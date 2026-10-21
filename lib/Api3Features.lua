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
  Api3.cfg = cfg
  local function persistCfg() saveSet("api3cfg", cfg) end
  persistCfg()

  local journal = saveGet("api3journal")
  if type(journal) ~= "table" then journal = {} end
  journal.battlesSeen = journal.battlesSeen or 0
  journal.trainerPartiesSeen = journal.trainerPartiesSeen or 0
  Api3.journal = journal
  local function persistJournal() saveSet("api3journal", journal) end

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
        end,
      }
    end
    items[#items + 1] = toggleItem("COMPANION", "companion")
    items[#items + 1] = toggleItem("EMOTE BUBBLES", "emote")
    items[#items + 1] = toggleItem("COMPANION EVENTS", "events")
    items[#items + 1] = toggleItem("BATTLE JOURNAL", "battle")
    items[#items + 1] = toggleItem("SHINY EVENTS", "shiny")
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
    refresh(journal, "api3journal")
    refresh(compState, "api3companion")
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
    if mapId then lastEnteredMap = mapId; spawnCompanion(mapId) end
  end)
  on("map.exited", function(ev)
    -- Only retire the companion when its own map exits; Gen 2's live-map
    -- preparation fires exited for neighbouring maps too, and honouring
    -- those is what fed the boot-time spawn/despawn cycle.
    local m = type(ev) == "table" and ev.mapId or nil
    if m and companion.mapId and m ~= companion.mapId then return end
    despawnCompanion()
  end)
  on("world.stepped", function(ev)
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
  on("world.interacted", function(ev)
    if type(ev) ~= "table" or ev.kind ~= "npc" then return end
    if not isCompanionTarget(ev.target) then return end
    -- Gen 1/3 answer the talk through the world.talk hook below; the
    -- interacted-driven path is the Gen 2 route (no world.talk site).
    local talkOk = supports("hooks", "world.talk")
    if not talkOk then companionTalk(ev.mapId) end
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
    journal.lastBattle = desc
    persistJournal()
  end)
  on("battle.ended", function(ev)
    if not cfg.battle then return end
    if type(ev) == "table" and ev.result then
      journal.lastBattleResult = ev.result
      persistJournal()
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
          shinyPending = nil
          journal.shinyForced = (journal.shinyForced or 0) + 1
          persistJournal()
          return true
        end
      end
      return next(ctx)
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
  logInfo("Kanto Life API3 layer installed (gen %s, flyTo=%s, emote=%s, companion=%s, screen=%s)",
    tostring(gen), tostring(flyOk), tostring(Api3.features.emote),
    tostring(Api3.features.companion), tostring(Api3.features.screen))
  mod._kantoApi3 = Api3
  return Api3
end
