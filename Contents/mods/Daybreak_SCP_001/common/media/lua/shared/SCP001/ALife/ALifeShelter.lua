-- Where Project A-Life's NPCs spend the day: on a square in a building that
-- the sun can't reach even at noon, by the same light test that burns the
-- player. Two A-Life behaviour modules do it:
--   daybreakShelter (decision, priority 5, ahead of orders and stances)
--     walks every NPC to such a square from a little before dawn and keeps
--     it there, resting, until the sun is down - then lets A-Life carry on.
--   daybreakSunFlight (response, priority 1) gets an NPC caught in the light
--     out of it before A-Life decides to fight.
-- On arriving, NPCs black out the building the way A-Life's own people board
-- up for the night - sheets over the windows, doors shut - which leaves most
-- of a house dark. The rest of the A-Life side lives in ALifeCompat.lua.
require "SCP001/Sunlight"
require "SCP001/ALife/ALifeCompat"
require "SCP001/ALife/ALifeSunDamage"

local Sunlight = SCP001.Sunlight
local Compat = SCP001.ALife

local Shelter = {
    -- Building id -> its darkness map, see mapFor.
    maps = {},
    -- Building id -> real-time ms until which it's changing (sheets going
    -- up), so no map is made of it yet.
    settlingUntilMs = {},
    -- "x,y,z" -> uid of the NPC sheltering there, and uid -> that key.
    claims = {},
    claimOf = {},
    -- "x,y,z" or building id -> day it was given up on.
    blacklist = {},
    -- uid -> how the walk to its square is going (not persisted).
    progress = {},
    -- groupId -> { x, y, z, day } of the building the group shelters in.
    groupBuildings = {},
    -- Building id -> { day, lit } of its last blackout.
    blackedOut = {},
    mapsThisTick = 0,
}
Compat.Shelter = Shelter

-- How far to look for a building with dark squares, and beyond that how far
-- to look for any building at all to make for.
local SEARCH_RADIUS = 40
local FAR_SEARCH_RADIUS = 100
local SEARCH_STEP = 3
local FAR_SEARCH_STEP = 6
local MAX_CANDIDATE_BUILDINGS = 6
-- Light from further out than this can't reach a building's squares at all.
local MAP_MARGIN = Sunlight.maxDangerousDistance(Sunlight.PEAK_LIGHT_LEVEL)
-- A map costs a scan of every square round the building, so only this many
-- are made per tick, levels past this many squares are left out (the first
-- is always mapped), and a map is kept for an in-game hour.
local MAPS_PER_TICK = 1
local MAP_SQUARE_BUDGET = 40000
local MAP_LIFETIME_HOURS = 1
-- After a blackout the map is made again this much later (real ms), once
-- the sheets are up - in multiplayer the server hangs them.
local MAP_SETTLE_MS = 3000
-- Giving up on a square: no tile of progress in this long (real ms), or
-- A-Life refusing to start the walk this many times.
local STUCK_MS = 60000
local MAX_REFUSED_STARTS = 3
-- A building is given up on for the day after this many squares in it.
local MAX_FAILED_SQUARES_PER_BUILDING = 2
local ARRIVED_TILES = 0.9
local REST_COOLDOWN_MS = 2000
-- Modules that still run while an NPC rests in its shelter.
local REST_MODULES = { "healing", "medic" }

-- Sixteen even directions for the ring scans.
local RAYS = {}
for index = 0, 15 do
    local angle = index * math.pi / 8
    RAYS[#RAYS + 1] = { math.cos(angle), math.sin(angle) }
end

local function memoryOf(actor)
    return type(actor.memory) == "table" and actor.memory or {}
end

local function positionOf(shell)
    return { x = shell:getX(), y = shell:getY(), z = math.floor(shell:getZ()) }
end

local function squareKey(x, y, z)
    return math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z)
end

local function buildingKey(building)
    return tostring(building:getID())
end

local function squareOf(spot)
    return getCell():getGridSquare(math.floor(spot.x), math.floor(spot.y), math.floor(spot.z or 0))
end

local function players()
    local locator = ProjectALife.PlayerLocator
    if locator ~= nil and type(locator.list) == "function" then
        local ok, list = pcall(locator.list)
        if ok and type(list) == "table" then return list end
    end
    local list = {}
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player then list[#list + 1] = player end
    end
    return list
end

local function playerInside(building)
    for _, player in ipairs(players()) do
        local square = player:getCurrentSquare()
        if square ~= nil and square:getBuilding() == building then return true end
    end
    return false
end

local function isSafehouse(square)
    return SafeHouse ~= nil and SafeHouse.isSafeHouse(square, nil, true) ~= nil
end

local function blacklisted(key)
    return Shelter.blacklist[key] == Compat.dayIndex()
end

-- Darkness maps ---------------------------------------------------------------------

-- Whether the ground round building is loaded far enough out for its map to
-- be trusted: missing squares would read as darkness.
local function surroundingsLoaded(building)
    local def = building:getDef()
    local cell = getCell()
    local x1, y1 = def:getX() - MAP_MARGIN, def:getY() - MAP_MARGIN
    local x2, y2 = def:getX2() - 1 + MAP_MARGIN, def:getY2() - 1 + MAP_MARGIN
    return cell:getGridSquare(x1, y1, 0) ~= nil and cell:getGridSquare(x2, y1, 0) ~= nil
        and cell:getGridSquare(x1, y2, 0) ~= nil and cell:getGridSquare(x2, y2, 0) ~= nil
end

-- Every square of building the sun can't reach even at its peak. It's
-- Sunlight.findExposureLightLevel turned round: one search inward from every
-- open-air square near the building, stepping onto a neighbour only where a
-- search from that neighbour would have stepped the other way. So a square
-- ends up lit exactly when the player's own search from it would find open
-- air within reach. Only squares an NPC can stand on are kept.
local function darkSquaresOf(building)
    local def = building:getDef()
    local x1, y1, x2, y2 = def:getX(), def:getY(), def:getX2() - 1, def:getY2() - 1
    local originX, originY = x1 - MAP_MARGIN, y1 - MAP_MARGIN
    local width = (x2 + MAP_MARGIN) - originX + 1
    local height = (y2 + MAP_MARGIN) - originY + 1
    local maxDist = Sunlight.maxDangerousDistance(Sunlight.PEAK_LIGHT_LEVEL)
    local directions = Sunlight.cardinalDirections
    local cell = getCell()
    local centreX, centreY = (x1 + x2) / 2, (y1 + y2) / 2
    local dark, scanned = {}, 0

    for z = def:getMinLevel(), def:getMaxLevel() do
        if scanned > 0 and scanned + width * height > MAP_SQUARE_BUDGET then break end
        scanned = scanned + width * height

        local squares, dist = {}, {}
        local queue, head, tail = {}, 1, 0
        for y = 0, height - 1 do
            for x = 0, width - 1 do
                local square = cell:getGridSquare(originX + x, originY + y, z)
                if square then
                    local index = x + y * width
                    squares[index] = square
                    if square:getOpenAir() then
                        dist[index] = 0
                        tail = tail + 1
                        queue[tail] = index
                    end
                end
            end
        end

        while head <= tail do
            local index = queue[head]
            head = head + 1
            local d = dist[index]
            if d < maxDist then
                local x, y = index % width, math.floor(index / width)
                for i = 1, #directions do
                    local direction = directions[i]
                    local nx, ny = x + direction.dx, y + direction.dy
                    if nx >= 0 and nx < width and ny >= 0 and ny < height then
                        local neighbourIndex = nx + ny * width
                        local neighbour = squares[neighbourIndex]
                        if neighbour and dist[neighbourIndex] == nil
                                and neighbour:testVisionAdjacent(-direction.dx, -direction.dy, 0, true, false)
                                    ~= Sunlight.blockedResult(neighbour) then
                            dist[neighbourIndex] = d + 1
                            tail = tail + 1
                            queue[tail] = neighbourIndex
                        end
                    end
                end
            end
        end

        for y = y1, y2 do
            for x = x1, x2 do
                local index = (x - originX) + (y - originY) * width
                local square = squares[index]
                if square and dist[index] == nil and square:getBuilding() == building
                        and not square:isOutside() and square:isFree(false) and square:TreatAsSolidFloor() then
                    dark[#dark + 1] = { x = x, y = y, z = z, core = (x - centreX) ^ 2 + (y - centreY) ^ 2 }
                end
            end
        end
    end

    -- Nearest the middle of the building first, in a fixed order, so a squad
    -- coming back on screen is given the same squares each time it's asked.
    table.sort(dark, function(a, b)
        if a.core ~= b.core then return a.core < b.core end
        if a.z ~= b.z then return a.z < b.z end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return dark
end

-- The darkness map of building: { dark = squares, ground = those at z 0,
-- darkKeys = set of their keys, madeAtHours }. Returns nil while the building
-- is settling after a blackout, or while a map that's due waits its turn
-- (at most MAPS_PER_TICK are made a tick).
function Shelter.mapFor(building)
    local key = buildingKey(building)
    local settling = Shelter.settlingUntilMs[key]
    if settling ~= nil then
        if getTimestampMs() < settling then return nil end
        Shelter.settlingUntilMs[key] = nil
        Shelter.maps[key] = nil
    end
    local map = Shelter.maps[key]
    local hours = getGameTime():getWorldAgeHours()
    if map ~= nil and hours - map.madeAtHours < MAP_LIFETIME_HOURS then return map end
    if Shelter.mapsThisTick >= MAPS_PER_TICK then return map end
    Shelter.mapsThisTick = Shelter.mapsThisTick + 1

    local dark = darkSquaresOf(building)
    local ground, darkKeys = {}, {}
    for _, spot in ipairs(dark) do
        darkKeys[squareKey(spot.x, spot.y, spot.z)] = true
        if spot.z == 0 then ground[#ground + 1] = spot end
    end
    map = { dark = dark, ground = ground, darkKeys = darkKeys, madeAtHours = hours }
    Shelter.maps[key] = map
    return map
end

-- The building is changing: map it again once delayMs have passed.
function Shelter.invalidate(building, delayMs)
    Shelter.settlingUntilMs[buildingKey(building)] = getTimestampMs() + (delayMs or 0)
end

-- Blackout ---------------------------------------------------------------------------

local function shutDoors(building, shell)
    local builder, traversal = ProjectALife.OutpostBuilder, ProjectALife.ObstacleTraversal
    if builder == nil or traversal == nil or type(builder.probeBuilding) ~= "function"
            or type(traversal.shutDoor) ~= "function" then
        return
    end
    local probe = builder.probeBuilding(building)
    if probe == nil or type(probe.doors) ~= "function" then return end
    for _, opening in ipairs(probe.doors()) do
        pcall(function()
            local door = opening.object
            if door:IsOpen() ~= true then return end
            if type(traversal.doorwayClear) == "function" and not traversal.doorwayClear(door, shell) then return end
            traversal.shutDoor(door, door:getSquare())
        end)
    end
end

-- Hangs sheets over building's windows (A-Life's own, server-side in
-- multiplayer) and shuts its outside doors (A-Life's synced door toggle).
-- Done once a day, again once the sun is up, and again whenever forced
-- because someone sheltering there got burned. Never while a player is
-- inside, as A-Life itself won't. Returns whether it did anything.
function Shelter.blackout(shell, building, force)
    if not Compat.settings.blackout then return false end
    local key = buildingKey(building)
    local today = Compat.dayIndex()
    local lit = Compat.sunThreat()
    local last = Shelter.blackedOut[key]
    if not force and last ~= nil and last.day == today and (last.lit or not lit) then return false end
    if playerInside(building) then return false end
    Shelter.blackedOut[key] = { day = today, lit = lit }

    local life = ProjectALife.ModuleIdleLife
    if life ~= nil and type(life.dressWindows) == "function" then
        pcall(life.dressWindows, building, shell, { x = shell:getX(), y = shell:getY() })
    end
    pcall(shutDoors, building, shell)
    Shelter.invalidate(building, MAP_SETTLE_MS)
    return true
end

-- Choosing a square -----------------------------------------------------------------

function Shelter.claim(uid, spot)
    Shelter.unclaim(uid)
    local key = squareKey(spot.x, spot.y, spot.z)
    Shelter.claims[key] = uid
    Shelter.claimOf[uid] = key
end

function Shelter.unclaim(uid)
    local key = Shelter.claimOf[uid]
    if key ~= nil and Shelter.claims[key] == uid then Shelter.claims[key] = nil end
    Shelter.claimOf[uid] = nil
end

local function pickSquare(map, uid, here)
    local best, bestScore
    for _, spot in ipairs(map.dark) do
        local key = squareKey(spot.x, spot.y, spot.z)
        local claimant = Shelter.claims[key]
        if (claimant == nil or claimant == uid) and not blacklisted(key) then
            local dx, dy, dz = spot.x + 0.5 - here.x, spot.y + 0.5 - here.y, (spot.z - here.z) * 8
            local score = dx * dx + dy * dy + dz * dz
            if best == nil or score < bestScore then best, bestScore = spot, score end
        end
    end
    return best
end

-- Buildings round (x, y), nearest ring first, up to limit of them.
local function buildingsAround(x, y, radius, step, limit, found, seen)
    local cell = getCell()
    for ring = 1, math.floor(radius / step) do
        local distance = ring * step
        for _, ray in ipairs(RAYS) do
            local square = cell:getGridSquare(math.floor(x + ray[1] * distance), math.floor(y + ray[2] * distance), 0)
            local building = square and square:getBuilding()
            if building ~= nil then
                local key = buildingKey(building)
                if not seen[key] then
                    seen[key] = true
                    found[#found + 1] = { building = building, square = square }
                    if #found >= limit then return found end
                end
            end
        end
    end
    return found
end

-- The group's building first, so squads keep together, then the one the NPC
-- is standing in, then the nearest others. Each comes with one of its squares.
local function candidateBuildings(actor, shell, here)
    local found, seen = {}, {}
    local function add(square)
        local building = square and square:getBuilding()
        if building == nil then return end
        local key = buildingKey(building)
        if seen[key] then return end
        seen[key] = true
        found[#found + 1] = { building = building, square = square }
    end
    local groupId = memoryOf(actor).groupId
    local group = groupId ~= nil and Shelter.groupBuildings[groupId] or nil
    if group ~= nil and group.day == Compat.dayIndex()
            and math.abs(group.x - here.x) <= SEARCH_RADIUS and math.abs(group.y - here.y) <= SEARCH_RADIUS then
        add(getCell():getGridSquare(group.x, group.y, group.z))
    end
    add(shell:getCurrentSquare())
    return buildingsAround(here.x, here.y, SEARCH_RADIUS, SEARCH_STEP, MAX_CANDIDATE_BUILDINGS, found, seen)
end

-- The square this NPC should shelter on, or nil plus "pending" while a map
-- is still waiting its turn. A building with a player inside is only used
-- when there's nothing else.
function Shelter.findSpot(actor, shell)
    local here = positionOf(shell)
    local currentSquare = shell:getCurrentSquare()
    local current = currentSquare and currentSquare:getBuilding() or nil
    local occupied = {}
    for pass = 1, 2 do
        local candidates = pass == 1 and candidateBuildings(actor, shell, here) or occupied
        for _, candidate in ipairs(candidates) do
            local building = candidate.building
            local key = buildingKey(building)
            if not blacklisted(key) and not isSafehouse(candidate.square) then
                if pass == 1 and building ~= current and playerInside(building) then
                    occupied[#occupied + 1] = candidate
                elseif surroundingsLoaded(building) then
                    local map = Shelter.mapFor(building)
                    if map == nil then return nil, "pending" end
                    local spot = pickSquare(map, actor.uid, here)
                    if spot ~= nil then
                        return { x = spot.x + 0.5, y = spot.y + 0.5, z = spot.z, building = key, day = Compat.dayIndex() }
                    end
                    -- Nothing dark in the building we're standing in: black it out
                    -- and look again once the sheets are up.
                    if building == current and Shelter.blackout(shell, building) then return nil, "pending" end
                end
            end
        end
    end
    return nil
end

-- With nothing dark nearby, the nearest building further out at least gets
-- the NPC moving towards cover.
function Shelter.farBuilding(shell)
    local here = positionOf(shell)
    local found = buildingsAround(here.x, here.y, FAR_SEARCH_RADIUS, FAR_SEARCH_STEP, 4, {}, {})
    for _, candidate in ipairs(found) do
        local key = buildingKey(candidate.building)
        if not blacklisted(key) and not isSafehouse(candidate.square) then
            return { x = candidate.square:getX() + 0.5, y = candidate.square:getY() + 0.5, z = 0, building = key }
        end
    end
    return nil
end

-- The square actor is sheltering on today, or nil.
function Shelter.spotOf(actor)
    local spot = type(actor) == "table" and memoryOf(actor).daybreakSpot or nil
    if type(spot) ~= "table" or spot.day ~= Compat.dayIndex() then return nil end
    return spot
end

-- Whether the latest map of spot's building still has it dark. Without a
-- map to go by, it's taken to be.
local function stillDark(spot)
    if blacklisted(squareKey(spot.x, spot.y, spot.z)) then return false end
    local map = Shelter.maps[spot.building]
    return map == nil or map.darkKeys[squareKey(spot.x, spot.y, spot.z)] == true
end

-- Giving up on a square for the day; after a few, on its whole building.
local function giveUp(actor, spot)
    local today = Compat.dayIndex()
    Shelter.blacklist[squareKey(spot.x, spot.y, spot.z)] = today
    local progress = Shelter.progress[actor.uid]
    local failures = (progress and progress.failures or {})
    failures[spot.building] = (failures[spot.building] or 0) + 1
    if failures[spot.building] >= MAX_FAILED_SQUARES_PER_BUILDING then Shelter.blacklist[spot.building] = today end
    Shelter.progress[actor.uid] = { failures = failures }
    Shelter.unclaim(actor.uid)
end

-- The behaviour ----------------------------------------------------------------------

local function hold(actor, context, intent, now, ms)
    if type(context.setActivity) == "function" then context.setActivity(actor, "idle", intent) end
    return { kind = "idle", intent = intent, cooldownUntilMs = now + ms }
end

local function arrived(here, spot)
    if here.z ~= math.floor(spot.z) then return false end
    local dx, dy = spot.x - here.x, spot.y - here.y
    return dx * dx + dy * dy <= ARRIVED_TILES * ARRIVED_TILES
end

local function walkTo(actor, shell, context, now, spot, intent, burning)
    local here = positionOf(shell)
    local distance = math.sqrt((spot.x - here.x) ^ 2 + (spot.y - here.y) ^ 2) + math.abs(spot.z - here.z) * 10
    local target = squareKey(spot.x, spot.y, spot.z)
    local progress = Shelter.progress[actor.uid]
    if progress == nil or progress.target ~= target then
        progress = { target = target, best = distance, atMs = now, refused = 0,
            failures = progress and progress.failures or {} }
        Shelter.progress[actor.uid] = progress
    end
    if distance < progress.best - 1 then
        progress.best = distance
        progress.atMs = now
    end
    if now - progress.atMs > STUCK_MS or progress.refused >= MAX_REFUSED_STARTS then
        giveUp(actor, spot)
        context.persistMemory(actor, "daybreakSpot", nil)
        return hold(actor, context, "daybreak_search", now, 300)
    end
    local pace = (burning or Compat.sunThreat()) and "run" or "walk"
    local state = context.startMovement(actor, shell, { x = spot.x, y = spot.y, z = spot.z }, intent,
        { pace = pace, doorsOnly = true, tolerance = 0.6, timeoutMs = 20000, activity = "moving" })
    if state == nil then
        progress.refused = progress.refused + 1
        return hold(actor, context, "daybreak_blocked", now, 1000)
    end
    return state
end

local function rest(actor, shell, context, now)
    local registry = ProjectALife.ModuleRegistry
    for _, id in ipairs(REST_MODULES) do
        local state = registry.evaluate("decision", actor, shell, context, id)
        if state ~= nil then return state end
    end
    local life = ProjectALife.ModuleIdleLife
    if life ~= nil and type(life.postBeat) == "function" then
        local beat = life.postBeat(actor, shell, context)
        if beat ~= nil then return beat end
    end
    return hold(actor, context, "daybreak_rest", now, REST_COOLDOWN_MS)
end

-- Gets actor to its square and keeps it there. When fleeing (the response
-- module), an NPC that's already in the dark is left to A-Life.
function Shelter.goToShelter(actor, shell, context, now, fleeing)
    local burning = Compat.SunDamage ~= nil and Compat.SunDamage.exposedNow(shell)
    local spot = Shelter.spotOf(actor)
    if spot ~= nil and not stillDark(spot) then spot = nil end

    -- Burning on its own square means someone let the light in (a burning
    -- NPC that only just got there is checked against the square itself).
    -- Black the building out again and choose again on its new map.
    if spot ~= nil and burning and arrived(positionOf(shell), spot) then
        local square = squareOf(spot)
        if Sunlight.sunLightAt(square) ~= nil then
            local building = square:getBuilding()
            if building ~= nil then
                Shelter.blackout(shell, building, true)
                Shelter.invalidate(building, MAP_SETTLE_MS)
            end
            Shelter.blacklist[squareKey(spot.x, spot.y, spot.z)] = Compat.dayIndex()
            Shelter.unclaim(actor.uid)
            context.persistMemory(actor, "daybreakSpot", nil)
            spot = nil
        end
    end

    if spot == nil then
        local found, why = Shelter.findSpot(actor, shell)
        if why == "pending" then return hold(actor, context, "daybreak_search", now, 300) end
        if found == nil then
            local far = Shelter.farBuilding(shell)
            if far == nil then return nil end
            return walkTo(actor, shell, context, now, far, "daybreak_seek_cover", burning)
        end
        spot = found
        Shelter.claim(actor.uid, spot)
        context.persistMemory(actor, "daybreakSpot", spot)
    elseif Shelter.claimOf[actor.uid] == nil then
        Shelter.claim(actor.uid, spot)
    end

    if not arrived(positionOf(shell), spot) then
        return walkTo(actor, shell, context, now, spot, "daybreak_shelter", burning)
    end

    -- Arrived: settle in.
    Shelter.progress[actor.uid] = nil
    local square = squareOf(spot)
    local building = square and square:getBuilding()
    if building ~= nil then
        local groupId = memoryOf(actor).groupId
        if groupId ~= nil then
            Shelter.groupBuildings[groupId] = { x = square:getX(), y = square:getY(), z = square:getZ(), day = spot.day }
        end
        Shelter.blackout(shell, building)
    end
    if fleeing then return nil end
    return rest(actor, shell, context, now)
end

-- Clears what an NPC held for the day, once the sun is down.
function Shelter.release(actor, context)
    Shelter.unclaim(actor.uid)
    Shelter.progress[actor.uid] = nil
    if memoryOf(actor).daybreakSpot ~= nil then context.persistMemory(actor, "daybreakSpot", nil) end
end

function Shelter.evaluate(actor, shell, context)
    if not Compat.active() or type(actor) ~= "table" or type(context) ~= "table" then return nil end
    if not Compat.shelterTime() then
        Shelter.release(actor, context)
        return nil
    end
    return Shelter.goToShelter(actor, shell, context, tonumber(context.now) or getTimestampMs(), false)
end

function Shelter.respond(actor, shell, context)
    if not Compat.active() or type(actor) ~= "table" or type(context) ~= "table" then return nil end
    if not Compat.shelterTime() or Compat.SunDamage == nil or not Compat.SunDamage.exposedNow(shell) then return nil end
    return Shelter.goToShelter(actor, shell, context, tonumber(context.now) or getTimestampMs(), true)
end

function Shelter.moduleDefinitions()
    return {
        {
            id = Compat.SHELTER_MODULE_ID,
            kind = "upkeep",
            dispatch = "decision",
            priority = 5,
            label = "Shelter from the sun",
            summary = "By day, waits indoors on a square the sun can't reach, with the building blacked out; at night, carries on as usual.",
            defaultEnabled = true,
            evaluate = function(actor, shell, context) return Shelter.evaluate(actor, shell, context) end,
        },
        {
            id = Compat.SUN_FLIGHT_MODULE_ID,
            kind = "reaction",
            dispatch = "response",
            priority = 1,
            label = "Flee the sun",
            summary = "Caught in sunlight, makes for the dark before fighting anything.",
            defaultEnabled = true,
            evaluate = function(actor, shell, context) return Shelter.respond(actor, shell, context) end,
        },
    }
end

-- Squads coming back on screen by day ----------------------------------------------

local function spotAllowed(x, y, list)
    local render, keepOut = ProjectALife.RenderProtocol, ProjectALife.KeepOut
    if list == nil or render == nil or keepOut == nil or type(render.spotAllowed) ~= "function" then return true end
    local settings = render.settings or {}
    local ok, allowed = pcall(render.spotAllowed, x, y, list, keepOut.ringTiles, settings.coneRange, settings.coneHalfCos)
    return not ok or allowed == true
end

-- Dark ground-floor squares of the building at (x, y) that A-Life could show
-- an off-screen squad on without a player watching them appear, in a stable
-- order, as { x, y } square centres. Nil when there's no such building.
function Shelter.rehydrationSpots(x, y, list)
    local cell = getCell()
    local building
    for _, step in ipairs({ { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do
        local square = cell:getGridSquare(math.floor(x) + step[1], math.floor(y) + step[2], 0)
        building = square and square:getBuilding()
        if building ~= nil then
            if isSafehouse(square) then return nil end
            break
        end
    end
    if building == nil or blacklisted(buildingKey(building)) or not surroundingsLoaded(building) then return nil end
    local map = Shelter.mapFor(building)
    if map == nil then return nil end
    local spots = {}
    for _, spot in ipairs(map.ground) do
        local sx, sy = spot.x + 0.5, spot.y + 0.5
        if spotAllowed(sx, sy, list) then spots[#spots + 1] = { x = sx, y = sy } end
    end
    return spots
end

-- Housekeeping -----------------------------------------------------------------------

function Shelter.prune()
    local today = Compat.dayIndex()
    local hours = getGameTime():getWorldAgeHours()
    for key, map in pairs(Shelter.maps) do
        if hours - map.madeAtHours > 2 then Shelter.maps[key] = nil end
    end
    local now = getTimestampMs()
    for key, untilMs in pairs(Shelter.settlingUntilMs) do
        if now >= untilMs then
            Shelter.settlingUntilMs[key] = nil
            Shelter.maps[key] = nil
        end
    end
    for key, day in pairs(Shelter.blacklist) do
        if day ~= today then Shelter.blacklist[key] = nil end
    end
    for key, done in pairs(Shelter.blackedOut) do
        if done.day ~= today then Shelter.blackedOut[key] = nil end
    end
    for key, group in pairs(Shelter.groupBuildings) do
        if group.day ~= today then Shelter.groupBuildings[key] = nil end
    end
    if not Compat.shelterTime() then
        Shelter.claims, Shelter.claimOf, Shelter.progress = {}, {}, {}
    end
end

Compat.onEvent("OnTick", function() Shelter.mapsThisTick = 0 end)
Compat.onEvent("EveryHours", Shelter.prune)

return Shelter
