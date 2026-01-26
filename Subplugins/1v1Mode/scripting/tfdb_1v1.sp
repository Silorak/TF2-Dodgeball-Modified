#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2_stocks>
#include <sdkhooks>
#include <multicolors>

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] 1v1 Mode"
#define PLUGIN_AUTHOR      "Silorak"
#define PLUGIN_DESCRIPTION "Adds a 1v1 mode with lives when one player remains per team"
#define PLUGIN_VERSION     "1.0.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball-Modified"

// Configuration variables
bool   g_b1v1Enabled;
int    g_i1v1Lives;
int    g_i1v1Chance;
bool   g_bAllowWithBots;
float  g_f1v1StartDelay;
char   g_strBeepSound[PLATFORM_MAX_PATH];
float  g_fBeepInterval;
char   g_str1v1Music[PLATFORM_MAX_PATH];
char   g_strHeartIcon[16];

// Game state
bool   g_b1v1Active;
int    g_iPlayerLives[MAXPLAYERS + 1];
int    g_iRedPlayer;
int    g_iBluPlayer;

// Timers
Handle g_hBeepTimer[MAXPLAYERS + 1];

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
	
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
	HookEvent("teamplay_round_start", OnRoundStart, EventHookMode_PostNoCopy);
	HookEvent("teamplay_round_win", OnRoundEnd, EventHookMode_PostNoCopy);
	
	if (!TFDB_IsDodgeballEnabled()) return;
	
	TFDB_OnRocketsConfigExecuted("general.cfg");
}

public void OnMapEnd()
{
	Reset1v1State();
}

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile)
{
	if (strcmp(strConfigFile, "general.cfg") != 0) return;
	
	ParseConfiguration();
}

void ParseConfiguration()
{
	char strPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, strPath, sizeof(strPath), "configs/dodgeball/general.cfg");
	
	if (!FileExists(strPath, true)) return;
	
	KeyValues kvConfig = new KeyValues("TF2_Dodgeball");
	if (!kvConfig.ImportFromFile(strPath))
	{
		delete kvConfig;
		return;
	}
	
	kvConfig.GotoFirstSubKey();
	do
	{
		char strSection[64];
		kvConfig.GetSectionName(strSection, sizeof(strSection));
		
		if (StrEqual(strSection, "1v1"))
		{
			Parse1v1Config(kvConfig);
		}
	}
	while (kvConfig.GotoNextKey());
	
	delete kvConfig;
}

void Parse1v1Config(KeyValues kvConfig)
{
	g_b1v1Enabled = view_as<bool>(kvConfig.GetNum("enabled", 0));
	g_i1v1Lives = kvConfig.GetNum("lives", 3);
	g_i1v1Chance = kvConfig.GetNum("chance", 100);
	g_bAllowWithBots = view_as<bool>(kvConfig.GetNum("allow with bots", 1));
	g_f1v1StartDelay = kvConfig.GetFloat("start delay", 3.0);
	
	kvConfig.GetString("beep sound", g_strBeepSound, sizeof(g_strBeepSound));
	g_fBeepInterval = kvConfig.GetFloat("beep interval", 1.5);
	kvConfig.GetString("music", g_str1v1Music, sizeof(g_str1v1Music));
	kvConfig.GetString("heart icon", g_strHeartIcon, sizeof(g_strHeartIcon), "♥");
	
	// Precache sounds
	if (g_strBeepSound[0])
	{
		char strFullPath[PLATFORM_MAX_PATH];
		FormatEx(strFullPath, sizeof(strFullPath), "sound/%s", g_strBeepSound);
		PrecacheSound(g_strBeepSound, true);
	}
	
	if (g_str1v1Music[0])
	{
		PrecacheSound(g_str1v1Music, true);
	}
}

public void OnRoundStart(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	Reset1v1State();
}

public void OnRoundEnd(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	Reset1v1State();
}

void Reset1v1State()
{
	g_b1v1Active = false;
	g_iRedPlayer = -1;
	g_iBluPlayer = -1;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iPlayerLives[i] = 0;
		if (g_hBeepTimer[i] != null)
		{
			KillTimer(g_hBeepTimer[i]);
			g_hBeepTimer[i] = null;
		}
	}
}

public Action OnPlayerDeath(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	if (!TFDB_IsDodgeballEnabled()) return Plugin_Continue;
	if (!g_b1v1Enabled) return Plugin_Continue;
	
	int iVictim = GetClientOfUserId(hEvent.GetInt("userid"));
	if (!IsValidClient(iVictim)) return Plugin_Continue;
	
	// If 1v1 is active, handle lives
	if (g_b1v1Active)
	{
		if (g_iPlayerLives[iVictim] > 1)
		{
			g_iPlayerLives[iVictim]--;
			
			// Announce lost life
			CPrintToChatAll("%t", "1v1_Lost_Life", iVictim, g_iPlayerLives[iVictim]);
			
			// Respawn the player
			CreateTimer(0.1, Timer_RespawnPlayer, GetClientUserId(iVictim));
			
			// Start beeping if at 1 life
			if (g_iPlayerLives[iVictim] == 1 && g_strBeepSound[0])
			{
				g_hBeepTimer[iVictim] = CreateTimer(g_fBeepInterval, Timer_Beep, GetClientUserId(iVictim), TIMER_REPEAT);
			}
			
			// Block the death
			return Plugin_Handled;
		}
		else
		{
			// Player is out of lives, 1v1 ends
			g_b1v1Active = false;
		}
	}
	else
	{
		// Check if this death triggers 1v1
		Check1v1Trigger();
	}
	
	return Plugin_Continue;
}

void Check1v1Trigger()
{
	if (!g_b1v1Enabled) return;
	
	int iRedCount = 0, iBluCount = 0;
	int iRedPlayer = -1, iBluPlayer = -1;
	bool bHasBot = false;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i, true)) continue;
		
		if (IsFakeClient(i))
		{
			bHasBot = true;
		}
		
		int iTeam = GetClientTeam(i);
		if (iTeam == view_as<int>(TFTeam_Red))
		{
			iRedCount++;
			iRedPlayer = i;
		}
		else if (iTeam == view_as<int>(TFTeam_Blue))
		{
			iBluCount++;
			iBluPlayer = i;
		}
	}
	
	// Check if 1v1 should trigger
	if (iRedCount != 1 || iBluCount != 1) return;
	
	// Check bot allowance
	if (bHasBot && !g_bAllowWithBots) return;
	
	// Check chance
	if (g_i1v1Chance < 100 && GetRandomInt(1, 100) > g_i1v1Chance) return;
	
	// Start 1v1!
	Start1v1(iRedPlayer, iBluPlayer);
}

void Start1v1(int iRedPlayer, int iBluPlayer)
{
	g_b1v1Active = true;
	g_iRedPlayer = iRedPlayer;
	g_iBluPlayer = iBluPlayer;
	
	g_iPlayerLives[iRedPlayer] = g_i1v1Lives;
	g_iPlayerLives[iBluPlayer] = g_i1v1Lives;
	
	// Announce 1v1
	CPrintToChatAll("%t", "1v1_Started", iRedPlayer, iBluPlayer);
	
	// Tell each player their lives
	CPrintToChat(iRedPlayer, "%t", "1v1_Lives", g_iPlayerLives[iRedPlayer]);
	CPrintToChat(iBluPlayer, "%t", "1v1_Lives", g_iPlayerLives[iBluPlayer]);
	
	// Show HUD with hearts
	UpdateLivesHud(iRedPlayer);
	UpdateLivesHud(iBluPlayer);
	
	// Play 1v1 music
	if (g_str1v1Music[0])
	{
		EmitSoundToAll(g_str1v1Music, SOUND_FROM_PLAYER, SNDCHAN_MUSIC);
	}
}

void UpdateLivesHud(int iClient)
{
	if (!IsValidClient(iClient)) return;
	
	char strHearts[64];
	for (int i = 0; i < g_iPlayerLives[iClient]; i++)
	{
		StrCat(strHearts, sizeof(strHearts), g_strHeartIcon);
		StrCat(strHearts, sizeof(strHearts), " ");
	}
	
	SetHudTextParams(-1.0, 0.15, 5.0, 255, 50, 50, 255, 0, 0.0, 0.0, 0.0);
	ShowHudText(iClient, -1, "%s", strHearts);
}

public Action Timer_RespawnPlayer(Handle hTimer, any iUserId)
{
	int iClient = GetClientOfUserId(iUserId);
	if (!IsValidClient(iClient)) return Plugin_Stop;
	
	TF2_RespawnPlayer(iClient);
	UpdateLivesHud(iClient);
	
	return Plugin_Stop;
}

public Action Timer_Beep(Handle hTimer, any iUserId)
{
	int iClient = GetClientOfUserId(iUserId);
	if (!IsValidClient(iClient, true))
	{
		g_hBeepTimer[iClient] = null;
		return Plugin_Stop;
	}
	
	if (!g_b1v1Active || g_iPlayerLives[iClient] > 1)
	{
		g_hBeepTimer[iClient] = null;
		return Plugin_Stop;
	}
	
	EmitSoundToClient(iClient, g_strBeepSound);
	return Plugin_Continue;
}

public void OnClientDisconnect(int iClient)
{
	g_iPlayerLives[iClient] = 0;
	if (g_hBeepTimer[iClient] != null)
	{
		KillTimer(g_hBeepTimer[iClient]);
		g_hBeepTimer[iClient] = null;
	}
	
	// If this player was in 1v1, end it
	if (g_b1v1Active && (iClient == g_iRedPlayer || iClient == g_iBluPlayer))
	{
		g_b1v1Active = false;
	}
}

bool IsValidClient(int iClient, bool bAlive = false)
{
	return iClient >= 1 &&
	       iClient <= MaxClients &&
	       IsClientInGame(iClient) &&
	       (!bAlive || IsPlayerAlive(iClient));
}
