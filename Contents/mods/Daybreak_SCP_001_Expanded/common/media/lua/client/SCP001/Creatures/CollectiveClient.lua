-- The player's side of a Great Collective: taking its hit, and keeping its
-- size right on a multiplayer client.

require "SCP001/Creatures/CollectiveSpecies"

local Creatures = DaybreakCreatures

-- A collective's hit, applied on the victim's own game, where a player's
-- body damage lives. The engine's own animal attack: a wound from the
-- species' damage and a hit reaction. The knockdown is our chance on top,
-- decided by the server. Called directly in single player, and from the
-- server's command in multiplayer.
function Creatures.applyCollectiveHit(player, animal, knockdown)
    if player == nil or animal == nil or player:isDead() then return end
    player:hitConsequences(nil, animal, false, 0, false)
    if knockdown then player:setKnockedDown(true) end
end

-- The crash of something it broke, played where it happened. Called directly
-- in single player, and from the server's command in multiplayer.
function Creatures.playCollectiveSound(args)
    local emitter = args and args.sound and getWorld():getFreeEmitter(args.x, args.y, args.z)
    if emitter then emitter:playSound(args.sound) end
end

-- Actions the model animates - its swing, its absorbing (the look table in
-- CollectiveSpecies.lua): the server sets the animation variable on its own
-- copy for as long as the action lasts, and a multiplayer client sets it on
-- this one, since custom animation variables do not travel with the animal.
local actionPulses = {}

local function startActionPulse(args)
    local animal = args.animal and getAnimal(args.animal)
    if animal == nil or type(args.variable) ~= "string" then return end
    animal:setVariable(args.variable, true)
    actionPulses[#actionPulses + 1] = {
        animal = animal,
        variable = args.variable,
        untilMs = getTimestampMs() + (tonumber(args.seconds) or 0.3) * 1000,
    }
end

local function endActionPulses()
    if #actionPulses == 0 then return end
    local nowMs = getTimestampMs()
    local running = {}
    for i = 1, #actionPulses do
        local pulse = actionPulses[i]
        if nowMs >= pulse.untilMs then
            pulse.animal:setVariable(pulse.variable, false)
        else
            running[#running + 1] = pulse
        end
    end
    actionPulses = running
end
Events.OnTick.Add(endActionPulses)

local function onServerCommand(module, command, args)
    if module ~= Creatures.MODULE or args == nil then return end
    if command == "CollectiveSound" then
        Creatures.playCollectiveSound(args)
        return
    end
    if command == "CollectiveAction" then
        startActionPulse(args)
        return
    end
    if command ~= "CollectiveHit" then return end
    local player = getPlayer()
    local animal = args.animal and getAnimal(args.animal)
    if player and animal then
        Creatures.applyCollectiveHit(player, animal, args.knockdown)
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- The server sets a collective's size from its mass, but it is not clear
-- that animal size reaches clients, so a multiplayer client applies it too,
-- from the mass the server transmits in modData - and marks it a collective
-- for its animations. Single player needs none of
-- this: the server code there is this same game.
local SIZE_EVERY_MS = 1000
local lastSizeMs = 0

local function onTick()
    if not isClient() then return end
    local nowMs = getTimestampMs()
    if nowMs - lastSizeMs < SIZE_EVERY_MS and nowMs >= lastSizeMs then return end
    lastSizeMs = nowMs

    local cell = getCell()
    local animals = cell and cell:getAnimals()
    if animals == nil then return end
    for i = 0, animals:size() - 1 do
        local animal = animals:get(i)
        if Creatures.isCollective(animal) then
            Creatures.applyCollectiveSize(animal)
            -- The marker its animation nodes look for; the server sets it on
            -- its own copy, and animation variables do not travel.
            animal:setVariable(Creatures.CollectiveLook.marker, true)
        end
    end
end
Events.OnTick.Add(onTick)
