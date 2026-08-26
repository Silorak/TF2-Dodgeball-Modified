#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2_stocks>
#include <multicolors>
#include <sdkhooks>

#include <tfdb>
#include <tfdbtrails>
#include <tfdb_clientcheck>

#define PLUGIN_NAME        "[TFDB] Rocket trails"
#define PLUGIN_AUTHOR      "x07x08, Silorak"
#define PLUGIN_DESCRIPTION "Customizable rocket trails"
#define PLUGIN_VERSION "2.3.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

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
// Parallel array of the real rocket entref, used by OnEntityDestroyed to
// reverse-lookup which fake belongs to a dying rocket.
int RocketRealEntity       [MAX_ROCKETS] = {-1, ...};
int RocketSlotByEntity     [2049] = {-1, ...};

// Per-rocket tracking of every info_particle_system / env_spritetrail entity
// we spawn. When TrailFlag_RemoveParticles is UNSET, the trail entity is
// parented directly to the real rocket - and Source does NOT cascade-delete
// SetParent children, so without explicit reaping these orphan and walk the
// edict count toward 2048 on long-running servers. We store entrefs (not raw
// indices) so stale-entity reads are safe.
#define MAX_TRAILS_PER_ROCKET 8
int RocketTrailEntities    [MAX_ROCKETS][MAX_TRAILS_PER_ROCKET];
int RocketTrailEntityCount [MAX_ROCKETS];

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
	RegConsoleCmd("sm_hidetrails", CmdHideTrails);
	RegConsoleCmd("sm_hidesprites", CmdHideSprites);
	
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
		HookEventEx("object_deflected", OnObjectDeflected);
		HookEventEx("player_team", OnPlayerTeam);
		
		Loaded = true;
	}
	
	if (strcmp(configFile, "general.cfg") == 0)
	{
		for (int index = 0; index < RocketClassCount; index++)
		{
			delete RocketClassSpriteTrie[index];
			RocketClassSpriteTrie[index] = null;
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

	Loaded = false;

	// Do NOT UnhookEvent here - SM auto-cleans on plugin unload.
	// Manual unhooking causes "has no active hook" errors that cascade
	// into the core dodgeball plugin and permanently break it.

	for (int index = 0; index < RocketClassCount; index++)
	{
		delete RocketClassSpriteTrie[index];
		RocketClassSpriteTrie[index] = null;
	}
	// Reap any fake entities still parented to dead rockets. Children of a
	// dead parent are orphaned (not auto-killed) in Source - without this
	// pass, prop_dynamic / info_particle_system / env_spritetrail entities
	// leak across map changes.
	for (int i = 0; i < MAX_ROCKETS; i++)
	{
		int fake = EntRefToEntIndex(RocketFakeEntity[i]);
		if (fake != -1 && IsValidEntity(fake))
		{
			AcceptEntityInput(fake, "Kill");
		}
		RocketFakeEntity[i] = -1;
		RocketRealEntity[i] = -1;

		// Reap any trail/sprite entities parented to the real rocket - these
		// don't die with the fake (which only takes its own children).
		KillRocketTrailEntities(i);
	}

	for (int entity = 0; entity < sizeof(RocketSlotByEntity); entity++)
	{
		RocketSlotByEntity[entity] = -1;
	}
	RocketClassCount = 0;
}

public void OnPluginEnd()
{
	// On unload, the same orphan problem exists: trail entities parented to
	// real rockets stay alive in-world even though we'll no longer track
	// them. Reap everything we know about before our state is destroyed.
	for (int i = 0; i < MAX_ROCKETS; i++)
	{
		int fake = EntRefToEntIndex(RocketFakeEntity[i]);
		if (fake != -1 && IsValidEntity(fake))
		{
			AcceptEntityInput(fake, "Kill");
		}
		RocketFakeEntity[i] = -1;
		RocketRealEntity[i] = -1;

		KillRocketTrailEntities(i);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity < 0 || entity >= sizeof(RocketSlotByEntity)) return;
	int slot = RocketSlotByEntity[entity];
	RocketSlotByEntity[entity] = -1;
	if (slot < 0 || slot >= MAX_ROCKETS) return;
	if (EntRefToEntIndex(RocketRealEntity[slot]) != entity) return;

	int fake = EntRefToEntIndex(RocketFakeEntity[slot]);
	if (fake != -1 && IsValidEntity(fake)) AcceptEntityInput(fake, "Kill");
	RocketFakeEntity[slot] = -1;
	RocketRealEntity[slot] = -1;
	KillRocketTrailEntities(slot);
}

// Kills every tracked trail/sprite entity for the given rocket slot and
// resets the count. Safe to call multiple times.
void KillRocketTrailEntities(int index)
{
	int count = RocketTrailEntityCount[index];
	for (int t = 0; t < count; t++)
	{
		int trailEnt = EntRefToEntIndex(RocketTrailEntities[index][t]);
		if (trailEnt != -1 && IsValidEntity(trailEnt))
		{
			RemoveEntity(trailEnt);
		}
		RocketTrailEntities[index][t] = INVALID_ENT_REFERENCE;
	}
	RocketTrailEntityCount[index] = 0;
}

// Push a freshly-spawned trail/sprite entity onto the per-rocket tracking
// list. Bounded by MAX_TRAILS_PER_ROCKET - overflow is silently ignored
// (defensive; with the current two spawn sites we cap at 2 per rocket).
void TrackRocketTrailEntity(int index, int trailEntity)
{
	if (index < 0 || index >= MAX_ROCKETS) return;
	if (RocketTrailEntityCount[index] >= MAX_TRAILS_PER_ROCKET) return;
	RocketTrailEntities[index][RocketTrailEntityCount[index]++] = EntIndexToEntRef(trailEntity);
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
	if (classIndex < 0 || classIndex >= RocketClassCount) return;

	if (!(RocketClassTrailFlags[classIndex] & TrailFlag_ReplaceParticles)) return;
	
	int team = GetEntProp(entity, Prop_Send, "m_iTeamNum", 1);
	
	// Crit glow swapping is handled by the core plugin's UpdateCritGlow.
	// m_bCritical is always 0 on the network, so the trails subplugin's
	// RocketRedCriticalEntity/RocketBluCriticalEntity system never activates.
	
	int fakeEntity = EntRefToEntIndex(RocketFakeEntity[index]);
	
	if (fakeEntity == -1) return;
	
	UpdateRocketSkin(fakeEntity, team, TestFlags(TFDB_GetRocketFlags(index), RocketFlag_IsNeutral));
}

public void OnPlayerTeam(Event event, char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	// Client may have disconnected between event fire and handler dispatch, or
	// the userid may resolve to 0 (engine sentinel). Either case means nothing
	// to send particles to - bail before TE_SendToClient(0) errors the frame.
	if (client <= 0 || !IsClientInGame(client)) return;

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
	// Remember the real rocket so OnEntityDestroyed can reap the fake when
	// the rocket dies - Source does not cascade-delete SetParent children.
	int previousEntity = EntRefToEntIndex(RocketRealEntity[index]);
	if (previousEntity > 0 && previousEntity < sizeof(RocketSlotByEntity)) RocketSlotByEntity[previousEntity] = -1;
	RocketRealEntity[index] = EntIndexToEntRef(entity);
	if (entity > 0 && entity < sizeof(RocketSlotByEntity)) RocketSlotByEntity[entity] = index;

	int classIndex = TFDB_GetRocketClass(index);
	if (classIndex < 0 || classIndex >= RocketClassCount) return;
	int target = TFDB_GetRocketTarget(index);
	if (target < 1 || target > MaxClients || !IsClientInGame(target)) return;
	int team  = GetAnalogueTeam(GetClientTeam(target));
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
				
				// Crit glow particles are managed by the core plugin's UpdateCritGlow.
				// m_bCritical is always 0 on the network, so the trails subplugin
				// does not create its own crit glow entities.
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

			// Track for cleanup. Required when this trail ends up parented to
			// the real rocket (RemoveParticles unset) - Source orphans rather
			// than cascade-deletes children. Tracking the parented-to-fake
			// case is harmless: the redundant kill is gated by IsValidEntity.
			TrackRocketTrailEntity(index, trailEntity);
			
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

			// Track for cleanup - same reasoning as the info_particle_system
			// branch above. Without this, sprites parented to the real
			// rocket (RemoveParticles unset) leak edicts on every rocket.
			TrackRocketTrailEntity(index, spriteEntity);
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
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
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
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
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
	
	if (!kvConfig.ImportFromFile(path))
	{
		LogError("[TFDB Trails] Error while parsing configuration file: %s (continuing without trails)", path);
		delete kvConfig;
		return;
	}

	if (!kvConfig.GotoFirstSubKey())
	{
		delete kvConfig;
		return;
	}
	
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
	if (!kvConfig.GotoFirstSubKey()) return;
	do
	{
		if (RocketClassCount >= MAX_ROCKET_CLASSES)
		{
			LogError("Reached maximum rocket classes (%d). Remaining classes will be ignored.", MAX_ROCKET_CLASSES);
			break;
		}

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
		// Previously this was ThrowError, which crashed the Trails subplugin whenever a
		// trail config referenced a missing particle. Now it logs and skips - missing
		// particles just mean no trail for that rocket, not a plugin death.
		LogError("[TFDB Trails] Missing precached particle: \"%s\" - skipping this trail.", particleName);
		return;
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
	if (index < 0 || index >= MAX_ROCKETS)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket index %d out of range [0..%d)", index, MAX_ROCKETS);
	return RocketFakeEntity[index];
}

public any Native_SetRocketFakeEntity(Handle plugin, int numParams)
{
	int index = GetNativeCell(1);
	if (index < 0 || index >= MAX_ROCKETS)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket index %d out of range [0..%d)", index, MAX_ROCKETS);
	int fake = GetNativeCell(2);
	RocketFakeEntity[index] = fake;
	return 0;
}

public any Native_GetRocketClassTrail(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	int maxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassTrail[classIndex], maxLen);
	
	return 0;
}

public any Native_SetRocketClassTrail(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	int maxLen; GetNativeStringLength(2, maxLen);
	
	char[] buffer = new char[maxLen + 1]; GetNativeString(2, buffer, maxLen + 1);
	
	strcopy(RocketClassTrail[classIndex], sizeof(RocketClassTrail[]), buffer);
	
	return 0;
}

public any Native_GetRocketClassSprite(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	int maxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassSprite[classIndex], maxLen);
	
	return 0;
}

public any Native_SetRocketClassSprite(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	int maxLen; GetNativeStringLength(2, maxLen);
	
	char[] buffer = new char[maxLen + 1]; GetNativeString(2, buffer, maxLen + 1);
	
	strcopy(RocketClassSprite[classIndex], sizeof(RocketClassSprite[]), buffer);
	
	return 0;
}

public any Native_GetRocketClassSpriteColor(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	int maxLen = GetNativeCell(3);
	
	SetNativeString(2, RocketClassSpriteColor[classIndex], maxLen);
	
	return 0;
}

public any Native_SetRocketClassSpriteColor(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	int maxLen; GetNativeStringLength(2, maxLen);
	
	char[] buffer = new char[maxLen + 1]; GetNativeString(2, buffer, maxLen + 1);
	
	strcopy(RocketClassSpriteColor[classIndex], sizeof(RocketClassSpriteColor[]), buffer);
	
	return 0;
}

public any Native_GetRocketClassSpriteLifetime(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	return RocketClassSpriteLifetime[classIndex];
}

public any Native_SetRocketClassSpriteLifetime(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	float lifetime = GetNativeCell(2);
	
	RocketClassSpriteLifetime[classIndex] = lifetime;
	
	return 0;
}

public any Native_GetRocketClassSpriteStartWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	return RocketClassSpriteStartWidth[classIndex];
}

public any Native_SetRocketClassSpriteStartWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	float width = GetNativeCell(2);
	
	RocketClassSpriteStartWidth[classIndex] = width;
	
	return 0;
}

public any Native_GetRocketClassSpriteEndWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	return RocketClassSpriteEndWidth[classIndex];
}

public any Native_SetRocketClassSpriteEndWidth(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	float width = GetNativeCell(2);
	
	RocketClassSpriteEndWidth[classIndex] = width;
	
	return 0;
}

public any Native_GetRocketClassTextureRes(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	return RocketClassTextureRes[classIndex];
}

public any Native_SetRocketClassTextureRes(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	float resolution = GetNativeCell(2);
	
	RocketClassTextureRes[classIndex] = resolution;
	
	return 0;
}

public any Native_GetRocketClassTrailFlags(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	return RocketClassTrailFlags[classIndex];
}

public any Native_SetRocketClassTrailFlags(Handle plugin, int numParams)
{
	int classIndex = GetNativeCell(1);
	if (classIndex < 0 || classIndex >= RocketClassCount)
		return ThrowNativeError(SP_ERROR_PARAM, "Rocket class index %d out of range [0..%d)", classIndex, RocketClassCount);
	
	TrailFlags flags = GetNativeCell(2);
	
	RocketClassTrailFlags[classIndex] = flags;
	
	return 0;
}
