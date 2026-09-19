require "TimedActions/ISRepairClothing"

local gameTime
Events.OnGameTimeLoaded.Add(function()
    gameTime = GameTime.getInstance()
end)

local function speedAdjustedDeltaMs()
    if not gameTime then return 0 end
    return gameTime:getMultipliedSecondsSinceLastUpdate() * 1000
end

-- getSkyLightLevel() packs its three channels into one integer as 0xRRGGBB.
local function GetRLightLevel(lightLevel)
    return math.floor(lightLevel / 65536) % 256
end

local function GetGLightLevel(lightLevel)
    return math.floor(lightLevel / 256) % 256
end

local function GetBLightLevel(lightLevel)
    return lightLevel % 256
end

local TestResultsBlockedInstance

local MIN_DANGEROUS_LIGHT_LEVEL = 60
local LIGHT_FALLOFF_PER_TILE = 16 -- on the same z level

-- dx/dy never change, so they're resolved once instead of per neighbour.
local function cardinal(direction)
    return { direction = direction, dx = direction:dx(), dy = direction:dy() }
end
local cardinalDirections = {
    cardinal(IsoDirections.N), cardinal(IsoDirections.W),
    cardinal(IsoDirections.S), cardinal(IsoDirections.E),
}

-- Traces outward from the player's square looking for line-of-sight to open
-- sky, the same way regardless of whether the light being measured comes
-- from the sun or the moon. baseLight is the 0-255 light level at an actual
-- open-air square right now; this returns what that same light level would
-- be by the time it reaches the player (falling off LIGHT_FALLOFF_PER_TILE
-- per tile through windows/doorways), or nil if no light above
-- MIN_DANGEROUS_LIGHT_LEVEL reaches the player at all. Anything at or below
-- that threshold deals no damage, so it must not count as exposure - that
-- would start the sound, wobble and vignette over nothing.
local function findExposureLightLevel(player, baseLight)
    if baseLight <= MIN_DANGEROUS_LIGHT_LEVEL then return nil end

    local startSquare = player:getCurrentSquare()
    if not startSquare then return nil end

    -- LosUtil isn't exposed to Lua, so the Blocked instance is taken from a
    -- call guaranteed to return it (offsets beyond one tile are rejected).
    if not TestResultsBlockedInstance then
        TestResultsBlockedInstance = startSquare:testVisionAdjacent(-2, 0, 0, true, false)
    end

    -- Furthest ring of squares whose light would still be above the threshold.
    local maxDistFromStart = math.ceil((baseLight - MIN_DANGEROUS_LIGHT_LEVEL) / LIGHT_FALLOFF_PER_TILE) - 1

    local squares = { startSquare }
    local distances = { 0 }
    local visited = { [startSquare] = true }
    local head, tail = 1, 1

    while head <= tail do
        local square = squares[head]
        local dist = distances[head]
        head = head + 1

        if square:getOpenAir() then
            return baseLight - LIGHT_FALLOFF_PER_TILE * dist
        end

        if dist < maxDistFromStart then
            for i = 1, #cardinalDirections do
                local cardinalDirection = cardinalDirections[i]
                local result = square:testVisionAdjacent(cardinalDirection.dx, cardinalDirection.dy, 0, true, false)
                if result ~= TestResultsBlockedInstance then
                    local adjacent = square:getAdjacentSquare(cardinalDirection.direction)
                    if adjacent and not visited[adjacent] then
                        visited[adjacent] = true
                        tail = tail + 1
                        squares[tail] = adjacent
                        distances[tail] = dist + 1
                    end
                end
            end
        end
    end

    return nil
end

-- IMPORTANT: getSkyLightLevel() is the *rendered* ambient light color, which
-- is per-player and gets artificially floored by the Cat's Eyes (NightVision)
-- trait and the "Bright Nights" sandbox option (see
-- RenderSettings.PlayerRenderSettings.updateRenderSettings client-side) - so
-- it reads as "bright" at night for anyone with either of those, even though
-- there is no actual sunlight. getDayLightStrength() is a real, trait-blind
-- environmental value, so it's used here purely to gate this function to
-- daytime; isMoonlit (below) handles genuine night-time light from an
-- entirely separate, trait-blind source.
local function isSunlit(player, scpPlayerData)
    if getClimateManager():getDayLightStrength() <= 0 then return false end -- night: no real sunlight regardless of rendered light level

    local skyLightLevel = getGameTime():getSkyLightLevel()
    local maxSkylight = math.max(
        GetRLightLevel(skyLightLevel), GetGLightLevel(skyLightLevel), GetBLightLevel(skyLightLevel)
    )

    local lightAtPlayer = findExposureLightLevel(player, maxSkylight)
    if not lightAtPlayer then return false end

    scpPlayerData.currentSquareLight = lightAtPlayer
    scpPlayerData.exposureSource = "sun"
    return true
end

-- How bright moonlight gets at its absolute strongest (full moon, clear sky,
-- standing right under open air), on the same 0-255 scale as sunlight above.
-- Falls off with distance from an opening exactly like sunlight, and gets
-- dimmed by cloud cover. Deliberately weak by default (below
-- MIN_DANGEROUS_LIGHT_LEVEL outside of a full moon) so moonlight damage is a
-- rare, atmospheric event rather than a nightly occurrence. Tweakable via the
-- "Moonlight Max Intensity" sandbox option (SandboxVars.SCP.MoonlightMaxIntensity).
local MOONLIGHT_MAX_INTENSITY = 100
-- Master on/off switch for the moonlight damage mechanic, independent of the
-- intensity slider above. Tweakable via the "Enable Moonlight Damage"
-- sandbox option (SandboxVars.SCP.MoonlightDamageEnabled).
local MOONLIGHT_DAMAGE_ENABLED = true

-- Deliberately independent of getSkyLightLevel() (see the comment on
-- isSunlit above): ClimateMoon's phase and ClimateManager's cloud intensity
-- are both real, server-driven environmental values with no per-player
-- rendering component, so this can't be inflated by Cat's Eyes/Bright Nights.
local function isMoonlit(player, scpPlayerData)
    if not MOONLIGHT_DAMAGE_ENABLED then return false end
    if getClimateManager():getDayLightStrength() > 0 then return false end -- daytime; isSunlit handles it

    local moonFloat = ClimateMoon.getInstance():getMoonFloat() -- 0 (new moon) .. 1 (full moon)
    if moonFloat <= 0 then return false end

    local cloudDampening = 1.0 - getClimateManager():getCloudIntensity()
    local baseLight = MOONLIGHT_MAX_INTENSITY * moonFloat * cloudDampening

    local lightAtPlayer = findExposureLightLevel(player, baseLight)
    if not lightAtPlayer then return false end

    scpPlayerData.currentSquareLight = lightAtPlayer
    scpPlayerData.exposureSource = "moon"
    return true
end

-- Body locations that count as covering the head, mapped to the default head
-- damage multiplier for items worn there. Build 42's ResourceLocation/Registry
-- rework namespaced these BodyLocation IDs, so both forms are listed.
local MASK_HEAD_DAMAGE_MULTIPLIER = 0.45
local headCoveringLocationDefaults = {
    ["fullsuithead"] = 0, ["base:fullsuithead"] = 0,
    ["maskfull"] = 0, ["base:maskfull"] = 0,
    ["fullhat"] = 0, ["base:fullhat"] = 0,
    ["mask"] = MASK_HEAD_DAMAGE_MULTIPLIER, ["base:mask"] = MASK_HEAD_DAMAGE_MULTIPLIER,
    ["maskeyes"] = MASK_HEAD_DAMAGE_MULTIPLIER, ["base:maskeyes"] = MASK_HEAD_DAMAGE_MULTIPLIER,
}

local function headCoveringLocationDefault(inventoryItem)
    return headCoveringLocationDefaults[string.lower(tostring(inventoryItem:getBodyLocation()))]
end

local function coversHead(inventoryItem)
    return headCoveringLocationDefault(inventoryItem) ~= nil
end

-- Per-item head damage multipliers (0-1) for items that pass
-- coversHead(), keyed by full item type (e.g. "Base.Hat_RiotHelmet"),
-- split into one file per group of body locations (full-head coverings,
-- MASK, MASK_EYES) but merged into one lookup table.
-- 0 = the item fully shields the head, 1 = the head takes damage as if bare.
-- Any head covering not listed (including modded ones) falls back to its
-- body location's default in headCoveringLocationDefaults.
-- getModFileReader checks the mod's version folder first, then common/.
local MOD_ID = "Daybreak_SCP_001_Expanded"
local HEAD_COVERING_MULTIPLIER_PATHS = {
    "media/dmg_multipliers/HeadCoveringDamageMultipliers.json",
    "media/dmg_multipliers/MaskDamageMultipliers.json",
    "media/dmg_multipliers/MaskEyesDamageMultipliers.json",
}
local headCoveringMultipliers = {}

-- Kahlua has no JSON library, and each file is a single flat object of
-- "ItemType": number pairs, so a pattern match over the whole text is
-- enough. Values are clamped into 0-1.
local function loadMultiplierFile(path, multipliers)
    local reader = getModFileReader(MOD_ID, path, false)
    if not reader then
        print("[Daybreak] Could not open " .. path .. ", its items will use their body location defaults")
        return
    end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()

    local text = table.concat(lines, "\n")
    for itemType, value in string.gmatch(text, "\"([^\"]+)\"%s*:%s*(-?[%d%.]+[eE]?[-+]?%d*)") do
        local number = tonumber(value)
        if number then
            multipliers[itemType] = math.max(0, math.min(number, 1))
        end
    end
end

local function loadHeadCoveringMultipliers()
    local multipliers = {}
    for i = 1, #HEAD_COVERING_MULTIPLIER_PATHS do
        loadMultiplierFile(HEAD_COVERING_MULTIPLIER_PATHS[i], multipliers)
    end
    headCoveringMultipliers = multipliers
end

local function headCoveringDamageMultiplier(inventoryItem)
    return headCoveringMultipliers[inventoryItem:getFullType()]
        or headCoveringLocationDefault(inventoryItem) or 0
end

local TOTAL_BODY_PARTS = BloodBodyPartType.MAX:index()

-- The head burns/damages faster than other body parts once exposed - applied
-- as a weight on top of the normal 1-per-part contribution to the damage
-- fraction below, whether the head is bare or just showing through a hole.
-- Tweakable in-game via the "Head Damage Multiplier" sandbox option
-- (SandboxVars.SCP.HeadDamageMultiplier) - see loadSandboxOptions() below.
local HEAD_DAMAGE_MULTIPLIER = 3
-- Multiplies the final health damage dealt to the player from sunlight
-- exposure, across all body parts. Tweakable via the "General Damage
-- Multiplier" sandbox option (SandboxVars.SCP.GeneralDamageMultiplier).
local GENERAL_DAMAGE_MULTIPLIER = 1
local HEAD_PART_INDEX = BloodBodyPartType.Head:index()
local TOTAL_DAMAGE_WEIGHT = (TOTAL_BODY_PARTS - 1) + HEAD_DAMAGE_MULTIPLIER

local function partDamageWeight(partIndex)
    if partIndex == HEAD_PART_INDEX then return HEAD_DAMAGE_MULTIPLIER end
    return 1
end

-- Weighted equivalent of (uncovered + holed part count) / TOTAL_BODY_PARTS:
-- same 0-1 range (0 = fully covered, 1 = fully exposed), but an exposed head
-- pulls the fraction toward 1 harder than any other single part would.
-- A head covered only by intact head coverings still counts partially,
-- scaled by headCoverMultiplier (0 while it's bare or holed, since it's
-- already counted in full above).
local function weightedExposureFraction(scpPlayerData)
    local sum = 0
    for partIndex in pairs(scpPlayerData.uncoveredParts) do
        sum = sum + partDamageWeight(partIndex)
    end
    for partIndex in pairs(scpPlayerData.holedParts) do
        sum = sum + partDamageWeight(partIndex)
    end
    sum = sum + HEAD_DAMAGE_MULTIPLIER * scpPlayerData.headCoverMultiplier
    return sum / TOTAL_DAMAGE_WEIGHT
end

-- How much of the light reaches the head specifically (0-1): all of it while
-- the head is bare or showing through a hole, otherwise however much the head
-- covering lets through - 0 behind a sealed helmet, more behind a thin mask.
-- The liquefaction sound and the screen wobble both scale with this, since
-- they're what the player's own head is going through.
local function headLightExposure(scpPlayerData)
    if scpPlayerData.uncoveredParts[HEAD_PART_INDEX] or scpPlayerData.holedParts[HEAD_PART_INDEX] then
        return 1.0
    end
    return scpPlayerData.headCoverMultiplier
end

-- Whether anything below the neck is bare or holed. The head covering only
-- muffles the liquefaction sound while it isn't - any other exposed part is
-- liquefying at full tilt no matter what's on the head.
local function hasExposureBesidesHead(scpPlayerData)
    for partIndex in pairs(scpPlayerData.uncoveredParts) do
        if partIndex ~= HEAD_PART_INDEX then return true end
    end
    for partIndex in pairs(scpPlayerData.holedParts) do
        if partIndex ~= HEAD_PART_INDEX then return true end
    end
    return false
end

-- BloodBodyPartType (used for clothing coverage) and BodyPartType (used for
-- actual body damage/wounds) are two different enums that happen to share
-- almost all the same names. This maps clothing-coverage zones to the wound
-- zone we apply burns to. BloodBodyPartType.Back has no BodyPartType
-- equivalent (it's a texture-only location, e.g. for backpack blood splatter)
-- so it's intentionally left out - it will just never receive a burn wound.
local bloodPartToBodyPartType = {
    [BloodBodyPartType.Hand_L:index()] = BodyPartType.Hand_L,
    [BloodBodyPartType.Hand_R:index()] = BodyPartType.Hand_R,
    [BloodBodyPartType.ForeArm_L:index()] = BodyPartType.ForeArm_L,
    [BloodBodyPartType.ForeArm_R:index()] = BodyPartType.ForeArm_R,
    [BloodBodyPartType.UpperArm_L:index()] = BodyPartType.UpperArm_L,
    [BloodBodyPartType.UpperArm_R:index()] = BodyPartType.UpperArm_R,
    [BloodBodyPartType.Torso_Upper:index()] = BodyPartType.Torso_Upper,
    [BloodBodyPartType.Torso_Lower:index()] = BodyPartType.Torso_Lower,
    [BloodBodyPartType.Head:index()] = BodyPartType.Head,
    [BloodBodyPartType.Neck:index()] = BodyPartType.Neck,
    [BloodBodyPartType.Groin:index()] = BodyPartType.Groin,
    [BloodBodyPartType.UpperLeg_L:index()] = BodyPartType.UpperLeg_L,
    [BloodBodyPartType.UpperLeg_R:index()] = BodyPartType.UpperLeg_R,
    [BloodBodyPartType.LowerLeg_L:index()] = BodyPartType.LowerLeg_L,
    [BloodBodyPartType.LowerLeg_R:index()] = BodyPartType.LowerLeg_R,
    [BloodBodyPartType.Foot_L:index()] = BodyPartType.Foot_L,
    [BloodBodyPartType.Foot_R:index()] = BodyPartType.Foot_R,
}

local function hasUnpatchedHole(itemVisual, inventoryItem, part)
    if itemVisual:getHole(part) <= 0 then return false end
    -- getPatchType only exists on Clothing (not the base InventoryItem), but
    -- every item that reaches here already passed getBloodClothingType(), so
    -- it's effectively guaranteed to be Clothing. Guard anyway just in case.
    if not inventoryItem.getPatchType then return true end
    return not inventoryItem:getPatchType(part)
end

local itemVisuals = ItemVisuals.new()
local coveredParts = ArrayList.new()
-- Returns (uncoveredParts, holedParts, headCoverMultiplier):
--   uncoveredParts: BloodBodyPartType indices with NO clothing covering them
--     at all (bare skin).
--   holedParts: BloodBodyPartType indices where every garment covering that
--     part has an unpatched hole there (sunlight gets through the rip even
--     though something is nominally "worn" over it). A part covered by at
--     least one intact (hole-free or patched) layer is NOT counted here, even
--     if another layer over/under it is torn.
--   headCoverMultiplier: if the head is covered by at least one intact head
--     covering, the lowest headCoveringDamageMultiplier among those items
--     (the most protective one wins); otherwise 0.
local function computeBodyCoverage(player)
    local uncovered = { }
    local hasIntactLayer = { }
    local hasHoledLayer = { }
    local intactHeadMultiplier = nil
    for i = 0, TOTAL_BODY_PARTS - 1 do
        uncovered[i] = true
    end

    player:getItemVisuals(itemVisuals)
    for i = itemVisuals:size() - 1, 0, -1 do
        local itemVisual = itemVisuals:get(i)
        local inventoryItem = itemVisual:getInventoryItem()
        if inventoryItem then
            local bloodClothingTypeList = inventoryItem:getBloodClothingType()
            if bloodClothingTypeList then
                coveredParts:clear()
                BloodClothingType.getCoveredParts(bloodClothingTypeList, coveredParts)
                for a = 0, coveredParts:size() - 1 do
                    local coveredPart = coveredParts:get(a)
                    local partIndex = coveredPart:index()
                    local isHead = partIndex == HEAD_PART_INDEX
                    local countsAsCovering = true
                    if isHead then
                        countsAsCovering = coversHead(inventoryItem)
                    end
                    if countsAsCovering then
                        uncovered[partIndex] = nil
                        if hasUnpatchedHole(itemVisual, inventoryItem, coveredPart) then
                            hasHoledLayer[partIndex] = true
                        else
                            hasIntactLayer[partIndex] = true
                            if isHead then
                                local multiplier = headCoveringDamageMultiplier(inventoryItem)
                                if not intactHeadMultiplier or multiplier < intactHeadMultiplier then
                                    intactHeadMultiplier = multiplier
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local holed = { }
    for i = 0, TOTAL_BODY_PARTS - 1 do
        if not uncovered[i] and hasHoledLayer[i] and not hasIntactLayer[i] then
            holed[i] = true
        end
    end

    -- An intact head layer means the head is neither bare nor holed, so it
    -- isn't already counted at full weight elsewhere.
    local headCoverMultiplier = intactHeadMultiplier or 0

    return uncovered, holed, headCoverMultiplier
end

-- Damage is dealt in ticks of DAMAGE_TICK_MS on the speed-adjusted clock,
-- starting DAMAGE_GRACE_MS after exposure begins. One update can cover
-- several ticks at high game speed, but never more than this many at once, so
-- an unusually long update can't land as a single lethal burst.
local DAMAGE_TICK_MS = 100
local DAMAGE_GRACE_MS = 1000
local MAX_CATCHUP_DAMAGE_TICKS = 5

local MAX_TICKS_TO_LETHAL = 60
local MIN_TICKS_TO_LETHAL = 10
local function sunlightIntensityNorm(sunlight)
    if sunlight <= MIN_DANGEROUS_LIGHT_LEVEL then return 0 end
    return math.min((sunlight - MIN_DANGEROUS_LIGHT_LEVEL) / (255 - MIN_DANGEROUS_LIGHT_LEVEL), 1.0)
end

local function calculateBodyDamageFromSunlight(sunlight)
    local norm = sunlightIntensityNorm(sunlight)
    if norm <= 0 then return 0 end
    local ticksToLethal = MAX_TICKS_TO_LETHAL - norm * (MAX_TICKS_TO_LETHAL - MIN_TICKS_TO_LETHAL)
    return 100.0 / ticksToLethal
end

-- Moonlight gets its own, much slower damage curve rather than just reusing
-- the sunlight one at a smaller input: reflected/moon-phase light is meant
-- to read as a slow-burn atmospheric hazard, never anywhere near daylight's
-- speed even at a full moon. Normalized against MOONLIGHT_MAX_INTENSITY
-- (its own peak) rather than 255, so 1.0 here means "as strong as moonlight
-- ever gets", not "as strong as the sun".
local function moonIntensityNorm(light)
    if MOONLIGHT_MAX_INTENSITY <= MIN_DANGEROUS_LIGHT_LEVEL then return 0 end -- degenerate sandbox config; treat as always-safe
    if light <= MIN_DANGEROUS_LIGHT_LEVEL then return 0 end
    return math.min((light - MIN_DANGEROUS_LIGHT_LEVEL) / (MOONLIGHT_MAX_INTENSITY - MIN_DANGEROUS_LIGHT_LEVEL), 1.0)
end

-- Does something used to be 3000 and 600 which bascically did less damage then naturally healed.
-- now it gets someone standing in the moonglow the entire night (like 5 hours long)
-- to critical health if they have only their head uncovered and probalby kills anyone 
local MOON_MAX_TICKS_TO_LETHAL = 220
local MOON_MIN_TICKS_TO_LETHAL = 200

local function calculateBodyDamageFromMoonlight(light)
    local norm = moonIntensityNorm(light)
    if norm <= 0 then return 0 end
    local ticksToLethal = MOON_MAX_TICKS_TO_LETHAL - norm * (MOON_MAX_TICKS_TO_LETHAL - MOON_MIN_TICKS_TO_LETHAL)
    return 100.0 / ticksToLethal
end

-- Burn wounds only start after this many continuous milliseconds in
-- dangerous light.
-- Tweakable via the "Min Exposure Time For Burns" sandbox option
-- (SandboxVars.SCP.MinExposureMsForBurns).
local MIN_EXPOSURE_MS_FOR_BURNS = 2000
-- Holed-but-covered parts (unpatched rip in worn clothing) need this many
-- times longer continuous exposure before they can burn, since there's still
-- fabric there partially shielding the skin. Tweakable via the "Holed
-- Clothing Exposure Multiplier" sandbox option
-- (SandboxVars.SCP.HoleBurnExposureMultiplier).
local HOLE_BURN_EXPOSURE_MULTIPLIER = 3
-- How often (speed-adjusted ms) each eligible body part gets a chance to
-- burn once its exposure threshold above is met.
local BURN_CHECK_INTERVAL_MS = 800
-- Chance (0-1) that any single eligible, not-already-burned body part burns
-- on a given check, at maximum sunlight intensity. Scales down linearly with
-- weaker sunlight via sunlightIntensityNorm/moonIntensityNorm, but never
-- below MIN_BURN_CHANCE_PER_CHECK as long as there's dangerous exposure at
-- all - the burns are meant to represent partial liquefaction from the
-- anomalous light, so any exposure that's dealing damage should carry a
-- meaningful chance of one. Set this to 0 to disable burns entirely (an
-- explicit off-switch that bypasses the floor below). Tweakable via the
-- "Max Burn Chance Per Check" sandbox option (SandboxVars.SCP.MaxBurnChancePerCheck).
local MAX_BURN_CHANCE_PER_CHECK = 0.15
-- Floor on burnChance above, applied whenever the player is taking any
-- damage at all (sun or moon) and MAX_BURN_CHANCE_PER_CHECK is nonzero -
-- see the comment above.
local MIN_BURN_CHANCE_PER_CHECK = 0.02

local function rollBurnsForParts(bodyDamage, parts, burnChance)
    for bloodPartIndex in pairs(parts) do
        local bodyPartType = bloodPartToBodyPartType[bloodPartIndex]
        if bodyPartType then
            local bodyPart = bodyDamage:getBodyPart(bodyPartType)
            -- Skip parts that are already burned so burns don't keep stacking
            -- on the same spot every check; they'll roll again once healed.
            if bodyPart and bodyPart:getBurnTime() <= 0 and ZombRand(10000) < burnChance * 10000 then
                bodyPart:setBurned()
                bodyPart:setBurnTime(ZombRand(75, 100))
            end
        end
    end
end

local HEAD_ONLY_PARTS = { [HEAD_PART_INDEX] = true }

-- Odds of at least one success across that many independent checks, so a
-- frame covering several checks (high game speed) burns as often as the same
-- stretch of game time spread over several frames would.
local function chanceOverChecks(chancePerCheck, checks)
    return 1 - (1 - chancePerCheck) ^ checks
end

local function tryApplyBurns(player, scpPlayerData, timestampMs)
    local checks = math.floor((timestampMs - scpPlayerData.lastBurnCheckTimestampMs) / BURN_CHECK_INTERVAL_MS)
    if checks <= 0 then return end
    scpPlayerData.lastBurnCheckTimestampMs = scpPlayerData.lastBurnCheckTimestampMs + checks * BURN_CHECK_INTERVAL_MS

    local intensityNorm
    if scpPlayerData.exposureSource == "moon" then
        intensityNorm = moonIntensityNorm(scpPlayerData.currentSquareLight)
    else
        intensityNorm = sunlightIntensityNorm(scpPlayerData.currentSquareLight)
    end
    if intensityNorm <= 0 then return end

    if MAX_BURN_CHANCE_PER_CHECK <= 0 then return end -- explicit off-switch: skip the floor entirely, not just clamp toward it

    local burnChancePerCheck = math.max(intensityNorm * MAX_BURN_CHANCE_PER_CHECK, MIN_BURN_CHANCE_PER_CHECK)

    local exposureMs = timestampMs - scpPlayerData.liquefyingStartTimestampMs
    local bodyDamage = player:getBodyDamage()

    if exposureMs >= MIN_EXPOSURE_MS_FOR_BURNS then
        rollBurnsForParts(bodyDamage, scpPlayerData.uncoveredParts, chanceOverChecks(burnChancePerCheck, checks))
        -- A head behind a head covering with a nonzero multiplier can burn
        -- too, with its chance scaled down by that multiplier.
        if scpPlayerData.headCoverMultiplier > 0 then
            rollBurnsForParts(bodyDamage, HEAD_ONLY_PARTS,
                chanceOverChecks(burnChancePerCheck * scpPlayerData.headCoverMultiplier, checks))
        end
    end
    if exposureMs >= MIN_EXPOSURE_MS_FOR_BURNS * HOLE_BURN_EXPOSURE_MULTIPLIER then
        rollBurnsForParts(bodyDamage, scpPlayerData.holedParts, chanceOverChecks(burnChancePerCheck, checks))
    end
end

-- These must match the "sound X" names defined in
-- media/scripts/scp_sounds.txt - PlaySound() needs a registered sound
-- script, a raw .wav in media/sound/ alone isn't enough. Deliberately named
-- to avoid any chance of colliding with a vanilla sound (e.g. plain
-- "burningFlesh1" happens to already be a vanilla zombie-burning sound name,
-- which is fragile to rely on).
local SUN_LIQUEFY_SOUND_NAME = "SCPBurningFlesh1"
local MOON_LIQUEFY_SOUND_NAME = "SCPQuietLiquefaction1"

local SUN_LIQUEFY_VOLUME = 0.3
local MOON_LIQUEFY_VOLUME = 0.25

-- Played on the player's own emitter and tracked by its instance id, so
-- checking and stopping it only ever touch this sound. (getSoundManager()'s
-- PlaySound hands out a world emitter shared with other sounds, whose
-- isPlaying/stop cover everything playing on it, and PlayAsMusic does nothing
-- at all in B42.20.)
-- Muffled by whatever the head is wearing - quieter behind a mask, silent
-- behind a sealed helmet - but only while the head is the only way in. With
-- any other part bare or holed, the sound stays at full volume.
-- The boost keeps thin coverings from being nearly inaudible. It has to stay
-- clamped: a bare head is already at 1.0, so without the clamp covering the
-- last other body part (gloves, typically) made the sound jump to twice the
-- full volume the branch above returns.
local HEAD_MUFFLE_BOOST = 2.0
local function liquefySoundVolume(scpPlayerData)
    local isMoon = scpPlayerData.exposureSource == "moon"
    local volume = isMoon and MOON_LIQUEFY_VOLUME or SUN_LIQUEFY_VOLUME
    if scpPlayerData.bodyExposedBesidesHead then return volume end
    return volume * math.min(scpPlayerData.headLightExposure * HEAD_MUFFLE_BOOST, 1.0)
end

local function playLiquefySound(player, scpPlayerData)
    local isMoon = scpPlayerData.exposureSource == "moon"
    local emitter = player:getEmitter()
    local soundId = emitter:playSound(isMoon and MOON_LIQUEFY_SOUND_NAME or SUN_LIQUEFY_SOUND_NAME)
    if soundId == 0 then -- sound failed to start
        scpPlayerData.soundId = nil
        return
    end
    emitter:setVolume(soundId, liquefySoundVolume(scpPlayerData))
    scpPlayerData.soundId = soundId
end

-- The intoxication stat is repurposed as a screen-wobble visual effect while
-- liquefying, not literal drunkenness. Moonlight is a much subtler process
-- than direct sunlight, so its wobble is dialed down to a fraction of the
-- normal amplitude rather than maxed out the same way, and a protected head
-- wobbles less than a bare one.
local FULL_LIQUEFY_INTOXICATION_LEVEL = 80.0
local MOON_LIQUEFY_INTOXICATION_SCALE = 0.25
local function liquefyIntoxicationLevel(scpPlayerData)
    local level = FULL_LIQUEFY_INTOXICATION_LEVEL
    if scpPlayerData.exposureSource == "moon" then
        level = level * MOON_LIQUEFY_INTOXICATION_SCALE
    end
    level = level * (scpPlayerData.headLightExposure * 1.5)
    -- Never sober the player up: a head covering dampens the liquefaction
    -- wobble, it doesn't cancel out drink they actually had.
    return math.max(level, scpPlayerData.originalDrunkenness)
end

local function startLiquefy(player, scpPlayerData)
    scpPlayerData.liquefying = true

    local timestampMs = scpPlayerData.clockMs
    scpPlayerData.liquefyingStartTimestampMs = timestampMs
    -- Backdated so the first damage tick lands exactly DAMAGE_GRACE_MS in.
    scpPlayerData.lastDamageDoneTimestampMs = timestampMs + DAMAGE_GRACE_MS - DAMAGE_TICK_MS
    -- Without this, the checks missed since the last exposure would all be
    -- rolled at once and make a burn near certain.
    scpPlayerData.lastBurnCheckTimestampMs = timestampMs

    -- NOTE: Stats.getDrunkenness()/setDrunkenness() no longer exist as of the
    -- Build 42.13.0 CharacterStat rework ("Replaced Drunkenness stat usage
    -- with CharacterStat.INTOXICATION"). Use the generic get/set accessor.
    local drunkenness = player:getStats():get(CharacterStat.INTOXICATION)
    scpPlayerData.originalDrunkenness = drunkenness

    playLiquefySound(player, scpPlayerData)

    player:getStats():set(CharacterStat.INTOXICATION, liquefyIntoxicationLevel(scpPlayerData))
end

local function stopLiquefy(player, scpPlayerData)
    scpPlayerData.liquefying = false

    if scpPlayerData.soundId then
        player:getEmitter():stopSoundLocal(scpPlayerData.soundId)
        scpPlayerData.soundId = nil
    end

    local playerStats = player:getStats()
    if playerStats then
        playerStats:set(CharacterStat.INTOXICATION, scpPlayerData.originalDrunkenness)
    end
end

-- Multiplier on light damage while holding an open umbrella in either hand.
-- Open umbrellas are separate items from the closed (weapon) ones, and are
-- the ones flagged ProtectFromRainWhenEquipped.
local UMBRELLA_DAMAGE_MULTIPLIER = 0.7

local function isHoldingOpenUmbrella(player)
    local primary = player:getPrimaryHandItem()
    if primary and primary:isProtectFromRainWhileEquipped() then return true end
    local secondary = player:getSecondaryHandItem()
    return secondary ~= nil and secondary:isProtectFromRainWhileEquipped()
end

local function liquefy(player, scpPlayerData)
    player:getStats():set(CharacterStat.INTOXICATION, liquefyIntoxicationLevel(scpPlayerData))

    -- The sound doesn't loop; if it's finished but we're still hurting the
    -- player, start it again from the top. While it runs, the volume is kept
    -- in step with the head covering, which can come off mid-exposure.
    if scpPlayerData.soundId then
        local emitter = player:getEmitter()
        if emitter:isPlaying(scpPlayerData.soundId) then
            emitter:setVolume(scpPlayerData.soundId, liquefySoundVolume(scpPlayerData))
        else
            playLiquefySound(player, scpPlayerData)
        end
    end

    local timestampMs = scpPlayerData.clockMs
    -- One update can span several ticks (fast-forward, low frame rate), so
    -- they're all paid out at once - otherwise damage per in-game minute
    -- would quietly drop as the game speeds up. Sleep is the extreme case at
    -- seconds of game time per update, but the first tick wakes the player, so
    -- that's all they're charged for.
    local ticks = math.floor((timestampMs - scpPlayerData.lastDamageDoneTimestampMs) / DAMAGE_TICK_MS)
    if ticks > 0 then
        local maxTicks = player:isAsleep() and 1 or MAX_CATCHUP_DAMAGE_TICKS
        if ticks > maxTicks then
            ticks = maxTicks
            scpPlayerData.lastDamageDoneTimestampMs = timestampMs -- drop the backlog, don't defer it
        else
            scpPlayerData.lastDamageDoneTimestampMs = scpPlayerData.lastDamageDoneTimestampMs + ticks * DAMAGE_TICK_MS
        end

        local rawDamage
        if scpPlayerData.exposureSource == "moon" then
            rawDamage = calculateBodyDamageFromMoonlight(scpPlayerData.currentSquareLight)
        else
            rawDamage = calculateBodyDamageFromSunlight(scpPlayerData.currentSquareLight)
        end
        local damage = rawDamage * scpPlayerData.exposureFraction * GENERAL_DAMAGE_MULTIPLIER * ticks
        if damage > 0 and isHoldingOpenUmbrella(player) then
            damage = damage * UMBRELLA_DAMAGE_MULTIPLIER
        end

        if damage > 0 then
            player:getBodyDamage():ReduceGeneralHealth(damage)

            if player:isAsleep() then
                player:forceAwake()
            end
        end
    end

    tryApplyBurns(player, scpPlayerData, timestampMs)
end

-- Coverage is recomputed immediately when needsClothingReload is set (see
-- OnClothingUpdated and the ISRepairClothing hook further down), and on this
-- speed-adjusted timer as a fallback for changes that fire no event (admin
-- restore, other mods, multiplayer sync arriving after the hook ran).
local CLOTHING_RECHECK_INTERVAL_MS = 2000
-- The light search walks outward square by square, which is by far the most
-- expensive thing here (a large windowless interior in full daylight is the
-- worst case). Moving to another square repeats it immediately; otherwise
-- this timer bounds how stale the answer can get when doors, curtains or the
-- time of day change while the player stands still.
local EXPOSURE_RECHECK_INTERVAL_MS = 90

local function shouldLiquefy(player, scpPlayerData)
    local timestampMs = scpPlayerData.clockMs
    if scpPlayerData.needsClothingReload
        or timestampMs - scpPlayerData.lastClothingCheckTimestampMs >= CLOTHING_RECHECK_INTERVAL_MS then
        scpPlayerData.needsClothingReload = false
        scpPlayerData.lastClothingCheckTimestampMs = timestampMs
        scpPlayerData.uncoveredParts, scpPlayerData.holedParts,
            scpPlayerData.headCoverMultiplier = computeBodyCoverage(player)
        scpPlayerData.exposureFraction = weightedExposureFraction(scpPlayerData)
        scpPlayerData.headLightExposure = headLightExposure(scpPlayerData)
        scpPlayerData.bodyExposedBesidesHead = hasExposureBesidesHead(scpPlayerData)
    end

    -- Fully covered, with no unpatched holes anywhere and a head covering
    -- that fully protects: always immune.
    if scpPlayerData.exposureFraction <= 0 then return false end

    local currentSquare = player:getCurrentSquare()
    if currentSquare ~= scpPlayerData.lastExposureSquare
        or timestampMs - scpPlayerData.lastExposureCheckTimestampMs >= EXPOSURE_RECHECK_INTERVAL_MS then
        scpPlayerData.lastExposureSquare = currentSquare
        scpPlayerData.lastExposureCheckTimestampMs = timestampMs
        scpPlayerData.isExposed = isSunlit(player, scpPlayerData) or isMoonlit(player, scpPlayerData)
    end

    return scpPlayerData.isExposed
end

local scpDataPerPlayer = {}

-- Stops everything and drops the player's state. Their data is rebuilt from
-- scratch on the next update, so this must only run once they're out of the
-- picture - otherwise it would count as a fresh exposure and restart the
-- sound from the top.
local function cleanUpPlayer(player)
    local scpPlayerData = scpDataPerPlayer[player]
    if not scpPlayerData then return end
    if scpPlayerData.liquefying then
        stopLiquefy(player, scpPlayerData)
    end
    scpDataPerPlayer[player] = nil
end
Events.OnPlayerDeath.Add(cleanUpPlayer)

-- ===== Low-health vignette (screen effect only, no gameplay impact) =====
-- A full-screen red vignette that fades in while the player is currently
-- being damaged by the anomalous light (scpPlayerData.liquefying) and fades
-- back out when they leave it, scaling in intensity with how close to death
-- they are (BodyDamage:getOverallBodyHealth(), 100 = full health, 0 = dead).
-- Drawn via Events.OnPreUIDraw + the static UIManager.DrawTexture call
-- (rather than as its own ISUIElement panel added to the UI tree), since
-- OnPreUIDraw fires before the HUD/buttons render each frame - that's what
-- keeps this underneath the rest of the player's UI without needing to fight
-- over z-order with it.
--
-- Deliberately timed off real wall-clock ms (getTimestampMs()), NOT the
-- speed-adjusted scpPlayerData.clockMs used for damage/burns elsewhere in
-- this file: the fade is a cosmetic screen transition, not a simulated
-- hazard, so it should always take about one real second regardless of the
-- game's current speed multiplier, the same way any other UI fade would.
local VIGNETTE_FADE_MS = 1000
-- Opacity (0-1) at the peak: fully faded in AND at 0 health. Tweakable via
-- the "Vignette Max Opacity" sandbox option (SandboxVars.SCP.VignetteMaxAlpha).
local VIGNETTE_MAX_ALPHA = 0.85
-- Master on/off switch. Tweakable via the "Enable Death Vignette" sandbox
-- option (SandboxVars.SCP.VignetteEnabled).
local VIGNETTE_ENABLED = true

local VIGNETTE_TEXTURE_PATH = "media/textures/SCPVignette.png"
local vignetteTexture
local function getVignetteTexture()
    if not vignetteTexture then
        vignetteTexture = getTexture(VIGNETTE_TEXTURE_PATH)
    end
    return vignetteTexture
end

-- Ramps scpPlayerData.vignetteFade linearly toward 1 (currently liquefying)
-- or 0 (not) at a rate of 1/VIGNETTE_FADE_MS per real ms, so a full fade
-- transition takes VIGNETTE_FADE_MS regardless of how choppy the frame rate
-- is. Called once per player per OnPlayerUpdate.
local function updateVignetteFade(scpPlayerData, nowRealMs)
    local realDeltaMs = nowRealMs - scpPlayerData.lastRealTimestampMs
    scpPlayerData.lastRealTimestampMs = nowRealMs
    -- Clamp against lag spikes/loading pauses producing one giant delta that
    -- would otherwise snap the fade instantly instead of animating it.
    realDeltaMs = math.max(0, math.min(realDeltaMs, 250))

    local target = scpPlayerData.liquefying and 1.0 or 0.0
    local step = realDeltaMs / VIGNETTE_FADE_MS
    if scpPlayerData.vignetteFade < target then
        scpPlayerData.vignetteFade = math.min(target, scpPlayerData.vignetteFade + step)
    elseif scpPlayerData.vignetteFade > target then
        scpPlayerData.vignetteFade = math.max(target, scpPlayerData.vignetteFade - step)
    end
end

local function drawDeathVignette()
    if not VIGNETTE_ENABLED then return end
    local texture = getVignetteTexture()
    if not texture then return end

    for i = 1, getNumActivePlayers() do
        local player = getSpecificPlayer(i - 1)
        if player and player:isAlive() then
            local scpPlayerData = scpDataPerPlayer[player]
            if scpPlayerData and scpPlayerData.vignetteFade > 0 then
                local overallHealth = player:getBodyDamage():getOverallBodyHealth()
                local deathCloseness = 1.0 - math.max(0, math.min(overallHealth, 100)) / 100.0
                local alpha = scpPlayerData.vignetteFade * deathCloseness * VIGNETTE_MAX_ALPHA
                if alpha > 0.001 then
                    -- Per-player viewport (not just the full window) so this
                    -- behaves correctly in split-screen too.
                    local playerNum = player:getPlayerNum()
                    local x = IsoCamera.getScreenLeft(playerNum)
                    local y = IsoCamera.getScreenTop(playerNum)
                    local w = IsoCamera.getScreenWidth(playerNum)
                    local h = IsoCamera.getScreenHeight(playerNum)
                    UIManager.DrawTexture(texture, x, y, w, h, alpha)
                end
            end
        end
    end
end
Events.OnPreUIDraw.Add(drawDeathVignette)

local function OnPlayerUpdate(player)
    -- A dead player standing in the same dangerous light would otherwise keep
    -- satisfying shouldLiquefy() on every update and liquefy the corpse.
    if not player:isAlive() then
        cleanUpPlayer(player)
        return
    end

    local scpPlayerData = scpDataPerPlayer[player]
    if not scpPlayerData then
        scpPlayerData = {}
        scpPlayerData.uncoveredParts = {}
        scpPlayerData.holedParts = {}
        scpPlayerData.headCoverMultiplier = 0
        scpPlayerData.exposureFraction = 0
        scpPlayerData.headLightExposure = 0
        scpPlayerData.bodyExposedBesidesHead = false
        scpPlayerData.needsClothingReload = true
        scpPlayerData.lastClothingCheckTimestampMs = 0
        scpPlayerData.isExposed = false
        scpPlayerData.lastExposureSquare = nil
        scpPlayerData.lastExposureCheckTimestampMs = 0
        scpPlayerData.liquefying = false
        scpPlayerData.liquefyingStartTimestampMs = 0
        scpPlayerData.lastBurnCheckTimestampMs = 0
        scpPlayerData.originalDrunkenness = 0.0
        scpPlayerData.currentSquareLight = 0
        scpPlayerData.exposureSource = "sun"
        scpPlayerData.lastDamageDoneTimestampMs = 0
        scpPlayerData.soundId = nil
        scpPlayerData.clockMs = 0
        scpPlayerData.vignetteFade = 0
        scpPlayerData.lastRealTimestampMs = getTimestampMs()
        scpDataPerPlayer[player] = scpPlayerData
    end

    scpPlayerData.clockMs = scpPlayerData.clockMs + speedAdjustedDeltaMs()

    if shouldLiquefy(player, scpPlayerData) then
        if scpPlayerData.liquefying then
            liquefy(player, scpPlayerData)
        else
            startLiquefy(player, scpPlayerData)
        end
    elseif scpPlayerData.liquefying then
        stopLiquefy(player, scpPlayerData)
    end

    updateVignetteFade(scpPlayerData, getTimestampMs())
end
Events.OnPlayerUpdate.Add(OnPlayerUpdate)

local function OnClothingUpdated(player)
    local scpPlayerData = scpDataPerPlayer[player]
    if not scpPlayerData then return end
    scpPlayerData.needsClothingReload = true
end
Events.OnClothingUpdated.Add(OnClothingUpdated)

-- Vanilla fires OnClothingUpdated for new holes (IsoGameCharacter.addHole),
-- patch removal (ISRemovePatch) and bandage patches (addBasicPatch), but
-- sewing a patch on via ISRepairClothing doesn't, so it's hooked here.
-- complete() is where the patch is applied in singleplayer; perform() is the
-- part that still runs on the client in multiplayer.
local originalRepairClothingComplete = ISRepairClothing.complete
function ISRepairClothing:complete()
    local result = originalRepairClothingComplete(self)
    OnClothingUpdated(self.character)
    return result
end

local originalRepairClothingPerform = ISRepairClothing.perform
function ISRepairClothing:perform()
    originalRepairClothingPerform(self)
    OnClothingUpdated(self.character)
end

-- Pulls this mod's tweakable values from its sandbox options (defined in
-- media/sandbox-options.txt) into the local variables declared above,
-- falling back to keep whatever default is already set if the sandbox
-- table - or an individual option in it - isn't populated for some reason.

local function loadSandboxOptions()
    local scpOptions = SandboxVars.SCP
    if not scpOptions then return end

    HEAD_DAMAGE_MULTIPLIER = scpOptions.HeadDamageMultiplier or HEAD_DAMAGE_MULTIPLIER
    GENERAL_DAMAGE_MULTIPLIER = scpOptions.GeneralDamageMultiplier or GENERAL_DAMAGE_MULTIPLIER
    MIN_EXPOSURE_MS_FOR_BURNS = scpOptions.MinExposureMsForBurns or MIN_EXPOSURE_MS_FOR_BURNS
    HOLE_BURN_EXPOSURE_MULTIPLIER = scpOptions.HoleBurnExposureMultiplier or HOLE_BURN_EXPOSURE_MULTIPLIER
    MAX_BURN_CHANCE_PER_CHECK = scpOptions.MaxBurnChancePerCheck or MAX_BURN_CHANCE_PER_CHECK
    MOONLIGHT_MAX_INTENSITY = scpOptions.MoonlightMaxIntensity or MOONLIGHT_MAX_INTENSITY
    if scpOptions.MoonlightDamageEnabled ~= nil then
        MOONLIGHT_DAMAGE_ENABLED = scpOptions.MoonlightDamageEnabled
    end
    VIGNETTE_MAX_ALPHA = scpOptions.VignetteMaxAlpha or VIGNETTE_MAX_ALPHA
    if scpOptions.VignetteEnabled ~= nil then
        VIGNETTE_ENABLED = scpOptions.VignetteEnabled
    end

    -- HEAD_DAMAGE_MULTIPLIER may have just changed, so the weight total it
    -- feeds into needs to be recalculated to match.
    TOTAL_DAMAGE_WEIGHT = (TOTAL_BODY_PARTS - 1) + HEAD_DAMAGE_MULTIPLIER
end

-- Red tinge on natural light, as the four colour values ClimateManager takes
-- per weather type (warm, normal, cloudy) for each season, in the order
-- summer, fall, winter, spring. Dawn and dusk deliberately share one table.
local DAWN_DUSK_SKY_COLORS = {
    { {0.14,0.10,0.90,0.82}, {0.16,0.11,0.85,0.80}, {0.18,0.13,0.80,0.77} },
    { {0.14,0.10,0.88,0.81}, {0.16,0.11,0.83,0.79}, {0.18,0.13,0.78,0.77} },
    { {0.15,0.10,0.86,0.79}, {0.17,0.12,0.81,0.77}, {0.19,0.14,0.76,0.76} },
    { {0.14,0.10,0.89,0.81}, {0.16,0.11,0.84,0.79}, {0.18,0.13,0.79,0.77} },
}
local DAY_SKY_COLORS = {
    { {0.00,0.00,1.00,0.85}, {0.05,0.05,0.95,0.83}, {0.08,0.08,0.92,0.81} },
    { {0.00,0.00,1.00,0.85}, {0.05,0.05,0.95,0.83}, {0.08,0.07,0.90,0.81} },
    { {0.00,0.00,1.00,0.85}, {0.06,0.06,0.94,0.82}, {0.10,0.10,0.90,0.80} },
    { {0.00,0.00,1.00,0.85}, {0.05,0.05,0.96,0.83}, {0.09,0.08,0.93,0.81} },
}

local function applySkyTint()
    local climateManager = getClimateManager()
    for season = 0, 3 do
        for weather = 0, 2 do
            local dawnDusk = DAWN_DUSK_SKY_COLORS[season + 1][weather + 1]
            local day = DAY_SKY_COLORS[season + 1][weather + 1]
            climateManager:setSeasonColorDawn(weather, season, dawnDusk[1], dawnDusk[2], dawnDusk[3], dawnDusk[4], true)
            climateManager:setSeasonColorDusk(weather, season, dawnDusk[1], dawnDusk[2], dawnDusk[3], dawnDusk[4], true)
            climateManager:setSeasonColorDay(weather, season, day[1], day[2], day[3], day[4], true)
        end
    end
end

local function OnInitWorld()
    loadSandboxOptions()
    loadHeadCoveringMultipliers()
    applySkyTint()
end
Events.OnInitWorld.Add(OnInitWorld)

local function OnTick()
    for i = 1, getNumActivePlayers() do
        local player = getSpecificPlayer(i - 1)
        if player then
            local scpPlayerData = scpDataPerPlayer[player]
            if scpPlayerData and scpPlayerData.liquefying then
                local playerStats = player:getStats()
                if playerStats then
                    playerStats:set(CharacterStat.INTOXICATION, scpPlayerData.originalDrunkenness)
                end
                local moodles = player:getMoodles()
                if moodles then
                    moodles:Update()
                end
            end
        end
    end
end
Events.OnTick.Add(OnTick)