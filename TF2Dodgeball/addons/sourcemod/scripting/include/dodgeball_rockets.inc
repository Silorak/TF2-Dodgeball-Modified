#if defined _dodgeball_rockets_included
  #endinput
#endif
#define _dodgeball_rockets_included

/**
 * All logic directly related to creating, managing, and controlling rockets.
 */

/**
 * Creates and spawns a new rocket from a spawner.
 *
 * @param spawnerEntity    The spawner entity to spawn from.
 * @param spawnerClass     The spawner class index (determines spawn chances).
 * @param team             The team the rocket belongs to (TFTeam_Red or TFTeam_Blue).
 * @param rocketClass      Optional rocket class (-1 for random from spawner chances).
 */
void CreateRocket(int spawnerEntity, int spawnerClass, int team, int rocketClass = -1)
{
	int index = FindFreeRocketSlot();
	if (index == -1) return;

	rocketClass = rocketClass == -1 ? GetRandomRocketClass(spawnerClass) : rocketClass;
	RocketFlags flags = RocketClassFlags[rocketClass];

	int classRef = rocketClass;
	RocketFlags flagsRef = flags;
	Action result = Forward_OnRocketCreatedPre(index, classRef, flagsRef);

	if (result == Plugin_Stop || result == Plugin_Handled)
	{
		return;
	}
	else if (result == Plugin_Changed)
	{
		rocketClass = classRef;
		flags = flagsRef;
	}

	int entity = CreateEntityByName(TestFlags(flags, RocketFlag_IsAnimated) ? "tf_projectile_sentryrocket" : "tf_projectile_rocket");
	if (entity == -1) return;

	float position[3], angles[3], direction[3];
	GetEntPropVector(spawnerEntity, Prop_Send, "m_vecOrigin", position);
	GetEntPropVector(spawnerEntity, Prop_Send, "m_angRotation", angles);
	GetAngleVectors(angles, direction, NULL_VECTOR, NULL_VECTOR);

	SetEntProp(entity,    Prop_Send, "m_bCritical",    (GetURandomFloatRange(0.0, 100.0) <= RocketClassCritChance[rocketClass]) ? 1 : 0, 1);
	SetEntProp(entity,    Prop_Send, "m_iTeamNum",     (TestFlags(flags, RocketFlag_IsNeutral)) ? 1 : team, 1);
	SetEntProp(entity,    Prop_Send, "m_iDeflected",   0);
	TeleportEntity(entity, position, angles, view_as<float>({0.0, 0.0, 0.0}));

	int targetTeam = (TestFlags(flags, RocketFlag_IsNeutral)) ? 0 : GetAnalogueTeam(team);
	int target     = SelectTarget(targetTeam);
	int owner      = SelectTarget(GetAnalogueTeam(GetClientTeam(target)));
	
	SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", owner);
	int weapon = GetPlayerWeaponSlot(owner, TFWeaponSlot_Primary);
	SetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher", weapon == -1 ? entity : weapon);
	SetEntPropEnt(entity, Prop_Send, "m_hLauncher", weapon == -1 ? entity : weapon);

	float modifier = CalculateModifier(rocketClass, 0);
	RocketIsValid[index]            = true;
	RocketInstanceFlags[index]      = flags;
	RocketEntity[index]             = EntIndexToEntRef(entity);
	RocketTarget[index]             = EntIndexToEntRef(target);
	RocketClass[index]              = rocketClass;
	RocketDeflections[index]        = 0;
	RocketEventDeflections[index]   = 0;
	RocketBounces[index]            = 0;
	RocketHomingPaused[index]       = false;
	RocketIsDragPause[index]        = false;
	RocketDragPauseEndTick[index]   = 0;
	RocketLastDeflectionTime[index] = GetGameTime();
	RocketLastBeepTime[index]       = GetGameTime();
	RocketSpeed[index]              = CalculateRocketSpeed(rocketClass, modifier);
	RocketMphSpeed[index]           = RocketSpeed[index] * HAMMER_TO_MPH;
	Internal_SetRocketState(index, RocketState_None);

	CopyVectors(direction, RocketDirection[index]);
	SetEntDataFloat(entity, DamageOffset, CalculateRocketDamage(rocketClass, modifier), true);
	DispatchSpawn(entity);

	if (TestFlags(flags, RocketFlag_CustomModel))
	{
		SetEntityModel(entity, RocketClassModel[rocketClass]);
		UpdateRocketSkin(entity, team, TestFlags(flags, RocketFlag_IsNeutral));
	}

	if (TestFlags(flags, RocketFlag_OnSpawnCmd))
	{
		ExecuteCommands(RocketClassCmdsOnSpawn[rocketClass], rocketClass, entity, 0, target, LastDeadClient, RocketSpeed[index], 0, RocketMphSpeed[index]);
	}

	EmitRocketSound(RocketSound_Spawn, rocketClass, entity, target, flags);
	EmitRocketSound(RocketSound_Alert, rocketClass, entity, target, flags);

	RocketCount++;
	RocketsFired++;
	LastSpawnTime[index] = GetGameTime();
	NextSpawnTime = GetGameTime() + SpawnersInterval[spawnerClass];

	SDKHook(entity, SDKHook_StartTouch, OnStartTouch);

	// Kill the engine's default trail and attach a server-controlled replacement.
	// Must happen after DispatchSpawn (which creates the engine trail) and before
	// the forward (so subplugins see a clean state).
	InitRocketTrail(entity);

	// Safety: the engine may write m_hEffectEntity a frame after DispatchSpawn.
	// Schedule a follow-up kill to catch any late engine trail.
	DataPack spawnPack = new DataPack();
	spawnPack.WriteCell(index);
	spawnPack.WriteCell(EntIndexToEntRef(entity));
	RequestFrame(Frame_PostSpawnTrailFix, spawnPack);

	Forward_OnRocketCreated(index, entity);
}

/**
 * Destroys a rocket by its internal index.
 *
 * @param index    The rocket's internal index.
 */
void DestroyRocket(int index)
{
	if (!IsValidRocket(index)) return;

	int entity = EntRefToEntIndex(RocketEntity[index]);
	if (entity != INVALID_ENT_REFERENCE)
	{
		RemoveEntity(entity);
	}
	RocketIsValid[index] = false;
	RocketCount--;
}

/**
 * Destroys all active rockets.
 */
void DestroyRockets()
{
	for (int index = 0; index < MAX_ROCKETS; index++)
	{
		DestroyRocket(index);
	}
	RocketCount = 0;
}

// ============================================================================
// Engine Trail Cleanup
//
// TF2's engine creates a new trail particle (info_particle_system) every time
// a rocket is deflected, storing it in m_hEffectEntity. The previous trail is
// orphaned — still rendering, still consuming resources. After 100+ deflects
// this causes FPS drops and client crashes.
//
// We kill these engine-created trails on spawn and after each deflect.
// The client renders its own trail from rockettrail.pcf automatically —
// that's the intended visual. For custom trails, use the tfdb_trails subplugin.
// ============================================================================

/**
 * Kills the engine's trail particle attached to a rocket via m_hEffectEntity.
 * This is the particle the engine creates on spawn and re-creates on every deflect.
 *
 * @param entity    The rocket entity index.
 */
void KillEngineTrail(int entity)
{
	if (!IsValidEntity(entity)) return;

	int effect = GetEntPropEnt(entity, Prop_Send, "m_hEffectEntity");
	if (effect == -1 || !IsValidEntity(effect)) return;

	AcceptEntityInput(effect, "ClearParent");
	AcceptEntityInput(effect, "Stop");
	RemoveEntity(effect);
	SetEntPropEnt(entity, Prop_Send, "m_hEffectEntity", -1);
}

/**
 * Kills the engine's default trail on a newly created rocket.
 *
 * @param index     The rocket's internal index.
 * @param entity    The rocket entity index.
 */
void InitRocketTrail(int entity)
{
	KillEngineTrail(entity);
}

/**
 * RequestFrame callback — kills the engine's newly stacked trail after deflect.
 * The engine writes m_hEffectEntity during Deflected(), which hasn't finished
 * when the object_deflected event fires.
 *
 * @param pack    DataPack containing rocket index and entity ref.
 */
void Frame_PostDeflectTrailFix(DataPack pack)
{
	pack.Reset();
	int index     = pack.ReadCell();
	int entityRef = pack.ReadCell();
	delete pack;

	int entity = EntRefToEntIndex(entityRef);
	if (entity == -1 || !IsValidEntity(entity)) return;
	if (!IsValidRocket(index)) return;
	if (RocketEntity[index] != entityRef) return;

	KillEngineTrail(entity);
}

/**
 * RequestFrame callback — kills any engine trail created after DispatchSpawn.
 * The engine may write m_hEffectEntity a frame after spawn.
 *
 * @param pack    DataPack containing rocket index and entity ref.
 */
void Frame_PostSpawnTrailFix(DataPack pack)
{
	pack.Reset();
	int index     = pack.ReadCell();
	int entityRef = pack.ReadCell();
	delete pack;

	int entity = EntRefToEntIndex(entityRef);
	if (entity == -1 || !IsValidEntity(entity)) return;
	if (!IsValidRocket(index)) return;
	if (RocketEntity[index] != entityRef) return;

	KillEngineTrail(entity);
}

/**
 * Checks if a rocket index is valid and the rocket exists.
 *
 * @param index    The rocket's internal index.
 * @return         True if valid, false otherwise.
 */
bool IsValidRocket(int index)
{
	if (!((index >= 0) && RocketIsValid[index])) return false;
	
	if (EntRefToEntIndex(RocketEntity[index]) != -1) return true;

	RocketIsValid[index] = false;
	RocketCount--;

	return false;
}

/**
 * Finds the next valid rocket after the given index.
 *
 * @param index    Starting index to search from.
 * @return         Next valid rocket index, or -1 if none found.
 */
int FindNextValidRocket(int index)
{
	for (int current = index + 1; current < MAX_ROCKETS; current++)
	{
		if (IsValidRocket(current)) return current;
	}
	return -1;
}

/**
 * Finds a free slot in the rocket array.
 *
 * @return          Free rocket index, or -1 if array is full.
 */
int FindFreeRocketSlot()
{
	for (int current = 0; current < MAX_ROCKETS; current++)
	{
		if (!IsValidRocket(current)) return current;
	}

	return -1;
}

/**
 * Finds a rocket's internal index by its entity index.
 *
 * @param entity   The rocket's entity index.
 * @return         Internal rocket index, or -1 if not found.
 */
int FindRocketByEntity(int entity)
{
	int index = -1;
	while ((index = FindNextValidRocket(index)) != -1)
	{
		if (EntRefToEntIndex(RocketEntity[index]) == entity) return index;
	}
	return -1;
}

/**
 * Processes a rocket deflection: reads the deflector's aim, selects a new target,
 * recalculates speed/damage, checks for steals, and fires forwards/commands.
 * Shared by HomingRocketThink, SharedRocketThink, and RocketLegacyThink.
 *
 * @param index            Rocket internal index.
 * @param entity           Rocket entity index.
 * @param rocketClass      Rocket class index.
 * @param flags            Rocket instance flags.
 * @param team             Rocket's current team.
 * @param targetTeam       Team to select new target from.
 * @param deflectionCount  Current event deflection count.
 * @param modifier         Speed/damage modifier for current deflection count.
 * @param clearDragging    True to clear RocketState_Dragging (homing/shared).
 *                         False for legacy (never enters drag state).
 * @return                 False if Forward_OnRocketDeflectPre blocked the deflection.
 */
bool ProcessDeflection(int index, int entity, int rocketClass, RocketFlags flags,
                       int team, int targetTeam, int deflectionCount, float modifier,
                       bool clearDragging)
{
	int client = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	bool validClient = (client >= 1 && client <= MaxClients && IsClientInGame(client));

	if (clearDragging)
		Internal_SetRocketState(index, (RocketInstanceState[index] & ~(RocketState_Dragging | RocketState_Stolen)));
	else
		Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_Stolen));

	if (validClient)
	{
		float viewAngles[3], direction[3];
		GetClientEyeAngles(client, viewAngles);
		GetAngleVectors(viewAngles, direction, NULL_VECTOR, NULL_VECTOR);
		CopyVectors(direction, RocketDirection[index]);
		UpdateRocketSkin(entity, team, TestFlags(flags, RocketFlag_IsNeutral));

		if (!(flags & RocketFlag_CanBeStolen))
		{
			CheckStolenRocket(client, index);
		}
	}

	int target = -1;

	// Target lock: if enabled, reuse the previous target for this deflector
	if (validClient && UseTargetLock && (!UseTargetLockBotOnly || IsFakeClient(client)))
	{
		int prevTarget = EntRefToEntIndex(LockedTarget[client]);
		if (prevTarget != -1 && IsClientInGame(prevTarget) && IsPlayerAlive(prevTarget))
		{
			// Verify target is on the correct team (or rocket is neutral)
			if (TestFlags(flags, RocketFlag_IsNeutral) || GetClientTeam(client) != GetClientTeam(prevTarget))
			{
				target = prevTarget;
			}
		}
	}

	if (target == -1)
	{
		target = SelectTarget(targetTeam, index);
	}

	// Store this target as the locked target for next deflection
	if (validClient) LockedTarget[client] = EntIndexToEntRef(target);

	RocketTarget[index]             = EntIndexToEntRef(target);
	RocketDeflections[index]        = deflectionCount;
	RocketLastDeflectionTime[index] = GetGameTime();
	RocketSpeed[index]              = CalculateRocketSpeed(rocketClass, modifier);
	SetEntDataFloat(entity, DamageOffset, CalculateRocketDamage(rocketClass, modifier), true);

	if (TestFlags(flags, RocketFlag_ElevateOnDeflect)) RocketInstanceFlags[index] |= RocketFlag_Elevating;

	if ((flags & RocketFlag_IsSpeedLimited) && (RocketSpeed[index] >= RocketClassSpeedLimit[rocketClass]))
	{
		RocketSpeed[index] = RocketClassSpeedLimit[rocketClass];
	}

	RocketMphSpeed[index] = RocketSpeed[index] * HAMMER_TO_MPH;

	if (CvarStealPreventionDamage.BoolValue && (RocketInstanceState[index] & RocketState_Stolen))
	{
		SetEntDataFloat(entity, DamageOffset, 0.0, true);
	}

	if (flags & RocketFlag_TeamlessHits)
	{
		SetEntProp(entity, Prop_Send, "m_iTeamNum", 1, 1);
	}

	int targetRef = target;
	Action deflectResult = Forward_OnRocketDeflectPre(index, entity, client, targetRef);

	if (deflectResult == Plugin_Stop || deflectResult == Plugin_Handled)
	{
		return false;
	}
	else if (deflectResult == Plugin_Changed)
	{
		target = targetRef;
		RocketTarget[index] = EntIndexToEntRef(target);
	}

	EmitRocketSound(RocketSound_Alert, rocketClass, entity, target, flags);
	if (TestFlags(flags, RocketFlag_OnDeflectCmd))
	{
		ExecuteCommands(RocketClassCmdsOnDeflect[rocketClass], rocketClass, entity, client, target, LastDeadClient, RocketSpeed[index], deflectionCount, RocketMphSpeed[index]);
	}
	Forward_OnRocketDeflect(index, entity, client);

	return true;
}

/**
 * Main think function for homing rockets. Handles tracking, dragging,
 * deflection, target switching, and all per-frame rocket behaviour.
 * Called from the logic timer in dodgeball_core.inc (~10Hz due to SourceMod's 0.1s min timer).
 *
 * @param index    The rocket's internal index.
 */
void HomingRocketThink(int index)
{
	int entity           = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	int rocketClass      = RocketClass[index];
	RocketFlags flags    = RocketInstanceFlags[index];
	int target           = EntRefToEntIndex(RocketTarget[index]);
	int team             = GetEntProp(entity, Prop_Send, "m_iTeamNum", 1);
	int targetTeam       = (TestFlags(flags, RocketFlag_IsNeutral)) ? 0 : GetAnalogueTeam(team);
	int deflectionCount  = RocketEventDeflections[index];
	float modifier       = CalculateModifier(rocketClass, deflectionCount);
	
	// --- Deflection detected: pause homing, defer aim reading to per-frame check ---
	if ((deflectionCount > RocketDeflections[index]) && !(RocketInstanceState[index] & RocketState_Dragging))
	{
		RocketHomingPaused[index] = true;
		RocketIsDragPause[index] = true;
		
		// Drag window is stored as an absolute game tick for deterministic behavior.
		int pauseTicks = RocketClassDragPauseTicks[rocketClass];
		RocketDragPauseEndTick[index] = GetGameTickCount() + pauseTicks;
		
		Internal_SetRocketState(index, (RocketInstanceState[index] | (RocketState_CanDrag | RocketState_Dragging)));
	}

	// --- Drag pause expired: process deflection per-frame (allows sub-100ms drag) ---
	if (RocketHomingPaused[index] && RocketIsDragPause[index] && GetGameTickCount() >= RocketDragPauseEndTick[index])
	{
		if (deflectionCount > RocketDeflections[index])
		{
			if (!ProcessDeflection(index, entity, rocketClass, flags, team, targetTeam, deflectionCount, modifier, true))
			{
				RocketHomingPaused[index] = false;
				RocketIsDragPause[index] = false;
				return;
			}
		}

		// Apply parameters and re-enable smooth homing
		ApplyRocketParameters(index);
		RocketHomingPaused[index] = false;
		RocketIsDragPause[index] = false;
	}

	// --- Normal homing: lerp toward target (only when not paused) ---
	if (!RocketHomingPaused[index])
	{
		if (!IsValidClient(target, true))
		{
			int owner = target;
			target = SelectTarget(targetTeam, index);

			if (!IsValidClient(target, true)) return;
			RocketTarget[index] = EntIndexToEntRef(target);
			EmitRocketSound(RocketSound_Alert, rocketClass, entity, target, flags);

			if (TestFlags(flags, RocketFlag_OnNoTargetCmd))
			{
				ExecuteCommands(RocketClassCmdsOnNoTarget[rocketClass], rocketClass, entity, owner, target, LastDeadClient, RocketSpeed[index], deflectionCount, RocketMphSpeed[index]);
			}

			if (CvarNoTargetRedirectDamage.BoolValue)
			{
				SetEntDataFloat(entity, DamageOffset, 0.0, true);
			}
			Forward_OnRocketNoTarget(index, target, owner);
		}
		else
		{
			if ((GetGameTime() - RocketLastDeflectionTime[index]) >= RocketClassControlDelay[rocketClass])
			{
				// Scale turn rate from "per TICK_BASE_INTERVAL" to "per frame" using GetTickInterval().
				float tickScale = GetTickInterval() / TICK_BASE_INTERVAL;
				float turnRate = CalculateRocketTurnRate(rocketClass, modifier) * tickScale;
				float directionToTarget[3]; CalculateDirectionToClient(entity, target, directionToTarget);

				if (RocketInstanceFlags[index] & RocketFlag_Elevating)
				{
					directionToTarget[2] = RocketDirection[index][2];
				}

				if ((RocketInstanceFlags[index] & RocketFlag_IsTRLimited) && (turnRate >= RocketClassTurnRateLimit[rocketClass] * tickScale))
				{
					turnRate = RocketClassTurnRateLimit[rocketClass] * tickScale;
				}
				LerpVectors(RocketDirection[index], directionToTarget, RocketDirection[index], turnRate);
			}
		}

		// --- Smooth elevation (OnGameFrame, frame-rate independent) ---
		if (UseSmoothElevation && (RocketInstanceFlags[index] & RocketFlag_Elevating))
		{
			if ((GetGameTime() - RocketLastDeflectionTime[index]) >= RocketClassControlDelay[rocketClass])
			{
				float elevRate = RocketClassElevationRate[rocketClass] * (GetTickInterval() / TICK_BASE_INTERVAL);
				if (RocketDirection[index][2] < RocketClassElevationLimit[rocketClass])
				{
					RocketDirection[index][2] = FMin(RocketDirection[index][2] + elevRate, RocketClassElevationLimit[rocketClass]);
				}
				else
				{
					RocketInstanceFlags[index] &= ~RocketFlag_Elevating;
				}
			}
		}

		if (!(RocketInstanceState[index] & RocketState_Bouncing))
		{
			ApplyRocketParameters(index);
		}
	}
}

/**
 * Handles logic that is shared between all rocket behaviours, like sounds and delay checks.
 * This is called from the logic timer in dodgeball_core.inc
 */
void SharedRocketThink(int index)
{
	int entity           = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	int rocketClass      = RocketClass[index];
	RocketFlags flags    = RocketInstanceFlags[index];
	int target           = EntRefToEntIndex(RocketTarget[index]);
	int team             = GetEntProp(entity, Prop_Send, "m_iTeamNum", 1);
	int targetTeam       = (TestFlags(flags, RocketFlag_IsNeutral)) ? 0 : GetAnalogueTeam(team);
	int deflectionCount  = RocketEventDeflections[index];
	float modifier       = CalculateModifier(rocketClass, deflectionCount);
	
	// --- Handle paused state: bounce unpauses are handled here (timer-based) ---
	// Drag unpauses are handled per-frame in HomingRocketThink for sub-100ms precision.
	if (RocketHomingPaused[index] && !RocketIsDragPause[index])
	{
		// Process pending deflection on the logic timer (bounce unpause)
		if (deflectionCount > RocketDeflections[index])
		{
			if (!ProcessDeflection(index, entity, rocketClass, flags, team, targetTeam, deflectionCount, modifier, true))
			{
				RocketHomingPaused[index] = false;
				return;
			}
		}

		// Apply parameters once on unpause and re-enable smooth homing
		ApplyRocketParameters(index);
		RocketHomingPaused[index] = false;
	}

	// --- Elevation (runs at logic timer rate when smooth elevation is off) ---
	if (!(deflectionCount > RocketDeflections[index]))
	{
		if (((GetGameTime() - RocketLastDeflectionTime[index]) >= RocketClassControlDelay[rocketClass]) &&
		    (RocketInstanceFlags[index] & RocketFlag_Elevating) && !UseSmoothElevation)
		{
			if (RocketDirection[index][2] < RocketClassElevationLimit[rocketClass])
			{
				RocketDirection[index][2] = FMin(RocketDirection[index][2] + RocketClassElevationRate[rocketClass], RocketClassElevationLimit[rocketClass]);
			}
			else
			{
				RocketInstanceFlags[index] &= ~RocketFlag_Elevating;
			}
		}

		if ((GetGameTime() - RocketLastBeepTime[index]) >= RocketClassBeepInterval[rocketClass])
		{
			EmitRocketSound(RocketSound_Beep, rocketClass, entity, target, flags);
			RocketLastBeepTime[index] = GetGameTime();
		}

		if (CvarDelayPrevention.BoolValue)
		{
			CheckRoundDelays(index);
		}
	}

	Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_Bouncing));
}

/**
 * Think function for legacy homing rockets. Uses instant direction changes
 * instead of smooth tracking. Called from the logic timer.
 *
 * @param index    The rocket's internal index.
 */
void RocketLegacyThink(int index)
{
	int entity           = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	int rocketClass      = RocketClass[index];
	RocketFlags flags    = RocketInstanceFlags[index];
	int target           = EntRefToEntIndex(RocketTarget[index]);
	int team             = GetEntProp(entity, Prop_Send, "m_iTeamNum", 1);
	int targetTeam       = (TestFlags(flags, RocketFlag_IsNeutral)) ? 0 : GetAnalogueTeam(team);
	int deflectionCount  = RocketEventDeflections[index];
	float modifier       = CalculateModifier(rocketClass, deflectionCount);

	if (!IsValidClient(target, true))
	{
		int owner = target;
		target = SelectTarget(targetTeam, index);

		if (!IsValidClient(target, true)) return;
		
		RocketTarget[index] = EntIndexToEntRef(target);
		EmitRocketSound(RocketSound_Alert, rocketClass, entity, target, flags);

		if (TestFlags(flags, RocketFlag_OnNoTargetCmd))
		{
			ExecuteCommands(RocketClassCmdsOnNoTarget[rocketClass], rocketClass, entity, owner, target, LastDeadClient, RocketSpeed[index], deflectionCount, RocketMphSpeed[index]);
		}

		if (CvarNoTargetRedirectDamage.BoolValue)
		{
			SetEntDataFloat(entity, DamageOffset, 0.0, true);
		}
		Forward_OnRocketNoTarget(index, target, owner);
	}
	else if (deflectionCount > RocketDeflections[index])
	{
		if (!ProcessDeflection(index, entity, rocketClass, flags, team, targetTeam, deflectionCount, modifier, false))
		{
			return;
		}
	}
	else
	{
		if ((GetGameTime() - RocketLastDeflectionTime[index]) >= RocketClassControlDelay[rocketClass])
		{
			float turnRate = CalculateRocketTurnRate(rocketClass, modifier);
			float directionToTarget[3];
			CalculateDirectionToClient(entity, target, directionToTarget);

			if (RocketInstanceFlags[index] & RocketFlag_Elevating)
			{
				if (RocketDirection[index][2] < RocketClassElevationLimit[rocketClass])
				{
					RocketDirection[index][2] = FMin(RocketDirection[index][2] + RocketClassElevationRate[rocketClass], RocketClassElevationLimit[rocketClass]);
					directionToTarget[2] = RocketDirection[index][2];
				}
				else
				{
					RocketInstanceFlags[index] &= ~RocketFlag_Elevating;
				}
			}

			if ((RocketInstanceFlags[index] & RocketFlag_IsTRLimited) && (turnRate >= RocketClassTurnRateLimit[rocketClass]))
			{
				turnRate = RocketClassTurnRateLimit[rocketClass];
			}
			LerpVectors(RocketDirection[index], directionToTarget, RocketDirection[index], turnRate);
		}
	}
	ApplyRocketParameters(index);
}

/** Calculates the modifier based on deflections, rockets fired, and player count. */
float CalculateModifier(int rocketClass, int deflections)
{
	return deflections +
	       (RocketsFired * RocketClassRocketsModifier[rocketClass]) +
	       (PlayerCount * RocketClassPlayerModifier[rocketClass]);
}

/** Calculates rocket damage based on class settings and modifier. */
float CalculateRocketDamage(int rocketClass, float modifier)
{
	return RocketClassDamage[rocketClass] + RocketClassDamageIncrement[rocketClass] * modifier;
}

/** Calculates rocket speed based on class settings and modifier. */
float CalculateRocketSpeed(int rocketClass, float modifier)
{
	return RocketClassSpeed[rocketClass] + RocketClassSpeedIncrement[rocketClass] * modifier;
}

/** Calculates turn rate based on class settings and modifier. */
float CalculateRocketTurnRate(int rocketClass, float modifier)
{
	if (UseOrbitCoefficient && RocketClassOrbitTightness[rocketClass] > 0.0)
	{
		// Scale by 0.001 so config values use a friendly 0.1–1.0 range
		// (0.3 ≈ default turn rate feel, 0.1 = loose, 1.0 = tight)
		return CalculateRocketSpeed(rocketClass, modifier) * RocketClassOrbitTightness[rocketClass] * 0.001;
	}
	return RocketClassTurnRate[rocketClass] + RocketClassTurnRateIncrement[rocketClass] * modifier;
}

/** Calculates the normalized direction vector from rocket to client. */
void CalculateDirectionToClient(int entity, int client, float out[3])
{
	float rocketPosition[3]; GetEntPropVector(entity, Prop_Send, "m_vecOrigin", rocketPosition);
	GetClientEyePosition(client, out);
	MakeVectorFromPoints(rocketPosition, out, out);
	NormalizeVector(out, out);
}

/** Applies rocket direction and speed to the entity's velocity. */
void ApplyRocketParameters(int index)
{
	int entity = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	float angles[3]; GetVectorAngles(RocketDirection[index], angles);
	float velocity[3]; CopyVectors(RocketDirection[index], velocity);

	ScaleVector(velocity, RocketSpeed[index]);
	SetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", velocity);
	SetEntPropVector(entity, Prop_Send, "m_angRotation", angles);
}

/** Updates the rocket's skin based on team and neutral status. */
void UpdateRocketSkin(int entity, int team, bool neutral)
{
	if (neutral) SetEntProp(entity, Prop_Send, "m_nSkin", 2);
	else         SetEntProp(entity, Prop_Send, "m_nSkin", (team == view_as<int>(TFTeam_Blue)) ? 0 : 1);
}

/** Gets a random rocket class based on spawner spawn chances. */
int GetRandomRocketClass(int spawnerClass)
{
	int random = GetURandomIntRange(1, 100);
	ArrayList table = SpawnersChancesTable[spawnerClass];
	int tableSize = table.Length;
	int chancesLower = 0;
	int chancesUpper = 0;

	for (int entry = 0; entry < tableSize; entry++)
	{
		chancesLower = chancesUpper;
		chancesUpper  = chancesLower + table.Get(entry);

		if ((random >= chancesLower) && (random <= chancesUpper))
		{
			return entry;
		}
	}
	return 0;
}

/**
 * Emits a rocket sound (spawn, beep, or alert) based on class settings.
 * Note: Beep timing is managed by SharedRocketThink - this function only plays sounds.
 */
void EmitRocketSound(RocketSound sound, int rocketClass, int entity, int target, RocketFlags flags)
{
	switch (sound)
	{
		case RocketSound_Spawn:
		{
			if (TestFlags(flags, RocketFlag_PlaySpawnSound))
			{
				if (TestFlags(flags, RocketFlag_CustomSpawnSound)) EmitSoundToAll(RocketClassSpawnSound[rocketClass], entity);
				else                                                EmitSoundToAll(SOUND_DEFAULT_SPAWN, entity);
			}
		}
		case RocketSound_Beep:
		{
			// Beep interval timing is handled by SharedRocketThink before calling this function
			if (TestFlags(flags, RocketFlag_PlayBeepSound))
			{
				if (TestFlags(flags, RocketFlag_CustomBeepSound)) EmitSoundToAll(RocketClassBeepSound[rocketClass], entity);
				else                                               EmitSoundToAll(SOUND_DEFAULT_BEEP, entity);
			}
		}
		case RocketSound_Alert:
		{
			if (TestFlags(flags, RocketFlag_PlayAlertSound))
			{
				if (TestFlags(flags, RocketFlag_CustomAlertSound)) EmitSoundToClient(target, RocketClassAlertSound[rocketClass]);
				else                                                EmitSoundToClient(target, SOUND_DEFAULT_ALERT, _, _, _, _, 0.5);
			}
		}
	}
}

/**
 * Checks if a rocket deflection was a steal and applies penalties.
 * Uses guard clauses for clarity and safety.
 */
void CheckStolenRocket(int client, int index)
{
	int target = EntRefToEntIndex(RocketTarget[index]);

	// Guard clauses - each condition is clear and prevents potential crashes
	if (target == -1) return;                                        // Invalid target entity
	if (!IsValidClient(target, true)) return;                        // Target not valid/alive
	if (target == client) return;                                    // Can't steal from yourself  
	if (StealInfo[client].stoleRocket) return;                       // Already processed a steal this round
	if (RocketInstanceState[index] & RocketState_Delayed) return;    // Delayed rockets exempt from steal check
	if (GetEntitiesDistance(target, client) <= CvarStealDistance.FloatValue) return;  // Too close to target
	
	// Team check: if enabled, only count as steal if on same team as target
	if ((RocketInstanceFlags[index] & RocketFlag_StealTeamCheck) && 
	    (GetClientTeam(target) != GetClientTeam(client))) return;

	// All conditions met - this is a steal
	StealInfo[client].stoleRocket = true;

	if (StealInfo[client].rocketsStolen < CvarStealPreventionNumber.IntValue)
	{
		StealInfo[client].rocketsStolen++;
		SlapPlayer(client, 0, true);
		CPrintToChat(client, "%t", "DBSteal_Warning_Client", StealInfo[client].rocketsStolen, CvarStealPreventionNumber.IntValue);

		if (CvarStealMessage.BoolValue)
		{
			CSkipNextClient(client);
			CPrintToChatAll("%t", "DBSteal_Announce_All", client, target);
		}
		StealInfo[client].stoleRocket = false;
	}
	else
	{
		ForcePlayerSuicide(client);
		CPrintToChat(client, "%t", "DBSteal_Slay_Client");
		if (CvarStealMessage.BoolValue)
		{
			CSkipNextClient(client);
			CPrintToChatAll("%t", "DBSteal_Announce_Slay_All", client);
		}
	}

	Internal_SetRocketState(index, (RocketInstanceState[index] | RocketState_Stolen));
	LastStealer = client;
	Forward_OnRocketSteal(index, client, target, StealInfo[client].rocketsStolen);
}

void CheckRoundDelays(int index)
{
	int entity = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	int target = EntRefToEntIndex(RocketTarget[index]);
	float timeToCheck = RocketDeflections[index] == 0 ? LastSpawnTime[index] : RocketLastDeflectionTime[index];
	
	if (target == -1 || (GetGameTime() - timeToCheck) < CvarDelayPreventionTime.FloatValue) return;

	if (!(RocketInstanceState[index] & RocketState_Delayed))
	{
		if (CvarDelayMessage.BoolValue)
		{
			CPrintToChatAll("%t", "DBDelay_Announce_All", target);
		}
		EmitSoundToAll(SOUND_DEFAULT_SPEEDUP, entity, SNDCHAN_AUTO, SNDLEVEL_GUNFIRE);
		Internal_SetRocketState(index, (RocketInstanceState[index] | RocketState_Delayed));
		Forward_OnRocketDelay(index, target);
	}
	else
	{
		RocketSpeed[index] += CvarDelayPreventionSpeedup.FloatValue;
	}
}
