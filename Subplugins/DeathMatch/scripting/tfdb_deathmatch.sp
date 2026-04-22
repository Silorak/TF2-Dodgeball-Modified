#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <multicolors>

#include <tfdb>
#include <tfdb_guardian>
#include <tfdb_pvb>

#define PLUGIN_NAME        "[TFDB] DeathMatch"
#define PLUGIN_AUTHOR      "Mikah (NER/SOLO v1.5.3) + Silorak (TFDB integration)"
#define PLUGIN_DESCRIPTION "Never-Ending Rounds + Solo queue for TF2 Dodgeball"
#define PLUGIN_VERSION     "2.2.0"
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
//  State
// ============================================================================

// NER (Never-Ending Rounds)
float LastVoteTime = 0.0;
bool  NERActive    = false;

int   OldTeam   [MAXPLAYERS + 1];
int   AllPlayers[MAXPLAYERS + 1];  // fisher-yates shuffle scratch

// Solo queue
ArrayStack SoloQueue = null;
bool       SoloEnabled[MAXPLAYERS + 1];

// Round state
bool  RoundStarted    = false;
int   LastDeadTeam    = view_as<int>(TFTeam_Red);

// Per-client respawn-protection window. Global was a bug in v1.5.3 — it granted
// 2s of immunity to ALL players whenever anyone respawned, which let the server
// briefly be a safe-zone every time NER fired.
float ClientRespawnTime[MAXPLAYERS + 1];

// Cached cvars
ConVar CvarNERVoteTimeout;
ConVar CvarForceNER;
ConVar CvarForceNERStartMap;
ConVar CvarNEREnabled;
ConVar CvarSoloEnabled;
ConVar CvarSoloPriority;
ConVar CvarHornVolume;
ConVar CvarRespawnProtection;
ConVar CvarSeeBotsAsPlayers;

// FFA cache — FFA is allowed to coexist; NER switches behavior when it's on.
// Retried on null so late-load order is handled cleanly.
ConVar FFACvar = null;

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

    RegAdminCmd("sm_dm_ner",   Cmd_ToggleNER, ADMFLAG_CONFIG, "[TFDB] Toggle Never-Ending Rounds mode");
    RegConsoleCmd("sm_votener", Cmd_VoteNER,                   "Vote to toggle Never-Ending Rounds");
    RegConsoleCmd("sm_solo",    Cmd_Solo,                      "Join/leave the solo queue (respawn at round end)");

    CvarNERVoteTimeout    = CreateConVar("tfdb_dm_ner_vote_timeout",   "120",  "NER vote cooldown in seconds",                                  _, true, 0.0);
    CvarForceNER          = CreateConVar("tfdb_dm_ner_force",          "0",    "Force NER on (cannot be disabled via vote or admin)",            _, true, 0.0, true, 1.0);
    CvarForceNERStartMap  = CreateConVar("tfdb_dm_ner_force_start",    "0",    "Enable NER at map start",                                        _, true, 0.0, true, 1.0);
    CvarNEREnabled        = CreateConVar("tfdb_dm_ner_enabled",        "1",    "Enable Never-Ending Rounds feature",                             _, true, 0.0, true, 1.0);
    CvarSoloEnabled       = CreateConVar("tfdb_dm_solo_enabled",       "1",    "Enable Solo queue feature",                                      _, true, 0.0, true, 1.0);
    CvarSoloPriority      = CreateConVar("tfdb_dm_solo_priority",      "1",    "Respawn soloers before switching alive teammates",               _, true, 0.0, true, 1.0);
    CvarHornVolume        = CreateConVar("tfdb_dm_horn_volume",        "0.5",  "Volume (0.0-1.0) of the horn played when players respawn",       _, true, 0.0, true, 1.0);
    CvarRespawnProtection = CreateConVar("tfdb_dm_respawn_protection", "2.0",  "Seconds of damage immunity after a DeathMatch respawn",          _, true, 0.0);
    CvarSeeBotsAsPlayers  = CreateConVar("tfdb_dm_bots_as_players",    "0",    "Debug: treat bots as players for NER (for local bot testing)",   _, true, 0.0, true, 1.0);

    CvarNEREnabled.AddChangeHook(OnCvarChanged);
    CvarSoloEnabled.AddChangeHook(OnCvarChanged);

    // Events are plugin-lifetime — hook once, SourceMod auto-unhooks on unload.
    HookEvent("arena_round_start",         Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_death",              Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("teamplay_round_win",        Event_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_stalemate",  Event_RoundEnd,   EventHookMode_PostNoCopy);

    // Persistent across maps — SoloQueue reinitializes on map start for safety.
    SoloQueue = new ArrayStack(1);

    // Handle late-load (plugin loaded mid-round)
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client)) OnClientPutInServer(client);
    }

    AutoExecConfig(true, "tfdb_deathmatch");
}

public void OnConfigsExecuted()
{
    if (CvarForceNERStartMap.BoolValue && CanActivateDeathMatch()) NERActive = true;

    PrecacheSound(SOUND_RESPAWN, true);

    // Stale queue from prior map (soloer indices don't persist across maps).
    if (SoloQueue != null) SoloQueue.Clear();
    RoundStarted = false;
    for (int c = 0; c <= MaxClients; c++) ClientRespawnTime[c] = 0.0;
}

// No OnMapEnd manual UnhookEvent — that anti-pattern crashes when other
// subplugins unhook shared events first. SourceMod handles cleanup on unload.

public void OnPluginEnd()
{
    // Explicit handle cleanup on unload. SM auto-cleans most handles but being
    // explicit about the ArrayStack keeps the lifecycle obvious.
    if (SoloQueue != null) { delete SoloQueue; SoloQueue = null; }
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
    if (LibraryExists("tfdb_pvb") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsPvBActive") == FeatureStatus_Available &&
        TFDB_IsPvBActive())
    {
        return false;
    }

    if (LibraryExists("tfdb_guardian") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsGuardianActive") == FeatureStatus_Available &&
        TFDB_IsGuardianActive())
    {
        return false;
    }

    return true;
}

// If PvB or Guardian starts while DM is active, force-disable DM cleanly.
public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "tfdb_pvb") || StrEqual(name, "tfdb_guardian"))
    {
        if (NERActive)
        {
            NERActive = false;
            CPrintToChatAll("%t", "DeathMatch_NER_Disabled_Conflict");
        }
    }
}

// ============================================================================
//  Native surface
// ============================================================================

public any Native_IsDeathMatchActive(Handle plugin, int numParams)
{
    return NERActive || (SoloQueue != null && !SoloQueue.Empty);
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
        NERActive = false;
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
        if (SoloQueue != null) SoloQueue.Clear();
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
    if (SoloQueue != null) SoloQueue.Clear();
    for (int c = 0; c <= MaxClients; c++) ClientRespawnTime[c] = 0.0;

    // Adapt to Guardian / PvB loading mid-round.
    if (NERActive && !CanActivateDeathMatch())
    {
        NERActive = false;
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
            if (SoloQueue.Empty) FormatEx(nameBuffer, sizeof(nameBuffer), "%N", client);
            else                 FormatEx(nameBuffer, sizeof(nameBuffer), ", %N", client);

            StrCat(listBuffer, sizeof(listBuffer), nameBuffer);
            SoloQueue.Push(client);
            ForcePlayerSuicide(client);
        }
        else
        {
            SoloEnabled[client] = false;
            CPrintToChat(client, "%t", "DeathMatch_Solo_Not_Possible_No_Teammates");
        }
    }

    if (!SoloQueue.Empty) CPrintToChatAll("%t", "DeathMatch_Solo_Announce_Soloers", listBuffer);

    RoundStarted = true;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!RoundStarted) return;

    if (CvarForceNER.BoolValue && CanActivateDeathMatch()) NERActive = true;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || !IsClientInGame(client)) return;

    LastDeadTeam = GetClientTeam(client);

    // 1v1 or lower: NER makes no sense.
    if (NERActive &&
        GetTeamClientCount(LastDeadTeam)              <= 1 &&
        GetTeamClientCount(AnalogueTeam(LastDeadTeam)) <= 1)
    {
        CPrintToChatAll("%t", "DeathMatch_NER_Disabled_Not_Enough_Players");
        LastVoteTime = 0.0;
        NERActive    = false;
    }

    if (GetTeamAliveCount(LastDeadTeam) != 1) return;

    // Case 1 — NER swap: someone on other team moves over.
    if (NERActive && GetTeamAliveCount(AnalogueTeam(LastDeadTeam)) > 1)
    {
        // Solo priority: respawn a soloer instead of swapping alive players.
        if (CvarSoloPriority.BoolValue && TryRespawnQueuedSoloer(LastDeadTeam)) return;

        int opponent = GetTeamRandomAliveClient(AnalogueTeam(LastDeadTeam));
        if (opponent > 0)
        {
            OldTeam[opponent] = AnalogueTeam(LastDeadTeam);
            ChangeAliveClientTeam(opponent, LastDeadTeam);
        }
        return;
    }

    // Case 2 — team reduced, soloers waiting: respawn a soloer onto the drained side.
    if (TryRespawnQueuedSoloer(LastDeadTeam)) return;

    // Case 3 — NER, both teams down to 1: respawn everyone and reshuffle.
    if (NERActive && GetTeamAliveCount(AnalogueTeam(LastDeadTeam)) == 1)
    {
        ReshuffleAndRespawnAll(client);
    }
}

/**
 * Pop soloers off the queue until we find a valid one (still connected, still
 * has solo enabled, still dead, not spectating). Respawn them on targetTeam.
 * Returns true if a soloer was respawned.
 */
bool TryRespawnQueuedSoloer(int targetTeam)
{
    if (SoloQueue == null || SoloQueue.Empty) return false;

    int soloer = 0;
    while (!SoloQueue.Empty)
    {
        int candidate = SoloQueue.Pop();
        if (candidate <= 0 || candidate > MaxClients) continue;
        if (!IsClientInGame(candidate))               continue;
        if (!SoloEnabled[candidate])                  continue;
        if (IsSpectatorTeam(candidate))               continue;
        if (IsPlayerAlive(candidate))                 continue;

        soloer = candidate;
        break;
    }

    if (soloer == 0) return false;

    ChangeClientTeam(soloer, targetTeam);
    TF2_RespawnPlayer(soloer);
    ClientRespawnTime[soloer] = GetGameTime();
    EmitSoundToClient(soloer, SOUND_RESPAWN, _, _, _, _, CvarHornVolume.FloatValue);
    return true;
}

/**
 * Both teams down to 1, NER active, no soloers to help — full respawn + reshuffle.
 * Uses Fisher-Yates. The "client" argument is the player that JUST died (PRE-hook),
 * respawned on next frame to avoid respawning a still-alive entity.
 */
void ReshuffleAndRespawnAll(int deadClient)
{
    // In bot scenarios (PvB shouldn't reach here due to mutex, but edge case),
    // let the bot's state decide if the round can proceed.
    int bot = GetBotClient();

    char listBuffer[512];
    char nameBuffer[64];

    SoloQueue.Clear();
    int winner        = GetTeamRandomAliveClient(AnalogueTeam(LastDeadTeam));
    int markedSoloer  = 0;
    int totalPlayers  = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)) continue;
        if (IsSpectatorTeam(client)) continue;
        if (client == bot)           continue;

        int lifeState = GetEntProp(client, Prop_Send, "m_lifeState");
        if (!lifeState) continue;  // dead — handled via respawn loop

        if (!SoloEnabled[client])
        {
            if (totalPlayers < sizeof(AllPlayers)) AllPlayers[totalPlayers++] = client;
        }
        else
        {
            markedSoloer = client;
        }
    }

    // Nobody available? Pull one soloer off solo so the round doesn't end.
    if (totalPlayers == 0 && markedSoloer > 0)
    {
        AllPlayers[totalPlayers++] = markedSoloer;
        SoloEnabled[markedSoloer]  = false;
        CPrintToChat(markedSoloer, "%t", "DeathMatch_Solo_Not_Possible_NER_Would_End");
    }

    // FFA active: respawn everyone on whichever team they were — no swap.
    bool ffaActive = IsFFACvarActive();
    int  newTeam   = ffaActive ? LastDeadTeam : LastDeadTeam;  // default
    if (!ffaActive && bot > 0) newTeam = AnalogueTeam(GetClientTeam(bot));

    for (int i = totalPlayers - 1; i >= 0; i--)
    {
        int j = GetRandomInt(0, i);
        int pick = AllPlayers[j];

        if (pick <= 0 || pick > MaxClients || !IsClientInGame(pick))
        {
            AllPlayers[j] = AllPlayers[i];
            continue;
        }

        ChangeClientTeam(pick, newTeam);
        TF2_RespawnPlayer(pick);

        if (!ffaActive && bot == 0) newTeam = AnalogueTeam(newTeam);
        AllPlayers[j] = AllPlayers[i];
    }

    // Second pass — catch any respawn that didn't take (rare but historic bug).
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))     continue;
        if (IsSpectatorTeam(client))     continue;
        if (SoloEnabled[client])         continue;
        if (IsPlayerAlive(client))       continue;
        if (client == bot)               continue;

        ChangeClientTeam(client, newTeam);
        TF2_RespawnPlayer(client);
        if (!ffaActive && bot == 0) newTeam = AnalogueTeam(newTeam);
    }

    // Bookkeeping for soloers who didn't get priority this round.
    int remainingRed  = GetTeamClientCount(view_as<int>(TFTeam_Red))  - 1;
    int remainingBlue = GetTeamClientCount(view_as<int>(TFTeam_Blue)) - 1;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)) continue;
        if (IsSpectatorTeam(client)) continue;
        if (!SoloEnabled[client])    continue;
        if (client == winner)        continue;

        int team = GetClientTeam(client);
        int room = (team == view_as<int>(TFTeam_Red)) ? remainingRed-- : remainingBlue--;

        if (room > 0)
        {
            if (SoloQueue.Empty) FormatEx(nameBuffer, sizeof(nameBuffer), "%N", client);
            else                 FormatEx(nameBuffer, sizeof(nameBuffer), ", %N", client);
            StrCat(listBuffer, sizeof(listBuffer), nameBuffer);
            SoloQueue.Push(client);

            CPrintToChat(client, "%t",
                CvarSoloPriority.BoolValue
                    ? "DeathMatch_Solo_Notify_Not_Respawned_Mid_Round"
                    : "DeathMatch_Solo_Notify_Not_Respawned");
        }
        else
        {
            SoloEnabled[client] = false;
            CPrintToChat(client, "%t", "DeathMatch_Solo_Not_Possible_NER_Would_End");
            TF2_RespawnPlayer(client);
        }
    }

    // Winner — re-queue for solo if they want it and team allows.
    if (winner > 0 && winner <= MaxClients && SoloEnabled[winner])
    {
        if (GetTeamAliveCount(AnalogueTeam(LastDeadTeam)) > 1)
        {
            if (SoloQueue.Empty) FormatEx(nameBuffer, sizeof(nameBuffer), "%N", winner);
            else                 FormatEx(nameBuffer, sizeof(nameBuffer), ", %N", winner);
            StrCat(listBuffer, sizeof(listBuffer), nameBuffer);
            SoloQueue.Push(winner);

            CPrintToChat(winner, "%t",
                CvarSoloPriority.BoolValue
                    ? "DeathMatch_Solo_Notify_Not_Respawned_Mid_Round"
                    : "DeathMatch_Solo_Notify_Not_Respawned");
            ForcePlayerSuicide(winner);
        }
        else
        {
            SoloEnabled[winner] = false;
            CPrintToChat(winner, "%t", "DeathMatch_Solo_Not_Possible_NER_Would_End");
            SetEntityHealth(winner, 175);
        }
    }
    else if (winner > 0 && winner <= MaxClients)
    {
        SetEntityHealth(winner, 175);
    }

    // deadClient is still alive in the entity sense (PRE-hook), so defer respawn.
    if (deadClient > 0 && deadClient <= MaxClients)
    {
        RequestFrame(Frame_RespawnDeadClient, GetClientUserId(deadClient));
    }

    if (!SoloQueue.Empty) CPrintToChatAll("%t", "DeathMatch_Solo_Announce_Soloers", listBuffer);
}

void Frame_RespawnDeadClient(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return;
    if (SoloEnabled[client]) return;  // soloer — stays dead on purpose

    TF2_RespawnPlayer(client);
    ClientRespawnTime[client] = GetGameTime();

    for (int c = 1; c <= MaxClients; c++)
    {
        if (IsClientInGame(c) && !IsFakeClient(c) && !SoloEnabled[c])
            EmitSoundToClient(c, SOUND_RESPAWN, _, _, _, _, CvarHornVolume.FloatValue);
    }
}

// ============================================================================
//  Damage hook — respawn protection window
// ============================================================================

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
                           int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
    if (victim <= 0 || victim > MaxClients)             return Plugin_Continue;
    if (!IsClientInGame(victim))                        return Plugin_Continue;
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

    // Toggle on — if alive, add to queue and suicide
    if (IsAliveInGame(client) && RoundStarted)
    {
        SoloQueue.Push(client);
        ForcePlayerSuicide(client);
    }

    SoloEnabled[client] = true;
    CPrintToChat(client, "%t", "DeathMatch_Solo_Toggled_On");
    return Plugin_Handled;
}

public Action Cmd_ToggleNER(int client, int args)
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

public Action Cmd_VoteNER(int client, int args)
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
        if (!IsClientInGame(c) || IsFakeClient(c)) continue;
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
        NERActive = true;
        CPrintToChatAll("%t", "DeathMatch_NER_Enabled");
    }
    else
    {
        NERActive = false;
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

int GetTeamRandomAliveClient(int team)
{
    int[] clients = new int[MaxClients];
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsAliveInGame(client)) continue;
        if (GetClientTeam(client) != team) continue;
        clients[count++] = client;
    }

    return (count == 0) ? -1 : clients[GetRandomInt(0, count - 1)];
}

int GetBotClient()
{
    if (CvarSeeBotsAsPlayers.BoolValue) return 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && IsFakeClient(client)) return client;
    }
    return 0;
}

bool IsFFACvarActive()
{
    // Retry the FindConVar while null — handles the case where FFA plugin
    // loads AFTER DeathMatch and the first lookup returned null. Once found,
    // the handle stays valid (SM keeps ConVar handles across plugin reloads).
    if (FFACvar == null) FFACvar = FindConVar("tf_dodgeball_ffa_bot");
    return FFACvar != null && FFACvar.BoolValue;
}

/**
 * Swap a client's team without triggering a death. Also fixes cosmetic (wearable)
 * team colors so BLU-to-RED swaps don't leave players wearing the wrong skin.
 *
 * Replaces the original plugin's sendprop-offset memory hack with a safe
 * classname iteration. Two passes: one immediate, one on the next frame to
 * catch any wearable TF2 spawns during the team transition itself.
 */
void ChangeAliveClientTeam(int client, int team)
{
    SetEntProp(client, Prop_Send, "m_lifeState", 2);
    ChangeClientTeam(client, team);
    SetEntProp(client, Prop_Send, "m_lifeState", 0);

    FixWearableTeamColors(client, team);

    // Second pass next frame — TF2 occasionally re-spawns wearables during a
    // team change and they appear after our first iteration. Pack client +
    // team into one cell (userid lives in low 16 bits, team in upper 16).
    int userid = GetClientUserId(client);
    RequestFrame(Frame_FixWearables, (team << 16) | (userid & 0xFFFF));
}

void Frame_FixWearables(any packed)
{
    int userid = packed & 0xFFFF;
    int team   = (packed >> 16) & 0xFFFF;
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return;

    FixWearableTeamColors(client, team);
}

void FixWearableTeamColors(int client, int team)
{
    int maxents = GetMaxEntities();
    int skin    = (team == view_as<int>(TFTeam_Blue)) ? 1 : 0;

    for (int ent = MaxClients + 1; ent <= maxents; ent++)
    {
        if (!IsValidEntity(ent)) continue;

        char classname[32];
        GetEntityClassname(ent, classname, sizeof(classname));
        if (StrContains(classname, "tf_wearable") != 0) continue;

        int owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
        if (owner != client) continue;

        // Defensive: future TF2 wearable variants may lack one of these props.
        // HasEntProp gate avoids a plugin-halting error on unexpected classnames.
        if (HasEntProp(ent, Prop_Send, "m_nSkin"))    SetEntProp(ent, Prop_Send, "m_nSkin",    skin);
        if (HasEntProp(ent, Prop_Send, "m_iTeamNum")) SetEntProp(ent, Prop_Send, "m_iTeamNum", team);
    }
}
