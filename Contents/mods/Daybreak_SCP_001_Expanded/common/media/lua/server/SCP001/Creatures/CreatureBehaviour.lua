-- What the creatures do once they exist: merge, call out, and fall apart.
--
-- World decisions, made only by the single-player game or the multiplayer
-- server. Files under server/ are loaded on multiplayer clients too.
if isClient() then return end

require "SCP001/Creatures/CreatureSpawner"

local Creatures = DaybreakCreatures
local Keys = Creatures.Keys
local Server = Creatures.Server

-- ---------------------------------------------------------------- merging --

-- "Instances of SCP-001-A that make contact with one another may combine and
-- blend at the molecular level." Two creatures of the same kind that stay
-- pressed together for a while become one of the next kind up: the horde gets
-- fewer and bigger instead of more.

-- Pairs currently pressed together, as "lowerId:higherId" -> first seen (ms).
local pairSince = {}

local function bucketKey(x, y, z)
    return math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z)
end

-- Can this creature merge right now? It needs something to merge into that
-- the days have unlocked, and it has to be up and about: knocked down,
-- stunned or crawling creatures don't.
local function canMerge(zombie, def, day)
    local into = Creatures.get(def.mergesInto)
    if into == nil or not Creatures.isUnlocked(into, day) then return false end
    -- A Great Collective also needs room under the sandbox cap.
    if into.isAnimal and not (Creatures.Collectives and Creatures.Collectives.hasRoom()) then return false end
    return not zombie:isOnFloor() and not zombie:isCrawling()
end

local function nearestPartner(zombie, typeId, buckets)
    local x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
    local maxDistance = Creatures.Tuning.mergeDistance
    local best, bestDistanceSq = nil, maxDistance * maxDistance

    for dx = -1, 1 do
        for dy = -1, 1 do
            local bucket = buckets[bucketKey(x + dx, y + dy, z)]
            if bucket then
                for i = 1, #bucket do
                    local other = bucket[i]
                    if other.zombie ~= zombie and other.typeId == typeId then
                        local ox, oy = other.zombie:getX() - x, other.zombie:getY() - y
                        local distanceSq = ox * ox + oy * oy
                        if distanceSq <= bestDistanceSq then
                            best, bestDistanceSq = other.zombie, distanceSq
                        end
                    end
                end
            end
        end
    end
    return best
end

local function merge(survivor, absorbed, def)
    -- Two Masses make a Great Collective, which is an animal rather than a
    -- zombie: both go, and it takes their place.
    local into = Creatures.get(def.mergesInto)
    if into and into.isAnimal then
        if Creatures.Collectives == nil then return end
        local x, y, z = math.floor(survivor:getX()), math.floor(survivor:getY()), math.floor(survivor:getZ())
        survivor:removeFromWorld()
        survivor:removeFromSquare()
        absorbed:removeFromWorld()
        absorbed:removeFromSquare()
        Creatures.Collectives.spawnAt(x, y, z, def.mass * 2)
        return
    end

    -- The merged creature is as healthy as the healthier of the two was.
    -- Only matters for a Remnant, which has no baseline recorded yet.
    local data = survivor:getModData()
    if data[Keys.baseHealth] == nil then
        data[Keys.baseHealth] = math.max(survivor:getHealth(), absorbed:getHealth())
    end

    absorbed:removeFromWorld()
    absorbed:removeFromSquare()
    Server.setType(survivor, def.mergesInto)
end

-- Only mutual nearest neighbours pair up, so every creature is in at most one
-- pair per sweep and the merges below never touch the same zombie twice.
local function processMerges(candidates, buckets, nowMs)
    local partnerById = {}
    for i = 1, #candidates do
        local candidate = candidates[i]
        local partner = nearestPartner(candidate.zombie, candidate.typeId, buckets)
        if partner then
            partnerById[candidate.zombie:getID()] = { zombie = candidate.zombie, partner = partner, def = candidate.def }
        end
    end

    local stillTogether = {}
    local mergeAfterMs = Creatures.Tuning.mergeSeconds * 1000
    for id, entry in pairs(partnerById) do
        local partnerId = entry.partner:getID()
        local back = partnerById[partnerId]
        if id < partnerId and back and back.partner == entry.zombie then
            local key = id .. ":" .. partnerId
            local since = pairSince[key] or nowMs
            if nowMs - since >= mergeAfterMs then
                merge(entry.zombie, entry.partner, entry.def)
            else
                stillTogether[key] = since
            end
        end
    end
    pairSince = stillTogether
end

-- ----------------------------------------------------------------- caller --

-- When a Caller has a player in sight it calls out: a world sound pulls every
-- creature in range towards it, and the players near enough to hear it are
-- told so their game can play the voice and take the toll on their nerves.
local function updateCaller(zombie, def, nowMs)
    local call = def.call
    local target = zombie:getTarget()
    -- An animal is an IsoPlayer as far as instanceof is concerned.
    if target == nil or not instanceof(target, "IsoPlayer") or instanceof(target, "IsoAnimal") then return end
    if zombie:DistTo(target) > call.range then return end

    local data = zombie:getModData()
    local last = data[Keys.lastCall]
    if last and nowMs >= last and nowMs - last < call.cooldownSeconds * 1000 then return end
    data[Keys.lastCall] = nowMs

    -- Deliberately no source. The engine gives a sound whose source is a
    -- zombie zero pull on other zombies (WorldSoundManager.getSoundAttract),
    -- so passing the Caller itself would make the lure do nothing.
    local x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()
    addSound(nil, math.floor(x), math.floor(y), math.floor(z), call.attractRadius, call.attractVolume)

    local args = { type = def.id, x = x, y = y, z = z, female = zombie:isFemale() }
    if isServer() then
        sendServerCommand(Creatures.MODULE, "CallerCall", args)
    elseif Creatures.onCallerCall then
        Creatures.onCallerCall(args) -- single player: the client code is right here
    end
end

-- ------------------------------------------------------------------ sweep --

local lastSweepMs = 0

local function sweep(nowMs)
    local cell = getCell()
    local zombies = cell and cell:getZombieList()
    if zombies == nil then return end

    local day = Creatures.evolutionDay()
    local merging = Creatures.sandbox("CreatureMerging", true)
    local candidates = {}
    local buckets = {}

    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and not zombie:isDead() and zombie:getCurrentSquare() then
            local def = Creatures.getDefinition(zombie)
            if def then
                if def.call then updateCaller(zombie, def, nowMs) end
                if merging and def.mergesInto and canMerge(zombie, def, day) then
                    local entry = { zombie = zombie, typeId = def.id, def = def }
                    candidates[#candidates + 1] = entry
                    local key = bucketKey(zombie:getX(), zombie:getY(), zombie:getZ())
                    local bucket = buckets[key]
                    if bucket == nil then
                        bucket = {}
                        buckets[key] = bucket
                    end
                    bucket[#bucket + 1] = entry
                end
            end
        end
    end

    if merging then processMerges(candidates, buckets, nowMs) end
end

-- ---------------------------------------------------------------- splitting --

-- Splits wait a tick: spawning from inside the death event itself is asking
-- for trouble.
local pendingSplits = {}

local function onZombieDead(zombie)
    if zombie == nil then return end
    local def = Creatures.getDefinition(zombie)
    local split = def and def.splitOnDeath
    if split == nil then return end

    -- "Incendiary weapons work as well": what burns stays down.
    if zombie:isOnFire() then return end

    pendingSplits[#pendingSplits + 1] = {
        into = split.into,
        count = split.count,
        x = math.floor(zombie:getX()),
        y = math.floor(zombie:getY()),
        z = math.floor(zombie:getZ()),
        -- The dead creature's own health before its multiplier: what the
        -- engine gives an ordinary zombie in this world.
        health = zombie:getModData()[Keys.baseHealth] or 1.0,
    }
end
Events.OnZombieDead.Add(onZombieDead)

local function onTick()
    if #pendingSplits > 0 then
        local splits = pendingSplits
        pendingSplits = {}
        for i = 1, #splits do
            local split = splits[i]
            Server.spawnAs(split.into, split.x, split.y, split.z, split.count, split.health)
        end
    end

    local nowMs = getTimestampMs()
    if nowMs - lastSweepMs >= Creatures.Tuning.sweepSeconds * 1000 or nowMs < lastSweepMs then
        lastSweepMs = nowMs
        local ok, err = pcall(sweep, nowMs)
        if not ok then print("[Daybreak] creature sweep failed: " .. tostring(err)) end
    end
end
Events.OnTick.Add(onTick)
