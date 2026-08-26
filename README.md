<div align="center">

# TF2 Dodgeball

[![Version](https://img.shields.io/badge/version-2.3.0-blue?style=for-the-badge)](https://github.com/Silorak/TF2-Dodgeball-Modified/releases)
[![SourceMod](https://img.shields.io/badge/SourceMod-1.12-orange?style=for-the-badge)](https://www.sourcemod.net/)
[![License](https://img.shields.io/badge/license-GPL%20v3-green?style=for-the-badge)](LICENSE)

The dodgeball gamemode for TF2 SourceMod servers. Pyros airblast homing rockets at each other. Last team alive wins. Built on years of community work and packaged for modern servers.

[Quick install](#quick-install) · [What's in the box](#whats-in-the-box) · [Subplugins](#subplugins) · [For plugin developers](#for-plugin-developers)

</div>

---

## What's in the box

One required core plugin plus 12 optional modules. Install only what you want.

| Plugin | What it does |
|---|---|
| **Core** (`dodgeball.smx`) | The game itself - rockets, airblast, deflection, bouncing. **Required.** |
| **Guardian** | One player becomes a boss with extra HP and special abilities. Everyone else fights them. **Beta - framework solid, design not fully fleshed out.** |
| **PlayerVsBot** | A game-states bot - config-driven state machine (not AI, no learning/persistence). Fight it 1-vs-1 or spawn a test squad to watch it fight itself. |
| **DeathMatch** | Never-Ending Rounds (NER) - round never ends; deaths stick, sides reshuffle. Uses gamedata detours to block round-end at the engine level. |
| **AntiCheat** | Catches obvious public-tier cheats. **Beta.** |
| **FFA** | Free-for-all mode. Friendly fire on. Coexists with DeathMatch. |
| **Votes** | Players can vote to toggle bouncing rockets, change rocket class, etc. |
| **Menu** | In-game admin menu for tuning rockets without editing files. |
| **Speedometer** | Shows current rocket speed in MPH on the HUD. |
| **Trails** | Visual particle and sprite trails on rockets. |
| **Print** | Pretty chat formatting for kill events. |
| **ExtraEvents** | Adds `on destroyed` event for rockets that explode without killing. |
| **AntiSnipe** | Stops players from interfering with rockets at long range. |

Anything you don't want? Just don't install its `.smx` file - or move it to `plugins/disabled/`.

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

Most servers don't need to touch the configs - defaults are reasonable. If you want to customize:

### `configs/dodgeball/general.cfg`
Defines rocket classes (speed, damage, turn rate, bouncing). Has built-in features for push prevention, target lock and noblock. The shipped file is commented and organized top-down by how often you'd change a setting.

For the full reference with every field explained plus rocket-design recipes (sniper, boulder, nuke, Damizean classic, competitive default), see [`configs/dodgeball/guide.md`](TF2Dodgeball/addons/sourcemod/configs/dodgeball/guide.md).

### Per-map configuration
Want a different setup on `tfdb_stadium_b3`? Create `configs/dodgeball/tfdb_stadium_b3.cfg`. New class and spawner sections are added to the definitions loaded from `general.cfg`. A class section with the same key is a partial overlay: omitted fields inherit from `general.cfg`, while an explicit `0` or empty value clears the corresponding numeric, flag, string, sound, model, particle, or command option. Spawner sections retain their existing replacement behavior.

### Live in-game tuning
Use `sm_tfdb` (admin only) to adjust per-class speed, turn rate, control delay, damage, and related fields. Global drag/bounce timing lives in `general.cfg`.

### Bounded runtime profiling

Root admins can open a short profiling window without enabling permanent debug logging:

| Command | Component |
|---|---|
| `sm_tfdb_profile [seconds]` | Core rocket/frame processing |
| `sm_pvb_profile [seconds]` | PlayerVsBot frame, command, and scan work |
| `sm_ac_profile [seconds]` | AntiCheat command, deflect, and fallback-scan work |

The default window is 15 seconds; values are clamped to 1-30 seconds. Each component uses a hard 100,000-event budget and writes one aggregate `[TFDB-PROFILE]` log line when the window ends or the map/plugin closes it. Fixed workload counters work on every platform. SourceMod profiler events are emitted only when the optional global profiler natives are available and profiling is active. These commands are diagnostic tools, not proof of acceptable latency by themselves; compare representative normal and maximum-load captures.

---

## Subplugins

Click a section to expand details.

<details>
<summary><b>Guardian</b> - 1-vs-all boss mode</summary>

One player per round becomes the Guardian. They get extra HP, a boss health bar, a glow effect and two special abilities you pick from a list. Everyone else fights them.

The Guardian gets picked at random each round, weighted by class. Players can opt out of being chosen with `sm_guardian`. Guardian rounds skip when bots are on the server, when FFA is active or when fewer than 2 players qualify.

> **⚠️ Beta - working but not finished.**
>
> The framework is solid (selection, abilities, opt-out, mutex with other modes) but the design isn't fully fleshed out. Class balance is rough, the ability set is short (5 types) and there's no late-round catch-up logic if the Guardian falls behind. Plays well as a "occasional change of pace" round but isn't tuned for competitive league use yet. Expect class tuning and ability additions in future releases.

**Commands**

| Command | Permission | What it does |
|---|---|---|
| `sm_forceguardian <player> [class]` | CONFIG | Force a specific player to be Guardian next round |
| `sm_gclass <class>` | CONFIG | Set the class for next round's Guardian |
| `sm_rguard` | CONFIG | End the current Guardian round early |
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
<summary><b>PlayerVsBot (PvB)</b> - a game-states bot (state machine, not AI)</summary>

A Pyro dodgeball bot. It's not learning or AI in any real sense - it's a config-driven state machine (perception → state selection → one movement/combat leaf per tick, the same kind of decision tree real-time game bots have used for decades), tuned by hand through `pvb.cfg`, not by anything the bot infers on its own. It doesn't remember individual players or adapt between sessions; there's no persistent storage of any kind. What it does have: a per-map walkable-area scan (built once so it knows where real edges/walls are) and a small amount of per-life state (current target, CQC positioning, wall-slide/evade commitment) that resets every round.

Ships with 4 default classes: Universal, Statue, Midrange, Aggressive. Players can vote which one they want to fight via `sm_votepvb`. Solo players get an instant pick menu when they're alone with the bot.

**Commands**

| Command | Permission | What it does |
|---|---|---|
| `sm_votepvb` / `sm_votepvb` / `sm_votepvb` | Public | Vote for a bot type or vote to disable the bot |
| `sm_botmenu` | Public | Open info menu - stats and current bot |
| `sm_botstats` | Public | Print current bot stats in chat |
| `sm_pvb` / `sm_pvb` | KICK | Admin force-toggle (skips the vote) |
| `sm_botadmin` | KICK | Open the bot administration menu |
| `sm_setbottype <index>` | KICK | Force a specific bot class |
| `sm_botreload` | CONFIG | Reload `pvb.cfg` without changing maps |
| `sm_bot_test <squad\|stop\|list>` | ROOT | Spawn a named developer test squad (`default`, `statue_v_world`, `gang_test`, `all_moves`, `orbit_test`) to fight itself, or stop it |
| `sm_pvb_profile [seconds]` | ROOT | Run a bounded PvB workload/profile window |

**Developer/debug tools** (all ROOT) - for tuning the state machine and nav cache, not everyday use:

| Command | What it does |
|---|---|
| `sm_botdebug [rate]` / `sm_botstop` | Detailed per-tick bot (and real-player) decision logging. Saves to `logs/tfdb_pvb/`. |
| `sm_botdraw` | Toggle live in-world beams showing a bot's wall-scan/move/aim state |
| `sm_navcell [#userid]` | Dump the walkable-area cache grid (floor height + edge distance per cell) around a position |
| `sm_botcfg [#userid\|typeIndex]` | Dump the actual runtime `pvb.cfg` values in effect for a bot class |
| `sm_inspect_bot` / `sm_inspect_rocket` / `sm_inspect_grid` / `sm_inspectall` | Dump raw internal state for debugging |

<details>
<summary><b>Bot configuration trick (capability-by-presence)</b></summary>

You can disable a bot's behavior just by removing the relevant key from `pvb.cfg`. The bot literally loses that ability - not "0% chance", actually gone.

| Remove these keys | Result |
|---|---|
| `orbit_time`, `orbit_max_loops`, `orbit_chance` | Bot never orbits |
| All four `cqc_*_dist` keys | Bot ignores close-quarters distances |
| `idle_chance` | Bot never stands still |
| `idle_chance "100"` (set to 100) | Bot stands still permanently (statue mode) |

</details>

</details>

<details>
<summary><b>AntiCheat</b> - server-side cheat detection (beta)</summary>


The beta AntiCheat creates server-side honeypot rockets that legitimate clients cannot see. An accepted interaction adds to the player's suspicion score after proximity, aim, mouse-movement, multi-Pyro, and real-rocket context filters run.

> **⚠️ Run log-only first.** A honeypot hit is suspicious evidence, not automatic proof. Review data from your own skilled players before enabling punishment.

Accepted detections are written to `addons/sourcemod/logs/honeypot_detections.log`. With `tf2db_honeypot_admin_alerts 1`, every in-game admin with the generic (`b`) flag receives a chat alert and a client-console record. The threshold-crossing alert is highlighted. The override name is `tfdb_honeypot_admin_alert`.

**Primary Cvars** - auto-created in `cfg/sourcemod/tf2db_honeypot_system.cfg`.

| Cvar | Default | What it does |
|---|---:|---|
| `tf2db_honeypot_enabled` | `1` | Enable honeypot detection |
| `tf2db_honeypot_admin_alerts` | `1` | Alert generic-flag admins in chat and client console |
| `tf2db_honeypot_log_enable` | `1` | Write accepted detections to the detailed log |
| `tf2db_honeypot_score_threshold` | `10.0` | Score that produces a highlighted threshold alert |
| `tf2db_honeypot_punish_enable` | `0` | Enable suspect warnings and eventual kick; keep off while baselining |
| `tf2db_honeypot_debug` | `0` | Verbose `[HoneypotSched]` server-console logging |
| `tf2db_honeypot_debug_crit` | `0` | Render debug honeypots as critical |

Use `sm_ac_debug` or `!hp_debug` as an in-game ROOT admin to toggle honeypot boxes and target lines for yourself. Visualization is independent of verbose scheduler logging and cannot be toggled from the dedicated server console.

**Optional SourceTV integration:** `sourcetvmanager.ext` is not required for AntiCheat to load or detect honeypot interactions. When absent, recording-state queries and bookmark metadata are skipped safely; detection, logs, admin alerts, and built-in SourceTV-only visual transmission continue. Current support attaches metadata to an externally active recording-it does not own/start/stop demos. See [`docs/anticheat-design.md`](docs/anticheat-design.md).

</details>

<details>
<summary><b>FFA</b> - free-for-all mode</summary>

Friendly fire on. Rockets target everyone regardless of team. Toggled via vote (`sm_voteffa`) or admin command.

**Coexists with DeathMatch.** Mutually exclusive with Guardian and PvB - those modes assume normal RED/BLU team layout that FFA's neutral mode breaks.

</details>

<details>
<summary><b>DeathMatch</b> - Never-Ending Rounds + Solo queue</summary>

Solves the "small server with empty rounds" problem two ways. Based on Mikah's NER/SOLO Standalone plugin, rewritten for 2.3.0.

- **Never-Ending Rounds (NER)** - when a team would lose, a player from the winning team gets swapped over so the round keeps going.
- **Solo queue** - players can opt out with `sm_solo`. They die immediately and respawn whenever a team needs someone.

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
| `tfdb_dm_respawn_protection` | `2.0` | Damage immunity duration after respawn (seconds) |
| `tfdb_dm_verbose` | `0` | 0 = quiet (errors only). 1 = full NER trace (team/spawn/death/census/bench) |

</details>

</details>

<details>
<summary><b>Votes</b> - let players vote on rocket settings</summary>

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
<summary><b>Speedometer</b> - rocket speed HUD</summary>

Shows current rocket speed in MPH. Players can toggle it for themselves with a cookie that sticks across sessions.

**Commands** (Public)

| Command | Aliases | What it does |
|---|---|---|
| `sm_speedhud` | `sm_shud` | Toggle the speed HUD on/off |

</details>

<details>
<summary><b>Trails</b> - visual rocket trails</summary>

Particle and sprite trails on rockets. Configured per rocket class in `general.cfg` (look for the trail fields - commented out by default; see `guide.md` for enabling).

**Commands** (Public, per-player toggle)

| Command | Aliases | What it does |
|---|---|---|
| `sm_hidetrails` | `sm_hidetrails`, `sm_hidetrails` | Toggle particle trails for yourself |
| `sm_hidesprites` | `sm_hidesprites`, `sm_hidesprites` | Toggle sprite trails for yourself |

</details>

<details>
<summary><b>AntiSnipe</b> - block long-range rocket interference</summary>

Stops players from hitting rockets at very long distance. Requires the CollisionHook extension. If the extension is missing, the plugin warns at load time and falls back to damage-based mode.

</details>

<details>
<summary><b>Menu</b> - in-game admin tuning</summary>

In-game menu for adjusting per-class dodgeball settings without editing config files. Live reload picks up changes made to `general.cfg`; global `drag delay` and `drag grid interval` remain file-level settings.

| Command | Permission | What it does |
|---|---|---|
| `sm_tfdb` | CONFIG | Open the admin menu |

</details>

<details>
<summary><b>ExtraEvents</b> - additional rocket events</summary>

Adds the `on destroyed` event for rockets that explode without killing a player. Required if your rocket class configs use that event in `general.cfg`.

</details>

<details>
<summary><b>Print</b> - pretty chat formatting</summary>

Provides server commands used by rocket event strings (`on kill`, `on spawn kill`) for colored chat messages with player-name substitution. See `guide.md` for the color tag list and the `##@owner##` substitution syntax.

</details>

---

## Troubleshooting

<details>
<summary><b>Plugin not loading or activating</b></summary>

**Dodgeball not activating** - The gamemode only activates on maps prefixed `tfdb_`, `db_` or `dbs_`. Check `dodgeball.smx` is loaded with `sm plugins list` in server console.

**A subplugin not loading** - Make sure its `.smx` is in `addons/sourcemod/plugins/` (not the `Subplugins/` source folder). Check `sm plugins list` and the SourceMod error log.

**TF2Attributes errors** - You need both `tf2attributes.smx` (the extension) AND `gamedata/tf2.attributes.txt`. Guardian needs both. Download from [FlaminSarge/tf2attributes](https://github.com/FlaminSarge/tf2attributes).

</details>

<details>
<summary><b>Rockets misbehaving</b></summary>

**Rockets not homing** - Check `general.cfg` has `"behaviour" "homing"` on your rocket class. Make sure `dodgeball_enable.cfg` is being executed.

**Rockets feel sticky after deflect** - Lower global `"drag delay"` to capture the flick sooner. A small per-class `"control delay"` then holds that sampled direction before homing; try `.030 + .030` or `.030 + .045`. The two values are separate and additive. Drag delay `0` means variable shared-grid timing, not instant capture. Fixed `.060`-`.070` remains the later v1.9.6-like endpoint range. See [`docs/drag-design.md`](docs/drag-design.md) before changing the ownership model.

**Nuke rocket shows as ERROR / red cube** - Your server has `sv_pure 1` blocking the custom model. Either add `models/custom/dodgeball/` to your pure whitelist, or remove the `"model"` field from the nuke class so it uses the default rocket model.

</details>

<details>
<summary><b>Guardian not triggering</b></summary>

Guardian is automatically blocked when:
- Bots are on the server (kick them first with `kickall bot` or via PvB if running)
- FFA is active
- PvB is active
- Fewer than 2 eligible players are present

Check `logs/tfdb_guardian/select.log` for detailed reasons.

**Abilities not working** - They unlock after `arena_round_start` fires (when players can move). Check your `guardian.cfg` has valid ability types and buttons.

</details>

<details>
<summary><b>PvB issues</b></summary>

**Bot replaced by a dumb vanilla bot after map change** - Your server has `tf_bot_quota_mode fill` or `match`. PvB sets it to `normal` automatically but some map configs override it. Add `sm_cvar tf_bot_quota_mode normal` to `cfg/sourcemod/dodgeball_enable.cfg`.

**Players spawning on the bot's team briefly** - Should be fixed in 2.3.0. If it happens, confirm `tfdb_pvb.smx` loaded successfully (check `sm plugins list`).

</details>

<details>
<summary><b>AntiCheat false positives</b></summary>

Run with `tfdb_ac_action 0` (log only) for a few weeks before enabling kick or ban. Review per-player score distributions in `logs/tfdb_ac/`. Raise `tfdb_ac_action_threshold` if pros trip the threshold legitimately. Read the AntiCheat section above for the full deploy guide - this plugin is beta.

</details>

<details>
<summary><b>DeathMatch issues</b></summary>

**`sm_dm` says "cannot activate"** - DeathMatch refuses when Guardian or PvB is active. Disable those first or wait for the round to end.

**Cosmetics wrong color after team swap** - Should be fixed in 2.3.0. If you still see it, a manual respawn resolves it.

**NER feels different in FFA** - By design. FFA neutralizes teams, so NER respawns players in place rather than swapping sides.

</details>

---

## For plugin developers

The rest of this README is for people writing SourceMod plugins on top of TFDB. If you're just running a server, you can stop reading here.


### Public API

Include the relevant header in your plugin:

| Include | What it gives you |
|---|---|
| `<tfdb>` | Core API: 162 natives for rocket manipulation and game state, plus event forwards |
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
    // PvB is running - defer or refuse to activate your mode.
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
    │   ├── tf2.attributes.txt              ← needed for Guardian
    │   └── tfdb_dm.games.txt               ← needed for DeathMatch NER
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
| **Darka (UDL team)** | AntiCheat (honeypot detection system) |
| **BloodyNightmare & Mitchell** | Airblast Prevention (now built into core) |
| **x07x08** | Major advancements (Unified branch, 2.1.0 baseline) |
| **Mikah** | NER/SOLO Standalone plugin (basis of DeathMatch) |
| **Silorak** | Current maintainer (2.3.0+) |

And the entire SourceMod community for keeping TF2 modding alive.

---

## License

GPL v3.0 - see [LICENSE](LICENSE).

<div align="center">

[Report a bug](https://github.com/Silorak/TF2-Dodgeball-Modified/issues) · [Request a feature](https://github.com/Silorak/TF2-Dodgeball-Modified/issues) · [Changelog](CHANGELOG.md)

</div>
