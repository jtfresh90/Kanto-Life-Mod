-- FireRed Kanto Life house-door etiquette.
-- A press of A while facing a house entrance is the knock.  The next entry
-- through that exact door is allowed once.  Walking through without knocking
-- still lets FireRed perform the normal door transition; immediately after
-- arrival the visitor is told to knock and is sent back outside.
-- Knocking applies to houses only: marts, Poke Centers, gyms and other
-- non-house buildings always allow free entry without knocking.
return function(ctx)
  local mod = ctx.mod
  local getOption = ctx.getOption
  local api = {}
  local armed = {}
  local pending = nil
  local lastGame = nil
  local lastMap = nil
  local authorizedDestMap = nil
  local installed = false
  local modalActive = false
  local suppressAUntilRelease = false
  local warpInProgress = false
  local warpStartMap = nil

  local function opt(key, default)
    if type(getOption) == "function" then
      local ok, v = pcall(getOption, key, default)
      if ok and v ~= nil then return v end
    end
    if mod.options and type(mod.options.get) == "function" then
      local ok, v = pcall(mod.options.get, mod.options, key)
      if ok and v ~= nil then return v end
    end
    return default
  end

  local function engine(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
  end

  -- House-only classification for door knocking.  Known service/non-house
  -- interiors (marts, Poke Centers, gyms, dept stores, labs, ...) are excluded
  -- by name first; only actual house names ("HOUSE", "HOME", "PLAYERS_HOUSE",
  -- ...) count as houses.  This mirrors Yellow's name-based resident() in
  -- lib/KantoMain.lua.  The old "every indoor map is a house" isOutdoors
  -- fallback is intentionally gone: it made every mart, center and gym
  -- require knocking.
  local NON_HOUSE_PATTERNS = {
    "MART", "POKECENTER", "POKE_CENTER", "POKEMON_CENTER", "CENTER",
    "GYM", "DEPT", "LAB", "MUSEUM", "GAME_CORNER", "HOTEL",
    "RESTAURANT", "SCHOOL", "DAYCARE", "POWER_PLANT", "SAFARI",
    "SILPH", "ROCKET", "MANSION", "SHIP", "DOCK", "GATE",
    "TOWER", "CAVE", "TUNNEL",
  }
  local HOUSE_PATTERNS = {
    "PLAYERS_HOUSE", "RIVALS_HOUSE", "HOUSE", "_HOME", "HOME_",
  }
  local function houseMap(id)
    local s = string.upper(tostring(id or ""))
    if s == "" then return false end
    -- Service and non-residential interiors never count as houses, even if a
    -- map id happens to combine a service word with a house-like word.
    for _, pattern in ipairs(NON_HOUSE_PATTERNS) do
      if s:find(pattern, 1, true) ~= nil then return false end
    end
    for _, pattern in ipairs(HOUSE_PATTERNS) do
      if s:find(pattern, 1, true) ~= nil then return true end
    end
    return false
  end

  local function doorInfo(game)
    local Player = engine("src.core.game3.player")
    local Collision = engine("src.core.game3.collision")
    if not (Player and Collision and Collision.isDoorWarp) then return nil end
    local facing = tostring(Player.facing or "up"):lower()
    local delta = ({ up={0,-1}, down={0,1}, left={-1,0}, right={1,0} })[facing] or {0,-1}
    local checks = {
      { Player.cellX + delta[1], Player.cellY + delta[2] },
      { Player.cellX, Player.cellY - 1 },
    }
    local seen = {}
    for _, c in ipairs(checks) do
      local k = tostring(c[1]) .. ":" .. tostring(c[2])
      if not seen[k] then
        seen[k] = true
        local ok, info = pcall(Collision.isDoorWarp, game, c[1], c[2])
        if ok and info then return info end
      end
    end
    return nil
  end

  local function key(game, info)
    local Map = engine("src.core.game3.map")
    local map = (Map and Map.current) or (game and game.currentMap) or ""
    return table.concat({ tostring(map), tostring(info.x), tostring(info.y), tostring(info.destMap) }, ":")
  end

  local function show(text, done)
    local Message = engine("src.ui.game3.message")
    if not Message or type(Message.show) ~= "function" then
      if done then done() end
      return
    end
    Message.show(text, function()
      if Message.close then Message.close() end
      if done then done() end
    end)
  end

  local function knock(game)
    if modalActive then return true end
    local info = doorInfo(game)
    if not info then return false end
    -- Knocking is for houses only.  Marts, Poke Centers, gyms and other
    -- non-house buildings keep FireRed's normal free entry.
    if not houseMap(info.destMap) then return false end
    modalActive = true
    suppressAUntilRelease = true
    local doorKey = key(game, info)
    local Audio = engine("src.core.game3.audio")
    local SE = engine("src.core.game3.se_ids")
    if Audio and SE and Audio.playSe and SE.SE_DOOR then pcall(Audio.playSe, SE.SE_DOOR) end

    -- FireRed's native Choice module owns cursor movement and A/B handling.
    -- Do not auto-authorize the entry: the player must explicitly choose YES.
    show("KNOCK KNOCK!", function()
      local Choice = engine("src.ui.game3.choice")
      if not Choice or type(Choice.yesNo) ~= "function" then
        -- If the choice UI is unavailable, fail closed rather than silently
        -- allowing entry without the required confirmation.
        armed[doorKey] = nil
        modalActive = false
        return
      end
      Choice.yesNo(function(yes)
        if yes then
          armed[doorKey] = true
          authorizedDestMap = info.destMap
          show("Welcome In!", function()
            local Warp = engine("src.core.game3.warp")
            local Runtime = engine("src.core.game3.runtime")
            local g = game or (Runtime and Runtime._game)
            local m = Runtime and Runtime._mod
            -- Mark warp in progress BEFORE starting it, so the A press that
            -- dismissed this message can't re-trigger knock during transition.
            warpInProgress = true
            local Map = engine("src.core.game3.map")
            warpStartMap = (Map and Map.current) or (g and g.currentMap)
            suppressAUntilRelease = true
            if Warp and type(Warp.startDoorEntrance) == "function" then
              pcall(Warp.startDoorEntrance, m, g, info.destMap, info.destX, info.destY, info.x, info.y)
            end
            modalActive = false
          end)
        else
          armed[doorKey] = nil
          if authorizedDestMap == info.destMap then authorizedDestMap = nil end
          show("Please knock before entering!", function()
            modalActive = false
          end)
        end
      end)
    end)
    return true
  end

  local function watchEntry(game)
    local Player = engine("src.core.game3.player")
    local Collision = engine("src.core.game3.collision")
    if not (Player and Collision and Collision.isDoorWarp) then return false end
    local Map = engine("src.core.game3.map")
    local currentMap = (Map and Map.current) or (game and game.currentMap)
    if not houseMap(currentMap) then return false end
    if not pending then return false end
    local exit = Collision.isExitWarp(game, Player.cellX, Player.cellY)
    if not exit then pending = nil; return false end
    local entryKey = pending.key
    local wasKnock = pending.authorized == true
    pending = nil
    armed[entryKey] = nil
    if wasKnock then
      return true
    end
    show("Please knock before entering!", function()
      local Warp = engine("src.core.game3.warp")
      if Warp and Warp.startDoorExit then
        local Runtime = engine("src.core.game3.runtime")
        local g = game or (Runtime and Runtime._game)
        local m = Runtime and Runtime._mod
        pcall(Warp.startDoorExit, m, g, exit.destMap, exit.destX, exit.destY, Player.cellX, Player.cellY)
      end
    end)
    return true
  end

  local function install()
    if installed or not mod.hooks or not mod.hooks.wrap then return end
    local ok = pcall(function()
      -- Intercept the actual source edge, before Input:step() promotes it to
      -- the field logic.  This covers keyboard and controller A equally.
      mod.hooks:wrap("input.key", function(next, game, ev)
        local input = game and game.input
        local isA = input and input.keyBindings and ev
          and ev.phase == "pressed" and input.keyBindings[ev.key] == "a"
        if isA and not modalActive and not suppressAUntilRelease and not warpInProgress
            and opt("firered_common_courtesy", true) ~= false
            and game and game.phase == "field" and knock(game) then
          return true
        end
        if ev and ev.phase == "released" and input and input.keyBindings
            and input.keyBindings[ev.key] == "a" then
          suppressAUntilRelease = false
        end
        return next(game, ev)
      end)
      mod.hooks:wrap("input.gamepad", function(next, game, ev)
        local input = game and game.input
        local isA = input and input.padBindings and ev
          and ev.phase == "pressed" and input.padBindings[ev.button] == "a"
        if isA and not modalActive and not suppressAUntilRelease and not warpInProgress
            and opt("firered_common_courtesy", true) ~= false
            and game and game.phase == "field" and knock(game) then
          return true
        end
        if ev and ev.phase == "released" and input and input.padBindings
            and input.padBindings[ev.button] == "a" then
          suppressAUntilRelease = false
        end
        return next(game, ev)
      end)
      mod.hooks:wrap("input.step", function(next, game, dt)
        lastGame = game
        local input = game and game.input
        -- Intercept the raw queued A edge before Game:step reaches the field
        -- movement code.  Waiting until after next() lets FireRed consume A
        -- as the normal door warp first, which is why the knock prompt can
        -- appear to stop responding even though the mod sees the same edge.
        -- Game3 promotes the physical edge with input:step() immediately
        -- AFTER this hook is entered (Game3:fixedUpdate lines 440-443).
        -- Therefore pressQueue is already drained here.  The old code watched
        -- pressQueue and consequently never saw A at the point where the door
        -- transition could be intercepted.  Keyboard and gamepad hooks now
        -- catch the edge before it reaches the overworld, while this step hook
        -- remains the cleanup/fallback path.
        local queuedA = false
        if input and type(input.pressQueue) == "table" then
          for _, btn in ipairs(input.pressQueue) do
            if btn == "a" then queuedA = true; break end
          end
        end
        if queuedA and not modalActive and not suppressAUntilRelease and not warpInProgress
            and opt("firered_common_courtesy", true) ~= false
            and game and game.phase == "field" then
          if knock(game) then
            for i = #input.pressQueue, 1, -1 do
              if input.pressQueue[i] == "a" then table.remove(input.pressQueue, i) end
            end
          end
        end

        local result = next(game, dt)
        -- At this point Input:step() has promoted the physical/touch A edge.
        -- This is the one hook path every FireRed input source shares.  The
        -- old implementation only intercepted key/gamepad callbacks, so the
        -- on-screen A button (and some controller paths) could reach the door
        -- warp without ever opening the knock prompt.
        local postInput = game and game.input
        if postInput and postInput.wasPressed and postInput:wasPressed("a")
            and not modalActive and not suppressAUntilRelease
            and opt("firered_common_courtesy", true) ~= false
            and game and game.phase == "field" then
          if knock(game) then
            if type(postInput.pressed) == "table" then postInput.pressed.a = nil end
          end
        end
        local Map = engine("src.core.game3.map")
        if Map and Map.current then lastMap = lastMap or Map.current end
        if opt("firered_common_courtesy", true) ~= false and game and game.phase == "field" then
          -- A is normally handled by the active Message/Choice state here.
          -- We only use this post-step pass for the UP edge that arms the
          -- map-entry fallback; the knock itself is intercepted above.
          local postInput = game.input
          local Player = engine("src.core.game3.player")
          local Collision = engine("src.core.game3.collision")
          if Player and Collision and Collision.isDoorWarp and postInput and postInput.wasPressed
              and postInput:wasPressed("up") then
            local info = Collision.isDoorWarp(game, Player.cellX, Player.cellY - 1)
            if info and houseMap(info.destMap) then
              local k = key(game, info)
              if not pending then pending = { key = k, authorized = armed[k] == true } end
            end
          end
          if postInput and postInput.wasPressed and not postInput:wasPressed("a") then
            suppressAUntilRelease = false
          end
        end
        return result
      end)
      mod.events:on("map.entered", function(payload)
        if not lastGame then return end
        local Map = engine("src.core.game3.map")
        local current = Map and Map.current or nil
        local wasOutdoor = lastMap ~= nil and not houseMap(lastMap)
        local enteredHouse = houseMap(current)
        local handled = watchEntry(lastGame)

        -- The map-entered event is the authoritative fallback. It catches a
        -- walk-through even when the movement hook did not expose the UP edge.
        -- An explicit YES authorizes only the exact destination house once.
        if wasOutdoor and enteredHouse and not handled then
          if authorizedDestMap and tostring(authorizedDestMap) == tostring(current) then
            authorizedDestMap = nil
          else
            authorizedDestMap = nil
            local Player = engine("src.core.game3.player")
            local Collision = engine("src.core.game3.collision")
            local exit = Player and Collision and Collision.isExitWarp
                and Collision.isExitWarp(lastGame, Player.cellX, Player.cellY)
            if exit then
              show("Please knock before entering!", function()
                local Warp = engine("src.core.game3.warp")
                local Runtime = engine("src.core.game3.runtime")
                local g = lastGame or (Runtime and Runtime._game)
                local m = Runtime and Runtime._mod
                if Warp and type(Warp.startDoorExit) == "function" then
                  pcall(Warp.startDoorExit, m, g, exit.destMap, exit.destX, exit.destY, Player.cellX, Player.cellY)
                end
              end)
            end
          end
        end
        lastMap = current
        -- Warp completed (map changed), clear the knock suppression.
        if warpInProgress and warpStartMap ~= nil and tostring(current) ~= tostring(warpStartMap) then
          warpInProgress = false
          warpStartMap = nil
        end
      end)
    end)
    installed = ok
  end

  install()
  return api
end
