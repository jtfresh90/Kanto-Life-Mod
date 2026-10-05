-- Kanto Life / FireRed sleep implementation.
-- FireRed has no Gen1/Gen2 clock, so the DAY SLEEPERS option is treated as
-- the explicit permission for sleeping on FireRed.  When it is OFF there is
-- no native FireRed night state to substitute, so no NPCs are put to sleep.
return function(ctx)
  local mod = ctx.mod
  local getOption = ctx.getOption
  local getWorld = ctx.getWorld
  local getFieldState = ctx.getFieldState
  local api = {}
  local function engine(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
  end
  local sleeping = setmetatable({}, { __mode = "k" })
  local sleepList = {}
  local lastMap = nil
  local installedDraw = false
  local imageCache = {}
  local grayShader = nil

  local function opt(key, default)
    if type(getOption) == "function" then
      local ok, v = pcall(getOption, key, default)
      if ok and v ~= nil then return v end
    end
    local ok, v = pcall(mod.options.get, mod.options, key)
    if ok and v ~= nil then return v end
    return default
  end

  local function hash(npc)
    local d = npc and npc.def or {}
    local s = table.concat({
      tostring(npc and (npc.localId or npc.id) or ""),
      tostring(d.graphicsId or d.graphics or d.sprite or ""),
      tostring(npc and npc.cellX or 0), tostring(npc and npc.cellY or 0),
    }, ":")
    local h = 2166136261
    for i = 1, #s do
      h = (h * 16777619 + s:byte(i)) % 2147483647
    end
    return h % 10000
  end

  local function isFollower(npc)
    if not npc then return false end
    if npc.pikachuFollower or npc.isFollower or npc.follower or npc.pokemonFollower
       or npc.partyFollower or npc.followingPlayer or npc.followsPlayer
       or npc.isCompanion or npc.companion then return true end
    local d = npc.def or {}
    return d.follower or d.isFollower or d.pokemonFollower or d.partyFollower
      or d.isCompanion or d.companion or false
  end

  local function eligible(npc)
    if not npc or npc.localId == 0xFF then return false end
    if isFollower(npc) then return false end
    if npc.isPlayer or npc.role == "player" then return false end
    if npc.item or (npc.def and npc.def.item) then return false end
    if npc.trainerType and tonumber(npc.trainerType) and tonumber(npc.trainerType) ~= 0 then return false end
    local d = npc.def or {}
    if d.player or d.isPlayer or d.item then return false end
    if d.trainer or d.isTrainer or d.story or d.isStory then return false end
    if tostring(npc.sprite or ""):upper():find("POKE_BALL", 1, true) then return false end
    return true
  end

  local function world()
    return type(getFieldState) == "function" and getFieldState() or nil
  end

  -- FireRed/Game3 does not expose an `ow.npcs` array.  Its authoritative
  -- live actors are the EventObjects owned by src.core.game3.objects.
  local function actors()
    local Objects = engine("src.core.game3.objects")
    if not Objects then return {} end
    local out = {}
    for _, lid in ipairs(Objects._order or {}) do
      local npc = Objects._byId and Objects._byId[lid]
      if npc then out[#out + 1] = npc end
    end
    return out
  end

  local function clearOne(npc)
    if not npc then return end
    local old = sleeping[npc]
    if not old then return end
    npc.frozen = old.frozen
    npc.moving = false
    npc.scriptBusy = old.scriptBusy
    if old.range ~= nil and npc.def then npc.def.range = old.range end
    npc.kantoLifeSleeping = nil
    npc.kantoLifeSleepAngle = nil
    npc.kantoLifeSleepSide = nil
    if npc.def then npc.def.kantoLifeSleeping = nil end
    -- EXPERIMENTAL: wake-up stretch — NPCs yawn/stretch when they wake up.
    pcall(function()
      local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
      local wakeBubbles = { "*yawn*", "*stretch*", "Mornin'..." }
      local bubbleUntil = tonumber(npc._kantoLifeCollisionBubbleUntil) or 0
      if bubbleUntil <= now then
        npc._kantoLifeCollisionBubbleText = wakeBubbles[math.random(1, #wakeBubbles)]
        npc._kantoLifeCollisionBubbleUntil = now + 2.0
      end
    end)
    sleeping[npc] = nil
  end

  local function stopTrack(npc)
    -- FireRed exposes no public "cancel NPC movement" handle method. The
    -- native object controller owns the track table, so cancel only this
    -- object's current track and leave every other object alone.
    local Objects = engine("src.core.game3.objects")
    if Objects and Objects._tracks and npc and npc.localId then
      Objects._tracks[npc.localId] = nil
    end
  end

  local function putToSleep(npc)
    if not eligible(npc) or sleeping[npc] then return false end
    local old = {
      frozen = npc.frozen,
      scriptBusy = npc.scriptBusy,
      range = npc.def and npc.def.range or nil,
      x = tonumber(npc.cellX) or 0,
      y = tonumber(npc.cellY) or 0,
    }
    sleeping[npc] = old
    npc.kantoLifeSleeping = true
    if npc.def then npc.def.kantoLifeSleeping = true end
    npc.frozen = true
    npc.scriptBusy = false
    npc.moving = false
    npc.progress = 0
    npc.targetX, npc.targetY = npc.cellX, npc.cellY
    npc.homeX, npc.homeY = npc.cellX, npc.cellY
    npc.px, npc.py = (tonumber(npc.cellX) or 0) * 16, (tonumber(npc.cellY) or 0) * 16
    local sign = (((tonumber(npc.cellX) or 0) + (tonumber(npc.cellY) or 0)) % 2 == 0) and 1 or -1
    npc.kantoLifeSleepAngle = sign * (math.pi / 2)
    npc.kantoLifeSleepSide = sign
    if npc.def then npc.def.range = "DOWN" end
    stopTrack(npc)
    return true
  end

  local function targetCount(candidates)
    local pct = math.floor(tonumber(opt("firered_sleep_pct", 10)) or 10)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return math.floor((#candidates * pct / 100) + 0.5)
  end

  local function destinationIsIndoor(map, warp)
    if not map or not warp then return false end
    local destId = warp.destMap
    if not destId and warp.mapGroup ~= nil and warp.mapNum ~= nil then
      local okCat, Catalog = pcall(require, "src.import.gba.map_catalog")
      if okCat and Catalog and type(Catalog.mapIdFor) == "function" then
        local ok, id = pcall(Catalog.mapIdFor, warp.mapGroup, warp.mapNum)
        if ok then destId = id end
      end
    end
    if not destId then return false end
    local okRuntime, Runtime = pcall(require, "src.core.game3.runtime")
    local g = okRuntime and Runtime and Runtime._game or nil
    local def = g and g.data and g.data.maps and g.data.maps[destId]
    if not def then return false end
    local okMoves, FieldMoves = pcall(require, "src.core.game3.field_moves")
    if okMoves and FieldMoves and type(FieldMoves.isOutdoors) == "function" then
      local ok, out = pcall(FieldMoves.isOutdoors, def and def.mapType)
      if ok then return not out end
    end
    return tostring(def.mapType) == "8"
  end

  local function sleepSafeMask(ow)
    local map = ow and ow.map
    if not map or type(map.isWalkableCell) ~= "function" then return nil, {}, {} end
    local w = tonumber(map.widthCells or map.width) or 0
    local h = tonumber(map.heightCells or map.height) or 0
    local warpCells, roofZones = {}, {}
    for _, wd in ipairs(map.warps or {}) do
      local x, y = tonumber(wd.x), tonumber(wd.y)
      if x and y then
        warpCells[tostring(x) .. ":" .. tostring(y)] = true
        -- For outdoor maps, a warp into an indoor map is a building entrance.
        -- FireRed house/center roofs sit immediately behind that entrance.
        -- Keep a conservative footprint around the building side only; this
        -- avoids the roof without banning the surrounding public walkway.
        if map:isOutdoor() and destinationIsIndoor(map, wd) then
          roofZones[#roofZones + 1] = { x = x, y = y, r = 5 }
        end
      end
    end

    local allowed = nil
    return allowed, warpCells, roofZones
  end

  local function sleepEligibleAt(npc, ow, allowed, warpCells, roofZones)
    if not npc or not ow or not ow.map then return false end
    local x, y = tonumber(npc.cellX), tonumber(npc.cellY)
    if not x or not y then return false end
    if warpCells[tostring(x) .. ":" .. tostring(y)] then return false end
    if allowed and not allowed[tostring(x) .. ":" .. tostring(y)] then return false end
    for _, z in ipairs(roofZones or {}) do
      -- Only the cells at/behind the building entrance are protected. The
      -- public space in front of the door remains a valid sleep location.
      if math.abs(x - z.x) <= z.r and y <= z.y and y >= z.y - z.r then
        return false
      end
    end
    local gid = tonumber(npc.graphicsId or (npc.def and npc.def.graphicsId) or (npc.def and npc.def.graphics))
    if gid == 92 or gid == 95 or gid == 96 or gid == 97 then return false end
    return true
  end

  local function rebuild(force)
    local ow = world()
    if not ow then return end
    local map = ow.map
    local mapId = map and (map.gen3Id or map.id)
    if not force and mapId == lastMap then return end
    lastMap = mapId

    for i = #sleepList, 1, -1 do clearOne(sleepList[i]); sleepList[i] = nil end
    if not opt("firered_sleeping_npcs", true) then return end
    if not opt("firered_day_sleepers", true) then return end

    local allowed, warpCells, roofZones = sleepSafeMask(ow)
    local candidates = {}
    for _, npc in ipairs(actors()) do
      if eligible(npc) and sleepEligibleAt(npc, ow, allowed, warpCells, roofZones) then
        candidates[#candidates + 1] = npc
      end
    end
    table.sort(candidates, function(a, b)
      local ha, hb = hash(a), hash(b)
      if ha == hb then return tostring(a.localId or "") < tostring(b.localId or "") end
      return ha < hb
    end)

    local want = targetCount(candidates)
    for i = 1, want do
      if putToSleep(candidates[i]) then sleepList[#sleepList + 1] = candidates[i] end
    end
  end

  local function spriteFor(game, npc)
    local okO, Ow = pcall(require, "src.core.game3.ow_sprites")
    if okO and Ow and Ow.ready and Ow.ready() and npc.graphicsId ~= nil then
      local spr = Ow.getDraw(npc.graphicsId)
      if spr then
        local frame, flip = Ow.pose(spr, npc.facing or "down", 0, false)
        local q = spr.quads and spr.quads[frame]
        if q then return spr.image, q, spr.width, spr.height, flip end
      end
    end

    local data = game and game.data
    local sprites = data and (data.gen2Sprites or data.sprites)
    local def = sprites and sprites[npc.sprite]
    if not def then return nil end
    local okR, Renderer = pcall(require, "src.render.SpriteRenderer")
    if not okR or not Renderer then return nil end
    local sr = Renderer.new(def, tostring(npc.localId or npc.sprite))
    local f = ({ down = 0, up = 1, left = 2, right = 2 })[npc.facing or "down"] or 0
    return sr.image, sr.frames and sr.frames[f], sr.frameWidth, sr.frameHeight,
      (npc.facing == "right")
  end

  local accessoryCache = {}
  local function accessoryImage(style)
    style = math.floor(tonumber(style) or 0)
    if style == 0 then return nil end
    local names = {[1]="sleep_tent.png",[2]="sleeping_bag.png",[3]="sleep_bed.png"}
    local rel = names[style]; if not rel then return nil end
    if accessoryCache[rel] then return accessoryCache[rel] end
    local path = rel
    local ok, img = false, nil
    -- Prefer the mod asset cache API. This is the engine-supported way to
    -- resolve bundled art and avoids a generation-specific 2D/voxel path
    -- mismatch. Keep the old path fallback for older runtimes.
    if mod.assets and type(mod.assets.image) == "function" then
      ok, img = pcall(mod.assets.image, mod.assets, "assets/" .. rel)
    end
    if not ok or not img then
      if mod.assets and type(mod.assets.path) == "function" then path = mod.assets:path("assets/" .. rel) end
      ok, img = pcall(love.graphics.newImage, path)
    end
    if ok and img then img:setFilter("nearest","nearest"); accessoryCache[rel]=img; return img end
    mod.log:warn("Kanto Life: could not load FireRed sleep prop %s", tostring(rel))
    return nil
  end

  local function makeSleepImage(key, image, quad, fw, fh, flip)
    local cached = imageCache[key]
    if cached then return cached end
    if not (love and love.graphics and love.graphics.newCanvas) then return nil end
    fw, fh = tonumber(fw) or 16, tonumber(fh) or 16
    if fw < 1 or fh < 1 then return nil end
    local style = math.floor(tonumber(opt("firered_sleep_style")) or 0)
    -- Default is kept on the original 1.2.29 path exactly.
    if style == 0 then
      local canvas = love.graphics.newCanvas(fh, fw)
      local previous = love.graphics.getCanvas()
      love.graphics.setCanvas(canvas); love.graphics.clear(0,0,0,0); love.graphics.setColor(1,1,1,1)
      if not grayShader and love.graphics.newShader then
        local ok, shader = pcall(love.graphics.newShader, [[
          vec4 effect(vec4 color, Image tex, vec2 uv, vec2 px) {
            vec4 c = Texel(tex, uv) * color;
            float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
            return vec4(g, g, g, c.a);
          }
        ]]); if ok then grayShader = shader end
      end
      if grayShader then love.graphics.setShader(grayShader) end
      love.graphics.push(); love.graphics.translate(fh/2,fw/2); love.graphics.rotate((flip and -1 or 1)*math.pi/2); love.graphics.translate(-fw/2,-fh/2)
      if quad then love.graphics.draw(image,quad,0,0) else love.graphics.draw(image,0,0) end
      love.graphics.pop(); love.graphics.setShader(); love.graphics.setCanvas(previous); love.graphics.setColor(1,1,1,1)
      imageCache[key]=canvas; return canvas
    end
    local accessory = accessoryImage(style)
    local canvas = love.graphics.newCanvas(24,24)
    local previous = love.graphics.getCanvas()
    love.graphics.setCanvas(canvas); love.graphics.clear(0,0,0,0); love.graphics.setColor(1,1,1,1)
    if not grayShader and love.graphics.newShader then
      local ok, shader = pcall(love.graphics.newShader, [[
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 px) {
          vec4 c = Texel(tex, uv) * color;
          float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
          return vec4(g, g, g, c.a);
        }
      ]]); if ok then grayShader = shader end
    end
    local angle=(flip and -1 or 1)*math.pi/2
    -- Keep the sleeper itself exactly as before: rotated and grayscale.
    if grayShader then love.graphics.setShader(grayShader) end
    love.graphics.push(); love.graphics.translate(12,12); love.graphics.rotate(angle); love.graphics.translate(-fw/2,-fh/2)
    if quad then love.graphics.draw(image,quad,0,0) else love.graphics.draw(image,0,0) end
    love.graphics.pop()
    love.graphics.setShader()
    -- The prop is a foreground cover with a transparent head opening.
    if accessory then
      love.graphics.setColor(1,1,1,1)
      local aw,ah=accessory:getDimensions()
      local shiftX = style == 1 and 0 or (-math.sin(angle) * 6.5)
      love.graphics.push(); love.graphics.translate(12 + shiftX,12)
      if style ~= 1 then love.graphics.rotate(angle) end
      love.graphics.translate(-aw/2,-ah/2)
      love.graphics.draw(accessory,0,0); love.graphics.pop()
    end
    love.graphics.setCanvas(previous); love.graphics.setColor(1,1,1,1)
    imageCache[key]=canvas; return canvas
  end

  local function drawSleepers(game, camX, camY)
    if opt("firered_sleep_bubbles", true) == false and #sleepList == 0 then return end
    local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
    for _, npc in ipairs(sleepList) do
      if sleeping[npc] and npc.visible ~= false and npc.hidden ~= true then
        local image, quad, fw, fh, flip = spriteFor(game, npc)
        if image then
          local style = math.floor(tonumber(opt("firered_sleep_style")) or 0)
          local key = tostring(npc.graphicsId or npc.sprite or "") .. ":" .. tostring(npc.facing or "down") .. ":" .. tostring(fw) .. ":" .. tostring(fh) .. ":style" .. tostring(style)
          local sleepImg = makeSleepImage(key, image, quad, fw, fh, flip)
          if sleepImg then
            local iw, ih = sleepImg:getDimensions()
            local baseX = (tonumber(npc.px) or (npc.cellX or 0) * 16) - camX + 8
            local baseY = (tonumber(npc.py) or (npc.cellY or 0) * 16) - camY + 8
            local sx = baseX - iw / 2
            local sy = baseY - ih / 2
            if style == 0 then sy = (tonumber(npc.py) or (npc.cellY or 0) * 16) - camY + 16 - ih end
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(sleepImg, math.floor(sx + 0.5), math.floor(sy + 0.5))

            if opt("firered_sleep_bubbles", true) then
              local phase = (t * 1.1 + hash(npc) * 0.013) % 2.4
              local rise = phase * 5
              local alpha = math.max(0.25, 1 - phase / 2.4)
              local zx = math.floor((tonumber(npc.px) or npc.cellX * 16) - camX + 6)
              local zy = math.floor((tonumber(npc.py) or npc.cellY * 16) - camY - 2 - rise)
              love.graphics.setColor(1, 1, 1, alpha)
              love.graphics.print("Z", zx, zy, 0, 0.65, 0.65)
              love.graphics.setColor(1, 1, 1, 1)
            end
          end
        end
      end
    end
  end

  local function installDrawWrapper()
    if installedDraw then return end
    local okF, FieldView = pcall(require, "src.core.game3.field_view")
    if not okF or not FieldView or type(FieldView.draw) ~= "function" then return end
    local original = FieldView.draw
    FieldView.draw = function(game, canvasW, canvasH, opts)
      local hidden = {}
      for _, npc in ipairs(sleepList) do
        if sleeping[npc] then
          hidden[#hidden + 1] = { npc, npc.visible, npc.hidden }
          npc.visible = false
          npc.hidden = true
        end
      end
      local ok, err = pcall(original, game, canvasW, canvasH, opts)
      for _, row in ipairs(hidden) do
        row[1].visible, row[1].hidden = row[2], row[3]
      end
      if not ok then error(err, 0) end

      local Runtime = engine("src.core.game3.runtime")
      local P = engine("src.core.game3.player")
      local Display = engine("src.core.game3.display")
      local px = P and P.px or 0
      local py = P and P.py or 0
      local w = canvasW or (Display and Display.W) or 240
      local h = canvasH or (Display and Display.H) or 160
      local camX = math.floor(px + 8 - w / 2)
      local camY = math.floor(py + 8 - h / 2)
      if FieldView.cameraPanX then camX = camX + FieldView.cameraPanX end
      if FieldView.cameraPanY then camY = camY + FieldView.cameraPanY end
      drawSleepers(game, camX, camY)
    end
    installedDraw = true
  end

  -- Battle Art/Porygonal consumes the voxel world after FieldView has drawn.
  -- FireRed's 2D sleep wrapper therefore cannot carry a tent/bed/bag into the
  -- voxel pass by itself.  Publish the selected prop as a projected ground
  -- decal in the same final world-present stage.
  local voxelPropInstalled = false
  local function installVoxelSleepProps()
    if voxelPropInstalled then return end
    local battle = nil
    if type(mod.find) == "function" then
      for _, id in ipairs({"BATTLE_ART_VOXEL_FORK", "BATTLE_ART_VOXEL"}) do
        local ok, m = pcall(mod.find, id)
        if ok and m then battle = m; break end
      end
    end
    local lib = battle and battle.exports and battle.exports.lib
    if not (lib and type(lib.require) == "function") then return end
    local okV, Voxel3D = pcall(lib.require, "Voxel3D")
    local okS, VoxelScene = pcall(lib.require, "VoxelScene")
    local Pipelines = engine("src.render.Pipelines")
    if not (okV and Voxel3D and type(Voxel3D.project) == "function" and Pipelines and type(Pipelines.worldPresent) == "function") then return end
    local base = Pipelines.worldPresent
    Pipelines.worldPresent = function(canvas, ctx)
      local out = base(canvas, ctx)
      local id = nil
      if type(Pipelines.worldPipeline) == "function" then
        local ok, v = pcall(Pipelines.worldPipeline); if ok then id = v end
      end
      if id ~= "voxel" or not out then return out end
      local style = math.floor(tonumber(opt("firered_sleep_style")) or 0)
      if style == 0 then return out end
      local prop = accessoryImage(style)
      if not prop then return out end
      local prev = love.graphics.getCanvas()
      if not pcall(love.graphics.setCanvas, out) then return out end
      local iw, ih = 1, 1
      if type(Voxel3D.size) == "function" then
        local a,b = Voxel3D.size(); if tonumber(a) and a > 0 then iw=a end; if tonumber(b) and b > 0 then ih=b end
      end
      local ow = out.getWidth and out:getWidth() or iw
      local oh = out.getHeight and out:getHeight() or ih
      local sxRatio, syRatio = ow/iw, oh/ih
      local ground = 0
      for _, npc in ipairs(sleepList) do
        if sleeping[npc] and npc.visible ~= false then
          local px = tonumber(npc.px or npc.cellX*16) or 0
          local py = tonumber(npc.py or npc.cellY*16) or 0
          local gh = 0
          if okS and VoxelScene and type(VoxelScene.groundAt) == "function" then
            local Map = engine("src.core.game3.map")
            local mapId = Map and Map.current
            local okH, h = pcall(VoxelScene.groundAt, mapId and (ctx and ctx.state and ctx.state.map), npc.cellX, npc.cellY)
            if okH and type(h) == "number" then gh=h end
          end
          local okP, x, y, perspective = pcall(Voxel3D.project, px+8, gh, py+8)
          if okP and x and y then
            perspective = math.max(0.35, math.min(3.0, tonumber(perspective) or 1))
            local scale = (tonumber(ctx and ctx.scale) or 1) * perspective * sxRatio
            local pw, ph = prop:getDimensions()
            love.graphics.push("all")
            love.graphics.setColor(1,1,1,1)
            local angle = (npc.kantoLifeSleepAngle or (math.pi/2))
            love.graphics.draw(prop, x*sxRatio, y*syRatio, angle, scale, scale, pw/2, ph/2)
            love.graphics.pop()
          end
        end
      end
      pcall(love.graphics.setCanvas, prev)
      return out
    end
    voxelPropInstalled = true
    mod.log:info("Kanto Life: FireRed/Gen3 voxel sleep props installed")
  end

  function api:rebuild(force) rebuild(force and true or false) end
  function api:wakeAll()
    for i = #sleepList, 1, -1 do clearOne(sleepList[i]); sleepList[i] = nil end
  end
  -- EXPERIMENTAL: lets other modules (e.g. ambient chatter) skip sleepers.
  function api.isSleeping(npc) return npc ~= nil and sleeping[npc] ~= nil end
  function api:update()
    installDrawWrapper()
    installVoxelSleepProps()
    -- Hard-lock every sleeper to the exact cell where sleep was assigned.
    -- This is deliberately reapplied every frame so routines, native object
    -- ticks, or a stale movement track cannot pull a sleeping actor away.
    for npc, old in pairs(sleeping) do
      if npc and old then
        npc.cellX, npc.cellY = old.x, old.y
        npc.homeX, npc.homeY = old.x, old.y
        npc.targetX, npc.targetY = old.x, old.y
        npc.px, npc.py = old.x * 16, old.y * 16
        npc.moving = false
        npc.progress = 0
      end
    end
    local ow = world()
    if not ow then return end
    local map = ow.map
    local id = map and (map.gen3Id or map.id)
    if id ~= lastMap then rebuild(true) end
  end

  return api
end
