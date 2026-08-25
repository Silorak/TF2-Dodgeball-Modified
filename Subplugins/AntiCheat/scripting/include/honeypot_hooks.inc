#if defined _honeypot_hooks_included
  #endinput
#endif
#define _honeypot_hooks_included
// SDKHooks and event hooks for honeypot interaction (OnPlayerRunCmd, damage, deflection, temp ents).


#include "honeypot_entities.inc"
#include "honeypot_utils.inc"

// ===================== Hooks & Events =====================

public Action Hook_NormalSound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], 
                                int &entity, int &channel, float &volume, int &level, int &pitch, int &flags,
                                char soundEntry[PLATFORM_MAX_PATH], int &seed) {
    // Check if this sound is from a honeypot
    if (entity > MaxClients) {
        if (IsSuppressedHoneypotEntity(entity)) {
            return Plugin_Stop;
        }
        if (!IsValidEntity(entity)) {
            return Plugin_Continue;
        }
        for (int i = 0; i < MAX_ROCKETS; i++) {
            if (g_Honeypots[i].isActive && g_Honeypots[i].entity == entity) {
                // This is a honeypot - block ALL sounds from it
                return Plugin_Stop;
            }
            if (g_Honeypots[i].isActive && g_Honeypots[i].visualEntity == entity) {
                int tv = -1;
                for (int c = 1; c <= MaxClients; c++) {
                    if (IsClientConnected(c) && IsClientSourceTV(c)) { tv = c; break; }
                }
                if (tv == -1) { return Plugin_Stop; }
                int n = 0;
                clients[n++] = tv;
                numClients = n;
                return Plugin_Changed;
            }
        }
    }
    return Plugin_Continue;
}

public void OnParticleSpawn(const char[] output, int caller, int activator, float delay) {
}

public Action Hook_BlockParticleEffects(const char[] te_name, const int[] Players, int numClients, float delay)
{
    // --- Try to get the entity index (different TempEntity types use different property names) ---
    int entity = -1;

    if (TE_IsValidProp("entindex")) {
        entity = TE_ReadNum("entindex");
    } else if (TE_IsValidProp("m_nEntIndex")) {
        entity = TE_ReadNum("m_nEntIndex");
    } else if (TE_IsValidProp("m_hEntity")) {
        entity = TE_ReadNum("m_hEntity");
    }

    if (entity > MaxClients && IsValidEntity(entity))
    {
        if (IsSuppressedHoneypotEntity(entity))
        {
            if (g_hDebugMode.BoolValue)
            {
                PrintToServer("[BustedByDarka] Blocked particle effect '%s' from suppressed honeypot entity %d", te_name, entity);
            }
            return Plugin_Handled;
        }
        for (int i = 0; i < MAX_ROCKETS; i++)
        {
            if (!g_Honeypots[i].isActive) continue;

            if (g_Honeypots[i].entity == entity)
            {
                if (g_hDebugMode.BoolValue)
                {
                    PrintToServer("[BustedByDarka] Blocked particle effect '%s' from honeypot %d", te_name, entity);
                }
                return Plugin_Handled;
            }

            if (g_Honeypots[i].visualEntity == entity)
            {
                bool onlyTV = false;
                if (numClients == 1 && Players[0] >= 1 && Players[0] <= MaxClients && IsClientConnected(Players[0]) && IsClientSourceTV(Players[0]))
                {
                    onlyTV = true;
                }
                if (!onlyTV)
                {
                    return Plugin_Handled;
                }
                return Plugin_Continue;
            }
        }
    }

    // Only block when particle TE explicitly references a honeypot entity.
    // Do not block by proximity to avoid corrupting real rocket particle control points.
    return Plugin_Continue;
}

// Limit visual duplicate transmission to SourceTV only
public Action OnSourceTVVisualSetTransmit(int entity, int client)
{
    if (!IsClientInGame(client))
        return Plugin_Handled;

    // Allow SourceTV only
    if (IsClientSourceTV(client))
        return Plugin_Continue;

    return Plugin_Handled;
}

public Action OnHoneypotSetTransmit(int entity, int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Handled;

    bool isHoneypot = false;
    int target = -1;
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (!g_Honeypots[i].isActive)
            continue;
        if (g_Honeypots[i].entity != entity)
            continue;
        isHoneypot = true;
        target = g_Honeypots[i].target;
        break;
    }

    if (!isHoneypot)
        return Plugin_Continue;

    if (IsClientSourceTV(client))
        return Plugin_Continue;

    if (client == target)
        return Plugin_Continue;

    return Plugin_Handled;
}

public Action OnPlayerAttack2(int client, const char[] command, int argc) {
    if (!g_hEnabled.BoolValue || !g_HoneypotsActive) return Plugin_Continue;
    if (!IsValidClientEx(client, true)) return Plugin_Continue;

    // Record last attack2 time for attribution
    g_Clients[client].lastAttack2Time = GetGameTime();
    g_PressTimes[client][3] = g_PressTimes[client][2];
    g_PressTimes[client][2] = g_PressTimes[client][1];
    g_PressTimes[client][1] = g_PressTimes[client][0];
    g_PressTimes[client][0] = g_Clients[client].lastAttack2Time;

    // Check for flamethrower
    int weapon = GetPlayerWeaponSlot(client, TFWeaponSlot_Primary);
    if (weapon == -1) return Plugin_Continue;

    char weaponClass[32];
    GetEntityClassname(weapon, weaponClass, sizeof(weaponClass));
    if (StrContains(weaponClass, "flamethrower", false) == -1) return Plugin_Continue;

    return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    // Track previous button state so we only log when the key is *pressed* (not held)
    static int lastButtons[MAXPLAYERS + 1];

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    float lastPitch = g_LastAngles[client][0];
    float lastYaw = g_LastAngles[client][1];
    float dPitch = angles[0] - lastPitch;
    if (dPitch < -180.0) dPitch += 360.0;
    if (dPitch > 180.0) dPitch -= 360.0;
    float dYaw = angles[1] - lastYaw;
    if (dYaw < -180.0) dYaw += 360.0;
    if (dYaw > 180.0) dYaw -= 360.0;
    float degMove = AbsFloat(dPitch) + AbsFloat(dYaw);
    int midx = g_MouseDegCount[client] % 20;
    g_MouseDegTimes[client][midx] = GetGameTime();
    g_MouseDegMag[client][midx] = degMove;
    g_MouseDegCount[client]++;
    g_LastAngles[client][0] = angles[0];
    g_LastAngles[client][1] = angles[1];
    g_LastAngles[client][2] = angles[2];

    // Detect new airblast press (transition from not pressed → pressed)
    bool pressed = (buttons & IN_ATTACK2) && !(lastButtons[client] & IN_ATTACK2);
    if (pressed)
    {
        g_Clients[client].lastAttack2Time = GetGameTime();
        g_PressTimes[client][3] = g_PressTimes[client][2];
        g_PressTimes[client][2] = g_PressTimes[client][1];
        g_PressTimes[client][1] = g_PressTimes[client][0];
        g_PressTimes[client][0] = g_Clients[client].lastAttack2Time;
        float eye[3], ang[3], fwd[3];
        GetClientEyePosition(client, eye);
        GetClientEyeAngles(client, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(fwd, fwd);
        float bestDist = -1.0;
        int maxEnt = GetMaxEntities();
        for (int e = MaxClients + 1; e < maxEnt; e++) {
            if (!IsValidEntity(e)) continue;
            char cls[64];
            if (!GetEntityClassname(e, cls, sizeof(cls))) continue;
            if (!StrEqual(cls, "tf_projectile_rocket")) continue;
            float rkPos[3], toRK[3];
            GetEntPropVector(e, Prop_Send, "m_vecOrigin", rkPos);
            VectorSubtract(rkPos, eye, toRK);
            float d = NormalizeVector(toRK, toRK);
            float dot = DotProduct(fwd, toRK);
            if (dot < 0.5) continue;
            if (bestDist < 0.0 || d < bestDist) bestDist = d;
        }
        g_Clients[client].lastPressRocketDist = bestDist;
        if (g_hDebugMode.BoolValue)
        {
            PrintToServer("[AirblastDebug] %N pressed attack2 (time %.2f)", client, g_Clients[client].lastAttack2Time);
            if (bestDist >= 0.0) {
                PrintToServer("[AirblastDebug] Real rocket dist at press: %.1f (entry=%.1f)", bestDist, g_hEntryRange.FloatValue);
            }
        }
    }

    lastButtons[client] = buttons;
    g_Clients[client].holdingAttack2 = (buttons & IN_ATTACK2) != 0;
    return Plugin_Continue;
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (!g_hEnabled.BoolValue || g_HoneypotCount <= 0) {
        return;
    }
}

public Action OnHoneypotPreSpawn(int honeypotEntity)
{
    ForceHoneypotInvisible(honeypotEntity);
    return Plugin_Continue;
}

public void OnHoneypotSpawnPost(int honeypotEntity)
{
}

public Action OnHoneypotDamaged(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3]) {
    if (g_hDebugMode.BoolValue) {
        char victimName[64], attackerName[64];
        // Safely get names or use entity/client indices
        if (IsValidClientEx(attacker)) {
            GetClientName(attacker, attackerName, sizeof(attackerName));
        } else {
            Format(attackerName, sizeof(attackerName), "Entity %d", attacker);
        }
        
        if (IsValidEntity(victim)) {
            Format(victimName, sizeof(victimName), "Honeypot %d", victim);
        } else {
            Format(victimName, sizeof(victimName), "Invalid Entity %d", victim);
        }

        PrintToServer("[BustedByDarka] DMG HOOK: %s hit %s. Type: %d (Airblast: %s)", 
            attackerName, 
            victimName, 
            damagetype, 
            (damagetype & DMG_AIRBLAST) != 0 ? "YES" : "NO");
    }
    
    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)) {
        bool isAirblast = ((damagetype & DMG_AIRBLAST) != 0);
        if (!isAirblast && weapon > 0 && IsValidEntity(weapon)) {
            char weaponClass[64];
            GetEntityClassname(weapon, weaponClass, sizeof(weaponClass));
            if (StrContains(weaponClass, "flamethrower", false) != -1) {
                isAirblast = true;
            }
        } else if (!isAirblast) {
            int activeWeapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
            if (activeWeapon > 0 && IsValidEntity(activeWeapon)) {
                char activeClass[64];
                GetEntityClassname(activeWeapon, activeClass, sizeof(activeClass));
                if (StrContains(activeClass, "flamethrower", false) != -1) {
                    isAirblast = true;
                }
            }
        }

        if (isAirblast) {
            DetectHoneypotInteraction(attacker, victim, HoneypotDetectionSource_Damage);
        }
    }
    return Plugin_Handled;
}

public Action OnRealRocketDamaged(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3]) {
    int actual = attacker;
    if (actual <= 0 || actual > MaxClients) {
        actual = inflictor;
    }
    if (actual <= 0 || actual > MaxClients) {
        return Plugin_Continue;
    }
    if (!IsClientInGame(actual)) {
        return Plugin_Continue;
    }

    bool isBlast = (damagetype & DMG_AIRBLAST) != 0;
    if (!isBlast && weapon > 0 && IsValidEntity(weapon)) {
        char wc[64];
        GetEntityClassname(weapon, wc, sizeof(wc));
        if (StrContains(wc, "flamethrower", false) != -1) {
            isBlast = true;
        }
    }
    if (!isBlast) {
        int activeWeapon = GetEntPropEnt(actual, Prop_Send, "m_hActiveWeapon");
        if (activeWeapon > 0 && IsValidEntity(activeWeapon)) {
            char ac[64];
            GetEntityClassname(activeWeapon, ac, sizeof(ac));
            if (StrContains(ac, "flamethrower", false) != -1) {
                isBlast = true;
            }
        }
    }
    if (!isBlast) {
        return Plugin_Continue;
    }

    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (!g_Honeypots[i].isActive) continue;
        if (g_Honeypots[i].realRocketEntity != victim) continue;
        int target = g_Honeypots[i].target;
        if (actual != target) continue;
        DetectHoneypotInteraction(actual, g_Honeypots[i].entity, HoneypotDetectionSource_Damage);
        CleanupHoneypot(i);
        break;
    }
    return Plugin_Continue;
}

public Action OnHoneypotPreventTouch(int honeypotEntity, int other) {
    SuppressHoneypotEffects(honeypotEntity);
    if (other > 0 && other <= MaxClients) {
        return Plugin_Handled;
    }
    return Plugin_Handled;
}

public bool OnHoneypotShouldCollide(int honeypotEntity, int collisiongroup, int contentsmask, bool originalResult)
{
    return false;
}

public Action OnHoneypotBlocked(int honeypotEntity, int other)
{
    SuppressHoneypotEffects(honeypotEntity);
    return Plugin_Handled;
}

public Action OnHoneypotStartTouch(int victim, int other) {
    SuppressHoneypotEffects(victim);
    if (other > 0 && other <= MaxClients && IsClientInGame(other)) {
        // Find and cleanup this honeypot
        for (int i = 0; i < MAX_ROCKETS; i++) {
            if (g_Honeypots[i].isActive && g_Honeypots[i].entity == victim) {
                CleanupHoneypot(i);
                break;
            }
        }
    }
    return Plugin_Handled;
}

public void TFDB_OnRocketDeflect(int rocketIndex, int rocketEntity, int rocketOwner)
{
    if (!g_hEnabled.BoolValue || !g_HoneypotsActive || !g_TF2DodgeballLoaded)
        return;

    if (!IsValidEntity(rocketEntity))
        return;

    // 🔹 1. NEW: Check if this deflected rocket is one of our honeypots
    for (int i = 0; i < MAX_ROCKETS; i++)
    {
        if (g_Honeypots[i].isActive && g_Honeypots[i].entity == rocketEntity)
        {
            DetectHoneypotInteraction(rocketOwner, rocketEntity, HoneypotDetectionSource_Damage);

            if (g_hDebugMode.BoolValue)
            {
                char deflectorName[64];
                GetClientName(rocketOwner, deflectorName, sizeof(deflectorName));
                PrintToServer("[BustedByDarka] TFDB deflect: %s deflected honeypot %d", deflectorName, rocketEntity);
            }

            // No need to spawn another honeypot for this one.
            return;
        }
    }

    // 🔹 2. ORIGINAL LOGIC: normal rockets spawn predictive honeypots
    int targetRef = TFDB_GetRocketTarget(rocketIndex);
    if (targetRef == INVALID_ENT_REFERENCE)
        return;

    int target = EntRefToEntIndex(targetRef);
    if (!IsEligibleHoneypotTarget(target))
        return;

    bool hasSamePending = false;
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (!g_PendingSpawns[i].active) continue;
        int refEnt = EntRefToEntIndex(g_PendingSpawns[i].rocketRef);
        if (refEnt != rocketEntity) continue;
        if (g_PendingSpawns[i].target == target) {
            hasSamePending = true;
        } else {
            g_PendingSpawns[i].active = false;
        }
    }
    if (g_hDebugMode.BoolValue)
    {
        char tn[64];
        GetClientName(target, tn, sizeof(tn));
        PrintToServer("[HoneypotSched] Deflect: rocket=%d newTarget=%s (%s)", rocketEntity, tn, hasSamePending ? "keep same-target pending" : "cancel others");
    }
    if (!hasSamePending) {
        ScheduleHoneypotSpawn(rocketEntity, target);
    }
}

public void TFDB_OnRocketCreated(int rocketIndex, int rocketEntity) {
    if (!g_hEnabled.BoolValue || !g_HoneypotsActive || !g_TF2DodgeballLoaded) return;
    
    int targetRef = TFDB_GetRocketTarget(rocketIndex);
    int target = EntRefToEntIndex(targetRef);
    
    if (!IsEligibleHoneypotTarget(target)) return;
    
    CancelPendingSpawnFor(rocketEntity, target);
    ScheduleHoneypotSpawn(rocketEntity, target);
    SDKHook(rocketEntity, SDKHook_OnTakeDamage, OnRealRocketDamaged);
}

public void TFDB_OnRocketNoTarget(int rocketIndex, int newTarget, int previousTarget)
{
    if (!g_hEnabled.BoolValue || !g_HoneypotsActive || !g_TF2DodgeballLoaded)
        return;

    int rocketRef = TFDB_GetRocketEntity(rocketIndex);
    int rocketEntity = EntRefToEntIndex(rocketRef);
    if (!IsValidEntity(rocketEntity))
        return;

    for (int i = 0; i < MAX_ROCKETS; i++)
    {
        if (g_Honeypots[i].isActive && g_Honeypots[i].entity == rocketEntity)
        {
            return;
        }
    }

    int targetRef = TFDB_GetRocketTarget(rocketIndex);
    if (targetRef == INVALID_ENT_REFERENCE)
        return;

    int target = EntRefToEntIndex(targetRef);
    if (!IsEligibleHoneypotTarget(target))
        return;

    CancelPendingSpawnFor(rocketEntity, target);
    ScheduleHoneypotSpawn(rocketEntity, target);
}

public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client && IsClientInGame(client)) {
        g_Clients[client].honeypotDetections = 0;
        g_Clients[client].lastDetectionTime = 0.0;
        g_Clients[client].consecutiveDetections = 0;
        g_Clients[client].lastTargetedTime = 0.0;
    }
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client && IsClientInGame(client)) {
        g_Clients[client].honeypotDetections = 0;
        g_Clients[client].consecutiveDetections = 0;
    }
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast) {
    g_HoneypotsActive = true;
    g_HoneypotCount = 0;
    
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (g_Honeypots[i].isActive) {
            CleanupHoneypot(i);
        }
        g_PendingSpawns[i].active = false;
    }
    
    // Start SourceTV recording
    if (g_hSourceTVEnable.BoolValue && g_hSourceTVAutoRecord.BoolValue) {
        CreateTimer(1.0, Timer_OpenSourceTVBookmarkSession, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnRoundEnd(Event event, const char[] name, bool dontBroadcast) {
    g_HoneypotsActive = false;
    
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (g_Honeypots[i].isActive) {
            CleanupHoneypot(i);
        }
        g_PendingSpawns[i].active = false;
    }
    
    // Stop SourceTV recording
    if (g_hSourceTVEnable.BoolValue && g_hSourceTVAutoRecord.BoolValue) {
        CreateTimer(2.0, Timer_CloseSourceTVBookmarkSession, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnClientDisconnect(int client) {
    g_Clients[client].honeypotDetections = 0;
    g_Clients[client].lastDetectionTime = 0.0;
    g_Clients[client].consecutiveDetections = 0;
    
    // Stop recording if all real players have left
    if (g_hSourceTVEnable.BoolValue && g_hSourceTVAutoRecord.BoolValue && !IsFakeClient(client)) {
        // Check after a short delay to ensure disconnect is processed
        CreateTimer(1.0, Timer_CloseBookmarkSessionIfEmpty, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnPluginEnd() {
    if (g_GameFrameTimer != null) {
        KillTimer(g_GameFrameTimer);
    }
    
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (g_Honeypots[i].isActive) {
            CleanupHoneypot(i);
        }
    }
    
    PrintToServer("[BustedByDarka] Shutdown complete");
}
