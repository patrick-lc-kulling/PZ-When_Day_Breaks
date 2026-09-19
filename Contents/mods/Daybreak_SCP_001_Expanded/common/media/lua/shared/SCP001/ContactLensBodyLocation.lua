-- Contact lenses sit in their own body location so they can be worn under
-- helmets and gas masks. Every vanilla head covering is declared exclusive
-- with the Eyes slot, which is why prescription glasses can't be. Exclusivity
-- is opt-in, so registering this location and declaring nothing leaves it
-- compatible with everything.
local group = BodyLocations.getGroup("Human")
group:getOrCreateLocation(ItemBodyLocation.get(ResourceLocation.of("Daybreak:ContactLenses")))
