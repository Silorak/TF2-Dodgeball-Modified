// tfdb_pvb_teams.inc - auto-extracted from tfdb_pvb.sp
// Do not edit directly; this is a split of the PvB plugin.

public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "tfdb")) {
        TFDBAvailable = true;
    }
}

public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "tfdb")) {
        TFDBAvailable = false;
    }
}

public void OnPluginStart() {
    LoadTranslations("tfdb.phrases.txt");

    // CurrentMap used to be set only in OnMapStart, which does NOT re-fire
    // on a plugin-only reload (`sm plugins reload tfdb_pvb`) mid-map - a
    // completely normal admin/testing workflow, not an edge case. That left
    // CurrentMap as an empty string for the rest of that session, silently
    // breaking every nav-cache file path (data/tfdb_pvb_navcache/%s.txt
    // with an empty map name): NavCache_Load() would always "fail" (wrong
    // file), forcing g_WalkableCells to stay null and every DirectionIsWalkable
    // call onto the live-trace fallback for the ENTIRE session, no matter
    // how good the actual persisted cache was. Set it here too so a plugin
    // reload alone is enough to recover it; OnMapStart's call remains for
    // the genuine map-change case (map name obviously changes then).
    GetCurrentMap(CurrentMap, sizeof(CurrentMap));

    // Same reload gap as CurrentMap above: the 15s retry poll used to only
    // get created in OnMapStart, so a plugin-only reload had no independent
    // trigger to (re)start the nav scan until the next player spawn event.
    // Harmless to create here too - StartNavScanIfNeeded() is already a
    // no-op once a scan is active or ready, so an extra timer just means an
    // extra cheap poll, never a duplicate scan. Also try immediately, since
    // a reload while players are already in-game (the normal testing case)
    // shouldn't have to wait 15s or for someone to die first.
    CreateTimer(15.0, Timer_RetryNavScan, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    StartNavScanIfNeeded();

    g_cvAccelerate = FindConVar("sv_accelerate");
    g_cvFriction   = FindConVar("sv_friction");
    g_cvStopspeed  = FindConVar("sv_stopspeed");

    // Per-plugin log folder. Heatmap dumps + debug traces go here so they
    // don't pollute the shared addons/sourcemod/logs/ root. Mirrors the
    // pattern AntiCheat uses (logs/tfdb_ac/) and Guardian (logs/tfdb_guardian/).
    char pvbLogDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, pvbLogDir, sizeof(pvbLogDir), "logs/tfdb_pvb");
    if (!DirExists(pvbLogDir))
    {
        CreateDirectory(pvbLogDir, 511);  // 0777
    }

    // Brain system removed - behavior tree uses config weights instead

    // Lock down TF2's bot quota so the server never auto-spawns replacement bots
    // after our PvB bot is kicked. This is the fix for the "map change spawns a
    // generic vanilla bot that just stands there" bug.
    //   tf_bot_quota_mode normal  = never add/remove bots without explicit command
    //   tf_bot_quota 0            = belt & suspenders (has no effect in 'normal' mode)
    //   tf_bot_auto_vacate 0      = don't boot our bot when humans join
    LockBotQuota();

    // Pre-allocate all possible taunt slots up front. LoadPvBConfig
    // decides how many slots are actually populated based on the .cfg.
    for (int t = 0; t < MAX_BOT_TYPES; t++) {
        TauntsPlayerDeath[t] = new ArrayList(256);
        TauntsBotDeath[t] = new ArrayList(256);
    }

    // Only version ConVar - everything else is config-driven (matches TFDB ecosystem)
    CreateConVar("sm_pvb_version", PLUGIN_VERSION, "PvB Version", FCVAR_SPONLY | FCVAR_DONTRECORD | FCVAR_NOTIFY);

    // Load config (all settings come from pvb.cfg)
    LoadPvBConfig();

    // Hooks. Use HookEventEx (returns false instead of throwing) so if any of
    // these event names ever get renamed / removed in a TF2 update, the plugin
    // logs a warning and keeps loading instead of hard-erroring on startup.
    if (!HookEventEx("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy))
        LogError("[PvB] Failed to hook teamplay_round_start");
    if (!HookEventEx("teamplay_round_win", Event_RoundEnd, EventHookMode_Post))
        LogError("[PvB] Failed to hook teamplay_round_win");
    if (!HookEventEx("player_death", Event_PlayerDeath))
        LogError("[PvB] Failed to hook player_death");
    if (!HookEventEx("player_spawn", Event_PlayerSpawn))
        LogError("[PvB] Failed to hook player_spawn");
    if (!HookEventEx("player_connect", Event_PlayerConnect))
        LogError("[PvB] Failed to hook player_connect");

    // Pre-emptive team-join protection. Without this, humans can spawn on
    // the bot's team for 1-2 ticks before ManageTeams reactively yanks
    // them - which destroys spawn state via forced TF2_RespawnPlayer.
    if (!HookEventEx("player_team", Event_PlayerTeamChange, EventHookMode_Pre))
        LogError("[PvB] Failed to hook player_team");
    if (!HookEventEx("object_deflected", Event_ObjectDeflected))
        LogError("[PvB] Failed to hook object_deflected");
    AddCommandListener(Listener_BlockPvBTeamCollision, "jointeam");
    AddCommandListener(Listener_BlockPvBTeamCollision, "autoteam");

    // === ROOT Commands ===
    RegAdminCmd("sm_pvb", Cmd_Toggle, ADMFLAG_KICK, "Force enable/disable the PvB bot.");
    RegAdminCmd("sm_bot_test", Cmd_BotTest, ADMFLAG_ROOT, "[ROOT] Spawn configurable bot squad for testing. Usage: sm_bot_test <squad|stop|list>");
    
    // === ADMIN Commands ===
    RegAdminCmd("sm_botadmin", Cmd_BotAdmin, ADMFLAG_KICK, "[ADMIN] Open bot administration menu.");
    RegAdminCmd("sm_setbottype", Cmd_SetBotType, ADMFLAG_KICK, "[ADMIN] Set bot type by class index (see pvb.cfg for available classes).");
    RegAdminCmd("sm_botreload", Cmd_ReloadConfig, ADMFLAG_CONFIG, "[ADMIN] Reload pvb.cfg");
    RegAdminCmd("sm_botdebug", Cmd_BotDebug, ADMFLAG_ROOT, "[ROOT] Toggle persistent bot debug logging to CSV.");
    RegAdminCmd("sm_botdraw", Cmd_BotDebugDraw, ADMFLAG_ROOT, "[ROOT] Toggle live in-world beams showing bot wall-scan/move/aim state.");
    RegAdminCmd("sm_navdraw", Cmd_NavDraw, ADMFLAG_ROOT, "[ROOT] Toggle in-world nav-cache overlay around you. Optional arg: radius in cells (1-10).");
    RegAdminCmd("sm_navrebuild", Cmd_NavRebuild, ADMFLAG_ROOT, "[ROOT] Delete this map cached walkable-area file and rescan from scratch.");
    RegAdminCmd("sm_navaudit", Cmd_NavAudit, ADMFLAG_ROOT, "[ROOT] Probe the nav cache extremes and log what the floor probe hits there.");
    RegAdminCmd("sm_navcell", Cmd_NavCell, ADMFLAG_ROOT, "[ROOT] Dump walkable-cache cells around your position (or sm_navcell #userid). See every cell's floorZ/edgeDist directly.");
    RegAdminCmd("sm_botcfg", Cmd_BotCfg, ADMFLAG_ROOT, "[ROOT] Dump the ACTUAL runtime pvb.cfg values in effect for a bot (or all types). sm_botcfg [#userid|typeIndex]");
    RegAdminCmd("sm_pvb_profile", Cmd_PvBProfile, ADMFLAG_ROOT, "[ROOT] Profile PvB hot paths for 1-30 seconds (default 15).");

    RegAdminCmd("sm_botstop", Cmd_StopDebug, ADMFLAG_ROOT, "[ROOT] Stop bot debug logging.");
    
    // === PLAYER Commands ===
    RegConsoleCmd("sm_botstats", Cmd_BotStats, "Show PvB bot stats.");
    RegConsoleCmd("sm_botmenu", Cmd_BotMenu, "Show bot type selection menu.");
    RegConsoleCmd("sm_votepvb", Cmd_BotVote, "Vote to enable PvB bot.");

    // Check if TFDB is already loaded (late load support)
    TFDBAvailable = LibraryExists("tfdb");
}

public void OnMapStart() {
    bool wasDebugStates = DebugStatesMode;  // Remember if we were in debug-states

    MapStartTime = GetEngineTime();

    // Re-enforce quota lock: map configs (server.cfg, map-specific cfg) can
    // reset tf_bot_quota_mode back to "fill". Without this, the server would
    // auto-spawn a replacement vanilla bot on the new map.
    LockBotQuota();

    // Diagnostics (nav= debug field, 2026-08-08 test) proved OnMapStart
    // fires on every ROUND restart on this server, not only on a genuine
    // map change - some round-restart implementations changelevel to the
    // same map rather than doing a lightweight in-place reset. Every one
    // of those was unconditionally wiping a perfectly good, already-built
    // nav cache via NavCache_Reset() below, then forcing a full rebuild
    // (bail-and-retry cycle) before it was usable again - measured at
    // ~44% of total playtime spent with the cache cold, bots ~99% frozen
    // during that window vs ~48% (normal positioning idle, not paralysis)
    // once ready. Only reset when the map name actually changed.
    char previousMap[128];
    strcopy(previousMap, sizeof(previousMap), CurrentMap);
    GetCurrentMap(CurrentMap, sizeof(CurrentMap));
    bool mapActuallyChanged = !StrEqual(previousMap, CurrentMap);

    // Walkable-area cache is per-map - last map's data (or its "ready"
    // flag) must not carry over on a REAL map change, or the new map's
    // first spawn would skip loading/building its own cache entirely.
    if (mapActuallyChanged) {
        NavCache_Reset();
    }

    // Spawn events alone aren't a reliable retry trigger: they all fire at
    // once when everyone spawns together (still bunched up in spawn rooms,
    // the worst possible seed position), and if nobody dies for a while
    // there's no later spawn event to retry from bots who've since
    // scattered across the open arena. Poll independently so a failed
    // attempt gets retried with fresh positions on a schedule instead of
    // only when a death happens to trigger one. Only (re)create this on a
    // real map change - OnPluginStart already creates one, and since
    // OnMapStart fires on every round restart here, creating another every
    // time would stack up redundant repeating timers over a long session.
    if (mapActuallyChanged) {
        CreateTimer(15.0, Timer_RetryNavScan, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }

    CommandForced = false;
    CommandDisabled = false;
    BotNameDirty = true;
    CachedRocketRef = INVALID_ENT_REFERENCE;
    CachedRealCount = 0;
    CachedFakeCount = 0;

    PrecacheModel("models/bots/pyro/bot_pyro.mdl", true);
    BeamSprite = PrecacheModel("materials/sprites/laser.vmt", true);

    CreateTimer(5.0, Timer_ClearMapChanged);

    // Debug logging persists across map changes - rotate to new file per map
    if (DebugActive) {
        RotateDebugFile();
    }

    // If debug-states was active before map change, re-spawn all debug-states bots
    if (wasDebugStates) {
        DebugStatesMode = false; // Reset so StartDebugStates can set it fresh
        DebugStatesBotCount = 0;
        CreateTimer(3.0, Timer_StartDebugStates, _, TIMER_FLAG_NO_MAPCHANGE);
    } else {
        DebugStatesMode = false;
        DebugStatesBotCount = 0;
    }
}

public void OnMapEnd() {
    if (g_PvBProfileWindow.active) StopPvBProfile();
    MapChanged = true;
    if (BotEnabled && !DebugStatesMode) {
        DisablePvB();
    }
    // Reset vote state cleanly across map change. Without this, ClassVoteActive
    // could survive into the next map, causing the next !votepvb to bounce off
    // PvB_Vote_InProgress until something else clears it.
    delete ClassVoteTimer;
    ClassVoteTimer = null;
    ClassVoteActive = false;
    PendingHotSwapType = -1;
    PendingMaxPlayerDisable = false;
    for (int i = 1; i <= MaxClients; i++) {
        ClassVoted[i] = -1;
    }
    for (int t = 0; t <= MAX_BOT_TYPES; t++) {
        ClassVotes[t] = 0;
    }

    // Debug-states mode persists across map changes - bots will respawn in OnMapStart
}

public Action Timer_ClearMapChanged(Handle timer) {
    MapChanged = false;
    return Plugin_Stop;
}

public Action Timer_RetryNavScan(Handle timer) {
    if (g_NavScanActive) return Plugin_Continue;  // initial scan or a growth pass already running

    if (!g_NavScanReady) {
        StartNavScanIfNeeded();
        return Plugin_Continue;
    }

    // Cache is built and stable - periodically try to GROW it from
    // wherever bots currently are, closing gaps the initial scan's seed
    // positions never reached. Never stops for good: as a round plays out,
    // bots keep visiting territory the very first scan never got seeded
    // near, so there's always more potential coverage to pick up.
    NavCache_TryGrow();
    return Plugin_Continue;
}

public void OnClientDisconnect(int client) {
    ResetPerConnectionState(client);

    // Client is still "in-game" during OnClientDisconnect, so UpdateCachedCounts
    // would still count them. Instead, check if this was the last human - if so,
    // kick the bot NOW before the server hibernates and OnGameFrame stops firing.
    if (!IsFakeClient(client) && BotEnabled && !DebugStatesMode)
    {
        int humansLeft = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (i == client) continue;  // Skip the leaving player
            if (!TFDB_IsRealHuman(i)) continue;
            humansLeft++;
        }

        if (humansLeft == 0)
        {
            DisablePvB();
            CommandForced = false;
            CommandDisabled = false;
        }
    }

    // Same IsClientInGame-still-true hazard as the humansLeft loop above -
    // without excluding `client` here, CachedRealCount stays overcounted by
    // one (the leaving player) until some unrelated later event (join, team
    // change, another disconnect) happens to refresh it. That stale count is
    // what left PvB's player-count-driven logic (vote eligibility, max/min
    // player gating) looking at a server that still "has" the player who
    // just left, breaking bot state around non-last-player disconnects.
    UpdateCachedCounts(client);
}

public void OnClientPostAdminCheck(int client) {
    // A bot completing admin-check while PvB isn't running is never ours -
    // it's TF2's own vanilla quota-fill bot (tf_bot_quota_mode drifted back
    // to "fill" during the gap between a human disconnecting and PvB's next
    // LockBotQuota() call). Mirrors tfdb_guardian.sp's OnClientPostAdminCheck
    // handling of an unexpected bot joining mid-round.
    //
    // This is the reliable place to catch it, NOT the per-tick OnGameFrame
    // self-heal in RunPvBGameFrame(): OnGameFrame stops firing entirely while
    // the server is hibernating (0 real humans), which is exactly the state
    // right up until the reconnecting human finishes loading - so a stray
    // bot that spawned during that gap could sit unmanaged indefinitely.
    // OnClientPostAdminCheck runs as part of client-connect processing, which
    // has to work even on a hibernating server (that's how anyone can ever
    // reconnect to an empty server in the first place), so it isn't subject
    // to the same stall.
    if (IsFakeClient(client) && !BotEnabled && !DebugStatesMode
        && !IsClientReplay(client) && !IsClientSourceTV(client))
    {
        ServerCommand("tf_bot_kick all");
        LockBotQuota();
        return;
    }

    UpdateCachedCounts();
}

void UpdateCachedCounts(int excludeClient = 0) {
    // CachedRealCount = real humans on a PLAY team (RED/BLU). Spectators don't count.
    // Every consumer of CachedRealCount asks "how many humans can play?" - a
    // spec player is not a participant. Excluding them here is what makes
    // PvB auto-disable when the last human goes to spec (bug 2026-04-26).
    //
    // excludeClient lets OnClientDisconnect force-exclude the leaving player:
    // IsClientInGame() still reports true for them during OnClientDisconnect,
    // so without this they'd be counted as still present.
    int real = 0, fake = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == excludeClient) continue;
        if (!IsClientInGame(i)) continue;
        if (IsClientReplay(i) || IsClientSourceTV(i)) continue;
        if (IsFakeClient(i)) { fake++; continue; }
        int team = GetClientTeam(i);
        if (team == view_as<int>(TFTeam_Red) || team == view_as<int>(TFTeam_Blue)) real++;
    }
    CachedRealCount = real;
    CachedFakeCount = fake;
}

public void Frame_RefreshCachedCounts(any data) {
    UpdateCachedCounts();
}

void LockBotQuota() {
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    ServerCommand("tf_bot_auto_vacate 0");
}

void EnablePvB() {
    // Refuse to activate during a Guardian round. Three-gate check avoids the
    // "Plugin owning this native is currently paused" exception when the partner
    // plugin crashed/paused after load - FeatureStatus_Available alone isn't
    // enough because the native binding survives a pause; LibraryExists is the
    // authoritative runtime gate.
    if (LibraryExists("tfdb_guardian") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsGuardianActive") == FeatureStatus_Available &&
        TFDB_IsGuardianActive()) {
        CPrintToChatAll("{olive}[TFDB]{default} Cannot enable PvB while a Guardian round is active.");
        PvB_Log("[PvB] EnablePvB refused: TFDB_IsGuardianActive() returned true");
        return;
    }

    // DeathMatch (NER / Solo) mutual exclusion - DM swaps teams which corrupts
    // the PvB bot-vs-humans team layout. Same three-gate pattern as above.
    if (LibraryExists("tfdb_deathmatch") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsDeathMatchActive") == FeatureStatus_Available &&
        TFDB_IsDeathMatchActive()) {
        CPrintToChatAll("{olive}[TFDB]{default} Cannot enable PvB while DeathMatch (NER/Solo) is active.");
        PvB_Log("[PvB] EnablePvB refused: TFDB_IsDeathMatchActive() returned true");
        return;
    }

    // FFA mutex - FFA flips rocket teams to neutral. With PvB's bot-on-BLU layout,
    // the bot ends up neutral and friendly-fires its own teammates (paradoxical
    // since "team" means nothing in FFA, but the bot's decision tree doesn't model that). Plus
    // PvB assumes 1v1 bot-vs-human team semantics throughout. Guard at activation.
    if (LibraryExists("tfdb_ffa") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsFFAActive") == FeatureStatus_Available &&
        TFDB_IsFFAActive()) {
        CPrintToChatAll("{olive}[TFDB]{default} Cannot enable PvB while FFA is active.");
        PvB_Log("[PvB] EnablePvB refused: TFDB_IsFFAActive() returned true");
        return;
    }

    LockBotQuota();   // ensure no auto-replacement will fight our tf_bot_add
    ServerCommand("mp_autoteambalance 0");

    // Arena mode enforces mp_teams_unbalance_limit when ChangeClientTeam is called.
    // Set to 0 so we can freely shuffle humans between teams during activation
    // and steady-state enforcement. Restored in DisablePvB().
    ServerCommand("mp_teams_unbalance_limit 0");

    // CRITICAL: move all non-spectator humans to RED BEFORE spawning the bot on BLU.
    //
    // Arena warmup ("Waiting for N more players") gates on BOTH teams having ≥1
    // player. If we add the bot to BLU while the invoking human is also on BLU,
    // RED stays empty → arena never transitions out of warmup → the bot spawns
    // stuck dead → ManageTeams's forced respawn silently fails because the
    // round hasn't started. This is the deadlock Guardian avoids by spawning
    // its boss on BLU *after* humans have already landed on RED in OnRoundStart.
    //
    // Since PvB activates mid-round (menu pick or !pvb), we have to pre-seed
    // RED ourselves. One human on RED + one bot on BLU = CheckReadyRestart()
    // fires → arena_round_start → everyone respawns alive. The prior
    // ManageTeams-based enforcement runs forever as a backstop.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i)) continue;
        int teamBefore = GetClientTeam(i);
        // Gate on TEAM, not IsClientObserver. During arena pregame, dead/not-
        // yet-spawned players on BLU/RED are in freeze-cam observer mode but
        // they are NOT on the spectator team - IsClientObserver would skip
        // them incorrectly. We only leave actual spectators (team 1) alone.
        if (teamBefore <= view_as<int>(TFTeam_Spectator)) continue;
        if (teamBefore == view_as<int>(TFTeam_Red)) continue;
        ChangeClientTeam(i, view_as<int>(TFTeam_Red));
    }

    ServerCommand("tf_bot_add 1 Pyro blue easy \"%s\"", BotName);
    ServerCommand("tf_bot_difficulty 0");
    ServerCommand("tf_bot_keep_class_after_death 1");
    ServerCommand("tf_bot_taunt_victim_chance 0");
    ServerCommand("tf_bot_join_after_player 0");

    BotEnabled = true;
    BotNameDirty = true;
    UpdateCachedCounts();
    CPrintToChatAll("%t", "PvB_Entered", BotName);
    PvB_Log("[PvB] EnablePvB complete - humans forced to RED, bot added to BLU (bot=%s).", BotName);

    ApplyBotTypeSettings();
}

void DisablePvB() {
    if (DebugStatesMode) {
        StopDebugStates();
        return;
    }
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_teams_unbalance_limit 1");  // restore default - undo EnablePvB override
    ServerCommand("tf_bot_kick all");
    BotEnabled = false;
    PendingMaxPlayerDisable = false;  // bot is gone, drain any stale queue
    PendingHotSwapType = -1;          // any queued vote-swap is moot now
    CachedRocketRef = INVALID_ENT_REFERENCE;
    CPrintToChatAll("%t", "PvB_Left", BotName);
}

public Action Timer_StartDebugStates(Handle timer) {
    StartDebugStates();
    return Plugin_Stop;
}

void StartDebugStates() {
    // Safety cap: max bots per team = half of max_debug_states_bots, never > num classes
    int perTeam = NumBotTypes;
    int halfCap = CfgMaxDebugStatesBots / 2;
    if (perTeam > halfCap) perTeam = halfCap;
    if (perTeam < 1) perTeam = 1;
    // Force quota_mode to "normal" BEFORE doing anything else. In normal mode
    // the server never adds or removes bots on its own - only explicit
    // tf_bot_add / tf_bot_kick calls take effect. If the server.cfg (or another
    // plugin) left quota_mode as "fill" or "match", the engine will silently
    // trim our named bots to match the quota, which is what was happening.
    // ref: https://developer.valvesoftware.com/wiki/Bot_quota
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");               // Ignored in normal mode, set for safety
    ServerCommand("mp_teams_unbalance_limit 0");   // Allow 4v5 when player joins
    ServerCommand("mp_autoteambalance 0");

    // Disable hibernation during debug-states. When the server hibernates (empty or
    // via tf_allow_server_hibernation), SourceMod timers stop firing and TF2
    // kicks any connected bots - which would silently destroy a debug-states
    // session the moment the last human leaves. We restore defaults in
    // StopDebugStates. ref: https://developer.valvesoftware.com/wiki/Server_Hibernation
    ServerCommand("tf_allow_server_hibernation 0");

    ServerCommand("tf_bot_kick all");

    DebugStatesMode = true;
    BotEnabled = true;
    CommandDisabled = false;  // Clear so debug-states can manage its own state
    CommandForced = true;     // Prevent auto-disable from killing debug-states bots
    DebugStatesBotCount = 0;

    ServerCommand("tf_bot_difficulty 0");
    ServerCommand("tf_bot_keep_class_after_death 1");
    ServerCommand("tf_bot_taunt_victim_chance 0");
    ServerCommand("tf_bot_join_after_player 0");

    for (int i = 0; i < perTeam; i++) {
        char bluName[MAX_NAME_LENGTH];
        FormatEx(bluName, sizeof(bluName), "%s [BLU]", BotNames[i]);
        ServerCommand("tf_bot_add 1 Pyro blue easy \"%s\"", bluName);
        DebugStatesBotCount++;
    }

    for (int i = 0; i < perTeam; i++) {
        char redName[MAX_NAME_LENGTH];
        FormatEx(redName, sizeof(redName), "%s [RED]", BotNames[i]);
        ServerCommand("tf_bot_add 1 Pyro red easy \"%s\"", redName);
        DebugStatesBotCount++;
    }

    // Don't re-raise tf_bot_quota here - normal mode ignores it entirely,
    // and we don't want the engine auto-adding unnamed replacements anyway.

    if (perTeam < NumBotTypes) {
        CPrintToChatAll("%t", "PvB_DebugStates_Capped", CfgMaxDebugStatesBots, perTeam);
    }
    
    CPrintToChatAll("%t", "PvB_DebugStates_Spawned", perTeam * 2, perTeam);
    CPrintToChatAll("%t", "PvB_DebugStates_HowToStop");
    
    // Assign bot types based on name after they connect
    CreateTimer(2.0, Timer_AssignDebugStatesTypes, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AssignDebugStatesTypes(Handle timer) {
    if (!DebugStatesMode) return Plugin_Stop;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (!TFDB_IsLiveBot(i)) continue;

        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        
        // Match against config names to assign type
        // Check most specific first (in case names share substrings)
        bool matched = false;
        for (int t = NumBotTypes - 1; t >= 0; t--) {
            if (StrContains(name, BotNames[t]) != -1) {
                DebugStatesBotType[i] = t;
                matched = true;
                break;
            }
        }
        
        if (!matched) {
            // Fallback: match on class key substring, else default to first class
            DebugStatesBotType[i] = 0;
            for (int t = NumBotTypes - 1; t >= 0; t--) {
                if (BotClassKey[t][0] == '\0') continue;
                if (StrContains(name, BotClassKey[t], false) != -1) {
                    DebugStatesBotType[i] = t;
                    break;
                }
            }
        }
        ResetCombatState(i);
    }
    
    UpdateCachedCounts();
    return Plugin_Stop;
}

void StopDebugStates() {
    DebugStatesMode = false;
    BotEnabled = false;
    DebugStatesBotCount = 0;
    CachedRocketRef = INVALID_ENT_REFERENCE;

    // Restore TF2 cvars we stomped on for debug-states
    ServerCommand("tf_bot_quota 0");
    ServerCommand("tf_bot_kick all");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("tf_allow_server_hibernation 1");

    CPrintToChatAll("%t", "PvB_DebugStates_Ended");
}

public Action Cmd_BotTest(int client, int args)
{
    if (args == 0)
    {
        ReplyToCommand(client, "[PvB] Test squads: default, statue_v_world, gang_test, all_moves, orbit_test");
        ReplyToCommand(client, "[PvB] Usage: sm_bot_test <squad>  |  sm_bot_test stop");
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));

    if (StrEqual(arg, "stop", false))
    {
        TestModeActive = false;
        if (DebugStatesMode) StopDebugStates();
        if (DebugActive && DebugAutoStarted)
        {
            StopDebugLogging();
            DebugAutoStarted = false;
        }
        ReplyToCommand(client, "[PvB] Test mode stopped.");
        return Plugin_Handled;
    }

    // Stop any existing debug-states first
    if (DebugStatesMode) StopDebugStates();

    // Set critical cvars (same as StartDebugStates) to prevent hibernation
    // and engine auto-kick from destroying the bot session
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    ServerCommand("mp_teams_unbalance_limit 0");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("tf_allow_server_hibernation 0");
    ServerCommand("tf_bot_difficulty 0");
    ServerCommand("tf_bot_keep_class_after_death 1");
    ServerCommand("tf_bot_taunt_victim_chance 0");
    ServerCommand("tf_bot_join_after_player 0");

    // Parse squad spec: "red:class:count,class:count;blue:class:count,class:count"
    // Or use presets
    int redClasses[MAX_BOT_TYPES];
    int redCounts[MAX_BOT_TYPES];
    int blueClasses[MAX_BOT_TYPES];
    int blueCounts[MAX_BOT_TYPES];
    int redCount = 0;
    int blueCount = 0;

    if (StrEqual(arg, "default", false))
    {
        // 1 of each class on both teams
        for (int i = 0; i < NumBotTypes && i < 4; i++) {
            redClasses[redCount] = i;  redCounts[redCount] = 1;  redCount++;
            blueClasses[blueCount] = i;  blueCounts[blueCount] = 1;  blueCount++;
        }
    }
    else if (StrEqual(arg, "statue_v_world", false))
    {
        // 4 statues vs 4 universals
        redClasses[0] = 1; redCounts[0] = 4; redCount = 1;  // statue = type 1
        blueClasses[0] = 0; blueCounts[0] = 4; blueCount = 1; // universal = type 0
    }
    else if (StrEqual(arg, "gang_test", false))
    {
        // 1 midrange vs 5 aggressive
        redClasses[0] = 2; redCounts[0] = 1; redCount = 1;   // midrange = type 2
        blueClasses[0] = 3; blueCounts[0] = 5; blueCount = 1; // aggressive = type 3
    }
    else if (StrEqual(arg, "all_moves", false))
    {
        // 2 midrange bots - long rallies for move-set testing
        redClasses[0] = 2; redCounts[0] = 1; redCount = 1;
        blueClasses[0] = 2; blueCounts[0] = 1; blueCount = 1;
    }
    else if (StrEqual(arg, "orbit_test", false))
    {
        // universal vs statue - orbit triggers
        redClasses[0] = 0; redCounts[0] = 1; redCount = 1;    // universal
        blueClasses[0] = 1; blueCounts[0] = 1; blueCount = 1; // statue
    }
    else
    {
        ReplyToCommand(client, "[PvB] Unknown squad '%s'. Available: default, statue_v_world, gang_test, all_moves, orbit_test", arg);
        return Plugin_Handled;
    }

    // Start debug-states with custom squad
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    ServerCommand("mp_teams_unbalance_limit 0");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("tf_allow_server_hibernation 0");
    ServerCommand("tf_bot_kick all");

    DebugStatesMode = true;
    BotEnabled = true;
    CommandDisabled = false;
    CommandForced = true;
    DebugStatesBotCount = 0;
    TestModeActive = true;

    // Auto-start the CSV dataset for this squad - this is the only entry
    // point that's supposed to trigger it (see DebugLogBotTick/DebugLogDecision
    // below). Don't clobber a session the admin already started manually via
    // sm_botdebug - only stop what sm_bot_test itself started.
    if (!DebugActive)
    {
        DebugTotalLines = 0;
        StartDebugLogging();
        DebugAutoStarted = true;
        ReplyToCommand(client, "[PvB] Dataset logging started: %s", DebugLogPath);
    }

    // Spawn red bots - use the same tf_bot_add syntax as StartDebugStates
    for (int i = 0; i < redCount; i++) {
        for (int j = 0; j < redCounts[i]; j++) {
            char botName[64];
            FormatEx(botName, sizeof(botName), "%s [RED]", BotNames[redClasses[i]]);
            ServerCommand("tf_bot_add 1 Pyro red easy \"%s\"", botName);
            PendingTestTypes[DebugStatesBotCount] = redClasses[i];
            DebugStatesBotCount++;
        }
    }

    // Spawn blue bots
    for (int i = 0; i < blueCount; i++) {
        for (int j = 0; j < blueCounts[i]; j++) {
            char botName[64];
            FormatEx(botName, sizeof(botName), "%s [BLU]", BotNames[blueClasses[i]]);
            ServerCommand("tf_bot_add 1 Pyro blue easy \"%s\"", botName);
            PendingTestTypes[DebugStatesBotCount] = blueClasses[i];
            DebugStatesBotCount++;
        }
    }

    // Assign types after bots spawn
    PendingTestCount = DebugStatesBotCount;
    CreateTimer(2.0, Timer_AssignTestTypes, _, TIMER_FLAG_NO_MAPCHANGE);

    CReplyToCommand(client, "[PvB] Test squad '%s' spawned: %d red + %d blue bots", arg, DebugStatesBotCount - blueCount > 0 ? DebugStatesBotCount : 0, DebugStatesBotCount);
    return Plugin_Handled;
}

public Action Timer_AssignTestTypes(Handle timer)
{
    if (!TestModeActive) return Plugin_Stop;

    int assigned = 0;
    int pendingIdx = 0;
    for (int i = 1; i <= MaxClients && pendingIdx < PendingTestCount; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i)) continue;
        if (!IsClientBot(i)) continue;

        // In test mode, override the type regardless of current value
        DebugStatesBotType[i] = PendingTestTypes[pendingIdx];
        ApplyBotTypeSettings();
        pendingIdx++;
        assigned++;
    }
    TestModeActive = false;  // One-shot
    PvB_Log("[PVB-TEST] Assigned %d bot types (pending=%d)", assigned, PendingTestCount);
    return Plugin_Stop;
}

public void OnClientPutInServer(int client) {
    ResetPerConnectionState(client);
    if (IsFakeClient(client)) return;

    // See SOLO_CONFIRM_DELAY_MAPSTART: right after a map change, use a much
    // longer confirmation window so stragglers still loading in get counted
    // before we treat the first arrival as "alone" and offer the direct
    // one-click enable menu instead of requiring !votepvb.
    float delay = (GetEngineTime() - MapStartTime < SOLO_MAPSTART_WINDOW)
        ? SOLO_CONFIRM_DELAY_MAPSTART
        : SOLO_CONFIRM_DELAY_NORMAL;
    CreateTimer(delay, Timer_CheckPlayerJoin, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

bool IsGenuinelySolo() {
    return (GetClientCount(false) - CachedFakeCount) <= 1;
}

public Action Timer_CheckPlayerJoin(Handle timer, int userId) {
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Stop;

    if (!CfgEnabled) return Plugin_Stop;

    int humans = CachedRealCount;

    if (humans == 1 && IsGenuinelySolo() && !BotEnabled && !ClassVoteActive) {
        SoloMenuShown = true;
        ShowClassPickMenu(client);
    }
    else if (humans >= 2 && SoloMenuShown) {
        SoloMenuShown = false;
        if (BotEnabled && !DebugStatesMode) {
            DisablePvB();
            CPrintToChatAll("%t", "PvB_PlayerJoined_BotDisabled");
        }
    }
    
    return Plugin_Stop;
}

public void OnGameFrame() {
    if (!g_PvBProfileWindow.active) {
        RunPvBGameFrame();
        return;
    }
    g_PvBProfileFrames++;
    bool emitEvent = TFDB_ProfileTakeEvent(g_PvBProfileWindow);
    if (emitEvent) EnterProfilingEvent("TFDB/PvB", "GameFrame");
    RunPvBGameFrame();
    if (emitEvent) LeaveProfilingEvent();
}

void RunPvBGameFrame() {
    if (!CfgEnabled) return;

    // Invalidate per-frame caches (was in SpatialGrid_Rebuild)
    for (int i = 1; i <= MaxClients; i++) {
        CachedFrameEnemyValid[i] = false;
        CachedFrameThreatsValid[i] = false;
        CachedTickPosValid[i] = false;
    }

    static int tickCount = 0;
    tickCount++;
    
    bool isEvenTick = (tickCount % 2 == 0);

    if (BotEnabled) {
        if (isEvenTick) {
            if (DebugStatesMode) {
                ManageDebugStatesTeams();
            } else {
                ManageTeams();
            }
        }
    }

    if (MapChanged && BotEnabled && !DebugStatesMode) {
        DisablePvB();
        return;
    }

    int humans = CachedRealCount;

    if (humans == 0 && BotEnabled && !DebugStatesMode) {
        DisablePvB();
        CommandForced = false;
        CommandDisabled = false;
        return;
    }

    // A fake client present while PvB itself isn't running is never one we
    // manage - it's a stray/vanilla TF2 bot. This happens when the engine's
    // own bot-quota system reverts tf_bot_quota_mode back to "fill" (map cfg,
    // a mid-map exec, engine defaults) during the window between a human
    // disconnecting and PvB next calling LockBotQuota() (only re-asserted in
    // OnMapStart / before EnablePvB - nowhere on the disconnect->reconnect
    // path). The vanilla bot doesn't know dodgeball rules and just stands
    // there ("the bot isn't cleared, rejoin gives a bot that doesn't work").
    // Self-heal every tick: kick it and re-lock quota so it can't come back.
    if (CachedFakeCount > 0 && !BotEnabled && !DebugStatesMode) {
        ServerCommand("tf_bot_kick all");
        LockBotQuota();
        return;
    }

    if (CachedFakeCount > 1 && !DebugStatesMode) {
        DisablePvB();
        return;
    }

    int minP = CfgMinPlayers;
    int maxP = CfgMaxPlayers;

    if (isEvenTick && minP != 0 && humans > 0 && humans <= minP && !BotEnabled && !CommandDisabled && !MapChanged && !DebugStatesMode) {
        // Don't auto-enable. Timer_CheckPlayerJoin will show the class pick menu
        // after the player fully loads. The menu handler enables the bot.
        // Without this block, nothing happens here - we just skip auto-enable.
    }

    // Auto-disable when humans EXCEED max_players. Strict > (not >=) so a
    // vote-confirmed bot at exactly max_players doesn't get kicked the next
    // tick. Override with `!pvb` admin toggle (sets CommandForced).
    //
    // Deferred to round end (queued via PendingMaxPlayerDisable). Triggering
    // mid-round was jarring - bot would vanish mid-rally when a 3rd player
    // joins. The flag is checked + drained in OnRoundWin / OnRoundEnd.
    if (isEvenTick && maxP != 0 && humans > 0 && humans > maxP && BotEnabled && !CommandForced && !MapChanged && !DebugStatesMode) {
        if (!PendingMaxPlayerDisable) {
            PendingMaxPlayerDisable = true;
            // Guarded translation lookup - see sourcemod-practices/translations.md.
            if (TranslationPhraseExists("PvB_TooManyPlayers_DeferredDisable")) {
                CPrintToChatAll("%t", "PvB_TooManyPlayers_DeferredDisable", humans, maxP);
            } else {
                CPrintToChatAll("[TFDB] %d players exceeds PvB max (%d). Bot will leave at end of this round.", humans, maxP);
            }
        }
    }

    // === GANG BOOST CLEANUP (per-tick, state-independent) ===
    // TFCond_SpeedBuffAlly auto-expires, but we track GangBoostUntil so
    // the boost isn't re-armed every tick while still in GANG_ESCAPE.
    // Clean up the tracking flag on death/disconnect.
    float frameNow = GetEngineTime();
    for (int i = 1; i <= MaxClients; i++) {
        if (GangBoostUntil[i] <= 0.0) continue;
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) {
            GangBoostUntil[i] = 0.0;
            continue;
        }
        // The condition itself expires on its own; just clear our flag
        if (frameNow >= GangBoostUntil[i]) {
            GangBoostUntil[i] = 0.0;
        }
    }

    // Nav overlay (sm_navdraw). Self-throttled per client to
    // NAV_DRAW_INTERVAL; the loop below is just the dispatch, so this costs
    // nothing on the frames in between and nothing at all when nobody has it
    // switched on.
    for (int i = 1; i <= MaxClients; i++) {
        if (!NavDrawEnabled[i]) continue;
        if (!IsClientInGame(i)) { NavDrawEnabled[i] = false; continue; }
        DrawNavOverlayFor(i);
    }
}

void ManageTeams() {
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) continue;

        if (IsFakeClient(i) && !IsClientReplay(i) && !IsClientSourceTV(i)) {
            if (GetClientTeam(i) != 3) {
                ChangeClientTeam(i, 3);
            }
            // Force-respawn the bot if it's dead, the round is running, AND
            // we're still within the brief post-round-start grace window.
            // This MUST be outside the team-change check above - otherwise a
            // bot that's already on BLU but dead (common after round restart
            // when TF2's arena respawn wave doesn't pick up the bot) never
            // gets respawned, leaving it stuck dead for the entire round.
            //
            // The grace-window gate is the fix for a real gameplay bug: without
            // it, this branch fires on ANY bot death for the entire round, not
            // just the round-restart spawn-wave-miss it was written for - so
            // killing the bot mid-round got silently undone within 1-2 ticks,
            // before TF2's own arena logic could register BLU as eliminated
            // and award the round. That made the round unwinnable by killing
            // the bot; the only way it could ever end was the human dying.
            // 3s comfortably covers the spawn-wave-miss case (which resolves
            // within a frame or two of round start) without masking a
            // legitimate mid-round kill.
            //
            // During arena pregame, TF2_RespawnPlayer silently fails and
            // leaves the bot stuck in death limbo - the RoundState_RoundRunning
            // gate prevents calling it during pregame.
            if (!IsPlayerAlive(i) && GameRules_GetRoundState() == RoundState_RoundRunning
                && (GetGameTime() - RoundStartTime) < 3.0) {
                TF2_RespawnPlayer(i);
            }
            if (BotNameDirty) {
                SetClientInfo(i, "name", BotName);
            }
        }
        else if (BotEnabled) {
            // Gate on TEAM (not IsClientObserver). During arena pregame, humans
            // on BLU/RED are in freeze-cam "observer mode" but aren't on the
            // spec team - we must still force them to RED. IsClientObserver
            // would skip them incorrectly. Leave actual spec-team players alone.
            int humanTeam = GetClientTeam(i);
            if (humanTeam <= view_as<int>(TFTeam_Spectator)) continue;
            if (humanTeam != 2) {
                FakeClientCommand(i, "jointeam red");
                RequestFrame(Frame_PvBVerifyTeam, GetClientUserId(i));
            }
        }
    }
    BotNameDirty = false;
}

void Frame_PvBVerifyTeam(any userId) {
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client)) return;
    if (GetClientTeam(client) == view_as<int>(TFTeam_Red) && !IsPlayerAlive(client)) {
        TF2_RespawnPlayer(client);
    }
}

void ManageDebugStatesTeams() {
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) continue;

        if (IsFakeClient(i) && !IsClientReplay(i) && !IsClientSourceTV(i)) {
            // Bots stay on their spawned team (encoded in name suffix)
            char name[MAX_NAME_LENGTH];
            GetClientName(i, name, sizeof(name));

            int targetTeam = 3; // Default BLU
            if (StrContains(name, "[RED]") != -1) {
                targetTeam = 2;
            }

            if (GetClientTeam(i) != targetTeam) {
                ChangeClientTeam(i, targetTeam);
                TF2_RespawnPlayer(i);
            }
        }
        // Real humans during debug-states: no forced team - humans can freely join
        // RED or BLU to participate alongside the debug-states bots, or spectate to
        // watch bot-vs-bot rounds. The listener also allows any team choice in
        // debug-states mode.
    }
}

public Action Listener_BlockPvBTeamCollision(int client, const char[] command, int argc)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return Plugin_Continue;
    if (!BotEnabled && !DebugStatesMode) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;  // bots route through their own logic

    // autoteam: redirect to RED in normal PvB. In debug-states, leave autoteam alone
    // (the engine picks a team; human can participate on either side).
    if (strcmp(command, "autoteam", false) == 0 && !DebugStatesMode) {
        FakeClientCommandEx(client, "jointeam red");
        return Plugin_Handled;
    }

    // jointeam <arg>: only restrict in normal PvB mode (human-vs-bot 1v1 requires
    // humans on RED, bot on BLU). Debug-states mode allows humans on ANY team so a
    // real player can test/participate alongside the bot-vs-bot debug-states.
    if (strcmp(command, "jointeam", false) == 0 && argc >= 1) {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));

        bool shouldRedirect = false;
        if (!DebugStatesMode) {
            // Normal PvB: block blue/3/auto (allow red/2/spec/1)
            if (strcmp(arg, "blue", false) == 0 ||
                strcmp(arg, "3", false)    == 0 ||
                strcmp(arg, "auto", false) == 0) {
                shouldRedirect = true;
            }
        }
        // DebugStatesMode: no restrictions - humans can join any team.

        if (shouldRedirect) {
            FakeClientCommandEx(client, "jointeam red");
            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

public void Event_ObjectDeflected(Event event, const char[] name, bool dontBroadcast)
{
    int deflector = GetClientOfUserId(event.GetInt("userid"));
    if (deflector <= 0 || deflector > MaxClients) return;

    // Track enemy deflect timing for the punish feature
    // When a bot's enemy deflects, record the time
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientBot(i) && IsPlayerAlive(i) && IsClientInGame(i)) {
            int enemy = GetFrameEnemy(i);
            if (enemy == deflector) {
                EnemyLastDeflectTime[i] = GetGameTime();

                // COUNTER: pre-aim where the enemy's deflected rocket will come from.
                // Read the enemy's eye angles NOW (during their 0.045s drag delay,
                // their aim isn't locked yet - but it's the best prediction we have).
                int counterType = GetEffectiveBotType(i);
                if (CfgCounterChance[counterType] > 0
                    && GetRandomInt(1, 100) <= CfgCounterChance[counterType])
                {
                    float deflectorAng[3];
                    GetClientEyeAngles(deflector, deflectorAng);
                    // The rocket will go where the enemy is looking
                    // Predict the incoming angle as the enemy's current aim
                    // (invert Y because they're facing us)
                    CounterPreAimPitch[i] = -deflectorAng[0];  // invert pitch
                    CounterPreAimYaw[i] = NormalizeAngle(deflectorAng[1] + 180.0);  // face toward us
                    CounterPreAimUntil[i] = GetGameTime() + 0.30;  // 300ms pre-aim window
                }

                // BAIT: if a rocket is currently inbound to this bot, roll bait chance
                // The bait sidesteps at the last moment to make the enemy waste airblast
                int baitType = GetEffectiveBotType(i);
                if (CfgBaitChance[baitType] > 0 && !BaitRollConsumed[i]
                    && GetRandomInt(1, 100) <= CfgBaitChance[baitType])
                {
                    int rocketEnt = GetCachedRocketForClient(i);
                    if (rocketEnt > 0 && IsValidEntity(rocketEnt))
                    {
                        float rPos[3], botPos[3];
                        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
                        GetClientAbsOrigin(i, botPos);
                        float dist = GetVectorDistance(rPos, botPos);
                        if (dist <= CfgRocketEngageDist[baitType])
                        {
                            BaitRollConsumed[i] = true;
                            BaitUntil[i] = GetGameTime() + 0.20;  // 200ms bait window
                            BaitSidestepDir[i] = (GetRandomInt(0, 1) == 0) ? -1.0 : 1.0;
                        }
                    }
                }
            }
        }
    }

    if (!IsClientBot(deflector) && !Allowed[deflector]) return;

    // This is a REAL deflect - increment the actual deflect count
    DeflectCount[deflector]++;

    int botType = GetEffectiveBotType(deflector);

    // Reposition is an optional, per-class response to a CONFIRMED deflect.
    // Rolling here prevents missed airblasts from creating a fake post-deflect
    // episode and guarantees one decision per actual deflection event.
    if (CfgCanWalk[botType] && !ClassIsStatueLike[botType]
        && CfgRepositionChance[botType] > 0
        && GetRandomInt(1, 100) <= CfgRepositionChance[botType])
    {
        PostDeflectRepositionUntil[deflector] = GetEngineTime() + CfgRepositionTime[botType];
    }
    else
    {
        PostDeflectRepositionUntil[deflector] = 0.0;
    }

    char moveName[16];
    MoveSetName(LastMoveSet[deflector], moveName, sizeof(moveName));

    // Log the bot's eye angles at the moment of deflect - this is what
    // TFDB's delayed one-shot drag sample uses for the rocket's new direction.
    float eyeAng[3];
    GetClientEyeAngles(deflector, eyeAng);

    PvB_Log("[PVB-DEFLECT] bot=%d class=%s move=%s deflects=%d eye=[%.0f,%.0f] (REAL deflect)",
        deflector, BotClassKey[botType], moveName, DeflectCount[deflector],
        eyeAng[0], eyeAng[1]);
}

public Action Event_PlayerTeamChange(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;

    int newTeam = event.GetInt("team");

    // Refresh playing-human count on EVERY transition - this is what makes
    // PvB auto-disable when the last human goes to spec. The OnGameFrame
    // disable check at line ~2114 reads CachedRealCount; without this update
    // it stays stale until next disconnect / admincheck.
    //
    // Hook is EventHookMode_Pre - GetClientTeam still returns the OLD team at
    // this moment. Defer to next frame so UpdateCachedCounts sees the real
    // post-transition state. (2026-04-26 fix: bot lingered when last human
    // went to spec because the count was sampled pre-transition.)
    RequestFrame(Frame_RefreshCachedCounts);

    // Solo-player bot menu: when a human transitions FROM spec TO a play team
    // and is the only one playing, offer them the bot menu. The
    // OnClientPutInServer path covers fresh connections / map changes; this
    // covers the spec→play case which has no putinserver event. (2026-04-28
    // regression fix: pre-clientcheck migration the menu fired because old
    // counts included spectators; now it needs an explicit trigger.)
    if (newTeam == view_as<int>(TFTeam_Red) || newTeam == view_as<int>(TFTeam_Blue)) {
        // Defer 1.5s - gives Frame_RefreshCachedCounts time to land AND lets
        // the player's spawn settle so the menu doesn't pop during freezecam.
        CreateTimer(1.5, Timer_CheckPlayerJoin, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }

    // The remaining BLU collision backstop only matters in active PvB mode.
    if (!BotEnabled || DebugStatesMode) return Plugin_Continue;

    // Human on BLU is a collision → schedule force-to-RED backstop.
    // ManageTeams handles the steady-state, this covers the race where the
    // engine pre-empts ManageTeams (spawn points, arena queue, etc.).
    if (newTeam == view_as<int>(TFTeam_Blue)) {
        CreateTimer(0.1, Timer_PvBForceTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }

    return Plugin_Continue;
}

public any Native_IsPvBActive(Handle plugin, int numParams)
{
    return BotEnabled && !DebugStatesMode;
}

public any Native_IsPvBDebugStates(Handle plugin, int numParams)
{
    return DebugStatesMode;
}

public Action Timer_PvBForceTeam(Handle timer, any userId)
{
    // Only normal PvB mode force-moves humans off BLU (bot-only team).
    // Debug-states mode is permissive - humans can join any team to participate.
    if (!BotEnabled || DebugStatesMode) return Plugin_Stop;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Stop;

    if (GetClientTeam(client) == view_as<int>(TFTeam_Blue)) {
        FakeClientCommand(client, "jointeam red");
        RequestFrame(Frame_PvBVerifyTeam, userId);
    }

    return Plugin_Stop;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    RoundStartTime = GetGameTime();
    RoundDeflects = 0;
    for (int i = 1; i <= MaxClients; i++) {
        RoundDeflectsBot[i] = 0;
        DeflectCount[i] = 0;       // reset per-round deflect count
        PostDeflectUntil[i] = 0.0; // clear any stale drag
    }
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (!BotEnabled) return Plugin_Continue;

    int winner = event.GetInt("team");

    if (winner == 3) {
        BotWins++;
    } else if (winner == 2) {
        BotLosses++;
    }

    // === Per-round telemetry summary ===
    if (DebugActive) {
        int totalDeflects = 0;
        int maxDeflects = 0;
        int maxBot = -1;
        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i) && IsFakeClient(i)) {
                totalDeflects += DeflectCount[i];
                if (DeflectCount[i] > maxDeflects) {
                    maxDeflects = DeflectCount[i];
                    maxBot = i;
                }
            }
        }
        PvB_Log("[PVB-TEL-SUM] round_end winner=%s totalDeflects=%d maxDeflects=%d(bot=%d) botWins=%d botLosses=%d",
            winner == 2 ? "RED" : (winner == 3 ? "BLU" : "DRAW"),
            totalDeflects, maxDeflects, maxBot, BotWins, BotLosses);
    }

    // Drain the deferred "too many players" disable now - current rally has
    // ended, safe to kick the bot. OnGameFrame queues this when humans > maxP
    // so the bot finishes the round before disappearing.
    if (PendingMaxPlayerDisable && !DebugStatesMode) {
        PendingMaxPlayerDisable = false;
        // Re-check the condition - humans may have left during the round.
        if (CachedRealCount > CfgMaxPlayers && !CommandForced) {
            DisablePvB();
            CommandDisabled = false;
        }
    }

    // Drain pending hot-swap (vote-driven type change). Doing this AFTER the
    // disable check above means a hot-swap that was queued just before a
    // max-player overflow won't try to swap a bot that's about to be kicked.
    if (PendingHotSwapType >= 0 && BotEnabled && !DebugStatesMode) {
        ApplyHotSwap();
    } else {
        PendingHotSwapType = -1;  // bot got disabled before the swap could fire
    }

    return Plugin_Continue;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients) {
        // Only reset combat state if this spawn follows a real death.
        // NER (DeathMatch) calls TF2_RespawnPlayer to teleport the player
        // to a spawn point without killing them - this fires player_spawn
        // but the player didn't actually die. Resetting state on a NER
        // respawn causes bots to lose their deflect/orbit/guard state and
        // miss subsequent deflects (especially statue bots).
        if (DiedRecently[client])
        {
            ResetCombatState(client);
            DiedRecently[client] = false;
        }

        // Bots use map spawn points normally. The previous random teleport
        // (300-500 HU offset, random facing) threw bots into walls and pits
        // and ignored map layout. Clustering is handled by separation steering.

        // Guard post: remember where this life spawned so a can_walk=0 bot
        // (statue) that gets knocked off its spot by an airblast/panic push
        // can walk itself back instead of staying wherever it landed.
        if (IsClientBot(client)) {
            GetClientAbsOrigin(client, BotGuardPos[client]);
            BotGuardPosValid[client] = true;
        }

        // Any spawn (bot or human) is a valid seed position for this map's
        // one-time walkable-area scan. No-op once already running/done.
        StartNavScanIfNeeded();
    }
    return Plugin_Continue;
}

public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast) {
    char sNetworkID[64];
    event.GetString("networkid", sNetworkID, sizeof(sNetworkID));
    
    if (StrContains(sNetworkID, "BOT") == -1) {
        CreateTimer(2.0, Timer_ShowBotMenu, _, TIMER_FLAG_NO_MAPCHANGE);
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    if (!CfgEnabled) return Plugin_Continue;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (victim <= 0 || victim > MaxClients) return Plugin_Continue;

    // Mark that this player died - Event_PlayerSpawn should only reset
    // combat state if the player actually died (not NER respawn).
    DiedRecently[victim] = true;

    float outcomeSpeed = 0.0;
    int outcomeDeflects = 0;
    int outcomeRocketIndex = -1;
    TryGetRocketContext(event.GetInt("inflictor_entindex"), outcomeSpeed, outcomeDeflects, outcomeRocketIndex);

    // Bot died
    if (IsClientBot(victim)) {
        // Debug: log death with context for tuning
        if (DebugActive) {
            int botType = GetEffectiveBotType(victim);
            float now = GetEngineTime();
            float timeSinceAirblast = now - LastAirblastTime[victim];
            PvB_Log("[PVB-DEATH] bot=%d class=%s speed=%d deflects=%d timeSinceAirblast=%.2fs lastMove=%d",
                victim, BotClassKey[botType], RoundToFloor(outcomeSpeed), outcomeDeflects,
                timeSinceAirblast, LastMoveSet[victim]);

            char killerName[32];
            if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)) {
                GetClientName(attacker, killerName, sizeof(killerName));
            } else {
                strcopy(killerName, sizeof(killerName), "world");
            }
            char deathDetails[128];
            FormatEx(deathDetails, sizeof(deathDetails), "killer=%s speed=%d deflects=%d timeSinceAirblast=%.2fs lastMove=%d",
                killerName, RoundToFloor(outcomeSpeed), outcomeDeflects, timeSinceAirblast, LastMoveSet[victim]);
            DebugLogDecision(victim, "Death", deathDetails);
        }

        // In debug-states mode don't force red win
        if (!DebugStatesMode) {
            ForceRedWin();
        }

        TotalDeaths++;

        int botType = GetEffectiveBotType(victim);
        if (CfgSpeech && CfgClassSpeech[botType] && attacker > 0 && attacker <= MaxClients
            && attacker != victim && IsClientInGame(attacker))
        {
            SpeakTaunt(victim, attacker, TauntsBotDeath[botType], outcomeDeflects);
        }
    }

    // Bot killed a human (or another bot in debug-states)
    if (attacker > 0 && attacker <= MaxClients && attacker != victim && IsClientBot(attacker)) {
        TotalKills++;
        int botType = GetEffectiveBotType(attacker);
        if (CfgSpeech && CfgClassSpeech[botType] && !IsClientBot(victim))
        {
            SpeakTaunt(attacker, victim, TauntsPlayerDeath[botType], outcomeDeflects);
        }
    }

    return Plugin_Continue;
}

void SpeakTaunt(int speaker, int target, ArrayList lines, int deflects)
{
    if (lines == null || lines.Length == 0) return;
    if (!IsClientInGame(speaker) || !IsClientInGame(target)) return;

    char speech[256];
    lines.GetString(GetRandomInt(0, lines.Length - 1), speech, sizeof(speech));

    char targetName[MAX_NAME_LENGTH];
    GetClientName(target, targetName, sizeof(targetName));
    ReplaceString(targetName, sizeof(targetName), "\"", "");
    ReplaceString(targetName, sizeof(targetName), ";", "");
    ReplaceString(targetName, sizeof(targetName), "\n", "");
    ReplaceString(speech, sizeof(speech), "#playername", targetName);

    char number[16];
    IntToString(deflects, number, sizeof(number));
    ReplaceString(speech, sizeof(speech), "#deflects", number);
    IntToString(RoundDeflects, number, sizeof(number));
    ReplaceString(speech, sizeof(speech), "#rounddeflects", number);

    ReplaceString(speech, sizeof(speech), "\"", "'");
    ReplaceString(speech, sizeof(speech), ";", ",");

    char command[512];
    FormatEx(command, sizeof(command), "say \"%s\"", speech);
    FakeClientCommandEx(speaker, command);
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (StrEqual(classname, "tf_projectile_rocket") || StrEqual(classname, "tf_projectile_sentryrocket")) {
        CachedRocketRef = EntIndexToEntRef(entity);
        
        for (int i = 1; i <= MaxClients; i++) {
            MissedAirblast[i] = false;
            }
    }
}

public void OnEntityDestroyed(int entity) {
    if (entity > 0 && EntIndexToEntRef(entity) == CachedRocketRef) {
        CachedRocketRef = INVALID_ENT_REFERENCE;
    }
}

public void TFDB_OnRocketCreated(int iIndex, int iEntity) {
    #pragma unused iEntity
    #pragma unused iIndex
}

public void TFDB_OnRocketDeflect(int iIndex, int iEntity, int iOwner) {
    if (!BotEnabled && !DebugStatesMode) return;
    

    // If a BOT deflected, count it as confirmed
    if (iOwner > 0 && iOwner <= MaxClients && IsClientInGame(iOwner) && IsClientBot(iOwner)) {
            RoundDeflectsBot[iOwner]++;
        TotalDeflects++;
        RoundDeflects++;
        
            

    }

}

int CollectValidRocketIndexes(int indexes[MAX_ROCKETS]) {
    int activeCount = TFDB_GetRocketCount();
    int found = 0;
    for (int i = 0; i < MAX_ROCKETS && found < activeCount; i++) {
        if (!TFDB_IsValidRocket(i)) continue;
        indexes[found++] = i;
    }
    return found;
}

bool TryGetRocketContext(int entity, float &speed, int &deflects, int &rocketIndex) {
    if (entity <= 0 || !IsValidEntity(entity)) return false;

    #if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled()) {
        int index = TFDB_FindRocketByEntity(entity);
        if (index >= 0 && TFDB_IsValidRocket(index)) {
            speed = TFDB_GetRocketSpeed(index);
            deflects = TFDB_GetRocketDeflections(index);
            rocketIndex = index;
            return true;
        }
    }
    #endif

    if (!HasEntProp(entity, Prop_Send, "m_iDeflected")) return false;

    float velocity[3];
    GetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", velocity);
    speed = GetVectorLength(velocity);
    deflects = GetEntProp(entity, Prop_Send, "m_iDeflected");
    if (deflects < 0) deflects = 0;
    rocketIndex = -1;
    return true;
}

int GetCachedRocket() {
    if (CachedRocketRef == INVALID_ENT_REFERENCE) return -1;
    int entity = EntRefToEntIndex(CachedRocketRef);
    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity)) {
        CachedRocketRef = INVALID_ENT_REFERENCE;
        return -1;
    }
    return entity;
}

float GetRocketClosingSpeed(const float rocketPos[3], const float rocketVelocity[3], const float targetPos[3]) {
    float toTarget[3];
    MakeVectorFromPoints(rocketPos, targetPos, toTarget);
    if (NormalizeVector(toTarget, toTarget) <= 0.0) return 0.0;
    return GetVectorDotProduct(rocketVelocity, toTarget);
}

int GetCachedRocketForClient(int client) {
    float engineTime = GetEngineTime();

    // Return cached result if still fresh
    if (engineTime < NextRocketScan[client]) {
        int cached = ClientRocketRef[client];
        if (cached != INVALID_ENT_REFERENCE) {
            int ent = EntRefToEntIndex(cached);
            if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
                return ent;
            ClientRocketRef[client] = INVALID_ENT_REFERENCE;
        }
        return -1;
    }
    NextRocketScan[client] = engineTime + 0.1;
    if (g_PvBProfileWindow.active) g_PvBProfileRocketScans++;

    #if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled()) {
        float eyePos[3];
        GetClientEyePosition(client, eyePos);

        int bestEntity = -1;
        float bestDist = 999999.0;
        bool bestIsTargeted = false;

        int rocketIndexes[MAX_ROCKETS];
        int rocketCount = CollectValidRocketIndexes(rocketIndexes);
        for (int n = 0; n < rocketCount; n++) {
            int i = rocketIndexes[n];
            int ent = TFDB_GetRocketEntity(i);
            if (ent <= 0 || !IsValidEntity(ent)) continue;

            float rPos[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", rPos);
            float dist = GetVectorDistance(eyePos, rPos);

            int target = TFDB_GetRocketTarget(i);
            // target == client: rocket is genuinely homing toward this bot.
            // target <= 0: rocket has no current target - treat it as
            // non-targeted, NOT as "targeting me." The old `|| target <= 0`
            // made every untargeted rocket count as targeting this specific
            // bot, giving it priority over rockets actually targeting
            // other bots, and pinning the bot in DEFLECT for rockets that
            // were never aimed at it.
            bool targeted = (target == client);

            // Classify before ranking: a closer departing rocket must never
            // beat a farther rocket that is actually approaching the bot.
            if (!targeted) {
                if (dist >= 600.0) continue;
                float rVel[3];
                GetEntPropVector(ent, Prop_Data, "m_vecAbsVelocity", rVel);
                if (GetRocketClosingSpeed(rPos, rVel, eyePos) <= 200.0) continue;
            }

            // Targeted rockets always beat non-targeted
            if (targeted && !bestIsTargeted) {
                bestEntity = ent;
                bestDist = dist;
                bestIsTargeted = true;
            }
            else if (targeted == bestIsTargeted && dist < bestDist) {
                bestEntity = ent;
                bestDist = dist;
                bestIsTargeted = targeted;
            }
        }

        if (bestEntity != -1) {
            ClientRocketRef[client] = EntIndexToEntRef(bestEntity);
            return bestEntity;
        }

        ClientRocketRef[client] = INVALID_ENT_REFERENCE;
        return -1;
    }
    #endif

    // Fallback: no TFDB - use global cached rocket
    int entity = GetCachedRocket();
    if (entity != -1) {
        ClientRocketRef[client] = EntIndexToEntRef(entity);
    } else {
        ClientRocketRef[client] = INVALID_ENT_REFERENCE;
    }
    return entity;
}

int CountIncomingThreats(int client) {
    if (!IsPlayerAlive(client)) return 0;

    float bPos[3];
    GetClientAbsOrigin(client, bPos);
    int count = 0;

#if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled()) {
        if (g_PvBProfileWindow.active) g_PvBProfileThreatScans++;
        int rocketIndexes[MAX_ROCKETS];
        int rocketCount = CollectValidRocketIndexes(rocketIndexes);
        for (int n = 0; n < rocketCount; n++) {
            int i = rocketIndexes[n];
            int ent = TFDB_GetRocketEntity(i);
            if (ent <= 0 || !IsValidEntity(ent)) continue;

            float rPos[3], rVel[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin",      rPos);
            GetEntPropVector(ent, Prop_Data, "m_vecAbsVelocity", rVel);

            float dist = GetVectorDistance(bPos, rPos);
            if (dist > 1800.0) continue;  // too far to threaten within reaction

            if (GetRocketClosingSpeed(rPos, rVel, bPos) > 200.0) count++;
        }
    }
#endif

    return count;
}

/**
 * Count rockets actively threatening this client - close AND closing.
 * Used by STATE_PANIC to decide if multi-rocket survival mode is needed.
 * Throttled to the same 10Hz as GetCachedRocketForClient to avoid
 * per-tick MAX_ROCKETS scans.
 */
int CountActiveThreats(int client)
{
    if (!IsPlayerAlive(client)) return 0;

    float bPos[3];
    GetClientAbsOrigin(client, bPos);
    int count = 0;

#if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled())
    {
        int rocketIndexes[MAX_ROCKETS];
        int rocketCount = CollectValidRocketIndexes(rocketIndexes);
        for (int n = 0; n < rocketCount; n++)
        {
            int i = rocketIndexes[n];
            int ent = TFDB_GetRocketEntity(i);
            if (ent <= 0 || !IsValidEntity(ent)) continue;

            float rPos[3], rVel[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", rPos);
            GetEntPropVector(ent, Prop_Data, "m_vecAbsVelocity", rVel);

            float dist = GetVectorDistance(bPos, rPos);
            if (dist > CfgRocketEngageDist[GetEffectiveBotType(client)]) continue;

            if (GetRocketClosingSpeed(rPos, rVel, bPos) > 200.0) count++;
        }
    }
#endif

    return count;
}

bool IsRocketTargetingClient(int entity, int client) {
    #if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled()) {
        int rocketIdx = TFDB_FindRocketByEntity(entity);
        if (rocketIdx != -1) {
            int target = TFDB_GetRocketTarget(rocketIdx);
            return (target == client || target <= 0);
        }
    }
    #endif
    return true; // If no TFDB, assume it's ours
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon) {
    if (!g_PvBProfileWindow.active)
        return RunPvBCommand(client, buttons, impulse, vel, angles, weapon);

    g_PvBProfileCommands++;
    bool emitEvent = TFDB_ProfileTakeEvent(g_PvBProfileWindow);
    if (emitEvent) EnterProfilingEvent("TFDB/PvB", "RunCmd");
    Action result = RunPvBCommand(client, buttons, impulse, vel, angles, weapon);
    if (emitEvent) LeaveProfilingEvent();
    return result;
}

Action RunPvBCommand(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon) {
    // Real-player telemetry (see DebugLogPlayerState) - captured here,
    // BEFORE ProcessBotTick's guard below, because an ordinary human
    // (not IsBot, not Allowed[client]) never gets past that guard at all.
    // vel/angles/buttons at this point are the player's own raw usercmd,
    // untouched by anything in this plugin - exactly the real aim/move
    // input needed to compare against bot behavior for tuning.
    if (!IsFakeClient(client) && IsPlayerAlive(client)) {
        DebugLogPlayerState(client, vel, angles, buttons);
    }

    // === BEHAVIOR TREE ENTRY POINT ===
    // The bot decision logic is now structured as a behavior tree (ProcessBotTick).
    // RunPvBCommand remains as the thin entry point that builds the context
    // and delegates to the tree evaluator.

    PvBCommandContext ctx;
    ctx.client = client;
    ctx.isBot = IsClientBot(client);

    return ProcessBotTick(ctx, buttons, vel, angles);
}

void ResetCombatState(int client) {
    MissedAirblast[client] = false;
    RetreatingFromFloor[client] = false;
    WallSlideSign[client] = 0;
    // Per-episode commitments: clear on death/round change so a bot doesn't
    // resume a circle or an orbit it committed to in a previous life.
    StrafeSideSign[client] = 0;
    StrafeSideUntil[client] = 0.0;
    OrbitRolledRocket[client] = -1;
    OrbitAttemptedRocket[client] = -1;
    OrbitRollPassed[client] = false;
    OrbitStartedFromCooldown[client] = false;
    strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "n/a");
    LastEdgeOverride[client] = false;
    LastEdgeDistKnown[client] = false;
    BotGuardPosValid[client] = false;
    ReturningToGuard[client] = false;
    Evading[client] = false;
    CurrentEvadeAction[client] = EVADE_NONE;
    EvadeEnd[client] = 0.0;
    NextEvadeCheck[client] = 0.0;
    ClientRocketRef[client] = INVALID_ENT_REFERENCE;
    NextRocketScan[client] = 0.0;

    OrbitPhaseIdx[client] = ORBIT_PHASE_NONE;
    OrbitEpisodeEnd[client] = 0.0;
    OrbitLoopsRemaining[client] = 0;
    OrbitLoopsPlanned[client] = 0;
    OrbitPhaseStart[client] = 0.0;
    OrbitLoopDuration[client] = 0.0;


    // Gang-escape speed boost: clear the tracking flag. The speed buff
    // itself (TFCond_SpeedBuffAlly) is cleared by the engine on death.
    GangBoostUntil[client] = 0.0;

    // WASD micro-movement state
    WasdDirection[client] = 0;
    WasdTapUntil[client] = 0.0;
    WasdLastEnemyDist[client] = 0.0;
    WasdCommitted[client] = false;

    // Enhanced feature state
    EnemyMissWindow[client] = 0.0;
    EnemyAirblastCandidateTime[client] = 0.0;
    EnemyAirblastResolveTime[client] = 0.0;
    EnemyAirblastCandidateUserId[client] = 0;
    EnemyLastSecondaryReady[client] = 0.0;
    NextEnemyMissCheck[client] = 0.0;
    PostDeflectRepositionUntil[client] = 0.0;
    FeintUntil[client] = 0.0;
    FeintRocketRef[client] = -1;
    FeintRollConsumed[client] = false;
    StealRocketRef[client] = -1;
    StealRolledRocket[client] = -1;
    StealRollPassed[client] = false;
    EnemyLastDeflectTime[client] = 0.0;

    // New state tracking
    PanicUntil[client] = 0.0;
    PanicRollConsumed[client] = false;
    ChaseUntil[client] = 0.0;
    ChaseRollConsumed[client] = false;
    LastEnemyDist[client] = 0.0;
    LastEnemyDistTime[client] = 0.0;
    CounterPreAimUntil[client] = 0.0;
    CounterPreAimYaw[client] = 0.0;
    CounterPreAimPitch[client] = 0.0;
    BaitUntil[client] = 0.0;
    BaitRollConsumed[client] = false;
    BaitSidestepDir[client] = 0.0;

}

void ResetPerConnectionState(int client) {
    DiedRecently[client] = false;
    DebugStatesBotType[client] = 0;
    RoundDeflectsBot[client] = 0;
    ResetCombatState(client);
    Allowed[client] = false;
    ClassVoted[client] = -1;
    BotDebugTick[client] = 0;
    PlayerDebugTick[client] = 0;
    PlayerLastYaw[client] = 0.0;
    PlayerLastVelX[client] = 0.0;
    PlayerLastVelY[client] = 0.0;
    // Overlay is per-client and slot indices get reused on reconnect -
    // clear it so a new occupant doesn't inherit the previous admin's beams.
    NavDrawEnabled[client] = false;
    NavDrawRadius[client] = 0;
    NextNavDraw[client] = 0.0;
}

int FindClosestEnemy(int client) {
    float bPos[3];
    GetClientAbsOrigin(client, bPos);
    int botTeam = GetClientTeam(client);

    int closest = -1;
    float closestDist = 999999.0;

    for (int i = 1; i <= MaxClients; i++) {
        if (i == client) continue;
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        // In debug-states mode, bots CAN target other bots (that's the point)
        if (!DebugStatesMode && IsFakeClient(i)) continue;
        if (GetClientTeam(i) == botTeam) continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(bPos, pos);
        if (dist < closestDist) {
            closestDist = dist;
            closest = i;
        }
    }

    return closest;
}

bool IsClientBot(int client) {
    return (client > 0 && client <= MaxClients && TFDB_IsLiveBot(client));
}

int GetRealClientCount() {
    // Counts real humans on a PLAY team (RED/BLU). Spectators excluded - same
    // semantics as CachedRealCount (see UpdateCachedCounts).
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (TFDB_IsRealHumanPlaying(i)) {
            count++;
        }
    }
    return count;
}

void ForceRedWin() {
    int ent = FindEntityByClassname(-1, "game_round_win");
    if (ent < 1) {
        ent = CreateEntityByName("game_round_win");
        if (IsValidEntity(ent)) {
            DispatchSpawn(ent);
        } else {
            LogError("[PvB] Could not create game_round_win entity!");
            return;
        }
    }

    SetVariantInt(2);
    AcceptEntityInput(ent, "SetTeam");
    AcceptEntityInput(ent, "RoundWin");
}

public void OnPluginEnd() {
    NavCache_Reset();

    if (g_PvBProfileWindow.active) StopPvBProfile();
    if (BotEnabled) {
        DisablePvB();
    }
    if (DebugStatesMode) {
        StopDebugStates();
    }
    if (DebugActive) {
        StopDebugLogging();
    }

    // Belt-and-suspenders: always restore hibernation on unload, even if
    // StopDebugStates already ran or we never entered debug-states this session.
    // If the plugin is unloaded mid-session (sm plugins unload, crash recover,
    // reload), we must not leave the server stuck in no-hibernate state.
    ServerCommand("tf_allow_server_hibernation 1");

    for (int t = 0; t < MAX_BOT_TYPES; t++) {
        delete TauntsPlayerDeath[t];
        TauntsPlayerDeath[t] = null;
        delete TauntsBotDeath[t];
        TauntsBotDeath[t] = null;
    }
}
