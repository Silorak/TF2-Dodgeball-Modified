# TF2 Dodgeball - Rocket Class Design Guide

Everything you need to know to design rocket classes in `general.cfg`.

Companion to the stripped-down `general.cfg` - that file is meant to be clean, this one explains **why** each field exists and **how** to combine them.

---

## Table of contents

1. [Quick reference](#quick-reference)
2. [How a rocket works](#how-a-rocket-works)
3. [Field reference](#field-reference)
4. [Recipes - designing by archetype](#recipes)
5. [Advanced: dormant features](#advanced-dormant-features)
6. [Troubleshooting](#troubleshooting)

---

## Quick reference

The fields you'll tune 90% of the time, with a one-sentence description.

| Field | What it does | Sane range |
|---|---|---|
| `speed` | Starting rocket speed in Hammer Units/second | 500-1500 |
| `speed increment` | Speed added per deflection | 50-300 |
| `speed limit` | Optional stricter per-class cap; 0 uses global `max velocity` | 0, 3000-3500 |
| `turn rate` | How sharply the rocket turns per homing tick | 0.15-0.30 |
| `turn rate increment` | Turn rate added per deflection | 0.01-0.03 |
| `damage` | Base damage on hit | 40-200 |
| `damage increment` | Damage added per deflection | 25-200 |
| `drag delay` | Global fixed pre-read drag window in **seconds**; 0 selects legacy grid timing | 0 or 0.015-0.150 |
| `drag grid interval` | Global shared bounce-grid interval in **milliseconds** | 10-100 |
| `think interval` | Homing cadence override (0 = per-tick, 0.05 = explicit 20Hz, 0.1 = 10Hz) | 0 or 0.05 |
| `critical chance` | % chance the rocket is a crit | 0-100 |

Everything else is tuned rarely - see full reference below.

---

## How a rocket works

A rocket's life, in order:

1. **Spawn** - `on spawn` fires. Speed, turn rate, damage are set from class defaults.
2. **Fly** - per tick (or per `think interval`), the rocket turns toward its target by `turn rate` degrees.
3. **Player airblasts** - the rocket enters the drag window.
   - For the global `drag delay` duration, the rocket flies its current direction (blind)
   - At window expiry, the plugin reads the player's **eye angles once** and commits that direction
   - The default fixed 0.045s window is consistent; `drag delay 0` opts into the variable legacy grid
   - If per-class `control delay > 0`, it adds extra blind time after the eye read
4. **Deflect** - `on deflect` fires. Speed, turn rate, damage each increase by their `increment`. Rocket re-targets an enemy.
5. **Wall bounce** (if it hits a surface):
   - Velocity reflects off the surface normal via `v' = v − 2(v·n)n` - pure physics, magnitude preserved by default
   - The rocket flies blind until the next shared `drag grid interval` boundary (phase-dependent, practically about one tick through ~100ms)
   - At that boundary, homing resumes toward the target; all bounces share the same clock
   - `max bounces` caps how many bounces before the rocket explodes
6. **Target hit or expired** - `on kill` / `on explode` / `on destroyed` fires.

### The drag and bounce windows explained

TFDB intentionally uses two different schedules:

| Window | When | Field | Typical |
|---|---|---|---|
| **Fixed pre-read drag** | Between airblast and the one-shot eye-angle read | global `drag delay` (seconds) | 0.045 (~45ms) |
| **Grid-gated bounce** | Between surface reflection and homing resume | global `drag grid interval` (milliseconds) | phase-dependent, ~one tick-100ms |
| (Optional) **Post-read commit** | AFTER eye read, before homing | per-class `control delay` (seconds) | 0 |

This split makes player flicks learnable while retaining the unpredictable, synchronized bounce behavior. Setting `drag delay` to 0 restores legacy grid timing for drags without changing bounce behavior.

> **2.3 timing migration:** the former per-class `steering control` and `bounce control` keys are no longer read. Set the global `drag delay` and `drag grid interval` in the `general` section instead. Per-class `control delay` remains separate and still applies after the eye-angle read. These deadlines govern modern `behaviour "homing"`; the explicit `legacy homing` compatibility path retains its coarse ~10Hz processing.

### Feel guide

`drag delay` is real-time seconds. Its deadline is checked every server frame, so it keeps approximately the same real-time feel across tickrates (actual execution rounds up to the next frame).

| seconds | feel |
|---|---|
| 0.000 | legacy shared-grid drag - variable, not instant |
| 0.015 | very tight |
| 0.030 | tight |
| **0.045** | **balanced fixed endpoint (default)** |
| 0.060 | slight weight |
| 0.075 | noticeable drag |
| **0.091** | **heavy drag** |
| 0.106 | sluggish |
| 0.121 | very sluggish |
| 0.150 | maximum - laggy-feeling |

#### v1.9.6 conversion warning

Version 1.9.6's `drag time min` / `drag time max` were not a random range. The normal defaults were `.05/.05`: the first frame that noticed a deflection sampled immediately, then later frames sampled again between the min and `max + one tick`. The final `.05/.05` sample often landed roughly **62-76ms after the actual deflection** at 66-128 tick. That is why the current fixed `.060`-`.070` range-and the later public v2.2 beta's tick-rounded `.074` one-shot setting-can feel closer to old 1.9.6 than a literal modern `.050`. Because the current deadline rounds upward rather than to the nearest tick, use `.070` as the closer current cross-tick-rate starting point instead of copying `.074` blindly.

If by “0.6/0.7” you mean `.060/.070`, those are valid moderate current settings. If an old min/max server literally used `.06/.07`, its repeated late samples and finalization ran later; start the current one-shot comparison near `.075` (or `.090` if matching homing-resume time). Literal `0.600/0.700` means 600-700ms and the current parser clamps either to 150ms. For *less* player drag, move downward through `.030`, `.020`, then `.015`; do not use zero, because zero selects variable grid timing.

The old min/max model continuously reread eye angles and was tick-rate dependent, so it remains deliberately removed rather than being restored just for familiar key names. See [`docs/drag-design.md`](../../../../../docs/drag-design.md) for source citations, conversion tables, rejected designs, and the live-test protocol.

---

## Field reference

### Identity

| Field | Type | Description |
|---|---|---|
| `name` | string | Human-readable name (shown in chat, HUD) |
| `behaviour` | string | `"homing"` (modern, per-tick smooth) or `"legacy homing"` (old-style 10Hz timer). **Stick with `"homing"` unless you want the classic feel.** |

### Movement

| Field | Type | Description |
|---|---|---|
| `speed` | float | Initial speed in HU/s. Community range 600-1300. |
| `speed increment` | float | Added per deflection. Higher = faster rallies. |
| `speed limit` | float | Optional per-class cap. 0 means no stricter class cap; TFDB still pre-clamps to global/server `max velocity`. |
| `turn rate` | float | Radians-ish per homing tick. 0.2 is vanilla-feel; >0.30 is sharp. |
| `turn rate increment` | float | Added per deflection. Rally intensifies. |
| `turn rate limit` | float | Max turn rate allowed (0 = no cap). |

### Drag / bounce mechanics

| Field | Type | Description |
|---|---|---|
| `drag delay` | global float seconds | Fixed pre-read drag window. 0 selects legacy shared-grid timing; 0.045 is the consistent default. |
| `drag grid interval` | global int milliseconds | Shared bounce clock (10-100ms). Bounces always use it; drags use it only when `drag delay` is 0. |
| `control delay` | per-class float seconds | Extra blind period AFTER the eye-angle read. Most classes use 0. |
| `think interval` | float seconds | Homing cadence. 0 = per-tick (smooth, default). 0.05 = explicit 20Hz. 0.1 = 10Hz. Historical lzardy requested 20Hz but SourceMod 1.9 actually dispatched its shared timer at ~10Hz; neither override alone is a complete authenticity preset. |
| `max bounces` | int | How many wall bounces before the rocket explodes. 0 = never bounces (explodes on first contact). |
| `bounce ceiling` | float | Deprecated non-legacy world-up velocity reshaper. Keep `0` for canonical reflection. TF rockets have zero gravity, so this is not a real arc-height ceiling; nonzero values flatten upward floor/slope reflections and redirect magnitude horizontally. |

Bounce speed-loss, blind-displacement, and pseudo-ceiling experiments are documented as noncanonical or rejected. See [`docs/bounce-design.md`](../../../../../docs/bounce-design.md) before proposing another bounce nerf.

Drag min/max, fixed endpoint timing, zero-delay compatibility behavior, and rejected continuous-sampling designs are recorded in [`docs/drag-design.md`](../../../../../docs/drag-design.md).

### Damage

| Field | Type | Description |
|---|---|---|
| `damage` | float | Base damage. Multiplied by 3 if crit. |
| `damage increment` | float | Added per deflection. |
| `critical chance` | int % | 0-100. 100 = always crit. |
| `crit glow stack` | int | Number of fake-crit glow particles stacked on the rocket's trail attachment. `1` = default single glow. `2-10` = denser visual glow (useful for low-damage rockets that want a "charged" look). Clamped to 1-10. Cosmetic only; does not affect damage. |
| `crit glow particle red` | string | Per-class crit glow particle override for Red team. Empty = engine default. |
| `crit glow particle blue` | string | Per-class crit glow particle override for Blue team. Empty = engine default. |
| `crit glow particle neutral` | string | Per-class crit glow particle override for neutral (FFA) rockets. Empty = engine default. |

### Targeting behavior

| Field | Type | Description |
|---|---|---|
| `keep direction` | 0/1 | Keep flight direction after surface contact. |
| `reset bounces` | 0/1 | Reset internal bounce counter on deflect. |
| `neutral rocket` | 0/1 | Ignore team; target anyone. |
| `teamless deflects` | 0/1 | Anyone can deflect (same as neutral but targeting respects team). |
| `can be stolen` | 0/1 | Allows off-target players to steal the rocket by airblasting. |
| `steal team check` | 0/1 | Disallow stealing across teams (pairs with `can be stolen`). |
| `direction to target weight` | int | Weight for target selection based on rocket's current direction. 100 = strong preference for facing target. |

### Sounds

| Field | Type | Description |
|---|---|---|
| `play spawn sound` / `play beep sound` / `play alert sound` | 0/1 | Toggle each sound type. |
| `spawn sound` / `beep sound` / `alert sound` | string paths | Custom sound overrides. Leave empty for default (sentry rocket sounds). |
| `beep interval` | float seconds | How often the beep fires. Key absent from cfg → default 0.5s. Key present with value `0` → literal 0s (beep fires every tick while homing; usually unintended). |

### Visual

| Field | Type | Description |
|---|---|---|
| `model` | path | Custom model. Leave empty for default rocket. |
| `is animated` | 0/1 | Set to 1 if your custom model has animations (sentry rockets do). |

**Trails** (require the `tfdb_trails` subplugin):

| Field | Type | Description |
|---|---|---|
| `trail particle` | string | Particle name (e.g. "superrare_burning1") |
| `trail sprite` | path | VMT path for sprite trail |
| `custom color` | "R G B" | 0-255 each, e.g. `"255 100 50"` |
| `sprite lifetime` | float | Seconds the trail segment lingers |
| `sprite start width` / `sprite end width` | float | Width at head / tail |
| `texture resolution` | float | UV scale |
| `remove particles` / `replace particles` | 0/1 | Nuke engine particles; clone with custom ones. |

### Progression modifiers

| Field | Type | Description |
|---|---|---|
| `no. players modifier` | float | Damage/speed/etc. scaled by player count in server. 0 = no scaling. |
| `no. rockets modifier` | float | Same, scaled by rockets fired since round start. |

### Elevation (optional)

| Field | Type | Description |
|---|---|---|
| `elevate on deflect` | 0/1 | Does the rocket gain altitude after each deflection? |
| `elevation rate` | float | How fast it rises. |
| `elevation limit` | float | Max rise. |

### General section

These live in the `"general"` block of `general.cfg`, not inside rocket class definitions.

| Field | Type | Description |
|---|---|---|
| `music` | 0/1 | Enable round music. |
| `use web player` | 0/1 | Use web-based music player (MOTD panel) instead of sound files. |
| `web player url` | string | URL for the web music player. |
| `round start` | path | Sound file for round start. |
| `round end (win)` | path | Sound file for round win. |
| `round end (lose)` | path | Sound file for round loss. |
| `gameplay` | path | Background gameplay music. |
| `smooth elevation` | 0/1 | Smooth elevation transitions during homing. |
| `drag delay` | float | Seconds before the deflector's eye angles are sampled. `0` = legacy shared-grid timing. Range: 0-0.15. |
| `drag grid interval` | int (ms) | Shared legacy grid interval in ms. Range: 10-100. |
| `max velocity` | float | Engine-wide projectile speed cap. `0` = leave server default. |
| `push prevention` | 0/1 | Prevent players from pushing each other (built into core). |
| `push prevention toggle` | 0/1 | Allow players to toggle push prevention via chat command. |
| `noblock` | 0/1 | Enable NoBlock (players pass through each other). |
| `target lock` | 0/1 | Lock rocket targets at spawn (prevents mid-flight retargeting). |
| `target lock bot only` | 0/1 | Target lock only applies to bots. |
| `disable round freeze` | 0/1 | Let players move during Arena pre-round setup. |

### Events

All optional. Leave empty if not used.

| Event | Fires when | Parameters |
|---|---|---|
| `on spawn` | Rocket is created | `@name` `@rocket` `@owner` `@target` |
| `on deflect` | Rocket is airblasted | + `@deflections` `@speed` `@mphspeed` |
| `on kill` | Rocket kills a player **after at least one deflect** | + `@dead` (the victim) |
| `on spawn kill` | Rocket kills a player **with zero deflects** (undeflected spawn kill) | same as `on kill` |
| `on explode` | Rocket kills + this fires ONCE even if it would hit multiple | same as `on kill` |
| `on no target` | Rocket has no valid target | `@target` becomes the new target |
| `on destroyed` | Rocket explodes without killing | requires `tfdb_extra_events` subplugin |

**Parameters** (all substitute into the command string):

| Token | Type | Meaning |
|---|---|---|
| `@name` | string | Class name (e.g. "Nuke!") |
| `@rocket` | int | Entity index of rocket (-1 for `on destroyed`) |
| `@owner` | int | Player who last deflected |
| `@target` | int | Player the rocket is targeting |
| `@dead` | int | Last player killed |
| `@deflections` | int | Total deflections this rocket |
| `@speed` | float | Speed with limit applied |
| `@mphspeed` | int | Speed in mph, no limit |
| `@capmphspeed` | int | Speed in mph, with limit |
| `@nocapspeed` | float | Raw speed, no limit |
| `@2dspeed` / `@2dnocapspeed` | float | Speed with 2 decimal places |

**Built-in commands** (use them in event strings):

```
tf_dodgeball_explosion <client>
    Huge visual explosion at the client.

tf_dodgeball_shockwave <client> <damage> <force> <radius> <falloff>
    Knockback + damage shockwave.

tf_dodgeball_print <text>
    Print formatted text to chat. Supports {color} tags.
```

Color tags for `tf_dodgeball_print`:
`{default}` `{darkred}` `{red}` `{lightred}` `{pink}` `{orange}` `{yellow}` `{olive}` `{green}` `{lime}` `{lightgreen}` `{cyan}` `{blue}` `{lightblue}` `{purple}` `{darkmagenta}` `{grey}` `{grey2}` `{black}` `{bluegrey}` `{white}`

Player name color substitutions:
- `##@owner##` / `##@target##` / `##@dead##` - render with team color

**`on kill` vs `on spawn kill` - mutually exclusive:**
- `on kill` fires only when the victim was killed by a **deflected** rocket (`@deflections > 0`).
- `on spawn kill` fires only when the victim was killed by an **undeflected** rocket (`@deflections == 0`). Used for "X died to a spawn rocket" messages.
- Exactly ONE of the two fires per kill - never both, never neither (if the matching event key is defined). Each is optional; leave the key blank or omit it to suppress that case.

---

## Recipes

Ready-made designs. Drop into `general.cfg` as new class blocks.

### Fast and snappy - "Sniper rocket"

Fast rocket with tight control. Rewards quick reflexes.

```
"sniper"
{
    "name"                   "Sniper Rocket"
    "behaviour"              "homing"
    "speed"                  "1200"
    "speed increment"        "200"
    "speed limit"            "3000"
    "turn rate"              "0.15"
    "turn rate increment"    "0.015"
    "damage"                 "60"
    "damage increment"       "40"
    "critical chance"        "100"
    "max bounces"            "5"
    "keep direction"         "1"
    "reset bounces"          "1"
}
```

### Heavy and dodgeable - "Boulder"

Slow, high damage, committed direction.

```
"boulder"
{
    "name"                   "Boulder"
    "behaviour"              "homing"
    "speed"                  "700"
    "speed increment"        "80"
    "speed limit"            "2000"
    "turn rate"              "0.32"       // sharp - intense orbits
    "turn rate increment"    "0.025"
    "damage"                 "150"
    "damage increment"       "100"
    "critical chance"        "50"
    "max bounces"            "20"
    "keep direction"         "1"
    "reset bounces"          "0"
}
```

### Damizean-authentic - "Legacy"

20Hz think cadence. Classic 2010s YADB feel.

```
"legacy"
{
    "name"                   "Damizean Legacy"
    "behaviour"              "homing"
    "speed"                  "1100"
    "speed increment"        "70"
    "turn rate"              "0.233"
    "turn rate increment"    "0.0275"
    "damage"                 "100"
    "damage increment"       "50"
    "critical chance"        "10"
    "max bounces"            "10000"
    "think interval"         "0.05"       // KEY: 20Hz homing, raw turn rate
    "keep direction"         "0"
}
```

### Kill-everyone - "Nuke"

Single-hit lethal. Slow but relentless.

```
"nuke"
{
    "name"                   "Nuke!"
    "behaviour"              "homing"
    "model"                  "models/custom/dodgeball/nuke/nuke.mdl"   // optional
    "is animated"            "1"
    "speed"                  "550"
    "speed increment"        "100"
    "turn rate"              "0.233"
    "turn rate increment"    "0.0275"
    "damage"                 "200"
    "damage increment"       "200"
    "critical chance"        "100"
    "max bounces"            "0"          // no bounces; explodes on impact
    "elevation rate"         "0.1237"
    "elevation limit"        "0.1237"
    "can be stolen"          "1"
    "on kill"                "tf_dodgeball_print [{olive}TFDB{default}] {darkmagenta}☢ NUKE{default} | {lightblue}##@owner## nuked {red}##@dead##"
    "on explode"             "tf_dodgeball_explosion @dead ; tf_dodgeball_shockwave @dead 200 1000 1000 600"
}
```

### Master-tier - "Competitive default"

The community-standard middle ground. What `common` is set to in shipped config.

```
"common"
{
    "name"                   "Homing Rocket"
    "behaviour"              "homing"
    "speed"                  "975"
    "speed increment"        "260"
    "turn rate"              "0.310"
    "turn rate increment"    "0.019"
    "damage"                 "40"
    "damage increment"       "25"
    "critical chance"        "100"
    "max bounces"            "10000"
    "keep direction"         "1"
    "reset bounces"          "1"
}
```

---

## Advanced: dormant features

These are in the code but off by default. Enable only if you know what you're doing.

### `orbit coefficient` (experimental)

Replaces `turn rate` + `turn rate increment` with a single `orbit tightness` value. The plugin computes turn rate dynamically to keep orbit radius constant across speeds.

Enable:
```
"orbit coefficient"  "1"
```

In class:
```
"orbit tightness"   "0.3"   // 0.1 = loose, 1.0 = tight, 0.3 = classic feel
```

Not recommended unless you want uniform orbit geometry regardless of rocket speed.

### `target speed scaling` (experimental)

Replaces `speed increment` with `max speed` + `max deflections`. Plugin computes increment to reach max speed evenly over N deflections.

Enable:
```
"target speed scaling"  "1"
```

In class:
```
"max speed"         "3500"
"max deflections"   "40"
```

Useful for classes with a target "endgame speed" rather than a per-deflect increment.

### `smooth elevation`

Makes elevation ramp continuously per-frame instead of stepped ~10Hz. Visual change only.

```
"smooth elevation"  "1"
```

---

## Troubleshooting

### "My rocket is uncatchable"

Usually the global `drag delay` is too long combined with a high per-class `turn rate`. Try:
- Lower `drag delay` toward 0.030-0.045 (do not use 0 unless you want legacy grid randomness)
- Lower `turn rate` below 0.25
- Keep `control delay` at 0 unless you intentionally want an extra post-read pause

### "My rocket feels floaty / doesn't home"

Check:
- `think interval` is set correctly (0 for per-tick; nonzero only for an intentional coarse cadence)
- `turn rate` isn't too low (try 0.2+)
- `turn rate limit` isn't capping too aggressively

### "Rocket stops turning after hitting a wall"

`keep direction "1"` is normal for most rockets. Bounce homing resumes at the next shared grid boundary; lower the global `drag grid interval` if that blind flight is too long.

### "Rocket explodes on first bounce"

`max bounces` is set to 0 or 1. Raise to 10000 for practical infinite bouncing.

### "Speed caps at ~3500"

The global `max velocity` is both the engine cap and TFDB's internal pre-write cap. Override it with `"max velocity" "5000"`; `speed limit` can impose a stricter per-class cap.

### "I need to reload config without restarting"

```
sm_reloadplugin dodgeball
```
or just change map - config reloads at map start.

---

## References in the codebase

For the curious / debugging:

- Config parser: `addons/sourcemod/scripting/include/dodgeball_config.inc`
- Rocket spawn + movement: `addons/sourcemod/scripting/include/dodgeball_rockets.inc`
- Bounce physics: `addons/sourcemod/scripting/include/dodgeball_events.inc`
- Public natives: `addons/sourcemod/scripting/include/tfdb.inc`

---

*This guide covers `general.cfg` (rocket classes + general section). For PvB (`pvb.cfg`), Guardian (`guardian.cfg`), presets (`presets.cfg`), and presets (`presets.cfg`), see the respective cfg files' inline comments or the wiki.*
