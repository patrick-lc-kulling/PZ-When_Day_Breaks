-- Straight lines across the square grid: what a line from a character crosses,
-- and whether anything solid stands in it. Shared by the Great Collective's
-- reach and the flamethrower's stream.

DaybreakGridLine = DaybreakGridLine or {}
local GridLine = DaybreakGridLine

-- The squares a straight line from `from` towards (toX, toY) crosses, handed
-- to visit(fromSquare, toSquare) one wall-edge at a time. A diagonal step is
-- split into its two sides so no wall between them is skipped. Stops at the
-- first visit that returns something, and returns that.
local LINE_STEP = 0.5 -- tiles; small enough never to skip a square

function GridLine.walk(from, toX, toY, maxDistance, visit)
    local previous = from:getCurrentSquare()
    if previous == nil then return nil end

    local cell = getCell()
    local fromX, fromY = from:getX(), from:getY()
    local z = math.floor(from:getZ())
    local dx, dy = toX - fromX, toY - fromY
    local length = math.sqrt(dx * dx + dy * dy)
    if maxDistance and length > maxDistance then
        dx, dy = dx * maxDistance / length, dy * maxDistance / length
        length = maxDistance
    end

    local steps = math.max(1, math.ceil(length / LINE_STEP))
    for i = 1, steps do
        local square = cell:getGridSquare(math.floor(fromX + dx * i / steps), math.floor(fromY + dy * i / steps), z)
        if square == nil then return nil end
        if square ~= previous then
            local stepX = square:getX() - previous:getX()
            local stepY = square:getY() - previous:getY()
            local side = nil
            if stepX ~= 0 and stepY ~= 0 then
                side = cell:getGridSquare(previous:getX() + stepX, previous:getY(), z)
            end
            local result
            if side then
                result = visit(previous, side) or visit(side, square)
            else
                result = visit(previous, square)
            end
            if result then return result end
            previous = square
        end
    end
    return nil
end

-- A window already smashed or found open still blocks walking, but not
-- reaching through it.
function GridLine.isOpenWindowBetween(a, b)
    local window = a:getWindowTo(b)
    return window ~= nil and (window:isSmashed() or window:IsOpen())
end

-- Nothing gets through from a to b: a wall, a closed door or window, stairs.
-- The engine's isBlockedTo has no fences in it, so both a reach and a jet of
-- flame go over them.
function GridLine.blocksReach(a, b)
    return a:isBlockedTo(b) and not GridLine.isOpenWindowBetween(a, b)
end

-- Nothing solid between the two characters. IsoGameCharacter:CanSee is no use
-- here - asked about one character by another, its two overloads call each
-- other until the stack overflows.
function GridLine.hasClearLine(from, to)
    local blocked = GridLine.walk(from, to:getX(), to:getY(), nil, function(a, b)
        if GridLine.blocksReach(a, b) then return true end
        return nil
    end)
    return not blocked
end
