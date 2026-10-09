-- Kanto Life custom routines controller 0.8.96

-- Controls only Kanto Life ambient actors. It uses Gen1Recomp's public NPC
-- handle API and does not modify Battle Art, Porygonal, HGSS_SPRITES, or Terrarium.
return function(ctx)
  local mod = ctx.mod
  local getGame = ctx.game or function() return nil end
  local isIndoor = ctx.isIndoor or function() return false end
  local isTown = ctx.isTown or function() return false end
  local isRoute = ctx.isRoute or function() return false end
  local resolveDestMap = ctx.resolveDestMap
  local onRoutineExit = ctx.onRoutineExit
  local getPokeSpriteObject = ctx.getPokeSpriteObject or function() return nil end

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
  local lastWorld = nil

  -- Random travel methods: door, route, fly, teleport, surf.
  -- Fly/teleport/surf NPCs depart in place with a visual effect instead of
  -- walking to an exit. Surf requires water nearby.
  local function waterNearby(world, npc, radius)
    local map = world and world.map
    if not map then return false end
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
      local ok, v = pcall(ctx.getOption, "npc_travel_methods")
      if ok and v ~= nil then return v ~= false end
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
    -- 25% each: fly, teleport, door, route (per user request)
    local roll = math.random(100)
    if roll <= 25 then return "fly"
    elseif roll <= 50 then return "teleport"
    elseif roll <= 75 then return "door"
    else return "route" end
  end

  -- Visual departure effect markers. The main controller's draw wrappers can
  -- use these for fancier effects; the routines themselves just need the
  -- timing. Fail-open: if nothing reads them, the NPC still despawns.
  local function startDepartEffect(npc, method)
    local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    npc._kantoLifeDepartMethod = method
    npc._kantoLifeDepartUntil = now + 1.2
    -- Trigger real animation (in addition to bubble cue).
    if method == "teleport" then
      pcall(npcTeleportOut, npc)
    elseif method == "fly" then
      pcall(npcFlyOut, npc)
    end
    -- Show a cue bubble so the departure doesn't look like a pop.
    local cue = method == "fly" and "^^" or method == "teleport" and "**" or method == "surf" and "~~" or "!"
    npc._kantoLifeCollisionBubbleText = cue
    npc._kantoLifeCollisionBubbleUntil = now + 1.2
  end

  -- Stuck recovery: teleport NPC to nearest walkable cell.
  -- Called when blockedCount >= 3. Keeps the same NPC (no despawn/pop).
  local function teleportUnstick(world, npc)
    local map = world and world.map
    if not map or type(map.isWalkableCell) ~= "function" then return false end
    local cx, cy = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    -- Spiral search: 5-15 cells away, find walkable unoccupied cell
    for radius = 5, 15 do
      for angle = 0, 7 do
        local tx = cx + math.floor(radius * math.cos(angle * math.pi / 4) + 0.5)
        local ty = cy + math.floor(radius * math.sin(angle * math.pi / 4) + 0.5)
        if tx ~= cx or ty ~= cy then
          local ok, walk = pcall(map.isWalkableCell, map, tx, ty)
          if ok and walk then
            -- Check not occupied (simple: no other NPC at target)
            local occupied = false
            if world.npcs then
              for _, other in ipairs(world.npcs) do
                if other ~= npc and tonumber(other.cellX) == tx and tonumber(other.cellY) == ty then
                  occupied = true
                  break
                end
              end
            end
            if not occupied then
              -- Teleport with visual cue
              startDepartEffect(npc, "teleport")
              npc.cellX, npc.cellY = tx, ty
              if type(npc.px) == "number" then npc.px, npc.py = tx * 16, ty * 16 end
              npc.targetX, npc.targetY = nil, nil
              npc.moving = false
              startArriveEffect(npc, "teleport")
              return true
            end
          end
        end
      end
    end
    return false
  end

  local function startArriveEffect(npc, method)
    local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    npc._kantoLifeArriveMethod = method
    npc._kantoLifeArriveUntil = now + 1.2
    -- Trigger real animation (in addition to bubble cue).
    if method == "teleport" then
      pcall(npcTeleportIn, npc)
    elseif method == "fly" then
      pcall(npcFlyIn, npc)
    end
    -- Show a cue bubble so the arrival doesn't look like a pop.
    local cue = method == "fly" and "vv" or method == "teleport" and "**" or "!"
    npc._kantoLifeCollisionBubbleText = cue
    npc._kantoLifeCollisionBubbleUntil = now + 1.2
  end

  -- Random flying Pokémon species for fly animation.
  -- User requirement: real bird/flying Pokémon (legendaries OK), not SPRITE_BIRD.
  local flyingSpeciesCache = nil
  local function randomFlyingSpecies()
    if flyingSpeciesCache and #flyingSpeciesCache > 0 then
      return flyingSpeciesCache[math.random(#flyingSpeciesCache)]
    end
    -- Try to get game data (set by KantoMain)
    local gd = _G._kantoLifeGameData
    local data = gd and gd.pokemon
    if type(data) ~= "table" then return nil end
    local flyers = {}
    for name, pdef in pairs(data) do
      if type(pdef) == "table" and type(pdef.types) == "table" then
        for _, ty in ipairs(pdef.types) do
          if tostring(ty):upper() == "FLYING" then
            flyers[#flyers + 1] = name
            break
          end
        end
      end
    end
    flyingSpeciesCache = flyers
    if #flyers == 0 then return nil end
    return flyers[math.random(#flyers)]
  end

  -- NPC Teleport OUT animation.
  -- Gen 2: uses built-in npc:scriptTeleport("from").
  -- Gen 1/3: custom spin + rise (mirrors Player:pose logic).
  local function npcTeleportOut(npc)
    -- Play sound
    pcall(function()
      local gd = _G._kantoLifeGameData
      if gd then require("src.core.Sound").play(gd, "Teleport_Exit2") end
    end)
    -- Gen 2 built-in (verified: src/world/gen2/Npc.lua:391)
    if type(npc.scriptTeleport) == "function" then
      pcall(npc.scriptTeleport, npc, "from")
      return true
    end
    -- Gen 1/3 custom: spin + rise with Abra (user requirement)
    -- Swap to Abra sprite for the teleport animation
    local abraSprite = nil
    pcall(function() abraSprite = getPokeSpriteObject("ABRA") end)
    npc.kantoLifeTeleport = {
      frame = 0,
      mode = "out",
      sprite = abraSprite,  -- Abra shown via pose wrapper (npc.sprite untouched)
    }
    npc.frozen = true
    return true
  end

  -- NPC Teleport IN animation (arrival).
  local function npcTeleportIn(npc)
    pcall(function()
      local gd = _G._kantoLifeGameData
      if gd then require("src.core.Sound").play(gd, "Teleport_Exit2") end
    end)
    if type(npc.scriptTeleport) == "function" then
      pcall(npc.scriptTeleport, npc, "to")
      return true
    end
    npc.kantoLifeTeleport = {
      frame = 0,
      mode = "in",
      sprite = nil,  -- Use NPC sprite for arrival
    }
    npc.frozen = true
    return true
  end

  -- NPC Fly OUT animation.
  -- Hides NPC, shows random flying Pokémon sprite flying up and away.
  local function npcFlyOut(npc)
    local species = randomFlyingSpecies()
    if not species then return false end
    -- Get bird sprite object
    local birdSprite = nil
    pcall(function() birdSprite = getPokeSpriteObject(species) end)
    if not birdSprite then return false end  -- No sprite, fall back to bubble
    -- Play sound
    pcall(function()
      local gd = _G._kantoLifeGameData
      if gd then require("src.core.Sound").play(gd, "Fly") end
    end)
    -- Bird sprite shown via pose wrapper (npc.sprite untouched)
    npc.kantoLifeFly = {
      species = species,
      frame = 0,
      mode = "out",
      sprite = birdSprite,
    }
    npc.frozen = true
    return true
  end

  -- NPC Fly IN animation (arrival).
  local function npcFlyIn(npc)
    local species = randomFlyingSpecies()
    if not species then return false end
    pcall(function()
      local gd = _G._kantoLifeGameData
      if gd then require("src.core.Sound").play(gd, "Fly") end
    end)
    npc.kantoLifeFly = {
      species = species,
      frame = 0,
      mode = "in",
      sprite = nil,  -- Use NPC sprite for arrival
    }
    npc.kantoLifeFlyHidden = true
    npc.frozen = true
    return true
  end

  -- Update teleport/fly animations. Called every frame before the frozen check.
  -- Returns true if the NPC is currently animating (skip normal routine).
  local function updateTravelAnimation(npc, dt)
    -- ENGINE-FAITHFUL travel animations (research 2026-10-09).
    --
    -- The engine NEVER modifies player.py. The lift exists ONLY in the
    -- pose return value. Our NPC:pose wrapper (KantoMain.lua) returns
    -- ta.py/ta.px from npc._kantoTravelAnim; npc.py stays at ground.
    -- 2D draws at returned py; voxel computes p.lift = e.py - vy.
    --
    -- Teleport: exact copy of Player teleport mechanics
    -- (OverworldController.lua:2432, Player.lua:191-212, Player.lua:312-329)
    -- Fly: engine path tables + phases (OverworldController.lua:2403, 6146)

    local SPIN_ORDER = {"down", "left", "up", "right"}

    -- Teleport animation state
    local tp = npc.kantoLifeTeleport
    if tp then
      -- Initialize _kantoTravelAnim on first frame
      if not npc._kantoTravelAnim then
        local holds, total, riseFrom, dropSteps
        if tp.mode == "out" then
          -- Departure: 135 frames (OverworldController.lua:2432)
          holds = {15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0, 3,3,3,3,3,0}
          total = 135
          riseFrom = 15
        else
          -- Arrival: 43 frames (OverworldController.lua:5429)
          holds = {3,3,3,3,3,0, 1,2,3,4,5,6,7,0}
          total = 43
          dropSteps = 6
        end
        npc._kantoTravelAnim = {
          kind = "teleport",
          frame = 0,
          spinStep = 0,
          spinHold = holds[1],
          holds = holds,
          total = total,
          riseFrom = riseFrom,
          dropSteps = dropSteps,
          sprite = tp.sprite,  -- Abra (set by startDepartEffect)
          px = npc.px,
          py = npc.py,  -- BASE py; pose wrapper adds lift
          facing = "down",
          phase = 0,
          sfxStep = -1,
        }
        npc.frozen = true
        -- Play departure SFX
        if tp.mode == "out" then
          pcall(function()
            local S = require("src.core.Sound")
            local g = type(getGame) == "function" and getGame() or nil
            if g then S.play(g.data, "Teleport_Exit2") end
          end)
        else
          pcall(function()
            local S = require("src.core.Sound")
            local g = type(getGame) == "function" and getGame() or nil
            if g then S.play(g.data, "Teleport_Enter1") end
          end)
        end
      end

      local ta = npc._kantoTravelAnim
      ta.frame = ta.frame + 1

      -- Tick holds exactly like Player:update (Player.lua:191-212)
      ta.spinHold = ta.spinHold - 1
      while ta.spinHold <= 0 and ta.spinStep < #ta.holds - 1 do
        ta.spinStep = ta.spinStep + 1
        ta.spinHold = ta.holds[ta.spinStep + 1]
      end

      -- SFX on step change (engine: steps 4,8,12 -> Exit2, step 16 -> Exit1)
      if ta.spinStep ~= ta.sfxStep then
        ta.sfxStep = ta.spinStep
        local key = nil
        if tp.mode == "out" then
          if ta.spinStep == 4 or ta.spinStep == 8 or ta.spinStep == 12 then
            key = "Teleport_Exit2"
          elseif ta.spinStep == 16 then
            key = "Teleport_Exit1"
          end
        end
        if key then
          pcall(function()
            local S = require("src.core.Sound")
            local g = type(getGame) == "function" and getGame() or nil
            if g then S.play(g.data, key) end
          end)
        end
      end

      -- Render exactly like Player:pose (Player.lua:312-329)
      ta.facing = SPIN_ORDER[ta.spinStep % 4 + 1]
      ta.phase = 0
      local lift = 0
      if tp.mode == "out" then
        -- Departure: rise 16px per step after riseFrom
        if ta.spinStep > ta.riseFrom then
          lift = (ta.spinStep - ta.riseFrom) * 16
        end
      else
        -- Arrival: start high, drop 16px per step
        local left = (ta.dropSteps or 6) - ta.spinStep
        if left > 0 then lift = left * 16 end
      end
      -- ta.py is pose py (raised); npc.py stays at ground
      ta.py = npc.py - lift
      ta.px = npc.px  -- Stay in place horizontally

      -- Done?
      if ta.frame >= ta.total then
        npc._kantoTravelAnim = nil
        npc.kantoLifeTeleport = nil
        npc.frozen = false
        if tp.mode == "out" then
          npc._kantoLifeTravelHidden = true  -- Hide until despawn
        end
      end
      return true  -- Animating
    end

    -- Fly animation: engine path tables + phases
    -- (OverworldController.lua:2403 flyTo, :6146 fxBird, :1364-1406 phases)
    local fl = npc.kantoLifeFly
    if fl then
      if not npc._kantoTravelAnim then
        -- FLY_PATH1, FLY_PATH2 from OverworldController.lua:85-97
        -- (screen-space offsets, anchored at FLY_ANCHOR)
        local FLY_ANCHOR = {0x3C, 0x48}
        npc._kantoTravelAnim = {
          kind = "fly",
          t = 0,
          phaseName = "flap",  -- flap -> path1 -> hold -> path2
          sprite = fl.sprite,  -- Flying-type (set by startDepartEffect)
          px = npc.px,
          py = npc.py,
          facing = "right",
          phase = 0,
          anchor = FLY_ANCHOR,
          path1 = {{0x3C,0x48},{0x3A,0x4E},{0x38,0x54},{0x36,0x5A},{0x34,0x60},{0x32,0x66},{0x30,0x6C},{0x2E,0x72},{0x2C,0x78},{0x2A,0x7E},{0x28,0x84},{0x27,0xA0}},
          path2 = {{0x1A,0x90},{0x16,0x88},{0x12,0x80},{0x0E,0x78},{0x0A,0x70},{0x06,0x68},{0x02,0x60},{-2,0x58},{-6,0x50},{-10,0x48},{-16,0x00}},
        }
        npc.frozen = true
      end

      local ta = npc._kantoTravelAnim
      ta.t = ta.t + 1

      -- Phase machine (OverworldController.lua:1373-1406)
      local phase, path, facing
      if ta.t <= 24 then
        phase, path, facing = "flap", nil, "right"
      elseif ta.t <= 60 then  -- 24 + 36
        phase, path, facing = "path1", ta.path1, "right"
        if ta.t == 25 then  -- SFX at path1 entry
          pcall(function()
            local S = require("src.core.Sound")
            local g = type(getGame) == "function" and getGame() or nil
            if g then S.play(g.data, "Fly") end
          end)
        end
      elseif ta.t <= 100 then  -- 60 + 40
        phase, path, facing = "hold", nil, "right"
      elseif ta.t <= 133 then  -- 100 + 33
        phase, path, facing = "path2", ta.path2, "left"
      else
        -- Done
        npc._kantoTravelAnim = nil
        npc.kantoLifeFly = nil
        npc.frozen = false
        if fl.mode == "out" then
          npc._kantoLifeTravelHidden = true
        end
        return true
      end

      ta.phaseName = phase
      ta.facing = facing
      -- Wing flap: step % 2 (exactly like fxBird)
      local step = math.floor(ta.t / 3)
      ta.phase = step % 2

      if path then
        local pair = path[math.min(#path, step + 1)]
        if pair then
          -- Screen-space offset from anchor (fxBird math)
          local sx = pair[2] - ta.anchor[2]
          local sy = pair[1] - ta.anchor[1]
          ta.px = npc.px + sx
          ta.py = npc.py + sy
        end
      else
        -- Flap/hold: stay in place
        ta.px = npc.px
        ta.py = npc.py
      end

      return true  -- Animating
    end

    return false  -- Not animating
  end

  local DIRS = {
    {1,0,"right"}, {-1,0,"left"}, {0,1,"down"}, {0,-1,"up"},
  }

  -- Downhill ledge-hop support. The engine only hops the player, so NPCs get
  -- the follower's proven hop write (targetX/targetY two cells out + hopStep,
  -- animated by NPC:update with span 2). Ledge rows live in
  -- game.data.field.ledges; matching mirrors the engine's own ledge check.
  -- Returns the landing cell for a hop from (cx,cy) facing dir, or nil.
  local function ledgeHopLanding(world, cx, cy, dir)
    local map = world and world.map
    if not map or type(map.cellTile) ~= "function" then return nil end
    local dd = dir == "up" and {0,-1} or dir == "down" and {0,1}
      or dir == "left" and {-1,0} or dir == "right" and {1,0} or nil
    if not dd then return nil end
    local fx, fy = cx + dd[1], cy + dd[2]
    local lx, ly = cx + dd[1] * 2, cy + dd[2] * 2
    local tileset = map.def and map.def.tileset
    local okS, standing = pcall(map.cellTile, map, cx, cy)
    local okF, front = pcall(map.cellTile, map, fx, fy)
    if not okS or not okF then return nil end
    local g = type(getGame) == "function" and getGame() or nil
    local ledges = g and g.data and g.data.field and g.data.field.ledges or {}
    for _, ledge in ipairs(ledges) do
      if (ledge.tileset or "OVERWORLD") == tileset
         and ledge.facing == dir and ledge.input == dir
         and ledge.standingTile == standing and ledge.ledgeTile == front then
        if type(map.inBounds) == "function" then
          local okB, ib = pcall(map.inBounds, map, lx, ly)
          if not okB or not ib then return nil end
        end
        local okW, walk = pcall(map.isWalkableCell, map, lx, ly)
        if okW and walk then
          local clear = true
          if world.player and world.player.cellX == lx and world.player.cellY == ly then clear = false end
          if clear then
            for _, n in ipairs(world.npcs or {}) do
              if n.passable ~= true and ((n.cellX == lx and n.cellY == ly) or (n.cellX == fx and n.cellY == fy)) then
                clear = false; break
              end
            end
          end
          if clear then return lx, ly end
        end
        return nil
      end
    end
    return nil
  end

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

  hash = function(npc)
    local s = actorKey(npc)
    if s == "" then s = tostring(npc and npc.def and npc.def.name or "") end
    if s == "" then s = tostring(npc and npc.cellX or 0) .. ":" .. tostring(npc and npc.cellY or 0) end
    local h = 0
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 10000 end
    return h % 100
  end

  local function isKantoSpawn(npc)
    if not npc or npc.isPlayer or npc.role == "player" then return false end
    local d = npc.def or {}
    return npc.kantoLifeAmbient == true or npc.kantoLifePokeAmbient == true
      or d.kantoLifeAmbient == true or d.kantoLifePokeAmbient == true
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
    if not isKantoSpawn(npc) then return false end
    -- RESEARCH FIX: Don't exclude frozen NPCs (they're just talking).
    -- The update loop skips stepping for frozen NPCs, preserving routine state.
    if npc.hidden or npc.nightlifeSleeping or npc.dsShelter
       or npc.kantoLifeSleeping or npc.johtoLifeSleeping or npc.sleeping then return false end
    if npc._kantoServiceTraffic then return false end
    if npc.kantoLifeWaterBound or (npc.def and npc.def.kantoLifeWaterBound) then return false end
    return true
  end

  local function anchor(npc)
    if npc._kantoRoutineAnchorX == nil or npc._kantoRoutineAnchorY == nil then
      local d = npc.def or {}
      npc._kantoRoutineAnchorX = tonumber(d.x) or tonumber(npc.cellX) or 0
      npc._kantoRoutineAnchorY = tonumber(d.y) or tonumber(npc.cellY) or 0
    end
    return npc._kantoRoutineAnchorX, npc._kantoRoutineAnchorY
  end

  -- Gen1Recomp's public npc() accepts an object name or object index. Spawned
  -- Kanto Life actors have a stable generated name, so name is the primary
  -- lookup. Index is retained as a fallback for mapped actors.
  local function handle(world, npc)
    if not world or not world.map or not mod or not mod.world or not npc then return nil end
    local map = world.map
    if handlesMap ~= map.id then handles = {}; handlesMap = map.id end
    local keyId = tostring(npc.id or "")
    local d = npc.def or {}
    local keys = {}
    -- Runtime Kanto Life actors always have a stable generated name.  This is
    -- the safest cross-generation lookup because Gold's facade resolves
    -- runtime objects by def.name as well as mapped indices.
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
          local destId = tostring(dest)
          -- Real connections carry an offset (in blocks) aligning the strip;
          -- the map center is usually a wall. Seed the scan at the offset
          -- position and walk outward along the edge for a walkable cell.
          local off = 0
          if type(conn) == "table" then off = tonumber(conn.offset) or 0 end
          local horizontal = dir == "north" or dir == "south"
          local span = horizontal and mw or mh
          local seed = math.floor((span - 1) / 2) - off * 2
          local x, y
          for step = 0, math.max(0, span - 1) do
            local i
            if step == 0 then i = seed
            else i = seed + (step % 2 == 1 and math.ceil(step / 2) or -math.ceil(step / 2)) end
            if i >= 0 and i < span then
              local cx, cy
              if dir == "north" then cx, cy = i, 0
              elseif dir == "south" then cx, cy = i, mh - 1
              elseif dir == "west" then cx, cy = 0, i
              elseif dir == "east" then cx, cy = mw - 1, i end
              if cx and cy then
                local ok, walk = pcall(map.isWalkableCell, map, cx, cy)
                if ok and walk then x, y = cx, cy; break end
              end
            end
          end
          -- 4-element entries only: positional slots 5/6 must stay coordinates
          -- (a table there crashed the controller via string concatenation).
          if x and y then out[#out + 1] = {x, y, "route", destId} end
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
    if npc._kantoRoutineOrigWanders ~= nil then
      npc.wanders = npc._kantoRoutineOrigWanders
      npc._kantoRoutineOrigWanders = nil
    end
    if npc._kantoRoutineOrigSteps ~= nil then
      npc.steps = npc._kantoRoutineOrigSteps
      npc._kantoRoutineOrigSteps = nil
    end
    npc._kantoRoutineTraveling = nil
    npc._kantoRoutineTargetX = nil
    npc._kantoRoutineTargetY = nil
  end

  local function activateNative(npc)
    if npc._kantoRoutineOrigWanders == nil then
      npc._kantoRoutineOrigWanders = npc.wanders
    end
    if npc._kantoRoutineOrigSteps == nil then
      npc._kantoRoutineOrigSteps = npc.steps
    end
    -- Travel actors are driven by this controller. Keep the engine's native
    -- wander flag disabled for controller-owned actors so it cannot compete
    -- with the deterministic local walker below.
    npc.wanders = false
  end

  local function activateLocalWander(npc)
    if npc._kantoRoutineOrigWanders == nil then
      npc._kantoRoutineOrigWanders = npc.wanders
    end
    if npc._kantoRoutineOrigSteps == nil then
      npc._kantoRoutineOrigSteps = npc.steps
    end
    -- Follow the engine/Terrarium model for ordinary ambient wandering: leave
    -- the native WALK state alive. Only actors actively travelling to a door
    -- or route are taken over by the deterministic controller. This prevents
    -- Yellow's NPC:update from being disabled before the custom walker has a
    -- chance to establish a step.
    npc.wanders = true
    npc.steps = true
  end

  local function setState(npc, traveling, exits, world)
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
    st.localTarget = nil
    st.localWait = 0
    st.localRoamRadius = 70  -- 3x area (was 40)
    -- RESEARCH FIX: 30% of local NPCs roam far (map-wide) instead of ±40.
    -- They use wanderTarget() but never despawn at doors.
    -- POKEMON: Always roam map-wide (user: vastly increase Pokemon wander area).
    -- Note: Pokemon need to spawn indoors AND exit — the spawn system
    -- must place them inside buildings, not just outdoors.
    local d2 = npc.def or {}
    local isPoke2 = npc.kantoLifePokeAmbient or d2.kantoLifePokeAmbient
    st.roamFar = isPoke2 or ((not traveling) and (math.random() < 0.3))
    st.blockedTime = 0
    st.blockedCount = 0
    st.travelKind = pickTravelKind(npc, world or lastWorld)
    npc._kantoRoutineTraveling = traveling and true or false
    -- Travel-selected actors use the route/door controller. Everyone else is
    -- intentionally returned to the engine's native wander AI; this is the
    -- important Yellow fix because native NPC:update owns its own timer,
    -- collision, and continuous wandering state.
    if traveling then
      activateNative(npc)
    else
      activateLocalWander(npc)
    end
  end

  -- Optional BFS when the map exposes isWalkableCell. This is only used to
  -- choose a route; movement itself always goes through the public NPC handle.
  local function pathTo(world, npc, tx, ty)
    local map = world and world.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil end
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
            -- Don't path THROUGH doors (unless the door is the target).
            -- Prevents NPCs from blocking doorways.
            local isDoor = false
            if nx ~= tx or ny ~= ty then
              if type(map.warpAtCell) == "function" then
                local wok, wv = pcall(map.warpAtCell, map, nx, ny)
                isDoor = wok and wv ~= nil
              elseif type(map.warpAt) == "function" then
                local wok, wv = pcall(map.warpAt, map, nx, ny)
                isDoor = wok and wv ~= nil
              end
            end
            if not isDoor then
              seen[k] = true
              parent[k] = {x=x, y=y, dir=d[3]}
              qx[#qx+1], qy[#qy+1] = nx, ny
            end
          else
            -- The neighbor may be a ledge tile: the traversable node is the
            -- 2-away landing cell when the hop pattern matches.
            local lx, ly = ledgeHopLanding(world, x, y, d[3])
            if lx then
              local lk = lx..","..ly
              if not seen[lk] and not occupied[lk] then
                seen[lk] = true
                parent[lk] = {x=x, y=y, dir=d[3]}
                qx[#qx+1], qy[#qy+1] = lx, ly
              end
            end
          end
        end
      end
      -- Raised for 3x area: covers ~d=63 in open terrain (was 5000)
      if #qx > 20000 then break end  -- Increased for Pokemon long-range (was 8000)
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

  local function stepToward(world, npc, tx, ty)
    local h = handle(world, npc)
    if not h then return false end
    if npc.moving then return true end
    if type(h.isMoving) == "function" then
      local ok, moving = pcall(h.isMoving, h)
      if ok and moving then return true end
    end

    local bx, by = handlePosition(h, npc)
    local path = pathTo(world, npc, tx, ty)
    local dirs = path and #path > 0 and {path[1]} or directDirs(npc, tx, ty)
    if #dirs == 0 then return npc.cellX == tx and npc.cellY == ty end

    local tried, candidates = {}, {}
    for _, dir in ipairs(dirs) do tried[dir] = true; candidates[#candidates + 1] = dir end
    for _, dir in ipairs(directDirs(npc, tx, ty)) do
      if not tried[dir] then tried[dir] = true; candidates[#candidates + 1] = dir end
    end
    for _, dir in ipairs({"up","down","left","right"}) do
      if not tried[dir] then tried[dir] = true; candidates[#candidates + 1] = dir end
    end

    for _, dir in ipairs(candidates) do
      -- Downhill ledge hop: bypass the engine step API and write the 2-cell
      -- hop directly (NPC:update animates hopStep with span 2). The landing
      -- was already validated by ledgeHopLanding.
      local lx, ly = ledgeHopLanding(world, npc.cellX or 0, npc.cellY or 0, dir)
      if lx then
        npc.targetX, npc.targetY = lx, ly
        npc.goalX, npc.goalY = lx, ly
        npc.hopStep = true
        npc.moving = true
        npc.progress = 0
        npc.facing = dir
        npc.stepDir = dir
        return true
      end
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
        -- stepNow uses the actor's current step timing; set it before the
        -- step, never after. The old post-step 43-frame override made Gen1
        -- appear to take a few steps and then stall.
        
        -- Match Gold's normal walking speed (32). 16 was sprinting.
        npc.stepFrames = 32
        local okStep = pcall(h.stepNow, h, dir)
        if okStep then
          local okMoving, moving = false, false
          if type(h.isMoving) == "function" then okMoving, moving = pcall(h.isMoving, h) end
          if okMoving and moving then return true end
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
    local currentId = tostring(map and map.id or "")
    local routeOnly = isRoute(currentId)
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

  local function replacementSpawnCell(world, door)
    local map = world and world.map
    if not map or not door then return nil end
    local x, y = tonumber(door[1]), tonumber(door[2])
    if not x or not y then return nil end
    local candidates = {}
    -- A routine replacement represents somebody entering from the selected
    -- doorway/route entrance. Never spawn on the warp itself: that is the
    -- transition tile and is what caused doorway ping-pong in Gold/Yellow.
    for _, d in ipairs(DIRS) do
      local nx, ny = x + d[1], y + d[2]
      local isWarp = false
      if type(map.warpAt) == "function" then
        local ok,v=pcall(map.warpAt,map,nx,ny); isWarp=ok and v~=nil
      elseif type(map.warpAtCell) == "function" then
        local ok,v=pcall(map.warpAtCell,map,nx,ny); isWarp=ok and v~=nil
      end
      local walk = true
      if type(map.isWalkableCell) == "function" then
        local ok,v=pcall(map.isWalkableCell,map,nx,ny); walk=ok and v==true
      end
      if walk and not isWarp and not occupied(world,nx,ny,nil) then
        candidates[#candidates+1]={nx,ny}
      end
    end
    if #candidates>0 then return candidates[math.random(#candidates)] end
    if not occupied(world,x,y,nil) then return {x,y} end
    return nil
  end

  local function removeAmbient(world, npc)
    if not npc then return end
    local id = npc.id
    pcall(function() if id then mod.world:removeNpc(id) end end)
    if world and world.npcs then
      for i = #world.npcs, 1, -1 do
        local n = world.npcs[i]
        if n == npc or (id and n and n.id == id) then table.remove(world.npcs, i) end
      end
    end
    if world and world.entities then
      for i = #world.entities, 1, -1 do
        local e = world.entities[i]
        if e == npc or (id and e and e.id == id) then table.remove(world.entities, i) end
      end
    end
    npc.hidden = true; npc.visible = false
  end

  local function spawnReplacement(world, npc, door, exitedDoor) -- exitedDoor[4] is the warp destMap
    if not world or not world.map or not door or not mod or not mod.world then return false end
    local _isExit = exitedDoor and tostring(exitedDoor[4] or "") ~= "" and tostring(exitedDoor[4]):upper() ~= tostring(world.map.id or ""):upper(); if _isExit then removeAmbient(world, npc); local _rd = destinationFor(world, npc, exitedDoor, "door"); if _rd then door = _rd end end; local spawn = replacementSpawnCell(world, door)
    if not spawn then return false end
    local d = npc.def or {}
    local poke = npc.kantoLifePokeAmbient == true or d.kantoLifePokeAmbient == true
    local sprite = d.sprite or (npc.sprite and npc.sprite.def and npc.sprite.def.id)
    if not sprite then return false end
    local serial = tostring(npc.id or d.name or math.random(100000)) .. "_R" .. tostring(math.random(100000))
    local name = "KANTO_ROUTINE_" .. serial
    local def = { name=name, sprite=sprite, x=spawn[1], y=spawn[2], text="",
      movement="WALK", range="ANY_DIR", kantoLifeAmbient=true,
      kantoLifePokeAmbient=poke or nil,
      kantoLifeDisplayName=d.kantoLifeDisplayName or npc.kantoLifeDisplayName,
      kantoLifeGender=d.kantoLifeGender or npc.kantoLifeGender,
      kantoLifeSpecies=d.kantoLifeSpecies or npc.kantoLifeSpecies,
      kantoLifeMon=d.kantoLifeMon or npc.kantoLifeMon,
      kantoLifeAquatic=d.kantoLifeAquatic or npc.kantoLifeAquatic }
    local id, err = mod.world:spawnNpc(world.map.id, def)
    if not id then
      if mod.log and mod.log.warn then mod.log:warn("Kanto routine replacement spawn failed: " .. tostring(err)) end
      return false
    end
    local got = type(id) == "table" and id.id or id
    for _, q in ipairs(world.npcs or {}) do
      if q.id == got or (q.def and q.def.name == name) then
        q._kantoRoutineForce = true
        q._kantoRoutineArrival = true
        q._kantoRoutineArrivalX = spawn[1]
        q._kantoRoutineArrivalY = spawn[2]
        break
      end
    end
    local exitKey = tostring(door[1]) .. ":" .. tostring(door[2])
    for _, q in ipairs(world.npcs or {}) do
      if q.id == got or (q.def and q.def.name == name) then
        q._kantoLifeLastExitDoorKey = exitKey
        break
      end
    end
    npc._kantoLifeLastExitDoorKey = exitKey
    removeAmbient(world, npc)
    return true
  end

  local function localWanderTarget(world, npc)
    local map = world and world.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil end
    local cx, cy = tonumber(npc.cellX) or 0, tonumber(npc.cellY) or 0
    -- Move in a broad local area, but never use the original anchor as a
    -- destination. The next target is selected from the actor's current cell,
    -- so successful movement naturally carries the actor away from spawn.
    -- RESEARCH FIX: Expanded from ±18 to ±40 for far-distance travel
    -- (user requirement: routines should travel far, not small squares)
    -- 3x AREA: ±70 (140x140=19,600 cells vs 80x80=6,400)
    -- User requirement: routines cover 3x as much area
    -- POKEMON: ±200 (400x400=160,000 cells, ~8x human range)
    -- HUMANS: ±200 outdoors/caves, ±70 in buildings (user request)
    -- Note: isIndoor() returns false for caves (they use outdoor tilesets),
    -- so "not indoor" covers both outdoor and caves.
    local d = npc.def or {}
    local isPoke = npc.kantoLifePokeAmbient or d.kantoLifePokeAmbient
    local mapId = map and tostring(map.id or "") or ""
    -- isIndoor is defined in KantoMain; use pcall-safe check
    local indoor = false
    pcall(function()
      -- KantoRoutines doesn't have isIndoor; mirror KantoMain's logic.
      -- Towns/routes/caves/overworld are NOT indoor (large radius).
      -- Buildings (houses, Marts, Centers, etc.) ARE indoor (small radius).
      local id = mapId:upper()
      -- Towns and routes are outdoor
      if id:match("^ROUTE_") or id:match("^TOWN_") then indoor = false; return end
      -- Building indicators (from KantoMain's isIndoor)
      indoor = id:find("HOUSE", 1, true) ~= nil
        or id:find("GATE", 1, true) ~= nil
        or id:find("_1F", 1, true) ~= nil or id:find("_2F", 1, true) ~= nil
        or id:find("_3F", 1, true) ~= nil or id:find("_B1F", 1, true) ~= nil
        or id:find("MART", 1, true) ~= nil or id:find("POKECENTER", 1, true) ~= nil
        or id:find("POKEMON_CENTER", 1, true) ~= nil or id:find("GYM", 1, true) ~= nil
        or id:find("LAB", 1, true) ~= nil or id:find("SILPH", 1, true) ~= nil
        or id:find("DEPT", 1, true) ~= nil or id:find("MUSEUM", 1, true) ~= nil
        or id:find("GAME_CORNER", 1, true) ~= nil or id:find("HOTEL", 1, true) ~= nil
    end)
    local useLargeRadius = isPoke or (not indoor)
    local radiusVal = useLargeRadius and 200 or 70
    local attempts = useLargeRadius and 60 or 40
    for _ = 1, attempts do
      local radius = useLargeRadius and radiusVal or ((st and st.localRoamRadius) or 70)
      local tx = cx + math.random(-radius, radius)
      local ty = cy + math.random(-radius, radius)
      if tx ~= cx or ty ~= cy then
        local ok, walk = pcall(map.isWalkableCell, map, tx, ty)
        local warp = false
        if ok and walk then
          if type(map.warpAtCell) == "function" then
            local wok, wv = pcall(map.warpAtCell, map, tx, ty); warp = wok and wv ~= nil
          elseif type(map.warpAt) == "function" then
            local wok, wv = pcall(map.warpAt, map, tx, ty); warp = wok and wv ~= nil
          end
        end
        if ok and walk and not warp and not occupied(world, tx, ty, npc) then
          return tx, ty
        end
      end
    end
    return nil
  end

  local function refresh(world, force)
    -- pcall: wild mods may modify map structure, breaking destination building.
    local ok, dests = pcall(buildDestinations, world)
    if not ok then
      -- Log the error so we can diagnose Wilds incompatibility
      if mod and mod.log then
        pcall(function() mod.log:warn("Kanto Life routines: buildDestinations failed: %s", tostring(dests)) end)
      end
      destinations = {}
    else
      destinations = dests
    end
    lastWorld = world
    local pct = optionPct()
    local candidates = {}
    for _, npc in ipairs(world.npcs or {}) do
      -- pcall protects against other mods' NPCs with unexpected structures.
      local ok, isEligible = pcall(eligible, npc)
      if ok and isEligible then candidates[#candidates + 1] = npc end
    end
    table.sort(candidates, function(a,b)
      local okA, ha = pcall(hash, a)
      local okB, hb = pcall(hash, b)
      ha, hb = okA and ha or 0, okB and hb or 0
      if ha == hb then
        local okKa, ka = pcall(actorKey, a)
        local okKb, kb = pcall(actorKey, b)
        return (okKa and ka or "") < (okKb and kb or "")
      end
      return ha < hb
    end)
    local indoorNow = isIndoor(tostring(world.map and world.map.id or ""), world.map)
    local desired = indoorNow and #candidates or math.ceil(#candidates * pct / 100)
    if not indoorNow then
      if pct <= 0 then desired = 0 elseif pct >= 100 then desired = #candidates end
    end
    local selected = {}
    for i=1,desired do selected[actorKey(candidates[i])] = true end
    for _, npc in ipairs(candidates) do
      if npc._kantoRoutineForce then
        selected[actorKey(npc)] = true
        npc._kantoRoutineForce = nil
      end
    end
    for _, npc in ipairs(candidates) do
      local traveling = selected[actorKey(npc)] == true
      local st = states[actorKey(npc)]
      if force or not st or st.traveling ~= traveling then
        setState(npc, traveling, destinations, world)
      end
    end
    dirty = false
    travelPct = pct
  end

  local agendaMode = 0
  local agendaStates = setmetatable({}, { __mode = "k" })
  local agendaDoors = {}
  local agendaLastNight = nil

  local function agendaNight(world)
    local tod = world and world.tod
    if world and type(world.timeOfDay) == "function" then
      local ok, v = pcall(world.timeOfDay, world); if ok then tod = v end
    end
    tod = tostring(tod or ""):upper()
    return tod == "NIGHT" or tod == "NITE" or tod == "MIDNIGHT"
  end

  local function agendaDoorsFor(world)
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

  local function agendaTarget(world, npc)
    local map = world and world.map
    if not map then return nil end
    if isIndoor(tostring(map.id or ""), map) then
      local doors = agendaDoorsFor(world)
      local ax, ay = anchor(npc); local best, bd
      for _, d in ipairs(doors) do
        local dd = math.abs(d[1]-ax) + math.abs(d[2]-ay)
        if not bd or dd < bd then best, bd = d, dd end
      end
      return best
    end
    local exits = outdoorExits(world)
    return nearestExit(npc, exits)
  end

  local function agendaEligible(npc)
    return eligible(npc) and (npc.kantoLifeAmbient == true or (npc.def and npc.def.kantoLifeAmbient == true))
  end

  local function agendaUpdate(world, dt, force)
    if not world or not world.map or agendaMode == 0 then
      for npc in pairs(agendaStates) do releaseNative(npc); agendaStates[npc] = nil end
      return
    end
    local night = agendaNight(world)
    if force or agendaLastNight ~= night then
      agendaLastNight = night; agendaDoors = {}
      for npc in pairs(agendaStates) do agendaStates[npc] = nil end
    end
    for _, npc in ipairs(world.npcs or {}) do
      -- pcall: wild mods may add NPCs with unexpected structure.
      local ok, isElig = pcall(agendaEligible, npc)
      if ok and isElig then
        local st = agendaStates[npc]
        if not st then
          local participate = (agendaMode == 2 and night) or ((not night) and (agendaMode >= 1) and hash(npc) < 10)
          if participate then
            local t = agendaTarget(world, npc)
            if t then
              st = {target={t[1],t[2]}, phase="out", wait=0, stuck=0}
              agendaStates[npc] = st
              activateNative(npc)
            end
          end
        end
        if st then
          if npc.cellX == st.target[1] and npc.cellY == st.target[2] then
            st.wait = (st.wait or 0) - (dt or 0)
            if st.wait <= 0 then
              -- No anchor: pick new random destination (user: not anchored to a point)
              local t = agendaTarget(world, npc)
              if t then st.phase = "out"; st.target = {t[1],t[2]}; st.wait = 0
              else st.phase = "out"; st.target = {localWanderTarget(world, npc)}; st.wait = 0 end
            end
          else
            local bx, by = npc.cellX, npc.cellY
            if not npc.moving then stepToward(world, npc, st.target[1], st.target[2]) end
            if bx == npc.cellX and by == npc.cellY then st.stuck = (st.stuck or 0) + 1 else st.stuck = 0 end
            if st.stuck > 45 then st.target = {localWanderTarget(world, npc)}; st.phase = "out"; st.stuck = 0 end
          end
        end
      end
    end
    for npc in pairs(agendaStates) do
      if not agendaEligible(npc) then releaseNative(npc); agendaStates[npc] = nil end
    end
  end

  function api.setEnabled(v)
    enabled = v and true or false
    dirty = true
    if not enabled then
      for key, st in pairs(states) do if st.npc then releaseNative(st.npc) end; states[key] = nil; stateKeys[key] = nil end
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

  function api.preUpdate(world)
    -- This runs BEFORE Gen1Recomp's native NPC:update pass.  It is important
    -- that controller-owned ambient actors are already non-native before the
    -- engine ticks them; changing wanders only after base Overworld:update
    -- still permits one vanilla step per frame.
    if not enabled or not world or not world.npcs then return end
    for _, npc in ipairs(world.npcs or {}) do
      -- pcall: wild mods may add NPCs with unexpected structure.
      local ok, isSpawn = pcall(isKantoSpawn, npc)
      if ok and isSpawn and not npc.nightlifeSleeping
         and npc._kantoRoutineTraveling == true then
        npc.wanders = false
      end
    end
  end

  function api.update(world, dt, force)
    if not world or not world.map or not world.npcs then return end
    -- pcall: protect against wild mod interference breaking the entire update.
    local ok, err = pcall(function()
      agendaUpdate(world, dt or 0, force)
    end)
    if not ok and mod and mod.log then
      mod.log:warn("KantoRoutines agendaUpdate failed: %s", tostring(err))
    end
    if not enabled then return end
    local mapId = tostring(world.map.id or "")
    local pct = optionPct()
    if pct ~= travelPct then dirty = true end
    -- Ambient actors are spawned after the overworld update on some maps.
    -- Detect newly spawned Kanto/Johto Life actors so they are assigned on
    -- the following frame instead of waiting for another map change.
    for _, candidate in ipairs(world.npcs or {}) do
      -- Wrap in pcall: other mods (e.g., Wilds of Kanto Revival) may add NPCs
      -- with unexpected structures that could break eligibility checks.
      local ok, isEligible = pcall(eligible, candidate)
      if ok and isEligible then
        local ok2, key = pcall(actorKey, candidate)
        if ok2 and key and not states[key] then dirty = true; break end
      end
    end
    local mapChanged = lastMap ~= mapId
    if mapChanged then lastMap = mapId; dirty = true end
    if dirty or force then refresh(world, force or mapChanged) end

    for key, st in pairs(states) do
      local npc = st.npc or stateKeys[key]
      -- Update travel animations (teleport/fly) before frozen check.
      -- Animating NPCs have frozen=true but need their animation updated.
      if npc then
        local animating = false
        pcall(function() animating = updateTravelAnimation(npc, dt) end)
        if animating then goto continue end
      end
      -- RESEARCH FIX: Skip frozen NPCs (talking) without deleting state.
      -- They'll resume their routine when unfrozen.
      if npc and npc.frozen then goto continue end
      -- pcall: the NPC may have been removed/modified by another mod.
      local ok, isEligible = pcall(eligible, npc)
      if not npc or not ok or not isEligible then
        if npc then pcall(releaseNative, npc) end
        states[key] = nil; stateKeys[key] = nil; goto continue
      end
      if not st.traveling then
        activateLocalWander(npc)
        st.localWait = math.max(0, (st.localWait or 0) - (dt or 0))
        if npc.moving then goto continue end
        if st.localTarget and npc.cellX == st.localTarget[1] and npc.cellY == st.localTarget[2] then
          st.localTarget = nil
          st.localWait = 0
        end
        if not st.localTarget then
          -- RESEARCH FIX: roamFar NPCs use map-wide wanderTarget()
          local tx, ty
          if st.roamFar then
            local wt = wanderTarget(world, npc)
            if wt then tx, ty = wt[1], wt[2] end
          else
            tx, ty = localWanderTarget(world, npc)
          end
          if tx and ty then st.localTarget = {tx, ty} end
        end
        if st.localTarget and not npc.moving then
          if not stepToward(world, npc, st.localTarget[1], st.localTarget[2]) then          
            st.localTarget = nil
            st.localWait = 0
          end
        end
        goto continue
      end
      activateNative(npc)

      if st.phase == "wander" then
        st.wait = (st.wait or 0) - (dt or 0)
        if not st.wanderTarget then st.wanderTarget = wanderTarget(world, npc) end
        local wt = st.wanderTarget
        if wt and npc.cellX == wt[1] and npc.cellY == wt[2] then st.wanderTarget = nil end
        if st.wait <= 0 then
          -- Fly/teleport/surf NPCs depart in place with a visual effect
          -- instead of walking to a door or route exit.
          -- Fallback: if travelKind was never set (e.g., state from before
          -- the travel feature), pick it now.
          local kind = st.travelKind
          if not kind then
            kind = pickTravelKind(npc, world)
            st.travelKind = kind
          end
          if kind == "fly" or kind == "teleport" or kind == "surf" then
            st.phase = "special_depart"
            st.wait = 1.2
            startDepartEffect(npc, kind)
          else
            st.phase = "outbound"
            st.target = destinationFor(world, npc, nil, st.travelKind)
            st.repath = 0
          end
        elseif st.wanderTarget then
          if not npc.moving then stepToward(world, npc, st.wanderTarget[1], st.wanderTarget[2]) end
        end
        goto continue
      end

      -- Special departure: fly/teleport/surf. The NPC plays its effect in
      -- place, then despawns and a replacement spawns at a random exit.
      if st.phase == "special_depart" then
        st.wait = (st.wait or 0) - (dt or 0)
        if st.wait <= 0 then
          local kind = st.travelKind
          local dest = destinationFor(world, npc, nil, "door")
          if not dest then dest = destinationFor(world, npc, nil, "route") end
          if dest then
            -- Pick a random arrival method for the replacement: door (30%),
            -- route (30%), fly (20%), teleport (20%). The replacement spawns
            -- at the door/route, but shows an arrival effect bubble.
            local arriveRoll = math.random(100)
            local arriveMethod
            if arriveRoll <= 30 then arriveMethod = "door"
            elseif arriveRoll <= 60 then arriveMethod = "route"
            elseif arriveRoll <= 80 then arriveMethod = "fly"
            else arriveMethod = "teleport" end
            -- Mark the replacement with the arrival method for effect hooks.
            local ok = spawnReplacement(world, npc, dest, nil)
            if ok then
              for _, q in ipairs(world.npcs or {}) do
                if q._kantoRoutineArrival then
                  -- Use the randomly chosen arrival method, not the departure kind.
                  startArriveEffect(q, arriveMethod)
                  break
                end
              end
              states[key] = nil; stateKeys[key] = nil; goto continue
            end
          end
          -- Fallback: couldn't spawn, return to wandering.
          st.phase = "wander"; st.wait = 2.0; st.wanderTarget = nil
          npc._kantoLifeDepartMethod = nil
        end
        goto continue
      end

      if not st.target then st.target = destinationFor(world, npc, nil, st.travelKind) end
      local t = st.target
      if not t then goto continue end
      local tx, ty = tonumber(t[5]) or t[1], tonumber(t[6]) or t[2]
      if npc.cellX == tx and npc.cellY == ty then
        local blocked = occupied(world, tx, ty, npc)
        if blocked then
          st.phase = "blocked_return"
          st.blockedDoor = {t[1], t[2], t[3], t[4]}
          local ax, ay = anchor(npc)
          st.target = {ax, ay}
          st.wait = 0
          st.repath = 0
          goto continue
        end
        local old = {t[1], t[2], t[3], t[4]}
        if st.phase == "blocked_return" then
          local replacement = destinationFor(world, npc, st.blockedDoor, st.travelKind)
          if replacement and spawnReplacement(world, npc, replacement, st.blockedDoor) then
            states[key] = nil; stateKeys[key] = nil; goto continue
          end
          st.phase = "wander"; st.wait = 2.0; st.wanderTarget = nil; st.target = nil; st.blockedDoor = nil
          goto continue
        end
        if type(onRoutineExit) == "function" then
          local ok, replaced = pcall(onRoutineExit, npc, world, old)
          if ok and replaced then states[key] = nil; stateKeys[key] = nil; goto continue end
        end
        local replacement = destinationFor(world, npc, old, st.travelKind)
        if replacement and spawnReplacement(world, npc, replacement, old) then
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
              -- Stuck recovery: try teleport to nearby cell first (keeps same NPC).
              -- Falls back to despawn/replacement if teleport fails.
              if teleportUnstick(world, npc) then
                st.phase = "wander"
                st.wait = 1.0
                st.wanderTarget = nil
                st.target = nil
                st.localTarget = nil
              else
                -- Last resort: the NPC leaves by surf/fly. Uses the same paired
                -- primitive as a doorway exit (despawn here, a replacement pops
                -- at another exit), so the population stays stable.
                local replacement = destinationFor(world, npc, st.target, st.travelKind)
                if replacement and spawnReplacement(world, npc, replacement, st.target) then
                  states[key] = nil; stateKeys[key] = nil; goto continue
                end
                st.phase = "wander"
                st.wait = 1.0
                st.wanderTarget = nil
                st.target = nil
              end
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
