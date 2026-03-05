#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#undef REQUIRE_EXTENSIONS
#include <collisionhook>
#define REQUIRE_EXTENSIONS

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] Anti-Sniping & Anti-Teamkilling"
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "Blocks snipes and teamkills."
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball-Modified"

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
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		
		SDKHook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
	}
}

public void OnClientPutInServer(int client)
{
	if (!TFDB_IsDodgeballEnabled()) return;
	
	SDKHook(client, SDKHook_OnTakeDamage, OnPlayerTakeDamage);
}

public Action OnPlayerTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damageType)
{
	if (!CvarHookDamage.BoolValue) return Plugin_Continue;
	
	int index = TFDB_FindRocketByEntity(inflictor);
	
	if (index == -1) return Plugin_Continue;
	
	int target = EntRefToEntIndex(TFDB_GetRocketTarget(index));
	
	if (!(IsValidClient(target) && (victim != target))) return Plugin_Continue;
	
	damage = 0.0;
	
	return Plugin_Changed;
}

public Action CH_PassFilter(int entity1, int entity2, bool &result)
{
	if (!TFDB_IsDodgeballEnabled() || !CvarHookCollision.BoolValue) return Plugin_Continue;
	
	int index1 = TFDB_FindRocketByEntity(entity1);
	int index2 = TFDB_FindRocketByEntity(entity2);
	
	if (((index1 != -1) && (EntRefToEntIndex(TFDB_GetRocketTarget(index1)) != entity2))
	    || ((index2 != -1) && (EntRefToEntIndex(TFDB_GetRocketTarget(index2)) != entity1)))
	{
		result = false;
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

stock bool IsValidClient(int client, bool alive = false)
{
	return client >= 1 &&
	       client <= MaxClients &&
	       IsClientInGame(client) &&
	       (!alive || IsPlayerAlive(client));
}
