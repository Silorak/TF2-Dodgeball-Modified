<div align="center">

# TF2 Dodgeball

[![Version](https://img.shields.io/badge/version-2.2.0-blue?style=for-the-badge)](https://github.com/Silorak/TF2-Dodgeball-Modified/releases)
[![SourceMod](https://img.shields.io/badge/SourceMod-1.12-orange?style=for-the-badge)](https://www.sourcemod.net/)
[![License](https://img.shields.io/badge/license-GPL%20v3-green?style=for-the-badge)](LICENSE)

The dodgeball gamemode for TF2 SourceMod servers. Pyros airblast homing rockets at each other. Last team alive wins. Built on years of community work and packaged for modern servers.

[Quick install](#quick-install) · [What's in the box](#whats-in-the-box) · [Subplugins](#subplugins) · [For plugin developers](#for-plugin-developers)

</div>

---

## What's in the box

One required core plugin plus 13 optional modules. Install only what you want.

| Plugin | What it does |
|---|---|
| **Core** (`dodgeball.smx`) | The game itself — rockets, airblast, deflection, bouncing. **Required.** |
| **Guardian** | One player becomes a boss with extra HP and special abilities. Everyone else fights them. |
| **PlayerVsBot** | An AI bot that learns as it plays. You can fight it 1-vs-1 or watch bots train each other. |
| **DeathMatch** | Keeps small servers alive — when a team would lose, swap a player or respawn a soloer. |
| **AntiCheat** | Catches obvious public-tier cheats. **Beta — read the warning before enabling.** |
| **FFA** | Free-for-all mode. Friendly fire on. Coexists with DeathMatch. |
| **Votes** | Players can vote to toggle bouncing rockets, change rocket class, etc. |
| **Menu** | In-game admin menu for tuning rockets without editing files. |
| **Speedometer** | Shows current rocket speed in MPH on the HUD. |
| **Trails** | Visual particle and sprite trails on rockets. |
| **Print** | Pretty chat formatting for kill events. |
| **ExtraEvents** | Adds `on destroyed` event for rockets that explode without killing. |
| **AntiSnipe** | Stops players from interfering with rockets at long range. |

Anything you don't want? Just don't install its `.smx` file — or move it to `plugins/disabled/`.

---

## What 2.2.0 brings

- **4 new modes**: Guardian, PlayerVsBot, DeathMatch and a beta cheat detector.
- **Rockets feel more consistent across server tickrates** (66 / 100 / 128).
- **Bouncing simplified** — pure physics reflection plus an optional height clamp.
- **Crit glow customization** — stack 1-10 fake-crit particles per class. Override the particle name per team.
- **Modes don't fight each other** — Guardian / PvB / DeathMatch refuse to run together (they all play with team layout). FFA pairs with DeathMatch only.
- **Three old plugins built into the core** (Airblast Prevention, Anti-Switch, NoBlock). Same settings, just live in `general.cfg` now.

For the full release notes including upgrade instructions from 2.1.0, see [CHANGELOG.md](CHANGELOG.md).

---

## Quick install

### What you need

- **SourceMod 1.12+** with **MetaMod:Source**
- Plus dependencies if you use specific modules:
   - Guardian needs **[TF2Attributes](https://github.com/FlaminSarge/tf2attributes)**
   - AntiSnipe needs **[CollisionHook](https://forums.alliedmods.net/showthread.php?t=197815)**

### Install in 4 steps

1. Download the latest release from the [Releases page](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest)
2. Extract the `TF2Dodgeball/` folder into your server's `tf/` directory (merge with existing folders)
3. If you're using Guardian or AntiSnipe, install the matching extension from the links above
4. Restart the server or change to a map prefixed `tfdb_`, `db_` or `dbs_`

The gamemode activates automatically on dodgeball-prefixed maps. Workshop maps are supported.

### Removing a subplugin you don't want

Move its `.smx` file to `addons/sourcemod/plugins/disabled/`. Nothing else needs to change.

---

## Configuration basics

Most servers don't need to touch the configs — defaults are reasonable. If you want to customize:

### `configs/dodgeball/general.cfg`
Defines rocket classes (speed, damage, turn rate, bouncing). Has built-in features for push prevention, target lock and noblock. The shipped file is commented and organized top-down by how often you'd change a setting.

For the full reference with every field explained plus rocket-design recipes (sniper, boulder, nuke, Damizean classic, competitive default), see [`configs/dodgeball/guide.md`](TF2Dodgeball/addons/sourcemod/configs/dodgeball/guide.md).

### Per-map overrides
Want a different setup on `tfdb_stadium_b3`? Create `configs/dodgeball/tfdb_stadium_b3.cfg` and override only the values you want changed. Everything else inherits from `general.cfg`.

### Live in-game tuning
Use `sm_tfdb` (admin only) to adjust speed / turn rate / drag / damage etc. without editing files. Changes apply on the next rocket spawn.

---

## Subplugins

Click a section to expand details.

<details>
<summary><b>Guardian</b> — 1-vs-all boss mode</summary>

One player per round becomes the Guardian. They get extra HP, a boss health bar, a glow effect and two special abilities you pick from a list. Everyone else fights them.

The Guardian gets picked at random each round, weighted by class. Players can opt out of being chosen with `sm_guardian`. Guardian rounds skip when bots are on the server, when FFA is active or when fewer than 2 players qualify.

**Commands**

| Command | Permission | What it does |
|---|---|---|
| `sm_forceguardian <player> [class]` | CONFIG | Force a specific player to be Guardian next round |
| `sm_guardianclass <class>` | CONFIG | Set the class for next round's Guardian |
| `sm_removeguardian` | CONFIG | End the current Guardian round early |
| `sm_guardian` | Public | Toggle whether you can be picked |

**Configured via** `configs/dodgeball/guardian.cfg`. You define classes (HP, weight, abilities) and the plugin picks one each round.

**Available abilities:** `rage` (airblast boost), `sprint` (speed), `charge` (faster speed), `pounce` (jump forward), `slow` (slow nearby enemies in a ring).

**Available buttons:** `TAUNT` (G), `RELOAD` (R), `ATTACK3` (middle mouse), `USE` (H).

<details>
<summary><b>Example class config</b></summary>

```
"berserker"
{
    "name"       "Berserker"
    "health"     "5000"
    "weight"     "100"          // higher = more likely to be picked

    "ability_1"
    {
        "type"     "pounce"
        "button"   "ATTACK3"
        "cooldown" "10.0"
        "duration" "5.0"
        "arg1"     "1200.0"    // forward force
        "arg2"     "600.0"     // upward force
        "particle" "utaunt_multicurse_teamcolor_blue"
    }

    "ability_2"
    {
        "type"     "slow"
        "button"   "RELOAD"
        "cooldown" "15.0"
        "duration" "10.0"
        "arg1"     "500.0"     // radius
        "arg2"     "50.0"      // 50% slow
        "particle" "utaunt_hands_teamcolor_blue"
    }
}
```

</details>

</details>

<details>
<summary><b>PlayerVsBot (PvB)</b> — AI bot that learns as it plays</summary>

A Pyro dodgeball bot. It actually gets better the more it plays — remembers your tricks, adapts its reactions, learns where it tends to die on each map.

Ships with 4 default classes: Universal, Statue, Midrange, Aggressive. Players can vote which one they want to fight via `sm_votepvb`. Solo players get an instant pick menu when they're alone with the bot.

The bot stores everything it learns in a SQLite database — you can reset it with `sm_resetbrain` whenever. Server crashes don't lose much because the bot saves what it learned every round.

**Commands**

| Command | Permission | What it does |
|---|---|---|
| `sm_votepvb` / `sm_votebot` / `sm_botvote` | Public | Vote for a bot type or vote to disable the bot |
| `sm_botmenu` | Public | Open info menu — stats and current bot |
| `sm_botstats` | Public | Print current bot stats in chat |
| `sm_pvb` / `sm_spawnpvb` | KICK | Admin force-toggle (skips the vote) |
| `sm_setbottype <index>` | KICK | Force a specific bot class |
| `sm_reloadbotcfg` | CONFIG | Reload `pvb.cfg` without changing maps |
| `sm_trainbots` | ROOT | Spawn training bots (bots fight each other; humans can join any team or watch) |
| `sm_stoptraining` | ROOT | End training mode and remove the bots |
| `sm_resetbrain` | ROOT | Wipe everything the bot has learned |

**Brain inspection** (all ROOT) — peek at what the bot has learned:

| Command | What it does |
|---|---|
| `sm_brainstats` | Quick summary of how much the bot has learned so far |
| `sm_brainshow <key>` | Show the bot's preferences for one specific situation |
| `sm_brainopponent <player>` | Dump everything the bot has learned about one player |
| `sm_brainheatmap [class]` | Save a danger map to a log file — see where bots tend to die |
| `sm_botdebug [rate]` / `sm_stopdebug` | Detailed bot decision logging (very verbose). Saves to `logs/tfdb_pvb/`. |

<details>
<summary><b>Bot configuration trick (capability-by-presence)</b></summary>

You can disable a bot's behavior just by removing the relevant key from `pvb.cfg`. The bot literally loses that ability — not "0% chance", actually gone.

| Remove these keys | Result |
|---|---|
| `orbit_time`, `orbit_max_loops`, `orbit_chance` | Bot never orbits |
| `evade_chance` | Bot never jumps or crouches to evade |
| All four `cqc_*_dist` keys | Bot ignores close-quarters distances |
| `idle_chance` | Bot never stands still |
| `idle_chance "100"` (set to 100) | Bot stands still permanently (statue mode) |

</details>

</details>

<details>
<summary><b>AntiCheat</b> — server-side cheat detection (beta)</summary>

Catches obvious public-tier cheats by watching for impossible aim angles, robotic timing patterns and silent-aim signatures. Three modes: log only, kick or ban. Default is log only.

> **⚠️ Honest warning — this plugin is beta.**
>
> It hasn't been tested at scale. We tuned it on a small group of skilled testers and three detectors (SnapAim, ConsistentTiming, PerfectStreak) had to be zeroed because they kept flagging legit competitive players. The remaining detectors carry varying false-positive risk against high-skill players.
>
> **Until your server has weeks of log-only data covering your actual playerbase, do not enable kick or ban actions.** Run `tfdb_ac_action 0`, review the logs in `addons/sourcemod/logs/tfdb_ac/`, see which detections fire on your trusted regulars, raise thresholds or zero weights for any detector that flags them, then move to kick. Ban only after kick has been clean for weeks.
>
> Set `tfdb_ac_immunity_flag` to a flag your trusted players hold so they don't trip detection while you're collecting data.
>
> This catches obvious cheats. It is not a polished anti-cheat product. Expect to tune it.

**Detection categories:**

| Detection | Catches | Default weight |
|---|---|---|
| `AntiAim` | Pitch outside ±89° (engine-impossible) | 5 |
| `ReactTimeFloor` | Deflect below 80ms reaction (with 3-streak gate) | 5 |
| `OneTickM2` | Airblast held for exactly 1 tick × 3 in a row | 6 |
| `DragSnapback` | Snap-airblast-snap-back pattern | 4 |
| `AirblastFacing` | 3 deflects in a row while not facing the rocket | 4 |
| `SnapAim` | (zero weight, logs only — too FP-prone) | 0 |

**Cvars** — auto-created in `cfg/sourcemod/tfdb_anticheat.cfg`.

| Cvar | Default | What it does |
|---|---|---|
| `tfdb_ac_enabled` | `1` | Master toggle |
| `tfdb_ac_action` | `1` | `0` log only, `1` kick, `2` ban |
| `tfdb_ac_action_threshold` | `60` | Score needed before action fires |
| `tfdb_ac_react_floor_ms` | `80` | Reaction-time floor in milliseconds |
| `tfdb_ac_ban_duration` | `1440` | Ban length in minutes (`0` = permanent) |
| `tfdb_ac_immunity_flag` | `b` | Admin flag granting immunity |
| `tfdb_ac_admin_hud` | `1` | Show live scores to admins |
| `tfdb_ac_log_level` | `1` | `0` silent, `1` detections, `2` verbose, `3` debug |

**Commands**

| Command | Permission | What it does |
|---|---|---|
| `sm_ac_status` | BAN | Show live suspicion scores for all players |
| `sm_ac_reset <player>` | ROOT | Reset detection counters for one player |
| `sm_ac_debug_player <player>` | ROOT | Toggle detailed CSV logging for one player |

Companion plugin `tfdb_ac_debug.smx` provides per-client logging for triage.

</details>

<details>
<summary><b>FFA</b> — free-for-all mode</summary>

Friendly fire on. Rockets target everyone regardless of team. Toggled via vote (`sm_voteffa`) or admin command.

**Coexists with DeathMatch.** Mutually exclusive with Guardian and PvB — those modes assume normal RED/BLU team layout that FFA's neutral mode breaks.

</details>

<details>
<summary><b>DeathMatch</b> — Never-Ending Rounds + Solo queue</summary>

Solves the "small server with empty rounds" problem two ways. Based on Mikah's NER/SOLO Standalone plugin, rewritten for 2.2.0.

- **Never-Ending Rounds (NER)** — when a team would lose, a player from the winning team gets swapped over so the round keeps going.
- **Solo queue** — players can opt out with `sm_solo`. They die immediately and respawn whenever a team needs someone.

After any DeathMatch respawn, players get a brief damage-immunity window. A horn plays to signal it.

**Coexists with FFA.** Mutually exclusive with Guardian and PvB.

**Commands**

| Command | Permission | What it does |
|---|---|---|
| `sm_solo` | Public | Toggle solo (join or leave the queue) |
| `sm_votedm` | Public | Vote to toggle DeathMatch |
| `sm_dm` | CONFIG | Admin toggle (skips vote) |

<details>
<summary><b>Cvars</b></summary>

Auto-created in `cfg/sourcemod/tfdb_deathmatch.cfg`.

| Cvar | Default | What it does |
|---|---|---|
| `tfdb_dm_ner_enabled` | `1` | Enable NER feature |
| `tfdb_dm_ner_force` | `0` | Force NER on (cannot be disabled by vote or admin) |
| `tfdb_dm_ner_force_start` | `0` | Turn NER on at map start |
| `tfdb_dm_ner_vote_timeout` | `120` | NER vote cooldown in seconds |
| `tfdb_dm_solo_enabled` | `1` | Enable solo queue |
| `tfdb_dm_solo_priority` | `1` | Respawn soloers before swapping alive players |
| `tfdb_dm_horn_volume` | `0.5` | Volume of the respawn horn (0–1) |
| `tfdb_dm_respawn_protection` | `2.0` | Damage immunity duration after respawn (seconds) |

</details>

</details>

<details>
<summary><b>Votes</b> — let players vote on rocket settings</summary>

Players can vote to toggle features mid-match. Each vote command has a 10-second per-player cooldown so spammers can't chain votes.

**Commands** (all Public)

| Command | Aliases | What it does |
|---|---|---|
| `sm_vrb` | `sm_votebounce` | Vote to toggle bouncing rockets |
| `sm_vrc` | `sm_voteclass` | Vote to change the rocket class |
| `sm_vrcount` | `sm_votecount` | Vote to change how many rockets spawn at once |
| `sm_vrp` | `sm_votepreset` | Vote for a preset from `presets.cfg` |

</details>

<details>
<summary><b>Speedometer</b> — rocket speed HUD</summary>

Shows current rocket speed in MPH. Players can toggle it for themselves with a cookie that sticks across sessions.

**Commands** (Public)

| Command | Aliases | What it does |
|---|---|---|
| `sm_speedhud` | `sm_shud` | Toggle the speed HUD on/off |

</details>

<details>
<summary><b>Trails</b> — visual rocket trails</summary>

Particle and sprite trails on rockets. Configured per rocket class in `general.cfg` (look for the trail fields — commented out by default; see `guide.md` for enabling).

**Commands** (Public, per-player toggle)

| Command | Aliases | What it does |
|---|---|---|
| `sm_rockettrails` | `sm_hidetrails`, `sm_toggletrails` | Toggle particle trails for yourself |
| `sm_rocketsprites` | `sm_hidesprites`, `sm_togglesprites` | Toggle sprite trails for yourself |

</details>

<details>
<summary><b>AntiSnipe</b> — block long-range rocket interference</summary>

Stops players from hitting rockets at very long distance. Requires the CollisionHook extension. If the extension is missing, the plugin warns at load time and falls back to damage-based mode.

</details>

<details>
<summary><b>Menu</b> — in-game admin tuning</summary>

In-game menu for adjusting dodgeball settings without editing config files. Live reload picks up changes you make to `general.cfg` on disk. Per-class feel knobs (speed, turn rate, damage, drag, bounce) are tunable live and apply on the next rocket spawn.

| Command | Permission | What it does |
|---|---|---|
| `sm_tfdb` | CONFIG | Open the admin menu |

</details>

<details>
<summary><b>ExtraEvents</b> — additional rocket events</summary>

Adds the `on destroyed` event for rockets that explode without killing a player. Required if your rocket class configs use that event in `general.cfg`.

</details>

<details>
<summary><b>Print</b> — pretty chat formatting</summary>

Provides server commands used by rocket event strings (`on kill`, `on spawn kill`) for colored chat messages with player-name substitution. See `guide.md` for the color tag list and the `##@owner##` substitution syntax.

</details>

---

## Troubleshooting

<details>
<summary><b>Plugin not loading or activating</b></summary>

**Dodgeball not activating** — The gamemode only activates on maps prefixed `tfdb_`, `db_` or `dbs_`. Check `dodgeball.smx` is loaded with `sm plugins list` in server console.

**A subplugin not loading** — Make sure its `.smx` is in `addons/sourcemod/plugins/` (not the `Subplugins/` source folder). Check `sm plugins list` and the SourceMod error log.

**TF2Attributes errors** — You need both `tf2attributes.smx` (the extension) AND `gamedata/tf2.attributes.txt`. Guardian needs both. Download from [FlaminSarge/tf2attributes](https://github.com/FlaminSarge/tf2attributes).

</details>

<details>
<summary><b>Rockets misbehaving</b></summary>

**Rockets not homing** — Check `general.cfg` has `"behaviour" "homing"` on your rocket class. Make sure `dodgeball_enable.cfg` is being executed.

**Rockets feel sticky after deflect** — Lower `"steering control"` (defaults around 0.045 seconds). Set `"control delay"` to `0` for immediate homing after deflect.

**Nuke rocket shows as ERROR / red cube** — Your server has `sv_pure 1` blocking the custom model. Either add `models/custom/dodgeball/` to your pure whitelist, or remove the `"model"` field from the nuke class so it uses the default rocket model.

</details>

<details>
<summary><b>Guardian not triggering</b></summary>

Guardian is automatically blocked when:
- Bots are on the server (kick them first with `kickall bot` or via PvB if running)
- FFA is active
- PvB is active
- Fewer than 2 eligible players are present

Check `logs/tfdb_guardian/select.log` for detailed reasons.

**Abilities not working** — They unlock after `arena_round_start` fires (when players can move). Check your `guardian.cfg` has valid ability types and buttons.

</details>

<details>
<summary><b>PvB issues</b></summary>

**Bot replaced by a dumb vanilla bot after map change** — Your server has `tf_bot_quota_mode fill` or `match`. PvB sets it to `normal` automatically but some map configs override it. Add `sm_cvar tf_bot_quota_mode normal` to `cfg/sourcemod/dodgeball_enable.cfg`.

**Players spawning on the bot's team briefly** — Should be fixed in 2.2.0. If it happens, confirm `tfdb_pvb.smx` loaded successfully (check `sm plugins list`).

</details>

<details>
<summary><b>AntiCheat false positives</b></summary>

Run with `tfdb_ac_action 0` (log only) for a few weeks before enabling kick or ban. Review per-player score distributions in `logs/tfdb_ac/`. Raise `tfdb_ac_action_threshold` if pros trip the threshold legitimately. Read the AntiCheat section above for the full deploy guide — this plugin is beta.

</details>

<details>
<summary><b>DeathMatch issues</b></summary>

**`sm_dm` says "cannot activate"** — DeathMatch refuses when Guardian or PvB is active. Disable those first or wait for the round to end.

**Cosmetics wrong color after team swap** — Should be fixed in 2.2.0. If you still see it, a manual respawn resolves it.

**NER feels different in FFA** — By design. FFA neutralizes teams, so NER respawns players in place rather than swapping sides.

</details>

---

## For plugin developers

The rest of this README is for people writing SourceMod plugins on top of TFDB. If you're just running a server, you can stop reading here.

### Public API

Include the relevant header in your plugin:

| Include | What it gives you |
|---|---|
| `<tfdb>` | Core API: 130+ natives for rocket manipulation, 11 forwards for events |
| `<tfdb_guardian>` | State-query natives for Guardian |
| `<tfdb_pvb>` | State-query natives for PlayerVsBot |
| `<tfdb_deathmatch>` | State-query natives for DeathMatch |
| `<tfdb_ffa>` | State-query natives for FFA |
| `<tfdbtrails>` | API for the Trails subplugin |
| `<tfdb_clientcheck>` | Six client-state predicate stocks (real human, playing, alive, spectator, bot, etc.) |

<details>
<summary><b>Core API quick reference</b></summary>

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

### Working with the optional natives

Guardian, PvB, DeathMatch, FFA all expose state-query natives so other subplugins can refuse to activate when they would conflict. Your plugin compiles cleanly whether the partner is installed or not.

```sourcepawn
if (LibraryExists("tfdb_pvb") &&
    GetFeatureStatus(FeatureType_Native, "TFDB_IsPvBActive") == FeatureStatus_Available &&
    TFDB_IsPvBActive())
{
    // PvB is running — defer or refuse to activate your mode.
}
```

Register your own library with `RegPluginLibrary("your_name")` so partners can check for you the same way.

### Compile order

If you're building from source: compile `dodgeball.sp` first (it generates the natives in `tfdb.inc`). Then compile subplugins in any order. Subplugin source lives in `Subplugins/<name>/scripting/`.

### File layout (for reference)

<details>
<summary><b>Click to expand</b></summary>

```
tf/
├── cfg/sourcemod/
│   ├── dodgeball_enable.cfg                ← runs when a dodgeball map loads
│   ├── dodgeball_disable.cfg               ← runs when leaving a dodgeball map
│   ├── dodgeball_ffa_enable.cfg            ← runs when FFA activates
│   └── dodgeball_ffa_disable.cfg           ← runs when FFA turns off
└── addons/sourcemod/
    ├── plugins/
    │   ├── dodgeball.smx                   ← required (core)
    │   ├── tfdb_guardian.smx               ← optional
    │   ├── tfdb_pvb.smx                    ← optional
    │   ├── tfdb_deathmatch.smx             ← optional
    │   ├── tfdb_anti_cheat.smx             ← optional
    │   ├── tfdb_ac_debug.smx               ← optional companion to AntiCheat
    │   ├── tfdb_ffa.smx                    ← optional
    │   ├── tfdb_votes.smx                  ← optional
    │   ├── tfdb_menu.smx                   ← optional
    │   ├── tfdb_speedhud.smx               ← optional
    │   ├── tfdb_trails.smx                 ← optional
    │   ├── tfdb_print.smx                  ← optional
    │   ├── tfdb_extra_events.smx           ← optional
    │   └── tfdb_anti_snipe.smx             ← optional
    ├── configs/dodgeball/
    │   ├── general.cfg                     ← main rocket and game config
    │   ├── guide.md                        ← full field reference and recipes
    │   ├── guardian.cfg                    ← Guardian classes and abilities
    │   ├── pvb.cfg                         ← PvB classes and tuning
    │   ├── presets.cfg                     ← rocket class presets
    │   └── tfdb_<mapname>.cfg              ← per-map overrides (create as needed)
    ├── data/sqlite/
    │   └── tfdb_pvb.sq3                    ← PvB persistent learning (auto-created)
    ├── logs/
    │   ├── tfdb_ac/                        ← AntiCheat detection logs
    │   ├── tfdb_guardian/                  ← Guardian round + selection logs
    │   └── tfdb_pvb/                       ← PvB heatmap dumps and decision traces
    ├── gamedata/
    │   └── tf2.attributes.txt              ← needed for Guardian
    ├── translations/
    │   └── tfdb.phrases.txt                ← all chat strings, edit for translations
    └── scripting/
        ├── include/                        ← .inc headers (public API)
        └── dodgeball.sp                    ← core source
```

</details>

---

## Credits

| | |
|---|---|
| **Damizean** | Original YADP |
| **bloody & lizzy** | YADP maintenance |
| **ClassicGuzzi** | Dodgeball Redux |
| **Oracle team** | DB_Reborn (bounce reflection formula) |
| **BloodyNightmare & Mitchell** | Airblast Prevention (now built into core) |
| **x07x08** | Major advancements (Unified branch, 2.1.0 baseline) |
| **Mikah** | NER/SOLO Standalone plugin (basis of DeathMatch) |
| **Silorak** | Current maintainer (2.2.0+) |

And the entire SourceMod community for keeping TF2 modding alive.

---

## License

GPL v3.0 — see [LICENSE](LICENSE).

<div align="center">

[Report a bug](https://github.com/Silorak/TF2-Dodgeball-Modified/issues) · [Request a feature](https://github.com/Silorak/TF2-Dodgeball-Modified/issues) · [Changelog](CHANGELOG.md)

</div>
