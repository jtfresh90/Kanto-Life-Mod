-- Kanto Life 0.8.96 — public voxel sleep renderer for Porygonal compatibility
return function(mod)
  local function loadBundled(rel)
    local src, err = mod:read(rel)
    if type(src) ~= "string" then return nil, err end
    local chunk, ce = (loadstring or load)(src, "@" .. mod.path .. "/" .. rel)
    if not chunk then return nil, ce end
    local ok, value = pcall(chunk)
    if not ok then return nil, value end
    return value
  end
  -- Cross-map traveler pool: when an NPC exits through a door/warp to a
  -- DIFFERENT map, they are recorded here instead of being replaced on the
  -- same map. When the player enters the destination map, the traveler
  -- spawns at the entrance connecting from their origin map.
  -- Combinatorial dialogue generator: unique lines via template+slot
  -- expansion with per-NPC history (see lib/DialogueGen.lua).
  local DialogueGen = loadBundled("lib/DialogueGen.lua")
  -- travelers[destMapId] = { {sprite, name, gender, agenda, fromMap, timestamp}, ... }
  local travelers = {}
  local TRAVELER_EXPIRY = 600  -- seconds; discard if player never visits

  local function pruneTravelers()
    local now = os.time()
    for destMap, list in pairs(travelers) do
      local kept = {}
      for _, t in ipairs(list) do
        if now - (t.timestamp or 0) < TRAVELER_EXPIRY then
          kept[#kept + 1] = t
        end
      end
      if #kept > 0 then travelers[destMap] = kept
      else travelers[destMap] = nil end
    end
  end

  -- Called by KantoRoutines when an NPC reaches a door/exit destination.
  -- If the door leads to a different map, record the NPC as a traveler
  -- (to spawn when the player enters that map) and remove them here.
  -- Returns true if handled (no same-map replacement), false otherwise.
  local function onRoutineExit(npc, world, old)
    -- old = {x, y, kind, destMap, destX, destY, "warp", warpDef}
    local destMap = old and old[4]
    destMap = destMap and tostring(destMap) or ""
    local currentMap = world and world.map and tostring(world.map.id or "") or ""
    if destMap == "" or destMap == currentMap then
      return false  -- same map or unknown; let normal replacement handle it
    end
    -- Cross-map exit: record traveler
    local d = npc and npc.def or {}
    travelers[destMap] = travelers[destMap] or {}
    table.insert(travelers[destMap], {
      sprite = d.sprite,
      name = d.kantoLifeDisplayName or d.name,
      gender = d.kantoLifeGender,
      agenda = npc and npc._kantoLifeAgenda,
      fromMap = currentMap,
      timestamp = os.time(),
    })
    pruneTravelers()
    -- Remove the NPC from the current map (they went through the door)
    if npc and npc.id and world and type(world.removeNpc) == "function" then
      pcall(world.removeNpc, world, npc.id)
    end
    return true
  end

  -- Spawn pending travelers when the player enters their destination map.
  -- Each traveler appears at the entrance (door/warp) that connects from
  -- their origin map, creating the paired exit/entry effect.
  local function spawnTravelers(mapId, map)
    local pending = travelers[tostring(mapId or "")]
    if not pending or #pending == 0 then return end
    pruneTravelers()
    pending = travelers[tostring(mapId or "")]
    if not pending or #pending == 0 then return end

    local ow = mod.world and mod.world:overworld()
    if not ow or not map then return end

    -- Build a lookup of entrances: which warp on THIS map leads to each
    -- connected map. The traveler came from `fromMap`, so they appear at
    -- the door that connects this map to fromMap.
    local entrances = {}  -- fromMapId -> {x, y}
    for _, w in ipairs((map.def and map.def.warps) or {}) do
      if w.x ~= nil and w.y ~= nil then
        local dest = w.destMap or w.map
        if dest then
          dest = tostring(dest)
          if entrances[dest] == nil then
            entrances[dest] = { tonumber(w.x), tonumber(w.y) }
          end
        end
      end
    end

    local spawned = 0
    local remaining = {}
    for _, t in ipairs(pending) do
      local entrance = entrances[t.fromMap]
      if entrance then
        -- Spawn adjacent to the entrance (not on top of it)
        local x, y = entrance[1], entrance[2] + 1
        local name = "KANTO_TRAVELER_" .. tostring(mapId) .. "_" .. tostring(spawned)
        -- Use a simple counter for unique names
        local ok, id = pcall(function()
          return mod.world:spawnNpc(tostring(mapId), {
            name = name,
            sprite = t.sprite,
            x = x, y = y,
            text = "",
            movement = "WALK",
            range = "ANY_DIR",
            radius = { x = 8, y = 8 },
            kantoLifeAmbient = true,
            kantoLifeDisplayName = t.name,
            kantoLifeGender = t.gender,
          })
        end)
        if ok and id then
          spawned = spawned + 1
          -- Tag the NPC with the traveler's agenda if available
          -- EXPERIMENTAL: arrival greeting — travelers announce themselves
          -- with a brief text bubble when they appear at the entrance.
          pcall(function()
            for _, n in ipairs(ow.npcs or {}) do
              if n.id == id then
                n._kantoLifeAgenda = t.agenda
                local greetings = {
                  "Phew, made it!",
                  "Here I am!",
                  "What a walk!",
                  "Finally here!",
                  "Hello there!",
                }
                local g = greetings[math.random(1, #greetings)]
                local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
                n._kantoLifeCollisionBubbleText = g
                n._kantoLifeCollisionBubbleUntil = now + 2.5
                break
              end
            end
          end)
        else
          remaining[#remaining + 1] = t
        end
      else
        -- No entrance found from this origin; keep for later (maybe player
        -- entered via a different route, or the map data is incomplete)
        remaining[#remaining + 1] = t
      end
    end

    if #remaining > 0 then travelers[tostring(mapId)] = remaining
    else travelers[tostring(mapId)] = nil end
  end

  -- Prefer mod.game (loader facade on 0.1.8x+). Fall back to mod.world.game
  -- for older engines where only WorldAPI carried the live reference.
  local function resolveGame()
    -- Re-resolve each time: on 0.1.84+ the loader may bind mod.game after
    -- entry starts, and Gen2 boots expose the live owner via world/game.ready.
    if mod.game ~= nil then return mod.game end
    local w = mod.world
    if w and w.game ~= nil then return w.game end
    -- Last resort: WorldAPI sometimes keeps the reference only on the API.
    if w and type(w.getGame) == "function" then
      local ok, g = pcall(w.getGame, w)
      if ok and g ~= nil then return g end
    end
    return nil
  end
  -- Convenience: most call sites still say `game`; keep a local that tracks
  -- the latest resolve so existing code works without a full rewrite.
  local game = resolveGame()
  local function G()
    game = resolveGame() or game
    return game
  end

  -- =====================================================================
  -- Renderer-stack compatibility
  --
  -- Kanto Life does not replace any renderer.  Battle Art owns the voxel
  -- scene, Porygonal supplies human character models through Battle Art's
  -- CharacterRenderers API, and Legendary Stadium supplies Pokemon models.
  -- Terrarium owns its own Routines/Shelter update loop.  These bridges only
  -- publish the metadata those mods already consume and prevent duplicate
  -- agenda/routine ownership when Terrarium is present.
  -- =====================================================================
  local function findInstalled(id)
    if not mod or type(mod.find) ~= "function" then return nil end
    local ok, found = pcall(mod.find, id)
    return ok and found or nil
  end

  local function stadiumOverworld()
    local m = findInstalled("LEGENDARY_STADIUM_OVERWORLD_MODELS")
    local ex = m and m.exports
    local ow = ex and ex.overworld
    if type(ow) == "table" and type(ow.tag) == "function" then return ow end
    return nil
  end

  local function terrariumRoutines()
    local m = findInstalled("TERRARIUM")
    local ex = m and m.exports
    local lib = ex and ex.lib
    if type(lib) ~= "table" or type(lib.require) ~= "function" then return nil end
    local ok, r = pcall(lib.require, "Routines")
    return ok and type(r) == "table" and r or nil
  end

  local function syncTerrariumSettings()
    local r = terrariumRoutines()
    if not r then return false end
    local g = G()
    local mode = math.floor(tonumber(opt("npc_agenda")) or 0)
    if mode < 0 then mode = 0 elseif mode > 2 then mode = 2 end
    if r.agendaSetting and type(r.agendaSetting.setIndex) == "function" then
      pcall(r.agendaSetting.setIndex, r.agendaSetting, mode + 1, g)
    end
    local routineOn = opt("npc_routines") and true or false
    if r.setting and type(r.setting.setIndex) == "function" then
      pcall(r.setting.setIndex, r.setting, routineOn and 1 or 2, g)
    end
    return true
  end

  local function tagKantoPokemon(npc, species)
    if not npc or not species then return end
    -- Stadium has an explicit tag API.  This is stronger than sprite-name
    -- inference and remains valid when HGSS/Porygonal changes the sprite
    -- definition underneath the NPC.
    local ow = stadiumOverworld()
    if ow then pcall(ow.tag, npc, species) end
    -- Terrarium's Routines excludes its own RoamerArt species via this
    -- metadata.  Keep Kanto Life's Pokemon under Kanto Life's population
    -- controller so the two agenda systems never fight over one actor.
    if terrariumRoutines() then
      npc.def = npc.def or {}
      npc.def.dsSpecies = species
    end
  end

  local function markKantoAmbientForTerrarium(npc)
    if not npc or not terrariumRoutines() then return end
    local d = npc.def or {}
    if d.kantoLifeAmbient and not d.kantoLifePokeAmbient then
      d.dsSpecies = d.dsSpecies or "KANTO_LIFE_AMBIENT"
      npc.def = d
    elseif npc._kantoServiceTraffic then
      d.dsSpecies = d.dsSpecies or "KANTO_LIFE_TRAFFIC"
      npc.def = d
    end
  end

  -- Gen 2 (Gold/Silver/Crystal) exposes OverworldController as a DISPATCH
  -- facade, not the live state singleton. Method-patching it the Gen 1 way
  -- crashes (e.g. takeWarp(warpDef) has no self). Gate invasive patches.
  local function engineGeneration()
    local g = G()
    if g and g.generation then return tonumber(g.generation) or 1 end
    if g and g.gameVersion and g.gameVersion.generation then
      return tonumber(g.gameVersion.generation) or 1
    end
    local ok, GV = pcall(require, "src.core.GameVersion")
    if ok and GV and type(GV.generation) == "function" then
      local ok2, gen = pcall(GV.generation)
      if ok2 and gen then return tonumber(gen) or 1 end
    end
    -- Gold boots often leave Gen1-only modules as facades without .interact body
    return 1
  end

  local function isGen1Boot()
    local gen = engineGeneration()
    if gen == 2 then return false end
    if gen == 1 then return true end
    -- Fallback: Gen2 OverworldController facade has no isOverworld flag
    local ok, OW = pcall(require, "src.world.OverworldController")
    if ok and type(OW) == "table" and OW.isOverworld == nil and type(OW.takeWarp) == "function" then
      -- Gen1 OverworldState sets isOverworld = true on the module table
      if OW.isOpaque == nil and OW.enter == nil then
        return false
      end
    end
    return true
  end

  -- ------- Options schema (mod manager + native OPTIONS menu via ui.options.rows)
  mod.options:define({
    { key = "extra_npcs", type = "toggle", label = "EXTRA NPCS", default = true },
    { key = "extra_npc_count", type = "number", label = "EXTRA NPC COUNT",
      default = 0, min = 0, max = 150, step = 1 },
    { key = "indoor_npcs", type = "toggle", label = "INDOOR NPCS", default = true },
    { key = "indoor_npc_count", type = "number", label = "INDOOR NPC COUNT",
      default = 3, min = 0, max = 30, step = 1 },
    { key = "poke_npcs", type = "toggle", label = "POKEMON NPCS", default = false },
    { key = "poke_npc_count", type = "number", label = "POKEMON NPC COUNT",
      default = 0, min = 0, max = 50, step = 1 },
    { key = "poke_random", type = "toggle", label = "RANDOM POKE NPCS", default = true },
    { key = "sleeping_npcs", type = "toggle", label = "SLEEPING NPCS", default = true },
    { key = "sleep_pct", type = "number", label = "SLEEP RATE %",
      default = 30, min = 0, max = 100, step = 10 },
    { key = "day_sleepers", type = "toggle", label = "DAY SLEEPERS", default = true },
    { key = "sleep_bubbles", type = "toggle", label = "SLEEP ZZZ", default = true },
    { key = "sleep_style", type = "choice", label = "SLEEP STYLE", default = 0, choices = { { "Default", 0 }, { "Tent", 1 }, { "Sleeping Bag", 2 }, { "Bed", 3 } } },
    { key = "npc_collision_bubbles", type = "toggle", label = "NPC TALK BUBBLES", default = true },
    { key = "common_courtesy", type = "toggle", label = "DOOR KNOCKING", default = true },
    { key = "npc_routines", type = "toggle", label = "NPC ROUTINES", default = true },
    { key = "npc_travel_pct", type = "number", label = "NPC TRAVEL %",
      default = 30, min = 0, max = 100, step = 10 },
    { key = "npc_agenda", type = "choice", label = "NPC AGENDA",
      choices = { { "OFF", 0 }, { "DAY", 1 }, { "FULL", 2 } }, default = 0 },
  })

  local function opt(key)
    if mod.options and type(mod.options.get) == "function" then
      local v = mod.options:get(key)
      if v ~= nil then return v end
    end
    local g = G and G() or game
    if g and g.mods and g.mods.modOptions and g.mods.modOptions[mod.id] then
      local v = g.mods.modOptions[mod.id][key]
      if v ~= nil then return v end
    end
    if g and g.save and g.save.options and g.save.options.modOptions
       and g.save.options.modOptions[mod.id] then
      local v = g.save.options.modOptions[mod.id][key]
      if v ~= nil then return v end
    end
    return nil
  end

  -- Per-map defaults used only when EXTRA NPCS is turned ON while count is 0.
  local townDefaults = {
    SAFFRON_CITY = 150, CELADON_CITY = 150, FUCHSIA_CITY = 150,
    VERMILION_CITY = 150, CERULEAN_CITY = 50, PEWTER_CITY = 50,
    VIRIDIAN_CITY = 30, LAVENDER_TOWN = 30, CINNABAR_ISLAND = 12,
    PALLET_TOWN = 12,
  }
  local ROUTE_DEFAULT = 10

  local lines = {
    "I'm headed to the\nMART before sunset.",
    "My PIDGEY loves\ncity walks!",
    "I heard a TRAINER\nbeat the GYM today!",
    "I'm visiting family\nin the next town.",
    "KANTO feels busy\nthese days!",
    "My partner is\nresting at the CENTER.",
    "I travel light so I\ncan take the long road.",
    "Have you checked\nthe local GYM?",
    "The weather is\nperfect for a stroll!",
    "I just bought a\nnew POTION!",
    "Watch out for wild\nPOKéMON on the road!",
    "My friend lives in\nCERULEAN CITY.",
    "I want to challenge\nthe next GYM!",
    "Have you seen any\nrare POKéMON?",
    "The PC is so handy\nat the CENTER.",
    "I'm saving up for\na BICYCLE!",
    "TEAM ROCKET better\nstay away from here!",
    "I love the music in\nthis town!",
    "Don't step on the\nflower beds!",
    "My little brother\nwants a RATTATA.",
    "The MART has great\ndeals today!",
    "I'm training hard\nfor the LEAGUE!",
    "This place looks\nbetter at night.",
    "Excuse me, do you\nknow the way?",
  }

  local routeLines = {
    "I'm traveling\nbetween towns today.",
    "These routes are\nfull of TRAINERS!",
    "I spotted a rare\nPOKéMON earlier!",
    "Don't get lost on\nthe long road.",
    "My team needs more\nexperience points.",
    "Tall grass hides\nplenty of surprises!",
    "I'm headed to the\nnext city soon.",
    "Watch your step\nnear the cliffs!",
  }


  -- Johto-port: gendered English names for ambient + default NPCs
  local MALE_NAMES = {
    "Aaron","Adam","Alex","Andrew","Ben","Blake","Brian","Caleb","Carlos","Chris",
    "Daniel","David","Derek","Dylan","Eric","Ethan","Felix","Frank","George","Greg",
    "Henry","Ian","Jack","James","Jason","Joel","John","Jordan","Kevin","Kyle",
    "Leo","Liam","Lucas","Mark","Mason","Matt","Max","Nathan","Nick","Noah",
    "Owen","Paul","Peter","Ray","Ryan","Sam","Scott","Sean","Steve","Tom","Tony","Tyler","Will","Zack",
  }
  local FEMALE_NAMES = {
    "Alice","Amy","Anna","Ashley","Beth","Brooke","Carla","Chloe","Claire","Dana",
    "Diana","Elena","Emma","Erin","Faye","Grace","Hannah","Helen","Iris","Jane",
    "Jenny","Jill","Joy","Kate","Kelly","Laura","Lily","Lisa","Lucy","Maria",
    "Mary","Megan","Mia","Molly","Nancy","Nina","Olivia","Paige","Rachel","Rose",
    "Ruby","Sara","Sofia","Sue","Tina","Vera","Wendy","Zoe",
  }
  local function genderFromSprite(spr)
    spr = tostring(spr or ""):upper()
    if spr:find("HIKER", 1, true) or spr:find("FISHER", 1, true) then return "m" end
    if spr:find("BALDING", 1, true) or spr:find("MIDDLE_AGED_MAN", 1, true) then return "m" end
    if spr:find("FAT", 1, true) or spr:find("GENTLEMAN", 1, true) then return "m" end
    if spr:find("SAILOR", 1, true) or spr:find("BIKER", 1, true) then return "m" end
    if spr:find("GAMBLER", 1, true) or spr:find("YOUNGSTER", 1, true) then return "m" end
    if spr:find("BUG_CATCHER", 1, true) or spr:find("SUPER_NERD", 1, true) then return "m" end
    if spr:find("ROCKER", 1, true) or spr:find("COOLTRAINER_M", 1, true) then return "m" end
    if spr:find("GUARD", 1, true) or spr:find("WAITER", 1, true) then return "m" end
    if spr:find("COOK", 1, true) or spr:find("ROCKET", 1, true) then return "m" end
    if spr:find("OLD_MAN", 1, true) or spr:find("LITTLE_BOY", 1, true) then return "m" end
    if spr:find("LASS", 1, true) or spr:find("BEAUTY", 1, true) then return "f" end
    if spr:find("LITTLE_GIRL", 1, true) or spr:find("GIRL", 1, true) then return "f" end
    if spr:find("CHANNELER", 1, true) or spr:find("NURSE", 1, true) then return "f" end
    if spr:find("COOLTRAINER_F", 1, true) or spr:find("DAISY", 1, true) then return "f" end
    if spr:find("MEDIUM", 1, true) or spr:find("MOM", 1, true) then return "f" end
    if spr:find("_F$") or spr:find("_F_") then return "f" end
    if spr:find("_M$") or spr:find("_M_") then return "m" end
    return "m"
  end
  local function genderFromNpc(npc)
    if not npc then return "m" end
    local d = npc.def or {}
    local spr = d.sprite or npc.spriteId
    if npc.sprite and type(npc.sprite.id) == "string" then spr = npc.sprite.id end
    return genderFromSprite(spr)
  end
  local function randomName(g)
    local pool = (g == "f") and FEMALE_NAMES or MALE_NAMES
    return pool[love.math.random(#pool)]
  end
  local function stableNameFor(npc)
    local d = npc.def or {}
    local seed = table.concat({
      tostring(d.sprite or ""), tostring(d.index or ""), tostring(npc.id or ""),
      tostring(npc.cellX or ""), tostring(npc.cellY or ""), tostring(d.name or ""),
    }, ":")
    local h = 2166136261
    for i = 1, #seed do h = (h * 16777619 + seed:byte(i)) % 2147483647 end
    local pool = (genderFromNpc(npc) == "f") and FEMALE_NAMES or MALE_NAMES
    return pool[(h % #pool) + 1]
  end

  local talkRegistered = {}
  -- Serial so every ambient name is unique even across re-spawns.
  local spawnSerial = 0

  -- Ambient Pokemon NPCs are OUR cosmetic interactables, never Wilds wilds.
  -- They use the same outdoor/indoor counts as human extras when POKEMON NPCS is on.
  local POKE_WATER = {
    "PSYDUCK", "POLIWAG", "TENTACOOL", "SLOWPOKE", "SEEL", "SHELLDER",
    "KRABBY", "HORSEA", "GOLDEEN", "STARYU", "MAGIKARP", "OMANYTE",
    "KABUTO", "LAPRAS", "VAPOREON",
  }
  local WATER_SPECIES = {}
  for _, s in ipairs(POKE_WATER) do WATER_SPECIES[s] = true end
  local function isWaterSpecies(sp)
    if type(sp) ~= "string" then return false end
    sp = sp:upper()
    if WATER_SPECIES[sp] then return true end
    local data = game and game.data and game.data.pokemon and game.data.pokemon[sp]
    if type(data) == "table" and type(data.types) == "table" then
      for _, ty in ipairs(data.types) do
        if tostring(ty):upper() == "WATER" then return true end
      end
    end
    return false
  end
  local POKE_LAND = {
    "PIDGEY", "RATTATA", "SPEAROW", "EKANS", "PIKACHU", "SANDSHREW",
    "NIDORAN_F", "NIDORAN_M", "VULPIX", "ZUBAT", "ODDISH", "PARAS",
    "MEOWTH", "MANKEY", "GROWLITHE", "ABRA", "MACHOP", "BELLSPROUT",
    "GEODUDE", "PONYTA", "MAGNEMITE", "FARFETCHD", "DODUO", "GRIMER",
    "GASTLY", "ONIX", "DROWZEE", "VOLTORB", "EXEGGCUTE", "CUBONE",
    "HITMONLEE", "KOFFING", "RHYHORN", "CHANSEY", "TANGELA", "EEVEE",
    "AERODACTYL", "SNORLAX", "DRATINI", "JIGGLYPUFF", "CLEFAIRY",
  }
  -- Full pool for RANDOM POKE NPCS (any species).
  local POKE_LEGENDARY = {
    "ARTICUNO", "ZAPDOS", "MOLTRES", "MEWTWO", "MEW",
  }
  local POKE_SPECIES = {}
  for _, s in ipairs(POKE_LAND) do POKE_SPECIES[#POKE_SPECIES + 1] = s end
  for _, s in ipairs(POKE_WATER) do POKE_SPECIES[#POKE_SPECIES + 1] = s end
  for _, s in ipairs(POKE_LEGENDARY) do POKE_SPECIES[#POKE_SPECIES + 1] = s end

  -- When RANDOM is on, prefer the full dex from game data (includes legendaries).
  local function fullDexSpecies()
    local out, seen = {}, {}
    local function add(sp)
      if type(sp) ~= "string" or sp == "" then return end
      sp = sp:upper()
      if seen[sp] then return end
      seen[sp] = true
      out[#out + 1] = sp
    end
    local data = game and game.data and game.data.pokemon
    if type(data) == "table" then
      for id, _ in pairs(data) do
        if type(id) == "string" then add(id) end
      end
    end
    if #out == 0 then
      for _, s in ipairs(POKE_SPECIES) do add(s) end
    end
    return out
  end

  local TOWN_FALLBACK = {
    "PIKACHU", "CLEFAIRY", "JIGGLYPUFF", "MEOWTH", "PSYDUCK",
    "EEVEE", "VULPIX", "GROWLITHE", "SLOWPOKE", "CHANSEY",
  }

  local function speciesDisplayName(species)
    return tostring(species or "POKEMON"):gsub("_", " ")
  end

  local function resolvePokeSprite(species)
    local data = game.data
    if not data then return nil end
    local sprites = data.sprites or {}
    local candidates = {
      species,
      "SPRITE_" .. tostring(species),
      "SPRITE_POKEMON_" .. tostring(species),
    }
    -- Some ports key overworld art under pokemon def fields.
    local pdef = data.pokemon and data.pokemon[species]
    if type(pdef) == "table" then
      for _, k in ipairs({ "overworldSprite", "sprite", "fieldSprite", "owSprite" }) do
        if pdef[k] then candidates[#candidates + 1] = pdef[k] end
      end
    end
    for _, c in ipairs(candidates) do
      if c and sprites[c] then return c end
    end
    -- Fall back: any sprite whose id contains the species name.
    local up = tostring(species):upper()
    for id, _ in pairs(sprites) do
      if tostring(id):upper():find(up, 1, true) and not tostring(id):upper():find("BACK", 1, true) then
        return id
      end
    end
    return nil
  end

  local function playSpeciesCry(species)
    pcall(function()
      if not species then return end
      local ChipAudio = require("src.core.ChipAudio")
      if ChipAudio and ChipAudio.newCry and game.data then
        local cry = ChipAudio.newCry(game.data, species)
        local g = G() or game
        if cry and g and g.audio and g.audio.play then
          g.audio:play(cry)
        elseif cry and cry.play then
          cry:play()
        end
      end
    end)
    pcall(function()
      local Sound = require("src.core.Sound")
      if Sound and Sound.playCry then Sound.playCry(G() or game, species) end
    end)
  end



  local function isTown(mapId) return townDefaults[mapId] ~= nil end
  local function isRoute(mapId)
    return type(mapId) == "string" and mapId:match("^ROUTE_") ~= nil
  end
  -- Indoor building maps. Prefer the engine's authoritative tileset id so
  -- this covers every building (Marts, Centers, Gyms, Labs, Silph, ships,
  -- department stores, etc.) instead of maintaining a house-name list.
  -- Organic/outdoor tilesets are deliberately excluded: caves, forests,
  -- routes, the plateau and the overworld are not buildings.
  local INDOOR_BUILDING_TILESETS = {
    GATE = true, FOREST_GATE = true, MUSEUM = true,
    POKECENTER = true, MART = true, GYM = true, DOJO = true,
    REDS_HOUSE_1 = true, REDS_HOUSE_2 = true, FACILITY = true,
    HOUSE = true, INTERIOR = true, LAB = true, LOBBY = true,
    MANSION = true, SHIP = true, CLUB = true,
  }
  local function isIndoor(mapId, map)
    if not mapId then return false end
    local id = tostring(mapId)
    if isTown(id) or isRoute(id) then return false end
    local tileset = map and map.def and map.def.tileset
    if not tileset and map and map.tileset then
      tileset = map.tileset.id or map.tileset.name or map.tileset
    end
    tileset = tileset and tostring(tileset):upper() or nil
    if tileset and INDOOR_BUILDING_TILESETS[tileset] then return true end
    -- Tower floors use the CEMETERY art tileset but are indoor rooms.
    if tileset == "CEMETERY" and id:find("TOWER", 1, true) then return true end
    -- Compatibility fallback for custom maps that use descriptive ids.
    if id:find("HOUSE", 1, true) or id:find("GATE", 1, true) then return true end
    if id:find("_1F", 1, true) or id:find("_2F", 1, true)
       or id:find("_3F", 1, true) or id:find("_4F", 1, true)
       or id:find("_5F", 1, true) or id:find("_B1F", 1, true) then return true end
    if id:find("DEPT", 1, true) or id:find("MUSEUM", 1, true)
       or id:find("GAME_CORNER", 1, true) or id:find("HOTEL", 1, true)
       or id:find("MART", 1, true) or id:find("POKECENTER", 1, true)
       or id:find("POKEMON_CENTER", 1, true) or id:find("GYM", 1, true)
       or id:find("LAB", 1, true) or id:find("SILPH", 1, true) then return true end
    return false
  end

  -- Never treat Pokemon / Wilds entities as civilian human sprites.
  local function isPokemonLike(npc)
    if not npc then return true end
    if npc.pikachuFollower then return true end
    if npc.wild or npc.isWild or npc.wildPokemon then return true end
    local d = npc.def or {}
    if d.kantoLifePokeAmbient or npc.kantoLifePokeAmbient then return true end
    -- Trainers often have d.pokemon as a party table — do NOT treat that as OW mon.
    if type(d.species) == "string" then return true end
    if type(d.pokemon) == "string" then return true end
    if d.wild then return true end
    if d.kantoLifeAmbient then return false end
    local sprite = tostring(d.sprite or ""):upper()
    local name = tostring(d.name or ""):upper()
    if sprite:find("POKEFAN", 1, true) then return false end
    if sprite:find("PIKACHU", 1, true) or name:find("PIKACHU", 1, true) then return true end
    if sprite:find("POKEMON", 1, true) then return true end
    if sprite:find("SPRITE_POKE_", 1, true) then return true end
    if sprite:find("BALL", 1, true) or sprite:find("FOSSIL", 1, true) then return true end
    if tostring(d.name or ""):match("^WILD") or tostring(d.name or ""):match("^FOLLOW") then return true end
    if d.overworldWild or d.follower or d.isFollower then return true end
    return false
  end

  -- Follower/companion Pokémon belong to their character/follower mods.
  -- Never let Kanto Life sleep, schedule, or replace their sprite.
  local function isPokemonFollower(npc)
    if not npc then return false end
    if npc.pikachuFollower or npc.isFollower or npc.follower
       or npc.pokemonFollower or npc.partyFollower
       or npc.followingPlayer or npc.followsPlayer
       or npc.isCompanion or npc.companion then return true end
    local d = type(npc.def) == "table" and npc.def or {}
    if d.follower or d.isFollower or d.pokemonFollower or d.partyFollower
       or d.followingPlayer or d.followsPlayer
       or d.isCompanion or d.companion then return true end
    local id = tostring(npc.id or npc.name or d.name or d.sprite or ""):upper()
    if (id:find("FOLLOWER",1,true) or id:find("COMPANION",1,true))
       and (npc.wild or npc.isWild or npc.wildPokemon or d.wild
            or type(d.species)=="string" or type(d.pokemon)=="string"
            or id:find("POKEMON",1,true) or id:find("PIKACHU",1,true)
            or id:find("GROWLITHE",1,true)) then return true end
    return false
  end

  -- Gen1Recomp has trainer-class constants such as SPRITE_BUG_CATCHER, but
  -- those are NOT necessarily registered overworld sprite IDs.  In Yellow,
  -- SPRITE_BUG_CATCHER is a trainer-class name and NPC.lua correctly rejects
  -- it as an overworld sprite.  Never pass an unregistered sprite through to
  -- world:spawnNpc().
  local KNOWN_GEN1_CIVILIAN_SPRITES = {
    "SPRITE_YOUNGSTER", "SPRITE_COOLTRAINER_F", "SPRITE_COOLTRAINER_M",
    "SPRITE_LITTLE_GIRL", "SPRITE_MIDDLE_AGED_MAN", "SPRITE_GAMBLER",
    "SPRITE_SUPER_NERD", "SPRITE_GIRL", "SPRITE_HIKER", "SPRITE_BEAUTY",
    "SPRITE_GENTLEMAN", "SPRITE_BIKER", "SPRITE_SAILOR", "SPRITE_COOK",
    "SPRITE_ROCKET", "SPRITE_CHANNELER", "SPRITE_WAITER",
    "SPRITE_SILPH_WORKER_F", "SPRITE_MIDDLE_AGED_WOMAN",
    "SPRITE_BRUNETTE_GIRL", "SPRITE_SCIENTIST", "SPRITE_ROCKER",
    "SPRITE_SWIMMER", "SPRITE_SAFARI_ZONE_WORKER", "SPRITE_GYM_GUIDE",
    "SPRITE_GRAMPS", "SPRITE_CLERK", "SPRITE_FISHING_GURU", "SPRITE_GRANNY",
  }
  local KNOWN_GEN1_CIVILIAN_SET = {}
  for _, id in ipairs(KNOWN_GEN1_CIVILIAN_SPRITES) do KNOWN_GEN1_CIVILIAN_SET[id] = true end

  local function isRegisteredOverworldSprite(sprite)
    if type(sprite) ~= "string" or sprite == "" then return false end
    local data = game and game.data
    local registry = data and data.sprites
    if type(registry) == "table" and registry[sprite] ~= nil then return true end
    -- The whitelist is deliberately conservative when data.sprites is not
    -- available during an early spawn pass.  It contains only actual Yellow
    -- overworld sprite IDs from the imported ROM manifest.
    return KNOWN_GEN1_CIVILIAN_SET[sprite] == true
  end

  local function isHumanCivilianSprite(sprite)
    if not sprite then return false end
    local raw = tostring(sprite)
    local s = raw:upper()
    if not isRegisteredOverworldSprite(raw) then return false end
    if s:find("PIKACHU", 1, true) or s:find("POKEMON", 1, true) then return false end
    if s:find("POKE", 1, true) or s:find("BALL", 1, true) or s:find("FOSSIL", 1, true) then return false end
    if s:find("MON_", 1, true) or s:find("_MON", 1, true) then return false end
    return true
  end
  local function defaultCount(mapId)
    if townDefaults[mapId] then return townDefaults[mapId] end
    if isRoute(mapId) then return ROUTE_DEFAULT end
    return 0
  end

  -- Absolute target: outdoor uses EXTRA NPC COUNT; indoor uses INDOOR NPC COUNT.
  local function targetCount(mapId, map)
    if isIndoor(mapId, map) then
      if not opt("indoor_npcs") then return 0 end
      local n = math.floor(tonumber(opt("indoor_npc_count")) or 0)
      if n < 0 then n = 0 end
      if n > 30 then n = 30 end
      return n
    end
    if not opt("extra_npcs") then return 0 end
    local n = math.floor(tonumber(opt("extra_npc_count")) or 0)
    if n < 0 then n = 0 end
    if n > 150 then n = 150 end
    return n
  end

  -- Pokemon ambient NPCs use their OWN count; human EXTRA NPC COUNT never drives them.
  local function pokeTargetCount(mapId, map)
    if not opt("poke_npcs") then return 0 end
    if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId, map)) then return 0 end
    local n = math.floor(tonumber(opt("poke_npc_count")) or 0)
    if n < 0 then n = 0 end
    if n > 50 then n = 50 end
    return n
  end

  -- Forward declaration: option-change handlers run before the sleep implementation is declared.
  -- Keeping this local prevents Lua from resolving wakeNpc as a nil global.
  local wakeNpc

  local function setOpt(key, value)
    local g = G() or game
    -- Keep mod.options in sync so opt() / refresh see the new value immediately
    if mod.options and type(mod.options.set) == "function" then
      pcall(function() mod.options:set(key, value) end)
    end
    local loader = g and g.mods
    if loader then
      loader.modOptions = loader.modOptions or {}
      loader.modOptions[mod.id] = loader.modOptions[mod.id] or {}
      loader.modOptions[mod.id][key] = value
      if loader.loader then
        loader.loader.modOptions = loader.loader.modOptions or {}
        loader.loader.modOptions[mod.id] = loader.loader.modOptions[mod.id] or {}
        loader.loader.modOptions[mod.id][key] = value
      end
    end
    if g and g.save and g.save.options then
      g.save.options.modOptions = g.save.options.modOptions or {}
      g.save.options.modOptions[mod.id] = g.save.options.modOptions[mod.id] or {}
      g.save.options.modOptions[mod.id][key] = value
    end
    pcall(function()
      local SaveData = require("src.core.SaveData")
      local opts = SaveData.loadOptions((g and g.fs) or nil)
      if type(opts) ~= "table" then return end
      opts.modOptions = opts.modOptions or {}
      opts.modOptions[mod.id] = opts.modOptions[mod.id] or {}
      opts.modOptions[mod.id][key] = value
      SaveData.saveOptions(opts, (g and g.fs) or nil)
    end)
    if loader and loader.events and loader.events.emit then
      loader.events:emit("mod.options_changed",
        { mod = mod.id, key = key, value = value })
    end
  end

  -- NPC AGENDA persistence:
  -- First-ever initialization is explicitly OFF. Once the player chooses
  -- OFF/DAY/FULL, keep that value in the normal mod-options save so it is
  -- restored on every subsequent launch instead of re-defaulting.
  local function ensureNpcAgendaPersistence()
    local g = G() or game
    local saved = nil
    local ok, SaveData = pcall(require, "src.core.SaveData")
    if ok and SaveData and type(SaveData.loadOptions) == "function" then
      local ok2, opts = pcall(SaveData.loadOptions, (g and g.fs) or nil)
      if ok2 and type(opts) == "table" then
        local mo = opts.modOptions and opts.modOptions[mod.id]
        if type(mo) == "table" and mo.npc_agenda ~= nil then
          saved = tonumber(mo.npc_agenda)
        end
      end
    end
    if saved == nil and g and g.save and g.save.options
       and g.save.options.modOptions and g.save.options.modOptions[mod.id] then
      saved = tonumber(g.save.options.modOptions[mod.id].npc_agenda)
    end
    if saved == nil and g and g.mods and g.mods.modOptions
       and g.mods.modOptions[mod.id] then
      saved = tonumber(g.mods.modOptions[mod.id].npc_agenda)
    end
    if saved == nil then
      -- No prior value exists: establish the one-time default of OFF.
      setOpt("npc_agenda", 0)
    else
      saved = math.floor(saved)
      if saved < 0 then saved = 0 elseif saved > 2 then saved = 2 end
      -- Rehydrate the UI/options layer from the saved value without changing it.
      if tonumber(opt("npc_agenda")) ~= saved then setOpt("npc_agenda", saved) end
    end
  end

  local function occupied(ow, x, y)
    for _, e in ipairs(ow.entities or {}) do
      if e.cellX == x and e.cellY == y then return true end
    end
    for _, n in ipairs(ow.npcs or {}) do
      if n.cellX == x and n.cellY == y then return true end
    end
    return false
  end

  local function nearWarp(map, x, y)
    if not map then return false end
    if map:warpAtCell(x, y) then return true end
    for dx = -1, 1 do
      for dy = -1, 1 do
        if not (dx == 0 and dy == 0) and map:warpAtCell(x + dx, y + dy) then
          return true
        end
      end
    end
    return false
  end

  local function isWaterCell(map, x, y)
    if not map or x == nil or y == nil then return false end
    if type(map.isWaterCell) == "function" then
      local ok, v = pcall(function() return map:isWaterCell(x, y) end)
      if ok and v then return true end
    end
    if type(map.waterAt) == "function" then
      local ok, v = pcall(function() return map:waterAt(x, y) end)
      if ok and v then return true end
    end
    if type(map.isWater) == "function" then
      local ok, v = pcall(function() return map:isWater(x, y) end)
      if ok and v then return true end
    end
    return false
  end

  -- True playable land: in-bounds, walkable feet, not water, not warp-adjacent.
  local function inMapBounds(map, x, y)
    if not map or x == nil or y == nil then return false end
    local w = map.widthCells or map.width or 0
    local h = map.heightCells or map.height or 0
    if w < 4 or h < 4 then return false end
    return x >= 2 and y >= 2 and x <= (w - 3) and y <= (h - 3)
  end

  local function isLandWalkable(map, x, y)
    if not inMapBounds(map, x, y) then return false end
    if type(map.isWalkableCell) ~= "function" then return false end
    local ok, walk = pcall(function() return map:isWalkableCell(x, y) end)
    if not ok or not walk then return false end
    if isWaterCell(map, x, y) then return false end
    if nearWarp(map, x, y) then return false end
    return true
  end

  local function isWaterSpawnable(map, x, y)
    if not inMapBounds(map, x, y) then return false end
    if not isWaterCell(map, x, y) then return false end
    if nearWarp(map, x, y) then return false end
    return true
  end

  local function pickSpawnCell(ow, map)
    if not ow or not map then return nil, nil end
    local w = map.widthCells or map.width or 0
    local h = map.heightCells or map.height or 0
    if w < 4 or h < 4 then return nil, nil end
    local px = (ow.player and (ow.player.cellX or ow.player.x)) or math.floor(w / 2)
    local py = (ow.player and (ow.player.cellY or ow.player.y)) or math.floor(h / 2)
    px = math.floor(tonumber(px) or 0)
    py = math.floor(tonumber(py) or 0)
    for radius = 4, 18, 2 do
      for _ = 1, 40 do
        local tx = px + love.math.random(-radius, radius)
        local ty = py + love.math.random(-radius, radius)
        if isLandWalkable(map, tx, ty) and not occupied(ow, tx, ty) then
          return tx, ty
        end
      end
    end
    for _ = 1, 250 do
      local tx = love.math.random(2, math.max(2, w - 3))
      local ty = love.math.random(2, math.max(2, h - 3))
      if isLandWalkable(map, tx, ty) and not occupied(ow, tx, ty) then
        return tx, ty
      end
    end
    return nil, nil
  end

  local function pickSpawnCellFiltered(ow, map, wantWater)
    if not ow or not map then return nil, nil end
    local w = map.widthCells or map.width or 0
    local h = map.heightCells or map.height or 0
    if w < 4 or h < 4 then return nil, nil end
    local px = (ow.player and (ow.player.cellX or ow.player.x)) or math.floor(w / 2)
    local py = (ow.player and (ow.player.cellY or ow.player.y)) or math.floor(h / 2)
    px = math.floor(tonumber(px) or 0)
    py = math.floor(tonumber(py) or 0)
    local function okCell(tx, ty)
      if occupied(ow, tx, ty) then return false end
      if wantWater then return isWaterSpawnable(map, tx, ty) end
      return isLandWalkable(map, tx, ty)
    end
    for radius = 4, 20, 2 do
      for _ = 1, 50 do
        local tx = px + love.math.random(-radius, radius)
        local ty = py + love.math.random(-radius, radius)
        if okCell(tx, ty) then return tx, ty end
      end
    end
    for _ = 1, 280 do
      local tx = love.math.random(2, math.max(2, w - 3))
      local ty = love.math.random(2, math.max(2, h - 3))
      if okCell(tx, ty) then return tx, ty end
    end
    return nil, nil
  end

  local function civilianSprites(ow, mapId)
    local sprites, seen = {}, {}
    for _, npc in ipairs(ow.npcs or {}) do
      local d = npc.def or {}
      if d.kantoLifeAmbient then goto continue end
      if isPokemonLike(npc) then goto continue end
      local lyingViridianOldMan = mapId == "VIRIDIAN_CITY"
        and (tostring(d.sprite):find("OLD_MAN", 1, true)
          or tostring(d.name):find("OLD_MAN", 1, true))
      if d.sprite and not lyingViridianOldMan
         and isHumanCivilianSprite(d.sprite)
         and not d.trainerClass and not d.item and not d.pokemon
         and not seen[d.sprite] then
        seen[d.sprite] = true; sprites[#sprites + 1] = d.sprite
      end
      ::continue::
    end
    -- Fallback human town sprites if the map has none to sample.
    if #sprites == 0 then
      -- Do not use trainer-only constants here.  In particular,
      -- SPRITE_BUG_CATCHER is not a Yellow overworld sprite.
      for _, s in ipairs(KNOWN_GEN1_CIVILIAN_SPRITES) do
        if isRegisteredOverworldSprite(s) then
          sprites[#sprites + 1] = s
        end
      end
    end
    return sprites
  end

  local function ensureTalkScripts(mapId, count)
    if talkRegistered[mapId] and talkRegistered[mapId] >= count then return end
    local talk = {}
    local n = math.max(count, talkRegistered[mapId] or 0, 1)
    for i = 1, n do
      talk["KANTO_CROWD_" .. mapId .. "_" .. i] = {
        { "show_text", lines[((i - 1) % #lines) + 1] },
      }
    end
    pcall(function()
      mod.content.map_scripts:register(mapId, { talk = talk })
    end)
    talkRegistered[mapId] = n
  end

  local function isAmbientNpc(npc)
    if not npc then return false end
    local d = npc.def or {}
    if d.kantoLifeAmbient or d.kantoLifePokeAmbient then return true end
    local name = tostring(d.name or "")
    return name:match("^KANTO_(CROWD|ROUTE_NPC|POKE)_") ~= nil
  end

  local function isPokeAmbient(npc)
    if not npc then return false end
    local d = npc.def or {}
    if d.kantoLifePokeAmbient or npc.kantoLifePokeAmbient then return true end
    if tostring(d.name or ""):match("^KANTO_POKE_") then return true end
    return false
  end


  -- Species label for default/vanilla Pokemon NPCs (not random human names).
  local SPECIES_NAMES = {
    "NIDORAN_F","NIDORAN_M","MR_MIME","FARFETCHD","FARFETCH_D",
    "NIDOQUEEN","NIDOKING","PIDGEOTTO","PIDGEOT","WIGGLYTUFF","NINETALES",
    "VILEPLUME","PARASECT","VENOMOTH","DUGTRIO","GOLDUCK","PRIMEAPE",
    "ARCANINE","POLIWHIRL","POLIWRATH","ALAKAZAM","MACHOKE","MACHAMP",
    "WEEPINBELL","VICTREEBEL","TENTACRUEL","GRAVELER","RAPIDASH","SLOWBRO",
    "MAGNETON","DEWGONG","CLOYSTER","HAUNTER","GENGAR","KINGLER",
    "ELECTRODE","EXEGGUTOR","MAROWAK","HITMONLEE","HITMONCHAN","LICKITUNG",
    "WEEZING","KANGASKHAN","SEADRA","SEAKING","STARMIE","ELECTABUZZ",
    "GYARADOS","LAPRAS","VAPOREON","JOLTEON","FLAREON","OMANYTE","OMASTAR",
    "KABUTO","KABUTOPS","AERODACTYL","SNORLAX","ARTICUNO","ZAPDOS","MOLTRES",
    "DRATINI","DRAGONAIR","DRAGONITE","MEWTWO",
    "BULBASAUR","IVYSAUR","VENUSAUR","CHARMANDER","CHARMELEON","CHARIZARD",
    "SQUIRTLE","WARTORTLE","BLASTOISE","CATERPIE","METAPOD","BUTTERFREE",
    "WEEDLE","KAKUNA","BEEDRILL","PIDGEY","RATTATA","RATICATE","SPEAROW",
    "FEAROW","EKANS","ARBOK","PIKACHU","RAICHU","SANDSHREW","SANDSLASH",
    "CLEFAIRY","CLEFABLE","VULPIX","JIGGLYPUFF","ZUBAT","GOLBAT","ODDISH",
    "GLOOM","PARAS","VENONAT","DIGLETT","MEOWTH","PERSIAN","PSYDUCK",
    "MANKEY","GROWLITHE","POLIWAG","ABRA","KADABRA","MACHOP","BELLSPROUT",
    "TENTACOOL","GEODUDE","GOLEM","PONYTA","SLOWPOKE","MAGNEMITE","DODUO",
    "DODRIO","SEEL","GRIMER","MUK","SHELLDER","GASTLY","ONIX","DROWZEE",
    "HYPNO","KRABBY","VOLTORB","EXEGGCUTE","CUBONE","KOFFING","RHYHORN",
    "RHYDON","CHANSEY","TANGELA","HORSEA","GOLDEEN","STARYU","SCYTHER",
    "JYNX","MAGMAR","PINSIR","TAUROS","MAGIKARP","DITTO","EEVEE","PORYGON",
    "MEW",
  }
  local SPECIES_SET = {}
  for _, s in ipairs(SPECIES_NAMES) do SPECIES_SET[s] = true end

  local function normalizeSpeciesToken(s)
    if type(s) ~= "string" or s == "" then return nil end
    local u = s:upper()
    u = u:gsub("^SPRITE_POKEMON_", ""):gsub("^SPRITE_POKE_", ""):gsub("^SPRITE_", "")
    u = u:gsub("^POKEMON_", ""):gsub("^POKE_", "")
    u = u:gsub("%s+", "_")
    -- FARFETCH'D variants
    u = u:gsub("FARFETCH.?D", "FARFETCHD")
    u = u:gsub("MR%.?%s*MIME", "MR_MIME")
    if SPECIES_SET[u] then return u end
    if u == "FARFETCH_D" then return "FARFETCHD" end
    return nil
  end

  local function resolveVanillaPokeName(npc)
    if not npc then return nil end
    -- Only the actual Yellow follower is Pikachu; never bleed that onto others.
    if npc.pikachuFollower then return "PIKACHU" end
    local d = npc.def or {}

    local function spriteString()
      if type(d.sprite) == "string" then return d.sprite end
      if type(npc.spriteId) == "string" then return npc.spriteId end
      local spr = npc.sprite
      if type(spr) == "string" then return spr end
      if type(spr) == "table" then
        if type(spr.id) == "string" then return spr.id end
        if type(spr.name) == "string" then return spr.name end
        if type(spr.key) == "string" then return spr.key end
      end
      return ""
    end

    local candidates = {
      npc.kantoLifeSpecies, d.kantoLifeSpecies, d.species,
    }
    if type(d.pokemon) == "string" then candidates[#candidates + 1] = d.pokemon end
    if type(d.mon) == "string" then candidates[#candidates + 1] = d.mon end
    if type(d.poke) == "string" then candidates[#candidates + 1] = d.poke end

    for _, c in ipairs(candidates) do
      local sp = normalizeSpeciesToken(tostring(c or ""))
      if sp then return speciesDisplayName(sp) end
    end

    local spr = tostring(spriteString())
    local sprU = spr:upper()
    if sprU ~= "" then
      local mapped = GENERIC_SPRITE_SPECIES[sprU] or GENERIC_SPRITE_SPECIES[spr]
      if mapped then return speciesDisplayName(mapped) end
      local exact = normalizeSpeciesToken(sprU)
      if exact then return speciesDisplayName(exact) end
      for _, species in ipairs(SPECIES_NAMES) do
        local before = sprU:find(species, 1, true)
        if before then
          local after = before + #species
          local chB = before > 1 and sprU:sub(before - 1, before - 1) or "_"
          local chA = after <= #sprU and sprU:sub(after, after) or "_"
          if not chB:match("[%w]") and not chA:match("[%w]") then
            return speciesDisplayName(species)
          end
        end
      end
    end

    for _, key in ipairs({ "displayName", "label", "name" }) do
      local sp = normalizeSpeciesToken(tostring(d[key] or ""))
      if sp then return speciesDisplayName(sp) end
    end
    return nil
  end

  local function isHumanAmbient(npc)
    return isAmbientNpc(npc) and not isPokeAmbient(npc)
  end

  local function destroyAmbient(ow, npc)
    if not npc then return end
    local id = npc.id
    pcall(function()
      if id then mod.world:removeNpc(id) end
    end)
    if ow and ow.npcs then
      for i = #ow.npcs, 1, -1 do
        local n = ow.npcs[i]
        if n == npc or (id and n and n.id == id) then
          table.remove(ow.npcs, i)
        end
      end
    end
    if ow and ow.entities then
      for i = #ow.entities, 1, -1 do
        local e = ow.entities[i]
        if e == npc or (id and e and e.id == id) then
          table.remove(ow.entities, i)
        end
      end
    end
    -- Soft-hide if the engine still holds a reference.
    npc.visible = false
    npc.hidden = true
    if npc.def then npc.def.hidden = true end
    pcall(function()
      if npc.cellX then npc.cellX = -100 end
      if npc.cellY then npc.cellY = -100 end
      if npc.px then npc.px = -1000 end
      if npc.py then npc.py = -1000 end
    end)
  end

  local function collectLiveAmbient(ow, kind)
    -- kind: "human" | "poke" | nil (all our ambients)
    local list = {}
    if not ow or not ow.npcs then return list end
    for _, n in ipairs(ow.npcs) do
      if isAmbientNpc(n) and not n.hidden then
        if kind == "human" and not isHumanAmbient(n) then goto cont end
        if kind == "poke" and not isPokeAmbient(n) then goto cont end
        list[#list + 1] = n
      end
      ::cont::
    end
    return list
  end

  local lastPokeRandomMode = nil

  local function syncAmbientToTarget(mapId, map)
    local ow = mod.world:overworld()
    if not ow then return end
    if not map then map = ow.map end
    if not map or (map.id and map.id ~= mapId) then
      if ow.map and ow.map.id == mapId then map = ow.map else return end
    end

    local function syncKind(kind, want, spawnOne)
      local have = collectLiveAmbient(ow, kind)
      while #have > want do
        local npc = table.remove(have)
        destroyAmbient(ow, npc)
      end
      if want <= 0 then return end
      for i = #have + 1, want do
        if not spawnOne(i) then break end
      end
    end

    -- Humans
    local wantH = targetCount(mapId, map)
    if isTown(mapId) or isIndoor(mapId) then
      ensureTalkScripts(mapId, math.max(wantH, 150))
      local sprites = civilianSprites(ow, mapId)
      syncKind("human", wantH, function(i)
        local x, y = pickSpawnCell(ow, map)
        if not x then return false end
        spawnSerial = spawnSerial + 1
        local text = "KANTO_CROWD_" .. mapId .. "_" .. spawnSerial
        local sprite = sprites[((i - 1) % math.max(#sprites, 1)) + 1]
        if not sprite then return false end
        local gend = genderFromSprite(sprite)
        local displayName = randomName(gend)
        local npcId, err = mod.world:spawnNpc(mapId, {
          name = text, sprite = sprite, x = x, y = y,
          text = text, movement = "WALK", range = "ANY_DIR", radius = { x = 8, y = 8 },
          kantoLifeAmbient = true,
          kantoLifeDisplayName = displayName,
          kantoLifeGender = gend,
        })
        if not npcId then
          mod.log:warn("Crowd spawn failed: " .. tostring(err))
          return false
        end
        for _, n in ipairs(ow.npcs or {}) do
          if n.id == npcId or (n.def and n.def.name == text) then
            n.def = n.def or {}
            n.def.kantoLifeAmbient = true
            n.def.name = text
            n.def.kantoLifeDisplayName = displayName
            n.def.kantoLifeGender = gend
          end
        end
        return true
      end)
    elseif isRoute(mapId) then
      local civilian, trainer = {}, {}
      for _, npc in ipairs(ow.npcs or {}) do
        local d = npc.def or {}
        if d.kantoLifeAmbient or d.kantoLifePokeAmbient then goto cont end
        if isPokemonLike(npc) then goto cont end
        if d.sprite and isHumanCivilianSprite(d.sprite) then
          if d.trainerClass then trainer[#trainer + 1] = d.sprite
          elseif not d.item and not d.pokemon then civilian[#civilian + 1] = d.sprite end
        end
        ::cont::
      end
      if #civilian == 0 and #trainer == 0 then
        civilian = civilianSprites(ow, mapId)
      end
      syncKind("human", wantH, function(i)
        local x, y = pickSpawnCell(ow, map)
        if not x then return false end
        local useTrainerSprite = i % 5 == 0 and #trainer > 0
        local sprites = useTrainerSprite and trainer or civilian
        if #sprites == 0 then sprites = trainer end
        if #sprites == 0 then return false end
        spawnSerial = spawnSerial + 1
        local name = "KANTO_ROUTE_NPC_" .. mapId .. "_" .. spawnSerial
        local sprite = sprites[love.math.random(#sprites)]
        local gend = genderFromSprite(sprite)
        local displayName = randomName(gend)
        local id, err = mod.world:spawnNpc(mapId, {
          name = name, sprite = sprite, x = x, y = y,
          text = "", movement = "WALK", range = "ANY_DIR", radius = { x = 8, y = 8 },
          kantoLifeAmbient = true,
          kantoLifeDisplayName = displayName,
          kantoLifeGender = gend,
        })
        if not id then
          mod.log:warn("Route NPC spawn failed: " .. tostring(err))
          return false
        end
        for _, n in ipairs(ow.npcs or {}) do
          if n.id == id or (n.def and n.def.name == name) then
            n.def = n.def or {}
            n.def.kantoLifeAmbient = true
            n.def.name = name
            n.def.kantoLifeDisplayName = displayName
            n.def.kantoLifeGender = gend
          end
        end
        return true
      end)
    else
      syncKind("human", 0, function() return false end)
    end

    -- Pokemon ambients: OWN count; never driven by human EXTRA NPC COUNT / Wilds
    local wantP = pokeTargetCount(mapId, map)
    local function buildReady(list)
      local out, seen = {}, {}
      for _, sp in ipairs(list or {}) do
        if type(sp) == "string" and not seen[sp] then
          seen[sp] = true
          local spr = resolvePokeSprite(sp)
          if spr then out[#out + 1] = { species = sp, sprite = spr } end
        end
      end
      return out
    end

        local function encounterSpeciesForMap(mapId, map)
      -- Wilds Town Pokémon style:
      -- 1) this map's grass/water tables
      -- 2) else borrow from neighboring routes
      -- 3) else small peaceful fallback (no legendaries)
      local land, water = {}, {}
      local seenL, seenW = {}, {}
      local data = game and game.data
      local encounters = data and data.encounters

      local function add(dest, seen, sp)
        if type(sp) ~= "string" or sp == "" then return end
        sp = sp:upper()
        if seen[sp] then return end
        seen[sp] = true
        dest[#dest + 1] = sp
      end
      local function take(dest, seen, block)
        if type(block) ~= "table" then return end
        local slots = block.slots or block
        if type(slots) ~= "table" then return end
        for _, slot in ipairs(slots) do
          if type(slot) == "table" then
            add(dest, seen, slot.species or slot.pokemon or slot[1])
          elseif type(slot) == "string" then
            add(dest, seen, slot)
          end
        end
      end
      local function fromMap(mid)
        local enc = encounters and mid and encounters[mid]
        if type(enc) ~= "table" then return end
        take(land, seenL, enc.grass)
        take(water, seenW, enc.water)
        take(water, seenW, enc.surfing)
        take(water, seenW, enc.fish)
        take(water, seenW, enc.fishing)
      end

      fromMap(mapId)

      -- Towns usually have no grass table: borrow from connected routes (Wilds).
      if #land == 0 and map then
        local def = map.def or map
        local conns = def and def.connections
        if type(conns) == "table" then
          for _, dir in ipairs({ "north", "south", "east", "west" }) do
            local conn = conns[dir]
            local dest = conn and (conn.map or conn.mapId or conn.dest)
            if type(dest) == "string" then fromMap(dest) end
            if #land >= 6 then break end
          end
        end
      end

      if #land == 0 then
        for _, sp in ipairs(TOWN_FALLBACK) do add(land, seenL, sp) end
      end
      return land, water
    end

    local fullyRandom = opt("poke_random") and true or false
    local readyAll = buildReady(fullyRandom and fullDexSpecies() or POKE_SPECIES)
    local readyLand, readyWater
    if fullyRandom then
      -- Full dex including legendaries; water/land placement still respected
      readyLand = readyAll
      readyWater = readyAll
    else
      local landSp, waterSp = encounterSpeciesForMap(mapId, map)
      readyLand = buildReady(landSp)
      readyWater = buildReady(waterSp)
      if #readyLand == 0 then readyLand = buildReady(POKE_LAND) end
      if #readyWater == 0 then readyWater = buildReady(POKE_WATER) end
    end
    if #readyLand == 0 then readyLand = readyAll end
    if #readyWater == 0 then readyWater = readyAll end
    if #readyAll == 0 and wantP > 0 then
      mod.log:warn("No overworld Pokemon sprites available; POKEMON NPCS skipped on " .. tostring(mapId))
      wantP = 0
    end

    -- Reshuffle poke species only when RANDOM POKE NPCS toggles.
    -- Count changes only add/remove; existing stay put.
    local modeNow = fullyRandom and true or false
    if lastPokeRandomMode == nil then
      lastPokeRandomMode = modeNow
    elseif lastPokeRandomMode ~= modeNow then
      local live = collectLiveAmbient(ow, "poke")
      for _, npc in ipairs(live) do
        destroyAmbient(ow, npc)
      end
      lastPokeRandomMode = modeNow
    end

    -- How watery is this map? Ocean routes skew toward water mons.
    local function waterCoverageRatio()
      local w = map.widthCells or map.width or 0
      local h = map.heightCells or map.height or 0
      if w < 4 or h < 4 then return 0 end
      local waterN, total = 0, 0
      local step = math.max(1, math.floor(math.max(w, h) / 24))
      for y = 2, h - 3, step do
        for x = 2, w - 3, step do
          total = total + 1
          if isWaterCell(map, x, y) then waterN = waterN + 1 end
        end
      end
      if total == 0 then return 0 end
      return waterN / total
    end
    local cover = waterCoverageRatio()
    -- Blend map water coverage with relative pool sizes
    local waterBias = cover
    if not fullyRandom then
      local nW, nL = #readyWater, #readyLand
      if nW + nL > 0 then
        waterBias = math.max(waterBias, nW / (nW + nL))
      end
    end
    -- Floor/ceiling so pure land maps stay land-heavy and ocean maps go wet
    if cover < 0.08 then waterBias = math.min(waterBias, 0.12) end
    if cover > 0.45 then waterBias = math.max(waterBias, 0.55) end
    if cover > 0.70 then waterBias = math.max(waterBias, 0.80) end

    syncKind("poke", wantP, function(i)
      local x, y, entry, wantWaterMon
      if fullyRandom then
        entry = readyAll[love.math.random(#readyAll)]
        if not entry then return false end
        wantWaterMon = isWaterSpecies(entry.species)
      else
        wantWaterMon = (#readyWater > 0) and (love.math.random() < waterBias)
        if wantWaterMon then
          entry = readyWater[love.math.random(#readyWater)]
        else
          entry = (#readyLand > 0) and readyLand[love.math.random(#readyLand)] or nil
        end
        if not entry then
          entry = readyAll[love.math.random(#readyAll)]
          if not entry then return false end
          wantWaterMon = isWaterSpecies(entry.species)
        end
      end
      if wantWaterMon then
        x, y = pickSpawnCellFiltered(ow, map, true)
      else
        x, y = pickSpawnCellFiltered(ow, map, false)
        if not x then x, y = pickSpawnCell(ow, map) end
      end
      -- Refuse to place a water mon on land (or land mon on water)
      if not x then return false end
      if wantWaterMon and not isWaterCell(map, x, y) then return false end
      if not wantWaterMon and isWaterCell(map, x, y) then return false end
      spawnSerial = spawnSerial + 1
      local name = "KANTO_POKE_" .. entry.species .. "_" .. spawnSerial
      local id, err = mod.world:spawnNpc(mapId, {
        name = name, sprite = entry.sprite, x = x, y = y,
        -- Water mons: no land pathing; land mons walk as before
        text = "",
        movement = wantWaterMon and "STAY" or "WALK",
        range = wantWaterMon and "NONE" or "ANY_DIR",
        kantoLifeAmbient = true,
        kantoLifePokeAmbient = true,
        kantoLifeSpecies = entry.species,
        kantoLifeWaterBound = wantWaterMon and true or nil,
        trainerClass = nil, pokemon = nil, party = nil,
      })
      if not id then
        mod.log:warn("Poke ambient spawn failed: " .. tostring(err))
        return false
      end
      for _, n in ipairs(ow.npcs or {}) do
        if n.id == id or (n.def and n.def.name == name) then
          n.def = n.def or {}
          n.def.kantoLifeAmbient = true
          n.def.kantoLifePokeAmbient = true
          n.def.kantoLifeSpecies = entry.species
          n.def.kantoLifeDisplayName = entry.species
          n.def.kantoLifeWaterBound = wantWaterMon and true or nil
          n.def.name = name
          n.kantoLifeSpecies = entry.species
          n.kantoLifePokeAmbient = true
          n.kantoLifeWaterBound = wantWaterMon and true or nil
          tagKantoPokemon(n, entry.species)
        end
      end
      return true
    end)
  end


  for mapId, count in pairs(townDefaults) do
    ensureTalkScripts(mapId, math.max(count, 150))
  end

  do
    local ver = (mod.manifest and mod.manifest.version) or "?"
    local eng = "?"
    local g = resolveGame and resolveGame() or game
    if g and g.VERSION then eng = tostring(g.VERSION)
    elseif mod.game then eng = "mod.game-ok" end
    if mod.log and mod.log.info then
      mod.log:info("Kanto Life %s ready (game facade: %s)", ver, game and "yes" or "pending")
    end
  end

  ensureNpcAgendaPersistence()

  -- Day Sleepers policy:
  -- When enabled, each fresh game/mod load starts the sleep rate at 10%.
  -- When disabled, leave the user's saved sleep rate untouched so it persists
  -- across reboots. The internal option key stays the same for compatibility.
  if opt("day_sleepers") == true then
    setOpt("sleep_pct", 10)
  end

  mod.events:on("map.entered", function(ev)
    local mapId, enteredMap = ev.mapId, ev.map
    if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId, enteredMap)) then return end
    -- Indoor NPC COUNT is global. When entering any building with the count
    -- at zero, seed it to 2. A nonzero value is never overwritten. If the
    -- feature itself is OFF, leave it OFF and do not touch the count.
    if isIndoor(mapId, enteredMap) and opt("indoor_npcs") then
      local cur = math.floor(tonumber(opt("indoor_npc_count")) or 0)
      if cur <= 0 then setOpt("indoor_npc_count", 2) end
    end
    syncAmbientToTarget(mapId, enteredMap)
    -- Spawn cross-map travelers who exited to this map from another map
    pcall(spawnTravelers, mapId, enteredMap)
  end)

  mod.events:on("mod.options_changed", function(payload)
    if not payload or payload.mod ~= mod.id then return end
    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map then return end
    local mapId = ow.map.id
    if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId)) then return end

    -- Turning EXTRA NPCS on with a zero count seeds the current map's default.
    if payload.key == "extra_npcs" and payload.value == true then
      local cur = math.floor(tonumber(opt("extra_npc_count")) or 0)
      if cur <= 0 then
        local d = defaultCount(mapId)
        if d > 0 then setOpt("extra_npc_count", d) end
      end
    end

    if payload.key == "extra_npcs" or payload.key == "extra_npc_count"
       or payload.key == "indoor_npcs" or payload.key == "indoor_npc_count"
       or payload.key == "poke_npcs" or payload.key == "poke_npc_count"
       or payload.key == "poke_random" then
      syncAmbientToTarget(mapId, ow.map)
    end
    if payload.key == "sleeping_npcs" and not opt("sleeping_npcs") then
      for _, npc in ipairs(ow.npcs or {}) do
        if npc.nightlifeSleeping then wakeNpc(npc) end
      end
    end
  end)

  -- Keep the large gameplay/menu implementation in its own function scope.
  -- Gen1Recomp/LuaJIT caps a single function at 200 local variables.
  local function setupGameplay()

  -- ------- Native OPTIONS submenu (same pattern as Wilds of Kanto / overworld-spawn-mod)
  -- START → OPTION → KANTO LIFE (OPEN) → ListMenu with left/right steppers
  local OPTIONS_SCREEN = "KantoLifeOptions"

  local function refreshAmbientNow()
    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map then return end
    local mapId = ow.map.id
    if isTown(mapId) or isRoute(mapId) or isIndoor(mapId) then
      syncAmbientToTarget(mapId, ow.map)
    end
  end


  local function resolveOverworld()
    local ow = nil
    pcall(function()
      if liveWorld then ow = liveWorld() end
    end)
    if ow and ow.npcs then return ow end
    pcall(function()
      if mod.world and type(mod.world.overworld) == "function" then
        ow = mod.world:overworld()
      end
    end)
    if ow and ow.npcs then return ow end
    local g = G and G() or nil
    if g then
      ow = g.world or g.overworld
      if type(ow) == "function" then
        local ok, w = pcall(ow, g)
        if ok then ow = w end
      end
    end
    return ow
  end

  local function reapplyAllSleep()
    local ow = resolveOverworld()
    if not (ow and ow.npcs) then return end
    -- Always wake first so rate decreases take effect immediately
    for _, npc in ipairs(ow.npcs) do
      if npc.nightlifeSleeping then
        pcall(wakeNpc, npc)
      end
      -- Allow day/night schedule to refresh when rate toggles
      -- (keep schedule so same NPCs tend to re-sleep unless rate excludes them)
    end
    if not opt("sleeping_npcs") then return end
    local isNight = night(ow)
    for _, npc in ipairs(ow.npcs) do
      if isSpecialCharacter(npc) then
        -- nurse/clerks/oak
      elseif isPokemonFollower(npc) then
        --
      elseif (npc.wild or npc.isWild or npc.wildPokemon) and not isPokeAmbient(npc) then
        -- true wilds only
      elseif shouldSleepNow(npc, isNight) then
        pcall(putToSleep, npc)
      end
    end
  end

  local function applySleepOff()
    if opt("sleeping_npcs") then return end
    local ow = mod.world and mod.world:overworld()
    if not ow then return end
    for _, npc in ipairs(ow.npcs or {}) do
      if npc.nightlifeSleeping then wakeNpc(npc) end
    end
  end

  local function stepToggle(item, dir)
    local nextVal = not item.current
    item.current = nextVal
    item.right = nextVal and "ON" or "OFF"
    if item.apply then item.apply(nextVal) end
  end

  local function stepNumber(item, dir)
    local step = tonumber(item.step) or 1
    if math.abs(dir or 1) > 1 then step = tonumber(item.stepFast) or step * 2 or 10 end
    local cur = tonumber(item.current) or 0
    local nextVal = cur + ((dir or 1) >= 0 and step or -step)
    -- Snap to step grid when step > 1
    if step > 1 then
      nextVal = math.floor((nextVal / step) + 0.5) * step
    end
    local mn, mx = item.min or 0, item.max or 150
    if nextVal < mn then nextVal = mn end
    if nextVal > mx then nextVal = mx end
    if nextVal == cur then return end
    item.current = nextVal
    if item.display then item.right = item.display(nextVal) else item.right = tostring(nextVal) end
    if item.apply then item.apply(nextVal) end
  end

  local function stepItem(item, dir)
    if not item or not item.stepper then return end
    if item.kind == "number" then
      stepNumber(item, dir)
    else
      stepToggle(item, dir)
    end
  end

  -- ListMenu with left/right steppers (mirrors Wilds settings_menus._makeStepperMenu)
  local function makeStepperMenu(g, title, items)
    local menu = mod.ui.ListMenu.new(g, title, items, {
      onChoose = function(item, m)
        if item and item.stepper then
          stepItem(item, 1)
          return
        end
        if item and item.onSelect then
          item.onSelect()
          if m and m.close then m:close() end
        end
      end,
    })
    if not (menu and type(menu.update) == "function") then
      return menu
    end

    local INITIAL_DELAY = 0.35
    local REPEAT_INTERVAL = 0.08
    local baseUpdate = menu.update
    menu.update = function(self, dt)
      local item = self.items and self.items[self.index or self.cursor or 1]
      -- Resolve selected index the way ListMenu stores it.
      local idx = self.index or self.selected or self.cursor
      if type(idx) == "number" and self.items then item = self.items[idx] end

      if not (item and item.stepper) then
        self._klHold = nil
        self._klTimer = 0
        return baseUpdate(self, dt)
      end

      local input = self.game and self.game.input
      local function down(dir)
        if not input then return false end
        if input.isDown and input:isDown(dir) then return true end
        if input.down and input:down(dir) then return true end
        return false
      end
      local function pressed(dir)
        if not input then return false end
        if input.wasPressed and input:wasPressed(dir) then return true end
        return false
      end

      -- Let ListMenu handle up/down/A/B first, but intercept left/right before
      -- pageJump would consume them (pageJump is off by default here).
      local leftP, rightP = pressed("left"), pressed("right")
      local leftD, rightD = down("left"), down("right")

      if leftP or rightP then
        stepItem(item, leftP and -1 or 1)
        self._klHold = leftP and "left" or "right"
        self._klTimer = 0
        -- Still run base for up/down/A/B, but skip its left/right page logic
        -- by temporarily clearing wasPressed if possible — simplest: call base
        -- and accept no-op when pageJump is false.
      elseif self._klHold then
        local still = (self._klHold == "left" and leftD) or (self._klHold == "right" and rightD)
        if still then
          self._klTimer = (self._klTimer or 0) + (dt or 0)
          if self._klTimer >= INITIAL_DELAY then
            -- After initial delay, repeat; use larger step for held number.
            local rep = math.floor((self._klTimer - INITIAL_DELAY) / REPEAT_INTERVAL)
            if not self._klRep or rep > self._klRep then
              self._klRep = rep
              local dir = self._klHold == "left" and -10 or 10
              if item.kind ~= "number" then dir = self._klHold == "left" and -1 or 1 end
              stepItem(item, dir)
            end
          end
        else
          self._klHold, self._klTimer, self._klRep = nil, 0, nil
        end
      end

      return baseUpdate(self, dt)
    end
    return menu
  end

  mod.content.screens:register(OPTIONS_SCREEN, {
    new = function(g)
      local items = {
        {
          label = "EXTRA NPCS",
          stepper = true,
          kind = "toggle",
          current = opt("extra_npcs") and true or false,
          right = opt("extra_npcs") and "ON" or "OFF",
          apply = function(v)
            setOpt("extra_npcs", v and true or false)
            if v then
              local cur = math.floor(tonumber(opt("extra_npc_count")) or 0)
              if cur <= 0 then
                local ow = mod.world and mod.world:overworld()
                local mapId = ow and ow.map and ow.map.id
                local d = mapId and defaultCount(mapId) or 0
                if d > 0 then setOpt("extra_npc_count", d) end
              end
            end
            refreshAmbientNow()
          end,
        },
        {
          label = "EXTRA NPC COUNT",
          stepper = true,
          kind = "number",
          min = 0, max = 150, stepFast = 10,
          current = math.floor(tonumber(opt("extra_npc_count")) or 0),
          right = tostring(math.floor(tonumber(opt("extra_npc_count")) or 0)),
          apply = function(v)
            setOpt("extra_npc_count", math.floor(tonumber(v) or 0))
            refreshAmbientNow()
          end,
        },
        {
          label = "POKEMON NPCS",
          stepper = true,
          kind = "toggle",
          current = opt("poke_npcs") and true or false,
          right = opt("poke_npcs") and "ON" or "OFF",
          apply = function(v)
            setOpt("poke_npcs", v and true or false)
            refreshAmbientNow()
          end,
        },
        {
          label = "POKE NPC COUNT",
          stepper = true,
          kind = "number",
          min = 0, max = 50, stepFast = 5,
          current = math.floor(tonumber(opt("poke_npc_count")) or 0),
          right = tostring(math.floor(tonumber(opt("poke_npc_count")) or 0)),
          apply = function(v)
            setOpt("poke_npc_count", math.floor(tonumber(v) or 0))
            refreshAmbientNow()
          end,
        },
        {
          label = "RANDOM POKE NPCS",
          stepper = true,
          kind = "toggle",
          current = opt("poke_random") ~= false,
          right = (opt("poke_random") ~= false) and "ON" or "OFF",
          apply = function(v)
            setOpt("poke_random", v and true or false)
            refreshAmbientNow()
          end,
        },
        {
          label = "INDOOR NPCS",
          stepper = true,
          kind = "toggle",
          current = opt("indoor_npcs") and true or false,
          right = opt("indoor_npcs") and "ON" or "OFF",
          apply = function(v)
            setOpt("indoor_npcs", v and true or false)
            refreshAmbientNow()
          end,
        },
        {
          label = "INDOOR NPC COUNT",
          stepper = true,
          kind = "number",
          min = 0, max = 30, stepFast = 5,
          current = math.floor(tonumber(opt("indoor_npc_count")) or 0),
          right = tostring(math.floor(tonumber(opt("indoor_npc_count")) or 0)),
          apply = function(v)
            setOpt("indoor_npc_count", math.floor(tonumber(v) or 0))
            refreshAmbientNow()
          end,
        },
        {
          label = "SLEEPING NPCS",
          stepper = true,
          kind = "toggle",
          current = opt("sleeping_npcs") and true or false,
          right = opt("sleeping_npcs") and "ON" or "OFF",
          apply = function(v)
            setOpt("sleeping_npcs", v and true or false)
            applySleepOff()
            pcall(reapplyAllSleep)
          end,
        },
        {
          label = "SLEEP RATE %",
          stepper = true,
          kind = "number",
          min = 0, max = 100, step = 10, stepFast = 10,
          current = math.floor(tonumber(opt("sleep_pct")) or 15),
          right = tostring(math.floor(tonumber(opt("sleep_pct")) or 15)),
          apply = function(v)
            local n = math.floor(tonumber(v) or 15)
            n = math.floor((n + 5) / 10) * 10
            if n < 0 then n = 0 end
            if n > 100 then n = 100 end
            setOpt("sleep_pct", n)
            pcall(reapplyAllSleep)
          end,
        },
        {
          label = "DAY SLEEPERS",
          stepper = true,
          kind = "toggle",
          current = opt("day_sleepers") and true or false,
          right = opt("day_sleepers") and "ON" or "OFF",
          apply = function(v)
            setOpt("day_sleepers", v and true or false)
            local ow = mod.world and mod.world.overworld and mod.world:overworld()
            if ow then
              for _, npc in ipairs(ow.npcs or {}) do
                npc.kantoLifeSleepSchedule = nil
                if npc.nightlifeSleeping then wakeNpc(npc) end
              end
            end
            pcall(reapplyAllSleep)
          end,
        },
        {
          label = "SLEEP ZZZ",
          stepper = true,
          kind = "toggle",
          current = opt("sleep_bubbles") and true or false,
          right = opt("sleep_bubbles") and "ON" or "OFF",
          apply = function(v)
            setOpt("sleep_bubbles", v and true or false)
          end,
        },
        {
          label = "SLEEP STYLE",
          stepper = true,
          kind = "number",
          min = 0, max = 3, step = 1, stepFast = 1,
          current = math.floor(tonumber(opt("sleep_style")) or 0),
          display = function(v) return ({[0]="Default",[1]="Tent",[2]="Sleeping Bag",[3]="Bed"})[math.floor(tonumber(v) or 0)] or "Default" end,
          right = ({[0]="Default",[1]="Tent",[2]="Sleeping Bag",[3]="Bed"})[math.floor(tonumber(opt("sleep_style")) or 0)] or "Default",
          apply = function(v) setOpt("sleep_style", math.max(0, math.min(3, math.floor(tonumber(v) or 0)))) end,
        },
        {
          label = "NPC TALK BUBBLES",
          stepper = true, kind = "toggle",
          current = opt("npc_collision_bubbles") ~= false,
          right = opt("npc_collision_bubbles") ~= false and "ON" or "OFF",
          apply = function(v) setOpt("npc_collision_bubbles", v and true or false) end,
        },
        {
          label = "NPC ROUTINES",
          stepper = true,
          kind = "toggle",
          current = opt("npc_routines") and true or false,
          right = opt("npc_routines") and "ON" or "OFF",
          apply = function(v)
            setOpt("npc_routines", v and true or false)
          end,
        },
        {
          label = "NPC TRAVEL %",
          stepper = true,
          kind = "number",
          min = 0, max = 100, step = 10, stepFast = 10,
          current = math.floor(tonumber(opt("npc_travel_pct")) or 30),
          right = tostring(math.floor(tonumber(opt("npc_travel_pct")) or 30)) .. "%",
          apply = function(v)
            local n = math.floor((tonumber(v) or 10) / 10 + 0.5) * 10
            if n < 0 then n = 0 elseif n > 100 then n = 100 end
            setOpt("npc_travel_pct", n)
            scheduleDirty = true
            if kantoRoutines and type(kantoRoutines.setTravelPercent) == "function" then
              kantoRoutines.setTravelPercent(n)
            end
          end,
        },
        {
          label = "NPC AGENDA",
          stepper = true,
          kind = "number",
          min = 0, max = 2, step = 1, stepFast = 1,
          current = math.floor(tonumber(opt("npc_agenda")) or 0),
          display = function(v) return ({[0] = "OFF", [1] = "DAY", [2] = "FULL"})[math.floor(tonumber(v) or 0)] or "OFF" end,
          right = ({[0] = "OFF", [1] = "DAY", [2] = "FULL"})[math.floor(tonumber(opt("npc_agenda")) or 0)] or "OFF",
          apply = function(v)
            local n = math.floor(tonumber(v) or 0)
            if n < 0 then n = 0 elseif n > 2 then n = 2 end
            setOpt("npc_agenda", n)
            scheduleDirty = true
            if kantoRoutines and type(kantoRoutines.setAgenda) == "function" then
              kantoRoutines.setAgenda(n)
            end
          end,
        },
        {
          label = "DOOR KNOCKING",
          stepper = true,
          kind = "toggle",
          current = opt("common_courtesy") and true or false,
          right = opt("common_courtesy") and "ON" or "OFF",
          apply = function(v)
            setOpt("common_courtesy", v and true or false)
          end,
        },
        {
          label = "CANCEL",
          onSelect = function() end,
        },
      }
      return makeStepperMenu(g, "KANTO LIFE", items)
    end,
  })

  mod.hooks:wrap("ui.options.rows", function(next, g, rows)
    local out = next(g, rows)
    if type(out) ~= "table" then return out end
    local row = {
      id = "kanto_life_open",
      label = "KANTO LIFE",
      value = function() return "OPEN" end,
      activate = function(game_)
        if mod.ui and mod.ui.push then
          mod.ui.push(game_, OPTIONS_SCREEN)
        end
      end,
    }
    if mod.ui and type(mod.ui.insertBefore) == "function" then
      out = mod.ui.insertBefore(out, "MODS", row) or out
    else
      out[#out + 1] = row
    end
    return out
  end)


  -- ------- Nightlife + Door Knocking (Gen 1 + Gen 2 / Gold-safe)
  local function safeRequire(path)
    local ok, result = pcall(require, path)
    if ok then return result end
    return nil
  end

  local gen1 = isGen1Boot()
  local Overworld = safeRequire("src.world.OverworldController")
    or safeRequire("src.world.Overworld")
  local MapScripts = gen1 and safeRequire("src.script.MapScripts") or nil
  local Warp = safeRequire("src.world.Warp")
  local TextBox = safeRequire("src.render.TextBox")
  local Strings = safeRequire("src.core.Strings")
  local NPC = gen1 and safeRequire("src.world.NPC") or nil


  -- Johto-port: prefix vanilla NPC dialogue with gender-correct / story names
  local STORY_SPRITE_NAMES = {
    SPRITE_MOM = "MOM", MOM = "MOM", SPRITE_OAK = "PROF.OAK", OAK = "PROF.OAK",
    SPRITE_NURSE = "NURSE", NURSE = "NURSE", SPRITE_CLERK = "CLERK", CLERK = "CLERK",
    SPRITE_BLUE = "BLUE", BLUE = "BLUE", SPRITE_RED = "RED",
    SPRITE_BILL = "BILL", BILL = "BILL",
    SPRITE_MR_FUJI = "MR.FUJI", MR_FUJI = "MR.FUJI",
    SPRITE_GIOVANNI = "GIOVANNI", GIOVANNI = "GIOVANNI",
    SPRITE_BROCK = "BROCK", BROCK = "BROCK",
    SPRITE_MISTY = "MISTY", MISTY = "MISTY",
    SPRITE_DAISY = "DAISY", DAISY = "DAISY",
    SPRITE_LANCE = "LANCE", SPRITE_AGATHA = "AGATHA",
    SPRITE_BRUNO = "BRUNO", SPRITE_LORELEI = "LORELEI",
    SPRITE_KOGA = "KOGA", SPRITE_ERIKA = "ERIKA",
    SPRITE_SABRINA = "SABRINA", SPRITE_BLAINE = "BLAINE",
    SPRITE_SURGE = "LT.SURGE",
  }
  local function bodyToString(body)
    if body == nil then return "" end
    if type(body) == "string" then return body end
    if type(body) == "table" and type(body.text) == "string" then return body.text end
    local ok, s = pcall(tostring, body)
    return (ok and s) or ""
  end
  local function textAlreadyNamed(text)
    if type(text) ~= "string" then return false end
    -- Already "NAME:\n..." or "NAME: ..."
    if text:match("^[%a][%w%s%.%-%']*:%s*\n") then return true end
    if text:match("^[%a][%w%s%.%-%']*:%s+%S") then return true end
    return false
  end
  local function looksLikeInternalId(name)
    if type(name) ~= "string" or name == "" then return true end
    if name:find("KANTO_", 1, true) or name:find("JOHTO_", 1, true) then return true end
    if name:find("SPRITE_", 1, true) then return true end
    if name:match("^OBJ_") or name:match("^NPC_") then return true end
    if name:match("^[A-Z0-9_]+$") and #name > 16 then return true end
    return false
  end

  -- Wilds / tagged mon: read species fields only. Never guess from sprite.
  local function speciesLabelFromNpc(npc)
    if not npc then return nil end
    local d = npc.def or {}
    -- Yellow follower only — never leak Pikachu onto other mons (Charmander etc.).
    if npc.pikachuFollower then return "PIKACHU" end
    local candidates = {
      npc.kantoLifeSpecies, d.kantoLifeSpecies,
      npc.species, d.species,
      npc.wildSpecies, d.wildSpecies,
    }
    if type(npc.speciesId) == "string" then candidates[#candidates + 1] = npc.speciesId end
    if type(d.speciesId) == "string" then candidates[#candidates + 1] = d.speciesId end
    for _, c in ipairs(candidates) do
      if type(c) == "string" and c ~= "" then
        local sp = normalizeSpeciesToken and normalizeSpeciesToken(c) or nil
        if sp then return speciesDisplayName(sp) end
        local u = c:upper():gsub("%s+", "_")
        if SPECIES_SET and SPECIES_SET[u] then return speciesDisplayName(u) end
      end
    end
    if type(d.pokemon) == "string" then
      local sp = normalizeSpeciesToken and normalizeSpeciesToken(d.pokemon) or nil
      if sp then return speciesDisplayName(sp) end
    end
    local spr = tostring(d.sprite or ""):upper()
    if spr:find("PIKACHU", 1, true) then return "PIKACHU" end
    for _, species in ipairs(SPECIES_NAMES or {}) do
      if #species >= 5 and spr:find(species, 1, true) then
        local before = spr:find(species, 1, true)
        local after = before + #species
        local chB = before > 1 and spr:sub(before - 1, before - 1) or "_"
        local chA = after <= #spr and spr:sub(after, after) or "_"
        if not chB:match("[%w]") and not chA:match("[%w]") then
          return speciesDisplayName(species)
        end
      end
    end
    return nil
  end

  local function storyDisplayName(npc)
    if not npc then return nil end
    if isAmbientNpc(npc) then return nil end
    -- Default / Wilds / vanilla overworld Pokemon: no name prefix.
    if isPokemonLike(npc) and not isPokeAmbient(npc) then
      return nil
    end
    if type(npc.kantoLifeStoryName) == "string" and npc.kantoLifeStoryName ~= "" then
      return npc.kantoLifeStoryName
    end
    local d = npc.def or {}
    -- Prefer real assigned display names from data
    for _, key in ipairs({ "displayName", "label", "trainerName", "name" }) do
      local v = d[key]
      if type(v) == "string" and #v >= 2 and #v <= 18 and not looksLikeInternalId(v) then
        if v:match("^[%a][%a%s%.%-']*$") then
          npc.kantoLifeStoryName = v:upper()
          return npc.kantoLifeStoryName
        end
      end
    end
    local spr = tostring(d.sprite or ""):upper()
    if STORY_SPRITE_NAMES[spr] then
      npc.kantoLifeStoryName = STORY_SPRITE_NAMES[spr]
      return npc.kantoLifeStoryName
    end
    -- Default map NPCs with no story name: stable gender-specific English name
    local assigned = stableNameFor(npc)
    npc.kantoLifeStoryName = assigned
    return assigned
  end
  -- Last talker remembered so TextBox hooks still see them even if the engine
  -- clears ow.talkNpc before the box is built.
  local lastTalkNpc = nil
  local function rememberTalker(npc)
    lastTalkNpc = npc
    local ow = (mod.world and type(mod.world.overworld) == "function") and mod.world:overworld() or nil
    if ow then ow.talkNpc = npc end
  end
  if TextBox and type(TextBox.new) == "function" then
    local baseTB = TextBox.new
    TextBox.new = function(gameArg, text, onDone, opts)
      local raw = bodyToString(text)
      if textAlreadyNamed(raw) then return baseTB(gameArg, text, onDone, opts) end
      local ow = (mod.world and type(mod.world.overworld) == "function") and mod.world:overworld() or nil
      local talker = ow and ow.talkNpc
      if not talker then
        -- One-shot fallback, but never the Yellow follower (it stole every name).
        if lastTalkNpc and not lastTalkNpc.pikachuFollower then
          talker = lastTalkNpc
        end
      end
      lastTalkNpc = nil
      if isAmbientNpc(talker) then return baseTB(gameArg, text, onDone, opts) end
      -- Ambient spawns already format their own text; skip re-prefix.
      -- Pokemon-like with a real species field still get a name via storyDisplayName.
            if talker and isPokemonLike(talker) and not isPokeAmbient(talker) then
        return baseTB(gameArg, text, onDone, opts)
      end
local nm = storyDisplayName(talker)
      if nm and type(text) == "string" then
        text = nm .. ":\n" .. text
      elseif nm and type(text) == "table" and type(text.text) == "string" then
        local copy = {}
        for k, v in pairs(text) do copy[k] = v end
        copy.text = nm .. ":\n" .. text.text
        text = copy
      end
      return baseTB(gameArg, text, onDone, opts)
    end
  end

  if not Overworld then
    mod.log:warn("Kanto Life: Overworld module unavailable; courtesy/sleep AI limited")
  end
  if not TextBox or not Strings then
    mod.log:warn("Kanto Life: TextBox/Strings unavailable; dialogue prompts limited")
  end
  mod.log:info(gen1 and "Kanto Life: Gen 1 nightlife hooks" or "Kanto Life: Gen 2 facade nightlife hooks")

  local homes = mod.save:get("homes") or {}
  local function saveHomes() mod.save:set("homes", homes) end
  local function key(id) return tostring(id) end
  local function now()
    local ok, t = pcall(function() return os.time() end)
    if ok and type(t) == "number" then return t end
    return 0
  end

  local COURTESY_MEMORY_STEPS = 1500
  local function courtesyWalkSteps()
    return tonumber(mod.save:get("courtesyWalkSteps")) or 0
  end
  local function setCourtesyWalkSteps(n)
    mod.save:set("courtesyWalkSteps", math.max(0, math.floor(n)))
  end
  local function markHomeKnown(dest)
    if not dest then return end
    local h = homes[key(dest)] or {}
    h.known = true
    h.knocked = nil
    h.knownUntil = courtesyWalkSteps() + COURTESY_MEMORY_STEPS
    homes[key(dest)] = h
    saveHomes()
  end
  local function isHomeKnown(dest)
    local h = homes[key(dest)]
    if not h or not h.known then return false end
    local untilSteps = h.knownUntil
    if untilSteps == nil then
      h.knownUntil = courtesyWalkSteps() + COURTESY_MEMORY_STEPS
      homes[key(dest)] = h
      saveHomes()
      return true
    end
    if courtesyWalkSteps() >= untilSteps then
      h.known, h.knownUntil, h.knocked = nil, nil, nil
      homes[key(dest)] = h
      saveHomes()
      return false
    end
    return true
  end
  local function onPlayerStep()
    setCourtesyWalkSteps(courtesyWalkSteps() + 1)
    local steps = courtesyWalkSteps()
    local changed = false
    for id, h in pairs(homes) do
      if type(h) == "table" and h.known and h.knownUntil and steps >= h.knownUntil then
        h.known, h.knownUntil = nil, nil
        homes[id] = h
        changed = true
      end
    end
    if changed then saveHomes() end
  end

  local function night(ow)
    if not ow then return false end
    if type(ow.timeOfDay) == "function" then
      local ok, tod = pcall(function() return ow:timeOfDay() end)
      if ok and tod then
        tod = tostring(tod):upper()
        if tod == "NIGHT" or tod == "NITE" or tod == "MIDNIGHT" then return true end
      end
    end
    if ow.tod ~= nil then
      local tod = tostring(ow.tod):upper()
      if tod == "NIGHT" or tod == "NITE" then return true end
    end
    return false
  end

  local function resident(mapId)
    if mapId == nil then return false end
    local id = tostring(mapId):upper()
    if id:find("HOUSE", 1, true) then return true end
    if id:find("_HOME", 1, true) or id:find("HOME_", 1, true) then return true end
    -- Johto residences often end in names like PLAYERS_HOUSE_1F
    if id:find("PLAYERS_HOUSE", 1, true) then return true end
    if id:find("RIVALS_HOUSE", 1, true) then return true end
    if id:find("ELMS_HOUSE", 1, true) then return true end
    return false
  end

  local excludedHomes = {
    CERULEAN_TRASHED_HOUSE = true,
    BILLS_HOUSE = true,
    BLUES_HOUSE = true,
    REDS_HOUSE_1F = true,
    REDS_HOUSE_2F = true,
  }
  local excludedHomePatterns = { "SAFARI" }
  local excludedEntrances = {
    { map = "CERULEAN_CITY", x = 9, y = 9 },
  }
  local function isExcludedEntrance(world)
    if not (world and world.map and world.player) then return false end
    for _, e in ipairs(excludedEntrances) do
      if e.map == world.map.id and e.x == world.player.cellX and e.y == world.player.cellY then
        return true
      end
    end
    return false
  end
  local function isExcludedHome(dest)
    if excludedHomes[dest] then return true end
    for _, pattern in ipairs(excludedHomePatterns) do
      if tostring(dest):find(pattern, 1, true) then return true end
    end
    return false
  end

  local function resolveDestMap(data, warpDef, lastOutdoor)
    if not warpDef then return nil end
    if type(warpDef) == "string" then return warpDef end
    if warpDef.destMap then return warpDef.destMap end
    if warpDef.map then return warpDef.map end
    if Warp and Warp.destination and data then
      local ok, a = pcall(function()
        return Warp.destination(data, warpDef, lastOutdoor)
      end)
      if ok and a then return a end
    end
    return nil
  end

  local function frontDoor(world, dest)
    if not opt("common_courtesy") then return false end
    if not world or not world.map or not world.player then return false end
    if not (dest and resident(dest) and not resident(world.map.id)) then return false end
    if isExcludedEntrance(world) then return false end
    if isExcludedHome(dest) then return false end
    return true
  end

  local function isSpecialCharacter(npc)
    if not npc then return false end
    local d = npc.def
    if type(d) ~= "table" then return false end
    local sprite = tostring(d.sprite or ""):upper()
    local name = tostring(d.name or ""):upper()
    local text = tostring(d.text or ""):upper()
    if sprite:find("NURSE", 1, true) or name:find("NURSE", 1, true) then return true end
    if sprite:find("CLERK", 1, true) or sprite:find("MART", 1, true) then return true end
    if sprite:find("OAK", 1, true) or name:find("OAK", 1, true) then return true end
    if sprite:find("ELM", 1, true) or name:find("ELM", 1, true) then return true end
    if sprite:find("BILL", 1, true) or name:find("BILL", 1, true) then return true end
    if sprite:find("RIVAL", 1, true) or name:find("RIVAL", 1, true) then return true end
    if sprite:find("MOM", 1, true) or name:find("MOM", 1, true) then return true end
    if sprite:find("DAISY", 1, true) or name:find("DAISY", 1, true) then return true end
    if name:find("JOY", 1, true) or text:find("JOY", 1, true) then return true end
    if d.trainerClass or d.trainer then
      local c = tostring(d.trainerClass or d.trainer or ""):upper()
      if c:find("LEADER", 1, true) or c:find("ELITE", 1, true)
         or c:find("RIVAL", 1, true) or c:find("PROF", 1, true) then
        return true
      end
    end
    if npc.pikachuFollower then return true end
    if sprite:find("PIKACHU", 1, true) or sprite:find("POKEMON", 1, true)
       or sprite:find("BALL", 1, true) or sprite:find("FOSSIL", 1, true) then
      return true
    end
    if d.item or d.pokemon then return true end
    return false
  end

  -- The 3D character mods own the Player actor through Battle Art. Kanto
  -- Life owns NPC actors only and must never interfere with that provider.
  local function isPlayerActor(npc)
    if not npc then return false end
    -- Never identify the player by sprite/graphics. Custom Player Sprites G1R
    -- can replace the player's overworld sprite with a Pokemon, while the
    -- underlying actor remains the actual player object.
    if npc.isPlayer == true or npc.role == "player" then return true end
    local d = type(npc.def) == "table" and npc.def or {}
    if d.player == true or d.isPlayer == true then return true end
    local g = G and G() or game
    local ow = (g and g.overworld) or (mod.world and mod.world.overworld and mod.world:overworld())
    if ow and ow.player == npc then return true end
    if g and g.player == npc then return true end
    return false
  end

  local function wake(d)
    local c = tostring((d and (d.trainerClass or d.trainer)) or "")
    if c:find("ELITE", 1, true) then return "You woke an ELITE\nFOUR member!\nPrepare yourself!" end
    if c:find("LEADER", 1, true) then return "You woke a GYM\nLEADER! Let's battle!" end
    return "Hey! You woke me\nup! Let's battle!"
  end

  local function ensureSleepSchedule(npc)
    if npc.kantoLifeSleepSchedule ~= nil then return end
    if not opt("day_sleepers") then
      npc.kantoLifeSleepSchedule = "night"
      return
    end
    local h = ((npc.cellX or 0) * 17 + (npc.cellY or 0) * 31 + (npc.id and tostring(npc.id):len() or 0)) % 10
    npc.kantoLifeSleepSchedule = (h < 3) and "day" or "night"
  end
  local function npcSleepHash(npc, isNight)
    local s = tostring(npc.id or "")
    if s == "" and npc.def then s = tostring(npc.def.name or npc.def.sprite or "") end
    if s == "" then
      s = tostring(npc.cellX or npc.x or 0) .. "," .. tostring(npc.cellY or npc.y or 0)
    end
    -- Include spawn index / ambient flag so mod NPCs distribute across the band
    if npc.kantoLifeAmbient then s = s .. ":amb" end
    if npc.kantoLifeName then s = s .. ":" .. tostring(npc.kantoLifeName) end
    local idn = 0
    for i = 1, #s do idn = idn + s:byte(i) * (i + 3) end
    idn = idn + (tonumber(npc.cellX) or 0) * 7 + (tonumber(npc.cellY) or 0) * 13
    return (idn + (isNight and 0 or 97)) % 100
  end
  local function shouldSleepNow(npc, isNight)
    local pct = math.floor(tonumber(opt("sleep_pct")) or 15)
    if pct <= 0 then return false end
    if pct > 100 then pct = 100 end
    if pct >= 100 then return true end
    return npcSleepHash(npc, isNight) < pct
  end

  -- =====================================================================
  -- NPC ROUTINES / AGENDA
  -- Ported from TERRARIUM's Routines system, but kept self-contained so it
  -- cannot replace or alter any existing Kanto Life subsystem.  ROUTINES
  -- changes only idle civilian facings; AGENDA gives existing WALK NPCs a
  -- destination, using the engine's normal scriptMove one tile at a time
  -- when visible and an off-screen placement when neither end is visible.
  --
  -- Important Kanto-specific guards:
  --   * trainers / named story characters are never touched
  --   * Kanto Life Pokemon are never touched
  --   * sleeping NPCs are never touched by the agenda
  --   * Door Knocking remains independent
  --   * the vanilla NPC wander flag remains enabled during DAY
  -- =====================================================================
  -- scheduleTick is the single owner of Kanto Life NPC routines/agenda.
  -- The older helper is not started so it cannot fight the self-driven API.
  local kantoRoutines = nil
  do
    local KantoRoutines, routineErr = loadBundled("lib/KantoRoutines.lua")
    if type(KantoRoutines) ~= "function" then mod.log:error("KantoRoutines load failed: %s", tostring(routineErr)) end
    if type(KantoRoutines) == "function" then
      local okInit, instance = pcall(KantoRoutines, {
        mod = mod,
        game = function() return G() end,
        isIndoor = isIndoor,
        isTown = isTown,
        isRoute = isRoute,
        resolveDestMap = resolveDestMap,
        onRoutineExit = onRoutineExit,
      })
      if okInit and instance then
        kantoRoutines = instance
        pcall(function() kantoRoutines.setTravelPercent(opt("npc_travel_pct") or 30) end)
        pcall(function() kantoRoutines.setEnabled(opt("npc_routines") ~= false) end)
        pcall(function() kantoRoutines.setAgenda(opt("npc_agenda") or 0) end)
      else
        mod.log:error("KantoRoutines init failed: %s", tostring(instance))
      end
    end
  end

  mod.exports = mod.exports or {}
  mod.exports.kantoLifeRoutines = kantoRoutines

  local scheduleHandles = setmetatable({}, { __mode = "k" })
  local scheduleDoors = {}
  local scheduleLastMap = nil
  local scheduleLastNight = nil
  local scheduleDirty = true

  mod.events:on("mod.options_changed", function(payload)
    if not payload or payload.mod ~= mod.id then return end
    if payload.key == "npc_routines" or payload.key == "npc_agenda" or payload.key == "npc_travel_pct" then
      scheduleDirty = true
      if kantoRoutines then
        if payload.key == "npc_travel_pct" and type(kantoRoutines.setTravelPercent) == "function" then
          kantoRoutines.setTravelPercent(payload.value)
        elseif payload.key == "npc_routines" and type(kantoRoutines.setEnabled) == "function" then
          kantoRoutines.setEnabled(payload.value and true or false)
        elseif payload.key == "npc_agenda" and type(kantoRoutines.setAgenda) == "function" then
          kantoRoutines.setAgenda(payload.value)
        end
        local ow = mod.world and mod.world:overworld()
        if ow and type(kantoRoutines.update) == "function" then
          kantoRoutines.update(ow, 0, true)
        end
      end
    end
  end)
  local scheduleAccum = 0

  local SCHED_DIRS = { "up", "down", "left", "right" }
  local SCHED_DELTA = {
    up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
  }

  local function scheduleMode()
    local n = math.floor(tonumber(opt("npc_agenda")) or 0)
    if n < 0 then n = 0 elseif n > 2 then n = 2 end
    return n
  end

  local function scheduleIsNight(world)
    if not world then return false end
    local tod = nil
    if type(world.timeOfDay) == "function" then
      local ok, v = pcall(world.timeOfDay, world)
      if ok then tod = v end
    end
    if tod == nil then tod = world.tod end
    tod = tostring(tod or ""):upper()
    return tod == "NIGHT" or tod == "NITE" or tod == "MIDNIGHT"
  end

  local function scheduleIdle(npc)
    if not npc or isPlayerActor(npc) then return false end
    local d = npc.def or {}
    if isSpecialCharacter(npc) then return false end
    if d.trainerClass or d.trainer then return false end
    if isPokemonLike(npc) and not isPokeAmbient(npc) then return false end
    if isPokemonFollower(npc) then return false end
    if npc.nightlifeSleeping then return false end
    if npc.frozen or npc.moving then return false end
    if npc.dsShelter or npc.dsGlanceFacing ~= nil then return false end
    if npc._kantoServiceTraffic then return false end
    if npc.kantoLifeAmbient or d.kantoLifeAmbient then return false end
    return true
  end

  local function scheduleTravelSelected(npc)
    local d = npc and npc.def or {}
    if not npc then return false end
    if not (npc.kantoLifeAmbient or d.kantoLifeAmbient or npc.kantoLifePokeAmbient or d.kantoLifePokeAmbient) then return true end
    local pct = math.floor(tonumber(opt("npc_travel_pct")) or 30)
    if pct <= 0 then return false end
    if pct >= 100 then return true end
    local id = tostring(npc.id or d.name or d.sprite or "")
    local h = 0
    for i = 1, #id do h = (h * 33 + id:byte(i)) % 10000 end
    return (h % 100) < pct
  end

  local function scheduleWalker(npc)
    local d = npc and npc.def or {}
    if not npc or isPlayerActor(npc) or d.trainerClass or d.trainer or isSpecialCharacter(npc) then return false end
    if isPokemonFollower(npc) or npc.nightlifeSleeping or npc.frozen or npc.moving then return false end
    if npc._kantoServiceTraffic then return false end
    local ambient = npc.kantoLifeAmbient or d.kantoLifeAmbient
    local pokeAmbient = isPokeAmbient(npc) or npc.kantoLifePokeAmbient or d.kantoLifePokeAmbient
    if pokeAmbient and not ambient then return false end
    if ambient then
      return scheduleTravelSelected(npc) and (npc.wanders ~= false) and not (npc.kantoLifeWaterBound or d.kantoLifeWaterBound)
    end
    if not npc.wanders or isPokemonLike(npc) then return false end
    return true
  end

  local function scheduleAnchor(npc)
    if npc._kantoScheduleAnchorX == nil or npc._kantoScheduleAnchorY == nil then
      local d = npc.def or {}
      npc._kantoScheduleAnchorX = tonumber(d.x) or tonumber(npc.cellX) or 0
      npc._kantoScheduleAnchorY = tonumber(d.y) or tonumber(npc.cellY) or 0
    end
    return npc._kantoScheduleAnchorX, npc._kantoScheduleAnchorY
  end

  local function schedulePostFacing(npc)
    if npc._kantoSchedulePostFacing then return npc._kantoSchedulePostFacing end
    local r = tostring((npc.def or {}).range or ""):upper()
    local f = ({DOWN="down", UP="up", LEFT="left", RIGHT="right"})[r]
    npc._kantoSchedulePostFacing = f or npc.facing or "down"
    return npc._kantoSchedulePostFacing
  end

  local function scheduleDoorsFor(world)
    local map = world and world.map
    local mapId = map and map.id
    if not map then return {} end
    if scheduleDoors[mapId] then return scheduleDoors[mapId] end
    local out = {}
    local w = tonumber(map.width or (map.def and map.def.width))
    local h = tonumber(map.height or (map.def and map.def.height))
    if not w or not h then
      scheduleDoors[mapId] = out
      return out
    end
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local ok, yes = pcall(map.isDoorTileCell, map, x, y)
        if ok and yes then out[#out + 1] = { x, y } end
      end
    end
    scheduleDoors[mapId] = out
    return out
  end

  local function scheduleDoorFor(world, npc, claimed)
    local doors = scheduleDoorsFor(world)
    if #doors == 0 then return nil end
    local ax, ay = scheduleAnchor(npc)
    local best, bestD
    for _, d in ipairs(doors) do
      local key = d[1] .. "," .. d[2]
      local dist = math.abs(d[1] - ax) + math.abs(d[2] - ay)
      if not claimed[key] and (not bestD or dist < bestD) then
        best, bestD = d, dist
      end
    end
    return best
  end

  local function isServiceIndoor(mapId)
    local id = tostring(mapId or ""):upper()
    if not isIndoor(id) then return false end
    return id:find("MART", 1, true) ~= nil
       or id:find("POKEMON_CENTER", 1, true) ~= nil
       or id:find("POKECENTER", 1, true) ~= nil
       or id:find("POKE_CENTER", 1, true) ~= nil
       or id:find("CENTER", 1, true) ~= nil
  end

  local function scheduleOutdoorExitFor(world, npc, claimed)
    local map = world and world.map
    if not map then return nil end
    local mapId = tostring(map.id or "")
    local g = G(); local data = g and g.data
    local ax, ay = scheduleAnchor(npc)
    local best, bestD
    for _, w in ipairs((map.def and map.def.warps) or {}) do
      if w.x ~= nil and w.y ~= nil then
        local dest = resolveDestMap(data, w, world.lastOutdoor or world.backupWarp)
        local destId = tostring(dest or "")
        if destId ~= "" and destId ~= mapId then
          local key = tostring(w.x)..","..tostring(w.y)
          local d = math.abs(w.x-ax) + math.abs(w.y-ay)
          if not claimed[key] and (not bestD or d < bestD) then best, bestD = {w.x, w.y}, d end
        end
      end
    end
    return best
  end

  local function scheduleDestinations(world)
    local out, claimed = {}, {}
    local p = world and world.player
    if p then claimed[p.cellX .. "," .. p.cellY] = true end
    local mapId = world and world.map and tostring(world.map.id or "")
    local indoor = isIndoor(mapId, world and world.map)
    local fullNight = (not indoor) and scheduleMode() == 2 and scheduleIsNight(world)
    for _, n in ipairs(world.npcs or {}) do
      if not scheduleWalker(n) then claimed[(n.cellX or 0)..","..(n.cellY or 0)] = true end
    end
    for _, n in ipairs(world.npcs or {}) do
      if scheduleWalker(n) and not n._kantoServiceTraffic then
        local tx, ty = scheduleAnchor(n)
        local dfn = n.def or {}
        local ambient = n.kantoLifeAmbient or dfn.kantoLifeAmbient
        if ambient then
          local phase = n._kantoScheduleTravelPhase or "outbound"
          local wait = tonumber(n._kantoScheduleTravelWait) or 0
          if wait > 0 then
            n._kantoScheduleTravelWait = math.max(0, wait - 0.2)
            tx, ty = (phase == "home") and scheduleAnchor(n) or ((n._kantoScheduleTravelTarget and n._kantoScheduleTravelTarget[1]) or tx), ((phase == "home") and select(2, scheduleAnchor(n)) or ((n._kantoScheduleTravelTarget and n._kantoScheduleTravelTarget[2]) or ty))
          else
            if n._kantoScheduleTravelTarget and n.cellX == n._kantoScheduleTravelTarget[1] and n.cellY == n._kantoScheduleTravelTarget[2] then
              if phase == "outbound" then
                n._kantoScheduleTravelPhase = "home"
                n._kantoScheduleTravelWait = 3
                local ax, ay = scheduleAnchor(n); tx, ty = ax, ay
              else
                n._kantoScheduleTravelPhase = "outbound"
                local target = indoor and scheduleDoorFor(world, n, claimed) or scheduleOutdoorExitFor(world, n, claimed)
                if target then n._kantoScheduleTravelTarget = {target[1], target[2]}; tx, ty = target[1], target[2] else tx, ty = scheduleAnchor(n) end
                n._kantoScheduleTravelWait = 5
              end
            else
              local target = indoor and scheduleDoorFor(world, n, claimed) or scheduleOutdoorExitFor(world, n, claimed)
              if target then n._kantoScheduleTravelTarget = {target[1], target[2]}; tx, ty = target[1], target[2] else tx, ty = scheduleAnchor(n) end
            end
          end
        elseif fullNight then
          local target = scheduleDoorFor(world, n, claimed)
          if target then tx, ty = target[1], target[2] end
        end
        out[n] = {tx, ty}
        claimed[tx .. "," .. ty] = true
      end
    end
    return out
  end

  local function scheduleSeen(world, npc)
    local p = world and world.player
    if not p then return false end
    local dx = math.abs((npc.cellX or 0) - (p.cellX or 0))
    local dy = math.abs((npc.cellY or 0) - (p.cellY or 0))
    return dx <= 10 and dy <= 10
  end

  local function scheduleHandle(world, npc)
    local h = scheduleHandles[npc]
    if h then return h end
    local mapId = world and world.map and world.map.id
    if not mapId then return nil end
    local d = npc.def or {}
    local key = d.index or d.name or npc.id
    if key == nil then return nil end
    local ok, got = pcall(function() return mod.world:npc(mapId, key) end)
    if ok and got then scheduleHandles[npc] = got; return got end
    return nil
  end

  local function scheduleStepToward(world, npc, tx, ty)
    if npc.moving then return true end
    local cx, cy = npc.cellX or 0, npc.cellY or 0
    local dirs = {}
    if tx > cx then dirs[#dirs+1] = "right" elseif tx < cx then dirs[#dirs+1] = "left" end
    if ty > cy then dirs[#dirs+1] = "down" elseif ty < cy then dirs[#dirs+1] = "up" end
    local seen = {}; for _, d in ipairs(dirs) do seen[d] = true end
    for _, d in ipairs({"up","down","left","right"}) do if not seen[d] then dirs[#dirs+1] = d end end
    local h = scheduleHandle(world, npc)
    if not h then return false end
    for _, dir in ipairs(dirs) do
      if type(h.canStep) == "function" and type(h.stepNow) == "function" then
        local okCan, can = pcall(h.canStep, h, dir)
        if okCan and can then local ok = pcall(h.stepNow, h, dir); if ok then return true end end
      elseif type(h.stepNow) == "function" then
        local ok = pcall(h.stepNow, h, dir); if ok then return true end
      elseif type(h.scriptMove) == "function" then
        local ok = pcall(h.scriptMove, h, dir, 1); if ok then return true end
      end
    end
    return false
  end

  local function scheduleRoutineBeat(world, npc, nightNow)
    if not scheduleIdle(npc) then return end
    local r = love.math.random()
    local map = world.map
    local function interest()
      local cx, cy = npc.cellX, npc.cellY
      for _, dir in ipairs(SCHED_DIRS) do
        local d = SCHED_DELTA[dir]
        local x, y = cx + d[1], cy + d[2]
        if map and map.inBounds and map:inBounds(x, y) then
          local okS, sign = pcall(map.signAtCell, map, x, y)
          if okS and sign then return dir end
          local okD, door = pcall(map.isDoorTileCell, map, x, y)
          if okD and door then return dir end
        end
      end
      return nil
    end
    if not nightNow and r < 0.30 then
      for _, other in ipairs(world.npcs or {}) do
        if other ~= npc and scheduleIdle(other) then
          local dx = other.cellX - npc.cellX
          local dy = other.cellY - npc.cellY
          if (dx == 0 or dy == 0) and math.abs(dx) + math.abs(dy) <= 2
             and math.abs(dx) + math.abs(dy) > 0 then
            npc.facing = (dx > 0 and "right") or (dx < 0 and "left")
                         or (dy > 0 and "down") or "up"
            other.facing = (dx > 0 and "left") or (dx < 0 and "right")
                           or (dy > 0 and "up") or "down"
            npc._kantoScheduleBeat = 8 + love.math.random() * 8
            other._kantoScheduleBeat = npc._kantoScheduleBeat
            other._kantoScheduleChat = npc
            npc._kantoScheduleChat = other
            return
          end
        end
      end
    end
    if r < 0.55 or nightNow then
      local dir = interest()
      if dir then npc.facing = dir; npc._kantoScheduleBeat = 4 + love.math.random() * 7; return end
    end
    if r < 0.80 then
      for _ = 1, 4 do
        local dir = SCHED_DIRS[love.math.random(#SCHED_DIRS)]
        if dir ~= npc.facing then npc.facing = dir; npc._kantoScheduleBeat = 4 + love.math.random() * 7; return end
      end
    end
    npc.facing = schedulePostFacing(npc)
    npc._kantoScheduleBeat = 4 + love.math.random() * 7
  end

  local function scheduleRelease(npc)
    npc._kantoScheduleTargetX = nil
    npc._kantoScheduleTargetY = nil
    npc._kantoScheduleDoor = nil
    npc._kantoScheduleChat = nil
    npc._kantoScheduleBeat = nil
    if npc._kantoSchedulePassable ~= nil then
      npc.passable = npc._kantoSchedulePassable or nil
      npc._kantoSchedulePassable = nil
    end
  end

  -- Daytime agenda doorway traffic.
  -- In DAY and FULL, about 10% of the current Kanto Life ambient population
  -- participates in the doorway exchange during daytime. In FULL at night,
  -- the normal agenda sends all eligible walkers to their nighttime doors;
  -- the 10% daytime traffic cap does NOT restrict nighttime door behavior.
  -- The doorway exchange never changes population: one body is removed only
  -- after reaching the doorway and a replacement is created on that doorway.
  local trafficStates = {}
  local trafficNext = 12.0
  local trafficMap = nil

  local function trafficBuildingDoors(world)
    local map = world and world.map
    if not map then return {} end
    local mapId = tostring(map.id or "")
    local doors = scheduleDoorsFor(world)
    -- Inside a building, use its own door tiles. Outside, use only warps that
    -- actually resolve into an indoor building map.
    if isIndoor(mapId, map) then return doors end
    if not isTown(mapId) then return {} end
    local data = game and game.data
    local out, seen = {}, {}
    for _, w in ipairs((map.def and map.def.warps) or {}) do
      local dest = resolveDestMap(data, w, world.lastOutdoor or world.backupWarp)
      if dest and isIndoor(dest) and w.x and w.y then
        local key = tostring(w.x) .. "," .. tostring(w.y)
        if not seen[key] then seen[key] = true; out[#out + 1] = { w.x, w.y } end
      end
    end
    return out
  end

  local function trafficProfile(npc)
    local d = npc and npc.def or {}
    return {
      poke = isPokeAmbient(npc),
      sprite = d.sprite,
      species = npc.kantoLifeSpecies or d.kantoLifeSpecies,
      displayName = npc.kantoLifeDisplayName,
      gender = npc.kantoLifeGender,
    }
  end

  local function trafficSpawn(world, profile, x, y, role)
    if not world or not world.map or not profile or not profile.sprite then return nil end
    spawnSerial = spawnSerial + 1
    local isPoke = profile.poke and profile.species
    local name = isPoke
      and ("KANTO_TRAFFIC_POKE_" .. tostring(profile.species) .. "_" .. spawnSerial)
      or ("KANTO_TRAFFIC_" .. tostring(world.map.id) .. "_" .. spawnSerial)
    local id = mod.world:spawnNpc(world.map.id, {
      name = name, sprite = profile.sprite, x = x, y = y, text = "",
      movement = "WALK", range = "ANY_DIR", radius = { x = 8, y = 8 }, kantoLifeAmbient = true,
      kantoLifePokeAmbient = isPoke and true or nil,
      kantoLifeSpecies = isPoke and profile.species or nil,
      kantoLifeDisplayName = isPoke and profile.species or profile.displayName,
      kantoLifeGender = profile.gender,
    })
    local gotId = type(id) == "table" and id.id or id
    if not gotId then return nil end
    for _, n in ipairs(world.npcs or {}) do
      if n.id == gotId or (n.def and n.def.name == name) then
        n.def = n.def or {}
        n.def.kantoLifeAmbient = true
        if isPoke then
          n.def.kantoLifePokeAmbient = true
          n.def.kantoLifeSpecies = profile.species
          n.kantoLifePokeAmbient = true
          n.kantoLifeSpecies = profile.species
        end
        n._kantoServiceTraffic = role
        if isPoke then tagKantoPokemon(n, profile.species) end
        markKantoAmbientForTerrarium(n)
        return n
      end
    end
    return nil
  end

  local function trafficCandidates(world)
    local out = {}
    for _, n in ipairs(world.npcs or {}) do
      if not isPlayerActor(n) and isAmbientNpc(n) and not n._kantoServiceTraffic
         and not n.nightlifeSleeping and not n.frozen and not n.moving
         and not isPokemonFollower(n)
         and (not isPokemonLike(n) or isPokeAmbient(n)) and n.wanders then
        out[#out + 1] = n
      end
    end
    return out
  end

  local function trafficDoorAvailable(world, door)
    if not door then return false end
    local x, y = door[1], door[2]
    local p = world.player
    if p and p.cellX == x and p.cellY == y then return false end
    for _, n in ipairs(world.npcs or {}) do
      if n.cellX == x and n.cellY == y then return false end
    end
    return true
  end

  local function trafficPickDoor(world, avoid)
    local doors = trafficBuildingDoors(world)
    local usable = {}
    for _, d in ipairs(doors) do
      local same = avoid and d[1] == avoid[1] and d[2] == avoid[2]
      if not same and trafficDoorAvailable(world, d) then usable[#usable + 1] = d end
    end
    if #usable == 0 then return nil end
    return usable[love.math.random(#usable)]
  end

  local function trafficEligible(npc)
    local s = tostring(npc and npc.id or npc and npc.def and npc.def.name or "")
    if s == "" then return false end
    local h = 0
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 100 end
    return h < 10
  end

  local function trafficActiveCount()
    local n = 0
    for _ in pairs(trafficStates) do n = n + 1 end
    return n
  end

  local function trafficMax(world)
    local ambient = 0
    for _, n in ipairs(world.npcs or {}) do
      if isAmbientNpc(n) and not n._kantoServiceTraffic then ambient = ambient + 1 end
    end
    return math.max(1, math.ceil(ambient * 0.10))
  end

  local function trafficStart(world)
    -- The 10% doorway exchange is a daytime behavior for both DAY and FULL.
    if scheduleMode() == 0 or scheduleIsNight(world) then return end
    local mapId = tostring(world and world.map and world.map.id or "")
    if not world or not mapId or not isTown(mapId) then return end
    if trafficActiveCount() >= trafficMax(world) then return end
    local candidates, eligible = trafficCandidates(world), {}
    for _, n in ipairs(candidates) do
      if trafficEligible(n) then eligible[#eligible + 1] = n end
    end
    if #eligible == 0 then return end
    local npc = eligible[love.math.random(#eligible)]
    local door = trafficPickDoor(world)
    if not door then return end
    local ax, ay = scheduleAnchor(npc)
    trafficStates[npc] = {
      phase = "depart", npc = npc, profile = trafficProfile(npc),
      anchorX = ax, anchorY = ay, doorX = door[1], doorY = door[2],
      stuck = 0, timer = 0, night = scheduleIsNight(world),
    }
    npc._kantoServiceTraffic = "depart"
  end

  local function trafficFinish(key)
    trafficStates[key] = nil
    trafficNext = 14 + love.math.random() * 20
  end

  local function trafficTick(world, dt)
    -- DAY and FULL get the 10% daytime doorway exchange. FULL nighttime
    -- doorway behavior is handled separately by scheduleDestinations().
    if scheduleMode() == 0 or scheduleIsNight(world) then
      trafficStates = {}; trafficMap = nil; trafficNext = 12; return
    end
    local mapId = tostring(world and world.map and world.map.id or "")
    if trafficMap ~= mapId then trafficMap = mapId; trafficStates = {}; trafficNext = 8 end
    if not world or not world.map or not isTown(mapId) then return end
    trafficNext = trafficNext - (dt or 0)
    if trafficNext <= 0 then trafficStart(world); trafficNext = 10 + love.math.random() * 16 end

    for key, st in pairs(trafficStates) do
      local npc = st.npc
      if not npc or npc.hidden then trafficFinish(key); goto nextState end
      if npc.nightlifeSleeping or npc.frozen then trafficFinish(key); goto nextState end

      if st.phase == "depart" then
        if npc.cellX == st.doorX and npc.cellY == st.doorY then
          local profile = st.profile
          destroyAmbient(world, npc)
          local replacement = trafficSpawn(world, profile, st.doorX, st.doorY, "visitor")
          if not replacement then
            -- Restore the population immediately if a spawn fails.
            replacement = trafficSpawn(world, profile, st.doorX, st.doorY, "restore")
          end
          if not replacement then trafficFinish(key); goto nextState end
          st.npc, st.phase, st.timer, st.stuck = replacement, "visit", 6 + love.math.random() * 8, 0
          st.lastDoor = { st.doorX, st.doorY }
          goto nextState
        end
        local bx, by = npc.cellX, npc.cellY
        if not npc.moving then scheduleStepToward(world, npc, st.doorX, st.doorY) end
        if bx == npc.cellX and by == npc.cellY then st.stuck = st.stuck + 1 else st.stuck = 0 end
        if st.stuck > 30 then trafficFinish(key) end
      elseif st.phase == "visit" then
        st.timer = st.timer - (dt or 0)
        if st.timer <= 0 then
          local d = trafficPickDoor(world, st.lastDoor)
          if d then
            st.doorX, st.doorY = d[1], d[2]
            st.phase, st.stuck = "return", 0
            npc._kantoServiceTraffic = "return"
          else
            st.timer = 3
          end
        end
      elseif st.phase == "return" then
        if npc.cellX == st.doorX and npc.cellY == st.doorY then
          local profile = trafficProfile(npc)
          destroyAmbient(world, npc)
          local replacement = trafficSpawn(world, profile, st.doorX, st.doorY, "visitor")
          if not replacement then replacement = trafficSpawn(world, profile, st.doorX, st.doorY, "restore") end
          if not replacement then trafficFinish(key); goto nextState end
          st.npc, st.phase, st.timer, st.stuck = replacement, "visit", 6 + love.math.random() * 8, 0
          st.lastDoor = { st.doorX, st.doorY }
          goto nextState
        end
        local bx, by = npc.cellX, npc.cellY
        if not npc.moving then scheduleStepToward(world, npc, st.doorX, st.doorY) end
        if bx == npc.cellX and by == npc.cellY then st.stuck = st.stuck + 1 else st.stuck = 0 end
        if st.stuck > 30 then trafficFinish(key) end
      end
      ::nextState::
    end
  end

  local function scheduleTick(world, dt)
    if not world or not world.map or not world.player or not world.npcs then return end
    -- KantoRoutines is the sole owner of Kanto Life spawned-NPC travel and
    -- agenda. Default FireRed map NPCs are intentionally never handed to a
    -- routine scheduler here.
    for _, n in ipairs(world.npcs or {}) do
      local d = n.def or {}
      if d.kantoLifeAmbient then
        d.dsSpecies = d.dsSpecies or "KANTO_LIFE_AMBIENT"
        n.def = d
      end
    end
    syncTerrariumSettings()
    if kantoRoutines and type(kantoRoutines.update) == "function" then
      local ok, err = pcall(function() kantoRoutines.update(world, dt or 0, false) end)
      if not ok then mod.log:error("Kanto Life routines update: %s", tostring(err)) end
    end
    -- EXPERIMENTAL: proximity greetings — ambient NPCs acknowledge the player
    -- with a brief bubble when walked past (not sleeping, cooldown per NPC).
    -- EXPERIMENTAL: idle behaviors — idle NPCs occasionally look around or
    -- show a thought bubble, so they feel alive when not moving.
    pcall(function()
      local player = world.player
      if not player then return end
      local px, py = tonumber(player.cellX), tonumber(player.cellY)
      if not px or not py then return end
      local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
      -- EXPERIMENTAL: time-of-day awareness — greetings shift with the clock.
      local hour = tonumber(os.date("%H")) or 12
      local timeOfDay
      if hour >= 5 and hour < 12 then timeOfDay = "morning"
      elseif hour >= 12 and hour < 18 then timeOfDay = "afternoon"
      elseif hour >= 18 and hour < 22 then timeOfDay = "evening"
      else timeOfDay = "night" end
      local greetingsByTime = {
        morning = { "Morning!", "Good morning!", "Hey!", "Hi there!", "Rise and shine!" },
        afternoon = { "Afternoon!", "Hey there!", "Hi!", "Yo!", "How's it going?" },
        evening = { "Evening!", "Hey!", "Hi there!", "Good evening!", "Yo!" },
        night = { "Oh, hi.", "Evening...", "*yawn* Hey.", "Hey...", "Still up?" },
      }
      local greetings = greetingsByTime[timeOfDay] or greetingsByTime.afternoon
      local idleThoughtsByTime = {
        morning = { "...", "Hmm.", "*stretch*", "What a day!", "La la..." },
        afternoon = { "...", "Hmm.", "La la...", "Nice weather.", "*stretch*" },
        evening = { "...", "Hmm.", "La la...", "What a day.", "*sigh*" },
        night = { "...", "*yawn*", "Hmm.", "*yawn*", "So sleepy..." },
      }
      local idleThoughts = idleThoughtsByTime[timeOfDay] or idleThoughtsByTime.afternoon
      local dirs = { "up", "down", "left", "right" }
      -- EXPERIMENTAL: track player movement — stillness (for face-the-player)
      -- and running (for startled reactions).
      local playerStill = false
      local playerRunning = false
      local lastPX = tonumber(world._kantoLifePlayerLastX)
      local lastPY = tonumber(world._kantoLifePlayerLastY)
      if lastPX == px and lastPY == py then
        playerStill = true
      else
        if lastPX and lastPY then
          local moved = math.abs(px - lastPX) + math.abs(py - lastPY)
          if moved >= 2 then playerRunning = true end
        end
        world._kantoLifePlayerLastX = px
        world._kantoLifePlayerLastY = py
      end
      for _, n in ipairs(world.npcs or {}) do
        local d = n.def or {}
        if d.kantoLifeAmbient and not n.nightlifeSleeping then
          -- EXPERIMENTAL: face the player — idle NPCs turn to look at you
          -- when you stand still nearby.
          if playerStill and not n.moving then
            local nx0, ny0 = tonumber(n.cellX), tonumber(n.cellY)
            if nx0 and ny0 then
              local pdist = math.abs(nx0 - px) + math.abs(ny0 - py)
              if pdist <= 2 and pdist > 0 then
                local dx, dy = px - nx0, py - ny0
                local face
                if math.abs(dx) >= math.abs(dy) then
                  face = dx > 0 and "right" or "left"
                else
                  face = dy > 0 and "down" or "up"
                end
                if face and n.facing ~= face then n.facing = face end
              end
            end
          end
          -- EXPERIMENTAL: startled reaction — NPCs notice when you sprint past.
          if playerRunning and not n.moving then
            local nx0, ny0 = tonumber(n.cellX), tonumber(n.cellY)
            if nx0 and ny0 then
              local pdist = math.abs(nx0 - px) + math.abs(ny0 - py)
              if pdist <= 2 and pdist > 0 then
                local lastStartle = tonumber(n._kantoLifeLastStartle) or 0
                if now - lastStartle > 15 then  -- 15s cooldown
                  n._kantoLifeLastStartle = now
                  local bubbleUntil2 = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
                  if bubbleUntil2 <= now then
                    n._kantoLifeCollisionBubbleText = "!"
                    n._kantoLifeCollisionBubbleUntil = now + 1.0
                  end
                  -- Turn to face the runner
                  local dx, dy = px - nx0, py - ny0
                  local face
                  if math.abs(dx) >= math.abs(dy) then
                    face = dx > 0 and "right" or "left"
                  else
                    face = dy > 0 and "down" or "up"
                  end
                  if face then n.facing = face end
                end
              end
            end
          end
          -- Skip if already showing a bubble (traveler greeting, collision, etc.)
          local bubbleUntil = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
          if bubbleUntil <= now then
            local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
            if nx and ny then
              local dist = math.abs(nx - px) + math.abs(ny - py)
              if dist <= 3 and dist > 0 then
                local lastGreet = tonumber(n._kantoLifeLastGreet) or 0
                if now - lastGreet > 30 then  -- 30s cooldown per NPC
                  n._kantoLifeLastGreet = now
                  n._kantoLifeCollisionBubbleText = greetings[math.random(1, #greetings)]
                  n._kantoLifeCollisionBubbleUntil = now + 2.0
                end
              end
            end
          end
          -- Idle behavior: only when standing still (not moving, no routine step)
          if not n.moving then
            local lastIdle = tonumber(n._kantoLifeLastIdle) or 0
            if now - lastIdle > 25 + math.random() * 20 then  -- 25-45s
              n._kantoLifeLastIdle = now
              if math.random() < 0.7 then
                -- Look around: face a random direction
                n.facing = dirs[math.random(1, 4)]
              else
                -- Thought bubble (only if no other bubble active)
                if bubbleUntil <= now then
                  n._kantoLifeCollisionBubbleText = idleThoughts[math.random(1, #idleThoughts)]
                  n._kantoLifeCollisionBubbleUntil = now + 1.5
                end
              end
            end
          end
        end
      end
      -- EXPERIMENTAL: NPC-to-NPC chatter — nearby idle NPCs exchange brief
      -- bubbles. One initiates, the other responds after a short delay.
      pcall(function()
        local now2 = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
        -- First, deliver any pending responses that are due
        for _, n in ipairs(world.npcs or {}) do
          local pending = n._kantoLifeChatReply
          if pending and tonumber(pending.at) and now2 >= tonumber(pending.at) then
            n._kantoLifeChatReply = nil
            local bubbleUntil = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
            if bubbleUntil <= now2 and not n.nightlifeSleeping and not n.moving then
              n._kantoLifeCollisionBubbleText = pending.text
              n._kantoLifeCollisionBubbleUntil = now2 + 2.0
            end
          end
        end
        -- Look for a new chatter pair (throttled: check every ~10s)
        local lastChatScan = tonumber(world._kantoLifeLastChatScan) or 0
        if now2 - lastChatScan > 10 then
          world._kantoLifeLastChatScan = now2
          local chatterOpeners = { "Hey!", "Psst!", "Yo!", "..." }
          local chatterReplies = { "Huh?", "Yeah?", "Hi!", "!", "..." }
          local candidates = {}
          for _, n in ipairs(world.npcs or {}) do
            local d = n.def or {}
            if d.kantoLifeAmbient and not n.nightlifeSleeping and not n.moving then
              local bubbleUntil = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
              if bubbleUntil <= now2 and not n._kantoLifeChatReply then
                local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
                if nx and ny then candidates[#candidates + 1] = n end
              end
            end
          end
          -- Find two NPCs within 2 tiles of each other
          for i = 1, #candidates do
            local a = candidates[i]
            local ax, ay = tonumber(a.cellX), tonumber(a.cellY)
            for j = i + 1, #candidates do
              local b = candidates[j]
              local bx, by = tonumber(b.cellX), tonumber(b.cellY)
              if math.abs(ax - bx) + math.abs(ay - by) <= 2 then
                local lastChat = math.max(tonumber(a._kantoLifeLastChat) or 0, tonumber(b._kantoLifeLastChat) or 0)
                if now2 - lastChat > 60 then  -- 60s cooldown per pair
                  a._kantoLifeLastChat = now2
                  b._kantoLifeLastChat = now2
                  a._kantoLifeCollisionBubbleText = chatterOpeners[math.random(1, #chatterOpeners)]
                  a._kantoLifeCollisionBubbleUntil = now2 + 2.0
                  b._kantoLifeChatReply = {
                    text = chatterReplies[math.random(1, #chatterReplies)],
                    at = now2 + 1.5,
                  }
                  break
                end
              end
            end
            if a._kantoLifeLastChat == now2 then break end
          end
        end
      end)
      -- EXPERIMENTAL: ambient Pokémon cries — wild/ambient Pokémon NPCs
      -- occasionally vocalize. Long cooldown so it's atmospheric, not spammy.
      pcall(function()
        local now3 = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
        for _, n in ipairs(world.npcs or {}) do
          if isPokemonLike(n) and not n.nightlifeSleeping and not n.moving then
            -- Skip followers (they belong to other mods)
            if not isPokemonFollower(n) then
              local lastCry = tonumber(n._kantoLifeLastCry) or 0
              if now3 - lastCry > 60 + math.random() * 60 then  -- 60-120s
                n._kantoLifeLastCry = now3
                local species = speciesLabelFromNpc(n)
                if species and playSpeciesCry then
                  playSpeciesCry(species)
                  -- Small bubble with the species name, like the games do
                  local bubbleUntil = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
                  if bubbleUntil <= now3 then
                    n._kantoLifeCollisionBubbleText = species .. "!"
                    n._kantoLifeCollisionBubbleUntil = now3 + 1.5
                  end
                end
              end
            end
          end
        end
      end)
    end)
  end

  -- Forward declaration: bakeSleepSprite can trigger a rebake on sleep-style
  -- change, which calls restoreSleepSprite (defined below). Without this the
  -- reference inside bakeSleepSprite would resolve to a nil global.
  local restoreSleepSprite

  -- Bake ±90° sleep frame into sprite.image so pose is real pixels (voxel + 2D)
  local function bakeSleepSprite(npc)
    if not npc or not npc.sprite then return false end
    local sprite = npc.sprite
    local curStyle = math.floor(tonumber(opt("sleep_style")) or 0)
    if sprite._kantoSleepBaked then
      -- Rebake if the sleep style changed (e.g. tent vs bed rotation).
      if sprite._kantoSleepBakedStyle == curStyle then return true end
      restoreSleepSprite(npc)
    end
    local angle = npc.kantoLifeSleepAngle or (math.pi / 2)
    -- Tent style (1): NPC stays upright inside the tent; the tent prop is
    -- drawn upright, so a 90-degree baked rotation would look wrong.
    if curStyle == 1 then
      angle = 0
    end
    local fw = tonumber(sprite.frameWidth) or 16
    local fh = tonumber(sprite.frameHeight) or 16
    local ok, canvas = pcall(function()
      local img = sprite.image
      if not img and type(sprite.resolveImage) == "function" then
        local ok2, r = pcall(function() return sprite:resolveImage() end)
        if ok2 then img = r end
      end
      if not img then return nil end
      local quad = sprite.frames and (sprite.frames[0] or sprite.frames[1])
      local c = love.graphics.newCanvas(fw, fh)
      local prev = love.graphics.getCanvas()
      love.graphics.setCanvas(c)
      love.graphics.clear(0, 0, 0, 0)
      love.graphics.setBlendMode("alpha")
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.push()
      love.graphics.translate(fw / 2, fh / 2)
      love.graphics.rotate(angle)
      love.graphics.translate(-fw / 2, -fh / 2)
      if quad then love.graphics.draw(img, quad, 0, 0)
      else love.graphics.draw(img, 0, 0) end
      love.graphics.pop()
      love.graphics.setCanvas(prev)
      return c
    end)
    if not (ok and canvas) then return false end
    sprite._kantoOrigImage = sprite.image
    sprite._kantoOrigFrames = sprite.frames
    sprite._kantoOrigFrameCount = sprite.frameCount
    sprite._kantoOrigDef = sprite.def
    sprite.image = canvas
    local qok, q = pcall(love.graphics.newQuad, 0, 0, fw, fh, fw, fh)
    if qok then
      sprite.frames = { [0] = q }
      sprite.frameCount = 1
    end
    local newDef = {}
    if type(sprite.def) == "table" then
      for k, v in pairs(sprite.def) do newDef[k] = v end
    end
    newDef.trueColor = true
    newDef.frames = 1
    newDef.walker = false
    sprite.def = newDef
    sprite._kantoSleepBaked = true
    sprite._kantoSleepBakedStyle = math.floor(tonumber(opt("sleep_style")) or 0)
    return true
  end

  restoreSleepSprite = function(npc)
    if not npc or not npc.sprite or not npc.sprite._kantoSleepBaked then return end
    local sprite = npc.sprite
    if sprite._kantoOrigImage ~= nil then sprite.image = sprite._kantoOrigImage end
    if sprite._kantoOrigFrames ~= nil then sprite.frames = sprite._kantoOrigFrames end
    if sprite._kantoOrigFrameCount ~= nil then sprite.frameCount = sprite._kantoOrigFrameCount end
    if sprite._kantoOrigDef ~= nil then sprite.def = sprite._kantoOrigDef end
    sprite._kantoOrigImage, sprite._kantoOrigFrames = nil, nil
    sprite._kantoOrigFrameCount, sprite._kantoOrigDef = nil, nil
    sprite._kantoSleepBaked = nil
    sprite._kantoSleepBakedStyle = nil
  end

  -- Exact vanilla Yellow sleeper: Viridian City's southwest sleeping Old Man.
  -- The map data uses object index 5 and sprite SPRITE_GAMBLER_ASLEEP.
  -- Leave this actor's original sprite object completely untouched so
  -- Porygonal can resolve its authored gambler_asleep 3D model.
  local function isViridianSleepyOldMan(npc)
    if not npc then return false end
    local id = tostring(npc.id or ""):upper()
    if id == "VIRIDIAN_CITY_OBJ_5" then return true end
    local spr = npc.sprite and npc.sprite.def
    local sid = tostring((spr and spr.id) or ""):upper()
    return sid == "SPRITE_GAMBLER_ASLEEP" and id:find("VIRIDIAN_CITY_OBJ_", 1, true) ~= nil
  end

function putToSleep(npc)
    if not npc or isPlayerActor(npc) then return end
    if isPokemonFollower(npc) then return end
    if (npc.wild or npc.isWild or npc.wildPokemon) and not isPokeAmbient(npc) then return end
    if isSpecialCharacter(npc) then return end
    if npc.nightlifeSleeping then return end
    if type(npc.def) ~= "table" then npc.def = {} end
    npc.nightlifeSleeping = true
    if npc.facing ~= nil then npc.kantoLifeSleepFacing = npc.facing end
    if npc.direction ~= nil then npc.kantoLifeSleepDir = npc.direction end
    local sign = ((npc.cellX or 0) + (npc.cellY or 0)) % 2 == 0 and 1 or -1
    npc.kantoLifeSleepAngle = sign * (math.pi / 2)
    npc.kantoLifeSleepSide = sign
    -- Hard stop (see NPC:update — frozen blocks NEW wanders; moving must be cleared)
    npc.frozen = true
    npc.moving = false
    npc.marching = false
    npc.progress = 0
    npc.hopStep = nil
    if type(npc.cellX) == "number" and type(npc.cellY) == "number" then
      npc.px, npc.py = npc.cellX * 16, npc.cellY * 16
    end
    if npc._kantoOrigWanders == nil then npc._kantoOrigWanders = npc.wanders end
    if npc._kantoOrigSteps == nil then npc._kantoOrigSteps = npc.steps end
    npc.wanders = false
    npc.steps = false
    npc.timer = 99999
    pcall(function()
      if type(npc.face) == "function" then npc:face("down")
      else npc.facing = "down" end
    end)
    if type(npc.def) == "table" then
      if npc.def.range ~= nil and npc.kantoLifeSleepRange == nil then
        npc.kantoLifeSleepRange = npc.def.range
        npc.def.range = "NONE"
      end
      npc.def.sleeping = true
    end
    npc.sleepPose = true
    -- Do not replace the vanilla asleep Old Man sprite. Porygonal already
    -- owns the correct authored 3D lying model for SPRITE_GAMBLER_ASLEEP.
    if isViridianSleepyOldMan(npc) then
      npc._kantoSleepSpriteActive = nil
      npc._kantoSleepVoxelFrames = nil
      npc._kantoSleepVoxelPaths = nil
      npc._kantoSleepIsHgss = nil
      return
    end
  end
  wakeNpc = function(npc)
    if not npc or not npc.nightlifeSleeping then return end
    npc.nightlifeSleeping = nil
    npc.frozen = false
    npc.sleepPose = nil
    npc.kantoLifeSleepAngle = nil
    restoreSleepSprite(npc)
    if npc.sprite then
      npc.sprite._sleepScreenX = nil
      npc.sprite._sleepScreenY = nil
    end
    if npc.def then npc.def.sleeping = nil end
    if npc.kantoLifeSleepFacing then
      npc.facing = npc.kantoLifeSleepFacing
      npc.kantoLifeSleepFacing = nil
    end
    if npc.def and npc.kantoLifeSleepRange ~= nil then
      npc.def.range = npc.kantoLifeSleepRange
      npc.kantoLifeSleepRange = nil
    end
    if npc._kantoOrigWanders ~= nil then
      npc.wanders = npc._kantoOrigWanders
      npc._kantoOrigWanders = nil
    end
    if npc._kantoOrigSteps ~= nil then
      npc.steps = npc._kantoOrigSteps
      npc._kantoOrigSteps = nil
    end
    if npc._kantoOrigSprite then
      npc.sprite = npc._kantoOrigSprite
      npc._kantoOrigSprite = nil
    end
    npc.timer = love.math.random(30, 120)
  end

  local function facingCell(world)
    local p = world and world.player
    if not p then return nil, nil end
    if type(p.facingCell) == "function" then
      local ok, x, y = pcall(function() return p:facingCell() end)
      if ok then return x, y end
    end
    local deltas = { up = {0,-1}, down = {0,1}, left = {-1,0}, right = {1,0} }
    local d = deltas[p.facing] or {0, 1}
    return (p.cellX or 0) + d[1], (p.cellY or 0) + d[2]
  end

  local function warpAt(world, x, y)
    if not (world and world.map and x and y) then return nil end
    local m = world.map
    if type(m.warpAtCell) == "function" then return m:warpAtCell(x, y) end
    if type(m.warpAt) == "function" then return m:warpAt(x, y) end
    return nil
  end

  local function pushText(g, world, msg, onDone, opts)
    if not msg then return end
    if g and g.stack and TextBox and Strings then
      g.stack:push(TextBox.new(g, Strings(msg), onDone, opts))
      return true
    end
    if world and type(world.showText) == "function" then
      world:showText(msg, onDone)
      return true
    end
    return false
  end

  local function liveWorld()
    if mod.world and type(mod.world.overworld) == "function" then
      local ok, w = pcall(function() return mod.world:overworld() end)
      if ok and w then return w end
    end
    local g = G()
    if g and g.overworld then return g.overworld end
    if g and g.world then return g.world end
    return nil
  end

  local pendingTrespass = mod.save:get("pendingTrespass")

  local function courtesyInteract(world)
    local g = G()
    if not opt("common_courtesy") then return false end
    if not world then world = liveWorld() end
    if not (world and world.player and world.map) then return false end
    local x, y = facingCell(world)
    if not x then return false end
    local at = warpAt(world, x, y)
    if not at then return false end
    local def = at.def or at
    local dest = resolveDestMap(g and g.data, def, world.lastOutdoor or world.backupWarp)
    if not dest and def.destMap and def.destMap ~= "LAST_MAP" then
      dest = def.destMap
    end
    if not frontDoor(world, dest) or isHomeKnown(dest) then return false end
    -- Yes/No knock prompt
    local function doWarpIn()
      world.kantoLifeWelcome = dest
      if type(world.takeWarp) == "function" then
        world:takeWarp(def)
      elseif Overworld and type(Overworld.takeWarp) == "function" then
        -- Gen2 facade takes warpDef only
        if gen1 then
          Overworld.takeWarp(world, def)
        else
          Overworld.takeWarp(def)
        end
      end
    end
    local shown = pushText(g, world, "KNOCK before\nentering?", nil, {
      choice = function(yes)
        local h = homes[key(dest)] or {}
        if yes then
          h.knocked = true
          homes[key(dest)] = h
          saveHomes()
          -- Clear any trespass from a prior walk-in
          pendingTrespass = nil
          mod.save:set("pendingTrespass", nil)
          if world then world.kantoLifeTrespass = nil end
          pushText(g, world, "KNOCK! KNOCK!\nCome in!", doWarpIn)
        else
          h.enterWithoutKnockUntil = now() + 10
          homes[key(dest)] = h
          saveHomes()
        end
      end
    })
    return shown and true or true -- handled even if text failed
  end



  -- Battle-style floating "Z"s above sleeping NPCs (scaled ~1/3 of a head).
  
  local function sleepZzzSeed(npc)
    local x = tonumber(npc and (npc.cellX or npc.x or npc.px)) or 0
    local y = tonumber(npc and (npc.cellY or npc.y or npc.py)) or 0
    return math.floor(x * 17 + y * 31) % 1000
  end

  local sleepAccessoryCache = {}
  local function sleepAccessoryImage(style)
    style = math.floor(tonumber(style) or 0)
    if style == 0 then return nil end
    local names = {[1]="sleep_tent.png",[2]="sleeping_bag.png",[3]="sleep_bed.png"}
    local rel = names[style]; if not rel then return nil end
    if sleepAccessoryCache[rel] then return sleepAccessoryCache[rel] end
    local path = rel
    local ok, img = false, nil
    -- Prefer the mod asset cache API. This is the engine-supported way to
    -- resolve bundled art and avoids a generation-specific 2D/voxel path
    -- mismatch. Keep the old path fallback for older runtimes.
    if mod.assets and type(mod.assets.image) == "function" then
      ok, img = pcall(mod.assets.image, mod.assets, "assets/" .. rel)
    end
    if not ok or not img then
      if mod.assets and type(mod.assets.path) == "function" then path = mod.assets:path("assets/" .. rel) end
      ok, img = pcall(love.graphics.newImage, path)
    end
    if ok and img then img:setFilter("nearest","nearest"); sleepAccessoryCache[rel]=img; return img end
    return nil
  end
  local function drawSleepAccessory(npc, sx, sy)
    local style = math.floor(tonumber(opt("sleep_style")) or 0)
    if style == 0 then return end
    local img = sleepAccessoryImage(style); if not img then return end
    local iw, ih = img:getDimensions()
    local angle = npc.kantoLifeSleepAngle or (math.pi / 2)
    local cx, cy = sx + 8, sy + 8
    love.graphics.push("all")
    love.graphics.setColor(1,1,1,1)
    local shiftX = style == 1 and 0 or (-math.sin(angle) * 6.5)
    love.graphics.translate(cx + shiftX, cy)
    if style ~= 1 then love.graphics.rotate(angle) end
    love.graphics.translate(-iw/2, -ih/2)
    love.graphics.draw(img, 0, 0)
    love.graphics.pop()
  end
  local function drawSleepTentOverlay(npc, sx, sy) return end

  local function drawSleepZzz(sx, sy, seed)
    if opt("sleep_bubbles") == false then return end
    if sx == nil or sy == nil then return end
    seed = seed or 0
    local side = (seed % 2 == 0) and -1 or 1
    local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    love.graphics.push("all")
    for i = 0, 1 do
      local phase = t * 1.5 + i * 0.8 + seed * 0.04
      local cycle = phase % 2.0
      local rise = cycle * 4
      local alpha = 1 - cycle / 2.0
      if alpha > 0.22 then
        local sc = 0.55 + i * 0.2
        local zx = sx + side * (2 + i * 3)
        local zy = sy - 4 - rise - i * 2
        love.graphics.setColor(1, 1, 1, alpha)
        love.graphics.print("Z", zx - 1, zy, 0, sc, sc)
        love.graphics.print("Z", zx + 1, zy, 0, sc, sc)
        love.graphics.print("Z", zx, zy - 1, 0, sc, sc)
        love.graphics.print("Z", zx, zy + 1, 0, sc, sc)
        love.graphics.setColor(0.15, 0.1, 0.4, alpha)
        love.graphics.print("Z", zx, zy, 0, sc, sc)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.pop()
  end

  local function drawCollisionBubble(npc, sx, sy)
    if opt("npc_collision_bubbles") == false then return end
    local untilAt = tonumber(npc and npc._kantoLifeCollisionBubbleUntil) or 0
    local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    if untilAt <= now then return end
    local text = tostring(npc._kantoLifeCollisionBubbleText or ":)")
    local G = love.graphics
    G.push("all")
    local font = G.getFont and G.getFont() or nil
    local tw = font and font:getWidth(text) or (#text * 6)
    local w, h = math.max(18, tw + 8), 12
    local x, y = math.floor(sx - w/2), math.floor(sy - 14)
    G.setColor(1,1,1,1); G.rectangle("fill", x, y, w, h, 2, 2)
    G.setColor(0.1,0.1,0.1,1); G.rectangle("line", x, y, w, h, 2, 2)
    G.polygon("fill", x + w/2 - 2, y + h, x + w/2 + 2, y + h, x + w/2, y + h + 3)
    G.print(text, x + 4, y + 1)
    G.pop()
  end

  -- Draw: engine handles the (baked) lying sprite like SPRITE_GAMBLER_ASLEEP;
  -- we only add Zzz above the head in screen space.
  do
    local NPCMod = NPC or safeRequire("src.world.NPC")
    if NPCMod and type(NPCMod.draw) == "function" then
      local baseNpcDraw = NPCMod.draw
      NPCMod.draw = function(self, camX, camY)
        if self.nightlifeSleeping then
          if self.sprite and not self.sprite._kantoSleepBaked then
            pcall(bakeSleepSprite, self)
          end
          local px0 = self.px or self.x or ((self.cellX or 0) * 16) or 0
          local py0 = self.py or self.y or ((self.cellY or 0) * 16) or 0
          local psx, psy = px0 - (camX or 0), py0 - (camY or 0)
          baseNpcDraw(self, camX, camY)
          drawSleepAccessory(self, psx, psy)
          local px = self.px or self.x or ((self.cellX or 0) * 16) or 0
          local py = self.py or self.y or ((self.cellY or 0) * 16) or 0
          local sx, sy = px - (camX or 0) + 8, py - (camY or 0) - 6
          if self.sprite and type(self.sprite.getScreenOrigin) == "function" then
            local ok, ox, oy = pcall(function()
              return self.sprite:getScreenOrigin(px, py, camX or 0, camY or 0)
            end)
            if ok and ox then sx, sy = ox + 8, oy - 4 end
          end
          drawSleepZzz(sx, sy, sleepZzzSeed(self))
          return
        end
        local r = baseNpcDraw(self, camX, camY)
        local px = self.px or self.x or ((self.cellX or 0) * 16)
        local py = self.py or self.y or ((self.cellY or 0) * 16)
        drawCollisionBubble(self, px - (camX or 0) + 8, py - (camY or 0))
        return r
      end
      NPC = NPCMod
      NPCMod._kantoLifeSleepWrapped = true
    end
  end

  local function courtesyOnWarp(world, warpDef)
    local g = G()
    if not opt("common_courtesy") then return false end
    if not warpDef then return false end
    -- world may be nil on Gen2 facade until we resolve it
    if not world then world = liveWorld() end
    if not (world and world.map and world.player) then return false end
    local from = {
      map = world.map.id,
      x = world.player.cellX,
      y = world.player.cellY,
    }
    local dest = resolveDestMap(g and g.data, warpDef, world.lastOutdoor or world.backupWarp)
    if not dest and warpDef.destMap and warpDef.destMap ~= "LAST_MAP" then
      dest = warpDef.destMap
    end
    if not frontDoor(world, dest) then return false end
    local h = homes[key(dest)] or {}
    if not isHomeKnown(dest) and not h.knocked and (h.lockedUntil or 0) > now() then
      pushText(g, world, "Please try again\nin 5 minutes.")
      return true -- block warp
    end
    if not isHomeKnown(dest) and not h.knocked then
      -- Mark trespass for eject AFTER the map change finishes (startWarpTo is async).
      local trespass = { home = dest, from = from }
      world.kantoLifeTrespass = trespass
      -- Module-level backup: survives any world field clears during transitions
      pendingTrespass = trespass
      mod.save:set("pendingTrespass", trespass)
    end
    h.knocked = nil
    homes[key(dest)] = h
    saveHomes()
    return false
  end

  local function clearTrespass(world)
    pendingTrespass = nil
    mod.save:set("pendingTrespass", nil)
    if world then
      world.kantoLifeTrespass = nil
    end
  end

  local function tryEjectTrespass(world, toMap)
    if not opt("common_courtesy") then return false end
    local g = G()
    world = world or liveWorld()
    local trespass = (world and world.kantoLifeTrespass) or pendingTrespass
    if not trespass or not trespass.home then return false end
    local mapId = toMap or (world and world.map and world.map.id)
    if not mapId or tostring(mapId) ~= tostring(trespass.home) then return false end
    if world and world.kantoLifeResolving then return false end
    if world then world.kantoLifeResolving = true end

    local function finish()
      clearTrespass(world)
      if world then world.kantoLifeResolving = false end
    end

    local function eject(seconds)
      local h = homes[key(trespass.home)] or {}
      if seconds and seconds > 0 then h.lockedUntil = now() + seconds end
      homes[key(trespass.home)] = h
      saveHomes()
      local from = trespass.from or {}
      local function warpBack()
        if world and type(world.startWarpTo) == "function" and from.map then
          world.doorWarp = true
          world:startWarpTo(from.map, from.x, from.y, "down")
        elseif Overworld and type(Overworld.startWarpTo) == "function" and from.map then
          Overworld.startWarpTo(from.map, from.x, from.y, "down")
        end
        finish()
      end
      local shown = pushText(g, world, "Please come back\nlater, and KNOCK!", warpBack)
      if not shown then
        warpBack()
      end
    end

    local npc = world and world.npcs and world.npcs[1]
    if npc and npc.def and (npc.def.trainerClass or npc.def.trainer)
       and world and type(world.engageTrainer) == "function" then
      pushText(g, world, wake(npc.def), function()
        world:engageTrainer(npc, function()
          if g and g.save and g.save.defeatedTrainers and g.save.defeatedTrainers[npc.id] then
            markHomeKnown(trespass.home)
            finish()
          else
            eject(5)
          end
        end)
      end)
    else
      eject(0)
    end
    return true
  end

  -- Reliable post-warp hook (Gen1 + Gen2 both emit this)
  if mod.events and mod.events.on then
    mod.events:on("player.warped", function(payload)
      payload = payload or {}
      local world = liveWorld()
      local toMap = payload.toMap
      -- Defer one tick so setMap has finished and npcs exist
      local frames = 0
      local function poll()
        frames = frames + 1
        world = liveWorld() or world
        if tryEjectTrespass(world, toMap or (world and world.map and world.map.id)) then
          return
        end
        if frames < 30 and pendingTrespass then
          -- keep checking briefly while transition completes
          if mod.events and mod.events.on then
            -- use update path instead
          end
        end
      end
      -- Store intended map on pending so tick can match
      if pendingTrespass and toMap then
        pendingTrespass.home = pendingTrespass.home or toMap
      end
      pcall(function() tryEjectTrespass(world, toMap) end)
    end)
  end

  -- Progressive dialogue + 5th-interaction events (item / trade / battle)
  local GIFT_ITEMS = {
    "POTION", "SUPER_POTION", "HYPER_POTION", "FULL_HEAL", "REVIVE",
    "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "REPEL", "SUPER_REPEL",
    "X_ATTACK", "X_DEFEND", "X_SPEED", "X_SPECIAL", "GUARD_SPEC",
    "ETHER", "MAX_ETHER", "ANTIDOTE", "AWAKENING", "BURN_HEAL", "ICE_HEAL", "PARLYZ_HEAL",
  }
  local GIFT_TMS = {
    "TM_01", "TM_05", "TM_06", "TM_08", "TM_09", "TM_10", "TM_12", "TM_15",
    "TM_24", "TM_25", "TM_26", "TM_28", "TM_29", "TM_30", "TM_31", "TM_34",
    "TM_38", "TM_39", "TM_44", "TM_45",
  }
  local RARE_SPECIES = {
    "CHANSEY", "SCYTHER", "PINSIR", "LAPRAS", "EEVEE", "SNORLAX", "KANGASKHAN",
    "ELECTABUZZ", "MAGMAR", "PORYGON", "OMANYTE", "KABUTO", "AERODACTYL",
    "DRATINI", "DRAGONAIR", "HITMONLEE", "HITMONCHAN", "LICKITUNG", "MR_MIME",
    "JYNX", "TAUROS", "GYARADOS", "VAPOREON", "JOLTEON", "FLAREON",
  }

  local function talkStateKey(npc)
    local d = npc and (npc.def or {}) or {}
    local mapId = npc.mapId or ""
    local nm = d.name or npc.id or d.kantoLifeDisplayName or "npc"
    return tostring(mapId) .. "::" .. tostring(nm)
  end

  local function loadTalkStates()
    local s = mod.save and mod.save.get and mod.save:get("npcTalkStates")
    return type(s) == "table" and s or {}
  end
  local function saveTalkStates(all)
    if mod.save and mod.save.set then mod.save:set("npcTalkStates", all) end
  end
  local function getTalkState(npc)
    local all = loadTalkStates()
    local key = talkStateKey(npc)
    local st = all[key]
    if type(st) ~= "table" then st = { count = 0 } end
    return st, key, all
  end
  local function putTalkState(key, st, all)
    all = all or loadTalkStates()
    all[key] = st
    saveTalkStates(all)
  end

  local function playerPartyInfo(g)
    local maxLv, n = 5, 0
    local function scan(list)
      if type(list) ~= "table" then return end
      for i = 1, 6 do
        local mon = list[i]
        if type(mon) == "table" and (mon.species or mon.id or mon.name) then
          n = n + 1
          local lv = tonumber(mon.level or mon.lvl or mon.Level)
          if not lv and type(mon.stats) == "table" then lv = tonumber(mon.stats.level) end
          lv = lv or 5
          if lv > maxLv then maxLv = lv end
        end
      end
    end
    local save = g and g.save
    local party = save and save.party
    if type(party) == "table" then
      scan(party.mons or party.pokemon or party)
    end
    if n == 0 and g and g.player then
      scan(g.player.party and (g.player.party.mons or g.player.party))
    end
    if n == 0 and save then
      scan(save.playerParty or save.player_party)
    end
    return maxLv, math.max(n, 0)
  end

  local function enemyLevelFor(playerMax)
    playerMax = tonumber(playerMax) or 5
    if playerMax > 50 then return 40 end
    return math.max(2, playerMax - 10)
  end

  -- Only give item ids that exist in game.data.items (TMs need .machine to teach).
  local function resolveItemId(g, itemId)
    if type(itemId) ~= "string" or itemId == "" then return nil end
    local items = g and g.data and g.data.items
    if type(items) ~= "table" then return itemId end
    if items[itemId] then return itemId end
    local num = itemId:match("(%d+)")
    if num and itemId:upper():find("TM", 1, true) then
      local n = tonumber(num) or 0
      local alts = {
        "TM_" .. string.format("%02d", n),
        "TM" .. string.format("%02d", n),
        "TM_" .. tostring(n),
        "TM" .. tostring(n),
        itemId:upper(),
        itemId:gsub(" ", "_"),
      }
      for _, a in ipairs(alts) do
        if items[a] then return a end
      end
      for id, def in pairs(items) do
        if type(id) == "string" and type(def) == "table" and def.machine then
          local idn = id:match("(%d+)")
          if idn and tonumber(idn) == n and def.machine.kind ~= "HM" then
            return id
          end
        end
      end
    end
    -- case / underscore variants
    local up = itemId:upper():gsub(" ", "_")
    if items[up] then return up end
    return nil
  end

  local function collectUsableTMs(g)
    local out = {}
    local items = g and g.data and g.data.items
    if type(items) ~= "table" then return out end
    for id, def in pairs(items) do
      if type(id) == "string" and type(def) == "table" and def.machine then
        if def.machine.kind ~= "HM" and def.machine.move then
          out[#out + 1] = id
        end
      elseif type(id) == "string" and type(def) == "table" and def.pocket == "TM_HM" then
        if not id:upper():find("HM", 1, true) then
          out[#out + 1] = id
        end
      end
    end
    table.sort(out)
    return out
  end

  local function pickGiftItem(g)
    local rnd = (love and love.math and love.math.random) or math.random
    if rnd() < 0.35 then
      local tms = collectUsableTMs(g)
      if #tms > 0 then return tms[rnd(1, #tms)] end
    end
    -- Prefer ids that exist in this game's item table
    local items = g and g.data and g.data.items
    local candidates = {}
    for _, id in ipairs(GIFT_ITEMS) do
      if type(items) ~= "table" or items[id] then
        candidates[#candidates + 1] = id
      else
        local resolved = resolveItemId(g, id)
        if resolved then candidates[#candidates + 1] = resolved end
      end
    end
    if #candidates == 0 and type(items) == "table" then
      for id, def in pairs(items) do
        if type(id) == "string" and type(def) == "table" and not def.machine then
          local pocket = def.pocket or "ITEM"
          if pocket == "ITEM" or pocket == "BALL" then
            candidates[#candidates + 1] = id
            if #candidates >= 40 then break end
          end
        end
      end
    end
    if #candidates == 0 then return GIFT_ITEMS[rnd(1, #GIFT_ITEMS)] end
    return candidates[rnd(1, #candidates)]
  end

  local function tryGiveItem(g, itemId, count)
    count = count or 1
    local resolved = resolveItemId(g, itemId) or itemId
    local Bag = safeRequire("src.inventory.Bag")
    if Bag and type(Bag.add) == "function" and g and g.save and g.data then
      local ok, res = pcall(Bag.add, g.save, resolved, count, g.data)
      if ok and res then return true, resolved end
      -- Retry once with raw id if different
      if resolved ~= itemId then
        ok, res = pcall(Bag.add, g.save, itemId, count, g.data)
        if ok and res then return true, itemId end
      end
    end
    -- Last resort: write inventory if the item is defined (keeps TM_HM pocket via Bag preferred)
    if g and g.save and g.data and g.data.items and g.data.items[resolved] then
      g.save.inventory = g.save.inventory or {}
      local inv = g.save.inventory
      if not inv[resolved] then
        local order = g.save.bagOrder
        if type(order) ~= "table" then
          g.save.bagOrder = {}
          order = g.save.bagOrder
        end
        order[#order + 1] = resolved
      end
      inv[resolved] = (inv[resolved] or 0) + count
      return true, resolved
    end
    return false, resolved
  end

  local function tryGivePokemon(g, species, level)
    level = math.max(1, math.floor(tonumber(level) or 10))
    local Pokemon = safeRequire("src.pokemon.Pokemon")
    local Party = safeRequire("src.pokemon.Party")
    if not (Pokemon and Pokemon.new and g and g.data and g.save) then return false end
    local ok, mon = pcall(Pokemon.new, g.data, species, level)
    if not ok or not mon then return false end
    if Party and type(Party.add) == "function" then
      local ok2, res = pcall(Party.add, g.save, mon, g.data)
      if ok2 and res ~= false then return true end
    end
    local party = g.save.party
    if type(party) == "table" then
      local list = party.mons or party
      if type(list) == "table" and #list < 6 then
        list[#list + 1] = mon
        return true
      end
    end
    return false
  end

  local function getPartyList(g)
    if not (g and g.save) then return nil end
    local party = g.save.party
    if type(party) ~= "table" then
      party = g.player and g.player.party
    end
    if type(party) ~= "table" then return nil end
    if type(party.mons) == "table" then return party.mons, party end
    return party, party
  end

  local function tryPartyTrade(g, giveSpecies, giveLevel)
    -- Swap: take one random party mon, give rare. Restores on failure.
    local list = getPartyList(g)
    if type(list) ~= "table" or #list < 1 then
      return false, "empty"
    end
    local idx = 1
    if #list >= 2 then
      idx = (love and love.math and love.math.random or math.random)(1, #list)
    end
    local taken = table.remove(list, idx)
    if not taken then return false, "empty" end
    local ok = tryGivePokemon(g, giveSpecies, giveLevel)
    if not ok then
      table.insert(list, idx, taken)
      return false, "full"
    end
    local takenName = tostring(taken.species or taken.id or "POKEMON"):gsub("_", " ")
    return true, takenName
  end


  local function partyList(g)
    if not (g and g.save) then return nil end
    local party = g.save.party
    if type(party) ~= "table" then return nil end
    if type(party.mons) == "table" then return party.mons end
    return party
  end

  local function snapshotPartyHp(g)
    local list = partyList(g)
    if not list then return nil end
    local snap = {}
    for i, mon in ipairs(list) do
      if type(mon) == "table" then
        snap[i] = {
          hp = mon.hp,
          status = mon.status,
          sleep = mon.sleep,
          toxic = mon.toxic,
        }
      end
    end
    return snap
  end

  local function restorePartyHp(g, snap)
    if not snap then return end
    local list = partyList(g)
    if not list then return end
    for i, s in pairs(snap) do
      local mon = list[i]
      if type(mon) == "table" and type(s) == "table" then
        if s.hp ~= nil then mon.hp = s.hp end
        mon.status = s.status
        mon.sleep = s.sleep
        mon.toxic = s.toxic
      end
    end
  end

  local function attachBattleFinish(g, world, battle, display, isPoke, snap)
    if not battle then return end
    local prev = battle.onFinish
    battle.onFinish = function(result)
      if type(prev) == "function" then pcall(prev, result) end
      result = result or "run"
      if result == "lose" and snap then
        restorePartyHp(g, snap)
      end
      local name = display or "TRAINER"
      if result == "win" then
        if isPoke then
          pushText(g, world, name .. ":\n" .. name .. "!\n(It looks tired...)")
        else
          local lines = {
            "You're really strong!",
            "I can't believe I lost...",
            "Wow! What a battle!",
            "I'll train harder!",
          }
          pushText(g, world, name .. ":\n" .. lines[love.math.random(1, #lines)])
        end
      elseif result == "lose" then
        if isPoke then
          pushText(g, world, name .. ":\n" .. name .. "!\n(It looks proud!)")
        else
          local lines = {
            "Ha! I won!",
            "Better luck next time!",
            "My team was stronger!",
            "Come back when you're ready!",
          }
          pushText(g, world, name .. ":\n" .. lines[love.math.random(1, #lines)])
        end
      end
      -- caught / run: no extra taunt
    end
  end

  local function pushBattle(g, battle)
    if not battle then return false end
    if g.stack and type(g.stack.push) == "function" then
      pcall(function() g.stack:push(battle) end)
      return true
    end
    if g.state and type(g.state.push) == "function" then
      pcall(function() g.state:push(battle) end)
      return true
    end
    return false
  end

  local function startWildBattle(g, species, level, ctx)
    level = math.max(2, math.min(100, math.floor(tonumber(level) or 5)))
    if sanitizeSpecies then species = sanitizeSpecies(species) end
    local BattleState = safeRequire("src.battle.BattleState")
    if not (BattleState and BattleState.newWild and g) then return false end
    local snap = snapshotPartyHp(g)
    local ok, battle = pcall(BattleState.newWild, g, species, level)
    if not ok or not battle then
      ok, battle = pcall(BattleState.newWild, g, { species = species, level = level })
    end
    if not ok or not battle then return false end
    pcall(function()
      if battle.enemy and battle.enemy[1] then
        battle.enemy[1].level = level
        battle.enemy[1].species = species
        battle.enemy[1].shiny = false
        battle.enemy[1].isShiny = false
        battle.enemy[1].form = nil
      end
      if battle.wild then
        battle.wild.level = level
        battle.wild.species = species
        battle.wild.shiny = false
        battle.wild.isShiny = false
      end
      if battle.foe then
        battle.foe.level = level
        battle.foe.species = species
        battle.foe.shiny = false
      end
      if type(battle.enemyParty) == "table" then
        for _, mon in ipairs(battle.enemyParty) do
          mon.shiny = false; mon.isShiny = false; mon.form = nil
          if mon.species then mon.species = sanitizeSpecies(mon.species) end
        end
      end
    end)
    ctx = ctx or {}
    attachBattleFinish(g, ctx.world, battle, ctx.display, true, snap)
    return pushBattle(g, battle)
  end

  local function spriteToTrainerBase(sprite)
    local spr = tostring(sprite or ""):upper()
    local map = {
      SPRITE_YOUNGSTER = "OPP_YOUNGSTER", SPRITE_BUG_CATCHER = "OPP_BUG_CATCHER",
      SPRITE_LASS = "OPP_LASS", SPRITE_SUPER_NERD = "OPP_SUPER_NERD",
      SPRITE_HIKER = "OPP_HIKER", SPRITE_BIKER = "OPP_BIKER",
      SPRITE_BURGLAR = "OPP_BURGLAR", SPRITE_ENGINEER = "OPP_ENGINEER",
      SPRITE_FISHER = "OPP_FISHER", SPRITE_SWIMMER = "OPP_SWIMMER",
      SPRITE_CUE_BALL = "OPP_CUE_BALL", SPRITE_GAMBLER = "OPP_GAMBLER",
      SPRITE_BEAUTY = "OPP_BEAUTY", SPRITE_PSYCHIC = "OPP_PSYCHIC",
      SPRITE_ROCKER = "OPP_ROCKER", SPRITE_JUGGLER = "OPP_JUGGLER",
      SPRITE_TAMER = "OPP_TAMER", SPRITE_BIRD_KEEPER = "OPP_BIRD_KEEPER",
      SPRITE_BLACKBELT = "OPP_BLACKBELT", SPRITE_BLACK_BELT = "OPP_BLACKBELT",
      SPRITE_SCIENTIST = "OPP_SCIENTIST", SPRITE_ROCKET = "OPP_ROCKET",
      SPRITE_COOLTRAINER_M = "OPP_COOLTRAINER_M", SPRITE_COOLTRAINER_F = "OPP_COOLTRAINER_F",
      SPRITE_GENTLEMAN = "OPP_GENTLEMAN", SPRITE_CHANNELER = "OPP_CHANNELER",
      SPRITE_POKEFAN_M = "OPP_YOUNGSTER", SPRITE_POKEFAN_F = "OPP_LASS",
      SPRITE_GRAMPS = "OPP_GENTLEMAN", SPRITE_GRANNY = "OPP_BEAUTY",
      SPRITE_BOY = "OPP_YOUNGSTER", SPRITE_GIRL = "OPP_LASS",
      SPRITE_LITTLE_GIRL = "OPP_LASS", SPRITE_FAT_BALD_GUY = "OPP_HIKER",
    }
    if map[spr] then return map[spr] end
    local bare = spr:gsub("^SPRITE_", "")
    if bare ~= "" then return "OPP_" .. bare end
    return "OPP_YOUNGSTER"
  end

  local function startTrainerBattle(g, partySlots, trainerName, npc)
    local BattleState = safeRequire("src.battle.BattleState")
    if not (BattleState and type(BattleState.newTrainer) == "function" and g and g.data) then
      return false
    end
    local snap = snapshotPartyHp(g)
    g.data.trainers = g.data.trainers or {}
    local classId = "OPP_KANTO_LIFE_" .. tostring(love.math.random(100000, 999999))
    local d = npc and (npc.def or npc) or {}
    local baseId = spriteToTrainerBase(d.sprite or d.spriteId)
    local base = g.data.trainers[baseId]
    if not base then
      base = g.data.trainers.OPP_YOUNGSTER or g.data.trainers.OPP_LASS
      baseId = (base and base.id) or baseId or "OPP_YOUNGSTER"
    end
    local pic = base and base.pic or nil
    if (not pic) and base and base.basePic and g.data.trainers[base.basePic] then
      pic = g.data.trainers[base.basePic].pic
    end
    local rec = {
      id = classId,
      name = trainerName or "TRAINER",
      baseMoney = 40,
      parties = { partySlots },
      basePic = baseId,
    }
    if pic then rec.pic = pic end
    g.data.trainers[classId] = rec
    pcall(function()
      if mod.content and mod.content.trainers and mod.content.trainers.register then
        mod.content.trainers:register(classId, rec)
      end
    end)
    local ok, battle = pcall(BattleState.newTrainer, g, classId, 1)
    if not ok or not battle then
      g.data.trainers[classId] = nil
      return false
    end
    pcall(function()
      battle.kind = "trainer"
      if battle.trainer then
        battle.trainer.name = trainerName or battle.trainer.name
        if pic then battle.trainer.pic = pic end
      end
      if pic and BattleState.trainerSprite and not battle.trainerPic then
        battle.trainerPic = BattleState.trainerSprite(g.data, rec, classId, 1)
      end
      -- Force normal (non-shiny / non-special) enemy party
      local function scrub(mon)
        if type(mon) ~= "table" then return end
        mon.shiny = false
        mon.isShiny = false
        mon.special = false
        mon.form = nil
        if mon.species then mon.species = sanitizeSpecies(mon.species) end
      end
      if type(battle.enemyParty) == "table" then
        for _, mon in ipairs(battle.enemyParty) do scrub(mon) end
      end
      if type(battle.enemy) == "table" then
        for _, mon in ipairs(battle.enemy) do scrub(mon) end
      end
    end)
    attachBattleFinish(g, (G and G() and (G().world or G().overworld)), battle, trainerName, false, snap)
    return pushBattle(g, battle)
  end

  
  local function isPlainSpecies(sp)
    if type(sp) ~= "string" or sp == "" then return false end
    sp = sp:upper():gsub(" ", "_")
    -- Block shiny / regional / special form IDs other mods register in data.pokemon
    local banned = {
      "SHINY", "CINDER", "GALAR", "ALOLA", "HISUI", "PALDEA", "MEGA", "PRIMAL",
      "SPECIAL", "FORM", "COSTUME", "ASH_", "SHADOW", "DARK_", "LIGHT_",
      "CRYSTAL_", "SPIRIT_", "GHOST_", "COSMETIC", "ALT_", "VARIANT",
    }
    for _, b in ipairs(banned) do
      if sp:find(b, 1, true) then return false end
    end
    local g = G and G() or game
    local def = g and g.data and g.data.pokemon and g.data.pokemon[sp]
    if type(def) == "table" then
      if def.shiny or def.isShiny or def.special or def.isSpecial then return false end
      if def.form and def.form ~= "BASE" and def.form ~= "NORMAL" and def.form ~= "" then
        return false
      end
      if def.baseSpecies and def.baseSpecies ~= sp then return false end
    end
    return true
  end

  local function sanitizeSpecies(sp)
    if type(sp) ~= "string" then return "PIDGEY" end
    sp = sp:upper():gsub(" ", "_")
    if isPlainSpecies(sp) then return sp end
    -- Strip common prefixes and retry
    local stripped = sp:gsub("^SHINY_", ""):gsub("^CINDER_", ""):gsub("^SPECIAL_", "")
    if isPlainSpecies(stripped) then return stripped end
    return "PIDGEY"
  end
local function pickRandomSpecies(preferRare)
    local rnd = (love and love.math and love.math.random) or math.random
    if preferRare then
      return sanitizeSpecies(RARE_SPECIES[rnd(1, #RARE_SPECIES)])
    end
    local fallback = {
      "PIDGEY", "RATTATA", "SPEAROW", "EKANS", "SANDSHREW", "ZUBAT", "ODDISH",
      "MEOWTH", "PSYDUCK", "MANKEY", "GROWLITHE", "POLIWAG", "ABRA", "MACHOP",
      "BELLSPROUT", "GEODUDE", "PONYTA", "SLOWPOKE", "MAGNEMITE", "DODUO",
      "GRIMER", "SHELLDER", "ONIX", "DROWZEE", "KRABBY", "VOLTORB", "EXEGGCUTE",
      "CUBONE", "KOFFING", "RHYHORN", "HORSEA", "GOLDEEN", "STARYU", "MAGIKARP",
      "NIDORAN_F", "NIDORAN_M", "CLEFAIRY", "VULPIX", "JIGGLYPUFF", "PARAS",
      "VENONAT", "DIGLETT", "PSYDUCK", "GROWLITHE", "POLIWAG", "ABRA", "MACHOP",
      "TENTACOOL", "GEODUDE", "PONYTA", "SLOWPOKE", "FARFETCHD", "DODUO",
      "SEEL", "GRIMER", "SHELLDER", "GASTLY", "ONIX", "DROWZEE", "KRABBY",
      "VOLTORB", "EXEGGCUTE", "CUBONE", "LICKITUNG", "KOFFING", "RHYHORN",
      "CHANSEY", "TANGELA", "KANGASKHAN", "HORSEA", "GOLDEEN", "STARYU",
      "MR_MIME", "SCYTHER", "JYNX", "ELECTABUZZ", "MAGMAR", "PINSIR", "TAUROS",
      "MAGIKARP", "LAPRAS", "DITTO", "EEVEE", "PORYGON", "OMANYTE", "KABUTO",
      "AERODACTYL", "SNORLAX", "DRATINI",
    }
    local pool = {}
    if type(fullDexSpecies) == "function" then
      local all = fullDexSpecies()
      if type(all) == "table" then
        for _, sp in ipairs(all) do
          if isPlainSpecies(sp) then pool[#pool + 1] = sp end
        end
      end
    end
    if #pool == 0 then pool = fallback end
    return sanitizeSpecies(pool[rnd(1, #pool)])
  end

  local function buildEnemyParty(g)
    local maxLv = playerPartyInfo(g)
    local count = love.math.random(1, 6)
    local lv = enemyLevelFor(maxLv)
    local party = {}
    for i = 1, count do
      party[i] = { species = sanitizeSpecies(pickRandomSpecies(false)), level = lv, shiny = false, isShiny = false, form = nil, special = false }
    end
    return party, lv
  end

  local function eventRefLine(st, isPoke)
    if not st or not st.event then return nil end
    if st.event == "item" then
      local item = tostring(st.eventDetail or "a gift"):gsub("_", " ")
      if isPoke then return "Still happy about\nthat " .. item .. "!" end
      return "Hope that " .. item .. "\ncame in handy!"
    elseif st.event == "trade" then
      local mon = tostring(st.eventDetail or "POKEMON"):gsub("_", " ")
      if isPoke then return "Remember our trade?\n" .. mon .. " found a home!" end
      return "That trade for\n" .. mon .. " made my day!"
    elseif st.event == "battle" then
      if isPoke then return "That battle was\nintense!" end
      return "Good battle earlier!\nTrain hard!"
    end
    return nil
  end

  
  local function beginInteractiveTrade(g, world, npc, st, key, all, isPoke, display, rare)
    rare = sanitizeSpecies and sanitizeSpecies(rare) or rare
    local nice = tostring(rare or "POKEMON"):gsub("_", " ")
    local askMsg
    if isPoke then
      askMsg = display .. ":\nTrade for my\n" .. nice .. "?"
    else
      askMsg = display .. ":\nWant to trade for\nmy " .. nice .. "?"
    end

    local function scheduleRetry(msg)
      st.event = nil
      st.pendingTrade = true
      st.eventDetail = rare
      st.retryAt = (tonumber(st.count) or 0) + 5
      putTalkState(key, st, all)
      if msg then pushText(g, world, msg) end
    end

    local function completeWith(picked)
      if not (g and g.save and picked) then
        scheduleRetry(display .. ":\nMaybe next time!")
        return
      end
      local party = g.save.party
      if type(party) ~= "table" then
        scheduleRetry(display .. ":\nMaybe next time!")
        return
      end
      local list = party
      if type(party.mons) == "table" then list = party.mons end
      local slot
      for i, mon in ipairs(list) do
        if mon == picked then slot = i break end
      end
      if not slot then
        scheduleRetry(display .. ":\nMaybe next time!")
        return
      end
      local Pokemon = safeRequire("src.pokemon.Pokemon")
      local Screens = safeRequire("src.ui.Screens")
      if not (Pokemon and Pokemon.new and g.data) then
        scheduleRetry(display .. ":\nTrade failed...")
        return
      end
      local sent = list[slot]
      local level = tonumber(sent.level or sent.lvl) or 10
      local ok, newMon = pcall(Pokemon.new, g.data, rare, level)
      if not ok or not newMon then
        scheduleRetry(display .. ":\nTrade failed...")
        return
      end
      newMon.traded = true
      newMon.ot = tostring(display or "TRAINER"):sub(1, 10)
      newMon.otId = (love and love.math and love.math.random or math.random)(0, 65535)
      newMon.shiny = false
      newMon.isShiny = false
      newMon.form = nil
      table.remove(list, slot)
      table.insert(list, newMon)
      local dex = g.save.pokedex
      if type(dex) == "table" then
        if type(dex.seen) == "table" then dex.seen[rare] = true end
        if type(dex.owned) == "table" then dex.owned[rare] = true end
      end
      st.event, st.eventDetail = "trade", rare
      st.pendingTrade = nil
      st.retryAt = nil
      putTalkState(key, st, all)
      local playerName = (g.save.player and g.save.player.name) or "PLAYER"
      local function afterAnim()
        pushText(g, world, display .. ":\nTrade complete!\nYou got " .. nice .. "!")
      end
      if Screens and type(Screens.push) == "function" then
        pcall(function()
          Screens.push(g, "TradeAnim", {
            sent = sent,
            received = newMon,
            enemyName = tostring(display or "TRAINER"),
            playerOt = playerName,
            playerOtId = sent.otId or (g.save.player and g.save.player.id) or 0,
            enemyOtId = newMon.otId,
            onDone = afterAnim,
          })
        end)
      else
        afterAnim()
      end
    end

    local function openParty()
      local Screens = safeRequire("src.ui.Screens")
      if not (Screens and type(Screens.push) == "function") then
        scheduleRetry(display .. ":\nCan't open the\nparty menu...")
        return
      end
      pcall(function()
        Screens.push(g, "PartyMenu", {
          pickOnly = true,
          onCancel = function()
            scheduleRetry(display .. ":\nOkay, maybe later!")
          end,
          onSwitch = function(mon)
            completeWith(mon)
          end,
        })
      end)
    end

    pushText(g, world, askMsg, nil, {
      choice = function(yes)
        if yes then
          openParty()
        else
          scheduleRetry(display .. ":\nOkay, maybe later!")
        end
      end,
    })
  end

local function runFifthEvent(g, world, npc, st, key, all, isPoke, display, species, forceKind)
    local rnd = (love and love.math and love.math.random) or math.random
        -- Pokemon NPCs: item or battle only. Humans: item, trade, or battle.
    local kinds
    if isPoke then
      kinds = { "item", "battle" }
    else
      kinds = { "item", "trade", "battle" }
    end
    local kind = forceKind
    if kind == "trade" and isPoke then kind = nil end
    if not kind then
      local last = st.lastKind
      local pool = {}
      for _, k in ipairs(kinds) do
        if k ~= last then pool[#pool + 1] = k end
      end
      if #pool == 0 then pool = kinds end
      kind = pool[rnd(1, #pool)]
    end
    st.lastKind = kind

    if kind == "item" then
      local itemId = pickGiftItem(g)
      local given, resolved = tryGiveItem(g, itemId, 1)
      itemId = resolved or itemId
      local nice = tostring(itemId):gsub("_", " ")
      st.event, st.eventDetail = "item", itemId
      st.pendingTrade = nil
      putTalkState(key, st, all)
      if isPoke then
        if playSpeciesCry then playSpeciesCry(species) end
        if given then
          pushText(g, world, display .. ":\n" .. display .. "!\n(Received " .. nice .. "!)")
        else
          pushText(g, world, display .. ":\n" .. display .. "!\n(Wanted to give\n" .. nice .. "...)")
        end
      else
        if given then
          pushText(g, world, display .. ":\nHere, take this\n" .. nice .. "!")
        else
          pushText(g, world, display .. ":\nI'd give you a\n" .. nice .. ", but your\nbag is full!")
        end
      end
      return true
    elseif kind == "trade" then
      local rare = st.eventDetail or pickRandomSpecies(true)
      if type(rare) ~= "string" or rare == "" then rare = pickRandomSpecies(true) end
      if sanitizeSpecies then rare = sanitizeSpecies(rare) end
      if npc.def then npc.def.kantoLifeTradeMon = rare end
      beginInteractiveTrade(g, world, npc, st, key, all, isPoke, display, rare)
      return true
    else
      -- battle
      local maxLv = playerPartyInfo(g)
      local lv = enemyLevelFor(maxLv)
      st.pendingTrade = nil
      if isPoke then
        local foe = species or pickRandomSpecies(false)
        st.event, st.eventDetail = "battle", foe
        putTalkState(key, st, all)
        if playSpeciesCry then playSpeciesCry(foe) end
        -- Start battle immediately (TextBox onDone is unreliable across builds)
        local started = startWildBattle(g, foe, lv, { world = world, display = display })
        if not started then
          pushText(g, world, display .. ":\n" .. display .. "!\n(Couldn't start\nthe battle...)")
        else
          pushText(g, world, display .. ":\n" .. display .. "!\n(Battle! Lv" .. tostring(lv) .. "\nYou can catch it!)")
        end
        return true
      else
        local party = buildEnemyParty(g)
        st.event, st.eventDetail = "battle", "trainer"
        putTalkState(key, st, all)
        local started = startTrainerBattle(g, party, display, npc)
        if not started then
          pushText(g, world, display .. ":\nI wanted to battle,\nbut something went wrong!")
        else
          pushText(g, world, display .. ":\nHow about a battle?\nMy team is ready!")
        end
        return true
      end
    end
  end

  local function progressiveAmbientTalk(g, world, npc, isPoke)
    local d = npc.def or {}
    local st, key, all = getTalkState(npc)
    st.count = (tonumber(st.count) or 0) + 1
    putTalkState(key, st, all)

    local display, species
    if isPoke then
      species = npc.kantoLifeSpecies or d.kantoLifeSpecies
      if type(species) ~= "string" or species == "" then
        species = type(d.kantoLifeDisplayName) == "string" and d.kantoLifeDisplayName:upper() or "POKEMON"
      end
      display = speciesDisplayName(species)
    else
      display = d.kantoLifeDisplayName or stableNameFor(npc) or "TRAINER"
    end

    if (not isPoke) and st.pendingTrade and not st.event and st.retryAt and st.count >= st.retryAt then
      return runFifthEvent(g, world, npc, st, key, all, false, display, nil, "trade")
    end
    if st.count == 5 and not st.event then
      return runFifthEvent(g, world, npc, st, key, all, isPoke, display, species, nil)
    end

    if isPoke then
      if playSpeciesCry then playSpeciesCry(species) end
      local ref = eventRefLine(st, true)
      if ref and love.math.random() < 0.55 then
        pushText(g, world, display .. ":\n" .. ref)
      else
        pushText(g, world, display .. ":\n" .. display .. "!")
      end
      return true
    end

    local name = tostring(d.name or "")
    local route = name:match("^KANTO_ROUTE") or name:match("^JOHTO_")
    -- Unique dialogue: combinatorial generator with per-NPC history.
    -- Falls back to the static pool if the generator is unavailable.
    local text
    if DialogueGen and type(DialogueGen.generate) == "function" then
      local genOk, genLine, genHistory = pcall(DialogueGen.generate, {
        npcName = display,
        gender = d.kantoLifeGender,
        agenda = npc._kantoLifeAgenda,
        gen = 1,
        dex = POKE_SPECIES,
        isPoke = false,
        recentLines = st.recentLines,
      })
      if genOk and type(genLine) == "string" and genLine ~= "" then
        text = genLine
        st.recentLines = genHistory
      end
    end
    if not text then
      local pool = route and routeLines or lines
      text = pool[love.math.random(1, #pool)]
    end
    local ref = eventRefLine(st, false)
    if ref and st.count > 5 and love.math.random() < 0.5 then
      text = ref
    end
    pushText(g, world, display .. ":\n" .. text)
    return true
  end

  local function courtesyTalk(world, npc)
    local g = G()
    local d = npc and npc.def
    if not d then return false end
    if isPokemonLike(npc) and not isPokeAmbient(npc) then return false end
    local isNight = night(world)
    local asleep = opt("sleeping_npcs") and shouldSleepNow(npc, isNight)

    if isPokeAmbient(npc) and not asleep then
      return progressiveAmbientTalk(g, world, npc, true)
    end
    if isAmbientNpc(npc) and not asleep and not isPokeAmbient(npc) then
      return progressiveAmbientTalk(g, world, npc, false)
    end
    if not asleep then return false end
    if isSpecialCharacter(npc) then return false end
    if d.trainerClass or d.trainer then
      pushText(g, world, wake(d))
      return true
    end
    npc.frozen = true
    pushText(g, world, string.format("%s is fast\nasleep.", tostring(d.name or "This person"):gsub("_", " ")))
    return true
  end

  -- Simplify nightlifeTick: step counting + deferred eject + sleep
  local lastStepCell = { map = nil, x = nil, y = nil }
    local function waterPokeTick(world)
    if not world or not world.map then return end
    local map = world.map
    for _, npc in ipairs(world.npcs or {}) do
      local d = npc.def or {}
      if not (d.kantoLifeWaterBound or npc.kantoLifeWaterBound) then goto cont end
      if not isPokeAmbient(npc) then goto cont end
      local cx = npc.cellX or npc.x
      local cy = npc.cellY or npc.y
      if type(cx) ~= "number" or type(cy) ~= "number" then goto cont end
      cx, cy = math.floor(cx), math.floor(cy)
      local function place(tx, ty)
        npc.cellX, npc.cellY = tx, ty
        if npc.x then npc.x = tx end
        if npc.y then npc.y = ty end
        if npc.px then npc.px = tx * 16 end
        if npc.py then npc.py = ty * 16 end
        if npc.def then npc.def.x, npc.def.y = tx, ty end
      end
      -- Pulled onto land somehow: snap back to nearest water
      if not isWaterCell(map, cx, cy) then
        local found = false
        for r = 1, 8 do
          for dx = -r, r do
            for dy = -r, r do
              local tx, ty = cx + dx, cy + dy
              if isWaterSpawnable(map, tx, ty) and not occupied(world, tx, ty) then
                place(tx, ty)
                found = true
                break
              end
            end
            if found then break end
          end
          if found then break end
        end
        goto cont
      end
      -- Occasional hop to an adjacent water tile only
      if love.math.random() < 0.03 then
        local dirs = { {0, 1}, {0, -1}, {1, 0}, {-1, 0} }
        local d0 = dirs[love.math.random(4)]
        local tx, ty = cx + d0[1], cy + d0[2]
        if isWaterSpawnable(map, tx, ty) and not occupied(world, tx, ty) then
          place(tx, ty)
        end
      end
      ::cont::
    end
  end

local function nightlifeTick(world, dt)
    if not world then return end
    local g = G()
    local p = world.player
    if p and p.cellX ~= nil and p.cellY ~= nil and world.map then
      local mapId = world.map.id
      if lastStepCell.map ~= mapId then
        lastStepCell.map, lastStepCell.x, lastStepCell.y = mapId, p.cellX, p.cellY
      elseif lastStepCell.x ~= p.cellX or lastStepCell.y ~= p.cellY then
        lastStepCell.x, lastStepCell.y = p.cellX, p.cellY
        onPlayerStep()
      end
    end

    -- Eject if we are inside a trespassed home (covers delayed map loads)
    tryEjectTrespass(world, world.map and world.map.id)

    if world.kantoLifeWelcome and world.map and world.map.id == world.kantoLifeWelcome then
      local welcomed = world.kantoLifeWelcome
      world.kantoLifeWelcome = nil
      markHomeKnown(welcomed)
      pushText(g, world, "Welcome! Thank you\nfor knocking.")
    end

    if opt("sleeping_npcs") then
      local isNight = night(world)
      for _, npc in ipairs(world.npcs or {}) do
        if isPlayerActor(npc) then
          -- Player sprites are replaceable by other mods; actor identity is
          -- authoritative, so the player is never a Kanto Life sleeper.
          if npc.nightlifeSleeping then wakeNpc(npc) end
        elseif isSpecialCharacter(npc) or isPokemonFollower(npc) then
          if npc.nightlifeSleeping then wakeNpc(npc) end
        elseif (npc.wild or npc.isWild or npc.wildPokemon) and not isPokeAmbient(npc) then
          if npc.nightlifeSleeping then wakeNpc(npc) end
        elseif shouldSleepNow(npc, isNight) then
          putToSleep(npc)
        elseif npc.nightlifeSleeping then
          wakeNpc(npc)
        end
      end
    end
  end

  if not Overworld then
    mod.log:warn("Kanto Life: no Overworld module — Door Knocking inactive")
  elseif gen1 then
    if type(Overworld.interact) == "function" then
      local base = Overworld.interact
      Overworld.interact = function(self)
        if courtesyInteract(self) then return end
        return base(self)
      end
    end
    if type(Overworld.takeWarp) == "function" then
      local base = Overworld.takeWarp
      Overworld.takeWarp = function(self, warpDef)
        if courtesyOnWarp(self, warpDef) then return end
        return base(self, warpDef)
      end
    end
    if type(Overworld.update) == "function" then
      local base = Overworld.update
      Overworld.update = function(self, dt)
        if kantoRoutines and type(kantoRoutines.preUpdate) == "function" then
          pcall(kantoRoutines.preUpdate, self)
        end
        base(self, dt)
        pcall(nightlifeTick, self, dt)
        pcall(scheduleTick, self, dt)
        pcall(waterPokeTick, self)
      end
    end
    if type(Overworld.talkTo) == "function" then
      local base = Overworld.talkTo
      Overworld.talkTo = function(self, npc)
        if npc then
          rememberTalker(npc)
          if self then self.talkNpc = npc end
        end
        if courtesyTalk(self, npc) then return end
        return base(self, npc)
      end
    end
  else
    local baseInteract = Overworld.interact
    Overworld.interact = function(world)
      if courtesyInteract(world) then return true end
      if type(baseInteract) == "function" then return baseInteract(world) end
      if world and type(world.interactBody) == "function" then return world:interactBody() end
    end

    local baseUpdate = Overworld.update
    Overworld.update = function(world, dt)
      if type(baseUpdate) == "function" then pcall(baseUpdate, world, dt) end
      pcall(nightlifeTick, world, dt)
      pcall(scheduleTick, world, dt)
    end

    local baseTalk = Overworld.talkTo
    Overworld.talkTo = function(world, npc)
      if npc then
        rememberTalker(npc)
        if world then world.talkNpc = npc end
      end
      if courtesyTalk(world, npc) then return true end
      if type(baseTalk) == "function" then return baseTalk(world, npc) end
      return false
    end

    local baseWarp = Overworld.takeWarp
    Overworld.takeWarp = function(warpDef)
      local world = liveWorld()
      if courtesyOnWarp(world, warpDef) then return false end
      if type(baseWarp) == "function" then return baseWarp(warpDef) end
    end
  end

  -- =====================================================================
  -- FINAL sleep install (AFTER nightlifeTick + Overworld wraps exist)
  -- Enforced every NPC:update tick using real gen1recomp NPC.lua rules:
  --   if frozen or not wanders → no new steps; clear moving to stop current step
  -- Visual: gray ±90° baked sprite, or geometric rotate fallback + Zzz
  -- =====================================================================
  do
    local sleepImgCache = {}

    local function ensureAssetHook()
      local ok, Assets = pcall(require, "src.render.Assets")
      if not (ok and Assets and type(Assets.image) == "function") then return end
      if Assets._kantoSleepHook then return end
      local base = Assets.image
      Assets.image = function(path, ...)
        if path and sleepImgCache[path] then return sleepImgCache[path] end
        return base(path, ...)
      end
      Assets._kantoSleepHook = true
    end

    local function bakeGrayLie(npc)
      if npc and isViridianSleepyOldMan(npc) then
        return false
      end
      if not npc or not npc.sprite or npc._kantoSleepSpriteActive then
        return npc and npc._kantoSleepSpriteActive
      end
      local sprite = npc.sprite
      if npc._kantoOrigSprite == nil then npc._kantoOrigSprite = sprite end
      local sign = (npc.kantoLifeSleepSide or 1) >= 0 and 1 or -1

      -- Voxel sleep art is generated ONCE from the real Gen-1 16x16 frame.
      -- Do not render the sprite through a canvas: that loses the renderer's
      -- OBJ color-0 transparency and was the source of the old blocky/"blob"
      -- result.  The imported sheet is four-shade grayscale; shade 0 is white
      -- and is the transparent OBJ color, exactly as SpriteRenderer does it.
      local ok, variants = pcall(function()
        local Assets = require("src.render.Assets")
        local src = nil
        local srcIsHgss = sprite.def and type(sprite.def.hgssNativeImage) == "string"
          and sprite.def.hgssNativeImage ~= ""
        npc._kantoSleepIsHgss = srcIsHgss and true or false
        -- HGSS_SPRITES keeps the authored sheet in hgssNativeImage and uses a
        -- small proxy for generic voxel UV discovery. Sleep art must sample the
        -- authored sheet or the sleeping NPC can become tiny/garbled.
        if srcIsHgss and love.image and love.image.newImageData then
          pcall(function() src = love.image.newImageData(sprite.def.hgssNativeImage) end)
        end
        if not src and type(Assets.imageData) == "function" and sprite.def and sprite.def.image then
          pcall(function() src = Assets.imageData(sprite.def.image) end)
        end
        if not src then
          local img = nil
          pcall(function()
            if type(sprite.resolveImage) == "function" then img = sprite:resolveImage() end
          end)
          if not img then img = sprite.image end
          if img and type(img.getData) == "function" then
            pcall(function() src = img:getData() end)
          end
        end
        if not src then return nil end
        local iw, ih = src:getDimensions()
        local sourceFW, sourceFH, sourceY = 16, 16, 0
        if srcIsHgss then
          sourceFW = tonumber(sprite.def.hgssFrameWidth or sprite.def.frameWidth) or 32
          sourceFH = tonumber(sprite.def.hgssFrameHeight or sprite.def.frameHeight) or sourceFW
          sourceFW = math.min(sourceFW, iw)
          sourceFH = math.min(sourceFH, ih)
        else
          sourceFW = math.min(sourceFW, iw)
          sourceFH = math.min(sourceFH, ih)
        end
        if sourceFW < 1 or sourceFH < 1 or sourceY + sourceFH > ih then return nil end

        local out = {}
        -- IMPORTANT: keep the exact proven 0.8.77 16x32 path for ordinary
        -- Gen-1 sprites. Only HGSS gets the larger native 32px voxel card.
        local bodyW = srcIsHgss and 32 or 16
        local bodyH = srcIsHgss and 32 or 16
        local zBand = 16
        local cardW = bodyW
        local cardH = bodyH + zBand
        for fi = 1, 3 do
          -- Non-HGSS remains byte-for-byte in geometry with 0.8.77.
          -- HGSS gets a native 32x32 actor footprint plus a 16px Z band.
          local d = love.image.newImageData(cardW, cardH)

          for y = 0, bodyH - 1 do
            for x = 0, bodyW - 1 do
              local sx = math.min(sourceFW - 1, math.floor((x + 0.5) * sourceFW / bodyW))
              local sy = math.min(sourceFH - 1, math.floor((y + 0.5) * sourceFH / bodyH))
              local r, g, b, a = src:getPixel(sx, sourceY + sy)
              if a > 0.01 and (r + g + b) < 2.97 then
                local lum = 0.299 * r + 0.587 * g + 0.114 * b
                local rx, ry
                if sign > 0 then rx, ry = bodyW - 1 - y, x
                else rx, ry = y, bodyH - 1 - x end
                d:setPixel(rx, ry + zBand, lum, lum, lum, a)
              end
            end
          end

          -- ONE Z. The animation is this same glyph at three successive
          -- positions; there are never multiple Zs in a frame.
          local pat = {
            "11111",
            "00001",
            "00110",
            "01100",
            "11000",
            "10000",
            "11111",
          }
          local zx = srcIsHgss and ({ 13, 14, 15 })[fi] or ({ 4, 5, 6 })[fi]
          local zy = ({ 5, 3, 1 })[fi]
          for yy = 1, #pat do
            for xx = 1, 5 do
              if pat[yy]:sub(xx, xx) == "1" then
                local px, py = zx + xx - 1, zy + yy - 1
                if px >= 0 and px < cardW and py >= 0 and py < zBand then
                  d:setPixel(px, py, 0.68, 0.68, 0.68, 1)
                end
              end
            end
          end

          local im = love.graphics.newImage(d)
          im:setFilter("nearest", "nearest")
          out[fi] = { image = im, data = d }
        end
        return out
      end)
      if not (ok and variants and variants[1] and variants[2] and variants[3]) then
        return false
      end

      -- Each animation state is a separate cached image. The sprite itself
      -- remains a normal single-frame SpriteRenderer from the engine's point
      -- of view; voxel simply receives the currently selected texture.
      local baseRel = string.format("kanto_life_exp_sleep/%s",
        tostring(npc.id or "x"):gsub("[^%w%-_]", "_"))
      local rels = {}
      for i = 1, 3 do
        local rel = baseRel .. "_" .. tostring(i) .. ".png"
        rels[i] = rel
        sleepImgCache[rel] = variants[i].image
      end
      ensureAssetHook()

      local okR, SR = pcall(require, "src.render.SpriteRenderer")
      if not (okR and SR and SR.new) then return false end
      local sleepIsHgss = npc._kantoSleepIsHgss == true
      local proxyW = sleepIsHgss and 32 or 16
      local proxyH = sleepIsHgss and 48 or 32
      local def = {
        id = "KANTO_SLEEP_" .. tostring(npc.id or baseRel),
        image = rels[1],
        frames = 1,
        walker = false,
        trueColor = true,
        frameWidth = proxyW,
        frameHeight = proxyH,
        anchorX = proxyW / 2,
        anchorY = proxyH,
      }
      if sleepIsHgss then
        -- Present the sleep card through HGSS_SPRITES' existing native-sheet
        -- contract. This is the important compatibility point: HGSS_SPRITES
        -- applies its live SPRITE SIZE value to Battle Art's billboard mesh.
        -- Kanto Life therefore does NOT hard-code 0.8/1.0 or duplicate the
        -- HGSS scaling code; changing HGSS's scale automatically changes the
        -- sleeping body's voxel footprint by the same amount.
        -- The generated card is 32x48: the lower 32px are the sleeping body
        -- and the upper 16px are the single animated Z band.
        def.kantoLifeSleepProxy = true
        def.hgssNativeImage = rels[1]
        def.hgssFrameWidth = 32
        def.hgssFrameHeight = 48
        def.hgssDrawWidth = 32
        def.hgssDrawHeight = 48
        def.hgssBaseDrawWidth = 32
        def.hgssBaseDrawHeight = 48
        def.hgssVoxelWidth = 32
        def.hgssVoxelHeight = 48
        def.hgssBaseVoxelWidth = 32
        def.hgssBaseVoxelHeight = 48
        def.hgssPreserveAspect = false
        def.hgssVoxelEntityYOffset = 0
        def.hgssPostPresent = true
      end
      local okN, ns = pcall(SR.new, def, tostring(npc.id or "s"))
      if not (okN and ns) then return false end
      ns.image = variants[1].image
      ns.def = def
      ns.frameCount = 1
      local qok, q = pcall(love.graphics.newQuad, 0, 0, proxyW, proxyH, proxyW, proxyH)
      if qok then ns.frames = { [0] = q } end
      ns._kantoSleepVoxelImages = variants
      ns._kantoSleepVoxelIndex = 1
      ns.resolveImage = function(self, ...)
        local list = self._kantoSleepVoxelImages
        local idx = self._kantoSleepVoxelIndex or 1
        return (list and list[idx] and list[idx].image) or self.image
      end

      if sleepIsHgss then
        npc._kantoSleepProxySprite = ns
        npc._kantoSleepSpriteActive = true
        npc._kantoSleepVoxelFrames = variants
        npc._kantoSleepVoxelPaths = rels
        npc._kantoSleepVoxelFrame = 1
        return true
      end

      -- Exact 0.8.77 behavior when HGSS_SPRITES is absent.
      npc.sprite = ns
      npc._kantoSleepSpriteActive = true
      npc._kantoSleepVoxelFrames = variants
      npc._kantoSleepVoxelPaths = rels
      npc._kantoSleepVoxelFrame = 1
      return true
    end

    local function hardFreeze(npc)
      npc.frozen = true
      npc.moving = false
      npc.marching = false
      npc.progress = 0
      npc.hopStep = nil
      if type(npc.cellX) == "number" and type(npc.cellY) == "number" then
        npc.px, npc.py = npc.cellX * 16, npc.cellY * 16
      end
      if npc._kantoOrigWanders == nil then npc._kantoOrigWanders = npc.wanders end
      if npc._kantoOrigSteps == nil then npc._kantoOrigSteps = npc.steps end
      npc.wanders = false
      npc.steps = false
      npc.timer = 99999
    end

    local NPCMod = NPC or safeRequire("src.world.NPC")

    ----------------------------------------------------------------
    -- Public voxel renderer bridge for Porygonal-compatible sleep.
    --
    -- Battle Art exposes CharacterRenderers as a documented public API.
    -- Its drawEntity callback runs BEFORE Porygonal's Battle Art adapter.
    -- For a sleeping civilian we therefore claim the actor and render the
    -- already-generated sleep body as actual voxel geometry lying on the
    -- ground.  This avoids Porygonal's standing-model/2D fallback without
    -- modifying either Porygonal or Battle Art.
    --
    -- The authored Viridian sleepy Old Man is deliberately excluded: its
    -- original SPRITE_GAMBLER_ASLEEP definition is left for Porygonal's own
    -- authored 3D asleep asset.
    ----------------------------------------------------------------
    local function installPublicVoxelSleepRenderer()
      if NPCMod and NPCMod._kantoLifePublicSleepRenderer then return end

      local okFind, battle = pcall(function()
        return mod.find("BATTLE_ART_VOXEL_FORK")
      end)
      local api = okFind and battle and battle.exports
        and battle.exports.characterRenderers or nil
      if not api or type(api.register) ~= "function" then return end

      local lib = battle.exports.lib
      if not lib or type(lib.require) ~= "function" then return end

      local okV, Voxel3D = pcall(lib.require, "Voxel3D")
      local okM, Mat4 = pcall(lib.require, "Mat4")
      local okB, SpriteBillboards = pcall(lib.require, "SpriteBillboards")
      if not (okV and okM and okB
              and Voxel3D and type(Voxel3D.draw) == "function"
              and type(Voxel3D.newMesh) == "function"
              and Mat4 and type(Mat4.mul) == "function"
              and type(Mat4.translate) == "function"
              and type(Mat4.rotateX) == "function"
              and type(Mat4.rotateY) == "function"
              and SpriteBillboards and type(SpriteBillboards.mesh) == "function") then
        return
      end

      local Assets = nil
      local okA, a = pcall(require, "src.render.Assets")
      if okA then Assets = a end
      if not Assets then return end

      local imageCache = {}
      local meshCache = {}

      local function facingYaw(facing)
        if facing == "left" then return math.rad(-90) end
        if facing == "up" then return math.rad(180) end
        if facing == "right" then return math.rad(90) end
        return 0
      end

      local function cacheImage(path, data)
        if imageCache[path] then return imageCache[path] end
        local ok, image = pcall(love.graphics.newImage, data)
        if not ok or not image then return nil end
        pcall(image.setFilter, image, "nearest", "nearest")
        imageCache[path] = image
        return image
      end

      local function bodyAndZ(npc, frameIndex)
        local frames = npc and npc._kantoSleepVoxelFrames
        local f = frames and frames[frameIndex]
        local data = f and f.data
        if not data or not data.getDimensions or not data.getPixel then return nil end

        local w, h = data:getDimensions()
        local bodyH = h - 16
        local bodyW = w
        if bodyW < 1 or bodyH < 1 then return nil end

        -- Sleep art is derived from the sprite frame, not the individual NPC.
        -- Share the GPU images/meshes between actors that use the same sprite;
        -- the old per-NPC cache multiplied voxel work in crowded maps and was
        -- the main avoidable cost in voxel sleep scenes.
        local source = npc._kantoOrigSprite or npc.sprite
        local sourceDef = source and source.def or {}
        local sourceKey = tostring(sourceDef.id or sourceDef.image or source.image or sourceDef.sprite or "npc")
        local key = sourceKey .. "#" .. tostring(frameIndex)
        if imageCache[key .. ":body"] and imageCache[key .. ":z"] then
          return imageCache[key .. ":body"], imageCache[key .. ":z"], bodyW, bodyH
        end

        local bodyData = love.image.newImageData(bodyW, bodyH)
        for y = 0, bodyH - 1 do
          for x = 0, bodyW - 1 do
            local r, g, b, a = data:getPixel(x, y + 16)
            bodyData:setPixel(x, y, r, g, b, a)
          end
        end

        local zData = love.image.newImageData(5, 7)
        for y = 0, 6 do
          for x = 0, 4 do
            zData:setPixel(x, y, 0, 0, 0, 0)
          end
        end
        local pat = {
          "11111", "00001", "00110", "01100", "11000", "10000", "11111"
        }
        for y = 1, 7 do
          for x = 1, 5 do
            if pat[y]:sub(x, x) == "1" then
              zData:setPixel(x - 1, y - 1, 0.68, 0.68, 0.68, 1)
            end
          end
        end

        local body = cacheImage(key .. ":body", bodyData)
        local z = cacheImage(key .. ":z", zData)
        if not body or not z then return nil end
        return body, z, bodyW, bodyH
      end

      local function quadMesh(imagePath, image, w, h, key)
        if meshCache[key] then return meshCache[key] end
        local old = imageCache[imagePath]
        imageCache[imagePath] = image
        local def = {
          id = "KANTO_LIFE_SLEEP_3D_" .. tostring(key),
          image = imagePath,
          frames = 1,
          frameWidth = w,
          frameHeight = h,
          trueColor = true,
          walker = false,
        }
        local mesh = SpriteBillboards.mesh(def, 0, h / 2)
        imageCache[imagePath] = old or image
        if mesh then meshCache[key] = mesh end
        return mesh
      end

      local sleepProp3DCache = {}
      local function sleepPropImage(style)
        style = math.floor(tonumber(style) or 0)
        if style <= 0 then return nil end
        local names = {[1]="sleep_tent.png",[2]="sleeping_bag.png",[3]="sleep_bed.png"}
        local rel = names[style]; if not rel then return nil end
        if sleepProp3DCache[rel] then return sleepProp3DCache[rel] end
        local path = rel
        if mod.assets and type(mod.assets.path)=="function" then path=mod.assets:path("assets/"..rel) end
        local ok,img=pcall(love.graphics.newImage,path)
        if ok and img then img:setFilter("nearest","nearest"); sleepProp3DCache[rel]=img; return img end
        return nil
      end

      local propMeshCache = {}
      local function sleepPropMesh(style)
        style = math.floor(tonumber(style) or 0)
        if style <= 0 then return nil end
        if propMeshCache[style] then return propMeshCache[style] end
        local prop = sleepPropImage(style)
        if not prop then return nil end
        local pw, ph = prop:getDimensions()
        local path = "kanto_life_exp_sleep_prop_" .. tostring(style) .. ".png"
        sleepImgCache[path] = prop
        ensureAssetHook()
        local def = { id="KANTO_LIFE_SLEEP_PROP_"..tostring(style), image=path, frames=1, frameWidth=pw, frameHeight=ph, trueColor=true, walker=false }
        local mesh = SpriteBillboards.mesh(def, pw/2, ph/2)
        if mesh then propMeshCache[style] = {mesh=mesh, image=prop, w=pw, h=ph} end
        return propMeshCache[style]
      end

      local function drawSleep3D(ctx)
        local npc = ctx and ctx.actor
        if not npc or not npc.nightlifeSleeping then return false end
        if isPokemonFollower(npc) or isPokemonLike(npc) then return false end
        if isViridianSleepyOldMan(npc) then return false end
        if not npc._kantoSleepVoxelFrames then
          pcall(bakeGrayLie, npc)
        end
        -- Battle Art can reuse a pose without calling NPC:update every render
        -- pass. Advance the Z frame from the same monotonic clock here as a
        -- render-side safeguard; this keeps voxel Zs animated instead of
        -- freezing on the first cached pose.
        local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
        local idx = (math.floor(now * 2.2) % 3) + 1
        if npc._kantoSleepVoxelFrame ~= idx then
          npc._kantoSleepVoxelFrame = idx
          local frames = npc._kantoSleepVoxelFrames
          local sleepSprite = npc._kantoSleepIsHgss and npc._kantoSleepProxySprite or npc.sprite
          if frames and frames[idx] and sleepSprite then
            sleepSprite.image = frames[idx].image
            sleepSprite._kantoSleepVoxelIndex = idx
          end
        end
        local body, z, w, h = bodyAndZ(npc, idx)
        if not body then return false end

        local source = npc._kantoOrigSprite or npc.sprite
        local sourceDef = source and source.def or {}
        local sourceKey = tostring(sourceDef.id or sourceDef.image or source.image or sourceDef.sprite or "npc"):gsub("[^%w%-_]", "_")
        local bodyPath = "kanto_life_exp_sleep_3d/" .. sourceKey .. "_body_" .. idx .. ".png"
        local zPath = "kanto_life_exp_sleep_3d/" .. sourceKey .. "_z_" .. idx .. ".png"
        -- The normal sleep asset hook already exists for the generated cards.
        -- Publish these two derived images through that same hook so
        -- SpriteBillboards.mesh can resolve them without touching Assets.
        sleepImgCache[bodyPath] = body
        sleepImgCache[zPath] = z
        ensureAssetHook()
        local bodyMesh = quadMesh(bodyPath, body, w, h, bodyPath)
        local zMesh = quadMesh(zPath, z, 5, 7, zPath)
        if not bodyMesh or not zMesh then return false end

        local px = tonumber(ctx.px) or tonumber(npc.px) or 0
        local py = tonumber(ctx.py) or tonumber(npc.py) or 0
        local gh = tonumber(ctx.groundHeight) or 0
        local sign = (tonumber(npc.kantoLifeSleepSide) or 1) >= 0 and 1 or -1
        local propStyle = math.floor(tonumber(opt("sleep_style")) or 0)
        -- Tent style mirrors the 2D path: the NPC stands upright inside the
        -- upright tent instead of lying flat. The baked voxel frames carry a
        -- 90-degree lying pixel rotation, so undo it in the card plane
        -- (rotateZ) rather than laying the card flat (rotateX), and lift the
        -- card so the sleeper's feet rest on the ground. Other styles keep the
        -- proven lying transform untouched.
        local isTent = (propStyle == 1) and type(Mat4.rotateZ) == "function"
        local yaw = facingYaw(npc.kantoLifeSleepFacing or npc.facing)
        if not isTent then yaw = yaw + sign * math.pi / 2 end

        -- SpriteBillboards' local card is centred by using anchorX/anchorY;
        -- rotate that plane onto the ground and keep its centre over the NPC.
        -- (Tent: keep the card vertical; the in-plane rotateZ below cancels
        -- the baked lying rotation so the sleeper stands upright.)
        local bodyModel
        if isTent then
          bodyModel = Mat4.mul(
            Mat4.translate(px, gh + 8.25, py + 8),
            Mat4.mul(Mat4.rotateY(yaw), Mat4.rotateZ(sign * math.pi / 2))
          )
        else
          bodyModel = Mat4.mul(
            Mat4.translate(px, gh + 0.25, py + 8),
            Mat4.mul(Mat4.rotateY(yaw), Mat4.rotateX(sign * math.pi / 2))
          )
        end
        Voxel3D.draw(bodyMesh, body, bodyModel, 0, bodyModel)

        local pm = sleepPropMesh(propStyle)
        if pm and pm.mesh then
          -- Tent style: prop stays upright like the standing NPC body, with
          -- the tent's base on the ground (24px tall card, centred anchor).
          local propRotX = isTent and 0 or (sign * math.pi / 2)
          local propLift = isTent and 12.05 or 0.05
          local propModel = Mat4.mul(
            Mat4.translate(px, gh + propLift, py + 8),
            Mat4.mul(Mat4.rotateY(yaw), Mat4.rotateX(propRotX))
          )
          Voxel3D.draw(pm.mesh, pm.image, propModel, 0, propModel)
        end

        -- One Z, upright and camera-facing like the native voxel billboard.
        local host = ctx.host or {}
        local fp = host.FirstPerson
        local pitch = -math.pi / 2
        local zyaw = 0
        if fp and type(fp.cardBlend) == "function" then
          local okBlend, blend = pcall(fp.cardBlend)
          if okBlend and tonumber(blend) and blend > 0.5
              and type(fp.cardYaw) == "function" then
            local okYaw, v = pcall(fp.cardYaw, px + 8, py + 8)
            if okYaw and tonumber(v) then zyaw = v end
            pitch = 0
          else
            local okState, VoxelState = pcall(lib.require, "VoxelState")
            if okState and VoxelState and tonumber(VoxelState.angle) then
              pitch = VoxelState.angle - math.pi / 2
            end
          end
        end
        local headOffsetX = sign * -5
        local zx, zz = px + headOffsetX, py + 8
        if isTent then
          -- Above the standing sleeper's head (card top-centre, yawed).
          zx = px + 8 * math.cos(yaw)
          zz = py + 8 - 8 * math.sin(yaw)
        end
        local zModel = Mat4.mul(
          Mat4.translate(zx, gh + 17, zz),
          Mat4.rotateY(zyaw)
        )
        if pitch ~= 0 then zModel = Mat4.mul(zModel, Mat4.rotateX(pitch)) end
        Voxel3D.draw(zMesh, z, zModel, 0, zModel)
        return true
      end

      local handle = api.register({
        apiVersion = 1,
        id = "KANTO_LIFE_SLEEP_3D",
        name = "Kanto Life Sleeping NPCs",
        priority = 10000,
        drawEntity = drawSleep3D,
      })
      if handle and NPCMod then
        NPCMod._kantoLifePublicSleepRenderer = handle
      end
    end

    installPublicVoxelSleepRenderer()

    -- IMPORTANT: voxel/Battle Art consumes NPC:pose(), not NPC:draw().
    -- Keep the working 2D draw path untouched; only make pose expose the
    -- already-baked sleeping sprite to alternate render pipelines.
    if NPCMod and type(NPCMod.pose) == "function"
       and not NPCMod._kantoLifeSleepPoseWrapped then
      local basePose = NPCMod.pose
      NPCMod.pose = function(self, ...)
        -- Battle Art/Porygonal may finish loading after Kanto Life. Retry the
        -- public renderer registration lazily instead of requiring a specific
        -- mod load order.
        if not NPCMod._kantoLifePublicSleepRenderer then
          pcall(installPublicVoxelSleepRenderer)
        end
        if self and self.nightlifeSleeping then
          if isViridianSleepyOldMan(self) then
            return basePose(self, ...)
          end
          if not self._kantoSleepSpriteActive then
            pcall(bakeGrayLie, self)
          end
          local frames = self._kantoSleepVoxelFrames
          local paths = self._kantoSleepVoxelPaths
          local spr = self._kantoSleepIsHgss and self._kantoSleepProxySprite or self.sprite
          if frames and paths and spr and #frames == 3 then
            local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
            local idx = (math.floor(t * 2.2) % 3) + 1
            if self._kantoSleepVoxelFrame ~= idx then
              self._kantoSleepVoxelFrame = idx
              spr.image = frames[idx].image
              spr._kantoSleepVoxelIndex = idx
            end
          end
          if self._kantoSleepIsHgss and frames and #frames == 3 and spr then
            return spr, self.px, self.py, self.facing, 0, false
          end
        end
        return basePose(self, ...)
      end
      NPCMod._kantoLifeSleepPoseWrapped = true
    end

    if NPCMod and type(NPCMod.update) == "function" then
      local baseUpdate = NPCMod.update
      function NPCMod:update(map, entities)
        -- Enforce sleep every frame (source of truth)
        if opt("sleeping_npcs") and type(shouldSleepNow) == "function" then
          local isNight = false
          pcall(function()
            local ow = map and map or nil
            -- night() expects overworld; approximate
          end)
          -- The engine owns the live player follower. Kanto Life must never
          -- enter its sleep path, even if the follower implementation does
          -- not expose a follower flag until after the NPC update begins.
          if isPokemonFollower(self) then
            if self.nightlifeSleeping then pcall(wakeNpc, self) end
            return baseUpdate(self, map, entities)
          end
          if shouldSleepNow(self, isNight) then
            if not self.nightlifeSleeping then
              pcall(putToSleep, self)
            end
            hardFreeze(self)
            if not self._kantoSleepSpriteActive then
              pcall(bakeGrayLie, self)
            end
            -- Drive the voxel ZZZ animation from NPC.update(), which is
            -- guaranteed to run even when the voxel scene reuses poses.
            if self._kantoSleepVoxelFrames then
              local sleepSprite = self._kantoSleepIsHgss and self._kantoSleepProxySprite or self.sprite
              if sleepSprite then
                local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
                local idx = (math.floor(t * 2.2) % 3) + 1
                if self._kantoSleepVoxelFrame ~= idx then
                  self._kantoSleepVoxelFrame = idx
                  sleepSprite.image = self._kantoSleepVoxelFrames[idx].image
                  sleepSprite._kantoSleepVoxelIndex = idx
                end
              end
            end
            return -- skip wander AI entirely
          elseif self.nightlifeSleeping then
            pcall(wakeNpc, self)
          end
        elseif self.nightlifeSleeping then
          pcall(wakeNpc, self)
        end
        return baseUpdate(self, map, entities)
      end
    end

    if NPCMod and type(NPCMod.draw) == "function" then
      local baseDraw = NPCMod.draw
      function NPCMod:draw(camX, camY)
        if not self.nightlifeSleeping then
          return baseDraw(self, camX, camY)
        end
        hardFreeze(self)
        -- Always try bake once (helps voxel / true sprite path)
        if not self._kantoSleepSpriteActive and not isPokemonLike(self) and not isViridianSleepyOldMan(self) then
          pcall(bakeGrayLie, self)
        end
        local G = love.graphics
        local px = self.px or self.x or 0
        local py = self.py or self.y or 0
        local angle = self.kantoLifeSleepAngle or (math.pi / 2)
        local sx = px - (camX or 0)
        local sy = py - (camY or 0)
        -- The vanilla Viridian sleepy Old Man is already authored as a lying
        -- sprite. Never rotate/bake it a second time.
        if isViridianSleepyOldMan(self) then
          local okAuthored = pcall(function()
            G.push("all")
            G.setColor(0.55, 0.55, 0.60, 1)
            self.sprite:draw(px, py, camX or 0, camY or 0, self.facing or "down", 0, false, nil, nil, nil)
            G.setColor(1, 1, 1, 1)
            G.pop()
          end)
          if type(drawSleepZzz) == "function" and opt("sleep_bubbles") ~= false then
            drawSleepZzz(sx + 8, sy - 6, type(sleepZzzSeed) == "function" and sleepZzzSeed(self) or 0)
          end
          if okAuthored then return end
        end
        -- 2D: geometric ±90° + gray on the ORIGINAL sprite (readable characters)
        -- Use orig sprite for this path so we don't draw a failed black bake
        local drawn = false
        pcall(function()
          local spr = self._kantoOrigSprite or self.sprite
          if not (spr and type(spr.draw) == "function") then return end
          G.push("all")
          G.translate(sx + 8, sy + 8)
          G.rotate(angle)
          G.setColor(0.55, 0.55, 0.60, 1)
          -- Draw stand-down frame at local origin
          local ok = pcall(function()
            spr:draw(0, 0, 0, 0, "down", 0, false, nil, nil, nil)
          end)
          if not ok then
            -- sprite:draw wants world coords — use transform around baseDraw with orig
            G.pop()
            G.push("all")
            G.translate(sx + 8, sy + 8)
            G.rotate(angle)
            G.translate(-(sx + 8), -(sy + 8))
            G.setColor(0.55, 0.55, 0.60, 1)
            local save = self.sprite
            if self._kantoOrigSprite then self.sprite = self._kantoOrigSprite end
            baseDraw(self, camX, camY)
            self.sprite = save
          end
          G.setColor(1, 1, 1, 1)
          G.pop()
          drawn = true
        end)
        if not drawn then
          pcall(function()
            G.push("all")
            G.translate(sx + 8, sy + 8)
            G.rotate(angle)
            G.translate(-(sx + 8), -(sy + 8))
            G.setColor(0.55, 0.55, 0.60, 1)
            baseDraw(self, camX, camY)
            G.setColor(1, 1, 1, 1)
            G.pop()
          end)
        end
        if type(drawSleepZzz) == "function" and opt("sleep_bubbles") ~= false then
          drawSleepZzz(sx + 8, sy - 6,
            type(sleepZzzSeed) == "function" and sleepZzzSeed(self) or 0)
        end
      end
    end
  end
  end

  setupGameplay()
end
