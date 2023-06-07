#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] No block"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "Removes collision between enemies."
#define PLUGIN_VERSION     "1.0.3"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

#define COLLISION_GROUP_PUSHAWAY 17

bool g_bLoaded;

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
	if (!TFDB_IsDodgeballEnabled()) return;
	
	TFDB_OnRocketsConfigExecuted();
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient) || !IsPlayerAlive(iClient)) continue;
		
		SetEntProp(iClient, Prop_Data, "m_CollisionGroup", COLLISION_GROUP_PUSHAWAY);
	}
}

public void TFDB_OnRocketsConfigExecuted()
{
	if (g_bLoaded) return;
	
	HookEvent("player_spawn", OnPlayerSpawn);
	
	g_bLoaded = true;
}

public void OnMapEnd()
{
	if (!g_bLoaded) return;
	
	UnhookEvent("player_spawn", OnPlayerSpawn);
	
	g_bLoaded = false;
}

public void OnPlayerSpawn(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	
	if (GetClientTeam(iClient) <= 1) return;
	
	// SetEntityCollisionGroup makes the server crash after a while. No idea why.
	SetEntProp(iClient, Prop_Data, "m_CollisionGroup", COLLISION_GROUP_PUSHAWAY);
}