-- The Grasper's ability: tearing a player's helmet or mask off.
--
-- Shared, because the strip itself has to run where vanilla's own unequip
-- and drop run - on the server in multiplayer, in the game itself in single
-- player. The client only detects the grasp and asks, see CreatureClient.lua.

require "SCP001/Creatures/CreatureTypes"
require "TimedActions/ISTransferAction"

local Creatures = DaybreakCreatures

local function locationName(item)
    local location = item:getBodyLocation()
    if location == nil then return nil end
    -- Build 42 namespaced body locations ("base:fullhat"); both forms occur.
    local name = string.gsub(string.lower(tostring(location)), "^base:", "")
    return name
end

local function locationRanks()
    local ranks = {}
    for rank, location in ipairs(Creatures.Tuning.strippableLocations) do
        ranks[location] = rank
    end
    return ranks
end

function Creatures.isStrippable(item)
    return item ~= nil and locationRanks()[locationName(item)] ~= nil
end

-- The worn item a grasper goes for: whichever strippable one ranks highest in
-- Tuning.strippableLocations, or nil if the player wears none.
function Creatures.findStrippableHeadgear(player)
    local worn = player:getWornItems()
    if worn == nil then return nil end

    local ranks = locationRanks()
    local best, bestRank = nil, nil
    for i = 0, worn:size() - 1 do
        local item = worn:get(i):getItem()
        local rank = item and ranks[locationName(item)]
        if rank and (bestRank == nil or rank < bestRank) then
            best, bestRank = item, rank
        end
    end
    return best
end

function Creatures.findWornItemById(player, itemId)
    local worn = player:getWornItems()
    if worn == nil or itemId == nil then return nil end
    for i = 0, worn:size() - 1 do
        local item = worn:get(i):getItem()
        if item and item:getID() == itemId then return item end
    end
    return nil
end

-- Take the item off and drop it at the player's feet. The same sequence as
-- ISUnequipAction:complete followed by a forced drop, including its network
-- calls, which do nothing outside multiplayer.
function Creatures.stripHeadgear(player, item)
    if player == nil or item == nil or player:isDead() then return false end
    if Creatures.findWornItemById(player, item:getID()) == nil then return false end

    player:removeWornItem(item)
    sendEquip(player)
    -- The sun code listens for this and re-checks the head straight away.
    triggerEvent("OnClothingUpdated", player)

    local inventory = player:getInventory()
    inventory:Remove(item)
    sendRemoveItemFromContainer(inventory, item)

    local square = player:getCurrentSquare()
    if square then
        local dropX, dropY, dropZ = ISTransferAction.GetDropItemOffset(player, square, item)
        square:AddWorldInventoryItem(item, dropX, dropY, dropZ)
    end
    return true
end
