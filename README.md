<div align="center">

# TF2 Dodgeball

[![Version](https://img.shields.io/badge/version-2.3.0-blue?style=for-the-badge)](https://github.com/Silorak/TF2-Dodgeball-Modified/releases)
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
| **Votes** | `tfdb_votes.smx` | Player voting system |
| **Menu** | `tfdb_menu.smx` | In-game admin settings menu |
| **Speedometer** | `tfdb_speedhud.smx` | Real-time rocket speed HUD |
| **Trails** | `tfdb_trails.smx` | Visual rocket trail effects |
| **Print** | `tfdb_print.smx` | Enhanced chat message formatting |
| **ExtraEvents** | `tfdb_extra_events.smx` | Additional event hooks (on destroyed, etc.) |
| **AntiSnipe** | `tfdb_anti_snipe.smx` | Blocks long-distance rocket interference |
| **AntiCheat** | `tfdb_anti_cheat.smx` | Cheat detection (+ `tfdb_ac_debug.smx` debug companion) |

**Core is required.** Everything else is optional — load whichever modules you need.

> **Note:** Push prevention, noblock, and target lock are built into core and configured via `general.cfg`. The old standalone AirblastPrevention, NoBlock, and AntiSwitch subplugins have been removed.

---

## Features

**Gameplay** — Steal and delay prevention built-in. Dual homing modes (smooth `homing` or classic `legacy homing`). Bouncing rockets with player-controlled force bouncing. "Keep Direction" (popular Redux feature). Neutral rockets, per-class damage, and configurable kill events.

**Rocket Classes** — Fully configurable rocket types with custom models, sounds, speeds, damage, turn rates, and bounce limits. Event commands with `@rocket`, `@owner`, `@target`, `@speed` placeholders. Experimental scaling modes for orbit tightness and target-speed-based acceleration.

**Guardian Mode** — One player becomes a boss on BLU with custom HP, a boss health bar, glow, and two configurable abilities (rage, sprint, pounce, charge, slow). Weighted random class selection. Opt-out system with configurable minimum players. Blocked automatically when bots or FFA are active.

**Per-Map Configs** — Override any setting for specific maps by creating `configs/dodgeball/tfdb_mapname.cfg`. The gamemode activates automatically on maps prefixed `tfdb_`, `db_`, or `dbs_` (including Workshop maps).

---

## Installation

### Requirements

- **SourceMod 1.12+** and **MetaMod:Source**
- **[TF2Attributes](https://github.com/FlaminSarge/tf2attributes)** — only if using Guardian module
- **[CollisionHook](https://forums.alliedmods.net/showthread.php?t=197815)** — only if using AntiSnipe module
- **[Nuke Model](https://forums.alliedmods.net/showpost.php?p=2180141&postcount=350)** — only if using nuke explosion effects

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
    │   ├── tfdb_votes.smx                  ← optional
    │   ├── tfdb_menu.smx                   ← optional
    │   ├── tfdb_speedhud.smx               ← optional
    │   ├── tfdb_trails.smx                 ← optional
    │   ├── tfdb_print.smx                  ← optional
    │   ├── tfdb_extra_events.smx           ← optional
    │   ├── tfdb_anti_snipe.smx             ← optional
    │   ├── tfdb_anti_cheat.smx             ← optional
    │   └── tfdb_ac_debug.smx               ← optional (anti-cheat debug)
    ├── configs/dodgeball/
    │   ├── general.cfg                     ← main rocket/game configuration
    │   ├── guardian.cfg                    ← guardian classes and abilities
    │   ├── presets.cfg                     ← rocket class presets
    │   └── tfdb_mapname.cfg               ← per-map overrides (create as needed)
    ├── gamedata/
    │   └── tf2.attributes.txt             ← required for Guardian (TF2Attributes)
    ├── translations/
    │   └── tfdb.phrases.txt
    └── scripting/
        ├── include/
        │   ├── tfdb.inc                   ← public API (130+ natives)
        │   ├── tfdb_guardian.inc           ← guardian API
        │   └── tfdbtrails.inc             ← trails API
        └── dodgeball.sp                   ← core source
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

## Configuration

### Core — `configs/dodgeball/general.cfg`

This is the main configuration file. It controls rocket classes, game mechanics, and built-in features. The file is heavily commented — open it for the full reference.

Key sections: rocket class definitions (speed, turn rate, damage, bouncing, events), experimental scaling modes (orbit coefficient, target speed scaling), steal/delay prevention settings, push prevention, noblock, and target lock.

<details>
<summary><b>Example Rocket Class</b></summary>

```
"normal"
{
    "name"                "Normal Rocket"
    "behaviour"           "homing"
    "damage"              "50"
    "speed"               "800"
    "speed increment"     "50"
    "turn rate"           "0.260"
    "turn rate increment" "0.018"
    "max bounces"         "2"
    "on kill"             "sm_beacon @target"
}
```

</details>

### Guardian — `configs/dodgeball/guardian.cfg`

Configures guardian mode: enable/disable, selection chance per round, HUD position/color, and guardian classes with abilities.

<details>
<summary><b>Guardian Class Example</b></summary>

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

### Per-Map Overrides

Create `configs/dodgeball/tfdb_mapname.cfg` (e.g. `tfdb_stadium_b3.cfg`) to override any value from `general.cfg` for that specific map. Only include the values you want to change — everything else inherits from `general.cfg`.

---

## Subplugins

### Guardian

One player per round becomes the Guardian — a boss on BLU with boosted HP, a visible boss health bar, player glow, and two configurable abilities. Everyone else fights on RED. Guardian is blocked when bots or FFA are active.

| Command | Permission | Description |
|---------|------------|-------------|
| `sm_forceguardian <player> [class]` | CONFIG | Force a player as Guardian next round |
| `sm_guardianclass <class>` | CONFIG | Set guardian class for next round |
| `sm_removeguardian` | CONFIG | Remove the current Guardian mid-round |
| `sm_guardian` | Public | Toggle opt-out from being selected |
| `sm_dguardian` | CHEATS | Toggle debug mode (spawns bots, verbose logging) |

### FFA

Free-for-all mode. Enables friendly fire so rockets target everyone. Toggled via vote or admin command. Automatically blocked during Guardian rounds.

### Votes

Player voting system for enabling/disabling game features mid-match.

### Speedometer

Real-time HUD displaying current rocket speed in MPH. Positioned to not overlap with Guardian HUD.

### Trails

Visual sprite-based trail effects on rockets. Players can toggle visibility with `sm_rockettrails` and `sm_rocketspritetrails`.

### AntiSnipe

Blocks players from interfering with rockets at long distances using CollisionHook. Requires the CollisionHook extension.

### Menu

In-game admin menu for adjusting dodgeball settings without editing config files.

---

## Developer API

Include `tfdb.inc` in your plugin. Core provides 130+ natives, a rich forward system, and full rocket manipulation.

### Key Natives

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

### Forwards

```sourcepawn
TFDB_OnRocketCreated(int iIndex, int iEntity)
TFDB_OnRocketDeflect(int iIndex, int iEntity, int iOwner)
TFDB_OnRocketSteal(int iIndex, int iOwner, int iTarget, int iStealCount)
TFDB_OnRocketsConfigExecuted(const char[] configFile)
```

### Guardian API

```sourcepawn
#include <tfdb_guardian>

TFDB_IsGuardianActive()      // bool: is a guardian round in progress?
TFDB_GetGuardian()           // int:  guardian client index, or 0
TFDB_IsNextRoundGuardian()   // bool: will next round be guardian?
```

> Full API documentation available in [`tfdb.inc`](TF2Dodgeball/addons/sourcemod/scripting/include/tfdb.inc) and [`tfdb_guardian.inc`](TF2Dodgeball/addons/sourcemod/scripting/include/tfdb_guardian.inc).

---

## Troubleshooting

**Dodgeball not activating** — The gamemode only activates on maps prefixed `tfdb_`, `db_`, or `dbs_` (including Workshop maps). Check that `dodgeball.smx` is loaded with `sm plugins list` in server console.

**Guardian not triggering** — Guardian is automatically blocked when bots are on the server (on RED or BLU teams). Kick all bots first. It's also blocked during FFA rounds and when fewer than 2 eligible players are present. Check `logs/guardian_select.log` for detailed selection diagnostics.

**Guardian abilities not working** — Abilities only unlock after `arena_round_start` fires (when players can move). If you press ability buttons during the pre-round freeze, nothing happens. Check that your `guardian.cfg` has valid ability types and buttons.

**Rockets not homing** — Make sure `general.cfg` has `"behaviour" "homing"` on your rocket class. The `"legacy homing"` mode behaves differently. Check that `dodgeball_enable.cfg` is being exec'd (verify with `sm_cvar tf_dodgeball_enabled`).

**Subplugin not loading** — Make sure the `.smx` file is in `addons/sourcemod/plugins/` (not still in the `Subplugins/` source folder). Check `sm plugins list` and the SourceMod error log for dependency issues.

**TF2Attributes errors** — Make sure both `tf2attributes.smx` (extension) and `gamedata/tf2.attributes.txt` are installed. Guardian's health and ability system requires this. Download from [FlaminSarge/tf2attributes](https://github.com/FlaminSarge/tf2attributes).

---

## Credits

| | |
|---|---|
| **Damizean** | Original YADB |
| **bloody & lizzy** | Updated YADB |
| **ClassicGuzzi** | Dodgeball Redux |
| **BloodyNightmare & Mitchell** | Airblast Prevention |
| **x07x08** | Major Advancements |
| **Silorak** | Current Maintainer |

And the entire SourceMod community for their continued support.

---

## License

GPL v3.0 — see [LICENSE](LICENSE).

<div align="center">

[Report Bug](https://github.com/Silorak/TF2-Dodgeball-Modified/issues) · [Request Feature](https://github.com/Silorak/TF2-Dodgeball-Modified/issues)

</div>
