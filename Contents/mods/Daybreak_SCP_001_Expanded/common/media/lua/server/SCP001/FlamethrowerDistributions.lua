-- Where the flamethrower and its fuel tanks turn up: military stores only, and
-- very rarely. For scale, in ArmyStorageGuns (4 rolls) the MSR7T sniper rifle
-- is 4 and the x8 scope 0.5; ArmyBunkerStorage has most of its kit at 0.1 to
-- 1. Both can always be crafted instead (daybreak_flamethrower.txt), and tanks
-- are found empty.
require "Items/ProceduralDistributions"

local LOOT = {
    Daybreak_Flamethrower = {
        ArmyStorageGuns   = 0.3,
        ArmyBunkerStorage = 0.1,
    },
    Daybreak_FlamethrowerTank = {
        ArmyStorageAmmunition = 0.3,
        ArmyBunkerStorage     = 0.1,
    },
}

local function addLoot(tableName, itemType, weight)
    local lootTable = ProceduralDistributions.list[tableName]
    if not lootTable or not lootTable.items then return end
    table.insert(lootTable.items, itemType)
    table.insert(lootTable.items, weight)
end

local function addFlamethrowerLoot()
    for itemType, tables in pairs(LOOT) do
        for tableName, weight in pairs(tables) do
            addLoot(tableName, itemType, weight)
        end
    end
end
Events.OnPreDistributionMerge.Add(addFlamethrowerLoot)
