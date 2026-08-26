// tfdb_pvb_config.inc - auto-extracted from tfdb_pvb.sp
// Do not edit directly; this is a split of the PvB plugin.

int GetEffectiveBotType(int client) {
    if (DebugStatesMode && IsFakeClient(client)) {
        return DebugStatesBotType[client];
    }
    return CfgBotType;
}

void LoadTauntFile(const char[] relPath, ArrayList list) {
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), relPath);

    File file = OpenFile(path, "r");
    if (file == null) {
        LogError("[PvB] Could not open %s", path);
        return;
    }

    char line[256];
    while (file.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] != '\0' && !(line[0] == '/' && line[1] == '/')) {
            list.PushString(line);
        }
    }
    delete file;
    PrintToServer("[PvB] Loaded %d lines from %s", list.Length, relPath);
}

void ApplyBotTypeSettings() {
    LoadBotTypeSettings(CfgBotType);
}

public Action Cmd_ReloadConfig(int client, int args) {
    LoadPvBConfig();
    // Re-apply settings to the live bot so cfg edits take effect without
    // requiring a hot-swap or map change. Previous behavior left runtime state
    // (BotName, weapon attributes, taunt lines) using stale pre-reload values
    // until next bot spawn. ApplyBotTypeSettings re-reads CfgBotType and
    // re-pushes settings.
    if (BotEnabled) {
        ApplyBotTypeSettings();
    }
    CReplyToCommand(client, "%t", "PvB_ConfigReloaded");
    return Plugin_Handled;
}

void GetBotTypeNameSafe(int botType, char[] buffer, int maxLen) {
    if (botType < 0 || botType >= NumBotTypes || BotDisplayName[botType][0] == '\0') {
        strcopy(buffer, maxLen, "Unknown");
        return;
    }
    strcopy(buffer, maxLen, BotDisplayName[botType]);
}

void StrLower(const char[] src, char[] dst, int maxLen) {
    int i = 0;
    for (; i < maxLen - 1 && src[i] != '\0'; i++) {
        int c = src[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        dst[i] = view_as<char>(c);
    }
    dst[i] = '\0';
}

int FindClassIndexByName(const char[] name) {
    if (name[0] == '\0') return -1;
    for (int i = 0; i < NumBotTypes; i++) {
        if (StrEqual(name, BotClassKey[i], false)) return i;
        if (StrEqual(name, BotDisplayName[i], false)) return i;
    }
    return -1;
}

void InitClassDefaults(int t) {
    // react_min / react_max removed - airblast fires at fixed 240 HU
    CfgMaxOrbitTime[t]        = 2.0;
    CfgMaxOrbitLoops[t]       = 3;
    CfgOrbitChance[t]         = 25;
    CfgMinOrbitTime[t]        = 0.5;
    CfgRocketEngageDist[t]    = 900.0;
    CfgDeflectRange[t]        = 300.0;
    // angle_random_chance / angle_random_strength removed - unused in BT code
    CfgEvadeChance[t]         = 40.0;
    CfgCqcFloorDist[t]        = 250.0;
    CfgCqcMinDist[t]          = 300.0;
    CfgCqcMaxDist[t]          = 600.0;
    CfgCqcRetreatDist[t]      = 250.0;
    CfgCqcMode[t]             = CQC_MODE_ARC;
    CfgCqcMaxArc[t]           = 70.0;
    CfgApproachGain[t]        = 2.5;
    CfgFireTimeToImpact[t]    = 0.50;
    CfgFireMinDist[t]         = 0.0;
    CfgSpikeUpPitch[t]        = -85.0;
    CfgSpikeDownPitch[t]      = 85.0;
    CfgAimEnemy[t]            = 0.22;
    CfgAimRocketNear[t]       = 0.92;
    CfgAimRocketFar[t]        = 0.28;
    CfgAimRocketNearDist[t]   = 240.0;
    CfgAimRocketFarDist[t]    = 900.0;
    CfgIdleChance[t]          = 40.0;
    CfgIdleDuration[t]        = 3.0;
    CfgLookAtPlayerTime[t]    = 1.5;
    CfgClassSpeech[t]         = true;
    CfgRepositionChance[t]    = 0;
    CfgRepositionTime[t]      = 1.0;
    ClassIsStatueLike[t]     = false;
    // Capabilities default ON - fallback class (see LoadPvBConfig error path)
    // gets all behaviors enabled. LoadSingleClass will demote to FALSE when a
    // class config removes the relevant keys.
    CfgCanOrbit[t]    = true;
    CfgCanEvade[t]    = true;
    CfgCanCqc[t]      = true;
    CfgCanIdle[t]     = true;
    CfgIdleAlways[t]  = false;
    BotNames[t][0]           = '\0';
    BotDisplayName[t][0]     = '\0';
    BotClassKey[t][0]        = '\0';
    SpeechPlayerDeath[t][0]  = '\0';
    SpeechBotDeath[t][0]     = '\0';
}

void LoadSingleClass(KeyValues kv, int t, const char[] sectionKey) {
    InitClassDefaults(t);

    // Store the lowercase section key and a display name (falls back to key)
    StrLower(sectionKey, BotClassKey[t], sizeof(BotClassKey[]));

    char displayBuf[64];
    kv.GetString("display_name", displayBuf, sizeof(displayBuf), "");
    if (displayBuf[0] == '\0') {
        // Capitalize first letter of the key for nicer display
        strcopy(displayBuf, sizeof(displayBuf), sectionKey);
        if (displayBuf[0] >= 'a' && displayBuf[0] <= 'z') {
            displayBuf[0] -= 32;
        }
    }
    strcopy(BotDisplayName[t], sizeof(BotDisplayName[]), displayBuf);

    // Per-class bot scoreboard name (falls back to display name)
    kv.GetString("bot_name", BotNames[t], sizeof(BotNames[]), displayBuf);

    // LEARNABLE tunings
    // react_min / react_max removed - airblast fires at fixed 240 HU
    // angle_random_chance / angle_random_strength removed - unused in BT code

    // -----------------------------------------------------------------------
    // Capability-by-presence detection.
    // KV readers return 0 / 0.0 when a key is absent. All our capability
    // values are strictly positive in normal use, so "value <= 0" cleanly
    // means "key absent OR explicitly disabled" - treated identically.
    // -----------------------------------------------------------------------

    // --- Orbit capability ---
    float orbitTime    = kv.GetFloat("orbit_time",      0.0);
    int   orbitLoops   = kv.GetNum("orbit_max_loops",   0);
    int   orbitChance  = kv.GetNum("orbit_chance",      0);  // used only as presence marker
    CfgCanOrbit[t]      = (orbitTime > 0.0) || (orbitLoops > 0) || (orbitChance > 0);
    if (orbitTime > 0.0 && orbitTime < 0.6) orbitTime = 0.6;
    if (orbitTime > 10.0) orbitTime = 10.0;
    if (orbitLoops > 8) orbitLoops = 8;
    CfgMaxOrbitTime[t]  = (orbitTime > 0.0) ? orbitTime  : 2.0;
    CfgMaxOrbitLoops[t] = (orbitLoops > 0)  ? orbitLoops : 3;

    // --- Evade capability ---
    int evadeChance    = kv.GetNum("evade_chance", 0);
    CfgCanEvade[t]     = (evadeChance > 0);
    CfgEvadeChance[t]  = float(evadeChance);

    // --- CQC capability (any one key triggers CQC-aware movement) ---
    float cqcFloor    = kv.GetFloat("cqc_floor_dist",   0.0);
    float cqcMin      = kv.GetFloat("cqc_min_dist",     0.0);
    float cqcMax      = kv.GetFloat("cqc_max_dist",     0.0);
    float cqcRetreat  = kv.GetFloat("cqc_retreat_dist", 0.0);
    CfgCanCqc[t]      = (cqcFloor > 0.0) || (cqcMin > 0.0) || (cqcMax > 0.0) || (cqcRetreat > 0.0);
    CfgCqcFloorDist[t]   = (cqcFloor   > 0.0) ? cqcFloor   : 250.0;
    CfgCqcMinDist[t]     = (cqcMin     > 0.0) ? cqcMin     : 300.0;
    CfgCqcMaxDist[t]     = (cqcMax     > 0.0) ? cqcMax     : 600.0;
    CfgCqcRetreatDist[t] = (cqcRetreat > 0.0) ? cqcRetreat : 250.0;

    // --- Idle capability + idle-always mode ---
    int idleChance     = kv.GetNum("idle_chance", 0);
    CfgCanIdle[t]      = (idleChance > 0);
    CfgIdleChance[t]   = float(idleChance);
    CfgIdleAlways[t]   = (idleChance >= 100);
    CfgIdleDuration[t] = kv.GetFloat("idle_duration", 3.0);

    CfgLookAtPlayerTime[t]    = kv.GetFloat("look_at_player_time", 1.5);
    CfgClassSpeech[t]         = (kv.GetNum("speech", 1) != 0);

    // "statue_like" flag: forces this class into permanent idle movement mode.
    // Auto-detected for backward compat when the lowercase key contains "statue".
    bool statueLike = (kv.GetNum("statue_like", 0) != 0);
    if (!statueLike && StrContains(BotClassKey[t], "statue") != -1) {
        statueLike = true;
    }
    ClassIsStatueLike[t] = statueLike;

    // Sanity enforcement
    if (CfgCqcRetreatDist[t] < CfgCqcFloorDist[t]) {
        CfgCqcRetreatDist[t] = CfgCqcFloorDist[t];
    }
    if (CfgCqcMinDist[t] < CfgCqcFloorDist[t]) {
        CfgCqcMinDist[t] = CfgCqcFloorDist[t] + 50.0;
    }

    // === BEHAVIOR TREE CONFIG ===
    CfgCanWalk[t]                  = (kv.GetNum("can_walk", 1) != 0);
    CfgMaxDeflectCount[t]         = kv.GetNum("max_deflect_count", 0);
    CfgMaxDeflectSpeed[t]          = kv.GetFloat("max_deflect_speed", 0.0);
    CfgOrbitSpeedThreshold[t]     = kv.GetFloat("orbit_speed_threshold", 2000.0);
    // orbit_chance is finally load-bearing. It was read purely as a presence
    // marker for CfgCanOrbit while the actual "random chance gate" tested
    // CfgMaxOrbitLoops <= 0 - no roll anywhere. Server owners had 25/30/35
    // configured across three classes, doing nothing.
    CfgOrbitChance[t]             = kv.GetNum("orbit_chance", 25);
    if (CfgOrbitChance[t] < 0) CfgOrbitChance[t] = 0;
    if (CfgOrbitChance[t] > 100) CfgOrbitChance[t] = 100;
    CfgMinOrbitTime[t]            = kv.GetFloat("orbit_time_min", 0.5);
    if (CfgCanOrbit[t])
    {
        if (CfgMinOrbitTime[t] < 0.6) CfgMinOrbitTime[t] = 0.6;
        if (CfgMinOrbitTime[t] > CfgMaxOrbitTime[t]) CfgMinOrbitTime[t] = CfgMaxOrbitTime[t];
    }
    CfgRocketEngageDist[t]        = kv.GetFloat("rocket_engage_dist", 900.0);
    CfgDeflectRange[t]            = kv.GetFloat("deflect_range", 300.0);
    CfgJumpOverChance[t]          = kv.GetNum("jump_over_chance", 15);
    CfgGangEscapeRange[t]         = kv.GetFloat("gang_escape_range", 400.0);
    CfgGangSpeedBoostMult[t]      = kv.GetFloat("gang_speed_boost_mult", 1.0);

    // cqc_mode: how the bot behaves once it is INSIDE the distance band.
    // Spelled out rather than numeric so a server owner editing pvb.cfg can
    // tell what it does without consulting source.
    char cqcModeBuf[16];
    kv.GetString("cqc_mode", cqcModeBuf, sizeof(cqcModeBuf), "arc");
    if (StrEqual(cqcModeBuf, "mirror", false))    CfgCqcMode[t] = CQC_MODE_MIRROR;
    else if (StrEqual(cqcModeBuf, "hold", false)) CfgCqcMode[t] = CQC_MODE_HOLD;
    else                                          CfgCqcMode[t] = CQC_MODE_ARC;
    CfgCqcMaxArc[t] = kv.GetFloat("cqc_max_arc", 70.0);
    CfgApproachGain[t] = kv.GetFloat("cqc_approach_gain", 2.5);
    CfgFireTimeToImpact[t] = kv.GetFloat("fire_time_to_impact", 0.50);
    CfgFireMinDist[t]      = kv.GetFloat("fire_min_dist",         0.0);
    CfgSpikeUpPitch[t]   = kv.GetFloat("spike_up_pitch",   -85.0);
    CfgSpikeDownPitch[t] = kv.GetFloat("spike_down_pitch",  85.0);

    // Aim speeds. 0..1 per-tick approach fraction toward the target angle.
    CfgAimEnemy[t]          = kv.GetFloat("aim_speed_enemy",       0.22);
    CfgAimRocketNear[t]     = kv.GetFloat("aim_speed_rocket_near", 0.92);
    CfgAimRocketFar[t]      = kv.GetFloat("aim_speed_rocket_far",  0.28);
    CfgAimRocketNearDist[t] = kv.GetFloat("aim_rocket_near_dist",  240.0);
    CfgAimRocketFarDist[t]  = kv.GetFloat("aim_rocket_far_dist",   900.0);
    CfgEvadeStrafeEnabled[t]      = (kv.GetNum("evade_strafe_enabled", 1) != 0);

    // --- Enhanced feature config ---
    CfgTimingVariance[t]     = kv.GetFloat("timing_variance", 0.0);
    CfgOrbitBreakChance[t]    = kv.GetNum("orbit_break_chance", 0);
    CfgPunishChance[t]        = kv.GetNum("punish_chance", 0);
    CfgRepositionChance[t]     = kv.GetNum("reposition_chance", 0);
    if (CfgRepositionChance[t] < 0) CfgRepositionChance[t] = 0;
    if (CfgRepositionChance[t] > 100) CfgRepositionChance[t] = 100;
    CfgRepositionTime[t]       = kv.GetFloat("reposition_time", 1.0);
    if (CfgRepositionTime[t] < 0.2) CfgRepositionTime[t] = 0.2;
    if (CfgRepositionTime[t] > 3.0) CfgRepositionTime[t] = 3.0;
    CfgFeintChance[t]         = kv.GetNum("feint_chance", 0);
    CfgStealChance[t]         = kv.GetNum("steal_chance", 0);
    CfgEdgePressureChance[t]  = kv.GetNum("edge_pressure_chance", 0);
    CfgPanicChance[t]         = kv.GetNum("panic_chance", 0);
    CfgChaseChance[t]         = kv.GetNum("chase_chance", 0);
    CfgCounterChance[t]       = kv.GetNum("counter_chance", 0);
    CfgBaitChance[t]          = kv.GetNum("bait_chance", 0);
    if (CfgPunishChance[t] < 0) CfgPunishChance[t] = 0;
    if (CfgPunishChance[t] > 100) CfgPunishChance[t] = 100;
    if (CfgFeintChance[t] < 0) CfgFeintChance[t] = 0;
    if (CfgFeintChance[t] > 100) CfgFeintChance[t] = 100;
    if (CfgStealChance[t] < 0) CfgStealChance[t] = 0;
    if (CfgStealChance[t] > 100) CfgStealChance[t] = 100;
    if (CfgEdgePressureChance[t] < 0) CfgEdgePressureChance[t] = 0;
    if (CfgEdgePressureChance[t] > 100) CfgEdgePressureChance[t] = 100;

    // Move set weights (0 = disabled via capability-by-presence)
    CfgMoveWeight[0][t] = kv.GetNum("move_normal",    30);  // MOVE_NORMAL
    CfgMoveWeight[1][t] = kv.GetNum("move_wave",      15);  // MOVE_WAVE
    CfgMoveWeight[2][t] = kv.GetNum("move_upspike",   20);  // MOVE_UPSPIKE
    CfgMoveWeight[3][t] = kv.GetNum("move_downspike", 10);  // MOVE_DOWNSPIKE
    CfgMoveWeight[4][t] = kv.GetNum("move_bounce",     10);  // MOVE_BOUNCE
    CfgMoveWeight[5][t] = kv.GetNum("move_direct",     10);  // MOVE_DIRECT
    CfgMoveWeight[6][t] = kv.GetNum("move_backfire",    5);  // MOVE_BACKFIRE

    // If statue_like, force can_walk off. Same for evade_strafe - a
    // statue is meant to hold its guard position and just deflect in
    // place; strafing off to the side to buy time on cooldown directly
    // contradicts that identity, so this is forced off regardless of the
    // per-class cfg value rather than left to the mapper to remember.
    if (statueLike) {
        CfgCanWalk[t] = false;
        CfgEvadeStrafeEnabled[t] = false;
    }
}

void LoadPvBConfig() {
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/dodgeball/pvb.cfg");

    KeyValues kv = new KeyValues("PvB");
    if (!kv.ImportFromFile(configPath)) {
        LogError("[PvB] Could not load config file: %s", configPath);
        delete kv;
        // Fall back to a single universal default so the plugin still works
        NumBotTypes = 1;
        InitClassDefaults(0);
        strcopy(BotClassKey[0], sizeof(BotClassKey[]), "universal");
        strcopy(BotDisplayName[0], sizeof(BotDisplayName[]), "Universal");
        strcopy(BotNames[0], sizeof(BotNames[]), "Mann Co. Bot");
        strcopy(BotName, sizeof(BotName), BotNames[0]);
        CfgBotType = 0;
        BotNameDirty = true;

        // Keep the built-in universal speech usable even when pvb.cfg is
        // temporarily missing; release packages still ship the full config.
        strcopy(SpeechPlayerDeath[0], sizeof(SpeechPlayerDeath[]),
            "configs/dodgeball/speech/speech_universal_kill.txt");
        strcopy(SpeechBotDeath[0], sizeof(SpeechBotDeath[]),
            "configs/dodgeball/speech/speech_universal_death.txt");
        LoadTauntFile(SpeechPlayerDeath[0], TauntsPlayerDeath[0]);
        LoadTauntFile(SpeechBotDeath[0], TauntsBotDeath[0]);
        return;
    }

    // --- Phase 1: read global "settings" section ---
    char requestedType[32] = "0";
    if (kv.JumpToKey("settings")) {
        CfgEnabled      = (kv.GetNum("enabled", 1) != 0);
        VoteMaxPlayers = kv.GetNum("vote_max_players", 12);
        CfgMinPlayers   = kv.GetNum("min_players", 1);
        CfgMaxPlayers   = kv.GetNum("max_players", 2);
        CfgSpeech       = (kv.GetNum("speech", 1) != 0);
        kv.GetString("bot_type", requestedType, sizeof(requestedType), "0");

        CfgMaxDebugStatesBots   = kv.GetNum("max_debug_states_bots",   16);
        if (CfgMaxDebugStatesBots < 2)  CfgMaxDebugStatesBots = 2;
        if (CfgMaxDebugStatesBots > 30) CfgMaxDebugStatesBots = 30;
        kv.GoBack();
    }

    // --- Phase 2: iterate "classes" section and load every class we find ---
    NumBotTypes = 0;

    // Clear taunt ArrayLists (they are pre-allocated in OnPluginStart)
    for (int t = 0; t < MAX_BOT_TYPES; t++) {
        if (TauntsPlayerDeath[t] != null) TauntsPlayerDeath[t].Clear();
        if (TauntsBotDeath[t] != null)    TauntsBotDeath[t].Clear();
    }

    // Per-settings legacy name overrides (only honored when a class with the
    // matching key exists). We collect them here and apply after class load.
    char legacyNames[4][MAX_NAME_LENGTH];
    char legacyKeys[4][16];
    strcopy(legacyKeys[0], sizeof(legacyKeys[]), "universal");
    strcopy(legacyKeys[1], sizeof(legacyKeys[]), "statue");
    strcopy(legacyKeys[2], sizeof(legacyKeys[]), "midrange");
    strcopy(legacyKeys[3], sizeof(legacyKeys[]), "aggressive");
    if (kv.JumpToKey("settings")) {
        kv.GetString("bot_name_universal",  legacyNames[0], sizeof(legacyNames[]), "");
        kv.GetString("bot_name_statue",     legacyNames[1], sizeof(legacyNames[]), "");
        kv.GetString("bot_name_midrange",   legacyNames[2], sizeof(legacyNames[]), "");
        kv.GetString("bot_name_aggressive", legacyNames[3], sizeof(legacyNames[]), "");
        kv.GoBack();
    }

    if (kv.JumpToKey("classes")) {
        if (kv.GotoFirstSubKey()) {
            do {
                if (NumBotTypes >= MAX_BOT_TYPES) {
                    LogError("[PvB] Too many classes in config (max %d), stopping", MAX_BOT_TYPES);
                    break;
                }
                char secName[32];
                if (!kv.GetSectionName(secName, sizeof(secName))) continue;
                if (secName[0] == '\0') continue;

                LoadSingleClass(kv, NumBotTypes, secName);
                PvB_Log("[PvB] Loaded class [%d] '%s' -> %s",
                    NumBotTypes, BotClassKey[NumBotTypes], BotNames[NumBotTypes]);
                NumBotTypes++;
            } while (kv.GotoNextKey());
            kv.GoBack(); // undo GotoFirstSubKey
        }
        kv.GoBack(); // undo JumpToKey("classes")
    }

    // If the config had no classes section or an empty one, synthesize a default
    if (NumBotTypes == 0) {
        InitClassDefaults(0);
        strcopy(BotClassKey[0], sizeof(BotClassKey[]), "universal");
        strcopy(BotDisplayName[0], sizeof(BotDisplayName[]), "Universal");
        strcopy(BotNames[0], sizeof(BotNames[]), "Mann Co. Bot");
        NumBotTypes = 1;
        PvB_Log("[PvB] No classes in config, synthesized 'universal' default");
    }

    // Apply legacy bot_name_* overrides to matching classes
    for (int i = 0; i < 4; i++) {
        if (legacyNames[i][0] == '\0') continue;
        int idx = FindClassIndexByName(legacyKeys[i]);
        if (idx >= 0) {
            strcopy(BotNames[idx], sizeof(BotNames[]), legacyNames[i]);
        }
    }

    // --- Phase 3: resolve active class from "bot_type" setting ---
    // Accepts numeric index OR class key name (case-insensitive)
    int resolved = -1;
    if (requestedType[0] >= '0' && requestedType[0] <= '9') {
        int asInt = StringToInt(requestedType);
        if (asInt >= 0 && asInt < NumBotTypes) resolved = asInt;
    }
    if (resolved < 0) resolved = FindClassIndexByName(requestedType);
    if (resolved < 0) resolved = 0;
    CfgBotType = resolved;

    // --- Phase 4: per-class speech files ---
    LoadSpeechConfig(kv);

    delete kv;

    strcopy(BotName, sizeof(BotName), BotNames[CfgBotType]);
    BotNameDirty = true;
    PvB_Log("[PvB] Active class: [%d] %s (%s)",
        CfgBotType, BotClassKey[CfgBotType], BotNames[CfgBotType]);
}

void LoadBotTypeSettings(int botType) {
    if (botType < 0 || botType >= NumBotTypes) {
        LogError("[PvB] LoadBotTypeSettings: invalid index %d (have %d classes)", botType, NumBotTypes);
        return;
    }
    CfgBotType = botType;
    strcopy(BotName, sizeof(BotName), BotNames[botType]);
    BotNameDirty = true;
    PvB_Log("[PvB] Switched to class [%d] %s", botType, BotClassKey[botType]);
}

void LoadSpeechConfig(KeyValues kv) {
    char defaultPlayerDeath[PLATFORM_MAX_PATH] = "configs/dodgeball/speech/speech_universal_kill.txt";
    char defaultBotDeath[PLATFORM_MAX_PATH]    = "configs/dodgeball/speech/speech_universal_death.txt";

    // ArrayLists were already cleared in LoadPvBConfig
    bool haveSpeechSection = kv.JumpToKey("speech");

    for (int t = 0; t < NumBotTypes; t++) {
        char playerDeathPath[PLATFORM_MAX_PATH];
        char botDeathPath[PLATFORM_MAX_PATH];
        strcopy(playerDeathPath, sizeof(playerDeathPath), defaultPlayerDeath);
        strcopy(botDeathPath, sizeof(botDeathPath), defaultBotDeath);

        if (haveSpeechSection) {
            char keyPlayerDeath[96], keyBotDeath[96];
            FormatEx(keyPlayerDeath, sizeof(keyPlayerDeath), "%s_playerdeath", BotClassKey[t]);
            FormatEx(keyBotDeath,    sizeof(keyBotDeath),    "%s_botdeath",    BotClassKey[t]);
            kv.GetString(keyPlayerDeath, playerDeathPath, sizeof(playerDeathPath), defaultPlayerDeath);
            kv.GetString(keyBotDeath,    botDeathPath,    sizeof(botDeathPath),    defaultBotDeath);
        }

        // Pre-flight existence check with resolved SM path, fall back to
        // universal if the configured file is missing. BuildPath + FileExists
        // is the idiomatic SM 1.12 pattern for config-driven file loading.
        char resolved[PLATFORM_MAX_PATH];
        BuildPath(Path_SM, resolved, sizeof(resolved), playerDeathPath);
        if (!FileExists(resolved)) {
            PvB_Log("[PvB] speech file missing for %s_playerdeath: %s - using universal fallback",
                BotClassKey[t], playerDeathPath);
            strcopy(playerDeathPath, sizeof(playerDeathPath), defaultPlayerDeath);
        }
        BuildPath(Path_SM, resolved, sizeof(resolved), botDeathPath);
        if (!FileExists(resolved)) {
            PvB_Log("[PvB] speech file missing for %s_botdeath: %s - using universal fallback",
                BotClassKey[t], botDeathPath);
            strcopy(botDeathPath, sizeof(botDeathPath), defaultBotDeath);
        }

        strcopy(SpeechPlayerDeath[t], sizeof(SpeechPlayerDeath[]), playerDeathPath);
        strcopy(SpeechBotDeath[t],    sizeof(SpeechBotDeath[]),    botDeathPath);

        LoadTauntFile(playerDeathPath, TauntsPlayerDeath[t]);
        LoadTauntFile(botDeathPath,    TauntsBotDeath[t]);
    }

    if (haveSpeechSection) kv.GoBack();
}
