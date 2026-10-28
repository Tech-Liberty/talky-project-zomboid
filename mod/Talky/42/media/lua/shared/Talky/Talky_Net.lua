-- Messages between the game client (Talky_Bridge, Talky_Client) and the Talky server code
-- (Talky_Server, Talky_ServerRunner, Talky_Tags), the same path in every mode:
--   single player : both sides live in this Lua state. Each direction has a queue drained on
--                   the next tick (never a direct call), and the payload is copied the way the
--                   network copies it (plain data only, an empty table arrives as nil).
--   multiplayer   : client -> server with sendClientCommand, server -> client with
--                   sendServerCommand, module "Talky" (Events.OnClientCommand/OnServerCommand).
-- Also: finding a player by username, and the strict parsers used on every value that
-- comes from a job or from the network.

require "Talky/Talky_Config"

TalkyNet = {
    MODULE = "Talky",
    toServerQueue = {},   -- single player: { command, args }
    toClientQueue = {},
    maxQueue = 2000,
    serverHandler = nil,  -- function(command, player, args), set by server/Talky/Talky_Server.lua
    clientHandler = nil,  -- function(command, args), set by client/Talky/Talky_Client.lua
}

---------------------------------------------------------------- mode

-- "sp" (single player), "client" (multiplayer client, the host's game included) or
-- "server" (dedicated server, or the server process of a hosted game).
function TalkyNet.mode()
    if isServer ~= nil and isServer() then return "server" end
    if isClient ~= nil and isClient() then return "client" end
    return "sp"
end

---------------------------------------------------------------- strict parsers

local MAX_INT = 9007199254740992 -- 2^53

-- Number or numeric string ("12", "-3", "1.5"; no exponent, hex, nan or inf), clamped to
-- [lo, hi]. Anything else, NaN and infinities included, gives def (not clamped).
function TalkyNet.num(v, def, lo, hi)
    if type(v) == "string" then
        if string.len(v) > 40 or not string.match(v, "^%s*%-?%d+%.?%d*%s*$") then return def end
        v = tonumber(v)
        if v == nil then return def end
    elseif type(v) ~= "number" then
        return def
    end
    if v ~= v or v == math.huge or v == -math.huge then return def end
    if v < lo then v = lo elseif v > hi then v = hi end
    return v
end

-- Same, rounded down to an integer.
function TalkyNet.int(v, def, lo, hi)
    local n = TalkyNet.num(v, nil, lo, hi)
    if n == nil then return def end
    return math.floor(n)
end

-- Whole number 1..2^53 (seq). Anything else (fractions included) gives nil.
-- The upper clamp is 2^54: 2^53 + 1 is not a double, so a larger value would come back as 2^53.
function TalkyNet.seq(v)
    local n = TalkyNet.num(v, nil, -1, MAX_INT * 2)
    if n == nil or n < 1 or n > MAX_INT or math.floor(n) ~= n then return nil end
    return n
end

-- First max characters of a string. Kahlua strings are Java (UTF-16) strings: string.len and
-- string.sub count UTF-16 units, and an emoji is two of them. A cut that leaves the first half
-- of a pair alone is shortened by one more unit (the network and the file writers would turn
-- the lone half into '?'). 55296..56319 = 0xD800..0xDBFF (string.byte returns the unit).
function TalkyNet.cut(v, max)
    if string.len(v) <= max then return v end
    if max < 1 then return "" end
    v = string.sub(v, 1, max)
    local last = string.byte(v, string.len(v))
    if last and last >= 55296 and last <= 56319 then v = string.sub(v, 1, string.len(v) - 1) end
    return v
end

-- Text without control characters, cut to max characters (TalkyNet.cut). Numbers become text;
-- any other type gives def.
function TalkyNet.str(v, max, def)
    if type(v) == "number" then
        if v ~= v then return def end
        v = tostring(v)
    end
    if type(v) ~= "string" then return def end
    v = TalkyNet.cut(v, max)
    v = string.gsub(v, "%c", " ")
    return v
end

-- "#rrggbb" (or "rrggbb"), returned as "#rrggbb"; anything else gives def.
function TalkyNet.color(v, def)
    if type(v) ~= "string" then return def end
    if string.match(v, "^#%x%x%x%x%x%x$") then return v end
    if string.match(v, "^%x%x%x%x%x%x$") then return "#" .. v end
    return def
end

function TalkyNet.bool(v, def)
    if v == nil then return def end
    return v == true or v == "true" or v == 1 or v == "1"
end

-- True when the table has no entry (Kahlua in the tests has no next()).
function TalkyNet.isEmpty(t)
    for _ in pairs(t) do return false end
    return true
end

---------------------------------------------------------------- logs

-- One console line, without control characters (viewer names cannot forge lines).
function TalkyNet.log(msg)
    print("[Talky] " .. TalkyNet.str(tostring(msg), 300, ""))
end

-- [key] = { minute, lines, suppressed, said = { [reason] = true } }
TalkyNet.logLimits = {}

-- Console line about one player (key = TalkyNet.userKey): once per reason per minute, at most
-- 10 lines per player per minute; the next minute starts with how many were left out. Used by
-- the server's command handler and by the job runner (Talky_Server.logFor).
function TalkyNet.logLimited(key, reason, msg)
    local t = getTimestampMs()
    key = tostring(key or "?")
    local l = TalkyNet.logLimits[key]
    if not l or t - l.minute >= 60000 or t < l.minute then
        if l and l.suppressed > 0 then
            TalkyNet.log(TalkyNet.str(key, 32, "?") .. ": " .. l.suppressed .. " line(s) suppressed")
        end
        l = { minute = t, lines = 0, suppressed = 0, said = {} }
        TalkyNet.logLimits[key] = l
    end
    if reason and l.said[reason] then
        l.suppressed = l.suppressed + 1
        return
    end
    if l.lines >= 10 then
        l.suppressed = l.suppressed + 1
        return
    end
    if reason then l.said[reason] = true end
    l.lines = l.lines + 1
    TalkyNet.log(TalkyNet.str(key, 32, "?") .. ": " .. TalkyNet.str(tostring(msg), 120, ""))
end

---------------------------------------------------------------- copy with network semantics

local MAX_DEPTH = 16

local function copyValue(v, depth)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    if t ~= "table" or depth >= MAX_DEPTH then return nil end
    local out = {}
    for k, val in pairs(v) do
        local kt = type(k)
        if kt == "string" or kt == "number" then
            local c = copyValue(val, depth + 1)
            if c ~= nil then out[k] = c end
        end
    end
    return out
end

-- Copy of args as the other side receives it: keys string or number, values string,
-- number, boolean or table (anything else dropped), a top-level empty table becomes nil.
function TalkyNet.copy(args)
    if type(args) ~= "table" then return nil end
    local out = copyValue(args, 0)
    if TalkyNet.isEmpty(out) then return nil end
    return out
end

---------------------------------------------------------------- sending

local function push(queue, command, args)
    if #queue >= TalkyNet.maxQueue then
        TalkyNet.log("message dropped, queue full: " .. tostring(command))
        return false
    end
    queue[#queue + 1] = { command = command, args = TalkyNet.copy(args) }
    return true
end

-- Client -> server. Returns false when nothing was sent (no local player yet).
function TalkyNet.toServer(command, args)
    local mode = TalkyNet.mode()
    if mode == "client" then
        local player = getPlayer()
        if not player then return false end
        sendClientCommand(player, TalkyNet.MODULE, command, args or {})
        return true
    elseif mode == "sp" then
        return push(TalkyNet.toServerQueue, command, args)
    end
    TalkyNet.log("toServer(" .. tostring(command) .. ") called on the server")
    return false
end

-- Server -> the client of one player.
function TalkyNet.toClient(player, command, args)
    local mode = TalkyNet.mode()
    if mode == "server" then
        if player then sendServerCommand(player, TalkyNet.MODULE, command, args or {}) end
    elseif mode == "sp" then
        push(TalkyNet.toClientQueue, command, args)
    else
        TalkyNet.log("toClient(" .. tostring(command) .. ") called on a client")
    end
end

-- Server -> every client (single player: the only one).
function TalkyNet.broadcast(command, args)
    local mode = TalkyNet.mode()
    if mode == "server" then
        sendServerCommand(TalkyNet.MODULE, command, args or {})
    elseif mode == "sp" then
        push(TalkyNet.toClientQueue, command, args)
    else
        TalkyNet.log("broadcast(" .. tostring(command) .. ") called on a client")
    end
end

-- Single player: delivers what was queued before this tick (replies go to the next one).
function TalkyNet.pump()
    if #TalkyNet.toServerQueue == 0 and #TalkyNet.toClientQueue == 0 then return end
    local toServer, toClient = TalkyNet.toServerQueue, TalkyNet.toClientQueue
    TalkyNet.toServerQueue, TalkyNet.toClientQueue = {}, {}
    for _, m in ipairs(toServer) do
        if TalkyNet.serverHandler then
            local ok, err = pcall(TalkyNet.serverHandler, m.command, getPlayer(), m.args)
            if not ok then TalkyNet.log("server command " .. tostring(m.command) .. " failed: " .. tostring(err)) end
        end
    end
    for _, m in ipairs(toClient) do
        if TalkyNet.clientHandler then
            local ok, err = pcall(TalkyNet.clientHandler, m.command, m.args)
            if not ok then TalkyNet.log("client command " .. tostring(m.command) .. " failed: " .. tostring(err)) end
        end
    end
end

---------------------------------------------------------------- players

-- Username of a player as the game spells it ("" when unknown).
function TalkyNet.username(player)
    if not player then return "" end
    local ok, name = pcall(function() return player:getUsername() end)
    if not ok or name == nil then return "" end
    return tostring(name)
end

-- Account identity of a username: A-Z folded to a-z and nothing else, exactly like SQLite's
-- LOWER() in the server's account lookup. Never string.lower (Java toLowerCase folds every
-- letter, and by the default locale): with AllowNonAsciiUsername, two names that differ only
-- by the case of an accented letter are two accounts. Never %u either (Kahlua's %u is Unicode
-- too).
function TalkyNet.nameKey(s)
    if type(s) ~= "string" then return "" end
    return (string.gsub(s, "[A-Z]", function(c) return string.char(string.byte(c) + 32) end))
end

-- The key of every per-player table (TalkyNet.nameKey of the username).
function TalkyNet.userKey(player)
    return TalkyNet.nameKey(TalkyNet.username(player))
end

-- The IsoPlayer of a username, looked up again at each call (a reconnect creates a new
-- one), or nil when offline. Single player: the local player. Never getPlayerFromUsername,
-- which only searches the client-side list and is always nil on a server.
function TalkyNet.findPlayer(username)
    local mode = TalkyNet.mode()
    if mode == "sp" then return getPlayer() end
    if type(username) ~= "string" or username == "" then return nil end
    local want = TalkyNet.nameKey(username)
    if mode == "server" then
        local list = getOnlinePlayers()
        if not list then return nil end
        local same
        for i = 0, list:size() - 1 do
            local p = list:get(i)
            if p then
                -- the exact name first; the same account typed in another ASCII case otherwise
                if TalkyNet.username(p) == username then return p end
                if not same and TalkyNet.userKey(p) == want then same = p end
            end
        end
        return same
    end
    local p = getPlayer()
    if p and TalkyNet.userKey(p) == want then return p end
    return nil
end

Events.OnTick.Add(TalkyNet.pump)

return TalkyNet
