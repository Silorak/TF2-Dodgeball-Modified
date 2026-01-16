#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>
#include <adminmenu>
#include <multicolors>

#include <tfdb>

#undef REQUIRE_PLUGIN
#include <tfdbtrails>
#define REQUIRE_PLUGIN

#define PLUGIN_NAME        "[TFDB] Admin menu"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "A pretty big menu for dodgeball"
#define PLUGIN_VERSION     "1.0.4"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

enum RocketClassMenu
{
	RocketClassMenu_None = -1,
	RocketClassMenu_Name = 1,
	RocketClassMenu_LongName,
	RocketClassMenu_Behaviour,
	RocketClassMenu_Model,
	RocketClassMenu_Trail,
	RocketClassMenu_Sprite,
	RocketClassMenu_SpriteColor,
	RocketClassMenu_SpriteLifetime,
	RocketClassMenu_SpriteStartWidth,
	RocketClassMenu_SpriteEndWidth,
	RocketClassMenu_Flags,
	RocketClassMenu_BeepInterval,
	RocketClassMenu_SpawnSound,
	RocketClassMenu_BeepSound,
	RocketClassMenu_AlertSound,
	RocketClassMenu_CritChance,
	RocketClassMenu_Damage,
	RocketClassMenu_DamageIncrement,
	RocketClassMenu_Speed,
	RocketClassMenu_SpeedIncrement,
	RocketClassMenu_SpeedLimit,
	RocketClassMenu_TurnRate,
	RocketClassMenu_TurnRateIncrement,
	RocketClassMenu_TurnRateLimit,
	RocketClassMenu_ElevationRate,
	RocketClassMenu_ElevationLimit,
	RocketClassMenu_RocketsModifier,
	RocketClassMenu_PlayerModifier,
	RocketClassMenu_ControlDelay,
	RocketClassMenu_DragTimeMin,
	RocketClassMenu_DragTimeMax,
	RocketClassMenu_TargetWeight,
	RocketClassMenu_CmdsOnSpawn,
	RocketClassMenu_CmdsOnDeflect,
	RocketClassMenu_CmdsOnKill,
	RocketClassMenu_CmdsOnExplode,
	RocketClassMenu_CmdsOnNoTarget,
	RocketClassMenu_MaxBounces,
	RocketClassMenu_BounceScale,
	SizeOfRocketClassMenu
};

enum SpawnerClassMenu
{
	SpawnerClassMenu_None = -1,
	SpawnerClassMenu_Name = 1,
	SpawnerClassMenu_MaxRockets,
	SpawnerClassMenu_Interval,
	SpawnerClassMenu_ChancesTable,
	SizeOfSpawnerClassMenu
};

enum struct RocketClass
{
	char           Name        [16];
	char           LongName    [32];
	BehaviourTypes Behaviour;
	char           Model       [PLATFORM_MAX_PATH];
	char           Trail       [PLATFORM_MAX_PATH];
	char           Sprite      [PLATFORM_MAX_PATH];
	char           SpriteColor [16];
	float          SpriteLifetime;
	float          SpriteStartWidth;
	float          SpriteEndWidth;
	RocketFlags    Flags;
	TrailFlags     TFlags;
	float          BeepInterval;
	char           SpawnSound  [PLATFORM_MAX_PATH];
	char           BeepSound   [PLATFORM_MAX_PATH];
	char           AlertSound  [PLATFORM_MAX_PATH];
	float          CritChance;
	float          Damage;
	float          DamageIncrement;
	float          Speed;
	float          SpeedIncrement;
	float          SpeedLimit;
	float          TurnRate;
	float          TurnRateIncrement;
	float          TurnRateLimit;
	float          ElevationRate;
	float          ElevationLimit;
	float          RocketsModifier;
	float          PlayerModifier;
	float          ControlDelay;
	float          DragTimeMin;
	float          DragTimeMax;
	float          TargetWeight;
	DataPack       CmdsOnSpawn;
	DataPack       CmdsOnDeflect;
	DataPack       CmdsOnKill;
	DataPack       CmdsOnExplode;
	DataPack       CmdsOnNoTarget;
	int            MaxBounces;
	float          BounceScale;
	
	void Destroy()
	{
		delete this.CmdsOnSpawn;
		delete this.CmdsOnDeflect;
		delete this.CmdsOnKill;
		delete this.CmdsOnExplode;
		delete this.CmdsOnNoTarget;
	}
}

enum struct SpawnerClass
{
	char      Name[32];
	int       MaxRockets;
	float     Interval;
	ArrayList ChancesTable;
	
	void Destroy()
	{
		delete this.ChancesTable;
	}
}

int              g_iRocketClassCount;
int              g_iSpawnersCount;
bool             ClientSayHook         [MAXPLAYERS + 1];
RocketClassMenu  g_iClientRocketClassMenu [MAXPLAYERS + 1] = {RocketClassMenu_None, ...};
SpawnerClassMenu g_iClientSpawnerClassMenu[MAXPLAYERS + 1] = {SpawnerClassMenu_None, ...};
int              g_iClientRocketClass     [MAXPLAYERS + 1] = {-1, ...};
float            ClientMenuSelectTime  [MAXPLAYERS + 1];
RocketClass      g_eSavedRocketClasses    [MAX_ROCKET_CLASSES];
SpawnerClass     g_eSavedSpawnerClasses   [MAX_SPAWNER_CLASSES];
bool             TrailsLoaded;
ConVar           CvarSayHookTimeout;

char strRocketClassMenu[view_as<int>(SizeOfRocketClassMenu) - 1][] =
{
	"Name",
	"Long name",
	"Behaviour",
	"Model",
	"Trail",
	"Sprite",
	"Sprite color",
	"Sprite lifetime",
	"Sprite start width",
	"Sprite end width",
	"Behaviour modifiers",
	"Beep interval",
	"Spawn sound",
	"Beep sound",
	"Alert sound",
	"Crit chance",
	"Damage",
	"Damage increment",
	"Speed",
	"Speed increment",
	"Speed limit",
	"Turn rate",
	"Turn rate increment",
	"Turn rate limit",
	"Elevation rate",
	"Elevation limit",
	"Rockets modifier",
	"Player modifier",
	"Control delay",
	"Drag time minimum (start)",
	"Drag time maximum (end)",
	"Target weight",
	"Spawn commands",
	"Deflect commands",
	"Kill commands",
	"Explode commands",
	"No target commands",
	"Maximum bounces",
	"Bounce scale"
};

char strSpawnerClassMenu[view_as<int>(SizeOfSpawnerClassMenu) - 1][] =
{
	"Name",
	"Maximum rockets",
	"Rocket spawn interval",
	"Rocket class spawn chances"
};

public Plugin myinfo =
{
	name        = PLUGIN_NAME,
	author      = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = PLUGIN_URL
};

public void OnPluginStart()
{
	LoadTranslations("tfdb.phrases.txt");
	
	RegAdminCmd("sm_tfdb", CmdDodgeballMenu, ADMFLAG_CONFIG, "Dodgeball admin menu.");
	
	CvarSayHookTimeout = CreateConVar("tf_dodgeball_sayhook_timeout", "15.0", "Chat hook time span", _, true, 0.0);
	
	if (!TFDB_IsDodgeballEnabled()) return;
	
	char strMapName[64]; GetCurrentMap(strMapName, sizeof(strMapName));
	char strMapFile[PLATFORM_MAX_PATH]; FormatEx(strMapFile, sizeof(strMapFile), "%s.cfg", strMapName);
	
	TFDB_OnRocketsConfigExecuted("general.cfg");
	TFDB_OnRocketsConfigExecuted(strMapFile);
}

public void OnLibraryAdded(const char[] strName)
{
	if (strcmp(strName, "tfdbtrails") == 0) TrailsLoaded = true;
}

public void OnLibraryRemoved(const char[] strName)
{
	if (strcmp(strName, "tfdbtrails") == 0) TrailsLoaded = false;
}

public void OnMapEnd()
{
	Internal_DestroyRocketClasses();
	Internal_DestroySpawners();
}

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile)
{
	// This will cause problems if "general.cfg" is not executed first.
	if (strcmp(strConfigFile, "general.cfg") == 0)
	{
		Internal_DestroyRocketClasses();
		Internal_DestroySpawners();
	}
	
	ParseConfigurations(strConfigFile);
}

public void OnClientDisconnect(int iClient)
{
	ClientSayHook[iClient]          = false;
	g_iClientRocketClass[iClient]      = -1;
	ClientMenuSelectTime[iClient]   = 0.0;
	g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
	g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
}

public void OnClientConnected(int iClient)
{
	ClientSayHook[iClient]          = false;
	g_iClientRocketClass[iClient]      = -1;
	ClientMenuSelectTime[iClient]   = 0.0;
	g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
	g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
}

public Action CmdDodgeballMenu(int iClient, int iArgs)
{
	if (iClient == 0)
	{
		ReplyToCommand(iClient, "Command is in-game only.");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	DisplayDodgeballMenu(iClient);
	
	return Plugin_Handled;
}

void DisplayDodgeballMenu(int iClient)
{
	if (!TFDB_IsDodgeballEnabled())
	{
		CPrintToChat(iClient, "%t", "Dodgeball_Disabled");
		
		return;
	}
	
	Menu hMenu = new Menu(DodgeballMenuHandler);
	
	hMenu.SetTitle("What would you like to change?");
	
	hMenu.AddItem("0", "Rockets", ITEMDRAW_DEFAULT);
	hMenu.AddItem("1", "Rocket classes", ITEMDRAW_DEFAULT);
	hMenu.AddItem("2", "Spawner classes", ITEMDRAW_DEFAULT);
	hMenu.AddItem("3", "Refresh configuration file", ITEMDRAW_DEFAULT);
	hMenu.AddItem("4", "Destroy active rockets", ITEMDRAW_DEFAULT);
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int DodgeballMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			char strOption[8];
			hMenu.GetItem(iParam2, strOption, sizeof(strOption));
			
			int iOption = StringToInt(strOption);
			
			switch (iOption)
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
					
					char strMapName[64]; GetCurrentMap(strMapName, sizeof(strMapName));
					char strMapFile[PLATFORM_MAX_PATH]; FormatEx(strMapFile, sizeof(strMapFile), "%s.cfg", strMapName);
					
					TFDB_ParseConfigurations();
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
			}
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketsMenu(int iClient)
{
	if (TFDB_GetRocketCount() == 0)
	{
		CPrintToChat(iClient, "%t", "Menu_NoRockets");
		
		DisplayDodgeballMenu(iClient);
		
		return;
	}
	
	Menu hMenu = new Menu(RocketsMenuHandler);
	
	char strRocketIndex[8], strRocketLongName[48];
	
	hMenu.SetTitle("Active rockets :");
	hMenu.ExitBackButton = true;
	
	for (int iIndex = 0; iIndex < MAX_ROCKETS; iIndex++)
	{
		if (!TFDB_IsValidRocket(iIndex)) continue;
		
		IntToString(iIndex, strRocketIndex, sizeof(strRocketIndex));
		TFDB_GetRocketClassLongName(TFDB_GetRocketClass(iIndex), strRocketLongName, sizeof(strRocketLongName));
		Format(strRocketLongName, sizeof(strRocketLongName), "%s (Index : %s)", strRocketLongName, strRocketIndex);
		
		hMenu.AddItem(strRocketIndex, strRocketLongName, ITEMDRAW_DEFAULT);
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketsMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			char strIndex[8];
			hMenu.GetItem(iParam2, strIndex, sizeof(strIndex));
			
			int iIndex = StringToInt(strIndex);
			DisplayRocketOptionsMenu(iParam1, iIndex);
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayDodgeballMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketOptionsMenu(int iClient, int iIndex)
{
	if (!TFDB_IsValidRocket(iIndex))
	{
		CPrintToChat(iClient, "%t", "Menu_InvalidRocket");
		
		DisplayRocketsMenu(iClient);
		
		return;
	}
	
	Menu hMenu = new Menu(RocketOptionsMenuHandler);
	
	char strIndex[8]; IntToString(iIndex, strIndex, sizeof(strIndex));
	char strTitle[48]; TFDB_GetRocketClassLongName(TFDB_GetRocketClass(iIndex), strTitle, sizeof(strTitle));
	
	Format(strTitle, sizeof(strTitle), "%s (%s) options", strTitle, strIndex);
	
	hMenu.SetTitle(strTitle);
	// https://github.com/punteroo/TF2-Item-Plugins/blob/production/scripting/tf2item_cosmetics.sp#L591
	hMenu.AddItem(strIndex, "", ITEMDRAW_IGNORE);
	hMenu.ExitBackButton = true;
	
	hMenu.AddItem("1", "Target", ITEMDRAW_DEFAULT);
	hMenu.AddItem("2", "Class", ITEMDRAW_DEFAULT);
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketOptionsMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	int  iIndex = StringToInt(strBuffer);
	
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			int iOption = StringToInt(strBuffer);
			
			switch (iOption)
			{
				case 1 :
				{
					DisplayRocketTargetMenu(iParam1, iIndex);
				}
				
				case 2 :
				{
					DisplayRocketClassMenu(iParam1, iIndex);
				}
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketsMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketTargetMenu(int iClient, int iIndex)
{
	if (!TFDB_IsValidRocket(iIndex))
	{
		CPrintToChat(iClient, "%t", "Menu_InvalidRocket");
		
		DisplayRocketsMenu(iClient);
		
		return;
	}
	
	Menu hMenu = new Menu(RocketTargetMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_DrawItem);
	
	char strIndex[8]; IntToString(iIndex, strIndex, sizeof(strIndex));
	
	hMenu.SetTitle("New rocket target :");
	hMenu.AddItem(strIndex, "", ITEMDRAW_IGNORE);
	hMenu.ExitBackButton = true;
	
	AddTargetsToMenu(hMenu, iClient, true, true);
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketTargetMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	int  iIndex  = StringToInt(strBuffer);
	int  iEntity = EntRefToEntIndex(TFDB_GetRocketEntity(iIndex));
	
	switch (iMenuActions)
	{
		case MenuAction_DrawItem :
		{
			int iStyle;
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer), iStyle);
			
			int iUserID = StringToInt(strBuffer);
			int iTarget = GetClientOfUserId(iUserID);
			
			return ((iEntity == -1) || (iTarget == EntRefToEntIndex(TFDB_GetRocketTarget(iIndex))) ||
			       ((iTarget == GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity")))) ? ITEMDRAW_DISABLED : iStyle;
		}
		
		case MenuAction_Select :
		{
			if (!TFDB_IsValidRocket(iIndex))
			{
				CPrintToChat(iParam1, "%t", "Menu_InvalidRocket");
				
				DisplayRocketsMenu(iParam1);
				
				return 0;
			}
			
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			
			int iUserID = StringToInt(strBuffer);
			int iTarget = GetClientOfUserId(iUserID);
			
			if (!iTarget || !IsPlayerAlive(iTarget))
			{
				CPrintToChat(iParam1, "%t", "Menu_InvalidClient");
			}
			else if (!CanUserTarget(iParam1, iTarget) ||
			        (iTarget == GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity")))
			{
				CPrintToChat(iParam1, "%t", "Menu_CannotTarget");
			}
			else if (iTarget == EntRefToEntIndex(TFDB_GetRocketTarget(iIndex)))
			{
				CPrintToChat(iParam1, "%t", "Menu_SameTarget");
			}
			else
			{
				TFDB_SetRocketTarget(iIndex, EntIndexToEntRef(iTarget));
				
				int iClass         = TFDB_GetRocketClass(iIndex);
				RocketFlags iFlags = TFDB_GetRocketFlags(iIndex);
				
				EmitRocketSound(RocketSound_Alert, iClass, iEntity, iTarget, iFlags);
				
				if (!(iFlags & RocketFlag_IsNeutral))
				{
					SetEntProp(iEntity, Prop_Send, "m_iTeamNum", GetAnalogueTeam(GetClientTeam(iTarget)), 1);
				}
				
				LogAction(iParam1, iTarget, "\"%L\" changed the target of a rocket to \"%L\"", iParam1, iTarget);
				CPrintToChat(iParam1, "%t", "Menu_ChangedTarget", iTarget);
			}
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketTargetMenu(iParam1, iIndex);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketOptionsMenu(iParam1, iIndex); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketClassMenu(int iClient, int iIndex)
{
	if (!TFDB_IsValidRocket(iIndex))
	{
		CPrintToChat(iClient, "%t", "Menu_InvalidRocket");
		
		DisplayRocketsMenu(iClient);
		
		return;
	}
	
	Menu hMenu = new Menu(RocketClassMenuHandler);
	
	
	char strIndex[8]; IntToString(iIndex, strIndex, sizeof(strIndex));
	char strRocketClassLongName[48];
	
	hMenu.SetTitle("New rocket class :");
	hMenu.AddItem(strIndex, "", ITEMDRAW_IGNORE);
	hMenu.ExitBackButton = true;
	
	for (int iClass = 0; iClass < TFDB_GetRocketClassCount(); iClass++)
	{
		IntToString(iClass, strIndex, sizeof(strIndex));
		TFDB_GetRocketClassLongName(iClass, strRocketClassLongName, sizeof(strRocketClassLongName));
		Format(strRocketClassLongName, sizeof(strRocketClassLongName), "%s (Class : %s)", strRocketClassLongName, strIndex);
		
		hMenu.AddItem(strIndex, strRocketClassLongName, iClass != TFDB_GetRocketClass(iIndex) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketClassMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	int  iIndex = StringToInt(strBuffer);
	
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			if (!TFDB_IsValidRocket(iIndex))
			{
				CPrintToChat(iParam1, "%t", "Menu_InvalidRocket");
				
				DisplayRocketsMenu(iParam1);
				
				return 0;
			}
			
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			int iClass = StringToInt(strBuffer);
			
			if (iClass == TFDB_GetRocketClass(iIndex))
			{
				CPrintToChat(iParam1, "%t", "Menu_SameRocketClass");
				
				DisplayRocketClassMenu(iParam1, iIndex);
				
				return 0;
			}
			
			char strRocketOldLongName[32]; TFDB_GetRocketClassLongName(TFDB_GetRocketClass(iIndex), strRocketOldLongName, sizeof(strRocketOldLongName));
			char strRocketClassLongName[32]; TFDB_GetRocketClassLongName(iClass, strRocketClassLongName, sizeof(strRocketClassLongName));
			
			RocketFlags iFlags         = TFDB_GetRocketFlags(iIndex);
			RocketFlags iClassFlags    = TFDB_GetRocketClassFlags(TFDB_GetRocketClass(iIndex));
			RocketFlags iNewClassFlags = TFDB_GetRocketClassFlags(iClass);
			
			TFDB_SetRocketFlags(iIndex, (iFlags & ~iClassFlags) | iNewClassFlags);
			
			TFDB_SetRocketClass(iIndex, iClass);
			
			LogAction(iParam1, -1, "\"%L\" changed the class of a rocket from \"%s\" to \"%s\"", iParam1, strRocketOldLongName, strRocketClassLongName);
			CPrintToChat(iParam1, "%t", "Menu_ChangedRocketClass", strRocketOldLongName, strRocketClassLongName);
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketClassMenu(iParam1, iIndex);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketOptionsMenu(iParam1, iIndex); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketClassesMenu(int iClient)
{
	Menu hMenu = new Menu(RocketClassesMenuHandler);
	
	char strClass[8], strRocketClassLongName[48];
	
	hMenu.SetTitle("Rocket classes :");
	hMenu.ExitBackButton = true;
	
	for (int iClass = 0; iClass < TFDB_GetRocketClassCount(); iClass++)
	{
		IntToString(iClass, strClass, sizeof(strClass));
		TFDB_GetRocketClassLongName(iClass, strRocketClassLongName, sizeof(strRocketClassLongName));
		Format(strRocketClassLongName, sizeof(strRocketClassLongName), "%s (Class : %s)", strRocketClassLongName, strClass);
		
		hMenu.AddItem(strClass, strRocketClassLongName, ITEMDRAW_DEFAULT);
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketClassesMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			char strClass[8];
			hMenu.GetItem(iParam2, strClass, sizeof(strClass));
			
			int iClass = StringToInt(strClass);
			DisplayRocketClassOptionsMenu(iParam1, iClass);
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayDodgeballMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketClassOptionsMenu(int iClient, int iClass)
{
	Menu hMenu = new Menu(RocketClassOptionsMenuHandler);
	
	char strBuffer[8]; IntToString(iClass, strBuffer, sizeof(strBuffer));
	char strTitle[48]; TFDB_GetRocketClassLongName(iClass, strTitle, sizeof(strTitle));
	
	Format(strTitle, sizeof(strTitle), "%s (%s) options", strTitle, strBuffer);
	
	hMenu.SetTitle(strTitle);
	hMenu.AddItem(strBuffer, "", ITEMDRAW_IGNORE);
	hMenu.ExitBackButton = true;
	
	for (RocketClassMenu iOption = RocketClassMenu_Name; iOption < SizeOfRocketClassMenu; iOption++)
	{
		IntToString(view_as<int>(iOption), strBuffer, sizeof(strBuffer));
		
		if (!IsRocketClassMenuDisabled(iOption))
		{
			hMenu.AddItem(strBuffer, strRocketClassMenu[view_as<int>(iOption) - 1], ITEMDRAW_DEFAULT);
		}
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketClassOptionsMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	int  iClass = StringToInt(strBuffer);
	
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			
			RocketClassMenu iOption = view_as<RocketClassMenu>(StringToInt(strBuffer));
			
			switch (iOption)
			{
				case RocketClassMenu_Behaviour :
				{
					DisplayRocketClassBehaviourMenu(iParam1, iClass);
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
					DisplayRocketClassFlagsMenu(iParam1, iClass);
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
				
				case RocketClassMenu_DragTimeMin :
				{
					CPrintToChat(iParam1, "%t", "Menu_DragTimeMin", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
				
				case RocketClassMenu_DragTimeMax :
				{
					CPrintToChat(iParam1, "%t", "Menu_DragTimeMax", CvarSayHookTimeout.IntValue);
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
				
				case RocketClassMenu_BounceScale :
				{
					CPrintToChat(iParam1, "%t", "Menu_BounceScale", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}
			}
			
			g_iClientRocketClassMenu[iParam1]  = iOption;
			ClientSayHook[iParam1]          = true;
			g_iClientRocketClass[iParam1]      = iClass;
			ClientMenuSelectTime[iParam1]   = GetGameTime();
			g_iClientSpawnerClassMenu[iParam1] = SpawnerClassMenu_None;
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1) && (iOption != RocketClassMenu_Flags && iOption != RocketClassMenu_Behaviour))
			{
				DisplayRocketClassOptionsMenu(iParam1, iClass);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketClassesMenu(iParam1); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketClassBehaviourMenu(int iClient, int iClass)
{
	Menu hMenu = new Menu(RocketClassBehaviourMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_DisplayItem);
	
	char strBuffer[8]; IntToString(iClass, strBuffer, sizeof(strBuffer));
	char strTitle[64]; TFDB_GetRocketClassLongName(iClass, strTitle, sizeof(strTitle));
	
	Format(strTitle, sizeof(strTitle), "%s (%s) behaviour", strTitle, strBuffer);
	
	hMenu.SetTitle(strTitle);
	hMenu.AddItem(strBuffer, "", ITEMDRAW_IGNORE);
	hMenu.ExitBackButton = true;
	
	for (BehaviourTypes iOption = Behaviour_Unknown; iOption < Behaviour_LegacyHoming + view_as<BehaviourTypes>(1); iOption++)
	{
		IntToString(view_as<int>(iOption) + 1, strBuffer, sizeof(strBuffer));
		hMenu.AddItem(strBuffer, BehaviourToString(iOption), ITEMDRAW_DEFAULT);
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketClassBehaviourMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	int  iClass = StringToInt(strBuffer);
	
	switch (iMenuActions)
	{
		case MenuAction_DisplayItem :
		{
			char strDisplay[32];
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer), _, strDisplay, sizeof(strDisplay));
			
			BehaviourTypes iOption = view_as<BehaviourTypes>(StringToInt(strBuffer) - 1);
			
			Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassBehaviour(iClass) == iOption ? "[X] %s" : "[ ] %s", strDisplay);
			
			return RedrawMenuItem(strDisplay);
		}
		
		case MenuAction_Select :
		{
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			
			BehaviourTypes iOption = view_as<BehaviourTypes>(StringToInt(strBuffer) - 1);
			
			TFDB_SetRocketClassBehaviour(iClass, iOption);
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketClassBehaviourMenu(iParam1, iClass);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketClassOptionsMenu(iParam1, iClass); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplayRocketClassFlagsMenu(int iClient, int iClass)
{
	Menu hMenu = new Menu(RocketClassFlagsMenuHandler, MENU_ACTIONS_DEFAULT | MenuAction_DisplayItem);
	
	char strClass[8]; IntToString(iClass, strClass, sizeof(strClass));
	char strTitle[64]; TFDB_GetRocketClassLongName(iClass, strTitle, sizeof(strTitle));
	
	Format(strTitle, sizeof(strTitle), "%s (%s) behaviour modifiers", strTitle, strClass);
	
	hMenu.SetTitle(strTitle);
	hMenu.AddItem(strClass, "", ITEMDRAW_IGNORE);
	hMenu.ExitBackButton = true;
	
	hMenu.AddItem("1", "Elevate on deflect", ITEMDRAW_DEFAULT);
	hMenu.AddItem("2", "Neutral rocket", ITEMDRAW_DEFAULT);
	hMenu.AddItem("3", "Keep direction", ITEMDRAW_DEFAULT);
	hMenu.AddItem("4", "Teamless deflects", ITEMDRAW_DEFAULT);
	hMenu.AddItem("5", "Reset bounces", ITEMDRAW_DEFAULT);
	hMenu.AddItem("6", "No bounce drags", ITEMDRAW_DEFAULT);
	hMenu.AddItem("7", "Can be stolen", ITEMDRAW_DEFAULT);
	hMenu.AddItem("8", "Steal team check", ITEMDRAW_DEFAULT);
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int RocketClassFlagsMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	int  iClass = StringToInt(strBuffer);
	
	switch (iMenuActions)
	{
		case MenuAction_DisplayItem :
		{
			char strDisplay[64];
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer), _, strDisplay, sizeof(strDisplay));
			
			int iOption = StringToInt(strBuffer);
			
			switch (iOption)
			{
				case 1 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_ElevateOnDeflect ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 2 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_IsNeutral ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 3 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_KeepDirection ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 4 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_TeamlessHits ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 5 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_ResetBounces ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 6 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_NoBounceDrags ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 7 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_CanBeStolen ? "[X] %s" : "[ ] %s", strDisplay);
				}
				
				case 8 :
				{
					Format(strDisplay, sizeof(strDisplay), TFDB_GetRocketClassFlags(iClass) & RocketFlag_StealTeamCheck ? "[X] %s" : "[ ] %s", strDisplay);
				}
			}
			
			return RedrawMenuItem(strDisplay);
		}
		
		case MenuAction_Select :
		{
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			
			int iOption = StringToInt(strBuffer);
			
			switch (iOption)
			{
				case 1 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_ElevateOnDeflect);
				}
				
				case 2 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_IsNeutral);
				}
				
				case 3 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_KeepDirection);
				}
				
				case 4 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_TeamlessHits);
				}
				
				case 5 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_ResetBounces);
				}
				
				case 6 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_NoBounceDrags);
				}
				
				case 7 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_CanBeStolen);
				}
				
				case 8 :
				{
					TFDB_SetRocketClassFlags(iClass, TFDB_GetRocketClassFlags(iClass) ^ RocketFlag_StealTeamCheck);
				}
			}
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1))
			{
				DisplayRocketClassFlagsMenu(iParam1, iClass);
			}
		}
		
		case MenuAction_Cancel :
		{
			if (iParam2 == MenuCancel_ExitBack) { DisplayRocketClassOptionsMenu(iParam1, iClass); }
		}
		
		case MenuAction_End :
		{
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplaySpawnerClassesMenu(int iClient)
{
	Menu hMenu = new Menu(SpawnerClassesMenuHandler);
	
	char strBuffer[8];
	
	hMenu.SetTitle("Spawners options :");
	hMenu.ExitBackButton = true;
	
	for (SpawnerClassMenu iOption = SpawnerClassMenu_MaxRockets; iOption < SizeOfSpawnerClassMenu; iOption++)
	{
		IntToString(view_as<int>(iOption), strBuffer, sizeof(strBuffer));
		
		hMenu.AddItem(strBuffer, strSpawnerClassMenu[view_as<int>(iOption) - 1], ITEMDRAW_DEFAULT);
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int SpawnerClassesMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	char strBuffer[8]; hMenu.GetItem(0, strBuffer, sizeof(strBuffer));
	
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			hMenu.GetItem(iParam2, strBuffer, sizeof(strBuffer));
			
			SpawnerClassMenu iOption = view_as<SpawnerClassMenu>(StringToInt(strBuffer));
			
			switch (iOption)
			{
				case SpawnerClassMenu_MaxRockets :
				{
					CPrintToChat(iParam1, "%t", "Menu_MaxRockets", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
					
					ClientSayHook[iParam1]          = true;
					ClientMenuSelectTime[iParam1]   = GetGameTime();
					g_iClientSpawnerClassMenu[iParam1] = iOption;
				}
				
				case SpawnerClassMenu_Interval :
				{
					CPrintToChat(iParam1, "%t", "Menu_Interval", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
					
					ClientSayHook[iParam1]          = true;
					ClientMenuSelectTime[iParam1]   = GetGameTime();
					g_iClientSpawnerClassMenu[iParam1] = iOption;
				}
				
				case SpawnerClassMenu_ChancesTable :
				{
					DisplaySpawnerClassChancesMenu(iParam1);
				}
			}
			
			g_iClientRocketClassMenu[iParam1] = RocketClassMenu_None;
			
			if (IsClientInGame(iParam1) && !IsClientInKickQueue(iParam1) && iOption != SpawnerClassMenu_ChancesTable)
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
			delete hMenu;
		}
	}
	
	return 0;
}

void DisplaySpawnerClassChancesMenu(int iClient)
{
	Menu hMenu = new Menu(SpawnerClassChancesMenuHandler);
	
	char strClass[8], strRocketClassLongName[48];
	
	hMenu.SetTitle("Rocket classes spawn chances :");
	hMenu.ExitBackButton = true;
	
	for (int iClass = 0; iClass < TFDB_GetRocketClassCount(); iClass++)
	{
		IntToString(iClass, strClass, sizeof(strClass));
		TFDB_GetRocketClassLongName(iClass, strRocketClassLongName, sizeof(strRocketClassLongName));
		Format(strRocketClassLongName, sizeof(strRocketClassLongName), "%s (Class : %s)", strRocketClassLongName, strClass);
		
		hMenu.AddItem(strClass, strRocketClassLongName, ITEMDRAW_DEFAULT);
	}
	
	hMenu.Display(iClient, MENU_TIME_FOREVER);
}

public int SpawnerClassChancesMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	switch (iMenuActions)
	{
		case MenuAction_Select :
		{
			char strClass[8];
			hMenu.GetItem(iParam2, strClass, sizeof(strClass));
			
			int iClass = StringToInt(strClass);
			
			ClientSayHook[iParam1]          = true;
			ClientMenuSelectTime[iParam1]   = GetGameTime();
			g_iClientSpawnerClassMenu[iParam1] = SpawnerClassMenu_ChancesTable;
			g_iClientRocketClass[iParam1]      = iClass;
			
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
			delete hMenu;
		}
	}
	
	return 0;
}

public Action OnClientSayCommand(int iClient, const char[] strCommand, const char[] strArgs)
{
	if (!ClientSayHook[iClient]) return Plugin_Continue;
	
	ClientSayHook[iClient] = false;
	
	if ((GetGameTime() - ClientMenuSelectTime[iClient]) > CvarSayHookTimeout.FloatValue) return Plugin_Continue;
	
	if (!((strcmp(strCommand, "say") == 0) || (strcmp(strCommand, "say_team") == 0))) return Plugin_Continue;
	
	RocketClassMenu  iRocketClassOption  = g_iClientRocketClassMenu[iClient];
	SpawnerClassMenu iSpawnerClassOption = g_iClientSpawnerClassMenu[iClient];
	int iRocketClass  = g_iClientRocketClass[iClient];
	
	switch (iRocketClassOption)
	{
		case RocketClassMenu_SpriteColor :
		{
			if ((strlen(strArgs) == 6) && (StrContains(strArgs, " ") == -1))
			{
				char strColor[16];
				int iRGB[3]; HexToRGB(strArgs, iRGB);
				
				FormatEx(strColor, sizeof(strColor), "%i %i %i", iRGB[0], iRGB[1], iRGB[2]);
				
				TFDB_SetRocketClassSpriteColor(iRocketClass, strColor);
				
				LogAction(iClient, -1, "\"%L\" changed rocket class sprite trail color to #%s", iClient, strArgs);
				CPrintToChat(iClient, "\x01%t\x01", "Menu_ChangedSpriteColor", "\x07", strArgs, strArgs);
			}
			else if (StringToInt(strArgs) != -1)
			{
				char strBuffer[3][8];
				ExplodeString(strArgs, " ", strBuffer, sizeof(strBuffer), sizeof(strBuffer[]));
				
				int iRGB[3];
				iRGB[0] = StringToInt(strBuffer[0]);
				iRGB[1] = StringToInt(strBuffer[1]);
				iRGB[2] = StringToInt(strBuffer[2]);
				
				char strColor[16]; RGBToHex(iRGB, strColor, sizeof(strColor));
				
				TFDB_SetRocketClassSpriteColor(iRocketClass, strArgs);
				
				LogAction(iClient, -1, "\"%L\" changed rocket class sprite trail color to #%s", iClient, strColor);
				CPrintToChat(iClient, "\x01%t\x01", "Menu_ChangedSpriteColor", "\x07", strColor, strColor);
			}
			else
			{
				char strBuffer[3][8];
				ExplodeString(g_eSavedRocketClasses[iRocketClass].SpriteColor, " ", strBuffer, sizeof(strBuffer), sizeof(strBuffer[]));
				
				int iRGB[3];
				iRGB[0] = StringToInt(strBuffer[0]);
				iRGB[1] = StringToInt(strBuffer[1]);
				iRGB[2] = StringToInt(strBuffer[2]);
				
				char strHex[16]; RGBToHex(iRGB, strHex, sizeof(strHex));
				
				TFDB_SetRocketClassSpriteColor(iRocketClass, g_eSavedRocketClasses[iRocketClass].SpriteColor);
				
				LogAction(iClient, -1, "\"%L\" reset rocket class sprite trail color to #%s", iClient, strHex);
				CPrintToChat(iClient, "\x01%t\x01", "Menu_ResetSpriteColor", "\x07", strHex, strHex);
			}
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteLifetime :
		{
			float fLifetime = StringToFloat(strArgs);
			
			TFDB_SetRocketClassSpriteLifetime(iRocketClass, fLifetime == -1.0 ? g_eSavedRocketClasses[iRocketClass].SpriteLifetime : fLifetime);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class sprite trail duration to %.2f", iClient, fLifetime);
			CPrintToChat(iClient, "%t", "Menu_ChangedSpriteLifetime", fLifetime);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteStartWidth :
		{
			float fWidth = StringToFloat(strArgs);
			
			TFDB_SetRocketClassSpriteStartWidth(iRocketClass, fWidth == -1.0 ? g_eSavedRocketClasses[iRocketClass].SpriteStartWidth : fWidth);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class sprite trail start width to %.2f", iClient, fWidth);
			CPrintToChat(iClient, "%t", "Menu_ChangedSpriteStartWidth", fWidth);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteEndWidth :
		{
			float fWidth = StringToFloat(strArgs);
			
			TFDB_SetRocketClassSpriteEndWidth(iRocketClass, fWidth == -1.0 ? g_eSavedRocketClasses[iRocketClass].SpriteEndWidth : fWidth);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class sprite trail end width to %.2f", iClient, fWidth);
			CPrintToChat(iClient, "%t", "Menu_ChangedSpriteEndWidth", fWidth);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_BeepInterval :
		{
			float fInterval = StringToFloat(strArgs);
			
			if (fInterval == -1.0)
			{
				g_eSavedRocketClasses[iRocketClass].Flags & RocketFlag_PlayBeepSound ?
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) | RocketFlag_PlayBeepSound) :
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) & ~RocketFlag_PlayBeepSound);
				
				TFDB_SetRocketClassBeepInterval(iRocketClass, g_eSavedRocketClasses[iRocketClass].BeepInterval);
			}
			else if (fInterval == 0.0)
			{
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) & ~RocketFlag_PlayBeepSound);
			}
			else
			{
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) | RocketFlag_PlayBeepSound);
				TFDB_SetRocketClassBeepInterval(iRocketClass, fInterval);
			}
			
			LogAction(iClient, -1, "\"%L\" changed rocket class beep interval to %.2f", iClient, fInterval);
			CPrintToChat(iClient, "%t", "Menu_ChangedBeepInterval", fInterval);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_CritChance :
		{
			float fChance = StringToFloat(strArgs);
			
			TFDB_SetRocketClassCritChance(iRocketClass, fChance == -1.0 ? g_eSavedRocketClasses[iRocketClass].CritChance : fChance);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class critical chance to %.2f", iClient, fChance);
			CPrintToChat(iClient, "%t", "Menu_ChangedCritChance", fChance);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_Damage :
		{
			float fDamage = StringToFloat(strArgs);
			
			TFDB_SetRocketClassDamage(iRocketClass, fDamage == -1.0 ? g_eSavedRocketClasses[iRocketClass].Damage : fDamage);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class damage to %.2f", iClient, fDamage);
			CPrintToChat(iClient, "%t", "Menu_ChangedDamage", fDamage);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_DamageIncrement :
		{
			float fDamage = StringToFloat(strArgs);
			
			TFDB_SetRocketClassDamageIncrement(iRocketClass, fDamage == -1.0 ? g_eSavedRocketClasses[iRocketClass].DamageIncrement : fDamage);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class damage increment to %.2f", iClient, fDamage);
			CPrintToChat(iClient, "%t", "Menu_ChangedDamageIncrement", fDamage);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_Speed :
		{
			float fSpeed = StringToFloat(strArgs);
			
			TFDB_SetRocketClassSpeed(iRocketClass, fSpeed == -1.0 ? g_eSavedRocketClasses[iRocketClass].Speed : fSpeed);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class speed to %.2f", iClient, fSpeed);
			CPrintToChat(iClient, "%t", "Menu_ChangedSpeed", fSpeed);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpeedIncrement :
		{
			float fSpeed = StringToFloat(strArgs);
			
			TFDB_SetRocketClassSpeedIncrement(iRocketClass, fSpeed == -1.0 ? g_eSavedRocketClasses[iRocketClass].SpeedIncrement : fSpeed);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class speed increment to %.2f", iClient, fSpeed);
			CPrintToChat(iClient, "%t", "Menu_ChangedSpeedIncrement", fSpeed);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpeedLimit :
		{
			float fSpeed = StringToFloat(strArgs);
			
			if (fSpeed == -1.0)
			{
				g_eSavedRocketClasses[iRocketClass].Flags & RocketFlag_IsSpeedLimited ?
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) | RocketFlag_IsSpeedLimited) :
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) & ~RocketFlag_IsSpeedLimited);
				
				TFDB_SetRocketClassSpeedLimit(iRocketClass, g_eSavedRocketClasses[iRocketClass].SpeedLimit);
			}
			else if (fSpeed == 0.0)
			{
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) & ~RocketFlag_IsSpeedLimited);
			}
			else
			{
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) | RocketFlag_IsSpeedLimited);
				TFDB_SetRocketClassSpeedLimit(iRocketClass, fSpeed);
			}
			
			LogAction(iClient, -1, "\"%L\" changed rocket class speed limit to %.2f", iClient, fSpeed);
			CPrintToChat(iClient, "%t", "Menu_ChangedSpeedLimit", fSpeed);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRate :
		{
			float fTurnRate = StringToFloat(strArgs);
			
			TFDB_SetRocketClassTurnRate(iRocketClass, fTurnRate == -1.0 ? g_eSavedRocketClasses[iRocketClass].TurnRate : fTurnRate);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class turn rate to %.2f", iClient, fTurnRate);
			CPrintToChat(iClient, "%t", "Menu_ChangedTurnRate", fTurnRate);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRateIncrement :
		{
			float fTurnRate = StringToFloat(strArgs);
			
			TFDB_SetRocketClassTurnRateIncrement(iRocketClass, fTurnRate == -1.0 ? g_eSavedRocketClasses[iRocketClass].TurnRateIncrement : fTurnRate);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class turn rate increment to %.2f", iClient, fTurnRate);
			CPrintToChat(iClient, "%t", "Menu_ChangedTurnRateIncrement", fTurnRate);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRateLimit :
		{
			float fTurnRate = StringToFloat(strArgs);
			
			if (fTurnRate == -1.0)
			{
				g_eSavedRocketClasses[iRocketClass].Flags & RocketFlag_IsTRLimited ?
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) | RocketFlag_IsTRLimited) :
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) & ~RocketFlag_IsTRLimited);
				
				TFDB_SetRocketClassTurnRateLimit(iRocketClass, g_eSavedRocketClasses[iRocketClass].TurnRateLimit);
			}
			else if (fTurnRate == 0.0)
			{
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) & ~RocketFlag_IsTRLimited);
			}
			else
			{
				TFDB_SetRocketClassFlags(iRocketClass, TFDB_GetRocketClassFlags(iRocketClass) | RocketFlag_IsTRLimited);
				TFDB_SetRocketClassTurnRateLimit(iRocketClass, fTurnRate);
			}
			
			LogAction(iClient, -1, "\"%L\" changed rocket class turn rate limit to %.2f", iClient, fTurnRate);
			CPrintToChat(iClient, "%t", "Menu_ChangedTurnRateLimit", fTurnRate);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ElevationRate :
		{
			float fElevation = StringToFloat(strArgs);
			
			TFDB_SetRocketClassElevationRate(iRocketClass, fElevation == -1.0 ? g_eSavedRocketClasses[iRocketClass].ElevationRate : fElevation);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class elevation rate to %.2f", iClient, fElevation);
			CPrintToChat(iClient, "%t", "Menu_ChangedElevationRate", fElevation);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ElevationLimit :
		{
			float fElevation = StringToFloat(strArgs);
			
			TFDB_SetRocketClassElevationLimit(iRocketClass, fElevation == -1.0 ? g_eSavedRocketClasses[iRocketClass].ElevationLimit : fElevation);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class elevation limit to %.2f", iClient, fElevation);
			CPrintToChat(iClient, "%t", "Menu_ChangedElevationLimit", fElevation);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_RocketsModifier :
		{
			float fModifier = StringToFloat(strArgs);
			
			TFDB_SetRocketClassRocketsModifier(iRocketClass, fModifier == -1.0 ? g_eSavedRocketClasses[iRocketClass].RocketsModifier : fModifier);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class fired rockets modifier to %.2f", iClient, fModifier);
			CPrintToChat(iClient, "%t", "Menu_ChangedRocketsModifier", fModifier);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_PlayerModifier :
		{
			float fModifier = StringToFloat(strArgs);
			
			TFDB_SetRocketClassPlayerModifier(iRocketClass, fModifier == -1.0 ? g_eSavedRocketClasses[iRocketClass].PlayerModifier : fModifier);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class player count modifier to %.2f", iClient, fModifier);
			CPrintToChat(iClient, "%t", "Menu_ChangedPlayerModifier", fModifier);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ControlDelay :
		{
			float fDelay = StringToFloat(strArgs);
			
			TFDB_SetRocketClassControlDelay(iRocketClass, fDelay == -1.0 ? g_eSavedRocketClasses[iRocketClass].ControlDelay : fDelay);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class control delay to %.2f", iClient, fDelay);
			CPrintToChat(iClient, "%t", "Menu_ChangedControlDelay", fDelay);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_DragTimeMin :
		{
			float fTime = StringToFloat(strArgs);
			
			TFDB_SetRocketClassDragTimeMin(iRocketClass, fTime == -1.0 ? g_eSavedRocketClasses[iRocketClass].DragTimeMin : fTime);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class drag time start to %.2f", iClient, fTime);
			CPrintToChat(iClient, "%t", "Menu_ChangedDragTimeMin", fTime);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_DragTimeMax :
		{
			float fTime = StringToFloat(strArgs);
			
			TFDB_SetRocketClassDragTimeMax(iRocketClass, fTime == -1.0 ? g_eSavedRocketClasses[iRocketClass].DragTimeMax : fTime);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class drag time end to %.2f", iClient, fTime);
			CPrintToChat(iClient, "%t", "Menu_ChangedDragTimeMax", fTime);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TargetWeight :
		{
			float fWeight = StringToFloat(strArgs);
			
			TFDB_SetRocketClassTargetWeight(iRocketClass, fWeight == -1.0 ? g_eSavedRocketClasses[iRocketClass].TargetWeight : fWeight);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class target weight to %.2f", iClient, fWeight);
			CPrintToChat(iClient, "%t", "Menu_ChangedTargetWeight", fWeight);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_MaxBounces :
		{
			int iBounces = StringToInt(strArgs);
			
			TFDB_SetRocketClassMaxBounces(iRocketClass, iBounces == -1 ? g_eSavedRocketClasses[iRocketClass].MaxBounces : iBounces);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class maximum bounces to %i", iClient, iBounces);
			CPrintToChat(iClient, "%t", "Menu_ChangedMaxBounces", iBounces);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_BounceScale :
		{
			float fScale = StringToFloat(strArgs);
			
			TFDB_SetRocketClassBounceScale(iRocketClass, fScale == -1.0 ? g_eSavedRocketClasses[iRocketClass].BounceScale : fScale);
			
			LogAction(iClient, -1, "\"%L\" changed rocket class bounce scale to %.2f", iClient, fScale);
			CPrintToChat(iClient, "%t", "Menu_ChangedBounceScale", fScale);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
	}
	
	switch (iSpawnerClassOption)
	{
		case SpawnerClassMenu_MaxRockets :
		{
			int iCount = StringToInt(strArgs);
			
			for (int iIndex = 0; iIndex < TFDB_GetSpawnersCount(); iIndex++)
			{
				TFDB_SetSpawnersMaxRockets(iIndex, iCount == -1 ? g_eSavedSpawnerClasses[iIndex].MaxRockets : iCount);
			}
			
			LogAction(iClient, -1, "\"%L\" changed spawners maximum rockets to %i", iClient, iCount);
			CPrintToChat(iClient, "%t", "Menu_ChangedMaxRockets", iCount);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case SpawnerClassMenu_Interval :
		{
			float fInterval = StringToFloat(strArgs);
			
			for (int iIndex = 0; iIndex < TFDB_GetSpawnersCount(); iIndex++)
			{
				TFDB_SetSpawnersInterval(iIndex, fInterval == -1.0 ? g_eSavedSpawnerClasses[iIndex].Interval : fInterval);
			}
			
			LogAction(iClient, -1, "\"%L\" changed spawners rocket spawn interval to %.2f", iClient, fInterval);
			CPrintToChat(iClient, "%t", "Menu_ChangedInterval", fInterval);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
		
		case SpawnerClassMenu_ChancesTable :
		{
			int iChances = StringToInt(strArgs);
			
			for (int iIndex = 0; iIndex < TFDB_GetSpawnersCount(); iIndex++)
			{
				ArrayList hTable = TFDB_GetSpawnersChancesTable(iIndex);
				
				if (iRocketClass < hTable.Length)
				{
					hTable.Set(iRocketClass, iChances == -1 ? g_eSavedSpawnerClasses[iIndex].ChancesTable.Get(iRocketClass) : iChances);
				}
				
				TFDB_SetSpawnersChancesTable(iIndex, hTable);
				
				delete hTable;
			}
			
			LogAction(iClient, -1, "\"%L\" changed spawners rocket class chances to %i", iClient, iChances);
			CPrintToChat(iClient, "%t", "Menu_ChangedChancesTable", iChances);
			
			g_iClientRocketClassMenu[iClient]  = RocketClassMenu_None;
			g_iClientSpawnerClassMenu[iClient] = SpawnerClassMenu_None;
			g_iClientRocketClass[iClient]  = -1;
			
			return Plugin_Stop;
		}
	}
	
	return Plugin_Continue;
}

void ParseConfigurations(const char[] strConfigFile)
{
	char strPath[PLATFORM_MAX_PATH];
	char strFileName[PLATFORM_MAX_PATH];
	FormatEx(strFileName, sizeof(strFileName), "configs/dodgeball/%s", strConfigFile);
	BuildPath(Path_SM, strPath, sizeof(strPath), strFileName);
	
	if (!FileExists(strPath, true)) return;
	
	KeyValues kvConfig = new KeyValues("TF2_Dodgeball");
	
	if (kvConfig.ImportFromFile(strPath) == false) SetFailState("Error while parsing the configuration file.");
	
	kvConfig.GotoFirstSubKey();
	
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
	char strBuffer[256];
	
	kvConfig.GotoFirstSubKey();
	do
	{
		int iIndex = g_iRocketClassCount;
		RocketFlags iFlags;
		TrailFlags iTrailFlags;
		
		kvConfig.GetSectionName(strName, sizeof(strName));        strcopy(g_eSavedRocketClasses[iIndex].Name, 16, strName);
		kvConfig.GetString("name", strBuffer, sizeof(strBuffer)); strcopy(g_eSavedRocketClasses[iIndex].LongName, 32, strBuffer);
		
		if (kvConfig.GetString("model", strBuffer, sizeof(strBuffer)))
		{
			strcopy(g_eSavedRocketClasses[iIndex].Model, PLATFORM_MAX_PATH, strBuffer);
			
			if (g_eSavedRocketClasses[iIndex].Model[0])
			{
				iFlags |= RocketFlag_CustomModel;
				
				if (kvConfig.GetNum("is animated", 0)) iFlags |= RocketFlag_IsAnimated;
			}
		}
		
		if (kvConfig.GetString("trail particle", strBuffer, sizeof(strBuffer)))
		{
			strcopy(g_eSavedRocketClasses[iIndex].Trail, sizeof(g_eSavedRocketClasses[].Trail), strBuffer);
			
			if (g_eSavedRocketClasses[iIndex].Trail[0])
			{
				iTrailFlags |= TrailFlag_CustomTrail;
			}
		}
		
		if (kvConfig.GetString("trail sprite", strBuffer, sizeof(strBuffer)))
		{
			strcopy(g_eSavedRocketClasses[iIndex].Sprite, PLATFORM_MAX_PATH, strBuffer);
			
			if (g_eSavedRocketClasses[iIndex].Sprite[0])
			{
				iTrailFlags |= TrailFlag_CustomSprite;
				
				if (kvConfig.GetString("custom color", strBuffer, sizeof(strBuffer)))
				{
					strcopy(g_eSavedRocketClasses[iIndex].SpriteColor, sizeof(g_eSavedRocketClasses[].SpriteColor), strBuffer);
				}
				
				g_eSavedRocketClasses[iIndex].SpriteLifetime   = kvConfig.GetFloat("sprite lifetime");
				g_eSavedRocketClasses[iIndex].SpriteStartWidth = kvConfig.GetFloat("sprite start width");
				g_eSavedRocketClasses[iIndex].SpriteEndWidth   = kvConfig.GetFloat("sprite end width");
			}
		}
		
		if (kvConfig.GetNum("remove particles", 0))
		{
			iTrailFlags |= TrailFlag_RemoveParticles;
			
			if (kvConfig.GetNum("replace particles", 0)) iTrailFlags |= TrailFlag_ReplaceParticles;
		}
		
		kvConfig.GetString("behaviour", strBuffer, sizeof(strBuffer), "homing");
		
		if (StrEqual(strBuffer, "homing"))
		{
			g_eSavedRocketClasses[iIndex].Behaviour = Behaviour_Homing;
		}
		else if (StrEqual(strBuffer, "legacy homing"))
		{
			g_eSavedRocketClasses[iIndex].Behaviour = Behaviour_LegacyHoming;
		}
		else
		{
			g_eSavedRocketClasses[iIndex].Behaviour = Behaviour_Unknown;
		}
		
		if (kvConfig.GetNum("play spawn sound", 0) == 1)
		{
			iFlags |= RocketFlag_PlaySpawnSound;
			
			if (kvConfig.GetString("spawn sound", g_eSavedRocketClasses[iIndex].SpawnSound, PLATFORM_MAX_PATH) && g_eSavedRocketClasses[iIndex].SpawnSound[0])
			{
				iFlags |= RocketFlag_CustomSpawnSound;
			}
		}
		
		if (kvConfig.GetNum("play beep sound", 0) == 1)
		{
			iFlags |= RocketFlag_PlayBeepSound;
			g_eSavedRocketClasses[iIndex].BeepInterval = kvConfig.GetFloat("beep interval", 0.5);
			
			if (kvConfig.GetString("beep sound", g_eSavedRocketClasses[iIndex].BeepSound, PLATFORM_MAX_PATH) && g_eSavedRocketClasses[iIndex].BeepSound[0])
			{
				iFlags |= RocketFlag_CustomBeepSound;
			}
		}
		
		if (kvConfig.GetNum("play alert sound", 0) == 1)
		{
			iFlags |= RocketFlag_PlayAlertSound;
			
			if (kvConfig.GetString("alert sound", g_eSavedRocketClasses[iIndex].AlertSound, PLATFORM_MAX_PATH) && g_eSavedRocketClasses[iIndex].AlertSound[0])
			{
				iFlags |= RocketFlag_CustomAlertSound;
			}
		}
		
		if (kvConfig.GetNum("elevate on deflect", 1) == 1) iFlags |= RocketFlag_ElevateOnDeflect;
		if (kvConfig.GetNum("neutral rocket", 0) == 1)     iFlags |= RocketFlag_IsNeutral;
		if (kvConfig.GetNum("keep direction", 0) == 1)     iFlags |= RocketFlag_KeepDirection;
		if (kvConfig.GetNum("teamless deflects", 0) == 1)  iFlags |= RocketFlag_TeamlessHits;
		if (kvConfig.GetNum("reset bounces", 0) == 1)      iFlags |= RocketFlag_ResetBounces;
		if (kvConfig.GetNum("no bounce drags", 0) == 1)    iFlags |= RocketFlag_NoBounceDrags;
		if (kvConfig.GetNum("can be stolen", 0) == 1)      iFlags |= RocketFlag_CanBeStolen;
		if (kvConfig.GetNum("steal team check", 0) == 1)   iFlags |= RocketFlag_StealTeamCheck;
		
		g_eSavedRocketClasses[iIndex].Damage            = kvConfig.GetFloat("damage");
		g_eSavedRocketClasses[iIndex].DamageIncrement   = kvConfig.GetFloat("damage increment");
		g_eSavedRocketClasses[iIndex].CritChance        = kvConfig.GetFloat("critical chance");
		g_eSavedRocketClasses[iIndex].Speed             = kvConfig.GetFloat("speed");
		g_eSavedRocketClasses[iIndex].SpeedIncrement    = kvConfig.GetFloat("speed increment");
		
		if ((g_eSavedRocketClasses[iIndex].SpeedLimit = kvConfig.GetFloat("speed limit")) != 0.0)
		{
			iFlags |= RocketFlag_IsSpeedLimited;
		}
		
		g_eSavedRocketClasses[iIndex].TurnRate          = kvConfig.GetFloat("turn rate");
		g_eSavedRocketClasses[iIndex].TurnRateIncrement = kvConfig.GetFloat("turn rate increment");
		
		if ((g_eSavedRocketClasses[iIndex].TurnRateLimit = kvConfig.GetFloat("turn rate limit")) != 0.0)
		{
			iFlags |= RocketFlag_IsTRLimited;
		}
		
		g_eSavedRocketClasses[iIndex].ElevationRate     = kvConfig.GetFloat("elevation rate");
		g_eSavedRocketClasses[iIndex].ElevationLimit    = kvConfig.GetFloat("elevation limit");
		g_eSavedRocketClasses[iIndex].ControlDelay      = kvConfig.GetFloat("control delay");
		g_eSavedRocketClasses[iIndex].DragTimeMin       = kvConfig.GetFloat("drag time min");
		g_eSavedRocketClasses[iIndex].DragTimeMax       = kvConfig.GetFloat("drag time max");
		g_eSavedRocketClasses[iIndex].BounceScale       = kvConfig.GetFloat("bounce scale", 1.0);
		g_eSavedRocketClasses[iIndex].PlayerModifier    = kvConfig.GetFloat("no. players modifier");
		g_eSavedRocketClasses[iIndex].RocketsModifier   = kvConfig.GetFloat("no. rockets modifier");
		g_eSavedRocketClasses[iIndex].TargetWeight      = kvConfig.GetFloat("direction to target weight");
		g_eSavedRocketClasses[iIndex].MaxBounces        = kvConfig.GetNum("max bounces");
		
		DataPack hCmds = null;
		
		kvConfig.GetString("on spawn", strBuffer, sizeof(strBuffer));
		if ((hCmds = ParseCommands(strBuffer)) != null) { iFlags |= RocketFlag_OnSpawnCmd; g_eSavedRocketClasses[iIndex].CmdsOnSpawn = hCmds; }
		
		kvConfig.GetString("on deflect", strBuffer, sizeof(strBuffer));
		if ((hCmds = ParseCommands(strBuffer)) != null) { iFlags |= RocketFlag_OnDeflectCmd; g_eSavedRocketClasses[iIndex].CmdsOnDeflect = hCmds; }
		
		kvConfig.GetString("on kill", strBuffer, sizeof(strBuffer));
		if ((hCmds = ParseCommands(strBuffer)) != null) { iFlags |= RocketFlag_OnKillCmd; g_eSavedRocketClasses[iIndex].CmdsOnKill = hCmds; }
		
		kvConfig.GetString("on explode", strBuffer, sizeof(strBuffer));
		if ((hCmds = ParseCommands(strBuffer)) != null) { iFlags |= RocketFlag_OnExplodeCmd; g_eSavedRocketClasses[iIndex].CmdsOnExplode = hCmds; }
		
		kvConfig.GetString("on no target", strBuffer, sizeof(strBuffer));
		if ((hCmds = ParseCommands(strBuffer)) != null) { iFlags |= RocketFlag_OnNoTargetCmd; g_eSavedRocketClasses[iIndex].CmdsOnNoTarget = hCmds; }
		
		g_eSavedRocketClasses[iIndex].Flags = iFlags;
		g_eSavedRocketClasses[iIndex].TFlags = iTrailFlags;
		g_iRocketClassCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack(); 
}

void ParseSpawners(KeyValues kvConfig)
{
	char strBuffer[256];
	kvConfig.GotoFirstSubKey();
	
	do
	{
		int iIndex = g_iSpawnersCount;
		
		kvConfig.GetSectionName(strBuffer, sizeof(strBuffer)); strcopy(g_eSavedSpawnerClasses[iIndex].Name, 32, strBuffer);
		g_eSavedSpawnerClasses[iIndex].MaxRockets = kvConfig.GetNum("max rockets", 1);
		g_eSavedSpawnerClasses[iIndex].Interval   = kvConfig.GetFloat("interval", 1.0);
		
		g_eSavedSpawnerClasses[iIndex].ChancesTable = new ArrayList();
		
		for (int iClassIndex = 0; iClassIndex < g_iRocketClassCount; iClassIndex++)
		{
			FormatEx(strBuffer, sizeof(strBuffer), "%s%%", g_eSavedRocketClasses[iClassIndex].Name);
			g_eSavedSpawnerClasses[iIndex].ChancesTable.Push(kvConfig.GetNum(strBuffer, 0));
		}
		
		g_iSpawnersCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack();
}

DataPack ParseCommands(char[] strLine)
{
	TrimString(strLine);
	
	if (!strLine[0])
	{
		return null;
	}
	
	char strStrings[8][255];
	int iNumStrings = ExplodeString(strLine, ";", strStrings, 8, 255);
	
	DataPack hDataPack = new DataPack();
	hDataPack.WriteCell(iNumStrings);
	
	for (int i = 0; i < iNumStrings; i++)
	{
		hDataPack.WriteString(strStrings[i]);
	}
	
	return hDataPack;
}

void EmitRocketSound(RocketSound iSound, int iClass, int iEntity, int iTarget, RocketFlags iFlags)
{
	switch (iSound)
	{
		case RocketSound_Spawn:
		{
			if (TestFlags(iFlags, RocketFlag_PlaySpawnSound))
			{
				if (TestFlags(iFlags, RocketFlag_CustomSpawnSound))
				{
					char strRocketClassSpawnSound[PLATFORM_MAX_PATH];
					TFDB_GetRocketClassSpawnSound(iClass, strRocketClassSpawnSound, sizeof(strRocketClassSpawnSound));
					EmitSoundToAll(strRocketClassSpawnSound, iEntity);
				}
				else
				{
					EmitSoundToAll(SOUND_DEFAULT_SPAWN, iEntity);
				}
			}
		}
		case RocketSound_Beep:
		{
			if (TestFlags(iFlags, RocketFlag_PlayBeepSound))
			{
				if (TestFlags(iFlags, RocketFlag_CustomBeepSound))
				{
					char strRocketClassBeepSound [PLATFORM_MAX_PATH];
					TFDB_GetRocketClassBeepSound(iClass, strRocketClassBeepSound, sizeof(strRocketClassBeepSound));
					EmitSoundToAll(strRocketClassBeepSound, iEntity);
				}
				else
				{
					EmitSoundToAll(SOUND_DEFAULT_BEEP, iEntity);
				}
			}
		}
		case RocketSound_Alert:
		{
			if (TestFlags(iFlags, RocketFlag_PlayAlertSound))
			{
				if (TestFlags(iFlags, RocketFlag_CustomAlertSound))
				{
					char strRocketClassAlertSound[PLATFORM_MAX_PATH];
					TFDB_GetRocketClassBeepSound(iClass, strRocketClassAlertSound, sizeof(strRocketClassAlertSound));
					EmitSoundToClient(iTarget, strRocketClassAlertSound);
				}
				else
				{
					EmitSoundToClient(iTarget, SOUND_DEFAULT_ALERT, _, _, _, _, 0.5);
				}
			}
		}
	}
}

char[] BehaviourToString(BehaviourTypes iBehaviour)
{
	char strBehaviour[16] = "undefined";
	
	switch (iBehaviour)
	{
		case Behaviour_Unknown :
		{
			strBehaviour = "Unknown";
		}
		
		case Behaviour_Homing :
		{
			strBehaviour = "Homing";
		}
		
		case Behaviour_LegacyHoming :
		{
			strBehaviour = "Legacy homing";
		}
	}
	
	return strBehaviour;
}

bool IsRocketClassMenuDisabled(RocketClassMenu iOption)
{
	return iOption == RocketClassMenu_Name           ||
	       iOption == RocketClassMenu_LongName       ||
	       iOption == RocketClassMenu_Model          ||
	       iOption == RocketClassMenu_Trail          ||
	       iOption == RocketClassMenu_Sprite         ||
	       iOption == RocketClassMenu_SpawnSound     ||
	       iOption == RocketClassMenu_BeepSound      ||
	       iOption == RocketClassMenu_AlertSound     ||
	       iOption == RocketClassMenu_CmdsOnSpawn    ||
	       iOption == RocketClassMenu_CmdsOnDeflect  ||
	       iOption == RocketClassMenu_CmdsOnKill     ||
	       iOption == RocketClassMenu_CmdsOnExplode  ||
	       iOption == RocketClassMenu_CmdsOnNoTarget ||
	       (!TrailsLoaded &&
	       (iOption == RocketClassMenu_SpriteColor    ||
	        iOption == RocketClassMenu_SpriteEndWidth ||
	        iOption == RocketClassMenu_SpriteLifetime ||
	        iOption == RocketClassMenu_SpriteStartWidth));
}

// https://github.com/JoinedSenses/SM-JSLib/blob/main/jslib.inc

stock void HexToRGB(const char[] strHex, int iRGB[3])
{
	IntToRGB(StringToInt(strHex, 16), iRGB);
}

stock void IntToRGB(int iValue, int iRGB[3])
{
	iRGB[0] = ((iValue >> 16) & 0xFF);
	iRGB[1] = ((iValue >>  8) & 0xFF);
	iRGB[2] = ((iValue      ) & 0xFF);
}

stock void RGBToHex(const int iRGB[3], char[] strHex, int iSize)
{
	FormatEx(strHex, iSize, "%06X", RGBToInt(iRGB));
}

stock int RGBToInt(const int iRGB[3])
{
	return ((iRGB[0] & 0xFF) << 16) |
	       ((iRGB[1] & 0xFF) <<  8) |
	       ((iRGB[2] & 0xFF)      );
}

void Internal_DestroyRocketClasses()
{
	for (int iIndex = 0; iIndex < g_iRocketClassCount; iIndex++)
	{
		g_eSavedRocketClasses[iIndex].Destroy();
	}
	
	g_iRocketClassCount = 0;
}

void Internal_DestroySpawners()
{
	for (int iIndex = 0; iIndex < g_iSpawnersCount; iIndex++)
	{
		g_eSavedSpawnerClasses[iIndex].Destroy();
	}
	
	g_iSpawnersCount  = 0;
}

stock int GetAnalogueTeam(int iTeam)
{
	if (iTeam == view_as<int>(TFTeam_Red)) return view_as<int>(TFTeam_Blue);
	
	return view_as<int>(TFTeam_Red);
}
