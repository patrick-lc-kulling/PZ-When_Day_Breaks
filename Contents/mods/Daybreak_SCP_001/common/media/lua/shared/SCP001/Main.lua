require "TimedActions/ISRepairClothing"
require "SCP001/Sunlight"

-- The light model itself (exposure, clothing coverage, damage curves and
-- their sandbox values) lives in Sunlight.lua, shared with the Project A-Life
-- NPC compatibility. This file is the player's side of it.
local Sunlight = SCP001.Sunlight

local gameTime
Events.OnGameTimeLoaded.Add(function()
    gameTime = GameTime.getInstance()
end)

local function speedAdjustedDeltaMs()
    if not gameTime then return 0 end
    return gameTime:getMultipliedSecondsSinceLastUpdate() * 1000
end

local function isSunlit(player, scpPlayerData)
    local lightAtPlayer = Sunlight.sunLightAt(player:getCurrentSquare())
    if not lightAtPlayer then return false end

    scpPlayerData.currentSquareLight = lightAtPlayer
    scpPlayerData.exposureSource = "sun"
    return true
end

local function isMoonlit(player, scpPlayerData)
    local lightAtPlayer = Sunlight.moonLightAt(player:getCurrentSquare())
    if not lightAtPlayer then return false end

    scpPlayerData.currentSquareLight = lightAtPlayer
    scpPlayerData.exposureSource = "moon"
    return true
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

local HEAD_ONLY_PARTS = { [Sunlight.HEAD_PART_INDEX] = true }

local function tryApplyBurns(player, scpPlayerData, timestampMs)
    local checks = math.floor((timestampMs - scpPlayerData.lastBurnCheckTimestampMs) / Sunlight.BURN_CHECK_INTERVAL_MS)
    if checks <= 0 then return end
    scpPlayerData.lastBurnCheckTimestampMs = scpPlayerData.lastBurnCheckTimestampMs + checks * Sunlight.BURN_CHECK_INTERVAL_MS

    local intensityNorm
    if scpPlayerData.exposureSource == "moon" then
        intensityNorm = Sunlight.moonIntensityNorm(scpPlayerData.currentSquareLight)
    else
        intensityNorm = Sunlight.sunlightIntensityNorm(scpPlayerData.currentSquareLight)
    end
    local burnChancePerCheck = Sunlight.burnChancePerCheck(intensityNorm)
    if burnChancePerCheck <= 0 then return end

    local exposureMs = timestampMs - scpPlayerData.liquefyingStartTimestampMs
    local bodyDamage = player:getBodyDamage()
    local chanceOverChecks = Sunlight.chanceOverChecks

    if exposureMs >= Sunlight.MIN_EXPOSURE_MS_FOR_BURNS then
        rollBurnsForParts(bodyDamage, scpPlayerData.uncoveredParts, chanceOverChecks(burnChancePerCheck, checks))
        -- A head behind a head covering with a nonzero multiplier can burn
        -- too, with its chance scaled down by that multiplier.
        if scpPlayerData.headCoverMultiplier > 0 then
            rollBurnsForParts(bodyDamage, HEAD_ONLY_PARTS,
                chanceOverChecks(burnChancePerCheck * scpPlayerData.headCoverMultiplier, checks))
        end
    end
    if exposureMs >= Sunlight.MIN_EXPOSURE_MS_FOR_BURNS * Sunlight.HOLE_BURN_EXPOSURE_MULTIPLIER then
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
    scpPlayerData.lastDamageDoneTimestampMs = timestampMs + Sunlight.DAMAGE_GRACE_MS - Sunlight.DAMAGE_TICK_MS
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
    local ticks = math.floor((timestampMs - scpPlayerData.lastDamageDoneTimestampMs) / Sunlight.DAMAGE_TICK_MS)
    if ticks > 0 then
        local maxTicks = player:isAsleep() and 1 or Sunlight.MAX_CATCHUP_DAMAGE_TICKS
        if ticks > maxTicks then
            ticks = maxTicks
            scpPlayerData.lastDamageDoneTimestampMs = timestampMs -- drop the backlog, don't defer it
        else
            scpPlayerData.lastDamageDoneTimestampMs = scpPlayerData.lastDamageDoneTimestampMs + ticks * Sunlight.DAMAGE_TICK_MS
        end

        local rawDamage
        if scpPlayerData.exposureSource == "moon" then
            rawDamage = Sunlight.calculateBodyDamageFromMoonlight(scpPlayerData.currentSquareLight)
        else
            rawDamage = Sunlight.calculateBodyDamageFromSunlight(scpPlayerData.currentSquareLight)
        end
        local damage = rawDamage * scpPlayerData.exposureFraction * Sunlight.GENERAL_DAMAGE_MULTIPLIER * ticks
        if damage > 0 and Sunlight.isHoldingOpenUmbrella(player) then
            damage = damage * Sunlight.UMBRELLA_DAMAGE_MULTIPLIER
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
            scpPlayerData.headCoverMultiplier = Sunlight.computeBodyCoverage(player)
        scpPlayerData.exposureFraction = Sunlight.weightedExposureFraction(scpPlayerData)
        scpPlayerData.headLightExposure = Sunlight.headLightExposure(scpPlayerData)
        scpPlayerData.bodyExposedBesidesHead = Sunlight.hasExposureBesidesHead(scpPlayerData)
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

-- Pulls the player-only tweakable values (the vignette's) from the sandbox
-- options (defined in media/sandbox-options.txt) into the local variables
-- declared above, falling back to keep whatever default is already set if the
-- sandbox table - or an individual option in it - isn't populated for some
-- reason. The light and damage values are loaded by Sunlight.init().

local function loadSandboxOptions()
    local scpOptions = SandboxVars.SCP
    if not scpOptions then return end

    VIGNETTE_MAX_ALPHA = scpOptions.VignetteMaxAlpha or VIGNETTE_MAX_ALPHA
    if scpOptions.VignetteEnabled ~= nil then
        VIGNETTE_ENABLED = scpOptions.VignetteEnabled
    end
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
    Sunlight.init()
    loadSandboxOptions()
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