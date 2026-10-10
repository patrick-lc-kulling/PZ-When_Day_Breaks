-- The light model behind the liquefying sun: how much light reaches a square,
-- how much of a body is bare to it and how fast it kills. Shared by the
-- player mechanic (Main.lua) and the Project A-Life NPC compatibility
-- (SCP001/ALife). It touches no client-only classes, so it also loads on a
-- dedicated server, where A-Life spawns and moves its off-screen squads.
SCP001 = SCP001 or {}
local Sunlight = {}
SCP001.Sunlight = Sunlight

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
Sunlight.MIN_DANGEROUS_LIGHT_LEVEL = MIN_DANGEROUS_LIGHT_LEVEL
Sunlight.LIGHT_FALLOFF_PER_TILE = LIGHT_FALLOFF_PER_TILE
-- The brightest the sun gets on the same 0-255 scale. A square with no
-- dangerous light at this level stays safe all day.
Sunlight.PEAK_LIGHT_LEVEL = 255

-- dx/dy never change, so they're resolved once instead of per neighbour.
local function cardinal(direction)
    return { direction = direction, dx = direction:dx(), dy = direction:dy() }
end
local cardinalDirections = {
    cardinal(IsoDirections.N), cardinal(IsoDirections.W),
    cardinal(IsoDirections.S), cardinal(IsoDirections.E),
}
Sunlight.cardinalDirections = cardinalDirections

-- LosUtil isn't exposed to Lua, so the Blocked instance is taken from a call
-- guaranteed to return it (offsets beyond one tile are rejected).
function Sunlight.blockedResult(square)
    if not TestResultsBlockedInstance then
        TestResultsBlockedInstance = square:testVisionAdjacent(-2, 0, 0, true, false)
    end
    return TestResultsBlockedInstance
end

-- How many squares (counting the start) light can travel through before it
-- falls to MIN_DANGEROUS_LIGHT_LEVEL, minus one: the furthest ring of squares
-- whose light would still be above the threshold.
function Sunlight.maxDangerousDistance(baseLight)
    return math.ceil((baseLight - MIN_DANGEROUS_LIGHT_LEVEL) / LIGHT_FALLOFF_PER_TILE) - 1
end

-- Traces outward from startSquare looking for line-of-sight to open sky, the
-- same way regardless of whether the light being measured comes from the sun
-- or the moon. baseLight is the 0-255 light level at an actual open-air
-- square right now; this returns what that same light level would be by the
-- time it reaches startSquare (falling off LIGHT_FALLOFF_PER_TILE per tile
-- through windows/doorways), or nil if no light above
-- MIN_DANGEROUS_LIGHT_LEVEL reaches it at all. Anything at or below that
-- threshold deals no damage, so it must not count as exposure - that would
-- start the sound, wobble and vignette over nothing.
function Sunlight.findExposureLightLevel(startSquare, baseLight)
    if baseLight <= MIN_DANGEROUS_LIGHT_LEVEL then return nil end
    if not startSquare then return nil end

    local blocked = Sunlight.blockedResult(startSquare)

    -- Furthest ring of squares whose light would still be above the threshold.
    local maxDistFromStart = Sunlight.maxDangerousDistance(baseLight)

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
                if result ~= blocked then
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

-- getDayLightStrength() is a real, trait-blind environmental value, and the
-- one gate everything in this mod uses for whether the sun is up at all.
function Sunlight.isSunUp()
    return getClimateManager():getDayLightStrength() > 0
end

-- IMPORTANT: getSkyLightLevel() is the *rendered* ambient light color, which
-- is per-player and gets artificially floored by the Cat's Eyes (NightVision)
-- trait and the "Bright Nights" sandbox option (see
-- RenderSettings.PlayerRenderSettings.updateRenderSettings client-side) - so
-- it reads as "bright" at night for anyone with either of those, even though
-- there is no actual sunlight. That's why it's only ever read behind
-- isSunUp(); moonlight (below) comes from an entirely separate, trait-blind
-- source.
-- A dedicated server renders nothing, so there the climate's own ambient
-- level, which the rendered value starts from, stands in for it.
function Sunlight.skyBaseLight()
    if isServer() then
        local ambient = getClimateManager():getAmbient()
        return math.max(0, math.min(ambient, 1)) * 255
    end
    local skyLightLevel = getGameTime():getSkyLightLevel()
    return math.max(
        GetRLightLevel(skyLightLevel), GetGLightLevel(skyLightLevel), GetBLightLevel(skyLightLevel)
    )
end

-- The sunlight reaching square right now, or nil if none of it is dangerous.
function Sunlight.sunLightAt(square)
    if not Sunlight.isSunUp() then return nil end -- night: no real sunlight regardless of rendered light level
    return Sunlight.findExposureLightLevel(square, Sunlight.skyBaseLight())
end

-- How bright moonlight gets at its absolute strongest (full moon, clear sky,
-- standing right under open air), on the same 0-255 scale as sunlight above.
-- Falls off with distance from an opening exactly like sunlight, and gets
-- dimmed by cloud cover. Deliberately weak by default (below
-- MIN_DANGEROUS_LIGHT_LEVEL outside of a full moon) so moonlight damage is a
-- rare, atmospheric event rather than a nightly occurrence. Tweakable via the
-- "Moonlight Max Intensity" sandbox option (SandboxVars.SCP.MoonlightMaxIntensity).
Sunlight.MOONLIGHT_MAX_INTENSITY = 100
-- Master on/off switch for the moonlight damage mechanic, independent of the
-- intensity slider above. Tweakable via the "Enable Moonlight Damage"
-- sandbox option (SandboxVars.SCP.MoonlightDamageEnabled).
Sunlight.MOONLIGHT_DAMAGE_ENABLED = true

-- The moonlight reaching square right now, or nil if none of it is dangerous.
-- Deliberately independent of getSkyLightLevel() (see skyBaseLight above):
-- ClimateMoon's phase and ClimateManager's cloud intensity are both real,
-- server-driven environmental values with no per-player rendering component,
-- so this can't be inflated by Cat's Eyes/Bright Nights.
function Sunlight.moonLightAt(square)
    if not Sunlight.MOONLIGHT_DAMAGE_ENABLED then return nil end
    if Sunlight.isSunUp() then return nil end -- daytime; sunLightAt handles it

    local moonFloat = ClimateMoon.getInstance():getMoonFloat() -- 0 (new moon) .. 1 (full moon)
    if moonFloat <= 0 then return nil end

    local cloudDampening = 1.0 - getClimateManager():getCloudIntensity()
    local baseLight = Sunlight.MOONLIGHT_MAX_INTENSITY * moonFloat * cloudDampening

    return Sunlight.findExposureLightLevel(square, baseLight)
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

-- item is either an InventoryItem or a script Item; both have getBodyLocation().
local function headCoveringLocationDefault(item)
    return headCoveringLocationDefaults[string.lower(tostring(item:getBodyLocation()))]
end

local function coversHead(item)
    return headCoveringLocationDefault(item) ~= nil
end

-- Per-item head damage multipliers (0-1) for items that pass
-- coversHead(), keyed by full item type (e.g. "Base.Hat_RiotHelmet"),
-- split into one file per group of body locations (full-head coverings,
-- MASK, MASK_EYES) but merged into one lookup table.
-- 0 = the item fully shields the head, 1 = the head takes damage as if bare.
-- Any head covering not listed (including modded ones) falls back to its
-- body location's default in headCoveringLocationDefaults.
-- getModFileReader checks the mod's version folder first, then common/.
local MOD_ID = "Daybreak_SCP_001"
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

-- A script Item is named by getFullName(), an InventoryItem by getFullType();
-- both give "Module.Type".
local function headCoveringDamageMultiplier(item, isScript)
    local fullType = isScript and item:getFullName() or item:getFullType()
    return headCoveringMultipliers[fullType]
        or headCoveringLocationDefault(item) or 0
end

local TOTAL_BODY_PARTS = BloodBodyPartType.MAX:index()

-- The head burns/damages faster than other body parts once exposed - applied
-- as a weight on top of the normal 1-per-part contribution to the damage
-- fraction below, whether the head is bare or just showing through a hole.
-- Tweakable in-game via the "Head Damage Multiplier" sandbox option
-- (SandboxVars.SCP.HeadDamageMultiplier) - see loadSandboxOptions() below.
Sunlight.HEAD_DAMAGE_MULTIPLIER = 3
-- Multiplies the final health damage dealt from sunlight exposure, across all
-- body parts. Tweakable via the "General Damage Multiplier" sandbox option
-- (SandboxVars.SCP.GeneralDamageMultiplier).
Sunlight.GENERAL_DAMAGE_MULTIPLIER = 1
local HEAD_PART_INDEX = BloodBodyPartType.Head:index()
Sunlight.HEAD_PART_INDEX = HEAD_PART_INDEX

local function totalDamageWeight()
    return (TOTAL_BODY_PARTS - 1) + Sunlight.HEAD_DAMAGE_MULTIPLIER
end

local function partDamageWeight(partIndex)
    if partIndex == HEAD_PART_INDEX then return Sunlight.HEAD_DAMAGE_MULTIPLIER end
    return 1
end

-- Weighted equivalent of (uncovered + holed part count) / TOTAL_BODY_PARTS:
-- same 0-1 range (0 = fully covered, 1 = fully exposed), but an exposed head
-- pulls the fraction toward 1 harder than any other single part would.
-- A head covered only by intact head coverings still counts partially,
-- scaled by headCoverMultiplier (0 while it's bare or holed, since it's
-- already counted in full above).
-- coverage is any table holding the three results of computeBodyCoverage as
-- uncoveredParts, holedParts and headCoverMultiplier.
function Sunlight.weightedExposureFraction(coverage)
    local sum = 0
    for partIndex in pairs(coverage.uncoveredParts) do
        sum = sum + partDamageWeight(partIndex)
    end
    for partIndex in pairs(coverage.holedParts) do
        sum = sum + partDamageWeight(partIndex)
    end
    sum = sum + Sunlight.HEAD_DAMAGE_MULTIPLIER * coverage.headCoverMultiplier
    return sum / totalDamageWeight()
end

-- How much of the light reaches the head specifically (0-1): all of it while
-- the head is bare or showing through a hole, otherwise however much the head
-- covering lets through - 0 behind a sealed helmet, more behind a thin mask.
-- The player's liquefaction sound and screen wobble both scale with this,
-- since they're what the player's own head is going through.
function Sunlight.headLightExposure(coverage)
    if coverage.uncoveredParts[HEAD_PART_INDEX] or coverage.holedParts[HEAD_PART_INDEX] then
        return 1.0
    end
    return coverage.headCoverMultiplier
end

-- Whether anything below the neck is bare or holed. The head covering only
-- muffles the player's liquefaction sound while it isn't - any other exposed
-- part is liquefying at full tilt no matter what's on the head.
function Sunlight.hasExposureBesidesHead(coverage)
    for partIndex in pairs(coverage.uncoveredParts) do
        if partIndex ~= HEAD_PART_INDEX then return true end
    end
    for partIndex in pairs(coverage.holedParts) do
        if partIndex ~= HEAD_PART_INDEX then return true end
    end
    return false
end

-- A worn item's patches live on the item itself, but a script Item has no
-- state, so for those the visual's own patch values are read instead.
local function hasUnpatchedHole(itemVisual, item, isScript, part)
    if itemVisual:getHole(part) <= 0 then return false end
    if isScript then
        return itemVisual:getBasicPatch(part) <= 0 and itemVisual:getDenimPatch(part) <= 0
            and itemVisual:getLeatherPatch(part) <= 0
    end
    -- getPatchType only exists on Clothing (not the base InventoryItem), but
    -- every item that reaches here already passed getBloodClothingType(), so
    -- it's effectively guaranteed to be Clothing. Guard anyway just in case.
    if not item.getPatchType then return true end
    return not item:getPatchType(part)
end

local itemVisuals = ItemVisuals.new()
local coveredParts = ArrayList.new()
-- Returns (uncoveredParts, holedParts, headCoverMultiplier) for any character
-- wearing ItemVisuals - the player, or an NPC's zombie shell:
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
-- Each visual is read through its real item when it has one. A multiplayer
-- client rebuilds other characters' outfits from item scripts, so for those
-- the visual only knows its script Item.
function Sunlight.computeBodyCoverage(character)
    local uncovered = { }
    local hasIntactLayer = { }
    local hasHoledLayer = { }
    local intactHeadMultiplier = nil
    for i = 0, TOTAL_BODY_PARTS - 1 do
        uncovered[i] = true
    end

    character:getItemVisuals(itemVisuals)
    for i = itemVisuals:size() - 1, 0, -1 do
        local itemVisual = itemVisuals:get(i)
        local item = itemVisual:getInventoryItem()
        local isScript = false
        if not item then
            item = itemVisual:getScriptItem()
            isScript = true
        end
        if item then
            local bloodClothingTypeList = item:getBloodClothingType()
            if bloodClothingTypeList then
                coveredParts:clear()
                BloodClothingType.getCoveredParts(bloodClothingTypeList, coveredParts)
                for a = 0, coveredParts:size() - 1 do
                    local coveredPart = coveredParts:get(a)
                    local partIndex = coveredPart:index()
                    local isHead = partIndex == HEAD_PART_INDEX
                    local countsAsCovering = true
                    if isHead then
                        countsAsCovering = coversHead(item)
                    end
                    if countsAsCovering then
                        uncovered[partIndex] = nil
                        if hasUnpatchedHole(itemVisual, item, isScript, coveredPart) then
                            hasHoledLayer[partIndex] = true
                        else
                            hasIntactLayer[partIndex] = true
                            if isHead then
                                local multiplier = headCoveringDamageMultiplier(item, isScript)
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
Sunlight.DAMAGE_TICK_MS = 100
Sunlight.DAMAGE_GRACE_MS = 1000
Sunlight.MAX_CATCHUP_DAMAGE_TICKS = 5

-- The damage functions below return health lost per tick on a 0-100 scale:
-- the player's general health, or a percentage of an NPC's maximum.
local MAX_TICKS_TO_LETHAL = 60
local MIN_TICKS_TO_LETHAL = 10
function Sunlight.sunlightIntensityNorm(sunlight)
    if sunlight <= MIN_DANGEROUS_LIGHT_LEVEL then return 0 end
    return math.min((sunlight - MIN_DANGEROUS_LIGHT_LEVEL) / (255 - MIN_DANGEROUS_LIGHT_LEVEL), 1.0)
end

function Sunlight.calculateBodyDamageFromSunlight(sunlight)
    local norm = Sunlight.sunlightIntensityNorm(sunlight)
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
function Sunlight.moonIntensityNorm(light)
    if Sunlight.MOONLIGHT_MAX_INTENSITY <= MIN_DANGEROUS_LIGHT_LEVEL then return 0 end -- degenerate sandbox config; treat as always-safe
    if light <= MIN_DANGEROUS_LIGHT_LEVEL then return 0 end
    return math.min((light - MIN_DANGEROUS_LIGHT_LEVEL) / (Sunlight.MOONLIGHT_MAX_INTENSITY - MIN_DANGEROUS_LIGHT_LEVEL), 1.0)
end

-- Does something used to be 3000 and 600 which bascically did less damage then naturally healed.
-- now it gets someone standing in the moonglow the entire night (like 5 hours long)
-- to critical health if they have only their head uncovered and probalby kills anyone
local MOON_MAX_TICKS_TO_LETHAL = 220
local MOON_MIN_TICKS_TO_LETHAL = 200

function Sunlight.calculateBodyDamageFromMoonlight(light)
    local norm = Sunlight.moonIntensityNorm(light)
    if norm <= 0 then return 0 end
    local ticksToLethal = MOON_MAX_TICKS_TO_LETHAL - norm * (MOON_MAX_TICKS_TO_LETHAL - MOON_MIN_TICKS_TO_LETHAL)
    return 100.0 / ticksToLethal
end

-- Burn wounds only start after this many continuous milliseconds in
-- dangerous light.
-- Tweakable via the "Min Exposure Time For Burns" sandbox option
-- (SandboxVars.SCP.MinExposureMsForBurns).
Sunlight.MIN_EXPOSURE_MS_FOR_BURNS = 2000
-- Holed-but-covered parts (unpatched rip in worn clothing) need this many
-- times longer continuous exposure before they can burn, since there's still
-- fabric there partially shielding the skin. Tweakable via the "Holed
-- Clothing Exposure Multiplier" sandbox option
-- (SandboxVars.SCP.HoleBurnExposureMultiplier).
Sunlight.HOLE_BURN_EXPOSURE_MULTIPLIER = 3
-- How often (speed-adjusted ms) each eligible body part gets a chance to
-- burn once its exposure threshold above is met.
Sunlight.BURN_CHECK_INTERVAL_MS = 800
-- Chance (0-1) that any single eligible, not-already-burned body part burns
-- on a given check, at maximum sunlight intensity. Scales down linearly with
-- weaker sunlight via sunlightIntensityNorm/moonIntensityNorm, but never
-- below MIN_BURN_CHANCE_PER_CHECK as long as there's dangerous exposure at
-- all - the burns are meant to represent partial liquefaction from the
-- anomalous light, so any exposure that's dealing damage should carry a
-- meaningful chance of one. Set this to 0 to disable burns entirely (an
-- explicit off-switch that bypasses the floor below). Tweakable via the
-- "Max Burn Chance Per Check" sandbox option (SandboxVars.SCP.MaxBurnChancePerCheck).
Sunlight.MAX_BURN_CHANCE_PER_CHECK = 0.15
-- Floor on burnChance above, applied whenever there's any damage at all
-- (sun or moon) and MAX_BURN_CHANCE_PER_CHECK is nonzero - see the comment
-- above.
Sunlight.MIN_BURN_CHANCE_PER_CHECK = 0.02

-- The chance of a burn per check for light of this intensity, or 0 when the
-- light deals no damage or burns are switched off.
function Sunlight.burnChancePerCheck(intensityNorm)
    if intensityNorm <= 0 then return 0 end
    if Sunlight.MAX_BURN_CHANCE_PER_CHECK <= 0 then return 0 end -- explicit off-switch: skip the floor entirely, not just clamp toward it
    return math.max(intensityNorm * Sunlight.MAX_BURN_CHANCE_PER_CHECK, Sunlight.MIN_BURN_CHANCE_PER_CHECK)
end

-- Odds of at least one success across that many independent checks, so a
-- frame covering several checks (high game speed) burns as often as the same
-- stretch of game time spread over several frames would.
function Sunlight.chanceOverChecks(chancePerCheck, checks)
    return 1 - (1 - chancePerCheck) ^ checks
end

-- Multiplier on light damage while holding an open umbrella in either hand.
-- Open umbrellas are separate items from the closed (weapon) ones, and are
-- the ones flagged ProtectFromRainWhenEquipped.
Sunlight.UMBRELLA_DAMAGE_MULTIPLIER = 0.7

function Sunlight.isHoldingOpenUmbrella(character)
    local primary = character:getPrimaryHandItem()
    if primary and primary:isProtectFromRainWhileEquipped() then return true end
    local secondary = character:getSecondaryHandItem()
    return secondary ~= nil and secondary:isProtectFromRainWhileEquipped()
end

-- Pulls the shared tweakable values from the mod's sandbox options (defined
-- in media/sandbox-options.txt), keeping whatever default is already set if
-- the sandbox table - or an individual option in it - isn't populated.
function Sunlight.loadSandboxOptions()
    local scpOptions = SandboxVars.SCP
    if not scpOptions then return end

    Sunlight.HEAD_DAMAGE_MULTIPLIER = scpOptions.HeadDamageMultiplier or Sunlight.HEAD_DAMAGE_MULTIPLIER
    Sunlight.GENERAL_DAMAGE_MULTIPLIER = scpOptions.GeneralDamageMultiplier or Sunlight.GENERAL_DAMAGE_MULTIPLIER
    Sunlight.MIN_EXPOSURE_MS_FOR_BURNS = scpOptions.MinExposureMsForBurns or Sunlight.MIN_EXPOSURE_MS_FOR_BURNS
    Sunlight.HOLE_BURN_EXPOSURE_MULTIPLIER = scpOptions.HoleBurnExposureMultiplier or Sunlight.HOLE_BURN_EXPOSURE_MULTIPLIER
    Sunlight.MAX_BURN_CHANCE_PER_CHECK = scpOptions.MaxBurnChancePerCheck or Sunlight.MAX_BURN_CHANCE_PER_CHECK
    Sunlight.MOONLIGHT_MAX_INTENSITY = scpOptions.MoonlightMaxIntensity or Sunlight.MOONLIGHT_MAX_INTENSITY
    if scpOptions.MoonlightDamageEnabled ~= nil then
        Sunlight.MOONLIGHT_DAMAGE_ENABLED = scpOptions.MoonlightDamageEnabled
    end
end

-- Loads the sandbox values and head-covering multipliers. Main.lua calls it
-- on OnInitWorld; the A-Life compatibility calls it as well, since Main.lua
-- can't be relied on to load on a dedicated server.
function Sunlight.init()
    Sunlight.loadSandboxOptions()
    loadHeadCoveringMultipliers()
    Sunlight.initialized = true
end

return Sunlight
