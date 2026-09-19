-- Runs before item scripts are parsed (ModRegistries.init precedes
-- ScriptManager.Load), which is the only window in which a custom body
-- location can be created. If this file is missing or misplaced, the contact
-- lens items parse with a null BodyLocation and are silently unwearable.
-- The namespace prefix is mandatory; the registry rejects plain "base".
ItemBodyLocation.register("Daybreak:ContactLenses")
