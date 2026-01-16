#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] Anti switch"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "Locks the target of any rocket"
#define PLUGIN_VERSION     "1.0.0"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

int Target[MAXPLAYERS + 1] = {-1, ...};
ConVar CvarBotOnly;

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
	CvarBotOnly = CreateConVar("tf_dodgeball_switch_bot", "1", "Lock targets only for bots?", _, true, 0.0, true, 1.0);
}

public void OnClientDisconnect(int iClient)
{
	Target[iClient] = -1;
}

public void OnClientConnected(int iClient)
{
	Target[iClient] = -1;
}

public Action TFDB_OnRocketDeflectPre(int iIndex, int iEntity, int iOwner, int &iTarget)
{
	int iPreviousTarget = EntRefToEntIndex(Target[iOwner]);
	
	if ((iPreviousTarget == -1) ||
	    !IsPlayerAlive(iPreviousTarget) ||
	    (!(TFDB_GetRocketFlags(iIndex) & RocketFlag_IsNeutral) && (GetClientTeam(iOwner) == GetClientTeam(iPreviousTarget))))
	{
		Target[iOwner] = EntIndexToEntRef(iTarget);
		iPreviousTarget = iTarget;
	}
	
	if (!CvarBotOnly.BoolValue || IsFakeClient(iOwner))
	{
		iTarget = iPreviousTarget;
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}
