return function(mod)
  -- Kanto Life 0.8.1 — based on 0.7.x Kanto (this chat), plus Johto-only deltas:
  -- gender-correct names for default NPCs + name: prefix on dialogue.
  local function resolveGame()
    if mod.game ~= nil then return mod.game end
    if mod.world and mod.world.game ~= nil then return mod.world.game end
    return nil
  end
  local game = resolveGame()
  local function G() game = resolveGame() or game; return game end
  game = G()

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
    { key = "sleeping_npcs", type = "toggle", label = "SLEEPING NPCS", default = true },
    { key = "sleep_pct", type = "number", label = "SLEEP RATE %",
      default = 15, min = 0, max = 100, step = 5 },
    { key = "day_sleepers", type = "toggle", label = "DAY SLEEPERS", default = true },
    { key = "common_courtesy", type = "toggle", label = "COMMON COURTESY", default = true },
  })

  local function opt(key)
    if mod.options and type(mod.options.get) == "function" then
      local v = mod.options:get(key)
      if v ~= nil then return v end
    end
    local g = G()
    if g and g.save and g.save.options and g.save.options.modOptions and g.save.options.modOptions[mod.id] then
      local v = g.save.options.modOptions[mod.id][key]
      if v ~= nil then return v end
    end
    if g and g.mods and g.mods.modOptions and g.mods.modOptions[mod.id] then
      local v = g.mods.modOptions[mod.id][key]
      if v ~= nil then return v end
    end
    return nil
  end

  local townDefaults = {
    SAFFRON_CITY = 150, CELADON_CITY = 150, FUCHSIA_CITY = 150,
    VERMILION_CITY = 150, CERULEAN_CITY = 50, PEWTER_CITY = 50,
    VIRIDIAN_CITY = 30, LAVENDER_TOWN = 30, CINNABAR_ISLAND = 12,
    PALLET_TOWN = 12,
  }
  local ROUTE_DEFAULT = 10
  local lines = {
    "I'm headed to the\nMART before sunset.", "My PIDGEY loves\ncity walks!",
    "I heard a TRAINER\nbeat the GYM today!", "I'm visiting family\nin the next town.",
    "KANTO feels busy\nthese days!", "My partner is\nresting at the CENTER.",
    "I travel light so I\ncan take the long road.", "Have you checked\nthe local GYM?",
  }
  local routeLines = {
    "I'm traveling\nbetween towns today.", "These routes are\nfull of TRAINERS!",
    "Tall grass hides\nsurprises!", "Don't get lost on\nthe long road.",
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
  }
  local POKE_CRY_LINES = { "%s!", "%s!\n%s!", "%s?", "%s...", "%s!\n%s?" }

  local talkRegistered = {}
  local spawnSerial = 0
  local outdoorTouched = mod.save:get("outdoorTouched") and true or false
  local pokeTouched = mod.save:get("pokeTouched") and true or false

  local function isTown(mapId) return townDefaults[mapId] ~= nil end
  local function isRoute(mapId)
    return type(mapId) == "string" and mapId:match("^ROUTE_") ~= nil
  end
  local function isIndoor(id)
    if not id then return false end
    id = tostring(id)
    if isTown(id) or isRoute(id) then return false end
    if id:find("HOUSE", 1, true) or id:find("HOME", 1, true) then return true end
    if id:find("_1F", 1, true) or id:find("_2F", 1, true) or id:find("_3F", 1, true) then return true end
    if id:find("MART", 1, true) or id:find("CENTER", 1, true) or id:find("GYM", 1, true) then return true end
    return false
  end
  local function defaultCount(mapId)
    if townDefaults[mapId] then return townDefaults[mapId] end
    if isRoute(mapId) then return ROUTE_DEFAULT end
    if isIndoor(mapId) then return math.floor(tonumber(opt("indoor_npc_count")) or 3) end
    return 0
  end

  local function setOpt(key, value)
    local g = G()
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
      local opts = SaveData.loadOptions(g and g.fs or nil)
      if type(opts) ~= "table" then return end
      opts.modOptions = opts.modOptions or {}
      opts.modOptions[mod.id] = opts.modOptions[mod.id] or {}
      opts.modOptions[mod.id][key] = value
      SaveData.saveOptions(opts, g and g.fs or nil)
    end)
    if mod.options and type(mod.options.set) == "function" then
      pcall(function() mod.options:set(key, value) end)
    end
    if loader and loader.events and loader.events.emit then
      loader.events:emit("mod.options_changed", { mod = mod.id, key = key, value = value })
    end
  end

  local function targetCount(mapId)
    if not opt("extra_npcs") then return 0 end
    if isIndoor(mapId) then
      if not opt("indoor_npcs") then return 0 end
      return math.max(0, math.floor(tonumber(opt("indoor_npc_count")) or 3))
    end
    if not (isTown(mapId) or isRoute(mapId)) then return 0 end
    if outdoorTouched then
      return math.max(0, math.floor(tonumber(opt("extra_npc_count")) or 0))
    end
    local n = math.floor(tonumber(opt("extra_npc_count")) or 0)
    if n > 0 then return n end
    return defaultCount(mapId)
  end
  local function pokeTarget(mapId)
    if not opt("pokemon_npcs") then return 0 end
    if not (isTown(mapId) or isRoute(mapId)) then return 0 end
    return math.max(0, math.floor(tonumber(opt("pokemon_npc_count")) or 0))
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
    if map.warpAtCell and map:warpAtCell(x, y) then return true end
    for dx = -1, 1 do
      for dy = -1, 1 do
        if not (dx == 0 and dy == 0) and map.warpAtCell and map:warpAtCell(x + dx, y + dy) then
          return true
        end
      end
    end
    return false
  end
  local function pickSpawnCell(ow, map)
    if not ow or not map then return nil, nil end
    local w = math.max(1, (map.widthCells or map.width or 2) - 2)
    local h = math.max(1, (map.heightCells or map.height or 2) - 2)
    for _ = 1, 200 do
      local tx = love.math.random(1, w)
      local ty = love.math.random(1, h)
      local walk = true
      if map.isWalkableCell and not map:isWalkableCell(tx, ty) then walk = false end
      if walk and not nearWarp(map, tx, ty) and not occupied(ow, tx, ty) then
        return tx, ty
      end
    end
    for _ = 1, 80 do
      local tx = love.math.random(1, w)
      local ty = love.math.random(1, h)
      local walk = true
      if map.isWalkableCell and not map:isWalkableCell(tx, ty) then walk = false end
      if walk and map.warpAtCell and not map:warpAtCell(tx, ty) and not occupied(ow, tx, ty) then
        return tx, ty
      end
    end
    return nil, nil
  end

  local function civilianSprites(ow, mapId)
    local sprites, seen = {}, {}
    for _, npc in ipairs(ow.npcs or {}) do
      local d = npc.def or {}
      if d.kantoLifeAmbient then goto continue end
      local lyingViridianOldMan = mapId == "VIRIDIAN_CITY"
        and (tostring(d.sprite):find("OLD_MAN", 1, true)
          or tostring(d.name):find("OLD_MAN", 1, true))
      local nonHumanSprite = tostring(d.sprite):find("PIKACHU", 1, true)
        or tostring(d.sprite):find("POKEMON", 1, true)
        or tostring(d.sprite):find("BALL", 1, true)
        or tostring(d.sprite):find("FOSSIL", 1, true)
        or npc.pikachuFollower
        or tostring(d.name):find("PIKACHU", 1, true)
      if d.sprite and not lyingViridianOldMan and not nonHumanSprite
         and not d.trainerClass and not d.item and not d.pokemon
         and not seen[d.sprite] then
        seen[d.sprite] = true; sprites[#sprites + 1] = d.sprite
      end
      ::continue::
    end
    return sprites
  end

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
  local function stableNameFor(npc)
    local d = npc.def or {}
    local seed = table.concat({
      tostring(d.sprite or ""),
      tostring(d.index or ""),
      tostring(npc.id or ""),
      tostring(npc.cellX or ""),
      tostring(npc.cellY or ""),
      tostring(d.name or ""),
    }, ":")
    local h = 2166136261
    for i = 1, #seed do h = (h * 16777619 + seed:byte(i)) % 2147483647 end
    local pool = (genderFromNpc(npc) == "f") and FEMALE_NAMES or MALE_NAMES
    return pool[(h % #pool) + 1]
  end
  local function randomName(g)
    local pool = (g == "f") and FEMALE_NAMES or MALE_NAMES
    return pool[love.math.random(#pool)]
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
    if d.kantoLifeAmbient then return true end
    local name = tostring(d.name or "")
    return name:match("^KANTO_(CROWD|ROUTE_NPC|POKE)_") ~= nil
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
        if n == npc or (id and n and n.id == id) then table.remove(ow.npcs, i) end
      end
    end
    if ow and ow.entities then
      for i = #ow.entities, 1, -1 do
        local e = ow.entities[i]
        if e == npc or (id and e and e.id == id) then table.remove(ow.entities, i) end
      end
    end
    npc.visible = false
    npc.hidden = true
    if npc.def then npc.def.hidden = true end
    pcall(function()
      if npc.cellX then npc.cellX = -100 end
      if npc.cellY then npc.cellY = -100 end
    end)
  end

  local function collectLiveAmbient(ow, pokeOnly)
    local list = {}
    if not ow or not ow.npcs then return list end
    for _, n in ipairs(ow.npcs) do
      if isAmbientNpc(n) and not n.hidden then
        local isPoke = n.def and n.def.kantoLifePokemon
        if pokeOnly == nil or pokeOnly == (isPoke and true or false) then
          list[#list + 1] = n
        end
      end
    end
    return list
  end

  local function tagAmbient(n, name, displayName, isPoke, monName)
    n.def = n.def or {}
    n.def.kantoLifeAmbient = true
    n.def.name = name
    n.def.kantoLifeDisplayName = displayName
    if isPoke then
      n.def.kantoLifePokemon = true
      n.def.kantoLifeMon = monName
    end
  end

  local function syncAmbientToTarget(mapId, map)
    local ow = mod.world:overworld()
    if not ow then return end
    if not map then map = ow.map end
    if not map or (map.id and map.id ~= mapId) then
      if ow.map and ow.map.id == mapId then map = ow.map else return end
    end

    local want = targetCount(mapId)
    local have = collectLiveAmbient(ow, false)
    while #have > want do
      local npc = table.remove(have)
      destroyAmbient(ow, npc)
    end

    if want > 0 and (isTown(mapId) or isIndoor(mapId)) then
      ensureTalkScripts(mapId, math.max(want, 150))
      local sprites = civilianSprites(ow, mapId)
      if #sprites == 0 then
        sprites = { "SPRITE_YOUNGSTER", "SPRITE_LASS", "SPRITE_HIKER", "SPRITE_BEAUTY" }
      end
      for i = #have + 1, want do
        local x, y = pickSpawnCell(ow, map)
        if not x then break end
        spawnSerial = spawnSerial + 1
        local text = "KANTO_CROWD_" .. mapId .. "_" .. spawnSerial
        local sprite = sprites[((i - 1) % #sprites) + 1]
        local g = genderFromSprite(sprite)
        local displayName = randomName(g)
        local npcId, err = mod.world:spawnNpc(mapId, {
          name = text, sprite = sprite, x = x, y = y,
          text = text, movement = "WALK", range = "ANY_DIR",
          kantoLifeAmbient = true,
          kantoLifeDisplayName = displayName,
          kantoLifeGender = g,
        })
        if not npcId then
          mod.log:warn("Crowd spawn failed: " .. tostring(err))
        else
          for _, n in ipairs(ow.npcs or {}) do
            if n.id == npcId or (n.def and n.def.name == text) then
              tagAmbient(n, text, displayName, false)
            end
          end
        end
      end
    elseif want > 0 and isRoute(mapId) then
      local civilian, trainer = {}, {}
      for _, npc in ipairs(ow.npcs or {}) do
        local d = npc.def or {}
        if d.kantoLifeAmbient then goto cont end
        local nonHuman = npc.pikachuFollower or tostring(d.sprite):find("PIKACHU", 1, true)
          or tostring(d.sprite):find("POKEMON", 1, true) or tostring(d.sprite):find("BALL", 1, true)
        if d.sprite and not nonHuman then
          if d.trainerClass then trainer[#trainer + 1] = d.sprite
          elseif not d.item and not d.pokemon then civilian[#civilian + 1] = d.sprite end
        end
        ::cont::
      end
      if #civilian == 0 and #trainer == 0 then
        civilian = { "SPRITE_YOUNGSTER", "SPRITE_HIKER", "SPRITE_LASS" }
      end
      for i = #have + 1, want do
        local x, y = pickSpawnCell(ow, map)
        if not x then break end
        local useTrainerSprite = i % 5 == 0 and #trainer > 0
        local sprites = useTrainerSprite and trainer or civilian
        if #sprites == 0 then sprites = trainer end
        if #sprites == 0 then break end
        spawnSerial = spawnSerial + 1
        local name = "KANTO_ROUTE_NPC_" .. mapId .. "_" .. spawnSerial
        local sprite = sprites[love.math.random(#sprites)]
        local g = genderFromSprite(sprite)
        local displayName = randomName(g)
        local id, err = mod.world:spawnNpc(mapId, {
          name = name, sprite = sprite, x = x, y = y,
          text = "", movement = "WALK", range = "ANY_DIR",
          kantoLifeAmbient = true,
          kantoLifeDisplayName = displayName,
          kantoLifeGender = g,
        })
        if not id then
          mod.log:warn("Route NPC spawn failed: " .. tostring(err))
        else
          for _, n in ipairs(ow.npcs or {}) do
            if n.id == id or (n.def and n.def.name == name) then
              tagAmbient(n, name, displayName, false)
            end
          end
        end
      end
    end

    -- Pokemon NPCs (Johto-port feature already on later Kanto builds)
    local wantPoke = pokeTarget(mapId)
    local havePoke = collectLiveAmbient(ow, true)
    while #havePoke > wantPoke do
      destroyAmbient(ow, table.remove(havePoke))
    end
    for i = #havePoke + 1, wantPoke do
      local x, y = pickSpawnCell(ow, map)
      if not x then break end
      spawnSerial = spawnSerial + 1
      local mon = POKE_LIST[love.math.random(#POKE_LIST)]
      local name = "KANTO_POKE_" .. mapId .. "_" .. spawnSerial
      local id = mod.world:spawnNpc(mapId, {
        name = name, sprite = "SPRITE_" .. mon, x = x, y = y,
        text = "", movement = "WALK", range = "ANY_DIR",
        kantoLifeAmbient = true, kantoLifePokemon = true,
        kantoLifeDisplayName = mon, kantoLifeMon = mon,
      })
      if not id then
        id = mod.world:spawnNpc(mapId, {
          name = name, sprite = mon, x = x, y = y, text = "",
          movement = "WALK", range = "ANY_DIR",
          kantoLifeAmbient = true, kantoLifePokemon = true,
          kantoLifeDisplayName = mon, kantoLifeMon = mon,
        })
      end
      if id then
        for _, n in ipairs(ow.npcs or {}) do
          if n.id == id or (n.def and n.def.name == name) then
            tagAmbient(n, name, mon, true, mon)
          end
        end
      end
    end
  end

  for mapId, count in pairs(townDefaults) do
    ensureTalkScripts(mapId, math.max(count, 150))
  end

  if mod.events and mod.events.on then
    mod.events:on("map.entered", function(ev)
      local id = ev and (ev.mapId or ev.id)
      if id and (isTown(id) or isRoute(id) or isIndoor(id)) then
        syncAmbientToTarget(id, ev.map)
      end
    end)
    mod.events:on("map.ready", function(ev)
      local id = ev and (ev.mapId or ev.id)
      if id and (isTown(id) or isRoute(id) or isIndoor(id)) then
        syncAmbientToTarget(id, ev and ev.map)
      end
    end)
    mod.events:on("mod.options_changed", function(payload)
      if not payload or payload.mod ~= mod.id then return end
      if payload.key == "extra_npc_count" then outdoorTouched = true; mod.save:set("outdoorTouched", true) end
      if payload.key == "pokemon_npc_count" then pokeTouched = true; mod.save:set("pokeTouched", true) end
      local ow = mod.world and mod.world:overworld()
      if not ow or not ow.map then return end
      local mapId = ow.map.id
      if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId)) then return end
      if payload.key == "extra_npcs" and payload.value == true then
        local cur = math.floor(tonumber(opt("extra_npc_count")) or 0)
        if cur <= 0 then
          local d = defaultCount(mapId)
          if d > 0 then setOpt("extra_npc_count", d) end
        end
      end
      syncAmbientToTarget(mapId, ow.map)
    end)
  end

  local OPTIONS_SCREEN = "KantoLifeOptions"
  local function refreshAmbientNow()
    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map then return end
    local mapId = ow.map.id
    if isTown(mapId) or isRoute(mapId) or isIndoor(mapId) then
      syncAmbientToTarget(mapId, ow.map)
    end
  end

  local function stepToggle(item, dir)
    local nextVal = not item.current
    item.current = nextVal
    item.right = nextVal and "ON" or "OFF"
    if item.apply then item.apply(nextVal) end
  end
  local function stepNumber(item, dir)
    local step = item.stepSize or 1
    if math.abs(dir or 1) > 1 then step = item.stepFast or 10 end
    local cur = tonumber(item.current) or 0
    local nextVal = cur + ((dir or 1) >= 0 and step or -step)
    local mn, mx = item.min or 0, item.max or 150
    if nextVal < mn then nextVal = mn end
    if nextVal > mx then nextVal = mx end
    if nextVal == cur then return end
    item.current = nextVal
    item.right = tostring(nextVal)
    if item.apply then item.apply(nextVal) end
  end
  local function stepItem(item, dir)
    if not item or not item.stepper then return end
    if item.kind == "number" then stepNumber(item, dir) else stepToggle(item, dir) end
  end

  local function makeStepperMenu(g, title, items)
    if not (mod.ui and mod.ui.ListMenu and mod.ui.ListMenu.new) then return nil end
    local menu = mod.ui.ListMenu.new(g, title, items, {
      onChoose = function(item, m)
        if item and item.stepper then stepItem(item, 1); return end
        if item and item.onSelect then
          item.onSelect()
          if m and m.close then m:close() end
        end
      end,
    })
    if not (menu and type(menu.update) == "function") then return menu end
    local INITIAL_DELAY, REPEAT_INTERVAL = 0.35, 0.08
    local baseUpdate = menu.update
    menu.update = function(self, dt)
      local idx = self.index or self.selected or self.cursor or 1
      local item = self.items and self.items[idx]
      if not (item and item.stepper) then
        self._klHold = nil; self._klTimer = 0
        return baseUpdate(self, dt)
      end
      local input = self.game and self.game.input
      local function down(dir)
        if not input then return false end
        if input.isDown and input:isDown(dir) then return true end
        if input.down and input:down(dir) then return true end
        if type(input.pressed) == "table" and input.pressed[dir] then return true end
        return false
      end
      local function pressed(dir)
        if not input then return false end
        if input.wasPressed and input:wasPressed(dir) then return true end
        return false
      end
      local leftP, rightP = pressed("left"), pressed("right")
      local leftD, rightD = down("left"), down("right")
      if leftP or rightP then
        stepItem(item, leftP and -1 or 1)
        self._klHold = leftP and "left" or "right"
        self._klTimer = 0
      elseif self._klHold then
        local still = (self._klHold == "left" and leftD) or (self._klHold == "right" and rightD)
        if still then
          self._klTimer = (self._klTimer or 0) + (dt or 0)
          if self._klTimer >= INITIAL_DELAY then
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

  if mod.content and mod.content.screens and mod.content.screens.register then
    mod.content.screens:register(OPTIONS_SCREEN, {
      new = function(g)
        local items = {
          { label = "EXTRA NPCS", stepper = true, kind = "toggle",
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
            end },
          { label = "EXTRA NPC COUNT", stepper = true, kind = "number",
            min = 0, max = 150, stepFast = 10,
            current = math.floor(tonumber(opt("extra_npc_count")) or 0),
            right = tostring(math.floor(tonumber(opt("extra_npc_count")) or 0)),
            apply = function(v)
              outdoorTouched = true; mod.save:set("outdoorTouched", true)
              setOpt("extra_npc_count", math.floor(tonumber(v) or 0))
              refreshAmbientNow()
            end },
          { label = "INDOOR NPCS", stepper = true, kind = "toggle",
            current = opt("indoor_npcs") and true or false,
            right = opt("indoor_npcs") and "ON" or "OFF",
            apply = function(v) setOpt("indoor_npcs", v and true or false); refreshAmbientNow() end },
          { label = "INDOOR COUNT", stepper = true, kind = "number",
            min = 0, max = 30, stepFast = 5,
            current = math.floor(tonumber(opt("indoor_npc_count")) or 3),
            right = tostring(math.floor(tonumber(opt("indoor_npc_count")) or 3)),
            apply = function(v) setOpt("indoor_npc_count", math.floor(tonumber(v) or 3)); refreshAmbientNow() end },
          { label = "POKE NPCS", stepper = true, kind = "toggle",
            current = opt("pokemon_npcs") and true or false,
            right = opt("pokemon_npcs") and "ON" or "OFF",
            apply = function(v) setOpt("pokemon_npcs", v and true or false); refreshAmbientNow() end },
          { label = "POKE COUNT", stepper = true, kind = "number",
            min = 0, max = 50, stepFast = 5,
            current = math.floor(tonumber(opt("pokemon_npc_count")) or 0),
            right = tostring(math.floor(tonumber(opt("pokemon_npc_count")) or 0)),
            apply = function(v)
              pokeTouched = true; mod.save:set("pokeTouched", true)
              setOpt("pokemon_npc_count", math.floor(tonumber(v) or 0))
              refreshAmbientNow()
            end },
          { label = "SLEEPING NPCS", stepper = true, kind = "toggle",
            current = opt("sleeping_npcs") and true or false,
            right = opt("sleeping_npcs") and "ON" or "OFF",
            apply = function(v) setOpt("sleeping_npcs", v and true or false) end },
          { label = "SLEEP RATE %", stepper = true, kind = "number",
            min = 0, max = 100, stepSize = 5, stepFast = 10,
            current = math.floor(tonumber(opt("sleep_pct")) or 15),
            right = tostring(math.floor(tonumber(opt("sleep_pct")) or 15)),
            apply = function(v) setOpt("sleep_pct", math.floor(tonumber(v) or 15)) end },
          { label = "DAY SLEEPERS", stepper = true, kind = "toggle",
            current = opt("day_sleepers") and true or false,
            right = opt("day_sleepers") and "ON" or "OFF",
            apply = function(v) setOpt("day_sleepers", v and true or false) end },
          { label = "COMMON COURTESY", stepper = true, kind = "toggle",
            current = opt("common_courtesy") and true or false,
            right = opt("common_courtesy") and "ON" or "OFF",
            apply = function(v) setOpt("common_courtesy", v and true or false) end },
          { label = "CANCEL", onSelect = function() end },
        }
        return makeStepperMenu(g, "KANTO LIFE", items)
      end,
    })
  end

  if mod.hooks and mod.hooks.wrap then
    mod.hooks:wrap("ui.options.rows", function(next, g, rows)
      local out = next(g, rows)
      if type(out) ~= "table" then return out end
      local row = {
        id = "kanto_life_open", label = "KANTO LIFE",
        value = function() return "OPEN" end,
        activate = function(game_)
          if mod.ui and mod.ui.push then mod.ui.push(game_, OPTIONS_SCREEN) end
        end,
      }
      if mod.ui and type(mod.ui.insertBefore) == "function" then
        out = mod.ui.insertBefore(out, "MODS", row) or out
      else
        out[#out + 1] = row
      end
      return out
    end)
  end

  -- Nightlife + Common Courtesy (0.7 base)
  local function safeRequire(path)
    local ok, m = pcall(require, path)
    if ok then return m end
    return nil
  end
  local Overworld = safeRequire("src.world.OverworldController")
  local MapScripts = safeRequire("src.script.MapScripts")
  local Warp = safeRequire("src.world.Warp")
  local TextBox = safeRequire("src.render.TextBox")
  local Strings = safeRequire("src.core.Strings")
  local NPC = safeRequire("src.world.NPC")
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
  local function night(ow) return ow.timeOfDay and ow:timeOfDay() == "NIGHT" end
  local function resident(mapId)
    return mapId ~= nil and tostring(mapId):find("HOUSE", 1, true) ~= nil
  end

  local excludedHomes = {
    CERULEAN_TRASHED_HOUSE = true, BILLS_HOUSE = true,
    BLUES_HOUSE = true, REDS_HOUSE_1F = true, REDS_HOUSE_2F = true,
  }
  local excludedHomePatterns = { "SAFARI" }
  local excludedEntrances = { { map = "CERULEAN_CITY", x = 9, y = 9 } }
  local function isExcludedEntrance(self)
    for _, e in ipairs(excludedEntrances) do
      if e.map == self.map.id and e.x == self.player.cellX and e.y == self.player.cellY then
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
  local function frontDoor(self, dest)
    if not opt("common_courtesy") then return false end
    if not (dest and resident(dest) and not resident(self.map.id)) then return false end
    if isExcludedEntrance(self) then return false end
    if isExcludedHome(dest) then return false end
    return true
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
  local function markKnown(dest)
    if not dest then return end
    local h = homes[key(dest)] or {}
    h.known, h.knocked = true, nil
    h.knownUntil = steps() + COURTESY_MEMORY_STEPS
    homes[key(dest)] = h; saveHomes()
  end

  local function isSpecialCharacter(npc)
    if not npc or not npc.def then return true end
    local d = npc.def
    local sprite = tostring(d.sprite or ""):upper()
    local name = tostring(d.name or ""):upper()
    local text = tostring(d.text or ""):upper()
    if sprite:find("NURSE", 1, true) or name:find("NURSE", 1, true) then return true end
    if sprite:find("CLERK", 1, true) or sprite:find("MART", 1, true) then return true end
    if sprite:find("OAK", 1, true) or name:find("OAK", 1, true) then return true end
    if sprite:find("BILL", 1, true) or name:find("BILL", 1, true) then return true end
    if sprite:find("RIVAL", 1, true) or name:find("RIVAL", 1, true) then return true end
    if sprite:find("MOM", 1, true) or name:find("MOM", 1, true) then return true end
    if sprite:find("DAISY", 1, true) or name:find("DAISY", 1, true) then return true end
    if name:find("JOY", 1, true) or text:find("JOY", 1, true) then return true end
    if d.trainerClass then
      local c = tostring(d.trainerClass):upper()
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

  local function wake(d)
    local c = tostring(d.trainerClass or "")
    if c:find("ELITE", 1, true) then return "You woke an ELITE\nFOUR member!\nPrepare yourself!" end
    if c:find("LEADER", 1, true) then return "You woke a GYM\nLEADER! Let's battle!" end
    return "Hey! You woke me\nup! Let's battle!"
  end

  local function putToSleep(npc)
    if not npc or not npc.def then return end
    if npc.nightlifeSleeping then return end
    npc.nightlifeSleeping = true
    npc.frozen = true
    if npc.facing ~= nil then npc.kantoLifeSleepFacing = npc.facing end
    local sign = ((npc.cellX or 0) + (npc.cellY or 0)) % 2 == 0 and 1 or -1
    npc.kantoLifeSleepAngle = sign * (math.pi / 2)
    if npc.def.range then
      npc.kantoLifeSleepRange = npc.def.range
      npc.def.range = "NONE"
    end
    npc.sleepPose = true
    npc.def.sleeping = true
  end

  local function wakeNpc(npc)
    if not npc or not npc.nightlifeSleeping then return end
    npc.nightlifeSleeping = nil
    npc.frozen = false
    npc.sleepPose = nil
    npc.kantoLifeSleepAngle = nil
    if npc.def then npc.def.sleeping = nil end
    if npc.kantoLifeSleepFacing then
      npc.facing = npc.kantoLifeSleepFacing
      npc.kantoLifeSleepFacing = nil
    end
    if npc.def and npc.kantoLifeSleepRange then
      npc.def.range = npc.kantoLifeSleepRange
      npc.kantoLifeSleepRange = nil
    end
  end

  -- Johto delta: name prefix on vanilla dialogue (story keeps assigned names)
  local STORY_SPRITE_NAMES = {
    SPRITE_MOM = "MOM", MOM = "MOM", SPRITE_OAK = "PROF.OAK", OAK = "PROF.OAK",
    SPRITE_NURSE = "NURSE", NURSE = "NURSE", SPRITE_CLERK = "CLERK",
    SPRITE_BLUE = "BLUE", SPRITE_RED = "RED", SPRITE_BILL = "BILL",
    SPRITE_MR_FUJI = "MR.FUJI", SPRITE_GIOVANNI = "GIOVANNI",
    SPRITE_BROCK = "BROCK", SPRITE_MISTY = "MISTY", SPRITE_DAISY = "DAISY",
  }
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
  local function storyDisplayName(npc)
    if not npc or isAmbientNpc(npc) then return nil end
    if type(npc.kantoLifeStoryName) == "string" and npc.kantoLifeStoryName ~= "" then
      return npc.kantoLifeStoryName
    end
    local d = npc.def or {}
    if type(d.name) == "string" and #d.name >= 2 and #d.name <= 14
        and d.name:match("^[%a][%a%s%.%-]*$")
        and not d.name:find("KANTO_", 1, true) then
      npc.kantoLifeStoryName = d.name:upper()
      return npc.kantoLifeStoryName
    end
    local spr = tostring(d.sprite or ""):upper()
    if STORY_SPRITE_NAMES[spr] then
      npc.kantoLifeStoryName = STORY_SPRITE_NAMES[spr]
      return npc.kantoLifeStoryName
    end
    local assigned = stableNameFor(npc)
    npc.kantoLifeStoryName = assigned
    return assigned
  end
  local function prefixStoryText(body, name)
    local text = bodyToString(body)
    if text == "" or textAlreadyNamed(text) then return body end
    return name .. ":\n" .. text
  end

  if TextBox and type(TextBox.new) == "function" then
    local baseTB = TextBox.new
    TextBox.new = function(gameArg, text, onDone, opts)
      local raw = bodyToString(text)
      if textAlreadyNamed(raw) then return baseTB(gameArg, text, onDone, opts) end
      local ow = mod.world and mod.world:overworld()
      local talker = ow and ow.talkNpc
      if isAmbientNpc(talker) then return baseTB(gameArg, text, onDone, opts) end
      local nm = storyDisplayName(talker)
      if nm then text = prefixStoryText(text, nm) end
      return baseTB(gameArg, text, onDone, opts)
    end
  end

  if NPC and NPC.draw then
    local baseNpcDraw = NPC.draw
    NPC.draw = function(self, camX, camY)
      if not self.nightlifeSleeping or not self.kantoLifeSleepAngle then
        return baseNpcDraw(self, camX, camY)
      end
      local sprite = self.sprite
      if not sprite or not sprite.image then
        return baseNpcDraw(self, camX, camY)
      end
      local px, py = self.px or 0, self.py or 0
      local x = math.floor(px - camX)
      local y = math.floor(py - camY) - 4
      local image = sprite.image
      if sprite.resolveImage then
        local ok, img = pcall(function() return sprite:resolveImage() end)
        if ok and img then image = img end
      end
      local angle = self.kantoLifeSleepAngle
      local ox, oy = 8, 8
      local quad = sprite.frames and (sprite.frames[0] or sprite.frames[1])
      love.graphics.push()
      if quad then
        love.graphics.draw(image, quad, x + ox, y + oy, angle, 1, 1, ox, oy)
      else
        love.graphics.draw(image, x + ox, y + oy, angle, 1, 1, ox, oy)
      end
      love.graphics.pop()
    end
  end

  if Overworld then
    local baseInteract = Overworld.interact
    Overworld.interact = function(self)
      local g = G()
      if self.player and self.player.facingCell and self.map and self.map.warpAtCell then
        local x, y = self.player:facingCell()
        local at = self.map:warpAtCell(x, y)
        if at and Warp and g and g.data then
          local dest = Warp.destination(g.data, at.def, self.lastOutdoor)
          if frontDoor(self, dest) and not isKnown(dest) then
            g.stack:push(TextBox.new(g,
              Strings("KNOCK before\nentering?"), nil, { choice = function(yes)
                local h = homes[key(dest)] or {}
                if yes then
                  h.knocked = true
                  homes[key(dest)] = h; saveHomes()
                  g.stack:push(TextBox.new(g,
                    Strings("KNOCK! KNOCK!\nCome in!"), function()
                      self.kantoLifeWelcome = dest
                      self:takeWarp(at.def)
                    end))
                else
                  h.enterWithoutKnockUntil = now() + 10
                  homes[key(dest)] = h; saveHomes()
                end
              end }))
            return
          end
        end
      end
      return baseInteract(self)
    end

    local baseWarp = Overworld.takeWarp
    Overworld.takeWarp = function(self, warpDef)
      local g = G()
      local from = { map = self.map.id, x = self.player.cellX, y = self.player.cellY }
      local dest = Warp and g and g.data and Warp.destination(g.data, warpDef, self.lastOutdoor)
      if dest and frontDoor(self, dest) then
        local h = homes[key(dest)] or {}
        if not isKnown(dest) and not h.knocked and (h.lockedUntil or 0) > now() then
          g.stack:push(TextBox.new(g, Strings("Please try again\nin 5 minutes."))); return
        end
        if not isKnown(dest) and not h.knocked then
          self.kantoLifeTrespass = { home = dest, from = from }
        end
        h.knocked = nil
        homes[key(dest)] = h; saveHomes()
      end
      return baseWarp(self, warpDef)
    end

    local baseUpdate = Overworld.update
    local lastCell = { map = nil, x = nil, y = nil }
    Overworld.update = function(self, dt)
      baseUpdate(self, dt)
      local g = G()
      local p = self.player
      if p and self.map then
        local mid = self.map.id
        if lastCell.map ~= mid then lastCell.map, lastCell.x, lastCell.y = mid, p.cellX, p.cellY
        elseif lastCell.x ~= p.cellX or lastCell.y ~= p.cellY then
          lastCell.x, lastCell.y = p.cellX, p.cellY
          setSteps(steps() + 1)
        end
      end
      local trespass = self.kantoLifeTrespass
      if trespass and self.map.id == trespass.home and not self.kantoLifeResolving then
        self.kantoLifeTrespass, self.kantoLifeResolving = nil, true
        local function eject(seconds)
          local h = homes[key(trespass.home)] or {}
          if seconds > 0 then h.lockedUntil = now() + seconds end
          homes[key(trespass.home)] = h; saveHomes()
          g.stack:push(TextBox.new(g, Strings("Please come back\nlater, and KNOCK!"), function()
            self.doorWarp = true
            self:startWarpTo(trespass.from.map, trespass.from.x, trespass.from.y, "down")
            self.kantoLifeResolving = false
          end))
        end
        local npc = self.npcs and self.npcs[1]
        if npc and npc.def and npc.def.trainerClass then
          g.stack:push(TextBox.new(g, Strings(wake(npc.def)), function()
            self:engageTrainer(npc, function()
              if g.save.defeatedTrainers and g.save.defeatedTrainers[npc.id] then
                markKnown(trespass.home); self.kantoLifeResolving = false
              else eject(5) end
            end)
          end))
        else eject(0) end
      end
      if self.kantoLifeWelcome and self.map.id == self.kantoLifeWelcome then
        local w = self.kantoLifeWelcome
        self.kantoLifeWelcome = nil
        markKnown(w)
        g.stack:push(TextBox.new(g, Strings("Welcome! Thank you\nfor knocking.")))
      end

      local sleepingOn = opt("sleeping_npcs")
      local isNight = night(self)
      local pct = math.floor(tonumber(opt("sleep_pct")) or 15)
      for _, npc in ipairs(self.npcs or {}) do
        if isSpecialCharacter(npc) then
          if npc.nightlifeSleeping then wakeNpc(npc) end
        elseif sleepingOn then
          local d = npc.def or {}
          if d.kantoLifeAmbient and not d.kantoLifePokemon then
            local s = tostring(npc.id or d.name or "")
            local h = 0; for i = 1, #s do h = h + s:byte(i) * i end
            local daySleeper = opt("day_sleepers") and ((h % 10) < 3)
            local window = daySleeper and (not isNight) or isNight
            if daySleeper then window = not isNight else window = isNight end
            if window and pct > 0 and (h % 100) < pct then
              putToSleep(npc)
            elseif npc.nightlifeSleeping then
              wakeNpc(npc)
            end
          elseif isNight then
            putToSleep(npc)
          elseif npc.nightlifeSleeping then
            wakeNpc(npc)
          end
        elseif npc.nightlifeSleeping then
          wakeNpc(npc)
        end
      end
    end

    local baseTalk = Overworld.talkTo
    Overworld.talkTo = function(self, npc)
      local g = G()
      local d = npc and npc.def
      if not d then return baseTalk(self, npc) end
      if isAmbientNpc(npc) then
        local display = d.kantoLifeDisplayName or stableNameFor(npc)
        if npc.nightlifeSleeping then
          return g.stack:push(TextBox.new(g, Strings(display .. " is fast\nasleep.")))
        end
        if d.kantoLifePokemon then
          local mon = d.kantoLifeMon or display
          local fmt = POKE_CRY_LINES[love.math.random(#POKE_CRY_LINES)]
          return g.stack:push(TextBox.new(g, Strings(display .. ":\n" .. fmt:format(mon, mon))))
        end
        local route = tostring(d.name or ""):match("^KANTO_ROUTE")
        local pool = route and routeLines or lines
        local idx = tonumber(tostring(d.name or ""):match("_(%d+)$")) or 1
        local h = 0; local nm = tostring(d.name or "")
        for i = 1, #nm do h = h + nm:byte(i) * i end
        local text = pool[((idx + h - 1) % #pool) + 1]
        return g.stack:push(TextBox.new(g, Strings(display .. ":\n" .. text)))
      end
      if not night(self) or not opt("sleeping_npcs") then
        return baseTalk(self, npc)
      end
      if isSpecialCharacter(npc) then return baseTalk(self, npc) end
      if MapScripts and MapScripts.talkScript and MapScripts.talkScript(self.map.id, d.text) then
        return baseTalk(self, npc)
      end
      if d.trainerClass then
        return g.stack:push(TextBox.new(g, Strings(wake(d)), function() baseTalk(self, npc) end))
      end
      npc.frozen = true
      local nm = storyDisplayName(npc) or (d.name or "This person"):gsub("_", " ")
      g.stack:push(TextBox.new(g, Strings("%s is fast\nasleep.", nm)))
    end
  end

  mod.log:info("Kanto Life 0.8.1 loaded (0.7 base + Johto name/gender deltas)")
end
