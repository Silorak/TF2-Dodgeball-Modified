<div align="center">

# 🚀 TF2 Dodgeball Modified

[![GitHub release](https://img.shields.io/github/v/release/Silorak/TF2-Dodgeball-Modified?style=for-the-badge&logo=github&color=blue)](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest)
[![GitHub issues](https://img.shields.io/github/issues/Silorak/TF2-Dodgeball-Modified?style=for-the-badge&logo=github)](https://github.com/Silorak/TF2-Dodgeball-Modified/issues)
[![License](https://img.shields.io/github/license/Silorak/TF2-Dodgeball-Modified?style=for-the-badge)](LICENSE)

**The definitive TF2 Dodgeball experience for SourceMod.**

A modern, stable, and highly extensible version of the classic gamemode,  
built on the shoulders of community giants.

[📖 Wiki](https://github.com/Silorak/TF2-Dodgeball-Modified/wiki) •
[📦 Download](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest) •
[🐛 Report Bug](https://github.com/Silorak/TF2-Dodgeball-Modified/issues)

</div>

---

## ✨ Features

<table>
<tr>
<td width="50%">

### 🎮 Gameplay
- **Steal & Delay Prevention** — Anti-grief mechanics built-in
- **Dual Homing Modes** — Smooth `homing` or classic `legacy homing`
- **Bouncing Rockets** — With player-controlled force bouncing
- **"Keep Direction"** — Popular Redux feature included

</td>
<td width="50%">

### 🔧 Customization
- **Custom Rocket Classes** — Models, sounds, speeds, damage
- **Event Commands** — `@rocket`, `@owner`, `@target` placeholders
- **Per-Map Configs** — Override settings for specific maps
- **Music System** — Round start/end music with web player support

</td>
</tr>
<tr>
<td>

### 🧩 Modular Architecture
- **11 Optional Subplugins** — Enable only what you need
- **Powerful API** — 130+ natives for addon developers
- **Rich Forward System** — Hook into every game event

</td>
<td>

### 📊 Technical
- **20Hz Logic Timer** — Optimized performance
- **Smooth Frame Homing** — High-precision tracking
- **Full Documentation** — Comprehensive wiki & code docs

</td>
</tr>
</table>

---

## 🚀 Quick Start

```bash
# 1. Download the latest release
# 2. Extract to your server's tf/ directory
# 3. (Optional) Add subplugins from Subplugins/ folder
# 4. Restart server or change to a tfdb_, db_, or dbs_ map
```

<details>
<summary><b>📋 Detailed Installation Steps</b></summary>

1. **Download** the latest release from the [Releases Page](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest)
2. **Extract** the `addons` folder into your server's `tf/` directory
3. **Add Subplugins** (optional): Copy desired modules from `Subplugins/` to `tf/addons/sourcemod/plugins/`
4. **Verify Dependencies**: See [Dependencies](#-dependencies) section
5. **Restart** your server or change to any `tfdb_`, `db_`, or `dbs_` prefixed map

> 📖 See the [Installation Wiki](https://github.com/Silorak/TF2-Dodgeball-Modified/wiki/Installation) for a complete guide.

</details>

---

## 📦 Subplugins

| Module | Description |
|--------|-------------|
| **AirblastPrevention** | Prevents airblast griefing |
| **AntiSnipe** | Blocks long-distance rocket interference |
| **AntiSwitch** | Prevents weapon switching exploits |
| **ExtraEvents** | Additional event hooks for customization |
| **FFA** | Free-for-all mode support |
| **Menu** | In-game admin menu for settings |
| **NoBlock** | Player collision toggle |
| **Print** | Enhanced chat messages |
| **Speedometer** | Real-time rocket speed display |
| **Trails** | Visual rocket trail effects |
| **Votes** | Player voting system |

---

## 🔧 Dependencies

| Dependency | Required For | Download |
|------------|--------------|----------|
| **CollisionHook** | Anti Snipe Module | [AlliedModders](https://forums.alliedmods.net/showthread.php?t=197815) |
| **Nuke Model** | Nuke explosion effects | [AlliedModders](https://forums.alliedmods.net/showpost.php?p=2180141&postcount=350) |

> ⚠️ Both dependencies are **optional** — only install if using the feature.

---

## ⚙️ Configuration

```
📁 addons/sourcemod/configs/dodgeball/
├── general.cfg          # Main configuration
└── tfdb_mapname.cfg     # Per-map overrides (optional)
```

The gamemode activates automatically on maps with the `tfdb_`, `db_`, or `dbs_` prefix (including Workshop maps).

<details>
<summary><b>🎯 Example Rocket Class</b></summary>

```
"normal"
{
    "name"                "Normal Rocket"
    "behaviour"           "homing"
    "damage"              "50"
    "speed"               "800"
    "speed increment"     "50"
    "turn rate"           "0.05"
    "max bounces"         "2"
    "on kill"             "sm_beacon @target"
}
```

</details>

> 📖 See the [Configuration Wiki](https://github.com/Silorak/TF2-Dodgeball-Modified/wiki/Configuration) for all options.

---

## 🛠️ For Developers

<details>
<summary><b>📚 API Overview</b></summary>

### Include File
```sourcepawn
#include <tfdb>
```

### Key Natives
```sourcepawn
// Check if dodgeball is active
TFDB_IsDodgeballEnabled()

// Rocket manipulation
TFDB_GetRocketSpeed(int iIndex)
TFDB_SetRocketTarget(int iIndex, int iTarget)
TFDB_CreateRocket(int spawner, int spawnerClass, int team)

// Game state
TFDB_GetRocketCount()
TFDB_GetRoundStarted()
```

### Forwards
```sourcepawn
TFDB_OnRocketCreated(int iIndex, int iEntity)
TFDB_OnRocketDeflect(int iIndex, int iEntity, int iOwner)
TFDB_OnRocketSteal(int iIndex, int iOwner, int iTarget, int iStealCount)
```

</details>

> 📖 Full API documentation available in [`tfdb.inc`](TF2Dodgeball/addons/sourcemod/scripting/include/tfdb.inc)

---

## ❤️ Credits

<table>
<tr>
<td align="center"><b>Damizean</b><br><sub>Original YADB</sub></td>
<td align="center"><b>bloody & lizzy</b><br><sub>Updated YADB</sub></td>
<td align="center"><b>ClassicGuzzi</b><br><sub>Dodgeball Redux</sub></td>
</tr>
<tr>
<td align="center"><b>BloodyNightmare & Mitchell</b><br><sub>Airblast Prevention</sub></td>
<td align="center"><b>x07x08</b><br><sub>Major Advancements</sub></td>
<td align="center"><b>Silorak</b><br><sub>Current Maintainer</sub></td>
</tr>
</table>

*And the entire SourceMod community for their continued support.*

---

<div align="center">

**Made with ❤️ for the TF2 Dodgeball Community**

</div>
