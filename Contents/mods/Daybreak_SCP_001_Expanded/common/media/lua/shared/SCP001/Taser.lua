-- Daybreak Taser: a low-lethality sidearm modelled on the M26, the taser
-- American police started carrying in 1999. media/scripts/daybreak_taser.txt
-- gives it almost no vanilla weapon damage on purpose - everything it
-- actually does to a target happens here: a small amount of direct damage,
-- plus being forced onto the ground for a few seconds. All four numbers
-- below are safe to retune independently, either right here or via the
-- matching sandbox options (media/sandbox-options.txt, SandboxVars.SCP.Taser*).
--
-- MP caveat: this runs from the shared folder and reacts to the same
-- OnWeaponHitZombie/OnWeaponHitCharacter events the rest of combat already
-- uses (mirroring how media/lua/shared/SCP001/Main.lua applies its own
-- damage), rather than adding a separate server-authoritative damage path.
-- That matches the rest of this mod, but hasn't been hardened against a
-- malicious client the way vanilla firearm damage is.

-- Flat health taken per hit, on the same 0-100 overall-health scale as
-- BodyDamage:ReduceGeneralHealth (100 = full health). Kept low for people -
-- a taser is meant to incapacitate, not wound.
local DAMAGE_TO_PLAYER = 2
-- Zombies have no armour or wound system for a taser to bypass, so this is
-- the entire cost of a hit to them - moderate rather than low, so it's a
-- slow but genuine way to put one down for good, not just a stun gun.
local DAMAGE_TO_ZOMBIE = 20

-- How many real-world seconds a hit target is forced to stay knocked down.
local STUN_SECONDS_PLAYER = 6
local STUN_SECONDS_ZOMBIE = 8

local TASER_FULLTYPE = "Base.Daybreak_Taser"

-- Pulls the tunables above from this mod's sandbox options (defined in
-- media/sandbox-options.txt), falling back to whatever's already set if the
-- sandbox table - or an individual option in it - isn't populated.
local function loadSandboxOptions()
    local options = SandboxVars.SCP
    if not options then return end

    DAMAGE_TO_PLAYER = options.TaserDamageToPlayer or DAMAGE_TO_PLAYER
    DAMAGE_TO_ZOMBIE = options.TaserDamageToZombie or DAMAGE_TO_ZOMBIE
    STUN_SECONDS_PLAYER = options.TaserStunSecondsPlayer or STUN_SECONDS_PLAYER
    STUN_SECONDS_ZOMBIE = options.TaserStunSecondsZombie or STUN_SECONDS_ZOMBIE
end
Events.OnInitWorld.Add(loadSandboxOptions)

local function isOurTaser(weapon)
    return weapon ~= nil and weapon:getFullType() == TASER_FULLTYPE
end

-- [character] = getTimestamp() (real seconds) the forced knockdown ends.
local stunnedUntil = {}

local function applyStun(character, stunSeconds, damage)
    if not character or character:isDead() then return end

    local bodyDamage = character:getBodyDamage()
    if bodyDamage then
        bodyDamage:ReduceGeneralHealth(damage)
    end

    stunnedUntil[character] = getTimestamp() + stunSeconds
    if character.setKnockedDown then
        character:setKnockedDown(true)
    end
end

local function onWeaponHitZombie(zombie, attacker, bodyPart, weapon)
    if not isOurTaser(weapon) then return end
    applyStun(zombie, STUN_SECONDS_ZOMBIE, DAMAGE_TO_ZOMBIE)
end
Events.OnWeaponHitZombie.Add(onWeaponHitZombie)

-- Only fires for non-zombie targets (other survivors/NPCs), so no separate
-- zombie check is needed here.
local function onWeaponHitCharacter(attacker, target, weapon, damage)
    if not isOurTaser(weapon) then return end
    applyStun(target, STUN_SECONDS_PLAYER, DAMAGE_TO_PLAYER)
end
Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)

-- setKnockedDown(true) only triggers the fall - left alone the character
-- would be back up almost immediately. This re-asserts it every few ticks
-- for as long as stunnedUntil says they should stay down, then releases
-- them. Throttled since it walks every currently-stunned character.
local TICKS_BETWEEN_CHECKS = 5
local tickCounter = 0
local function onTick()
    tickCounter = tickCounter + 1
    if tickCounter % TICKS_BETWEEN_CHECKS ~= 0 then return end

    local now = getTimestamp()
    for character, endTime in pairs(stunnedUntil) do
        if not character or character:isDead() then
            stunnedUntil[character] = nil
        elseif now >= endTime then
            stunnedUntil[character] = nil
            if character.setKnockedDown then character:setKnockedDown(false) end
        elseif character.setKnockedDown then
            character:setKnockedDown(true)
        end
    end
end
Events.OnTick.Add(onTick)
