# Kanto Life

**Kanto Life** adds a living, moving population to the overworlds of **Gen 1, Gen 2, and Gen 3** while keeping the original games and their maps at the center of the experience.

It is one unified mod for **Yellow/Gen 1, Gold/Gen 2, and FireRed/LeafGreen/Emerald/Gen 3**. Features are adapted to each generation's native NPC, map, graphics, and world systems.

---

## 🎛️ Everything Is Optional

Every feature below can be turned **off**. Kanto Life is built as a menu of independent toggles, not an all-or-nothing package:

- **Population** — extra humans, indoor NPCs, and Pokémon NPCs each have their own on/off switch and count.
- **Routines & travel** — wandering, door/route travel, agendas, and travel animations can each be disabled.
- **Sleep** — the entire sleep system (or just ZZZs, accessories, or daytime sleepers) can be turned off.
- **Lifelike behaviors** — greetings, moods, chatter, meetups, and companions are separate `exp_*` options; disable one or all of them and the mod keeps working.
- **Interactions** — door knocking, 2nd-interaction events, and collision bubbles are each optional.

If you only want a busier overworld with zero extra behavior, turn everything off except the population counts. If you want the full living-world experience, turn it all on. The mod never forces a feature on you.

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
- **Day Sleepers** option for occasional daytime sleepers (10% of Pokémon NPCs).
- **Sleep ZZZs** that can be enabled or disabled.
- **Sleep accessories:** Tent, Sleeping Bag, and Bed styles, plus Natural (auto-selects by location).
- **Grayscale sleeping characters** with stationary sleep poses.
- **Voxel-safe sleeping visuals**, designed to work alongside supported 3D/voxel sprite systems without replacing their core rendering behavior.
- **NPC travel animations:** teleport (spin + rise), fly (rise), surf — with species-appropriate sprite swaps.
- **FireRed/Gen 3 ambient dialogue** with large, varied pools of contextual lines.
- **Named spawned civilians** so ambient characters do not all appear under the same name.
- **Progressive FireRed interactions:** repeated conversations can lead to an item, trade, or battle event.
- **FireRed Pokémon NPC interactions:** Pokémon communicate through their species cry and can trigger an item or wild-battle event.
- **FireRed wild-style Pokémon battles** for Pokémon NPC encounters.
- **FireRed Pokémon NPC replacement** after the Pokémon is caught or defeated.
- **FireRed event cooldowns** of 15 real-time minutes for item/trade and battle events.
- **Post-event dialogue references** for previous trades, items, and battles.
- **Generation-specific implementations** so Gen 1, Gen 2, and Gen 3 do not have to share incompatible engine behavior.
- **Save-aware settings** so configurable values can persist between sessions.
- **Live option changes** for population, travel, sleep, agenda, and related settings where supported.
- **Lifelike NPC behaviors** (optional `exp_*` toggles): greetings, moods with mood-colored speech bubbles, NPC meetups, walking companions, NPC-to-NPC chatter, idle behaviors, yawns, sneezes, and time-of-day comments — every one of them can be switched off independently.

---

## 🎮 Generation Support

### Gen 1 — Kanto / Yellow (v1.4.266)

**Sleep:** Grayscale, lying-down sprites with Zzz. Bed/tent/sleeping bag accessories via SLEEP STYLE (Default/Tent/Sleeping Bag/Bed/Random/Natural).
**Travel:** 25% fly / 25% teleport / 25% door / 25% route, with animated departures (teleport spin/rise, fly rise).

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
- Teleport/fly departure animations with native engine effects.
- 2nd-interaction events: item, trade, or battle — repeating every 15 real minutes per NPC.

### Gen 2 — Gold / Johto (v1.4.266)

**Sleep:** Grayscale, lying-down sprites with Zzz. 2D and voxel support. Bed/tent/sleeping bag accessories via SLEEP STYLE (Default/Tent/Sleeping Bag/Bed/Random/Natural).
**Travel:** 25% fly / 25% teleport / 25% door / 25% route, with native teleport animation and fly rise.

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
- Daytime sleepers (10% of Pokémon NPCs sleep during day).
- Sleep ZZZs.
- Sleeping sprites with bed/tent/sleeping-bag accessories.
- Grayscale/stationary sleeping presentation.
- Sleep props rendered safely with supported voxel/3D sprite setups.
- NPC talk/collision bubbles (2D and voxel).
- Door Knocking.
- NPC Travel percentage.
- NPC Agenda: `OFF`, `DAY`, or `FULL`.
- Teleport/fly departure animations.
- 2nd-interaction events: item, trade, or battle — repeating every 15 real minutes per NPC.
- Migration of older Johto Life option data into the unified Kanto Life settings bucket.

### Gen 3 — FireRed / LeafGreen / Emerald (v1.4.266)

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
- Every second interaction can produce an **item, trade, or battle** for human NPCs.
- Pokémon NPCs use an **item or wild-battle** event on their second interaction.
- Human NPC battles use a non-team-themed civilian trainer presentation when the required trainer data is available.
- Pokémon NPC battles use a **wild-style encounter** rather than a trainer battle.
- A Pokémon NPC that is **caught or defeated** leaves the overworld and is replaced with another Pokémon NPC.
- Item/trade and battle events use **15-minute real-time cooldowns**.
- Later conversations can reference a previous **trade, item, or battle**.
- Sleeping NPCs with adjustable rate, daytime sleeping, ZZZs, and sleep styles.
- FireRed's native Game3 object and world systems remain responsible for graphics, collision, movement, and map behavior.

---

## 💤 Sleeping NPCs

Sleeping NPCs can use six visual styles:

1. **Default** — the NPC lies down in the sleep pose.
2. **Tent** — adds the sleeping tent texture.
3. **Sleeping Bag** — adds the sleeping-bag texture.
4. **Bed** — adds the bed texture.
5. **Random** — randomly assigns one of the above per NPC.
6. **Natural** — auto-selects by location: tent outdoors, bed in houses, 80% sleeping bag / 20% default in other interiors.

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
- **Sleep Style** — Default, Tent, Sleeping Bag, Bed, Random, or Natural (auto-selects: tent outdoors, bed in houses, 80% sleeping bag / 20% default elsewhere).
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
- On the second interaction, a human NPC can trigger an **item, trade, or battle** event.

### Pokémon NPCs

- Pokémon NPCs display their species identity.
- They respond with the Pokémon's **native cry and cry audio** rather than human dialogue.
- On their second interaction, they can provide an item or trigger a wild-style battle.
- Catching or defeating the encountered Pokémon removes that overworld Pokémon NPC and replenishes the population.

### Battle cooldown

- Battle events use a **15-minute real-time cooldown**.
- The cooldown prevents repeated battle triggers from firing back-to-back.

---

## 💛 Lifelike NPC Behaviors

An optional layer that makes NPCs feel like people going about their day. **Every behavior below is a separate toggle** — turn on the ones you like, turn off the rest. Disabling them changes nothing else about the mod.

- **Greetings** (`exp_greetings`) — NPCs greet you when you arrive on a map, walk up to them, or return after being away. What they say depends on their mood.
- **Moods** (`exp_moods`) — NPCs cycle through happy, neutral, grumpy, sleepy, and excited moods, which change their greeting and chatter wording.
- **Mood-colored speech bubbles** — emotion bubbles are tinted by the NPC's mood: warm yellow for happy, orange for excited, red for grumpy, soft blue for sleepy. Regular conversation stays white.
- **NPC meetups** (`exp_chatter`) — two NPCs can walk up to each other and hold a 5–10 second back-and-forth conversation, then go their separate ways.
- **Walking companions** (`exp_companions`) — bonded NPCs fall in step and walk beside each other, stride for stride, instead of wandering alone.
- **NPC-to-NPC chatter** (`exp_chatter`) — nearby NPCs exchange short two-line chats ("Beautiful day, isn't it?" / "Sure is!").
- **Idle behaviors** (`exp_idle`) — NPCs look around and hum to themselves as they go about their routines.
- **Contagious yawning** (`exp_ambience`) — when one NPC yawns, nearby NPCs can catch it.
- **Sneezes** (`exp_ambience`) — NPCs sneeze, and a nearby NPC may reply "Bless you!".
- **Curiosity** (`exp_ambience`) — NPCs pop a `?` bubble when something catches their eye, and can get startled if you sprint past.
- **Pokémon adoration** (`exp_ambience`) — NPCs melt at cute Pokémon with a mood-colored "Aww!".
- **Time-of-day comments** (`exp_timeaware`) — NPCs remark on the morning, afternoon, evening, or night.
- **Player-aware reactions** (`exp_player`) — NPCs notice and react to what you're doing nearby.

None of these interfere with travel: an NPC that starts teleporting, flying, or surfing is left alone until its departure finishes.

---

## 🧩 Compatibility

Kanto Life is packaged as a unified content mod for:

- **Gen 1**
- **Gen 2**
- **Gen 3**
  - FireRed
  - LeafGreen
  - Emerald

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

**Current unified build:** `1.4.266`
