-- The liquefied creature types, and every tunable of the creature system.
--
-- This is the file to edit. Adding a type is one register{} call below; the
-- spawner, merging, splitting and abilities all read these tables, so nothing
-- else needs to change unless the type brings a brand new ability.
--
-- Fields of a type (only `id` is required):
--   stage       evolution stage, 0 = as the sun left them. Higher stages take
--               the top of the spawn roll, see DaybreakCreatures.classify().
--   mass        how many bodies it is made of.
--   weight      how common it is once fully ramped, relative to the others.
--   unlockDay   first day it can appear (scaled by the Evolution Pace option).
--   rampDays    days after unlocking to reach its full weight.
--   health      multiplies the health the engine rolled, so the sandbox
--               Toughness setting still applies. 2.0 = twice as tough.
--   speedSteps  steps along slow1..slow3, walk1..walk3, sprint1..sprint5,
--               relative to the world's own speed. Negative is slower.
--   stunTime    multiplies how long the electric weapons hold it on the
--               ground. 0.5 = half as long, 0 = cannot be stunned at all.
--   knockdownImmune  true: fists, shoves and ordinary weapons can no longer
--               knock it over. Only the electric weapons can, and only if its
--               stunTime is above 0. Hits still make it stagger back.
--   outfit      clothing.xml outfit it wears. Also how a multiplayer client
--               recognises it, so every non-base type needs one.
--   marker      item in that outfit that proves it is dressed.
--   mergesInto  two of this type pressed together become one of that type.
--   splitOnDeath   { into = type, count = n }: falls apart instead of dying,
--                  unless it was burning.
--   call        the Caller's ability, see its entry.
--   stripsHeadgear the Grasper's ability.
--   sounds      { idle = "SoundName", idleChance = 0-1 }: played now and then
--               near players. Point it at your own sound script entries.
--
-- Quotes are from the source material, S. D. Locke's Proposal.

require "SCP001/Creatures/CreatureCore"

local Creatures = DaybreakCreatures
local register = Creatures.register

-- Tunables that are not tied to a single type.
Creatures.Tuning = {
    -- Merging: two creatures of the same kind that stay pressed together for
    -- mergeSeconds become one creature of the next kind up. Crowds at a
    -- barricade are where this happens most.
    mergeDistance = 0.8,    -- tiles
    mergeSeconds = 8,
    sweepSeconds = 1,       -- how often the server looks at loaded creatures

    -- Grasper: after one has torn something off, no grasper can do it to the
    -- same player again for this long. The chance itself is a sandbox option.
    grasperCooldownSeconds = 15,
    grasperReach = 2.0,     -- tiles; hits from further away are not a grasp

    -- Head locations a grasper can tear off, the one it goes for first at the
    -- top. Full suits are left out: tearing a hazmat suit off in one hit would
    -- be a death sentence, not a threat.
    strippableLocations = { "fullhat", "maskfull", "mask", "maskeyes" },

    -- Idle sounds: how often each nearby creature may make one, and how near.
    voiceSeconds = 3,
    voiceRange = 25,        -- tiles

    -- The Great Collective. Not a zombie: an animal species of its own, see
    -- CollectiveSpecies.lua and CreatureCollectives.lua.
    collective = {
        animalType = "daybreak_collective",
        breed = "liquefied",

        -- Mass is how many bodies it holds. Two Masses make one at 8; it
        -- absorbs creatures it touches up to maxMass, and no further.
        startMass = 8,
        maxMass = 24,
        -- Size at startMass and at maxMass, linear between. 1.0 is a bull.
        minSize = 1.6,
        maxSize = 2.6,

        -- Hunting and its hit.
        huntRadius = 20,          -- tiles it notices a player from
        loseRadius = 30,          -- tiles at which it gives up on one
        repathSeconds = 2,
        reach = 1.4,              -- tiles, plus reachPerSize for every 1.0 of size
        reachPerSize = 0.4,
        attackCooldownSeconds = 3,
        knockdownChance = 0.35,   -- chance a hit also knocks the player over
        knockdownCooldownSeconds = 10,

        -- Barriers: a door, window, barricade, fence, or anything built or
        -- moved into its way, breaks when it walks into it, and it staggers
        -- for a moment. Walls of the map itself hold.
        breakPauseSeconds = 1.0,
        breakNoiseRadius = 25,    -- tiles creatures hear the crash from
        stuckSeconds = 4,         -- no closer to its prey for this long: it
                                  -- heads for the nearest breakable barrier

        -- Absorbing: a creature that stays this close this long is swallowed.
        absorbDistance = 1.0,     -- tiles at minSize, grows with size
        absorbSeconds = 2,

        -- Damage from anything but fire is divided by mass x this (never
        -- below 1), so a big one takes far longer to club down while fire
        -- stays the quick answer. Tune in play: a fresh one should take about
        -- as long as eight Remnants.
        toughnessPerBody = 0.25,

        -- Beaten down without fire, it falls apart into Masses: one per four
        -- bodies, at most maxSplit.
        maxSplit = 4,

        -- The world seeds new ones out of sight, up to the sandbox cap.
        seedChancePerDay = 0.5,
        seedMinDistance = 200,    -- tiles from a random player
        seedMaxDistance = 500,
        spawnClearance = 20,      -- no player this close when it appears
        forgetAfterDays = 30,     -- a record unseen this long frees its slot
    },
}

-- Stage 0 ------------------------------------------------------------------

-- "Motile organisms will attempt to orient themselves in a fashion
-- reminiscent of their previous form." Every zombie in the world is one of
-- these unless it rolls something else; it plays exactly like vanilla.
-- Vanilla crawlers are the lore's partly-liquefied "Pooled" and need no type.
register {
    id = "remnant",
    stage = 0,
    mass = 1,
    weight = 100,           -- always present, so it never disappears
    stunTime = 1.0,
    mergesInto = "conjoined",
}

-- Stage 1: pairs ----------------------------------------------------------

-- "Limbs and bodies will rise periodically from within the mass." Two
-- bodies' worth of health, slowed by its own bulk.
register {
    id = "conjoined",
    stage = 1,
    mass = 2,
    unlockDay = 7,
    rampDays = 21,
    weight = 25,
    health = 2.0,
    speedSteps = -1,
    stunTime = 0.75,
    outfit = "Daybreak_Conjoined",
    marker = "Base.Daybreak_Marker_Conjoined",    -- yellow hard hat
    mergesInto = "mass",
}

-- "Calling out to us, begging for us to come outside." Humans keep "a
-- modicum of sapience and memory". Fragile and in no hurry: when it has you
-- in sight it calls out, which draws every creature in earshot to it and
-- wears on the nerves of anyone who hears it. Kill it first.
register {
    id = "caller",
    stage = 1,
    mass = 1,
    unlockDay = 7,
    rampDays = 30,
    weight = 4,
    health = 0.6,
    speedSteps = -1,
    stunTime = 1.25,         -- one body, and a weak one
    outfit = "Daybreak_Caller",
    marker = "Base.Daybreak_Marker_Caller",       -- white hard hat
    call = {
        range = 20,             -- tiles to its target before it calls
        cooldownSeconds = 20,
        attractRadius = 40,     -- tiles the call pulls other creatures from
        attractVolume = 40,
        stressRange = 15,       -- tiles within which hearing it causes stress
        stress = 0.1,           -- added per call, stress runs 0-1
        -- Placeholders: vanilla's own shouted "Hey!". Swap for a pleading
        -- voice when there is one.
        soundMale = "VoiceMaleShoutHey",
        soundFemale = "VoiceFemaleShoutHey",
    },
}

-- Stage 2: collectives ----------------------------------------------------

-- "One got a hold of him, tried to get his mask off." Its hits can tear off
-- the helmet or mask that keeps the light out, and drop it at your feet.
register {
    id = "grasper",
    stage = 2,
    mass = 2,
    unlockDay = 21,
    rampDays = 30,
    weight = 10,
    health = 2.0,
    speedSteps = -1,
    stunTime = 0.75,
    outfit = "Daybreak_Grasper",
    marker = "Base.Daybreak_Marker_Grasper",      -- red hard hat
    stripsHeadgear = true,
}

-- "Larger instances will form a pseudopod from their constituent life-forms,
-- and drag themselves about in a manner similar to amoeba." Slow and very
-- tough, and "at no point do living organisms perish": beaten down, it falls
-- apart into two Remnants. Fire is the exception - "incendiary weapons work
-- as well" - so a Mass that dies burning stays dead.
register {
    id = "mass",
    stage = 2,
    mass = 4,
    unlockDay = 21,
    rampDays = 45,
    weight = 12,
    health = 4.0,
    speedSteps = -2,
    stunTime = 0.5,          -- four bodies take the current badly shared
    knockdownImmune = true,  -- too much bulk to push over by hand
    outfit = "Daybreak_Mass",
    marker = "Base.Daybreak_Marker_Mass",         -- blue hard hat
    mergesInto = "collective",
    splitOnDeath = { into = "remnant", count = 4 },
}

-- Stage 3: the Great Collective --------------------------------------------

-- "This one mass that I'm sure must have a few dozen people and god-knows how
-- many animals roiling around inside it", and collectives "seem to possess no
-- maximum volume" - though this one stops at Tuning.collective.maxMass.
--
-- An animal species rather than a zombie (CollectiveSpecies.lua), so it has
-- real size and collision; its hunting, absorbing and splitting live in
-- CreatureCollectives.lua. Registered here so it shares the unlock day and
-- Evolution Pace with the rest. Weight 0: no zombie ever rolls it. It comes
-- from two Masses merging, or from the world seeding one out of sight.
register {
    id = "collective",
    stage = 3,
    mass = 8,
    unlockDay = 45,
    weight = 0,
    stunTime = 0,             -- the electric weapons do nothing to it
    isAnimal = true,
}
