-- Reads the jobs of the bridge and hands them to Talky_ServerRunner, where the jobs run: in the
-- single player game, or on the server (dedicated, or the server of a hosted game), next to
-- which the bridge runs in server mode. No client takes part: a job never crosses the network.
--   inbox : talky_inbox.jsonl, one JSON job per line, each with an increasing "seq". Server
--           mode: "target" = the username of the streamer whose token the webhook call carried
--           (Talky_Streamers); "test" = a Test now of an admin who may not be a streamer.
--   ack   : talky_ack.txt, "S" or "S s1 s2 ..." - every job up to S is taken (accepted, refused
--           for good, expired or unreadable), and s1, s2... above S too. The bridge then drops
--           them from the inbox.
-- A job is known by its id (seq + createdAt): a bridge that lost its state can give a seq
-- again, so a job taken before never hides another one with the same seq.
-- The steps of a job are checked (Talky_Actions.sanitizeStep, the sandbox options on a server)
-- before it is queued. A job that cannot be queued yet (busy, rate limited) stays in the inbox
-- and is read again later; the jobs of the same streamer behind it wait too (order kept).
-- Runs on the server and in single player only.

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Json"
require "Talky/Talky_Net"
require "Talky/Talky_Actions"
require "Talky/Talky_Files"
require "Talky/Talky_Streamers"
require "Talky/Talky_ServerRunner"

Talky_Inbox = {
    started = false,
    lastSeq = 0,        -- S, the high-water mark written in talky_ack.txt
    ackText = nil,      -- last text written in talky_ack.txt
    acked = {},         -- [seq] = id of the job taken (true: read back from the ack file), above S
    inbox = {},         -- last inbox read, sorted: { seq, id, job, dead }
    lastPoll = nil,
    expiredSeen = {},
    retryAt = {},       -- [key] = time the jobs of a rate limited streamer are read again
    jobTimes = {},      -- [key] = { t }   jobs accepted in the last minute
}

local I = Talky_Inbox
local MAX_REFUSED_REPORTS = 20

---------------------------------------------------------------- ack

-- Reads "S s1 s2 ..." (a 0.3.0 file holds "S" only).
function Talky_Inbox.loadAck()
    local text = Talky_Files.readText(Talky_Config.ackFile)
    local first = true
    I.lastSeq, I.acked = 0, {}
    for d in string.gmatch(text or "", "%d+") do
        local n = tonumber(d)
        if first then
            I.lastSeq = n or 0
            first = false
        elseif n and n > I.lastSeq then
            I.acked[n] = true
        end
    end
    I.ackText = text
end

-- Past its expiresAt, or older than the game would take it (15 minutes after the bridge
-- created it, Talky_Config.maxJobTtlMs, whatever jobTtlSeconds says).
local function deadlineOf(job, t)
    local created = TalkyNet.num(job.createdAt, nil, 0, 1e15)
    local deadline = (created or t) + Talky_Config.maxJobTtlMs
    local expires = TalkyNet.num(job.expiresAt, nil, 0, 1e15)
    if expires and expires < deadline then deadline = expires end
    return deadline
end

local function expired(job, t)
    return deadlineOf(job, t) <= t
end

-- Taken: by this very job (its id), or read back from the ack file.
local function isAcked(e)
    local a = I.acked[e.seq]
    return a == true or (a ~= nil and a == e.id)
end

-- S = largest inbox seq such that every inbox seq up to it is taken (acked, refused, expired
-- or unreadable); the acked seqs above S follow it in the file.
function Talky_Inbox.updateAck()
    local t = getTimestampMs()
    local mark, blocked, present = I.lastSeq, false, {}
    for _, e in ipairs(I.inbox) do
        if e.seq > I.lastSeq then
            present[e.seq] = e.id
            local done = isAcked(e) or e.dead or expired(e.job, t)
            if done and not blocked then mark = e.seq elseif not done then blocked = true end
        end
    end
    local extras = {}
    for seq, v in pairs(I.acked) do
        -- an id that is not the one of the job now holding that seq: another job, forgotten
        if seq <= mark or not present[seq] or (v ~= true and v ~= present[seq]) then
            I.acked[seq] = nil
        else
            extras[#extras + 1] = seq
        end
    end
    table.sort(extras)
    I.lastSeq = mark
    local text = tostring(mark)
    if #extras > 0 then text = text .. " " .. table.concat(extras, " ") .. "\n" end
    if text ~= I.ackText and (mark > 0 or #extras > 0) then
        if Talky_Files.write(Talky_Config.ackFile, text, false) then I.ackText = text end
    end
end

---------------------------------------------------------------- checks

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

-- action_failed for the steps refused at acceptance, once the job is accepted or refused for
-- good (never for a job read again later). On a server each (action, code) is reported once
-- per job, 20 lines per job at most; single player reports every refused step, as 0.3.0.
local function reportRefused(owner, seq, refused, caps)
    local said, n = {}, 0
    for _, r in ipairs(refused) do
        local k = tostring(r.action) .. ":" .. tostring(r.code)
        if not caps.enforce or not said[k] then
            said[k] = true
            n = n + 1
            if caps.enforce and n > MAX_REFUSED_REPORTS then return end
            Talky_Files.streamerEvent("action_failed", { seq = seq, action = r.action, code = r.code, error = r.code }, owner)
        end
    end
end

local function recentJobs(key, t)
    local keep = {}
    for _, at in ipairs(I.jobTimes[key] or {}) do
        if t - at < 60000 and at <= t then keep[#keep + 1] = at end
    end
    I.jobTimes[key] = keep
    return keep
end

local function countJob(key, t, caps)
    if not caps.maxJobsPerMinute then return end
    local list = I.jobTimes[key] or {}
    list[#list + 1] = t
    I.jobTimes[key] = list
end

-- One job for owner (username) / key (TalkyNet.nameKey). Returns { ok = true }, a final
-- refusal { reason } (acked, job_rejected) or a delay { wait = true, retryAt } (left in the
-- inbox, read again later).
function Talky_Inbox.accept(owner, key, e, t, caps, isTest)
    local raw = e.job
    local deadline = deadlineOf(raw, t)
    if deadline <= t then return { reason = "expired" } end
    if caps.maxJobsPerMinute then
        local recent = recentJobs(key, t)
        if #recent >= caps.maxJobsPerMinute then return { wait = true, retryAt = recent[1] + 60000 + 100 } end
    end
    local steps, truncated, refused = sanitizeSteps(raw.steps, caps)
    -- On a server a job whose steps are all refused is refused for good, and counts in the
    -- per-minute window too. Single player runs it like 0.3.0: action_failed for each step,
    -- then job_done.
    if caps.enforce and #steps == 0 and #refused > 0 then
        countJob(key, t, caps)
        reportRefused(owner, e.seq, refused, caps)
        local first = refused[1].code
        return { reason = (first == "disabled" or first == "unknown_action") and first or "invalid" }
    end
    if not Talky_ServerRunner.canQueue(key, caps) then return { wait = true } end
    Talky_ServerRunner.enqueue(key, owner, {
        seq = e.seq, id = e.id,
        workflow = TalkyNet.str(raw.workflow, 64, ""),
        user = TalkyNet.str(raw.user, 64, ""),
        steps = steps,
        receivedAt = t,
        deadline = deadline,
        test = isTest == true,
    })
    countJob(key, t, caps)
    reportRefused(owner, e.seq, refused, caps)
    if truncated > 0 then
        TalkyNet.logLimited(key, "truncated", "job " .. e.seq .. ": " .. truncated .. " step(s) dropped (more than " .. caps.maxStepsPerJob .. " steps)")
    end
    return { ok = true }
end

-- Who a job is for: username, key, test. Single player: the local player. Server: the
-- streamer named in "target", or, for a Test now ("test"), an admin online.
local function ownerOf(job)
    if TalkyNet.mode() ~= "server" then
        local name = TalkyNet.username(getPlayer())
        local key = TalkyNet.nameKey(name)
        if key == "" then key = "player" end
        return name, key, false
    end
    local target = Talky_Streamers.cleanName(job.target)
    if not target then return nil end
    local entry = Talky_Streamers.find(target)
    if entry then return entry.name, entry.key, false end
    if job.test == true and Talky_Server and Talky_Server.isAdmin then
        local player = TalkyNet.findPlayer(target)
        if player and Talky_Server.isAdmin(player) then return TalkyNet.username(player), TalkyNet.userKey(player), true end
    end
    return nil
end

-- A job refused for good: acked, job_rejected for the bridge.
local function reject(e, reason, owner, key)
    I.acked[e.seq] = e.id
    local workflow = TalkyNet.str(e.job.workflow, 64, "")
    TalkyNet.logLimited(key or "?", "rejected:" .. reason, "job " .. e.seq .. " refused: " .. reason)
    Talky_Files.streamerEvent("job_rejected", { seq = e.seq, workflow = workflow, reason = reason },
        owner or Talky_Streamers.cleanName(e.job.target))
end

---------------------------------------------------------------- reading

-- Compared for equality only (a bridge that lost its state can reuse a seq).
local function jobId(job, seq)
    local created = TalkyNet.num(job.createdAt, 0, 0, 1e15)
    return tostring(seq) .. ":" .. string.format("%.0f", created)
end

function Talky_Inbox.start()
    I.started = true
    I.loadAck()
    TalkyNet.log("inbox ready, last seq = " .. I.lastSeq .. " (" .. TalkyNet.mode() .. ")")
end

function Talky_Inbox.poll()
    if not I.started then I.start() end
    local t = getTimestampMs()
    I.lastPoll = t
    local lines = Talky_Files.readLines(Talky_Config.inboxFile)
    if not lines then return end
    local list = {}
    for i = 1, #lines do
        local line = lines[i]
        if line ~= "" then
            local job, err = TalkyJson.tryDecode(line)
            if type(job) ~= "table" then
                TalkyNet.logLimited("inbox", "bad line", "bad inbox line: " .. tostring(err))
            else
                local seq = TalkyNet.seq(job.seq)
                if seq then
                    list[#list + 1] = { seq = seq, id = jobId(job, seq), job = job, dead = type(job.steps) ~= "table" }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    I.inbox = list
    local caps = Talky_Config.caps()
    local held = {}   -- [key] = true: a job of this streamer waits, the next ones wait too
    for _, e in ipairs(list) do
        if e.seq > I.lastSeq and not isAcked(e) and not e.dead then
            if expired(e.job, t) then
                if not I.expiredSeen[e.seq] then
                    I.expiredSeen[e.seq] = true
                    TalkyNet.log("job " .. e.seq .. " expired, skipped")
                end
            else
                local owner, key, isTest = ownerOf(e.job)
                if not owner then
                    reject(e, "not_streamer", nil, "inbox")
                elseif held[key] or (I.retryAt[key] and t < I.retryAt[key] and t + 120000 >= I.retryAt[key]) then
                    held[key] = true
                else
                    local ok, res = pcall(Talky_Inbox.accept, owner, key, e, t, caps, isTest)
                    if not ok then
                        TalkyNet.logLimited(key, "error", "job " .. e.seq .. " refused, error: " .. tostring(res))
                        reject(e, "invalid", owner, key)
                    elseif res.ok then
                        I.acked[e.seq] = e.id
                    elseif res.wait then
                        held[key] = true
                        if res.retryAt then I.retryAt[key] = res.retryAt end
                    else
                        reject(e, res.reason, owner, key)
                    end
                end
            end
        end
    end
    I.updateAck()
    -- a seq at or below S never comes back: forget it
    local n = 0
    for seq in pairs(I.expiredSeen) do
        if seq <= I.lastSeq then I.expiredSeen[seq] = nil else n = n + 1 end
    end
    if n > 1000 then I.expiredSeen = {} end
end

Events.OnTick.Add(function()
    if TalkyNet.mode() == "client" then return end
    local t = getTimestampMs()
    if I.lastPoll and t - I.lastPoll < Talky_Config.pollIntervalMs and t >= I.lastPoll then return end
    local ok, err = pcall(Talky_Inbox.poll)
    if not ok then
        I.lastPoll = t
        TalkyNet.log("inbox error: " .. tostring(err))
    end
end)

return Talky_Inbox
