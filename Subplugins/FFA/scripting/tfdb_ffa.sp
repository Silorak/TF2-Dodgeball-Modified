#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2>
#include <sdktools_functions>
#include <multicolors>

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] Free-for-All"
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "Makes all rockets neutral"
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

bool  Loaded;
bool  FFAEnabled;
int   BotCount;
bool  VoteAllowed;
float LastVoteTime;
int   OldTeam[MAXPLAYERS + 1];

ConVar CvarDisableOnBot;
ConVar CvarVoteTimeout;
ConVar CvarVoteDuration;
ConVar CvarToggleMode;
ConVar CvarAllowStealing;
ConVar CvarDisableConfig;
ConVar CvarEnableConfig;
ConVar CvarSwitchTeams;
ConVar CvarFriendlyFire;

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
	
	CvarDisableOnBot  = CreateConVar("tf_dodgeball_ffa_bot", "1", "Disable FFA when a bot joins?", _, true, 0.0, true, 1.0);
	CvarVoteTimeout   = CreateConVar("tf_dodgeball_ffa_timeout", "150", "Vote timeout (in seconds)", _, true, 0.0);
	CvarVoteDuration  = CreateConVar("tf_dodgeball_ffa_duration", "20", "Vote duration (in seconds)", _, true, 0.0);
	CvarToggleMode    = CreateConVar("tf_dodgeball_ffa_mode", "1", "How does changing FFA affect the rockets?\n 0 - No effect, wait for the next spawn\n 1 - Destroy all active rockets\n 2 - Immediately change the rockets to be neutral", _, true, 0.0);
	CvarAllowStealing = CreateConVar("tf_dodgeball_ffa_stealing", "1", "Allow stealing in FFA mode?", _, true, 0.0, true, 1.0);
	CvarDisableConfig = CreateConVar("tf_dodgeball_ffa_disablecfg", "sourcemod/dodgeball_ffa_disable.cfg", "Config file to execute when disabling FFA mode");
	CvarEnableConfig  = CreateConVar("tf_dodgeball_ffa_enablecfg", "sourcemod/dodgeball_ffa_enable.cfg", "Config file to execute when enabling FFA mode");
	CvarSwitchTeams   = CreateConVar("tf_dodgeball_ffa_teams", "1", "Automatically swap players when a team is empty in FFA mode?", _, true, 0.0, true, 1.0);
	CvarFriendlyFire  = FindConVar("mp_friendlyfire");
	
	RegAdminCmd("sm_ffa", CmdToggleFFA, ADMFLAG_CONFIG, "Forcefully toggle FFA");
	RegConsoleCmd("sm_voteffa", CmdVoteFFA, "Start a vote to toggle FFA");
	
	if (!TFDB_IsDodgeballEnabled()) return;
	
	TFDB_OnRocketsConfigExecuted("general.cfg");
}

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile)
{
	if (Loaded) return;
	
	int savedTeam;
	
	VoteAllowed  = true;
	FFAEnabled   = false;
	BotCount     = 0;
	LastVoteTime = 0.0;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		
		savedTeam = GetClientTeam(client);
		
		if (!(savedTeam >= 2)) continue;
		
		OldTeam[client] = savedTeam;
		
		if (IsFakeClient(client)) BotCount++;
	}
	
	CvarDisableOnBot.AddChangeHook(DisableOnBotCallback);
	
	HookEventEx("player_team", OnPlayerTeam);
	HookEventEx("player_death", OnPlayerDeath);
	HookEventEx("teamplay_round_start", OnRoundStart);
	
	Loaded = true;
}

public void OnMapEnd()
{
	if (!Loaded) return;
	
	Loaded = false;
	
	// Do NOT UnhookEvent here — SM auto-cleans on plugin unload.
	// Manual unhooking causes cascading errors.
	
	CvarDisableOnBot.RemoveChangeHook(DisableOnBotCallback);
	
	VoteAllowed  = false;
	FFAEnabled   = false;
	BotCount     = 0;
	LastVoteTime = 0.0;
	
	CvarFriendlyFire.RestoreDefault();
	ExecuteDisableConfig();
}

public void OnClientDisconnect(int client)
{
	OldTeam[client] = 0;
	
	if (!FFAEnabled ||
	    !CvarSwitchTeams.BoolValue ||
	    (CvarDisableOnBot.BoolValue && BotCount) ||
	    !TFDB_GetRoundStarted())
	{
		return;
	}
	
	int team = GetClientTeam(client);
	
	if (team <= 1) return;
	
	int otherTeam = GetAnalogueTeam(team);
	
	if (((GetTeamAliveClientCount(team) - view_as<int>(IsPlayerAlive(client))) == 0) &&
	    ((GetTeamAliveClientCount(otherTeam) - 1) >= 1))
	{
		ChangeAliveClientTeam(GetRandomTeamAliveClient(otherTeam), team);
	}
}

public void OnClientConnected(int client)
{
	OldTeam[client] = 0;
}

public void OnPlayerTeam(Event event, char[] eventName, bool dontBroadcast)
{
	int client  = GetClientOfUserId(event.GetInt("userid"));
	int team    = event.GetInt("team");
	int oldTeam = event.GetInt("oldteam");
	
	if (!FFAEnabled ||
	    !CvarSwitchTeams.BoolValue ||
	    (CvarDisableOnBot.BoolValue && BotCount) ||
	    !TFDB_GetRoundStarted())
	{
		OldTeam[client] = team;
	}
	else
	{
		// If you swap between RED and BLU, this event gets fired first instead of player_death.
		// This makes GetClientTeam report the new team instead of the old one when used inside a player_death callback.
		
		if (team <= 1)
		{
			OldTeam[client] = team;
		}
		else if ((oldTeam >= 2) &&
		         ((GetTeamAliveClientCount(oldTeam) - view_as<int>(IsPlayerAlive(client))) == 0) &&
		         ((GetTeamAliveClientCount(team) - 1) >= 1))
		{
			ChangeAliveClientTeam(GetRandomTeamAliveClient(team), oldTeam);
		}
	}
	
	if (!IsFakeClient(client)) return;
	
	if ((oldTeam <= 1) && (team >= 2))
	{
		BotCount++;
		
		if (FFAEnabled && (BotCount == 1) && CvarDisableOnBot.BoolValue)
		{
			CPrintToChatAll("%t", "Dodgeball_FFABot_Joined");
			CvarFriendlyFire.RestoreDefault();
			ExecuteDisableConfig();
		}
	}
	else if ((oldTeam >= 2) && (team <= 1))
	{
		BotCount--;
		
		if (FFAEnabled && (BotCount == 0) && CvarDisableOnBot.BoolValue)
		{
			CPrintToChatAll("%t", "Dodgeball_FFABot_Left");
			CvarFriendlyFire.SetBool(true);
			ExecuteEnableConfig();
		}
	}
}

public void OnPlayerDeath(Event event, char[] eventName, bool dontBroadcast)
{
	if (!FFAEnabled ||
	    !CvarSwitchTeams.BoolValue ||
	    (CvarDisableOnBot.BoolValue && BotCount) ||
	    !TFDB_GetRoundStarted())
	{
		return;
	}
	
	int victim = GetClientOfUserId(event.GetInt("userid"));
	
	int team = GetClientTeam(victim);
	
	if (team <= 1) return; // ...
	
	int otherTeam = GetAnalogueTeam(team);
	
	// Checking the alive players count in here doesn't exclude the player that has just died.
	// Doing this check in a SDKHook_OnTakeDamagePost callback excludes him for some reason...
	
	if (((GetTeamAliveClientCount(team) - 1) == 0) && ((GetTeamAliveClientCount(otherTeam) - 1) >= 1))
	{
		ChangeAliveClientTeam(GetRandomTeamAliveClient(otherTeam), team);
	}
}

public void OnRoundStart(Event event, char[] eventName, bool dontBroadcast)
{
	if (!FFAEnabled ||
	    !CvarSwitchTeams.BoolValue ||
	    (CvarDisableOnBot.BoolValue && BotCount))
	{
		return;
	}
	
	int team;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || ((team = GetClientTeam(client)) <= 1)) continue;
		
		if ((OldTeam[client] >= 2) &&
		    (OldTeam[client] != team) &&
		    ((GetTeamAliveClientCount(team) - view_as<int>(IsPlayerAlive(client))) >= 1))
		{
			ChangeClientTeam(client, OldTeam[client]);
		}
		
		if (OldTeam[client] <= 1) OldTeam[client] = team;
	}
}

public Action CmdToggleFFA(int client, int args)
{
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(client, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	ToggleFFA();
	
	return Plugin_Handled;
}

public Action CmdVoteFFA(int client, int args)
{
	if (client == 0)
	{
		// CReplyToCommand prints the message twice...
		ReplyToCommand(client, "Command is in-game only.");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(client, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	if (IsVoteInProgress())
	{
		CReplyToCommand(client, "%t", "Dodgeball_FFAVote_Conflict");
		
		return Plugin_Handled;
	}
	
	if (VoteAllowed)
	{
		VoteAllowed  = false;
		LastVoteTime = GetGameTime();
		
		StartFFAVote();
		CreateTimer(CvarVoteTimeout.FloatValue, VoteTimeoutCallback, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		CReplyToCommand(client, "%t", "Dodgeball_FFAVote_Cooldown",
		                RoundToCeil((LastVoteTime + CvarVoteTimeout.FloatValue) - GetGameTime()));
	}
	
	return Plugin_Handled;
}

public void DisableOnBotCallback(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!FFAEnabled || !BotCount) return;
	
	if (convar.BoolValue)
	{
		CvarFriendlyFire.RestoreDefault();
		ExecuteDisableConfig();
	}
	else
	{
		CvarFriendlyFire.SetBool(true);
		ExecuteEnableConfig();
	}
}

void StartFFAVote()
{
	char mode[16];
	mode = !FFAEnabled ? "Enable" : "Disable";
	
	Menu menu = new Menu(VoteMenuHandler);
	menu.VoteResultCallback = VoteResultHandler;
	
	menu.SetTitle("%s FFA mode?", mode);
	
	menu.AddItem("0", "Yes");
	menu.AddItem("1", "No");
	
	int total;
	int[] clients = new int[MaxClients];
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) <= 1)
		{
			continue;
		}
		
		clients[total++] = client;
	}
	
	menu.DisplayVote(clients, total, CvarVoteDuration.IntValue);
}

public int VoteMenuHandler(Menu menu, MenuAction menuActions, int param1, int param2)
{
	switch (menuActions)
	{
		case MenuAction_End :
		{
			delete menu;
		}
	}
	
	return 0;
}

public void VoteResultHandler(Menu menu,
                              int numVotes,
                              int numClients,
                              const int[][] clientInfo,
                              int numItems,
                              const int[][] itemInfo)
{
	int winnerIndex = 0;
	
	if (numItems > 1 &&
	    (itemInfo[0][VOTEINFO_ITEM_VOTES] == itemInfo[1][VOTEINFO_ITEM_VOTES]))
	{
		winnerIndex = GetRandomInt(0, 1);
	}
	
	char winner[8]; menu.GetItem(itemInfo[winnerIndex][VOTEINFO_ITEM_INDEX], winner, sizeof(winner));
	
	if (StrEqual(winner, "0"))
	{
		ToggleFFA();
	}
	else
	{
		CPrintToChatAll("%t", "Dodgeball_FFAVote_Failed");
	}
}

void EnableFFA()
{
	FFAEnabled = true;
	
	if (CvarDisableOnBot.BoolValue && BotCount)
	{
		CPrintToChatAll("%t", "Dodgeball_FFAVote_LateEnabled");
	}
	else
	{
		CvarFriendlyFire.SetBool(true);
		ExecuteEnableConfig();
		
		switch (CvarToggleMode.IntValue)
		{
			case 1 :
			{
				TFDB_DestroyRockets();
			}
			
			case 2 :
			{
				ChangeRockets();
			}
		}
		
		CPrintToChatAll("%t", "Dodgeball_FFAVote_Enabled");
	}
}

void DisableFFA()
{
	FFAEnabled = false;
	CvarFriendlyFire.RestoreDefault();
	ExecuteDisableConfig();
	
	switch (CvarToggleMode.IntValue)
	{
		case 1 :
		{
			TFDB_DestroyRockets();
		}
		
		case 2 :
		{
			ChangeRockets();
		}
	}
	
	CPrintToChatAll("%t", "Dodgeball_FFAVote_Disabled");
}

void ToggleFFA()
{
	if (!FFAEnabled)
	{
		EnableFFA();
	}
	else
	{
		DisableFFA();
	}
}

void ChangeRockets()
{
	RocketFlags flags, classFlags;
	int entity;
	
	for (int index = 0; index < MAX_ROCKETS; index++)
	{
		if (!TFDB_IsValidRocket(index)) continue;
		
		flags = TFDB_GetRocketFlags(index);
		classFlags = TFDB_GetRocketClassFlags(TFDB_GetRocketClass(index));
		entity = EntRefToEntIndex(TFDB_GetRocketEntity(index));
		
		if (FFAEnabled)
		{
			flags |= RocketFlag_IsNeutral;
			
			if (CvarAllowStealing.BoolValue) flags |= RocketFlag_CanBeStolen;
			
			SetEntProp(entity, Prop_Send, "m_iTeamNum", 1, 1);
			
			TFDB_SetRocketFlags(index, flags);
		}
		else
		{
			if (!(classFlags & RocketFlag_IsNeutral)) flags &= ~RocketFlag_IsNeutral;
			
			if (CvarAllowStealing.BoolValue && !(classFlags & RocketFlag_CanBeStolen)) flags &= ~RocketFlag_CanBeStolen;
			
			int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
			
			if (owner >= 1 && owner <= MaxClients && IsClientInGame(owner))
			{
				SetEntProp(entity, Prop_Send, "m_iTeamNum", GetClientTeam(owner), 1);
			}
			
			TFDB_SetRocketFlags(index, flags);
		}
	}
}

public Action VoteTimeoutCallback(Handle timer)
{
	VoteAllowed = true;
	
	return Plugin_Continue;
}

public Action TFDB_OnRocketCreatedPre(int index, int &rocketClass, RocketFlags &flags)
{
	if (FFAEnabled && (!CvarDisableOnBot.BoolValue || !BotCount))
	{
		flags |= RocketFlag_IsNeutral;
		
		if (CvarAllowStealing.BoolValue) flags |= RocketFlag_CanBeStolen;
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

void ExecuteDisableConfig()
{
	char configPath[64]; CvarDisableConfig.GetString(configPath, sizeof(configPath));
	ServerCommand("exec \"%s\"", configPath);
}

void ExecuteEnableConfig()
{
	char configPath[64]; CvarEnableConfig.GetString(configPath, sizeof(configPath));
	ServerCommand("exec \"%s\"", configPath);
}

int GetTeamAliveClientCount(int team)
{
	int count;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		
		if ((GetClientTeam(client) == team) && IsPlayerAlive(client)) count++;
	}
	
	return count;
}

stock int GetAnalogueTeam(int team)
{
	if (team == view_as<int>(TFTeam_Red)) return view_as<int>(TFTeam_Blue);
	
	return view_as<int>(TFTeam_Red);
}

// https://forums.alliedmods.net/showthread.php?t=286924

int GetRandomTeamAliveClient(int team)
{
	int[] clients = new int[MaxClients];
	int count;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		
		if ((GetClientTeam(client) == team) && IsPlayerAlive(client)) clients[count++] = client;
	}
	
	return count == 0 ? -1 : clients[GetRandomInt(0, count - 1)];
}

// https://forums.alliedmods.net/showthread.php?t=314271

void ChangeAliveClientTeam(int client, int team)
{
	int lifeState = GetEntProp(client, Prop_Send, "m_lifeState");
	SetEntProp(client, Prop_Send, "m_lifeState", 2);
	
	ChangeClientTeam(client, team);
	SetEntProp(client, Prop_Send, "m_lifeState", lifeState);

	// Safer than raw memory walking: update owned wearable entities by classname.
	UpdateClientWearablesTeam(client, team);
}

void UpdateClientWearablesTeam(int client, int team)
{
	static const char wearableClassnames[][] =
	{
		"tf_wearable",
		"tf_wearable_demoshield",
		"tf_powerup_bottle"
	};

	for (int i = 0; i < sizeof(wearableClassnames); i++)
	{
		int entity = -1;
		while ((entity = FindEntityByClassname(entity, wearableClassnames[i])) != -1)
		{
			if (GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") != client) continue;

			SetEntProp(entity, Prop_Send, "m_nSkin", (team == view_as<int>(TFTeam_Blue)) ? 1 : 0);
			SetEntProp(entity, Prop_Send, "m_iTeamNum", team);
		}
	}
}
