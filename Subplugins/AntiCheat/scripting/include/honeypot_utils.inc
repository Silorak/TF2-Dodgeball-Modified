#if defined _honeypot_utils_included
  #endinput
#endif
#define _honeypot_utils_included
// Shared honeypot utilities (trail clearing, SourceTV availability checks, recording bookmarks).


#include "honeypot_entities.inc"

// SourceTV Manager enriches recordings/bookmarks but must never be required
// for the honeypot detector itself. core.inc defines REQUIRE_EXTENSIONS by
// default, so temporarily clear it while importing this extension's natives.
#if defined REQUIRE_EXTENSIONS
  #define TFDB_RESTORE_REQUIRE_EXTENSIONS
  #undef REQUIRE_EXTENSIONS
#endif
#include <sourcetvmanager>
#if defined TFDB_RESTORE_REQUIRE_EXTENSIONS
  #define REQUIRE_EXTENSIONS
  #undef TFDB_RESTORE_REQUIRE_EXTENSIONS
#endif

// ===================== Helper Utilities =====================
stock bool IsValidClientEx(int client, bool alive = false) {
    return client >= 1 &&
           client <= MaxClients &&
           IsClientInGame(client) &&
           (!alive || IsPlayerAlive(client));
}

stock float CalculateRocketDamage(float modifier) {
    return 100.0 + (10.0 * modifier);
}

stock float MaxFloat(float a, float b) {
    return (a > b) ? a : b;
}

stock float AbsFloat(float x) {
    return x < 0.0 ? -x : x;
}

stock bool IsEligibleHoneypotTarget(int client) {
    if (!IsValidClientEx(client, true)) {
        return false;
    }

    if (!g_hAllowBotTargets.BoolValue && IsFakeClient(client)) {
        return false;
    }

    return true;
}

public bool TraceEntityFilterLegit(int entity, int contentsMask, int data) {
    if (entity == g_LegitTraceIgnoreClient) {
        return false;
    }
    if (entity >= 1 && entity <= MaxClients) {
        return false;
    }
    if (entity == g_LegitTraceIgnoreEntity) {
        return false;
    }
    return true;
}

public bool TraceEntityFilterPlayers(int entity, int contentsMask, int data) {
    if (entity == data) {
        return false;
    }
    
    if (entity >= 1 && entity <= MaxClients) {
        return false;
    }
    
    return true;
}

stock void SuppressHoneypotEffects(int entity, float duration = 0.35)
{
    if (entity <= MaxClients || entity <= 0) {
        return;
    }

    float now = GetGameTime();
    float until = now + duration;
    int ref = IsValidEntity(entity) ? EntIndexToEntRef(entity) : INVALID_ENT_REFERENCE;
    int best = 0;
    float oldest = g_SuppressedHoneypotUntil[0];

    for (int i = 0; i < HONEYPOT_SUPPRESS_SLOTS; i++) {
        if (g_SuppressedHoneypotUntil[i] <= now) {
            best = i;
            oldest = -1.0;
            break;
        }
        if (g_SuppressedHoneypotEnts[i] == entity || (ref != INVALID_ENT_REFERENCE && g_SuppressedHoneypotRefs[i] == ref)) {
            best = i;
            oldest = -1.0;
            break;
        }
        if (g_SuppressedHoneypotUntil[i] < oldest) {
            oldest = g_SuppressedHoneypotUntil[i];
            best = i;
        }
    }

    g_SuppressedHoneypotRefs[best] = ref;
    g_SuppressedHoneypotEnts[best] = entity;
    g_SuppressedHoneypotUntil[best] = until;
}

stock bool IsSuppressedHoneypotEntity(int entity)
{
    if (entity <= MaxClients || entity <= 0) {
        return false;
    }

    float now = GetGameTime();
    bool valid = IsValidEntity(entity);
    int ref = valid ? EntIndexToEntRef(entity) : INVALID_ENT_REFERENCE;
    for (int i = 0; i < HONEYPOT_SUPPRESS_SLOTS; i++) {
        if (g_SuppressedHoneypotUntil[i] <= now) {
            continue;
        }
        if (valid && ref != INVALID_ENT_REFERENCE && g_SuppressedHoneypotRefs[i] == ref) {
            return true;
        }
        if (!valid && g_SuppressedHoneypotEnts[i] == entity) {
            return true;
        }
    }

    return false;
}

// ===================== Entity & Particle Utilities =====================
stock void EnsureHoneypotNonSolid(int honeypotEntity)
{
    if (!IsValidEntity(honeypotEntity)) return;
    // Keep the entity looking closer to a normal projectile while hooks/spawn validation
    // handle the collision side. Cheats are more likely to consider this a real rocket.
    const int fsTrigger = 0x0008;
    const int collisionDefault = 0;
    SetEntProp(honeypotEntity, Prop_Data, "m_nSolidType", 2);
    SetEntProp(honeypotEntity, Prop_Data, "m_usSolidFlags", fsTrigger);
    SetEntProp(honeypotEntity, Prop_Data, "m_CollisionGroup", collisionDefault);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_usSolidFlags")) SetEntProp(honeypotEntity, Prop_Send, "m_usSolidFlags", fsTrigger);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_CollisionGroup")) SetEntProp(honeypotEntity, Prop_Send, "m_CollisionGroup", collisionDefault);
    int flags = GetEntProp(honeypotEntity, Prop_Data, "m_fFlags");
    SetEntProp(honeypotEntity, Prop_Data, "m_fFlags", flags & ~(0x00000800));
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bCollideWithWorld")) SetEntProp(honeypotEntity, Prop_Send, "m_bCollideWithWorld", 0);
    if (HasEntProp(honeypotEntity, Prop_Data, "m_bCollideWithOwner")) SetEntProp(honeypotEntity, Prop_Data, "m_bCollideWithOwner", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bCollideWithOwner")) SetEntProp(honeypotEntity, Prop_Send, "m_bCollideWithOwner", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bSolidToPlayers")) SetEntProp(honeypotEntity, Prop_Send, "m_bSolidToPlayers", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bSolidToNPCs")) SetEntProp(honeypotEntity, Prop_Send, "m_bSolidToNPCs", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bShouldExplodeOnTouch")) SetEntProp(honeypotEntity, Prop_Send, "m_bShouldExplodeOnTouch", 0);
    if (HasEntProp(honeypotEntity, Prop_Data, "m_bShouldExplodeOnTouch")) SetEntProp(honeypotEntity, Prop_Data, "m_bShouldExplodeOnTouch", 0);
}

stock void ClearHoneypotTrailHandles(int honeypotEntity)
{
    if (!IsValidEntity(honeypotEntity)) return;
    static const char trailSendProps[][] = {"m_hRocketTrail","m_hCriticalTrail","m_hExplosionSprite","m_hParticleEffect","m_hGlowTrail","m_hProjectileTrail","m_hParticleSystem","m_hTrailParticle","m_hTracerParticle"};
    for (int i = 0; i < sizeof(trailSendProps); i++) if (HasEntProp(honeypotEntity, Prop_Send, trailSendProps[i])) SetEntPropEnt(honeypotEntity, Prop_Send, trailSendProps[i], -1);
    static const char trailDataProps[][] = {"m_hRocketTrail","m_hCriticalTrail","m_hTrailParticle","m_hProjectileTrail"};
    for (int j = 0; j < sizeof(trailDataProps); j++) if (HasEntProp(honeypotEntity, Prop_Data, trailDataProps[j])) SetEntPropEnt(honeypotEntity, Prop_Data, trailDataProps[j], -1);
    static const char trailIntProps[][] = {"m_iParticleSystemIndex","m_nTrailParticleIndex","m_nExplosionParticle","m_iAttachedParticle"};
    for (int k = 0; k < sizeof(trailIntProps); k++) { if (HasEntProp(honeypotEntity, Prop_Send, trailIntProps[k])) SetEntProp(honeypotEntity, Prop_Send, trailIntProps[k], 0); if (HasEntProp(honeypotEntity, Prop_Data, trailIntProps[k])) SetEntProp(honeypotEntity, Prop_Data, trailIntProps[k], 0); }
}

stock void ForceHoneypotInvisible(int honeypotEntity)
{
    if (!IsValidEntity(honeypotEntity)) return;
    ClearHoneypotTrailHandles(honeypotEntity);
    SetEntityRenderMode(honeypotEntity, RENDER_TRANSCOLOR);
    SetEntityRenderColor(honeypotEntity, 0, 0, 0, 0);
    SetEntPropFloat(honeypotEntity, Prop_Send, "m_flModelScale", 0.01);
    SetEntProp(honeypotEntity, Prop_Send, "m_fEffects", 0);
    SetEntPropEnt(honeypotEntity, Prop_Send, "m_hEffectEntity", -1);
    SetEntProp(honeypotEntity, Prop_Send, "m_nRenderFX", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bGlowEnabled")) SetEntProp(honeypotEntity, Prop_Send, "m_bGlowEnabled", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_bShouldExplodeOnTouch")) SetEntProp(honeypotEntity, Prop_Send, "m_bShouldExplodeOnTouch", 0);
    if (HasEntProp(honeypotEntity, Prop_Data, "m_bShouldExplodeOnTouch")) SetEntProp(honeypotEntity, Prop_Data, "m_bShouldExplodeOnTouch", 0);
    if (HasEntProp(honeypotEntity, Prop_Send, "m_hParticleEffect")) SetEntPropEnt(honeypotEntity, Prop_Send, "m_hParticleEffect", -1);
}

stock float GetClientPingMs(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) {
        return 0.0;
    }
    float inLat = GetClientAvgLatency(client, NetFlow_Incoming);
    float outLat = GetClientAvgLatency(client, NetFlow_Outgoing);
    return (inLat + outLat) * 1000.0;
}

stock float DotProduct(const float a[3], const float b[3]) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

stock void VectorSubtract(const float a[3], const float b[3], float out[3]) {
    out[0] = a[0] - b[0];
    out[1] = a[1] - b[1];
    out[2] = a[2] - b[2];
}

stock bool TryGetEntityAbsVelocity(int entity, float velocity[3]) {
    if (HasEntProp(entity, Prop_Data, "m_vecAbsVelocity")) {
        GetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", velocity);
        return true;
    }

    if (HasEntProp(entity, Prop_Send, "m_vecVelocity")) {
        GetEntPropVector(entity, Prop_Send, "m_vecVelocity", velocity);
        return true;
    }

    velocity[0] = velocity[1] = velocity[2] = 0.0;
    return false;
}

// ===================== SourceTV Recording Utilities =====================

stock bool IsSourceTVManagerAvailable(bool logMissing = false) {
    bool available =
        GetFeatureStatus(FeatureType_Native, "SourceTV_IsRecording") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "SourceTV_GetRecordingTick") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "SourceTV_GetDemoFileName") == FeatureStatus_Available;

    if (!available && logMissing) {
        static bool warned;
        if (!warned) {
            LogMessage("[SourceTV] Optional SourceTV Manager extension is unavailable; recording/bookmarks are disabled, honeypot detection and built-in SourceTV visuals continue.");
            warned = true;
        }
    }
    return available;
}

stock int GetRealPlayerCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            count++;
        }
    }
    return count;
}

public Action Timer_OpenSourceTVBookmarkSession(Handle timer) {
    if (!g_bBookmarkSessionActive) {
        OpenSourceTVBookmarkSession();
    }
    return Plugin_Stop;
}

public Action Timer_CloseSourceTVBookmarkSession(Handle timer) {
    if (g_bBookmarkSessionActive) {
        CloseSourceTVBookmarkSession();
    }
    return Plugin_Stop;
}

public Action Timer_CloseBookmarkSessionIfEmpty(Handle timer) {
    if (g_bBookmarkSessionActive && GetRealPlayerCount() == 0) {
        CloseSourceTVBookmarkSession();
        LogMessage("[SourceTV] Bookmark session closed - all players left");
    }
    return Plugin_Stop;
}

public Action Timer_DeleteEmptyBookmarkFile(Handle timer, DataPack pack) {
    char bookmarkBasePath[128];
    pack.ReadString(bookmarkBasePath, sizeof(bookmarkBasePath));
    
    char bookmarkPath[PLATFORM_MAX_PATH];
    Format(bookmarkPath, sizeof(bookmarkPath), "%s.txt", bookmarkBasePath);
    if (FileExists(bookmarkPath)) {
        DeleteFile(bookmarkPath);
        LogMessage("[SourceTV] Deleted bookmark file: %s", bookmarkPath);
    }
    
    return Plugin_Stop;
}

stock void OpenSourceTVBookmarkSession() {
    if (!g_hSourceTVEnable.BoolValue || !IsSourceTVManagerAvailable(true)) return;
    if (g_bBookmarkSessionActive) return;
    
    // Create a unique metadata path.
    char timeStr[64];
    FormatTime(timeStr, sizeof(timeStr), "%Y%m%d_%H%M%S", GetTime());
    char folder[128];
    GetConVarString(g_hSourceTVFolder, folder, sizeof(folder));
    if (folder[0] == '\0') {
        strcopy(folder, sizeof(folder), "demos/anticheat");
    }
    CreateDirectory(folder, 511);
    Format(g_sBookmarkBasePath, sizeof(g_sBookmarkBasePath), "%s/anticheat_%s", folder, timeStr);

    g_bBookmarkSessionActive = SourceTV_IsRecording();
    g_iBookmarkCount = 0;
    
    if (g_bBookmarkSessionActive) {
        LogMessage("[SourceTV] Bookmark session started: %s.txt", g_sBookmarkBasePath);
    } else {
        LogMessage("[SourceTV] SourceTV not recording; bookmarks will be skipped");
    }
}

stock void CloseSourceTVBookmarkSession() {
    if (!g_bBookmarkSessionActive) return;
    
    g_bBookmarkSessionActive = false;
    
    if (g_iBookmarkCount == 0) {
        DataPack pack;
        CreateDataTimer(5.0, Timer_DeleteEmptyBookmarkFile, pack, TIMER_FLAG_NO_MAPCHANGE);
        pack.WriteString(g_sBookmarkBasePath);
        LogMessage("[SourceTV] Bookmark file %s.txt will be deleted (no bookmarks)", g_sBookmarkBasePath);
    } else {
        LogMessage("[SourceTV] Bookmark session ended: %s.txt (%d bookmarks)", g_sBookmarkBasePath, g_iBookmarkCount);
    }
    
    g_sBookmarkBasePath[0] = '\0';
    g_iBookmarkCount = 0;
}

stock void AddSourceTVBookmark(int client, const char[] reason) {
    if (!g_hSourceTVEnable.BoolValue || !g_hSourceTVAutoBookmark.BoolValue) return;
    if (!IsSourceTVManagerAvailable(true)) return;
    if (!SourceTV_IsRecording()) {
        g_bBookmarkSessionActive = false;
        return;
    }
    if (!g_bBookmarkSessionActive) {
        OpenSourceTVBookmarkSession();
    }
    if (!g_bBookmarkSessionActive) {
        return;
    }
    
    char clientName[64];
    GetClientName(client, clientName, sizeof(clientName));
    
    char steamId[64];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true);
    
    char bookmarkMsg[256];
    Format(bookmarkMsg, sizeof(bookmarkMsg), "CHEATER: %s [%s] - %s", clientName, steamId, reason);
    g_iBookmarkCount++;
    
    int demoTick = SourceTV_GetRecordingTick();
    char activeDemo[PLATFORM_MAX_PATH];
    activeDemo[0] = '\0';
    SourceTV_GetDemoFileName(activeDemo, sizeof(activeDemo));
    
    char bookmarkFilePath[PLATFORM_MAX_PATH];
    Format(bookmarkFilePath, sizeof(bookmarkFilePath), "%s.txt", g_sBookmarkBasePath);
    
    Handle file = OpenFile(bookmarkFilePath, "a");
    if (file != null) {
        char timeStr[64];
        FormatTime(timeStr, sizeof(timeStr), "%Y-%m-%d %H:%M:%S", GetTime());
        
        if (activeDemo[0] != '\0') {
            WriteFileLine(file, "[%s] Tick: %d | %s | Demo: %s", timeStr, demoTick, bookmarkMsg, activeDemo);
        } else {
            WriteFileLine(file, "[%s] Tick: %d | %s", timeStr, demoTick, bookmarkMsg);
        }
        CloseHandle(file);
    }
    
    LogMessage("[SourceTV] Bookmark #%d added at tick %d: %s", g_iBookmarkCount, demoTick, bookmarkMsg);
}
