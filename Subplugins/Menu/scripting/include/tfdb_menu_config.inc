// tfdb_menu_config.inc - Menu config parser - loads and caches rocket class settings for the admin menu.

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile)
{
	// This will cause problems if "general.cfg" is not executed first.
	if (strcmp(strConfigFile, "general.cfg") == 0)
	{
		// Destroy existing rockets so the refresh is clean - old-config
		// rockets would keep flying with their old speed/turn/model
		// while new rockets use the new config, which is confusing.
		Internal_DestroyRocketClasses();
		Internal_DestroySpawners();
		TFDB_DestroyRockets();
	}
	
	ParseConfigurations(strConfigFile);
}

void ParseConfigurations(const char[] strConfigFile)
{
	char strPath[PLATFORM_MAX_PATH];
	char strFileName[PLATFORM_MAX_PATH];
	FormatEx(strFileName, sizeof(strFileName), "configs/dodgeball/%s", strConfigFile);
	BuildPath(Path_SM, strPath, sizeof(strPath), strFileName);
	
	if (!FileExists(strPath, true)) return;
	
	KeyValues kvConfig = new KeyValues("TF2_Dodgeball");
	
	if (!kvConfig.ImportFromFile(strPath))
	{
		LogError("[TFDB Menu] Error while parsing configuration file: %s (continuing with defaults)", strPath);
		delete kvConfig;
		return;
	}

	if (!kvConfig.GotoFirstSubKey())
	{
		delete kvConfig;
		return;
	}
	
	do
	{
		char strSection[64]; kvConfig.GetSectionName(strSection, sizeof(strSection));
		
		if (StrEqual(strSection, "classes"))       ParseClasses(kvConfig);
		else if (StrEqual(strSection, "spawners")) ParseSpawners(kvConfig);
	}
	while (kvConfig.GotoNextKey());
	
	delete kvConfig;
}

void ParseClasses(KeyValues kvConfig)
{
	char strName[64];
	char buffer[256];
	
	if (!kvConfig.GotoFirstSubKey()) return;
	do
	{
		if (RocketClassCount >= MAX_ROCKET_CLASSES)
		{
			LogError("Reached maximum rocket classes (%d). Remaining classes will be ignored.", MAX_ROCKET_CLASSES);
			break;
		}
		int index = RocketClassCount;
		RocketFlags flags;
		TrailFlags iTrailFlags;
		
		kvConfig.GetSectionName(strName, sizeof(strName));        strcopy(SavedRocketClasses[index].Name, 16, strName);
		kvConfig.GetString("name", buffer, sizeof(buffer)); strcopy(SavedRocketClasses[index].LongName, 32, buffer);
		
		if (kvConfig.GetString("model", buffer, sizeof(buffer)))
		{
			strcopy(SavedRocketClasses[index].Model, PLATFORM_MAX_PATH, buffer);
			
			if (SavedRocketClasses[index].Model[0])
			{
				flags |= RocketFlag_CustomModel;
				
				if (kvConfig.GetNum("is animated", 0)) flags |= RocketFlag_IsAnimated;
			}
		}
		
		if (kvConfig.GetString("trail particle", buffer, sizeof(buffer)))
		{
			strcopy(SavedRocketClasses[index].Trail, sizeof(SavedRocketClasses[].Trail), buffer);
			
			if (SavedRocketClasses[index].Trail[0])
			{
				iTrailFlags |= TrailFlag_CustomTrail;
			}
		}
		
		if (kvConfig.GetString("trail sprite", buffer, sizeof(buffer)))
		{
			strcopy(SavedRocketClasses[index].Sprite, PLATFORM_MAX_PATH, buffer);
			
			if (SavedRocketClasses[index].Sprite[0])
			{
				iTrailFlags |= TrailFlag_CustomSprite;
				
				if (kvConfig.GetString("custom color", buffer, sizeof(buffer)))
				{
					strcopy(SavedRocketClasses[index].SpriteColor, sizeof(SavedRocketClasses[].SpriteColor), buffer);
				}
				
				SavedRocketClasses[index].SpriteLifetime   = kvConfig.GetFloat("sprite lifetime");
				SavedRocketClasses[index].SpriteStartWidth = kvConfig.GetFloat("sprite start width");
				SavedRocketClasses[index].SpriteEndWidth   = kvConfig.GetFloat("sprite end width");
			}
		}
		
		if (kvConfig.GetNum("remove particles", 0))
		{
			iTrailFlags |= TrailFlag_RemoveParticles;
			
			if (kvConfig.GetNum("replace particles", 0)) iTrailFlags |= TrailFlag_ReplaceParticles;
		}
		
		kvConfig.GetString("behaviour", buffer, sizeof(buffer), "homing");
		
		if (StrEqual(buffer, "homing"))
		{
			SavedRocketClasses[index].Behaviour = Behaviour_Homing;
		}
		else if (StrEqual(buffer, "legacy homing"))
		{
			SavedRocketClasses[index].Behaviour = Behaviour_LegacyHoming;
		}
		else
		{
			SavedRocketClasses[index].Behaviour = Behaviour_Unknown;
		}
		
		if (kvConfig.GetNum("play spawn sound", 0) == 1)
		{
			flags |= RocketFlag_PlaySpawnSound;
			
			if (kvConfig.GetString("spawn sound", SavedRocketClasses[index].SpawnSound, PLATFORM_MAX_PATH) && SavedRocketClasses[index].SpawnSound[0])
			{
				flags |= RocketFlag_CustomSpawnSound;
			}
		}
		
		if (kvConfig.GetNum("play beep sound", 0) == 1)
		{
			flags |= RocketFlag_PlayBeepSound;
			SavedRocketClasses[index].BeepInterval = kvConfig.GetFloat("beep interval", 0.5);
			
			if (kvConfig.GetString("beep sound", SavedRocketClasses[index].BeepSound, PLATFORM_MAX_PATH) && SavedRocketClasses[index].BeepSound[0])
			{
				flags |= RocketFlag_CustomBeepSound;
			}
		}
		
		if (kvConfig.GetNum("play alert sound", 0) == 1)
		{
			flags |= RocketFlag_PlayAlertSound;
			
			if (kvConfig.GetString("alert sound", SavedRocketClasses[index].AlertSound, PLATFORM_MAX_PATH) && SavedRocketClasses[index].AlertSound[0])
			{
				flags |= RocketFlag_CustomAlertSound;
			}
		}
		
		if (kvConfig.GetNum("elevate on deflect", 1) == 1) flags |= RocketFlag_ElevateOnDeflect;
		if (kvConfig.GetNum("neutral rocket", 0) == 1)     flags |= RocketFlag_IsNeutral;
		if (kvConfig.GetNum("keep direction", 0) == 1)     flags |= RocketFlag_KeepDirection;
		if (kvConfig.GetNum("teamless deflects", 0) == 1)  flags |= RocketFlag_TeamlessHits;
		if (kvConfig.GetNum("reset bounces", 0) == 1)      flags |= RocketFlag_ResetBounces;
		if (kvConfig.GetNum("can be stolen", 0) == 1)      flags |= RocketFlag_CanBeStolen;
		if (kvConfig.GetNum("steal team check", 0) == 1)   flags |= RocketFlag_StealTeamCheck;
		
		SavedRocketClasses[index].Damage            = kvConfig.GetFloat("damage");
		SavedRocketClasses[index].DamageIncrement   = kvConfig.GetFloat("damage increment");
		SavedRocketClasses[index].CritChance        = kvConfig.GetFloat("critical chance");
		SavedRocketClasses[index].Speed             = kvConfig.GetFloat("speed");
		SavedRocketClasses[index].SpeedIncrement    = kvConfig.GetFloat("speed increment");
		
		if ((SavedRocketClasses[index].SpeedLimit = kvConfig.GetFloat("speed limit")) != 0.0)
		{
			flags |= RocketFlag_IsSpeedLimited;
		}
		
		SavedRocketClasses[index].TurnRate          = kvConfig.GetFloat("turn rate");
		SavedRocketClasses[index].TurnRateIncrement = kvConfig.GetFloat("turn rate increment");
		
		if ((SavedRocketClasses[index].TurnRateLimit = kvConfig.GetFloat("turn rate limit")) != 0.0)
		{
			flags |= RocketFlag_IsTRLimited;
		}
		
		SavedRocketClasses[index].ElevationRate     = kvConfig.GetFloat("elevation rate");
		SavedRocketClasses[index].ElevationLimit    = kvConfig.GetFloat("elevation limit");
		SavedRocketClasses[index].ControlDelay        = kvConfig.GetFloat("control delay");
		SavedRocketClasses[index].ThinkInterval       = kvConfig.GetFloat("think interval", 0.0);
		SavedRocketClasses[index].BounceCeiling       = kvConfig.GetFloat("bounce ceiling", 0.0);
		SavedRocketClasses[index].CritGlowStack       = kvConfig.GetNum("crit glow stack", 1);
		if (SavedRocketClasses[index].CritGlowStack < 1)              SavedRocketClasses[index].CritGlowStack = 1;
		if (SavedRocketClasses[index].CritGlowStack > MAX_CRIT_STACK) SavedRocketClasses[index].CritGlowStack = MAX_CRIT_STACK;
		SavedRocketClasses[index].PlayerModifier    = kvConfig.GetFloat("no. players modifier");
		SavedRocketClasses[index].RocketsModifier   = kvConfig.GetFloat("no. rockets modifier");
		SavedRocketClasses[index].TargetWeight      = kvConfig.GetFloat("direction to target weight");
		SavedRocketClasses[index].MaxBounces        = kvConfig.GetNum("max bounces");
		
		DataPack cmds = null;
		
		kvConfig.GetString("on spawn", buffer, sizeof(buffer));
		if ((cmds = ParseCommands(buffer)) != null) { flags |= RocketFlag_OnSpawnCmd; SavedRocketClasses[index].CmdsOnSpawn = cmds; }
		
		kvConfig.GetString("on deflect", buffer, sizeof(buffer));
		if ((cmds = ParseCommands(buffer)) != null) { flags |= RocketFlag_OnDeflectCmd; SavedRocketClasses[index].CmdsOnDeflect = cmds; }
		
		kvConfig.GetString("on kill", buffer, sizeof(buffer));
		if ((cmds = ParseCommands(buffer)) != null) { flags |= RocketFlag_OnKillCmd; SavedRocketClasses[index].CmdsOnKill = cmds; }

		kvConfig.GetString("on spawn kill", buffer, sizeof(buffer));
		if ((cmds = ParseCommands(buffer)) != null) { flags |= RocketFlag_OnSpawnKillCmd; SavedRocketClasses[index].CmdsOnSpawnKill = cmds; }

		kvConfig.GetString("on explode", buffer, sizeof(buffer));
		if ((cmds = ParseCommands(buffer)) != null) { flags |= RocketFlag_OnExplodeCmd; SavedRocketClasses[index].CmdsOnExplode = cmds; }
		
		kvConfig.GetString("on no target", buffer, sizeof(buffer));
		if ((cmds = ParseCommands(buffer)) != null) { flags |= RocketFlag_OnNoTargetCmd; SavedRocketClasses[index].CmdsOnNoTarget = cmds; }
		
		SavedRocketClasses[index].Flags = flags;
		SavedRocketClasses[index].TFlags = iTrailFlags;
		RocketClassCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack(); 
}

void ParseSpawners(KeyValues kvConfig)
{
	char buffer[256];
	if (!kvConfig.GotoFirstSubKey()) return;
	
	do
	{
		if (SpawnersCount >= MAX_SPAWNER_CLASSES)
		{
			LogError("Reached maximum spawner classes (%d). Remaining spawners will be ignored.", MAX_SPAWNER_CLASSES);
			break;
		}
		int index = SpawnersCount;
		
		kvConfig.GetSectionName(buffer, sizeof(buffer)); strcopy(SavedSpawnerClasses[index].Name, 32, buffer);
		SavedSpawnerClasses[index].MaxRockets = kvConfig.GetNum("max rockets", 1);
		SavedSpawnerClasses[index].Interval   = kvConfig.GetFloat("interval", 1.0);
		
		SavedSpawnerClasses[index].ChancesTable = new ArrayList();
		
		for (int iClassIndex = 0; iClassIndex < RocketClassCount; iClassIndex++)
		{
			FormatEx(buffer, sizeof(buffer), "%s%%", SavedRocketClasses[iClassIndex].Name);
			SavedSpawnerClasses[index].ChancesTable.Push(kvConfig.GetNum(buffer, 0));
		}
		
		SpawnersCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack();
}

void EmitRocketSound(RocketSound iSound, int classIndex, int entity, int target, RocketFlags flags)
{
	switch (iSound)
	{
		case RocketSound_Spawn:
		{
			if (TestFlags(flags, RocketFlag_PlaySpawnSound))
			{
				if (TestFlags(flags, RocketFlag_CustomSpawnSound))
				{
					char strRocketClassSpawnSound[PLATFORM_MAX_PATH];
					TFDB_GetRocketClassSpawnSound(classIndex, strRocketClassSpawnSound, sizeof(strRocketClassSpawnSound));
					EmitSoundToAll(strRocketClassSpawnSound, entity);
				}
				else
				{
					EmitSoundToAll(SOUND_DEFAULT_SPAWN, entity);
				}
			}
		}
		case RocketSound_Beep:
		{
			if (TestFlags(flags, RocketFlag_PlayBeepSound))
			{
				if (TestFlags(flags, RocketFlag_CustomBeepSound))
				{
					char strRocketClassBeepSound [PLATFORM_MAX_PATH];
					TFDB_GetRocketClassBeepSound(classIndex, strRocketClassBeepSound, sizeof(strRocketClassBeepSound));
					EmitSoundToAll(strRocketClassBeepSound, entity);
				}
				else
				{
					EmitSoundToAll(SOUND_DEFAULT_BEEP, entity);
				}
			}
		}
		case RocketSound_Alert:
		{
			if (TestFlags(flags, RocketFlag_PlayAlertSound))
			{
				if (TestFlags(flags, RocketFlag_CustomAlertSound))
				{
					char strRocketClassAlertSound[PLATFORM_MAX_PATH];
					TFDB_GetRocketClassAlertSound(classIndex, strRocketClassAlertSound, sizeof(strRocketClassAlertSound));
					EmitSoundToClient(target, strRocketClassAlertSound);
				}
				else
				{
					EmitSoundToClient(target, SOUND_DEFAULT_ALERT, _, _, _, _, 0.5);
				}
			}
		}
	}
}
