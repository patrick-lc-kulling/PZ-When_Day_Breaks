-- The Great Collective as an animal species.
--
-- A zombie cannot be made bigger; an animal can, and it has real collision to
-- match. The species is a deep clone of vanilla's bull: the biggest animal in
-- the game, and the angus breed already has a black hide, so the placeholder
-- is a giant black bull until it gets a model of its own. Everything that
-- makes a bull livestock - grazing, breeding, being petted, led, carried or
-- tamed, needing food - is switched off. Its hunting is not the bull's either:
-- that is CreatureCollectives.lua.
--
-- Java reads AnimalDefinitions lazily when a world loads, so defining it at
-- file scope here is early enough, as long as vanilla's own files ran first.

require "Definitions/animal/CowDefinitions"
require "Definitions/animal/AnimalAvatarDefinition"
require "Definitions/animal/AnimalPartsDefinitions"
require "SCP001/Creatures/CreatureTypes"

local Tuning = DaybreakCreatures.Tuning.collective

local SOURCE_TYPE = "bull"
local SOURCE_BREED = "angus"

-- Wide enough that every size the mass can call for fits: AnimalData.setSize
-- clamps to this range, and so does loading a saved animal.
local SPECIES_MIN_SIZE = 1.0
local SPECIES_MAX_SIZE = 3.0

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, inner in pairs(value) do copy[key] = deepCopy(inner) end
    return copy
end

local function registerSpecies()
    local animals = AnimalDefinitions and AnimalDefinitions.animals
    local source = animals and animals[SOURCE_TYPE]
    if source == nil or source.breeds == nil or source.breeds[SOURCE_BREED] == nil then
        print("[Daybreak] no vanilla " .. SOURCE_TYPE .. " to clone, the Great Collective is disabled")
        return
    end

    local species = deepCopy(source)
    local speciesType = Tuning.animalType

    -- Its own group, one stage that never grows into anything, no breeding.
    -- Sharing the bull's group would have cows courting it.
    species.group = speciesType
    species.stages = { [speciesType] = { ageToGrow = 999999 } }
    species.mate = nil
    species.babyType = nil
    species.minAgeForBaby = nil

    -- One breed, the angus's black hide.
    local breed = deepCopy(source.breeds[SOURCE_BREED])
    breed.name = Tuning.breed
    species.breeds = { [Tuning.breed] = breed }

    -- A predator, not livestock.
    species.wild = true
    species.alwaysFleeHumans = false
    species.fleeZombies = false
    species.canBeAlerted = false
    species.canBePet = false
    species.canBePicked = false
    species.canBeAttached = false
    species.canBeTransported = false
    species.canBeDomesticated = false
    species.canBeFeedByHand = false
    species.luredPossibleItems = nil
    species.sitRandomly = false
    species.eatGrass = false
    species.hungerMultiplier = 0
    species.thirstMultiplier = 0
    species.stressAboveGround = false
    species.stressUnderRain = false
    species.dung = nil
    species.dungChancePerDay = 0

    -- Its attacks are CreatureCollectives.lua's. The bull's own stress attack
    -- stays off so the two never double up, and its knockdown-every-hit is
    -- replaced by a chance there. attackBack stays: on a server, hitting it
    -- may still earn you a real swing.
    species.attackIfStressed = false
    -- The bull's own thumping is off too: it locks onto whatever blocks its
    -- path and plays its attack at it until that thing is gone - and a door
    -- our code removed is gone without the bull ever being told, so it went
    -- on thumping an empty doorway. Breaking things is ours.
    species.canThump = false
    species.attackBack = true
    species.knockdownAttack = false
    species.canDoLaceration = true

    species.minSize = SPECIES_MIN_SIZE
    species.maxSize = SPECIES_MAX_SIZE

    animals[speciesType] = species

    -- The animal UI and butchering look these up by type without checking,
    -- so they have to exist. Butchering a burned one gives the bull's parts
    -- until it has a list of its own.
    if AnimalAvatarDefinition and AnimalAvatarDefinition[SOURCE_TYPE] then
        AnimalAvatarDefinition[speciesType] = deepCopy(AnimalAvatarDefinition[SOURCE_TYPE])
    end
    local parts = AnimalPartsDefinitions and AnimalPartsDefinitions.animals
        and AnimalPartsDefinitions.animals[SOURCE_TYPE .. SOURCE_BREED]
    if parts then
        AnimalPartsDefinitions.animals[speciesType .. Tuning.breed] = deepCopy(parts)
    end
end

registerSpecies()

-- How big a collective holding this many bodies is. Shared so the server,
-- which decides the mass, and a multiplayer client, which only draws it,
-- always agree.
function DaybreakCreatures.collectiveSize(mass)
    local span = Tuning.maxMass - Tuning.startMass
    local progress = 0
    if span > 0 then progress = (mass - Tuning.startMass) / span end
    progress = math.max(0, math.min(1, progress))
    return Tuning.minSize + (Tuning.maxSize - Tuning.minSize) * progress
end

function DaybreakCreatures.collectiveMass(animal)
    return animal:getModData()[DaybreakCreatures.Keys.collectiveMass] or Tuning.startMass
end

function DaybreakCreatures.isCollective(object)
    return object ~= nil and instanceof(object, "IsoAnimal")
        and object:getAnimalType() == Tuning.animalType
end

-- Keep the drawn size in step with the mass. The engine grows animals by age
-- and restores size on load, so this is re-applied rather than set once.
function DaybreakCreatures.applyCollectiveSize(animal)
    local size = DaybreakCreatures.collectiveSize(DaybreakCreatures.collectiveMass(animal))
    local data = animal:getData()
    if math.abs(data:getSize() - size) > 0.01 then data:setSize(size) end
end
