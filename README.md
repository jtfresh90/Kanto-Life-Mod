# Kanto Life — Experimental Fork

> **This is the experimental fork** (`experimental/lifelike-features`) of [Kanto Life](https://github.com/jtfresh90/Kanto-Life-Mod).
> For the stable release, use the [main mod](https://github.com/jtfresh90/Kanto-Life-Mod).

## 🧪 Fork vs Main: Feature Differences

This fork contains **all main-mod features plus 23+ experimental lifelike NPC behaviors**. All main bug fixes are ported here.

### Exclusive to this fork (experimental)
- **Proximity greetings** (3 tiles, 30s cooldown, all 3 gens)
- **Mood-colored** proximity greeting bubbles
- **Group conversations** between NPCs
- **Contagious yawning**
- **Idle-player curiosity** `?` bubbles
- **Welcome-back greetings**
- **Sneezes** with bless-you responses
- **Time-of-day transition comments**
- **Pokémon adoration** (Gen 1/2)
- **NPC walking-companion bonds**
- **NPC-to-NPC chatter** with real dialogue exchanges
- **Traveler arrival greetings**

### Synced with main (all bug fixes ported)
- **Sleep:** 1.0.0-based (no accessories), HGSS support, grayscale lying-down — same as main 1.4.36
- **Travel:** 25% fly / 25% teleport / 25% door / 25% route — same as main
- **Wild mod compatibility:** pcall protections for Wilds of Kanto, Revival, Untamed — same as main
- **Sleep exclusions:** Story NPCs, boat boarders, Nurse Joy, shop clerks never sleep — same as main
- **Celadon Living District:** Compatible via NPC flag isolation

> **Warning:** Experimental features may be unstable.

**Kanto Life** adds a living, moving population to the overworlds of **Gen 1, Gen 2, and Gen 3** while keeping the original games and their maps at the center of the experience.

It is one unified mod for **Yellow/Gen 1, Gold/Gen 2, and FireRed/LeafGreen/Emerald/Gen 3**. Features are adapted to each generation's native NPC, map, graphics, and world systems.

---

## ✨ Features at a Glance

- **Ambient NPCs** that populate towns, routes, and interiors.
- **Extra human NPCs** with adjustable population counts.
- **Indoor NPCs** with their own adjustable population count.
- **Optional Pokémon NPCs** with adjustable counts.
- **Random Pokémon mode** for Pokémon NPC variety.
- **Area-aware Pokémon spawning** when random mode is disabled, using nearby/connected encounter information where available.
- **NPC routines** that let spawned characters roam instead of remaining permanently at their spawn point.
- **Local wandering** plus longer-distance **door and route travel**.
- **Indoor/outdoor transitions** through appropriate doors, exits, stairs, and route connections.
- **Replacement spawning** at entrances/exits so populations remain active as NPCs travel away.
- **NPC travel percentage** setting in 10% steps to control how many spawned NPCs receive longer-distance travel behavior.
- **NPC Agenda** modes: `OFF`, `DAY`, and `FULL`.
- **NPC-to-NPC collision reactions** with short speech bubbles in supported Gen 3 gameplay.
- **Door Knocking** / house-entry etiquette.
- **Sleeping NPCs** with adjustable sleep rates in 10% steps.
- **Day Sleepers** option for occasional daytime sleepers.
- **Sleep ZZZs** that can be enabled or disabled.
- **Sleeping NPCs:** Default sleeping sprites only (grayscale, lying down). Tent/Sleeping Bag/Bed accessories disabled as of 1.4.31 — they caused visual regressions.
- **Grayscale sleeping characters** with stationary sleep poses.
- **Voxel-safe sleeping visuals**, designed to work alongside supported 3D/voxel sprite systems without replacing their core rendering behavior.
- **FireRed/Gen 3 ambient dialogue** with large, varied pools of contextual lines.
- **Named spawned civilians** so ambient characters do not all appear under the same name.
- **Progressive FireRed interactions:** repeated conversations can lead to an item, trade, or battle event.
- **FireRed Pokémon NPC interactions:** Pokémon communicate through their species cry and can trigger an item or wild-battle event.
- **FireRed wild-style Pokémon battles** for Pokémon NPC encounters.
- **FireRed Pokémon NPC replacement** after the Pokémon is caught or defeated.
- **FireRed battle cooldown** of one real-time hour for battle events.
- **Post-event dialogue references** for previous trades, items, and battles.
- **Generation-specific implementations** so Gen 1, Gen 2, and Gen 3 do not have to share incompatible engine behavior.
- **Save-aware settings** so configurable values can persist between sessions.
- **Live option changes** for population, travel, sleep, agenda, and related settings where supported.

---

## 🎮 Generation Support

### Gen 1 — Kanto / Yellow (v1.4.36)

**Sleep:** 1.0.0-based. Grayscale, lying-down sprites with Zzz. HGSS sprite support. Bed/tent/sleeping bag accessories via SLEEP STYLE (Default/Tent/Sleeping Bag/Bed/Random).
**Travel:** 25% fly / 25% teleport / 25% door / 25% route.
**Wild mods:** Compatible with Wilds of Kanto, Wilds of Kanto Revival, Untamed Tohjo via pcall protections.

- Extra human NPCs for towns and routes.
- Adjustable indoor NPC population.
- Optional Pokémon NPC population.
- Random Pokémon NPC selection.
- Native Gen 1 NPC wandering for local movement.
- Kanto Life route/door controller for travel-selected NPCs.
- Town, route, and interior travel destinations.
- Route exits and entrances used for longer-distance movement.
- Doorway approach logic that avoids placing NPCs directly on transition tiles.
- Replacement spawning that avoids repeatedly sending NPCs through the same doorway when alternatives exist.
- Sleeping NPCs with adjustable rate.
- Daytime sleeper option.
- Sleep ZZZs.
- Default sleeping sprites only (1.0.0 behavior; accessories disabled in 1.4.31).
- Grayscale, stationary sleeping presentation.
- NPC talk/collision bubbles.
- Door Knocking.
- NPC Travel percentage.
- NPC Agenda: `OFF`, `DAY`, or `FULL`.

### Gen 2 — Gold / Johto (v1.4.36)

**Sleep:** 1.0.0-based. Grayscale, lying-down sprites with Zzz. 2D and voxel support. Bed/tent/sleeping bag accessories via SLEEP STYLE (Default/Tent/Sleeping Bag/Bed/Random).
**Travel:** 25% fly / 25% teleport / 25% door / 25% route.

- Extra human NPCs for towns, routes, and interiors.
- Adjustable indoor NPC population.
- Optional Pokémon NPC population.
- Random Pokémon NPC selection.
- Wider local NPC roaming instead of staying confined to the original anchor area.
- Door, route, and indoor transition routines.
- Route exits and entrances for longer-distance travel.
- Door approach cells to prevent doorway ping-pong.
- Replacement spawning through usable entrances.
- Sleeping NPCs with adjustable rate.
- Daytime sleepers.
- Sleep ZZZs.
- Default sleeping sprites only (1.0.0 behavior; accessories disabled in 1.4.31).
- Grayscale/stationary sleeping presentation.
- Sleep props that can be rendered safely with supported voxel/3D sprite setups.
- NPC talk/collision bubbles.
- Door Knocking.
- NPC Travel percentage.
- NPC Agenda: `OFF`, `DAY`, or `FULL`.
- Migration of older Johto Life option data into the unified Kanto Life settings bucket.

### Gen 3 — FireRed / LeafGreen / Emerald

- Native Game3 EventObject-based ambient NPCs.
- Extra human NPCs with real game graphics rather than fabricated placeholder actors.
- Adjustable indoor NPC population.
- Optional Pokémon NPC population.
- Random Pokémon NPC mode with variety protection against repeatedly selecting the same graphics.
- Area/connected-route-aware Pokémon selection when random mode is disabled.
- Outdoor spawning that avoids isolated roof areas and doorway/warp tiles.
- Indoor spawning that respects the actual map environment.
- Native door and route transition handling.
- Indoor exits, outdoor route connections, and replacement entrances.
- Door approach cells so NPCs do not stand directly on transition tiles.
- Alternate-door selection when multiple usable entrances exist.
- FireRed Door Knocking with an explicit **YES / NO** choice before a courtesy entry.
- Short NPC-to-NPC collision speech bubbles.
- Randomized civilian names for spawned NPCs.
- Large, non-repeating contextual dialogue generation for ambient human NPCs.
- Dialogue can reference Pokémon, locations, routes, activities, and previous interactions.
- Pokémon NPCs use their **species name and native cry** rather than invented human dialogue.
- Repeated interaction tracking for ambient NPCs.
- Every fifth interaction can produce an **item, trade, or battle** for human NPCs.
- Pokémon NPCs use an **item or wild-battle** event on their fifth interaction.
- Human NPC battles use a non-team-themed civilian trainer presentation when the required trainer data is available.
- Pokémon NPC battles use a **wild-style encounter** rather than a trainer battle.
- A Pokémon NPC that is **caught or defeated** leaves the overworld and is replaced with another Pokémon NPC.
- Battle events use a **one-hour real-time cooldown**.
- Later conversations can reference a previous **trade, item, or battle**.
- Sleeping NPCs with adjustable rate, daytime sleeping, ZZZs, and sleep styles.
- FireRed's native Game3 object and world systems remain responsible for graphics, collision, movement, and map behavior.

---

## 💤 Sleeping NPCs

Sleeping NPCs can use four visual styles:

1. **Default** — the NPC lies down in the sleep pose.
2. **Tent** — adds the sleeping tent texture.
3. **Sleeping Bag** — adds the sleeping-bag texture.
4. **Bed** — adds the bed texture.

Sleeping characters are kept stationary and presented in a grayscale sleep state, with optional **ZZZ** effects. The implementation is designed to be safe for both traditional 2D rendering and supported voxel/3D overworld sprite systems.

### Sleeping texture previews

<table>
<tr>
<td align="center"><strong>Tent</strong><br><img src="assets/sleep_tent.png" width="160" height="192" alt="Kanto Life sleeping tent texture"></td>
<td align="center"><strong>Sleeping Bag</strong><br><img src="assets/sleeping_bag.png" width="160" height="192" alt="Kanto Life sleeping bag texture"></td>
<td align="center"><strong>Bed</strong><br><img src="assets/sleep_bed.png" width="160" height="192" alt="Kanto Life sleeping bed texture"></td>
</tr>
</table>

The source textures are intentionally kept as small pixel-art assets in the mod's `assets/` folder; the enlarged previews above use the same files and do not alter the game textures.

---

## ⚙️ Options

Open the mod options from the game's normal options/mod interface. The available settings include:

- **Extra NPCs** — enable/disable additional ambient humans.
- **Extra NPC Count** — choose the extra population size.
- **Indoor NPCs** — enable/disable indoor ambient humans.
- **Indoor NPC Count** — choose the indoor population size.
- **Pokémon NPCs** — enable/disable ambient Pokémon.
- **Pokémon NPC Count** — choose the Pokémon population size.
- **Random Pokémon NPCs** — switch between broad random selection and area-aware selection where supported.
- **Sleeping NPCs** — enable/disable sleeping characters.
- **Sleep Rate %** — adjustable in 10% increments.
- **Day Sleepers** — allow sleepers during daytime.
- **Sleep ZZZ** — show/hide the ZZZ effect.
- **Sleep Style** — Default, Tent, Sleeping Bag, or Bed.
- **NPC Talk Bubbles** — show/hide short NPC-to-NPC collision reactions.
- **Door Knocking** — enable/disable house-entry etiquette.
- **NPC Routines** — enable/disable routine behavior.
- **NPC Travel %** — adjustable in 10% increments.
- **NPC Agenda** — `OFF`, `DAY`, or `FULL`.

Settings are generation-specific where the underlying game systems require it, while the overall feature set is kept consistent across Kanto Life's three supported generations.

---

## 🚪 NPC Routines & Travel

Kanto Life separates ordinary wandering from longer-distance travel:

- Most ambient NPCs can **wander locally** around the area where they spawned.
- A percentage of NPCs can be selected for **travel behavior** using the NPC Travel setting.
- Travel NPCs can head toward **doors, route exits, entrances, stairs, and other valid map transitions** depending on the generation.
- NPCs approach transition cells rather than being parked directly on the warp tile.
- When an NPC leaves, Kanto Life can create a **replacement entrant** so the area continues to feel populated.
- Where multiple entrances are available, the replacement system can avoid immediately reusing the same entrance.
- Indoor and outdoor maps use their appropriate transition logic.
- Collision and walkability checks are used to avoid invalid destinations.

The Gen 1 implementation intentionally leaves ordinary Yellow local wandering with the engine's native walker while the Kanto Life controller handles route/door travel. This keeps continuous local movement under the engine's normal NPC timing and collision behavior.

---

## 🏠 Door Knocking

With **Door Knocking** enabled, house entry can use a short courtesy interaction instead of silently walking through a residence entrance.

- Face an eligible entrance and interact to knock.
- Choose **YES** or **NO** when a choice is presented.
- Confirmed entry authorizes that door transition once.
- The system is designed to avoid repeatedly reopening the same prompt from a single button press.
- FireRed uses its native choice handling for the YES/NO interaction.

---

## 💬 FireRed Ambient Conversations

FireRed adds the most advanced interaction layer in Kanto Life.

### Human NPCs

- Spawned civilians receive stable generated names.
- Dialogue is selected from a large deterministic sequence to reduce repetition.
- Lines can draw from subjects such as Pokémon, routes, towns, activities, travel, and local surroundings.
- Previous special events can be referenced later.
- On the fifth interaction, a human NPC can trigger an **item, trade, or battle** event.

### Pokémon NPCs

- Pokémon NPCs display their species identity.
- They respond with the Pokémon's **native cry and cry audio** rather than human dialogue.
- On their fifth interaction, they can provide an item or trigger a wild-style battle.
- Catching or defeating the encountered Pokémon removes that overworld Pokémon NPC and replenishes the population.

### Battle cooldown

- Battle events use a **one-hour real-time cooldown**.
- The cooldown prevents repeated battle triggers from firing back-to-back.

---

## 🧩 Compatibility

Kanto Life is packaged as a unified content mod for:

- **Gen 1**
- **Gen 2**
- **Gen 3**
  - FireRed
  - LeafGreen
  - Emerald

The mod also declares optional compatibility with:

- **HGSS_SPRITES**
- **red_3d_player**
- **player_model_loader**
- **PORYGONAL_OVERWORLD_CHARACTERS**
- **LEGENDARY_STADIUM_OVERWORLD_MODELS**
- **TERRARIUM**

Kanto Life's routine code is scoped to its own ambient actors and is designed not to take over the core behavior of unrelated NPCs or visual mods.

---

## 📦 Installation

1. Download the latest Kanto Life release ZIP.
2. Install/import it through the **gen1recomp MODS** interface, or place the mod under the game's `mods/` directory.
3. Enable **Kanto Life**.
4. Open the Kanto Life options and configure the population, routines, sleep, travel, agenda, and interaction features you want.
5. Start or continue your game.

### Mod structure

```text
Kanto-Life/
├── main.lua
├── manifest.json
├── README.md
├── lib/
│   ├── KantoMain.lua
│   ├── KantoRoutines.lua
│   ├── JohtoMain.lua
│   ├── JohtoRoutines.lua
│   ├── FireRedMain.lua
│   ├── FireRedAmbient.lua
│   ├── FireRedRoutines.lua
│   ├── FireRedInteractions.lua
│   ├── FireRedDoorKnocking.lua
│   └── FireRedSleep.lua
└── assets/
    ├── sleep_tent.png
    ├── sleeping_bag.png
    └── sleep_bed.png
```

---

## 🔄 Updates

Kanto Life is distributed through GitHub releases and includes a launcher update manifest for the repository:

`jtfresh90/Kanto-Life-Mod`

The launcher can detect a newer installable ZIP when a release is published.

---

## ❤️ Credits & Compatibility Notes

Kanto Life is built for the **gen1recomp** ecosystem and uses each supported generation's native world/NPC systems where appropriate.

Optional sprite, voxel, and overworld mods remain optional; Kanto Life adapts its behavior when their supported interfaces are present.

**Current unified build:** `1.2.36`
