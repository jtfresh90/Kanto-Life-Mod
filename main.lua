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
