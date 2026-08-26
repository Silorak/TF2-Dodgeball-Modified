// tfdb_menu_menus.inc - Menu UI - all admin menu handlers, class/spawner editing, preset management.

public Action CmdDodgeballMenu(int client, int args)
{
	// Menu must be displayed to a real human client (DisplayMenu(0,...) is undefined).
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		ReplyToCommand(client, "Command is in-game only.");

		return Plugin_Handled;
	}
	
	if (!CheckCommandAccess(client, "sm_tfdb", ADMFLAG_CONFIG))
	{
		CPrintToChat(client, "%t", "Command_NoAccess");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(client, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	DisplayDodgeballMenu(client);
	
	return Plugin_Handled;
}

void DisplayDodgeballMenu(int client)
{
	if (!TFDB_IsDodgeballEnabled())
	{
		CPrintToChat(client, "%t", "Dodgeball_Disabled");
		
		return;
	}
	
	Menu menu = new Menu(DodgeballMenuHandler);
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_WhatChange", client);
	menu.SetTitle(menuTitle);
	
	menu.AddItem("0", "Rockets", ITEMDRAW_DEFAULT);
	menu.AddItem("1", "Rocket classes", ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Spawner classes", ITEMDRAW_DEFAULT);
	menu.AddItem("3", "Refresh configuration file", ITEMDRAW_DEFAULT);
	menu.AddItem("4", "Destroy active rockets", ITEMDRAW_DEFAULT);
	menu.AddItem("5", "Apply preset", ITEMDRAW_DEFAULT);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int DodgeballMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			char strOption[8];
			menu.GetItem(iParam2, strOption, sizeof(strOption));
			
			int option = StringToInt(strOption);
			
			switch (option)
			{
				case 0 :
				{
					DisplayRocketsMenu(iParam1);
				}
				
				case 1 :
				{
					DisplayRocketClassesMenu(iParam1);
				}
				
				case 2 :
				{
					DisplaySpawnerClassesMenu(iParam1);
				}
				
				case 3 :
				{
					TFDB_DestroyRocketClasses();
					TFDB_DestroySpawners();
					
					char mapName[64]; GetCurrentMap(mapName, sizeof(mapName));
					GetMapDisplayName(mapName, mapName, sizeof(mapName));
					char strMapFile[PLATFORM_MAX_PATH]; FormatEx(strMapFile, sizeof(strMapFile), "%s.cfg", mapName);
					
					TFDB_ParseConfigurations();
					TFDB_ParseConfigurations("presets.cfg");
					TFDB_ParseConfigurations(strMapFile);
					TFDB_PopulateSpawnPoints();
					
					CPrintToChatAll("%t", "Command_DBRefresh_Done", iParam1);
					
					if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
					{
						DisplayDodgeballMenu(iParam1);
					}
				}
				
				case 4 :
				{
					TFDB_DestroyRockets();
					
					if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
					{
						DisplayDodgeballMenu(iParam1);
					}
				}

				case 5 :
				{
					DisplayPresetsMenu(iParam1);
				}
			}
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketsMenu(int client)
{
	if (TFDB_GetRocketCount() == 0)
	{
		CPrintToChat(client, "%t", "Menu_NoRockets");
		
		DisplayDodgeballMenu(client);
		
		return;
	}
	
	Menu menu = new Menu(RocketsMenuHandler);
	
	char strRocketIndex[8], strRocketLongName[48];
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_ActiveRockets", client);
	menu.SetTitle(menuTitle);
	menu.ExitBackButton = true;
	
	for (int index = 0; index < MAX_ROCKETS; index++)
	{
		if (!TFDB_IsValidRocket(index)) continue;
		
		IntToString(index, strRocketIndex, sizeof(strRocketIndex));
		TFDB_GetRocketClassLongName(TFDB_GetRocketClass(index), strRocketLongName, sizeof(strRocketLongName));
		Format(strRocketLongName, sizeof(strRocketLongName), "%s (Index : %s)", strRocketLongName, strRocketIndex);
		
		menu.AddItem(strRocketIndex, strRocketLongName, ITEMDRAW_DEFAULT);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketsMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			char indexStr[8];
			menu.GetItem(iParam2, indexStr, sizeof(indexStr));
			
			int index = StringToInt(indexStr);
			DisplayRocketOptionsMenu(iParam1, index);
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayDodgeballMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketOptionsMenu(int client, int index)
{
	if (!TFDB_IsValidRocket(index))
	{
		CPrintToChat(client, "%t", "Menu_InvalidRocket");
		
		DisplayRocketsMenu(client);
		
		return;
	}
	
	Menu menu = new Menu(RocketOptionsMenuHandler);
	
	char indexStr[8]; IntToString(index, indexStr, sizeof(indexStr));
	char title[48]; TFDB_GetRocketClassLongName(TFDB_GetRocketClass(index), title, sizeof(title));
	
	Format(title, sizeof(title), "%s (%s) options", title, indexStr);
	
	menu.SetTitle(title);
	// https://github.com/punteroo/TF2-Item-Plugins/blob/production/scripting/tf2item_cosmetics.sp#L591
	menu.AddItem(indexStr, "", ITEMDRAW_IGNORE);
	menu.ExitBackButton = true;
	
	menu.AddItem("1", "Target", ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Class", ITEMDRAW_DEFAULT);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketOptionsMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  index = StringToInt(buffer);
	
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			int option = StringToInt(buffer);
			
			switch (option)
			{
				case 1 :
				{
					DisplayRocketTargetMenu(iParam1, index);
				}
				
				case 2 :
				{
					DisplayRocketClassMenu(iParam1, index);
				}
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketsMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketTargetMenu(int client, int index)
{
	if (!TFDB_IsValidRocket(index))
	{
		CPrintToChat(client, "%t", "Menu_InvalidRocket");
		
		DisplayRocketsMenu(client);
		
		return;
	}
	
	Menu menu = new Menu(RocketTargetMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_DrawItem);
	
	char indexStr[8]; IntToString(index, indexStr, sizeof(indexStr));
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_NewRocketTarget", client);
	menu.SetTitle(menuTitle);
	menu.AddItem(indexStr, "", ITEMDRAW_IGNORE);
	menu.ExitBackButton = true;
	
	AddTargetsToMenu(menu, client, true, true);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketTargetMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  index  = StringToInt(buffer);
	int  entity = EntRefToEntIndex(TFDB_GetRocketEntity(index));
	
	switch (menuActions)
	{
		case MenuAction_DrawItem :
		{
			int iStyle;
			menu.GetItem(iParam2, buffer, sizeof(buffer), iStyle);
			
			int iUserID = StringToInt(buffer);
			int target = GetClientOfUserId(iUserID);
			
			return ((entity == -1) || (target == TFDB_GetRocketTarget(index)) ||
			       ((target == GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity")))) ? ITEMDRAW_DISABLED : iStyle;
		}
		
		case MenuAction_Select :
		{
			if (!TFDB_IsValidRocket(index))
			{
				CPrintToChat(iParam1, "%t", "Menu_InvalidRocket");
				
				DisplayRocketsMenu(iParam1);
				
				return 0;
			}
			
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			
			int iUserID = StringToInt(buffer);
			int target = GetClientOfUserId(iUserID);
			
			if (!target || !IsPlayerAlive(target))
			{
				CPrintToChat(iParam1, "%t", "Menu_InvalidClient");
			}
			else if (!CanUserTarget(iParam1, target) ||
			        (target == GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity")))
			{
				CPrintToChat(iParam1, "%t", "Menu_CannotTarget");
			}
			else if (target == TFDB_GetRocketTarget(index))
			{
				CPrintToChat(iParam1, "%t", "Menu_SameTarget");
			}
			else
			{
				TFDB_SetRocketTarget(index, target);
				
				int classIndex         = TFDB_GetRocketClass(index);
				RocketFlags flags = TFDB_GetRocketFlags(index);
				
				EmitRocketSound(RocketSound_Alert, classIndex, entity, target, flags);
				
				if (!(flags & RocketFlag_IsNeutral))
				{
					SetEntProp(entity, Prop_Send, "m_iTeamNum", GetAnalogueTeam(GetClientTeam(target)), 1);
				}
				
				LogAction(iParam1, target, "\"%L\" changed the target of a rocket to \"%L\"", iParam1, target);
				CPrintToChat(iParam1, "%t", "Menu_ChangedTarget", target);
			}
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketTargetMenu(iParam1, index);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketOptionsMenu(iParam1, index); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketClassMenu(int client, int index)
{
	if (!TFDB_IsValidRocket(index))
	{
		CPrintToChat(client, "%t", "Menu_InvalidRocket");
		
		DisplayRocketsMenu(client);
		
		return;
	}
	
	Menu menu = new Menu(RocketClassMenuHandler);
	
	
	char indexStr[8]; IntToString(index, indexStr, sizeof(indexStr));
	char rocketLongName[48];
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_NewRocketClass", client);
	menu.SetTitle(menuTitle);
	menu.AddItem(indexStr, "", ITEMDRAW_IGNORE);
	menu.ExitBackButton = true;
	
	for (int classIndex = 0; classIndex < TFDB_GetRocketClassCount(); classIndex++)
	{
		IntToString(classIndex, indexStr, sizeof(indexStr));
		TFDB_GetRocketClassLongName(classIndex, rocketLongName, sizeof(rocketLongName));
		Format(rocketLongName, sizeof(rocketLongName), "%s (Class : %s)", rocketLongName, indexStr);
		
		menu.AddItem(indexStr, rocketLongName, classIndex != TFDB_GetRocketClass(index) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketClassMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  index = StringToInt(buffer);
	
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			if (!TFDB_IsValidRocket(index))
			{
				CPrintToChat(iParam1, "%t", "Menu_InvalidRocket");
				
				DisplayRocketsMenu(iParam1);
				
				return 0;
			}
			
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			int classIndex = StringToInt(buffer);
			
			if (classIndex == TFDB_GetRocketClass(index))
			{
				CPrintToChat(iParam1, "%t", "Menu_SameRocketClass");
				
				DisplayRocketClassMenu(iParam1, index);
				
				return 0;
			}
			
			char strRocketOldLongName[32]; TFDB_GetRocketClassLongName(TFDB_GetRocketClass(index), strRocketOldLongName, sizeof(strRocketOldLongName));
			char rocketLongName[32]; TFDB_GetRocketClassLongName(classIndex, rocketLongName, sizeof(rocketLongName));
			
			RocketFlags flags         = TFDB_GetRocketFlags(index);
			RocketFlags iClassFlags    = TFDB_GetRocketClassFlags(TFDB_GetRocketClass(index));
			RocketFlags iNewClassFlags = TFDB_GetRocketClassFlags(classIndex);
			
			TFDB_SetRocketFlags(index, (flags & ~iClassFlags) | iNewClassFlags);
			
			TFDB_SetRocketClass(index, classIndex);
			
			LogAction(iParam1, -1, "\"%L\" changed the class of a rocket from \"%s\" to \"%s\"", iParam1, strRocketOldLongName, rocketLongName);
			CPrintToChat(iParam1, "%t", "Menu_ChangedRocketClass", strRocketOldLongName, rocketLongName);
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketClassMenu(iParam1, index);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketOptionsMenu(iParam1, index); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketClassesMenu(int client)
{
	Menu menu = new Menu(RocketClassesMenuHandler);
	
	char className[8], rocketLongName[48];
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_RocketClasses", client);
	menu.SetTitle(menuTitle);
	menu.ExitBackButton = true;
	
	for (int classIndex = 0; classIndex < TFDB_GetRocketClassCount(); classIndex++)
	{
		IntToString(classIndex, className, sizeof(className));
		TFDB_GetRocketClassLongName(classIndex, rocketLongName, sizeof(rocketLongName));
		Format(rocketLongName, sizeof(rocketLongName), "%s (Class : %s)", rocketLongName, className);
		
		menu.AddItem(className, rocketLongName, ITEMDRAW_DEFAULT);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketClassesMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			char className[8];
			menu.GetItem(iParam2, className, sizeof(className));
			
			int classIndex = StringToInt(className);
			DisplayRocketClassOptionsMenu(iParam1, classIndex);
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayDodgeballMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketClassOptionsMenu(int client, int classIndex)
{
	Menu menu = new Menu(RocketClassOptionsMenuHandler);
	
	char buffer[8]; IntToString(classIndex, buffer, sizeof(buffer));
	char title[48]; TFDB_GetRocketClassLongName(classIndex, title, sizeof(title));
	
	Format(title, sizeof(title), "%s (%s) options", title, buffer);
	
	menu.SetTitle(title);
	menu.AddItem(buffer, "", ITEMDRAW_IGNORE);
	menu.ExitBackButton = true;
	
	for (RocketClassMenu option = RocketClassMenu_Name; option < SizeOfRocketClassMenu; option++)
	{
		IntToString(view_as<int>(option), buffer, sizeof(buffer));
		
		if (!IsRocketClassMenuDisabled(option))
		{
			menu.AddItem(buffer, strRocketClassMenu[view_as<int>(option) - 1], ITEMDRAW_DEFAULT);
		}
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketClassOptionsMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  classIndex = StringToInt(buffer);
	
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			
			RocketClassMenu option = view_as<RocketClassMenu>(StringToInt(buffer));
			
			switch (option)
			{
				case RocketClassMenu_Behaviour :
				{
					DisplayRocketClassBehaviourMenu(iParam1, classIndex);
				}
				
				case RocketClassMenu_SpriteColor :
				{
					CPrintToChat(iParam1, "%t", "Menu_SpriteColor", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_SpriteLifetime :
				{
					CPrintToChat(iParam1, "%t", "Menu_SpriteLifetime", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_SpriteStartWidth :
				{
					CPrintToChat(iParam1, "%t", "Menu_SpriteStartWidth", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_SpriteEndWidth :
				{
					CPrintToChat(iParam1, "%t", "Menu_SpriteEndWidth", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_Flags :
				{
					DisplayRocketClassFlagsMenu(iParam1, classIndex);
				}
				
				case RocketClassMenu_BeepInterval :
				{
					CPrintToChat(iParam1, "%t", "Menu_BeepInterval", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_ResetBeepInterval");
				}
				
				case RocketClassMenu_CritChance :
				{
					CPrintToChat(iParam1, "%t", "Menu_CritChance", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_Damage :
				{
					CPrintToChat(iParam1, "%t", "Menu_Damage", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_DamageIncrement :
				{
					CPrintToChat(iParam1, "%t", "Menu_DamageIncrement", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_Speed :
				{
					CPrintToChat(iParam1, "%t", "Menu_Speed", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_SpeedIncrement :
				{
					CPrintToChat(iParam1, "%t", "Menu_SpeedIncrement", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_SpeedLimit :
				{
					CPrintToChat(iParam1, "%t", "Menu_SpeedLimit", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_ResetSpeedLimit");
				}
				
				case RocketClassMenu_TurnRate :
				{
					CPrintToChat(iParam1, "%t", "Menu_TurnRate", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_TurnRateIncrement :
				{
					CPrintToChat(iParam1, "%t", "Menu_TurnRateIncrement", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_TurnRateLimit :
				{
					CPrintToChat(iParam1, "%t", "Menu_TurnRateLimit", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_ResetTurnRateLimit");
				}
				
				case RocketClassMenu_ElevationRate :
				{
					CPrintToChat(iParam1, "%t", "Menu_ElevationRate", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_ElevationLimit :
				{
					CPrintToChat(iParam1, "%t", "Menu_ElevationLimit", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_RocketsModifier :
				{
					CPrintToChat(iParam1, "%t", "Menu_RocketsModifier", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_PlayerModifier :
				{
					CPrintToChat(iParam1, "%t", "Menu_PlayerModifier", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_ControlDelay :
				{
					CPrintToChat(iParam1, "%t", "Menu_ControlDelay", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_TargetWeight :
				{
					CPrintToChat(iParam1, "%t", "Menu_TargetWeight", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_MaxBounces :
				{
					CPrintToChat(iParam1, "%t", "Menu_MaxBounces", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_ThinkInterval :
				{
					CPrintToChat(iParam1, "%t", "Menu_ThinkInterval", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_BounceCeiling :
				{
					CPrintToChat(iParam1, "%t", "Menu_BounceCeiling", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_CritGlowStack :
				{
					CPrintToChat(iParam1, "%t", "Menu_CritGlowStack", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

			}
			
			ClientRocketClassMenu[iParam1]  = option;
			ClientSayHook[iParam1]          = true;
			ClientRocketClass[iParam1]      = classIndex;
			ClientMenuSelectTime[iParam1]   = GetGameTime();
			ClientSpawnerClassMenu[iParam1] = SpawnerClassMenu_None;
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1) && (option != RocketClassMenu_Flags && option != RocketClassMenu_Behaviour))
			{
				DisplayRocketClassOptionsMenu(iParam1, classIndex);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketClassesMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketClassBehaviourMenu(int client, int classIndex)
{
	Menu menu = new Menu(RocketClassBehaviourMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_DisplayItem);
	
	char buffer[8]; IntToString(classIndex, buffer, sizeof(buffer));
	char title[64]; TFDB_GetRocketClassLongName(classIndex, title, sizeof(title));
	
	Format(title, sizeof(title), "%s (%s) behaviour", title, buffer);
	
	menu.SetTitle(title);
	menu.AddItem(buffer, "", ITEMDRAW_IGNORE);
	menu.ExitBackButton = true;
	
	for (BehaviourTypes option = Behaviour_Unknown; option < Behaviour_LegacyHoming + view_as<BehaviourTypes>(1); option++)
	{
		IntToString(view_as<int>(option) + 1, buffer, sizeof(buffer));
		menu.AddItem(buffer, BehaviourToString(option), ITEMDRAW_DEFAULT);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketClassBehaviourMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  classIndex = StringToInt(buffer);
	
	switch (menuActions)
	{
		case MenuAction_DisplayItem :
		{
			char display[32];
			menu.GetItem(iParam2, buffer, sizeof(buffer), _, display, sizeof(display));
			
			BehaviourTypes option = view_as<BehaviourTypes>(StringToInt(buffer) - 1);
			
			Format(display, sizeof(display), TFDB_GetRocketClassBehaviour(classIndex) == option ? "[X] %s" : "[ ] %s", display);
			
			return RedrawMenuItem(display);
		}
		
		case MenuAction_Select :
		{
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			
			BehaviourTypes option = view_as<BehaviourTypes>(StringToInt(buffer) - 1);
			
			TFDB_SetRocketClassBehaviour(classIndex, option);
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketClassBehaviourMenu(iParam1, classIndex);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketClassOptionsMenu(iParam1, classIndex); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayRocketClassFlagsMenu(int client, int classIndex)
{
	Menu menu = new Menu(RocketClassFlagsMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_DisplayItem);
	
	char className[8]; IntToString(classIndex, className, sizeof(className));
	char title[64]; TFDB_GetRocketClassLongName(classIndex, title, sizeof(title));
	
	Format(title, sizeof(title), "%s (%s) behaviour modifiers", title, className);
	
	menu.SetTitle(title);
	menu.AddItem(className, "", ITEMDRAW_IGNORE);
	menu.ExitBackButton = true;
	
	menu.AddItem("1", "Elevate on deflect", ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Neutral rocket", ITEMDRAW_DEFAULT);
	menu.AddItem("3", "Keep direction", ITEMDRAW_DEFAULT);
	menu.AddItem("4", "Teamless deflects", ITEMDRAW_DEFAULT);
	menu.AddItem("5", "Reset bounces", ITEMDRAW_DEFAULT);
	menu.AddItem("6", "Can be stolen", ITEMDRAW_DEFAULT);
	menu.AddItem("7", "Steal team check", ITEMDRAW_DEFAULT);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketClassFlagsMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	// Flag table: index maps option number (1-based) to RocketFlags value.
	static const RocketFlags g_FlagMenuOptions[] =  {
		RocketFlag_None,           // 0 - unused (1-based option numbering)
		RocketFlag_ElevateOnDeflect,
		RocketFlag_IsNeutral,
		RocketFlag_KeepDirection,
		RocketFlag_TeamlessHits,
		RocketFlag_ResetBounces,
		RocketFlag_CanBeStolen,
		RocketFlag_StealTeamCheck
	};
	const int numFlags = sizeof(g_FlagMenuOptions) - 1; // exclude slot 0

	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  classIndex = StringToInt(buffer);

	switch (menuActions)
	{
		case MenuAction_DisplayItem :
		{
			char display[64];
			menu.GetItem(iParam2, buffer, sizeof(buffer), _, display, sizeof(display));

			int option = StringToInt(buffer);
			if (option >= 1 && option <= numFlags)
			{
				RocketFlags flags = TFDB_GetRocketClassFlags(classIndex);
				Format(display, sizeof(display), (flags & g_FlagMenuOptions[option]) ? "[X] %s" : "[ ] %s", display);
			}

			return RedrawMenuItem(display);
		}

		case MenuAction_Select :
		{
			menu.GetItem(iParam2, buffer, sizeof(buffer));

			int option = StringToInt(buffer);
			if (option >= 1 && option <= numFlags)
			{
				TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ g_FlagMenuOptions[option]);
			}

			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketClassFlagsMenu(iParam1, classIndex);
			}
		}

		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketClassOptionsMenu(iParam1, classIndex); }
		}

		case MenuAction_End :
		{
			delete menu;
		}
	}

	return 0;
}

void DisplaySpawnerClassesMenu(int client)
{
	Menu menu = new Menu(SpawnerClassesMenuHandler);
	
	char buffer[8];
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_SpawnersOptions", client);
	menu.SetTitle(menuTitle);
	menu.ExitBackButton = true;
	
	for (SpawnerClassMenu option = SpawnerClassMenu_MaxRockets; option < SizeOfSpawnerClassMenu; option++)
	{
		IntToString(view_as<int>(option), buffer, sizeof(buffer));
		
		menu.AddItem(buffer, strSpawnerClassMenu[view_as<int>(option) - 1], ITEMDRAW_DEFAULT);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int SpawnerClassesMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			
			SpawnerClassMenu option = view_as<SpawnerClassMenu>(StringToInt(buffer));
			
			switch (option)
			{
				case SpawnerClassMenu_MaxRockets :
				{
					CPrintToChat(iParam1, "%t", "Menu_MaxRockets", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
					
					ClientSayHook[iParam1]          = true;
					ClientMenuSelectTime[iParam1]   = GetGameTime();
					ClientSpawnerClassMenu[iParam1] = option;
				}
				
				case SpawnerClassMenu_Interval :
				{
					CPrintToChat(iParam1, "%t", "Menu_Interval", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
					
					ClientSayHook[iParam1]          = true;
					ClientMenuSelectTime[iParam1]   = GetGameTime();
					ClientSpawnerClassMenu[iParam1] = option;
				}
				
				case SpawnerClassMenu_ChancesTable :
				{
					DisplaySpawnerClassChancesMenu(iParam1);
				}
			}
			
			ClientRocketClassMenu[iParam1] = RocketClassMenu_None;
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1) && option != SpawnerClassMenu_ChancesTable)
			{
				DisplaySpawnerClassesMenu(iParam1);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayDodgeballMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplaySpawnerClassChancesMenu(int client)
{
	Menu menu = new Menu(SpawnerClassChancesMenuHandler);
	
	char className[8], rocketLongName[48];
	
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_SpawnChances", client);
	menu.SetTitle(menuTitle);
	menu.ExitBackButton = true;
	
	for (int classIndex = 0; classIndex < TFDB_GetRocketClassCount(); classIndex++)
	{
		IntToString(classIndex, className, sizeof(className));
		TFDB_GetRocketClassLongName(classIndex, rocketLongName, sizeof(rocketLongName));
		Format(rocketLongName, sizeof(rocketLongName), "%s (Class : %s)", rocketLongName, className);
		
		menu.AddItem(className, rocketLongName, ITEMDRAW_DEFAULT);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int SpawnerClassChancesMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			char className[8];
			menu.GetItem(iParam2, className, sizeof(className));
			
			int classIndex = StringToInt(className);
			
			ClientSayHook[iParam1]          = true;
			ClientMenuSelectTime[iParam1]   = GetGameTime();
			ClientSpawnerClassMenu[iParam1] = SpawnerClassMenu_ChancesTable;
			ClientRocketClass[iParam1]      = classIndex;
			
			CPrintToChat(iParam1, "%t", "Menu_ChancesTable", CvarSayHookTimeout.IntValue);
			CPrintToChat(iParam1, "%t", "Menu_Reset");
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplaySpawnerClassChancesMenu(iParam1);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplaySpawnerClassesMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayPresetsMenu(int client)
{
	int presetCount = TFDB_GetPresetCount();
	if (presetCount <= 0)
	{
		CPrintToChat(client, "[TFDB] No presets loaded.");
		DisplayDodgeballMenu(client);
		return;
	}

	Menu menu = new Menu(PresetsMenuHandler);
	char menuTitle[64]; FormatEx(menuTitle, sizeof(menuTitle), "%T", "Menu_Title_ApplyPreset", client);
	menu.SetTitle(menuTitle);
	menu.ExitBackButton = true;

	char presetIndex[8];
	char presetName[128];
	for (int i = 0; i < presetCount; i++)
	{
		IntToString(i, presetIndex, sizeof(presetIndex));
		TFDB_GetPresetName(i, presetName, sizeof(presetName));
		menu.AddItem(presetIndex, presetName, ITEMDRAW_DEFAULT);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int PresetsMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	switch (menuActions)
	{
		case MenuAction_Select :
		{
			char presetIndex[8];
			menu.GetItem(iParam2, presetIndex, sizeof(presetIndex));
			int preset = StringToInt(presetIndex);

			if (TFDB_ApplyPreset(preset))
			{
				char presetName[128];
				TFDB_GetPresetName(preset, presetName, sizeof(presetName));
				CPrintToChatAll("%t", "Menu_Admin_AppliedPreset", iParam1, presetName);
			}
			else
			{
				CPrintToChat(iParam1, "[TFDB] Failed to apply preset.");
			}

			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayPresetsMenu(iParam1);
			}
		}

		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayDodgeballMenu(iParam1); }
		}

		case MenuAction_End :
		{
			delete menu;
		}
	}

	return 0;
}

bool IsRocketClassMenuDisabled(RocketClassMenu option)
{
	return option == RocketClassMenu_Name           ||
	       option == RocketClassMenu_LongName       ||
	       option == RocketClassMenu_Model          ||
	       option == RocketClassMenu_Trail          ||
	       option == RocketClassMenu_Sprite         ||
	       option == RocketClassMenu_SpawnSound     ||
	       option == RocketClassMenu_BeepSound      ||
	       option == RocketClassMenu_AlertSound     ||
	       option == RocketClassMenu_CmdsOnSpawn    ||
	       option == RocketClassMenu_CmdsOnDeflect  ||
	       option == RocketClassMenu_CmdsOnKill     ||
	       option == RocketClassMenu_CmdsOnSpawnKill ||
	       option == RocketClassMenu_CmdsOnExplode  ||
	       option == RocketClassMenu_CmdsOnNoTarget ||
	       (!TrailsLoaded &&
	       (option == RocketClassMenu_SpriteColor    ||
	        option == RocketClassMenu_SpriteEndWidth ||
	        option == RocketClassMenu_SpriteLifetime ||
	        option == RocketClassMenu_SpriteStartWidth));
}

stock void HexToRGB(const char[] hex, int rgb[3])
{
	IntToRGB(StringToInt(hex, 16), rgb);
}

stock void IntToRGB(int iValue, int rgb[3])
{
	rgb[0] = ((iValue >> 16) & 0xFF);
	rgb[1] = ((iValue >>  8) & 0xFF);
	rgb[2] = ((iValue      ) & 0xFF);
}

stock void RGBToHex(const int rgb[3], char[] hex, int iSize)
{
	FormatEx(hex, iSize, "%06X", RGBToInt(rgb));
}

stock int RGBToInt(const int rgb[3])
{
	return ((rgb[0] & 0xFF) << 16) |
	       ((rgb[1] & 0xFF) <<  8) |
	       ((rgb[2] & 0xFF)      );
}
