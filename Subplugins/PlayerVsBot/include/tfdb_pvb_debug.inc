// tfdb_pvb_debug.inc — auto-extracted from tfdb_pvb.sp
// Do not edit directly; this is a split of the PvB plugin.

public Action Cmd_BotDebugDraw(int client, int args) {
    DebugDrawActive = !DebugDrawActive;
    CReplyToCommand(client, "[PvB] Bot debug beams %s.", DebugDrawActive ? "ENABLED" : "disabled");
    return Plugin_Handled;
}

void DebugDrawBotState(int client, const float vel[3], const float angles[3])
{
    if (!DebugDrawActive || BeamSprite == -1) return;

    float now = GetEngineTime();
    if (now < NextDebugDraw[client]) return;
    NextDebugDraw[client] = now + 0.25;

    // Only draw for real humans currently in-game -- no point spending
    // temp-entity bandwidth on bots watching other bots.
    int recipients[MAXPLAYERS];
    int numRecipients = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) recipients[numRecipients++] = i;
    }
    if (numRecipients == 0) return;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    pos[2] += 4.0;

    // Wall-scan: 8 short beams, color-coded from WallBlocked_/EdgeBlocked_
    // (see MaybeScanWalls -- same data, same world-absolute indexing).
    for (int i = 0; i < 8; i++) {
        // World-absolute, matching how MaybeScanWalls actually scanned them.
        // Drawing these relative to current facing (as this used to) made the
        // overlay agree with the old rotated read instead of with the world,
        // so the beams looked plausible while pointing at the wrong geometry.
        float dirVec[3];
        DirIndexToWorldVector(i, dirVec);

        float end[3];
        end[0] = pos[0] + dirVec[0] * 48.0;
        end[1] = pos[1] + dirVec[1] * 48.0;
        end[2] = pos[2];

        int color[4];
        if (EdgeBlocked_[client][i])      { color[0]=255; color[1]=140; color[2]=0;   color[3]=255; }  // orange: edge
        else if (WallBlocked_[client][i]) { color[0]=255; color[1]=0;   color[2]=0;   color[3]=255; }  // red: wall
        else                               { color[0]=0;   color[1]=255; color[2]=0;   color[3]=255; }  // green: open

        TE_SetupBeamPoints(pos, end, BeamSprite, 0, 0, 0, 0.3, 1.5, 1.5, 0, 0.0, color, 0);
        TE_Send(recipients, numRecipients);
    }

    // Move direction (cyan) -- this tick's actual decided vel[], the same
    // vector that gets force-applied via TeleportEntity.
    float horizSpeed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
    if (horizSpeed > 1.0) {
        float moveEnd[3];
        moveEnd[0] = pos[0] + (vel[0] / horizSpeed) * 40.0;
        moveEnd[1] = pos[1] + (vel[1] / horizSpeed) * 40.0;
        moveEnd[2] = pos[2] + 12.0;
        int cyan[4] = {0, 255, 255, 255};
        TE_SetupBeamPoints(pos, moveEnd, BeamSprite, 0, 0, 0, 0.3, 2.0, 2.0, 0, 0.0, cyan, 0);
        TE_Send(recipients, numRecipients);
    }

    // Aim direction (yellow) -- where angles[] this tick is actually
    // pointing, from eye height so it reads as a sightline.
    float eyePos[3];
    GetClientEyePosition(client, eyePos);
    float aimFwd[3], aimRight[3], aimUp[3];
    GetAngleVectors(angles, aimFwd, aimRight, aimUp);
    float aimEnd[3];
    aimEnd[0] = eyePos[0] + aimFwd[0] * 200.0;
    aimEnd[1] = eyePos[1] + aimFwd[1] * 200.0;
    aimEnd[2] = eyePos[2] + aimFwd[2] * 200.0;
    int yellow[4] = {255, 255, 0, 255};
    TE_SetupBeamPoints(eyePos, aimEnd, BeamSprite, 0, 0, 0, 0.3, 1.0, 1.0, 0, 0.0, yellow, 0);
    TE_Send(recipients, numRecipients);
}

public Action Cmd_BotDebug(int client, int args) {
    if (DebugActive) {
        StopDebugLogging();
        CReplyToCommand(client, "[PvB] Debug logging STOPPED. %d lines -> %s", DebugLinesWritten, DebugLogPath);
        return Plugin_Handled;
    }

    // Parse optional sample rate: sm_botdebug [rate]
    if (args >= 1) {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        int rate = StringToInt(arg);
        if (rate >= 1 && rate <= 66) DebugSampleRate = rate;
    }

    // Fresh user-initiated session — reset cumulative-line counter so the hard
    // cap measures THIS session, not the previous one. (RotateDebugFile also
    // calls StartDebugLogging but must NOT reset DebugTotalLines, otherwise the
    // hard cap would never trigger across rotations.)
    DebugTotalLines = 0;
    StartDebugLogging();
    CReplyToCommand(client, "[PvB] Debug logging STARTED (every %d ticks). sm_stopdebug to stop.", DebugSampleRate);
    CReplyToCommand(client, "[PvB] Log: %s", DebugLogPath);
    return Plugin_Handled;
}

public Action Cmd_StopDebug(int client, int args) {
    if (!DebugActive) {
        CReplyToCommand(client, "[PvB] Debug logging is not active.");
        return Plugin_Handled;
    }
    StopDebugLogging();
    CReplyToCommand(client, "[PvB] Debug logging STOPPED. %d lines -> %s", DebugLinesWritten, DebugLogPath);
    return Plugin_Handled;
}

void PvB_Log(const char[] format, any ...)
{
    char msg[512];
    VFormat(msg, sizeof(msg), format, 2);

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "logs/tfdb_pvb");
    if (!DirExists(dir)) CreateDirectory(dir, 511);

    char day[16];
    FormatTime(day, sizeof(day), "%Y%m%d");
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "logs/tfdb_pvb/pvb_%s.log", day);

    File f = OpenFile(path, "a");
    if (f == null) {
        // Last resort only -- if the plugin's own log is unwritable the
        // message still has to go somewhere.
        LogError("[PvB] cannot open %s -- falling back to SM log for: %s", path, msg);
        return;
    }

    char stamp[32];
    FormatTime(stamp, sizeof(stamp), "%m/%d/%Y - %H:%M:%S");
    f.WriteLine("L %s: %s", stamp, msg);
    delete f;
}

void StartDebugLogging() {
    char timestamp[32];
    FormatTime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S");
    BuildPath(Path_SM, DebugLogPath, sizeof(DebugLogPath), "logs/tfdb_pvb/debug_%s.log", timestamp);

    // Open file handle for high-frequency writes (File.WriteLine doesn't spam console)
    DebugFile = OpenFile(DebugLogPath, "a");
    if (DebugFile == null) {
        LogError("[PvB] Could not open debug log: %s", DebugLogPath);
        return;
    }

    // Write header
    DebugFile.WriteLine("=== PVB DEBUG START === map=%s rate=%d build=%s ===", CurrentMap, DebugSampleRate, PVB_BUILD_MARKER);
    DebugFile.WriteLine("FORMAT [BOT tick N]: #clientIdx name type=class team=(2R/3B) state=BEHAVIOR_TREE_STATE evade=(none/jump_over/reposition/strafe/crouch) orbit=(0/1) trick=MOVE_SET_NAME pos(x y z) vel(x y) speed=groundspeed ang(pitch yaw) rocket(ent mine=targetingMe tgtcl=actualTarget dist spd) enemy=#idx(dist) walls=8-char-OWV-string(O=open,W=wall-hit,V=void-edge; WORLD-ABSOLUTE compass, index i = world yaw i*45: 0=+X,1=+X+Y,2=+Y,3=-X+Y,4=-X,5=-X-Y,6=-Y,7=+X-Y -- NOT relative to facing, so the same index means the same real direction on every line) open=openDirCount btn=WSADM1M2JC reason=(idle_roll/retreat_floor/break_flank/too_far/too_close/sweet_spot/n/a -- which State_Move branch fired) edgeDist=(cells from mapped boundary, ? if uncached) edgeov=(1 if edge-comfort retreat bias overrode this tick) wslide=(wall-slide commitment sign: 0/1/-1) ctl=(1 = a behaviour-tree leaf decided this tick's velocity, 0 = no leaf decided and the bot is deliberately holding position; a run of 0s used to mean the engine's own NextBot locomotion had taken over) cqc=(this bot class's ACTUAL runtime min/max/floor/retreat distances from pvb.cfg) nav=(ready=g_NavScanReady active=g_NavScanActive cellsnull=g_WalkableCells==null edgenull=g_CellEdgeDist==null hit=cache hits of 8 sampled dirs attempts=StartNavScanIfNeeded calls that passed early-out guards bails=how many of those found nobody with valid footing enabled=CfgEnabled map=live CurrentMap value cellsdone=g_NavCellsDone rejwall/rejnofloor/rejslope/rejfoot=NavCache_ExpandCell rejection counters frontier=g_NavFrontier.Length or -1 if null seed=(n=how many clients seeded the most recent fresh-scan attempt x/y/z=world pos of the first seed) fwdsweep=(direction-0/forward IncrementalWallClear outcome this tick: reason 0=clear 1=real wall hit 2=no floor/edge, faildist=distance along the 100-unit sweep where it failed, -1 if clear))");
    DebugFile.WriteLine("FORMAT [PLAYER tick N]: same as [BOT] minus state/evade/orbit/trick/walls, plus velDelta/yawDelta (turn rate)");
    DebugFile.WriteLine("[STATE] events: behavior tree state transitions. Format: bot=N class=X old=Y new=Z reason=R");
    DebugFile.WriteLine("DECISION/<type> events: rare, not per-tick -- StateChange, Deflect, JumpOverStart, JumpReposition, OrbitStart, OrbitEnd, Death");

    DebugActive = true;
    for (int i = 1; i <= MaxClients; i++) { BotDebugTick[i] = 0; PlayerDebugTick[i] = 0; }
    DebugLinesWritten = 0;
    PrintToServer("[PvB] Debug logging started: %s", DebugLogPath);
}

void StopDebugLogging() {
    if (DebugActive && DebugFile != null) {
        DebugFile.WriteLine("=== PVB DEBUG STOP === lines=%d ===", DebugLinesWritten);
    }
    delete DebugFile;
    DebugFile = null;
    DebugActive = false;
    PrintToServer("[PvB] Debug logging stopped. %d lines written.", DebugLinesWritten);
}

void RotateDebugFile() {
    StopDebugLogging();
    StartDebugLogging();
}

void DebugBumpLineCount() {
    DebugLinesWritten++;
    DebugTotalLines++;

    if (DebugTotalLines >= DEBUG_MAX_TOTAL_LINES) {
        PrintToServer("[PvB] Debug log hit hard cap (%d lines) — auto-stopping. Use sm_stopdebug next time.", DEBUG_MAX_TOTAL_LINES);
        StopDebugLogging();
        return;
    }

    if (DebugLinesWritten >= DEBUG_MAX_LINES) {
        RotateDebugFile();
    }
}

void DebugLogDecision(int client, const char[] where, const char[] details)
{
    if (!DebugActive || DebugFile == null) return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return;

    int botType = GetEffectiveBotType(client);
    char botName[32];
    GetClientName(client, botName, sizeof(botName));

    DebugFile.WriteLine(
        "[tick %d] DECISION/%s #%d %s type=%d %s",
        GetGameTickCount(), where, client, botName, botType, details);

    DebugBumpLineCount();
}

void DebugLogPlayerState(int client, float vel[3], float angles[3], int buttons) {
    if (!DebugActive || DebugFile == null) return;

    // Same sampling throttle DebugLogBotTick uses -- without this it would
    // write every single tick (66/s) instead of DebugSampleRate-sampled,
    // wildly out of proportion with the bot-side data it's meant to line
    // up against for comparison.
    PlayerDebugTick[client]++;
    if (PlayerDebugTick[client] % DebugSampleRate != 0) return;

    char playerName[32];
    GetClientName(client, playerName, sizeof(playerName));

    int team = GetClientTeam(client);
    float pos[3];
    GetClientAbsOrigin(client, pos);
    float eyePos[3];
    GetClientEyePosition(client, eyePos);

    // Aim delta: how fast is the player turning? (degrees per sample)
    float yawDelta = angles[1] - PlayerLastYaw[client];
    if (yawDelta > 180.0) yawDelta -= 360.0;
    if (yawDelta < -180.0) yawDelta += 360.0;
    PlayerLastYaw[client] = angles[1];

    // Velocity delta: acceleration / direction changes
    float velDeltaX = vel[0] - PlayerLastVelX[client];
    float velDeltaY = vel[1] - PlayerLastVelY[client];
    PlayerLastVelX[client] = vel[0];
    PlayerLastVelY[client] = vel[1];

    // Button flags — full input picture
    char btnStr[48];
    FormatEx(btnStr, sizeof(btnStr), "%s%s%s%s%s%s%s%s",
        (buttons & IN_FORWARD)  ? "W" : "-",
        (buttons & IN_BACK)     ? "S" : "-",
        (buttons & IN_MOVELEFT) ? "A" : "-",
        (buttons & IN_MOVERIGHT)? "D" : "-",
        (buttons & IN_ATTACK)   ? "M1" : "--",  // Flame
        (buttons & IN_ATTACK2)  ? "M2" : "--",  // Airblast
        (buttons & IN_JUMP)     ? "J" : "-",
        (buttons & IN_DUCK)     ? "C" : "-");   // Crouch

    // Ground speed (actual movement speed regardless of input direction)
    float actualVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", actualVel);
    float groundSpeed = SquareRoot(actualVel[0] * actualVel[0] + actualVel[1] * actualVel[1]);

    // Nearest rocket info (same scan as bots use)
    int rocketEnt = -1;
    float rocketDist = -1.0;
    float rocketSpeed = 0.0;
    bool rocketTargeted = false;
    int rocketTargetClient = -1;
    bool rocketApproaching = false;

    #if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled()) {
        float bestDist = 999999.0;
        int rocketIndexes[MAX_ROCKETS];
        int rocketCount = CollectValidRocketIndexes(rocketIndexes);
        for (int n = 0; n < rocketCount; n++) {
            int i = rocketIndexes[n];
            int ent = TFDB_GetRocketEntity(i);
            if (ent <= 0 || !IsValidEntity(ent)) continue;
            float rPos[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", rPos);
            float d = GetVectorDistance(eyePos, rPos);
            if (d < bestDist) {
                bestDist = d;
                rocketEnt = ent;
            }
        }
        if (rocketEnt != -1) {
            float rPos[3];
            GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
            rocketDist = GetVectorDistance(eyePos, rPos);
            float rVel[3];
            GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rVel);
            rocketSpeed = GetVectorLength(rVel);
            rocketTargeted = IsRocketTargetingClient(rocketEnt, client);
            int rIdx = TFDB_FindRocketByEntity(rocketEnt);
            if (rIdx != -1) {
                rocketTargetClient = TFDB_GetRocketTarget(rIdx);
            }
            float toMe[3];
            SubtractVectors(eyePos, rPos, toMe);
            NormalizeVector(toMe, toMe);
            rocketApproaching = (GetVectorDotProduct(rVel, toMe) > 0.0);
        }
    }
    #endif

    // Nearest enemy distance
    int nearEnemy = -1;
    float nearEnemyDist = 99999.0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == client) continue;
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        if (GetClientTeam(i) == team) continue;
        float ePos[3];
        GetClientAbsOrigin(i, ePos);
        float d = GetVectorDistance(pos, ePos);
        if (d < nearEnemyDist) {
            nearEnemyDist = d;
            nearEnemy = i;
        }
    }

    DebugFile.WriteLine(
        "[PLAYER tick %d] #%d %s team=%d pos=(%.0f %.0f %.0f) "
    ... "vel=(%.0f %.0f) velDelta=(%.0f %.0f) speed=%.0f ang=(%.1f %.1f) yawDelta=%.1f "
    ... "rocket=(ent=%d mine=%d tgtcl=%d dist=%.0f spd=%.0f approach=%d) "
    ... "enemy=#%d(%.0f) btn=%s",
        GetGameTickCount(), client, playerName, team,
        pos[0], pos[1], pos[2],
        vel[0], vel[1], velDeltaX, velDeltaY, groundSpeed,
        angles[0], angles[1], yawDelta,
        rocketEnt, rocketTargeted ? 1 : 0, rocketTargetClient, rocketDist, rocketSpeed, rocketApproaching ? 1 : 0,
        nearEnemy, nearEnemyDist,
        btnStr);

    DebugBumpLineCount();
}

void DebugLogBotTick(int client, float vel[3], float angles[3], int buttons) {
    if (!DebugActive || DebugFile == null) return;

    BotDebugTick[client]++;
    if (BotDebugTick[client] % DebugSampleRate != 0) return;

    int botType = GetEffectiveBotType(client);
    char botName[32];
    GetClientName(client, botName, sizeof(botName));
    int team = GetClientTeam(client);
    float pos[3];
    GetClientAbsOrigin(client, pos);
    float eyePos[3];
    GetClientEyePosition(client, eyePos);

    char stateName[16];
    BotStateName(view_as<BotState>(BotState_[client]), stateName, sizeof(stateName));

    char evadeStr[24];
    if (Evading[client]) {
        switch (CurrentEvadeAction[client]) {
            case EVADE_JUMP:       strcopy(evadeStr, sizeof(evadeStr), "jump_over");
            case EVADE_REPOSITION: strcopy(evadeStr, sizeof(evadeStr), "reposition");
            case EVADE_STRAFE:     strcopy(evadeStr, sizeof(evadeStr), "strafe");
            case EVADE_CROUCH:     strcopy(evadeStr, sizeof(evadeStr), "crouch");
            default:               strcopy(evadeStr, sizeof(evadeStr), "unknown");
        }
    } else {
        strcopy(evadeStr, sizeof(evadeStr), "none");
    }

    char trickName[16];
    if (LastMoveSet[client] < 0) {
        strcopy(trickName, sizeof(trickName), "jump_over");
    } else {
        MoveSetName(LastMoveSet[client], trickName, sizeof(trickName));
    }

    bool orbiting = (OrbitLoopsRemaining[client] > 0);

    // Ground speed (actual movement speed regardless of input direction)
    float actualVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", actualVel);
    float groundSpeed = SquareRoot(actualVel[0] * actualVel[0] + actualVel[1] * actualVel[1]);

    char btnStr[48];
    FormatEx(btnStr, sizeof(btnStr), "%s%s%s%s%s%s%s%s",
        (buttons & IN_FORWARD)  ? "W" : "-",
        (buttons & IN_BACK)     ? "S" : "-",
        (buttons & IN_MOVELEFT) ? "A" : "-",
        (buttons & IN_MOVERIGHT)? "D" : "-",
        (buttons & IN_ATTACK)   ? "M1" : "--",
        (buttons & IN_ATTACK2)  ? "M2" : "--",  // Airblast
        (buttons & IN_JUMP)     ? "J" : "-",
        (buttons & IN_DUCK)     ? "C" : "-");

    // Nearest rocket info (same scan CanDeflect/State_Deflect use)
    int rocketEnt = -1;
    float rocketDist = -1.0;
    float rocketSpeed = 0.0;
    bool rocketTargeted = false;
    int rocketTargetClient = -1;

    #if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled()) {
        float bestDist = 999999.0;
        int rocketIndexes[MAX_ROCKETS];
        int rocketCount = CollectValidRocketIndexes(rocketIndexes);
        for (int n = 0; n < rocketCount; n++) {
            int i = rocketIndexes[n];
            int ent = TFDB_GetRocketEntity(i);
            if (ent <= 0 || !IsValidEntity(ent)) continue;
            float rPos[3];
            GetEntPropVector(ent, Prop_Data, "m_vecOrigin", rPos);
            float d = GetVectorDistance(eyePos, rPos);
            if (d < bestDist) {
                bestDist = d;
                rocketEnt = ent;
            }
        }
        if (rocketEnt != -1) {
            float rPos[3];
            GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
            rocketDist = GetVectorDistance(eyePos, rPos);
            float rVel[3];
            GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rVel);
            rocketSpeed = GetVectorLength(rVel);
            rocketTargeted = IsRocketTargetingClient(rocketEnt, client);
            int rIdx = TFDB_FindRocketByEntity(rocketEnt);
            if (rIdx != -1) rocketTargetClient = TFDB_GetRocketTarget(rIdx);
        }
    }
    #endif

    // Nearest enemy distance
    int nearEnemy = -1;
    float nearEnemyDist = 99999.0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == client) continue;
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        if (GetClientTeam(i) == team) continue;
        float ePos[3];
        GetClientAbsOrigin(i, ePos);
        float d = GetVectorDistance(pos, ePos);
        if (d < nearEnemyDist) {
            nearEnemyDist = d;
            nearEnemy = i;
        }
    }

    // Wall/edge scan state (see MaybeScanWalls) -- O = open, W = real wall
    // hit (TR_TraceHull), V = void edge (no walkable floor). Indices 0-7 are
    // WORLD-ABSOLUTE compass directions (i = world yaw i*45: 0 = +X, 2 = +Y,
    // 4 = -X, 6 = -Y), NOT relative to where the bot is looking. Reading a
    // log: the same index means the same real-world direction on every line,
    // so a persistent 'V' in one slot is a fixed piece of map geometry
    // rather than something that moves as the bot turns. W and V used to be
    // a single combined "blocked" bit (old logs only ever show
    // walls=XXXXXXXX either way) -- split so a fully-blocked reading is
    // distinguishable as "surrounded by real geometry" vs "standing at an
    // edge" instead of requiring another guess.
    char wallStr[9];
    int openDirs = 0;
    for (int i = 0; i < 8; i++) {
        if (EdgeBlocked_[client][i])      wallStr[i] = 'V';
        else if (WallBlocked_[client][i]) wallStr[i] = 'W';
        else                              wallStr[i] = 'O';
        if (!WallBlocked_[client][i]) openDirs++;
    }
    wallStr[8] = '\0';

    // Decision introspection (see LastMoveReason/LastEdgeDist/WallSlideSign):
    // WHY this tick's vel[] is what it is, not just what it is. reason= is
    // whichever State_Move branch fired (or "n/a" if State_Move didn't run this
    // tick -- e.g. DEFLECT/ORBIT/GUARD states). edgeDist= is this cell's
    // distance from the mapped boundary in grid cells ("?" if the position
    // isn't cached), edgeov=1 means the edge-comfort retreat bias
    // overrode normal CQC positioning this tick. wslide= is the wall-slide
    // commitment sign (see FindUnblockedDirCommitted): 0 none, 1 CW, -1 CCW.
    // cqc=(...) is the ACTUAL runtime pvb.cfg values driving this bot's
    // class this tick, not the file on disk -- confirms config is loaded
    // and applied as expected instead of having to take it on faith.
    char edgeDistStr[8];
    if (LastEdgeDistKnown[client]) FormatEx(edgeDistStr, sizeof(edgeDistStr), "%d", LastEdgeDist[client]);
    else strcopy(edgeDistStr, sizeof(edgeDistStr), "?");

    DebugFile.WriteLine(
        "[BOT tick %d] #%d %s type=%d team=%d state=%s evade=%s orbit=%d trick=%s "
    ... "pos=(%.0f %.0f %.0f) vel=(%.0f %.0f) speed=%.0f ang=(%.1f %.1f) "
    ... "rocket=(ent=%d mine=%d tgtcl=%d dist=%.0f spd=%.0f) enemy=#%d(%.0f) walls=%s open=%d btn=%s "
    ... "reason=%s edgeDist=%s edgeov=%d wslide=%d ctl=%d cqc=(min=%.0f max=%.0f floor=%.0f retreat=%.0f) "
    ... "nav=(ready=%d active=%d cellsnull=0 edgenull=0 hit=%d/8 attempts=%d bails=%d enabled=%d map=%s "
    ... "cellsdone=%d rejwall=%d rejnofloor=%d rejslope=%d rejfoot=%d frontier=%d "
    ... "seed=(%d n=%.0f %.0f %.0f) fwdsweep=(reason=%d faildist=%.0f))",
        GetGameTickCount(), client, botName, botType, team, stateName, evadeStr, orbiting ? 1 : 0, trickName,
        pos[0], pos[1], pos[2],
        vel[0], vel[1], groundSpeed,
        angles[0], angles[1],
        rocketEnt, rocketTargeted ? 1 : 0, rocketTargetClient, rocketDist, rocketSpeed,
        nearEnemy, nearEnemyDist, wallStr, openDirs,
        btnStr,
        LastMoveReason[client], edgeDistStr, LastEdgeOverride[client] ? 1 : 0, WallSlideSign[client],
        LastLeafDecided[client] ? 1 : 0,
        CfgCqcMinDist[botType], CfgCqcMaxDist[botType], CfgCqcFloorDist[botType], CfgCqcRetreatDist[botType],
        g_NavScanReady ? 1 : 0, g_NavScanActive ? 1 : 0, 0, 0,
        LastCacheHitCount[client], g_NavScanAttempts, g_NavScanBails, CfgEnabled ? 1 : 0, CurrentMap,
        g_NavCellsDone, g_NavRejectWall, g_NavRejectNoFloor, g_NavRejectSlope, g_NavRejectFootprint,
        (g_NavFrontier == null) ? -1 : g_NavFrontier.Length,
        g_NavSeedCount, g_NavSeedX, g_NavSeedY, g_NavSeedZ,
        LastWallFailReason[client], LastWallFailDist[client]);

    DebugBumpLineCount();
}
