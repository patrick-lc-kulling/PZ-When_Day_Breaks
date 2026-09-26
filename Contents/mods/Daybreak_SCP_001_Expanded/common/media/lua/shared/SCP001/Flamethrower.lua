-- Flamethrower: its tunables, its fuel tanks, and starting fires.
--
-- Everything about how the flame behaves lives in CONFIG below. Its physical
-- stats - weight, noise, tank size - are in the item script instead
-- (media/scripts/daybreak_flamethrower.txt), because the engine reads those
-- directly. The fuel tank is the weapon's magazine: one "round" is one burst.

require "TimedActions/ISReloadWeaponAction"

DaybreakFlamethrower = DaybreakFlamethrower or {}
local Flamethrower = DaybreakFlamethrower

Flamethrower.ITEM = "Base.Daybreak_Flamethrower"
Flamethrower.TANK = "Base.Daybreak_FlamethrowerTank"
Flamethrower.MODULE = "Daybreak"

Flamethrower.CONFIG = {
    range            = 10.0, -- tiles the flame reaches; keep the script's MaxRange the same
    coneDegrees      = 30,   -- full width of the stream, in degrees
    maxTargets       = 6,    -- most things one burst sets alight, nearest first

    -- Filling a tank. A full one (MaxAmmo 150 in the script) is 7.5 L.
    litresPerShot    = 0.05, -- petrol one burst burns
    minFillShots     = 15,   -- the least one fill adds; the fill recipe's -fluid
                             -- amount must be minFillShots x litresPerShot (0.75)

    -- Burning patches the stream leaves on the ground. Like a molotov's, they
    -- spread into grass and anything else flammable.
    groundFireChance      = 0.15, -- per square the stream crosses, per burst; 0 = never
    groundFireMinDistance = 2,    -- tiles; never lights the ground nearer you than this
    groundFireLife        = 300,  -- how long a patch burns, in fire ticks (vanilla: 800-3000)
    groundFireEnergy      = 100,  -- how fiercely it starts (vanilla's own debug fire: 100)
}

function Flamethrower.isFlamethrower(item)
    return item ~= nil and item:getFullType() == Flamethrower.ITEM
end

function Flamethrower.isTank(item)
    return item ~= nil and item:getFullType() == Flamethrower.TANK
end

-- Fuel is not rounds. With no chamber and fuel in the tank, vanilla would let
-- you "rack" a flamethrower - taking one burst out as a loose fuel item - and
-- single player queues exactly that after every tank you insert. Racking it
-- is never possible; this is shared so the server refuses it too.
local canRack = ISReloadWeaponAction.canRack
ISReloadWeaponAction.canRack = function(weapon)
    if Flamethrower.isFlamethrower(weapon) then return false end
    return canRack(weapon)
end

-- ------------------------------------------------------------ filling --

local EPSILON = 0.0001

local function isPurePetrol(item)
    local fluid = item and item:getFluidContainer()
    return fluid ~= nil and not fluid:isEmpty() and fluid:isPureFluid(Fluid.Petrol)
end

-- Takes the petrol for up to shotsWanted bursts out of a container, and says
-- how many it had.
local function drawPetrol(source, shotsWanted, litresPerShot)
    local fluid = source:getFluidContainer()
    local shots = math.min(shotsWanted, math.floor(fluid:getAmount() / litresPerShot + EPSILON))
    if shots <= 0 then return 0 end
    fluid:adjustAmount(math.max(0, fluid:getAmount() - shots * litresPerShot))
    if isServer() then source:syncItemFields() end
    return shots
end

local function addAll(list, items)
    if not items then return end
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
end

-- OnTest of the fill recipe: a tank needs room for at least the minimum fill.
-- It is asked about every candidate input, the petrol can included, so
-- anything that isn't a tank has to pass.
function Flamethrower.canFillTank(item, character)
    if not Flamethrower.isTank(item) then return true end
    return item:getMaxAmmo() - item:getCurrentAmmoCount() >= Flamethrower.CONFIG.minFillShots
end

-- OnCreate of the fill recipe, called as (craftRecipeData, character). The
-- recipe has already taken the minimum fill's petrol from one container; this
-- tops the tank up as far as the petrol you carry allows - that container
-- first, then any other pure petrol in your inventory and bags, the emptiest
-- first so part-used cans get finished off.
function Flamethrower.onFillTank(craftRecipeData, character)
    local config = Flamethrower.CONFIG
    local inputs = {}
    addAll(inputs, craftRecipeData:getAllKeepInputItems())
    addAll(inputs, craftRecipeData:getAllConsumedItems())

    local tank, used = nil, nil
    for i = 1, #inputs do
        local item = inputs[i]
        if Flamethrower.isTank(item) then
            tank = item
        elseif isPurePetrol(item) then
            used = item
        end
    end
    if tank == nil then return end

    local maxFuel = tank:getMaxAmmo()
    local fuel = math.min(maxFuel, tank:getCurrentAmmoCount() + config.minFillShots)

    local sources = {}
    if used then sources[1] = used end
    if character then
        local others = {}
        addAll(others, character:getInventory():getAllEvalRecurse(function(item)
            return item ~= used and item ~= tank and isPurePetrol(item)
        end))
        table.sort(others, function(a, b)
            return a:getFluidContainer():getAmount() < b:getFluidContainer():getAmount()
        end)
        for i = 1, #others do sources[#sources + 1] = others[i] end
    end

    for i = 1, #sources do
        if fuel >= maxFuel then break end
        fuel = fuel + drawPetrol(sources[i], maxFuel - fuel, config.litresPerShot)
    end

    tank:setCurrentAmmoCount(fuel)
    if isServer() and character then syncItemFields(character, tank) end
end

-- Where a burst's fires are started: in single player straight from the
-- shooter's game, in multiplayer on the server (FlamethrowerServer.lua) -
-- IsoFireManager.StartFire does nothing on a multiplayer client. A fire under
-- a character sets it alight on whichever game owns it, which is how a zombie
-- another client drives catches fire.
--
-- fires: list of { x, y, z }. animals: list of animal online IDs, set alight
-- directly - the server owns every animal.
function Flamethrower.applyBurst(fires, animals)
    local cell = getCell()
    local config = Flamethrower.CONFIG

    for i = 1, #fires do
        local fire = fires[i]
        local square = cell:getGridSquare(fire.x, fire.y, fire.z)
        if square then
            IsoFireManager.StartFire(cell, square, true, config.groundFireEnergy, config.groundFireLife)
        end
    end

    for i = 1, #animals do
        local animal = getAnimal(animals[i])
        if animal and not animal:isDead() and not animal:isOnFire() then
            animal:SetOnFire()
        end
    end
end
