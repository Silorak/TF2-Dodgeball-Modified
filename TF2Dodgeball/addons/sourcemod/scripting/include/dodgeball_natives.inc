#if defined _dodgeball_natives_included
  #endinput
#endif
#define _dodgeball_natives_included

/**
 * Implements the native functions exposed by the TF2 Dodgeball plugin.
 * These natives allow other plugins to interact with and control the gamemode.
 */

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

// *********************************************************************************
// NATIVES - ROCKET GETTERS/SETTERS
// *********************************************************************************

public any Native_GetRocketEntity(Handle plugin, int numParams) {
	return EntRefToEntIndex(RocketEntity[GetNativeCell(1)]);
}

public any Native_SetRocketEntity(Handle plugin, int numParams) {
	RocketEntity[GetNativeCell(1)] = EntIndexToEntRef(GetNativeCell(2));
	return 0;
}

public any Native_GetRocketFlags(Handle plugin, int numParams) {
	return RocketInstanceFlags[GetNativeCell(1)];
}

public any Native_SetRocketFlags(Handle plugin, int numParams) {
	RocketInstanceFlags[GetNativeCell(1)] = view_as<RocketFlags>(GetNativeCell(2));
	return 0;
}

public any Native_GetRocketTarget(Handle plugin, int numParams) {
	return EntRefToEntIndex(RocketTarget[GetNativeCell(1)]);
}

public any Native_SetRocketTarget(Handle plugin, int numParams) {
	RocketTarget[GetNativeCell(1)] = EntIndexToEntRef(GetNativeCell(2));
	return 0;
}

public any Native_GetRocketEventDeflections(Handle plugin, int numParams) {
	return RocketEventDeflections[GetNativeCell(1)];
}

public any Native_SetRocketEventDeflections(Handle plugin, int numParams) {
	RocketEventDeflections[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketDeflections(Handle plugin, int numParams) {
	return RocketDeflections[GetNativeCell(1)];
}

public any Native_SetRocketDeflections(Handle plugin, int numParams) {
	RocketDeflections[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClass(Handle plugin, int numParams) {
	return RocketClass[GetNativeCell(1)];
}

public any Native_SetRocketClass(Handle plugin, int numParams) {
	RocketClass[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketSpeed(Handle plugin, int numParams) {
	return view_as<any>(RocketSpeed[GetNativeCell(1)]);
}

public any Native_SetRocketSpeed(Handle plugin, int numParams) {
	RocketSpeed[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketMphSpeed(Handle plugin, int numParams) {
	return view_as<any>(RocketMphSpeed[GetNativeCell(1)]);
}

public any Native_SetRocketMphSpeed(Handle plugin, int numParams) {
	RocketMphSpeed[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketDirection(Handle plugin, int numParams) {
	SetNativeArray(2, RocketDirection[GetNativeCell(1)], 3);
	return 0;
}

public any Native_SetRocketDirection(Handle plugin, int numParams) {
	float direction[3];
	GetNativeArray(2, direction, sizeof(direction));
	CopyVectors(direction, RocketDirection[GetNativeCell(1)]);
	return 0;
}

public any Native_GetRocketLastDeflectionTime(Handle plugin, int numParams) {
	return view_as<any>(RocketLastDeflectionTime[GetNativeCell(1)]);
}

public any Native_SetRocketLastDeflectionTime(Handle plugin, int numParams) {
	RocketLastDeflectionTime[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketLastBeepTime(Handle plugin, int numParams) {
	return view_as<any>(RocketLastBeepTime[GetNativeCell(1)]);
}

public any Native_SetRocketLastBeepTime(Handle plugin, int numParams) {
	RocketLastBeepTime[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketCount(Handle plugin, int numParams) {
	return RocketCount;
}

public any Native_GetLastSpawnTime(Handle plugin, int numParams) {
	return view_as<any>(LastSpawnTime[GetNativeCell(1)]);
}

public any Native_GetRocketBounces(Handle plugin, int numParams) {
	return RocketBounces[GetNativeCell(1)];
}

public any Native_SetRocketBounces(Handle plugin, int numParams) {
	RocketBounces[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketState(Handle plugin, int numParams) {
	return RocketInstanceState[GetNativeCell(1)];
}

public any Native_SetRocketState(Handle plugin, int numParams) {
	Internal_SetRocketState(GetNativeCell(1), view_as<RocketState>(GetNativeCell(2)));
	return 0;
}

// *********************************************************************************
// NATIVES - ROCKET CLASS GETTERS/SETTERS
// *********************************************************************************

public any Native_GetRocketClassCount(Handle plugin, int numParams) {
	return RocketClassCount;
}

public any Native_SetRocketClassCount(Handle plugin, int numParams) {
	RocketClassCount = GetNativeCell(1);
	return 0;
}

public any Native_GetRocketClassBehaviour(Handle plugin, int numParams) {
	return RocketClassBehaviour[GetNativeCell(1)];
}

public any Native_SetRocketClassBehaviour(Handle plugin, int numParams) {
	RocketClassBehaviour[GetNativeCell(1)] = view_as<BehaviourTypes>(GetNativeCell(2));
	return 0;
}

public any Native_GetRocketClassFlags(Handle plugin, int numParams) {
	return RocketClassFlags[GetNativeCell(1)];
}

public any Native_SetRocketClassFlags(Handle plugin, int numParams) {
	RocketClassFlags[GetNativeCell(1)] = view_as<RocketFlags>(GetNativeCell(2));
	return 0;
}

public any Native_GetRocketClassDamage(Handle plugin, int numParams) {
	return view_as<any>(RocketClassDamage[GetNativeCell(1)]);
}

public any Native_SetRocketClassDamage(Handle plugin, int numParams) {
	RocketClassDamage[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassDamageIncrement(Handle plugin, int numParams) {
	return view_as<any>(RocketClassDamageIncrement[GetNativeCell(1)]);
}

public any Native_SetRocketClassDamageIncrement(Handle plugin, int numParams) {
	RocketClassDamageIncrement[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassSpeed(Handle plugin, int numParams) {
	return view_as<any>(RocketClassSpeed[GetNativeCell(1)]);
}

public any Native_SetRocketClassSpeed(Handle plugin, int numParams) {
	RocketClassSpeed[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassSpeedIncrement(Handle plugin, int numParams) {
	return view_as<any>(RocketClassSpeedIncrement[GetNativeCell(1)]);
}

public any Native_SetRocketClassSpeedIncrement(Handle plugin, int numParams) {
	RocketClassSpeedIncrement[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassSpeedLimit(Handle plugin, int numParams) {
	return view_as<any>(RocketClassSpeedLimit[GetNativeCell(1)]);
}

public any Native_SetRocketClassSpeedLimit(Handle plugin, int numParams) {
	RocketClassSpeedLimit[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassTurnRate(Handle plugin, int numParams) {
	return view_as<any>(RocketClassTurnRate[GetNativeCell(1)]);
}

public any Native_SetRocketClassTurnRate(Handle plugin, int numParams) {
	RocketClassTurnRate[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassTurnRateIncrement(Handle plugin, int numParams) {
	return view_as<any>(RocketClassTurnRateIncrement[GetNativeCell(1)]);
}

public any Native_SetRocketClassTurnRateIncrement(Handle plugin, int numParams) {
	RocketClassTurnRateIncrement[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassTurnRateLimit(Handle plugin, int numParams) {
	return view_as<any>(RocketClassTurnRateLimit[GetNativeCell(1)]);
}

public any Native_SetRocketClassTurnRateLimit(Handle plugin, int numParams) {
	RocketClassTurnRateLimit[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassElevationRate(Handle plugin, int numParams) {
	return view_as<any>(RocketClassElevationRate[GetNativeCell(1)]);
}

public any Native_SetRocketClassElevationRate(Handle plugin, int numParams) {
	RocketClassElevationRate[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassElevationLimit(Handle plugin, int numParams) {
	return view_as<any>(RocketClassElevationLimit[GetNativeCell(1)]);
}

public any Native_SetRocketClassElevationLimit(Handle plugin, int numParams) {
	RocketClassElevationLimit[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassRocketsModifier(Handle plugin, int numParams) {
	return view_as<any>(RocketClassRocketsModifier[GetNativeCell(1)]);
}

public any Native_SetRocketClassRocketsModifier(Handle plugin, int numParams) {
	RocketClassRocketsModifier[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassPlayerModifier(Handle plugin, int numParams) {
	return view_as<any>(RocketClassPlayerModifier[GetNativeCell(1)]);
}

public any Native_SetRocketClassPlayerModifier(Handle plugin, int numParams) {
	RocketClassPlayerModifier[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassControlDelay(Handle plugin, int numParams) {
	return view_as<any>(RocketClassControlDelay[GetNativeCell(1)]);
}

public any Native_SetRocketClassControlDelay(Handle plugin, int numParams) {
	RocketClassControlDelay[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}


public any Native_GetRocketClassMaxBounces(Handle plugin, int numParams) {
	return RocketClassMaxBounces[GetNativeCell(1)];
}

public any Native_SetRocketClassMaxBounces(Handle plugin, int numParams) {
	RocketClassMaxBounces[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassName(Handle plugin, int numParams) {
	SetNativeString(2, RocketClassName[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassName(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(RocketClassName[rocketClass], sizeof(RocketClassName[]), buffer);
	return 0;
}

public any Native_GetRocketClassLongName(Handle plugin, int numParams) {
	SetNativeString(2, RocketClassLongName[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassLongName(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(RocketClassLongName[rocketClass], sizeof(RocketClassLongName[]), buffer);
	return 0;
}

public any Native_GetRocketClassModel(Handle plugin, int numParams) {
	SetNativeString(2, RocketClassModel[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassModel(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(RocketClassModel[rocketClass], sizeof(RocketClassModel[]), buffer);
	return 0;
}

public any Native_GetRocketClassBeepInterval(Handle plugin, int numParams) {
	return view_as<any>(RocketClassBeepInterval[GetNativeCell(1)]);
}

public any Native_SetRocketClassBeepInterval(Handle plugin, int numParams) {
	RocketClassBeepInterval[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassSpawnSound(Handle plugin, int numParams) {
	SetNativeString(2, RocketClassSpawnSound[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassSpawnSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(RocketClassSpawnSound[rocketClass], sizeof(RocketClassSpawnSound[]), buffer);
	return 0;
}

public any Native_GetRocketClassBeepSound(Handle plugin, int numParams) {
	SetNativeString(2, RocketClassBeepSound[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassBeepSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(RocketClassBeepSound[rocketClass], sizeof(RocketClassBeepSound[]), buffer);
	return 0;
}

public any Native_GetRocketClassAlertSound(Handle plugin, int numParams) {
	SetNativeString(2, RocketClassAlertSound[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetRocketClassAlertSound(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(RocketClassAlertSound[rocketClass], sizeof(RocketClassAlertSound[]), buffer);
	return 0;
}

public any Native_GetRocketClassCritChance(Handle plugin, int numParams) {
	return view_as<any>(RocketClassCritChance[GetNativeCell(1)]);
}

public any Native_SetRocketClassCritChance(Handle plugin, int numParams) {
	RocketClassCritChance[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassTargetWeight(Handle plugin, int numParams) {
	return view_as<any>(RocketClassTargetWeight[GetNativeCell(1)]);
}

public any Native_SetRocketClassTargetWeight(Handle plugin, int numParams) {
	RocketClassTargetWeight[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassBounceScale(Handle plugin, int numParams) {
	return view_as<any>(RocketClassBounceScale[GetNativeCell(1)]);
}

public any Native_SetRocketClassBounceScale(Handle plugin, int numParams) {
	RocketClassBounceScale[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassOrbitTightness(Handle plugin, int numParams) {
	return view_as<any>(RocketClassOrbitTightness[GetNativeCell(1)]);
}

public any Native_SetRocketClassOrbitTightness(Handle plugin, int numParams) {
	RocketClassOrbitTightness[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassMaxSpeed(Handle plugin, int numParams) {
	return view_as<any>(RocketClassMaxSpeed[GetNativeCell(1)]);
}

public any Native_SetRocketClassMaxSpeed(Handle plugin, int numParams) {
	RocketClassMaxSpeed[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassMaxDeflections(Handle plugin, int numParams) {
	return RocketClassMaxDeflections[GetNativeCell(1)];
}

public any Native_SetRocketClassMaxDeflections(Handle plugin, int numParams) {
	RocketClassMaxDeflections[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassBounceVerticalScale(Handle plugin, int numParams) {
	return view_as<any>(RocketClassBounceVerticalScale[GetNativeCell(1)]);
}

public any Native_SetRocketClassBounceVerticalScale(Handle plugin, int numParams) {
	RocketClassBounceVerticalScale[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassBounceMaxVerticalSpeed(Handle plugin, int numParams) {
	return view_as<any>(RocketClassBounceMaxVerticalSpeed[GetNativeCell(1)]);
}

public any Native_SetRocketClassBounceMaxVerticalSpeed(Handle plugin, int numParams) {
	RocketClassBounceMaxVerticalSpeed[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetRocketClassDragPauseDuration(Handle plugin, int numParams) {
	return view_as<any>(RocketClassDragPauseDuration[GetNativeCell(1)]);
}

public any Native_SetRocketClassDragPauseDuration(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	float duration = GetNativeCell(2);
	RocketClassDragPauseDuration[rocketClass] = duration;

	float tickInterval = GetTickInterval();
	int dragTicks = 0;
	if (tickInterval > 0.0 && duration > 0.0)
	{
		dragTicks = RoundToCeil(duration / tickInterval);
	}
	RocketClassDragPauseTicks[rocketClass] = dragTicks;

	return 0;
}

// *********************************************************************************
// NATIVES - SPAWNER GETTERS/SETTERS
// *********************************************************************************

public any Native_GetSpawnersName(Handle plugin, int numParams) {
	SetNativeString(2, SpawnersName[GetNativeCell(1)], GetNativeCell(3));
	return 0;
}

public any Native_SetSpawnersName(Handle plugin, int numParams) {
	int spawnerClass = GetNativeCell(1);
	int maxLen;
	GetNativeStringLength(2, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(2, buffer, maxLen + 1);
	strcopy(SpawnersName[spawnerClass], sizeof(SpawnersName[]), buffer);
	return 0;
}

public any Native_GetSpawnersMaxRockets(Handle plugin, int numParams) {
	return SpawnersMaxRockets[GetNativeCell(1)];
}

public any Native_SetSpawnersMaxRockets(Handle plugin, int numParams) {
	SpawnersMaxRockets[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetSpawnersInterval(Handle plugin, int numParams) {
	return view_as<any>(SpawnersInterval[GetNativeCell(1)]);
}

public any Native_SetSpawnersInterval(Handle plugin, int numParams) {
	SpawnersInterval[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetSpawnersChancesTable(Handle plugin, int numParams) {
	return CloneHandle(SpawnersChancesTable[GetNativeCell(1)], plugin);
}

public any Native_SetSpawnersChancesTable(Handle plugin, int numParams) {
	int spawnerClass = GetNativeCell(1);
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
	SpawnersCount = GetNativeCell(1);
	return 0;
}

// *********************************************************************************
// NATIVES - SPAWN POINT GETTERS/SETTERS
// *********************************************************************************

public any Native_GetCurrentRedSpawn(Handle plugin, int numParams) {
	return CurrentRedSpawn;
}

public any Native_SetCurrentRedSpawn(Handle plugin, int numParams) {
	CurrentRedSpawn = GetNativeCell(1);
	return 0;
}

public any Native_GetSpawnPointsRedCount(Handle plugin, int numParams) {
	return SpawnPointsRedCount;
}

public any Native_SetSpawnPointsRedCount(Handle plugin, int numParams) {
	SpawnPointsRedCount = GetNativeCell(1);
	return 0;
}

public any Native_GetSpawnPointsRedClass(Handle plugin, int numParams) {
	return SpawnPointsRedClass[GetNativeCell(1)];
}

public any Native_SetSpawnPointsRedClass(Handle plugin, int numParams) {
	SpawnPointsRedClass[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetSpawnPointsRedEntity(Handle plugin, int numParams) {
	return SpawnPointsRedEntity[GetNativeCell(1)];
}

public any Native_SetSpawnPointsRedEntity(Handle plugin, int numParams) {
	SpawnPointsRedEntity[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetCurrentBluSpawn(Handle plugin, int numParams) {
	return CurrentBluSpawn;
}

public any Native_SetCurrentBluSpawn(Handle plugin, int numParams) {
	CurrentBluSpawn = GetNativeCell(1);
	return 0;
}

public any Native_GetSpawnPointsBluCount(Handle plugin, int numParams) {
	return SpawnPointsBluCount;
}

public any Native_SetSpawnPointsBluCount(Handle plugin, int numParams) {
	SpawnPointsBluCount = GetNativeCell(1);
	return 0;
}

public any Native_GetSpawnPointsBluClass(Handle plugin, int numParams) {
	return SpawnPointsBluClass[GetNativeCell(1)];
}

public any Native_SetSpawnPointsBluClass(Handle plugin, int numParams) {
	SpawnPointsBluClass[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

public any Native_GetSpawnPointsBluEntity(Handle plugin, int numParams) {
	return SpawnPointsBluEntity[GetNativeCell(1)];
}

public any Native_SetSpawnPointsBluEntity(Handle plugin, int numParams) {
	SpawnPointsBluEntity[GetNativeCell(1)] = GetNativeCell(2);
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

public any Native_GetRocketClassCmdsOnSpawn(Handle plugin, int numParams) {
	return CloneHandle(RocketClassCmdsOnSpawn[GetNativeCell(1)], plugin);
}

public any Native_SetRocketClassCmdsOnSpawn(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	DataPack cmds = view_as<DataPack>(GetNativeCell(2));
	DataPack clonedPack = view_as<DataPack>(CloneHandle(cmds, GetMyHandle()));
	delete RocketClassCmdsOnSpawn[rocketClass];
	RocketClassCmdsOnSpawn[rocketClass] = clonedPack;
	return 0;
}

public any Native_GetRocketClassCmdsOnDeflect(Handle plugin, int numParams) {
	return CloneHandle(RocketClassCmdsOnDeflect[GetNativeCell(1)], plugin);
}

public any Native_SetRocketClassCmdsOnDeflect(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	DataPack cmds = view_as<DataPack>(GetNativeCell(2));
	DataPack clonedPack = view_as<DataPack>(CloneHandle(cmds, GetMyHandle()));
	delete RocketClassCmdsOnDeflect[rocketClass];
	RocketClassCmdsOnDeflect[rocketClass] = clonedPack;
	return 0;
}

public any Native_GetRocketClassCmdsOnKill(Handle plugin, int numParams) {
	return CloneHandle(RocketClassCmdsOnKill[GetNativeCell(1)], plugin);
}

public any Native_SetRocketClassCmdsOnKill(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	DataPack cmds = view_as<DataPack>(GetNativeCell(2));
	DataPack clonedPack = view_as<DataPack>(CloneHandle(cmds, GetMyHandle()));
	delete RocketClassCmdsOnKill[rocketClass];
	RocketClassCmdsOnKill[rocketClass] = clonedPack;
	return 0;
}

public any Native_GetRocketClassCmdsOnExplode(Handle plugin, int numParams) {
	return CloneHandle(RocketClassCmdsOnExplode[GetNativeCell(1)], plugin);
}

public any Native_SetRocketClassCmdsOnExplode(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	DataPack cmds = view_as<DataPack>(GetNativeCell(2));
	DataPack clonedPack = view_as<DataPack>(CloneHandle(cmds, GetMyHandle()));
	delete RocketClassCmdsOnExplode[rocketClass];
	RocketClassCmdsOnExplode[rocketClass] = clonedPack;
	return 0;
}

public any Native_GetRocketClassCmdsOnNoTarget(Handle plugin, int numParams) {
	return CloneHandle(RocketClassCmdsOnNoTarget[GetNativeCell(1)], plugin);
}

public any Native_SetRocketClassCmdsOnNoTarget(Handle plugin, int numParams) {
	int rocketClass = GetNativeCell(1);
	DataPack cmds = view_as<DataPack>(GetNativeCell(2));
	DataPack clonedPack = view_as<DataPack>(CloneHandle(cmds, GetMyHandle()));
	delete RocketClassCmdsOnNoTarget[rocketClass];
	RocketClassCmdsOnNoTarget[rocketClass] = clonedPack;
	return 0;
}

// *********************************************************************************
// NATIVES - ACTION FUNCTIONS
// *********************************************************************************

public any Native_CreateRocket(Handle plugin, int numParams) {
	CreateRocket(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), GetNativeCell(4));
	return 0;
}

public any Native_DestroyRocket(Handle plugin, int numParams) {
	DestroyRocket(GetNativeCell(1));
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
	int maxLen;
	GetNativeStringLength(1, maxLen);
	char[] buffer = new char[maxLen + 1];
	GetNativeString(1, buffer, maxLen + 1);
	ParseConfigurations(buffer);
	return 0;
}

public any Native_PopulateSpawnPoints(Handle plugin, int numParams) {
	PopulateSpawnPoints();
	return 0;
}

public any Native_HomingRocketThink(Handle plugin, int numParams) {
	HomingRocketThink(GetNativeCell(1));
	return 0;
}

public any Native_RocketLegacyThink(Handle plugin, int numParams) {
	RocketLegacyThink(GetNativeCell(1));
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
