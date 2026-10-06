-- Kanto Life FireRed / Gen 3 NPC routines.
--
-- Travel percentage is applied to eligible actors using a stable per-actor
-- bucket: at 10%, roughly one actor in ten is assigned a routine; 100% assigns
-- every eligible actor. Agenda DAY adds its own 10% doorway routine and FULL
-- assigns the doorway routine to every eligible *ambient* actor.
--
-- Kanto Life ambient actors are the only actors allowed to leave the map's
-- population through a doorway and be replaced by another ambient actor.
-- Native FireRed actors are never removed/replaced by this controller.
return function(ctx)
  local mod = ctx.mod
  local getWorld = ctx.getWorld
  local getFieldState = ctx.getFieldState
  local onRoutineExit = ctx.onRoutineExit
  local api = {}

  local function engine(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
  end

  local enabled = true
  local travelPct = 70
  local agendaMode = 0
  local lastMap = nil
  local elapsed = 0
  -- Key runtime state by localId rather than weak object identity. FireRed's
  -- object facade can hand a mod a fresh Lua wrapper around the same live
  -- EventObject, so weak object keys can otherwise reset the routine every frame.
  local states = {}
  local handles = {}
  local routineAssigned = {}

  -- Random travel methods: door, route, fly, teleport, surf.
  -- Fly/teleport/surf NPCs depart in place via exitAmbient instead of walking
  -- to a door. Surf requires water nearby.
  local function waterNearby(world, npc, radius)
    local map = world and world.map
    if not map then
      -- Try engine map access
      local Map = engine("src.core.game3.map")
      map = Map and Map.current and { } or nil
      if not map then return false end
    end
    local cx, cy = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    radius = radius or 4
    for dy = -radius, radius do
      for dx = -radius, radius do
        local ok, isWater = pcall(function()
          if type(map.isWaterCell) == "function" then return map:isWaterCell(cx+dx, cy+dy) end
          if type(map.waterAt) == "function" then return map:waterAt(cx+dx, cy+dy) end
          if type(map.isWater) == "function" then return map:isWater(cx+dx, cy+dy) end
          return false
        end)
        if ok and isWater then return true end
      end
    end
    return false
  end

  local function travelMethodsEnabled()
    if type(ctx.getOption) == "function" then
      -- FireRed uses firered_ prefix; also check unprefixed for consistency.
      local ok, v = pcall(ctx.getOption, "firered_npc_travel_methods")
      if ok and v ~= nil then return v ~= false end
      local ok2, v2 = pcall(ctx.getOption, "npc_travel_methods")
      if ok2 and v2 ~= nil then return v2 ~= false end
    end
    return true
  end

  -- Forward declaration: hash is defined further below but used by
  -- pickTravelKind above its definition point.
  local hash

  local function pickTravelKind(npc, world)
    if not travelMethodsEnabled() then
      return (hash(npc) < 50) and "route" or "door"
    end
    -- Context-aware: if water is nearby, the NPC chooses to surf most of
    -- the time (70%). Otherwise, use the standard distribution.
    if world and waterNearby(world, npc, 4) then
      local roll = math.random(100)
      if roll <= 70 then return "surf"
      elseif roll <= 80 then return "door"
      elseif roll <= 90 then return "route"
      elseif roll <= 95 then return "fly"
      else return "teleport" end
    end
    local roll = math.random(100)
    if roll <= 30 then return "door"
    elseif roll <= 60 then return "route"
    elseif roll <= 75 then return "fly"
    elseif roll <= 90 then return "teleport"
    else
      return (hash(npc) < 50) and "route" or "door"
    end
  end

  local function startDepartEffect(npc, method)
    local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    npc._kantoLifeFRDepartMethod = method
    npc._kantoLifeFRDepartUntil = now + 1.2
    local cue = method == "fly" and "^^" or method == "teleport" and "**" or method == "surf" and "~~" or "!"
    npc._kantoLifeCollisionBubbleText = cue
    npc._kantoLifeCollisionBubbleUntil = now + 1.2
  end

  local function actorKey(npc)
    return tonumber(npc and (npc.localId or (npc.def and npc.def.localId) or npc.id))
      or tostring(npc and npc.id or npc)
  end

  local DIRS = {
    { 1, 0, "right" }, { -1, 0, "left" },
    { 0, 1, "down" }, { 0, -1, "up" },
  }

  hash = function(npc)
    local id = npc and (npc.localId or npc.id or (npc.def and npc.def.localId)) or 0
    local s = tostring(id)
    local h = 0
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 10000 end
    return h % 100
  end

  local function worldState()
    return type(getFieldState) == "function" and getFieldState() or nil
  end

  local function actors()
    local Objects = engine("src.core.game3.objects")
    if not Objects then return {} end
    local out = {}
    for _, lid in ipairs(Objects._order or {}) do
      local npc = Objects._byId and Objects._byId[lid]
      if npc then out[#out + 1] = npc end
    end
    return out
  end

  local function mapId(world)
    local map = world and world.map
    return map and (map.gen3Id or map.id) or nil
  end

  local function isIndoor(world)
    local map = world and world.map
    if not map then return false end
    if type(map.isOutdoor) == "function" then
      local ok, out = pcall(map.isOutdoor, map)
      if ok then return not out end
    end
    return false
  end

  local function isAmbient(npc)
    return npc and npc.kantoLifeAmbient == true
  end

  local function eligible(npc)
    if not npc or npc.hidden or npc.isPlayer or npc.localId == 0xFF then return false end
    if npc.frozen or npc.story or npc.isStory or npc.trainer or npc.isTrainer then return false end
    local d = npc.def or {}
    if d.hidden or d.story or d.isStory or d.trainer or d.isTrainer then return false end
    if d.player or d.isPlayer then return false end
    -- Never treat field objects as routine actors. These are map props such as
    -- Poké Balls, Cut trees, rocks and pushable boulders, not NPCs.
    local gid = tonumber(npc.graphicsId or d.graphicsId or d.graphics)
    if gid == 92 or gid == 95 or gid == 96 or gid == 97 then return false end
    if d.item or npc.item then return false end
    return true
  end

  local function anchor(npc)
    if npc._kantoLifeFRAnchorX == nil or npc._kantoLifeFRAnchorY == nil then
      npc._kantoLifeFRAnchorX = tonumber(npc.cellX) or 0
      npc._kantoLifeFRAnchorY = tonumber(npc.cellY) or 0
    end
    return npc._kantoLifeFRAnchorX, npc._kantoLifeFRAnchorY
  end

  local function npcHandle(world, npc)
    local key = actorKey(npc)
    if handles[key] then return handles[key] end
    local id = mapId(world)
    local localId = npc and (npc.localId or (npc.def and npc.def.localId) or npc.id)
    if not id or localId == nil then return nil end
    local w = type(getWorld) == "function" and getWorld() or nil
    if not w then return nil end
    local ok, h = pcall(function() return w:npc(id, localId) end)
    if ok and h then
      handles[key] = h
      return h
    end
    return nil
  end

  local function slowStep(h, npc, dir)
    if not h or not npc then return false end
    local bx, by = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    local ok = false
    if type(h.stepNow) == "function" then
      npc.stepFrames = 21
      ok = pcall(h.stepNow, h, dir)
    elseif type(h.scriptMove) == "function" then
      ok = pcall(h.scriptMove, h, dir, 1)
    end
    if not ok then return false end
    if type(h.isMoving) == "function" then
      local okMoving, moving = pcall(h.isMoving, h)
      if okMoving and moving then return true end
    end
    local px, py = tonumber(npc.cellX) or bx, tonumber(npc.cellY) or by
    if px ~= bx or py ~= by then return true end
    if type(h.position) == "function" then
      local okPos, pos = pcall(h.position, h)
      if okPos and type(pos) == "table" then
        local x = tonumber(pos.x or pos.cellX or pos[1])
        local y = tonumber(pos.y or pos.cellY or pos[2])
        if x and y and (x ~= bx or y ~= by) then return true end
      end
    end
    return false
  end

  local function occupied(world, x, y, selfNpc)
    local Objects = engine("src.core.game3.objects")
    if Objects and type(Objects.blocks) == "function" then
      local lid = selfNpc and tonumber(selfNpc.localId) or nil
      local ok, blocked = pcall(Objects.blocks, x, y, lid)
      if ok and blocked then return true end
    end
    local Player = engine("src.core.game3.player")
    if Player and Player.cellX == x and Player.cellY == y then return true end
    return false
  end

  local BUBBLE_TEXT = { ":)", ":D", ":-)", ";)", "^_^", "!!", "?", "...", "<3", ":P", "^^", "o_o" }
  local function collisionBubble(a, b)
    if not a or not b then return end
    local text = BUBBLE_TEXT[math.random(1, #BUBBLE_TEXT)]
    local untilAt = (love and love.timer and love.timer.getTime and love.timer.getTime() or 0) + 1.35
    a._kantoLifeCollisionBubbleText, a._kantoLifeCollisionBubbleUntil = text, untilAt
    b._kantoLifeCollisionBubbleText, b._kantoLifeCollisionBubbleUntil = text, untilAt
  end
  local function ambientAt(x, y, except)
    for _, other in ipairs(actors()) do
      if other ~= except and isAmbient(other) and not other.hidden
         and tonumber(other.cellX) == tonumber(x) and tonumber(other.cellY) == tonumber(y) then return other end
    end
    return nil
  end

  local function occupiedByAmbient(world, x, y, selfNpc)
    if occupied(world, x, y, selfNpc) then return true end
    -- Do not trust native EventObject collision alone: ambient objects are
    -- created dynamically and the native movement layer can lag one tick
    -- behind their Lua positions. Explicitly reserve the destination cell.
    for _, other in ipairs(actors()) do
      if other ~= selfNpc and isAmbient(other) and not other.hidden then
        if tonumber(other.cellX) == tonumber(x) and tonumber(other.cellY) == tonumber(y) then
          return true
        end
      end
    end
    return false
  end

  local function mapDef(id)
    local okRuntime, Runtime = pcall(require, "src.core.game3.runtime")
    local g = okRuntime and Runtime and Runtime._game or nil
    local maps = g and g.data and g.data.maps
    return maps and maps[id] or nil
  end

  local function destinationMapId(warp)
    if not warp then return nil end
    if warp.destMap then return warp.destMap end
    if warp.mapGroup ~= nil and warp.mapNum ~= nil then
      local okCatalog, Catalog = pcall(require, "src.import.gba.map_catalog")
      if okCatalog and Catalog and type(Catalog.mapIdFor) == "function" then
        local ok, id = pcall(Catalog.mapIdFor, warp.mapGroup, warp.mapNum)
        if ok then return id end
      end
    end
    return nil
  end

  local function mapIsOutdoor(id)
    local def = mapDef(id)
    if not def then return nil end
    local okMoves, FieldMoves = pcall(require, "src.core.game3.field_moves")
    if okMoves and FieldMoves and type(FieldMoves.isOutdoors) == "function" then
      local ok, out = pcall(FieldMoves.isOutdoors, def.mapType)
      if ok then return out and true or false end
    end
    return nil
  end

  local function isRouteId(id)
    local s=tostring(id or ""):upper()
    return s:find("ROUTE",1,true) ~= nil
  end

  local function doorwayList(world)
    local map = world and world.map
    if not map then return {} end
    local currentOutdoor = not isIndoor(world)
    local currentId = map.id or map.gen3Id
    local Runtime = engine("src.core.game3.runtime")
    local Collision = engine("src.core.game3.collision")
    local game = Runtime and Runtime._game or nil
    local out, fallback = {}, {}

    -- FireRed door/warp destinations are authoritative for building entrances.
    local warpList = map.warps
    if type(warpList) ~= "table" or #warpList == 0 then warpList = map.def and map.def.warps or {} end
    for _, w in ipairs(warpList) do
      local x, y = tonumber(w.x), tonumber(w.y)
      if x and y then
        local info = nil
        if Collision and game then
          if currentOutdoor and type(Collision.isDoorWarp) == "function" then
            local ok, v = pcall(Collision.isDoorWarp, game, x, y)
            if ok then info = v end
          elseif not currentOutdoor and type(Collision.isExitWarp) == "function" then
            local ok, v = pcall(Collision.isExitWarp, game, x, y)
            if ok then info = v end
          end
        end
        local destMap = info and info.destMap or destinationMapId(w)
        local destX = info and info.destX or tonumber(w.destX)
        local destY = info and info.destY or tonumber(w.destY)
        local destOutdoor = mapIsOutdoor(destMap)
        local crossesBoundary = destMap ~= nil and tostring(destMap) ~= tostring(currentId)
        -- Indoors, every cross-map warp is an exit candidate: doors, stairs,
        -- elevators and other interior transitions are all represented as
        -- warps. Outdoors, retain the door/route boundary test.
        local isDoor = info ~= nil or (not currentOutdoor and crossesBoundary)
          or (destOutdoor ~= nil and destOutdoor ~= currentOutdoor)
        local kind = (destOutdoor == true and isRouteId(destMap)) and "route" or "door"
        local entry = { x=x, y=y, warp=w, kind=kind, door=isDoor,
          destMap=destMap, destX=destX, destY=destY, route=(kind=="route") }
        if isDoor and crossesBoundary then out[#out + 1] = entry end
        fallback[#fallback + 1] = entry
      end
    end

    if #out == 0 and Collision and type(Collision.warpAt) == "function" then
      local mw = tonumber(map.widthCells or map.width or 0) or 0
      local mh = tonumber(map.heightCells or map.height or 0) or 0
      for yy = 0, mh - 1 do
        for xx = 0, mw - 1 do
          local okW, wv = pcall(Collision.warpAt, xx, yy)
          if okW and wv then
            local def = wv.def or wv
            local destMap = destinationMapId(def)
            local crosses = destMap ~= nil and tostring(destMap) ~= tostring(currentId)
            if not currentOutdoor or crosses then
              out[#out + 1] = {x=xx, y=yy, warp=def, kind="door", door=true,
                destMap=destMap, destX=tonumber(def.destX), destY=tonumber(def.destY), route=false}
            end
          end
        end
      end
    end

    -- Map connections are the actual route entrances/exits.  They are used on
    -- towns as well as routes, so routine actors can leave a town by a route
    -- entrance and later return through a route entrance just like doors.
    if currentOutdoor and map.def and type(map.def.connections) == "table" and game and Collision
        and type(Collision.connectionLanding) == "function" then
      local md = map.def
      local L = md.midLayout or {}
      local w = tonumber(L.width or md.width or map.widthCells or map.width or 0) or 0
      local h = tonumber(L.height or md.height or map.heightCells or map.height or 0) or 0
      local dirs = {
        north={delta="up", axis="x"}, south={delta="down", axis="x"},
        east={delta="right", axis="y"}, west={delta="left", axis="y"},
      }
      for dir, meta in pairs(dirs) do
        local conn = md.connections[dir]
        local destMap = type(conn) == "table" and (conn.map or conn.mapId) or conn
        local data = game.data and game.data.maps
        local destDef = data and destMap and data[destMap]
        if destDef and tostring(destMap) ~= tostring(currentId) then
          local span = (meta.axis == "x") and w or h
          local center = math.floor(math.max(0, span - 1) / 2)
          local best
          for pass=0,1 do
            for off=0,math.max(0,span-1) do
              local i
              if pass == 0 then
                i = math.floor(center + (off % 2 == 0 and off/2 or -(off+1)/2))
              else i = off end
              if i >= 0 and i < span then
                local sx,sy
                if dir == "north" then sx,sy=i,0 elseif dir == "south" then sx,sy=i,h-1
                elseif dir == "west" then sx,sy=0,i else sx,sy=w-1,i end
                local okWalk, walk = pcall(map.isWalkableCell, map, sx, sy)
                if okWalk and walk then
                  local dx,dy = Collision.connectionLanding(destDef, conn, meta.delta, sx, sy)
                  local dw = destDef.midLayout and destDef.midLayout.width or destDef.width
                  local dh = destDef.midLayout and destDef.midLayout.height or destDef.height
                  if dx ~= nil and dy ~= nil and dx >= 0 and dy >= 0 and tonumber(dw or 0) > dx and tonumber(dh or 0) > dy then
                    best = {x=sx,y=sy,kind="route",route=true,connection=true,
                      destMap=destMap,destX=dx,destY=dy,dir=meta.delta,conn=conn}
                    break
                  end
                end
              end
            end
            if best then break end
          end
          if best then out[#out + 1] = best end
        end
      end
    end

    return #out > 0 and out or fallback
  end

  local function nearestDoor(world, npc, avoidX, avoidY)
    local doors = doorwayList(world)
    if #doors == 0 then return nil end
    local ax, ay = anchor(npc)
    local desired = npc._kantoLifeFRTravelKind or ((hash(npc) < 50) and "route" or "door")
    local open, blocked, any = {}, {}, {}
    for _, d in ipairs(doors) do
      if (avoidX == nil or d.x ~= avoidX or d.y ~= avoidY)
         and (npc._kantoLifeFRLastDoorX == nil or d.x ~= npc._kantoLifeFRLastDoorX or d.y ~= npc._kantoLifeFRLastDoorY) then
        local row = { x=d.x, y=d.y, warp=d.warp, kind=d.kind, route=d.route, connection=d.connection,
          destMap=d.destMap, destX=d.destX, destY=d.destY, blocked=occupied(world,d.x,d.y,npc) }
        row.dist = math.abs(d.x-ax) + math.abs(d.y-ay)
        any[#any+1] = row
        if d.kind == desired then
          if row.blocked then blocked[#blocked+1] = row else open[#open+1] = row end
        end
      end
    end
    local pool = #open > 0 and open or (#blocked > 0 and blocked or any)
    if #pool == 0 then return nil end
    table.sort(pool, function(a,b) return a.dist < b.dist end)
    local n = math.min(3, #pool)
    return pool[math.random(1,n)]
  end

  local function approachWarp(world, npc, entry)
    if not entry then return nil end
    -- The routine exit is the warp/connection cell itself. The controller
    -- removes the actor only after it reaches that cell, which makes the
    -- departure visibly happen at the actual doorway/route boundary.
    if entry.connection or entry.route then
      return tonumber(entry.x), tonumber(entry.y)
    end
    local map = world and world.map
    if not map then return nil end
    local x, y = tonumber(entry.x), tonumber(entry.y)
    if not x or not y then return nil end
    local walk, occupiedHere = true, occupied(world, x, y, npc)
    if type(map.isWalkableCell) == "function" then
      local ok, v = pcall(map.isWalkableCell, map, x, y); walk = ok and v == true
    end
    -- Most FRLG building warp cells are themselves walkable. Prefer the real
    -- doorway so the actor reaches the threshold; only fall back to an
    -- adjacent cell for maps where the warp cell is intentionally blocked.
    if walk and not occupiedHere then return x, y end
    local candidates = {}
    for _, d in ipairs(DIRS) do
      local nx, ny = x + d[1], y + d[2]
      local w = true
      if type(map.isWalkableCell) == "function" then
        local ok, v = pcall(map.isWalkableCell, map, nx, ny); w = ok and v == true
      end
      if w and not occupied(world, nx, ny, npc) then
        candidates[#candidates+1] = { x=nx, y=ny, dist=math.abs((npc.cellX or 0)-nx)+math.abs((npc.cellY or 0)-ny) }
      end
    end
    table.sort(candidates, function(a,b) return a.dist < b.dist end)
    if #candidates == 0 then return nil end
    return candidates[1].x, candidates[1].y
  end

  -- Downhill ledge-hop support. The engine only hops the player, so NPCs
  -- emulate it via Objects.scriptJump (2 cells), mirroring
  -- Handle:stepNow's frozen/scriptBusy restore so routine state is
  -- unaffected. Collision.ledgeLanding (game3) validates the facing against
  -- the ROM ledge table and returns the 2-away landing cell.
  local function ledgeHopLandingXY(world, x, y, dir)
    local Runtime = engine("src.core.game3.runtime")
    local Collision = engine("src.core.game3.collision")
    local game = Runtime and Runtime._game or nil
    if not (Collision and game and type(Collision.ledgeLanding) == "function") then return nil end
    local ok, lx, ly = pcall(Collision.ledgeLanding, game, x, y, dir)
    if not ok or lx == nil or ly == nil then return nil end
    if occupiedByAmbient(world, lx, ly, nil) then return nil end
    local Player = engine("src.core.game3.player")
    if Player and Player.cellX == lx and Player.cellY == ly then return nil end
    return lx, ly
  end

  local function ledgeHopLanding(world, npc, dir)
    local x, y = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    return ledgeHopLandingXY(world, x, y, dir)
  end

  local function pathFirst(world, npc, tx, ty)
    local map = world and world.map
    if not map then return nil end
    local sx, sy = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    if sx == tx and sy == ty then return nil end
    if type(map.isWalkableCell) ~= "function" then
      if math.abs(tx - sx) >= math.abs(ty - sy) then
        return tx > sx and "right" or "left"
      end
      return ty > sy and "down" or "up"
    end
    local width = tonumber(map.widthCells or map.width or (map.def and map.def.midLayout and map.def.midLayout.width) or (map.def and map.def.width)) or 0
    local height = tonumber(map.heightCells or map.height or (map.def and map.def.midLayout and map.def.midLayout.height) or (map.def and map.def.height)) or 0
    if width <= 0 or height <= 0 then return nil end
    local qx, qy, head = { sx }, { sy }, 1
    local seen = { [sx .. ":" .. sy] = true }
    local parent = {}
    local goal = tx .. ":" .. ty
    while head <= #qx do
      local x, y = qx[head], qy[head]; head = head + 1
      if x == tx and y == ty then break end
      for _, d in ipairs(DIRS) do
        local nx, ny = x + d[1], y + d[2]
        local key = nx .. ":" .. ny
        if nx >= 0 and ny >= 0 and nx < width and ny < height and not seen[key] then
          local ok, pass = pcall(map.isWalkableCell, map, nx, ny)
          if ok and pass then
            seen[key] = true
            parent[key] = { prev = x .. ":" .. y, dir = d[3] }
            qx[#qx + 1], qy[#qy + 1] = nx, ny
          else
            -- Ledge transit: the 1-ahead cell is an impassable hop metatile;
            -- the traversable node is the 2-away landing when facing matches.
            local lx, ly = ledgeHopLandingXY(world, x, y, d[3])
            if lx and lx >= 0 and ly >= 0 and lx < width and ly < height then
              local lk = lx .. ":" .. ly
              if not seen[lk] then
                seen[lk] = true
                parent[lk] = { prev = x .. ":" .. y, dir = d[3] }
                qx[#qx + 1], qy[#qy + 1] = lx, ly
              end
            end
          end
        end
      end
      if #qx > 6000 then break end
    end
    if not seen[goal] then return nil end
    local key, first = goal, nil
    while key ~= sx .. ":" .. sy do
      local p = parent[key]
      if not p then return nil end
      first, key = p.dir, p.prev
    end
    return first
  end

  local WANDER_RADIUS = 6
  local WANDER_TARGET_RETRIES = 12

  local function pickWanderTarget(world, npc)
    local map = world and world.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil end
    local ax, ay = anchor(npc)
    local w = tonumber(map.widthCells or map.width) or 0
    local h = tonumber(map.heightCells or map.height) or 0
    for _ = 1, WANDER_TARGET_RETRIES do
      local tx = ax + math.random(-WANDER_RADIUS, WANDER_RADIUS)
      local ty = ay + math.random(-WANDER_RADIUS, WANDER_RADIUS)
      if tx >= 0 and ty >= 0 and tx < w and ty < h and map:isWalkableCell(tx, ty) then
        return tx, ty
      end
    end
    return ax, ay
  end

  local function localWander(world, npc, st)
    if npc.moving or npc.frozen or npc.scriptBusy then return false end
    if (st.wanderCooldown or 0) > 0 then return false end
    local h = npcHandle(world, npc)
    if not h then return false end
    local start = math.random(1, #DIRS)
    for i = 0, #DIRS - 1 do
      local d = DIRS[((start + i - 1) % #DIRS) + 1]
      local ok, can = pcall(h.canStep, h, d[3])
      if ok and can then
        slowStep(h, npc, d[3])
        st.wanderCooldown = 0.35
        return true
      end
    end
    return false
  end

  local function setNativeWander(npc)
    if not npc then return end
    npc.movement = "WALK"
    npc.range = "ANY_DIR"
    npc.radius = { x = 10, y = 10 }
    if npc.def then
      npc.def.movement = "WALK"
      npc.def.range = "ANY_DIR"
      npc.def.radius = { x = 10, y = 10 }
    end
  end

  local function arrivalTarget(world, npc)
    local map = world and world.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil, nil end
    local x, y = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    local candidates = {}
    for _, d in ipairs(DIRS) do
      local tx, ty = x + d[1], y + d[2]
      local ok, walk = pcall(map.isWalkableCell, map, tx, ty)
      if ok and walk and not occupied(world, tx, ty, npc) then
        candidates[#candidates + 1] = { tx, ty }
      end
    end
    if #candidates == 0 then return nil, nil end
    local c = candidates[math.random(1, #candidates)]
    return c[1], c[2]
  end

  local function stateFor(world, npc, forcedRoutine)
    local key = actorKey(npc)
    local st = states[key]
    if st then return st end
    if not eligible(npc) then return nil end

    local indoor = isIndoor(world)
    local ambient = isAmbient(npc)
    st = {
      routine = false,
      returning = false,
      targetX = nil,
      targetY = nil,
      exitX = nil,
      exitY = nil,
      wait = 0,
      wanderTime = 0,
      wanderCooldown = 0,
      arrival = false,
      arrivalX = nil,
      arrivalY = nil,
      blockedTime = 0,
      blockedCount = 0,
    }
    states[key] = st

    -- Default indoor FireRed NPCs are intentionally excluded from the
    -- doorway population cycle. They still wander normally.
    if not ambient then
      -- Vanilla/default FireRed EventObjects are never controlled by Kanto
      -- Life routines. Their original movement, items and map props remain
      -- entirely owned by the engine.
      return st
    end

    -- forcedRoutine is true (explicit) or nil (roll it). Never default to
    -- false here: ambient NPCs spawned after the per-map rebuild() would
    -- otherwise never receive a routine and would wander forever.
    local travel = ambient and forcedRoutine
    if ambient and travel == nil then
      if npc._kantoLifeFRForceRoutine then
        travel = true
        npc._kantoLifeFRForceRoutine = nil
      else
        -- Late spawns get the same assignment rebuild() applies: everyone
        -- travels indoors, travelPct% outdoors.
        travel = isIndoor(world) or (travelPct > 0 and hash(npc) < travelPct)
      end
    end
    local agenda = false
    if ambient and agendaMode == 1 then
      agenda = hash(npc) < 10
    elseif ambient and agendaMode == 2 then
      agenda = true
    end
    st.routine = travel or agenda
    st.ambientRoutine = ambient and st.routine
    if st.routine then
      npc._kantoLifeFRTravelKind = pickTravelKind(npc, world)
      st.travelKind = npc._kantoLifeFRTravelKind
      npc.movement = "STAY"
      npc.range = "DOWN"
      if npc.def then npc.def.movement = "STAY"; npc.def.range = "DOWN" end
      npc._kantoLifeFRRoutine = true
      npc._kantoLifeFRRoutinePhase = "wander"
      if npc._kantoLifeFRArrivalDoorX ~= nil then
        local ax, ay = arrivalTarget(world, npc)
        st.arrival = ax ~= nil
        st.arrivalX = ax
        st.arrivalY = ay
        npc._kantoLifeFRArrivalDoorX = nil
        npc._kantoLifeFRArrivalDoorY = nil
      end
      if agenda then npc._kantoLifeFRAgenda = true end
    else
      setNativeWander(npc)
    end
    return st
  end

  local function rebuild(world)
    states = {}
    handles = {}
    lastMap = mapId(world)
    elapsed = 0
    if not world then return end
    routineAssigned = {}
    local list = actors()
    local candidates = {}
    for _, npc in ipairs(list) do
      if eligible(npc) and isAmbient(npc) then
        candidates[#candidates + 1] = npc
      end
    end
    table.sort(candidates, function(a, b) return hash(a) < hash(b) end)
    local desired = isIndoor(world) and #candidates or math.ceil(#candidates * travelPct / 100)
    if not isIndoor(world) then
      if travelPct <= 0 then desired = 0 end
      if travelPct >= 100 then desired = #candidates end
    end
    for i = 1, desired do routineAssigned[actorKey(candidates[i])] = true end
    for _, npc in ipairs(list) do
      -- Explicit false: NPCs rebuild() deliberately excluded must not get a
      -- second roll in stateFor; only genuinely late spawns (nil state) roll.
      stateFor(world, npc, routineAssigned[actorKey(npc)] and true or false)
    end
  end

  local function exitAmbient(world, npc, st)
    if not st.ambientRoutine or not isAmbient(npc) then return false end
    local x, y = tonumber(npc.cellX), tonumber(npc.cellY)
    local callback = onRoutineExit
    if type(callback) == "function" then
      st.exiting = true
      return callback(npc, st.exitX or x, st.exitY or y, st.blockedDoorX, st.blockedDoorY) and true or false
    end
    return false
  end

  local function updateActor(world, npc, st, dt)
    if npc.hidden or not npc.visible then return end
    if npc._kantoLifeFRTalkPaused then
      local untilAt = tonumber(npc._kantoLifeFRTalkHoldUntil) or 0
      if untilAt > os.time() then return end
      npc._kantoLifeFRTalkPaused = nil
      npc._kantoLifeFRTalkHoldUntil = nil
    end
    st.wanderCooldown = math.max(0, (st.wanderCooldown or 0) - dt)

    if not st.routine then
      return
    end
    if st.exiting then return end

    local h = npcHandle(world, npc)
    if not h then return end
    if npc.moving or npc.scriptBusy then return end

    -- A replacement spawned on a doorway first walks back into the building
    --/map instead of materializing and standing on the threshold.
    if st.arrival and st.arrivalX ~= nil then
      if npc.cellX == st.arrivalX and npc.cellY == st.arrivalY then
        st.arrival = false
        st.wanderTime = 0
      else
        local dir = pathFirst(world, npc, st.arrivalX, st.arrivalY)
        if dir and not occupiedByAmbient(world, (npc.cellX or 0) + ({up={0,-1},down={0,1},left={-1,0},right={1,0}})[dir][1], (npc.cellY or 0) + ({up={0,-1},down={0,1},left={-1,0},right={1,0}})[dir][2], npc) then
          local ok, can = pcall(h.canStep, h, dir)
          if ok and can then slowStep(h, npc, dir) end
        else
          st.arrival = false
        end
      end
      return
    end

    -- Wander for a while before committing to the routine doorway. This makes
    -- routine NPCs visibly roam rather than walking straight to the door.
    if not st.returning and (st.wanderTime or 0) < 7.0 then
      -- Routine actors get a substantially wider local roaming area before
      -- they commit to the doorway. Targets stay within six cells of their
      -- spawn anchor so they roam naturally without crossing the whole map.
      if st.wanderTargetX == nil or (npc.cellX == st.wanderTargetX and npc.cellY == st.wanderTargetY) then
        st.wanderTargetX, st.wanderTargetY = pickWanderTarget(world, npc)
      end
      local wx, wy = st.wanderTargetX, st.wanderTargetY
      if wx ~= nil and wy ~= nil and (npc.cellX ~= wx or npc.cellY ~= wy) then
        local dir = pathFirst(world, npc, wx, wy)
        local moved = false
        if dir then
          local ok, can = pcall(h.canStep, h, dir)
          if ok and can then
            slowStep(h, npc, dir)
            moved = true
          end
        end
        if not moved then st.wanderTargetX, st.wanderTargetY = nil, nil end
      end
      st.wanderTime = (st.wanderTime or 0) + dt
      return
    end

    if st.targetX == nil then
      -- Fly/teleport/surf NPCs depart in place with a visual effect instead
      -- of walking to a doorway. Uses the paired exit primitive.
      -- Fall back to picking the kind now if it wasn't set at assignment
      -- (e.g., state reused across NPC objects).
      local kind = npc._kantoLifeFRTravelKind or st.travelKind
      if not kind then
        kind = pickTravelKind(npc, world)
        npc._kantoLifeFRTravelKind = kind
        st.travelKind = kind
      end
      if kind == "fly" or kind == "teleport" or kind == "surf" then
        if not st.specialDepartStarted then
          st.specialDepartStarted = true
          st.specialDepartWait = 1.2
          startDepartEffect(npc, kind)
          return
        end
        st.specialDepartWait = (st.specialDepartWait or 0) - dt
        if st.specialDepartWait <= 0 then
          npc._kantoLifeFRRoutinePhase = "exit_special"
          if exitAmbient(world, npc, st) then return end
          -- Fallback: exit failed, resume wandering.
          st.specialDepartStarted = nil
          st.wanderTime = 0
          npc._kantoLifeFRDepartMethod = nil
        end
        return
      end
      local target
      -- Towns and routes both expose the same mixed destination pool. A stable
      -- per-actor travel kind is applied by nearestDoor, so some actors use
      -- route connections while others use buildings, and they can switch on
      -- later trips.
      target = nearestDoor(world, npc)
      if target then
        local ax, ay = approachWarp(world, npc, target)
        if ax ~= nil then
          st.targetX, st.targetY = ax, ay
          st.exitX, st.exitY = target.x, target.y
          npc._kantoLifeFRLastDoorX, npc._kantoLifeFRLastDoorY = target.x, target.y
          npc._kantoLifeFRRoutineTargetX, npc._kantoLifeFRRoutineTargetY = ax, ay
          npc._kantoLifeFRRoutinePhase = "to_door"
        end
      end
    end

    if st.targetX == nil then
      -- No reachable doorway right now (transient collision/grid state).
      -- Keep wandering and retry instead of permanently retiring the routine.
      st.doorRetryAt = (st.doorRetryAt or 0) + 1
      npc._kantoLifeFRRoutinePhase = "door_retry"
      st.wanderTime = 0
      -- Surf/fly last resort: after sustained failure outdoors, leave via the
      -- paired exit primitive (despawn here, replacement pops at another
      -- exit) so the population keeps cycling. Never indoors.
      if st.doorRetryAt >= 4 and not isIndoor(world) then
        st.doorRetryAt = 0
        npc._kantoLifeFRRoutinePhase = "exit_surf_fly"
        exitAmbient(world, npc, st)
      end
      return
    end
    st.doorRetryAt = 0

    local x, y = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    local atTarget = (x == st.targetX and y == st.targetY)
    local nextToTarget = math.abs(x - st.targetX) + math.abs(y - st.targetY) <= 1
    if atTarget or (nextToTarget and st.ambientRoutine and not st.returning) then
      if st.ambientRoutine and not st.returning then
        local blockedHere = occupiedByAmbient(world, x, y, npc)
        if blockedHere then
          -- Do not wedge two NPCs in the same threshold. Retreat into the
          -- building/map, then hand the population off to a different door.
          st.returning = true
          st.blockedDoorX, st.blockedDoorY = x, y
          st.targetX, st.targetY = anchor(npc)
          npc._kantoLifeFRRoutinePhase = "retreat_blocked_door"
          return
        end
        npc._kantoLifeFRRoutinePhase = "exit"
        exitAmbient(world, npc, st)
        return
      end
      if st.returning and st.blockedDoorX ~= nil then
        if x == st.targetX and y == st.targetY then
          npc._kantoLifeFRRoutinePhase = "exit_after_block"
          exitAmbient(world, npc, st)
          return
        end
      end

      st.wait = (st.wait or 0) + dt
      if st.wait >= 0.6 then
        st.wait = 0
        st.returning = not st.returning
        st.wanderTime = 0
        if st.returning then
          st.targetX, st.targetY = anchor(npc)
        else
          local target = nearestDoor(world, npc)
          if target then st.targetX, st.targetY = target.x, target.y end
        end
      end
      return
    end

    local dir = pathFirst(world, npc, st.targetX, st.targetY)
    if not dir then
      st.blockedTime = (st.blockedTime or 0) + dt
      if st.blockedTime >= 0.45 then
        st.blockedTime = 0
        st.blockedCount = (st.blockedCount or 0) + 1
        st.targetX, st.targetY = nil, nil
        st.exitX, st.exitY = nil, nil
        npc._kantoLifeFRRoutineTargetX, npc._kantoLifeFRRoutineTargetY = nil, nil
        npc._kantoLifeFRRoutinePhase = "reroute"
        st.wanderTime = 0
        if st.blockedCount >= 3 then
          st.blockedCount = 0
          st.wanderTargetX, st.wanderTargetY = pickWanderTarget(world, npc)
        end
      end
      return
    end
    local delta = ({up={0,-1},down={0,1},left={-1,0},right={1,0}})[dir]
    local nx = (npc.cellX or 0) + (delta and delta[1] or 0)
    local ny = (npc.cellY or 0) + (delta and delta[2] or 0)
    local other = ambientAt(nx, ny, npc)
    if other then
      collisionBubble(npc, other)
      st.blockedTime = (st.blockedTime or 0) + dt
      return
    end
    local free = not occupiedByAmbient(world, nx, ny, npc)
    -- Downhill ledge hop: bypass canStep and jump the 2 cells directly via
    -- Objects.scriptJump, mirroring Handle:stepNow's frozen/scriptBusy
    -- restore so routine state is unaffected.
    local hopLx, hopLy = ledgeHopLanding(world, npc, dir)
    if hopLx then
      local Objects = engine("src.core.game3.objects")
      if Objects and type(Objects.scriptJump) == "function" then
        local wasFrozen = npc.frozen
        npc.stepFrames = 21
        local okJump = pcall(Objects.scriptJump, npc, dir, 2)
        npc.frozen = wasFrozen
        npc.scriptBusy = false
        if okJump then
          st.blockedTime = 0
          st.blockedCount = 0
        else
          st.blockedTime = (st.blockedTime or 0) + dt
        end
        return
      end
    end
    local ok, can = pcall(h.canStep, h, dir)
    if free and ok and can and slowStep(h, npc, dir) then
      st.blockedTime = 0
      st.blockedCount = 0
    else
      st.blockedTime = (st.blockedTime or 0) + dt
      if st.blockedTime >= 0.45 then
        st.blockedTime = 0
        st.targetX, st.targetY = nil, nil
        st.exitX, st.exitY = nil, nil
        npc._kantoLifeFRRoutineTargetX, npc._kantoLifeFRRoutineTargetY = nil, nil
        npc._kantoLifeFRRoutinePhase = "reroute"
        st.wanderTime = 0
      end
    end
  end

  function api:setRoutineExitHandler(fn)
    onRoutineExit = type(fn) == "function" and fn or nil
  end

  function api:setEnabled(v)
    enabled = v ~= false
    if not enabled then
      for _, npc in ipairs(actors()) do
        if isAmbient(npc) then
          npc._kantoLifeFRRoutine = nil
          npc._kantoLifeFRAgenda = nil
          npc._kantoLifeFRRoutinePhase = nil
          setNativeWander(npc)
        end
      end
      states = {}
      handles = {}
      return
    end
    local world = worldState()
    if world then rebuild(world) end
  end

  function api:setTravelPercent(v)
    local n = math.floor((tonumber(v) or 10) / 10 + 0.5) * 10
    if n < 0 then n = 0 elseif n > 100 then n = 100 end
    travelPct = n
    local world = worldState()
    if world then rebuild(world) end
  end

  function api:setAgenda(v)
    local n = math.floor(tonumber(v) or 0)
    if n < 0 then n = 0 elseif n > 2 then n = 2 end
    agendaMode = n
    local world = worldState()
    if world then rebuild(world) end
  end

  function api:update(world, dt)
    if not enabled or not world then return end
    local id = mapId(world)
    if id ~= lastMap then rebuild(world) end
    local delta = tonumber(dt) or 0.016
    elapsed = elapsed + delta
    if elapsed < 0.12 then return end
    local tick = elapsed
    elapsed = 0
    for _, npc in ipairs(actors()) do
      -- pcall: wild-spawn mods (Untamed Advance, Wild Followers) may add NPCs
      -- with unexpected structures. Skip them instead of breaking routines.
      local okKey, key = pcall(actorKey, npc)
      if not okKey or key == nil then goto continue end
      local okElig, isElig = pcall(eligible, npc)
      if npc._kantoLifeFRForceRoutine and okElig and isElig then
        local okAmb, isAmb = pcall(isAmbient, npc)
        if okAmb and isAmb then
          -- A doorway replacement is part of the same routine population. Force
          -- its state immediately instead of waiting for the next percentage
          -- assignment pass, which would otherwise treat it as a fresh spawn.
          states[key] = nil
          npc._kantoLifeFRForceRoutine = nil
          stateFor(world, npc, true)
        end
      end
      local st = states[key] or stateFor(world, npc)
      local okElig2, isElig2 = pcall(eligible, npc)
      if st and okElig2 and isElig2 then
        -- FireRed's native Field.interact ignores a moving EventObject. Pause
        -- only an ambient actor that is actually in the player's facing cell;
        -- that makes A reliable for dialogue, item, trade, and battle events
        -- without stopping NPC traffic elsewhere on the map.
        local p = world.player
        local facing = p and p.facing
        local fx, fy = p and p.cellX, p and p.cellY
        if facing == "up" then fy = fy and fy - 1
        elseif facing == "down" then fy = fy and fy + 1
        elseif facing == "left" then fx = fx and fx - 1
        elseif facing == "right" then fx = fx and fx + 1 end
        if npc.kantoLifeAmbient and fx ~= nil and fy ~= nil and npc.cellX == fx and npc.cellY == fy then
          npc.moving = false
        else
          updateActor(world, npc, st, tick)
        end
      end
      ::continue::
    end
  end

  return api
end
