-- Talky server code: receives the jobs the streamers' games relay from their bridge, checks
-- them and hands them to Talky_ServerRunner. Module "Talky", commands from the client:
--   hello { v, client }      -> helloAck { v, allowed, reason, caps, server, mode }
--   jobs  { v, list = {...} } -> jobAcks { list = { { seq, id, ok, reason, retry_ms, truncated } } }
--   tags                      -> tags { reset, list } (names above zombies, for late joiners)
-- Order of the checks for every command: rate limit, command, permission, validation, dedup,
-- queue. Replies carry reason codes only, never error texts.
--   acked by the client (final): not_allowed, invalid, duplicate, unknown_action, disabled, expired
--   retried by the client      : busy, rate_limited (with retry_ms)
-- The steps refused at acceptance are reported (action_failed) once the answer is final only:
-- a job answered busy or rate_limited comes back, and would report them again at every try.
-- Who may use Talky on a server: the username in Talky.AllowedPlayers (names separated by
-- commas or semicolons, a space is part of a name; A-Z not case-sensitive, like the game's
-- account database: TalkyNet.nameKey), or (Talky.AllowAdmins and the player's role has the
-- CreateHorde capability: admins and moderators by default).
-- In single player: always. Nothing here reads or writes files (in a hosted game the server
-- shares Zomboid/Lua with the host's client).
-- Runs on the server and in single player only.

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Net"
require "Talky/Talky_Actions"
require "Talky/Talky_Tags"
require "Talky/Talky_ServerRunner"

Talky_Server = {
    buckets = {},     -- [key] = { tokens, at }   5 commands/s, burst 10
    seen = {},        -- [key] = { [id] = expiresAt }   jobs already accepted
    jobTimes = {},    -- [key] = { t }   jobs accepted in the last minute
    helloAt = {},     -- [key] = last hello answered
    deniedAt = {},    -- [key] = last refusal answered
    tagsAt = {},      -- [key] = last tags snapshot
    lastPurge = 0,
    allowedCache = { text = nil, set = {} },
}

local S = Talky_Server
local PERMANENT = { not_allowed = true, invalid = true, duplicate = true, unknown_action = true, disabled = true, expired = true }
Talky_Server.PERMANENT = PERMANENT

---------------------------------------------------------------- logs

-- One console line per player and reason per minute, at most 10 lines per player per minute
-- (shared with the job runner: TalkyNet.logLimited).
function Talky_Server.logFor(key, reason, msg)
    TalkyNet.logLimited(key, reason, msg)
end

---------------------------------------------------------------- permission

-- Talky.AllowedPlayers: names separated by ',' or ';' (both refused in usernames), each one
-- trimmed. A space is part of a name ("Big Boss" is one username): splitting on it would let
-- anyone create the account "big" and pass.
local function allowedSet(text)
    local c = S.allowedCache
    if c.text ~= text then
        c.text, c.set = text, {}
        for entry in string.gmatch(text or "", "[^,;]+") do
            local name = string.match(entry, "^%s*(.-)%s*$")
            if name and name ~= "" then c.set[TalkyNet.nameKey(name)] = true end
        end
    end
    return c.set
end

-- May this player use Talky? Never isAdmin/isCoopHost/hasAdminPower (wrong or client-only
-- on a server), never a name taken from the args.
function Talky_Server.isAllowed(player)
    local mode = TalkyNet.mode()
    if mode == "sp" then return true end
    if mode ~= "server" or not player then return false end
    local sv = Talky_Config.readSandbox()
    local key = TalkyNet.userKey(player)
    if key ~= "" and allowedSet(sv.AllowedPlayers)[key] then return true end
    if sv.AllowAdmins then
        local ok, res = pcall(function()
            local role = player:getRole()
            return role ~= nil and role:hasCapability(Capability.CreateHorde)
        end)
        if ok and res == true then return true end
    end
    return false
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

local function recentJobs(key, t)
    local keep = {}
    for _, at in ipairs(S.jobTimes[key] or {}) do
        if t - at < 60000 and at <= t then keep[#keep + 1] = at end
    end
    S.jobTimes[key] = keep
    return keep
end

-- Drops old dedup entries and idle per-player state, once a minute.
local function purge(t)
    if t - S.lastPurge < 60000 and t >= S.lastPurge then return end
    S.lastPurge = t
    for key, ids in pairs(S.seen) do
        local alive = false
        for id, untilMs in pairs(ids) do
            if untilMs < t then ids[id] = nil else alive = true end
        end
        if not alive then S.seen[key] = nil end
    end
    for key, b in pairs(S.buckets) do
        if t - b.at > 60000 then S.buckets[key] = nil end
    end
end

---------------------------------------------------------------- validation

local function readId(raw)
    local id = TalkyNet.str(raw.id, 64, nil)
    if id and not string.match(id, "^[%w:%._%-]+$") then id = nil end
    return id
end

-- Clean copy of the steps of a job. Returns steps, truncated, refused = { { action, code } }.
local function sanitizeSteps(rawSteps, caps)
    local steps, refused = {}, {}
    local n = #rawSteps
    local cap = caps.maxStepsPerJob
    local truncated = 0
    if n > cap then truncated = n - cap; n = cap end
    local waitLeft = caps.maxWaitPerJobMs
    for i = 1, n do
        local step, code, action = Talky_Actions.sanitizeStep(rawSteps[i], i, caps)
        if step then
            if step.action == "wait" then
                local ms = math.min(Talky_Actions.waitMs(step), waitLeft)
                waitLeft = waitLeft - ms
                step.seconds = ms / 1000
            end
            steps[#steps + 1] = step
        else
            refused[#refused + 1] = { action = action, code = code }
        end
    end
    return steps, truncated, refused
end

-- action_failed for the steps refused at acceptance. Called once the answer for the job is
-- final (accepted, or refused for good), never before a busy or rate_limited answer: the job
-- comes back, and the same lines would be written at every try. On a server each (action,
-- code) is reported once per job, 20 lines per job at most (one "jobs" message must not turn
-- into hundreds of packets); single player reports every refused step, as 0.3.0.
local MAX_REFUSED_REPORTS = 20
local function reportRefused(player, seq, refused, caps)
    local said, n = {}, 0
    for _, r in ipairs(refused) do
        local k = tostring(r.action) .. ":" .. tostring(r.code)
        if not caps.enforce or not said[k] then
            said[k] = true
            n = n + 1
            if caps.enforce and n > MAX_REFUSED_REPORTS then return end
            TalkyNet.toClient(player, "emit", { event = "action_failed", data = { seq = seq, action = r.action, code = r.code } })
        end
    end
end

-- One job of a "jobs" message. Returns the ack entry, or nil when there is nothing the
-- client could match it with (no readable seq nor id).
function Talky_Server.acceptJob(player, key, raw, v, t, caps)
    if type(raw) ~= "table" then return nil end
    local seq = TalkyNet.seq(raw.seq)
    local id = readId(raw)
    if not seq and not id then return nil end
    local ack = { seq = seq, id = id }
    if not seq or v ~= Talky_Config.protocolVersion or type(raw.steps) ~= "table" then
        ack.ok, ack.reason = false, "invalid"
        return ack
    end
    id = id or tostring(seq)
    ack.id = id
    local seen = S.seen[key]
    if seen and seen[id] then
        ack.ok, ack.reason = false, "duplicate"
        return ack
    end
    local age = TalkyNet.num(raw.age_ms, 0, 0, Talky_Config.maxJobTtlMs)
    local ttl = TalkyNet.num(raw.ttl_ms, Talky_Config.maxJobTtlMs, 0, Talky_Config.maxJobTtlMs)
    local life = math.min(ttl, Talky_Config.maxJobTtlMs - age)
    if life <= 0 then
        ack.ok, ack.reason = false, "expired"
        return ack
    end
    -- transient answers before anything is reported: a rate_limited job is sent again
    if caps.maxJobsPerMinute then
        local recent = recentJobs(key, t)
        if #recent >= caps.maxJobsPerMinute then
            ack.ok, ack.reason = false, "rate_limited"
            ack.retry_ms = math.max(1000, 60000 - (t - recent[1]) + 100)
            return ack
        end
    end
    local steps, truncated, refused = sanitizeSteps(raw.steps, caps)
    -- On a server a job whose steps are all refused is refused for good, and counts in the
    -- per-minute window too (a flood of such jobs ends up rate_limited). Single player runs it
    -- like 0.3.0: action_failed for each step, then job_done.
    if caps.enforce and #steps == 0 and #refused > 0 then
        if caps.maxJobsPerMinute then
            local list = S.jobTimes[key] or {}
            list[#list + 1] = t
            S.jobTimes[key] = list
        end
        reportRefused(player, seq, refused, caps)
        ack.ok, ack.reason = false, refused[1].code == "disabled" and "disabled" or (refused[1].code == "unknown_action" and "unknown_action" or "invalid")
        return ack
    end
    if not Talky_ServerRunner.canQueue(key, caps) then
        ack.ok, ack.reason, ack.retry_ms = false, "busy", 5000
        return ack
    end
    Talky_ServerRunner.enqueue(key, TalkyNet.username(player), {
        seq = seq, id = id,
        workflow = TalkyNet.str(raw.workflow, 64, ""),
        user = TalkyNet.str(raw.user, 64, ""),
        steps = steps,
        receivedAt = t,
        deadline = t + life,
    })
    seen = seen or {}
    seen[id] = t + ttl + 60000
    S.seen[key] = seen
    if caps.maxJobsPerMinute then
        local list = S.jobTimes[key] or {}
        list[#list + 1] = t
        S.jobTimes[key] = list
    end
    -- accepted: reported once (a resend now gets "duplicate" before reaching this point)
    reportRefused(player, seq, refused, caps)
    ack.ok = true
    if truncated > 0 then ack.truncated = truncated end
    return ack
end

---------------------------------------------------------------- commands

local commands = {}

commands.hello = function(player, key, args, t)
    local mode = TalkyNet.mode()
    local v = type(args) == "table" and TalkyNet.num(args.v, 0, 0, 1000000) or 0
    local allowed = Talky_Server.isAllowed(player)
    if mode == "server" then
        if S.helloAt[key] and t - S.helloAt[key] < 5000 and t >= S.helloAt[key] then return end
        if not allowed and S.deniedAt[key] and t - S.deniedAt[key] < 30000 and t >= S.deniedAt[key] then return end
    end
    S.helloAt[key] = t
    local reply = { v = Talky_Config.protocolVersion, server = Talky_Config.version, mode = mode,
                    caps = Talky_Config.publicCaps() }
    if v ~= Talky_Config.protocolVersion then
        reply.allowed, reply.reason = false, "version"
        S.logFor(key, "version", "protocol " .. tostring(v) .. " instead of " .. Talky_Config.protocolVersion .. ": update Talky")
    elseif allowed then
        reply.allowed = true
    else
        reply.allowed, reply.reason = false, "not_allowed"
        S.deniedAt[key] = t
    end
    TalkyNet.toClient(player, "helloAck", reply)
end

commands.jobs = function(player, key, args, t)
    if type(args) ~= "table" or type(args.list) ~= "table" then return end
    local list = args.list
    local n = math.min(#list, Talky_Config.jobsPerBatch)
    local v = TalkyNet.num(args.v, 0, 0, 1000000)
    local acks = {}
    if not Talky_Server.isAllowed(player) then
        if S.deniedAt[key] and t - S.deniedAt[key] < 30000 and t >= S.deniedAt[key] then return end
        S.deniedAt[key] = t
        for i = 1, n do
            local raw = list[i]
            if type(raw) == "table" then
                local seq, id = TalkyNet.seq(raw.seq), readId(raw)
                if seq or id then acks[#acks + 1] = { seq = seq, id = id, ok = false, reason = "not_allowed" } end
            end
        end
        S.logFor(key, "not_allowed", "jobs refused: not allowed (Talky.AllowedPlayers / AllowAdmins)")
    else
        local caps = Talky_Config.caps()
        for i = 1, n do
            local raw = list[i]
            local ok, ack = pcall(Talky_Server.acceptJob, player, key, raw, v, t, caps)
            if not ok then
                S.logFor(key, "error", "job refused, error: " .. tostring(ack))
                ack = nil
                if type(raw) == "table" then
                    local seq, id = TalkyNet.seq(raw.seq), readId(raw)
                    if seq or id then ack = { seq = seq, id = id, ok = false, reason = "invalid" } end
                end
            end
            if ack then
                if not ack.ok and ack.reason ~= "duplicate" then
                    S.logFor(key, ack.reason, "job " .. tostring(ack.seq) .. " refused: " .. tostring(ack.reason))
                end
                acks[#acks + 1] = ack
            end
        end
    end
    if #acks > 0 then TalkyNet.toClient(player, "jobAcks", { list = acks }) end
end

commands.tags = function(player, key, args, t)
    if TalkyNet.mode() ~= "server" then return end
    if S.tagsAt[key] and t - S.tagsAt[key] < 10000 and t >= S.tagsAt[key] then return end
    S.tagsAt[key] = t
    Talky_Tags.sendSnapshot(player)
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
    purge(t)
    local ok, err = pcall(handler, player, key, args, t)
    if not ok then S.logFor(key, "error", tostring(command) .. " failed: " .. tostring(err)) end
end

TalkyNet.serverHandler = Talky_Server.onCommand

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= TalkyNet.MODULE then return end
    Talky_Server.onCommand(command, player, args)
end)

Events.OnServerStarted.Add(function()
    TalkyNet.log("server ready (Talky " .. Talky_Config.version .. ", protocol " .. Talky_Config.protocolVersion .. ")")
end)

return Talky_Server
