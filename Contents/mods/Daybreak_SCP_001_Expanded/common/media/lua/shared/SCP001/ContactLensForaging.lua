-- Foraging applies its own Short Sighted vision penalty, and its test only
-- looks at the Eyes slot, so contact lenses wouldn't clear it. This widens the
-- test to isWearingVisualAid(), which checks every worn item in any location -
-- a strict superset of the vanilla behaviour, so glasses still work as before.
--
-- forageSkills.lua captured the original function by value into the skill
-- definition's testFuncs, so replacing forageSystem.doGlassesCheck alone would
-- do nothing; the captured entry has to be swapped too.
require "Foraging/forageSkills"

local function daybreakGlassesCheck(character, skillDef, bonusEffect)
    if bonusEffect == "visionBonus" and character:isWearingVisualAid() then
        return false
    end
    return true
end

local originalCheck = forageSystem.doGlassesCheck
forageSystem.doGlassesCheck = daybreakGlassesCheck

local shortSighted = forageSystem.forageSkillDefinitions and forageSystem.forageSkillDefinitions.ShortSighted
if shortSighted and shortSighted.testFuncs then
    for i = 1, #shortSighted.testFuncs do
        if shortSighted.testFuncs[i] == originalCheck then
            shortSighted.testFuncs[i] = daybreakGlassesCheck
        end
    end
end
