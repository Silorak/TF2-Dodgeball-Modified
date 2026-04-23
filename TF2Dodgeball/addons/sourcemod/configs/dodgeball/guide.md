# TF2 Dodgeball — Rocket Class Design Guide

Everything you need to know to design rocket classes in `general.cfg`.

Companion to the stripped-down `general.cfg` — that file is meant to be clean, this one explains **why** each field exists and **how** to combine them.

---

## Table of contents

1. [Quick reference](#quick-reference)
2. [How a rocket works](#how-a-rocket-works)
3. [Field reference](#field-reference)
4. [Recipes — designing by archetype](#recipes)
5. [Advanced: dormant features](#advanced-dormant-features)
6. [Troubleshooting](#troubleshooting)

---

## Quick reference

The fields you'll tune 90% of the time, with a one-sentence description.

| Field | What it does | Sane range |
|---|---|---|
| `speed` | Starting rocket speed in Hammer Units/second | 500–1500 |
| `speed increment` | Speed added per deflection | 50–300 |
| `speed limit` | Hard cap on speed (0 = no cap, engine default 3500) | 0, 3000–3500 |
| `turn rate` | How sharply the rocket turns per homing tick | 0.15–0.30 |
| `turn rate increment` | Turn rate added per deflection | 0.01–0.03 |
| `damage` | Base damage on hit | 40–200 |
| `damage increment` | Damage added per deflection | 25–200 |
| `steering control` | Pre-read drag window in **seconds** (auto-converts to ticks for any tickrate) | 0.000–0.150 |
| `bounce control` | Post-bounce blind window in **seconds** | 0.000–0.150 |
| `think interval` | Homing cadence override (0 = per-tick, 0.05 = 20Hz, 0.1 = 10Hz) | 0 or 0.05 |
| `critical chance` | % chance the rocket is a crit | 0–100 |

Everything else is tuned rarely — see full reference below.

---

## How a rocket works

A rocket's life, in order:

1. **Spawn** — `on spawn` fires. Speed, turn rate, damage are set from class defaults.
2. **Fly** — per tick (or per `think interval`), the rocket turns toward its target by `turn rate` degrees.
3. **Player airblasts** — the rocket enters the drag window.
   - For `steering control` seconds, the rocket flies its current direction (blind)
   - At window expiry, the plugin reads the player's **eye angles** and commits the new direction
   - If `control delay > 0`, adds extra blind time after the eye read
4. **Deflect** — `on deflect` fires. Speed, turn rate, damage each increase by their `increment`. Rocket re-targets an enemy.
5. **Wall bounce** (if it hits a surface):
   - Velocity reflects off the surface normal via `v' = v − 2(v·n)n` — pure physics, magnitude preserved
   - Rocket enters **bounce control** blind window — flies bounced direction without homing
   - At window expiry, homing resumes toward target
   - `max bounces` caps how many bounces before the rocket explodes
6. **Target hit or expired** — `on kill` / `on explode` / `on destroyed` fires.

### The two "drag" windows explained

TFDB has TWO separate blind windows:

| Window | When | Field | Typical |
|---|---|---|---|
| **Pre-read drag** | Between airblast and eye-angle read | `steering control` (seconds) | 0.045 (~45ms) |
| **Post-bounce commit** | Between wall bounce and homing resume | `bounce control` (seconds) | 0.045 (~45ms) |
| (Optional) **Post-read commit** | AFTER eye read, before homing | `control delay` (seconds) | 0 |

Most classes leave `control delay` at 0. Use `steering control` for drag feel and `bounce control` for bounce feel.

### Feel guide

`steering control` and `bounce control` are in **seconds**. The plugin converts to real server ticks at config load, so the feel is identical on 66/100/128-tick servers.

| seconds | feel |
|---|---|
| 0.000 | instant — no window |
| 0.015 | very tight |
| 0.030 | tight |
| **0.045** | **master-like (default)** |
| 0.060 | slight weight |
| 0.075 | noticeable drag |
| **0.091** | **heavy drag** |
| 0.106 | sluggish |
| 0.121 | very sluggish |
| 0.150+ | laggy-feeling |

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
| `speed` | float | Initial speed in HU/s. Community range 600–1300. |
| `speed increment` | float | Added per deflection. Higher = faster rallies. |
| `speed limit` | float | Hard cap. 0 = unlimited (but engine caps at 3500 without `max velocity` override in general settings). |
| `turn rate` | float | Radians-ish per homing tick. 0.2 is vanilla-feel; >0.30 is sharp. |
| `turn rate increment` | float | Added per deflection. Rally intensifies. |
| `turn rate limit` | float | Max turn rate allowed (0 = no cap; engine caps at 1.0). |

### Drag / bounce mechanics

| Field | Type | Description |
|---|---|---|
| `steering control` | float seconds | Pre-read drag window. 0 = unflickable (instant). 0.045 = master-like. 0.091 = heavy. Auto-scales across tickrates. |
| `bounce control` | float seconds | Post-bounce blind time before homing resumes. 0 = instant. 0.045 ≈ old behavior. 0.091 = committed. |
| `control delay` | float seconds | Extra blind period AFTER eye-read. Most classes use 0. Set to 0.1 for "legacy feel." |
| `think interval` | float seconds | Homing cadence. 0 = per-tick (smooth, default). 0.05 = 20Hz (Damizean authentic). 0.1 = 10Hz (classic chunky). |
| `max bounces` | int | How many wall bounces before the rocket explodes. 0 = never bounces (explodes on first contact). |
| `bounce ceiling` | float HU | Max bounce arc height above the bounce point. `0` = no clamp (pure physics). `300-500` = typical tune to prevent high-deflect rockets from launching to the map ceiling. Rocket speed is preserved — excess vertical energy is redistributed to horizontal components. Only affects upward bounces (floor/slope); ceiling bounces (rocket hits ceiling) unaffected. |

### Damage

| Field | Type | Description |
|---|---|---|
| `damage` | float | Base damage. Multiplied by 3 if crit. |
| `damage increment` | float | Added per deflection. |
| `critical chance` | int % | 0–100. 100 = always crit. |
| `crit glow stack` | int | Number of fake-crit glow particles stacked on the rocket's trail attachment. `1` = default single glow. `2-10` = denser visual glow (useful for low-damage rockets that want a "charged" look). Clamped to 1–10. Cosmetic only; does not affect damage. |

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
| `beep interval` | float seconds | How often the beep fires. 0 = engine default (~0.5s). |

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
| `custom color` | "R G B" | 0–255 each, e.g. `"255 100 50"` |
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
- `##@owner##` / `##@target##` / `##@dead##` — render with team color

**`on kill` vs `on spawn kill`:**
- `on kill` fires only when the victim was killed by a **deflected** rocket (`@deflections > 0`).
- `on spawn kill` fires only when the victim was killed by an **undeflected** rocket (`@deflections == 0`). Used for "X died to a spawn rocket" messages.
- Both are optional and independent. Leave either blank to suppress that case entirely.

---

## Recipes

Ready-made designs. Drop into `general.cfg` as new class blocks.

### Fast and snappy — "Sniper rocket"

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
    "steering control"       "0.015"      // very tight, unflickable
    "bounce control"         "0"          // instant re-home
    "max bounces"            "5"
    "keep direction"         "1"
    "reset bounces"          "1"
}
```

### Heavy and dodgeable — "Boulder"

Slow, high damage, committed direction.

```
"boulder"
{
    "name"                   "Boulder"
    "behaviour"              "homing"
    "speed"                  "700"
    "speed increment"        "80"
    "speed limit"            "2000"
    "turn rate"              "0.32"       // sharp — intense orbits
    "turn rate increment"    "0.025"
    "damage"                 "150"
    "damage increment"       "100"
    "critical chance"        "50"
    "steering control"       "0.121"      // heavy drag
    "bounce control"         "0.121"      // long commit after bounce
    "max bounces"            "20"
    "keep direction"         "1"
    "reset bounces"          "0"
}
```

### Damizean-authentic — "Legacy"

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
    "steering control"       "0.045"
    "bounce control"         "0.045"
    "max bounces"            "10000"
    "think interval"         "0.05"       // KEY: 20Hz homing, raw turn rate
    "keep direction"         "0"
}
```

### Kill-everyone — "Nuke"

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
    "steering control"       "0.045"
    "bounce control"         "0.045"
    "elevation rate"         "0.1237"
    "elevation limit"        "0.1237"
    "can be stolen"          "1"
    "on kill"                "tf_dodgeball_print [{olive}TFDB{default}] {darkmagenta}☢ NUKE{default} | {lightblue}##@owner## nuked {red}##@dead##"
    "on explode"             "tf_dodgeball_explosion @dead ; tf_dodgeball_shockwave @dead 200 1000 1000 600"
}
```

### Master-tier — "Competitive default"

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
    "steering control"       "0.045"
    "bounce control"         "0.045"
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

Usually `steering control` is too high combined with high `turn rate`. Try:
- Lower `steering control` to 0–0.045
- Lower `turn rate` below 0.25
- Add `control delay "0.05"` (brief post-read pause) — makes the drag window more visible

### "My rocket feels floaty / doesn't home"

Check:
- `think interval` is set correctly (0 for per-tick, 0.05 for Damizean)
- `turn rate` isn't too low (try 0.2+)
- `turn rate limit` isn't capping too aggressively

### "Rocket stops turning after hitting a wall"

You set `keep direction "1"` which is correct behavior for most rockets. If you want post-bounce homing to resume, make sure `bounce control` isn't excessively long.

### "Rocket explodes on first bounce"

`max bounces` is set to 0 or 1. Raise to 10000 for practical infinite bouncing.

### "Speed caps at ~3500"

Engine default. Override with `"max velocity" "5000"` in general settings (note: this is ENGINE cap; `speed limit` is per-CLASS cap).

### "I need to reload config without restarting"

```
sm_reloadplugin dodgeball
```
or just change map — config reloads at map start.

---

## References in the codebase

For the curious / debugging:

- Config parser: `addons/sourcemod/scripting/include/dodgeball_config.inc`
- Rocket spawn + movement: `addons/sourcemod/scripting/include/dodgeball_rockets.inc`
- Bounce physics: `addons/sourcemod/scripting/include/dodgeball_events.inc`
- Public natives: `addons/sourcemod/scripting/include/tfdb.inc`

---

*This guide covers `general.cfg`. For anti-cheat (`tfdb_anticheat.cfg`), PvB (`pvb.cfg`), guardian (`guardian.cfg`), and presets (`presets.cfg`), see the respective cfg files' inline comments or the wiki.*
