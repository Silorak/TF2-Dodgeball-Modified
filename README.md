<div align="center">

# TF2 Dodgeball

[![Version](https://img.shields.io/badge/version-2.2.0-blue?style=for-the-badge)](https://github.com/Silorak/TF2-Dodgeball-Modified/releases)
[![SourceMod](https://img.shields.io/badge/SourceMod-1.12-orange?style=for-the-badge)](https://www.sourcemod.net/)
[![License](https://img.shields.io/badge/license-GPL%20v3-green?style=for-the-badge)](LICENSE)

A modern, stable, and highly extensible dodgeball gamemode for TF2 SourceMod servers — built on the shoulders of community giants.

[Installation](#installation) · [Configuration](#configuration) · [Subplugins](#subplugins) · [API](#developer-api)

</div>

---

## Architecture

A modular plugin suite built around a shared native API. The core plugin handles all rocket logic, homing, physics, and game state. Subplugins extend functionality and can be loaded or unloaded independently.

| Plugin | File | Purpose |
|--------|------|---------|
| **Core** | `dodgeball.smx` | Rocket spawning, homing, deflection, steal/delay, game state, 130+ natives |
| **Guardian** | `tfdb_guardian.smx` | 1-vs-all boss mode with configurable classes and abilities |
| **FFA** | `tfdb_ffa.smx` | Free-for-all mode with friendly fire |
| **PlayerVsBot** | `tfdb_pvb.smx` | Self-learning dodgeball AI with capability-driven config |
| **DeathMatch** | `tfdb_deathmatch.smx` | Never-Ending Rounds + Solo queue (based on Mikah's NER/SOLO) |
| **AntiCheat** | `tfdb_anti_cheat.smx` | Server-side cheat detection (+ `tfdb_ac_debug.smx` debug companion) |
| **Votes** | `tfdb_votes.smx` | Player voting system |
| **Menu** | `tfdb_menu.smx` | In-game admin settings menu |
| **Speedometer** | `tfdb_speedhud.smx` | Real-time rocket speed HUD |
| **Trails** | `tfdb_trails.smx` | Visual rocket trail effects |
| **Print** | `tfdb_print.smx` | Enhanced chat message formatting |
| **ExtraEvents** | `tfdb_extra_events.smx` | Additional event hooks (`on destroyed`, etc.) |
| **AntiSnipe** | `tfdb_anti_snipe.smx` | Blocks long-distance rocket interference |

**Core is required.** Everything else is optional — load whichever modules you need.

> **Note:** Push prevention, noblock, and target lock are built into core and configured via `general.cfg`. The old standalone AirblastPrevention, NoBlock, and AntiSwitch subplugins have been removed.

---

## Features

**Gameplay** — Steal and delay prevention built-in. Dual homing modes (smooth `homing` or classic `legacy homing`). Per-class cadence via `"think interval"` — 20 Hz for authentic YADB/Damizean feel, per-tick for modern smooth. Bouncing rockets with player-controlled force bouncing. "Keep Direction" (popular Redux feature). Neutral rockets, per-class damage, and configurable kill events.

**Drag mechanics** — Emergent drag by default (one eye-angle read at the airblast event, no polling window) — the legacy feel without the sticky polling of modern forks. Tunable per-class via `"steering control"` (pre-read drag window, seconds) and `"bounce control"` (post-bounce blind window, seconds). Design flicky or heavy rockets without touching core code.

**Tickrate-independent feel** — Rocket behavior is identical across 66 / 100 / 128-tick servers. Drag / bounce windows are authored in seconds and auto-convert to real ticks at parse time. Turn rate scales via `GetTickInterval()` per frame. Author your cfg on one server, deploy anywhere without re-tuning.

**Engine cap override** — The `"max velocity"` key in `general.cfg` sets `sv_maxvelocity` on map load (default TF2 cap is 3500 HU/s; raise it for high-speed rallies).

**Rocket classes** — Fully configurable with custom models, sounds, speeds, damage, turn rates, and bounce limits. Event commands with `@rocket`, `@owner`, `@target`, `@speed` placeholders. Experimental scaling modes for orbit tightness and target-speed-based acceleration. See [`configs/dodgeball/guide.md`](TF2Dodgeball/addons/sourcemod/configs/dodgeball/guide.md) for the full field reference and ready-made recipes (sniper, boulder, nuke, Damizean-authentic, competitive default).

**Guardian mode** — One player becomes a boss on BLU with custom HP, a boss health bar, glow, and two configurable abilities (rage, sprint, pounce, charge, slow). Weighted random class selection. Opt-out system with configurable minimum players. Blocked automatically when bots or FFA are active. 4-layer team-join defense (`jointeam` listener + `player_team` event + timer fallback + spawn catch) prevents non-guardians from landing on BLU.

**Self-learning bot (PvB)** — Pyro dodgeball bot with persistent per-class SQLite brain. Learns per-opponent trick preferences, drifts reaction time with success/failure, tracks map-level danger heatmaps, runs league-style self-play for diversity. Capability-by-presence config: remove keys from `pvb.cfg` and the bot becomes physically incapable of that behavior (no orbits, no evasion, no CQC, no idle — or permanent idle with `idle_chance 100`). Multi-rocket threat detection forces defensive stance when two rockets converge. Team-join protection (ported from Guardian) prevents humans landing on the bot's team.

**Anti-cheat** — Server-side detection targeted at common public-tier cheats. Six detections: AntiAim (impossible pitch), OneTickM2 (1-tick airblast signature), ReactTimeFloor (deflects below 120 ms physiological floor), DragSnapback (snap-airblast-restore pattern), AirblastFacing (tick-choking silent-aim signature), SnapAim. Cumulative threshold scoring with configurable kick/ban actions and admin immunity. Does NOT target paid-tier cheats with active AC bypass.

**DeathMatch (NER + Solo)** — Never-Ending Rounds keeps small-server rounds alive by swapping players between teams on death. Solo queue lets players sit out and rejoin when a team empties. Per-client respawn protection, two-pass cosmetic team-color fix after swap, FFA coexistence. Mutually exclusive with Guardian and PvB.

**Cross-plugin ecosystem** — Guardian, PvB, and DeathMatch use a three-way mutual-exclusion protocol so they never run simultaneously (team-management conflict). FFA coexists with all three. Plugin-developer friendly: every subplugin registers a library via `RegPluginLibrary` and exposes optional natives (`TFDB_IsGuardianActive`, `TFDB_IsPvBActive`, `TFDB_IsDeathMatchActive`). Third-party plugins can integrate via runtime `LibraryExists` gates without hard dependencies.

**Per-map configs** — Override any setting for specific maps by creating `configs/dodgeball/tfdb_mapname.cfg`. The gamemode activates automatically on maps prefixed `tfdb_`, `db_`, or `dbs_` (including Workshop maps).

---

## Installation

### Requirements

- **SourceMod 1.12+** and **MetaMod:Source**
- **[TF2Attributes](https://github.com/FlaminSarge/tf2attributes)** — only if using Guardian module
- **[CollisionHook](https://forums.alliedmods.net/showthread.php?t=197815)** — only if using AntiSnipe module

All dependencies are optional — only install if using the corresponding feature.

### File Structure

The release zip contains two top-level folders. `TF2Dodgeball/` is the core install that maps directly onto your server's `tf/` directory. `Subplugins/` contains source code for optional modules — their compiled `.smx` files are already included in `TF2Dodgeball/`.

```
From this repo                              →  Install to server
──────────────────────────────────────────────────────────────────
TF2Dodgeball/addons/                        →  tf/addons/
TF2Dodgeball/cfg/                           →  tf/cfg/
Subplugins/                                 →  (source code only, not needed on server)
```

Full server layout after install:

```
tf/
├── cfg/sourcemod/
│   ├── dodgeball_enable.cfg                ← exec'd when dodgeball map loads
│   ├── dodgeball_disable.cfg               ← exec'd when leaving dodgeball map
│   ├── dodgeball_ffa_enable.cfg            ← exec'd when FFA activates
│   └── dodgeball_ffa_disable.cfg           ← exec'd when FFA deactivates
└── addons/sourcemod/
    ├── plugins/
    │   ├── dodgeball.smx                   ← required (core)
    │   ├── tfdb_guardian.smx               ← optional
    │   ├── tfdb_ffa.smx                    ← optional
    │   ├── tfdb_pvb.smx                    ← optional (PlayerVsBot)
    │   ├── tfdb_deathmatch.smx             ← optional (NER + Solo queue)
    │   ├── tfdb_anti_cheat.smx             ← optional
    │   ├── tfdb_ac_debug.smx               ← optional (AC debug companion)
    │   ├── tfdb_votes.smx                  ← optional
    │   ├── tfdb_menu.smx                   ← optional
    │   ├── tfdb_speedhud.smx               ← optional
    │   ├── tfdb_trails.smx                 ← optional
    │   ├── tfdb_print.smx                  ← optional
    │   ├── tfdb_extra_events.smx           ← optional
    │   └── tfdb_anti_snipe.smx             ← optional
    ├── configs/dodgeball/
    │   ├── general.cfg                     ← main rocket/game configuration
    │   ├── guide.md                        ← field reference + rocket-design recipes
    │   ├── guardian.cfg                    ← guardian classes and abilities
    │   ├── pvb.cfg                         ← PlayerVsBot classes + tuning
    │   ├── presets.cfg                     ← rocket class presets
    │   └── tfdb_mapname.cfg                ← per-map overrides (create as needed)
    ├── data/sqlite/
    │   └── tfdb_pvb.sq3                    ← PvB persistent brain (auto-created)
    ├── logs/tfdb_ac/                       ← AntiCheat detection logs (auto-created)
    ├── gamedata/
    │   └── tf2.attributes.txt              ← required for Guardian (TF2Attributes)
    ├── translations/
    │   └── tfdb.phrases.txt
    └── scripting/
        ├── include/
        │   ├── tfdb.inc                    ← core API (130+ natives)
        │   ├── tfdb_guardian.inc           ← guardian API
        │   ├── tfdb_pvb.inc                ← PvB state-query API
        │   ├── tfdb_deathmatch.inc         ← DeathMatch state-query API
        │   └── tfdbtrails.inc              ← trails API
        └── dodgeball.sp                    ← core source
```

> **Don't want a subplugin?** Move its `.smx` to the `plugins/disabled/` folder. No other files need to change — subplugins detect core via `SharedPlugin` and have no hard dependencies on each other.

### Quick Install

1. Download the latest release from the [Releases Page](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest)
2. Extract `TF2Dodgeball/` contents into your server's `tf/` directory (merge with existing folders)
3. Install dependencies if using Guardian (`tf2attributes.smx` + `tf2.attributes.txt`) or AntiSnipe (`collisionhook.ext`)
4. Restart the server or change to any `tfdb_`, `db_`, or `dbs_` prefixed map

### Compile Order

Compile `dodgeball.sp` first (it generates `tfdb.inc` natives). Then compile subplugins in any order. Subplugin source is in `Subplugins/<name>/scripting/`.

---

## Core Configuration

The core plugin uses one file: `configs/dodgeball/general.cfg`. It defines rocket classes, spawner behavior, and built-in features (push prevention, noblock, target lock, max velocity override). Deliberately kept minimal — one-line comments only. Fields are ordered top-down by how often you'll tune them.

**For the full reference** (every field explained, rocket-design recipes, dormant features, troubleshooting), see [`guide.md`](TF2Dodgeball/addons/sourcemod/configs/dodgeball/guide.md) in the same folder.

<details>
<summary><b>Example rocket class</b></summary>

```
"common"
{
    "name"                "Homing Rocket"
    "behaviour"           "homing"

    "speed"               "975"
    "speed increment"     "260"
    "turn rate"           "0.2640"
    "turn rate increment" "0.0190"

    "damage"              "40"
    "damage increment"    "25"
    "critical chance"     "100"

    // Drag / bounce feel (seconds, auto-scaled to any tickrate — see guide.md)
    "steering control"    "0.045"   // 0=tight, 0.045=master, 0.091=heavy
    "bounce control"      "0.045"
    "bounce scale"        "0.8"     // velocity kept per bounce
    "max bounces"         "10000"

    "think interval"      "0"       // 0 = per-tick smooth. 0.05 = 20Hz Damizean.

    "on kill"             "tf_dodgeball_print [KILL] ##@owner## killed ##@dead##"
}
```

</details>

<details>
<summary><b>Designing rocket feel via the drag knobs</b></summary>

| Feel | `steering control` | `bounce control` | `think interval` |
|---|---|---|---|
| Modern smooth (default) | 0.045 | 0.045 | 0 (per-tick) |
| Heavy, sticky | 0.106 | 0.106 | 0 |
| Snappy, instant | 0.015 | 0 | 0 |
| Damizean-authentic (YADB 1.4.2) | 0.045 | 0.045 | 0.05 (20 Hz) |
| Chunky old-2.2.0 legacy | 0.045 | 0.045 | 0.1 (10 Hz) |

When `think interval > 0`, turn rate applies **raw per fire** (no tick-scale compensation), so Damizean-era turn-rate values (e.g. 0.233) produce Damizean-era rotation rates.

</details>

Subplugin-specific configs (guardian.cfg, pvb.cfg, AntiCheat cvars) are documented under each subplugin in the [Subplugins](#subplugins) section below.

### Per-map Overrides

Create `configs/dodgeball/tfdb_mapname.cfg` (e.g. `tfdb_stadium_b3.cfg`) to override any value from `general.cfg` for that specific map. Only include the values you want to change — everything else inherits from `general.cfg`.

---

## Subplugins

Click a section to expand details. Summaries stay visible for quick scanning.

<details>
<summary><b>Guardian</b> — 1-vs-all boss mode</summary>

One player per round becomes the Guardian — a boss on BLU with boosted HP, a visible boss health bar, player glow, and two configurable abilities. Everyone else fights on RED. Guardian is blocked when bots (including PvB bots) are on the server, or during FFA rounds.

**Commands**

| Command | Permission | Description |
|---------|------------|-------------|
| `sm_forceguardian <player> [class]` | CONFIG | Force a player as Guardian next round |
| `sm_guardianclass <class>` | CONFIG | Set guardian class for next round |
| `sm_removeguardian` | CONFIG | Remove the current Guardian mid-round |
| `sm_guardian` | Public | Toggle opt-out from being selected |
| `sm_dguardian` | ROOT | Toggle debug mode (spawns bots, verbose logging) |

**Configured via** `configs/dodgeball/guardian.cfg` — classes, abilities, HUD position, selection chance.

<details>
<summary><b>Guardian class example</b></summary>

```
"berserker"
{
    "name"       "Berserker"
    "health"     "5000"
    "weight"     "100"          // higher = more likely to be picked

    "ability_1"
    {
        "type"     "pounce"
        "button"   "ATTACK3"   // Middle Mouse
        "cooldown" "10.0"
        "duration" "5.0"
        "arg1"     "1200.0"    // forward force
        "arg2"     "600.0"     // upward force
        "particle" "utaunt_multicurse_teamcolor_blue"
    }

    "ability_2"
    {
        "type"     "slow"
        "button"   "RELOAD"    // R key
        "cooldown" "15.0"
        "duration" "10.0"
        "arg1"     "500.0"     // radius
        "arg2"     "50.0"      // 50% slow
        "particle" "utaunt_hands_teamcolor_blue"
    }
}
```

**Ability types:** `rage` (airblast boost), `sprint` (speed buff), `charge` (high speed buff), `pounce` (directional launch), `slow` (AoE stun pulse with visual ring).

**Buttons:** `TAUNT` (G), `RELOAD` (R), `ATTACK3` (middle mouse), `USE` (H).

</details>

</details>

<details>
<summary><b>PlayerVsBot (PvB)</b> — self-learning dodgeball bot</summary>

Self-learning Pyro dodgeball bot. Configured via `configs/dodgeball/pvb.cfg`.

**Features**

- **Persistent learning** — SQLite brain stored in `addons/sourcemod/data/sqlite/tfdb_pvb.sq3`. Per-class policy tables, reaction-time drift, per-opponent behavioral profile (keyed on SteamID), and per-map danger heatmaps.
- **Six decision types** — airblast timing, trick selection, aim offset, movement mode, orbit choice, evasion. Each keyed on discretized world state + opponent tendency.
- **Credit-assignment-aware rewards** — DEFLECT credits timing/aim/trick fully and positioning at half; DEATH inverts. Continuous shaping rewards fill the silence between deflect/death events.
- **Multi-rocket awareness** — when 2+ rockets converge, bot forces defensive stance and blocks orbit entry.
- **Shared base policy** — new class types inherit aggregate wisdom from a type-agnostic key; mature classes diverge to their own policy.
- **League-style self-play** — training mode detects monocultures and spawns exploiters to force adaptation.
- **Team-join protection** — 3-layer defense prevents humans from landing on the bot's team. Training mode force-moves humans to spectator.
- **Capability-by-presence config** — remove keys from `pvb.cfg` and the bot loses that behavior entirely.

Auto-locks `tf_bot_quota_mode normal` on plugin load + every map start so the server never auto-fills with vanilla Pyro bots.

**Commands**

| Command | Permission | Description |
|---------|------------|-------------|
| `sm_votepvb` / `sm_votebot` / `sm_botvote` | Public | Vote to enable the PvB bot |
| `sm_pvb` | CONFIG | Admin toggle (bypasses vote) |
| `sm_trainbots` | ROOT | Spawn training bots (bot-vs-bot self-play) |
| `sm_setbottype <index>` | KICK | Set bot class (see `pvb.cfg` for indices) |
| `sm_reloadbotcfg` | KICK | Reload `pvb.cfg` without map change |
| `sm_resetbrain` | ROOT | Wipe learned bot brain data (safe during active rounds) |

<details>
<summary><b>Capability-by-presence reference</b></summary>

Remove a key from a bot class block in `pvb.cfg` and the bot becomes physically incapable of that behavior — not "chance 0", fully absent.

| Remove these keys | Result |
|---|---|
| `orbit_time`, `orbit_max_loops`, `orbit_chance` (any one gone = all gone) | Bot never orbits |
| `evade_chance` | Bot never jumps/crouches to evade |
| All four `cqc_*_dist` keys | Bot ignores close-quarters distance thresholds |
| `idle_chance` | Bot never stands still |
| `idle_chance "100"` (keep, set to 100) | Bot is permanently idle (same as `statue_like 1` but works on any class) |

</details>

</details>

<details>
<summary><b>AntiCheat</b> — server-side detection (6 categories)</summary>

Server-side cheat detection. Targets common public-tier cheats — **not** paid-tier cheats with active AC bypass.

**Detections**

| Detection | Catches | Decays? | Weight |
|---|---|---|---|
| `AntiAim` | Pitch outside ±89° (engine-impossible) | No | 5 |
| `ReactTimeFloor` | Deflect <120 ms from rocket becoming incoming | No | 8 |
| `OneTickM2` | IN_ATTACK2 held for exactly 1 tick, streak ≥3 | Yes | 6 |
| `DragSnapback` | Post-control-delay snap-and-return pattern | Yes | 4 |
| `AirblastFacing` | 3 consecutive deflects while not facing rocket | Yes | 4 |
| `SnapAim` | >35° single-tick angle snap + airblast + return | Yes | 5 |

**Cvars** — auto-created in `cfg/sourcemod/tfdb_anticheat.cfg` on first run.

| Cvar | Default | Purpose |
|---|---|---|
| `tfdb_ac_enabled` | `1` | Master toggle |
| `tfdb_ac_action` | `1` | `0` = log only, `1` = kick, `2` = ban |
| `tfdb_ac_action_threshold` | `30` | Cumulative score before action fires |
| `tfdb_ac_ban_duration` | `1440` | Minutes; `0` = permanent |
| `tfdb_ac_immunity_flag` | `b` | Admin flag letter granting immunity |
| `tfdb_ac_admin_hud` | `1` | Show live scores to admins |
| `tfdb_ac_log_level` | `1` | `0` silent, `1` detections, `2` verbose, `3` debug |

**Deploy advice:** run `tfdb_ac_action 0` (log only) for a week → review `addons/sourcemod/logs/tfdb_ac/` → raise to `1` (kick) once pros aren't flagged → `2` (ban) only after FP rate is confirmed low.

**Commands**

| Command | Permission | Description |
|---------|------------|-------------|
| `sm_ac_status` | BAN | Show live suspicion scores for all players |
| `sm_ac_reset <player>` | ROOT | Reset detection counters for one player |
| `sm_ac_debug_player <player>` | ROOT | Toggle per-client usercmd CSV logging |

Companion plugin `tfdb_ac_debug.smx` provides the per-client CSV logging for triage — enable with `sm_ac_debug_player`.

</details>

<details>
<summary><b>FFA</b> — free-for-all mode</summary>

Free-for-all mode. Enables friendly fire so rockets target everyone. Toggled via vote or admin command. Automatically blocked during Guardian rounds. **Coexists with DeathMatch** — NER behavior adapts to skip team swaps when FFA is active.

</details>

<details>
<summary><b>DeathMatch</b> — Never-Ending Rounds + Solo queue</summary>

Based on **Mikah's** *NER/SOLO Standalone plugin For Dodgeball* (v1.5.3), rewritten for TFDB v2.2.0. Two modes that work together or independently:

- **NER (Never-Ending Rounds)** — when a team would lose, a player from the winning team is swapped over to keep the round going. Great for small servers where a round would otherwise end in seconds.
- **Solo queue** — players can toggle solo to sit out mid-round. They die immediately and are respawned whenever a team empties (with optional priority over NER team-swaps).

Players get a short damage-immunity window after any DeathMatch respawn. A horn plays to signal the respawn.

**Mutually exclusive** with Guardian and PvB (team-management conflict). **Coexists with FFA** — NER adapts to respawn players in-place instead of swapping teams when FFA is on.

**Commands**

| Command | Permission | Description |
|---|---|---|
| `sm_solo` | Public | Toggle solo (join/leave the queue) |
| `sm_votedm` | Public | Vote to toggle DeathMatch mode |
| `sm_dm` | CONFIG | Admin toggle DeathMatch directly (bypasses vote) |

<details>
<summary><b>Cvars</b></summary>

Auto-created in `cfg/sourcemod/tfdb_deathmatch.cfg` on first run.

| Cvar | Default | Purpose |
|---|---|---|
| `tfdb_dm_ner_enabled` | `1` | Enable NER feature |
| `tfdb_dm_ner_force` | `0` | Force NER on (cannot be disabled by vote or admin) |
| `tfdb_dm_ner_force_start` | `0` | Turn NER on at map start |
| `tfdb_dm_ner_vote_timeout` | `120` | NER vote cooldown in seconds |
| `tfdb_dm_solo_enabled` | `1` | Enable solo queue |
| `tfdb_dm_solo_priority` | `1` | Respawn soloers before switching alive teammates |
| `tfdb_dm_horn_volume` | `0.5` | Volume (0–1) of the respawn horn |
| `tfdb_dm_respawn_protection` | `2.0` | Seconds of damage immunity after a DM respawn |

</details>

</details>

<details>
<summary><b>Votes</b> — in-game voting system</summary>

Player voting system for enabling/disabling game features mid-match.

</details>

<details>
<summary><b>Speedometer</b> — real-time rocket speed HUD</summary>

Real-time HUD displaying current rocket speed in MPH. Positioned to not overlap with Guardian HUD. Players can toggle with a client cookie (persists across sessions).

</details>

<details>
<summary><b>Trails</b> — sprite + particle rocket trails</summary>

Visual sprite-based trail effects on rockets. Players can toggle visibility with `sm_rockettrails` and `sm_rocketspritetrails`. Configured in rocket class blocks in `general.cfg` (trail fields are commented out by default — see `guide.md` for enabling).

</details>

<details>
<summary><b>AntiSnipe</b> — long-distance rocket interference blocker</summary>

Blocks players from interfering with rockets at long distances using CollisionHook. Requires the CollisionHook extension. Warns at load time if the extension is missing.

</details>

<details>
<summary><b>Menu</b> — in-game admin config menu</summary>

In-game admin menu for adjusting dodgeball settings without editing config files. Live reload option picks up disk changes to `general.cfg`. Per-class feel knobs (speed, turn rate, damage, **steering control**, **bounce control**, **think interval**) are tunable live — changes apply on next rocket spawn.

| Command | Permission | Description |
|---|---|---|
| `sm_tfdb` | CONFIG | Open the admin menu |

</details>

<details>
<summary><b>ExtraEvents</b> — additional rocket event hooks</summary>

Adds the `on destroyed` event for rockets that explode without killing a player. Required if your rocket class configs use that event in `general.cfg`.

</details>

<details>
<summary><b>Print</b> — chat color formatting</summary>

Enhanced chat formatting for event commands. Provides `tf_dodgeball_print` with color tag support (`{olive}`, `{red}`, `##@owner##` team-color substitutions, etc.). See `guide.md` for the full color tag list.

</details>

---

## Developer API

Include the relevant `.inc` in your plugin. Core provides 130+ natives; Guardian and PvB expose state-query natives for cross-plugin coordination. Click a section to see the main natives and forwards.

<details>
<summary><b>Core</b> — <code>tfdb.inc</code> (130+ natives)</summary>

```sourcepawn
#include <tfdb>

// Game state
TFDB_IsDodgeballEnabled()
TFDB_GetRoundStarted()
TFDB_GetRocketCount()

// Rocket manipulation
TFDB_GetRocketSpeed(int iIndex)
TFDB_SetRocketSpeed(int iIndex, float fSpeed)
TFDB_SetRocketTarget(int iIndex, int iTarget)
TFDB_GetRocketTarget(int iIndex)
TFDB_CreateRocket(int spawner, int spawnerClass, int team)
TFDB_DestroyRocket(int iIndex)
```

**Forwards**

```sourcepawn
TFDB_OnRocketCreated(int iIndex, int iEntity)
TFDB_OnRocketDeflect(int iIndex, int iEntity, int iOwner)
TFDB_OnRocketDeflectPre(int iIndex, int iEntity, int iOwner, int &iNewTarget)
TFDB_OnRocketSteal(int iIndex, int iOwner, int iTarget, int iStealCount)
TFDB_OnRocketsConfigExecuted(const char[] configFile)
```

Full reference: [`tfdb.inc`](TF2Dodgeball/addons/sourcemod/scripting/include/tfdb.inc).

</details>

<details>
<summary><b>Guardian</b> — <code>tfdb_guardian.inc</code></summary>

```sourcepawn
#include <tfdb_guardian>

TFDB_IsGuardianActive()      // bool: is a guardian round in progress?
TFDB_GetGuardian()           // int:  guardian client index, or 0
TFDB_IsNextRoundGuardian()   // bool: will next round be guardian?
```

Use these if your subplugin needs to refuse activation while a Guardian round is live.

</details>

<details>
<summary><b>PlayerVsBot</b> — <code>tfdb_pvb.inc</code></summary>

```sourcepawn
#include <tfdb_pvb>

TFDB_IsPvBActive()           // bool: PvB normal mode active (bot fighting humans)
TFDB_IsPvBTraining()         // bool: training mode active (bot-vs-bot)
```

Use these if your subplugin needs to defer to PvB — e.g., refuse to activate a conflicting mode while PvB owns the round.

</details>

<details>
<summary><b>DeathMatch</b> — <code>tfdb_deathmatch.inc</code></summary>

```sourcepawn
#include <tfdb_deathmatch>

TFDB_IsDeathMatchActive()    // bool: NER running OR soloers queued
TFDB_IsNEREnabled()          // bool: Never-Ending Rounds specifically
```

Use these to gate team-management or round-ending logic while DeathMatch owns the round.

</details>

<details>
<summary><b>Canonical runtime-gated integration pattern</b></summary>

All four optional natives above (`TFDB_IsGuardianActive`, `TFDB_IsPvBActive`, `TFDB_IsPvBTraining`, `TFDB_IsDeathMatchActive`) follow SourceMod's optional-native convention. Your plugin compiles and loads cleanly whether or not the partner plugin is installed.

```sourcepawn
if (LibraryExists("tfdb_pvb") &&
    GetFeatureStatus(FeatureType_Native, "TFDB_IsPvBActive") == FeatureStatus_Available &&
    TFDB_IsPvBActive())
{
    // PvB is running — defer or refuse to activate your mode.
}
```

Register your own library in `OnPluginStart` via `RegPluginLibrary("your_name")` so partners can check presence symmetrically. Full protocol in `wiki/frameworks/guardian-pvb-deathmatch-mutual-exclusion.md`.

</details>

> Full API documentation available in the `.inc` headers under `addons/sourcemod/scripting/include/`.

---

## Troubleshooting

Click a category to expand relevant issues.

<details>
<summary><b>Install & load</b> — plugin not loading, dependencies</summary>

**Dodgeball not activating** — The gamemode only activates on maps prefixed `tfdb_`, `db_`, or `dbs_` (including Workshop maps). Check that `dodgeball.smx` is loaded with `sm plugins list` in server console.

**Subplugin not loading** — Make sure the `.smx` file is in `addons/sourcemod/plugins/` (not still in the `Subplugins/` source folder). Check `sm plugins list` and the SourceMod error log for dependency issues.

**TF2Attributes errors** — Make sure both `tf2attributes.smx` (extension) and `gamedata/tf2.attributes.txt` are installed. Guardian's health and ability system requires this. Download from [FlaminSarge/tf2attributes](https://github.com/FlaminSarge/tf2attributes).

</details>

<details>
<summary><b>Rockets</b> — homing, model, feel</summary>

**Rockets not homing** — Make sure `general.cfg` has `"behaviour" "homing"` on your rocket class. The `"legacy homing"` mode behaves differently. Check that `dodgeball_enable.cfg` is being exec'd.

**Rockets feel sticky or unflickable after deflect** — Check `"steering control"` on the affected class. Higher values (5-8) give a wider drag window. Set `"control delay"` to 0 for immediate post-read homing; 0.1+ for a coast period.

**Nuke rocket renders as ERROR model / red cube** — Your server has `sv_pure 1` (or higher) without a whitelist for `models/custom/dodgeball/`. The nuke's custom model (`models/custom/dodgeball/nuke/nuke.mdl`) is being blocked by pure mode. Either add the custom path to `cfg/pure_server_whitelist.txt`, set `sv_pure 0` / `-1`, or clear the `"model"` field on the nuke class in `general.cfg` to fall back to the default rocket model.

</details>

<details>
<summary><b>Guardian</b> — not triggering, abilities broken</summary>

**Guardian not triggering** — Guardian is automatically blocked when bots are on the server (on RED or BLU teams). Kick all bots first. It's also blocked during FFA rounds, PvB rounds, and when fewer than 2 eligible players are present. Check `logs/guardian_select.log` for detailed selection diagnostics.

**Guardian abilities not working** — Abilities only unlock after `arena_round_start` fires (when players can move). Check that your `guardian.cfg` has valid ability types and buttons.

</details>

<details>
<summary><b>PlayerVsBot (PvB)</b> — bot replaced, team mixing</summary>

**PvB bot replaced by dumb vanilla bot after map change** — Your server has `tf_bot_quota_mode fill` or `match`. PvB auto-sets it to `normal` on plugin load + each map start, but some map configs override it. Add `sm_cvar tf_bot_quota_mode normal` to your `cfg/sourcemod/dodgeball_enable.cfg` as a belt-and-suspenders.

**Players spawning on the bot's team briefly** — Should no longer happen after the team-join protection layer landed. If you see it, confirm `tfdb_pvb.smx` is loaded and the `player_team` event hook + command listener registered successfully in the server console at plugin load.

</details>

<details>
<summary><b>AntiCheat</b> — false positives, late load</summary>

**AntiCheat flagging legit pros** — Run with `tfdb_ac_action 0` (log only) first; review detection distributions per player before kicking/banning. Raise `tfdb_ac_action_threshold` if pros trip via SnapAim or AirblastFacing (both have residual FP risk).

**AntiCheat not detecting on late plugin load** — Timers are created in `OnMapStart`. The plugin now auto-triggers `OnMapStart` when loaded mid-map. If you see "timers not firing" on older builds, just change map.

</details>

<details>
<summary><b>DeathMatch</b> — NER/Solo not activating, cosmetics wrong color</summary>

**`sm_dm` says "cannot activate"** — DeathMatch refuses when Guardian or PvB is active. Disable those first (`sm_votepvb` / `sm_removeguardian`) or wait for the round to end.

**NER swapped me to the other team but my cosmetic is still the old team color** — Fixed. DeathMatch does a two-pass wearable fix (immediate + next-frame) on every swap. If you somehow still hit it, a manual respawn resolves it.

**NER "works" in FFA but feels weird** — By design. When FFA is active, NER respawns players on whichever team they were on (no cross-team swap), since FFA has already neutralized team sides.

**Soloer list truncated** — The announce buffer is 512 chars (~30–40 names). Servers with that many simultaneous soloers almost certainly don't exist, but if yours does, raise `listBuffer` size in `tfdb_deathmatch.sp`.

</details>

---

## Credits

| | |
|---|---|
| **Damizean** | Original YADB |
| **bloody & lizzy** | Updated YADB |
| **ClassicGuzzi** | Dodgeball Redux |
| **BloodyNightmare & Mitchell** | Airblast Prevention |
| **x07x08** | Major Advancements |
| **Mikah** | NER/SOLO Standalone plugin (basis of DeathMatch) |
| **Silorak** | Current Maintainer |

And the entire SourceMod community for their continued support.

---

## License

GPL v3.0 — see [LICENSE](LICENSE).

<div align="center">

[Report Bug](https://github.com/Silorak/TF2-Dodgeball-Modified/issues) · [Request Feature](https://github.com/Silorak/TF2-Dodgeball-Modified/issues)

</div>
