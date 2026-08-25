#if defined _dodgeball_rockets_included
  #endinput
#endif
#define _dodgeball_rockets_included

/**
 * All logic directly related to creating, managing, and controlling rockets.
 */

#define ROCKET_SLOT_NONE (-1)

void ClearRocketEntityMapping(int index)
{
	int entity = EntRefToEntIndex(RocketEntity[index]);
	if (entity <= 0 || entity >= sizeof(g_EntityIndexToRocketSlot)) return;
	if (g_EntityIndexToRocketSlot[entity] != index) return;
	g_EntityIndexToRocketSlot[entity] = ROCKET_SLOT_NONE;
}

void ClearRocketSlotMappings(int index)
{
	for (int entity = 0; entity < sizeof(g_EntityIndexToRocketSlot); entity++)
	{
		if (g_EntityIndexToRocketSlot[entity] == index) g_EntityIndexToRocketSlot[entity] = ROCKET_SLOT_NONE;
	}
}

bool RebindRocketEntity(int index, int entity)
{
	if (entity <= 0 || entity >= sizeof(g_EntityIndexToRocketSlot)) return false;
	int mappedSlot = g_EntityIndexToRocketSlot[entity];
	if (mappedSlot != ROCKET_SLOT_NONE && mappedSlot != index)
	{
		bool sameEntity = mappedSlot >= 0 && mappedSlot < MAX_ROCKETS
			&& IsValidRocket(mappedSlot)
			&& EntRefToEntIndex(RocketEntity[mappedSlot]) == entity;
		if (sameEntity) return false;
		g_EntityIndexToRocketSlot[entity] = ROCKET_SLOT_NONE;
	}

	ClearRocketEntityMapping(index);
	RocketEntity[index] = EntIndexToEntRef(entity);
	g_EntityIndexToRocketSlot[entity] = index;
	return true;
}

/** Attaches every callback required for a tracked rocket; SDKHooks owns cleanup. */
bool AttachRocketHooks(int entity)
{
	bool touchHooked = SDKHookEx(entity, SDKHook_StartTouch, OnStartTouch);
	bool damageHooked = SDKHookEx(entity, SDKHook_OnTakeDamage, OnRocketTakeDamage);
	return touchHooked && damageHooked;
}

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
	if (rocketClass < 0 || rocketClass >= RocketClassCount)
	{
		LogError("Cannot create rocket: class index %d out of range [0..%d).", rocketClass, RocketClassCount);
		return;
	}
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
	if (rocketClass < 0 || rocketClass >= RocketClassCount)
	{
		LogError("TFDB_OnRocketCreatedPre returned invalid class index %d.", rocketClass);
		return;
	}

	int entity = CreateEntityByName(TestFlags(flags, RocketFlag_IsAnimated) ? "tf_projectile_sentryrocket" : "tf_projectile_rocket");
	if (entity == -1) return;

	float position[3], angles[3], direction[3];
	GetEntPropVector(spawnerEntity, Prop_Send, "m_vecOrigin", position);
	GetEntPropVector(spawnerEntity, Prop_Send, "m_angRotation", angles);
	GetAngleVectors(angles, direction, NULL_VECTOR, NULL_VECTOR);

	// Determine crit status. m_bCritical is NEVER set to 1 (not even server-only)
	// because Source Engine's edict-level dirty tracking can leak it to clients,
	// triggering CreateTrails() and spawning client-side crit particles that the
	// server cannot remove. Instead, crit damage (3x) is applied directly to the
	// damage value via CalculateRocketDamage.
	bool isCrit = (GetURandomFloatRange(0.0, 100.0) <= RocketClassCritChance[rocketClass]);
	SetEntProp(entity,    Prop_Send, "m_bCritical",    0, 1);
	SetEntProp(entity,    Prop_Send, "m_iTeamNum",     (TestFlags(flags, RocketFlag_IsNeutral)) ? 1 : team, 1);
	SetEntProp(entity,    Prop_Send, "m_iDeflected",   0);
	TeleportEntity(entity, position, angles, view_as<float>({0.0, 0.0, 0.0}));

	int targetTeam = (TestFlags(flags, RocketFlag_IsNeutral)) ? 0 : GetAnalogueTeam(team);
	int target     = SelectTarget(targetTeam);

	// Abort spawn cleanly when no valid target exists (empty team, round transition, etc.).
	// Per SelectTarget contract: -1 is legitimate, callers must validate before
	// any client native. See concepts/select-target-contract.md in the wiki.
	if (target <= 0 || target > MaxClients || !IsClientInGame(target))
	{
		AcceptEntityInput(entity, "Kill");
		return;
	}

	int owner = SelectTarget(GetAnalogueTeam(GetClientTeam(target)));
	if (owner <= 0 || owner > MaxClients || !IsClientInGame(owner))
	{
		AcceptEntityInput(entity, "Kill");
		return;
	}

	SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", owner);
	int weapon = GetPlayerWeaponSlot(owner, TFWeaponSlot_Primary);
	SetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher", weapon == -1 ? entity : weapon);
	SetEntPropEnt(entity, Prop_Send, "m_hLauncher", weapon == -1 ? entity : weapon);

	float modifier = CalculateModifier(rocketClass, 0);
	if (!RebindRocketEntity(index, entity))
	{
		LogError("Cannot create rocket: entity %d is already bound to an active slot.", entity);
		AcceptEntityInput(entity, "Kill");
		return;
	}
	RocketIsValid[index]            = true;
	RocketInstanceFlags[index]      = flags;
	RocketTarget[index]             = EntIndexToEntRef(target);
	RocketClass[index]              = rocketClass;
	RocketDeflections[index]        = 0;
	RocketEventDeflections[index]   = 0;
	RocketBounces[index]            = 0;
	RocketHomingPaused[index]     = false;
	RocketDragEventBoundary[index]   = 0.0;
	RocketBounceEventBoundary[index] = 0.0;
	RocketNextHomingThink[index]  = 0.0;
	RocketLastLogicThink[index]   = 0.0;
	for (int i = 0; i < MAX_CRIT_STACK; i++) RocketCritGlow[index][i] = INVALID_ENT_REFERENCE;
	RocketCritGlowTeam[index]       = 0;
	RocketIsCritical[index]         = isCrit;
	RocketLastDeflectionTime[index] = GetGameTime();
	RocketLastBeepTime[index]       = GetGameTime();
	float spawnSpeed = CalculateRocketSpeed(rocketClass, modifier);
	RocketRawMphSpeed[index]        = spawnSpeed * HAMMER_TO_MPH;
	RocketSpeed[index]              = LimitRocketSpeed(rocketClass, flags, spawnSpeed);
	RocketMphSpeed[index]           = RocketSpeed[index] * HAMMER_TO_MPH;
	// Slot reuse is initialization, not a gameplay state transition.
	RocketInstanceState[index]      = RocketState_None;

	CopyVectors(direction, RocketDirection[index]);
	float baseDamage = CalculateRocketDamage(rocketClass, modifier);
	SetEntDataFloat(entity, DamageOffset, isCrit ? baseDamage * 3.0 : baseDamage, true);
	DispatchSpawn(entity);

	// Publish no commands, sounds, counters, or schedule changes until every
	// required hook is attached. RocketCount is incremented first so
	// DestroyRocket can roll internal ownership back on attachment failure.
	RocketCount++;
	if (!AttachRocketHooks(entity))
	{
		LogError("Cannot manage rocket entity %d: SDKHookEx attachment failed.", entity);
		DestroyRocket(index);
		return;
	}

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

	RocketsFired++;
	LastSpawnTime[index] = GetGameTime();
	NextSpawnTime = GetGameTime() + SpawnersInterval[spawnerClass];
	// Note: OnRocketThink is driven by OnGameFrame iteration (see events.inc),
	// NOT by SDKHook_Think. tf_projectile_rocket's engine-side Think schedule is
	// sparse (~10Hz lifetime checks), so SDKHook_Think cannot drive per-tick homing.

	// Create the initial crit glow particle only if the rocket rolled crit.
	// Non-crit rockets look like normal TF2 rockets (smoke trail only, no glow).
	if (isCrit)
	{
		UpdateCritGlow(index, entity, team);
	}

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

	// Clean up server-managed crit glow particle stack
	for (int i = 0; i < MAX_CRIT_STACK; i++)
	{
		if (RocketCritGlow[index][i] == INVALID_ENT_REFERENCE) continue;
		int glow = EntRefToEntIndex(RocketCritGlow[index][i]);
		if (glow != -1 && IsValidEntity(glow)) RemoveEntity(glow);
		RocketCritGlow[index][i] = INVALID_ENT_REFERENCE;
	}
	RocketCritGlowTeam[index] = 0;

	int entity = EntRefToEntIndex(RocketEntity[index]);
	ClearRocketEntityMapping(index);

	if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
	{
		RemoveEntity(entity);
	}
	RocketIsValid[index] = false;
	RocketInstanceState[index] = RocketState_None;
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

/**
 * Creates or replaces the server-managed crit glow particle stack on a rocket.
 * Uses proper SetParent attachment for smooth following without position sync.
 * The stack count is per-class via cfg key "crit glow stack" (1 = default).
 *
 * @param index    The rocket's internal index.
 * @param entity   The rocket entity index.
 * @param team     The team number for the glow color.
 */
void UpdateCritGlow(int index, int entity, int team)
{
	int rocketClass = RocketClass[index];
	int stack = RocketClassCritGlowStack[rocketClass];
	if (stack < 1)              stack = 1;
	if (stack > MAX_CRIT_STACK) stack = MAX_CRIT_STACK;

	// Same-team skip: if the current stack is already the correct team color
	// and the first entry is still alive, assume the rest are too — don't
	// destroy and recreate.
	if (RocketCritGlow[index][0] != INVALID_ENT_REFERENCE && RocketCritGlowTeam[index] == team)
	{
		int existingGlow = EntRefToEntIndex(RocketCritGlow[index][0]);
		if (existingGlow != -1 && IsValidEntity(existingGlow))
		{
			return;
		}
	}

	// Resolve particle name: per-class override (cfg "crit glow particle <team>")
	// wins; empty/unset falls back to the engine defaults.
	char particleName[32];
	if (team == view_as<int>(TFTeam_Blue))
	{
		if (RocketClassCritGlowParticleBlue[rocketClass][0] != '\0')
			strcopy(particleName, sizeof(particleName), RocketClassCritGlowParticleBlue[rocketClass]);
		else
			particleName = "critical_rocket_blue";
	}
	else if (team == view_as<int>(TFTeam_Red))
	{
		if (RocketClassCritGlowParticleRed[rocketClass][0] != '\0')
			strcopy(particleName, sizeof(particleName), RocketClassCritGlowParticleRed[rocketClass]);
		else
			particleName = "critical_rocket_red";
	}
	else
	{
		if (RocketClassCritGlowParticleNeutral[rocketClass][0] != '\0')
			strcopy(particleName, sizeof(particleName), RocketClassCritGlowParticleNeutral[rocketClass]);
		else
			particleName = "eyeboss_projectile";
	}

	// Clean up old stack first so we don't leak any lingering entries.
	for (int i = 0; i < MAX_CRIT_STACK; i++)
	{
		if (RocketCritGlow[index][i] == INVALID_ENT_REFERENCE) continue;
		int oldGlow = EntRefToEntIndex(RocketCritGlow[index][i]);
		if (oldGlow != -1 && IsValidEntity(oldGlow))
		{
			AcceptEntityInput(oldGlow, "Stop");
			RemoveEntity(oldGlow);
		}
		RocketCritGlow[index][i] = INVALID_ENT_REFERENCE;
	}

	// Spawn N parented particles at the rocket's "trail" attachment (or origin
	// fallback). All emit from the same spot → denser/brighter glow.
	for (int i = 0; i < stack; i++)
	{
		int newGlow = SpawnParticleSystem(particleName, NULL_VECTOR, NULL_VECTOR, entity, "trail", 0.0, 0.0);
		if (newGlow == -1) continue;
		RocketCritGlow[index][i] = EntIndexToEntRef(newGlow);
	}

	RocketCritGlowTeam[index] = team;
}



/**
 * Checks if a rocket index is valid and the rocket exists.
 *
 * @param index    The rocket's internal index.
 * @return         True if valid, false otherwise.
 */
bool IsValidRocket(int index)
{
	if (index < 0 || index >= MAX_ROCKETS || !RocketIsValid[index]) return false;
	
	if (EntRefToEntIndex(RocketEntity[index]) != -1) return true;

	// Rocket entity was destroyed by the engine (shot down, exploded, etc.)
	// without going through DestroyRocket. Clean up the server-managed crit
	// glow particle stack so they don't linger at the rocket's last position.
	for (int i = 0; i < MAX_CRIT_STACK; i++)
	{
		if (RocketCritGlow[index][i] == INVALID_ENT_REFERENCE) continue;
		int glow = EntRefToEntIndex(RocketCritGlow[index][i]);
		if (glow != -1 && IsValidEntity(glow))
		{
			AcceptEntityInput(glow, "Stop");
			RemoveEntity(glow);
		}
		RocketCritGlow[index][i] = INVALID_ENT_REFERENCE;
	}
	RocketCritGlowTeam[index] = 0;

	ClearRocketSlotMappings(index);
	RocketIsValid[index] = false;
	RocketInstanceState[index] = RocketState_None;
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
	if (entity <= 0 || entity >= sizeof(g_EntityIndexToRocketSlot)) return -1;
	int slot = g_EntityIndexToRocketSlot[entity];
	if (slot < 0 || slot >= MAX_ROCKETS) return -1;

	// Sanity check: entity recycling can leave stale entries (engine destroys
	// the rocket, slot index gets reused for another entity). Verify the slot
	// still points back to this entity before trusting the mapping.
	if (EntRefToEntIndex(RocketEntity[slot]) != entity)
	{
		g_EntityIndexToRocketSlot[entity] = ROCKET_SLOT_NONE;
		return -1;
	}
	return slot;
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
 * @return                 False if no valid target exists or the pre-forward blocks it.
 */
bool ProcessDeflection(int index, int entity, int rocketClass, RocketFlags flags,
                       int team, int targetTeam, int deflectionCount, float modifier)
{
	int client = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	bool validClient = (client >= 1 && client <= MaxClients && IsClientInGame(client));
	int target = -1;

	// ---- Target must be scored against the NEW aim, not the old heading ----
	//
	// SelectTarget scores candidates with
	//     GetVectorDotProduct(RocketDirection[index], directionToClient)
	// i.e. it answers "who is this rocket pointed at?", so it can only answer
	// correctly using the direction the deflector just aimed. Scoring against
	// the PRE-deflect heading favoured players off to the sides -- deflect
	// straight at someone and the rocket picked their neighbour. v1.9.6 does
	// direction first, then target, and says so in its own comments.
	//
	// It cannot simply be reordered: Forward_OnRocketDeflectPre may VETO the
	// deflection, and nothing may be mutated before it gets that chance
	// (test_deflection_contracts). So compute the direction into a LOCAL,
	// score against it via SelectTarget's override, and commit after approval.
	float newDirection[3];
	bool haveNewDirection = false;
	if (validClient)
	{
		float viewAngles[3];
		GetClientEyeAngles(client, viewAngles);
		GetAngleVectors(viewAngles, newDirection, NULL_VECTOR, NULL_VECTOR);
		haveNewDirection = true;
	}

	// Target lock: if enabled, reuse the previous target for this deflector.
	if (validClient && UseTargetLock && (!UseTargetLockBotOnly || IsFakeClient(client)))
	{
		int prevTarget = EntRefToEntIndex(LockedTarget[client]);
		if (IsValidClient(prevTarget, true)
			&& (TestFlags(flags, RocketFlag_IsNeutral) || GetClientTeam(client) != GetClientTeam(prevTarget)))
		{
			target = prevTarget;
		}
	}

	if (target == -1) target = SelectTarget(targetTeam, index, haveNewDirection, newDirection);
	if (!IsValidClient(target, true))
	{
		RocketDeflections[index] = deflectionCount;
		return false;
	}

	int targetRef = target;
	Action deflectResult = Forward_OnRocketDeflectPre(index, entity, client, targetRef);
	if (deflectResult == Plugin_Stop || deflectResult == Plugin_Handled)
	{
		RocketDeflections[index] = deflectionCount;
		return false;
	}
	if (deflectResult == Plugin_Changed) target = targetRef;
	if (!IsValidClient(target, true))
	{
		RocketDeflections[index] = deflectionCount;
		return false;
	}

	Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_Stolen));
	if (validClient)
	{
		if (haveNewDirection) CopyVectors(newDirection, RocketDirection[index]);
		UpdateRocketSkin(entity, team, TestFlags(flags, RocketFlag_IsNeutral));
		if (RocketIsCritical[index]) UpdateCritGlow(index, entity, team);
		if (!(flags & RocketFlag_CanBeStolen)) CheckStolenRocket(client, index);
		LockedTarget[client] = EntIndexToEntRef(target);
	}

	RocketTarget[index]             = EntIndexToEntRef(target);
	RocketDeflections[index]        = deflectionCount;
	RocketLastDeflectionTime[index] = GetGameTime();
	float rawSpeed = CalculateRocketSpeed(rocketClass, modifier);
	RocketRawMphSpeed[index]        = rawSpeed * HAMMER_TO_MPH;
	RocketSpeed[index]              = LimitRocketSpeed(rocketClass, flags, rawSpeed);
	float baseDamage = CalculateRocketDamage(rocketClass, modifier);
	SetEntDataFloat(entity, DamageOffset, RocketIsCritical[index] ? baseDamage * 3.0 : baseDamage, true);

	if (TestFlags(flags, RocketFlag_ElevateOnDeflect)) RocketInstanceFlags[index] |= RocketFlag_Elevating;
	RocketMphSpeed[index] = RocketSpeed[index] * HAMMER_TO_MPH;

	if (g_CacheStealPreventionDamage && (RocketInstanceState[index] & RocketState_Stolen))
	{
		SetEntDataFloat(entity, DamageOffset, 0.0, true);
	}
	if (flags & RocketFlag_TeamlessHits) SetEntProp(entity, Prop_Send, "m_iTeamNum", 1, 1);

	EmitRocketSound(RocketSound_Alert, rocketClass, entity, target, flags);
	if (TestFlags(flags, RocketFlag_OnDeflectCmd))
	{
		ExecuteCommands(RocketClassCmdsOnDeflect[rocketClass], rocketClass, entity, client, target, LastDeadClient, RocketSpeed[index], deflectionCount, RocketMphSpeed[index]);
	}
	Forward_OnRocketDeflect(index, entity, client);
	return true;
}

/**
 * Shared no-target handler. Extracted from HomingRocketThink and
 * RocketLegacyThink where the logic was duplicated verbatim.
 *
 * Selects a new target, fires commands/sounds/forwards, and optionally
 * zeroes damage. Returns the new target index, or -1 if no valid target
 * was found (caller must return immediately).
 */
int HandleNoTarget(int index, int entity, int owner, int targetTeam,
                   int rocketClass, RocketFlags flags, int deflectionCount)
{
	int target = SelectTarget(targetTeam, index);
	if (!IsValidClient(target, true)) return -1;

	RocketTarget[index] = EntIndexToEntRef(target);
	EmitRocketSound(RocketSound_Alert, rocketClass, entity, target, flags);

	if (TestFlags(flags, RocketFlag_OnNoTargetCmd))
	{
		ExecuteCommands(RocketClassCmdsOnNoTarget[rocketClass], rocketClass, entity, owner, target, LastDeadClient, RocketSpeed[index], deflectionCount, RocketMphSpeed[index]);
	}

	if (g_CacheNoTargetRedirectDamage)
	{
		SetEntDataFloat(entity, DamageOffset, 0.0, true);
	}

	Forward_OnRocketNoTarget(index, target, owner);
	return target;
}

/**
 * Applies the homing lerp: gradually turns the rocket's direction toward
 * the target. Extracted from HomingRocketThink to flatten nesting.
 * Guard-clauses on control delay; applies tick-scaled turn rate.
 */
void ApplyHomingLerp(int index, int entity, int rocketClass, int target,
                     float modifier, float now, bool gatedThink,
                     float thinkInterval, float tickScaleConst)
{
	if ((now - RocketLastDeflectionTime[index]) < RocketClassControlDelay[rocketClass]) return;

	// tickScale: 1.0 for gated think (Damizean raw-lerp), else GetTickInterval()/TICK_BASE_INTERVAL.
	float tickScale = gatedThink ? 1.0 : tickScaleConst;
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

	if (gatedThink)
	{
		RocketNextHomingThink[index] = now + thinkInterval;
	}
}

/**
 * Applies smooth elevation (frame-rate independent). Extracted from
 * HomingRocketThink to flatten nesting. Guard-clauses on all conditions.
 */
void ApplySmoothElevation(int index, int rocketClass, float now, float tickScaleConst)
{
	if (!UseSmoothElevation) return;
	if (!(RocketInstanceFlags[index] & RocketFlag_Elevating)) return;
	if ((now - RocketLastDeflectionTime[index]) < RocketClassControlDelay[rocketClass]) return;

	float elevRate = RocketClassElevationRate[rocketClass] * tickScaleConst;
	if (RocketDirection[index][2] < RocketClassElevationLimit[rocketClass])
	{
		RocketDirection[index][2] = FMin(RocketDirection[index][2] + elevRate, RocketClassElevationLimit[rocketClass]);
	}
	else
	{
		RocketInstanceFlags[index] &= ~RocketFlag_Elevating;
	}
}

/**
 * Main think function for homing rockets. Handles tracking, dragging,
 * deflection, target switching, and all per-frame rocket behaviour.
 * Called from OnGameFrame per-rocket per-tick (dispatched via OnRocketThink).
 *
 * @param index    The rocket's internal index.
 */
void HomingRocketThink(int index)
{
	int entity           = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	// Game time changes each frame; tick scale is stable for the server session.
	float now = GetGameTime();
	float tickScaleConst = TickScaleConst;

	int rocketClass      = RocketClass[index];
	RocketFlags flags    = RocketInstanceFlags[index];
	int target           = EntRefToEntIndex(RocketTarget[index]);
	int team             = GetEntProp(entity, Prop_Send, "m_iTeamNum", 1);
	int targetTeam       = (TestFlags(flags, RocketFlag_IsNeutral)) ? 0 : GetAnalogueTeam(team);
	int deflectionCount  = RocketEventDeflections[index];
	bool deflectionPending = (deflectionCount > RocketDeflections[index]);
	float modifier       = CalculateModifier(rocketClass, deflectionCount);

	// --- Bounce unpause: clear the pause once the shared legacy grid catches up ---
	// OnTouch set RocketHomingPaused=true and stamped RocketBounceEventBoundary (the
	// next boundary of the shared grid after the bounce — see NextLegacyGridTick). We let
	// the rocket fly its bounce direction blindly until then, then resume homing.
	// Reproduces the original timer-driven build's 0-100ms variable post-bounce
	// window (same grid boundaries for every rocket) instead of a fixed delay.
	if (RocketHomingPaused[index])
	{
		if (now >= RocketBounceEventBoundary[index])
		{
			// End both pause representations on the same shared-grid frame. v1.9.6's
			// global RocketOtherThink cleared RocketState_Bouncing before that frame's
			// OnGameFrame homing pass. Leaving it for the unrelated per-rocket shared
			// gate suppresses velocity commits for up to another ~100ms, producing a
			// long stale/downward segment that legacy never had.
			//
			// Do not pre-apply RocketDirection here. Normal homing below will apply its
			// freshly lerped direction when no deflection is pending. If a just-
			// airblasted rocket is still waiting for its delayed eye read, the drag
			// block returns without a write and preserves the physical bounce until
			// ProcessDeflection installs the new player direction.
			RocketHomingPaused[index] = false;
			RocketBounceEventBoundary[index] = 0.0;
			Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_Bouncing));
		}
		// If a deflection came in during the bounce pause, the drag block below still
		// runs on top. When ready it wins over the physical bounce direction.
	}

	// --- Emergent drag: process the deflection at its recorded deadline ---
	// Normally this is deflection time + the fixed DragDelay. It is the next
	// shared-grid boundary only in the explicit legacy mode (DragDelay == 0).
	// ProcessDeflection samples eye angles once; this is a reproducible flick
	// window, not continuous crosshair steering.
	if (deflectionPending)
	{
		if (now >= RocketDragEventBoundary[index])
		{
			if (!ProcessDeflection(index, entity, rocketClass, flags, team, targetTeam, deflectionCount, modifier))
			{
				return;
			}

			// ProcessDeflection may select a different target. Refresh the local so
			// this same frame cannot bend the freshly sampled drag direction toward
			// the stale pre-deflect target when control delay is zero.
			target = EntRefToEntIndex(RocketTarget[index]);
			ApplyRocketParameters(index);
		}
		else
		{
			// Still waiting for the drag window to elapse. Do not run homing yet.
			return;
		}
	}

	// --- Normal homing (only when not paused) ---
	if (RocketHomingPaused[index]) return;

	float thinkInterval = RocketClassThinkInterval[rocketClass];
	bool gatedThink = (thinkInterval > 0.0);
	bool homingLerpEligible = !gatedThink || (now >= RocketNextHomingThink[index]);

	// No-target handling or homing lerp
	if (!IsValidClient(target, true))
	{
		int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
		target = HandleNoTarget(index, entity, owner, targetTeam, rocketClass, flags, deflectionCount);
		if (target == -1) return;
	}
	else if (homingLerpEligible)
	{
		ApplyHomingLerp(index, entity, rocketClass, target, modifier, now, gatedThink, thinkInterval, tickScaleConst);
	}

	// --- Smooth elevation (OnGameFrame, frame-rate independent) ---
	ApplySmoothElevation(index, rocketClass, now, tickScaleConst);

	if (!(RocketInstanceState[index] & RocketState_Bouncing))
	{
		ApplyRocketParameters(index);
	}
}

/**
 * Handles logic that is shared between all rocket behaviours (sounds, delay checks,
 * elevation step, no-target handling). Called from OnRocketThink (in events.inc)
 * under a ~10 Hz gate via RocketLastLogicThink.
 */
void SharedRocketThink(int index)
{
	int entity           = EntRefToEntIndex(RocketEntity[index]);
	if (entity == -1) return;

	int rocketClass      = RocketClass[index];
	RocketFlags flags    = RocketInstanceFlags[index];
	int target           = EntRefToEntIndex(RocketTarget[index]);
	int deflectionCount  = RocketEventDeflections[index];

	// Modern bounce unpause/state clearing and drag processing happen per-frame
	// in HomingRocketThink. Bounce uses the shared legacy grid; drag uses its
	// fixed deadline unless legacy drag mode is selected. The compatibility
	// Behaviour_LegacyHoming path still clears its state after its coarse think.

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

		if (g_CacheDelayPrevention)
		{
			CheckRoundDelays(index);
		}
	}

	if (RocketClassBehaviour[rocketClass] == Behaviour_LegacyHoming)
	{
		Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_Bouncing));
	}
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
		int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
		target = HandleNoTarget(index, entity, owner, targetTeam, rocketClass, flags, deflectionCount);
		if (target == -1) return;
	}
	else if (deflectionCount > RocketDeflections[index])
	{
		if (!ProcessDeflection(index, entity, rocketClass, flags, team, targetTeam, deflectionCount, modifier))
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

/** Applies engine-wide and optional stricter per-class speed caps before entity writes. */
float LimitRocketSpeed(int rocketClass, RocketFlags flags, float speed)
{
	float capped = speed;
	if (EngineMaxVelocity > 0.0) capped = FMin(capped, EngineMaxVelocity);
	if (TestFlags(flags, RocketFlag_IsSpeedLimited) && RocketClassSpeedLimit[rocketClass] > 0.0)
	{
		capped = FMin(capped, RocketClassSpeedLimit[rocketClass]);
	}
	return capped;
}

/** Calculates turn rate based on class settings and modifier. */
float CalculateRocketTurnRate(int rocketClass, float modifier)
{
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
	ArrayList table = SpawnersChancesTable[spawnerClass];
	int tableSize = table.Length;

	if (tableSize == 0) return 0;

	// Sum actual weights — don't assume they total 100.
	// This lets configs use any relative weights: "common%" "9", "nuke%" "1"
	// works the same as "common%" "90", "nuke%" "10".
	int totalWeight = 0;
	for (int entry = 0; entry < tableSize; entry++)
	{
		totalWeight += table.Get(entry);
	}

	if (totalWeight <= 0) return 0;

	// Pick a random value in [0, totalWeight - 1].
	// Using GetRandomInt — SM's built-in that handles range correctly
	// without the modulo bias of GetURandomInt() % N.
	int random = GetRandomInt(0, totalWeight - 1);

	// Walk the cumulative weight ranges. Each class owns an exclusive
	// slice: [cumulative, cumulative + weight). The strict < on the
	// upper bound means no boundary overlap between adjacent classes.
	int cumulative = 0;
	for (int entry = 0; entry < tableSize; entry++)
	{
		cumulative += table.Get(entry);
		if (random < cumulative)
		{
			return entry;
		}
	}

	// Should never reach here if weights are valid, but guard against
	// floating point or config edge cases — return last valid class.
	return tableSize - 1;
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
	
	if (target == -1 || (GetGameTime() - timeToCheck) < g_CacheDelayPreventionTime) return;

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
		int rocketClass = RocketClass[index];
		RocketSpeed[index] = LimitRocketSpeed(rocketClass, RocketInstanceFlags[index],
			RocketSpeed[index] + CvarDelayPreventionSpeedup.FloatValue);
		RocketMphSpeed[index] = RocketSpeed[index] * HAMMER_TO_MPH;
	}
}

/** Adds the crit damage flag when the tracked rocket entity is damaged. */
public Action OnRocketTakeDamage(int victim, int &attacker, int &inflictor, 
                                  float &damage, int &damagetype, int &weapon, 
                                  float damageForce[3], float damagePosition[3])
{
	int index = FindRocketByEntity(victim);
	if (index == -1) return Plugin_Continue;

	if (RocketIsCritical[index])
	{
		damagetype |= DMG_CRIT;
	}

	return Plugin_Continue;
}
