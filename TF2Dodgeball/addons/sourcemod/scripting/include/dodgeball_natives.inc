#if defined _dodgeball_natives_included
  #endinput
#endif
#define _dodgeball_natives_included

/**
 * Implements the native functions exposed by the TF2 Dodgeball plugin.
 * These natives allow other plugins to interact with and control the gamemode.
 *
 * Most get/set natives follow the same pattern: fetch the array index from
 * native cell 1, read or write the corresponding slot. The macros below
 * generate the boilerplate. Use them for simple primitive (int/float/any)
 * arrays indexed by a single int key.
 *
 * For non-primitive types (ent-refs, vectors, strings, DataPacks, handles)
 * or for natives with custom logic, write the handler out explicitly.
 */

// Generate a getter that returns Field[GetNativeCell(1)].
// Uses view_as<any> so float arrays work without a separate macro.
// Bounds-check the rocket index - third-party subplugins that forget to call
// IsValidRocket() first would otherwise read/write adjacent memory and crash
// core. ThrowNativeError raises a script exception in the calling subplugin
// instead of corrupting our state. (Audit finding 2026-04-28.)
//
// Example: TFDB_NATIVE_GET(Native_GetRocketSpeed, RocketSpeed)
#define TFDB_NATIVE_GET(%1,%2) \
	public any %1(Handle plugin, int numParams) { \
		int idx = GetNativeCell(1); \
		if (!ValidateNativeIndex(idx, sizeof(%2), "Array")) return 0; \
		return view_as<any>(%2[idx]); \
	}

// Generate a setter that writes GetNativeCell(2) into Field[GetNativeCell(1)].
// Example: TFDB_NATIVE_SET(Native_SetRocketSpeed, RocketSpeed)
#define TFDB_NATIVE_SET(%1,%2) \
	public any %1(Handle plugin, int numParams) { \
		int idx = GetNativeCell(1); \
		if (!ValidateNativeIndex(idx, sizeof(%2), "Array")) return 0; \
		%2[idx] = GetNativeCell(2); \
		return 0; \
	}

// Setter with an enum cast (for typed-enum arrays like RocketInstanceFlags).
// Example: TFDB_NATIVE_SET_CAST(Native_SetRocketFlags, RocketInstanceFlags, RocketFlags)
#define TFDB_NATIVE_SET_CAST(%1,%2,%3) \
	public any %1(Handle plugin, int numParams) { \
		int idx = GetNativeCell(1); \
		if (!ValidateNativeIndex(idx, sizeof(%2), "Array")) return 0; \
		%2[idx] = view_as<%3>(GetNativeCell(2)); \
		return 0; \
	}

#define TFDB_NATIVE_DATAPACK_GET(%1,%2) \
	public any %1(Handle plugin, int numParams) { \
		int idx = GetNativeCell(1); \
		if (!ValidateNativeIndex(idx, sizeof(%2), "Rocket class")) return 0; \
		return CloneHandle(%2[idx], plugin); \
	}

#define TFDB_NATIVE_DATAPACK_SET(%1,%2) \
	public any %1(Handle plugin, int numParams) { \
		int idx = GetNativeCell(1); \
		if (!ValidateNativeIndex(idx, sizeof(%2), "Rocket class")) return 0; \
		DataPack source = view_as<DataPack>(GetNativeCell(2)); \
		DataPack clone = view_as<DataPack>(CloneHandle(source, GetMyHandle())); \
		delete %2[idx]; \
		%2[idx] = clone; \
		return 0; \
	}

bool ValidateNativeIndex(int index, int limit, const char[] type)
{
	if (index >= 0 && index < limit) return true;
	ThrowNativeError(SP_ERROR_PARAM, "%s index %d out of range [0..%d)", type, index, limit);
	return false;
}

bool ValidateNativeCount(int count, int limit, const char[] type)
{
	if (count >= 0 && count <= limit) return true;
	ThrowNativeError(SP_ERROR_PARAM, "%s count %d out of range [0..%d]", type, count, limit);
	return false;
}

bool ValidateNativeCursor(int cursor, int count, const char[] type)
{
	if (cursor >= 0 && (cursor < count || (count == 0 && cursor == 0))) return true;
	ThrowNativeError(SP_ERROR_PARAM, "%s cursor %d out of range for count %d", type, cursor, count);
	return false;
}

bool IsSupportedRocketEntity(int entity)
{
	if (entity <= MaxClients || !IsValidEntity(entity)) return false;
	char classname[32];
	if (!GetEntityClassname(entity, classname, sizeof(classname))) return false;
	return StrEqual(classname, "tf_projectile_rocket") || StrEqual(classname, "tf_projectile_sentryrocket");
}

// *********************************************************************************
// NATIVES - GENERAL & STATE
// *********************************************************************************

public any Native_IsValidRocket(Handle plugin, int numParams) {
	return IsValidRocket(GetNativeCell(1));
}

public any Native_FindRocketByEntity(Handle plugin, int numParams) {
	return FindRocketByEntity(GetNativeCell(1));
}

public any Native_IsDodgeballEnabled(Handle plugin, int numParams) {
	return Enabled;
}

public any Native_RecountAlive(Handle plugin, int numParams) {
	RecountAlive();
	return 0;
}

// *********************************************************************************
// NATIVES - ROCKET GETTERS/SETTERS
// *********************************************************************************

public any Native_GetRocketEntity(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketEntity), "Rocket")) return 0;
	return EntRefToEntIndex(RocketEntity[index]);
}

public any Native_SetRocketEntity(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int entity = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(RocketEntity), "Rocket")) return 0;
	if (!RocketIsValid[index]) return ThrowNativeError(SP_ERROR_PARAM, "Cannot rebind inactive rocket slot %d", index);
	if (!IsSupportedRocketEntity(entity)) return ThrowNativeError(SP_ERROR_PARAM, "Invalid rocket entity %d", entity);
	int oldEntity = EntRefToEntIndex(RocketEntity[index]);
	if (oldEntity == entity) return 0;
	if (!RebindRocketEntity(index, entity)) return ThrowNativeError(SP_ERROR_PARAM, "Rocket entity %d is already bound", entity);
	if (AttachRocketHooks(entity)) return 0;

	if (oldEntity != -1) RebindRocketEntity(index, oldEntity);
	else
	{
		ClearRocketEntityMapping(index);
		RocketEntity[index] = INVALID_ENT_REFERENCE;
	}
	return ThrowNativeError(SP_ERROR_NATIVE, "SDKHookEx failed for rocket entity %d", entity);
}

TFDB_NATIVE_GET(     Native_GetRocketFlags,              RocketInstanceFlags)
TFDB_NATIVE_SET_CAST(Native_SetRocketFlags,              RocketInstanceFlags, RocketFlags)

// Ent-ref round-trip - kept explicit because of the EntIndexToEntRef wrapping.
public any Native_GetRocketTarget(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketTarget), "Rocket")) return 0;
	return EntRefToEntIndex(RocketTarget[index]);
}
public any Native_SetRocketTarget(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int target = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(RocketTarget), "Rocket")) return 0;
	if (!IsValidClient(target, true)) return ThrowNativeError(SP_ERROR_PARAM, "Invalid rocket target %d", target);
	RocketTarget[index] = EntIndexToEntRef(target);
	return 0;
}

// Derived - owner is read from an entity prop, not a rocket-class array.
public any Native_GetRocketOwner(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketEntity), "Rocket")) return 0;
	if (!RocketIsValid[index]) return -1;
	int entity = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return -1;
	return GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
}

TFDB_NATIVE_GET(Native_GetRocketEventDeflections,    RocketEventDeflections)
TFDB_NATIVE_SET(Native_SetRocketEventDeflections,    RocketEventDeflections)
TFDB_NATIVE_GET(Native_GetRocketDeflections,         RocketDeflections)
TFDB_NATIVE_SET(Native_SetRocketDeflections,         RocketDeflections)
TFDB_NATIVE_GET(Native_GetRocketClass,               RocketClass)
public any Native_SetRocketClass(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int rocketClass = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(RocketClass), "Rocket")) return 0;
	if (!ValidateNativeIndex(rocketClass, RocketClassCount, "Rocket class")) return 0;
	RocketClass[index] = rocketClass;
	return 0;
}
TFDB_NATIVE_GET(Native_GetRocketSpeed,               RocketSpeed)
TFDB_NATIVE_SET(Native_SetRocketSpeed,               RocketSpeed)
TFDB_NATIVE_GET(Native_GetRocketMphSpeed,            RocketMphSpeed)
TFDB_NATIVE_GET(Native_GetRocketRawMphSpeed,          RocketRawMphSpeed)
TFDB_NATIVE_SET(Native_SetRocketMphSpeed,            RocketMphSpeed)

// Vector get/set - needs SetNativeArray / GetNativeArray. Kept explicit.
public any Native_GetRocketDirection(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketDirection), "Rocket")) return 0;
	SetNativeArray(2, RocketDirection[index], 3);
	return 0;
}
public any Native_SetRocketDirection(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketDirection), "Rocket")) return 0;
	float direction[3];
	GetNativeArray(2, direction, sizeof(direction));
	CopyVectors(direction, RocketDirection[index]);
	return 0;
}

TFDB_NATIVE_GET(Native_GetRocketLastDeflectionTime,  RocketLastDeflectionTime)
TFDB_NATIVE_SET(Native_SetRocketLastDeflectionTime,  RocketLastDeflectionTime)
TFDB_NATIVE_GET(Native_GetRocketLastBeepTime,        RocketLastBeepTime)
TFDB_NATIVE_SET(Native_SetRocketLastBeepTime,        RocketLastBeepTime)

// Global counter - not array-indexed, so the macros don't apply.
public any Native_GetRocketCount(Handle plugin, int numParams) {
	return RocketCount;
}

TFDB_NATIVE_GET(Native_GetLastSpawnTime,             LastSpawnTime)

public any Native_GetRocketBounces(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketBounces), "Rocket")) return 0;
	return RocketBounces[index];
}

public any Native_SetRocketBounces(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketBounces), "Rocket")) return 0;
	RocketBounces[index] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketState(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketInstanceState), "Rocket")) return 0;
	return RocketInstanceState[index];
}

public any Native_SetRocketState(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketInstanceState), "Rocket")) return 0;
	Internal_SetRocketState(index, view_as<RocketState>(GetNativeCell(2)));
	return 0;
}

// *********************************************************************************
// NATIVES - ROCKET CLASS GETTERS/SETTERS
// *********************************************************************************

public any Native_GetRocketClassCount(Handle plugin, int numParams) {
	return RocketClassCount;
}

public any Native_SetRocketClassCount(Handle plugin, int numParams) {
	int count = GetNativeCell(1);
	if (!ValidateNativeCount(count, MAX_ROCKET_CLASSES, "Rocket class")) return 0;
	RocketClassCount = count;
	return 0;
}

TFDB_NATIVE_GET(     Native_GetRocketClassBehaviour,        RocketClassBehaviour)
TFDB_NATIVE_SET_CAST(Native_SetRocketClassBehaviour,        RocketClassBehaviour, BehaviourTypes)
TFDB_NATIVE_GET(     Native_GetRocketClassFlags,            RocketClassFlags)
TFDB_NATIVE_SET_CAST(Native_SetRocketClassFlags,            RocketClassFlags, RocketFlags)

TFDB_NATIVE_GET(Native_GetRocketClassDamage,                RocketClassDamage)
TFDB_NATIVE_SET(Native_SetRocketClassDamage,                RocketClassDamage)
TFDB_NATIVE_GET(Native_GetRocketClassDamageIncrement,       RocketClassDamageIncrement)
TFDB_NATIVE_SET(Native_SetRocketClassDamageIncrement,       RocketClassDamageIncrement)
TFDB_NATIVE_GET(Native_GetRocketClassSpeed,                 RocketClassSpeed)
TFDB_NATIVE_SET(Native_SetRocketClassSpeed,                 RocketClassSpeed)
TFDB_NATIVE_GET(Native_GetRocketClassSpeedIncrement,        RocketClassSpeedIncrement)
public any Native_SetRocketClassSpeedIncrement(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, sizeof(RocketClassSpeedIncrement), "Rocket class")) return 0;
	float value = view_as<float>(GetNativeCell(2));
	RocketClassConfiguredSpeedIncrement[index] = value;
	RocketClassSpeedIncrement[index] = value;
	return 0;
}
TFDB_NATIVE_GET(Native_GetRocketClassSpeedLimit,            RocketClassSpeedLimit)
TFDB_NATIVE_SET(Native_SetRocketClassSpeedLimit,            RocketClassSpeedLimit)
TFDB_NATIVE_GET(Native_GetRocketClassTurnRate,              RocketClassTurnRate)
TFDB_NATIVE_SET(Native_SetRocketClassTurnRate,              RocketClassTurnRate)
TFDB_NATIVE_GET(Native_GetRocketClassTurnRateIncrement,     RocketClassTurnRateIncrement)
TFDB_NATIVE_SET(Native_SetRocketClassTurnRateIncrement,     RocketClassTurnRateIncrement)
TFDB_NATIVE_GET(Native_GetRocketClassTurnRateLimit,         RocketClassTurnRateLimit)
TFDB_NATIVE_SET(Native_SetRocketClassTurnRateLimit,         RocketClassTurnRateLimit)
TFDB_NATIVE_GET(Native_GetRocketClassElevationRate,         RocketClassElevationRate)
TFDB_NATIVE_SET(Native_SetRocketClassElevationRate,         RocketClassElevationRate)
TFDB_NATIVE_GET(Native_GetRocketClassElevationLimit,        RocketClassElevationLimit)
TFDB_NATIVE_SET(Native_SetRocketClassElevationLimit,        RocketClassElevationLimit)
TFDB_NATIVE_GET(Native_GetRocketClassRocketsModifier,       RocketClassRocketsModifier)
TFDB_NATIVE_SET(Native_SetRocketClassRocketsModifier,       RocketClassRocketsModifier)
TFDB_NATIVE_GET(Native_GetRocketClassPlayerModifier,        RocketClassPlayerModifier)
TFDB_NATIVE_SET(Native_SetRocketClassPlayerModifier,        RocketClassPlayerModifier)
TFDB_NATIVE_GET(Native_GetRocketClassControlDelay,          RocketClassControlDelay)
TFDB_NATIVE_SET(Native_SetRocketClassControlDelay,          RocketClassControlDelay)
TFDB_NATIVE_GET(Native_GetRocketClassMaxBounces,            RocketClassMaxBounces)
TFDB_NATIVE_SET(Native_SetRocketClassMaxBounces,            RocketClassMaxBounces)

public any Native_GetRocketClassName(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassName), "Rocket class")) return 0;
	SetNativeString(2, RocketClassName[rocketClass], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassName(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassName), "Rocket class")) return 0;
	GetNativeString(2, RocketClassName[rocketClass], sizeof(RocketClassName[]));
	return 0;
}

public any Native_GetRocketClassLongName(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassLongName), "Rocket class")) return 0;
	SetNativeString(2, RocketClassLongName[rocketClass], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassLongName(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassLongName), "Rocket class")) return 0;
	GetNativeString(2, RocketClassLongName[rocketClass], sizeof(RocketClassLongName[]));
	return 0;
}

public any Native_GetRocketClassModel(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassModel), "Rocket class")) return 0;
	SetNativeString(2, RocketClassModel[rocketClass], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassModel(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassModel), "Rocket class")) return 0;
	GetNativeString(2, RocketClassModel[rocketClass], sizeof(RocketClassModel[]));
	return 0;
}

TFDB_NATIVE_GET(Native_GetRocketClassBeepInterval,          RocketClassBeepInterval)
TFDB_NATIVE_SET(Native_SetRocketClassBeepInterval,          RocketClassBeepInterval)

public any Native_GetRocketClassSpawnSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassSpawnSound), "Rocket class")) return 0;
	SetNativeString(2, RocketClassSpawnSound[rocketClass], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassSpawnSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassSpawnSound), "Rocket class")) return 0;
	GetNativeString(2, RocketClassSpawnSound[rocketClass], sizeof(RocketClassSpawnSound[]));
	return 0;
}

public any Native_GetRocketClassBeepSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassBeepSound), "Rocket class")) return 0;
	SetNativeString(2, RocketClassBeepSound[rocketClass], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassBeepSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassBeepSound), "Rocket class")) return 0;
	GetNativeString(2, RocketClassBeepSound[rocketClass], sizeof(RocketClassBeepSound[]));
	return 0;
}

public any Native_GetRocketClassAlertSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassAlertSound), "Rocket class")) return 0;
	SetNativeString(2, RocketClassAlertSound[rocketClass], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassAlertSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassAlertSound), "Rocket class")) return 0;
	GetNativeString(2, RocketClassAlertSound[rocketClass], sizeof(RocketClassAlertSound[]));
	return 0;
}

TFDB_NATIVE_GET(Native_GetRocketClassCritChance,            RocketClassCritChance)
TFDB_NATIVE_SET(Native_SetRocketClassCritChance,            RocketClassCritChance)
TFDB_NATIVE_GET(Native_GetRocketClassTargetWeight,          RocketClassTargetWeight)
TFDB_NATIVE_SET(Native_SetRocketClassTargetWeight,          RocketClassTargetWeight)
TFDB_NATIVE_GET(Native_GetRocketClassBounceCeiling,         RocketClassBounceCeiling)
TFDB_NATIVE_SET(Native_SetRocketClassBounceCeiling,         RocketClassBounceCeiling)
TFDB_NATIVE_GET(Native_GetRocketClassCritGlowStack,         RocketClassCritGlowStack)
TFDB_NATIVE_SET(Native_SetRocketClassCritGlowStack,         RocketClassCritGlowStack)

/**
 * TFDB_GetRocketClassCritGlowParticle(int iClass, int iTeam, char[] strBuffer, int iMaxLen)
 *
 * Reads the per-class crit glow particle name for a given team. Returns the
 * stored override (set in cfg or via the setter); empty string means "use
 * the engine default" - the caller can fall back to "critical_rocket_red" /
 * "critical_rocket_blue" / "eyeboss_projectile" as appropriate.
 *
 * iTeam values: 2 = TFTeam_Red, 3 = TFTeam_Blue, 0 = neutral (any other value
 * also routed to neutral).
 */
public any Native_GetRocketClassCritGlowParticle(Handle plugin, int numParams) {
	int iClass = GetNativeCell(1);
	int iTeam  = GetNativeCell(2);
	int maxLen = GetNativeCell(4);
	if (iClass < 0 || iClass >= MAX_ROCKET_CLASSES) return ThrowNativeError(SP_ERROR_NATIVE, "Invalid rocket class index %d", iClass);

	if      (iTeam == view_as<int>(TFTeam_Red))   SetNativeString(3, RocketClassCritGlowParticleRed[iClass],     maxLen);
	else if (iTeam == view_as<int>(TFTeam_Blue))  SetNativeString(3, RocketClassCritGlowParticleBlue[iClass],    maxLen);
	else                                          SetNativeString(3, RocketClassCritGlowParticleNeutral[iClass], maxLen);
	return 0;
}

/**
 * TFDB_SetRocketClassCritGlowParticle(int iClass, int iTeam, const char[] strBuffer)
 *
 * Sets the per-class crit glow particle name for a given team. Empty string
 * restores the engine default. Takes effect on the NEXT rocket spawn (existing
 * rockets keep the particle they were spawned with).
 */
public any Native_SetRocketClassCritGlowParticle(Handle plugin, int numParams) {
	int iClass = GetNativeCell(1);
	int iTeam  = GetNativeCell(2);
	if (iClass < 0 || iClass >= MAX_ROCKET_CLASSES) return ThrowNativeError(SP_ERROR_NATIVE, "Invalid rocket class index %d", iClass);

	char buffer[32];
	GetNativeString(3, buffer, sizeof(buffer));

	if      (iTeam == view_as<int>(TFTeam_Red))   strcopy(RocketClassCritGlowParticleRed[iClass],     32, buffer);
	else if (iTeam == view_as<int>(TFTeam_Blue))  strcopy(RocketClassCritGlowParticleBlue[iClass],    32, buffer);
	else                                          strcopy(RocketClassCritGlowParticleNeutral[iClass], 32, buffer);
	return 0;
}

public any Native_GetRocketClassThinkInterval(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassThinkInterval), "Rocket class")) return 0;
	return view_as<any>(RocketClassThinkInterval[rocketClass]);
}

public any Native_SetRocketClassThinkInterval(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	if (!ValidateNativeIndex(rocketClass, sizeof(RocketClassThinkInterval), "Rocket class")) return 0;
	float seconds = view_as<float>(GetNativeCell(2));
	if (seconds < 0.0) seconds = 0.0;
	RocketClassThinkInterval[rocketClass] = seconds;
	return 0;
}

// *********************************************************************************
// NATIVES - SPAWNER GETTERS/SETTERS
// *********************************************************************************

public any Native_GetSpawnersName(Handle plugin, int numParams) {
	int spawnerClass = GetNativeCell(1);
	if (!ValidateNativeIndex(spawnerClass, sizeof(SpawnersName), "Spawner")) return 0;
	SetNativeString(2, SpawnersName[spawnerClass], GetNativeCell(3));
	return 0;
}

public any Native_SetSpawnersName(Handle plugin, int numParams) {
	int spawnerClass = GetNativeCell(1);
	if (!ValidateNativeIndex(spawnerClass, sizeof(SpawnersName), "Spawner")) return 0;
	GetNativeString(2, SpawnersName[spawnerClass], sizeof(SpawnersName[]));
	return 0;
}

TFDB_NATIVE_GET(Native_GetSpawnersMaxRockets, SpawnersMaxRockets)
TFDB_NATIVE_SET(Native_SetSpawnersMaxRockets, SpawnersMaxRockets)
TFDB_NATIVE_GET(Native_GetSpawnersInterval,   SpawnersInterval)
TFDB_NATIVE_SET(Native_SetSpawnersInterval,   SpawnersInterval)

public any Native_GetSpawnersChancesTable(Handle plugin, int numParams) {
	int spawnerClass = GetNativeCell(1);
	if (!ValidateNativeIndex(spawnerClass, sizeof(SpawnersChancesTable), "Spawner")) return 0;
	return CloneHandle(SpawnersChancesTable[spawnerClass], plugin);
}

public any Native_SetSpawnersChancesTable(Handle plugin, int numParams) {
	int spawnerClass = GetNativeCell(1);
	if (!ValidateNativeIndex(spawnerClass, sizeof(SpawnersChancesTable), "Spawner")) return 0;
	ArrayList table = view_as<ArrayList>(GetNativeCell(2));
	ArrayList clonedTable = view_as<ArrayList>(CloneHandle(table, GetMyHandle()));
	delete SpawnersChancesTable[spawnerClass];
	SpawnersChancesTable[spawnerClass] = clonedTable;
	return 0;
}

public any Native_GetSpawnersCount(Handle plugin, int numParams) {
	return SpawnersCount;
}

public any Native_SetSpawnersCount(Handle plugin, int numParams) {
	int count = GetNativeCell(1);
	if (!ValidateNativeCount(count, MAX_SPAWNER_CLASSES, "Spawner")) return 0;
	SpawnersCount = count;
	return 0;
}

// *********************************************************************************
// NATIVES - SPAWN POINT GETTERS/SETTERS
// *********************************************************************************

public any Native_GetCurrentRedSpawn(Handle plugin, int numParams) {
	return CurrentRedSpawn;
}

public any Native_SetCurrentRedSpawn(Handle plugin, int numParams) {
	int cursor = GetNativeCell(1);
	if (!ValidateNativeCursor(cursor, SpawnPointsRedCount, "RED spawn")) return 0;
	CurrentRedSpawn = cursor;
	return 0;
}

public any Native_GetSpawnPointsRedCount(Handle plugin, int numParams) {
	return SpawnPointsRedCount;
}

public any Native_SetSpawnPointsRedCount(Handle plugin, int numParams) {
	int count = GetNativeCell(1);
	if (!ValidateNativeCount(count, MAX_SPAWN_POINTS, "RED spawn point")) return 0;
	SpawnPointsRedCount = count;
	if (CurrentRedSpawn >= count) CurrentRedSpawn = 0;
	return 0;
}

TFDB_NATIVE_GET(Native_GetSpawnPointsRedClass,  SpawnPointsRedClass)
public any Native_SetSpawnPointsRedClass(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int spawnerClass = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(SpawnPointsRedClass), "RED spawn point")) return 0;
	if (!ValidateNativeIndex(spawnerClass, SpawnersCount, "Spawner class")) return 0;
	SpawnPointsRedClass[index] = spawnerClass;
	return 0;
}
TFDB_NATIVE_GET(Native_GetSpawnPointsRedEntity, SpawnPointsRedEntity)
public any Native_SetSpawnPointsRedEntity(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int entity = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(SpawnPointsRedEntity), "RED spawn point")) return 0;
	if (entity <= MaxClients || !IsValidEntity(entity)) return ThrowNativeError(SP_ERROR_PARAM, "Invalid RED spawn entity %d", entity);
	SpawnPointsRedEntity[index] = entity;
	return 0;
}

public any Native_GetCurrentBluSpawn(Handle plugin, int numParams) {
	return CurrentBluSpawn;
}

public any Native_SetCurrentBluSpawn(Handle plugin, int numParams) {
	int cursor = GetNativeCell(1);
	if (!ValidateNativeCursor(cursor, SpawnPointsBluCount, "BLU spawn")) return 0;
	CurrentBluSpawn = cursor;
	return 0;
}

public any Native_GetSpawnPointsBluCount(Handle plugin, int numParams) {
	return SpawnPointsBluCount;
}

public any Native_SetSpawnPointsBluCount(Handle plugin, int numParams) {
	int count = GetNativeCell(1);
	if (!ValidateNativeCount(count, MAX_SPAWN_POINTS, "BLU spawn point")) return 0;
	SpawnPointsBluCount = count;
	if (CurrentBluSpawn >= count) CurrentBluSpawn = 0;
	return 0;
}

TFDB_NATIVE_GET(Native_GetSpawnPointsBluClass,  SpawnPointsBluClass)
public any Native_SetSpawnPointsBluClass(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int spawnerClass = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(SpawnPointsBluClass), "BLU spawn point")) return 0;
	if (!ValidateNativeIndex(spawnerClass, SpawnersCount, "Spawner class")) return 0;
	SpawnPointsBluClass[index] = spawnerClass;
	return 0;
}
TFDB_NATIVE_GET(Native_GetSpawnPointsBluEntity, SpawnPointsBluEntity)
public any Native_SetSpawnPointsBluEntity(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	int entity = GetNativeCell(2);
	if (!ValidateNativeIndex(index, sizeof(SpawnPointsBluEntity), "BLU spawn point")) return 0;
	if (entity <= MaxClients || !IsValidEntity(entity)) return ThrowNativeError(SP_ERROR_PARAM, "Invalid BLU spawn entity %d", entity);
	SpawnPointsBluEntity[index] = entity;
	return 0;
}

// *********************************************************************************
// NATIVES - GAMEPLAY GETTERS/SETTERS
// *********************************************************************************

public any Native_GetRoundStarted(Handle plugin, int numParams) {
	return RoundStarted;
}

public any Native_GetRoundCount(Handle plugin, int numParams) {
	return RoundCount;
}

public any Native_GetRocketsFired(Handle plugin, int numParams) {
	return RocketsFired;
}

public any Native_GetNextSpawnTime(Handle plugin, int numParams) {
	return view_as<any>(NextSpawnTime);
}

public any Native_SetNextSpawnTime(Handle plugin, int numParams) {
	NextSpawnTime = GetNativeCell(1);
	return 0;
}

public any Native_GetLastDeadTeam(Handle plugin, int numParams) {
	return LastDeadTeam;
}

public any Native_GetLastDeadClient(Handle plugin, int numParams) {
	return LastDeadClient;
}

public any Native_GetLastStealer(Handle plugin, int numParams) {
	return LastStealer;
}

public any Native_GetStealInfo(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}
	SetNativeCellRef(2, StealInfo[client].stoleRocket);
	SetNativeCellRef(3, StealInfo[client].rocketsStolen);
	return 0;
}

public any Native_SetStealInfo(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients) {
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}
	StealInfo[client].stoleRocket = view_as<bool>(GetNativeCell(2));
	StealInfo[client].rocketsStolen = GetNativeCell(3);
	return 0;
}

// *********************************************************************************
// NATIVES - DATAPACK-BASED GETTERS/SETTERS
// *********************************************************************************

TFDB_NATIVE_DATAPACK_GET(Native_GetRocketClassCmdsOnSpawn,     RocketClassCmdsOnSpawn)
TFDB_NATIVE_DATAPACK_SET(Native_SetRocketClassCmdsOnSpawn,     RocketClassCmdsOnSpawn)
TFDB_NATIVE_DATAPACK_GET(Native_GetRocketClassCmdsOnDeflect,   RocketClassCmdsOnDeflect)
TFDB_NATIVE_DATAPACK_SET(Native_SetRocketClassCmdsOnDeflect,   RocketClassCmdsOnDeflect)
TFDB_NATIVE_DATAPACK_GET(Native_GetRocketClassCmdsOnKill,      RocketClassCmdsOnKill)
TFDB_NATIVE_DATAPACK_SET(Native_SetRocketClassCmdsOnKill,      RocketClassCmdsOnKill)
TFDB_NATIVE_DATAPACK_GET(Native_GetRocketClassCmdsOnSpawnKill, RocketClassCmdsOnSpawnKill)
TFDB_NATIVE_DATAPACK_SET(Native_SetRocketClassCmdsOnSpawnKill, RocketClassCmdsOnSpawnKill)
TFDB_NATIVE_DATAPACK_GET(Native_GetRocketClassCmdsOnExplode,   RocketClassCmdsOnExplode)
TFDB_NATIVE_DATAPACK_SET(Native_SetRocketClassCmdsOnExplode,   RocketClassCmdsOnExplode)
TFDB_NATIVE_DATAPACK_GET(Native_GetRocketClassCmdsOnNoTarget,  RocketClassCmdsOnNoTarget)
TFDB_NATIVE_DATAPACK_SET(Native_SetRocketClassCmdsOnNoTarget,  RocketClassCmdsOnNoTarget)

// *********************************************************************************
// NATIVES - ACTION FUNCTIONS
// *********************************************************************************

public any Native_CreateRocket(Handle plugin, int numParams) {
	int spawnerEntity = GetNativeCell(1);
	int spawnerClass = GetNativeCell(2);
	int team = GetNativeCell(3);
	int rocketClass = GetNativeCell(4);
	if (spawnerEntity <= MaxClients || !IsValidEntity(spawnerEntity)) return ThrowNativeError(SP_ERROR_PARAM, "Invalid spawner entity %d", spawnerEntity);
	if (!ValidateNativeIndex(spawnerClass, SpawnersCount, "Spawner")) return 0;
	if (team != view_as<int>(TFTeam_Red) && team != view_as<int>(TFTeam_Blue)) return ThrowNativeError(SP_ERROR_PARAM, "Invalid rocket team %d", team);
	if (rocketClass < -1 || rocketClass >= RocketClassCount) return ThrowNativeError(SP_ERROR_PARAM, "Invalid rocket class %d", rocketClass);
	CreateRocket(spawnerEntity, spawnerClass, team, rocketClass);
	return 0;
}

public any Native_DestroyRocket(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, MAX_ROCKETS, "Rocket")) return 0;
	DestroyRocket(index);
	return 0;
}

public any Native_DestroyRockets(Handle plugin, int numParams) {
	DestroyRockets();
	return 0;
}

public any Native_DestroyRocketClasses(Handle plugin, int numParams) {
	DestroyRocketClasses();
	return 0;
}

public any Native_DestroySpawners(Handle plugin, int numParams) {
	DestroySpawners();
	return 0;
}

public any Native_ParseConfigurations(Handle plugin, int numParams) {
	char buffer[PLATFORM_MAX_PATH];
	GetNativeString(1, buffer, sizeof(buffer));
	ParseConfigurations(buffer);
	return 0;
}

public any Native_PopulateSpawnPoints(Handle plugin, int numParams) {
	PopulateSpawnPoints();
	return 0;
}

public any Native_HomingRocketThink(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, MAX_ROCKETS, "Rocket")) return 0;
	HomingRocketThink(index);
	return 0;
}

public any Native_RocketLegacyThink(Handle plugin, int numParams) {
	int index = GetNativeCell(1);
	if (!ValidateNativeIndex(index, MAX_ROCKETS, "Rocket")) return 0;
	RocketLegacyThink(index);
	return 0;
}

// *********************************************************************************
// NATIVES - PRESETS
// *********************************************************************************

public any Native_GetPresetCount(Handle plugin, int numParams) {
	return PresetCount;
}

public any Native_GetPresetName(Handle plugin, int numParams) {
	int preset = GetNativeCell(1);
	if (!ValidateNativeIndex(preset, PresetCount, "Preset")) return 0;
	int maxLen = GetNativeCell(3);
	SetNativeString(2, PresetName[preset], maxLen);
	return 0;
}

public any Native_ApplyPreset(Handle plugin, int numParams) {
	int preset = GetNativeCell(1);
	if (preset < 0 || preset >= PresetCount) return false;

	// Find the rocket class index by short name
	int targetClass = -1;
	for (int i = 0; i < RocketClassCount; i++)
	{
		if (StrEqual(RocketClassName[i], PresetRocketClass[preset], false))
		{
			targetClass = i;
			break;
		}
	}
	if (targetClass == -1) return false;

	// Destroy active rockets before changing settings
	DestroyRockets();

	// Apply to all spawners
	for (int i = 0; i < SpawnersCount; i++)
	{
		SpawnersMaxRockets[i] = PresetMaxRockets[preset];

		if (PresetSpawnInterval[preset] > 0.0)
		{
			SpawnersInterval[i] = PresetSpawnInterval[preset];
		}

		// Set all chances to 0, then set the target class to 100
		ArrayList table = SpawnersChancesTable[i];
		for (int j = 0; j < table.Length; j++)
		{
			table.Set(j, 0);
		}
		if (targetClass < table.Length)
		{
			table.Set(targetClass, 100);
		}
	}

	return true;
}

public any Native_GetVersion(Handle plugin, int numParams)
{
	return TFDB_API_VERSION;
}
