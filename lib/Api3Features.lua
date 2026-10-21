-- Kanto Life API 3 features (branch api3-features, prototype -- NOT a release)
--
-- One additive layer on top of the existing per-generation installers,
-- built only on the portable API 3 surfaces (engine 0.3.93+):
--
--   P1  Official emote bubbles: world.trainer_engaged -> queueScript emote
--   P2  NPC handles: spawnNpc / npc() handle, canStep-guarded stepNow,
--       setAppearance travel sprite swaps
--   P3  Portable queueScript interaction events (heal / gift / giftmon /
--       mart / wild) driven off world.interacted with the companion
--   P4  Companion follower: world.follower.spawn hook (all gens) +
--       liveMaps presence journal (Gen 1/2)
--   P5  Battle-aware journal: battle.started/ended + mod.battle snapshot,
--       trainer.party observer, shiny.roll (Gen 2/3) for Api3 wild events
--   P6  KANTO_LIFE_API3 screen via content.screens + mod.ui (Gen 3 bridge),
--       opened from a ui.start_menu.items row
--   P7  Gossip network: notable battle moments become "news" entries the
--       companion and market-goers share when talked to
--   P8  Market days: on a rotating entry cadence, runtime NPCs gather on
--       the map (spawnNpc + handles + emotes), then disperse on exit
--   P9  Lost Pokemon reunions: a lone spawned Pokemon NPC follows the
--       player (follower machinery) to its trainer on the next map;
--       reunion scene + thank-you gift via queueScript
--   P10 Shiny fame: shiny sightings make the companion react with an
--       emote, become gossip, and draw a "shiny hunter" NPC in the
--       next town
--
-- Design rules (same as the rest of the mod):
--   * Fail-open everywhere: every engine call is pcall-wrapped; a failure
--     logs once and disables that sub-feature, never the whole mod.
--   * Nothing here replaces a working per-gen system. The layer only adds.
--   * No movement is ever written without the handle's canStep check.
--   * State lives in mod.save buckets "api3cfg" / "api3journal" so it is
--     per-playthrough and survives relaunches.
--
-- The installer returns a table (also stored on mod._kantoApi3) so tests
-- and future per-gen code can call the builders/handlers directly.

return function(mod, gen)
  local Api3 = { installed = false, gen = gen, features = {} }

  local unpackFn = table.unpack or unpack
  local function logInfo(fmt, ...)
    local a = { ... }
    pcall(function()
      if mod.log and type(mod.log.info) == "function" then mod.log:info(fmt, unpackFn(a)) end
    end)
  end
  local function logWarn(fmt, ...)
    local a = { ... }
    pcall(function()
      if mod.log and type(mod.log.warn) == "function" then mod.log:warn(fmt, unpackFn(a)) end
    end)
  end

  -- ------------------------------------------------------------------
  -- API 3 detection + capability query
  -- ------------------------------------------------------------------
  local function supports(surface, name)
    if type(mod.supports) ~= "function" then return false, "mod:supports unavailable (api < 3)" end
    local ok, a, b = pcall(function() return mod:supports(surface, name) end)
    if not ok then return false, tostring(a) end
    return a == true, b
  end
  Api3.supports = supports

  if type(mod.supports) ~= "function" then
    Api3.reason = "api < 3: unified facades not present, layer inert"
    logInfo("Kanto Life API3 layer inert: %s", Api3.reason)
    mod._kantoApi3 = Api3
    return Api3
  end

  -- ------------------------------------------------------------------
  -- Persistent config + journal (mod.save buckets)
  -- ------------------------------------------------------------------
  local function saveGet(key)
    if not (mod.save and type(mod.save.get) == "function") then return nil end
    local ok, v = pcall(function() return mod.save:get(key) end)
    if ok then return v end
    return nil
  end
  local function saveSet(key, value)
    if not (mod.save and type(mod.save.set) == "function") then return end
    pcall(function() mod.save:set(key, value) end)
  end

  local cfg = saveGet("api3cfg")
  if type(cfg) ~= "table" then cfg = {} end
  if cfg.emote == nil then cfg.emote = true end          -- P1
  if cfg.companion == nil then cfg.companion = true end  -- P4 (implies P2/P3 surfaces)
  if cfg.events == nil then cfg.events = true end        -- P3
  if cfg.battle == nil then cfg.battle = true end        -- P5
  if cfg.shiny == nil then cfg.shiny = true end          -- P5 shiny rolls for Api3 wild events
  if cfg.gossip == nil then cfg.gossip = true end        -- P7
  if cfg.market == nil then cfg.market = true end        -- P8
  if cfg.lost == nil then cfg.lost = true end            -- P9
  if cfg.fame == nil then cfg.fame = true end            -- P10
  Api3.cfg = cfg
  local function persistCfg() saveSet("api3cfg", cfg) end
  persistCfg()

  local journal = saveGet("api3journal")
  if type(journal) ~= "table" then journal = {} end
  journal.battlesSeen = journal.battlesSeen or 0
  journal.trainerPartiesSeen = journal.trainerPartiesSeen or 0
  Api3.journal = journal
  local function persistJournal() saveSet("api3journal", journal) end

  -- P7 -- gossip news store. Kept as an array of plain strings plus a
  -- delivered-count in the journal bucket (save-safe shapes only: the
  -- engine's per-playthrough buckets are not asked to serialise nested
  -- record tables). Newest last; capped at 8, oldest dropped first and
  -- the delivered count adjusted so unread items stay unread.
  local function addNews(text)
    if not cfg.gossip then return false end
    if type(text) ~= "string" or text == "" then return false end
    journal.news = type(journal.news) == "table" and journal.news or {}
    for _, n in ipairs(journal.news) do if n == text then return false end end
    journal.news[#journal.news + 1] = text
    journal.newsSeen = tonumber(journal.newsSeen) or 0
    while #journal.news > 8 do
      table.remove(journal.news, 1)
      journal.newsSeen = math.max(0, journal.newsSeen - 1)
    end
    persistJournal()
    return true
  end
  Api3._addNews = addNews
  local function unreadNews()
    if type(journal.news) ~= "table" then return nil end
    local idx = (tonumber(journal.newsSeen) or 0) + 1
    return journal.news[idx], idx
  end
  Api3._unreadNews = unreadNews

  local function nowSeconds()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then return t end
    return 0
  end

  -- Private mod flags (API 3: "mod:<key>" flags live in the mod's own
  -- save bucket on every generation).
  local function setFlag(key, value)
    if not (mod.world and type(mod.world.setFlag) == "function") then return nil, "setFlag unavailable" end
    local ok, a, b = pcall(function() return mod.world:setFlag("mod:" .. key, value) end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.setFlag = setFlag

  -- ------------------------------------------------------------------
  -- P1 -- official emote bubbles on trainer engage
  -- ------------------------------------------------------------------
  -- queueScript rows are validated whole-list by the engine; a bad target
  -- refuses the list with nil, reason and nothing runs. We try the parsed
  -- object index first, then the full object id string.
  local function emoteTargets(ev)
    local out = {}
    local npc = type(ev) == "table" and ev.npc or nil
    if type(npc) == "number" or type(npc) == "string" then out[#out + 1] = npc end
    if type(npc) == "table" then
      if type(npc.index) == "number" then out[#out + 1] = npc.index end
      if type(npc.localId) == "number" then out[#out + 1] = npc.localId end
      if type(npc.id) == "string" then
        local idx = npc.id:match("_obj_(%d+)$")
        if idx then out[#out + 1] = tonumber(idx) end
        out[#out + 1] = npc.id
      end
    end
    if type(ev) == "table" and type(ev.npcId) ~= "nil" then out[#out + 1] = ev.npcId end
    return out
  end
  Api3._emoteTargets = emoteTargets

  local function queueEmote(ev, bubble)
    if not (mod.world and type(mod.world.queueScript) == "function") then
      return nil, "queueScript unavailable"
    end
    bubble = bubble or "shock"
    local lastErr
    for _, target in ipairs(emoteTargets(ev)) do
      local rows = { { "emote", target, bubble, 60 } }
      local ok, a, b = pcall(function()
        return mod.world:queueScript(rows, { onDone = function(doneOk, reason)
          if not doneOk then logWarn("Kanto Life API3 emote script failed: %s", tostring(reason)) end
        end })
      end)
      if ok and a then return true end
      lastErr = ok and b or a
    end
    return nil, lastErr or "no emote target resolved"
  end
  Api3.queueEmote = queueEmote

  -- ------------------------------------------------------------------
  -- P2 -- NPC handle layer
  -- ------------------------------------------------------------------
  local function npcHandle(mapId, id)
    if not (mod.world and type(mod.world.npc) == "function") then return nil, "world.npc unavailable" end
    local ok, a, b = pcall(function() return mod.world:npc(mapId, id) end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.npcHandle = npcHandle

  -- The ONLY movement writer in this layer: ask the map first (canStep),
  -- then stepNow. Never writes movement state directly.
  local function stepHandle(handle, dir)
    if type(handle) ~= "table" then return nil, "no handle" end
    local canOk, can = pcall(function() return handle:canStep(dir) end)
    if not canOk or not can then return nil, "canStep refused " .. tostring(dir) end
    local ok, a, b = pcall(function() return handle:stepNow(dir) end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.stepHandle = stepHandle

  local function faceHandle(handle, dir)
    if type(handle) ~= "table" or type(handle.face) ~= "function" then return nil, "face unavailable" end
    local ok, a, b = pcall(function() return handle:face(dir) end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.faceHandle = faceHandle

  -- Travel departure sprite swap (teleport -> Psychic mon sprite,
  -- fly -> Fly-capable mon sprite) through the official handle method.
  local function swapAppearance(handle, spriteId)
    if type(handle) ~= "table" or type(handle.setAppearance) ~= "function" then
      return nil, "setAppearance unavailable on this handle"
    end
    local ok, a, b = pcall(function() return handle:setAppearance(spriteId) end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.swapAppearance = swapAppearance

  local function placeHandle(handle, x, y, facing)
    if type(handle) ~= "table" or type(handle.placeAt) ~= "function" then return nil, "placeAt unavailable" end
    local ok, a, b = pcall(function() return handle:placeAt(x, y, facing) end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.placeHandle = placeHandle

  local function handlePosition(handle)
    if type(handle) ~= "table" or type(handle.position) ~= "function" then return nil end
    local ok, x, y = pcall(function() return handle:position() end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
    return nil
  end
  Api3.handlePosition = handlePosition

  -- ------------------------------------------------------------------
  -- P3 -- portable interaction-event scripts (pure builders + runner)
  -- ------------------------------------------------------------------
  -- open_mart note (verified against the wiki Reference: Commands):
  -- open_mart takes the TEXT constant of a native mart script; there is
  -- no generic "any mart" form. Api3.setMartConst(mapId, const) records
  -- a known const per map; the mart event uses it when present and
  -- degrades to the gift event (with a log line) when it is not.
  local martConsts = saveGet("api3marts")
  if type(martConsts) ~= "table" then martConsts = {} end
  function Api3.setMartConst(mapId, const)
    martConsts[mapId] = const
    saveSet("api3marts", martConsts)
  end

  local GIFT_ITEMS = { "POTION", "ANTIDOTE", "REPEL", "POKE_BALL", "ESCAPE_ROPE" }
  local GIFT_MON = { "PIDGEY", "RATTATA", "CATERPIE", "WEEDLE", "SPEAROW", "EKANS", "SANDSHREW", "ZUBAT", "GEODUDE", "MAGIKARP" }
  local WILD_MON = { "PIDGEY", "RATTATA", "CATERPIE", "WEEDLE", "SPEAROW", "EKANS", "SANDSHREW", "ZUBAT", "GEODUDE", "MANKEY", "POLIWAG", "ABRA" }

  local function pick(list, seed)
    if #list == 0 then return nil end
    local n = math.floor(math.abs(tonumber(seed) or 1)) % #list + 1
    return list[n]
  end

  -- Pure builder: returns queueScript rows for a companion event kind.
  -- ctx: { name=, seed=, item=, species=, level=, martConst= }
  local function buildEventScript(kind, ctx)
    ctx = ctx or {}
    local name = ctx.name or "Your companion"
    local seed = ctx.seed or 1
    if kind == "heal" then
      return {
        { "show_text", name .. ": You look worn out. Let me fix that." },
        { "heal_party" },
        { "show_text", name .. ": All healed up. Take care out there!" },
      }
    elseif kind == "gift" then
      local item = ctx.item or pick(GIFT_ITEMS, seed)
      return {
        { "show_text", name .. ": I picked this up on my travels. It's yours." },
        { "give_item", item, 1 },
      }
    elseif kind == "giftmon" then
      local species = ctx.species or pick(GIFT_MON, seed)
      local level = ctx.level or 5
      return {
        { "play_cry", species },
        { "show_text", name .. ": This " .. species .. " needs a friend. Look after it, okay?" },
        { "give_pokemon", species, level, true },
      }
    elseif kind == "mart" then
      local const = ctx.martConst
      if not const then return nil, "no mart TEXT const known for this map" end
      return {
        { "show_text", name .. ": I run a little travelling shop. Have a look." },
        { "open_mart", const },
      }
    elseif kind == "trainer" then
      if not ctx.trainerClass then return nil, "trainerClass required" end
      return {
        { "show_text", name .. ": Let's see how strong you've gotten!" },
        { "start_battle", "trainer", ctx.trainerClass, ctx.partyIndex or 1 },
      }
    end
    return nil, "unknown event kind: " .. tostring(kind)
  end
  Api3.buildEventScript = buildEventScript
  Api3._giftItems = GIFT_ITEMS
  Api3._giftMon = GIFT_MON
  Api3._wildMon = WILD_MON

  local function runScript(rows)
    if not (mod.world and type(mod.world.queueScript) == "function") then
      return nil, "queueScript unavailable"
    end
    local ok, a, b = pcall(function()
      return mod.world:queueScript(rows, { onDone = function(doneOk, reason)
        if not doneOk then logWarn("Kanto Life API3 script failed: %s", tostring(reason)) end
      end })
    end)
    if not ok then return nil, tostring(a) end
    return a, b
  end
  Api3.runScript = runScript

  -- P5 bridge: a pending shiny request for the next Api3-started wild
  -- battle. The shiny.roll wrap (Gen 2/3) consumes it.
  local shinyPending = nil
  local function startWild(species, level, wantShiny)
    if not (mod.world and type(mod.world.startWildBattle) == "function") then
      return nil, "startWildBattle unavailable"
    end
    if wantShiny and cfg.shiny then shinyPending = species end
    local ok, a, b = pcall(function()
      return mod.world:startWildBattle(species, level, function(doneOk, reason)
        if not doneOk then shinyPending = nil end
      end)
    end)
    if not ok then shinyPending = nil; return nil, tostring(a) end
    if not a then shinyPending = nil end
    return a, b
  end
  Api3.startWild = startWild

  local EVENT_CYCLE = { "heal", "gift", "giftmon", "mart", "wild" }
  Api3._eventCycle = EVENT_CYCLE

  -- One companion interaction event. Returns kind, ok, err.
  local function runCompanionEvent(talkCount, mapId, playerLevel)
    local kind = EVENT_CYCLE[(math.max(1, math.floor(talkCount / 2)) - 1) % #EVENT_CYCLE + 1]
    if kind == "wild" then
      local species = pick(WILD_MON, talkCount * 7 + 3)
      local level = math.max(2, math.min(40, (playerLevel or 10)))
      -- Prototype visibility: 1-in-16 shiny so a play-test can actually
      -- see the shiny.roll path fire; labelled as a test rate.
      local wantShiny = cfg.shiny and (talkCount % 16 == 0)
      local ok, err = startWild(species, level, wantShiny)
      return kind, ok, err
    end
    local rows, err = buildEventScript(kind, {
      seed = talkCount * 13 + 5,
      martConst = mapId and martConsts[mapId] or nil,
    })
    if not rows then
      -- Mart with no known const degrades to gift rather than failing.
      logInfo("Kanto Life API3 event %s degraded to gift: %s", kind, tostring(err))
      kind = "gift"
      rows = buildEventScript("gift", { seed = talkCount * 13 + 5 })
    end
    local ok, rerr = runScript(rows)
    return kind, ok, rerr
  end
  Api3.runCompanionEvent = runCompanionEvent

  -- ------------------------------------------------------------------
  -- P4 -- companion (built on the P2 handle layer) + follower hook
  -- ------------------------------------------------------------------
  local companion = { id = nil, mapId = nil, sprite = nil }
  Api3.companion = companion

  local HUMAN_SPRITES = {
    [1] = { "SPRITE_YOUNGSTER", "SPRITE_LASS", "SPRITE_GIRL" },
    [2] = { "SPRITE_YOUNGSTER", "SPRITE_LASS", "SPRITE_GIRL" },
    [3] = { "OBJ_EVENT_GFX_YOUNGSTER_M", "SPRITE_YOUNGSTER", "YOUNGSTER" },
  }

  local function playerCell()
    local ow
    local ok, w = pcall(function() return mod.world and mod.world:overworld() end)
    if ok then ow = w end
    if type(ow) == "table" and ow.player then
      local p = ow.player
      if type(p.x) == "number" and type(p.y) == "number" then return p.x, p.y end
      if type(p.cellX) == "number" and type(p.cellY) == "number" then return p.cellX, p.cellY end
      if type(p.px) == "number" and type(p.py) == "number" then
        return math.floor(p.px / 16), math.floor(p.py / 16)
      end
    end
    return nil
  end
  Api3._playerCell = playerCell

  -- Gen 2 boot finding (0.3.94): the unified events cycle map.exited /
  -- map.entered repeatedly while live maps are being prepared (946
  -- spawn/despawn cycles on PLAYERS_HOUSE_2F before the title screen
  -- settled). Three guards keep the lifecycle sane on every gen:
  -- a re-entrancy flag (spawnNpc must never nest a second spawn), a
  -- same-map respawn debounce keyed on real despawns, and map.exited
  -- only retiring the companion when its own map exits (see below).
  local companionSpawning = false
  local lastDespawnAt, lastDespawnMap = 0, nil
  local despawnCompanion -- forward declaration: spawnCompanion retires a
                         -- companion left behind on another map first

  -- Gen 3 boot finding (0.3.94): map.entered fires while the world is
  -- still busy with the continue transition and spawnNpc refuses every
  -- sprite with "world is busy"; with no second map transition the
  -- companion then never appears. A failed attempt therefore arms a
  -- retry that the world.stepped handler runs (throttled to 1/second)
  -- once the player actually moves.
  local companionRetryPending = false
  local companionRetryAt = 0
  local lastEnteredMap = nil

  local function spawnCompanion(mapId)
    if not cfg.companion then return nil, "companion disabled" end
    if companion.id and companion.mapId == mapId then return companion.id end
    if companionSpawning then return nil, "spawn already in progress" end
    if lastDespawnMap == mapId and (os.time() - lastDespawnAt) < 2 then
      return nil, "respawn debounced"
    end
    if companion.id then despawnCompanion() end
    if not (mod.world and type(mod.world.spawnNpc) == "function") then
      companionRetryPending = true
      return nil, "spawnNpc unavailable"
    end
    local px, py = playerCell()
    if not px then companionRetryPending = true; return nil, "player cell unknown" end
    local sprites = HUMAN_SPRITES[gen] or HUMAN_SPRITES[1]
    companionSpawning = true
    for _, sprite in ipairs(sprites) do
      local ok, id, err = pcall(function()
        return mod.world:spawnNpc(mapId, {
          name = "KANTO_API3_COMPANION", sprite = sprite,
          x = px + 1, y = py, text = "KANTO_API3_COMPANION",
          movement = "STAY", range = "ANY_DIR",
          kantoApi3Companion = true,
        })
      end)
      if ok and id then
        companion.id, companion.mapId, companion.sprite = id, mapId, sprite
        journal.companionSpawns = (journal.companionSpawns or 0) + 1
        persistJournal()
        logInfo("Kanto Life API3 companion spawned on %s as %s (%s)", tostring(mapId), tostring(id), sprite)
        companionSpawning = false
        companionRetryPending = false
        return id
      end
      if not ok then err = id end
      logWarn("Kanto Life API3 companion spawn failed (%s): %s", sprite, tostring(err))
    end
    companionSpawning = false
    companionRetryPending = true
    return nil, "all companion sprites refused"
  end
  Api3.spawnCompanion = spawnCompanion

  despawnCompanion = function()
    companionRetryPending = false
    if companion.id then
      lastDespawnMap, lastDespawnAt = companion.mapId, os.time()
      if mod.world and type(mod.world.removeNpc) == "function" then
        local id = companion.id
        pcall(function() mod.world:removeNpc(id) end)
      end
    end
    companion.id, companion.mapId = nil, nil
  end
  Api3.despawnCompanion = despawnCompanion

  -- Travel-style catch-up: if the companion is left far behind, swap its
  -- appearance (the P2 setAppearance path the per-gen travel systems can
  -- adopt for teleport/fly swaps), place it beside the player, swap back.
  local function companionCatchUp(handle, px, py)
    local alt = (HUMAN_SPRITES[gen] or {})[2]
    if alt and alt ~= companion.sprite then swapAppearance(handle, alt) end
    placeHandle(handle, px + 1, py, "left")
    if alt and alt ~= companion.sprite and companion.sprite then
      swapAppearance(handle, companion.sprite)
    end
  end

  local DIRS = {
    { name = "right", dx = 1, dy = 0 }, { name = "left", dx = -1, dy = 0 },
    { name = "down", dx = 0, dy = 1 }, { name = "up", dx = 0, dy = -1 },
  }
  local function companionFollow(px, py)
    if not companion.id or not companion.mapId then return end
    local handle = npcHandle(companion.mapId, companion.id)
    if not handle then return end
    local movingOk, moving = pcall(function() return handle:isMoving() end)
    if movingOk and moving then return end
    local cx, cy = handlePosition(handle)
    if not cx then return end
    local dx, dy = px - cx, py - cy
    local cheby = math.max(math.abs(dx), math.abs(dy))
    if cheby > 8 then
      companionCatchUp(handle, px, py)
      return
    end
    if math.abs(dx) + math.abs(dy) <= 1 then return end
    -- Step along the dominant axis; stepHandle asks canStep first.
    local candidates = {}
    if math.abs(dx) >= math.abs(dy) then
      candidates[1] = dx > 0 and "right" or "left"
      candidates[2] = dy > 0 and "down" or (dy < 0 and "up" or nil)
    else
      candidates[1] = dy > 0 and "down" or "up"
      candidates[2] = dx > 0 and "right" or (dx < 0 and "left" or nil)
    end
    for _, dir in ipairs(candidates) do
      if dir and stepHandle(handle, dir) then return end
    end
  end
  Api3._companionFollow = companionFollow

  -- Companion talk state (per playthrough).
  local compState = saveGet("api3companion")
  if type(compState) ~= "table" then compState = { talks = 0, lastEventAt = 0 } end

  local GREETINGS = {
    "Beautiful day for a walk, isn't it?",
    "I saw a trainer rush past earlier. Everyone's busy today.",
    "Stick with me and you'll never walk alone.",
    "I keep a little journal of our travels, you know.",
    "One more step, one more story.",
  }

  local gossipDeliver -- forward declaration; assigned in P7 below

  local function partyMaxLevel()
    if not (mod.world and type(mod.world.party) == "function") then return nil end
    local ok, party = pcall(function() return mod.world:party() end)
    if not ok or type(party) ~= "table" then return nil end
    local best = nil
    for _, mon in ipairs(party) do
      local lv = type(mon) == "table" and tonumber(mon.level) or nil
      if lv and (not best or lv > best) then best = lv end
    end
    return best
  end
  Api3._partyMaxLevel = partyMaxLevel

  -- Runs on a companion talk. Returns "greeting" | event kind | nil.
  local function companionTalk(mapId)
    compState.talks = (compState.talks or 0) + 1
    saveSet("api3companion", compState)
    local talks = compState.talks
    if cfg.events and talks % 2 == 0 then
      local t = nowSeconds()
      if t == 0 or (t - (compState.lastEventAt or 0)) >= 900 then
        compState.lastEventAt = t
        saveSet("api3companion", compState)
        local kind, ok, err = runCompanionEvent(talks, mapId, partyMaxLevel())
        journal.lastCompanionEvent = kind
        persistJournal()
        if not ok then logWarn("Kanto Life API3 companion event %s failed: %s", tostring(kind), tostring(err)) end
        return kind
      end
    end
    if gossipDeliver and gossipDeliver() then return "gossip" end
    local line = GREETINGS[(talks - 1) % #GREETINGS + 1]
    local ok, err = runScript({ { "show_text", "Companion: " .. line } })
    if not ok then logWarn("Kanto Life API3 greeting failed: %s", tostring(err)) end
    return "greeting"
  end
  Api3.companionTalk = companionTalk

  local function isCompanionTarget(target)
    if type(target) ~= "table" then return false end
    if companion.id and target.id == companion.id then return true end
    local def = target.def
    if type(def) == "table" and def.name == "KANTO_API3_COMPANION" then return true end
    if target.name == "KANTO_API3_COMPANION" then return true end
    return false
  end
  Api3._isCompanionTarget = isCompanionTarget

  -- ------------------------------------------------------------------
  -- P6 -- journal / toggles screen
  -- ------------------------------------------------------------------
  local SCREEN_ID = "KANTO_LIFE_API3"
  Api3.screenId = SCREEN_ID

  local function journalLines()
    local lines = {}
    lines[#lines + 1] = "API3 PROTOTYPE BUILD"
    if journal.lastBattle then
      lines[#lines + 1] = "LAST BATTLE: " .. tostring(journal.lastBattle)
    else
      lines[#lines + 1] = "LAST BATTLE: NONE YET"
    end
    if journal.lastTrainer then
      lines[#lines + 1] = "LAST TRAINER: " .. tostring(journal.lastTrainer)
    end
    if journal.lastCompanionEvent then
      lines[#lines + 1] = "LAST EVENT: " .. tostring(journal.lastCompanionEvent):upper()
    end
    lines[#lines + 1] = "BATTLES SEEN: " .. tostring(journal.battlesSeen or 0)
    local news = type(journal.news) == "table" and journal.news or {}
    local unread = #news - (tonumber(journal.newsSeen) or 0)
    if unread > 0 then lines[#lines + 1] = "NEWS: " .. tostring(unread) .. " UNREAD" end
    if (journal.reunions or 0) > 0 then
      lines[#lines + 1] = "REUNIONS: " .. tostring(journal.reunions)
    end
    if (journal.shinySeen or 0) > 0 then
      lines[#lines + 1] = "SHINY SEEN: " .. tostring(journal.shinySeen)
    end
    return lines
  end
  Api3._journalLines = journalLines

  local function buildScreen(g)
    local items = {}
    for _, line in ipairs(journalLines()) do
      items[#items + 1] = { label = line }
    end
    local function toggleItem(label, key)
      return {
        label = label, stepper = true, kind = "toggle",
        current = cfg[key] and true or false,
        right = cfg[key] and "ON" or "OFF",
        apply = function(v)
          cfg[key] = v and true or false
          persistCfg()
          if key == "companion" and not cfg.companion then despawnCompanion() end
          if not v and Api3._featureOff then Api3._featureOff(key) end
        end,
      }
    end
    items[#items + 1] = toggleItem("COMPANION", "companion")
    items[#items + 1] = toggleItem("EMOTE BUBBLES", "emote")
    items[#items + 1] = toggleItem("COMPANION EVENTS", "events")
    items[#items + 1] = toggleItem("BATTLE JOURNAL", "battle")
    items[#items + 1] = toggleItem("SHINY EVENTS", "shiny")
    items[#items + 1] = toggleItem("GOSSIP", "gossip")
    items[#items + 1] = toggleItem("MARKET DAYS", "market")
    items[#items + 1] = toggleItem("LOST POKEMON", "lost")
    items[#items + 1] = toggleItem("SHINY FAME", "fame")
    if mod.ui and mod.ui.ListMenu and type(mod.ui.ListMenu.new) == "function" then
      local ok, menu = pcall(function() return mod.ui.ListMenu.new(g, "KANTO LIFE API3", items, {}) end)
      if ok and menu then return menu end
      logWarn("Kanto Life API3 screen ListMenu failed: %s", tostring(menu))
    end
    -- Minimal fallback state so a push never crashes the stack.
    return {
      enter = function() end, exit = function() end,
      update = function() end, draw = function() end,
    }
  end
  Api3._buildScreen = buildScreen

  -- ------------------------------------------------------------------
  -- P7-P10 -- social layer: gossip, market days, lost Pokemon, shiny fame
  -- ------------------------------------------------------------------
  -- All four run on the same portable machinery as P1-P6: spawnNpc /
  -- removeNpc, the P2 handle layer for movement, queueScript for
  -- scenes, emote rows for reactions, and the journal bucket for
  -- persistence. Every spawn is fail-open: if every candidate sprite
  -- is refused, the feature quietly skips this map.
  --
  -- Prototype cadences (labelled test rates, like the 1-in-16 shiny):
  -- a lost Pokemon may appear on every 3rd map entry, a market
  -- gathering on every 5th (never on the same entry as a lost spawn).

  -- Runtime NPC registry: id -> { role=, name=, mapId= }. The
  -- companion is tracked separately (P4) and never appears here.
  local runtimeNpcs = {}
  Api3._runtimeNpcs = runtimeNpcs
  local RUNTIME_NAMES = {
    KANTO_API3_MARKET = "market",
    KANTO_API3_LOST = "lost",
    KANTO_API3_HUNTER = "hunter",
    KANTO_API3_TRAINER = "trainer",
  }

  local function spawnRuntimeNpc(mapId, name, sprites, dx, dy)
    if not (mod.world and type(mod.world.spawnNpc) == "function") then
      return nil, "spawnNpc unavailable"
    end
    local px, py = playerCell()
    if not px then return nil, "player cell unknown" end
    local lastErr
    for _, sprite in ipairs(sprites) do
      local ok, id, err = pcall(function()
        return mod.world:spawnNpc(mapId, {
          name = name, sprite = sprite,
          x = px + (dx or 0), y = py + (dy or 0), text = name,
          movement = "STAY", range = "ANY_DIR",
          kantoApi3Runtime = true,
        })
      end)
      if ok and id then
        runtimeNpcs[id] = { role = RUNTIME_NAMES[name], name = name, mapId = mapId }
        return id, sprite
      end
      if not ok then err = id end
      lastErr = err
    end
    return nil, lastErr or "all sprites refused"
  end

  local function despawnRuntime(id)
    if id == nil then return end
    runtimeNpcs[id] = nil
    if mod.world and type(mod.world.removeNpc) == "function" then
      pcall(function() mod.world:removeNpc(id) end)
    end
  end

  local function runtimeRoleOf(target)
    if type(target) ~= "table" then return nil end
    if target.id ~= nil and runtimeNpcs[target.id] then
      return runtimeNpcs[target.id].role, runtimeNpcs[target.id]
    end
    local nm = (type(target.def) == "table" and target.def.name) or target.name
    if nm and RUNTIME_NAMES[nm] then return RUNTIME_NAMES[nm], nil end
    return nil
  end
  Api3._runtimeRoleOf = runtimeRoleOf

  -- Generic follower step (the lost Pokemon): same discipline as the
  -- companion -- canStep-guarded steps toward the player, placeAt
  -- catch-up when left far behind.
  local function followNpc(mapId, id, px, py)
    local handle = npcHandle(mapId, id)
    if not handle then return end
    local movingOk, moving = pcall(function() return handle:isMoving() end)
    if movingOk and moving then return end
    local cx, cy = handlePosition(handle)
    if not cx then return end
    local dx, dy = px - cx, py - cy
    if math.max(math.abs(dx), math.abs(dy)) > 8 then
      placeHandle(handle, px + 1, py, "left")
      return
    end
    if math.abs(dx) + math.abs(dy) <= 1 then return end
    local candidates = {}
    if math.abs(dx) >= math.abs(dy) then
      candidates[1] = dx > 0 and "right" or "left"
      candidates[2] = dy > 0 and "down" or (dy < 0 and "up" or nil)
    else
      candidates[1] = dy > 0 and "down" or "up"
      candidates[2] = dx > 0 and "right" or (dx < 0 and "left" or nil)
    end
    for _, dir in ipairs(candidates) do
      if dir and stepHandle(handle, dir) then return end
    end
  end

  -- P7: the companion shares the oldest unread news instead of a
  -- greeting. Returns true when a news line was delivered.
  gossipDeliver = function()
    if not cfg.gossip then return false end
    local text, idx = unreadNews()
    if not text then return false end
    journal.newsSeen = idx
    persistJournal()
    local ok, err = runScript({ { "show_text", "Companion: Did you hear? " .. text } })
    if not ok then logWarn("Kanto Life API3 gossip failed: %s", tostring(err)) end
    return true
  end

  -- P8 -- market days
  local marketState = { mapId = nil, ids = {} }
  Api3._marketState = marketState
  local MARKET_LINES = {
    "Fresh goods from three towns over!",
    "Market day is the best day, isn't it?",
    "I walked all morning to get here.",
    "Everyone saves up for market day.",
  }
  local function clearMarket()
    for _, id in ipairs(marketState.ids) do despawnRuntime(id) end
    marketState.ids = {}
    marketState.mapId = nil
  end
  local function marketSpawnAttempt(mapId)
    if not cfg.market then return false end
    if marketState.mapId == mapId and #marketState.ids > 0 then return true end
    clearMarket()
    local sprites = HUMAN_SPRITES[gen] or HUMAN_SPRITES[1]
    local offsets = { { 2, 0 }, { -2, 0 }, { 0, 2 } }
    local spawned = 0
    for _, off in ipairs(offsets) do
      local id = spawnRuntimeNpc(mapId, "KANTO_API3_MARKET", sprites, off[1], off[2])
      if id then
        marketState.ids[#marketState.ids + 1] = id
        spawned = spawned + 1
      end
    end
    if spawned == 0 then return false end
    marketState.mapId = mapId
    journal.marketDays = (journal.marketDays or 0) + 1
    persistJournal()
    queueEmote({ npcId = marketState.ids[1] }, "happy")
    addNews("Market day in " .. tostring(mapId) .. "! Travellers have gathered.")
    logInfo("Kanto Life API3 market day on %s (%d travellers)", tostring(mapId), spawned)
    return true
  end
  Api3._marketAttempt = marketSpawnAttempt

  -- P9 -- lost Pokemon reunions. Quest state persists in its own
  -- bucket (plain strings/numbers only): stage none -> waiting (lone
  -- Pokemon on a map) -> following (player talked to it) -> reunion
  -- (its trainer waits on the next map) -> none (scene played).
  local lostState = saveGet("api3lost")
  if type(lostState) ~= "table" then lostState = { stage = "none" } end
  Api3.lostState = lostState
  local function persistLost() saveSet("api3lost", lostState) end
  local LOST_SPECIES = { "PIDGEY", "MEOWTH", "PSYDUCK", "POLIWAG", "JIGGLYPUFF", "ODDISH", "EKANS", "SANDSHREW" }
  -- Overworld sprite candidates per gen: generic Pokemon-shaped object
  -- sprites, best-effort (the species label in dialogue is the lost
  -- Pokemon's identity; if every candidate is refused the feature
  -- skips the map silently).
  local POKE_SPRITES = {
    [1] = { "SPRITE_FAIRY", "SPRITE_BIRD", "SPRITE_MONSTER", "SPRITE_PIKACHU" },
    [2] = { "SPRITE_FAIRY", "SPRITE_BIRD", "SPRITE_MONSTER", "SPRITE_PIKACHU" },
    [3] = { "OBJ_EVENT_GFX_PIKACHU", "OBJ_EVENT_GFX_MARILL", "OBJ_EVENT_GFX_SKITTY", "OBJ_EVENT_GFX_TAILLOW", "SPRITE_PIKACHU" },
  }
  local function lostSpawnAttempt(mapId)
    if not cfg.lost then return false end
    if lostState.stage ~= "none" then return false end
    local species = pick(LOST_SPECIES, (journal.mapEntries or 1) * 7 + gen)
    local id, sprite = spawnRuntimeNpc(mapId, "KANTO_API3_LOST", POKE_SPRITES[gen] or POKE_SPRITES[1], 2, 1)
    if not id then return false end
    lostState.stage = "waiting"
    lostState.species = species
    lostState.sprite = sprite
    lostState.monId = id
    lostState.monMap = mapId
    persistLost()
    logInfo("Kanto Life API3 lost %s appeared on %s", tostring(species), tostring(mapId))
    return true
  end
  Api3._lostAttempt = lostSpawnAttempt

  -- While the lost Pokemon follows, entering a new map respawns it
  -- there (the companion pattern) and its trainer appears.
  local function lostContinue(mapId)
    if lostState.stage ~= "following" and lostState.stage ~= "reunion" then return end
    if lostState.monMap ~= mapId then
      if lostState.monId then despawnRuntime(lostState.monId) end
      local sprites = {}
      if lostState.sprite then sprites[#sprites + 1] = lostState.sprite end
      for _, s in ipairs(POKE_SPRITES[gen] or POKE_SPRITES[1]) do sprites[#sprites + 1] = s end
      local id, sprite = spawnRuntimeNpc(mapId, "KANTO_API3_LOST", sprites, 1, 0)
      if id then
        lostState.monId, lostState.monMap, lostState.sprite = id, mapId, sprite
        persistLost()
      end
    end
    if lostState.stage == "following" and not lostState.trainerId then
      local tid = spawnRuntimeNpc(mapId, "KANTO_API3_TRAINER", HUMAN_SPRITES[gen] or HUMAN_SPRITES[1], -2, 0)
      if tid then
        lostState.trainerId, lostState.trainerMap = tid, mapId
        lostState.stage = "reunion"
        persistLost()
        logInfo("Kanto Life API3 lost %s: trainer waiting on %s", tostring(lostState.species), tostring(mapId))
      end
    end
  end

  -- P10 -- shiny fame
  local hunterState = { id = nil, mapId = nil }
  Api3._hunterState = hunterState
  local function onShinySeen(species)
    if not cfg.fame then return end
    journal.shinySeen = (journal.shinySeen or 0) + 1
    journal.famePending = true
    persistJournal()
    addNews("A shiny " .. tostring(species or "POKEMON") .. " was spotted! Everyone is talking about it.")
    if companion.id then queueEmote({ npcId = companion.id }, "shock") end
  end
  Api3._onShinySeen = onShinySeen
  local function hunterSpawnAttempt(mapId)
    if not cfg.fame or not journal.famePending then return false end
    if hunterState.id then return true end
    local id = spawnRuntimeNpc(mapId, "KANTO_API3_HUNTER", HUMAN_SPRITES[gen] or HUMAN_SPRITES[1], -2, 0)
    if not id then return false end
    hunterState.id, hunterState.mapId = id, mapId
    journal.famePending = false
    persistJournal()
    logInfo("Kanto Life API3 shiny hunter appeared on %s", tostring(mapId))
    return true
  end
  Api3._hunterAttempt = hunterSpawnAttempt

  -- Talking to runtime NPCs (claimed by the talk paths in the install
  -- section, so the vanilla talk never runs for our spawned NPCs).
  local function runtimeTalk(role)
    if role == "market" then
      local text, idx = unreadNews()
      if cfg.gossip and text then
        journal.newsSeen = idx
        persistJournal()
        runScript({ { "show_text", "Traveller: Did you hear? " .. text } })
      else
        local line = MARKET_LINES[((journal.marketDays or 1) + #marketState.ids) % #MARKET_LINES + 1]
        runScript({ { "show_text", "Traveller: " .. line } })
      end
      return true
    elseif role == "lost" then
      local species = tostring(lostState.species or "POKEMON")
      if lostState.stage == "waiting" then
        lostState.stage = "following"
        persistLost()
        runScript({
          { "play_cry", species },
          { "show_text", "The lost " .. species .. " started following you! Its trainer can't be far. Try the next town!" },
        })
      else
        runScript({
          { "play_cry", species },
          { "show_text", species .. " looks around hopefully..." },
        })
      end
      return true
    elseif role == "trainer" then
      if lostState.stage ~= "reunion" then return false end
      local species = tostring(lostState.species or "POKEMON")
      queueEmote({ npcId = lostState.trainerId }, "happy")
      runScript({
        { "show_text", "Trainer: There you are! I was so worried!" },
        { "play_cry", species },
        { "show_text", "Trainer: Thank you for bringing my " .. species .. " back. Please, take this!" },
        { "give_item", pick(GIFT_ITEMS, (journal.reunions or 0) + 3), 1 },
        { "show_text", species .. " is home again. What a happy ending!" },
      })
      despawnRuntime(lostState.trainerId)
      despawnRuntime(lostState.monId)
      lostState.stage = "none"
      lostState.monId, lostState.trainerId = nil, nil
      persistLost()
      journal.reunions = (journal.reunions or 0) + 1
      persistJournal()
      addNews("A lost " .. species .. " was reunited with its trainer!")
      return true
    elseif role == "hunter" then
      runScript({
        { "show_text", "Shiny Hunter: Word travels fast! I heard about that shiny. You're famous around here now!" },
      })
      journal.hunterMet = (journal.hunterMet or 0) + 1
      persistJournal()
      despawnRuntime(hunterState.id)
      hunterState.id, hunterState.mapId = nil, nil
      return true
    end
    return false
  end
  Api3._runtimeTalk = runtimeTalk
  local function handleRuntimeTalk(target)
    local role = runtimeRoleOf(target)
    if not role then return false end
    return runtimeTalk(role)
  end
  Api3._handleRuntimeTalk = handleRuntimeTalk

  -- Social lifecycle, called from the single map.entered / map.exited /
  -- world.stepped subscriptions in the install section (the layer keeps
  -- one handler per event, like everywhere else here).
  local function socialMapEntered(mapId)
    journal.mapEntries = (journal.mapEntries or 0) + 1
    persistJournal()
    hunterSpawnAttempt(mapId)
    if lostState.stage == "following" or lostState.stage == "reunion" then
      lostContinue(mapId)
      return
    end
    local lostSpawned = false
    if (journal.mapEntries % 3) == 0 then lostSpawned = lostSpawnAttempt(mapId) end
    if (journal.mapEntries % 5) == 0 and not lostSpawned then
      marketSpawnAttempt(mapId)
    end
  end
  Api3._socialMapEntered = socialMapEntered
  local function socialMapExited(mapId)
    if not mapId then return end
    if marketState.mapId == mapId then clearMarket() end
    if hunterState.mapId == mapId and hunterState.id then
      despawnRuntime(hunterState.id)
      hunterState.id, hunterState.mapId = nil, nil
      journal.famePending = true -- the hunter looks for you in the next town
      persistJournal()
    end
    if lostState.monMap == mapId and lostState.monId then
      despawnRuntime(lostState.monId)
      lostState.monId = nil
      if lostState.stage == "waiting" then
        lostState.stage = "none" -- left behind unfound; another may appear later
      end
      persistLost()
    end
    if lostState.trainerMap == mapId and lostState.trainerId then
      despawnRuntime(lostState.trainerId)
      lostState.trainerId, lostState.trainerMap = nil, nil
      if lostState.stage == "reunion" then lostState.stage = "following" end
      persistLost()
    end
  end
  Api3._socialMapExited = socialMapExited
  local function socialStepped(ev)
    if (lostState.stage == "following" or lostState.stage == "reunion")
        and lostState.monId and lostState.monMap
        and lastEnteredMap and lostState.monMap == lastEnteredMap
        and type(ev) == "table" and type(ev.x) == "number" and type(ev.y) == "number" then
      followNpc(lostState.monMap, lostState.monId, ev.x, ev.y)
    end
  end
  Api3._socialStepped = socialStepped

  Api3._featureOff = function(key)
    if key == "market" then
      clearMarket()
    elseif key == "lost" then
      if lostState.monId then despawnRuntime(lostState.monId) end
      if lostState.trainerId then despawnRuntime(lostState.trainerId) end
      lostState.stage = "none"
      lostState.monId, lostState.trainerId = nil, nil
      persistLost()
    elseif key == "fame" then
      if hunterState.id then despawnRuntime(hunterState.id) end
      hunterState.id, hunterState.mapId = nil, nil
      journal.famePending = false
      persistJournal()
    end
  end

  -- ------------------------------------------------------------------
  -- No portable 2nd-interaction event system lives here, on purpose.
  -- The unified script rows cannot express those events without
  -- changing how they work: give_pokemon never takes one of the
  -- player's Pokemon in exchange, the unified trade verb only replays
  -- the game's native fixed trades, and a unified trainer battle
  -- needs a native trainer class with its fixed party instead of a
  -- fully random one. Instead, the event DECISIONS are unified in
  -- lib/SharedEvents.lua (one engine for all 3 gens, Joshua's
  -- Oct 21 2026 direction) while execution stays in the per-gen
  -- modules' own branches, reached from their own talk triggers --
  -- spawned NPCs only, exactly as shipped. This layer only reports
  -- the engine's registration (features.unifiedEvents).
  -- ------------------------------------------------------------------

  -- ------------------------------------------------------------------
  -- Install: events, hooks, screen registration
  -- ------------------------------------------------------------------
  local function on(event, fn)
    if not (mod.events and type(mod.events.on) == "function") then return false end
    local ok, err = pcall(function() mod.events:on(event, fn) end)
    if not ok then logWarn("Kanto Life API3 events:on %s failed: %s", event, tostring(err)) end
    return ok
  end
  local function wrap(hook, fn)
    if not (mod.hooks and type(mod.hooks.wrap) == "function") then return false end
    local ok, err = pcall(function() mod.hooks:wrap(hook, fn) end)
    if not ok then logWarn("Kanto Life API3 hooks:wrap %s failed: %s", hook, tostring(err)) end
    return ok
  end

  -- Bucket refresh: mod.save holds a pre-save bucket at entry time; the
  -- real per-playthrough data arrives with save.loaded / save.created.
  -- Re-read our buckets then, mutating the captured tables in place so
  -- every closure above sees the refreshed state.
  local function reloadBuckets()
    local function refresh(dst, key)
      local fresh = saveGet(key)
      if type(fresh) ~= "table" then return end
      for k in pairs(dst) do dst[k] = nil end
      for k, v in pairs(fresh) do dst[k] = v end
    end
    refresh(cfg, "api3cfg")
    if cfg.emote == nil then cfg.emote = true end
    if cfg.companion == nil then cfg.companion = true end
    if cfg.events == nil then cfg.events = true end
    if cfg.battle == nil then cfg.battle = true end
    if cfg.shiny == nil then cfg.shiny = true end
    if cfg.gossip == nil then cfg.gossip = true end
    if cfg.market == nil then cfg.market = true end
    if cfg.lost == nil then cfg.lost = true end
    if cfg.fame == nil then cfg.fame = true end
    refresh(journal, "api3journal")
    refresh(compState, "api3companion")
    refresh(lostState, "api3lost")
    if lostState.stage == nil then lostState.stage = "none" end
    refresh(martConsts, "api3marts")
  end
  Api3._reloadBuckets = reloadBuckets
  on("save.loaded", reloadBuckets)
  on("save.created", reloadBuckets)

  -- P1: trainer notice
  Api3.features.emote = on("world.trainer_engaged", function(ev)
    if not cfg.emote then return end
    local npc = type(ev) == "table" and ev.npc or nil
    journal.lastTrainer = (type(npc) == "table" and npc.id) or ev.trainerClass or "trainer"
    if type(ev) == "table" and ev.trainerClass then
      journal.lastTrainer = tostring(ev.trainerClass)
    end
    persistJournal()
    local ok, err = queueEmote(ev, "shock")
    if not ok then logWarn("Kanto Life API3 trainer emote failed: %s", tostring(err)) end
  end)

  -- P4: companion lifecycle
  Api3.features.companion = on("map.entered", function(ev)
    local mapId = type(ev) == "table" and ev.mapId or nil
    if mapId then
      lastEnteredMap = mapId
      spawnCompanion(mapId)
      socialMapEntered(mapId)
    end
  end)
  on("map.exited", function(ev)
    local m = type(ev) == "table" and ev.mapId or nil
    socialMapExited(m)
    -- Only retire the companion when its own map exits; Gen 2's live-map
    -- preparation fires exited for neighbouring maps too, and honouring
    -- those is what fed the boot-time spawn/despawn cycle.
    if m and companion.mapId and m ~= companion.mapId then return end
    despawnCompanion()
  end)
  on("world.stepped", function(ev)
    socialStepped(ev)
    if not cfg.companion then return end
    if companionRetryPending and not companion.id and lastEnteredMap
        and os.time() ~= companionRetryAt then
      companionRetryAt = os.time()
      spawnCompanion(lastEnteredMap)
    end
    if type(ev) == "table" and type(ev.x) == "number" and type(ev.y) == "number" then
      companionFollow(ev.x, ev.y)
    end
  end)
  local interactedOk = on("world.interacted", function(ev)
    if type(ev) ~= "table" or ev.kind ~= "npc" then return end
    -- Runtime social NPCs (P7-P10): same routing rule as the companion --
    -- the interacted path is the Gen 2 route; Gen 1/3 use world.talk.
    if not supports("hooks", "world.talk") and handleRuntimeTalk(ev.target) then
      return
    end
    if isCompanionTarget(ev.target) then
      -- Gen 1/3 answer the talk through the world.talk hook below; the
      -- interacted-driven path is the Gen 2 route (no world.talk site).
      local talkOk = supports("hooks", "world.talk")
      if not talkOk then companionTalk(ev.mapId) end
      return
    end
  end)
  on("world.live_maps_updated", function(ev)
    if type(ev) == "table" then
      local maps = ev.maps
      if type(maps) == "table" then
        local names = {}
        for i, m in ipairs(maps) do
          if i > 6 then break end
          names[#names + 1] = tostring(type(m) == "table" and (m.id or m.mapId) or m)
        end
        journal.liveMaps = table.concat(names, ",")
        persistJournal()
      end
      if cfg.companion and not companion.id and ev.mapId then
        spawnCompanion(ev.mapId)
      end
    end
  end)

  -- P4: follower hook (all gens). When our companion is out, it takes the
  -- follower slot: the vanilla follower is suppressed, ours walks instead.
  Api3.features.followerHook = wrap("world.follower.spawn", function(next, game, ow)
    journal.followerSeen = true
    persistJournal()
    if cfg.companion and companion.id then return false end
    return next(game, ow)
  end)

  -- P3 talk path for Gen 1/3 (world.talk has no Gen 2 site).
  if supports("hooks", "world.talk") then
    Api3.features.talkHook = wrap("world.talk", function(next, gameOrWorld, target)
      if handleRuntimeTalk(target) then
        return nil -- claimed: runtime social NPC (market / lost / hunter / trainer)
      end
      if isCompanionTarget(target) then
        local mapId = companion.mapId
        companionTalk(mapId)
        return nil -- claimed: do not run the vanilla talk for our runtime NPC
      end
      return next(gameOrWorld, target)
    end)
  end

  -- P5: battle journal + snapshot
  Api3.features.battle = on("battle.started", function(ev)
    if not cfg.battle then return end
    journal.battlesSeen = (journal.battlesSeen or 0) + 1
    local desc = tostring(type(ev) == "table" and ev.kind or "battle")
    if type(ev) == "table" and ev.species then
      desc = desc .. " " .. tostring(ev.species) .. " Lv" .. tostring(ev.level or "?")
    end
    if mod.battle and type(mod.battle.snapshot) == "function" then
      local ok, snap = pcall(function() return mod.battle:snapshot() end)
      if ok and type(snap) == "table" and type(snap.enemy) == "table" then
        local e = snap.enemy
        desc = desc .. " vs " .. tostring(e.species or e.name or "?") .. " Lv" .. tostring(e.level or "?")
        journal.lastSnapshotEnemy = e.species or e.name
      end
    end
    if type(ev) == "table" and ev.shiny then onShinySeen(ev.species) end
    journal.lastBattle = desc
    persistJournal()
  end)
  on("battle.ended", function(ev)
    if not cfg.battle then return end
    if type(ev) == "table" and ev.result then
      journal.lastBattleResult = ev.result
      persistJournal()
      -- P7: notable battles become gossip the companion and market
      -- travellers can share.
      if cfg.gossip and journal.lastBattle then
        addNews("People are talking about that battle: " .. tostring(journal.lastBattle)
          .. " (" .. tostring(ev.result) .. ").")
      end
    end
  end)

  -- P5: trainer.party observer. Deliberately NO mutation: Kanto Life's
  -- level rules (<=40, player-10) belong to its own event battles, and a
  -- global clamp would nerf gym leaders and the Elite Four. This records
  -- what the engine served, in the canonical API 3 record shape.
  Api3.features.trainerParty = wrap("trainer.party", function(next, trainerClass, partyIndex, party)
    local result = next(trainerClass, partyIndex, party)
    if cfg.battle then
      journal.trainerPartiesSeen = (journal.trainerPartiesSeen or 0) + 1
      local served = result or party
      if type(served) == "table" then
        local parts = {}
        for i, mon in ipairs(served) do
          if i > 6 then break end
          if type(mon) == "table" then
            parts[#parts + 1] = tostring(mon.species or "?") .. " Lv" .. tostring(mon.level or "?")
          end
        end
        journal.lastTrainerParty = table.concat(parts, ", ")
      end
      journal.lastTrainer = tostring(trainerClass)
      persistJournal()
    end
    return result
  end)

  -- P5: shiny.roll (Gen 2/3 only). Forces shiny only for a wild battle
  -- this layer started with a pending shiny request; everything else
  -- passes through untouched. A forced-shiny scripted battle (the cart's
  -- own shiny Gyarados) is never overridden by the engine.
  if supports("hooks", "shiny.roll") then
    Api3.features.shiny = wrap("shiny.roll", function(next, ctx)
      if shinyPending and type(ctx) == "table" then
        local species = ctx.species
        if species == nil or tostring(species) == tostring(shinyPending) then
          local forcedSpecies = shinyPending
          shinyPending = nil
          journal.shinyForced = (journal.shinyForced or 0) + 1
          persistJournal()
          onShinySeen(forcedSpecies) -- P10: a forced shiny is still a sighting
          return true
        end
      end
      local natural = next(ctx)
      if natural == true and type(ctx) == "table" then onShinySeen(ctx.species) end
      return natural
    end)
  end

  -- P6: screen + start-menu entry
  if mod.content and mod.content.screens and type(mod.content.screens.register) == "function" then
    local ok, err = pcall(function()
      mod.content.screens:register(SCREEN_ID, { new = function(g) return buildScreen(g) end })
    end)
    Api3.features.screen = ok
    if not ok then logWarn("Kanto Life API3 screen register failed: %s", tostring(err)) end
  end
  Api3.features.startMenu = wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then out = items end
    if type(out) == "table" then
      local copy = {}
      for i, item in ipairs(out) do copy[i] = item end
      copy[#copy + 1] = {
        label = "KANTO LIFE API3",
        onSelect = function(g2)
          if mod.ui and type(mod.ui.push) == "function" then
            pcall(function() mod.ui.push(g2 or game, SCREEN_ID) end)
          end
        end,
      }
      return copy
    end
    return out
  end)

  Api3.installed = true
  local flyOk = supports("world", "flyTo")
  -- The per-gen modules register the unified SharedEvents engine here
  -- when it loaded (they install before this layer). The layer itself
  -- never fires NPC events; the engine runs from the modules' own
  -- talk triggers.
  Api3.features.unifiedEvents = mod._kantoLifeUnifiedEvents or false
  Api3.features.gossip = true
  Api3.features.market = true
  Api3.features.lost = true
  Api3.features.fame = true
  logInfo("Kanto Life API3 layer installed (gen %s, flyTo=%s, emote=%s, companion=%s, screen=%s, unifiedEvents=%s, gossip=%s, market=%s, lost=%s, fame=%s)",
    tostring(gen), tostring(flyOk), tostring(Api3.features.emote),
    tostring(Api3.features.companion), tostring(Api3.features.screen),
    tostring(Api3.features.unifiedEvents), tostring(Api3.features.gossip),
    tostring(Api3.features.market), tostring(Api3.features.lost),
    tostring(Api3.features.fame))
  mod._kantoApi3 = Api3
  return Api3
end
