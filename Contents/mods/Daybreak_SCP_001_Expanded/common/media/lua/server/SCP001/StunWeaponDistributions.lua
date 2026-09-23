-- Where the electric weapons turn up. The prod is farm equipment, so it is
-- common in barns and farm supply; the stun gun is a civilian self-defence
-- item; the taser and its cartridges are police and prison kit. For scale, in
-- BarnTools a hand scythe is 20 and a forged garden hoe is 0.1.
require "Items/ProceduralDistributions"

local function addLoot(tableName, itemType, weight)
    local lootTable = ProceduralDistributions.list[tableName]
    if not lootTable or not lootTable.items then return end
    table.insert(lootTable.items, itemType)
    table.insert(lootTable.items, weight)
end

local function addStunWeaponLoot()
    addLoot("BarnTools", "Daybreak_LivestockProd", 8)
    addLoot("FarmerTools", "Daybreak_LivestockProd", 8)
    addLoot("ToolStoreFarming", "Daybreak_LivestockProd", 4)
    addLoot("CrateFarming", "Daybreak_LivestockProd", 4)
    addLoot("ToolCabinetFarming", "Daybreak_LivestockProd", 2)

    addLoot("PawnShopTools", "Daybreak_StunGun", 6)
    addLoot("GunStoreAccessories", "Daybreak_StunGun", 6)
    addLoot("PoliceTools", "Daybreak_StunGun", 4)
    addLoot("PoliceStateTools", "Daybreak_StunGun", 4)
    addLoot("PoliceLockers", "Daybreak_StunGun", 2)
    addLoot("PrisonGuardLockers", "Daybreak_StunGun", 2)
    addLoot("BedroomSidetable", "Daybreak_StunGun", 0.5)

    addLoot("PoliceTools", "Daybreak_Taser", 6)
    addLoot("PoliceStateTools", "Daybreak_Taser", 6)
    addLoot("PoliceLockers", "Daybreak_Taser", 2)
    addLoot("PrisonGuardLockers", "Daybreak_Taser", 2)
    addLoot("GunStoreAccessories", "Daybreak_Taser", 0.5)

    addLoot("PoliceTools", "Daybreak_TaserCartridge", 8)
    addLoot("PoliceStateTools", "Daybreak_TaserCartridge", 8)
    addLoot("PoliceLockers", "Daybreak_TaserCartridge", 4)
    addLoot("PrisonGuardLockers", "Daybreak_TaserCartridge", 4)
    addLoot("PoliceStorageAmmunition", "Daybreak_TaserCartridge", 4)
    addLoot("GunStoreAccessories", "Daybreak_TaserCartridge", 2)
end
Events.OnPreDistributionMerge.Add(addStunWeaponLoot)
