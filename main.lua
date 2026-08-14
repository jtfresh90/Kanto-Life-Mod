return function(mod)
  local parts = {}
  local n = 5
  for i = 1, n do
    local data, err = mod:read("src/p" .. i .. ".txt")
    if not data then
      error(("Kanto Life: missing src/p%d.txt (%s)"):format(i, tostring(err)), 0)
    end
    parts[i] = data
  end
  local src = table.concat(parts)
  local chunk, err = load(src, "=@kanto_life/main.lua")
  if not chunk then
    error("Kanto Life load failed: " .. tostring(err), 0)
  end
  local entry = chunk()
  if type(entry) ~= "function" then
    error("Kanto Life entry is not a function", 0)
  end
  return entry(mod)
end
