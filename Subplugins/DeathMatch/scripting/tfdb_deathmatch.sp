#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <dhooks>
#include <tf2>
#include <tf2_stocks>
#include <multicolors>

#include <tfdb>
// DM is mutex with Guardian + PvB only. DM and FFA coexist intentionally —
// different layers (team swaps vs neutral rockets) that don't fight each other.
#include <tfdb_guardian>
#include <tfdb_pvb>
#include <tfdb_clientcheck>

#define PLUGIN_NAME        "[TFDB] DeathMatch"
#define PLUGIN_AUTHOR      "Mikah (NER/SOLO v1.5.3) + Silorak (TFDB integration)"
#define PLUGIN_DESCRIPTION "Never-Ending Rounds + Solo queue for TF2 Dodgeball"
#define PLUGIN_VERSION          "2.3.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = PLUGIN_AUTHOR,
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION,
    url         = PLUGIN_URL
};

#define SOUND_RESPAWN ")ambient/alarms/doomsday_lift_alarm.wav"

// AnalogueTeam: TFTeam_Red (2) ^ 1 = 3 (Blue), TFTeam_Blue (3) ^ 1 = 2 (Red)
#define AnalogueTeam(%1) ((%1) ^ 1)

// ============================================================================
//  WHAT THIS PLUGIN DOES (read this first)
// ============================================================================
//
//  NER (Never-Ending Rounds) prevents round-end by detouring C++ game functions:
//
//    1. LoadGameConfigFile("tfdb_dm.games") → resolves symbols from server .symtab
//    2. DHookCreateDetour on CTFGameRules::SetWinningTeam + ::SetStalemate
//    3. While NERActive: callbacks return MRES_Supercede → round CANNOT end
//    4. When NERActive is false: callbacks return MRES_Ignored → normal game
//
//  The detours are installed once at plugin load. NERActive is the on/off switch.
//  When a kill empties a side, the NER game loop (not the engine) resolves it:
//    other side has 2+ alive → MOVE one player over (1v1 duel forms)
//    other side has ≤1 alive  → RESOLVE (reshuffle dead, balanced respawn)
//
//  If this sounds scary, read docs/ARCHITECTURE.md §4 (DeathMatch NER v3).

// ============================================================================
//  State
// ============================================================================

// NER (Never-Ending Rounds)
float LastVoteTime = 0.0;
bool  NERActive    = false;


// Solo queue
bool       SoloEnabled[MAXPLAYERS + 1];

// Round state
bool  RoundStarted    = false;
int   LastDeadTeam    = view_as<int>(TFTeam_Red);

// Per-client respawn-protection window. Global was a bug in v1.5.3 — it granted
// 2s of immunity to ALL players whenever anyone respawned, which let the server
// briefly be a safe-zone every time NER fired.
float ClientRespawnTime[MAXPLAYERS + 1];
bool   NERRespawnQueued[MAXPLAYERS + 1];  // legacy: cleared on disconnect; kept for save-state safety

// NER lifecycle roster (v3 'gamedata NER' — the real engine fight):
//   !dm  -> detour CTFGameRules::SetWinningTeam + ::SetStalemate with
//           MRES_Supercede while NER is active. The round PHYSICALLY cannot
//           end: no death-tick race, no restart gap, kills always land.
//   roster: every Red/Blue player (never spectators); joiners captured on
//           team join, released on spectate/disconnect.
//   death STICKS — no respawn-on-death (strong players would dominate).
//   When a side reaches 0 alive -> RESOLVE: reshuffle all DEAD roster
//           members into balanced teams (safe: everyone's dead) and respawn
//           them. The killer's side keeps its survivors. Loop continues.
bool NERLifecycle[MAXPLAYERS + 1];

// Spawned-this-round discriminator: set by player_spawn, cleared at round
// start/disconnect. Separates KILLED players (spawned then died — deaths
// STICK per the game loop) from BENCHED joiners (on a team, never spawned —
// must enter play). Timing-based checks failed three times live because
// fresh joins read IsPlayerAlive==true in the transition window.
bool SpawnedThisRound[MAXPLAYERS + 1];

// Diagnostics + join-window bookkeeping: GetGameTime() when this client last
// joined a playing team (set in Event_PlayerTeam). Used to distinguish a
// just-joined benched player from an established one in the NER logs and to
// sanity-check SpawnedThisRound (a benched joiner may fire a PHANTOM
// player_spawn while being seated — hypothesis under live investigation).
float JoinTeamTime[MAXPLAYERS + 1];

// Bench sweep timer + census throttle
Handle       g_hBenchSweep    = null;
float        g_fLastSweepCensus = 0.0;

// Game-rules detours (symbols from the server binary's .symtab, resolved at
// runtime via gamedata — see gamedata/tfdb_dm.games.txt)
Handle g_hGamedata         = null;

DynamicDetour g_detSetWin  = null;
DynamicDetour g_detStale   = null;

// Cached cvars
ConVar CvarNERVoteTimeout;
ConVar CvarForceNER;
ConVar CvarForceNERStartMap;
ConVar CvarNEREnabled;
ConVar CvarSoloEnabled;
ConVar CvarRespawnProtection;
ConVar CvarVerbose;

// FFA cache — FFA is allowed to coexist; NER switches behavior when it's on.
// Retried on null so late-load order is handled cleanly.

// ============================================================================
//  Plugin lifecycle
// ============================================================================

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
    CreateNative("TFDB_IsDeathMatchActive", Native_IsDeathMatchActive);
    CreateNative("TFDB_IsNEREnabled",       Native_IsNEREnabled);

    RegPluginLibrary("tfdb_deathmatch");
    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("tfdb.phrases.txt");

    RegAdminCmd("sm_dm",     Cmd_ToggleDeathMatch, ADMFLAG_CONFIG, "[TFDB] Toggle DeathMatch mode (NER)");
    RegConsoleCmd("sm_votedm", Cmd_VoteDeathMatch,                 "Vote to toggle DeathMatch mode");
    RegConsoleCmd("sm_solo",   Cmd_Solo,                           "Join/leave the solo queue (respawn at round end)");

    CvarNERVoteTimeout    = CreateConVar("tfdb_dm_ner_vote_timeout",   "120",  "NER vote cooldown in seconds",                                  _, true, 0.0);
    CvarForceNER          = CreateConVar("tfdb_dm_ner_force",          "0",    "Force NER on (cannot be disabled via vote or admin)",            _, true, 0.0, true, 1.0);
    CvarForceNERStartMap  = CreateConVar("tfdb_dm_ner_force_start",    "0",    "Enable NER at map start",                                        _, true, 0.0, true, 1.0);
    CvarNEREnabled        = CreateConVar("tfdb_dm_ner_enabled",        "1",    "Enable Never-Ending Rounds feature",                             _, true, 0.0, true, 1.0);
    CvarSoloEnabled       = CreateConVar("tfdb_dm_solo_enabled",       "1",    "Enable Solo queue feature",                                      _, true, 0.0, true, 1.0);
    CvarRespawnProtection = CreateConVar("tfdb_dm_respawn_protection", "2.0",  "Seconds of damage immunity after a DeathMatch respawn",          _, true, 0.0);
    CvarVerbose         = CreateConVar("tfdb_dm_verbose",             "0",    "0 = quiet (errors + NER on/off + detour status only). 1 = full NER trace: team/spawn/death events, census, bench, move, resolve", _, true, 0.0, true, 1.0);

    CvarNEREnabled.AddChangeHook(OnCvarChanged);
    CvarSoloEnabled.AddChangeHook(OnCvarChanged);

    // Events are plugin-lifetime — hook once, SourceMod auto-unhooks on unload.
    HookEvent("arena_round_start",         Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death",              Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("player_spawn",              Event_PlayerSpawnDM, EventHookMode_Post);
    HookEvent("teamplay_round_win",        Event_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_stalemate",  Event_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("player_team",               Event_PlayerTeam, EventHookMode_Post);

    
    // --- Gamedata NER: detour the game-rules round-end functions ---
    // CTFGameRules::SetWinningTeam and ::SetStalemate are superseded while
    // NER is active, so the engine can never end the round on us. Symbols
    // resolve from the server binary's symtab via gamedata (Linux). Server
    // builds differ (live-verified: one build resolved SetStalemate's symbol,
    // another didn't) — candidate symbols are tried in order.
    g_hGamedata = LoadGameConfigFile("tfdb_dm.games");
    if (g_hGamedata == null)
    {
        LogError("[TFDB-DM] gamedata/tfdb_dm.games.txt missing or unreadable — NER round-end detours NOT installed");
    }
    else
    {
        // REQUIRED — blocks round-end by elimination (the NER core).
        Address addrWin = Address_Null;
        for (int c = 1; c <= 2 && addrWin == Address_Null; c++)
        {
            addrWin = GameConfGetAddress(g_hGamedata,
                c == 1 ? "CTFGameRules::SetWinningTeam" : "CTFGameRules::SetWinningTeam.v2");
        }

        if (addrWin == Address_Null)
        {
            LogError("[TFDB-DM] SetWinningTeam NOT resolved — NER cannot block round-end on this server build");
        }
        else
        {
            LogMessage("[DM-NER] SetWinningTeam address resolved: 0x%x", view_as<int>(addrWin));
            g_detSetWin = DHookCreateDetour(addrWin, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
            if (g_detSetWin != null)
            {
                DHookAddParam(g_detSetWin, HookParamType_Int);    // iTeam
                DHookAddParam(g_detSetWin, HookParamType_Int);    // iReason
                DHookAddParam(g_detSetWin, HookParamType_Bool);   // bForceMapReset
                DHookAddParam(g_detSetWin, HookParamType_Bool);   // bSwitchTeams
                DHookAddParam(g_detSetWin, HookParamType_Bool);   // bDontAddScore
                DHookAddParam(g_detSetWin, HookParamType_Bool);   // bFinal
                if (DHookEnableDetour(g_detSetWin, false, Detour_SetWinningTeam))
                    LogMessage("[DM-NER] SetWinningTeam detour OK — elimination round-ends blocked while NER is active");
                else
                    LogError("[TFDB-DM] failed to enable SetWinningTeam detour");
            }
            else LogError("[TFDB-DM] failed to create SetWinningTeam detour");
        }

        // OPTIONAL — blocks the rare timelimit/empty-server stalemate end.
        // If no candidate resolves on this build, NER still fully works
        // (SetWinningTeam covers elimination); log and continue.
        Address addrSt = Address_Null;
        for (int c = 1; c <= 2 && addrSt == Address_Null; c++)
        {
            addrSt = GameConfGetAddress(g_hGamedata,
                c == 1 ? "CTFGameRules::SetStalemate" : "CTFGameRules::SetStalemate.v2");
        }

        if (addrSt == Address_Null)
        {
            LogMessage("[DM-NER] SetStalemate not resolved on this build — optional detour skipped (timelimit stalemates may still end a round)");
        }
        else
        {
            LogMessage("[DM-NER] SetStalemate address resolved: 0x%x", view_as<int>(addrSt));
            g_detStale = DHookCreateDetour(addrSt, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
            if (g_detStale != null)
            {
                DHookAddParam(g_detStale, HookParamType_Int);     // iReason
                DHookAddParam(g_detStale, HookParamType_Bool);    // bForceMapReset
                DHookAddParam(g_detStale, HookParamType_Bool);    // bSwitchTeams
                if (DHookEnableDetour(g_detStale, false, Detour_SetStalemate))
                    LogMessage("[DM-NER] SetStalemate detour OK — stalemate round-ends blocked while NER is active");
                else
                    LogMessage("[DM-NER] SetStalemate detour enable failed — optional, continuing");
            }
        }
    }
    RegAdminCmd("sm_dm_debug", Cmd_DMDebug, ADMFLAG_ROOT, "[TFDB] Toggle DM debug mode + dump NER state");

    // Handle late-load (plugin loaded mid-round)
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client)) OnClientPutInServer(client);
    }

    AutoExecConfig(true, "tfdb_deathmatch");
}

void SetNERActive(bool active)
{
    NERActive = active;

    if (active)
    {
        // Canary: if the SetWinningTeam detour didn't install (gamedata
        // missing, symbol not found, wrong build), NER is a lie — the round
        // WILL end normally. Log loudly so the admin knows immediately.
        if (g_detSetWin == null)
            LogError("[TFDB-DM] NER activated but SetWinningTeam detour is NOT installed — round-end blocking will NOT work! Check gamedata/tfdb_dm.games.txt and the load-time log.");

        // Capture the roster: everyone currently on a playing team.
        for (int client = 1; client <= MaxClients; client++)
            NERLifecycle[client] = IsClientInGame(client) && !IsSpectatorTeam(client);

        LogMessage("[DM-NER] active — game-rules detours engaged, roster of %d captured",
            CountLifecycleRoster());
    }
    else
    {
        for (int client = 0; client <= MaxClients; client++) NERLifecycle[client] = false;
    }
}

// Engine fight: block round-end by elimination and stalemate while NER owns
// the mode. Symbols: CTFGameRules::SetWinningTeam / ::SetStalemate (see
// gamedata/tfdb_dm.games.txt — resolved from the server .symtab at runtime).
public MRESReturn Detour_SetWinningTeam(int pThis, DHookParam hParams)
{
    if (!NERActive || !RoundStarted)
        return MRES_Ignored;
    int winTeam = -1; if (hParams != null) winTeam = hParams.Get(1);
    DMDebugLog("BLOCKED SetWinningTeam(team=%d) — NER owns the round", winTeam);
    return MRES_Supercede;
}

public MRESReturn Detour_SetStalemate(int pThis, DHookParam hParams)
{
    if (!NERActive || !RoundStarted)
        return MRES_Ignored;
    DMDebugLog("BLOCKED SetStalemate — NER owns the round");
    return MRES_Supercede;
}

int CountLifecycleRoster()
{
    int n = 0;
    for (int client = 1; client <= MaxClients; client++)
        if (NERLifecycle[client] && IsClientInGame(client)) n++;
    return n;
}

public void OnConfigsExecuted()
{
    // NER persistence across map changes: the NERActive flag survives the
    // map transition. The roster is recaptured at Event_RoundStart (when
    // RoundStarted goes true). Force-start at map start if configured.
    if (CvarForceNERStartMap.BoolValue && CanActivateDeathMatch())
        SetNERActive(true);

    PrecacheSound(SOUND_RESPAWN, true);

    RoundStarted = false;
    for (int c = 0; c <= MaxClients; c++) ClientRespawnTime[c] = 0.0;

    // Fresh map: reset lifecycle bookkeeping.
    for (int client = 0; client <= MaxClients; client++)
    {
        NERLifecycle[client]      = false;
        SpawnedThisRound[client]  = false;
        JoinTeamTime[client]      = 0.0;
    }
    if (g_hBenchSweep != null) { KillTimer(g_hBenchSweep); g_hBenchSweep = null; }
    g_hBenchSweep = CreateTimer(2.0, Timer_BenchSweep, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// No OnMapEnd manual UnhookEvent — that anti-pattern crashes when other
// subplugins unhook shared events first. SourceMod handles cleanup on unload.

public void OnPluginEnd()
{
    // Explicit handle cleanup on unload. SM auto-cleans most handles but being
    // explicit about the ArrayStack keeps the lifecycle obvious.
}

public void OnClientPutInServer(int client)
{
    SoloEnabled[client] = false;
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
    SoloEnabled[client]       = false;
    ClientRespawnTime[client] = 0.0;
    NERRespawnQueued[client]  = false;
    bool leavingRoster = NERLifecycle[client];
    NERLifecycle[client]      = false;
    SpawnedThisRound[client]  = false;

    // If NER is active and the round is live, a disconnect may have emptied
    // their side — run the side-emptied logic next frame (move or resolve).
    if (NERActive && RoundStarted && leavingRoster)
    {
        int team = GetClientTeam(client);
        if (team == view_as<int>(TFTeam_Red) || team == view_as<int>(TFTeam_Blue))
            RequestFrame(Frame_HandleSideEmptied, team);
    }

    // If only 1 human remains, disable NER — there's nobody to play against.
    // Players can still vote to re-enable with !votedm or use !dm when more
    // people join. Bots don't count (CvarSeeBotsAsPlayers handles debug mode).
    if (NERActive)
    {
        RequestFrame(Frame_CheckMinPlayers);
    }
}

void Frame_CheckMinPlayers(any userid)
{
    #pragma unused userid
    // The disconnecting client is already gone — we don't need their index.
    // Count the remaining humans and disable NER if only 1 (or 0) is left.
    if (!NERActive) return;
    // Don't disable during map transitions or between rounds —
    // OnClientDisconnect fires for all clients on map change.
    // NER persistence is handled by OnConfigsExecuted.
    if (!RoundStarted) return;

    int humanCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i)) continue;
        humanCount++;
    }

    if (humanCount <= 1)
    {
        SetNERActive(false);
        CvarForceNER.SetBool(false);
        CPrintToChatAll("%t", "DeathMatch_NER_Disabled");
    }
}

// ============================================================================
//  Cross-plugin mutex
// ============================================================================

/**
 * DeathMatch is mutually exclusive with PvB and Guardian (team-management
 * conflicts). FFA is compatible — NER adapts its team-swap logic when FFA
 * is active. See frameworks/deathmatch-mutual-exclusion in the wiki.
 */
bool CanActivateDeathMatch()
{
    // Allow DM with PvB for 1v1 bot (normal mode), but NOT debug-states mode
    // (sm_bot_test with 8 bots causes team-swap cascade).
    if (LibraryExists("tfdb_pvb") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsPvBActive") == FeatureStatus_Available &&
        TFDB_IsPvBActive())
    {
        if (GetFeatureStatus(FeatureType_Native, "TFDB_IsPvBDebugStates") == FeatureStatus_Available
            && TFDB_IsPvBDebugStates())
            return false;  // Debug-states mode — block DM (cascade risk)
        // PvB normal mode (1v1 bot) — allow DM for NER
    }

    if (LibraryExists("tfdb_guardian") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsGuardianActive") == FeatureStatus_Available &&
        TFDB_IsGuardianActive())
    {
        return false;
    }

    // NOTE: FFA and DM coexist intentionally. FFA makes rockets neutral; DM
    // swaps players between RED/BLU on death to keep small-server rounds going.
    // These layers don't fight each other — DM's team-swap still works while
    // FFA is on, and FFA's neutral-rocket logic still works during NER swaps.
    // Do NOT add an FFA gate here.

    return true;
}

// If PvB or Guardian starts while DM is active, force-disable DM cleanly.
public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "tfdb_pvb") || StrEqual(name, "tfdb_guardian"))
    {
        if (NERActive)
        {
            SetNERActive(false);
            CPrintToChatAll("%t", "DeathMatch_NER_Disabled_Conflict");
        }
    }
}

// ============================================================================
//  Native surface
// ============================================================================

public any Native_IsDeathMatchActive(Handle plugin, int numParams)
{
    return NERActive;
}

public any Native_IsNEREnabled(Handle plugin, int numParams)
{
    return NERActive;
}

// ============================================================================
//  Cvar change
// ============================================================================

public void OnCvarChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    if (!CvarNEREnabled.BoolValue && NERActive)
    {
        SetNERActive(false);
        CPrintToChatAll("%t", "DeathMatch_NER_Disabled");
    }

    if (!CvarSoloEnabled.BoolValue)
    {
        for (int client = 1; client <= MaxClients; client++)
        {
            if (SoloEnabled[client])
            {
                SoloEnabled[client] = false;
                if (IsClientInGame(client)) CPrintToChat(client, "%t", "DeathMatch_Solo_Disabled_By_Config");
            }
        }
        }
}

// ============================================================================
//  Round events
// ============================================================================

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    RoundStarted = false;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int c = 0; c <= MaxClients; c++) ClientRespawnTime[c] = 0.0;

    // Lifecycle roster follows round restarts (engine restart respawns the
    // whole roster anyway; recapture in case anyone changed teams while dead).
    if (NERActive)
    {
        for (int client = 1; client <= MaxClients; client++)
        {
            NERLifecycle[client]     = IsClientInGame(client) && !IsSpectatorTeam(client);
            SpawnedThisRound[client] = false;
        }
    }

    // Adapt to Guardian / PvB loading mid-round.
    if (NERActive && !CanActivateDeathMatch())
    {
        SetNERActive(false);
        CPrintToChatAll("%t", "DeathMatch_NER_Disabled_Conflict");
    }

    char listBuffer[512];
    char nameBuffer[64];

    int redCount  = GetTeamClientCount(view_as<int>(TFTeam_Red));
    int blueCount = GetTeamClientCount(view_as<int>(TFTeam_Blue));

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsAliveInGame(client)) continue;
        if (!SoloEnabled[client])   continue;
        if (IsSpectatorTeam(client)) continue;

        // Keep one non-soloer per team alive so the round isn't empty.
        int clientTeam = GetClientTeam(client);
        int remaining  = (clientTeam == view_as<int>(TFTeam_Red)) ? --redCount : --blueCount;

        if (remaining > 0)
        {
            if (listBuffer[0] == '\0') FormatEx(nameBuffer, sizeof(nameBuffer), "%N", client);
            else                      FormatEx(nameBuffer, sizeof(nameBuffer), ", %N", client);

            StrCat(listBuffer, sizeof(listBuffer), nameBuffer);
            ForcePlayerSuicide(client);
        }
        else
        {
            SoloEnabled[client] = false;
            CPrintToChat(client, "%t", "DeathMatch_Solo_Not_Possible_No_Teammates");
        }
    }

    if (listBuffer[0] != '\0') CPrintToChatAll("%t", "DeathMatch_Solo_Announce_Soloers", listBuffer);

    RoundStarted = true;
}

public void Event_PlayerSpawnDM(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients) return;
    if (!NERActive) return;

    bool wasSpawned = SpawnedThisRound[client];
    SpawnedThisRound[client] = true;

    // PHANTOM DETECTION: a spawn within 2s of joining a team, with the client
    // reading alive, is the arena bench-seating spawn (joiner never really
    // enters play). Marked so the sweep can override SpawnedThisRound for it.
    if (!wasSpawned && JoinTeamTime[client] > 0.0
        && GetGameTime() - JoinTeamTime[client] < 2.0)
    {
        if (CvarVerbose.BoolValue)
                    LogMessage("[DM-NER] spawn: %N within %.2fs of team join — PHANTOM BENCH SPAWN (flag stays %s)",
            client, GetGameTime() - JoinTeamTime[client],
            SpawnedThisRound[client] ? "true" : "false");
        SpawnedThisRound[client] = false;   // bench seating is NOT real play
    }
    else
    {
        if (CvarVerbose.BoolValue)
                    LogMessage("[DM-NER] spawn: %N (real — flag now true)", client);
    }
}

// Bench sweep (backstop, 2s while NER owns a round): any roster member who is
// on a team, not solo, never spawned this round, and currently dead is a
// benched joiner or a failed respawn — bring them in. Killed players are
// excluded by SpawnedThisRound (their deaths stick by design).
// NER resolution (v3): a side just emptied and no spares to move. Everyone
// NOT on the surviving side is dead or benched — team changes are safe.
// Shuffle all dead roster members, assign them balanced around the
// survivors, respawn them. The round keeps running: SetWinningTeam is
// blocked, so the engine never even noticed the empty side.
void Frame_ResolveCycle(any userid)
{
    if (!NERActive || !RoundStarted) return;
    if (CountLifecycleRoster() == 0) return;   // kick-all / empty server noise
    // A move may have repaired the side between queueing and now — no full
    // respawn needed in that case.
    if (GetTeamAliveCount(view_as<int>(TFTeam_Red)) > 0 && GetTeamAliveCount(view_as<int>(TFTeam_Blue)) > 0)
        return;

    int victim = GetClientOfUserId(userid);

    // Survivors (alive, roster) stay put — their team shapes the refill.
    int aliveRed = 0, aliveBlue = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!NERLifecycle[client] || !IsAliveInGame(client)) continue;
        int team = GetClientTeam(client);
        if (team == view_as<int>(TFTeam_Red))  aliveRed++;
        if (team == view_as<int>(TFTeam_Blue)) aliveBlue++;
    }

    // Collect dead roster members (includes benched joiners).
    int pool[MAXPLAYERS + 1];
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!NERLifecycle[client])          continue;
        if (!IsClientInGame(client))        continue;
        if (SoloEnabled[client])            continue;   // soloers sit out by choice
        if (SpawnedThisRound[client] && IsPlayerAlive(client))
            continue;                                    // genuine survivor — stays
        if (IsSpectatorTeam(client) && GetEntProp(client, Prop_Send, "m_lifeState") == 0)
            continue;                                    // living spectator — released
        // Includes killed players (flag set, dead) AND benched joiners
        // (flag clear — IsPlayerAlive reads TRUE for them with no pawn).
        pool[count++] = client;
    }

    // Fisher-Yates shuffle
    for (int i = count - 1; i > 0; i--)
    {
        int j = GetRandomInt(0, i);
        int tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp;
    }

    // Assign balanced around survivors, then respawn OUTSIDE the death tick
    // (this is a frame callback — TF2_RespawnPlayer is reliable here).
    int placedRed = aliveRed, placedBlue = aliveBlue;
    for (int i = 0; i < count; i++)
    {
        int team = (placedRed <= placedBlue) ? view_as<int>(TFTeam_Red) : view_as<int>(TFTeam_Blue);
        if (GetClientTeam(pool[i]) != team)
            ChangeClientTeam(pool[i], team);
        TF2_RespawnPlayer(pool[i]);
        ClientRespawnTime[pool[i]] = GetGameTime();
        ApplyRespawnShieldVisual(pool[i]);
        if (team == view_as<int>(TFTeam_Red)) placedRed++; else placedBlue++;
    }

    char poolNames[256];
    for (int i = 0; i < count && i < 12; i++)
    {
        char nb[40];
        if (i == 0) FormatEx(nb, sizeof(nb), "%N", pool[i]);
        else        FormatEx(nb, sizeof(nb), ", %N", pool[i]);
        StrCat(poolNames, sizeof(poolNames), nb);
    }
    if (CvarVerbose.BoolValue)
            LogMessage("[DM-NER] resolve: victim=%d side emptied; pool=[%s]; respawned+reshuffled %d dead -> %dr %db (survivors kept)",
        victim, poolNames, count, placedRed, placedBlue);
}

public Action Timer_BenchSweep(Handle timer)
{
    if (!NERActive || !RoundStarted) return Plugin_Continue;

    // Keep the respawn-shield visual alive for everyone inside the protection
    // window (conditions get stripped by heals/round events; 0.2s condition
    // re-applied every sweep tick = continuous shimmer for the full window).
    float now2 = GetGameTime();
    for (int c = 1; c <= MaxClients; c++)
    {
        if (ClientRespawnTime[c] <= 0.0) continue;
        if (now2 >= ClientRespawnTime[c] + CvarRespawnProtection.FloatValue) continue;
        ApplyRespawnShieldVisual(c);
    }

    // Throttled roster heartbeat: once per 10s, the sweep logs a one-line
    // roster census so skipped players are visible from the log alone.
    if (now2 - g_fLastSweepCensus > 10.0)
    {
        g_fLastSweepCensus = now2;
        int roster = 0, spawned = 0, aliveR = 0, aliveB = 0;
        for (int c = 1; c <= MaxClients; c++)
        {
            if (!NERLifecycle[c] || !IsClientInGame(c)) continue;
            roster++;
            if (SpawnedThisRound[c]) spawned++;
            if (!IsPlayerAlive(c)) continue;
            int t = GetClientTeam(c);
            if (t == view_as<int>(TFTeam_Red))  aliveR++;
            if (t == view_as<int>(TFTeam_Blue)) aliveB++;
        }
        if (CvarVerbose.BoolValue)
                    LogMessage("[DM-NER] census: roster=%d spawned=%d alive=%dr+%db",
            roster, spawned, aliveR, aliveB);
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!NERLifecycle[client])       continue;
        if (!IsClientInGame(client))     continue;
        if (SoloEnabled[client])         continue;
        if (SpawnedThisRound[client])    continue;   // played this round — kills stick
        if (IsSpectatorTeam(client))     continue;

        // NOTE: no IsPlayerAlive check. A benched arena joiner has
        // m_lifeState=0 with no pawn — IsPlayerAlive reads TRUE forever
        // (live-proven 14:00 & 14:08: every alive-gated filter skipped the
        // benched bot). SpawnedThisRound is the sole discriminator; a forced
        // respawn sets the correct state, and if they were genuinely mid-
        // spawn the engine no-ops harmlessly.
        TF2_RespawnPlayer(client);
        ClientRespawnTime[client] = GetGameTime();
        ApplyRespawnShieldVisual(client);
        if (CvarVerbose.BoolValue)
                    LogMessage("[DM-NER] bench sweep: %N entered play", client);
    }
    return Plugin_Continue;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!RoundStarted) return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;

    LastDeadTeam = GetClientTeam(client);

    if (NERActive)
        if (CvarVerbose.BoolValue)
                    LogMessage("[DM-NER] death: %N team=%d | roster=%d spawned=%d alive=%d",
            client, LastDeadTeam, NERLifecycle[client], SpawnedThisRound[client], IsPlayerAlive(client));

    // NER v3 (gamedata detours): the round cannot end while NER is active —
    // SetWinningTeam/SetStalemate are superseded. Deaths STICK (no
    // respawn-on-death). When a side reaches 0 alive, move-or-resolve.
    //
    // MUST defer to the next frame: this is the PRE hook, the victim still
    // reads ALIVE in GetTeamAliveCount, and HandleSideEmptied's "already
    // repaired" guard would see 1 alive and bail — the live bug where the
    // last death never resolved and the dead bot stayed benched forever.
    // One frame later the death has settled and the counts are accurate.
    if (NERActive && RoundStarted)
        RequestFrame(Frame_HandleSideEmptied, LastDeadTeam);
}

// Side emptied. The game loop (user spec, final):
//   other side has 2+ alive  -> MOVE one of them over (instant m_lifeState-
//                                spoofed team change — the proven technique;
//                                player keeps position, dead STAY dead) so a
//                                1v1 duel forms with real stakes.
//   other side has <= 1      -> the duel kill landed: FULL resolve — respawn
//                                every dead roster member, reshuffled into
//                                balanced teams around the survivor.
// Detours guarantee the round cannot end either way, so timing is free.
void HandleSideEmptied(int emptyTeam, int dyingUserid)
{
    if (!NERActive || !RoundStarted) return;
    if (emptyTeam != view_as<int>(TFTeam_Red) && emptyTeam != view_as<int>(TFTeam_Blue)) return;
    int emptyCount = GetTeamAliveCount(emptyTeam);
    if (emptyCount > 0) return;  // already repaired (double event / move landed)

    int other = AnalogueTeam(emptyTeam);
    int otherCount = GetTeamAliveCount(other);
    if (otherCount >= 2)
    {
        int mover = PickAliveMover(other);
        if (mover > 0)
        {
            MoveAliveClient(mover, emptyTeam);
            return;
        }
    }
    RequestFrame(Frame_ResolveCycle, dyingUserid);
}

void Frame_HandleSideEmptied(any emptyTeam)
{
    HandleSideEmptied(view_as<int>(emptyTeam), 0);
}

// Random alive roster member of 'team' to move; soloers only as last resort.
int PickAliveMover(int team)
{
    int pool[MAXPLAYERS + 1];  int n = 0;
    int solo[MAXPLAYERS + 1];  int s = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsAliveInGame(client))       continue;
        if (GetClientTeam(client) != team) continue;
        if (!NERLifecycle[client])        continue;
        if (SoloEnabled[client]) solo[s++] = client;
        else                     pool[n++] = client;
    }
    if (n > 0) return pool[GetRandomInt(0, n - 1)];
    if (s > 0) return solo[GetRandomInt(0, s - 1)];
    return -1;
}

// Instant alive-player team change (proven live): spoof dead so the engine's
// team-change path doesn't kill/respawn us, change team, restore, recount.
// The mover keeps their position — the 1v1 forms seamlessly.
void MoveAliveClient(int client, int toTeam)
{
    SetEntProp(client, Prop_Send, "m_lifeState", 2);
    ChangeClientTeam(client, toTeam);
    SetEntProp(client, Prop_Send, "m_lifeState", 0);
    TFDB_RecountAlive();

    // Crossfire protection: rocket targets lock at spawn and only re-pick on
    // deflection — a rocket locked on this player BEFORE the move still flies
    // at him mid-transition (live-observed: moved player standing on his old
    // side with an inbound rocket). The respawn-protection window keeps the
    // freshly moved duelist alive through that one crossing instead of
    // instantly re-emptying the side we just repaired.
    ClientRespawnTime[client] = GetGameTime();
    ApplyRespawnShieldVisual(client);

    if (CvarVerbose.BoolValue)
            LogMessage("[DM-NER] move: %N -> team %d (1v1 duel forms; dead stay dead)", client, toTeam);
}

/**
 * player_team handler. If a player switches to spectate (or unassigned) while
 * NER is active, their old team may now be at 0 or 1 alive. Defer to next frame
 * so the team change is fully processed, then trigger NER if needed.
 */
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    if (!NERActive) return;
    if (event.GetBool("disconnect")) return;  // handled by OnClientDisconnect

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;

    // TF2's player_team fields are "team"/"oldteam" (NOT "newteam" — that is
    // the CS:S name; reading it returned 0 for every event and silently broke
    // ALL mid-round roster capture: joiners were treated as spectators and
    // never rostered — live-proven 14:00/14:08/14:14/14:21 bench bugs).
    int newTeam = event.GetInt("team");
    int oldTeam = event.GetInt("oldteam");

    // Full-state trace: every team event under NER is logged so bench-joiner
    // bugs are diagnosable from the server log alone. (tfdb_dm_verbose 1)
    if (CvarVerbose.BoolValue)
    LogMessage("[DM-NER] team-event: %N new=%d old=%d disc=%d | roster=%d spawned=%d alive=%d hp=%d class=%d",
        client, newTeam, oldTeam, event.GetBool("disconnect"),
        NERLifecycle[client], SpawnedThisRound[client], IsPlayerAlive(client),
        (client > 0 && IsClientInGame(client)) ? GetClientHealth(client) : -1,
        (client > 0 && IsClientInGame(client)) ? view_as<int>(TF2_GetPlayerClass(client)) : -1);

    if (newTeam == view_as<int>(TFTeam_Red) || newTeam == view_as<int>(TFTeam_Blue))
    {
        NERLifecycle[client] = true;
        JoinTeamTime[client] = GetGameTime();

        // Fresh join (from spec/unassigned): clear the connection-time phantom
        // spawn flag so the bench override/sweep bring them into play. A
        // Red<->Blue switch keeps the flag (they're already playing).
        if (oldTeam != view_as<int>(TFTeam_Red) && oldTeam != view_as<int>(TFTeam_Blue))
            SpawnedThisRound[client] = false;

        // Bench override: arena seats mid-round joiners DEAD until next round,
        // but NER rounds don't end. IsPlayerAlive is NOT a valid gate here
        // (fresh joins read alive in the transition window — live bug 14:00).
        // Gate on the spawned-this-round flag after a short settle delay; the
        // 2s bench sweep is the backstop either way.
        if (RoundStarted && !SpawnedThisRound[client] && !SoloEnabled[client])
        {
            DataPack dp = new DataPack();
            dp.WriteCell(GetClientUserId(client));
            CreateTimer(0.4, Timer_BenchOverride, dp, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    else
    {
        // Left for spectator: release from roster; if that emptied their old
        // side, run the side-emptied logic next frame (move or full resolve).
        bool wasRoster = NERLifecycle[client];
        NERLifecycle[client] = false;
        if (wasRoster && RoundStarted)
        {
            if (oldTeam == view_as<int>(TFTeam_Red) || oldTeam == view_as<int>(TFTeam_Blue))
                RequestFrame(Frame_HandleSideEmptied, oldTeam);
        }
    }
}

// Mid-round joiner bench override (see Event_PlayerTeam). Delayed 0.4s so
// the engine's bench seating settles; gated on SpawnedThisRound so a joiner
// the engine DID spawn (e.g. during setup) is left alone.
public Action Timer_BenchOverride(Handle timer, any data)
{
    DataPack dp = view_as<DataPack>(data);
    dp.Reset();
    int client = GetClientOfUserId(dp.ReadCell());
    delete dp;
    if (!NERActive || !RoundStarted) return Plugin_Stop;
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return Plugin_Stop;
    if (SoloEnabled[client])       return Plugin_Stop;
    if (!NERLifecycle[client])     return Plugin_Stop;
    if (SpawnedThisRound[client])  return Plugin_Stop;   // engine spawned them
    if (IsPlayerAlive(client))     return Plugin_Stop;   // spawning right now

    int team = GetClientTeam(client);
    if (team != view_as<int>(TFTeam_Red) && team != view_as<int>(TFTeam_Blue)) return Plugin_Stop;

    TF2_RespawnPlayer(client);
    ClientRespawnTime[client] = GetGameTime();
    if (CvarVerbose.BoolValue)
            LogMessage("[DM-NER] bench override: %N joined mid-round and spawned in", client);
    return Plugin_Stop;
}

// ============================================================================
//  Damage hook — NER lethal prevention + respawn protection
// ============================================================================

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
                           int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
    if (victim <= 0 || victim > MaxClients)             return Plugin_Continue;
    if (!IsClientInGame(victim))                        return Plugin_Continue;

    // NER v3: no damage blocking. Kills ALWAYS land — the round cannot end
    // while NER is active (CTFGameRules::SetWinningTeam/SetStalemate are
    // detoured and superseded), so there is no death-tick race to dodge.
    // When a kill empties a side, Event_PlayerDeath resolves the cycle:
    // dead players are reshuffled into balanced teams and respawned.

    // Respawn protection window (existing logic)
    if (ClientRespawnTime[victim] <= 0.0)               return Plugin_Continue;
    if (GetGameTime() >= ClientRespawnTime[victim] + CvarRespawnProtection.FloatValue) return Plugin_Continue;

    damage = 0.0;
    return Plugin_Changed;
}

// ============================================================================
//  Commands
// ============================================================================

public Action Cmd_Solo(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[TFDB] sm_solo is an in-game command.");
        return Plugin_Handled;
    }
    if (!TFDB_IsRealHuman(client))
    {
        return Plugin_Handled;
    }
    // Solo only makes sense for active players. Spectators can't be "soloed"
    // (they're not even on a team) and the flag persisting across team changes
    // led to silent unpredictable behavior on rejoin.
    if (GetClientTeam(client) <= view_as<int>(TFTeam_Spectator))
    {
        if (TranslationPhraseExists("DeathMatch_MustBeOnTeam"))
            CReplyToCommand(client, "%t", "DeathMatch_MustBeOnTeam");
        else
            CReplyToCommand(client, "[TFDB] You must be on RED or BLU to enable solo.");
        return Plugin_Handled;
    }

    if (!CvarSoloEnabled.BoolValue)
    {
        CReplyToCommand(client, "%t", "DeathMatch_Solo_Not_Allowed");
        return Plugin_Handled;
    }

    // Toggle off
    if (SoloEnabled[client])
    {
        SoloEnabled[client] = false;
        CPrintToChat(client, "%t", "DeathMatch_Solo_Toggled_Off");
        return Plugin_Handled;
    }

    // Cannot solo if last alive on team
    if (IsAliveInGame(client) && GetTeamAliveCount(GetClientTeam(client)) == 1)
    {
        CPrintToChat(client, "%t", "DeathMatch_Solo_Not_Possible_Last_Alive");
        return Plugin_Handled;
    }

    // Toggle on — if alive, sit out immediately (resolution skips soloers)
    if (IsAliveInGame(client) && RoundStarted)
    {
        ForcePlayerSuicide(client);
    }

    SoloEnabled[client] = true;
    CPrintToChat(client, "%t", "DeathMatch_Solo_Toggled_On");
    return Plugin_Handled;
}

public Action Cmd_ToggleDeathMatch(int client, int args)
{
    if (!CvarNEREnabled.BoolValue)
    {
        CReplyToCommand(client, "%t", "DeathMatch_NER_Not_Allowed");
        return Plugin_Handled;
    }

    if (!CanActivateDeathMatch())
    {
        CReplyToCommand(client, "%t", "DeathMatch_Blocked_Conflict");
        return Plugin_Handled;
    }

    ToggleNER();
    return Plugin_Handled;
}

public Action Cmd_VoteDeathMatch(int client, int args)
{
    // Guard quartet — was missing all four. console (client=0) hitting this
    // would crash on the FormatEx %T path with an invalid client.
    if (client == 0)
    {
        ReplyToCommand(client, "Command is in-game only.");
        return Plugin_Handled;
    }
    if (!TFDB_IsRealHuman(client))
    {
        return Plugin_Handled;
    }
    if (GetClientTeam(client) <= view_as<int>(TFTeam_Spectator))
    {
        if (TranslationPhraseExists("DeathMatch_MustBeOnTeam"))
            CReplyToCommand(client, "%t", "DeathMatch_MustBeOnTeam");
        else
            CReplyToCommand(client, "[TFDB] You must be on RED or BLU to call a DeathMatch vote.");
        return Plugin_Handled;
    }

    if (!CvarNEREnabled.BoolValue)
    {
        CReplyToCommand(client, "%t", "DeathMatch_NER_Not_Allowed");
        return Plugin_Handled;
    }

    if (!CanActivateDeathMatch())
    {
        CReplyToCommand(client, "%t", "DeathMatch_Blocked_Conflict");
        return Plugin_Handled;
    }

    // Cooldown check — the original logic was inverted (treated "never voted"
    // as "on cooldown"). Fixed: reject if LastVoteTime > 0 AND cooldown window unexpired.
    if (LastVoteTime > 0.0 && LastVoteTime + CvarNERVoteTimeout.FloatValue > GetGameTime())
    {
        float remaining = LastVoteTime + CvarNERVoteTimeout.FloatValue - GetGameTime();
        CReplyToCommand(client, "%t", "DeathMatch_NERVote_Cooldown", remaining);
        return Plugin_Handled;
    }

    if (IsVoteInProgress())
    {
        CReplyToCommand(client, "%t", "DeathMatch_Vote_Conflict");
        return Plugin_Handled;
    }

    Menu menu = new Menu(MenuHandler_Vote);
    menu.VoteResultCallback = VoteResult_NER;

    // Menu title is seen by whoever called the vote; route through translation.
    // Per-client %T would be better for multi-language servers, but Menu.SetTitle
    // is a single string — use the caller's language, fall back to "server language".
    char titleBuffer[64];
    FormatEx(titleBuffer, sizeof(titleBuffer), "%T", NERActive ? "DeathMatch_Vote_Menu_Title_Disable" : "DeathMatch_Vote_Menu_Title_Enable", client);
    menu.SetTitle(titleBuffer);
    menu.AddItem("0", "Yes");
    menu.AddItem("1", "No");

    int voterCount = 0;
    int[] voters = new int[MaxClients];
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!TFDB_IsRealHumanPlaying(c)) continue;  // specs don't vote on active gameplay
        voters[voterCount++] = c;
    }

    menu.DisplayVote(voters, voterCount, 10);
    LastVoteTime = GetGameTime();
    return Plugin_Handled;
}

void ToggleNER()
{
    if (!NERActive)
    {
        SetNERActive(true);
        CPrintToChatAll("%t", "DeathMatch_NER_Enabled");
    }
    else
    {
        SetNERActive(false);
        CPrintToChatAll("%t", "DeathMatch_NER_Disabled");
    }
}

// ============================================================================
//  Vote menu callbacks
// ============================================================================

public int MenuHandler_Vote(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) delete menu;
    return 0;
}

public void VoteResult_NER(Menu menu, int numVotes, int numClients, const int[][] clientInfo,
                           int numItems, const int[][] itemInfo)
{
    int winner = 0;

    if (numItems > 1 && itemInfo[0][VOTEINFO_ITEM_VOTES] == itemInfo[1][VOTEINFO_ITEM_VOTES])
        winner = GetRandomInt(0, 1);

    char winnerStr[8];
    menu.GetItem(itemInfo[winner][VOTEINFO_ITEM_INDEX], winnerStr, sizeof(winnerStr));

    if (StrEqual(winnerStr, "0"))
    {
        if (CanActivateDeathMatch()) ToggleNER();
        else                         CPrintToChatAll("%t", "DeathMatch_Blocked_Conflict");
    }
    else
    {
        CPrintToChatAll("%t", "DeathMatch_NERVote_Failed");
    }
}

// ============================================================================
//  Helpers
// ============================================================================

// Visual marker for the NER respawn-protection window. Live-verified bug:
// TFCond_UberchargedHidden (51) renders NOTHING (it exists precisely to be
// invisible for out-of-bounds MvM robots) — users saw no effect. Use
// TFCond_UberchargedCanteen (52): visible invulnerability effect, and unlike
// plain TFCond_Ubercharged (5) it is not stripped by healing or other uber
// effects. Purely cosmetic — the actual immunity is damage=0 in OnTakeDamage,
// which survives any condition being stripped. Re-applied every sweep tick
// while the window is open so the visual tracks the real protection.
void ApplyRespawnShieldVisual(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;
    if (!IsPlayerAlive(client)) return;
    TF2_AddCondition(client, TFCond_UberchargedCanteen, 2.2);
}

bool IsAliveInGame(int client)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client))            return false;
    return IsPlayerAlive(client);
}

bool IsSpectatorTeam(int client)
{
    int team = GetClientTeam(client);
    return team == view_as<int>(TFTeam_Spectator) || team == view_as<int>(TFTeam_Unassigned);
}

int GetTeamAliveCount(int team)
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsAliveInGame(client) && GetClientTeam(client) == team) count++;
    }
    return count;
}

void DMDebugLog(const char[] fmt, any ...)
{
    if (!CvarVerbose.BoolValue) return;
    char msg[256];
    VFormat(msg, sizeof(msg), fmt, 2);
    LogMessage("[DM-DBG] %s", msg);
}

public Action Cmd_DMDebug(int client, int args)
{
    if (args > 0)
    {
        char arg[4];
        GetCmdArg(1, arg, sizeof(arg));
        CvarVerbose.SetInt(StringToInt(arg) != 0);
    }

    // Full NER state dump — one line per in-game client.
    ReplyToCommand(client, "[DM-NER] state dump (NER=%d round=%d):", NERActive, RoundStarted);
    ReplyToCommand(client, "  #  name                 team roster spawned alive hp class tSinceJoin");
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c)) continue;
        char nm[MAX_NAME_LENGTH];
        GetClientName(c, nm, sizeof(nm));
        float tj = (JoinTeamTime[c] > 0.0) ? (GetGameTime() - JoinTeamTime[c]) : -1.0;
        ReplyToCommand(client, "  %2d %-20s %4d %5d %7d %5d %3d %4d %8.1f",
            c, nm, GetClientTeam(c), NERLifecycle[c], SpawnedThisRound[c],
            IsPlayerAlive(c), GetClientHealth(c),
            view_as<int>(TF2_GetPlayerClass(c)), tj);
    }
    return Plugin_Handled;
}
