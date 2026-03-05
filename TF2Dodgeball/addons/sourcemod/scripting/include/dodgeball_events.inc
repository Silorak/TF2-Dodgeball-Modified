#if defined _dodgeball_events_included
  #endinput
#endif
#define _dodgeball_events_included

/**
 * Handles all game events hooked by the plugin.
 */

/** Called when a new round starts. Resets steal info and plays round start music. */
public void OnRoundStart(Event event, char[] eventName, bool dontBroadcast)
{
	if (Music[Music_RoundStart])
	{
		EmitSoundToAll(MusicPath[Music_RoundStart]);
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		StealInfo[client].stoleRocket = false;
		StealInfo[client].rocketsStolen = 0;
	}
}

/** Called when setup phase ends. Initializes spawn points and starts the game timer. */
public void OnSetupFinished(Event event, char[] eventName, bool dontBroadcast)
{
	// Guard against being called twice (both teamplay_round_active and arena_round_start hook this)
	if (RoundStarted) return;
	if (!BothTeamsPlaying()) return;

	PopulateSpawnPoints();
	if (LastDeadTeam == 0) LastDeadTeam = GetURandomIntRange(view_as<int>(TFTeam_Red), view_as<int>(TFTeam_Blue));
	if (!IsValidClient(LastDeadClient)) LastDeadClient = 0;
	
	LogicTimer      = CreateTimer(FPS_LOGIC_INTERVAL, OnDodgeBallGameFrame, _, TIMER_REPEAT);
	PlayerCount     = CountAlivePlayers();
	RocketsFired    = 0;
	CurrentRedSpawn = 0;
	CurrentBluSpawn = 0;
	NextSpawnTime   = GetGameTime();
	RoundStarted    = true;
	RoundCount++;
}

/** Called when round ends. Stops timer, music, and destroys all rockets. */
public void OnRoundEnd(Event event, char[] eventName, bool dontBroadcast)
{
	if (LogicTimer != null)
	{
		KillTimer(LogicTimer);
		LogicTimer = null;
	}

	if (MusicEnabled)
	{
		if (UseWebPlayer)
		{
			for (int client = 1; client <= MaxClients; client++)
			{
				if (!IsValidClientEx(client)) continue;
				ShowHiddenMOTDPanel(client, "MusicPlayerStop", "http://0.0.0.0/");
			}
		}
		else if (Music[Music_Gameplay])
		{
			StopSoundToAll(SNDCHAN_MUSIC, MusicPath[Music_Gameplay]);
		}
	}

	DestroyRockets();
	RoundStarted = false;
}

/** Called when player spawns. Forces Pyro class. */
public void OnPlayerSpawn(Event event, char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client)) return;

	TFClassType playerClass = TF2_GetPlayerClass(client);
	if ((playerClass == TFClass_Pyro || playerClass == TFClass_Unknown)) return;

	TF2_SetPlayerClass(client, TFClass_Pyro, false, true);
	TF2_RespawnPlayer(client);
}

/** Called when player dies. Updates game state and executes kill commands. */
public void OnPlayerDeath(Event event, char[] eventName, bool dontBroadcast)
{
	if (!RoundStarted) return;

	SetRandomSeed(view_as<int>(GetGameTime()));

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim = GetClientOfUserId(event.GetInt("userid"));

	if (!IsValidClient(victim)) return;

	// Force FL_NOTARGET on death — prevents spectator ghost airblast bug
	if (UsePushPrevention)
	{
		SetEntityFlags(victim, GetEntityFlags(victim) | FL_NOTARGET);
	}

	StealInfo[victim].stoleRocket = false;
	StealInfo[victim].rocketsStolen = 0;

	LastDeadClient = victim;
	LastDeadTeam = GetClientTeam(victim);
	PlayerCount = CountAlivePlayers();
	
	int inflictor = event.GetInt("inflictor_entindex");
	int index = FindRocketByEntity(inflictor);

	if (index == -1) return;

	int rocketClass = RocketClass[index];
	int target = EntRefToEntIndex(RocketTarget[index]);
	float speed = RocketSpeed[index];
	float mphSpeed = RocketMphSpeed[index];
	int deflections = RocketDeflections[index];

	if ((RocketInstanceFlags[index] & RocketFlag_OnExplodeCmd) && !(RocketInstanceFlags[index] & RocketFlag_Exploded))
	{
		ExecuteCommands(RocketClassCmdsOnExplode[rocketClass], rocketClass, inflictor, attacker, target, LastDeadClient, speed, deflections, mphSpeed);
		RocketInstanceFlags[index] |= RocketFlag_Exploded;
	}

	if (TestFlags(RocketInstanceFlags[index], RocketFlag_OnKillCmd))
	{
		ExecuteCommands(RocketClassCmdsOnKill[rocketClass], rocketClass, inflictor, attacker, target, LastDeadClient, speed, deflections, mphSpeed);
	}
}

/** Called when player receives inventory. Removes non-flamethrower weapons and applies built-in features. */
public void OnPlayerInventory(Event event, char[] eventName, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsValidClient(client)) return;
	for (int slot = 1; slot < 5; slot++)
	{
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (weapon != -1) RemoveEntity(weapon);
	}

	// Push prevention: set FL_NOTARGET to prevent airblast push
	if (UsePushPrevention && PushPreventionEnabled[client])
	{
		SetEntityFlags(client, GetEntityFlags(client) | FL_NOTARGET);
	}

	// NoBlock: remove player-to-player collision
	if (UseNoBlock && GetClientTeam(client) > 1)
	{
		SetEntProp(client, Prop_Data, "m_CollisionGroup", 17); // COLLISION_GROUP_PUSHAWAY
	}
}

/** Blocks primary attack when dodgeball is enabled. */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float velocity[3], float angles[3], int &weapon)
{
	if (Enabled) buttons &= ~IN_ATTACK;
	return Plugin_Continue;
}

/** Handles custom music for round start, win, and lose events. */
public Action OnBroadcastAudio(Event event, char[] eventName, bool dontBroadcast)
{
	if (!MusicEnabled) return Plugin_Continue;

	char sound[PLATFORM_MAX_PATH];
	event.GetString("sound", sound, sizeof(sound));
	int team = event.GetInt("team");

	if (StrEqual(sound, "Announcer.AM_RoundStartRandom"))
	{
		if (!UseWebPlayer)
		{
			if (!Music[Music_Gameplay]) return Plugin_Continue;
			EmitSoundToAll(MusicPath[Music_Gameplay], SOUND_FROM_PLAYER, SNDCHAN_MUSIC);
			return Plugin_Handled;
		}
		else
		{
			for (int client = 1; client <= MaxClients; client++)
			{
				if (!IsValidClientEx(client)) continue;
				ShowHiddenMOTDPanel(client, "MusicPlayerStart", WebPlayerUrl);
			}
			return Plugin_Handled;
		}
	}
	else if (StrEqual(sound, "Game.YourTeamWon"))
	{
		if (!Music[Music_RoundWin]) return Plugin_Continue;

		for (int client = 1; client <= MaxClients; client++)
		{
			if (!(IsValidClientEx(client) && (team == GetClientTeam(client)))) continue;
			EmitSoundToClient(client, MusicPath[Music_RoundWin]);
		}
		return Plugin_Handled;
	}
	else if (StrEqual(sound, "Game.YourTeamLost"))
	{
		if (!Music[Music_RoundLose]) return Plugin_Continue;
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!(IsValidClientEx(client) && (team == GetClientTeam(client)))) continue;
			EmitSoundToClient(client, MusicPath[Music_RoundLose]);
		}
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

/** Called when a projectile is deflected. Updates deflection count and drag state. */
public void OnObjectDeflected(Event event, char[] eventName, bool dontBroadcast)
{
	int entity = event.GetInt("object_entindex");
	int index  = FindRocketByEntity(entity);
	if (index == -1) return;

	RocketEventDeflections[index]++;

	int launcher = GetEntPropEnt(entity, Prop_Send, "m_hLauncher");
	if (launcher != -1)
	{
		SetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher", launcher);
	}

	if (RocketInstanceState[index] & RocketState_Delayed)
	{
		Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_Delayed));
		RocketSpeed[index] = CalculateRocketSpeed(RocketClass[index], CalculateModifier(RocketClass[index], RocketDeflections[index]));
	}

	if (RocketInstanceFlags[index] & RocketFlag_ResetBounces)
	{
		RocketBounces[index] = 0;
	}

	if (RocketInstanceFlags[index] & RocketFlag_IsNeutral)
	{
		SetEntProp(entity, Prop_Send, "m_iTeamNum", 1, 1);
	}

	// Trail fix: the engine creates a new trail particle on every deflect,
	// stacking on top of the previous one. Schedule cleanup for next frame
	// (the engine writes the new trail to m_hEffectEntity during Deflected(),
	// which hasn't finished when this event fires).
	DataPack pack = new DataPack();
	pack.WriteCell(index);
	pack.WriteCell(EntIndexToEntRef(entity));
	RequestFrame(Frame_PostDeflectTrailFix, pack);
}

/**
 * This hook runs every server frame.
 * It's responsible for the smooth "homing" behaviour.
 * "legacy homing" is handled by the logic timer OnDodgeBallGameFrame (~10Hz).
 */
public void OnGameFrame()
{
	if (!Enabled || !RoundStarted) return;

	int index = -1;
	while ((index = FindNextValidRocket(index)) != -1)
	{
		if (RocketClassBehaviour[RocketClass[index]] == Behaviour_Homing)
		{
			HomingRocketThink(index);
		}
	}
}

/**
 * Cleans up client state when they disconnect.
 *
 * @param client   Client index that disconnected.
 */
public void OnClientDisconnect(int client)
{
	StealInfo[client].stoleRocket = false;
	StealInfo[client].rocketsStolen = 0;
	PushPreventionEnabled[client] = false;
	LockedTarget[client] = -1;

	if (client == LastDeadClient)
	{
		LastDeadClient = 0;
	}

	if (client == LastStealer)
	{
		LastStealer = 0;
	}
}

public void OnClientConnected(int client)
{
	PushPreventionEnabled[client] = true; // Default: push prevention on
	LockedTarget[client] = -1;
}

public void OnClientPutInServer(int client)
{
	if (!Enabled) return;

	// Hook WeaponCanUse for the FL_NOTARGET sound fix workaround.
	// FL_NOTARGET suppresses sentry targeting sounds as a side effect;
	// temporarily removing it during weapon pickup avoids the issue.
	if (UsePushPrevention)
	{
		SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
	}
}

/**
 * SDKHook callback for rocket collision detection.
 * Handles initial checks before bouncing and player collision.
 *
 * @param entity   The rocket entity.
 * @param other    The entity being touched.
 * @return         Plugin_Handled to block touch, Plugin_Continue otherwise.
 */
public Action OnStartTouch(int entity, int other)
{
	int index = FindRocketByEntity(entity);

	if (index == -1) return Plugin_Continue;
	if (other > 0 && other <= MaxClients)
	{
		if (RocketDeflections[index] == 0)
		{
			SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", 0);
			SetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher", -1);
			SetEntPropEnt(entity, Prop_Send, "m_hLauncher", -1);
		}
		return Plugin_Continue;
	}

	int rocketClass = RocketClass[index];
	if (RocketBounces[index] >= RocketClassMaxBounces[rocketClass])
	{
		if (RocketDeflections[index] == 0)
		{
			SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", 0);
			SetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher", -1);
			SetEntPropEnt(entity, Prop_Send, "m_hLauncher", -1);
		}
		return Plugin_Continue;
	}

	SDKHook(entity, SDKHook_Touch, OnTouch);
	return Plugin_Handled;
}

public Action OnTouch(int entity, int other)
{
	int index = FindRocketByEntity(entity);

	if (index == -1)
	{
		SDKUnhook(entity, SDKHook_Touch, OnTouch);
		return Plugin_Continue;
	}

	int rocketClass = RocketClass[index];

	float origin[3];
	GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);

	float angles[3];
	GetEntPropVector(entity, Prop_Data, "m_angRotation", angles);
	
	float velocity[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", velocity);

	Handle trace = TR_TraceRayFilterEx(origin, angles, MASK_SHOT, RayType_Infinite, TEF_ExcludeEntity, entity);

	if (!TR_DidHit(trace))
	{
		delete trace;
		return Plugin_Continue;
	}

	float normal[3];
	TR_GetPlaneNormal(trace, normal);
	delete trace;
	
	float dotProduct = GetVectorDotProduct(normal, velocity);
	ScaleVector(normal, dotProduct);
	ScaleVector(normal, 2.0);

	float bounceVec[3];
	SubtractVectors(velocity, normal, bounceVec);
	ScaleVector(bounceVec, RocketClassBounceScale[rocketClass]);

	// Z-clamp: scale vertical component to prevent extreme vertical bounces
	if (UseBounceVerticalScale && RocketClassBounceVerticalScale[rocketClass] < 1.0)
	{
		bounceVec[2] *= RocketClassBounceVerticalScale[rocketClass];
	}

	// Absolute vertical speed cap (like UDL's crawl bounce max up)
	if (UseBounceVerticalScale && RocketClassBounceMaxVerticalSpeed[rocketClass] > 0.0)
	{
		if (bounceVec[2] > RocketClassBounceMaxVerticalSpeed[rocketClass])
		{
			bounceVec[2] = RocketClassBounceMaxVerticalSpeed[rocketClass];
		}
		else if (bounceVec[2] < -RocketClassBounceMaxVerticalSpeed[rocketClass])
		{
			bounceVec[2] = -RocketClassBounceMaxVerticalSpeed[rocketClass];
		}
	}

	float newAngles[3];
	GetVectorAngles(bounceVec, newAngles);

	float newAnglesRef[3]; CopyVectors(newAngles, newAnglesRef);
	float bounceVecRef[3];
	CopyVectors(bounceVec, bounceVecRef);

	Action bounceResult = Forward_OnRocketBouncePre(index, entity, newAnglesRef, bounceVecRef);
	if (bounceResult == Plugin_Stop || bounceResult == Plugin_Handled)
	{
		SDKUnhook(entity, SDKHook_Touch, OnTouch);
		return Plugin_Continue;
	}
	else if (bounceResult == Plugin_Changed)
	{
		CopyVectors(newAnglesRef, newAngles);
		CopyVectors(bounceVecRef, bounceVec);
	}

	// Pause homing — rocket flies freely with bounce velocity until
	// the logic timer re-enables it (bounce pauses use timer, not per-frame drag).
	RocketHomingPaused[index] = true;
	RocketIsDragPause[index] = false;

	TeleportEntity(entity, NULL_VECTOR, newAngles, bounceVec);
	RocketBounces[index]++;
	if (RocketInstanceFlags[index] & RocketFlag_NoBounceDrags)
	{
		Internal_SetRocketState(index, (RocketInstanceState[index] & ~RocketState_CanDrag));
	}

	if ((RocketInstanceState[index] & RocketState_Delayed) || (RocketInstanceFlags[index] & RocketFlag_KeepDirection))
	{
		Internal_SetRocketState(index, (RocketInstanceState[index] | RocketState_Bouncing));
	}
	else
	{
		float direction[3];
		GetAngleVectors(newAngles, direction, NULL_VECTOR, NULL_VECTOR);
		CopyVectors(direction, RocketDirection[index]);
	}

	Forward_OnRocketBounce(index, entity);
	SDKUnhook(entity, SDKHook_Touch, OnTouch);

	return Plugin_Handled;
}

public Action OnTFExplosion(const char[] teName, const int[] clients, int numClients, float delay)
{
	static int ignoreHook;
	if (!Enabled)
	{
		return Plugin_Continue;
	}

	if (ignoreHook)
	{
		ignoreHook = false;
		return Plugin_Continue;
	}

	TE_Start("TFExplosion");

	float vecNormal[3]; TE_ReadVector("m_vecNormal", vecNormal);
	TE_WriteFloat("m_vecOrigin[0]", TE_ReadFloat("m_vecOrigin[0]"));
	TE_WriteFloat("m_vecOrigin[1]", TE_ReadFloat("m_vecOrigin[1]"));
	TE_WriteFloat("m_vecOrigin[2]", TE_ReadFloat("m_vecOrigin[2]"));
	TE_WriteVector("m_vecNormal", vecNormal);
	TE_WriteNum("m_iWeaponID", TE_ReadNum("m_iWeaponID"));
	TE_WriteNum("entindex",    TE_ReadNum("entindex"));
	TE_WriteNum("m_nDefID",    -1);
	TE_WriteNum("m_nSound",    TE_ReadNum("m_nSound"));
	TE_WriteNum("m_iCustomParticleIndex", TE_ReadNum("m_iCustomParticleIndex"));

	ignoreHook = true;
	TE_Send(clients, numClients, delay);
	return Plugin_Stop;

}

// ============================================================================
// Push Prevention (!ab command and WeaponCanUse workaround)
// ============================================================================

/**
 * Console command: toggles airblast push prevention for the calling player.
 */
public Action CmdTogglePushPrevention(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "Command is in-game only.");
		return Plugin_Handled;
	}

	if (!Enabled || !UsePushPrevention || !UsePushPreventionToggle)
	{
		CReplyToCommand(client, "%t", "Command_Disabled");
		return Plugin_Handled;
	}

	PushPreventionEnabled[client] = !PushPreventionEnabled[client];

	if (IsPlayerAlive(client))
	{
		int flags = GetEntityFlags(client);
		SetEntityFlags(client, PushPreventionEnabled[client] ? (flags | FL_NOTARGET) : (flags & ~FL_NOTARGET));
	}

	CReplyToCommand(client, "%t", PushPreventionEnabled[client]
		? "Dodgeball_AirblastPreventionCmd_Enabled"
		: "Dodgeball_AirblastPreventionCmd_Disabled");

	return Plugin_Handled;
}

/**
 * SDKHook callback: temporarily removes FL_NOTARGET during weapon equip
 * to avoid a sound bug where FL_NOTARGET suppresses weapon pickup sounds.
 * Re-applies FL_NOTARGET on the next frame.
 */
public Action OnWeaponCanUse(int client, int weapon)
{
	if (!UsePushPrevention) return Plugin_Continue;

	int flags = GetEntityFlags(client);
	if (!(flags & FL_NOTARGET)) return Plugin_Continue;

	SetEntityFlags(client, flags & ~FL_NOTARGET);
	RequestFrame(Frame_RestorePushPrevention, GetClientUserId(client));

	return Plugin_Continue;
}

void Frame_RestorePushPrevention(int userId)
{
	int client = GetClientOfUserId(userId);
	if (client == 0 || !IsClientInGame(client) || !PushPreventionEnabled[client]) return;

	SetEntityFlags(client, GetEntityFlags(client) | FL_NOTARGET);
}
