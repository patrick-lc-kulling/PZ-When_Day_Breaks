-- The Great Collective as an animal species.
--
-- A zombie cannot be made bigger; an animal can, and it has real collision to
-- match. The species is a deep clone of a vanilla animal - for now the bull:
-- the biggest animal in the game, and the angus breed already has a black
-- hide, so the placeholder is a giant black bull. Everything that makes it
-- livestock - grazing, breeding, being petted, led, carried or tamed, needing
-- food - is switched off. Its hunting is not the animal's either: that is
-- CreatureCollectives.lua and CollectiveNavigation.lua.
--
-- Everything about how it looks and animates is in the look table below, and
-- the behaviour code only ever asks that table. The final model replaces the
-- placeholder there and nowhere else.
--
-- Java reads AnimalDefinitions lazily when a world loads, so defining it at
-- file scope here is early enough, as long as vanilla's own files ran first.

require "Definitions/animal/CowDefinitions"
require "Definitions/animal/AnimalAvatarDefinition"
require "Definitions/animal/AnimalPartsDefinitions"
require "SCP001/Creatures/CreatureTypes"

local Tuning = DaybreakCreatures.Tuning.collective

-- ------------------------------------------------------------------- look --

DaybreakCreatures.CollectiveLook = {
    -- The vanilla animal cloned for its body, and the breed whose hide it
    -- wears. Everything the clone brings - model, animations, textures - can
    -- be replaced below.
    cloneType = "bull",
    cloneBreed = "angus",

    -- Fields laid over the cloned species and breed. The final model sets its
    -- own here: in species, bodyModel, modelscript, animset and textureSkinned
    -- (the skeleton and headless models too, for butchering); in breed,
    -- texture and textureMale.
    species = {},
    breed = {},

    -- Which of the usual animal animations the model has. The behaviour never
    -- calls for one it lacks: the final model has no run, so neither may the
    -- placeholder, and vanilla's reasons to run are overridden every tick.
    canRun = false,

    -- The animation variable that marks an animal as a collective, set on it
    -- every brain step, so the look's own animation nodes play for
    -- collectives only and never for other animals sharing the animset.
    marker = "DaybreakCollective",

    -- Its swing, at players and at fences alike: the animation variable its
    -- attack animation plays on, held for durationSeconds, and when in the
    -- swing the blow lands. The placeholder's nodes, in AnimSets/cow/idle,
    -- walk and pathfind (Daybreak_CollectiveAttack.xml), play the cow's head
    -- swipe at 1.5x speed: 1.93 s / 1.5, connecting at 35% of it. The final
    -- model's nodes go beside its own animset's and use its own clip; only
    -- the timings here change.
    attack = {
        variable = "DaybreakCollectiveAttacking",
        impactSeconds = 0.45,
        durationSeconds = 1.29,
    },

    -- One-off actions, each the name of an animation variable its animset
    -- plays the action on, pulsed true for pulseSeconds when it happens.
    -- false while the model has no such animation - the placeholder has none.
    actions = {
        absorb = false, -- swallowing a creature
    },
    pulseSeconds = 0.3,
}

local Look = DaybreakCreatures.CollectiveLook
local SOURCE_TYPE = Look.cloneType
local SOURCE_BREED = Look.cloneBreed

local function overlay(target, fields)
    for key, value in pairs(fields) do target[key] = value end
end

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

    -- One breed, the cloned breed's hide unless the look says otherwise.
    local breed = deepCopy(source.breeds[SOURCE_BREED])
    overlay(breed, Look.breed)
    breed.name = Tuning.breed
    species.breeds = { [Tuning.breed] = breed }

    -- A predator, not livestock - and not a wild animal either: the engine
    -- has wild animals take fright and flee from players who come near
    -- (BaseAnimalBehavior.spotted). Irish's Dinosaurs' T-rex is built the
    -- same way.
    species.wild = false
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

    -- Its attacks are CreatureCollectives.lua's. As with the T-rex, the
    -- animal's own fighting back stays on - a hit turns it on the attacker
    -- rather than making it flee - but can never land: attackDist 0 and a
    -- timer that never runs out. Its stress attack is off, and its
    -- knockdown-every-hit is replaced by a chance there.
    species.attackIfStressed = false
    species.attackDist = 0
    species.attackTimer = 999999999
    species.dontAttackOtherMale = true
    species.canBeKilledWithoutWeapon = false
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

    -- How fast it turns; the engine reads this every update. And no running
    -- off at random; whether it may run at all is the look's canRun.
    species.turnDelta = Tuning.turnDelta
    species.periodicRun = false
    -- Its own roaming is the brain's; vanilla's idle wandering is made rare
    -- (the T-rex's value) so the two seldom cross.
    species.wanderMul = 220

    -- The look's own model and animations, last, over everything cloned.
    overlay(species, Look.species)

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
