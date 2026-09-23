-- Relays a taser stun to the player who was hit.
--
-- A knocked-down flag reaches other clients on its own through the vanilla hit
-- packet, but the timer that decides how long someone stays down is not
-- networked, and only a player's own client may drive that player. So the
-- attacker asks the server, and the server tells the victim.

local MODULE = "Daybreak"

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= "StunPlayer" then return end
    if not args or not args.target then return end

    local target = getPlayerByOnlineID(args.target)
    if not target then return end

    sendServerCommand(target, MODULE, "Stunned", { weapon = args.weapon })
end
Events.OnClientCommand.Add(onClientCommand)
