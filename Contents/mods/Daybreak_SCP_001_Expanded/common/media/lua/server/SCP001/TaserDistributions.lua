-- Loot for the Daybreak Taser and its cartridges: police-issue and
-- retail/black-market gun spawns, mirroring where a real taser would turn
-- up. Container names are vanilla ProceduralDistributions.list keys
-- (Build 42.20); weights follow the same scale as
-- ContactLensDistributions.lua in this same folder.
require "Items/ProceduralDistributions"

local function addLoot(tableName, itemType, weight)
    local lootTable = ProceduralDistributions.list[tableName]
    if not lootTable or not lootTable.items then return end
    table.insert(lootTable.items, itemType)
    table.insert(lootTable.items, weight)
end

local function addTaserLoot()
    -- The taser itself: standard police issue, rarer anywhere else.
    addLoot("PoliceStorageGuns", "Daybreak_Taser", 4)
    addLoot("PoliceLockers", "Daybreak_Taser", 2)
    addLoot("SWATStorageGuns", "Daybreak_Taser", 3)
    addLoot("GunStoreGuns", "Daybreak_Taser", 1.5)
    addLoot("GunStoreDisplayCase", "Daybreak_Taser", 1)
    addLoot("PawnShopGuns", "Daybreak_Taser", 0.5)

    -- Spare cartridges: meant to be more common than the taser itself, at
    -- the same general spawn points plus evidence lockers.
    addLoot("PoliceStorageAmmunition", "Daybreak_TaserCartridge", 10)
    addLoot("PoliceStorageGuns", "Daybreak_TaserCartridge", 6)
    addLoot("PoliceEvidence", "Daybreak_TaserCartridge", 4)
    addLoot("SWATStorageAmmunition", "Daybreak_TaserCartridge", 8)
    addLoot("GunStoreAmmunition", "Daybreak_TaserCartridge", 5)
    addLoot("GunStoreMagsAmmo", "Daybreak_TaserCartridge", 5)
    addLoot("PawnShopGuns", "Daybreak_TaserCartridge", 1)
end
Events.OnPreDistributionMerge.Add(addTaserLoot)
