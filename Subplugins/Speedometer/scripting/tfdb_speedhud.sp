#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <tfdb> // Include the Dodgeball plugin's natives
#include <clientprefs> // Include for cookie functions
#include <multicolors> // Include for colored chat and translations
#include <tfdb_clientcheck>

#define PLUGIN_VERSION "2.3.0"

public Plugin myinfo =
{
	name = "[TF2] Dodgeball Speed HUD",
	author = "Silorak",
	description = "Displays the speed of active rockets to all players.",
	version = PLUGIN_VERSION,
	url = "https://github.com/Silorak/TF2-Dodgeball"
};

// ====================================================================================================
// Global Variables
// ====================================================================================================

ConVar CvarHudEnabled;
Handle DisplayTimer;
Cookie CookieHudPref; // Cookie for the client's HUD preference.

// Tracks if the HUD is currently being displayed for a client.
bool IsHudVisible[MAXPLAYERS + 1];
// Tracks a client's personal preference for seeing the HUD.
bool HudEnabledForClient[MAXPLAYERS + 1];

// ====================================================================================================
// Plugin Lifecycle
// ====================================================================================================

public void OnPluginStart()
{
	CreateConVar("tfdb_speedhud_version", PLUGIN_VERSION, "Dodgeball Speed HUD Version", FCVAR_NOTIFY|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_DONTRECORD);
	CvarHudEnabled = CreateConVar("tfdb_speedhud_enabled", "1", "Enable the rocket speed HUD for all players.", _, true, 0.0, true, 1.0);

	// Register the command for players to toggle the HUD.
	RegConsoleCmd("sm_speedhud", Command_ToggleHud, "Toggles the rocket speed HUD display.");
	RegConsoleCmd("sm_shud", Command_ToggleHud, "Toggles the rocket speed HUD display."); // Alias

	// Load the translations from the main Dodgeball plugin.
	LoadTranslations("tfdb.phrases.txt");

	// Register the cookie. The second argument is the default value.
	CookieHudPref = new Cookie("tfdb_speedhud_pref", "Toggle for the Dodgeball Speed HUD", CookieAccess_Public);

	// Hook the ConVar change to enable/disable the timer on the fly.
	CvarHudEnabled.AddChangeHook(OnConVarChanged);

	// Hook client connection to load their preference from cookies.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			OnClientPostAdminCheck(i);
		}
	}

	// Start the timer if the plugin is loaded while the cvar is enabled.
	if (CvarHudEnabled.BoolValue)
	{
		StartDisplayTimer();
	}
}

public void OnPluginEnd()
{
	// Clean up the timer when the plugin unloads.
	StopDisplayTimer();
}

public void OnClientDisconnect(int client)
{
	IsHudVisible[client] = false;
	HudEnabledForClient[client] = false;
}

public void OnMapStart()
{
    // Check if the Dodgeball plugin is running and if the HUD is enabled.
    if (LibraryExists("tfdb") && CvarHudEnabled.BoolValue)
    {
        StartDisplayTimer();
    }
}

public void OnMapEnd()
{
	// Clean up the timer at the end of the map.
	StopDisplayTimer();
}

public void OnClientPostAdminCheck(int client)
{
	// Default to ON until cookies are loaded.
	HudEnabledForClient[client] = true;
}

public void OnClientCookiesCached(int client)
{
	// Load the client's preference once cookies are available.
	char sCookie[8];
	GetClientCookie(client, CookieHudPref, sCookie, sizeof(sCookie));

	// Default to ON if the cookie is not set or is set to "1".
	HudEnabledForClient[client] = (sCookie[0] != '0');
}

// ====================================================================================================
// ConVar & Command Management
// ====================================================================================================

public Action Command_ToggleHud(int client, int args)
{
	// Per-client toggle - must reject server console (no cookie/state slot)
	// AND fake clients (a bot somehow invoking this would write to a slot
	// it can't observe).
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		ReplyToCommand(client, "[TFDB] sm_speedhud is an in-game command (real players only).");
		return Plugin_Handled;
	}

	// Flip the player's preference.
	HudEnabledForClient[client] = !HudEnabledForClient[client];

	if (HudEnabledForClient[client])
	{
		// Set cookie to "1" for ON.
		SetClientCookie(client, CookieHudPref, "1");
		CPrintToChat(client, "%t", "Hud_Enabled");
	}
	else
	{
		// Set cookie to "0" for OFF.
		SetClientCookie(client, CookieHudPref, "0");
		CPrintToChat(client, "%t", "Hud_Disabled");
	}

	return Plugin_Handled;
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == CvarHudEnabled)
	{
		if (StringToInt(newValue) == 1)
		{
			StartDisplayTimer();
		}
		else
		{
			StopDisplayTimer();
		}
	}
}

/**
 * Starts the main timer for displaying the HUD.
 */
void StartDisplayTimer()
{
	// Don't create a new timer if one already exists.
	if (DisplayTimer != null)
	{
		return;
	}
	// Create a repeating timer that calls DisplayHud every 0.1 seconds.
	DisplayTimer = CreateTimer(0.1, DisplayHud, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Stops the main display timer and clears the HUD for all players.
 */
void StopDisplayTimer()
{
	if (DisplayTimer != null)
	{
		KillTimer(DisplayTimer);
		DisplayTimer = null;
	}

	// Clear the HUD for any player who might still have it open.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsHudVisible[i])
		{
			// Set an empty message to clear the HUD.
			SetHudTextParams(0.0, 0.0, 0.1, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
			ShowHudText(i, 4, " ");
			IsHudVisible[i] = false;
		}
	}
}

// ====================================================================================================
// Core Logic
// ====================================================================================================

/**
 * Timer callback that runs continuously to update the HUD for all players.
 */
void ClearHudForClient(int client)
{
	if (!IsClientInGame(client) || !IsHudVisible[client]) return;
	SetHudTextParams(0.0, 0.0, 0.1, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
	ShowHudText(client, 4, " ");
	IsHudVisible[client] = false;
}

void ClearAllHud()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		ClearHudForClient(client);
	}
}

public Action DisplayHud(Handle timer)
{
	if (!CvarHudEnabled.BoolValue || !TFDB_IsDodgeballEnabled())
	{
		DisplayTimer = null;
		ClearAllHud();
		return Plugin_Stop;
	}

	if (TFDB_GetRocketCount() <= 0)
	{
		ClearAllHud();
		return Plugin_Continue;
	}

	// Keep only the five fastest rockets; a full sort is unnecessary.
	int rocketIndices[5];
	float rocketSpeeds[5];
	int rocketCount = 0;
	int topCount = 0;

	for (int index = 0; index < MAX_ROCKETS; index++)
	{
		if (!TFDB_IsValidRocket(index)) continue;
		rocketCount++;

		float speed = TFDB_GetRocketMphSpeed(index);
		// Show uncapped MPH if available (keeps stacking past sv_maxvelocity)
		if (GetFeatureStatus(FeatureType_Native, "TFDB_GetRocketRawMphSpeed") == FeatureStatus_Available)
			speed = TFDB_GetRocketRawMphSpeed(index);
		int insertAt = topCount;
		for (int rank = 0; rank < topCount; rank++)
		{
			if (speed > rocketSpeeds[rank])
			{
				insertAt = rank;
				break;
			}
		}
		if (insertAt >= 5) continue;

		int last = topCount < 5 ? topCount : 4;
		for (int rank = last; rank > insertAt; rank--)
		{
			rocketSpeeds[rank] = rocketSpeeds[rank - 1];
			rocketIndices[rank] = rocketIndices[rank - 1];
		}
		rocketSpeeds[insertAt] = speed;
		rocketIndices[insertAt] = index;
		if (topCount < 5) topCount++;
	}

	if (rocketCount == 0)
	{
		ClearAllHud();
		return Plugin_Continue;
	}

	if (rocketCount == 1)
	{
		int rocketIndex = rocketIndices[0];
		float mphSpeed = rocketSpeeds[0];
		float huSpeed = TFDB_GetRocketSpeed(rocketIndex);
		int deflections = TFDB_GetRocketDeflections(rocketIndex);
		int rocketClass = TFDB_GetRocketClass(rocketIndex);
		char className[64];
		TFDB_GetRocketClassLongName(rocketClass, className, sizeof(className));

		char hudMessage[256];
		FormatEx(hudMessage, sizeof(hudMessage), "%t", "Hud_Speedometer", mphSpeed, huSpeed, deflections, rocketIndex + 1, className);

		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client) || IsFakeClient(client)) continue;
			if (!HudEnabledForClient[client])
			{
				ClearHudForClient(client);
				continue;
			}
			SetHudTextParams(-1.0, 0.85, 0.15, 100, 255, 100, 255, 0, 0.0, 0.0, 0.15);
			ShowHudText(client, 4, hudMessage);
			IsHudVisible[client] = true;
		}
		return Plugin_Continue;
	}

	char hudMessage[1024];
	for (int rank = 0; rank < topCount; rank++)
	{
		int rocketIndex = rocketIndices[rank];
		float mphSpeed = rocketSpeeds[rank];
		float huSpeed = TFDB_GetRocketSpeed(rocketIndex);
		int deflections = TFDB_GetRocketDeflections(rocketIndex);
		int rocketClass = TFDB_GetRocketClass(rocketIndex);
		char className[64];
		TFDB_GetRocketClassLongName(rocketClass, className, sizeof(className));

		char line[256];
		Format(line, sizeof(line), "%t\n", "Hud_SpeedometerEx", mphSpeed, huSpeed, deflections, rank + 1, className);
		if (rank == 0) strcopy(hudMessage, sizeof(hudMessage), line);
		else StrCat(hudMessage, sizeof(hudMessage), line);
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		if (!HudEnabledForClient[client])
		{
			ClearHudForClient(client);
			continue;
		}
		SetHudTextParams(0.05, 0.4, 0.15, 100, 255, 100, 255, 0, 0.0, 0.0, 0.15);
		ShowHudText(client, 4, hudMessage);
		IsHudVisible[client] = true;
	}
	return Plugin_Continue;
}
