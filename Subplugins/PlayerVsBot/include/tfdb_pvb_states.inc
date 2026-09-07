// tfdb_pvb_states.inc - game state machine: state selection + state handlers
// (UpdateBotState + all state functions: MOVE, DEFLECT, DODGE, ORBIT, etc.)
//
// ============================================================================
//  STATE TRANSITION TABLE (read this first)
// ============================================================================
//
//  UpdateBotState runs every tick. It evaluates conditions in priority order -
//  the FIRST match wins and the bot enters that state. Lower-priority states
//  are never reached if a higher one triggers.
//
//  Priority  Condition                          → State
//  --------  ----------------------------------  ----------------
//  1         2+ enemies in gang range           → GANG_ESCAPE
//  2a        Already feinting (time window)      → FEINT
//  2b        Rocket in range + CanOrbit          → ORBIT
//  2c        Rocket in deflect range + CanDeflect→ DEFLECT
//  2d        Rocket in range + !CanDeflect       → DODGE
//  3.4       Post-deflect reposition window      → REPOSITION
//  3.5       Enemy missed airblast (punish)      → PUNISH
//  3.6       Debug-states + rocket on teammate      → STEAL
//  3.7       Enemy near map edge                 → EDGE_PRESSURE
//  3.8       2+ rockets + airblast on cooldown   → PANIC
//  3.9       Enemy just deflected (pre-aim)      → COUNTER
//  3.10      Bait window active                  → BAIT
//  3.11      Chase window active                 → CHASE
//  4         Has enemies (normal movement)       → MOVE
//  4.5       can_walk=0 class, away from post    → GUARD
//  5         Nothing else                        → IDLE
//
//  Notes:
//  - Statue classes (isStatue) skip to DEFLECT on any rocket - no locomotion.
//  - can_walk=0 classes skip MOVE/CHASE/etc and fall to GUARD or IDLE.
//  - "Window" states (PANIC, COUNTER, BAIT, CHASE) use a timestamp gate:
//    once triggered, they stay active for a fixed duration before expiring.
//  - ProcessBotTick dispatches to the State_* handler for the current state.
//  - Each handler returns Action_Handled (consumed the tick) or
//    Plugin_Continue (let the engine handle movement).
//
// ============================================================================

int GetFrameEnemy(int client) {
    if (CachedFrameEnemyValid[client]) return CachedFrameEnemy[client];
    CachedFrameEnemy[client] = FindClosestEnemy(client);
    CachedFrameEnemyValid[client] = true;
    return CachedFrameEnemy[client];
}

void GetTickOrigin(int client, float pos[3]) {
    if (CachedTickPosValid[client]) {
        pos[0] = CachedTickPos[client][0];
        pos[1] = CachedTickPos[client][1];
        pos[2] = CachedTickPos[client][2];
        return;
    }
    GetClientAbsOrigin(client, pos);
    CachedTickPos[client][0] = pos[0];
    CachedTickPos[client][1] = pos[1];
    CachedTickPos[client][2] = pos[2];
    CachedTickPosValid[client] = true;
}

int GetFrameThreatCount(int client) {
    if (CachedFrameThreatsValid[client]) return CachedFrameThreats[client];
    CachedFrameThreats[client] = CountIncomingThreats(client);
    CachedFrameThreatsValid[client] = true;
    return CachedFrameThreats[client];
}

Action ProcessBotTick(PvBCommandContext ctx, int &buttons, float vel[3], float angles[3])
{
    int client = ctx.client;

    // Guard: alive and enabled
    if (!CfgEnabled || !IsPlayerAlive(client)) return Plugin_Continue;
    if (!((BotEnabled && ctx.isBot) || Allowed[client])) return Plugin_Continue;

    // === PERCEPTION ===
    GetCachedRocketForClient(client);

    // Update cached state (pressure, walls, gangers - throttled)
    UpdatePressureVector(client);
    MaybeScanWalls(client);
    UpdateGangerCount(client);

    // Enemy miss detection is episode-based. Observe one NEW secondary-
    // cooldown edge, wait briefly for object_deflected, then resolve exactly
    // once. All timestamps use GetGameTime because the weapon prop does.
    int enemy = GetFrameEnemy(client);
    int botTypeForMiss = GetEffectiveBotType(client);
    float gameTime = GetGameTime();
    if (EnemyMissWindow[client] > 0.0 && gameTime >= EnemyMissWindow[client])
        EnemyMissWindow[client] = 0.0;

    // Throttle the miss scan to 10Hz. The airblast cooldown is 0.75s, so
    // checking every tick (15ms) is 50x oversampled. 100ms resolution is
    // still 7.5x faster than the event we're tracking.
    if (enemy > 0 && IsPlayerAlive(enemy) && CfgPunishChance[botTypeForMiss] > 0
        && gameTime >= NextEnemyMissCheck[client])
    {
        NextEnemyMissCheck[client] = gameTime + 0.1;

        int enemyWeapon = GetPlayerWeaponSlot(enemy, 0);
        if (enemyWeapon > 0 && IsValidEntity(enemyWeapon))
        {
            float nextSecondary = GetEntPropFloat(enemyWeapon, Prop_Data, "m_flNextSecondaryAttack");
            if (nextSecondary > gameTime
                && nextSecondary > EnemyLastSecondaryReady[client] + 0.05)
            {
                EnemyLastSecondaryReady[client] = nextSecondary;
                EnemyAirblastCandidateTime[client] = gameTime;
                EnemyAirblastResolveTime[client] = gameTime + 0.12;
                EnemyAirblastCandidateUserId[client] = GetClientUserId(enemy);
            }
        }
    }

    if (EnemyAirblastResolveTime[client] > 0.0
        && gameTime >= EnemyAirblastResolveTime[client])
    {
        int candidateEnemy = GetClientOfUserId(EnemyAirblastCandidateUserId[client]);
        bool sameEnemy = candidateEnemy > 0 && candidateEnemy == enemy;
        bool confirmedDeflect = EnemyLastDeflectTime[client]
            >= EnemyAirblastCandidateTime[client] - 0.03;
        if (sameEnemy && !confirmedDeflect && CfgPunishChance[botTypeForMiss] > 0
            && GetRandomInt(1, 100) <= CfgPunishChance[botTypeForMiss])
        {
            EnemyMissWindow[client] = gameTime + 0.75;
            PvB_Log("[PVB-PUNISH] bot=%d detected enemy %d missed airblast",
                client, enemy);
        }
        EnemyAirblastCandidateTime[client] = 0.0;
        EnemyAirblastResolveTime[client] = 0.0;
        EnemyAirblastCandidateUserId[client] = 0;
    }

    // CHASE detection: if enemy is moving away and we haven't rolled yet,
    // roll chase chance. Track distance between ticks to detect retreat.
    int chaseEnemy = GetFrameEnemy(client);
    int chaseBotType = GetEffectiveBotType(client);
    bool canWalkChase = CfgCanWalk[chaseBotType];
    if (canWalkChase && CfgChaseChance[chaseBotType] > 0 && chaseEnemy > 0 && IsPlayerAlive(chaseEnemy)
        && !ChaseRollConsumed[client])
    {
        float ePos[3], bPos[3];
        GetClientAbsOrigin(chaseEnemy, ePos);
        GetClientAbsOrigin(client, bPos);
        float dist = GetVectorDistance(ePos, bPos);

        if (LastEnemyDist[client] > 0.0 && dist > LastEnemyDist[client] + 50.0)
        {
            // Enemy moved 50+ HU away since last check - fleeing
            ChaseRollConsumed[client] = true;
            if (GetRandomInt(1, 100) <= CfgChaseChance[chaseBotType])
            {
                ChaseUntil[client] = gameTime + 1.5;  // 1.5s chase episode
            }
        }
        LastEnemyDist[client] = dist;
    }

    // Pick state for this tick
    UpdateBotState(client);

    // Snapshot before dispatch so the post-deflect block below can tell
    // "a drag window that's already been running for a tick or more" apart
    // from "State_Deflect just armed a brand-new one THIS tick" - see the
    // justArmedDrag comment below.
    float prevPostDeflectUntil = PostDeflectUntil[client];

    // Cleared once per tick here rather than inside any single leaf: State_Move
    // used to own this flag, so states that never call it reported whatever
    // the last MOVE tick left behind.
    LastEdgeOverride[client] = false;

    // Execute state action (flat dispatch - max depth 2)
    Action result = Plugin_Continue;
    switch (view_as<BotState>(BotState_[client]))
    {
        case STATE_GANG_ESCAPE:  result = State_GangEscape(client, buttons, vel);
        case STATE_DEFLECT:      result = State_Deflect(client, buttons, vel, angles);
        case STATE_DODGE:        result = State_Dodge(client, buttons, vel);
        case STATE_ORBIT:        result = State_Orbit(client, buttons, vel, angles);
        case STATE_MOVE:         result = State_Move(client, buttons, vel, angles);
        case STATE_GUARD:        result = State_Guard(client, buttons, vel, angles);
        case STATE_IDLE:         result = State_Idle(client, vel, angles);
        case STATE_PUNISH:       result = State_Punish(client, buttons, vel, angles);
        case STATE_REPOSITION:   result = State_Reposition(client, buttons, vel, angles);
        case STATE_FEINT:        result = State_Feint(client, buttons, vel, angles);
        case STATE_STEAL:        result = State_Steal(client, buttons, vel, angles);
        case STATE_EDGE_PRESSURE: result = State_EdgePressure(client, buttons, vel, angles);
        case STATE_PANIC:        result = State_Panic(client, buttons, vel, angles);
        case STATE_CHASE:        result = State_Chase(client, buttons, vel, angles);
        case STATE_COUNTER:      result = State_Counter(client, buttons, vel, angles);
        case STATE_BAIT:         result = State_Bait(client, buttons, vel, angles);
    }

    // === POST-DEFLECT DRAG ===
    // After a deflect, apply the move set's aim direction for a short window.
    // The TFDB core reads eye angles once after the fixed global drag delay
    // to set the rocket's new direction. The bot must SNAP to the drag direction
    // immediately - real players flick their mouse, not gradually turn.
    //
    // BUT: if a DIFFERENT rocket is incoming (within airblast range), cancel the
    // drag and let State_Deflect handle the new threat. The drag is only useful when
    // the bot is safe from incoming rockets.
    //
    // Comparing against PostDeflectRocketEnt (not just "is any rocket cached")
    // matters: TFDB doesn't reassign the just-deflected rocket's target away
    // from this bot until the core's drag-delay deadline elapses - the same
    // delay this drag window exists to exploit. So GetCachedRocketForClient()
    // legitimately keeps reporting the just-deflected rocket as "targeting me"
    // for the rocket's entire remaining flight window, not due to stale
    // caching. Without this check, every deflect cancelled its own drag on
    // the same tick it was armed, before the delayed drag read could ever
    // see it - the bot could deflect but every move set (wave/bounce/upspike/
    // downspike/direct/backfire) was silently inert.
    float nowPost = GetEngineTime();

    // State_Deflect just aimed angles[] AT THE ROCKET so THIS tick's airblast
    // actually connects (its own comment says so explicitly). If State_Deflect
    // armed the drag window during the dispatch call above (PostDeflectUntil
    // grew from what it was before dispatch), that fire-aim belongs to THIS
    // tick's usercmd - overwriting angles[] here too would send the airblast
    // aimed at the move's post-deflect direction (e.g. -45 pitch for upspike)
    // instead of at the rocket, and the airblast misses. Let the drag start
    // applying from the NEXT tick onward instead, once the fire-aim usercmd
    // has already gone out.
    bool justArmedDrag = PostDeflectUntil[client] > prevPostDeflectUntil;

    if (!justArmedDrag && nowPost < PostDeflectUntil[client])
    {
        // Check if a genuinely different rocket is incoming - if so, cancel drag
        int newRocket = GetCachedRocketForClient(client);
        if (newRocket >= 0 && newRocket != PostDeflectRocketEnt[client] && view_as<BotState>(BotState_[client]) == STATE_DEFLECT)
        {
            // A different rocket is incoming and we're in DEFLECT state - cancel drag
            PostDeflectUntil[client] = 0.0;
        }
        else
        {
            float dragAng[3];
            dragAng[0] = PostDeflectAim[client][0];
            dragAng[1] = PostDeflectAim[client][1];
            dragAng[2] = 0.0;

            if (PostDeflectWave[client])
            {
                // Oscillate yaw for wave drag - real players wiggle mouse
                float t = GetEngineTime();
                dragAng[1] += 20.0 * Sine(2.0 * 3.14159 * 5.0 * t);
            }

            // SNAP to drag direction - no smoothing, no jitter.
            // This simulates a real mouse flick during the drag window.
            float snapAng[3];
            snapAng[0] = dragAng[0];
            snapAng[1] = dragAng[1];
            snapAng[2] = 0.0;
            ClampAngles(snapAng);
            TeleportEntity(client, NULL_VECTOR, snapAng, NULL_VECTOR);
            angles[0] = snapAng[0];
            angles[1] = snapAng[1];

            // CRITICAL: must return Plugin_Changed so the engine applies our angle override.
            // If the BT state function returned Plugin_Continue, the engine would ignore
            // our modified angles[] - the drag would silently fail.
            result = Plugin_Changed;
        }
    }

    // === FORCE-APPLY MOVEMENT (bots only) ===
    // client is a tf_bot_add native TF2 bot (CTFBot/NextBot), not a
    // SourceMod fake client whose movement is purely usercmd-driven. Its own
    // internal locomotion AI runs independently of this hook and was already
    // known to fight usercmd-level overrides - that's exactly why SmoothAim
    // forces angles through TeleportEntity instead of trusting the angles[]
    // copyback alone. vel[] never got the same treatment: every BT_* leaf
    // above computes a correct desired velocity into vel[], but leaving it
    // as only a usercmd copyback let the engine's locomotion silently overwrite it a
    // moment later, which is why bots visibly "decide" to move (see
    // DebugLogBotTick's vel=/speed= fields) while their actual position
    // barely changes. Force it the same way angles already are. Real human
    // clients must never have their velocity stomped like this - gate
    // strictly on ctx.isBot, not on the broader Allowed[client] flag.
    // Gated on ctx.isBot ALONE, not on result == Plugin_Changed.
    //
    // Requiring Plugin_Changed made control FAIL OPEN: any leaf that declined
    // to decide (State_Move returns Plugin_Continue when GetFrameEnemy comes back
    // <= 0, State_Deflect when the rocket ref goes stale) skipped this whole
    // block, so no TeleportEntity ran and the engine's own NextBot locomotion drove the
    // client for that tick. For a plugin whose entire job is overriding that
    // locomotion, "when in doubt, give it back to the thing we're fighting" is
    // backwards.
    //
    // Measured: 4,686 ticks across all six bots sitting at spawn with
    // walls=OOOOOOOO, open=8, edgeDist 4-8, an enemy 3,300 units away and
    // reason=too_far - wanting to advance, in the clear, not moving. The tell
    // was btn=---------C: crouch was held, and this plugin never presses
    // IN_DUCK anywhere. Something else was steering.
    //
    // Now the bot is always under our control. If no leaf produced a
    // velocity this tick we hold position deliberately (below) rather than
    // letting the engine's locomotion fill the gap - failing to a stand is
    // recoverable and legible; failing to a second controller is neither.
    if (ctx.isBot)
    {
        LastLeafDecided[client] = (result == Plugin_Changed);

        // A statue is an anchored turret, not a low-mobility bot. Pin it to
        // the post captured at spawn every tick so NextBot locomotion,
        // knockback, gang pressure, and residual friction cannot move it.
        // Aim and IN_ATTACK2 from State_Deflect are preserved.
        int botType = GetEffectiveBotType(client);
        if (ClassIsStatueLike[botType] && BotGuardPosValid[client])
        {
            float zeroVel[3] = {0.0, 0.0, 0.0};
            vel[0] = 0.0;
            vel[1] = 0.0;
            vel[2] = 0.0;
            TeleportEntity(client, BotGuardPos[client], NULL_VECTOR, zeroVel);

            if (ctx.isBot)
            {
                DebugLogBotTick(client, vel, angles, buttons);
                DebugDrawBotState(client, vel, angles);
            }
            return Plugin_Changed;
        }

        if (result != Plugin_Changed)
        {
            // vel[] currently holds whatever the engine's locomotion wanted. Discard it.
            vel[0] = 0.0;
            vel[1] = 0.0;
            result = Plugin_Changed;
        }
        // Safety net matching this map's own intended design, not a
        // heuristic. tfdb_abyss_v4's ring is meant to be lethal to fall off
        // - a trigger below it is supposed to kill/teleport anyone who
        // falls, same as it would a real player. Debug logs proved the
        // bots are somehow passing through that trigger untouched: they
        // land on real floor far below (-2079) and keep playing normally
        // instead of dying, no death event anywhere in the log. This is
        // most likely the same root pattern behind several other bugs this
        // session - tf_bot_add NextBot entities don't always process the
        // world the same way a real player's movement pipeline does. Since
        // I can't inspect or fix the trigger itself, enforce the same rule
        // directly: fall far enough below where this bot actually spawned
        // and it dies here, exactly like the map intends.
        float curPos[3];
        GetTickOrigin(client, curPos);
        if (BotGuardPosValid[client] && curPos[2] < BotGuardPos[client][2] - FALL_KILL_DEPTH)
        {
            // Direct proof this branch actually ran, independent of whether
            // ForcePlayerSuicide's death event fires/logs correctly -
            // confirmed bots reaching -2079 alive with zero DECISION/Death
            // lines, so the failure could be here OR downstream of this call.
            PvB_Log("[PVB-FALLKILL] bot=%d z=%.0f spawnZ=%.0f threshold=%.0f - forcing suicide",
                client, curPos[2], BotGuardPos[client][2], BotGuardPos[client][2] - FALL_KILL_DEPTH);
            ForcePlayerSuicide(client);

            // Unconditional backup, not gated on whether the suicide above
            // actually took effect. This session has repeatedly found that
            // tf_bot_add NextBot entities don't process ordinary player
            // mechanics the same way real players do (angles needed a
            // direct TeleportEntity override, velocity needed the same,
            // gravity didn't accumulate without direct intervention) - if
            // CommitSuicide's death processing turns out to be another one
            // of those, this guarantees the bot is out of the void
            // immediately regardless, rather than depending on a mechanism
            // already shown untrustworthy for this entity type.
            float zeroVel[3] = {0.0, 0.0, 0.0};
            TeleportEntity(client, BotGuardPos[client], NULL_VECTOR, zeroVel);
            return result;
        }

        // Per-tick "about to step into nothing" guard, independent of the
        // periodic 8-direction scan. MaybeScanWalls only refreshes every
        // ~0.2s / 50 units moved - debug logs showed a bot reading a clean
        // walls=WWWWWWWW right up until the tick before it was already
        // several ticks deep into an accelerating fall (see the abyss_v4
        // capture: z=56 with all-clear walls, then z=37/13/-14 with the
        // edge only THEN flagged). It had already crossed the edge in the
        // gap between scans. This check uses THIS tick's actual decided
        // velocity against a fresh downward trace, so it can never be more
        // than one tick stale, unlike the throttled scan.
        // Read the entity's OWN current velocity once - used below both to
        // detect actual falling (not just what FL_ONGROUND claims) and to
        // preserve real vertical speed through the forced apply.
        float actualVel[3];
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", actualVel);

        bool grounded = (GetEntityFlags(client) & FL_ONGROUND) != 0;
        // FL_ONGROUND can lag a tick or more behind the real transition -
        // debug logs showed z accelerating downward (gravity's signature)
        // for several ticks while FL_ONGROUND still read true and this
        // guard never fired. Trust the entity's actual vertical velocity
        // instead: meaningfully negative means it's already falling,
        // regardless of what the flag says.
        bool falling = actualVel[2] < -50.0;

        // === EDGE COMFORT (every state, not just State_Move) ===
        // State_Move has had an edge-comfort bias for a while, but it lived
        // inside that one leaf - so DEFLECT, DODGE, ORBIT and GANG_ESCAPE
        // could all still steer a bot off a ledge, and those are exactly the
        // states a bot is in when something interesting is happening. Applying
        // it here, on the final decided velocity, means every state inherits
        // it without each leaf having to remember to ask.
        //
        // It also never actually ran before now: edgeDist came from a nav
        // cache that mapped a phantom shelf ~10 cells past the real rim, so
        // the bot read "deep interior" while standing next to the drop
        // (edgeov=0 across every recorded session). With the cache finally
        // bounded by real geometry the distances mean something.
        //
        // Proportional rather than a hard veto: at the comfort threshold this
        // is a slight nudge inward, at the boundary cell it dominates. A hard
        // switch at a threshold is what makes a bot visibly stutter along a
        // rim - it flips between "fine" and "flee" every time the distance
        // ticks over, which reads as exactly the glitching-against-geometry
        // this is meant to stop.
        float edgeHoriz = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
        if (!falling && edgeHoriz > 1.0)
        {
            int edgeDist;
            if (NavCache_GetEdgeDist(curPos, edgeDist) && edgeDist < NAV_EDGE_COMFORT_CELLS)
            {
                float retreat[3];
                if (NavCache_RetreatDirection(curPos, retreat))
                {
                    float urgency = 1.0 - (float(edgeDist) / float(NAV_EDGE_COMFORT_CELLS));
                    if (urgency < 0.0) urgency = 0.0;
                    if (urgency > 1.0) urgency = 1.0;

                    float blended[3];
                    blended[0] = (vel[0] / edgeHoriz) * (1.0 - urgency) + retreat[0] * urgency;
                    blended[1] = (vel[1] / edgeHoriz) * (1.0 - urgency) + retreat[1] * urgency;
                    float bl = SquareRoot(blended[0] * blended[0] + blended[1] * blended[1]);
                    if (bl > 0.001)
                    {
                        vel[0] = (blended[0] / bl) * edgeHoriz;
                        vel[1] = (blended[1] / bl) * edgeHoriz;
                        LastEdgeOverride[client] = true;
                    }
                }
            }
        }

        float horizSpeed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);

        if (falling && !(buttons & IN_JUMP))
        {
            // Already falling - stop steering/drifting horizontally. A
            // real player falling off a ledge doesn't keep gliding forward
            // under their own power; let gravity do the one thing it does.
            // This also caps how far any fall that does slip past the edge
            // checks can carry the bot sideways before it lands.
            vel[0] = 0.0;
            vel[1] = 0.0;
        }
        else if (grounded && horizSpeed > 1.0 && !(buttons & IN_JUMP))
        {
            float stepDir[3];
            stepDir[0] = vel[0] / horizSpeed;
            stepDir[1] = vel[1] / horizSpeed;
            stepDir[2] = 0.0;

            if (!DirectionIsWalkable(curPos, stepDir, NEXT_STEP_CHECK_DIST, curPos[2]))
            {
                // The step this tick's velocity is about to take lands on
                // nothing walkable (no floor, or a slope steeper than TF2's
                // own walkable limit) - refuse it regardless of what the
                // scan-based decision said. Next tick's refreshed
                // state/scan picks a new direction instead of continuing.
                vel[0] = 0.0;
                vel[1] = 0.0;
            }
        }

        // TeleportEntity's velocity argument is the FULL 3-component
        // velocity, not just horizontal, and none of the BT_* leaves above
        // ever touch vel[2]. Gravity/falling is the ENGINE's own physics
        // simulation integrating downward speed frame over frame - it is
        // not something the usercmd's vel[2] copyback already reflects.
        // Forcing that raw copyback value through a direct engine call
        // every tick doesn't just leak a small residual (the on-ground
        // sinking seen last round, "fixed" by zeroing on FL_ONGROUND) -
        // in the air it RESETS actual fall speed back to that same small
        // input value every single tick instead of letting it accelerate,
        // which is exactly the "hovering down instead of falling normally"
        // symptom: gravity was never being allowed to accumulate.
        // Correct fix: only override the horizontal component. Preserve
        // the entity's own real vertical velocity untouched, on the ground
        // or in the air alike.
        // === ACCELERATION / FRICTION LIMITING ===
        // Force-applying the decided velocity outright is what makes the
        // movement read as an "artificial push" rather than a player. The
        // logged speed distribution is the proof: 250 samples at exactly 300
        // and 41 at 299, with nothing in between - the bot is only ever at
        // full sprint or stopped dead, switching between them in one tick.
        //
        // Source moves players by ACCELERATING toward the wish direction at
        // sv_accelerate * maxspeed HU/s^2 (3000 for a 300 HU/s Pyro - about
        // 45 HU/s per tick at 66 tick, so ~0.1s from a standstill to full
        // speed), and slowing them by FRICTION, which is gentler still. That
        // asymmetry is most of what "moving like a player" looks like: quick
        // off the mark, but sliding to a halt rather than stopping dead.
        //
        // Reproduce both against the server's own cvars, so a server running
        // non-default movement gets bots that match its feel instead of ours.
        float ft = GetTickInterval();
        float maxSpeed = GetEntPropFloat(client, Prop_Data, "m_flMaxspeed");
        if (maxSpeed <= 0.0) maxSpeed = 300.0;

        float svAccel  = g_CachedAccel;
        float svFric   = g_CachedFriction;
        float svStop   = g_CachedStop;

        float curX = actualVel[0], curY = actualVel[1];
        float curLen = SquareRoot(curX * curX + curY * curY);
        float wishLen = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);

        if (wishLen < 1.0)
        {
            // Nothing wanted this tick - coast down under friction instead
            // of snapping to zero. This is the single most unnatural part of
            // the old behaviour: real players never stop instantly.
            if (curLen > 0.1)
            {
                float drop = (curLen < svStop ? svStop : curLen) * svFric * ft;
                float newLen = curLen - drop;
                if (newLen < 0.0) newLen = 0.0;
                vel[0] = curX / curLen * newLen;
                vel[1] = curY / curLen * newLen;
            }
        }
        else
        {
            float maxDelta = svAccel * maxSpeed * ft;
            float dvx = vel[0] - curX;
            float dvy = vel[1] - curY;
            float dvLen = SquareRoot(dvx * dvx + dvy * dvy);
            if (dvLen > maxDelta && dvLen > 0.001)
            {
                vel[0] = curX + (dvx / dvLen) * maxDelta;
                vel[1] = curY + (dvy / dvLen) * maxDelta;
            }
        }

        // Absolute speed cap: the acceleration limiter above only limits
        // the rate of CHANGE, not the magnitude itself. A bot whose
        // m_flMaxspeed was boosted (gang escape) and then not restored
        // (before the per-tick fix) could carry an above-maxspeed velocity
        // indefinitely. Even with the fix, TeleportEntity's velocity
        // argument is a direct set - the engine's own movement code clamps
        // real players to maxspeed, so we must do the same here.
        float finalHoriz = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
        if (finalHoriz > maxSpeed && finalHoriz > 0.001) {
            vel[0] = (vel[0] / finalHoriz) * maxSpeed;
            vel[1] = (vel[1] / finalHoriz) * maxSpeed;
        }

        vel[2] = actualVel[2];
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vel);
    }

    // Dataset logging - bots only (sm_bot_test squads), gated by DebugActive
    // so this is free/no-op the rest of the time. See DebugLogBotTick.
    if (ctx.isBot) {
        DebugLogBotTick(client, vel, angles, buttons);
        DebugDrawBotState(client, vel, angles);
    }

    // Per-frame cache invalidation (review-pvb V1): the Cached* values are
    // tick-scoped by contract. Without this reset the first tick latches
    // enemy/threat/position for the bot's whole lifetime - state selection
    // then runs on day-old data.
    CachedTickPosValid[client] = false;
    CachedFrameEnemyValid[client] = false;
    CachedFrameThreatsValid[client] = false;

    return result;
}

void UpdateBotState(int client)
{
    int gangers   = GangerCount_[client];
    int botType   = GetEffectiveBotType(client);
    bool canWalk  = CfgCanWalk[botType];
    bool isStatue = ClassIsStatueLike[botType];

    BotState oldState = view_as<BotState>(BotState_[client]);

    // Priority 1: GANG ESCAPE
    if (!isStatue && gangers >= 2 && InGangRange(client))
    {
        BotState_[client] = STATE_GANG_ESCAPE;
        if (oldState != STATE_GANG_ESCAPE) LogStateChange(client, oldState, STATE_GANG_ESCAPE, "gangers");
        return;
    }

    // Priority 2: ROCKET
    //
    // Range-gated. This used to fire on ANY tracked rocket, and
    // GetCachedRocketForClient applies no distance cap at all to a rocket
    // that targets this bot - so one rocket anywhere on the map pinned the
    // bot in DEFLECT for its whole flight, including while it was flying
    // AWAY after being hit. The recorded symptom is a run of
    // "[PVB-WAIT] not facing" with dot sliding 0.55 -> -0.92 while dist grows
    // 81 -> 185: the bot patiently turning to face a departing rocket.
    //
    // It also starved every state below this one, which is why State_Deflect
    // ended up calling State_Move back out of itself in three places to get its
    // locomotion back. Cap the range here and those hacks stop being needed.
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt >= 0)
    {
        float botPos[3], rPos[3];
        GetClientAbsOrigin(client, botPos);
        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
        float rocketDist = GetVectorDistance(botPos, rPos);

        // Statue is an anchored turret: answer every rocket from its fixed
        // post and never detour into locomotion or trick-shot states.
        if (isStatue)
        {
            BotState_[client] = STATE_DEFLECT;
            if (oldState != STATE_DEFLECT) LogStateChange(client, oldState, STATE_DEFLECT, "rocket");
            return;
        }

        // A feint is a bounded one-rocket episode and must outrank the generic
        // rocket selector until its safe delay expires.
        if (oldState == STATE_FEINT && FeintUntil[client] > GetEngineTime()
            && EntRefToEntIndex(FeintRocketRef[client]) == rocketEnt)
        {
            BotState_[client] = STATE_FEINT;
            return;
        }

        if (rocketDist <= CfgRocketEngageDist[botType])
        {
            // ORBIT sits INSIDE the rocket branch, ahead of the deflect
            // decision - not after it as a lower priority. That ordering was
            // why STATE_ORBIT could never be reached: Priority 2 returned on
            // any tracked rocket, and CanOrbit requires a tracked rocket, so
            // the two conditions were mutually exclusive and State_Orbit had
            // never executed once in the plugin's life.
            //
            // Orbiting is a thing you do WITH an incoming rocket (circle it,
            // burn its turn rate, delay the deflect to wreck the opponent's
            // timing), so this is where it belongs.
            if (canWalk && CanOrbit(client))
            {
                BotState_[client] = STATE_ORBIT;
                if (oldState != STATE_ORBIT) LogStateChange(client, oldState, STATE_ORBIT, "orbit");
                return;
            }

            if (rocketDist <= CfgDeflectRange[botType])
            {
                if (CanDeflect(client))
                {
                    BotState_[client] = STATE_DEFLECT;
                    if (oldState != STATE_DEFLECT) LogStateChange(client, oldState, STATE_DEFLECT, "rocket");
                    return;
                }
                if (RocketRequiresDodge(client, rocketEnt))
                {
                    BotState_[client] = STATE_DODGE;
                    if (oldState != STATE_DODGE) LogStateChange(client, oldState, STATE_DODGE, "rocket_limit");
                    return;
                }
                // Departing/non-closing cached rocket: fall through to normal
                // positioning instead of dodging a non-threat.
            }
        }
        // Rocket known but out of engagement range: fall through to normal
        // movement. State_Move keeps the aim on it (see its FACING block), so
        // the bot is already pointed the right way when it does close.
    }

    // Priority 3.4: POST-DEFLECT REPOSITION
    // After deflecting, pre-position for the return rocket
    if (canWalk && PostDeflectRepositionUntil[client] > GetEngineTime())
    {
        BotState_[client] = STATE_REPOSITION;
        if (oldState != STATE_REPOSITION) LogStateChange(client, oldState, STATE_REPOSITION, "reposition");
        return;
    }

    // Priority 3.5: PUNISH MISSED AIRBLAST
    // If the enemy just airblasted at nothing (missed), they're on 0.75s cooldown.
    // This is the most vulnerable moment - close distance and deflect at them.
    if (canWalk && CfgPunishChance[botType] > 0 && GetFrameEnemy(client) > 0
        && EnemyMissWindow[client] > 0 && GetGameTime() < EnemyMissWindow[client])
    {
        {
            BotState_[client] = STATE_PUNISH;
            if (oldState != STATE_PUNISH) LogStateChange(client, oldState, STATE_PUNISH, "punish");
            return;
        }
    }

    // Priority 3.6: ROCKET STEAL
    // In debug-states mode, intercept rockets targeting nearby teammates
    if (canWalk && TFDBAvailable && CfgStealChance[botType] > 0 && DebugStatesMode && rocketEnt >= 0)
    {
        int rocketIndex = TFDB_FindRocketByEntity(rocketEnt);
        if (rocketIndex >= 0)
        {
            int rocketTarget = TFDB_GetRocketTarget(rocketIndex);
            if (rocketTarget > 0 && rocketTarget <= MaxClients && rocketTarget != client
                && IsClientInGame(rocketTarget) && IsPlayerAlive(rocketTarget)
                && GetClientTeam(rocketTarget) == GetClientTeam(client))
            {
                BotState_[client] = STATE_STEAL;
                if (oldState != STATE_STEAL) LogStateChange(client, oldState, STATE_STEAL, "steal");
                return;
            }
        }
    }

    // Priority 3.7: EDGE PRESSURE
    // On maps with edges, herd the enemy toward the drop
    if (canWalk && CfgEdgePressureChance[botType] > 0 && HasEnemies(client))
    {
        int enemy = GetFrameEnemy(client);
        if (enemy > 0 && IsPlayerAlive(enemy))
        {
            float ePos[3], bPos[3];
            GetClientAbsOrigin(enemy, ePos);
            GetClientAbsOrigin(client, bPos);
            int eDist;
            if (NavCache_GetEdgeDist(ePos, eDist) && eDist < NAV_EDGE_COMFORT_CELLS)
            {
                // Enemy is near an edge - pressure them
                BotState_[client] = STATE_EDGE_PRESSURE;
                if (oldState != STATE_EDGE_PRESSURE) LogStateChange(client, oldState, STATE_EDGE_PRESSURE, "edge_pressure");
                return;
            }
        }
    }

    // Priority 3.8: PANIC - multi-rocket + airblast cooldown = pure survival
    // Overrides everything below because the bot is about to die.
    if (canWalk && CfgPanicChance[botType] > 0 && rocketEnt >= 0
        && !CanDeflect(client) && CountActiveThreats(client) >= 2)
    {
        if (!PanicRollConsumed[client])
        {
            PanicRollConsumed[client] = true;
            if (GetRandomInt(1, 100) <= CfgPanicChance[botType])
                PanicUntil[client] = GetGameTime() + 0.75; // airblast cooldown window
        }
        if (PanicUntil[client] > GetGameTime())
        {
            BotState_[client] = STATE_PANIC;
            if (oldState != STATE_PANIC) LogStateChange(client, oldState, STATE_PANIC, "panic");
            return;
        }
    }

    // Priority 3.9: COUNTER - pre-aim where enemy's deflected rocket will come from
    // Triggered right after the enemy deflects - predicts incoming direction.
    if (canWalk && CfgCounterChance[botType] > 0 && CounterPreAimUntil[client] > GetGameTime())
    {
        BotState_[client] = STATE_COUNTER;
        if (oldState != STATE_COUNTER) LogStateChange(client, oldState, STATE_COUNTER, "counter");
        return;
    }

    // Priority 3.10: BAIT - bait enemy airblast, then punish the miss
    if (canWalk && CfgBaitChance[botType] > 0 && BaitUntil[client] > GetGameTime())
    {
        BotState_[client] = STATE_BAIT;
        if (oldState != STATE_BAIT) LogStateChange(client, oldState, STATE_BAIT, "bait");
        return;
    }

    // Priority 3.11: CHASE - pursue a fleeing enemy
    if (canWalk && CfgChaseChance[botType] > 0 && HasEnemies(client) && ChaseUntil[client] > GetGameTime())
    {
        BotState_[client] = STATE_CHASE;
        if (oldState != STATE_CHASE) LogStateChange(client, oldState, STATE_CHASE, "chase");
        return;
    }

    // Priority 4: MOVEMENT
    if (canWalk && HasEnemies(client))
    {
        BotState_[client] = STATE_MOVE;
        if (oldState != STATE_MOVE) LogStateChange(client, oldState, STATE_MOVE, "move");
        return;
    }

    // Priority 4.5: GUARD RETURN for custom non-statue can_walk=0 classes.
    // Statue itself is pinned directly and never selects locomotion. Hysteresis via
    // ReturningToGuard: once triggered, keep walking back until actually
    // arrived rather than stopping the instant distance dips under the
    // trigger threshold.
    if (!canWalk && !isStatue && BotGuardPosValid[client])
    {
        float curPos[3];
        GetClientAbsOrigin(client, curPos);
        float distFromPost = GetVectorDistance(curPos, BotGuardPos[client]);

        if (ReturningToGuard[client]) {
            if (distFromPost <= GUARD_ARRIVE_DIST) ReturningToGuard[client] = false;
        } else if (distFromPost > GUARD_TRIGGER_DIST) {
            ReturningToGuard[client] = true;
        }

        if (ReturningToGuard[client])
        {
            BotState_[client] = STATE_GUARD;
            if (oldState != STATE_GUARD) LogStateChange(client, oldState, STATE_GUARD, "guard_return");
            return;
        }
    }

    // Priority 5: IDLE
    BotState_[client] = STATE_IDLE;
    if (oldState != STATE_IDLE) LogStateChange(client, oldState, STATE_IDLE, "idle");
}

bool InGangRange(int client)
{
    int botType = GetEffectiveBotType(client);
    float gangRange = CfgGangEscapeRange[botType];
    if (gangRange <= 0.0) return false;

    int botTeam = GetClientTeam(client);
    float botPos[3];
    GetClientAbsOrigin(client, botPos);

    int nearbyEnemies = 0;
    for (int enemy = 1; enemy <= MaxClients; enemy++)
    {
        if (enemy == client) continue;
        if (!IsClientInGame(enemy) || !IsPlayerAlive(enemy)) continue;
        if (GetClientTeam(enemy) == botTeam) continue;

        float enemyPos[3];
        GetClientAbsOrigin(enemy, enemyPos);
        if (GetVectorDistance(botPos, enemyPos) < gangRange)
            nearbyEnemies++;
    }
    return nearbyEnemies >= 2;
}

bool JumpEvadeSafe(int client)
{
    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    vel[2] = 0.0;
    if (GetVectorLength(vel) < 20.0) return true;  // barely moving, momentum can't carry it anywhere

    float ang[3];
    GetVectorAngles(vel, ang);
    int dirIdx = WorldYawToDirIndex(ang[1]);
    return !WallBlocked_[client][dirIdx];
}

bool CanDeflect(int client)
{
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt < 0) return false;

    int botType = GetEffectiveBotType(client);

    // Max deflect count check
    if (CfgMaxDeflectCount[botType] > 0 && DeflectCount[client] >= CfgMaxDeflectCount[botType])
        return false;

    // Rocket speed check
    float rVel[3];
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rVel);
    float rocketSpeed = GetVectorLength(rVel);
    if (CfgMaxDeflectSpeed[botType] > 0.0 && rocketSpeed > CfgMaxDeflectSpeed[botType])
        return false;

    // NOTE: Airblast cooldown is NOT checked here.
    // The state should always be DEFLECT when a rocket is incoming.
    // State_Deflect handles the cooldown internally - it just waits for the
    // right moment to press the airblast button.

    // Check the rocket is actually targeting this bot or closing on it
    if (!IsRocketTargetingClient(rocketEnt, client))
    {
        float botPos[3], rocketPos[3];
        GetClientAbsOrigin(client, botPos);
        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);
        float dist = GetVectorDistance(botPos, rocketPos);
        if (dist > 600.0) return false;  // too far to deflect

        float closingSpeed = GetRocketClosingSpeed(rocketPos, rVel, botPos);
        if (closingSpeed <= 200.0) return false;  // not approaching
    }

    return true;
}

bool RocketRequiresDodge(int client, int rocketEnt)
{
    if (rocketEnt < 0 || !IsValidEntity(rocketEnt)) return false;

    float botPos[3], rocketPos[3], rocketVel[3];
    GetClientAbsOrigin(client, botPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rocketVel);

    // A cached rocket that is already departing is not a dodge threat even if
    // TFDB has not updated its target yet. DODGE is reserved for an incoming
    // rocket the class deliberately refuses by count/speed limit.
    float closingSpeed = GetRocketClosingSpeed(rocketPos, rocketVel, botPos);
    return closingSpeed > 200.0;
}

float EstimateRocketTurnRate(int rocketIdx)
{
    int rocketClass = TFDB_GetRocketClass(rocketIdx);
    float rate = TFDB_GetRocketClassTurnRate(rocketClass)
        + TFDB_GetRocketClassTurnRateIncrement(rocketClass) * float(TFDB_GetRocketDeflections(rocketIdx));

    RocketFlags flags = TFDB_GetRocketClassFlags(rocketClass);
    if (flags & RocketFlag_IsTRLimited)
    {
        float limit = TFDB_GetRocketClassTurnRateLimit(rocketClass);
        if (rate > limit) rate = limit;
    }
    return rate;
}

bool OrbitStillSafe(int client, int rocketEnt, float phaseDuration)
{
    float botPos[3], rPos[3], rVel[3];
    GetClientAbsOrigin(client, botPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rVel);
    float rocketSpeed = GetVectorLength(rVel);

    int botType = GetEffectiveBotType(client);
    if (rocketSpeed > CfgOrbitSpeedThreshold[botType]) return false;

    #if defined _tfdb_included
    if (TFDBAvailable && TFDB_IsDodgeballEnabled())
    {
        int rocketIdx = TFDB_FindRocketByEntity(rocketEnt);
        if (rocketIdx >= 0 && EstimateRocketTurnRate(rocketIdx) >= 0.30) return false;
    }
    #endif

    float distance = GetVectorDistance(botPos, rPos);
    float closingSpeed = GetRocketClosingSpeed(rPos, rVel, botPos);
    if (closingSpeed > 0.0 && (distance / closingSpeed) < phaseDuration) return false;

    return true;
}

void ClearOrbitEpisode(int client, bool consumeAttempt = true)
{
    OrbitLoopsRemaining[client] = 0;
    OrbitLoopsPlanned[client] = 0;
    OrbitPhaseIdx[client] = 0;
    OrbitPhaseStart[client] = 0.0;
    OrbitLoopDuration[client] = 0.0;
    OrbitEpisodeEnd[client] = 0.0;
    OrbitStartedFromCooldown[client] = false;
    if (consumeAttempt) OrbitRollPassed[client] = false;
}

void FinishOrbitEpisode(int client, const char[] reason)
{
    int planned = OrbitLoopsPlanned[client];
    int remaining = OrbitLoopsRemaining[client];
    int completed = planned - remaining;
    if (completed < 0) completed = 0;

    char source[16];
    strcopy(source, sizeof(source), OrbitStartedFromCooldown[client] ? "cooldown" : "chance");
    PvB_Log("[PVB-MOVE] bot=%d class=%s move=orbit_end reason=%s loops=%d/%d source=%s",
        client, BotClassKey[GetEffectiveBotType(client)], reason, completed, planned, source);

    char details[96];
    FormatEx(details, sizeof(details), "reason=%s loops=%d/%d source=%s", reason, completed, planned, source);
    DebugLogDecision(client, "OrbitEnd", details);
    ClearOrbitEpisode(client);
}

bool CanOrbit(int client)
{
    int botType = GetEffectiveBotType(client);
    bool activeEpisode = view_as<BotState>(BotState_[client]) == STATE_ORBIT
        && OrbitEpisodeEnd[client] > 0.0;

    if (!CfgCanOrbit[botType] || ClassIsStatueLike[botType] || !CfgCanWalk[botType])
    {
        if (activeEpisode) FinishOrbitEpisode(client, "disabled");
        return false;
    }

    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt < 0)
    {
        if (activeEpisode) FinishOrbitEpisode(client, "rocket_lost");
        return false;
    }

    // Geometry and impact safety are re-checked every tick, including during
    // an active episode. Multi-rocket pressure is not an automatic veto: a
    // safe orbit is specifically useful for managing several rockets.
    int openDirs = 0;
    for (int i = 0; i < 8; i++) if (!WallBlocked_[client][i]) openDirs++;
    if (openDirs < ORBIT_MIN_OPEN_DIRS)
    {
        if (activeEpisode) FinishOrbitEpisode(client, "blocked");
        return false;
    }

    float phaseDuration = OrbitLoopDuration[client] > 0.0
        ? OrbitLoopDuration[client] / 4.0
        : CfgMaxOrbitTime[botType] / 4.0;
    if (phaseDuration < 0.15) phaseDuration = 0.15;
    if (!OrbitStillSafe(client, rocketEnt, phaseDuration))
    {
        if (activeEpisode) FinishOrbitEpisode(client, "unsafe");
        return false;
    }

    // Once State_Orbit has initialized an episode, keep it selected until its
    // loop budget ends or the safety checks above fail. Do not re-roll chance
    // every tick; that produces stutter rather than an orbit.
    if (activeEpisode) return true;

    float now = GetEngineTime();
    bool onCooldown = (now - LastAirblastTime[client]) < AIRBLAST_COOLDOWN;

    int rocketRef = EntIndexToEntRef(rocketEnt);
    if (OrbitAttemptedRocket[client] == rocketRef) return false;

    if (OrbitRolledRocket[client] != rocketRef)
    {
        OrbitRolledRocket[client] = rocketRef;
        OrbitRollPassed[client] = (GetRandomInt(1, 100) <= CfgOrbitChance[botType]);
    }

    // Cooldown can force one safe attempt because the bot cannot deflect yet;
    // otherwise the configured chance is one attempt roll per rocket.
    bool eligible = onCooldown || OrbitRollPassed[client];
    if (eligible) OrbitStartedFromCooldown[client] = onCooldown && !OrbitRollPassed[client];
    return eligible;
}

bool HasEnemies(int client) { return GetFrameEnemy(client) > 0; }

int SelectMoveSet(int botType)
{
    int total = 0;
    for (int i = 0; i < NUM_MOVE_SETS; i++)
        total += CfgMoveWeight[i][botType];
    if (total <= 0) return 0;  // fallback to normal

    int roll = GetRandomInt(1, total);
    int cumulative = 0;
    for (int i = 0; i < NUM_MOVE_SETS; i++)
    {
        cumulative += CfgMoveWeight[i][botType];
        if (roll <= cumulative) return i;
    }
    return 0;
}

void MoveSetName(int move, char[] buf, int maxlen)
{
    switch (move)
    {
        case MOVE_NORMAL:    strcopy(buf, maxlen, "normal");
        case MOVE_WAVE:       strcopy(buf, maxlen, "wave");
        case MOVE_UPSPIKE:    strcopy(buf, maxlen, "upspike");
        case MOVE_DOWNSPIKE:  strcopy(buf, maxlen, "downspike");
        case MOVE_BOUNCE:     strcopy(buf, maxlen, "bounce");
        case MOVE_DIRECT:     strcopy(buf, maxlen, "direct");
        case MOVE_BACKFIRE:   strcopy(buf, maxlen, "backfire");
        default:              strcopy(buf, maxlen, "unknown");
    }
}

void LogStateChange(int client, BotState old, BotState newState, const char[] reason)
{
    if (!DebugActive) return;
    char oldName[16], newName[16];
    BotStateName(old, oldName, sizeof(oldName));
    BotStateName(newState, newName, sizeof(newName));
    PvB_Log("[PVB-STATE] bot=%d class=%s old=%s new=%s reason=%s",
        client, BotClassKey[GetEffectiveBotType(client)],
        oldName, newName, reason);

    char details[64];
    FormatEx(details, sizeof(details), "old=%s new=%s reason=%s", oldName, newName, reason);
    DebugLogDecision(client, "StateChange", details);
}

void BotStateName(BotState s, char[] buf, int maxlen)
{
    switch (s)
    {
        case STATE_IDLE:          strcopy(buf, maxlen, "IDLE");
        case STATE_GANG_ESCAPE:   strcopy(buf, maxlen, "GANG_ESCAPE");
        case STATE_DEFLECT:       strcopy(buf, maxlen, "DEFLECT");
        case STATE_DODGE:          strcopy(buf, maxlen, "DODGE");
        case STATE_ORBIT:          strcopy(buf, maxlen, "ORBIT");
        case STATE_MOVE:           strcopy(buf, maxlen, "MOVE");
        case STATE_GUARD:          strcopy(buf, maxlen, "GUARD");
        case STATE_PUNISH:         strcopy(buf, maxlen, "PUNISH");
        case STATE_REPOSITION:     strcopy(buf, maxlen, "REPOSITION");
        case STATE_FEINT:          strcopy(buf, maxlen, "FEINT");
        case STATE_STEAL:          strcopy(buf, maxlen, "STEAL");
        case STATE_EDGE_PRESSURE:  strcopy(buf, maxlen, "EDGE_PRESSURE");
        case STATE_PANIC:          strcopy(buf, maxlen, "PANIC");
        case STATE_CHASE:          strcopy(buf, maxlen, "CHASE");
        case STATE_COUNTER:        strcopy(buf, maxlen, "COUNTER");
        case STATE_BAIT:            strcopy(buf, maxlen, "BAIT");
        default:                strcopy(buf, maxlen, "UNKNOWN");
    }
}

bool AirblastWouldConnect(int client, int rocketEnt)
{
    if (rocketEnt < 0 || !IsValidEntity(rocketEnt)) return false;

    float botEye[3], rocketPos[3];
    GetClientEyePosition(client, botEye);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);

    float toRocket[3];
    MakeVectorFromPoints(botEye, rocketPos, toRocket);
    float dist = GetVectorLength(toRocket);
    if (dist > AIRBLAST_REACH) return false;
    if (NormalizeVector(toRocket, toRocket) <= 0.0) return false;

    float eyeAng[3], fwd[3];
    GetClientEyeAngles(client, eyeAng);
    GetAngleVectors(eyeAng, fwd, NULL_VECTOR, NULL_VECTOR);

    return GetVectorDotProduct(fwd, toRocket) >= AIRBLAST_CONE_DOT;
}

Action State_GangEscape(int client, int &buttons, float vel[3])
{
    int botType = GetEffectiveBotType(client);
    int gangers = GangerCount_[client];
    float now = GetEngineTime();

    float botPos[3];
    GetClientAbsOrigin(client, botPos);

    // Non-statue: sprint away from gang centroid
    // Compute gang centroid (average position of nearby enemies)
    float centroid[3];
    centroid = {0.0, 0.0, 0.0};
    int gangCount = 0;
    int botTeam = GetClientTeam(client);

    for (int enemy = 1; enemy <= MaxClients; enemy++)
    {
        if (enemy == client) continue;
        if (!IsClientInGame(enemy) || !IsPlayerAlive(enemy)) continue;
        if (GetClientTeam(enemy) == botTeam) continue;

        float enemyPos[3];
        GetClientAbsOrigin(enemy, enemyPos);
        float dist = GetVectorDistance(botPos, enemyPos);
        if (dist < CfgGangEscapeRange[botType])
        {
            centroid[0] += enemyPos[0];
            centroid[1] += enemyPos[1];
            gangCount++;
        }
    }

    if (gangCount == 0) return Plugin_Continue;

    centroid[0] /= float(gangCount);
    centroid[1] /= float(gangCount);

    // Escape through the biggest gap between gangers, not directly
    // away from the centroid. Fleeing from the centroid is predictable
    // - a real player looks for the open lane between two enemies and
    // sprint through it. If all gangers are on one side, the gap direction
    // naturally falls opposite them (same as centroid-flee). If they're
    // surrounding the bot, the gap is the widest angular space between
    // any two adjacent gangers.
    float flee[3];
    flee[2] = 0.0;

    if (gangCount <= 1)
    {
        // Single ganger - just flee directly away
        flee[0] = botPos[0] - centroid[0];
        flee[1] = botPos[1] - centroid[1];
    }
    else
    {
        // Multiple gangers - find the biggest angular gap between them
        // Sort gangers by angle from bot, then find the widest gap
        float angles[16];  // max 16 gangers
        int angleCount = 0;
        int botTeam2 = GetClientTeam(client);
        for (int enemy = 1; enemy <= MaxClients; enemy++)
        {
            if (enemy == client) continue;
            if (!IsClientInGame(enemy) || !IsPlayerAlive(enemy)) continue;
            if (GetClientTeam(enemy) == botTeam2) continue;
            float ePos[3];
            GetClientAbsOrigin(enemy, ePos);
            float dist = GetVectorDistance(botPos, ePos);
            if (dist < CfgGangEscapeRange[botType])
            {
                float toE[3];
                toE[0] = ePos[0] - botPos[0];
                toE[1] = ePos[1] - botPos[1];
                float ang = ArcTangent2(toE[1], toE[0]) * (180.0 / 3.14159265);
                if (ang < 0.0) ang += 360.0;
                angles[angleCount] = ang;
                angleCount++;
                if (angleCount >= 16) break;
            }
        }

        if (angleCount <= 1)
        {
            flee[0] = botPos[0] - centroid[0];
            flee[1] = botPos[1] - centroid[1];
        }
        else
        {
            // Sort angles (simple bubble sort - gangCount is tiny)
            for (int a = 0; a < angleCount - 1; a++)
                for (int b = a + 1; b < angleCount; b++)
                    if (angles[b] < angles[a])
                    {
                        float tmp = angles[a];
                        angles[a] = angles[b];
                        angles[b] = tmp;
                    }

            // Find the biggest gap between consecutive angles (including wrap)
            float bestGapAng = 0.0;
            float bestGapSize = 0.0;
            for (int a = 0; a < angleCount; a++)
            {
                float a1 = angles[a];
                float a2 = angles[(a + 1) % angleCount];
                float gap = a2 - a1;
                if (gap < 0.0) gap += 360.0;
                if (gap > bestGapSize)
                {
                    bestGapSize = gap;
                    // Escape direction is the midpoint of the gap
                    bestGapAng = a1 + gap * 0.5;
                }
            }

            // Convert gap midpoint angle to a direction vector
            float rad = bestGapAng * (3.14159265 / 180.0);
            flee[0] = Cosine(rad);
            flee[1] = Sine(rad);
        }
    }

    float len = SquareRoot(flee[0]*flee[0] + flee[1]*flee[1]);
    if (len < 0.001) { flee[0] = 1.0; flee[1] = 0.0; len = 1.0; }
    flee[0] /= len; flee[1] /= len;

    // Apply speed boost
    float boostMult = CfgGangSpeedBoostMult[botType];
    if (boostMult < 1.0) boostMult = 1.0;

    // Engine-native speed buff: TFCond_SpeedBuffAlly gives a 1.35x speed
    // multiplier (the Disciplinary Action buff). The engine handles
    // maxspeed recalculation, automatic expiry, and cleanup on death -
    // no manual m_flMaxspeed manipulation or per-tick restore needed.
    // This replaces the old SetEntPropFloat(m_flMaxspeed) approach which
    // required manual restore and could leak boosted speed across state
    // changes and respawns.
    if (boostMult > 1.0 && GangBoostUntil[client] < now)
    {
        GangBoostUntil[client] = now + 3.0;
        TF2_AddCondition(client, TFCond_SpeedBuffAlly, 3.0);
    }

    // TFCond_SpeedBuffAlly already multiplies m_flMaxspeed by 1.35x, so
    // reading m_flMaxspeed here gives us the buffed value. Don't multiply
    // by boostMult on top of that - the double-buff made aggressive bots
    // (boost_mult=2.5) sprint at 600 HU/s (engine cap) on top of the
    // 1.35x condition, which was 2.5x faster than a real player.
    // gang_speed_boost_mult > 1.0 now only controls whether the
    // TFCond_SpeedBuffAlly buff fires at all; the actual speed increase
    // is the engine's own 1.35x, not a manual multiplier.
    float gangMax = GetEntPropFloat(client, Prop_Data, "m_flMaxspeed");
    if (gangMax <= 0.0) gangMax = 300.0;
    float speed = gangMax;
    if (speed > 600.0) speed = 600.0;

    vel[0] = flee[0] * speed;
    vel[1] = flee[1] * speed;

    // Wall-aware adjustment
    float moveAng[3];
    GetVectorAngles(vel, moveAng);
    int desiredDir = WorldYawToDirIndex(moveAng[1]);
    int actualDir;
    if (!FindUnblockedDir(client, desiredDir, actualDir))
    {
        // Cornered - try jumping
        buttons |= IN_JUMP;
        vel[0] = 0.0; vel[1] = 0.0;
    }
    else if (actualDir != desiredDir)
    {
        float dirVec[3];
        DirIndexToWorldVector(actualDir, dirVec);
        vel[0] = dirVec[0] * speed;
        vel[1] = dirVec[1] * speed;
    }

    // Still try to deflect if rocket is incoming
    int rocketEnt = GetCachedRocketForClient(client);
    // Was `dist < 400`, again well beyond the 256 the blast can reach, and
    // with no cone test. Same wasted-cooldown failure as above.
    if (rocketEnt >= 0 && (now - LastAirblastTime[client]) >= AIRBLAST_COOLDOWN
        && AirblastWouldConnect(client, rocketEnt))
    {
        {
            buttons |= IN_ATTACK2;
            LastAirblastTime[client] = now;
        }
    }

    PvB_Log("[PVB-MOVE] bot=%d class=%s move=gang_escape gangers=%d speed=%d",
        client, BotClassKey[botType], gangers, RoundToFloor(speed));

    return Plugin_Changed;
}

bool TryEvadeStrafe(int client, int botType, const float rocketVel[3], float vel[3])
{
    bool canStrafeEvade = CfgEvadeStrafeEnabled[botType] && !ClassIsStatueLike[botType] && CfgCanWalk[botType];
    if (!canStrafeEvade) return false;

    // Perpendicular to the rocket's travel direction - same construction
    // State_Orbit uses for its own (differently-triggered) circling behavior.
    float perp[3];
    perp[0] = -rocketVel[1];
    perp[1] = rocketVel[0];
    perp[2] = 0.0;
    float perpLen = SquareRoot(perp[0]*perp[0] + perp[1]*perp[1]);
    if (perpLen <= 0.001) return false;

    perp[0] /= perpLen; perp[1] /= perpLen;

    float perpAng[3];
    GetVectorAngles(perp, perpAng);
    int dirIdx = WorldYawToDirIndex(perpAng[1]);
    int altIdx = (dirIdx + 4) % 8;

    bool startingNewEpisode = !(Evading[client] && CurrentEvadeAction[client] == EVADE_STRAFE);
    if (startingNewEpisode || StrafeEvadeSign[client] == 0)
    {
        EvadeStrafePickSide(client, dirIdx, altIdx);
        if (startingNewEpisode) DebugLogDecision(client, "EvadeStrafeStart", "");
    }
    else
    {
        EvadeStrafeCheckCommitment(client, dirIdx, altIdx);
    }

    if (StrafeEvadeSign[client] > 0)
    {
        vel[0] = perp[0] * 300.0;
        vel[1] = perp[1] * 300.0;
    }
    else if (StrafeEvadeSign[client] < 0)
    {
        vel[0] = -perp[0] * 300.0;
        vel[1] = -perp[1] * 300.0;
    }
    else
    {
        vel[0] = 0.0;
        vel[1] = 0.0;  // deliberate hold, not a fallthrough to State_Move
    }
    return true;
}

void EvadeStrafePickSide(int client, int dirIdx, int altIdx)
{
    if (!WallBlocked_[client][dirIdx] && WallBlocked_[client][altIdx]) StrafeEvadeSign[client] = 1;
    else if (!WallBlocked_[client][altIdx] && WallBlocked_[client][dirIdx]) StrafeEvadeSign[client] = -1;
    else StrafeEvadeSign[client] = (GetRandomInt(0, 1) == 0) ? 1 : -1;
}

void EvadeStrafeCheckCommitment(int client, int dirIdx, int altIdx)
{
    bool committedBlocked = (StrafeEvadeSign[client] > 0) ? WallBlocked_[client][dirIdx] : WallBlocked_[client][altIdx];
    if (!committedBlocked) return;

    bool otherBlocked = (StrafeEvadeSign[client] > 0) ? WallBlocked_[client][altIdx] : WallBlocked_[client][dirIdx];
    StrafeEvadeSign[client] = otherBlocked ? 0 : -StrafeEvadeSign[client];
}

Action State_Deflect(int client, int &buttons, float vel[3], float angles[3])
{
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt < 0) return Plugin_Continue;

    int botType = GetEffectiveBotType(client);
    float botPos[3], botEye[3];
    GetClientAbsOrigin(client, botPos);
    GetClientEyePosition(client, botEye);

    float rocketPos[3], rocketVel[3];
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rocketVel);
    float rocketSpeed = GetVectorLength(rocketVel);

    // Calculate distance to rocket
    float distToRocket = GetVectorDistance(botPos, rocketPos);
    float now = GetEngineTime();

    // Neither jump-evasion path applies to bots that can't walk (statue-like
    // or explicitly can_walk=0). Those classes are supposed to just stand
    // and deflect in place - hopping around contradicts that identity, and
    // statues in particular reach STATE_DEFLECT for ANY rocket regardless of
    // distance (see UpdateBotState), so without this gate they'd jump at
    // rockets that aren't even close.
    bool canJumpEvade = !ClassIsStatueLike[botType] && CfgCanWalk[botType];

    // Safety net: if an evasion (jump-over or reposition) never got the
    // chance to resolve - rocket left range, got destroyed, etc. - don't
    // leave the bias/state stuck forever.
    if (Evading[client] && now >= EvadeEnd[client])
    {
        Evading[client] = false;
        CurrentEvadeAction[client] = EVADE_NONE;
    }

    // === JUMP-OVER CHECK ===
    // Rocket is slow, low to ground, very close to feet - hop it, then let
    // the normal aim/fire flow below handle the actual deflect once
    // airborne. This used to fire the airblast on the SAME tick as the jump
    // with a hardcoded 45-degree pitch that often didn't even point at the
    // rocket (angles[1]/yaw was never touched at all) - looked like random
    // jumping regardless of where the rocket actually was. Now it only
    // presses jump and biases the upcoming deflect toward upspike/backfire
    // (see SELECT MOVE SET below); the actual aim math is whatever the rest
    // of this function already computes correctly for every other deflect.
    if (canJumpEvade && !Evading[client] && rocketSpeed < 1500.0 && distToRocket < 200.0 && JumpEvadeSafe(client))
    {
        float rocketZ = rocketPos[2];
        float botZ = botPos[2];
        if (rocketZ < botZ - 20.0)  // rocket is below bot's feet
        {
            int jumpRoll = GetRandomInt(1, 100);
            if (jumpRoll <= CfgJumpOverChance[botType])
            {
                buttons |= IN_JUMP;
                Evading[client] = true;
                CurrentEvadeAction[client] = EVADE_JUMP;
                EvadeEnd[client] = now + 2.0;
                PvB_Log("[PVB-MOVE] bot=%d class=%s move=jump_over_start speed=%d deflects=%d dist=%d",
                    client, BotClassKey[botType], RoundToFloor(rocketSpeed), DeflectCount[client], RoundToFloor(distToRocket));
                char jumpDetails[64];
                FormatEx(jumpDetails, sizeof(jumpDetails), "speed=%d deflects=%d dist=%d",
                    RoundToFloor(rocketSpeed), DeflectCount[client], RoundToFloor(distToRocket));
                DebugLogDecision(client, "JumpOverStart", jumpDetails);
                return Plugin_Changed;
            }
        }
    }

    // === COMMIT POINT: TIME to impact, not distance to it ===
    //
    // The airblast box is fixed (256 HU, ~60 degree cone) so 240 is still the
    // hard ceiling - you physically cannot deflect further out. But firing at
    // a fixed 240 regardless of speed models the wrong skill entirely.
    //
    // Distance is not time. At 5,000 HU/s a 240-unit gap is about 3 ticks; at
    // 1,000 HU/s the same gap is 16. One trigger, wildly different difficulty,
    // and the failure is asymmetric: per the TF2 wiki, "airblast too early and
    // the projectile is not reflected, and a second airblast will not ready
    // before the collision" - an early miss is FATAL, not merely wasted,
    // because the cooldown outlasts the rocket's remaining flight.
    //
    // DEFAULT IS "fire as soon as it can possibly connect", not "wait".
    //
    // The first version of this defaulted to 0.08s, modelling the moment a
    // human commits. That was the wrong model: a bot is not a player and has
    // nothing to gain from a reaction window. Waiting only shrinks the number
    // of ticks in which range and cone both hold, so the bot blasted late,
    // missed, and ate the cooldown - measured as bots "airblasting nothing
    // and dying". Deflecting is deterministic; there is no skill being
    // simulated by deferring it.
    //
    // The knob is kept because delaying IS a legitimate per-class handicap
    // (and this project keeps difficulty in cfg, never hardcoded), but the
    // default is now high enough that fireDist clamps to the blast's own
    // reach at any realistic rocket speed. A server owner who wants a
    // sloppier class lowers it deliberately:
    //
    //   default 0.5s, 1000 HU/s -> wants 500 -> clamped to 240 (max range)
    //   set to 0.08s, 1000 HU/s -> 80: deliberately late, deliberately worse

    float closingSpeed = GetRocketClosingSpeed(rocketPos, rocketVel, botPos);
    if (closingSpeed < 1.0) closingSpeed = rocketSpeed;  // odd geometry - fall back to raw speed

    float fireDist = closingSpeed * CfgFireTimeToImpact[botType];
    // Timing variance: occasionally deflect slightly early or late to be unpredictable
    float variance = CfgTimingVariance[botType];
    if (variance > 0.0) {
        float jitter = GetRandomFloat(-variance, variance);
        fireDist += closingSpeed * jitter;
    }
    if (fireDist > AIRBLAST_FIRE_RANGE)            fireDist = AIRBLAST_FIRE_RANGE;
    if (fireDist < CfgFireMinDist[botType])   fireDist = CfgFireMinDist[botType];

    // Wait for the right moment - don't airblast if too far
    if (distToRocket > fireDist)
    {
        // No State_Move re-entry here any more. This leaf used to call the
        // movement leaf back out of itself, because UpdateBotState routed to
        // DEFLECT for a rocket at ANY distance and the bot would otherwise
        // stand frozen for the whole approach. That was a leaf working around
        // a broken priority order. UpdateBotState now range-gates the rocket
        // branch (CfgDeflectRange, default 300), so reaching this function at
        // all means the rocket is genuinely close - the remaining band
        // between AIRBLAST_FIRE_RANGE (240) and that gate is a few tenths of a
        // second of holding still and aiming, which is what a real player
        // does at that range anyway.

        // Rocket too far to fire - smoothly track it (not a hard snap) so
        // we're aimed correctly by the time it gets close. Overrides
        // whatever angle State_Move just set (it aims at the enemy, we need
        // the rocket instead).
        float aimAng[3];
        CalcAimAngles(botEye, rocketPos, aimAng);
        SmoothAim(client, aimAng, AimFactorForRocket(botType, distToRocket));
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];
        return Plugin_Changed;
    }

    // === AIM ALIGNMENT CHECK ===
    // The airblast only affects entities within ~60° of the bot's forward direction.
    // If the rocket is at the bot's side, the airblast cone misses it entirely.
    // Check that the bot is actually FACING the rocket before firing.
    //
    // CRITICAL: aim at the rocket's PREDICTED position next tick, not current.
    // At 5000 HU/s the rocket moves 76 HU per tick - if we aim at where it IS,
    // by the time the airblast processes the rocket has moved past the cone.
    float currentAng[3];
    GetClientEyeAngles(client, currentAng);
    float fwd[3];
    GetAngleVectors(currentAng, fwd, NULL_VECTOR, NULL_VECTOR);

    float toRocket[3];
    toRocket[0] = rocketPos[0] - botEye[0];
    toRocket[1] = rocketPos[1] - botEye[1];
    toRocket[2] = rocketPos[2] - botEye[2];
    NormalizeVector(toRocket, toRocket);

    float dot = GetVectorDotProduct(fwd, toRocket);
    // cos(50°) ≈ 0.643 - rocket must be within ~50° of where bot is facing
    // (airblast cone is ~60°, we use 50° for safety margin)
    if (dot < AIRBLAST_CONE_DOT)
    {
        // State_Move re-entry removed here too - same reasoning as the
        // too-far branch. With the rocket branch range-gated, being
        // misaligned this close means turning is the whole job.

        // Not facing the rocket - turn toward its predicted position.
        // Smoothed (not a hard TeleportEntity snap): this branch re-fires
        // every tick while misaligned, and the target angle shifts slightly
        // each tick as the rocket moves, so a raw snap here reads as rapid,
        // shaky re-aiming rather than a real player turning their view.
        // 0.75 is high enough to still reorient within a couple ticks for
        // genuinely urgent cases (the jump-reposition case right below is
        // one of them), just not an instant teleport every frame.
        float aimAng[3];
        CalcAimAngles(botEye, rocketPos, aimAng);
        SmoothAim(client, aimAng, AimFactorForRocket(botType, distToRocket));
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];

        // Rocket is BEHIND (more than ~90 degrees off) AND genuinely close -
        // jump while re-acquiring so recovering from a bad angle looks like a
        // real reposition instead of the bot just standing there spinning in
        // place. By the time the bot lands, the snap-aim above (which runs
        // every tick this branch is hit) has already turned it to face the
        // rocket's current position, so the rocket has effectively moved
        // from behind to back in front for a normal deflect once dot clears
        // the cone threshold below.
        //
        // The distance gate matters: State_Deflect dispatches for ANY tracked
        // rocket up to 600u away (see CanDeflect), not just imminent ones,
        // and dot<0 covers a full HALF of all possible facings - without a
        // tighter range check here this fired for rockets that were merely
        // somewhere nearby and not yet a real threat, which looked like
        // random jumping with no walking/movement logic ever getting a
        // chance to run. 400u keeps this reserved for "it's basically on
        // top of me" recoveries.
        // Throttled via NextEvadeCheck so it doesn't bunny-hop every tick
        // of a multi-tick re-turn.
        if (canJumpEvade && dot < 0.0 && distToRocket < 400.0 && now >= NextEvadeCheck[client] && JumpEvadeSafe(client))
        {
            // JumpEvadeSafe checked the bot's CURRENT actual velocity
            // direction (last tick's real physics state), but State_Move
            // (called above, at the top of this branch) may have just
            // computed a DIFFERENT vel[] this same tick - that's what
            // actually gets committed alongside the jump below, not
            // whatever direction JumpEvadeSafe happened to see. A jump
            // exempts this tick from the normal per-tick ground guard (see
            // ProcessBotTick's force-apply block), so if this exact vel[]
            // was never independently vetted, nothing else catches it
            // either - confirmed root cause of bots jumping straight off
            // the abyss_v4 ring while mid-reposition. Re-validate THIS
            // tick's real vel[] with the same authoritative check normal
            // walking already trusts before letting a jump carry it
            // somewhere never actually checked.
            float horizSpeed = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
            bool jumpVelSafe = true;
            if (horizSpeed > 1.0)
            {
                float jumpDir[3];
                jumpDir[0] = vel[0] / horizSpeed;
                jumpDir[1] = vel[1] / horizSpeed;
                jumpDir[2] = 0.0;
                jumpVelSafe = DirectionIsWalkable(botPos, jumpDir, NEXT_STEP_CHECK_DIST, botPos[2]);
            }
            if (!jumpVelSafe) { vel[0] = 0.0; vel[1] = 0.0; }

            buttons |= IN_JUMP;
            Evading[client] = true;
            CurrentEvadeAction[client] = EVADE_REPOSITION;
            EvadeEnd[client] = now + 2.0;
            NextEvadeCheck[client] = now + 1.0;

            char repoDetails[64];
            FormatEx(repoDetails, sizeof(repoDetails), "dot=%.2f dist=%d", dot, RoundToFloor(distToRocket));
            DebugLogDecision(client, "JumpReposition", repoDetails);
        }

        if (DebugActive)
            PvB_Log("[PVB-WAIT] bot=%d dot=%.2f < 0.64 (not facing, SNAP) dist=%d zDiff=%d",
                client, dot, RoundToFloor(distToRocket), RoundToFloor(rocketPos[2] - botPos[2]));
        return Plugin_Changed;
    }

    // Realigned - clear any in-progress reposition evasion.
    if (Evading[client] && CurrentEvadeAction[client] == EVADE_REPOSITION)
    {
        Evading[client] = false;
        CurrentEvadeAction[client] = EVADE_NONE;
    }

    // If on cooldown, track the rocket and hold the airblast button.
    // The engine will fire the airblast the moment the cooldown expires.
    bool onCooldown = (now - LastAirblastTime[client] < AIRBLAST_COOLDOWN);
    if (onCooldown)
    {
        // Recovery/delay strafe - see TryEvadeStrafe. Rocket is already
        // close and lined up (distance/alignment checked above); back off
        // and strafe clear instead of standing there waiting, aim staying
        // locked on the threat via SmoothAim below regardless of which
        // branch this takes.
        bool didStrafe = TryEvadeStrafe(client, botType, rocketVel, vel);

        if (didStrafe)
        {
            Evading[client] = true;
            CurrentEvadeAction[client] = EVADE_STRAFE;
            EvadeEnd[client] = now + 1.0;
        }
        else if (CfgCanWalk[botType])
        {
            State_Move(client, buttons, vel, angles);
        }

        // Smoothed, not a hard snap - this can hold for up to 0.75s (many
        // ticks), and the target angle drifts every tick as the rocket
        // moves, so a raw TeleportEntity here was a big source of the
        // "shaky screen" while tracking. Higher factor than the general
        // tracking case since alignment already matters here - about to fire.
        float aimAng[3];
        CalcAimAngles(botEye, rocketPos, aimAng);
        SmoothAim(client, aimAng, AimFactorForRocket(botType, distToRocket));
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];

        // DO NOT hold IN_ATTACK2 here.
        //
        // This used to keep the button down for the whole cooldown so "the
        // engine fires it the instant cooldown expires". That hands the
        // decision of WHEN to blast to the engine's own timer, and the engine
        // does not know or care whether a rocket is in range and inside the
        // cone at that instant. Result: bots blasting empty air, then dying -
        // because the wasted blast starts a fresh 0.75s cooldown that the
        // actual incoming rocket arrives inside of.
        //
        // It also corrupted our own bookkeeping. LastAirblastTime is stamped
        // where we PRESS, so once the engine started firing on its schedule
        // instead of ours the two clocks drifted apart, and every subsequent
        // "is the blast ready" test was answering about the wrong moment.
        //
        // One press, one deliberate shot: the fire path below is the only
        // place that presses, and it only runs once range, alignment and
        // cooldown all agree.
        return Plugin_Changed;
    }

    // Cooldown cleared - about to fire this tick. Clear any in-progress
    // strafe-evade episode so a stale commitment doesn't leak into the
    // next one.
    if (Evading[client] && CurrentEvadeAction[client] == EVADE_STRAFE)
    {
        Evading[client] = false;
        CurrentEvadeAction[client] = EVADE_NONE;
        StrafeEvadeSign[client] = 0;
    }

    // === SELECT MOVE SET ===
    int moveSet;
    if (Evading[client] && CurrentEvadeAction[client] == EVADE_JUMP)
    {
        // Jump-over deflect landing now: only the two moves that make sense
        // coming down from a hop over a grounded rocket - send it up and
        // over the opponent's head, or backfire it back the way it came.
        moveSet = (GetRandomInt(0, 1) == 0) ? view_as<int>(MOVE_UPSPIKE) : view_as<int>(MOVE_BACKFIRE);
        Evading[client] = false;
        CurrentEvadeAction[client] = EVADE_NONE;
        PvB_Log("[PVB-MOVE] bot=%d class=%s move=jump_over_land chosen=%s", client, BotClassKey[botType],
            moveSet == view_as<int>(MOVE_UPSPIKE) ? "upspike" : "backfire");
    }
    else
    {
        moveSet = SelectMoveSet(botType);
    }
    LastMoveSet[client] = moveSet;

    // Get enemy position for post-deflect aim target
    int enemy = GetFrameEnemy(client);
    float enemyPos[3];
    if (enemy > 0) GetClientAbsOrigin(enemy, enemyPos);
    else { enemyPos = botPos; enemyPos[2] += 100.0; }

    // === EXECUTE MOVE ===
    // REAL dodgeball flow:
    //   1. Aim at rocket → airblast (deflect it toward where you're facing)
    //   2. AFTER deflect → drag mouse to steer the rocket (wave, upspike, etc.)
    //
    // The TFDB core reads eye angles once at its fixed global deadline after
    // object_deflected to apply the drag. Our bot must:
    //   - Always aim at the rocket when airblasting (so the airblast connects)
    //   - Set a "post-deflect aim target" that the delayed one-shot read samples
    //
    // All moves aim at the rocket first. The move set only changes what
    // direction the bot faces AFTER the deflect fires.
    float aimAng[3];
    CalcAimAngles(botEye, rocketPos, aimAng);
    SmoothAim(client, aimAng, AimFactorForRocket(botType, distToRocket));
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    // Set post-deflect aim direction based on move set.
    // This is the direction the bot will face in the next few ticks,
    // which the TFDB delayed eye-angle sample applies as drag to the rocket.
    // We store it in a per-client "PostDeflectAim" array.
    switch (moveSet)
    {
        case MOVE_NORMAL:
        {
            // No drag - rocket goes straight toward enemy
            // Post-deflect aim: toward enemy
            float postAng[3];
            CalcAimAngles(botEye, enemyPos, postAng);
            PostDeflectAim[client][0] = postAng[0];
            PostDeflectAim[client][1] = postAng[1];
        }
        case MOVE_WAVE:
        {
            // Sine-wave drag - oscillating yaw after deflect
            PostDeflectAim[client][0] = aimAng[0];
            PostDeflectAim[client][1] = aimAng[1]; // will be oscillated in post-deflect tick
            PostDeflectWave[client] = true;
        }
        case MOVE_UPSPIKE:
        {
            // Aim up after deflect - rocket goes off opponent's screen
            // A spike is described as an "extremely fast upward flick" that
            // sends the rocket up in a high arch, specifically so the target
            // struggles to see and time it. -45 is not a spike, it is a
            // gentle lob - it barely changes the rocket's arc and gives the
            // opponent an easy read. Near-vertical is the actual technique
            // (the same value lzardy/tf2db-advancedbot uses).
            PostDeflectAim[client][0] = CfgSpikeUpPitch[botType];
            PostDeflectAim[client][1] = aimAng[1];
        }
        case MOVE_DOWNSPIKE:
        {
            // Aim down after deflect - rocket hits ground near opponent
            // Down spike drives the rocket into the ground to detonate it -
            // "useful when overwhelmed or for distraction". +30 doesn't reach
            // the floor at any useful range; it needs to be steep.
            PostDeflectAim[client][0] = CfgSpikeDownPitch[botType];
            PostDeflectAim[client][1] = aimAng[1];
        }
        case MOVE_BOUNCE:
        {
            // Aim at ground between bot and enemy after deflect
            float groundPoint[3];
            groundPoint[0] = (botPos[0] + enemyPos[0]) * 0.5;
            groundPoint[1] = (botPos[1] + enemyPos[1]) * 0.5;
            groundPoint[2] = botPos[2] - 50.0;
            float postAng[3];
            CalcAimAngles(botEye, groundPoint, postAng);
            PostDeflectAim[client][0] = postAng[0];
            PostDeflectAim[client][1] = postAng[1];
        }
        case MOVE_DIRECT:
        {
            // Aim straight at enemy after deflect - rocket flies directly at them
            float postAng[3];
            CalcAimAngles(botEye, enemyPos, postAng);
            PostDeflectAim[client][0] = postAng[0];
            PostDeflectAim[client][1] = postAng[1];
        }
        case MOVE_BACKFIRE:
        {
            // Backfire aims AT the enemy, like every other move.
            //
            // This used to do `postAng[1] += 180.0` - the angle toward the
            // enemy, flipped - so the bot pointed directly AWAY from them and
            // the post-deflect drag sent the rocket back past itself. It would
            // then blast its own rocket again at point-blank, deflections
            // incrementing every cooldown, speed climbing 250 each time. That
            // is the "bot deflected and its own rocket flew back at it while
            // the mph shot up" report, and at 5-10% weight it showed up as an
            // occasional inexplicable moment rather than a constant fault.
            //
            // The mistake was reading the technique's own description too
            // literally. "Orbit so rocket goes behind you, aim behind you and
            // airblast" - BEHIND YOU describes where the ROCKET is, not where
            // you send it. You circle until the rocket is at your back, turn to
            // face it, and blast it at the opponent from an angle they did not
            // expect. The destination was always the enemy.
            //
            // So what distinguishes a backfire is the SETUP (rocket behind you
            // when you fire), not the aim. The aim is the same as a direct.
            // Until State_Orbit is driving that setup deliberately, this behaves
            // as a direct shot - which is a correct shot, where the previous
            // version was a self-inflicted one.
            float postAng[3];
            CalcAimAngles(botEye, enemyPos, postAng);
            PostDeflectAim[client][0] = postAng[0];
            PostDeflectAim[client][1] = postAng[1];
        }
    }

    // Apply current angles
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    // Roll at most once for this rocket. A feint delays a ready airblast by
    // 0.15s, so require at least 0.22s time-to-impact; fast close-range
    // rockets always take the ordinary immediate deflect path.
    int feintRef = EntIndexToEntRef(rocketEnt);
    if (FeintRocketRef[client] != feintRef)
    {
        FeintRocketRef[client] = feintRef;
        FeintRollConsumed[client] = false;
    }
    if (!FeintRollConsumed[client])
    {
        FeintRollConsumed[client] = true;
        float timeToImpact = (closingSpeed > 1.0) ? distToRocket / closingSpeed : 0.0;
        if (CfgFeintChance[botType] > 0 && timeToImpact >= 0.22
            && GetRandomInt(1, 100) <= CfgFeintChance[botType])
        {
            FeintUntil[client] = GetEngineTime() + 0.15;
            BotState_[client] = STATE_FEINT;
            LogStateChange(client, STATE_DEFLECT, STATE_FEINT, "feint");
            return Plugin_Changed;
        }
    }

    // Press airblast
    buttons |= IN_ATTACK2;
    LastAirblastTime[client] = GetEngineTime();

    // Reposition is armed only by the confirmed object_deflected event, never
    // by an attempted airblast that may have missed.
    // Note: DeflectCount is incremented by Event_ObjectDeflected (real deflect only)

    // Activate post-deflect drag window - bot snaps to the move's direction
    // for the next 0.15s so TFDB's delayed one-shot sample reads it as drag.
    // The default drag delay is 0.045s (about 3 ticks at 66Hz),
    // so 0.15s covers the read window with margin.
    PostDeflectUntil[client] = GetEngineTime() + 0.15;
    PostDeflectWave[client] = (view_as<int>(moveSet) == view_as<int>(MOVE_WAVE));
    // Remember which rocket this drag window belongs to. TFDB doesn't retarget
    // the rocket away from this bot until its own drag-delay deadline
    // elapses (the same delay this drag window exists to exploit) - so
    // GetCachedRocketForClient() will keep reporting THIS rocket as "targeting
    // me" for the rocket's entire remaining flight-to-us window, not because
    // of stale caching but because TFDB genuinely hasn't reassigned it yet.
    // ProcessBotTick's "cancel drag on new threat" check needs this to tell
    // "the rocket I just hit" apart from an actually different incoming one.
    PostDeflectRocketEnt[client] = rocketEnt;

    // Log the move with full debug data for tuning
    char moveName[16];
    MoveSetName(moveSet, moveName, sizeof(moveName));

    // Get current eye angles for dot product logging
    float eyeAng[3];
    GetClientEyeAngles(client, eyeAng);
    float fwd2[3];
    GetAngleVectors(eyeAng, fwd2, NULL_VECTOR, NULL_VECTOR);
    float toR[3];
    toR[0] = rocketPos[0] - botEye[0];
    toR[1] = rocketPos[1] - botEye[1];
    toR[2] = rocketPos[2] - botEye[2];
    NormalizeVector(toR, toR);
    float aimDot = GetVectorDotProduct(fwd2, toR);

    // Height diff: positive = rocket above bot
    float zDiff = rocketPos[2] - botPos[2];

    PvB_Log("[PVB-MOVE] bot=%d class=%s move=%s speed=%d deflects=%d dist=%d firedist=%d tti=%.3f dot=%.2f zDiff=%d eye=[%.0f,%.0f] threats=%d",
        client, BotClassKey[botType], moveName,
        RoundToFloor(rocketSpeed), DeflectCount[client],
        RoundToFloor(distToRocket), RoundToFloor(fireDist),
        (closingSpeed > 1.0) ? (distToRocket / closingSpeed) : -1.0,
        aimDot, RoundToFloor(zDiff),
        eyeAng[0], eyeAng[1], GetFrameThreatCount(client));

    char deflectDetails[128];
    FormatEx(deflectDetails, sizeof(deflectDetails), "move=%s speed=%d deflects=%d dist=%d dot=%.2f zDiff=%d threats=%d",
        moveName, RoundToFloor(rocketSpeed), DeflectCount[client], RoundToFloor(distToRocket),
        aimDot, RoundToFloor(zDiff), GetFrameThreatCount(client));
    DebugLogDecision(client, "Deflect", deflectDetails);

    return Plugin_Changed;
}

Action State_Dodge(int client, int &buttons, float vel[3])
{
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt < 0) return Plugin_Continue;

    float botPos[3], rocketPos[3], rocketVel[3];
    GetClientAbsOrigin(client, botPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecAbsVelocity", rocketVel);

    // Perpendicular to rocket velocity (2D), then pick the wall-free side
    float perp[3];
    Perp2D(rocketVel, perp);
    if (!Normalize2D(perp)) { perp[0] = 1.0; perp[1] = 0.0; }

    int dirIdx = VecToDirIndex(perp);
    int altIdx = (dirIdx + 4) % 8;
    int chosenDir = PickBetterDir(client, dirIdx);
    if (chosenDir != dirIdx) { perp[0] = -perp[0]; perp[1] = -perp[1]; }

    vel[0] = perp[0] * 300.0;
    vel[1] = perp[1] * 300.0;

    // Both strafe directions blocked and rocket is slow - hop in place
    bool strafeBlocked = WallBlocked_[client][dirIdx] && WallBlocked_[client][altIdx];
    if (strafeBlocked && GetVectorLength(rocketVel) < 1500.0)
    {
        vel[0] = 0.0; vel[1] = 0.0;
        buttons |= IN_JUMP;
    }

    return Plugin_Changed;
}

Action State_Orbit(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float now = GetEngineTime();

    // WASD phases: 0=right(D), 1=back(S), 2=left(A), 3=forward(W)
    int rocketEnt = GetCachedRocketForClient(client);

    // Initialize orbit if just entering
    if (OrbitEpisodeEnd[client] <= 0.0)
    {
        // How many loops the bot would LIKE to attempt this time - randomized
        // per attempt (not always the configured max) so orbiting doesn't look
        // identical every time, then trimmed by wall space. This is only the
        // starting budget: OrbitStillSafe below can still cut it short every
        // tick if the rocket turns out to be too dangerous to keep circling.
        int baseLoops = CfgMaxOrbitLoops[botType];
        if (baseLoops < 1) baseLoops = 1;
        int loops = GetRandomInt(1, baseLoops);

        int openDirs = 0;
        for (int i = 0; i < 8; i++) if (!WallBlocked_[client][i]) openDirs++;
        // Tight but still safe spaces reduce the randomized budget by one;
        // integer-halving made configured 2- and 3-loop profiles both collapse
        // to one loop whenever only four or five directions were open.
        if (openDirs < 6 && loops > 1) loops--;

        float minLoopTime = CfgMinOrbitTime[botType];
        float maxLoopTime = CfgMaxOrbitTime[botType];
        if (minLoopTime < 0.6) minLoopTime = 0.6;
        if (maxLoopTime < minLoopTime) maxLoopTime = minLoopTime;
        float loopDuration = GetRandomFloat(minLoopTime, maxLoopTime);

        OrbitLoopsRemaining[client] = loops;
        OrbitLoopsPlanned[client] = loops;
        OrbitAttemptedRocket[client] = (rocketEnt >= 0) ? EntIndexToEntRef(rocketEnt) : -1;
        OrbitLoopDuration[client] = loopDuration;
        OrbitPhaseIdx[client] = 0;
        OrbitEpisodeEnd[client] = now + loopDuration * float(loops) + GetTickInterval() * 2.0;
        // Reset phase-0 timing for THIS orbit. Without this, a bot's second
        // and later orbits inherited the stale timestamp from the end of
        // their previous orbit, making the very next "is this phase done"
        // check true immediately - phase 0 (strafe right) got skipped or
        // cut short on every orbit after the bot's first.
        OrbitPhaseStart[client] = now;

        char orbitStartDetails[64];
        FormatEx(orbitStartDetails, sizeof(orbitStartDetails), "loops=%d loopTime=%.2f openDirs=%d",
            loops, loopDuration, openDirs);
        DebugLogDecision(client, "OrbitStart", orbitStartDetails);
    }

    float phaseDuration = OrbitLoopDuration[client] / 4.0;
    if (phaseDuration < 0.15) phaseDuration = 0.15;

    // Re-check safety EVERY tick, not just at entry. A rocket's turn rate and
    // speed both grow with deflections (see EstimateRocketTurnRate) - a rocket
    // that was safe to orbit when this loop started can become unsafe mid-orbit
    // on a tight cfg, and the "about to hit" closing-speed check in
    // OrbitStillSafe means a bot on a tight cfg naturally bails after partial
    // or even zero loops, while a bot on a loose cfg can ride out its full
    // randomized budget - no hardcoded loop cap needed either way.
    bool stillSafe = (rocketEnt >= 0) && OrbitStillSafe(client, rocketEnt, phaseDuration);

    // End only after the selected loop budget, the absolute safety deadline,
    // or a live geometry/impact safety failure. orbit_break_chance is rolled
    // once per COMPLETED loop below, never once per tick.
    bool timedOut = now >= OrbitEpisodeEnd[client];
    if (timedOut || OrbitLoopsRemaining[client] <= 0 || !stillSafe)
    {
        char endReason[16];
        strcopy(endReason, sizeof(endReason), !stillSafe ? "unsafe" : (timedOut ? "timeout" : "done"));
        FinishOrbitEpisode(client, endReason);

        // Airblast at end of orbit - but only if it can actually land.
        //
        // Orbiting deliberately runs the clock down, so this fires at whatever
        // moment the loop budget happens to expire. That instant has no reason
        // to coincide with the rocket being in the blast box, and an orbit
        // that ends with a wasted press is strictly worse than one that ends
        // with none: the bot comes out of the circle already on cooldown, with
        // the rocket still inbound. The guide's version of this is "right
        // click when the rocket is about to or is in front of you" - in
        // front, not merely nearby.
        if (rocketEnt >= 0 && (now - LastAirblastTime[client]) >= AIRBLAST_COOLDOWN
            && AirblastWouldConnect(client, rocketEnt))
        {
            buttons |= IN_ATTACK2;
            LastAirblastTime[client] = now;
        }
        return Plugin_Changed;
    }

    // Check if current phase is done. OrbitPhaseStart is seeded at orbit
    // entry above, so no bootstrap case is needed here.
    if (now - OrbitPhaseStart[client] >= phaseDuration)
    {
        OrbitPhaseIdx[client]++;
        // Advance on the planned schedule instead of resetting to `now`;
        // otherwise per-phase tick rounding accumulates and a multi-loop
        // episode hits its deadline before completing its configured loops.
        OrbitPhaseStart[client] += phaseDuration;
        if (OrbitPhaseIdx[client] > 3)
        {
            OrbitPhaseIdx[client] = 0;
            OrbitLoopsRemaining[client]--;
            if (OrbitLoopsRemaining[client] > 0 && CfgOrbitBreakChance[botType] > 0
                && GetRandomInt(1, 100) <= CfgOrbitBreakChance[botType])
            {
                OrbitLoopsRemaining[client] = 0;
            }
        }
    }

    // Execute movement for current phase
    float botPos[3];
    GetClientAbsOrigin(client, botPos);

    float angles2[3];
    GetClientEyeAngles(client, angles2);
    float fwd[3], right[3], up[3];
    GetAngleVectors(angles2, fwd, right, up);

    float speed = 300.0;

    switch (OrbitPhaseIdx[client])
    {
        case 0: // Strafe right (D)
        {
            vel[0] = right[0] * speed;
            vel[1] = right[1] * speed;
        }
        case 1: // Move back (S)
        {
            vel[0] = -fwd[0] * speed;
            vel[1] = -fwd[1] * speed;
        }
        case 2: // Strafe left (A)
        {
            vel[0] = -right[0] * speed;
            vel[1] = -right[1] * speed;
        }
        case 3: // Move forward (W)
        {
            vel[0] = fwd[0] * speed;
            vel[1] = fwd[1] * speed;
        }
    }

    // Wall check - if blocked, try alternate direction
    float moveAng[3];
    GetVectorAngles(vel, moveAng);
    int dirIdx = WorldYawToDirIndex(moveAng[1]);
    if (WallBlocked_[client][dirIdx])
    {
        int altDir;
        if (FindUnblockedDir(client, dirIdx, altDir))
        {
            float dirVec[3];
            DirIndexToWorldVector(altDir, dirVec);
            vel[0] = dirVec[0] * speed;
            vel[1] = dirVec[1] * speed;
        }
        else
        {
            // All 8 directions read wall-blocked. Pushing through is only
            // safe if the direction we push into isn't actually a void
            // edge - a wall bumps you to a stop, an edge doesn't stop
            // anything, it's a drop. Refuse to send the bot off a ledge
            // just because "some direction" was requested; only take a
            // confirmed non-edge direction, or stand still if truly none.
            int safeDir;
            if (FindNonEdgeDir(client, dirIdx, safeDir))
            {
                float dirVec[3];
                DirIndexToWorldVector(safeDir, dirVec);
                vel[0] = dirVec[0] * speed;
                vel[1] = dirVec[1] * speed;
            }
            else
            {
                vel[0] = 0.0; vel[1] = 0.0;
            }
        }
    }

    // Face the rocket during orbit (rocketEnt fetched once at the top of this function)
    if (rocketEnt >= 0)
    {
        float rocketPos[3], botEye[3];
        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);
        GetClientEyePosition(client, botEye);
        float aimAng[3];
        CalcAimAngles(botEye, rocketPos, aimAng);
        // Range-scaled like every other rocket track - an orbiting bot is
        // deliberately holding its blast, so there is no reason for it to
        // snap onto a rocket that is still far away.
        float botPosOrbit[3];
        GetClientAbsOrigin(client, botPosOrbit);
        SmoothAim(client, aimAng, AimFactorForRocket(botType, GetVectorDistance(botPosOrbit, rocketPos)));
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];
    }

    return Plugin_Changed;
}

void UpdatePressureVector(int client)
{
    float now = GetEngineTime();
    if (now < NextPressureUpdate[client]) return;
    NextPressureUpdate[client] = now + 0.2;

    float botPos[3], botEye[3];
    GetClientAbsOrigin(client, botPos);
    GetClientEyePosition(client, botEye);

    int botTeam = GetClientTeam(client);

    PressureVec[client][0] = 0.0;
    PressureVec[client][1] = 0.0;
    PressureVec[client][2] = 0.0;
    PressureScalarSum[client] = 0.0;
    PressureCount[client] = 0;

    float maxDist = 2000.0;

    for (int enemy = 1; enemy <= MaxClients; enemy++)
    {
        if (enemy == client) continue;
        if (!IsClientInGame(enemy) || !IsPlayerAlive(enemy)) continue;
        if (GetClientTeam(enemy) == botTeam) continue;

        float enemyPos[3];
        GetClientAbsOrigin(enemy, enemyPos);

        float dist = GetVectorDistance(botPos, enemyPos);
        if (dist > maxDist) continue;
        if (dist < 1.0) dist = 1.0;

        // Line of sight - skip enemies behind walls
        float enemyEye[3];
        GetClientEyePosition(enemy, enemyEye);
        TR_TraceRay(botEye, enemyEye, MASK_VISIBLE, RayType_EndPoint);
        if (TR_DidHit()) continue;

        // Push = (botPos - enemyPos) normalized, 2D only
        float push[3];
        push[0] = botPos[0] - enemyPos[0];
        push[1] = botPos[1] - enemyPos[1];
        push[2] = 0.0;

        float len = SquareRoot(push[0]*push[0] + push[1]*push[1]);
        if (len < 0.001) { push[0] = 1.0; push[1] = 0.0; len = 1.0; }
        push[0] /= len;
        push[1] /= len;

        // Inverse square weight - closer enemies push harder
        float weight = 1.0 / (dist * dist);
        push[0] *= weight;
        push[1] *= weight;

        PressureVec[client][0] += push[0];
        PressureVec[client][1] += push[1];
        PressureScalarSum[client] += weight;
        PressureCount[client]++;
    }

    PressureMag[client] = SquareRoot(
        PressureVec[client][0] * PressureVec[client][0] +
        PressureVec[client][1] * PressureVec[client][1]
    );

    // Cancellation ratio: |sum of pushes| / sum of |pushes|.
    //
    // This exists because the old flank test compared PressureMag against a
    // fixed 0.00001. Weights here are inverse-square (1/d^2), so that
    // constant is not "about zero" at all - solve 1/d^2 = 1e-5 and it is a
    // single enemy at 316 units. With cqc_min 300 / cqc_max 600, ANY lone
    // enemy in the normal fighting band read as "zero pressure" and the
    // break-flank branch won by default. Production data: 2,844 break_flank
    // samples against ZERO sweet_spot, across a whole session.
    //
    // A ratio has no scale to get wrong: ~1 means every enemy pushes the
    // same way (one side), ~0 means they cancel (genuinely surrounded).
    // It also resolves the ambiguity the magnitude never could - "nobody
    // near" and "perfectly flanked" both produce a tiny vector, but only the
    // second produces a tiny vector from LARGE opposing contributions.
    PressureCancelRatio[client] =
        (PressureScalarSum[client] > 0.0) ? (PressureMag[client] / PressureScalarSum[client]) : 1.0;
}

Action State_Move(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float botPos[3], botEye[3];
    GetClientAbsOrigin(client, botPos);
    GetClientEyePosition(client, botEye);

    int enemy = GetFrameEnemy(client);
    if (enemy <= 0) return Plugin_Continue;

    float enemyPos[3];
    GetClientAbsOrigin(enemy, enemyPos);

    float distToEnemy = GetVectorDistance(botPos, enemyPos);

    // CQC distance thresholds (needed before idle roll so it can gate on range)
    float cqcMin = CfgCqcMinDist[botType];
    float cqcMax = CfgCqcMaxDist[botType];
    float cqcFloor = CfgCqcFloorDist[botType];
    float cqcRetreat = CfgCqcRetreatDist[botType];

    // === IDLE ROLL ===
    // Only idle when already in the CQC band - a bot at 2000 units
    // should always be approaching, not standing still. The old code
    // rolled for idle at ANY distance, causing the bot to freeze at
    // spawn for idle_duration seconds 40% of the time.
    float now = GetEngineTime();
    if (now >= NextMoveDecision[client] && distToEnemy >= cqcMin && distToEnemy <= cqcMax)
    {
        NextMoveDecision[client] = now + GetRandomFloat(2.0, 5.0);
        int idleRoll = GetRandomInt(1, 100);
        if (idleRoll <= RoundToFloor(CfgIdleChance[botType]))
        {
            // Stand still for idle_duration
            float idleDur = CfgIdleDuration[botType];
            if (idleDur > 0.0) NextMoveDecision[client] = now + idleDur;
            strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "idle_roll");
            vel[0] = 0.0; vel[1] = 0.0;
            // Face enemy
            float aimAng[3];
            CalcAimAngles(botEye, enemyPos, aimAng);
            SmoothAim(client, aimAng, CfgAimEnemy[botType]);
            angles[0] = aimAng[0]; angles[1] = aimAng[1];
            return Plugin_Changed;
        }
    }

    // === DECIDE MOVEMENT DIRECTION ===
    float moveDir[3];
    moveDir[2] = 0.0;
    float speed = 300.0;

    // Floor-breach hysteresis: once retreating from a cqc_floor_dist breach,
    // keep retreating until cqc_retreat_dist is reached, not just until
    // distance ticks back over the floor by a hair. Without this,
    // cqc_retreat_dist was parsed from config and validated but never
    // actually consulted anywhere - the bot would immediately stop
    // retreating the instant it cleared the floor, then get pushed straight
    // back under it as the enemy kept closing, causing rapid oscillation
    // right at the floor line.
    if (RetreatingFromFloor[client])
    {
        if (distToEnemy >= cqcRetreat) RetreatingFromFloor[client] = false;
    }
    else if (distToEnemy < cqcFloor)
    {
        RetreatingFromFloor[client] = true;
    }

    if (RetreatingFromFloor[client])
    {
        strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "retreat_floor");
        // Too close - move away (anti-face-hug), all the way out to cqc_retreat_dist
        moveDir[0] = botPos[0] - enemyPos[0];
        moveDir[1] = botPos[1] - enemyPos[1];
        NormalizeVector(moveDir, moveDir);
        moveDir[2] = 0.0;

        // --- Trapped against the rim: slide, don't freeze ---
        // Backing straight away from someone who is walking you toward a
        // ledge eventually asks for a step into the void. Every safety layer
        // then correctly refuses it, and the bot ends up pinned in place -
        // which is exactly the reported exploit: walk at a bot near an edge
        // and it cannot escape.
        //
        // A player in that spot doesn't keep pressing back into the drop.
        // They slide ALONG the rim and get out sideways. Retreat direction
        // and edge safety aren't actually in conflict; only the assumption
        // that retreat must be directly-away was.
        float retreatAng[3];
        GetVectorAngles(moveDir, retreatAng);
        int retreatDir = WorldYawToDirIndex(retreatAng[1]);
        if (EdgeBlocked_[client][retreatDir])
        {
            // The two directions 90 degrees off the blocked retreat: both
            // still increase distance from the enemy (they are perpendicular
            // to the line to them, not toward them) while running parallel to
            // the edge instead of into it.
            int slideA = (retreatDir + 2) % 8;
            int slideB = (retreatDir + 6) % 8;
            bool aFree = !EdgeBlocked_[client][slideA];
            bool bFree = !EdgeBlocked_[client][slideB];

            int chosen = -1;
            if (aFree && bFree)
            {
                // Keep sliding the way we already were, so this doesn't
                // oscillate between the two while the enemy keeps pressing.
                chosen = (StrafeSideSign[client] >= 0) ? slideA : slideB;
            }
            else if (aFree) { chosen = slideA; StrafeSideSign[client] = 1;  }
            else if (bFree) { chosen = slideB; StrafeSideSign[client] = -1; }

            if (chosen >= 0)
            {
                DirIndexToWorldVector(chosen, moveDir);
            }
            // If BOTH slides are edges too, leave moveDir alone - the step
            // guard will stop it, and standing is genuinely correct when
            // every direction away is a drop.
        }
        speed = 300.0;
    }
    else if (PressureCount[client] >= 2 && PressureCancelRatio[client] < BREAK_FLANK_CANCEL_RATIO
             && distToEnemy <= cqcMax)
    {
        // Flanked means "enemies are pushing me from opposing sides", which
        // is a statement about their ARRANGEMENT, not about any magnitude.
        //
        // This used to test PressureMag < 0.00001. Pushes are weighted
        // 1/d^2, so that constant is a single enemy at 316 units - inside
        // the normal engagement band (cqc_min 300 / cqc_max 600). A lone
        // enemy therefore read as "zero pressure" and this branch beat all
        // real positioning: 2,844 break_flank samples vs ZERO sweet_spot in
        // one session. An earlier patch bolted on `distToEnemy <= cqcMax`
        // to contain it, which narrowed the symptom without touching the
        // cause; that gate is kept, but it is no longer what does the work.
        //
        // Two real requirements now, both scale-free: at least TWO enemies
        // contributing, and their pushes actually cancelling. One enemy can
        // never flank you no matter how the arithmetic lands.
        strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "break_flank");
        // === BREAK-FLANK ===
        // Enemies on opposite sides - move perpendicular to bot-enemy line
        float toEnemy[3];
        toEnemy[0] = enemyPos[0] - botPos[0];
        toEnemy[1] = enemyPos[1] - botPos[1];
        toEnemy[2] = 0.0;

        // Perpendicular: rotate 90 degrees
        moveDir[0] = -toEnemy[1];
        moveDir[1] = toEnemy[0];
        float len = SquareRoot(moveDir[0]*moveDir[0] + moveDir[1]*moveDir[1]);
        if (len > 0.001) { moveDir[0] /= len; moveDir[1] /= len; }
        else { moveDir[0] = 1.0; moveDir[1] = 0.0; }

        // Pick left or right (whichever has fewer walls)
        float perpAng[3];
        GetVectorAngles(moveDir, perpAng);
        int dirIdx = WorldYawToDirIndex(perpAng[1]);
        int altIdx = (dirIdx + 4) % 8;

        if (WallBlocked_[client][dirIdx] && !WallBlocked_[client][altIdx])
        {
            moveDir[0] = -moveDir[0];
            moveDir[1] = -moveDir[1];
        }
    }
    else if (distToEnemy > cqcMax)
    {
        strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "approach");
        // Toward the enemy's standoff ring. Speed is set proportionally
        // below - this branch only decides the DIRECTION.
        moveDir[0] = enemyPos[0] - botPos[0];
        moveDir[1] = enemyPos[1] - botPos[1];
        NormalizeVector(moveDir, moveDir);
        moveDir[2] = 0.0;
    }
    else if (distToEnemy < cqcMin)
    {
        strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "back_off");
        // Close - back off
        moveDir[0] = botPos[0] - enemyPos[0];
        moveDir[1] = botPos[1] - enemyPos[1];
        NormalizeVector(moveDir, moveDir);
        moveDir[2] = 0.0;
        speed = 200.0;
    }
    else
    {
        strcopy(LastMoveReason[client], sizeof(LastMoveReason[]), "sweet_spot");
        // === WASD MICRO-MOVEMENT ===
        // Real dodgeball players don't orbit their opponent. They tap A/D
        // for short bursts, pause to read the play, occasionally tap W/S
        // to fine-tune spacing. This simulates that pattern: pick a WASD
        // direction, hold it for a short tap, then re-roll.
        //
        // The old code committed to left or right for 1.2-2.5 seconds
        // continuously - that's a satellite orbiting, not a player dodging.
        float toEnemy[3];
        toEnemy[0] = enemyPos[0] - botPos[0];
        toEnemy[1] = enemyPos[1] - botPos[1];
        toEnemy[2] = 0.0;

        float now2 = GetEngineTime();

        // Commitment check: if we're mid-tap and the enemy hasn't moved
        // dramatically, finish the tap. Only re-roll if the tap expired
        // or the enemy sprinted away (>120 HU in one tick).
        float distDelta = FloatAbs(distToEnemy - WasdLastEnemyDist[client]);
        WasdLastEnemyDist[client] = distToEnemy;

        if (WasdCommitted[client] && now2 < WasdTapUntil[client] && distDelta < CQC_COMMIT_BREAK_DIST)
        {
            // Still mid-tap - continue current direction
            // (fall through to direction execution below)
        }
        else
        {
            WasdCommitted[client] = false;

            // Maybe pause between taps - a real player stops to read the play
            if (WasdDirection[client] != 0 && GetRandomInt(1, 100) <= WASD_PAUSE_CHANCE)
            {
                WasdDirection[client] = 0;  // stop
                WasdTapUntil[client] = now2 + GetRandomFloat(WASD_PAUSE_MIN, WASD_PAUSE_MAX);
                WasdCommitted[client] = true;
            }
            else
            {
                // Weighted random direction selection
                int roll = GetRandomInt(1, WASD_WEIGHT_SIDE + WASD_WEIGHT_FWD + WASD_WEIGHT_BACK + WASD_WEIGHT_STOP);
                roll -= WASD_WEIGHT_SIDE;
                if (roll <= 0)
                {
                    // Side-step: pick left or right (prefer the side with fewer walls)
                    float strafeAng[3];
                    GetVectorAngles(toEnemy, strafeAng);
                    int fwdDir = WorldYawToDirIndex(strafeAng[1]);
                    int leftDir = (fwdDir + 6) % 8;   // 90° left
                    int rightDir = (fwdDir + 2) % 8;  // 90° right
                    if (WallBlocked_[client][leftDir] && !WallBlocked_[client][rightDir])
                        WasdDirection[client] = 2;  // right (D)
                    else if (WallBlocked_[client][rightDir] && !WallBlocked_[client][leftDir])
                        WasdDirection[client] = 1;  // left (A)
                    else
                        WasdDirection[client] = (GetRandomInt(0, 1) == 0) ? 1 : 2;
                }
                else
                {
                    roll -= WASD_WEIGHT_FWD;
                    if (roll <= 0)
                        WasdDirection[client] = 3;  // forward (W) - close slightly
                    else
                    {
                        roll -= WASD_WEIGHT_BACK;
                        if (roll <= 0)
                            WasdDirection[client] = 4;  // back (S) - open slightly
                        else
                            WasdDirection[client] = 0;  // stop
                    }
                }
                WasdTapUntil[client] = now2 + GetRandomFloat(WASD_TAP_MIN, WASD_TAP_MAX);
                WasdCommitted[client] = true;
            }
        }

        // Convert WASD direction to world-space movement vector
        float toEnemyNorm[3];
        toEnemyNorm[0] = toEnemy[0];
        toEnemyNorm[1] = toEnemy[1];
        toEnemyNorm[2] = 0.0;
        float toLen = SquareRoot(toEnemyNorm[0]*toEnemyNorm[0] + toEnemyNorm[1]*toEnemyNorm[1]);
        if (toLen > 0.001) { toEnemyNorm[0] /= toLen; toEnemyNorm[1] /= toLen; }

        // Perpendicular (strafe) axis
        float perp[3];
        perp[0] = -toEnemyNorm[1];
        perp[1] = toEnemyNorm[0];
        perp[2] = 0.0;

        switch (WasdDirection[client])
        {
            case 0: // stop
            {
                moveDir[0] = 0.0; moveDir[1] = 0.0;
            }
            case 1: // left (A)
            {
                moveDir[0] = perp[0]; moveDir[1] = perp[1];
            }
            case 2: // right (D)
            {
                moveDir[0] = -perp[0]; moveDir[1] = -perp[1];
            }
            case 3: // forward (W) - close slightly
            {
                moveDir[0] = toEnemyNorm[0]; moveDir[1] = toEnemyNorm[1];
            }
            case 4: // back (S) - open slightly
            {
                moveDir[0] = -toEnemyNorm[0]; moveDir[1] = -toEnemyNorm[1];
            }
        }

        // Wall safety: if the chosen direction is blocked, try the opposite side
        float mvLen = SquareRoot(moveDir[0]*moveDir[0] + moveDir[1]*moveDir[1]);
        if (mvLen > 0.001)
        {
            int mvDir = VecToDirIndex(moveDir);
            int oppDir = (mvDir + 4) % 8;
            if (EdgeBlocked_[client][mvDir])
            {
                if (!EdgeBlocked_[client][oppDir])
                {
                    moveDir[0] = -moveDir[0]; moveDir[1] = -moveDir[1];
                }
                else
                {
                    moveDir[0] = 0.0; moveDir[1] = 0.0;
                }
            }
        }

        // Sync StrafeSideSign for the edge-comfort and wall-aware code below
        StrafeSideSign[client] = (WasdDirection[client] == 1) ? 1 :
                                 (WasdDirection[client] == 2) ? -1 : 0;
        StrafeSideUntil[client] = WasdTapUntil[client];

        // CQC_MODE_HOLD overrides: stand and deflect, no lateral movement
        if (CfgCqcMode[botType] == CQC_MODE_HOLD)
        {
            moveDir[0] = 0.0; moveDir[1] = 0.0;
        }
        // CQC_MODE_MIRROR overrides: match enemy lateral movement instead of random taps
        else if (CfgCqcMode[botType] == CQC_MODE_MIRROR)
        {
            float enemyVel[3];
            GetEntPropVector(enemy, Prop_Data, "m_vecVelocity", enemyVel);
            enemyVel[2] = 0.0;
            float axis[3];
            axis[0] = perp[0]; axis[1] = perp[1]; axis[2] = 0.0;
            float axisLen = SquareRoot(axis[0]*axis[0] + axis[1]*axis[1]);
            if (axisLen > 0.001) { axis[0] /= axisLen; axis[1] /= axisLen; }
            float lateral = enemyVel[0]*axis[0] + enemyVel[1]*axis[1];
            if (FloatAbs(lateral) < CQC_MIRROR_DEADZONE)
            {
                moveDir[0] = 0.0; moveDir[1] = 0.0;
            }
            else
            {
                float sign = (lateral > 0.0) ? 1.0 : -1.0;
                moveDir[0] = axis[0] * sign;
                moveDir[1] = axis[1] * sign;
            }
        }
        // CQC_MODE_ARC: the WASD micro-movement already produces bounded
        // lateral drift (short taps, not continuous circling), so arc
        // mode no longer needs its own bearing anchor. The randomness of
        // the tap pattern naturally keeps the bot from wrapping behind.

    }


    // === PROPORTIONAL STANDOFF SPEED ===
    //
    // The branches above choose a DIRECTION. This chooses how hard to commit
    // to it, and it is the difference between a bot and a machine.
    //
    // What this replaces: every branch ran at a fixed 200 or 300, so the
    // controller was bang-bang. Cross cqc_max by a single unit and the bot
    // flipped from circling to a full sprint in one tick; cross back and it
    // flipped again. Those cliffs are what makes the movement read as
    // twitchy - it is not an animation artefact, it is the controller
    // changing mode discontinuously at a threshold.
    //
    // Instead, treat the enemy as carrying a standoff RING that the bot wants
    // to be standing on, and correct the error smoothly:
    //
    //      error   = distToEnemy - standoff       (signed)
    //      speed   = (|error| - deadband) * gain  (clamped to max)
    //
    // Consequences that fall straight out, all of which were asked for:
    //  * the enemy drifting a little produces a gentle readjustment, not a
    //    sprint - the bot keeps doing what it was doing and eases back in;
    //  * the enemy leaving fast produces a real approach, scaled to the gap;
    //  * sitting near the ring produces NO correction at all (deadband), so
    //    the bot stops fidgeting over a few units;
    //  * there is no boundary to oscillate across, because there is no
    //    boundary - just an error that goes to zero.
    //
    // The frame is the ENEMY's ring, not a band the bot tests around itself.
    // Same distance either way, but this way the bot has a place to be rather
    // than a threshold to trip, which is why re-entry is gradual.
    float standoff = (cqcMin + cqcMax) * 0.5;
    float ringErr  = distToEnemy - standoff;
    float deadband = (cqcMax - cqcMin) * CQC_DEADBAND_FRAC;
    float absErr   = (ringErr < 0.0) ? -ringErr : ringErr;

    if (!RetreatingFromFloor[client])
    {
        float radial = (absErr > deadband) ? ((absErr - deadband) * CfgApproachGain[botType]) : 0.0;
        if (radial > speed) radial = speed;   // never exceed the class's own max

        // Lateral (circling/mirroring) keeps its own pace, but fades out
        // while the bot is genuinely out of position - you do not strafe
        // sideways while closing a 2,000-unit gap.
        bool inBand = (absErr <= deadband * 2.0);
        if (StrEqual(LastMoveReason[client], "sweet_spot"))
        {
            speed = inBand ? speed : (speed * 0.5);
        }
        else
        {
            speed = radial;
        }
    }
    // retreat_floor deliberately keeps full speed: that branch exists for
    // getting out of someone's face, and easing off it would defeat it.

    // === EDGE-COMFORT OVERRIDE ===
    // Bias away from the mapped boundary BEFORE the reactive wall-aware
    // step below, not instead of it - this is what makes bots generally
    // stay off the rim during normal play instead of only ever catching
    // themselves on the single step that would put them over the edge.
    // Takes priority over CQC positioning: a real player backs off a ledge
    // before worrying about optimal spacing on an enemy. No-op wherever
    // the cache isn't ready (falls straight through to normal CQC
    // movement, same as before this existed).
    int edgeDist;
    LastEdgeDistKnown[client] = NavCache_GetEdgeDist(botPos, edgeDist);
    LastEdgeDist[client] = edgeDist;
    // (cleared once per tick in ProcessBotTick - only ever set true here)
    if (LastEdgeDistKnown[client] && edgeDist < NAV_EDGE_COMFORT_CELLS)
    {
        float retreatDir[3];
        if (NavCache_RetreatDirection(botPos, retreatDir))
        {
            moveDir[0] = retreatDir[0];
            moveDir[1] = retreatDir[1];
            LastEdgeOverride[client] = true;
        }
    }

    // === WALL-AWARE ADJUSTMENT ===
    float moveAng[3];
    GetVectorAngles(moveDir, moveAng);
    int desiredDir = WorldYawToDirIndex(moveAng[1]);

    int actualDir;
    if (!FindUnblockedDirCommitted(client, desiredDir, distToEnemy, actualDir))
    {
        // All 8 sampled directions read as blocked. Freezing here used to be
        // the fallback, but the engine already handles an actual WALL on its
        // own - movement toward a real obstacle gets stopped/slid along at
        // the collision boundary, same as any player misjudging a corner. A
        // hard freeze only makes sense if walking really would clip through
        // something, which SourceMod movement output can't do anyway.
        //
        // BUT: "blocked" also covers void edges (see MaybeScanWalls), and an
        // edge is not a wall - nothing stops the bot there, it just falls.
        // Only push through if there's a confirmed non-edge direction to
        // push into; if literally every direction is a drop, standing still
        // is the correct call, not a bug to route around.
        int safeDir;
        if (FindNonEdgeDir(client, desiredDir, safeDir))
        {
            if (safeDir != desiredDir)
            {
                DirIndexToWorldVector(safeDir, moveDir);
            }
            vel[0] = moveDir[0] * speed;
            vel[1] = moveDir[1] * speed;
        }
        else
        {
            vel[0] = 0.0; vel[1] = 0.0;
        }
    }
    else if (actualDir != desiredDir)
    {
        // Use the unblocked direction instead
        DirIndexToWorldVector(actualDir, moveDir);

        vel[0] = moveDir[0] * speed;
        vel[1] = moveDir[1] * speed;
    }
    else
    {
        // Desired direction is clear
        vel[0] = moveDir[0] * speed;
        vel[1] = moveDir[1] * speed;
    }

    // === FACING ===
    float aimAng[3];
    CalcAimAngles(botEye, enemyPos, aimAng);
    SmoothAim(client, aimAng, CfgAimEnemy[botType]);
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    return Plugin_Changed;
}

Action State_Guard(int client, int &buttons, float vel[3], float angles[3])
{
    float botPos[3], botEye[3];
    GetClientAbsOrigin(client, botPos);
    GetClientEyePosition(client, botEye);

    float toPost[3];
    SubtractVectors(BotGuardPos[client], botPos, toPost);
    toPost[2] = 0.0;
    float dist = SquareRoot(toPost[0] * toPost[0] + toPost[1] * toPost[1]);

    if (dist <= GUARD_ARRIVE_DIST)
    {
        // Close enough - UpdateBotState will drop us back to IDLE next tick
        // (ReturningToGuard already cleared there). Stand down now instead
        // of waiting a tick to avoid one frame of pointless residual motion.
        vel[0] = 0.0; vel[1] = 0.0;
        return State_Idle(client, vel, angles);
    }

    float moveDir[3];
    moveDir[0] = toPost[0]; moveDir[1] = toPost[1]; moveDir[2] = 0.0;
    NormalizeVector(moveDir, moveDir);

    float moveAng[3];
    GetVectorAngles(moveDir, moveAng);
    int desiredDir = WorldYawToDirIndex(moveAng[1]);

    float speed = 300.0;
    int actualDir;
    if (!FindUnblockedDir(client, desiredDir, actualDir))
    {
        // All 8 sampled directions read blocked. Only push through a
        // confirmed non-edge direction - a wall bumps to a stop, a void
        // edge does not. Better to sit one tick off-post than march a
        // pushed statue straight off a ledge trying to get back to it.
        int safeDir;
        if (FindNonEdgeDir(client, desiredDir, safeDir))
        {
            if (safeDir != desiredDir)
            {
                DirIndexToWorldVector(safeDir, moveDir);
            }
            vel[0] = moveDir[0] * speed;
            vel[1] = moveDir[1] * speed;
        }
        else
        {
            vel[0] = 0.0; vel[1] = 0.0;
        }
    }
    else if (actualDir != desiredDir)
    {
        DirIndexToWorldVector(actualDir, moveDir);

        vel[0] = moveDir[0] * speed;
        vel[1] = moveDir[1] * speed;
    }
    else
    {
        vel[0] = moveDir[0] * speed;
        vel[1] = moveDir[1] * speed;
    }

    // Face the post while marching back to it, not the travel direction -
    // reads as "returning to my spot" rather than "wandering."
    float aimPoint[3];
    aimPoint[0] = BotGuardPos[client][0];
    aimPoint[1] = BotGuardPos[client][1];
    aimPoint[2] = botEye[2];
    float aimAng[3];
    CalcAimAngles(botEye, aimPoint, aimAng);
    SmoothAim(client, aimAng, CfgAimEnemy[GetEffectiveBotType(client)]);
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    return Plugin_Changed;
}

Action State_Idle(int client, float vel[3], float angles[3])
{
    // Stand still. vel[] enters this function holding whatever the bot's own
    // native TF2 AI most recently wanted to do that tick (see the force-apply
    // in ProcessBotTick) - it is NOT already zero, despite the old comment
    // here claiming so. Zero it explicitly or "idle" silently inherits
    // leftover native-AI movement intent.
    vel[0] = 0.0;
    vel[1] = 0.0;

    int enemy = GetFrameEnemy(client);
    if (enemy > 0)
    {
        float botEye[3], enemyPos[3];
        GetClientEyePosition(client, botEye);
        GetClientAbsOrigin(enemy, enemyPos);
        float aimAng[3];
        CalcAimAngles(botEye, enemyPos, aimAng);
        SmoothAim(client, aimAng, CfgAimEnemy[GetEffectiveBotType(client)]);
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];
    }

    return Plugin_Changed;
}

void UpdateGangerCount(int client)
{
    float now = GetEngineTime();
    if (now < NextGangUpdate[client]) return;
    NextGangUpdate[client] = now + 0.2;

    int botType = GetEffectiveBotType(client);
    float gangRange = CfgGangEscapeRange[botType];
    if (gangRange <= 0.0) { GangerCount_[client] = 0; return; }

    int botTeam = GetClientTeam(client);
    float botPos[3];
    GetClientAbsOrigin(client, botPos);

    int count = 0;
    for (int enemy = 1; enemy <= MaxClients; enemy++)
    {
        if (enemy == client) continue;
        if (!IsClientInGame(enemy) || !IsPlayerAlive(enemy)) continue;
        if (GetClientTeam(enemy) == botTeam) continue;

        float enemyPos[3];
        GetClientAbsOrigin(enemy, enemyPos);
        if (GetVectorDistance(botPos, enemyPos) < gangRange)
            count++;
    }
    GangerCount_[client] = count;
}


// ============================================================================
// ENHANCED STATE HANDLERS
// ============================================================================

// Punish: enemy missed airblast → close distance rapidly + deflect
Action State_Punish(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    int enemy = GetFrameEnemy(client);
    if (enemy <= 0 || !IsPlayerAlive(enemy))
    {
        EnemyMissWindow[client] = 0.0;
        return State_Move(client, buttons, vel, angles);
    }

    float now = GetGameTime();
    if (now >= EnemyMissWindow[client])
    {
        // Punish window expired - back to normal
        EnemyMissWindow[client] = 0.0;
        return State_Move(client, buttons, vel, angles);
    }

    // Check if a rocket is incoming - if so, deflect it aggressively
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt >= 0)
    {
        float rocketPos[3], botPos[3];
        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rocketPos);
        GetClientAbsOrigin(client, botPos);
        float dist = GetVectorDistance(botPos, rocketPos);

        if (dist <= CfgDeflectRange[botType] && CanDeflect(client))
        {
            // Deflect the rocket at the vulnerable enemy
            return State_Deflect(client, buttons, vel, angles);
        }

        // Move toward the enemy while rocket closes
        float enemyPos[3];
        GetClientAbsOrigin(enemy, enemyPos);
        float toEnemy[3];
        toEnemy[0] = enemyPos[0] - botPos[0];
        toEnemy[1] = enemyPos[1] - botPos[1];
        toEnemy[2] = 0.0;
        NormalizeVector(toEnemy, toEnemy);

        // Sprint toward the enemy - they can't deflect right now
        vel[0] = toEnemy[0] * 300.0;
        vel[1] = toEnemy[1] * 300.0;

        // Face the enemy
        float botEye[3], aimAng[3];
        GetClientEyePosition(client, botEye);
        CalcAimAngles(botEye, enemyPos, aimAng);
        SmoothAim(client, aimAng, CfgAimEnemy[botType]);
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];

        PvB_Log("[PVB-PUNISH] bot=%d closing on enemy %d (miss window %.2fs left)",
            client, enemy, EnemyMissWindow[client] - now);
        return Plugin_Changed;
    }

    // No rocket - just close distance
    float botPos[3], enemyPos[3];
    GetClientAbsOrigin(client, botPos);
    GetClientAbsOrigin(enemy, enemyPos);
    float toEnemy[3];
    toEnemy[0] = enemyPos[0] - botPos[0];
    toEnemy[1] = enemyPos[1] - botPos[1];
    toEnemy[2] = 0.0;
    NormalizeVector(toEnemy, toEnemy);
    vel[0] = toEnemy[0] * 300.0;
    vel[1] = toEnemy[1] * 300.0;

    float botEye[3], aimAng[3];
    GetClientEyePosition(client, botEye);
    CalcAimAngles(botEye, enemyPos, aimAng);
    SmoothAim(client, aimAng, CfgAimEnemy[botType]);
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    return Plugin_Changed;
}

// Reposition: post-deflect, move to intercept the return rocket
Action State_Reposition(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float now = GetEngineTime();

    if (now >= PostDeflectRepositionUntil[client])
    {
        // Reposition window expired - back to normal movement
        return State_Move(client, buttons, vel, angles);
    }

    // Check if a new rocket is incoming - if so, handle it
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt >= 0)
    {
        float botPos[3], rPos[3];
        GetClientAbsOrigin(client, botPos);
        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
        float dist = GetVectorDistance(botPos, rPos);
        if (dist <= CfgDeflectRange[botType] && CanDeflect(client))
        {
            // A genuinely urgent rocket is back - handle it. Do not hand a
            // far engagement-range rocket to DEFLECT and freeze positioning.
            return State_Deflect(client, buttons, vel, angles);
        }
    }

    // During reposition: move to a spot that gives good angle for the return
    // Simple version: move toward the center of the arena (away from edges)
    float botPos[3];
    GetClientAbsOrigin(client, botPos);

    int edgeDist;
    if (NavCache_GetEdgeDist(botPos, edgeDist) && edgeDist < NAV_EDGE_COMFORT_CELLS)
    {
        // Near edge - retreat toward center
        float retreat[3];
        if (NavCache_RetreatDirection(botPos, retreat))
        {
            vel[0] = retreat[0] * 200.0;
            vel[1] = retreat[1] * 200.0;
        }
    }
    else
    {
        // In good position - hold still and face the enemy
        vel[0] = 0.0;
        vel[1] = 0.0;
    }

    // Face the enemy
    int enemy = GetFrameEnemy(client);
    if (enemy > 0)
    {
        float botEye[3], enemyPos[3], aimAng[3];
        GetClientEyePosition(client, botEye);
        GetClientAbsOrigin(enemy, enemyPos);
        CalcAimAngles(botEye, enemyPos, aimAng);
        SmoothAim(client, aimAng, CfgAimEnemy[botType]);
        angles[0] = aimAng[0];
        angles[1] = aimAng[1];
    }

    return Plugin_Changed;
}

// Feint: quick strafe then snap back and deflect
Action State_Feint(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float now = GetEngineTime();

    if (now >= FeintUntil[client])
    {
        // Feint done - actually deflect now
        return State_Deflect(client, buttons, vel, angles);
    }

    // During feint: quick strafe perpendicular to the rocket
    int rocketEnt = EntRefToEntIndex(FeintRocketRef[client]);
    if (rocketEnt < 0)
    {
        FeintUntil[client] = 0.0;
        FeintRocketRef[client] = -1;
        FeintRollConsumed[client] = false;
        return State_Move(client, buttons, vel, angles);
    }

    float botPos[3], rPos[3];
    GetClientAbsOrigin(client, botPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);

    float toRocket[3];
    toRocket[0] = rPos[0] - botPos[0];
    toRocket[1] = rPos[1] - botPos[1];
    toRocket[2] = 0.0;

    // Perpendicular strafe (quick dodge one way)
    float perp[3];
    perp[0] = -toRocket[1];
    perp[1] = toRocket[0];
    perp[2] = 0.0;
    float len = SquareRoot(perp[0]*perp[0] + perp[1]*perp[1]);
    if (len > 0.001) { perp[0] /= len; perp[1] /= len; }
    else { perp[0] = 1.0; perp[1] = 0.0; }

    int firstDir = VecToDirIndex(perp);
    float opposite[3];
    opposite[0] = -perp[0];
    opposite[1] = -perp[1];
    opposite[2] = 0.0;
    int secondDir = VecToDirIndex(opposite);
    bool firstSafe = !WallBlocked_[client][firstDir]
        && DirectionIsWalkable(botPos, perp, NEXT_STEP_CHECK_DIST, botPos[2]);
    bool secondSafe = !WallBlocked_[client][secondDir]
        && DirectionIsWalkable(botPos, opposite, NEXT_STEP_CHECK_DIST, botPos[2]);

    if (firstSafe)
    {
        vel[0] = perp[0] * 250.0;
        vel[1] = perp[1] * 250.0;
    }
    else if (secondSafe)
    {
        vel[0] = opposite[0] * 250.0;
        vel[1] = opposite[1] * 250.0;
    }
    else
    {
        vel[0] = 0.0;
        vel[1] = 0.0;
    }

    // Face the rocket (tracking it during the feint)
    float botEye[3], aimAng[3];
    GetClientEyePosition(client, botEye);
    CalcAimAngles(botEye, rPos, aimAng);
    SmoothAim(client, aimAng, AimFactorForRocket(botType, GetVectorDistance(botPos, rPos)));
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    return Plugin_Changed;
}

// Steal: intercept a rocket targeting a teammate
Action State_Steal(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt < 0)
    {
        return State_Move(client, buttons, vel, angles);
    }

    float botPos[3], rPos[3];
    GetClientAbsOrigin(client, botPos);
    GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
    float dist = GetVectorDistance(botPos, rPos);

    // If close enough to deflect - do it
    if (dist <= CfgDeflectRange[botType] && CanDeflect(client))
    {
        PvB_Log("[PVB-STEAL] bot=%d stealing rocket from teammate", client);
        return State_Deflect(client, buttons, vel, angles);
    }

    // Move toward the rocket's predicted path
    float toRocket[3];
    toRocket[0] = rPos[0] - botPos[0];
    toRocket[1] = rPos[1] - botPos[1];
    toRocket[2] = 0.0;
    NormalizeVector(toRocket, toRocket);

    vel[0] = toRocket[0] * 300.0;
    vel[1] = toRocket[1] * 300.0;

    // Face the rocket
    float botEye[3], aimAng[3];
    GetClientEyePosition(client, botEye);
    CalcAimAngles(botEye, rPos, aimAng);
    SmoothAim(client, aimAng, AimFactorForRocket(botType, dist));
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    return Plugin_Changed;
}

// Edge pressure: position to herd enemy toward map edge
Action State_EdgePressure(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    int enemy = GetFrameEnemy(client);
    if (enemy <= 0 || !IsPlayerAlive(enemy))
    {
        return State_Move(client, buttons, vel, angles);
    }

    float botPos[3], enemyPos[3];
    GetClientAbsOrigin(client, botPos);
    GetClientAbsOrigin(enemy, enemyPos);

    // Check if enemy is still near edge
    int eDist;
    if (!NavCache_GetEdgeDist(enemyPos, eDist) || eDist >= NAV_EDGE_COMFORT_CELLS)
    {
        // Enemy moved away from edge - back to normal
        return State_Move(client, buttons, vel, angles);
    }

    // Check if a rocket is incoming - survival first
    int rocketEnt = GetCachedRocketForClient(client);
    if (rocketEnt >= 0)
    {
        float rPos[3];
        GetEntPropVector(rocketEnt, Prop_Data, "m_vecOrigin", rPos);
        float dist = GetVectorDistance(botPos, rPos);
        if (dist <= CfgRocketEngageDist[botType])
        {
            return State_Deflect(client, buttons, vel, angles);
        }
    }

    // Position on the opposite side of the enemy from the nearest edge
    // This cuts off their escape route away from the edge
    float retreatDir[3];
    if (NavCache_RetreatDirection(enemyPos, retreatDir))
    {
        // retreatDir points AWAY from edge (toward center)
        // Bot should position on the side of the enemy that's AWAY from center
        // = on the enemy's edge side, blocking their escape
        float blockPos[3];
        blockPos[0] = enemyPos[0] - retreatDir[0] * 150.0;
        blockPos[1] = enemyPos[1] - retreatDir[1] * 150.0;
        blockPos[2] = enemyPos[2];

        float toBlock[3];
        toBlock[0] = blockPos[0] - botPos[0];
        toBlock[1] = blockPos[1] - botPos[1];
        toBlock[2] = 0.0;
        float len = SquareRoot(toBlock[0]*toBlock[0] + toBlock[1]*toBlock[1]);
        if (len > 10.0)
        {
            toBlock[0] /= len;
            toBlock[1] /= len;
            vel[0] = toBlock[0] * 250.0;
            vel[1] = toBlock[1] * 250.0;
        }
        else
        {
            vel[0] = 0.0;
            vel[1] = 0.0;
        }
    }
    else
    {
        return State_Move(client, buttons, vel, angles);
    }

    // Face the enemy
    float botEye[3], aimAng[3];
    GetClientEyePosition(client, botEye);
    CalcAimAngles(botEye, enemyPos, aimAng);
    SmoothAim(client, aimAng, CfgAimEnemy[botType]);
    angles[0] = aimAng[0];
    angles[1] = aimAng[1];

    return Plugin_Changed;
}


// ============================================================================
// STATE_PANIC - multi-rocket + airblast cooldown → pure survival
// Triggered when: multiple rockets are inbound AND airblast is on cooldown
// The bot runs to the safest direction, jumps, does anything to survive.
// ============================================================================

Action State_Panic(int client, int &buttons, float vel[3], float angles[3])
{
    #pragma unused angles
    float gameTime = GetGameTime();

    // Panic expires - return to normal state selection
    if (gameTime >= PanicUntil[client])
    {
        PanicUntil[client] = 0.0;
        PanicRollConsumed[client] = false;
        return Plugin_Continue;
    }

    // Pure survival: run perpendicular to the nearest rocket's direction
    int rocket = GetCachedRocketForClient(client);
    if (rocket > 0 && IsValidEntity(rocket))
    {
        float rPos[3], rVel[3], botPos[3];
        GetEntPropVector(rocket, Prop_Data, "m_vecOrigin", rPos);
        GetEntPropVector(rocket, Prop_Data, "m_vecAbsVelocity", rVel);
        GetClientAbsOrigin(client, botPos);

        // Perpendicular to rocket's incoming direction
        float toBot[3];
        SubtractVectors(botPos, rPos, toBot);
        toBot[2] = 0.0;

        float perp[3];
        perp[0] = -toBot[1];
        perp[1] = toBot[0];
        perp[2] = 0.0;

        float perpLen = GetVectorLength(perp);
        if (perpLen > 0.1)
        {
            ScaleVector(perp, 400.0 / perpLen);
            vel[0] = perp[0];
            vel[1] = perp[1];
        }

        // Jump if the rocket is LOW (near feet) - jump OVER it to survive.
        // Do NOT jump when the rocket is at head/body height - that's jumping INTO it.
        if (rPos[2] < botPos[2] + 40.0)
            buttons |= IN_JUMP;
    }
    else
    {
        // No rocket tracked - run toward center (safest open space)
        float botPos[3];
        GetClientAbsOrigin(client, botPos);
        float centerDir[3];
        centerDir[0] = -botPos[0];
        centerDir[1] = -botPos[1];
        centerDir[2] = 0.0;
        float len = GetVectorLength(centerDir);
        if (len > 0.1)
        {
            ScaleVector(centerDir, 400.0 / len);
            vel[0] = centerDir[0];
            vel[1] = centerDir[1];
        }
    }

    // Don't aim at anything - just survive

    return Plugin_Changed;
}

// ============================================================================
// STATE_CHASE - pursue a fleeing enemy aggressively
// Triggered when: enemy is moving away AND bot has deflect available
// The bot collapses distance faster than STATE_MOVE would.
// ============================================================================

Action State_Chase(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float gameTime = GetGameTime();

    // Chase expires - return to normal state
    if (gameTime >= ChaseUntil[client])
    {
        ChaseUntil[client] = 0.0;
        ChaseRollConsumed[client] = false;
        return Plugin_Continue;
    }

    int enemy = GetFrameEnemy(client);
    if (enemy <= 0 || !IsPlayerAlive(enemy))
    {
        ChaseUntil[client] = 0.0;
        return Plugin_Continue;
    }

    float botPos[3], enemyPos[3];
    GetClientAbsOrigin(client, botPos);
    GetClientAbsOrigin(enemy, enemyPos);

    float toEnemy[3];
    SubtractVectors(enemyPos, botPos, toEnemy);
    toEnemy[2] = 0.0;
    float dist = GetVectorLength(toEnemy);

    if (dist < 0.1)
        return Plugin_Continue;

    // Chase faster than normal move - 500 HU/s toward enemy
    ScaleVector(toEnemy, 500.0 / dist);
    vel[0] = toEnemy[0];
    vel[1] = toEnemy[1];

    // Aim at the enemy
    float chaseBotEye[3], chaseEnemyPos[3], chaseAimAng[3];
    GetClientEyePosition(client, chaseBotEye);
    GetClientAbsOrigin(enemy, chaseEnemyPos);
    CalcAimAngles(chaseBotEye, chaseEnemyPos, chaseAimAng);
    SmoothAim(client, chaseAimAng, CfgAimEnemy[botType]);

    // If we've closed to deflect range, break chase and deflect
    if (dist <= CfgDeflectRange[botType])
    {
        ChaseUntil[client] = 0.0;
        BotState_[client] = STATE_DEFLECT;
        return State_Deflect(client, buttons, vel, angles);
    }


    return Plugin_Changed;
}

// ============================================================================
// STATE_COUNTER - pre-aim where enemy's deflected rocket will come from
// Triggered when: enemy just deflected AND bot rolls counter chance
// The bot pre-aims at the predicted incoming direction for an instant deflect.
// ============================================================================

Action State_Counter(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float gameTime = GetGameTime();

    // Counter pre-aim expires
    if (gameTime >= CounterPreAimUntil[client])
    {
        CounterPreAimUntil[client] = 0.0;
        return Plugin_Continue;
    }

    // Hold the pre-aim angle - don't move, just aim
    vel[0] = 0.0;
    vel[1] = 0.0;

    float aimAng[3];
    aimAng[0] = CounterPreAimPitch[client];
    aimAng[1] = CounterPreAimYaw[client];
    aimAng[2] = 0.0;

    // Smooth toward the pre-aim angle
    float curAng[3];
    GetClientEyeAngles(client, curAng);

    float lerp = CfgAimRocketNear[botType];
    float diff0 = aimAng[0] - curAng[0];
    if (diff0 > 180.0) diff0 -= 360.0;
    if (diff0 < -180.0) diff0 += 360.0;
    curAng[0] += diff0 * lerp;
    float diff1 = aimAng[1] - curAng[1];
    if (diff1 > 180.0) diff1 -= 360.0;
    if (diff1 < -180.0) diff1 += 360.0;
    curAng[1] += diff1 * lerp;

    TeleportEntity(client, NULL_VECTOR, curAng, NULL_VECTOR);

    // If a rocket is now in range, deflect immediately
    int rocket = GetCachedRocketForClient(client);
    if (rocket > 0 && IsValidEntity(rocket))
    {
        float rPos[3], botPos[3];
        GetEntPropVector(rocket, Prop_Data, "m_vecOrigin", rPos);
        GetClientAbsOrigin(client, botPos);
        float dist = GetVectorDistance(rPos, botPos);

        if (dist <= CfgDeflectRange[botType])
        {
            CounterPreAimUntil[client] = 0.0;
            BotState_[client] = STATE_DEFLECT;
            return State_Deflect(client, buttons, vel, angles);
        }
    }


    return Plugin_Changed;
}

// ============================================================================
// STATE_BAIT - bait enemy airblast early, then punish
// Triggered when: rocket is inbound AND bot is in deflect range AND
// bot rolls bait chance. Bot sidesteps at the last moment to make the
// enemy airblast too early, then deflects the still-incoming rocket.
// ============================================================================

Action State_Bait(int client, int &buttons, float vel[3], float angles[3])
{
    int botType = GetEffectiveBotType(client);
    float gameTime = GetGameTime();

    // Bait expires - return to deflect
    if (gameTime >= BaitUntil[client])
    {
        BaitUntil[client] = 0.0;
        BaitRollConsumed[client] = false;
        BotState_[client] = STATE_DEFLECT;
        return State_Deflect(client, buttons, vel, angles);
    }

    int rocket = GetCachedRocketForClient(client);
    if (rocket <= 0 || !IsValidEntity(rocket))
    {
        BaitUntil[client] = 0.0;
        return Plugin_Continue;
    }

    float rPos[3], rVel[3], botPos[3];
    GetEntPropVector(rocket, Prop_Data, "m_vecOrigin", rPos);
    GetEntPropVector(rocket, Prop_Data, "m_vecAbsVelocity", rVel);
    GetClientAbsOrigin(client, botPos);

    float dist = GetVectorDistance(rPos, botPos);

    // Sidestep perpendicular to the rocket's direction
    float toBot[3];
    SubtractVectors(botPos, rPos, toBot);
    toBot[2] = 0.0;

    float perp[3];
    perp[0] = -toBot[1] * BaitSidestepDir[client];
    perp[1] = toBot[0] * BaitSidestepDir[client];
    perp[2] = 0.0;

    float perpLen = GetVectorLength(perp);
    if (perpLen > 0.1)
    {
        // Small sidestep - just enough to look like we're committing
        ScaleVector(perp, 250.0 / perpLen);
        vel[0] = perp[0];
        vel[1] = perp[1];
    }

    // Aim at the enemy (make them think we're about to deflect)
    int baitEnemy = GetFrameEnemy(client);
    if (baitEnemy > 0 && IsPlayerAlive(baitEnemy))
    {
        float baitBotEye[3], baitEnemyPos[3], baitAimAng[3];
        GetClientEyePosition(client, baitBotEye);
        GetClientAbsOrigin(baitEnemy, baitEnemyPos);
        CalcAimAngles(baitBotEye, baitEnemyPos, baitAimAng);
        SmoothAim(client, baitAimAng, CfgAimEnemy[botType]);
    }

    // If rocket is very close, stop baiting and deflect for real
    if (dist <= CfgDeflectRange[botType] * 0.7)
    {
        BaitUntil[client] = 0.0;
        BotState_[client] = STATE_DEFLECT;
        return State_Deflect(client, buttons, vel, angles);
    }


    return Plugin_Changed;
}
