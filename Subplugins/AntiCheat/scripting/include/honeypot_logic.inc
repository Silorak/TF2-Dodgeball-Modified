#if defined _honeypot_logic_included
  #endinput
#endif
#define _honeypot_logic_included
// Honeypot spawn positioning, safety checks, lifecycle management, and cleanup.



#include "honeypot_entities.inc"
#include "honeypot_utils.inc"

// ===================== Core Logic =====================

public void Frame_EnsureHoneypotNonSolid(int entityRef)
{
    int honeypotEntity = EntRefToEntIndex(entityRef);
    if (honeypotEntity == INVALID_ENT_REFERENCE || !IsValidEntity(honeypotEntity)) return;
    SetEntProp(honeypotEntity, Prop_Send, "m_nSolidType", 2);
    EnsureHoneypotNonSolid(honeypotEntity);
}

stock bool IsHoneypotOverlappingPlayerAtPos(float pos[3], int client, const float feetOrigin[3])
{
    if (!IsValidClientEx(client, true)) {
        return false;
    }

    // Standard TF2 player hull (was probed via 4 HasEntProp per call; players
    // are always the same hull in practice, and this function is on the
    // per-honeypot-per-tick cleanup path - review F5).
    float playerOrigin[3];
    playerOrigin[0] = feetOrigin[0];
    playerOrigin[1] = feetOrigin[1];
    playerOrigin[2] = feetOrigin[2];

    float playerMins[3] = {-24.0, -24.0, 0.0};
    float playerMaxs[3] = {24.0, 24.0, 82.0};

    float safetyPad = 6.0;
    float plyMin[3], plyMax[3];
    plyMin[0] = playerOrigin[0] + playerMins[0] - safetyPad;
    plyMin[1] = playerOrigin[1] + playerMins[1] - safetyPad;
    plyMin[2] = playerOrigin[2] + playerMins[2] - safetyPad;
    plyMax[0] = playerOrigin[0] + playerMaxs[0] + safetyPad;
    plyMax[1] = playerOrigin[1] + playerMaxs[1] + safetyPad;
    plyMax[2] = playerOrigin[2] + playerMaxs[2] + safetyPad;

    float hpMin[3], hpMax[3];
    hpMin[0] = pos[0] - 8.0;
    hpMin[1] = pos[1] - 8.0;
    hpMin[2] = pos[2] - 8.0;
    hpMax[0] = pos[0] + 8.0;
    hpMax[1] = pos[1] + 8.0;
    hpMax[2] = pos[2] + 8.0;

    if (hpMax[0] < plyMin[0] || hpMin[0] > plyMax[0]) return false;
    if (hpMax[1] < plyMin[1] || hpMin[1] > plyMax[1]) return false;
    if (hpMax[2] < plyMin[2] || hpMin[2] > plyMax[2]) return false;
    return true;
}

stock bool IsHoneypotSpawnClearOfPlayers(float pos[3])
{
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClientEx(i, true)) {
            continue;
        }
        float feet[3];
        GetClientAbsOrigin(i, feet);
        if (IsHoneypotOverlappingPlayerAtPos(pos, i, feet)) {
            return false;
        }
    }
    return true;
}

stock bool ShouldCleanupHoneypotForNearbyPlayers(float hpPos[3])
{
    float bodyDanger = 56.0;
    float movingDanger = 112.0;
    float closingSpeedMin = 90.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClientEx(i, true)) {
            continue;
        }

        float feet[3];
        GetClientAbsOrigin(i, feet);
        if (IsHoneypotOverlappingPlayerAtPos(hpPos, i, feet)) {
            return true;
        }
        float center[3];
        center[0] = feet[0];
        center[1] = feet[1];
        center[2] = feet[2] + 48.0;

        float toHp[3];
        VectorSubtract(hpPos, center, toHp);
        float dist = NormalizeVector(toHp, toHp);
        if (dist <= bodyDanger) {
            return true;
        }

        if (dist > movingDanger) {
            continue;
        }

        float vel[3];
        if (!TryGetEntityAbsVelocity(i, vel)) {
            continue;
        }

        float closing = DotProduct(vel, toHp);
        if (closing >= closingSpeedMin) {
            return true;
        }
    }

    return false;
}

stock bool ResolveSafeHoneypotSpawn(int target, float eyePos[3], float desiredPos[3], float outPos[3])
{
    static const float hullMins[3] = {-8.0, -8.0, -8.0};
    static const float hullMaxs[3] = { 8.0,  8.0,  8.0};
    const int spawnMask = MASK_PLAYERSOLID_BRUSHONLY;

    float toDesired[3];
    VectorSubtract(desiredPos, eyePos, toDesired);
    float desiredDist = NormalizeVector(toDesired, toDesired);
    if (desiredDist < 112.0) {
        return false;
    }

    outPos[0] = desiredPos[0];
    outPos[1] = desiredPos[1];
    outPos[2] = desiredPos[2];

    Handle tr = TR_TraceHullFilterEx(eyePos, desiredPos, hullMins, hullMaxs, spawnMask, TraceEntityFilterPlayers, 0);
    if (tr != null) {
        if (TR_DidHit(tr)) {
            float hit[3];
            TR_GetEndPosition(hit, tr);

            // Keep the honeypot off the wall so it cannot instantly collide and explode.
            float backoff = 28.0;
            outPos[0] = hit[0] - (toDesired[0] * backoff);
            outPos[1] = hit[1] - (toDesired[1] * backoff);
            outPos[2] = hit[2] - (toDesired[2] * backoff);
        }
        delete tr;
    }

    if (GetVectorDistance(eyePos, outPos) < 96.0) {
        return false;
    }

    float feet[3];
    GetClientAbsOrigin(target, feet);
    float bodyCenter[3];
    bodyCenter[0] = feet[0];
    bodyCenter[1] = feet[1];
    bodyCenter[2] = feet[2] + 48.0;

    float toBody[3];
    VectorSubtract(outPos, bodyCenter, toBody);
    float bodyDist = NormalizeVector(toBody, toBody);
    if (bodyDist < 92.0) {
        float fallbackDir[3];
        VectorSubtract(outPos, eyePos, fallbackDir);
        if (NormalizeVector(fallbackDir, fallbackDir) < 0.001) {
            fallbackDir[0] = 1.0;
            fallbackDir[1] = 0.0;
            fallbackDir[2] = 0.0;
        }
        if (bodyDist < 0.001) {
            toBody[0] = fallbackDir[0];
            toBody[1] = fallbackDir[1];
            toBody[2] = fallbackDir[2];
        }
        float push = (92.0 - bodyDist) + 12.0;
        outPos[0] += toBody[0] * push;
        outPos[1] += toBody[1] * push;
        outPos[2] += toBody[2] * push;
    }

    if (GetVectorDistance(bodyCenter, outPos) < 88.0) {
        return false;
    }

    // Reject points that start inside world/playerclip.
    Handle trSolid = TR_TraceHullFilterEx(outPos, outPos, hullMins, hullMaxs, spawnMask, TraceEntityFilterPlayers, 0);
    if (trSolid != null) {
        if (TR_StartSolid(trSolid) || TR_AllSolid(trSolid)) {
            delete trSolid;
            return false;
        }
        delete trSolid;
    }

    if (!IsHoneypotSpawnClearOfPlayers(outPos)) {
        return false;
    }

    static const float probeOffset[6][3] = {
        {16.0, 0.0, 0.0},
        {-16.0, 0.0, 0.0},
        {0.0, 16.0, 0.0},
        {0.0, -16.0, 0.0},
        {0.0, 0.0, 16.0},
        {0.0, 0.0, -16.0}
    };

    int blockedDirections = 0;
    for (int i = 0; i < sizeof(probeOffset); i++) {
        float probe[3];
        probe[0] = outPos[0] + probeOffset[i][0];
        probe[1] = outPos[1] + probeOffset[i][1];
        probe[2] = outPos[2] + probeOffset[i][2];
        Handle trProbe = TR_TraceHullFilterEx(outPos, probe, hullMins, hullMaxs, spawnMask, TraceEntityFilterPlayers, 0);
        if (trProbe != null) {
            if (TR_DidHit(trProbe) && TR_GetFraction(trProbe) < 0.999) {
                blockedDirections++;
            }
            delete trProbe;
        }
    }

    if (blockedDirections >= 3) {
        return false;
    }

    if (!IsHoneypotSpawnClearOfPlayers(outPos)) {
        return false;
    }

    return true;
}

stock bool HasAmbiguousNearbyPyro(int target, int rocketEntity)
{
    float radius = g_hMultiPyroRadius.FloatValue;
    float targetEye[3];
    GetClientEyePosition(target, targetEye);

    float rocketPos[3];
    GetEntPropVector(rocketEntity, Prop_Send, "m_vecOrigin", rocketPos);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == target)
            continue;
        if (!IsValidClientEx(i, true))
            continue;
        if (TF2_GetPlayerClass(i) != TFClass_Pyro)
            continue;

        float eye[3], ang[3], fwd[3];
        GetClientEyePosition(i, eye);
        GetClientEyeAngles(i, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(fwd, fwd);

        float dist = GetVectorDistance(eye, targetEye);
        if (dist > radius)
            continue;

        float toRocket[3];
        VectorSubtract(rocketPos, eye, toRocket);
        NormalizeVector(toRocket, toRocket);
        float dot = DotProduct(fwd, toRocket);
        if (dot >= g_hFaceDot.FloatValue)
            return true;
    }

    return false;
}

stock bool HasVeryClosePyro(int target)
{
    float radius = g_hMultiPyroCloseRadius.FloatValue;
    float eyeT[3];
    GetClientEyePosition(target, eyeT);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == target) continue;
        if (!IsValidClientEx(i, true)) continue;
        if (TF2_GetPlayerClass(i) != TFClass_Pyro) continue;
        float eye[3];
        GetClientEyePosition(i, eye);
        float d = GetVectorDistance(eye, eyeT);
        if (d <= radius)
            return true;
    }
    return false;
}

stock bool CanScheduleForTarget(int rocketEntity, int target, float windowStart)
{
    float now = GetGameTime();
    float cooldown = g_hTargetCooldown.FloatValue;
    float dtSinceTargeted = (windowStart - g_Clients[target].lastTargetedTime);
    float dtUntilWindow = (windowStart - now);
    bool immediate = dtUntilWindow <= 0.06;
    if (!immediate && cooldown > 0.0 && dtSinceTargeted < cooldown) {
        if (g_hDebugMode.BoolValue) {
            char name[64]; GetClientName(target, name, sizeof(name));
            PrintToServer("[HoneypotSched] Blocked by cooldown for %s (dt=%.2f < %.2f)", name, (windowStart - g_Clients[target].lastTargetedTime), cooldown);
        }
        return false;
    }

    if (g_hMultiPyroEnable.BoolValue && (HasAmbiguousNearbyPyro(target, rocketEntity) || HasVeryClosePyro(target))) {
        if (g_hDebugMode.BoolValue) {
            char name2[64]; GetClientName(target, name2, sizeof(name2));
            PrintToServer("[HoneypotSched] Blocked by multi-Pyro ambiguity near %s", name2);
        }
        return false;
    }

    return true;
}

// Initialize arrays
public void InitializeHoneypotArrays() {
    for (int i = 0; i < MAX_ROCKETS; i++) {
        g_Honeypots[i].entity = -1;
        g_Honeypots[i].target = -1;
        g_Honeypots[i].realRocketEntity = -1;
        g_Honeypots[i].spawnTime = 0.0;
        g_Honeypots[i].detections = 0;
        g_Honeypots[i].isActive = false;
        g_Honeypots[i].cleanupTimer = null;
        g_Honeypots[i].particleKillTimer = null;
    }
    g_HoneypotCount = 0;
}

public void InitializeClientData() {
    for (int i = 1; i <= MaxClients; i++) {
        g_Clients[i].honeypotDetections = 0;
        g_Clients[i].lastDetectionTime = 0.0;
        g_Clients[i].consecutiveDetections = 0;
        g_Clients[i].detectionScore = 0.0;
        g_Clients[i].lastPressRocketDist = -1.0;
        g_HpReactionCounts[i] = 0;
    }
}

static void FinalizeHoneypotEntity(int honeypotEntity) {
    if (!IsValidEntity(honeypotEntity)) {
        return;
    }

    static const char honeypotModel[] = "models/weapons/w_models/w_rocket_udl.mdl";
    PrecacheModel(honeypotModel);
    SetEntityModel(honeypotEntity, honeypotModel);

    ForceHoneypotInvisible(honeypotEntity);
}

void RequeuePendingSpawn(int slot, int rocketEntity, int target, float now, float delay)
{
    g_PendingSpawns[slot].rocketRef = EntIndexToEntRef(rocketEntity);
    g_PendingSpawns[slot].target = target;
    g_PendingSpawns[slot].spawnAt = now + delay;
    g_PendingSpawns[slot].active = true;
}

public void OnGameFrame() {
    if (!g_hEnabled.BoolValue || !g_HoneypotsActive) {
        return;
    }

    // Score decay: if a player hasn't been flagged in a while, gradually forgive
    // borderline detections. This prevents legitimate players who occasionally
    // hit the honeypot from accumulating score across a long session. Cheaters
    // who hit the honeypot repeatedly (rapid detections) are unaffected because
    // their lastDetectionTime stays recent. Throttled to ~5s to avoid per-tick work.
    static float nextDecayCheck = 0.0;
    float decayNow = GetGameTime();
    if (decayNow >= nextDecayCheck)
    {
        nextDecayCheck = decayNow + 5.0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_Clients[i].detectionScore <= 0.0) continue;
            float since = decayNow - g_Clients[i].lastDetectionTime;
            if (since > 60.0)   // 1 minute clean: start decaying
                g_Clients[i].detectionScore *= 0.90;  // 10% reduction per 5s check
        }
    }

    float currentTime = GetGameTime();
    float entryRange = g_hEntryRange.FloatValue;
    float honeypotLifetime = g_hHoneypotLifetime.FloatValue;

    // Snapshot only TFDB-owned rockets; honeypot projectile entities are excluded.
    static float realRocketPositions[MAX_ROCKETS][3];
    int realRocketCount = 0;
    if (g_TF2DodgeballLoaded) {
        int expectedRockets = TFDB_GetRocketCount();
        for (int index = 0; index < MAX_ROCKETS && realRocketCount < expectedRockets; index++) {
            if (!TFDB_IsValidRocket(index)) continue;
            int entity = TFDB_GetRocketEntity(index);
            if (entity <= MaxClients || !IsValidEntity(entity)) continue;
            GetEntPropVector(entity, Prop_Send, "m_vecOrigin", realRocketPositions[realRocketCount]);
            realRocketCount++;
        }
    }

    // Entry-cross detection needs at least one real rocket; with zero rockets
    // every client would pay 4 eye/angle natives only to skip per candidate
    // (review F10).
    if (realRocketCount > 0)
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;
        float eye[3], angles[3], fwd[3];
        GetClientEyePosition(client, eye);
        GetClientEyeAngles(client, angles);
        GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(fwd, fwd);

        float bestDistance = -1.0;
        for (int rocket = 0; rocket < realRocketCount; rocket++) {
            float toRocket[3];
            VectorSubtract(realRocketPositions[rocket], eye, toRocket);
            float distance = NormalizeVector(toRocket, toRocket);
            if (DotProduct(fwd, toRocket) < 0.5) continue;
            if (bestDistance < 0.0 || distance < bestDistance) bestDistance = distance;
        }
        if (bestDistance < 0.0) continue;

        float previousDistance = g_LastRocketDist[client];
        if (previousDistance > entryRange && bestDistance <= entryRange) {
            g_LastEntryCrossTime[client] = currentTime;
        }
        g_LastRocketDist[client] = bestDistance;
    }

    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (!g_Honeypots[i].isActive) continue;

        int realRocketEntity = g_Honeypots[i].realRocketEntity;
        if (realRocketEntity == -1 || !IsValidEntity(realRocketEntity)) {
            CleanupHoneypot(i);
            continue;
        }

        int target = g_Honeypots[i].target;
        if (!IsEligibleHoneypotTarget(target)) {
            CleanupHoneypot(i);
            continue;
        }

        int realDeflected = GetEntProp(realRocketEntity, Prop_Send, "m_iDeflected");
        if (realDeflected != 0) {
            int newOwner = GetEntPropEnt(realRocketEntity, Prop_Send, "m_hOwnerEntity");
            if (newOwner > 0 && newOwner <= MaxClients && IsClientInGame(newOwner) && newOwner == target) {
                DetectHoneypotInteraction(target, g_Honeypots[i].entity, HoneypotDetectionSource_Damage);
                CleanupHoneypot(i);
                continue;
            }
        }

        int deflected = GetEntProp(g_Honeypots[i].entity, Prop_Send, "m_iDeflected");
        if (deflected != 0) {
            int owner = GetEntPropEnt(g_Honeypots[i].entity, Prop_Send, "m_hOwnerEntity");
            if (owner > 0 && owner <= MaxClients && IsClientInGame(owner)) {
                DetectHoneypotInteraction(owner, g_Honeypots[i].entity, HoneypotDetectionSource_Damage);
            }
            CleanupHoneypot(i);
            continue;
        }

        // Prevent rare ground collisions: if vertical velocity is strongly downward and
        // the honeypot is close to ground, dampen Z velocity to avoid touching world.
        float hpVel[3];
        if (TryGetEntityAbsVelocity(g_Honeypots[i].entity, hpVel)) {
            if (hpVel[2] < -100.0) {
                float origin[3];
                GetEntPropVector(g_Honeypots[i].entity, Prop_Send, "m_vecOrigin", origin);
                float groundCheck[3];
                groundCheck[0] = origin[0];
                groundCheck[1] = origin[1];
                groundCheck[2] = origin[2] - 16.0;
                Handle tr = TR_TraceRayFilterEx(origin, groundCheck, MASK_SOLID, RayType_EndPoint, TraceEntityFilterPlayers, g_Honeypots[i].entity);
                bool nearGround = false;
                if (tr != null) {
                    if (TR_DidHit(tr)) {
                        nearGround = true;
                    }
                    delete tr;
                }
                if (nearGround) {
                    hpVel[2] = -10.0;
                    TeleportEntity(g_Honeypots[i].entity, NULL_VECTOR, NULL_VECTOR, hpVel);
                }
            }
        }

        if (currentTime - g_Honeypots[i].spawnTime >= honeypotLifetime) {
            CleanupHoneypot(i);
            continue;
        }

        float hpPos[3];
        float rkPos[3];
        GetEntPropVector(g_Honeypots[i].entity, Prop_Send, "m_vecOrigin", hpPos);
        GetEntPropVector(realRocketEntity, Prop_Send, "m_vecOrigin", rkPos);
        if (ShouldCleanupHoneypotForNearbyPlayers(hpPos)) {
            CleanupHoneypot(i);
            continue;
        }
        float tgPos[3];
        GetClientEyePosition(target, tgPos);
        float minDist = g_hMinSpawnDistance.FloatValue;
        float dRT = GetVectorDistance(rkPos, tgPos);
        if (dRT < minDist) {
            CleanupHoneypot(i);
            continue;
        }
        if (GetVectorDistance(hpPos, rkPos) < 60.0) {
            CleanupHoneypot(i);
            continue;
        }
    }
    // Debug visualization: draw boxes around active honeypots for admins
    for (int admin = 1; admin <= MaxClients; admin++) {
        if (!g_HpDebugDraw[admin] || !IsClientInGame(admin)) continue;
        for (int h = 0; h < MAX_ROCKETS; h++) {
            if (!g_Honeypots[h].isActive || !IsValidEntity(g_Honeypots[h].entity)) continue;
            float hpPos[3];
            GetEntPropVector(g_Honeypots[h].entity, Prop_Send, "m_vecOrigin", hpPos);
            DrawHoneypotBox(admin, hpPos);
            // Also draw a line from honeypot to its target
            float targetPos[3];
            GetClientEyePosition(g_Honeypots[h].target, targetPos);
            int color[4] = {0, 255, 0, 128};
            TE_SetupBeamPoints(hpPos, targetPos, g_HpBeamModel, g_HpBeamModel, 0, 0, 0.1, 1.0, 1.0, 1, 0.0, color, 0);
            TE_SendToClient(admin);
        }
    }


    for (int j = 0; j < MAX_ROCKETS; j++) {
        if (!g_PendingSpawns[j].active) continue;
        if (currentTime < g_PendingSpawns[j].spawnAt) continue;

        int rocketEntity = EntRefToEntIndex(g_PendingSpawns[j].rocketRef);
        int target = g_PendingSpawns[j].target;
        g_PendingSpawns[j].active = false;

        if (rocketEntity == INVALID_ENT_REFERENCE || !IsValidEntity(rocketEntity)) {
            continue;
        }
        if (!IsEligibleHoneypotTarget(target)) {
            continue;
        }
        float rocketPos[3], targetPos[3];
        GetEntPropVector(rocketEntity, Prop_Send, "m_vecOrigin", rocketPos);
        GetClientEyePosition(target, targetPos);
        float toTarget[3];
        VectorSubtract(targetPos, rocketPos, toTarget);
        float dist = NormalizeVector(toTarget, toTarget);
        float range = entryRange;
        bool outside = dist >= range;
        float lead = dist - range;

        float vel[3];
        bool hasVel = TryGetEntityAbsVelocity(rocketEntity, vel);
        float closing = 0.0;
        if (hasVel) {
            closing = DotProduct(vel, toTarget);
        }
        if (closing <= 0.0) {
            float jitter = g_hSpawnJitter.FloatValue;
            float delay = MaxFloat(0.01, jitter);
            RequeuePendingSpawn(j, rocketEntity, target, currentTime, delay);
            if (g_hDebugMode.BoolValue) {
                char nameCancel[64]; GetClientName(target, nameCancel, sizeof(nameCancel));
                PrintToServer("[HoneypotSched] Receding; requeue pending for %s (next=%.2f)", nameCancel, g_PendingSpawns[j].spawnAt);
            }
            continue;
        }

        if (!outside) {
            float sampleInterval = MaxFloat(g_hSpawnJitter.FloatValue, 0.03);
            float insideDepth = range - dist;
            if (hasVel && closing > 0.0 && insideDepth <= (closing * (sampleInterval + g_hSpawnBuffer.FloatValue + 0.02) + 12.0)) {
                float minDist = g_hMinSpawnDistance.FloatValue;
                if (dist < minDist) {
                    float jitter = g_hSpawnJitter.FloatValue;
                    float delay = MaxFloat(0.01, jitter);
                    RequeuePendingSpawn(j, rocketEntity, target, currentTime, delay);
                    if (g_hDebugMode.BoolValue) {
                        char nameMd[64]; GetClientName(target, nameMd, sizeof(nameMd));
                        PrintToServer("[HoneypotSched] Blocked by min distance inside: %.1f < %.1f for %s (next=%.2f)", dist, minDist, nameMd, g_PendingSpawns[j].spawnAt);
                    }
                    continue;
                }
                float windowStartCheck = currentTime;
                if (!CanScheduleForTarget(rocketEntity, target, windowStartCheck)) {
                    continue;
                }
                CreateInvisibleHoneypotForTarget(rocketEntity, target);
                continue;
            }
            float jitter = g_hSpawnJitter.FloatValue;
            float delay = MaxFloat(0.01, jitter);
            RequeuePendingSpawn(j, rocketEntity, target, currentTime, delay);
            if (g_hDebugMode.BoolValue) {
                char nameRqInside[64]; GetClientName(target, nameRqInside, sizeof(nameRqInside));
                PrintToServer("[HoneypotSched] Inside entry; requeue %s (next=%.2f)", nameRqInside, g_PendingSpawns[j].spawnAt);
            }
            continue;
        }

        float minLead = g_hPreEntryLead.FloatValue;
        float nearMargin = minLead;
        if (hasVel) {
            float speed = SquareRoot(DotProduct(vel, vel));
            float candidate = speed * 0.08;
            if (candidate < 48.0) {
                nearMargin = 48.0;
            } else if (candidate > minLead) {
                nearMargin = minLead;
            } else {
                nearMargin = candidate;
            }
        }
        float requiredLead = minLead;
        float sampleInterval = MaxFloat(g_hSpawnJitter.FloatValue, 0.03);
        float tLeadNow = 0.0;
        if (hasVel && closing > 0.0) {
            float speed = SquareRoot(DotProduct(vel, vel));
            float accelBuffer = (speed / 1000.0) * 0.05;  // Extra time buffer for acceleration, scales with current speed
            float effectiveThreshold = sampleInterval + g_hSpawnBuffer.FloatValue + 0.02 + accelBuffer;
            tLeadNow = MaxFloat(0.0, ((dist - range) - requiredLead) / closing);
            if (tLeadNow <= effectiveThreshold) {
            float minDist = g_hMinSpawnDistance.FloatValue;
            if (dist < minDist) {
                float jitter = g_hSpawnJitter.FloatValue;
                float delay = MaxFloat(0.01, jitter);
                RequeuePendingSpawn(j, rocketEntity, target, currentTime, delay);
                if (g_hDebugMode.BoolValue) {
                    char nameMd2[64]; GetClientName(target, nameMd2, sizeof(nameMd2));
                    PrintToServer("[HoneypotSched] Blocked by min distance outside: %.1f < %.1f for %s (next=%.2f)", dist, minDist, nameMd2, g_PendingSpawns[j].spawnAt);
                }
                continue;
            }
            float windowStartCheck = currentTime;
            if (!CanScheduleForTarget(rocketEntity, target, windowStartCheck)) {
                continue;
            }
            CreateInvisibleHoneypotForTarget(rocketEntity, target);
            continue;
        }
        }

        float jitter = g_hSpawnJitter.FloatValue;
        float delay = MaxFloat(0.01, jitter);
        RequeuePendingSpawn(j, rocketEntity, target, currentTime, delay);
        if (g_hDebugMode.BoolValue) {
            char nameRq[64]; GetClientName(target, nameRq, sizeof(nameRq));
            PrintToServer("[HoneypotSched] Lead %.1f > required %.1f (min %.1f, near %.1f); requeue %s (next=%.2f)", lead, requiredLead, minLead, nearMargin, nameRq, g_PendingSpawns[j].spawnAt);
        }
    }
}

// Create invisible honeypot for target
public void CreateInvisibleHoneypotForTarget(int realRocketEntity, int target) {
    if (g_HoneypotCount >= g_hMaxHoneypots.IntValue) return;
    if (realRocketEntity == -1 || !IsValidEntity(realRocketEntity)) return;
    if (!IsEligibleHoneypotTarget(target)) return;
    float minDist = g_hMinSpawnDistance.FloatValue;
    float rkPos[3], tgPos[3];
    GetEntPropVector(realRocketEntity, Prop_Send, "m_vecOrigin", rkPos);
    GetClientEyePosition(target, tgPos);
    float d = GetVectorDistance(rkPos, tgPos);
    if (d < minDist) {
        if (g_hDebugMode.BoolValue) {
            char nameMd4[64]; GetClientName(target, nameMd4, sizeof(nameMd4));
            PrintToServer("[BustedByDarka] Create blocked by min distance: %.1f < %.1f for %s", d, minDist, nameMd4);
        }
        return;
    }
    
    int honeypotIndex = -1;
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (!g_Honeypots[i].isActive) {
            honeypotIndex = i;
            break;
        }
    }
    
    if (honeypotIndex == -1) return;
    
    float targetPos[3], targetAngles[3], desiredPos[3], honeypotPos[3];
    GetClientEyePosition(target, targetPos);
    GetClientEyeAngles(target, targetAngles);
    CalculateHoneypotPosition(targetPos, targetAngles, desiredPos);
    if (!ResolveSafeHoneypotSpawn(target, targetPos, desiredPos, honeypotPos)) {
        if (g_hDebugMode.BoolValue) {
            char blockedName[64];
            GetClientName(target, blockedName, sizeof(blockedName));
            PrintToServer("[BustedByDarka] Skipped honeypot for %s due to unsafe geometry/player-overlap spawn", blockedName);
        }
        return;
    }
    
    int honeypotEntity = CreateEntityByName("tf_projectile_rocket");
    if (honeypotEntity == -1) return;
    
    DispatchKeyValue(honeypotEntity, "model", "");

    // CRITICAL: Set properties BEFORE spawning to prevent particle creation
    SetupHoneypotProperties(honeypotEntity, target, realRocketEntity, targetAngles);
    
    // CRITICAL FIX: Replace particle effect with invisible one BEFORE spawning
    // This prevents ANY particles from ever being created
    DispatchKeyValue(honeypotEntity, "effect_name", "");
    
    // Also hook Spawn/SpawnPost to catch any child particles
    SDKHook(honeypotEntity, SDKHook_Spawn, OnHoneypotPreSpawn);
    SDKHook(honeypotEntity, SDKHook_SpawnPost, OnHoneypotSpawnPost);
    SDKHook(honeypotEntity, SDKHook_ShouldCollide, OnHoneypotShouldCollide);
    SDKHook(honeypotEntity, SDKHook_Blocked, OnHoneypotBlocked);
    SDKHook(honeypotEntity, SDKHook_OnTakeDamage, OnHoneypotDamaged);
    SDKHook(honeypotEntity, SDKHook_StartTouch, OnHoneypotStartTouch);
    SDKHook(honeypotEntity, SDKHook_Touch, OnHoneypotPreventTouch);
    SDKHook(honeypotEntity, SDKHook_SetTransmit, OnHoneypotSetTransmit);
    
    // Set effect entity to -1 before spawn and strip any particle handles
    SetEntPropEnt(honeypotEntity, Prop_Send, "m_hEffectEntity", -1);
    
    // Mark active before DispatchSpawn so any immediate touch/sound paths can still identify this entity.
    float spawnNow = GetGameTime();
    g_Honeypots[honeypotIndex].entity = honeypotEntity;
    g_Honeypots[honeypotIndex].target = target;
    g_Honeypots[honeypotIndex].realRocketEntity = realRocketEntity;
    g_Honeypots[honeypotIndex].spawnTime = spawnNow;
    g_Honeypots[honeypotIndex].detections = 0;
    g_Honeypots[honeypotIndex].isActive = true;
    g_Honeypots[honeypotIndex].visualEntity = -1;
    g_Honeypots[honeypotIndex].visualActive = false;
    g_Honeypots[honeypotIndex].cleanupTimer = null;
    g_Honeypots[honeypotIndex].particleKillTimer = null;
    g_HoneypotCount++;
    g_Clients[target].lastTargetedTime = spawnNow;

    // Position and spawn
    TeleportEntity(honeypotEntity, honeypotPos, targetAngles, NULL_VECTOR);

    SetEntProp(honeypotEntity, Prop_Send, "m_nSolidType", 2);

    DispatchSpawn(honeypotEntity);
    if (!IsValidEntity(honeypotEntity)) {
        g_Honeypots[honeypotIndex].entity = -1;
        g_Honeypots[honeypotIndex].target = -1;
        g_Honeypots[honeypotIndex].realRocketEntity = -1;
        g_Honeypots[honeypotIndex].spawnTime = 0.0;
        g_Honeypots[honeypotIndex].detections = 0;
        g_Honeypots[honeypotIndex].isActive = false;
        g_Honeypots[honeypotIndex].visualEntity = -1;
        g_Honeypots[honeypotIndex].visualActive = false;
        if (g_HoneypotCount > 0) {
            g_HoneypotCount--;
        }
        return;
    }

    FinalizeHoneypotEntity(honeypotEntity);
    RequestFrame(Frame_EnsureHoneypotNonSolid, EntIndexToEntRef(honeypotEntity));

    if (g_hDebugCritical.BoolValue) {
        if (HasEntProp(honeypotEntity, Prop_Send, "m_bCritical")) {
            SetEntProp(honeypotEntity, Prop_Send, "m_bCritical", 1);
        }
    }
    
    // Much lighter cleanup - just in case any stragglers appear
    // Schedule cleanup
    g_Honeypots[honeypotIndex].cleanupTimer = CreateTimer(g_hHoneypotLifetime.FloatValue, CleanupHoneypotTimer, honeypotIndex, TIMER_FLAG_NO_MAPCHANGE);
    
    // Single cleanup pass on next frame just in case
    RequestFrame(Frame_KillInitialParticles, EntIndexToEntRef(honeypotEntity));
    
    if (g_hDebugMode.BoolValue) {
        char targetName[64];
        GetClientName(target, targetName, sizeof(targetName));
        float rp[3];
        GetEntPropVector(realRocketEntity, Prop_Send, "m_vecOrigin", rp);
        float d2 = GetVectorDistance(rp, tgPos);
        float vel[3];
        TryGetEntityAbsVelocity(realRocketEntity, vel);
        float speed = SquareRoot(DotProduct(vel, vel));
        PrintToServer("[BustedByDarka] Created cheat-visible honeypot %d for %s (d=%.1f, range=%.1f, speed=%.1f)", honeypotEntity, targetName, d2, g_hEntryRange.FloatValue, speed);
    }
    float pressSince = GetGameTime() - g_Clients[target].lastAttack2Time;
    if (pressSince <= 0.20) {
        DetectHoneypotInteraction(target, honeypotEntity, HoneypotDetectionSource_Command);
    }

    // Create SourceTV-only visual duplicate if enabled
    CreateSourceTVVisualForHoneypot(honeypotIndex, honeypotEntity, target, realRocketEntity);
}

// Kill particles on next frame
public void Frame_KillInitialParticles(int entityRef) {
    int honeypotEntity = EntRefToEntIndex(entityRef);
    if (honeypotEntity == INVALID_ENT_REFERENCE || !IsValidEntity(honeypotEntity)) return;
    
    ForceHoneypotInvisible(honeypotEntity);
}

public void SetupHoneypotProperties(int honeypotEntity, int target, int realRocketEntity, float targetAngles[3]) {
    int realRocketTeam = GetEntProp(realRocketEntity, Prop_Send, "m_iTeamNum");
    // bool isCritical = GetEntProp(realRocketEntity, Prop_Send, "m_bCritical") != 0;
    
    // Prevent any critical visuals that would spawn extra particles.
    SetEntProp(honeypotEntity, Prop_Send, "m_bCritical", 0);
    SetEntProp(honeypotEntity, Prop_Send, "m_iTeamNum", realRocketTeam, 1);
    SetEntProp(honeypotEntity, Prop_Send, "m_nSkin", (view_as<TFTeam>(realRocketTeam) == TFTeam_Blue) ? 0 : 1);
    SetEntProp(honeypotEntity, Prop_Send, "m_iDeflected", 0);
    int weapon = GetPlayerWeaponSlot(target, TFWeaponSlot_Primary);
    SetEntPropEnt(honeypotEntity, Prop_Send, "m_hOwnerEntity", target);
    SetEntPropEnt(honeypotEntity, Prop_Send, "m_hOriginalLauncher", weapon == -1 ? honeypotEntity : weapon);
    SetEntPropEnt(honeypotEntity, Prop_Send, "m_hLauncher", weapon == -1 ? honeypotEntity : weapon);
    // (review F18) removed: an early m_takedamage=1 write superseded below,
    // and a raw FindSendPropInfo+4 offset write that assumed m_flDamage layout;
    // the named-prop writes below cover both.

    if (HasEntProp(honeypotEntity, Prop_Send, "m_hRocketTrail")) {
        SetEntPropEnt(honeypotEntity, Prop_Send, "m_hRocketTrail", -1);
    }
    if (HasEntProp(honeypotEntity, Prop_Data, "m_hRocketTrail")) {
        SetEntPropEnt(honeypotEntity, Prop_Data, "m_hRocketTrail", -1);
    }
 
    SetEntProp(honeypotEntity, Prop_Data, "m_takedamage", 2); // DAMAGE_YES
    SetEntProp(honeypotEntity, Prop_Data, "m_iHealth", 1);
    SetEntProp(honeypotEntity, Prop_Data, "m_iMaxHealth", 1);
    
    if (HasEntProp(honeypotEntity, Prop_Send, "m_flDamage")) {
        SetEntPropFloat(honeypotEntity, Prop_Send, "m_flDamage", 0.0);
    }
    if (HasEntProp(honeypotEntity, Prop_Data, "m_flDamage")) {
        SetEntPropFloat(honeypotEntity, Prop_Data, "m_flDamage", 0.0);
    }
    if (HasEntProp(honeypotEntity, Prop_Send, "m_iDamage")) {
        SetEntProp(honeypotEntity, Prop_Send, "m_iDamage", 0);
    }
    if (HasEntProp(honeypotEntity, Prop_Data, "m_iDamage")) {
        SetEntProp(honeypotEntity, Prop_Data, "m_iDamage", 0);
    }
    
    SetEntProp(honeypotEntity, Prop_Data, "m_CollisionGroup", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_CollisionGroup")) {
        SetEntProp(honeypotEntity, Prop_Send, "m_CollisionGroup", 0);
    }
    
    EnsureHoneypotNonSolid(honeypotEntity);
    ClearHoneypotTrailHandles(honeypotEntity);
 
    // Configurable velocity
    float velocity[3];
    CalculateHoneypotVelocity(targetAngles, velocity);
    // If initial Z velocity points strongly downward and we are close to ground, soften it
    if (velocity[2] < -100.0) {
        float pos[3]; GetEntPropVector(honeypotEntity, Prop_Send, "m_vecOrigin", pos);
        float down[3]; down[0] = pos[0]; down[1] = pos[1]; down[2] = pos[2] - 64.0;
        Handle tr = TR_TraceRayFilterEx(pos, down, MASK_SOLID, RayType_EndPoint, TraceEntityFilterPlayers, honeypotEntity);
        bool nearGround = false;
        if (tr != null) { if (TR_DidHit(tr)) nearGround = true; delete tr; }
        if (nearGround) {
            velocity[2] = -10.0;
        }
    }
    TeleportEntity(honeypotEntity, NULL_VECTOR, NULL_VECTOR, velocity);
    
    ForceHoneypotInvisible(honeypotEntity);
    SetEntProp(honeypotEntity, Prop_Send, "m_bSimulatedEveryTick", true);
}

// Create a visual-only rocket that is transmitted only to SourceTV.
// It follows the honeypot entity and renders with crit trail on SourceTV demos.
public void CreateSourceTVVisualForHoneypot(int honeypotIndex, int honeypotEntity, int target, int realRocketEntity)
{
    if (!g_hSourceTVEnable.BoolValue || !g_hSourceTVVisuals.BoolValue)
        return;

    // Find a SourceTV client
    int tvClient = -1;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i) && IsClientSourceTV(i)) {
            tvClient = i;
            break;
        }
    }
    if (tvClient == -1)
        return;

    int visual = CreateEntityByName("tf_projectile_rocket");
    if (visual == -1)
        return;

    char modelPath[PLATFORM_MAX_PATH];
    GetConVarString(g_hSourceTVVisualModel, modelPath, sizeof(modelPath));
    if (modelPath[0] == '\0') {
        // Fallback to default TF2 rocket model
        strcopy(modelPath, sizeof(modelPath), "models/weapons/w_models/w_rocket.mdl");
    }
    PrecacheModel(modelPath);
    DispatchKeyValue(visual, "model", modelPath);

    // Basic properties to keep it non-interactive
    int realRocketTeam = GetEntProp(realRocketEntity, Prop_Send, "m_iTeamNum");
    SetEntProp(visual, Prop_Send, "m_iTeamNum", realRocketTeam, 1);
    SetEntProp(visual, Prop_Send, "m_nSkin", (view_as<TFTeam>(realRocketTeam) == TFTeam_Blue) ? 0 : 1);
    SetEntProp(visual, Prop_Send, "m_iDeflected", 0);
    SetEntPropEnt(visual, Prop_Send, "m_hOwnerEntity", target);
    SetEntProp(visual, Prop_Data, "m_takedamage", 0); // DAMAGE_NO
    SetEntProp(visual, Prop_Data, "m_iHealth", 1);
    SetEntProp(visual, Prop_Data, "m_iMaxHealth", 1);

    // Critical visual toggle
    int crit = g_hSourceTVVisualCrit.BoolValue ? 1 : 0;
    SetEntProp(visual, Prop_Send, "m_bCritical", crit);

    // Non-solid and no world collisions
    EnsureHoneypotNonSolid(visual);
    SetEntProp(visual, Prop_Send, "m_nSolidType", 2);

    // Position it initially at the honeypot
    float hpPos[3]; float hpAng[3];
    GetEntPropVector(honeypotEntity, Prop_Send, "m_vecOrigin", hpPos);
    GetEntPropVector(honeypotEntity, Prop_Send, "m_angRotation", hpAng);
    TeleportEntity(visual, hpPos, hpAng, NULL_VECTOR);
    DispatchSpawn(visual);

    // Follow the honeypot
    if (HasEntProp(visual, Prop_Send, "m_hMoveParent")) {
        SetEntPropEnt(visual, Prop_Send, "m_hMoveParent", honeypotEntity);
    }

    // Only transmit to SourceTV
    SDKHook(visual, SDKHook_SetTransmit, OnSourceTVVisualSetTransmit);

    g_Honeypots[honeypotIndex].visualEntity = visual;
    g_Honeypots[honeypotIndex].visualActive = true;
}

public void CalculateHoneypotPosition(float targetPos[3], float targetAngles[3], float outPos[3]) {
    outPos[0] = targetPos[0];
    outPos[1] = targetPos[1];
    outPos[2] = targetPos[2];
    
    float autoFov = g_hAutoFovDeg.FloatValue;
    float offsetDeg = GetRandomFloat(autoFov * 0.4, autoFov * 0.6);  // Reduced for lower FOV offset
    if (GetRandomInt(0, 1) == 0) offsetDeg = -offsetDeg;
    float yawRadians = (targetAngles[1] + offsetDeg) * 3.14159 / 180.0;
    float pitchRadians = -targetAngles[0] * 3.14159 / 180.0;
    
    float radius = g_hLegitRange.FloatValue;  // Use cvar-controlled legit range for spawn distance
    float mult = GetRandomFloat(0.85, 0.95);  // Bias towards slightly closer
    outPos[0] += Cosine(pitchRadians) * Cosine(yawRadians) * radius * mult;
    outPos[1] += Cosine(pitchRadians) * Sine(yawRadians) * radius * mult;
    outPos[2] += Sine(pitchRadians) * radius * mult;

    outPos[0] += GetRandomFloat(-8.0, 8.0);
    outPos[1] += GetRandomFloat(-8.0, 8.0);
    outPos[2] += GetRandomFloat(-4.0, 4.0);

    // Ensure ground clearance: if the computed position is at or below ground, lift it
    float down[3];
    down[0] = outPos[0];
    down[1] = outPos[1];
    down[2] = outPos[2] - 128.0;
    Handle tr = TR_TraceRayFilterEx(outPos, down, MASK_SOLID, RayType_EndPoint, TraceEntityFilterPlayers, 0);
    if (tr != null) {
        if (TR_DidHit(tr)) {
            float hit[3]; TR_GetEndPosition(hit, tr);
            float clearance = g_hGroundClearance.FloatValue;
            if (outPos[2] <= hit[2] + clearance) {
                outPos[2] = hit[2] + clearance;
            }
        }
        delete tr;
    }

    // Also avoid spawning far below the player's eye level
    if (outPos[2] < (targetPos[2] - 32.0)) {
        outPos[2] = targetPos[2] - 32.0;
    }
}

stock void CalculateHoneypotVelocity(float targetAngles[3], float outVelocity[3]) {
    float speed = g_hHoneypotSpeed.FloatValue;
    if (speed < 1.0) {
        speed = 1.0;
    }
    
    float pitchRadians = targetAngles[0] * 3.14159 / 180.0;
    float yawRadians = targetAngles[1] * 3.14159 / 180.0;
    
    outVelocity[0] = Cosine(pitchRadians) * Cosine(yawRadians) * speed;
    outVelocity[1] = Cosine(pitchRadians) * Sine(yawRadians) * speed;
    outVelocity[2] = Sine(pitchRadians) * speed;
}

stock void ScheduleHoneypotSpawn(int rocketEntity, int target) {
    if (!IsValidEntity(rocketEntity) || !IsEligibleHoneypotTarget(target)) {
        return;
    }

    float now = GetGameTime();

    float jitter = g_hSpawnJitter.FloatValue;
    float spawnDelay = MaxFloat(jitter, 0.02);
    if (spawnDelay > 0.05) {
        spawnDelay = 0.05;
    }

    float rkPos[3], tgPos[3];
    GetEntPropVector(rocketEntity, Prop_Send, "m_vecOrigin", rkPos);
    GetClientEyePosition(target, tgPos);
    float minDist = g_hMinSpawnDistance.FloatValue;
    float d = GetVectorDistance(rkPos, tgPos);
    if (d < minDist) {
        if (g_hDebugMode.BoolValue) {
            char nameMd3[64]; GetClientName(target, nameMd3, sizeof(nameMd3));
            PrintToServer("[HoneypotSched] Schedule blocked by min distance: %.1f < %.1f for %s", d, minDist, nameMd3);
        }
        return;
    }

    float windowStart = now + spawnDelay;
    if (!CanScheduleForTarget(rocketEntity, target, windowStart)) {
        return;
    }

    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (g_Honeypots[i].isActive && g_Honeypots[i].target == target) {
            return;
        }
    }
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (g_PendingSpawns[i].active && g_PendingSpawns[i].target == target) {
            return;
        }
    }

    int idx = -1;
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (!g_PendingSpawns[i].active) {
            idx = i;
            break;
        }
    }
    if (idx == -1) {
        return;
    }
    g_PendingSpawns[idx].rocketRef = EntIndexToEntRef(rocketEntity);
    g_PendingSpawns[idx].target = target;
    g_PendingSpawns[idx].spawnAt = GetGameTime() + spawnDelay + GetRandomFloat(0.0, jitter);
    g_PendingSpawns[idx].active = true;
    if (g_hDebugMode.BoolValue) {
        char targetName[64];
        GetClientName(target, targetName, sizeof(targetName));
        PrintToServer("[HoneypotSched] Pending spawn for %s in %.2fs (spawnAt=%.2f)", targetName, spawnDelay, g_PendingSpawns[idx].spawnAt);
    }
}

stock void CancelPendingSpawnFor(int rocketEntity, int target)
{
    for (int i = 0; i < MAX_ROCKETS; i++)
    {
        if (!g_PendingSpawns[i].active) continue;
        int refEnt = EntRefToEntIndex(g_PendingSpawns[i].rocketRef);
        if (refEnt == rocketEntity && g_PendingSpawns[i].target == target)
        {
            g_PendingSpawns[i].active = false;
        }
    }
}

public Action DelayedCleanupHoneypot(Handle timer, any honeypotIndex) {
    CleanupHoneypot(honeypotIndex);
    return Plugin_Stop;
}

public Action CleanupHoneypotTimer(Handle timer, any honeypotIndex) {
    CleanupHoneypot(honeypotIndex);
    return Plugin_Stop;
}

public void CleanupHoneypot(int honeypotIndex) {
    if (honeypotIndex < 0 || honeypotIndex >= MAX_ROCKETS) return;
    if (!g_Honeypots[honeypotIndex].isActive) return;
    
    int entity = g_Honeypots[honeypotIndex].entity;
    if (IsValidEntity(entity)) {
        SuppressHoneypotEffects(entity, 0.50);
        SDKUnhook(entity, SDKHook_OnTakeDamage, OnHoneypotDamaged);
        SDKUnhook(entity, SDKHook_StartTouch, OnHoneypotStartTouch);
        SDKUnhook(entity, SDKHook_Touch, OnHoneypotPreventTouch);
        SDKUnhook(entity, SDKHook_ShouldCollide, OnHoneypotShouldCollide);
        SDKUnhook(entity, SDKHook_Blocked, OnHoneypotBlocked);
        SDKUnhook(entity, SDKHook_SetTransmit, OnHoneypotSetTransmit);
        SDKUnhook(entity, SDKHook_SpawnPost, OnHoneypotSpawnPost);
        SDKUnhook(entity, SDKHook_Spawn, OnHoneypotPreSpawn);
        RemoveEntity(entity);
    }

    // Remove SourceTV visual duplicate if present
    int visual = g_Honeypots[honeypotIndex].visualEntity;
    if (visual > 0 && IsValidEntity(visual)) {
        SuppressHoneypotEffects(visual, 0.50);
        SDKUnhook(visual, SDKHook_SetTransmit, OnSourceTVVisualSetTransmit);
        RemoveEntity(visual);
    }
    
    if (g_Honeypots[honeypotIndex].cleanupTimer != null) {
        KillTimer(g_Honeypots[honeypotIndex].cleanupTimer);
        g_Honeypots[honeypotIndex].cleanupTimer = null;
    }
    
    if (g_Honeypots[honeypotIndex].particleKillTimer != null) {
        KillTimer(g_Honeypots[honeypotIndex].particleKillTimer);
        g_Honeypots[honeypotIndex].particleKillTimer = null;
    }
    
    g_Honeypots[honeypotIndex].entity = -1;
    g_Honeypots[honeypotIndex].target = -1;
    g_Honeypots[honeypotIndex].realRocketEntity = -1;
    g_Honeypots[honeypotIndex].visualEntity = -1;
    g_Honeypots[honeypotIndex].spawnTime = 0.0;
    g_Honeypots[honeypotIndex].detections = 0;
    g_Honeypots[honeypotIndex].isActive = false;
    g_Honeypots[honeypotIndex].visualActive = false;
    
    g_HoneypotCount--;
}
