#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>
#include <adminmenu>
#include <multicolors>

#include <tfdb>
#include <tfdb_clientcheck>

#undef REQUIRE_PLUGIN
#include <tfdbtrails>
#define REQUIRE_PLUGIN

#define PLUGIN_NAME        "[TFDB] Admin menu"
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "A pretty big menu for dodgeball"
#define PLUGIN_VERSION "2.3.0"
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
	RocketClassMenu_CmdsOnSpawnKill,
	RocketClassMenu_CmdsOnExplode,
	RocketClassMenu_CmdsOnNoTarget,
	RocketClassMenu_MaxBounces,
	RocketClassMenu_ThinkInterval,
	RocketClassMenu_BounceCeiling,
	RocketClassMenu_CritGlowStack,
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
	DataPack       CmdsOnSpawnKill;
	DataPack       CmdsOnExplode;
	DataPack       CmdsOnNoTarget;
	int            MaxBounces;
	float          ThinkInterval;
	float          BounceCeiling;
	int            CritGlowStack;

	void Destroy()
	{
		delete this.CmdsOnSpawn;
		delete this.CmdsOnDeflect;
		delete this.CmdsOnKill;
		delete this.CmdsOnSpawnKill;
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
	"Spawn-kill commands",
	"Explode commands",
	"No target commands",
	"Maximum bounces",
	"Think interval (sec)",
	"Deprecated vertical reshape",
	"Crit glow stack"
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


// https://github.com/JoinedSenses/SM-JSLib/blob/main/jslib.inc





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


// === LOCAL INCLUDES ===
#include "include/tfdb_menu_config.inc"
#include "include/tfdb_menu_menus.inc"
#include "include/tfdb_menu_chat.inc"