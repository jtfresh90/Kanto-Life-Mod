-- FireRed implementation of Kanto Life's progressive ambient NPC dialogue.
-- Isolated from the Gen 1/2 interaction code. Only Kanto Life-owned ambient
-- EventObjects (kantoLifeAmbient=true) are intercepted; vanilla FireRed talk
-- scripts always fall through unchanged.
return function(ctx)
  local mod = ctx.mod
  local getWorld = ctx.getWorld
  local onPokemonBattleStart = ctx.onPokemonBattleStart
  local function engine(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
  end
  local installed = false
  local dialogueSerials = {}
  local GFX_SPECIES = {
    [109]="SNORLAX", [110]="SPEAROW", [111]="CUBONE", [112]="POLIWRATH",
    [113]="CLEFAIRY", [114]="PIDGEOT", [115]="JIGGLYPUFF", [116]="PIDGEY",
    [117]="CHANSEY", [118]="OMANYTE", [119]="KANGASKHAN", [120]="PIKACHU",
    [121]="PSYDUCK", [122]="NIDORAN_F", [123]="NIDORAN_M", [124]="NIDORINO",
    [125]="MEOWTH", [126]="SEEL", [127]="VOLTORB", [128]="SLOWPOKE",
    [129]="SLOWBRO", [130]="MACHOP", [131]="WIGGLYTUFF", [132]="DODUO",
    [133]="FEAROW", [134]="MACHOKE", [135]="LAPRAS", [136]="ZAPDOS",
    [137]="MOLTRES", [138]="ARTICUNO", [139]="MEWTWO", [140]="MEW",
    [141]="ENTEI", [142]="SUICUNE", [143]="RAIKOU", [144]="LUGIA",
    [145]="HO_OH", [146]="CELEBI", [147]="KABUTO", [148]="DEOXYS",
    [149]="DEOXYS", [150]="DEOXYS",
  }

  local function saveGet(key, default)
    if mod.save and type(mod.save.get) == "function" then
      local ok, v = pcall(mod.save.get, mod.save, key)
      if ok and v ~= nil then return v end
    end
    return default
  end
  local function saveSet(key, value)
    if mod.save and type(mod.save.set) == "function" then
      pcall(mod.save.set, mod.save, key, value)
    end
  end

  local function stateKey(npc)
    local def = npc and npc.def or {}
    local mapId = (engine("src.core.game3.map") or {}).current or ""
    local kind = def.kantoLifePokemon and "poke" or "human"
    -- Runtime actors move.  Their cell is not a stable identity; using it
    -- made the conversation counter reset whenever routines moved an NPC.
    local stableId = npc.id or npc.localId or def.localId or def.index or def.name
    return string.format("%s::%s::%s", tostring(mapId), kind, tostring(stableId))
  end

  local function getState(npc)
    local all = saveGet("fireredNpcTalkStates", {})
    if type(all) ~= "table" then all = {} end
    local key = stateKey(npc)
    local st = all[key]
    if type(st) ~= "table" then st = { count = 0 } end
    return st, key, all
  end
  local function putState(key, st, all)
    all[key] = st
    saveSet("fireredNpcTalkStates", all)
  end

  local function runtimeGame()
    local R = engine("src.core.game3.runtime")
    return R and R._game or nil
  end

  local function session()
    local R = engine("src.core.game3.runtime")
    return R and R.getSession and R.getSession()
  end

  local function message(text, done)
    local Message = engine("src.ui.game3.message")
    if not Message then
      local ok, m = pcall(require, "src.ui.game3.message")
      if ok then Message = m end
    end
    if not Message or type(Message.show) ~= "function" then return false end
    Message.show(tostring(text or ""), function()
      if Message.close then Message.close() end
      if done then done() end
      -- The interaction controller may have opened a trade/battle after the
      -- message. Its own completion handlers can leave this set until the UI
      -- is actually done; clearing here is safe for ordinary dialogue.
    end)
    return true
  end

  local function speciesId(name)
    local Compat = engine("src.mods.Gen3Compat")
    if Compat and Compat.speciesId then
      local ok, id = pcall(Compat.speciesId, name)
      if ok and id then return id end
    end
    local Pokemon = engine("src.core.game3.pokemon")
    if Pokemon and Pokemon.speciesFromName then
      local ok, id = pcall(Pokemon.speciesFromName, name)
      if ok and id then return id end
    end
    return tonumber(name)
  end

  local function speciesName(id)
    local Compat = engine("src.mods.Gen3Compat")
    if Compat and Compat.speciesName then
      local ok, n = pcall(Compat.speciesName, id)
      if ok and n then return n end
    end
    local Pokemon = engine("src.core.game3.pokemon")
    if Pokemon and Pokemon.name then
      local ok, n = pcall(Pokemon.name, id)
      if ok and n then return n end
    end
    return tostring(id)
  end

  local function allSpeciesPool()
    local Pokemon = engine("src.core.game3.pokemon")
    if not Pokemon then return {} end
    pcall(function() if Pokemon.ready and not Pokemon.ready() and Pokemon.install then Pokemon.install(Pokemon._cache) end end)
    local names = Pokemon._names
    local out, seen = {}, {}
    if type(names) == "table" then
      for id, name in pairs(names) do
        id = tonumber(id)
        if id and id > 0 and type(name) == "string" and name ~= "" and name ~= "??????????" then
          local meta = Pokemon.speciesMeta and Pokemon.speciesMeta(id) or nil
          if id ~= (Pokemon.SPECIES_EGG or -1) and (not meta or meta.isEgg ~= true) then
            out[#out + 1] = id; seen[id] = true
          end
        end
      end
    end
    if #out == 0 then for i=1,386 do out[#out+1]=i end end
    table.sort(out)
    return out
  end

  local function randomSpeciesId()
    local pool = allSpeciesPool()
    if #pool == 0 then return 1 end
    return pool[math.random(1, #pool)]
  end

  local function lowestPartyLevel(s)
    local lowest = nil
    for _, mon in ipairs((s and s.party) or {}) do
      local lv = tonumber(mon and mon.level)
      if lv and lv > 0 and (lowest == nil or lv < lowest) then lowest = lv end
    end
    return lowest or 5
  end

  local function giftItem(s)
    local ids = { 13, 25, 24, 26, 27, 4, 3, 2, 17, 18, 19, 20, 21 }
    local Bag = engine("src.core.game3.bag") or require("src.core.game3.bag")
    local id = ids[math.random(1, #ids)]
    if not (s and s.bag and Bag and Bag.add) then return false, id end
    local ok = Bag.add(s.bag, id, 1)
    return ok == true, id
  end

  local function itemName(id)
    local Items = engine("src.core.game3.items")
    if not Items then local ok, x = pcall(require, "src.core.game3.items"); if ok then Items=x end end
    if Items and Items.displayName then return Items.displayName(id) end
    return "ITEM"
  end

  local function randomRare()
    return speciesName(randomSpeciesId())
  end

  local function playPokemonCry(species)
    local id = speciesId(species)
    if not id then return false end
    local Audio = engine("src.core.game3.audio")
    if Audio and Audio.playCry then
      local ok = pcall(Audio.playCry, id)
      return ok
    end
    return false
  end

  local function cryMessage(display, species, done)
    -- Pokémon NPCs never get invented conversational dialogue. Their only
    -- spoken line is the species cry, with the native FireRed cry audio.
    -- Start the cry at interaction time, not after the message is dismissed.
    playPokemonCry(species)
    return message(display .. "!", done)
  end

  local function openTrade(npc, st, key, all, display, rare, isPoke, species)
    local s = session()
    local PartyMenu = engine("src.ui.game3.party_menu")
    if not PartyMenu then local ok, x = pcall(require, "src.ui.game3.party_menu"); if ok then PartyMenu=x end end
    if not (s and type(s.party) == "table" and #s.party > 0 and PartyMenu and PartyMenu.show) then
      st.pendingTrade = true
      st.retryAt = (tonumber(st.count) or 0) + 5
      putState(key, st, all)
      return message("Choose a party Pokémon to trade.")
    end
    st.pendingTrade = true
    st.tradeSpecies = rare
    putState(key, st, all)
    local prompt = "Trade for " .. speciesName(speciesId(rare) or rare) .. "?"
    local function openParty()
      PartyMenu.show(s.party, nil, {
        mode = "choose", session = s,
        onSelect = function(slot)
          slot = tonumber(slot)
          local sent = slot and s.party[slot]
          if not sent then
            st.retryAt = (tonumber(st.count) or 0) + 5
            putState(key, st, all)
            releaseActor(npc)
            return message("Trade cancelled.")
          end
          local rid = speciesId(rare)
          local Party = engine("src.core.game3.party")
          local scratch = { party = {}, name = display, trainerId = math.random(0, 65535) }
          local ok, code, received = false, nil, nil
          if Party and Party.giveMon and rid then
            ok, code, received = pcall(Party.giveMon, scratch, rid, tonumber(sent.level) or 10, "")
          end
          if not ok or type(received) ~= "table" then
            st.retryAt = (tonumber(st.count) or 0) + 5
            putState(key, st, all)
            releaseActor(npc)
            return message("The trade failed.\nPlease try again.")
          end
          received.traded = true
          received.ot = display
          received.otId = math.random(0, 65535)
          s.party[slot] = received
          st.event, st.eventDetail = "trade", rare
          st.pendingTrade, st.retryAt = nil, nil
          putState(key, st, all)
          message("Trade complete!\nYou got " .. speciesName(rid) .. "!", function() releaseActor(npc) end)
        end,
      })
    end
    if isPoke then
      return cryMessage(display, species, function() message(prompt, openParty) end)
    end
    return message(display .. ":\n" .. prompt, openParty)
  end

  -- FireRed battle presentation is keyed by trainerId -> trainer class/pic.
  -- Ambient NPCs do not have a ROM trainer record of their own, so choose the
  -- real trainer record whose class corresponds to the NPC's actual overworld
  -- graphics family.  This is resolved from the extracted trainer table at
  -- runtime instead of hard-coding arbitrary trainer ids (which can make every
  -- ambient battle display the same class, e.g. TEAM AQUA).
  local trainerBySprite = {}
  local SPRITE_CLASS = {
    SPRITE_YOUNGSTER = {"YOUNGSTER"},
    SPRITE_LASS = {"LASS"},
    SPRITE_TEACHER = {"LADY", "SCHOOLGIRL", "TEACHER"},
    SPRITE_COOLTRAINER_M = {"COOLTRAINER_M", "COOLTRAINER"},
    SPRITE_COOLTRAINER_F = {"COOLTRAINER_F", "COOLTRAINER"},
    SPRITE_POKEFAN_M = {"POKEFANM", "POKEFAN"},
    SPRITE_ROCKER = {"ROCKER"},
    SPRITE_FISHER = {"FISHERMAN", "FISHER"},
    SPRITE_BEAUTY = {"BEAUTY"},
    SPRITE_GRAMPS = {"GENTLEMAN", "OLD_MALE", "GENTLEMAN"},
    SPRITE_GRANNY = {"LADY", "OLD_FEMALE", "POKEFANF"},
    SPRITE_BLACK_BELT = {"BLACK_BELT"},
    SPRITE_SCIENTIST = {"SCIENTIST"},
    SPRITE_GENTLEMAN = {"GENTLEMAN"},
    SPRITE_SAILOR = {"SAILOR"},
    SPRITE_SUPER_NERD = {"SUPER_NERD"},
  }

  local function trainerIdForNpc(npc)
    local def = npc and npc.def or {}
    local gid = tonumber(npc and npc.graphicsId or def.graphicsId or def.graphics)
    if gid == nil then return 89 end
    local okG, GfxIds = pcall(require, "src.core.game3.scripting.gfx_ids")
    local sprite = okG and GfxIds and GfxIds.spriteFor and GfxIds.spriteFor(gid) or nil
    local cached = sprite and trainerBySprite[sprite]
    if cached then return cached end
    local want = sprite and SPRITE_CLASS[sprite] or nil
    local okT, Trainers = pcall(require, "src.core.game3.scripting.trainers")
    local pack = okT and Trainers and Trainers.pack and Trainers.pack() or nil
    local bestId, bestPic
    if pack and type(pack.trainers) == "table" and want then
      local wanted = {}
      for rank, name in ipairs(want) do wanted[string.upper(name)] = rank end
      for id, row in pairs(pack.trainers) do
        local cn = string.upper(tostring(row.className or ""))
        local rank = wanted[cn]
        if rank then
          if not bestId or rank < bestPic then bestId, bestPic = tonumber(id), rank end
        end
      end
    end
    -- Fall back to a non-team civilian trainer class, never Team Aqua/Magma.
    if not bestId and pack and type(pack.trainers) == "table" then
      for id, row in pairs(pack.trainers) do
        local cn = string.upper(tostring(row.className or ""))
        if cn == "YOUNGSTER" then bestId = tonumber(id); break end
      end
    end
    -- Never guess a numeric trainer id.  A stale fallback id can legitimately
    -- point at TEAM AQUA in a FireRed trainer table.  If the extracted table
    -- is unavailable, refuse the trainer battle rather than show the wrong
    -- opponent presentation.
    if sprite and bestId then trainerBySprite[sprite] = bestId end
    return bestId
  end

  local function fifthEvent(game, npc, st, key, all, isPoke, display, species)
    local kindPool = isPoke and { "item", "battle" } or { "item", "trade", "battle" }
    local last = st.lastKind
    local battleReady = (tonumber(st.lastBattleAt) == nil) or (realNow() - tonumber(st.lastBattleAt) >= 3600)
    local kind
    if isPoke then
      -- Pokémon NPCs alternate item/battle on successive fifth interactions
      -- instead of repeatedly rolling the same item result. A battle is only
      -- suppressed when its real-time one-hour cooldown is active.
      st.fifthIndex = (tonumber(st.fifthIndex) or 0) + 1
      kind = ((st.fifthIndex % 2) == 1) and "item" or "battle"
      if kind == "battle" and not battleReady then kind = "item" end
    else
      local pool = {}
      for _, k in ipairs(kindPool) do
        if k ~= last and (k ~= "battle" or battleReady) then pool[#pool+1] = k end
      end
      if #pool == 0 then
        for _, k in ipairs(kindPool) do if k ~= "battle" or battleReady then pool[#pool+1] = k end end
      end
      if #pool == 0 then pool = { "item" } end
      kind = pool[math.random(1, #pool)]
    end
    st.lastKind = kind

    if kind == "item" then
      local s = session()
      local given, id = giftItem(s)
      st.event, st.eventDetail = "item", id
      st.pendingTrade, st.retryAt = nil, nil
      putState(key, st, all)
      local nice = itemName(id)
      if isPoke then
        return cryMessage(display, species, function()
          message("Received " .. nice .. "!" .. (given and "" or "\nYour BAG is full!"), function() releaseActor(npc) end)
        end)
      end
      return message(display .. ":\nHere, take this\n" .. nice .. "!" .. (given and "" or "\nYour BAG is full!"), function() releaseActor(npc) end)
    elseif kind == "trade" then
      if not isPoke then
        return openTrade(npc, st, key, all, display, randomRare(), false, nil)
      end
      kind = "battle"
    end

    local s = session()
    if not s or type(s.party) ~= "table" or #s.party == 0 then
      if isPoke then
        return cryMessage(display, species, function() message("No PARTY available for a battle.") end)
      end
      return message(display .. ":\nI'd battle you,\nbut you need a PARTY!", function() releaseActor(npc) end)
    end
    local lv = math.max(2, math.min(40, lowestPartyLevel(s) - 10))
    local foeId = randomSpeciesId()
    local foeSpecies = speciesName(foeId)
    st.event, st.eventDetail = "battle", foeSpecies
    st.pendingTrade = nil
    putState(key, st, all)

    if isPoke then
      local world = type(getWorld) == "function" and getWorld() or nil
      if world and world.startWildBattle then
        return cryMessage(display, species, function()
          -- Mark the live actor before the asynchronous battle transition.
          -- The battle-ended event is then able to remove this exact NPC on
          -- a catch or player victory and immediately replenish the population.
          if type(onPokemonBattleStart) == "function" then
            pcall(onPokemonBattleStart, npc, species, foeId)
          end
          local ok = world:startWildBattle(foeId, lv, function(result)
            if result == "win" or result == "caught" then
              message("Battle over!")
            end
          end)
          if ok then st.lastBattleAt = realNow(); putState(key, st, all) end
          if not ok then
            if type(onPokemonBattleStart) == "function" then pcall(onPokemonBattleStart, nil) end
            message("The battle could not start.")
          end
        end)
      end
      return cryMessage(display, species, function() message("The battle could not start.") end)
    end

    local BattleBridge = engine("src.core.game3.battle_bridge")
    if BattleBridge and type(BattleBridge.start) == "function" then
      local foeParty = {}
      local pool = allSpeciesPool()
      for i = 1, math.random(1, 3) do
        local sid = pool[math.random(1, #pool)] or foeId
        foeParty[#foeParty+1] = { species = sid, level = lv }
      end
      local trainerId = trainerIdForNpc(npc)
      if not trainerId then
        return message(display .. ":\nI couldn't identify\nthis trainer.")
      end
      local foe = { trainerId = trainerId, party = foeParty, trainerName = display }
      return message(display .. ":\nHow about a battle?\nMy team is ready!", function()
        local ok = BattleBridge.start(mod, game, foe, {
          wild = false, playerParty = s.party, trainerId = trainerId,
          trainerName = display, session = s,
          onDone = function(result)
            if result == "win" then
              message(display .. ":\nYou're really strong!", function() releaseActor(npc) end)
            else
              releaseActor(npc)
            end
          end,
        })
        if ok then st.lastBattleAt = realNow(); putState(key, st, all) end
        if not ok then
          message(display .. ":\nI couldn't start\nthe battle.", function() releaseActor(npc) end)
        end
      end)
    end
    return message(display .. ":\nI couldn't start\nthe battle.")
  end

  -- Human identities are generated from a large deterministic name bank. The
  -- name is keyed by map + runtime object id, not by a shared fallback, so
  -- spawned civilians do not all become Quinn.
  local MALE_FIRST_NAMES = {
    "Aaron","Adam","Aiden","Alex","Andre","Arthur","Ben","Blake","Bobby","Brady","Brandon","Bryce","Caleb","Cameron","Chad","Chase",
    "Chris","Cole","Colin","Connor","Dakota","Daniel","Darius","David","Dean","Derek","Diego","Drew","Eli","Eric",
    "Ethan","Evan","Felix","Finn","Frank","Gabriel","Gavin","Grant","Harper","Hayden","Henry","Hunter","Ian","Isaac","Jack","Jacob","Jake",
    "James","Jason","Jesse","Joe","Jordan","Jose","Josh","Julian","Keith","Kevin","Kyle","Lance","Leo",
    "Liam","Logan","Lucas","Luke","Marcus","Mark","Mason","Matt","Michael","Nate","Nathan","Nick","Nico","Noah","Owen","Parker","Patrick",
    "Paul","Peter","Ryan","Sam","Scott","Sean","Shane","Shawn","Simon","Spencer","Steven","Theo","Tim","Toby","Travis","Trevor","Tyler","Victor","Wade","Will",
    "William","Wyatt","Xander","Zach"
  }
  local FEMALE_FIRST_NAMES = {
    "Abby","Alice","Amber","Amy","Anna","April","Ari","Aria","Ashley","Avery","Bailey","Bianca","Brenda","Brianna","Brooke","Callie","Cara","Carla",
    "Casey","Cathy","Chloe","Claire","Clara","Courtney","Crystal","Daisy","Daphne","Dawn","Diana","Ella","Ellie","Emily","Emma",
    "Erin","Eva","Faith","Fiona","Gia","Grace","Hailey","Hannah","Hazel","Heidi","Holly","Iris","Isla","Jackie","Jade",
    "Jamie","Jasmine","Jenna","Jenny","Jill","Joan","Joy","Julia","Kara","Karen","Kate","Katie","Kayla","Kelly","Kim","Kira","Laura","Lauren","Leah",
    "Lily","Lucy","Maddie","Mara","Maria","Maya","Megan","Mia","Mila","Molly","Morgan","Nell","Nina","Nora","Paige","Payton","Peyton","Quinn","Rachael","Rae","Riley","Robin","Rosa","Rose","Ruby","Sadie","Samantha",
    "Sara","Sarah","Serena","Sierra","Sofia","Sophie","Stella","Summer","Tara","Taylor","Tiffany","Tina","Valerie","Vanessa","Violet","Wendy","Yara","Zoe"
  }

  local function stableHash(s, modv)
    local h = 2166136261
    for i=1,#s do h = (h * 16777619 + s:byte(i)) % 2147483647 end
    return h % modv
  end

  local function spriteGender(npc, def)
    -- Infer gender from sprite name. Returns "male", "female", or nil if unknown.
    local gid = tonumber(npc and npc.graphicsId or def.graphicsId or def.graphics)
    if not gid then return nil end
    local okG, GfxIds = pcall(require, "src.core.game3.scripting.gfx_ids")
    local sprite = okG and GfxIds and GfxIds.spriteFor and GfxIds.spriteFor(gid) or nil
    if not sprite then return nil end
    local s = string.upper(tostring(sprite))
    -- Female indicators
    if s:find("LASS") or s:find("LADY") or s:find("SCHOOLGIRL") or s:find("BEAUTY")
       or s:find("GRANNY") or s:find("POKEFANF") or s:find("_F") or s:find("FEMALE")
       or s:find("GIRL") or s:find("WOMAN") or s:find("MOM") then
      return "female"
    end
    -- Male indicators
    if s:find("YOUNGSTER") or s:find("POKEFANM") or s:find("GRAMPS") or s:find("GENTLEMAN")
       or s:find("SAILOR") or s:find("FISHER") or s:find("_M") or s:find("MALE")
       or s:find("BOY") or s:find("MAN") or s:find("DAD") then
      return "male"
    end
    return nil
  end

  local function assignedName(npc, def)
    if def.kantoLifeName and def.kantoLifeName ~= "" then return def.kantoLifeName end
    local mapId = (engine("src.core.game3.map") or {}).current or ""
    local raw = tostring(mapId) .. "::" .. tostring(npc and (npc.localId or npc.id or def.localId or def.index or def.name) or "")
    -- Gender-matched first name only (no last names).
    local gender = spriteGender(npc, def)
    local nameList = MALE_FIRST_NAMES
    if gender == "female" then
      nameList = FEMALE_FIRST_NAMES
    elseif gender ~= "male" then
      -- Unknown gender: pick from combined list
      local combined = {}
      for _, n in ipairs(MALE_FIRST_NAMES) do table.insert(combined, n) end
      for _, n in ipairs(FEMALE_FIRST_NAMES) do table.insert(combined, n) end
      nameList = combined
    end
    local h = stableHash(raw, #nameList)
    local name = nameList[(h % #nameList) + 1]
    def.kantoLifeName = name
    return name
  end

  local function displayFor(npc, def, isPoke, species)
    if isPoke then return speciesName(speciesId(species) or species) end
    return assignedName(npc, def)
  end

  local function isRegularNpc(npc)
    local def = npc and npc.def or {}
    if def.kantoLifeAmbient or npc.kantoLifeAmbient or def.kantoLifeRandomDialogue then return true end
    if def.item or def.pokemon or def.trainerId or def.isTrainer or def.trainer then return false end
    if tonumber(def.trainerType) and tonumber(def.trainerType) > 0 then return false end
    if def.story or def.isStory or def.hidden then return false end
    return def.scriptKey ~= nil or def.text ~= nil
  end

  -- The dialogue ledger is global, not per NPC. That is the important
  -- distinction: two different NPCs can never receive the same generated
  -- line until the 2-million+ tuple space has been exhausted.
  local D_SUBJECT = {
    "the market stalls","the riverside path","the bicycle lane","the Pokémon Center porch","the quiet plaza","the flower beds","the fishing dock","the museum steps",
    "the train of carts","the little bridge","the west gate","the east gate","the route sign","the shop awning","the fountain","the lookout",
    "the berry patch","the rocky clearing","the forest trail","the shoreline","the harbor road","the old gatehouse","the town bulletin board","the station platform",
    "the hill path","the grass beside the fence","the cave mouth","the ranger post","the campground","the lighthouse path","the boardwalk","the southern gate"
  }
  local D_ACTIVITY = {
    "counting the supplies in my bag","watching the clouds move over the rooftops","checking whether my Pokémon are ready for another walk","looking for a quiet place to sketch",
    "comparing travel notes with a friend","waiting for a delivery","taking the scenic way home","listening for wild Pokémon nearby",
    "planning tomorrow's route","checking the time before heading out","looking for a good fishing spot","trying to remember where I left my map",
    "practicing a new training routine","watching people come and go","saving up for something useful","taking a break between errands",
    "following a rumor I heard this morning","looking for a familiar face","sorting through a handful of old souvenirs","walking off a big lunch",
    "checking the weather","making a list of places to visit","waiting for the path to clear","thinking about a Pokémon I used to have",
    "keeping an eye on the nearby trail","looking for a shortcut","finishing a small errand","heading toward the next stop","taking notes for a friend","watching the wild Pokémon from a distance","checking a sign I had not noticed before","planning a longer trip"
  }
  local D_POKEMON = {
    "PIKACHU","PIDGEY","RATTATA","SPEAROW","ODDISH","BULBASAUR","CHARMANDER","SQUIRTLE","BUTTERFREE","GEODUDE","ZUBAT","MEOWTH","PSYDUCK","POLIWAG","GROWLITHE","ABRA",
    "MACHOP","BELLSPROUT","TENTACOOL","PONYTA","MAGNEMITE","FARFETCHD","DODUO","GRIMER","GASTLY","VOLTORB","KOFFING","RHYHORN","HORSEA","GOLDEEN","STARYU","DITTO"
  }
  local D_DETAIL = {
    "The timing worked out better than I expected.","I noticed a small detail I had missed before.","It was quieter than usual today.","I think I will remember this stop.",
    "A little patience made the difference.","I changed my plans after seeing that.","It turned into a more interesting trip than I expected.","I should probably write that down.",
    "Someone here gave me a useful tip.","I keep finding new things to notice.","It made me slow down and look around.","I am glad I took the longer way.",
    "That was not what I expected to find.","I have a feeling there is more to discover.","I will probably come back later.","It is nice having somewhere familiar to visit.",
    "The whole place feels different at this hour.","I nearly walked right past it.","That small surprise improved my day.","I have been meaning to check this out for a while.",
    "It is one of those little moments that makes traveling worthwhile.","I learned something useful from watching for a minute.","I am still deciding what to do next.","I did not expect the area to be this busy.",
    "The route feels different every time I pass through.","I am keeping this part of the trip flexible.","I found a better way around the last obstacle.","It is worth taking a second look.",
    "I think my Pokémon noticed it before I did.","That is a story I will probably tell later.","I am glad I stopped instead of rushing past.","There is always another little detail here."
  }
  local D_MAP = {
    "this neighborhood","the local outskirts","the road toward the next town","the coastal side of Kanto","the forest edge","the city center","the quieter residential side",
    "the route beyond the gate","the nearby countryside","the southern road","the northern road","the eastern path","the western path","the lakeside area","the harbor district","the hill above town",
    "the old residential quarter","the market district","the route junction","the trail behind town","the public square","the edge of the forest","the path by the water","the nearby cave system",
    "the road outside the town","the next stretch of route","the area around the station","the outskirts near the gate","the local walking path","the road back home","the nearby settlement","this part of the region"
  }
  local D_TEMPLATES = {
    "I spent some time at %s, then %s. I was thinking about %s while I was there. %s",
    "Earlier I was %s at %s. I noticed %s nearby. %s",
    "If you are heading through %s, you might notice %s. I was %s when I saw it. %s",
    "I took the long way through %s because I was %s. %s I kept thinking about %s.",
    "My plans changed near %s. I was %s, and then I noticed %s. %s",
    "There is something different about %s today. I was %s when I noticed it. %s",
    "I was talking with a friend about %s while walking through %s. %s",
    "I came through %s looking for a quiet spot. I ended up %s instead. %s",
    "You might enjoy %s if you are %s. I found %s there earlier. %s",
    "I have been %s around %s all day. %s The Pokémon I kept seeing was %s.",
    "My favorite part of %s is that you can %s without much trouble. %s",
    "I was %s when I passed %s. It reminded me of %s. %s",
    "I stopped at %s before %s. %s I did not expect to see %s.",
    "Someone told me about %s while I was %s near %s. %s",
    "The route from %s to %s has a nice rhythm to it. I was %s when I noticed that. %s",
    "I am keeping my plans open today. I may %s after I finish at %s. %s",
  }

  local function tupleForSerial(n)
    n = math.max(0, tonumber(n) or 0)
    local a=n%#D_SUBJECT; n=math.floor(n/#D_SUBJECT)
    local b=n%#D_ACTIVITY; n=math.floor(n/#D_ACTIVITY)
    local c=n%#D_POKEMON; n=math.floor(n/#D_POKEMON)
    local d=n%#D_DETAIL; n=math.floor(n/#D_DETAIL)
    local e=n%#D_MAP; n=math.floor(n/#D_MAP)
    local f=n%#D_TEMPLATES
    return D_SUBJECT[a+1],D_ACTIVITY[b+1],D_POKEMON[c+1],D_DETAIL[d+1],D_MAP[e+1],D_TEMPLATES[f+1]
  end

  local function eventReference(st)
    if st.event == "trade" then return "I still remember the trade for " .. tostring(st.eventDetail or "that Pokémon"):gsub("_"," ") .. "." end
    if st.event == "item" then return "I hope the " .. tostring(st.eventDetail or "item"):gsub("_"," ") .. " has been useful." end
    if st.event == "battle" then return "I remember our battle. I changed how I train after that match." end
    return nil
  end

  local function humanDialogue(st, npc)
    local ledger = saveGet("fireredDialogueLedgerV2", {})
    if type(ledger) ~= "table" then ledger = {} end
    local serial = tonumber(ledger.nextSerial) or 0
    -- V2 starts a fresh global sequence so old repetitive V1 state cannot leak
    -- into the new dialogue system.
    ledger.nextSerial = serial + 1
    saveSet("fireredDialogueLedgerV2", ledger)
    local subject, activity, mon, detail, mapName, template = tupleForSerial(serial)
    local ref = eventReference(st)
    local body
    if template == D_TEMPLATES[1] then body=template:format(subject,activity,mon,detail)
    elseif template == D_TEMPLATES[2] then body=template:format(activity,subject,mon,detail)
    elseif template == D_TEMPLATES[3] then body=template:format(mapName,subject,activity,detail)
    elseif template == D_TEMPLATES[4] then body=template:format(subject,activity,detail,mon)
    elseif template == D_TEMPLATES[5] then body=template:format(subject,activity,mon,detail)
    elseif template == D_TEMPLATES[6] then body=template:format(subject,activity,detail)
    elseif template == D_TEMPLATES[7] then body=template:format(mon,subject,detail)
    elseif template == D_TEMPLATES[8] then body=template:format(subject,activity,detail)
    elseif template == D_TEMPLATES[9] then body=template:format(subject,activity,mon,detail)
    elseif template == D_TEMPLATES[10] then body=template:format(activity,mapName,detail,mon)
    elseif template == D_TEMPLATES[11] then body=template:format(subject,activity,detail)
    elseif template == D_TEMPLATES[12] then body=template:format(activity,subject,mon,detail)
    elseif template == D_TEMPLATES[13] then body=template:format(subject,activity,detail,mon)
    elseif template == D_TEMPLATES[14] then body=template:format(subject,activity,mapName,detail)
    elseif template == D_TEMPLATES[15] then body=template:format(subject,mapName,activity,detail)
    else body=template:format(activity,subject,detail) end
    if ref then body = body .. " " .. ref end
    return body
  end

  local function realNow()
    if os and os.time then
      local ok, t = pcall(os.time)
      if ok and tonumber(t) then return tonumber(t) end
    end
    if love and love.timer and love.timer.getTime then return love.timer.getTime() end
    return 0
  end

  local function holdActor(npc, seconds)
    if not npc then return end
    npc._kantoLifeFRTalkHoldUntil = realNow() + (tonumber(seconds) or 30)
    npc._kantoLifeFRTalkPaused = true
  end

  local function releaseActor(npc)
    if not npc then return end
    npc._kantoLifeFRTalkHoldUntil = nil
    npc._kantoLifeFRTalkPaused = nil
  end

  local function progressive(game, npc)
    -- The routine controller honors this flag until the message/event closes.
    -- This prevents an actor from walking through the player while its dialogue
    -- or trade/battle/item UI is active.
    holdActor(npc, 30)
    local def = npc.def or {}
    local st, key, all = getState(npc)
    st.count = (tonumber(st.count) or 0) + 1
    putState(key, st, all)
    local isPoke = def.kantoLifePokemon == true
    local species = def.kantoLifeSpecies
    if isPoke and not species then species = GFX_SPECIES[tonumber(npc.graphicsId or def.graphicsId)] or "PIKACHU" end
    local display = displayFor(npc, def, isPoke, species)

    if npc.kantoLifeSleeping or def.kantoLifeSleeping then
      return message(display .. " is fast asleep!", function() releaseActor(npc) end)
    end

    if st.count % 5 == 0 then
      return fifthEvent(game, npc, st, key, all, isPoke, display, species)
    end

    if isPoke then
      return cryMessage(display, species)
    end

    local line = humanDialogue(st, npc)
    putState(key, st, all)
    return message(display .. ":\n" .. line, function() releaseActor(npc) end)
  end

  local function install()
    if installed or not mod.hooks or not mod.hooks.wrap then return end
    local ok = pcall(function()
      mod.hooks:wrap("world.talk", function(next, a, b)
        local game, npc = a, b
        if type(npc) ~= "table" or not npc.def or not isRegularNpc(npc) then
          return next(a, b)
        end
        local handled = progressive(game, npc)
        if handled then return true end
        return next(a, b)
      end)

      -- Prefix only ordinary human NPC dialogue. The underlying ROM text and
      -- script remain untouched; we only replace the show_text argument with
      -- the resolved original text plus "Name:". This keeps every default
      -- FireRed line, branch, trainer/item behavior, and map script intact.
      mod.hooks:wrap("script.command", function(next, ctx2, name, args)
        if name ~= "show_text" or type(args) ~= "table" then
          return next(ctx2, name, args)
        end
        local npc = ctx2 and ctx2.npc
        if type(npc) ~= "table" or not npc.def or npc.def.kantoLifeAmbient
           or npc.def.kantoLifePokemon or not isRegularNpc(npc) then
          return next(ctx2, name, args)
        end
        local textId = args[1]
        if textId == nil then return next(ctx2, name, args) end
        local text
        if ctx2.game and ctx2.game.data then
          text = ctx2.game.data.text[textId]
          if not text and ctx2.overworld and ctx2.overworld.map then
            text = select(1, ctx2.game.data:resolveText(ctx2.overworld.map.def.label, textId))
          end
        end
        if type(text) == "string" then
          local def = npc.def or {}
          local nameText = assignedName(npc, def)
          local patched = nameText .. ":\n" .. text
          local copy = {}
          for i, v in ipairs(args) do copy[i] = v end
          copy[1] = patched
          return next(ctx2, name, copy)
        end
        return next(ctx2, name, args)
      end)
    end)
    installed = ok
  end

  install()
  return { install = install }
end
