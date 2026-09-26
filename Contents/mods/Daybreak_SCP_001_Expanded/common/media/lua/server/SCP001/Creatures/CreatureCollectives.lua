-- What a Great Collective does: hunt, swallow creatures it touches, shrug off
-- anything but fire, fall apart into Masses, and turn up in the world.
--
-- Its hunting follows the T-rex of Irish's Dinosaurs (Workshop 3784875732):
-- noticed by range, chased by the engine's own pathfinding, fences smashed
-- with a swing, attacks as timed swings, roaming between hunts, and never a
-- step indoors. How it looks and animates is the look table in
-- CollectiveSpecies.lua.
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

local Creatures = DaybreakCreatures
local Keys = Creatures.Keys
local Server = Creatures.Server
local Tuning = Creatures.Tuning.collective
local Look = Creatures.CollectiveLook

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

-- ------------------------------------------------------------------- state --

-- Per-collective runtime state, by record key: what it is doing, its prey
-- and what it remembers of them, its timers, and which creatures have been
-- touching it since when.
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

local function isDue(last, nowMs, seconds)
    return last == nil or nowMs - last >= seconds * 1000 or nowMs < last
end

local function randomBetween(minValue, maxValue)
    return minValue + ZombRandFloat(0.0, 1.0) * (maxValue - minValue)
end

-- How far its blow reaches, from its centre. It grows with its size.
local function reachOf(animal)
    return Tuning.reach + Tuning.reachPerSize * animal:getData():getSize()
end

local function isOutside(square)
    return square ~= nil and square:isOutside()
end

local function isOpenOutdoorSquare(square)
    return isOutside(square) and not square:isSolid() and not square:isSolidTrans()
end

-- --------------------------------------------------------- animation hooks --

-- The look's animation variables (CollectiveSpecies.lua). The marker lets its
-- animset nodes tell a collective from any other animal sharing the set.
-- Custom animation variables do not travel with an animal, so in
-- multiplayer every client's game is told to set them too, for as long as
-- they last (CollectiveClient.lua).
local function setAnimation(animal, variable, on, seconds)
    if not variable then return end
    if on then animal:setVariable(variable, true) else animal:clearVariable(variable) end
    if on and isServer() then
        sendServerCommand(Creatures.MODULE, "CollectiveAction",
            { animal = animal:getOnlineID(), variable = variable, seconds = seconds })
    end
end

-- One-off actions with a pulse animation of their own (absorbing).
local pulses = {}

local function playAction(animal, action, nowMs)
    local variable = Look.actions[action]
    if not variable then return end
    setAnimation(animal, variable, true, Look.pulseSeconds)
    pulses[#pulses + 1] = { animal = animal, variable = variable, untilMs = nowMs + Look.pulseSeconds * 1000 }
end

local function endPulses(nowMs)
    if #pulses == 0 then return end
    local running = {}
    for i = 1, #pulses do
        local pulse = pulses[i]
        if nowMs >= pulse.untilMs or pulse.untilMs - nowMs > Look.pulseSeconds * 1000 then
            pulse.animal:clearVariable(pulse.variable)
        else
            running[#running + 1] = pulse
        end
    end
    pulses = running
end

-- ---------------------------------------------------------------- movement --

-- It moves the way Irish's Dinosaurs moves its T-rex: by the engine's own
-- pathfinding, asked for a path only when the old one no longer does.
-- Nothing of the animal's own movement is held off; its species leaves it
-- little of its own to do (CollectiveSpecies.lua), and the brain below keeps
-- it busy.
local function cancelPath(animal)
    local path = animal:getPathFindBehavior2()
    if path then path:cancel() end
end

local function prepareToMove(animal, resetAction)
    animal:setIgnoreMovement(false)
    animal:getBehavior():setBlockMovement(false)
    animal:clearVariable("sittingAnim")
    animal:clearVariable("idleAction")
    if not Look.canRun then animal:clearVariable("animalRunning") end
    if resetAction then animal:getBehavior():resetBehaviorAction() end
end

local function stopMoving(animal, hard)
    cancelPath(animal)
    animal:clearVariable("animalRunning")
    if hard then animal:stopAllMovementNow() end
end

local function pathToLocation(animal, x, y, z, resetAction)
    prepareToMove(animal, resetAction)
    animal:pathToLocation(math.floor(x), math.floor(y), math.floor(z))
end

local function pathToCharacter(animal, target, resetAction)
    prepareToMove(animal, resetAction)
    animal:pathToCharacter(target)
end

local function isPathMoving(animal)
    if animal:isPathfindRunning() then return true end
    local path = animal:getPathFindBehavior2()
    return path ~= nil and (path:isMovingUsingPathFind() or path:shouldBeMoving() or path:hasStartedMoving())
end

local function faceToward(animal, x, y)
    local dx, dy = x - animal:getX(), y - animal:getY()
    local length = math.sqrt(dx * dx + dy * dy)
    if length > 0.001 then animal:setTargetAndCurrentDirection(dx / length, dy / length) end
end

-- Being hit, knocked over or falling: the engine's own reaction plays out,
-- and it waits.
local function inNativeReaction(animal)
    if animal:hasHitReaction() or animal:isKnockedDown() or animal:isFalling() or animal:isStaggerBack() then
        return true
    end
    local name = string.lower(tostring(animal:getCurrentActionContextStateName() or ""))
    return name == "hitreaction" or name == "falldown" or name == "onground"
        or name == "death" or name == "deadbody"
end

-- ------------------------------------------------------------------- lines --

-- Walks the squares a straight line from (fromX, fromY) to (toX, toY) crosses,
-- one grid edge at a time, handing each to visit(fromSquare, toSquare). A
-- line through a corner exactly visits both ways round, and `corner` decides.
-- Stops at the first visit that returns something, and returns that.
local function traverse(fromX, fromY, toX, toY, z, maxSteps, visit, corner)
    local cell = getCell()
    local x, y = math.floor(fromX), math.floor(fromY)
    local endX, endY = math.floor(toX), math.floor(toY)
    local dx, dy = toX - fromX, toY - fromY
    if math.abs(dx) < 0.0001 and math.abs(dy) < 0.0001 then return nil end
    local stepX = dx > 0 and 1 or (dx < 0 and -1 or 0)
    local stepY = dy > 0 and 1 or (dy < 0 and -1 or 0)
    local inf = math.huge
    local tDeltaX = stepX ~= 0 and math.abs(1.0 / dx) or inf
    local tDeltaY = stepY ~= 0 and math.abs(1.0 / dy) or inf
    local tMaxX = stepX > 0 and ((x + 1) - fromX) / dx or (stepX < 0 and (fromX - x) / -dx or inf)
    local tMaxY = stepY > 0 and ((y + 1) - fromY) / dy or (stepY < 0 and (fromY - y) / -dy or inf)

    for _ = 1, maxSteps do
        if x == endX and y == endY then return nil end
        local from = cell:getGridSquare(x, y, z)
        if from == nil then return nil end
        if tMaxX + 0.000001 < tMaxY then
            local to = cell:getGridSquare(x + stepX, y, z)
            if to == nil then return nil end
            local result = visit(from, to)
            if result then return result end
            x, tMaxX = x + stepX, tMaxX + tDeltaX
        elseif tMaxY + 0.000001 < tMaxX then
            local to = cell:getGridSquare(x, y + stepY, z)
            if to == nil then return nil end
            local result = visit(from, to)
            if result then return result end
            y, tMaxY = y + stepY, tMaxY + tDeltaY
        else
            local result = corner(from, x, y, stepX, stepY)
            if result then return result end
            x, y = x + stepX, y + stepY
            tMaxX, tMaxY = tMaxX + tDeltaX, tMaxY + tDeltaY
        end
    end
    return nil
end

-- Can its blow reach from where it stands to (x, y)? Walls, closed doors and
-- windows stop it; low fences do not. Past a corner, either way round will do.
local function attackPathClear(animal, x, y)
    local z = math.floor(animal:getZ())
    local cell = getCell()
    local function blocked(a, b) return a:isBlockedTo(b) end
    local blockedAt = traverse(animal:getX(), animal:getY(), x, y, z, 64,
        function(a, b) if blocked(a, b) then return true end return nil end,
        function(from, fx, fy, stepX, stepY)
            local sideX = cell:getGridSquare(fx + stepX, fy, z)
            local sideY = cell:getGridSquare(fx, fy + stepY, z)
            local diagonal = cell:getGridSquare(fx + stepX, fy + stepY, z)
            if diagonal == nil then return true end
            local viaX = sideX ~= nil and not blocked(from, sideX) and not blocked(sideX, diagonal)
            local viaY = sideY ~= nil and not blocked(from, sideY) and not blocked(sideY, diagonal)
            if viaX or viaY then return nil end
            return true
        end)
    return blockedAt == nil
end

-- ------------------------------------------------------------------ fences --

-- Fences are what it smashes through: low or high, the map's own or anything
-- built. It does not break into buildings - it stays outdoors.
local function isFenceObject(object)
    if object == nil then return false end
    if object:isHoppable() or object:isTallHoppable() then return true end
    local name = object:getSpriteName()
    if name then
        name = string.lower(name)
        return string.find(name, "fence", 1, true) ~= nil or string.find(name, "fencing", 1, true) ~= nil
    end
    return false
end

local function isOnEdge(object, north)
    local properties = object:getProperties()
    if properties == nil then return false end
    if north then
        return properties:has(IsoFlagType.HoppableN) or properties:has(IsoFlagType.TallHoppableN)
            or properties:has(IsoFlagType.collideN)
    end
    return properties:has(IsoFlagType.HoppableW) or properties:has(IsoFlagType.TallHoppableW)
        or properties:has(IsoFlagType.collideW)
end

-- The fence on the edge between two orthogonal neighbours, if any.
local function fenceBetween(a, b)
    if a:getZ() ~= b:getZ() then return nil end
    local dx, dy = b:getX() - a:getX(), b:getY() - a:getY()
    if math.abs(dx) + math.abs(dy) ~= 1 then return nil end
    local getters = {
        function() return a:getHoppableTo(b) end,
        function() return a:getWallHoppableTo(b) end,
        function() return a:getHoppableThumpableTo(b) end,
        function() return b:getHoppableTo(a) end,
        function() return b:getWallHoppableTo(a) end,
        function() return b:getHoppableThumpableTo(a) end,
        function() return a:testCollideSpecialObjects(b) end,
    }
    for i = 1, #getters do
        local ok, object = pcall(getters[i])
        if ok and isFenceObject(object) then return object end
    end
    -- Walls and fences live on a square's north and west edges: the fence
    -- has to be on the edge being crossed, not the square's other one.
    local owner = (dx < 0 or dy < 0) and a or b
    local north = dy ~= 0
    local objects = owner:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if isFenceObject(object) and isOnEdge(object, north) then return object end
    end
    return nil
end

-- The first fence on the straight line from it to (x, y), within maxSteps
-- grid edges: the fence, and the squares either side of it.
local function fenceOnLineTo(animal, x, y, maxSteps)
    local z = math.floor(animal:getZ())
    local cell = getCell()
    local found = traverse(animal:getX(), animal:getY(), x, y, z, maxSteps,
        function(a, b)
            local fence = fenceBetween(a, b)
            if fence then return { fence = fence, near = a, far = b } end
            return nil
        end,
        function(from, fx, fy, stepX, stepY)
            for _, side in ipairs({ { stepX, 0 }, { 0, stepY } }) do
                if side[1] ~= 0 or side[2] ~= 0 then
                    local to = cell:getGridSquare(fx + side[1], fy + side[2], z)
                    local fence = to and fenceBetween(from, to)
                    if fence then return { fence = fence, near = from, far = to } end
                end
            end
            return nil
        end)
    if found then return found.fence, found.near, found.far end
    return nil
end

-- The fence right ahead of it on its current path, if any: what it is about
-- to walk into while roaming.
local function fenceOnPathAhead(animal, fallbackX, fallbackY)
    local current = animal:getCurrentSquare()
    if current == nil then return nil end
    local aimX, aimY = fallbackX, fallbackY
    local path = animal:getPathFindBehavior2()
    local ok, isSet, nextX, nextY = pcall(function() return path.pathNextIsSet, path.pathNextX, path.pathNextY end)
    if ok and isSet and nextX and nextY then aimX, aimY = nextX, nextY end
    local dx, dy = aimX - animal:getX(), aimY - animal:getY()
    local stepX = dx > 0.15 and 1 or (dx < -0.15 and -1 or 0)
    local stepY = dy > 0.15 and 1 or (dy < -0.15 and -1 or 0)
    local steps = math.abs(dx) >= math.abs(dy) and { { stepX, 0 }, { 0, stepY } } or { { 0, stepY }, { stepX, 0 } }
    local cell = getCell()
    for _, step in ipairs(steps) do
        if step[1] ~= 0 or step[2] ~= 0 then
            local ahead = cell:getGridSquare(current:getX() + step[1], current:getY() + step[2], current:getZ())
            local fence = ahead and fenceBetween(current, ahead)
            if fence then return fence, current, ahead end
        end
    end
    return nil
end

local function fenceStillStands(fence)
    return fence ~= nil and fence:getObjectIndex() ~= -1
        and not (instanceof(fence, "IsoThumpable") and fence:isDestroyed())
end

-- The crash, heard by every creature in earshot and played on every game.
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

local function fenceSound(fence)
    local ok, sound = pcall(function()
        if instanceof(fence, "IsoThumpable") then return fence:getBreakSound() end
        return IsoThumpable.GetBreakFurnitureSound(fence:getSprite())
    end)
    if ok then return sound end
    return nil
end

-- Gone: taken off the map outright, the way the T-rex does it.
local function destroyFence(animal, fence)
    if not fenceStillStands(fence) then return true end
    local square = fence:getSquare()
    local sound = fenceSound(fence)

    if instanceof(fence, "IsoThumpable") then
        pcall(function()
            fence:setHealth(0)
            fence:destroy()
        end)
    elseif fence:isHoppable() or fence:isTallHoppable() then
        pcall(function()
            if isServer() then square:transmitRemoveItemFromSquare(fence) else square:RemoveTileObject(fence) end
            square:RecalcAllWithNeighbours(true)
        end)
    end
    if fenceStillStands(fence) then
        pcall(function()
            fence:destroyFence(animal:getDir())
            if square then square:RecalcAllWithNeighbours(true) end
        end)
    end
    if fenceStillStands(fence) then
        pcall(function()
            fence:Damage(327670.0)
            fence:Thump(animal, 1)
        end)
    end
    if square then breakNoise(square, sound) end
    return not fenceStillStands(fence)
end

-- ----------------------------------------------------------------- attacks --

-- Its swing, used on players and on fences alike: it stops, turns, and plays
-- the look's attack animation; the blow lands at impactSeconds and the swing
-- ends at durationSeconds. While it swings it neither moves nor turns away.
local function beginSwing(animal, entry, nowMs, swing)
    stopMoving(animal, true)
    entry.pursuit, entry.fenceRoute = nil, nil
    animal:setIgnoreMovement(true)
    animal:getBehavior():setBlockMovement(true)
    faceToward(animal, swing.faceX, swing.faceY)
    setAnimation(animal, Look.attack.variable, true, Look.attack.durationSeconds)
    swing.impactMs = nowMs + Look.attack.impactSeconds * 1000
    swing.endsMs = nowMs + Look.attack.durationSeconds * 1000
    swing.impacted = false
    entry.swing = swing
end

local function endSwing(animal, entry, nowMs)
    local swing = entry.swing
    entry.swing = nil
    animal:clearVariable(Look.attack.variable)
    animal:setIgnoreMovement(false)
    animal:getBehavior():setBlockMovement(false)
    if swing and swing.kind == "player" then
        entry.attackReadyMs = nowMs + Tuning.attackRecoverySeconds * 1000
    end
    -- Smashed a fence on a walk: on with the walk.
    local wander = entry.wander
    if wander and wander.mode == "walking" then
        pathToLocation(animal, wander.targetX, wander.targetY, animal:getZ(), true)
        wander.startedMs = nowMs
        wander.timeoutMs = nowMs + Tuning.wanderTimeoutSeconds * 1000
    end
end

-- The hit is the engine's own animal attack (IsoPlayer.hitConsequences with
-- an animal as the attacker: a wound from the species' damage), applied on
-- the victim's own game. See Creatures.applyCollectiveHit.
local function strike(animal, player, entry, nowMs)
    local knockdown = false
    if isDue(entry.lastKnockdownMs, nowMs, Tuning.knockdownCooldownSeconds)
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

-- Did the blow land on them? Still within reach, still in front of it, and
-- nothing solid in the way.
local function blowLands(animal, swing, player)
    if player:isDead() or math.floor(player:getZ()) ~= math.floor(animal:getZ()) then return false end
    local dx, dy = player:getX() - animal:getX(), player:getY() - animal:getY()
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance > reachOf(animal) + Tuning.reachSlack then return false end
    if distance > 0.05 and (dx * swing.forwardX + dy * swing.forwardY) / distance < 0.25 then return false end
    return attackPathClear(animal, player:getX(), player:getY())
end

-- Every tick while it swings: keep facing, land the blow, finish.
local function processSwing(animal, entry, nowMs)
    local swing = entry.swing
    faceToward(animal, swing.faceX, swing.faceY)
    if not swing.impacted and nowMs >= swing.impactMs then
        swing.impacted = true
        if swing.kind == "player" then
            if blowLands(animal, swing, swing.target) then strike(animal, swing.target, entry, nowMs) end
        else
            destroyFence(animal, swing.fence)
        end
    end
    if nowMs >= swing.endsMs then endSwing(animal, entry, nowMs) end
end

local function beginPlayerAttack(animal, entry, player, nowMs)
    local dx, dy = player:getX() - animal:getX(), player:getY() - animal:getY()
    local length = math.max(0.001, math.sqrt(dx * dx + dy * dy))
    beginSwing(animal, entry, nowMs, {
        kind = "player", target = player,
        faceX = player:getX(), faceY = player:getY(),
        forwardX = dx / length, forwardY = dy / length,
    })
end

local function beginFenceAttack(animal, entry, fence, far, nowMs)
    beginSwing(animal, entry, nowMs, {
        kind = "fence", fence = fence,
        faceX = far:getX() + 0.5, faceY = far:getY() + 0.5,
    })
end

-- The middle of the edge between the squares either side of a fence.
local function fenceFace(near, far)
    return (near:getX() + far:getX()) / 2 + 0.5, (near:getY() + far:getY()) / 2 + 0.5
end

local function withinFenceReach(animal, near, far)
    local fx, fy = fenceFace(near, far)
    local dx, dy = animal:getX() - fx, animal:getY() - fy
    return dx * dx + dy * dy <= reachOf(animal) * reachOf(animal)
end

-- ----------------------------------------------------------------- pursuit --

-- After the T-rex: a path to its prey, asked for again only when they have
-- moved retargetDistance since, or it has been getting nowhere for
-- stuckSeconds - never more often than every repathSeconds.
local function issuePursuit(animal, entry, player, nowMs, resetAction)
    pathToCharacter(animal, player, resetAction)
    entry.wander = nil
    entry.pursuit = {
        kind = "chase", target = player,
        targetX = player:getX(), targetY = player:getY(),
        nextRepathMs = nowMs + Tuning.repathSeconds * 1000,
        startedMs = nowMs, startedMoving = false,
        lastX = animal:getX(), lastY = animal:getY(), lastProgressMs = nowMs,
    }
end

local function servicePursuit(animal, entry, player, nowMs)
    local info = entry.pursuit
    if info == nil or info.kind ~= "chase" or info.target ~= player then
        issuePursuit(animal, entry, player, nowMs, true)
        return
    end
    local ax, ay = animal:getX(), animal:getY()
    local mx, my = ax - info.lastX, ay - info.lastY
    if mx * mx + my * my >= 0.0625 then
        info.lastX, info.lastY, info.lastProgressMs = ax, ay, nowMs
        info.startedMoving = true
    end
    if nowMs < info.nextRepathMs then return end
    info.nextRepathMs = nowMs + Tuning.repathSeconds * 1000

    if nowMs - info.lastProgressMs >= Tuning.stuckSeconds * 1000 then
        issuePursuit(animal, entry, player, nowMs, true)
        return
    end
    local tx, ty = player:getX() - info.targetX, player:getY() - info.targetY
    if tx * tx + ty * ty < Tuning.retargetDistance * Tuning.retargetDistance then return end
    if not info.startedMoving and nowMs - info.startedMs < Tuning.pathStartGraceSeconds * 1000 then return end
    issuePursuit(animal, entry, player, nowMs, false)
end

-- ------------------------------------------------------------------ memory --

-- What it remembers of its prey: where they were when it last knew, for
-- memorySeconds. Out of range it goes there, then searches round the spot.
local function rememberPlayer(entry, player, nowMs)
    entry.memory = {
        target = player,
        originX = player:getX(), originY = player:getY(),
        x = player:getX(), y = player:getY(), z = math.floor(player:getZ()),
        expiresMs = nowMs + Tuning.memorySeconds * 1000,
    }
end

local function memoryValid(entry, animal, nowMs)
    local memory = entry.memory
    return memory ~= nil and memory.z == math.floor(animal:getZ()) and nowMs < memory.expiresMs
end

-- The next spot of its search: somewhere open outdoors round where it last
-- knew them.
local function advanceSearch(memory, animal)
    local cell = getCell()
    for _ = 1, 12 do
        local angle = ZombRandFloat(0, math.pi * 2)
        local distance = randomBetween(2.0, Tuning.searchRadius)
        local x = math.floor(memory.originX + math.cos(angle) * distance)
        local y = math.floor(memory.originY + math.sin(angle) * distance)
        if isOpenOutdoorSquare(cell:getGridSquare(x, y, memory.z)) then
            memory.x, memory.y = x, y
            return true
        end
    end
    return false
end

local function issueMemoryPursuit(animal, entry, nowMs, resetAction)
    local memory = entry.memory
    pathToLocation(animal, memory.x, memory.y, memory.z, resetAction)
    entry.wander = nil
    entry.pursuit = { kind = "memory", nextRepathMs = nowMs + Tuning.memoryRepathSeconds * 1000 }
end

-- True while it is still going after what it remembers.
local function serviceLastKnown(animal, entry, nowMs)
    if not memoryValid(entry, animal, nowMs) then
        entry.memory = nil
        if entry.pursuit and entry.pursuit.kind == "memory" then entry.pursuit = nil end
        return false
    end
    local memory = entry.memory
    local dx, dy = animal:getX() - memory.x, animal:getY() - memory.y
    if dx * dx + dy * dy <= Tuning.arriveDistance * Tuning.arriveDistance then
        if advanceSearch(memory, animal) then
            issueMemoryPursuit(animal, entry, nowMs, true)
            return true
        end
        entry.memory, entry.pursuit = nil, nil
        stopMoving(animal, true)
        return false
    end
    local info = entry.pursuit
    if info == nil or info.kind ~= "memory" then
        issueMemoryPursuit(animal, entry, nowMs, true)
    elseif nowMs >= info.nextRepathMs then
        issueMemoryPursuit(animal, entry, nowMs, false)
    end
    return true
end

-- ------------------------------------------------------------------ roaming --

-- With nothing to hunt it roams, as the T-rex does: an idle stand, then a
-- walk to a random open spot outdoors, then another stand. A fence on its
-- way gets smashed.
local function beginIdle(animal, entry, nowMs)
    stopMoving(animal, true)
    animal:setIgnoreMovement(false)
    animal:getBehavior():setBlockMovement(false)
    animal:getBehavior():resetBehaviorAction()
    animal:clearVariable("idleAction")
    entry.wander = {
        mode = "idle",
        untilMs = nowMs + randomBetween(Tuning.wanderIdleMinSeconds, Tuning.wanderIdleMaxSeconds) * 1000,
    }
end

local function beginWander(animal, entry, nowMs, continuous)
    local cell = getCell()
    local z = math.floor(animal:getZ())
    for _ = 1, 10 do
        local angle = ZombRandFloat(0, math.pi * 2)
        local radius = randomBetween(Tuning.wanderRadiusMin, Tuning.wanderRadiusMax)
        local x = math.floor(animal:getX() + math.cos(angle) * radius)
        local y = math.floor(animal:getY() + math.sin(angle) * radius)
        if isOpenOutdoorSquare(cell:getGridSquare(x, y, z)) then
            pathToLocation(animal, x, y, z, true)
            entry.pursuit = nil
            entry.wander = {
                mode = "walking", continuous = continuous == true,
                targetX = x, targetY = y,
                startedMs = nowMs, timeoutMs = nowMs + Tuning.wanderTimeoutSeconds * 1000,
            }
            return
        end
    end
    if continuous then
        entry.wander = { mode = "retry", continuous = true, untilMs = nowMs + 500 }
    else
        beginIdle(animal, entry, nowMs)
    end
end

-- Would its next step on the path take it indoors?
local function nextStepIndoors(animal)
    local current = animal:getCurrentSquare()
    if not isOutside(current) then return true end
    local future = animal:getFuturWalkedSquare()
    if future and future ~= current and not isOutside(future) then return true end
    local path = animal:getPathFindBehavior2()
    local ok, isSet, nextX, nextY = pcall(function() return path.pathNextIsSet, path.pathNextX, path.pathNextY end)
    if ok and isSet and nextX and nextY then
        local square = getCell():getGridSquare(math.floor(nextX), math.floor(nextY), current:getZ())
        if square and not isOutside(square) then return true end
    end
    return false
end

-- `continuous`: walk after walk without standing about - its prowl round a
-- building its prey is hiding in.
local function serviceWander(animal, entry, nowMs, continuous)
    local info = entry.wander
    if info == nil then
        if continuous then beginWander(animal, entry, nowMs, true) else beginIdle(animal, entry, nowMs) end
        return
    end
    if info.mode == "idle" or info.mode == "retry" then
        if nowMs >= info.untilMs or (continuous and info.mode == "idle") then
            beginWander(animal, entry, nowMs, continuous or info.continuous)
        end
        return
    end

    local keepMoving = continuous or info.continuous
    local function moveOn()
        if keepMoving then beginWander(animal, entry, nowMs, true) else beginIdle(animal, entry, nowMs) end
    end
    if not Look.canRun then animal:clearVariable("animalRunning") end

    if nextStepIndoors(animal) then
        cancelPath(animal)
        moveOn()
        return
    end
    local fence, near, far = fenceOnPathAhead(animal, info.targetX, info.targetY)
    if fence then
        beginFenceAttack(animal, entry, fence, far, nowMs)
        return
    end
    local dx, dy = animal:getX() - info.targetX, animal:getY() - info.targetY
    if dx * dx + dy * dy <= Tuning.arriveDistance * Tuning.arriveDistance or nowMs >= info.timeoutMs then
        moveOn()
        return
    end
    if nowMs >= info.startedMs + Tuning.pathStartGraceSeconds * 1000 and not isPathMoving(animal) then
        moveOn()
    end
end

-- -------------------------------------------------------------- outdoors --

-- It stays outdoors. Having strayed in, it heads back out the way it came.
local function keepOutdoors(animal, entry)
    local current = animal:getCurrentSquare()
    if isOutside(current) then
        entry.lastOutside = { x = animal:getX(), y = animal:getY(), z = animal:getZ() }
        return false
    end
    entry.pursuit, entry.wander, entry.fenceRoute = nil, nil, nil
    if isPathMoving(animal) and not isDue(entry.outdoorPathMs, getTimestampMs(), 1.0) then return true end
    entry.outdoorPathMs = getTimestampMs()
    local target = entry.lastOutside
    if target == nil then
        local cell = getCell()
        for radius = 1, 8 do
            for dx = -radius, radius do
                for dy = -radius, radius do
                    if target == nil and (math.abs(dx) == radius or math.abs(dy) == radius) then
                        local square = cell:getGridSquare(current:getX() + dx, current:getY() + dy, current:getZ())
                        if isOpenOutdoorSquare(square) then target = { x = square:getX(), y = square:getY(), z = square:getZ() } end
                    end
                end
            end
        end
    end
    if target then pathToLocation(animal, target.x, target.y, target.z, true) else stopMoving(animal, true) end
    return true
end

-- ---------------------------------------------------------------- targets --

local function isHuntable(player, animal)
    return not player:isDead() and math.floor(player:getZ()) == math.floor(animal:getZ())
        and player:getVehicle() == nil and not player:isGhostMode() and not player:isInvisible()
end

-- How far it notices this player from: detectRange, half that for one
-- sneaking. Sneaking indoors out of its reach, they are hidden from it.
local function noticeRange(animal, player)
    local range = Tuning.detectRange
    if player:isSneaking() then
        if player:isInARoom() and isOutside(animal:getCurrentSquare())
            and not attackPathClear(animal, player:getX(), player:getY()) then
            return 0
        end
        range = range * 0.5
    end
    return range
end

local function distanceTo(animal, player)
    local dx, dy = player:getX() - animal:getX(), player:getY() - animal:getY()
    return math.sqrt(dx * dx + dy * dy)
end

-- The player it hunts: the nearest it notices, though it keeps after its
-- current prey while they stay within keepRange of what it noticed them from
-- and nobody else is much nearer.
local function chooseTarget(animal, entry, players)
    local best, bestDistance = nil, math.huge
    for i = 1, #players do
        local player = players[i]
        if isHuntable(player, animal) then
            local distance = distanceTo(animal, player)
            if distance < noticeRange(animal, player) and distance < bestDistance then
                best, bestDistance = player, distance
            end
        end
    end
    local current = entry.target
    if current and current ~= best and isHuntable(current, animal) then
        local distance = distanceTo(animal, current)
        if distance <= noticeRange(animal, current) * Tuning.keepRange and distance <= bestDistance * 1.35 then
            return current, distance
        end
    end
    return best, bestDistance
end

-- --------------------------------------------------------------- hunting --

-- Heading for a fence between it and its prey: re-asked every repathSeconds,
-- and smashed once within reach.
local function serviceFenceRoute(animal, entry, player, nowMs)
    local route = entry.fenceRoute
    if route == nil then return false end
    if route.target ~= player or not fenceStillStands(route.fence) then
        entry.fenceRoute = nil
        return false
    end
    if withinFenceReach(animal, route.near, route.far) then
        beginFenceAttack(animal, entry, route.fence, route.far, nowMs)
        return true
    end
    if nowMs >= route.nextRepathMs then
        route.nextRepathMs = nowMs + Tuning.repathSeconds * 1000
        pathToLocation(animal, route.near:getX(), route.near:getY(), route.near:getZ(), true)
    end
    return true
end

local function huntPlayer(animal, entry, player, distance, nowMs)
    rememberPlayer(entry, player, nowMs)

    -- Indoors, out of its reach: it prowls round outside.
    if not isOutside(player:getCurrentSquare()) then
        entry.pursuit, entry.fenceRoute = nil, nil
        if entry.indoorPlayer ~= player then
            entry.indoorPlayer = player
            beginIdle(animal, entry, nowMs)
        end
        serviceWander(animal, entry, nowMs, true)
        return
    end
    entry.indoorPlayer = nil
    if entry.wander then entry.wander = nil end

    if serviceFenceRoute(animal, entry, player, nowMs) then return end

    -- A fence on the straight line to its prey: straight at it, and through.
    local fence, near, far = fenceOnLineTo(animal, player:getX(), player:getY(), Tuning.fenceProbeSteps)
    if fence == nil and isDue(entry.longFenceProbeMs, nowMs, Tuning.fenceLongProbeSeconds) then
        entry.longFenceProbeMs = nowMs
        fence, near, far = fenceOnLineTo(animal, player:getX(), player:getY(), 256)
    end
    if fence then
        if withinFenceReach(animal, near, far) then
            beginFenceAttack(animal, entry, fence, far, nowMs)
        else
            entry.pursuit = nil
            entry.fenceRoute = {
                target = player, fence = fence, near = near, far = far,
                nextRepathMs = nowMs + Tuning.repathSeconds * 1000,
            }
            pathToLocation(animal, near:getX(), near:getY(), near:getZ(), true)
        end
        return
    end

    if distance <= reachOf(animal) * Tuning.attackStartFraction
        and nowMs >= (entry.attackReadyMs or 0)
        and not player:isOnFloor()
        and attackPathClear(animal, player:getX(), player:getY()) then
        beginPlayerAttack(animal, entry, player, nowMs)
        return
    end
    -- Looming over a downed player instead of beating them on the floor:
    -- getting up is the chance to run.
    if player:isOnFloor() and distance <= reachOf(animal) then
        stopMoving(animal, false)
        entry.pursuit = nil
        faceToward(animal, player:getX(), player:getY())
        return
    end
    servicePursuit(animal, entry, player, nowMs)
end

-- One collective, every brain step.
local function think(animal, entry, players, nowMs)
    if keepOutdoors(animal, entry) then return end

    local target, distance = chooseTarget(animal, entry, players)
    entry.target = target
    if target then
        huntPlayer(animal, entry, target, distance, nowMs)
        return
    end
    entry.indoorPlayer, entry.fenceRoute = nil, nil
    if serviceLastKnown(animal, entry, nowMs) then
        entry.wander = nil
        return
    end
    if entry.pursuit then
        stopMoving(animal, false)
        entry.pursuit = nil
    end
    serviceWander(animal, entry, nowMs, false)
end

-- Being hit starts the engine's own reaction; whatever it was doing, bar a
-- swing already under way, is dropped until that is over.
local function releaseForReaction(animal, entry)
    if entry.pursuit or entry.wander or entry.fenceRoute then cancelPath(animal) end
    entry.pursuit, entry.wander, entry.fenceRoute = nil, nil, nil
    animal:clearVariable("animalRunning")
    animal:setIgnoreMovement(false)
    animal:getBehavior():setBlockMovement(false)
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
    playAction(animal, "absorb", nowMs)
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
    -- Whoever hits it, it knows where they are - a shot from beyond its
    -- notice included - and goes for them.
    if key and wielder and instanceof(wielder, "IsoPlayer") and not instanceof(wielder, "IsoAnimal") then
        rememberPlayer(stateFor(key), wielder, getTimestampMs())
    end
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

-- ------------------------------------------------------------- controller --

-- After the T-rex's controller: the brain decides every brainSeconds; a
-- swing under way is timed every tick; the bookkeeping runs every second.
local loaded = {} -- record key -> animal, refreshed every brain step

local function refreshLoaded()
    loaded = {}
    local cell = getCell()
    local animals = cell and cell:getAnimals()
    if animals == nil then return end
    for i = 0, animals:size() - 1 do
        local animal = animals:get(i)
        if Creatures.isCollective(animal) and not animal:isDead() and animal:getCurrentSquare() ~= nil then
            loaded[track(animal)] = animal
        end
    end
end

local function service(animal, entry, players, nowMs, runBrain)
    -- The model has no run, so neither may the placeholder: whatever
    -- vanilla starts it running for, it walks.
    if not Look.canRun then animal:clearVariable("animalRunning") end

    if entry.swing then
        processSwing(animal, entry, nowMs)
    elseif inNativeReaction(animal) then
        releaseForReaction(animal, entry)
    elseif runBrain then
        animal:setVariable(Look.marker, true)
        think(animal, entry, players, nowMs)
    end
end

-- Every second: growing, swallowing, and the ones yet to appear.
local function sweep(nowMs)
    local zombies = getCell():getZombieList()
    for key, animal in pairs(loaded) do
        if not animal:isDead() then
            -- Zombies close by drive an animal's stress up; nothing frightens it.
            animal:setDebugStress(0)
            Creatures.applyCollectiveSize(animal)
            if zombies then absorb(animal, stateFor(key), zombies, nowMs) end
        end
    end
    materialize(livingPlayers())
end

local lastBrainMs = 0
local lastSweepMs = 0

local function tick(nowMs)
    endPulses(nowMs)
    local runBrain = isDue(lastBrainMs, nowMs, Tuning.brainSeconds)
    if runBrain then
        lastBrainMs = nowMs
        refreshLoaded()
    end
    local players = runBrain and livingPlayers() or nil
    for key, animal in pairs(loaded) do
        if not animal:isDead() and animal:getCurrentSquare() ~= nil then
            service(animal, stateFor(key), players, nowMs, runBrain)
        end
    end
end

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
    local okTick, tickErr = pcall(tick, nowMs)
    if not okTick then log("collective brain failed: %s", tostring(tickErr)) end

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
