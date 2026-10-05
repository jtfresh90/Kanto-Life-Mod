-- Kanto Life Unified
-- Generation dispatch only: each generation keeps its own implementation.
return function(mod)
  local function loadLocal(rel)
    local source, err = mod:read(rel)
    if type(source) ~= "string" then
      error("Kanto Life: missing bundled module " .. rel .. ": " .. tostring(err), 0)
    end
    local compile = loadstring or load
    local chunk, compileErr = compile(source, "@" .. mod.path .. "/" .. rel)
    if not chunk then
      error("Kanto Life: cannot compile " .. rel .. ": " .. tostring(compileErr), 0)
    end
    local ok, value = pcall(chunk)
    if not ok then error("Kanto Life: cannot load " .. rel .. ": " .. tostring(value), 0) end
    if type(value) ~= "function" then error("Kanto Life: " .. rel .. " must return an installer function", 0) end
    return value
  end
  -- Install hygiene: clear the mod's persisted data (mod.save bucket +
  -- mod.cache files) on fresh install, update, or reinstall-after-removal,
  -- before any generation code reads it. The engine already clears the
  -- mod's files on update/remove; this covers the data the engine leaves.
  -- Fail-open: hygiene must never break mod load.
  --
  -- NOTE: mod.save is not populated with the slot's real data until the
  -- save is adopted (save.loaded/save.created), which happens AFTER mod
  -- entry. So the check runs now (harmless on the pre-save bucket) and is
  -- re-run when the real save data arrives -- that is when update/reinstall
  -- wipes actually take effect.
  pcall(function()
    local hygiene = loadLocal("lib/InstallHygiene.lua")
    hygiene(mod)
    -- Re-run when the slot's real save data is adopted (save.loaded for
    -- Continue, save.created for New Game). The entry-time check above runs
    -- on the pre-save bucket; the event-time check sees the real data, so
    -- update/reinstall wipes actually take effect. Colon-call syntax is
    -- required by the events API.
    if mod.events and type(mod.events.on) == "function" then
      mod.events:on("save.loaded", function() pcall(hygiene, mod) end)
      mod.events:on("save.created", function() pcall(hygiene, mod) end)
    end
  end)

  local gen
  local okGV, GV = pcall(require, "src.core.GameVersion")
  if okGV and GV and type(GV.generation) == "function" then
    local okGen, value = pcall(GV.generation)
    if okGen and value ~= nil then gen = tonumber(value) end
  end
  if gen == nil and mod.game and mod.game.generation ~= nil then gen = tonumber(mod.game.generation) end
  if gen == nil then error("Kanto Life: could not determine the active game generation", 0) end

  -- One-time migration of the old separate Johto-Life settings bucket.
  -- Only runs on Gen2 and only when the unified bucket has not been created.
  if gen == 2 then
    pcall(function()
      local g = mod.game or (mod.world and mod.world.game)
      local opts = g and g.save and g.save.options
      if opts and opts.modOptions and opts.modOptions.kanto_life == nil
         and opts.modOptions.johto_life ~= nil then
        local old = opts.modOptions.johto_life
        local copy = {}
        for k,v in pairs(old) do copy[k] = v end
        opts.modOptions.kanto_life = copy
      end
    end)
  end

  local rel
  if gen == 1 then rel = "lib/KantoMain.lua"
  elseif gen == 2 then rel = "lib/JohtoMain.lua"
  elseif gen == 3 then rel = "lib/FireRedMain.lua"
  else error("Kanto Life: unsupported game generation " .. tostring(gen), 0) end

  print("KANTO DEBUG dispatch", gen, rel)
  local installer = loadLocal(rel)
  print("KANTO DEBUG loaded installer", rel)
  print("KANTO DEBUG installing", rel)
  local okRun, err = pcall(installer, mod)
  print("KANTO DEBUG installed", rel, okRun, err)
  if not okRun then error(err, 0) end
end
