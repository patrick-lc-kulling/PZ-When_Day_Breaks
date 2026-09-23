-- The liquefied creatures: the type registry, the evolution curve, and how any
-- machine - server, client or single player - tells what a creature is.
--
-- A type is one table passed to DaybreakCreatures.register(). They all live in
-- CreatureTypes.lua, which is the file to edit when adding or tuning a type;
-- nothing here needs to change unless a type brings a brand new ability.

DaybreakCreatures = DaybreakCreatures or {}
local Creatures = DaybreakCreatures

-- Module name for client/server commands about creatures.
Creatures.MODULE = "DaybreakCreatures"

-- modData keys. They are a save-file schema, so never inline them elsewhere:
-- a typo silently creates a second, empty field.
Creatures.Keys = {
    type          = "DaybreakCreature",
    seed          = "DaybreakCreatureSeed",
    baseHealth    = "DaybreakBaseHealth",
    baseWalkType  = "DaybreakBaseWalkType",
    baseSpeedType = "DaybreakBaseSpeedType",
    lastCall      = "DaybreakLastCall",
    fresh         = "DaybreakFresh",
    -- On a Great Collective (an animal, not a zombie).
    collectiveId   = "DaybreakCollectiveId",
    collectiveMass = "DaybreakCollectiveMass",
}

-- What every zombie is unless something says otherwise.
Creatures.BASE_TYPE = "remnant"

local types = {}
local registrationOrder = {}
local typeByOutfit = {}
local stageOrder = nil -- built lazily, see byStageDescending()

function Creatures.register(def)
    assert(type(def) == "table" and type(def.id) == "string", "a creature type needs an id")
    assert(types[def.id] == nil, "creature type registered twice: " .. def.id)

    def.stage = def.stage or 0
    def.mass = def.mass or 1
    def.weight = def.weight or 0
    def.unlockDay = def.unlockDay or 0
    def.rampDays = def.rampDays or 0
    def.health = def.health or 1.0
    def.speedSteps = def.speedSteps or 0
    def.stunTime = def.stunTime or 1.0 -- 0 survives this: only nil is replaced
    def.index = #registrationOrder + 1

    types[def.id] = def
    registrationOrder[def.index] = def
    if def.outfit then typeByOutfit[def.outfit] = def.id end
    stageOrder = nil
    return def
end

function Creatures.get(id)
    return id and types[id] or nil
end

function Creatures.all()
    return registrationOrder
end

function Creatures.typeForOutfit(outfitName)
    return outfitName and typeByOutfit[outfitName] or nil
end

-- What this creature is. The server and single player keep it in modData; a
-- multiplayer client has no copy of that, but it does receive the zombie's
-- outfit through the engine's own sync, and every evolved type has one.
function Creatures.getType(zombie)
    if zombie == nil then return nil end
    local id = zombie:getModData()[Creatures.Keys.type]
    if id and types[id] then return id end
    return Creatures.typeForOutfit(zombie:getOutfitName()) or Creatures.BASE_TYPE
end

function Creatures.getDefinition(zombie)
    return types[Creatures.getType(zombie)]
end

-- True if the zombie is visibly wearing its type's marker. A type without a
-- marker has nothing to check, so it always passes.
function Creatures.isWearingMarker(zombie, def)
    if not def.marker then return true end
    local visuals = zombie:getItemVisuals()
    if visuals == nil then return false end
    for i = 0, visuals:size() - 1 do
        local visual = visuals:get(i)
        local itemType = visual and visual:getItemType()
        if itemType == def.marker or (itemType and "Base." .. itemType == def.marker) then
            return true
        end
    end
    return false
end

function Creatures.sandbox(name, default)
    local options = SandboxVars and SandboxVars.SCP -- nil on the main menu
    local value = options and options[name]
    if value == nil then return default end
    return value
end

-- How far the liquefaction has progressed, in days. Real days since the world
-- began, scaled by the Evolution Pace sandbox option: at pace 2, the day-21
-- creatures turn up after ten and a half days.
function Creatures.evolutionDay()
    local gameTime = getGameTime()
    if not gameTime then return 0 end
    return gameTime:getWorldAgeHours() / 24 * Creatures.sandbox("CreatureEvolutionPace", 1.0)
end

function Creatures.isUnlocked(def, day)
    return day >= def.unlockDay
end

-- A type is worth this share of its full weight on the day it unlocks, so
-- "unlocked" means rare rather than absent.
local RAMP_START = 0.05

-- How likely this type is on a given day, relative to the others: nothing
-- before it unlocks, then a linear ramp to its full weight over rampDays.
function Creatures.weightFor(def, day)
    if def.weight <= 0 or day < def.unlockDay then return 0 end
    if def.rampDays <= 0 then return def.weight end

    local progress = (day - def.unlockDay) / def.rampDays
    if progress < RAMP_START then progress = RAMP_START end
    if progress > 1 then progress = 1 end
    return def.weight * progress
end

local function byStageDescending()
    if stageOrder then return stageOrder end
    stageOrder = {}
    for i = 1, #registrationOrder do stageOrder[i] = registrationOrder[i] end
    table.sort(stageOrder, function(a, b)
        if a.stage ~= b.stage then return a.stage > b.stage end
        return a.index < b.index
    end)
    return stageOrder
end

-- Which type a creature with this seed (0-1) is on this day.
--
-- The most evolved types take the top of the 0-1 range and grow downwards as
-- their weight ramps up. A creature keeps its seed for life, so as the days go
-- by it can only ever be reached by a more evolved band, never a lesser one:
-- revisited creatures evolve, they never regress.
function Creatures.classify(seed, day)
    local total = 0
    for _, def in ipairs(registrationOrder) do
        total = total + Creatures.weightFor(def, day)
    end
    if total <= 0 then return Creatures.BASE_TYPE end

    local threshold = 1.0
    for _, def in ipairs(byStageDescending()) do
        local weight = Creatures.weightFor(def, day)
        if weight > 0 then
            threshold = threshold - weight / total
            if seed >= threshold then return def.id end
        end
    end
    return Creatures.BASE_TYPE
end
