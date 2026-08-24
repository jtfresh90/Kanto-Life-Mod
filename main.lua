return function(mod)
  -- Kanto Life 0.8.0 — Gen1 only (Johto features ported)
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
    { key = "sleeping_npcs", type = "toggle", label = "SLEEPING NPCS", default = true },
    { key = "sleep_pct", type = "number", label = "SLEEP RATE %",
      default = 15, min = 0, max = 100, step = 5 },
    { key = "day_sleepers", type = "toggle", label = "DAY SLEEPERS", default = true },
    { key = "common_courtesy", type = "toggle", label = "COMMON COURTESY", default = true },
  })

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
    PALLET_TOWN = 8, VIRIDIAN_CITY = 20, PEWTER_CITY = 25,
    CERULEAN_CITY = 30, VERMILION_CITY = 30, LAVENDER_TOWN = 15,
    CELADON_CITY = 60, FUCHSIA_CITY = 40, SAFFRON_CITY = 60,
    CINNABAR_ISLAND = 10, INDIGO_PLATEAU = 5,
  }
  local ROUTE_DEFAULT = 8
  local SPRITE_DEFS = {
    { "SPRITE_YOUNGSTER", "m" }, { "SPRITE_LASS", "f" },
    { "SPRITE_BUG_CATCHER", "m" }, { "SPRITE_COOLTRAINER_M", "m" },
    { "SPRITE_COOLTRAINER_F", "f" }, { "SPRITE_BEAUTY", "f" },
    { "SPRITE_SUPER_NERD", "m" }, { "SPRITE_HIKER", "m" },
    { "SPRITE_FISHER", "m" }, { "SPRITE_SAILOR", "m" },
    { "SPRITE_GENTLEMAN", "m" }, { "SPRITE_BIKER", "m" },
    { "SPRITE_GAMBLER", "m" }, { "SPRITE_LITTLE_GIRL", "f" },
    { "SPRITE_GIRL", "f" }, { "SPRITE_MIDDLE_AGED_MAN", "m" },
    { "SPRITE_BALDING_GUY", "m" }, { "SPRITE_OLD_MEDIUM_WOMAN", "f" },
    { "SPRITE_CHANNELER", "f" }, { "SPRITE_ROCKER", "m" },
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
  local lines = {
    "I'm headed to the\nMART before sunset.", "KANTO feels lively\ntoday!",
    "Have you tried the\nlocal GYM?", "My partner is at\nthe POKEMON CENTER.",
    "I'm training for\nthe LEAGUE!", "Watch for wild\nPOKEMON in the grass!",
    "CELADON has the\nbest shops!", "I love the music\nin this town!",
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
  local function isIndoor(id)
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
    if isIndoor(id) then return math.floor(tonumber(opt("indoor_npc_count")) or 3) end
    return 0
  end
  local function humanTarget(mapId)
    if not opt("extra_npcs") then return 0 end
    if isIndoor(mapId) then
      if not opt("indoor_npcs") then return 0 end
      return math.max(0, math.floor(tonumber(opt("indoor_npc_count")) or 3))
    end
    if not (isTown(mapId) or isRoute(mapId)) then return 0 end
    if outdoorTouched then return math.max(0, math.floor(tonumber(opt("extra_npc_count")) or 0)) end
    local n = math.floor(tonumber(opt("extra_npc_count")) or 0)
    if n > 0 then return n end
    return defaultCount(mapId)
  end
  local function pokeTarget(mapId)
    if not opt("pokemon_npcs") then return 0 end
    if not (isTown(mapId) or isRoute(mapId)) then return 0 end
    return math.max(0, math.floor(tonumber(opt("pokemon_npc_count")) or 0))
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
  local function pickCell(ow, map)
    if not (ow and map) then return nil end
    local w = map.width or (map.def and map.def.width) or 20
    local h = map.height or (map.def and map.def.height) or 18
    for _ = 1, 60 do
      local x = love.math.random(2, math.max(2, w - 3))
      local y = love.math.random(2, math.max(2, h - 3))
      local blocked = false
      if map.isWalkable and not map:isWalkable(x, y) then blocked = true end
      if map.isWalkableCell and not map:isWalkableCell(x, y) then blocked = true end
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
      if d.kantoLifeAmbient then
        local isPoke = d.kantoLifePokemon and true or false
        if pokeOnly == nil or pokeOnly == isPoke then list[#list + 1] = n end
      end
    end
    return list
  end

  local function spawnOne(ow, map, mapId, isPoke)
    local x, y = pickCell(ow, map)
    if not x then return nil end
    spawnSerial = spawnSerial + 1
    local sprite, gender, displayName, monName, movement, radius
    if isPoke then
      monName = POKE_LIST[love.math.random(1, #POKE_LIST)]
      displayName, gender, sprite = monName, "m", "SPRITE_" .. monName
      movement, radius = MOVE_WANDER, { x = 2, y = 2 }
    else
      local def = SPRITE_DEFS[love.math.random(#SPRITE_DEFS)]
      sprite, gender = def[1], def[2]
      displayName = randomName(gender)
      local roll = love.math.random(1, 3)
      if roll == 1 then movement = MOVE_WALK_UD
      elseif roll == 2 then movement = MOVE_WALK_LR
      else movement = MOVE_WANDER end
      radius = { x = 3, y = 3 }
    end
    local tag = isPoke and "KANTO_POKE_" or "KANTO_NPC_"
    local name = tag .. tostring(mapId) .. "_" .. spawnSerial .. "_" .. tostring(love.math.random(100000))
    local function trySpawn(spr)
      return mod.world:spawnNpc(mapId, {
        name = name, sprite = spr, x = x, y = y, text = "",
        movement = movement, radius = radius,
        kantoLifeAmbient = true,
        kantoLifePokemon = isPoke and true or nil,
        kantoLifeDisplayName = displayName,
        kantoLifeGender = gender,
        kantoLifeMon = monName,
      })
    end
    local id = trySpawn(sprite)
    if not id and isPoke then
      id = trySpawn(monName) or trySpawn("SPRITE_MONSTER") or trySpawn("SPRITE_POKE_BALL")
    end
    if not id then return nil end
    for _, n in ipairs(ow.npcs or {}) do
      if n.id == id or (n.def and n.def.name == name) then
        n.def = n.def or {}
        n.def.kantoLifeAmbient = true
        n.def.kantoLifePokemon = isPoke and true or nil
        n.def.kantoLifeDisplayName = displayName
        n.def.kantoLifeMon = monName
        n.frozen = false
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
    if not (isTown(mapId) or isRoute(mapId) or isIndoor(mapId)) then return end
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
    balance(humanTarget(mapId), false)
    if isTown(mapId) or isRoute(mapId) then balance(pokeTarget(mapId), true) end
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

  local function openKantoOptions(parentGame)
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
        { label = "COURTESY", right = opt("common_courtesy") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("common_courtesy", not opt("common_courtesy")) end },
        { label = "SLEEP NPCS", right = opt("sleeping_npcs") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("sleeping_npcs", not opt("sleeping_npcs")) end },
        { label = "SLEEP %", right = tostring(math.floor(tonumber(opt("sleep_pct")) or 15)), stepper = true,
          step = function(dir)
            local n = math.max(0, math.min(100, math.floor(tonumber(opt("sleep_pct")) or 15) + 5 * (dir or 1)))
            setOpt("sleep_pct", n)
          end,
          onSelect = function()
            local n = math.floor(tonumber(opt("sleep_pct")) or 15)
            setOpt("sleep_pct", (n >= 100) and 0 or (n + 5))
          end },
        { label = "DAY SLEEP", right = opt("day_sleepers") and "ON" or "OFF", stepper = true,
          onSelect = function() setOpt("day_sleepers", not opt("day_sleepers")) end },
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
      local menuRef = mod.ui.ListMenu.new(g, "KANTO LIFE", items, {
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
          id = "kanto_life:open", label = "KANTO LIFE",
          text = function() return "OPEN" end,
          value = function() return "OPEN" end,
          activate = function(gg) openKantoOptions(gg or gameArg) end,
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
    RIVALS_HOUSE = true, OAKS_LAB = true,
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
    if world then world.kantoLifeTrespass = nil end
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
    local trespass = (world and world.kantoLifeTrespass) or pendingTrespass
    if not trespass or not trespass.home then return false end
    local mapId = toMap or (world and world.map and world.map.id)
    if not mapId or tostring(mapId) ~= tostring(trespass.home) then return false end
    if world and world.kantoLifeResolving then return false end
    if world then world.kantoLifeResolving = true end
    local from = trespass.from or {}
    local function finish()
      warpBackTo(world, from); clearTrespass(world)
      if world then world.kantoLifeResolving = false end
    end
    if not pushText(world, "Please come back\nlater, and KNOCK!", finish) then finish() end
    return true
  end
  local function markTrespass(world, dest, fromMap, fromX, fromY)
    local t = { home = dest, from = { map = fromMap, x = fromX or 0, y = fromY or 0 } }
    pendingTrespass = t; mod.save:set("pendingTrespass", t)
    if world then world.kantoLifeTrespass = t end
  end

  local STORY_SPRITE_NAMES = {
    SPRITE_MOM = "MOM", MOM = "MOM", SPRITE_OAK = "PROF.OAK", OAK = "PROF.OAK",
    SPRITE_NURSE = "NURSE", NURSE = "NURSE", SPRITE_CLERK = "CLERK",
    SPRITE_BLUE = "BLUE", SPRITE_RED = "RED", SPRITE_BILL = "BILL",
    SPRITE_MR_FUJI = "MR.FUJI", SPRITE_GIOVANNI = "GIOVANNI",
    SPRITE_BROCK = "BROCK", SPRITE_MISTY = "MISTY", SPRITE_LT_SURGE = "LT.SURGE",
    SPRITE_ERIKA = "ERIKA", SPRITE_KOGA = "KOGA", SPRITE_SABRINA = "SABRINA",
    SPRITE_BLAINE = "BLAINE", SPRITE_DAISY = "DAISY",
  }
  -- Gen1 sprite gender (string match + common indices)
  local function genderFromNpc(npc)
    if not npc then return "m" end
    local d = npc.def or {}
    local spr = ""
    if npc.sprite and type(npc.sprite.id) == "string" then spr = npc.sprite.id:upper()
    elseif type(d.sprite) == "string" then spr = d.sprite:upper()
    elseif type(npc.spriteId) == "string" then spr = npc.spriteId:upper()
    end
    if spr ~= "" then
      if spr:find("HIKER", 1, true) or spr:find("FISHER", 1, true) then return "m" end
      if spr:find("BALDING", 1, true) or spr:find("MIDDLE_AGED_MAN", 1, true) then return "m" end
      if spr:find("FAT", 1, true) or spr:find("GENTLEMAN", 1, true) then return "m" end
      if spr:find("SAILOR", 1, true) or spr:find("BIKER", 1, true) then return "m" end
      if spr:find("GAMBLER", 1, true) or spr:find("YOUNGSTER", 1, true) then return "m" end
      if spr:find("BUG_CATCHER", 1, true) or spr:find("SUPER_NERD", 1, true) then return "m" end
      if spr:find("ROCKER", 1, true) or spr:find("COOLTRAINER_M", 1, true) then return "m" end
      if spr:find("GUARD", 1, true) or spr:find("WAITER", 1, true) then return "m" end
      if spr:find("COOK", 1, true) or spr:find("ROCKET", 1, true) then return "m" end
      if spr:find("LASS", 1, true) or spr:find("BEAUTY", 1, true) then return "f" end
      if spr:find("LITTLE_GIRL", 1, true) or spr:find("GIRL", 1, true) then return "f" end
      if spr:find("CHANNELER", 1, true) or spr:find("NURSE", 1, true) then return "f" end
      if spr:find("COOLTRAINER_F", 1, true) or spr:find("DAISY", 1, true) then return "f" end
      if spr:find("MEDIUM", 1, true) or spr:find("MOM", 1, true) then return "f" end
      if spr:find("_F$") or spr:find("_F_") then return "f" end
      if spr:find("_M$") or spr:find("_M_") then return "m" end
    end
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
    if d.kantoLifeAmbient then return true end
    local nm = tostring(d.name or npc.id or "")
    if nm:find("KANTO_NPC_", 1, true) or nm:find("KANTO_POKE_", 1, true) then return true end
    return false
  end
  local function storyDisplayName(npc)
    if not npc then return nil end
    if isAmbientNpc(npc) then return nil end
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
    local tr = d.trainer
    if type(tr) == "table" then
      if type(tr.name) == "string" and tr.name ~= "" then
        local nm = (type(tr.class) == "string" and tr.class ~= "" and (tr.class .. " " .. tr.name) or tr.name):upper()
        npc.kantoLifeStoryName = nm
        return nm
      end
      if type(tr.class) == "string" and tr.class ~= "" then
        npc.kantoLifeStoryName = tr.class:upper()
        return npc.kantoLifeStoryName
      end
    end
    local spr = spriteKeyOf(npc)
    if STORY_SPRITE_NAMES[spr] then
      npc.kantoLifeStoryName = STORY_SPRITE_NAMES[spr]
      return npc.kantoLifeStoryName
    end
    local sk = tostring(d.scriptKey or "")
    local from = sk:match("([%a]+)Script")
    if from and #from >= 3 and #from <= 12 then
      local u = from:upper()
      if u ~= "OBJECT" and u ~= "STD" and u ~= "GENERIC" and u ~= "ITEM" and u ~= "HIDDEN" then
        npc.kantoLifeStoryName = u
        return u
      end
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

  -- Gen1 World showText hook
  local World1 = safeRequire("src.world.World") or safeRequire("src.world.gen1.World")
  if World1 and type(World1.showText) == "function" then
    local baseShowText = World1.showText
    World1.showText = function(self, body, onDone, stay, hold)
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
      refreshCurrentMap()
    end)
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
                    world.kantoLifeWelcome = dest
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

    if World1 and type(World1.takeWarp) == "function" then
      local baseWorldWarp = World1.takeWarp
      World1.takeWarp = function(self, warpDef)
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
    if World1 and type(World1.step) == "function" then
      local baseStep = World1.step
      World1.step = function(self, ...)
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
      if world.kantoLifeWelcome and world.map and world.map.id == world.kantoLifeWelcome then
        local w = world.kantoLifeWelcome; world.kantoLifeWelcome = nil
        markKnown(w); pushText(world, "Welcome! Thank you\nfor knocking.")
      end
      for _, npc in ipairs(world.npcs or {}) do
        local d = npc.def or {}
        if d.kantoLifeAmbient and not npc.nightlifeSleeping then
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
      if opt("sleeping_npcs") then
        local pct = math.floor(tonumber(opt("sleep_pct")) or 15)
        local isNight = false
        if type(world.timeOfDay) == "function" then
          local ok, tod = pcall(function() return world:timeOfDay() end)
          isNight = ok and tod == "NIGHT"
        end
        for _, npc in ipairs(world.npcs or {}) do
          local d = npc.def or {}
          if d.kantoLifeAmbient and not d.kantoLifePokemon then
            local s = tostring(npc.id or d.name or "")
            local h = 0; for i = 1, #s do h = h + s:byte(i) * i end
            local daySleeper = opt("day_sleepers") and ((h % 10) < 3)
            local window
            if daySleeper then window = not isNight else window = isNight end
            if window and pct > 0 and (h % 100) < pct then
              npc.frozen = true; npc.nightlifeSleeping = true
            elseif npc.nightlifeSleeping then
              npc.frozen = false; npc.nightlifeSleeping = nil
            end
          end
        end
      end
      if world.map and (isTown(world.map.id) or isRoute(world.map.id) or isIndoor(world.map.id)) then
        if #liveAmbient(world, false) ~= humanTarget(world.map.id)
            or #liveAmbient(world, true) ~= pokeTarget(world.map.id) then
          spawnAmbient(world.map.id)
        end
      end
    end

    local baseTalk = Overworld.talkTo
    Overworld.talkTo = function(world, npc)
      local d = npc and npc.def
      if d and d.kantoLifeAmbient then
        local display = d.kantoLifeDisplayName or "Someone"
        if npc.nightlifeSleeping then
          pushText(world, display .. " is fast\nasleep."); return true
        end
        if d.kantoLifePokemon then
          local mon = d.kantoLifeMon or display
          local fmt = POKE_CRY_LINES[love.math.random(#POKE_CRY_LINES)]
          pushText(world, display .. ":\n" .. fmt:format(mon, mon)); return true
        end
        local name = tostring(d.name or "")
        local pool = name:find("ROUTE", 1, true) and routeLines or lines
        local idx = tonumber(name:match("_(%d+)$")) or 1
        local h = 0; for i = 1, #name do h = h + name:byte(i) * i end
        pushText(world, display .. ":\n" .. pool[((idx + h - 1) % #pool) + 1]); return true
      end
      if type(baseTalk) == "function" then return baseTalk(world, npc) end
      return false
    end
  else
    mod.log:warn("Kanto Life: Overworld facade missing")
  end

  mod.log:info("Kanto Life 0.8.0 loaded")
end
