-- What a Great Collective does: hunt, swallow creatures it touches, shrug off
-- anything but fire, fall apart into Masses, and turn up in the world.
--
-- It is an animal (CollectiveSpecies.lua), and animals keep their modData and
-- position through unloading and saving on their own, so unlike the zombie
-- types it needs no identity bookkeeping. The small registry below only
-- counts them against the sandbox cap and remembers where unmet ones wait.
--
-- The server owns all animal AI; files under server/ load on multiplayer
-- clients too, hence the guard.
if isClient() then return end

require "SCP001/Creatures/CreatureSpawner"
require "SCP001/Creatures/CollectiveSpecies"
require "BuildingObjects/ISBuildUtil" -- buildUtil: double and garage door parts

local Creatures = DaybreakCreatures
local Keys = Creatures.Keys
local Server = Creatures.Server
local Tuning = Creatures.Tuning.collective

local Collectives = {}
Creatures.Collectives = Collectives

local STORE_KEY = "DaybreakCollectives"
local SPLIT_INTO = "mass"
local SWEEP_MS = 1000
local CORPSE_SEARCH_MS = 15000 -- the body appears once the death animation ends

local function log(message, ...)
    print("[Daybreak] " .. string.format(message, ...))
end

local function worldDay()
    return getGameTime():getWorldAgeHours() / 24
end

-- --------------------------------------------------------------- registry --

-- World ModData: { nextId, lastSeedDay, records = { key -> record } }.
-- A record is a live collective (x, y, z, mass, lastSeen) or, with `pending`,
-- a spot where one waits to appear once somebody comes close enough.
local function store()
    local data = ModData.getOrCreate(STORE_KEY)
    if data.records == nil then data.records = {} end
    if data.nextId == nil then data.nextId = 1 end
    return data
end

local function newRecord(fields)
    local data = store()
    local key = "c" .. data.nextId
    data.nextId = data.nextId + 1
    fields.key = key
    fields.lastSeen = worldDay()
    data.records[key] = fields
    return fields
end

local function recordCount()
    local count = 0
    for _ in pairs(store().records) do count = count + 1 end
    return count
end

-- Is there room under the sandbox cap for one more? 0 turns them off.
function Collectives.hasRoom()
    return recordCount() < Creatures.sandbox("CollectiveMax", 3)
end

-- A record not seen for forgetAfterDays frees its slot: one that vanished
-- without dying, or a seed placed somewhere no one ever goes.
local function forgetStale()
    local today = worldDay()
    local records = store().records
    for key, record in pairs(records) do
        if today - (record.lastSeen or today) > Tuning.forgetAfterDays then
            records[key] = nil
        end
    end
end

-- ------------------------------------------------------------------ spawn --

local function livingPlayers()
    local players = {}
    if isServer() then
        local online = getOnlinePlayers()
        for i = 0, online:size() - 1 do
            local player = online:get(i)
            if player and not player:isDead() then players[#players + 1] = player end
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player and not player:isDead() then players[#players + 1] = player end
        end
    end
    return players
end

-- Put a collective of this mass into the world. `record` is the pending seed
-- it fulfils, if any; otherwise it gets a new one.
function Collectives.spawnAt(x, y, z, mass, record)
    local definition = AnimalDefinitions.getDef(Tuning.animalType)
    local breed = definition and definition:getBreedByName(Tuning.breed)
    if breed == nil then
        log("the Great Collective species is not registered")
        return nil
    end

    local ok, animal = pcall(addAnimal, getCell(), x, y, z, Tuning.animalType, breed)
    if not ok or animal == nil then
        log("could not spawn a Great Collective: %s", tostring(animal))
        return nil
    end
    animal:addToWorld()

    record = record or newRecord({})
    record.pending = nil
    record.x, record.y, record.z = x, y, z
    record.mass = mass
    record.lastSeen = worldDay()

    local data = animal:getModData()
    data[Keys.collectiveId] = record.key
    data[Keys.collectiveMass] = mass
    Creatures.applyCollectiveSize(animal)
    if isServer() then animal:transmitModData() end
    return animal
end

-- ----------------------------------------------------------------- hunting --

-- Per-collective runtime state, by record key: its target, timers, and which
-- creatures have been touching it since when.
local state = {}

local function stateFor(key)
    local entry = state[key]
    if entry == nil then
        entry = { touching = {} }
        state[key] = entry
    end
    return entry
end

-- Keep its registry record current, creating one if it has none (it was
-- spawned before the record existed, or its record was forgotten).
local function track(animal)
    local data = animal:getModData()
    local records = store().records
    local key = data[Keys.collectiveId]
    local record = key and records[key]
    if record == nil then
        record = newRecord({})
        data[Keys.collectiveId] = record.key
    end
    record.pending = nil
    record.x = math.floor(animal:getX())
    record.y = math.floor(animal:getY())
    record.z = math.floor(animal:getZ())
    record.mass = Creatures.collectiveMass(animal)
    record.lastSeen = worldDay()
    return record.key
end

local function isHuntable(player, floorZ)
    return math.floor(player:getZ()) == floorZ and player:getVehicle() == nil
        and not player:isGhostMode() and not player:isInvisible()
end

-- The nearest player it can notice, keeping its current one until they get
-- properly away.
local function pickTarget(animal, entry, players)
    local ax, ay = animal:getX(), animal:getY()
    local floorZ = math.floor(animal:getZ())
    local huntSq = Tuning.huntRadius * Tuning.huntRadius
    local loseSq = Tuning.loseRadius * Tuning.loseRadius

    local best, bestSq = nil, nil
    for i = 1, #players do
        local player = players[i]
        if isHuntable(player, floorZ) then
            local dx, dy = player:getX() - ax, player:getY() - ay
            local distanceSq = dx * dx + dy * dy
            local limit = player == entry.target and loseSq or huntSq
            if distanceSq <= limit and (bestSq == nil or distanceSq < bestSq) then
                best, bestSq = player, distanceSq
            end
        end
    end
    return best
end

local function reachOf(animal)
    return Tuning.reach + Tuning.reachPerSize * animal:getData():getSize()
end

-- ------------------------------------------------------------------ lines --

-- The squares a straight line from `from` towards (toX, toY) crosses, handed
-- to visit(fromSquare, toSquare) one wall-edge at a time. A diagonal step is
-- split into its two sides so no wall between them is skipped. Stops at the
-- first visit that returns something, and returns that.
local LINE_STEP = 0.5 -- tiles; small enough never to skip a square

local function walkLine(from, toX, toY, maxDistance, visit)
    local previous = from:getCurrentSquare()
    if previous == nil then return nil end

    local cell = getCell()
    local fromX, fromY = from:getX(), from:getY()
    local z = math.floor(from:getZ())
    local dx, dy = toX - fromX, toY - fromY
    local length = math.sqrt(dx * dx + dy * dy)
    if maxDistance and length > maxDistance then
        dx, dy = dx * maxDistance / length, dy * maxDistance / length
        length = maxDistance
    end

    local steps = math.max(1, math.ceil(length / LINE_STEP))
    for i = 1, steps do
        local square = cell:getGridSquare(math.floor(fromX + dx * i / steps), math.floor(fromY + dy * i / steps), z)
        if square == nil then return nil end
        if square ~= previous then
            local stepX = square:getX() - previous:getX()
            local stepY = square:getY() - previous:getY()
            local side = nil
            if stepX ~= 0 and stepY ~= 0 then
                side = cell:getGridSquare(previous:getX() + stepX, previous:getY(), z)
            end
            local result
            if side then
                result = visit(previous, side) or visit(side, square)
            else
                result = visit(previous, square)
            end
            if result then return result end
            previous = square
        end
    end
    return nil
end

-- A window it has already smashed or found open still blocks walking, but
-- not reaching through - and it is big enough to reach.
local function isOpenWindowBetween(a, b)
    local window = a:getWindowTo(b)
    return window ~= nil and (window:isSmashed() or window:IsOpen())
end

-- Nothing solid between the two, for its hit. IsoGameCharacter:CanSee is no
-- use here - asked about one character by another, its two overloads call
-- each other until the stack overflows.
local function hasClearLine(from, to)
    local blocked = walkLine(from, to:getX(), to:getY(), nil, function(a, b)
        if a:isBlockedTo(b) and not isOpenWindowBetween(a, b) then return true end
        return nil
    end)
    return not blocked
end

-- What stops it walking from a to b. The engine's isBlockedTo covers walls,
-- windows, doors and stairs; a fence you would hop over is not in it, but a
-- creature this size does not hop.
local function isEdgeBlocked(a, b)
    return a:isBlockedTo(b) or a:isHoppableTo(b)
end

-- The first blocked edge between it and a point, as { a = its side, b = the
-- far side }, or nil if the way is clear within maxDistance.
local function firstBlockedEdge(from, toX, toY, maxDistance)
    return walkLine(from, toX, toY, maxDistance, function(a, b)
        if isEdgeBlocked(a, b) then return { a = a, b = b } end
        return nil
    end)
end

-- --------------------------------------------------------------- barriers --

-- Walking into a door, window, barricade, fence or anything built or moved
-- into its way breaks it, the way PZTheMutants' Wrecker breaks what it charges
-- into: every layer on that edge, barricade first. Walls of the map itself
-- hold. The Wrecker hands each barrier to the engine's own Thump, but Thump
-- only does damage when the thumper is a zombie, so these go through the
-- sledgehammer's route instead (ISDestroyStuffAction:complete).
local MAX_BREAK_PASSES = 8

-- Which square owns the edge between two orthogonal neighbours: walls live on
-- a square's north and west edges.
local function edgeBetween(a, b)
    local dx, dy = b:getX() - a:getX(), b:getY() - a:getY()
    if dx == 0 and dy == -1 then return { boundary = a, north = true, dir = IsoDirections.N } end
    if dx == 0 and dy == 1 then return { boundary = b, north = true, dir = IsoDirections.S } end
    if dx == -1 and dy == 0 then return { boundary = a, north = false, dir = IsoDirections.W } end
    if dx == 1 and dy == 0 then return { boundary = b, north = false, dir = IsoDirections.E } end
    return nil
end

local function isOnEdge(object, north)
    local properties = object:getProperties()
    if properties == nil then return false end
    if north then
        return properties:has(IsoFlagType.collideN) or properties:has(IsoFlagType.HoppableN)
            or properties:has(IsoFlagType.TallHoppableN)
    end
    return properties:has(IsoFlagType.collideW) or properties:has(IsoFlagType.HoppableW)
        or properties:has(IsoFlagType.TallHoppableW)
end

local function isFence(object, north)
    local properties = object:getProperties()
    if properties == nil then return false end
    if north then
        return properties:has(IsoFlagType.HoppableN) or properties:has(IsoFlagType.TallHoppableN)
    end
    return properties:has(IsoFlagType.HoppableW) or properties:has(IsoFlagType.TallHoppableW)
end

local function isSolidBlock(object)
    local properties = object:getProperties()
    if properties == nil then return false end
    return properties:has(IsoFlagType.solid) or properties:has(IsoFlagType.solidtrans)
        or object:isMovedThumpable()
end

-- Everything that could be in the way on that edge, in the Wrecker's order.
local function barrierCandidates(a, b, edge)
    local candidates, seen = {}, {}
    local function add(object)
        if object ~= nil and not seen[object] then
            seen[object] = true
            candidates[#candidates + 1] = object
        end
    end
    add(a:getDoorTo(b))
    add(a:getWindowTo(b))
    add(a:getWindowThumpableTo(b))
    add(a:getHoppableThumpableTo(b))
    add(a:getHoppableTo(b))
    add(edge.boundary:getThumpable(edge.north))
    add(edge.boundary:getThumpableWall(edge.north))
    add(edge.boundary:getHoppableWall(edge.north))
    local objects = edge.boundary:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if isOnEdge(object, edge.north) then add(object) end
    end
    local blocking = b:getObjects()
    for i = 0, blocking:size() - 1 do
        local object = blocking:get(i)
        if isSolidBlock(object) then add(object) end
    end
    return candidates
end

-- The outermost breakable thing on the edge, or nil. getThumpableFor puts a
-- barricade ahead of the door or window it covers, as vanilla does. A map
-- fence is never thumpable, so fences come last, on their climb-over flags.
local function outermostBarrier(a, b, edge, animal)
    local fences = BentFences.getInstance()
    local candidates = barrierCandidates(a, b, edge)
    for i = 1, #candidates do
        local candidate = candidates[i]
        if candidate:getObjectIndex() ~= -1 then
            if fences:isBentObject(candidate) or fences:isUnbentObject(candidate, edge.dir) then
                return candidate
            end
            local ok, target = pcall(function() return candidate:getThumpableFor(animal) end)
            if ok and target ~= nil then return target end
        end
    end
    for i = 1, #candidates do
        local candidate = candidates[i]
        if candidate:getObjectIndex() ~= -1 and isFence(candidate, edge.north) then
            return candidate
        end
    end
    return nil
end

local function breakSound(target)
    local ok, sound = pcall(function()
        if instanceof(target, "IsoThumpable") then return target:getBreakSound() end
        return IsoThumpable.GetBreakFurnitureSound(target:getSprite())
    end)
    if ok then return sound end
    return nil
end

-- Announce a break: every creature in earshot hears it, and each player's
-- game plays the crash where it happened.
local function breakNoise(square, sound)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    addSound(nil, x, y, z, Tuning.breakNoiseRadius, Tuning.breakNoiseRadius)
    if sound == nil then return end
    local args = { x = x + 0.5, y = y + 0.5, z = z, sound = sound }
    if isServer() then
        sendServerCommand(Creatures.MODULE, "CollectiveSound", args)
    elseif Creatures.playCollectiveSound then
        Creatures.playCollectiveSound(args)
    end
end

local function removeObject(object)
    local square = object:getSquare()
    if square then square:transmitRemoveItemFromSquare(object) end
end

-- Break one barrier. Fences are bent, then smashed, as a car does. A window
-- is smashed and its frame stays. Anything else is removed outright, a double
-- or garage door together with its other parts, contents dumped on the floor.
local function breakOne(target, edge)
    local fences = BentFences.getInstance()
    if fences:isBentObject(target) then
        fences:smashFence(target, edge.dir)
        return
    end
    if fences:isUnbentObject(target, edge.dir) then
        fences:bendFence(target, edge.dir)
        return
    end
    if instanceof(target, "IsoWindow") then
        if not target:isSmashed() then target:smashWindow() end
        return
    end

    local square = target:getSquare()
    local sound = breakSound(target)
    local parts = nil
    local ok, doubleDoor = pcall(buildUtil.getDoubleDoorObjects, target)
    if ok and doubleDoor and #doubleDoor > 0 then parts = doubleDoor end
    local ok2, garageDoor = pcall(buildUtil.getGarageDoorObjects, target)
    if parts == nil and ok2 and garageDoor and #garageDoor > 0 then parts = garageDoor end

    pcall(function() target:dumpContentsInSquare() end)
    if parts then
        for i = 1, #parts do removeObject(parts[i]) end
    else
        removeObject(target)
    end
    if square then breakNoise(square, sound) end
end

-- Break everything on the edge between a and b. True if anything broke.
local function breakThrough(a, b, animal)
    local edge = edgeBetween(a, b)
    if edge == nil then return false end

    local broke = false
    for _ = 1, MAX_BREAK_PASSES do
        local target = outermostBarrier(a, b, edge, animal)
        if target == nil then break end
        local ok, err = pcall(breakOne, target, edge)
        if not ok then
            log("could not break %s: %s", tostring(target), tostring(err))
            break
        end
        broke = true
        -- A smashed window is as broken as it gets; the same thing coming
        -- back means no progress, so stop rather than spin.
        if outermostBarrier(a, b, edge, animal) == target then break end
    end
    return broke
end

local function isBreakable(a, b, animal)
    local edge = edgeBetween(a, b)
    return edge ~= nil and outermostBarrier(a, b, edge, animal) ~= nil
end

-- The square it is facing, if a wall edge is in between: what it has walked
-- into, when its path led it somewhere the straight line did not.
local function edgeAhead(animal)
    local square = animal:getCurrentSquare()
    local direction = animal:getDir()
    if square == nil or direction == nil then return nil end
    if direction:dx() ~= 0 and direction:dy() ~= 0 then return nil end
    local ahead = square:getAdjacentSquare(direction)
    if ahead and isEdgeBlocked(square, ahead) then return { a = square, b = ahead } end
    return nil
end

-- ----------------------------------------------------------------- hunting --

-- The hit is the engine's own animal attack (IsoPlayer.hitConsequences with
-- an animal as the attacker: a wound from the species' damage), applied on
-- the victim's own game. See Creatures.applyCollectiveHit.
local function strike(animal, player, entry, nowMs)
    local knockdown = false
    local lastKnockdown = entry.lastKnockdownMs
    if (lastKnockdown == nil or nowMs - lastKnockdown >= Tuning.knockdownCooldownSeconds * 1000 or nowMs < lastKnockdown)
        and ZombRandFloat(0.0, 1.0) < Tuning.knockdownChance then
        knockdown = true
        entry.lastKnockdownMs = nowMs
    end

    if isServer() then
        sendServerCommand(player, Creatures.MODULE, "CollectiveHit",
            { animal = animal:getOnlineID(), knockdown = knockdown })
    elseif Creatures.applyCollectiveHit then
        Creatures.applyCollectiveHit(player, animal, knockdown)
    end
end

local function isDue(last, nowMs, seconds)
    return last == nil or nowMs - last >= seconds * 1000 or nowMs < last
end

local function hunt(animal, entry, players, nowMs)
    local target = pickTarget(animal, entry, players)
    entry.target = target
    if target == nil then
        entry.approach = nil
        entry.bestDistance = nil
        return
    end
    -- Staggered by the last thing it broke.
    if entry.pauseUntilMs and nowMs < entry.pauseUntilMs then return end

    local reach = reachOf(animal)
    local targetX, targetY = target:getX(), target:getY()

    -- Whatever breakable stands between it and its prey within reach, or
    -- right in front of it, goes - and it staggers for a moment.
    local edge = firstBlockedEdge(animal, targetX, targetY, reach) or edgeAhead(animal)
    if edge and breakThrough(edge.a, edge.b, animal) then
        animal:stopAllMovementNow()
        entry.pauseUntilMs = nowMs + Tuning.breakPauseSeconds * 1000
        entry.approach = nil
        entry.bestDistance = nil
        return
    end

    local dx, dy = targetX - animal:getX(), targetY - animal:getY()
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= reach then
        animal:faceThisObject(target)
        -- It looms over a downed player instead of beating them on the floor:
        -- getting up is the chance to run.
        if target:isOnFloor() then return end
        if isDue(entry.lastAttackMs, nowMs, Tuning.attackCooldownSeconds) and hasClearLine(animal, target) then
            entry.lastAttackMs = nowMs
            animal:stopAllMovementNow()
            strike(animal, target, entry, nowMs)
        end
        return
    end

    -- Getting nowhere - the pathfinder will not route an animal through a
    -- closed door - so head for the first breakable barrier on the straight
    -- line to its prey and go through that instead.
    if entry.bestDistance == nil or distance < entry.bestDistance - 1 then
        entry.bestDistance = distance
        entry.progressMs = nowMs
    elseif isDue(entry.progressMs, nowMs, Tuning.stuckSeconds) then
        entry.progressMs = nowMs
        entry.bestDistance = distance
        local blocked = firstBlockedEdge(animal, targetX, targetY, nil)
        if blocked and isBreakable(blocked.a, blocked.b, animal) then
            entry.approach = { x = blocked.a:getX(), y = blocked.a:getY(), z = blocked.a:getZ() }
            entry.lastPathMs = nowMs
            animal:pathToLocation(entry.approach.x, entry.approach.y, entry.approach.z)
            return
        end
    end

    local approach = entry.approach
    if approach then
        local ax, ay = approach.x + 0.5 - animal:getX(), approach.y + 0.5 - animal:getY()
        if ax * ax + ay * ay > 1.5 * 1.5 then return end
        entry.approach = nil -- arrived; the break check above takes it from here
    end

    if isDue(entry.lastPathMs, nowMs, Tuning.repathSeconds) then
        entry.lastPathMs = nowMs
        animal:pathToCharacter(target)
    end
end

-- -------------------------------------------------------------- absorbing --

-- A creature that stays in contact for absorbSeconds is swallowed and its
-- bodies added, one per sweep, until maxMass. At maxMass nothing more fits.
local function absorb(animal, entry, zombies, nowMs)
    local mass = Creatures.collectiveMass(animal)
    if mass >= Tuning.maxMass then
        entry.touching = {}
        return
    end

    local radius = Tuning.absorbDistance * animal:getData():getSize() / Tuning.minSize
    local radiusSq = radius * radius
    local ax, ay = animal:getX(), animal:getY()
    local floorZ = math.floor(animal:getZ())

    local touching = {}
    local swallowed = nil
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and not zombie:isDead() and math.floor(zombie:getZ()) == floorZ then
            local dx, dy = zombie:getX() - ax, zombie:getY() - ay
            if dx * dx + dy * dy <= radiusSq then
                local id = zombie:getID()
                local since = entry.touching[id] or nowMs
                touching[id] = since
                if swallowed == nil and nowMs - since >= Tuning.absorbSeconds * 1000 then
                    swallowed = zombie
                end
            end
        end
    end
    entry.touching = touching
    if swallowed == nil then return end

    local def = Creatures.getDefinition(swallowed)
    touching[swallowed:getID()] = nil
    swallowed:removeFromWorld()
    swallowed:removeFromSquare()

    animal:getModData()[Keys.collectiveMass] = math.min(Tuning.maxMass, mass + (def and def.mass or 1))
    Creatures.applyCollectiveSize(animal)
    if isServer() then animal:transmitModData() end
end

-- -------------------------------------------------------------- toughness --

-- Health before the hit that is being processed, by record key. The engine
-- takes the damage between OnWeaponHitCharacter and OnWeaponHitXp; the
-- second hands part of it back, the more bodies the more. Fire damage never
-- passes through a weapon hit, so burning stays the quick way.
local healthBeforeHit = {}

local function onWeaponHitCharacter(wielder, target, weapon, damage)
    if not Creatures.isCollective(target) then return end
    local key = target:getModData()[Keys.collectiveId]
    if key then healthBeforeHit[key] = target:getHealth() end
end
Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)

local function onWeaponHitXp(owner, weapon, hitObject, damage, hitCount)
    if not Creatures.isCollective(hitObject) then return end
    local key = hitObject:getModData()[Keys.collectiveId]
    local before = key and healthBeforeHit[key]
    if before == nil then return end
    healthBeforeHit[key] = nil

    local lost = before - hitObject:getHealth()
    if lost <= 0 then return end
    local divisor = math.max(1, Creatures.collectiveMass(hitObject) * Tuning.toughnessPerBody)
    hitObject:setHealth(before - lost / divisor)
end
Events.OnWeaponHitXp.Add(onWeaponHitXp)

-- ------------------------------------------------------------------ death --

-- Beaten down, it falls apart into Masses and leaves no body: it came apart,
-- it did not die. Burned, it stays dead and its body stays with it.
local pendingSplits = {}
local pendingCorpses = {}

local function onCharacterDeath(character)
    if not Creatures.isCollective(character) then return end

    local data = character:getModData()
    local key = data[Keys.collectiveId]
    if key then
        store().records[key] = nil
        state[key] = nil
        healthBeforeHit[key] = nil
    end

    if character:isOnFire() then return end

    local mass = Creatures.collectiveMass(character)
    local x, y, z = math.floor(character:getX()), math.floor(character:getY()), math.floor(character:getZ())
    pendingSplits[#pendingSplits + 1] = {
        x = x, y = y, z = z,
        count = math.max(1, math.min(Tuning.maxSplit, math.floor(mass / 4))),
    }
    if key then
        pendingCorpses[#pendingCorpses + 1] = { key = key, x = x, y = y, z = z, untilMs = getTimestampMs() + CORPSE_SEARCH_MS }
    end
end
Events.OnCharacterDeath.Add(onCharacterDeath)

-- The body copies the animal's modData, which is how it is recognised.
local function removeCorpse(entry)
    local cell = getCell()
    for dx = -2, 2 do
        for dy = -2, 2 do
            local square = cell:getGridSquare(entry.x + dx, entry.y + dy, entry.z)
            local bodies = square and square:getDeadBodys()
            if bodies then
                for i = bodies:size() - 1, 0, -1 do
                    local body = bodies:get(i)
                    if body and body:getModData()[Keys.collectiveId] == entry.key then
                        square:removeCorpse(body, false)
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------- origins --

-- Once a day after the unlock: maybe place a new one far from a random
-- player. It waits there, unmet, until someone comes close enough.
local function trySeed()
    local def = Creatures.get("collective")
    if def == nil or not Creatures.isUnlocked(def, Creatures.evolutionDay()) then return end

    forgetStale()
    if not Collectives.hasRoom() then return end
    if ZombRandFloat(0.0, 1.0) >= Tuning.seedChancePerDay then return end

    local players = livingPlayers()
    if #players == 0 then return end
    local player = players[ZombRand(#players) + 1]
    local angle = ZombRandFloat(0.0, math.pi * 2)
    local distance = Tuning.seedMinDistance + ZombRand(Tuning.seedMaxDistance - Tuning.seedMinDistance + 1)

    newRecord({
        pending = true,
        x = math.floor(player:getX() + math.cos(angle) * distance),
        y = math.floor(player:getY() + math.sin(angle) * distance),
        z = 0,
        mass = Tuning.startMass,
    })
end

local function onEveryHours()
    local data = store()
    local today = math.floor(worldDay())
    if data.lastSeedDay == today then return end
    data.lastSeedDay = today
    trySeed()
end
Events.EveryHours.Add(onEveryHours)

local function isStandable(square)
    return square ~= nil and square:isSolidFloor() and square:isOutside()
        and not square:has(IsoFlagType.water) and square:isFree(false)
end

-- Nearest open outdoor square within ten tiles, rings outward.
local function findSpawnSquare(cell, x, y, z)
    for radius = 0, 10 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.max(math.abs(dx), math.abs(dy)) == radius then
                    local square = cell:getGridSquare(x + dx, y + dy, z)
                    if isStandable(square) then return square end
                end
            end
        end
    end
    return nil
end

local function anyPlayerWithin(players, x, y, radius)
    local radiusSq = radius * radius
    for i = 1, #players do
        local dx, dy = players[i]:getX() - x, players[i]:getY() - y
        if dx * dx + dy * dy <= radiusSq then return true end
    end
    return false
end

-- A pending one appears once its spot is loaded - someone came within the
-- loaded area - but never in plain view.
local function materialize(players)
    local cell = getCell()
    local records = store().records
    for key, record in pairs(records) do
        if record.pending and cell:getGridSquare(record.x, record.y, record.z) ~= nil
            and not anyPlayerWithin(players, record.x, record.y, Tuning.spawnClearance) then
            local square = findSpawnSquare(cell, record.x, record.y, record.z)
            if square then
                Collectives.spawnAt(square:getX(), square:getY(), square:getZ(), record.mass or Tuning.startMass, record)
            else
                -- Nowhere to stand (a lake, a forest): forget it, and let a
                -- later day seed somewhere else.
                records[key] = nil
            end
        end
    end
end

-- ------------------------------------------------------------------ sweep --

-- An animal runs from any zombie within six tiles (BaseAnimalBehavior.spotted,
-- whatever its fleeZombies says) and from anything but a player that hits it
-- (fleeFromAttacker). A Collective runs from nothing. Both kinds of flight
-- start a path to a location - its own paths are to a character, or to the
-- barrier it is heading for - so any other location path is cancelled the
-- tick it starts: back onto its prey if it has one, otherwise it stays put.
local loaded = {}

local function isOurPath(entry, path)
    local approach = entry and entry.approach
    if approach == nil then return false end
    return math.abs(path:getTargetX() - (approach.x + 0.5)) < 1.5
        and math.abs(path:getTargetY() - (approach.y + 0.5)) < 1.5
end

local function holdCourse(nowMs)
    for key, animal in pairs(loaded) do
        if animal:isDead() or animal:getCurrentSquare() == nil then
            loaded[key] = nil
        else
            local attacker = animal:getAttackedBy()
            if attacker and (instanceof(attacker, "IsoAnimal") or not instanceof(attacker, "IsoPlayer")) then
                animal:setAttackedBy(nil)
            end

            local path = animal:getPathFindBehavior2()
            if path and path:isMovingUsingPathFind() and path:isGoalLocation() then
                local entry = state[key]
                if not isOurPath(entry, path) then
                    local paused = entry and entry.pauseUntilMs and nowMs < entry.pauseUntilMs
                    if entry and entry.target and not paused then
                        entry.lastPathMs = nowMs
                        animal:pathToCharacter(entry.target)
                    else
                        animal:stopAllMovementNow()
                    end
                end
            end
        end
    end
end

local function sweep(nowMs)
    local cell = getCell()
    if cell == nil then return end
    loaded = {}

    local players = livingPlayers()
    local animals = cell:getAnimals()
    local zombies = cell:getZombieList()
    if animals then
        for i = 0, animals:size() - 1 do
            local animal = animals:get(i)
            if Creatures.isCollective(animal) and not animal:isDead() then
                local key = track(animal)
                local entry = stateFor(key)
                loaded[key] = animal
                -- Zombies close by drive an animal's stress up; nothing frightens it.
                animal:setDebugStress(0)
                Creatures.applyCollectiveSize(animal)
                hunt(animal, entry, players, nowMs)
                if zombies then absorb(animal, entry, zombies, nowMs) end
            end
        end
    end
    materialize(players)
end

local lastSweepMs = 0

local function onTick()
    if #pendingSplits > 0 then
        local splits = pendingSplits
        pendingSplits = {}
        for i = 1, #splits do
            local split = splits[i]
            Server.spawnAs(SPLIT_INTO, split.x, split.y, split.z, split.count, 1.0)
        end
    end

    local nowMs = getTimestampMs()
    local okHold, holdErr = pcall(holdCourse, nowMs)
    if not okHold then log("collective course hold failed: %s", tostring(holdErr)) end
    if nowMs - lastSweepMs < SWEEP_MS and nowMs >= lastSweepMs then return end
    lastSweepMs = nowMs

    if #pendingCorpses > 0 then
        local stillWaiting = {}
        for i = 1, #pendingCorpses do
            local entry = pendingCorpses[i]
            if not removeCorpse(entry) and nowMs < entry.untilMs then
                stillWaiting[#stillWaiting + 1] = entry
            end
        end
        pendingCorpses = stillWaiting
    end

    local ok, err = pcall(sweep, nowMs)
    if not ok then log("collective sweep failed: %s", tostring(err)) end
end
Events.OnTick.Add(onTick)
