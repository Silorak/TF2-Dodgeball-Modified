#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2_stocks>
#include <multicolors>
#include <sdkhooks>

#include <tfdb>
#include <tfdbtrails>

#define PLUGIN_NAME        "[TFDB] Rocket trails"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "Customizable rocket trails"
#define PLUGIN_VERSION     "1.0.1"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

enum ParticleAttachmentType
{
	PATTACH_ABSORIGIN = 0,    // Create at absorigin, but don't follow
	PATTACH_ABSORIGIN_FOLLOW, // Create at absorigin, and update to follow the entity
	PATTACH_CUSTOMORIGIN,     // Create at a custom origin, but don't follow
	PATTACH_POINT,            // Create on attachment point, but don't follow
	PATTACH_POINT_FOLLOW,     // Create on attachment point, and update to follow the entity
	PATTACH_WORLDORIGIN,      // Used for control points that don't attach to an entity
	PATTACH_ROOTBONE_FOLLOW   // Create at the root bone of the entity, and update to follow
};

int RocketClassCount;

int  EmptyModel;
bool ClientHideTrails [MAXPLAYERS + 1];
bool ClientHideSprites[MAXPLAYERS + 1];
bool ClientShouldSee  [MAXPLAYERS + 1];
bool Loaded;

int RocketFakeEntity       [MAX_ROCKETS] = {-1, ...};
int RocketRedCriticalEntity[MAX_ROCKETS] = {-1, ...};
int RocketBluCriticalEntity[MAX_ROCKETS] = {-1, ...};

char       RocketClassTrail         [MAX_ROCKET_CLASSES][PLATFORM_MAX_PATH];
char       RocketClassSprite        [MAX_ROCKET_CLASSES][PLATFORM_MAX_PATH];
char       RocketClassSpriteColor   [MAX_ROCKET_CLASSES][16];
float      RocketClassSpriteLifetime  [MAX_ROCKET_CLASSES];
float      RocketClassSpriteStartWidth[MAX_ROCKET_CLASSES];
float      RocketClassSpriteEndWidth  [MAX_ROCKET_CLASSES];
float      RocketClassTextureRes      [MAX_ROCKET_CLASSES];
TrailFlags RocketClassTrailFlags      [MAX_ROCKET_CLASSES];

StringMap RocketClassSpriteTrie[MAX_ROCKET_CLASSES];

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
	
	RegConsoleCmd("sm_rockettrails", CmdHideTrails);
	RegConsoleCmd("sm_rocketsprites", CmdHideSprites);
	RegConsoleCmd("sm_hidetrails", CmdHideTrails);
	RegConsoleCmd("sm_hidesprites", CmdHideSprites);
	RegConsoleCmd("sm_toggletrails", CmdHideTrails);
	RegConsoleCmd("sm_togglesprites", CmdHideSprites);
	
	RegConsoleCmd("sm_rocketspritetrails", CmdHideSprites);
	
	if (!TFDB_IsDodgeballEnabled()) return;
	
	TFDB_OnRocketsConfigExecuted("general.cfg");
}

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] strError, int iErrMax)
{
	CreateNative("TFDB_GetRocketFakeEntity", Native_GetRocketFakeEntity);
	CreateNative("TFDB_SetRocketFakeEntity", Native_SetRocketFakeEntity);
	
	CreateNative("TFDB_GetRocketClassTrail", Native_GetRocketClassTrail);
	CreateNative("TFDB_SetRocketClassTrail", Native_SetRocketClassTrail);
	
	CreateNative("TFDB_GetRocketClassSprite", Native_GetRocketClassSprite);
	CreateNative("TFDB_SetRocketClassSprite", Native_SetRocketClassSprite);
	
	CreateNative("TFDB_GetRocketClassSpriteColor", Native_GetRocketClassSpriteColor);
	CreateNative("TFDB_SetRocketClassSpriteColor", Native_SetRocketClassSpriteColor);
	
	CreateNative("TFDB_GetRocketClassSpriteLifetime", Native_GetRocketClassSpriteLifetime);
	CreateNative("TFDB_SetRocketClassSpriteLifetime", Native_SetRocketClassSpriteLifetime);
	
	CreateNative("TFDB_GetRocketClassSpriteStartWidth", Native_GetRocketClassSpriteStartWidth);
	CreateNative("TFDB_SetRocketClassSpriteStartWidth", Native_SetRocketClassSpriteStartWidth);
	
	CreateNative("TFDB_GetRocketClassSpriteEndWidth", Native_GetRocketClassSpriteEndWidth);
	CreateNative("TFDB_SetRocketClassSpriteEndWidth", Native_SetRocketClassSpriteEndWidth);
	
	CreateNative("TFDB_GetRocketClassTextureRes", Native_GetRocketClassTextureRes);
	CreateNative("TFDB_SetRocketClassTextureRes", Native_SetRocketClassTextureRes);
	
	CreateNative("TFDB_GetRocketClassTrailFlags", Native_GetRocketClassTrailFlags);
	CreateNative("TFDB_SetRocketClassTrailFlags", Native_SetRocketClassTrailFlags);
	
	RegPluginLibrary("tfdbtrails");
	
	return APLRes_Success;
}

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile)
{
	if (!Loaded)
	{
		HookEvent("object_deflected", OnObjectDeflected);
		HookEvent("player_team", OnPlayerTeam);
		
		Loaded = true;
	}
	
	if (strcmp(strConfigFile, "general.cfg") == 0)
	{
		for (int iIndex = 0; iIndex < RocketClassCount; iIndex++)
		{
			delete RocketClassSpriteTrie[iIndex];
		}
		
		RocketClassCount = 0;
		
		ParseConfigurations(strConfigFile);
	}
	
	EmptyModel = GetPrecachedModel(EMPTY_MODEL);
	
	GetPrecachedParticle(ROCKET_TRAIL_FIRE);
	
	for (int iIndex = 0; iIndex < RocketClassCount; iIndex++)
	{
		TrailFlags iFlags = RocketClassTrailFlags[iIndex];
		
		if (TestFlags(iFlags, TrailFlag_CustomTrail))  GetPrecachedParticle(RocketClassTrail[iIndex]);
		if (TestFlags(iFlags, TrailFlag_CustomSprite)) GetPrecachedGeneric(RocketClassSprite[iIndex]);
	}
}

public void OnMapEnd()
{
	if (!Loaded) return;
	
	UnhookEvent("object_deflected", OnObjectDeflected);
	UnhookEvent("player_team", OnPlayerTeam);
	
	for (int iIndex = 0; iIndex < RocketClassCount; iIndex++)
	{
		delete RocketClassSpriteTrie[iIndex];
	}
	
	RocketClassCount = 0;
	
	Loaded = false;
}

public void OnClientDisconnect(int iClient)
{
	ClientHideTrails [iClient] = false;
	ClientHideSprites[iClient] = false;
	ClientShouldSee  [iClient] = false;
}

public void OnObjectDeflected(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iEntity = hEvent.GetInt("object_entindex");
	int iIndex  = TFDB_FindRocketByEntity(iEntity);
	
	if (iIndex == -1) return;
	
	int iClass = TFDB_GetRocketClass(iIndex);
	
	if (!(RocketClassTrailFlags[iClass] & TrailFlag_ReplaceParticles)) return;
	
	bool bCritical = !!GetEntProp(iEntity, Prop_Send, "m_bCritical");
	int iTeam = GetEntProp(iEntity, Prop_Send, "m_iTeamNum", 1);
	
	if (bCritical)
	{
		int iRedCriticalEntity = EntRefToEntIndex(RocketRedCriticalEntity[iIndex]);
		int iBluCriticalEntity = EntRefToEntIndex(RocketBluCriticalEntity[iIndex]);
		
		if (iRedCriticalEntity != -1 && iBluCriticalEntity != -1)
		{
			if (iTeam == view_as<int>(TFTeam_Red))
			{
				AcceptEntityInput(iBluCriticalEntity, "Stop");
				AcceptEntityInput(iRedCriticalEntity, "Start");
			}
			else if (iTeam == view_as<int>(TFTeam_Blue))
			{
				AcceptEntityInput(iBluCriticalEntity, "Start");
				AcceptEntityInput(iRedCriticalEntity, "Stop");
			}
		}
	}
	
	int iOtherEntity = EntRefToEntIndex(RocketFakeEntity[iIndex]);
	
	if (iOtherEntity == -1) return;
	
	UpdateRocketSkin(iOtherEntity, iTeam, TestFlags(TFDB_GetRocketFlags(iIndex), RocketFlag_IsNeutral));
}

public void OnPlayerTeam(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	int iOtherEntity = -1;
	int iAttachPoint;
	float fPosition[3];
	ParticleAttachmentType iAttachType;
	
	if (hEvent.GetInt("oldteam") == 0 && !ClientShouldSee[iClient])
	{
		for (int iRocket = 0; iRocket < MAX_ROCKETS; iRocket++)
		{
			if (!(TFDB_IsValidRocket(iRocket) &&
			    (RocketClassTrailFlags[TFDB_GetRocketClass(iRocket)] & TrailFlag_ReplaceParticles))) continue;
			
			iOtherEntity = EntRefToEntIndex(RocketFakeEntity[iRocket]);
			
			if (iOtherEntity == -1) continue;
			
			GetEntPropVector(iOtherEntity, Prop_Send, "m_vecOrigin", fPosition);
			
			iAttachType = PATTACH_POINT_FOLLOW;
			iAttachPoint = 1;
			
			if ((TFDB_GetRocketFlags(iRocket) & RocketFlag_CustomModel) &&
			    ((iAttachPoint = LookupEntityAttachment(iOtherEntity, "trail")) == 0))
			{
				iAttachPoint = -1;
				iAttachType = PATTACH_ABSORIGIN_FOLLOW;
			}
			
			CreateTempParticle(ROCKET_TRAIL_FIRE, fPosition, _, _, iOtherEntity, iAttachType, iAttachPoint);
			TE_SendToClient(iClient);
		}
		
		ClientShouldSee[iClient] = true;
	}
}

public void TFDB_OnRocketCreated(int iIndex, int iEntity)
{
	int iClass = TFDB_GetRocketClass(iIndex);
	int iTeam  = GetAnalogueTeam(GetClientTeam(EntRefToEntIndex(TFDB_GetRocketTarget(iIndex))));
	TrailFlags iFlags = RocketClassTrailFlags[iClass];
	
	float fPosition[3], fAngles[3], fDirection[3];
	GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", fPosition);
	GetEntPropVector(iEntity, Prop_Send, "m_angRotation", fAngles);
	GetAngleVectors(fAngles, fDirection, NULL_VECTOR, NULL_VECTOR);
	
	if (TestFlags(iFlags, TrailFlag_RemoveParticles))
	{
		int iOtherEntity = CreateEntityByName("prop_dynamic");
		
		if (iOtherEntity != -1)
		{
			SetEntProp(iEntity, Prop_Send, "m_nModelIndexOverrides", EmptyModel);
			
			SetEntityModel(iOtherEntity, ROCKET_MODEL);
			SetEntProp(iOtherEntity, Prop_Send, "m_CollisionGroup", 0);    // COLLISION_GROUP_NONE
			SetEntProp(iOtherEntity, Prop_Send, "m_usSolidFlags", 0x0004); // FSOLID_NOT_SOLID
			SetEntProp(iOtherEntity, Prop_Send, "m_nSolidType", 0);        // SOLID_NONE
			TeleportEntity(iOtherEntity, fPosition, fAngles, view_as<float>({0.0, 0.0, 0.0}));
			RocketFakeEntity[iIndex] = EntIndexToEntRef(iOtherEntity);
			DispatchSpawn(iOtherEntity);
			
			SetVariantString("!activator");
			AcceptEntityInput(iOtherEntity, "SetParent", iEntity, iOtherEntity);
			
			if (TestFlags(iFlags, TrailFlag_ReplaceParticles))
			{
				// If the rocket gets instantly destroyed, the temp ent still gets sent. Why?
				CreateTempParticle(ROCKET_TRAIL_FIRE, fPosition, _, _, iOtherEntity, PATTACH_POINT_FOLLOW, 1);
				TE_SendToAll();
				
				bool bCritical = !!GetEntProp(iEntity, Prop_Send, "m_bCritical");
				
				if (bCritical)
				{
					int iRedCriticalEntity = CreateEntityByName("info_particle_system");
					int iBluCriticalEntity = CreateEntityByName("info_particle_system");
					
					if ((iRedCriticalEntity != -1) && (iBluCriticalEntity != -1))
					{
						TeleportEntity(iRedCriticalEntity, fPosition, fAngles, view_as<float>({0.0, 0.0, 0.0}));
						TeleportEntity(iBluCriticalEntity, fPosition, fAngles, view_as<float>({0.0, 0.0, 0.0}));
						
						DispatchKeyValue(iRedCriticalEntity, "effect_name", ROCKET_CRIT_RED);
						DispatchKeyValue(iBluCriticalEntity, "effect_name", ROCKET_CRIT_BLU);
						
						RocketRedCriticalEntity[iIndex] = EntIndexToEntRef(iRedCriticalEntity);
						RocketBluCriticalEntity[iIndex] = EntIndexToEntRef(iBluCriticalEntity);
						
						DispatchSpawn(iRedCriticalEntity);
						DispatchSpawn(iBluCriticalEntity);
						
						ActivateEntity(iRedCriticalEntity);
						ActivateEntity(iBluCriticalEntity);
						
						SetVariantString("!activator");
						AcceptEntityInput(iRedCriticalEntity, "SetParent", iOtherEntity, iRedCriticalEntity);
						
						SetVariantString("!activator");
						AcceptEntityInput(iBluCriticalEntity, "SetParent", iOtherEntity, iBluCriticalEntity);
						
						SetVariantString("trail");
						AcceptEntityInput(iRedCriticalEntity, "SetParentAttachment", iOtherEntity, iRedCriticalEntity);
						
						SetVariantString("trail");
						AcceptEntityInput(iBluCriticalEntity, "SetParentAttachment", iOtherEntity, iBluCriticalEntity);
						
						if (iTeam == view_as<int>(TFTeam_Red))
						{
							AcceptEntityInput(iRedCriticalEntity, "Start");
						}
						else if (iTeam == view_as<int>(TFTeam_Blue))
						{
							AcceptEntityInput(iBluCriticalEntity, "Start");
						}
					}
				}
			}
		}
	}
	
	if (TestFlags(iFlags, TrailFlag_CustomTrail))
	{
		int iTrailEntity = CreateEntityByName("info_particle_system");
		
		if (iTrailEntity != -1)
		{
			TeleportEntity(iTrailEntity, fPosition, fAngles, view_as<float>({0.0, 0.0, 0.0}));
			DispatchKeyValue(iTrailEntity, "effect_name", RocketClassTrail[iClass]);
			DispatchSpawn(iTrailEntity);
			ActivateEntity(iTrailEntity);
			
			if (TestFlags(iFlags, TrailFlag_RemoveParticles))
			{
				int iOtherEntity = EntRefToEntIndex(RocketFakeEntity[iIndex]);
				
				if (iOtherEntity != -1)
				{
					SetVariantString("!activator");
					AcceptEntityInput(iTrailEntity, "SetParent", iOtherEntity, iTrailEntity);
					
					SetVariantString("trail");
					AcceptEntityInput(iTrailEntity, "SetParentAttachment", iOtherEntity, iTrailEntity);
					
					AcceptEntityInput(iTrailEntity, "Start");
				}
			}
			else
			{
				SetVariantString("!activator");
				AcceptEntityInput(iTrailEntity, "SetParent", iEntity, iTrailEntity);
				
				SetVariantString("trail");
				AcceptEntityInput(iTrailEntity, "SetParentAttachment", iEntity, iTrailEntity);
				
				AcceptEntityInput(iTrailEntity, "Start");
			}
			
			// This allows SetTransmit to work on info_particle_system
			SetEdictFlags(iTrailEntity, (GetEdictFlags(iTrailEntity) & ~FL_EDICT_ALWAYS));
			SDKHook(iTrailEntity, SDKHook_SetTransmit, TrailSetTransmit);
		}
	}
	
	if (TestFlags(iFlags, TrailFlag_CustomSprite))
	{
		int iSpriteEntity = CreateEntityByName("env_spritetrail");
		
		if (iSpriteEntity != -1)
		{
			TeleportEntity(iSpriteEntity, fPosition, fAngles, view_as<float>({0.0, 0.0, 0.0}));
			
			DispatchKeyValue(iSpriteEntity, "spritename", RocketClassSprite[iClass]);
			DispatchKeyValueFloat(iSpriteEntity, "lifetime", RocketClassSpriteLifetime[iClass] != 0 ? RocketClassSpriteLifetime[iClass] : 1.0);
			DispatchKeyValueFloat(iSpriteEntity, "endwidth", RocketClassSpriteEndWidth[iClass] != 0 ? RocketClassSpriteEndWidth[iClass] : 15.0);
			DispatchKeyValueFloat(iSpriteEntity, "startwidth", RocketClassSpriteStartWidth[iClass] != 0 ? RocketClassSpriteStartWidth[iClass] : 6.0);
			DispatchKeyValue(iSpriteEntity, "rendercolor", strlen(RocketClassSpriteColor[iClass]) != 0 ? RocketClassSpriteColor[iClass] : "255 255 255");
			DispatchKeyValue(iSpriteEntity, "renderamt", "255");
			DispatchKeyValue(iSpriteEntity, "rendermode", "3");
			SetEntPropFloat(iSpriteEntity, Prop_Send, "m_flTextureRes", RocketClassTextureRes[iClass]);
			
			if (RocketClassSpriteTrie[iClass] != null)
			{
				StringMapSnapshot hSpriteEntitySnap = RocketClassSpriteTrie[iClass].Snapshot();
				
				int iSnapSize = hSpriteEntitySnap.Length;
				char strKey[256];
				char strValue[256];
				
				for (int iEntry = 0; iEntry < iSnapSize; iEntry++)
				{
					hSpriteEntitySnap.GetKey(iEntry, strKey, sizeof(strKey));
					RocketClassSpriteTrie[iClass].GetString(strKey, strValue, sizeof(strValue));
					DispatchKeyValue(iSpriteEntity, strKey, strValue);
				}
				
				delete hSpriteEntitySnap;
			}
			
			if (TestFlags(iFlags, TrailFlag_RemoveParticles))
			{
				int iOtherEntity = EntRefToEntIndex(RocketFakeEntity[iIndex]);
				
				if (iOtherEntity != -1)
				{
					SetVariantString("!activator");
					AcceptEntityInput(iSpriteEntity, "SetParent", iOtherEntity, iSpriteEntity);
					
					SetVariantString("trail");
					AcceptEntityInput(iSpriteEntity, "SetParentAttachment", iOtherEntity, iSpriteEntity);
				}
			}
			else
			{
				SetVariantString("!activator");
				AcceptEntityInput(iSpriteEntity, "SetParent", iEntity, iSpriteEntity);
				
				SetVariantString("trail");
				AcceptEntityInput(iSpriteEntity, "SetParentAttachment", iEntity, iSpriteEntity);
			}
			
			DispatchSpawn(iSpriteEntity);
			SDKHook(iSpriteEntity, SDKHook_SetTransmit, SpriteSetTransmit);
		}
	}
	
	RocketFlags iRocketFlags = TFDB_GetRocketFlags(iIndex);
	
	if (TestFlags(iFlags, TrailFlag_RemoveParticles) && TestFlags(iRocketFlags, RocketFlag_CustomModel))
	{
		char strCustomModel[PLATFORM_MAX_PATH]; TFDB_GetRocketClassModel(iClass, strCustomModel, sizeof(strCustomModel));
		int iOtherEntity = EntRefToEntIndex(RocketFakeEntity[iIndex]);
		
		SetEntityModel(iOtherEntity, strCustomModel);
		UpdateRocketSkin(iOtherEntity, iTeam, TestFlags(iRocketFlags, RocketFlag_IsNeutral));
	}
}

public Action TrailSetTransmit(int iEntity, int iClient)
{
	if (GetEdictFlags(iEntity) & FL_EDICT_ALWAYS)
	{
		// Stops the game from setting back the flag
		SetEdictFlags(iEntity, (GetEdictFlags(iEntity) ^ FL_EDICT_ALWAYS));
	}
	
	return ClientHideTrails[iClient] ? Plugin_Handled : Plugin_Continue;
}

public Action SpriteSetTransmit(int iEntity, int iClient)
{
	return ClientHideSprites[iClient] ? Plugin_Handled : Plugin_Continue;
}

public Action CmdHideTrails(int iClient, int iArgs)
{
	if (iClient == 0)
	{
		ReplyToCommand(iClient, "Command is in-game only.");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	if (iArgs)
	{
		CReplyToCommand(iClient, "%t", "Command_DBHideParticles_Usage");
		
		return Plugin_Handled;
	}
	
	ClientHideTrails[iClient] = !ClientHideTrails[iClient];
	
	CPrintToChat(iClient, "%t", ClientHideTrails[iClient] ? "Command_DBHideParticles_Hidden" : "Command_DBHideParticles_Visible");
	
	return Plugin_Handled;
}

public Action CmdHideSprites(int iClient, int iArgs)
{
	if (iClient == 0)
	{
		ReplyToCommand(iClient, "Command is in-game only.");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	if (iArgs)
	{
		CReplyToCommand(iClient, "%t", "Command_DBHideSprites_Usage");
		
		return Plugin_Handled;
	}
	
	ClientHideSprites[iClient] = !ClientHideSprites[iClient];
	
	CPrintToChat(iClient, "%t", ClientHideSprites[iClient] ? "Command_DBHideSprites_Hidden" : "Command_DBHideSprites_Visible");
	
	return Plugin_Handled;
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
	kvConfig.GotoFirstSubKey();
	do
	{
		int iIndex = RocketClassCount;
		TrailFlags iFlags;
		
		kvConfig.GetString("trail particle", RocketClassTrail[iIndex], sizeof(RocketClassTrail[]));
		
		if (RocketClassTrail[iIndex][0]) iFlags |= TrailFlag_CustomTrail;
		
		kvConfig.GetString("trail sprite", RocketClassSprite[iIndex], sizeof(RocketClassSprite[]));
		
		if (RocketClassSprite[iIndex][0])
		{
			iFlags |= TrailFlag_CustomSprite;
			
			kvConfig.GetString("custom color", RocketClassSpriteColor[iIndex], sizeof(RocketClassSpriteColor[]));
			
			RocketClassSpriteLifetime[iIndex]   = kvConfig.GetFloat("sprite lifetime");
			RocketClassSpriteStartWidth[iIndex] = kvConfig.GetFloat("sprite start width");
			RocketClassSpriteEndWidth[iIndex]   = kvConfig.GetFloat("sprite end width");
			RocketClassTextureRes[iIndex]       = kvConfig.GetFloat("texture resolution", 0.05);
			
			if (kvConfig.JumpToKey("entity keyvalues"))
			{
				RocketClassSpriteTrie[iIndex] = ParseSpriteEntity(kvConfig);
				
				kvConfig.GoBack();
			}
		}
		
		if (kvConfig.GetNum("remove particles", 0))
		{
			iFlags |= TrailFlag_RemoveParticles;
			
			if (kvConfig.GetNum("replace particles", 0)) iFlags |= TrailFlag_ReplaceParticles;
		}
		
		RocketClassTrailFlags[iIndex] = iFlags;
		RocketClassCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack();
}

StringMap ParseSpriteEntity(KeyValues kvConfig)
{
	char strBuffer[256], strValue[256];
	StringMap hBufferMap = new StringMap();
	
	kvConfig.GotoFirstSubKey(false);
	do
	{
		kvConfig.GetSectionName(strBuffer, sizeof(strBuffer));
		kvConfig.GetString(NULL_STRING, strValue, sizeof(strValue));
		
		hBufferMap.SetString(strBuffer, strValue);
	}
	while (kvConfig.GotoNextKey(false));
	
	kvConfig.GoBack();
	
	return hBufferMap;
}

void UpdateRocketSkin(int iEntity, int iTeam, bool bNeutral)
{
	if (bNeutral) SetEntProp(iEntity, Prop_Send, "m_nSkin", 2);
	else          SetEntProp(iEntity, Prop_Send, "m_nSkin", (iTeam == view_as<int>(TFTeam_Blue)) ? 0 : 1);
}

stock int GetAnalogueTeam(int iTeam)
{
	if (iTeam == view_as<int>(TFTeam_Red)) return view_as<int>(TFTeam_Blue);
	
	return view_as<int>(TFTeam_Red);
}

stock int GetPrecachedModel(const char[] strModel)
{
	static int iModelPrecache = INVALID_STRING_TABLE;
	
	if ((iModelPrecache == INVALID_STRING_TABLE) &&
	    ((iModelPrecache = FindStringTable("modelprecache")) == INVALID_STRING_TABLE))
	{
		return INVALID_STRING_INDEX;
	}
	
	int iModelIndex = FindStringIndex(iModelPrecache, strModel);
	
	if (iModelIndex == INVALID_STRING_INDEX)
	{
		iModelIndex = PrecacheModel(strModel, true);
	}
	
	return iModelIndex;
}

stock int GetPrecachedParticle(const char[] strParticleSystem)
{
	static int iParticleEffectNames = INVALID_STRING_TABLE;
	
	if ((iParticleEffectNames == INVALID_STRING_TABLE) &&
	    ((iParticleEffectNames = FindStringTable("ParticleEffectNames")) == INVALID_STRING_TABLE))
	{
		return INVALID_STRING_INDEX;
	}
	
	int iParticleIndex = FindStringIndex(iParticleEffectNames, strParticleSystem);
	
	if (iParticleIndex == INVALID_STRING_INDEX)
	{
		int iNumStrings = GetStringTableNumStrings(iParticleEffectNames);
		
		if (iNumStrings >= GetStringTableMaxStrings(iParticleEffectNames))
		{
			return INVALID_STRING_INDEX;
		}
		
		AddToStringTable(iParticleEffectNames, strParticleSystem);
		iParticleIndex = iNumStrings;
	}
	
	return iParticleIndex;
}

stock int GetPrecachedGeneric(const char[] strGeneric)
{
	static int iGenericPrecache = INVALID_STRING_TABLE;
	
	if ((iGenericPrecache == INVALID_STRING_TABLE) &&
	    ((iGenericPrecache = FindStringTable("genericprecache")) == INVALID_STRING_TABLE))
	{
		return INVALID_STRING_INDEX;
	}
	
	int iGenericIndex = FindStringIndex(iGenericPrecache, strGeneric);
	
	if (iGenericIndex == INVALID_STRING_INDEX)
	{
		iGenericIndex = PrecacheGeneric(strGeneric, true);
	}
	
	return iGenericIndex;
}

// https://forums.alliedmods.net/showthread.php?t=75102

stock void CreateTempParticle(const char[] strParticle,
                              const float vecOrigin[3] = NULL_VECTOR,
                              const float vecStart[3] = NULL_VECTOR,
                              const float vecAngles[3] = NULL_VECTOR,
                              int iEntity = -1,
                              ParticleAttachmentType AttachmentType = PATTACH_ABSORIGIN,
                              int iAttachmentPoint = -1,
                              bool bResetParticles = false)
{
	int iParticleIndex = GetPrecachedParticle(strParticle);
	if (iParticleIndex == INVALID_STRING_INDEX)
	{
		ThrowError("Could not find particle index: %s", strParticle);
	}
	
	TE_Start("TFParticleEffect");
	TE_WriteFloat("m_vecOrigin[0]", vecOrigin[0]);
	TE_WriteFloat("m_vecOrigin[1]", vecOrigin[1]);
	TE_WriteFloat("m_vecOrigin[2]", vecOrigin[2]);
	TE_WriteFloat("m_vecStart[0]", vecStart[0]);
	TE_WriteFloat("m_vecStart[1]", vecStart[1]);
	TE_WriteFloat("m_vecStart[2]", vecStart[2]);
	TE_WriteVector("m_vecAngles", vecAngles);
	TE_WriteNum("m_iParticleSystemIndex", iParticleIndex);
	
	if (iEntity != -1)
	{
		TE_WriteNum("entindex", iEntity);
	}
	
	if (AttachmentType != PATTACH_ABSORIGIN)
	{
		TE_WriteNum("m_iAttachType", view_as<int>(AttachmentType));
	}
	
	if (iAttachmentPoint != -1)
	{
		TE_WriteNum("m_iAttachmentPointIndex", iAttachmentPoint);
	}
	
	TE_WriteNum("m_bResetParticles", bResetParticles ? 1 : 0);
}

public any Native_GetRocketFakeEntity(Handle hPlugin, int iNumParams)
{
	int iIndex = GetNativeCell(1);
	
	return RocketFakeEntity[iIndex];
}

public any Native_SetRocketFakeEntity(Handle hPlugin, int iNumParams)
{
	int iIndex = GetNativeCell(1);
	
	int iFakeEntity = GetNativeCell(2);
	
	RocketFakeEntity[iIndex] = iFakeEntity;
	
	return 0;
}

public any Native_GetRocketClassTrail(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	int iMaxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassTrail[iClass], iMaxLen);
	
	return 0;
}

public any Native_SetRocketClassTrail(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	int iMaxLen; GetNativeStringLength(2, iMaxLen);
	
	char[] strBuffer = new char[iMaxLen + 1]; GetNativeString(2, strBuffer, iMaxLen + 1);
	
	strcopy(RocketClassTrail[iClass], sizeof(RocketClassTrail[]), strBuffer);
	
	return 0;
}

public any Native_GetRocketClassSprite(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	int iMaxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassSprite[iClass], iMaxLen);
	
	return 0;
}

public any Native_SetRocketClassSprite(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	int iMaxLen; GetNativeStringLength(2, iMaxLen);
	
	char[] strBuffer = new char[iMaxLen + 1]; GetNativeString(2, strBuffer, iMaxLen + 1);
	
	strcopy(RocketClassSprite[iClass], sizeof(RocketClassSprite[]), strBuffer);
	
	return 0;
}

public any Native_GetRocketClassSpriteColor(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	int iMaxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassSpriteColor[iClass], iMaxLen);
	
	return 0;
}

public any Native_SetRocketClassSpriteColor(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	int iMaxLen; GetNativeStringLength(2, iMaxLen);
	
	char[] strBuffer = new char[iMaxLen + 1]; GetNativeString(2, strBuffer, iMaxLen + 1);
	
	strcopy(RocketClassSpriteColor[iClass], sizeof(RocketClassSpriteColor[]), strBuffer);
	
	return 0;
}

public any Native_GetRocketClassSpriteLifetime(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	return RocketClassSpriteLifetime[iClass];
}

public any Native_SetRocketClassSpriteLifetime(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	float fLifetime = GetNativeCell(2);
	
	RocketClassSpriteLifetime[iClass] = fLifetime;
	
	return 0;
}

public any Native_GetRocketClassSpriteStartWidth(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	return RocketClassSpriteStartWidth[iClass];
}

public any Native_SetRocketClassSpriteStartWidth(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	float fWidth = GetNativeCell(2);
	
	RocketClassSpriteStartWidth[iClass] = fWidth;
	
	return 0;
}

public any Native_GetRocketClassSpriteEndWidth(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	return RocketClassSpriteEndWidth[iClass];
}

public any Native_SetRocketClassSpriteEndWidth(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	float fWidth = GetNativeCell(2);
	
	RocketClassSpriteEndWidth[iClass] = fWidth;
	
	return 0;
}

public any Native_GetRocketClassTextureRes(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	return RocketClassTextureRes[iClass];
}

public any Native_SetRocketClassTextureRes(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	float fResolution = GetNativeCell(2);
	
	RocketClassTextureRes[iClass] = fResolution;
	
	return 0;
}

public any Native_GetRocketClassTrailFlags(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	return RocketClassTrailFlags[iClass];
}

public any Native_SetRocketClassTrailFlags(Handle hPlugin, int iNumParams)
{
	int iClass = GetNativeCell(1);
	
	TrailFlags iFlags = GetNativeCell(2);
	
	RocketClassTrailFlags[iClass] = iFlags;
	
	return 0;
}
