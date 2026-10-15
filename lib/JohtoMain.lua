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
  local function loadJohtoSleepAsset(rel)
    if sleepPropCache[rel] then return sleepPropCache[rel] end
    local ok, img = false, nil
    local candidates = {
      "assets/" .. rel,
      rel,
    }
    if mod.assets and type(mod.assets.path) == "function" then
      local p = mod.assets:path("assets/" .. rel)
      if p then candidates[#candidates + 1] = p end
    end
    if mod.path then
      candidates[#candidates + 1] = tostring(mod.path) .. "/assets/" .. rel
    end
    if mod.assets and type(mod.assets.image) == "function" then
      ok, img = pcall(mod.assets.image, mod.assets, "assets/" .. rel)
    end
    if not ok or not img then
      for _, path in ipairs(candidates) do
        ok, img = pcall(love.graphics.newImage, path)
        if ok and img then break end
      end
    end
    if ok and img then
      img:setFilter("nearest", "nearest")
      sleepPropCache[rel] = img
      return img
    end
    mod.log:warn("Johto Life: could not load sleep prop %s", tostring(rel))
    return nil
  end
  local function sleepPropImage(style)
    style = math.floor(tonumber(style) or 0)
    if style <= 0 then return nil end
    local names = {[1]="sleep_tent.png", [2]="sleeping_bag.png", [3]="sleep_bed.png"}
    local rel = names[style]
    if not rel then return nil end
    return loadJohtoSleepAsset(rel)
  end

  -- Base (opaque) image for 3-layer rendering: drawn UNDER the NPC
  local function sleepPropBaseImage(style)
    style = math.floor(tonumber(style) or 0)
    if style <= 0 or style == 1 then return nil end  -- No base for Default or Tent
    local names = {[2]="sleeping_bag_base.png", [3]="sleep_bed_base.png"}
    local rel = names[style]
    if not rel then return nil end
    return loadJohtoSleepAsset(rel)
  end

  -- Build a new 1-frame sprite from the NPC's current rendered standing frame,
  -- rotated ±90°, so both the flat and voxel renderers consume the same pixels.

  -- Allow SpriteBillboards / Assets to resolve in-memory prop images.
  do
    local hooked = false
    local function ensurePropAssetHook()
      if hooked then return end
      hooked = true
      pcall(function()
        local okA, Assets = pcall(require, "src.Assets")
        if not (okA and Assets and type(Assets.get) == "function") then return end
        if Assets._johtoLifePropHooked then return end
        local baseGet = Assets.get
        Assets.get = function(path, ...)
          local imgs = _G._johtoLifePropImages
          if imgs and path and imgs[path] then return imgs[path] end
          return baseGet(path, ...)
        end
        Assets._johtoLifePropHooked = true
      end)
    end
    ensurePropAssetHook()
  end

  local function bakeRotatedSleepSprite(npc)
    if not npc or not npc.sprite then return false end
    local sprite = npc.sprite
    if sprite._johtoSleepBaked then
      if tonumber(sprite._johtoSleepCacheVersion) == 2 then return true end
      -- A sprite object can survive hot-reloads of Kanto Life. Discard the
      -- older 1.4.0 blank bake and restore the original 1.0.0-compatible source
      -- before baking again; otherwise voxel mode keeps resolving the stale
      -- sentinel image even though the current code has been fixed.
      if sprite._johtoSleepImageKey then johtoSleepImages[sprite._johtoSleepImageKey] = nil end
      if sprite._johtoOrigImage ~= nil then sprite.image = sprite._johtoOrigImage end
      if sprite._johtoOrigFrames ~= nil then sprite.frames = sprite._johtoOrigFrames end
      if sprite._johtoOrigFrameCount ~= nil then sprite.frameCount = sprite._johtoOrigFrameCount end
      if sprite._johtoOrigDef ~= nil then sprite.def = sprite._johtoOrigDef end
      sprite._johtoSleepImageKey = nil
      sprite._johtoOrigImage, sprite._johtoOrigFrames = nil, nil
      sprite._johtoOrigFrameCount, sprite._johtoOrigDef = nil, nil
      sprite._johtoSleepBaked, sprite._johtoSleepCacheVersion = nil, nil
    end
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
    sprite._johtoOrigFrameWidth = sprite.frameWidth
    sprite._johtoOrigFrameHeight = sprite.frameHeight
    sprite._johtoOrigAnchorX = sprite.anchorX
    sprite._johtoOrigAnchorY = sprite.anchorY
    sprite.image = canvas
    sprite.frameWidth = fw
    sprite.frameHeight = fh
    sprite.anchorX = fw / 2
    sprite.anchorY = fh
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
    newDef.frameWidth = fw
    newDef.frameHeight = fh
    newDef.anchorX = fw / 2
    newDef.anchorY = fh
    sprite.def = newDef
    sprite._johtoSleepBaked = true
    sprite._johtoSleepCacheVersion = 2
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
    sprite._johtoSleepCacheVersion = nil
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
    { key = "sleep_style", type = "choice", label = "SLEEP STYLE", default = 0, choices = { { "Default", 0 }, { "Tent", 1 }, { "Sleeping Bag", 2 }, { "Bed", 3 }, { "Random", 4 }, { "Natural", 5 } } },
    { key = "npc_collision_bubbles", type = "toggle", label = "NPC TALK BUBBLES", default = true },
    { key = "common_courtesy", type = "toggle", label = "DOOR KNOCKING", default = true },
    { key = "npc_routines", type = "toggle", label = "NPC ROUTINES", default = true },
        { key = "npc_travel_pct", type = "number", label = "NPC TRAVEL %",
      default = 30, min = 0, max = 100, step = 10 },
    { key = "npc_travel_methods", type = "toggle", label = "TRAVEL METHODS", default = true },
    { key = "npc_fly_teleport", type = "toggle", label = "FLY / TELEPORT", default = true },
    { key = "npc_agenda", type = "choice", label = "NPC AGENDA",
      choices = { { "OFF", 0 }, { "DAY", 1 }, { "FULL", 2 } }, default = 0 },
    -- EXPERIMENTAL: Lifelike feature toggles
    { key = "exp_greetings", type = "toggle", label = "LIFELIKE GREETINGS", default = true },
    { key = "exp_chatter", type = "toggle", label = "NPC CHATTER", default = true },
    { key = "exp_moods", type = "toggle", label = "NPC MOODS", default = true },
    { key = "exp_idle", type = "toggle", label = "IDLE BEHAVIORS", default = true },
    { key = "exp_timeaware", type = "toggle", label = "TIME AWARENESS", default = true },
    { key = "exp_player", type = "toggle", label = "PLAYER REACTIONS", default = true },
    { key = "exp_companions", type = "toggle", label = "COMPANIONS", default = true },
    { key = "exp_ambience", type = "toggle", label = "AMBIENT LIFE", default = true },
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
    -- Extra trainers / important humans for ambient variety
    { "SPRITE_BLACK_BELT", "m" }, { "SPRITE_HIKER", "m" },
    { "SPRITE_PSYCHIC", "m" }, { "SPRITE_MEDIUM", "f" },
    { "SPRITE_KIMONO_GIRL", "f" }, { "SPRITE_FIREBREATHER", "m" },
    { "SPRITE_JUGGLER", "m" }, { "SPRITE_Biker", "m" },
    { "SPRITE_BIKER", "m" }, { "SPRITE_CAMPER", "m" },
    { "SPRITE_PICNICKER", "f" }, { "SPRITE_ROCKET", "m" },
    { "SPRITE_ROCKET_GIRL", "f" }, { "SPRITE_GUITARIST", "m" },
    { "SPRITE_GENTLEMAN", "m" }, { "SPRITE_OFFICER_M", "m" },
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
      sp = sp:upper():gsub(" ", "_"):gsub("'", "")
      if seen[sp] then return end
      if sp:find("^SPRITE") or sp:find("^PAL_") or sp == "NONE" then return end
      -- Never treat human class names as mons
      if sp:find("TRAINER", 1, true) or sp:find("PLAYER", 1, true) then return end
      seen[sp] = true
      out[#out + 1] = sp
    end
    local g = G and G() or game
    local data = g and g.data and g.data.pokemon
    if type(data) == "table" then
      for id, def in pairs(data) do
        if type(id) == "string" then add(id)
        elseif type(id) == "number" and type(def) == "table" then
          if type(def.id) == "string" then add(def.id) end
          if type(def.species) == "string" then add(def.species) end
          if type(def.name) == "string" then add(def.name) end
        end
        if type(def) == "table" then
          if type(def.id) == "string" then add(def.id) end
          if type(def.species) == "string" then add(def.species) end
        end
      end
    end
    local sprites = g and g.data and g.data.sprites
    if type(sprites) == "table" then
      for id, sd in pairs(sprites) do
        local s = tostring(id):upper()
        if s:find("SPRITE_POKEMON_", 1, true) then
          add(s:gsub("^SPRITE_POKEMON_", ""))
        elseif type(sd) == "table" and sd.species then
          add(tostring(sd.species))
        end
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
      -- Merge every human-looking sprite from the live registry (all trainers).
      pcall(function()
        local reg = game and game.data and game.data.sprites
        if type(reg) ~= "table" then return end
        local extra = {}
        for id, _ in pairs(reg) do
          local u = tostring(id):upper()
          if u:find("^SPRITE_") and not u:find("POKEMON") and not u:find("POKE_")
             and not u:find("PLAYER") and not u:find("ITEM") and not u:find("BALL")
             and not u:find("STILL") and not u:find("MISC") then
            extra[#extra+1] = { id, (u:find("_F") or u:find("LASS") or u:find("GIRL")
              or u:find("BEAUTY") or u:find("WOMAN") or u:find("GRANNY")) and "f" or "m" }
          end
        end
        if #extra > 0 then
          local merged = {}
          for _, c in ipairs(pool) do merged[#merged+1] = c end
          for _, c in ipairs(extra) do merged[#merged+1] = c end
          pool = merged
        end
      end)
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
    if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId, mod.world and type(mod.world.overworld) == "function" and mod.world:overworld() and mod.world:overworld().map)) then return end
    local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
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
    -- Pokemon spawn on towns, routes, AND indoor maps (pokeTarget handles
    -- the indoor count via the indoor_npcs/pokemon_npc_count options).
    if isTown(mapId) or isRoute(mapId) or isIndoor(mapId, map) then
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
    local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
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

  -- Cross-map traveler pool (Gen 2): same design as Gen 1. When an NPC
  -- exits through a door/warp to a DIFFERENT map, they are recorded here.
  -- When the player enters the destination map, the traveler spawns at the
  -- entrance connecting from their origin map.
  local johtoTravelers = {}
  local JOHTO_TRAVELER_EXPIRY = 600

  local function pruneJohtoTravelers()
    local now = os.time()
    for destMap, list in pairs(johtoTravelers) do
      local kept = {}
      for _, t in ipairs(list) do
        if now - (t.timestamp or 0) < JOHTO_TRAVELER_EXPIRY then
          kept[#kept + 1] = t
        end
      end
      if #kept > 0 then johtoTravelers[destMap] = kept
      else johtoTravelers[destMap] = nil end
    end
  end

  local function onJohtoRoutineExit(npc, world, old)
    local destMap = old and old[4]
    destMap = destMap and tostring(destMap) or ""
    local currentMap = world and world.map and tostring(world.map.id or "") or ""
    if destMap == "" or destMap == currentMap then
      return false
    end
    local d = npc and npc.def or {}
    johtoTravelers[destMap] = johtoTravelers[destMap] or {}
    table.insert(johtoTravelers[destMap], {
      sprite = d.sprite,
      name = d.kantoLifeDisplayName or d.name,
      gender = d.kantoLifeGender,
      agenda = npc and npc._kantoLifeAgenda,
      fromMap = currentMap,
      timestamp = os.time(),
    })
    pruneJohtoTravelers()
    -- EXPERIMENTAL: farewell waves — nearby NPCs wave goodbye to the
    -- departing traveler.
    pcall(function()
      if not npc then return end
      local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
      if not nx or not ny then return end
      local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
      local farewells = { "Bye!", "See ya!", "Safe travels!", "Take care!", "Bye-bye!" }
      local waved = 0
      for _, other in ipairs(world.npcs or {}) do
        if other ~= npc and waved < 3 then
          local d2 = other.def or {}
          if d2.johtoLifeAmbient and not other.nightlifeSleeping and not other.moving then
            local ox, oy = tonumber(other.cellX), tonumber(other.cellY)
            if ox and oy then
              local dist = math.abs(ox - nx) + math.abs(oy - ny)
              if dist <= 3 and dist > 0 then
                local bubbleUntil = tonumber(other._kantoLifeCollisionBubbleUntil) or 0
                if bubbleUntil <= now then
                  other._kantoLifeCollisionBubbleText = farewells[math.random(1, #farewells)]
                  other._kantoLifeCollisionBubbleUntil = now + 2.0
                  waved = waved + 1
                end
              end
            end
          end
        end
      end
    end)
    if npc and npc.id and world and type(world.removeNpc) == "function" then
      pcall(world.removeNpc, world, npc.id)
    end
    return true
  end

  local function spawnJohtoTravelers(mapId)
    local key = tostring(mapId or "")
    local pending = johtoTravelers[key]
    if not pending or #pending == 0 then return end
    pruneJohtoTravelers()
    pending = johtoTravelers[key]
    if not pending or #pending == 0 then return end

    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map or ow.map.id ~= mapId then return end
    local map = ow.map

    local entrances = {}
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

    local remaining = {}
    for _, t in ipairs(pending) do
      local entrance = entrances[t.fromMap]
      if entrance then
        local x, y = entrance[1], entrance[2] + 1
        local name = "JOHTO_TRAVELER_" .. key .. "_" .. tostring(os.time() % 100000)
        local ok, id = pcall(function()
          return mod.world:spawnNpc(key, {
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
        if not (ok and id) then
          remaining[#remaining + 1] = t
        else
          -- EXPERIMENTAL: arrival greeting
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
        end
      else
        remaining[#remaining + 1] = t
      end
    end

    if #remaining > 0 then johtoTravelers[key] = remaining
    else johtoTravelers[key] = nil end
  end

  local JohtoRoutines, johtoRoutineErr = loadBundled("lib/JohtoRoutines.lua")
  -- Combinatorial dialogue generator: unique lines via template+slot
  -- expansion with per-NPC history (see lib/DialogueGen.lua).
  local DialogueGen = loadBundled("lib/DialogueGen.lua")
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
      onRoutineExit = onJohtoRoutineExit,
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
        { label = "SLEEP STYLE", right = ({[0]="Default",[1]="Tent",[2]="Sleeping Bag",[3]="Bed",[4]="Random",[5]="Natural"})[math.floor(tonumber(opt("sleep_style")) or 0)] or "Default", stepper = true,
          step = function(dir) local n=(math.floor(tonumber(opt("sleep_style")) or 0)+(dir or 1))%6; setOpt("sleep_style",n) end,
          onSelect = function() local n=(math.floor(tonumber(opt("sleep_style")) or 0)+1)%6; setOpt("sleep_style",n) end },
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
        { label = "FLY / TELEPORT", right = opt("npc_fly_teleport") ~= false and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("npc_fly_teleport", not (opt("npc_fly_teleport") ~= false)) end },
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
      local ok, w = pcall(function() return mod.world and type(mod.world.overworld) == "function" and mod.world:overworld() end)
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
      if id then pcall(spawnJohtoTravelers, id) end
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
        local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
        if ow and type(johtoRoutines.update) == "function" then
          johtoRoutines.update(ow, 0, true)
        end
      end
      refreshCurrentMap()
      -- Immediately re-apply sleep when rate / toggle / day-sleepers / style change
      if p.key == "sleep_pct" or p.key == "sleeping_npcs" or p.key == "day_sleepers"
         or p.key == "sleep_style" or p.key == "sleep_bubbles" then
        local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
        if ow then pcall(johtoSleepTick, ow) end
      end
    end)
  end

  johtoSleepTick = function(world)
    if not world or not opt("sleeping_npcs") then return end
    local function safe(npc)
      local map = world.map
      if not map or not npc then return false end
      local x, y = npc.cellX, npc.cellY
      if x == nil or y == nil then return false end
      -- Only block the door tile itself and immediate neighbors (1 cell).
      for _, w in ipairs(map.warps or (map.def and map.def.warps) or {}) do
        local wx = tonumber(w.x or w.cellX or w.tx)
        local wy = tonumber(w.y or w.cellY or w.ty)
        if wx and wy and math.abs(wx - x) <= 1 and math.abs(wy - y) <= 1 then
          return false
        end
      end
      if type(map.warpAtCell) == "function" then
        for dx = -1, 1 do
          for dy = -1, 1 do
            local ok, isW = pcall(map.warpAtCell, map, x + dx, y + dy)
            if ok and isW then return false end
          end
        end
      end
      if type(map.isDoorTileCell) == "function" then
        local ok, door = pcall(map.isDoorTileCell, map, x, y)
        if ok and door then return false end
      end
      -- Do NOT require isWalkableCell — NPCs already stand on valid tiles;
      -- that check was eliminating most candidates on some maps.
      return true
    end
    local function putAsleep(npc)
      if not npc or npc.nightlifeSleeping then return end
      -- Hard gate: never sleep mart/center map staff (non-ambient)
      do
        local d = npc.def or {}
        local spr = tostring(d.sprite or npc.sprite or ""):upper()
        local nm = tostring(d.name or npc.name or ""):upper()
        if spr:find("NURSE", 1, true) or nm:find("JOY", 1, true)
           or spr:find("CLERK", 1, true) or spr:find("MART", 1, true)
           or spr:find("SHOP", 1, true) or spr:find("CASHIER", 1, true)
           or spr:find("RECEPTION", 1, true) then
          return
        end
        local isAmb = d.johtoLifeAmbient or npc.johtoLifeAmbient
        local mapId = tostring((world.map and world.map.id) or ""):upper()
        if (mapId:find("MART", 1, true) or mapId:find("CENTER", 1, true)
            or mapId:find("POKECENTER", 1, true)) and not isAmb then
          return
        end
      end
      -- Door exclusion is handled by safe() (1-cell). A 5-cell radius was
      -- rejecting almost every NPC in towns and all indoor sleepers.
      npc.moving = false; npc.targetX = nil; npc.targetY = nil; npc.progress = 0
      npc.spriteYOffset = 0; npc.frozen = true; npc.nightlifeSleeping = true
      npc.sleepPose = true
      if npc.def then npc.def.sleeping = true end
      -- Keep the real overworld sprite (HGSS 32px etc.) for voxel body layer.
      -- Pose later swaps in an invisible card so BA does not draw a standing body.
      if npc.sprite and not npc.sprite._johtoInvisible then
        npc._johtoOrigSleepSprite = npc.sprite
      end
      if npc.facing ~= nil and npc.johtoLifeSleepFacing == nil then
        npc.johtoLifeSleepFacing = npc.facing
      end
      local sign = ((npc.cellX or 0) + (npc.cellY or 0)) % 2 == 0 and 1 or -1
      npc.johtoLifeSleepAngle = sign * (math.pi / 2)
      npc.johtoLifeSleepSide = sign
      pcall(bakeRotatedSleepSprite, npc)
      local faceDir = (sign > 0) and "LEFT" or "RIGHT"
      pcall(function()
        if type(npc.face) == "function" then npc:face(faceDir) else npc.facing = faceDir end
      end)
    end
    local function wakeUp(npc)
      if not npc.nightlifeSleeping then return end
      npc.frozen = false; npc.nightlifeSleeping = nil; npc.johtoLifeSleepAngle = nil
      npc._johtoOrigSleepSprite = nil
      npc.sleepPose = nil
      if npc.def then npc.def.sleeping = nil end
      if npc._johtoLifeSavedVisible then
        npc.visible = true
        npc.hidden = false
        npc._johtoLifeSavedVisible = nil
      elseif npc.visible == false then
        npc.visible = true
        npc.hidden = false
      end
      npc._johtoLifeVoxelSleepHidden = nil
      pcall(restoreRotatedSleepSprite, npc)
      if npc.johtoLifeSleepFacing ~= nil then
        pcall(function()
          if type(npc.face) == "function" then npc:face(npc.johtoLifeSleepFacing)
          else npc.facing = npc.johtoLifeSleepFacing end
        end)
        npc.johtoLifeSleepFacing = nil
      end
      -- EXPERIMENTAL (fork): wake-up stretch bubble. Ported from the fork's
      -- Overworld.update inline sleep block during the 1.4.200 sync, when
      -- main consolidated sleep assignment into johtoSleepTick.
      pcall(function()
        local nowW = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
        local wakeBubbles = { "*yawn*", "*stretch*", "Mornin'..." }
        local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
        if bubbleUntil <= nowW then
          npc._kantoLifeCollisionBubbleText = wakeBubbles[math.random(1, #wakeBubbles)]
          npc._kantoLifeCollisionBubbleUntil = nowW + 2.0
        end
      end)
    end
    local pct = math.floor(tonumber(opt("sleep_pct")) or 10)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    local isNight = false
    if type(world.timeOfDay) == "function" then
      local ok, tod = pcall(function() return world:timeOfDay() end)
      local t = ok and tostring(tod):upper() or ""
      isNight = t == "NIGHT" or t == "NITE" or t == "MIDNIGHT"
    end
    -- Humans: sleep_pct of ALL ambient humans (not a pre-filtered 30% day subset).
    -- Day requires day_sleepers ON; night always eligible.
    local humanCandidates = {}
    local player = world.player
    for _, npc in ipairs(world.npcs or {}) do
      if npc and npc ~= player then
        local d = npc.def or {}
        local isPoke = d.johtoLifePokemon or npc.johtoLifePokemon
          or d.species or npc.species or d.pokemon
        local spr = tostring(d.sprite or npc.sprite or ""):upper()
        local nm = tostring(d.name or npc.name or ""):upper()
        local isExcluded = spr:find("NURSE", 1, true) or nm:find("JOY", 1, true)
          or spr:find("CLERK", 1, true) or spr:find("SAILOR", 1, true)
          or spr:find("PLAYER", 1, true) or nm:find("PLAYER", 1, true)
          or spr:find("MART", 1, true) or nm:find("MART", 1, true)
          or spr:find("SHOP", 1, true) or nm:find("SHOP", 1, true)
          or spr:find("CASHIER", 1, true) or spr:find("RECEPTION", 1, true)
          or nm:find("RECEPTION", 1, true) or spr:find("ATTENDANT", 1, true)
          or spr:find("GYM_GUIDE", 1, true) or d.isPlayer or npc.isPlayer
        local isAmb = d.johtoLifeAmbient or npc.johtoLifeAmbient
        -- Map staff in marts / centers must never sleep (only ambient visitors may).
        local mapId = tostring((world.map and world.map.id) or ""):upper()
        local isServiceMap = mapId:find("MART", 1, true)
          or mapId:find("CENTER", 1, true)
          or mapId:find("POKECENTER", 1, true)
          or mapId:find("POKE_CENTER", 1, true)
        if isServiceMap and not isAmb then
          isExcluded = true
        end
        local isHumanish = not isPoke and not isExcluded
        if isHumanish and safe(npc) and (isAmb or not d.trainerClass) then
          local id = tostring(npc.id or d.name or nm or "")
          local h = 0; for i = 1, #id do h = (h + id:byte(i) * i) % 10000 end
          humanCandidates[#humanCandidates + 1] = { npc = npc, hash = h }
        end
      end
    end
    table.sort(humanCandidates, function(a,b)
      if a.hash == b.hash then return tostring(a.npc.id) < tostring(b.npc.id) end
      return a.hash < b.hash
    end)
    local want = 0
    if isNight or opt("day_sleepers") then
      want = math.ceil(#humanCandidates * pct / 100)
      if pct > 0 and #humanCandidates > 0 and want < 1 then want = 1 end
      if pct >= 100 then want = #humanCandidates end
    end
    local chosen = {}
    for i = 1, want do chosen[humanCandidates[i].npc] = true end
    for _, entry in ipairs(humanCandidates) do
      local npc = entry.npc
      if chosen[npc] then putAsleep(npc) else wakeUp(npc) end
    end
    -- Pokemon ambients: sleep at the same rate at night; optional day_sleepers.
    local pokeCandidates = {}
    for _, npc in ipairs(world.npcs or {}) do
      local d = npc.def or {}
      local isAmb = d.johtoLifeAmbient or npc.johtoLifeAmbient
      local isPoke = d.johtoLifePokemon or npc.johtoLifePokemon
      if isAmb and isPoke and safe(npc) then
        local id = tostring(npc.id or d.name or "")
        local h = 0; for i = 1, #id do h = (h + id:byte(i) * i) % 10000 end
        pokeCandidates[#pokeCandidates + 1] = { npc = npc, hash = h }
      end
    end
    table.sort(pokeCandidates, function(a,b)
      if a.hash == b.hash then return tostring(a.npc.id) < tostring(b.npc.id) end
      return a.hash < b.hash
    end)
    local pokeWant = 0
    if isNight or opt("day_sleepers") then
      pokeWant = math.ceil(#pokeCandidates * pct / 100)
      if pct > 0 and #pokeCandidates > 0 and pokeWant < 1 then pokeWant = 1 end
      if pct >= 100 then pokeWant = #pokeCandidates end
    end
    local pokeChosen = {}
    for i = 1, pokeWant do pokeChosen[pokeCandidates[i].npc] = true end
    for _, entry in ipairs(pokeCandidates) do
      local npc = entry.npc
      if pokeChosen[npc] then putAsleep(npc) else wakeUp(npc) end
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
      -- EXPERIMENTAL: double-take — when the player enters a new map, nearby
      -- NPCs are surprised. Revisited maps get "Welcome back!" instead.
      pcall(function()
        local mapId = world.map and tostring(world.map.id or "") or ""
        local lastMap = world._kantoLifeLastMapId
        if lastMap and lastMap ~= mapId then
          world._kantoLifeVisitedMaps = world._kantoLifeVisitedMaps or {}
          local isRevisit = world._kantoLifeVisitedMaps[mapId]
          world._kantoLifeVisitedMaps[mapId] = true
          local player = world.player
          local px, py = player and tonumber(player.cellX), player and tonumber(player.cellY)
          if px and py then
            local nowDt = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
            local reacted = 0
            for _, n in ipairs(world.npcs or {}) do
              if reacted >= 3 then break end
              local d2 = n.def or {}
              if d2.johtoLifeAmbient and not n.nightlifeSleeping and not n.moving then
                local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
                if nx and ny then
                  local dist = math.abs(nx - px) + math.abs(ny - py)
                  if dist <= 4 and dist > 0 then
                    local bubbleUntil = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
                    if bubbleUntil <= nowDt then
                      if isRevisit then
                        local welcomes = { "Welcome back!", "You're back!", "Hey again!", "WB!" }
                        n._kantoLifeCollisionBubbleText = welcomes[math.random(1, #welcomes)]
                      else
                        n._kantoLifeCollisionBubbleText = "!"
                      end
                      n._kantoLifeCollisionBubbleUntil = nowDt + 1.5
                      reacted = reacted + 1
                    end
                  end
                end
              end
            end
          end
        end
        world._kantoLifeLastMapId = mapId
      end)
      -- EXPERIMENTAL: proximity greetings — ambient NPCs acknowledge the player
      -- with a brief bubble when walked past (not sleeping, cooldown per NPC).
      -- EXPERIMENTAL: idle behaviors — idle NPCs occasionally look around or
      -- show a thought bubble.
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
        -- EXPERIMENTAL: time transition comments
        local lastTimeOfDay = world._kantoLifeLastTimeOfDay
        if lastTimeOfDay and lastTimeOfDay ~= timeOfDay then
          local transitionComments = {
            morning = { "Morning already?", "Rise and shine!", "A new day!" },
            afternoon = { "Afternoon already!", "Time flies!", "It's midday!" },
            evening = { "Getting dark...", "Evening already?", "Sun's setting!" },
            night = { "It's night...", "So late...", "Time for bed soon." },
          }
          local comments = transitionComments[timeOfDay] or {}
          if #comments > 0 and player then
            local px2, py2 = tonumber(player.cellX), tonumber(player.cellY)
            if px2 and py2 then
              local commented = 0
              for _, n in ipairs(world.npcs or {}) do
                if commented >= 2 then break end
                local d = n.def or {}
                if d.johtoLifeAmbient and not n.nightlifeSleeping and not n.moving then
                  local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
                  if nx and ny then
                    local dist = math.abs(nx - px2) + math.abs(ny - py2)
                    if dist <= 5 and dist > 0 then
                      local bubbleUntil = tonumber(n._kantoLifeCollisionBubbleUntil) or 0
                      if bubbleUntil <= now then
                        n._kantoLifeCollisionBubbleText = comments[math.random(1, #comments)]
                        n._kantoLifeCollisionBubbleUntil = now + 2.0
                        commented = commented + 1
                      end
                    end
                  end
                end
              end
            end
          end
        end
        world._kantoLifeLastTimeOfDay = timeOfDay
        local greetingsByTime = {
          morning = { "Morning!", "Good morning!", "Hey!", "Hi there!", "Rise and shine!" },
          afternoon = { "Afternoon!", "Hey there!", "Hi!", "Yo!", "How's it going?" },
          evening = { "Evening!", "Hey!", "Hi there!", "Good evening!", "Yo!" },
          night = { "Oh, hi.", "Evening...", "*yawn* Hey.", "Hey...", "Still up?" },
        }
        local greetings = greetingsByTime[timeOfDay] or greetingsByTime.afternoon
        -- EXPERIMENTAL: NPC moods — each NPC has a mood that colors greetings.
        local moodGreetings = {
          happy = { "Hey!", "Hi there!", "Great day!", "Hello!", "Howdy!" },
          neutral = { "Hey.", "Hi.", "Hello.", "Yo." },
          grumpy = { "...", "Hmph.", "What?", "Yeah, hi." },
          sleepy = { "*yawn* Hey.", "Oh, hi...", "Mmm...", "Hey..." },
          excited = { "Hey hey!", "Wow, hi!", "Hello!!", "Hiya!" },
        }
        local moodList = { "happy", "neutral", "neutral", "grumpy", "sleepy", "excited" }
        local function getNpcMood(npc)
          local moodSetAt = tonumber(npc._kantoLifeMoodSetAt) or 0
          if now - moodSetAt > 1800 + math.random() * 1800 then
            npc._kantoLifeMood = moodList[math.random(1, #moodList)]
            npc._kantoLifeMoodSetAt = now
          end
          return npc._kantoLifeMood or "neutral"
        end
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
        local playerIdleLong = false
        local lastPX = tonumber(world._kantoLifePlayerLastX)
        local lastPY = tonumber(world._kantoLifePlayerLastY)
        if lastPX == px and lastPY == py then
          playerStill = true
          local stillSince = tonumber(world._kantoLifePlayerStillSince) or now
          if now - stillSince > 30 then playerIdleLong = true end
        else
          world._kantoLifePlayerStillSince = now
          if lastPX and lastPY then
            local moved = math.abs(px - lastPX) + math.abs(py - lastPY)
            if moved >= 2 then playerRunning = true end
          end
          world._kantoLifePlayerLastX = px
          world._kantoLifePlayerLastY = py
        end
        for _, npc in ipairs(world.npcs or {}) do
          local d = npc.def or {}
          if d.johtoLifeAmbient and not npc.nightlifeSleeping then
            -- EXPERIMENTAL: face the player — idle NPCs turn to look at you
            -- when you stand still nearby.
            if playerStill and not npc.moving then
              local nx0, ny0 = tonumber(npc.cellX), tonumber(npc.cellY)
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
                  if face and npc.facing ~= face then npc.facing = face end
                end
              end
            end
            -- EXPERIMENTAL: idle curiosity — NPCs notice if you stand still 30+s.
            if playerIdleLong and not npc.moving then
              local nx0, ny0 = tonumber(npc.cellX), tonumber(npc.cellY)
              if nx0 and ny0 then
                local pdist = math.abs(nx0 - px) + math.abs(ny0 - py)
                if pdist <= 4 and pdist > 0 then
                  local lastCurious = tonumber(npc._kantoLifeLastCurious) or 0
                  if now - lastCurious > 300 then
                    npc._kantoLifeLastCurious = now
                    local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
                    if bubbleUntil <= now then
                      npc._kantoLifeCollisionBubbleText = "?"
                      npc._kantoLifeCollisionBubbleUntil = now + 1.5
                    end
                  end
                end
              end
            end
            -- EXPERIMENTAL: NPCs adore Pokémon — humans near Pokémon NPCs show hearts.
            local npcDef = npc.def or {}
            if not npc.moving and not npcDef.johtoLifePokemon then
              local nx0, ny0 = tonumber(npc.cellX), tonumber(npc.cellY)
              if nx0 and ny0 then
                local lastAdore = tonumber(npc._kantoLifeLastAdore) or 0
                if now - lastAdore > 120 then
                  for _, other in ipairs(world.npcs or {}) do
                    if other ~= npc then
                      local od = other.def or {}
                      if od.johtoLifePokemon and not other.moving then
                        local ox, oy = tonumber(other.cellX), tonumber(other.cellY)
                        if ox and oy then
                          local odist = math.abs(ox - nx0) + math.abs(oy - ny0)
                          if odist <= 3 and odist > 0 then
                            npc._kantoLifeLastAdore = now
                            local dx, dy = ox - nx0, oy - ny0
                            if math.abs(dx) >= math.abs(dy) then
                              npc.facing = dx > 0 and "right" or "left"
                            else
                              npc.facing = dy > 0 and "down" or "up"
                            end
                            local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
                            if bubbleUntil <= now then
                              local adores = { "♥", "Cute!", "Aww!", "So cute!", "♥♥" }
                              npc._kantoLifeCollisionBubbleText = adores[math.random(1, #adores)]
                              npc._kantoLifeCollisionBubbleUntil = now + 1.5
                            end
                            break
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
            -- EXPERIMENTAL: companion bond — stay engaged with companion.
            local companion = npc._kantoLifeCompanion
            local companionUntil = tonumber(npc._kantoLifeCompanionUntil) or 0
            if companion and now < companionUntil and not npc.moving then
              local cx, cy = tonumber(companion.cellX), tonumber(companion.cellY)
              local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
              if cx and cy and nx and ny then
                local cdist = math.abs(cx - nx) + math.abs(cy - ny)
                if cdist <= 4 and cdist > 1 then
                  local dx, dy = cx - nx, cy - ny
                  if math.abs(dx) >= math.abs(dy) then
                    npc.facing = dx > 0 and "right" or "left"
                  else
                    npc.facing = dy > 0 and "down" or "up"
                  end
                end
              end
            end
            -- EXPERIMENTAL: startled reaction — NPCs notice when you sprint past.
            if playerRunning and not npc.moving then
              local nx0, ny0 = tonumber(npc.cellX), tonumber(npc.cellY)
              if nx0 and ny0 then
                local pdist = math.abs(nx0 - px) + math.abs(ny0 - py)
                if pdist <= 2 and pdist > 0 then
                  local lastStartle = tonumber(npc._kantoLifeLastStartle) or 0
                  if now - lastStartle > 15 then
                    npc._kantoLifeLastStartle = now
                    local bubbleUntil2 = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
                    if bubbleUntil2 <= now then
                      npc._kantoLifeCollisionBubbleText = "!"
                      npc._kantoLifeCollisionBubbleUntil = now + 1.0
                    end
                    local dx, dy = px - nx0, py - ny0
                    local face
                    if math.abs(dx) >= math.abs(dy) then
                      face = dx > 0 and "right" or "left"
                    else
                      face = dy > 0 and "down" or "up"
                    end
                    if face then npc.facing = face end
                  end
                end
              end
            end
            local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
            if bubbleUntil <= now then
              local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
              if nx and ny then
                local dist = math.abs(nx - px) + math.abs(ny - py)
                if dist <= 3 and dist > 0 then
                  local lastGreet = tonumber(npc._kantoLifeLastGreet) or 0
                  if now - lastGreet > 30 then
                    npc._kantoLifeLastGreet = now
                    -- EXPERIMENTAL: mood colors the greeting
                    local mood = getNpcMood(npc)
                    local moodPool = moodGreetings[mood]
                    if moodPool and math.random() < 0.6 then
                      npc._kantoLifeCollisionBubbleText = moodPool[math.random(1, #moodPool)]
                    else
                      npc._kantoLifeCollisionBubbleText = greetings[math.random(1, #greetings)]
                    end
                    npc._kantoLifeCollisionBubbleUntil = now + 2.0
                  end
                end
              end
            end
            -- Idle behavior: only when standing still
            if not npc.moving then
              local lastIdle = tonumber(npc._kantoLifeLastIdle) or 0
              if now - lastIdle > 25 + math.random() * 20 then
                npc._kantoLifeLastIdle = now
                local roll = math.random()
                if roll < 0.6 then
                  npc.facing = dirs[math.random(1, 4)]
                elseif roll < 0.7 and (timeOfDay == "morning" or timeOfDay == "afternoon") then
                  -- EXPERIMENTAL: happy humming — daytime NPCs sing a little
                  if bubbleUntil <= now then
                    local hums = { "♪", "♫", "La la~ ♪" }
                    npc._kantoLifeCollisionBubbleText = hums[math.random(1, #hums)]
                    npc._kantoLifeCollisionBubbleUntil = now + 1.5
                  end
                else
                  -- EXPERIMENTAL: contagious yawning
                  if bubbleUntil <= now then
                    local thought = idleThoughts[math.random(1, #idleThoughts)]
                    local recentYawn = world._kantoLifeRecentYawn
                    if recentYawn and now - (tonumber(recentYawn.at) or 0) < 5 then
                      local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
                      if nx and ny then
                        local ydx = math.abs(nx - (tonumber(recentYawn.x) or 999))
                        local ydy = math.abs(ny - (tonumber(recentYawn.y) or 999))
                        if ydx + ydy <= 4 and ydx + ydy > 0 and math.random() < 0.5 then
                          thought = "*yawn*"
                        end
                      end
                    end
                    npc._kantoLifeCollisionBubbleText = thought
                    npc._kantoLifeCollisionBubbleUntil = now + 1.5
                    if thought == "*yawn*" then
                      local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
                      if nx and ny then
                        world._kantoLifeRecentYawn = { x = nx, y = ny, at = now }
                      end
                    end
                    -- EXPERIMENTAL: random sneezes — nearby NPCs say "Bless you!"
                    if thought ~= "*yawn*" and math.random() < 0.02 then
                      local lastSneeze = tonumber(npc._kantoLifeLastSneeze) or 0
                      if now - lastSneeze > 300 then
                        npc._kantoLifeLastSneeze = now
                        npc._kantoLifeCollisionBubbleText = "Achoo!"
                        npc._kantoLifeCollisionBubbleUntil = now + 1.5
                        local sx, sy = tonumber(npc.cellX), tonumber(npc.cellY)
                        if sx and sy then
                          for _, other in ipairs(world.npcs or {}) do
                            if other ~= npc then
                              local d2 = other.def or {}
                              if d2.johtoLifeAmbient and not other.nightlifeSleeping and not other.moving then
                                local ox, oy = tonumber(other.cellX), tonumber(other.cellY)
                                if ox and oy then
                                  local odist = math.abs(ox - sx) + math.abs(oy - sy)
                                  if odist <= 3 and odist > 0 and math.random() < 0.7 then
                                    local obubble = tonumber(other._kantoLifeCollisionBubbleUntil) or 0
                                    if obubble <= now then
                                      other._kantoLifeCollisionBubbleText = "Bless you!"
                                      other._kantoLifeCollisionBubbleUntil = now + 1.5
                                    end
                                  end
                                end
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end)
      -- EXPERIMENTAL: NPC-to-NPC chatter — nearby idle NPCs exchange brief
      -- bubbles. One initiates, the other responds after a short delay.
      -- EXPERIMENTAL: group conversations — clusters of 3+ NPCs face the
      -- center, like they're having a group chat.
      pcall(function()
        local now2 = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
        local lastGroupScan = tonumber(world._kantoLifeLastGroupScan) or 0
        if now2 - lastGroupScan > 30 then
          world._kantoLifeLastGroupScan = now2
          local idleNpcs = {}
          for _, n in ipairs(world.npcs or {}) do
            local d = n.def or {}
            if d.johtoLifeAmbient and not n.nightlifeSleeping and not n.moving then
              local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
              if nx and ny then idleNpcs[#idleNpcs + 1] = n end
            end
          end
          local grouped = {}
          for i = 1, #idleNpcs do
            if not grouped[idleNpcs[i]] then
              local a = idleNpcs[i]
              local ax, ay = tonumber(a.cellX), tonumber(a.cellY)
              local cluster = { a }
              for j = 1, #idleNpcs do
                if i ~= j and not grouped[idleNpcs[j]] then
                  local b = idleNpcs[j]
                  local bx, by = tonumber(b.cellX), tonumber(b.cellY)
                  if math.abs(ax - bx) + math.abs(ay - by) <= 2 then
                    cluster[#cluster + 1] = b
                  end
                end
              end
              if #cluster >= 3 then
                local cx, cy = 0, 0
                for _, m in ipairs(cluster) do
                  cx = cx + tonumber(m.cellX)
                  cy = cy + tonumber(m.cellY)
                  grouped[m] = true
                end
                cx, cy = cx / #cluster, cy / #cluster
                for _, m in ipairs(cluster) do
                  local mx, my = tonumber(m.cellX), tonumber(m.cellY)
                  local dx, dy = cx - mx, cy - my
                  if math.abs(dx) >= math.abs(dy) then
                    m.facing = dx > 0 and "right" or (dx < 0 and "left" or m.facing)
                  else
                    m.facing = dy > 0 and "down" or (dy < 0 and "up" or m.facing)
                  end
                end
              end
            end
          end
        end
        for _, npc in ipairs(world.npcs or {}) do
          local replies = npc._kantoLifeChatReplies
          if replies and #replies > 0 then
            local kept = {}
            for _, r in ipairs(replies) do
              if tonumber(r.at) and now2 >= tonumber(r.at) then
                local deadConvos = world._kantoLifeChatDead
                local dead = deadConvos and deadConvos[r.convo]
                local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
                if not dead and bubbleUntil <= now2 and not npc.nightlifeSleeping
                   and not npc.moving and world.talkNpc ~= npc then
                  npc._kantoLifeCollisionBubbleText = r.text
                  npc._kantoLifeCollisionBubbleUntil = now2 + 2.0
                elseif not dead then
                  world._kantoLifeChatDead = deadConvos or {}
                  world._kantoLifeChatDead[r.convo] = true
                  local nDead = 0
                  for _ in pairs(world._kantoLifeChatDead) do nDead = nDead + 1 end
                  if nDead > 40 then world._kantoLifeChatDead = {} end
                end
              else
                kept[#kept + 1] = r
              end
            end
            npc._kantoLifeChatReplies = kept
          end
        end
        local lastChatScan = tonumber(world._kantoLifeLastChatScan) or 0
        if now2 - lastChatScan > 10 then
          world._kantoLifeLastChatScan = now2
          local hour = tonumber(os.date("%H")) or 12
          local chatOpeners = { "Hey!", "Hi there!", "Psst!", "Yo!", "Hiya!", "Hey you!" }
          if hour >= 5 and hour < 12 then
            chatOpeners[#chatOpeners + 1] = "Morning!"
            chatOpeners[#chatOpeners + 1] = "Good morning!"
          elseif hour >= 18 or hour < 5 then
            chatOpeners[#chatOpeners + 1] = "Evening!"
          end
          local chatReplies = { "Oh, hi!", "Hey!", "Hiya!", "What's up?", "Oh! Hi!", "Hey there!" }
          local chatFollowUps = {
            "Nice day, huh?", "Lovely weather!", "Hope it holds up.", "So windy today!",
            "Busy day?", "Almost lunchtime!", "Getting late...", "Long day, huh?",
            "Seen any rare ones?", "My team's doing great!", "Caught a new one!",
            "Been to GOLDENROD?", "Heard about TIN TOWER?", "Quiet around here.",
            "Heard the rumor?", "Busy lately, huh?",
          }
          local chatFarewells = { "See ya!", "Bye!", "Take care!", "Later!", "Well, bye!" }
          local function pick(t) return t[math.random(1, #t)] end
          local function chatBusy(npc)
            local pr = npc._kantoLifeChatReplies
            if pr and #pr > 0 then return true end
            return (tonumber(npc._kantoLifeChatUntil) or 0) > now2
          end
          local candidates = {}
          for _, npc in ipairs(world.npcs or {}) do
            local d = npc.def or {}
            if d.johtoLifeAmbient and not npc.nightlifeSleeping and not npc.moving
               and not npc._johtoRoutineTraveling and world.talkNpc ~= npc then
              local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
              if bubbleUntil <= now2 and not chatBusy(npc) then
                local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
                if nx and ny then candidates[#candidates + 1] = npc end
              end
            end
          end
          for i = 1, #candidates do
            local a = candidates[i]
            local ax, ay = tonumber(a.cellX), tonumber(a.cellY)
            for j = i + 1, #candidates do
              local b = candidates[j]
              local bx, by = tonumber(b.cellX), tonumber(b.cellY)
              if math.abs(ax - bx) + math.abs(ay - by) <= 2 then
                -- Per-pair cooldown (3 min) so the same two don't chatter constantly
                local aPairs = a._kantoLifeChatPartners or {}
                local pairLast = math.max(aPairs[b] or 0,
                  (b._kantoLifeChatPartners or {})[a] or 0)
                if now2 - pairLast > 180 then
                  a._kantoLifeLastChat = now2
                  b._kantoLifeLastChat = now2
                  aPairs[b] = now2
                  a._kantoLifeChatPartners = aPairs
                  local bPairs = b._kantoLifeChatPartners or {}
                  bPairs[a] = now2
                  b._kantoLifeChatPartners = bPairs
                  do
                    local nPairs = 0
                    for _ in pairs(aPairs) do nPairs = nPairs + 1 end
                    if nPairs > 24 then a._kantoLifeChatPartners = { [b] = now2 } end
                  end
                  -- Build the conversation: opener -> reply -> [follow-up] -> [farewell]
                  world._kantoLifeChatConvoSeq = (tonumber(world._kantoLifeChatConvoSeq) or 0) + 1
                  local convo = world._kantoLifeChatConvoSeq
                  local stepAt = now2 + 2.3
                  a._kantoLifeCollisionBubbleText = pick(chatOpeners)
                  a._kantoLifeCollisionBubbleUntil = now2 + 2.0
                  b._kantoLifeChatReplies = { { text = pick(chatReplies), at = stepAt, convo = convo } }
                  if math.random() < 0.65 then
                    stepAt = stepAt + 2.3
                    a._kantoLifeChatReplies = { { text = pick(chatFollowUps), at = stepAt, convo = convo } }
                    if math.random() < 0.7 then
                      stepAt = stepAt + 2.3
                      b._kantoLifeChatReplies[#b._kantoLifeChatReplies + 1] =
                        { text = pick(chatFarewells), at = stepAt, convo = convo }
                    end
                  end
                  a._kantoLifeChatUntil = stepAt + 1
                  b._kantoLifeChatUntil = stepAt + 1
                  -- EXPERIMENTAL: face each other while chatting
                  local dx2, dy2 = tonumber(b.cellX) - tonumber(a.cellX), tonumber(b.cellY) - tonumber(a.cellY)
                  if math.abs(dx2) >= math.abs(dy2) then
                    a.facing = dx2 > 0 and "right" or "left"
                    b.facing = dx2 > 0 and "left" or "right"
                  else
                    a.facing = dy2 > 0 and "down" or "up"
                    b.facing = dy2 > 0 and "up" or "down"
                  end
                  -- EXPERIMENTAL: walking companions
                  a._kantoLifeCompanion = b
                  b._kantoLifeCompanion = a
                  a._kantoLifeCompanionUntil = now2 + 300
                  b._kantoLifeCompanionUntil = now2 + 300
                  break
                end
              end
            end
            if a._kantoLifeLastChat == now2 then break end
          end
        end
      end)
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

      -- Sleep assignment owned solely by johtoSleepTick (accurate % + poke sleep).
      pcall(johtoSleepTick, world)

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
      local pool = name:find("ROUTE", 1, true) and routeLines or lines
      -- Unique dialogue: combinatorial generator with per-NPC history.
      -- Falls back to the static pool if the generator is unavailable.
      local text
      if DialogueGen and type(DialogueGen.generate) == "function" then
        local dexPool = nil
        pcall(function() dexPool = fullDexSpecies() end)
        local genOk, genLine, genHistory = pcall(DialogueGen.generate, {
          npcName = display,
          gender = d.johtoLifeGender,
          agenda = npc._johtoLifeAgenda,
          gen = 2,
          dex = dexPool,
          isPoke = false,
          recentLines = st.recentLines,
        })
        if genOk and type(genLine) == "string" and genLine ~= "" then
          text = genLine
          st.recentLines = genHistory
        end
      end
      if not text then
        text = pool[love.math.random(1, #pool)]
      end
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

    local _johtoSleepInvisibleSprite
    local _johtoCompositeCache = {}

    -- One card BA draws like any other NPC (same FP/TP sizing as default sleepers).
    local function bakeVoxelSleepComposite(npc)
      if not npc then return nil end
      local style = 0
      pcall(function() style = resolveSleepStyle(npc) end)
      style = math.floor(tonumber(style) or 0)

      local bodySrc = npc._johtoSleepBodyImage
      local spr = npc._johtoOrigSleepSprite or npc.sprite
      if not bodySrc and spr and not spr._johtoInvisible and not spr._johtoSleepComposite then
        if spr._johtoSleepBaked and spr.image then
          bodySrc = spr.image
        elseif type(spr.resolveImage) == "function" then
          local ok, r = pcall(spr.resolveImage, spr)
          if ok then bodySrc = r end
        else
          bodySrc = spr.image
        end
      end

      local prop = (style >= 1) and sleepPropImage(style) or nil
      local propBase = (style == 2 or style == 3) and sleepPropBaseImage(style) or nil
      if style == 1 and not prop then return nil end
      if style == 0 and not bodySrc then return nil end
      if (style == 2 or style == 3) and not (prop or propBase or bodySrc) then return nil end

      local cacheKey = tostring(npc) .. "#" .. tostring(style) .. "#"
        .. tostring(bodySrc) .. "#" .. tostring(prop) .. "#" .. tostring(propBase)
      if _johtoCompositeCache[cacheKey] then return _johtoCompositeCache[cacheKey] end

      local SIZE = 16
      local okC, canvas = pcall(function()
        local c = love.graphics.newCanvas(SIZE, SIZE)
        local prev = love.graphics.getCanvas()
        love.graphics.setCanvas(c)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setColor(1, 1, 1, 1)
        local function blit(img, scaleMul)
          if not img or type(img.getDimensions) ~= "function" then return end
          local iw, ih = img:getDimensions()
          -- scaleMul is a multiplier on the fit-to-SIZE scale (not an absolute
          -- scale): blit(bodySrc, 0.85) draws the body at 85% of its fitted
          -- size instead of overflowing the 16x16 canvas.
          local s = (SIZE / math.max(iw, ih, 1)) * (scaleMul or 1)
          local dx = (SIZE - iw * s) / 2
          local dy = (SIZE - ih * s) / 2
          love.graphics.draw(img, dx, dy, 0, s, s)
        end
        if style == 1 then
          blit(prop)
        elseif style == 2 or style == 3 then
          if propBase then blit(propBase) end
          if bodySrc then blit(bodySrc, 0.85) end
          if prop then blit(prop) end
        else
          if bodySrc then blit(bodySrc) end
        end
        love.graphics.setCanvas(prev)
        pcall(c.setFilter, c, "nearest", "nearest")
        return c
      end)
      if not (okC and canvas) then return nil end

      local qok, q = pcall(love.graphics.newQuad, 0, 0, SIZE, SIZE, SIZE, SIZE)
      local comp = {
        image = canvas,
        frames = qok and { [0] = q } or nil,
        frameWidth = SIZE,
        frameHeight = SIZE,
        frameCount = 1,
        def = {
          id = "JOHTO_LIFE_SLEEP_COMPOSITE",
          image = canvas,
          frames = 1,
          frameWidth = SIZE,
          frameHeight = SIZE,
          trueColor = true,
          walker = false,
        },
        _johtoSleepComposite = true,
        _johtoSleepBaked = true,
        resolveImage = function(self) return self.image end,
      }
      _johtoCompositeCache[cacheKey] = comp
      npc._johtoVoxelSleepComposite = comp
      return comp
    end

    local function isVoxelPresentation()
      -- Any Battle Art / Dramatic Shape voxel level other than OFF
      local names = {
        "DRAMATIC_SHAPE", "DRAMALESS_SHAPE", "BATTLE_ART_VOXEL", "BATTLE_ART_VOXEL_FORK",
        "BATTLE_ART_VOXEL_GEN2",
        "battle_art_voxel", "BattleArtVoxel", "POTATO_VOXEL", "PotatoVoxel", "potato_voxel",
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
    -- Accessories re-enabled (1.4.45)
    local style = math.floor(tonumber(opt("sleep_style")) or 0)
    if style == 5 then
      -- Natural mirrors Kanto: tent outdoors, bed in houses, and sleeping
      -- bag/default for other interiors. Resolve once per sleep session.
      local cached = npc.kantoLifeNaturalSleepStyle
      if cached ~= nil then return cached end
      local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
      local map = ow and ow.map
      local id = tostring(map and map.id or ""):upper()
      if not isIndoor(id, map) then cached = 1
      elseif id:find("HOUSE", 1, true) or id:find("HOME", 1, true) then cached = 3
      else cached = (math.random(100) <= 80) and 2 or 0 end
      npc.kantoLifeNaturalSleepStyle = cached
      return cached
    end
    if style ~= 4 then return style end
    local cached = npc.kantoLifeRandomSleepStyle
    if cached == nil then
      cached = math.random(0, 3)
      npc.kantoLifeRandomSleepStyle = cached
    end
    return cached
  end
    -- Draw the opaque base layer UNDER the NPC (3-layer system).
    -- Handles BOTH Gen2 NPC:draw forms:
    --   scale ~= nil  → translate(ox,oy); scale(s); world-space draw
    --   scale == nil  → cam form: screen = world - cam (ox,oy are camX,camY)
    local function propScreenXY(self, ox, oy, scale)
      local px = (type(self.px) == "number" and self.px)
        or ((self.cellX or 0) * 16)
      local py = (type(self.py) == "number" and self.py)
        or ((self.cellY or 0) * 16)
      -- Exact 16×16 tile center used by the engine NPC sprite (top-left at
      -- px,py; center at px+8,py+8). All three layers share this point.
      local cx, cy = px + 8, py + 8
      if scale == nil then
        return cx - (ox or 0), cy - (oy or 0), 1
      end
      return cx, cy, scale
    end
    -- Shared camera/world transform for every sleep layer so base, body, and
    -- overlay all pivot on the exact same point (px+8, py+8).
    local function pushSleepTransform(self, ox, oy, scale)
      love.graphics.push("all")
      love.graphics.setColor(1, 1, 1, 1)
      if scale ~= nil then
        love.graphics.translate(ox or 0, oy or 0)
        if scale ~= 1 then love.graphics.scale(scale, scale) end
      else
        -- Cam form: screen = world - cam
        love.graphics.translate(-(ox or 0), -(oy or 0))
      end
    end
    local function sleepTileCenter(self)
      local px = (type(self.px) == "number" and self.px) or ((self.cellX or 0) * 16)
      local py = (type(self.py) == "number" and self.py) or ((self.cellY or 0) * 16)
      return px + 8, py + 8
    end
    local function drawSleepAccessoryBase(self, ox, oy, scale)
      if not self.nightlifeSleeping then return end
      local style = resolveSleepStyle(self)
      if style == 0 or style == 1 then return end
      local img = sleepPropBaseImage(style); if not img then return end
      local iw, ih = img:getDimensions()
      local angle = self.johtoLifeSleepAngle or (math.pi / 2)
      local cx, cy = sleepTileCenter(self)
      pushSleepTransform(self, ox, oy, scale)
      love.graphics.draw(img, cx, cy, angle, 1, 1, iw / 2, ih / 2)
      love.graphics.pop()
    end
    local function drawSleepAccessory(self, ox, oy, scale)
      if not self.nightlifeSleeping then return end
      local style = resolveSleepStyle(self)
      if style == 0 then return end
      local img = sleepAccessoryImage(style); if not img then return end
      local iw, ih = img:getDimensions()
      local angle = self.johtoLifeSleepAngle or (math.pi / 2)
      local cx, cy = sleepTileCenter(self)
      pushSleepTransform(self, ox, oy, scale)
      local rot = (style == 2 or style == 3) and angle or 0
      love.graphics.draw(img, cx, cy, rot, 1, 1, iw / 2, ih / 2)
      love.graphics.pop()
    end
    -- Draw the baked sleeper at the SAME center as the props (not via baseDraw
    -- which can use a different origin). Keeps the 3-layer stack locked.
    local function drawSleepBodyCentered(self, ox, oy, scale)
      local spr = self.sprite
      if not spr then return end
      local img = spr.image
      if type(spr.resolveImage) == "function" then
        local ok, r = pcall(spr.resolveImage, spr)
        if ok and r then img = r end
      end
      if not img then return end
      local fw = tonumber(spr.frameWidth) or 16
      local fh = tonumber(spr.frameHeight) or 16
      local quad = spr.frames and (spr.frames[0] or spr.frames[1])
      local cx, cy = sleepTileCenter(self)
      pushSleepTransform(self, ox, oy, scale)
      if quad then
        love.graphics.draw(img, quad, cx, cy, 0, 1, 1, fw / 2, fh / 2)
      else
        love.graphics.draw(img, cx, cy, 0, 1, 1, fw / 2, fh / 2)
      end
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
      -- Match engine Gen2 NPC:draw(ox, oy, scale):
      --   if scale==nil then draw(-(ox),-(oy),1)  -- cam → screen offset
      --   else translate(ox,oy); scale(s); draw in world px
      local px = (self.px ~= nil) and self.px or ((self.cellX or 0) * 16)
      local py = (self.py ~= nil) and self.py or ((self.cellY or 0) * 16)
      local s = tonumber(scale)
      if s == nil then
        ox, oy, s = -(ox or 0), -(oy or 0), 1
      end
      local font = G.getFont()
      local tw, th = font:getWidth(text), font:getHeight()
      local w, h = math.max(22, tw + 10), math.max(13, th + 5)
      G.push("all")
      G.translate(ox or 0, oy or 0)
      if s ~= 1 then G.scale(s, s) end
      local cx = px + 8
      local cy = py - 16 + (tonumber(self.spriteYOffset) or 0)
      local x = math.floor(cx - w / 2)
      local y = math.floor(cy - h - 4)
      G.setColor(1,1,1,1); G.rectangle("fill",x,y,w,h,2,2)
      G.setColor(0.1,0.1,0.1,1); G.rectangle("line",x,y,w,h,2,2)
      G.polygon("fill",x+w/2-2,y+h,x+w/2+2,y+h,x+w/2,y+h+3)
      G.setColor(0.1,0.1,0.1,1)
      G.print(text, cx - tw/2, y + (h-th)/2)
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
        local ok, npcMod = pcall(require, path)
        if ok and npcMod and type(npcMod.draw) == "function" then
          NPC = npcMod
          break
        end
      end
      if not (NPC and type(NPC.draw) == "function") then return end
      -- Re-wrap on each mod load so bugfixes apply; unwrap prior Johto wrap first.
      if NPC._johtoLifeZzzWrapped and type(NPC._johtoLifeZzzBaseDraw) == "function" then
        NPC.draw = NPC._johtoLifeZzzBaseDraw
        NPC._johtoLifeZzzWrapped = nil
      end
      local baseDraw = NPC.draw
      NPC._johtoLifeZzzBaseDraw = baseDraw
      NPC.draw = function(self, ox, oy, scale)
        -- Teleport spins then rises; Fly lifts and drifts away. Keep the map
        -- cell untouched and apply a temporary pixel-space render offset only.
        -- Also swap the sprite for a random flying/psychic mon when available.
        local travel = self and self._johtoLifeTravelAnim
        if travel then
          local frame = tonumber(travel.frame) or 0
          local total = tonumber(travel.total) or 72
          local progress = math.max(0, math.min(1, frame / total))
          local lift = progress * progress * (travel.kind == "fly" and 140 or 100)
          local drift = travel.kind == "fly" and progress * 48 or 0
          local oldPx, oldPy, oldFacing, oldSprite = self.px, self.py, self.facing, self.sprite
          self.px = (tonumber(travel.basePx) or tonumber(self.px) or 0) + drift
          self.py = (tonumber(travel.basePy) or tonumber(self.py) or 0) - lift
          if travel.kind == "teleport" then
            self.facing = ({"down", "left", "up", "right"})[(math.floor(frame / 3) % 4) + 1]
          end
          -- Reuse the pose-path mon sprite if pose wrap already built it.
          if type(NPC.pose) == "function" then
            local okP, spr = pcall(function()
              local s = select(1, NPC.pose(self))
              return s
            end)
            if okP and spr and spr ~= oldSprite then self.sprite = spr end
          end
          local okTravel, result = pcall(baseDraw, self, ox, oy, scale)
          self.px, self.py, self.facing, self.sprite = oldPx, oldPy, oldFacing, oldSprite
          if not okTravel then error(result, 0) end
          return result
        end
        -- The native 2D path calls draw(self, camX, camY) without a scale.
        -- Keep that signature, but layer in the same props/bubbles as the
        -- scaled path; previously this early return skipped both entirely.
        if scale == nil then
          local r = nil
          local sleeping = self and self.nightlifeSleeping
          if sleeping then
            local style = resolveSleepStyle(self)
            if isVoxelPresentation() then
              if style ~= 1 then r = baseDraw(self, ox, oy) end
            else
              if style ~= 1 and style ~= 0 then
                pcall(drawSleepAccessoryBase, self, ox, oy, nil)
              end
              if style ~= 1 then
                if self.sprite and self.sprite._johtoSleepBaked then
                  pcall(drawSleepBodyCentered, self, ox, oy, nil)
                  r = true
                else
                  r = baseDraw(self, ox, oy)
                end
              end
              pcall(drawSleepAccessory, self, ox, oy, nil)
              drawZzzForNpc(self, ox, oy, nil)
            end
          else
            r = baseDraw(self, ox, oy)
            local cbUntil = tonumber(self and self._kantoLifeCollisionBubbleUntil) or 0
            local cbNow = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
            if cbUntil > cbNow then pcall(drawCollisionBubble, self, ox, oy, nil) end
          end
          return r
        end

        local sleeping = self.nightlifeSleeping
        local voxel = isVoxelPresentation()
        local angle = self.johtoLifeSleepAngle or (math.pi / 2)
        -- Sprite assets can still be resolving when an NPC first enters sleep.
        -- The old 1.0.0 baked-sprite path is the voxel-compatible source of truth;
        -- retry until it succeeds instead of leaving the standing sprite forever.
        if sleeping and self.sprite and not self.sprite._johtoSleepBaked then
          pcall(bakeRotatedSleepSprite, self)
        end
        local baked = self.sprite and self.sprite._johtoSleepBaked

        -- Baked lying sprite: normal draw path (same idea as SPRITE_GAMBLER_ASLEEP)
        if sleeping and baked then
          local style = resolveSleepStyle(self)
          -- In voxel, NPC:draw is not the presentation path — pose + worldPresent
          -- own the body and props. Drawing 2D props here paints on the wrong
          -- canvas and produces the offset floating tents.
          if voxel then
            -- All accessory styles are owned by worldPresent (underlay/body/overlay).
            -- Drawing here double-paints the BA body and fights the prop stack.
            if style >= 1 then return nil end
            return baseDraw(self, ox, oy, scale)
          end
          local r = nil
          -- 2D: all three layers share sleepTileCenter (px+8, py+8).
          if style ~= 1 and style ~= 0 then
            pcall(drawSleepAccessoryBase, self, ox, oy, scale)
          end
          if style ~= 1 then
            pcall(drawSleepBodyCentered, self, ox, oy, scale)
            r = true
          end
          pcall(drawSleepAccessory, self, ox, oy, scale)
          drawZzzForNpc(self, ox, oy, scale)
          return r
        end

        -- Voxel (or missing sprite): must use baseDraw so figures still appear
        if sleeping and (not voxel) and self.sprite and type(self.sprite.draw) == "function" then
          local style = resolveSleepStyle(self)
          if style ~= 1 then
            local px, py = self.px or 0, self.py or 0
            local okRot = pcall(function()
              local G = love.graphics
              G.push()
              G.translate(ox or 0, oy or 0)
              if scale and scale ~= 1 then G.scale(scale, scale) end
              local cx, cy = px + 8, py + 8
              G.translate(cx, cy)
              G.rotate(angle)
              G.translate(-cx, -cy)
              G.setColor(0.55, 0.55, 0.60, 1)
              self.sprite:draw(px, py, 0, 0, "down", 0, false, false, false, nil)
              G.setColor(1, 1, 1, 1)
              G.pop()
            end)
            if not okRot then
              baseDraw(self, ox, oy, scale)
            end
          end
          if style ~= 1 and style ~= 0 then
            pcall(drawSleepAccessoryBase, self, ox, oy, scale)
          end
          pcall(drawSleepAccessory, self, ox, oy, scale)
        else
          baseDraw(self, ox, oy, scale)
          pcall(drawSleepAccessory, self, ox, oy, scale)
        end

        if not voxel then
          drawZzzForNpc(self, ox, oy, scale)
        end
        -- Draw collision bubble for awake NPCs
        local cbUntil = tonumber(self._kantoLifeCollisionBubbleUntil) or 0
        local cbNow = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
        if cbUntil > cbNow then
          pcall(drawCollisionBubble, self, ox, oy, scale)
        end
      end
      -- Voxel renderers consume NPC:pose(), not NPC:draw(). Mirror the travel
      -- offsets there so Fly/Teleport are visible in voxel mode as well.
      -- Also substitute a random flying/psychic menu-icon sprite for the mon.
      if type(NPC.pose) == "function" and not NPC._johtoLifeTravelPoseWrapped then
        local basePose = NPC.pose
        local travelSpriteCache = {}
        local function travelPokemonSprite(species)
          if type(species) ~= "string" or species == "" then return nil end
          species = tostring(species):upper():gsub(" ", "_"):gsub("'", "")
          if travelSpriteCache[species] then return travelSpriteCache[species] end
          local okRenderer, Renderer = pcall(require, "src.render.SpriteRenderer")
          if not (okRenderer and Renderer and type(Renderer.new) == "function") then return nil end
          local g = G()
          local data = g and g.data
          local sprites = data and data.sprites

          local function accept(spr)
            if spr then travelSpriteCache[species] = spr; return spr end
            return nil
          end

          -- 1) Registry overworld sprites.
          -- HGSS_SPRITES registers Gen 2 Pokemon under SPRITE_HGSS_GEN2_<SPECIES>
          -- (35 canonical species keep SPRITE_<SPECIES>). Try the HGSS id FIRST
          -- so HGSS art wins over any default-art def when the mod is on; the
          -- order-arbitrary fuzzy scan below must never shadow it.
          local candidates = {
            "SPRITE_HGSS_GEN2_" .. species,
            "SPRITE_" .. species, species, "SPRITE_POKEMON_" .. species,
            "SPRITE_POKE_" .. species,
          }
          if sprites then
            for _, id in ipairs(candidates) do
              local def = sprites[id]
              if type(def) == "table" then
                local okS, spr = pcall(Renderer.new, def)
                if okS and accept(spr) then return spr end
              end
            end
            for id, def in pairs(sprites) do
              local up = tostring(id):upper()
              if up:find(species, 1, true) and not up:find("BACK", 1, true)
                 and not up:find("TRAINER", 1, true)
                 and type(def) == "table" then
                local okS, spr = pcall(Renderer.new, def)
                if okS and accept(spr) then return spr end
              end
            end
          end

          -- 2) Prefer registry defs already patched by HGSS_SPRITES
          if sprites then
            local best
            for id, def in pairs(sprites) do
              local up = tostring(id):upper()
              if type(def) == "table" and up:find(species, 1, true)
                 and not up:find("BACK", 1, true)
                 and not up:find("TRAINER", 1, true) then
                if def.hgssNativeImage or def.hgssVoxelWidth or def.hgssFrameWidth then
                  local okS, spr = pcall(Renderer.new, def)
                  if okS and accept(spr) then return spr end
                end
                if not best then best = def end
              end
            end
          end

          -- 3) Load HGSS pokemon-overworld sheet by national dex number
          pcall(function()
            local hgss = mod.find("HGSS_SPRITES")
            if not hgss then
              for _, id in ipairs({"HGSS_SPRITES", "hgss_sprites", "HGSS Visual Overhaul"}) do
                local ok, m = pcall(function() return mod.find(id) end)
                if ok and m then hgss = m; break end
              end
            end
            if not (hgss and hgss.assets and type(hgss.assets.path) == "function") then return end

            local DEX = {
              PIDGEY=16,PIDGEOTTO=17,PIDGEOT=18,SPEAROW=21,FEAROW=22,FARFETCHD=83,FARFETCH_D=83,
              DODUO=84,DODRIO=85,CHARIZARD=6,AERODACTYL=142,DRAGONITE=149,BUTTERFREE=12,
              ZUBAT=41,GOLBAT=42,CROBAT=169,VENOMOTH=49,SCYTHER=123,GYARADOS=130,
              ARTICUNO=144,ZAPDOS=145,MOLTRES=146,HOOTHOOT=163,NOCTOWL=164,NATU=177,XATU=178,
              SKARMORY=227,MURKROW=198,GLIGAR=207,MANTINE=226,TOGETIC=176,LUGIA=249,HO_OH=250,
              ABRA=63,KADABRA=64,ALAKAZAM=65,SLOWPOKE=79,SLOWBRO=80,SLOWKING=199,
              DROWZEE=96,HYPNO=97,EXEGGCUTE=102,EXEGGUTOR=103,STARYU=120,STARMIE=121,
              MR_MIME=122,JYNX=124,SMOOCHUM=238,ESPEON=196,UNOWN=201,WOBBUFFET=202,
              GIRAFARIG=203,MEWTWO=150,MEW=151,CELEBI=251,
            }
            local num = DEX[species]
            local pdef = data and data.pokemon and data.pokemon[species]
            if type(pdef) == "table" then
              num = num or tonumber(pdef.number or pdef.dex or pdef.nationalDex or pdef.natDex or pdef.id)
            end
            if not num and type(data) == "table" and data.pokemon then
              for k, v in pairs(data.pokemon) do
                if type(k) == "string" and k:upper():gsub(" ", "_") == species and type(v) == "table" then
                  num = tonumber(v.number or v.dex or v.nationalDex)
                  break
                end
              end
            end
            if not num then return end
            local rel = string.format("assets/gen2/pokemon-overworld/%03d-normal.png", num)
            local path = hgss.assets:path(rel)
            if not path then
              rel = string.format("assets/gen2/pokemon-overworld/%d-normal.png", num)
              path = hgss.assets:path(rel)
            end
            if not path then return end
            local okI, img = pcall(love.graphics.newImage, path)
            if not (okI and img) then return end
            pcall(img.setFilter, img, "nearest", "nearest")
            local iw, ih = img:getDimensions()
            local fw, fh = math.min(32, iw), math.min(32, ih)
            local okC, canvas = pcall(function()
              local c = love.graphics.newCanvas(16, 16)
              local prev = love.graphics.getCanvas()
              love.graphics.setCanvas(c)
              love.graphics.clear(0, 0, 0, 0)
              love.graphics.setColor(1, 1, 1, 1)
              local q = love.graphics.newQuad(0, 0, fw, fh, iw, ih)
              love.graphics.draw(img, q, 0, 0, 0, 16 / fw, 16 / fh)
              love.graphics.setCanvas(prev)
              return c
            end)
            if not (okC and canvas) then return end
            -- Register canvas so SpriteRenderer/Assets can resolve it
            local imgKey = "johto_life_travel_hgss_" .. species
            pcall(function()
              local okA, Assets = pcall(require, "src.render.Assets")
              if okA and Assets then
                if not Assets._johtoTravelHooked and type(Assets.image) == "function" then
                  local baseImg = Assets.image
                  local bag = {}
                  Assets.image = function(p, ...)
                    if bag[p] then return bag[p] end
                    if type(p) == "string" and p:find("johto_life_travel_hgss_", 1, true) then
                      return canvas
                    end
                    return baseImg(p, ...)
                  end
                  Assets._johtoTravelHooked = true
                  Assets._johtoTravelBag = bag
                end
                if Assets._johtoTravelBag then Assets._johtoTravelBag[imgKey] = canvas end
              end
            end)
            local def = {
              id = "SPRITE_JOHTO_TRAVEL_HGSS_" .. species,
              image = imgKey,
              frames = 1, walker = false, trueColor = true,
              frameWidth = 16, frameHeight = 16,
              spriteType = "POKEMON_SPRITE", species = species,
            }
            local okS, spr = pcall(Renderer.new, def)
            if not (okS and spr) then
              def.image = canvas
              okS, spr = pcall(Renderer.new, def)
            end
            if okS and accept(spr) then return end
          end)
          if travelSpriteCache[species] then return travelSpriteCache[species] end

          -- 3) Live ambient of same species
          pcall(function()
            local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
            for _, n in ipairs((ow and ow.npcs) or {}) do
              local mon = (n.def and (n.def.species or n.def.johtoLifeSpecies or n.def.kantoLifeSpecies))
                or n.species or n.johtoLifeSpecies
              if mon and tostring(mon):upper():gsub(" ", "_"):gsub("'", "") == species and n.sprite then
                accept(n.sprite)
                return
              end
            end
          end)
          if travelSpriteCache[species] then return travelSpriteCache[species] end

          -- 4) Battle front / icon synthesised to 16x16
          local pdef = data and data.pokemon and data.pokemon[species]
          if type(pdef) == "table" then
            local img = pdef.front or pdef.frontSprite or pdef.icon or pdef.menuIcon or pdef.image
            if type(img) == "string" and sprites and sprites[img] then
              img = sprites[img].image or img
            end
            if img then
              local okC, canvas = pcall(function()
                local src = img
                if type(src) == "string" then
                  local okI, i = pcall(love.graphics.newImage, src)
                  if okI then src = i else return nil end
                end
                if type(src.getDimensions) ~= "function" then return nil end
                local sw, sh = src:getDimensions()
                local c = love.graphics.newCanvas(16, 16)
                local prev = love.graphics.getCanvas()
                love.graphics.setCanvas(c)
                love.graphics.clear(0, 0, 0, 0)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(src, 0, 0, 0, 16 / math.max(1, sw), 16 / math.max(1, sh))
                love.graphics.setCanvas(prev)
                return c
              end)
              if okC and canvas then
                local def = {
                  id = "SPRITE_JOHTO_TRAVEL_SYN_" .. species,
                  image = canvas, frames = 1, walker = false,
                  trueColor = true, frameWidth = 16, frameHeight = 16,
                  spriteType = "POKEMON_SPRITE", species = species,
                }
                local okS, spr = pcall(Renderer.new, def)
                if okS and accept(spr) then return spr end
              end
            end
          end

          -- 5) gen2 menu icon last resort
          local icons = data and data.gen2Icons
          local iconId = icons and icons.species and icons.species[species]
          local entry = iconId and icons.icons and icons.icons[iconId]
          if entry and entry.image then
            local def = {
              id = "SPRITE_JOHTO_TRAVEL_MON_" .. species,
              image = entry.image, frames = entry.frames or 2, walker = false,
              spriteType = "POKEMON_SPRITE",
              palette = entry.palette or "PAL_OW_RED",
              paletteId = entry.paletteId or 0, species = species,
            }
            local okS, spr = pcall(Renderer.new, def)
            if okS and accept(spr) then return spr end
          end
          return nil
        end


        NPC.pose = function(self, ...)
          if self and self.nightlifeSleeping and self.sprite and not self.sprite._johtoInvisible then
            if not self.sprite._johtoSleepBaked then
              pcall(bakeRotatedSleepSprite, self)
            end
            if self.sprite and self.sprite._johtoSleepBaked and self.sprite.image then
              self._johtoSleepBodyImage = self.sprite.image
              self._johtoOrigSleepSprite = self._johtoOrigSleepSprite or self.sprite
            end
          end
          local sprite, px, py, facing, phase, flip, extra = basePose(self, ...)
          -- Voxel owns layering for tent/bed/bag via worldPresent drawPropAt.
          -- Hide the engine billboard so it does not sit under the underlay
          -- (or show beside a tent). drawPropAt paints underlay → body → overlay.
          if self and self.nightlifeSleeping and isVoxelPresentation() then
            local style = 0
            pcall(function() style = resolveSleepStyle(self) end)
            style = math.floor(tonumber(style) or 0)
            -- Voxel: return a single composite card (prop + body) so Battle Art
            -- draws it through the SAME drawEntity/billboard path as default
            -- sleepers — no custom matrices, no FP/TP shrink.
            if style >= 0 then
              if self.sprite and not self.sprite._johtoSleepComposite and not self.sprite._johtoInvisible then
                self._johtoOrigSleepSprite = self._johtoOrigSleepSprite or self.sprite
              end
              local comp = nil
              pcall(function() comp = bakeVoxelSleepComposite(self) end)
              if comp then
                if _G._johtoLifeTagSleeperSprite then
                  pcall(_G._johtoLifeTagSleeperSprite, comp, self)
                end
                return comp, px, py, facing, 0, false, extra
              end
            end
          elseif self and self._johtoLifeSavedVisible then
            self.visible = true
            self._johtoLifeSavedVisible = nil
            self._johtoLifeVoxelSleepHidden = nil
          elseif self then
            self._johtoLifeVoxelSleepHidden = nil
          end
          local travel = self and self._johtoLifeTravelAnim
          if not travel then return sprite, px, py, facing, phase, flip, extra end
          local frame = tonumber(travel.frame) or 0
          local total = tonumber(travel.total) or 72
          local progress = math.max(0, math.min(1, frame / total))
          local lift = progress * progress * (travel.kind == "fly" and 140 or 100)
          local drift = travel.kind == "fly" and progress * 48 or 0
          if travel.kind == "teleport" then
            facing = ({"down", "left", "up", "right"})[(math.floor(frame / 3) % 4) + 1]
          end
          local mon = travelPokemonSprite(travel.species)
          return mon or sprite, (tonumber(px) or 0) + drift, (tonumber(py) or 0) - lift, facing, phase or 0, flip, extra
        end
        NPC._johtoLifeTravelPoseWrapped = true
      end
      NPC._johtoLifeZzzWrapped = true
    end)

    -- =====================================================================
    -- Gen2 VOXEL sleep props + bubbles
    --
    -- Root cause of "props vanished" in 1.4.202–203:
    --   Voxel3D was resolved once at install. If Battle Art was not ready yet,
    --   project() never worked, and the "projection-only" gate drew nothing.
    --   Path B then set a flag that suppressed Path A even when CR drew zero.
    --
    -- Fix: lazy-resolve Voxel3D every frame; always draw props when we can
    -- project OR when we have a valid scene canvas + cam from ctx; never let
    -- Path B suppress Path A.
    -- =====================================================================
    pcall(function()
      local Pipelines = nil
      pcall(function() Pipelines = require("src.render.Pipelines") end)

      local function resolveVoxel3D()
        -- Cache on _G so hot-reloads can refresh by nil-ing the cache.
        if _G._johtoLifeVoxel3D and type(_G._johtoLifeVoxel3D.project) == "function" then
          return _G._johtoLifeVoxel3D, _G._johtoLifeVoxelLib
        end
        if type(mod.find) ~= "function" then return nil, nil end
        local ids = {
          "BATTLE_ART_VOXEL_GEN2", "BATTLE_ART_VOXEL_FORK", "BATTLE_ART_VOXEL",
          "battle_art_voxel", "BattleArtVoxel", "DRAMATIC_SHAPE",
          "POTATO_VOXEL", "PotatoVoxel", "potato_voxel",
        }
        -- Prefer pipeline owner when known (NPC Bubbles approach)
        pcall(function()
          local data = (mod.world and mod.world.game and mod.world.game.data)
            or (mod.game and mod.game.data)
          local owners = data and data.render_pipelines and data.render_pipelines._owners
          if type(owners) == "table" and type(owners.voxel) == "string" and owners.voxel ~= "" then
            table.insert(ids, 1, owners.voxel)
          end
        end)
        for _, id in ipairs(ids) do
          local ok, ba = pcall(mod.find, id)
          local lib = ok and ba and (ba.lib or (ba.exports and ba.exports.lib)) or nil
          if lib and type(lib.require) == "function" then
            local okV, V3 = pcall(lib.require, "Voxel3D")
            if okV and type(V3) == "table" and type(V3.project) == "function" then
              _G._johtoLifeVoxel3D = V3
              _G._johtoLifeVoxelLib = lib
              _G._johtoLifeBattleArtMod = ba
              return V3, lib
            end
          end
        end
        return nil, nil
      end

      local function collectSleepers()
        local out, seen = {}, {}
        local function add(list)
          for _, n in ipairs(list or {}) do
            if n and n.nightlifeSleeping and not seen[n] then
              seen[n] = true; out[#out + 1] = n
            end
          end
        end
        pcall(function()
          local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
          if ow then add(ow.npcs); add(ow.entities) end
        end)
        return out
      end

      local function sceneProjDiv(V3, canvas)
        local projDiv = 1
        if not (canvas and V3 and type(V3.size) == "function") then return projDiv end
        local okC, cw = pcall(canvas.getWidth, canvas)
        if not (okC and tonumber(cw) and cw > 0) then return projDiv end
        local okS, sceneW = pcall(V3.size)
        if okS and tonumber(sceneW) and sceneW > 0 then
          projDiv = sceneW / cw
        end
        if not (projDiv > 0) then projDiv = 1 end
        return projDiv
      end

      local function projectNpc(npc, canvas)
        local V3 = resolveVoxel3D()
        if not (V3 and type(V3.project) == "function") then
          return nil, nil, false
        end
        local px = tonumber(npc.px) or ((npc.cellX or 0) * 16)
        local py = tonumber(npc.py) or ((npc.cellY or 0) * 16)
        local gh = tonumber(npc.groundHeight) or tonumber(npc._groundHeight) or 0
        -- Project at tile center slightly above ground so props center on NPC.
        local ok, sx, sy = pcall(V3.project, px + 8, gh + 6, py + 8)
        if not (ok and type(sx) == "number" and type(sy) == "number") and gh ~= 0 then
          ok, sx, sy = pcall(V3.project, px + 8, 6, py + 8)
        end
        if not (ok and type(sx) == "number" and type(sy) == "number") then
          return nil, nil, false
        end
        local projDiv = sceneProjDiv(V3, canvas)
        return sx / projDiv, sy / projDiv, true
      end

      local function canvasScale(canvas, ctx)
        local ok, w = pcall(function() return canvas and canvas.getWidth and canvas:getWidth() end)
        local vw = ctx and tonumber(ctx.vw)
        if not (vw and vw > 0) then vw = 160 end
        if ok and tonumber(w) and w > 0 then
          local s = w / vw
          if s > 0 then return s end
        end
        return tonumber(ctx and ctx.scale) or 1
      end

      local function drawFloatingZ(Gfx, sx, sy, scale, npc)
        -- Same animated Zzz as drawSleepZzz (pre-230). Do not replace with static letters.
        local v = opt("sleep_bubbles")
        if v == false then return end
        local seed = 0
        if npc then
          local x = tonumber(npc.cellX or npc.x) or 0
          local y = tonumber(npc.cellY or npc.y) or 0
          seed = math.floor(x * 17 + y * 31) % 1000
        end
        local side = (seed % 2 == 0) and -1 or 1
        local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
        local s = math.max(0.85, (tonumber(scale) or 1) * 0.9)
        Gfx.push("all")
        for i = 0, 2 do
          local phase = t * 1.5 + i * 0.75 + seed * 0.05
          local cycle = phase % 2.5
          local rise = cycle * 4
          local alpha = 1 - cycle / 2.5
          if alpha > 0.25 then
            local sc = (0.7 + i * 0.2) * s
            local zx = sx + side * (3 + i * 3) * s
            local zy = sy - 6 * s - rise * s - i * 2 * s
            Gfx.setColor(1, 1, 1, alpha)
            Gfx.print("Z", zx - 1, zy, 0, sc, sc)
            Gfx.print("Z", zx + 1, zy, 0, sc, sc)
            Gfx.print("Z", zx, zy - 1, 0, sc, sc)
            Gfx.print("Z", zx, zy + 1, 0, sc, sc)
            Gfx.setColor(0.1, 0.05, 0.3, alpha)
            Gfx.print("Z", zx, zy, 0, sc, sc)
          end
        end
        Gfx.setColor(1, 1, 1, 1)
        Gfx.pop()
      end

      -- Voxel 3-layer at projected body center:
      --   tent (1): tent only (engine body hidden in pose)
      --   bag/bed (2/3): underlay → baked body → overlay (engine body hidden)
      -- Hiding the engine billboard prevents the "sprite under the bed" look.
      local function drawPropAt(Gfx, npc, sx, sy, scale)
        local style = 0
        pcall(function() style = resolveSleepStyle(npc) end)
        style = math.floor(tonumber(style) or 0)
        if style <= 0 then return end
        local prop = sleepPropImage(style)
        local propBase = (style == 2 or style == 3) and sleepPropBaseImage(style) or nil
        if not prop and not propBase then return end
        -- Stable size independent of camera distance (canvasScale drifts in FP/TP).
        -- Bed/bag share the sleeper's angle so the 3-layer stack lines up.
        -- Tent stays upright and oversized so it covers any residual BA body.
        local pscale = (style == 1) and 2.4 or 2.0
        local pang = 0
        if style == 2 or style == 3 then
          pang = npc.johtoLifeSleepAngle or (math.pi / 2)
        end
        Gfx.push("all")
        Gfx.setColor(1, 1, 1, 1)
        if propBase then
          local bw, bh = propBase:getDimensions()
          Gfx.draw(propBase, sx, sy, pang, pscale, pscale, bw / 2, bh / 2)
        end
        -- Body between underlay and overlay for bed/bag only.
        -- Baked sleep sprites already contain the side-lie rotation → draw at 0.
        if style == 2 or style == 3 then
          pcall(function()
            local spr = npc.sprite
            if not spr or spr._johtoInvisible then return end
            local img = spr.image
            if type(spr.resolveImage) == "function" then
              local ok, r = pcall(spr.resolveImage, spr)
              if ok and r then img = r end
            end
            if not img then return end
            local iw = tonumber(spr.frameWidth) or 16
            local ih = tonumber(spr.frameHeight) or 16
            local quad = spr.frames and (spr.frames[0] or spr.frames[1])
            local nscale = pscale * 0.85
            local bang = spr._johtoSleepBaked and 0 or pang
            if quad then
              Gfx.draw(img, quad, sx, sy, bang, nscale, nscale, iw / 2, ih / 2)
            else
              Gfx.draw(img, sx, sy, bang, nscale, nscale, iw / 2, ih / 2)
            end
          end)
        end
        if prop then
          local pw, ph = prop:getDimensions()
          Gfx.draw(prop, sx, sy, pang, pscale, pscale, pw / 2, ph / 2)
        end
        Gfx.pop()
      end

      local function drawVoxelOverlays(canvas, ctx)
        if not canvas then return end
        local Gfx = love.graphics
        local prev = Gfx.getCanvas()
        if not pcall(Gfx.setCanvas, canvas) then return end
        pcall(function() if Gfx.setShader then Gfx.setShader() end end)
        Gfx.push("all")

        local scale = canvasScale(canvas, ctx)
        local showZzz = opt("sleep_bubbles") ~= false
        local sleepers = collectSleepers()
        if ctx and ctx.state then
          local seen = {}
          for _, n in ipairs(sleepers) do seen[n] = true end
          for _, list in ipairs({ctx.state.npcs or {}, ctx.state.entities or {}}) do
            for _, n in ipairs(list) do
              if n and n.nightlifeSleeping and not seen[n] then
                sleepers[#sleepers + 1] = n; seen[n] = true
              end
            end
          end
        end

        for _, npc in ipairs(sleepers) do
          -- CharacterRenderers draws props + animated Zzz in WORLD space.
          -- Screen stickers shrink with distance and can stick to the camera —
          -- never use them when CR is live.
          if _G._johtoLifeVoxelSleepCRInstalled or npc._johtoLifeCRSleepClaimed then
            npc._johtoLifeCRSleepClaimed = nil
          else
            local sx, sy, ok = projectNpc(npc, canvas)
            if ok and sx and sy then
              drawPropAt(Gfx, npc, sx, sy, scale)
              if showZzz then drawFloatingZ(Gfx, sx, sy, scale, npc) end
            end
          end
        end

        -- Speech / collision bubbles (same projection as props)
        if opt("npc_collision_bubbles") ~= false then
          local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
          local actors, seenA = {}, {}
          local function addA(n)
            if n and not seenA[n] then seenA[n] = true; actors[#actors + 1] = n end
          end
          pcall(function()
            local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
            for _, list in ipairs({(ow and ow.npcs) or {}, (ow and ow.entities) or {}}) do
              for _, a in ipairs(list) do addA(a) end
            end
          end)
          if ctx and ctx.state then
            for _, list in ipairs({ctx.state.npcs or {}, ctx.state.entities or {}}) do
              for _, a in ipairs(list) do addA(a) end
            end
          end
          local okW, cw = pcall(canvas.getWidth, canvas)
          local okH, ch = pcall(canvas.getHeight, canvas)
          cw = (okW and tonumber(cw)) or 0
          ch = (okH and tonumber(ch)) or 0
          local s = math.max(1.0, scale)
          for _, npc in ipairs(actors) do
            local untilAt = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
            if untilAt > now and npc.visible ~= false and not npc.hidden then
              local sx, sy, okP = projectNpc(npc, canvas)
              if okP and sx and sy and (cw <= 0 or (sx > -20 and sy > -20 and sx < cw + 20 and sy < ch + 20)) then
                local text = tostring(npc._kantoLifeCollisionBubbleText or ":)")
                local font = Gfx.getFont()
                local tw, th = 12, 10
                pcall(function()
                  if font then tw = font:getWidth(text); th = font:getHeight() end
                end)
                Gfx.push("all")
                Gfx.translate(sx, sy)
                Gfx.scale(s, s)
                local bw = math.max(16, tw + 8)
                local bh = math.max(12, th + 4)
                local bx, by = -bw / 2, -30 - bh
                Gfx.setColor(1, 1, 1, 1)
                Gfx.rectangle("fill", bx, by, bw, bh, 2, 2)
                Gfx.setColor(0.1, 0.1, 0.1, 1)
                Gfx.rectangle("line", bx, by, bw, bh, 2, 2)
                Gfx.polygon("fill", bx + bw/2 - 2, by + bh, bx + bw/2 + 2, by + bh, bx + bw/2, by + bh + 3)
                if font then Gfx.print(text, bx + (bw - tw) / 2, by + (bh - th) / 2) end
                Gfx.pop()
              end
            end
          end
        end

        Gfx.setColor(1, 1, 1, 1)
        Gfx.pop()
        pcall(Gfx.setCanvas, prev)
      end

      -- Install worldPresent wrap (this is what painted props in working builds)
      if Pipelines and type(Pipelines.worldPresent) == "function" then
        if Pipelines._johtoLifeSleepWorldPresentWrapped
           and type(Pipelines._johtoLifeSleepWorldPresentBase) == "function" then
          Pipelines.worldPresent = Pipelines._johtoLifeSleepWorldPresentBase
        end
        local baseWorldPresent = Pipelines.worldPresent
        Pipelines._johtoLifeSleepWorldPresentBase = baseWorldPresent
        Pipelines.worldPresent = function(canvas, ctx)
          local out = baseWorldPresent(canvas, ctx)
          pcall(drawVoxelOverlays, out or canvas, ctx)
          return out
        end
        Pipelines._johtoLifeSleepWorldPresentWrapped = true
        mod.log:info("Johto Life: Gen2 voxel sleep/bubble worldPresent wrap installed")
      end

      -- Also register a content pipeline when the API exists (NPC Bubbles style)
      pcall(function()
        if not (mod.content and mod.content.render_pipelines
                and type(mod.content.render_pipelines.register) == "function") then
          return
        end
        local PIPE_ID = "johto_life_sleep_overlay"
        mod.content.render_pipelines:register(PIPE_ID, {
          label = "JOHTO LIFE SLEEP 3D",
          default = 1,
          worldPresent = function(canvas, ctx)
            pcall(drawVoxelOverlays, canvas, ctx)
            return canvas
          end,
        })
        pcall(function()
          if Pipelines and type(Pipelines.setLevel) == "function" then
            if (Pipelines.level and Pipelines.level(PIPE_ID) or 0) <= 0 then
              Pipelines.setLevel(PIPE_ID, 1)
            end
          end
        end)
      end)

      -- Do NOT wrap love.draw for props (wrong coordinate space → sliding duplicates).
    end)


  ----------------------------------------------------------------
  -- Public CharacterRenderers sleep for Gen2 voxel.
  -- Ports Gen1's floor-geometry claim so beds/bags lie flat, tents stay
  -- upright, BA does not draw a standing/duplicate body, and Zzz is large.
  ----------------------------------------------------------------
  ----------------------------------------------------------------
  -- Gen2 Battle Art 2.1.x has NO CharacterRenderers export.
  -- Sleep props must ride the SAME world-space path as default NPCs:
  -- wrap VoxelScene.drawEntity and draw with Voxel3D + Mat4 so beds/tents
  -- never shrink or stick to the camera in FP/TP.
  ----------------------------------------------------------------
  local function installJohtoVoxelSleepCR()
    if _G._johtoLifeVoxelSleepCRInstalled then return true end

    local battle, battleId = nil, nil
    for _, id in ipairs({
      "BATTLE_ART_VOXEL_GEN2", "BATTLE_ART_VOXEL_FORK", "BATTLE_ART_VOXEL",
      "battle_art_voxel", "POTATO_VOXEL", "PotatoVoxel",
    }) do
      local ok, m = pcall(function() return mod.find(id) end)
      if ok and m and m.exports and m.exports.lib and type(m.exports.lib.require) == "function" then
        battle, battleId = m, id
        break
      end
    end
    if not battle then return false end

    local lib = battle.exports.lib
    local okV, Voxel3D = pcall(lib.require, "Voxel3D")
    local okM, Mat4 = pcall(lib.require, "Mat4")
    local okB, SpriteBillboards = pcall(lib.require, "SpriteBillboards")
    local okS, VoxelScene = pcall(lib.require, "VoxelScene")
    local okF, FirstPerson = pcall(lib.require, "FirstPerson")
    if not (okV and okM and okB and okS and Voxel3D and Mat4 and SpriteBillboards
            and VoxelScene and type(VoxelScene.drawEntity) == "function"
            and type(Voxel3D.draw) == "function"
            and type(Mat4.mul) == "function"
            and type(SpriteBillboards.mesh) == "function") then
      return false
    end

    -- Gen2 BA: SpriteBillboards.mesh(def, frameNumber) — NOT (def, ax, ay)
    local sleepImgCache = {}
    local meshCache = {}

    local function ensureAssetHook()
      pcall(function()
        local okA, Assets = pcall(require, "src.render.Assets")
        if not (okA and Assets and type(Assets.get) == "function") then return end
        if Assets._johtoLifeSleepCRHooked then return end
        local base = Assets.get
        Assets.get = function(path, ...)
          if path and sleepImgCache[path] then return sleepImgCache[path] end
          return base(path, ...)
        end
        -- BA prefers Assets.image
        if type(Assets.image) == "function" and not Assets._johtoLifeSleepImageHooked then
          local baseImg = Assets.image
          Assets.image = function(path, ...)
            if path and sleepImgCache[path] then return sleepImgCache[path] end
            return baseImg(path, ...)
          end
          Assets._johtoLifeSleepImageHooked = true
        end
        Assets._johtoLifeSleepCRHooked = true
      end)
    end

    local function loadPropImg(rel)
      if not rel then return nil end
      if sleepImgCache[rel] then return sleepImgCache[rel] end
      local path = "assets/" .. rel
      if mod.assets and type(mod.assets.path) == "function" then
        path = mod.assets:path("assets/" .. rel) or path
      end
      local ok, img = pcall(love.graphics.newImage, path)
      if not (ok and img) then
        ok, img = pcall(love.graphics.newImage, "assets/" .. rel)
      end
      if ok and img then
        pcall(img.setFilter, img, "nearest", "nearest")
        sleepImgCache[rel] = img
        sleepImgCache["assets/" .. rel] = img
        return img
      end
      return nil
    end

    local function makeMesh(cacheKey, img)
      if not img then return nil end
      if meshCache[cacheKey] then return meshCache[cacheKey] end
      local w, h = img:getDimensions()
      local path = "johto_life_sleep_ba/" .. tostring(cacheKey) .. ".png"
      sleepImgCache[path] = img
      ensureAssetHook()
      local def = {
        id = "JOHTO_LIFE_SLEEP_BA_" .. tostring(cacheKey),
        image = path,
        frames = 1,
        frameWidth = w,
        frameHeight = h,
        trueColor = true,
        walker = false,
      }
      -- Gen2 BA signature: mesh(def, frameIndex)
      local mesh = SpriteBillboards.mesh(def, 0)
      if not mesh then
        -- Fallback if BA build still accepts anchor form
        local ok2, m2 = pcall(SpriteBillboards.mesh, def, 0, h / 2)
        if ok2 then mesh = m2 end
      end
      if not mesh then return nil end
      meshCache[cacheKey] = { mesh = mesh, image = img, w = w, h = h }
      return meshCache[cacheKey]
    end

    local propMeshCache, propBaseMeshCache, bodyMeshCache = {}, {}, {}
    local zBillboard = nil

    local function propMesh(style)
      style = math.floor(tonumber(style) or 0)
      if style <= 0 then return nil end
      if propMeshCache[style] then return propMeshCache[style] end
      local names = {[1]="sleep_tent.png",[2]="sleeping_bag.png",[3]="sleep_bed.png"}
      local img = loadPropImg(names[style]); if not img then return nil end
      propMeshCache[style] = makeMesh("prop_" .. style, img)
      return propMeshCache[style]
    end

    local function propBaseMesh(style)
      style = math.floor(tonumber(style) or 0)
      if style <= 1 then return nil end
      if propBaseMeshCache[style] then return propBaseMeshCache[style] end
      local names = {[2]="sleeping_bag_base.png",[3]="sleep_bed_base.png"}
      local img = loadPropImg(names[style]); if not img then return nil end
      propBaseMeshCache[style] = makeMesh("propbase_" .. style, img)
      return propBaseMeshCache[style]
    end

    local function bodyMeshFor(npc)
      -- Prefer the baked lying-down canvas (already ~16px, gray, correct frame).
      local bakedImg = npc and npc._johtoSleepBodyImage
      local spr = npc and (npc._johtoOrigSleepSprite or npc.sprite)
      if not bakedImg and (not spr or spr._johtoInvisible) then return nil end

      local key
      local drawImg
      if bakedImg and type(bakedImg.getDimensions) == "function" then
        key = "baked#" .. tostring(npc) .. "#" .. tostring(bakedImg)
        if bodyMeshCache[key] then return bodyMeshCache[key] end
        local bw, bh = bakedImg:getDimensions()
        if bw == 16 and bh == 16 then
          drawImg = bakedImg
        else
          local okS, scaled = pcall(function()
            local c = love.graphics.newCanvas(16, 16)
            local prev = love.graphics.getCanvas()
            love.graphics.setCanvas(c)
            love.graphics.clear(0, 0, 0, 0)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(bakedImg, 0, 0, 0, 16 / math.max(1, bw), 16 / math.max(1, bh))
            love.graphics.setCanvas(prev)
            return c
          end)
          drawImg = (okS and scaled) or bakedImg
        end
        bodyMeshCache[key] = makeMesh("body_" .. key, drawImg)
        return bodyMeshCache[key]
      end

      if not spr or spr._johtoInvisible then return nil end
      local def = spr.def or {}
      local img = spr.image
      if type(spr.resolveImage) == "function" then
        local ok, r = pcall(spr.resolveImage, spr)
        if ok and r then img = r end
      end
      if (not img or type(img) == "string") and type(def.hgssNativeImage) == "string" then
        pcall(function()
          local okI, i = pcall(love.graphics.newImage, def.hgssNativeImage)
          if okI and i then img = i end
        end)
      end
      if type(img) == "string" then
        pcall(function()
          local okI, i = pcall(love.graphics.newImage, img)
          if okI and i then img = i end
        end)
      end
      if not img or type(img.getDimensions) ~= "function" then return nil end

      local fw = tonumber(spr.frameWidth) or tonumber(def.frameWidth)
        or tonumber(def.hgssFrameWidth) or tonumber(def.hgssVoxelWidth) or 16
      local fh = tonumber(spr.frameHeight) or tonumber(def.frameHeight)
        or tonumber(def.hgssFrameHeight) or tonumber(def.hgssVoxelHeight) or 16
      fw = math.max(1, math.floor(fw))
      fh = math.max(1, math.floor(fh))
      local iw, ih = img:getDimensions()
      if fw > iw then fw = iw end
      if fh > ih then fh = ih end

      key = tostring(spr) .. "#" .. fw .. "x" .. fh .. "#fit16"
      if bodyMeshCache[key] then return bodyMeshCache[key] end

      local okFrame, frameCanvas = pcall(function()
        local c = love.graphics.newCanvas(fw, fh)
        local prev = love.graphics.getCanvas()
        love.graphics.setCanvas(c)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setColor(1, 1, 1, 1)
        local quad = spr.frames and (spr.frames[0] or spr.frames[1])
        if quad then
          love.graphics.draw(img, quad, 0, 0)
        else
          local okQ, q = pcall(love.graphics.newQuad, 0, 0, fw, fh, iw, ih)
          if okQ and q then love.graphics.draw(img, q, 0, 0)
          else love.graphics.draw(img, 0, 0) end
        end
        love.graphics.setCanvas(prev)
        return c
      end)
      if not (okFrame and frameCanvas) then return nil end

      drawImg = frameCanvas
      if fw ~= 16 or fh ~= 16 then
        local okS, scaled = pcall(function()
          local c = love.graphics.newCanvas(16, 16)
          local prev = love.graphics.getCanvas()
          love.graphics.setCanvas(c)
          love.graphics.clear(0, 0, 0, 0)
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.draw(frameCanvas, 0, 0, 0, 16 / fw, 16 / fh)
          love.graphics.setCanvas(prev)
          return c
        end)
        if okS and scaled then drawImg = scaled end
      end
      bodyMeshCache[key] = makeMesh("body_" .. key, drawImg)
      return bodyMeshCache[key]
    end


    local function zMesh()
      if zBillboard then return zBillboard end
      local okC, canvas = pcall(function()
        local c = love.graphics.newCanvas(12, 14)
        local prev = love.graphics.getCanvas()
        love.graphics.setCanvas(c)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print("Z", 1, 0)
        love.graphics.setColor(0.15, 0.05, 0.35, 1)
        love.graphics.print("Z", 2, 1)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setCanvas(prev)
        return c
      end)
      if not (okC and canvas) then return nil end
      zBillboard = makeMesh("zzz_anim", canvas)
      return zBillboard
    end

    local function facingYaw(facing)
      if facing == "left" then return math.rad(-90) end
      if facing == "up" then return math.rad(180) end
      if facing == "right" then return math.rad(90) end
      return 0
    end

    -- Match BA's character card matrix so tent size tracks default NPCs in FP/TP
    local function uprightCardMatrix(px, py, y, half)
      half = half or 8
      local m = Mat4.translate(px + half, y, py + half)
      if okF and FirstPerson and type(FirstPerson.cardBlend) == "function" then
        local okB, b = pcall(FirstPerson.cardBlend)
        b = (okB and tonumber(b)) or 0
        if b > 0 and type(FirstPerson.cardYaw) == "function" then
          local okY, yaw = pcall(FirstPerson.cardYaw, px + half, py + half)
          if okY and tonumber(yaw) then
            m = Mat4.mul(m, Mat4.rotateY(yaw * b))
          end
        end
        -- In orbit mode BA leans the card by camera pitch; approximate upright
        -- in FP (blend high) and slight lean in orbit (blend low).
        if b < 0.5 then
          m = Mat4.mul(m, Mat4.rotateX(-math.pi / 2 * (1 - b) * 0.15))
        end
      end
      return Mat4.mul(m, Mat4.translate(-half, 0, 0))
    end

    -- Flat on the ground (bed/bag) — fixed world orientation, not camera-sized
    local function flatMatrix(px, py, y, yaw)
      return Mat4.mul(
        Mat4.translate(px + 8, y, py + 8),
        Mat4.mul(Mat4.rotateY(yaw or 0), Mat4.rotateX(-math.pi / 2)),
        Mat4.translate(-8, 0, 0)
      )
    end

    local function resolveStyle(npc)
      local style = 0
      if npc.kantoLifeNaturalSleepStyle ~= nil then
        style = npc.kantoLifeNaturalSleepStyle
      elseif npc.kantoLifeRandomSleepStyle ~= nil then
        style = npc.kantoLifeRandomSleepStyle
      else
        local okR, rs = pcall(function() return resolveSleepStyle(npc) end)
        if okR and rs ~= nil then style = rs
        else
          local okO, v = pcall(function() return opt("sleep_style") end)
          if okO then style = v end
        end
      end
      return math.floor(tonumber(style) or 0)
    end

    local function drawSleeperWorld(npc, px, py, gh)
      local style = resolveStyle(npc)
      local yaw = facingYaw(npc.facing or npc.kantoLifeSleepFacing)
      gh = tonumber(gh) or 0
      px = tonumber(px) or 0
      py = tonumber(py) or 0

      if style == 2 or style == 3 then
        local pbm = propBaseMesh(style)
        if pbm and pbm.mesh then
          pcall(Voxel3D.draw, pbm.mesh, pbm.image,
                flatMatrix(px, py, gh + 0.03, yaw), 0, flatMatrix(px, py, gh + 0.03, yaw))
        end
        local bm = bodyMeshFor(npc)
        if bm and bm.mesh then
          pcall(Voxel3D.draw, bm.mesh, bm.image,
                flatMatrix(px, py, gh + 0.25, yaw), 0.1, flatMatrix(px, py, gh + 0.25, yaw))
        end
        local pm = propMesh(style)
        if pm and pm.mesh then
          pcall(Voxel3D.draw, pm.mesh, pm.image,
                flatMatrix(px, py, gh + 0.45, yaw), 0.2, flatMatrix(px, py, gh + 0.45, yaw))
        end
      elseif style == 1 then
        local pm = propMesh(1)
        if pm and pm.mesh then
          -- Upright tent, same world-space card path as default NPCs
          local half = (pm.w or 16) / 2
          local model = uprightCardMatrix(px, py, gh + 0.05, half)
          pcall(Voxel3D.draw, pm.mesh, pm.image, model, 0.2, model)
        end
      else
        -- style 0: default sleep — still draw body flat + Zzz (no prop)
        local bm = bodyMeshFor(npc)
        if bm and bm.mesh then
          pcall(Voxel3D.draw, bm.mesh, bm.image,
                flatMatrix(px, py, gh + 0.15, yaw), 0.1, flatMatrix(px, py, gh + 0.15, yaw))
        end
      end

      -- World-space animated Zzz (classic rise, fixed world size)
      local zm = zMesh()
      if zm and zm.mesh then
        local zt = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
        for i = 0, 2 do
          local phase = zt * 1.5 + i * 0.75
          local cycle = phase % 2.5
          local rise = cycle * 4
          local alpha = 1 - cycle / 2.5
          if alpha > 0.25 then
            local model = uprightCardMatrix(px + (i - 1) * 3, py, gh + 14 + rise + i * 2, 6)
            pcall(Voxel3D.draw, zm.mesh, zm.image, model, 0.5, model)
          end
        end
      end
    end

    -- Map invisible pose sprite → owning NPC so drawEntity can find them
    if not _G._johtoLifeSleeperBySprite then
      _G._johtoLifeSleeperBySprite = setmetatable({}, { __mode = "k" })
    end
    local sleeperBySprite = _G._johtoLifeSleeperBySprite

    -- Also: scan world npcs each draw by px/py match as backup
    local function findSleeperAt(px, py)
      local ow = mod.world and type(mod.world.overworld) == "function" and mod.world:overworld()
      local list = (ow and ow.npcs) or {}
      for _, n in ipairs(list) do
        if n and n.nightlifeSleeping then
          local nx = tonumber(n.px) or ((n.cellX or 0) * 16)
          local ny = tonumber(n.py) or ((n.cellY or 0) * 16)
          if math.abs(nx - px) < 1 and math.abs(ny - py) < 1 then
            return n
          end
        end
      end
      return nil
    end

    if not VoxelScene._johtoLifeDrawEntityWrapped then
      local baseDrawEntity = VoxelScene.drawEntity
      VoxelScene.drawEntity = function(sprite, px, py, facing, phase, flip, gh, colors, lift)
        local npc = nil
        if sprite then
          npc = sleeperBySprite[sprite] or sprite._johtoLifeSleeperNpc
        end
        if not npc then
          npc = findSleeperAt(px, py)
        end
        if npc and npc.nightlifeSleeping then
          -- Composite sprite is already what pose() returned; let BA draw it
          -- with the normal billboard path (same FP/TP sizing as default sleepers).
          local result = baseDrawEntity(sprite, px, py, facing, phase, flip, gh, colors, lift)
          -- World-space Zzz only (small, same upright card matrix as NPCs)
          pcall(function()
            local zm = zMesh and zMesh() or nil
            if not (zm and zm.mesh) then return end
            local zt = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
            for i = 0, 2 do
              local phaseZ = zt * 1.5 + i * 0.75
              local cycle = phaseZ % 2.5
              local rise = cycle * 4
              local alpha = 1 - cycle / 2.5
              if alpha > 0.25 then
                local model = uprightCardMatrix(px + (i - 1) * 3, py, (gh or 0) + 14 + rise + i * 2, 6)
                pcall(Voxel3D.draw, zm.mesh, zm.image, model, 0.5, model)
              end
            end
          end)
          npc._johtoLifeCRSleepClaimed = true
          return result ~= nil and result or true
        end
        return baseDrawEntity(sprite, px, py, facing, phase, flip, gh, colors, lift)
      end
      VoxelScene._johtoLifeDrawEntityWrapped = true
      VoxelScene._johtoLifeDrawEntityBase = baseDrawEntity
    end

    -- Tag invisible sleep sprites so drawEntity can resolve the NPC
    -- (pose already hides the engine billboard in voxel)
    pcall(function()
      if _johtoSleepInvisibleSprite then
        -- keep table identity stable
      end
    end)

    _G._johtoLifeVoxelSleepCRInstalled = true
    pcall(function()
      mod.log:info("Johto Life: Gen2 VoxelScene.drawEntity sleep wrap installed ("
        .. tostring(battleId) .. ")")
    end)
    return true
  end

  -- Tag invisible sprite with NPC during pose (so drawEntity can find it)
  do
    local prevPoseHook = NPC and NPC.pose
    -- Already wrapped above; extend by patching the invisible sprite assignment
    -- via a small after-install helper used from the existing pose wrap.
    _G._johtoLifeTagSleeperSprite = function(sprite, npc)
      if not sprite or not npc then return end
      sprite._johtoLifeSleeperNpc = npc
      if not _G._johtoLifeSleeperBySprite then
        _G._johtoLifeSleeperBySprite = setmetatable({}, { __mode = "k" })
      end
      _G._johtoLifeSleeperBySprite[sprite] = npc
    end
  end

  pcall(installJohtoVoxelSleepCR)
  pcall(function()
    if mod.events and type(mod.events.on) == "function" then
      mod.events:on("update", function()
        if not _G._johtoLifeVoxelSleepCRInstalled then
          pcall(installJohtoVoxelSleepCR)
        end
      end)
    elseif mod.on and type(mod.on) == "function" then
      mod.on("update", function()
        if not _G._johtoLifeVoxelSleepCRInstalled then
          pcall(installJohtoVoxelSleepCR)
        end
      end)
    end
  end)

  mod.log:info("Johto Life 0.1.52 loaded")
end
