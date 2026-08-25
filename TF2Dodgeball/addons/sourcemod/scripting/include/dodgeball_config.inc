#if defined _dodgeball_config_included
  #endinput
#endif
#define _dodgeball_config_included

/**
 * Handles parsing of configuration files and server commands.
 */

/** Clears all rocket class definitions and frees associated command DataPacks. */
void DestroyRocketClasses()
{
	for (int index = 0; index < RocketClassCount; index++)
	{
		ResetRocketClass(index);
	}
	RocketClassCount = 0;
}

void ResetRocketClass(int index)
{
	DataPack cmdOnSpawn     = RocketClassCmdsOnSpawn[index];
	DataPack cmdOnKill      = RocketClassCmdsOnKill[index];
	DataPack cmdOnSpawnKill = RocketClassCmdsOnSpawnKill[index];
	DataPack cmdOnExplode   = RocketClassCmdsOnExplode[index];
	DataPack cmdOnDeflect   = RocketClassCmdsOnDeflect[index];
	DataPack cmdOnNoTarget  = RocketClassCmdsOnNoTarget[index];

	if (cmdOnSpawn     != null) delete cmdOnSpawn;
	if (cmdOnKill      != null) delete cmdOnKill;
	if (cmdOnSpawnKill != null) delete cmdOnSpawnKill;
	if (cmdOnExplode   != null) delete cmdOnExplode;
	if (cmdOnDeflect   != null) delete cmdOnDeflect;
	if (cmdOnNoTarget  != null) delete cmdOnNoTarget;

	RocketClassName[index][0]       = '\0';
	RocketClassLongName[index][0]   = '\0';
	RocketClassModel[index][0]      = '\0';
	RocketClassSpawnSound[index][0] = '\0';
	RocketClassBeepSound[index][0]  = '\0';
	RocketClassAlertSound[index][0] = '\0';

	RocketClassBehaviour[index]         = Behaviour_Unknown;
	RocketClassFlags[index]             = RocketFlag_None;
	RocketClassBeepInterval[index]      = 0.0;
	RocketClassCritChance[index]        = 0.0;
	RocketClassDamage[index]            = 0.0;
	RocketClassDamageIncrement[index]   = 0.0;
	RocketClassSpeed[index]             = 0.0;
	RocketClassSpeedIncrement[index]    = 0.0;
	RocketClassConfiguredSpeedIncrement[index] = 0.0;
	RocketClassSpeedLimit[index]        = 0.0;
	RocketClassTurnRate[index]          = 0.0;
	RocketClassTurnRateIncrement[index] = 0.0;
	RocketClassTurnRateLimit[index]     = 0.0;
	RocketClassElevationRate[index]     = 0.0;
	RocketClassElevationLimit[index]    = 0.0;
	RocketClassRocketsModifier[index]   = 0.0;
	RocketClassPlayerModifier[index]    = 0.0;
	RocketClassControlDelay[index]      = 0.0;
	RocketClassTargetWeight[index]      = 0.0;
	RocketClassMaxBounces[index]        = 0;
	RocketClassBounceCeiling[index]     = 0.0;
	RocketClassCritGlowStack[index]     = 1;
	RocketClassCritGlowParticleRed[index][0]     = '\0';  // empty = use default "critical_rocket_red"
	RocketClassCritGlowParticleBlue[index][0]    = '\0';  // empty = use default "critical_rocket_blue"
	RocketClassCritGlowParticleNeutral[index][0] = '\0';  // empty = use default "eyeboss_projectile"
	RocketClassThinkInterval[index]     = 0.0;

	RocketClassCmdsOnSpawn[index]     = null;
	RocketClassCmdsOnKill[index]      = null;
	RocketClassCmdsOnSpawnKill[index] = null;
	RocketClassCmdsOnExplode[index]   = null;
	RocketClassCmdsOnDeflect[index]   = null;
	RocketClassCmdsOnNoTarget[index]  = null;
}

int FindRocketClassByName(const char[] name)
{
	char key[16];
	strcopy(key, sizeof(key), name);

	for (int index = 0; index < RocketClassCount; index++)
	{
		if (StrEqual(RocketClassName[index], key, false)) return index;
	}

	return -1;
}

/** Clears all spawner class definitions and spawn point data. */
void DestroySpawners()
{
	for (int index = 0; index < SpawnersCount; index++)
	{
		ResetSpawner(index);
	}

	SpawnersCount  = 0;
	SpawnPointsRedCount = 0;
	SpawnPointsBluCount = 0;
	DefaultRedSpawner = -1;
	DefaultBluSpawner = -1;
	SpawnersTrie.Clear();
}

void ResetSpawner(int index)
{
	if (SpawnersChancesTable[index] != null) delete SpawnersChancesTable[index];
	SpawnersChancesTable[index] = null;
	SpawnersName[index][0] = '\0';
	SpawnersMaxRockets[index] = 0;
	SpawnersInterval[index] = 0.0;
}

/**
 * Scans the map for info_target entities and populates spawn point arrays.
 * Looks for entities named "rocket_spawn_red", "tf_dodgeball_red",
 * "rocket_spawn_blu", or "tf_dodgeball_blu".
 * Calls SetFailState if no spawn points are found.
 */
void PopulateSpawnPoints()
{
	SpawnPointsRedCount = 0;
	SpawnPointsBluCount = 0;
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "info_target")) != -1)
	{
		char name[32]; GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
		if ((StrContains(name, "rocket_spawn_red") != -1) || (StrContains(name, "tf_dodgeball_red") != -1))
		{
			if (SpawnPointsRedCount >= MAX_SPAWN_POINTS)
			{
				LogError("Reached maximum RED spawn points (%d). Remaining points will be ignored.", MAX_SPAWN_POINTS);
				continue;
			}

			int index = FindSpawnerByName(name);
			if (index == -1) index = DefaultRedSpawner;
			SpawnPointsRedClass [SpawnPointsRedCount] = index;
			SpawnPointsRedEntity[SpawnPointsRedCount] = entity;
			SpawnPointsRedCount++;
		}

		if ((StrContains(name, "rocket_spawn_blu") != -1) || (StrContains(name, "tf_dodgeball_blu") != -1))
		{
			if (SpawnPointsBluCount >= MAX_SPAWN_POINTS)
			{
				LogError("Reached maximum BLU spawn points (%d). Remaining points will be ignored.", MAX_SPAWN_POINTS);
				continue;
			}

			int index = FindSpawnerByName(name);
			if (index == -1) index = DefaultBluSpawner;

			SpawnPointsBluClass [SpawnPointsBluCount] = index;
			SpawnPointsBluEntity[SpawnPointsBluCount] = entity;
			SpawnPointsBluCount++;
		}
	}

	// Spawn-point failures are NON-FATAL: admins can load non-TFDB maps with
	// tf_dodgeball_enabled=1 without taking down the entire plugin. Rockets
	// just won't spawn (downstream code already guards on zero counts).
	// LogMessage (not LogError) — plugin may run on non-dodgeball maps where
	// missing TFDB spawn entities is an expected condition, not a configuration
	// error. LogError would trigger false alarms in monitoring dashboards.
	if (SpawnPointsRedCount == 0 && SpawnPointsBluCount == 0)
	{
		LogMessage("[TFDB] No 'info_target' entities found on this map — rocket spawning disabled for this map.");
		return;
	}

	if (SpawnPointsRedCount == 0) LogMessage("[TFDB] No RED spawn points found on this map — rockets won't spawn for RED.");
	if (SpawnPointsBluCount == 0) LogMessage("[TFDB] No BLU spawn points found on this map — rockets won't spawn for BLU.");
}

/**
 * Finds a spawner class index by name using the spawners trie.
 *
 * @param name   The spawner name to search for.
 * @return       The spawner class index, or -1 if not found.
 */
int FindSpawnerByName(const char[] name)
{
	int index = -1;
	SpawnersTrie.GetValue(name, index);
	return index;
}

/** Registers server commands for explosion and shockwave effects. */
void RegisterCommands()
{
	RegServerCmd("tf_dodgeball_explosion", CmdExplosion);
	RegServerCmd("tf_dodgeball_shockwave", CmdShockwave);
	RegConsoleCmd("sm_ab", CmdTogglePushPrevention, "Toggle airblast push prevention.");
	RegAdminCmd("sm_tfdb_profile", Cmd_TFDBProfile, ADMFLAG_ROOT, "Profile core hot paths for 1-30 seconds (default 15).");
}

/**
 * Server command: Creates nuke particle effects at a client's position.
 * Usage: tf_dodgeball_explosion <client>
 *
 * @param args   Number of command arguments.
 * @return       Plugin_Handled after processing.
 */
public Action CmdExplosion(int args)
{
	if (!Enabled)
	{
		CPrintToServer("%t", "Command_Disabled");
		return Plugin_Handled;
	}

	if (args != 1)
	{
		CPrintToServer("%t", "Command_DBShockwave_Usage");
		return Plugin_Handled;
	}

	char buffer[8];
	int client;
	GetCmdArg(1, buffer, sizeof(buffer));
	client = StringToInt(buffer);

	if (!IsValidClient(client)) return Plugin_Handled;

	float position[3];
	GetClientAbsOrigin(client, position);
	switch (GetURandomIntRange(0, 4))
	{
		case 0: PlayParticle(position, PARTICLE_NUKE_1_ANGLES, PARTICLE_NUKE_1);
		case 1: PlayParticle(position, PARTICLE_NUKE_2_ANGLES, PARTICLE_NUKE_2);
		case 2: PlayParticle(position, PARTICLE_NUKE_3_ANGLES, PARTICLE_NUKE_3);
		case 3: PlayParticle(position, PARTICLE_NUKE_4_ANGLES, PARTICLE_NUKE_4);
		case 4: PlayParticle(position, PARTICLE_NUKE_5_ANGLES, PARTICLE_NUKE_5);
	}
	PlayParticle(position, PARTICLE_NUKE_COLLUMN_ANGLES, PARTICLE_NUKE_COLLUMN);

	return Plugin_Handled;
}

/**
 * Server command: Creates a shockwave that damages and pushes players.
 * Usage: tf_dodgeball_shockwave <client> <damage> <push_strength> <radius> <falloff_radius>
 *
 * @param args   Number of command arguments.
 * @return       Plugin_Handled after processing.
 */
public Action CmdShockwave(int args)
{
	if (!Enabled)
	{
		CPrintToServer("%t", "Command_Disabled");
		return Plugin_Handled;
	}

	if (args != 5)
	{
		CPrintToServer("%t", "Command_DBShockwave_Usage");
		return Plugin_Handled;
	}

	char buffer[32];
	int client, team;
	float position[3];
	int damage;
	float pushStrength, radius, falloffRadius;
	
	GetCmdArg(1, buffer, sizeof(buffer)); client       = StringToInt(buffer);
	GetCmdArg(2, buffer, sizeof(buffer)); damage       = StringToInt(buffer);
	GetCmdArg(3, buffer, sizeof(buffer)); pushStrength = StringToFloat(buffer);
	GetCmdArg(4, buffer, sizeof(buffer)); radius       = StringToFloat(buffer);
	GetCmdArg(5, buffer, sizeof(buffer)); falloffRadius = StringToFloat(buffer);

	if (!IsValidClient(client)) return Plugin_Handled;
	
	team = GetClientTeam(client);
	GetClientAbsOrigin(client, position);

	for (client = 1; client <= MaxClients; client++)
	{
		if (!(IsValidClientEx(client, true) && (GetClientTeam(client) == team))) continue;
		
		float playerPosition[3];
		GetClientEyePosition(client, playerPosition);
		float distanceToShockwave = GetVectorDistance(position, playerPosition);

		if (!(distanceToShockwave < radius)) continue;

		float impulse[3];
		float finalPush;
		int finalDamage;
		impulse[0] = playerPosition[0] - position[0];
		impulse[1] = playerPosition[1] - position[1];
		impulse[2] = playerPosition[2] - position[2];
		NormalizeVector(impulse, impulse);
		
		if (impulse[2] < 0.4) { impulse[2] = 0.4; NormalizeVector(impulse, impulse); }

		if (distanceToShockwave < falloffRadius)
		{
			finalPush = pushStrength;
			finalDamage = damage;
		}
		else if (radius <= falloffRadius)
		{
			finalPush = pushStrength;
			finalDamage = RoundToFloor(float(damage));
		}
		else
		{
			float impact = (1.0 - ((distanceToShockwave - falloffRadius) / (radius - falloffRadius)));
			finalPush   = impact * pushStrength;
			finalDamage = RoundToFloor(impact * damage);
		}

		ScaleVector(impulse, finalPush);
		SlapPlayer(client, finalDamage, true);
		SetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", impulse);
	}

	return Plugin_Handled;
}

/**
 * Executes stored commands from a DataPack, replacing placeholders with actual values.
 * Used for on-spawn, on-deflect, on-kill, on-explode, and on-no-target commands.
 *
 * Supported placeholders:
 *   @name        - Rocket class long name
 *   @rocket      - Rocket entity index
 *   @owner       - Owner client index
 *   @target      - Target client index
 *   @dead        - Last dead client index
 *   @deflections - Number of deflections
 *   @speed       - Current speed (Hammer units/s)
 *   @mphspeed    - Current speed (MPH, rounded)
 *   @capmphspeed - Capped MPH speed
 *   @nocapspeed  - Uncapped speed
 *   @2dspeed     - Speed with 2 decimal places
 *   @2dnocapspeed - Uncapped speed with 2 decimal places
 *
 * @param dataPack        DataPack containing commands to execute.
 * @param rocketClass     Rocket class index.
 * @param rocket          Rocket entity index.
 * @param owner           Owner client index.
 * @param target          Target client index.
 * @param lastDead        Last dead client index.
 * @param speed           Current rocket speed (Hammer units/s).
 * @param numDeflections  Number of deflections.
 * @param mphSpeed        Current rocket speed (MPH).
 */
void ExecuteCommands(DataPack dataPack, int rocketClass, int rocket, int owner, int target, int lastDead, float speed, int numDeflections, float mphSpeed)
{
	dataPack.Reset(false);
	int numCommands = dataPack.ReadCell();

	while (numCommands-- > 0)
	{
		char cmd[256], buffer[32];

		dataPack.ReadString(cmd, sizeof(cmd));
		ReplaceString(cmd, sizeof(cmd), "@name", RocketClassLongName[rocketClass]);
		FormatEx(buffer, sizeof(buffer), "%i", rocket);                           ReplaceString(cmd, sizeof(cmd), "@rocket", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", owner);                            ReplaceString(cmd, sizeof(cmd), "@owner", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", target);                           ReplaceString(cmd, sizeof(cmd), "@target", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", lastDead);                         ReplaceString(cmd, sizeof(cmd), "@dead", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", numDeflections);                   ReplaceString(cmd, sizeof(cmd), "@deflections", buffer);
		FormatEx(buffer, sizeof(buffer), "%f", speed);                            ReplaceString(cmd, sizeof(cmd), "@speed", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", RoundToNearest(mphSpeed));         ReplaceString(cmd, sizeof(cmd), "@mphspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", RoundToNearest(speed * HAMMER_TO_MPH)); ReplaceString(cmd, sizeof(cmd), "@capmphspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%f", mphSpeed / HAMMER_TO_MPH);              ReplaceString(cmd, sizeof(cmd), "@nocapspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%.2f", speed);                          ReplaceString(cmd, sizeof(cmd), "@2dspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%.2f", mphSpeed / HAMMER_TO_MPH);            ReplaceString(cmd, sizeof(cmd), "@2dnocapspeed", buffer);

		ServerCommand(cmd);
	}
}

/**
 * Parses a dodgeball configuration file (KeyValues format).
 * Loads general settings, rocket classes, and spawner classes.
 *
 * IMPORTANT: per-map cfgs (`tfdb_mapname.cfg`) ADD to and override the classes
 * loaded from `general.cfg` — they do NOT replace them. Wiping state here
 * between `general.cfg` and `mapname.cfg` parses would leave the server with
 * zero classes on maps whose cfg only overrides spawners or a subset.
 *
 * For a true fresh reload, call `DisableDodgeBall` / `EnableDodgeBall` which
 * handle cleanup explicitly (see `dodgeball_core.inc:DisableDodgeBall`).
 */
void ParseConfigurations(char[] configFile = "general.cfg")
{
	char path[PLATFORM_MAX_PATH];
	char fileName[PLATFORM_MAX_PATH];
	FormatEx(fileName, sizeof(fileName), "configs/dodgeball/%s", configFile);
	BuildPath(Path_SM, path, sizeof(path), fileName);
	LogMessage("Executing configuration file %s", path);

	if (!FileExists(path, true))
	{
		// Per-map cfgs are optional. general.cfg missing will be caught downstream
		// by "no rocket classes defined" — but we log a hint so admins aren't lost.
		LogMessage("[TFDB] Config file not found, skipping: %s", path);
		return;
	}

	KeyValues config = new KeyValues("TF2_Dodgeball");
	if (!config.ImportFromFile(path))
	{
		// Malformed cfg: log + skip instead of nuking the entire plugin. A broken
		// tfdb_mapname.cfg should NOT take down the plugin for the rest of the session.
		LogError("[TFDB] Error while parsing configuration file: %s (continuing with existing classes)", path);
		delete config;
		return;
	}

	if (!config.GotoFirstSubKey())
	{
		LogError("[TFDB] Config file has no top-level sections: %s", path);
		delete config;
		return;
	}
	do
	{
		char section[64]; config.GetSectionName(section, sizeof(section));
		if (StrEqual(section, "general"))       ParseGeneral(config);
		else if (StrEqual(section, "classes"))  ParseClasses(config);
		else if (StrEqual(section, "spawners")) ParseSpawners(config);
		else if (StrEqual(section, "presets"))  ParsePresets(config);
	}
	while (config.GotoNextKey());

	delete config;
	Forward_OnRocketsConfigExecuted(configFile);
}

/** Parses the "general" section of the config (music and scaling settings). */
void ParseGeneral(KeyValues config)
{
	// Scaling mode flags (read before music to avoid early return)
	UseSmoothElevation    = view_as<bool>(config.GetNum("smooth elevation", 0));

	// Consistent post-deflection steering window. HomingRocketThink samples the
	// deflector's eye angles exactly once after this many seconds. 0 selects the
	// authentic shared-grid path instead (a variable 0-DragGridInterval wait).
	DragDelay = config.GetFloat("drag delay", 0.045);
	if (DragDelay < 0.0)  DragDelay = 0.0;
	if (DragDelay > 0.15) DragDelay = 0.15;

	// Shared legacy grid interval, authored in milliseconds. Bounces always use
	// this grid; deflections use it only when "drag delay" is 0. Clamped to the
	// established 10-100ms range.
	int dragGridMs = config.GetNum("drag grid interval", 100);
	if (dragGridMs < 10)  dragGridMs = 10;
	if (dragGridMs > 100) dragGridMs = 100;
	DragGridInterval = float(dragGridMs) / 1000.0;

	MusicEnabled = view_as<bool>(config.GetNum("music", 0));

	// Built-in features (previously separate subplugins, now cfg-only)
	UsePushPrevention       = view_as<bool>(config.GetNum("push prevention", 1));
	UsePushPreventionToggle = view_as<bool>(config.GetNum("push prevention toggle", 1));
	UseNoBlock              = view_as<bool>(config.GetNum("noblock", 1));
	UseTargetLock           = view_as<bool>(config.GetNum("target lock", 0));
	UseTargetLockBotOnly    = view_as<bool>(config.GetNum("target lock bot only", 1));
	UnfreezeDuringSetup     = view_as<bool>(config.GetNum("disable round freeze", 0));

	// Engine-wide projectile speed cap. 0 leaves the server's current
	// sv_maxvelocity unchanged. Cache the resulting value so LimitRocketSpeed
	// clamps BEFORE writing entity velocity; engine-side clamping of a fast
	// parent otherwise emits SetLocalVelocity warnings for attached particles.
	float maxVel = config.GetFloat("max velocity", 0.0);
	ConVar maxVelCvar = FindConVar("sv_maxvelocity");
	if (maxVelCvar != null)
	{
		if (maxVel > 0.0) maxVelCvar.FloatValue = maxVel;
		EngineMaxVelocity = maxVelCvar.FloatValue;
	}
	else if (maxVel > 0.0)
	{
		EngineMaxVelocity = maxVel;
	}

	if (!MusicEnabled) return;

	UseWebPlayer = view_as<bool>(config.GetNum("use web player", 0));
	config.GetString("web player url", WebPlayerUrl, sizeof(WebPlayerUrl));
	Music[Music_RoundStart] = config.GetString("round start",      MusicPath[Music_RoundStart], PLATFORM_MAX_PATH) && MusicPath[Music_RoundStart][0];
	Music[Music_RoundWin]   = config.GetString("round end (win)",  MusicPath[Music_RoundWin],   PLATFORM_MAX_PATH) && MusicPath[Music_RoundWin][0];
	Music[Music_RoundLose]  = config.GetString("round end (lose)", MusicPath[Music_RoundLose],  PLATFORM_MAX_PATH) && MusicPath[Music_RoundLose][0];
	Music[Music_Gameplay]   = config.GetString("gameplay",         MusicPath[Music_Gameplay],   PLATFORM_MAX_PATH) && MusicPath[Music_Gameplay][0];
}

bool ClassKeyPresent(KeyValues config, const char[] key)
{
	return config.GetDataType(key) != KvData_None;
}

void SetRocketFlag(RocketFlags flag, bool enabled, RocketFlags &flags)
{
	if (enabled) flags |= flag;
	else flags &= ~flag;
}

void OverlayRocketFlag(KeyValues config, const char[] key, RocketFlags flag, RocketFlags &flags)
{
	if (ClassKeyPresent(config, key)) SetRocketFlag(flag, config.GetNum(key) != 0, flags);
}

void OverlayRocketString(KeyValues config, const char[] key, char[] value, int valueSize)
{
	if (ClassKeyPresent(config, key)) config.GetString(key, value, valueSize);
}

void OverlayRocketBehaviour(KeyValues config, int index)
{
	if (!ClassKeyPresent(config, "behaviour")) return;
	char value[32];
	config.GetString("behaviour", value, sizeof(value));
	if (StrEqual(value, "homing")) RocketClassBehaviour[index] = Behaviour_Homing;
	else if (StrEqual(value, "legacy homing")) RocketClassBehaviour[index] = Behaviour_LegacyHoming;
	else RocketClassBehaviour[index] = Behaviour_Unknown;
}

DataPack OverlayRocketCommands(KeyValues config, const char[] key, DataPack current, RocketFlags flag, RocketFlags &flags)
{
	if (!ClassKeyPresent(config, key)) return current;
	delete current;
	char value[256];
	config.GetString(key, value, sizeof(value));
	current = ParseCommands(value);
	SetRocketFlag(flag, current != null, flags);
	return current;
}

void InitializeNewRocketClass(int index)
{
	ResetRocketClass(index);
	RocketClassBehaviour[index] = Behaviour_Homing;
	RocketClassBeepInterval[index] = 0.5;
}

/** Parses the "classes" section of the config (rocket class definitions). */
void ParseClasses(KeyValues config)
{
	char name[64];
	if (!config.GotoFirstSubKey()) return;
	do
	{
		config.GetSectionName(name, sizeof(name));

		int index = FindRocketClassByName(name);
		bool newClass = (index == -1);
		if (newClass)
		{
			if (RocketClassCount >= MAX_ROCKET_CLASSES)
			{
				LogError("Reached maximum rocket classes (%d). Remaining classes will be ignored.", MAX_ROCKET_CLASSES);
				break;
			}

			index = RocketClassCount;
			InitializeNewRocketClass(index);
		}

		RocketFlags flags = RocketClassFlags[index];

		strcopy(RocketClassName[index], 16, name);
		OverlayRocketString(config, "name", RocketClassLongName[index], 32);
		OverlayRocketString(config, "model", RocketClassModel[index], PLATFORM_MAX_PATH);
		SetRocketFlag(RocketFlag_CustomModel, RocketClassModel[index][0] != '\0', flags);
		OverlayRocketFlag(config, "is animated", RocketFlag_IsAnimated, flags);
		if (RocketClassModel[index][0] == '\0') SetRocketFlag(RocketFlag_IsAnimated, false, flags);
		OverlayRocketBehaviour(config, index);

		OverlayRocketFlag(config, "play spawn sound", RocketFlag_PlaySpawnSound, flags);
		OverlayRocketString(config, "spawn sound", RocketClassSpawnSound[index], PLATFORM_MAX_PATH);
		SetRocketFlag(RocketFlag_CustomSpawnSound, RocketClassSpawnSound[index][0] != '\0', flags);

		OverlayRocketFlag(config, "play beep sound", RocketFlag_PlayBeepSound, flags);
		OverlayRocketString(config, "beep sound", RocketClassBeepSound[index], PLATFORM_MAX_PATH);
		SetRocketFlag(RocketFlag_CustomBeepSound, RocketClassBeepSound[index][0] != '\0', flags);

		OverlayRocketFlag(config, "play alert sound", RocketFlag_PlayAlertSound, flags);
		OverlayRocketString(config, "alert sound", RocketClassAlertSound[index], PLATFORM_MAX_PATH);
		SetRocketFlag(RocketFlag_CustomAlertSound, RocketClassAlertSound[index][0] != '\0', flags);

		OverlayRocketFlag(config, "elevate on deflect", RocketFlag_ElevateOnDeflect, flags);
		OverlayRocketFlag(config, "neutral rocket", RocketFlag_IsNeutral, flags);
		OverlayRocketFlag(config, "keep direction", RocketFlag_KeepDirection, flags);
		OverlayRocketFlag(config, "teamless deflects", RocketFlag_TeamlessHits, flags);
		OverlayRocketFlag(config, "reset bounces", RocketFlag_ResetBounces, flags);
		OverlayRocketFlag(config, "can be stolen", RocketFlag_CanBeStolen, flags);
		OverlayRocketFlag(config, "steal team check", RocketFlag_StealTeamCheck, flags);

		RocketClassBeepInterval[index]      = config.GetFloat("beep interval", RocketClassBeepInterval[index]);
		RocketClassDamage[index]            = config.GetFloat("damage", RocketClassDamage[index]);
		RocketClassDamageIncrement[index]   = config.GetFloat("damage increment", RocketClassDamageIncrement[index]);
		RocketClassCritChance[index]        = config.GetFloat("critical chance", RocketClassCritChance[index]);
		RocketClassSpeed[index]             = config.GetFloat("speed", RocketClassSpeed[index]);
		RocketClassConfiguredSpeedIncrement[index] = config.GetFloat("speed increment", RocketClassConfiguredSpeedIncrement[index]);
		RocketClassSpeedIncrement[index]    = RocketClassConfiguredSpeedIncrement[index];
		RocketClassSpeedLimit[index]        = config.GetFloat("speed limit", RocketClassSpeedLimit[index]);
		SetRocketFlag(RocketFlag_IsSpeedLimited, RocketClassSpeedLimit[index] != 0.0, flags);

		RocketClassTurnRate[index]          = config.GetFloat("turn rate", RocketClassTurnRate[index]);
		RocketClassTurnRateIncrement[index] = config.GetFloat("turn rate increment", RocketClassTurnRateIncrement[index]);
		RocketClassTurnRateLimit[index]     = config.GetFloat("turn rate limit", RocketClassTurnRateLimit[index]);
		SetRocketFlag(RocketFlag_IsTRLimited, RocketClassTurnRateLimit[index] != 0.0, flags);

		RocketClassElevationRate[index]     = config.GetFloat("elevation rate", RocketClassElevationRate[index]);
		RocketClassElevationLimit[index]    = config.GetFloat("elevation limit", RocketClassElevationLimit[index]);
		RocketClassControlDelay[index]      = config.GetFloat("control delay", RocketClassControlDelay[index]);
		RocketClassMaxBounces[index]        = config.GetNum("max bounces", RocketClassMaxBounces[index]);
		RocketClassBounceCeiling[index]     = config.GetFloat("bounce ceiling", RocketClassBounceCeiling[index]);
		if (RocketClassBounceCeiling[index] < 0.0) RocketClassBounceCeiling[index] = 0.0;
		RocketClassCritGlowStack[index]     = config.GetNum("crit glow stack", RocketClassCritGlowStack[index]);
		if (RocketClassCritGlowStack[index] < 1)              RocketClassCritGlowStack[index] = 1;
		if (RocketClassCritGlowStack[index] > MAX_CRIT_STACK) RocketClassCritGlowStack[index] = MAX_CRIT_STACK;

		// Per-class crit glow particle override per team. Empty string = use the
		// engine default for that team (red/blue/neutral; see UpdateCritGlow).
		// Particle name MUST exist in the ParticleEffectNames string table or it
		// renders nothing — use stock TF2 particle names.
		OverlayRocketString(config, "crit glow particle red", RocketClassCritGlowParticleRed[index], 32);
		OverlayRocketString(config, "crit glow particle blue", RocketClassCritGlowParticleBlue[index], 32);
		OverlayRocketString(config, "crit glow particle neutral", RocketClassCritGlowParticleNeutral[index], 32);
		RocketClassPlayerModifier[index]  = config.GetFloat("no. players modifier", RocketClassPlayerModifier[index]);
		RocketClassRocketsModifier[index] = config.GetFloat("no. rockets modifier", RocketClassRocketsModifier[index]);
		RocketClassTargetWeight[index]    = config.GetFloat("direction to target weight", RocketClassTargetWeight[index]);

		RocketClassThinkInterval[index] = config.GetFloat("think interval", RocketClassThinkInterval[index]);
		if (RocketClassThinkInterval[index] < 0.0) RocketClassThinkInterval[index] = 0.0;

		RocketClassCmdsOnSpawn[index] = OverlayRocketCommands(config, "on spawn", RocketClassCmdsOnSpawn[index], RocketFlag_OnSpawnCmd, flags);
		RocketClassCmdsOnDeflect[index] = OverlayRocketCommands(config, "on deflect", RocketClassCmdsOnDeflect[index], RocketFlag_OnDeflectCmd, flags);
		RocketClassCmdsOnKill[index] = OverlayRocketCommands(config, "on kill", RocketClassCmdsOnKill[index], RocketFlag_OnKillCmd, flags);
		RocketClassCmdsOnSpawnKill[index] = OverlayRocketCommands(config, "on spawn kill", RocketClassCmdsOnSpawnKill[index], RocketFlag_OnSpawnKillCmd, flags);
		RocketClassCmdsOnExplode[index] = OverlayRocketCommands(config, "on explode", RocketClassCmdsOnExplode[index], RocketFlag_OnExplodeCmd, flags);
		RocketClassCmdsOnNoTarget[index] = OverlayRocketCommands(config, "on no target", RocketClassCmdsOnNoTarget[index], RocketFlag_OnNoTargetCmd, flags);

		RocketClassFlags[index] = flags;
		if (newClass) RocketClassCount++;
	}
	while (config.GotoNextKey());
	config.GoBack();
}

/** Parses the "spawners" section of the config (spawner class definitions). */
void ParseSpawners(KeyValues config)
{
	char buffer[256];
	if (!config.GotoFirstSubKey()) return;
	do
	{
		config.GetSectionName(buffer, sizeof(buffer));

		int index = FindSpawnerByName(buffer);
		bool newSpawner = (index == -1);
		if (newSpawner)
		{
			if (SpawnersCount >= MAX_SPAWNER_CLASSES)
			{
				LogError("Reached maximum spawner classes (%d). Remaining spawners will be ignored.", MAX_SPAWNER_CLASSES);
				break;
			}

			index = SpawnersCount;
		}

		ResetSpawner(index);
		strcopy(SpawnersName[index], 32, buffer);
		SpawnersMaxRockets[index] = config.GetNum("max rockets", 1);
		SpawnersInterval[index]   = config.GetFloat("interval", 1.0);

		SpawnersChancesTable[index] = new ArrayList();
		for (int classIndex = 0; classIndex < RocketClassCount; classIndex++)
		{
			FormatEx(buffer, sizeof(buffer), "%s%%", RocketClassName[classIndex]);
			SpawnersChancesTable[index].Push(config.GetNum(buffer, 0));
		}

		SpawnersTrie.SetValue(SpawnersName[index], index);
		if (newSpawner) SpawnersCount++;
	}
	while (config.GotoNextKey());

	config.GoBack();
	SpawnersTrie.GetValue("red", DefaultRedSpawner);
	SpawnersTrie.GetValue("blu", DefaultBluSpawner);
}

/** Parses the "presets" section of the config (gameplay preset definitions).
 *  Resets PresetCount so mid-map config reload doesn't double-count.
 */
void ParsePresets(KeyValues config)
{
	PresetCount = 0;
	if (!config.GotoFirstSubKey()) return;
	do
	{
		int index = PresetCount;

		config.GetString("name", PresetName[index], sizeof(PresetName[]));
		config.GetString("rocket class", PresetRocketClass[index], sizeof(PresetRocketClass[]));
		PresetMaxRockets[index]    = config.GetNum("max rockets", 1);
		PresetSpawnInterval[index] = config.GetFloat("spawn interval", 0.0);

		PresetCount++;

		if (PresetCount >= MAX_PRESETS)
		{
			LogError("Reached maximum presets (%d). Remaining presets will be ignored.", MAX_PRESETS);
			break;
		}
	}
	while (config.GotoNextKey());
	config.GoBack();
}

/**
 * Parses a semicolon-separated command string into a DataPack.
 * Each command between semicolons becomes a separate entry.
 *
 * @param line   The command string to parse (e.g., "sm_slay @target; sm_beacon @owner").
 * @return       DataPack containing the commands, or null if empty.
 */
DataPack ParseCommands(char[] line)
{
    TrimString(line);
    if (!line[0]) return null;

    static char parts[32][256];
    int numParts = ExplodeString(line, ";", parts, sizeof(parts), sizeof(parts[]));
    int numCommands = 0;

    for (int i = 0; i < numParts; i++)
    {
        TrimString(parts[i]);
        if (parts[i][0]) numCommands++;
    }
    if (numCommands == 0) return null;

    DataPack dataPack = new DataPack();
    dataPack.WriteCell(numCommands);
    for (int i = 0; i < numParts; i++)
    {
        if (parts[i][0]) dataPack.WriteString(parts[i]);
    }
    return dataPack;
}
