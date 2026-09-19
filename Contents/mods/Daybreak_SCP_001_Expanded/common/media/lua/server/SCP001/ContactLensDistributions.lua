-- Low, concentrated spawns: common where an optometrist or pharmacy would
-- stock them, rare in a random bathroom. For scale, in BathroomCabinet a
-- toothbrush is 10 and antibiotics are 0.5.
require "Items/ProceduralDistributions"

local function addLoot(tableName, itemType, weight)
    local lootTable = ProceduralDistributions.list[tableName]
    if not lootTable or not lootTable.items then return end
    table.insert(lootTable.items, itemType)
    table.insert(lootTable.items, weight)
end

local function addContactLensLoot()
    addLoot("OptometristGlasses", "Daybreak_ContactLenses", 20)
    addLoot("OptometristGlasses", "Daybreak_LensSolution", 12)

    addLoot("PharmacyGlasses", "Daybreak_ContactLenses", 12)
    addLoot("PharmacyGlasses", "Daybreak_LensSolution", 16)

    addLoot("BathroomCabinet", "Daybreak_ContactLenses", 2)
    addLoot("BathroomCabinet", "Daybreak_LensSolution", 3)

    addLoot("MedicalCabinet", "Daybreak_LensSolution", 4)
    addLoot("MedicalClinicDrugs", "Daybreak_LensSolution", 5)

    addLoot("BedroomSidetable", "Daybreak_ContactLenses", 0.2)
end
Events.OnPreDistributionMerge.Add(addContactLensLoot)
