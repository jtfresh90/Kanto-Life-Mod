-- DialogueGen.lua — Combinatorial unique dialogue generator for Kanto Life.
--
-- Goal: unique dialogue on every interaction. Instead of a fixed list of
-- lines (which repeats quickly), this builds lines from templates with
-- slots filled from large pools. The combination space is in the millions,
-- and per-NPC recent-line history prevents immediate repeats.
--
-- Usage:
--   local gen = loadBundled("lib/DialogueGen.lua")
--   local line = gen.generate({
--     npcName = "Ash", gender = "m", agenda = "travel",
--     pokemon = "PIKACHU", location = "VIRIDIAN CITY",
--     timeOfDay = "morning", weather = "sunny",
--     recentLines = { ... },  -- last N lines for this NPC (to avoid repeats)
--     dex = { "BULBASAUR", ... },  -- species pool for {pokemon} slot
--   })
-- Returns: string (the dialogue line), updatedRecentLines (table)

local DialogueGen = {}

-- ============================================================================
-- Slot pools
-- ============================================================================

local LOCATIONS_KANTO = {
  "VIRIDIAN CITY", "PEWTER CITY", "CERULEAN CITY", "VERMILION CITY",
  "LAVENDER TOWN", "CELADON CITY", "FUCHSIA CITY", "SAFFRON CITY",
  "CINNABAR ISLAND", "INDIGO PLATEAU", "PALLET TOWN",
  "ROUTE 1", "ROUTE 2", "VIRIDIAN FOREST", "MT. MOON",
  "ROUTE 12", "ROUTE 15", "SEAFOAM ISLANDS", "POWER PLANT",
  "SAFARI ZONE", "SILPH CO.", "POKéMON TOWER", "ROCK TUNNEL",
}

local LOCATIONS_JOHTO = {
  "NEW BARK TOWN", "CHERRYGROVE CITY", "VIOLET CITY", "AZALEA TOWN",
  "GOLDENROD CITY", "ECRUTEAK CITY", "OLIVINE CITY", "CIANWOOD CITY",
  "MAHOGANY TOWN", "BLACKTHORN CITY",
  "ROUTE 29", "ROUTE 32", "ILEX FOREST", "BURNED TOWER",
  "TIN TOWER", "WHIRL ISLANDS", "MT. SILVER", "DARK CAVE",
  "NATIONAL PARK", "RUINS OF ALPH",
}

local LOCATIONS_HOENN = {
  "LITTLEROOT TOWN", "OLDALE TOWN", "PETALBURG CITY", "RUSTBORO CITY",
  "DEWFORD TOWN", "SLATEPORT CITY", "MAUVILLE CITY", "VERDANTURF TOWN",
  "FALLARBOR TOWN", "LAVARIDGE TOWN", "FORTREE CITY", "LILYCOVE CITY",
  "MOSSDEEP CITY", "SOOTOPOLIS CITY", "PACIFIDLOG TOWN",
  "ROUTE 101", "ROUTE 110", "PETALBURG WOODS", "GRANITE CAVE",
  "MT. CHIMNEY", "JAGGED PASS", "SKY PILLAR",
}

local ITEMS = {
  "POTION", "SUPER POTION", "HYPER POTION", "MAX POTION", "FULL RESTORE",
  "FULL HEAL", "REVIVE", "MAX REVIVE", "ANTIDOTE", "AWAKENING",
  "BURN HEAL", "ICE HEAL", "PARLYZ HEAL",
  "POKé BALL", "GREAT BALL", "ULTRA BALL", "MASTER BALL",
  "REPEL", "SUPER REPEL", "MAX REPEL", "ESCAPE ROPE",
  "X ATTACK", "X DEFEND", "X SPEED", "X SPECIAL", "DIRE HIT",
  "RARE CANDY", "NUGGET", "BIG PEARL", "STARDUST", "HEART SCALE",
  "MOON STONE", "FIRE STONE", "WATER STONE", "THUNDERSTONE", "LEAF STONE",
  "BICYCLE", "OLD ROD", "GOOD ROD", "SUPER ROD",
}

local ACTIVITIES = {
  "training", "battling", "exploring", "fishing", "hiking",
  "camping", "sightseeing", "shopping", "relaxing", "jogging",
  "birdwatching", "foraging", "swimming", "cycling", "picnicking",
  "stargazing", "photographing", "sketching", "meditating", "gardening",
}

local WEATHER_WORDS = {
  "sunny", "cloudy", "rainy", "windy", "clear", "humid", "crisp", "misty",
}

local TIME_WORDS = {
  "morning", "afternoon", "evening", "night", "dawn", "dusk", "midday", "midnight",
}

local GREETINGS = {
  "Hey", "Hi", "Hello", "Yo", "Hiya", "Howdy", "Greetings",
}

local EXCLAMATIONS = {
  "Wow", "Amazing", "Incredible", "Unbelievable", "Fantastic", "Wonderful",
}

-- ============================================================================
-- Templates — {slot} is filled from pools. Keep lines to 2 rows for text box.
-- ============================================================================

local TEMPLATES = {
  -- Pokemon sightings
  "I saw a wild {pokemon}\nnear {location} today!",
  "A {pokemon} crossed my\npath on {route}!",
  "Have you seen a\n{pokemon} around here?",
  "I heard a {pokemon}\ncry near {location}!",
  "My friend caught a\n{pokemon} yesterday!",
  "I wish I had a\n{pokemon} on my team.",
  "That {pokemon} was\nso fast I blinked!",
  "A shiny {pokemon}?\nI can only dream...",

  -- Training & battling
  "I'm training my\n{pokemon} for the LEAGUE!",
  "My {pokemon} learned\na new move today!",
  "We battled a TRAINER\nnear {location}!",
  "My {pokemon} is getting\nstronger every day!",
  "I need to level up\nmy {pokemon} more.",
  "That GYM LEADER was\ntougher than expected!",
  "My {pokemon} won three\nbattles in a row!",
  "I'm saving {item}\nfor the next battle.",

  -- Items & shopping
  "I just bought a\n{item} at the MART!",
  "The MART has great\ndeals on {item} today!",
  "I'm saving up for\nan {item}!",
  "I found an {item}\non {route}!",
  "Don't forget to stock\nup on {item}!",
  "I wish {item} were\ncheaper at the MART.",

  -- Travel & locations
  "I'm headed to\n{location} before sunset.",
  "Have you been to\n{location} yet?",
  "{location} is beautiful\nthis time of year!",
  "I'm traveling between\n{location} and {location2}.",
  "The road to {location}\nis full of TRAINERS!",
  "I got lost near\n{location} yesterday!",
  "Next stop:\n{location}!",

  -- Daily life
  "The weather is {weather}\nperfect for {activity}!",
  "I love {activity} in\nthe {time}!",
  "My {pokemon} loves\n{activity} with me!",
  "I'm taking a break\nfrom {activity} today.",
  "Nothing beats {activity}\non a {weather} day!",
  "{greeting}! Nice day for\n{activity}, isn't it?",

  -- Story & world
  "I heard a TRAINER\nbeat the GYM today!",
  "TEAM ROCKET better\nstay away from here!",
  "Did you hear about\n{location}?",
  "The POKéMON CENTER\nis so handy!",
  "Someone spotted a rare\nPOKéMON near {location}!",
  "{exclamation}! That battle\nwas incredible!",
  "The LEAGUE is getting\nmore competitive!",
  "I want to challenge\nthe next GYM!",

  -- Personal (uses NPC name/agenda)
  "I'm {name}, and I\nlove {activity}!",
  "As a {agenda}, I\nvisit {location} often.",
  "My dream is to see\nevery {pokemon}!",
  "I named my {pokemon}\nafter my hometown!",
  "Being a {agenda} is\nthe best life!",
  "{name} here! Have you\ntried {activity}?",

  -- Questions (engaging)
  "What's your favorite\n{pokemon}?",
  "Do you prefer {location}\nor {location2}?",
  "Have you tried using\n{item} in battle?",
  "What's the rarest\nPOKéMON you've seen?",
  "Do you like {activity}\nin the {time}?",
  "Which GYM was hardest\nfor you?",

  -- Pokemon NPC specific (isPoke)
  "Cry! I am {pokemon}!\nI live near {location}.",
  "{pokemon}! {pokemon}!\nI love {activity}!",
  "I saw a TRAINER with\na {pokemon} today!",
  "The tall grass near\n{location} is my home.",
  "I evolved near\n{location} last week!",
}

-- Agenda-specific templates
local AGENDA_TEMPLATES = {
  travel = {
    "The road calls!\nNext: {location}!",
    "I've walked {route}\nthree times this week!",
    "My feet are tired\nbut {location} awaits!",
  },
  shop = {
    "The MART's {item}\nselection is great!",
    "I'm comparing prices\non {item}.",
    "Just restocked my\n{item} supply!",
  },
  train = {
    "No pain, no gain!\nMy {pokemon} agrees!",
    "One more battle\nnear {location}!",
    "My {pokemon} and I\nare in sync!",
  },
  rest = {
    "The CENTER's beds\nare so comfortable!",
    "My {pokemon} is\nnapping right now.",
    "Even TRAINERS need\nrest sometimes.",
  },
  fish = {
    "The {pokemon} are\nbiting near {location}!",
    "I caught something big\nwith my OLD ROD!",
    "Fishing is about\npatience, you know.",
  },
}

-- ============================================================================
-- Generation
-- ============================================================================

local HISTORY_SIZE = 25
local MAX_RETRIES = 10

local function pick(list, rnd)
  if #list == 0 then return "" end
  return list[rnd(1, #list)]
end

local function titleCase(s)
  s = tostring(s or "")
  s = s:gsub("_", " ")
  return s:gsub("(%a)([%w_']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
end

local function buildSlots(ctx, rnd)
  local dex = ctx.dex
  if type(dex) ~= "table" or #dex == 0 then
    dex = { "PIKACHU", "EEVEE", "MEOWTH", "PSYDUCK", "SNORLAX" }
  end
  local locations = LOCATIONS_KANTO
  if ctx.gen == 2 then locations = LOCATIONS_JOHTO
  elseif ctx.gen == 3 then locations = LOCATIONS_HOENN end

  local function dexName()
    local v = pick(dex, rnd)
    if type(v) == "table" then v = v.name or v.species or v[1] end
    return titleCase(v)
  end

  return {
    pokemon = dexName(),
    pokemon2 = dexName(),
    location = pick(locations, rnd),
    location2 = pick(locations, rnd),
    route = "ROUTE " .. tostring(rnd(1, 25)),
    item = titleCase(pick(ITEMS, rnd)),
    activity = pick(ACTIVITIES, rnd),
    weather = ctx.weather or pick(WEATHER_WORDS, rnd),
    time = ctx.timeOfDay or pick(TIME_WORDS, rnd),
    greeting = pick(GREETINGS, rnd),
    exclamation = pick(EXCLAMATIONS, rnd),
    name = ctx.npcName or "Traveler",
    agenda = ctx.agenda or "traveler",
  }
end

local function fillTemplate(template, slots)
  return (template:gsub("{(%w+)}", function(key)
    return tostring(slots[key] or ("{" .. key .. "}"))
  end))
end

local function inHistory(line, history)
  for _, h in ipairs(history or {}) do
    if h == line then return true end
  end
  return false
end

function DialogueGen.generate(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local rnd = (love and love.math and love.math.random) or math.random
  local history = ctx.recentLines
  if type(history) ~= "table" then history = {} end

  local pool = {}
  for _, t in ipairs(TEMPLATES) do pool[#pool + 1] = t end
  local agenda = tostring(ctx.agenda or ""):lower()
  local agendaTs = AGENDA_TEMPLATES[agenda]
  if agendaTs then
    for _, t in ipairs(agendaTs) do pool[#pool + 1] = t end
  end

  local line = nil
  for _ = 1, MAX_RETRIES do
    local template = pick(pool, rnd)
    local slots = buildSlots(ctx, rnd)
    local candidate = fillTemplate(template, slots)
    if not inHistory(candidate, history) then
      line = candidate
      break
    end
  end
  if not line then
    local slots = buildSlots(ctx, rnd)
    line = fillTemplate(pick(pool, rnd), slots)
  end

  local updated = {}
  for _, h in ipairs(history) do updated[#updated + 1] = h end
  updated[#updated + 1] = line
  while #updated > HISTORY_SIZE do table.remove(updated, 1) end

  return line, updated
end

function DialogueGen.quick(ctx)
  local line, _ = DialogueGen.generate(ctx)
  return line
end

return DialogueGen
