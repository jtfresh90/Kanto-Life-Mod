-- Mock-mod unit tests for lib/Api3Features.lua (branch api3-features).
-- Run via tests/run_api3_mock.py (lupa). API3_PATH global points at the module.
local path = API3_PATH
local f = assert(io.open(path, "r"))
local src = f:read("*a"); f:close()
local installer = assert((loadstring or load)(src, "@Api3Features"))()

local failures = 0
local function check(cond, label)
  if cond then
    print("PASS " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
  end
end
local function eq(a, b, label) check(a == b, label .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end

local function newMod(opts)
  opts = opts or {}
  local store = {}
  local calls = { scripts = {}, spawns = {}, wild = {}, pushes = {}, steps = {}, appearances = {} }
  local handlers, wraps = {}, {}
  local handle = { x = 6, y = 6 }
  function handle:canStep(dir) return dir ~= "up" end
  function handle:stepNow(dir)
    calls.steps[#calls.steps + 1] = dir
    if dir == "down" then self.y = self.y + 1 elseif dir == "up" then self.y = self.y - 1
    elseif dir == "right" then self.x = self.x + 1 elseif dir == "left" then self.x = self.x - 1 end
    return true
  end
  function handle:face(dir) return true end
  function handle:position() return self.x, self.y end
  function handle:isMoving() return false end
  function handle:placeAt(x, y) self.x, self.y = x, y; return true end
  function handle:setAppearance(s) calls.appearances[#calls.appearances + 1] = s; return true end

  local mod = { id = "kanto_life", path = "mods/kanto_life", _calls = calls, _handlers = handlers, _wraps = wraps, _store = store }
  mod.log = {
    info = function(self, fmt, ...) end,
    warn = function(self, fmt, ...) end,
    error = function(self, fmt, ...) end,
  }
  mod.save = {
    get = function(self, k) return store[k] end,
    set = function(self, k, v) store[k] = v end,
  }
  mod.supports = function(self, surface, name)
    if surface == "world" and name == "flyTo" then return true end
    if surface == "hooks" and name == "world.talk" then return opts.talk == true end
    if surface == "hooks" and name == "shiny.roll" then return opts.shiny == true end
    return false, "unsupported in mock"
  end
  mod.events = { on = function(self, name, fn) handlers[name] = fn; return true end }
  mod.hooks = { wrap = function(self, name, fn) wraps[name] = fn; return true end }
  mod.world = {
    setFlag = function(self, k, v) store["flag:" .. k] = v; return true end,
    getFlag = function(self, k) return store["flag:" .. k] end,
    overworld = function(self) return { player = { x = 5, y = 6 } } end,
    spawnNpc = function(self, mapId, def)
      if (opts.busySpawns or 0) > 0 then
        opts.busySpawns = opts.busySpawns - 1
        return nil, "world is busy"
      end
      calls.spawns[#calls.spawns + 1] = { mapId = mapId, def = def }
      return mapId .. "_obj_99"
    end,
    removeNpc = function(self, id) calls.removed = id; return true end,
    npc = function(self, mapId, id) return handle end,
    queueScript = function(self, rows, extra)
      calls.scripts[#calls.scripts + 1] = rows
      return true
    end,
    startWildBattle = function(self, species, level, onDone)
      calls.wild[#calls.wild + 1] = { species = species, level = level }
      return true
    end,
    party = function(self) return { { level = 20 }, { level = 12 } } end,
    current = function(self) return { mapId = "PALLET_TOWN" } end,
  }
  mod.battle = { snapshot = function(self) return { enemy = { species = "MEW", level = 5 } } end }
  mod.content = { screens = { register = function(self, id, def) calls.screenId = id; calls.screenDef = def; return true end } }
  mod.ui = {
    ListMenu = { new = function(g, title, items, o) return { isMenu = true, items = items, title = title } end },
    push = function(game, id) calls.pushes[#calls.pushes + 1] = id; return true end,
  }
  mod._handle = handle
  return mod
end

local function rowsContain(rows, verb, arg2)
  for _, row in ipairs(rows or {}) do
    if row[1] == verb and (arg2 == nil or row[2] == arg2) then return true end
  end
  return false
end

-- ===== Gen 1 install (talk hook yes, shiny no) =====
local mod1 = newMod({ talk = true, shiny = false })
local A = installer(mod1, 1)
eq(A.installed, true, "gen1 install")
eq(A.features.emote, true, "gen1 emote feature on")
eq(mod1._calls.screenId, "KANTO_LIFE_API3", "gen1 screen registered")
check(mod1._wraps["world.talk"] ~= nil, "gen1 talk hook wrapped")
check(mod1._wraps["shiny.roll"] == nil, "gen1 shiny hook absent (unsupported)")
check(mod1._wraps["world.follower.spawn"] ~= nil, "gen1 follower hook wrapped")
check(mod1._wraps["trainer.party"] ~= nil, "gen1 trainer.party wrapped")
check(mod1._wraps["ui.start_menu.items"] ~= nil, "gen1 start menu wrapped")

-- ===== P3 builders =====
local heal = A.buildEventScript("heal", {})
check(rowsContain(heal, "heal_party"), "heal script has heal_party")
check(rowsContain(heal, "show_text"), "heal script has show_text")
local gift = A.buildEventScript("gift", { seed = 5 })
check(rowsContain(gift, "give_item", "POTION"), "gift script gives POTION for seed 5 (index 1)")
local gm = A.buildEventScript("giftmon", { seed = 2 })
check(rowsContain(gm, "give_pokemon") and rowsContain(gm, "play_cry"), "giftmon has play_cry + give_pokemon")
local martRows, martErr = A.buildEventScript("mart", {})
eq(martRows, nil, "mart without const refused")
check(type(martErr) == "string", "mart refusal has reason")
local mart2 = A.buildEventScript("mart", { martConst = "TEXT_MART" })
check(rowsContain(mart2, "open_mart", "TEXT_MART"), "mart with const has open_mart")
local tr, trErr = A.buildEventScript("trainer", {})
eq(tr, nil, "trainer without class refused")
local bad, badErr = A.buildEventScript("nope", {})
eq(bad, nil, "unknown kind refused")

-- ===== P1 emote targets + trainer_engaged =====
local tg = A._emoteTargets({ npc = { id = "PALLET_TOWN_obj_7" } })
eq(tg[1], 7, "emote target parses obj index first")
mod1._handlers["world.trainer_engaged"]({ npc = { id = "ROUTE_1_obj_3" }, trainerClass = "YOUNGSTER" })
local lastScript = mod1._calls.scripts[#mod1._calls.scripts]
check(rowsContain(lastScript, "emote", 3), "trainer_engaged queued emote on index 3")
eq(lastScript[1][3], "shock", "emote bubble is shock")
eq(A.journal.lastTrainer, "YOUNGSTER", "journal recorded trainer class")

-- ===== P4 companion spawn + follow (P2 handles) =====
mod1._handlers["map.entered"]({ mapId = "PALLET_TOWN" })
eq(#mod1._calls.spawns, 1, "companion spawned on map.entered")
eq(A.companion.id, "PALLET_TOWN_obj_99", "companion id recorded")
eq(A.companion.sprite, "SPRITE_YOUNGSTER", "companion sprite gen1 first choice")
-- player steps far below: companion at (6,6), player cell in stepped ev (5,10)
mod1._handlers["world.stepped"]({ mapId = "PALLET_TOWN", x = 5, y = 10 })
eq(mod1._calls.steps[1], "down", "companion stepped down toward player (canStep-guarded)")
-- follower hook suppresses vanilla follower while companion is out
local followerWrap = mod1._wraps["world.follower.spawn"]
local vanillaCalled = false
local res = followerWrap(function(g, ow) vanillaCalled = true; return true end, {}, {})
eq(res, false, "follower hook suppresses vanilla follower with companion out")
eq(vanillaCalled, false, "vanilla follower not called")

-- ===== P5 battle journal =====
mod1._handlers["battle.started"]({ kind = "wild", species = "PIDGEY", level = 3 })
eq(A.journal.battlesSeen, 1, "battle counted")
check(tostring(A.journal.lastBattle):find("MEW") ~= nil, "snapshot enemy recorded in journal")
local partyWrap = mod1._wraps["trainer.party"]
local served = { { species = "MEW", level = 5 } }
local outParty = partyWrap(function(c, i, p) return p end, "YOUNGSTER", 1, served)
eq(outParty, served, "trainer.party observer returns party unchanged")
check(tostring(A.journal.lastTrainerParty):find("MEW") ~= nil, "trainer party journal recorded")

-- ===== P6 start menu + screen =====
local menuWrap = mod1._wraps["ui.start_menu.items"]
local items = menuWrap(function(g, it) return it end, {}, { { label = "POKEMON" } })
eq(items[#items].label, "KANTO LIFE API3", "start menu row appended")
items[#items].onSelect({})
eq(mod1._calls.pushes[1], "KANTO_LIFE_API3", "start menu row pushes Api3 screen")
local screen = A._buildScreen({})
check(screen.isMenu == true, "screen builds a ListMenu")
local foundToggle = false
for _, it in ipairs(screen.items) do if it.label == "COMPANION" and it.kind == "toggle" then foundToggle = true end end
check(foundToggle, "screen has companion toggle")

-- ===== Gen 2 install (no talk hook -> interacted path; shiny yes) =====
local mod2 = newMod({ talk = false, shiny = true })
local B = installer(mod2, 2)
eq(B.installed, true, "gen2 install")
check(mod2._wraps["world.talk"] == nil, "gen2 talk hook absent")
check(mod2._wraps["shiny.roll"] ~= nil, "gen2 shiny hook wrapped")
mod2._handlers["map.entered"]({ mapId = "NEW_BARK_TOWN" })
eq(B.companion.id, "NEW_BARK_TOWN_obj_99", "gen2 companion spawned")
-- talk 1: greeting via interacted
mod2._handlers["world.interacted"]({ kind = "npc", mapId = "NEW_BARK_TOWN", target = { id = "NEW_BARK_TOWN_obj_99" } })
local g1 = mod2._calls.scripts[#mod2._calls.scripts]
check(rowsContain(g1, "show_text"), "gen2 companion talk 1 is a greeting")
-- talk 2: first companion event = heal (cycle[1]), party max level via world.party
mod2._handlers["world.interacted"]({ kind = "npc", mapId = "NEW_BARK_TOWN", target = { id = "NEW_BARK_TOWN_obj_99" } })
local g2 = mod2._calls.scripts[#mod2._calls.scripts]
check(rowsContain(g2, "heal_party"), "gen2 companion talk 2 runs heal event script")
eq(B.journal.lastCompanionEvent, "heal", "gen2 journal recorded heal event")

-- ===== P5 shiny pending via startWild =====
local okWild = B.startWild("ABRA", 5, true)
eq(okWild, true, "startWild ok")
eq(mod2._calls.wild[1].species, "ABRA", "startWild species recorded")
local shinyWrap = mod2._wraps["shiny.roll"]
local forced = shinyWrap(function(ctx) return false end, { species = "ABRA" })
eq(forced, true, "shiny.roll forced for pending Api3 wild battle")
local passthrough = shinyWrap(function(ctx) return false end, { species = "ABRA" })
eq(passthrough, false, "shiny pending consumed after one force")

-- ===== Gen 3 busy-world spawn retry =====
-- map.entered fires during the continue transition: every sprite is
-- refused with "world is busy". The retry armed by the failure must
-- spawn the companion on a later world.stepped once the world settles.
local mod3 = newMod({ talk = true, shiny = true, busySpawns = 3 })
local A3 = installer(mod3, 3)
eq(A3.installed, true, "gen3 install")
mod3._handlers["map.entered"]({ mapId = "LITTLEROOT_TOWN" })
eq(#mod3._calls.spawns, 0, "gen3 busy world refused all companion sprites")
eq(A3.companion.id, nil, "gen3 companion not recorded after busy refusal")
mod3._handlers["world.stepped"]({ mapId = "LITTLEROOT_TOWN", x = 5, y = 6 })
eq(#mod3._calls.spawns, 1, "gen3 companion spawned on stepped retry")
eq(A3.companion.id, "LITTLEROOT_TOWN_obj_99", "gen3 companion id recorded after retry")

-- ===== api < 3 inert =====
local modOld = newMod({})
modOld.supports = nil
local C = installer(modOld, 1)
eq(C.installed, false, "api<3 layer inert")

print(failures == 0 and "ALL TESTS PASSED" or ("FAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
