-- Fake Project Zomboid 42.21 for the Talky tests (loaded by sim.lua).
--
-- Every simulated game process (single player game, dedicated server, coop server of a hosted
-- game, each client) is a Lua state of its own (__newEnv): its own globals, events, files,
-- player objects and world. The mod files are loaded into it the way the game does:
--   single player : shared/, client/, then server/ when the game starts; isClient() and
--                   isServer() both false
--   MP client     : shared/, client/, server/ (server files must return at once); isClient()
--   server        : shared/, server/ (client/ is only checksummed: a require of a client file
--                   is recorded as a failure, never run); isServer()
-- The game API below behaves like the 42.21 jar on each side (see CRITIQUE.md, checks.md):
-- sendServerCommand does nothing outside a server, transmitServer* only work on a server,
-- triggerCustomWeatherStage refuses while a weather period runs, playServerSound does nothing
-- in single player, getPlayerFromUsername is always nil on a server, an MP client cannot change
-- the world, and so on.
-- What the real game would silently ignore, or what Talky must never call, goes to P.misuse;
-- NaN or infinite values reaching the world go to W.corrupt; errors raised in event handlers
-- go to P.errors; reads of globals that do not exist go to P.unknown; every file opened goes to
-- P.io (the server and single player open Talky's own files only, a multiplayer client none of
-- the bridge's). H.hygiene() checks them.
-- Messages between processes go through H.net: copied by the game's own serializer
-- (__netCopy), a top-level empty table arrives as nil, and they are delivered at the end of
-- the tick, never inside the call that sent them.

local ROOT = __MOD_ROOT

H = { procs = {}, verbose = false, tickNo = 0 }
local noop = function() end

---------------------------------------------------------------- helpers

function H.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Lines as Java's BufferedReader.readLine gives them ("\n" or "\r\n", nothing after the last "\n").
function H.splitLines(s)
    local out, pos, n = {}, 1, string.len(s or "")
    while pos <= n do
        local e = string.find(s, "\n", pos)
        local line
        if e then
            line = string.sub(s, pos, e - 1)
            pos = e + 1
        else
            line = string.sub(s, pos)
            pos = n + 1
        end
        local len = string.len(line)
        if len > 0 and string.sub(line, len) == "\r" then line = string.sub(line, 1, len - 1) end
        out[#out + 1] = line
    end
    return out
end

local function bad(v)
    return type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge
end
H.bad = bad

local function isInt(v)
    return not bad(v) and math.floor(v) == v
end

-- Fake game objects carry a metatable with __java = class name: __netCopy drops them, like
-- the game's serializer drops an IsoPlayer or an IsoZombie. A fake IsoDirections is sent as
-- the real enum constant instead (the game sends directions, items and dead bodies): the
-- receiver gets a Java object, type "userdata".
function H.java(kind, t)
    return setmetatable(t, { __java = kind })
end
local java = H.java

function H.isJava(v, kind)
    if type(v) ~= "table" then return false end
    local mt = getmetatable(v)
    return mt ~= nil and mt.__java ~= nil and (kind == nil or mt.__java == kind)
end

-- java.util.ArrayList
function H.list(t)
    local l = { _t = t or {} }
    function l:size() return #self._t end
    function l:isEmpty() return #self._t == 0 end
    function l:get(i)
        if type(i) ~= "number" or i < 0 or i >= #self._t then
            error("IndexOutOfBoundsException: Index " .. tostring(i) .. " out of bounds for length " .. #self._t)
        end
        return self._t[i + 1]
    end
    function l:add(v) self._t[#self._t + 1] = v; return true end
    return java("ArrayList", l)
end

-- Deterministic random numbers (ZombRand, ZombRandFloat, helicopter target).
local seed = 1
function H.seed(s) seed = s end
function H.random()
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647
end

---------------------------------------------------------------- data files

local function decodeFile(path)
    local text = __readFile(path)
    if not text then return nil end
    return H.JSON.decode(text)
end

do
    local JE = __newEnv()
    local fn, err = __load(JE, ROOT .. "/shared/Talky/Talky_Json.lua", "shared/Talky/Talky_Json.lua")
    if not fn then error("cannot load Talky_Json: " .. tostring(err)) end
    fn()
    H.JSON = JE.TalkyJson
end
H.UI = { EN = decodeFile(ROOT .. "/shared/Translate/EN/UI.json") or {}, FR = decodeFile(ROOT .. "/shared/Translate/FR/UI.json") or {} }
H.SANDBOX_TEXT = { EN = decodeFile(ROOT .. "/shared/Translate/EN/Sandbox.json") or {}, FR = decodeFile(ROOT .. "/shared/Translate/FR/Sandbox.json") or {} }

---------------------------------------------------------------- roles and accounts

-- Capabilities of the default roles (zombie.characters.Roles.addStatic, 42.21).
local ALL_CAPS = { "AddItem", "AddXP", "CanModifyBodyStats", "ChangeAccessLevel", "ClimateManager", "CreateHorde",
    "MakeEventsAlarmGunshot", "ManipulateVehicle", "ManipulateZombie", "StartStopRain", "ToggleGodModHimself",
    "ToggleInvisibleHimself", "ToggleNoclipHimself", "UseBrushToolManager", "UseFastMoveCheat", "UseHealthCheat",
    "UseTimedActionInstantCheat" }
local function capSet(list, without)
    local s = {}
    for _, c in ipairs(list) do s[c] = true end
    for _, c in ipairs(without or {}) do s[c] = nil end
    return s
end
H.ROLE_CAPS = {
    user = {},
    observer = capSet({ "ToggleGodModHimself", "ToggleInvisibleHimself", "ToggleNoclipHimself" }),
    gm = capSet({ "AddItem", "AddXP", "StartStopRain", "MakeEventsAlarmGunshot", "ToggleGodModHimself",
                  "ToggleInvisibleHimself", "ToggleNoclipHimself" }),
    moderator = capSet(ALL_CAPS, { "ChangeAccessLevel" }),
    admin = capSet(ALL_CAPS),
}
local CAPABILITY = {}
for _, c in ipairs(ALL_CAPS) do CAPABILITY[c] = c end

function H.misuse(P, what)
    P.misuse[#P.misuse + 1] = what
    if H.verbose then print("        misuse in " .. P.name .. ": " .. what) end
end

local function roleObject(P, name)
    local caps = H.ROLE_CAPS[name] or {}
    return java("Role", {
        getName = function() return name end,
        hasCapability = function(_, cap)
            if cap == nil then H.misuse(P, "Role:hasCapability(nil)") end
            return cap ~= nil and caps[cap] == true
        end,
        hasAdminPower = function()
            H.misuse(P, "Role:hasAdminPower() (true for observer and gm too)")
            return name ~= "user"
        end,
    })
end

local nextPlayerId = 1
-- The character as the world knows it; each process holds its own IsoPlayer object for it.
-- opts: role ("user", "observer", "gm", "moderator", "admin", or false for no role), x, y, z
function H.account(username, opts)
    opts = opts or {}
    local role = opts.role
    if role == nil then role = "user" elseif role == false then role = nil end
    local a = { username = username, role = role, x = opts.x or 100, y = opts.y or 100, z = opts.z or 0,
                dead = false, onlineId = nextPlayerId, stats = {}, items = {}, healed = {}, said = {}, sounds = {} }
    nextPlayerId = nextPlayerId + 1
    return a
end

local CHARACTER_STATS = { "ANGER", "BOREDOM", "DISCOMFORT", "ENDURANCE", "FATIGUE", "FITNESS", "FOOD_SICKNESS", "HUNGER",
    "IDLENESS", "INTOXICATION", "MORALE", "NICOTINE_WITHDRAWAL", "PAIN", "PANIC", "POISON", "SANITY", "SICKNESS",
    "STRESS", "TEMPERATURE", "THIRST", "UNHAPPINESS", "WETNESS", "ZOMBIE_FEVER", "ZOMBIE_INFECTION" }

local function corrupt(P, what)
    local list = P.world and P.world.corrupt or P.corrupt
    list[#list + 1] = what
    if H.verbose then print("        corrupt value in " .. P.name .. ": " .. what) end
end

-- IsoPlayer object of an account, held by process P.
function H.player(acc, P)
    local side = P.kind
    local p = { acc = acc, proc = P }
    local function num(v, what)
        if bad(v) then corrupt(P, what .. " = " .. tostring(v)) end
    end
    local function stat(s)
        if not H.isJava(s, "CharacterStat") then H.misuse(P, "Stats with a non-CharacterStat " .. tostring(s)) end
        return s and s.name or "?"
    end
    function p:getUsername() return acc.username end
    function p:getDisplayName() return acc.username end
    function p:getX() return acc.x end
    function p:getY() return acc.y end
    function p:getZ() return acc.z end
    function p:isDead() return acc.dead end
    function p:isExistInTheWorld() return true end
    function p:getPlayerNum() return 0 end
    function p:getOnlineID() return acc.onlineId end
    function p:isLocalPlayer() return side ~= "server" end
    function p:getRole()
        if acc.role == nil then return nil end
        return roleObject(P, acc.role)
    end
    function p:Say(text) acc.said[#acc.said + 1] = { side = side, text = tostring(text) } end
    function p:getCurrentSquare()
        if P.world then return P.world.square(math.floor(acc.x), math.floor(acc.y), acc.z) end
        return H.clientSquare(P, math.floor(acc.x), math.floor(acc.y), acc.z)
    end
    local inv = java("ItemContainer", {
        AddItems = function(_, t, n)
            if type(t) ~= "string" then H.misuse(P, "AddItems with a non-string type") end
            if not isInt(n) or n < 1 then corrupt(P, "AddItems count " .. tostring(n)) end
            if side == "client" then H.misuse(P, "AddItems on an MP client (the server owns the inventory)") end
            acc.items[#acc.items + 1] = { side = side, t = t, n = n }
            local list = {}
            for i = 1, (isInt(n) and n or 0) do list[i] = java("InventoryItem", { t = t }) end
            return H.list(list)
        end,
    })
    function p:getInventory() return inv end
    function p:getBodyDamage()
        return java("BodyDamage", { RestoreToFullHealth = function() acc.healed[#acc.healed + 1] = side end })
    end
    function p:getStats()
        return java("Stats", {
            get = function(_, s) return acc.stats[stat(s)] or 0 end,
            set = function(_, s, v) num(v, "Stats.set"); acc.stats[stat(s)] = v; acc.statSide = side end,
            add = function(_, s, v) num(v, "Stats.add"); local k = stat(s); acc.stats[k] = (acc.stats[k] or 0) + v; acc.statSide = side end,
            remove = function(_, s, v) num(v, "Stats.remove"); local k = stat(s); acc.stats[k] = (acc.stats[k] or 0) - v; acc.statSide = side end,
        })
    end
    function p:getEmitter()
        return java("BaseCharacterSoundEmitter", { playSound = function(_, name)
            acc.sounds[#acc.sounds + 1] = { side = side, name = name }
            return 1
        end })
    end
    function p:getHoursSurvived() return 12.7 end
    function p:getZombieKills() return 3 end
    return java("IsoPlayer", p)
end

---------------------------------------------------------------- world (single player game or server)

function H.world(kind)
    local W = { kind = kind, zombies = {}, nextZombieId = 100, squares = {}, blocked = {}, indoor = {}, void = {},
                safehouses = {}, weatherRunning = false, weather = {}, weatherStops = 0, thunder = {}, times = {},
                fires = {}, vehicles = {}, ground = {}, sounds = {}, serverSounds = {}, heli = {}, xp = {},
                statSyncs = {}, itemSyncs = 0, climatePackets = 0, corrupt = {}, spawnCalls = 0 }
    function W.key(x, y, z) return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z) end
    function W.square(x, y, z)
        if bad(x) or bad(y) or bad(z) then
            W.corrupt[#W.corrupt + 1] = "getGridSquare(" .. tostring(x) .. ", " .. tostring(y) .. ", " .. tostring(z) .. ")"
            return nil
        end
        local k = W.key(x, y, z)
        if W.void[k] or W.voidAll then return nil end
        local sq = W.squares[k]
        if not sq then
            sq = java("IsoGridSquare", { x = x, y = y, z = z })
            function sq:getX() return x end
            function sq:getY() return y end
            function sq:getZ() return z end
            function sq:isFree() return not W.blocked[k] end
            function sq:isOutside() return not W.indoor[k] end
            -- the String overload: the item is sent to the clients on a server
            function sq:AddWorldInventoryItem(item, ox, oy, oz)
                if type(item) ~= "string" then W.misuse = (W.misuse or 0) + 1 end
                if bad(ox) or bad(oy) or bad(oz) then W.corrupt[#W.corrupt + 1] = "AddWorldInventoryItem offset" end
                W.ground[#W.ground + 1] = { t = item, x = x, y = y, z = z }
                return java("InventoryItem", { t = item })
            end
            W.squares[k] = sq
        end
        return sq
    end
    -- IsoZombie of this world. Server: a short online id; single player: -1.
    function W.newZombie(x, y, z, o)
        local id = -1
        if kind == "server" then
            id = W.nextZombieId
            W.nextZombieId = W.nextZombieId + 1
        end
        local zed = { md = {}, dead = false, id = id, outfit = 5000 + #W.zombies, x = x, y = y, z = z,
                      onFire = o.onFire, health = o.health, crawler = o.crawler, fakeDead = o.fakeDead,
                      outfitName = o.outfit, attacker = nil, spottedBy = nil }
        function zed:getModData() return self.md end
        function zed:hasModData() return true end
        function zed:getOnlineID() return self.id end
        function zed:getPersistentOutfitID() return self.outfit end
        function zed:isDead() return self.dead end
        function zed:getCurrentSquare() if self.dead then return nil end return W.square(self.x, self.y, self.z) end
        function zed:getX() return self.x end
        function zed:getY() return self.y end
        function zed:getZ() return self.z end
        function zed:getAlpha() return 1 end
        function zed:getAttackedBy() return self.attacker end
        function zed:spotted(p) self.spottedBy = p end
        function zed:pathToCharacter(p) self.pathTo = p end
        W.zombies[#W.zombies + 1] = java("IsoZombie", zed)
        return zed
    end
    W.cell = java("IsoCell", {
        getGridSquare = function(_, x, y, z) return W.square(x, y, z) end,
        getZombieList = function()
            local alive = {}
            for _, z in ipairs(W.zombies) do if not z.dead then alive[#alive + 1] = z end end
            return H.list(alive)
        end,
    })
    function W.alive()
        local n = 0
        for _, z in ipairs(W.zombies) do if not z.dead then n = n + 1 end end
        return n
    end
    -- What IsoZombie.resetForReuse does: online id and outfit id reset, modData wiped.
    function W.recycle(zed, newId)
        zed.md = {}
        zed.id = newId or -1
        zed.outfit = 0
    end
    -- safehouse: { x1, y1, x2, y2, members = { lower-case usernames } }
    function W.addSafehouse(sh)
        sh.members = sh.members or {}
        W.safehouses[#W.safehouses + 1] = sh
    end
    return W
end

-- A square seen by an MP client: it exists, but changing the world from there is a mistake.
function H.clientSquare(P, x, y, z)
    local sq = java("IsoGridSquare", {})
    function sq:getX() return x end
    function sq:getY() return y end
    function sq:getZ() return z end
    function sq:isFree() return true end
    function sq:isOutside() return true end
    function sq:AddWorldInventoryItem() H.misuse(P, "AddWorldInventoryItem on an MP client") end
    return sq
end

-- Zombies of the server as one client sees them: same online id and outfit, own modData.
local function mirror(P, z)
    P.mirrors = P.mirrors or {}
    local m = P.mirrors[z]
    if m then return m end
    m = { md = {} }
    function m:getModData() return self.md end
    function m:getOnlineID() return z.id end
    function m:getPersistentOutfitID() return z.outfit end
    function m:isDead() return z.dead end
    function m:getCurrentSquare() if z.dead then return nil end return H.clientSquare(P, z.x, z.y, z.z) end
    function m:getX() return z.x end
    function m:getY() return z.y end
    function m:getZ() return z.z end
    function m:getAlpha() return 1 end
    function m:getAttackedBy() return z.attacker end
    java("IsoZombie", m)
    P.mirrors[z] = m
    return m
end
H.mirror = mirror

---------------------------------------------------------------- processes

-- Lua events of 42.21 (LuaEventManager) Talky may use; any other name is a mistake.
local VALID_EVENTS = {}
for _, e in ipairs({ "OnGameBoot", "OnGameStart", "OnTick", "OnTickEvenPaused", "OnClientCommand", "OnServerCommand",
    "OnServerStarted", "OnZombieDead", "OnPlayerDeath", "OnPostUIDraw", "OnPreUIDraw", "OnKeyPressed", "OnInitGlobalModData",
    "OnReceiveGlobalModData", "OnConnected", "OnDisconnect", "OnCreatePlayer", "OnPlayerUpdate", "OnMainMenuEnter",
    "OnLoad", "OnSave", "EveryOneMinute", "EveryTenMinutes", "EveryHours", "EveryDays", "OnResetLua", "OnInitWorld" }) do
    VALID_EVENTS[e] = true
end

function H.fire(P, ev, ...)
    if not P.alive then return end
    local list = P.handlers[ev]
    if not list then return end
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    for i = 1, #copy do
        local ok, err = pcall(copy[i], ...)
        if not ok then
            P.errors[#P.errors + 1] = ev .. ": " .. tostring(err)
            print("        error in " .. P.name .. " " .. ev .. ": " .. tostring(err))
        end
    end
end

local function installEvents(P)
    P.E.Events = setmetatable({}, { __index = function(t, ev)
        if not VALID_EVENTS[ev] then H.misuse(P, "Events." .. tostring(ev) .. " does not exist") end
        local e = {
            Add = function(fn)
                if type(fn) ~= "function" then H.misuse(P, "Events." .. ev .. ".Add without a function") end
                local l = P.handlers[ev] or {}
                l[#l + 1] = fn
                P.handlers[ev] = l
            end,
            Remove = function(fn)
                local l = P.handlers[ev] or {}
                for i = 1, #l do
                    if l[i] == fn then table.remove(l, i); break end
                end
            end,
        }
        rawset(t, ev, e)
        return e
    end })
end

local function installCore(P)
    local E, kind = P.E, P.kind
    E.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        local line = table.concat(parts, "\t")
        P.log[#P.log + 1] = line
        if H.verbose then print("        " .. P.name .. " | " .. line) end
    end
    E.isClient = function() return kind == "client" end
    E.isServer = function() return kind == "server" end
    E.getTimestampMs = function() return NOW end
    -- A server pauses only when no player is connected and PauseEmpty is on (GameTime 0-32):
    -- never while a streamer is online. Single player: the pause menu (then no OnTick at all).
    E.isGamePaused = function()
        if kind == "server" then
            if P.pauseEmpty == false then return false end
            for _, c in ipairs(P.conns) do
                if c.connected and c.serverPlayer then return false end
            end
            return true
        end
        return P.paused == true
    end
    E.instanceof = function(o, cls) return H.isJava(o, cls) end
    E.ZombRand = function(a, b)
        if b == nil then a, b = 0, a end
        if bad(a) or bad(b) then corrupt(P, "ZombRand(" .. tostring(a) .. ", " .. tostring(b) .. ")"); return 0 end
        if b <= a then return a end
        return a + math.floor(H.random() * (b - a))
    end
    E.ZombRandFloat = function(a, b)
        if bad(a) or bad(b) then corrupt(P, "ZombRandFloat(" .. tostring(a) .. ", " .. tostring(b) .. ")"); return 0 end
        return a + H.random() * (b - a)
    end
    -- players
    E.getPlayer = function()
        if kind == "server" then return nil end
        return P.localPlayer
    end
    E.getOnlinePlayers = function()
        if kind == "server" then
            local list = {}
            for _, c in ipairs(P.conns) do
                if c.connected and c.serverPlayer then list[#list + 1] = c.serverPlayer end
            end
            return H.list(list)
        elseif kind == "client" then
            return H.list({ P.localPlayer })
        end
        return H.list({})
    end
    E.getPlayerByOnlineID = function(id)
        if kind == "server" then
            for _, c in ipairs(P.conns) do
                if c.connected and c.serverPlayer and c.account.onlineId == id then return c.serverPlayer end
            end
            return nil
        end
        if P.localPlayer and P.acc and P.acc.onlineId == id then return P.localPlayer end
        return nil
    end
    -- GameClient's list only: always nil on a server
    E.getPlayerFromUsername = function(name)
        if kind == "server" then
            H.misuse(P, "getPlayerFromUsername on the server (always nil there)")
            return nil
        end
        if P.localPlayer and P.acc and P.acc.username == name then return P.localPlayer end
        return nil
    end
    E.isAdmin = function()
        if kind ~= "client" then
            if kind == "server" then H.misuse(P, "isAdmin() on the server (always false there)") end
            return false
        end
        return P.acc ~= nil and P.acc.role == "admin"
    end
    E.isCoopHost = function()
        if kind == "server" then H.misuse(P, "isCoopHost() on the server (reads GameClient.connection)") end
        return kind == "client" and P.conn ~= nil and P.conn.host == true
    end
    E.getAccessLevel = function()
        H.misuse(P, "getAccessLevel() is deprecated")
        return ""
    end
    E.getServerName = function()
        if kind == "client" and P.conn then return P.conn.server.serverName end
        return ""
    end
    E.SendCommandToServer = function(cmd)
        if kind ~= "client" or not P.conn then H.misuse(P, "SendCommandToServer outside an MP client"); return end
        P.commands[#P.commands + 1] = cmd
        H.net.cmds[#H.net.cmds + 1] = { conn = P.conn, cmd = cmd }
    end
    E.Capability = CAPABILITY
    -- Talky keeps no global ModData (R9): any use is a mistake
    E.ModData = setmetatable({}, { __index = function(_, k)
        return function() H.misuse(P, "ModData." .. tostring(k) .. " (Talky must not use global ModData)") end
    end })
    -- translations (UI.json)
    P.MISSING, P.BAD_ARGS = {}, {}
    E.getTextOrNull = function(key, ...)
        local cur = H.UI[P.lang] or H.UI.EN
        local v = cur[key]
        if v == nil then v = H.UI.EN[key] end
        if v == nil then
            P.MISSING[key] = true
            return nil
        end
        local args = { ... }
        v = string.gsub(v, "%%(%d)", function(d)
            local a = args[tonumber(d)]
            if a == nil then
                P.BAD_ARGS[key] = true
                return "%" .. d
            end
            return tostring(a)
        end)
        return v
    end
    E.getText = function(key, ...) return E.getTextOrNull(key, ...) or key end
    E.Translator = { getLanguage = function() return { name = function() return P.lang end } end }
end

local ALLOWED_EXT = { ini = true, cfg = true, txt = true, log = true, json = true }

-- Zomboid/Lua of the machine. In a hosted game the coop server and the host's client share it.
local function installFiles(P)
    local E = P.E
    E.getFileReader = function(fname)
        P.io[#P.io + 1] = "read " .. tostring(fname)
        local content = P.fs[fname]
        if content == nil then return nil end
        local lines, i = H.splitLines(content), 0
        return java("BufferedReader", { readLine = function() i = i + 1; return lines[i] end, close = noop })
    end
    -- 42.20.1+: only ini, cfg, txt, log and json files (LuaManager.ALLOWED_FILE_EXTENSIONS)
    E.getFileWriter = function(fname, create, append)
        P.io[#P.io + 1] = "write " .. tostring(fname)
        local ext = string.match(tostring(fname), "%.(%w+)$")
        if not ext or not ALLOWED_EXT[ext] then
            P.refusedWrites[#P.refusedWrites + 1] = fname
            return nil
        end
        local buf = ""
        if append then buf = P.fs[fname] or "" end
        return java("LuaFileWriter", {
            write = function(_, s) buf = buf .. tostring(s) end,
            writeln = function(_, s) buf = buf .. tostring(s) .. "\n" end,
            close = function() P.fs[fname] = buf end,
        })
    end
end

local function installWorld(P)
    local E, W, kind = P.E, P.world, P.kind
    local function onClient(what)
        if kind == "client" then
            H.misuse(P, what .. " on an MP client (the server owns the world)")
            return true
        end
        return false
    end
    local function finite(what, ...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if bad(v) then corrupt(P, what .. " argument " .. i .. " = " .. tostring(v)); return false end
        end
        return true
    end
    local function ints(what, ...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if not isInt(v) then H.misuse(P, what .. " argument " .. i .. " is not an integer: " .. tostring(v)); return false end
        end
        return true
    end
    E.getCell = function()
        if kind == "client" then
            local list = {}
            local S = P.conn and P.conn.server
            for _, z in ipairs(S and S.world.zombies or {}) do
                if not z.dead then list[#list + 1] = mirror(P, z) end
            end
            return java("IsoCell", {
                getZombieList = function() return H.list(list) end,
                getGridSquare = function(_, x, y, z) return H.clientSquare(P, x, y, z) end,
            })
        end
        return W.cell
    end
    -- B42: x, y, z, count, outfit, femaleChance, crawler, isFallOnFront, isFakeDead, knockedDown,
    -- isInvulnerable, isSitting, health, isRecordingAnims, heightOffset, isRagdolling, onFire
    E.addZombiesInOutfit = function(...)
        local n = select("#", ...)
        local x, y, z, count, outfit, female, crawler, _, fakeDead, _, _, _, health, _, height, _, onFire = ...
        if n ~= 17 then H.misuse(P, "addZombiesInOutfit with " .. n .. " arguments, 17 expected") end
        if onClient("addZombiesInOutfit") then return H.list({}) end
        W.spawnCalls = W.spawnCalls + 1
        if not finite("addZombiesInOutfit", x, y, z, count, female, health, height) then return H.list({}) end
        -- LuaManager.GlobalObject.addZombiesInOutfit (17 args) returns an empty list when the
        -- world has zombies turned off (IsoWorld.getZombiesDisabled, offsets 9-35) or when
        -- there is no square there (offsets 36-63)
        if W.zombiesDisabled then return H.list({}) end
        if W.square(x, y, z) == nil then return H.list({}) end
        ints("addZombiesInOutfit", x, y, z, count)
        if outfit ~= nil and type(outfit) ~= "string" then H.misuse(P, "addZombiesInOutfit outfit is not a string") end
        for i = 1, select("#", crawler, fakeDead, onFire) do
            if type((select(i, crawler, fakeDead, onFire))) ~= "boolean" then H.misuse(P, "addZombiesInOutfit flag is not a boolean") end
        end
        local list = {}
        for _ = 1, count do
            list[#list + 1] = W.newZombie(x, y, z, { outfit = outfit, crawler = crawler, fakeDead = fakeDead, health = health, onFire = onFire })
        end
        return H.list(list)
    end
    E.addSound = function(src, x, y, z, radius, volume)
        if onClient("addSound") then return end
        if finite("addSound", x, y, z, radius, volume) then ints("addSound", x, y, z, radius, volume) end
        W.sounds[#W.sounds + 1] = { x = x, y = y, z = z, r = radius, v = volume }
    end
    -- GameServer.PlayWorldSoundServer: returns at once unless on a server
    E.playServerSound = function(name, sq)
        if kind ~= "server" then H.misuse(P, "playServerSound outside a server (does nothing)"); return end
        W.serverSounds[#W.serverSounds + 1] = name
    end
    -- server: a random connected player, dead or alive (Lua cannot aim it)
    E.testHelicopter = function()
        if onClient("testHelicopter") then return end
        local target
        if kind == "server" then
            local list = E.getOnlinePlayers()
            if list:size() > 0 then target = list:get(math.floor(H.random() * list:size())):getUsername() end
        else
            target = P.localPlayer and P.localPlayer:getUsername()
        end
        W.heli[#W.heli + 1] = { target = target }
    end
    local thunder = java("ThunderStorm", {
        -- server: filled and sent with the climate packet; single player: queued; MP client: nothing
        triggerThunderEvent = function(_, x, y, strike, light, rumble)
            if kind == "client" then H.misuse(P, "triggerThunderEvent on an MP client (does nothing)"); return end
            finite("triggerThunderEvent", x, y)
            W.thunder[#W.thunder + 1] = { x = x, y = y, strike = strike, transmitted = kind == "server" }
        end,
    })
    local function serverOnly(what)
        if kind ~= "server" then H.misuse(P, what .. " outside a server (does nothing)"); return false end
        return true
    end
    local climate = java("ClimateManager", {
        -- returns on a client; stops the period, and transmits on a server
        stopWeatherAndThunder = function()
            if kind == "client" then H.misuse(P, "stopWeatherAndThunder on an MP client (does nothing)"); return end
            W.weatherRunning = false
            W.weatherStops = W.weatherStops + 1
            if kind == "server" then W.climatePackets = W.climatePackets + 1 end
        end,
        -- false on a client and while a weather period runs
        triggerCustomWeatherStage = function(_, stage, hours)
            if kind == "client" or W.weatherRunning then return false end
            if not finite("triggerCustomWeatherStage", stage, hours) then return false end
            ints("triggerCustomWeatherStage stage", stage)
            W.weatherRunning = true
            W.weather[#W.weather + 1] = { stage = stage, hours = hours }
            return true
        end,
        transmitServerTriggerStorm = function(_, hours)
            if not serverOnly("transmitServerTriggerStorm") then return end
            finite("transmitServerTriggerStorm", hours)
            W.weatherRunning = true
            W.weather[#W.weather + 1] = { stage = 3, hours = hours, transmitted = true }
        end,
        transmitServerStopWeather = function()
            if serverOnly("transmitServerStopWeather") then W.weatherRunning = false end
        end,
        transmitServerStartRain = function(_, v) if serverOnly("transmitServerStartRain") then W.weatherRunning = true end end,
        transmitServerStopRain = function() if serverOnly("transmitServerStopRain") then W.weatherRunning = false end end,
        transmitServerTriggerLightning = function(_, x, y)
            if serverOnly("transmitServerTriggerLightning") then W.thunder[#W.thunder + 1] = { x = x, y = y, transmitted = true } end
        end,
        getThunderStorm = function() return thunder end,
    })
    E.getClimateManager = function() return climate end
    E.getWorld = function() return java("IsoWorld", { getClimateManager = function() return climate end }) end
    E.getGameTime = function()
        return java("GameTime", {
            setTimeOfDay = function(_, h)
                if onClient("setTimeOfDay") then return end
                if finite("setTimeOfDay", h) then W.times[#W.times + 1] = h end
            end,
            getTimeOfDay = function() return W and W.times[#W.times] or 12 end,
        })
    end
    E.IsoFireManager = {
        -- warns and returns on a client
        StartFire = function(cell, sq, ignite, power, life)
            if kind == "client" then print("The StartFire function was called on Client"); H.misuse(P, "StartFire on an MP client"); return end
            finite("StartFire", power, life)
            W.fires[#W.fires + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
        end,
    }
    E.IsoDirections = {}
    for _, d in ipairs({ "N", "NE", "E", "SE", "S", "SW", "W", "NW" }) do E.IsoDirections[d] = java("IsoDirections", { name = d }) end
    E.addVehicleDebug = function(script, dir, skin, sq)
        if onClient("addVehicleDebug") then return java("BaseVehicle", {}) end
        if not H.isJava(dir, "IsoDirections") then H.misuse(P, "addVehicleDebug without an IsoDirections") end
        W.vehicles[#W.vehicles + 1] = { script = script, x = sq:getX(), y = sq:getY(), z = sq:getZ() }
        return java("BaseVehicle", {})
    end
    -- scripts: a few items (one hidden, one obsolete) and two vehicles
    local ITEMS = { ["Base.Apple"] = {}, ["Base.Bandage"] = {}, ["Base.Katana"] = {}, ["Base.Axe"] = {},
                    ["Base.HiddenThing"] = { hidden = true }, ["Base.OldThing"] = { obsolete = true } }
    local VEHICLES = { ["Base.CarNormal"] = true, ["Base.PickUpTruck"] = true }
    E.getScriptManager = function()
        return java("ScriptManager", {
            FindItem = function(_, t)
                if type(t) ~= "string" then return nil end
                local full = t
                if not string.find(t, "%.") then full = "Base." .. t end
                local it = ITEMS[full]
                if not it then return nil end
                return java("Item", {
                    getFullName = function() return full end,
                    getObsolete = function() return it.obsolete == true end,
                    isHidden = function() return it.hidden == true end,
                })
            end,
            getVehicle = function(_, s)
                if VEHICLES[s] then return java("VehicleScript", {}) end
                return nil
            end,
        })
    end
    E.sendAddItemsToContainer = function(inv, items)
        if serverOnly("sendAddItemsToContainer") then W.itemSyncs = W.itemSyncs + 1 end
    end
    -- XP: nothing on an MP client
    E.addXp = function(player, perk, amount)
        if kind == "client" then H.misuse(P, "addXp on an MP client (does nothing)"); return end
        if not H.isJava(perk, "Perk") then H.misuse(P, "addXp with a non-Perk " .. tostring(perk)); return end
        if not finite("addXp", amount) then return end
        W.xp[#W.xp + 1] = { user = player:getUsername(), perk = perk.name, amount = amount }
    end
    local none = java("Perk", { name = "None" })
    function none:getParent() return none end
    local function perk(name, parent)
        local pk = java("Perk", { name = name })
        function pk:getParent() return parent or none end
        function pk:getName() return name end
        return pk
    end
    local cats = {}
    E.Perks = { None = none, MAX = perk("MAX") }
    for _, c in ipairs({ "Agility", "Combat", "Crafting", "Firearm", "Passiv", "Survivalist" }) do
        cats[c] = perk(c)
        E.Perks[c] = cats[c]
    end
    for name, parent in pairs({ Strength = "Passiv", Fitness = "Passiv", Sprinting = "Agility", Axe = "Combat",
                                Aiming = "Firearm", Cooking = "Crafting", Farming = "Survivalist" }) do
        E.Perks[name] = perk(name, cats[parent])
    end
    E.Perks.FromString = function(s) return E.Perks[s] end
    E.CharacterStat = {}
    local masks = {}
    for i, s in ipairs(CHARACTER_STATS) do
        E.CharacterStat[s] = java("CharacterStat", { name = s })
        masks[s] = 2 ^ (i - 1)
    end
    E.SyncPlayerStatsPacket = { getBitMaskForStat = function(stat)
        if not H.isJava(stat, "CharacterStat") then H.misuse(P, "getBitMaskForStat with a non-CharacterStat") return 0 end
        return masks[stat.name]
    end }
    E.syncPlayerStats = function(player, mask)
        if serverOnly("syncPlayerStats") then
            if not isInt(mask) or mask <= 0 then H.misuse(P, "syncPlayerStats with mask " .. tostring(mask)) end
            W.statSyncs[#W.statSyncs + 1] = { user = player:getUsername(), mask = mask }
        end
    end
    -- HaloTextHelper: on a server it sends a packet to that player; local elsewhere
    E.HaloTextHelper = { addText = function(player, text)
        P.halos[#P.halos + 1] = { user = player and player:getUsername(), text = text, side = kind }
    end }
    -- the "say" chat only exists in multiplayer
    E.processSayMessage = function(text)
        if kind ~= "client" then H.misuse(P, "processSayMessage without the multiplayer chat"); return end
        P.chat[#P.chat + 1] = text
    end
    E.SafeHouse = {
        getSafeHouse = function(sq)
            if not W then return nil end
            local x, y = sq:getX(), sq:getY()
            for _, sh in ipairs(W.safehouses) do
                if x >= sh.x1 and x <= sh.x2 and y >= sh.y1 and y <= sh.y2 then
                    return java("SafeHouse", { playerAllowed = function(_, p)
                        return sh.members[string.lower(p:getUsername())] == true
                    end })
                end
            end
            return nil
        end,
    }
end

---------------------------------------------------------------- network

H.net = { up = {}, down = {}, sp = {}, cmds = {}, held = {}, lost = 0, nullPlayer = 0, stale = 0, javaDropped = 0, javaSent = 0,
          dropUp = nil, dropDown = nil, hold = nil, reverse = false }

-- args as the receiver gets them: written and read back by the game's serializer; a
-- top-level empty table becomes nil.
function H.netArgs(P, args)
    if type(args) ~= "table" then return nil end
    local copy, dropped, sent = __netCopy(args)
    if dropped and dropped > 0 then
        H.net.javaDropped = H.net.javaDropped + dropped
        H.misuse(P, dropped .. " game object(s) in network args (the game drops them)")
    end
    if sent and sent > 0 then
        -- delivered (tests use it to send what a modified client could), but Talky never should
        H.net.javaSent = (H.net.javaSent or 0) + sent
        H.misuse(P, sent .. " game object(s) in network args (the game sends them)")
    end
    if copy == nil or H.count(copy) == 0 then return nil end
    return copy
end

local function installNet(P)
    local E, kind = P.E, P.kind
    -- sendClientCommand(player, module, command, args) or (module, command, args)
    E.sendClientCommand = function(a, b, c, d)
        local player, module, command, args
        if type(a) == "string" then
            if kind == "server" then error("IllegalStateException: sendClientCommand(module, command, args) on the server") end
            player, module, command, args = P.localPlayer, a, b, c
        else
            player, module, command, args = a, b, c, d
        end
        if kind == "server" then
            -- fires OnClientCommand in this process
            H.fire(P, "OnClientCommand", module, command, player, H.netArgs(P, args))
            return
        end
        if kind == "sp" then
            -- SinglePlayerClient: serialised, delivered on the next frame
            H.net.sp[#H.net.sp + 1] = { proc = P, player = player, module = module, command = command, args = H.netArgs(P, args) }
            return
        end
        if player == nil or player ~= P.localPlayer then return end
        if not P.conn or not P.conn.connected or not P.conn.ingame then
            P.droppedUp = (P.droppedUp or 0) + 1
            return
        end
        H.net.up[#H.net.up + 1] = { conn = P.conn, module = module, command = command, args = H.netArgs(P, args) }
        P.sent[command] = (P.sent[command] or 0) + 1
    end
    -- sendServerCommand(module, command, args) to every client, or (player, module, command, args)
    E.sendServerCommand = function(a, b, c, d)
        if kind ~= "server" then H.misuse(P, "sendServerCommand outside a server (does nothing)"); return end
        if type(a) == "string" then
            for _, conn in ipairs(P.conns) do
                if conn.connected and conn.serverPlayer then
                    H.net.down[#H.net.down + 1] = { conn = conn, module = a, command = b, args = H.netArgs(P, c), broadcast = true }
                end
            end
            return
        end
        for _, conn in ipairs(P.conns) do
            if conn.connected and conn.serverPlayer ~= nil and conn.serverPlayer == a then
                H.net.down[#H.net.down + 1] = { conn = conn, module = b, command = c, args = H.netArgs(P, d) }
                return
            end
        end
        -- GameServer.sendServerCommand(IsoPlayer...): no connection for that object, nothing sent
        H.net.stale = H.net.stale + 1
    end
end

-- Server side of SendCommandToServer: /setaccesslevel works for admins and, through the
-- coop-host bypass (GameServer.handleServerCommand), for the host of a hosted game.
local function serverCommand(conn, cmd)
    local S = conn.server
    local name, level = string.match(cmd, '^/setaccesslevel "([^"]+)" (%w+)$')
    if not name then S.adminLog[#S.adminLog + 1] = "unknown command " .. cmd; return end
    local sender = conn.account
    local caps = H.ROLE_CAPS[sender.role or ""] or {}
    if not conn.host and not caps.ChangeAccessLevel then
        S.adminLog[#S.adminLog + 1] = "refused " .. cmd .. " from " .. sender.username
        return
    end
    local target = S.accounts[string.lower(name)]
    if not target or not H.ROLE_CAPS[level] then S.adminLog[#S.adminLog + 1] = "bad " .. cmd; return end
    target.role = level
    S.adminLog[#S.adminLog + 1] = "role of " .. target.username .. " = " .. level
end

local function reversed(list)
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end
    return out
end

-- Delivers what was sent during the tick. Answers sent while handling go to the next tick.
function H.deliver()
    local up, down, sp, cmds = H.net.up, H.net.down, H.net.sp, H.net.cmds
    H.net.up, H.net.down, H.net.sp, H.net.cmds = {}, {}, {}, {}
    if H.net.reverse then up, down = reversed(up), reversed(down) end
    for _, m in ipairs(sp) do
        H.fire(m.proc, "OnClientCommand", m.module, m.command, m.player, m.args)
    end
    for _, c in ipairs(cmds) do serverCommand(c.conn, c.cmd) end
    for _, m in ipairs(up) do
        local conn = m.conn
        if H.net.dropUp and H.net.dropUp(m) then
            H.net.lost = H.net.lost + 1
        elseif not conn.connected then
            H.net.lost = H.net.lost + 1
        elseif not conn.serverPlayer then
            -- GameServer.receiveClientCommand: "player is null", dropped
            H.net.nullPlayer = H.net.nullPlayer + 1
        else
            H.fire(conn.server, "OnClientCommand", m.module, m.command, conn.serverPlayer, m.args)
        end
    end
    for _, m in ipairs(down) do
        local P = m.conn.client
        if H.net.dropDown and H.net.dropDown(m) then
            H.net.lost = H.net.lost + 1
        elseif H.net.hold and H.net.hold(m) then
            H.net.held[#H.net.held + 1] = m
        elseif m.conn.connected and P.alive then
            P.received[#P.received + 1] = m.command
            H.fire(P, "OnServerCommand", m.module, m.command, m.args)
        end
    end
end

-- Messages kept back by H.net.hold, delivered now (out of order).
function H.releaseHeld()
    local held = H.net.held
    H.net.held = {}
    for _, m in ipairs(held) do
        if m.conn.connected and m.conn.client.alive then
            m.conn.client.received[#m.conn.client.received + 1] = m.command
            H.fire(m.conn.client, "OnServerCommand", m.module, m.command, m.args)
        end
    end
end

---------------------------------------------------------------- UI (single player and clients)

local function installUI(P)
    local E = P.E
    local ui = { TEXTS = {}, BUTTONS = {}, ENTRIES = {}, DRAWN = {} }
    P.ui = ui
    local function record(t)
        if t ~= nil then ui.TEXTS[#ui.TEXTS + 1] = tostring(t) end
    end
    E.UIFont = { Small = "Small", Medium = "Medium", Large = "Large" }
    local TM = {
        getFontHeight = function() return 14 end,
        MeasureStringX = function(_, _, s) return string.len(tostring(s)) * 7 end,
        DrawStringCentre = function(_, font, x, y, text) ui.DRAWN[#ui.DRAWN + 1] = tostring(text) end,
    }
    E.getTextManager = function() return TM end
    local CORE = {
        getScreenWidth = function() return 1920 end,
        getScreenHeight = function() return 1080 end,
        getKey = function() return 0 end,
    }
    E.getCore = function() return CORE end
    E.Clipboard = { setClipboard = function(s) ui.CLIPBOARD = s end }
    E.Keyboard = { KEY_F8 = 66 }
    E.keyBinding = {}
    E.isoToScreenX = function() return 10 end
    E.isoToScreenY = function() return 10 end

    local Base = {}
    Base.__index = Base
    function Base:derive(name)
        local cls = {}
        cls.__index = cls
        cls.Type = name
        return setmetatable(cls, { __index = self })
    end
    function Base:new(x, y, w, h)
        local o = { x = x, y = y, width = w, height = h, children = {} }
        return setmetatable(o, self)
    end
    function Base:initialise() end
    function Base:instantiate() end
    function Base:addChild(c) table.insert(self.children, c) end
    function Base:removeChild() end
    function Base:addToUIManager()
        if self.createChildren and not self.__created then
            self.__created = true
            self:createChildren()
        end
    end
    function Base:removeFromUIManager() end
    function Base:setVisible(v) self.visible = v end
    function Base:isVisible() return self.visible ~= false end
    function Base:setAlwaysOnTop() end
    function Base:setResizable() end
    function Base:setTitle(t) self.title = t; record(t) end
    function Base:titleBarHeight() return 16 end
    function Base:drawRect() end
    function Base:drawText(t) record(t) end
    function Base:createChildren() end
    function Base:prerender() end

    E.ISCollapsableWindow = Base:derive("ISCollapsableWindow")
    E.ISPanel = Base:derive("ISPanel")

    local ISButton = Base:derive("ISButton")
    function ISButton:new(x, y, w, h, title, target, onclick)
        local o = Base.new(self, x, y, w, h)
        o.title, o.target, o.onclick = title, target, onclick
        record(title)
        table.insert(ui.BUTTONS, o)
        return o
    end
    E.ISButton = ISButton

    local ISLabel = Base:derive("ISLabel")
    function ISLabel:new(x, y, h, name)
        local o = Base.new(self, x, y, 0, h)
        o.name = name
        record(name)
        return o
    end
    function ISLabel:setName(n) self.name = n; record(n) end
    E.ISLabel = ISLabel

    local ISTextEntryBox = Base:derive("ISTextEntryBox")
    function ISTextEntryBox:new(text, x, y, w, h)
        local o = Base.new(self, x, y, w, h)
        o.text = text
        table.insert(ui.ENTRIES, o)
        return o
    end
    -- like the game: a masked box shows stars, getInternalText() keeps the real text
    function ISTextEntryBox:getText()
        if self.masked then return string.rep("*", string.len(tostring(self.text or ""))) end
        return self.text
    end
    function ISTextEntryBox:getInternalText() return self.text end
    function ISTextEntryBox:setText(t) self.text = t end
    function ISTextEntryBox:setMasked(b) self.masked = b end
    function ISTextEntryBox:isMasked() return self.masked == true end
    function ISTextEntryBox:setOnlyNumbers() end
    function ISTextEntryBox:setMultipleLine() end
    function ISTextEntryBox:setMaxLines() end
    function ISTextEntryBox:addScrollBars() end
    E.ISTextEntryBox = ISTextEntryBox

    local ISComboBox = Base:derive("ISComboBox")
    function ISComboBox:new(x, y, w, h, target, onchange)
        local o = Base.new(self, x, y, w, h)
        o.options, o.selected, o.target, o.onchange = {}, 1, target, onchange
        return o
    end
    function ISComboBox:addOptionWithData(text, data)
        table.insert(self.options, { text = text, data = data })
        record(text)
    end
    function ISComboBox:getOptionData(i)
        local opt = self.options[i]
        return opt and opt.data
    end
    E.ISComboBox = ISComboBox

    local ISTickBox = Base:derive("ISTickBox")
    function ISTickBox:new(x, y, w, h, name, target, onchange)
        local o = Base.new(self, x, y, w, h)
        o.sel = {}
        return o
    end
    function ISTickBox:addOption(t) record(t) end
    function ISTickBox:setSelected(i, v) self.sel[i] = v end
    function ISTickBox:isSelected(i) return self.sel[i] == true end
    E.ISTickBox = ISTickBox

    local ISScrollingListBox = Base:derive("ISScrollingListBox")
    function ISScrollingListBox:new(x, y, w, h)
        local o = Base.new(self, x, y, w, h)
        o.items, o.selected = {}, 1
        return o
    end
    function ISScrollingListBox:addItem(text, item)
        table.insert(self.items, { text = text, item = item })
        record(text)
    end
    function ISScrollingListBox:setOnMouseDownFunction() end
    function ISScrollingListBox:setOnMouseDoubleClick() end
    E.ISScrollingListBox = ISScrollingListBox
end

---------------------------------------------------------------- loading the mod

-- Vanilla files Talky requires; the stubs above stand in for them.
local function vanilla(mod) return string.sub(mod, 1, 5) == "ISUI/" end

local function runFile(P, rel, mod)
    local fn, err = __load(P.E, ROOT .. "/" .. rel, rel)
    if not fn then
        if err then P.errors[#P.errors + 1] = "compile " .. rel .. ": " .. tostring(err) end
        return false
    end
    P.loaded[mod] = true
    P.files[#P.files + 1] = rel
    local ok, res = pcall(fn)
    if not ok then
        P.errors[#P.errors + 1] = "load " .. rel .. ": " .. tostring(res)
        print("        error loading " .. rel .. " in " .. P.name .. ": " .. tostring(res))
    else
        P.returns[mod] = res
    end
    return true
end

local function exists(rel) return __readFile(ROOT .. "/" .. rel) ~= nil end

-- require, searching the folders of the process (LuaManager.paths: shared, client, server).
local function installRequire(P)
    local dirs = { "shared", "client", "server" }
    P.E.require = function(mod)
        if type(mod) ~= "string" then H.misuse(P, "require of a non-string") return nil end
        if P.loaded[mod] then return P.returns[mod] end
        if vanilla(mod) then
            P.loaded[mod] = true
            return nil
        end
        for _, dir in ipairs(dirs) do
            local rel = dir .. "/" .. mod .. ".lua"
            if exists(rel) then
                if dir == "client" and P.kind == "server" then
                    -- the server would RUN this client file (its path is registered for require)
                    P.badRequires[#P.badRequires + 1] = mod
                    P.loaded[mod] = true
                    return nil
                end
                P.loaded[mod] = true
                runFile(P, rel, mod)
                return P.returns[mod]
            end
        end
        P.missingRequires[#P.missingRequires + 1] = mod
        return nil
    end
end

-- Loads every file of one folder, in the game's order (sorted, case-insensitive).
function H.loadDir(P, dir)
    local prefix = dir .. "/"
    for _, rel in ipairs(__LUA_FILES) do
        if string.sub(rel, 1, string.len(prefix)) == prefix then
            P.E.require(string.sub(rel, string.len(prefix) + 1, string.len(rel) - 4))
        end
    end
end

-- One simulated game process. kind: "sp" | "server" | "client".
-- opts: fs (Zomboid/Lua files), world, sandbox (SandboxVars), lang ("EN" | "FR")
function H.process(name, kind, opts)
    opts = opts or {}
    local P = { name = name, kind = kind, fs = opts.fs or {}, world = opts.world, alive = true, paused = false,
                handlers = {}, misuse = {}, errors = {}, unknown = {}, io = {}, refusedWrites = {}, log = {},
                loaded = {}, returns = {}, files = {}, badRequires = {}, missingRequires = {}, corrupt = {},
                lang = opts.lang or "EN", sent = {}, received = {}, chat = {}, halos = {}, commands = {},
                conns = {}, accounts = {}, adminLog = {}, ui = {} }
    P.E = __newEnv()
    P.fire = function(ev, ...) H.fire(P, ev, ...) end
    installEvents(P)
    installCore(P)
    installFiles(P)
    installWorld(P)
    installNet(P)
    installRequire(P)
    if kind ~= "server" then installUI(P) end
    P.E.SandboxVars = opts.sandbox or { Talky = {} }
    -- reads of globals nobody defined (a game API the harness lacks, or a client global read
    -- on the server...)
    setmetatable(P.E, { __index = function(_, k)
        P.unknown[k] = (P.unknown[k] or 0) + 1
        return nil
    end })
    H.procs[#H.procs + 1] = P
    return P
end

-- Single player game: shared/ and client/ at boot, server/ when the game starts.
function H.newSP(acc, opts)
    opts = opts or {}
    local W = H.world("sp")
    local P = H.process(opts.name or "SP", "sp", { fs = opts.fs, world = W, sandbox = opts.sandbox, lang = opts.lang })
    P.acc = acc
    P.localPlayer = H.player(acc, P)
    H.loadDir(P, "shared")
    H.loadDir(P, "client")
    P.fire("OnGameBoot")
    if opts.beforeStart then opts.beforeStart(P) end
    -- noServer: the server/ files failed to load (a Lua error in another mod, say)
    if not opts.noServer then H.loadDir(P, "server") end
    P.fire("OnInitGlobalModData", true)
    P.fire("OnGameStart")
    return P
end

-- Dedicated server, or the coop server of a hosted game (opts.fs = the host's folder).
function H.newServer(name, opts)
    opts = opts or {}
    local W = H.world("server")
    local S = H.process(name, "server", { fs = opts.fs, world = W, sandbox = opts.sandbox })
    S.serverName = opts.serverName or "talkytest"
    H.loadDir(S, "shared")
    H.loadDir(S, "server")
    S.fire("OnInitGlobalModData", true)
    S.fire("OnServerStarted")
    return S
end

-- A player joins: the client Lua starts again with the server's mods (shared, client, then
-- server/), OnGameStart fires; the server has an IsoPlayer for the connection only after
-- opts.joinDelayMs (commands sent before are dropped: "player is null").
function H.newClient(name, acc, S, opts)
    opts = opts or {}
    local P = H.process(name, "client", { fs = opts.fs, lang = opts.lang })
    P.acc = acc
    H.loadDir(P, "shared")
    H.loadDir(P, "client")
    P.fire("OnGameBoot")
    local conn = { client = P, server = S, account = acc, host = opts.host == true, connected = true, ingame = false,
                   serverPlayer = nil, readyAt = NOW + (opts.joinDelayMs or 300) }
    P.conn = conn
    S.conns[#S.conns + 1] = conn
    S.accounts[string.lower(acc.username)] = acc
    H.loadDir(P, "server")
    P.localPlayer = H.player(acc, P)
    P.fire("OnInitGlobalModData", false)
    conn.ingame = true
    P.fire("OnGameStart")
    return P
end

-- The player quits: the client process ends, the server drops the IsoPlayer.
function H.leave(P)
    if P.conn then
        P.conn.connected = false
        P.conn.serverPlayer = nil
    end
    P.alive = false
end

-- Same account and same Zomboid/Lua, new game process and new IsoPlayer objects.
function H.rejoin(P, opts)
    opts = opts or {}
    H.leave(P)
    return H.newClient(opts.name or (P.name .. "'"), P.acc, P.conn.server, { fs = P.fs, lang = P.lang, host = P.conn.host, joinDelayMs = opts.joinDelayMs })
end

---------------------------------------------------------------- time

-- One tick of every process (servers first), then the network delivers.
-- Single player: no OnTick while the game is paused (GameWindow.logic skips the state update,
-- only OnTickEvenPaused fires). Server: no OnTick while it is paused, i.e. empty with
-- PauseEmpty on (IngameState.updateInternal, offsets 888-943); it still takes connections and
-- handles client commands.
function H.tick(n, dt)
    for _ = 1, n or 1 do
        NOW = NOW + (dt or 100)
        H.tickNo = H.tickNo + 1
        for _, P in ipairs(H.procs) do
            if P.alive and P.kind == "server" then
                for _, c in ipairs(P.conns) do
                    if c.connected and not c.serverPlayer and NOW >= c.readyAt then c.serverPlayer = H.player(c.account, P) end
                end
                if not P.E.isGamePaused() then P.fire("OnTick", H.tickNo) end
            end
        end
        for _, P in ipairs(H.procs) do
            if P.alive and P.kind ~= "server" and not (P.kind == "sp" and P.paused) then P.fire("OnTick", H.tickNo) end
        end
        H.deliver()
    end
end

-- Lets ms go by, one tick per step ms (default 1 s).
function H.wait(ms, step)
    step = step or 1000
    local n = math.floor(ms / step)
    if n < 1 then n = 1 end
    H.tick(n, step)
end

---------------------------------------------------------------- bridge side (what the bridge writes and reads)

-- A job as the bridge writes it in talky_inbox.jsonl.
function H.job(t)
    t.workflow = t.workflow or ("wf" .. tostring(t.seq))
    t.user = t.user or "viewer"
    t.createdAt = t.createdAt or NOW
    t.expiresAt = t.expiresAt or (t.createdAt + 900000)
    t.steps = t.steps or { { action = "notify", text = "job " .. tostring(t.seq) } }
    return t
end

function H.setInbox(P, jobs)
    local out = {}
    for _, j in ipairs(jobs) do out[#out + 1] = H.JSON.encode(H.job(j)) end
    P.fs["talky_inbox.jsonl"] = #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

function H.addInbox(P, jobs)
    local text = P.fs["talky_inbox.jsonl"] or ""
    for _, j in ipairs(jobs) do text = text .. H.JSON.encode(H.job(j)) .. "\n" end
    P.fs["talky_inbox.jsonl"] = text
end

-- talky_ack.txt as bridge/lib/ipc.js parseAck reads it: S, and the seqs after it (the last
-- one only when a space or a line end follows it).
function H.parseAck(text)
    text = text or ""
    local tokens = {}
    for tok in string.gmatch(text, "%S+") do tokens[#tokens + 1] = tok end
    local head = string.match(text, "^%s*(%d+)")
    local mark = head and tonumber(head) or 0
    local extra = {}
    if not tokens[1] or not string.match(tokens[1], "^%d+$") then return mark, extra end
    local complete = string.match(text, "%s$") ~= nil
    local last = complete and #tokens or (#tokens - 1)
    for i = 2, last do
        local n = string.match(tokens[i], "^%d+$") and tonumber(tokens[i])
        if n and n > mark then extra[#extra + 1] = n end
    end
    table.sort(extra)
    return mark, extra
end

-- What the bridge does every 500 ms: drops the acked and expired jobs from the inbox.
function H.bridgeApplyAck(P)
    local mark, extra = H.parseAck(P.fs["talky_ack.txt"])
    local acked = {}
    for _, s in ipairs(extra) do acked[s] = true end
    local keep = {}
    for _, line in ipairs(H.splitLines(P.fs["talky_inbox.jsonl"] or "")) do
        local j = line ~= "" and H.JSON.tryDecode(line)
        if type(j) == "table" and j.seq > mark and not acked[j.seq] and j.expiresAt > NOW then keep[#keep + 1] = line end
    end
    P.fs["talky_inbox.jsonl"] = #keep > 0 and (table.concat(keep, "\n") .. "\n") or ""
    return mark, extra
end

function H.inboxSeqs(P)
    local out = {}
    for _, line in ipairs(H.splitLines(P.fs["talky_inbox.jsonl"] or "")) do
        local j = line ~= "" and H.JSON.tryDecode(line)
        if type(j) == "table" then out[#out + 1] = j.seq end
    end
    return out
end

-- talky_outbox.txt: { { event, data, ts } }
function H.outbox(P)
    local out = {}
    for _, line in ipairs(H.splitLines(P.fs["talky_outbox.txt"] or "")) do
        if line ~= "" then
            local e = H.JSON.tryDecode(line)
            if type(e) == "table" then out[#out + 1] = e else out[#out + 1] = { event = "?bad line", data = line } end
        end
    end
    return out
end

function H.events(P, name)
    local out = {}
    for _, e in ipairs(H.outbox(P)) do
        if e.event == name then out[#out + 1] = e end
    end
    return out
end

function H.clearOutbox(P) P.fs["talky_outbox.txt"] = nil end

---------------------------------------------------------------- bridge side, server mode

-- talky_status.json as a running bridge writes it (server mode unless opts.mode says otherwise).
function H.bridgeUp(P, opts)
    opts = opts or {}
    P.fs["talky_status.json"] = H.JSON.encode({ ts = opts.ts or NOW, version = opts.version or "0.5.0", protocol = opts.protocol or 3,
        mode = opts.mode or "server", testNonce = opts.nonce or "srv-nonce", port = opts.port or 7420, session = "0123456789abcdef",
        publicUrl = opts.publicUrl or "", pending = opts.pending or 0, lastAck = 0, webhooks = { "follow" }, hookTokens = {},
        streamers = #(P.streamers or {}), recent = opts.recent or {} })
end

-- Tokens as the bridge draws them: 48 hexadecimal characters, a new one each time.
local tokenNo = 0
function H.newToken()
    tokenNo = tokenNo + 1
    return "c0ffee" .. string.rep("0", 36) .. string.sub("000000" .. tostring(tokenNo), -6)
end

-- talky_streamers.json from P.streamers ({ { name, token } }), as bridge.js writes it.
function H.writeStreamers(P)
    P.streamersRev = (P.streamersRev or 0) + 1
    local list = {}
    for i, s in ipairs(P.streamers or {}) do list[i] = { name = s.name, token = s.token, createdAt = NOW } end
    P.fs["talky_streamers.json"] = H.JSON.encode({ rev = P.streamersRev, streamers = list })
end

function H.setStreamers(P, names)
    P.streamers = {}
    for _, n in ipairs(names) do P.streamers[#P.streamers + 1] = { name = n, token = H.newToken() } end
    H.writeStreamers(P)
end

function H.tokenOf(P, name)
    for _, s in ipairs(P.streamers or {}) do
        if string.lower(s.name) == string.lower(name) then return s.token end
    end
    return nil
end

-- What the bridge does with the streamer requests of the outbox (bridge.js streamerRequest):
-- streamer_add / streamer_remove / streamer_token, then talky_streamers.json written again. The
-- other lines stay. Returns the requests handled, as "op:name".
function H.bridgeRequests(P)
    local keep, done = {}, {}
    for _, line in ipairs(H.splitLines(P.fs["talky_outbox.txt"] or "")) do
        local e = line ~= "" and H.JSON.tryDecode(line)
        local op = type(e) == "table" and type(e.event) == "string" and string.match(e.event, "^streamer_(%a+)$")
        if op then
            local name = e.data and e.data.name
            P.streamers = P.streamers or {}
            local found
            for i, s in ipairs(P.streamers) do if string.lower(s.name) == string.lower(tostring(name)) then found = i end end
            if op == "add" and not found then P.streamers[#P.streamers + 1] = { name = name, token = H.newToken() }
            elseif op == "remove" and found then table.remove(P.streamers, found)
            elseif op == "token" and found then P.streamers[found].token = H.newToken() end
            done[#done + 1] = op .. ":" .. tostring(name)
        elseif line ~= "" then
            keep[#keep + 1] = line
        end
    end
    P.fs["talky_outbox.txt"] = #keep > 0 and (table.concat(keep, "\n") .. "\n") or nil
    if #done > 0 then H.writeStreamers(P) end
    return done
end

-- Every message a client process receives from the server, with its args (tests read them).
function H.recordDown(P)
    P.down = {}
    local dispatch = P.E.Talky_Client.dispatch
    P.E.Talky_Client.dispatch = function(command, args)
        P.down[#P.down + 1] = { command = command, args = args }
        return dispatch(command, args)
    end
end

-- The text of every value of a table (tokens in args, on screen...).
function H.flatten(v, out, depth)
    out = out or {}
    depth = depth or 0
    if type(v) == "table" and depth < 20 then
        for k, x in pairs(v) do
            out[#out + 1] = tostring(k)
            H.flatten(x, out, depth + 1)
        end
    elseif v ~= nil then
        out[#out + 1] = tostring(v)
    end
    return out
end

function H.contains(v, text)
    for _, s in ipairs(H.flatten(v)) do
        if string.find(s, text, 1, true) then return true end
    end
    return false
end

function H.logHas(P, pattern)
    for _, l in ipairs(P.log) do
        if string.find(l, pattern) then return true end
    end
    return false
end

function H.logCount(P, pattern)
    local n = 0
    for _, l in ipairs(P.log) do
        if string.find(l, pattern) then n = n + 1 end
    end
    return n
end

function H.toastTexts(P)
    local out = {}
    local overlay = rawget(P.E, "Talky_Overlay")
    for _, t in ipairs(overlay and overlay.toasts or {}) do out[#out + 1] = t.text end
    return out
end

function H.hasToast(P, text)
    for _, t in ipairs(H.toastTexts(P)) do
        if t == text then return true end
    end
    return false
end

-- A zombie dies in a world: OnZombieDead on the server (or single player game) and on every
-- client that sees it. times = 2 for a burning zombie (FireCheck fires the event again).
function H.kill(P, zed, attacker, times)
    zed.dead = true
    zed.attacker = attacker
    for _ = 1, times or 1 do
        P.fire("OnZombieDead", zed)
        if P.kind == "server" then
            for _, c in ipairs(P.conns) do
                if c.connected and c.client.alive then c.client.fire("OnZombieDead", mirror(c.client, zed)) end
            end
        end
    end
end

---------------------------------------------------------------- checks every process must pass

-- Globals the mod reads on purpose behind a nil test ("TalkyJson = TalkyJson or {}").
H.optionalGlobals = { sp = { TalkyJson = true }, client = { TalkyJson = true }, server = { TalkyJson = true } }

-- A global of a process, read without counting it as unknown (tests use this).
function H.g(P, name) return rawget(P.E, name) end

function H.hygiene(P, label)
    label = label or P.name
    local function list(t, max)
        local out = {}
        for i = 1, math.min(#t, max or 5) do out[#out + 1] = tostring(t[i]) end
        return table.concat(out, " | ")
    end
    check(#P.errors == 0, label .. ": no Lua error in the mod" .. (#P.errors > 0 and (" (" .. list(P.errors) .. ")") or ""))
    check(#P.misuse == 0, label .. ": no wrong or useless game API call" .. (#P.misuse > 0 and (" (" .. list(P.misuse) .. ")") or ""))
    local corrupt = P.world and P.world.corrupt or P.corrupt
    check(#corrupt == 0, label .. ": no NaN or infinite value reached the game" .. (#corrupt > 0 and (" (" .. list(corrupt) .. ")") or ""))
    local unknown = {}
    for k in pairs(P.unknown) do
        if not (H.optionalGlobals[P.kind] or {})[k] then unknown[#unknown + 1] = k end
    end
    table.sort(unknown)
    check(#unknown == 0, label .. ": every global the mod reads exists" .. (#unknown > 0 and (" (" .. table.concat(unknown, ", ") .. ")") or ""))
    local missing = {}
    for _, m in ipairs(P.missingRequires) do missing[#missing + 1] = m end
    check(#missing == 0 and #P.badRequires == 0, label .. ": every require resolves, none of a client/ file on a server"
        .. ((#missing + #P.badRequires) > 0 and (" (" .. list(missing) .. list(P.badRequires) .. ")") or ""))
    if P.kind == "server" or P.kind == "sp" then
        local other = {}
        for _, e in ipairs(P.io) do
            if not string.match(e, "^%a+ talky_[%w_]+%.%a+$") then other[#other + 1] = e end
        end
        check(#other == 0, label .. ": only Talky's own files are opened in Zomboid/Lua" .. (#other > 0 and (" (" .. list(other) .. ")") or ""))
    else
        -- a client opens no file: the bridge's are the server's (even in a hosted game), and its
        -- display settings come from the server's configuration
        check(#P.io == 0, label .. ": a multiplayer client opens no file" .. (#P.io > 0 and (" (" .. list(P.io) .. ")") or ""))
    end
    check(#P.refusedWrites == 0, label .. ": no file write refused by the game" .. (#P.refusedWrites > 0 and (" (" .. list(P.refusedWrites) .. ")") or ""))
end

-- Forgets every process (each suite starts from scratch).
function H.reset()
    for _, P in ipairs(H.procs) do P.alive = false end
    H.procs = {}
    H.net.up, H.net.down, H.net.sp, H.net.cmds, H.net.held = {}, {}, {}, {}, {}
    H.net.dropUp, H.net.dropDown, H.net.hold, H.net.reverse = nil, nil, nil, false
    H.net.lost, H.net.nullPlayer, H.net.stale, H.net.javaDropped, H.net.javaSent = 0, 0, 0, 0, 0
    H.seed(12345)
end
