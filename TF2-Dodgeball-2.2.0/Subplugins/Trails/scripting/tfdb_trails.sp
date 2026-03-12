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
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "Customizable rocket trails"
#define PLUGIN_VERSION     "2.2.0"
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

public void TFDB_OnRocketsConfigExecuted(const char[] configFile)
{
	if (!Loaded)
	{
		HookEvent("object_deflected", OnObjectDeflected);
		HookEvent("player_team", OnPlayerTeam);
		
		Loaded = true;
	}
	
	if (strcmp(configFile, "general.cfg") == 0)
	{
		for (int index = 0; index < RocketClassCount; index++)
		{
			delete RocketClassSpriteTrie[index];
		}
		
		RocketClassCount = 0;
		
		ParseConfigurations(configFile);
	}
	
	EmptyModel = GetPrecachedModel(EMPTY_MODEL);
	
	GetPrecachedParticle(ROCKET_TRAIL_FIRE);
	
	for (int index = 0; index < RocketClassCount; index++)
	{
		TrailFlags flags = RocketClassTrailFlags[index];
		
		if (TestFlags(flags, TrailFlag_CustomTrail))  GetPrecachedParticle(RocketClassTrail[index]);
		if (TestFlags(flags, TrailFlag_CustomSprite)) GetPrecachedGeneric(RocketClassSprite[index]);
	}
}

public void OnMapEnd()
{
	if (!Loaded) return;
	
	UnhookEvent("object_deflected", OnObjectDeflected);
	UnhookEvent("player_team", OnPlayerTeam);
	
	for (int index = 0; index < RocketClassCount; index++)
	{
		delete RocketClassSpriteTrie[index];
	}
	
	RocketClassCount = 0;
	
	Loaded = false;
}

public void OnClientDisconnect(int client)
{
	ClientHideTrails [client] = false;
	ClientHideSprites[client] = false;
	ClientShouldSee  [client] = false;
}

public void OnObjectDeflected(Event event, char[] eventName, bool dontBroadcast)
{
	int entity = event.GetInt("object_entindex");
	int index  = TFDB_FindRocketByEntity(entity);
	
	if (index == -1) return;
	
	int classIndex = TFDB_GetRocketClass(index);
	
	if (!(RocketClassTrailFlags[classIndex] & TrailFlag_ReplaceParticles)) return;
	
	bool critical = !!GetEntProp(entity, Prop_Send, "m_bCritical");
	int team = GetEntProp(entity, Prop_Send, "m_iTeamNum", 1);
	
	if (critical)
	{
		int redCritEntity = EntRefToEntIndex(RocketRedCriticalEntity[index]);
		int bluCritEntity = EntRefToEntIndex(RocketBluCriticalEntity[index]);
		
		if (redCritEntity != -1 && bluCritEntity != -1)
		{
			if (team == view_as<int>(TFTeam_Red))
			{
				AcceptEntityInput(bluCritEntity, "Stop");
				AcceptEntityInput(redCritEntity, "Start");
			}
			else if (team == view_as<int>(TFTeam_Blue))
			{
				AcceptEntityInput(bluCritEntity, "Start");
				AcceptEntityInput(redCritEntity, "Stop");
			}
		}
	}
	
	int fakeEntity = EntRefToEntIndex(RocketFakeEntity[index]);
	
	if (fakeEntity == -1) return;
	
	UpdateRocketSkin(fakeEntity, team, TestFlags(TFDB_GetRocketFlags(index), RocketFlag_IsNeutral));
}

public void OnPlayerTeam(Event event, char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int fakeEntity = -1;
	int attachPoint;
	float position[3];
	ParticleAttachmentType attachType;
	
	if (event.GetInt("oldteam") == 0 && !ClientShouldSee[client])
	{
		for (int rocket = 0; rocket < MAX_ROCKETS; rocket++)
		{
			if (!(TFDB_IsValidRocket(rocket) &&
			    (RocketClassTrailFlags[TFDB_GetRocketClass(rocket)] & TrailFlag_ReplaceParticles))) continue;
			
			fakeEntity = EntRefToEntIndex(RocketFakeEntity[rocket]);
			
			if (fakeEntity == -1) continue;
			
			GetEntPropVector(fakeEntity, Prop_Send, "m_vecOrigin", position);
			
			attachType = PATTACH_POINT_FOLLOW;
			attachPoint = 1;
			
			if ((TFDB_GetRocketFlags(rocket) & RocketFlag_CustomModel) &&
			    ((attachPoint = LookupEntityAttachment(fakeEntity, "trail")) == 0))
			{
				attachPoint = -1;
				attachType = PATTACH_ABSORIGIN_FOLLOW;
			}
			
			CreateTempParticle(ROCKET_TRAIL_FIRE, position, _, _, fakeEntity, attachType, attachPoint);
			TE_SendToClient(client);
		}
		
		ClientShouldSee[client] = true;
	}
}

public void TFDB_OnRocketCreated(int index, int entity)
{
	int classIndex = TFDB_GetRocketClass(index);
	int team  = GetAnalogueTeam(GetClientTeam(EntRefToEntIndex(TFDB_GetRocketTarget(index))));
	TrailFlags flags = RocketClassTrailFlags[classIndex];
	
	float position[3], angles[3], fDirection[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", position);
	GetEntPropVector(entity, Prop_Send, "m_angRotation", angles);
	GetAngleVectors(angles, fDirection, NULL_VECTOR, NULL_VECTOR);
	
	if (TestFlags(flags, TrailFlag_RemoveParticles))
	{
		int fakeEntity = CreateEntityByName("prop_dynamic");
		
		if (fakeEntity != -1)
		{
			SetEntProp(entity, Prop_Send, "m_nModelIndexOverrides", EmptyModel);
			
			SetEntityModel(fakeEntity, ROCKET_MODEL);
			SetEntProp(fakeEntity, Prop_Send, "m_CollisionGroup", 0);    // COLLISION_GROUP_NONE
			SetEntProp(fakeEntity, Prop_Send, "m_usSolidFlags", 0x0004); // FSOLID_NOT_SOLID
			SetEntProp(fakeEntity, Prop_Send, "m_nSolidType", 0);        // SOLID_NONE
			TeleportEntity(fakeEntity, position, angles, view_as<float>({0.0, 0.0, 0.0}));
			RocketFakeEntity[index] = EntIndexToEntRef(fakeEntity);
			DispatchSpawn(fakeEntity);
			
			SetVariantString("!activator");
			AcceptEntityInput(fakeEntity, "SetParent", entity, fakeEntity);
			
			if (TestFlags(flags, TrailFlag_ReplaceParticles))
			{
				// If the rocket gets instantly destroyed, the temp ent still gets sent. Why?
				CreateTempParticle(ROCKET_TRAIL_FIRE, position, _, _, fakeEntity, PATTACH_POINT_FOLLOW, 1);
				TE_SendToAll();
				
				bool critical = !!GetEntProp(entity, Prop_Send, "m_bCritical");
				
				if (critical)
				{
					int redCritEntity = CreateEntityByName("info_particle_system");
					int bluCritEntity = CreateEntityByName("info_particle_system");
					
					if ((redCritEntity != -1) && (bluCritEntity != -1))
					{
						TeleportEntity(redCritEntity, position, angles, view_as<float>({0.0, 0.0, 0.0}));
						TeleportEntity(bluCritEntity, position, angles, view_as<float>({0.0, 0.0, 0.0}));
						
						DispatchKeyValue(redCritEntity, "effect_name", ROCKET_CRIT_RED);
						DispatchKeyValue(bluCritEntity, "effect_name", ROCKET_CRIT_BLU);
						
						RocketRedCriticalEntity[index] = EntIndexToEntRef(redCritEntity);
						RocketBluCriticalEntity[index] = EntIndexToEntRef(bluCritEntity);
						
						DispatchSpawn(redCritEntity);
						DispatchSpawn(bluCritEntity);
						
						ActivateEntity(redCritEntity);
						ActivateEntity(bluCritEntity);
						
						SetVariantString("!activator");
						AcceptEntityInput(redCritEntity, "SetParent", fakeEntity, redCritEntity);
						
						SetVariantString("!activator");
						AcceptEntityInput(bluCritEntity, "SetParent", fakeEntity, bluCritEntity);
						
						SetVariantString("trail");
						AcceptEntityInput(redCritEntity, "SetParentAttachment", fakeEntity, redCritEntity);
						
						SetVariantString("trail");
						AcceptEntityInput(bluCritEntity, "SetParentAttachment", fakeEntity, bluCritEntity);
						
						if (team == view_as<int>(TFTeam_Red))
						{
							AcceptEntityInput(redCritEntity, "Start");
						}
						else if (team == view_as<int>(TFTeam_Blue))
						{
							AcceptEntityInput(bluCritEntity, "Start");
						}
					}
				}
			}
		}
	}
	
	if (TestFlags(flags, TrailFlag_CustomTrail))
	{
		int trailEntity = CreateEntityByName("info_particle_system");
		
		if (trailEntity != -1)
		{
			TeleportEntity(trailEntity, position, angles, view_as<float>({0.0, 0.0, 0.0}));
			DispatchKeyValue(trailEntity, "effect_name", RocketClassTrail[classIndex]);
			DispatchSpawn(trailEntity);
			ActivateEntity(trailEntity);
			
			if (TestFlags(flags, TrailFlag_RemoveParticles))
			{
				int fakeEntity = EntRefToEntIndex(RocketFakeEntity[index]);
				
				if (fakeEntity != -1)
				{
					SetVariantString("!activator");
					AcceptEntityInput(trailEntity, "SetParent", fakeEntity, trailEntity);
					
					SetVariantString("trail");
					AcceptEntityInput(trailEntity, "SetParentAttachment", fakeEntity, trailEntity);
					
					AcceptEntityInput(trailEntity, "Start");
				}
			}
			else
			{
				SetVariantString("!activator");
				AcceptEntityInput(trailEntity, "SetParent", entity, trailEntity);
				
				SetVariantString("trail");
				AcceptEntityInput(trailEntity, "SetParentAttachment", entity, trailEntity);
				
				AcceptEntityInput(trailEntity, "Start");
			}
			
			// This allows SetTransmit to work on info_particle_system
			SetEdictFlags(trailEntity, (GetEdictFlags(trailEntity) & ~FL_EDICT_ALWAYS));
			SDKHook(trailEntity, SDKHook_SetTransmit, TrailSetTransmit);
		}
	}
	
	if (TestFlags(flags, TrailFlag_CustomSprite))
	{
		int spriteEntity = CreateEntityByName("env_spritetrail");
		
		if (spriteEntity != -1)
		{
			TeleportEntity(spriteEntity, position, angles, view_as<float>({0.0, 0.0, 0.0}));
			
			DispatchKeyValue(spriteEntity, "spritename", RocketClassSprite[classIndex]);
			DispatchKeyValueFloat(spriteEntity, "lifetime", RocketClassSpriteLifetime[classIndex] != 0 ? RocketClassSpriteLifetime[classIndex] : 1.0);
			DispatchKeyValueFloat(spriteEntity, "endwidth", RocketClassSpriteEndWidth[classIndex] != 0 ? RocketClassSpriteEndWidth[classIndex] : 15.0);
			DispatchKeyValueFloat(spriteEntity, "startwidth", RocketClassSpriteStartWidth[classIndex] != 0 ? RocketClassSpriteStartWidth[classIndex] : 6.0);
			DispatchKeyValue(spriteEntity, "rendercolor", strlen(RocketClassSpriteColor[classIndex]) != 0 ? RocketClassSpriteColor[classIndex] : "255 255 255");
			DispatchKeyValue(spriteEntity, "renderamt", "255");
			DispatchKeyValue(spriteEntity, "rendermode", "3");
			SetEntPropFloat(spriteEntity, Prop_Send, "m_flTextureRes", RocketClassTextureRes[classIndex]);
			
			if (RocketClassSpriteTrie[classIndex] != null)
			{
				StringMapSnapshot spriteSnap = RocketClassSpriteTrie[classIndex].Snapshot();
				
				int snapSize = spriteSnap.Length;
				char key[256];
				char value[256];
				
				for (int entry = 0; entry < snapSize; entry++)
				{
					spriteSnap.GetKey(entry, key, sizeof(key));
					RocketClassSpriteTrie[classIndex].GetString(key, value, sizeof(value));
					DispatchKeyValue(spriteEntity, key, value);
				}
				
				delete spriteSnap;
			}
			
			if (TestFlags(flags, TrailFlag_RemoveParticles))
			{
				int fakeEntity = EntRefToEntIndex(RocketFakeEntity[index]);
				
				if (fakeEntity != -1)
				{
					SetVariantString("!activator");
					AcceptEntityInput(spriteEntity, "SetParent", fakeEntity, spriteEntity);
					
					SetVariantString("trail");
					AcceptEntityInput(spriteEntity, "SetParentAttachment", fakeEntity, spriteEntity);
				}
			}
			else
			{
				SetVariantString("!activator");
				AcceptEntityInput(spriteEntity, "SetParent", entity, spriteEntity);
				
				SetVariantString("trail");
				AcceptEntityInput(spriteEntity, "SetParentAttachment", entity, spriteEntity);
			}
			
			DispatchSpawn(spriteEntity);
			SDKHook(spriteEntity, SDKHook_SetTransmit, SpriteSetTransmit);
		}
	}
	
	RocketFlags rocketFlags = TFDB_GetRocketFlags(index);
	
	if (TestFlags(flags, TrailFlag_RemoveParticles) && TestFlags(rocketFlags, RocketFlag_CustomModel))
	{
		char customModel[PLATFORM_MAX_PATH]; TFDB_GetRocketClassModel(classIndex, customModel, sizeof(customModel));
		int fakeEntity = EntRefToEntIndex(RocketFakeEntity[index]);
		
		if (fakeEntity != -1)
		{
			SetEntityModel(fakeEntity, customModel);
			UpdateRocketSkin(fakeEntity, team, TestFlags(rocketFlags, RocketFlag_IsNeutral));
		}
	}
}

public Action TrailSetTransmit(int entity, int client)
{
	if (GetEdictFlags(entity) & FL_EDICT_ALWAYS)
	{
		// Stops the game from setting back the flag
		SetEdictFlags(entity, (GetEdictFlags(entity) ^ FL_EDICT_ALWAYS));
	}
	
	return ClientHideTrails[client] ? Plugin_Handled : Plugin_Continue;
}

public Action SpriteSetTransmit(int entity, int client)
{
	return ClientHideSprites[client] ? Plugin_Handled : Plugin_Continue;
}

public Action CmdHideTrails(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "Command is in-game only.");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(client, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	if (args)
	{
		CReplyToCommand(client, "%t", "Command_DBHideParticles_Usage");
		
		return Plugin_Handled;
	}
	
	ClientHideTrails[client] = !ClientHideTrails[client];
	
	CPrintToChat(client, "%t", ClientHideTrails[client] ? "Command_DBHideParticles_Hidden" : "Command_DBHideParticles_Visible");
	
	return Plugin_Handled;
}

public Action CmdHideSprites(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "Command is in-game only.");
		
		return Plugin_Handled;
	}
	
	if (!TFDB_IsDodgeballEnabled())
	{
		CReplyToCommand(client, "%t", "Command_Disabled");
		
		return Plugin_Handled;
	}
	
	if (args)
	{
		CReplyToCommand(client, "%t", "Command_DBHideSprites_Usage");
		
		return Plugin_Handled;
	}
	
	ClientHideSprites[client] = !ClientHideSprites[client];
	
	CPrintToChat(client, "%t", ClientHideSprites[client] ? "Command_DBHideSprites_Hidden" : "Command_DBHideSprites_Visible");
	
	return Plugin_Handled;
}

void ParseConfigurations(const char[] configFile)
{
	char path[PLATFORM_MAX_PATH];
	char strFileName[PLATFORM_MAX_PATH];
	FormatEx(strFileName, sizeof(strFileName), "configs/dodgeball/%s", configFile);
	BuildPath(Path_SM, path, sizeof(path), strFileName);
	
	if (!FileExists(path, true)) return;
	
	KeyValues kvConfig = new KeyValues("TF2_Dodgeball");
	
	if (kvConfig.ImportFromFile(path) == false) SetFailState("Error while parsing the configuration file.");
	
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
	kvConfig.GotoFirstSubKey();
	do
	{
		int index = RocketClassCount;
		TrailFlags flags;
		
		kvConfig.GetString("trail particle", RocketClassTrail[index], sizeof(RocketClassTrail[]));
		
		if (RocketClassTrail[index][0]) flags |= TrailFlag_CustomTrail;
		
		kvConfig.GetString("trail sprite", RocketClassSprite[index], sizeof(RocketClassSprite[]));
		
		if (RocketClassSprite[index][0])
		{
			flags |= TrailFlag_CustomSprite;
			
			kvConfig.GetString("custom color", RocketClassSpriteColor[index], sizeof(RocketClassSpriteColor[]));
			
			RocketClassSpriteLifetime[index]   = kvConfig.GetFloat("sprite lifetime");
			RocketClassSpriteStartWidth[index] = kvConfig.GetFloat("sprite start width");
			RocketClassSpriteEndWidth[index]   = kvConfig.GetFloat("sprite end width");
			RocketClassTextureRes[index]       = kvConfig.GetFloat("texture resolution", 0.05);
			
			if (kvConfig.JumpToKey("entity keyvalues"))
			{
				RocketClassSpriteTrie[index] = ParseSpriteEntity(kvConfig);
				
				kvConfig.GoBack();
			}
		}
		
		if (kvConfig.GetNum("remove particles", 0))
		{
			flags |= TrailFlag_RemoveParticles;
			
			if (kvConfig.GetNum("replace particles", 0)) flags |= TrailFlag_ReplaceParticles;
		}
		
		RocketClassTrailFlags[index] = flags;
		RocketClassCount++;
	}
	while (kvConfig.GotoNextKey());
	
	kvConfig.GoBack();
}

StringMap ParseSpriteEntity(KeyValues kvConfig)
{
	char buffer[256], value[256];
	StringMap bufferMap = new StringMap();
	
	kvConfig.GotoFirstSubKey(false);
	do
	{
		kvConfig.GetSectionName(buffer, sizeof(buffer));
		kvConfig.GetString(NULL_STRING, value, sizeof(value));
		
		bufferMap.SetString(buffer, value);
	}
	while (kvConfig.GotoNextKey(false));
	
	kvConfig.GoBack();
	
	return bufferMap;
}

void UpdateRocketSkin(int entity, int team, bool neutral)
{
	if (neutral) SetEntProp(entity, Prop_Send, "m_nSkin", 2);
	else          SetEntProp(entity, Prop_Send, "m_nSkin", (team == view_as<int>(TFTeam_Blue)) ? 0 : 1);
}

stock int GetAnalogueTeam(int team)
{
	if (team == view_as<int>(TFTeam_Red)) return view_as<int>(TFTeam_Blue);
	
	return view_as<int>(TFTeam_Red);
}

stock int GetPrecachedModel(const char[] model)
{
	static int modelPrecache = INVALID_STRING_TABLE;
	
	if ((modelPrecache == INVALID_STRING_TABLE) &&
	    ((modelPrecache = FindStringTable("modelprecache")) == INVALID_STRING_TABLE))
	{
		return INVALID_STRING_INDEX;
	}
	
	int modelIndex = FindStringIndex(modelPrecache, model);
	
	if (modelIndex == INVALID_STRING_INDEX)
	{
		modelIndex = PrecacheModel(model, true);
	}
	
	return modelIndex;
}

stock int GetPrecachedParticle(const char[] particleSystem)
{
	static int particleEffectNames = INVALID_STRING_TABLE;
	
	if ((particleEffectNames == INVALID_STRING_TABLE) &&
	    ((particleEffectNames = FindStringTable("ParticleEffectNames")) == INVALID_STRING_TABLE))
	{
		return INVALID_STRING_INDEX;
	}
	
	int particleIndex = FindStringIndex(particleEffectNames, particleSystem);
	
	if (particleIndex == INVALID_STRING_INDEX)
	{
		int numStrings = GetStringTableNumStrings(particleEffectNames);
		
		if (numStrings >= GetStringTableMaxStrings(particleEffectNames))
		{
			return INVALID_STRING_INDEX;
		}
		
		AddToStringTable(particleEffectNames, particleSystem);
		particleIndex = numStrings;
	}
	
	return particleIndex;
}

stock int GetPrecachedGeneric(const char[] generic)
{
	static int genericPrecache = INVALID_STRING_TABLE;
	
	if ((genericPrecache == INVALID_STRING_TABLE) &&
	    ((genericPrecache = FindStringTable("genericprecache")) == INVALID_STRING_TABLE))
	{
		return INVALID_STRING_INDEX;
	}
	
	int genericIndex = FindStringIndex(genericPrecache, generic);
	
	if (genericIndex == INVALID_STRING_INDEX)
	{
		genericIndex = PrecacheGeneric(generic, true);
	}
	
	return genericIndex;
}

// https://forums.alliedmods.net/showthread.php?t=75102

stock void CreateTempParticle(const char[] particleName,
                              const float vecOrigin[3] = NULL_VECTOR,
                              const float vecStart[3] = NULL_VECTOR,
                              const float vecAngles[3] = NULL_VECTOR,
                              int entity = -1,
                              ParticleAttachmentType AttachmentType = PATTACH_ABSORIGIN,
                              int iAttachmentPoint = -1,
                              bool resetParticles = false)
{
	int particleIndex = GetPrecachedParticle(particleName);
	if (particleIndex == INVALID_STRING_INDEX)
	{
		ThrowError("Could not find particle index: %s", particleName);
	}
	
	TE_Start("TFParticleEffect");
	TE_WriteFloat("m_vecOrigin[0]", vecOrigin[0]);
	TE_WriteFloat("m_vecOrigin[1]", vecOrigin[1]);
	TE_WriteFloat("m_vecOrigin[2]", vecOrigin[2]);
	TE_WriteFloat("m_vecStart[0]", vecStart[0]);
	TE_WriteFloat("m_vecStart[1]", vecStart[1]);
	TE_WriteFloat("m_vecStart[2]", vecStart[2]);
	TE_WriteVector("m_vecAngles", vecAngles);
	TE_WriteNum("m_iParticleSystemIndex", particleIndex);
	
	if (entity != -1)
	{
		TE_WriteNum("entindex", entity);
	}
	
	if (AttachmentType != PATTACH_ABSORIGIN)
	{
		TE_WriteNum("m_iAttachType", view_as<int>(AttachmentType));
	}
	
	if (iAttachmentPoint != -1)
	{
		TE_WriteNum("m_iAttachmentPointIndex", iAttachmentPoint);
	}
	
	TE_WriteNum("m_bResetParticles", resetParticles ? 1 : 0);
}

public any Native_GetRocketFakeEntity(Handle plugin, int numParams)
{
	int index = GetNativeCell(1);
	
	return RocketFakeEntity[index];
}

public any Native_SetRocketFakeEntity(Handle plugin, int numParams)
{
	int index = GetNativeCell(1);
	
	int fake = GetNativeCell(2);
	
	RocketFakeEntity[index] = fake;
	
	return 0;
}

public any Native_GetRocketClassTrail(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	int maxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassTrail[classIndex], maxLen);
	
	return 0;
}

public any Native_SetRocketClassTrail(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	int maxLen; GetNativeStringLength(2, maxLen);
	
	char[] buffer = new char[maxLen + 1]; GetNativeString(2, buffer, maxLen + 1);
	
	strcopy(RocketClassTrail[classIndex], sizeof(RocketClassTrail[]), buffer);
	
	return 0;
}

public any Native_GetRocketClassSprite(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	int maxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassSprite[classIndex], maxLen);
	
	return 0;
}

public any Native_SetRocketClassSprite(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	int maxLen; GetNativeStringLength(2, maxLen);
	
	char[] buffer = new char[maxLen + 1]; GetNativeString(2, buffer, maxLen + 1);
	
	strcopy(RocketClassSprite[classIndex], sizeof(RocketClassSprite[]), buffer);
	
	return 0;
}

public any Native_GetRocketClassSpriteColor(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	int maxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassSpriteColor[classIndex], maxLen);
	
	return 0;
}

public any Native_SetRocketClassSpriteColor(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	int maxLen; GetNativeStringLength(2, maxLen);
	
	char[] buffer = new char[maxLen + 1]; GetNativeString(2, buffer, maxLen + 1);
	
	strcopy(RocketClassSpriteColor[classIndex], sizeof(RocketClassSpriteColor[]), buffer);
	
	return 0;
}

public any Native_GetRocketClassSpriteLifetime(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	return RocketClassSpriteLifetime[classIndex];
}

public any Native_SetRocketClassSpriteLifetime(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	float lifetime = GetNativeCell(2);
	
	RocketClassSpriteLifetime[classIndex] = lifetime;
	
	return 0;
}

public any Native_GetRocketClassSpriteStartWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	return RocketClassSpriteStartWidth[classIndex];
}

public any Native_SetRocketClassSpriteStartWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	float width = GetNativeCell(2);
	
	RocketClassSpriteStartWidth[classIndex] = width;
	
	return 0;
}

public any Native_GetRocketClassSpriteEndWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	return RocketClassSpriteEndWidth[classIndex];
}

public any Native_SetRocketClassSpriteEndWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	float width = GetNativeCell(2);
	
	RocketClassSpriteEndWidth[classIndex] = width;
	
	return 0;
}

public any Native_GetRocketClassTextureRes(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	return RocketClassTextureRes[classIndex];
}

public any Native_SetRocketClassTextureRes(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	float resolution = GetNativeCell(2);
	
	RocketClassTextureRes[classIndex] = resolution;
	
	return 0;
}

public any Native_GetRocketClassTrailFlags(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	return RocketClassTrailFlags[classIndex];
}

public any Native_SetRocketClassTrailFlags(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	
	TrailFlags flags = GetNativeCell(2);
	
	RocketClassTrailFlags[classIndex] = flags;
	
	return 0;
}
