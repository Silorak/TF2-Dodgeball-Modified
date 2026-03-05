#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <multicolors>

#include <tfdb>
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

enum struct GuardianClass
{
	char  Name[32];
	char  DisplayName[64];
	int   Health;
	int   Weight;

	float RageCooldown;
	float RageDuration;
	float RageAirblastRefire;
	float RageAirblastPush;
	char  RageParticle[PLATFORM_MAX_PATH];

	float SprintCooldown;
	float SprintDuration;
	float SprintSpeedMultiplier;
	char  SprintParticle[PLATFORM_MAX_PATH];
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

// Classes
GuardianClass guardianClasses[MAX_GUARDIAN_CLASSES];
int           guardianClassCount;

// Active state
bool          guardianActive;
int           guardianClient;
int           activeClassIndex;
int           guardianMaxHP;
int           guardianCurrentHP;

// Admin force for next round
int           forcedClient  = -1;
int           forcedClass   = -1;

// Rage ability (G key)
bool          rageActive;
float         rageExpireTime;
float         rageNextUseTime;
int           rageParticleRef = INVALID_ENT_REFERENCE;

// Sprint ability (R key)
bool          sprintActive;
float         sprintExpireTime;
float         sprintNextUseTime;
int           sprintParticleRef = INVALID_ENT_REFERENCE;
float         normalSpeed;

// HUD
Handle        hudSync;
Handle        updateTimer;

// Boss HP bar entity
int           monsterResource = -1;

// Edge detection for R key per-client
int           previousButtons[MAXPLAYERS + 1];

// FFA detection
ConVar        cvarFriendlyFire;

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

public void OnPluginStart()
{
	LoadTranslations("tfdb.phrases.txt");

	RegAdminCmd("sm_forceguardian",  Command_ForceGuardian,  ADMFLAG_CONFIG, "Force a player as Guardian next round. Usage: sm_forceguardian <player> [class]");
	RegAdminCmd("sm_guardianclass",  Command_GuardianClass,  ADMFLAG_CONFIG, "Set guardian class for next round. Usage: sm_guardianclass <class>");
	RegAdminCmd("sm_removeguardian", Command_RemoveGuardian, ADMFLAG_CONFIG, "Remove the current Guardian mid-round.");

	hudSync = CreateHudSynchronizer();

	HookEvent("teamplay_round_start", OnRoundStart);
	HookEvent("player_death",         OnPlayerDeath);
	HookEvent("player_spawn",         OnPlayerSpawn);
	HookEvent("player_team",          OnPlayerTeamChange, EventHookMode_Pre);

	cvarFriendlyFire = FindConVar("mp_friendlyfire");

	if (!TFDB_IsDodgeballEnabled()) return;

	TFDB_OnRocketsConfigExecuted("general.cfg");
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
	PrecacheSound(SOUND_SELECTED, true);
	PrecacheSound(SOUND_READY, true);
	PrecacheSound(SOUND_ACTIVATE, true);

	monsterResource = FindEntityByClassname(-1, "monster_resource");

	if (monsterResource == -1)
	{
		monsterResource = CreateEntityByName("monster_resource");

		if (IsValidEntity(monsterResource))
		{
			DispatchSpawn(monsterResource);
		}
	}
}

public void OnMapEnd()
{
	ResetAllState();
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
		hudY            = kv.GetFloat("hud y", 0.85);

		char colorStr[32];
		kv.GetString("hud color", colorStr, sizeof(colorStr), "255 50 50");

		char parts[3][8];
		ExplodeString(colorStr, " ", parts, sizeof(parts), sizeof(parts[]));
		hudColor[0] = StringToInt(parts[0]);
		hudColor[1] = StringToInt(parts[1]);
		hudColor[2] = StringToInt(parts[2]);

		kv.GoBack();
	}

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

				guardianClasses[idx].RageCooldown       = kv.GetFloat("rage cooldown", 15.0);
				guardianClasses[idx].RageDuration        = kv.GetFloat("rage duration", 5.0);
				guardianClasses[idx].RageAirblastRefire  = kv.GetFloat("rage airblast refire", 0.5);
				guardianClasses[idx].RageAirblastPush    = kv.GetFloat("rage airblast push scale", 1.5);
				kv.GetString("rage particle", guardianClasses[idx].RageParticle, sizeof(guardianClasses[].RageParticle), "utaunt_hellfire_red");

				guardianClasses[idx].SprintCooldown          = kv.GetFloat("sprint cooldown", 12.0);
				guardianClasses[idx].SprintDuration           = kv.GetFloat("sprint duration", 3.0);
				guardianClasses[idx].SprintSpeedMultiplier   = kv.GetFloat("sprint speed multiplier", 1.6);
				kv.GetString("sprint particle", guardianClasses[idx].SprintParticle, sizeof(guardianClasses[].SprintParticle), "utaunt_electricity_teamcolor_blue");

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
		CPrintToChatAll("%t", "Guardian_BlockedBot");
		return false;
	}

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

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// Clean up previous round
	if (guardianActive)
	{
		CleanupGuardian(false);
	}

	if (!CanActivateGuardian()) return;

	// Determine activation
	bool activate = false;
	int target = -1;
	int classIndex = -1;

	if (forcedClient != -1)
	{
		if (IsClientInGame(forcedClient) && IsPlayerAlive(forcedClient))
		{
			target   = forcedClient;
			activate = true;
		}

		forcedClient = -1;
	}
	else
	{
		if (GetRandomInt(1, 100) <= selectionChance)
		{
			activate = true;
		}
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

	ActivateGuardian(target, classIndex);
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!guardianActive) return;

	int client = GetClientOfUserId(event.GetInt("userid"));

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
	int newTeam = event.GetInt("team");

	if (client != guardianClient && newTeam == view_as<int>(TFTeam_Blue))
	{
		CreateTimer(0.1, Timer_ForceRed, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}

	return Plugin_Continue;
}

public Action Timer_ForceRed(Handle timer, any userId)
{
	int client = GetClientOfUserId(userId);

	if (client > 0 && IsClientInGame(client) && client != guardianClient)
	{
		if (GetClientTeam(client) == view_as<int>(TFTeam_Blue))
		{
			ChangeClientTeam(client, view_as<int>(TFTeam_Red));

			if (IsPlayerAlive(client))
			{
				TF2_RespawnPlayer(client);
			}

			CPrintToChat(client, "%t", "Guardian_TeamBlocked");
		}
	}

	return Plugin_Stop;
}

// Block jointeam to BLU via console command
public Action OnClientCommand(int client, int args)
{
	if (!guardianActive || client == guardianClient) return Plugin_Continue;

	char cmd[32];
	GetCmdArg(0, cmd, sizeof(cmd));

	if (strcmp(cmd, "jointeam", false) == 0 && args >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));

		if (strcmp(arg, "blue", false) == 0 || strcmp(arg, "3", false) == 0)
		{
			CPrintToChat(client, "%t", "Guardian_TeamBlocked");
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

	// Reset abilities
	rageActive         = false;
	rageExpireTime     = 0.0;
	rageNextUseTime    = 0.0;
	rageParticleRef    = INVALID_ENT_REFERENCE;

	sprintActive       = false;
	sprintExpireTime   = 0.0;
	sprintNextUseTime  = 0.0;
	sprintParticleRef  = INVALID_ENT_REFERENCE;
	normalSpeed        = 0.0;

	// Move to BLU
	if (GetClientTeam(client) != view_as<int>(TFTeam_Blue))
	{
		ChangeClientTeam(client, view_as<int>(TFTeam_Blue));
		TF2_RespawnPlayer(client);
	}

	ApplyGuardianHealth();

	// Glow
	SetEntProp(client, Prop_Send, "m_bGlowEnabled", 1);

	// Hook damage for HP tracking
	SDKHook(client, SDKHook_OnTakeDamage, OnGuardianDamage);

	// Announce
	EmitSoundToAll(SOUND_SELECTED);
	CPrintToChatAll("%t", "Guardian_Selected", client, guardianClasses[classIndex].DisplayName);

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
	if (!guardianActive) return;

	int client = guardianClient;

	DeactivateRage();
	DeactivateSprint();

	if (IsClientInGame(client))
	{
		SetEntProp(client, Prop_Send, "m_bGlowEnabled", 0);
		SDKUnhook(client, SDKHook_OnTakeDamage, OnGuardianDamage);

		if (respawn && IsPlayerAlive(client))
		{
			ChangeClientTeam(client, view_as<int>(TFTeam_Red));
			TF2_RespawnPlayer(client);
		}
	}

	HideBossHealthBar();

	guardianActive = false;
	guardianClient = 0;

	StopUpdateTimer();
}

void ResetAllState()
{
	if (guardianActive)
	{
		CleanupGuardian(false);
	}

	forcedClient    = -1;
	forcedClass     = -1;
	monsterResource = -1;

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

public Action OnGuardianDamage(int victim, int &attacker, int &inflictor, float &damage, int &damageType)
{
	if (!guardianActive || victim != guardianClient) return Plugin_Continue;

	guardianCurrentHP -= RoundToFloor(damage);

	if (guardianCurrentHP < 0)
	{
		guardianCurrentHP = 0;
	}

	UpdateBossHealthBar();

	return Plugin_Continue;
}

// ============================================================================
//  Ability Input Detection
// ============================================================================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!guardianActive || client != guardianClient || !IsPlayerAlive(client))
	{
		return Plugin_Continue;
	}

	// R key — Sprint (rising edge only)
	bool reloadPressed  = (buttons & IN_RELOAD) != 0;
	bool reloadPrevious = (previousButtons[client] & IN_RELOAD) != 0;

	if (reloadPressed && !reloadPrevious)
	{
		float now = GetGameTime();

		if (!sprintActive && now >= sprintNextUseTime)
		{
			ActivateSprint();
		}
	}

	previousButtons[client] = buttons;

	return Plugin_Continue;
}

// G key — Taunt (detected via condition)
public void TF2_OnConditionAdded(int client, TFCond condition)
{
	if (!guardianActive || client != guardianClient) return;

	if (condition == TFCond_Taunting)
	{
		TF2_RemoveCondition(client, TFCond_Taunting);

		float now = GetGameTime();

		if (!rageActive && now >= rageNextUseTime)
		{
			ActivateRage();
		}
	}
}

// ============================================================================
//  Rage Ability (G key)
// ============================================================================

void ActivateRage()
{
	if (!guardianActive || !IsClientInGame(guardianClient)) return;

	int idx = activeClassIndex;

	rageActive     = true;
	rageExpireTime = GetGameTime() + guardianClasses[idx].RageDuration;

	// Airblast attributes on primary weapon
	int weapon = GetPlayerWeaponSlot(guardianClient, 0);

	if (weapon != -1 && IsValidEntity(weapon))
	{
		TF2Attrib_SetByName(weapon, "mult airblast refire time", guardianClasses[idx].RageAirblastRefire);
		TF2Attrib_SetByName(weapon, "airblast pushback scale",   guardianClasses[idx].RageAirblastPush);
	}

	// Particle
	rageParticleRef = AttachParticle(guardianClient, guardianClasses[idx].RageParticle);

	// Sound + announce
	EmitSoundToAll(SOUND_ACTIVATE);
	CPrintToChatAll("%t", "Guardian_RageActivated", guardianClient);

	CreateTimer(guardianClasses[idx].RageDuration, Timer_RageExpire, _, TIMER_FLAG_NO_MAPCHANGE);
}

void DeactivateRage()
{
	if (!rageActive) return;

	rageActive       = false;
	rageNextUseTime  = GetGameTime() + guardianClasses[activeClassIndex].RageCooldown;

	if (IsClientInGame(guardianClient))
	{
		int weapon = GetPlayerWeaponSlot(guardianClient, 0);

		if (weapon != -1 && IsValidEntity(weapon))
		{
			TF2Attrib_RemoveByName(weapon, "mult airblast refire time");
			TF2Attrib_RemoveByName(weapon, "airblast pushback scale");
		}
	}

	DestroyParticle(rageParticleRef);
	rageParticleRef = INVALID_ENT_REFERENCE;
}

public Action Timer_RageExpire(Handle timer)
{
	DeactivateRage();

	if (guardianActive && IsClientInGame(guardianClient))
	{
		EmitSoundToClient(guardianClient, SOUND_READY);
	}

	return Plugin_Stop;
}

// ============================================================================
//  Sprint Ability (R key)
// ============================================================================

void ActivateSprint()
{
	if (!guardianActive || !IsClientInGame(guardianClient)) return;

	int idx = activeClassIndex;

	sprintActive     = true;
	sprintExpireTime = GetGameTime() + guardianClasses[idx].SprintDuration;

	normalSpeed = GetEntPropFloat(guardianClient, Prop_Send, "m_flMaxspeed");

	float boosted = normalSpeed * guardianClasses[idx].SprintSpeedMultiplier;
	SetEntPropFloat(guardianClient, Prop_Send, "m_flMaxspeed", boosted);

	sprintParticleRef = AttachParticle(guardianClient, guardianClasses[idx].SprintParticle);

	EmitSoundToAll(SOUND_ACTIVATE);
	CPrintToChatAll("%t", "Guardian_SprintActivated", guardianClient);

	CreateTimer(guardianClasses[idx].SprintDuration, Timer_SprintExpire, _, TIMER_FLAG_NO_MAPCHANGE);
}

void DeactivateSprint()
{
	if (!sprintActive) return;

	sprintActive      = false;
	sprintNextUseTime = GetGameTime() + guardianClasses[activeClassIndex].SprintCooldown;

	if (IsClientInGame(guardianClient) && IsPlayerAlive(guardianClient) && normalSpeed > 0.0)
	{
		SetEntPropFloat(guardianClient, Prop_Send, "m_flMaxspeed", normalSpeed);
	}

	DestroyParticle(sprintParticleRef);
	sprintParticleRef = INVALID_ENT_REFERENCE;
}

public Action Timer_SprintExpire(Handle timer)
{
	DeactivateSprint();

	if (guardianActive && IsClientInGame(guardianClient))
	{
		EmitSoundToClient(guardianClient, SOUND_READY);
	}

	return Plugin_Stop;
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
	if (rageActive && now >= rageExpireTime)
	{
		DeactivateRage();
	}

	if (sprintActive && now >= sprintExpireTime)
	{
		DeactivateSprint();
	}

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

	char rageStatus[64];
	char sprintStatus[64];

	if (rageActive)
	{
		float remaining = rageExpireTime - now;
		FormatEx(rageStatus, sizeof(rageStatus), "RAGE [ACTIVE %.1fs]", remaining);
	}
	else if (now < rageNextUseTime)
	{
		float cooldown = rageNextUseTime - now;
		FormatEx(rageStatus, sizeof(rageStatus), "RAGE [CD %.1fs]", cooldown);
	}
	else
	{
		strcopy(rageStatus, sizeof(rageStatus), "RAGE [READY — Press G]");
	}

	if (sprintActive)
	{
		float remaining = sprintExpireTime - now;
		FormatEx(sprintStatus, sizeof(sprintStatus), "SPRINT [ACTIVE %.1fs]", remaining);
	}
	else if (now < sprintNextUseTime)
	{
		float cooldown = sprintNextUseTime - now;
		FormatEx(sprintStatus, sizeof(sprintStatus), "SPRINT [CD %.1fs]", cooldown);
	}
	else
	{
		strcopy(sprintStatus, sizeof(sprintStatus), "SPRINT [READY — Press R]");
	}

	SetHudTextParams(hudX, hudY, HUD_UPDATE_INTERVAL + 0.05, hudColor[0], hudColor[1], hudColor[2], 255, 0, 0.0, 0.0, 0.0);
	ShowSyncHudText(guardianClient, hudSync,
		"[ %s ] HP: %d / %d\n%s\n%s",
		guardianClasses[idx].DisplayName,
		guardianCurrentHP, guardianMaxHP,
		rageStatus,
		sprintStatus);

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

	int byte = RoundToFloor((float(guardianCurrentHP) / float(guardianMaxHP)) * 255.0);

	if (byte < 0)   byte = 0;
	if (byte > 255)  byte = 255;

	SetEntProp(monsterResource, Prop_Send, "m_iBossHealthPercentageByte", byte);
}

void HideBossHealthBar()
{
	if (monsterResource != -1 && IsValidEntity(monsterResource))
	{
		SetEntProp(monsterResource, Prop_Send, "m_iBossHealthPercentageByte", 0);
	}
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

	DispatchKeyValue(particle, "effect_name", particleName);
	DispatchKeyValueVector(particle, "origin", pos);
	DispatchSpawn(particle);
	ActivateEntity(particle);
	AcceptEntityInput(particle, "Start");

	SetVariantString("!activator");
	AcceptEntityInput(particle, "SetParent", client, particle, 0);

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

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || IsFakeClient(i)) continue;

		candidates[count++] = i;
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
