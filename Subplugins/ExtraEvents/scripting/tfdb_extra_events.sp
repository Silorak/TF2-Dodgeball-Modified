#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#include <tfdb>
#include <tfdb_clientcheck>

#define PLUGIN_NAME        "[TFDB] Extra events"
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "Adds more events for use with external commands."
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

int RocketClassCount;

DataPack RocketClassCmdsOnDestroyed[MAX_ROCKET_CLASSES];

// Per-rocket flag: true if an OnTouch DataPack has already been queued for this
// rocket on the current frame. SDKHook_Touch fires per-overlap, often many times
// per tick per rocket; the destroy-detection branch in TouchRequestFrame only
// reads "did the entity get freed by next frame?", so one queued check per
// rocket per frame is sufficient. Cleared at the head of TouchRequestFrame and
// on map/config reset.
bool g_TouchPending[MAX_ROCKETS];

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
	
	TFDB_OnRocketsConfigExecuted("general.cfg");
	
	for (int index = 0; index < MAX_ROCKETS; index++)
	{
		if (!TFDB_IsValidRocket(index)) continue;

		// TFDB_GetRocketEntity already unwraps the ent ref internally and returns
		// an entity INDEX. Do NOT wrap it in EntRefToEntIndex again — double-wrapping
		// a raw index returns INVALID_ENT_REFERENCE (raw indices lack the ent-ref magic
		// bits), which makes SDKHook(-1, ...) silently fail on plugin late-load.
		int entity = TFDB_GetRocketEntity(index);
		if (entity > 0 && IsValidEntity(entity))
		{
			SDKHook(entity, SDKHook_Touch, OnTouch);
		}
	}
}

public void TFDB_OnRocketsConfigExecuted(const char[] configFile)
{
	if (!(strcmp(configFile, "general.cfg") == 0)) return;
	
	for (int index = 0; index < RocketClassCount; index++)
	{
		delete RocketClassCmdsOnDestroyed[index];
		RocketClassCmdsOnDestroyed[index] = null;
	}

	RocketClassCount = 0;

	ParseConfigurations(configFile);
}

public void OnMapEnd()
{
	for (int index = 0; index < RocketClassCount; index++)
	{
		delete RocketClassCmdsOnDestroyed[index];
		RocketClassCmdsOnDestroyed[index] = null;
	}

	RocketClassCount = 0;

	// Reset dedupe flags — any RequestFrame still in flight will be discarded
	// on map change, so flags stuck at true would block touches on the next map.
	for (int i = 0; i < sizeof(g_TouchPending); i++) g_TouchPending[i] = false;
}

void ParseConfigurations(const char[] configFile)
{
	char path[PLATFORM_MAX_PATH];
	char fileName[PLATFORM_MAX_PATH];
	FormatEx(fileName, sizeof(fileName), "configs/dodgeball/%s", configFile);
	BuildPath(Path_SM, path, sizeof(path), fileName);
	
	if (!FileExists(path, true)) return;
	
	KeyValues kvConfig = new KeyValues("TF2_Dodgeball");
	
	if (kvConfig.ImportFromFile(path) == false) SetFailState("[TFDB ExtraEvents] Error while parsing configuration file: %s", path);
	
	kvConfig.GotoFirstSubKey();
	
	do
	{
		char section[64]; kvConfig.GetSectionName(section, sizeof(section));
		
		if (StrEqual(section, "classes")) ParseClasses(kvConfig);
	}
	while (kvConfig.GotoNextKey());
	
	delete kvConfig;
}

void ParseClasses(KeyValues kvConfig)
{
	char buffer[256];
	
	kvConfig.GotoFirstSubKey();
	do
	{
		if (RocketClassCount >= MAX_ROCKET_CLASSES)
		{
			LogError("Reached maximum rocket classes (%d). Remaining classes will be ignored.", MAX_ROCKET_CLASSES);
			break;
		}

		int index = RocketClassCount;
		
		kvConfig.GetString("on destroyed", buffer, sizeof(buffer));
		RocketClassCmdsOnDestroyed[index] = ParseCommands(buffer);
		
		RocketClassCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack();
}

DataPack ParseCommands(char[] line)
{
	TrimString(line);
	
	if (!line[0])
	{
		return null;
	}
	
	char strings[8][255];
	int numStrings = ExplodeString(line, ";", strings, 8, 255);
	
	DataPack dataPack = new DataPack();
	dataPack.WriteCell(numStrings);
	
	for (int i = 0; i < numStrings; i++)
	{
		dataPack.WriteString(strings[i]);
	}
	
	return dataPack;
}

void ExecuteCommands(DataPack dataPack,
                     int rocketClass,
                     int rocket,
                     int owner,
                     int target,
                     int lastDead,
                     float speed,
                     int numDeflections,
                     float mphSpeed)
{
	dataPack.Reset(false);
	int numCommands = dataPack.ReadCell();
	
	while (numCommands-- > 0)
	{
		static char cmd[256], buffer[32];
		
		dataPack.ReadString(cmd, sizeof(cmd));
		ReplaceString(cmd, sizeof(cmd), "@name", GetRocketClassLongName(rocketClass));
		FormatEx(buffer, sizeof(buffer), "%i", rocket);                           ReplaceString(cmd, sizeof(cmd), "@rocket", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", owner);                            ReplaceString(cmd, sizeof(cmd), "@owner", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", target);                           ReplaceString(cmd, sizeof(cmd), "@target", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", lastDead);                         ReplaceString(cmd, sizeof(cmd), "@dead", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", numDeflections);                   ReplaceString(cmd, sizeof(cmd), "@deflections", buffer);
		FormatEx(buffer, sizeof(buffer), "%f", speed);                            ReplaceString(cmd, sizeof(cmd), "@speed", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", RoundToNearest(mphSpeed));         ReplaceString(cmd, sizeof(cmd), "@mphspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%i", RoundToNearest(speed * 0.042614)); ReplaceString(cmd, sizeof(cmd), "@capmphspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%f", mphSpeed / 0.042614);              ReplaceString(cmd, sizeof(cmd), "@nocapspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%.2f", speed);                          ReplaceString(cmd, sizeof(cmd), "@2dspeed", buffer);
		FormatEx(buffer, sizeof(buffer), "%.2f", mphSpeed / 0.042614);            ReplaceString(cmd, sizeof(cmd), "@2dnocapspeed", buffer);
		
		ServerCommand(cmd);
	}
}

public void TFDB_OnRocketCreated(int index, int entity)
{
	SDKHook(entity, SDKHook_Touch, OnTouch);
}

public Action OnTouch(int entity, int other)
{
	int index = TFDB_FindRocketByEntity(entity);
	
	if (index == -1) return Plugin_Continue;
	
	int rocketClass = TFDB_GetRocketClass(index);
	if (rocketClass < 0 || rocketClass >= RocketClassCount) return Plugin_Continue;

	if (RocketClassCmdsOnDestroyed[rocketClass] == null) return Plugin_Continue;

	// Dedupe: only one queued check per rocket per frame.
	if (g_TouchPending[index]) return Plugin_Continue;
	g_TouchPending[index] = true;

	DataPack touchInfo = new DataPack();

	touchInfo.WriteCell(index);
	touchInfo.WriteCell(rocketClass);
	touchInfo.WriteCell(EntIndexToEntRef(entity));
	touchInfo.WriteCell(EntIndexToEntRef(GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity")));
	touchInfo.WriteCell(TFDB_GetRocketTarget(index));
	touchInfo.WriteCell(TFDB_GetLastDeadClient());
	touchInfo.WriteFloat(TFDB_GetRocketSpeed(index));
	touchInfo.WriteCell(TFDB_GetRocketEventDeflections(index));
	touchInfo.WriteFloat(TFDB_GetRocketMphSpeed(index));
	touchInfo.WriteCell(((other > 0) && (other <= MaxClients)) ? GetClientUserId(other) : -1);
	
	RequestFrame(TouchRequestFrame, touchInfo);
	
	return Plugin_Continue;
}

public void TouchRequestFrame(DataPack touchInfo)
{
	touchInfo.Reset();

	int index           = touchInfo.ReadCell();
	// Clear the per-rocket dedupe flag first thing, regardless of which branch
	// below we take — if we early-return without clearing, future touches on
	// this rocket index would never re-arm.
	if (index >= 0 && index < MAX_ROCKETS) g_TouchPending[index] = false;

	int rocketClass     = touchInfo.ReadCell();
	int rocket          = EntRefToEntIndex(touchInfo.ReadCell());
	int owner           = EntRefToEntIndex(touchInfo.ReadCell());
	// Re-validate the owner: if the player disconnected between frames,
	// EntRefToEntIndex returns -1 and `@owner` would expand to "-1" —
	// clamp to 0 so substituted commands receive a sentinel instead.
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner))
	{
		owner = 0;
	}
	int target          = touchInfo.ReadCell();
	int lastDead        = touchInfo.ReadCell();
	float speed         = touchInfo.ReadFloat();
	int numDeflections  = touchInfo.ReadCell();
	float mphSpeed      = touchInfo.ReadFloat();
	
	int other           = touchInfo.ReadCell();
	
	delete touchInfo;
	
	if (rocket != -1) return;
	if (rocketClass < 0 || rocketClass >= RocketClassCount) return;
	if (RocketClassCmdsOnDestroyed[rocketClass] == null) return;

	if (other != -1)
	{
		if (((other = GetClientOfUserId(other)) == 0) ||
		    !(IsClientInGame(other) && IsPlayerAlive(other)))
		{
			return;
		}
		
		target = other;
	}
	
	ExecuteCommands(RocketClassCmdsOnDestroyed[rocketClass],
	                rocketClass,
	                rocket,
	                owner,
	                target,
	                lastDead,
	                speed,
	                numDeflections,
	                mphSpeed);
}

char[] GetRocketClassLongName(int rocketClass)
{
	char buffer[32]; TFDB_GetRocketClassLongName(rocketClass, buffer, sizeof(buffer));
	
	return buffer;
}
