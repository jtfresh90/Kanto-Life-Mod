-- lib/InstallHygiene.lua
--
-- Clears the mod's persisted data every time the installed copy changes:
-- first install, update to a new version, or reinstall after removal.
--
-- The engine already removes the mod's FILES on update (installZip with
-- replace=true wipes the whole mods/<id>/ tree before copying the new one)
-- and on uninstall. What it never touches is the mod's DATA:
--   * mod.save  -> per-save-slot bucket (save.modData[modId]): NPC talk
--                  states, dialogue ledgers, travel percentages, routine
--                  state, courtesy/homes/trespass tracking...
--   * mod.cache -> installation-scoped generated files (mod_cache/<modId>/).
-- Without this wipe, stale state from the previous install survives updates
-- and reinstalls and the new code keeps driving on the old data.
--
-- Detection uses two signals:
--   * marker: mod.save["kanto_life_install"] = { version = "<manifest>" }.
--     Absent  -> first install.  Version differs -> update.
--   * install flag: the engine's enable flag for this mod id in the live
--     options (options.mods[id]). The mod sets it on every load; the engine
--     clears it on uninstall -- so "flag missing but marker present" means
--     the mod was removed and reinstalled (same version or not).
--
-- Everything here is best-effort and fail-open: if any engine surface is
-- missing (harness, odd loader), hygiene is skipped and the mod loads
-- normally. Hygiene must never break the mod.
--
-- Usage (top of main.lua's installer, before generation dispatch):
--   local hygiene = loadLocal("lib/InstallHygiene.lua")
--   hygiene(mod)  -- true, reason when a wipe happened
-- Because mod.save only carries the slot's real data after save.loaded /
-- save.created, main.lua also re-runs hygiene on those events; the
-- entry-time run is harmless and the event-time run does the real work.

local MARKER_KEY = "kanto_life_install"

-- Every top-level mod.save key the mod writes, across all three generations.
-- Per-NPC state nests inside these tables (e.g. npcTalkStates), so clearing
-- the top-level keys clears everything.
local SAVE_KEYS = {
  "courtesyWalkSteps",
  "fireredDialogueLedgerV2",
  "fireredNpcTalkStates",
  "fireredNpcTravelPctV2Seeded",
  "firered_npc_travel_pct",
  "homes",
  "npcTalkStates",
  "npcTravelPctV3Seeded",
  "npc_travel_pct",
  "outdoorTouched",
  "pendingTrespass",
  "pokeTouched",
}

-- Installation-scoped mod.cache files the mod generates. The mod currently
-- writes none; listed here so future caches are wiped with everything else.
local CACHE_FILES = {
}

local function saveGet(mod, key)
  if not (mod and mod.save and type(mod.save.get) == "function") then return nil end
  local ok, value = pcall(mod.save.get, mod.save, key)
  if not ok then return nil end
  return value
end

local function saveSet(mod, key, value)
  if not (mod and mod.save and type(mod.save.set) == "function") then return false end
  local ok = pcall(mod.save.set, mod.save, key, value)
  return ok == true
end

-- The engine's enable flag for this mod id, read from the live options the
-- same way SaveData.modEnabled does (per-version bucket first, then shared).
-- Returns true/false/nil.
local function readInstallFlag(mod)
  local id = (mod and mod.id) or "kanto_life"
  local game = mod and (mod.game or (mod.world and mod.world.game))
  local options = game and game.save and game.save.options
  if type(options) ~= "table" then return nil end
  local version = game and game.version
  if type(version) == "string" then
    local byVersion = options.modsByVersion
    local bucket = type(byVersion) == "table" and byVersion[version]
    if type(bucket) == "table" and type(bucket[id]) == "boolean" then
      return bucket[id]
    end
  end
  local shared = options.mods
  if type(shared) == "table" and type(shared[id]) == "boolean" then
    return shared[id]
  end
  return nil
end

-- Record the install flag in the live options and flush it so the signal
-- survives to the next boot. The engine clears this flag on uninstall, which
-- is what lets a later reinstall be detected.
local function writeInstallFlag(mod)
  local id = (mod and mod.id) or "kanto_life"
  local game = mod and (mod.game or (mod.world and mod.world.game))
  local options = game and game.save and game.save.options
  if type(options) ~= "table" then return false end
  local ok = pcall(function()
    options.mods = options.mods or {}
    options.mods[id] = true
  end)
  if not ok then return false end
  -- Persist immediately; options are otherwise only flushed on options-menu /
  -- mod-manager changes, and an unflushed flag would look like a reinstall
  -- on the next boot.
  pcall(function()
    if game and type(game.writeOptions) == "function" then game:writeOptions() end
  end)
  return true
end

local function wipeData(mod)
  for _, key in ipairs(SAVE_KEYS) do
    saveSet(mod, key, nil)
  end
  if mod and mod.cache and type(mod.cache.delete) == "function" then
    for _, rel in ipairs(CACHE_FILES) do
      pcall(mod.cache.delete, mod.cache, rel)
    end
  end
end

return function(mod)
  if type(mod) ~= "table" then return false, "no mod api" end
  local current = mod.version
  if type(current) ~= "string" or current == "" then
    current = mod.manifest and mod.manifest.version
  end
  if type(current) ~= "string" or current == "" then
    return false, "no version"
  end

  local marker = saveGet(mod, MARKER_KEY)
  local markedVersion = type(marker) == "table" and marker.version or nil

  local reason = nil
  if markedVersion == nil then
    reason = "fresh"
  elseif markedVersion ~= current then
    reason = "update"
  elseif readInstallFlag(mod) == nil then
    -- Marker survived but the engine's install flag is gone: the mod was
    -- removed and reinstalled. (The flag is set on every load below, so a
    -- normally installed mod always has it.)
    reason = "reinstall"
  end

  if reason then
    wipeData(mod)
    saveSet(mod, MARKER_KEY, { version = current })
    writeInstallFlag(mod)
    if type(print) == "function" then
      print(("Kanto Life: cleared mod data (%s install, %s -> %s)"):format(
        reason, tostring(markedVersion), tostring(current)))
    end
    return true, reason
  end

  -- Normal boot: make sure the install flag is present for future
  -- reinstall detection.
  writeInstallFlag(mod)
  return false, "current"
end
