return function(mod)
  -- Mods do not receive the engine's private `Game` global. WorldAPI owns
  -- the supported live-game reference and works under other overworld mods.
  local game = mod.world.game

  -- ------- Options schema (mod manager + native OPTIONS menu via ui.options.rows)
  mod.options:define({
    { key = "extra_npcs", type = "toggle", label = "EXTRA NPCS", default = true },
    { key = "extra_npc_count", type = "number", label = "EXTRA NPC COUNT",
      default = 0, min = 0, max = 150, step = 1 },
    { key = "sleeping_npcs", type = "toggle", label = "SLEEPING NPCS", default = true },
    { key = "common_courtesy", type = "toggle", label = "COMMON COURTESY", default = true },
  })

  local function opt(key)
    return mod.options:get(key)
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
    "I'm headed to the\nMART before sunset.", "My PIDGEY loves\ncity walks!",
    "I heard a TRAINER\nbeat the GYM today!", "I'm visiting family\nin the next town.",
    "KANTO feels busy\nthese days!", "My partner is\nresting at the CENTER.",
    "I travel light so I\ncan take the long road.", "Have you checked\nthe local GYM?",
  }

  local talkRegistered = {}
  -- Serial so every ambient name is unique even across re-spawns.
  local spawnSerial = 0

  local function isTown(mapId) return townDefaults[mapId] ~= nil end
  local function isRoute(mapId)
    return type(mapId) == "string" and mapId:match("^ROUTE_") ~= nil
  end
  local function defaultCount(mapId)
    if townDefaults[mapId] then return townDefaults[mapId] end
    if isRoute(mapId) then return ROUTE_DEFAULT end
    return 0
  end

  -- Absolute target: toggle off → 0; otherwise the slider value (0 = none).
  local function targetCount(mapId)
    if not opt("extra_npcs") then return 0 end
    local n = math.floor(tonumber(opt("extra_npc_count")) or 0)
    if n < 0 then n = 0 end
    if n > 150 then n = 150 end
    return n
  end

  local function setOpt(key, value)
    local loader = game.mods
    if loader then
      loader.modOptions = loader.modOptions or {}
      loader.modOptions[mod.id] = loader.modOptions[mod.id] or {}
      loader.modOptions[mod.id][key] = value
    end
    if game.save and game.save.options then
      game.save.options.modOptions = game.save.options.modOptions or {}
      game.save.options.modOptions[mod.id] = game.save.options.modOptions[mod.id] or {}
      game.save.options.modOptions[mod.id][key] = value
    end
    pcall(function()
      local SaveData = require("src.core.SaveData")
      local opts = SaveData.loadOptions(game.fs or nil)
      if type(opts) ~= "table" then return end
      opts.modOptions = opts.modOptions or {}
      opts.modOptions[mod.id] = opts.modOptions[mod.id] or {}
      opts.modOptions[mod.id][key] = value
      SaveData.saveOptions(opts, game.fs or nil)
    end)
    if loader and loader.events and loader.events.emit then
      loader.events:emit("mod.options_changed",
        { mod = mod.id, key = key, value = value })
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

  local function pickSpawnCell(ow, map)
    if not ow or not map then return nil, nil end
    local w = math.max(1, (map.widthCells or 2) - 2)
    local h = math.max(1, (map.heightCells or 2) - 2)
    for _ = 1, 200 do
      local tx = love.math.random(1, w)
      local ty = love.math.random(1, h)
      if map:isWalkableCell(tx, ty)
         and not nearWarp(map, tx, ty)
         and not occupied(ow, tx, ty) then
        return tx, ty
      end
    end
    for _ = 1, 80 do
      local tx = love.math.random(1, w)
      local ty = love.math.random(1, h)
      if map:isWalkableCell(tx, ty)
         and not map:warpAtCell(tx, ty)
         and not occupied(ow, tx, ty) then
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
    return name:match("^KANTO_(CROWD|ROUTE_NPC)_") ~= nil
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

  local function collectLiveAmbient(ow)
    local list = {}
    if not ow or not ow.npcs then return list end
    for _, n in ipairs(ow.npcs) do
      if isAmbientNpc(n) and not n.hidden then
        list[#list + 1] = n
      end
    end
    return list
  end

  local function syncAmbientToTarget(mapId, map)
    local ow = mod.world:overworld()
    if not ow then return end
    if not map then map = ow.map end
    if not map or (map.id and map.id ~= mapId) then
      if ow.map and ow.map.id == mapId then map = ow.map else return end
    end

    local want = targetCount(mapId)
    local have = collectLiveAmbient(ow)

    -- Always trim first so 0 clears everything.
    while #have > want do
      local npc = table.remove(have)
      destroyAmbient(ow, npc)
    end

    if want <= 0 then return end

    if isTown(mapId) then
      ensureTalkScripts(mapId, math.max(want, 150))
      local sprites = civilianSprites(ow, mapId)
      if #sprites == 0 then
        mod.log:warn("No civilian sprite on " .. tostring(mapId))
        return
      end
      for i = #have + 1, want do
        local x, y = pickSpawnCell(ow, map)
        if not x then break end
        spawnSerial = spawnSerial + 1
        local text = "KANTO_CROWD_" .. mapId .. "_" .. spawnSerial
        local sprite = sprites[((i - 1) % #sprites) + 1]
        local npcId, err = mod.world:spawnNpc(mapId, {
          name = text, sprite = sprite, x = x, y = y,
          text = text, movement = "WALK", range = "ANY_DIR",
          kantoLifeAmbient = true,
        })
        if not npcId then
          mod.log:warn("Crowd spawn failed: " .. tostring(err))
        else
          -- Tag the live instance too (def copy may not carry custom fields).
          for _, n in ipairs(ow.npcs or {}) do
            if n.id == npcId or (n.def and n.def.name == text) then
              n.def = n.def or {}
              n.def.kantoLifeAmbient = true
              n.def.name = text
            end
          end
        end
      end
    elseif isRoute(mapId) then
      local civilian, trainer = {}, {}
      for _, npc in ipairs(ow.npcs or {}) do
        local d = npc.def or {}
        if d.kantoLifeAmbient then goto cont end
        local nonHuman = npc.pikachuFollower or tostring(d.sprite):find("PIKACHU", 1, true)
          or tostring(d.sprite):find("POKEMON", 1, true) or tostring(d.sprite):find("BALL", 1, true)
          or tostring(d.sprite):find("FOSSIL", 1, true)
        if d.sprite and not nonHuman then
          if d.trainerClass then trainer[#trainer + 1] = d.sprite
          elseif not d.item and not d.pokemon then civilian[#civilian + 1] = d.sprite end
        end
        ::cont::
      end
      if #civilian == 0 and #trainer == 0 then return end
      for i = #have + 1, want do
        local x, y = pickSpawnCell(ow, map)
        if not x then break end
        local useTrainerSprite = i % 5 == 0 and #trainer > 0
        local sprites = useTrainerSprite and trainer or civilian
        if #sprites == 0 then sprites = trainer end
        if #sprites == 0 then break end
        spawnSerial = spawnSerial + 1
        local name = "KANTO_ROUTE_NPC_" .. mapId .. "_" .. spawnSerial
        local id, err = mod.world:spawnNpc(mapId, {
          name = name, sprite = sprites[love.math.random(#sprites)], x = x, y = y,
          text = "", movement = "WALK", range = "ANY_DIR",
          kantoLifeAmbient = true,
        })
        if not id then
          mod.log:warn("Route NPC spawn failed: " .. tostring(err))
        else
          for _, n in ipairs(ow.npcs or {}) do
            if n.id == id or (n.def and n.def.name == name) then
              n.def = n.def or {}
              n.def.kantoLifeAmbient = true
              n.def.name = name
            end
          end
        end
      end
    end
  end

  for mapId, count in pairs(townDefaults) do
    ensureTalkScripts(mapId, math.max(count, 150))
  end

  mod.events:on("map.entered", function(ev)
    if not (isTown(ev.mapId) or isRoute(ev.mapId)) then return end
    syncAmbientToTarget(ev.mapId, ev.map)
  end)

  mod.events:on("mod.options_changed", function(payload)
    if not payload or payload.mod ~= mod.id then return end
    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map then return end
    local mapId = ow.map.id
    if not (isTown(mapId) or isRoute(mapId)) then return end

    -- Turning EXTRA NPCS on with a zero count seeds the current map's default.
    if payload.key == "extra_npcs" and payload.value == true then
      local cur = math.floor(tonumber(opt("extra_npc_count")) or 0)
      if cur <= 0 then
        local d = defaultCount(mapId)
        if d > 0 then setOpt("extra_npc_count", d) end
      end
    end

    if payload.key == "extra_npcs" or payload.key == "extra_npc_count" then
      syncAmbientToTarget(mapId, ow.map)
    end
    if payload.key == "sleeping_npcs" and not opt("sleeping_npcs") then
      for _, npc in ipairs(ow.npcs or {}) do
        if npc.nightlifeSleeping then wakeNpc(npc) end
      end
    end
  end)

  -- ------- Native OPTIONS submenu (same pattern as Wilds of Kanto / overworld-spawn-mod)
  -- START → OPTION → KANTO LIFE (OPEN) → ListMenu with left/right steppers
  local OPTIONS_SCREEN = "KantoLifeOptions"

  local function refreshAmbientNow()
    local ow = mod.world and mod.world:overworld()
    if not ow or not ow.map then return end
    local mapId = ow.map.id
    if isTown(mapId) or isRoute(mapId) then
      syncAmbientToTarget(mapId, ow.map)
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
    local step = 1
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
          label = "SLEEPING NPCS",
          stepper = true,
          kind = "toggle",
          current = opt("sleeping_npcs") and true or false,
          right = opt("sleeping_npcs") and "ON" or "OFF",
          apply = function(v)
            setOpt("sleeping_npcs", v and true or false)
            applySleepOff()
          end,
        },
        {
          label = "COMMON COURTESY",
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

  -- ------- Nightlife + Common Courtesy
  local Overworld = require("src.world.OverworldController")
  local MapScripts = require("src.script.MapScripts")
  local Warp = require("src.world.Warp")
  local TextBox = require("src.render.TextBox")
  local Strings = require("src.core.Strings")
  local NPC = require("src.world.NPC")
  local homes = mod.save:get("homes") or {}
  local function saveHomes() mod.save:set("homes", homes) end
  local function key(id) return tostring(id) end
  local function now() return os.time() end
  local function night(ow) return ow.timeOfDay and ow:timeOfDay() == "NIGHT" end
  local function resident(mapId)
    return mapId ~= nil and tostring(mapId):find("HOUSE", 1, true) ~= nil
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
    mod.log:info(("kanto-life: front-door prompt at %s (%d,%d) -> %s")
      :format(self.map.id, self.player.cellX, self.player.cellY, dest))
    return true
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
    if npc.facing ~= nil then
      npc.kantoLifeSleepFacing = npc.facing
    end
    local sign = ((npc.cellX or 0) + (npc.cellY or 0)) % 2 == 0 and 1 or -1
    npc.kantoLifeSleepAngle = sign * (math.pi / 2)
    if npc.def.range then
      npc.kantoLifeSleepRange = npc.def.range
      npc.def.range = "NONE"
    end
    npc.sleepPose = true
    npc.def.sleeping = true
  end

  function wakeNpc(npc)
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

  local baseInteract = Overworld.interact
  Overworld.interact = function(self)
    local x, y = self.player:facingCell(); local at = self.map:warpAtCell(x, y)
    if at then
      local dest = Warp.destination(game.data, at.def, self.lastOutdoor)
      if frontDoor(self, dest) and not (homes[key(dest)] or {}).known then
        game.stack:push(TextBox.new(game,
          Strings("KNOCK before\nentering?"), nil, { choice = function(yes)
            local h = homes[key(dest)] or {}
            if yes then
              h.knocked = true
              homes[key(dest)] = h; saveHomes()
              game.stack:push(TextBox.new(game,
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
    return baseInteract(self)
  end

  local baseWarp = Overworld.takeWarp
  Overworld.takeWarp = function(self, warpDef)
    local from = { map = self.map.id, x = self.player.cellX, y = self.player.cellY }
    local dest = Warp.destination(game.data, warpDef, self.lastOutdoor)
    if frontDoor(self, dest) then
      local h = homes[key(dest)] or {}
      if not h.known and not h.knocked and (h.lockedUntil or 0) > now() then
        game.stack:push(TextBox.new(game,
          Strings("Please try again\nin 5 minutes."))); return
      end
      if not h.known and not h.knocked then
        self.kantoLifeTrespass = { home = dest, from = from }
      end
      h.knocked = nil
      homes[key(dest)] = h; saveHomes()
    end
    return baseWarp(self, warpDef)
  end

  local baseUpdate = Overworld.update
  Overworld.update = function(self, dt)
    baseUpdate(self, dt)
    local trespass = self.kantoLifeTrespass
    if trespass and self.map.id == trespass.home and not self.kantoLifeResolving then
      self.kantoLifeTrespass, self.kantoLifeResolving = nil, true
      local function eject(seconds)
        local h = homes[key(trespass.home)] or {}
        if seconds > 0 then h.lockedUntil = now() + seconds end
        homes[key(trespass.home)] = h; saveHomes()
        game.stack:push(TextBox.new(game, Strings("Please come back\nlater, and KNOCK!"), function()
          self.doorWarp = true
          self:startWarpTo(trespass.from.map, trespass.from.x, trespass.from.y, "down")
          self.kantoLifeResolving = false
        end))
      end
      local npc = self.npcs and self.npcs[1]
      if npc and npc.def and npc.def.trainerClass then
        game.stack:push(TextBox.new(game, Strings(wake(npc.def)), function()
          self:engageTrainer(npc, function()
            if game.save.defeatedTrainers and game.save.defeatedTrainers[npc.id] then
              homes[key(trespass.home)] = { known = true }; saveHomes(); self.kantoLifeResolving = false
            else eject(5) end
          end)
        end))
      else eject(0) end
    end
    if self.kantoLifeWelcome and self.map.id == self.kantoLifeWelcome then
      self.kantoLifeWelcome = nil
      game.stack:push(TextBox.new(game,
        Strings("Welcome! Thank you\nfor knocking.")))
    end

    local sleepingOn = opt("sleeping_npcs")
    local isNight = night(self)
    for _, npc in ipairs(self.npcs or {}) do
      if isSpecialCharacter(npc) then
        if npc.nightlifeSleeping then wakeNpc(npc) end
      elseif sleepingOn and isNight then
        putToSleep(npc)
      elseif npc.nightlifeSleeping then
        wakeNpc(npc)
      end
    end
  end

  local baseTalk = Overworld.talkTo
  Overworld.talkTo = function(self, npc)
    local d = npc and npc.def
    if not d then return baseTalk(self, npc) end
    if isAmbientNpc(npc) and not night(self) then
      local route = tostring(d.name or ""):match("^KANTO_ROUTE")
      local text = route and "I'm traveling\nbetween towns today."
        or "KANTO feels busy\nthese days!"
      return game.stack:push(TextBox.new(game, Strings(text)))
    end
    if not night(self) or not opt("sleeping_npcs") then
      return baseTalk(self, npc)
    end
    if isSpecialCharacter(npc) then return baseTalk(self, npc) end
    if not isAmbientNpc(npc) and MapScripts.talkScript(self.map.id, d.text) then
      return baseTalk(self, npc)
    end
    if d.trainerClass then
      return game.stack:push(TextBox.new(game, Strings(wake(d)), function() baseTalk(self, npc) end))
    end
    npc.frozen = true
    game.stack:push(TextBox.new(game, Strings("%s is fast\nasleep.", (d.name or "This person"):gsub("_", " "))))
  end
end
