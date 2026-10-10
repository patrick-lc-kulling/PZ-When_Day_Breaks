-- Project A-Life compatibility. A-Life's NPCs are living people, so the sun
-- liquefies them the same way it does the player (ALifeSunDamage). They spend
-- the day indoors in the dark (ALifeShelter) and live at night, when nothing
-- burns at all.
--
-- This file holds the clock the rest follows and hooks it into A-Life. A-Life
-- is optional: without it nothing here does anything. Every hook checks that
-- what it wraps still exists and reports once if A-Life has changed, so a
-- newer A-Life can only switch parts of this off, never break.
-- Nothing of ours may live under media/lua/*/ProjectALife/: A-Life reports
-- files there as a mod shipping a copy of its code.
require "SCP001/Sunlight"

SCP001 = SCP001 or {}
local Sunlight = SCP001.Sunlight

local Compat = {
    -- Sandbox values (media/sandbox-options.txt), see loadSandboxOptions.
    settings = {
        -- Master switch for everything in SCP001/ALife.
        enabled = true,
        -- NPC sun damage as a multiple of what a player in the same clothes
        -- takes. 0 leaves NPCs unharmed but still keeping to the schedule.
        sunDamageMultiplier = 1.0,
        -- How long before dawn NPCs start heading indoors.
        shelterLeadMinutes = 60,
        -- Whether sheltering NPCs hang sheets over windows and shut doors.
        blackout = true,
    },
    hooks = {},
    warned = {},
}
SCP001.ALife = Compat

Compat.SHELTER_MODULE_ID = "daybreakShelter"
Compat.SUN_FLIGHT_MODULE_ID = "daybreakSunFlight"
-- How far from its shelter square an NPC may move while fighting by day.
Compat.SHELTER_LEASH_TILES = 2

function Compat.loadSandboxOptions()
    local scpOptions = SandboxVars and SandboxVars.SCP
    if not scpOptions then return end
    local settings = Compat.settings
    if scpOptions.ALifeCompatibility ~= nil then settings.enabled = scpOptions.ALifeCompatibility end
    settings.sunDamageMultiplier = scpOptions.ALifeSunDamageMultiplier or settings.sunDamageMultiplier
    settings.shelterLeadMinutes = scpOptions.ALifeShelterLeadMinutes or settings.shelterLeadMinutes
    if scpOptions.ALifeBlackout ~= nil then settings.blackout = scpOptions.ALifeBlackout end
end

function Compat.present()
    return type(ProjectALife) == "table" and type(ProjectALife.ModuleRegistry) == "table"
end

function Compat.active()
    return Compat.settings.enabled == true and Compat.present()
end

-- The day ------------------------------------------------------------------------

-- The sun is a threat whenever there's any real daylight at all: the same
-- gate the player's own sun damage uses.
function Compat.sunThreat()
    return Sunlight.isSunUp()
end

local function dawnAndDusk()
    local season = getClimateManager():getSeason()
    return season:getDawn(), season:getDusk()
end

local function leadHours()
    return math.max(0, Compat.settings.shelterLeadMinutes) / 60
end

-- Whether people should be indoors now: while the sun is up, and from a
-- little before dawn, so they're inside before it rises. It reads only the
-- climate and the clock, so the server and every client agree on it.
function Compat.shelterTime()
    if Compat.sunThreat() then return true end
    local dawn = dawnAndDusk()
    local hour = getGameTime():getTimeOfDay()
    return hour >= dawn - leadHours() and hour < dawn + 1
end

-- The same question about an hour of the day. A-Life almost always asks
-- about the current hour, which is answered live; any other hour goes by the
-- season's dawn and dusk.
function Compat.shelterTimeAt(hour)
    hour = tonumber(hour)
    if hour == nil then return Compat.shelterTime() end
    local apart = math.abs(hour - getGameTime():getTimeOfDay())
    if apart < 1 or apart > 23 then return Compat.shelterTime() end
    local dawn, dusk = dawnAndDusk()
    hour = hour % 24
    return hour >= dawn - leadHours() and hour < dusk + 1
end

-- Which day it is, for things done once a day. A day's shelter time doesn't
-- span midnight, so the calendar day will do.
function Compat.dayIndex()
    return math.floor(getGameTime():getWorldAgeHours() / 24)
end

-- Whether square stays dark even at the sun's peak: indoors, and no
-- dangerous light reaches it. It's the same test that burns the player.
function Compat.darkAllDay(square)
    if square == nil or square:isOutside() then return false end
    return Sunlight.findExposureLightLevel(square, Sunlight.PEAK_LIGHT_LEVEL) == nil
end

-- Whether going to point now would take someone into the sun: anywhere
-- outdoors, anywhere not loaded, or anywhere sunlight reaches right now.
function Compat.unsafeByDay(point)
    if type(point) ~= "table" then return false end
    local x, y = tonumber(point.x), tonumber(point.y)
    if x == nil or y == nil then return false end
    local square = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(tonumber(point.z) or 0))
    if square == nil or square:isOutside() then return true end
    return Sunlight.sunLightAt(square) ~= nil
end

-- Hooks --------------------------------------------------------------------------

function Compat.warnOnce(key, message)
    if Compat.warned[key] then return end
    Compat.warned[key] = true
    print("[Daybreak] Project A-Life compatibility: " .. message)
end

-- Not every event exists on every side (OnServerStarted, for one), so they're
-- only hooked where they do, as A-Life does.
function Compat.onEvent(name, handler)
    local event = Events[name]
    if event ~= nil then event.Add(handler) end
end

-- Replaces ProjectALife[ownerName][name] with makeWrapper(original), once.
-- A table or function A-Life rebuilds is wrapped again. When report is set
-- (the final install at game start), a missing target is reported.
local function wrap(ownerName, name, report, makeWrapper)
    local owner = ProjectALife[ownerName]
    local key = ownerName .. "." .. name
    if type(owner) ~= "table" or type(owner[name]) ~= "function" then
        if report then Compat.warnOnce(key, key .. " not found, so that part is off") end
        return false
    end
    local hook = Compat.hooks[key]
    if hook ~= nil and hook.owner == owner and owner[name] == hook.wrapper then return true end
    local original = owner[name]
    local wrapper = makeWrapper(original)
    owner[name] = wrapper
    Compat.hooks[key] = { owner = owner, wrapper = wrapper, original = original }
    return true
end

local function daytime()
    return Compat.active() and Compat.shelterTime()
end

-- A-Life's night - when its people board up or camp, and its house crews go
-- quiet - becomes the time the sun is a threat. At real night A-Life acts as
-- it does by day. Its sight limit in the dark, flashlights and helicopter
-- spotlights go by the clock, not this, so they still follow real darkness.
local function isNightAdapter()
    return Compat.shelterTime()
end

local function installDayCycle(report)
    local cycle = ProjectALife.DayCycle
    if type(cycle) ~= "table" or type(cycle.adapters) ~= "table" then
        if report then Compat.warnOnce("DayCycle", "DayCycle not found, so A-Life keeps its own night") end
        return
    end
    if Compat.active() then
        if cycle.adapters.isNight ~= isNightAdapter then
            Compat.replacedIsNight = cycle.adapters.isNight
            cycle.adapters.isNight = isNightAdapter
        end
    elseif cycle.adapters.isNight == isNightAdapter then
        cycle.adapters.isNight = Compat.replacedIsNight
    end
end

local function installLull(report)
    local decisions = ProjectALife.DecisionLoop
    local lull = type(decisions) == "table" and decisions.lullModules or nil
    if type(lull) ~= "table" then
        if report then Compat.warnOnce("lullModules", "DecisionLoop.lullModules not found") end
        return
    end
    for _, id in ipairs(lull) do
        if id == Compat.SHELTER_MODULE_ID then return end
    end
    table.insert(lull, 1, Compat.SHELTER_MODULE_ID)
end

local function installHooks(report)
    -- A-Life only makes camp in its night, which is now the day: a campfire
    -- in the open is no shelter from the sun.
    wrap("ModuleIdleLife", "makeCamp", report, function(original)
        return function(actor, shell, context)
            if Compat.active() then return nil end
            return original(actor, shell, context)
        end
    end)

    -- Out of daylight A-Life only covers the windows that are lit or face
    -- trouble. Before sunrise none are lit yet, and by day every window lets
    -- the sun in, so sheltering people cover them all.
    wrap("ModuleIdleLife", "coverable", report, function(original)
        return function(facts)
            if daytime() then return true end
            return original(facts)
        end
    end)

    -- Every behaviour profile runs our two modules. An admin's per-NPC "off"
    -- and A-Life's module switches are checked before this and still apply.
    wrap("BehaviorProfiles", "allows", report, function(original)
        return function(actor, overlay)
            if overlay == Compat.SHELTER_MODULE_ID or overlay == Compat.SUN_FLIGHT_MODULE_ID then return true end
            return original(actor, overlay)
        end
    end)

    -- By day a fight is fought from the shelter square, so nobody chases
    -- into the sun.
    wrap("Combat", "leashFor", report, function(original)
        return function(actor)
            if daytime() and Compat.Shelter ~= nil then
                local spot = Compat.Shelter.spotOf(actor)
                if spot ~= nil then return spot, Compat.SHELTER_LEASH_TILES end
            end
            return original(actor)
        end
    end)

    -- Nobody runs out into the sun to back up a squadmate or check a noise.
    wrap("Programs", "supportDestination", report, function(original)
        return function(actor, shell, now)
            local destination, intent = original(actor, shell, now)
            if destination ~= nil and daytime() and Compat.unsafeByDay(destination) then return nil end
            return destination, intent
        end
    end)
    wrap("Investigation", "destinationFor", report, function(original)
        return function(actor, shell, now)
            local heard = original(actor, shell, now)
            if heard ~= nil and daytime() and Compat.unsafeByDay(heard) then return nil end
            return heard
        end
    end)

    -- Off-screen squads rest through the day and travel by night.
    wrap("OfflineDirector", "restsTonight", report, function(original)
        return function(squad, hours, hour)
            if Compat.active() then return Compat.shelterTimeAt(hour) end
            return original(squad, hours, hour)
        end
    end)

    -- Night is when people are out, so every encounter and faction can turn
    -- up then, whatever time of day it was written for; none do by day.
    wrap("Encounters", "timeAllowed", report, function(original)
        return function(definition, hour)
            if Compat.active() then return not Compat.shelterTimeAt(hour) end
            return original(definition, hour)
        end
    end)
    wrap("FactionSpawnRules", "activeAtHour", report, function(original)
        return function(spawn, hour)
            if Compat.active() then return not Compat.shelterTimeAt(hour) end
            return original(spawn, hour)
        end
    end)

    -- Nobody is created where the sun would reach them. Admins placing an
    -- NPC by hand get what they asked for.
    wrap("SpawnPolicy", "check", report, function(original)
        return function(position, options, context)
            local allowed, reason, normalized, square = original(position, options, context)
            if allowed ~= true or not daytime() then return allowed, reason, normalized, square end
            if type(options) == "table" and options.adminPlaced == true then
                return allowed, reason, normalized, square
            end
            if not Compat.darkAllDay(square) then return false, "daybreak_sunlight" end
            return allowed, reason, normalized, square
        end
    end)

    -- An off-screen squad only comes back on screen by day if it's hiding
    -- somewhere dark, and then it's placed on dark squares there. The rest
    -- wait for night instead of A-Life moving them away for want of a spot.
    wrap("RenderProtocol", "driverNearest", report, function(original)
        return function(x, y, list)
            local driving = original(x, y, list)
            if driving == true or not daytime() or Compat.Shelter == nil then return driving end
            Compat.stagingPlayers = list
            local spots = Compat.Shelter.rehydrationSpots(x, y, list)
            return spots == nil or #spots == 0
        end
    end)
    wrap("RenderProtocol", "columnPosition", report, function(original)
        return function(headX, headY, dx, dy, index, spacing)
            if daytime() and Compat.Shelter ~= nil then
                local spots = Compat.Shelter.rehydrationSpots(headX, headY, Compat.stagingPlayers)
                local spot = spots and spots[index]
                if spot ~= nil then return spot.x, spot.y end
            end
            return original(headX, headY, dx, dy, index, spacing)
        end
    end)

    installLull(report)
end

local function registerModules(report)
    local registry = ProjectALife.ModuleRegistry
    if Compat.Shelter == nil or type(registry.register) ~= "function" then return end
    for _, definition in ipairs(Compat.Shelter.moduleDefinitions()) do
        if registry.get(definition.id) == nil then
            local registered, why = registry.register(definition)
            if not registered and report then
                Compat.warnOnce("register:" .. definition.id, "could not register " .. definition.id .. ": " .. tostring(why))
            end
        end
    end
end

-- Installs everything that can be installed yet. A-Life's tables appear as
-- its files load, so this runs at load, at game start (report = true, when
-- anything still missing is reported) and every ten in-game minutes.
-- The light model is (re)loaded at game start, once the save's sandbox values
-- are in: Main.lua does it too on OnInitWorld, but it can't be relied on to
-- load on a dedicated server.
function Compat.install(report)
    Compat.loadSandboxOptions()
    if report then Sunlight.init() end
    if not Compat.present() then return end
    installDayCycle(report)
    if not Compat.settings.enabled then return end
    installHooks(report)
    registerModules(report)
end

local function installAndReport()
    local ok, err = pcall(Compat.install, true)
    if not ok then print("[Daybreak] Project A-Life compatibility failed to install: " .. tostring(err)) end
end

pcall(Compat.install, false)
Compat.onEvent("OnGameStart", installAndReport)
Compat.onEvent("OnServerStarted", installAndReport)
Compat.onEvent("EveryTenMinutes", function() pcall(Compat.install, false) end)

return Compat
