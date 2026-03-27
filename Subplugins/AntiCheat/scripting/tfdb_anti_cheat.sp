#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2_stocks>
#include <multicolors>

// TFDB API: optional dependency. Works without it but gains rocket-level
// attribution (who deflected which rocket, exact speed, target info) when present.
#undef REQUIRE_PLUGIN
#tryinclude <tfdb>
#define REQUIRE_PLUGIN

// Track whether the TFDB library is actually loaded at runtime.
bool TfdbAvailable;

// Cached ConVar values — read once on change, not every tick.
// SM 1.12 best practice: never call .IntValue/.FloatValue in hot paths.
bool   ACEnabled;
int    ACLogLevel;
int    ACActionThreshold;
int    ACActionMode;
int    ACSilentHitsPerPoint;
int    ACTimingHitsPerPoint;
int    ACDecayAmount;
char   ACImmunityFlag[4];

// ============================================================================
// Constants
// ============================================================================

#define PLUGIN_NAME    "TFDB Anti-Cheat"
#define PLUGIN_VERSION "2.2.0"

// Ring buffer depth for angle history.
// The cheat's AntiCheatCompatibility keeps 5 frames of history to mask snaps,
// so we keep more to see through the smoothing.
#define ANGLE_HISTORY   32

// Ring buffer depth for airblast timing samples.
#define TIMING_HISTORY  64

// Perfect airblast timing window. The cheat fires IN_ATTACK2 on the exact
// tick the rocket enters the deflection sphere (128 hu radius * multiplier).
// Expressed as time, converted to ticks at runtime.
#define PERFECT_TIMING_TIME 0.03 // ~2 ticks at 66, ~4 at 128

// ============================================================================
// Per-client data structures
// ============================================================================

enum struct AngleRecord {
    float pitch;
    float yaw;
    int tick;
    bool attacking;
}

enum struct TimingRecord {
    float rocketDistance;
    float rocketSpeed;
    int ticksBeforeDeflect;
    int tick;
}


// Per-client tracking state
AngleRecord  AngleHistory[MAXPLAYERS + 1][ANGLE_HISTORY];
int          AngleIndex[MAXPLAYERS + 1];
int          AngleSamples[MAXPLAYERS + 1];

TimingRecord TimingHistory[MAXPLAYERS + 1][TIMING_HISTORY];
int          TimingIndex[MAXPLAYERS + 1];
int          TimingSamples[MAXPLAYERS + 1];


// Detection counters - accumulated evidence, not instant bans.
int   PerfectTimingDetections[MAXPLAYERS + 1];
int   InhaleExhaleDetections[MAXPLAYERS + 1];  // ConsistentTiming counter
int   DragSnapbackDetections[MAXPLAYERS + 1];  // Post-drag-pause 3-angle snapback (TFDB-specific)
int   AirblastFacingDetections[MAXPLAYERS + 1]; // Airblast succeeded while not facing rocket
int   AntiAimDetections[MAXPLAYERS + 1];       // m_angEyeAngles pitch outside [-89, 89]
int   PerfectStreakScore[MAXPLAYERS + 1];       // Scored streak milestones (not raw count)
float LastDetectionTime[MAXPLAYERS + 1];

// Timing detection state — prevents log spam and stale-data false positives
bool  TimingFlagged[MAXPLAYERS + 1];    // True once ConsistentTiming fires, false when pattern breaks
int   TimingCooldown[MAXPLAYERS + 1];   // Deflects remaining before re-evaluating after TimingCleared
int   CurrentStreak[MAXPLAYERS + 1];    // Current consecutive sub-2-tick airblast count
int   LastStreakMilestone[MAXPLAYERS + 1]; // Last streak milestone that was scored (6, 10, 15, 20...)

// Tracking the last airblast for timing analysis
float LastAirblastTime[MAXPLAYERS + 1];
int   LastAirblastTick[MAXPLAYERS + 1];
bool  JustAirblasted[MAXPLAYERS + 1];

// Angle state for snapback detection

// Previous tick data
float PrevAngles[MAXPLAYERS + 1][3];
int   PrevButtons[MAXPLAYERS + 1];

// Raw (pre-modification) angles from OnPlayerRunCmdPre
float RawAngles[MAXPLAYERS + 1][3];
bool  RawAnglesValid[MAXPLAYERS + 1];

// Network anomaly tracking

// Debug system — per-player verbose logging
// Per-client debug state — supports multiple simultaneous debug targets.
// Each debugged player gets their own log file named by sanitized SteamID.
enum struct DebugState {
    bool   active;                     // Is this client being debug-logged?
    char   logPath[PLATFORM_MAX_PATH]; // Cached full path to their log file
    char   steamId[32];                // Cached SteamID for filename
}

DebugState PlayerDebug[MAXPLAYERS + 1];

// ============================================================================
// ConVars
// ============================================================================

ConVar CvarEnabled;
ConVar CvarLogLevel;
ConVar CvarActionThreshold;
ConVar CvarAction;
ConVar CvarSilentThreshold;
ConVar CvarTimingThreshold;
ConVar CvarDecayInterval;
ConVar CvarDecayAmount;
ConVar CvarImmunityFlag;
ConVar CvarAdminHud;

// Admin HUD synchronizer — persistent overlay for admins showing live scores
Handle HudSync = INVALID_HANDLE;

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "Silorak",
    description = "Dodgeball Anti Cheat",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/tfdb-anticheat"
};

// ============================================================================
// Plugin Lifecycle
// ============================================================================

public void OnPluginStart()
{
    // Core toggle
    CvarEnabled = CreateConVar(
        "tfdb_ac_enabled", "1",
        "Enable the TFDB anti-cheat system.",
        _, true, 0.0, true, 1.0
    );

    // Logging verbosity: 0 = silent, 1 = detections only, 2 = verbose, 3 = debug
    CvarLogLevel = CreateConVar(
        "tfdb_ac_log_level", "1",
        "Log verbosity. 0=silent, 1=detections, 2=verbose, 3=debug",
        _, true, 0.0, true, 3.0
    );

    // Total accumulated score needed to trigger action
    CvarActionThreshold = CreateConVar(
        "tfdb_ac_action_threshold", "30",
        "Total detection score needed before taking action on a player.",
        _, true, 5.0, true, 200.0
    );

    // What to do when threshold is reached: 0=log, 1=kick, 2=ban
    CvarAction = CreateConVar(
        "tfdb_ac_action", "1",
        "Action on threshold: 0=log only, 1=kick, 2=ban.",
        _, true, 0.0, true, 2.0
    );

    // Individual detection type thresholds (how many raw hits = 1 score point)
    CvarSilentThreshold = CreateConVar(
        "tfdb_ac_silent_hits", "3",
        "Silent aim raw detections needed per score point.",
        _, true, 1.0, true, 20.0
    );

        "tfdb_ac_snap_hits", "4",
        "Angle snap raw detections needed per score point.",
        _, true, 1.0, true, 20.0
    );

    CvarTimingThreshold = CreateConVar(
        "tfdb_ac_timing_hits", "8",
        "Perfect timing raw detections needed per score point.",
        _, true, 1.0, true, 30.0
    );

        "tfdb_ac_movefix_hits", "6",
        "Movement correction raw detections needed per score point.",
        _, true, 1.0, true, 20.0
    );

    // Score decay: keeps the system from accumulating stale evidence
    CvarDecayInterval = CreateConVar(
        "tfdb_ac_decay_interval", "60.0",
        "Seconds between score decay ticks.",
        _, true, 10.0, true, 300.0
    );

    CvarDecayAmount = CreateConVar(
        "tfdb_ac_decay_amount", "2",
        "Score points removed per decay tick.",
        _, true, 1.0, true, 10.0
    );

    // Admin immunity
    CvarImmunityFlag = CreateConVar(
        "tfdb_ac_immunity_flag", "b",
        "Admin flag letter that grants immunity from detection."
    );

    // Admin HUD — live overlay showing suspicion scores for flagged players.
    // Only visible to admins with Ban flag. 0 = off, 1 = on.
    CvarAdminHud = CreateConVar(
        "tfdb_ac_admin_hud", "1",
        "Show live anti-cheat HUD overlay to admins. 0=off, 1=on",
        _, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "tfdb_anticheat");

    // Create log directory — LogToFile does NOT create directories automatically.
    // StAC uses the same pattern: create logs/stac/ at startup.
    char logDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logDir, sizeof(logDir), "logs/tfdb_ac");
    if (!DirExists(logDir))
    {
        CreateDirectory(logDir, 511); // 0777 permissions
    }

    // Use the shared TFDB translation file — our phrases are appended there.
    // This follows the TFDB subplugin convention where all plugins share tfdb.phrases.txt.
    LoadTranslations("tfdb.phrases.txt");

    // ConVar change hooks for caching — never read .IntValue in hot paths
    CvarEnabled.AddChangeHook(OnConVarChanged);
    CvarLogLevel.AddChangeHook(OnConVarChanged);
    CvarActionThreshold.AddChangeHook(OnConVarChanged);
    CvarAction.AddChangeHook(OnConVarChanged);
    CvarSilentThreshold.AddChangeHook(OnConVarChanged);
    CvarTimingThreshold.AddChangeHook(OnConVarChanged);
    CvarDecayAmount.AddChangeHook(OnConVarChanged);
    CvarImmunityFlag.AddChangeHook(OnConVarChanged);

    // Initial cache population
    CacheAllConVars();

    // Create HUD synchronizer for admin overlay
    HudSync = CreateHudSynchronizer();

    // Hook all currently connected clients (late load support)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }

    CreateTimer(CvarDecayInterval.FloatValue, Timer_DecayScores, _, TIMER_REPEAT);
    CreateTimer(1.0, Timer_AdminHud, _, TIMER_REPEAT);

    RegAdminCmd("sm_ac_status", Command_Status, ADMFLAG_BAN, "Show anti-cheat status for all players.");
    RegAdminCmd("sm_ac_reset", Command_Reset, ADMFLAG_ROOT, "Reset detection counters for a player.");
    RegAdminCmd("sm_ac_debug_player", Command_DebugPlayer, ADMFLAG_ROOT, "Toggle per-tick CSV debug logging for a player.");
}

// ============================================================================
// TFDB Library Integration
// ============================================================================

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "tfdb"))
        TfdbAvailable = true;
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "tfdb"))
        TfdbAvailable = false;
}

public void OnAllPluginsLoaded()
{
    TfdbAvailable = LibraryExists("tfdb");
}

#if defined _tfdb_included
// Hook TFDB deflect forward for precise rocket-player attribution.
// This is far more accurate than scanning entities in PreThink because
// TFDB tells us exactly WHO deflected WHICH rocket at WHAT speed.
public void TFDB_OnRocketDeflect(int index, int entity, int owner)
{
    if (!ACEnabled || !IsValidClient(owner))
        return;

    // Record the exact rocket speed at deflection time.
    float speed = TFDB_GetRocketSpeed(index);

    // Store deflection data for this client
    int tIdx = TimingIndex[owner] % TIMING_HISTORY;
    TimingHistory[owner][tIdx].rocketSpeed = speed;
    TimingHistory[owner][tIdx].tick = GetGameTickCount();

    // Use the TFDB rocket entity for distance calculation instead of
    // scanning all rockets in the world (more efficient and precise).
    if (IsValidEntity(entity))
    {
        float clientPos[3], rocketPos[3];
        GetClientEyePosition(owner, clientPos);
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", rocketPos);
        TimingHistory[owner][tIdx].rocketDistance = GetVectorDistance(clientPos, rocketPos);
    }

    // Estimate ticks margin (how close to the deflection sphere boundary).
    //
    // NOTE ON ROCKET CURVES: Dodgeball rockets don't fly straight — they
    // curve toward their target via LerpVectors with a turn rate each frame.
    // The cheat's PredictOrigin also uses straight-line projection from
    // instantaneous velocity, so our calculation matches the cheat's model.
    //
    // Since the curve makes the actual travel path longer than the straight
    // line, our margin estimate is a conservative lower bound — we'll
    // undercount rather than overcount perfect timing hits. That's correct
    // behavior for anti-cheat (fewer false positives).
    //
    // Speed in dodgeball typically caps around 3500 HU/s in practice.
    float deflectionRadius = 128.0;
    float distToSphere = TimingHistory[owner][tIdx].rocketDistance - deflectionRadius;
    if (distToSphere < 0.0) distToSphere = 0.0;

    int ticksMargin = 0;
    if (speed > 0.0)
    {
        ticksMargin = RoundToFloor(distToSphere / (speed * GetTickInterval()));
    }
    TimingHistory[owner][tIdx].ticksBeforeDeflect = ticksMargin;

    TimingIndex[owner]++;
    if (TimingSamples[owner] < TIMING_HISTORY) TimingSamples[owner]++;

    if (ticksMargin <= RoundToCeil(PERFECT_TIMING_TIME / GetTickInterval()) && TimingHistory[owner][tIdx].rocketDistance < deflectionRadius + 80.0)
    {
        PerfectTimingDetections[owner]++;
        LogDetection(owner, "PerfectTiming",
            "dist=%.0f speed=%.0f ticksMargin=%d (via TFDB)",
            TimingHistory[owner][tIdx].rocketDistance, speed, ticksMargin);
    }

    // Analyze timing consistency with enough samples
    if (TimingSamples[owner] >= 8)
    {
        AnalyzeAirblastTiming(owner, ticksMargin);
    }

    // ------------------------------------------------------------------
    // AIRBLAST-WITHOUT-FACING: Detects PSilent (bSendPacket choking).
    //
    // The cheat's PSilent auto-airblast works by:
    //   1. Choking the tick where viewangles are snapped to the rocket
    //   2. Firing IN_ATTACK2 on the choked tick
    //   3. Restoring viewangles and sending the next tick
    //
    // After the server processes the choked batch, GetClientEyeAngles
    // returns the FINAL (restored) angles, not the snapped ones.
    // But the deflection succeeded because the engine processed the
    // choked tick's angles for the airblast.
    //
    // If the player's current eye angles don't face the rocket at all
    // (>60° away from the rocket direction), yet the deflection worked,
    // the player must have used silent aim on a choked tick.
    //
    // False positive risk: a player might legitimately look away in the
    // same tick the deflection processes. But combined with consistent
    // timing, this becomes very strong evidence.
    // ------------------------------------------------------------------
    if (IsValidEntity(entity))
    {
        float eyePos[3], rocketPos[3];
        GetClientEyePosition(owner, eyePos);
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", rocketPos);

        float dist = GetVectorDistance(eyePos, rocketPos);

        // Only check when rocket is close (< 300 HU) and we have
        // enough angle history to scan.
        if (dist < 300.0 && AngleSamples[owner] >= 12)
        {
            // Calculate the angle FROM the player TO the rocket
            float dirToRocket[3];
            MakeVectorFromPoints(eyePos, rocketPos, dirToRocket);
            float angleToRocket[3];
            GetVectorAngles(dirToRocket, angleToRocket);

            // Scan the last 6 ticks of AngleHistory for ANY tick where
            // the player was facing the rocket (within 50°).
            //
            // LEGIT PLAYER: Faces rocket → airblasts → flicks away.
            //   At least 1-2 ticks in the window will show < 50° to rocket.
            //
            // PSILENT CHEAT: Never faces rocket in SENT ticks. The facing
            //   angle was on a CHOKED tick, which doesn't appear in our
            //   history because AntiCheatCompatibility smoothed it.
            //   All visible ticks show the player's REAL view direction.
            //
            // Why 50° not 60°: the deflection sphere is generous, but a
            // legit player who was tracking the rocket should have at least
            // one tick within 50° of it right before/during the airblast.
            bool facedRocket = false;
            float bestDelta = 999.0;

            for (int i = 0; i < 12; i++)
            {
                int hIdx = (AngleIndex[owner] - 1 - i + ANGLE_HISTORY) % ANGLE_HISTORY;
                float delta = AngleDelta(
                    AngleHistory[owner][hIdx].pitch,
                    AngleHistory[owner][hIdx].yaw,
                    angleToRocket[0], angleToRocket[1]);

                if (delta < bestDelta)
                    bestDelta = delta;

                if (delta < 50.0)
                {
                    facedRocket = true;
                    break;
                }
            }

            // Also check current eye angles (they may have just arrived)
            float currentAngles[3];
            GetClientEyeAngles(owner, currentAngles);
            float currentDelta = AngleDelta(currentAngles[0], currentAngles[1],
                angleToRocket[0], angleToRocket[1]);
            if (currentDelta < 50.0)
                facedRocket = true;
            if (currentDelta < bestDelta)
                bestDelta = currentDelta;

            // If NO tick in the window faced the rocket, this is PSilent.
            // The airblast succeeded (TFDB_OnRocketDeflect fired) but the
            // player's visible angles never pointed at the rocket.
            if (!facedRocket)
            {
                AirblastFacingDetections[owner]++;
                LogDetection(owner, "AirblastFacing",
                    "bestDelta=%.1f eyeAng=(%.1f,%.1f) rocketAng=(%.1f,%.1f) dist=%.0f",
                    bestDelta, currentAngles[0], currentAngles[1],
                    angleToRocket[0], angleToRocket[1], dist);
            }
        }
    }

    // ------------------------------------------------------------------
    // DRAG-AWARE DETECTION: 3-angle snapback via TFDB drag pause.
    //
    // The cheat's auto-airblast with Redirect does this:
    //   1. Player's real view = angle A (PreDeflect)
    //   2. Cheat snaps to rocket = angle B (Deflect) + fires IN_ATTACK2
    //   3. AntiCheatCompatibility lerps back within 1-3 ticks
    //   4. After drag pause, player's view = angle C (PostDrag) ≈ A
    //
    // A LEGIT DRAGGER does this:
    //   1. Player faces rocket = angle A ≈ B (already looking at it)
    //   2. Airblasts = angle B (Deflect)
    //   3. Drags mouse to aim at enemy target during drag pause
    //   4. After drag pause = angle C ≠ A, ≠ B (new target direction)
    //
    // OLD (BROKEN) DETECTION: |B - C| > 45°
    //   → Flags legit draggers (who move from B to C)
    //   → Misses cheaters (whose C ≈ A, making |B - C| ≈ |B - A|)
    //
    // NEW (CORRECT) DETECTION: |C - A| < threshold AND |B - A| > 15°
    //   → The cheat snapped FROM A to B (large departure) then returned
    //     to A after drag pause (near-perfect return = snapback)
    //   → Legit draggers have A ≈ B (no departure) so |B - A| < 15°
    //     and C is somewhere new → never triggers
    //
    // We need 3 angles: A (pre-deflect), B (at deflect), C (post-drag).
    // A is pulled from AngleHistory — we look 4 ticks back from the
    // current tick to get the angle BEFORE the cheat started snapping.
    // B is GetClientEyeAngles at the moment of TFDB_OnRocketDeflect.
    // C is GetClientEyeAngles after the drag pause timer fires.
    // ------------------------------------------------------------------
    int rocketClass = TFDB_GetRocketClass(index);
    float dragDuration = TFDB_GetRocketClassDragPauseDuration(rocketClass);

    if (dragDuration > 0.0)
    {
        // Angle B: where the player is looking RIGHT NOW at deflection time.
        // If the cheat has Redirect on, this is the snapped angle (toward rocket).
        // If legit, this is where they were naturally aiming.
        float deflectAngles[3];
        GetClientEyeAngles(owner, deflectAngles);

        // Angle A: where the player was looking BEFORE the deflection.
        // We go 4 ticks back in AngleHistory to get the pre-snap angle.
        // The cheat snaps on the same tick as the airblast, so t-4 should
        // be before any AntiCheatCompatibility lerping began.
        // If we don't have enough history, skip this check.
        float preDeflectPitch = deflectAngles[0];
        float preDeflectYaw = deflectAngles[1];
        bool hasPreDeflect = false;

        if (AngleSamples[owner] >= 5)
        {
            int preIdx = (AngleIndex[owner] - 4 + ANGLE_HISTORY) % ANGLE_HISTORY;
            preDeflectPitch = AngleHistory[owner][preIdx].pitch;
            preDeflectYaw = AngleHistory[owner][preIdx].yaw;
            hasPreDeflect = true;
        }

        // Pack all 3 angles for the delayed check
        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(owner));
        pack.WriteCell(index);
        pack.WriteFloat(deflectAngles[0]);  // B pitch
        pack.WriteFloat(deflectAngles[1]);  // B yaw
        pack.WriteFloat(preDeflectPitch);   // A pitch
        pack.WriteFloat(preDeflectYaw);     // A yaw
        pack.WriteCell(hasPreDeflect);
        CreateTimer(dragDuration + GetTickInterval(), Timer_CheckDragAngle, pack, TIMER_DATA_HNDL_CLOSE);
    }
}

/**
 * Fires after TFDB's drag pause expires. Implements 3-angle snapback detection.
 *
 * Angles:
 *   A = PreDeflect (4 ticks before airblast — before cheat snap)
 *   B = Deflect    (at airblast — potentially cheat-snapped)
 *   C = PostDrag   (now, after drag pause — where player is looking)
 *
 * Cheat signature: |B - A| > 15° (cheat snapped) AND |C - A| < 8° (returned to origin)
 * Legit dragger:   |B - A| < 15° (already facing rocket) → no flag regardless of C
 */
public Action Timer_CheckDragAngle(Handle timer, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    pack.ReadCell(); // rocket index - advance position
    float deflectPitch = pack.ReadFloat();    // B
    float deflectYaw = pack.ReadFloat();      // B
    float preDeflectPitch = pack.ReadFloat();  // A
    float preDeflectYaw = pack.ReadFloat();    // A
    bool hasPreDeflect = pack.ReadCell() != 0;
    // pack is auto-deleted by TIMER_DATA_HNDL_CLOSE

    int client = GetClientOfUserId(userId);
    if (!IsValidClient(client, true))
        return Plugin_Stop;

    if (!TfdbAvailable)
        return Plugin_Stop;

    if (!hasPreDeflect)
        return Plugin_Stop;

    // Angle C: where the player is looking NOW (after drag pause)
    float currentAngles[3];
    GetClientEyeAngles(client, currentAngles);

    // |B - A| = departure: how far they snapped at deflection time
    float departure = AngleDelta(preDeflectPitch, preDeflectYaw,
        deflectPitch, deflectYaw);

    // |C - A| = return: how close they are to their pre-deflect angle
    float returnToOrigin = AngleDelta(preDeflectPitch, preDeflectYaw,
        currentAngles[0], currentAngles[1]);

    // |C - B| = drift: how far they moved from deflect angle (for logging)
    float driftFromDeflect = AngleDelta(deflectPitch, deflectYaw,
        currentAngles[0], currentAngles[1]);

    // CHEAT SIGNATURE:
    // 1. departure > 15°: the cheat snapped viewangles to a different direction
    //    (toward the rocket) at airblast time. A legit player was already
    //    facing the rocket, so their departure is small.
    // 2. returnToOrigin < 8°: after drag pause, the cheat has snapped back
    //    to within 8° of where it was before. A legit dragger has moved to
    //    a completely new angle (their drag target), so returnToOrigin is large.
    //
    // The 8° return threshold is generous — the cheat's AntiCheatCompatibility
    // returns to within 0.1° (REAL_EPSILON). We use 8° to account for natural
    // mouse drift during the drag pause period while the cheat is "returned".
    if (departure > 15.0 && returnToOrigin < 8.0)
    {
        DragSnapbackDetections[client]++;
        LogDetection(client, "DragSnapback",
            "preAng=(%.1f,%.1f) deflectAng=(%.1f,%.1f) postAng=(%.1f,%.1f) depart=%.1f return=%.1f drift=%.1f",
            preDeflectPitch, preDeflectYaw,
            deflectPitch, deflectYaw,
            currentAngles[0], currentAngles[1],
            departure, returnToOrigin, driftFromDeflect);
    }

    return Plugin_Stop;
}
#endif

// ============================================================================
// ConVar Caching (SM 1.12 best practice)
// ============================================================================

void CacheAllConVars()
{
    ACEnabled = CvarEnabled.BoolValue;
    ACLogLevel = CvarLogLevel.IntValue;
    ACActionThreshold = CvarActionThreshold.IntValue;
    ACActionMode = CvarAction.IntValue;
    ACSilentHitsPerPoint = MaxInt(1, CvarSilentThreshold.IntValue);
    ACTimingHitsPerPoint = MaxInt(1, CvarTimingThreshold.IntValue);
    ACDecayAmount = CvarDecayAmount.IntValue;
    CvarImmunityFlag.GetString(ACImmunityFlag, sizeof(ACImmunityFlag));
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CacheAllConVars();
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
    SDKHook(client, SDKHook_PreThink, OnPreThink);
}

public void OnClientDisconnect(int client)
{
    LogSessionSummary(client);

    // Close debug logging if active on this player
    if (PlayerDebug[client].active)
    {
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogToFile(PlayerDebug[client].logPath, "=== Debug ended for %s (disconnected) ===", name);
        PlayerDebug[client].active = false;
    }

    ResetClientState(client);
    SDKUnhook(client, SDKHook_PreThink, OnPreThink);
}

void ResetClientState(int client)
{
    AngleIndex[client]     = 0;
    AngleSamples[client]   = 0;
    TimingIndex[client]    = 0;
    TimingSamples[client]  = 0;

    PerfectTimingDetections[client]  = 0;
    InhaleExhaleDetections[client]   = 0;
    DragSnapbackDetections[client]   = 0;
    AirblastFacingDetections[client] = 0;
    AntiAimDetections[client]        = 0;
    PerfectStreakScore[client]        = 0;
    LastDetectionTime[client]        = 0.0;

    TimingFlagged[client]       = false;
    TimingCooldown[client]      = 0;
    CurrentStreak[client]       = 0;
    LastStreakMilestone[client]  = 0;

    LastAirblastTime[client]  = 0.0;
    LastAirblastTick[client]  = 0;
    JustAirblasted[client]    = false;

    PrevAngles[client][0] = 0.0;
    PrevAngles[client][1] = 0.0;
    PrevAngles[client][2] = 0.0;
    PrevButtons[client]   = 0;

    RawAnglesValid[client] = false;
}

// ============================================================================
// Core Detection: OnPlayerRunCmdPre (SM 1.12+)
//
// This forward fires BEFORE any other plugin can modify the usercmd.
// Critical for anti-cheat: we see the raw client values untouched.
// Falls back to OnPlayerRunCmd on older SM versions.
// ============================================================================

public void OnPlayerRunCmdPre(int client, int buttons, int impulse,
    const float vel[3], const float angles[3], int weapon, int subtype,
    int cmdnum, int tickcount, int seed, const int mouse[2])
{
    // ------------------------------------------------------------------
    // DEBUG LOGGING: Per-tick data for any debug-active player.
    // Must run BEFORE immunity/alive gates — admin debugging themselves
    // has immunity flag which would skip everything below.
    // Supports multiple simultaneous targets, each with their own log file.
    // ------------------------------------------------------------------
    if (PlayerDebug[client].active && IsClientInGame(client))
    {
        bool isAtk2 = (buttons & IN_ATTACK2) != 0;
        bool isAtk1 = (buttons & IN_ATTACK) != 0;
        LogToFile(PlayerDebug[client].logPath,
            "cmd=%d p=%.2f y=%.2f atk=%d%d btn=%d tick=%d",
            cmdnum, angles[0], angles[1],
            isAtk1 ? 1 : 0, isAtk2 ? 1 : 0,
            buttons, tickcount);
    }

    if (!ACEnabled)
        return;

    if (!IsValidClient(client, true))
        return;

    if (HasImmunity(client))
        return;

    // Store the raw (pre-modification) angles from the client's usercmd.
    // OnPlayerRunCmdPre fires BEFORE any other plugin can modify angles.
    // In OnPlayerRunCmd we compare these against what arrives — if another
    // plugin changed the angles, we must not flag that as a cheat snap.
    RawAngles[client][0] = angles[0];
    RawAngles[client][1] = angles[1];
    RawAngles[client][2] = angles[2];
    RawAnglesValid[client] = true;
}

// ============================================================================
// Core Detection: OnPlayerRunCmd
//
// This is where we see every user command the client sends. The cheat
// modifies CUserCmd in CHLClient_CreateMove before it reaches the server.
// We analyze the patterns that remain visible server-side.
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
    float vel[3], float angles[3], int &weapon, int &subtype,
    int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!ACEnabled)
        return Plugin_Continue;

    if (!IsValidClient(client, true))
        return Plugin_Continue;

    if (HasImmunity(client))
        return Plugin_Continue;

    int currentTick = GetGameTickCount();

    // If another plugin modified the angles between OnPlayerRunCmdPre and
    // OnPlayerRunCmd, the delta we'd see isn't from the client's usercmd.
    // Skip angle-based detections this tick to avoid false positives.
    bool anglesModifiedByPlugin = false;
    if (RawAnglesValid[client])
    {
        if (angles[0] != RawAngles[client][0] ||
            angles[1] != RawAngles[client][1])
        {
            anglesModifiedByPlugin = true;
        }
    }
    RawAnglesValid[client] = false;


    // ------------------------------------------------------------------
    // Record angle history (used by AirblastFacing and DragSnapback
    // in TFDB_OnRocketDeflect)
    // ------------------------------------------------------------------

    bool isAttacking = (buttons & IN_ATTACK2) != 0;
    bool wasAttacking = (PrevButtons[client] & IN_ATTACK2) != 0;

    int idx = AngleIndex[client] % ANGLE_HISTORY;
    AngleHistory[client][idx].pitch = angles[0];
    AngleHistory[client][idx].yaw = angles[1];
    AngleHistory[client][idx].tick = currentTick;
    AngleHistory[client][idx].attacking = isAttacking;
    AngleIndex[client]++;
    if (AngleSamples[client] < ANGLE_HISTORY) AngleSamples[client]++;

    // ------------------------------------------------------------------
    // DETECTION: AntiAim via m_angEyeAngles
    //
    // The cheat's AntiAim adds +360 to pitch or does 180-pitch.
    // SM clamps CUserCmd angles before OnPlayerRunCmd, so we can't
    // see it in the usercmd. But the engine sets m_angEyeAngles on
    // the player entity from the RAW usercmd values. The DataTable
    // SendProxy clamps for network transmission, but the entity prop
    // retains the raw value.
    //
    // If m_angEyeAngles[0] is outside [-89, 89], the client is using
    // AntiAim. Zero false positive rate.
    // ------------------------------------------------------------------

    float eyePitch = GetEntPropFloat(client, Prop_Send, "m_angEyeAngles", 0);
    if (eyePitch > 89.1 || eyePitch < -89.1)
    {
        AntiAimDetections[client]++;
        LogDetection(client, "AntiAim",
            "m_angEyeAngles[0]=%.2f (valid range [-89, 89])",
            eyePitch);
    }

    // ------------------------------------------------------------------
    // Track airblast timing (used by TFDB_OnRocketDeflect for
    // ConsistentTiming and PerfectStreak analysis)
    // ------------------------------------------------------------------

    if (isAttacking && !wasAttacking)
    {
        LastAirblastTime[client] = GetGameTime();
        LastAirblastTick[client] = currentTick;
        JustAirblasted[client] = true;
    }

    // Store for next tick comparison
    PrevAngles[client][0] = angles[0];
    PrevAngles[client][1] = angles[1];
    PrevAngles[client][2] = angles[2];
    PrevButtons[client]   = buttons;

    // Periodically evaluate accumulated evidence
    EvaluatePlayer(client);

    return Plugin_Continue;
}

// ============================================================================
// PreThink Hook - Rocket Proximity Analysis
//
// We use PreThink instead of OnGameFrame because we need per-client context.
// This checks what rockets are near each player and correlates with their
// airblast inputs.
// ============================================================================

public void OnPreThink(int client)
{
    if (!ACEnabled || !IsValidClient(client, true))
        return;

    if (!JustAirblasted[client])
        return;

    JustAirblasted[client] = false;

    // If TFDB is available, the TFDB_OnRocketDeflect forward already
    // handles timing analysis with precise rocket data. Skip the
    // expensive entity scan fallback.
    if (TfdbAvailable)
        return;

    // Find the closest enemy rocket and measure how far it was when
    // the player airblasted. Perfect timing = airblast exactly when
    // the rocket enters the deflection sphere.
    float clientPos[3];
    GetClientEyePosition(client, clientPos);

    float closestDist = 99999.0;
    float closestSpeed = 0.0;
    int closestRocket = -1;

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "tf_projectile_rocket")) != -1)
    {
        if (!IsValidEntity(entity))
            continue;

        int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
        int clientTeam = GetClientTeam(client);
        if (team == clientTeam)
            continue;

        float rocketPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", rocketPos);

        float dist = GetVectorDistance(clientPos, rocketPos);
        if (dist < closestDist)
        {
            closestDist = dist;
            closestRocket = entity;

            float rocketVel[3];
            GetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", rocketVel);
            closestSpeed = GetVectorLength(rocketVel);
        }
    }

    // Also check sentry rockets (for animated models)
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "tf_projectile_sentryrocket")) != -1)
    {
        if (!IsValidEntity(entity))
            continue;

        int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
        int clientTeam = GetClientTeam(client);
        if (team == clientTeam)
            continue;

        float rocketPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", rocketPos);

        float dist = GetVectorDistance(clientPos, rocketPos);
        if (dist < closestDist)
        {
            closestDist = dist;
            closestRocket = entity;

            float rocketVel[3];
            GetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", rocketVel);
            closestSpeed = GetVectorLength(rocketVel);
        }
    }

    if (closestRocket == -1)
        return;

    // Record timing data
    int tIdx = TimingIndex[client] % TIMING_HISTORY;
    TimingHistory[client][tIdx].rocketDistance = closestDist;
    TimingHistory[client][tIdx].rocketSpeed = closestSpeed;
    TimingHistory[client][tIdx].tick = LastAirblastTick[client];

    // Estimate ticks until the rocket would have hit:
    // Deflection radius is ~128 hu (scaled by weapon attributes).
    float deflectionRadius = 128.0;
    float distanceToSphere = closestDist - deflectionRadius;
    if (distanceToSphere < 0.0) distanceToSphere = 0.0;

    int ticksBeforeHit = 0;
    if (closestSpeed > 0.0)
    {
        ticksBeforeHit = RoundToFloor(distanceToSphere / (closestSpeed * GetTickInterval()));
    }
    TimingHistory[client][tIdx].ticksBeforeDeflect = ticksBeforeHit;

    TimingIndex[client]++;
    if (TimingSamples[client] < TIMING_HISTORY) TimingSamples[client]++;

    // The cheat predicts rocket position using:
    //   SDK::PredictOrigin(vOrigin, m_vecOrigin(), GetVelocity(), latency)
    // Then checks CanAirblastEntity using a CEntitySphereQuery.
    // It fires IN_ATTACK2 on the exact frame the rocket is within range.
    //
    // A human needs to visually react to the approaching rocket and time
    // their airblast with imprecise muscle memory. Consistently airblasting
    // within 0-2 ticks of the sphere boundary is inhuman.
    if (ticksBeforeHit <= RoundToCeil(PERFECT_TIMING_TIME / GetTickInterval()) && closestDist < deflectionRadius + 80.0)
    {
        PerfectTimingDetections[client]++;
        LogDetection(client, "PerfectTiming",
            "dist=%.0f speed=%.0f ticksMargin=%d",
            closestDist, closestSpeed, ticksBeforeHit);
    }
}

// ============================================================================
// Detection Helpers
// ============================================================================

/**
 * Check for the silent aim snapback pattern.
 *
 * The cheat sets PSilentAngles = true, snaps to a rocket, fires IN_ATTACK2,
 * then its AntiCheatCompatibility function lerps the viewangles back over
 * 2-3 frames to avoid per-frame delta thresholds.
 *
 * The old detector checked: calm(t-2→t-1) + big(t-1→t) + attacking.
 * This fails because the cheat's lerp splits the snap into multiple small
 * deltas (e.g. 8° + 8° + 8° instead of one 24° snap).
 *
 * NEW APPROACH — Arc displacement over attack window:
 * 1. When IN_ATTACK2 fires, record the "anchor" angle from 3+ frames prior.
 * 2. After IN_ATTACK2 releases, track where the view goes for 6 frames.
 * 3. Compute total arc distance (sum of all per-frame deltas in the window)
 *    vs. net displacement (straight-line from anchor to current).
 *
 * For a human flick-reflect: arc ≈ net (they flick in a direction and stay).
 * For the cheat: arc >> net (it goes to rocket, then comes BACK to origin).
 * A ratio of arc/net > 3.0 with arc > 15° during an attack is the signature.
 *
 * Additionally: check the "return precision". The cheat returns to within
 * 0.1° of the pre-attack angle (REAL_EPSILON). Humans never return to
 * exactly where they were — there's always 2-5° of drift.
 */

/**
 * Analyze airblast timing patterns.
 *
 * Called on every TFDB_OnRocketDeflect with the current deflect's ticksMargin.
 *
 * Two detectors:
 * 1. ConsistentTiming: fires ONCE when recent-8 variance drops below threshold,
 *    then suppresses until the pattern breaks (variance rises above 3.0).
 *    This prevents the log spam seen in testing (44 entries in 54 seconds).
 *
 * 2. PerfectStreak: tracks the CURRENT streak of sub-2-tick airblasts.
 *    Scores at milestones (6, 12, 20, 30, 45) — each milestone adds points.
 *    When the streak breaks, it resets. No more "counting down" from historical max.
 */
void AnalyzeAirblastTiming(int client, int ticksMargin)
{
    int limit = TimingSamples[client] < TIMING_HISTORY ?
                TimingSamples[client] : TIMING_HISTORY;

    // ------- Streak tracking (per-deflect, not historical scan) -------
    if (ticksMargin <= 2)
    {
        CurrentStreak[client]++;

        // Score at milestones: 6, 12, 20, 30, 45
        // Each milestone that hasn't been scored yet adds to PerfectStreakScore
        int streak = CurrentStreak[client];
        int milestone = 0;
        if (streak >= 45) milestone = 45;
        else if (streak >= 30) milestone = 30;
        else if (streak >= 20) milestone = 20;
        else if (streak >= 12) milestone = 12;
        else if (streak >= 6) milestone = 6;

        if (milestone > 0 && milestone > LastStreakMilestone[client])
        {
            LastStreakMilestone[client] = milestone;
            PerfectStreakScore[client]++;
            LogDetection(client, "PerfectStreak",
                "streak=%d milestone=%d",
                streak, milestone);
        }
    }
    else
    {
        // Streak broken
        if (CurrentStreak[client] >= 6)
        {
            // Log the break for analysis — not a detection, just info
            if (ACLogLevel >= 2)
            {
                LogDetection(client, "StreakBroken",
                    "finalStreak=%d ticksMargin=%d",
                    CurrentStreak[client], ticksMargin);
            }
        }
        CurrentStreak[client] = 0;
        LastStreakMilestone[client] = 0;
    }

    // ------- Recent window variance (last 8 deflects) -------
    if (limit < 8) return;

    // Cooldown: after TimingCleared, wait for 8 fresh deflects
    // before re-evaluating. Prevents stale cheat data from causing
    // false re-flags when toggling off.
    if (TimingCooldown[client] > 0)
    {
        TimingCooldown[client]--;
        return;
    }

    float recentSum = 0.0;
    float recentSumSq = 0.0;
    for (int i = 0; i < 8; i++)
    {
        int idx = ((TimingIndex[client] - 1 - i) % TIMING_HISTORY + TIMING_HISTORY) % TIMING_HISTORY;
        float val = float(TimingHistory[client][idx].ticksBeforeDeflect);
        recentSum += val;
        recentSumSq += val * val;
    }

    float recentMean = recentSum / 8.0;
    float recentVariance = (recentSumSq / 8.0) - (recentMean * recentMean);

    if (recentVariance < 1.5 && recentMean < 2.5)
    {
        // Pattern detected — only fire if not already flagged
        if (!TimingFlagged[client])
        {
            TimingFlagged[client] = true;
            InhaleExhaleDetections[client]++;
            LogDetection(client, "ConsistentTiming",
                "recentMean=%.1f recentVar=%.2f window=8 (FLAGGED)",
                recentMean, recentVariance);
        }
        // While flagged, continue accumulating score every 10 deflects
        // to ensure persistent cheaters reach threshold
        else if (TimingSamples[client] % 10 == 0)
        {
            InhaleExhaleDetections[client]++;
            if (ACLogLevel >= 2)
            {
                LogDetection(client, "ConsistentTiming",
                    "recentMean=%.1f recentVar=%.2f window=8 (ACCUMULATING)",
                    recentMean, recentVariance);
            }
        }
    }
    else if (recentVariance > 3.0)
    {
        // Pattern broken — unflag so we can detect it again
        if (TimingFlagged[client])
        {
            TimingFlagged[client] = false;
            // Set a cooldown: don't re-evaluate timing for 8 more deflects.
            // This prevents stale cheat data in the ring buffer from
            // causing a false re-flag when the cheat is toggled off.
            // The ring buffer needs 8 new legit samples to fully flush.
            TimingCooldown[client] = 8;
            if (ACLogLevel >= 2)
            {
                LogDetection(client, "TimingCleared",
                    "recentMean=%.1f recentVar=%.2f (pattern broken, cooldown=8)",
                    recentMean, recentVariance);
            }
        }
    }
}

// ============================================================================
// Score Evaluation
// ============================================================================

/**
 * Convert raw detection counts into a weighted score and take action
 * if the threshold is exceeded.
 *
 * Different detection types have different confidence levels:
 * - Snapback/SilentAim: HIGH confidence (hard to false-positive)
 * - MoveFix: HIGH confidence (mathematically precise signature)
 * - PerfectTiming: MEDIUM confidence (good players CAN be fast)
 * - SnapAim: MEDIUM confidence (high-DPI mice produce large deltas)
 * - FrozenSnap: LOW confidence (could be alt-tabbing)
 */
/**
 * Calculate the weighted score for a player from raw detection counts.
 */
int CalculateScore(int client)
{
    int score = 0;

    // CRITICAL: AntiAim — m_angEyeAngles pitch outside [-89, 89]
    // Zero false positive rate. Does not decay.
    score += AntiAimDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 5;

    // HIGH: PSilent detection via facing check
    score += AirblastFacingDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 4;

    // HIGH: 3-angle drag snapback (return-to-origin after drag pause)
    score += DragSnapbackDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 4;

    // MEDIUM-HIGH: timing (primary detector for auto-airblast)
    score += InhaleExhaleDetections[client] * 3;

    // MEDIUM-HIGH: streak milestones (each milestone = 4 points)
    score += PerfectStreakScore[client] * 4;

    // MEDIUM: individual timing flags
    score += PerfectTimingDetections[client] / MaxInt(1, ACTimingHitsPerPoint) * 2;

    return score;
}

void EvaluatePlayer(int client)
{
    // Only evaluate every 66 ticks (~1 second) to avoid spam
    if (GetGameTickCount() % RoundToCeil(1.0 / GetTickInterval()) != 0) return;

    int score = CalculateScore(client);

    if (score >= ACActionThreshold)
    {
        TakeAction(client, score);
    }
}

void TakeAction(int client, int score)
{
    char name[MAX_NAME_LENGTH];
    char steamId[32];
    GetClientName(client, name, sizeof(name));
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    char logPath[PLATFORM_MAX_PATH];
    char dateStr[32];
    FormatTime(dateStr, sizeof(dateStr), "%m_%d_%Y");
    BuildPath(Path_SM, logPath, sizeof(logPath),
        "logs/tfdb_ac/tfdb_ac_%s.log", dateStr);

    LogToFile(logPath,
        "[ACTION] %s (%s) Score:%d | AA:%d AF:%d DS:%d PT:%d CT:%d Str:%d(%d) | action:%d",
        name, steamId, score,
        AntiAimDetections[client],
        AirblastFacingDetections[client],
        DragSnapbackDetections[client],
        PerfectTimingDetections[client],
        InhaleExhaleDetections[client],
        CurrentStreak[client],
        PerfectStreakScore[client],
        ACActionMode);

    switch (ACActionMode)
    {
        case 0:
        {
            PrintToAdmins("%t", "AC_Admin_Flagged", client, score);
        }
        case 1:
        {
            char reason[128];
            Format(reason, sizeof(reason), "%T", "AC_Kick_Reason", LANG_SERVER);
            KickClient(client, reason);
            PrintToAdmins("%t", "AC_Admin_Kicked", client, score);
        }
        case 2:
        {
            char reason[128];
            Format(reason, sizeof(reason), "%T", "AC_Ban_Reason", LANG_SERVER);
            BanClient(client, 0, BANFLAG_AUTHID, reason, reason);
            PrintToAdmins("%t", "AC_Admin_Banned", client, score);
        }
    }

    // Reset after action to avoid repeated kicks on rejoin with stale data
    ResetClientState(client);
}

// ============================================================================
// Score Decay Timer
// ============================================================================

public Action Timer_DecayScores(Handle timer)
{
    int decay = ACDecayAmount;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client))
            continue;

        // AntiAim does NOT decay — zero false positive rate, permanent evidence.

        AirblastFacingDetections[client] = MaxInt(0, AirblastFacingDetections[client] - decay);
        DragSnapbackDetections[client]   = MaxInt(0, DragSnapbackDetections[client] - decay);
        PerfectTimingDetections[client]  = MaxInt(0, PerfectTimingDetections[client] - decay);

        // Don't decay timing counters while cheat is actively running.
        if (!TimingFlagged[client])
            InhaleExhaleDetections[client] = MaxInt(0, InhaleExhaleDetections[client] - decay);
        if (CurrentStreak[client] < 6)
            PerfectStreakScore[client] = MaxInt(0, PerfectStreakScore[client] - decay);
    }

    return Plugin_Continue;
}

// ============================================================================
// Admin HUD Overlay
//
// Shows live anti-cheat suspicion data to admins with Ban flag.
// Uses CreateHudSynchronizer for flicker-free persistent display.
// Updates every 1 second. Only shows players with score > 0.
// Position: top-left corner (x=0.01, y=0.02) to avoid overlapping
// the speedhud (bottom-center) and game HUD elements.
// ============================================================================

public Action Timer_AdminHud(Handle timer)
{
    if (!ACEnabled) return Plugin_Continue;
    if (HudSync == INVALID_HANDLE) return Plugin_Continue;
    if (!CvarAdminHud.BoolValue) return Plugin_Continue;

    // Build the HUD text once, then send to all admins
    char hudText[512];
    int hudLen = 0;
    int flaggedCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;

        int score = CalculateScore(i);
        if (score <= 0) continue;

        flaggedCount++;

        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));

        // Compact format: Name Score [active detectors]
        char detectors[128];
        int dLen = 0;

        if (AntiAimDetections[i] > 0)
            dLen += FormatEx(detectors[dLen], sizeof(detectors) - dLen, " AA:%d", AntiAimDetections[i]);
        if (AirblastFacingDetections[i] > 0)
            dLen += FormatEx(detectors[dLen], sizeof(detectors) - dLen, " AF:%d", AirblastFacingDetections[i]);
        if (DragSnapbackDetections[i] > 0)
            dLen += FormatEx(detectors[dLen], sizeof(detectors) - dLen, " DS:%d", DragSnapbackDetections[i]);
        if (PerfectTimingDetections[i] > 0)
            dLen += FormatEx(detectors[dLen], sizeof(detectors) - dLen, " PT:%d", PerfectTimingDetections[i]);
        if (InhaleExhaleDetections[i] > 0)
            dLen += FormatEx(detectors[dLen], sizeof(detectors) - dLen, " CT:%d", InhaleExhaleDetections[i]);
        if (PerfectStreakScore[i] > 0 || CurrentStreak[i] >= 6)
            dLen += FormatEx(detectors[dLen], sizeof(detectors) - dLen, " Str:%d(%d)", CurrentStreak[i], PerfectStreakScore[i]);

        // Color-code the score in the HUD by threshold proximity
        // Score text goes from white → yellow → red as it approaches action threshold
        hudLen += FormatEx(hudText[hudLen], sizeof(hudText) - hudLen,
            "%s [%d]%s\n",
            name, score, detectors);

        if (flaggedCount >= 5) break; // Max 5 players shown to keep HUD compact
    }

    if (flaggedCount == 0)
    {
        // Clear the HUD for all admins when nobody is flagged
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidClient(i)) continue;
            AdminId admin = GetUserAdmin(i);
            if (admin == INVALID_ADMIN_ID) continue;
            if (!GetAdminFlag(admin, Admin_Ban)) continue;
            ClearSyncHud(i, HudSync);
        }
        return Plugin_Continue;
    }

    // Send to all admins with Ban flag
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        AdminId admin = GetUserAdmin(i);
        if (admin == INVALID_ADMIN_ID) continue;
        if (!GetAdminFlag(admin, Admin_Ban)) continue;

        // Position: top-left, small text, yellow-ish for visibility
        // Color shifts from white (low score) toward red (near threshold)
        // We use the highest score among flagged players to set color
        int r = 255, g = 220, b = 50;
        SetHudTextParams(0.01, 0.02, 1.1, r, g, b, 255, 0, 0.0, 0.0, 0.0);
        ShowSyncHudText(i, HudSync, "-- AC --\n%s", hudText);
    }

    return Plugin_Continue;
}

// ============================================================================
// Admin Commands
// ============================================================================

public Action Command_Status(int client, int args)
{
    bool foundAny = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;

        int score = CalculateScore(i);

        if (score > 0)
        {
            if (!foundAny)
            {
                CReplyToCommand(client, "%t", "AC_Status_Header");
                foundAny = true;
            }
            CReplyToCommand(client, "%t", "AC_Status_Player",
                i, score,
                AntiAimDetections[i],
                AirblastFacingDetections[i],
                DragSnapbackDetections[i],
                PerfectTimingDetections[i],
                InhaleExhaleDetections[i],
                CurrentStreak[i],
                PerfectStreakScore[i]);
        }
    }
    if (!foundAny)
    {
        CReplyToCommand(client, "%t", "AC_Status_Clean");
    }
    return Plugin_Handled;
}

public Action Command_Reset(int client, int args)
{
    if (args < 1)
    {
        CReplyToCommand(client, "%t", "AC_Reset_Usage");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true);
    if (target == -1) return Plugin_Handled;

    ResetClientState(target);
    CReplyToCommand(client, "%t", "AC_Reset_Done", target);
    return Plugin_Handled;
}

public Action Command_DebugPlayer(int client, int args)
{
    if (args < 1)
    {
        // No args: show currently active debug targets
        bool foundAny = false;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (PlayerDebug[i].active && IsValidClient(i))
            {
                char name[MAX_NAME_LENGTH];
                GetClientName(i, name, sizeof(name));
                CReplyToCommand(client, "[{olive}AC{default}] Debugging: {darkorange}%s{default} → %s", name, PlayerDebug[i].steamId);
                foundAny = true;
            }
        }
        if (!foundAny)
        {
            CReplyToCommand(client, "[{olive}AC{default}] No active debug targets.");
        }
        CReplyToCommand(client, "[{olive}AC{default}] Usage: {community}sm_ac_debug_player <target|off>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    // "off" disables ALL debug targets
    if (StrEqual(arg, "off", false) || StrEqual(arg, "none", false))
    {
        int count = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (PlayerDebug[i].active)
            {
                PlayerDebug[i].active = false;
                count++;
            }
        }
        CReplyToCommand(client, "[{olive}AC{default}] Debug logging {red}DISABLED{default} for %d player(s).", count);
        return Plugin_Handled;
    }

    int target = FindTarget(client, arg, true);
    if (target == -1) return Plugin_Handled;

    // Toggle: if already debugging this player, disable
    if (PlayerDebug[target].active)
    {
        PlayerDebug[target].active = false;
        char name[MAX_NAME_LENGTH];
        GetClientName(target, name, sizeof(name));
        CReplyToCommand(client, "[{olive}AC{default}] Debug {red}DISABLED{default} for {darkorange}%s{default}.", name);
        return Plugin_Handled;
    }

    // Enable debug on this player — build their unique log file path
    char steamId[32];
    if (!GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId)))
        FormatEx(steamId, sizeof(steamId), "unknown_%d", GetClientUserId(target));

    // Sanitize SteamID for filename: STEAM_0:0:1789052 → STEAM_0_0_1789052
    char safeSteamId[32];
    strcopy(safeSteamId, sizeof(safeSteamId), steamId);
    ReplaceString(safeSteamId, sizeof(safeSteamId), ":", "_");

    // Build path: logs/tfdb_ac/debug_STEAM_0_0_1789052_03_25_2026.log
    char dateStr[32];
    FormatTime(dateStr, sizeof(dateStr), "%m_%d_%Y");

    char logPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logPath, sizeof(logPath),
        "logs/tfdb_ac/debug_%s_%s.log", safeSteamId, dateStr);

    // Store in the enum struct
    PlayerDebug[target].active = true;
    strcopy(PlayerDebug[target].logPath, sizeof(PlayerDebug[].logPath), logPath);
    strcopy(PlayerDebug[target].steamId, sizeof(PlayerDebug[].steamId), steamId);

    // Write header
    char name[MAX_NAME_LENGTH];
    GetClientName(target, name, sizeof(name));

    LogToFile(logPath, "=== Debug started for %s (%s) ===", name, steamId);
    LogToFile(logPath, "Format: cmd=CMDNUM p=PITCH y=YAW atk=ATK1+ATK2 btn=BUTTONS tick=TICKCOUNT");

    CReplyToCommand(client,
        "[{olive}AC{default}] Debug {community}ENABLED{default} for {darkorange}%s{default}. File: debug_%s_%s.log",
        name, safeSteamId, dateStr);
    return Plugin_Handled;
}

// ============================================================================
// Utility Functions
// ============================================================================

bool IsValidClient(int client, bool alive = false)
{
    if (client < 1 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (IsFakeClient(client)) return false;
    if (alive && !IsPlayerAlive(client)) return false;
    return true;
}

float AngleDelta(float p1, float y1, float p2, float y2)
{
    float dp = NormalizeAngle(p2 - p1);
    float dy = NormalizeAngle(y2 - y1);
    return SquareRoot(dp * dp + dy * dy);
}

float NormalizeAngle(float angle)
{
    // Guard against NaN or extreme values that would infinite-loop
    if (angle != angle || angle > 1000000.0 || angle < -1000000.0)
        return 0.0;

    while (angle > 180.0) angle -= 360.0;
    while (angle < -180.0) angle += 360.0;
    return angle;
}

int MaxInt(int a, int b)
{
    return a > b ? a : b;
}

bool HasImmunity(int client)
{
    if (ACImmunityFlag[0] == '\0') return false;

    AdminId admin = GetUserAdmin(client);
    if (admin == INVALID_ADMIN_ID) return false;

    AdminFlag flagBit;
    if (!FindFlagByChar(ACImmunityFlag[0], flagBit)) return false;

    return GetAdminFlag(admin, flagBit);
}

void LogDetection(int client, const char[] type, const char[] format, any ...)
{
    if (ACLogLevel < 1) return;

    char details[512];
    VFormat(details, sizeof(details), format, 4);

    char name[MAX_NAME_LENGTH];
    char steamId[32];
    GetClientName(client, name, sizeof(name));

    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)))
        FormatEx(steamId, sizeof(steamId), "UNKNOWN");

    // Determine confidence tag for this detection type
    char confidence[12];
    if (StrEqual(type, "AntiAim"))
    {
        FormatEx(confidence, sizeof(confidence), "CRITICAL");
    }
    else if (StrEqual(type, "AirblastFacing") || StrEqual(type, "DragSnapback"))
    {
        FormatEx(confidence, sizeof(confidence), "HIGH");
    }
    else if (StrEqual(type, "PerfectTiming") || StrEqual(type, "ConsistentTiming") ||
             StrEqual(type, "PerfectStreak"))
    {
        FormatEx(confidence, sizeof(confidence), "MEDIUM");
    }
    else
    {
        FormatEx(confidence, sizeof(confidence), "LOW");
    }

    // Build daily log path using BuildPath for SM-relative path resolution
    char logPath[PLATFORM_MAX_PATH];
    char dateStr[32];
    FormatTime(dateStr, sizeof(dateStr), "%m_%d_%Y");
    BuildPath(Path_SM, logPath, sizeof(logPath),
        "logs/tfdb_ac/tfdb_ac_%s.log", dateStr);

    // Always log to file at level 1+ — this is the data collection layer.
    // Format: [TIME] [CONFIDENCE] [TYPE] Name (SteamID) | details | score:X
    int score = CalculateScore(client);
    LogToFile(logPath,
        "[%s] [%s] %s (%s) | %s | score:%d",
        confidence, type, name, steamId, details, score);

    // Level 2: print to admin chat
    if (ACLogLevel >= 2)
    {
        PrintToAdmins(
            "[{olive}AC{default}] [{steelblue}%s{default}] [{red}%s{default}] {darkorange}%s{default}: %s",
            confidence, type, name, details);
    }
}

/**
 * Log a full session summary when a player disconnects.
 * This gives admins a single log line per player per session
 * to scan for patterns without reading every individual detection.
 */
void LogSessionSummary(int client)
{
    if (ACLogLevel < 1) return;

    int score = CalculateScore(client);

    // Don't log clean players — keep logs focused
    if (score == 0 &&
        AntiAimDetections[client] == 0 &&
        PerfectTimingDetections[client] == 0)
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    char steamId[32];
    GetClientName(client, name, sizeof(name));

    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)))
        FormatEx(steamId, sizeof(steamId), "UNKNOWN");

    char logPath[PLATFORM_MAX_PATH];
    char dateStr[32];
    FormatTime(dateStr, sizeof(dateStr), "%m_%d_%Y");
    BuildPath(Path_SM, logPath, sizeof(logPath),
        "logs/tfdb_ac/tfdb_ac_%s.log", dateStr);

    LogToFile(logPath,
        "[SESSION] %s (%s) | Score:%d | AA:%d AF:%d DS:%d PT:%d CT:%d Str:%d(%d)",
        name, steamId, score,
        AntiAimDetections[client],
        AirblastFacingDetections[client],
        DragSnapbackDetections[client],
        PerfectTimingDetections[client],
        InhaleExhaleDetections[client],
        CurrentStreak[client],
        PerfectStreakScore[client]);
}

void PrintToAdmins(const char[] format, any ...)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        AdminId admin = GetUserAdmin(i);
        if (admin == INVALID_ADMIN_ID) continue;
        if (!GetAdminFlag(admin, Admin_Ban)) continue;

        // SetGlobalTransTarget makes %t resolve for this specific client's
        // language before VFormat processes the format string.
        SetGlobalTransTarget(i);
        char buffer[512];
        VFormat(buffer, sizeof(buffer), format, 2);
        CPrintToChat(i, buffer);
    }
}
