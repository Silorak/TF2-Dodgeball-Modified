// tfdb_guardian_abilities.inc — extracted from tfdb_guardian.sp

void ActivateAbility(GuardianAbility ability, int slotIdx)
{
	if (!guardianActive || !IsClientInGame(guardianClient)) return;

	float now = GetGameTime();
	
	if (slotIdx == 1)
	{
		primaryActive = true;
		primaryExpireTime = now + ability.Duration;
		primaryParticleRef = AttachParticle(guardianClient, ability.Particle);
	}
	else
	{
		secondaryActive = true;
		secondaryExpireTime = now + ability.Duration;
		secondaryParticleRef = AttachParticle(guardianClient, ability.Particle);
	}

	EmitSoundToAll(SOUND_ACTIVATE);

	if (StrEqual(ability.Type, "rage", false)) CPrintToChatAll("%t", "Guardian_RageActivated", guardianClient);
	else if (StrEqual(ability.Type, "sprint", false)) CPrintToChatAll("%t", "Guardian_SprintActivated", guardianClient);
	else if (StrEqual(ability.Type, "pounce", false)) CPrintToChatAll("%t", "Guardian_PounceActivated", guardianClient);
	else if (StrEqual(ability.Type, "charge", false)) CPrintToChatAll("%t", "Guardian_ChargeActivated", guardianClient);
	else if (StrEqual(ability.Type, "scare", false) || StrEqual(ability.Type, "slow", false)) CPrintToChatAll("%t", "Guardian_SlowActivated", guardianClient);

	if (StrEqual(ability.Type, "rage", false))
	{
		int weapon = GetPlayerWeaponSlot(guardianClient, 0);
		if (weapon != -1 && IsValidEntity(weapon))
		{
			TF2Attrib_SetByName(weapon, "mult airblast refire time", ability.Arg1 > 0.0 ? ability.Arg1 : 0.5);
			TF2Attrib_SetByName(weapon, "airblast pushback scale", ability.Arg2 > 0.0 ? ability.Arg2 : 1.5);
		}
	}
	else if (StrEqual(ability.Type, "sprint", false) || StrEqual(ability.Type, "charge", false))
	{
		TF2_AddCondition(guardianClient, TFCond_SpeedBuffAlly, ability.Duration);
	}
	else if (StrEqual(ability.Type, "pounce", false))
	{
		float vVel[3], vAng[3];
		GetClientEyeAngles(guardianClient, vAng);
		vAng[0] = 0.0;
		GetAngleVectors(vAng, vVel, NULL_VECTOR, NULL_VECTOR);
		
		float forceFwd = ability.Arg1 > 0.0 ? ability.Arg1 : 1000.0;
		float forceUp  = ability.Arg2 > 0.0 ? ability.Arg2 : 500.0;
		ScaleVector(vVel, forceFwd);
		vVel[2] = forceUp;
		
		TeleportEntity(guardianClient, NULL_VECTOR, NULL_VECTOR, vVel);
	}
	else if (StrEqual(ability.Type, "scare", false) || StrEqual(ability.Type, "slow", false))
	{
		// Start pulsating slow timer
		if (slotIdx == 1)
		{
			delete primarySlowPulseTimer;
			DataPack pack;
			primarySlowPulseTimer = CreateDataTimer(0.2, Timer_SlowPulse, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			if (pack != null)
			{
				pack.WriteCell(activeClassIndex);
				pack.WriteCell(1); 
			}
		}
		else
		{
			delete secondarySlowPulseTimer;
			DataPack pack;
			secondarySlowPulseTimer = CreateDataTimer(0.2, Timer_SlowPulse, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			if (pack != null)
			{
				pack.WriteCell(activeClassIndex);
				pack.WriteCell(2);
			}
		}

		// Initial application
		TriggerSlowPulse(activeClassIndex, (slotIdx == 1 ? true : false));
	}

	DataPack pack;
	if (slotIdx == 1)
	{
		delete primaryTimer; // defensive: prevent handle leak if timer already exists
		primaryTimer = CreateDataTimer(ability.Duration, Timer_PrimaryExpire, pack, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		delete secondaryTimer;
		secondaryTimer = CreateDataTimer(ability.Duration, Timer_SecondaryExpire, pack, TIMER_FLAG_NO_MAPCHANGE);
	}
	if (pack != null) pack.WriteCell(GetClientUserId(guardianClient));
}

void DeactivatePrimary()
{
	if (!primaryActive) return;

	if (primaryTimer != null)
	{
		delete primaryTimer;
		primaryTimer = null;
	}

	primaryActive = false;
	primaryNextUseTime = GetGameTime() + guardianClasses[activeClassIndex].PrimaryAbility.Cooldown;

	RestoreAbilityState(guardianClasses[activeClassIndex].PrimaryAbility);
	DestroyParticle(primaryParticleRef);
	primaryParticleRef = INVALID_ENT_REFERENCE;

	// Stop slow pulse if this was the slow ability
	char type[32];
	strcopy(type, sizeof(type), guardianClasses[activeClassIndex].PrimaryAbility.Type);
	if (StrEqual(type, "slow", false) || StrEqual(type, "scare", false))
	{
		delete primarySlowPulseTimer;
		primarySlowPulseTimer = null;
	}
}

void DeactivateSecondary()
{
	if (!secondaryActive) return;

	if (secondaryTimer != null)
	{
		delete secondaryTimer;
		secondaryTimer = null;
	}

	secondaryActive = false;
	secondaryNextUseTime = GetGameTime() + guardianClasses[activeClassIndex].SecondaryAbility.Cooldown;

	RestoreAbilityState(guardianClasses[activeClassIndex].SecondaryAbility);
	DestroyParticle(secondaryParticleRef);
	secondaryParticleRef = INVALID_ENT_REFERENCE;

	// Stop slow pulse if this was the slow ability
	char type[32];
	strcopy(type, sizeof(type), guardianClasses[activeClassIndex].SecondaryAbility.Type);
	if (StrEqual(type, "slow", false) || StrEqual(type, "scare", false))
	{
		delete secondarySlowPulseTimer;
		secondarySlowPulseTimer = null;
	}
}

void RestoreAbilityState(GuardianAbility ability)
{
	if (!IsClientInGame(guardianClient) || !IsPlayerAlive(guardianClient)) return;

	if (StrEqual(ability.Type, "rage", false))
	{
		int weapon = GetPlayerWeaponSlot(guardianClient, 0);
		if (weapon != -1 && IsValidEntity(weapon))
		{
			TF2Attrib_RemoveByName(weapon, "mult airblast refire time");
			TF2Attrib_RemoveByName(weapon, "airblast pushback scale");
		}
	}
	else if (StrEqual(ability.Type, "sprint", false) || StrEqual(ability.Type, "charge", false))
	{
		TF2_RemoveCondition(guardianClient, TFCond_SpeedBuffAlly);
	}
}

public Action Timer_PrimaryExpire(Handle timer, DataPack pack)
{
	primaryTimer = null;
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	
	DeactivatePrimary();
	if (client && guardianActive && client == guardianClient) EmitSoundToClient(client, SOUND_READY);
	return Plugin_Stop;
}

public Action Timer_SecondaryExpire(Handle timer, DataPack pack)
{
	secondaryTimer = null;
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	
	DeactivateSecondary();
	if (client && guardianActive && client == guardianClient) EmitSoundToClient(client, SOUND_READY);
	return Plugin_Stop;
}

public Action Timer_SlowPulse(Handle timer, DataPack pack)
{
	if (!guardianActive || !IsClientInGame(guardianClient) || !IsPlayerAlive(guardianClient))
	{
		// One of these handles IS the timer currently executing - only null it.
		// Plugin_Stop tells the engine to destroy it. Delete the other one safely.
		if (timer == primarySlowPulseTimer)
		{
			primarySlowPulseTimer = null;
			delete secondarySlowPulseTimer;
		}
		else
		{
			secondarySlowPulseTimer = null;
			delete primarySlowPulseTimer;
		}
		return Plugin_Stop;
	}

	pack.Reset();
	int classIdx = pack.ReadCell();
	int slot     = pack.ReadCell();

	bool isPrimary = (slot == 1);
	
	// Check if still active
	if (isPrimary && (!primaryActive || primarySlowPulseTimer == null)) { primarySlowPulseTimer = null; return Plugin_Stop; }
	if (!isPrimary && (!secondaryActive || secondarySlowPulseTimer == null)) { secondarySlowPulseTimer = null; return Plugin_Stop; }

	TriggerSlowPulse(classIdx, isPrimary);
	
	return Plugin_Continue;
}

void TriggerSlowPulse(int classIdx, bool isPrimary)
{
	float radius = isPrimary ? guardianClasses[classIdx].PrimaryAbility.Arg1 : guardianClasses[classIdx].SecondaryAbility.Arg1;
	float speed  = isPrimary ? guardianClasses[classIdx].PrimaryAbility.Arg2 : guardianClasses[classIdx].SecondaryAbility.Arg2;

	if (radius <= 0.0) radius = 500.0;
	if (speed <= 0.0)  speed = 50.0;
	
	speed /= 100.0; // Converted to percentage (0.5 for 50%)
	
	float origin[3], otherOrigin[3];
	GetClientAbsOrigin(guardianClient, origin);
	origin[2] += 10.0; // Slightly above ground for ring

	// Draw Visual Ring
	int color[4] = {100, 150, 255, 128}; // Transparent Blue
	TE_SetupBeamRingPoint(origin, 10.0, radius, beamModelIndex, haloModelIndex, 0, 15, 0.4, 3.0, 0.0, color, 10, 0); // Reduced duration to 0.4 for higher pulse rate
	TE_SendToAll();

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i) && i != guardianClient && GetClientTeam(i) != GetClientTeam(guardianClient))
		{
			GetClientAbsOrigin(i, otherOrigin);
			if (GetVectorDistance(origin, otherOrigin) <= radius)
			{
				// Apply very short stun that refreshes next pulse
				TF2_StunPlayer(i, 0.3, speed, TF_STUNFLAG_SLOWDOWN, guardianClient);
			}
		}
	}
}

int AttachParticle(int client, const char[] particleName)
{
	if (particleName[0] == '\0') return INVALID_ENT_REFERENCE;

	int particle = CreateEntityByName("info_particle_system");

	if (!IsValidEntity(particle)) return INVALID_ENT_REFERENCE;

	float pos[3];
	GetClientAbsOrigin(client, pos);

	char tName[64];
	GetEntPropString(client, Prop_Data, "m_iName", tName, sizeof(tName));

	if (tName[0] == '\0')
	{
		Format(tName, sizeof(tName), "target%i", client);
		DispatchKeyValue(client, "targetname", tName);
	}

	DispatchKeyValue(particle, "effect_name", particleName);
	DispatchKeyValueVector(particle, "origin", pos);
	DispatchKeyValue(particle, "cpoint1", tName); // Assign Control Point 1 to the player targetname

	DispatchSpawn(particle);
	ActivateEntity(particle);
	AcceptEntityInput(particle, "Start");

	SetVariantString(tName);
	AcceptEntityInput(particle, "SetParent", client, particle, 0);

	// Attachment logic refinement:
	// If it's an unusual taunt (utaunt_), we attach to "flag" (head/back area) 
	// UNLESS it's hands, which look better at feet/origin.
	if (StrContains(particleName, "utaunt_", false) != -1)
	{
		if (StrContains(particleName, "hands", false) == -1) // Not hands? Move to flag!
		{
			SetVariantString("flag");
			AcceptEntityInput(particle, "SetParentAttachment", client, particle, 0);
		}
	}
	else
	{
		// Generic particles also go to flag
		SetVariantString("flag");
		AcceptEntityInput(particle, "SetParentAttachment", client, particle, 0); // Fixed parent argument
	}

	return EntIndexToEntRef(particle);
}

void DestroyParticle(int ref)
{
	if (ref == INVALID_ENT_REFERENCE) return;

	int entity = EntRefToEntIndex(ref);

	if (entity != -1 && IsValidEntity(entity))
	{
		AcceptEntityInput(entity, "Stop");
		AcceptEntityInput(entity, "Kill");
	}
}
