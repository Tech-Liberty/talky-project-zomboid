-- File-based IPC with the Talky bridge (Kahlua cannot open sockets), and the relay of its
-- jobs to the Talky server code (the server in multiplayer, this same game in single player).
--   inbox  : one JSON job per line, each with an increasing "seq"
--   ack    : "S" or "S s1 s2 ..." - every job up to S is taken (accepted by the server, refused
--            for good, or expired), and s1, s2... above S too. The bridge then drops them.
--   outbox : we append game events (zombie killed, player died...) for the bridge
-- Handshake: "hello" every 3 s from the game start until "helloAck"; jobs are relayed only
-- after the server said yes. A job without answer is sent again every 30 s until its time
-- to live ends; it is acked only once the server answered for good.
-- A job is known by its id (seq + createdAt): a bridge that lost its state can give a seq
-- again, so an answer naming an id never applies to another job with the same seq.

require "Talky/Talky_Json"
require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Actions"

Talky_Bridge = {
    lastSeq = 0,        -- S, the high-water mark written in talky_ack.txt
    ackText = nil,      -- last text written in talky_ack.txt
    acked = {},         -- [seq] = id of the job taken (true: read back from the ack file), above S
    pending = {},       -- [id] = { job, seq, id, sentAt, retryAt, sendSteps, bytes, cut, emitted }
    relayed = {},       -- [id] = { seq, workflow, steps, emitted, untilMs, done }: accepted by the server
    inbox = {},         -- last inbox read, sorted: { seq, id, job, dead }
    lastPoll = 0,
    noAnswer = 0,       -- jobs sent more than 15 s ago without answer
    lastReject = nil,   -- { seq, workflow, reason }
    serverLines = {},   -- times of the outbox lines asked by the server (60 a minute)
    droppedLines = 0,   -- lines over that budget since the last console line about them
    dropLogAt = nil,
    singleUntil = nil,  -- a "jobs" message could not be sent: one job per message until then
    sendErrAt = nil,
    expiredSeen = {},
    gameStartedSent = false,
    writerWarned = false,
    hello = { state = "idle", firstAt = 0, nextAt = 0 },
    --   idle -> waiting (hello every 3 s) -> allowed | denied (hello every 30 s) | version | no_answer
}

local RESEND_MS, NO_ANSWER_MS, HELLO_MS, HELLO_DENIED_MS, HELLO_GIVE_UP_MS = 30000, 15000, 3000, 30000, 120000
local KEEP_RELAYED_MS, MAX_RELAYED = 1800000, 300
-- A "jobs" message is written into the connection's packet buffer, 1,000,000 bytes that never
-- grow: past it sendClientCommand throws (and the game keeps a lock of that connection). The
-- batch is cut at BATCH_BYTES of estimated size; a job estimated above MAX_JOB_BYTES alone is
-- never sent (multiplayer only: single player has no such buffer).
local BATCH_BYTES, MAX_JOB_BYTES = 262144, 900000
local PERMANENT = { not_allowed = true, invalid = true, duplicate = true, unknown_action = true, disabled = true, expired = true }
Talky_Bridge.PERMANENT = PERMANENT
-- Never written because the server asked for it (R10): only this PC's game sends these.
local LOCAL_ONLY = { test_workflow = true, game_started = true, player_died = true }

function Talky_Bridge.log(msg)
    TalkyNet.log(msg)
end

local function readAll(name)
    local reader = getFileReader(name, false)
    if not reader then return nil end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return lines
end

Talky_Bridge.readLines = readAll

---------------------------------------------------------------- outbox

function Talky_Bridge.emit(event, data)
    local w = getFileWriter(Talky_Config.outboxFile, true, true)
    if not w then
        if not Talky_Bridge.writerWarned then
            Talky_Bridge.writerWarned = true
            Talky_Bridge.log("cannot write " .. Talky_Config.outboxFile)
        end
        return false
    end
    w:write(TalkyJson.encode({ event = event, data = data or {}, ts = getTimestampMs() }) .. "\n")
    w:close()
    return true
end

-- Outbox line the server asked for. Multiplayer: at most 60 a minute (R10), the others are
-- dropped and counted in one console line a minute. Single player: the "server" is this same
-- game, every line is written (as 0.3.0).
function Talky_Bridge.emitFromServer(event, data)
    if TalkyNet.mode() ~= "client" then return Talky_Bridge.emit(event, data) end
    local t = getTimestampMs()
    local keep = {}
    for _, at in ipairs(Talky_Bridge.serverLines) do
        if t - at < 60000 and at <= t then keep[#keep + 1] = at end
    end
    Talky_Bridge.serverLines = keep
    if #keep >= 60 then
        Talky_Bridge.droppedLines = Talky_Bridge.droppedLines + 1
        local at = Talky_Bridge.dropLogAt
        if not at or t - at >= 60000 or t < at then
            Talky_Bridge.dropLogAt = t
            Talky_Bridge.log(Talky_Bridge.droppedLines .. " game event(s) dropped: more than 60 a minute from the server")
            Talky_Bridge.droppedLines = 0
        end
        return false
    end
    keep[#keep + 1] = t
    return Talky_Bridge.emit(event, data)
end

---------------------------------------------------------------- ack

local function writeAck(text)
    local w = getFileWriter(Talky_Config.ackFile, true, false)
    if not w then return false end
    w:write(text)
    w:close()
    return true
end

-- Reads "S s1 s2 ..." (a 0.3.0 file holds "S" only).
function Talky_Bridge.loadAck()
    local lines = readAll(Talky_Config.ackFile)
    local text = lines and table.concat(lines, "\n") or ""
    local first = true
    Talky_Bridge.lastSeq, Talky_Bridge.acked = 0, {}
    for d in string.gmatch(text, "%d+") do
        local n = tonumber(d)
        if first then
            Talky_Bridge.lastSeq = n or 0
            first = false
        elseif n and n > Talky_Bridge.lastSeq then
            Talky_Bridge.acked[n] = true
        end
    end
    Talky_Bridge.ackText = lines and text or nil
end

-- Past its expiresAt, or older than the server would take it (15 minutes after the bridge
-- created it, Talky_Config.maxJobTtlMs, whatever jobTtlSeconds says): skipped quietly here,
-- never sent to be refused as "expired".
local function expired(job, t)
    if type(job.expiresAt) == "number" and job.expiresAt < t then return true end
    local created = TalkyNet.num(job.createdAt, nil, 0, 1e15)
    return created ~= nil and created + Talky_Config.maxJobTtlMs <= t
end

-- Taken: by this very job (its id), or read back from the ack file.
local function isAcked(e)
    local a = Talky_Bridge.acked[e.seq]
    return a == true or (a ~= nil and a == e.id)
end

-- S = largest inbox seq such that every inbox seq up to it is taken (acked, refused, expired
-- or unreadable); the acked seqs above S follow it in the file.
function Talky_Bridge.updateAck()
    local t = getTimestampMs()
    local mark, blocked, present = Talky_Bridge.lastSeq, false, {}
    for _, e in ipairs(Talky_Bridge.inbox) do
        if e.seq > Talky_Bridge.lastSeq then
            present[e.seq] = e.id
            local done = isAcked(e) or e.dead or expired(e.job, t)
            if done and not blocked then mark = e.seq elseif not done then blocked = true end
        end
    end
    local extras = {}
    for seq, v in pairs(Talky_Bridge.acked) do
        -- an id that is not the one of the job now holding that seq: another job, forgotten
        if seq <= mark or not present[seq] or (v ~= true and v ~= present[seq]) then
            Talky_Bridge.acked[seq] = nil
        else
            extras[#extras + 1] = seq
        end
    end
    table.sort(extras)
    for id, p in pairs(Talky_Bridge.pending) do
        if p.seq <= mark or present[p.seq] ~= p.id then Talky_Bridge.pending[id] = nil end
    end
    Talky_Bridge.lastSeq = mark
    local text = tostring(mark)
    if #extras > 0 then text = text .. " " .. table.concat(extras, " ") .. "\n" end
    if text ~= Talky_Bridge.ackText and (mark > 0 or #extras > 0) then
        if writeAck(text) then Talky_Bridge.ackText = text end
    end
end

---------------------------------------------------------------- refusals

-- Translated reason (UI_Talky_Reason_<code>), or the code itself.
function Talky_Bridge.reasonText(reason)
    local key = "Reason_" .. tostring(reason)
    return Talky_Text.getOrNil(key) or tostring(reason)
end
local reasonText = Talky_Bridge.reasonText

-- A job refused for good (by the server, or "too_large" here: it cannot be sent at all):
-- acked, job_rejected for the bridge, a toast.
local function reject(p, reason, t)
    Talky_Bridge.acked[p.seq] = p.id
    Talky_Bridge.pending[p.id] = nil
    local workflow = TalkyNet.str(p.job.workflow, 64, "")
    Talky_Bridge.lastReject = { seq = p.seq, workflow = workflow, reason = reason }
    if reason == "too_large" then
        Talky_Bridge.log("job " .. p.seq .. " not sent: too large for one game message")
    else
        Talky_Bridge.log("job " .. p.seq .. " refused by the server: " .. reason)
    end
    Talky_Bridge.emit("job_rejected", { seq = p.seq, workflow = workflow, reason = reason })
    if Talky_Overlay then
        local text = reason == "too_large" and Talky_T("Toast_JobTooLarge", p.seq) or Talky_T("Toast_JobRejected", p.seq, reasonText(reason))
        Talky_Overlay.toast(text, "#ff5555")
    end
    if reason == "not_allowed" then
        local h = Talky_Bridge.hello
        h.state, h.reason, h.nextAt = "denied", "not_allowed", t + HELLO_DENIED_MS
    end
end

---------------------------------------------------------------- inbox and relay

-- Compared for equality only (a bridge that lost its state can reuse a seq).
local function jobId(job, seq)
    local created = TalkyNet.num(job.createdAt, 0, 0, 1e15)
    return tostring(seq) .. ":" .. string.format("%.0f", created)
end

-- Upper bound of the bytes the game's serializer (TableNetworkUtils.save) writes for a value:
-- a type byte, then string = 2-byte length + UTF-8 (3 bytes at most per UTF-16 unit), number
-- = 8 bytes, boolean = 1, table = a 4-byte count and its pairs. Too large (never sent): a
-- string that may pass 32,767 bytes (GameWindow$StringUTF.save writes the length as a signed
-- short: the receiver would read garbage), nesting deeper than 32.
local MAX_STRING_UNITS = 10922   -- 3 * 10922 = 32766 bytes
local function netSize(v, depth)
    local t = type(v)
    if t == "string" then
        if string.len(v) > MAX_STRING_UNITS then return MAX_JOB_BYTES + 1 end
        return 3 + 3 * string.len(v)
    end
    if t == "number" then return 9 end
    if t == "boolean" then return 2 end
    if t ~= "table" then return 0 end
    if depth > 32 then return MAX_JOB_BYTES + 1 end
    local n = 5
    for k, val in pairs(v) do
        local kt = type(k)
        if kt == "string" or kt == "number" then n = n + netSize(k, depth + 1) + netSize(val, depth + 1) end
    end
    return n
end
Talky_Bridge.netSize = function(v) return netSize(v, 0) end

-- Steps the server takes (helloAck caps.maxStepsPerJob; the server drops the others anyway).
local function stepCap()
    local caps = Talky_Bridge.hello.caps
    return TalkyNet.int(caps and caps.maxStepsPerJob, 500, 10, 500)
end

-- The job as it is sent: steps 1..cap of our copy (same indexes, so an emit step the server
-- names is found again in job.steps), size estimated once.
local function entryOf(p, t)
    local job = p.job
    if not p.sendSteps then
        local cap, out = stepCap(), {}
        local n = #job.steps
        for i = 1, math.min(n, cap) do out[i] = job.steps[i] end
        p.sendSteps, p.cut = out, math.max(0, n - cap)
    end
    local created = TalkyNet.num(job.createdAt, nil, 0, 1e15)
    local expires = TalkyNet.num(job.expiresAt, nil, 0, 1e15)
    local entry = {
        seq = p.seq,
        id = p.id,
        workflow = TalkyNet.str(job.workflow, 64, ""),
        user = TalkyNet.str(job.user, 64, ""),
        age_ms = created and math.max(0, t - created) or 0,
        ttl_ms = expires and math.max(0, math.min(expires - t, Talky_Config.maxJobTtlMs)) or Talky_Config.maxJobTtlMs,
        steps = p.sendSteps,
    }
    -- + its index in the list (a number key)
    if not p.bytes then p.bytes = netSize(entry, 1) + 9 end
    return entry
end

local function relay(t)
    if Talky_Bridge.hello.state ~= "allowed" then return end
    local mp = TalkyNet.mode() == "client"
    local maxJobs = Talky_Config.jobsPerBatch
    local single = Talky_Bridge.singleUntil
    if single and t < single and t + 60000 >= single then maxJobs = 1 else Talky_Bridge.singleUntil = nil end
    local batch, list, bytes, rejected = {}, {}, 64, false
    for _, e in ipairs(Talky_Bridge.inbox) do
        if e.seq > Talky_Bridge.lastSeq and not isAcked(e) and not e.dead and not expired(e.job, t) then
            local p = Talky_Bridge.pending[e.id]
            if not p then
                p = { job = e.job, seq = e.seq, id = e.id, retryAt = 0 }
                Talky_Bridge.pending[e.id] = p
            end
            -- order is kept behind a job the server asked to send again later
            if p.retryAt > t then break end
            if not p.sentAt or t - p.sentAt >= RESEND_MS or t < p.sentAt then
                local entry = entryOf(p, t)
                if mp and p.bytes > MAX_JOB_BYTES then
                    -- never sent: refused for good here, the jobs behind it go on
                    reject(p, "too_large", t)
                    rejected = true
                elseif mp and #batch > 0 and bytes + p.bytes > BATCH_BYTES then
                    break
                else
                    batch[#batch + 1] = p
                    list[#list + 1] = entry
                    bytes = bytes + p.bytes
                    if #batch >= maxJobs then break end
                end
            end
        end
    end
    if rejected then Talky_Bridge.updateAck() end
    if #batch == 0 then return end
    local ok, sent = pcall(TalkyNet.toServer, "jobs", { v = Talky_Config.protocolVersion, list = list })
    if not ok then
        -- the size estimate is the guard; this is the last resort (each failed send of the game
        -- leaves the connection's packet lock held)
        local at = Talky_Bridge.sendErrAt
        if not at or t - at >= 60000 or t < at then
            Talky_Bridge.sendErrAt = t
            Talky_Bridge.log("cannot send " .. #batch .. " job(s) to the server: " .. tostring(sent))
        end
        if #batch > 1 then
            Talky_Bridge.singleUntil = t + 60000
        else
            reject(batch[1], "too_large", t)
            Talky_Bridge.updateAck()
        end
        return
    end
    if sent then
        for _, p in ipairs(batch) do p.sentAt = t end
    end
end

function Talky_Bridge.poll()
    local lines = readAll(Talky_Config.inboxFile)
    if not lines then return end
    local t = getTimestampMs()
    local list = {}
    for i = 1, #lines do
        local line = lines[i]
        if line ~= "" then
            local job, err = TalkyJson.tryDecode(line)
            if type(job) ~= "table" then
                Talky_Bridge.log("bad inbox line: " .. tostring(err))
            else
                local seq = TalkyNet.seq(job.seq)
                if seq then
                    list[#list + 1] = { seq = seq, id = jobId(job, seq), job = job, dead = type(job.steps) ~= "table" }
                    if seq > Talky_Bridge.lastSeq and expired(job, t) and not Talky_Bridge.expiredSeen[seq] then
                        Talky_Bridge.expiredSeen[seq] = true
                        Talky_Bridge.log("job " .. seq .. " expired, skipped")
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    Talky_Bridge.inbox = list
    Talky_Bridge.updateAck()
    relay(t)
end

---------------------------------------------------------------- answers of the server

-- The pending job an answer is about: by its id; by seq only when the answer has no id (the
-- seq of another job with the same seq must never match).
local function findPending(a)
    local id = TalkyNet.str(a.id, 64, nil)
    if id then return Talky_Bridge.pending[id] end
    local seq = TalkyNet.seq(a.seq)
    if not seq then return nil end
    for _, q in pairs(Talky_Bridge.pending) do
        if q.seq == seq then return q end
    end
    return nil
end

local function hasEmit(steps)
    if type(steps) ~= "table" then return false end
    for _, s in ipairs(steps) do
        if type(s) == "table" and s.action == "emit" then return true end
    end
    return false
end

-- Longest the job can still run: its waits (as the server caps them) after the longest time
-- it can wait in the server queue.
local function lifeMs(steps)
    local waits = 0
    if type(steps) == "table" then
        for _, s in ipairs(steps) do
            if type(s) == "table" and s.action == "wait" then waits = waits + Talky_Actions.waitMs(s) end
        end
    end
    local cap = TalkyNet.mode() == "client" and Talky_Config.maxWaitPerJobMs or Talky_Config.caps().maxWaitPerJobMs
    return Talky_Config.maxJobTtlMs + math.min(waits, cap)
end

-- Accepted by the server: the copy is kept until job_done / job_expired / job_rejected
-- (Talky_Bridge.forget); the time limit is only a safety net for a job that never ends (server
-- restart, runner error), and holds the job's whole life when it has emit steps.
local function remember(p, t)
    local r = Talky_Bridge.relayed
    local old = r[p.id]
    -- already over (an answer "duplicate" after its job_done): stays over
    if old and old.done then return end
    local withEmit = hasEmit(p.job.steps)
    r[p.id] = {
        seq = p.seq, workflow = p.job.workflow,
        steps = withEmit and p.job.steps or nil,
        emitted = p.emitted or (old and old.emitted) or {},
        untilMs = t + (withEmit and (lifeMs(p.job.steps) + KEEP_RELAYED_MS) or KEEP_RELAYED_MS),
    }
    local n, oldestId, oldestAt, plainId, plainAt = 0, nil, nil, nil, nil
    for id, e in pairs(r) do
        if e.untilMs < t then
            r[id] = nil
        else
            n = n + 1
            if not oldestAt or e.untilMs < oldestAt then oldestId, oldestAt = id, e.untilMs end
            if e.steps == nil and (not plainAt or e.untilMs < plainAt) then plainId, plainAt = id, e.untilMs end
        end
    end
    -- too many: a copy without emit step goes first (it only gives a workflow name)
    if n > MAX_RELAYED then
        local victim = plainId or oldestId
        if victim then r[victim] = nil end
    end
end

-- The job is over (job_done, job_expired or job_rejected from the server): its steps go (no
-- emit step of it can be written any more), its workflow name stays 30 minutes, so a late
-- message about it is still named from our own copy.
function Talky_Bridge.forget(id)
    local r = id and Talky_Bridge.relayed[id]
    if not r then return end
    r.steps, r.emitted, r.done = nil, nil, true
    r.untilMs = math.min(r.untilMs, getTimestampMs() + KEEP_RELAYED_MS)
end

function Talky_Bridge.onJobAcks(args)
    if type(args) ~= "table" or type(args.list) ~= "table" then return end
    local t = getTimestampMs()
    local changed = false
    for i = 1, math.min(#args.list, 50) do
        local a = args.list[i]
        local p = type(a) == "table" and findPending(a)
        if p then
            local reason = TalkyNet.str(a.reason, 32, nil)
            if a.ok == true or reason == "duplicate" then
                Talky_Bridge.acked[p.seq] = p.id
                Talky_Bridge.pending[p.id] = nil
                remember(p, t)
                -- cut here to the server's limit, or by the server itself
                local cut = (p.cut or 0) + TalkyNet.int(a.truncated, 0, 0, 100000)
                if cut > 0 then Talky_Bridge.log("job " .. p.seq .. ": " .. cut .. " step(s) dropped by the server (too many)") end
                changed = true
            elseif reason and PERMANENT[reason] then
                reject(p, reason, t)
                changed = true
            else
                p.retryAt = t + TalkyNet.num(a.retry_ms, 10000, 1000, 120000)
                p.sentAt = nil
            end
        end
    end
    if changed then Talky_Bridge.updateAck() end
end

local function pendingCopy(p)
    p.emitted = p.emitted or {}
    return { seq = p.seq, workflow = p.job.workflow, steps = p.job.steps, emitted = p.emitted }
end

-- The local copy of a job (it came from this PC's inbox): pending or accepted. By id when the
-- server gives one (then only that job), by seq otherwise.
function Talky_Bridge.findJob(id, seq)
    if id then
        local p = Talky_Bridge.pending[id]
        if p then return pendingCopy(p) end
        local r = Talky_Bridge.relayed[id]
        if r then
            r.emitted = r.emitted or {}
            return r
        end
        return nil
    end
    if seq then
        for _, p in pairs(Talky_Bridge.pending) do
            if p.seq == seq then return pendingCopy(p) end
        end
        for _, r in pairs(Talky_Bridge.relayed) do
            if r.seq == seq then
                r.emitted = r.emitted or {}
                return r
            end
        end
    end
    return nil
end

-- Console line about an emit step that was not written: once per job, one line every 10 s
-- at most (the server decides how often it asks).
local emitNotes = { at = nil, seqs = {}, n = 0 }
local function emitNote(seq, msg)
    if seq and emitNotes.seqs[seq] then return end
    local t = getTimestampMs()
    if emitNotes.at and t - emitNotes.at < 10000 and t >= emitNotes.at then return end
    emitNotes.at = t
    if seq then
        if emitNotes.n >= 64 then emitNotes.seqs, emitNotes.n = {}, 0 end
        emitNotes.seqs[seq] = true
        emitNotes.n = emitNotes.n + 1
    end
    Talky_Bridge.log(msg)
end

-- "emit" step of a job: the event and its data come from our own copy of the job, each step
-- written once (a server naming the same step again is ignored).
function Talky_Bridge.onEmitStep(args)
    if type(args) ~= "table" then return end
    local seq = TalkyNet.seq(args.seq)
    local job = Talky_Bridge.findJob(TalkyNet.str(args.id, 64, nil), seq)
    if not job or type(job.steps) ~= "table" then
        emitNote(seq, "emit step of job " .. tostring(seq) .. " not written: this game has no copy of the job")
        return
    end
    local index = TalkyNet.int(args.index, nil, 1, 100000)
    local step = index and job.steps[index]
    if type(step) ~= "table" or step.action ~= "emit" then return end
    local event = TalkyNet.str(step.event or "custom", 64, "custom")
    if LOCAL_ONLY[event] then
        Talky_Bridge.log("emit step refused: \"" .. event .. "\" is only sent by the game itself")
        return
    end
    local done = job.emitted
    if done and done[index] then
        emitNote(seq, "emit step " .. index .. " of job " .. tostring(seq) .. " already written, ignored")
        return
    end
    -- marked once written only: a line over the budget can still be written by a later ask
    if Talky_Bridge.emitFromServer(event, step.data) and done then done[index] = true end
end

---------------------------------------------------------------- handshake

local function gameStartedData()
    local mode = TalkyNet.mode()
    local host, server = false, ""
    if mode == "client" then
        local ok, h = pcall(isCoopHost)
        host = ok and h == true
        local ok2, s = pcall(getServerName)
        if ok2 and type(s) == "string" then server = TalkyNet.str(s, 64, "") end
    end
    return { mode = mode, host = host, server = server }
end

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

function Talky_Bridge.onHelloAck(args)
    args = type(args) == "table" and args or {}
    local h = Talky_Bridge.hello
    local t = getTimestampMs()
    h.answerAt = t
    h.serverVersion = TalkyNet.str(args.server, 16, "?")
    h.caps = capsOf(args.caps)
    local v = TalkyNet.num(args.v, 0, 0, 1000000)
    if v ~= Talky_Config.protocolVersion or args.reason == "version" then
        if h.state ~= "version" then
            Talky_Bridge.log("Talky " .. h.serverVersion .. " (protocol " .. tostring(v) .. ") on the server does not match Talky "
                .. Talky_Config.version .. " (protocol " .. Talky_Config.protocolVersion .. ") here: nothing is relayed")
        end
        h.state, h.reason = "version", "version"
    elseif args.allowed == true then
        if h.state ~= "allowed" then Talky_Bridge.log("the server accepts the jobs of this player") end
        h.state, h.reason = "allowed", nil
    else
        if h.state ~= "denied" then Talky_Bridge.log("the server refuses the jobs of this player (not allowed)") end
        h.state, h.reason, h.nextAt = "denied", TalkyNet.str(args.reason, 32, "not_allowed"), t + HELLO_DENIED_MS
    end
    if not Talky_Bridge.gameStartedSent then
        Talky_Bridge.gameStartedSent = true
        Talky_Bridge.emit("game_started", gameStartedData())
    end
end

-- Hosted game: the host's account starts with the default role. The server lets the real
-- host change its own role; then hello again.
function Talky_Bridge.allowMe()
    if TalkyNet.mode() ~= "client" then return false end
    local name = TalkyNet.username(getPlayer())
    if name == "" or string.match(name, '"') then return false end
    SendCommandToServer('/setaccesslevel "' .. name .. '" admin')
    local t = getTimestampMs()
    local h = Talky_Bridge.hello
    h.state, h.firstAt, h.nextAt = "waiting", t, t + 2000
    return true
end

-- What the F8 Status page shows.
function Talky_Bridge.serverStatus()
    local h = Talky_Bridge.hello
    local waiting = 0
    for _ in pairs(Talky_Bridge.pending) do waiting = waiting + 1 end
    local mode = TalkyNet.mode()
    local host = false
    if mode == "client" then
        local ok, res = pcall(isCoopHost)
        host = ok and res == true
    end
    return {
        mode = mode, state = h.state, reason = h.reason, caps = h.caps, serverVersion = h.serverVersion,
        host = host, noAnswer = Talky_Bridge.noAnswer, waiting = waiting, lastReject = Talky_Bridge.lastReject,
        username = TalkyNet.username(getPlayer()),
    }
end

---------------------------------------------------------------- lifecycle

function Talky_Bridge.start()
    Talky_Bridge.loadAck()
    local t = getTimestampMs()
    local h = Talky_Bridge.hello
    h.state, h.firstAt, h.nextAt = "waiting", t, t
    local mode = TalkyNet.mode()
    Talky_Bridge.log("ready, last seq = " .. Talky_Bridge.lastSeq .. " (" .. mode .. ")")
    if mode == "sp" then
        Talky_Bridge.gameStartedSent = true
        Talky_Bridge.emit("game_started", gameStartedData())
    end
end

local function helloTick(t)
    local h = Talky_Bridge.hello
    if (h.state ~= "waiting" and h.state ~= "denied") or t < h.nextAt then return end
    if h.state == "waiting" and t - h.firstAt > HELLO_GIVE_UP_MS then
        h.state = "no_answer"
        if TalkyNet.mode() == "sp" then
            -- single player: the "server" is this game; its server/ files did not start
            Talky_Bridge.log("the Talky game code does not answer: look for [Talky] errors in console.txt")
        else
            Talky_Bridge.log("the server does not answer: check the server console for [Talky] errors")
        end
        return
    end
    TalkyNet.toServer("hello", { v = Talky_Config.protocolVersion, client = Talky_Config.version })
    h.nextAt = t + (h.state == "waiting" and HELLO_MS or HELLO_DENIED_MS)
end

local function onTick()
    local t = getTimestampMs()
    helloTick(t)
    if t - Talky_Bridge.lastPoll < Talky_Config.pollIntervalMs and t >= Talky_Bridge.lastPoll then return end
    Talky_Bridge.lastPoll = t
    local silent = 0
    for _, p in pairs(Talky_Bridge.pending) do
        if p.sentAt and t - p.sentAt > NO_ANSWER_MS then silent = silent + 1 end
    end
    Talky_Bridge.noAnswer = silent
    local player = getPlayer()
    if not player or player:isDead() then return end
    local ok, err = pcall(Talky_Bridge.poll)
    if not ok then Talky_Bridge.log("poll error: " .. tostring(err)) end
end

Events.OnGameStart.Add(Talky_Bridge.start)
Events.OnTick.Add(onTick)

return Talky_Bridge
