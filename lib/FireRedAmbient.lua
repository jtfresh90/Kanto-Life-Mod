-- FireRed ambient NPC population using the native Game3 EventObject shape.
--
-- Important FireRed detail: Pokémon overworld actors are not Gen2 SPRITE_* names.
-- pret FireRed assigns them real OBJ_EVENT_GFX ids 109..150, and gen1recomp's
-- Game3 OwSprites extractor already extracts the complete FRLG object-graphics
-- table from the loaded FireRed ROM.  We therefore keep the graphicsId on the
-- ambient EventObject and let FieldView/OwSprites render the actual FRLG sprite.
return function(ctx)
  local mod = ctx.mod
  local getOption = ctx.getOption
  local getWorld = ctx.getWorld
  local setOption = ctx.setOption
  local getFieldState = ctx.getFieldState
  local api = {}
  local function engine(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
  end
  local function gameLayout()
    local GV = engine("src.core.GameVersion")
    return GV and GV.layout and GV.layout() or "frlg"
  end
  local spawned = {}
  local serial = 0
  local lastMap = nil
  local pendingPokemonBattle = nil

  -- Cross-map traveler pool (Gen 3): when an NPC exits through a door/warp
  -- to a DIFFERENT map, they are recorded here instead of being replaced on
  -- the same map. When the player enters the destination map, the traveler
  -- spawns at the entrance connecting from their origin map (paired exit/
  -- entry). Same-map exits use the existing replacement logic unchanged.
  -- travelers[destMapId] = { {graphicsId, isPoke, species, agenda, fromMap, timestamp}, ... }
  local travelers = {}
  local TRAVELER_EXPIRY = 600  -- seconds; discard if player never visits

  local function pruneTravelers()
    local now = os.time()
    for destMap, list in pairs(travelers) do
      local kept = {}
      for _, t in ipairs(list) do
        if now - (t.timestamp or 0) < TRAVELER_EXPIRY then
          kept[#kept + 1] = t
        end
      end
      if #kept > 0 then travelers[destMap] = kept
      else travelers[destMap] = nil end
    end
  end

  -- Resolve a warp/door definition to its destination map ID string.
  local function warpDestMapId(warp)
    if type(warp) ~= "table" then return nil end
    if warp.destMap ~= nil then return tostring(warp.destMap) end
    if warp.mapGroup ~= nil and warp.mapNum ~= nil then
      local okCatalog, Catalog = pcall(require, "src.import.gba.map_catalog")
      if okCatalog and Catalog and type(Catalog.mapIdFor) == "function" then
        local ok, id = pcall(Catalog.mapIdFor, warp.mapGroup, warp.mapNum)
        if ok and id ~= nil then return tostring(id) end
      end
    end
    return nil
  end

  -- Build pools from the active Gen3 profile's actual event-object constants.
  -- FRLG and Emerald use different graphics tables, so hard-coding FireRed
  -- ids here would silently show the wrong sprites on Emerald.
  local GFX_SPECIES, SPECIES_GFX, POKE_GFX = {}, {}, {}
  local HUMAN_GFX = {}
  local function buildGraphicsPools()
    local Constants = engine("src.core.game3.constants")
    local GV = engine("src.core.GameVersion")
    local version = GV and GV.get and GV.get() or nil
    local C = Constants and Constants.of and Constants.of(version) or nil
    local byName = C and C.event_objects and C.event_objects.byName or nil
    if type(byName) ~= "table" then return end

    local function gid(name) return tonumber(byName[name]) end
    local humanNames = {
      "OBJ_EVENT_GFX_BOY_1","OBJ_EVENT_GFX_GIRL_1","OBJ_EVENT_GFX_BOY_2","OBJ_EVENT_GFX_GIRL_2",
      "OBJ_EVENT_GFX_BOY_3","OBJ_EVENT_GFX_GIRL_3","OBJ_EVENT_GFX_LITTLE_BOY","OBJ_EVENT_GFX_LITTLE_GIRL",
      "OBJ_EVENT_GFX_WOMAN_1","OBJ_EVENT_GFX_WOMAN_2","OBJ_EVENT_GFX_WOMAN_3","OBJ_EVENT_GFX_WOMAN_4",
      "OBJ_EVENT_GFX_WOMAN_5","OBJ_EVENT_GFX_MAN_1","OBJ_EVENT_GFX_MAN_2","OBJ_EVENT_GFX_MAN_3",
      "OBJ_EVENT_GFX_OLD_MAN","OBJ_EVENT_GFX_OLD_WOMAN","OBJ_EVENT_GFX_YOUNGSTER","OBJ_EVENT_GFX_CAMPER",
      "OBJ_EVENT_GFX_PICNICKER","OBJ_EVENT_GFX_POKEFAN_M","OBJ_EVENT_GFX_POKEFAN_F","OBJ_EVENT_GFX_LASS",
      "OBJ_EVENT_GFX_BUG_CATCHER","OBJ_EVENT_GFX_SCHOOL_KID_M","OBJ_EVENT_GFX_EXPERT_M","OBJ_EVENT_GFX_EXPERT_F",
      "OBJ_EVENT_GFX_PSYCHIC_M","OBJ_EVENT_GFX_HIKER","OBJ_EVENT_GFX_FISHERMAN","OBJ_EVENT_GFX_SAILOR",
      "OBJ_EVENT_GFX_BLACK_BELT","OBJ_EVENT_GFX_BEAUTY","OBJ_EVENT_GFX_GENTLEMAN","OBJ_EVENT_GFX_SCIENTIST_1",
      "OBJ_EVENT_GFX_MANIAC","OBJ_EVENT_GFX_HEX_MANIAC","OBJ_EVENT_GFX_NURSE","OBJ_EVENT_GFX_MART_EMPLOYEE",
    }
    for _, name in ipairs(humanNames) do local n=gid(name); if n then HUMAN_GFX[#HUMAN_GFX+1]=n end end

    local Pokemon = engine("src.core.game3.pokemon")
    for id, name in pairs(Pokemon and Pokemon._names or {}) do
      id = tonumber(id)
      if id and type(name)=="string" then
        local key = name:upper():gsub("[^A-Z0-9]+", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
        local n = gid("OBJ_EVENT_GFX_" .. key)
        if n then
          GFX_SPECIES[n] = key
          if SPECIES_GFX[key] == nil then SPECIES_GFX[key] = n end
          POKE_GFX[#POKE_GFX+1] = n
        end
      end
    end
    table.sort(POKE_GFX)
    -- Explicit aliases used by the FRLG constants.
    local aliases = { HO_OH="HO_OH", NIDORAN_F="NIDORAN_F", NIDORAN_M="NIDORAN_M" }
    for k,v in pairs(aliases) do if not SPECIES_GFX[k] then local n=gid("OBJ_EVENT_GFX_"..v); if n then SPECIES_GFX[k]=n; GFX_SPECIES[n]=k; POKE_GFX[#POKE_GFX+1]=n end end end
  end
  buildGraphicsPools()

  local recentPokeGfx = {}
  local opt

  local function rememberPokeGfx(gid)
    recentPokeGfx[#recentPokeGfx + 1] = gid
    while #recentPokeGfx > 6 do table.remove(recentPokeGfx, 1) end
  end

  local function recentlyUsed(gid)
    for _, v in ipairs(recentPokeGfx) do if v == gid then return true end end
    return false
  end

  local function addEncounterSlots(dst, seen, block)
    if type(block) ~= "table" then return end
    local slots = block.slots or block
    if type(slots) ~= "table" then return end
    for _, slot in ipairs(slots) do
      local species = type(slot) == "table" and (slot.species or slot.pokemon or slot.mon or slot[1]) or slot
      if type(species) == "number" then
        local Pokemon = engine("src.core.game3.pokemon")
        if Pokemon and type(Pokemon.keyName) == "function" then
          local ok, key = pcall(Pokemon.keyName, species)
          if ok then species = key end
        end
      end
      species = type(species) == "string" and species:upper() or nil
      if species and SPECIES_GFX[species] and not seen[species] then
        seen[species] = true
        dst[#dst + 1] = species
      end
    end
  end

  local function destinationMapId(warp)
    if not warp then return nil end
    if warp.destMap then return warp.destMap end
    if warp.mapGroup ~= nil and warp.mapNum ~= nil then
      local okCatalog, Catalog = pcall(require, "src.import.gba.map_catalog")
      if okCatalog and Catalog and type(Catalog.mapIdFor) == "function" then
        local ok, id = pcall(Catalog.mapIdFor, warp.mapGroup, warp.mapNum)
        if ok then return id end
      end
    end
    return nil
  end

  -- FireRed towns generally have no wild table of their own. Build a local
  -- ambient-Pokémon pool from the current map first, then connected maps,
  -- preferring connected routes. Only species with an actual FRLG overworld
  -- object graphic are eligible, because these NPCs are EventObjects.
  local function encounterPoolsForMap(mapId, map)
    local Encounters = engine("src.core.game3.encounters")
    local land, water, seenL, seenW, seenMaps = {}, {}, {}, {}, {}
    if not Encounters then return land, water end
    pcall(function() Encounters.ensureLoaded() end)
    local tables = Encounters._tables or {}
    local function take(mid)
      if not mid or seenMaps[tostring(mid)] then return end
      seenMaps[tostring(mid)] = true
      local enc = tables[mid]
      if type(enc) ~= "table" then return end
      addEncounterSlots(land, seenL, enc.land)
      addEncounterSlots(water, seenW, enc.water)
      addEncounterSlots(water, seenW, enc.surfing)
      addEncounterSlots(water, seenW, enc.fish)
      addEncounterSlots(water, seenW, enc.fishing)
    end
    take(mapId)
    if map then
      local def = map.def or map
      local conns = def and def.connections
      if type(conns) == "table" then
        for _, dir in ipairs({"north","south","east","west"}) do
          local c = conns[dir]
          take(c and (c.map or c.mapId or c.dest))
        end
      end
      for _, w in ipairs(map.warps or {}) do
        local dest = destinationMapId(w)
        if dest and tostring(dest):upper():find("ROUTE", 1, true) then take(dest) end
      end
    end
    return land, water
  end

  local function externalSpeciesGraphics(speciesId, speciesNameValue)
    local candidates = {
      "1025dex", "1025_dex", "pokemon_1025", "pokemon1025", "dex1025", "expanded_dex",
    }
    local function tryExport(obj)
      if type(obj) ~= "table" then return nil end
      local ex = obj.exports or obj
      for _, key in ipairs({"graphicsForSpecies","speciesGraphics","getGraphicsId","graphicsIdForSpecies","overworldGraphics","getOverworldGraphics"}) do
        local fn = ex[key]
        if type(fn) == "function" then
          local ok, v = pcall(fn, speciesId, speciesNameValue)
          if ok and tonumber(v) then return tonumber(v) end
        end
      end
      return nil
    end
    if type(mod.find) == "function" then
      for _, id in ipairs(candidates) do
        local ok, m = pcall(mod.find, id)
        if ok and m then local gid = tryExport(m); if gid then return gid end end
      end
    end
    local Ow = engine("src.core.game3.ow_sprites")
    if Ow then
      for _, key in ipairs({"graphicsForSpecies","speciesGraphics","graphicsIdForSpecies","getGraphicsId"}) do
        local fn = Ow[key]
        if type(fn) == "function" then
          local ok, v = pcall(fn, speciesId, speciesNameValue)
          if ok and tonumber(v) then return tonumber(v) end
        end
      end
    end
    return nil
  end

  local function expandedSpeciesPool()
    local Pokemon = engine("src.core.game3.pokemon")
    local out = {}
    if Pokemon then
      pcall(function() if Pokemon.ready and not Pokemon.ready() and Pokemon.install then Pokemon.install(Pokemon._cache) end end)
      for id, name in pairs(Pokemon._names or {}) do
        id = tonumber(id)
        if id and id > 0 and type(name) == "string" and name ~= "" and name ~= "??????????" then
          if not Pokemon.SPECIES_EGG or id ~= Pokemon.SPECIES_EGG then out[#out+1] = {id=id,name=name} end
        end
      end
    end
    table.sort(out, function(a,b) return a.id < b.id end)
    return out
  end

  local function choosePokemonGfx(mapId, map, water)
    local randomPoke = opt("firered_poke_random", true) ~= false
    if randomPoke then
      -- When an expanded 1025-Dex/overworld-sprite provider is loaded, draw
      -- from its complete species table rather than limiting random spawns to
      -- FireRed's original 42 Pokémon graphics.  If no provider is present,
      -- safely fall back to the native FRLG object graphics.
      local expanded = expandedSpeciesPool()
      local attempts = math.min(80, #expanded)
      for _ = 1, attempts do
        if #expanded == 0 then break end
        local pick = expanded[math.random(1, #expanded)]
        local gid = externalSpeciesGraphics(pick.id, pick.name)
        if gid and not recentlyUsed(gid) then
          rememberPokeGfx(gid)
          return gid, pick.name
        end
      end
      local pool = {}
      for _, gid in ipairs(POKE_GFX) do if not recentlyUsed(gid) then pool[#pool + 1] = gid end end
      if #pool == 0 then pool = POKE_GFX end
      if #pool == 0 then return nil, nil end
      local gid = pool[math.random(1, #pool)]
      rememberPokeGfx(gid)
      return gid, GFX_SPECIES[gid]
    end
    local land, waterPool = encounterPoolsForMap(mapId, map)
    local pool = water and #waterPool > 0 and waterPool or land
    if #pool == 0 then pool = (#waterPool > 0 and waterPool or land) end
    if #pool > 0 then
      local species = pool[math.random(1, #pool)]
      local gid = SPECIES_GFX[species]
      if gid then rememberPokeGfx(gid); return gid, species end
    end
    -- No extracted encounter table or no matching overworld graphics: retain
    -- the safe FRLG overworld pool rather than inventing an invalid sprite.
    local gid = POKE_GFX[math.random(1, #POKE_GFX)]
    rememberPokeGfx(gid)
    return gid, GFX_SPECIES[gid]
  end

  opt = function(key, default)
    if type(getOption) == "function" then
      local ok, v = pcall(getOption, key, default)
      if ok and v ~= nil then return v end
    end
    local ok, v = pcall(mod.options.get, mod.options, key)
    if ok and v ~= nil then return v end
    return default
  end

  local function world()
    return type(getFieldState) == "function" and getFieldState() or nil
  end

  local function isIndoor(map)
    if not map then return false end
    if type(map.isOutdoor) == "function" then
      local ok, out = pcall(map.isOutdoor, map)
      if ok then return not out end
    end
    return false
  end

  local function isHouse(mapId)
    local s = tostring(mapId or ""):upper()
    return s:find("HOUSE", 1, true) ~= nil or s:find("PLAYERS_HOUSE", 1, true) ~= nil
  end

  local function clear()
    local Objects = engine("src.core.game3.objects")
    if Objects then
      for lid in pairs(spawned) do
        if Objects._byId then Objects._byId[lid] = nil end
        for i = #Objects._order, 1, -1 do
          if Objects._order[i] == lid then table.remove(Objects._order, i) break end
        end
        if Objects._tracks then Objects._tracks[lid] = nil end
        if Objects._defs then
          for i = #Objects._defs, 1, -1 do
            local d = Objects._defs[i]
            if tonumber(d and (d.localId or d.index)) == tonumber(lid) then
              table.remove(Objects._defs, i)
              break
            end
          end
        end
      end
      local okF, FieldView = pcall(require, "src.core.game3.field_view")
      if okF and FieldView then FieldView._nativeDirty = true end
    end
    spawned = {}
  end

  local function occupied(x, y, exceptLocalId)
    local Objects = engine("src.core.game3.objects")
    if not Objects then return true end
    if type(Objects.blocks) == "function" then
      local ok, blocked = pcall(Objects.blocks, x, y, exceptLocalId)
      if ok and blocked then return true end
    elseif type(Objects.at) == "function" then
      local ok, eo = pcall(Objects.at, x, y)
      if ok and eo then return true end
    end
    local Player = engine("src.core.game3.player")
    return Player and Player.cellX == x and Player.cellY == y or false
  end

  local function walkableComponentMask(ow)
    local map = ow and ow.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil end
    local w = tonumber(map.widthCells or map.width) or 0
    local h = tonumber(map.heightCells or map.height) or 0
    if w <= 0 or h <= 0 then return nil end

    -- On outdoor FireRed maps, house roofs can be walkable but are normally
    -- disconnected from the ground walkable graph.  Seed the graph from the
    -- cells immediately around real map warps/doors, then only use cells that
    -- belong to that ground-connected graph.  This keeps ambient spawns off
    -- isolated roof islands without hard-coding any map's roof tile IDs.
    local seeds = {}
    for _, wd in ipairs(map.warps or {}) do
      local wx, wy = tonumber(wd.x), tonumber(wd.y)
      if wx and wy then
        for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local sx, sy = wx + d[1], wy + d[2]
          if sx >= 0 and sy >= 0 and sx < w and sy < h
              and map:isWalkableCell(sx, sy) then
            seeds[#seeds + 1] = {sx, sy}
          end
        end
      end
    end
    if #seeds == 0 then return nil end

    local allowed = {}
    local qx, qy, head = {}, {}, 1
    local function push(x, y)
      local key = tostring(x) .. ":" .. tostring(y)
      if allowed[key] then return end
      allowed[key] = true
      qx[#qx + 1], qy[#qy + 1] = x, y
    end
    for _, seed in ipairs(seeds) do push(seed[1], seed[2]) end
    while head <= #qx do
      local x, y = qx[head], qy[head]
      head = head + 1
      for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
        local nx, ny = x + d[1], y + d[2]
        if nx >= 0 and ny >= 0 and nx < w and ny < h
            and map:isWalkableCell(nx, ny) then
          push(nx, ny)
        end
      end
    end
    return allowed
  end

  local function candidateCells(ow)
    local map = ow and ow.map
    local out = {}
    local groundMask = walkableComponentMask(ow)
    local w = tonumber(map and (map.widthCells or map.width)) or 0
    local h = tonumber(map and (map.heightCells or map.height)) or 0
    if w < 3 or h < 3 or type(map.isWalkableCell) ~= "function" then return out end

    -- Never place an ambient actor on a warp/door cell.  FireRed's entrance
    -- warps are walkable by design, so a simple walkability test can select a
    -- house doorway and leave the NPC standing directly on the door, which
    -- blocks the player and makes the population look as if the house itself
    -- is broken.  The native map warp table is the authoritative exclusion.
    local warpCells = {}
    for _, wdef in ipairs((map.warps or {})) do
      local wx, wy = tonumber(wdef.x), tonumber(wdef.y)
      if wx and wy then warpCells[tostring(wx) .. ":" .. tostring(wy)] = true end
    end
    for y = 1, h - 2 do
      for x = 1, w - 2 do
        local walk = map:isWalkableCell(x, y)
        local warpCell = warpCells[tostring(x) .. ":" .. tostring(y)]
        local hasNeighbor = true
        local Collision = engine("src.core.game3.collision")
        if Collision and type(Collision.canEnter) == "function" then
          hasNeighbor = false
          for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
            local ok, can = pcall(Collision.canEnter, nil, x + d[1], y + d[2], { fromX = x, fromY = y })
            if ok and can then hasNeighbor = true; break end
          end
        end
        local groundConnected = (groundMask == nil) or groundMask[tostring(x) .. ":" .. tostring(y)]
        if walk and hasNeighbor and groundConnected and not warpCell and not occupied(x, y) then
          out[#out + 1] = { x, y }
        end
      end
    end
    return out
  end

  local function mapDefFor(id)
    local okRuntime, Runtime = pcall(require, "src.core.game3.runtime")
    local g = okRuntime and Runtime and Runtime._game or nil
    local maps = g and g.data and g.data.maps
    return maps and maps[id] or nil
  end

  local function destinationDef(map, warp)
    if not warp then return nil end
    local destId = warp.destMap
    if not destId and warp.mapGroup ~= nil and warp.mapNum ~= nil then
      local okCatalog, Catalog = pcall(require, "src.import.gba.map_catalog")
      if okCatalog and Catalog and type(Catalog.mapIdFor) == "function" then
        local ok, id = pcall(Catalog.mapIdFor, warp.mapGroup, warp.mapNum)
        if ok then destId = id end
      end
    end
    return destId and mapDefFor(destId) or nil
  end

  local function isOutdoorDef(def)
    if not def then return nil end
    local okMoves, FieldMoves = pcall(require, "src.core.game3.field_moves")
    if okMoves and FieldMoves and type(FieldMoves.isOutdoors) == "function" and def.mapType ~= nil then
      local ok, out = pcall(FieldMoves.isOutdoors, def.mapType)
      if ok then return out and true or false end
    end
    return nil
  end

  local function routineDoorCells(ow)
    local map = ow and ow.map
    if not map then return {} end
    local currentOutdoor = not isIndoor(map)
    local out, fallback = {}, {}
    local warpList = map.warps
    if type(warpList) ~= "table" or #warpList == 0 then warpList = map.def and map.def.warps or {} end
    for _, w in ipairs(warpList) do
      local x, y = tonumber(w.x), tonumber(w.y)
      if x and y then
        local dest = destinationDef(map, w)
        local isDestOutdoor = isOutdoorDef(dest)
        local kind = "door"
        local destId = dest and (dest.id or dest.mapId or dest.name)
        if currentOutdoor and isDestOutdoor == true and tostring(destId or ""):upper():find("ROUTE",1,true) then kind = "route" end
        -- Outdoors: only cross-area warps are routine exits. Indoors: every
        -- warp is a usable exit, including indoor-to-indoor stairs/ramps.
        local isExit = (not currentOutdoor) or isDestOutdoor == nil or isDestOutdoor ~= currentOutdoor
        local c = { x=x, y=y, warp=w, kind=kind, route=(kind=="route") }
        if isExit then out[#out + 1] = c end
        fallback[#fallback + 1] = c
      end
    end
    if #out == 0 and #fallback == 0 then
      local Collision = engine("src.core.game3.collision")
      local mw = tonumber(map.widthCells or map.width or 0) or 0
      local mh = tonumber(map.heightCells or map.height or 0) or 0
      if Collision and type(Collision.warpAt) == "function" then
        for yy = 0, mh - 1 do
          for xx = 0, mw - 1 do
            local okW, wv = pcall(Collision.warpAt, xx, yy)
            if okW and wv then out[#out + 1] = {x=xx,y=yy,kind="door",route=false} end
          end
        end
      end
    end

    -- Outdoor route connections are exits/entrances even when there is no
    -- explicit warp object at the edge.
    if currentOutdoor and map.def and type(map.def.connections) == "table" then
      local dirs = { north="up", south="down", east="right", west="left" }
      local w = tonumber((map.def.midLayout and map.def.midLayout.width) or map.def.width or map.widthCells or map.width or 0) or 0
      local h = tonumber((map.def.midLayout and map.def.midLayout.height) or map.def.height or map.heightCells or map.height or 0) or 0
      for name, dir in pairs(dirs) do
        local conn = map.def.connections[name]
        local dest = type(conn)=="table" and (conn.map or conn.mapId) or conn
        if dest and w>0 and h>0 then
          local x,y
          if dir=="up" then x,y=math.floor((w-1)/2),0 elseif dir=="down" then x,y=math.floor((w-1)/2),h-1
          elseif dir=="left" then x,y=0,math.floor((h-1)/2) else x,y=w-1,math.floor((h-1)/2) end
          if type(map.isWalkableCell)=="function" then
            local ok,walk=pcall(map.isWalkableCell,map,x,y)
            if ok and walk then out[#out+1]={x=x,y=y,kind="route",route=true,connection=true,destMap=dest,conn=conn} end
          end
        end
      end
    end
    return #out > 0 and out or fallback
  end

  local function interiorCell(ow, door)
    local map=ow and ow.map
    if not map or not door then return nil end
    for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
      local x,y=door.x+d[1],door.y+d[2]
      local warp=false
      if type(map.warpAt)=="function" then local ok,v=pcall(map.warpAt,map,x,y); warp=ok and v~=nil end
      if not warp and type(map.isWalkableCell)=="function" then
        local ok,v=pcall(map.isWalkableCell,map,x,y)
        if ok and v and not occupied(x,y) then return x,y end
      end
    end
    return door.x,door.y
  end

  local function chooseReplacementDoor(ow, oldX, oldY, avoidX, avoidY)
    local doors = routineDoorCells(ow)
    local candidates = {}
    for _, d in ipairs(doors) do
      if (d.x ~= oldX or d.y ~= oldY) and (avoidX == nil or d.x ~= avoidX or d.y ~= avoidY) then
        local blocked = occupied(d.x, d.y)
        if not blocked then
          local player = nil
          local okPlayer, Player = pcall(require, "src.core.game3.player")
          if okPlayer and Player then player = Player end
          if not player or player.cellX ~= d.x or player.cellY ~= d.y then
            candidates[#candidates + 1] = d
          end
        end
      end
    end
    if #candidates == 0 then
      for _, d in ipairs(doors) do
        if (avoidX == nil or d.x ~= avoidX or d.y ~= avoidY) and not occupied(d.x, d.y) then candidates[#candidates + 1] = d end
      end
    end
    -- Some interior maps (including single-entrance houses) legitimately have
    -- only one doorway. In that case the population still has to be maintained:
    -- the replacement enters from that same doorway after the previous actor
    -- disappears. When two or more doors exist, the old door is always excluded.
    if #candidates == 0 and #doors > 0 then
      local d = doors[math.random(1, #doors)]
      if d.x ~= oldX or d.y ~= oldY then
        candidates[#candidates + 1] = d
      else
        candidates[#candidates + 1] = d
      end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
  end

  -- Native FRLG civilian graphics IDs.  These are all ordinary human
  -- OBJ_EVENT_GFX_* entries from the engine's gfx_ids table; using the real
  -- numeric IDs lets FireRed's renderer show the authored FRLG sprite art.
  -- Keep story-only/player graphics out so ambient NPCs have variety without
  -- impersonating Red/Blue/Oak/Bill/Mom.
  local HUMAN_GFX = {
    16, 17, 18, 19, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32, 33, 35,
    39, 40, 41, 42, 48, 54, 55, 56, 57, 61, 62, 64, 65, 68, 69,
  }

  local function humanSprite(seed)
    local n = tonumber(seed) or serial + 1
    if #HUMAN_GFX == 0 then return 0 end
    return HUMAN_GFX[((n * 37) % #HUMAN_GFX) + 1]
  end

  local function newObject(x, y, sprite, graphicsId, isPokemon, speciesNameOverride)
    local Objects = engine("src.core.game3.objects")
    if not Objects or type(Objects.addObject) ~= "function" then return nil end
    serial = serial + 1
    local lid = 0x6000 + serial
    while Objects._byId and Objects._byId[lid] do lid = lid + 1 end

    -- FireRed's native EventObject constructor is private.  Do not hand-build
    -- a fake live actor: append a real object definition to the active
    -- template list and let Objects.addObject() run the engine's constructor.
    -- That resolves graphics IDs, elevation, movement fields, visibility,
    -- collision state, and renderer bookkeeping exactly like a ROM object.
    local def = {
      localId = lid, index = lid,
      name = "KANTO_LIFE_FR_AMBIENT_" .. tostring(lid),
      sprite = sprite, graphicsId = graphicsId,
      x = x, y = y, movement = "STAY", range = "DOWN", movementType = 0x08,
      -- Field.interact only enters the NPC-talk path when scriptKey is present.
      -- This is a Kanto Life marker; FireRedInteractions consumes it before
      -- the native script VM, so it never needs to point at a ROM script.
      scriptKey = "KANTO_LIFE_AMBIENT_TALK",
      movementType = gameLayout() == "frlg" and 0x08 or nil,
      radius = { x = 1, y = 1 }, flag = 0,
      passable = false,
      kantoLifeAmbient = true,
      kantoLifePokemon = isPokemon == true,
      kantoLifeSpecies = speciesNameOverride or GFX_SPECIES[graphicsId],
      kantoLifeDisplayName = isPokemon and nil or "TRAINER",
    }
    -- Objects._defs is the ROM event bundle table, not a runtime-owned list.
    -- Never leave an ambient definition in it: doing so makes every later
    -- map reload see yesterday's spawned actors and the population grows on
    -- repeated enter/exit cycles.  Temporarily expose the definition only
    -- while addObject constructs the live EventObject, then remove it again.
    Objects._defs = Objects._defs or {}
    local defs = Objects._defs
    local insertedAt = #defs + 1
    defs[insertedAt] = def
    local ok = Objects.addObject(lid)
    table.remove(defs, insertedAt)
    if not ok then
      return nil
    end
    local eo = Objects._byId[lid]
    if not eo then return nil end
    eo.kantoLifeAmbient = true
    eo.kantoLifePokemon = isPokemon == true
    eo.kantoLifeSpecies = speciesNameOverride or GFX_SPECIES[graphicsId]
    eo.kantoLifeDisplayName = isPokemon and nil or "TRAINER"
    spawned[lid] = true
    return eo
  end

  function api:rebuild(force)
    local ow = world()
    if not ow or not ow.map then return end
    local map = ow.map
    local mapId = map.gen3Id or map.id
    if not force and mapId == lastMap then return end
    clear()

    local indoor = isIndoor(ow.map)
    local extra = opt("firered_extra_npcs", true) ~= false
      and math.max(0, math.floor(tonumber(opt("firered_extra_npc_count", 0)) or 0)) or 0
    local indoorEnabled = opt("firered_indoor_npcs", true) ~= false
    local indoorCount = 0
    if indoor and indoorEnabled then
      indoorCount = math.floor(tonumber(opt("firered_indoor_npc_count", 3)) or 3)
      if indoorCount <= 0 then
        indoorCount = 2
        if type(setOption) == "function" then
          pcall(setOption, "firered_indoor_npc_count", 2)
        end
      end
    end

    local wantHumans = indoor and indoorCount or extra
    local pokeEnabled = opt("firered_poke_npcs", false) ~= false
    local wantPoke = pokeEnabled and math.max(0, math.floor(tonumber(opt("firered_poke_npc_count", 0)) or 0)) or 0
    if wantHumans <= 0 and wantPoke <= 0 then return end

    local cells = candidateCells(ow)
    if #cells == 0 then
      -- Map.entered can fire before the collision grid/field atlas finishes
      -- binding. Do not mark the map complete; the next world tick retries.
      lastMap = nil
      return
    end
    lastMap = mapId

    local idx = 0
    for i = 1, math.min(wantHumans, #cells) do
      idx = idx + 1
      local c = cells[((idx * 37) % #cells) + 1]
      newObject(c[1], c[2], nil, humanSprite(i), false)
    end

    for i = 1, math.min(wantPoke, math.max(0, #cells - idx)) do
      idx = idx + 1
      local c = cells[((idx * 53) % #cells) + 1]
      local water = false
      local Collision = engine("src.core.game3.collision")
      if Collision and type(Collision.isWater) == "function" then
        local ok, yes = pcall(Collision.isWater, c[1], c[2]); water = ok and yes or false
      end
      local pick, species = choosePokemonGfx(mapId, map, water)
      newObject(c[1], c[2], nil, pick, true, species)
    end
  end

  function api:markPokemonBattle(npc, species)
    if type(npc) ~= "table" or not npc.kantoLifePokemon then return false end
    pendingPokemonBattle = {
      localId = tonumber(npc.localId or (npc.def and npc.def.localId)),
      species = species,
    }
    return true
  end

  function api:handleBattleEnded(result)
    local pending = pendingPokemonBattle
    pendingPokemonBattle = nil
    -- A wild Pokémon NPC leaves the overworld when it is caught OR defeated.
    -- Running away / losing leaves the same actor in place.
    if not pending or (result ~= "caught" and result ~= "win") then return false end
    local Objects = engine("src.core.game3.objects")
    if not Objects then return false end
    local old = Objects._byId and Objects._byId[pending.localId]
    if old and old.kantoLifePokemon then
      Objects.removeObject(pending.localId)
      spawned[pending.localId] = nil
    end

    -- Replace the caught Pokémon at a genuinely different open cell. The
    -- old cell is now free, but deliberately exclude it so the replacement
    -- cannot appear to be the same NPC respawning in place.
    local ow = world()
    if not ow or not ow.map then return true end
    local cells = candidateCells(ow)
    local oldX = old and tonumber(old.cellX)
    local oldY = old and tonumber(old.cellY)
    local choices = {}
    for _, c in ipairs(cells) do
      if oldX == nil or c[1] ~= oldX or c[2] ~= oldY then
        choices[#choices + 1] = c
      end
    end
    if #choices == 0 then choices = cells end
    if #choices == 0 then return true end
    local c = choices[math.random(1, #choices)]
    local gid, species = choosePokemonGfx(map.gen3Id or map.id, map, false)
    newObject(c[1], c[2], nil, gid, true, species)
    return true
  end

  function api:handleRoutineExit(npc, exitX, exitY, avoidX, avoidY)
    if type(npc) ~= "table" or npc.kantoLifeAmbient ~= true then return false end
    local ow = world()
    if not ow or not ow.map then return false end
    local oldX, oldY = tonumber(npc.cellX), tonumber(npc.cellY)
    local Objects = engine("src.core.game3.objects")
    if not Objects or type(Objects.removeObject) ~= "function" then return false end
    local lid = tonumber(npc.localId or (npc.def and npc.def.localId))
    if not lid then return false end

    -- Cross-map check: if the door/warp the NPC is exiting through leads to
    -- a DIFFERENT map, record them as a traveler instead of doing same-map
    -- replacement. They will spawn at the paired entrance when the player
    -- enters the destination map.
    local currentMapId = tostring(ow.map.gen3Id or ow.map.id or "")
    do
      local dx, dy = tonumber(exitX) or oldX, tonumber(exitY) or oldY
      local destMapId = nil
      -- Find the door at the exit coordinates and resolve its destination.
      for _, d in ipairs(routineDoorCells(ow)) do
        if d.x == dx and d.y == dy then
          -- Route connections store destMap directly; warps resolve via def.
          destMapId = d.destMap and tostring(d.destMap) or warpDestMapId(d.warp)
          break
        end
      end
      if destMapId and destMapId ~= "" and destMapId ~= currentMapId then
        -- Cross-map exit: record traveler, remove NPC from this map.
        local isPoke = npc.kantoLifePokemon == true
        local gid = tonumber(npc.graphicsId or (npc.def and npc.def.graphicsId))
        travelers[destMapId] = travelers[destMapId] or {}
        table.insert(travelers[destMapId], {
          graphicsId = gid,
          isPoke = isPoke,
          species = npc.kantoLifeSpecies,
          agenda = npc._kantoLifeFRAgenda,
          fromMap = currentMapId,
          timestamp = os.time(),
        })
        pruneTravelers()
        -- Remove the NPC (they went through the door to the other map).
        -- Use the same Objects API as the same-map path below.
        Objects._tracks[lid] = nil
        Objects._byId[lid] = nil
        for i = #Objects._order, 1, -1 do if tonumber(Objects._order[i]) == lid then table.remove(Objects._order, i) break end end
        if Objects._defs then
          for i = #Objects._defs, 1, -1 do
            local d = Objects._defs[i]
            if tonumber(d and (d.localId or d.index)) == lid then table.remove(Objects._defs, i) break end
          end
        end
        spawned[lid] = nil
        local okF, FieldView = pcall(require, "src.core.game3.field_view")
        if okF and FieldView then FieldView._nativeDirty = true end
        return true
      end
      -- Same map, unknown destination, or no door found: fall through to the
      -- existing same-map replacement logic below (unchanged behavior).
    end

    local replacement = chooseReplacementDoor(ow, oldX, oldY, avoidX, avoidY)
    if not replacement then return false end
    local isPoke = npc.kantoLifePokemon == true
    local gid = tonumber(npc.graphicsId or (npc.def and npc.def.graphicsId))
    if isPoke and not gid then gid = POKE_GFX[math.random(1, #POKE_GFX)] end
    if not isPoke and not gid then gid = humanSprite(lid) end

    -- Keep the population intact if the alternate door is usable: create the
    -- replacement first, then remove the departing actor.  If the only valid
    -- doorway is the same cell, remove first so that doorway can be reused.
    local sameDoor = replacement.x == oldX and replacement.y == oldY
    if sameDoor then
      Objects._tracks[lid] = nil
      Objects._byId[lid] = nil
      for i = #Objects._order, 1, -1 do if tonumber(Objects._order[i]) == lid then table.remove(Objects._order, i) break end end
      if Objects._defs then
        for i = #Objects._defs, 1, -1 do
          local d = Objects._defs[i]
          if tonumber(d and (d.localId or d.index)) == lid then table.remove(Objects._defs, i) break end
        end
      end
      spawned[lid] = nil
    end

    local spawnX, spawnY = interiorCell(ow, replacement)
    local replacementNpc = newObject(spawnX or replacement.x, spawnY or replacement.y, nil, gid, isPoke, npc.kantoLifeSpecies)
    if not replacementNpc then
      -- Do not silently lose a population member. If we had not removed the
      -- old actor yet it remains in place; same-door fallback is the only case
      -- where it was necessarily removed first.
      if sameDoor then
        local restored = newObject(oldX, oldY, nil, gid, isPoke)
        return restored ~= nil
      end
      return false
    end

    if not sameDoor then
      Objects._tracks[lid] = nil
      Objects._byId[lid] = nil
      for i = #Objects._order, 1, -1 do if tonumber(Objects._order[i]) == lid then table.remove(Objects._order, i) break end end
      if Objects._defs then
        for i = #Objects._defs, 1, -1 do
          local d = Objects._defs[i]
          if tonumber(d and (d.localId or d.index)) == lid then table.remove(Objects._defs, i) break end
        end
      end
      spawned[lid] = nil
    end
    replacementNpc.frozen = false
    replacementNpc.hidden = false
    replacementNpc.visible = true
    replacementNpc.moving = false
    replacementNpc.scriptBusy = false
    replacementNpc._kantoLifeRoutineArrival = true
    replacementNpc._kantoLifeFRForceRoutine = true
    replacementNpc._kantoLifeFRArrivalDoorX = replacement.x
    replacementNpc._kantoLifeFRArrivalDoorY = replacement.y
    replacementNpc._kantoLifeFRLastDoorX = replacement.x
    replacementNpc._kantoLifeFRLastDoorY = replacement.y
    replacementNpc._kantoLifeFRAnchorX = spawnX or replacement.x
    replacementNpc._kantoLifeFRAnchorY = spawnY or replacement.y
    local okF, FieldView = pcall(require, "src.core.game3.field_view")
    if okF and FieldView then FieldView._nativeDirty = true end
    return true
  end

  -- Spawn pending travelers when the player enters their destination map.
  -- Each traveler appears at the entrance (door/warp) that connects back to
  -- their origin map, creating the paired exit/entry effect. Called from the
  -- map.entered event in FireRedMain.
  function api:spawnTravelers()
    local ow = world()
    if not ow or not ow.map then return end
    local mapId = tostring(ow.map.gen3Id or ow.map.id or "")
    if mapId == "" then return end
    local pending = travelers[mapId]
    if not pending or #pending == 0 then return end
    pruneTravelers()
    pending = travelers[mapId]
    if not pending or #pending == 0 then return end

    -- Build entrance lookup: for each door on THIS map, which map does it
    -- lead to? The traveler came from `fromMap`, so they appear at the door
    -- that connects this map back to fromMap.
    local entrances = {}  -- fromMapId -> {x, y, door}
    for _, d in ipairs(routineDoorCells(ow)) do
      local dest = d.destMap and tostring(d.destMap) or warpDestMapId(d.warp)
      if dest and dest ~= "" and entrances[dest] == nil then
        entrances[dest] = d
      end
    end

    local remaining = {}
    for _, t in ipairs(pending) do
      local entrance = entrances[t.fromMap]
      if entrance then
        -- Spawn adjacent to the entrance (not on top of it), using the same
        -- interiorCell logic as same-map replacements.
        local sx, sy = interiorCell(ow, entrance)
        local npc = newObject(sx or entrance.x, sy or entrance.y, nil,
          t.graphicsId, t.isPoke, t.species)
        if npc then
          npc.frozen = false
          npc.hidden = false
          npc.visible = true
          npc.moving = false
          npc.scriptBusy = false
          npc._kantoLifeRoutineArrival = true
          npc._kantoLifeFRForceRoutine = true
          npc._kantoLifeFRArrivalDoorX = entrance.x
          npc._kantoLifeFRArrivalDoorY = entrance.y
          npc._kantoLifeFRLastDoorX = entrance.x
          npc._kantoLifeFRLastDoorY = entrance.y
          npc._kantoLifeFRAnchorX = sx or entrance.x
          npc._kantoLifeFRAnchorY = sy or entrance.y
          if t.agenda then npc._kantoLifeFRAgenda = true end
          -- EXPERIMENTAL: arrival greeting bubble
          local greetings = {
            "Phew, made it!",
            "Here I am!",
            "What a walk!",
            "Finally here!",
            "Hello there!",
          }
          local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
          npc._kantoLifeCollisionBubbleText = greetings[math.random(1, #greetings)]
          npc._kantoLifeCollisionBubbleUntil = now + 2.5
        else
          remaining[#remaining + 1] = t
        end
      else
        -- No entrance from this origin on the current map layout; keep the
        -- traveler for a later visit (map data may differ by entrance).
        remaining[#remaining + 1] = t
      end
    end
    if #remaining > 0 then travelers[mapId] = remaining
    else travelers[mapId] = nil end
    local okF, FieldView = pcall(require, "src.core.game3.field_view")
    if okF and FieldView then FieldView._nativeDirty = true end
  end

  function api:update()
    local ow = world()
    if not ow or not ow.map then return end
    local map = ow.map
    local mapId = map.gen3Id or map.id
    if mapId ~= lastMap then self:rebuild(true) end
    -- EXPERIMENTAL: proximity greetings — ambient NPCs acknowledge the player
    -- with a brief bubble when walked past (cooldown per NPC).
    -- EXPERIMENTAL: idle behaviors — idle NPCs occasionally change facing or
    -- show a thought bubble.
    pcall(function()
      local Player = engine("src.core.game3.player")
      local Objects = engine("src.core.game3.objects")
      if not Player or not Objects then return end
      local px, py = tonumber(Player.cellX), tonumber(Player.cellY)
      if not px or not py then return end
      local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
      local greetings = {
        "Hey!", "Hi there!", "Hello!", "Yo!", "Hey there!",
        "Morning!", "Afternoon!", "Evening!",
      }
      local idleThoughts = { "...", "Hmm.", "*yawn*", "*stretch*", "La la..." }
      for lid, _ in pairs(spawned) do
        local npc = Objects._byId and Objects._byId[lid]
        if npc and npc.kantoLifeAmbient then
          local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
          if bubbleUntil <= now then
            local nx, ny = tonumber(npc.cellX), tonumber(npc.cellY)
            if nx and ny then
              local dist = math.abs(nx - px) + math.abs(ny - py)
              if dist <= 3 and dist > 0 then
                local lastGreet = tonumber(npc._kantoLifeLastGreet) or 0
                if now - lastGreet > 30 then
                  npc._kantoLifeLastGreet = now
                  npc._kantoLifeCollisionBubbleText = greetings[math.random(1, #greetings)]
                  npc._kantoLifeCollisionBubbleUntil = now + 2.0
                end
              end
            end
          end
          -- Idle behavior: only when standing still
          if not npc.moving then
            local lastIdle = tonumber(npc._kantoLifeLastIdle) or 0
            if now - lastIdle > 25 + math.random() * 20 then
              npc._kantoLifeLastIdle = now
              if math.random() < 0.7 then
                -- Turn to face a random direction
                if npc.setDirection then pcall(npc.setDirection, npc, math.random(0, 3)) end
              else
                if bubbleUntil <= now then
                  npc._kantoLifeCollisionBubbleText = idleThoughts[math.random(1, #idleThoughts)]
                  npc._kantoLifeCollisionBubbleUntil = now + 1.5
                end
              end
            end
          end
        end
      end
    end)
  end

  function api:clear() clear(); lastMap = nil end
  return api
end
