-- Decides what each zombie is when it is created, and makes it so.
--
-- What a creature is, is a world decision: it happens in exactly one place,
-- the single-player game or the multiplayer server. Files under server/ are
-- loaded on multiplayer clients too, hence the guard.
if isClient() then return end

require "SCP001/Creatures/CreatureTypes"

local Creatures = DaybreakCreatures
local Keys = Creatures.Keys

Creatures.Server = Creatures.Server or {}
local Server = Creatures.Server

-- The engine finishes building a zombie after OnZombieCreate returns and
-- overwrites its health on the way, so stats wait a few ticks. It dresses the
-- zombie later still and replaces whatever it wears, so dressing waits longer,
-- and is checked again afterwards because a successful-looking dress can still
-- be undone by the engine a moment later.
local STATS_DELAY_TICKS = 3
local DRESS_DELAY_TICKS = 30
local VERIFY_DELAY_TICKS = 120
local MAX_DRESS_ATTEMPTS = 5

local function log(message, ...)
    print("[Daybreak] " .. string.format(message, ...))
end

-- ------------------------------------------------------------------ speed --

-- The engine's walk types, slowest first. A lower speedType is faster:
-- 1 = sprinter, 2 = fast shambler, 3 = shambler.
local WALK_SCALE = {
    "slow1", "slow2", "slow3",
    "walk1", "walk2", "walk3",
    "sprint1", "sprint2", "sprint3", "sprint4", "sprint5",
}
local FAMILY_BY_SPEED_TYPE = { [1] = "sprint", [2] = "walk", [3] = "slow" }

local scale, scaleIndex

-- getSpeedTypeFromWalkType is static, so it is called on the class. Anything
-- the engine does not recognise is left off the scale instead of guessed at.
local function speedTypeOf(walkType)
    local ok, speedType = pcall(IsoZombie.getSpeedTypeFromWalkType, walkType)
    if ok then return speedType end
    return nil
end

local function getScale()
    if scale then return scale end
    scale, scaleIndex = {}, {}
    for _, walkType in ipairs(WALK_SCALE) do
        if speedTypeOf(walkType) ~= nil then
            scale[#scale + 1] = walkType
            scaleIndex[walkType] = #scale
        end
    end
    return scale
end

-- getWalkType() can come back as a bare variant ("2") without its family.
-- Rebuild the name from the zombie's speed family, and keep it only if the
-- engine agrees the rebuilt name belongs to that family.
local function scalePosition(walkType, speedType)
    getScale()
    if walkType == nil then return nil end
    if scaleIndex[walkType] then return scaleIndex[walkType] end

    local variant = string.match(tostring(walkType), "^(%d+)$")
    local family = FAMILY_BY_SPEED_TYPE[speedType]
    if not variant or not family then return nil end
    local rebuilt = family .. variant
    if speedTypeOf(rebuilt) ~= speedType then return nil end
    return scaleIndex[rebuilt]
end

local function applySpeed(zombie, data, steps)
    if steps == 0 or zombie:isCrawling() then return end
    local position = scalePosition(data[Keys.baseWalkType], data[Keys.baseSpeedType])
    if position == nil then return end

    local entries = getScale()
    position = math.max(1, math.min(#entries, position + steps))
    local walkType = entries[position]
    if walkType ~= zombie:getWalkType() then
        zombie:setWalkType(walkType)
        zombie:setSpeedTypeFromWalkType()
    end
end

-- ------------------------------------------------------------------ apply --

-- The zombie's values as the engine rolled them, recorded once. Modifiers
-- are always computed from these, so re-applying after a chunk reload gives
-- the same result instead of stacking.
local function captureBaseline(zombie, data)
    if data[Keys.baseHealth] == nil then
        data[Keys.baseHealth] = zombie:getHealth()
    end
    if data[Keys.baseWalkType] == nil then
        data[Keys.baseWalkType] = zombie:getWalkType()
        data[Keys.baseSpeedType] = zombie:getSpeedType()
    end
end

local function applyStats(zombie, def)
    local data = zombie:getModData()
    captureBaseline(zombie, data)
    zombie:setHealth(data[Keys.baseHealth] * def.health)
    applySpeed(zombie, data, def.speedSteps)
end

local function dress(zombie, def)
    zombie:setDressInRandomOutfit(false)
    zombie:dressInNamedOutfit(def.outfit)
    zombie:resetModelNextFrame()
end

-- Out of attempts: hand the zombie back to the engine's own dressing rather
-- than leave it naked. It keeps its type and stats; only the marker is lost.
local function abandonDressing(zombie, def)
    zombie:setDressInRandomOutfit(true)
    zombie:resetModelNextFrame()
    log("could not dress a %s in %s, leaving it in its own clothes", def.id, def.outfit)
end

-- ------------------------------------------------------------------ queue --

local pending = {}

local function queue(zombie, what, ticks, attempt)
    pending[#pending + 1] = { zombie = zombie, what = what, ticks = ticks, attempt = attempt or 1 }
end

local function needsWork(def)
    return def.outfit ~= nil or def.health ~= 1.0 or def.speedSteps ~= 0
end

local function runEntry(entry, zombie, def)
    if entry.what == "stats" then
        applyStats(zombie, def)
    elseif entry.what == "dress" and def.outfit then
        dress(zombie, def)
        queue(zombie, "verify", VERIFY_DELAY_TICKS, entry.attempt)
    elseif entry.what == "verify" and def.outfit then
        if Creatures.isWearingMarker(zombie, def) then return end
        if entry.attempt >= MAX_DRESS_ATTEMPTS then
            abandonDressing(zombie, def)
        else
            dress(zombie, def)
            queue(zombie, "verify", VERIFY_DELAY_TICKS, entry.attempt + 1)
        end
    end
end

local function onTick()
    local count = #pending
    if count == 0 then return end

    local due = {}
    local waiting = {}
    for i = 1, count do
        local entry = pending[i]
        entry.ticks = entry.ticks - 1
        if entry.ticks > 0 then
            waiting[#waiting + 1] = entry
        else
            due[#due + 1] = entry
        end
    end
    pending = waiting

    for i = 1, #due do
        local entry = due[i]
        local zombie = entry.zombie
        -- It may have died, merged or unloaded while it waited. The type is
        -- read now rather than when queued, since a merge can change it.
        if zombie and zombie:getCurrentSquare() and not zombie:isDead() then
            local def = Creatures.getDefinition(zombie)
            if def then
                local ok, err = pcall(runEntry, entry, zombie, def)
                if not ok then log("creature %s failed on %s: %s", def.id, entry.what, tostring(err)) end
            end
        end
    end
end
Events.OnTick.Add(onTick)

-- ----------------------------------------------------------------- public --

-- Make this zombie a given type, now: used by the roll, merging and splitting.
function Server.setType(zombie, typeId)
    local def = Creatures.get(typeId)
    if def == nil then return end

    local data = zombie:getModData()
    data[Keys.type] = typeId
    if data[Keys.seed] == nil then
        data[Keys.seed] = ZombRand(1000000) / 1000000
    end

    if needsWork(def) then
        queue(zombie, "stats", STATS_DELAY_TICKS)
        if def.outfit then queue(zombie, "dress", DRESS_DELAY_TICKS) end
    end
end

-- Spawn `count` creatures of a type at a spot, knocked down, as if they had
-- just fallen out of something. `health` is what the engine would give a
-- fresh zombie. Every zombie created during the call is claimed for the type
-- before the roll can see it.
local forcedType = nil
local forcedCount = 0

function Server.spawnAs(typeId, x, y, z, count, health)
    forcedType, forcedCount = typeId, count
    local ok, spawned = pcall(addZombiesInOutfit, x, y, z, count, nil, 50,
        false, false, false, true, false, false, health)
    forcedType, forcedCount = nil, 0

    if not ok then
        log("could not spawn %d %s: %s", count, typeId, tostring(spawned))
        return
    end
    if spawned then
        for i = 0, spawned:size() - 1 do
            local zombie = spawned:get(i)
            if zombie and zombie:getModData()[Keys.type] ~= typeId then
                Server.setType(zombie, typeId)
                -- Typed before OnZombieCreate saw it. When that does fire, it
                -- would look like a reload and could promote it on the spot,
                -- turning a Mass's split-offs straight back into a Mass.
                zombie:getModData()[Keys.fresh] = true
            end
        end
    end
end

-- ------------------------------------------------------------------ spawn --

-- The Bandits mod makes its human NPCs out of IsoZombies carrying a "Bandit"
-- animation variable. They are people, not creatures: leave them alone.
local function isBandit(zombie)
    local ok, bandit = pcall(function() return zombie:getVariableBoolean("Bandit") end)
    return ok and bandit == true
end

-- OnZombieCreate fires for brand-new zombies and again every time a chunk
-- reloads its zombies, so this must be cheap and must not re-roll a creature
-- that already has a type.
local function onZombieCreate(zombie)
    if zombie == nil or isBandit(zombie) then return end
    local data = zombie:getModData()

    if forcedCount > 0 then
        forcedCount = forcedCount - 1
        Server.setType(zombie, forcedType)
        return
    end

    local current = Creatures.get(data[Keys.type])
    if current and data[Keys.fresh] then
        data[Keys.fresh] = nil
        return
    end
    if current then
        -- A reload with its modData intact. Time has passed while nobody was
        -- looking, so let it evolve if its seed now falls in a higher stage;
        -- it never goes back down. Either way its stats and look are
        -- re-applied, since the engine rebuilds the zombie on reload.
        local rolled = Creatures.get(Creatures.classify(data[Keys.seed] or 0, Creatures.evolutionDay()))
        if rolled and rolled.stage > current.stage then
            Server.setType(zombie, rolled.id)
        elseif needsWork(current) then
            queue(zombie, "stats", STATS_DELAY_TICKS)
            if current.outfit then queue(zombie, "verify", VERIFY_DELAY_TICKS) end
        end
        return
    end

    -- No type. Either brand new, or rebuilt after the population manager
    -- dropped its modData off-screen; in the second case it may come back
    -- still wearing one of our outfits, and then it keeps that identity.
    local fromOutfit = Creatures.typeForOutfit(zombie:getOutfitName())
    if fromOutfit then
        Server.setType(zombie, fromOutfit)
        return
    end

    local seed = ZombRand(1000000) / 1000000
    data[Keys.seed] = seed
    local def = Creatures.get(Creatures.classify(seed, Creatures.evolutionDay()))
    if def == nil or def.id == Creatures.BASE_TYPE then
        data[Keys.type] = Creatures.BASE_TYPE
        return
    end

    -- Claim the look now: the engine dresses a new zombie on a later tick and
    -- would replace anything put on before, unless told not to here.
    if def.outfit then zombie:setDressInRandomOutfit(false) end
    Server.setType(zombie, def.id)
end
Events.OnZombieCreate.Add(onZombieCreate)
