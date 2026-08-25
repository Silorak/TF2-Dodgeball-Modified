// tfdb_guardian_hud.inc — extracted from tfdb_guardian.sp

void Frame_ApplyGuardianHealth(int userId)
{
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client)) return;
	if (!guardianActive || client != guardianClient) return;

	// Read what the engine set HP to before we override it
	int engineHP  = GetClientHealth(client);
	int engineMax = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (debugMode)
	{
		GuardianDebugLog("[GUARDIAN DBG] " ... "Frame_ApplyGuardianHealth - BEFORE apply: engineHP=%d engineMax=%d", engineHP, engineMax);
	}

	ApplyGuardianHealth();
}

void ApplyGuardianHealth()
{
	if (!guardianActive || !IsClientInGame(guardianClient) || !IsPlayerAlive(guardianClient)) return;

	int client = guardianClient;
	int baseHP = guardianMaxHP;

	if (debugMode)
	{
		GuardianDebugLog("[GUARDIAN DBG] " ... "ApplyGuardianHealth - client=%d maxHP=%d currentHP=%d", client, baseHP, guardianCurrentHP);
	}

	// TF2 recomputes max health from class base + attributes every frame.
	// m_iMaxHealth via Prop_Data does not stick. The correct approach (same as VSH/FF2)
	// is to use the "max health additive bonus" player attribute. Remove then re-add it
	// so stale values from a previous spawn never accumulate.
	TF2Attrib_RemoveByName(client, "max health additive bonus");

	// The attribute value is additive on top of the Pyro base (175 HP).
	// We want the final max to equal guardianMaxHP, so: bonus = guardianMaxHP - 175.
	int bonus = baseHP - 175;
	if (bonus > 0)
		TF2Attrib_SetByName(client, "max health additive bonus", float(bonus));

	if (debugMode)
	{
		GuardianDebugLog("[GUARDIAN DBG] " ... "ApplyGuardianHealth - attribute bonus set to %d (base 175 + %d = %d)", bonus, bonus, 175 + bonus);
	}

	SetEntityHealth(client, guardianCurrentHP);

	// Verify what the engine actually sees after the call
	int liveHP  = GetClientHealth(client);
	int liveMax = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (debugMode)
	{
		GuardianDebugLog("[GUARDIAN DBG] " ... "ApplyGuardianHealth - POST: liveHP=%d liveMax(DataProp)=%d wanted=%d", liveHP, liveMax, guardianCurrentHP);
	}
}

public Action OnGetGuardianMaxHealth(int client, int &maxhealth)
{
	if (!guardianActive || client != guardianClient) return Plugin_Continue;

	maxhealth = guardianMaxHP;
	return Plugin_Changed;
}

void StartUpdateTimer()
{
	StopUpdateTimer();
	updateTimer = CreateTimer(HUD_UPDATE_INTERVAL, Timer_Update, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopUpdateTimer()
{
	delete updateTimer;
	updateTimer = null;
}

public Action Timer_Update(Handle timer)
{
	if (!guardianActive || !IsClientInGame(guardianClient))
	{
		updateTimer = null;
		return Plugin_Stop;
	}

	float now = GetGameTime();

	// Check ability expiration
	if (primaryActive && now >= primaryExpireTime) DeactivatePrimary();
	if (secondaryActive && now >= secondaryExpireTime) DeactivateSecondary();

	// Bot join check - disable Guardian if a bot appeared mid-round (skip in debugMode).
	// g_ActiveBotCount is event-driven (OnClientPostAdminCheck / OnClientDisconnect /
	// OnPlayerTeamChange) so we avoid the per-tick MaxClients loop.
	if (g_ActiveBotCount > 0 && !debugMode)
	{
		GuardianLog("Timer_Update - bot detected mid-round, cleaning up guardian and moving bots to spectator");
		CPrintToChatAll("%t", "Guardian_BotJoined");
		CleanupGuardian(true);
		// Move all active-team bots to spectator so they don't block future rounds
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) > view_as<int>(TFTeam_Spectator))
			{
				GuardianLog("Timer_Update - moving bot %d from team=%d to spectator", i, GetClientTeam(i));
				ChangeClientTeam(i, view_as<int>(TFTeam_Spectator));
			}
		}
		updateTimer = null;
		return Plugin_Stop;
	}

	// FFA check - disable Guardian if FFA was enabled mid-round.
	// g_FFAActiveCached is refreshed by OnLibraryAdded / OnLibraryRemoved /
	// round_start, so per-tick we read a plain bool.
	if (g_FFAActiveCached)
	{
		CPrintToChatAll("%t", "Guardian_BlockedFFA");
		CleanupGuardian(true);
		updateTimer = null;
		return Plugin_Stop;
	}

	// --- Guardian HUD (guardian only) ---
	// Static strings (display name, uppercased ability names, button labels) are
	// cached at activation. Safety net: if we somehow lost the cache mid-round,
	// rebuild before reading.
	if (!g_CachedHudReady) RebuildGuardianHudCache();

	char status1[80];
	char status2[80];

	if (primaryActive)
	{
		float remaining = primaryExpireTime - now;
		FormatEx(status1, sizeof(status1), "[%s] %s [ACTIVE %.1fs]", g_CachedKey1, g_CachedName1, remaining);
	}
	else if (now < primaryNextUseTime)
	{
		float cooldown = primaryNextUseTime - now;
		FormatEx(status1, sizeof(status1), "[%s] %s [CD %.1fs]", g_CachedKey1, g_CachedName1, cooldown);
	}
	else
	{
		FormatEx(status1, sizeof(status1), "[%s] %s [READY]", g_CachedKey1, g_CachedName1);
	}

	if (secondaryActive)
	{
		float remaining = secondaryExpireTime - now;
		FormatEx(status2, sizeof(status2), "[%s] %s [ACTIVE %.1fs]", g_CachedKey2, g_CachedName2, remaining);
	}
	else if (now < secondaryNextUseTime)
	{
		float cooldown = secondaryNextUseTime - now;
		FormatEx(status2, sizeof(status2), "[%s] %s [CD %.1fs]", g_CachedKey2, g_CachedName2, cooldown);
	}
	else
	{
		FormatEx(status2, sizeof(status2), "[%s] %s [READY]", g_CachedKey2, g_CachedName2);
	}

	SetHudTextParams(hudX, hudY, HUD_UPDATE_INTERVAL + 0.05, hudColor[0], hudColor[1], hudColor[2], 255, 0, 0.0, 0.0, 0.0);
	ShowSyncHudText(guardianClient, hudSync,
		"[ %s ]\n%s\n%s",
		g_CachedDisplayName,
		status1,
		status2);

	UpdateBossHealthBar();

	return Plugin_Continue;
}

void UpdateBossHealthBar()
{
	// monsterResource is stored as an EntRef (via EntIndexToEntRef). Must resolve
	// it back to a raw entity index before calling IsValidEntity/SetEntProp — those
	// natives expect edict indices, not EntRefs.
	int resourceEntity = EntRefToEntIndex(monsterResource);
	if (resourceEntity == INVALID_ENT_REFERENCE || !IsValidEntity(resourceEntity)) return;

	if (!guardianActive || guardianMaxHP <= 0)
	{
		HideBossHealthBar();
		return;
	}

	if (IsClientInGame(guardianClient) && IsPlayerAlive(guardianClient))
	{
		guardianCurrentHP = GetClientHealth(guardianClient);
	}
	else
	{
		guardianCurrentHP = 0;
	}

	int byte = RoundToFloor((float(guardianCurrentHP) / float(guardianMaxHP)) * 255.0);

	if (byte < 0)   byte = 0;
	if (byte > 255)  byte = 255;

	SetEntProp(resourceEntity, Prop_Send, "m_iBossHealthPercentageByte", byte);

	int bossState = 0;
	if (debugBossState >= 0 && debugBossState <= 4)
	{
		bossState = debugBossState;
	}
	else
	{
		// Safety: invalid debug values should never leak into live HUD state.
		debugBossState = -1;
	}

	// Known practical states from community usage:
	// 0 = default, 1 = healing/green, 3 = victory/blue, 4 = loss/gray.
	SetEntProp(resourceEntity, Prop_Send, "m_iBossState", bossState);
}

void HideBossHealthBar()
{
	int resourceEntity = EntRefToEntIndex(monsterResource);
	if (resourceEntity != INVALID_ENT_REFERENCE && IsValidEntity(resourceEntity))
	{
		SetEntProp(resourceEntity, Prop_Send, "m_iBossHealthPercentageByte", 0);
		SetEntProp(resourceEntity, Prop_Send, "m_iBossState", 0);
	}
}

public Action Command_BossState(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[TFDB] Usage: sm_tfdb_bossstate <-1|0-4> (-1 disables override)");
		return Plugin_Handled;
	}

	char arg[10];
	GetCmdArg(1, arg, sizeof(arg));
	int value = StringToInt(arg);
	if (value < -1 || value > 4)
	{
		ReplyToCommand(client, "[TFDB] Invalid boss state %d. Use -1 or 0-4.", value);
		return Plugin_Handled;
	}

	debugBossState = value;
	ReplyToCommand(client, "[TFDB] Boss state override set to: %d", debugBossState);
	return Plugin_Handled;
}
