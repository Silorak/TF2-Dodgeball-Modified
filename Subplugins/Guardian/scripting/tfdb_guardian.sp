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
#define PLUGIN_DESCRIPTION "Guardian mode for dodgeball — one powered player vs all"
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball-Modified"

#define MAX_GUARDIAN_CLASSES   16
#define HUD_UPDATE_INTERVAL    0.1

#define SOUND_SELECTED  "misc/killstreak.wav"
#define SOUND_READY     "buttons/button17.wav"
#define SOUND_ACTIVATE  "misc/halloween/spell_overheal.wav"

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
int           monsterResource = -1;
int           debugBossState  = -1;

// Edge detection for R key per-client
int           previousButtons[MAXPLAYERS + 1];

// FFA detection
ConVar        cvarFriendlyFire;

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

public void OnPluginStart()
{
	LoadTranslations("tfdb.phrases");
	debugBossState = -1;

	RegAdminCmd("sm_forceguardian",  Command_ForceGuardian,  ADMFLAG_CONFIG, "Force a player as Guardian next round. Usage: sm_forceguardian <player> [class]");
	RegAdminCmd("sm_guardianclass",  Command_GuardianClass,  ADMFLAG_CONFIG, "Set guardian class for next round. Usage: sm_guardianclass <class>");
	RegAdminCmd("sm_removeguardian", Command_RemoveGuardian, ADMFLAG_CONFIG, "Remove the current Guardian mid-round.");

	hudSync = CreateHudSynchronizer();

	HookEvent("teamplay_round_start", OnRoundStart);
	HookEvent("teamplay_round_win",   OnRoundWin);
	HookEvent("player_death",         OnPlayerDeath);
	HookEvent("player_spawn",         OnPlayerSpawn);
	HookEvent("player_team",          OnPlayerTeamChange, EventHookMode_Pre);

	RegAdminCmd("sm_tfdb_bossstate", Command_BossState, ADMFLAG_CHEATS); // Hidden debug
	

	cvarFriendlyFire = FindConVar("mp_friendlyfire");
	cvUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");
	cvAutoteambalance = FindConVar("mp_autoteambalance");

	AddCommandListener(Listener_BlockGuardianCommands, "kill");
	AddCommandListener(Listener_BlockGuardianCommands, "explode");
	AddCommandListener(Listener_BlockGuardianCommands, "jointeam");
	AddCommandListener(Listener_BlockGuardianCommands, "autoteam");
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

	CPrintToChat(client, "{red}[TFDB] You cannot use '%s' while you are the Guardian!", command);
	return Plugin_Handled;
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

	PrecacheModel("materials/sprites/laserbeam.vmt", true);
	PrecacheModel("materials/sprites/halo01.vmt", true);

	monsterResource = FindEntityByClassname(-1, "monster_resource");

	if (monsterResource == -1)
	{
		monsterResource = CreateEntityByName("monster_resource");

		if (IsValidEntity(monsterResource))
		{
			DispatchSpawn(monsterResource);
		}
	}

	if (monsterResource != -1 && IsValidEntity(monsterResource))
	{
		SetEntProp(monsterResource, Prop_Send, "m_iTeamNum", 2); // Set to RED team
	}
}

public void OnMapEnd()
{
	nextRoundIsGuardian = false;
	debugBossState = -1;
	ResetAllState();
	monsterResource = -1;
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
	// Bot joined — disable Guardian if active
	if (IsFakeClient(client) && guardianActive)
	{
		CPrintToChatAll("%t", "Guardian_BotJoined");
		CleanupGuardian(true);
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
		{
			return true;
		}
	}

	return false;
}

bool IsFFAActive()
{
	// FFA mode enables friendly fire — check if the FFA plugin's cvar exists
	// and if friendly fire is currently on
	ConVar ffaCvar = FindConVar("tf_dodgeball_ffa_bot");

	if (ffaCvar == null) return false; // FFA plugin not loaded

	// FFA plugin is loaded — check if friendly fire is enabled (FFA active)
	if (cvarFriendlyFire != null && cvarFriendlyFire.BoolValue)
	{
		return true;
	}

	return false;
}

bool CanActivateGuardian()
{
	if (!enabled || guardianClassCount == 0) return false;

	if (!TFDB_IsDodgeballEnabled()) return false;

	if (HasActiveBots())
	{
		if (!botMessageShown)
		{
			CPrintToChatAll("%t", "Guardian_BlockedBot");
			botMessageShown = true;
		}
		return false;
	}

	// Bots are gone — reset so the message shows again if bots rejoin
	botMessageShown = false;

	if (IsFFAActive())
	{
		CPrintToChatAll("%t", "Guardian_BlockedFFA");
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
			CReplyToCommand(client, "  %s — %s (HP: %d)",
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

// ============================================================================
//  Events
// ============================================================================

public void OnRoundWin(Event event, const char[] name, bool dontBroadcast)
{
	if (!CanActivateGuardian())
	{
		nextRoundIsGuardian = false;
		return;
	}

	// Determine activation for NEXT round
	if (forcedClient != -1 || forcedClass != -1)
	{
		// Force rules take precedence, already announced when command used
		nextRoundIsGuardian = true;
	}
	else if (GetRandomInt(1, 100) <= selectionChance)
	{
		nextRoundIsGuardian = true;
		CPrintToChatAll("%t", "Guardian_NextRoundWarning");
	}
	else
	{
		nextRoundIsGuardian = false;
	}

	// EMERGENCY: Always ensure limits are restored at round end
	if (cvUnbalanceLimit != null) cvUnbalanceLimit.SetInt(1);
	if (cvAutoteambalance != null) cvAutoteambalance.SetInt(1);
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// Aggressive hard reset every round start
	ResetAllState(true);

	if (!CanActivateGuardian())
	{
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
			target   = forcedClient;
			activate = true;
		}

		forcedClient = -1;
	}

	if (!activate) return;

	// Pick class
	if (forcedClass != -1)
	{
		classIndex  = forcedClass;
		forcedClass = -1;
	}
	else
	{
		classIndex = SelectWeightedClass();
	}

	if (classIndex == -1) return;

	// Pick player
	if (target == -1)
	{
		target = SelectRandomPlayer();
	}

	if (target == -1) return;

	// Surgical Arena Limits: Disable during Guardian round
	if (cvUnbalanceLimit != null) cvUnbalanceLimit.SetInt(0);
	if (cvAutoteambalance != null) cvAutoteambalance.SetInt(0);

	ActivateGuardian(target, classIndex);
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!guardianActive) return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return;

	if (client == guardianClient)
	{
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
		ApplyGuardianHealth();
		return;
	}

	// Non-guardian on BLU — force to RED
	if (IsClientInGame(client) && !IsFakeClient(client))
	{
		if (GetClientTeam(client) == view_as<int>(TFTeam_Blue))
		{
			// Refined team switch to avoid "Skull" HUD glitch
			ChangeClientTeam(client, view_as<int>(TFTeam_Red));
			TF2_RespawnPlayer(client);
			CPrintToChat(client, "%t", "Guardian_TeamBlocked");
		}
	}
}

public Action OnPlayerTeamChange(Event event, const char[] name, bool dontBroadcast)
{
	if (!guardianActive) return Plugin_Continue;

	int client  = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return Plugin_Continue;

	int newTeam = event.GetInt("team");

	if (client != guardianClient && newTeam == view_as<int>(TFTeam_Blue))
	{
		CreateTimer(0.1, Timer_ForceRed, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}

	return Plugin_Continue;
}

public Action Timer_ForceRed(Handle timer, any userId)
{
	if (!guardianActive)
	{
		return Plugin_Stop;
	}

	int client = GetClientOfUserId(userId);

	if (client > 0 && IsClientInGame(client) && client != guardianClient)
	{
		if (GetClientTeam(client) == view_as<int>(TFTeam_Blue))
		{
			ChangeClientTeam(client, view_as<int>(TFTeam_Red));
			TF2_RespawnPlayer(client);
			CPrintToChat(client, "%t", "Guardian_TeamBlocked");
		}
	}

	return Plugin_Stop;
}

// Block jointeam to BLU via console command
public Action OnClientCommand(int client, int args)
{
	if (!guardianActive || client <= 0 || client > MaxClients) return Plugin_Continue;

	char cmd[32];
	GetCmdArg(0, cmd, sizeof(cmd));

	// Redundant suicide block removed (handled by AddCommandListener)
	
	if (client != guardianClient)
	{
		if (strcmp(cmd, "jointeam", false) == 0 && args >= 1)
		{
			char arg[16];
			GetCmdArg(1, arg, sizeof(arg));

			if (strcmp(arg, "blue", false) == 0 || strcmp(arg, "3", false) == 0 || strcmp(arg, "auto", false) == 0)
			{
				CPrintToChat(client, "{olive}[TFDB]{default} The Guardian blocks BLU. Moving you to {red}RED{default} team.");
				FakeClientCommand(client, "jointeam red");
				return Plugin_Handled;
			}
		}
		else if (strcmp(cmd, "autoteam", false) == 0)
		{
			CPrintToChatAll("{olive}[TFDB]{default} The Guardian blocks BLU. Moving you to {red}RED{default} team.");
			FakeClientCommand(client, "jointeam red");
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
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

	// Move to BLU
	if (GetClientTeam(client) != view_as<int>(TFTeam_Blue))
	{
		ChangeClientTeam(client, view_as<int>(TFTeam_Blue));
		TF2_RespawnPlayer(client);
	}

	ApplyGuardianHealth();

	// Glow
	SetEntProp(client, Prop_Send, "m_bGlowEnabled", 1);

	// Hook GetMaxHealth so the engine knows our custom max HP.
	// Without this, TF2 thinks max health is 175 (Pyro base) and drains
	// anything above that as overheal. This is how VSH/boss plugins solve it.
	SDKHook(client, SDKHook_GetMaxHealth, OnGetGuardianMaxHealth);

	// Announce
	EmitSoundToAll(SOUND_SELECTED);
	CPrintToChatAll("%t", "Guardian_Selected", client, guardianClasses[classIndex].DisplayName);
	PrintCenterText(client, "You have been chosen as the Guardian!\nPrepare yourself!");
	PrintHintText(client, "You are the Guardian!\nUse your abilities to survive!");

	// Move everyone else to RED
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || IsFakeClient(i)) continue;

		if (GetClientTeam(i) == view_as<int>(TFTeam_Blue))
		{
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

	DeactivatePrimary();
	DeactivateSecondary();
	
	delete primarySlowPulseTimer;
	primarySlowPulseTimer = null;
	delete secondarySlowPulseTimer;
	secondarySlowPulseTimer = null;

	if (client > 0 && IsClientInGame(client))
	{
		SetEntProp(client, Prop_Send, "m_bGlowEnabled", 0);
		SDKUnhook(client, SDKHook_GetMaxHealth, OnGetGuardianMaxHealth);

		if (respawn)
		{
			ChangeClientTeam(client, view_as<int>(TFTeam_Red));
			TF2_RespawnPlayer(client);
		}
	}

	HideBossHealthBar();

	guardianActive = false;
	guardianClient = 0;
	guardianCurrentHP = 0;
	guardianMaxHP     = 0;

	// Restore normal rules
	if (cvUnbalanceLimit != null) cvUnbalanceLimit.SetInt(1);
	if (cvAutoteambalance != null) cvAutoteambalance.SetInt(1);

	StopUpdateTimer();
}

void ResetAllState(bool preserveQueuedSelection = false)
{
	if (guardianActive)
	{
		CleanupGuardian(false);
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
//  Health System
// ============================================================================

void ApplyGuardianHealth()
{
	if (!guardianActive || !IsClientInGame(guardianClient)) return;

	SetEntityHealth(guardianClient, guardianCurrentHP);
	SetEntProp(guardianClient, Prop_Data, "m_iMaxHealth", guardianMaxHP);
}

	// Removed OnGuardianDamage since health is perfectly tracked via GetClientHealth() dynamically.

/**
 * SDKHook_GetMaxHealth callback — tells the engine the Guardian's true max health.
 * Without this, TF2 treats health above 175 (Pyro base) as overheal and drains it.
 * Returning Plugin_Changed with the custom max health prevents the drain entirely.
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

// G key — Taunt (detected via condition)
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
	if (slotIdx == 1) primaryTimer = CreateDataTimer(ability.Duration, Timer_PrimaryExpire, pack, TIMER_FLAG_NO_MAPCHANGE);
	else secondaryTimer = CreateDataTimer(ability.Duration, Timer_SecondaryExpire, pack, TIMER_FLAG_NO_MAPCHANGE);
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
		delete primarySlowPulseTimer;
		primarySlowPulseTimer = null;
		delete secondarySlowPulseTimer;
		secondarySlowPulseTimer = null;
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
	TE_SetupBeamRingPoint(origin, 10.0, radius, PrecacheModel("materials/sprites/laserbeam.vmt"), PrecacheModel("materials/sprites/halo01.vmt"), 0, 15, 0.4, 3.0, 0.0, color, 10, 0); // Reduced duration to 0.4 for higher pulse rate
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

	// Bot join check — disable Guardian if a bot appeared mid-round
	if (HasActiveBots())
	{
		CPrintToChatAll("%t", "Guardian_BotJoined");
		CleanupGuardian(true);
		updateTimer = null;
		return Plugin_Stop;
	}

	// FFA check — disable Guardian if FFA was enabled mid-round
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
	if (monsterResource == -1 || !IsValidEntity(monsterResource)) return;

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
	SetEntProp(monsterResource, Prop_Send, "m_iTeamNum", 3);   // Enforce BLU team
}

void HideBossHealthBar()
{
	if (monsterResource != -1 && IsValidEntity(monsterResource))
	{
		SetEntProp(monsterResource, Prop_Send, "m_iBossHealthPercentageByte", 0);
		SetEntProp(monsterResource, Prop_Send, "m_iBossState", 0);
		SetEntProp(monsterResource, Prop_Send, "m_iTeamNum", 0);
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

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) <= 1) continue;
		
		// Skip the last guardian if we have other choices
		if (i == lastGuardian && lastGuardian != 0) continue;

		candidates[count++] = i;
	}

	// If no other candidates (e.g. 1v1 and we're skipping the winner), 
	// fall back to including everyone to avoid a crash/failure.
	if (count == 0)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) <= 1) continue;
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
