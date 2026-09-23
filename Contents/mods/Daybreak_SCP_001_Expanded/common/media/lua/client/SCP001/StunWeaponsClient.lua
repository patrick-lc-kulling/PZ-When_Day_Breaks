-- Applies and maintains the stun from the electric weapons. Tunables are in
-- shared/SCP001/StunWeapons.lua; this file is the machinery.
require "SCP001/StunWeapons"

local MODULE = "Daybreak"
local TASER = "Base.Daybreak_Taser"
local SPENT_CARTRIDGE = "Base.Daybreak_TaserCartridge_Spent"

-- reanimateTimer, the engine's "can I get up yet" counter, is measured in
-- 30fps frames rather than seconds.
local FRAMES_PER_SECOND = 30

-- Targets currently being held on the ground: { target = character,
-- framesLeft = number }. Normally empty or a couple of entries long.
local activeStuns = {}

local function addStun(target, seconds)
    local frames = seconds * FRAMES_PER_SECOND
    for i = 1, #activeStuns do
        if activeStuns[i].target == target then
            -- A second zap refreshes rather than stacks.
            if activeStuns[i].framesLeft < frames then
                activeStuns[i].framesLeft = frames
            end
            return
        end
    end
    activeStuns[#activeStuns + 1] = { target = target, framesLeft = frames }
end

-- The stun has to be re-applied rather than set once: ZombieOnGroundState
-- overwrites reanimateTimer with its own random 30-89 frames when the target
-- lands, and PlayerKnockedDown counts it down during the fall animation.
-- Counting in the engine's own frame units means sleeping and fast-forward
-- scale the stun the same way they scale everything else.
local function updateStuns()
    local count = #activeStuns
    if count == 0 then return end

    local frameStep = getGameTime():getThirtyFPSMultiplier()

    for i = count, 1, -1 do
        local stun = activeStuns[i]
        local target = stun.target
        stun.framesLeft = stun.framesLeft - frameStep

        if stun.framesLeft <= 0 or not target or target:isDead() then
            table.remove(activeStuns, i)
        elseif target:isOnFloor() then
            target:setReanimateTimer(stun.framesLeft)
        end
    end
end
Events.OnTick.Add(updateStuns)

-- IsoZombie:knockDown() is unusable in B42.20: it sets playerAttackPosition to
-- "BEHIND" or nil, but every to_staggerback-knockeddown transition compares
-- against "FRONT" or "BACK", so the knockdown node is never reached. Setting
-- the same flags by hand, with a value the animation graph accepts, is what
-- actually floors them.
local function knockDownZombie(zombie)
    zombie:setHitReaction("")
    zombie:setPlayerAttackPosition("FRONT")
    zombie:setKnockedDown(true)
    zombie:setStaggerBack(true)
    zombie:setHitForce(2.0)
    zombie:reportEvent("wasHit")
end

-- How long this creature stays down, relative to the weapon's zombieStunSeconds:
-- its type's stunTime (see CreatureTypes.lua), 0 meaning it cannot be stunned.
local function creatureStunScale(zombie)
    local creatures = DaybreakCreatures
    local def = creatures and creatures.getDefinition(zombie)
    return def and def.stunTime or 1.0
end

-- The route vanilla uses when a car clips a player: a hit reaction plus the
-- knockdown flag, which the animation graph turns into falldown then onground.
local function knockDownPlayer(player, seconds)
    player:setHitReaction("HitReaction")
    player:setKnockedDown(true)
    player:setReanimateTimer(seconds * FRAMES_PER_SECOND)
    player:reportEvent("washit")
    addStun(player, seconds)
end

-- OnWeaponHitXp is the only weapon event that runs on the attacking client
-- alone, and it fires after hitConsequences (which would otherwise overwrite
-- the knockdown flag) but before the vanilla hit packet is built - so the
-- knockdown reaches other players without a packet of our own. It covers the
-- taser too: it fires for ranged weapons as well as melee.
local function onStunHit(owner, weapon, hitObject, damage, hitCount)
    if not owner or not weapon or not hitObject then return end

    local config = DaybreakStunWeapons.getConfig(weapon)
    if not config then return end
    if not instanceof(owner, "IsoPlayer") or not owner:isLocalPlayer() then return end

    -- hitObject is whatever was struck, including doors, trees and windows,
    -- and animals - which instanceof calls IsoPlayers. The weapons do nothing
    -- to animals: that includes the Great Collective, which is immune anyway.
    local isZombie = instanceof(hitObject, "IsoZombie")
    local isPlayer = not isZombie and instanceof(hitObject, "IsoPlayer")
        and not instanceof(hitObject, "IsoAnimal")
    if not isZombie and not isPlayer then return end

    if config.maxCharge > 0 then
        local charge = DaybreakStunWeapons.getCharge(weapon, config)
        if charge < config.chargePerUse then
            owner:setHaloNote(getText("IGUI_Daybreak_StunWeaponFlat"), 255, 80, 80, 200)
            return
        end
        DaybreakStunWeapons.setCharge(weapon, charge - config.chargePerUse, config)
    end

    if config.stunChance < 1.0 and ZombRandFloat(0.0, 1.0) > config.stunChance then return end

    if isZombie then
        local stunScale = creatureStunScale(hitObject)
        if stunScale <= 0 then
            -- Immune. The hit itself may still have knocked it over (a lucky
            -- crit), and immune has to mean it stays standing.
            hitObject:setKnockedDown(false)
            return
        end
        knockDownZombie(hitObject)
        -- In multiplayer only the client that owns a zombie drives its AI. The
        -- knockdown still reaches everyone through the vanilla hit packet, but
        -- holding it down any longer than vanilla would is the owner's job.
        if not (isClient() and hitObject:isRemoteZombie()) then
            addStun(hitObject, config.zombieStunSeconds * stunScale)
        end
    elseif hitObject:isLocalPlayer() then
        -- Split screen: the victim is right here, no round trip needed.
        knockDownPlayer(hitObject, config.playerStunSeconds)
    else
        -- The knockdown flag rides the vanilla hit packet, but reanimateTimer
        -- is not networked, so the victim's own client has to be told to hold
        -- itself down for longer than the default.
        hitObject:setKnockedDown(true)
        if isClient() then
            sendClientCommand(owner, MODULE, "StunPlayer", {
                target = hitObject:getOnlineID(),
                weapon = weapon:getFullType(),
            })
        end
    end
end
Events.OnWeaponHitXp.Add(onStunHit)

-- Told by the server that someone tased us. The duration is looked up in our
-- own config rather than taken from the message, so another client can't
-- decide how long we lie on the floor.
local function onServerCommand(module, command, args)
    if module ~= MODULE or command ~= "Stunned" then return end

    local player = getPlayer()
    if not player or player:isDead() then return end

    local config = args and args.weapon and DaybreakStunWeapons.CONFIG[args.weapon]
    local seconds = config and config.playerStunSeconds
        or DaybreakStunWeapons.FALLBACK_PLAYER_STUN_SECONDS
    knockDownPlayer(player, seconds)
end
Events.OnServerCommand.Add(onServerCommand)

-- Spent taser cartridges come back so they can be rebuilt. A dart is only
-- spent when a round actually left the weapon, so the ammo count is compared
-- across the shot rather than assuming every trigger pull fired.
local ammoBeforeShot = {}

local function isLocalTaserUser(character, weapon)
    if not weapon or weapon:getFullType() ~= TASER then return false end
    return instanceof(character, "IsoPlayer") and character:isLocalPlayer()
end

local function onTaserSwing(character, weapon)
    if not isLocalTaserUser(character, weapon) then return end
    ammoBeforeShot[character:getPlayerNum()] = weapon:getCurrentAmmoCount()
end
Events.OnWeaponSwing.Add(onTaserSwing)

local function onTaserAttackFinished(character, weapon)
    if not isLocalTaserUser(character, weapon) then return end

    local playerNum = character:getPlayerNum()
    local before = ammoBeforeShot[playerNum]
    ammoBeforeShot[playerNum] = nil
    if not before then return end

    if weapon:getCurrentAmmoCount() < before then
        character:getInventory():AddItem(SPENT_CARTRIDGE)
    end
end
Events.OnPlayerAttackFinished.Add(onTaserAttackFinished)

-- Nothing should survive into a new world: these are live object references.
local function clearStuns()
    activeStuns = {}
    ammoBeforeShot = {}
end
Events.OnGameStart.Add(clearStuns)
