-- Runs before item scripts are parsed (ModRegistries.init precedes
-- ScriptManager.Load), which is the only window in which a custom body
-- location can be created. If this file is missing or misplaced, the contact
-- lens items parse with a null BodyLocation and are silently unwearable.
-- The namespace prefix is mandatory; the registry rejects plain "base".
ItemBodyLocation.register("Daybreak:ContactLenses")

-- Ammo types live in a registry of the same kind, and the taser's AmmoType is
-- resolved while its item script is parsed, so the cartridge has to be
-- registered here too. Arguments are (resource name, item key).
AmmoType.register("Daybreak:taser_cartridge", "Base.Daybreak_TaserCartridge")

-- The flamethrower's fuel is its ammo, fed from fuel tanks that work as its
-- magazines. An ammo type needs an item, so this one points at a fuel item
-- that never spawns.
AmmoType.register("Daybreak:flamethrower_fuel", "Base.Daybreak_FlamethrowerFuel")
