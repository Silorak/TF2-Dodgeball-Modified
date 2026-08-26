/**
 * [TFDB] Data - human gameplay recorder
 *
 * Records what a REAL player does, in the same terms the PvB bot uses to
 * decide, so the two can be compared directly.
 *
 * The point is not "log everything". Logging everything produces a file
 * nobody can answer a question with. Every column here exists because some
 * specific PvB tuning value is currently a guess, and this is the measurement
 * that would replace it:
 *
 *   rocket_dist / rocket_closing at the moment of a deflect
 *       -> what distance do humans ACTUALLY blast at? Directly replaces the
 *          guessed fire_time_to_impact / AIRBLAST_REACH commit point.
 *   enemy_dist over time
 *       -> what standoff do humans actually hold? Replaces cqc_min/max and
 *          the standoff ring, which were picked out of the air.
 *   speed / accel
 *       -> do humans run at full speed constantly, or modulate? The bot's
 *          old bang-bang 300 assumed the former; this settles it.
 *   yaw_delta (turn rate)
 *       -> how fast does a human actually flick? Replaces the aim_speed_*
 *          factors, which are pure guesswork.
 *   pitch at deflect
 *       -> are real spikes near-vertical? Replaces spike_up_pitch.
 *   buttons
 *       -> the actual WASD pattern during an orbit, rather than our assumed
 *          4-phase cycle.
 *
 * One CSV per round, closed on round end, because the user plays a different
 * style each round and mixing them averages the signal away.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tfdb>

#define PLUGIN_VERSION "2.3.0"

public Plugin myinfo = {
    name        = "[TFDB] Data",
    author      = "Silorak",
    description = "Records human dodgeball gameplay to CSV for tuning the PvB decision tree.",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
ConVar g_cvEnabled  = null;
ConVar g_cvSampleRate = null;   // record every Nth tick

File   g_File       = null;
char   g_FilePath[PLATFORM_MAX_PATH];
bool   g_Recording  = false;
int    g_RoundIndex = 0;
int    g_Rows       = 0;

// Per-client previous-tick values, for deltas the bot also computes.
float  g_PrevYaw[MAXPLAYERS + 1];
float  g_PrevSpeed[MAXPLAYERS + 1];
int    g_TickCounter[MAXPLAYERS + 1];

// Hard cap so a forgotten recording can't fill the disk.
#define MAX_ROWS 400000

public void OnPluginStart()
{
    CreateConVar("tfdb_data_version", PLUGIN_VERSION, "[TFDB] Data version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("tfdb_data_enable", "0",
        "Record human gameplay to CSV. 0 = off.", _, true, 0.0, true, 1.0);
    g_cvSampleRate = CreateConVar("tfdb_data_rate", "1",
        "Record every Nth tick. 1 = every tick.", _, true, 1.0, true, 66.0);

    RegAdminCmd("sm_tfdbdata", Cmd_Toggle, ADMFLAG_ROOT,
        "[ROOT] Toggle human gameplay recording on/off.");

    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_win",   Event_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("player_death",         Event_PlayerDeath, EventHookMode_Post);

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "data/tfdb_data");
    if (!DirExists(dir)) CreateDirectory(dir, 511);
}

public Action Cmd_Toggle(int client, int args)
{
    bool on = !g_cvEnabled.BoolValue;
    g_cvEnabled.SetBool(on);

    if (on) {
        ReplyToCommand(client, "[TFDB-Data] Recording ENABLED. A file is opened per round.");
        if (!g_Recording) StartRound();
    } else {
        StopRound("manual");
        ReplyToCommand(client, "[TFDB-Data] Recording disabled.");
    }
    return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Round lifecycle - one file per round, deliberately.
// ---------------------------------------------------------------------------
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return;
    StartRound();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    StopRound("round_end");
}

void StartRound()
{
    StopRound("restart");   // never leave a handle open across rounds

    char map[64], stamp[32];
    GetCurrentMap(map, sizeof(map));
    FormatTime(stamp, sizeof(stamp), "%Y%m%d_%H%M%S");

    g_RoundIndex++;
    BuildPath(Path_SM, g_FilePath, sizeof(g_FilePath),
        "data/tfdb_data/%s_%s_r%d.csv", map, stamp, g_RoundIndex);

    g_File = OpenFile(g_FilePath, "w");
    if (g_File == null) {
        LogError("[TFDB-Data] Could not open %s", g_FilePath);
        return;
    }

    // Column names are the bot's own decision inputs, so a row here is
    // directly comparable to a [BOT tick] line from the PvB debug log.
    g_File.WriteLine("tick,player,team,alive,pos_x,pos_y,pos_z,vel_x,vel_y,speed,accel,pitch,yaw,yaw_delta,onground,btn_w,btn_s,btn_a,btn_d,btn_m1,btn_m2,btn_jump,btn_duck,enemy_dist,rocket_ent,rocket_dist,rocket_speed,rocket_closing,rocket_targets_me,rocket_deflections,event");

    g_Recording = true;
    g_Rows = 0;

    for (int i = 1; i <= MaxClients; i++) {
        g_PrevYaw[i] = 0.0;
        g_PrevSpeed[i] = 0.0;
        g_TickCounter[i] = 0;
    }

    PrintToServer("[TFDB-Data] Recording round %d -> %s", g_RoundIndex, g_FilePath);
}

void StopRound(const char[] reason)
{
    if (g_File != null) {
        g_File.Flush();
        delete g_File;
        g_File = null;
        PrintToServer("[TFDB-Data] Round closed (%s): %d rows -> %s", reason, g_Rows, g_FilePath);
    }
    g_Recording = false;
}

public void OnMapEnd()
{
    StopRound("map_end");
}

public void OnPluginEnd()
{
    StopRound("plugin_end");
}

// ---------------------------------------------------------------------------
// Events worth marking inline, so a row can be found by what happened rather
// than by scrubbing timestamps.
// ---------------------------------------------------------------------------
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_Recording) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients) return;
    if (IsFakeClient(client)) return;
    WriteEventRow(client, "death");
}

public void TFDB_OnRocketDeflect(int iIndex, int iEntity, int iOwner)
{
    if (!g_Recording) return;
    if (iOwner < 1 || iOwner > MaxClients || !IsClientInGame(iOwner)) return;
    if (IsFakeClient(iOwner)) return;

    // The single most valuable row in the file: the exact tick a human
    // committed, with the aim they committed AT. Everything the bot guesses
    // about when and how to blast is answerable from these rows alone.
    //
    // Force the rocket columns onto the rocket that was ACTUALLY deflected.
    // The generic picker below prefers whichever rocket targets this player,
    // which on a deflect row is frequently a different one - first pass
    // produced deflect rows reading rocket_dist 695 and 673, well outside the
    // 256 the blast can even reach, because it had latched onto a second
    // rocket inbound from across the map. Those rows would have argued for a
    // commit distance that is physically impossible.
    WriteEventRowForRocket(iOwner, "deflect", iEntity);
}

// ---------------------------------------------------------------------------
// Per-tick sampling
// ---------------------------------------------------------------------------
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3],
                             float angles[3], int &weapon)
{
    if (!g_Recording || g_File == null) return Plugin_Continue;
    if (client < 1 || client > MaxClients) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;   // humans only - bots are the thing being tuned
    if (!IsClientInGame(client)) return Plugin_Continue;

    int rate = g_cvSampleRate.IntValue;
    if (rate > 1) {
        g_TickCounter[client]++;
        if (g_TickCounter[client] % rate != 0) return Plugin_Continue;
    }

    WriteRow(client, buttons, angles, "", -1);
    return Plugin_Continue;
}

void WriteEventRow(int client, const char[] evt)
{
    WriteEventRowForRocket(client, evt, -1);
}

void WriteEventRowForRocket(int client, const char[] evt, int forceRocketEnt)
{
    float angles[3];
    GetClientEyeAngles(client, angles);
    int buttons = IsPlayerAlive(client) ? GetClientButtons(client) : 0;
    WriteRow(client, buttons, angles, evt, forceRocketEnt);
}

void WriteRow(int client, int buttons, const float angles[3], const char[] evt, int forceRocketEnt)
{
    if (g_File == null) return;
    if (g_Rows >= MAX_ROWS) return;

    float pos[3], velocity[3];
    GetClientAbsOrigin(client, pos);
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);

    float speed = SquareRoot(velocity[0] * velocity[0] + velocity[1] * velocity[1]);

    // Per-tick deltas. accel is what settles "does a human run flat out or
    // modulate", and yaw_delta is the real flick rate the aim_speed_* values
    // are currently guessing at.
    float accel = speed - g_PrevSpeed[client];
    g_PrevSpeed[client] = speed;

    float yawDelta = angles[1] - g_PrevYaw[client];
    while (yawDelta > 180.0)  yawDelta -= 360.0;
    while (yawDelta < -180.0) yawDelta += 360.0;
    g_PrevYaw[client] = angles[1];

    bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
    int team = GetClientTeam(client);

    // Nearest living enemy - the same quantity the bot's standoff controller
    // works against.
    float enemyDist = -1.0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        if (GetClientTeam(i) == team) continue;
        float epos[3];
        GetClientAbsOrigin(i, epos);
        float d = GetVectorDistance(pos, epos);
        if (enemyDist < 0.0 || d < enemyDist) enemyDist = d;
    }

    // Most relevant rocket: the one targeting this player, else the nearest.
    int   rEnt = -1, rDeflects = 0, rTargetsMe = 0;
    float rDist = -1.0, rSpeed = 0.0, rClosing = 0.0;

    if (TFDB_IsDodgeballEnabled()) {
        float eyePos[3];
        GetClientEyePosition(client, eyePos);
        bool haveTargeted = false;

        for (int i = 0; i < 64; i++) {
            if (!TFDB_IsValidRocket(i)) continue;
            int ent = TFDB_GetRocketEntity(i);
            if (ent <= 0 || !IsValidEntity(ent)) continue;

            float rpos[3], rvel[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", rpos);
            GetEntPropVector(ent, Prop_Data, "m_vecAbsVelocity", rvel);
            float d = GetVectorDistance(eyePos, rpos);
            bool targeted = (TFDB_GetRocketTarget(i) == client);

            // An explicitly named rocket (deflect rows) overrides everything:
            // that row is ABOUT that rocket.
            bool forced = (forceRocketEnt > 0 && ent == forceRocketEnt);
            if (forceRocketEnt > 0 && !forced) continue;

            // A rocket aimed at this player always wins over a closer one
            // that isn't - same precedence the bot uses.
            if (forced || (targeted && !haveTargeted) || (targeted == haveTargeted && (rDist < 0.0 || d < rDist))) {
                rEnt = ent;
                rDist = d;
                rSpeed = GetVectorLength(rvel);
                rDeflects = TFDB_GetRocketDeflections(i);
                rTargetsMe = targeted ? 1 : 0;
                haveTargeted = haveTargeted || targeted;

                float toMe[3];
                MakeVectorFromPoints(rpos, eyePos, toMe);
                if (NormalizeVector(toMe, toMe) > 0.0) {
                    rClosing = GetVectorDotProduct(rvel, toMe);
                }
            }
        }
    }

    char nameBuf[MAX_NAME_LENGTH];
    GetClientName(client, nameBuf, sizeof(nameBuf));
    ReplaceString(nameBuf, sizeof(nameBuf), ",", " ");   // never break the CSV

    g_File.WriteLine("%d,%s,%d,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.1f,%d,%.1f,%.1f,%.1f,%d,%d,%s",
        GetGameTickCount(), nameBuf, team, IsPlayerAlive(client) ? 1 : 0,
        pos[0], pos[1], pos[2],
        velocity[0], velocity[1], speed, accel,
        angles[0], angles[1], yawDelta,
        onGround ? 1 : 0,
        (buttons & IN_FORWARD)   ? 1 : 0,
        (buttons & IN_BACK)      ? 1 : 0,
        (buttons & IN_MOVELEFT)  ? 1 : 0,
        (buttons & IN_MOVERIGHT) ? 1 : 0,
        (buttons & IN_ATTACK)    ? 1 : 0,
        (buttons & IN_ATTACK2)   ? 1 : 0,
        (buttons & IN_JUMP)      ? 1 : 0,
        (buttons & IN_DUCK)      ? 1 : 0,
        enemyDist,
        rEnt, rDist, rSpeed, rClosing, rTargetsMe, rDeflects,
        evt);

    g_Rows++;
    if (g_Rows == MAX_ROWS) {
        LogMessage("[TFDB-Data] Row cap (%d) reached for %s - recording stopped for this round.", MAX_ROWS, g_FilePath);
    }
}
