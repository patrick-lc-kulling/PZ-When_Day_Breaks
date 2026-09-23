-- Multiplayer: a player's client reports that a Grasper got hold of them, and
-- the server tears the item off, the same place vanilla takes clothing off.
--
-- The client decides whether the grasp succeeded. That is safe to trust: the
-- only thing a dishonest client could do with it is never report one.
if isClient() then return end

require "SCP001/Creatures/CreatureHeadgear"

local Creatures = DaybreakCreatures

local function onClientCommand(module, command, player, args)
    if module ~= Creatures.MODULE or command ~= "GrasperStrip" then return end
    if player == nil or args == nil then return end

    local item = Creatures.findWornItemById(player, args.item)
    if item == nil or not Creatures.isStrippable(item) then return end

    local name = item:getDisplayName()
    if Creatures.stripHeadgear(player, item) then
        sendServerCommand(player, Creatures.MODULE, "HeadgearStripped", { name = name })
    end
end
Events.OnClientCommand.Add(onClientCommand)
