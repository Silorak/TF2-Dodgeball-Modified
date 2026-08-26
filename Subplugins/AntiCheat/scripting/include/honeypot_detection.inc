#if defined _honeypot_detection_included
  #endinput
#endif
#define _honeypot_detection_included
// Honeypot interaction detection and scoring (airblast timing, facing, cadence).


#include "honeypot_entities.inc"
#include "honeypot_utils.inc"

// ===================== Detection Logic =====================

// Command/touch/generic detection removed. We only detect via damage.

stock void NotifyAdminsOfHoneypotDetection(int suspect, float weight, bool thresholdCrossed)
{
    if (!g_hAdminAlerts.BoolValue) return;

    char name[64];
    char steamId[64];
    GetClientName(suspect, name, sizeof(name));
    GetClientAuthId(suspect, AuthId_SteamID64, steamId, sizeof(steamId), true);
    float score = g_Clients[suspect].detectionScore;
    float threshold = g_hScoreThreshold.FloatValue;

    for (int admin = 1; admin <= MaxClients; admin++)
    {
        if (!IsClientInGame(admin) || IsFakeClient(admin)) continue;
        if (!CheckCommandAccess(admin, "tfdb_honeypot_admin_alert", ADMFLAG_GENERIC, true)) continue;

        if (thresholdCrossed)
        {
            PrintToChat(admin, "FF4444[TFDB AC] %t", "Honeypot_AdminThreshold", name, score, threshold);
            PrintToConsole(admin, "%T", "Honeypot_AdminThresholdConsole", admin, name, steamId, score, threshold, weight);
        }
        else
        {
            PrintToChat(admin, "[TFDB AC] %t", "Honeypot_AdminHit", name, score, threshold);
            PrintToConsole(admin, "%T", "Honeypot_AdminHitConsole", admin, name, steamId, score, threshold, weight);
        }
    }
}

// ============================================================================
//  DetectHoneypotInteraction - the detection pipeline (read this first)
// ============================================================================
//
//  WHAT HAPPENS WHEN A PLAYER HITS THE HONEYPOT:
//
//  Phase 1 - CONTEXT (compute 3 groups of variables):
//    A. Targeting metrics:  dotHP (facing honeypot?), dotRK (facing real?),
//                          hpDist / rkDist (which is closer?), closing (real rocket
//                          approaching or retreating?)
//    B. Timing metrics:    rtHp (reaction time to honeypot), rtEntry (reaction to
//                          real rocket entering range), hpMean/hpStd (consistency),
//                          cadenceMatch (is the airblast cadence automated?)
//    C. Input metrics:     mouseDeg (total mouse movement in window), flickNow
//                          (large flick = real aim), pingMs (lag compensation)
//
//  Phase 2 - LEGITIMACY FILTER (if ANY condition is true → cleanup, no score):
//    - legitNow:  a real rocket is nearby, in front, unobstructed, and closer
//                 than the honeypot → player was aiming at the real thing
//    - flickNow:  large mouse movement in the last N ms → real airblast aim
//    - realFar + realAway: real rocket is far AND moving away → no reason to
//                          airblast toward the honeypot's direction
//
//  Phase 3 - SCORE (if all three legitimacy checks fail):
//    weight = 1.5 (damage) × speedMult × pingReduction
//    detectionScore += weight  (one-way: only goes up, decays via OnGameFrame)
//    If score crosses threshold → admin alert / kick / warn
//
// ============================================================================

public void DetectHoneypotInteraction(int client, int honeypotEntity, HoneypotDetectionSource source) {
    if (!g_hEnabled.BoolValue || !g_HoneypotsActive) {
        return;
    }
    if (source != HoneypotDetectionSource_Damage) {
        return;
    }
    int honeypotIndex = -1;
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (g_Honeypots[i].isActive && g_Honeypots[i].entity == honeypotEntity) {
            honeypotIndex = i;
            break;
        }
    }
    
    if (honeypotIndex == -1) return;
    if (!IsValidClientEx(client, true)) return;
    int target = g_Honeypots[honeypotIndex].target;
    if (client != target) return;
    float now = GetGameTime();
    
    // Compute context metrics first
    g_Honeypots[honeypotIndex].detections++;
    g_Clients[client].honeypotDetections++;
    float weight = GetDetectionWeight(source);
    float speedMult = GetSpeedWeightMultiplier(client, now);
    weight *= speedMult;

    // Ping-based weight reduction: high-ping players have inherent server
    // desync - their airblast may land at a stale position, hitting the
    // honeypot instead of the real rocket they were aiming at. This is not
    // cheating; it's latency. Scale weight down proportionally above 100ms.
    // At 100ms: full weight. At 200ms: 75%. At 300ms: 50%. At 400ms+: 25%.
    float pingMs = GetClientPingMs(client);
    if (pingMs > 100.0)
    {
        float pingReduction = 1.0 - ((pingMs - 100.0) / 400.0) * 0.75;
        if (pingReduction < 0.25) pingReduction = 0.25;
        weight *= pingReduction;
    }
    float distAdd = 0.0;
    float reactAdd = 0.0;
    float fastAddVar = 0.0;
    float consAddVar = 0.0;
    float rkSpeed = -1.0;
    float hpSpeed = -1.0;
    int realEnt = g_Honeypots[honeypotIndex].realRocketEntity;
    float v[3];
    if (IsValidEntity(realEnt) && TryGetEntityAbsVelocity(realEnt, v)) {
        rkSpeed = SquareRoot(DotProduct(v, v));
    }
    if (TryGetEntityAbsVelocity(honeypotEntity, v)) {
        hpSpeed = SquareRoot(DotProduct(v, v));
    }

    float eye[3], ang[3], fwd[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);
    float hpPos[3], toHP[3];
    GetEntPropVector(honeypotEntity, Prop_Send, "m_vecOrigin", hpPos);
    VectorSubtract(hpPos, eye, toHP);
    float hpDist = NormalizeVector(toHP, toHP);
    float dotHP = DotProduct(fwd, toHP);
    float rkPos[3], toRK[3];
    GetEntPropVector(realEnt, Prop_Send, "m_vecOrigin", rkPos);
    VectorSubtract(rkPos, eye, toRK);
    float rkDist = NormalizeVector(toRK, toRK);
    float dotRK = DotProduct(fwd, toRK);
    float closing = 0.0;
    if (IsValidEntity(realEnt) && TryGetEntityAbsVelocity(realEnt, v)) {
        closing = DotProduct(v, toRK);
    }
    pingMs = GetClientPingMs(client);
    int nearPyros = 0;
    float radius = g_hMultiPyroRadius.FloatValue;
    float eyeT[3];
    GetClientEyePosition(client, eyeT);
    for (int pi = 1; pi <= MaxClients; pi++) {
        if (pi == client) continue;
        if (!IsValidClientEx(pi, true)) continue;
        if (TF2_GetPlayerClass(pi) != TFClass_Pyro) continue;
        float eye2[3];
        GetClientEyePosition(pi, eye2);
        float d2 = GetVectorDistance(eye2, eyeT);
        if (d2 <= radius) nearPyros++;
    }
    int realCrit = 0;
    if (HasEntProp(realEnt, Prop_Send, "m_bCritical")) {
        realCrit = GetEntProp(realEnt, Prop_Send, "m_bCritical");
    }
    float rtHp = now - g_Honeypots[honeypotIndex].spawnTime;
    int idxHp = g_HpReactionCounts[client] % 10;
    g_HpReactionTimes[client][idxHp] = rtHp;
    g_HpReactionCounts[client]++;
    int nHp = g_HpReactionCounts[client] < 10 ? g_HpReactionCounts[client] : 10;
    float hpMean = -1.0;
    float hpStd = -1.0;
    if (nHp >= 1) {
        float sum = 0.0;
        for (int i = 0; i < nHp; i++) sum += g_HpReactionTimes[client][i];
        hpMean = sum / float(nHp);
        float varianceHp = 0.0;
        for (int j = 0; j < nHp; j++) { float d = g_HpReactionTimes[client][j] - hpMean; varianceHp += d * d; }
        varianceHp /= float(nHp);
        hpStd = SquareRoot(varianceHp);
    }
    float rtEntry = -1.0;
    float entryMean = -1.0;
    float entryStd = -1.0;
    if (g_LastEntryCrossTime[client] > 0.0) {
        rtEntry = now - g_LastEntryCrossTime[client];
        int idx = g_ReactionCounts[client] % 10;
        g_ReactionTimes[client][idx] = rtEntry;
        g_ReactionCounts[client]++;
        int n = g_ReactionCounts[client] < 10 ? g_ReactionCounts[client] : 10;
        float mean = 0.0;
        for (int k = 0; k < n; k++) mean += g_ReactionTimes[client][k];
        mean /= float(n);
        float variance = 0.0;
        for (int m = 0; m < n; m++) { float d2 = g_ReactionTimes[client][m] - mean; variance += d2 * d2; }
        variance /= float(n);
        entryMean = mean;
        entryStd = SquareRoot(variance);
    }
    bool cadenceMatch = IsAutoAirblastPattern(client);

    bool legitNow = IsLegitAirblastContext(client, honeypotEntity);
    float sinceAttack = now - g_Clients[client].lastAttack2Time;
    float window = g_hMouseWindow.FloatValue;
    float t0 = now - window;
    float mouseDeg = 0.0;
    for (int mi = 0; mi < 20; mi++) {
        float ts = g_MouseDegTimes[client][mi];
        if (ts > 0.0 && ts >= t0) {
            mouseDeg += g_MouseDegMag[client][mi];
        }
    }
    bool flickNow = (mouseDeg >= g_hMouseFlickDeg.FloatValue);
    bool realFar = (rkDist >= g_hRealFar.FloatValue);
    bool realAway = (closing <= -g_hClosingAway.FloatValue);
    if (legitNow || flickNow || (realFar && realAway)) {
        CreateTimer(0.1, DelayedCleanupHoneypot, honeypotIndex);
        return;
    }

    float previousScore = g_Clients[client].detectionScore;
    g_Clients[client].detectionScore += weight;
    if (weight >= 1.0) {
        g_Clients[client].consecutiveDetections++;
    }
    g_Clients[client].lastDetectionTime = now;

    LogDetectionToFile(client, honeypotEntity, source, weight, g_Clients[client].lastPressRocketDist, g_hPressScoreDistMin.FloatValue, dotHP, legitNow, speedMult, distAdd, reactAdd, fastAddVar, consAddVar, rtHp, sinceAttack, rkSpeed, hpSpeed, dotRK, hpDist, rkDist, closing, pingMs, nearPyros, realCrit, hpMean, hpStd, entryMean, entryStd, cadenceMatch ? 1 : 0, mouseDeg, flickNow ? 1 : 0);

    
    char clientName[64];
    GetClientName(client, clientName, sizeof(clientName));
    
    if (source == HoneypotDetectionSource_Damage) {
        LogMessage("[BustedByDarka] Airblast detection: %s airblasted honeypot %d", clientName, honeypotEntity);
    }
    
    bool thresholdCrossed = previousScore < g_hScoreThreshold.FloatValue
        && g_Clients[client].detectionScore >= g_hScoreThreshold.FloatValue;
    NotifyAdminsOfHoneypotDetection(client, weight, thresholdCrossed);
    ProcessDetectionThreshold(client);

    char bookmarkReason[128];
    Format(bookmarkReason, sizeof(bookmarkReason), "Score %.2f", 
            g_Clients[client].detectionScore);
    AddSourceTVBookmark(client, bookmarkReason);

    // Cleanup after detection
    CreateTimer(0.1, DelayedCleanupHoneypot, honeypotIndex);

    int real = g_Honeypots[honeypotIndex].realRocketEntity;
    if (IsValidEntity(real) && IsEligibleHoneypotTarget(target)) {
        ScheduleHoneypotSpawn(real, target);
    }
}

public void ProcessDetectionThreshold(int client) {
    float scoreThreshold = g_hScoreThreshold.FloatValue;
    bool exceeded = (g_Clients[client].detectionScore >= scoreThreshold);
    if (exceeded) {
        char clientName[64];
        GetClientName(client, clientName, sizeof(clientName));
        
        PrintToServer("[BustedByDarka] THRESHOLD EXCEEDED: %s (score %.2f)", 
                     clientName, g_Clients[client].detectionScore);
        
        if (g_hPunishEnable.BoolValue) {
            if (g_Clients[client].detectionScore >= scoreThreshold * 1.5) {
                char kickReason[128];
                Format(kickReason, sizeof(kickReason), 
                       "BustedByDarka: You've been naughty (score %.2f)", 
                       g_Clients[client].detectionScore);
                
                // Add kick bookmark
                AddSourceTVBookmark(client, "KICKED for cheating");
                
                KickClient(client, kickReason);
                
                PrintToServer("[BustedByDarka] KICKED %s (score %.2f)", 
                             clientName, g_Clients[client].detectionScore);
            } else {
                PrintToChat(client, "\x07FF4444[BustedByDarka]\x07FFFFFF Warning: Suspicious gameplay detected.");
                PrintToServer("[BustedByDarka] WARNED %s (score %.2f)", 
                             clientName, g_Clients[client].detectionScore);
            }
        }
    }
}

static float GetDetectionWeight(HoneypotDetectionSource source) {
    if (source == HoneypotDetectionSource_Damage) return 1.5;
    if (source == HoneypotDetectionSource_Command) return 1.0;
    if (source == HoneypotDetectionSource_Touch) return 0.5;
    return 0.75;
}

static float GetSpeedWeightMultiplier(int client, float now) {
    float since = now - g_Clients[client].lastAttack2Time;
    float fast = g_hSpeedFast.FloatValue;
    float slow = g_hSpeedSlow.FloatValue;
    if (since <= fast) {
        return g_hSpeedFastMult.FloatValue;
    }
    if (since >= slow) {
        return g_hSpeedSlowMult.FloatValue;
    }
    return 1.0;
}

static bool IsAutoAirblastPattern(int client) {
    float min = g_hAutoPressMin.FloatValue;
    float max = g_hAutoPressMax.FloatValue;
    float jit = g_hAutoPressJitter.FloatValue;
    int req = g_hAutoPressRequired.IntValue;
    float t0 = g_PressTimes[client][0];
    float t1 = g_PressTimes[client][1];
    float t2 = g_PressTimes[client][2];
    float t3 = g_PressTimes[client][3];
    int count = 0;
    if (t1 > 0.0) {
        float d01 = t0 - t1;
        if (d01 >= min && d01 <= max) count++;
    }
    if (t2 > 0.0) {
        float d12 = t1 - t2;
        if (d12 >= min && d12 <= max && (t1 <= 0.0 || AbsFloat((t0 - t1) - d12) <= jit)) count++;
    }
    if (t3 > 0.0) {
        float d23 = t2 - t3;
        if (d23 >= min && d23 <= max && AbsFloat(d23 - (t1 - t2)) <= jit) count++;
    }
    return count >= req;
}

static bool IsLegitAirblastContext(int client, int honeypotEntity) {
    float eye[3], ang[3], fwd[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(fwd, fwd);

    float hpPos[3], toHP[3];
    GetEntPropVector(honeypotEntity, Prop_Send, "m_vecOrigin", hpPos);
    VectorSubtract(hpPos, eye, toHP);
    float hpDist = NormalizeVector(toHP, toHP);

    float legitDot = g_hLegitDot.FloatValue;
    float legitRange = g_hLegitRange.FloatValue;

    int maxEntities = GetMaxEntities();
    for (int entity = MaxClients + 1; entity < maxEntities; entity++) {
        if (!IsValidEntity(entity) || entity == honeypotEntity) continue;
        char classname[64];
        if (!GetEntityClassname(entity, classname, sizeof(classname))) continue;
        if (!StrEqual(classname, "tf_projectile_rocket")) continue;

        float rkPos[3], toRK[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", rkPos);
        VectorSubtract(rkPos, eye, toRK);
        float rkDist = NormalizeVector(toRK, toRK);
        if (rkDist > legitRange) continue;
        float dot = DotProduct(fwd, toRK);
        if (dot < legitDot) continue;

        g_LegitTraceIgnoreClient = client;
        g_LegitTraceIgnoreEntity = honeypotEntity;
        Handle trace = TR_TraceRayFilterEx(eye, rkPos, MASK_SOLID, RayType_EndPoint, TraceEntityFilterLegit, 0);
        bool obstructed = false;
        if (trace != null) {
            if (TR_DidHit(trace)) {
                float fraction = TR_GetFraction(trace);
                if (fraction < 0.999) obstructed = true;
            }
            delete trace;
        }
        if (obstructed) continue;

        float near = g_hLegitNear.FloatValue;
        if (rkDist <= hpDist + near) {
            return true;
        }
    }
    return false;
}

static void LogDetectionToFile(int client, int honeypotEntity, HoneypotDetectionSource source, float weight, float pressDist, float distMin, float dotHP, bool legitContext, float speedMult, float distAdd, float reactAdd, float fastAdd, float consAdd, float rtHp, float sinceAttack, float rkSpeed, float hpSpeed, float dotRK, float hpDist, float rkDist, float closing, float pingMs, int nearPyros, int realCrit, float hpMean, float hpStd, float entryMean, float entryStd, int cadence, float mouseDeg, int flick)
{
    if (!g_hLogEnable.BoolValue) return;
    char fileName[64];
    GetConVarString(g_hLogFile, fileName, sizeof(fileName));
    if (fileName[0] == '\0') {
        strcopy(fileName, sizeof(fileName), "honeypot_detections.log");
    }
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "logs/%s", fileName);
    char name[64];
    GetClientName(client, name, sizeof(name));
    char steam[64];
    GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam), true);
    char src[16];
    switch (source) {
        case HoneypotDetectionSource_Command: {
            strcopy(src, sizeof(src), "command");
        }
        case HoneypotDetectionSource_Damage: {
            strcopy(src, sizeof(src), "damage");
        }
        case HoneypotDetectionSource_Touch: {
            strcopy(src, sizeof(src), "touch");
        }
        default: {
            strcopy(src, sizeof(src), "generic");
        }
    }
    char ts[64];
    FormatTime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", GetTime());
    float score = g_Clients[client].detectionScore;
    Handle f = OpenFile(path, "a");
    if (f != null) {
        WriteFileLine(f, "[%s] client=%s steam=%s source=%s hp=%d weight=%.2f score=%.2f press=%.1f distMin=%.1f dotHP=%.3f dotRK=%.3f legit=%d speedMult=%.2f distAdd=%.2f reactAdd=%.2f fastAdd=%.2f consAdd=%.2f rtHp=%.3f sinceAttack=%.3f rkSpeed=%.1f hpSpeed=%.1f hpDist=%.1f rkDist=%.1f closing=%.1f ping=%.1f nearPyros=%d realCrit=%d hpMean=%.3f hpStd=%.3f entryMean=%.3f entryStd=%.3f cadence=%d mouseDeg=%.1f flick=%d", ts, name, steam, src, honeypotEntity, weight, score, pressDist, distMin, dotHP, dotRK, legitContext ? 1 : 0, speedMult, distAdd, reactAdd, fastAdd, consAdd, rtHp, sinceAttack, rkSpeed, hpSpeed, hpDist, rkDist, closing, pingMs, nearPyros, realCrit, hpMean, hpStd, entryMean, entryStd, cadence, mouseDeg, flick);
        CloseHandle(f);
    }
}
