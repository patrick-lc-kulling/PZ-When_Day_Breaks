-- Contact lenses are upkeep, not a cure: a pair lasts a set number of in-game
-- days of *worn* time, then dries out wherever the player happens to be. The
-- countdown only runs while they're in, so taking them out somewhere safe
-- genuinely saves them.
--
-- Remaining time is mirrored onto the item's condition bar so the player can
-- see how close a pair is to drying out. The modData value is the real clock -
-- condition is a coarse integer and only exists for the display.

local FRESH_LENSES = "Base.Daybreak_ContactLenses"
local USED_LENSES = "Base.Daybreak_ContactLenses_Used"

-- Tweakable via the "Contact Lens Wear Time" sandbox option
-- (SandboxVars.SCP.LensWearDays).
local DEFAULT_WEAR_DAYS = 3.0

local lensLocation
local function getLensLocation()
    if not lensLocation then
        lensLocation = ItemBodyLocation.get(ResourceLocation.of("Daybreak:ContactLenses"))
    end
    return lensLocation
end

local function wearHours()
    local scpOptions = SandboxVars.SCP -- nil on the main menu
    local days = scpOptions and scpOptions.LensWearDays or DEFAULT_WEAR_DAYS
    return days * 24
end

-- A pair found in the world spawns with a randomised condition, so treat that
-- bar as how used it already is rather than handing out a fresh pair.
local function remainingHours(item, totalHours)
    local hoursLeft = item:getModData().DaybreakLensHoursLeft
    if hoursLeft then return hoursLeft end

    local conditionMax = item:getConditionMax()
    if conditionMax <= 0 then return totalHours end
    return totalHours * (item:getCondition() / conditionMax)
end

local function showWearOnCondition(item, hoursLeft, totalHours)
    local conditionMax = item:getConditionMax()
    if conditionMax <= 0 then return end
    -- Floored at 1: condition 0 would have the game destroy the item before it
    -- can be turned into a dried out pair.
    local condition = math.max(1, math.ceil(hoursLeft / totalHours * conditionMax))
    if item:getCondition() ~= condition then
        item:setConditionNoSound(condition)
    end
end

local function dryOut(player, item)
    local inventory = player:getInventory()
    player:removeWornItem(item)
    inventory:Remove(item)
    inventory:AddItem(USED_LENSES)
    -- Same follow-up ISWearClothing does after changing what's worn.
    triggerEvent("OnClothingUpdated", player)
    player:resetModel()
    player:setHaloNote(getText("IGUI_Daybreak_LensesDriedOut"), 255, 80, 80, 300)
end

-- EveryOneMinute can skip minutes while sleeping or fast-forwarding, so the
-- elapsed time comes from the world clock rather than from counting ticks.
local lastWorldAgeHours

local function updateWornLenses()
    local location = getLensLocation()
    if not location then return end

    local nowHours = getGameTime():getWorldAgeHours()
    local elapsedHours = lastWorldAgeHours and (nowHours - lastWorldAgeHours) or 0
    lastWorldAgeHours = nowHours
    if elapsedHours <= 0 then return end

    local totalHours = wearHours()

    for i = 1, getNumActivePlayers() do
        local player = getSpecificPlayer(i - 1)
        if player and player:isAlive() then
            local item = player:getWornItem(location)
            if item and item:getFullType() == FRESH_LENSES then
                local hoursLeft = remainingHours(item, totalHours) - elapsedHours
                if hoursLeft <= 0 then
                    dryOut(player, item)
                else
                    item:getModData().DaybreakLensHoursLeft = hoursLeft
                    showWearOnCondition(item, hoursLeft, totalHours)
                end
            end
        end
    end
end
Events.EveryOneMinute.Add(updateWornLenses)

-- A fresh world/save must not inherit the previous session's reading, or the
-- first tick would bill the player for the gap between them.
local function resetClock()
    lastWorldAgeHours = nil
end
Events.OnGameStart.Add(resetClock)
