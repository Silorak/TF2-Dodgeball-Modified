#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#undef REQUIRE_EXTENSIONS
#include <collisionhook>
#define REQUIRE_EXTENSIONS

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] Anti-Sniping & Anti-Teamkilling"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "Blocks snipes and teamkills."
#define PLUGIN_VERSION     "1.2.2"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

ConVar CvarHookDamage;
ConVar CvarHookCollision;

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
	CvarHookDamage    = CreateConVar("tf_dodgeball_as_damage", "1", "Hook damage for anti-sniping?", _, true, 0.0, true, 1.0);
	CvarHookCollision = CreateConVar("tf_dodgeball_as_collision", "1", "Change player collisions for anti-sniping?", _, true, 0.0, true, 1.0);
	
	if (!TFDB_IsDodgeballEnabled()) return;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient)) continue;
		
		SDKHook(iClient, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
	}
}

public void OnClientPutInServer(int iClient)
{
	if (!TFDB_IsDodgeballEnabled()) return;
	
	SDKHook(iClient, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
}

public Action OnPlayerTakeDamage(int iVictim, int &iAttacker, int &iInflictor, float &fDamage, int &iDamageType)
{
	if (!CvarHookDamage.BoolValue) return Plugin_Continue;
	
	int iIndex = TFDB_FindRocketByEntity(iInflictor);
	
	if (iIndex == -1) return Plugin_Continue;
	
	int iTarget = EntRefToEntIndex(TFDB_GetRocketTarget(iIndex));
	
	if (!(IsValidClient(iTarget) && (iVictim != iTarget))) return Plugin_Continue;
	
	fDamage = 0.0;
	
	return Plugin_Changed;
}

public Action CH_PassFilter(int iEntity1, int iEntity2, bool &bResult)
{
	if (!TFDB_IsDodgeballEnabled() || !CvarHookCollision.BoolValue) return Plugin_Continue;
	
	int iIndex1 = TFDB_FindRocketByEntity(iEntity1);
	int iIndex2 = TFDB_FindRocketByEntity(iEntity2);
	
	if (((iIndex1 != -1) && (EntRefToEntIndex(TFDB_GetRocketTarget(iIndex1)) != iEntity2))
	    || ((iIndex2 != -1) && (EntRefToEntIndex(TFDB_GetRocketTarget(iIndex2)) != iEntity1)))
	{
		bResult = false;
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

stock bool IsValidClient(int iClient, bool bAlive = false)
{
	return iClient >= 1 &&
	       iClient <= MaxClients &&
	       IsClientInGame(iClient) &&
	       (!bAlive || IsPlayerAlive(iClient));
}
