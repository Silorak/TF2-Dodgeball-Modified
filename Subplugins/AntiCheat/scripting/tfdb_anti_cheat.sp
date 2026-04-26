#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2_stocks>
#include <multicolors>
#include <tfdb_clientcheck>

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
int    ACDecayAmount;
int    ACBanDuration;   // Minutes (0 = perma)
char   ACImmunityFlag[4];

// ============================================================================
// Constants
// ============================================================================

#define PLUGIN_NAME    "TFDB Anti-Cheat"
#define PLUGIN_VERSION "2.2.0"

// Ring buffer depth for angle history.
// Some cheats smooth their angle snaps over multiple frames to defeat
// short-window detectors. A 32-frame window sees through that smoothing.
#define ANGLE_HISTORY   32

// Ring buffer depth for airblast timing samples.
#define TIMING_HISTORY  64

// Perfect airblast timing window. The cheat fires IN_ATTACK2 on the exact
// tick the rocket enters the deflection sphere (128 hu radius * multiplier).
// Expressed as time, converted to ticks at runtime.
#define PERFECT_TIMING_TIME 0.03 // ~2 ticks at 66, ~4 at 128

// Reaction-time floor for ReactTimeFloor detection.
// Default value now exposed as ConVar `tfdb_ac_react_floor_ms` (2026-04-24).
// Lowered default 120 -> 80 after FP audit: expert dodgeball players ANTICIPATE
// the rocket's arrival based on trajectory — "react time" measured from
// rocket-becomes-incoming to airblast regularly dips below 100ms legitimately.
// Psychophysics simple-RT floor is ~100-120ms, but this game measures from the
// moment targeting flips (which happens AFTER the player has already tracked
// the rocket visually), so the effective reaction time includes anticipation.
// Real tick-bot signature is sub-50ms. Kept the constant as a documentation
// anchor; runtime value is `ReactFloorSecs` fed from the ConVar.
#define REACT_FLOOR_DEFAULT_MS  80
#define REACT_FLOOR_STREAK_NEEDED 3      // consecutive sub-floor deflects before scoring
#define REACT_FLOOR_STREAK_WINDOW 10.0   // seconds; streak resets if gap exceeds this

float ReactFloorSecs = 0.080;  // live value, updated from ConVar hook
ConVar CvarReactFloorMs;

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
int   DragSnapbackDetections[MAXPLAYERS + 1];  // Post-control-delay 3-angle snapback (TFDB-specific)
int   AirblastFacingDetections[MAXPLAYERS + 1]; // Airblast succeeded while not facing rocket
int   AirblastFacingStreak[MAXPLAYERS + 1];     // Consecutive not-facing deflects; scored only at streak >=3
int   OneTickM2Detections[MAXPLAYERS + 1];      // IN_ATTACK2 pressed for exactly 1 tick (cheat signature)
int   OneTickM2Streak[MAXPLAYERS + 1];          // Consecutive 1-tick presses; scored at streak >=3
int   M2PressStartTick[MAXPLAYERS + 1];         // Tick when IN_ATTACK2 began; used to measure hold duration
float JoinTime[MAXPLAYERS + 1];                 // GetEngineTime() at OnClientPutInServer; 3s warmup gates ReactTimeFloor

// Reaction-time floor tracking (physiological floor ~120ms per the
// psychophysics literature). When a rocket becomes targeted at a client,
// record the moment. If they deflect within 120ms of that moment, it's
// below what any human can visually react to.
float LastRocketIncomingTime[MAXPLAYERS + 1];   // Seconds (GetEngineTime) when any rocket last targeted this client
int   ReactTimeFloorDetections[MAXPLAYERS + 1]; // Count of sub-floor-deflect STREAKS (not individual hits; streak-gated 2026-04-24)
int   ReactFloorStreakCount[MAXPLAYERS + 1];    // Current consecutive sub-floor deflect count (resets if >10s between hits)
float ReactFloorStreakLastTime[MAXPLAYERS + 1]; // GetEngineTime() of the last sub-floor deflect
int   AntiAimDetections[MAXPLAYERS + 1];       // m_angEyeAngles pitch outside [-89, 89]
int   SnapAimDetections[MAXPLAYERS + 1];       // Large angle snap coinciding with airblast
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

// SnapAim tracking — detects large angle jumps around airblast ticks
float PreSnapAngles[MAXPLAYERS + 1][3];  // Angles before the snap started
bool  SnapPending[MAXPLAYERS + 1];       // We saw a big snap, waiting for return
int   SnapStartTick[MAXPLAYERS + 1];     // When the snap happened
bool  SnapHadAirblast[MAXPLAYERS + 1];   // Was ATK2 pressed during/near the snap

// Previous tick data
float PrevAngles[MAXPLAYERS + 1][3];
int   PrevButtons[MAXPLAYERS + 1];

// Raw (pre-modification) angles from OnPlayerRunCmdPre
float RawAngles[MAXPLAYERS + 1][3];
bool  RawAnglesValid[MAXPLAYERS + 1];

// Cached admin-immunity state — HasImmunity() was a hot-path call (3x per
// client per tick across OnPlayerRunCmd*/EvaluatePlayer) that ran
// GetUserAdmin + FindFlagByChar + GetAdminFlag every invocation. Now resolved
// once at OnClientPostAdminCheck / cvar-change and read as an array lookup.
bool      g_ClientImmune[MAXPLAYERS + 1];
AdminFlag g_ImmunityFlagBit;
bool      g_ImmunityFlagValid = false;

// Cached m_angEyeAngles sendprop offset — resolved once at OnPluginStart so
// the per-tick AntiAim check skips the HasEntProp + GetEntPropFloat string
// lookups. -1 = lookup failed (gate skips check).
// (deprecated — Tier-1 perf attempt to cache m_angEyeAngles offset failed:
//  FindSendPropInfo returned -1 in production. Reverted 2026-04-26 to use
//  HasEntProp + GetEntPropFloat directly. Variable kept commented for the
//  next contributor to know not to retry the same path without a real fix.)
// int g_EyeAnglesPropOffset = -1;

// Server tick rate, cached at OnMapStart so we can rate-limit per-tick spam
// without calling GetTickInterval()/RoundToCeil in hot paths.
int g_TicksPerSecond = 66;

// Per-client cooldown for AntiAim detection — cheats holding AntiAim would
// otherwise trigger LogDetection (synchronous LogToFile) every tick.
int g_LastAntiAimTick[MAXPLAYERS + 1];

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

// Global "collect all" mode — when true, every player who joins gets debug-logged
// automatically, and logging persists across map changes until disabled with "off".
bool CollectAll = false;

// ============================================================================
// ConVars
// ============================================================================

ConVar CvarEnabled;
ConVar CvarLogLevel;
ConVar CvarActionThreshold;
ConVar CvarAction;
ConVar CvarSilentThreshold;
ConVar CvarDecayInterval;
ConVar CvarDecayAmount;
ConVar CvarImmunityFlag;
ConVar CvarAdminHud;
ConVar CvarBanDuration;  // Minutes (0 = permanent). Default 1440 = 24h.

// Admin HUD synchronizer — persistent overlay for admins showing live scores
Handle HudSync = null;

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo = {
    name        = PLUGIN_NAME,
    author      = "Silorak",
    description = "Dodgeball Anti Cheat",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/Silorak/TF2-Dodgeball"
};

// ============================================================================
// Plugin Lifecycle
// ============================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("TFDB_GetRocketSpeed");
    MarkNativeAsOptional("TFDB_GetRocketClass");
    MarkNativeAsOptional("TFDB_GetRocketClassControlDelay");
    MarkNativeAsOptional("TFDB_FindRocketByEntity");
    MarkNativeAsOptional("TFDB_GetRocketTarget");
    MarkNativeAsOptional("TFDB_GetRocketDeflections");
    return APLRes_Success;
}

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

    // Total accumulated score needed to trigger action.
    // Raised 30 -> 60 on 2026-04-24 after FP audit: legit skilled players
    // routinely accumulated 25-35 in a single session under the old threshold.
    // With SnapAim/PerfectStreak/ConsistentTiming zeroed AND threshold=60,
    // a clean player never crosses; a real cheater tripping signature-level
    // detectors (AntiAim, ReactTimeFloor streak, OneTickM2) still crosses fast.
    CvarActionThreshold = CreateConVar(
        "tfdb_ac_action_threshold", "60",
        "Total detection score needed before taking action on a player.",
        _, true, 5.0, true, 200.0
    );

    // What to do when threshold is reached: 0=log, 1=kick, 2=ban
    CvarAction = CreateConVar(
        "tfdb_ac_action", "1",
        "Action on threshold: 0=log only, 1=kick, 2=ban.",
        _, true, 0.0, true, 2.0
    );

    // Individual detection type thresholds (how many raw hits = 1 score point).
    // Raised 3 -> 5 (2026-04-24) to require stronger evidence before silent-aim
    // detectors (AntiAim/AirblastFacing/DragSnapback/SnapAim) contribute score.
    CvarSilentThreshold = CreateConVar(
        "tfdb_ac_silent_hits", "5",
        "Silent aim raw detections needed per score point.",
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

    // ReactTimeFloor threshold (ms). Default 80 — expert dodgeball anticipation
    // legitimately dips below 100ms. See tfdb_anti_cheat.sp:50-60 rationale.
    // Detection is streak-gated (3 consecutive sub-floor deflects within 10s).
    CvarReactFloorMs = CreateConVar(
        "tfdb_ac_react_floor_ms", "80",
        "Reaction-time floor (ms). Deflects faster than this contribute to a streak; streak of 3 within 10s scores.",
        _, true, 30.0, true, 200.0
    );
    ReactFloorSecs = CvarReactFloorMs.FloatValue / 1000.0;
    CvarReactFloorMs.AddChangeHook(OnReactFloorMsChanged);

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

    // Ban duration when action=2. Minutes. 0 = permanent.
    // Default 1440 (24h) — safer than permanent on automated detection.
    CvarBanDuration = CreateConVar(
        "tfdb_ac_ban_duration", "1440",
        "Ban duration in minutes when action=2 (ban). 0 = permanent.",
        _, true, 0.0, true, 525600.0  // max 1 year
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
    CvarDecayAmount.AddChangeHook(OnConVarChanged);
    CvarBanDuration.AddChangeHook(OnConVarChanged);
    CvarImmunityFlag.AddChangeHook(OnConVarChanged);

    // Initial cache population
    CacheAllConVars();
    RefreshImmunityFlag();

    // Cache tick rate immediately so late-load before first map change has a
    // valid value. OnMapStart re-populates with the actual server rate; this
    // covers the gap where OnPlayerRunCmd could fire before OnMapStart on
    // late plugin load. (Audit finding 2026-04-26.)
    g_TicksPerSecond = RoundToCeil(1.0 / GetTickInterval());

    // Create HUD synchronizer for admin overlay
    HudSync = CreateHudSynchronizer();

    // Hook all currently connected clients (late load support)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
            // On late-load, OnClientPostAdminCheck won't fire for already-
            // authed clients, so populate the immunity cache directly.
            RefreshClientImmunity(i);
        }
    }

    RegAdminCmd("sm_ac_status", Command_Status, ADMFLAG_BAN, "Show anti-cheat status for all players.");
    RegAdminCmd("sm_ac_reset", Command_Reset, ADMFLAG_ROOT, "Reset detection counters for a player.");
    RegAdminCmd("sm_ac_debug_player", Command_DebugPlayer, ADMFLAG_ROOT, "Toggle debug CSV logging. No args = collect all (toggle). With player = single target.");

    // Late-load: if the plugin is loaded mid-map (sm plugins load), OnMapStart
    // won't fire until the next map change. Decay + HUD timers would never
    // fire, leaving scores accumulating forever. Manually invoke OnMapStart
    // to create the timers right now when we detect we're already in a map.
    char mapName[64];
    if (GetCurrentMap(mapName, sizeof(mapName)) && mapName[0] != '\0') {
        OnMapStart();
    }
}

// ============================================================================
// Map Lifecycle
// ============================================================================

public void OnMapStart()
{
    // Cache server tick rate — used by per-client AntiAim rate-limit so we
    // don't call GetTickInterval() in OnPlayerRunCmd.
    g_TicksPerSecond = RoundToCeil(1.0 / GetTickInterval());

    // Recreate repeating timers — TIMER_FLAG_NO_MAPCHANGE kills them on map end.
    CreateTimer(CvarDecayInterval.FloatValue, Timer_DecayScores, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_AdminHud, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnPluginEnd()
{
    // Release the HUD synchronizer handle. SM will clean on unload but being
    // explicit avoids handle-table pressure during dev iteration.
    if (HudSync != null)
    {
        delete HudSync;
        HudSync = null;
    }
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
// Record moment each rocket becomes targeted at a client. Epoch for the
// ReactTimeFloor detection — a legit player needs >120ms from this moment
// before they can physically react and press airblast.
public void TFDB_OnRocketCreated(int index, int entity)
{
    if (!ACEnabled) return;
    int target = TFDB_GetRocketTarget(index);
    if (target > 0 && target <= MaxClients && IsValidClient(target))
    {
        LastRocketIncomingTime[target] = GetEngineTime();
    }
}

// Runs just BEFORE a deflect completes. The new target is the player the
// rocket is re-assigned to; they become the reaction-window epoch.
public Action TFDB_OnRocketDeflectPre(int index, int entity, int owner, int &newTarget)
{
    if (ACEnabled && newTarget > 0 && newTarget <= MaxClients && IsValidClient(newTarget))
    {
        LastRocketIncomingTime[newTarget] = GetEngineTime();
    }
    return Plugin_Continue;
}

// Hook TFDB deflect forward for precise rocket-player attribution.
// This is far more accurate than scanning entities in PreThink because
// TFDB tells us exactly WHO deflected WHICH rocket at WHAT speed.
public void TFDB_OnRocketDeflect(int index, int entity, int owner)
{
    if (!ACEnabled || !IsValidClient(owner))
        return;

    // Admin immunity: without this gate, detection counters would accumulate
    // on immune admins — showing them on the admin HUD and polluting their
    // decay state. Gate every downstream detection on this single check.
    if (HasImmunity(owner))
        return;

    // ReactTimeFloor: sub-floor deflect detection. Streak-gated + join-warmup
    // gated. Streak gate avoids single-shot anticipation FPs; warmup gate
    // ignores the first 3s after a player joins (their first deflect can race
    // with the spawn-tick targeting flip and produce a falsely-low elapsed).
    if (LastRocketIncomingTime[owner] > 0.0 &&
        (GetEngineTime() - JoinTime[owner]) > 3.0)
    {
        float now = GetEngineTime();
        float elapsed = now - LastRocketIncomingTime[owner];
        if (elapsed < ReactFloorSecs && elapsed > 0.0)
        {
            // Is this hit part of an active streak?
            if (ReactFloorStreakCount[owner] > 0 &&
                (now - ReactFloorStreakLastTime[owner]) <= REACT_FLOOR_STREAK_WINDOW)
            {
                ReactFloorStreakCount[owner]++;
            }
            else
            {
                ReactFloorStreakCount[owner] = 1;  // start fresh streak
            }
            ReactFloorStreakLastTime[owner] = now;

            LogDetection(owner, "ReactTimeFloor",
                "elapsed=%.3fs (floor=%.3fs) streak=%d/%d",
                elapsed, ReactFloorSecs,
                ReactFloorStreakCount[owner], REACT_FLOOR_STREAK_NEEDED);

            // Only score when streak hits the threshold — sustained sub-floor
            // pattern, not a one-off anticipation. Reset streak after scoring
            // so continued cheating continues to score, but in multiples of N.
            if (ReactFloorStreakCount[owner] >= REACT_FLOOR_STREAK_NEEDED)
            {
                ReactTimeFloorDetections[owner]++;
                LogDetection(owner, "ReactTimeFloorStreakScored",
                    "streak of %d sub-floor deflects in <%.0fs — SCORED",
                    ReactFloorStreakCount[owner], REACT_FLOOR_STREAK_WINDOW);
                ReactFloorStreakCount[owner] = 0;
            }
        }
    }

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

    // Estimate ticks margin (conservative lower bound since rocket curve
    // makes actual travel longer than straight-line). Kept for downstream
    // ConsistentTiming analysis — its VARIANCE is meaningful even when the
    // absolute value is biased low.
    //
    // NOTE: do NOT add a "PerfectTiming" per-deflect check based on
    // `RoundToFloor(dist / (speed * tickInterval)) == 0` — the straight-line
    // distance makes this return 0 for any close deflect, so it fires on
    // every legitimate close-range airblast. Streak and ConsistentTiming
    // detections cover the same pattern more reliably.
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

    // Analyze timing consistency with enough samples
    if (TimingSamples[owner] >= 8)
    {
        AnalyzeAirblastTiming(owner, ticksMargin);
    }

    // ------------------------------------------------------------------
    // AIRBLAST-WITHOUT-FACING: Detects tick-choking silent-aim.
    //
    // Tick-choking auto-airblast works by:
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
    // same tick the deflection processes. Streak requirement (below) plus
    // ConsistentTiming correlation make this strong evidence.
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
            // TICK-CHOKING CHEAT: Never faces rocket in SENT ticks. The
            //   facing angle was on a CHOKED tick, which doesn't appear in
            //   our history because the cheat's anti-detection smoothing
            //   erased it. All visible ticks show the player's REAL view.
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

            // If NO tick in the window faced the rocket, this is
            // tick-choking silent-aim. The airblast succeeded
            // (TFDB_OnRocketDeflect fired) but the player's visible angles
            // never pointed at the rocket.
            //
            // Tuning: a single not-facing deflect can happen legit on
            // glance-deflects, quick camera flicks, or rockets entering
            // from behind in FOV dead zones. Require a STREAK of 3
            // consecutive not-facing deflects before counting — this is
            // how a real tick-choking cheat looks (every deflect is silent),
            // while a legit player breaks the streak with a normal deflect.
            if (!facedRocket)
            {
                AirblastFacingStreak[owner]++;
                if (AirblastFacingStreak[owner] >= 3)
                {
                    AirblastFacingDetections[owner]++;
                    LogDetection(owner, "AirblastFacing",
                        "streak=%d bestDelta=%.1f eyeAng=(%.1f,%.1f) rocketAng=(%.1f,%.1f) dist=%.0f",
                        AirblastFacingStreak[owner],
                        bestDelta, currentAngles[0], currentAngles[1],
                        angleToRocket[0], angleToRocket[1], dist);
                }
            }
            else
            {
                // Faced rocket this time → streak broken.
                AirblastFacingStreak[owner] = 0;
            }
        }
    }

    // ------------------------------------------------------------------
    // CONTROL-DELAY-AWARE DETECTION: 3-angle snapback via TFDB control delay (blind window).
    //
    // Snap-airblast-restore cheats do this:
    //   1. Player's real view = angle A (PreDeflect)
    //   2. Cheat snaps to rocket = angle B (Deflect) + fires IN_ATTACK2
    //   3. Cheat's anti-detection smoothing lerps back within 1-3 ticks
    //   4. After control delay expires, player's view = angle C (PostDrag) ≈ A
    //
    // A LEGIT DRAGGER does this:
    //   1. Player faces rocket = angle A ≈ B (already looking at it)
    //   2. Airblasts = angle B (Deflect)
    //   3. Drags mouse to aim at enemy target during control delay (blind window)
    //   4. After control delay expires = angle C ≠ A, ≠ B (new target direction)
    //
    // OLD (BROKEN) DETECTION: |B - C| > 45°
    //   → Flags legit draggers (who move from B to C)
    //   → Misses cheaters (whose C ≈ A, making |B - C| ≈ |B - A|)
    //
    // NEW (CORRECT) DETECTION: |C - A| < threshold AND |B - A| > 15°
    //   → The cheat snapped FROM A to B (large departure) then returned
    //     to A after control delay (near-perfect return = snapback)
    //   → Legit draggers have A ≈ B (no departure) so |B - A| < 15°
    //     and C is somewhere new → never triggers
    //
    // We need 3 angles: A (pre-deflect), B (at deflect), C (post-drag).
    // A is pulled from AngleHistory — we look 4 ticks back from the
    // current tick to get the angle BEFORE the cheat started snapping.
    // B is GetClientEyeAngles at the moment of TFDB_OnRocketDeflect.
    // C is GetClientEyeAngles after the control delay timer fires.
    // ------------------------------------------------------------------
    int rocketClass = TFDB_GetRocketClass(index);
    float dragDuration = TFDB_GetRocketClassControlDelay(rocketClass);

    if (dragDuration > 0.0)
    {
        // Angle B: where the player is looking RIGHT NOW at deflection time.
        // If the cheat is snapping on airblast, this is the snapped angle
        // (toward rocket). If legit, this is where they were naturally aiming.
        float deflectAngles[3];
        GetClientEyeAngles(owner, deflectAngles);

        // Angle A: where the player was looking BEFORE the deflection.
        // We go 4 ticks back in AngleHistory to get the pre-snap angle.
        // The cheat snaps on the same tick as the airblast, so t-4 should
        // be before any anti-detection lerp-back began.
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
 * Fires after TFDB's control delay (blind window) expires. Implements 3-angle snapback detection.
 *
 * Angles:
 *   A = PreDeflect (4 ticks before airblast — before cheat snap)
 *   B = Deflect    (at airblast — potentially cheat-snapped)
 *   C = PostDrag   (now, after control delay — where player is looking)
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

    // Angle C: where the player is looking NOW (after control delay)
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
    // 2. returnToOrigin < 8°: after control delay, the cheat has snapped back
    //    to within 8° of where it was before. A legit dragger has moved to
    //    a completely new angle (their drag target), so returnToOrigin is large.
    //
    // The 8° return threshold is generous — cheat angle-smoothing typically
    // returns to within ~0.1°. We use 8° to account for natural mouse drift
    // during the control delay period while the cheat is "returned".
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
    ACDecayAmount = CvarDecayAmount.IntValue;
    ACBanDuration = CvarBanDuration.IntValue;
    CvarImmunityFlag.GetString(ACImmunityFlag, sizeof(ACImmunityFlag));
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    CacheAllConVars();
    // Immunity flag may have changed — re-resolve and recompute every client.
    RefreshImmunityFlag();
    RefreshAllClientImmunity();
}

/**
 * Resolve the immunity flag once after configs have loaded. CacheAllConVars
 * runs in OnPluginStart before AutoExecConfig has applied the .cfg file, so
 * we re-resolve here to pick up the on-disk flag value.
 */
public void OnConfigsExecuted()
{
    RefreshImmunityFlag();
    RefreshAllClientImmunity();
}

/**
 * Cache immunity once per client, after their admin record is loaded.
 * Caveat: if admins are reloaded mid-session (sm_reloadadmins) the cached
 * value goes stale until reconnect. Acceptable trade-off for this plugin.
 */
public void OnClientPostAdminCheck(int client)
{
    RefreshClientImmunity(client);
}

/** Live-update the cached ReactTimeFloor seconds when the ms cvar changes. */
public void OnReactFloorMsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ReactFloorSecs = convar.FloatValue / 1000.0;
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
    JoinTime[client] = GetEngineTime();  // ReactTimeFloor warmup window
    SDKHook(client, SDKHook_PreThink, OnPreThink);

    // Auto-enable debug logging if global collect mode is on
    if (CollectAll && !IsFakeClient(client))
    {
        // Delay so SteamID is available (not ready in OnClientPutInServer)
        CreateTimer(3.0, Timer_AutoDebugPlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
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
    g_ClientImmune[client] = false;
    g_LastAntiAimTick[client] = 0;
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
    AirblastFacingStreak[client]     = 0;
    AntiAimDetections[client]        = 0;
    SnapAimDetections[client]        = 0;
    OneTickM2Detections[client]      = 0;
    OneTickM2Streak[client]          = 0;
    M2PressStartTick[client]         = 0;
    ReactTimeFloorDetections[client] = 0;
    ReactFloorStreakCount[client]    = 0;
    ReactFloorStreakLastTime[client] = 0.0;
    LastRocketIncomingTime[client]   = 0.0;
    PerfectStreakScore[client]        = 0;
    LastDetectionTime[client]        = 0.0;

    TimingFlagged[client]       = false;
    TimingCooldown[client]      = 0;
    CurrentStreak[client]       = 0;
    LastStreakMilestone[client]  = 0;

    LastAirblastTime[client]  = 0.0;
    LastAirblastTick[client]  = 0;
    JustAirblasted[client]    = false;

    PreSnapAngles[client][0] = 0.0;
    PreSnapAngles[client][1] = 0.0;
    PreSnapAngles[client][2] = 0.0;
    SnapPending[client]      = false;
    SnapStartTick[client]    = 0;
    SnapHadAirblast[client]  = false;

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
    // Skip snap-based detections this tick to avoid false positives.
    // (E.g. PvB's aim override or Guardian's target-lock rotate angles.)
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

    // Read pitch via HasEntProp + GetEntPropFloat — the original API.
    // The Tier-1 perf attempt to use FindSendPropInfo("CTFPlayer",
    // "m_angEyeAngles") + GetEntDataFloat returned -1 in production
    // (m_angEyeAngles isn't directly in the CTFPlayer SendTable; SourceMod's
    // HasEntProp/GetEntPropFloat resolve through datamap fallbacks that
    // FindSendPropInfo doesn't). Reverted 2026-04-26 — detection working
    // beats the ~3168 string-lookups/sec "saving."
    if (HasEntProp(client, Prop_Send, "m_angEyeAngles"))
    {
        float eyePitch = GetEntPropFloat(client, Prop_Send, "m_angEyeAngles", 0);
        if (eyePitch > 89.1 || eyePitch < -89.1)
        {
            // Rate-limit: a cheat holding AntiAim would otherwise drive
            // LogDetection -> LogToFile (synchronous disk write) every tick
            // AND inflate the score by ~66/sec. Cap at one detection per
            // second per client. Score weight stays meaningful; log spam dies.
            if ((currentTick - g_LastAntiAimTick[client]) >= g_TicksPerSecond)
            {
                g_LastAntiAimTick[client] = currentTick;
                AntiAimDetections[client]++;
                LogDetection(client, "AntiAim",
                    "m_angEyeAngles[0]=%.2f (valid range [-89, 89])",
                    eyePitch);
            }
        }
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
        M2PressStartTick[client] = currentTick;
    }

    // ------------------------------------------------------------------
    // DETECTION: 1-tick IN_ATTACK2 press
    //
    // Common TF2 auto-airblast implementations set IN_ATTACK2 for exactly
    // one tick per fire; human players physically hold M2 for 6-15 ticks
    // (~90-220ms) before releasing it. The fingerprint is robust — reviewed
    // public auto-airblast implementations do not mask it by holding the
    // button across ticks.
    //
    // Requires a streak of 3 consecutive 1-tick presses to fire. A legit
    // player tap can produce a 1-tick press occasionally (hardware debounce
    // or very quick release); three-in-a-row is cheat-only behavior.
    // ------------------------------------------------------------------
    if (!isAttacking && wasAttacking)
    {
        int holdDuration = currentTick - M2PressStartTick[client];
        if (holdDuration <= 1)
        {
            OneTickM2Streak[client]++;
            if (OneTickM2Streak[client] >= 3)
            {
                OneTickM2Detections[client]++;
                LogDetection(client, "OneTickM2",
                    "streak=%d (M2 held for %d tick, human floor ~6 ticks)",
                    OneTickM2Streak[client], holdDuration);
            }
        }
        else
        {
            OneTickM2Streak[client] = 0;
        }
    }

    // ------------------------------------------------------------------
    // DETECTION: SnapAim — large sudden angle change around airblast
    //
    // Silent aim snaps the usercmd angles toward the rocket for the
    // airblast frame, then returns to the original view direction.
    // A real cheat modifies angles CLIENT-SIDE so the snap appears in
    // the raw usercmd (visible in OnPlayerRunCmdPre).
    //
    // Signature:
    //   1. Large angle delta (>25°) in a single tick
    //   2. ATK2 pressed during or within 3 ticks of the snap
    //   3. Angles return to within 10° of pre-snap position within 8 ticks
    // ------------------------------------------------------------------

    float angleDelta = AngleDelta(PrevAngles[client][0], PrevAngles[client][1],
        angles[0], angles[1]);

    // Check if angles returned to pre-snap position (confirms snapback)
    if (SnapPending[client])
    {
        int ticksSinceSnap = currentTick - SnapStartTick[client];

        // Track if airblast happened near the snap
        if (isAttacking || wasAttacking)
            SnapHadAirblast[client] = true;

        float returnDelta = AngleDelta(PreSnapAngles[client][0], PreSnapAngles[client][1],
            angles[0], angles[1]);

        if (returnDelta < 10.0 && SnapHadAirblast[client] && ticksSinceSnap >= 2)
        {
            // Confirmed: large snap → airblast → return to origin
            SnapAimDetections[client]++;
            LogDetection(client, "SnapAim",
                "preSnap=(%.1f,%.1f) current=(%.1f,%.1f) return=%.1f ticks=%d",
                PreSnapAngles[client][0], PreSnapAngles[client][1],
                angles[0], angles[1], returnDelta, ticksSinceSnap);
            SnapPending[client] = false;
        }
        else if (ticksSinceSnap > 8)
        {
            // Window expired — probably a legit flick, not a snapback
            SnapPending[client] = false;
        }
    }

    // Detect new snap: large angle change in one tick.
    // Require at least 12 samples so a late-joining client doesn't trigger
    // on the first real tick vs zero-initialized PrevAngles. The old guard
    // `PrevAngles != 0.0` was fragile (0.0 is a legit horizontal pitch).
    //
    // Threshold raised 25→35°: skilled dodgeball pros routinely flick 40-60°,
    // and 25° was generating false positives. 35° keeps detection strong
    // against cheat silent-aim (which snaps ~90° to rocket) while giving
    // room for legit fast flicks.
    //
    // Also gate on anglesModifiedByPlugin — if another subplugin (PvB aim
    // override, Guardian target-lock) rotated angles this tick, the snap
    // is not client-side and we must not flag it.
    if (angleDelta > 35.0 && !SnapPending[client] &&
        !anglesModifiedByPlugin &&
        AngleSamples[client] >= 12)
    {
        PreSnapAngles[client][0] = PrevAngles[client][0];
        PreSnapAngles[client][1] = PrevAngles[client][1];
        PreSnapAngles[client][2] = PrevAngles[client][2];
        SnapPending[client] = true;
        SnapStartTick[client] = currentTick;
        SnapHadAirblast[client] = (isAttacking || wasAttacking);
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

    // PerfectTiming per-airblast check REMOVED — see TFDB_OnRocketDeflect
    // for rationale. Timing history is still recorded here for the
    // ConsistentTiming variance analysis, which uses the distribution
    // shape (not the individual margin=0 flag).
}

// ============================================================================
// Detection Helpers
// ============================================================================

/**
 * Check for the silent aim snapback pattern.
 *
 * The cheat chokes a tick with silent angles, snaps to a rocket, fires
 * IN_ATTACK2, then lerps the visible viewangles back toward the original
 * aim over 2-3 frames to avoid per-frame delta thresholds.
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
    // Only margin 0-1 counts as "perfect" for streaks. Margin 2 is
    // achievable by good dodgeball players and inflates streaks.
    if (ticksMargin <= 1)
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
 * Calculate the weighted score for a player from raw detection counts.
 *
 * Confidence tiers (reflected in the weights below):
 * - AntiAim, ReactTimeFloor: CRITICAL — physiological / engine-level
 *   impossibilities. Zero-FP by design. Do not decay.
 * - OneTickM2: HIGH — free-paste cheat fingerprint, streak-gated.
 * - DragSnapback, AirblastFacing: HIGH — specific behavioral signatures,
 *   streak-gated for FP reduction.
 * - SnapAim: MEDIUM — tuned (35° threshold + plugin-modified angle gate)
 *   but high-DPI flicks can still false-positive.
 * - ConsistentTiming, PerfectStreak: MEDIUM — auto-airblast timing
 *   regularity; legit chain play can mimic briefly.
 */
int CalculateScore(int client)
{
    int score = 0;

    // =====================================================================
    // SCORE WEIGHTS — tuned 2026-04-24 after FP audit on production logs
    // (50% of skilled players were getting auto-kicked in ~90 min sessions).
    //
    // KEEP at full weight (signature-level, near-zero FP):
    //   AntiAim, AirblastFacing, DragSnapback, OneTickM2, ReactTimeFloor
    //
    // ZEROED (kept firing + logged for tuning, but contribute 0 score):
    //   SnapAim        — fires on every natural deflect aim-correction
    //   ConsistentTiming (InhaleExhaleDetections) — gameplay enforces
    //                     tight timing; low variance is skill, not a bot
    //   PerfectStreak  — routine 6+ streaks are warmup, not evidence
    //
    // If you have strong evidence a specific cheat trips one of the zeroed
    // detectors but NOT the signature-level ones, re-enable by restoring the
    // multiplier on its own line (leave the rest zero). See the AC wiki page
    // `subplugins/AntiCheat.md` for the full rationale.
    // =====================================================================

    // CRITICAL: AntiAim — m_angEyeAngles pitch outside [-89, 89]
    // Zero false positive rate. Does not decay.
    score += AntiAimDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 5;

    // HIGH: Tick-choking silent-aim detection via facing check
    score += AirblastFacingDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 4;

    // HIGH: 3-angle drag snapback (return-to-origin after control delay)
    score += DragSnapbackDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 4;

    // DISABLED: SnapAim — every natural dodgeball deflect is a snap-to-target
    // then re-correction; detector can't distinguish from silent aim.
    score += SnapAimDetections[client] / MaxInt(1, ACSilentHitsPerPoint) * 0;

    // DISABLED: ConsistentTiming — the airblast window is ~2 ticks wide BY DESIGN,
    // so skilled players naturally cluster at low variance. A real tick-bot already
    // trips ReactTimeFloor harder; this adds no marginal signal.
    score += InhaleExhaleDetections[client] * 0;

    // DISABLED: PerfectStreak — 6-deflect streaks are a warmup on any competitive
    // server. Real cheats show ReactTimeFloor and OneTickM2 first.
    score += PerfectStreakScore[client] * 0;

    // HIGH: 1-tick IN_ATTACK2 signature (free-paste cheat fingerprint).
    // Every detection already requires a 3-deep streak before scoring, so
    // full weight (6) is safe; false-positive rate is near zero.
    score += OneTickM2Detections[client] * 6;

    // CRITICAL: ReactTimeFloor — deflect faster than human anticipation floor.
    // Weight reduced 8 -> 5 because ReactTimeFloor is now streak-gated: a
    // SINGLE sub-floor deflect no longer counts (expert anticipation can dip
    // sub-floor briefly). 3 sub-floor deflects within 10s is the real signal.
    score += ReactTimeFloorDetections[client] * 5;

    return score;
}

void EvaluatePlayer(int client)
{
    // Only evaluate every ~1 second of ticks to avoid spam.
    // Use the cached g_TicksPerSecond (populated in OnMapStart) instead of
    // recomputing 1.0/GetTickInterval() every tick — this runs from
    // OnPlayerRunCmd for every player on every tick, so the math adds up.
    if (GetGameTickCount() % g_TicksPerSecond != 0) return;

    int score = CalculateScore(client);

    if (score >= ACActionThreshold)
    {
        TakeAction(client, score);
    }
}

void TakeAction(int client, int score)
{
    // Re-check immunity at ACTION time, not just at DETECTION time. The admin flag
    // cvar (tfdb_ac_immunity_flag) or the client's admin flags may have changed
    // between the initial detection and the threshold crossing. Without this
    // check, an admin who gained their flag mid-session could still be auto-kicked
    // or auto-banned on stale score accumulated before the flag was granted.
    if (HasImmunity(client))
    {
        ResetClientState(client);
        return;
    }

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
        "[ACTION] %s (%s) Score:%d | AA:%d AF:%d DS:%d SA:%d PT:%d CT:%d Str:%d(%d) | action:%d",
        name, steamId, score,
        AntiAimDetections[client],
        AirblastFacingDetections[client],
        DragSnapbackDetections[client],
        SnapAimDetections[client],
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
            // Use configured ban duration instead of hardcoded 0 (permanent).
            // Default cvar value is 1440 (24h) — safer for automated AC.
            BanClient(client, ACBanDuration, BANFLAG_AUTHID, reason, reason);
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
        SnapAimDetections[client]        = MaxInt(0, SnapAimDetections[client] - decay);
        OneTickM2Detections[client]      = MaxInt(0, OneTickM2Detections[client] - decay);

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
    if (HudSync == null) return Plugin_Continue;
    if (!CvarAdminHud.BoolValue) return Plugin_Continue;

    // Build the HUD text once, then send to all admins
    char hudText[768];
    hudText[0] = '\0';
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
        detectors[0] = '\0';
        char tmp[32];

        if (AntiAimDetections[i] > 0)
        {
            FormatEx(tmp, sizeof(tmp), " AA:%d", AntiAimDetections[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }
        if (AirblastFacingDetections[i] > 0)
        {
            FormatEx(tmp, sizeof(tmp), " AF:%d", AirblastFacingDetections[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }
        if (SnapAimDetections[i] > 0)
        {
            FormatEx(tmp, sizeof(tmp), " SA:%d", SnapAimDetections[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }
        if (DragSnapbackDetections[i] > 0)
        {
            FormatEx(tmp, sizeof(tmp), " DS:%d", DragSnapbackDetections[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }
        if (PerfectTimingDetections[i] > 0)
        {
            FormatEx(tmp, sizeof(tmp), " PT:%d", PerfectTimingDetections[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }
        if (InhaleExhaleDetections[i] > 0)
        {
            FormatEx(tmp, sizeof(tmp), " CT:%d", InhaleExhaleDetections[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }
        if (PerfectStreakScore[i] > 0 || CurrentStreak[i] >= 6)
        {
            FormatEx(tmp, sizeof(tmp), " Str:%d(%d)", CurrentStreak[i], PerfectStreakScore[i]);
            StrCat(detectors, sizeof(detectors), tmp);
        }

        // Color-code the score in the HUD by threshold proximity
        // Score text goes from white → yellow → red as it approaches action threshold
        char hudEntry[128];
        FormatEx(hudEntry, sizeof(hudEntry), "%s [%d]%s\n", name, score, detectors);
        StrCat(hudText, sizeof(hudText), hudEntry);

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
                SnapAimDetections[i],
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

// Helper: enable debug logging on a single client. Returns true if newly enabled.
bool EnableDebugOnClient(int target)
{
    if (PlayerDebug[target].active) return false;  // Already active
    if (IsFakeClient(target)) return false;

    char steamId[32];
    if (!GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId)))
        FormatEx(steamId, sizeof(steamId), "unknown_%d", GetClientUserId(target));

    char safeSteamId[32];
    strcopy(safeSteamId, sizeof(safeSteamId), steamId);
    ReplaceString(safeSteamId, sizeof(safeSteamId), ":", "_");

    char dateStr[32];
    FormatTime(dateStr, sizeof(dateStr), "%m_%d_%Y");

    char logPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, logPath, sizeof(logPath),
        "logs/tfdb_ac/debug_%s_%s.log", safeSteamId, dateStr);

    PlayerDebug[target].active = true;
    strcopy(PlayerDebug[target].logPath, sizeof(PlayerDebug[].logPath), logPath);
    strcopy(PlayerDebug[target].steamId, sizeof(PlayerDebug[].steamId), steamId);

    char name[MAX_NAME_LENGTH];
    GetClientName(target, name, sizeof(name));
    LogToFile(logPath, "=== Debug started for %s (%s) ===", name, steamId);
    LogToFile(logPath, "Format: cmd=CMDNUM p=PITCH y=YAW atk=ATK1+ATK2 btn=BUTTONS tick=TICKCOUNT");

    return true;
}

// Timer callback for auto-enabling debug on newly joined players (collect-all mode)
public Action Timer_AutoDebugPlayer(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !TFDB_IsRealHuman(client)) return Plugin_Stop;
    if (!CollectAll) return Plugin_Stop;  // Collect mode was turned off before timer fired

    if (EnableDebugOnClient(client))
    {
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogMessage("[AC] Auto-debug enabled for %s (%s) — collect-all mode.", name, PlayerDebug[client].steamId);
    }
    return Plugin_Stop;
}

public Action Command_DebugPlayer(int client, int args)
{
    // No args: toggle collect-all mode (on → off, off → on)
    if (args < 1)
    {
        if (CollectAll)
        {
            // Second call: disable everything
            int count = 0;
            for (int i = 1; i <= MaxClients; i++)
            {
                if (PlayerDebug[i].active)
                {
                    PlayerDebug[i].active = false;
                    count++;
                }
            }
            CollectAll = false;
            CReplyToCommand(client, "[{olive}AC{default}] Collect-all {red}DISABLED{default}. Stopped debug on %d player(s).", count);
        }
        else
        {
            // First call: enable on all current players + auto-collect new joins
            CollectAll = true;
            int count = 0;
            for (int i = 1; i <= MaxClients; i++)
            {
                if (TFDB_IsRealHuman(i))
                {
                    if (EnableDebugOnClient(i))
                        count++;
                }
            }
            CReplyToCommand(client,
                "[{olive}AC{default}] Collect-all {community}ENABLED{default}. Debug started on %d player(s). New joins auto-logged. Type again to stop.",
                count);
        }
        return Plugin_Handled;
    }

    // With args: toggle a single player
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true);
    if (target == -1) return Plugin_Handled;

    if (PlayerDebug[target].active)
    {
        PlayerDebug[target].active = false;
        char name[MAX_NAME_LENGTH];
        GetClientName(target, name, sizeof(name));
        CReplyToCommand(client, "[{olive}AC{default}] Debug {red}DISABLED{default} for {darkorange}%s{default}.", name);
    }
    else if (EnableDebugOnClient(target))
    {
        char name[MAX_NAME_LENGTH];
        GetClientName(target, name, sizeof(name));
        CReplyToCommand(client,
            "[{olive}AC{default}] Debug {community}ENABLED{default} for {darkorange}%s{default}. File: %s",
            name, PlayerDebug[target].logPath);
    }
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
    return g_ClientImmune[client];
}

/** Resolve the immunity flag character once into an AdminFlag bit. */
void RefreshImmunityFlag()
{
    g_ImmunityFlagValid = (ACImmunityFlag[0] != '\0')
                          && FindFlagByChar(ACImmunityFlag[0], g_ImmunityFlagBit);
}

/** Recompute one client's cached immunity. Cheap — no string lookups. */
void RefreshClientImmunity(int client)
{
    if (!g_ImmunityFlagValid) { g_ClientImmune[client] = false; return; }
    AdminId admin = GetUserAdmin(client);
    g_ClientImmune[client] = (admin != INVALID_ADMIN_ID)
                             && GetAdminFlag(admin, g_ImmunityFlagBit);
}

/** Refresh immunity for every connected client (call after cvar/flag change). */
void RefreshAllClientImmunity()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i)) RefreshClientImmunity(i);
        else g_ClientImmune[i] = false;
    }
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
    else if (StrEqual(type, "AirblastFacing") || StrEqual(type, "DragSnapback") || StrEqual(type, "SnapAim"))
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
        "[SESSION] %s (%s) | Score:%d | AA:%d AF:%d DS:%d SA:%d PT:%d CT:%d Str:%d(%d)",
        name, steamId, score,
        AntiAimDetections[client],
        AirblastFacingDetections[client],
        DragSnapbackDetections[client],
        SnapAimDetections[client],
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
