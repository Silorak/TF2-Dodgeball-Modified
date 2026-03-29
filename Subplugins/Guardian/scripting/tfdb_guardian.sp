#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <multicolors>

#include <tfdb>
#include <tfdb_guardian>
#include <tf2attributes>

#define PLUGIN_NAME        "[TFDB] Guardian"
#define PLUGIN_AUTHOR      "Silorak"
#define PLUGIN_DESCRIPTION "Guardian mode for dodgeball - one powered player vs all"
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball-Modified"

#define MAX_GUARDIAN_CLASSES   16
#define HUD_UPDATE_INTERVAL    0.1

#define SOUND_SELECTED  "misc/killstreak.wav"
#define SOUND_READY     "buttons/button17.wav"
#define SOUND_ACTIVATE  "misc/halloween/spell_overheal.wav"

#define GUARDIAN_LOG_FILE    "logs/guardian_debug.log"
#define GUARDIAN_SEL_FILE    "logs/guardian_select.log"

// Resolved at plugin start via BuildPath — writes to addons/sourcemod/logs/
char GUARDIAN_LOG[PLATFORM_MAX_PATH];
char GUARDIAN_SEL[PLATFORM_MAX_PATH];

// ============================================================================
//  Data Structures
// ============================================================================

enum struct GuardianAbility
{
	char  Type[32];
	int   Button;
	float Cooldown;
	float Duration;
	float Arg1;
	float Arg2;
	char  Particle[PLATFORM_MAX_PATH];
}

enum struct GuardianClass
{
	char  Name[32];
	char  DisplayName[64];
	int   Health;
	int   Weight;

	GuardianAbility PrimaryAbility;
	GuardianAbility SecondaryAbility;
}

// ============================================================================
//  Globals
// ============================================================================

// Configuration
bool          enabled;
int           selectionChance;
float         hudX;
float         hudY;
int           hudColor[3];

// Next round status
bool          nextRoundIsGuardian;
// Classes
GuardianClass guardianClasses[MAX_GUARDIAN_CLASSES];
int           guardianClassCount;

// Active state
bool          guardianActive;
int           guardianClient;
int           activeClassIndex;
int           guardianMaxHP;
int           guardianCurrentHP;
bool          botMessageShown;

// Admin force for next round
int           forcedClient  = -1;
int           forcedClass   = -1;
int           lastGuardianUserId = 0; // Prevent same person twice in a row

// Primary Ability State
bool          primaryActive;
float         primaryExpireTime;
float         primaryNextUseTime;
int           primaryParticleRef = INVALID_ENT_REFERENCE;
Handle        primaryTimer       = null;

// Secondary Ability State
bool          secondaryActive;
float         secondaryExpireTime;
float         secondaryNextUseTime;
int           secondaryParticleRef = INVALID_ENT_REFERENCE;
Handle        secondaryTimer       = null;

// HUD
Handle        hudSync;
Handle        updateTimer;
Handle        primarySlowPulseTimer   = null;
Handle        secondarySlowPulseTimer = null;

// Boss HP bar entity
int           monsterResource = INVALID_ENT_REFERENCE;
int           debugBossState  = -1;

// Debug mode - toggled by !dguardian (admin only). Spawns bots and treats them as real players to simulate a full game.
bool          debugMode       = false;
// Set true during ActivateGuardian's TF2_RespawnPlayer call to suppress death-path cleanup
bool          guardianActivating = false;

// Opt-out system
int           optOutMinPlayers = 0;          // min players required before opt-out is honoured (0 = disabled)
bool          guardianOptOut[MAXPLAYERS + 1]; // per-client opt-out flag

// Edge detection for R key per-client
int           previousButtons[MAXPLAYERS + 1];

// FFA detection
ConVar        cvarFriendlyFire;

// Cached model indices for beam ring (precached once per map, reused in TriggerSlowPulse)
int           beamModelIndex  = -1;
int           haloModelIndex  = -1;

// Surgical Arena Limits
ConVar        cvUnbalanceLimit;
ConVar        cvAutoteambalance;

// ============================================================================
//  Plugin Info
// ============================================================================

public Plugin myinfo =
{
	name        = PLUGIN_NAME,
	author      = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = PLUGIN_URL
};

// ============================================================================
//  Lifecycle
// ============================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	CreateNative("TFDB_IsGuardianActive", Native_IsGuardianActive);
	CreateNative("TFDB_GetGuardian", Native_GetGuardian);
	CreateNative("TFDB_IsNextRoundGuardian", Native_IsNextRoundGuardian);
	
	RegPluginLibrary("tfdb_guardian");
	
	return APLRes_Success;
}

/**
 * Logs to the guardian selection log only when debugMode is active.
 * Prevents "Could not open file" errors when debug is off and the
 * log file doesn't exist yet. LogToFileEx creates the file on first
 * write, so the file only appears when debugging is actually enabled.
 */
void GuardianLog(const char[] format, any ...)
{
	if (!debugMode) return;

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	GuardianLog("%s", buffer);
}

/**
 * Logs to the guardian debug log only when debugMode is active.
 */
void GuardianDebugLog(const char[] format, any ...)
{
	if (!debugMode) return;

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	GuardianDebugLog("%s", buffer);
}

public void OnPluginStart()
{
	// Resolve log paths to addons/sourcemod/logs/ via BuildPath.
	// LogToFileEx takes raw paths — without BuildPath it resolves
	// relative to the game directory (tf/) which may not have a logs/ folder.
	BuildPath(Path_SM, GUARDIAN_LOG, sizeof(GUARDIAN_LOG), GUARDIAN_LOG_FILE);
	BuildPath(Path_SM, GUARDIAN_SEL, sizeof(GUARDIAN_SEL), GUARDIAN_SEL_FILE);

	LoadTranslations("tfdb.phrases");
	debugBossState = -1;

	RegAdminCmd("sm_forceguardian",  Command_ForceGuardian,  ADMFLAG_CONFIG, "Force a player as Guardian next round. Usage: sm_forceguardian <player> [class]");
	RegAdminCmd("sm_guardianclass",  Command_GuardianClass,  ADMFLAG_CONFIG, "Set guardian class for next round. Usage: sm_guardianclass <class>");
	RegAdminCmd("sm_removeguardian", Command_RemoveGuardian, ADMFLAG_CONFIG, "Remove the current Guardian mid-round.");

	hudSync = CreateHudSynchronizer();

	HookEventEx("teamplay_round_start", OnRoundStart);
	HookEventEx("teamplay_round_win",   OnRoundWin);
	HookEventEx("arena_round_start",    OnArenaRoundStart, EventHookMode_PostNoCopy);
	HookEventEx("player_death",         OnPlayerDeath);
	HookEventEx("player_spawn",         OnPlayerSpawn);
	HookEventEx("player_team",          OnPlayerTeamChange, EventHookMode_Pre);

	RegAdminCmd("sm_tfdb_bossstate", Command_BossState, ADMFLAG_ROOT); // Hidden debug
	RegAdminCmd("sm_dguardian", Command_DebugGuardian, ADMFLAG_ROOT, "Toggle guardian debug output.");
	RegConsoleCmd("sm_guardian",  Command_GuardianOptOut, "Toggle opt-out from being selected as Guardian.");
	

	cvarFriendlyFire = FindConVar("mp_friendlyfire");
	cvUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");
	cvAutoteambalance = FindConVar("mp_autoteambalance");

	AddCommandListener(Listener_BlockGuardianCommands, "kill");
	AddCommandListener(Listener_BlockGuardianCommands, "explode");
	AddCommandListener(Listener_BlockBLUJoin, "jointeam");
	AddCommandListener(Listener_BlockBLUJoin, "autoteam");
	AddCommandListener(Listener_BlockGuardianCommands, "spectate");
	AddCommandListener(Listener_BlockGuardianCommands, "spec");
	AddCommandListener(Listener_BlockGuardianCommands, "joinclass");
	AddCommandListener(Listener_BlockGuardianCommands, "changeclass");

	if (!TFDB_IsDodgeballEnabled()) return;

	TFDB_OnRocketsConfigExecuted("general.cfg");
}

public Action Listener_BlockGuardianCommands(int client, const char[] command, int argc)
{
	if (!guardianActive || client < 1 || client > MaxClients || !IsClientInGame(client) || client != guardianClient || !IsPlayerAlive(client))
	{
		return Plugin_Continue;
	}

	GuardianLog("[CMD] " ... "BlockGuardianCommands - BLOCKED '%s' from guardian %N (client=%d team=%d alive=%d)", command, client, client, GetClientTeam(client), IsPlayerAlive(client));
	CPrintToChat(client, "{red}[TFDB] You cannot use '%s' while you are the Guardian!", command);
	return Plugin_Handled;
}

// Handles jointeam and autoteam:
// - Guardian: blocked entirely (cannot leave BLU)
// - Non-guardian: redirected to RED if trying to join BLU
public Action Listener_BlockBLUJoin(int client, const char[] command, int argc)
{
	if (!guardianActive || client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return Plugin_Continue;
	}

	// Guardian cannot use jointeam or autoteam at all
	if (client == guardianClient && IsPlayerAlive(client))
	{
		GuardianLog("[CMD] " ... "BlockBLUJoin - BLOCKED '%s' from guardian %N (client=%d) - guardian is alive on BLU", command, client, client);
		CPrintToChat(client, "{red}[TFDB] You cannot use '%s' while you are the Guardian!", command);
		return Plugin_Handled;
	}

	// Non-guardian: block attempts to join BLU, redirect to RED
	if (strcmp(command, "autoteam", false) == 0)
	{
		GuardianLog("[CMD] " ... "BlockBLUJoin - autoteam from %N (client=%d team=%d) - redirecting to RED", client, client, GetClientTeam(client));
		CPrintToChat(client, "{olive}[TFDB]{default} Guardian round active. Moving you to {red}RED{default}.");
		FakeClientCommand(client, "jointeam red");
		return Plugin_Handled;
	}

	if (strcmp(command, "jointeam", false) == 0 && argc >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));

		if (strcmp(arg, "blue", false) == 0 || strcmp(arg, "3", false) == 0 || strcmp(arg, "auto", false) == 0)
		{
			GuardianLog("[CMD] " ... "BlockBLUJoin - jointeam %s from %N (client=%d team=%d) - redirecting to RED", arg, client, client, GetClientTeam(client));
			CPrintToChat(client, "{olive}[TFDB]{default} Guardian round active. Moving you to {red}RED{default}.");
			FakeClientCommand(client, "jointeam red");
			return Plugin_Handled;
		}
	}

	GuardianLog("[CMD] " ... "BlockBLUJoin - '%s %s' from %N (client=%d team=%d) - passed through", command, (argc >= 1) ? "..." : "", client, client, GetClientTeam(client));
	return Plugin_Continue;
}

// ============================================================================
//  API Natives
// ============================================================================

public any Native_IsGuardianActive(Handle plugin, int numParams)
{
	return guardianActive;
}

public any Native_GetGuardian(Handle plugin, int numParams)
{
	return guardianActive ? guardianClient : 0;
}

public any Native_IsNextRoundGuardian(Handle plugin, int numParams)
{
	return nextRoundIsGuardian;
}

public void OnPluginEnd()
{
	if (guardianActive)
	{
		CleanupGuardian(false);
	}

	StopUpdateTimer();
}

public void OnMapStart()
{
	debugBossState = -1;

	PrecacheSound(SOUND_SELECTED, true);
	PrecacheSound(SOUND_READY, true);
	PrecacheSound(SOUND_ACTIVATE, true);

	beamModelIndex = PrecacheModel("materials/sprites/laserbeam.vmt", true);
	haloModelIndex = PrecacheModel("materials/sprites/halo01.vmt", true);

	int ent = FindEntityByClassname(-1, "monster_resource");

	if (ent == -1)
	{
		ent = CreateEntityByName("monster_resource");

		if (IsValidEntity(ent))
		{
			DispatchSpawn(ent);
		}
	}

	if (ent != -1 && IsValidEntity(ent))
	{
		monsterResource = EntIndexToEntRef(ent);
	}
	else
	{
		monsterResource = INVALID_ENT_REFERENCE;
	}
}

public void OnMapEnd()
{
	nextRoundIsGuardian = false;
	debugBossState = -1;
	debugMode = false;
	ResetAllState();
	monsterResource = INVALID_ENT_REFERENCE;
}

public void TFDB_OnRocketsConfigExecuted(const char[] configFile)
{
	if (strcmp(configFile, "general.cfg") != 0) return;

	guardianClassCount = 0;
	ParseGuardianConfig();
}

public void OnClientDisconnect(int client)
{
	previousButtons[client] = 0;
	guardianOptOut[client]  = false;

	if (guardianActive && client == guardianClient)
	{
		CPrintToChatAll("%t", "Guardian_Disconnected", client);
		CleanupGuardian(false);
	}

	if (forcedClient == client)
	{
		forcedClient = -1;
	}
}

public void OnClientPostAdminCheck(int client)
{
	// Bot joined mid-guardian - cancel guardian round (skip in debugMode where bots are intentional test fodder)
	if (IsFakeClient(client) && guardianActive && !debugMode)
	{
		CPrintToChatAll("%t", "Guardian_BotJoined");
		CleanupGuardian(true);
		// Move the bot to spectator so it doesn't block future guardian reselection.
		// HasActiveBots() checks for bots on teams > 1, so leaving the bot on RED/BLU
		// would permanently block CanActivateGuardian() every round.
		GuardianLog("OnClientPostAdminCheck - bot %d joined mid-guardian, moving to spectator", client);
		ChangeClientTeam(client, view_as<int>(TFTeam_Spectator));
	}
}

// ============================================================================
//  Config Parsing
// ============================================================================

void ParseAbilityConfig(KeyValues kv, GuardianAbility ability)
{
	kv.GetString("type", ability.Type, sizeof(ability.Type), "none");

	char buttonStr[32];
	kv.GetString("button", buttonStr, sizeof(buttonStr), "");

	if (StrEqual(buttonStr, "RELOAD", false)) ability.Button = IN_RELOAD;
	else if (StrEqual(buttonStr, "ATTACK3", false)) ability.Button = IN_ATTACK3;
	else if (StrEqual(buttonStr, "USE", false)) ability.Button = IN_USE;
	else if (StrEqual(buttonStr, "TAUNT", false)) ability.Button = 1000000;
	else ability.Button = 0;

	ability.Cooldown = kv.GetFloat("cooldown", 0.0);
	ability.Duration = kv.GetFloat("duration", 0.0);
	ability.Arg1 = kv.GetFloat("arg1", 0.0);
	ability.Arg2 = kv.GetFloat("arg2", 0.0);
	kv.GetString("particle", ability.Particle, sizeof(ability.Particle), "");
}

void ParseGuardianConfig()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/dodgeball/guardian.cfg");

	if (!FileExists(path, true))
	{
		LogError("[Guardian] Config not found: %s", path);
		return;
	}

	KeyValues kv = new KeyValues("TF2_Dodgeball");

	if (!kv.ImportFromFile(path))
	{
		LogError("[Guardian] Failed to parse: %s", path);
		delete kv;
		return;
	}

	// Shared settings
	if (kv.JumpToKey("guardian"))
	{
		enabled         = kv.GetNum("enabled", 1) != 0;
		selectionChance = kv.GetNum("selection chance", 25);
		optOutMinPlayers = kv.GetNum("opt out min players", 0);
		hudX            = kv.GetFloat("hud x", -1.0);
		hudY            = kv.GetFloat("hud y", 0.92);

		char colorStr[32];
		kv.GetString("hud color", colorStr, sizeof(colorStr), "255 50 50");

		char parts[3][8];
		ExplodeString(colorStr, " ", parts, sizeof(parts), sizeof(parts[]));
		hudColor[0] = StringToInt(parts[0]);
		hudColor[1] = StringToInt(parts[1]);
		hudColor[2] = StringToInt(parts[2]);

		kv.GoBack();
	}

	if (selectionChance < 0) selectionChance = 0;
	if (selectionChance > 100) selectionChance = 100;

	// Guardian classes
	if (kv.JumpToKey("guardian_classes"))
	{
		if (kv.GotoFirstSubKey())
		{
			do
			{
				if (guardianClassCount >= MAX_GUARDIAN_CLASSES)
				{
					LogError("[Guardian] Max classes reached (%d)", MAX_GUARDIAN_CLASSES);
					break;
				}

				int idx = guardianClassCount;

				kv.GetSectionName(guardianClasses[idx].Name, sizeof(guardianClasses[].Name));
				kv.GetString("name", guardianClasses[idx].DisplayName, sizeof(guardianClasses[].DisplayName), guardianClasses[idx].Name);

				guardianClasses[idx].Health = kv.GetNum("health", 5000);
				guardianClasses[idx].Weight = kv.GetNum("weight", 100);

				if (kv.JumpToKey("ability_1"))
				{
					ParseAbilityConfig(kv, guardianClasses[idx].PrimaryAbility);
					kv.GoBack();
				}

				if (kv.JumpToKey("ability_2"))
				{
					ParseAbilityConfig(kv, guardianClasses[idx].SecondaryAbility);
					kv.GoBack();
				}

				guardianClassCount++;
			}
			while (kv.GotoNextKey());

			kv.GoBack();
		}

		kv.GoBack();
	}

	delete kv;

	LogMessage("[Guardian] Loaded %d class(es). Enabled: %s, Chance: %d%%",
		guardianClassCount, enabled ? "yes" : "no", selectionChance);
}

// ============================================================================
//  Safety Checks
// ============================================================================

bool HasActiveBots()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) > 1)
			return true;
	}
	return false;
}

bool IsFFAActive()
{
	// FFA mode enables friendly fire - check if the FFA plugin's cvar exists
	// and if friendly fire is currently on
	ConVar ffaCvar = FindConVar("tf_dodgeball_ffa_bot");

	if (ffaCvar == null) return false; // FFA plugin not loaded

	// FFA plugin is loaded - check if friendly fire is enabled (FFA active)
	if (cvarFriendlyFire != null && cvarFriendlyFire.BoolValue)
	{
		return true;
	}

	return false;
}

bool CanActivateGuardian()
{
	if (!enabled || guardianClassCount == 0)
	{
		GuardianLog("CanActivateGuardian - false: enabled=%d classCount=%d", enabled, guardianClassCount);
		return false;
	}

	if (!TFDB_IsDodgeballEnabled())
	{
		GuardianLog("CanActivateGuardian - false: dodgeball not enabled");
		return false;
	}

	if (HasActiveBots() && !debugMode)
	{
		GuardianLog("CanActivateGuardian - false: active bots on server");
		if (!botMessageShown)
		{
			CPrintToChatAll("%t", "Guardian_BlockedBot");
			botMessageShown = true;
		}
		return false;
	}

	// Bots are gone - reset so the message shows again if bots rejoin
	botMessageShown = false;

	if (IsFFAActive())
	{
		GuardianLog("CanActivateGuardian - false: FFA active");
		CPrintToChatAll("%t", "Guardian_BlockedFFA");
		return false;
	}

	// Need at least 2 eligible players: 1 for guardian + 1 for RED
	int eligible = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) <= 1) continue;
		if (IsFakeClient(i) && !debugMode) continue;
		eligible++;
	}
	if (eligible < 2)
	{
		GuardianLog("CanActivateGuardian - false: not enough players (%d eligible, need 2)", eligible);
		return false;
	}

	return true;
}

// ============================================================================
//  Admin Commands
// ============================================================================

public Action Command_ForceGuardian(int client, int args)
{
	if (!enabled || guardianClassCount == 0)
	{
		CReplyToCommand(client, "%t", "Guardian_Disabled");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		CReplyToCommand(client, "[TFDB] Usage: sm_forceguardian <player> [class]");
		return Plugin_Handled;
	}

	if (HasActiveBots())
	{
		CReplyToCommand(client, "%t", "Guardian_BlockedBot");
		return Plugin_Handled;
	}

	if (IsFFAActive())
	{
		CReplyToCommand(client, "%t", "Guardian_BlockedFFA");
		return Plugin_Handled;
	}

	char targetStr[64];
	GetCmdArg(1, targetStr, sizeof(targetStr));

	int target = FindTarget(client, targetStr, true, false);

	if (target == -1) return Plugin_Handled;

	forcedClient = target;
	forcedClass  = -1;

	if (args >= 2)
	{
		char classStr[32];
		GetCmdArg(2, classStr, sizeof(classStr));

		int classIndex = FindGuardianClassByName(classStr);

		if (classIndex == -1)
		{
			CReplyToCommand(client, "[TFDB] Unknown guardian class: %s", classStr);
			return Plugin_Handled;
		}

		forcedClass = classIndex;
	}

	CPrintToChat(client, "%t", "Guardian_Forced", target);

	return Plugin_Handled;
}

public Action Command_GuardianClass(int client, int args)
{
	if (!enabled || guardianClassCount == 0)
	{
		CReplyToCommand(client, "%t", "Guardian_Disabled");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		CReplyToCommand(client, "[TFDB] Usage: sm_guardianclass <class>");
		CReplyToCommand(client, "[TFDB] Available:");

		for (int i = 0; i < guardianClassCount; i++)
		{
			CReplyToCommand(client, "  %s - %s (HP: %d)",
				guardianClasses[i].Name,
				guardianClasses[i].DisplayName,
				guardianClasses[i].Health);
		}

		return Plugin_Handled;
	}

	char classStr[32];
	GetCmdArg(1, classStr, sizeof(classStr));

	int classIndex = FindGuardianClassByName(classStr);

	if (classIndex == -1)
	{
		CReplyToCommand(client, "[TFDB] Unknown guardian class: %s", classStr);
		return Plugin_Handled;
	}

	forcedClass = classIndex;

	CPrintToChat(client, "%t", "Guardian_ClassForced", guardianClasses[classIndex].DisplayName);

	return Plugin_Handled;
}

public Action Command_RemoveGuardian(int client, int args)
{
	if (!guardianActive)
	{
		CReplyToCommand(client, "[TFDB] No Guardian active.");
		return Plugin_Handled;
	}

	CPrintToChatAll("%t", "Guardian_Removed", guardianClient);
	CleanupGuardian(true);

	return Plugin_Handled;
}

public Action Command_GuardianOptOut(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[TFDB] This command is player-only.");
		return Plugin_Handled;
	}

	guardianOptOut[client] = !guardianOptOut[client];

	if (guardianOptOut[client])
	{
		if (optOutMinPlayers > 0)
			CPrintToChat(client, "{olive}[TFDB]{default} You have {red}opted out{default} of being Guardian. (Ignored if fewer than %d players)", optOutMinPlayers);
		else
			CPrintToChat(client, "{olive}[TFDB]{default} You have {red}opted out{default} of being Guardian.");
	}
	else
	{
		CPrintToChat(client, "{olive}[TFDB]{default} You have {green}opted in{default} to being Guardian.");
	}

	return Plugin_Handled;
}

// ============================================================================
//  Events
// ============================================================================

public void OnRoundWin(Event event, const char[] name, bool dontBroadcast)
{
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "OnRoundWin - guardianActive=%d nextRoundIsGuardian=%d", guardianActive, nextRoundIsGuardian);
		GuardianDebugLog("[GUARDIAN DBG] " ... "OnRoundWin - guardianActive=%d nextRoundIsGuardian=%d", guardianActive, nextRoundIsGuardian);
	}
	GuardianLog("=== OnRoundWin - guardianActive=%d ===", guardianActive);

	// Clean up the guardian IMMEDIATELY on round end.
	// This moves them back to RED, removes glow/hooks/health bar,
	// and sets guardianActive = false so the jointeam block stops
	// trapping them during the bonus round (humiliation phase).
	// Without this, the guardian stays on BLU with skull HP and
	// "cannot use jointeam" until round_start fires.
	if (guardianActive)
	{
		CleanupGuardian(true);
	}

	if (!CanActivateGuardian())
	{
		GuardianLog("OnRoundWin - CanActivateGuardian()=false, nextRoundIsGuardian reset to false");
		nextRoundIsGuardian = false;
		return;
	}

	// Determine activation for NEXT round
	if (forcedClient != -1 || forcedClass != -1)
	{
		GuardianLog("OnRoundWin - forced next round (forcedClient=%d forcedClass=%d)", forcedClient, forcedClass);
		nextRoundIsGuardian = true;
	}
	else if (GetRandomInt(1, 100) <= selectionChance)
	{
		GuardianLog("OnRoundWin - dice roll HIT (chance=%d%%) - nextRoundIsGuardian=true", selectionChance);
		nextRoundIsGuardian = true;
		CPrintToChatAll("%t", "Guardian_NextRoundWarning");
	}
	else
	{
		GuardianLog("OnRoundWin - dice roll MISS (chance=%d%%) - nextRoundIsGuardian=false", selectionChance);
		nextRoundIsGuardian = false;
	}
}

/**
 * arena_round_start fires when players can actually move - this is when
 * TFDB sets RoundStarted=true and guardian abilities become available.
 * We log it so the select log shows the full sequence:
 *   teamplay_round_start (guardian activates, TFDB RoundStarted=false)
 *   arena_round_start    (TFDB RoundStarted=true, abilities now unlocked)
 */
public void OnArenaRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	GuardianLog("=== arena_round_start - TFDB now sets RoundStarted=true, guardian abilities unlock === guardianActive=%d", guardianActive);
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "OnArenaRoundStart - guardianActive=%d TFDB_GetRoundStarted()=%d", guardianActive, TFDB_GetRoundStarted());
		GuardianDebugLog("[GUARDIAN DBG] " ... "OnArenaRoundStart - guardianActive=%d TFDB_GetRoundStarted()=%d", guardianActive, TFDB_GetRoundStarted());
	}
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "OnRoundStart - nextRoundIsGuardian=%d forcedClient=%d forcedClass=%d", nextRoundIsGuardian, forcedClient, forcedClass);
		GuardianDebugLog("[GUARDIAN DBG] " ... "OnRoundStart - nextRoundIsGuardian=%d forcedClient=%d forcedClass=%d", nextRoundIsGuardian, forcedClient, forcedClass);
	}
	GuardianLog("=== OnRoundStart - nextRoundIsGuardian=%d forcedClient=%d forcedClass=%d ===",
		nextRoundIsGuardian, forcedClient, forcedClass);

	// Aggressive hard reset every round start
	ResetAllState(true);

	if (!CanActivateGuardian())
	{
		GuardianLog("OnRoundStart - CanActivateGuardian()=false, aborting");
		nextRoundIsGuardian = false;
		return;
	}

	// Determine activation from earlier state/commands
	bool activate = nextRoundIsGuardian;
	
	int target = -1;
	int classIndex = -1;

	// Reset next round tracker now that round is starting
	nextRoundIsGuardian = false; 

	if (forcedClient != -1)
	{
		if (IsClientInGame(forcedClient) && !IsFakeClient(forcedClient))
		{
			GuardianLog("OnRoundStart - using forcedClient=%d", forcedClient);
			target   = forcedClient;
			activate = true;
		}
		else
		{
			GuardianLog("OnRoundStart - forcedClient=%d no longer valid, ignoring", forcedClient);
		}

		forcedClient = -1;
	}

	if (!activate)
	{
		GuardianLog("OnRoundStart - activate=false, no guardian this round");
		return;
	}

	// Pick class
	if (forcedClass != -1)
	{
		classIndex  = forcedClass;
		forcedClass = -1;
		GuardianLog("OnRoundStart - using forcedClass=%d", classIndex);
	}
	else
	{
		classIndex = SelectWeightedClass();
		GuardianLog("OnRoundStart - SelectWeightedClass()=%d", classIndex);
	}

	if (classIndex == -1)
	{
		GuardianLog("OnRoundStart - classIndex=-1, aborting (no classes configured?)");
		return;
	}

	// Pick player
	if (target == -1)
	{
		target = SelectRandomPlayer();
		GuardianLog("OnRoundStart - SelectRandomPlayer()=%d", target);
	}

	if (target == -1)
	{
		GuardianLog("OnRoundStart - target=-1, aborting (no eligible players?)");
		return;
	}

	GuardianLog("OnRoundStart - activating guardian: client=%d class=%d", target, classIndex);

	// Surgical Arena Limits: Disable during Guardian round
	if (cvUnbalanceLimit != null) cvUnbalanceLimit.SetInt(0);
	if (cvAutoteambalance != null) cvAutoteambalance.SetInt(0);

	ActivateGuardian(target, classIndex);
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!guardianActive) return;
	if (guardianActivating) return; // death fired by TF2_RespawnPlayer during activation, ignore

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return;

	if (client == guardianClient)
	{
		if (debugMode)
		{
			PrintToChatAll("[GUARDIAN DBG] " ... "OnPlayerDeath - guardian %N died, calling CleanupGuardian(false)", client);
			GuardianDebugLog("[GUARDIAN DBG] " ... "OnPlayerDeath - guardian %N died, calling CleanupGuardian(false)", client);
		}
		CPrintToChatAll("%t", "Guardian_Died", client);
		CleanupGuardian(false);
	}
}

public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (!guardianActive) return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return;

	if (client == guardianClient)
	{
		if (debugMode)
		{
			PrintToChatAll("[GUARDIAN DBG] " ... "OnPlayerSpawn - guardian %N spawned, scheduling Frame_ApplyGuardianHealth", client);
			GuardianDebugLog("[GUARDIAN DBG] " ... "OnPlayerSpawn - guardian %N spawned, scheduling Frame_ApplyGuardianHealth", client);
		}
		// Defer health application one frame. TF2 resets the player's health to class
		// default as part of spawn processing. Applying our custom health inside the
		// player_spawn event fires before that reset, so the engine overwrites us.
		// Deferring to RequestFrame guarantees we run after the engine is done.
		RequestFrame(Frame_ApplyGuardianHealth, GetClientUserId(client));
		return;
	}

	// Non-guardian on BLU - force to RED (or spectator if bot)
	if (IsClientInGame(client))
	{
		if (GetClientTeam(client) == view_as<int>(TFTeam_Blue))
		{
			if (IsFakeClient(client))
			{
				// Bot spawned on BLU during a guardian round.
				// Bots can't receive the chat message and TF2_RespawnPlayer on a bot
				// can be unreliable - just move it to spectator to keep it out of the way.
				GuardianLog("OnPlayerSpawn - bot %d spawned on BLU during guardian round, moving to spectator", client);
				ChangeClientTeam(client, view_as<int>(TFTeam_Spectator));
			}
			else
			{
				if (debugMode)
				{
					PrintToChatAll("[GUARDIAN DBG] " ... "OnPlayerSpawn - non-guardian %N on BLU, forcing to RED", client);
					GuardianDebugLog("[GUARDIAN DBG] " ... "OnPlayerSpawn - non-guardian %N on BLU, forcing to RED", client);
				}
				// Refined team switch to avoid "Skull" HUD glitch
				ChangeClientTeam(client, view_as<int>(TFTeam_Red));
				TF2_RespawnPlayer(client);
				CPrintToChat(client, "%t", "Guardian_TeamBlocked");
			}
		}
	}
}

void Frame_ApplyGuardianHealth(int userId)
{
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client)) return;
	if (!guardianActive || client != guardianClient) return;

	// Read what the engine set HP to before we override it
	int engineHP  = GetClientHealth(client);
	int engineMax = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "Frame_ApplyGuardianHealth - BEFORE apply: engineHP=%d engineMax=%d", engineHP, engineMax);
		GuardianDebugLog("[GUARDIAN DBG] " ... "Frame_ApplyGuardianHealth - BEFORE apply: engineHP=%d engineMax=%d", engineHP, engineMax);
	}

	ApplyGuardianHealth();
}

public Action OnPlayerTeamChange(Event event, const char[] name, bool dontBroadcast)
{
	if (!guardianActive) return Plugin_Continue;

	int client  = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return Plugin_Continue;

	int newTeam = event.GetInt("team");
	int oldTeam = event.GetInt("oldteam");

	GuardianLog("OnPlayerTeamChange - %N (client=%d) oldTeam=%d newTeam=%d guardianClient=%d",
		client, client, oldTeam, newTeam, guardianClient);

	if (client != guardianClient && newTeam == view_as<int>(TFTeam_Blue))
	{
		GuardianLog("OnPlayerTeamChange - non-guardian joined BLU, scheduling Timer_ForceRed");
		CreateTimer(0.1, Timer_ForceRed, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}

	// Guardian moved to spectator mid-round - clean up immediately
	if (client == guardianClient && newTeam <= view_as<int>(TFTeam_Spectator))
	{
		GuardianLog("OnPlayerTeamChange - guardian %N moved to spectator, triggering cleanup", client);
		CleanupGuardian(false);
	}

	return Plugin_Continue;
}

public Action Timer_ForceRed(Handle timer, any userId)
{
	if (!guardianActive)
	{
		GuardianLog("Timer_ForceRed - guardianActive=false, skipping");
		return Plugin_Stop;
	}

	int client = GetClientOfUserId(userId);

	if (client > 0 && IsClientInGame(client) && client != guardianClient && !IsFakeClient(client))
	{
		int team = GetClientTeam(client);
		if (team == view_as<int>(TFTeam_Blue))
		{
			GuardianLog("Timer_ForceRed - forcing %N (client=%d) from BLU to RED", client, client);
			ChangeClientTeam(client, view_as<int>(TFTeam_Red));
			TF2_RespawnPlayer(client);
			CPrintToChat(client, "%t", "Guardian_TeamBlocked");
		}
		else
		{
			GuardianLog("Timer_ForceRed - %N (client=%d) already on team=%d, no action needed", client, client, team);
		}
	}
	else
	{
		GuardianLog("Timer_ForceRed - client from userId no longer valid or is guardian, skipping");
	}

	return Plugin_Stop;
}

// ============================================================================
//  Activation / Cleanup
// ============================================================================

void ActivateGuardian(int client, int classIndex)
{
	guardianActive     = true;
	guardianClient     = client;
	activeClassIndex   = classIndex;
	guardianMaxHP      = guardianClasses[classIndex].Health;
	guardianCurrentHP  = guardianMaxHP;
	lastGuardianUserId = GetClientUserId(client);

	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "ActivateGuardian - client=%d class=%s maxHP=%d", client, guardianClasses[classIndex].DisplayName, guardianMaxHP);
		GuardianDebugLog("[GUARDIAN DBG] " ... "ActivateGuardian - client=%d class=%s maxHP=%d", client, guardianClasses[classIndex].DisplayName, guardianMaxHP);
	}

	// Reset abilities
	primaryActive        = false;
	primaryExpireTime    = 0.0;
	primaryNextUseTime   = 0.0;
	primaryParticleRef   = INVALID_ENT_REFERENCE;
	primaryTimer         = null;

	secondaryActive      = false;
	secondaryExpireTime  = 0.0;
	secondaryNextUseTime = 0.0;
	secondaryParticleRef = INVALID_ENT_REFERENCE;
	secondaryTimer       = null;

	// Hook GetMaxHealth before respawning so the hook is in place when player_spawn fires.
	SDKHook(client, SDKHook_GetMaxHealth, OnGetGuardianMaxHealth);
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "ActivateGuardian - SDKHook_GetMaxHealth registered for client=%d", client);
		GuardianDebugLog("[GUARDIAN DBG] " ... "ActivateGuardian - SDKHook_GetMaxHealth registered for client=%d", client);
	}

	// Set flag before any team/respawn operations so player_death fired by the
	// engine during ChangeClientTeam or TF2_RespawnPlayer doesn't trigger cleanup.
	guardianActivating = true;

	// Move to BLU. If already on BLU, still respawn so player_spawn fires and
	// Frame_ApplyGuardianHealth applies the custom health cleanly.
	if (GetClientTeam(client) != view_as<int>(TFTeam_Blue))
	{
		GuardianLog("ActivateGuardian - moving guardian %N (client=%d) from team=%d to BLU",
			client, client, GetClientTeam(client));
		if (debugMode)
		{
			PrintToChatAll("[GUARDIAN DBG] " ... "ActivateGuardian - changing team to BLU for client=%d", client);
			GuardianDebugLog("[GUARDIAN DBG] " ... "ActivateGuardian - changing team to BLU for client=%d", client);
		}
		ChangeClientTeam(client, view_as<int>(TFTeam_Blue));
	}
	else
	{
		GuardianLog("ActivateGuardian - guardian %N (client=%d) already on BLU", client, client);
	}
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "ActivateGuardian - calling TF2_RespawnPlayer for client=%d", client);
		GuardianDebugLog("[GUARDIAN DBG] " ... "ActivateGuardian - calling TF2_RespawnPlayer for client=%d", client);
	}
	TF2_RespawnPlayer(client);
	guardianActivating = false;
	// Health is applied via OnPlayerSpawn -> RequestFrame -> Frame_ApplyGuardianHealth.
	// Do not call ApplyGuardianHealth() directly here - the engine hasn't finished
	// its own spawn-health reset yet and would overwrite our values.

	// Glow
	SetEntProp(client, Prop_Send, "m_bGlowEnabled", 1);

	// Announce
	EmitSoundToAll(SOUND_SELECTED);
	CPrintToChatAll("%t", "Guardian_Selected", client, guardianClasses[classIndex].DisplayName);
	PrintCenterText(client, "You have been chosen as the Guardian!\nPrepare yourself!");
	PrintHintText(client, "You are the Guardian!\nUse your abilities to survive!");

	// Move everyone else to RED
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i)) continue;
		if (IsFakeClient(i) && !debugMode) continue;

		if (GetClientTeam(i) == view_as<int>(TFTeam_Blue))
		{
			GuardianLog("ActivateGuardian - moving non-guardian %N (client=%d) from BLU to RED", i, i);
			ChangeClientTeam(i, view_as<int>(TFTeam_Red));
			TF2_RespawnPlayer(i);
		}
	}

	StartUpdateTimer();
	UpdateBossHealthBar();
}

void CleanupGuardian(bool respawn)
{
	if (!guardianActive) 
	{
		// Even if not active, always ensure CVars are restored
		if (cvUnbalanceLimit != null) cvUnbalanceLimit.SetInt(1);
		if (cvAutoteambalance != null) cvAutoteambalance.SetInt(1);
		return;
	}

	int client = guardianClient;

	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "CleanupGuardian - client=%d respawn=%d liveHP=%d", client, respawn, (IsClientInGame(client) ? GetClientHealth(client) : -1));
		GuardianDebugLog("[GUARDIAN DBG] " ... "CleanupGuardian - client=%d respawn=%d liveHP=%d", client, respawn, (IsClientInGame(client) ? GetClientHealth(client) : -1));
	}

	DeactivatePrimary();
	DeactivateSecondary();
	
	delete primarySlowPulseTimer;
	primarySlowPulseTimer = null;
	delete secondarySlowPulseTimer;
	secondarySlowPulseTimer = null;

	HideBossHealthBar();

	guardianActive     = false;
	guardianClient     = 0;
	guardianCurrentHP  = 0;
	guardianMaxHP      = 0;
	guardianActivating = false;

	// Restore normal rules
	if (cvUnbalanceLimit != null) cvUnbalanceLimit.SetInt(1);
	if (cvAutoteambalance != null) cvAutoteambalance.SetInt(1);

	if (client > 0 && IsClientInGame(client))
	{
		SetEntProp(client, Prop_Send, "m_bGlowEnabled", 0);
		SDKUnhook(client, SDKHook_GetMaxHealth, OnGetGuardianMaxHealth);
		TF2Attrib_RemoveByName(client, "max health additive bonus");
		if (debugMode)
		{
			PrintToChatAll("[GUARDIAN DBG] " ... "CleanupGuardian - unhooked GetMaxHealth + removed attribute for client=%d", client);
			GuardianDebugLog("[GUARDIAN DBG] " ... "CleanupGuardian - unhooked GetMaxHealth + removed attribute for client=%d", client);
		}

		if (respawn)
		{
			// Round end path (OnRoundWin): guardian stays on BLU for the win screen.
			// ResetAllState in the next OnRoundStart moves them to RED cleanly before
			// the next guardian is picked. No forced suicide or team change needed here.
			GuardianLog("CleanupGuardian - round-end: %N (client=%d) stays on BLU for win screen",
				client, client);
			if (debugMode)
			{
				PrintToChatAll("[GUARDIAN DBG] " ... "CleanupGuardian - round-end: staying on BLU until next OnRoundStart");
				GuardianDebugLog("[GUARDIAN DBG] " ... "CleanupGuardian - round-end: staying on BLU until next OnRoundStart");
			}
		}
		else
		{
			// Death path (OnPlayerDeath): the guardian just died. We can't call
			// ChangeClientTeam inside player_death - it can re-trigger the
			// engine's team-wipe check or fire another death event. Defer the
			// team change to the next frame so the death event resolves first.
			GuardianLog("CleanupGuardian - death path: deferring team move for %N (client=%d) via RequestFrame",
				client, client);
			if (debugMode)
			{
				PrintToChatAll("[GUARDIAN DBG] " ... "CleanupGuardian - death path: deferring ChangeTeam RED via RequestFrame");
				GuardianDebugLog("[GUARDIAN DBG] " ... "CleanupGuardian - death path: deferring ChangeTeam RED via RequestFrame");
			}
			RequestFrame(Frame_MoveToRed, GetClientUserId(client));
		}
	}

	StopUpdateTimer();
}

/**
 * RequestFrame callback - moves the dead guardian back to RED after
 * the player_death event has fully resolved. Calling ChangeClientTeam
 * directly inside player_death can re-trigger engine team-wipe checks.
 */
void Frame_MoveToRed(int userId)
{
	int client = GetClientOfUserId(userId);
	if (client > 0 && IsClientInGame(client))
	{
		GuardianLog("Frame_MoveToRed - moving %N (client=%d) from team=%d to RED", client, client, GetClientTeam(client));
		ChangeClientTeam(client, view_as<int>(TFTeam_Red));
	}
	else
	{
		GuardianLog("Frame_MoveToRed - client from userId no longer valid");
	}
}

void ResetAllState(bool preserveQueuedSelection = false)
{
	if (guardianActive && !guardianActivating)
	{
		// Move the previous guardian back to RED before cleaning up.
		// This is the clean path - no forced respawn, just a team reassignment
		// so the engine's natural round-start scramble can take over.
		int prevClient = guardianClient;
		CleanupGuardian(true);
		if (prevClient > 0 && IsClientInGame(prevClient))
		{
			ChangeClientTeam(prevClient, view_as<int>(TFTeam_Red));
		}
	}

	if (!preserveQueuedSelection)
	{
		forcedClient = -1;
		forcedClass  = -1;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		previousButtons[i] = 0;
	}
}

// ============================================================================
//  Debug
// ============================================================================






public Action Command_DebugGuardian(int client, int args)
{
	debugMode    = !debugMode;

	char who[MAX_NAME_LENGTH];
	if (client == 0)
		strcopy(who, sizeof(who), "SERVER");
	else
		GetClientName(client, who, sizeof(who));

	char state[8];
	strcopy(state, sizeof(state), debugMode ? "ON" : "OFF");

	PrintToChatAll("[GUARDIAN] Debug mode %s (toggled by %s)", state, who);

	if (debugMode)
	{
		// Spawn RED bots as test fodder so rounds can start solo
		ServerCommand("tf_bot_join_after_player 0");
		ServerCommand("tf_bot_keep_class_after_death 1");
		ServerCommand("tf_bot_taunt_victim_chance 0");
		ServerCommand("tf_bot_add 1 red");
		ServerCommand("tf_bot_add 1 red");
		ServerCommand("tf_bot_add 1 red");

		GuardianDebugLog("");
		GuardianDebugLog("======================================================");
		GuardianDebugLog("  Guardian debug ON  (toggled by %s)", who);
		GuardianDebugLog("======================================================");
		GuardianLog("debugMode=true (toggled by %s)", who);
		GuardianDebugLog("guardianActive=%d  client=%d  maxHP=%d  currentHP=%d  nextRound=%d",
			guardianActive, guardianClient, guardianMaxHP, guardianCurrentHP, nextRoundIsGuardian);

		if (guardianActive && IsClientInGame(guardianClient))
		{
			int liveHP  = GetClientHealth(guardianClient);
			int liveMax = GetEntProp(guardianClient, Prop_Data, "m_iMaxHealth");
			GuardianDebugLog("Live HP=%d  m_iMaxHealth=%d  guardianMaxHP=%d",
				liveHP, liveMax, guardianMaxHP);

			PrintToChatAll("[GUARDIAN DBG] Live HP=%d  m_iMaxHealth=%d  guardianMaxHP=%d",
				liveHP, liveMax, guardianMaxHP);
		}
	}
	else
	{
		ServerCommand("tf_bot_kick all");

		// Only write to debug log if it already exists (avoids creating the file just to say "OFF")
		if (FileExists(GUARDIAN_LOG))
		{
			GuardianDebugLog("------------------------------------------------------");
			GuardianDebugLog("  Guardian debug OFF  (toggled by %s)", who);
			GuardianDebugLog("------------------------------------------------------");
			GuardianDebugLog("");
		}
		GuardianLog("debugMode=false (toggled by %s)", who);
	}

	return Plugin_Handled;
}

// ============================================================================
//  Health System
// ============================================================================

void ApplyGuardianHealth()
{
	if (!guardianActive || !IsClientInGame(guardianClient) || !IsPlayerAlive(guardianClient)) return;

	int client = guardianClient;
	int baseHP = guardianMaxHP;

	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "ApplyGuardianHealth - client=%d maxHP=%d currentHP=%d", client, baseHP, guardianCurrentHP);
		GuardianDebugLog("[GUARDIAN DBG] " ... "ApplyGuardianHealth - client=%d maxHP=%d currentHP=%d", client, baseHP, guardianCurrentHP);
	}

	// TF2 recomputes max health from class base + attributes every frame.
	// m_iMaxHealth via Prop_Data does not stick. The correct approach (same as VSH/FF2)
	// is to use the "max health additive bonus" player attribute. Remove then re-add it
	// so stale values from a previous spawn never accumulate.
	TF2Attrib_RemoveByName(client, "max health additive bonus");

	// The attribute value is additive on top of the Pyro base (175 HP).
	// We want the final max to equal guardianMaxHP, so: bonus = guardianMaxHP - 175.
	int bonus = baseHP - 175;
	if (bonus > 0)
		TF2Attrib_SetByName(client, "max health additive bonus", float(bonus));

	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "ApplyGuardianHealth - attribute bonus set to %d (base 175 + %d = %d)", bonus, bonus, 175 + bonus);
		GuardianDebugLog("[GUARDIAN DBG] " ... "ApplyGuardianHealth - attribute bonus set to %d (base 175 + %d = %d)", bonus, bonus, 175 + bonus);
	}

	SetEntityHealth(client, guardianCurrentHP);

	// Verify what the engine actually sees after the call
	int liveHP  = GetClientHealth(client);
	int liveMax = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (debugMode)
	{
		PrintToChatAll("[GUARDIAN DBG] " ... "ApplyGuardianHealth - POST: liveHP=%d liveMax(DataProp)=%d wanted=%d", liveHP, liveMax, guardianCurrentHP);
		GuardianDebugLog("[GUARDIAN DBG] " ... "ApplyGuardianHealth - POST: liveHP=%d liveMax(DataProp)=%d wanted=%d", liveHP, liveMax, guardianCurrentHP);
	}
}

/**
 * SDKHook_GetMaxHealth callback - tells the engine the Guardian's true max health.
 * The attribute handles the engine's own drain logic; this hook covers any edge cases
 * where the engine queries max health before the attribute has been evaluated.
 */
public Action OnGetGuardianMaxHealth(int client, int &maxhealth)
{
	if (!guardianActive || client != guardianClient) return Plugin_Continue;

	maxhealth = guardianMaxHP;
	return Plugin_Changed;
}

// ============================================================================
//  Ability Input Detection
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!guardianActive || client != guardianClient || !IsPlayerAlive(client) || !TFDB_GetRoundStarted())
	{
		return Plugin_Continue;
	}

	int currentButtons = buttons;
	int oldButtons = previousButtons[client];
	float now = GetGameTime();
	
	int btn1 = guardianClasses[activeClassIndex].PrimaryAbility.Button;
	int btn2 = guardianClasses[activeClassIndex].SecondaryAbility.Button;

	if (btn1 > 0 && btn1 != 1000000)
	{
		if ((currentButtons & btn1) && !(oldButtons & btn1))
		{
			if (!primaryActive && now >= primaryNextUseTime) ActivateAbility(guardianClasses[activeClassIndex].PrimaryAbility, 1);
		}
	}

	if (btn2 > 0 && btn2 != 1000000)
	{
		if ((currentButtons & btn2) && !(oldButtons & btn2))
		{
			if (!secondaryActive && now >= secondaryNextUseTime) ActivateAbility(guardianClasses[activeClassIndex].SecondaryAbility, 2);
		}
	}

	previousButtons[client] = buttons;
	return Plugin_Continue;
}

// G key - Taunt (detected via condition)
public void TF2_OnConditionAdded(int client, TFCond condition)
{
	if (!guardianActive || !IsPlayerAlive(client) || !TFDB_GetRoundStarted()) return;

	if (condition == TFCond_Taunting && client == guardianClient)
	{
		TF2_RemoveCondition(client, TFCond_Taunting);

		float now = GetGameTime();
		int btn1 = guardianClasses[activeClassIndex].PrimaryAbility.Button;
		int btn2 = guardianClasses[activeClassIndex].SecondaryAbility.Button;

		if (btn1 == 1000000 && !primaryActive && now >= primaryNextUseTime) ActivateAbility(guardianClasses[activeClassIndex].PrimaryAbility, 1);
		else if (btn2 == 1000000 && !secondaryActive && now >= secondaryNextUseTime) ActivateAbility(guardianClasses[activeClassIndex].SecondaryAbility, 2);
	}
}

// ============================================================================
//  Modular Ability Execution
// ============================================================================

void ActivateAbility(GuardianAbility ability, int slotIdx)
{
	if (!guardianActive || !IsClientInGame(guardianClient)) return;

	float now = GetGameTime();
	
	if (slotIdx == 1)
	{
		primaryActive = true;
		primaryExpireTime = now + ability.Duration;
		primaryParticleRef = AttachParticle(guardianClient, ability.Particle);
	}
	else
	{
		secondaryActive = true;
		secondaryExpireTime = now + ability.Duration;
		secondaryParticleRef = AttachParticle(guardianClient, ability.Particle);
	}

	EmitSoundToAll(SOUND_ACTIVATE);

	if (StrEqual(ability.Type, "rage", false)) CPrintToChatAll("%t", "Guardian_RageActivated", guardianClient);
	else if (StrEqual(ability.Type, "sprint", false)) CPrintToChatAll("%t", "Guardian_SprintActivated", guardianClient);
	else if (StrEqual(ability.Type, "pounce", false)) CPrintToChatAll("%t", "Guardian_PounceActivated", guardianClient);
	else if (StrEqual(ability.Type, "charge", false)) CPrintToChatAll("%t", "Guardian_ChargeActivated", guardianClient);
	else if (StrEqual(ability.Type, "scare", false) || StrEqual(ability.Type, "slow", false)) CPrintToChatAll("%t", "Guardian_SlowActivated", guardianClient);

	if (StrEqual(ability.Type, "rage", false))
	{
		int weapon = GetPlayerWeaponSlot(guardianClient, 0);
		if (weapon != -1 && IsValidEntity(weapon))
		{
			TF2Attrib_SetByName(weapon, "mult airblast refire time", ability.Arg1 > 0.0 ? ability.Arg1 : 0.5);
			TF2Attrib_SetByName(weapon, "airblast pushback scale", ability.Arg2 > 0.0 ? ability.Arg2 : 1.5);
		}
	}
	else if (StrEqual(ability.Type, "sprint", false) || StrEqual(ability.Type, "charge", false))
	{
		TF2_AddCondition(guardianClient, TFCond_SpeedBuffAlly, ability.Duration);
	}
	else if (StrEqual(ability.Type, "pounce", false))
	{
		float vVel[3], vAng[3];
		GetClientEyeAngles(guardianClient, vAng);
		vAng[0] = 0.0;
		GetAngleVectors(vAng, vVel, NULL_VECTOR, NULL_VECTOR);
		
		float forceFwd = ability.Arg1 > 0.0 ? ability.Arg1 : 1000.0;
		float forceUp  = ability.Arg2 > 0.0 ? ability.Arg2 : 500.0;
		ScaleVector(vVel, forceFwd);
		vVel[2] = forceUp;
		
		TeleportEntity(guardianClient, NULL_VECTOR, NULL_VECTOR, vVel);
	}
	else if (StrEqual(ability.Type, "scare", false) || StrEqual(ability.Type, "slow", false))
	{
		// Start pulsating slow timer
		if (slotIdx == 1)
		{
			delete primarySlowPulseTimer;
			DataPack pack;
			primarySlowPulseTimer = CreateDataTimer(0.2, Timer_SlowPulse, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			if (pack != null)
			{
				pack.WriteCell(activeClassIndex);
				pack.WriteCell(1); 
			}
		}
		else
		{
			delete secondarySlowPulseTimer;
			DataPack pack;
			secondarySlowPulseTimer = CreateDataTimer(0.2, Timer_SlowPulse, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			if (pack != null)
			{
				pack.WriteCell(activeClassIndex);
				pack.WriteCell(2);
			}
		}

		// Initial application
		TriggerSlowPulse(activeClassIndex, (slotIdx == 1 ? true : false));
	}

	DataPack pack;
	if (slotIdx == 1)
	{
		delete primaryTimer; // defensive: prevent handle leak if timer already exists
		primaryTimer = CreateDataTimer(ability.Duration, Timer_PrimaryExpire, pack, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		delete secondaryTimer;
		secondaryTimer = CreateDataTimer(ability.Duration, Timer_SecondaryExpire, pack, TIMER_FLAG_NO_MAPCHANGE);
	}
	if (pack != null) pack.WriteCell(GetClientUserId(guardianClient));
}

void DeactivatePrimary()
{
	if (!primaryActive) return;

	if (primaryTimer != null)
	{
		delete primaryTimer;
		primaryTimer = null;
	}

	primaryActive = false;
	primaryNextUseTime = GetGameTime() + guardianClasses[activeClassIndex].PrimaryAbility.Cooldown;

	RestoreAbilityState(guardianClasses[activeClassIndex].PrimaryAbility);
	DestroyParticle(primaryParticleRef);
	primaryParticleRef = INVALID_ENT_REFERENCE;

	// Stop slow pulse if this was the slow ability
	char type[32];
	strcopy(type, sizeof(type), guardianClasses[activeClassIndex].PrimaryAbility.Type);
	if (StrEqual(type, "slow", false) || StrEqual(type, "scare", false))
	{
		delete primarySlowPulseTimer;
		primarySlowPulseTimer = null;
	}
}

void DeactivateSecondary()
{
	if (!secondaryActive) return;

	if (secondaryTimer != null)
	{
		delete secondaryTimer;
		secondaryTimer = null;
	}

	secondaryActive = false;
	secondaryNextUseTime = GetGameTime() + guardianClasses[activeClassIndex].SecondaryAbility.Cooldown;

	RestoreAbilityState(guardianClasses[activeClassIndex].SecondaryAbility);
	DestroyParticle(secondaryParticleRef);
	secondaryParticleRef = INVALID_ENT_REFERENCE;

	// Stop slow pulse if this was the slow ability
	char type[32];
	strcopy(type, sizeof(type), guardianClasses[activeClassIndex].SecondaryAbility.Type);
	if (StrEqual(type, "slow", false) || StrEqual(type, "scare", false))
	{
		delete secondarySlowPulseTimer;
		secondarySlowPulseTimer = null;
	}
}

void RestoreAbilityState(GuardianAbility ability)
{
	if (!IsClientInGame(guardianClient) || !IsPlayerAlive(guardianClient)) return;

	if (StrEqual(ability.Type, "rage", false))
	{
		int weapon = GetPlayerWeaponSlot(guardianClient, 0);
		if (weapon != -1 && IsValidEntity(weapon))
		{
			TF2Attrib_RemoveByName(weapon, "mult airblast refire time");
			TF2Attrib_RemoveByName(weapon, "airblast pushback scale");
		}
	}
	else if (StrEqual(ability.Type, "sprint", false) || StrEqual(ability.Type, "charge", false))
	{
		TF2_RemoveCondition(guardianClient, TFCond_SpeedBuffAlly);
	}
}

public Action Timer_PrimaryExpire(Handle timer, DataPack pack)
{
	primaryTimer = null;
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	
	DeactivatePrimary();
	if (client && guardianActive && client == guardianClient) EmitSoundToClient(client, SOUND_READY);
	return Plugin_Stop;
}

public Action Timer_SecondaryExpire(Handle timer, DataPack pack)
{
	secondaryTimer = null;
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	
	DeactivateSecondary();
	if (client && guardianActive && client == guardianClient) EmitSoundToClient(client, SOUND_READY);
	return Plugin_Stop;
}

public Action Timer_SlowPulse(Handle timer, DataPack pack)
{
	if (!guardianActive || !IsClientInGame(guardianClient) || !IsPlayerAlive(guardianClient))
	{
		// One of these handles IS the timer currently executing - only null it.
		// Plugin_Stop tells the engine to destroy it. Delete the other one safely.
		if (timer == primarySlowPulseTimer)
		{
			primarySlowPulseTimer = null;
			delete secondarySlowPulseTimer;
		}
		else
		{
			secondarySlowPulseTimer = null;
			delete primarySlowPulseTimer;
		}
		return Plugin_Stop;
	}

	pack.Reset();
	int classIdx = pack.ReadCell();
	int slot     = pack.ReadCell();

	bool isPrimary = (slot == 1);
	
	// Check if still active
	if (isPrimary && (!primaryActive || primarySlowPulseTimer == null)) { primarySlowPulseTimer = null; return Plugin_Stop; }
	if (!isPrimary && (!secondaryActive || secondarySlowPulseTimer == null)) { secondarySlowPulseTimer = null; return Plugin_Stop; }

	TriggerSlowPulse(classIdx, isPrimary);
	
	return Plugin_Continue;
}

void TriggerSlowPulse(int classIdx, bool isPrimary)
{
	float radius = isPrimary ? guardianClasses[classIdx].PrimaryAbility.Arg1 : guardianClasses[classIdx].SecondaryAbility.Arg1;
	float speed  = isPrimary ? guardianClasses[classIdx].PrimaryAbility.Arg2 : guardianClasses[classIdx].SecondaryAbility.Arg2;

	if (radius <= 0.0) radius = 500.0;
	if (speed <= 0.0)  speed = 50.0;
	
	speed /= 100.0; // Converted to percentage (0.5 for 50%)
	
	float origin[3], otherOrigin[3];
	GetClientAbsOrigin(guardianClient, origin);
	origin[2] += 10.0; // Slightly above ground for ring

	// Draw Visual Ring
	int color[4] = {100, 150, 255, 128}; // Transparent Blue
	TE_SetupBeamRingPoint(origin, 10.0, radius, beamModelIndex, haloModelIndex, 0, 15, 0.4, 3.0, 0.0, color, 10, 0); // Reduced duration to 0.4 for higher pulse rate
	TE_SendToAll();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i) && i != guardianClient && GetClientTeam(i) != GetClientTeam(guardianClient))
		{
			GetClientAbsOrigin(i, otherOrigin);
			if (GetVectorDistance(origin, otherOrigin) <= radius)
			{
				// Apply very short stun that refreshes next pulse
				TF2_StunPlayer(i, 0.3, speed, TF_STUNFLAG_SLOWDOWN, guardianClient);
			}
		}
	}
}

// ============================================================================
//  HUD + Boss Health Bar
// ============================================================================

void StartUpdateTimer()
{
	StopUpdateTimer();
	updateTimer = CreateTimer(HUD_UPDATE_INTERVAL, Timer_Update, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopUpdateTimer()
{
	delete updateTimer;
	updateTimer = null;
}

public Action Timer_Update(Handle timer)
{
	if (!guardianActive || !IsClientInGame(guardianClient))
	{
		updateTimer = null;
		return Plugin_Stop;
	}

	float now = GetGameTime();

	// Check ability expiration
	if (primaryActive && now >= primaryExpireTime) DeactivatePrimary();
	if (secondaryActive && now >= secondaryExpireTime) DeactivateSecondary();

	// Bot join check - disable Guardian if a bot appeared mid-round (skip in debugMode)
	if (HasActiveBots() && !debugMode)
	{
		GuardianLog("Timer_Update - bot detected mid-round, cleaning up guardian and moving bots to spectator");
		CPrintToChatAll("%t", "Guardian_BotJoined");
		CleanupGuardian(true);
		// Move all active-team bots to spectator so they don't block future rounds
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) > view_as<int>(TFTeam_Spectator))
			{
				GuardianLog("Timer_Update - moving bot %d from team=%d to spectator", i, GetClientTeam(i));
				ChangeClientTeam(i, view_as<int>(TFTeam_Spectator));
			}
		}
		updateTimer = null;
		return Plugin_Stop;
	}

	// FFA check - disable Guardian if FFA was enabled mid-round
	if (IsFFAActive())
	{
		CPrintToChatAll("%t", "Guardian_BlockedFFA");
		CleanupGuardian(true);
		updateTimer = null;
		return Plugin_Stop;
	}

	// --- Guardian HUD (guardian only) ---
	int idx = activeClassIndex;

	char status1[64];
	char status2[64];
	
	char name1[32], name2[32];
	strcopy(name1, sizeof(name1), guardianClasses[idx].PrimaryAbility.Type);
	strcopy(name2, sizeof(name2), guardianClasses[idx].SecondaryAbility.Type);
	
	for (int i = 0; name1[i] != '\0'; i++) name1[i] = CharToUpper(name1[i]);
	for (int i = 0; name2[i] != '\0'; i++) name2[i] = CharToUpper(name2[i]);

	if (primaryActive)
	{
		float remaining = primaryExpireTime - now;
		FormatEx(status1, sizeof(status1), "%s [ACTIVE %.1fs]", name1, remaining);
	}
	else if (now < primaryNextUseTime)
	{
		float cooldown = primaryNextUseTime - now;
		FormatEx(status1, sizeof(status1), "%s [CD %.1fs]", name1, cooldown);
	}
	else
	{
		FormatEx(status1, sizeof(status1), "%s [READY]", name1);
	}

	if (secondaryActive)
	{
		float remaining = secondaryExpireTime - now;
		FormatEx(status2, sizeof(status2), "%s [ACTIVE %.1fs]", name2, remaining);
	}
	else if (now < secondaryNextUseTime)
	{
		float cooldown = secondaryNextUseTime - now;
		FormatEx(status2, sizeof(status2), "%s [CD %.1fs]", name2, cooldown);
	}
	else
	{
		FormatEx(status2, sizeof(status2), "%s [READY]", name2);
	}

	SetHudTextParams(hudX, hudY, HUD_UPDATE_INTERVAL + 0.05, hudColor[0], hudColor[1], hudColor[2], 255, 0, 0.0, 0.0, 0.0);
	ShowSyncHudText(guardianClient, hudSync,
		"[ %s ]\n%s\n%s",
		guardianClasses[idx].DisplayName,
		status1,
		status2);

	UpdateBossHealthBar();

	return Plugin_Continue;
}

void UpdateBossHealthBar()
{
	if (monsterResource == INVALID_ENT_REFERENCE || !IsValidEntity(monsterResource)) return;

	if (!guardianActive || guardianMaxHP <= 0)
	{
		HideBossHealthBar();
		return;
	}

	if (IsClientInGame(guardianClient) && IsPlayerAlive(guardianClient))
	{
		guardianCurrentHP = GetClientHealth(guardianClient);
	}
	else
	{
		guardianCurrentHP = 0;
	}

	int byte = RoundToFloor((float(guardianCurrentHP) / float(guardianMaxHP)) * 255.0);

	if (byte < 0)   byte = 0;
	if (byte > 255)  byte = 255;

	SetEntProp(monsterResource, Prop_Send, "m_iBossHealthPercentageByte", byte);

	int bossState = 0;
	if (debugBossState >= 0 && debugBossState <= 4)
	{
		bossState = debugBossState;
	}
	else
	{
		// Safety: invalid debug values should never leak into live HUD state.
		debugBossState = -1;
	}

	// Known practical states from community usage:
	// 0 = default, 1 = healing/green, 3 = victory/blue, 4 = loss/gray.
	SetEntProp(monsterResource, Prop_Send, "m_iBossState", bossState);
}

void HideBossHealthBar()
{
	if (monsterResource != INVALID_ENT_REFERENCE && IsValidEntity(monsterResource))
	{
		SetEntProp(monsterResource, Prop_Send, "m_iBossHealthPercentageByte", 0);
		SetEntProp(monsterResource, Prop_Send, "m_iBossState", 0);
	}
}

public Action Command_BossState(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[TFDB] Usage: sm_tfdb_bossstate <-1|0-4> (-1 disables override)");
		return Plugin_Handled;
	}

	char arg[10];
	GetCmdArg(1, arg, sizeof(arg));
	int value = StringToInt(arg);
	if (value < -1 || value > 4)
	{
		ReplyToCommand(client, "[TFDB] Invalid boss state %d. Use -1 or 0-4.", value);
		return Plugin_Handled;
	}

	debugBossState = value;
	ReplyToCommand(client, "[TFDB] Boss state override set to: %d", debugBossState);
	return Plugin_Handled;
}

// ============================================================================
//  Particle Helpers
// ============================================================================

int AttachParticle(int client, const char[] particleName)
{
	if (particleName[0] == '\0') return INVALID_ENT_REFERENCE;

	int particle = CreateEntityByName("info_particle_system");

	if (!IsValidEntity(particle)) return INVALID_ENT_REFERENCE;

	float pos[3];
	GetClientAbsOrigin(client, pos);

	char tName[64];
	GetEntPropString(client, Prop_Data, "m_iName", tName, sizeof(tName));

	if (tName[0] == '\0')
	{
		Format(tName, sizeof(tName), "target%i", client);
		DispatchKeyValue(client, "targetname", tName);
	}

	DispatchKeyValue(particle, "effect_name", particleName);
	DispatchKeyValueVector(particle, "origin", pos);
	DispatchKeyValue(particle, "cpoint1", tName); // Assign Control Point 1 to the player targetname

	DispatchSpawn(particle);
	ActivateEntity(particle);
	AcceptEntityInput(particle, "Start");

	SetVariantString(tName);
	AcceptEntityInput(particle, "SetParent", client, particle, 0);

	// Attachment logic refinement:
	// If it's an unusual taunt (utaunt_), we attach to "flag" (head/back area) 
	// UNLESS it's hands, which look better at feet/origin.
	if (StrContains(particleName, "utaunt_", false) != -1)
	{
		if (StrContains(particleName, "hands", false) == -1) // Not hands? Move to flag!
		{
			SetVariantString("flag");
			AcceptEntityInput(particle, "SetParentAttachment", client, particle, 0);
		}
	}
	else
	{
		// Generic particles also go to flag
		SetVariantString("flag");
		AcceptEntityInput(particle, "SetParentAttachment", client, particle, 0); // Fixed parent argument
	}

	return EntIndexToEntRef(particle);
}

void DestroyParticle(int ref)
{
	if (ref == INVALID_ENT_REFERENCE) return;

	int entity = EntRefToEntIndex(ref);

	if (entity != -1 && IsValidEntity(entity))
	{
		AcceptEntityInput(entity, "Stop");
		AcceptEntityInput(entity, "Kill");
	}
}

// ============================================================================
//  Selection Helpers
// ============================================================================

int SelectRandomPlayer()
{
	int candidates[MAXPLAYERS + 1];
	int count = 0;
	int lastGuardian = GetClientOfUserId(lastGuardianUserId);

	// Count eligible non-opted-out players first
	int totalEligible = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) <= 1) continue;
		if (IsFakeClient(i) && !debugMode) continue;
		if (i == lastGuardian && lastGuardian != 0) continue;
		totalEligible++;
	}

	// Honour opt-outs only if enough players are present
	bool honorOptOut = (optOutMinPlayers > 0 && totalEligible >= optOutMinPlayers);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) <= 1) continue;
		if (IsFakeClient(i) && !debugMode) continue;
		if (i == lastGuardian && lastGuardian != 0) continue;
		if (honorOptOut && guardianOptOut[i]) continue;

		candidates[count++] = i;
	}

	// Fallback 1: everyone except last guardian (ignore opt-outs if not enough)
	if (count == 0)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || GetClientTeam(i) <= 1) continue;
			if (IsFakeClient(i) && !debugMode) continue;
			if (i == lastGuardian && lastGuardian != 0) continue;
			candidates[count++] = i;
		}
	}

	// Fallback 2: include last guardian too (1v1 scenario)
	if (count == 0)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || GetClientTeam(i) <= 1) continue;
			if (IsFakeClient(i) && !debugMode) continue;
			candidates[count++] = i;
		}
	}

	if (count == 0) return -1;

	return candidates[GetRandomInt(0, count - 1)];
}

int SelectWeightedClass()
{
	if (guardianClassCount == 0) return -1;
	if (guardianClassCount == 1) return 0;

	int totalWeight = 0;

	for (int i = 0; i < guardianClassCount; i++)
	{
		totalWeight += guardianClasses[i].Weight;
	}

	if (totalWeight <= 0) return 0;

	int roll    = GetRandomInt(1, totalWeight);
	int running = 0;

	for (int i = 0; i < guardianClassCount; i++)
	{
		running += guardianClasses[i].Weight;

		if (roll <= running) return i;
	}

	return 0;
}

int FindGuardianClassByName(const char[] className)
{
	for (int i = 0; i < guardianClassCount; i++)
	{
		if (StrEqual(guardianClasses[i].Name, className, false))
		{
			return i;
		}
	}

	return -1;
}
