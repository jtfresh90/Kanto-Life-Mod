-- Shared lifelike ambient behaviors (ported from experimental/lifelike-features).
-- All features are gated by option keys; callers pass opt() and NPC list helpers.
--
-- Option keys (Gen1/Gen2):
--   exp_greetings, exp_chatter, exp_moods, exp_idle,
--   exp_timeaware, exp_player, exp_companions, exp_ambience
-- Gen3 may pass the same keys or firered_exp_* aliases via opt().
--
-- exp_chatter also drives meetups: idle NPCs 2-6 cells apart walk up to each
-- other and hold a 5-10 second conversation. exp_companions also drives
-- escort stepping: a bonded companion strides beside its walking leader,
-- stepping in the same tick so the pair moves as one.
return function(ctx)
  local opt = ctx.opt or function() return nil end
  local api = {}

  local function enabled(key)
    local v = opt(key)
    if v == nil and type(key) == "string" and key:find("^exp_") then
      v = opt("firered_" .. key)
    end
    return v ~= false and v ~= 0
  end

  local function anyEnabled()
    return enabled("exp_greetings") or enabled("exp_chatter") or enabled("exp_moods")
        or enabled("exp_idle") or enabled("exp_timeaware") or enabled("exp_player")
        or enabled("exp_companions") or enabled("exp_ambience")
  end

  local function nowTime()
    if love and love.timer and love.timer.getTime then return love.timer.getTime() end
    return os.time()
  end

  local function timeOfDay()
    -- Prefer in-game night flag when the caller provides it.
    if ctx.isNight and type(ctx.isNight) == "function" then
      local ok, night = pcall(ctx.isNight)
      if ok and night then return "night" end
    end
    local hour = tonumber(os.date("%H")) or 12
    if hour >= 5 and hour < 12 then return "morning"
    elseif hour >= 12 and hour < 18 then return "afternoon"
    elseif hour >= 18 and hour < 22 then return "evening"
    else return "night" end
  end

  local MOOD_LIST = { "happy", "neutral", "neutral", "grumpy", "sleepy", "excited" }
  -- Bubble tint per mood (RGB). neutral = nil → default white bubble.
  local MOOD_COLORS = {
    happy   = { 1.0, 0.85, 0.35 },
    excited = { 1.0, 0.62, 0.25 },
    grumpy  = { 1.0, 0.38, 0.38 },
    sleepy  = { 0.55, 0.72, 1.0 },
  }
  local function getMood(npc)
    if not enabled("exp_moods") then return "neutral" end
    local t = nowTime()
    local setAt = tonumber(npc._kantoLifeMoodSetAt) or 0
    if not npc._kantoLifeMood or (t - setAt > 1800 + math.random() * 1800) then
      npc._kantoLifeMood = MOOD_LIST[math.random(1, #MOOD_LIST)]
      npc._kantoLifeMoodSetAt = t
    end
    return npc._kantoLifeMood or "neutral"
  end

  -- RGB tint for the NPC's current mood, or nil for the default white bubble.
  local function moodColor(npc)
    return MOOD_COLORS[getMood(npc)]
  end

  local function setBubble(npc, text, hold, color)
    if not npc or not text then return end
    local t = nowTime()
    npc._kantoLifeCollisionBubbleText = text
    npc._kantoLifeCollisionBubbleUntil = t + (hold or 2.0)
    -- Always written (nil clears): a white bubble must not inherit a stale tint.
    npc._kantoLifeBubbleColor = color or nil
  end

  local function hasBubble(npc, t)
    return (tonumber(npc._kantoLifeCollisionBubbleUntil) or 0) > (t or nowTime())
  end

  -- True while an NPC is departing via a travel method (teleport / fly / surf):
  -- the departure-method flag plus the per-gen animation states. Lifelike
  -- features must leave these NPCs alone so the travel follows through
  -- instead of being interrupted (and the departure cue bubble ^^ / ** / ~~
  -- must not be stomped by a greeting or chatter bubble).
  -- Defined before updateAnim/startAnim: they call it.
  local function isDeparting(npc)
    if not npc then return false end
    if npc._kantoLifeDepartMethod or npc._johtoLifeDepartMethod
        or npc._kantoLifeFRDepartMethod then
      return true
    end
    if npc.kantoLifeTeleport or npc.kantoLifeFly then return true end
    if npc._johtoLifeTravelAnim then return true end
    if npc._kantoLifeFRAnimPhase then return true end
    return false
  end

  -- ---- Visible mini-animations (all gens) ----
  -- Uses facing, optional hop/jump, spriteYOffset bounce, and bubbles.
  local FACINGS = { "down", "left", "up", "right" }

  local function setFacing(npc, facing)
    if not npc or not facing then return end
    npc.facing = facing
    npc.direction = facing
    if npc.def then npc.def.facing = facing end
    pcall(function()
      if type(npc.face) == "function" then npc:face(facing) end
    end)
  end

  local function tryHop(npc)
    if not npc then return end
    -- Visual-only hop. NEVER write the engine's movement fields here
    -- (moving / jumping / progress / targetX / targetY). Setting moving=true
    -- without a target corrupts the step state machine: Gen2's Npc:update
    -- assigns cellX = targetX (nil) on step completion and then crashes at
    -- src/world/gen2/Npc.lua:683 doing arithmetic on the nil cellX, and
    -- Gen3's tickMotion crashes the same way on its nil target. The
    -- sine-bounce below (decayed in updateAnim via spriteYOffset) is the
    -- safe cross-generation hop.
    npc._kantoLifeAnimHopT = 0.35
    if npc.spriteYOffset == nil then npc.spriteYOffset = 0 end
  end

  local function startAnim(npc, kind, opts)
    if not npc then return end
    opts = opts or {}
    local t = nowTime()
    -- Don't stomp a short anim mid-play unless forced
    local cur = npc._kantoLifeAnim
    if cur and (cur.untilT or 0) > t and not opts.force then return end
    local dur = opts.duration or 1.0
    npc._kantoLifeAnim = {
      kind = kind,
      t0 = t,
      untilT = t + dur,
      phase = 0,
      targetX = opts.targetX,
      targetY = opts.targetY,
      bubble = opts.bubble,
      partner = opts.partner,
    }
    if opts.bubble then
      -- Emotion kinds tint by mood; dialogue kinds ("chat", "follow_face")
      -- stay default white. An explicit opts.bubbleColor overrides.
      local bc = opts.bubbleColor
      if bc == nil then
        local emotion = kind == "greet" or kind == "notice" or kind == "startle"
            or kind == "happy" or kind == "yawn" or kind == "look_around"
        if emotion then bc = moodColor(npc) end
      end
      setBubble(npc, opts.bubble, math.min(2.5, dur + 0.5), bc or nil)
    end
    -- Brief freeze so the pose reads
    if npc._kantoLifeAnimFrozen == nil then
      npc._kantoLifeAnimFrozen = npc.frozen
    end
    if kind ~= "follow_face" then
      npc.frozen = true
      -- Snap a mid-step NPC into its destination cell before halting it, so
      -- it never strands between cells (same pattern as FireRedRoutines'
      -- talk-hold snap). tonumber-guarded: a nil target leaves it untouched.
      local snapX, snapY = tonumber(npc.targetX), tonumber(npc.targetY)
      if npc.moving and snapX and snapY then
        npc.cellX, npc.cellY = snapX, snapY
        if tonumber(npc.cellX) then npc.px = npc.cellX * 16 end
        if tonumber(npc.cellY) then npc.py = npc.cellY * 16 end
      end
      npc.targetX, npc.targetY = nil, nil
      npc.moving = false
      npc.progress = 0
      npc.stepDir = nil
    end
  end

  local function updateAnim(npc, dt)
    -- Hop bounce runs every frame, independent of anims (it's visual-only).
    -- Gen1/2 consume spriteYOffset; Gen3 event objects consume raiseY, so the
    -- bounce is written to both (harmless where ignored). Skipped while
    -- departing: the travel animation owns the offsets then.
    do
      local hopT = tonumber(npc and npc._kantoLifeAnimHopT) or 0
      if hopT > 0 and npc and not isDeparting(npc) then
        npc._kantoLifeAnimHopT = hopT - dt
        local a = math.max(0, hopT)
        local bounce = -math.sin((1 - a / 0.35) * math.pi) * 4
        npc.spriteYOffset = bounce
        if npc.graphicsId ~= nil or npc.raiseY ~= nil then npc.raiseY = bounce end
        if npc._kantoLifeAnimHopT <= 0 then
          npc._kantoLifeAnimHopT = nil
          npc.spriteYOffset = 0
          if npc.graphicsId ~= nil or npc.raiseY ~= nil then npc.raiseY = 0 end
        end
      end
    end
    local anim = npc and npc._kantoLifeAnim
    if not anim then return end
    local t = nowTime()
    local elapsed = t - (anim.t0 or t)
    local kind = anim.kind

    -- A departure in progress wins over lifelike anims: drop the anim so its
    -- bubbles and facing never stomp the travel cue (^^ / ** / ~~/ !) or fight
    -- the travel animation. Frozen and sprite offsets belong to the travel
    -- now, so leave them untouched.
    if isDeparting(npc) then
      npc._kantoLifeAnim = nil
      npc._kantoLifeAnimFrozen = nil
      npc._kantoLifeAnimHopT = nil
      return
    end

    if kind == "notice" or kind == "greet" then
      -- Face target, hold, small hop at start
      if elapsed < 0.05 then tryHop(npc) end
      if anim.targetX then setFacing(npc, nil) end
      do
        local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
        local tx, ty = anim.targetX, anim.targetY
        if nx and ny and tx and ty then
          local dx, dy = tx - nx, ty - ny
          if math.abs(dx) > math.abs(dy) then
            setFacing(npc, dx > 0 and "right" or "left")
          else
            setFacing(npc, dy > 0 and "down" or "up")
          end
        end
      end
    elseif kind == "look_around" then
      local idx = (math.floor(elapsed * 2) % 4) + 1
      setFacing(npc, FACINGS[idx])
    elseif kind == "startle" then
      if elapsed < 0.1 then tryHop(npc) end
      local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
      if nx and ny and anim.targetX and anim.targetY then
        local dx, dy = anim.targetX - nx, anim.targetY - ny
        if math.abs(dx) > math.abs(dy) then
          setFacing(npc, dx > 0 and "right" or "left")
        else
          setFacing(npc, dy > 0 and "down" or "up")
        end
      end
    elseif kind == "yawn" then
      -- Dip sprite slightly
      npc.spriteYOffset = -math.sin(math.min(1, elapsed / 0.8) * math.pi) * 2
    elseif kind == "chat" then
      local partner = anim.partner
      if partner then
        local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
        local px, py = tonumber(partner.cellX), tonumber(partner.cellY)
        if nx and ny and px and py then
          local dx, dy = px - nx, py - ny
          if math.abs(dx) > math.abs(dy) then
            setFacing(npc, dx > 0 and "right" or "left")
          else
            setFacing(npc, dy > 0 and "down" or "up")
          end
        end
      end
      -- Second line halfway through
      if elapsed > 0.7 and not anim._second and anim.bubble2 then
        anim._second = true
        setBubble(npc, anim.bubble2, 1.5)
      end
    elseif kind == "happy" then
      if math.floor(elapsed * 8) % 2 == 0 then tryHop(npc) end
    end

    if t >= (anim.untilT or 0) then
      npc._kantoLifeAnim = nil
      if npc._kantoLifeAnimFrozen ~= nil then
        npc.frozen = npc._kantoLifeAnimFrozen
        npc._kantoLifeAnimFrozen = nil
      else
        npc.frozen = false
      end
      npc.spriteYOffset = 0
      if npc.graphicsId ~= nil or npc.raiseY ~= nil then npc.raiseY = 0 end
      npc._kantoLifeAnimHopT = nil
    end
  end

  local function isAmbient(npc)
    if type(ctx.isAmbient) == "function" then
      local ok, v = pcall(ctx.isAmbient, npc)
      if ok then return v end
    end
    local d = npc.def or {}
    return npc.kantoLifeAmbient or d.kantoLifeAmbient
        or npc.johtoLifeAmbient or d.johtoLifeAmbient
        or npc.kantoLifePokeAmbient or d.kantoLifePokeAmbient
        or false
  end

  local function isPoke(npc)
    if not npc then return false end
    if type(ctx.isPoke) == "function" then
      local ok, v = pcall(ctx.isPoke, npc)
      if ok and v then return true end
    end
    local d = npc.def or {}
    if npc.kantoLifePokemon or d.kantoLifePokemon then return true end
    if npc.johtoLifePokemon or d.johtoLifePokemon then return true end
    if npc.kantoLifePokeAmbient or d.kantoLifePokeAmbient then return true end
    if npc.johtoLifePokeAmbient or d.johtoLifePokeAmbient then return true end
    if type(npc.johtoLifeMon) == "string" or type(d.johtoLifeMon) == "string" then return true end
    if type(npc.kantoLifeSpecies) == "string" or type(d.kantoLifeSpecies) == "string" then return true end
    local nm = tostring(d.name or npc.id or "")
    if nm:find("JOHTO_POKE_", 1, true) or nm:find("KANTO_POKE_", 1, true) then return true end
    local spr = tostring(d.sprite or npc.sprite or ""):upper()
    if spr:find("POKEMON", 1, true) or spr:find("SPRITE_POKE", 1, true) then return true end
    -- Species-looking sprite ids: SPRITE_PIDGEY, SPRITE_RATTATA, etc.
    if spr:match("^SPRITE_[A-Z0-9_]+$") and not spr:find("YOUNGSTER") and not spr:find("LASS")
        and not spr:find("TRAINER") and not spr:find("HUMAN") then
      local mon = d.johtoLifeMon or d.kantoLifeMon or d.kantoLifeSpecies
      if mon then return true end
    end
    return false
  end

  local function pokeSpeciesName(npc)
    local d = npc and npc.def or {}
    local mon = npc.johtoLifeMon or d.johtoLifeMon
        or npc.kantoLifeSpecies or d.kantoLifeSpecies
        or d.kantoLifeMon or npc.kantoLifeMon
    if type(mon) == "string" and mon ~= "" then
      return mon:gsub("_", " ")
    end
    local spr = tostring(d.sprite or ""):upper()
    local m = spr:match("^SPRITE_(.+)$")
    if m and not m:find("POKE_BALL") then
      return m:gsub("_", " ")
    end
    return "POKeMON"
  end

  local POKE_EMOTES = {
    "!", "?", "...", "~", "*!", "*?", "♪", "!!",
  }
  local function pokeBubble(npc)
    -- 50% species cry-style name, 50% pure emotion (never human English).
    if math.random() < 0.5 then
      return pokeSpeciesName(npc) .. "!"
    end
    return POKE_EMOTES[math.random(1, #POKE_EMOTES)]
  end

  local function isSleeping(npc)
    if type(ctx.isSleeping) == "function" then
      local ok, v = pcall(ctx.isSleeping, npc)
      if ok then return v end
    end
    local d = npc.def or {}
    return npc.nightlifeSleeping or d.kantoLifeSleeping or npc.kantoLifeSleeping or false
  end

  local function faceToward(npc, tx, ty)
    local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
    if not nx or not ny or not tx or not ty then return end
    local dx, dy = tx - nx, ty - ny
    if math.abs(dx) > math.abs(dy) then
      setFacing(npc, dx > 0 and "right" or "left")
    else
      setFacing(npc, dy > 0 and "down" or "up")
    end
  end

  local function manhattan(ax, ay, bx, by)
    return math.abs(ax - bx) + math.abs(ay - by)
  end

  -- ---- Directed stepping (all gens) ----
  -- The engine animates NPC movement from the targetX/targetY + moving fields
  -- (the same protocol KantoRoutines' ledge-hop uses). The per-gen routine
  -- update runs before this tick, so the moving flag serializes us with it:
  -- we only step NPCs that aren't already stepping, and it backs off ours.
  local STEP_DIRS = {
    up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
  }

  local function walkableCell(world, x, y)
    local map = world and world.map
    if map and type(map.isWalkableCell) == "function" then
      local ok, v = pcall(map.isWalkableCell, map, x, y)
      if ok then return v and true or false end
    end
    return true -- fail-open when the engine exposes no collision query
  end

  local function cellBlocked(world, npcs, player, x, y, except)
    if player and player ~= except then
      if tonumber(player.cellX) == x and tonumber(player.cellY) == y then return true end
    end
    for _, n in ipairs(npcs or {}) do
      if n and n ~= except and n.passable ~= true then
        if tonumber(n.cellX) == x and tonumber(n.cellY) == y then return true end
        if n.moving and tonumber(n.targetX) == x and tonumber(n.targetY) == y then return true end
      end
    end
    return false
  end

  -- Issue one smooth engine-animated step. Returns true when the step started.
  local function stepOnce(world, npcs, player, npc, dir)
    if not npc or not dir then return false end
    if npc.moving then return false end
    local d = STEP_DIRS[dir]
    if not d then return false end
    local cx, cy = tonumber(npc.cellX), tonumber(npc.cellY)
    if not cx or not cy then return false end
    local nx, ny = cx + d[1], cy + d[2]
    if not walkableCell(world, nx, ny) then return false end
    if cellBlocked(world, npcs, player, nx, ny, npc) then return false end
    setFacing(npc, dir)
    npc.stepFrames = 32
    npc.stepDir = dir
    npc.targetX, npc.targetY = nx, ny
    npc.moving = true
    npc.progress = 0
    return true
  end

  local function dirToward(fx, fy, tx, ty)
    local dx, dy = tx - fx, ty - fy
    if dx == 0 and dy == 0 then return nil end
    if math.abs(dx) >= math.abs(dy) then
      return dx > 0 and "right" or "left"
    end
    return dy > 0 and "down" or "up"
  end

  -- ---- NPC meetups: walk up to each other, talk 5-10 seconds ----
  -- Approach steps are issued directly (the routine runs before this tick, so
  -- the moving flag serializes us: no fighting, no frozen juggling). The talk
  -- phase uses the tested startAnim("chat") hold, which freezes cleanly.
  local CONVO_LINES = {
    { "So...", "Yeah.", "Anyway.", "Mm-hm." },
    { "Did you hear?", "No way!", "Seriously?", "Wow." },
    { "Nice weather.", "Sure is.", "Love it.", "Me too." },
    { "Busy today?", "A little.", "Same here.", "Ugh." },
    { "How's it going?", "Pretty good!", "Not bad.", "You?" },
    { "Seen any rare Pokémon?", "Not lately.", "Keep looking!", "Will do!" },
  }

  local function meetupAbort(n)
    local mu = n._kantoLifeMeetup
    n._kantoLifeMeetup = nil
    n._kantoLifeEscorting = nil
    if mu then
      local p = mu.partner
      if p and p._kantoLifeMeetup and p._kantoLifeMeetup.partner == n then
        p._kantoLifeMeetup = nil
        p._kantoLifeEscorting = nil
      end
    end
  end

  local function meetupStart(a, b, t)
    local dur = 5 + math.random() * 5 -- 5-10 second conversation
    local lines = CONVO_LINES[math.random(1, #CONVO_LINES)]
    local untilT = t + 25 -- approach timeout; the talk phase ends itself
    a._kantoLifeMeetup = { partner = b, phase = "approach", untilT = untilT,
      nextStep = 0, stalls = 0, lines = lines, dur = dur }
    b._kantoLifeMeetup = { partner = a, phase = "approach", untilT = untilT,
      nextStep = 0, stalls = 0,
      lines = { lines[2], lines[1], lines[4], lines[3] }, dur = dur }
    -- Walking up together can bond them into companions.
    if math.random() < 0.3 then
      a._kantoLifeCompanion = b
      b._kantoLifeCompanion = a
    end
  end

  local function meetupStep(world, npcs, player, alive, n, t)
    local mu = n._kantoLifeMeetup
    if not mu then return end
    local p = mu.partner
    if not p or not alive[p] or isSleeping(n) or isSleeping(p)
        or isDeparting(n) or isDeparting(p)
        or not p._kantoLifeMeetup or p._kantoLifeMeetup.partner ~= n then
      meetupAbort(n)
      n._kantoLifeLastChat = t
      if p then p._kantoLifeLastChat = t end
      return
    end
    if t > mu.untilT then
      meetupAbort(n)
      n._kantoLifeLastChat = t
      if p then p._kantoLifeLastChat = t end
      return
    end
    local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
    local px, py = tonumber(p.cellX), tonumber(p.cellY)
    if not nx or not ny or not px or not py then
      meetupAbort(n)
      n._kantoLifeLastChat = t
      if p then p._kantoLifeLastChat = t end
      return
    end
    if mu.phase == "approach" then
      if manhattan(nx, ny, px, py) <= 1 and not n.moving then
        -- Arrived and settled: hold a 5-10s chat. The anim freezes them
        -- other; we trade four lines across the duration below.
        mu.phase = "talk"
        mu.talkT0 = t
        mu.talkUntil = t + mu.dur
        mu.saidIdx = 0
        startAnim(n, "chat", { duration = mu.dur, partner = p,
          targetX = px, targetY = py, force = true })
        return
      end
      if t >= (mu.nextStep or 0) and not n.moving then
        local dir = dirToward(nx, ny, px, py)
        if dir and stepOnce(world, npcs, player, n, dir) then
          mu.stalls = 0
        else
          mu.stalls = (mu.stalls or 0) + 1
        end
        mu.nextStep = t + 0.35
        if (mu.stalls or 0) >= 8 then
          meetupAbort(n)
          n._kantoLifeLastChat = t
          if p then p._kantoLifeLastChat = t end
        end
      end
    else -- talk phase: trade lines across the 5-10s; anim holds the pose
      local seg = mu.dur / 4
      local idx = math.min(4, math.floor((t - (mu.talkT0 or t)) / seg) + 1)
      if idx ~= mu.saidIdx and mu.lines[idx] then
        mu.saidIdx = idx
        setBubble(n, mu.lines[idx], seg + 0.8)
      end
      if t >= (mu.talkUntil or 0) then
        meetupAbort(n)
        n._kantoLifeLastChat = t
        if p then p._kantoLifeLastChat = t end
      end
    end
  end

  -- ---- Companion escort: stride beside the leader, in step ----
  -- When the bonded leader walks, the companion steps in the same tick to
  -- the free cell beside the leader's destination, so the pair moves as one.
  local function escortTick(world, npcs, player, alive, n, c, t)
    local leader, follower
    local np, cp = isPoke(n), isPoke(c)
    if np and not cp then leader, follower = c, n
    elseif cp and not np then leader, follower = n, c
    elseif n.moving and not c.moving then leader, follower = n, c
    elseif c.moving and not n.moving then leader, follower = c, n
    elseif n.moving then leader, follower = n, c
    else
      n._kantoLifeEscorting = nil
      c._kantoLifeEscorting = nil
      return
    end
    if leader ~= n then return end -- driven once, on the leader's visit
    if not alive[leader] or not alive[follower] then return end
    if isSleeping(leader) or isSleeping(follower) then
      follower._kantoLifeEscorting = nil
      return
    end
    -- A departing NPC follows through with its travel; never stride-step it,
    -- and never treat its departure as a lead to follow.
    if isDeparting(leader) or isDeparting(follower) then
      follower._kantoLifeEscorting = nil
      return
    end
    if follower._kantoLifeMeetup or leader._kantoLifeMeetup then
      follower._kantoLifeEscorting = nil
      return
    end
    local lx, ly = tonumber(leader.cellX), tonumber(leader.cellY)
    local fx, fy = tonumber(follower.cellX), tonumber(follower.cellY)
    if not lx or not ly or not fx or not fy then return end
    local ltx, lty = tonumber(leader.targetX), tonumber(leader.targetY)
    if not (leader.moving and ltx and lty) then
      follower._kantoLifeEscorting = nil
      return
    end
    if follower.moving then return end
    -- Don't yank the companion across the map; stay leashed.
    if manhattan(fx, fy, ltx, lty) > 4 then
      follower._kantoLifeEscorting = nil
      return
    end
    -- Destination: nearest free cell adjacent to the leader's destination,
    -- so the companion keeps its side and strides with the leader.
    local bx, by, bd = nil, nil, nil
    for _, d in pairs(STEP_DIRS) do
      local cx, cy = ltx + d[1], lty + d[2]
      if walkableCell(world, cx, cy)
          and not cellBlocked(world, npcs, player, cx, cy, follower) then
        local dist = manhattan(cx, cy, fx, fy)
        if not bd or dist < bd then bx, by, bd = cx, cy, dist end
      end
    end
    if not bx or (fx == bx and fy == by) then return end
    follower._kantoLifeEscorting = true
    local dir = dirToward(fx, fy, bx, by)
    if dir then stepOnce(world, npcs, player, follower, dir) end
  end

  local GREETINGS = {
    morning = { "Good morning!", "Morning!", "Hi there!", "Hello!", "Hey!" },
    afternoon = { "Hi!", "Hey!", "Hello!", "Howdy!", "Oh, hi!" },
    evening = { "Good evening!", "Evening!", "Hi!", "Hey there!", "Hello!" },
    night = { "Oh, hi.", "Evening...", "*yawn* Hey.", "Hey...", "Still up?" },
  }
  local MOOD_GREETINGS = {
    happy = { "Hey friend!", "Great to see you!", "Hi!!", "Hello!", "What a day!" },
    neutral = { "Hi.", "Hey.", "Hello.", "Oh, hi.", "Hm?" },
    grumpy = { "Hmph.", "...Hi.", "What?", "Yeah?", "..." },
    sleepy = { "*yawn* Hey.", "Oh, hi...", "Mmm...", "Hey..." },
    excited = { "Hey!!!", "You're here!", "Hi hi!", "Oh wow!", "Hello!!" },
  }
  local IDLE_THOUGHTS = {
    morning = { "Nice day.", "Hmm.", "...", "Let's go!", "Coffee..." },
    afternoon = { "Hmm.", "...", "Bored.", "Nice.", "..." },
    evening = { "Getting late.", "Hmm.", "...", "Dinner?", "..." },
    night = { "...", "*yawn*", "Hmm.", "*yawn*", "So sleepy..." },
  }

  local state = {
    lastMapId = nil,
    lastTimeOfDay = nil,
    lastPlayerXY = nil,
    playerStillSince = nil,
    lastYawnAt = 0,
  }

  -- Call when player leaves a map (farewell waves).
  function api.onMapLeave(world, npcs, player)
    if not enabled("exp_greetings") then return end
    if not player then return end
    local px, py = tonumber(player.cellX), tonumber(player.cellY)
    if not px or not py then return end
    local t = nowTime()
    for _, n in ipairs(npcs or {}) do
      if n and isAmbient(n) and not isSleeping(n) and not isPoke(n) then
        local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
        if nx and ny and math.abs(nx - px) + math.abs(ny - py) <= 4 then
          if not hasBubble(n, t) then
            setBubble(n, ({ "Bye!", "See ya!", "Take care!", "Later!", "Goodbye!" })[math.random(1, 5)], 1.5, moodColor(n))
            faceToward(n, px, py)
          end
        end
      end
    end
  end

  -- Call when a traveler ambient arrives.
  function api.onTravelerArrival(npc)
    if not enabled("exp_greetings") or not npc then return end
    if isPoke(npc) then
      setBubble(npc, pokeBubble(npc), 2.0, moodColor(npc))
      return
    end
    local lines = { "Ah, finally!", "Made it!", "What a trip!", "Home at last!", "Tired feet..." }
    setBubble(npc, lines[math.random(1, #lines)], 2.5, moodColor(npc))
  end

  -- Call when an NPC wakes from sleep.
  function api.onWake(npc)
    if not enabled("exp_ambience") or not npc then return end
    if isPoke(npc) then
      setBubble(npc, ({ "*yawn*", "...", "~", pokeSpeciesName(npc) .. "..." })[math.random(1, 4)], 2.0, moodColor(npc))
      return
    end
    setBubble(npc, ({ "*yawn*", "*stretch*", "Ah...", "Morning...", "*yawn* Okay." })[math.random(1, 5)], 2.0, moodColor(npc))
  end

  -- Per-frame / per-tick update. npcs is an array of actor tables.
  function api.tick(world, npcs, player, dt)
    if not anyEnabled() then return end
    if not player then return end
    local px, py = tonumber(player.cellX), tonumber(player.cellY)
    if not px or not py then return end
    local t = nowTime()
    local tod = timeOfDay()
    dt = tonumber(dt) or 0.016
    npcs = npcs or {}

    -- Liveness set: NPCs present on this map this tick. Meetup partners and
    -- escort leaders are validated against it so stale refs abort cleanly.
    local alive = {}
    for _, an in ipairs(npcs) do if an then alive[an] = true end end

    -- Map change → double-take
    local mapId = world and world.map and tostring(world.map.id or "")
    if enabled("exp_player") and mapId and mapId ~= "" and mapId ~= state.lastMapId then
      if state.lastMapId ~= nil then
        for _, n in ipairs(npcs) do
          if n and isAmbient(n) and not isSleeping(n) and not isDeparting(n) then
            local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
            if nx and ny and math.abs(nx - px) + math.abs(ny - py) <= 5 then
              if math.random() < 0.5 then
                local text = isPoke(n) and pokeBubble(n)
                    or ({ "Oh!", "Huh?", "Hm?", "You!", "!" })[math.random(1, 5)]
                startAnim(n, "notice", { duration = 1.0, targetX = px, targetY = py, bubble = text })
              end
            end
          end
        end
      end
      state.lastMapId = mapId
    end

    -- Time-of-day transition comments
    if enabled("exp_timeaware") and state.lastTimeOfDay and state.lastTimeOfDay ~= tod then
      local comments = {
        morning = { "Morning already?", "Rise and shine!", "A new day!" },
        afternoon = { "Afternoon already.", "Time flies.", "Midday..." },
        evening = { "Evening's here.", "Getting dark.", "Sunset..." },
        night = { "Night time.", "So late...", "*yawn*" },
      }
      local pool = comments[tod] or comments.afternoon
      for _, n in ipairs(npcs) do
        if n and isAmbient(n) and not isSleeping(n) and not isDeparting(n) and not isPoke(n) and math.random() < 0.25 then
          if not hasBubble(n, t) then
            setBubble(n, pool[math.random(1, #pool)], 2.0, moodColor(n))
          end
        end
      end
    end
    state.lastTimeOfDay = tod

    -- Player stillness tracking
    local moved = true
    if state.lastPlayerXY then
      moved = state.lastPlayerXY[1] ~= px or state.lastPlayerXY[2] ~= py
    end
    state.lastPlayerXY = { px, py }
    if moved then
      state.playerStillSince = t
    elseif not state.playerStillSince then
      state.playerStillSince = t
    end
    local stillFor = t - (state.playerStillSince or t)
    local playerIdleLong = stillFor >= 30
    local playerSprinting = false
    pcall(function()
      if player.running or player.isRunning or player.sprint then playerSprinting = true end
    end)

    local greetPool = GREETINGS[tod] or GREETINGS.afternoon
    local idlePool = IDLE_THOUGHTS[tod] or IDLE_THOUGHTS.afternoon

    -- Advance any playing mini-animations first
    for _, n in ipairs(npcs) do
      if n then pcall(updateAnim, n, dt) end
    end

    -- Per-NPC pass
    for _, n in ipairs(npcs) do
      if not n or isSleeping(n) or isDeparting(n) then goto continue end
      if not isAmbient(n) then goto continue end
      local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
      if not nx or not ny then goto continue end
      local dist = math.abs(nx - px) + math.abs(ny - py)
      local poke = isPoke(n)

      -- Skip starting a new anim if one is already playing
      if n._kantoLifeAnim and (n._kantoLifeAnim.untilT or 0) > t then goto continue end

      -- NPCs driven by meetup/escort stepping keep their stride; idle anims
      -- must not stomp their movement.
      if n._kantoLifeMeetup or n._kantoLifeEscorting then goto continue end

      -- Proximity greetings with face + hop
      if enabled("exp_greetings") and dist > 0 and dist <= 3 then
        local last = tonumber(n._kantoLifeLastGreet) or 0
        if t - last > 14 then
          n._kantoLifeLastGreet = t
          local text
          if poke then
            text = pokeBubble(n)
          else
            if enabled("exp_moods") and math.random() < 0.6 then
              local pool = MOOD_GREETINGS[getMood(n)]
              text = pool and pool[math.random(1, #pool)]
            end
            text = text or greetPool[math.random(1, #greetPool)]
          end
          startAnim(n, "greet", { duration = 1.1, targetX = px, targetY = py, bubble = text })
        end
      end

      -- Face / notice the player
      if enabled("exp_player") and dist > 0 and dist <= 4 then
        if not n.moving and not n.scriptBusy and math.random() < 0.06 then
          local text
          if poke then text = pokeBubble(n)
          else text = ({ "Oh.", "Hm?", "Hey.", "..." })[math.random(1, 4)] end
          startAnim(n, "notice", { duration = 0.9, targetX = px, targetY = py, bubble = text })
        end
      end

      -- Idle curiosity when player stands still
      if enabled("exp_player") and playerIdleLong and dist > 0 and dist <= 5 then
        if math.random() < 0.05 then
          startAnim(n, "notice", { duration = 1.0, targetX = px, targetY = py, bubble = "?" })
        end
      end

      -- Startled by sprint: hop + !
      if enabled("exp_player") and playerSprinting and dist > 0 and dist <= 2 then
        if math.random() < 0.2 then
          local text = poke and ({ "!", "!!", "*!" })[math.random(1, 3)]
              or ({ "Whoa!", "Hey!", "Watch it!", "!" })[math.random(1, 4)]
          startAnim(n, "startle", { duration = 0.8, targetX = px, targetY = py, bubble = text })
        end
      end

      -- Idle: look around, hum, yawn, sneeze
      if (enabled("exp_idle") or enabled("exp_ambience")) and not n.moving then
        if math.random() < 0.03 then
          local roll = math.random()
          if enabled("exp_ambience") and roll < 0.2 then
            startAnim(n, "yawn", { duration = 1.2, bubble = "*yawn*" })
            state.lastYawnAt = t
            n._kantoLifeJustYawned = t
          elseif enabled("exp_ambience") and roll < 0.3 and not poke then
            startAnim(n, "startle", { duration = 0.7, bubble = "*achoo!*", targetX = px, targetY = py })
            n._kantoLifeJustSneezed = t
          elseif enabled("exp_idle") and roll < 0.55 then
            local text = poke and pokeBubble(n)
                or (tod ~= "night" and ({ "♪", "♪♪", "Hmm ♪" })[math.random(1, 3)])
                or idlePool[math.random(1, #idlePool)]
            startAnim(n, "look_around", { duration = 1.4, bubble = text })
          end
        end
      end

      -- Contagious yawn
      if enabled("exp_ambience") and not poke then
        local yawned = tonumber(n._kantoLifeJustYawned) or 0
        if t - state.lastYawnAt < 3 and t - yawned > 5 and dist <= 3 and math.random() < 0.15 then
          startAnim(n, "yawn", { duration = 1.1, bubble = "*yawn*" })
          n._kantoLifeJustYawned = t
        end
      end

      -- Bless you after sneeze
      if enabled("exp_ambience") and not poke then
        for _, other in ipairs(npcs) do
          if other and other ~= n and (tonumber(other._kantoLifeJustSneezed) or 0) > t - 2 then
            local ox, oy = tonumber(other.cellX), tonumber(other.cellY)
            if ox and oy and math.abs(ox - nx) + math.abs(oy - ny) <= 2 then
              if not hasBubble(n, t) and math.random() < 0.5 then
                setBubble(n, "Bless you!", 1.5, moodColor(n))
              end
            end
          end
        end
      end

      -- Pokémon adoration
      if enabled("exp_companions") and not poke then
        for _, other in ipairs(npcs) do
          if other and isPoke(other) then
            local ox, oy = tonumber(other.cellX), tonumber(other.cellY)
            if ox and oy and math.abs(ox - nx) + math.abs(oy - ny) <= 2 then
              if math.random() < 0.04 then
                startAnim(n, "happy", {
                  duration = 1.0,
                  bubble = ({ "Cute!", "Aww!", "So cool!", "Wow!", "Hi there!" })[math.random(1, 5)],
                  targetX = ox, targetY = oy,
                })
              end
            end
          end
        end
      end

      ::continue::
    end

    -- NPC-to-NPC chatter: quick exchanges up close, plus meetups where NPCs
    -- walk up to each other and hold a 5-10 second conversation.
    if enabled("exp_chatter") then
      -- Advance in-progress meetups first.
      for _, n in ipairs(npcs) do
        if n and n._kantoLifeMeetup then
          pcall(meetupStep, world, npcs, player, alive, n, t)
        end
      end
      -- Pair up new meetups: idle NPCs 2-6 cells apart walk to each other.
      for i = 1, #npcs do
        local a = npcs[i]
        if not a or isSleeping(a) or isPoke(a) or not isAmbient(a) then goto meet_a end
        if a.moving or a._kantoLifeMeetup or a._kantoLifeEscorting then goto meet_a end
        if isDeparting(a) then goto meet_a end
        if hasBubble(a, t) then goto meet_a end
        local ax, ay = tonumber(a.cellX), tonumber(a.cellY)
        if not ax or not ay then goto meet_a end
        if t - (tonumber(a._kantoLifeLastChat) or 0) < 30 then goto meet_a end
        for j = i + 1, #npcs do
          local b = npcs[j]
          if not b or isSleeping(b) or isPoke(b) or not isAmbient(b) then goto meet_b end
          if b.moving or b._kantoLifeMeetup or b._kantoLifeEscorting then goto meet_b end
          if isDeparting(b) then goto meet_b end
          if hasBubble(b, t) then goto meet_b end
          local bx, by = tonumber(b.cellX), tonumber(b.cellY)
          if not bx or not by then goto meet_b end
          if t - (tonumber(b._kantoLifeLastChat) or 0) < 30 then goto meet_b end
          local d = manhattan(ax, ay, bx, by)
          if d >= 2 and d <= 6 and math.random() < 0.05 then
            pcall(meetupStart, a, b, t)
            break
          end
          ::meet_b::
        end
        ::meet_a::
      end
      -- Quick chats for NPCs already standing close (existing behavior).
      for i = 1, #npcs do
        local a = npcs[i]
        if not a or isSleeping(a) or isPoke(a) or not isAmbient(a) then goto next_a end
        if a.moving or hasBubble(a, t) or isDeparting(a) then goto next_a end
        if a._kantoLifeMeetup or a._kantoLifeEscorting then goto next_a end
        local ax, ay = tonumber(a.cellX), tonumber(a.cellY)
        if not ax then goto next_a end
        local lastChat = tonumber(a._kantoLifeLastChat) or 0
        if t - lastChat < 20 then goto next_a end
        for j = i + 1, #npcs do
          local b = npcs[j]
          if not b or isSleeping(b) or isPoke(b) or not isAmbient(b) then goto next_b end
          if b.moving or hasBubble(b, t) or isDeparting(b) then goto next_b end
          if b._kantoLifeMeetup or b._kantoLifeEscorting then goto next_b end
          local bx, by = tonumber(b.cellX), tonumber(b.cellY)
          if not bx then goto next_b end
          if math.abs(ax - bx) + math.abs(ay - by) <= 2 and math.random() < 0.05 then
            local lines = {
              { "So...", "Yeah." },
              { "Did you hear?", "No way!" },
              { "Nice weather.", "Sure is." },
              { "Busy today?", "A little." },
              { "Hello!", "Hi!" },
              { "Anyway...", "Mm-hm." },
            }
            local pair = lines[math.random(1, #lines)]
            startAnim(a, "chat", { duration = 1.8, partner = b, bubble = pair[1], targetX = bx, targetY = by })
            -- second speaker slightly delayed
            startAnim(b, "chat", { duration = 1.8, partner = a, bubble = pair[2], targetX = ax, targetY = ay })
            a._kantoLifeLastChat = t
            b._kantoLifeLastChat = t
            if enabled("exp_companions") and math.random() < 0.3 then
              a._kantoLifeCompanion = b
              b._kantoLifeCompanion = a
            end
            break
          end
          ::next_b::
        end
        ::next_a::
      end
    end

    -- Companion bond: face each other; pet Pokemon try to stay near their human.
    if enabled("exp_companions") then
      for _, n in ipairs(npcs) do
        if not n or isSleeping(n) or isDeparting(n) then goto comp_next end
        local c = n._kantoLifeCompanion or n.kantoLifePetCompanion
        if not c then
          -- Resolve owner link from companionOf name (Gen2 spawn tag).
          local ownerName = n.johtoLifeCompanionOf or (n.def and n.def.johtoLifeCompanionOf)
          if ownerName then
            for _, o in ipairs(npcs) do
              local on = o and o.def and o.def.name
              if on == ownerName then
                c = o
                n._kantoLifeCompanion = o
                o._kantoLifeCompanion = n
                o.kantoLifePetCompanion = n
                break
              end
            end
          end
        end
        if c and not isSleeping(c) and not isDeparting(c) then
          local cx, cy = tonumber(c.cellX), tonumber(c.cellY)
          local nx, ny = tonumber(n.cellX), tonumber(n.cellY)
          if cx and nx then
            local d = math.abs(cx - nx) + math.abs(cy - ny)
            if d <= 5 then
              if math.random() < 0.08 then faceToward(n, cx, cy) end
            end
            -- Pokemon companion: soft-follow owner by nudging facing/home toward them.
            if isPoke(n) and d >= 2 and d <= 6 and not n.moving and math.random() < 0.2 then
              faceToward(n, cx, cy)
              n.homeX, n.homeY = cx, cy
              if n.def then n.def.homeX, n.def.homeY = cx, cy end
            end
            -- Escort: stride beside the walking leader, in step, same tick.
            if alive[c] and not n._kantoLifeMeetup and not c._kantoLifeMeetup then
              pcall(escortTick, world, npcs, player, alive, n, c, t)
            end
          end
        end
        ::comp_next::
      end
    end
  end

  return api
end
