# TDS Automation API 🛠️

A comprehensive Luau library designed to streamline and automate match logic for **Tower Defense Simulator**.

---

## 🧩 Core Engine Methods

| Method | Parameters | Description |
| --- | --- | --- |
| `Place` | `name, x, y, z` | Places a tower. Returns `tower_index`. |
| `Upgrade` | `index, path` | Upgrades the tower at the specified index. |
| `Sell` | `index` | Sells the tower at the specified index. |
| `SetTarget` | `index, mode` | Changes targeting (e.g., `"First"`, `"Strong"`). |
| `SetOption` | `idx, name, val, wave` | Configures tower toggles (e.g., Unit control). |
| `Ability` | `idx, name, data, loop` | Activates abilities; `loop` enables auto-cast. |

---

## 📖 In-Depth Usage & Options

For detailed implementation of complex methods—including specific `data` strings for **SetOption**, **Ability** names, and **Targeting** modes—please refer to the [Official Documentation](https://github.com/Shonkyyy/Auto_Strat/blob/main/docs).

* **`SetTarget`**: Use this to optimize damage by switching towers to `"Strong"` for bosses or `"Last"` for specific leak control.
* **`SetOption`**: Essential for towers like the **Mercenary Base** where unit selection is required.
* **`Ability`**: Can be used for one-time activations (like **Call to Arms**) or set to `loop = true`.

---

## 🎮 Match Control
* **`TDS:GameInfo(map, modifiers)`** -- Selects the desired Map and Modifiers.
* **`TDS:VoteSkip()`** – Sends a skip request with a built-in retry loop.
* **`TDS:TimeScale(value)`** – Sets game speed (`0.5` to `2`). *Requires tickets.*

---

### **🚀 Quick Start Setup**

To run this automatically, place your script in your executor's **`autoexec`** folder. Use the template below to configure your settings:

```lua
-- [[ CONFIGURATION ]]
getgenv().AutoStrat     = true
getgenv().AutoSkip      = true
getgenv().AutoPickups = true
getgenv().AntiLag = true

-- [[ WEBHOOK SETTINGS ]]
getgenv().SendWebhook   = false -- Set to true to enable notifications
getgenv().Webhook       = "YOUR-WEBHOOK-URL-HERE" 

-- [[ INITIALIZE LIBRARY ]]
local TDS = loadstring(game:HttpGet("https://raw.githubusercontent.com/DuxiiT/tds-autostrat/refs/heads/main/main.lua"))()

-- [[ START STRATEGY ]]
-- Example:
-- TDS:Loadout("Soldier", "Farm")
-- TDS:Mode("Frost")
-- TDS:GameInfo("Simplicity", {HiddenEnemies = true})

-- TDS:UnlockTimeScale() <-- You may remove this if you don't want to use timescale tickets
-- TDS:TimeScale(2) <-- You may remove this if you don't want to use timescale tickets

--TDS:Place("Soldier", 10, 10, 10)
--TDS:Equip("Scout")
--TDS:VoteSkip(1, 5)
--TDS:VoteSkip(1)
```

> [!IMPORTANT]
> Ensure `getgenv().SendWebhook` is set to `true` if you provide a URL; otherwise, the script may error out during initialization.

---

## 📜 Usage Policy & Copyright

**Copyright © 2025 Duxii. All Rights Reserved.**

* **Modification:** Permitted for personal use or free strategies.
* **Non-Commercial:** Strictly prohibited from selling this script or using it for paid services.
* **Attribution:** Credit the original author if redistributing modified versions.

**Questions?** Join our [Community](https://discord.gg/dd5wfcd2HX) on Discord.
