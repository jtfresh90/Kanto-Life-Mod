-- Johto Life custom routines controller 0.1.54
-- Controls only Johto Life ambient actors. It uses Gen1Recomp's public NPC
-- handle API and does not modify Battle Art, Porygonal, HGSS_SPRITES, or Terrarium.
return function(ctx)
  local mod = ctx.mod
  local getGame = ctx.game or function() return nil end
  local isIndoor = ctx.isIndoor or function() return false end
  local isTown = ctx.isTown or function() return false end
  local isRoute = ctx.isRoute or function() return false end
  local resolveDestMap = ctx.resolveDestMap
  local onRoutineExit = ctx.onRoutineExit

  local api = {}
  local enabled = true
  local travelPct = 30
  local lastMap = nil
  local dirty = true
  local states = {}
  local stateKeys = {}
  local handles = {}
  local handlesMap = nil
  local destinations = {}

  local DIRS = {
    {1,0,"right"}, {-1,0,"left"}, {0,1,"down"}, {0,-1,"up"},
  }

  local BUBBLE_TEXT = { ":)", ":D", ":-)", ";)", "^_^", "!!", "?", "...", "<3", ":P", "^^", "o_o" }
  local function setCollisionBubble(a, b)
    if not a or not b then return end
    local text = BUBBLE_TEXT[math.random(1, #BUBBLE_TEXT)]
    local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    a._kantoLifeCollisionBubbleText, a._kantoLifeCollisionBubbleUntil = text, now + 1.35
    b._kantoLifeCollisionBubbleText, b._kantoLifeCollisionBubbleUntil = text, now + 1.35
  end
  local function nearbyCollisionBubbles(world)
    local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    local list = {}
    for _, n in ipairs(world.npcs or {}) do
      if (n.kantoLifeAmbient or n.johtoLifeAmbient or (n.def and (n.def.kantoLifeAmbient or n.def.johtoLifeAmbient)))
         and not n.hidden and not n.frozen and not n.nightlifeSleeping then
        list[#list+1] = n
      end
    end
    for i=1,#list do
      local a=list[i]
      for j=i+1,#list do
        local b=list[j]
        local d=math.abs((a.cellX or 0)-(b.cellX or 0))+math.abs((a.cellY or 0)-(b.cellY or 0))
        if d <= 1 then
          local au=tonumber(a._kantoLifeCollisionBubbleUntil) or 0
          local bu=tonumber(b._kantoLifeCollisionBubbleUntil) or 0
          if au <= now and bu <= now then setCollisionBubble(a,b) end
        end
      end
    end
  end

  local function actorAt(world, x, y, except)
    for _, n in ipairs(world.npcs or {}) do
      if n ~= except and n.passable ~= true and n.cellX == x and n.cellY == y
         and (n.kantoLifeAmbient or (n.def and n.def.kantoLifeAmbient)) then return n end
    end
    return nil
  end

  local function optionPct()
    -- setTravelPercent is the live source of truth.  The main controller calls
    -- it whenever the option changes, so a runtime change takes effect on the
    -- very next update instead of being overwritten by a cached schema default.
    return math.max(0, math.min(100, math.floor((tonumber(travelPct) or 30) / 10 + 0.5) * 10))
  end

  local function actorKey(npc)
    local d = npc and npc.def or {}
    return tostring(npc and (npc.id or d.name or (tostring(npc.cellX or 0)..":"..tostring(npc.cellY or 0))) or "")
  end

  local function hash(npc)
    local s = actorKey(npc)
    if s == "" then s = tostring(npc and npc.def and npc.def.name or "") end
    if s == "" then s = tostring(npc and npc.cellX or 0) .. ":" .. tostring(npc and npc.cellY or 0) end
    local h = 0
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 10000 end
    return h % 100
  end

  local function isJohtoSpawn(npc)
    if not npc or npc.isPlayer or npc.role == "player" then return false end
    local d = npc.def or {}
    return npc.johtoLifeAmbient == true or npc.johtoLifePokeAmbient == true
      or d.johtoLifeAmbient == true or d.johtoLifePokeAmbient == true
  end

  local function isFollower(npc)
    if not npc then return false end
    if npc.pikachuFollower or npc.isFollower or npc.follower or npc.pokemonFollower
       or npc.partyFollower or npc.followingPlayer or npc.followsPlayer
       or npc.isCompanion or npc.companion then return true end
    local d = npc.def or {}
    if d.follower or d.isFollower or d.pokemonFollower or d.partyFollower
       or d.followingPlayer or d.followsPlayer or d.isCompanion or d.companion then return true end
    local id = tostring(npc.id or npc.name or d.name or d.sprite or ""):upper()
    return id:find("FOLLOWER", 1, true) ~= nil or id:find("COMPANION", 1, true) ~= nil
  end

  local function eligible(npc)
    if not isJohtoSpawn(npc) then return false end
    if npc.hidden or npc.frozen or npc.nightlifeSleeping or npc.dsShelter
       or npc.kantoLifeSleeping or npc.johtoLifeSleeping or npc.sleeping then return false end
    if npc._johtoServiceTraffic then return false end
    if npc.johtoLifeWaterBound or (npc.def and npc.def.johtoLifeWaterBound) then return false end
    return true
  end

  local function anchor(npc)
    if npc._johtoRoutineAnchorX == nil or npc._johtoRoutineAnchorY == nil then
      local d = npc.def or {}
      npc._johtoRoutineAnchorX = tonumber(d.x) or tonumber(npc.cellX) or 0
      npc._johtoRoutineAnchorY = tonumber(d.y) or tonumber(npc.cellY) or 0
    end
    return npc._johtoRoutineAnchorX, npc._johtoRoutineAnchorY
  end

  -- Gen1Recomp's public npc() accepts an object name or object index. Spawned
  -- Johto Life actors have a stable generated name, so name is the primary
  -- lookup. Index is retained as a fallback for mapped actors.
  local function handle(world, npc)
    if not world or not world.map or not mod or not mod.world or not npc then return nil end
    local map = world.map
    if handlesMap ~= map.id then handles = {}; handlesMap = map.id end
    local keyId = tostring(npc.id or "")
    local d = npc.def or {}
    local keys = {}
    if d.name ~= nil then keys[#keys + 1] = d.name end
    if d.index ~= nil then keys[#keys + 1] = d.index end
    if npc.id ~= nil then keys[#keys + 1] = npc.id end
    for _, key in ipairs(keys) do
      local ok, got = pcall(function() return mod.world:npc(map.id, key) end)
      if ok and got then
        if keyId ~= "" then handles[keyId] = got end
        return got
      end
    end
    return nil
  end

  local function handlePosition(h, npc)
    if h and type(h.position) == "function" then
      local ok, pos = pcall(h.position, h)
      if ok and type(pos) == "table" then
        local x = tonumber(pos.x or pos.cellX or pos[1])
        local y = tonumber(pos.y or pos.cellY or pos[2])
        if x ~= nil and y ~= nil then return x, y end
      end
    end
    return tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
  end

  local function doorTiles(map)
    local out = {}
    if not map or type(map.isDoorTileCell) ~= "function" then return out end
    local w = tonumber(map.widthCells or map.width or (map.def and map.def.widthCells) or (map.def and map.def.width))
    local h = tonumber(map.heightCells or map.height or (map.def and map.def.heightCells) or (map.def and map.def.height))
    if not w or not h then return out end
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local ok, yes = pcall(map.isDoorTileCell, map, x, y)
        if ok and yes then out[#out + 1] = {x, y, "door"} end
      end
    end
    return out
  end

  local function outdoorExits(world)
    local map = world and world.map
    if not map then return {} end
    local data = getGame() and getGame().data
    local currentId = tostring(map.id or "")
    local out = {}
    local seen = {}
    for _, w in ipairs((map.def and map.def.warps) or {}) do
      if w.x ~= nil and w.y ~= nil then
        local dest
        if type(resolveDestMap) == "function" then
          local ok, x = pcall(resolveDestMap, data, w, world.lastOutdoor or world.backupWarp)
          if ok then dest = x end
        end
        local destId = tostring(dest or "")
        if destId ~= "" and destId:upper() ~= currentId:upper() then
          local destIndoor = false
          pcall(function() destIndoor = isIndoor(destId) end)
          local kind = destIndoor and "door" or (isRoute(destId) and "route" or "exit")
          local k = tostring(w.x)..","..tostring(w.y)
          if not seen[k] then
            seen[k] = true
            out[#out + 1] = {tonumber(w.x), tonumber(w.y), kind, destId}
          end
        end
      end
    end

    -- Gen 1/2 route transitions are map connections, not ordinary warps.
    -- Use the real edge cell so a routine actor can be handed off at the
    -- connection instead of being sent back to its anchor.
    local def = map.def or {}
    local conns = def.connections
    if type(conns) == "table" then
      local mw = tonumber(map.widthCells or (map.width and map.width * 2) or def.widthCells or (def.width and def.width * 2)) or 0
      local mh = tonumber(map.heightCells or (map.height and map.height * 2) or def.heightCells or (def.height and def.height * 2)) or 0
      for dir, conn in pairs(conns) do
        local dest = type(conn) == "table" and (conn.map or conn.mapId or conn.dest) or conn
        if dest and tostring(dest):upper() ~= currentId:upper() then
          local x, y
          if dir == "north" then x,y = math.floor((mw-1)/2),0
          elseif dir == "south" then x,y = math.floor((mw-1)/2),mh-1
          elseif dir == "west" then x,y = 0,math.floor((mh-1)/2)
          elseif dir == "east" then x,y = mw-1,math.floor((mh-1)/2) end
          if x and y and x >= 0 and y >= 0 and x < mw and y < mh then
            local ok, walk = pcall(map.isWalkableCell, map, x, y)
            if ok and walk then out[#out+1] = {x,y,"route",tostring(dest),conn,dir} end
          end
        end
      end
    end
    return out
  end

  local function buildDestinations(world)
    local map = world and world.map
    if not map then return {} end
    local id = tostring(map.id or "")
    if isIndoor(id, map) then
      local out, seen = {}, {}
      for _, w in ipairs((map.def and map.def.warps) or {}) do
        if w.x ~= nil and w.y ~= nil then
          local k = tostring(w.x)..":"..tostring(w.y)
          if not seen[k] then
            seen[k] = true
            out[#out + 1] = { tonumber(w.x), tonumber(w.y), "door", tostring(w.destMap or ""), tonumber(w.destX), tonumber(w.destY), "warp", w }
          end
        end
      end
      if #out > 0 then return out end
      return doorTiles(map)
    end
    return outdoorExits(world)
  end

  local function nearestExit(npc, exits)
    if #exits == 0 then return nil end
    local ax, ay = anchor(npc)
    local best, bd
    for _, e in ipairs(exits) do
      local d = math.abs(e[1]-ax) + math.abs(e[2]-ay)
      if not bd or d < bd then best, bd = e, d end
    end
    return best
  end

  local function releaseNative(npc)
    if npc._johtoRoutineOrigWanders ~= nil then
      npc.wanders = npc._johtoRoutineOrigWanders
      npc._johtoRoutineOrigWanders = nil
    end
    npc._johtoRoutineTraveling = nil
    npc._johtoRoutineTargetX = nil
    npc._johtoRoutineTargetY = nil
  end

  local function activateNative(npc)
    if npc._johtoRoutineOrigWanders == nil then
      npc._johtoRoutineOrigWanders = npc.wanders
    end
    npc.wanders = false
  end

  local function setState(npc, traveling, exits)
    local key = actorKey(npc)
    local st = states[key]
    if not st then st = {}; states[key] = st; stateKeys[key] = npc end
    st.npc = npc
    st.traveling = traveling
    st.phase = traveling and "wander" or "idle"
    st.target = nil
    st.wait = traveling and (2.5 + math.random() * 4.0) or 0
    st.repath = 0
    st.wanderUntil = st.wait
    st.wanderTarget = nil
    st.blockedTime = 0
    st.blockedCount = 0
    st.travelKind = (hash(npc) < 50) and "route" or "door"
    npc._johtoRoutineTraveling = traveling and true or false
    -- All Kanto/Johto Life actors use this controller for continuous ambient
    -- walking. Travel percentage controls doorway/route journeys, not whether
    -- an actor freezes after a few native wander steps.
    activateNative(npc)
  end

  -- Optional BFS when the map exposes isWalkableCell. This is only used to
  -- choose a route; movement itself always goes through the public NPC handle.
  local function pathTo(world, npc, tx, ty)
    local map = world and world.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil end
    -- Defensive: callers occasionally pass a destination table instead of
    -- coordinates. Coerce (same guard as KantoRoutines; fixes live crash
    -- "attempt to concatenate local 'tx' (a table value)").
    if type(tx) == "table" then tx, ty = tx[1], tx[2] end
    tx, ty = tonumber(tx), tonumber(ty)
    if tx == nil or ty == nil then return nil end
    local sx, sy = npc.cellX or 0, npc.cellY or 0
    if sx == tx and sy == ty then return {} end
    -- Map.width/height are block dimensions in both Gen 1 and Gold.
    -- NPC positions and warps are CELL coordinates, so pathfinding over the
    -- block count silently clipped the routable area in half.
    local mw = tonumber(map.widthCells or (map.width and map.width * 2) or (map.def and map.def.widthCells) or (map.def and map.def.width and map.def.width * 2)) or 0
    local mh = tonumber(map.heightCells or (map.height and map.height * 2) or (map.def and map.def.heightCells) or (map.def and map.def.height and map.def.height * 2)) or 0
    if mw <= 0 or mh <= 0 then return nil end
    local occupied = {}
    for _, e in ipairs(world.npcs or {}) do
      if e ~= npc and e.passable ~= true then
        occupied[(e.cellX or 0)..","..(e.cellY or 0)] = true
        if e.targetX ~= nil and e.targetY ~= nil then occupied[e.targetX..","..e.targetY] = true end
      end
    end
    if world.player then occupied[(world.player.cellX or 0)..","..(world.player.cellY or 0)] = true end
    occupied[sx..","..sy] = nil
    occupied[tx..","..ty] = nil
    local qx, qy, head = {sx}, {sy}, 1
    local parent = {}
    local seen = {[sx..","..sy] = true}
    local goalKey = tx..","..ty
    while head <= #qx do
      local x, y = qx[head], qy[head]; head = head + 1
      if x == tx and y == ty then break end
      for _, d in ipairs(DIRS) do
        local nx, ny = x+d[1], y+d[2]
        local k = nx..","..ny
        if nx >= 0 and ny >= 0 and nx < mw and ny < mh
           and not seen[k] and not occupied[k] then
          local ok, walkable = pcall(map.isWalkableCell, map, nx, ny)
          if ok and walkable then
            seen[k] = true
            parent[k] = {x=x, y=y, dir=d[3]}
            qx[#qx+1], qy[#qy+1] = nx, ny
          end
        end
      end
      if #qx > 5000 then break end
    end
    if not seen[goalKey] then return nil end
    local rev, k = {}, goalKey
    while k ~= sx..","..sy do
      local p = parent[k]
      if not p then return nil end
      rev[#rev+1] = p.dir
      k = p.x..","..p.y
    end
    local path = {}
    for i = #rev, 1, -1 do path[#path+1] = rev[i] end
    return path
  end

  local function directDirs(npc, tx, ty)
    local cx, cy = npc.cellX or 0, npc.cellY or 0
    local dirs = {}
    if tx > cx then dirs[#dirs+1] = "right" elseif tx < cx then dirs[#dirs+1] = "left" end
    if ty > cy then dirs[#dirs+1] = "down" elseif ty < cy then dirs[#dirs+1] = "up" end
    return dirs
  end

  local pathCache = {}
  local function stepToward(world, npc, tx, ty)
    -- Defensive: coerce table targets to coordinates (same guard as
    -- KantoRoutines).
    if type(tx) == "table" then tx, ty = tx[1], tx[2] end
    tx, ty = tonumber(tx), tonumber(ty)
    if tx == nil or ty == nil then return false end
    local h = handle(world, npc)
    if not h then return false end
    if npc.moving then return true end
    if type(h.isMoving) == "function" then
      local ok, moving = pcall(h.isMoving, h)
      if ok and moving then return true end
    end
    local bx, by = handlePosition(h, npc)
    local key = actorKey(npc)
    local c = pathCache[key]
    if not c or c.tx ~= tx or c.ty ~= ty or c.mapId ~= tostring(world.map and world.map.id or "") then
      local path = pathTo(world, npc, tx, ty)
      c = {tx=tx, ty=ty, mapId=tostring(world.map and world.map.id or ""), path=path or {}}
      pathCache[key] = c
    end
    local dirs = c.path and #c.path > 0 and {c.path[1]} or directDirs(npc, tx, ty)
    if #dirs == 0 then return npc.cellX == tx and npc.cellY == ty end
    local tried, candidates = {}, {}
    for _, dir in ipairs(dirs) do tried[dir] = true; candidates[#candidates + 1] = dir end
    for _, dir in ipairs(directDirs(npc, tx, ty)) do if not tried[dir] then tried[dir] = true; candidates[#candidates + 1] = dir end end
    for _, dir in ipairs({"up","down","left","right"}) do if not tried[dir] then tried[dir] = true; candidates[#candidates + 1] = dir end end
    for _, dir in ipairs(candidates) do
      local dd = ({up={0,-1},down={0,1},left={-1,0},right={1,0}})[dir]
      local nx = (npc.cellX or 0) + (dd and dd[1] or 0)
      local ny = (npc.cellY or 0) + (dd and dd[2] or 0)
      local other = actorAt(world, nx, ny, npc)
      if other then
        setCollisionBubble(npc, other)
        goto next_dir
      end
      if type(h.canStep) == "function" then
        local okCan, can = pcall(h.canStep, h, dir)
        if not okCan or not can then goto next_dir end
      end
      if type(h.stepNow) == "function" then
        -- Gold routine NPCs were left at an overly slow 86-frame step.
        -- Use ~57 frames (86 / 1.5) for a 50% speed increase.
        npc.stepFrames = 57
        local okStep = pcall(h.stepNow, h, dir)
        if okStep then
          if c and c.path and #c.path > 0 then table.remove(c.path, 1) end
          if type(h.isMoving) == "function" then local okM, moving = pcall(h.isMoving, h); if okM and moving then return true end end
          local ax, ay = handlePosition(h, npc)
          if ax ~= bx or ay ~= by then return true end
          -- A successful API call is not necessarily a successful movement:
          -- another NPC can reject the step between canStep and stepNow.
          return false
        end
      elseif type(h.scriptMove) == "function" then
        local okMove = pcall(h.scriptMove, h, dir, 1)
        if okMove then return true end
      end
      ::next_dir::
    end
    return false
  end

  local function occupied(world, x, y, except)
    if world.player and world.player ~= except and world.player.cellX == x and world.player.cellY == y then return true end
    for _, n in ipairs(world.npcs or {}) do
      if n ~= except and n.passable ~= true and n.cellX == x and n.cellY == y then return true end
    end
    return false
  end

  local function wanderTarget(world, npc)
    local map = world and world.map
    local mw = tonumber(map and (map.widthCells or (map.width and map.width * 2) or (map.def and (map.def.widthCells or (map.def.width and map.def.width * 2))))) or 255
    local mh = tonumber(map and (map.heightCells or (map.height and map.height * 2) or (map.def and (map.def.heightCells or (map.def.height and map.def.height * 2))))) or 255
    for _ = 1, 48 do
      local tx = math.random(1, math.max(1, mw - 2))
      local ty = math.random(1, math.max(1, mh - 2))
      local isDoor = false
      if map and type(map.isDoorTileCell) == "function" then pcall(function() isDoor = map:isDoorTileCell(tx,ty) end) end
      if not isDoor and not occupied(world, tx, ty, npc) then
        if not map or type(map.isWalkableCell) ~= "function" then return {tx,ty} end
        local ok, walk = pcall(map.isWalkableCell, map, tx, ty)
        if ok and walk then return {tx,ty} end
      end
    end
    return nil
  end

  local function destinationTarget(world, npc, d)
    if not d then return nil end
    local map = world and world.map
    local x, y = tonumber(d[1]), tonumber(d[2])
    if not map or x == nil or y == nil then return nil end
    local walk = true
    if type(map.isWalkableCell) == "function" then
      local ok, v = pcall(map.isWalkableCell, map, x, y); walk = ok and v == true
    end
    if walk then return x, y end
    return nil
  end

  local function approachDestination(world, npc, d)
    if not d then return nil end
    local map = world and world.map
    local x, y = tonumber(d[1]), tonumber(d[2])
    if not map or x == nil or y == nil then return d end
    local candidates = {}
    for _, dir in ipairs(DIRS) do
      local nx, ny = x + dir[1], y + dir[2]
      local walk = true
      if type(map.isWalkableCell) == "function" then
        local ok, v = pcall(map.isWalkableCell, map, nx, ny); walk = ok and v == true
      end
      local warp = false
      if type(map.warpAt) == "function" then
        local ok, v = pcall(map.warpAt, map, nx, ny); warp = ok and v ~= nil
      elseif type(map.warpAtCell) == "function" then
        local ok, v = pcall(map.warpAtCell, map, nx, ny); warp = ok and v ~= nil
      end
      if walk and not warp and not occupied(world, nx, ny, npc) then
        candidates[#candidates+1] = { x = nx, y = ny, dist = math.abs((npc.cellX or 0)-nx) + math.abs((npc.cellY or 0)-ny) }
      end
    end
    table.sort(candidates, function(a,b) return a.dist < b.dist end)
    if #candidates == 0 then return nil end
    local out = { d[1], d[2], d[3], d[4] }
    out[5], out[6] = candidates[1].x, candidates[1].y
    return out
  end

  local function destinationFor(world, npc, old, kind)
    local map = world and world.map
    local routeOnly = isRoute(tostring(map and map.id or ""))
    local doors, exits, fallback = {}, {}, {}
    for _, d in ipairs(destinations or {}) do
      local same = old and d[1] == old[1] and d[2] == old[2]
      if not occupied(world, d[1], d[2], npc) then
        fallback[#fallback+1] = d
        if not same then
          if d[3] == "route" or d[3] == "exit" then exits[#exits+1] = d
          else doors[#doors+1] = d end
        end
      end
    end
    local function pick(list)
      if #list == 0 then return nil end
      local pool = {}
      for _, d in ipairs(list) do
        local k = tostring(d[1]) .. ":" .. tostring(d[2])
        if not npc._kantoLifeLastExitDoorKey or k ~= npc._kantoLifeLastExitDoorKey then pool[#pool+1] = d end
      end
      if #pool == 0 then pool = list end
      return pool[math.random(#pool)]
    end
    if routeOnly and #exits > 0 then return pick(exits) end
    if kind == "route" and #exits > 0 then return pick(exits) end
    if kind == "door" and #doors > 0 then
      local d = pick(doors); local tx,ty=destinationTarget(world,npc,d); if tx then d[5],d[6]=tx,ty; return d end
      return approachDestination(world,npc,d)
    end
    if #exits > 0 then return pick(exits) end
    if #doors > 0 then
      local d = pick(doors); local tx,ty=destinationTarget(world,npc,d); if tx then d[5],d[6]=tx,ty; return d end
      return approachDestination(world,npc,d)
    end
    if #fallback > 0 then return approachDestination(world, npc, fallback[math.random(#fallback)]) end
    return nil
  end

  local function spawnReplacement(world, npc, door)
    if not world or not world.map or not door or not mod or not mod.world then return false end
    -- Gen 3 behavior: the actor that reaches a doorway leaves the population,
    -- and the replacement enters from a DIFFERENT available doorway when one
    -- exists.  The previous Gen 1/2 implementation respawned at `door`, which
    -- made the same NPC appear to teleport back into the same threshold.
    local replacementDoor = destinationFor(world, npc, door, "door")
    if not replacementDoor then return false end
    local d = npc.def or {}
    local poke = npc["johtoLifePokeAmbient"] == true or d["johtoLifePokeAmbient"] == true
    local sprite = d.sprite or (npc.sprite and npc.sprite.def and npc.sprite.def.id)
    if not sprite then return false end
    local serial = tostring(npc.id or d.name or math.random(100000)) .. "_R" .. tostring(math.random(100000))
    local name = "JOHTO_ROUTINE_" .. serial
    local def = {
      name=name, sprite=sprite, x=replacementDoor[1], y=replacementDoor[2], text="",
      movement="WALK", range="ANY_DIR",
      ["johtoLifeAmbient"]=true,
      ["johtoLifePokeAmbient"]=poke or nil,
      ["johtoLifeDisplayName"]= d["johtoLifeDisplayName"] or npc["johtoLifeDisplayName"],
      ["johtoLifeGender"]= d["johtoLifeGender"] or npc["johtoLifeGender"],
      ["johtoLifeSpecies"]= d["johtoLifeSpecies"] or npc["johtoLifeSpecies"],
      ["johtoLifeMon"]= d["johtoLifeMon"] or npc["johtoLifeMon"],
      ["johtoLifeAquatic"]= d["johtoLifeAquatic"] or npc["johtoLifeAquatic"],
    }
    local id = mod.world:spawnNpc(world.map.id, def)
    local got = type(id)=="table" and id.id or id
    if not got then return false end
    pcall(function() mod.world:removeNpc(npc.id or (d.id)) end)
    return true
  end

  local function refresh(world, force)
    destinations = buildDestinations(world)
    local pct = optionPct()
    local candidates = {}
    for _, npc in ipairs(world.npcs or {}) do
      if eligible(npc) then candidates[#candidates + 1] = npc end
    end
    table.sort(candidates, function(a,b)
      local ha, hb = hash(a), hash(b)
      if ha == hb then return actorKey(a) < actorKey(b) end
      return ha < hb
    end)
    local indoorNow = isIndoor(world)
    local desired = indoorNow and #candidates or math.ceil(#candidates * pct / 100)
    if not indoorNow then
      if pct <= 0 then desired = 0 elseif pct >= 100 then desired = #candidates end
    end
    local selected = {}
    for i=1,desired do selected[actorKey(candidates[i])] = true end
    for _, npc in ipairs(candidates) do
      local traveling = selected[actorKey(npc)] == true
      local st = states[actorKey(npc)]
      if force or not st or st.traveling ~= traveling then
        setState(npc, traveling, destinations)
      end
    end
    dirty = false
    travelPct = pct
  end

  function api.setEnabled(v)
    enabled = v and true or false
    dirty = true
    if not enabled then
      for key, st in pairs(states) do if st.npc then releaseNative(st.npc) end; states[key] = nil; stateKeys[key] = nil end
    end
  end

  local agendaMode = 0
  local agendaStates = setmetatable({}, { __mode = "k" })
  local agendaDoors = {}
  local agendaLastNight = nil

  local function agendaHash(npc)
    local s = tostring(npc and npc.id or "")
    if s == "" then s = tostring(npc and npc.def and npc.def.name or "") end
    local h = 0
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 10000 end
    return h % 100
  end

  local function agendaNight(world)
    if not world then return false end
    local tod
    if type(world.timeOfDay) == "function" then
      local ok, v = pcall(world.timeOfDay, world); if ok then tod = v end
    end
    tod = tostring(tod or world.tod or ""):upper()
    return tod == "NIGHT" or tod == "NITE" or tod == "MIDNIGHT"
  end

  local function agendaEligible(npc)
    if not isJohtoSpawn(npc) then return false end
    if npc.nightlifeSleeping or npc.frozen or npc.moving then return false end
    if npc.dsShelter or npc.dsGlanceFacing ~= nil then return false end
    if npc.johtoLifePokemon or (npc.def and npc.def.johtoLifePokemon) then return false end
    return true
  end

  local function agendaAnchor(npc)
    if npc._johtoAgendaAnchorX == nil or npc._johtoAgendaAnchorY == nil then
      local d = npc.def or {}
      npc._johtoAgendaAnchorX = tonumber(d.x) or tonumber(npc.cellX) or 0
      npc._johtoAgendaAnchorY = tonumber(d.y) or tonumber(npc.cellY) or 0
    end
    return npc._johtoAgendaAnchorX, npc._johtoAgendaAnchorY
  end

  local function agendaDoorList(world)
    local map = world and world.map
    if not map then return {} end
    local id = tostring(map.id or "")
    if agendaDoors[id] then return agendaDoors[id] end
    local out = {}
    local w = tonumber(map.width or (map.def and map.def.width)) or 0
    local h = tonumber(map.height or (map.def and map.def.height)) or 0
    if type(map.isDoorTileCell) == "function" then
      for y = 0, h - 1 do
        for x = 0, w - 1 do
          local ok, yes = pcall(map.isDoorTileCell, map, x, y)
          if ok and yes then out[#out + 1] = {x, y} end
        end
      end
    end
    agendaDoors[id] = out
    return out
  end

  local function agendaNearestDoor(world, npc)
    local doors = agendaDoorList(world)
    local ax, ay = agendaAnchor(npc)
    local best, bd
    for _, d in ipairs(doors) do
      local dist = math.abs(d[1] - ax) + math.abs(d[2] - ay)
      if not bd or dist < bd then best, bd = d, dist end
    end
    return best
  end

  local function agendaHandle(world, npc)
    local h = npc._johtoAgendaHandle
    if h then return h end
    local map = world and world.map
    local d = npc.def or {}
    local key = d.index or d.name or npc.id
    if not (map and key ~= nil and mod.world) then return nil end
    local ok, got = pcall(function() return mod.world:npc(map.id, key) end)
    if ok and got then npc._johtoAgendaHandle = got; return got end
    return nil
  end

  local function agendaStep(world, npc, tx, ty)
    if npc.moving then return true end
    return stepToward(world, npc, tx, ty)
  end

  local function agendaUpdate(world, dt, force)
    if not world or not world.map or agendaMode == 0 then
      for npc, st in pairs(agendaStates) do
        npc._johtoAgendaTargetX, npc._johtoAgendaTargetY = nil, nil
        agendaStates[npc] = nil
      end
      return
    end
    local night = agendaNight(world)
    if force or agendaLastNight ~= night then
      agendaLastNight = night
      agendaDoors = {}
      for npc in pairs(agendaStates) do agendaStates[npc] = nil end
    end
    for _, npc in ipairs(world.npcs or {}) do
      if agendaEligible(npc) then
        local st = agendaStates[npc]
        if not st then
          local participate = false
          if agendaMode == 1 then
            participate = (not night) and agendaHash(npc) < 10
          elseif agendaMode == 2 then
            participate = night or agendaHash(npc) < 10
          end
          if participate then
            local d = agendaNearestDoor(world, npc)
            if isIndoor(tostring(world.map.id or ""), world.map) then
              local pool = buildDestinations(world)
              if #pool > 0 then d = pool[1] end
            end
            if d then
              st = { target = {d[1], d[2]}, phase = "out", wait = 0, repath = 0 }
              agendaStates[npc] = st
              npc.wanders = false
            end
          end
        end
        if st then
          local t = st.target
          if npc.cellX == t[1] and npc.cellY == t[2] then
            st.wait = (st.wait or 0) - (dt or 0)
            if st.wait <= 0 then
              if st.phase == "out" then
                local ax, ay = agendaAnchor(npc)
                st.phase = "home"; st.target = {ax, ay}; st.wait = 4
              else
                st.phase = "out"
                local d = agendaNearestDoor(world, npc)
                if d then st.target = {d[1], d[2]}; st.wait = 0 else st.target = agendaAnchor(npc); st.wait = 2 end
              end
            end
          else
            agendaStep(world, npc, t[1], t[2])
          end
        end
      end
    end
    -- Release agenda control from actors no longer eligible or when their
    -- mode no longer selects them.
    for npc, st in pairs(agendaStates) do
      if not agendaEligible(npc) then
        npc.wanders = true
        npc._johtoAgendaTargetX, npc._johtoAgendaTargetY = nil, nil
        agendaStates[npc] = nil
      end
    end
  end

  function api.setAgenda(v)
    local n = math.floor(tonumber(v) or 0)
    if n < 0 then n = 0 elseif n > 2 then n = 2 end
    if n ~= agendaMode then agendaMode = n; agendaDoors = {}; agendaLastNight = nil end
  end

  function api.setTravelPercent(v)
    local n = math.floor((tonumber(v) or 30) / 10 + 0.5) * 10
    if n < 0 then n = 0 elseif n > 100 then n = 100 end
    if n ~= travelPct then dirty = true end
    travelPct = n
  end

  function api.update(world, dt, force)
    if not world or not world.map or not world.npcs then return end
    agendaUpdate(world, dt or 0, force)
    if not enabled then return end
    local mapId = tostring(world.map.id or "")
    local pct = optionPct()
    if pct ~= travelPct then dirty = true end
    -- Ambient actors are spawned after the overworld update on some maps.
    -- Detect newly spawned Kanto/Johto Life actors so they are assigned on
    -- the following frame instead of waiting for another map change.
    for _, candidate in ipairs(world.npcs or {}) do
      if eligible(candidate) and not states[actorKey(candidate)] then dirty = true; break end
    end
    local mapChanged = lastMap ~= mapId
    if mapChanged then lastMap = mapId; dirty = true end
    if dirty or force then refresh(world, force or mapChanged) end

    for key, st in pairs(states) do
      local npc = st.npc or stateKeys[key]
      if not npc or not eligible(npc) then
        if npc then releaseNative(npc) end
        states[key] = nil; stateKeys[key] = nil; goto continue
      end
      activateNative(npc)

      if not st.traveling then
        st.wait = math.max(0, (st.wait or 0) - (dt or 0))
        if not st.wanderTarget then st.wanderTarget = wanderTarget(world, npc) end
        local wt = st.wanderTarget
        if wt and npc.cellX == wt[1] and npc.cellY == wt[2] then st.wanderTarget = nil end
        if (st.wait or 0) <= 0 and st.wanderTarget and not npc.moving then
          stepToward(world, npc, st.wanderTarget[1], st.wanderTarget[2])
        end
        goto continue
      end

      if st.phase == "wander" then
        st.wait = (st.wait or 0) - (dt or 0)
        if not st.wanderTarget then st.wanderTarget = wanderTarget(world, npc) end
        local wt = st.wanderTarget
        if wt and npc.cellX == wt[1] and npc.cellY == wt[2] then st.wanderTarget = nil end
        if st.wait <= 0 then
          st.phase = "outbound"
          st.target = destinationFor(world, npc, nil)
          st.repath = 0
        elseif st.wanderTarget then
          if not npc.moving then stepToward(world, npc, st.wanderTarget[1], st.wanderTarget[2]) end
        end
        goto continue
      end

      if not st.target then st.target = destinationFor(world, npc, nil, st.travelKind) end
      local t = st.target
      if not t then goto continue end
      local tx, ty = t[5] or t[1], t[6] or t[2]
      if npc.cellX == tx and npc.cellY == ty then
        local old = {t[1], t[2], t[3], t[4]}
        if type(onRoutineExit) == "function" then
          local ok, replaced = pcall(onRoutineExit, npc, world, old)
          if ok and replaced then states[key] = nil; stateKeys[key] = nil; goto continue end
        end
        local replacement = destinationFor(world, npc, old, st.travelKind)
        if replacement and spawnReplacement(world, npc, replacement) then
          states[key] = nil; stateKeys[key] = nil; goto continue
        end
        -- If a replacement cannot be created, keep the actor alive and send it
        -- back to its anchor rather than deleting the population.
        st.phase = "wander"; st.wait = 2.0; st.wanderTarget = nil; st.target = nil
      else
        local moved = stepToward(world, npc, tx, ty)
        if moved then
          st.repath = 0
          st.blockedTime = 0
          st.blockedCount = 0
        else
          st.repath = (st.repath or 0) + (dt or 0)
          st.blockedTime = (st.blockedTime or 0) + (dt or 0)
          if st.blockedTime >= 0.75 then
            st.blockedTime = 0
            st.blockedCount = (st.blockedCount or 0) + 1
            st.repath = 0
            st.target = destinationFor(world, npc, st.target, st.travelKind)
            if st.blockedCount >= 3 then
              st.blockedCount = 0
              st.phase = "wander"
              st.wait = 1.0
              st.wanderTarget = nil
              st.target = nil
            end
          elseif st.repath > 1.0 then
            st.repath = 0
            st.target = destinationFor(world, npc, st.target, st.travelKind)
          end
        end
      end
      ::continue::
    end
    nearbyCollisionBubbles(world)
  end

  function api.reset(world)
    dirty = true
    if world then api.update(world, 0, true) end
  end

  return api
end
