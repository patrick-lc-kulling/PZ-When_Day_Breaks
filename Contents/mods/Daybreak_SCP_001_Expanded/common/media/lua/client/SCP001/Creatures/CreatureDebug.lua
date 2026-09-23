-- Debug mode only: right-click the ground to spawn any creature type there,
-- instead of waiting weeks of game time for the evolution curve to get to it.
-- Single player only; the server code it calls lives in the same game there.

require "ISUI/ISContextMenu"

local function spawnHere(typeId, x, y, z)
    local creatures = DaybreakCreatures
    local def = creatures and creatures.get(typeId)
    if def and def.isAnimal then
        -- The Great Collective is an animal, spawned by its own code.
        local collectives = creatures.Collectives
        if collectives then collectives.spawnAt(x, y, z, creatures.Tuning.collective.startMass) end
        return
    end
    local server = creatures and creatures.Server
    if server then server.spawnAs(typeId, x, y, z, 1, 1.0) end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test or not isDebugEnabled() or isClient() then return end
    if not (DaybreakCreatures and DaybreakCreatures.Server) then return end

    local object = worldObjects and worldObjects[1]
    local square = object and object:getSquare()
    if square == nil then return end

    local option = context:addOption("Daybreak: Spawn Creature", worldObjects, nil)
    local subMenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, subMenu)
    for _, def in ipairs(DaybreakCreatures.all()) do
        subMenu:addOption(def.id, def.id, spawnHere, square:getX(), square:getY(), square:getZ())
    end
end
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
