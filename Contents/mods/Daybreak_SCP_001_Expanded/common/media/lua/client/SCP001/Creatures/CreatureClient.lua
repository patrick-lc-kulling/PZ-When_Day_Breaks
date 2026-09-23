-- The player's side of the creatures: noticing a Grasper's grab, hearing a
-- Caller, and the sounds creatures make nearby.
--
-- A multiplayer client has no creature modData; it knows each creature's type
-- from the outfit the engine syncs, see DaybreakCreatures.getType().

require "SCP001/Creatures/CreatureHeadgear"

local Creatures = DaybreakCreatures

-- ---------------------------------------------------------------- grasper --

-- There is no Lua event for a zombie hitting a player in B42.20:
-- OnBeingHitByZombie is registered but never fired, and OnPlayerGetDamage has
-- no zombie damage type. What a zombie's hit does leave behind is the
-- player's hit reaction and getAttackedBy() pointing at the zombie, so a grasp
-- is the moment a hit reaction starts while a Grasper is the attacker.
local wasBeingHit = {}
local lastStripMs = {}

-- A grasp is a grab, not a blow: the hit that tears the helmet off must not
-- also tear holes in the clothes. That damage is already done by the time the
-- grasp can be noticed - the engine puts holes in the outermost layer, destroys
-- any patch there and knocks condition off in the same call that starts the
-- hit reaction - so the worn clothing is photographed just beforehand and put
-- back when a grasp succeeds. Only while a Grasper is close enough to swing,
-- so it costs nothing the rest of the time.
local SNAPSHOT_EVERY_MS = 60
local NEAR_CHECK_EVERY_MS = 250
local grasperNear = {}
local snapshots = {}
local lastSnapshotMs = {}
local lastNearCheckMs = 0

-- A destroyed patch is sewn back with a fabric of the same kind. Only the
-- fabric's type is read from the item, it is never used up.
local PATCH_FABRIC_ITEM = {
    Cotton = "Base.RippedSheets",
    Denim = "Base.DenimStrips",
    Leather = "Base.LeatherStrips",
}

local function takeSnapshot(player)
    local worn = player:getWornItems()
    local snapshot = {}
    if worn == nil then return snapshot end

    local partCount = BloodBodyPartType.MAX:index()
    for i = 0, worn:size() - 1 do
        local item = worn:get(i):getItem()
        if item and instanceof(item, "Clothing") then
            local entry = {
                item = item,
                visual = ItemVisual.new(item:getVisual()), -- holes and blood
                condition = item:getCondition(),
            }
            if item:getPatchesNumber() > 0 then
                entry.patches = {}
                for part = 0, partCount - 1 do
                    local patch = item:getPatchType(BloodBodyPartType.FromIndex(part))
                    if patch then entry.patches[part] = patch:getFabricTypeName() end
                end
            end
            snapshot[#snapshot + 1] = entry
        end
    end
    return snapshot
end

local function restoreSnapshot(player, snapshot)
    for i = 1, #snapshot do
        local entry = snapshot[i]
        local item = entry.item

        -- Sew destroyed patches back first. The one thing that does not come
        -- back exactly is the patch's quality: vanilla gives no way to read the
        -- level of whoever sewed it, so it takes the player's current Tailoring.
        if entry.patches then
            for part, fabric in pairs(entry.patches) do
                local bodyPart = BloodBodyPartType.FromIndex(part)
                local fabricItem = PATCH_FABRIC_ITEM[fabric]
                if item:getPatchType(bodyPart) == nil and fabricItem then
                    item:addPatch(player, bodyPart, instanceItem(fabricItem))
                end
            end
        end

        local visual = item:getVisual()
        visual:copyHoles(entry.visual)
        visual:copyBlood(entry.visual)
        -- Last, since sewing a patch changes condition too.
        if item:getCondition() ~= entry.condition then
            item:setCondition(entry.condition)
        end
        if isClient() then pcall(syncItemFields, player, item) end
    end

    if isClient() then pcall(function() player:syncVisuals() end) end
    player:resetModelNextFrame()
    triggerEvent("OnClothingUpdated", player)
end

local function updateGrasperProximity()
    local cell = getCell()
    local zombies = cell and cell:getZombieList()
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        local near = false
        if player and zombies and not player:isDead() then
            local range = Creatures.Tuning.grasperReach + 1
            local rangeSq = range * range
            for j = 0, zombies:size() - 1 do
                local zombie = zombies:get(j)
                if zombie and not zombie:isDead() then
                    local dx, dy = zombie:getX() - player:getX(), zombie:getY() - player:getY()
                    if dx * dx + dy * dy <= rangeSq then
                        local def = Creatures.getDefinition(zombie)
                        if def and def.stripsHeadgear then
                            near = true
                            break
                        end
                    end
                end
            end
        end
        grasperNear[i] = near
        if not near then snapshots[i] = nil end
    end
end

function Creatures.onHeadgearStripped(player, itemName, fromServer)
    player:setHaloNote(getText("IGUI_Daybreak_HeadgearTornOff", itemName), 255, 80, 80, 300)
    -- In single player the strip already fired this; from the server it has
    -- only fired over there, and the sun code here needs to hear it too.
    if fromServer then triggerEvent("OnClothingUpdated", player) end
end

local function tryStrip(player)
    local playerNum = player:getPlayerNum()
    local nowMs = getTimestampMs()
    local last = lastStripMs[playerNum]
    if last and nowMs >= last and nowMs - last < Creatures.Tuning.grasperCooldownSeconds * 1000 then return end

    local chance = Creatures.sandbox("GrasperStripChance", 25)
    if chance <= 0 or ZombRand(100) >= chance then return end

    local item = Creatures.findStrippableHeadgear(player)
    if item == nil then return end
    lastStripMs[playerNum] = nowMs

    -- Undo what the blow did to the clothes, the torn-off item included,
    -- before it comes off.
    local snapshot = snapshots[playerNum]
    if snapshot then restoreSnapshot(player, snapshot) end

    if isClient() then
        sendClientCommand(player, Creatures.MODULE, "GrasperStrip", { item = item:getID() })
    else
        local name = item:getDisplayName()
        if Creatures.stripHeadgear(player, item) then
            Creatures.onHeadgearStripped(player, name, false)
        end
    end
end

local function onPlayerUpdate(player)
    local playerNum = player:getPlayerNum()
    local beingHit = player:hasHitReaction()
    if beingHit and not wasBeingHit[playerNum] then
        local attacker = player:getAttackedBy()
        if attacker and instanceof(attacker, "IsoZombie")
            and attacker:DistTo(player) <= Creatures.Tuning.grasperReach then
            local def = Creatures.getDefinition(attacker)
            if def and def.stripsHeadgear then tryStrip(player) end
        end
    end
    wasBeingHit[playerNum] = beingHit

    -- Photograph the clothes while a Grasper is in reach, but never during a
    -- hit reaction: that would capture the damage it is meant to undo.
    if grasperNear[playerNum] and not beingHit then
        local nowMs = getTimestampMs()
        local last = lastSnapshotMs[playerNum]
        if last == nil or nowMs - last >= SNAPSHOT_EVERY_MS or nowMs < last then
            snapshots[playerNum] = takeSnapshot(player)
            lastSnapshotMs[playerNum] = nowMs
        end
    end
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)

local function checkGrasperProximity()
    local nowMs = getTimestampMs()
    if nowMs - lastNearCheckMs < NEAR_CHECK_EVERY_MS and nowMs >= lastNearCheckMs then return end
    lastNearCheckMs = nowMs
    updateGrasperProximity()
end
Events.OnTick.Add(checkGrasperProximity)

-- -------------------------------------------------------------- knockdown --

-- Masses, and anything bigger that sets knockdownImmune, are too much bulk to
-- knock over by hand or with an ordinary weapon. The engine has already
-- decided on the knockdown by the time OnWeaponHitXp fires, and has not yet
-- sent the hit to anyone else, so cancelling it here cancels it everywhere.
-- The electric weapons are exempt: their own handler decides whether the
-- creature goes down, from its stunTime.
local function isElectricWeapon(weapon)
    return DaybreakStunWeapons ~= nil and DaybreakStunWeapons.getConfig(weapon) ~= nil
end

local function onWeaponHitXp(owner, weapon, hitObject, damage, hitCount)
    if hitObject == nil or not instanceof(hitObject, "IsoZombie") then return end
    if owner == nil or not instanceof(owner, "IsoPlayer") or not owner:isLocalPlayer() then return end
    if isElectricWeapon(weapon) then return end

    local def = Creatures.getDefinition(hitObject)
    if def and def.knockdownImmune then
        hitObject:setKnockedDown(false)
    end
end
Events.OnWeaponHitXp.Add(onWeaponHitXp)

-- ----------------------------------------------------------------- caller --

-- A Caller called out. Called by the server's command in multiplayer, and
-- directly by the server code in single player.
function Creatures.onCallerCall(args)
    local def = Creatures.get(args.type)
    local call = def and def.call
    if call == nil then return end

    local sound = args.female and call.soundFemale or call.soundMale
    local emitter = sound and getWorld():getFreeEmitter(args.x, args.y, args.z)
    if emitter then emitter:playSound(sound) end

    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() and math.floor(player:getZ()) == math.floor(args.z) then
            local dx, dy = player:getX() - args.x, player:getY() - args.y
            if dx * dx + dy * dy <= call.stressRange * call.stressRange then
                player:getStats():add(CharacterStat.STRESS, call.stress)
            end
        end
    end
end

-- ----------------------------------------------------------------- voices --

-- Idle sounds, for any type that declares sounds.idle. Pure presentation, so
-- each client plays them for what it can hear itself, with no network. The
-- sweep does nothing at all until some type has a sound.
local anyTypeHasSounds = nil
local lastVoiceMs = 0

local function typesHaveSounds()
    if anyTypeHasSounds == nil then
        anyTypeHasSounds = false
        for _, def in ipairs(Creatures.all()) do
            if def.sounds and def.sounds.idle then anyTypeHasSounds = true end
        end
    end
    return anyTypeHasSounds
end

local function nearAnyPlayer(zombie, rangeSq)
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player then
            local dx, dy = player:getX() - zombie:getX(), player:getY() - zombie:getY()
            if dx * dx + dy * dy <= rangeSq then return true end
        end
    end
    return false
end

local function playIdleVoices()
    local cell = getCell()
    local zombies = cell and cell:getZombieList()
    if zombies == nil then return end

    local range = Creatures.Tuning.voiceRange
    local rangeSq = range * range
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and not zombie:isDead() then
            local def = Creatures.getDefinition(zombie)
            local sounds = def and def.sounds
            if sounds and sounds.idle and ZombRandFloat(0.0, 1.0) < (sounds.idleChance or 0.2)
                and nearAnyPlayer(zombie, rangeSq) then
                zombie:getEmitter():playSound(sounds.idle)
            end
        end
    end
end

local function onTick()
    if not typesHaveSounds() then return end
    local nowMs = getTimestampMs()
    if nowMs - lastVoiceMs < Creatures.Tuning.voiceSeconds * 1000 and nowMs >= lastVoiceMs then return end
    lastVoiceMs = nowMs
    playIdleVoices()
end
Events.OnTick.Add(onTick)

-- ---------------------------------------------------------------- network --

local function onServerCommand(module, command, args)
    if module ~= Creatures.MODULE or args == nil then return end
    if command == "HeadgearStripped" then
        local player = getPlayer()
        if player then Creatures.onHeadgearStripped(player, args.name, true) end
    elseif command == "CallerCall" then
        Creatures.onCallerCall(args)
    end
end
Events.OnServerCommand.Add(onServerCommand)
