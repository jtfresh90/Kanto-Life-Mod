-- Kanto Life FireRed / Gen 3 implementation.
-- This file is deliberately isolated from the Gen 1 and Gen 2 implementations.
return function(mod)
  local function loadLocal(rel)
    local source, err = mod:read(rel)
    if type(source) ~= "string" then
      error("Kanto Life: missing bundled file " .. rel .. ": " .. tostring(err), 0)
    end
    local compile = loadstring or load
    local chunk, compileErr = compile(source, "@" .. mod.path .. "/" .. rel)
    if not chunk then error("Kanto Life: cannot compile " .. rel .. ": " .. tostring(compileErr), 0) end
    local ok, value = pcall(chunk)
    if not ok then error("Kanto Life: cannot load " .. rel .. ": " .. tostring(value), 0) end
    return value
  end

  -- FireRed gets the same Kanto/Johto-facing option surface and ordering.
  -- The routine controller consumes ROUTINES / TRAVEL / AGENDA; the remaining
  -- values are persisted here so the native OPTIONS screen is identical in
  -- shape and the settings survive switching games.
  mod.options:define({
    { key = "firered_extra_npcs", type = "toggle", label = "EXTRA NPCS", default = true },
    { key = "firered_extra_npc_count", type = "number", label = "EXTRA NPC COUNT", default = 0, min = 0, max = 150, step = 1 },
    { key = "firered_indoor_npcs", type = "toggle", label = "INDOOR NPCS", default = true },
    { key = "firered_indoor_npc_count", type = "number", label = "INDOOR NPC COUNT", default = 3, min = 0, max = 30, step = 1 },
    { key = "firered_poke_npcs", type = "toggle", label = "POKEMON NPCS", default = false },
    { key = "firered_poke_npc_count", type = "number", label = "POKE NPC COUNT", default = 0, min = 0, max = 50, step = 1 },
    { key = "firered_poke_random", type = "toggle", label = "RANDOM POKE NPCS", default = true },
    { key = "firered_sleeping_npcs", type = "toggle", label = "SLEEPING NPCS", default = true },
    { key = "firered_sleep_pct", type = "number", label = "SLEEP RATE %", default = 10, min = 0, max = 100, step = 10 },
    { key = "firered_day_sleepers", type = "toggle", label = "DAY SLEEPERS", default = true },
    { key = "firered_sleep_bubbles", type = "toggle", label = "SLEEP ZZZ", default = true },
    { key = "firered_sleep_style", type = "choice", label = "SLEEP STYLE", default = 0, choices = { { "Default", 0 }, { "Tent", 1 }, { "Sleeping Bag", 2 }, { "Bed", 3 }, { "Random", 4 }, { "Natural", 5 } } },
    { key = "firered_npc_collision_bubbles", type = "toggle", label = "NPC TALK BUBBLES", default = true },
    { key = "firered_common_courtesy", type = "toggle", label = "DOOR KNOCKING", default = true },
    { key = "firered_npc_routines", type = "toggle", label = "NPC ROUTINES", default = true },
    { key = "firered_npc_travel_pct", type = "number", label = "NPC TRAVEL %", default = 70, min = 0, max = 100, step = 10 },
    { key = "firered_npc_travel_methods", type = "toggle", label = "TRAVEL METHODS", default = true },
    { key = "firered_npc_agenda", type = "choice", label = "NPC AGENDA", default = 0, choices = { { "OFF", 0 }, { "DAY", 1 }, { "FULL", 2 } } },
  })

  if mod.save and type(mod.save.get) == "function" and type(mod.save.set) == "function" then
    local okSeed, seeded = pcall(mod.save.get, mod.save, "fireredNpcTravelPctV2Seeded")
    if okSeed and not seeded then
      pcall(mod.save.set, mod.save, "firered_npc_travel_pct", 70)
      pcall(mod.save.set, mod.save, "fireredNpcTravelPctV2Seeded", true)
    end
  end

  local function resolveGame()
    -- FireRed's mod facade is sandboxed before Game3 is fully wired, so the
    -- lazy mod.game/mod.world fields are not reliable from nested controller
    -- chunks. Runtime._game is the authoritative live Game3 owner.
    local okRuntime, Runtime = pcall(require, "src.core.game3.runtime")
    if okRuntime and Runtime and Runtime._game ~= nil then return Runtime._game end
    local ok, Game3 = pcall(require, "src.core.Game3")
    if ok and type(Game3) == "table" and type(Game3.new) == "function" then
      -- No singleton is exposed by Game3; keep this fallback only for the
      -- loader's injected game if one is available.
    end
    return nil
  end

  local function resolveWorld()
    local g = resolveGame()
    if not g then return nil end
    local okGV, GV = pcall(require, "src.core.GameVersion")
    local layout = okGV and GV and GV.layout and GV.layout() or nil

    -- The Gen3Compat/WorldAPI adapter intentionally stops at FRLG because its
    -- map bridge manufactures FR_* Kanto ids. Emerald is the same Game3 engine
    -- but must use its native EM_* map ids, so give Kanto Life the small live
    -- world handle it actually needs instead of routing Emerald through that
    -- FRLG-only adapter.
    if layout == "rse" then
      local Objects = require("src.core.game3.objects")
      local Collision = require("src.core.game3.collision")
      local Player = require("src.core.game3.player")
      local P = require("src.core.game3.pokemon")
      local BattleBridge = require("src.core.game3.battle_bridge")
      local W = {}
      function W:npc(_mapId, indexOrName)
        for _, lid in ipairs(Objects._order or {}) do
          local eo = Objects._byId and Objects._byId[lid]
          local def = eo and eo.def
          if eo and (lid == indexOrName or (def and (def.name == indexOrName or def.id == indexOrName))) then
            local H = {}
            function H:position() return eo.cellX, eo.cellY end
            function H:isMoving() return eo.moving and true or false end
            function H:canStep(dir)
              local d = ({up={0,-1},down={0,1},left={-1,0},right={1,0}})[dir]
              if not d then return false end
              local tx, ty = eo.cellX + d[1], eo.cellY + d[2]
              if not Collision.canEnter(nil, tx, ty, { fromX=eo.cellX, fromY=eo.cellY, dir=dir }) then return false end
              return true
            end
            function H:stepNow(dir)
              if eo.moving then return nil, "already moving" end
              local d = ({up={0,-1},down={0,1},left={-1,0},right={1,0}})[dir]
              if not d then return nil, "bad direction" end
              local wasFrozen, wasBusy = eo.frozen, eo.scriptBusy
              local okStep = Objects.scriptStep(eo, dir)
              eo.frozen, eo.scriptBusy = wasFrozen, wasBusy
              return okStep and true or nil, okStep and nil or "step rejected"
            end
            function H:placeAt(x,y,facing)
              eo.moving=false; eo.progress=0; eo.cellX=x; eo.cellY=y; eo.targetX=x; eo.targetY=y
              eo.px=x*16; eo.py=y*16; if facing then eo.facing=facing end
              return true
            end
            return H
          end
        end
        return nil, "no such object"
      end
      function W:startWildBattle(species, level, onDone)
        local sid = type(species) == "number" and species or (P and P.speciesFromName and P.speciesFromName(species))
        if not (sid and P and P._names and P._names[sid]) then return nil, "unknown species" end
        level = tonumber(level)
        if not level or level < 1 or level > 100 then return nil, "bad level" end
        if not (BattleBridge and BattleBridge.startWild) then return nil, "wild battle unavailable" end
        local ok, err = BattleBridge.startWild(nil, g, {species=sid, level=level}, {done=onDone and function() onDone() end or nil})
        return ok and true or nil, err
      end
      return W
    end

    local ok, WorldAPI = pcall(require, "src.world.game3.WorldAPI")
    if not ok or type(WorldAPI) ~= "table" or type(WorldAPI.new) ~= "function" then return nil end
    return WorldAPI.new(g, mod.id)
  end

  local function resolveFieldState()
    local g = resolveGame()
    if not g or g.phase ~= "field" then return nil end
    local okMap, Map = pcall(require, "src.core.game3.map")
    local okCol, Collision = pcall(require, "src.core.game3.collision")
    local okMoves, FieldMoves = pcall(require, "src.core.game3.field_moves")
    if not (okMap and Map and okCol and Collision) then return nil end
    local mapId = Map.current
    local def = Map.currentDef and Map.currentDef() or (g.data and g.data.maps and g.data.maps[mapId])
    if not mapId or not def then return nil end
    local map = {
      id = mapId, gen3Id = mapId, def = def,
      warps = def.warps or {},
      widthCells = tonumber(Collision._widthCells) or 0,
      heightCells = tonumber(Collision._heightCells) or 0,
    }
    function map:isWalkableCell(x, y) return Collision.isWalkable(x, y) end
    function map:isOutdoor()
      if okMoves and FieldMoves and FieldMoves.isOutdoors then
        return FieldMoves.isOutdoors(def.mapType)
      end
      return false
    end
    return { map = map }
  end

  -- Read the live persisted bucket first.  FireRed's native option UI and
  -- the mod-options facade are not the same writer; relying on
  -- mod.options:set() alone is unsafe because older/current loaders may only
  -- expose :define/:get.  This also makes an in-game change immediately
  -- visible to every FireRed controller.
  local function opt(key, default)
    local g = resolveGame()
    if g and g.save and g.save.options and g.save.options.modOptions
        and g.save.options.modOptions[mod.id]
        and g.save.options.modOptions[mod.id][key] ~= nil then
      return g.save.options.modOptions[mod.id][key]
    end
    if g and g.mods and g.mods.modOptions and g.mods.modOptions[mod.id]
        and g.mods.modOptions[mod.id][key] ~= nil then
      return g.mods.modOptions[mod.id][key]
    end
    if mod.options and type(mod.options.get) == "function" then
      local ok, v = pcall(mod.options.get, mod.options, key)
      if ok and v ~= nil then return v end
    end
    return default
  end

  local function setOpt(key, value)
    local g = resolveGame()
    local loader = g and g.mods
    if loader then
      loader.modOptions = loader.modOptions or {}
      loader.modOptions[mod.id] = loader.modOptions[mod.id] or {}
      loader.modOptions[mod.id][key] = value
    end
    local okSave, SaveData = pcall(require, "src.core.SaveData")
    if okSave and SaveData and type(SaveData.loadOptions) == "function"
        and type(SaveData.saveOptions) == "function" then
      pcall(function()
        local opts = SaveData.loadOptions()
        if type(opts) ~= "table" then return end
        opts.modOptions = opts.modOptions or {}
        opts.modOptions[mod.id] = opts.modOptions[mod.id] or {}
        opts.modOptions[mod.id][key] = value
        SaveData.saveOptions(opts)
      end)
    end
    if g and g.save then
      g.save.options = g.save.options or {}
      g.save.options.modOptions = g.save.options.modOptions or {}
      g.save.options.modOptions[mod.id] = g.save.options.modOptions[mod.id] or {}
      g.save.options.modOptions[mod.id][key] = value
    end
    if loader and loader.events and type(loader.events.emit) == "function" then
      loader.events:emit("mod.options_changed", { mod = mod.id, key = key, value = value })
    end
    return true
  end

  local getWorld = resolveWorld
  local getFieldState = resolveFieldState

  local FireRedRoutines = loadLocal("lib/FireRedRoutines.lua")
  local FireRedSleep = loadLocal("lib/FireRedSleep.lua")
  local FireRedAmbient = loadLocal("lib/FireRedAmbient.lua")
  local FireRedInteractions = loadLocal("lib/FireRedInteractions.lua")
  local FireRedDoorKnocking = loadLocal("lib/FireRedDoorKnocking.lua")
  local okFactory, routines = pcall(FireRedRoutines, { mod = mod, getOption = opt, getWorld = getWorld, getFieldState = getFieldState })
  if not okFactory or type(routines) ~= "table" then
    error("Kanto Life: FireRed routine controller failed: " .. tostring(routines), 0)
  end

  routines:setTravelPercent(opt("firered_npc_travel_pct", 70))
  routines:setAgenda(opt("firered_npc_agenda", 0))
  routines:setEnabled(opt("firered_npc_routines", true) ~= false)

  -- NPC-to-NPC collision speech: draw only while the short collision event is active.
  pcall(function()
    local FieldView = require("src.core.game3.field_view")
    if FieldView and not FieldView._kantoLifeCollisionBubbleWrapped then
      local baseDraw = FieldView.draw
      FieldView.draw = function(game_, canvasW, canvasH, opts)
        local result = baseDraw(game_, canvasW, canvasH, opts)
        if opt("firered_npc_collision_bubbles") == false then return result end
        local Runtime = require("src.core.game3.runtime")
        local Objects = require("src.core.game3.objects")
        local Player = require("src.core.game3.player")
        local px, py = Player.px or 0, Player.py or 0
        local cw, ch = canvasW or 240, canvasH or 160
        local camX = math.floor(px + 8 - cw / 2) + (FieldView.cameraPanX or 0)
        local camY = math.floor(py + 8 - ch / 2) + (FieldView.cameraPanY or 0)
        local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
        for _, npc in ipairs(Objects.forDraw and Objects.forDraw() or {}) do
          local untilAt = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
          if untilAt > now and npc.visible ~= false and not npc.hidden then
            local text = tostring(npc._kantoLifeCollisionBubbleText or ":)")
            local font = love.graphics.getFont()
            local tw = font:getWidth(text)
            local th = font:getHeight()
            local w = math.max(22, tw + 10)
            local h = math.max(13, th + 5)
            local sx = (tonumber(npc.px) or npc.cellX * 16) - camX + 8
            local sy = (tonumber(npc.py) or npc.cellY * 16) - camY - h - 4
            local left = sx - w / 2
            local top = sy
            love.graphics.push("all")
            love.graphics.setColor(1,1,1,1); love.graphics.rectangle("fill",left,top,w,h,2,2)
            love.graphics.setColor(0.1,0.1,0.1,1); love.graphics.rectangle("line",left,top,w,h,2,2)
            love.graphics.polygon("fill",sx-2,top+h,sx+2,top+h,sx,top+h+3)
            love.graphics.setColor(0.1,0.1,0.1,1)
            love.graphics.print(text, sx - tw / 2, top + (h - th) / 2)
            love.graphics.pop()
          end
        end
        return result
      end
      FieldView._kantoLifeCollisionBubbleWrapped = true
    end
  end)

  local okSleepFactory, sleep = pcall(FireRedSleep, { mod = mod, getOption = opt, getWorld = getWorld, getFieldState = getFieldState })
  if not okSleepFactory or type(sleep) ~= "table" then
    error("Kanto Life: FireRed sleep controller failed: " .. tostring(sleep), 0)
  end

  local okAmbientFactory, ambient = pcall(FireRedAmbient, { mod = mod, getOption = opt, setOption = setOpt, getWorld = getWorld, getFieldState = getFieldState })
  if not okAmbientFactory or type(ambient) ~= "table" then
    error("Kanto Life: FireRed ambient NPC controller failed: " .. tostring(ambient), 0)
  end
  if type(routines.setRoutineExitHandler) == "function" then
    routines:setRoutineExitHandler(function(npc, x, y, avoidX, avoidY)
      return ambient:handleRoutineExit(npc, x, y, avoidX, avoidY)
    end)
  end

  local okInteractionFactory, interactions = pcall(FireRedInteractions, {
    mod = mod, getOption = opt, getWorld = getWorld, getFieldState = getFieldState,
    onPokemonBattleStart = function(npc, species)
      return ambient:markPokemonBattle(npc, species)
    end,
  })
  if not okInteractionFactory or type(interactions) ~= "table" then
    error("Kanto Life: FireRed interaction controller failed: " .. tostring(interactions), 0)
  end

  -- A caught Kanto Life Pokémon is a transient overworld population member,
  -- not a permanent ROM object. Replace it only after a real "caught" result;
  -- wins/runs/losses leave the existing NPC in place.
  mod.events:on("battle.ended", function(payload)
    if type(payload) == "table" then
      ambient:handleBattleEnded(payload.result)
    end
  end)

  local okDoorFactory, doorKnocking = pcall(FireRedDoorKnocking, { mod = mod, getOption = opt, getWorld = getWorld, getFieldState = getFieldState })
  if not okDoorFactory or type(doorKnocking) ~= "table" then
    error("Kanto Life: FireRed door-knocking controller failed: " .. tostring(doorKnocking), 0)
  end

  mod.events:on("game.ready", function()
    local ow = getFieldState()
    if ow then
      ambient:rebuild(true)
      routines:update(ow, 0)
      sleep:rebuild(true)
      sleep:update()
    end
  end)

  -- Game3's world.stepped event only fires when the player completes a
  -- movement step. Kanto Life NPCs must continue their routines while the
  -- player stands still, so drive the controllers from the engine's per-frame
  -- input.step hook instead. This keeps movement autonomous without changing
  -- any vanilla FireRed movement code.
  if mod.hooks and type(mod.hooks.wrap) == "function" then
    mod.hooks:wrap("input.step", function(next, game, dt)
      local result = next(game, dt)
      if game and game.phase == "field" then
        ambient:update()
        local ow = getFieldState()
        if ow then routines:update(ow, dt or 0.016) end
        sleep:update()
      end
      return result
    end)
  end

  mod.events:on("map.entered", function()
    local ow = getFieldState()
    if ow then
      ambient:rebuild(true)
      routines:update(ow, 1)
      sleep:rebuild(true)
      sleep:update()
    end
  end)

  mod.events:on("mod.options_changed", function(payload)
    if type(payload) ~= "table" then return end
    if payload.mod and payload.mod ~= mod.id then return end
    if payload.key == "firered_npc_routines" then
      routines:setEnabled(payload.value ~= false)
    elseif payload.key == "firered_npc_travel_pct" then
      routines:setTravelPercent(payload.value)
    elseif payload.key == "firered_npc_agenda" then
      routines:setAgenda(payload.value)
    elseif payload.key == "firered_sleeping_npcs" or payload.key == "firered_sleep_pct"
        or payload.key == "firered_day_sleepers" or payload.key == "firered_sleep_bubbles" or payload.key == "firered_sleep_style" or payload.key == "firered_npc_collision_bubbles" then
      if payload.key == "firered_sleeping_npcs" and payload.value == false then
        sleep:wakeAll()
      end
      sleep:rebuild(true)
    elseif payload.key == "firered_extra_npcs" or payload.key == "firered_extra_npc_count"
        or payload.key == "firered_indoor_npcs" or payload.key == "firered_indoor_npc_count"
        or payload.key == "firered_poke_npcs" or payload.key == "firered_poke_npc_count"
        or payload.key == "firered_poke_random" then
      ambient:rebuild(true)
      local ow = getFieldState()
      if ow then routines:update(ow, 1) end
      sleep:rebuild(true)
    end
  end)

  -- FireRed's OPTION screen is a native Game3 modal stack.  The working
  -- GameShark Gen3 implementation uses that same stack directly instead of
  -- trying to push a Gen1/Gen2 ListMenu or inventing a second screen system.
  -- Kanto Life follows that proven Game3 pattern here.
  do
    local okRows, Game3Rows = pcall(require, "src.ui.game3.option_rows")
    local okStack, Game3Stack = pcall(require, "src.ui.game3.stack")
    if okRows and type(Game3Rows) == "table" and type(Game3Rows.build) == "function"
        and okStack and type(Game3Stack) == "table"
        and type(Game3Stack.push) == "function" and type(Game3Stack.pop) == "function" then

      local KantoLifeMenu = {
        open = false,
        cursor = 1,
        scroll = 0,
      }

      local VISIBLE = 7

      local function rows()
        local agendaNames = { [0] = "OFF", [1] = "DAY", [2] = "FULL" }
        return {
          { key="firered_extra_npcs", label="EXTRA NPCS", kind="bool", default=true },
          { key="firered_extra_npc_count", label="EXTRA NPC COUNT", kind="number", default=0, min=0, max=150, step=1 },
          { key="firered_indoor_npcs", label="INDOOR NPCS", kind="bool", default=true },
          { key="firered_indoor_npc_count", label="INDOOR NPC COUNT", kind="number", default=3, min=0, max=30, step=1 },
          { key="firered_poke_npcs", label="POKEMON NPCS", kind="bool", default=false },
          { key="firered_poke_npc_count", label="POKE NPC COUNT", kind="number", default=0, min=0, max=50, step=1 },
          { key="firered_poke_random", label="RANDOM POKE NPCS", kind="bool", default=true },
          { key="firered_sleeping_npcs", label="SLEEPING NPCS", kind="bool", default=true },
          { key="firered_sleep_pct", label="SLEEP RATE %", kind="number", default=10, min=0, max=100, step=10 },
          { key="firered_day_sleepers", label="DAY SLEEPERS", kind="bool", default=true },
          { key="firered_sleep_bubbles", label="SLEEP ZZZ", kind="bool", default=true },
          { key="firered_sleep_style", label="SLEEP STYLE", kind="sleepstyle", default=0, min=0, max=5, step=1 },
          { key="firered_npc_collision_bubbles", label="NPC TALK BUBBLES", kind="bool", default=true },
          { key="firered_common_courtesy", label="DOOR KNOCKING", kind="bool", default=true },
          { key="firered_npc_routines", label="NPC ROUTINES", kind="bool", default=true },
          { key="firered_npc_travel_pct", label="NPC TRAVEL %", kind="number", default=70, min=0, max=100, step=10 },
          { key="firered_npc_travel_methods", label="TRAVEL METHODS", kind="bool", default=true },
          { key="firered_npc_agenda", label="NPC AGENDA", kind="agenda", default=0, min=0, max=2, names=agendaNames },
        }
      end

      local function valueFor(r)
        local v = opt(r.key, r.default)
        if r.kind == "bool" then return v and "ON" or "OFF" end
        if r.kind == "agenda" then
          return r.names[tonumber(v) or 0] or "OFF"
        end
        if r.kind == "sleepstyle" then
          return ({[0]="Default",[1]="Tent",[2]="Sleeping Bag",[3]="Bed",[4]="Random"})[tonumber(v) or 0] or "Default"
        end
        return tostring(tonumber(v) or r.default)
      end

      local function setAndApply(r, value)
        setOpt(r.key, value)
        if r.key == "firered_npc_routines" then
          routines:setEnabled(value ~= false)
        elseif r.key == "firered_npc_travel_pct" then
          routines:setTravelPercent(value)
        elseif r.key == "firered_npc_agenda" then
          routines:setAgenda(value)
        elseif r.key == "firered_sleeping_npcs" and value == false then
          sleep:wakeAll()
          sleep:rebuild(true)
        elseif r.key == "firered_sleeping_npcs"
            or r.key == "firered_sleep_pct"
            or r.key == "firered_day_sleepers"
            or r.key == "firered_sleep_bubbles" then
          sleep:rebuild(true)
        elseif r.key == "firered_extra_npcs"
            or r.key == "firered_extra_npc_count"
            or r.key == "firered_indoor_npcs"
            or r.key == "firered_indoor_npc_count"
            or r.key == "firered_poke_npcs"
            or r.key == "firered_poke_npc_count"
            or r.key == "firered_poke_random" then
          ambient:rebuild(true)
        end
      end

      local function clamp()
        local list = rows()
        if #list == 0 then KantoLifeMenu.cursor = 1; KantoLifeMenu.scroll = 0; return end
        KantoLifeMenu.cursor = math.max(1, math.min(#list, KantoLifeMenu.cursor))
        if KantoLifeMenu.cursor - KantoLifeMenu.scroll > VISIBLE then
          KantoLifeMenu.scroll = KantoLifeMenu.cursor - VISIBLE
        elseif KantoLifeMenu.cursor - KantoLifeMenu.scroll < 1 then
          KantoLifeMenu.scroll = KantoLifeMenu.cursor - 1
        end
        KantoLifeMenu.scroll = math.max(0, math.min(KantoLifeMenu.scroll, math.max(0, #list - VISIBLE)))
      end

      local function move(delta)
        local list = rows()
        if #list == 0 then return end
        KantoLifeMenu.cursor = ((KantoLifeMenu.cursor - 1 + delta) % #list) + 1
        clamp()
      end

      local function adjust(dir)
        local list = rows()
        local r = list[KantoLifeMenu.cursor]
        if not r then return end
        local cur = opt(r.key, r.default)
        if r.kind == "bool" then
          setAndApply(r, cur ~= true)
          return
        end
        if r.kind == "agenda" then
          local nextValue = (tonumber(cur) or 0) + ((dir < 0) and -1 or 1)
          if nextValue < r.min then nextValue = r.max end
          if nextValue > r.max then nextValue = r.min end
          setAndApply(r, nextValue)
          return
        end
        local nextValue = (tonumber(cur) or r.default) + ((dir < 0) and -r.step or r.step)
        if nextValue < r.min then nextValue = r.min end
        if nextValue > r.max then nextValue = r.max end
        if nextValue ~= tonumber(cur) then setAndApply(r, nextValue) end
      end

      function KantoLifeMenu.show()
        KantoLifeMenu.open = true
        KantoLifeMenu.cursor = 1
        KantoLifeMenu.scroll = 0
        Game3Stack.push("kantoLife", KantoLifeMenu, { hideBelow = true })
      end

      function KantoLifeMenu.close()
        if not KantoLifeMenu.open then return end
        KantoLifeMenu.open = false
        Game3Stack.pop("kantoLife")
      end

      function KantoLifeMenu.handleInput(input)
        if not input then return end
        if input:wasPressed("up") then
          move(-1)
        elseif input:wasPressed("down") then
          move(1)
        elseif input:wasPressed("left") then
          adjust(-1)
        elseif input:wasPressed("right") then
          adjust(1)
        elseif input:wasPressed("a") then
          adjust(1)
        elseif input:wasPressed("b") or input:wasPressed("start") then
          KantoLifeMenu.close()
        end
        clamp()
      end

      function KantoLifeMenu.update()
        -- Game3's stack dispatches input only to the top modal layer.
      end

      function KantoLifeMenu.draw()
        if not KantoLifeMenu.open then return end
        local Window = require("src.ui.game3.window")
        local okFont, Font = pcall(require, "src.ui.game3.frlg_font")
        local Chrome = require("src.ui.game3.chrome")
        local normalColor = okFont and Font and Font.COLOR and Font.COLOR.NORMAL or {1,1,1,1}
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.rectangle("fill", 0, 0, 240, 160)
        love.graphics.setColor(1, 1, 1, 1)
        Chrome.fixedStdFrame(1, 1, 28, 3)
        Window.printPx("KANTO LIFE", 16, 12, { colors = normalColor })
        Window.userFrame(Window.template(1, 5, 28, 14), 0)

        clamp()
        local list = rows()
        for slot = 1, VISIBLE do
          local i = KantoLifeMenu.scroll + slot
          local r = list[i]
          if not r then break end
          local y = 45 + (slot - 1) * 14
          if i == KantoLifeMenu.cursor then Window.cursorPx(10, y) end
          Window.printPx(r.label, 18, y, { colors = Font.COLOR.NORMAL, maxWidth = 150 })
          Window.printPx(valueFor(r), 180, y, { colors = Font.COLOR.NORMAL, maxWidth = 48 })
        end
      end

      if not Game3Rows.__kantoLifeFireRedPatched then
        local baseBuild = Game3Rows.build
        Game3Rows.build = function(ctx)
          local base = baseBuild(ctx)
          if type(base) ~= "table" then return base end
          for _, r in ipairs(base) do
            if r and r.id == "kantoLife" then return base end
          end
          base[#base + 1] = {
            id = "kantoLife",
            label = "KANTO LIFE",
            value = function() return ">" end,
            activate = function()
              KantoLifeMenu.show()
            end,
          }
          return base
        end
        Game3Rows.__kantoLifeFireRedPatched = true
      end
    end
  end

  mod.exports = mod.exports or {}
  mod.exports.generation = 3
  mod.exports.fireRedRoutines = routines
  mod.exports.fireRedAmbient = ambient
  mod.exports.fireRedSleep = sleep
end
