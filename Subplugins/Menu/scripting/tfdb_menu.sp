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
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "A pretty big menu for dodgeball"
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

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
	RocketClassMenu_TargetWeight,
	RocketClassMenu_CmdsOnSpawn,
	RocketClassMenu_CmdsOnDeflect,
	RocketClassMenu_CmdsOnKill,
	RocketClassMenu_CmdsOnExplode,
	RocketClassMenu_CmdsOnNoTarget,
	RocketClassMenu_MaxBounces,
	RocketClassMenu_BounceScale,
	RocketClassMenu_OrbitTightness,
	RocketClassMenu_MaxSpeed,
	RocketClassMenu_MaxDeflections,
	RocketClassMenu_SteeringControl,
	RocketClassMenu_BounceControl,
	RocketClassMenu_ThinkInterval,
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
	float          TargetWeight;
	DataPack       CmdsOnSpawn;
	DataPack       CmdsOnDeflect;
	DataPack       CmdsOnKill;
	DataPack       CmdsOnExplode;
	DataPack       CmdsOnNoTarget;
	int            MaxBounces;
	float          BounceScale;
	float          OrbitTightness;
	float          MaxSpeed;
	int            MaxDeflections;
	float          SteeringControlSec;
	float          BounceControlSec;
	float          ThinkInterval;

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

int              RocketClassCount;
int              SpawnersCount;
bool             ClientSayHook         [MAXPLAYERS + 1];
RocketClassMenu  ClientRocketClassMenu [MAXPLAYERS + 1] = {RocketClassMenu_None, ...};
SpawnerClassMenu ClientSpawnerClassMenu[MAXPLAYERS + 1] = {SpawnerClassMenu_None, ...};
int              ClientRocketClass     [MAXPLAYERS + 1] = {-1, ...};
float            ClientMenuSelectTime  [MAXPLAYERS + 1];
RocketClass      SavedRocketClasses    [MAX_ROCKET_CLASSES];
SpawnerClass     SavedSpawnerClasses   [MAX_SPAWNER_CLASSES];
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
	"Target weight",
	"Spawn commands",
	"Deflect commands",
	"Kill commands",
	"Explode commands",
	"No target commands",
	"Maximum bounces",
	"Bounce scale",
	"Orbit tightness",
	"Max speed",
	"Max deflections",
	"Steering control (sec)",
	"Bounce control (sec)",
	"Think interval (sec)"
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

	// Prime TrailsLoaded for servers where Trails loaded before Menu (OnLibraryAdded
	// won't fire retroactively). Sprite menu entries are gated on this flag.
	TrailsLoaded = LibraryExists("tfdbtrails");

	if (!TFDB_IsDodgeballEnabled()) return;
	
	char mapName[64]; GetCurrentMap(mapName, sizeof(mapName));
	GetMapDisplayName(mapName, mapName, sizeof(mapName));
	char strMapFile[PLATFORM_MAX_PATH]; FormatEx(strMapFile, sizeof(strMapFile), "%s.cfg", mapName);
	
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

public void OnClientDisconnect(int client)
{
	ClientSayHook[client]          = false;
	ClientRocketClass[client]      = -1;
	ClientMenuSelectTime[client]   = 0.0;
	ClientRocketClassMenu[client]  = RocketClassMenu_None;
	ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
}

public void OnClientConnected(int client)
{
	ClientSayHook[client]          = false;
	ClientRocketClass[client]      = -1;
	ClientMenuSelectTime[client]   = 0.0;
	ClientRocketClassMenu[client]  = RocketClassMenu_None;
	ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
}

public Action CmdDodgeballMenu(int client, int args)
{
	if (client == 0)
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
	
	menu.SetTitle("What would you like to change?");
	
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
	
	menu.SetTitle("Active rockets :");
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
	
	menu.SetTitle("New rocket target :");
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
				TFDB_SetRocketTarget(index, EntIndexToEntRef(target));
				
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
	
	menu.SetTitle("New rocket class :");
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
	
	menu.SetTitle("Rocket classes :");
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
				
				case RocketClassMenu_BounceScale :
				{
					CPrintToChat(iParam1, "%t", "Menu_BounceScale", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_OrbitTightness :
				{
					CPrintToChat(iParam1, "%t", "Menu_OrbitTightness");
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_MaxSpeed :
				{
					CPrintToChat(iParam1, "%t", "Menu_MaxSpeed");
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_MaxDeflections :
				{
					CPrintToChat(iParam1, "%t", "Menu_MaxDeflections");
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_SteeringControl :
				{
					CPrintToChat(iParam1, "%t", "Menu_SteeringControl", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_BounceControl :
				{
					CPrintToChat(iParam1, "%t", "Menu_BounceControl", CvarSayHookTimeout.IntValue);
					CPrintToChat(iParam1, "%t", "Menu_Reset");
				}

				case RocketClassMenu_ThinkInterval :
				{
					CPrintToChat(iParam1, "%t", "Menu_ThinkInterval", CvarSayHookTimeout.IntValue);
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
	menu.AddItem("6", "No bounce drags", ITEMDRAW_DEFAULT);
	menu.AddItem("7", "Can be stolen", ITEMDRAW_DEFAULT);
	menu.AddItem("8", "Steal team check", ITEMDRAW_DEFAULT);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RocketClassFlagsMenuHandler(Menu menu, MenuAction menuActions, int iParam1, int iParam2)
{
	char buffer[8]; menu.GetItem(0, buffer, sizeof(buffer));
	int  classIndex = StringToInt(buffer);
	
	switch (menuActions)
	{
		case MenuAction_DisplayItem :
		{
			char display[64];
			menu.GetItem(iParam2, buffer, sizeof(buffer), _, display, sizeof(display));
			
			int option = StringToInt(buffer);
			
			switch (option)
			{
				case 1 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_ElevateOnDeflect ? "[X] %s" : "[ ] %s", display);
				}
				
				case 2 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_IsNeutral ? "[X] %s" : "[ ] %s", display);
				}
				
				case 3 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_KeepDirection ? "[X] %s" : "[ ] %s", display);
				}
				
				case 4 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_TeamlessHits ? "[X] %s" : "[ ] %s", display);
				}
				
				case 5 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_ResetBounces ? "[X] %s" : "[ ] %s", display);
				}
				
				case 6 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_NoBounceDrags ? "[X] %s" : "[ ] %s", display);
				}
				
				case 7 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_CanBeStolen ? "[X] %s" : "[ ] %s", display);
				}
				
				case 8 :
				{
					Format(display, sizeof(display), TFDB_GetRocketClassFlags(classIndex) & RocketFlag_StealTeamCheck ? "[X] %s" : "[ ] %s", display);
				}
			}
			
			return RedrawMenuItem(display);
		}
		
		case MenuAction_Select :
		{
			menu.GetItem(iParam2, buffer, sizeof(buffer));
			
			int option = StringToInt(buffer);
			
			switch (option)
			{
				case 1 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_ElevateOnDeflect);
				}
				
				case 2 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_IsNeutral);
				}
				
				case 3 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_KeepDirection);
				}
				
				case 4 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_TeamlessHits);
				}
				
				case 5 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_ResetBounces);
				}
				
				case 6 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_NoBounceDrags);
				}
				
				case 7 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_CanBeStolen);
				}
				
				case 8 :
				{
					TFDB_SetRocketClassFlags(classIndex, TFDB_GetRocketClassFlags(classIndex) ^ RocketFlag_StealTeamCheck);
				}
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
	
	menu.SetTitle("Spawners options :");
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
	
	menu.SetTitle("Rocket classes spawn chances :");
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
	menu.SetTitle("Apply preset:");
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
				CPrintToChatAll("[TFDB] %N applied preset: %s", iParam1, presetName);
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

public Action OnClientSayCommand(int client, const char[] strCommand, const char[] args)
{
	if (!ClientSayHook[client]) return Plugin_Continue;
	
	ClientSayHook[client] = false;
	
	if ((GetGameTime() - ClientMenuSelectTime[client]) > CvarSayHookTimeout.FloatValue) return Plugin_Continue;
	
	if (!((strcmp(strCommand, "say") == 0) || (strcmp(strCommand, "say_team") == 0))) return Plugin_Continue;
	
	RocketClassMenu  iRocketClassOption  = ClientRocketClassMenu[client];
	SpawnerClassMenu iSpawnerClassOption = ClientSpawnerClassMenu[client];
	int rocketClass  = ClientRocketClass[client];
	
	// Sprite options fail fast if Trails subplugin unloaded between menu display
	// and input submission. Natives are MarkNativeAsOptional so compile is fine,
	// but calling an unbound native throws a runtime error.
	if ((iRocketClassOption == RocketClassMenu_SpriteColor ||
	     iRocketClassOption == RocketClassMenu_SpriteLifetime ||
	     iRocketClassOption == RocketClassMenu_SpriteStartWidth ||
	     iRocketClassOption == RocketClassMenu_SpriteEndWidth) && !TrailsLoaded)
	{
		CPrintToChat(client, "{olive}[TFDB]{default} Trails plugin not loaded \u2014 sprite settings unavailable.");
		ClientRocketClassMenu[client]  = RocketClassMenu_None;
		ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
		ClientRocketClass[client]  = -1;
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteLifetime :
		{
			float fLifetime = StringToFloat(args);
			
			TFDB_SetRocketClassSpriteLifetime(rocketClass, fLifetime == -1.0 ? SavedRocketClasses[rocketClass].SpriteLifetime : fLifetime);
			
			LogAction(client, -1, "\"%L\" changed rocket class sprite trail duration to %.2f", client, fLifetime);
			CPrintToChat(client, "%t", "Menu_ChangedSpriteLifetime", fLifetime);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteStartWidth :
		{
			float width = StringToFloat(args);
			
			TFDB_SetRocketClassSpriteStartWidth(rocketClass, width == -1.0 ? SavedRocketClasses[rocketClass].SpriteStartWidth : width);
			
			LogAction(client, -1, "\"%L\" changed rocket class sprite trail start width to %.2f", client, width);
			CPrintToChat(client, "%t", "Menu_ChangedSpriteStartWidth", width);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpriteEndWidth :
		{
			float width = StringToFloat(args);
			
			TFDB_SetRocketClassSpriteEndWidth(rocketClass, width == -1.0 ? SavedRocketClasses[rocketClass].SpriteEndWidth : width);
			
			LogAction(client, -1, "\"%L\" changed rocket class sprite trail end width to %.2f", client, width);
			CPrintToChat(client, "%t", "Menu_ChangedSpriteEndWidth", width);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_CritChance :
		{
			float fChance = StringToFloat(args);
			
			TFDB_SetRocketClassCritChance(rocketClass, fChance == -1.0 ? SavedRocketClasses[rocketClass].CritChance : fChance);
			
			LogAction(client, -1, "\"%L\" changed rocket class critical chance to %.2f", client, fChance);
			CPrintToChat(client, "%t", "Menu_ChangedCritChance", fChance);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_Damage :
		{
			float damage = StringToFloat(args);
			
			TFDB_SetRocketClassDamage(rocketClass, damage == -1.0 ? SavedRocketClasses[rocketClass].Damage : damage);
			
			LogAction(client, -1, "\"%L\" changed rocket class damage to %.2f", client, damage);
			CPrintToChat(client, "%t", "Menu_ChangedDamage", damage);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_DamageIncrement :
		{
			float damage = StringToFloat(args);
			
			TFDB_SetRocketClassDamageIncrement(rocketClass, damage == -1.0 ? SavedRocketClasses[rocketClass].DamageIncrement : damage);
			
			LogAction(client, -1, "\"%L\" changed rocket class damage increment to %.2f", client, damage);
			CPrintToChat(client, "%t", "Menu_ChangedDamageIncrement", damage);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_Speed :
		{
			float speed = StringToFloat(args);
			
			TFDB_SetRocketClassSpeed(rocketClass, speed == -1.0 ? SavedRocketClasses[rocketClass].Speed : speed);
			
			LogAction(client, -1, "\"%L\" changed rocket class speed to %.2f", client, speed);
			CPrintToChat(client, "%t", "Menu_ChangedSpeed", speed);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_SpeedIncrement :
		{
			float speed = StringToFloat(args);
			
			TFDB_SetRocketClassSpeedIncrement(rocketClass, speed == -1.0 ? SavedRocketClasses[rocketClass].SpeedIncrement : speed);
			
			LogAction(client, -1, "\"%L\" changed rocket class speed increment to %.2f", client, speed);
			CPrintToChat(client, "%t", "Menu_ChangedSpeedIncrement", speed);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRate :
		{
			float turnRate = StringToFloat(args);
			
			TFDB_SetRocketClassTurnRate(rocketClass, turnRate == -1.0 ? SavedRocketClasses[rocketClass].TurnRate : turnRate);
			
			LogAction(client, -1, "\"%L\" changed rocket class turn rate to %.2f", client, turnRate);
			CPrintToChat(client, "%t", "Menu_ChangedTurnRate", turnRate);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TurnRateIncrement :
		{
			float turnRate = StringToFloat(args);
			
			TFDB_SetRocketClassTurnRateIncrement(rocketClass, turnRate == -1.0 ? SavedRocketClasses[rocketClass].TurnRateIncrement : turnRate);
			
			LogAction(client, -1, "\"%L\" changed rocket class turn rate increment to %.2f", client, turnRate);
			CPrintToChat(client, "%t", "Menu_ChangedTurnRateIncrement", turnRate);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ElevationRate :
		{
			float fElevation = StringToFloat(args);
			
			TFDB_SetRocketClassElevationRate(rocketClass, fElevation == -1.0 ? SavedRocketClasses[rocketClass].ElevationRate : fElevation);
			
			LogAction(client, -1, "\"%L\" changed rocket class elevation rate to %.2f", client, fElevation);
			CPrintToChat(client, "%t", "Menu_ChangedElevationRate", fElevation);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ElevationLimit :
		{
			float fElevation = StringToFloat(args);
			
			TFDB_SetRocketClassElevationLimit(rocketClass, fElevation == -1.0 ? SavedRocketClasses[rocketClass].ElevationLimit : fElevation);
			
			LogAction(client, -1, "\"%L\" changed rocket class elevation limit to %.2f", client, fElevation);
			CPrintToChat(client, "%t", "Menu_ChangedElevationLimit", fElevation);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_RocketsModifier :
		{
			float modifier = StringToFloat(args);
			
			TFDB_SetRocketClassRocketsModifier(rocketClass, modifier == -1.0 ? SavedRocketClasses[rocketClass].RocketsModifier : modifier);
			
			LogAction(client, -1, "\"%L\" changed rocket class fired rockets modifier to %.2f", client, modifier);
			CPrintToChat(client, "%t", "Menu_ChangedRocketsModifier", modifier);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_PlayerModifier :
		{
			float modifier = StringToFloat(args);
			
			TFDB_SetRocketClassPlayerModifier(rocketClass, modifier == -1.0 ? SavedRocketClasses[rocketClass].PlayerModifier : modifier);
			
			LogAction(client, -1, "\"%L\" changed rocket class player count modifier to %.2f", client, modifier);
			CPrintToChat(client, "%t", "Menu_ChangedPlayerModifier", modifier);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_ControlDelay :
		{
			float fDelay = StringToFloat(args);
			
			TFDB_SetRocketClassControlDelay(rocketClass, fDelay == -1.0 ? SavedRocketClasses[rocketClass].ControlDelay : fDelay);
			
			LogAction(client, -1, "\"%L\" changed rocket class control delay to %.2f", client, fDelay);
			CPrintToChat(client, "%t", "Menu_ChangedControlDelay", fDelay);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_TargetWeight :
		{
			float fWeight = StringToFloat(args);
			
			TFDB_SetRocketClassTargetWeight(rocketClass, fWeight == -1.0 ? SavedRocketClasses[rocketClass].TargetWeight : fWeight);
			
			LogAction(client, -1, "\"%L\" changed rocket class target weight to %.2f", client, fWeight);
			CPrintToChat(client, "%t", "Menu_ChangedTargetWeight", fWeight);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_MaxBounces :
		{
			int iBounces = StringToInt(args);
			
			TFDB_SetRocketClassMaxBounces(rocketClass, iBounces == -1 ? SavedRocketClasses[rocketClass].MaxBounces : iBounces);
			
			LogAction(client, -1, "\"%L\" changed rocket class maximum bounces to %i", client, iBounces);
			CPrintToChat(client, "%t", "Menu_ChangedMaxBounces", iBounces);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}
		
		case RocketClassMenu_BounceScale :
		{
			float fScale = StringToFloat(args);
			
			TFDB_SetRocketClassBounceScale(rocketClass, fScale == -1.0 ? SavedRocketClasses[rocketClass].BounceScale : fScale);
			
			LogAction(client, -1, "\"%L\" changed rocket class bounce scale to %.2f", client, fScale);
			CPrintToChat(client, "%t", "Menu_ChangedBounceScale", fScale);
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
			return Plugin_Stop;
		}

		case RocketClassMenu_OrbitTightness :
		{
			float fTightness = StringToFloat(args);
			TFDB_SetRocketClassOrbitTightness(rocketClass, fTightness == -1.0 ? SavedRocketClasses[rocketClass].OrbitTightness : fTightness);
			LogAction(client, -1, "\"%L\" changed rocket class orbit tightness to %.3f", client, fTightness);
			CPrintToChat(client, "[TFDB] Orbit tightness set to %.3f", fTightness);

			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			return Plugin_Stop;
		}

		case RocketClassMenu_MaxSpeed :
		{
			float fMaxSpeed = StringToFloat(args);
			TFDB_SetRocketClassMaxSpeed(rocketClass, fMaxSpeed == -1.0 ? SavedRocketClasses[rocketClass].MaxSpeed : fMaxSpeed);
			LogAction(client, -1, "\"%L\" changed rocket class max speed to %.2f", client, fMaxSpeed);
			CPrintToChat(client, "[TFDB] Max speed set to %.2f", fMaxSpeed);

			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			return Plugin_Stop;
		}

		case RocketClassMenu_MaxDeflections :
		{
			int iMaxDeflections = StringToInt(args);
			TFDB_SetRocketClassMaxDeflections(rocketClass, iMaxDeflections == -1 ? SavedRocketClasses[rocketClass].MaxDeflections : iMaxDeflections);
			LogAction(client, -1, "\"%L\" changed rocket class max deflections to %i", client, iMaxDeflections);
			CPrintToChat(client, "[TFDB] Max deflections set to %i", iMaxDeflections);

			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			return Plugin_Stop;
		}

		case RocketClassMenu_SteeringControl :
		{
			// Menu input is seconds (matches cfg). Native takes real server ticks.
			float fSec = StringToFloat(args);
			float cachedSec = SavedRocketClasses[rocketClass].SteeringControlSec;
			float useSec = (fSec == -1.0) ? cachedSec : fSec;
			int ticks = (useSec <= 0.0) ? 0 : RoundToNearest(useSec / GetTickInterval());
			if (useSec > 0.0 && ticks < 1) ticks = 1;

			TFDB_SetRocketClassSteeringControl(rocketClass, ticks);

			LogAction(client, -1, "\"%L\" changed rocket class steering control to %.3fs (%d ticks)", client, useSec, ticks);
			CPrintToChat(client, "%t", "Menu_ChangedSteeringControl", useSec);

			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			return Plugin_Stop;
		}

		case RocketClassMenu_BounceControl :
		{
			float fSec = StringToFloat(args);
			float cachedSec = SavedRocketClasses[rocketClass].BounceControlSec;
			float useSec = (fSec == -1.0) ? cachedSec : fSec;
			int ticks = (useSec <= 0.0) ? 0 : RoundToNearest(useSec / GetTickInterval());
			if (useSec > 0.0 && ticks < 1) ticks = 1;

			TFDB_SetRocketClassBounceControl(rocketClass, ticks);

			LogAction(client, -1, "\"%L\" changed rocket class bounce control to %.3fs (%d ticks)", client, useSec, ticks);
			CPrintToChat(client, "%t", "Menu_ChangedBounceControl", useSec);

			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
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

			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
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
			
			ClientRocketClassMenu[client]  = RocketClassMenu_None;
			ClientSpawnerClassMenu[client] = SpawnerClassMenu_None;
			ClientRocketClass[client]  = -1;
			
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
	
	if (kvConfig.ImportFromFile(strPath) == false) SetFailState("[TFDB Menu] Error while parsing configuration file: %s", strPath);
	
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
	char buffer[256];
	
	kvConfig.GotoFirstSubKey();
	do
	{
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
		if (kvConfig.GetNum("no bounce drags", 0) == 1)    flags |= RocketFlag_NoBounceDrags;
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
		SavedRocketClasses[index].SteeringControlSec  = kvConfig.GetFloat("steering control", 0.045);
		SavedRocketClasses[index].BounceControlSec    = kvConfig.GetFloat("bounce control", 0.045);
		SavedRocketClasses[index].ThinkInterval       = kvConfig.GetFloat("think interval", 0.0);
		SavedRocketClasses[index].BounceScale       = kvConfig.GetFloat("bounce scale", 1.0);
		SavedRocketClasses[index].OrbitTightness    = kvConfig.GetFloat("orbit tightness", 0.0);
		SavedRocketClasses[index].MaxSpeed          = kvConfig.GetFloat("max speed", 0.0);
		SavedRocketClasses[index].MaxDeflections    = kvConfig.GetNum("max deflections", 0);
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
	kvConfig.GotoFirstSubKey();
	
	do
	{
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
	       option == RocketClassMenu_CmdsOnExplode  ||
	       option == RocketClassMenu_CmdsOnNoTarget ||
	       (!TrailsLoaded &&
	       (option == RocketClassMenu_SpriteColor    ||
	        option == RocketClassMenu_SpriteEndWidth ||
	        option == RocketClassMenu_SpriteLifetime ||
	        option == RocketClassMenu_SpriteStartWidth));
}

// https://github.com/JoinedSenses/SM-JSLib/blob/main/jslib.inc

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

void Internal_DestroyRocketClasses()
{
	for (int index = 0; index < RocketClassCount; index++)
	{
		SavedRocketClasses[index].Destroy();
	}
	
	RocketClassCount = 0;
}

void Internal_DestroySpawners()
{
	for (int index = 0; index < SpawnersCount; index++)
	{
		SavedSpawnerClasses[index].Destroy();
	}
	
	SpawnersCount  = 0;
}

stock int GetAnalogueTeam(int iTeam)
{
	if (iTeam == view_as<int>(TFTeam_Red)) return view_as<int>(TFTeam_Blue);
	
	return view_as<int>(TFTeam_Red);
}
