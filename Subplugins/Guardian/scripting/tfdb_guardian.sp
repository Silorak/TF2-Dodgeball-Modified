#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <multicolors>

#include <tfdb>
#include <tfdb_clientcheck>
#include <tfdb_guardian>
#include <tfdb_pvb>
#include <tfdb_deathmatch>
#undef REQUIRE_PLUGIN
#tryinclude <tfdb_ffa>
#define REQUIRE_PLUGIN
#include <tf2attributes>

#define PLUGIN_NAME        "[TFDB] Guardian"
#define PLUGIN_AUTHOR      "Silorak"
#define PLUGIN_DESCRIPTION "Guardian mode for dodgeball - one powered player vs all"
#define PLUGIN_VERSION "2.3.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

#define MAX_GUARDIAN_CLASSES   16
#define HUD_UPDATE_INTERVAL    0.1

#define SOUND_SELECTED  "misc/killstreak.wav"
#define SOUND_READY     "buttons/button17.wav"
#define SOUND_ACTIVATE  "misc/halloween/spell_overheal.wav"

#define GUARDIAN_LOG_DIR     "logs/tfdb_guardian"
#define GUARDIAN_LOG_FILE    "logs/tfdb_guardian/debug.log"
#define GUARDIAN_SEL_FILE    "logs/tfdb_guardian/select.log"
#define GUARDIAN_BTN_TAUNT 1000000   // taunt-key sentinel used in button masks

// Resolved at plugin start via BuildPath - writes to addons/sourcemod/logs/
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
bool          ffaMessageShown;  // dedup the "Guardian blocked: FFA active" chat - was firing every CanActivateGuardian call (multiple per round)

// Admin force for next round (stored as userid to prevent slot reuse)
int           forcedClientUserId  = 0;
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

// --- HUD string cache (perf) ---
// Timer_Update runs at 10Hz; the static display strings (class display name,
// uppercased ability names, button labels) never change while a guardian round
// is active because activeClassIndex is fixed for the duration. Cache them on
// activation, read per tick, invalidate on cleanup. Only the dynamic
// status/cooldown text is rebuilt each tick.
char g_CachedDisplayName[64];
char g_CachedName1[32];
char g_CachedName2[32];
char g_CachedKey1[16];
char g_CachedKey2[16];
bool g_CachedHudReady = false;

// --- Bot presence count (perf) ---
// HasActiveBots() iterated MaxClients every Timer_Update tick. Maintain a
// running count via the bot lifecycle events instead. Counts fake clients on
// teams > 1 (RED/BLU). Spectator-bot transitions are tracked via player_team.
int  g_ActiveBotCount = 0;

// --- FFA active cache (perf) ---
// IsFFAActive() did LibraryExists + GetFeatureStatus + native call every tick.
// Refresh on plugin load events + round_start; read the cached bool each tick.
bool g_FFAActiveCached = false;

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
	LogToFileEx(GUARDIAN_SEL, "%s", buffer);
}

/**
 * Logs to the guardian debug log only when debugMode is active.
 */
void GuardianDebugLog(const char[] format, any ...)
{
	if (!debugMode) return;

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogToFileEx(GUARDIAN_LOG, "%s", buffer);
}

public void OnPluginStart()
{
	// Guardian depends on the TF2Attributes extension for ability attributes.
	// Log a warning if missing/broken so admins know, but don't SetFailState -
	// boss HP bar + team management still work without TF2Attrib_* calls. This
	// matches AntiSnipe's permissive pattern for CollisionHook (graceful degrade).
	int tf2AttribStatus = GetExtensionFileStatus("tf2attributes.ext");
	if (tf2AttribStatus < 1)
	{
		LogError("[Guardian] TF2Attributes extension status %d (1 = loaded OK). Ability attributes may not work. Install: https://github.com/FlaminSarge/tf2attributes", tf2AttribStatus);
	}

	// Resolve log paths to addons/sourcemod/logs/tfdb_guardian/ via BuildPath.
	// LogToFileEx takes raw paths - without BuildPath it resolves
	// relative to the game directory (tf/) which may not have a logs/ folder.
	// Create the per-plugin log folder first; LogToFile won't create it.
	char guardianLogDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, guardianLogDir, sizeof(guardianLogDir), GUARDIAN_LOG_DIR);
	if (!DirExists(guardianLogDir))
	{
		CreateDirectory(guardianLogDir, 511);  // 0777
	}

	BuildPath(Path_SM, GUARDIAN_LOG, sizeof(GUARDIAN_LOG), GUARDIAN_LOG_FILE);
	BuildPath(Path_SM, GUARDIAN_SEL, sizeof(GUARDIAN_SEL), GUARDIAN_SEL_FILE);

	LoadTranslations("tfdb.phrases.txt");
	debugBossState = -1;

	RegAdminCmd("sm_forceguardian",  Command_ForceGuardian,  ADMFLAG_CONFIG, "Force a player as Guardian next round. Usage: sm_forceguardian <player> [class]");
	RegAdminCmd("sm_gclass",  Command_GuardianClass,  ADMFLAG_CONFIG, "Set guardian class for next round. Usage: sm_guardianclass <class>");
	RegAdminCmd("sm_rguard", Command_RemoveGuardian, ADMFLAG_CONFIG, "Remove the current Guardian mid-round.");

	hudSync = CreateHudSynchronizer();

	HookEventEx("teamplay_round_start", OnRoundStart);
	HookEventEx("teamplay_round_win",   OnRoundWin);
	HookEventEx("arena_round_start",    OnArenaRoundStart, EventHookMode_PostNoCopy);
	HookEventEx("player_death",         OnPlayerDeath);
	HookEventEx("player_spawn",         OnPlayerSpawn);
	HookEventEx("player_team",          OnPlayerTeamChange, EventHookMode_Pre);

	RegAdminCmd("sm_gboss", Command_BossState, ADMFLAG_ROOT); // Hidden debug
	RegAdminCmd("sm_gdebug", Command_DebugGuardian, ADMFLAG_ROOT, "Toggle guardian debug output.");
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

public void OnAllPluginsLoaded()
{
	// Guardian hard-requires the tfdb core. Without it, every TFDB_* native
	// call would throw "missing native" at runtime - fail loudly instead.
	if (!LibraryExists("tfdb"))
	{
		SetFailState("[Guardian] tfdb core plugin not loaded - Guardian cannot function.");
	}

	// Initial population of the FFA cache. From now on it's maintained by
	// OnLibraryAdded / OnLibraryRemoved / round_start.
	RefreshFFAActiveCache();

	// Initial population of the bot counter for late-load. Without this, if
	// Guardian loads mid-round with bots already on RED/BLU, g_ActiveBotCount
	// stays at 0 until OnRoundStart fires - meaning HasActiveBots() returns
	// false and Guardian can wrongly activate over a PvB round.
	// (Audit finding 2026-04-26.)
	RecountActiveBots();
}

public void OnLibraryAdded(const char[] name)
{
	// FFA plugin (un)loaded mid-game flips whether IsFFAActive() can return
	// true. Refresh the cache so Timer_Update sees the change without polling.
	if (StrEqual(name, "tfdb_ffa"))
	{
		RefreshFFAActiveCache();
	}
}

public void OnLibraryRemoved(const char[] name)
{
	// If the core unloads at runtime, disable ourselves gracefully rather than
	// SetFailState'ing - a SetFailState here cascades when the core crashes
	// (both plugins error into the log at once, tangling the root cause).
	// We'll simply stop reacting; subsequent native calls are guarded below.
	if (StrEqual(name, "tfdb"))
	{
		LogMessage("[Guardian] tfdb core unloaded - disabling Guardian.");
		enabled      = false;
		guardianActive = false;
	}

	if (StrEqual(name, "tfdb_ffa"))
	{
		RefreshFFAActiveCache();
	}
}

public Action Listener_BlockGuardianCommands(int client, const char[] command, int argc)
{
	if (!guardianActive || client != guardianClient || !IsClientInGame(client) || !IsPlayerAlive(client))
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
		CPrintToChat(client, "%t", "Guardian_CmdBlocked", command);
		return Plugin_Handled;
	}

	// Non-guardian: block attempts to join BLU, redirect to RED
	if (strcmp(command, "autoteam", false) == 0)
	{
		GuardianLog("[CMD] " ... "BlockBLUJoin - autoteam from %N (client=%d team=%d) - redirecting to RED", client, client, GetClientTeam(client));
		CPrintToChat(client, "%t", "Guardian_MovedToRed");
		FakeClientCommandEx(client, "jointeam red");
		return Plugin_Handled;
	}

	if (strcmp(command, "jointeam", false) == 0 && argc >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));

		if (strcmp(arg, "blue", false) == 0 || strcmp(arg, "3", false) == 0 || strcmp(arg, "auto", false) == 0)
		{
			GuardianLog("[CMD] " ... "BlockBLUJoin - jointeam %s from %N (client=%d team=%d) - redirecting to RED", arg, client, client, GetClientTeam(client));
			CPrintToChat(client, "%t", "Guardian_MovedToRed");
			FakeClientCommandEx(client, "jointeam red");
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

	// Release the HUD synchronizer handle (created in OnPluginStart).
	if (hudSync != null)
	{
		delete hudSync;
		hudSync = null;
	}
}

public void OnMapStart()
{
	// Reset perf-cache state. No bots survive a map change; the count must
	// start at zero. FFA cache will be refreshed on round start.
	g_ActiveBotCount  = 0;
	g_FFAActiveCached = false;
	g_CachedHudReady  = false;

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

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
}

// ============================================================================
//  Spawn Rocket AOE Protection
// ============================================================================
//
// Exploit: the Guardian walks to a rocket spawn point and intentionally takes
// the spawn rocket hit. The rocket's AOE splash kills nearby RED players
// without the Guardian ever needing to deflect. This turns spawn points into
// weapons.
//
// Fix: if a rocket has 0 deflections (freshly spawned, never airblasted) and
// the player taking damage is NOT the rocket's intended target, block the
// damage entirely. The target (usually the Guardian) still takes full damage.
//
public Action OnPlayerTakeDamage(int victim, int &attacker, int &inflictor,
                                  float &damage, int &damagetype,
                                  int &weapon, float damageForce[3],
                                  float damagePosition[3])
{
	// Only filter during active Guardian rounds
	if (!guardianActive) return Plugin_Continue;

	// Check if damage came from a rocket projectile
	if (inflictor <= 0 || !IsValidEntity(inflictor)) return Plugin_Continue;

	char classname[64];
	GetEntityClassname(inflictor, classname, sizeof(classname));
	if (strcmp(classname, "tf_projectile_rocket") != 0) return Plugin_Continue;

	// Find the dodgeball rocket index for this entity
	int rocketIdx = TFDB_FindRocketByEntity(inflictor);
	if (rocketIdx == -1) return Plugin_Continue;

	// Only block on freshly spawned rockets (0 deflections = never airblasted)
	int deflections = TFDB_GetRocketDeflections(rocketIdx);
	if (deflections > 0) return Plugin_Continue;

	// Allow damage to the rocket's intended target (usually the Guardian)
	int target = TFDB_GetRocketTarget(rocketIdx);
	if (target == victim) return Plugin_Continue;

	// Only block splash to players on the SAME team as the rocket.
	// Spawn rockets are team-coloured: a RED rocket targets BLU, and its
	// splash should never damage RED teammates anyway. Blocking all
	// non-target damage regardless of team could accidentally protect the
	// Guardian from an enemy spawn rocket whose target hasn't been set yet
	// (race condition between TFDB target assignment and the damage event).
	int rocketTeam = GetEntProp(inflictor, Prop_Send, "m_iTeamNum", 1);
	int victimTeam = GetClientTeam(victim);
	if (rocketTeam == victimTeam) return Plugin_Handled;

	// Block AOE splash damage to non-target players from spawn rockets
	if (debugMode)
	{
		char victimName[64];
		GetClientName(victim, victimName, sizeof(victimName));
		GuardianDebugLog("[SPAWN PROTECT] Blocked %.0f damage to %s from spawn rocket (0 deflections, not target)", damage, victimName);
	}

	return Plugin_Handled;
}

public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
	previousButtons[client] = 0;
	guardianOptOut[client]  = false;

	// Maintain g_ActiveBotCount: if a bot on a play team disconnects, decrement.
	// IsClientInGame is still true at OnClientDisconnect (the slot hasn't freed
	// yet), so IsFakeClient + GetClientTeam are valid here.
	if (IsClientInGame(client) && IsFakeClient(client) && GetClientTeam(client) > 1)
	{
		if (g_ActiveBotCount > 0) g_ActiveBotCount--;
	}

	if (guardianActive && client == guardianClient)
	{
		CPrintToChatAll("%t", "Guardian_Disconnected", client);
		CleanupGuardian(false);
	}

	if (forcedClientUserId != 0 && GetClientOfUserId(forcedClientUserId) == client)
	{
		forcedClientUserId = 0;
	}
}

public void OnClientPostAdminCheck(int client)
{
	// Maintain g_ActiveBotCount: bot just authenticated. If they're on a play
	// team (>1) - uncommon at PostAdminCheck since bots usually start as
	// unassigned, but possible - count them. The player_team handler covers
	// the normal case where the bot is later assigned to RED/BLU.
	if (IsFakeClient(client) && IsClientInGame(client) && GetClientTeam(client) > 1)
	{
		g_ActiveBotCount++;
	}

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

/**
 * Human-readable label for an ability's bound button. Used in the guardian HUD
 * so players can see WHICH key triggers each ability instead of just the type
 * name. Default TF2 keybinds assumed; admins running custom binds should say so.
 *
 * Mirrors the parse table in ParseAbilityConfig:
 *   IN_RELOAD   -> "R"         (reload key)
 *   IN_ATTACK3  -> "MOUSE3"    (mouse wheel click / middle mouse)
 *   IN_USE      -> "E"         (use key)
 *   1000000     -> "G"         (taunt key, sentinel value)
 *   0           -> "(none)"    (no button bound / parse fallback)
 */
void GetButtonLabel(int buttonBit, char[] buffer, int maxLen)
{
	if (buttonBit == IN_RELOAD)       strcopy(buffer, maxLen, "R");
	else if (buttonBit == IN_ATTACK3) strcopy(buffer, maxLen, "MOUSE3");
	else if (buttonBit == IN_USE)     strcopy(buffer, maxLen, "E");
	else if (buttonBit == 1000000)    strcopy(buffer, maxLen, "G");
	else                              strcopy(buffer, maxLen, "(none)");
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

/**
 * Recount active bots from scratch. Called on map start / round start as a
 * defensive resync - the per-event maintenance in OnClientPostAdminCheck /
 * OnClientDisconnect / OnPlayerTeamChange should keep g_ActiveBotCount
 * accurate, but a full rescan costs nothing on map boundaries and prevents
 * permanent drift if any event was missed.
 */
void RecountActiveBots()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) > 1)
			count++;
	}
	g_ActiveBotCount = count;
}

/**
 * Refresh g_FFAActiveCached. Called on plugin load events + round_start, NOT
 * on every Timer_Update tick. Mirrors IsFFAActive()'s logic exactly.
 */
void RefreshFFAActiveCache()
{
	if (LibraryExists("tfdb_ffa") &&
	    GetFeatureStatus(FeatureType_Native, "TFDB_IsFFAActive") == FeatureStatus_Available &&
	    TFDB_IsFFAActive())
	{
		g_FFAActiveCached = true;
		return;
	}

	// Legacy fallback: friendlyfire cvar implies FFA when tfdb_ffa is loaded
	// but doesn't expose the native (older FFA builds).
	if (LibraryExists("tfdb_ffa") && cvarFriendlyFire != null && cvarFriendlyFire.BoolValue)
	{
		g_FFAActiveCached = true;
		return;
	}

	g_FFAActiveCached = false;
}

/**
 * Build the static portion of the guardian HUD strings once per activation.
 * Read by Timer_Update each tick. Invalidated by CleanupGuardian.
 */
void RebuildGuardianHudCache()
{
	int idx = activeClassIndex;
	if (idx < 0 || idx >= guardianClassCount)
	{
		g_CachedHudReady = false;
		return;
	}

	strcopy(g_CachedDisplayName, sizeof(g_CachedDisplayName), guardianClasses[idx].DisplayName);
	strcopy(g_CachedName1,       sizeof(g_CachedName1),       guardianClasses[idx].PrimaryAbility.Type);
	strcopy(g_CachedName2,       sizeof(g_CachedName2),       guardianClasses[idx].SecondaryAbility.Type);

	for (int i = 0; g_CachedName1[i] != '\0'; i++) g_CachedName1[i] = CharToUpper(g_CachedName1[i]);
	for (int i = 0; g_CachedName2[i] != '\0'; i++) g_CachedName2[i] = CharToUpper(g_CachedName2[i]);

	GetButtonLabel(guardianClasses[idx].PrimaryAbility.Button,   g_CachedKey1, sizeof(g_CachedKey1));
	GetButtonLabel(guardianClasses[idx].SecondaryAbility.Button, g_CachedKey2, sizeof(g_CachedKey2));

	g_CachedHudReady = true;
}

bool IsFFAActive()
{
	// Prefer the proper three-gate native (LibraryExists + FeatureStatus +
	// native call) - same pattern Guardian uses for PvB and DeathMatch. This
	// reads FFA's actual `FFAEnabled` flag, not the indirect mp_friendlyfire
	// signal which is fragile (admins can flip mp_friendlyfire manually,
	// and FFA's "disable on bot join" path also flips it).
	if (LibraryExists("tfdb_ffa") &&
	    GetFeatureStatus(FeatureType_Native, "TFDB_IsFFAActive") == FeatureStatus_Available &&
	    TFDB_IsFFAActive())
	{
		return true;
	}

	// Legacy heuristic fallback for FFA builds older than 2.2.0 that don't
	// expose TFDB_IsFFAActive yet. Cached cvar to avoid FindConVar churn.
	static ConVar ffaCvar = null;
	static bool   ffaCached = false;

	if (!ffaCached)
	{
		ffaCvar  = FindConVar("tf_dodgeball_ffa_bot");
		ffaCached = true;
	}

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

	// Explicit PvB mutual exclusion - HasActiveBots() is imprecise (a PvB round
	// with 0 live bots between spawns wouldn't trip it). See
	// frameworks/guardian-pvb-mutual-exclusion.md in the wiki.
	if (LibraryExists("tfdb_pvb") &&
	    GetFeatureStatus(FeatureType_Native, "TFDB_IsPvBActive") == FeatureStatus_Available &&
	    TFDB_IsPvBActive())
	{
		GuardianLog("CanActivateGuardian - false: PvB is active");
		return false;
	}

	// DeathMatch mutual exclusion - NER swaps teams, which conflicts with
	// Guardian's boss-on-BLU rule. See frameworks/deathmatch-mutual-exclusion.
	if (LibraryExists("tfdb_deathmatch") &&
	    GetFeatureStatus(FeatureType_Native, "TFDB_IsDeathMatchActive") == FeatureStatus_Available &&
	    TFDB_IsDeathMatchActive())
	{
		GuardianLog("CanActivateGuardian - false: DeathMatch is active");
		return false;
	}

	if (IsFFAActive())
	{
		GuardianLog("CanActivateGuardian - false: FFA active");
		// Dedup: only chat once per FFA-active "session". Resets below when
		// FFA flips off so the message can fire again next time it activates.
		if (!ffaMessageShown)
		{
			CPrintToChatAll("%t", "Guardian_BlockedFFA");
			ffaMessageShown = true;
		}
		return false;
	}

	// FFA is off - clear the dedup so the next FFA flip re-announces.
	ffaMessageShown = false;

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

	// FindTarget matches by name even for spectators. Reject so admins don't
	// accidentally force a spec into Guardian role on the next round, which
	// silently kicks them to BLU and bypasses the eligibility count.
	if (TFDB_IsSpectator(target))
	{
		CReplyToCommand(client, "[TFDB] %N is on spectator and can't be forced as Guardian. They must join RED or BLU first.", target);
		return Plugin_Handled;
	}

	forcedClientUserId = GetClientUserId(target);
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

	// Capture client BEFORE CleanupGuardian so the chat message has a valid reference
	// even if cleanup invalidates guardianClient (e.g. player disconnected mid-command).
	int removedClient = guardianClient;
	CleanupGuardian(true);
	CPrintToChatAll("%t", "Guardian_Removed", removedClient);

	return Plugin_Handled;
}

public Action Command_GuardianOptOut(int client, int args)
{
	if (client == 0 || !TFDB_IsRealHuman(client))
	{
		ReplyToCommand(client, "[TFDB] This command is player-only.");
		return Plugin_Handled;
	}

	guardianOptOut[client] = !guardianOptOut[client];

	if (guardianOptOut[client])
	{
		if (optOutMinPlayers > 0)
			CPrintToChat(client, "%t", "Guardian_OptedOutMin", optOutMinPlayers);
		else
			CPrintToChat(client, "%t", "Guardian_OptedOut");
	}
	else
	{
		CPrintToChat(client, "%t", "Guardian_OptedIn");
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
	if (forcedClientUserId != 0 || forcedClass != -1)
	{
		GuardianLog("OnRoundWin - forced next round (forcedClientUserId=%d forcedClass=%d)", forcedClientUserId, forcedClass);
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
		GuardianDebugLog("[GUARDIAN DBG] " ... "OnArenaRoundStart - guardianActive=%d TFDB_GetRoundStarted()=%d", guardianActive, TFDB_GetRoundStarted());
	}
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (debugMode)
	{
		GuardianDebugLog("[GUARDIAN DBG] " ... "OnRoundStart - nextRoundIsGuardian=%d forcedClientUserId=%d forcedClass=%d", nextRoundIsGuardian, forcedClientUserId, forcedClass);
	}
	GuardianLog("=== OnRoundStart - nextRoundIsGuardian=%d forcedClientUserId=%d forcedClass=%d ===",
		nextRoundIsGuardian, forcedClientUserId, forcedClass);

	// Aggressive hard reset every round start
	ResetAllState(true);

	// Refresh perf caches at round boundary. Cheap defensive resync -
	// keeps g_ActiveBotCount and g_FFAActiveCached honest in case any event
	// went missed between rounds (plugin reload, late-load, etc).
	RecountActiveBots();
	RefreshFFAActiveCache();

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

	if (forcedClientUserId != 0)
	{
		int forcedClient = GetClientOfUserId(forcedClientUserId);
		if (forcedClient != 0 && IsClientInGame(forcedClient) && !IsFakeClient(forcedClient))
		{
			GuardianLog("OnRoundStart - using forcedClient=%d (userId=%d)", forcedClient, forcedClientUserId);
			target   = forcedClient;
			activate = true;
		}
		else
		{
			GuardianLog("OnRoundStart - forcedClientUserId=%d no longer valid, ignoring", forcedClientUserId);
		}

		forcedClientUserId = 0;
	}

	if (!activate)
	{
		GuardianLog("OnRoundStart - activate=false, no guardian this round");
		// Critical: when the previous round had a guardian who died and got
		// moved to RED, and this round's dice roll missed, both teams may now
		// be lopsided (e.g. all humans on RED, BLU empty). TF2 arena requires
		// >=1 player per team to start the round, but engine autobalance only
		// fires on player_team/player_disconnect events, not round transitions.
		// Rebalance manually so the round can actually start.
		EnsureTeamBalance();
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


public Action OnPlayerTeamChange(Event event, const char[] name, bool dontBroadcast)
{
	int client  = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients) return Plugin_Continue;

	int newTeam = event.GetInt("team");
	int oldTeam = event.GetInt("oldteam");

	// Maintain g_ActiveBotCount across spectator <-> RED/BLU transitions for bots.
	// Runs unconditionally (not gated on guardianActive) so the count stays
	// correct between rounds too.
	if (IsClientInGame(client) && IsFakeClient(client))
	{
		bool wasOnPlayTeam = (oldTeam > 1);
		bool nowOnPlayTeam = (newTeam > 1);
		if (!wasOnPlayTeam && nowOnPlayTeam)      g_ActiveBotCount++;
		else if (wasOnPlayTeam && !nowOnPlayTeam) { if (g_ActiveBotCount > 0) g_ActiveBotCount--; }
	}

	if (!guardianActive) return Plugin_Continue;

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

	if (client > 0 && TFDB_IsRealHuman(client) && client != guardianClient)
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

	// Build the static HUD string cache once, here, before the 10Hz timer starts
	// hammering Timer_Update. activeClassIndex is fixed for the duration of this
	// guardian round, so the strings derived from it never change - caching saves
	// the per-tick CharToUpper loops and GetButtonLabel calls.
	RebuildGuardianHudCache();

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
		GuardianDebugLog("[GUARDIAN DBG] " ... "CleanupGuardian - client=%d respawn=%d liveHP=%d", client, respawn, (IsClientInGame(client) ? GetClientHealth(client) : -1));
	}

	DeactivatePrimary();
	DeactivateSecondary();

	HideBossHealthBar();

	guardianActive     = false;
	guardianClient     = 0;
	guardianCurrentHP  = 0;
	guardianMaxHP      = 0;
	guardianActivating = false;

	// Invalidate the cached HUD strings. Next ActivateGuardian will rebuild;
	// the safety net in Timer_Update will also rebuild on demand if needed.
	g_CachedHudReady = false;

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

/**
 * Manually rebalance teams when one team is empty and the other has 2+ humans.
 *
 * Engine's mp_autoteambalance fires on player_team/player_disconnect events,
 * NOT on round transitions. After a guardian round where the guardian died and
 * was moved to RED, both humans can end up on RED with BLU empty - arena
 * warmup then refuses to start the round ("Waiting for 1 more player").
 *
 * Move one player from the over-stuffed team to the empty one. Picks a random
 * non-bot, non-spectator client to avoid always punishing the same person.
 * Called from OnRoundStart when no guardian is being activated this round.
 */
void EnsureTeamBalance()
{
	int redCount = 0, bluCount = 0;
	int redCandidates[MAXPLAYERS + 1], bluCandidates[MAXPLAYERS + 1];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i)) continue;
		if (IsFakeClient(i)) continue;
		int team = GetClientTeam(i);
		if (team == view_as<int>(TFTeam_Red))
		{
			redCandidates[redCount++] = i;
		}
		else if (team == view_as<int>(TFTeam_Blue))
		{
			bluCandidates[bluCount++] = i;
		}
	}

	// Only act when one team is empty and the other has 2+ - otherwise leave alone.
	if (redCount >= 2 && bluCount == 0)
	{
		int target = redCandidates[GetRandomInt(0, redCount - 1)];
		GuardianLog("EnsureTeamBalance - moving %N from RED to BLU (red=%d blu=0)", target, redCount);
		ChangeClientTeam(target, view_as<int>(TFTeam_Blue));
	}
	else if (bluCount >= 2 && redCount == 0)
	{
		int target = bluCandidates[GetRandomInt(0, bluCount - 1)];
		GuardianLog("EnsureTeamBalance - moving %N from BLU to RED (blu=%d red=0)", target, bluCount);
		ChangeClientTeam(target, view_as<int>(TFTeam_Red));
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
		forcedClientUserId = 0;
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


/**
 * SDKHook_GetMaxHealth callback - tells the engine the Guardian's true max health.
 * The attribute handles the engine's own drain logic; this hook covers any edge cases
 * where the engine queries max health before the attribute has been evaluated.
 */

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

	if (btn1 > 0 && btn1 != GUARDIAN_BTN_TAUNT)
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
	if (!guardianActive || client != guardianClient || !IsPlayerAlive(client) || !TFDB_GetRoundStarted()) return;

	if (condition == TFCond_Taunting && client == guardianClient)
	{
		TF2_RemoveCondition(client, TFCond_Taunting);

		float now = GetGameTime();
		int btn1 = guardianClasses[activeClassIndex].PrimaryAbility.Button;
		int btn2 = guardianClasses[activeClassIndex].SecondaryAbility.Button;

		if (btn1 == GUARDIAN_BTN_TAUNT && !primaryActive && now >= primaryNextUseTime) ActivateAbility(guardianClasses[activeClassIndex].PrimaryAbility, 1);
		else if (btn2 == 1000000 && !secondaryActive && now >= secondaryNextUseTime) ActivateAbility(guardianClasses[activeClassIndex].SecondaryAbility, 2);
	}
}

// ============================================================================
//  Modular Ability Execution
// ============================================================================









// ============================================================================
//  HUD + Boss Health Bar
// ============================================================================







// ============================================================================
//  Particle Helpers
// ============================================================================



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



// === LOCAL INCLUDES ===
#include "include/tfdb_guardian_config.inc"
#include "include/tfdb_guardian_abilities.inc"
#include "include/tfdb_guardian_hud.inc"