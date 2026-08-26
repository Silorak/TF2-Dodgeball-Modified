#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <multicolors>
#include <tfdb_clientcheck>
#include <tfdb_profiling>

// TFDB support - use TFDB natives to get rocket ownership
// Falls back to non-TFDB mode if TFDB not loaded
#undef REQUIRE_PLUGIN
#tryinclude <tfdb>
#tryinclude <tfdb_guardian>
#tryinclude <tfdb_deathmatch>
#tryinclude <tfdb_ffa>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "2.3.0"

// Bumped by hand on every debug-relevant fix so a pasted-back debug log's
// header line ("=== PVB DEBUG START === ... build=... ===") proves which
// build actually produced it - no more guessing whether a test result
// reflects the latest source or a stale upload.
#define PVB_BUILD_MARKER        "quality-guard-2026-08-15"

// Runtime detection of TFDB plugin (compile-time #if is not enough)
bool TFDBAvailable = false;

// === WALL/EDGE SCAN CONSTANTS ===
// Used by both MaybeScanWalls (periodic 8-direction scan) and ProcessBotTick's
// per-tick step guard, so these must be defined before either - moved here
// from just above MaybeScanWalls, which was too late in the file for the
// per-tick guard's earlier use.
#define WALL_CHECK_DIST    100.0
#define HULL_MINS_X  -16.0
#define HULL_MINS_Y  -16.0
#define HULL_MINS_Z    0.0
#define HULL_MAXS_X   16.0
#define HULL_MAXS_Y   16.0
#define HULL_MAXS_Z   72.0
// Lift the trace start above the floor to avoid the floor-flush
// self-embedding bug: GetClientAbsOrigin returns a floor-level point,
// and a hull sweep starting flush with the floor registers "stuck in
// solid" against the floor brush itself. 4.0 is proven for the nav
// scanner; the live per-tick sweep uses LIVE_SWEEP_LIFT (16.0) because
// raw bot positions need more clearance than pre-validated cell centers.
#define WALL_CHECK_LIFT      4.0
// Proven correct for the scanner (built a real 11000+-cell cache with
// it) - do not change without re-verifying via g_NavReject* diagnostics.
#define SCANNER_WALL_CHECK_LIFT 4.0
// Lift specifically for MaybeScanWalls's live horizontal sweep (via
// IncrementalWallClear), separate from WALL_CHECK_LIFT and
// SCANNER_WALL_CHECK_LIFT - see the correction above. 16.0, matching the
// first attempt's value, but this time isolated with faildist diagnostics
// confirming exactly which problem it's meant to fix before committing to
// it a second time.
#define LIVE_SWEEP_LIFT      16.0
// How far straight down a floor-check point must find ground before it's
// treated as a real edge. Generous enough to clear a normal staircase/ramp
// step without false-flagging it as a cliff, well short of "might still be
// standing on something out of range."
#define EDGE_CHECK_FALL_DIST 64.0
// Hop size for DirectionIsWalkable's incremental path sampling - checking
// only the far endpoint of a long lookahead can sample past a localized
// drop that levels off again further out. 20 units was still coarse enough
// to straddle a narrow curb-then-cliff feature (a small lip climbed on one
// hop, the actual drop just past it never independently sampled). 8 units
// is finer than any legitimate single stair step this project's maps use,
// so a real ramp/staircase still passes hop by hop while a narrow ledge
// can't hide between samples anymore.
#define EDGE_CHECK_STEP 8.0
// Max height change tolerated PER HOP before a direction is flagged
// unwalkable. Used to be the same value as EDGE_CHECK_STEP (the hop
// distance itself) - coupling "how densely to sample" to "how much noise
// to tolerate" meant shrinking the hop size to catch narrow features also
// made the check intolerant of ordinary floor unevenness over that same
// short span. Debug logs showed bots frozen with walls=VVVVVVVV on
// completely flat, known-good spawn ground, nowhere near a real edge -
// every direction was being misread as a cliff. Decoupled: still sample
// every 8 units (catches a narrow lip), but allow a more realistic amount
// of height noise per hop before calling it unwalkable.
#define EDGE_CHECK_MAX_DROP 24.0
// Source's own instantaneous step-up limit (sv_stepsize, default 18). A
// surface no more than this above the current floor is something the engine
// will silently place the bot on top of, with no jump and no arc.
//
// KNOWN UNSOLVED PROBLEM, kept here as the record of it: the downward
// walkability probes start only WALL_CHECK_LIFT (4) above the reference
// floor, so any surface more than 4 units up is above the ray's own origin
// and invisible to them - while step-up will still put a bot on it. That is
// how two abyss_v4 bots reached z=81 on a map whose entire 11,022-cell nav
// cache contains nothing above z=68.53, and then fell.
//
// Raising the probe start to clear this limit was tried and REVERTED: it
// froze every bot (see DirectionIsWalkable_LiveTrace for the measurements).
// A fix has to detect the lip WITHOUT moving the floor probe's start height.
#define NAV_MAX_STEP_UP 18.0
// How completely opposing enemy pressure has to cancel before the bot calls
// itself flanked. |sum of pushes| / sum of |pushes|: 1.0 = all one side,
// 0.0 = perfectly opposed. 0.35 is "meaningfully surrounded" rather than
// "slightly off-axis". Unitless by construction, so unlike the absolute
// epsilon it replaces it cannot silently mean a distance.
#define BREAK_FLANK_CANCEL_RATIO 0.35
// Minimum unblocked directions before a bot will commit to circling. Circling
// needs room; doing it in a corridor just grinds the bot along geometry.
#define ORBIT_MIN_OPEN_DIRS 4
// Pyro airblast cooldown. Was written as a bare 0.75 in three places, which
// is also the value the orbit trigger has to agree with - if orbit thinks
// the blast is ready and State_Deflect doesn't, the bot flips between them.
#define AIRBLAST_COOLDOWN 0.75
// The compression blast's real box. A press outside either of these cannot
// connect at any angle, but still burns the full cooldown - see
// AirblastWouldConnect.
#define AIRBLAST_REACH      256.0
#define AIRBLAST_FIRE_RANGE 240.0
#define AIRBLAST_CONE_DOT   0.643   // cos(50deg); the cone is ~60, this leaves margin
// Per-tick step guard's lookahead (see ProcessBotTick's force-apply block):
// how far along this tick's decided velocity direction to check for floor
// before committing to the step, independent of the periodic scan's cadence.
#define NEXT_STEP_CHECK_DIST 24.0
// How far below its own spawn height a bot has to fall before the
// safety-net kill in ProcessBotTick fires (see there). Comfortably past
// normal ramp/step variance (observed up to ~70 units on abyss_v4's
// walkway), well short of "might still be on the intended play area."
#define FALL_KILL_DEPTH 300.0

// === BEHAVIOR TREE STATES ===
enum BotState {
    STATE_IDLE = 0,
    STATE_GANG_ESCAPE,
    STATE_DEFLECT,
    STATE_DODGE,
    STATE_ORBIT,
    STATE_MOVE,
    STATE_GUARD,
    STATE_PUNISH,          // enemy missed airblast → close distance + deflect
    STATE_REPOSITION,       // post-deflect: pre-position for return rocket
    STATE_FEINT,            // fake strafe then deflect
    STATE_STEAL,            // intercept rocket targeting teammate
    STATE_EDGE_PRESSURE,    // herd enemy toward map edge
    STATE_PANIC,            // multi-rocket + cooldown → pure survival
    STATE_CHASE,            // pursue a fleeing enemy aggressively
    STATE_COUNTER,          // pre-aim enemy's deflected rocket for instant deflect
    STATE_BAIT,             // bait enemy airblast early, then punish
    STATE_COUNT
}

// --- Bot Types (fully dynamic - loaded from config) ---
// Every class (built-in or user-defined) is discovered by iterating the
// "classes" section of pvb.cfg at load time. No hardcoded identities.
// Class index 0 is always the "default" fallback if the config has no classes.
#define MAX_BOT_TYPES 32     // Maximum supported classes
int NumBotTypes = 0;      // Populated by LoadPvBConfig from .cfg

// Legacy indices retained ONLY for movement-mode default weighting; they
// match the built-in class order in the stock config and are safe fallbacks.
#define BOT_TYPE_UNIVERSAL   0
#define BOT_TYPE_STATUE      1
#define BOT_TYPE_MIDRANGE    2
#define BOT_TYPE_AGGRESSIVE  3

// Per-class identity (loaded from .cfg)
char BotClassKey[MAX_BOT_TYPES][32];       // Lowercase key as written in cfg (e.g. "statue")
char BotDisplayName[MAX_BOT_TYPES][64];    // Human-readable (e.g. "Statue (Rally/Deflect)")
bool ClassIsStatueLike[MAX_BOT_TYPES];     // Per-class: force-idle behavior (was the STATUE-only hardcode)

// --- Evasion Actions ---
enum EvadeAction {
    EVADE_NONE = 0,
    EVADE_JUMP,        // grounded/low rocket close to feet - hop it, then deflect on the way down
    EVADE_CROUCH,
    EVADE_REPOSITION,  // rocket behind/off to the side - jump + turn to reacquire it
    // Not really "evasion" in the dodge-out-of-the-way sense - more a
    // recovery/delay move: airblast is on cooldown, a rocket is already
    // close and lined up, and there's nothing to do but buy time. Strafes
    // laterally away from the rocket's line while aim stays locked onto
    // it (SmoothAim already runs independently in this branch), same
    // shape as a real player backing off and holding a mouse-drag toward
    // the threat rather than standing still waiting for the cooldown.
    EVADE_STRAFE
}

#define NUM_EVADE 4

// --- Orbit Phases (for multi-rotation WASD orbit) ---
enum OrbitPhase {
    ORBIT_PHASE_NONE = 0,
    ORBIT_PHASE_RIGHT,    // Strafe right (D)
    ORBIT_PHASE_BACK,     // Move back (S)
    ORBIT_PHASE_LEFT,     // Strafe left (A)
    ORBIT_PHASE_FORWARD   // Move forward (W)
}

#define NUM_ORBIT_PHASES 4

// --- Movement Modes ---

// --- Look States (after deflection) ---

// --- Global server-wide config (loaded from pvb.cfg "settings") ---
bool CfgEnabled = true;          // Master enable
int CfgBotType = 0;              // Active class index in normal mode
int CfgMinPlayers = 1;           // Auto-enable when players <= this
int CfgMaxPlayers = 2;           // Auto-disable when players > this (e.g. max_players 2 = bot allowed up to 2 humans, kicked at 3+)
bool CfgSpeech = true;           // Master taunt toggle
bool CfgClassSpeech[MAX_BOT_TYPES];

// --- Per-class config arrays (loaded from pvb.cfg "classes") ---
// Every bot in debug-states mode indexes these by its own type, so classes
// don't stomp each other's tunings.
// react_min / react_max removed - airblast fires at fixed 240 HU (airblast range)
float CfgMaxOrbitTime[MAX_BOT_TYPES];
int   CfgMaxOrbitLoops[MAX_BOT_TYPES];
// angle_random_chance / angle_random_strength removed - unused in BT code
float CfgEvadeChance[MAX_BOT_TYPES];
float CfgCqcFloorDist[MAX_BOT_TYPES];   // Hard floor - no class can EVER go closer
float CfgCqcMinDist[MAX_BOT_TYPES];
float CfgCqcMaxDist[MAX_BOT_TYPES];
float CfgCqcRetreatDist[MAX_BOT_TYPES];
float CfgIdleChance[MAX_BOT_TYPES];
float CfgIdleDuration[MAX_BOT_TYPES];
float CfgLookAtPlayerTime[MAX_BOT_TYPES];

// --- Capability-by-presence flags -------------------------------------------
// Each CfgCan* flag is TRUE iff the corresponding config key(s) were present in
// the class section of pvb.cfg. Remove the keys from the class block and the
// bot becomes physically incapable of that action - not just "chance 0", but
// gated out of the code path entirely. Defaults to TRUE so classes with
// complete configs behave exactly as before.
//
//   CfgCanOrbit[t]   - orbit_time / orbit_max_loops / orbit_chance present
//   CfgCanEvade[t]   - evade_chance present
//   CfgCanCqc[t]     - any cqc_*_dist key present
//   CfgCanIdle[t]    - idle_chance present (gates both look-idle and move-idle)
//   CfgIdleAlways[t] - idle_chance >= 100 (permanent idle, no duration roll)
bool CfgCanOrbit[MAX_BOT_TYPES];
bool CfgCanEvade[MAX_BOT_TYPES];
bool CfgCanCqc[MAX_BOT_TYPES];
bool CfgCanIdle[MAX_BOT_TYPES];
bool CfgIdleAlways[MAX_BOT_TYPES];

// === BT CONFIG (per-class, loaded from pvb.cfg) ===
bool  CfgCanWalk[MAX_BOT_TYPES];
// --- Enhanced features ---
float CfgTimingVariance[MAX_BOT_TYPES];     // +/- random offset on deflect timing
int   CfgOrbitBreakChance[MAX_BOT_TYPES];    // % chance to break orbit early
int   CfgPunishChance[MAX_BOT_TYPES];        // % chance to punish enemy missed airblast
int   CfgRepositionChance[MAX_BOT_TYPES];     // confirmed-deflect reposition chance
float CfgRepositionTime[MAX_BOT_TYPES];       // bounded reposition episode
int   CfgFeintChance[MAX_BOT_TYPES];        // % chance to feint before deflect
int   CfgStealChance[MAX_BOT_TYPES];        // % chance to steal teammate's rocket
int   CfgEdgePressureChance[MAX_BOT_TYPES]; // % chance to herd enemy toward edge
int   CfgPanicChance[MAX_BOT_TYPES];         // % chance to panic under multi-rocket + cooldown
int   CfgChaseChance[MAX_BOT_TYPES];         // % chance to chase a fleeing enemy
int   CfgCounterChance[MAX_BOT_TYPES];       // % chance to pre-aim enemy deflect for instant counter
int   CfgBaitChance[MAX_BOT_TYPES];          // % chance to bait enemy airblast early
bool  CfgEvadeStrafeEnabled[MAX_BOT_TYPES];  // per-class toggle for EVADE_STRAFE; forced off for statue-like classes regardless of this value
int   CfgMaxDeflectCount[MAX_BOT_TYPES];
float CfgMaxDeflectSpeed[MAX_BOT_TYPES];
int   CfgMoveWeight[7][MAX_BOT_TYPES];  // 7 moves: normal, wave, upspike, downspike, bounce, direct, backfire
float CfgOrbitSpeedThreshold[MAX_BOT_TYPES];
int   CfgOrbitChance[MAX_BOT_TYPES];       // % chance to orbit a rocket when the blast IS available
float CfgMinOrbitTime[MAX_BOT_TYPES];      // lower bound of a committed orbit episode
float CfgRocketEngageDist[MAX_BOT_TYPES];  // beyond this a tracked rocket does not drive state at all
float CfgDeflectRange[MAX_BOT_TYPES];      // within this the bot commits to DEFLECT/DODGE
int   CfgJumpOverChance[MAX_BOT_TYPES];
float CfgGangEscapeRange[MAX_BOT_TYPES];
float CfgGangSpeedBoostMult[MAX_BOT_TYPES];
int   CfgCqcMode[MAX_BOT_TYPES];    // CQC_MODE_ARC / _MIRROR / _HOLD
// Post-deflect spike pitches. Near-vertical by default: a real spike is a
// hard flick that arcs the rocket high (or slams it into the floor), which is
// what makes it hard for the target to track.
// Commit point for the airblast, expressed as time-to-impact rather than a
// distance - see State_Deflect. fire_min_dist stops a very slow rocket being
// let all the way onto the bot's face before it commits.
float CfgFireTimeToImpact[MAX_BOT_TYPES];
float CfgFireMinDist[MAX_BOT_TYPES];
float CfgSpikeUpPitch[MAX_BOT_TYPES];
float CfgSpikeDownPitch[MAX_BOT_TYPES];
// Aim speed. Enemy tracking is deliberately the slowest thing the bot does -
// there is no urgency in facing someone. Rocket tracking scales with range;
// see AimFactorForRocket.
float CfgAimEnemy[MAX_BOT_TYPES];
float CfgAimRocketNear[MAX_BOT_TYPES];
float CfgAimRocketFar[MAX_BOT_TYPES];
float CfgAimRocketNearDist[MAX_BOT_TYPES];
float CfgAimRocketFarDist[MAX_BOT_TYPES];
float CfgCqcMaxArc[MAX_BOT_TYPES];  // degrees of lateral drift allowed in ARC mode
// Speed per unit of standoff error. 2.5 means a 120-unit gap asks for 300
// HU/s; smaller gaps ask for proportionally less, which is what makes the bot
// ease back into position instead of sprinting at every threshold crossing.
float CfgApproachGain[MAX_BOT_TYPES];

// --- Speech file paths per bot type ---
char SpeechPlayerDeath[MAX_BOT_TYPES][PLATFORM_MAX_PATH];
char SpeechBotDeath[MAX_BOT_TYPES][PLATFORM_MAX_PATH];

// --- Runtime State ---
bool BotEnabled = false;         // Is the bot system currently active?
bool CommandForced = false;   // Was it force-enabled by admin?
bool CommandDisabled = false; // Was it force-disabled by admin?
bool MapChanged = false;

// Cached player counts (updated on connect/disconnect/team change, not every frame)
int CachedRealCount = 0;
int CachedFakeCount = 0;
bool BotNameDirty = false;    // Only set bot name when changed

// Bot Stats
int BotWins = 0;              // Rounds bot's team won
int BotLosses = 0;            // Rounds bot's team lost
int TotalDeflects = 0;        // Total deflects achieved
int TotalKills = 0;           // Kills by bot
int TotalDeaths = 0;          // Times bot died
int RoundDeflects = 0;        // Deflects THIS round (for stat display)
float RoundStartTime = 0.0;   // GetGameTime() at last teamplay_round_start - see ManageTeams' spawn-wave-miss grace window
// (Disable-vote globals removed 2026-04-24 - unified into class vote menu.)
int VoteMaxPlayers = 12;      // Max players allowed to vote (loaded from config)

// Class vote system - players vote for which bot type to play against.
// Array is sized MAX_BOT_TYPES+1: slots 0..NumBotTypes-1 = bot types,
// slot NumBotTypes = "Disable bot" votes.
int ClassVotes[MAX_BOT_TYPES + 1];
int ClassVoted[MAXPLAYERS + 1]; // Which slot this player voted for (-1 = not voted; NumBotTypes = disable)
bool ClassVoteActive = false; // Is a class vote in progress
bool PendingMaxPlayerDisable = false; // OnGameFrame queued a "too many players" disable; drained at round end so bot finishes the current rally
int  PendingHotSwapType = -1;          // Vote winner queued for next-round hot-swap; -1 = no swap pending
bool SoloMenuShown = false;   // Was the solo player menu shown
Handle ClassVoteTimer = null;
float MapStartTime = 0.0;     // GetEngineTime() at last OnMapStart - see Timer_CheckPlayerJoin

// Right after a map change, real players reconnect on a stagger of many
// seconds (map download/load + class select), not all at once. A short
// solo-check delay made the FIRST player to finish loading look like the
// only human in the server and handed him a one-click direct bot-enable
// menu (ShowClassPickMenu) before everyone else had even connected -
// bypassing !votepvb entirely for people who were, in fact, on their way in.
// Give stragglers a real window right after map start; a genuine lone
// late-joiner well into a map (no one else around, no one about to load in)
// still only waits the normal short delay.
#define SOLO_CONFIRM_DELAY_NORMAL   3.0
#define SOLO_CONFIRM_DELAY_MAPSTART 15.0
#define SOLO_MAPSTART_WINDOW        20.0

// Debug-states mode
bool DebugStatesMode = false;    // Are we in debug-states mode (bots on both teams)?
int DebugStatesBotCount = 0;     // Number of debug-states bots spawned

// --- League-style self-play diversity ---------------------------------------
// Tracks per-type win rate so we can detect when one bot class dominates the
// meta. When a type crosses a threshold, we convert one of its bots to an
// under-represented type ("exploiter") at the next round boundary. This
// forces the dominant type to face fresh counter-play instead of stagnating
// against a monoculture it has already solved.
// League diversity tracking removed (dead code from pre-BT era)

// Per-client
bool Allowed[MAXPLAYERS + 1];  // autoreflect permission

// Movement

// Movement and look enums are defined at top of file

// Airblast state machine (per bot)
bool MissedAirblast[MAXPLAYERS + 1];    // True if we airblasted but missed the rocket
// int Deflects removed (was only used by removed TrackRocketStats)
int CachedRocketRef = INVALID_ENT_REFERENCE; // Last-spawned rocket (for stats tracking)
int ClientRocketRef[MAXPLAYERS + 1];          // Per-client best rocket entity ref
float NextRocketScan[MAXPLAYERS + 1];         // Throttle per-client rocket scans




// Multi-loop WASD orbit state
int OrbitPhaseIdx[MAXPLAYERS + 1];        // Current WASD phase (1-4)
float OrbitEpisodeEnd[MAXPLAYERS + 1]; // Absolute safety deadline for the current episode

// Evasion state (jump/crouch over low rockets)
bool Evading[MAXPLAYERS + 1];          // Currently in evasion action
bool DiedRecently[MAXPLAYERS + 1];     // True between death and next spawn - skip state reset on NER respawns
EvadeAction CurrentEvadeAction[MAXPLAYERS + 1]; // EVADE_JUMP or EVADE_CROUCH
float EvadeEnd[MAXPLAYERS + 1];        // When evasion action ends
float NextEvadeCheck[MAXPLAYERS + 1];  // Throttle evasion checks

// Rate-limit per-tick CountIncomingThreats scan (full rocket loop is expensive
// at 66 Hz x N bots). 0.1s cadence is plenty - multi-threat state doesn't
// change faster than that in practice.

// Post-deflect look behavior


// Taunts - per bot type
ArrayList TauntsPlayerDeath[MAX_BOT_TYPES];
ArrayList TauntsBotDeath[MAX_BOT_TYPES];

// Bot name cache
char BotName[MAX_NAME_LENGTH];                    // Active bot name (set from current type)
char BotNames[MAX_BOT_TYPES][MAX_NAME_LENGTH];    // Per-type names from config

// Per-bot type override for debug-states mode (each bot uses its own type)
int DebugStatesBotType[MAXPLAYERS + 1];

// ============================================================================
// PERSISTENT DEBUG SYSTEM
// Captures per-bot decision data every N ticks to a CSV log file.
// Runs continuously until manually stopped - survives map changes.
// Use: sm_botdebug to start, sm_botdebug again (or sm_stopdebug) to stop.
// ============================================================================
bool DebugActive = false;
bool DebugAutoStarted = false;      // True if sm_bot_test turned logging on - so sm_bot_test stop only stops what IT started, not a session the admin started manually with sm_botdebug
int  BotDebugTick[MAXPLAYERS + 1];  // Per-bot tick counter (was global, caused 4x logging with 4 bots)
int  DebugSampleRate = 10;          // Log every N ticks (10 = ~6.6 samples/sec at 66 tick)
int  DebugLinesWritten = 0;
int  DebugTotalLines = 0;            // Cumulative across rotations - drives hard-cap shutoff (DebugLinesWritten resets on rotate)
#define DEBUG_MAX_LINES 50000        // Rotate log file after this many lines (~400/bot/minute at rate=10, 66 tick)
#define DEBUG_MAX_TOTAL_LINES 500000 // Hard cap: auto-stop logging if user forgets sm_stopdebug (prevents unbounded rotated-file growth)
char DebugLogPath[PLATFORM_MAX_PATH];
File DebugFile = null;               // File handle for high-frequency writes (avoids console spam)

// Live in-world visualization: beams drawn from each bot showing its
// wall-scan reads, current move direction, and aim target - the same data
// the CSV logger captures, but seen directly instead of reconstructed from
// text after the fact. Toggle with sm_botdebugdraw. Independent of
// DebugActive so you can run one without the other.
bool DebugDrawActive = false;
int  BeamSprite = -1;                // PrecacheModel'd in OnMapStart

// Server movement cvars, cached. Bots accelerate and coast using the SAME
// numbers the engine moves real players with, so a server running non-default
// movement gets bots that match its feel. See ProcessBotTick's force-apply.
ConVar g_cvAccelerate = null;
ConVar g_cvFriction   = null;
ConVar g_cvStopspeed  = null;

// Held aim tremor (see SmoothAim). Re-rolled on an interval, not per tick -
// per-tick randomness is vibration, not a human hand.
#define AIM_JITTER_HOLD_MIN 0.12
#define AIM_JITTER_HOLD_MAX 0.30
float AimJitterYaw[MAXPLAYERS + 1];
float AimJitterPitch[MAXPLAYERS + 1];
float AimJitterUntil[MAXPLAYERS + 1];

// --- Nav cache overlay (sm_navdraw) ---
// Per-client so two admins can look at different areas without fighting.
#define NAV_DRAW_MAX_RADIUS 10    // 21x21 = 441 cells; each is one probe + one beam
#define NAV_DRAW_INTERVAL   0.4
#define NAV_DRAW_HEIGHT     28.0  // beam height; tall enough to read at a glance, short enough not to curtain the view
bool  NavDrawEnabled[MAXPLAYERS + 1];
int   NavDrawRadius[MAXPLAYERS + 1];
float NextNavDraw[MAXPLAYERS + 1];
float NextDebugDraw[MAXPLAYERS + 1]; // per-bot throttle so beams don't spam every tick

// Player data collection - logs human player state when debug is active.
// Same sample rate as bots so data is directly comparable.
// Use this data to study real player behavior and improve bot movesets.
int  PlayerDebugTick[MAXPLAYERS + 1];   // Per-player tick counter for sampling
float PlayerLastYaw[MAXPLAYERS + 1];    // Last aim yaw (track aim smoothness)
float PlayerLastVelX[MAXPLAYERS + 1];   // Last velocity X (track movement changes)
float PlayerLastVelY[MAXPLAYERS + 1];   // Last velocity Y

int   CfgMaxDebugStatesBots   = 16;      // Safety cap on debug-states-mode bot spawn

char      CurrentMap[64];


// === BT PER-CLIENT STATE (all fixed-size, zero heap) ===
int   BotState_[MAXPLAYERS + 1];

// Movement
float NextMoveDecision[MAXPLAYERS + 1];

// Pressure vector (multi-foe)
float PressureVec[MAXPLAYERS + 1][3];
float PressureMag[MAXPLAYERS + 1];
// Sum of the individual push MAGNITUDES (not the vector sum). Together with
// PressureMag this gives a scale-free "are they cancelling each other out"
// ratio - see UpdatePressureVector.
float PressureScalarSum[MAXPLAYERS + 1];
float PressureCancelRatio[MAXPLAYERS + 1];
int   PressureCount[MAXPLAYERS + 1];      // visible enemies that contributed
float NextPressureUpdate[MAXPLAYERS + 1];

// True while backing off from a cqc_floor_dist breach. See State_Move: retreat
// continues until cqc_retreat_dist is reached (not just barely past the
// floor), so the bot doesn't hover right at the edge and get immediately
// re-triggered as the enemy keeps approaching.
bool RetreatingFromFloor[MAXPLAYERS + 1];

// Guard post - where a can_walk=0 class (statue) last spawned. Airblast
// knockback, gang-panic pushes, etc. can shove an immobile bot off its spot
// even though it never chose to move; STATE_GUARD walks it back. Captured
// fresh on every Event_PlayerSpawn (see ResetCombatState), so it always
// means "this life's spawn point", not a stale cross-round position.
float BotGuardPos[MAXPLAYERS + 1][3];
bool  BotGuardPosValid[MAXPLAYERS + 1];
bool  ReturningToGuard[MAXPLAYERS + 1];   // hysteresis: stay in GUARD until back within GUARD_ARRIVE_DIST
#define GUARD_TRIGGER_DIST 120.0          // displacement from post that starts a guard-return
#define GUARD_ARRIVE_DIST  48.0           // distance from post considered "back on guard"

// Wall detection.
// Both arrays are indexed in the WORLD-ABSOLUTE 8-direction space: index i
// is world yaw i*45 (0 = +X, 2 = +Y, 4 = -X, 6 = -Y). Never facing-relative
// - these outlive any single tick's facing. See WorldYawToDirIndex.
bool  WallBlocked_[MAXPLAYERS + 1][8];   // wall OR edge - "don't prefer this direction"
bool  EdgeBlocked_[MAXPLAYERS + 1][8];   // edge/void specifically - "never push through this one"
float NextWallScan_[MAXPLAYERS + 1];
float LastWallPos[MAXPLAYERS + 1][3];

// Circle-strafe side commitment (see State_Move's sweet_spot branch). Held for
// an episode so the bot actually travels around the enemy instead of coin-
// flipping left/right every tick and vibrating in place.
// CQC engagement shape (cqc_mode). Dodgeball is played facing your opponent,
// so unbounded orbiting was never right - it walks the bot into whatever is
// on the far side of the enemy.
#define CQC_MODE_ARC    0   // bounded sweep in front of the enemy
#define CQC_MODE_MIRROR 1   // hold station in front, matching their slide
#define CQC_MODE_HOLD   2   // keep the band and stand, deflecting
#define CQC_MIRROR_DEADZONE 40.0   // enemy lateral speed below this = "not sliding"
// Fraction of the cqc band width that counts as "close enough to the standoff
// ring" - inside it the bot makes no radial correction at all, so it stops
// micro-adjusting over a few units. See State_Move's proportional standoff.
#define CQC_DEADBAND_FRAC 0.25

#define STRAFE_SIDE_HOLD_MIN 1.2
#define STRAFE_SIDE_HOLD_MAX 2.5

// === CQC MICRO-MOVEMENT (WASD tap simulation) ===
// Real dodgeball players don't circle-strafe continuously. They tap A/D
// for short bursts, pause, tap W/S to adjust spacing, and repeat. This
// makes their position unpredictable without looking like an orbit.
// The bot simulates this with a state machine that picks a WASD direction,
// holds it for a short tap duration, then re-rolls.
#define WASD_TAP_MIN  0.12    // shortest tap (~8 ticks at 66Hz - a quick side-step)
#define WASD_TAP_MAX  0.40    // longest tap (~26 ticks - a committed dodge)
#define WASD_PAUSE_CHANCE 25  // % chance to stop between taps (a real player pauses)
#define WASD_PAUSE_MIN 0.10   // pause duration
#define WASD_PAUSE_MAX 0.35
// Weighted direction selection: side-steps dominate, W/S are micro-adjustments
#define WASD_WEIGHT_SIDE   50  // A or D (dodge left/right)
#define WASD_WEIGHT_FWD    15  // W (close distance slightly)
#define WASD_WEIGHT_BACK   15  // S (open distance slightly)
#define WASD_WEIGHT_STOP   20  // no movement (read the play)
// Commitment: don't abandon the current tap when the enemy moves slightly.
// Only break if the enemy moved more than this in one frame (sprint/dash).
#define CQC_COMMIT_BREAK_DIST 120.0
int   StrafeSideSign[MAXPLAYERS + 1];
float StrafeSideUntil[MAXPLAYERS + 1];

// WASD micro-movement state for CQC sweet_spot
int   WasdDirection[MAXPLAYERS + 1];   // 0=stop, 1=left(A), 2=right(D), 3=fwd(W), 4=back(S)
float WasdTapUntil[MAXPLAYERS + 1];    // engine time when the current tap expires
float WasdLastEnemyDist[MAXPLAYERS + 1]; // last tick's enemy distance (for commitment check)
bool  WasdCommitted[MAXPLAYERS + 1];   // true = finishing a tap, don't re-roll

// --- Enhanced feature state ---
float EnemyLastDeflectTime[MAXPLAYERS + 1];    // GetGameTime of enemy's confirmed deflect
float EnemyMissWindow[MAXPLAYERS + 1];         // GetGameTime vulnerability deadline
float EnemyAirblastCandidateTime[MAXPLAYERS + 1];
float EnemyAirblastResolveTime[MAXPLAYERS + 1];
int   EnemyAirblastCandidateUserId[MAXPLAYERS + 1];
float EnemyLastSecondaryReady[MAXPLAYERS + 1];
float NextEnemyMissCheck[MAXPLAYERS + 1];  // 10Hz throttle for enemy airblast miss scan
float PostDeflectRepositionUntil[MAXPLAYERS + 1]; // reposition window after deflect
float FeintUntil[MAXPLAYERS + 1];              // feint window timer
int   FeintRocketRef[MAXPLAYERS + 1];
bool  FeintRollConsumed[MAXPLAYERS + 1];
int   StealRocketRef[MAXPLAYERS + 1];
int   StealRolledRocket[MAXPLAYERS + 1];
bool  StealRollPassed[MAXPLAYERS + 1];

// STATE_PANIC: multi-rocket survival tracking
float PanicUntil[MAXPLAYERS + 1];              // GetGameTime when panic episode expires
bool  PanicRollConsumed[MAXPLAYERS + 1];        // one roll per threat episode

// STATE_CHASE: pursue fleeing enemy
float ChaseUntil[MAXPLAYERS + 1];              // GetGameTime when chase episode expires
bool  ChaseRollConsumed[MAXPLAYERS + 1];        // one roll per enemy-fleeing episode
float LastEnemyDist[MAXPLAYERS + 1];           // distance to enemy last tick (for retreat detection)
float LastEnemyDistTime[MAXPLAYERS + 1];       // when LastEnemyDist was sampled

// STATE_COUNTER: pre-aim enemy deflect for instant counter
float CounterPreAimUntil[MAXPLAYERS + 1];       // GetGameTime window to hold pre-aim
float CounterPreAimYaw[MAXPLAYERS + 1];         // predicted yaw where rocket will come from
float CounterPreAimPitch[MAXPLAYERS + 1];       // predicted pitch

// STATE_BAIT: bait enemy airblast early
float BaitUntil[MAXPLAYERS + 1];                // GetGameTime when bait episode expires
bool  BaitRollConsumed[MAXPLAYERS + 1];         // one roll per deflect cycle
float BaitSidestepDir[MAXPLAYERS + 1];          // +1 or -1 strafe direction during bait

// Wall-slide commitment (see FindUnblockedDirCommitted) - which
// rotational side of an obstacle a bot is currently committed to routing
// around, and whether that commitment is actually making progress.
int   WallSlideSign[MAXPLAYERS + 1];        // +1 = clockwise-first, -1 = counter-clockwise-first, 0 = no active commitment
float WallSlideUntil[MAXPLAYERS + 1];       // GetEngineTime() when the current commitment is reassessed
float WallSlideStartDist[MAXPLAYERS + 1];   // distance-to-goal when this commitment began

// EVADE_STRAFE side commitment - picked once when a cooldown-strafe
// episode starts (see State_Deflect's onCooldown branch), held for that
// whole episode (at most ~0.75s, the airblast cooldown window) rather
// than re-picked every tick, so it reads as one continuous strafe instead
// of jittering. +1/-1 = which of the two rocket-perpendicular directions;
// 0 = no active commitment.
int   StrafeEvadeSign[MAXPLAYERS + 1];

// Decision introspection - WHY State_Move picked what it picked, not just
// what it picked. Set at each decision point in State_Move, read by
// DebugLogBotTick so the reasoning is visible per tick instead of having
// to be reverse-engineered from position deltas after the fact.
char  LastMoveReason[MAXPLAYERS + 1][20];   // "retreat_floor"/"break_flank"/"too_far"/"too_close"/"sweet_spot"/"idle"
bool  LastEdgeOverride[MAXPLAYERS + 1];     // did the edge-comfort retreat bias fire this tick
// ctl= in the debug log: did a decision-tree leaf actually decide a velocity
// this tick (1), or did it decline and leave us holding position (0)? A run of
// ctl=0 used to mean the engine's own locomotion was driving; it now means the bot is
// deliberately standing, which is a very different thing to see in a log.
bool  LastLeafDecided[MAXPLAYERS + 1];
bool  LastEdgeDistKnown[MAXPLAYERS + 1];    // false = position isn't in the cache (unknown, not "zero")
int   LastEdgeDist[MAXPLAYERS + 1];         // this tick's cell distance from the mapped boundary, valid only if Known

// One-shot internal-state dump for MaybeScanWalls's 8-direction sample,
// set once per scan so DebugLogBotTick can print which branch inside
// DirectionIsWalkable actually fired instead of only seeing the final
// O/W/V result - needed to disambiguate "cache says unsafe" from
// "cache doesn't know, live trace also says unsafe" from a symptom alone.
int   LastCacheHitCount[MAXPLAYERS + 1];    // how many of the 8 sampled targets were a NavCache_IsWalkable hit
// Direction-0 (forward) sample of MaybeScanWalls's IncrementalWallClear
// outcome: WHERE along the 100-unit sweep it failed and WHY. -1/0 = clear.
// Needed to tell "genuinely embedded/failing near distance 0" (a real
// per-tick bug) apart from "correctly found a real edge/wall out at 40-90
// units" (expected on this disk-shaped map) instead of only seeing the
// final W/V verdict with no idea where in the sweep it came from.
float LastWallFailDist[MAXPLAYERS + 1];
int   LastWallFailReason[MAXPLAYERS + 1];   // 0=clear, 1=real wall hit, 2=no floor/edge

// === WALKABLE-AREA CACHE (nav-mesh-equivalent, self-generated) ===
// TF2's own bots avoid ledges by never leaving the map's .nav mesh; that
// data is authoritative because it's pre-computed once, offline, instead
// of inferred live from a handful of per-tick traces. Dodgeball maps never
// ship a .nav file (confirmed: none exist anywhere on this server) and
// generating one is real per-map manual work with this project's map
// rotation, so relying on Valve's format isn't practical here. This is the
// same idea built ourselves instead: flood-fill outward from spawn points
// ONCE per map, off the tick-time-budget critical path, and cache which
// grid cells are actually connected, walkable ground. Runtime movement
// checks then become a cheap lookup against pre-validated data instead of
// a handful of live traces trying to guess it under time pressure - which
// is exactly the category of bug (floor-flush hulls, brush-entity plane
// normals, single-point lookahead gaps, curb-then-cliff patterns) this
// project spent this whole session chasing one at a time.
#define NAV_CELL_SIZE       48.0    // grid resolution; ~1.5x player width
#define NAV_CELL_MAX_DELTA  45.0    // max per-hop height change between adjacent cells (~45 degrees)
// Shared by NavCache_ExpandCell (the cache-build scanner, using
// SCANNER_WALL_CHECK_LIFT) and MaybeScanWalls (the live per-tick scan,
// using WALL_CHECK_LIFT) - both sweep a hull from (floorZ + their lift)
// up to (floorZ + their lift + NAV_SWEEP_HEIGHT). A ceiling-clipping
// theory here (reducing this to 36.0) was tried and measured to make no
// difference to the scanner's rejection counters - the scanner's actual
// problem was its lift value, not this height; see
// SCANNER_WALL_CHECK_LIFT. Reverted to 48.0, the value already confirmed
// (via live walls= flipping from WWWWWWWW to VVVVVVVV) to work correctly
// for the live scan at WALL_CHECK_LIFT=16.0, and - combined with
// SCANNER_WALL_CHECK_LIFT=4.0 - exactly reconstructs the original
// lift+height=52 window that's the only config to ever actually build a
// working 11000+-cell cache for the scanner.
#define NAV_SWEEP_HEIGHT    48.0
#define NAV_SCAN_BATCH      60      // cells expanded per timer tick
#define NAV_SCAN_INTERVAL   0.02    // seconds between batches
#define NAV_MAX_CELLS       20000   // safety cap so a pathological map can't scan forever
#define NAV_MIN_VIABLE_CELLS   20   // below this, the scan is treated as failed, not finished (see Timer_NavScanStep)
// Movement stays reactive without this: State_Move only ever asks "is the one
// step I'm about to take safe," the same question a player never
// consciously asks near a cliff because they're not walking that close in
// the first place. NAV_EDGE_COMFORT_CELLS is how many cells of margin from
// the nearest mapped boundary a bot tries to keep during normal movement -
// an influence-map-style bias (see NavCache_ComputeEdgeDistances), not
// another reactive last-step check.
#define NAV_EDGE_COMFORT_CELLS 4
// How many cells of buffer from the boundary DirectionIsWalkable requires
// before it will actually commit to a step, not just prefer to avoid one.
// 0 (only refuse the literal boundary cell) proved not wide enough in
// practice - a curb can be standing on a cell that's already 1+ cells
// "inland" by this metric while the real drop is still one step away.
// 2 cells (~96 units) is a real margin, not a single grid square's worth.
#define NAV_HARD_MARGIN_CELLS  2

// Nav cache flat arrays - replaces StringMap for O(1) integer-indexed lookups.
// Eliminates all FormatEx + string hash operations (~9000/sec at 8 bots).
#define NAV_GRID_SIZE  128
#define NAV_GRID_HALF  64
#define NAV_GRID_CELLS (NAV_GRID_SIZE * NAV_GRID_SIZE)  // 16384
float g_NavFloorZ[NAV_GRID_CELLS];     // floor height per cell, -9999.0 = unknown
int   g_NavEdgeDist[NAV_GRID_CELLS];   // edge distance per cell, -1 = unknown
bool  g_NavCellKnown[NAV_GRID_CELLS];  // true if cell has been mapped

// Convert grid coords to flat array index. Returns -1 if out of bounds.
ArrayList g_NavFrontier     = null;  // queue of [ix, iy, floorZ] entries awaiting expansion, as floats
int       g_NavFrontierRead = 0;     // read index into g_NavFrontier (never erases - avoids O(n^2) on a growing queue)
int       g_NavCellsDone    = 0;
// Rejection-reason counters - a one-time scan can afford to be verbose
// about exactly why a neighbor didn't expand, instead of guessing.
int       g_NavRejectWall    = 0;
int       g_NavRejectNoFloor = 0;
int       g_NavRejectSlope   = 0;
int       g_NavRejectFootprint = 0;  // see NavCache_FootprintClear - a cell whose CENTER is fine but whose edge overhangs a drop
bool      g_NavScanActive   = false;
bool      g_NavScanReady    = false; // true once this map's cache is fully built or loaded from disk
// Diagnostics only - how many times StartNavScanIfNeeded got past its
// early-out guards to actually attempt a load-or-fresh-scan, and how many
// of those attempts bailed immediately (nobody had valid footing to seed
// from). Surfaced per-tick so a "still stuck" test tells us whether the
// scan never even tried, is stuck mid-progress, or keeps bailing -
// instead of only seeing the final null/not-ready state with no history.
int       g_NavScanAttempts  = 0;
int       g_NavScanBails     = 0;
// Where the most recent fresh-scan attempt actually seeded from - lets us
// tell "the scan is dying inside a genuinely tiny enclosed room" from "the
// scan is dying somewhere it shouldn't be" instead of only seeing the
// final tiny cell count with no idea which part of the map it's stuck in.
float     g_NavSeedX = 0.0;
float     g_NavSeedY = 0.0;
float     g_NavSeedZ = 0.0;
int       g_NavSeedCount = 0;
// A one-shot scan only ever sees what its initial seed positions happened
// to reach. Confirmed real gaps this way - a bot fell after a long,
// genuinely-successful wall-slide run reached a pocket the original scan
// never explored. Growth mode re-seeds from wherever bots currently are,
// even after g_NavScanReady is already true, and keeps whatever new cells
// that finds - unlike the initial scan, a small growth result is a
// legitimate partial addition, not a failed attempt to discard.
bool      g_NavGrowthMode    = false;
Handle    g_NavScanTimer    = null;

// Orbit episode state. One loop contains four WASD phases.
int   OrbitLoopsRemaining[MAXPLAYERS + 1];
int   OrbitLoopsPlanned[MAXPLAYERS + 1];
float OrbitPhaseStart[MAXPLAYERS + 1];
float OrbitLoopDuration[MAXPLAYERS + 1];
int   OrbitRolledRocket[MAXPLAYERS + 1];  // entity reference rolled once per rocket
int   OrbitAttemptedRocket[MAXPLAYERS + 1]; // at most one episode per rocket
bool  OrbitRollPassed[MAXPLAYERS + 1];
bool  OrbitStartedFromCooldown[MAXPLAYERS + 1];

// Deflection
int   LastMoveSet[MAXPLAYERS + 1];
float LastAirblastTime[MAXPLAYERS + 1];

// Post-deflect aim - the direction the bot faces AFTER airblasting.
// TFDB reads eye angles once after the fixed global drag delay
// to apply drag to the rocket. We set this direction when airblasting,
// then smoothly turn toward it in the following ticks.
float PostDeflectAim[MAXPLAYERS + 1][2];  // [0]=pitch, [1]=yaw
bool  PostDeflectWave[MAXPLAYERS + 1];    // wave = oscillating yaw
float PostDeflectUntil[MAXPLAYERS + 1];  // engine time until post-deflect aim expires
int   PostDeflectRocketEnt[MAXPLAYERS + 1]; // the rocket entity this drag window is steering - see ProcessBotTick POST-DEFLECT DRAG
int   DeflectCount[MAXPLAYERS + 1];

// Gang
int   GangerCount_[MAXPLAYERS + 1];
float NextGangUpdate[MAXPLAYERS + 1];
float GangBoostUntil[MAXPLAYERS + 1];

// --- FSM: Formal state machine for bot behavior ---
// Consolidates the 7 implicit state machines into validated transition helpers.
// Each Set* helper logs the transition when debug is active, making state
// changes auditable. Behavior is preserved - these wrap existing writes.



// --- Event-Driven: Per-frame caches ---
// Per-frame enemy cache: FindClosestEnemy is called 6+ times per command
// callback. Cache the result per-client per-frame, invalidated on grid rebuild.
int   CachedFrameEnemy[MAXPLAYERS + 1];
bool  CachedFrameEnemyValid[MAXPLAYERS + 1];
float CachedTickPos[MAXPLAYERS + 1][3];  // per-tick cached GetClientAbsOrigin
bool  CachedTickPosValid[MAXPLAYERS + 1];

// Per-frame threat count cache: CountIncomingThreats called from movement
// blend and orbit. Cache per-client per-frame.
int   CachedFrameThreats[MAXPLAYERS + 1];
bool  CachedFrameThreatsValid[MAXPLAYERS + 1];

// ============================================================================
// SPATIAL GRID - Uniform hash grid for O(1)-ish spatial queries.
// Rebuilt each frame from OnGameFrame. Replaces O(MaxClients) linear scans
// in FindClosestEnemy and NearestTeammateDist with O(nearby cells).
// Cell size = 1000 HU (covers reaction/threat distance range).
// Grid spans ±16384 HU → 33×33 cells, keyed by "gx gy".
// ============================================================================

// ============================================================================
// VECTOR/DIRECTION HELPERS
// Extracted from 37+ inline repetitions across BT_* functions.
// Each replaces a 2-4 line micro-pattern that was copy-pasted everywhere,
// contributing to arrow-code nesting and making the BT leaves harder to read.
// ============================================================================

// Convert a 2D direction vector directly to an 8-direction compass index.
// Replaces the 13x GetVectorAngles(vec, ang) + WorldYawToDirIndex(ang[1]) combo.

// Normalize a 2D vector in-place (z untouched). Returns false if the vector
// is too short to normalize. Replaces the 10x SquareRoot+divide pattern.

// Compute the perpendicular to a 2D vector (rotate 90 degrees CCW).
// Replaces the 6x [-toEnemy[1], toEnemy[0]] pattern.

// Pick whichever of two opposite compass directions has fewer walls.
// Replaces the 8x WallBlocked_ pick pattern. Returns the unblocked dir,
// or desiredDir if the desired is already clear.



// Cached enemy lookup: returns cached result if already computed this frame.

// Get GetClientAbsOrigin, cached per tick (called 4x per bot per tick without this)

// Cached threat count: returns cached result if already computed this frame.

// One synchronous user-command snapshot. Never stored across frames.
// Mutable callback outputs (buttons, velocity, angles, impulse, weapon) remain
// explicit references on phase helpers rather than copied into this context.
enum struct PvBCommandContext {
    int client;
    bool isBot;
}

// Continuous movement blend weights (used instead of discrete modes)

// TFDB-based deflect tracking (more accurate than m_iDeflected)
int RoundDeflectsBot[MAXPLAYERS + 1];    // Per-bot deflects THIS round (reset on round start)

// Bounded profiling: fixed counters only in hot paths.
TFDBProfileWindow g_PvBProfileWindow;
int g_PvBProfileFrames;
int g_PvBProfileCommands;
int g_PvBProfileEligibleCommands;
int g_PvBProfileRocketScans;
int g_PvBProfileThreatScans;

// Get the effective bot type for a given client (debug-states vs normal)

public Plugin myinfo = {
    name        = "[TFDB] Player vs Bot",
    author      = "Silorak",
    description = "Self-learning TFDB bot. Debug-states mode, proper orbiting, evasion, personality speech.",
    version     = PLUGIN_VERSION,
    url         = ""
};

// Fix: Mark TFDB natives as optional so plugin loads even without TFDB
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    TFDB_MarkProfilerNativesOptional();
    // Expose PvB state to other subplugins (Guardian, FFA, etc.) so they can
    // refuse to activate during PvB mode.
    CreateNative("TFDB_IsPvBActive",   Native_IsPvBActive);
    CreateNative("TFDB_IsPvBDebugStates", Native_IsPvBDebugStates);
    RegPluginLibrary("tfdb_pvb");

    // Runtime state inspector commands
    RegisterInspectorCommands();

    // Reverse direction: we mark Guardian's natives optional so we can
    // query guardian state before activating PvB (without hard-requiring
    // the Guardian plugin to be loaded).
    MarkNativeAsOptional("TFDB_IsGuardianActive");

    #if defined _tfdb_included
    MarkNativeAsOptional("TFDB_IsDodgeballEnabled");
    MarkNativeAsOptional("TFDB_FindRocketByEntity");
    MarkNativeAsOptional("TFDB_GetRocketOwner");
    MarkNativeAsOptional("TFDB_GetRocketTarget");
    MarkNativeAsOptional("TFDB_IsValidRocket");
    MarkNativeAsOptional("TFDB_GetRocketSpeed");
    MarkNativeAsOptional("TFDB_GetRocketMphSpeed");
    MarkNativeAsOptional("TFDB_GetRocketDeflections");
    MarkNativeAsOptional("TFDB_GetRocketClass");
    MarkNativeAsOptional("TFDB_GetRocketClassTurnRate");
    MarkNativeAsOptional("TFDB_GetRocketClassTurnRateIncrement");
    MarkNativeAsOptional("TFDB_GetRocketClassSpeed");
    MarkNativeAsOptional("TFDB_GetRocketClassSpeedIncrement");
    MarkNativeAsOptional("TFDB_GetRocketLastDeflectionTime");
    MarkNativeAsOptional("TFDB_GetRocketEntity");
    MarkNativeAsOptional("TFDB_SetRocketSpeed");
    MarkNativeAsOptional("TFDB_GetRocketClassSpeedLimit");
    #endif
    return APLRes_Success;
}



// ============================================================================
// INITIALIZATION
// ============================================================================




// Completion callback for admin brain-reset DELETEs. Clears BrainDraining so
// normal writes resume, then reloads the in-memory brain from the (now empty
// or pruned) table. If the DELETE failed we still clear the flag - keeping it
// set would permanently block writes; the error is logged and the admin can retry.

// ============================================================================
// MAP LIFECYCLE
// ============================================================================





// See g_NavGrowthMode. Seeds from every currently in-game client's
// position, but only cells not already known - if nothing new is found
// (the common case once the map is well covered), this is a cheap no-op.

// ============================================================================
// CLIENT LIFECYCLE
// ============================================================================




// RequestFrame target - defers UpdateCachedCounts to one frame after a
// player_team event so GetClientTeam returns the post-transition value.

// ============================================================================
// ENABLE / DISABLE
// ============================================================================

// Lock down TF2's bot quota so the server never auto-spawns replacement bots.
// Called from OnPluginStart, OnMapStart, and before EnablePvB adds our bot.
// Redundant by design - some map configs can reset cvars between ticks.




// ============================================================================
// TRAINING MODE (ROOT ONLY)
// Spawns all 4 bot types on BOTH teams so they train against each other.
// Bots on RED fight bots on BLU, learning from every deflect and death.
// ============================================================================






// ============================================================================
// BOT TEST MODE - configurable bot squads for focused testing
// ============================================================================

int PendingTestTypes[MAXPLAYERS + 1];
int PendingTestCount = 0;
bool TestModeActive = false;



// ============================================================================
// ADMIN MENU SYSTEM
// ============================================================================













// Admin-issued full brain wipe. Drain-flush-delete protocol:
//   1. Set BrainDraining so new learning writes are dropped during the reset.
//   2. Temporarily release the gate and dispatch the detached pending queue as
//      one atomic SourceMod Transaction.
//   3. Queue DELETE on the same threaded database connection after that batch.
//   4. Completion callback reloads surviving rows and clears BrainDraining.
// A failed pre-reset batch is not restored while BrainDraining: the requested
// DELETE remains authoritative and must not be undone by old observations.


// ============================================================================
// PLAYER COMMANDS - Toggle, Vote, Stats, Menu
// ============================================================================





// ============================================================================
// VOTING SYSTEM
// ============================================================================


// ============================================================================
// STATS MENU
// ============================================================================



// ============================================================================
// CLIENT JOIN / CLASS SELECTION
// ============================================================================


// GetClientCount(false) counts every occupied client slot, including players
// still mid-connect (not yet IsClientInGame) and real humans sitting on
// Spectator/unassigned (not yet counted by CachedRealCount/TFDB_IsRealHumanPlaying).
// Subtracting our own fake bot slot(s) gives a precise "is anyone else here at
// all, even partway through joining" check - far better than trusting
// CachedRealCount alone, which only sees players who are fully in and on a
// play team.




// ============================================================================
// CLASS VOTE - Multiple players vote for bot type
// ============================================================================


// Special vote value used by the "Disable bot" menu item. Out-of-range of any
// real bot type index (valid types are 0..NumBotTypes-1).
#define PVB_VOTE_DISABLE  -1





/**
 * Drain a pending bot hot-swap. Called from Event_RoundEnd. Kicks the current
 * bot, loads the new type's settings, spawns a fresh bot under the new type.
 * Deliberately NOT called mid-round so the active rally doesn't get a phantom
 * bot disappearance.
 */

// ============================================================================
// BOT INFO MENU (for players) - View only! No type changing.
// Players can see what's active, check stats, and start/stop votes.
// ============================================================================



// ============================================================================
// BOUNDED PROFILING
// ============================================================================





// ============================================================================
// GAME FRAME - Team management & auto enable/disable
// ============================================================================



// Normal mode: keep bot on BLU, all humans on RED

/**
 * Respawn the human after FakeClientCommand("jointeam red") has been fully
 * processed by the engine. Called via RequestFrame so the team change is
 * already applied when this runs - otherwise TF2_RespawnPlayer would fire
 * on the old BLU team.
 */

// Debug-states mode: keep bots on their assigned teams, humans to spectator.

// ============================================================================
// EVENTS
// ============================================================================

// ============================================================================
// TEAM-JOIN PROTECTION
// ============================================================================
// Three layers:
//   1. AddCommandListener for "jointeam"/"autoteam" - intercepts user commands
//      BEFORE the engine processes them. FakeClientCommandEx reroutes.
//   2. player_team event hook (Pre) - catches engine-level team changes that
//      bypass the command (mp_autoteambalance, trigger_multiple, etc).
//      Schedules Timer_PvBForceTeam 0.1s later as fallback.
//   3. ManageTeams() reactive polling every 2 frames (pre-existing) - last
//      line of defense.
//
// Contract:
//   - Normal PvB (BotEnabled): humans on RED (team 2); bot on BLU (team 3)
//   - Debug-states mode: humans on SPECTATOR (team 1); bots on both teams
//   - Neither mode active: no intervention, plugin is passive
// ============================================================================


// Only count REAL deflects - when the airblast actually hits the rocket.
// The engine fires object_deflected only on a successful airblast connection.


// ============================================================================
// Natives - exposed for other subplugins to query PvB state before they
// activate conflicting modes (e.g. Guardian refuses to start during PvB).
// ============================================================================









// ============================================================================
// ROCKET TRACKING
// ============================================================================


// ============================================================================
// TFDB DEFLECT FORWARD - Fires when a rocket is ACTUALLY deflected.
// This is the authoritative deflect counter, not the airblast button press.
// ============================================================================

#if defined _tfdb_included

#endif




// Positive when the rocket is moving toward the target position.

// Per-client rocket finder. Priorities:
// 1. Rocket targeting THIS client (highest priority - must airblast)
// 2. Rocket flying TOWARD this client within threat range (dodge/avoid)
// 3. Fallback to global cached rocket if TFDB not available
// Scans are throttled to every 0.1s per client to avoid perf issues.











// Multi-rocket threat count.
// Counts how many rockets are both (a) close enough to matter and (b) moving
// toward this bot with closing velocity. Used by the movement layer to shift
// to defensive stance when multiple rockets converge (can't orbit safely,
// should hold position and focus on timing).
//
// Returns 0..N. Callers typically branch on >= 2 as "multi-threat."
// Cheap: O(rocket count) which is typically <= 4 in TFDB.

// Returns true if the given rocket entity is specifically targeting this client.
// Used to decide whether bot should airblast vs just dodge.

// ============================================================================
// EVASION HELPERS
// Extracted from OnPlayerRunCmd to flatten depth-7 nesting.
// ============================================================================

/**
 * Maintains an active evasion action (jump/crouch button press).
 * Returns early if no evasion is active or the window has elapsed.
 */

/**
 * Checks whether a new evasion opportunity exists and starts it.
 * Guard-clause chain replaces the original depth-7 nesting.
 */

// ============================================================================
// CORE BOT LOGIC - OnPlayerRunCmd
// ============================================================================



// ============================================================================
// BEHAVIOR TREE - Flat priority-based state dispatch.
// Max depth 2: UpdateBotState picks a state, then one BT_* leaf executes.
// Each leaf is a stub returning Plugin_Continue until Phase 2+ implementation.
// ============================================================================



// === MOVE SET TYPES ===
enum MoveSetType {
    MOVE_NORMAL = 0,
    MOVE_WAVE,
    MOVE_UPSPIKE,
    MOVE_DOWNSPIKE,
    MOVE_BOUNCE,
    MOVE_DIRECT,
    MOVE_BACKFIRE,
    MOVE_COUNT
}
#define NUM_MOVE_SETS 7

// === STUB FUNCTIONS (implemented in Phase 2+) ===

// Ground-truth check before committing to a jump-evasion. A jump adds no new
// horizontal velocity of its own - it only carries whatever momentum the
// bot already had (e.g. from State_Move) into the air. MaybeScanWalls' scan
// already folds map-edge detection in with walls (see ScanWalls:
// TR_PointOutsideWorld) for exactly this reason - State_Move/State_Dodge/State_Orbit
// already consult it before choosing a walking direction, but the jump
// triggers in State_Deflect never checked it before pressing IN_JUMP, so a bot
// already moving toward a ledge when a rocket got close would jump straight
// off it instead of just continuing to walk up to the edge and stopping.


// Estimates the rocket's CURRENT effective turn rate. A class's configured
// "turn rate" is only the STARTING value - core scales it up per deflection
// via "turn rate increment" (see dodgeball_rockets.inc CalculateRocketTurnRate
// / CalculateModifier), so a rocket that was gentle at 0 deflections can be
// well past the orbit-safety threshold by deflection 5 on a tight cfg. Only
// the deflection term is replicated here (not rockets-fired/player-count) -
// those two drift slowly across a whole round and don't meaningfully change
// tick-to-tick, which is what "is orbiting safe right now" actually needs.

// Shared safety check for both entering orbit and continuing an orbit already
// in progress - called every tick of State_Orbit, not just once at entry, since
// the rocket's effective turn rate/speed can escalate past "safe" mid-orbit.
//
// "About to hit" awareness: if the rocket would close the remaining distance
// before even one more WASD phase could finish, further circling is pointless
// - bail to deflect instead of blindly running out a pre-committed loop count.
// This is what makes a tight cfg naturally cap the bot at partial or even zero
// orbit loops, and a loose cfg let it run its full randomized budget, without
// any separate hardcoded per-cfg tuning.


// Select a move set using weighted random from config

// Get move set name for debug logging



// Stub BT leaf functions (Phase 2+ implementation)
// Would an airblast fired RIGHT NOW actually touch this rocket?
//
// The compression blast is a fixed box: ~256 HU reach and a ~60 degree cone.
// A press outside either of those is not a miss, it is a no-op that still
// costs the full 0.75s cooldown - and on a dodgeball server that cooldown is
// usually the difference between deflecting the incoming rocket and being
// killed by it. "Bots airblasting nothing and dying" is exactly this: two
// call sites were firing at 600 and 400 units, both far outside the 256 the
// blast can physically reach, so those presses could never have connected at
// any angle.
//
// Every place that presses IN_ATTACK2 goes through here.


// EVADE-STRAFE (recovery/delay, not real dodge-out-of-the-way evasion).
// Extracted from State_Deflect's onCooldown branch to reduce nesting depth -
// inline it was reaching depth 6, worse than the depth-5 the 2026-07-12
// systems audit flagged as needing decomposition in the old monolithic
// OnPlayerRunCmd. Same pattern already used throughout this file
// ("Extracted from X to reduce nesting depth").
//
// By the time State_Deflect's onCooldown branch calls this, distToRocket <=
// AIRBLAST_RANGE (240) and the bot is already facing the rocket - it's
// close, lined up, and can't fire yet. A real player backs off and
// strafes clear rather than standing there waiting for the cooldown, aim
// staying locked on the threat the whole time (SmoothAim in State_Deflect
// already does that independently of this). Gated the same way
// jump-evasion is: per-class cfg, off for statue-like/can't-walk classes
// since standing and holding guard IS their identity, not something to
// strafe away from. Returns true if it applied a strafe/hold this tick
// (including a deliberate zero-velocity hold), false if the caller should
// fall back to normal State_Move CQC positioning instead.

// Fresh side pick for a new EVADE_STRAFE episode: prefer whichever side
// the wall/edge scan actually reads as clear right now - not a fixed
// left/right rule, the same "whichever side feels dodgeable in the
// moment" judgment call this whole mechanic is modeling, proxied by real
// scan data instead of a coin flip where possible.

// Already committed to a side - keep going the same way unless that side
// has since turned unsafe (backed toward a wall/edge mid-strafe), in
// which case flip if the other side is clear, otherwise hold position
// (sign 0) rather than push into either.


// Dodge node - strafe perpendicular to rocket velocity
// Orbit state machine - WASD phases to circle around the rocket

// ============================================================================
// PHASE 2: MOVEMENT + WALL AVOIDANCE
// ============================================================================

#define WALL_SCAN_INTERVAL  0.2
#define WALL_SKIP_DIST  50.0

// Downward trace from start to end, hopping EDGE_CHECK_STEP units at a
// time instead of checking only the far endpoint (a single distant sample
// can land on flat ground BEYOND a localized dip or cliff, "jumping over"
// exactly the drop that matters). LIVE-TRACE FALLBACK ONLY: this is what
// every per-tick edge check used to run directly. Kept as the fallback for
// the brief window before this map's walkable-area cache (see below) has
// finished its one-time scan - prefer DirectionIsWalkable() everywhere
// else, which checks the cache first and only drops to this when the cache
// isn't ready yet.

// === WALKABLE-AREA CACHE ===
// See the globals block above for the rationale. Grid key is "ix:iy" where
// ix/iy are the position divided by NAV_CELL_SIZE and rounded.
// Multi-source BFS distance transform over the completed walkable-cell set:
// every cell's distance (in grid hops) to the nearest cell that borders
// unmapped space, i.e. a real edge. This is what turns the cache from a
// reactive "is this one step safe" gate into something normal movement can
// actively stay away from, the same way a player doesn't consciously
// re-check every footstep near a ledge because they're not walking that
// close to begin with. Run once, right after the cache itself is ready
// (fresh scan or loaded from disk) - cheap relative to building the cache
// itself, since it's just neighbor lookups over an already-known cell set.

// outDist: grid hops to the nearest mapped edge. false if unknown (outside
// the cache, or the field hasn't been computed yet).

// Direction (as a normalized 2D vector) from pos toward whichever
// immediate grid neighbor has the highest edge-distance - "which way is
// most away from the nearest boundary." Used to override normal movement
// when a bot is already inside the comfort margin, same as a player
// instinctively stepping back from an edge instead of optimizing position
// relative to an enemy while standing right on it.

// Downward probe used both to seed the flood-fill and to validate each
// candidate cell during expansion. Same technique as the live edge-check,
// just run once per cell instead of every tick.

// Runtime lookup: is the grid cell containing pos[] confirmed walkable by
// the completed (or in-progress) scan? Only trustworthy once g_NavScanReady
// - callers must fall back to the live trace otherwise, since a cell that
// simply hasn't been reached YET by an in-progress scan is not the same as
// a cell the scan has confirmed is unwalkable.





// Returns true if a cache existed on disk and was loaded successfully.


// Entry point: called from Event_PlayerSpawn (any client's first spawn is
// enough to have a seed position). No-op once a scan has completed or is
// already running for this map.

// The general fix, not another per-map patch: every cell-acceptance check
// so far only ever sampled ONE point (the cell's center). A cliff edge
// doesn't respect the 48-unit grid - it can cut straight through the
// middle of a cell, leaving the center reading "solid ground" while part
// of that same tile already overhangs empty air. Confirmed on abyss_v4:
// a bot fell from a spot the cache rated edgeDist=18-20 (deep "safe"
// interior by graph distance), because the cell it stood on was accepted
// by a single center-point check, not because it was actually near any
// correctly-recorded boundary. This checks several points across the
// tile - roughly a player's footprint, not a single sample - before the
// cell is allowed into the graph at all. A cell that's genuinely
// straddling an edge fails here and is simply never added, which means
// every distance-from-boundary defense already built (margin, retreat
// bias) starts measuring from a real edge instead of one drawn a cell too
// far out. This is checked once, at scan time, so being thorough here is
// free in a way it never was for the live per-tick path.

// A single hull sweep held at ONE fixed height across a whole hop cannot
// cross a real staircase: stairs are discrete steps (risers), not a
// smooth ramp, so a level sweep slams straight into the first riser even
// though a player walking down it normally has zero trouble (the engine's
// own per-step movement follows the stairs; this trace doesn't). Confirmed
// on abyss_v4 via seed-position diagnostics: fresh nav-cache scans kept
// seeding from an elevated spawn platform (z=79) that sits ~16 units above
// the main floor (z=63) reached by a staircase, and every single expansion
// attempt died there - 100% rejwall, 0% from any other rejection reason,
// an exact match for "the sweep can't get past the first step down."
// Fixes this by walking the same short hops the floor-check already uses
// (EDGE_CHECK_STEP), re-sweeping a short segment at the CURRENT local
// floor height after each hop instead of the original position's height
// for the whole distance - the same technique DirectionIsWalkable_LiveTrace
// already uses for floor validation, just also applied to the wall check.
//
// Shared by NavCache_ExpandCell (the cache-build scanner, 48-unit hops)
// and MaybeScanWalls (the live per-tick scan, 100-unit/WALL_CHECK_DIST
// sweeps) - the live scan's longer single-shot sweep turned out to have
// the exact same "can't follow real terrain" problem regardless of lift
// value, just less obviously since it doesn't have rejection counters to
// show 100% wall failures the way the scanner did.
// outNoFloor distinguishes WHY it failed: a real TR_TraceHull hit (solid
// geometry - a genuine wall) vs. simply running out of floor (an edge -
// on a disk/island-shaped map surrounded by void, most directions from
// most positions run out of floor within 100 units long before hitting
// any actual wall brush). Conflating the two into one bool was the actual
// bug: MaybeScanWalls already has a SEPARATE, correct edge check
// (DirectionIsWalkable/offEdge) feeding EdgeBlocked_ - but this
// function's floor-probe failures were ALSO being reported as a wall hit
// (WallBlocked_ via hitWall), duplicating and mislabeling "there's an edge
// here" as "there's a wall here". On this map's disk shape, that meant
// nearly every bot far from the exact center had at least one of its 8
// sampled directions run into void within 100 units, misreported as W.
//
// THIRD bug found in this function (2026-08-09): TR_TraceHull without a
// filter isn't brush-only despite the mask's name - MASK_SOLID_BRUSHONLY
// only controls which CONTENTS_* flags count on world brushes, it does
// NOT exclude other players/bots from the trace. Confirmed via per-segment
// diagnostics: 100% of live per-tick samples failed at the very first
// 8-unit segment as a "real wall hit", completely unmoved by lift=4 vs
// lift=16 (ruling out a height/clearance problem) - in close-quarters
// dodgeball combat, bots constantly cluster near each other and their
// target, so a teammate or enemy standing within the first 8 units of the
// sweep direction (often literally the enemy being aimed at) reads as a
// solid wall. TraceFilter_NoPlayers already existed in this file but was
// never wired up anywhere. Now uses TR_TraceHullFilter with it so only
// world/static geometry counts - other players no longer register as
// walls.



// Post-scan self-audit. Answers, with no admin action required, the question
// the abyss_v4 cache raises on inspection: is this a map of real ground, or
// one flat brush the probe can see everywhere?
//
// That cache came out as 11,019 of 11,022 cells at EXACTLY z=64.03, an
// unbroken 105x105 square spanning +-2496 - while bots fell to -230 from
// x~2060 with the cache reporting edgeDist 9-10. If the extreme cells report
// the same entity and the same z as the centre, the flood-fill mapped a
// phantom surface and every edgeDist derived from it is measured against the
// wrong boundary (which is why edgeov has never once fired).

// Cache-first walkability check - the one every live call site should use.
// Falls back to the live trace hop-check only while this map's one-time
// scan hasn't finished yet (or was never able to start).

// 8-direction wall scan relative to bot facing

// Pressure vector - multi-foe positioning

// ============================================================================
// 8-DIRECTION INDEX SPACE - WORLD-ABSOLUTE, NOT FACING-RELATIVE.
//
// Index i is world yaw i*45 degrees: 0 = +X, 2 = +Y, 4 = -X, 6 = -Y.
// This is the single shared convention for WallBlocked_/EdgeBlocked_ and
// every consumer of them.
//
// It used to be facing-relative (dirs[0] = wherever the bot was looking).
// That could never work: MaybeScanWalls stamps the array using the eye yaw
// AT SCAN TIME and the cache lives for WALL_SCAN_INTERVAL (0.2s, ~13 ticks),
// while every reader converted its world yaw using the eye yaw RIGHT NOW.
// A dodgeball bot is tracking a homing rocket through SmoothAim factors of
// 0.6-0.9 plus outright TeleportEntity angle snaps during the drag window,
// so its yaw routinely swings 90-180 degrees inside one scan interval -
// several times the 45-degree width of a single bucket. WallBlocked_[3]
// meant "back-right as of 0.2s ago" but was read as "back-right now", so
// the wall/edge map was arbitrarily rotated against reality and every
// consumer inherited it: direction preference in FindUnblockedDirCommitted,
// side choice in EvadeStrafePickSide, the open-direction count in CanOrbit,
// and - the one that actually killed bots - JumpEvadeSafe clearing a jump
// against a direction map pointing somewhere else entirely.
//
// An earlier pass caught half of this and made callers subtract the current
// facing, which is why the old comment here described doing exactly that.
// Subtracting the CURRENT facing from a world yaw does not convert it into
// the SCAN-TIME facing's frame - it just moved the same rotation error
// around. World-absolute removes the frame mismatch outright: neither side
// of the exchange depends on where the bot happens to be looking.
// ============================================================================

// Inverse of WorldYawToDirIndex: the unit world-space ground vector for a
// direction index. Uses GetAngleVectors rather than raw trig so this shares
// the engine's own yaw convention byte for byte with everything else that
// builds a direction from angles.

// Wall helper: find an unblocked direction near the desired one
// Returns true if found, fills outDir with the direction index

// Same idea as FindUnblockedDir, but with commitment: a bot deflected
// around an obstacle keeps trying the SAME rotational side (CW or CCW)
// across ticks instead of blindly re-deriving "clockwise first" fresh
// every time. Without this, a wall that curves (the layered rings on
// octagon are the reported case) produces exactly "runs into the wall and
// circles like a dumb bot" - desiredDir gets recomputed fresh each tick
// purely from CQC positioning with zero memory of the wall it just
// bumped, FindUnblockedDir's CW-first bias resolves it the same way every
// time, and the bot just slides along the same curve indefinitely with no
// concept of whether that's actually getting anywhere.
//
// Fix: commit to one rotational side for a couple seconds. When the
// commitment expires, check whether distance to the goal actually
// improved over that window - if not, flip to the other side next time
// instead of re-committing to the side that demonstrably wasn't working.
// This is the standard fix for reactive-avoidance oscillation (short of
// full pathfinding over the nav-cache grid, which is the further step if
// this still isn't enough): commit-and-reassess, not "smarter" per-tick
// math, since the actual problem is a lack of memory across ticks.

// Like FindUnblockedDir, but against EdgeBlocked_ instead of WallBlocked_.
// Used only by the "all 8 directions blocked, push through anyway" last
// resorts: a wall is safe to bump through (engine stops you), a void edge
// is not (nothing stops you but gravity). Returns false only if every
// single direction is an edge - genuinely nowhere safe to move.

// Movement node - follow/keep distance, wall-aware

// Guard-return node - walks a displaced can_walk=0 bot (statue) back to
// BotGuardPos. Reuses State_Move's wall-aware direction logic instead of a
// blind beeline so it doesn't march straight into geometry that happens to
// sit between the bot and its post.

// Idle node - stand still, face enemy if one exists

// Stub helper - Phase 5


// Forward declarations for BT action nodes



// Main BT entry point - replaces RunPvBCommand's sequential flow with
// a structured tree evaluation. The behavior is identical to the original
// orchestrator; the tree structure makes priorities and early-exit points
// explicit and auditable.
//
// Returns Plugin_Continue (no changes needed) or Plugin_Changed (state mutated).
// Wall check and pit avoidance with hysteresis and wall-stuck mode switching.
// Extracted from ExecutePvBMovement to reduce nesting depth.
// Separation steering: when a teammate is very close (<200 HU), override
// the blend with a direct velocity push away. Extracted from ExecutePvBMovement.
// Compute movement blend desires (idle, toward, circle, away) and apply them
// to the blend arrays. Extracted from ExecutePvBMovement to reduce nesting depth.
// Handles: strategy pattern coefficients, CQC distance, opponent tendency,
// heatmap danger, separation steering, rocket speed, threat count, teammate proximity.




// ============================================================================
// TRICK APPLICATION
// ============================================================================


// ============================================================================
// CONFIG LOADING
// ============================================================================

// Case-insensitive lowercase copy (used for class key normalization)

// Return the class index matching a name/key, or -1 if not found.
// Matches against both the lowercase key and the display name (case-insensitive).

// Fill [botType] config slots with safe defaults. Used before reading a class
// section, so missing keys fall back to sane values rather than zero.

// Read the class section currently positioned at `kv` into slot `t`.
// The caller must have already JumpToKey'd into the class section.


// Switch active class at runtime. All per-class settings are already loaded
// into arrays, so this just flips the index and updates the bot name.

// Load speech files per bot type. Uses each class's lowercase key to look up
// "<key>_playerdeath" and "<key>_botdeath" entries in the "speech" section.
// Defaults fall back to the shipped universal taunts so a missing/incomplete
// "speech" section degrades gracefully instead of silently logging open errors.

// ============================================================================
// PERSISTENT DEBUG SYSTEM - Commands and Logging
// ============================================================================


// Force a clean rescan. The on-disk cache outlives every code change -
// StartNavScanIfNeeded loads it and returns, so a probe fix has no effect on
// an existing map until the file is gone. That cost several rounds of
// "nothing changed" when the actual scanner had in fact been fixed.



// Per-cell nav overlay. Each cell gets one short vertical beam, coloured by
// comparing the CACHE against a fresh live probe of the same spot - the two
// disagreeing is the whole point, so the colours are chosen to make
// disagreement impossible to miss rather than to look tidy.
//
// This exists because the abyss_v4 cache is 11,019/11,022 cells at exactly
// z=64.03 covering an unbroken +-2496 square, while bots fall to -230 from
// x~2060. Reading that off a saved text file takes a diff and a hypothesis;
// seeing a magenta shelf hanging out past the real rim takes one look.

// Minimal "#userid" arg parser - returns a valid in-game client index, or
// -1 if arg isn't a #userid reference at all (caller decides what that means).

// "See every cell" directly instead of inferring the cache's understanding
// of an area from bot behavior. Dumps a grid of walkable-cache cells
// centered on the caller's own position (or a target client's, passed as
// #userid) - each cell's floor height and distance from the mapped
// boundary, or X if the cache doesn't know it at all.

// "What general.cfg [pvb.cfg] fire" - the ACTUAL loaded runtime values for
// a bot class, not the file on disk. No args: dumps every configured type.
// #userid: dumps that bot's effective type. A raw number: dumps that type
// index directly.

// Beams showing exactly what the CSV logger's walls=/vel=/enemy= fields
// capture as text, seen live instead of reconstructed after the fact -
// this is the wall-scan data (see MaybeScanWalls) that the whole
// abyss_v4/octagon debugging this session kept needing to infer from
// dozens of log lines at a time. Green = open, red = wall, orange = edge.
// Cyan = this tick's decided move direction. Yellow = current aim target.
// Throttled per-bot so it's readable instead of a strobing mess.



// ============================================================================
// BRAIN INSPECTION COMMANDS
// Expose what the bot has learned to admins. All ROOT because raw policy
// weights and SteamID-keyed opponent profiles are sensitive. Output goes to
// admin's console (via ReplyToCommand) - no chat spam.
//
// See subplugins/PvB-brain-inspection.md for usage examples.
// ============================================================================







// Plugin-scoped log. Everything PvB has to say - nav scan progress and
// audits, state changes, fall-kills, enable/disable - lands in
// logs/tfdb_pvb/pvb_<date>.log instead of the shared SourceMod log, where it
// was getting buried among every other plugin's output and repeatedly sent
// people grepping the wrong file.
//
// One file per day, appended. These are low-frequency events (scan
// start/finish, round transitions), not per-tick data - the high-volume
// dataset still goes through DebugFile, which holds its handle open. Opening
// per call here keeps the file consistent if the server crashes mid-round.
//
// Creates the directory itself rather than relying on the one made in
// OnPluginStart: StartNavScanIfNeeded() runs BEFORE that block, so the very
// first nav messages of a session would otherwise be dropped.




// Shared post-write bookkeeping: bumps line counters, enforces the hard cap
// (auto-stops logging if the user forgot sm_stopdebug - otherwise rotated
// files would grow unbounded), then rotates the current file at DEBUG_MAX_LINES.
// Call after every DebugFile.WriteLine() that participates in the line budget.
// ============================================================================
// DECISION-TRACE LOGGING
// Captures the RATIONALE behind a bot's choice (cfg values consulted, rolls
// made, branches taken) - not just the final state. Use at every pivotal
// branch in the behavior tree so post-hoc analysis can answer "why did statue walk
// instead of idle?", "why did 3 bots all idle the same tick?", etc.
//
// Lines are tagged DECISION/<where> for grep-by-decision-point. Always logged
// regardless of sample rate - these are rare events, not per-tick noise.
//
// Format: [tick N] DECISION/<where> #idx name type=T <free-form details>
// Example: [tick 12345] DECISION/MoveMode #2 TBotV64 type=1 cfg.idle_chance=100 roll=42 wantIdle=1 -> MOVE_IDLE
// ============================================================================


// ============================================================================
// PLAYER DATA COLLECTION
// Logs human player state in the same debug file as bot data. Prefixed with
// [PLAYER] so it's easy to filter. Captures movement, aim, buttons, position,
// and rocket awareness - everything needed to study how real players behave
// and derive better bot movesets from the data.
// ============================================================================

// ============================================================================
// BOT TICK LOGGING - the dataset sm_bot_test spawns. Same fields as
// DebugLogPlayerState (position/velocity/aim/rocket-awareness/nearest enemy)
// plus the bot-specific state the behavior tree actually branches on: which
// BotState it's in (IDLE/MOVE/ORBIT/DODGE/DEFLECT/GANG_ESCAPE), whether it's
// mid jump-evasion (and which kind), whether it's mid-orbit, and the last
// move/trick it picked. Sampled at DebugSampleRate (not every tick) via
// BotDebugTick, same throttle StartDebugLogging already resets per session.
// Call from ProcessBotTick after state dispatch so vel/angles/buttons reflect
// this tick's actual decision, not the previous one.
// ============================================================================

// ============================================================================
// COMBAT STATE RESET
// ============================================================================




// ============================================================================
// FIND CLOSEST ENEMY
// ============================================================================


// ============================================================================
// ANGLE UTILITIES
// ============================================================================


// Humanlike aim state: tracks recent aim targets for overshoot simulation
float LastAimTargetYaw[MAXPLAYERS + 1];
int   AimTicksSinceTarget[MAXPLAYERS + 1];  // Ticks since target changed (for overshoot)

// Aim speed for tracking a rocket, scaled by how close it is.
//
// Fixed per-branch factors (0.6 / 0.75 / 0.85 / 0.9) made the bot swing onto
// a rocket at nearly the same rate whether it was 850 units out or about to
// hit - which reads as inhuman in both directions at once: twitchy on a
// distant rocket nobody would be urgent about, and no more committed when it
// actually matters. Good players are the opposite: loose and unhurried while
// the rocket is far, then very fast in the last stretch.
//
// Linear between the two configured distances, clamped outside them, so
// "far" and "near" are the tuning knobs rather than the curve shape.



// ============================================================================
// TRACE FILTER
// ============================================================================


// For "is this a genuine WALL" specifically (IncrementalWallClear), not
// just "not a player" - TraceFilter_NoPlayers stopped players from
// registering as walls, but confirmed via spacebox_udl_a4 diagnostics
// (walls=WWWWWWWW, faildist=8, while the bot was in state=DEFLECT with a
// rocket actively targeting it) a nearby dodgeball ROCKET entity can
// ALSO false-positive as a wall: under the default TRACE_EVERYTHING mode,
// only DYNAMIC entities go through the filter at all (static props are
// always solid regardless, bypassing the filter entirely - see
// TraceType's documented behavior), so excluding just the client index
// range still leaves every other dynamic entity (rockets, physics props,
// anything else) counting as solid. Only the world entity (index 0)
// should count here; static props still register correctly since they
// never reach the filter to begin with.
// Source engine collision groups. SourceMod ships no constants for these, so
// they're declared here from the SDK's collisionproperty.h ordering. Only the
// ones TraceFilter_PlayerSolid actually tests are named; the numbering is the
// engine's and must not be reordered.
#define COLLISION_GROUP_DEBRIS              1   // never collides with anything
#define COLLISION_GROUP_DEBRIS_TRIGGER      2   // debris, but hits triggers
#define COLLISION_GROUP_INTERACTIVE_DEBRIS  3   // doesn't collide with other debris or players
#define COLLISION_GROUP_WEAPON             11   // dropped weapons
#define COLLISION_GROUP_VEHICLE_CLIP       12   // blocks vehicles only
#define COLLISION_GROUP_PROJECTILE         13   // rockets/grenades - passes players
#define COLLISION_GROUP_PASSABLE_DOOR      15   // player walks through
#define COLLISION_GROUP_DISSOLVING         16   // mid-dissolve, non-solid to players

// From the SDK's ISolid interface (m_usSolidFlags). Also not shipped by
// SourceMod. Only the one this file tests is named.
#define FSOLID_NOT_SOLID                0x0004  // entity is not solid at all

// Floor-probe filter: what counts as GROUND for walkability purposes.
//
// Measured on tfdb_abyss_v4 via sm_navcell, which is why this is neither of
// the two obvious filters:
//   * unfiltered      - returns players ("ent=1 class=player startsolid=1").
//   * WorldOnly       - returns nothing. The real floor here is
//                        `func_brush` (ent 51, CONTENTS_SOLID at z=64.03),
//                        a brush ENTITY, so entity==0 finds no ground at all
//                        and every scan bails.
// So: keep brush entities, drop players.
//
// And it drops anything that does not block PLAYER movement, which is the
// actual root cause of the abyss falls.
//
// Out past the rim the probe hit `func_physbox_multiplayer` at z=-11.19.
// That entity is on the map to stop ROCKETS leaving the arena - players
// walk straight through it. But it is CONTENTS_SOLID, so a trace stops dead
// on it and reports "floor". The cache then records ground where a player
// cannot stand, the bot walks out onto it, and falls. Cache and live probe
// agreed the whole time, which is why the overlay showed GREEN over the exact
// spot bots die: both were asking "does a trace stop here", when the question
// that matters is "does a PLAYER stop here".
//
// Discriminating by classname would only ever patch this one map. The engine
// already stores the answer: an entity's collision group decides what it
// actually collides with. Reject the groups that pass players through, and
// this generalises to any map - which is the whole point, since these bots
// are meant to handle maps nobody has hand-tuned for them.


// ============================================================================
// UTILITY STOCKS
// ============================================================================





// ============================================================================
// RUNTIME STATE INSPECTOR
// ============================================================================
// Admin commands for live bot/rocket/brain state inspection.
// Must be at end of file (after all globals are defined).
// Commands:
//   sm_inspect_bot <client>    - Full bot state dump
//   sm_inspect_rocket <index>  - Rocket state dump
//   sm_inspect_grid            - Spatial grid summary
//   sm_inspect_all             - Full snapshot of all bots + rockets
// ============================================================================










// === INCLUDE FILES (function bodies split for readability) ===
#include "include/tfdb_pvb_helpers.inc"
#include "include/tfdb_pvb_nav.inc"
#include "include/tfdb_pvb_config.inc"
#include "include/tfdb_pvb_debug.inc"
#include "include/tfdb_pvb_states.inc"
#include "include/tfdb_pvb_teams.inc"
#include "include/tfdb_pvb_menus.inc"