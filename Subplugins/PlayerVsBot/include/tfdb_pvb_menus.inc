// tfdb_pvb_menus.inc — auto-extracted from tfdb_pvb.sp
// Do not edit directly; this is a split of the PvB plugin.

public Action Cmd_BotAdmin(int client, int args) {
    // Menu commands require an active client to display to. RCON path is fatal.
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) {
        CReplyToCommand(client, "%t", "PvB_ConsoleOnly_Admin");
        return Plugin_Handled;
    }

    ShowAdminMainMenu(client);
    return Plugin_Handled;
}

void ShowAdminMainMenu(int client) {
    Menu menu = new Menu(MenuHandler_AdminMain);
    char title[128];
    FormatEx(title, sizeof(title), "%T", "PvB_Menu_Admin_Panel", client,
        BotEnabled ? "ACTIVE" : "INACTIVE",
        DebugStatesMode ? "TRAINING" : "Normal");
    menu.SetTitle(title);
    
    menu.AddItem("toggle", BotEnabled ? "Disable Bot" : "Enable Bot");
    menu.AddItem("type", "Change Bot Type");
    menu.AddItem("stats", "View Bot Stats");
    menu.AddItem("reload", "Reload Config");
    menu.AddItem("speech", "Speech Settings");
    
    menu.ExitButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_AdminMain(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        
        if (StrEqual(info, "toggle")) {
            if (!BotEnabled) {
                EnablePvB();
                CommandForced = true;
                CommandDisabled = false;
            } else {
                DisablePvB();
                CommandDisabled = true;
                CommandForced = false;
            }
            ShowAdminMainMenu(param1);
        }
        else if (StrEqual(info, "type")) {
            ShowAdminTypeMenu(param1);
        }
        else if (StrEqual(info, "stats")) {
            ShowBotStatsMenu(param1);
        }
        else if (StrEqual(info, "reload")) {
            LoadPvBConfig();
            CPrintToChat(param1, "%t", "PvB_ConfigReloaded");
            ShowAdminMainMenu(param1);
        }
        else if (StrEqual(info, "brain")) {
            ShowAdminBrainMenu(param1);
        }
        else if (StrEqual(info, "speech")) {
            ShowAdminSpeechMenu(param1);
        }
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void ShowAdminTypeMenu(int client) {
    Menu menu = new Menu(MenuHandler_AdminType);

    char currentName[32];
    GetBotTypeNameSafe(CfgBotType, currentName, sizeof(currentName));
    char title[96];
    FormatEx(title, sizeof(title), "%T", "PvB_Menu_Choose_Type", client, currentName);
    menu.SetTitle(title);

    for (int t = 0; t < NumBotTypes; t++) {
        char info[8], display[96];
        IntToString(t, info, sizeof(info));
        if (t == CfgBotType) {
            FormatEx(display, sizeof(display), ">> %s <<", BotDisplayName[t]);
        } else {
            strcopy(display, sizeof(display), BotDisplayName[t]);
        }
        menu.AddItem(info, display);
    }

    menu.ExitBackButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_AdminType(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[8];
        menu.GetItem(param2, info, sizeof(info));
        int type = StringToInt(info);
        LoadBotTypeSettings(type);
        
        char typeName[32];
        GetBotTypeNameSafe(CfgBotType, typeName, sizeof(typeName));
        CPrintToChatAll("%t", "PvB_Admin_TypeChanged", typeName);
        ShowAdminMainMenu(param1);
    }
    else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowAdminMainMenu(param1);
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void ShowAdminBrainMenu(int client) {
    Menu menu = new Menu(MenuHandler_AdminBrain);
    char title[64];
    FormatEx(title, sizeof(title), "%T", "PvB_Menu_Brain_Mgmt", client);
    menu.SetTitle(title);
    
    menu.AddItem("info", "Brain system removed (behavior tree)", ITEMDRAW_DISABLED);
    
    menu.ExitBackButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_AdminBrain(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        
        // Double-check ROOT access before actually resetting
        bool isRoot = (param1 == 0 || (GetUserFlagBits(param1) & ADMFLAG_ROOT) != 0);
        if (!isRoot) {
            CPrintToChat(param1, "%t", "PvB_Brain_RequiresRoot");
            ShowAdminMainMenu(param1);
            return 0;
        }
        
        ShowAdminMainMenu(param1);
    }
    else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowAdminMainMenu(param1);
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void ShowAdminSpeechMenu(int client) {
    Menu menu = new Menu(MenuHandler_AdminSpeech);
    char title[64];
    FormatEx(title, sizeof(title), "%T", "PvB_Menu_Speech", client, CfgSpeech ? "ON" : "OFF");
    menu.SetTitle(title);
    
    menu.AddItem("toggle", CfgSpeech ? "Disable Speech" : "Enable Speech");
    
    for (int t = 0; t < NumBotTypes; t++) {
        char info[8], display[128];
        IntToString(t, info, sizeof(info));
        char typeName[32];
        GetBotTypeNameSafe(t, typeName, sizeof(typeName));
        FormatEx(display, sizeof(display), "%s: %d kill / %d death lines",
            typeName, 
            TauntsPlayerDeath[t].Length,
            TauntsBotDeath[t].Length);
        menu.AddItem(info, display, ITEMDRAW_DISABLED);
    }
    
    menu.ExitBackButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_AdminSpeech(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        
        if (StrEqual(info, "toggle")) {
            CfgSpeech = !CfgSpeech;
            CPrintToChat(param1, "%t", "PvB_Speech_Toggled", CfgSpeech ? "enabled" : "disabled");
        }
        ShowAdminMainMenu(param1);
    }
    else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowAdminMainMenu(param1);
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

public Action Cmd_SetBotType(int client, int args) {
    if (args < 1) {
        CReplyToCommand(client, "%t", "PvB_SetBotType_Usage", NumBotTypes);
        for (int t = 0; t < NumBotTypes; t++) {
            CReplyToCommand(client, "  %d = %s (%s)", t, BotClassKey[t], BotDisplayName[t]);
        }
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));

    int type = -1;
    if (arg[0] >= '0' && arg[0] <= '9') {
        type = StringToInt(arg);
        if (type < 0 || type >= NumBotTypes) type = -1;
    }
    if (type < 0) type = FindClassIndexByName(arg);

    if (type < 0) {
        CReplyToCommand(client, "%t", "PvB_SetBotType_Unknown", arg, NumBotTypes);
        return Plugin_Handled;
    }

    LoadBotTypeSettings(type);
    char typeName[32];
    GetBotTypeNameSafe(CfgBotType, typeName, sizeof(typeName));
    CPrintToChatAll("%t", "PvB_BotType_Set", typeName);
    return Plugin_Handled;
}

public Action Cmd_Toggle(int client, int args) {
    if (!CfgEnabled) return Plugin_Handled;

    if (!BotEnabled) {
        EnablePvB();
        CommandForced = true;
        CommandDisabled = false;
    } else {
        DisablePvB();
        CommandDisabled = true;
        CommandForced = false;
    }
    return Plugin_Handled;
}

public Action Cmd_BotMenu(int client, int args) {
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) {
        CReplyToCommand(client, "%t", "PvB_ConsoleOnly_Player");
        return Plugin_Handled;
    }

    if (!CfgEnabled) {
        CReplyToCommand(client, "%t", "PvB_Disabled");
        return Plugin_Handled;
    }

    ShowBotTypeMenu(client);
    return Plugin_Handled;
}

public Action Cmd_BotStats(int client, int args) {
    if (client == 0) {
        CReplyToCommand(client, "%t", "PvB_ConsoleOnly_Stats");
        return Plugin_Handled;
    }
    
    if (!BotEnabled) {
        CReplyToCommand(client, "%t", "PvB_Bot_NotActive");
        return Plugin_Handled;
    }
    
    int totalRounds = BotWins + BotLosses;
    float winRate = (totalRounds > 0) ? (float(BotWins) / float(totalRounds) * 100.0) : 0.0;
    
    CPrintToChat(client, "%t", "PvB_Stats_Header");
    char typeName[32];
    GetBotTypeNameSafe(CfgBotType, typeName, sizeof(typeName));
    CPrintToChat(client, "%t", "PvB_Stats_Type", typeName);
    CPrintToChat(client, "%t", "PvB_Stats_Rounds", totalRounds, BotWins, BotLosses);
    CPrintToChat(client, "%t", "PvB_Stats_WinRate", winRate);
    CPrintToChat(client, "%t", "PvB_Stats_Deflects", TotalDeflects, RoundDeflects);
    CPrintToChat(client, "%t", "PvB_Stats_Kills", TotalKills);
    CPrintToChat(client, "%t", "PvB_Stats_Deaths", TotalDeaths);
    CPrintToChat(client, "%t", "PvB_Stats_Footer");
    
    return Plugin_Handled;
}

public Action Cmd_BotVote(int client, int args) {
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) {
        CReplyToCommand(client, "%t", "PvB_ConsoleOnly_Player");
        return Plugin_Handled;
    }

    if (!CfgEnabled) {
        CPrintToChat(client, "%t", "PvB_Disabled");
        return Plugin_Handled;
    }

    if (ClassVoteActive) {
        CPrintToChat(client, "%t", "PvB_Vote_InProgress");
        return Plugin_Handled;
    }

    if (DebugStatesMode) {
        CPrintToChat(client, "%t", "PvB_Vote_DebugStatesBlock");
        return Plugin_Handled;
    }

    // Spectators can't start a vote that affects active gameplay state. They
    // CAN view stats via sm_botstats / sm_botmenu — that path doesn't gate on
    // team. This only blocks vote initiation.
    if (GetClientTeam(client) <= view_as<int>(TFTeam_Spectator)) {
        if (TranslationPhraseExists("PvB_Vote_MustBeOnTeam")) {
            CPrintToChat(client, "%t", "PvB_Vote_MustBeOnTeam");
        } else {
            CPrintToChat(client, "[TFDB] You must be on RED or BLU to vote for the bot.");
        }
        return Plugin_Handled;
    }

    // Preemptive mutex check — reject the vote up-front if a partner mode is
    // active (Guardian / DeathMatch / FFA). Without this the vote runs to
    // completion, then EnablePvB() silently fails on the same gates inside —
    // bot never spawns and players are confused. Better to tell them now.
    if (LibraryExists("tfdb_guardian") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsGuardianActive") == FeatureStatus_Available &&
        TFDB_IsGuardianActive()) {
        CPrintToChat(client, "{olive}[TFDB]{default} Cannot vote for bot while a Guardian round is active.");
        return Plugin_Handled;
    }
    if (LibraryExists("tfdb_deathmatch") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsDeathMatchActive") == FeatureStatus_Available &&
        TFDB_IsDeathMatchActive()) {
        CPrintToChat(client, "{olive}[TFDB]{default} Cannot vote for bot while DeathMatch is active.");
        return Plugin_Handled;
    }
    if (LibraryExists("tfdb_ffa") &&
        GetFeatureStatus(FeatureType_Native, "TFDB_IsFFAActive") == FeatureStatus_Available &&
        TFDB_IsFFAActive()) {
        CPrintToChat(client, "{olive}[TFDB]{default} Cannot vote for bot while FFA is active.");
        return Plugin_Handled;
    }

    int currentPlayers = CachedRealCount;
    if (VoteMaxPlayers > 0 && currentPlayers > VoteMaxPlayers) {
        CPrintToChat(client, "%t", "PvB_Vote_TooManyPlayers", currentPlayers, VoteMaxPlayers);
        return Plugin_Handled;
    }

    // Preemptive check vs CfgMaxPlayers — if the vote would pass but the bot
    // would auto-kick the next tick due to humans > max_players, tell the
    // player upfront with the actual cap instead of running the silent
    // enable-then-disable cycle. Only enforce when bot is OFF (enabling); a
    // vote to DISABLE while humans > max is fine. Skip when bot is already on
    // and the vote could be a hot-swap or disable.
    if (!BotEnabled && CfgMaxPlayers > 0 && currentPlayers > CfgMaxPlayers) {
        // Guard the translation lookup — same rationale as other PvB phrases
        // (stale global phrase cache could throw before the user runs
        // sm_reload_translations). See sourcemod-practices/translations.md.
        if (TranslationPhraseExists("PvB_Vote_AbovePvBLimit")) {
            CPrintToChat(client, "%t", "PvB_Vote_AbovePvBLimit", currentPlayers, CfgMaxPlayers);
        } else {
            CPrintToChat(client, "[TFDB] Bot can't run with this many players (%d > %d max). Have an admin force it with !pvb.",
                currentPlayers, CfgMaxPlayers);
        }
        return Plugin_Handled;
    }

    // Unified class vote. Always shows the bot-type menu with a final
    // "Disable bot" option. This lets players:
    //   - enable the bot by picking a type (when bot is off)
    //   - switch to a different type (when bot is on with a different type)
    //   - disable the bot (pick "Disable bot" from the same menu)
    // One menu, all use cases.
    CPrintToChatAll("%t", "PvB_Vote_StartClass", client);
    StartClassVote();

    return Plugin_Handled;
}

void ShowBotStatsMenu(int client) {
    if (!BotEnabled && !DebugStatesMode) {
        CPrintToChat(client, "%t", "PvB_Bot_NoActive");
        return;
    }
    
    Menu menu = new Menu(MenuHandler_BotStats);
    
    int totalRounds = BotWins + BotLosses;
    float winRate = (totalRounds > 0) ? (float(BotWins) / float(totalRounds) * 100.0) : 0.0;
    
    char title[256];
    char statsTypeName[32];
    GetBotTypeNameSafe(CfgBotType, statsTypeName, sizeof(statsTypeName));
    FormatEx(title, sizeof(title), "PvB Bot Stats\nType: %s\nWins: %d | Losses: %d (%.1f%%)\nRound Deflects: %d",
           statsTypeName, BotWins, BotLosses, winRate, RoundDeflects);
    menu.SetTitle(title);
    
    char stats[64];
    FormatEx(stats, sizeof(stats), "Total Deflects: %d", TotalDeflects);
    menu.AddItem("deflects", stats, ITEMDRAW_DISABLED);
    
    FormatEx(stats, sizeof(stats), "Kills: %d", TotalKills);
    menu.AddItem("kills", stats, ITEMDRAW_DISABLED);
    
    FormatEx(stats, sizeof(stats), "Deaths: %d", TotalDeaths);
    menu.AddItem("deaths", stats, ITEMDRAW_DISABLED);
    
    menu.ExitButton = true;
    menu.Display(client, 20);
}

public int MenuHandler_BotStats(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void ShowClassPickMenu(int client) {
    Menu menu = new Menu(MenuHandler_ClassPick);
    char title[64];
    FormatEx(title, sizeof(title), "%T", "PvB_Menu_Choose_Opponent", client);
    menu.SetTitle(title);
    for (int t = 0; t < NumBotTypes; t++) {
        char info[8];
        IntToString(t, info, sizeof(info));
        menu.AddItem(info, BotDisplayName[t]);
    }
    menu.ExitButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_ClassPick(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        if (CachedRealCount != 1 || !IsGenuinelySolo()) {
            CPrintToChat(param1, "%t", "PvB_PlayerJoined_Cancelled");
            SoloMenuShown = false;
        } else {
            char info[8];
            menu.GetItem(param2, info, sizeof(info));
            int type = StringToInt(info);
            
            LoadBotTypeSettings(type);
            
            char typeName[32];
            GetBotTypeNameSafe(CfgBotType, typeName, sizeof(typeName));
            CPrintToChatAll("%t", "PvB_PvB_Starting", typeName);
            
            if (!BotEnabled) {
                EnablePvB();
            }
            SoloMenuShown = false;
        }
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void StartClassVote() {
    if (ClassVoteActive) return;

    // Zero tallies + per-client ballot BEFORE flipping the active flag — if any
    // call below throws (e.g. stale translation cache in ShowClassVoteMenu),
    // the flag stays false so the next !votepvb can retry cleanly.
    for (int t = 0; t <= NumBotTypes; t++) {  // +1 covers the "disable" slot
        ClassVotes[t] = 0;
    }
    for (int i = 1; i <= MaxClients; i++) {
        ClassVoted[i] = -1;
    }

    CPrintToChatAll("%t", "PvB_ClassVote_Start");

    // Show ballot only to players on RED or BLU. Spectators don't get to vote
    // on active gameplay state — same rationale as the starter gate above.
    for (int i = 1; i <= MaxClients; i++) {
        if (TFDB_IsRealHumanPlaying(i)) {
            ShowClassVoteMenu(i);
        }
    }

    // Only now commit to the active state. Even if the menu loop above partial-
    // fails, the timer below guarantees ResolveClassVote runs and clears the flag.
    ClassVoteActive = true;
    delete ClassVoteTimer;
    ClassVoteTimer = CreateTimer(20.0, Timer_EndClassVote, _, TIMER_FLAG_NO_MAPCHANGE);
}

void ShowClassVoteMenu(int client) {
    Menu menu = new Menu(MenuHandler_ClassVote);
    char title[64];
    FormatEx(title, sizeof(title), "%T", "PvB_Menu_Vote_Type", client);
    menu.SetTitle(title);
    for (int t = 0; t < NumBotTypes; t++) {
        char info[8];
        IntToString(t, info, sizeof(info));
        menu.AddItem(info, BotDisplayName[t]);
    }
    // "Disable bot" menu entry — only when the bot is currently active. No
    // point offering "disable" when nothing is running. Uses project translation
    // convention (shared `tfdb.phrases.txt`, PvB_* prefix). TranslationPhraseExists
    // guards a stale translation cache (SM's global phrase cache doesn't auto-
    // refresh on plugin reload; requires `sm_reload_translations` or map change).
    if (BotEnabled) {
        char disableLabel[48];
        if (TranslationPhraseExists("PvB_Menu_Vote_Disable_Option")) {
            FormatEx(disableLabel, sizeof(disableLabel), "%T", "PvB_Menu_Vote_Disable_Option", client);
        } else {
            strcopy(disableLabel, sizeof(disableLabel), "Disable bot");
        }
        char disableInfo[8];
        IntToString(PVB_VOTE_DISABLE, disableInfo, sizeof(disableInfo));
        menu.AddItem(disableInfo, disableLabel);
    }

    // Exit button lets a player abstain from the vote. Cancel-as-abstain is
    // counted toward the early-resolve check so a solo player hitting Exit
    // doesn't leave the 20s timer running on nothing.
    menu.ExitButton = true;
    menu.Display(client, 20);
}

public int MenuHandler_ClassVote(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        if (ClassVoted[param1] != -1) return 0;

        char info[8];
        menu.GetItem(param2, info, sizeof(info));
        int type = StringToInt(info);

        // Clamp: valid type (0..NumBotTypes-1), or PVB_VOTE_DISABLE (-1).
        // Disable votes are tallied in ClassVotes[NumBotTypes] — the slot
        // just past the last real type. MAX_BOT_TYPES leaves room for it.
        int voteSlot;
        if (type == PVB_VOTE_DISABLE) {
            voteSlot = NumBotTypes;  // dedicated "disable" tally slot
        } else {
            if (type < 0 || type >= NumBotTypes) type = 0;
            voteSlot = type;
        }

        ClassVoted[param1] = voteSlot;
        ClassVotes[voteSlot]++;

        char typeName[32];
        if (type == PVB_VOTE_DISABLE) {
            if (TranslationPhraseExists("PvB_Menu_Vote_Disable_Option")) {
                FormatEx(typeName, sizeof(typeName), "%T", "PvB_Menu_Vote_Disable_Option", LANG_SERVER);
            } else {
                strcopy(typeName, sizeof(typeName), "Disable bot");
            }
        } else {
            GetBotTypeNameSafe(type, typeName, sizeof(typeName));
        }
        CPrintToChatAll("%t", "PvB_ClassVote_Voted", param1, typeName);

        // Early-resolve: if every human in game has voted, skip the remaining
        // timer — no point waiting 20s when the result is already decided.
        // Count live non-fake clients directly (don't rely on CachedRealCount
        // which updates on a separate tick).
        int humans = 0, voted = 0;
        for (int i = 1; i <= MaxClients; i++) {
            if (!TFDB_IsRealHumanPlaying(i)) continue;  // specs don't vote
            humans++;
            if (ClassVoted[i] != -1) voted++;
        }
        if (voted >= humans && humans > 0) {
            delete ClassVoteTimer;
            ClassVoteTimer = null;
            ResolveClassVote();
        }
    }
    else if (action == MenuAction_Cancel) {
        // Client hit Exit on the vote menu. Count them as abstained (-2) so
        // early-resolve doesn't wait 20s for a client who has opted out.
        // -2 is distinct from -1 (never voted) so they can't re-open + vote.
        if (param1 >= 1 && param1 <= MaxClients && ClassVoted[param1] == -1) {
            ClassVoted[param1] = -2;
            // Guard the translation lookup — same reason as PvB_Menu_Vote_Disable_Option,
            // stale global phrase cache could throw. See sourcemod-practices/translations.md.
            if (TranslationPhraseExists("PvB_ClassVote_Abstained")) {
                CPrintToChatAll("%t", "PvB_ClassVote_Abstained", param1);
            }

            // Same early-resolve check as MenuAction_Select — if every human
            // has either voted or abstained, wrap the vote now.
            int humans = 0, done = 0;
            for (int i = 1; i <= MaxClients; i++) {
                if (!TFDB_IsRealHuman(i)) continue;
                humans++;
                if (ClassVoted[i] != -1) done++;
            }
            if (done >= humans && humans > 0) {
                delete ClassVoteTimer;
                ClassVoteTimer = null;
                ResolveClassVote();
            }
        }
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

public Action Timer_EndClassVote(Handle timer) {
    ClassVoteTimer = null;
    ResolveClassVote();
    return Plugin_Stop;
}

void ResolveClassVote() {
    ClassVoteActive = false;

    // Ballot slots 0..NumBotTypes-1 = each bot type; slot NumBotTypes = "Disable bot".
    int totalSlots = NumBotTypes + 1;

    int maxVotes = 0;
    for (int i = 0; i < totalSlots; i++) {
        if (ClassVotes[i] > maxVotes) {
            maxVotes = ClassVotes[i];
        }
    }

    if (maxVotes == 0) {
        // No one voted — keep current state. If bot wasn't on, don't enable.
        CPrintToChatAll("%t", "PvB_ClassVote_NoVotes");
        if (!BotEnabled) LoadBotTypeSettings(CfgBotType);
        // Don't call EnablePvB() in no-vote case — silent cancel.
        return;
    }

    // Find tied winners, pick one at random.
    int tied[MAX_BOT_TYPES + 1];
    int tiedCount = 0;
    for (int i = 0; i < totalSlots; i++) {
        if (ClassVotes[i] == maxVotes) {
            tied[tiedCount++] = i;
        }
    }
    int winnerSlot = tied[GetRandomInt(0, tiedCount - 1)];

    // Slot NumBotTypes = "Disable bot" winner.
    if (winnerSlot == NumBotTypes) {
        char disableLabel[48];
        if (TranslationPhraseExists("PvB_Menu_Vote_Disable_Option")) {
            FormatEx(disableLabel, sizeof(disableLabel), "%T", "PvB_Menu_Vote_Disable_Option", LANG_SERVER);
        } else {
            strcopy(disableLabel, sizeof(disableLabel), "Disable bot");
        }
        CPrintToChatAll("%t", "PvB_ClassVote_Result", disableLabel, maxVotes);
        if (BotEnabled) DisablePvB();
        return;
    }

    // Bot-type winner — switch (or enable) to that type.
    char typeName[32];
    GetBotTypeNameSafe(winnerSlot, typeName, sizeof(typeName));

    if (!BotEnabled) {
        // Bot is OFF — vote enables it. Apply type immediately + spawn the bot.
        LoadBotTypeSettings(winnerSlot);
        CPrintToChatAll("%t", "PvB_ClassVote_Result", typeName, maxVotes);
        EnablePvB();
    } else if (winnerSlot == CfgBotType) {
        // Vote winner is already the active type — nothing to do, no respawn needed.
        CPrintToChatAll("%t", "PvB_ClassVote_Result", typeName, maxVotes);
    } else {
        // Hot-swap to a DIFFERENT type while bot is running. Defer to round end
        // so the current rally isn't interrupted mid-fight (mirrors the
        // PendingMaxPlayerDisable pattern). If round-state is between rounds
        // already, swap immediately.
        PendingHotSwapType = winnerSlot;
        if (GameRules_GetRoundState() == RoundState_RoundRunning) {
            if (TranslationPhraseExists("PvB_HotSwap_Deferred")) {
                CPrintToChatAll("%t", "PvB_HotSwap_Deferred", typeName);
            } else {
                CPrintToChatAll("[TFDB] Vote passed: bot will switch to %s at end of this round.", typeName);
            }
        } else {
            // Already between rounds — apply now, no rally to interrupt.
            ApplyHotSwap();
        }
    }
}

void ApplyHotSwap()
{
    if (PendingHotSwapType < 0 || PendingHotSwapType >= NumBotTypes) {
        PendingHotSwapType = -1;
        return;
    }

    LoadBotTypeSettings(PendingHotSwapType);
    PendingHotSwapType = -1;

    // BotName was updated by LoadBotTypeSettings; the fresh tf_bot_add uses it.
    ServerCommand("tf_bot_kick all");
    ServerCommand("tf_bot_add 1 Pyro blue easy \"%s\"", BotName);
    BotNameDirty = true;
    ApplyBotTypeSettings();
}

void ShowBotTypeMenu(int client) {
    Menu menu = new Menu(MenuHandler_BotType);
    
    char typeName[32];
    GetBotTypeNameSafe(CfgBotType, typeName, sizeof(typeName));
    
    char title[128];
    if (BotEnabled) {
        FormatEx(title, sizeof(title), "%T", "PvB_Menu_Info_Active", client, typeName, RoundDeflects);
    } else {
        FormatEx(title, sizeof(title), "%T", "PvB_Menu_Info_Inactive", client);
    }
    menu.SetTitle(title);
    
    menu.AddItem("stats", "View Bot Stats");
    
    if (BotEnabled) {
        menu.AddItem("votedisable", "Vote to Disable Bot");
    } else {
        menu.AddItem("voteenable", "Vote to Enable Bot");
    }
    
    menu.ExitButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_BotType(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        
        if (StrEqual(info, "stats")) {
            ShowBotStatsMenu(param1);
        }
        else if (StrEqual(info, "voteenable")) {
            if (!BotEnabled && !ClassVoteActive) {
                FakeClientCommandEx(param1, "sm_botvote");
            } else if (BotEnabled) {
                CPrintToChat(param1, "%t", "PvB_Bot_AlreadyActive");
            } else {
                CPrintToChat(param1, "%t", "PvB_Vote_InProgress");
            }
        }
        else if (StrEqual(info, "votedisable")) {
            if (BotEnabled && !ClassVoteActive) {
                FakeClientCommandEx(param1, "sm_botvote");
            } else if (!BotEnabled) {
                CPrintToChat(param1, "%t", "PvB_Bot_AlreadyDisabled");
            } else {
                CPrintToChat(param1, "%t", "PvB_Vote_InProgress");
            }
        }
    }
    else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void ResetPvBProfileCounters() {
    g_PvBProfileFrames = 0;
    g_PvBProfileCommands = 0;
    g_PvBProfileEligibleCommands = 0;
    g_PvBProfileRocketScans = 0;
    g_PvBProfileThreatScans = 0;
}

void StopPvBProfile() {
    float elapsed = TFDB_ProfileStop(g_PvBProfileWindow);
    // Deliberately NOT PvB_Log. Every TFDB component emits its own
    // [TFDB-PROFILE] line and they're meant to be read together against one
    // timeline -- splitting PvB's into a plugin-private file would break the
    // one thing this output is for. Plugin-scoped logging is for PvB's own
    // narrative (nav, states, falls); cross-component telemetry stays shared.
    LogMessage("[TFDB-PROFILE] component=pvb elapsed=%.3f frames=%d commands=%d eligible=%d rocketScans=%d threatScans=%d events=%d dropped=%d debug=%d",
        elapsed, g_PvBProfileFrames, g_PvBProfileCommands, g_PvBProfileEligibleCommands,
        g_PvBProfileRocketScans, g_PvBProfileThreatScans, g_PvBProfileWindow.emittedEvents,
        g_PvBProfileWindow.droppedEvents, DebugActive ? 1 : 0);
}

public Action Cmd_PvBProfile(int client, int args) {
    if (g_PvBProfileWindow.active) {
        ReplyToCommand(client, "[PvB] Profiling is already active.");
        return Plugin_Handled;
    }
    float duration = TFDB_ProfileDurationFromArgs(args);
    ResetPvBProfileCounters();
    TFDB_ProfileStart(g_PvBProfileWindow, duration);
    CreateTimer(duration, Timer_StopPvBProfile, _, TIMER_FLAG_NO_MAPCHANGE);
    ReplyToCommand(client, "[PvB] Profiling started for %.1f seconds.", duration);
    return Plugin_Handled;
}

public Action Timer_StopPvBProfile(Handle timer) {
    if (g_PvBProfileWindow.active) StopPvBProfile();
    return Plugin_Stop;
}

public Action Timer_ShowBotMenu(Handle timer) {
    if (!BotEnabled && CfgEnabled && GetRealClientCount() == 1) {
        ShowBotTypeMenuToAll();
    }
    return Plugin_Stop;
}

void ShowBotTypeMenuToAll() {
    for (int i = 1; i <= MaxClients; i++) {
        if (TFDB_IsRealHuman(i)) {
            ShowBotTypeMenu(i);
            break;
        }
    }
}

static void Inspect_PrintBot(int client) {
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) {
        PrintToServer("[Inspect] Invalid client #%d", client);
        return;
    }
    if (!IsFakeClient(client)) {
        PrintToServer("[Inspect] Client #%d is not a bot", client);
        return;
    }
    if (!IsPlayerAlive(client)) {
        PrintToServer("[Inspect] Bot #%d is dead", client);
        return;
    }

    int botType = DebugStatesBotType[client];
    int team = GetClientTeam(client);

    // BT state
    BotState state = view_as<BotState>(BotState_[client]);
    char stateName[16];
    switch (state) {
        case STATE_IDLE:        strcopy(stateName, sizeof(stateName), "IDLE");
        case STATE_GANG_ESCAPE: strcopy(stateName, sizeof(stateName), "GANG_ESCAPE");
        case STATE_DEFLECT:     strcopy(stateName, sizeof(stateName), "DEFLECT");
        case STATE_DODGE:       strcopy(stateName, sizeof(stateName), "DODGE");
        case STATE_ORBIT:       strcopy(stateName, sizeof(stateName), "ORBIT");
        case STATE_MOVE:        strcopy(stateName, sizeof(stateName), "MOVE");
        case STATE_GUARD:       strcopy(stateName, sizeof(stateName), "GUARD");
        default: FormatEx(stateName, sizeof(stateName), "STATE_%d", view_as<int>(state));
    }

    char className[16];
    strcopy(className, sizeof(className), BotClassKey[botType]);

    PrintToServer("");
    PrintToServer("[BOT #%d] %s | Type=%d | Team=%s | State=%s | Deflects=%d",
        client, className, botType,
        team == 2 ? "RED" : (team == 3 ? "BLU" : "SPEC"),
        stateName, DeflectCount[client]);

    // Last move set
    char moveName[16];
    MoveSetName(LastMoveSet[client], moveName, sizeof(moveName));
    PrintToServer("  LastMove: %s | PostDeflect: %s",
        moveName,
        (GetEngineTime() < PostDeflectUntil[client]) ? "ACTIVE" : "inactive");

    // Enemy
    int enemy = GetFrameEnemy(client);
    if (enemy > 0 && IsClientInGame(enemy) && IsPlayerAlive(enemy)) {
        float enemyPos[3], myPos[3];
        GetClientAbsOrigin(enemy, enemyPos);
        GetClientAbsOrigin(client, myPos);
        float dist = GetVectorDistance(myPos, enemyPos);
        PrintToServer("  Enemy: #%d dist=%.0f HU | Gangs: %d", enemy, dist, GangerCount_[client]);
    } else {
        PrintToServer("  Enemy: none | Gangs: %d", GangerCount_[client]);
    }

    // Rocket
    int rocket = GetCachedRocketForClient(client);
    if (rocket != -1 && TFDB_IsValidRocket(rocket)) {
        float rocketPos[3], rocketVel[3];
        GetEntPropVector(rocket, Prop_Data, "m_vecAbsOrigin", rocketPos);
        GetEntPropVector(rocket, Prop_Data, "m_vecAbsVelocity", rocketVel);
        float speed = GetVectorLength(rocketVel);
        float myEye[3];
        GetClientEyePosition(client, myEye);
        float rDist = GetVectorDistance(myEye, rocketPos);
        PrintToServer("  Rocket: entity=%d speed=%.0f HU/s dist=%.0f HU targeting=%s",
            rocket, speed, rDist,
            IsRocketTargetingClient(rocket, client) ? "ME" : "other");
    } else {
        PrintToServer("  Rocket: none");
    }

    // Walls
    int openDirs = 0;
    for (int i = 0; i < 8; i++) if (!WallBlocked_[client][i]) openDirs++;
    PrintToServer("  Walls: %d/8 open | OrbitPhase: %d",
        openDirs, OrbitPhaseIdx[client]);

    // Eye angles
    float eyeAng[3];
    GetClientEyeAngles(client, eyeAng);
    PrintToServer("  Eye: [%.0f, %.0f] | CanWalk: %s | isStatue: %s | EvadeStrafe: %s",
        eyeAng[0], eyeAng[1],
        CfgCanWalk[botType] ? "yes" : "no",
        ClassIsStatueLike[botType] ? "yes" : "no",
        CfgEvadeStrafeEnabled[botType] ? "yes" : "no");

    PrintToServer("");
}

static void Inspect_PrintRocket(int rocketIndex) {
    if (rocketIndex < 0 || rocketIndex >= MAX_ROCKETS) {
        PrintToServer("[Inspect] Invalid rocket index %d (0-%d)", rocketIndex, MAX_ROCKETS - 1);
        return;
    }
    if (!TFDB_IsValidRocket(rocketIndex)) {
        PrintToServer("[Inspect] Rocket index %d is not valid/active", rocketIndex);
        return;
    }

    int entity = TFDB_GetRocketEntity(rocketIndex);
    int target = TFDB_GetRocketTarget(rocketIndex);
    int owner = TFDB_GetRocketOwner(rocketIndex);
    int deflects = TFDB_GetRocketEventDeflections(rocketIndex);
    int totalDeflects = TFDB_GetRocketDeflections(rocketIndex);
    float speed = TFDB_GetRocketSpeed(rocketIndex);
    int rClass = TFDB_GetRocketClass(rocketIndex);

    float rocketPos[3], rocketDir[3];
    GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", rocketPos);
    TFDB_GetRocketDirection(rocketIndex, rocketDir);

    PrintToServer("");
    PrintToServer("[ROCKET %d] entity=%d class=%d", rocketIndex, entity, rClass);
    PrintToServer("  Target: #%d (%s)", target,
        (target > 0 && target <= MaxClients && IsClientInGame(target)) ? "valid" : "invalid");
    PrintToServer("  Owner: #%d", owner);
    PrintToServer("  Deflects: event=%d total=%d", deflects, totalDeflects);
    PrintToServer("  Speed: %.0f HU/s (%.0f mph)", speed, TFDB_GetRocketMphSpeed(rocketIndex));
    PrintToServer("  Position: (%.0f, %.0f, %.0f)", rocketPos[0], rocketPos[1], rocketPos[2]);
    PrintToServer("  Direction: (%.2f, %.2f, %.2f)", rocketDir[0], rocketDir[1], rocketDir[2]);
    PrintToServer("  LastDeflectTime: %.1f", TFDB_GetRocketLastDeflectionTime(rocketIndex));
    PrintToServer("");
}

static void Inspect_PrintAll() {
    PrintToServer("");
    PrintToServer("======== FULL STATE SNAPSHOT ========");
    PrintToServer("Time: %.2f", GetEngineTime());

    int botCount = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsFakeClient(i) && IsPlayerAlive(i)) {
            Inspect_PrintBot(i);
            botCount++;
        }
    }
    PrintToServer("Bots alive: %d", botCount);

    int rocketCount = 0;
    for (int i = 0; i < MAX_ROCKETS; i++) {
        if (TFDB_IsValidRocket(i)) {
            Inspect_PrintRocket(i);
            rocketCount++;
        }
    }
    PrintToServer("Rockets active: %d", rocketCount);

    PrintToServer("=====================================");
    PrintToServer("");
}

public Action Command_InspectBot(int client, int args) {
    if (args < 1) {
        PrintToServer("[Inspect] Usage: sm_inspect_bot <client>");
        return Plugin_Handled;
    }
    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    Inspect_PrintBot(StringToInt(arg));
    return Plugin_Handled;
}

public Action Command_InspectRocket(int client, int args) {
    if (args < 1) {
        PrintToServer("[Inspect] Usage: sm_inspect_rocket <index>");
        return Plugin_Handled;
    }
    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    Inspect_PrintRocket(StringToInt(arg));
    return Plugin_Handled;
}

public Action Command_InspectAll(int client, int args) {
    Inspect_PrintAll();
    return Plugin_Handled;
}

void RegisterInspectorCommands() {
    RegAdminCmd("sm_inspect_bot", Command_InspectBot, ADMFLAG_ROOT, "Dump bot state");
    RegAdminCmd("sm_inspect_rocket", Command_InspectRocket, ADMFLAG_ROOT, "Dump rocket state");
    RegAdminCmd("sm_inspectall", Command_InspectAll, ADMFLAG_ROOT, "Full state snapshot");
}
