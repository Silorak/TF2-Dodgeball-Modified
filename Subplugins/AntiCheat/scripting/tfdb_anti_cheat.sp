/*
 * TF2Dodgeball_InvisibleHoneypot.sp - Cheat-Visible Honeypot Detection System
 *
 * KEY STRATEGY:
 * - Entity MUST be networked normally (no EF_NODRAW, no SetTransmit blocking)
 * - Particles hidden via model scale manipulation and particle system tricks
 * - Sounds blocked via client-side filtering
 * - Cheats can enumerate it, but humans can't see it
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <sdkhooks>
#include <tfdb>

// ===================== Plugin Info =====================
// Plugin Information
public Plugin myinfo =
{
  name        = "[TFDB] Anti-Cheat",
  author      = "Darka, Tolfx, Silorak",
  description = "Honeypot-based cheat detection for TF2 Dodgeball",
  version     = "2.3.0",
  url         = "https://github.com/Silorak/TF2-Dodgeball"
};

// ===================== Constants =====================
// Entity constants
#define AIRBLAST_RANGE              50.0
#define AIRBLAST_SAFETY_MARGIN      5.0
#define HONEYPOT_RANGE              (AIRBLAST_RANGE + AIRBLAST_SAFETY_MARGIN)
#define HONEYPOT_VIEW_DOT_THRESHOLD 0.94
#if !defined DMG_AIRBLAST
  #define DMG_AIRBLAST (1 << 28)
#endif

#include "include/honeypot_entities.inc"  // Configuration handles, cvar init and shared data moved to this include
#include "include/honeypot_utils.inc"
#include "include/honeypot_detection.inc"
#include "include/honeypot_logic.inc"
#include "include/honeypot_hooks.inc"

// ===================== Startup & Configuration =====================
// Plugin startup

public Action Cmd_HpDebugDraw(int client, int args)
{
    if (client < 1 || !IsClientInGame(client)) return Plugin_Handled;
    g_HpDebugDraw[client] = !g_HpDebugDraw[client];
    PrintToChat(client, "[Honeypot] Debug draw %s", g_HpDebugDraw[client] ? "ON" : "OFF");
    return Plugin_Handled;
}

// Draw a box around a position using beams
void DrawHoneypotBox(int adminClient, float pos[3])
{
    float mins[3], maxs[3];
    mins[0] = pos[0] - 20.0; maxs[0] = pos[0] + 20.0;
    mins[1] = pos[1] - 20.0; maxs[1] = pos[1] + 20.0;
    mins[2] = pos[2] - 20.0; maxs[2] = pos[2] + 20.0;

    int color[4] = {255, 0, 0, 255}; // red box
    float life = 0.1;

    // Bottom rectangle
    float p1[3], p2[3], p3[3], p4[3];
    p1[0] = mins[0]; p1[1] = mins[1]; p1[2] = mins[2];
    p2[0] = maxs[0]; p2[1] = mins[1]; p2[2] = mins[2];
    p3[0] = maxs[0]; p3[1] = maxs[1]; p3[2] = mins[2];
    p4[0] = mins[0]; p4[1] = maxs[1]; p4[2] = mins[2];

    TE_SetupBeamPoints(p1, p2, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
    TE_SetupBeamPoints(p2, p3, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
    TE_SetupBeamPoints(p3, p4, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
    TE_SetupBeamPoints(p4, p1, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);

    // Top rectangle
    p1[2] = maxs[2]; p2[2] = maxs[2]; p3[2] = maxs[2]; p4[2] = maxs[2];
    TE_SetupBeamPoints(p1, p2, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
    TE_SetupBeamPoints(p2, p3, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
    TE_SetupBeamPoints(p3, p4, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
    TE_SetupBeamPoints(p4, p1, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);

    // Vertical edges
    p1[0] = mins[0]; p1[1] = mins[1]; p1[2] = mins[2];
    p2[0] = mins[0]; p2[1] = mins[1]; p2[2] = maxs[2];
    TE_SetupBeamPoints(p1, p2, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);

    p1[0] = maxs[0]; p1[1] = mins[1]; p1[2] = mins[2];
    p2[0] = maxs[0]; p2[1] = mins[1]; p2[2] = maxs[2];
    TE_SetupBeamPoints(p1, p2, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);

    p1[0] = maxs[0]; p1[1] = maxs[1]; p1[2] = mins[2];
    p2[0] = maxs[0]; p2[1] = maxs[1]; p2[2] = maxs[2];
    TE_SetupBeamPoints(p1, p2, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);

    p1[0] = mins[0]; p1[1] = maxs[1]; p1[2] = mins[2];
    p2[0] = mins[0]; p2[1] = maxs[1]; p2[2] = maxs[2];
    TE_SetupBeamPoints(p1, p2, g_HpBeamModel, g_HpBeamModel, 0, 0, life, 1.0, 1.0, 1, 0.0, color, 0);
    TE_SendToClient(adminClient);
}


public void OnPluginStart()
{
  g_TF2DodgeballLoaded = LibraryExists("tfdb");
  LoadTranslations("tfdb.phrases.txt");

  // Configuration
  g_hEnabled           = CreateConVar("tf2db_honeypot_enabled", "1", "Enable the honeypot detection system", _, true, 0.0, true, 1.0);
  g_hDebugMode         = CreateConVar("tf2db_honeypot_debug", "0", "Enable verbose scheduler/debug console logging");
  g_hSpawnDelay        = CreateConVar("tf2db_honeypot_spawn_delay", "0.0", "Spawn delay (seconds)", _, true, 0.0, true, 0.5);
  g_hGracePeriod       = CreateConVar("tf2db_honeypot_grace_period", "0.05", "Grace period after spawn (seconds)", _, true, 0.0, true, 1.0);
  g_hMaxHoneypots      = CreateConVar("tf2db_honeypot_max", "16", "Maximum concurrent honeypots");
  g_hHoneypotLifetime  = CreateConVar("tf2db_honeypot_lifetime", "0.35", "Honeypot lifetime (seconds)", _, true, 0.05, true, 2.0);
  g_hHoneypotSpeed     = CreateConVar("tf2db_honeypot_speed", "420.0", "Initial honeypot projectile speed (units per second)", _, true, 50.0, true, 1200.0);
  g_hAllowBotTargets   = CreateConVar("tf2db_honeypot_allow_bots", "0", "Allow honeypots to target bots", _, true, 0.0, true, 1.0);
  g_hSpawnBuffer       = CreateConVar("tf2db_honeypot_spawn_buffer", "0.02", "Additional buffer applied to predictive honeypot spawns (seconds)", _, true, 0.0, true, 0.25);
  g_hMinSpawnDistance  = CreateConVar("tf2db_honeypot_min_spawn_dist", "400.0", "Do not spawn honeypot when real rocket is closer than this distance (units)", _, true, 0.0, true, 1024.0);
  g_hEntryRange        = CreateConVar("tf2db_honeypot_entry_range", "440.0", "Distance at which honeypot promotion occurs (pre-entry spawn)", _, true, 64.0, true, 1024.0);
  g_hPreEntryLead      = CreateConVar("tf2db_honeypot_preentry_lead", "24.0", "Tolerance near entry_range for honeypot creation (units)", _, true, 0.0, true, 256.0);
  g_hDebugCritical     = CreateConVar("tf2db_honeypot_debug_crit", "0", "Force honeypot rockets critical for debugging", _, true, 0.0, true, 1.0);
  g_hLogEnable         = CreateConVar("tf2db_honeypot_log_enable", "1", "Enable logging detections to file", _, true, 0.0, true, 1.0);
  g_hLogFile           = CreateConVar("tf2db_honeypot_log_file", "honeypot_detections.log", "Log filename (relative to addons/sourcemod/logs)");
  g_hSpawnJitter       = CreateConVar("tf2db_honeypot_spawn_jitter", "0.03", "Random jitter added to honeypot spawn timing (seconds)", _, true, 0.0, true, 0.25);
  g_hTargetCooldown    = CreateConVar("tf2db_honeypot_target_cooldown", "0.5", "Cooldown before same player gets another honeypot (seconds)", _, true, 0.0, true, 3.0);
  g_hQuietWindow       = CreateConVar("tf2db_honeypot_quiet_window", "0.25", "Minimum time since last airblast before scheduling (seconds)", _, true, 0.0, true, 2.0);
  g_hFaceDot           = CreateConVar("tf2db_honeypot_face_dot", "0.75", "Minimum facing dot product required for detection", _, true, 0.0, true, 1.0);
  g_hMultiPyroEnable   = CreateConVar("tf2db_honeypot_multi_pyro_enable", "1", "Enable multi-Pyro proximity filter", _, true, 0.0, true, 1.0);
  g_hMultiPyroRadius   = CreateConVar("tf2db_honeypot_multi_pyro_radius", "128.0", "Radius to consider nearby Pyros ambiguous (units)", _, true, 32.0, true, 512.0);
  g_hMultiPyroCloseRadius = CreateConVar("tf2db_honeypot_multi_pyro_close_radius", "256.0", "Block honeypot spawn when any Pyro is very close (units)", _, true, 16.0, true, 256.0);
  g_hScoreThreshold    = CreateConVar("tf2db_honeypot_score_threshold", "10.0", "Detection score threshold before punishment", _, true, 0.5, true, 10.0);
  g_hPunishEnable      = CreateConVar("tf2db_honeypot_punish_enable", "0", "Enable kick and player chat punishments", _, true, 0.0, true, 1.0);
  g_hAdminAlerts       = CreateConVar("tf2db_honeypot_admin_alerts", "1", "Notify generic-flag admins of accepted honeypot detections", _, true, 0.0, true, 1.0);
  g_hLegitDot          = CreateConVar("tf2db_honeypot_legit_dot", "0.99", "Dot required to consider a real rocket in FOV legitimate", _, true, 0.0, true, 1.0);
  g_hLegitRange        = CreateConVar("tf2db_honeypot_legit_range", "235.0", "Max distance to real rocket to consider legitimate airblast (units)", _, true, 32.0, true, 512.0);
  g_hGroundClearance   = CreateConVar("tf2db_honeypot_ground_clearance", "24.0", "Minimum Z clearance above ground for honeypot spawn (units)", _, true, 8.0, true, 96.0);
  g_hRealFar           = CreateConVar("tf2db_honeypot_real_far", "600.0", "Distance above which real rocket considered far (units)", _, true, 128.0, true, 4096.0);
  g_hClosingAway       = CreateConVar("tf2db_honeypot_closing_away", "600.0", "Minimum away speed to consider real rocket moving away (units/s)", _, true, 100.0, true, 5000.0);
  g_hMouseWindow       = CreateConVar("tf2db_honeypot_mouse_window", "0.15", "Time window around honeypot hit to measure mouse movement (s)", _, true, 0.02, true, 0.50);
  g_hMouseFlickDeg     = CreateConVar("tf2db_honeypot_mouse_flick_deg", "22.0", "Total mouse degrees in window to consider flick legit", _, true, 0.0, true, 180.0);
  g_hSpeedFast         = CreateConVar("tf2db_honeypot_speed_fast", "0.10", "Fast airblast window (seconds)", _, true, 0.02, true, 1.0);
  g_hSpeedSlow         = CreateConVar("tf2db_honeypot_speed_slow", "0.45", "Slow airblast window (seconds)", _, true, 0.1, true, 2.0);
  g_hSpeedFastMult     = CreateConVar("tf2db_honeypot_speed_fast_mult", "1.25", "Weight multiplier for fast airblasts", _, true, 0.5, true, 3.0);
  g_hSpeedSlowMult     = CreateConVar("tf2db_honeypot_speed_slow_mult", "0.80", "Weight multiplier for slow airblasts", _, true, 0.1, true, 1.5);
  g_hAutoPressMin      = CreateConVar("tf2db_auto_press_min", "0.16", "Minimum interval for auto airblast cadence (s)", _, true, 0.05, true, 0.5);
  g_hAutoPressMax      = CreateConVar("tf2db_auto_press_max", "0.35", "Maximum interval for auto airblast cadence (s)", _, true, 0.1, true, 1.0);
  g_hAutoPressJitter   = CreateConVar("tf2db_auto_press_jitter", "0.06", "Allowed jitter between intervals (s)", _, true, 0.01, true, 0.2);
  g_hAutoPressRequired = CreateConVar("tf2db_auto_press_required", "3", "Number of recent intervals required to match cadence", _, true, 2.0, true, 3.0);
  g_hAutoFovDeg        = CreateConVar("tf2db_auto_fov_deg", "20.0", "Assumed cheat auto airblast FOV in degrees", _, true, 5.0, true, 45.0);
  g_hLegitNear         = CreateConVar("tf2db_honeypot_legit_near", "128.0", "Extra margin to treat real rocket as closer than honeypot (units)", _, true, 0.0, true, 256.0);
  ConVar autoScale     = CreateConVar("tf2db_honeypot_autoscale_tick", "1", "Autoscale timing for server tickrate", _, true, 0.0, true, 1.0);
  Handle hUpd          = FindConVar("sv_maxupdaterate");
  float  upd           = hUpd == null ? 66.0 : GetConVarFloat(hUpd);
  float  scale         = (upd <= 0.0) ? 1.0 : (66.0 / upd);
  if (autoScale.BoolValue)
  {
    SetConVarFloat(g_hSpawnJitter, MaxFloat(0.005, g_hSpawnJitter.FloatValue * scale));
    SetConVarFloat(g_hSpawnDelay, MaxFloat(0.0, g_hSpawnDelay.FloatValue * scale));
    SetConVarFloat(g_hGracePeriod, MaxFloat(0.01, g_hGracePeriod.FloatValue * scale));
    SetConVarFloat(g_hQuietWindow, MaxFloat(0.05, g_hQuietWindow.FloatValue * scale));
    SetConVarFloat(g_hSpeedFast, MaxFloat(0.02, g_hSpeedFast.FloatValue * scale));
    SetConVarFloat(g_hSpeedSlow, MaxFloat(0.05, g_hSpeedSlow.FloatValue * scale));
    SetConVarFloat(g_hAutoPressMin, MaxFloat(0.05, g_hAutoPressMin.FloatValue * scale));
    SetConVarFloat(g_hAutoPressMax, MaxFloat(0.08, g_hAutoPressMax.FloatValue * scale));
    SetConVarFloat(g_hAutoPressJitter, MaxFloat(0.01, g_hAutoPressJitter.FloatValue * scale));
    SetConVarFloat(g_hSpawnBuffer, MaxFloat(0.0, g_hSpawnBuffer.FloatValue * scale));
  }
  g_hPressScoreDistMin      = CreateConVar("tf2db_honeypot_press_dist_min", "235.0", "Minimum real rocket distance at press to log", _, true, 0.0, true, 1024.0);
  if (autoScale.BoolValue)
  {
    // No autoscale adjustments needed for removed convars
  }

  // SourceTV recording and bookmarking
  g_hSourceTVEnable       = CreateConVar("tf2db_sourcetv_enable", "1", "Enable SourceTV integration", _, true, 0.0, true, 1.0);
  g_hSourceTVAutoRecord   = CreateConVar("tf2db_sourcetv_auto_record", "1", "Open/close AntiCheat bookmark sessions on round boundaries when SourceTV is already recording", _, true, 0.0, true, 1.0);
  g_hSourceTVAutoBookmark = CreateConVar("tf2db_sourcetv_auto_bookmark", "1", "Automatically add bookmarks when cheaters are detected", _, true, 0.0, true, 1.0);
  g_hSourceTVFolder       = CreateConVar("tf2db_sourcetv_folder", "demos/anticheat", "Folder for anticheat bookmark metadata", _, false, 0.0, false, 0.0);

  // SourceTV-only visual duplicate for honeypots
  g_hSourceTVVisuals      = CreateConVar("tf2db_sourcetv_visuals", "1", "Show honeypot visually on SourceTV only", _, true, 0.0, true, 1.0);
  g_hSourceTVVisualCrit   = CreateConVar("tf2db_sourcetv_visual_crit", "1", "Make SourceTV honeypot visual critical", _, true, 0.0, true, 1.0);
  g_hSourceTVVisualModel  = CreateConVar("tf2db_sourcetv_visual_model", "models/weapons/w_models/w_rocket.mdl", "Model path for SourceTV honeypot visual");

  AutoExecConfig(true, "tf2db_honeypot_system");

  InitializeHoneypotArrays();
  InitializeClientData();

  // Hook events
  HookEvent("player_spawn", OnPlayerSpawn);
  HookEvent("player_death", OnPlayerDeath);
  HookEvent("teamplay_round_start", OnRoundStart);
  HookEvent("teamplay_round_win", OnRoundEnd);

  // Hook sounds to block deflection sounds
  AddNormalSoundHook(Hook_NormalSound);

  // CRITICAL: Hook TempEntity to block ALL particle effects at network level
  AddTempEntHook("TFParticleEffect", Hook_BlockParticleEffects);
  AddTempEntHook("EffectDispatch", Hook_BlockParticleEffects);
  AddTempEntHook("World Decal", Hook_BlockParticleEffects);
  AddTempEntHook("BeamFollow", Hook_BlockParticleEffects);

  // CRITICAL: Hook entity outputs to block particle spawning;;;;

  for (int i = 0; i < MAX_ROCKETS; i++)
  {
    g_PendingSpawns[i].active = false;
  }

  PrintToServer("[BustedByDarka] v8.4.0 loaded - Cheat-visible, human-invisible honeypots");
  if (g_TF2DodgeballLoaded)
  {
    PrintToServer("[BustedByDarka] TF2Dodgeball detected - full functionality enabled");
  }

  // Debug draw command
  RegAdminCmd("sm_ac_debug", Cmd_HpDebugDraw, ADMFLAG_ROOT, "[ROOT] Toggle honeypot debug box visualization");
  g_HpBeamModel = PrecacheModel("materials/sprites/laser.vmt", true);
}

// Library tracking
public void OnLibraryAdded(const char[] name)
{
  if (StrEqual(name, "tfdb"))
  {
    g_TF2DodgeballLoaded = true;
  }
}

public void OnLibraryRemoved(const char[] name)
{
  if (StrEqual(name, "tfdb"))
  {
    g_TF2DodgeballLoaded = false;
  }
}
