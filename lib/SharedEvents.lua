-- SharedEvents.lua -- ONE 2nd-interaction event engine for all 3 gens.
--
-- Joshua's direction (Oct 21 2026): all features exist exactly as they
-- already are, but the code is cleaned up to work better with the new
-- API -- one unified implementation instead of three near-copies. The
-- unified semantics he picked:
--   * Base: the Gen 1/2 approach -- humans roll item / trade / battle,
--     Pokemon NPCs roll item / battle; the interactive trade (player
--     picks a Pokemon to give, receives a fully random species) and
--     the declined-trade re-offer after +5 talks are unchanged.
--   * From Gen 3: Pokemon NPCs schedule 70% battle / 30% item (with a
--     fallback to the other kind when the scheduled one is on
--     cooldown), item+trade share one 15-minute "reward" gate while
--     battle has its own 15-minute gate, and when nothing is ready
--     the NPC shows the "check back later" path instead of an event.
--   * From Gen 3: battle level = lowest party member level - 10,
--     clamped to [2, 40], for every gen.
--   * Humans avoid repeating the previous kind when picking (Gen 1/2
--     rule, kept): the pool excludes st.lastKind first, then widens.
--
-- This module owns ONLY the decision + bookkeeping. Every piece of
-- execution (giving the item, running the interactive trade, starting
-- the wild / trainer battle, showing text) is a per-gen adapter
-- supplied by the calling module, and each adapter is that gen's
-- existing branch code, so what the player sees and gets is exactly
-- what the per-gen systems already produced. Talk counting, dialogue,
-- and talk-state persistence stay in the per-gen modules; this engine
-- is called from their existing trigger points, for the mod-spawned
-- NPCs those systems already serve (native map NPCs never reach it).
--
-- env = {
--   now        = fn() -> real-time seconds,
--   rnd        = fn(n) -> integer in 1..n,
--   rnd100     = fn() -> integer in 1..100,
--   persist    = fn(key, st, all),
--   battleLevel= fn(ctx) -> level for a battle (lowest-member rule),
--   giveItem   = fn(ctx) -> handled,
--   openTrade  = fn(ctx) -> handled,
--   wildBattle = fn(ctx, lv) -> handled,   -- Pokemon NPC battle
--   trainerBattle = fn(ctx, lv) -> handled, -- human NPC battle
--   waitMessage= fn(ctx) -> handled,        -- check-back-later path
-- }
-- ctx = { npc, st, key, all, isPoke, display, species, forceKind }

local M = { version = 1 }

M.REWARD_GATE_SECONDS = 900
M.BATTLE_GATE_SECONDS = 900

local function rewardReady(st, now)
  local last = tonumber(st.lastItemAt)
  if not last then return true end
  return (now - last) >= M.REWARD_GATE_SECONDS
end

local function battleReady(st, now)
  local last = tonumber(st.lastBattleAt)
  if not last then return true end
  return (now - last) >= M.BATTLE_GATE_SECONDS
end

-- Pure decision: returns "item" | "trade" | "battle" | "wait".
-- "wait" is the check-back-later path (an event was attempted but
-- every kind is on cooldown).
function M.decide(env, ctx)
  local st = ctx.st
  local now = env.now()
  local itemReady = rewardReady(st, now)
  local bReady = battleReady(st, now)
  if ctx.isPoke then
    -- Gen 3's 70/30: 70% wild battle, 30% item; fall back to the
    -- other kind when the scheduled one is on cooldown.
    local scheduled = (env.rnd100() <= 70) and "battle" or "item"
    if scheduled == "battle" then
      if bReady then return "battle" end
      if itemReady then return "item" end
    else
      if itemReady then return "item" end
      if bReady then return "battle" end
    end
    return "wait"
  end
  -- Humans: Gen 1/2 pool pick (exclude the previous kind) filtered by
  -- the split gates; widen to all ready kinds before giving up.
  local kinds = { "item", "trade", "battle" }
  local function ready(k)
    if k == "battle" then return bReady end
    return itemReady -- item and trade share the reward gate
  end
  local pool = {}
  for _, k in ipairs(kinds) do
    if k ~= st.lastKind and ready(k) then pool[#pool + 1] = k end
  end
  if #pool == 0 then
    for _, k in ipairs(kinds) do
      if ready(k) then pool[#pool + 1] = k end
    end
  end
  if #pool == 0 then return "wait" end
  return pool[env.rnd(#pool)]
end

-- Run one event attempt for an NPC whose talk trigger fired. Returns
-- whatever the adapter returns (truthy = the talk was handled).
function M.run(env, ctx)
  local st = ctx.st
  local kind = ctx.forceKind
  if kind == "trade" and ctx.isPoke then kind = nil end
  if not kind then kind = M.decide(env, ctx) end
  if kind == "wait" then
    return env.waitMessage(ctx)
  end
  if not kind then return false end
  st.lastKind = kind
  if kind ~= "battle" then
    -- Item and trade stamp the shared reward gate at selection, as
    -- Gen 1/2 stamped their single gate at selection. (Gen 3's trade
    -- also stamps on completion, overwriting with the later time.)
    -- Battle gates are stamped by the battle adapters, matching each
    -- gen's existing stamp-on-start semantics.
    st.lastItemAt = env.now()
  end
  env.persist(ctx.key, st, ctx.all)
  if kind == "item" then
    return env.giveItem(ctx)
  elseif kind == "trade" then
    return env.openTrade(ctx)
  end
  local lv = env.battleLevel(ctx)
  if ctx.isPoke then
    return env.wildBattle(ctx, lv)
  end
  return env.trainerBattle(ctx, lv)
end

-- The unified battle-level rule (Gen 3's): lowest party member - 10,
-- clamped to [2, 40].
function M.levelFor(lowestPartyLevel)
  local low = tonumber(lowestPartyLevel) or 5
  local lv = low - 10
  if lv > 40 then lv = 40 end
  if lv < 2 then lv = 2 end
  return lv
end

return M
