#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2_stocks>
#include <multicolors>

#include <tfdb>

#define PLUGIN_NAME        "[TFDB] Annotations"
#define PLUGIN_AUTHOR      "Silorak"
#define PLUGIN_DESCRIPTION "Shows floating indicators above rockets visible to target player"
#define PLUGIN_VERSION     "1.0.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball-Modified"

// Configuration variables
bool   g_bAnnotationsEnabled;
float  g_fAnnotationDistance;
float  g_fAnnotationLifetime;

// State tracking
bool   g_bAnnotationVisible[MAX_ROCKETS];

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
	
	if (!TFDB_IsDodgeballEnabled()) return;
	
	TFDB_OnRocketsConfigExecuted("general.cfg");
}

public void OnMapEnd()
{
	for (int i = 0; i < MAX_ROCKETS; i++)
	{
		g_bAnnotationVisible[i] = false;
	}
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
		
		if (StrEqual(strSection, "annotations"))
		{
			ParseAnnotationsConfig(kvConfig);
		}
	}
	while (kvConfig.GotoNextKey());
	
	delete kvConfig;
}

void ParseAnnotationsConfig(KeyValues kvConfig)
{
	g_bAnnotationsEnabled = view_as<bool>(kvConfig.GetNum("enabled", 0));
	g_fAnnotationDistance = kvConfig.GetFloat("distance", 1000.0);
	g_fAnnotationLifetime = kvConfig.GetFloat("lifetime", 1.5);
}

public void TFDB_OnRocketCreated(int iIndex, int iEntity)
{
	if (!g_bAnnotationsEnabled) return;
	
	g_bAnnotationVisible[iIndex] = false;
	
	// Delay showing annotation slightly
	CreateTimer(0.1, Timer_ShowAnnotation, iIndex);
}

public Action Timer_ShowAnnotation(Handle hTimer, int iIndex)
{
	if (!TFDB_IsValidRocket(iIndex)) return Plugin_Stop;
	if (!g_bAnnotationsEnabled) return Plugin_Stop;
	
	int iEntity = EntRefToEntIndex(TFDB_GetRocketEntity(iIndex));
	if (iEntity == -1) return Plugin_Stop;
	
	int iTarget = EntRefToEntIndex(TFDB_GetRocketTarget(iIndex));
	if (!IsValidClient(iTarget, true)) return Plugin_Stop;
	
	// Check distance
	float fClientPos[3], fRocketPos[3];
	GetClientAbsOrigin(iTarget, fClientPos);
	GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", fRocketPos);
	
	if (GetVectorDistance(fClientPos, fRocketPos) < g_fAnnotationDistance)
	{
		return Plugin_Stop;
	}
	
	ShowAnnotation(iIndex, iEntity, iTarget);
	
	return Plugin_Stop;
}

void ShowAnnotation(int iIndex, int iEntity, int iTarget)
{
	Handle hEvent = CreateEvent("show_annotation");
	if (hEvent == INVALID_HANDLE)
	{
		return;
	}
	
	int iClass = TFDB_GetRocketClass(iIndex);
	char strRocketName[64];
	TFDB_GetRocketClassLongName(iClass, strRocketName, sizeof(strRocketName));
	
	char strAnnotation[128];
	Format(strAnnotation, sizeof(strAnnotation), "%t", "Annotation_Rocket", strRocketName);
	
	SetEventInt(hEvent, "follow_entindex", iEntity);
	SetEventFloat(hEvent, "lifetime", g_fAnnotationLifetime);
	SetEventInt(hEvent, "id", iIndex);
	SetEventString(hEvent, "text", strAnnotation);
	SetEventString(hEvent, "play_sound", "vo/null.mp3");
	SetEventInt(hEvent, "visibilityBitfield", 1 << iTarget);
	SetEventBool(hEvent, "show_effect", true);
	FireEvent(hEvent);
	
	g_bAnnotationVisible[iIndex] = true;
}

void HideAnnotation(int iIndex)
{
	Handle hEvent = CreateEvent("hide_annotation");
	if (hEvent == INVALID_HANDLE)
	{
		return;
	}
	
	SetEventInt(hEvent, "id", iIndex);
	FireEvent(hEvent);
	
	g_bAnnotationVisible[iIndex] = false;
}

public void TFDB_OnRocketDeflect(int iIndex, int iEntity, int iOwner)
{
	if (!g_bAnnotationsEnabled) return;
	
	// Hide old annotation
	if (g_bAnnotationVisible[iIndex])
	{
		HideAnnotation(iIndex);
	}
	
	// Show new annotation to new target
	CreateTimer(0.1, Timer_ShowAnnotation, iIndex);
}

// Check if annotation should be hidden when rocket gets close
public void OnGameFrame()
{
	if (!TFDB_IsDodgeballEnabled()) return;
	if (!g_bAnnotationsEnabled) return;
	
	for (int iIndex = 0; iIndex < MAX_ROCKETS; iIndex++)
	{
		if (!TFDB_IsValidRocket(iIndex)) continue;
		if (!g_bAnnotationVisible[iIndex]) continue;
		
		int iEntity = EntRefToEntIndex(TFDB_GetRocketEntity(iIndex));
		if (iEntity == -1) continue;
		
		int iTarget = EntRefToEntIndex(TFDB_GetRocketTarget(iIndex));
		if (!IsValidClient(iTarget, true)) continue;
		
		float fClientPos[3], fRocketPos[3];
		GetClientAbsOrigin(iTarget, fClientPos);
		GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", fRocketPos);
		
		if (GetVectorDistance(fClientPos, fRocketPos) < g_fAnnotationDistance)
		{
			HideAnnotation(iIndex);
		}
	}
}

bool IsValidClient(int iClient, bool bAlive = false)
{
	return iClient >= 1 &&
	       iClient <= MaxClients &&
	       IsClientInGame(iClient) &&
	       (!bAlive || IsPlayerAlive(iClient));
}
