// tfdb_pvb_nav.inc — auto-extracted from tfdb_pvb.sp
// Do not edit directly; this is a split of the PvB plugin.

stock int NavGridIndex(int ix, int iy) {
    int gx = ix + NAV_GRID_HALF;
    int gy = iy + NAV_GRID_HALF;
    if (gx < 0 || gx >= NAV_GRID_SIZE || gy < 0 || gy >= NAV_GRID_SIZE)
        return -1;
    return gx * NAV_GRID_SIZE + gy;
}

void NavCache_TryGrow()
{

    delete g_NavFrontier;
    g_NavFrontier = new ArrayList(3);
    g_NavFrontierRead = 0;
    g_NavCellsDone = 0;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float floorZ;
        if (!NavCache_ProbeFloorZ(pos, floorZ)) continue;

        int ix = RoundToNearest(pos[0] / NAV_CELL_SIZE);
        int iy = RoundToNearest(pos[1] / NAV_CELL_SIZE);
        if (NavCache_CellKnown(ix, iy)) continue;  // already mapped -- nothing new here
        NavCache_AddCell(ix, iy, floorZ);
    }

    if (g_NavFrontier.Length == 0) {
        delete g_NavFrontier;
        g_NavFrontier = null;
        return;  // everyone's currently standing on already-known ground
    }

    g_NavGrowthMode = true;
    g_NavScanActive = true;
    g_NavScanTimer = CreateTimer(NAV_SCAN_INTERVAL, Timer_NavScanStep, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

bool DirectionIsWalkable_LiveTrace(const float basePos[3], const float dir2D[3], float totalDist, float refGroundZ)
{
    float prevZ = refGroundZ;
    float traveled = 0.0;

    while (traveled < totalDist)
    {
        traveled += EDGE_CHECK_STEP;
        if (traveled > totalDist) traveled = totalDist;

        float start[3];
        start[0] = basePos[0] + dir2D[0] * traveled;
        start[1] = basePos[1] + dir2D[1] * traveled;
        // REVERTED to the low lift, and to an UNFILTERED ray, on 2026-08-10
        // after both changes were measured and both broke the bot outright.
        // Recording the measurements so neither gets retried blind:
        //
        //  * start[2] = prevZ + NAV_MAX_STEP_UP-clearing lift (24), to catch the z=81 lip
        //    that step-up puts bots on: froze every bot. A start embedded in
        //    solid hits at fraction 0, so the probe returned its own start
        //    height as "floor"; prevZ re-anchored to that and ratcheted 24
        //    per hop until nothing was in range. walls=VVVVVVVV, speed=0,
        //    faildist=32 on all 20,762 samples.
        //
        //  * TraceFilter_WorldOnly, to keep rockets/players out of the probe:
        //    froze it differently and worse -- seed count went to 0 and every
        //    scan attempt bailed (17/17), faildist=8 on the first hop. The
        //    floor here is NOT world geometry (entity 0); it is a brush
        //    entity, consistent with the walkway being player_clip. Filtering
        //    to entity==0 deletes the very surface the bot stands on.
        //
        // The step-up blindness described in those attempts is REAL and still
        // unfixed -- this probe cannot see a surface above its own start, and
        // that is how bots reach z=81 and fall. But it must be solved without
        // moving this start height and without excluding brush entities.
        start[2] = prevZ + WALL_CHECK_LIFT;
        float end[3];
        end[0] = start[0];
        end[1] = start[1];
        end[2] = start[2] - EDGE_CHECK_FALL_DIST;

        // NoPlayers filter, data -1 -- see NavCache_ProbeFloorZ for why this
        // is neither unfiltered (hits players) nor WorldOnly (misses the
        // brush-entity floor these maps are built from).
        TR_TraceRayFilter(start, end, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_PlayerSolid, -1);
        if (!TR_DidHit()) return false;

        float hitPos[3];
        TR_GetEndPosition(hitPos);

        // Drop-only, not symmetric: a symmetric rise+drop check was tried
        // and reverted -- on a player_clip walkway (a rough physical
        // stand-in, not exact geometry) it caught ordinary floor
        // unevenness as constantly as it caught real cliffs.
        float drop = prevZ - hitPos[2];
        if (drop > EDGE_CHECK_MAX_DROP) return false;  // steeper than the tolerated slope this hop

        prevZ = hitPos[2];
    }
    return true;
}

void NavCache_ComputeEdgeDistances()
{
    // Clear edge distance array
    for (int i = 0; i < NAV_GRID_CELLS; i++) g_NavEdgeDist[i] = -1;

    static const int dx[8] = {1,1,0,-1,-1,-1,0,1};
    static const int dy[8] = {0,1,1,1,0,-1,-1,-1};

    ArrayList queue = new ArrayList(3);
    int readIdx = 0;

    // Find boundary cells (known cells with at least one unknown neighbor)
    int totalCells = 0;
    for (int idx = 0; idx < NAV_GRID_CELLS; idx++) {
        if (!g_NavCellKnown[idx]) continue;
        totalCells++;
        int ix = (idx / NAV_GRID_SIZE) - NAV_GRID_HALF;
        int iy = (idx % NAV_GRID_SIZE) - NAV_GRID_HALF;

        bool isBoundary = false;
        for (int d = 0; d < 8; d++) {
            if (!NavCache_CellKnown(ix + dx[d], iy + dy[d])) { isBoundary = true; break; }
        }
        if (isBoundary) {
            g_NavEdgeDist[idx] = 0;
            float entry[3];
            entry[0] = float(ix); entry[1] = float(iy); entry[2] = 0.0;
            queue.PushArray(entry);
        }
    }
    int boundaryCount = queue.Length;

    // BFS to compute edge distances
    while (readIdx < queue.Length) {
        float cell[3];
        queue.GetArray(readIdx, cell);
        readIdx++;
        int ix = RoundToFloor(cell[0] + 0.5);
        int iy = RoundToFloor(cell[1] + 0.5);
        int dist = RoundToFloor(cell[2] + 0.5);

        for (int d = 0; d < 8; d++) {
            int nx = ix + dx[d];
            int ny = iy + dy[d];
            if (!NavCache_CellKnown(nx, ny)) continue;

            int nIdx = NavGridIndex(nx, ny);
            if (nIdx < 0 || g_NavEdgeDist[nIdx] >= 0) continue;

            g_NavEdgeDist[nIdx] = dist + 1;
            float nentry[3];
            nentry[0] = float(nx); nentry[1] = float(ny); nentry[2] = float(dist + 1);
            queue.PushArray(nentry);
        }
    }

    PvB_Log("[PVB-NAV] Edge-distance field for %s: %d total cache cells, %d boundary seeds, %d cells got a distance assigned",
        CurrentMap, totalCells, boundaryCount, queue.Length);
    delete queue;
}

bool NavCache_GetEdgeDist(const float pos[3], int &outDist)
{
    int ix = RoundToNearest(pos[0] / NAV_CELL_SIZE);
    int iy = RoundToNearest(pos[1] / NAV_CELL_SIZE);
    int idx = NavGridIndex(ix, iy);
    if (idx < 0 || g_NavEdgeDist[idx] < 0) return false;
    outDist = g_NavEdgeDist[idx];
    return true;
}

bool NavCache_RetreatDirection(const float pos[3], float outDir[3])
{
    int ix = RoundToNearest(pos[0] / NAV_CELL_SIZE);
    int iy = RoundToNearest(pos[1] / NAV_CELL_SIZE);

    static const int dx[8] = {1,1,0,-1,-1,-1,0,1};
    static const int dy[8] = {0,1,1,1,0,-1,-1,-1};

    // Read our own cell's edge distance
    int myIdx = NavGridIndex(ix, iy);
    int myDist = -1;
    if (myIdx >= 0 && g_NavEdgeDist[myIdx] >= 0) myDist = g_NavEdgeDist[myIdx];

    int bestDist = -1;
    int bestDx = 0, bestDy = 0;
    for (int d = 0; d < 8; d++) {
        int nIdx = NavGridIndex(ix + dx[d], iy + dy[d]);
        if (nIdx < 0 || g_NavEdgeDist[nIdx] < 0) continue;
        int dist = g_NavEdgeDist[nIdx];

        // 2-cell lookahead: skip directions where gradient reverses
        int n2Idx = NavGridIndex(ix + dx[d]*2, iy + dy[d]*2);
        if (n2Idx >= 0 && g_NavEdgeDist[n2Idx] >= 0) {
            if (g_NavEdgeDist[n2Idx] < dist) continue;
        }

        if (dist > bestDist) { bestDist = dist; bestDx = dx[d]; bestDy = dy[d]; }
    }

    if (bestDist < 0 || (myDist >= 0 && bestDist <= myDist)) return false;

    outDir[0] = float(bestDx);
    outDir[1] = float(bestDy);
    outDir[2] = 0.0;
    float len = SquareRoot(outDir[0] * outDir[0] + outDir[1] * outDir[1]);
    if (len > 0.001) { outDir[0] /= len; outDir[1] /= len; }
    return true;
}

bool NavCache_ProbeFloorZ(const float pos[3], float &outZ)
{
    // Low lift, deliberately restored 2026-08-10 (raising it froze every bot
    // -- see DirectionIsWalkable_LiveTrace).
    //
    // FILTERED with TraceFilter_NoPlayers, not unfiltered and NOT
    // TraceFilter_WorldOnly. All three were measured:
    //   * unfiltered   -- hits PLAYERS. Confirmed directly by sm_navcell:
    //                     "probe hit z=68.03 ent=1 class=player startsolid=1".
    //                     MASK_PLAYERSOLID_BRUSHONLY does not exclude players
    //                     despite the "BRUSHONLY" in its name; that only
    //                     refers to omitting CONTENTS_MONSTER from the
    //                     contents bits. So a bot standing near a cell during
    //                     the scan got its own hull cached as ground.
    //   * WorldOnly    -- finds nothing at all here (seed count 0, 17/17
    //                     scans bailed). The floor is a brush entity.
    //   * NoPlayers    -- the correct middle: keeps brush-entity floors,
    //                     drops players. A player is never ground.
    // Data must be -1, not 0: the filter's own `entity != data` test would
    // reject the world (entity 0) if 0 were passed as the exclusion.
    float start[3];
    start[0] = pos[0]; start[1] = pos[1]; start[2] = pos[2] + WALL_CHECK_LIFT;
    float end[3];
    end[0] = pos[0]; end[1] = pos[1]; end[2] = pos[2] - EDGE_CHECK_FALL_DIST;

    TR_TraceRayFilter(start, end, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint, TraceFilter_PlayerSolid, -1);
    if (!TR_DidHit()) return false;

    float hitPos[3];
    TR_GetEndPosition(hitPos);
    outZ = hitPos[2];
    return true;
}

bool NavCache_IsWalkable(const float pos[3], float &outFloorZ)
{
    int ix = RoundToNearest(pos[0] / NAV_CELL_SIZE);
    int iy = RoundToNearest(pos[1] / NAV_CELL_SIZE);
    int idx = NavGridIndex(ix, iy);
    if (idx < 0 || !g_NavCellKnown[idx]) return false;
    outFloorZ = g_NavFloorZ[idx];
    return true;
}

void NavCache_AddCell(int ix, int iy, float floorZ)
{
    int idx = NavGridIndex(ix, iy);
    if (idx < 0) return;
    g_NavFloorZ[idx] = floorZ;
    g_NavCellKnown[idx] = true;

    float entry[3];
    entry[0] = float(ix); entry[1] = float(iy); entry[2] = floorZ;
    g_NavFrontier.PushArray(entry);
}

bool NavCache_CellKnown(int ix, int iy)
{
    int idx = NavGridIndex(ix, iy);
    if (idx < 0) return false;
    return g_NavCellKnown[idx];
}

void NavCache_BuildPath(char[] buf, int maxlen)
{
    BuildPath(Path_SM, buf, maxlen, "data/tfdb_pvb_navcache/%s.txt", CurrentMap);
}

void NavCache_Save()
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "data/tfdb_pvb_navcache");
    if (!DirExists(dir)) CreateDirectory(dir, 511);

    char path[PLATFORM_MAX_PATH];
    NavCache_BuildPath(path, sizeof(path));

    File file = OpenFile(path, "w");
    if (file == null) {
        LogError("[PVB-NAV] Could not save walkable-area cache to %s", path);
        return;
    }

    // Iterate flat array — write known cells in "ix:iy floorZ" format
    for (int idx = 0; idx < NAV_GRID_CELLS; idx++) {
        if (!g_NavCellKnown[idx]) continue;
        int ix = (idx / NAV_GRID_SIZE) - NAV_GRID_HALF;
        int iy = (idx % NAV_GRID_SIZE) - NAV_GRID_HALF;
        file.WriteLine("%d:%d %.2f", ix, iy, g_NavFloorZ[idx]);
    }
    delete file;
}

bool NavCache_Load()
{
    char path[PLATFORM_MAX_PATH];
    NavCache_BuildPath(path, sizeof(path));
    if (!FileExists(path)) return false;

    File file = OpenFile(path, "r");
    if (file == null) return false;

    // Clear arrays first
    NavCache_Reset();

    char line[64];
    int count = 0;
    while (file.ReadLine(line, sizeof(line))) {
        TrimString(line);
        if (line[0] == '\0') continue;

        char parts[2][32];
        if (ExplodeString(line, " ", parts, 2, 32) != 2) continue;

        // Parse "ix:iy floorZ" format from the cache file
        char coords[2][16];
        if (ExplodeString(parts[0], ":", coords, 2, 16) != 2) continue;
        int ix = StringToInt(coords[0]);
        int iy = StringToInt(coords[1]);
        float floorZ = StringToFloat(parts[1]);

        int idx = NavGridIndex(ix, iy);
        if (idx >= 0) {
            g_NavFloorZ[idx] = floorZ;
            g_NavCellKnown[idx] = true;
            count++;
        }
    }
    delete file;

    if (count == 0) return false;

    PvB_Log("[PVB-NAV] Loaded cached walkable-area map for %s: %d cells", CurrentMap, count);
    return true;
}

void NavCache_Reset()
{
    delete g_NavScanTimer;
    g_NavScanTimer = null;
    // Clear flat arrays (set all cells to unknown)
    for (int i = 0; i < NAV_GRID_CELLS; i++) {
        g_NavFloorZ[i] = -9999.0;
        g_NavEdgeDist[i] = -1;
        g_NavCellKnown[i] = false;
    }
    delete g_NavFrontier;
    g_NavFrontier = null;
    g_NavFrontierRead = 0;
    g_NavCellsDone = 0;
    g_NavScanActive = false;
    g_NavScanReady = false;
    g_NavGrowthMode = false;
}

void StartNavScanIfNeeded()
{
    if (g_NavScanActive || g_NavScanReady) return;
    if (!CfgEnabled) return;

    g_NavScanAttempts++;

    if (NavCache_Load()) {
        g_NavScanReady = true;
        NavCache_ComputeEdgeDistances();
        // DO NOT audit here. StartNavScanIfNeeded is reached from OnMapStart,
        // and NavCache_AuditExtremes fires TR_TraceRay -- tracing that early,
        // before the world/physics environment is fully up, segfaults the
        // server (exit 139 on map load, 2026-08-10; SourcePawn itself is
        // VM-safe, so a native crash means an engine call ran at a moment it
        // could not be made). Cache loading is exactly the path that hits
        // OnMapStart, which is why this was the one place it could not go.
        // Use sm_navaudit for a loaded cache instead -- admin-triggered, so
        // by definition the map is live.
        return;
    }

    // Flat arrays are already allocated as globals — just clear them
    NavCache_Reset();
    g_NavFrontier = new ArrayList(3);
    g_NavFrontierRead = 0;
    g_NavCellsDone = 0;
    g_NavRejectWall = 0;
    g_NavRejectNoFloor = 0;
    g_NavRejectSlope = 0;
    g_NavRejectFootprint = 0;

    int seedCount = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float floorZ;
        if (!NavCache_ProbeFloorZ(pos, floorZ)) continue;

        int ix = RoundToNearest(pos[0] / NAV_CELL_SIZE);
        int iy = RoundToNearest(pos[1] / NAV_CELL_SIZE);
        if (NavCache_CellKnown(ix, iy)) continue;
        NavCache_AddCell(ix, iy, floorZ);
        if (seedCount == 0) {
            g_NavSeedX = pos[0]; g_NavSeedY = pos[1]; g_NavSeedZ = floorZ;
        }
        seedCount++;
    }
    g_NavSeedCount = seedCount;

    if (g_NavFrontier.Length == 0) {
        // Nobody currently in-game had valid footing to seed from -- bail
        // quietly, a later spawn will retry.
        g_NavScanBails++;
        NavCache_Reset();
        return;
    }

    g_NavScanActive = true;
    PvB_Log("[PVB-NAV] Starting walkable-area scan for %s", CurrentMap);
    g_NavScanTimer = CreateTimer(NAV_SCAN_INTERVAL, Timer_NavScanStep, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

bool NavCache_FootprintClear(const float centerPos[3], float centerZ)
{
    static const float offX[4] = {20.0, -20.0, 0.0, 0.0};
    static const float offY[4] = {0.0, 0.0, 20.0, -20.0};

    for (int i = 0; i < 4; i++) {
        float probePos[3];
        probePos[0] = centerPos[0] + offX[i];
        probePos[1] = centerPos[1] + offY[i];
        probePos[2] = centerZ;

        float probeZ;
        if (!NavCache_ProbeFloorZ(probePos, probeZ)) return false;       // this corner overhangs nothing
        if (FloatAbs(probeZ - centerZ) > NAV_CELL_MAX_DELTA) return false; // this corner is a real step/edge, not flat continuation
    }
    return true;
}

bool IncrementalWallClear(const float basePos[3], float baseZ, const float dir2D[3], float totalDist, float lift, bool &outNoFloor, float &outFailDist, int excludeClient = 0)
{
    outNoFloor = false;
    outFailDist = -1.0;
    float mins[3] = {HULL_MINS_X, HULL_MINS_Y, HULL_MINS_Z};
    float maxs[3] = {HULL_MAXS_X, HULL_MAXS_Y, NAV_SWEEP_HEIGHT};

    float prevPos[3];
    prevPos[0] = basePos[0]; prevPos[1] = basePos[1];
    float prevZ = baseZ;
    float traveled = 0.0;

    while (traveled < totalDist)
    {
        traveled += EDGE_CHECK_STEP;
        if (traveled > totalDist) traveled = totalDist;

        float curPos[3];
        curPos[0] = basePos[0] + dir2D[0] * traveled;
        curPos[1] = basePos[1] + dir2D[1] * traveled;

        float sweepStart[3], sweepEnd[3];
        sweepStart[0] = prevPos[0]; sweepStart[1] = prevPos[1]; sweepStart[2] = prevZ + lift;
        sweepEnd[0] = curPos[0]; sweepEnd[1] = curPos[1]; sweepEnd[2] = prevZ + lift;
        // MASK_PLAYERSOLID_BRUSHONLY, not MASK_SOLID_BRUSHONLY. The only
        // difference between them is CONTENTS_PLAYERCLIP (0x10000), and on
        // a player_clip-built map that one bit is the entire map:
        //
        //   MASK_SOLID_BRUSHONLY       = SOLID|MOVEABLE|WINDOW|GRATE
        //   MASK_PLAYERSOLID_BRUSHONLY = SOLID|MOVEABLE|WINDOW|GRATE|PLAYERCLIP
        //
        // Measured on abyss_v4 across two full sessions, 11,702 wall-scan
        // samples: the letter 'W' never appeared once. Not rare -- zero.
        // Every WallBlocked_ bit that was ever set came from the offEdge
        // term instead. The bot could not see a single wall on this map,
        // which is why open= reads 8 essentially always, FindUnblockedDir
        // never had real data to prefer a direction with, EvadeStrafePickSide
        // always fell through to its coin flip, and "hugs walls when it
        // doesn't need to" was inevitable -- there were no walls in its
        // world model at all.
        //
        // The earlier switch away from PLAYERSOLID was made to fix 40/40
        // neighbour rejections, read at the time as the hull starting
        // embedded in a thick clip volume. That reading may well be right,
        // but excluding player_clip outright treats the symptom by deleting
        // the signal. Handle the embedded case directly instead: if the
        // hull STARTS in solid, the obstruction is where we already are,
        // not something ahead in the sweep direction -- that is never a
        // wall discovery, so don't report one.
        //
        // FILTER (2026-08-10): TraceFilter_PlayerSolid, not
        // TraceFilter_WorldOnly. Swapping the MASK alone changed nothing --
        // still zero 'W' across ~50,000 samples -- because the blocker was
        // never the mask, it was the filter. This map's geometry is brush
        // ENTITIES (the floor is `func_brush`, ent 51, proven via sm_navcell),
        // and `entity == 0` discards every one of them. It blinded the wall
        // sweep in exactly the way it blinded the floor probe, where the same
        // filter produced seed count 0 and 17/17 failed scans.
        //
        // PlayerSolid asks the question that actually matters for a wall --
        // "would a PLAYER be stopped by this" -- so it keeps brush entities
        // and drops players, rockets, and the func_physbox_multiplayer
        // rocket-barriers that stop traces but not people.
        TR_TraceHullFilter(sweepStart, sweepEnd, mins, maxs, MASK_PLAYERSOLID_BRUSHONLY, TraceFilter_PlayerSolid, excludeClient);
        if (TR_DidHit() && !TR_StartSolid()) { outFailDist = traveled; return false; }  // a REAL wall -- outNoFloor stays false

        // Re-anchor height to the ACTUAL local floor before the next
        // segment, so a descending staircase gets followed step by step
        // instead of swept at the original position's height the whole way.
        float floorProbe[3];
        floorProbe[0] = curPos[0]; floorProbe[1] = curPos[1]; floorProbe[2] = prevZ;
        float curZ;
        if (!NavCache_ProbeFloorZ(floorProbe, curZ)) { outNoFloor = true; outFailDist = traveled; return false; }  // an EDGE, not a wall
        if ((prevZ - curZ) > EDGE_CHECK_MAX_DROP) { outNoFloor = true; outFailDist = traveled; return false; }     // same -- too steep a drop to call "floor"

        prevPos[0] = curPos[0]; prevPos[1] = curPos[1];
        prevZ = curZ;
    }
    return true;
}

void NavCache_ExpandCell(int ix, int iy, float z)
{
    static const int dx[8] = {1,1,0,-1,-1,-1,0,1};
    static const int dy[8] = {0,1,1,1,0,-1,-1,-1};

    // Shorter and narrower than the general wall-check hull, and critically
    // MASK_SOLID_BRUSHONLY instead of MASK_PLAYERSOLID_BRUSHONLY (excludes
    // CONTENTS_PLAYERCLIP). Diagnostic data made this unambiguous: 40/40
    // neighbor checks rejected at the wall-sweep, 0 from the floor probe,
    // across 5 different cells -- not "surrounded by real geometry" (that
    // wouldn't be 100% uniform across a spread of cells), a systematic
    // sweep failure. The floor probe is a zero-width RAY and never had this
    // problem; only the swept HULL did. Two candidate causes, both fixed by
    // this: (1) this map's walkway is player_clip (confirmed earlier this
    // session) -- if it's a THICK volume rather than a thin sheet, a hull
    // that starts already inside it registers "stuck in solid" for any
    // sweep direction, same as the classic floor-flush bug but sideways;
    // MASK_SOLID_BRUSHONLY stops caring about player_clip entirely. (2) a
    // 72-unit-tall hull reaching up to floor+76 can clip a modest spawn-room
    // ceiling that a real player's movement wouldn't even notice; a real
    // WALL still spans full room height either way, so shrinking this only
    // risks missing a wall that's short even by that standard, which isn't
    // a real wall in the first place. (Hull mins/maxs now live in
    // IncrementalWallClear, which does the actual sweep.)
    float basePos[3];
    basePos[0] = float(ix) * NAV_CELL_SIZE;
    basePos[1] = float(iy) * NAV_CELL_SIZE;
    basePos[2] = z;

    for (int d = 0; d < 8; d++) {
        int nx = ix + dx[d];
        int ny = iy + dy[d];
        if (NavCache_CellKnown(nx, ny)) continue;

        float neighborPos[3];
        neighborPos[0] = float(nx) * NAV_CELL_SIZE;
        neighborPos[1] = float(ny) * NAV_CELL_SIZE;
        neighborPos[2] = z;

        // Horizontal path check: refuse a neighbor if there's a wall
        // between here and there. Incremental (see
        // IncrementalWallClear), not one sweep at a fixed height
        // for the whole hop -- a level sweep can't cross a real staircase,
        // it slams into the first riser.
        float dx2 = neighborPos[0] - basePos[0];
        float dy2 = neighborPos[1] - basePos[1];
        float hopDist = SquareRoot(dx2 * dx2 + dy2 * dy2);
        float dir2D[3];
        dir2D[0] = dx2 / hopDist; dir2D[1] = dy2 / hopDist; dir2D[2] = 0.0;
        bool scanNoFloor;
        float scanFailDist;
        if (!IncrementalWallClear(basePos, z, dir2D, hopDist, SCANNER_WALL_CHECK_LIFT, scanNoFloor, scanFailDist)) {
            if (scanNoFloor) g_NavRejectNoFloor++; else g_NavRejectWall++;
            continue;
        }

        // Floor check along the WHOLE hop, incrementally -- a single probe
        // at the far end can land past a narrow dip hidden partway through
        // the 48-unit jump (the exact bug fixed for the live per-tick
        // guard earlier; this one-time scan needs the same rigor, it just
        // never got it, which is why bots kept falling at the same spot
        // even with a "complete" cache covering the rest of the map fine).
        if (!DirectionIsWalkable_LiveTrace(basePos, dir2D, hopDist, z)) { g_NavRejectNoFloor++; continue; }

        float neighborZ;
        if (!NavCache_ProbeFloorZ(neighborPos, neighborZ)) { g_NavRejectNoFloor++; continue; }  // void/edge
        if (FloatAbs(neighborZ - z) > NAV_CELL_MAX_DELTA) { g_NavRejectSlope++; continue; }      // too steep
        if (!NavCache_FootprintClear(neighborPos, neighborZ)) { g_NavRejectFootprint++; continue; }  // center's fine, an edge of this tile isn't

        NavCache_AddCell(nx, ny, neighborZ);
    }
}

public Action Timer_NavScanStep(Handle timer)
{
    int processed = 0;
    while (processed < NAV_SCAN_BATCH && g_NavFrontierRead < g_NavFrontier.Length) {
        float cell[3];
        g_NavFrontier.GetArray(g_NavFrontierRead, cell);
        g_NavFrontierRead++;

        NavCache_ExpandCell(RoundToFloor(cell[0]), RoundToFloor(cell[1]), cell[2]);

        processed++;
        g_NavCellsDone++;
        if (g_NavCellsDone >= NAV_MAX_CELLS) {
            g_NavFrontierRead = g_NavFrontier.Length;
            PvB_Log("[PVB-NAV] %s hit the %d-cell safety cap -- scan stopped early", CurrentMap, NAV_MAX_CELLS);
            break;
        }
    }

    if (g_NavFrontierRead >= g_NavFrontier.Length) {
        g_NavScanActive = false;
        delete g_NavFrontier;
        g_NavFrontier = null;
        g_NavFrontierRead = 0;
        g_NavScanTimer = null;

        if (g_NavGrowthMode) {
            // Growth pass: unlike the initial scan, ANY number of newly
            // discovered cells is a legitimate result to keep, never a
            // failure to discard -- the existing 11000+ cell cache (or
            // however large) isn't at risk here, this only ever adds to
            // it. Only bother recomputing/resaving if something actually
            // changed; most growth ticks find nothing new once a map is
            // well covered, and that's an expected, silent no-op.
            g_NavGrowthMode = false;
            if (g_NavCellsDone > 0) {
                NavCache_ComputeEdgeDistances();
                NavCache_Save();
                PvB_Log("[PVB-NAV] %s cache grew by %d cells (now covers more of the map bots have actually visited)",
                    CurrentMap, g_NavCellsDone);
            }
            return Plugin_Stop;
        }

        if (g_NavCellsDone < NAV_MIN_VIABLE_CELLS) {
            // The flood-fill died almost immediately -- most likely the
            // seed spawned in a small boxed-in room where the real exit
            // isn't grid-aligned with one of the 8 sampled directions
            // within range. Treating this as "done" would permanently
            // cache a useless 1-cell result and block every future
            // attempt (g_NavScanReady gates StartNavScanIfNeeded). Leave
            // it NOT ready so the next spawn -- which reseeds from every
            // currently in-game client, including any bot that's since
            // wandered into the open arena via the live-trace fallback --
            // gets another shot instead of being stuck on this forever.
            NavCache_Reset();
            PvB_Log("[PVB-NAV] %s scan died at %d cells (rejected: wall=%d nofloor=%d slope=%d footprint=%d) -- too small to trust, will retry on next spawn",
                CurrentMap, g_NavCellsDone, g_NavRejectWall, g_NavRejectNoFloor, g_NavRejectSlope, g_NavRejectFootprint);
            return Plugin_Stop;
        }

        g_NavScanReady = true;
        NavCache_ComputeEdgeDistances();
        PvB_Log("[PVB-NAV] Walkable-area scan complete for %s: %d cells (rejected: wall=%d nofloor=%d slope=%d footprint=%d)",
            CurrentMap, g_NavCellsDone, g_NavRejectWall, g_NavRejectNoFloor, g_NavRejectSlope, g_NavRejectFootprint);
        NavCache_AuditExtremes();
        NavCache_Save();
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

void NavCache_AuditExtremes()
{

    // Hard refusal to trace on a map that isn't live yet. This function
    // segfaulted the server when it was reachable from OnMapStart (see
    // StartNavScanIfNeeded). Requiring a real client in-game is a cheap,
    // reliable proxy for "the world exists and TR_* is safe to call" -- the
    // diagnostic is worth nothing if running it can take the server down.
    bool anyoneHere = false;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) { anyoneHere = true; break; }
    }
    if (!anyoneHere) return;

    int minIx = 999999, maxIx = -999999, minIy = 999999, maxIy = -999999;
    for (int idx = 0; idx < NAV_GRID_CELLS; idx++) {
        if (!g_NavCellKnown[idx]) continue;
        int ix = (idx / NAV_GRID_SIZE) - NAV_GRID_HALF;
        int iy = (idx % NAV_GRID_SIZE) - NAV_GRID_HALF;
        if (ix < minIx) minIx = ix;
        if (ix > maxIx) maxIx = ix;
        if (iy < minIy) minIy = iy;
        if (iy > maxIy) maxIy = iy;
    }

    PvB_Log("[PVB-NAV-AUDIT] %s extent: ix %d..%d, iy %d..%d (world x %.0f..%.0f, y %.0f..%.0f)",
        CurrentMap, minIx, maxIx, minIy, maxIy,
        float(minIx) * NAV_CELL_SIZE, float(maxIx) * NAV_CELL_SIZE,
        float(minIy) * NAV_CELL_SIZE, float(maxIy) * NAV_CELL_SIZE);

    // Centre plus the four extremes. Same entity at centre and rim is the
    // phantom-plane signature.
    int sampleIx[5], sampleIy[5];
    sampleIx[0] = (minIx + maxIx) / 2; sampleIy[0] = (minIy + maxIy) / 2;
    sampleIx[1] = minIx;               sampleIy[1] = sampleIy[0];
    sampleIx[2] = maxIx;               sampleIy[2] = sampleIy[0];
    sampleIx[3] = sampleIx[0];         sampleIy[3] = minIy;
    sampleIx[4] = sampleIx[0];         sampleIy[4] = maxIy;

    static const char labels[5][] = { "centre", "min-x rim", "max-x rim", "min-y rim", "max-y rim" };

    for (int s = 0; s < 5; s++) {
        float cellPos[3];
        cellPos[0] = float(sampleIx[s]) * NAV_CELL_SIZE;
        cellPos[1] = float(sampleIy[s]) * NAV_CELL_SIZE;

        float cachedZ;
        if (!NavCache_IsWalkable(cellPos, cachedZ)) {
            PvB_Log("[PVB-NAV-AUDIT] %-10s cell %d:%d -- not in cache", labels[s], sampleIx[s], sampleIy[s]);
            continue;
        }
        cellPos[2] = cachedZ;

        float pStart[3], pEnd[3];
        pStart[0] = cellPos[0]; pStart[1] = cellPos[1]; pStart[2] = cachedZ + WALL_CHECK_LIFT;
        pEnd[0]   = cellPos[0]; pEnd[1]   = cellPos[1]; pEnd[2]   = cachedZ - EDGE_CHECK_FALL_DIST;
        TR_TraceRay(pStart, pEnd, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint);

        if (!TR_DidHit()) {
            PvB_Log("[PVB-NAV-AUDIT] %-10s cell %d:%d cachedZ=%.2f -- probe NO HIT (cached a cell with no floor!)",
                labels[s], sampleIx[s], sampleIy[s], cachedZ);
            continue;
        }

        float hit[3];
        TR_GetEndPosition(hit);
        int ent = TR_GetEntityIndex();
        char cls[64];
        if (ent > 0 && IsValidEntity(ent)) GetEntityClassname(ent, cls, sizeof(cls));
        else if (ent == 0) strcopy(cls, sizeof(cls), "worldspawn");
        else strcopy(cls, sizeof(cls), "<none>");

        PvB_Log("[PVB-NAV-AUDIT] %-10s cell %d:%d cachedZ=%.2f probeZ=%.2f ent=%d class=%s",
            labels[s], sampleIx[s], sampleIy[s], cachedZ, hit[2], ent, cls);
    }
}

bool DirectionIsWalkable(const float basePos[3], const float dir2D[3], float totalDist, float refGroundZ)
{
    float target[3];
    target[0] = basePos[0] + dir2D[0] * totalDist;
    target[1] = basePos[1] + dir2D[1] * totalDist;
    target[2] = refGroundZ;

    // ---- The cache is a VETO. It is never, on its own, a PASS. ----
    //
    // A cache HIT used to return true immediately, skipping the live trace
    // entirely. That is what killed a bot at (2001 585) on abyss_v4
    // (2026-08-10 capture): cell 42:12 and every neighbour out to +-2 are
    // cached as solid floor at z=64.03 with edgeDist=10 -- ten cells, ~480
    // units, from any mapped boundary. Deep interior by every cache metric.
    // The bot walked that ground at z=63, stepped up 19 units onto a lip at
    // (2001 585) -- inside the SAME 48-unit cell -- and dropped to -236.
    //
    // The grid samples one floor probe per 48-unit cell. It structurally
    // cannot represent a hole narrower than one cell, so for that spot it
    // was confidently, precisely wrong -- and because a hit short-circuited
    // the trace, nothing else ever looked. walls= read OOOOOOOO, the
    // per-tick step guard passed, and edgeov stayed 0 for all 10,546
    // samples of that session.
    //
    // The control experiment is already on record: the immediately previous
    // session ran the whole time with ready=0 (scan unfinished), so every
    // query fell through to the live trace -- zero falls, and correct
    // single-direction void readings at real edges. Cache on: one death.
    // Cache off: none. The cache was actively degrading safety by
    // suppressing the finer check.
    //
    // So: let the cache refuse fast (a boundary cell is a boundary cell,
    // no trace needed to reject it), but make every "yes" go through the
    // 8-unit-granularity live trace, which samples finely enough to see a
    // sub-cell hole. Cost is bounded -- the per-tick step guard is 3 hops,
    // and the 8-direction scan is throttled to WALL_SCAN_INTERVAL.
    int edgeDist;
    if (NavCache_GetEdgeDist(target, edgeDist) && edgeDist < NAV_HARD_MARGIN_CELLS) return false;

    // Unmapped cells land here too, and that is deliberate: "unknown" must
    // mean "go measure it", never "assume safe" and never "refuse with no
    // recourse" (the latter produced walls=VVVVVVVV paralysis when a bot
    // spawned beside one of the tiny FootprintClear gaps near spawn).
    return DirectionIsWalkable_LiveTrace(basePos, dir2D, totalDist, refGroundZ);
}

void MaybeScanWalls(int client)
{
    float now = GetEngineTime();
    if (now < NextWallScan_[client]) return;

    float pos[3];
    GetClientAbsOrigin(client, pos);

    // Skip if barely moved and throttle not fully expired
    float dist = GetVectorDistance(pos, LastWallPos[client]);
    if (dist < WALL_SKIP_DIST && now < NextWallScan_[client] + WALL_SCAN_INTERVAL) return;

    // 8 WORLD-ABSOLUTE directions (index i = world yaw i*45) -- deliberately
    // NOT built from the bot's eye angles. See WorldYawToDirIndex for why:
    // this array outlives the facing it would have been stamped with, and a
    // rocket-tracking bot's facing is the fastest-changing thing about it.
    float dirs[8][3];
    for (int i = 0; i < 8; i++) {
        DirIndexToWorldVector(i, dirs[i]);
    }

    // A single sweep held at pos's height for the whole WALL_CHECK_DIST
    // (100 units, over twice the scanner's 48-unit hop) has the exact same
    // "can't cross a real staircase" problem NavCache_ExpandCell had --
    // confirmed via diagnostics: even with a fully-built, correct nav
    // cache (edgeDist=18-19, deep interior, nowhere near a real boundary),
    // mobile bots kept reading walls=WWWWWWWW / open=0 in 100% of samples.
    // Now uses IncrementalWallClear (see NavCache_ExpandCell), the same
    // technique that fixed the scanner -- short hops, re-anchored to the
    // locally-probed floor each step, instead of one sweep at a fixed
    // height for the whole distance.
    float tracePos[3];
    tracePos[0] = pos[0]; tracePos[1] = pos[1]; tracePos[2] = pos[2];

    LastCacheHitCount[client] = 0;
    for (int i = 0; i < 8; i++)
    {
        bool wallNoFloor;
        float wallFailDist;
        bool wallClear = IncrementalWallClear(tracePos, tracePos[2], dirs[i], WALL_CHECK_DIST, LIVE_SWEEP_LIFT, wallNoFloor, wallFailDist, client);
        bool hitWall = !wallClear && !wallNoFloor;

        // Diagnostic only, direction 0 (forward) as a representative
        // sample -- see LastWallFailDist/LastWallFailReason.
        if (i == 0) {
            if (wallClear) { LastWallFailDist[client] = -1.0; LastWallFailReason[client] = 0; }
            else if (wallNoFloor) { LastWallFailDist[client] = wallFailDist; LastWallFailReason[client] = 2; }
            else { LastWallFailDist[client] = wallFailDist; LastWallFailReason[client] = 1; }
        }

        // Also check map edges — don't walk off a ledge. Evaluated
        // UNCONDITIONALLY, not gated behind "!hitWall": this flag is what
        // keeps the "all directions blocked -> push through anyway"
        // fallbacks in State_Move/State_Orbit/State_Guard from marching a bot off a
        // real cliff. If it only ran when hitWall was false, any bug or
        // edge case that makes hitWall wrongly true would silently disable
        // the one check that actually matters for not falling off the map.
        //
        // This used to be TR_PointOutsideWorld, which only answers "is this
        // point outside the compiled level's leaf structure entirely" --
        // the out-of-bounds/killzone check. It does NOT detect a gap/chasm
        // that's still fully inside the map's own bounds (skybox still
        // encloses it) with nothing but void below, which is exactly what
        // this abyss-style map is built from and exactly why bots kept
        // walking straight off the edge. The correct check for "is there
        // WALKABLE floor here" is a downward trace checked against TF2's
        // own slope-walkability limit (see TraceFindsWalkableFloor) --
        // "some surface exists below" isn't enough on its own, since a
        // slope steeper than the engine's own walkable limit un-grounds a
        // player exactly like a real edge does (debug logs showed bots
        // sliding straight down one of these while a plain hit-test kept
        // reporting solid ground the whole way).
        // wallNoFloor folded in here, not into hitWall: on a disk/island
        // map surrounded by void, most directions from most positions run
        // out of floor within WALL_CHECK_DIST (100 units) long before
        // hitting any real wall brush -- that's an edge, not a wall, and
        // it's useful extra edge information DirectionIsWalkable's own
        // 80-unit check might miss (an edge sitting between 80-100 units
        // out), not something to discard.
        bool offEdge = !DirectionIsWalkable(pos, dirs[i], 80.0, pos[2]) || wallNoFloor;

        WallBlocked_[client][i] = hitWall || offEdge;
        EdgeBlocked_[client][i] = offEdge;

        // Diagnostic only, mirrors DirectionIsWalkable's own target calc --
        // see LastCacheHitCount.
        float diagTarget[3];
        diagTarget[0] = pos[0] + dirs[i][0] * 80.0;
        diagTarget[1] = pos[1] + dirs[i][1] * 80.0;
        diagTarget[2] = pos[2];
        float diagZ;
        if (NavCache_IsWalkable(diagTarget, diagZ)) LastCacheHitCount[client]++;
    }

    LastWallPos[client] = pos;
    NextWallScan_[client] = now + WALL_SCAN_INTERVAL;
}

int WorldYawToDirIndex(float worldYaw)
{
    float yaw = worldYaw;
    while (yaw < 0.0)     yaw += 360.0;
    while (yaw >= 360.0)  yaw -= 360.0;

    // 8 sectors of 45 degrees, each centred on its index's exact yaw
    // (sector 0 spans -22.5..22.5 around world +X).
    float adjusted = yaw + 22.5;
    if (adjusted >= 360.0) adjusted -= 360.0;
    return RoundToFloor(adjusted / 45.0) % 8;
}

void DirIndexToWorldVector(int dirIdx, float out[3])
{
    if (dirIdx < 0 || dirIdx > 7) dirIdx = 0;

    float ang[3];
    ang[0] = 0.0;
    ang[1] = float(dirIdx) * 45.0;
    ang[2] = 0.0;

    float fwd[3];
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    out[0] = fwd[0];
    out[1] = fwd[1];
    out[2] = 0.0;

    float len = SquareRoot(out[0] * out[0] + out[1] * out[1]);
    if (len > 0.001) { out[0] /= len; out[1] /= len; }
}

bool FindUnblockedDir(int client, int desiredDir, int &outDir)
{
    if (desiredDir < 0 || desiredDir > 7) desiredDir = 0;

    // Try the desired direction first
    if (!WallBlocked_[client][desiredDir]) { outDir = desiredDir; return true; }

    // Try offsets: 1, -1, 2, -2, 3, -3, 4
    for (int offset = 1; offset <= 4; offset++)
    {
        int cw = (desiredDir + offset) % 8;
        if (!WallBlocked_[client][cw]) { outDir = cw; return true; }
        int ccw = (desiredDir - offset + 8) % 8;
        if (!WallBlocked_[client][ccw]) { outDir = ccw; return true; }
    }
    return false;  // all directions blocked
}

bool FindUnblockedDirCommitted(int client, int desiredDir, float distToGoal, int &outDir)
{
    if (desiredDir < 0 || desiredDir > 7) desiredDir = 0;

    if (!WallBlocked_[client][desiredDir])
    {
        WallSlideSign[client] = 0;  // clear path -- no detour, drop any commitment
        outDir = desiredDir;
        return true;
    }

    float now = GetEngineTime();

    if (WallSlideSign[client] != 0 && now >= WallSlideUntil[client])
    {
        // Commitment window elapsed -- did it actually help? 10 units of
        // slack so normal positional noise doesn't read as "no progress."
        if (distToGoal >= WallSlideStartDist[client] - 10.0)
            WallSlideSign[client] = -WallSlideSign[client];  // wasn't working -- try the other way
        else
            WallSlideSign[client] = 0;  // it was working -- let it re-decide fresh next time
    }

    if (WallSlideSign[client] == 0)
    {
        WallSlideSign[client] = 1;  // default direction, same as FindUnblockedDir's CW-first
        WallSlideUntil[client] = now + 2.0;
        WallSlideStartDist[client] = distToGoal;
    }

    for (int offset = 1; offset <= 4; offset++)
    {
        int primary   = (WallSlideSign[client] > 0) ? (desiredDir + offset) % 8 : (desiredDir - offset + 8) % 8;
        int secondary = (WallSlideSign[client] > 0) ? (desiredDir - offset + 8) % 8 : (desiredDir + offset) % 8;

        if (!WallBlocked_[client][primary])   { outDir = primary; return true; }
        if (!WallBlocked_[client][secondary]) { outDir = secondary; return true; }
    }
    return false;
}

bool FindNonEdgeDir(int client, int desiredDir, int &outDir)
{
    if (desiredDir < 0 || desiredDir > 7) desiredDir = 0;

    if (!EdgeBlocked_[client][desiredDir]) { outDir = desiredDir; return true; }

    for (int offset = 1; offset <= 4; offset++)
    {
        int cw = (desiredDir + offset) % 8;
        if (!EdgeBlocked_[client][cw]) { outDir = cw; return true; }
        int ccw = (desiredDir - offset + 8) % 8;
        if (!EdgeBlocked_[client][ccw]) { outDir = ccw; return true; }
    }
    return false;
}

public Action Cmd_NavRebuild(int client, int args) {
    char path[PLATFORM_MAX_PATH];
    NavCache_BuildPath(path, sizeof(path));

    bool existed = FileExists(path);
    if (existed && !DeleteFile(path)) {
        CReplyToCommand(client, "[PvB] Could not delete %s -- check file permissions.", path);
        return Plugin_Handled;
    }

    NavCache_Reset();
    StartNavScanIfNeeded();

    CReplyToCommand(client, "[PvB] %s cache for %s. Rescanning now.",
        existed ? "Deleted" : "No existing", CurrentMap);
    CReplyToCommand(client, "[PvB] Watch sm_navdraw: cells appear as the flood-fill reaches them.");
    CReplyToCommand(client, "[PvB] Result lands in logs/tfdb_pvb/pvb_<date>.log ([PVB-NAV] / [PVB-NAV-AUDIT]).");
    return Plugin_Handled;
}

public Action Cmd_NavAudit(int client, int args) {
    NavCache_AuditExtremes();
    CReplyToCommand(client, "[PvB] Audit written to logs/tfdb_pvb/pvb_<date>.log ([PVB-NAV-AUDIT]).");
    return Plugin_Handled;
}

public Action Cmd_NavDraw(int client, int args) {
    if (client < 1 || !IsClientInGame(client)) {
        ReplyToCommand(client, "[PvB] Run this in-game (draws around your own position).");
        return Plugin_Handled;
    }

    if (args >= 1) {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        int r = StringToInt(arg);
        if (r >= 1 && r <= NAV_DRAW_MAX_RADIUS) NavDrawRadius[client] = r;
    }
    if (NavDrawRadius[client] <= 0) NavDrawRadius[client] = 6;

    NavDrawEnabled[client] = !NavDrawEnabled[client];
    if (!NavDrawEnabled[client]) {
        CReplyToCommand(client, "[PvB] Nav cache overlay disabled.");
        return Plugin_Handled;
    }

    CReplyToCommand(client, "[PvB] Nav cache overlay ENABLED (radius %d cells, %d units). sm_navdraw again to stop.",
        NavDrawRadius[client], RoundToFloor(float(NavDrawRadius[client]) * NAV_CELL_SIZE));
    CReplyToCommand(client, "[PvB] GREEN = cached, real floor confirmed   YELLOW = cached, near the cache's own boundary");
    CReplyToCommand(client, "[PvB] {red}MAGENTA = CACHED BUT NO REAL FLOOR{default} -- phantom cell, this is what makes bots walk into the void");
    CReplyToCommand(client, "[PvB] RED = real floor exists but NOT cached (scan never reached it)");
    return Plugin_Handled;
}

void DrawNavOverlayFor(int client)
{
    if (BeamSprite == -1) return;
    if (!(client >= 1 && client <= MaxClients && IsClientInGame(client))) return;

    float now = GetEngineTime();
    if (now < NextNavDraw[client]) return;
    NextNavDraw[client] = now + NAV_DRAW_INTERVAL;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    int cx = RoundToNearest(pos[0] / NAV_CELL_SIZE);
    int cy = RoundToNearest(pos[1] / NAV_CELL_SIZE);
    int radius = NavDrawRadius[client];

    int only[1];
    only[0] = client;

    for (int dx = -radius; dx <= radius; dx++)
    {
        for (int dy = -radius; dy <= radius; dy++)
        {
            float cellPos[3];
            cellPos[0] = float(cx + dx) * NAV_CELL_SIZE;
            cellPos[1] = float(cy + dy) * NAV_CELL_SIZE;
            cellPos[2] = pos[2];

            float cachedZ;
            bool cached = NavCache_IsWalkable(cellPos, cachedZ);

            // Independent ground truth for this exact cell.
            float probePos[3];
            probePos[0] = cellPos[0];
            probePos[1] = cellPos[1];
            probePos[2] = cached ? cachedZ : pos[2];
            float realZ;
            bool hasFloor = NavCache_ProbeFloorZ(probePos, realZ);

            if (!cached && !hasFloor) continue;  // genuine void, nothing to say

            int color[4];
            float drawZ;

            if (cached && !hasFloor) {
                // The cache asserts ground where a fresh probe finds none.
                color[0] = 255; color[1] = 0; color[2] = 255; color[3] = 255;  // magenta
                drawZ = cachedZ;
            } else if (!cached && hasFloor) {
                color[0] = 255; color[1] = 0; color[2] = 0; color[3] = 255;    // red
                drawZ = realZ;
            } else {
                int ed;
                bool haveEd = NavCache_GetEdgeDist(cellPos, ed);
                if (haveEd && ed < NAV_HARD_MARGIN_CELLS) {
                    color[0] = 255; color[1] = 220; color[2] = 0; color[3] = 255;  // yellow
                } else {
                    color[0] = 0; color[1] = 255; color[2] = 0; color[3] = 255;    // green
                }
                drawZ = realZ;
            }

            float bottom[3], top[3];
            bottom[0] = cellPos[0]; bottom[1] = cellPos[1]; bottom[2] = drawZ + 1.0;
            top[0]    = cellPos[0]; top[1]    = cellPos[1]; top[2]    = drawZ + NAV_DRAW_HEIGHT;

            TE_SetupBeamPoints(bottom, top, BeamSprite, 0, 0, 0, NAV_DRAW_INTERVAL + 0.1, 2.0, 2.0, 0, 0.0, color, 0);
            TE_Send(only, 1);
        }
    }
}

int ParseUserIdArg(const char[] arg)
{
    if (arg[0] != '#') return -1;
    int uid = StringToInt(arg[1]);
    int c = GetClientOfUserId(uid);
    return (c > 0 && IsClientInGame(c)) ? c : -1;
}

public Action Cmd_NavCell(int client, int args) {
    // Server console (client 0) has no position of its own, but it CAN name a
    // target -- and the arg parsing below already supports that. Refusing
    // outright before even looking at the args made the command unusable from
    // the server console / RCON even when a perfectly good target was given.
    if (client == 0 && args < 1) {
        ReplyToCommand(client, "[PvB] From the server console, give a target: sm_navcell <#userid|name>");
        ReplyToCommand(client, "[PvB] (In-game with no argument it centres on your own position.)");
        return Plugin_Handled;
    }
    if (!g_NavScanReady) {
        CReplyToCommand(client, "[PvB] No walkable-area cache for %s yet (not scanned, or still scanning).", CurrentMap);
        return Plugin_Handled;
    }

    int target = client;
    if (args >= 1) {
        char arg[32];
        GetCmdArg(1, arg, sizeof(arg));
        int t = ParseUserIdArg(arg);
        if (t > 0) target = t;
    }
    if (!(target >= 1 && target <= MaxClients && IsClientInGame(target))) {
        ReplyToCommand(client, "[PvB] No valid target to centre on.");
        return Plugin_Handled;
    }

    float pos[3];
    GetClientAbsOrigin(target, pos);
    int cx = RoundToNearest(pos[0] / NAV_CELL_SIZE);
    int cy = RoundToNearest(pos[1] / NAV_CELL_SIZE);

    CReplyToCommand(client, "[PvB] Cache around (%d,%d) [world %.0f,%.0f] -- each cell: Z height / edge-distance, X = not in cache", cx, cy, pos[0], pos[1]);
    for (int dy = 3; dy >= -3; dy--) {
        char row[256];
        row[0] = '\0';
        for (int dx = -3; dx <= 3; dx++) {
            char cellStr[32];
            float cellPos[3];
            cellPos[0] = float(cx + dx) * NAV_CELL_SIZE;
            cellPos[1] = float(cy + dy) * NAV_CELL_SIZE;
            cellPos[2] = pos[2];

            float cz;
            if (!NavCache_IsWalkable(cellPos, cz)) {
                strcopy(cellStr, sizeof(cellStr), (dx == 0 && dy == 0) ? "[ X]" : " X  ");
            } else {
                int ed;
                if (!NavCache_GetEdgeDist(cellPos, ed)) ed = -1;
                if (dx == 0 && dy == 0) FormatEx(cellStr, sizeof(cellStr), "[%d/%d]", RoundToFloor(cz), ed);
                else FormatEx(cellStr, sizeof(cellStr), "%d/%-2d", RoundToFloor(cz), ed);
            }
            Format(row, sizeof(row), "%s%-7s", row, cellStr);
        }
        ReplyToCommand(client, "%s", row);
    }

    // --- What is the floor probe actually hitting here? ---
    // The cache for tfdb_abyss_v4 is 11,019 of 11,022 cells at EXACTLY
    // 64.03, a uniform plane spanning +-2496 -- including well out over the
    // void, where bots have repeatedly fallen to -230 while the cache
    // reported edgeDist 9-10 (deep interior). A scan of real geometry does
    // not look like that; a single flat brush the trace can see does.
    // Filtering the probe to entity==0 made it find nothing anywhere at all,
    // so whatever it is, it is an ENTITY and not world geometry.
    //
    // Rather than keep inferring, ask the trace directly. This reports the
    // entity index and classname under the queried spot, so "what is the bot
    // standing on, and is it the same thing 500 units out over the abyss?"
    // becomes one command instead of another guess.
    // Probe from well clear of the querying player's own hull, and with
    // players filtered out. The first version of this did neither and
    // dutifully reported "ent=1 class=player startsolid=1" -- it was
    // measuring the admin standing on the spot. That was still useful (it
    // proved MASK_PLAYERSOLID_BRUSHONLY does NOT exclude players), but it
    // told us nothing about the ground.
    float probeStart[3], probeEnd[3];
    probeStart[0] = pos[0]; probeStart[1] = pos[1]; probeStart[2] = pos[2] + WALL_CHECK_LIFT;
    probeEnd[0]   = pos[0]; probeEnd[1]   = pos[1]; probeEnd[2]   = pos[2] - EDGE_CHECK_FALL_DIST;

    // Break the mask down bit by bit. A surface that a PLAYER can stand on
    // and a surface that merely stops a TRACE are different things, and the
    // whole phantom-plane problem is that this probe cannot currently tell
    // them apart. Reporting per-contents tells us exactly which brush type
    // the cache has been mapping -- no more inferring it from symptoms.
    int bits[5];
    bits[0] = CONTENTS_SOLID;
    bits[1] = CONTENTS_PLAYERCLIP;
    bits[2] = CONTENTS_GRATE;
    bits[3] = CONTENTS_WINDOW;
    bits[4] = CONTENTS_MOVEABLE;
    static const char bitNames[5][] = { "SOLID", "PLAYERCLIP", "GRATE", "WINDOW", "MOVEABLE" };

    CReplyToCommand(client, "[PvB] --- floor probe at (%.0f %.0f %.0f), players filtered out ---", pos[0], pos[1], pos[2]);

    for (int b = 0; b < 5; b++)
    {
        TR_TraceRayFilter(probeStart, probeEnd, bits[b], RayType_EndPoint, TraceFilter_PlayerSolid, -1);
        if (!TR_DidHit()) {
            CReplyToCommand(client, "[PvB]   %-11s : no hit", bitNames[b]);
            continue;
        }
        float h[3];
        TR_GetEndPosition(h);
        int e = TR_GetEntityIndex();
        char cls[64];
        if (e > 0 && IsValidEntity(e)) GetEntityClassname(e, cls, sizeof(cls));
        else if (e == 0) strcopy(cls, sizeof(cls), "worldspawn");
        else strcopy(cls, sizeof(cls), "<none>");

        // Collision group + solid flags alongside the hit, because "what is
        // it" was never the hard part -- "would a PLAYER actually stop on it"
        // was, and that took a round-trip through the Valve wiki to answer for
        // func_physbox_multiplayer. Print the properties that decide it so the
        // next unknown entity is one command, not another research detour.
        // (accepted= is this filter's verdict, so the answer is never inferred.)
        int cgroup = -1, sflags = 0;
        if (e > 0 && IsValidEntity(e)) {
            if (HasEntProp(e, Prop_Data, "m_CollisionGroup")) cgroup = GetEntProp(e, Prop_Data, "m_CollisionGroup");
            if (HasEntProp(e, Prop_Send, "m_usSolidFlags"))   sflags = GetEntProp(e, Prop_Send, "m_usSolidFlags");
        }
        bool accepted = TraceFilter_PlayerSolid(e, bits[b], -1);

        CReplyToCommand(client, "[PvB]   %-11s : HIT z=%.2f ent=%d class=%s cgroup=%d solidflags=0x%X accepted=%s",
            bitNames[b], h[2], e, cls, cgroup, sflags, accepted ? "YES" : "no (not ground)");
    }

    CReplyToCommand(client, "[PvB] Run this on good ground AND out where the bot falls.");
    CReplyToCommand(client, "[PvB] A bit that hits in BOTH places is the phantom surface the cache is following.");
    return Plugin_Handled;
}

public Action Cmd_BotCfg(int client, int args) {
    int startType = 0, endType = NumBotTypes - 1;

    if (args >= 1) {
        char arg[32];
        GetCmdArg(1, arg, sizeof(arg));
        int t = ParseUserIdArg(arg);
        if (t > 0) {
            startType = GetEffectiveBotType(t);
            endType = startType;
        } else {
            int idx = StringToInt(arg);
            if (idx >= 0 && idx < NumBotTypes) { startType = idx; endType = idx; }
        }
    }

    for (int t = startType; t <= endType; t++) {
        CReplyToCommand(client, "[PvB] type=%d (%s / %s) can_walk=%d statue=%d",
            t, BotClassKey[t], BotDisplayName[t], CfgCanWalk[t] ? 1 : 0, ClassIsStatueLike[t] ? 1 : 0);
        CReplyToCommand(client, "    cqc: min=%.0f max=%.0f floor=%.0f retreat=%.0f",
            CfgCqcMinDist[t], CfgCqcMaxDist[t], CfgCqcFloorDist[t], CfgCqcRetreatDist[t]);
        CReplyToCommand(client, "    idle: chance=%.0f%% duration=%.1fs gang_escape_range=%.0f",
            CfgIdleChance[t], CfgIdleDuration[t], CfgGangEscapeRange[t]);
    }
    return Plugin_Handled;
}

public bool TraceFilter_PlayerSolid(int entity, int contentsMask, any data) {
    if (entity <= 0) return true;            // worldspawn
    if (entity <= MaxClients) return false;  // players/bots are never ground
    if (!IsValidEntity(entity)) return false;

    // --- Classes the engine hard-codes as non-solid to players ---
    //
    // Per the Valve Developer Community: "func_physbox_multiplayer is
    // identical to func_physbox, except NOT SOLID TO PLAYERS BY DEFAULT."
    // That behaviour lives in the C++ class's ShouldCollide() override, NOT
    // in any networked property -- there is no collision group, solid flag
    // or contents bit that reflects it, which is exactly why reading
    // m_CollisionGroup missed it and a rebuilt cache came back byte-identical.
    // SourceMod cannot call ShouldCollide, so the class name is the only
    // available signal.
    //
    // abyss_v4 uses one of these as an out-of-bounds ROCKET barrier: solid to
    // the rocket, invisible to the player's feet. The floor probe hit it at
    // z=-11.19 (ent 136) and cached ground over the abyss; bots then walked
    // out onto it and died.
    //
    // Bias is deliberately toward refusing: a mapper CAN make one of these
    // player-solid, and refusing it then merely makes the bot avoid a
    // standable box. Accepting a non-solid one kills the bot. Those costs are
    // not close.
    char cls[64];
    if (GetEntityClassname(entity, cls, sizeof(cls))) {
        if (StrEqual(cls, "func_physbox_multiplayer", false)) return false;
        // Physics props in general: even where they are player-solid, they
        // MOVE. A persistent nav cache must not record ground whose existence
        // depends on an object staying put.
        if (StrContains(cls, "prop_physics", false) != -1) return false;
    }

    // --- General case: collision groups that pass players through ---
    if (HasEntProp(entity, Prop_Data, "m_CollisionGroup")) {
        switch (GetEntProp(entity, Prop_Data, "m_CollisionGroup")) {
            case COLLISION_GROUP_DEBRIS,
                 COLLISION_GROUP_DEBRIS_TRIGGER,
                 COLLISION_GROUP_INTERACTIVE_DEBRIS,
                 COLLISION_GROUP_WEAPON,
                 COLLISION_GROUP_VEHICLE_CLIP,
                 COLLISION_GROUP_PROJECTILE,
                 COLLISION_GROUP_PASSABLE_DOOR,
                 COLLISION_GROUP_DISSOLVING:
            {
                return false;  // a player passes through this -- not ground
            }
        }
    }

    // --- General case: explicitly non-solid ---
    if (HasEntProp(entity, Prop_Send, "m_usSolidFlags")) {
        if (GetEntProp(entity, Prop_Send, "m_usSolidFlags") & FSOLID_NOT_SOLID) return false;
    }

    return true;
}

