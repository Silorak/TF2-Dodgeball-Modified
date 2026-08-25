// tfdb_menu_chat.inc — Chat command handlers for menu shortcuts (trail color, sprite settings).

void ClearPendingMenuInput(int client)
{
	ClientRocketClassMenu[client]  = RocketClassMenu_None;
	ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
	ClientRocketClass[client]      = -1;
	ClientMenuSelectTime[client]   = 0.0;
}

public Action OnClientSayCommand(int client, const char[] strCommand, const char[] args)
{
	if (!ClientSayHook[client]) return Plugin_Continue;
	
	ClientSayHook[client] = false;
	
	if ((GetGameTime() - ClientMenuSelectTime[client]) > CvarSayHookTimeout.FloatValue) return Plugin_Continue;
	
	if (!((strcmp(strCommand, "say") == 0) || (strcmp(strCommand, "say_team") == 0))) return Plugin_Continue;
	
	RocketClassMenu  iRocketClassOption  = ClientRocketClassMenu[client];
	SpawnerClassMenu iSpawnerClassOption = ClientSpawnerClassMenu[client];
	int rocketClass  = ClientRocketClass[client];
	if (rocketClass < 0 || rocketClass >= RocketClassCount || rocketClass >= TFDB_GetRocketClassCount())
	{
		ClearPendingMenuInput(client);
		CPrintToChat(client, "{olive}[TFDB]{default} That menu selection expired. Open the menu again.");
		return Plugin_Stop;
	}
	
	// Sprite options fail fast if Trails subplugin unloaded between menu display
	// and input submission. Natives are MarkNativeAsOptional so compile is fine,
	// but calling an unbound native throws a runtime error.
	if ((iRocketClassOption == RocketClassMenu_SpriteColor ||
	     iRocketClassOption == RocketClassMenu_SpriteLifetime ||
	     iRocketClassOption == RocketClassMenu_SpriteStartWidth ||
	     iRocketClassOption == RocketClassMenu_SpriteEndWidth) && !TrailsLoaded)
	{
		CPrintToChat(client, "{olive}[TFDB]{default} Trails plugin not loaded \u2014 sprite settings unavailable.");
		ClearPendingMenuInput(client);
		return Plugin_Stop;
	}

	switch (iRocketClassOption)
	{
		case RocketClassMenu_SpriteColor :
		{
			if ((strlen(args) == 6) && (StrContains(args, " ") == -1))
			{
				char color[16];
				int rgb[3]; HexToRGB(args, rgb);
				
				FormatEx(color, sizeof(color), "%i %i %i", rgb[0], rgb[1], rgb[2]);
				
				TFDB_SetRocketClassSpriteColor(rocketClass, color);
				
				LogAction(client, -1, "\"%L\" changed rocket class sprite trail color to #%s", client, args);
				CPrintToChat(client, "\x01%t\x01", "Menu_ChangedSpriteColor", "\x07", args, args);
			}
			else if (StringToInt(args) != -1)
			{
				char buffer[3][8];
				ExplodeString(args, " ", buffer, sizeof(buffer), sizeof(buffer[]));
				
				int rgb[3];
				rgb[0] = StringToInt(buffer[0]);
				rgb[1] = StringToInt(buffer[1]);
				rgb[2] = StringToInt(buffer[2]);
				
				char color[16]; RGBToHex(rgb, color, sizeof(color));
				
				TFDB_SetRocketClassSpriteColor(rocketClass, args);
				
				LogAction(client, -1, "\"%L\" changed rocket class sprite trail color to #%s", client, color);
				CPrintToChat(client, "\x01%t\x01", "Menu_ChangedSpriteColor", "\x07", color, color);
			}
			else
			{
				char buffer[3][8];
				ExplodeString(SavedRocketClasses[rocketClass].SpriteColor, " ", buffer, sizeof(buffer), sizeof(buffer[]));
				
				int rgb[3];
				rgb[0] = StringToInt(buffer[0]);
				rgb[1] = StringToInt(buffer[1]);
				rgb[2] = StringToInt(buffer[2]);
				
				char hex[16]; RGBToHex(rgb, hex, sizeof(hex));
				
				TFDB_SetRocketClassSpriteColor(rocketClass, SavedRocketClasses[rocketClass].SpriteColor);
				
				LogAction(client, -1, "\"%L\" reset rocket class sprite trail color to #%s", client, hex);
				CPrintToChat(client, "\x01%t\x01", "Menu_ResetSpriteColor", "\x07", hex, hex);
			}
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteLifetime :
		{
			float fLifetime = StringToFloat(args);
			
			TFDB_SetRocketClassSpriteLifetime(rocketClass, fLifetime == -1.0 ? SavedRocketClasses[rocketClass].SpriteLifetime : fLifetime);
			
			LogAction(client, -1, "\"%L\" changed rocket class sprite trail duration to %.2f", client, fLifetime);
			CPrintToChat(client, "%t", "Menu_ChangedSpriteLifetime", fLifetime);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteStartWidth :
		{
			float width = StringToFloat(args);
			
			TFDB_SetRocketClassSpriteStartWidth(rocketClass, width == -1.0 ? SavedRocketClasses[rocketClass].SpriteStartWidth : width);
			
			LogAction(client, -1, "\"%L\" changed rocket class sprite trail start width to %.2f", client, width);
			CPrintToChat(client, "%t", "Menu_ChangedSpriteStartWidth", width);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteEndWidth :
		{
			float width = StringToFloat(args);
			
			TFDB_SetRocketClassSpriteEndWidth(rocketClass, width == -1.0 ? SavedRocketClasses[rocketClass].SpriteEndWidth : width);
			
			LogAction(client, -1, "\"%L\" changed rocket class sprite trail end width to %.2f", client, width);
			CPrintToChat(client, "%t", "Menu_ChangedSpriteEndWidth", width);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_BeepInterval :
		{
			float interval = StringToFloat(args);
			
			if (interval == -1.0)
			{
				SavedRocketClasses[rocketClass].Flags & RocketFlag_PlayBeepSound ?
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) | RocketFlag_PlayBeepSound) :
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) & ~RocketFlag_PlayBeepSound);
				
				TFDB_SetRocketClassBeepInterval(rocketClass, SavedRocketClasses[rocketClass].BeepInterval);
			}
			else if (interval == 0.0)
			{
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) & ~RocketFlag_PlayBeepSound);
			}
			else
			{
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) | RocketFlag_PlayBeepSound);
				TFDB_SetRocketClassBeepInterval(rocketClass, interval);
			}
			
			LogAction(client, -1, "\"%L\" changed rocket class beep interval to %.2f", client, interval);
			CPrintToChat(client, "%t", "Menu_ChangedBeepInterval", interval);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_CritChance :
		{
			float fChance = StringToFloat(args);
			
			TFDB_SetRocketClassCritChance(rocketClass, fChance == -1.0 ? SavedRocketClasses[rocketClass].CritChance : fChance);
			
			LogAction(client, -1, "\"%L\" changed rocket class critical chance to %.2f", client, fChance);
			CPrintToChat(client, "%t", "Menu_ChangedCritChance", fChance);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_Damage :
		{
			float damage = StringToFloat(args);
			
			TFDB_SetRocketClassDamage(rocketClass, damage == -1.0 ? SavedRocketClasses[rocketClass].Damage : damage);
			
			LogAction(client, -1, "\"%L\" changed rocket class damage to %.2f", client, damage);
			CPrintToChat(client, "%t", "Menu_ChangedDamage", damage);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_DamageIncrement :
		{
			float damage = StringToFloat(args);
			
			TFDB_SetRocketClassDamageIncrement(rocketClass, damage == -1.0 ? SavedRocketClasses[rocketClass].DamageIncrement : damage);
			
			LogAction(client, -1, "\"%L\" changed rocket class damage increment to %.2f", client, damage);
			CPrintToChat(client, "%t", "Menu_ChangedDamageIncrement", damage);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_Speed :
		{
			float speed = StringToFloat(args);
			
			TFDB_SetRocketClassSpeed(rocketClass, speed == -1.0 ? SavedRocketClasses[rocketClass].Speed : speed);
			
			LogAction(client, -1, "\"%L\" changed rocket class speed to %.2f", client, speed);
			CPrintToChat(client, "%t", "Menu_ChangedSpeed", speed);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpeedIncrement :
		{
			float speed = StringToFloat(args);
			
			TFDB_SetRocketClassSpeedIncrement(rocketClass, speed == -1.0 ? SavedRocketClasses[rocketClass].SpeedIncrement : speed);
			
			LogAction(client, -1, "\"%L\" changed rocket class speed increment to %.2f", client, speed);
			CPrintToChat(client, "%t", "Menu_ChangedSpeedIncrement", speed);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpeedLimit :
		{
			float speed = StringToFloat(args);
			
			if (speed == -1.0)
			{
				SavedRocketClasses[rocketClass].Flags & RocketFlag_IsSpeedLimited ?
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) | RocketFlag_IsSpeedLimited) :
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) & ~RocketFlag_IsSpeedLimited);
				
				TFDB_SetRocketClassSpeedLimit(rocketClass, SavedRocketClasses[rocketClass].SpeedLimit);
			}
			else if (speed == 0.0)
			{
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) & ~RocketFlag_IsSpeedLimited);
			}
			else
			{
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) | RocketFlag_IsSpeedLimited);
				TFDB_SetRocketClassSpeedLimit(rocketClass, speed);
			}
			
			LogAction(client, -1, "\"%L\" changed rocket class speed limit to %.2f", client, speed);
			CPrintToChat(client, "%t", "Menu_ChangedSpeedLimit", speed);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRate :
		{
			float turnRate = StringToFloat(args);
			
			TFDB_SetRocketClassTurnRate(rocketClass, turnRate == -1.0 ? SavedRocketClasses[rocketClass].TurnRate : turnRate);
			
			LogAction(client, -1, "\"%L\" changed rocket class turn rate to %.2f", client, turnRate);
			CPrintToChat(client, "%t", "Menu_ChangedTurnRate", turnRate);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRateIncrement :
		{
			float turnRate = StringToFloat(args);
			
			TFDB_SetRocketClassTurnRateIncrement(rocketClass, turnRate == -1.0 ? SavedRocketClasses[rocketClass].TurnRateIncrement : turnRate);
			
			LogAction(client, -1, "\"%L\" changed rocket class turn rate increment to %.2f", client, turnRate);
			CPrintToChat(client, "%t", "Menu_ChangedTurnRateIncrement", turnRate);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRateLimit :
		{
			float turnRate = StringToFloat(args);
			
			if (turnRate == -1.0)
			{
				SavedRocketClasses[rocketClass].Flags & RocketFlag_IsTRLimited ?
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) | RocketFlag_IsTRLimited) :
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) & ~RocketFlag_IsTRLimited);
				
				TFDB_SetRocketClassTurnRateLimit(rocketClass, SavedRocketClasses[rocketClass].TurnRateLimit);
			}
			else if (turnRate == 0.0)
			{
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) & ~RocketFlag_IsTRLimited);
			}
			else
			{
				TFDB_SetRocketClassFlags(rocketClass, TFDB_GetRocketClassFlags(rocketClass) | RocketFlag_IsTRLimited);
				TFDB_SetRocketClassTurnRateLimit(rocketClass, turnRate);
			}
			
			LogAction(client, -1, "\"%L\" changed rocket class turn rate limit to %.2f", client, turnRate);
			CPrintToChat(client, "%t", "Menu_ChangedTurnRateLimit", turnRate);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ElevationRate :
		{
			float fElevation = StringToFloat(args);
			
			TFDB_SetRocketClassElevationRate(rocketClass, fElevation == -1.0 ? SavedRocketClasses[rocketClass].ElevationRate : fElevation);
			
			LogAction(client, -1, "\"%L\" changed rocket class elevation rate to %.2f", client, fElevation);
			CPrintToChat(client, "%t", "Menu_ChangedElevationRate", fElevation);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ElevationLimit :
		{
			float fElevation = StringToFloat(args);
			
			TFDB_SetRocketClassElevationLimit(rocketClass, fElevation == -1.0 ? SavedRocketClasses[rocketClass].ElevationLimit : fElevation);
			
			LogAction(client, -1, "\"%L\" changed rocket class elevation limit to %.2f", client, fElevation);
			CPrintToChat(client, "%t", "Menu_ChangedElevationLimit", fElevation);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_RocketsModifier :
		{
			float modifier = StringToFloat(args);
			
			TFDB_SetRocketClassRocketsModifier(rocketClass, modifier == -1.0 ? SavedRocketClasses[rocketClass].RocketsModifier : modifier);
			
			LogAction(client, -1, "\"%L\" changed rocket class fired rockets modifier to %.2f", client, modifier);
			CPrintToChat(client, "%t", "Menu_ChangedRocketsModifier", modifier);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_PlayerModifier :
		{
			float modifier = StringToFloat(args);
			
			TFDB_SetRocketClassPlayerModifier(rocketClass, modifier == -1.0 ? SavedRocketClasses[rocketClass].PlayerModifier : modifier);
			
			LogAction(client, -1, "\"%L\" changed rocket class player count modifier to %.2f", client, modifier);
			CPrintToChat(client, "%t", "Menu_ChangedPlayerModifier", modifier);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ControlDelay :
		{
			float fDelay = StringToFloat(args);
			
			TFDB_SetRocketClassControlDelay(rocketClass, fDelay == -1.0 ? SavedRocketClasses[rocketClass].ControlDelay : fDelay);
			
			LogAction(client, -1, "\"%L\" changed rocket class control delay to %.2f", client, fDelay);
			CPrintToChat(client, "%t", "Menu_ChangedControlDelay", fDelay);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TargetWeight :
		{
			float fWeight = StringToFloat(args);
			
			TFDB_SetRocketClassTargetWeight(rocketClass, fWeight == -1.0 ? SavedRocketClasses[rocketClass].TargetWeight : fWeight);
			
			LogAction(client, -1, "\"%L\" changed rocket class target weight to %.2f", client, fWeight);
			CPrintToChat(client, "%t", "Menu_ChangedTargetWeight", fWeight);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_MaxBounces :
		{
			int iBounces = StringToInt(args);
			
			TFDB_SetRocketClassMaxBounces(rocketClass, iBounces == -1 ? SavedRocketClasses[rocketClass].MaxBounces : iBounces);
			
			LogAction(client, -1, "\"%L\" changed rocket class maximum bounces to %i", client, iBounces);
			CPrintToChat(client, "%t", "Menu_ChangedMaxBounces", iBounces);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ThinkInterval :
		{
			// Native already takes seconds. 0 = per-tick, 0.05 = 20Hz, 0.1 = 10Hz.
			float fSec = StringToFloat(args);
			float useSec = (fSec < 0.0) ? SavedRocketClasses[rocketClass].ThinkInterval : fSec;

			TFDB_SetRocketClassThinkInterval(rocketClass, useSec);

			LogAction(client, -1, "\"%L\" changed rocket class think interval to %.3fs", client, useSec);
			CPrintToChat(client, "%t", "Menu_ChangedThinkInterval", useSec);

			ClearPendingMenuInput(client);
			return Plugin_Stop;
		}

		case RocketClassMenu_BounceCeiling :
		{
			// Ceiling in HU. 0 = disabled. Enter -1 to reset to cfg value.
			float fCeiling = StringToFloat(args);
			float useCeiling = (fCeiling < 0.0) ? SavedRocketClasses[rocketClass].BounceCeiling : fCeiling;

			TFDB_SetRocketClassBounceCeiling(rocketClass, useCeiling);

			LogAction(client, -1, "\"%L\" changed deprecated rocket vertical reshape to %.0f", client, useCeiling);
			CPrintToChat(client, "%t", "Menu_ChangedBounceCeiling", useCeiling);

			ClearPendingMenuInput(client);
			return Plugin_Stop;
		}

		case RocketClassMenu_CritGlowStack :
		{
			// Stack size 1..MAX_CRIT_STACK. Enter -1 to reset to cfg value.
			int iStack = StringToInt(args);
			int useStack = (iStack < 0) ? SavedRocketClasses[rocketClass].CritGlowStack : iStack;
			if (useStack < 1)              useStack = 1;
			if (useStack > MAX_CRIT_STACK) useStack = MAX_CRIT_STACK;

			TFDB_SetRocketClassCritGlowStack(rocketClass, useStack);

			LogAction(client, -1, "\"%L\" changed rocket class crit glow stack to %d", client, useStack);
			CPrintToChat(client, "%t", "Menu_ChangedCritGlowStack", useStack);

			ClearPendingMenuInput(client);
			return Plugin_Stop;
		}

	}
	
	switch (iSpawnerClassOption)
	{
		case SpawnerClassMenu_MaxRockets :
		{
			int iCount = StringToInt(args);
			
			for (int index = 0; index < TFDB_GetSpawnersCount(); index++)
			{
				TFDB_SetSpawnersMaxRockets(index, iCount == -1 ? SavedSpawnerClasses[index].MaxRockets : iCount);
			}
			
			LogAction(client, -1, "\"%L\" changed spawners maximum rockets to %i", client, iCount);
			CPrintToChat(client, "%t", "Menu_ChangedMaxRockets", iCount);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case SpawnerClassMenu_Interval :
		{
			float interval = StringToFloat(args);
			
			for (int index = 0; index < TFDB_GetSpawnersCount(); index++)
			{
				TFDB_SetSpawnersInterval(index, interval == -1.0 ? SavedSpawnerClasses[index].Interval : interval);
			}
			
			LogAction(client, -1, "\"%L\" changed spawners rocket spawn interval to %.2f", client, interval);
			CPrintToChat(client, "%t", "Menu_ChangedInterval", interval);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
		
		case SpawnerClassMenu_ChancesTable :
		{
			int iChances = StringToInt(args);
			
			for (int index = 0; index < TFDB_GetSpawnersCount(); index++)
			{
				ArrayList hTable = TFDB_GetSpawnersChancesTable(index);
				
				if (rocketClass < hTable.Length)
				{
					hTable.Set(rocketClass, iChances == -1 ? SavedSpawnerClasses[index].ChancesTable.Get(rocketClass) : iChances);
				}
				
				TFDB_SetSpawnersChancesTable(index, hTable);
				
				delete hTable;
			}
			
			LogAction(client, -1, "\"%L\" changed spawners rocket class chances to %i", client, iChances);
			CPrintToChat(client, "%t", "Menu_ChangedChancesTable", iChances);
			
			ClearPendingMenuInput(client);
			
			return Plugin_Stop;
		}
	}
	
	return Plugin_Continue;
}
