# TF2 Dodgeball Modified

[![GitHub release (latest by date)](https://img.shields.io/github/v/release/Silorak/TF2-Dodgeball-Modified?style=for-the-badge)](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest)
[![GitHub issues](https://img.shields.io/github/issues/Silorak/TF2-Dodgeball-Modified?style=for-the-badge)](https://github.com/Silorak/TF2-Dodgeball-Modified/issues)

This project is a modern, stable, and highly extensible version of the classic TF2 Dodgeball gamemode for SourceMod. It builds upon the work of several community developers to provide a definitive and customizable Dodgeball experience.

---

## 📚 Documentation

**For complete documentation, including detailed installation, configuration, and module guides, please visit the [Official Wiki](https://github.com/Silorak/TF2-Dodgeball-Modified/wiki).**

The wiki is the primary source for all information regarding this project.

---

## ✨ Key Features

* **Advanced Gameplay Mechanics**: Incorporates essential features like **steal and delay prevention**, plus the popular **"keep direction"** feature from Dodgeball Redux.
* **Dual Homing Modes**: Choose between two distinct rocket behaviors: a modern, smooth `"homing"` and a classic, more direct `"legacy homing"`.
* **Extensive Rocket Customization**: Define rocket classes with unique models, sounds, speeds, turn rates, and damage properties via configuration files.
* **Rich Event System**: Use parameters like `@rocket`, `@owner`, and `@target` to trigger custom server commands on in-game events.
* **Modular System**: A powerful core plugin with a suite of optional modules allows you to enable only the features you want.
* **Developer API**: A robust set of natives and forwards allows other developers to easily create addons that interact with the gamemode.

---

## 🚀 Quick Installation

1.  **Download the latest release** from the [**Releases Page**](https://github.com/Silorak/TF2-Dodgeball-Modified/releases/latest).
2.  **Install the Core Plugin**: From the downloaded `.zip`, copy the `addons` folder into your server's `tf/` directory.
3.  **Install Optional Modules**: Copy any desired modules from the `Subplugins` folder into your server's `tf/addons/sourcemod/plugins/` directory.
4.  **Verify Dependencies**: Ensure you have the required dependencies installed (see below).
5.  **Restart** your server or change maps.

> **For a detailed step-by-step guide, please see the [Installation Page on the Wiki](https://github.com/Silorak/TF2-Dodgeball-Modified/wiki/Installation).**

---

## 🔧 Dependencies

* **CollisionHook** (Optional): Only required for the **Anti Snipe Module**.
    * Download from the [AlliedModders thread](https://forums.alliedmods.net/showthread.php?t=197815).

---

## ⚙️ Basic Configuration

* The main configuration file is located at `addons/sourcemod/configs/dodgeball/general.cfg`.
* The gamemode activates automatically on maps with the `tfdb_` prefix.

> **For a complete guide on creating custom rockets and spawners, please see the [Configuration Guide on the Wiki](https://github.com/Silorak/TF2-Dodgeball-Modified/wiki/Configuration).**

---

## ❤️ Credits

This project stands on the shoulders of giants. A huge thank you to the original creators and contributors who made TF2 Dodgeball possible.

* **Damizean** (Original YADB plugin)
* **bloody & lizzy** (Updated YADB plugin)
* **ClassicGuzzi** (Dodgeball Redux)
* **BloodyNightmare & Mitchell** (Original airblast prevention plugin)
* **x07x08** (Major advancements in TF2-Dodgeball-Modified)
* And many others in the SourceMod community.
