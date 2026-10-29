-- Talky server code: what the players' games ask the server (module "Talky"), and the game
-- events the server writes for the bridge itself. The jobs never come from a client: the
-- server reads them from the bridge's files (Talky_Inbox).
-- Commands from the client (every one rate limited, 5 a second per player):
--   status                     -> status { mode, version, admin, streamer, caps, display, bridge, recent? }
--                                 (display: the display settings of talky_config.json)
--   tags                       -> tags { reset, list } (names above zombies, for late joiners)
-- Admins only (role with the CreateHorde capability, checked here at every command):
--   streamers                  -> streamers { list = { { name, token, online } }, port, publicUrl }
--   streamer { op, name }      -> streamerAck { op, name, ok, reason }: op = add | remove | token,
--                                 written to the outbox for the bridge (it draws the tokens)
--   config                     -> config { data } or config { error } (talky_config.json)
--   saveConfig { data }        -> configSaved { ok, error }, and display { settings } to every client
--   test { workflow, vars }    -> testAck { ok, error }: test_workflow in the outbox, for the admin
-- Answers carry reason codes only, never error texts. The tokens of the streamers only ever go
-- to an admin who asked for them.
-- Game events written here (server mode): game_started when the server starts, player_died
-- when a streamer dies (OnPlayerDeath does not exist on a server: read every second).
-- Runs on the server and in single player only (single player only uses "tags" and the local
-- effects: its F8 window reads the bridge's files itself).

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Json"
require "Talky/Talky_Net"
require "Talky/Talky_Actions"
require "Talky/Talky_Files"
require "Talky/Talky_Streamers"
require "Talky/Talky_Tags"
require "Talky/Talky_ServerRunner"
require "Talky/Talky_Inbox"

Talky_Server = {
    buckets = {},     -- [key] = { tokens, at }   5 commands/s, burst 10
    tagsAt = {},      -- [key] = last tags snapshot
    statusCache = nil,
    statusReadAt = nil,
    configText = nil,
    configData = nil,
    lastDead = {},    -- [streamer key] = true while dead (player_died once per death)
    deathCheckAt = nil,
}

local S = Talky_Server

-- Console lines about one player: TalkyNet.logLimited (one per reason a minute, 10 a minute).
function Talky_Server.logFor(key, reason, msg)
    TalkyNet.logLimited(key, reason, msg)
end

---------------------------------------------------------------- permission

-- May this player manage Talky on this server (streamers, workflows, Test now)? The role's
-- CreateHorde capability (admin and moderator by default). Never isAdmin, isCoopHost or
-- hasAdminPower (wrong or client-only on a server), never a name taken from the args.
-- Single player: always.
function Talky_Server.isAdmin(player)
    local mode = TalkyNet.mode()
    if mode == "sp" then return true end
    if mode ~= "server" or not player then return false end
    local ok, res = pcall(function()
        local role = player:getRole()
        return role ~= nil and role:hasCapability(Capability.CreateHorde)
    end)
    return ok and res == true
end

---------------------------------------------------------------- rate limit

local function takeToken(key, t)
    local b = S.buckets[key]
    if not b then
        b = { tokens = 10, at = t }
        S.buckets[key] = b
    end
    local dt = t - b.at
    if dt < 0 then dt = 0 end
    b.tokens = math.min(10, b.tokens + dt * 5 / 1000)
    b.at = t
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

---------------------------------------------------------------- bridge status

-- talky_status.json of the bridge, read at most once a second: { alive, ...fields }.
function Talky_Server.bridgeStatus()
    local t = getTimestampMs()
    if S.statusCache and S.statusReadAt and t - S.statusReadAt < 1000 and t >= S.statusReadAt then return S.statusCache end
    S.statusReadAt = t
    local text = Talky_Files.readText(Talky_Config.statusFile)
    local st = text and TalkyJson.tryDecode(text)
    if type(st) ~= "table" then st = {} end
    local ts = TalkyNet.num(st.ts, 0, 0, 1e15)
    st.alive = ts > 0 and t - ts < 6000 and t - ts > -60000
    S.statusCache = st
    return st
end

-- The last events of the bridge, as plain short data (admins only).
local function recentOf(st)
    local out = {}
    if type(st.recent) ~= "table" then return out end
    for i = 1, math.min(#st.recent, 15) do
        local e = st.recent[i]
        if type(e) == "table" then
            local c = {}
            for _, k in ipairs({ "at", "source", "workflow", "user", "streamer", "skipped", "error", "rejected" }) do
                c[k] = TalkyNet.str(e[k], 120, nil)
            end
            c.job = TalkyNet.seq(e.job)
            out[#out + 1] = c
        end
    end
    return out
end

-- talky_config.json as a table (cached by its text), or nil and a reason.
local function readConfig()
    local text = Talky_Files.readText(Talky_Config.configFile)
    if not text or text == "" then return {} end
    if text ~= S.configText then
        local data = TalkyJson.tryDecode(text)
        if type(data) ~= "table" then return nil, "unreadable" end
        S.configText, S.configData = text, data
    end
    return S.configData
end

-- The display settings of the server's configuration (names above zombies, banners): every
-- client applies them.
function Talky_Server.display()
    local cfg = readConfig()
    return Talky_Config.displayOf(cfg and cfg.settings)
end

---------------------------------------------------------------- commands

local commands = {}

commands.status = function(player, key, args, t)
    local admin = S.isAdmin(player)
    local st = S.bridgeStatus()
    local reply = {
        mode = TalkyNet.mode(),
        version = Talky_Config.version,
        admin = admin,
        streamer = Talky_Streamers.isStreamer(player),
        caps = Talky_Config.publicCaps(),
        display = S.display(),
        bridge = {
            alive = st.alive == true,
            version = TalkyNet.str(st.version, 16, ""),
            mode = TalkyNet.str(st.mode, 16, ""),
            protocol = TalkyNet.int(st.protocol, 1, 0, 1000000),
            port = TalkyNet.int(st.port, 7420, 1, 65535),
        },
    }
    if admin then
        reply.bridge.publicUrl = TalkyNet.str(st.publicUrl, 200, "")
        reply.bridge.pending = TalkyNet.int(st.pending, 0, 0, 1000000)
        reply.recent = recentOf(st)
    end
    TalkyNet.toClient(player, "status", reply)
end

commands.tags = function(player, key, args, t)
    if TalkyNet.mode() ~= "server" then return end
    if S.tagsAt[key] and t - S.tagsAt[key] < 10000 and t >= S.tagsAt[key] then return end
    S.tagsAt[key] = t
    Talky_Tags.sendSnapshot(player)
end

local function refuse(player, what)
    TalkyNet.toClient(player, "refused", { what = what, reason = "not_admin" })
end

commands.streamers = function(player, key, args, t)
    if not S.isAdmin(player) then return refuse(player, "streamers") end
    local list = {}
    for _, e in ipairs(Talky_Streamers.all()) do
        list[#list + 1] = { name = e.name, token = e.token, online = TalkyNet.findPlayer(e.name) ~= nil }
    end
    local st = S.bridgeStatus()
    TalkyNet.toClient(player, "streamers", {
        list = list,
        rev = Talky_Streamers.rev,
        port = TalkyNet.int(st.port, 7420, 1, 65535),
        publicUrl = TalkyNet.str(st.publicUrl, 200, ""),
        bridge = st.alive == true and TalkyNet.str(st.mode, 16, "") == "server",
    })
end

local OPS = { add = "streamer_add", remove = "streamer_remove", token = "streamer_token" }

commands.streamer = function(player, key, args, t)
    if not S.isAdmin(player) then return refuse(player, "streamer") end
    args = type(args) == "table" and args or {}
    local op = TalkyNet.str(args.op, 8, "")
    local event = OPS[op]
    local name = Talky_Streamers.cleanName(args.name)
    local reply = { op = op, name = name, ok = false }
    local current = name and Talky_Streamers.find(name)
    if not event or not name then
        reply.reason = "invalid"
    elseif op == "add" and current then
        reply.reason = "exists"
    elseif op == "add" and #Talky_Streamers.all() >= Talky_Config.maxStreamers then
        reply.reason = "full"
    elseif op ~= "add" and not current then
        reply.reason = "unknown"
    elseif Talky_Files.event(event, { name = current and current.name or name, by = TalkyNet.username(player) }) then
        reply.ok = true
        S.logFor(key, "streamer:" .. op, "streamer " .. op .. " asked for " .. tostring(name))
    else
        reply.reason = "error"
    end
    TalkyNet.toClient(player, "streamerAck", reply)
end

local CONFIG_KEYS = {"webhooks", "workflows", "gameEvents", "publicUrl", "settings" }

commands.config = function(player, key, args, t)
    if not S.isAdmin(player) then return refuse(player, "config") end
    local data, err = readConfig()
    if not data then return TalkyNet.toClient(player, "config", { error = err }) end
    local out = {}
    for _, k in ipairs(CONFIG_KEYS) do out[k] = data[k] end
    if not TalkyNet.fits({ data = out }) then return TalkyNet.toClient(player, "config", { error = "too_large" }) end
    TalkyNet.toClient(player, "config", { data = out, ok = true })
end

-- The F8 window of an admin saves the five fields it edits; the other keys of the file stay.
commands.saveConfig = function(player, key, args, t)
    if not S.isAdmin(player) then return refuse(player, "saveConfig") end
    local sent = type(args) == "table" and type(args.data) == "table" and TalkyNet.copy(args.data, 40) or nil
    if not sent then return TalkyNet.toClient(player, "configSaved", { ok = false, error = "invalid" }) end
    local current = readConfig() or {}
    local merged = {}
    for k, v in pairs(current) do merged[k] = v end
    for _, k in ipairs(CONFIG_KEYS) do
        local v = sent[k]
        if k == "publicUrl" then
            merged[k] = TalkyNet.str(v, 200, "")
        elseif type(v) == "table" then
            merged[k] = v
        elseif v == nil and (k == "webhooks" or k == "workflows" or k == "gameEvents") then
            -- an empty table arrives as nil
            merged[k] = {}
        end
    end
    local ok = Talky_Files.write(Talky_Config.configFile, TalkyJson.encode(merged, "  "), false)
    if ok then
        S.configText, S.configData = nil, nil
        S.logFor(key, "saveConfig", "talky_config.json saved by " .. TalkyNet.username(player))
        -- the display settings reach every player at once
        TalkyNet.broadcast("display", { settings = Talky_Config.displayOf(merged.settings) })
    end
    TalkyNet.toClient(player, "configSaved", { ok = ok, error = not ok and "error" or nil })
end

-- Test now from the F8 window of an admin: the bridge runs the workflow for that admin (the
-- test code of talky_status.json proves the line comes from this server code).
commands.test = function(player, key, args, t)
    if not S.isAdmin(player) then return refuse(player, "test") end
    args = type(args) == "table" and args or {}
    local workflow = TalkyNet.str(args.workflow, 64, nil)
    local st = S.bridgeStatus()
    local nonce = TalkyNet.str(st.testNonce, 128, nil)
    if not workflow or workflow == "" then return TalkyNet.toClient(player, "testAck", { ok = false, error = "invalid" }) end
    if not st.alive then return TalkyNet.toClient(player, "testAck", { ok = false, error = "bridge_offline" }) end
    local vars = type(args.vars) == "table" and TalkyNet.copy(args.vars, 4) or {}
    if not TalkyNet.fits(vars) or TalkyNet.netSize(vars) > 4096 then vars = {} end
    local ok = Talky_Files.event("test_workflow", { workflow = workflow, vars = vars, nonce = nonce, streamer = TalkyNet.username(player) })
    TalkyNet.toClient(player, "testAck", { ok = ok, workflow = workflow })
end

Talky_Server.commands = commands

-- Entry point: OnClientCommand on a server, the local queue in single player.
function Talky_Server.onCommand(command, player, args)
    if not player then return end
    local mode = TalkyNet.mode()
    local key = TalkyNet.userKey(player)
    if key == "" then
        if mode ~= "sp" then return end
        key = "player"
    end
    local t = getTimestampMs()
    if mode == "server" and not takeToken(key, t) then return end
    local handler = commands[command]
    if not handler then return end
    local ok, err = pcall(handler, player, key, args, t)
    if not ok then S.logFor(key, "error", tostring(command) .. " failed: " .. tostring(err)) end
end

TalkyNet.serverHandler = Talky_Server.onCommand

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= TalkyNet.MODULE then return end
    Talky_Server.onCommand(command, player, args)
end)

---------------------------------------------------------------- game events (server mode)

-- A streamer who dies: player_died { streamer, hoursSurvived, zombieKills }, once per death.
function Talky_Server.checkDeaths()
    if TalkyNet.mode() ~= "server" then return end
    local t = getTimestampMs()
    if S.deathCheckAt and t - S.deathCheckAt < 1000 and t >= S.deathCheckAt then return end
    S.deathCheckAt = t
    local seen = {}
    for _, e in ipairs(Talky_Streamers.all()) do
        local p = TalkyNet.findPlayer(e.name)
        local dead = false
        if p then
            local ok, d = pcall(function() return p:isDead() end)
            dead = ok and d == true
        end
        if dead and not S.lastDead[e.key] then
            local hours, kills = 0, 0
            pcall(function() hours = math.floor(p:getHoursSurvived()) end)
            pcall(function() kills = p:getZombieKills() end)
            Talky_Files.streamerEvent("player_died", {
                hoursSurvived = TalkyNet.int(hours, 0, 0, 1e9), zombieKills = TalkyNet.int(kills, 0, 0, 1e9),
            }, e.name)
        end
        if dead then seen[e.key] = true end
    end
    S.lastDead = seen
end

Events.OnTick.Add(function()
    local ok, err = pcall(Talky_Server.checkDeaths)
    if not ok then TalkyNet.log("death check: " .. tostring(err)) end
end)

Events.OnServerStarted.Add(function()
    TalkyNet.log("server ready (Talky " .. Talky_Config.version .. ")")
    local server = ""
    pcall(function() server = TalkyNet.str(getServerName(), 64, "") or "" end)
    Talky_Files.event("game_started", { mode = "server", host = false, server = server })
end)

return Talky_Server
