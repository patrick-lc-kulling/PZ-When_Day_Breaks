-- Starts a flamethrower burst's fires in multiplayer.
--
-- IsoFireManager.StartFire does nothing on a multiplayer client, and the
-- server owns every animal, so the shooter's game works out what the stream
-- reached and asks the server to light it. What arrives is checked against the
-- sender first: flamethrower in hand, everything within the flame's reach.
if isClient() then return end

require "SCP001/Flamethrower"

local Flamethrower = DaybreakFlamethrower

-- Slack on top of the flame's range for the shooter having moved on while the
-- command was in flight.
local RANGE_SLACK = 2
local MAX_FIRES = 40
local MAX_ANIMALS = 10

local function withinReach(player, x, y, z, reach)
    if math.floor(z) ~= math.floor(player:getZ()) then return false end
    local dx, dy = x - player:getX(), y - player:getY()
    return dx * dx + dy * dy <= reach * reach
end

local function onClientCommand(module, command, player, args)
    if module ~= Flamethrower.MODULE or command ~= "FlameBurst" then return end
    if not player or player:isDead() or not args then return end
    if not Flamethrower.isFlamethrower(player:getPrimaryHandItem()) then return end

    local reach = Flamethrower.CONFIG.range + RANGE_SLACK
    local fires, animals = {}, {}

    if type(args.fires) == "table" then
        for _, fire in ipairs(args.fires) do
            if #fires >= MAX_FIRES then break end
            local x, y, z = tonumber(fire.x), tonumber(fire.y), tonumber(fire.z)
            if x and y and z and withinReach(player, x + 0.5, y + 0.5, z, reach) then
                fires[#fires + 1] = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
            end
        end
    end

    if type(args.animals) == "table" then
        for _, id in ipairs(args.animals) do
            if #animals >= MAX_ANIMALS then break end
            local animal = tonumber(id) and getAnimal(tonumber(id))
            if animal and withinReach(player, animal:getX(), animal:getY(), animal:getZ(), reach) then
                animals[#animals + 1] = tonumber(id)
            end
        end
    end

    Flamethrower.applyBurst(fires, animals)
end
Events.OnClientCommand.Add(onClientCommand)
