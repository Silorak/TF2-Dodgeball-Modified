#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2_stocks>
#include <multicolors>

#undef REQUIRE_PLUGIN
#tryinclude <tfdb>
#define REQUIRE_PLUGIN

#define PLUGIN_NAME    "TFDB Cheat Debugger"
#define PLUGIN_VERSION "2.2.0"

// Simulation mode bitfield
enum
{
    SIM_NONE          = 0,
    SIM_AUTOAIRBLAST  = 1 << 0,  // Auto-airblast on perfect tick
    SIM_SILENTAIM     = 1 << 1,  // Snap angles to rocket + snapback
    SIM_FIXMOVEMENT   = 1 << 2,  // Perfect movement correction
    SIM_FAKELAG       = 1 << 3,  // Manipulate tickcount
    SIM_ALL           = 0xF
}

// Per-client state
bool  DebugActive[MAXPLAYERS + 1];
int   SimMode[MAXPLAYERS + 1];
float SavedAngles[MAXPLAYERS + 1][3];
bool  DidSnap[MAXPLAYERS + 1];
int   SnapTick[MAXPLAYERS + 1];
int   FakeLagCounter[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = "Silorak",
    description = "Debug that simulates dodgeball cheat behaviors",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/Silorak/TF2-Dodgeball"
};

public void OnPluginStart()
{
    // Load shared phrase files so any %t formatter in admin messages resolves.
    // AC_Debug's user-facing text is admin-only English (intentional — debug
    // output shouldn't be localized), but common phrases (player targeting
    // errors from FindTarget, etc.) need the common tables.
    LoadTranslations("common.phrases");
    LoadTranslations("tfdb.phrases.txt");

    RegAdminCmd("sm_ac", Command_AC, ADMFLAG_ROOT,
        "Toggle cheat simulation. Usage: sm_ac <player> [mode]  Modes: 1=autoairblast 2=silentaim 4=fixmovement 8=fakelag");
}

// ============================================================================
// Unified command: sm_ac <player> [mode]
// ============================================================================

public Action Command_AC(int client, int args)
{
    if (args < 1)
    {
        CReplyToCommand(client, "[{olive}AC{default}] Usage: {community}sm_ac <player> [mode]");
        CReplyToCommand(client, "[{olive}AC{default}] Modes: {community}1{default}=autoairblast {community}2{default}=silentaim {community}4{default}=fixmovement {community}8{default}=fakelag");
        CReplyToCommand(client, "[{olive}AC{default}] No mode = all. Combine: 3=auto+silent, 5=auto+movefix");
        return Plugin_Handled;
    }

    // Parse target
    char targetArg[64];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    int target = FindTarget(client, targetArg, false, false);
    if (target == -1)
        return Plugin_Handled;

    // Parse optional mode (default = SIM_ALL)
    int requestedMode = SIM_ALL;
    if (args >= 2)
    {
        char modeArg[8];
        GetCmdArg(2, modeArg, sizeof(modeArg));
        requestedMode = StringToInt(modeArg) & SIM_ALL;
        if (requestedMode == 0)
            requestedMode = SIM_ALL;
    }

    char targetName[MAX_NAME_LENGTH];
    GetClientName(target, targetName, sizeof(targetName));

    // Toggle logic:
    // Active with same mode → disable
    // Active with different mode → switch
    // Inactive → enable
    if (DebugActive[target])
    {
        if (SimMode[target] == requestedMode)
        {
            // Same mode — toggle OFF
            DebugActive[target] = false;
            SimMode[target] = SIM_NONE;
            DidSnap[target] = false;
            FakeLagCounter[target] = 0;

            CPrintToChat(client,
                "[{olive}AC{default}] Simulation {red}DISABLED{default} on {darkorange}%s{default}.",
                targetName);

            if (target != client)
            {
                CPrintToChat(target,
                    "[{olive}AC{default}] Cheat simulation {red}DISABLED{default} by admin.");
            }
        }
        else
        {
            // Different mode — switch
            SimMode[target] = requestedMode;
            DidSnap[target] = false;

            char flags[128];
            FormatModeFlags(requestedMode, flags, sizeof(flags));

            CPrintToChat(client,
                "[{olive}AC{default}] {darkorange}%s{default} switched to mode {community}%d{default}: %s",
                targetName, requestedMode, flags);

            if (target != client)
            {
                CPrintToChat(target,
                    "[{olive}AC{default}] Simulation changed to mode {community}%d{default}: %s",
                    requestedMode, flags);
            }
        }
    }
    else
    {
        // Enable
        DebugActive[target] = true;
        SimMode[target] = requestedMode;
        DidSnap[target] = false;
        FakeLagCounter[target] = 0;

        char flags[128];
        FormatModeFlags(requestedMode, flags, sizeof(flags));

        CPrintToChat(client,
            "[{olive}AC{default}] Simulation {community}ENABLED{default} on {darkorange}%s{default} → mode {community}%d{default}: %s",
            targetName, requestedMode, flags);

        if (target != client)
        {
            CPrintToChat(target,
                "[{olive}AC{default}] Cheat simulation {community}ENABLED{default} by admin. Mode: %s",
                flags);
        }
    }

    return Plugin_Handled;
}

void FormatModeFlags(int mode, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    char tmp[32];

    if (mode & SIM_AUTOAIRBLAST)
    {
        FormatEx(tmp, sizeof(tmp), "AutoAirblast ");
        StrCat(buffer, maxlen, tmp);
    }
    if (mode & SIM_SILENTAIM)
    {
        FormatEx(tmp, sizeof(tmp), "SilentAim ");
        StrCat(buffer, maxlen, tmp);
    }
    if (mode & SIM_FIXMOVEMENT)
    {
        FormatEx(tmp, sizeof(tmp), "FixMovement ");
        StrCat(buffer, maxlen, tmp);
    }
    if (mode & SIM_FAKELAG)
    {
        FormatEx(tmp, sizeof(tmp), "FakeLag ");
        StrCat(buffer, maxlen, tmp);
    }

    if (buffer[0] == '\0')
        FormatEx(buffer, maxlen, "None");
}

// ============================================================================
// Client lifecycle
// ============================================================================

public void OnClientPutInServer(int client)
{
    DebugActive[client] = false;
    SimMode[client] = SIM_NONE;
    DidSnap[client] = false;
    SnapTick[client] = 0;
    FakeLagCounter[client] = 0;
}

public void OnClientDisconnect(int client)
{
    DebugActive[client] = false;
    SimMode[client] = SIM_NONE;
    DidSnap[client] = false;
    SnapTick[client] = 0;
    FakeLagCounter[client] = 0;
}

// ============================================================================
// Core simulation: modify the player's usercmd to mimic cheat behavior
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
    float vel[3], float angles[3], int &weapon, int &subtype,
    int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!DebugActive[client] || !IsPlayerAlive(client))
        return Plugin_Continue;

    int mode = SimMode[client];
    int currentTick = GetGameTickCount();

    // Find the closest enemy rocket
    float clientPos[3];
    GetClientEyePosition(client, clientPos);

    float closestDist = 99999.0;
    float rocketPos[3];
    int closestRocket = -1;

    // Scan both rocket types (TFDB uses tf_projectile_rocket and
    // tf_projectile_sentryrocket for animated models)
    char classnames[][] = { "tf_projectile_rocket", "tf_projectile_sentryrocket" };
    for (int c = 0; c < sizeof(classnames); c++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, classnames[c])) != -1)
        {
            if (!IsValidEntity(entity)) continue;
            if (GetEntProp(entity, Prop_Send, "m_iTeamNum") == GetClientTeam(client)) continue;

            float pos[3];
            GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
            float dist = GetVectorDistance(clientPos, pos);
            if (dist < closestDist)
            {
                closestDist = dist;
                closestRocket = entity;
                rocketPos[0] = pos[0];
                rocketPos[1] = pos[1];
                rocketPos[2] = pos[2];
            }
        }
    }

    if (closestRocket == -1)
    {
        // No rocket — snapback if we were snapped
        if (DidSnap[client] && (currentTick - SnapTick[client]) >= 2)
        {
            angles[0] = SavedAngles[client][0];
            angles[1] = SavedAngles[client][1];
            angles[2] = SavedAngles[client][2];
            DidSnap[client] = false;
        }
        return Plugin_Continue;
    }

    // ------------------------------------------------------------------
    // SIM_AUTOAIRBLAST: Fire IN_ATTACK2 on the exact tick the rocket
    // enters the 128hu deflection sphere
    // ------------------------------------------------------------------
    float deflectionRadius = 128.0;
    bool inRange = (closestDist <= deflectionRadius + 30.0);

    if ((mode & SIM_AUTOAIRBLAST) && inRange)
    {
        buttons |= IN_ATTACK2;
    }

    // ------------------------------------------------------------------
    // SIM_SILENTAIM: Snap viewangles to face the rocket for the airblast
    // frame, then snap back 2 ticks later
    // ------------------------------------------------------------------
    if ((mode & SIM_SILENTAIM) && inRange && (buttons & IN_ATTACK2))
    {
        if (!DidSnap[client])
        {
            SavedAngles[client][0] = angles[0];
            SavedAngles[client][1] = angles[1];
            SavedAngles[client][2] = angles[2];
            DidSnap[client] = true;
            SnapTick[client] = currentTick;
        }

        // Snap to rocket
        float direction[3];
        SubtractVectors(rocketPos, clientPos, direction);
        NormalizeVector(direction, direction);

        float aimAngles[3];
        GetVectorAngles(direction, aimAngles);

        angles[0] = aimAngles[0];
        angles[1] = aimAngles[1];
        angles[2] = 0.0;

        // ------------------------------------------------------------------
        // SIM_FIXMOVEMENT: Rotate movement vector by -yawDelta
        // ------------------------------------------------------------------
        if (mode & SIM_FIXMOVEMENT)
        {
            float yawDelta = angles[1] - SavedAngles[client][1];
            if (yawDelta != yawDelta) yawDelta = 0.0;
            while (yawDelta > 180.0) yawDelta -= 360.0;
            while (yawDelta < -180.0) yawDelta += 360.0;

            float rad = DegToRad(-yawDelta);
            float cosVal = Cosine(rad);
            float sinVal = Sine(rad);

            float oldForward = vel[0];
            float oldSide = vel[1];
            vel[0] = cosVal * oldForward - sinVal * oldSide;
            vel[1] = sinVal * oldForward + cosVal * oldSide;
        }

        return Plugin_Continue;
    }

    // Snapback: return to saved angles 2 ticks after snap
    if (DidSnap[client] && (currentTick - SnapTick[client]) >= 2)
    {
        angles[0] = SavedAngles[client][0];
        angles[1] = SavedAngles[client][1];
        angles[2] = SavedAngles[client][2];
        DidSnap[client] = false;
        return Plugin_Continue;
    }

    // ------------------------------------------------------------------
    // SIM_FAKELAG: Periodically manipulate tickcount
    // ------------------------------------------------------------------
    if (mode & SIM_FAKELAG)
    {
        FakeLagCounter[client]++;
        if (FakeLagCounter[client] % 100 == 0)
        {
            tickcount += RoundToCeil(0.20 / GetTickInterval());
            return Plugin_Continue;
        }
    }

    return Plugin_Continue;
}
