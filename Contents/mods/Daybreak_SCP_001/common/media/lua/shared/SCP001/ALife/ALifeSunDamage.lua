-- The sun liquefies Project A-Life's NPCs the way it does the player: the
-- same light search, the same clothing coverage and the same damage curve,
-- dealt as a share of the NPC's maximum health through A-Life's own health
-- calls. Burns become A-Life wounds. Nothing burns at night - NPCs ignore
-- moonlight whatever the player's moonlight setting is.
--
-- Damage is applied only by whoever runs the NPC: everyone in singleplayer,
-- and in multiplayer the client A-Life has executing it, which is where
-- A-Life applies its own damage too (see its ALifeVehicleRules).
require "SCP001/Sunlight"
require "SCP001/ALife/ALifeCompat"

local Sunlight = SCP001.Sunlight
local Compat = SCP001.ALife

local SunDamage = {
    -- Per NPC shell; a shell A-Life rebuilds starts over.
    states = setmetatable({}, { __mode = "k" }),
    -- Real-time ms each shell was last found in dangerous light.
    exposedAtMs = setmetatable({}, { __mode = "k" }),
    clockMs = 0,
    lastStepMs = 0,
    anyBurning = false,
}
Compat.SunDamage = SunDamage

-- The light search is the expensive part; each NPC repeats it whenever it
-- moves to another square, and otherwise on this speed-adjusted timer.
local EXPOSURE_RECHECK_INTERVAL_MS = 250
-- NPCs fire no clothing events, so their coverage is just rechecked.
local CLOTHING_RECHECK_INTERVAL_MS = 2000
-- How long a burning NPC counts as exposed after its last exposed check.
local EXPOSED_MEMORY_MS = 1500
-- In multiplayer, clients also check NPCs they don't run within this many
-- tiles of a local player, only to play the burning sound.
local SOUND_RADIUS = 30

-- Must match the "sound X" name in media/scripts/scp_sounds.txt. A-Life
-- silences zombie sounds on its NPCs by name, so this is our own.
local NPC_BURNING_SOUND_NAME = "SCPNPCBurning"

-- A-Life wound zones for the body parts a burn can land on.
local woundZone = {}
for _, name in ipairs({ "Head", "Neck" }) do woundZone[BloodBodyPartType[name]:index()] = "head" end
for _, name in ipairs({ "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R", "Foot_L", "Foot_R" }) do
    woundZone[BloodBodyPartType[name]:index()] = "limb"
end

local HEAD_ONLY_PARTS = { [Sunlight.HEAD_PART_INDEX] = true }

local function speedAdjustedDeltaMs()
    return getGameTime():getMultipliedSecondsSinceLastUpdate() * 1000
end

local function isActor(shell)
    local damage = ProjectALife.HumanDamage
    if damage ~= nil and type(damage.isActor) == "function" then return damage.isActor(shell) == true end
    local data = shell:getModData()
    return data ~= nil and (data.ProjectALifeOwned == true or data.ProjectALifeActor == true)
end

local function hasAuthority(shell)
    local fence = ProjectALife.AIFence
    if fence == nil or type(fence.authorityFor) ~= "function" then return not isClient() end
    return fence.authorityFor(shell) == true
end

local function nearLocalPlayer(shell)
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and math.abs(player:getX() - shell:getX()) <= SOUND_RADIUS
                and math.abs(player:getY() - shell:getY()) <= SOUND_RADIUS then
            return true
        end
    end
    return false
end

local function newState()
    return {
        burning = false, burningSinceMs = 0, lastDamageMs = 0, lastBurnCheckMs = 0,
        nextCoverageMs = 0, uncoveredParts = {}, holedParts = {}, headCoverMultiplier = 0,
        exposureFraction = 0, lastSquare = nil, nextLightMs = 0, light = nil,
        woundedParts = {}, soundId = nil,
    }
end

local function playBurningSound(shell, state)
    local emitter = shell:getEmitter()
    if state.soundId and emitter:isPlaying(state.soundId) then return end
    local soundId = emitter:playSound(NPC_BURNING_SOUND_NAME)
    state.soundId = soundId ~= 0 and soundId or nil
end

local function stopBurning(shell, state)
    if not state.burning then return end
    state.burning = false
    local soundId = state.soundId
    if soundId then
        state.soundId = nil
        pcall(function() shell:getEmitter():stopSoundLocal(soundId) end)
    end
end

local function startBurning(state, now)
    state.burning = true
    state.burningSinceMs = now
    -- Backdated so the first damage tick lands exactly DAMAGE_GRACE_MS in,
    -- as for the player.
    state.lastDamageMs = now + Sunlight.DAMAGE_GRACE_MS - Sunlight.DAMAGE_TICK_MS
    state.lastBurnCheckMs = now
    state.woundedParts = {}
end

-- Health lost this step, on A-Life's scale: the player's damage per tick is
-- a share of 100 health, so it's taken as the same share of the NPC's
-- maximum. Returns the health left, or nil if nothing was dealt.
local function applyDamage(shell, state, now)
    local ticks = math.floor((now - state.lastDamageMs) / Sunlight.DAMAGE_TICK_MS)
    if ticks <= 0 then return nil end
    if ticks > Sunlight.MAX_CATCHUP_DAMAGE_TICKS then
        ticks = Sunlight.MAX_CATCHUP_DAMAGE_TICKS
        state.lastDamageMs = now -- drop the backlog, don't defer it
    else
        state.lastDamageMs = state.lastDamageMs + ticks * Sunlight.DAMAGE_TICK_MS
    end

    local percent = Sunlight.calculateBodyDamageFromSunlight(state.light) * state.exposureFraction
        * Sunlight.GENERAL_DAMAGE_MULTIPLIER * Compat.settings.sunDamageMultiplier * ticks
    if percent > 0 and Sunlight.isHoldingOpenUmbrella(shell) then
        percent = percent * Sunlight.UMBRELLA_DAMAGE_MULTIPLIER
    end
    if percent <= 0 then return nil end

    -- A-Life keeps its own health ceiling on top of the engine's, so health
    -- only goes through its calls.
    local simulation = ProjectALife.ShellSimulation
    local current = tonumber(simulation.trueHealth(shell)) or 0
    if current <= 0 then return nil end
    local after = math.max(0, current - simulation.maximumFor(shell) * percent / 100)
    if after <= 0 then
        simulation.setHealth(shell, 0)
        -- Killed by the sun, not by any player.
        shell:Kill(shell)
        return 0
    end
    simulation.setHealth(shell, after)
    return after
end

local function rollWounds(shell, state, parts, chance, remaining)
    local health = ProjectALife.Health
    for partIndex in pairs(parts) do
        if not state.woundedParts[partIndex] and ZombRand(10000) < chance * 10000 then
            state.woundedParts[partIndex] = true
            -- Forgiven: no player is to blame, so no reputation or grudge.
            health.onDamage(nil, shell, woundZone[partIndex] or "torso", remaining,
                ProjectALife.ShellSimulation.maximumFor(shell), getTimestampMs(), true)
        end
    end
end

-- The player's burn rules: after the same exposure time, at the same
-- intervals and odds, each bare part may burn - here into an A-Life wound
-- (a limp from the legs, blood, and the downed bleed-out once health is
-- critical), at most once per exposure.
local function applyBurns(shell, state, now, remaining)
    local checks = math.floor((now - state.lastBurnCheckMs) / Sunlight.BURN_CHECK_INTERVAL_MS)
    if checks <= 0 then return end
    state.lastBurnCheckMs = state.lastBurnCheckMs + checks * Sunlight.BURN_CHECK_INTERVAL_MS

    local health = ProjectALife.Health
    if health == nil or type(health.onDamage) ~= "function" then return end
    local burnChancePerCheck = Sunlight.burnChancePerCheck(Sunlight.sunlightIntensityNorm(state.light))
    if burnChancePerCheck <= 0 then return end

    local exposureMs = now - state.burningSinceMs
    local chanceOverChecks = Sunlight.chanceOverChecks
    if exposureMs >= Sunlight.MIN_EXPOSURE_MS_FOR_BURNS then
        rollWounds(shell, state, state.uncoveredParts, chanceOverChecks(burnChancePerCheck, checks), remaining)
        if state.headCoverMultiplier > 0 then
            rollWounds(shell, state, HEAD_ONLY_PARTS,
                chanceOverChecks(burnChancePerCheck * state.headCoverMultiplier, checks), remaining)
        end
    end
    if exposureMs >= Sunlight.MIN_EXPOSURE_MS_FOR_BURNS * Sunlight.HOLE_BURN_EXPOSURE_MULTIPLIER then
        rollWounds(shell, state, state.holedParts, chanceOverChecks(burnChancePerCheck, checks), remaining)
    end
end

function SunDamage.updateShell(shell, now, baseLight)
    local states = SunDamage.states
    local state = states[shell]
    local simulation = ProjectALife.ShellSimulation
    if shell:isDead() or simulation == nil or simulation.grappledCorpse(shell) or not isActor(shell) then
        if state then stopBurning(shell, state) states[shell] = nil end
        return
    end
    local authority = hasAuthority(shell)
    if not authority and not (isClient() and nearLocalPlayer(shell)) then
        if state then stopBurning(shell, state) end
        return
    end
    if not state then
        state = newState()
        states[shell] = state
    end

    if now >= state.nextCoverageMs then
        state.nextCoverageMs = now + CLOTHING_RECHECK_INTERVAL_MS
        state.uncoveredParts, state.holedParts, state.headCoverMultiplier = Sunlight.computeBodyCoverage(shell)
        state.exposureFraction = Sunlight.weightedExposureFraction(state)
    end
    if state.exposureFraction <= 0 then
        stopBurning(shell, state)
        return
    end

    local square = shell:getCurrentSquare()
    if square ~= state.lastSquare or now >= state.nextLightMs then
        state.lastSquare = square
        state.nextLightMs = now + EXPOSURE_RECHECK_INTERVAL_MS
        state.light = Sunlight.findExposureLightLevel(square, baseLight)
    end
    if not state.light then
        stopBurning(shell, state)
        return
    end

    if not state.burning then startBurning(state, now) end
    SunDamage.anyBurning = true
    SunDamage.exposedAtMs[shell] = getTimestampMs()
    -- A dedicated server plays no sound, and a sound that fails mustn't
    -- stop the damage below.
    if not isServer() then pcall(playBurningSound, shell, state) end
    if not authority then return end

    local health = ProjectALife.Health
    if health ~= nil and type(health.invulnerable) == "function" and health.invulnerable(shell) then return end
    local remaining = applyDamage(shell, state, now)
    if remaining == 0 then
        stopBurning(shell, state)
        states[shell] = nil
        return
    end
    applyBurns(shell, state, now, remaining or tonumber(simulation.trueHealth(shell)) or 0)
end

function SunDamage.stopAll()
    if not SunDamage.anyBurning then return end
    SunDamage.anyBurning = false
    for shell, state in pairs(SunDamage.states) do
        pcall(stopBurning, shell, state)
    end
end

-- Whether shell was burning a moment ago. The shelter uses it to get burning
-- NPCs out of the light before anything else.
function SunDamage.exposedNow(shell)
    local at = shell ~= nil and SunDamage.exposedAtMs[shell] or nil
    return at ~= nil and getTimestampMs() - at <= EXPOSED_MEMORY_MS
end

local shells = {}
function SunDamage.step(now)
    if not Compat.active() or not Sunlight.isSunUp() then
        SunDamage.stopAll()
        return
    end
    local baseLight = Sunlight.skyBaseLight()
    if baseLight <= Sunlight.MIN_DANGEROUS_LIGHT_LEVEL then
        SunDamage.stopAll()
        return
    end
    local fence = ProjectALife.AIFence
    if fence == nil or type(fence.owned) ~= "table" then return end

    -- Collected first: a kill makes A-Life drop the shell from the table.
    local count = 0
    for shell in pairs(fence.owned) do
        count = count + 1
        shells[count] = shell
    end
    for index = 1, count do
        local shell = shells[index]
        shells[index] = nil
        local ok, err = pcall(SunDamage.updateShell, shell, now, baseLight)
        if not ok then Compat.warnOnce("sundamage", "NPC sun damage failed: " .. tostring(err)) end
    end
end

function SunDamage.onTick()
    SunDamage.clockMs = SunDamage.clockMs + speedAdjustedDeltaMs()
    local now = SunDamage.clockMs
    if now - SunDamage.lastStepMs < Sunlight.DAMAGE_TICK_MS then return end
    SunDamage.lastStepMs = now
    SunDamage.step(now)
end

Compat.onEvent("OnTick", SunDamage.onTick)

return SunDamage
