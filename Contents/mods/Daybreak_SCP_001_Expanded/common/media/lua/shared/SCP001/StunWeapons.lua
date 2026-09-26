-- Electric stun weapons: livestock prod, stun gun, taser.
--
-- Everything tunable about their behaviour lives in CONFIG below. Their
-- physical stats - reach, damage, swing speed, weight - are in the item script
-- instead (media/scripts/daybreak_stunweapons.txt), because the engine reads
-- those directly.
--
-- "Stun" means the target is knocked flat and held there for a set number of
-- seconds. A player takes a shorter stun than a zombie.

DaybreakStunWeapons = DaybreakStunWeapons or {}

DaybreakStunWeapons.CONFIG = {
    ["Base.Daybreak_LivestockProd"] = {
        zombieStunSeconds = 6.0, -- how long a zombie is held on the ground
        playerStunSeconds = 1.5, -- the same for a player, in multiplayer
        maxCharge         = 20,  -- zaps per battery
        chargePerUse      = 1,   -- charge spent per connecting hit
        stunChance        = 1.0, -- 1.0 = every hit stuns, 0.5 = half of them
    },

    ["Base.Daybreak_StunGun"] = {
        zombieStunSeconds = 4.0,
        playerStunSeconds = 1.5,
        maxCharge         = 12,
        chargePerUse      = 1,
        stunChance        = 1.0,
    },

    -- The taser is limited by its cartridges rather than by a battery, so it
    -- carries no charge of its own: maxCharge 0 switches the charge system off
    -- for an item entirely.
    ["Base.Daybreak_Taser"] = {
        zombieStunSeconds = 8.0,
        playerStunSeconds = 1.5,
        maxCharge         = 0,
        chargePerUse      = 0,
        stunChance        = 1.0,
    },
}

-- Used only if a stun arrives for a weapon this build has no config for, which
-- can happen if two players run different versions of the mod.
DaybreakStunWeapons.FALLBACK_PLAYER_STUN_SECONDS = 1.5

local CONFIG = DaybreakStunWeapons.CONFIG

function DaybreakStunWeapons.getConfig(item)
    if not item then return nil end
    return CONFIG[item:getFullType()]
end

-- A weapon can't be a drainable item in B42 - base:weapon is a HandWeapon and
-- base:drainable is a DrainableComboItem, and no item is both - so the charge
-- lives in modData and the condition bar is only a display of it.
function DaybreakStunWeapons.getCharge(item, config)
    local modData = item:getModData()
    if modData.DaybreakCharge then return modData.DaybreakCharge end

    -- Loot spawns with a randomised condition, so a weapon found in the world
    -- starts as worn down as its bar looks rather than fully charged.
    local charge = config.maxCharge
    local conditionMax = item:getConditionMax()
    if conditionMax > 0 then
        charge = math.floor(config.maxCharge * (item:getCondition() / conditionMax) + 0.5)
    end
    modData.DaybreakCharge = charge
    return charge
end

function DaybreakStunWeapons.setCharge(item, charge, config)
    if charge < 0 then charge = 0 end
    if charge > config.maxCharge then charge = config.maxCharge end
    item:getModData().DaybreakCharge = charge

    local conditionMax = item:getConditionMax()
    if conditionMax <= 0 or config.maxCharge <= 0 then return end

    -- Floored at 1: the game destroys an item whose condition reaches 0, and a
    -- flat battery should leave the weapon in your hands to be recharged.
    local condition = math.max(1, math.ceil(charge / config.maxCharge * conditionMax))
    if item:getCondition() ~= condition then
        item:setConditionNoSound(condition)
    end
end

-- OnTest of the recharge recipe: keeps it off the menu for a weapon that is
-- already full, so a battery can't be wasted on one.
--
-- This is asked about every candidate input, the battery included, so anything
-- that isn't one of our weapons has to pass - rejecting it here would reject
-- the battery as well and the recipe would never be craftable.
function DaybreakStunWeapons.canRecharge(item, character)
    local config = DaybreakStunWeapons.getConfig(item)
    if not config then return true end
    if config.maxCharge <= 0 then return false end
    return DaybreakStunWeapons.getCharge(item, config) < config.maxCharge
end

-- OnCreate of the recharge recipe, called as (craftRecipeData, character). The
-- weapon is a mode:keep input, so it comes back from getAllKeepInputItems
-- rather than from the consumed list.
function DaybreakStunWeapons.onRecharge(craftRecipeData, character)
    local items = craftRecipeData:getAllKeepInputItems()
    if not items then return end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local config = DaybreakStunWeapons.getConfig(item)
        if config then
            DaybreakStunWeapons.setCharge(item, config.maxCharge, config)
        end
    end
end
