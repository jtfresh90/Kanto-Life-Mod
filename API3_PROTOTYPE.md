# API 3 prototype branch (`api3-features`)

Status: **prototype, not a release.** The branch is pushed to origin
(`api3-features`) for play-testing only; no release is cut from it.
`main` stays on 1.4.268 / api 2 until Joshua decides otherwise.

This branch flips `manifest.json` to `"api": 3` and adds one additive
module, `lib/Api3Features.lua`, installed from `main.lua` after the
per-generation installers, fail-open: if the API 3 layer errors, the
existing Gen 1/2/3 systems keep running untouched. The module checks for
the API 3 facades (`mod:supports`) and stays inert on api < 3.

## API 3 compatibility fixes (the only non-additive changes)

Booting the branch on the real 0.3.94 engine exposed two Gen 2 breaks
that api 2 never had, both in `lib/JohtoMain.lua`, plus a lifecycle bug
in the new companion code. All fixes are guarded so api 2 behaviour is
unchanged; main (api 2) does not need them.

1. **`map.ready` subscription (JohtoMain)** — API 3's unified events
   catalog has no `map.ready` call site on any generation, and
   subscribing raises (`unsupported events callback map.ready in
   Gen 2`). The subscription sat mid-installer, so the whole Gen 2
   installer aborted: everything after it (including the
   `johtoSleepTick` assignment) never ran, and the already-wrapped
   `input.step` hook then warned ~9,775 times about the nil tick.
   Fix: that one subscription is pcall-guarded; `map.entered` /
   `map.reloaded` drive the same handler. A full audit of every
   `events:on` / `hooks:wrap` name in the mod against the unified
   catalog found no other unguarded breaks (`world.talk` has no Gen 2
   site and `shiny.roll` none on Gen 1 — the API 3 layer already checks
   `mod:supports` for those).
2. **`update` event (JohtoMain voxel-sleep retry)** — also absent from
   the unified catalog. It was already inside a pcall, so it failed
   silently; the retry now falls back to wrapping the `core.update`
   hook when the event subscription fails.
3. **Companion spawn loop (Api3Features)** — Gen 2's unified events
   cycle `map.exited` / `map.entered` while live maps are prepared;
   at boot this produced 946 spawn/despawn cycles on PLAYERS_HOUSE_2F.
   Guards: `map.exited` only retires the companion when its own map
   exits, a re-entrancy flag around `spawnNpc`, a 2-second same-map
   respawn debounce keyed on real despawns, and retiring a companion
   left on another map before spawning a new one. After the fix the
   Gold boot spawns exactly one companion.
4. **Companion spawn refused at Gen 3 map entry (Api3Features)** —
   on Gen 3, `map.entered` fires while the world is still busy with
   the continue transition and `spawnNpc` refuses every sprite with
   "world is busy"; without a later transition the companion never
   appeared. A failed attempt now arms a retry that `world.stepped`
   runs (throttled to once per second) once the player moves; the
   next real map transition would also retry via `map.entered`. The
   retry is covered by mock tests; the headless driver never steps
   the player, so its in-game confirmation is on the play-test list.

## What each point does

1. **Official emote bubbles** — `world.trainer_engaged` (all gens) queues a
   portable script `{ "emote", <trainer object index>, "shock", 60 }`
   through `mod.world:queueScript`. Target resolution tries the payload's
   object index, then its full object id; the engine validates the whole
   script before running it, so a bad target refuses cleanly.
2. **NPC handles** — a small layer over `mod.world:npc(mapId, id)`:
   `stepHandle` is the only movement writer and always asks `canStep`
   first; `faceHandle`, `placeHandle`, and `swapAppearance`
   (`setAppearance`, the teleport/fly departure sprite-swap) wrap the
   remaining handle methods, all pcall-guarded.
3. **Portable interaction events** — pure builders (`Api3.buildEventScript`)
   produce `queueScript` rows for heal (`heal_party`), gift (`give_item`),
   gift Pokémon (`play_cry` + `give_pokemon`), mart (`open_mart`), and
   trainer (`start_battle`) events. They run on the companion: every 2nd
   talk, repeating after 15 real minutes, cycling
   heal → gift → giftmon → mart → wild. Wild events use
   `mod.world:startWildBattle` (which API 3 gives Gold). `open_mart`
   caveat: it needs the TEXT constant of a native mart script — record one
   per map with `Api3.setMartConst(mapId, const)`; without one the mart
   event degrades to gift instead of failing.
4. **Companion + follower hook + live maps** — `map.entered` spawns one
   runtime companion NPC per map (respawn-per-entry, the documented
   pattern); it follows on `world.stepped` using the handle layer, with a
   `setAppearance` swap + `placeAt` catch-up when left 8+ cells behind.
   The `world.follower.spawn` hook (all gens) suppresses the vanilla
   follower while the companion is out, so the companion takes the
   follower slot. `world.live_maps_updated` (Gen 1/2) is journalled.
   Talking to the companion: Gen 1/3 claim the talk via the `world.talk`
   hook; Gen 2 (no `world.talk` site) uses `world.interacted`.
5. **Battle-aware journal** — `battle.started` records the fight plus a
   `mod.battle:snapshot()` enemy readout; `battle.ended` records the
   result. `trainer.party` is wrapped as a pure observer (records the
   served party in canonical shape). Deliberately no mutation: Kanto
   Life's ≤40 / player−10 level rules belong to its own event battles —
   a global clamp would nerf gym leaders and the Elite Four.
   `shiny.roll` (Gen 2/3) forces shiny only for a wild battle this layer
   started with a pending request. For play-test visibility, companion
   wild events request shiny on a 1-in-16 cadence — a labelled test rate,
   not a design rate.
6. **Gen 3 screen** — `KANTO_LIFE_API3` is registered in
   `content.screens` and opened from a `ui.start_menu.items` row
   ("KANTO LIFE API3"). It shows the journal (last battle / trainer /
   event, battles seen) and stepper toggles for companion, emotes,
   companion events, battle journal, and shiny events. Toggles persist in
   the `api3cfg` mod.save bucket; journal in `api3journal`. On Gen 3 the
   screen opens through the API 3 `mod.ui` bridge (GBA frame interior).

## Portability audit — what else can be one code across all 3 gens?

Checked feature by feature against the 0.3.94 unified facades
(UnifiedCallbacks catalog + call sites, UnifiedWorld, UnifiedScripts):

| Feature | One code? | Why |
| --- | --- | --- |
| 2nd-interaction events (item / trade / battle / wild) | **Unified decision engine — done** | A first portable version (firing events from the API 3 layer via unified `queueScript` rows) was removed at Joshua's direction: it could not reproduce the features without changing them — `give_pokemon` never takes a Pokémon in exchange, the unified `trade` verb only replays the game's native fixed trades, and a unified trainer battle needs a native trainer class with its fixed party. The shipped unification is therefore one shared decision engine, `lib/SharedEvents.lua`, behind small per-gen adapters: the engine owns the decisions and bookkeeping for all 3 gens (random pick excluding the previous kind; split 15-minute gates — `lastItemAt` for item/trade, `lastBattleAt` for battles; Pokémon NPCs roll 70% battle / 30% item with fallback to the other kind and a "check back later" wait message; battle level = lowest party member − 10, clamped 2–40 — semantics unified at Joshua's direction, Oct 21 2026), while each gen executes with its own existing native code (interactive trade flow, random-party trainer battles, wild battle against the NPC's own species). Events fire on even-numbered talks for all gens and apply only to NPCs the mod itself spawns; native map NPCs are never touched. If `SharedEvents.lua` fails to load in a gen, that gen's original event code stays in charge (fail-open). The API 3 layer itself never fires NPC events — a mock-test guard asserts that. |
| Companion + follower slot | **Yes — done (P4)** | `spawnNpc` / handles / `world.follower.spawn` are one shape on all gens. |
| Emote bubbles ("!" on trainer engage) | **Yes — done (P1)** | `world.trainer_engaged` + portable `emote` row on all gens. |
| Battle journal / shiny forcing | **Yes — done (P5)** | `battle.started/ended` + snapshot on all gens; `shiny.roll` has Gen 2/3 sites (Gen 1 has no shiny mechanic to hook). |
| Journal / toggles screen | **Yes — done (P6)** | `ui.start_menu.items` has sites on all gens; the Gen 3 `mod.ui` bridge renders the same screen. |
| Ambient NPC routines / agendas / meetups | No | The brains hook per-gen movement/collision internals and per-gen NPC registries; the unified world exposes handles for runtime NPCs but no routine scheduler or agenda state. A portable routine engine could be built on `world.stepped` + handles (the companion's follow is the seed of it), but it would be a rewrite, not a unification. |
| Sleep system (sprites, beds, voxel) | No | Sprite compositing and render pipelines are per-gen; API 3 adds no rendering surface for sleep. Stays per-gen by design. |
| Travel departures (fly / teleport / surf) | Partial | For runtime NPCs the handle layer (`setAppearance` swap + `placeAt`, `flyTo`, `useFieldAction`) is portable — the companion's catch-up already uses it. The per-gen systems move their own ambient NPCs through per-gen state machines (surf needs per-gen water/pathing logic), so those stay per-gen. |
| Free-roam speech bubbles / dialogue | Partial | Scripted moments are portable (`show_text` / `emote` rows — P3 uses them). The ambient bubble pipeline renders through per-gen hooks and stays. |
| Door knocking (Gen 3) | Portable in principle | Its input hooks (`input.key` / `input.gamepad` / `input.step`) have call sites on all gens, but the feature is Gen 3 flavour by design; not moved. |
| Mod options | Already shared | `mod.options` is not a per-gen facade; options are defined once in `main.lua`. The per-gen modules still register a few of their own rows — centralising them is janitorial, not an API 3 question. |

Net: every feature the unified facades can express *without changing
how it works* is expressed once (P1–P6), and the 2nd-interaction
events — whose interactive trade and random-party battles exceed the
unified rows — are unified one level up, as a single shared decision
engine (`lib/SharedEvents.lua`) with per-gen execution adapters.
What remains per-gen is rendering (sleep, bubbles) and the routine
brains — bound to engine internals the portable API deliberately
does not expose.

## Verification on this branch

- `tests/run_api3_mock.py` — lupa compile check for every Lua file
  (three FireRed files skip on a documented lupa/LuaJIT baseline
  difference, identical on main) plus 86 mock-mod assertions covering
  all six points, the api<3 inert path, the Gen 3 busy-world spawn
  retry, and the SharedEvents decision engine (70/30 roll boundary,
  cooldown cross-fallbacks, wait paths, 900s gate expiry, human pool
  exclusion/widening, gate stamping, battle-level clamps).
- Headless boot test on the real 0.3.94 engine (Xvfb, driver runs,
  branch mod copied into the rig's `mods/kanto_life/`):
  - **Yellow: pass.** Mod loaded under api 3, API 3 layer installed
    (flyTo/emote/companion/screen all true), companion spawned once on
    VIRIDIAN_CITY, in-world samples clean, no Lua errors — only the two
    known api-3 sandbox warnings about the Gen 1 debug-log writer
    (pre-existing on main, has a compat-storage fallback).
  - **Gold: pass after the fixes above.** First run failed as
    documented (Gen 2 installer abort + companion spawn loop); the
    re-run loads Johto Life fully, installs the API 3 layer, spawns
    exactly one companion, and completes the driver with zero errors
    or warnings.
  - **Emerald: pass at load level.** Mod + API 3 layer install with
    zero errors or warnings (the `world.live_maps_updated`
    subscription, which has no Gen 3 call site, is accepted silently
    and simply never fires). The rig has no Emerald save, so in-world
    Gen 3 coverage comes from FireRed below.
  - **FireRed (Gen 3 in-world): pass.** 7,200-frame run in
    FR_VIRIDIAN_CITY_MART: FireRedMain routines active (3 routine NPCs
    of 6), API 3 layer installed, zero Lua errors. The one finding is
    the companion's "world is busy" spawn refusal at entry — fix 4
    above; its stepped retry needs a real player step to confirm.
- Unified-events boot re-test (after the SharedEvents wiring): all
  three gens log `unifiedEvents=1` in the layer-installed line,
  proving the shared engine registered in each gen's module. Yellow:
  companion spawned once on VIRIDIAN_CITY, zero errors (the
  boot-check driver then stalls in Gen 1 menus and the run is
  timeout-killed — a driver quirk, reproduced with pre-unification
  code; judged on install lines + in-world samples). Gold: BOOT DONE,
  exactly one companion, zero errors or warnings. FireRed: 7,200
  in-world frames in FR_VIRIDIAN_CITY_MART, routines active, zero
  errors; companion spawn refused 3× with "world is busy" during the
  continue transition (expected — the stepped retry is armed, and the
  headless driver never steps the player).

## What still needs in-game eyes (cannot be verified headless)

- Whether the emote actually renders over the engaging trainer (target
  resolution is the risky part), in 2D and voxel.
- Companion spawn cell choice, following feel, and the catch-up swap.
- The Gen 3 screen's rendering inside the GBA frame.
- Whether Yellow's Pikachu follower suppression reads as intended.
- Shiny forcing on a real Gen 2/3 wild battle.
