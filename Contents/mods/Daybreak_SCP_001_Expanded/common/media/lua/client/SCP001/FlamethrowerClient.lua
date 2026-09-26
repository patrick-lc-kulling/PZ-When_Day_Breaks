-- Fires the flamethrower's burst, and keeps its fuel out of the gun menus.
-- Tunables are in shared/SCP001/Flamethrower.lua; this file is the machinery.
require "SCP001/Flamethrower"
require "SCP001/GridLine"
require "ISUI/ISInventoryPaneContextMenu"

local Flamethrower = DaybreakFlamethrower
local GridLine = DaybreakGridLine

-- ------------------------------------------------------------------- fuel --

-- The tank as of the last player update, per local player. The shot event
-- fires on a dry trigger pull too, and in single player vanilla's own handler
-- has already taken this shot's fuel off by the time ours runs - so the count
-- from just before the shot is the one that says whether it fired. It is also
-- the one that holds on a multiplayer client, where the server does the
-- decrement.
local lastFuel = {}

local function onPlayerUpdate(player)
    if not player:isLocalPlayer() then return end
    local weapon = player:getPrimaryHandItem()
    if Flamethrower.isFlamethrower(weapon) then
        lastFuel[player:getPlayerNum()] = weapon:getCurrentAmmoCount()
    else
        lastFuel[player:getPlayerNum()] = nil
    end
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- ------------------------------------------------------------------ burst --

local function addFire(fires, seen, square)
    if square == nil then return end
    local key = square:getX() .. "," .. square:getY() .. "," .. square:getZ()
    if seen[key] then return end
    seen[key] = true
    fires[#fires + 1] = { x = square:getX(), y = square:getY(), z = square:getZ() }
end

-- Another player can be burned only where they could be shot: a PvP server,
-- and neither of you with safety on.
local function canBurnPlayer(shooter, target)
    if not isClient() then return false end
    local options = getServerOptions()
    if not (options and options:getBoolean("PVP")) then return false end
    return not shooter:getSafety():isEnabled() and not target:getSafety():isEnabled()
end

-- How far the flame has to go to reach it, or nil if it is outside the cone.
-- Something right on top of you only has to be in front.
local function reachInCone(shooter, target, dirX, dirY, cosHalfAngle, range, floorZ)
    if target:isDead() or math.floor(target:getZ()) ~= floorZ then return nil end
    local dx, dy = target:getX() - shooter:getX(), target:getY() - shooter:getY()
    local distanceSq = dx * dx + dy * dy
    if distanceSq > range * range then return nil end
    local distance = math.sqrt(distanceSq)
    if distance < 0.01 then return nil end
    local cosAngle = (dx * dirX + dy * dirY) / distance
    local minimum = distance < 1.0 and 0.0 or cosHalfAngle
    if cosAngle < minimum then return nil end
    return distance
end

local function collectCandidates(shooter, dirX, dirY, config)
    local cosHalfAngle = math.cos(math.rad(config.coneDegrees / 2))
    local floorZ = math.floor(shooter:getZ())
    local candidates = {}

    local function consider(target)
        local distance = reachInCone(shooter, target, dirX, dirY, cosHalfAngle, config.range, floorZ)
        if distance then candidates[#candidates + 1] = { target = target, distance = distance } end
    end

    local cell = getCell()
    local zombies = cell:getZombieList()
    for i = 0, zombies:size() - 1 do consider(zombies:get(i)) end

    local animals = cell:getAnimals()
    if animals then
        for i = 0, animals:size() - 1 do consider(animals:get(i)) end
    end

    if isClient() then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do
            local player = players:get(i)
            if player ~= shooter and not instanceof(player, "IsoAnimal") and canBurnPlayer(shooter, player) then
                consider(player)
            end
        end
    end

    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    return candidates
end

-- Sets what the stream reaches alight. Anything this game drives is lit here
-- and now; anything another game drives needs a fire under it, started by the
-- server (see Flamethrower.applyBurst).
local function igniteTargets(shooter, dirX, dirY, config, fires, seen, animals)
    local lit = 0
    local candidates = collectCandidates(shooter, dirX, dirY, config)
    for i = 1, #candidates do
        if lit >= config.maxTargets then break end
        local target = candidates[i].target
        if GridLine.hasClearLine(shooter, target) then
            lit = lit + 1
            if instanceof(target, "IsoZombie") then
                if isClient() and target:isRemoteZombie() then
                    addFire(fires, seen, target:getCurrentSquare())
                elseif not target:isOnFire() then
                    target:SetOnFire()
                end
            elseif instanceof(target, "IsoAnimal") then
                if isClient() then
                    animals[#animals + 1] = target:getOnlineID()
                elseif not target:isOnFire() then
                    target:SetOnFire()
                end
            else
                addFire(fires, seen, target:getCurrentSquare())
            end
        end
    end
end

-- Burning patches along the middle of the stream, up to the first wall or
-- closed door or window - never at your own feet.
local function rollGroundFires(shooter, dirX, dirY, config, fires, seen)
    if config.groundFireChance <= 0 then return end
    local x, y = shooter:getX(), shooter:getY()
    local minDistanceSq = config.groundFireMinDistance * config.groundFireMinDistance
    GridLine.walk(shooter, x + dirX * config.range, y + dirY * config.range, config.range, function(a, b)
        if GridLine.blocksReach(a, b) then return true end
        local dx, dy = b:getX() + 0.5 - x, b:getY() + 0.5 - y
        if dx * dx + dy * dy >= minDistanceSq and ZombRandFloat(0.0, 1.0) < config.groundFireChance then
            addFire(fires, seen, b)
        end
        return nil
    end)
end

local function burst(shooter)
    local config = Flamethrower.CONFIG
    local dirX, dirY = shooter:getForwardDirectionX(), shooter:getForwardDirectionY()
    local length = math.sqrt(dirX * dirX + dirY * dirY)
    if length < 0.0001 then return end
    dirX, dirY = dirX / length, dirY / length

    local fires, seen, animals = {}, {}, {}
    igniteTargets(shooter, dirX, dirY, config, fires, seen, animals)
    rollGroundFires(shooter, dirX, dirY, config, fires, seen)
    if #fires == 0 and #animals == 0 then return end

    if isClient() then
        sendClientCommand(shooter, Flamethrower.MODULE, "FlameBurst", { fires = fires, animals = animals })
    else
        Flamethrower.applyBurst(fires, animals)
    end
end

-- One call per shot, the same event vanilla takes the ammo off in.
local function onWeaponSwingHitPoint(character, weapon)
    if not Flamethrower.isFlamethrower(weapon) then return end
    if not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() then return end
    local fuel = lastFuel[character:getPlayerNum()]
    if fuel == nil or fuel <= 0 then return end
    burst(character)
end
Events.OnWeaponSwingHitPoint.Add(onWeaponSwingHitPoint)

-- ------------------------------------------------------------------ menus --

-- A fuel tank is a magazine, so vanilla's right-click menu for it would offer
-- to load it with loose rounds of the placeholder fuel item (greyed out: there
-- are none) and to unload it into them. Petrol goes in through the fill
-- recipe and only comes out as flame, so neither is shown. Swapping tanks in
-- and out of the flamethrower is left alone. Racking fuel out of the weapon is
-- blocked in shared/SCP001/Flamethrower.lua.
local doMagazineMenu = ISInventoryPaneContextMenu.doMagazineMenu
ISInventoryPaneContextMenu.doMagazineMenu = function(playerObj, magazine, context)
    if Flamethrower.isTank(magazine) then return end
    return doMagazineMenu(playerObj, magazine, context)
end

-- Nothing should survive into a new world.
local function clearFuel()
    lastFuel = {}
end
Events.OnGameStart.Add(clearFuel)
