#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] Extra events"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "Adds more events for use with external commands."
#define PLUGIN_VERSION     "1.0.1"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

int RocketClassCount;

DataPack RocketClassCmdsOnDestroyed[MAX_ROCKET_CLASSES];

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
	
	for (int iIndex = 0; iIndex < MAX_ROCKETS; iIndex++)
	{
		if (!TFDB_IsValidRocket(iIndex)) continue;
		
		SDKHook(EntRefToEntIndex(TFDB_GetRocketEntity(iIndex)), SDKHook_Touch, OnTouch);
	}
}

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile)
{
	if (!(strcmp(strConfigFile, "general.cfg") == 0)) return;
	
	for (int iIndex = 0; iIndex < RocketClassCount; iIndex++)
	{
		delete RocketClassCmdsOnDestroyed[iIndex];
	}
	
	RocketClassCount = 0;
	
	ParseConfigurations(strConfigFile);
}

public void OnMapEnd()
{
	for (int iIndex = 0; iIndex < RocketClassCount; iIndex++)
	{
		delete RocketClassCmdsOnDestroyed[iIndex];
	}
	
	RocketClassCount = 0;
}

void ParseConfigurations(const char[] strConfigFile)
{
	char strPath[PLATFORM_MAX_PATH];
	char strFileName[PLATFORM_MAX_PATH];
	FormatEx(strFileName, sizeof(strFileName), "configs/dodgeball/%s", strConfigFile);
	BuildPath(Path_SM, strPath, sizeof(strPath), strFileName);
	
	if (!FileExists(strPath, true)) return;
	
	KeyValues kvConfig = new KeyValues("TF2_Dodgeball");
	
	if (kvConfig.ImportFromFile(strPath) == false) SetFailState("Error while parsing the configuration file.");
	
	kvConfig.GotoFirstSubKey();
	
	do
	{
		char strSection[64]; kvConfig.GetSectionName(strSection, sizeof(strSection));
		
		if (StrEqual(strSection, "classes")) ParseClasses(kvConfig);
	}
	while (kvConfig.GotoNextKey());
	
	delete kvConfig;
}

void ParseClasses(KeyValues kvConfig)
{
	char strBuffer[256];
	
	kvConfig.GotoFirstSubKey();
	do
	{
		int iIndex = RocketClassCount;
		
		kvConfig.GetString("on destroyed", strBuffer, sizeof(strBuffer));
		RocketClassCmdsOnDestroyed[iIndex] = ParseCommands(strBuffer);
		
		RocketClassCount++;
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

void ExecuteCommands(DataPack hDataPack,
                     int iClass,
                     int iRocket,
                     int iOwner,
                     int iTarget,
                     int iLastDead,
                     float fSpeed,
                     int iNumDeflections,
                     float fMphSpeed)
{
	hDataPack.Reset(false);
	int iNumCommands = hDataPack.ReadCell();
	
	while (iNumCommands-- > 0)
	{
		static char strCmd[256], strBuffer[32];
		
		hDataPack.ReadString(strCmd, sizeof(strCmd));
		ReplaceString(strCmd, sizeof(strCmd), "@name", GetRocketClassLongName(iClass));
		FormatEx(strBuffer, sizeof(strBuffer), "%i", iRocket);                           ReplaceString(strCmd, sizeof(strCmd), "@rocket", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%i", iOwner);                            ReplaceString(strCmd, sizeof(strCmd), "@owner", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%i", iTarget);                           ReplaceString(strCmd, sizeof(strCmd), "@target", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%i", iLastDead);                         ReplaceString(strCmd, sizeof(strCmd), "@dead", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%i", iNumDeflections);                   ReplaceString(strCmd, sizeof(strCmd), "@deflections", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%f", fSpeed);                            ReplaceString(strCmd, sizeof(strCmd), "@speed", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%i", RoundToNearest(fMphSpeed));         ReplaceString(strCmd, sizeof(strCmd), "@mphspeed", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%i", RoundToNearest(fSpeed * 0.042614)); ReplaceString(strCmd, sizeof(strCmd), "@capmphspeed", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%f", fMphSpeed / 0.042614);              ReplaceString(strCmd, sizeof(strCmd), "@nocapspeed", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%.2f", fSpeed);                          ReplaceString(strCmd, sizeof(strCmd), "@2dspeed", strBuffer);
		FormatEx(strBuffer, sizeof(strBuffer), "%.2f", fMphSpeed / 0.042614);            ReplaceString(strCmd, sizeof(strCmd), "@2dnocapspeed", strBuffer);
		
		ServerCommand(strCmd);
	}
}

public void TFDB_OnRocketCreated(int iIndex, int iEntity)
{
	SDKHook(iEntity, SDKHook_Touch, OnTouch);
}

public Action OnTouch(int iEntity, int iOther)
{
	int iIndex = TFDB_FindRocketByEntity(iEntity);
	
	if (iIndex == -1) return Plugin_Continue;
	
	int iClass = TFDB_GetRocketClass(iIndex);
	
	if (RocketClassCmdsOnDestroyed[iClass] == null) return Plugin_Continue;
	
	DataPack hTouchInfo = new DataPack();
	
	hTouchInfo.WriteCell(iClass);
	hTouchInfo.WriteCell(EntIndexToEntRef(iEntity));
	hTouchInfo.WriteCell(EntIndexToEntRef(GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity")));
	hTouchInfo.WriteCell(TFDB_GetRocketTarget(iIndex));
	hTouchInfo.WriteCell(EntIndexToEntRef(TFDB_GetLastDeadClient()));
	hTouchInfo.WriteCell(TFDB_GetRocketSpeed(iIndex));
	hTouchInfo.WriteCell(TFDB_GetRocketEventDeflections(iIndex));
	hTouchInfo.WriteCell(TFDB_GetRocketMphSpeed(iIndex));
	hTouchInfo.WriteCell(((iOther > 0) && (iOther <= MaxClients)) ? GetClientUserId(iOther) : -1);
	
	RequestFrame(TouchRequestFrame, hTouchInfo);
	
	return Plugin_Continue;
}

public void TouchRequestFrame(DataPack hTouchInfo)
{
	hTouchInfo.Reset();
	
	int iClass          = hTouchInfo.ReadCell();
	int iRocket         = EntRefToEntIndex(hTouchInfo.ReadCell());
	int iOwner          = EntRefToEntIndex(hTouchInfo.ReadCell());
	int iTarget         = EntRefToEntIndex(hTouchInfo.ReadCell());
	int iLastDead       = EntRefToEntIndex(hTouchInfo.ReadCell());
	float fSpeed        = hTouchInfo.ReadCell();
	int iNumDeflections = hTouchInfo.ReadCell();
	float fMphSpeed     = hTouchInfo.ReadCell();
	
	int iOther          = hTouchInfo.ReadCell();
	
	delete hTouchInfo;
	
	if (iRocket != -1) return;
	
	if (iOther != -1)
	{
		if (((iOther = GetClientOfUserId(iOther)) == 0) ||
		    !(IsClientInGame(iOther) && IsPlayerAlive(iOther)))
		{
			return;
		}
		
		iTarget = iOther;
	}
	
	ExecuteCommands(RocketClassCmdsOnDestroyed[iClass],
	                iClass,
	                iRocket,
	                iOwner,
	                iTarget,
	                iLastDead,
	                fSpeed,
	                iNumDeflections,
	                fMphSpeed);
}

char[] GetRocketClassLongName(int iClass)
{
	char strBuffer[32]; TFDB_GetRocketClassLongName(iClass, strBuffer, sizeof(strBuffer));
	
	return strBuffer;
}
