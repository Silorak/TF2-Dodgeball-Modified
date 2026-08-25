#if defined _honeypot_entities_included
  #endinput
#endif
#define _honeypot_entities_included
// Honeypot entity creation, property setup, and visual rendering for SourceTV.


// Shared honeypot data: enums and global variables
ConVar g_hEnabled;
ConVar g_hDebugMode;
ConVar g_hSpawnDelay;
ConVar g_hGracePeriod;
ConVar g_hMaxHoneypots;
ConVar g_hHoneypotLifetime;
ConVar g_hHoneypotSpeed;
ConVar g_hAllowBotTargets;
ConVar g_hSpawnBuffer;
ConVar g_hDebugCritical;
ConVar g_hSpawnJitter;
ConVar g_hMinSpawnDistance;
ConVar g_hTargetCooldown;
ConVar g_hQuietWindow;
ConVar g_hFaceDot;
ConVar g_hMultiPyroEnable;
ConVar g_hMultiPyroRadius;
ConVar g_hMultiPyroCloseRadius;
ConVar g_hScoreThreshold;
ConVar g_hLegitDot;
ConVar g_hLegitRange;
ConVar g_hGroundClearance;
ConVar g_hRealFar;
ConVar g_hClosingAway;
ConVar g_hSpeedFast;
ConVar g_hSpeedSlow;
ConVar g_hSpeedFastMult;
ConVar g_hSpeedSlowMult;
ConVar g_hAutoPressMin, g_hAutoPressMax, g_hAutoPressJitter, g_hAutoPressRequired;
ConVar g_hPressScoreDistMin;
ConVar g_hAutoFovDeg, g_hLegitNear;
ConVar g_hLogEnable, g_hLogFile;
ConVar g_hPunishEnable;
ConVar g_hAdminAlerts;
ConVar g_hEntryRange;
ConVar g_hPreEntryLead;
ConVar g_hMouseWindow, g_hMouseFlickDeg;
// SourceTV recording
ConVar g_hSourceTVEnable;
ConVar g_hSourceTVAutoRecord;
ConVar g_hSourceTVAutoBookmark;
ConVar g_hSourceTVFolder;
bool g_bBookmarkSessionActive = false;
char g_sBookmarkBasePath[256];
int g_iBookmarkCount = 0;

// SourceTV-only visual config
ConVar g_hSourceTVVisuals;
ConVar g_hSourceTVVisualCrit;
ConVar g_hSourceTVVisualModel;

enum struct HoneypotData {
    int entity;
    int target;
    int realRocketEntity;
    int visualEntity;
    float spawnTime;
    int detections;
    bool isActive;
    bool visualActive;
    Handle cleanupTimer;
    Handle particleKillTimer;
}

enum struct ClientData {
    int honeypotDetections;
    float lastDetectionTime;
    int consecutiveDetections;
    float lastAttack2Time;
    bool holdingAttack2;
    float lastTargetedTime;
    float detectionScore;
    float lastPressRocketDist;
}

enum HoneypotDetectionSource {
    HoneypotDetectionSource_Generic = 0,
    HoneypotDetectionSource_Command,
    HoneypotDetectionSource_Damage,
    HoneypotDetectionSource_Touch
};

HoneypotData g_Honeypots[MAX_ROCKETS];
ClientData g_Clients[MAXPLAYERS + 1];
int g_HoneypotCount;
bool g_HoneypotsActive;
bool g_TF2DodgeballLoaded = false;
Handle g_GameFrameTimer;

enum struct PendingSpawn {
    int rocketRef;
    int target;
    float spawnAt;
    bool active;
}

PendingSpawn g_PendingSpawns[MAX_ROCKETS];

float g_LastEntryCrossTime[MAXPLAYERS + 1];
float g_LastRocketDist[MAXPLAYERS + 1];
float g_ReactionTimes[MAXPLAYERS + 1][10];
int g_ReactionCounts[MAXPLAYERS + 1];
float g_HpReactionTimes[MAXPLAYERS + 1][10];
int g_HpReactionCounts[MAXPLAYERS + 1];
float g_PressTimes[MAXPLAYERS + 1][4];
int g_LegitTraceIgnoreClient = 0;
int g_LegitTraceIgnoreEntity = 0;
float g_LastAngles[MAXPLAYERS + 1][3];
float g_MouseDegTimes[MAXPLAYERS + 1][20];
float g_MouseDegMag[MAXPLAYERS + 1][20];
int g_MouseDegCount[MAXPLAYERS + 1];

#define HONEYPOT_SUPPRESS_SLOTS 32
int g_SuppressedHoneypotRefs[HONEYPOT_SUPPRESS_SLOTS];
int g_SuppressedHoneypotEnts[HONEYPOT_SUPPRESS_SLOTS];
float g_SuppressedHoneypotUntil[HONEYPOT_SUPPRESS_SLOTS];

// Debug visualization
bool g_HpDebugDraw[MAXPLAYERS + 1];
int g_HpBeamModel = 0;
