-- Multiplayer: what the F8 window knows from the server, and asks it. The bridge runs next to
-- the server, so this game never reads its files: the Talky server code answers.
--   status     every player: the server's Talky version, the limits, the bridge (running or
--              not, its mode), whether this player is a streamer, an admin (CreateHorde role)
--   streamers  admins: the streamers, their tokens, the bridge's port and public address
--   config     admins: the webhooks, workflows, game events and settings of the server's
--              talky_config.json; saved back with "saveConfig"
--   test       admins: Test now (the bridge runs the workflow around the admin)
-- Asked every 3 s from the game start until the server answers (2 minutes at most, then every
-- 30 s), then again while the F8 window is open.

require "Talky/Talky_Config"
require "Talky/Talky_Net"

Talky_Remote = {
    status = nil,          -- last "status" answer
    statusAt = nil,
    state = "idle",        -- idle | waiting | ready | no_answer
    firstAskAt = nil,
    nextAskAt = 0,
    streamers = nil,       -- last "streamers" answer { list, port, publicUrl, bridge }
    streamersAt = nil,
    streamersAskedAt = nil,
    config = nil,          -- the server's configuration (admins), edited by the window
    configState = "none",  -- none | loading | ready | error
    configError = nil,
    saving = false,
    lastAck = nil,         -- last "streamerAck" { op, name, ok, reason }
    lastTest = nil,        -- last "testAck"
    refused = {},          -- [what] = true: the server refused an admin command to this player
    tagsRequested = false,
    onChange = nil,        -- function(what): an answer arrived (the window draws its page again)
}

local R = Talky_Remote
local str = TalkyNet.str
local ASK_MS, ASK_SLOW_MS, GIVE_UP_MS = 3000, 30000, 120000

local function changed(what)
    if R.onChange then pcall(R.onChange, what) end
end

function Talky_Remote.active()
    return TalkyNet.mode() == "client"
end

function Talky_Remote.isAdmin()
    return R.status ~= nil and R.status.admin == true
end

function Talky_Remote.isStreamer()
    return R.status ~= nil and R.status.streamer == true
end

function Talky_Remote.isHost()
    if not R.active() then return false end
    local ok, res = pcall(isCoopHost)
    return ok and res == true
end

---------------------------------------------------------------- requests

function Talky_Remote.askStatus()
    if not R.active() then return false end
    return TalkyNet.toServer("status", {})
end

-- While the F8 window is open: the status every 5 s, the streamers every 3 s on the Webhooks
-- page (an admin added one: the bridge drew the token a second later).
function Talky_Remote.refresh(page)
    if not R.active() then return end
    local t = getTimestampMs()
    if R.state == "ready" and (not R.statusAt or t - R.statusAt >= 5000 or t < R.statusAt) and t >= R.nextAskAt then
        R.nextAskAt = t + 5000
        R.askStatus()
    end
    if page == "webhooks" and R.isAdmin() and (not R.streamersAskedAt or t - R.streamersAskedAt >= 3000 or t < R.streamersAskedAt) then
        R.streamersAskedAt = t
        TalkyNet.toServer("streamers", {})
    end
end

function Talky_Remote.askStreamers()
    if not R.active() then return end
    R.streamersAskedAt = getTimestampMs()
    TalkyNet.toServer("streamers", {})
end

function Talky_Remote.askConfig()
    if not R.active() then return end
    R.configState = "loading"
    R.configError = nil
    TalkyNet.toServer("config", {})
end

-- false and a reason when nothing was sent.
function Talky_Remote.saveConfig(data)
    if not R.active() or type(data) ~= "table" then return false, "invalid" end
    local out = {}
    for _, k in ipairs({ "webhooks", "workflows", "gameEvents", "publicUrl", "settings" }) do out[k] = data[k] end
    if not TalkyNet.fits({ data = out }) then return false, "too_large" end
    R.saving = true
    TalkyNet.toServer("saveConfig", { data = out })
    return true
end

-- op = add | remove | token
function Talky_Remote.streamerOp(op, name)
    if not R.active() then return false end
    R.lastAck = nil
    TalkyNet.toServer("streamer", { op = op, name = name })
    return true
end

function Talky_Remote.test(workflow, vars)
    if not R.active() then return false end
    R.lastTest = nil
    TalkyNet.toServer("test", { workflow = workflow, vars = vars })
    return true
end

-- Hosted game: the host's account starts with the default role, and only an admin manages
-- Talky. The server lets the real host change its own role; then ask the status again.
function Talky_Remote.allowMe()
    if not R.active() then return false end
    local name = TalkyNet.username(getPlayer())
    if name == "" or string.match(name, '"') then return false end
    SendCommandToServer('/setaccesslevel "' .. name .. '" admin')
    R.recheckAt = getTimestampMs() + 2000
    return true
end

---------------------------------------------------------------- answers

local function capsOf(c)
    if type(c) ~= "table" then return nil end
    local out = { allow = {} }
    for _, k in ipairs({ "maxZombiesPerAction", "maxZombiesPerJob", "maxSpawnDistance", "maxActiveJobs",
                         "maxQueuedJobs", "maxJobsPerMinute", "maxStepsPerJob", "audience" }) do
        out[k] = TalkyNet.int(c[k], nil, 0, 1000000)
    end
    if type(c.allow) == "table" then
        for _, cat in ipairs(Talky_Config.categories) do out.allow[cat] = c.allow[cat] ~= false end
    end
    return out
end

local function recentOf(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, math.min(#list, 15) do
        local e = list[i]
        if type(e) == "table" then
            local c = {}
            for _, k in ipairs({ "at", "source", "workflow", "user", "streamer", "skipped", "error", "rejected" }) do c[k] = str(e[k], 120, nil) end
            c.job = TalkyNet.seq(e.job)
            out[#out + 1] = c
        end
    end
    return out
end

function Talky_Remote.onStatus(a)
    local b = type(a.bridge) == "table" and a.bridge or {}
    local wasAdmin = R.isAdmin()
    R.status = {
        version = str(a.version, 16, "?"),
        admin = a.admin == true,
        streamer = a.streamer == true,
        caps = capsOf(a.caps),
        bridge = {
            alive = b.alive == true,
            version = str(b.version, 16, ""),
            mode = str(b.mode, 16, ""),
            protocol = TalkyNet.int(b.protocol, 1, 0, 1000000),
            port = TalkyNet.int(b.port, 7420, 1, 65535),
            publicUrl = str(b.publicUrl, 200, ""),
            pending = TalkyNet.int(b.pending, 0, 0, 1000000),
        },
        recent = recentOf(a.recent),
    }
    R.statusAt = getTimestampMs()
    if R.state ~= "ready" then TalkyNet.log("the server answers (Talky " .. R.status.version .. ")") end
    R.state = "ready"
    if R.status.admin then R.refused = {} end
    -- names already above zombies, once per session (late join)
    if not R.tagsRequested then
        R.tagsRequested = true
        TalkyNet.toServer("tags", {})
    end
    -- an admin now (Allow me, or a role given during the game): load the configuration
    if R.status.admin and not wasAdmin and R.configState ~= "ready" then R.askConfig() end
    changed("status")
end

function Talky_Remote.onStreamers(a)
    local list = {}
    if type(a.list) == "table" then
        for i = 1, math.min(#a.list, Talky_Config.maxStreamers) do
            local e = a.list[i]
            local name = type(e) == "table" and str(e.name, Talky_Config.maxStreamerName, nil)
            local token = type(e) == "table" and str(e.token, 128, nil)
            if name and name ~= "" and token and string.match(token, "^%x+$") then
                list[#list + 1] = { name = name, token = token, online = e.online == true }
            end
        end
    end
    R.streamers = {
        list = list,
        port = TalkyNet.int(a.port, 7420, 1, 65535),
        publicUrl = str(a.publicUrl, 200, ""),
        bridge = a.bridge == true,
    }
    R.streamersAt = getTimestampMs()
    changed("streamers")
end

local ACK_REASONS = { invalid = true, exists = true, full = true, unknown = true, error = true }

function Talky_Remote.onStreamerAck(a)
    local reason = str(a.reason, 16, nil)
    R.lastAck = { op = str(a.op, 8, ""), name = str(a.name, Talky_Config.maxStreamerName, ""), ok = a.ok == true,
                  reason = reason and ACK_REASONS[reason] and reason or nil }
    -- the bridge writes the new list a moment later: ask again soon
    R.streamersAskedAt = getTimestampMs() - 2000
    changed("streamerAck")
end

function Talky_Remote.onConfig(a)
    if type(a.data) == "table" and a.ok == true then
        local d = TalkyNet.copy(a.data, 40) or {}
        for _, k in ipairs({ "webhooks", "workflows", "gameEvents", "settings" }) do
            if type(d[k]) ~= "table" then d[k] = {} end
        end
        if type(d.publicUrl) ~= "string" then d.publicUrl = "" end
        R.config = d
        R.configState = "ready"
    else
        R.configState = "error"
        R.configError = str(a.error, 32, "error")
    end
    changed("config")
end

function Talky_Remote.onConfigSaved(a)
    R.saving = false
    R.lastSave = { ok = a.ok == true, error = str(a.error, 32, nil) }
    changed("configSaved")
end

function Talky_Remote.onTestAck(a)
    R.lastTest = { ok = a.ok == true, error = str(a.error, 32, nil), workflow = str(a.workflow, 64, "") }
    changed("testAck")
end

function Talky_Remote.onRefused(a)
    local what = str(a.what, 16, "")
    R.refused[what] = true
    if what == "config" or what == "saveConfig" then
        R.configState = "none"
        R.saving = false
    end
    if R.status then R.status.admin = false end
    changed("refused")
end

---------------------------------------------------------------- start

local function onGameStart()
    if not R.active() then return end
    local t = getTimestampMs()
    R.state, R.firstAskAt, R.nextAskAt = "waiting", t, t
end

local function onTick()
    if not R.active() then return end
    local t = getTimestampMs()
    if R.recheckAt and t >= R.recheckAt then
        -- after Allow me: the new role, a moment later
        R.recheckAt = nil
        R.askStatus()
    end
    if (R.state ~= "waiting" and R.state ~= "no_answer") or t < R.nextAskAt then return end
    if R.state == "waiting" and t - R.firstAskAt > GIVE_UP_MS then
        R.state = "no_answer"
        TalkyNet.log("the server does not answer: check the server console for [Talky] errors")
        changed("status")
    end
    R.askStatus()
    R.nextAskAt = t + (R.state == "waiting" and ASK_MS or ASK_SLOW_MS)
end

Events.OnGameStart.Add(onGameStart)
Events.OnTick.Add(onTick)

return Talky_Remote
