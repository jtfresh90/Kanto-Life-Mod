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
  -- Johto Life owns its voxel sleep compatibility. Battle Art is intentionally
  -- left untouched: when a sleeping sprite gets a temporary sentinel image
  -- key, the engine's shared Assets.image resolver returns the baked canvas
  -- for that key. Battle Art's existing voxel renderer therefore sees the
  -- same 1-frame sleeping image that the normal 2D sprite uses.
  local SleepAssets = require("src.render.Assets")
  if not SleepAssets._johtoLifeSleepImageResolver then
    local originalImage = SleepAssets.image
    local sleepImages = {}
    SleepAssets._johtoLifeSleepOriginalImage = originalImage
    SleepAssets._johtoLifeSleepImages = sleepImages
    SleepAssets._johtoLifeSleepImageResolver = true
    SleepAssets.image = function(path)
      local img = sleepImages[path]
      if img then return img end
      return originalImage(path)
    end
  end
  local johtoSleepImages = SleepAssets._johtoLifeSleepImages
  -- Double cache clear on version update.
  -- Pass 1: clear the global image cache immediately.
  -- Pass 2: clear again after a tick to catch late-loading assets.
  -- This handles iOS file caching where old broken sprites persist.
  local function clearSleepCache()
    if SleepAssets._johtoLifeSleepImages then
      for k in pairs(SleepAssets._johtoLifeSleepImages) do
        SleepAssets._johtoLifeSleepImages[k] = nil
      end
    end
    -- Reset the baked flag version to force draw-time fallback.
    SleepAssets._johtoLifeSleepCacheVersion = 2
  end
  clearSleepCache()  -- Pass 1
  -- Pass 2 is scheduled via the sleep tick (clears again on first run).
  SleepAssets._johtoLifeSleepCacheClearPending = true
  -- Clear any stale baked-sleep flags from previous mod versions.
  -- The 1.4.0 bake produced blank canvases; if an NPC still carries the
  -- _johtoSleepBaked flag, the draw code will use the broken cached image.
  -- Resetting forces the draw-time fallback (pre-1.4.0 behavior).
  pcall(function()
    local G = _G or {}
    -- Cannot access world NPCs yet at load time; the flag is cleared
    -- lazily in the draw path via the version check below.
    SleepAssets._johtoLifeSleepCacheVersion = 2
  end)
  local sleepGrayShader

  local function getSleepGrayShader()
    if sleepGrayShader then return sleepGrayShader end
    local ok, sh = pcall(function()
      return love.graphics.newShader([[
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
          vec4 c = Texel(tex, uv) * color;
          float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
          return vec4(g, g, g, c.a);
        }
      ]])
    end)
    if ok then sleepGrayShader = sh end
    return sleepGrayShader
  end

  local sleepPropCache = {}
  local function sleepPropImage(style)
    style = math.floor(tonumber(style) or 0)
    if style <= 0 then return nil end
    local names = {[1]="sleep_tent.png", [2]="sleeping_bag.png", [3]="sleep_bed.png"}
    local rel = names[style]
    if not rel then return nil end
    if sleepPropCache[rel] then return sleepPropCache[rel] end
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
    if ok and img then img:setFilter("nearest", "nearest"); sleepPropCache[rel] = img; return img end
    mod.log:warn("Johto Life: could not load sleep prop %s", tostring(rel))
    return nil
  end

  -- Build a new 1-frame sprite from the NPC's current rendered standing frame,
  -- rotated ±90°, so both the flat and voxel renderers consume the same pixels.
  local function bakeRotatedSleepSprite(npc)
    if not npc or not npc.sprite then return false end
    local sprite = npc.sprite
    if sprite._johtoSleepBaked then return true end
    local angle = npc.johtoLifeSleepAngle or (math.pi / 2)
    local fw = tonumber(sprite.frameWidth) or 16
    local fh = tonumber(sprite.frameHeight) or 16

    local ok, canvas = pcall(function()
      local img = nil
      if type(sprite.resolveImage) == "function" then
        local ok2, r = pcall(function() return sprite:resolveImage() end)
        if ok2 then img = r end
      end
      if not img then img = sprite.image end
      if not img then return nil end
      local quad = sprite.frames and (sprite.frames[0] or sprite.frames[1])
      local c = love.graphics.newCanvas(fw, fh)
      local prev = love.graphics.getCanvas()
      love.graphics.setCanvas(c)
      love.graphics.clear(0, 0, 0, 0)
      love.graphics.setBlendMode("alpha")
      love.graphics.setColor(1, 1, 1, 1)
      local gray = getSleepGrayShader()
      if gray then love.graphics.setShader(gray) end
      love.graphics.push()
      love.graphics.translate(fw / 2, fh / 2)
      love.graphics.rotate(angle)
      love.graphics.translate(-fw / 2, -fh / 2)
      if quad then
        love.graphics.draw(img, quad, 0, 0)
      else
        love.graphics.draw(img, 0, 0)
      end
      love.graphics.pop()
      love.graphics.setShader()
      love.graphics.setCanvas(prev)
      return c
    end)
    if not (ok and canvas) then return false end
    local sleepKey = "__johto_life_sleep__" .. tostring(npc)
    johtoSleepImages[sleepKey] = canvas
    sprite._johtoSleepImageKey = sleepKey
    sprite._johtoOrigImage = sprite.image
    sprite._johtoOrigFrames = sprite.frames
    sprite._johtoOrigFrameCount = sprite.frameCount
    sprite._johtoOrigDef = sprite.def
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
    newDef.image = sleepKey
    newDef.frames = 1
    newDef.walker = false
    sprite.def = newDef
    sprite._johtoSleepBaked = true
    return true
  end

  local function restoreRotatedSleepSprite(npc)
    if not npc or not npc.sprite or not npc.sprite._johtoSleepBaked then return end
    local sprite = npc.sprite
    if sprite._johtoSleepImageKey then
      johtoSleepImages[sprite._johtoSleepImageKey] = nil
      sprite._johtoSleepImageKey = nil
    end
    if sprite._johtoOrigImage ~= nil then sprite.image = sprite._johtoOrigImage end
    if sprite._johtoOrigFrames ~= nil then sprite.frames = sprite._johtoOrigFrames end
    if sprite._johtoOrigFrameCount ~= nil then sprite.frameCount = sprite._johtoOrigFrameCount end
    if sprite._johtoOrigDef ~= nil then sprite.def = sprite._johtoOrigDef end
    if sprite._johtoOrigFrameWidth ~= nil then sprite.frameWidth = sprite._johtoOrigFrameWidth end
    if sprite._johtoOrigFrameHeight ~= nil then sprite.frameHeight = sprite._johtoOrigFrameHeight end
    if sprite._johtoOrigAnchorX ~= nil then sprite.anchorX = sprite._johtoOrigAnchorX end
    if sprite._johtoOrigAnchorY ~= nil then sprite.anchorY = sprite._johtoOrigAnchorY end
    sprite._johtoOrigFrameWidth = nil
    sprite._johtoOrigFrameHeight = nil
    sprite._johtoOrigAnchorX = nil
    sprite._johtoOrigAnchorY = nil
    sprite._johtoSleepIsHgss = nil
    sprite._johtoOrigImage = nil
    sprite._johtoOrigFrames = nil
    sprite._johtoOrigFrameCount = nil
    sprite._johtoOrigDef = nil
    sprite._johtoSleepBaked = nil
  end


  -- Johto Life 0.1.52 — Gen2 only
  local function resolveGame()
    if mod.game ~= nil then return mod.game end
    if mod.world and mod.world.game ~= nil then return mod.world.game end
    return nil
  end
  local game = resolveGame()
  local function G() game = resolveGame() or game; return game end

  mod.options:define({
    { key = "extra_npcs", type = "toggle", label = "EXTRA NPCS", default = true },
    { key = "extra_npc_count", type = "number", label = "EXTRA NPC COUNT",
      default = 0, min = 0, max = 150, step = 1 },
    { key = "indoor_npcs", type = "toggle", label = "INDOOR NPCS", default = true },
    { key = "indoor_npc_count", type = "number", label = "INDOOR NPC COUNT",
      default = 3, min = 0, max = 30, step = 1 },
    { key = "pokemon_npcs", type = "toggle", label = "POKEMON NPCS", default = true },
    { key = "pokemon_npc_count", type = "number", label = "POKEMON NPC COUNT",
      default = 0, min = 0, max = 50, step = 1 },
    { key = "poke_random", type = "toggle", label = "RANDOM POKE NPCS", default = false },
    { key = "sleeping_npcs", type = "toggle", label = "SLEEPING NPCS", default = true },
    { key = "sleep_pct", type = "number", label = "SLEEP RATE %",
      default = 30, min = 0, max = 100, step = 10 },
    { key = "day_sleepers", type = "toggle", label = "DAY SLEEPERS", default = true },
    { key = "sleep_bubbles", type = "toggle", label = "SLEEP ZZZ", default = true },
    { key = "sleep_style", type = "choice", label = "SLEEP STYLE", default = 0, choices = { { "Default", 0 }, { "Tent", 1 }, { "Sleeping Bag", 2 }, { "Bed", 3 }, { "Random", 4 } } },
    { key = "npc_collision_bubbles", type = "toggle", label = "NPC TALK BUBBLES", default = true },
    { key = "common_courtesy", type = "toggle", label = "DOOR KNOCKING", default = true },
    { key = "npc_routines", type = "toggle", label = "NPC ROUTINES", default = true },
        { key = "npc_travel_pct", type = "number", label = "NPC TRAVEL %",
      default = 30, min = 0, max = 100, step = 10 },
    { key = "npc_travel_methods", type = "toggle", label = "TRAVEL METHODS", default = true },
    { key = "npc_agenda", type = "choice", label = "NPC AGENDA",
      choices = { { "OFF", 0 }, { "DAY", 1 }, { "FULL", 2 } }, default = 0 },
  })

  if mod.save and type(mod.save.get) == "function" and type(mod.save.set) == "function" then
    local okSeed, seeded = pcall(mod.save.get, mod.save, "npcTravelPctV3Seeded")
    if okSeed and not seeded then
      pcall(mod.save.set, mod.save, "npc_travel_pct", 30)
      pcall(mod.save.set, mod.save, "npcTravelPctV3Seeded", true)
    end
  end

  local function writeOptionBucket(key, value)
    local g = G()
    if not (mod and mod.id) then return false end
    local function write(bucket)
      if type(bucket) ~= "table" then return false end
      bucket[mod.id] = bucket[mod.id] or {}
      bucket[mod.id][key] = value
      return true
    end
    local wrote = false
    if g and g.save then
      g.save.options = g.save.options or {}
      g.save.options.modOptions = g.save.options.modOptions or {}
      if write(g.save.options.modOptions) then wrote = true end
    end
    if g and g.mods then
      g.mods.modOptions = g.mods.modOptions or {}
      if write(g.mods.modOptions) then wrote = true end
      if g.mods.loader then
        g.mods.loader.modOptions = g.mods.loader.modOptions or {}
        if write(g.mods.loader.modOptions) then wrote = true end
      end
    end
    if g and type(g.writeOptions) == "function" then pcall(g.writeOptions, g) end
    if mod.options and type(mod.options.set) == "function" then
      pcall(function() mod.options:set(key, value) end)
      wrote = true
    end
    return wrote
  end

  local function opt(k)
    if mod.options and type(mod.options.get) == "function" then
      local v = mod.options:get(k)
      if v ~= nil then return v end
    end
    local g = G()
    local buckets = {}
    if g and g.save and g.save.options and g.save.options.modOptions then
      buckets[#buckets + 1] = g.save.options.modOptions[mod.id]
    end
    if g and g.mods and g.mods.modOptions then
      buckets[#buckets + 1] = g.mods.modOptions[mod.id]
    end
    if g and g.mods and g.mods.loader and g.mods.loader.modOptions then
      buckets[#buckets + 1] = g.mods.loader.modOptions[mod.id]
    end
    for i = 1, #buckets do
      local b = buckets[i]
      if type(b) == "table" and b[k] ~= nil then return b[k] end
    end
    return nil
  end
  local function setOpt(k, v) return writeOptionBucket(k, v) end

  local outdoorTouched = mod.save:get("outdoorTouched") and true or false
  local pokeTouched = mod.save:get("pokeTouched") and true or false
  local MOVE_WANDER, MOVE_WALK_UD, MOVE_WALK_LR = 2, 4, 5
  local townDefaults = {
    NEW_BARK_TOWN = 12, CHERRYGROVE_CITY = 20, VIOLET_CITY = 40,
    AZALEA_TOWN = 25, GOLDENROD_CITY = 80, ECRUTEAK_CITY = 50,
    OLIVINE_CITY = 40, CIANWOOD_CITY = 25, MAHOGANY_TOWN = 20,
    BLACKTHORN_CITY = 35, PALLET_TOWN = 8, VIRIDIAN_CITY = 20,
    PEWTER_CITY = 25, CERULEAN_CITY = 30, VERMILION_CITY = 30,
    LAVENDER_TOWN = 15, CELADON_CITY = 60, FUCHSIA_CITY = 40,
    SAFFRON_CITY = 60, CINNABAR_ISLAND = 10,
  }
  local ROUTE_DEFAULT = 8
  local SPRITE_DEFS = {
    { "SPRITE_YOUNGSTER", "m" }, { "SPRITE_LASS", "f" },
    { "SPRITE_BUG_CATCHER", "m" }, { "SPRITE_COOLTRAINER_M", "m" },
    { "SPRITE_COOLTRAINER_F", "f" }, { "SPRITE_BEAUTY", "f" },
    { "SPRITE_SUPER_NERD", "m" }, { "SPRITE_ROCKER", "m" },
    { "SPRITE_POKEFAN_M", "m" }, { "SPRITE_POKEFAN_F", "f" },
    { "SPRITE_GRAMPS", "m" }, { "SPRITE_GRANNY", "f" },
    { "SPRITE_TWIN", "f" }, { "SPRITE_SCHOOLBOY", "m" },
    { "SPRITE_TEACHER", "f" }, { "SPRITE_FISHER", "m" },
    { "SPRITE_BIRD_KEEPER", "m" }, { "SPRITE_SCIENTIST", "m" },
    { "SPRITE_OFFICER", "m" }, { "SPRITE_SAGE", "m" },
    { "SPRITE_BOARDER", "m" }, { "SPRITE_SKIER", "f" },
    { "SPRITE_BUENA", "f" }, { "SPRITE_SAILOR", "m" },
    { "SPRITE_SWIMMER_GUY", "m" }, { "SPRITE_SWIMMER_GIRL", "f" },
  }
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
  local POKE_LIST = {
    "PIDGEY","RATTATA","SPEAROW","PIKACHU","SANDSHREW","NIDORAN_F","NIDORAN_M",
    "CLEFAIRY","VULPIX","JIGGLYPUFF","ZUBAT","ODDISH","PARAS","MEOWTH","PSYDUCK",
    "MANKEY","GROWLITHE","POLIWAG","ABRA","MACHOP","BELLSPROUT","TENTACOOL",
    "GEODUDE","PONYTA","SLOWPOKE","MAGNEMITE","FARFETCH_D","DODUO","SEEL",
    "GRIMER","SHELLDER","GASTLY","ONIX","DROWZEE","KRABBY","VOLTORB","EXEGGCUTE",
    "CUBONE","KOFFING","RHYHORN","CHANSEY","TANGELA","HORSEA","GOLDEEN","STARYU",
    "SCYTHER","JYNX","ELECTABUZZ","MAGMAR","PINSIR","TAUROS","MAGIKARP","EEVEE",
    "SENTRET","HOOTHOOT","LEDYBA","SPINARAK","CHINCHOU","PICHU","CLEFFA","IGGLYBUFF",
    "TOGEPI","NATU","MAREEP","MARILL","HOPPIP","AIPOM","SUNKERN","YANMA","WOOPER",
    "MURKROW","MISDREAVUS","GIRAFARIG","PINECO","DUNSPARCE","GLIGAR","SNUBBULL",
    "QWILFISH","SHUCKLE","HERACROSS","SNEASEL","TEDDIURSA","SLUGMA","SWINUB",
    "CORSOLA","REMORAID","DELIBIRD","MANTINE","SKARMORY","HOUNDOUR","PHANPY",
    "STANTLER","SMEARGLE","TYROGUE","SMOOCHUM","ELEKID","MAGBY","MILTANK",
  }
  local POKE_LEGENDARY = {
    "ARTICUNO","ZAPDOS","MOLTRES","MEWTWO","MEW",
    "RAIKOU","ENTEI","SUICUNE","LUGIA","HO_OH","CELEBI",
  }
  local POKE_WATER = {
    "PSYDUCK","POLIWAG","TENTACOOL","SLOWPOKE","SEEL","SHELLDER","KRABBY",
    "HORSEA","GOLDEEN","STARYU","MAGIKARP","CHINCHOU","MARILL","WOOPER",
    "QWILFISH","CORSOLA","REMORAID","MANTINE","QUAGSIRE","OCTILLERY",
  }
  local WATER_SPECIES = {}
  for _, s in ipairs(POKE_WATER) do WATER_SPECIES[s] = true end
  local function isWaterSpecies(sp)
    if type(sp) ~= "string" then return false end
    sp = sp:upper()
    if WATER_SPECIES[sp] then return true end
    local g = G and G() or game
    local data = g and g.data and g.data.pokemon and g.data.pokemon[sp]
    if type(data) == "table" and type(data.types) == "table" then
      for _, ty in ipairs(data.types) do
        if tostring(ty):upper() == "WATER" then return true end
      end
    end
    return false
  end
  local function isSwimmingSpriteKey(key)
    if type(key) ~= "string" then return false end
    key = key:upper()
    return key == "SPRITE_SWIMMER_GUY" or key == "SPRITE_SWIMMER_GIRL"
  end
  local function npcIsAquatic(npc)
    if not npc then return false end
    local d = npc.def or {}
    if d.johtoLifeAquatic ~= nil then return d.johtoLifeAquatic == true end
    if d.johtoLifePokemon then return isWaterSpecies(d.johtoLifeMon) end
    local key = (type(npc.spriteId) == "string" and npc.spriteId)
      or (type(d.sprite) == "string" and d.sprite)
    return isSwimmingSpriteKey(key)
  end
  local TOWN_FALLBACK = {
    "SENTRET","HOOTHOOT","PIDGEY","RATTATA","PICHU","TOGEPI","MARILL",
    "HOPPIP","SNUBBULL","TEDDIURSA","CLEFAIRY","JIGGLYPUFF","EEVEE",
  }
  local function fullDexSpecies()
    local out, seen = {}, {}
    local function add(sp)
      if type(sp) ~= "string" or sp == "" then return end
      sp = sp:upper()
      if seen[sp] then return end
      seen[sp] = true
      out[#out + 1] = sp
    end
    local g = G and G() or game
    local data = g and g.data and g.data.pokemon
    if type(data) == "table" then
      for id, _ in pairs(data) do
        if type(id) == "string" then add(id) end
      end
    end
    if #out == 0 then
      for _, s in ipairs(POKE_LIST) do add(s) end
      for _, s in ipairs(POKE_LEGENDARY) do add(s) end
    else
      for _, s in ipairs(POKE_LEGENDARY) do add(s) end
    end
    return out
  end
  local function areaSpeciesPool(mapId, map)
    -- Wilds Town Pokémon style for Gen2:
    -- local encounters → neighbor routes → fallback (no forced legendaries)
    local pool, seen = {}, {}
    local function add(sp)
      if type(sp) ~= "string" or sp == "" then return end
      sp = sp:upper()
      if seen[sp] then return end
      seen[sp] = true
      pool[#pool + 1] = sp
    end
    local function take(block)
      if type(block) ~= "table" then return end
      local slots = block.slots or block
      if type(slots) ~= "table" then return end
      for _, slot in ipairs(slots) do
        if type(slot) == "table" then
          add(slot.species or slot.pokemon or slot[1])
        elseif type(slot) == "string" then
          add(slot)
        end
      end
      -- Gen2 sometimes nests by time of day
      for _, k in ipairs({ "morn", "day", "nite", "MORN", "DAY", "NITE" }) do
        local sub = block[k]
        if type(sub) == "table" then
          local ss = sub.slots or sub
          if type(ss) == "table" then
            for _, slot in ipairs(ss) do
              if type(slot) == "table" then add(slot.species or slot.pokemon or slot[1])
              elseif type(slot) == "string" then add(slot) end
            end
          end
        end
      end
    end
    local g = G and G() or game
    local data = g and g.data
    local encounters = data and (data.encounters or data.gen2Encounters)
    local function fromMap(mid)
      if not encounters or not mid then return end
      local enc = encounters[mid]
      if type(enc) ~= "table" then return end
      take(enc.grass)
      take(enc.water)
      take(enc.surfing)
      take(enc.fish)
      take(enc.fishing)
      -- Gen2: grass/water may be maps of location -> tables
      if type(enc.grass) == "table" and not enc.grass.slots then
        for _, v in pairs(enc.grass) do
          if type(v) == "table" then take(v) end
        end
      end
      if type(enc.water) == "table" and not enc.water.slots then
        for _, v in pairs(enc.water) do
          if type(v) == "table" then take(v) end
        end
      end
    end
    fromMap(mapId)
    if #pool == 0 and map then
      local def = map.def or map
      local conns = def and def.connections
      if type(conns) == "table" then
        for _, dir in ipairs({ "north", "south", "east", "west" }) do
          local conn = conns[dir]
          local dest = conn and (conn.map or conn.mapId or conn.dest)
          if type(dest) == "string" then fromMap(dest) end
          if #pool >= 8 then break end
        end
      end
    end
    if #pool == 0 then
      for _, sp in ipairs(TOWN_FALLBACK) do add(sp) end
    end
    return pool
  end
  local lastPokeRandomMode = nil
  local POKE_CRY_LINES = { "%s!", "%s!\n%s!", "%s?", "%s...", "%s!\n%s?" }
  local lines = {
    "I'm headed to the\nMART before sunset.", "JOHTO feels lively\ntoday!",
    "Have you tried the\nlocal GYM?", "My partner is at\nthe POKEMON CENTER.",
    "I'm training for\nthe LEAGUE!", "Watch for wild\nPOKEMON in the grass!",
    "GOLDENROD has the\nbest shops!", "I love the music\nin this town!",
    "Excuse me, do you\nknow the way?", "I'm visiting family\nin the next town.",
    "The weather is\nperfect for a stroll!", "TEAM ROCKET better\nstay away!",
    "I'm saving up for\na BICYCLE!", "Have you seen any\nrare POKEMON?",
    "Don't step on the\nflower beds!",
  }
  local routeLines = {
    "These routes are\nfull of TRAINERS!", "I'm traveling\nbetween towns.",
    "Tall grass hides\nsurprises!", "Don't get lost on\nthe long road.",
    "My team needs more\nexperience!",
  }

  local spawnSerial = 0
  local function isTown(id) return townDefaults[id] ~= nil end
  local function isRoute(id) return type(id) == "string" and id:match("^ROUTE_") ~= nil end

  -- Detect wild-spawn mods to reduce NPC-list pressure when they are active.
  local function wildSpawnModActive()
    if not mod then return false end
    local knownIds = { "overworld_wild_spawns", "wilds_of_kanto", "wilds_of_kanto_revival", "wild_skies", "untamed_hoenn", "untamed_tohoj", "untamed_advance", "wild_followers", }
    if mod.list and type(mod.list) == "function" then
      local ok, list = pcall(mod.list)
      if ok and type(list) == "table" then
        for _, m in ipairs(list) do
          local id = (type(m) == "table" and (m.id or m.name)) or tostring(m)
          id = string.lower(tostring(id))
          for _, known in ipairs(knownIds) do
            if string.find(id, known, 1, true) then return true end
          end
        end
      end
    end
    if _G.overworld_wild_spawns or _G.wilds_of_kanto or _G.wild_skies then return true end
    return false
  end
  local function isIndoor(id, map)
    -- Gold's Map exposes the ROM's environment directly.  Prefer it over
    -- filename heuristics so indoor maps whose ids do not contain HOUSE/MART/
    -- CENTER/_1F are still eligible for the configured indoor population.
    local env = map and (map.environment or (map.def and map.def.environment))
    if env ~= nil then
      env = tostring(env):upper()
      if env == "INDOOR" or env == "CAVE" or env == "DUNGEON" or env == "GATE" then return true end
      if env == "TOWN" or env == "ROUTE" or env == "OUTDOOR" then return false end
    end
    if not id then return false end
    id = tostring(id)
    if isTown(id) or isRoute(id) then return false end
    if id:find("HOUSE", 1, true) or id:find("HOME", 1, true) then return true end
    if id:find("_1F", 1, true) or id:find("_2F", 1, true) or id:find("_3F", 1, true) then return true end
    if id:find("MART", 1, true) or id:find("CENTER", 1, true) or id:find("GYM", 1, true) then return true end
    return false
  end
  local function defaultCount(id)
    if townDefaults[id] then return townDefaults[id] end
    if isRoute(id) then return ROUTE_DEFAULT end
    if isIndoor(id, nil) then return math.floor(tonumber(opt("indoor_npc_count")) or 3) end
    return 0
  end
  local function humanTarget(mapId, map)
    if not opt("extra_npcs") then return 0 end
    if isIndoor(mapId, map) then
      if not opt("indoor_npcs") then return 0 end
      return math.max(0, math.floor(tonumber(opt("indoor_npc_count")) or 3))
    end
    if not (isTown(mapId) or isRoute(mapId)) then return 0 end
    if outdoorTouched then return math.max(0, math.floor(tonumber(opt("extra_npc_count")) or 0)) end
    local n = math.floor(tonumber(opt("extra_npc_count")) or 0)
    if n > 0 then return n end
    return defaultCount(mapId)
  end
  local function pokeTarget(mapId, map)
    if not opt("pokemon_npcs") then return 0 end
    local base = 0
    if isIndoor(mapId, map) then
      if not opt("indoor_npcs") then return 0 end
      base = math.max(0, math.floor(tonumber(opt("pokemon_npc_count")) or 0))
    elseif not (isTown(mapId) or isRoute(mapId)) then
      return 0
    else
      base = math.max(0, math.floor(tonumber(opt("pokemon_npc_count")) or 0))
    end
    if base > 1 and wildSpawnModActive() then base = math.floor(base / 2) end
    return base
  end
  local function cellHasWarp(map, x, y)
    if not map then return false end
    if map.warpAt and map:warpAt(x, y) then return true end
    if map.warpAtCell and map:warpAtCell(x, y) then return true end
    local warps = map.def and map.def.warps or map.warps
    if type(warps) == "table" then
      for _, w in pairs(warps) do
        if type(w) == "table" and w.x == x and w.y == y then return true end
      end
    end
    return false
  end
  -- Keep the original Johto Life spawn coordinate search intact. The prior
  -- version expanded this to widthCells/heightCells, which is valid for Map's
  -- cell API but broke the mod's existing ambient placement in practice.
  -- Surface filtering is layered onto the same coordinate range instead.
  local function pickCell(ow, map, surface)
    if not (ow and map) then return nil end
    local w = map.widthCells or map.width or (map.def and map.def.widthCells) or (map.def and map.def.width) or 20
    local h = map.heightCells or map.height or (map.def and map.def.heightCells) or (map.def and map.def.height) or 18
    for _ = 1, 90 do
      local x = love.math.random(2, math.max(2, w - 3))
      local y = love.math.random(2, math.max(2, h - 3))
      local blocked = false
      local isWater = false
      if map.isWaterCell then
        local ok, v = pcall(function() return map:isWaterCell(x, y) end)
        isWater = ok and v == true
      end

      if surface == true then
        -- Aquatic ambient actors must be placed on actual water.
        if not isWater then blocked = true end
      else
        -- Land actors keep the exact old walkability test, plus a water veto.
        if isWater then blocked = true end
        if map.isWalkable and not map:isWalkable(x, y) then blocked = true end
        if map.isWalkableCell and not map:isWalkableCell(x, y) then blocked = true end
      end

      if cellHasWarp(map, x, y) then blocked = true end
      if not blocked then
        for dx = -1, 1 do for dy = -1, 1 do
          if cellHasWarp(map, x + dx, y + dy) then blocked = true end
        end end
      end
      if not blocked then
        for _, e in ipairs(ow.entities or ow.npcs or {}) do
          if e.cellX == x and e.cellY == y then blocked = true break end
        end
      end
      if not blocked then return x, y end
    end
    return nil
  end
  local function randomName(g)
    local pool = (g == "f") and FEMALE_NAMES or MALE_NAMES
    return pool[love.math.random(#pool)]
  end
  local function liveAmbient(ow, pokeOnly)
    local list = {}
    for _, n in ipairs((ow and ow.npcs) or {}) do
      local d = n.def or {}
      if d.johtoLifeAmbient then
        local isPoke = d.johtoLifePokemon and true or false
        if pokeOnly == nil or pokeOnly == isPoke then list[#list + 1] = n end
      end
    end
    return list
  end

  local function spawnOne(ow, map, mapId, isPoke)
    spawnSerial = spawnSerial + 1
    local sprite, gender, displayName, monName, movement, radius
    local aquatic = false
    if isPoke then
      local pool
      if opt("poke_random") then pool = fullDexSpecies()
      else pool = areaSpeciesPool(mapId, map) end
      if not pool or #pool == 0 then pool = POKE_LIST end
      monName = pool[love.math.random(1, #pool)]
      displayName, gender, sprite = monName, "m", "SPRITE_" .. monName
      aquatic = isWaterSpecies(monName)
      -- Native Gen2 uses SWIM_WANDER ($24) for water walkers.
      movement, radius = aquatic and 0x24 or MOVE_WANDER,
                        aquatic and { x = 2, y = 2 } or { x = 2, y = 2 }
    else
      local pool = SPRITE_DEFS
      if isIndoor(mapId, map) then
        pool = {}
        for _, candidate in ipairs(SPRITE_DEFS) do
          local key = candidate[1]
          if key ~= "SPRITE_SWIMMER_GUY" and key ~= "SPRITE_SWIMMER_GIRL"
              and key ~= "SPRITE_BOARDER" and key ~= "SPRITE_SKIER" then
            pool[#pool+1] = candidate
          end
        end
        if #pool == 0 then pool = SPRITE_DEFS end
      end
      local def = pool[love.math.random(#pool)]
      sprite, gender = def[1], def[2]
      displayName = randomName(gender)
      aquatic = isSwimmingSpriteKey(sprite)
      local roll = love.math.random(1, 3)
      if aquatic then movement = 0x24
      elseif roll == 1 then movement = MOVE_WALK_UD
      elseif roll == 2 then movement = MOVE_WALK_LR
      else movement = MOVE_WANDER end
      radius = { x = 3, y = 3 }
    end

    local x, y = pickCell(ow, map, aquatic and true or false)
    if not x then return nil end

    local tag = isPoke and "JOHTO_POKE_" or "JOHTO_NPC_"
    local name = tag .. tostring(mapId) .. "_" .. spawnSerial .. "_" .. tostring(love.math.random(100000))
    local function trySpawn(spr)
      return mod.world:spawnNpc(mapId, {
        name = name, sprite = spr, x = x, y = y, text = "",
        movement = movement, radius = radius,
        johtoLifeAmbient = true,
        johtoLifePokemon = isPoke and true or nil,
        johtoLifeDisplayName = displayName,
        johtoLifeGender = gender,
        johtoLifeMon = monName,
        johtoLifeAquatic = aquatic or nil,
      })
    end
    local id = trySpawn(sprite)
    if not id and isPoke then
      id = trySpawn(monName) or trySpawn("SPRITE_POKEMON") or trySpawn("SPRITE_POKE_BALL")
    end
    if not id then return nil end
    for _, n in ipairs(ow.npcs or {}) do
      if n.id == id or (n.def and n.def.name == name) then
        n.def = n.def or {}
        n.def.johtoLifeAmbient = true
        n.def.johtoLifePokemon = isPoke and true or nil
        n.def.johtoLifeDisplayName = displayName
        n.def.johtoLifeMon = monName
        n.def.johtoLifeAquatic = aquatic or nil
        n.frozen = false
        -- Aquatic objects use the native collision hook below; the normal
        -- objects remain ordinary Gen2 wanderers.
        if n.kind == nil or n.kind == "stand" then
          n.kind = "walk"
          n.roamDirs = { "up", "down", "left", "right" }
          n.radiusX = (radius and radius.x) or 3
          n.radiusY = (radius and radius.y) or 3
          n.homeX = n.cellX or x
          n.homeY = n.cellY or y
          n.timer = love.math.random(20, 90)
        end
        return n
      end
    end
    return true
  end

  local function spawnAmbient(mapId)
    if not mapId then return end
    if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId, mod.world and mod.world:overworld() and mod.world:overworld().map)) then return end
    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map or ow.map.id ~= mapId then return end
    local map = ow.map
    local function balance(want, pokeOnly)
      local have = liveAmbient(ow, pokeOnly)
      while #have > want do
        local n = table.remove(have)
        local id = n.id or (n.def and n.def.id)
        if id then pcall(function() mod.world:removeNpc(id) end) end
      end
      local guard = 0
      while #have < want and guard < want + 25 do
        guard = guard + 1
        local n = spawnOne(ow, map, mapId, pokeOnly)
        if n then have[#have + 1] = n else break end
      end
    end
    balance(humanTarget(mapId, map), false)
    if isTown(mapId) or isRoute(mapId) then
      local modeNow = opt("poke_random") and true or false
      -- nil ~= true/false is true in Lua: first force-refresh and every toggle
      -- must clear existing poke NPCs so the active pool applies immediately.
      if lastPokeRandomMode ~= modeNow then
        local live = liveAmbient(ow, true)
        for _, n in ipairs(live) do
          local id = n.id or (n.def and n.def.id)
          if id then pcall(function() mod.world:removeNpc(id) end) end
        end
        lastPokeRandomMode = modeNow
      end
      balance(pokeTarget(mapId, map), true)
    end
  end
  local function refreshCurrentMap()
    local ow = mod.world and mod.world:overworld()
    if ow and ow.map then spawnAmbient(ow.map.id) end
  end
  local function safeRequire(path)
    local ok, m = pcall(require, path)
    if ok then return m end
    return nil
  end

  -- Gen-2-native routine controller. It uses only the public mod.world NPC
  -- handle surface, which Gen1Recomp++ resolves to the live Gold/Silver/Crystal
  -- world. No Gen-1 OverworldController internals are patched here.
  local JohtoRoutines, johtoRoutineErr = loadBundled("lib/JohtoRoutines.lua")
  local johtoRoutines = nil
  if type(JohtoRoutines) == "function" then
    local ok, instance = pcall(JohtoRoutines, {
      mod = mod,
      game = function() return G() end,
      isIndoor = isIndoor,
      isTown = isTown,
      isRoute = isRoute,
      resolveDestMap = function(data, warpDef)
        return warpDef and warpDef.destMap
      end,
      getOption = function(k) return opt(k) end,
    })
    if ok and instance then
      johtoRoutines = instance
      if type(johtoRoutines.setTravelPercent) == "function" then
        johtoRoutines.setTravelPercent(opt("npc_travel_pct") or 30)
      end
      if type(johtoRoutines.setEnabled) == "function" then
        johtoRoutines.setEnabled(opt("npc_routines") ~= false)
      end
      if type(johtoRoutines.setAgenda) == "function" then
        johtoRoutines.setAgenda(opt("npc_agenda") or 0)
      end
    else
      mod.log:error("JohtoRoutines load failed: %s", tostring(johtoRoutineErr))
    end
  end

  mod.exports = mod.exports or {}
  mod.exports.johtoLifeRoutines = johtoRoutines

  local johtoSleepTick

  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("input.step", function(next, g, dt)
      local result = next(g, dt)
      local owner = g or G()
      local ow = owner and owner.world
      if ow and ow.map then johtoSleepTick(ow) end
      return result
    end)
  end

  -- Keep water-only ambient swimmers on water. Native collision already
  -- keeps land NPCs off water; this hook only grants SWIM_WANDER access to
  -- water cells for the Johto Life actors that were intentionally spawned there.
  if mod.hooks and mod.hooks.wrap then
    pcall(function()
      mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
        local mover = ctx and ctx.mover
        if not (mover and mover.def and mover.def.johtoLifeAmbient) then
          return next(allowed, ctx)
        end
        local map = ctx.map
        if not (map and map.isWaterCell and ctx.toX ~= nil and ctx.toY ~= nil) then
          return next(allowed, ctx)
        end
        local ok, water = pcall(function() return map:isWaterCell(ctx.toX, ctx.toY) end)
        if not ok then return next(allowed, ctx) end
        local aquatic = npcIsAquatic(mover)
        if water and aquatic then return true end
        if water and not aquatic then return false end
        if aquatic then return false end
        return next(allowed, ctx)
      end)
    end)
  end

  local function navPressed(input, dir)
    if not input then return false end
    if type(input.wasPressed) == "function" then
      local ok, v = pcall(function() return input:wasPressed(dir) end)
      if ok and v then return true end
    end
    if type(input.pressed) == "table" and input.pressed[dir] then return true end
    if type(input.down) == "function" then
      local ok, v = pcall(function() return input:down(dir) end)
      if ok and v then return true end
    end
    if type(input.state) == "table" and input.state[dir] then return true end
    return false
  end

  local function openJohtoOptions(parentGame)
    local g = parentGame or G()
    local function rebuildItems()
      return {
        { label = "EXTRA NPCS", right = opt("extra_npcs") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("extra_npcs", not opt("extra_npcs")); refreshCurrentMap() end },
        { label = "NPC COUNT", right = tostring(math.floor(tonumber(opt("extra_npc_count")) or 0)), stepper = true,
          step = function(dir)
            outdoorTouched = true; mod.save:set("outdoorTouched", true)
            local n = math.max(0, math.min(150, math.floor(tonumber(opt("extra_npc_count")) or 0) + (dir or 1)))
            setOpt("extra_npc_count", n); refreshCurrentMap()
          end,
          onSelect = function()
            outdoorTouched = true; mod.save:set("outdoorTouched", true)
            local n = math.floor(tonumber(opt("extra_npc_count")) or 0)
            setOpt("extra_npc_count", (n >= 150) and 0 or (n + 1)); refreshCurrentMap()
          end },
        { label = "INDOOR NPCS", right = opt("indoor_npcs") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("indoor_npcs", not opt("indoor_npcs")); refreshCurrentMap() end },
        { label = "INDOOR COUNT", right = tostring(math.floor(tonumber(opt("indoor_npc_count")) or 3)), stepper = true,
          step = function(dir)
            local n = math.max(0, math.min(30, math.floor(tonumber(opt("indoor_npc_count")) or 3) + (dir or 1)))
            setOpt("indoor_npc_count", n); refreshCurrentMap()
          end,
          onSelect = function()
            local n = math.floor(tonumber(opt("indoor_npc_count")) or 3)
            setOpt("indoor_npc_count", (n >= 30) and 0 or (n + 1)); refreshCurrentMap()
          end },
        { label = "POKE NPCS", right = opt("pokemon_npcs") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("pokemon_npcs", not opt("pokemon_npcs")); refreshCurrentMap() end },
        { label = "POKE COUNT", right = tostring(math.floor(tonumber(opt("pokemon_npc_count")) or 0)), stepper = true,
          step = function(dir)
            pokeTouched = true; mod.save:set("pokeTouched", true)
            local n = math.max(0, math.min(50, math.floor(tonumber(opt("pokemon_npc_count")) or 0) + (dir or 1)))
            setOpt("pokemon_npc_count", n); refreshCurrentMap()
          end,
          onSelect = function()
            pokeTouched = true; mod.save:set("pokeTouched", true)
            local n = math.floor(tonumber(opt("pokemon_npc_count")) or 0)
            setOpt("pokemon_npc_count", (n >= 50) and 0 or (n + 1)); refreshCurrentMap()
          end },
        { label = "RANDOM POKE", right = opt("poke_random") and "ON" or "OFF", stepper = true,
          onSelect = function()
            setOpt("poke_random", not opt("poke_random"))
            lastPokeRandomMode = nil
            refreshCurrentMap()
          end },
        { label = "DOOR KNOCKING", right = opt("common_courtesy") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("common_courtesy", not opt("common_courtesy")) end },
        { label = "SLEEP NPCS", right = opt("sleeping_npcs") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("sleeping_npcs", not opt("sleeping_npcs")) end },
        { label = "SLEEP %", right = tostring(math.floor(tonumber(opt("sleep_pct")) or 15)), stepper = true,
          step = function(dir)
            local n = math.max(0, math.min(100, math.floor(tonumber(opt("sleep_pct")) or 10) + 10 * (dir or 1)))
            setOpt("sleep_pct", n)
          end,
          onSelect = function()
            local n = math.floor(tonumber(opt("sleep_pct")) or 10)
            setOpt("sleep_pct", (n >= 100) and 0 or (n + 10))
          end },
        { label = "DAY SLEEP", right = opt("day_sleepers") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("day_sleepers", not opt("day_sleepers")) end },
        { label = "SLEEP STYLE", right = ({[0]="Default",[1]="Tent",[2]="Sleeping Bag",[3]="Bed",[4]="Random"})[math.floor(tonumber(opt("sleep_style")) or 0)] or "Default", stepper = true,
          step = function(dir) local n=(math.floor(tonumber(opt("sleep_style")) or 0)+(dir or 1))%5; setOpt("sleep_style",n) end,
          onSelect = function() local n=(math.floor(tonumber(opt("sleep_style")) or 0)+1)%5; setOpt("sleep_style",n) end },
        { label = "NPC TALK BUBBLES", right = opt("npc_collision_bubbles") ~= false and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("npc_collision_bubbles", not (opt("npc_collision_bubbles") ~= false)) end },
        { label = "NPC ROUTINES", right = opt("npc_routines") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("npc_routines", not opt("npc_routines")); refreshCurrentMap() end },
        { label = "NPC TRAVEL %", right = tostring(math.floor(tonumber(opt("npc_travel_pct")) or 30)) .. "%", stepper = true,
          step = function(dir)
            local n = math.floor((tonumber(opt("npc_travel_pct")) or 30)) + 10 * (dir or 1)
            n = math.max(0, math.min(100, n)); setOpt("npc_travel_pct", n); refreshCurrentMap()
          end,
          onSelect = function()
            local n = math.floor(tonumber(opt("npc_travel_pct")) or 30)
            n = (n >= 100) and 0 or (n + 10); setOpt("npc_travel_pct", n); refreshCurrentMap()
          end },
        { label = "NPC AGENDA", right = ({[0] = "OFF", [1] = "DAY", [2] = "FULL"})[math.floor(tonumber(opt("npc_agenda")) or 0)] or "OFF", stepper = true,
          step = function(dir)
            local n = math.floor(tonumber(opt("npc_agenda")) or 0) + (dir or 1)
            if n < 0 then n = 2 elseif n > 2 then n = 0 end
            setOpt("npc_agenda", n); refreshCurrentMap()
          end,
          onSelect = function()
            local n = math.floor(tonumber(opt("npc_agenda")) or 0) + 1
            if n > 2 then n = 0 end
            setOpt("npc_agenda", n); refreshCurrentMap()
          end },
        { label = "CANCEL", onSelect = function() end },
      }
    end
    local function refreshRights(menu)
      if not menu or not menu.items then return end
      local fresh = rebuildItems()
      for i, it in ipairs(menu.items) do
        if fresh[i] and it.label ~= "CANCEL" then
          it.right = fresh[i].right
          it.value = fresh[i].right
        end
      end
    end
    local items = rebuildItems()
    if mod.ui and mod.ui.ListMenu and mod.ui.ListMenu.new then
      local menuRef = mod.ui.ListMenu.new(g, "JOHTO LIFE", items, {
        onChoose = function(item, m)
          if not item then return end
          if item.label == "CANCEL" then if m and m.close then m:close() end return end
          if item.onSelect then item.onSelect() end
          refreshRights(m)
        end,
      })
      if menuRef and type(menuRef.update) == "function" then
        local baseUp = menuRef.update
        local heldL, heldR = false, false
        menuRef.update = function(self, dt)
          local input = g and g.input
          local idx = self.selected or self.index or 1
          local it = (self.items or items)[idx]
          local left, right = navPressed(input, "left"), navPressed(input, "right")
          if it and it.label ~= "CANCEL" then
            if left and not heldL then
              if it.step then it.step(-1) elseif it.onSelect then it.onSelect() end
              refreshRights(self); heldL, heldR = left, right; return
            elseif right and not heldR then
              if it.step then it.step(1) elseif it.onSelect then it.onSelect() end
              refreshRights(self); heldL, heldR = left, right; return
            end
          end
          heldL, heldR = left, right
          baseUp(self, dt)
        end
      end
      if menuRef and g and g.stack then g.stack:push(menuRef) end
    end
  end

  local function hasLabel(items, label)
    if type(items) ~= "table" then return false end
    for _, it in ipairs(items) do
      if it and (it.label == label or it.id == label) then return true end
    end
    return false
  end
  local function insertOptionsRow(out, row)
    if mod.ui and type(mod.ui.insertBefore) == "function" then
      if hasLabel(out, "MODS") then return mod.ui.insertBefore(out, "MODS", row) or out end
      if hasLabel(out, "CANCEL") then return mod.ui.insertBefore(out, "CANCEL", row) or out end
    end
    out[#out + 1] = row
    return out
  end
  if mod.hooks and mod.hooks.wrap then
    pcall(function()
      mod.hooks:wrap("ui.options.rows", function(next, gameArg, rows)
        local out = next(gameArg, rows)
        if type(out) ~= "table" then return out end
        return insertOptionsRow(out, {
          id = "johto_life:open", label = "JOHTO LIFE",
          text = function() return "OPEN" end,
          value = function() return "OPEN" end,
          activate = function(gg) openJohtoOptions(gg or gameArg) end,
        })
      end)
    end)
  end

  local Overworld = safeRequire("src.world.OverworldController")
  local TextBox = safeRequire("src.render.TextBox")
  local Strings = safeRequire("src.core.Strings")
  local homes = mod.save:get("homes") or {}
  local function saveHomes() mod.save:set("homes", homes) end
  local function key(id) return tostring(id) end
  local function now()
    local ok, t = pcall(os.time)
    return (ok and type(t) == "number") and t or 0
  end
  local COURTESY_MEMORY_STEPS = 1500
  local function steps() return tonumber(mod.save:get("courtesyWalkSteps")) or 0 end
  local function setSteps(n) mod.save:set("courtesyWalkSteps", math.max(0, math.floor(n))) end
  local function markKnown(dest)
    if not dest then return end
    local h = homes[key(dest)] or {}
    h.known, h.knocked = true, nil
    h.knownUntil = steps() + COURTESY_MEMORY_STEPS
    homes[key(dest)] = h; saveHomes()
  end
  local function isKnown(dest)
    local h = homes[key(dest)]
    if not h or not h.known then return false end
    if not h.knownUntil then
      h.knownUntil = steps() + COURTESY_MEMORY_STEPS
      homes[key(dest)] = h; saveHomes()
      return true
    end
    if steps() >= h.knownUntil then
      h.known, h.knownUntil, h.knocked = nil, nil, nil
      homes[key(dest)] = h; saveHomes()
      return false
    end
    return true
  end
  local function resident(mapId)
    if not mapId then return false end
    local id = tostring(mapId):upper()
    return id:find("HOUSE", 1, true) ~= nil or id:find("HOME", 1, true) ~= nil
  end
  local excluded = {
    PLAYERS_HOUSE_1F = true, PLAYERS_HOUSE_2F = true,
    KRISS_HOUSE_1F = true, KRISS_HOUSE_2F = true,
    RIVALS_HOUSE = true, ELMS_HOUSE = true,
  }
  local function isHouseDest(dest)
    return dest and not excluded[dest] and resident(dest)
  end
  local function liveWorld()
    if mod.world and mod.world.overworld then
      local ok, w = pcall(function() return mod.world:overworld() end)
      if ok and w then return w end
    end
    local g = G()
    return g and (g.world or g.overworld) or nil
  end
  local function pushText(world, msg, onDone, opts)
    local g = G()
    if g and g.stack and TextBox and Strings then
      g.stack:push(TextBox.new(g, Strings(msg), onDone, opts))
      return true
    end
    if world and world.showText then world:showText(msg, onDone) return true end
    return false
  end
  local function facingXY(world)
    local p = world and world.player
    if not p then return nil end
    local d = ({ up={0,-1}, down={0,1}, left={-1,0}, right={1,0} })[p.facing] or {0,1}
    return (p.cellX or 0) + d[1], (p.cellY or 0) + d[2]
  end
  local function warpAt(world, x, y)
    if not (world and world.map and x) then return nil end
    local m = world.map
    if m.warpAtCell then return m:warpAtCell(x, y) end
    if m.warpAt then return m:warpAt(x, y) end
    return nil
  end
  local function destOf(w)
    if not w then return nil end
    if type(w) == "string" then return w end
    return w.destMap or w.map
  end
  local pendingTrespass = mod.save:get("pendingTrespass")
  local function clearTrespass(world)
    pendingTrespass = nil; mod.save:set("pendingTrespass", nil)
    if world then world.johtoLifeTrespass = nil end
  end
  local function warpBackTo(world, from)
    if not (from and from.map) then return false end
    local x, y = tonumber(from.x) or 0, tonumber(from.y) or 0
    if world and world.warpToMapId then return world:warpToMapId(from.map, x, y, "down") end
    if Overworld and Overworld.startWarpTo then return Overworld.startWarpTo(from.map, x, y, "down") end
    if world and world.setMap then return world:setMap(from.map, x, y, "down") end
    return false
  end
  local function tryEject(world, toMap)
    if not opt("common_courtesy") then return false end
    world = world or liveWorld()
    local trespass = (world and world.johtoLifeTrespass) or pendingTrespass
    if not trespass or not trespass.home then return false end
    local mapId = toMap or (world and world.map and world.map.id)
    if not mapId or tostring(mapId) ~= tostring(trespass.home) then return false end
    if world and world.johtoLifeResolving then return false end
    if world then world.johtoLifeResolving = true end
    local from = trespass.from or {}
    local function finish()
      warpBackTo(world, from); clearTrespass(world)
      if world then world.johtoLifeResolving = false end
    end
    if not pushText(world, "Please come back\nlater, and KNOCK!", finish) then finish() end
    return true
  end
  local function markTrespass(world, dest, fromMap, fromX, fromY)
    local t = { home = dest, from = { map = fromMap, x = fromX or 0, y = fromY or 0 } }
    pendingTrespass = t; mod.save:set("pendingTrespass", t)
    if world then world.johtoLifeTrespass = t end
  end

  local STORY_SPRITE_NAMES = {
    SPRITE_MOM = "MOM", MOM = "MOM", SPRITE_ELM = "PROF.ELM", ELM = "PROF.ELM",
    SPRITE_NURSE = "NURSE", NURSE = "NURSE", SPRITE_CLERK = "CLERK",
    SPRITE_RECEPTIONIST = "RECEPTIONIST", SPRITE_SILVER = "SILVER",
    SPRITE_OAK = "PROF.OAK", SPRITE_BILL = "BILL", SPRITE_KURT = "KURT",
    SPRITE_FALKNER = "FALKNER", SPRITE_BUGSY = "BUGSY", SPRITE_WHITNEY = "WHITNEY",
    SPRITE_MORTY = "MORTY", SPRITE_CHUCK = "CHUCK", SPRITE_JASMINE = "JASMINE",
    SPRITE_PRYCE = "PRYCE", SPRITE_CLAIR = "CLAIR", SPRITE_WILL = "WILL",
    SPRITE_KOGA = "KOGA", SPRITE_BRUNO = "BRUNO", SPRITE_KAREN = "KAREN",
    SPRITE_LANCE = "LANCE", SPRITE_RED = "RED",
  }
  -- Crystal sprite constants (pret/pokecrystal). POKEFAN_M (0x2d) = chubby male.
  local GENDER_BY_INDEX = {
    [0x0a]="f",[0x0c]="f",[0x0e]="f",[0x0f]="f",[0x13]="f",[0x17]="f",[0x19]="f",
    [0x1b]="f",[0x1d]="f",[0x20]="f",[0x22]="f",[0x24]="f",[0x26]="f",[0x28]="f",
    [0x29]="f",[0x2a]="f",[0x2e]="f",[0x30]="f",[0x32]="f",[0x36]="f",[0x37]="f",
    [0x38]="f",[0x3d]="f",[0x42]="f",[0x58]="f",[0x60]="f",[0x61]="f",
    [0x01]="m",[0x02]="m",[0x03]="m",[0x04]="m",[0x05]="m",[0x06]="m",[0x07]="m",
    [0x08]="m",[0x09]="m",[0x0b]="m",[0x0d]="m",[0x10]="m",[0x11]="m",[0x12]="m",
    [0x14]="m",[0x15]="m",[0x16]="m",[0x18]="m",[0x1a]="m",[0x1c]="m",[0x1e]="m",
    [0x1f]="m",[0x21]="m",[0x23]="m",[0x25]="m",[0x27]="m",[0x2b]="m",[0x2c]="m",
    [0x2d]="m", -- POKEFAN_M overweight male
    [0x2f]="m",[0x31]="m",[0x35]="m",[0x39]="m",[0x3a]="m",[0x3b]="m",[0x3c]="m",
    [0x3e]="m",[0x3f]="m",[0x40]="m",[0x41]="m",[0x43]="m",[0x44]="m",[0x46]="m",
    [0x48]="m",[0x49]="m",[0x4a]="m",[0x4b]="m",[0x62]="m",[0x66]="m",
  }
  local function genderFromNpc(npc)
    if not npc then return "m" end
    local d = npc.def or {}
    local idx = tonumber(d.sprite) or tonumber(npc.spriteId) or tonumber(d.spriteId)
    if not idx and npc.sprite and type(npc.sprite.id) == "number" then idx = npc.sprite.id end
    if idx and GENDER_BY_INDEX[idx] then return GENDER_BY_INDEX[idx] end
    local spr = ""
    if npc.sprite and type(npc.sprite.id) == "string" then spr = npc.sprite.id:upper()
    elseif type(d.sprite) == "string" then spr = d.sprite:upper()
    elseif type(npc.spriteId) == "string" then spr = npc.spriteId:upper()
    end
    if spr ~= "" then
      if spr:find("POKEFAN_M", 1, true) or spr:find("POKEFANM", 1, true) then return "m" end
      if spr:find("POKEFAN_F", 1, true) or spr:find("POKEFANF", 1, true) then return "f" end
      if spr:find("HIKER", 1, true) or spr:find("FISHER", 1, true) then return "m" end
      if spr:find("BLACK_BELT", 1, true) or spr:find("GENTLEMAN", 1, true) then return "m" end
      if spr:find("SAILOR", 1, true) or spr:find("GRAMPS", 1, true) then return "m" end
      if spr:find("OFFICER", 1, true) or spr:find("YOUNGSTER", 1, true) then return "m" end
      if spr:find("BUG_CATCHER", 1, true) or spr:find("SUPER_NERD", 1, true) then return "m" end
      if spr:find("ROCKER", 1, true) or spr:find("SWIMMER_GUY", 1, true) then return "m" end
      if spr:find("BIKER", 1, true) or spr:find("SAGE", 1, true) then return "m" end
      if spr:find("SCIENTIST", 1, true) or spr:find("BOARDER", 1, true) then return "m" end
      if spr:find("LASS", 1, true) or spr:find("BEAUTY", 1, true) then return "f" end
      if spr:find("GRANNY", 1, true) or spr:find("TEACHER", 1, true) then return "f" end
      if spr:find("TWIN", 1, true) or spr:find("NURSE", 1, true) then return "f" end
      if spr:find("SWIMMER_GIRL", 1, true) or spr:find("KIMONO", 1, true) then return "f" end
      if spr:find("SKIER", 1, true) or spr:find("BUENA", 1, true) then return "f" end
      if spr:find("_F$") or spr:find("_F_") or spr:find("GIRL", 1, true) then return "f" end
      if spr:find("_M$") or spr:find("_M_") or spr:find("GUY", 1, true) then return "m" end
    end
    -- Most Crystal outdoor fillers are male when unknown
    return "m"
  end
  local function spriteKeyOf(npc)
    if not npc then return "" end
    local d = npc.def or {}
    if npc.sprite and type(npc.sprite.id) == "string" then return npc.sprite.id:upper() end
    if type(npc.spriteId) == "string" then return npc.spriteId:upper() end
    if type(d.sprite) == "string" then return d.sprite:upper() end
    local idx = tonumber(d.sprite) or tonumber(npc.spriteId)
    if idx then return "SPR_" .. tostring(idx) end
    return ""
  end
  local function stableNameFor(npc)
    local d = npc.def or {}
    local parts = {
      spriteKeyOf(npc),
      tostring(d.index or ""),
      tostring(npc.id or ""),
      tostring(npc.cellX or ""),
      tostring(npc.cellY or ""),
      tostring(npc.mapId or d.mapId or ""),
      tostring(d.name or ""),
      tostring(d.scriptKey or ""),
    }
    local seed = table.concat(parts, ":")
    local h = 2166136261
    for i = 1, #seed do
      h = (h * 16777619 + seed:byte(i)) % 2147483647
    end
    local pool = (genderFromNpc(npc) == "f") and FEMALE_NAMES or MALE_NAMES
    return pool[(h % #pool) + 1]
  end
  local function bodyToString(body)
    if body == nil then return "" end
    if type(body) == "string" then return body end
    if type(body) == "table" and type(body.text) == "string" then return body.text end
    local ok, s = pcall(tostring, body)
    return (ok and s) or ""
  end
  local function textAlreadyNamed(text)
    return type(text) == "string" and text:match("^[%a][%w%s%.%-']*:%s*[\n ]") ~= nil
  end
  local function isAmbientNpc(npc)
    if not npc then return false end
    local d = npc.def or {}
    if d.johtoLifeAmbient then return true end
    local nm = tostring(d.name or npc.id or "")
    if nm:find("JOHTO_NPC_", 1, true) or nm:find("JOHTO_POKE_", 1, true) then return true end
    return false
  end
  local function storyDisplayName(npc)
    if not npc then return nil end
    if isAmbientNpc(npc) then return nil end
    if type(npc.johtoLifeStoryName) == "string" and npc.johtoLifeStoryName ~= "" then
      return npc.johtoLifeStoryName
    end
    local d = npc.def or {}
    if type(d.name) == "string" and #d.name >= 2 and #d.name <= 14
        and d.name:match("^[%a][%a%s%.%-]*$")
        and not d.name:find("JOHTO_", 1, true) then
      npc.johtoLifeStoryName = d.name:upper()
      return npc.johtoLifeStoryName
    end
    local tr = d.trainer
    if type(tr) == "table" then
      if type(tr.name) == "string" and tr.name ~= "" then
        local nm = (type(tr.class) == "string" and tr.class ~= "" and (tr.class .. " " .. tr.name) or tr.name):upper()
        npc.johtoLifeStoryName = nm
        return nm
      end
      if type(tr.class) == "string" and tr.class ~= "" then
        npc.johtoLifeStoryName = tr.class:upper()
        return npc.johtoLifeStoryName
      end
    end
    local spr = spriteKeyOf(npc)
    if STORY_SPRITE_NAMES[spr] then
      npc.johtoLifeStoryName = STORY_SPRITE_NAMES[spr]
      return npc.johtoLifeStoryName
    end
    local sk = tostring(d.scriptKey or "")
    local from = sk:match("([%a]+)Script")
    if from and #from >= 3 and #from <= 12 then
      local u = from:upper()
      if u ~= "OBJECT" and u ~= "STD" and u ~= "GENERIC" and u ~= "ITEM" and u ~= "HIDDEN" then
        npc.johtoLifeStoryName = u
        return u
      end
    end
    local assigned = stableNameFor(npc)
    npc.johtoLifeStoryName = assigned
    return assigned
  end
  local function prefixStoryText(body, name)
    local text = bodyToString(body)
    if text == "" or textAlreadyNamed(text) then return body end
    return name .. ":\n" .. text
  end

  local World2 = safeRequire("src.world.gen2.World")
  if World2 and type(World2.showText) == "function" then
    local baseShowText = World2.showText
    World2.showText = function(self, body, onDone, stay, hold)
      local text = bodyToString(body)
      if textAlreadyNamed(text) then return baseShowText(self, body, onDone, stay, hold) end
      local talker = self and self.talkNpc
      if isAmbientNpc(talker) then return baseShowText(self, body, onDone, stay, hold) end
      local nm = storyDisplayName(talker)
      if nm then body = prefixStoryText(body, nm) end
      return baseShowText(self, body, onDone, stay, hold)
    end
  end
  if TextBox and type(TextBox.new) == "function" then
    local baseTB = TextBox.new
    TextBox.new = function(gameArg, text, onDone, opts)
      local raw = bodyToString(text)
      if textAlreadyNamed(raw) then return baseTB(gameArg, text, onDone, opts) end
      local world = liveWorld()
      local talker = world and world.talkNpc
      if isAmbientNpc(talker) then return baseTB(gameArg, text, onDone, opts) end
      local nm = storyDisplayName(talker)
      if nm then text = prefixStoryText(text, nm) end
      return baseTB(gameArg, text, onDone, opts)
    end
  end

  if mod.events and mod.events.on then
    mod.events:on("player.warped", function(payload)
      payload = payload or {}
      local toMap, fromMap = payload.toMap, payload.fromMap
      if not opt("common_courtesy") then return end
      if not isHouseDest(toMap) or resident(fromMap) then return end
      if isKnown(toMap) then return end
      local h = homes[key(toMap)] or {}
      if h.knocked then return end
      local world = liveWorld()
      local px, py = 0, 0
      if world and world.player then px = world.player.cellX or 0; py = world.player.cellY or 0 end
      markTrespass(world, toMap, fromMap, px, py)
    end)
    local function onMapIn(p)
      local id = p and (p.mapId or p.id)
      if id then spawnAmbient(id); tryEject(liveWorld(), id) end
    end
    mod.events:on("map.ready", onMapIn)
    mod.events:on("map.reloaded", onMapIn)
    mod.events:on("map.entered", onMapIn)
    mod.events:on("mod.options_changed", function(p)
      if not p or p.mod ~= mod.id then return end
      if p.key == "extra_npc_count" then outdoorTouched = true; mod.save:set("outdoorTouched", true) end
      if p.key == "pokemon_npc_count" then pokeTouched = true; mod.save:set("pokeTouched", true) end
      if p.key == "poke_random" then lastPokeRandomMode = nil end
      if johtoRoutines then
        if p.key == "npc_travel_pct" and type(johtoRoutines.setTravelPercent) == "function" then
          johtoRoutines.setTravelPercent(p.value)
        elseif p.key == "npc_routines" and type(johtoRoutines.setEnabled) == "function" then
          johtoRoutines.setEnabled(p.value and true or false)
        elseif p.key == "npc_agenda" and type(johtoRoutines.setAgenda) == "function" then
          johtoRoutines.setAgenda(p.value)
        end
        local ow = mod.world and mod.world:overworld()
        if ow and type(johtoRoutines.update) == "function" then
          johtoRoutines.update(ow, 0, true)
        end
      end
      refreshCurrentMap()
    end)
  end

  johtoSleepTick = function(world)
    -- Pass 2 of double cache clear: runs on first tick after mod load.
    if SleepAssets and SleepAssets._johtoLifeSleepCacheClearPending then
      SleepAssets._johtoLifeSleepCacheClearPending = nil
      if SleepAssets._johtoLifeSleepImages then
        for k in pairs(SleepAssets._johtoLifeSleepImages) do
          SleepAssets._johtoLifeSleepImages[k] = nil
        end
      end
      SleepAssets._johtoLifeSleepCacheVersion = 2
    end
    if not world or not opt("sleeping_npcs") then return end
    local function safe(npc)
      local map = world.map
      if not map or not npc then return false end
      local x, y = npc.cellX, npc.cellY
      if x == nil or y == nil then return false end
      for _, w in ipairs(map.warps or (map.def and map.def.warps) or {}) do
        local wx, wy = tonumber(w.x), tonumber(w.y)
        if wx and wy and math.abs(wx-x) <= 1 and math.abs(wy-y) <= 1 then return false end
      end
      if type(map.isDoorTileCell) == "function" then
        local ok, door = pcall(map.isDoorTileCell, map, x, y)
        if ok and door then return false end
      end
      if type(map.isWalkableCell) == "function" then
        local ok, walk = pcall(map.isWalkableCell, map, x, y)
        if not ok or not walk then return false end
      end
      return true
    end
    local pct = math.floor(tonumber(opt("sleep_pct")) or 10)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    local isNight = false
    if type(world.timeOfDay) == "function" then
      local ok, tod = pcall(function() return world:timeOfDay() end)
      local t = ok and tostring(tod):upper() or ""
      isNight = t == "NIGHT" or t == "NITE" or t == "MIDNIGHT"
    end
    local candidates = {}
    for _, npc in ipairs(world.npcs or {}) do
      local d = npc.def or {}
      if d.johtoLifeAmbient and not d.johtoLifePokemon and safe(npc) then
        local id = tostring(npc.id or d.name or "")
        local h = 0; for i = 1, #id do h = (h + id:byte(i) * i) % 10000 end
        if isNight or (opt("day_sleepers") and (h % 10) < 3) then
          candidates[#candidates + 1] = { npc = npc, hash = h }
        end
      end
    end
    table.sort(candidates, function(a,b)
      if a.hash == b.hash then return tostring(a.npc.id) < tostring(b.npc.id) end
      return a.hash < b.hash
    end)
    local want = math.ceil(#candidates * pct / 100)
    if pct > 0 and #candidates > 0 and want < 1 then want = 1 end
    if pct >= 100 then want = #candidates end
    local chosen = {}
    for i = 1, want do chosen[candidates[i].npc] = true end
    for _, npc in ipairs(world.npcs or {}) do
      local d = npc.def or {}
      if d.johtoLifeAmbient and not d.johtoLifePokemon then
        if chosen[npc] then
          if not npc.nightlifeSleeping then
            npc.frozen = true; npc.nightlifeSleeping = true
            if npc.facing ~= nil and npc.johtoLifeSleepFacing == nil then npc.johtoLifeSleepFacing = npc.facing end
            local sign = ((npc.cellX or 0) + (npc.cellY or 0)) % 2 == 0 and 1 or -1
            npc.johtoLifeSleepAngle = sign * (math.pi / 2); npc.johtoLifeSleepSide = sign
            -- Pre-1.4.0: no bake. The bake (added in 1.4.0) produced blank sprites.
            -- pcall(bakeRotatedSleepSprite, npc)
            pcall(function() if type(npc.face) == "function" then npc:face(sign > 0 and "LEFT" or "RIGHT") else npc.facing = sign > 0 and "LEFT" or "RIGHT" end end)
          end
        elseif npc.nightlifeSleeping then
          npc.frozen = false; npc.nightlifeSleeping = nil; npc.johtoLifeSleepAngle = nil
          pcall(restoreRotatedSleepSprite, npc)
          if npc.johtoLifeSleepFacing ~= nil then
            pcall(function() if type(npc.face) == "function" then npc:face(npc.johtoLifeSleepFacing) else npc.facing = npc.johtoLifeSleepFacing end end)
            npc.johtoLifeSleepFacing = nil
          end
        end
      end
    end
  end

  if Overworld then
    local baseInteract = Overworld.interact
    Overworld.interact = function(world)
      if opt("common_courtesy") and world and world.player and world.map then
        local x, y = facingXY(world)
        local at = warpAt(world, x, y)
        if at then
          local def = at.def or at
          local dest = destOf(def)
          if isHouseDest(dest) and not resident(world.map.id) and not isKnown(dest) then
            pushText(world, "KNOCK before\nentering?", nil, {
              choice = function(yes)
                local h = homes[key(dest)] or {}
                if yes then
                  h.knocked = true; homes[key(dest)] = h; saveHomes()
                  clearTrespass(world)
                  pushText(world, "KNOCK! KNOCK!\nCome in!", function()
                    world.johtoLifeWelcome = dest
                    if world.takeWarp then world:takeWarp(def)
                    elseif Overworld.takeWarp then Overworld.takeWarp(def) end
                  end)
                else homes[key(dest)] = h; saveHomes() end
              end
            })
            return true
          end
        end
      end
      if type(baseInteract) == "function" then return baseInteract(world) end
      if world and world.interactBody then return world:interactBody() end
    end

    if World2 and type(World2.takeWarp) == "function" then
      local baseWorldWarp = World2.takeWarp
      World2.takeWarp = function(self, warpDef)
        if opt("common_courtesy") and self and self.map and self.player and warpDef then
          local dest = destOf(warpDef)
          if isHouseDest(dest) and not resident(self.map.id) then
            local h = homes[key(dest)] or {}
            if not isKnown(dest) and not h.knocked and (h.lockedUntil or 0) > now() then
              pushText(self, "Please try again\nin 5 minutes."); return false
            end
            if not isKnown(dest) and not h.knocked then
              markTrespass(self, dest, self.map.id, self.player.cellX, self.player.cellY)
            end
          end
        end
        return baseWorldWarp(self, warpDef)
      end
    end
    if World2 and type(World2.step) == "function" then
      local baseStep = World2.step
      World2.step = function(self, ...)
        local r = baseStep(self, ...)
        if self and self.map then tryEject(self, self.map.id) end
        return r
      end
    end

    local baseUpdate = Overworld.update
    local lastCell = { map = nil, x = nil, y = nil }
    Overworld.update = function(world, dt)
      if type(baseUpdate) == "function" then pcall(baseUpdate, world, dt) end
      if not world then return end
      local p = world.player
      if p and world.map then
        local mid = world.map.id
        if lastCell.map ~= mid then lastCell.map, lastCell.x, lastCell.y = mid, p.cellX, p.cellY
        elseif lastCell.x ~= p.cellX or lastCell.y ~= p.cellY then
          lastCell.x, lastCell.y = p.cellX, p.cellY; setSteps(steps() + 1)
        end
      end
      tryEject(world, world.map and world.map.id)
      if world.johtoLifeWelcome and world.map and world.map.id == world.johtoLifeWelcome then
        local w = world.johtoLifeWelcome; world.johtoLifeWelcome = nil
        markKnown(w); pushText(world, "Welcome! Thank you\nfor knocking.")
      end
      for _, npc in ipairs(world.npcs or {}) do
        local d = npc.def or {}
        if d.johtoLifeAmbient and not npc.nightlifeSleeping then
          npc.frozen = false
          if npc.kind == "stand" or npc.kind == nil then
            npc.kind = "walk"
            npc.roamDirs = npc.roamDirs or { "up", "down", "left", "right" }
            if (npc.radiusX or 0) == 0 then npc.radiusX = 3 end
            if (npc.radiusY or 0) == 0 then npc.radiusY = 3 end
            npc.homeX = npc.homeX or npc.cellX
            npc.homeY = npc.homeY or npc.cellY
          end
        end
      end
      local function sleepSafeCell(world, npc)
        local map = world and world.map
        if not map or not npc then return false end
        local x, y = npc.cellX, npc.cellY
        if x == nil or y == nil then return false end
        -- Never place a sleeper on a Gold warp/door cell, or immediately on
        -- the doorway approach cells. This also prevents a routine actor that
        -- has just reached a door from becoming a sleeper there.
        for _, w in ipairs(map.warps or (map.def and map.def.warps) or {}) do
          local wx, wy = tonumber(w.x), tonumber(w.y)
          if wx and wy and math.abs(wx-x) <= 1 and math.abs(wy-y) <= 1 then return false end
        end
        if type(map.isDoorTileCell) == "function" then
          local ok, door = pcall(map.isDoorTileCell, map, x, y)
          if ok and door then return false end
        end
        if type(map.isWalkableCell) == "function" then
          local ok, walk = pcall(map.isWalkableCell, map, x, y)
          if not ok or not walk then return false end
        end
        return true
      end

      if opt("sleeping_npcs") then
        local pct = math.floor(tonumber(opt("sleep_pct")) or 10)
        if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
        local isNight = false
        if type(world.timeOfDay) == "function" then
          local ok, tod = pcall(function() return world:timeOfDay() end)
          local t = ok and tostring(tod):upper() or ""
          isNight = t == "NIGHT" or t == "NITE" or t == "MIDNIGHT"
        end

        local candidates = {}
        for _, npc in ipairs(world.npcs or {}) do
          local d = npc.def or {}
          if d.johtoLifeAmbient and not d.johtoLifePokemon and sleepSafeCell(world, npc) then
            local id = tostring(npc.id or d.name or "")
            local h = 0
            for i = 1, #id do h = (h + id:byte(i) * i) % 10000 end
            local dayEligible = isNight or (opt("day_sleepers") and ((h % 10) < 3))
            if dayEligible then candidates[#candidates + 1] = { npc = npc, hash = h } end
          end
        end
        table.sort(candidates, function(a,b)
          if a.hash == b.hash then return tostring(a.npc.id) < tostring(b.npc.id) end
          return a.hash < b.hash
        end)
        local want = math.ceil(#candidates * pct / 100)
        if pct > 0 and #candidates > 0 and want < 1 then want = 1 end
        if pct >= 100 then want = #candidates end
        local chosen = {}
        for i = 1, want do chosen[candidates[i].npc] = true end

        for _, npc in ipairs(world.npcs or {}) do
          local d = npc.def or {}
          if d.johtoLifeAmbient and not d.johtoLifePokemon then
            if chosen[npc] then
              if not npc.nightlifeSleeping then
                npc.moving = false; npc.targetX = nil; npc.targetY = nil; npc.progress = 0; npc.spriteYOffset = 0
                npc.frozen = true
                npc.nightlifeSleeping = true
                if npc.facing ~= nil and npc.johtoLifeSleepFacing == nil then npc.johtoLifeSleepFacing = npc.facing end
                local sign = ((npc.cellX or 0) + (npc.cellY or 0)) % 2 == 0 and 1 or -1
                npc.johtoLifeSleepAngle = sign * (math.pi / 2)
                npc.johtoLifeSleepSide = sign
                -- Pre-1.4.0: no bake.
                -- pcall(bakeRotatedSleepSprite, npc)
                local faceDir = (sign > 0) and "LEFT" or "RIGHT"
                pcall(function() if type(npc.face) == "function" then npc:face(faceDir) else npc.facing = faceDir end end)
              end
            elseif npc.nightlifeSleeping then
              npc.frozen = false
              npc.nightlifeSleeping = nil
              npc.johtoLifeSleepAngle = nil
              pcall(restoreRotatedSleepSprite, npc)
              if npc.johtoLifeSleepFacing ~= nil then
                pcall(function() if type(npc.face) == "function" then npc:face(npc.johtoLifeSleepFacing) else npc.facing = npc.johtoLifeSleepFacing end end)
                npc.johtoLifeSleepFacing = nil
              end
            end
          end
        end
      end
      if johtoRoutines and type(johtoRoutines.update) == "function" then
        johtoRoutines.update(world, dt or 0, false)
      end
      if world.map and (isTown(world.map.id) or isRoute(world.map.id) or isIndoor(world.map.id)) then
        if #liveAmbient(world, false) ~= humanTarget(world.map.id)
            or #liveAmbient(world, true) ~= pokeTarget(world.map.id, world.map) then
          spawnAmbient(world.map.id)
        end
      end
    end

    -- Progressive dialogue + 5th-interaction events (same as Kanto Life 0.8.26)
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
      "ELECTABUZZ", "MAGMAR", "PORYGON", "DRATINI", "DRAGONAIR", "GYARADOS",
      "TOGEPI", "MAREEP", "ESPEON", "UMBREON", "MURKROW", "MISDREAVUS", "SKARMORY",
      "PHANPY", "DONPHAN", "STANTLER", "SMEARGLE", "MILTANK", "LARVITAR", "PUPITAR",
    }

    local function talkStateKey(npc)
      local d = npc and (npc.def or {}) or {}
      local mapId = npc.mapId or ""
      local nm = d.name or npc.id or d.johtoLifeDisplayName or "npc"
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
      local ok, Bag = pcall(require, "src.inventory.Bag")
      if ok and Bag and type(Bag.add) == "function" and g and g.save and g.data then
        local ok2, res = pcall(Bag.add, g.save, resolved, count, g.data)
        if ok2 and res then return true, resolved end
        if resolved ~= itemId then
          ok2, res = pcall(Bag.add, g.save, itemId, count, g.data)
          if ok2 and res then return true, itemId end
        end
      end
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
      local okP, Pokemon = pcall(require, "src.pokemon.Pokemon")
      local okA, Party = pcall(require, "src.pokemon.Party")
      if not (okP and Pokemon and Pokemon.new and g and g.data and g.save) then return false end
      local ok, mon = pcall(Pokemon.new, g.data, species, level)
      if not ok or not mon then return false end
      if okA and Party and type(Party.add) == "function" then
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


    local function pushBattle(g, battle)
      if not battle then return false end
      if g.stack and type(g.stack.push) == "function" then
        pcall(function() g.stack:push(battle) end); return true
      end
      if g.state and type(g.state.push) == "function" then
        pcall(function() g.state:push(battle) end); return true
      end
      return false
    end
    local function getLiveWorld()
      local w = liveWorld and liveWorld() or nil
      if w then return w end
      local g = G and G() or nil
      if g then return g.world or g.overworld end
      return nil
    end

    local function resolveGameWorld()
      local world = getLiveWorld()
      local g = G and G() or nil
      if world and world.game then g = world.game end
      if (not g) and world and world.save then
        g = { data = world.game and world.game.data, save = world.save, stack = world.game and world.game.stack }
      end
      return g, world
    end

    local function partyArray(g)
      local out = {}
      if not (g and g.save) then return out end
      local party = g.save.party
      if type(party) ~= "table" then return out end
      if type(party.mons) == "table" then party = party.mons end
      for i = 1, 6 do
        local mon = party[i]
        if type(mon) == "table" and (mon.species or mon.id or mon.name) then
          out[#out + 1] = mon
        end
      end
      if #out == 0 then
        for _, mon in pairs(party) do
          if type(mon) == "table" and (mon.species or mon.id or mon.name) then
            out[#out + 1] = mon
          end
        end
      end
      return out
    end

    local function makeEnemyMon(g, species, level)
      local okM, Mon = pcall(require, "src.battle.gen2.Mon")
      if not (okM and Mon and Mon.new and g and g.data) then return nil end
      level = math.max(2, math.min(100, math.floor(tonumber(level) or 10)))
      if sanitizeSpecies then species = sanitizeSpecies(species) end
      local tries = { species, "PIDGEY", "RATTATA", "SENTRET", "HOOTHOOT" }
      for _, sp in ipairs(tries) do
        if type(sp) == "string" and sp ~= "" then
          local mon = Mon.new(g.data, sp, level)
          if mon then
            mon.shiny = false
            if mon.hp == nil and mon.stats and mon.stats.hp then mon.hp = mon.stats.hp end
            return mon
          end
        end
      end
      return nil
    end

    local function pushGen2Battle(g, world, battleOpts, onDone)
      -- Prefer World:startBattle (music + transition + Gen2BattleState)
      if world and type(world.startBattle) == "function" then
        local ok, err = pcall(function()
          world:startBattle(battleOpts, onDone)
        end)
        if ok then return true end
      end
      local okS, Screens = pcall(require, "src.ui.Screens")
      local okB, Battle = pcall(require, "src.battle.gen2.Battle")
      if not (okS and Screens and Screens.push and okB and Battle and Battle.new and g) then
        return false
      end
      local battle = Battle.new({
        data = g.data,
        party = battleOpts.party or partyArray(g),
        wild = battleOpts.wild,
        trainer = battleOpts.trainer,
        save = g.save,
      })
      if not battle then return false end
      -- Ensure sides exist when possible
      if not battle.enemy and battleOpts.wild then
        battle.enemy = battleOpts.wild
        battle.enemyParty = { battleOpts.wild }
        battle.wild = true
      end
      if not battle.enemy and battleOpts.trainer and battleOpts.trainer.party then
        battle.enemyParty = battleOpts.trainer.party
        battle.enemy = battleOpts.trainer.party[1]
        battle.wild = false
      end
      if not battle.player then
        local pa = battleOpts.party or partyArray(g)
        battle.party = pa
        battle.player = pa[1]
        battle.playerIndex = 1
      end
      if not (battle.player and battle.enemy) then return false end
      pcall(function()
        Screens.push(g, "Gen2BattleState", {
          battle = battle,
          save = g.save,
          onDone = onDone,
        })
      end)
      return true
    end

    local function snapshotPartyHp(g)
      local list = partyArray(g)
      local snap = {}
      for i, mon in ipairs(list) do
        if type(mon) == "table" then
          snap[i] = { hp = mon.hp, status = mon.status, sleep = mon.sleep, toxic = mon.toxic }
        end
      end
      return snap
    end

    local function restorePartyHp(g, snap)
      if not snap then return end
      local list = partyArray(g)
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

    local function afterBattleDialogue(world, display, isPoke, result)
      result = tostring(result or "run")
      local name = display or (isPoke and "POKEMON" or "TRAINER")
      if result == "win" then
        if isPoke then
          pushText(world, name .. ":\n" .. name .. "!\n(It looks tired...)")
        else
          local lines = {
            "You're really strong!",
            "I can't believe I lost...",
            "Wow! What a battle!",
            "I'll train harder!",
          }
          pushText(world, name .. ":\n" .. lines[love.math.random(1, #lines)])
        end
      elseif result == "lose" then
        if isPoke then
          pushText(world, name .. ":\n" .. name .. "!\n(It looks proud!)")
        else
          local lines = {
            "Ha! I won!",
            "Better luck next time!",
            "My team was stronger!",
            "Come back when you're ready!",
          }
          pushText(world, name .. ":\n" .. lines[love.math.random(1, #lines)])
        end
      elseif result == "caught" then
        pushText(world, "Gotcha!\n" .. name .. " was caught!")
      end
    end

    local function startWildBattle(g, species, level, ctx)
      level = math.max(2, math.min(100, math.floor(tonumber(level) or 5)))
      local world
      g, world = resolveGameWorld()
      if not g then return false end
      ctx = ctx or {}
      if ctx.world then world = ctx.world end
      local party = partyArray(g)
      if #party < 1 then return false end
      local mon = makeEnemyMon(g, species, level)
      if not mon then return false end
      local snap = snapshotPartyHp(g)
      local display = ctx.display or (type(species) == "string" and species:gsub("_", " ") or "POKEMON")
      local function onDone(result)
        if result == "lose" then restorePartyHp(g, snap) end
        afterBattleDialogue(world, display, true, result)
      end
      return pushGen2Battle(g, world, { wild = mon, party = party }, onDone)
    end

    local function startTrainerBattle(g, partySlots, trainerName, npc, ctx)
      local world
      g, world = resolveGameWorld()
      if not g then return false end
      ctx = ctx or {}
      if ctx.world then world = ctx.world end
      trainerName = trainerName or "TRAINER"
      local party = partyArray(g)
      if #party < 1 then return false end

      local enemyParty = {}
      for _, slot in ipairs(partySlots or {}) do
        local mon = makeEnemyMon(g, slot.species, slot.level or 10)
        if mon then enemyParty[#enemyParty + 1] = mon end
      end
      if #enemyParty == 0 then
        local mon = makeEnemyMon(g, "PIDGEY", 10)
        if mon then enemyParty[1] = mon end
      end
      if #enemyParty == 0 then return false end

      local classId = "YOUNGSTER"
      local d = npc and (npc.def or npc) or {}
      local spr = tostring(d.sprite or d.spriteId or ""):upper()
      if spr:find("LASS", 1, true) then classId = "LASS"
      elseif spr:find("BEAUTY", 1, true) then classId = "BEAUTY"
      elseif spr:find("FISHER", 1, true) then classId = "FISHER"
      elseif spr:find("HIKER", 1, true) then classId = "HIKER"
      elseif spr:find("BUG", 1, true) then classId = "BUG_CATCHER"
      elseif spr:find("SCHOOL", 1, true) then classId = "SCHOOLBOY"
      end

      local trainer = {
        classId = classId,
        class = classId,
        memberId = 1,
        index = 1,
        name = trainerName,
        trainerName = trainerName,
        className = "TRAINER",
        party = enemyParty,
        baseMoney = 40,
      }

      local snap = snapshotPartyHp(g)
      local function onDone(result)
        if result == "lose" then restorePartyHp(g, snap) end
        afterBattleDialogue(world, trainerName, false, result)
      end
      return pushGen2Battle(g, world, { trainer = trainer, party = party }, onDone)
    end

    local function isPlainSpecies(sp)
      if type(sp) ~= "string" or sp == "" then return false end
      sp = sp:upper():gsub(" ", "_")
      local banned = {
        "SHINY", "CINDER", "GALAR", "ALOLA", "HISUI", "PALDEA", "MEGA", "PRIMAL",
        "SPECIAL", "FORM", "COSTUME", "ASH_", "SHADOW", "DARK_", "LIGHT_",
        "CRYSTAL_", "SPIRIT_", "GHOST_", "COSMETIC", "ALT_", "VARIANT",
      }
      for _, b in ipairs(banned) do
        if sp:find(b, 1, true) then return false end
      end
      local g = G and G() or nil
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
        "PIDGEY", "RATTATA", "SENTRET", "HOOTHOOT", "LEDYBA", "SPINARAK", "ZUBAT",
        "MAREEP", "HOPPIP", "SUNKERN", "WOOPER", "MURKROW", "MISDREAVUS", "GIRAFARIG",
        "PINECO", "DUNSPARCE", "GLIGAR", "SNUBBULL", "QWILFISH", "SHUCKLE", "HERACROSS",
        "SNEASEL", "TEDDIURSA", "SLUGMA", "SWINUB", "CORSOLA", "REMORAID", "DELIBIRD",
        "MANTINE", "SKARMORY", "HOUNDOUR", "PHANPY", "STANTLER", "SMEARGLE", "MILTANK",
        "LARVITAR", "SPEAROW", "EKANS", "SANDSHREW", "CLEFAIRY", "VULPIX", "JIGGLYPUFF",
        "ODDISH", "PARAS", "VENONAT", "DIGLETT", "MEOWTH", "PSYDUCK", "MANKEY",
        "GROWLITHE", "POLIWAG", "ABRA", "MACHOP", "BELLSPROUT", "TENTACOOL", "GEODUDE",
        "PONYTA", "SLOWPOKE", "MAGNEMITE", "FARFETCHD", "DODUO", "SEEL", "GRIMER",
        "SHELLDER", "GASTLY", "ONIX", "DROWZEE", "KRABBY", "VOLTORB", "EXEGGCUTE",
        "CUBONE", "KOFFING", "RHYHORN", "CHANSEY", "TANGELA", "HORSEA", "GOLDEEN",
        "STARYU", "MAGIKARP", "EEVEE", "DRATINI",
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
      local maxLv, count = playerPartyInfo(g)
      count = math.max(1, math.min(6, count > 0 and count or 1))
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

    
    local function beginInteractiveTrade(world, npc, st, key, all, isPoke, display, rare)
      local g = G()
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
        if msg then pushText(world, msg) end
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
        local okP, Pokemon = pcall(require, "src.pokemon.Pokemon")
        local okS, Screens = pcall(require, "src.ui.Screens")
        if not (okP and Pokemon and Pokemon.new and g.data) then
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
          pushText(world, display .. ":\nTrade complete!\nYou got " .. nice .. "!")
        end
        if okS and Screens and type(Screens.push) == "function" then
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
        local okS, Screens = pcall(require, "src.ui.Screens")
        if not (okS and Screens and type(Screens.push) == "function") then
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

      pushText(world, askMsg, nil, {
        choice = function(yes)
          if yes then
            openParty()
          else
            scheduleRetry(display .. ":\nOkay, maybe later!")
          end
        end,
      })
    end

local function runFifthEvent(world, npc, st, key, all, isPoke, display, species, forceKind)
      local g = G()
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
          if given then
            pushText(world, display .. ":\n" .. display .. "!\n(Received " .. nice .. "!)")
          else
            pushText(world, display .. ":\n" .. display .. "!\n(Wanted to give\n" .. nice .. "...)")
          end
        else
          if given then
            pushText(world, display .. ":\nHere, take this\n" .. nice .. "!")
          else
            pushText(world, display .. ":\nI'd give you a\n" .. nice .. ", but your\nbag is full!")
          end
        end
        return true
      elseif kind == "trade" then
        local rare = st.eventDetail or pickRandomSpecies(true)
        if type(rare) ~= "string" or rare == "" then rare = pickRandomSpecies(true) end
        if sanitizeSpecies then rare = sanitizeSpecies(rare) end
        if npc.def then npc.def.johtoLifeTradeMon = rare end
        beginInteractiveTrade(world, npc, st, key, all, isPoke, display, rare)
        return true
      else
        local maxLv = playerPartyInfo(g)
        local lv = enemyLevelFor(maxLv)
        st.pendingTrade = nil
        if isPoke then
          local foe = species or pickRandomSpecies(false)
          st.event, st.eventDetail = "battle", foe
          putTalkState(key, st, all)
          local started = startWildBattle(g, foe, lv, { world = world, display = display })
          if not started then
            pushText(world, display .. ":\n" .. display .. "!\n(Couldn't start\nthe battle...)")
          else
            pushText(world, display .. ":\n" .. display .. "!\n(Battle! Lv" .. tostring(lv) .. "\nYou can catch it!)")
          end
          return true
        else
          local party = buildEnemyParty(g)
          st.event, st.eventDetail = "battle", "trainer"
          putTalkState(key, st, all)
          local started = startTrainerBattle(g, party, display, npc, { world = world })
          if not started then
            -- Johto may lack trainer path; still never use catchable wild for humans
            pushText(world, display .. ":\nI wanted to battle,\nbut something went wrong!")
          else
            pushText(world, display .. ":\nHow about a battle?\nMy team is ready!")
          end
          return true
        end
      end
    end

        local function progressiveAmbientTalk(world, npc, isPoke)
      local d = npc.def or {}
      local st, key, all = getTalkState(npc)
      st.count = (tonumber(st.count) or 0) + 1
      putTalkState(key, st, all)

      local display, species
      if isPoke then
        species = d.johtoLifeMon or d.johtoLifeDisplayName or "POKEMON"
        if type(species) == "string" then species = species:upper() end
        display = species
      else
        display = d.johtoLifeDisplayName or "Someone"
      end

      if (not isPoke) and st.pendingTrade and not st.event and st.retryAt and st.count >= st.retryAt then
        return runFifthEvent(world, npc, st, key, all, false, display, nil, "trade")
      end
      if st.count == 5 and not st.event then
        return runFifthEvent(world, npc, st, key, all, isPoke, display, species, nil)
      end

      if isPoke then
        local ref = eventRefLine(st, true)
        if ref and love.math.random() < 0.55 then
          pushText(world, display .. ":\n" .. ref)
        else
          local fmt = POKE_CRY_LINES[love.math.random(#POKE_CRY_LINES)]
          pushText(world, display .. ":\n" .. fmt:format(species, species))
        end
        return true
      end

      local name = tostring(d.name or "")
      local pool = name:find("ROUTE", 1, true) and routeLines or lines; --[[ Per-NPC dialogue history: skip last 5 lines per NPC per pool; resets when all used. ]] local rh = st.recentLines; if type(rh) ~= "table" then rh = {}; st.recentLines = rh end; local rk = (name:find("ROUTE", 1, true) and "route" or "town"); local hst = rh[rk]; if type(hst) ~= "table" then hst = {}; rh[rk] = hst end; local avail = {}; for i = 1, #pool do local used = false; for _, v in ipairs(hst) do if v == i then used = true; break end end; if not used then avail[#avail + 1] = i end end; if #avail == 0 then hst = {}; rh[rk] = hst; for i = 1, #pool do avail[i] = i end end; local pi = avail[love.math.random(1, #avail)]; hst[#hst + 1] = pi; while #hst > 5 do table.remove(hst, 1) end; putTalkState(key, st, all)
      local text = pool[pi]
      local ref = eventRefLine(st, false)
      if ref and st.count > 5 and love.math.random() < 0.5 then
        text = ref
      end
      pushText(world, display .. ":\n" .. text)
      return true
    end

    local baseTalk = Overworld.talkTo
    Overworld.talkTo = function(world, npc)
      local d = npc and npc.def
      if d and d.johtoLifeAmbient then
        local display = d.johtoLifeDisplayName or "Someone"
        if npc.nightlifeSleeping then
          pushText(world, display .. " is fast\nasleep."); return true
        end
        if d.johtoLifePokemon then
          return progressiveAmbientTalk(world, npc, true)
        end
        return progressiveAmbientTalk(world, npc, false)
      end
      if type(baseTalk) == "function" then return baseTalk(world, npc) end
      return false
    end
  else
    mod.log:warn("Johto Life: Overworld facade missing")
  end


    
    local function sleepZzzSeed(npc)
      local x = tonumber(npc and (npc.cellX or npc.x)) or 0
      local y = tonumber(npc and (npc.cellY or npc.y)) or 0
      return math.floor(x * 17 + y * 31) % 1000
    end

    -- Plain floating Zzz only (no speech bubble). Coords = current graphics space.
    local function drawSleepZzz(sx, sy, seed)
      local v = opt("sleep_bubbles")
      if v == false then return end
      seed = seed or 0
      local side = (seed % 2 == 0) and -1 or 1
      local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
      love.graphics.push("all")
      for i = 0, 2 do
        local phase = t * 1.5 + i * 0.75 + seed * 0.05
        local cycle = phase % 2.5
        local rise = cycle * 4
        local alpha = 1 - cycle / 2.5
        if alpha > 0.25 then
          local sc = 0.7 + i * 0.2
          local zx = sx + side * (3 + i * 3)
          local zy = sy - 6 - rise - i * 2
          -- outline
          love.graphics.setColor(1, 1, 1, alpha)
          love.graphics.print("Z", zx - 1, zy, 0, sc, sc)
          love.graphics.print("Z", zx + 1, zy, 0, sc, sc)
          love.graphics.print("Z", zx, zy - 1, 0, sc, sc)
          love.graphics.print("Z", zx, zy + 1, 0, sc, sc)
          love.graphics.setColor(0.1, 0.05, 0.3, alpha)
          love.graphics.print("Z", zx, zy, 0, sc, sc)
        end
      end
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.pop()
    end



    -- Gen2 sleep visuals: baseDraw always (voxel-safe); Zzz after; 2D side-lie when possible
    
function isVoxelPresentation()
      -- Any Battle Art / Dramatic Shape voxel level other than OFF
      local names = {
        "DRAMATIC_SHAPE", "DRAMALESS_SHAPE", "BATTLE_ART_VOXEL", "BATTLE_ART_VOXEL_FORK",
        "battle_art_voxel", "BattleArtVoxel", "POTATO_VOXEL", "PotatoVoxel",
      }
      if type(mod.find) == "function" then
        for _, id in ipairs(names) do
          local ok, m = pcall(mod.find, id)
          if ok and m and m.options and type(m.options.get) == "function" then
            for _, key in ipairs({ "voxel", "VOXEL", "voxels", "mode" }) do
              local v = m.options:get(key)
              if v ~= nil and v ~= false and v ~= "OFF" and v ~= "off" and v ~= 0 then
                return true
              end
            end
          end
        end
      end
      return false
    end

    local function sleepAccessoryImage(style) return sleepPropImage(style) end
      -- Resolve sleep style, handling Random (4) by assigning a stable per-NPC random 0-3
  local function resolveSleepStyle(npc)
    local style = math.floor(tonumber(opt("sleep_style")) or 0)
    if style ~= 4 then return style end
    local cached = npc.kantoLifeRandomSleepStyle
    if cached == nil then
      cached = math.random(0, 3)
      npc.kantoLifeRandomSleepStyle = cached
    end
    return cached
  end
    local function drawSleepAccessory(self, ox, oy, scale)
      local style = resolveSleepStyle(self)
      if style == 0 then return end
      local img = sleepAccessoryImage(style); if not img then return end
      local iw, ih = img:getDimensions()
      local px = (self.cellX ~= nil) and (self.cellX * 16) or (self.px or self.x or 0)
      local py = (self.cellY ~= nil) and (self.cellY * 16) or (self.py or self.y or 0)
      local angle = self.johtoLifeSleepAngle or (math.pi/2)
      local s = scale or 1
      love.graphics.push("all")
      -- Match the transform order used by drawZzzForNpc: translate by camera
      -- offset, apply scale, then position in world coordinates. The old code
      -- added (ox+px) before scaling, which placed props at wrong positions
      -- whenever scale ~= 1 and offset them even at scale == 1.
      love.graphics.translate(ox or 0, oy or 0)
      love.graphics.scale(s, s)
      local shiftX = style == 1 and 0 or (-math.sin(angle) * 6.5)
      love.graphics.translate(px + 8 + shiftX, py + 8)
      if style == 2 or style == 3 then love.graphics.rotate(angle) end
      love.graphics.translate(-iw/2,-ih)
      love.graphics.draw(img,0,0)
      love.graphics.pop()
    end
local function drawSleepTentOverlay(self, ox, oy, scale) return end
    local function drawCollisionBubble(self, ox, oy, scale)
      if opt("npc_collision_bubbles") == false then return end
      local untilAt = tonumber(self and self._kantoLifeCollisionBubbleUntil) or 0
      local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
      if untilAt <= now then return end
      local text = tostring(self._kantoLifeCollisionBubbleText or ":)")
      local G = love.graphics
      G.push("all")
      if scale and scale ~= 1 then G.scale(scale,scale) end
      local px = (self.cellX ~= nil) and (self.cellX * 16) or (self.px or self.x or 0)
      local py = (self.cellY ~= nil) and (self.cellY * 16) or (self.py or self.y or 0)
      local font = G.getFont()
      local tw, th = font:getWidth(text), font:getHeight()
      local w, h = math.max(22, tw + 10), math.max(13, th + 5)
      local x = px - (ox or 0) + 8 - w/2
      local y = py - (oy or 0) - h - 4
      G.setColor(1,1,1,1); G.rectangle("fill",x,y,w,h,2,2)
      G.setColor(0.1,0.1,0.1,1); G.rectangle("line",x,y,w,h,2,2)
      G.polygon("fill",x+w/2-2,y+h,x+w/2+2,y+h,x+w/2,y+h+3)
      G.setColor(0.1,0.1,0.1,1)
      G.print(text, px - (ox or 0) + 8 - tw/2, y + (h-th)/2)
      G.pop()
    end

    local function drawZzzForNpc(self, ox, oy, scale)
      if not self or not self.nightlifeSleeping then return end
      local v = opt("sleep_bubbles")
      if v == false then return end
      local px = (self.cellX ~= nil) and (self.cellX * 16) or (self.px or self.x or 0) or 0
      local py = (self.cellY ~= nil) and (self.cellY * 16) or (self.py or self.y or 0) or 0
      local G = love.graphics
      G.push()
      if scale ~= nil then
        G.translate(ox or 0, oy or 0)
        if scale and scale ~= 1 then G.scale(scale, scale) end
        drawSleepZzz(px + 8, py - 4, sleepZzzSeed(self))
      else
        -- camX, camY form
        drawSleepZzz(px - (ox or 0) + 8, py - (oy or 0) - 4, sleepZzzSeed(self))
      end
      G.pop()
    end

    pcall(function()
      -- Try multiple require paths for iOS/Android compatibility.
      -- The engine's module structure may differ across platforms.
      local NPC = nil
      for _, path in ipairs({
        "src.world.gen2.Npc",
        "src.world.Npc",
        "world.gen2.Npc",
        "world.Npc",
      }) do
        local ok, mod = pcall(require, path)
        if ok and mod and type(mod.draw) == "function" then
          NPC = mod
          break
        end
      end
      if not (NPC and type(NPC.draw) == "function") then return end
      -- Reset the wrap flag on every mod load. The flag persists on the NPC
      -- class across mod updates; without resetting, a fixed draw hook would
      -- never install because the old (broken) wrap is still marked as done.
      NPC._johtoLifeZzzWrapped = nil
      local baseDraw = NPC.draw
      NPC.draw = function(self, ox, oy, scale)
        local sleeping = self.nightlifeSleeping
        -- Always preserve original 2-arg behavior through base, BUT
        -- sleeping NPCs need the rotation even in the 2-arg path.
        -- (Bug: the scale==nil early return was skipping sleep visuals.)
        if scale == nil and not sleeping then
          local r = baseDraw(self, ox, oy)
          if not isVoxelPresentation() then
            drawZzzForNpc(self, ox, oy, nil)
          end
          drawCollisionBubble(self, ox, oy, nil)
          return r
        end
        -- If sleeping and scale is nil, use scale=1 for the sleep path below.
        if scale == nil then scale = 1 end
        local voxel = isVoxelPresentation()
        local angle = self.johtoLifeSleepAngle or (math.pi / 2)
    
        local baked = self.sprite and self.sprite._johtoSleepBaked
        -- Invalidate stale bakes from 1.4.0-1.4.14 (blank canvases).
        -- Cache version 2 = bake disabled, use draw-time fallback.
        if SleepAssets and SleepAssets._johtoLifeSleepCacheVersion == 2 then
          baked = false
        end
        -- Baked lying sprite: normal draw path (same idea as SPRITE_GAMBLER_ASLEEP).
        if sleeping and baked then
          local r = baseDraw(self, ox, oy, scale)
          drawSleepAccessory(self, ox, oy, scale)
          if not voxel then
            drawZzzForNpc(self, ox, oy, scale)
          end
          drawCollisionBubble(self, ox, oy, scale)
          return r
        end

        -- Voxel (or missing sprite): must use baseDraw so figures still appear
        if sleeping and (not voxel) and self.sprite and type(self.sprite.draw) == "function" then
          local G = love.graphics
          local yOff = (self.spriteYOffset or 0) + 4
          local px, py = self.px or 0, self.py or 0
          local okRot = pcall(function()
            G.push()
            G.translate(ox or 0, oy or 0)
            if scale and scale ~= 1 then G.scale(scale, scale) end
            local cx, cy = px + 8, py + yOff + 4
            G.translate(cx, cy)
            G.rotate(angle)
            G.translate(-cx, -cy)
            self.sprite:draw(px, py + yOff - 4, 0, 0, "down", 0, false, false, false, nil)
            G.pop()
          end)
          if not okRot then
            baseDraw(self, ox, oy, scale)
          end
          if sleeping then drawSleepAccessory(self, ox, oy, scale) end
        else
          baseDraw(self, ox, oy, scale)
          if sleeping then drawSleepAccessory(self, ox, oy, scale) end
        end
        drawCollisionBubble(self, ox, oy, scale)

        if not voxel then
          drawZzzForNpc(self, ox, oy, scale)
        end
      end
      NPC._johtoLifeZzzWrapped = true
    end)

    -- Voxel sleep Zs: use Gold's REAL Gen-2 battle animation runtime.
    --
    -- The previous implementation used src.battle.AnimPlayer, which is the
    -- Gen-1 battle-animation format. Gold does not use that format. Gold's
    -- battle sleep effect is ANIM_SLP -> BattleAnim_Slp ->
    -- BATTLE_ANIM_OBJ_ASLEEP, rendered by src.battle.gen2.AnimRunner and
    -- src.ui.gen2.BattleAnimView. This block instantiates those exact engine
    -- classes from the merged Gold data; it does not redraw the Zs itself.
    pcall(function()
      local BA = require("src.battle.gen2.AnimRunner")
      local BV = require("src.ui.gen2.BattleAnimView")
      local Pipelines = require("src.render.Pipelines")
      local Voxel3D = nil
      local VoxelScene = nil

      local ba = type(mod.find) == "function" and mod.find("BATTLE_ART_VOXEL_GEN2") or nil
      local V = ba and (ba.lib or (ba.exports and ba.exports.lib)) or nil
      if V and type(V.require) == "function" then
        Voxel3D = V.require("Voxel3D")
        VoxelScene = V.require("VoxelScene")
      end
      if not (Voxel3D and BA and BV and Pipelines) then
        mod.log:warn("Johto Life: Gold battle sleep overlay unavailable (engine modules missing)")
        return
      end

      local sleepRunner
      local sleepView
      local sleepData
      local sleepKey
      local lastSleepStep = -1

      local function setupSleepRuntime()
        local g = G()
        local data = g and g.data or nil
        local anims = data and data.gen2BattleAnims or nil
        local constants = data and data.gen2Constants or nil
        local palettes = data and data.gen2Palettes or nil
        if not (anims and constants and palettes) then return false end

        local ids = anims.ids or {}
        local key = ids.ANIM_SLP
        if not key then
          -- Keep this fail-closed: do not substitute a guessed animation key.
          mod.log:warn("Johto Life: Gold battle animation data has no ANIM_SLP id")
          return false
        end
        if sleepRunner and sleepView and sleepData == anims and sleepKey == key then
          return true
        end

        local okR, runner = pcall(BA.new, {
          data = anims,
          constants = constants,
          battleTurn = 1, -- sleep is a status effect on the opposing/enemy side
          animId = "ANIM_SLP",
          sgb = false,
        })
        if not okR or not runner then
          mod.log:warn("Johto Life: could not construct Gold ANIM_SLP runner")
          return false
        end
        local okV, view = pcall(BV.new, anims, palettes)
        if not okV or not view then
          mod.log:warn("Johto Life: could not construct Gold BattleAnimView")
          return false
        end
        local okStart = pcall(function() runner:start(key) end)
        if not okStart then
          mod.log:warn("Johto Life: could not start Gold ANIM_SLP")
          return false
        end
        sleepRunner, sleepView, sleepData, sleepKey = runner, view, anims, key
        lastSleepStep = -1
        mod.log:info("Johto Life: using Gold gen2 ANIM_SLP / BattleAnimView for voxel sleep")
        return true
      end

      local function stepSleepRuntime(frame)
        if not setupSleepRuntime() then return false end
        -- Exactly one Gen-2 battle-animation frame per rendered game frame.
        -- The runner owns the object positions/frames; Johto Life only chooses
        -- where that finished 160x144 animation canvas is placed in voxel space.
        if frame ~= lastSleepStep then
          pcall(function() sleepRunner:step() end)
          -- Gold's real ANIM_SLP script intentionally runs three 40-frame
          -- loops and then returns. In an actual battle the status remains
          -- represented by the battle state, so the caller can start the
          -- effect again when needed. An overworld sleeper has no battle
          -- state to restart it for us, so keep the exact Gold animation
          -- looping for as long as the NPC remains asleep.
          if type(sleepRunner.done) == "function" and sleepRunner:done() then
            pcall(function()
              sleepRunner:start(sleepKey)
              sleepRunner:step()
            end)
          end
          lastSleepStep = frame
        end
        return true
      end

      local function drawGoldSleep(canvas, ctx)
        if not canvas or not ctx or opt("sleep_bubbles") == false then return end
        if not setupSleepRuntime() then return end

        local state = ctx.state
        if not state then return end
        local sleepers = {}
        for _, npc in ipairs(state.npcs or {}) do
          if npc and npc.nightlifeSleeping then sleepers[#sleepers + 1] = npc end
        end
        for _, e in ipairs(state.entities or {}) do
          if e and e.nightlifeSleeping then sleepers[#sleepers + 1] = e end
        end
        for _, ghost in ipairs(state.ghosts or {}) do
          if ghost and ghost.npc and ghost.npc.nightlifeSleeping then
            local n = ghost.npc
            n = setmetatable({
              px = (n.px or 0) + (ghost.ox or 0),
              py = (n.py or 0) + (ghost.oy or 0),
              cellX = n.cellX, cellY = n.cellY,
              nightlifeSleeping = true,
            }, { __index = n })
            sleepers[#sleepers + 1] = n
          end
        end
        if #sleepers == 0 then return end

        local Gfx = love.graphics
        local prevCanvas = Gfx.getCanvas()
        local prevShader = Gfx.getShader()
        if not pcall(Gfx.setCanvas, canvas) then return end

        local iw, ih = 1, 1
        if type(Voxel3D.size) == "function" then
          local a, b = Voxel3D.size()
          if type(a) == "number" and a > 0 then iw = a end
          if type(b) == "number" and b > 0 then ih = b end
        end
        local ow = type(canvas.getWidth) == "function" and canvas:getWidth() or iw
        local oh = type(canvas.getHeight) == "function" and canvas:getHeight() or ih
        local sxRatio, syRatio = ow / iw, oh / ih
        local frame = math.floor(((love.timer and love.timer.getTime and love.timer.getTime()) or 0) * 60)
        stepSleepRuntime(frame)

        Gfx.push("all")
        Gfx.setShader()
        Gfx.setColor(1, 1, 1, 1)

        -- The Gold battle animation itself is the source of the Z shape.
        -- Johto Life's 2D presentation, however, intentionally gives its Z
        -- glyph a white pixel outline. Keep the battle-authored Z geometry
        -- and animation, but reproduce that outline by drawing the exact same
        -- battle object through an all-white palette at the four neighboring
        -- pixel positions before drawing the real object on top.
        local originalObjPalette = sleepView.objPalette
        local WHITE_PALETTE = {
          { 255, 255, 255 }, { 255, 255, 255 },
          { 255, 255, 255 }, { 255, 255, 255 },
        }
        local function drawSleepObjectsWithOutline(x, y, scale)
          -- Palette substitution is how the engine renders the actual
          -- 2bpp battle sheet; no bitmap or Z glyph is fabricated here.
          sleepView.objPalette = function() return WHITE_PALETTE end
          local outlinePx = 1 / math.max(scale, 0.001)
          for _, d in ipairs({
            {-outlinePx, 0}, {outlinePx, 0},
            {0, -outlinePx}, {0, outlinePx},
          }) do
            Gfx.push()
            Gfx.translate(x + d[1] * scale, y + d[2] * scale)
            pcall(function() sleepView:drawObjects(sleepRunner, nil) end)
            Gfx.pop()
          end
          sleepView.objPalette = originalObjPalette

          -- The real battle palette/graphics go on last, preserving the exact
          -- Gold animation in the center of the outline.
          Gfx.push()
          Gfx.translate(x, y)
          pcall(function() sleepView:drawObjects(sleepRunner, nil) end)
          Gfx.pop()
        end

        -- Gold's ANIM_SLP object is authored at battle OAM (64,80). The
        -- renderer converts that to draw-space (56,64), then FLOAT_UP moves
        -- it. We map that exact battle anchor to a point just above each
        -- sleeper's projected head. No glyphs, font calls, or guessed frames.
        local BATTLE_ANCHOR_X = 56
        local BATTLE_ANCHOR_Y = 64
        local drawn = {}

        for _, npc in ipairs(sleepers) do
          if npc and not drawn[npc] then
            drawn[npc] = true
            local px = tonumber(npc.px or npc.x or ((npc.cellX or 0) * 16)) or 0
            local pz = tonumber(npc.py or npc.y or ((npc.cellY or 0) * 16)) or 0
            local gh = 0
            if VoxelScene and type(VoxelScene.groundAt) == "function" then
              local gok, h = pcall(VoxelScene.groundAt, state.map,
                                    npc.cellX, npc.cellY)
              if gok and type(h) == "number" then gh = h end
            end

            local x, y, perspective
            local groundX, groundY
            -- Match the camera mode to Battle Art's actual world renderer.
            -- Do not infer free-camera state from Voxel3D.camera: that field
            -- is nil for the normal orbit and populated only by the placed
            -- first/third-person rigs.
            local freeCamera = (Voxel3D.camera ~= nil)
            local okState, VoxelState = pcall(V.require, "VoxelState")
            if type(Voxel3D.project) == "function" then
              -- Use the exact screen-space position of Battle Art's NPC card,
              -- rather than inventing a world-space Z offset. VoxelScene's
              -- drawEntity places a 16x16 card at (px+8, gh, py+8), pivots it
              -- at the feet, then applies the same pitch used by the camera.
              -- Reproduce that transform for the card's TOP CENTER.  We keep
              -- the projected ground-center X so the Z can never drift sideways
              -- from the NPC it belongs to.
              local cx, cy, cp = Voxel3D.project(px + 8, gh, pz + 8)
              groundX, groundY = cx, cy
              local angle = nil
              if VoxelScene and VoxelScene.spriteLean ~= nil then
                angle = tonumber(VoxelScene.spriteLean)
              end
              if not angle then
                local okVS, VS = pcall(V.require, "VoxelState")
                if okVS and VS then angle = tonumber(VS.angle) end
              end
              angle = angle or (math.pi / 2)

              -- Battle Art's billboardMatrix rotates local +Y around the feet
              -- by (angle - pi/2). The top-center vector (0,16,0) therefore
              -- becomes (0, 16*cos(theta), 16*sin(theta)).
              local theta = angle - math.pi / 2
              local topWorldY = gh + 16 * math.cos(theta)
              local topWorldZ = pz + 8 + 16 * math.sin(theta)
              local tx, ty, tp = Voxel3D.project(px + 8, topWorldY, topWorldZ)
              x, y, perspective = cx, ty, cp or tp
            end
            if x and y then
              perspective = tonumber(perspective) or 1
              if perspective < 0.35 then perspective = 0.35 end
              if perspective > 3.0 then perspective = 3.0 end
              x, y = x * sxRatio, y * syRatio

              local scale = (tonumber(ctx.scale) or 1) * perspective * sxRatio
              -- The free camera uses a much wider world view than the
              -- diorama. The battle-authored 160x144 object therefore needs
              -- a larger presentation scale to match the 2D sleep effect.
              if freeCamera then scale = scale * 2.0 end

              if scale < 0.35 then scale = 0.35 end; if scale > 8.0 then scale = 8.0 end
-- Tent (style 1) stays upright; sleeping bag (2) and bed (3) lie flat.
                local pang = math.pi/2
              Gfx.push()
              local tx = x - BATTLE_ANCHOR_X * scale
              local ty = y - BATTLE_ANCHOR_Y * scale
              Gfx.scale(scale, scale)
              drawSleepObjectsWithOutline(tx / scale, ty / scale, scale)
              Gfx.pop()

              -- Non-default tent/bag/bed props are presentation-only additions.
              -- The default Gold sleep sprite above is never replaced.
              local propStyle = math.floor(tonumber(opt("sleep_style")) or 0)
              if propStyle == 4 then
  propStyle = npc.kantoLifeRandomSleepStyle
  if propStyle == nil then
    propStyle = math.random(0, 3)
    npc.kantoLifeRandomSleepStyle = propStyle
  end
end
local prop = propStyle > 0 and sleepPropImage(propStyle) or nil
              if prop and groundX and groundY then
                local pw, ph = prop:getDimensions()
                -- Props need to be larger than the NPC sprite scale to be visible.
                -- Use 2x the NPC scale so bed/tent/sleeping bag are prominent.
                local pscale = scale * 2.0
                if pscale < 1.6 then pscale = 1.6 end
                -- Tent (style 1) stays upright (angle 0); sleeping bag (2) and bed (3) lie flat (90°).
                local pang = (propStyle == 1) and 0 or (math.pi/2)
                Gfx.push("all")
                                Gfx.setColor(1,1,1,1)
-- groundX/groundY are unscaled; x/y were already scaled at line 2987.
                -- Scale ground before averaging, don't scale the result.
                local propX = (groundX * sxRatio + x) * 0.5
                local propY = (groundY * syRatio + y) * 0.5
            Gfx.draw(prop, propX, propY, pang, pscale, pscale, pw/2, ph/2)
                Gfx.pop()
              end
            end
          end
        end

        Gfx.pop()
        pcall(Gfx.setShader, prevShader)
        pcall(Gfx.setCanvas, prevCanvas)
      end

      if type(Pipelines.worldPresent) ~= "function" then return end
      if Pipelines._johtoLifeSleepWorldPresentWrapped then return end
      local baseWorldPresent = Pipelines.worldPresent
      Pipelines.worldPresent = function(canvas, ctx)
        local out = baseWorldPresent(canvas, ctx)
        local id = nil
        if type(Pipelines.worldPipeline) == "function" then
          local ok, v = pcall(Pipelines.worldPipeline)
          if ok then id = v end
        end
        if id == "voxel" and out then
          pcall(function() drawGoldSleep(out, ctx) end)
        end
        return out
      end
      Pipelines._johtoLifeSleepWorldPresentWrapped = true
      mod.log:info("Johto Life: voxel sleep overlay now uses Gold's actual ANIM_SLP runtime")
    end)

  mod.log:info("Johto Life 0.1.52 loaded")
end
