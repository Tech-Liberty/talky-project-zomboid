-- Runs the jobs Talky_Inbox accepted, on the server (and in single player, where server/
-- files run too). A job is an ordered list of steps; steps run one after another, "wait"
-- pauses the job without blocking the others.
--   queues   : one per streamer (TalkyNet.nameKey of the username), each with its waiting and
--              running jobs
--   owner    : the IsoPlayer is looked up again on every tick (a reconnect creates a new one);
--              while the owner is offline or dead their jobs do not move. An empty server
--              paused by PauseEmpty runs no tick at all: that time counts as offline too.
--   rules    : on a server the streamer list and the category toggles are checked again on
--              every tick, so a streamer an admin removed, or a category turned off, also
--              stops the jobs already accepted
--   budgets  : on a server, zombies / items / vehicles / XP / fires / sounds per 10 minutes and
--              per job, server-wide cooldowns, at most Talky_Config.zombiesPerTick zombies per
--              tick; banners shown to everyone and "say" lines per minute
--   results  : job_done, action_failed, job_expired and job_rejected are written to the outbox
--              for the bridge, with the streamer in server mode (Talky_Files)
-- Runs on the server and in single player only.

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Net"
require "Talky/Talky_Actions"
require "Talky/Talky_Files"
require "Talky/Talky_Streamers"
require "Talky/Talky_Tags"

Talky_ServerRunner = {
    queues = {},       -- [key] = { owner = username, queued = { run }, active = { run }, offlineSince, lastSeen }
    windows = {},      -- rolling 10-minute budgets: [name] = { [10 s bucket] = sum }
    cooldowns = {},    -- server-wide: [kind] = last use (ms)
    broadcasts = {},   -- uses in the last minute: ["b:" | "s:" .. key] = { t }, ["b:*" | "s:*"] = { t }
    tickBudget = 0,
    lastExpiryCheck = 0,
    offlineDropMs = 900000,   -- a streamer offline for 15 min loses their jobs
}

local R = Talky_ServerRunner
-- A window is the sum of its 10-second buckets: its size stays at 60 keys at most, whatever
-- the amounts (an XP step of 0.0001 costs the same as one of 1000). A bucket is dropped once it
-- is 60 buckets old: a spend counts for 590 to 600 s.
local BUCKET_MS, BUCKETS = 10000, 60

---------------------------------------------------------------- budgets

local function windowSum(name, t)
    local b = R.windows[name]
    if not b then return 0 end
    local now, sum, stale = math.floor(t / BUCKET_MS), 0, nil
    for k, n in pairs(b) do
        -- k > now: a bucket from the future after the clock went back
        if k > now or now - k >= BUCKETS then
            stale = stale or {}
            stale[#stale + 1] = k
        else
            sum = sum + n
        end
    end
    if stale then
        for _, k in ipairs(stale) do b[k] = nil end
        if TalkyNet.isEmpty(b) then R.windows[name] = nil end
    end
    return sum
end

local function windowAdd(name, t, n)
    if not (n > 0) then return end
    local b = R.windows[name] or {}
    local k = math.floor(t / BUCKET_MS)
    b[k] = (b[k] or 0) + n
    R.windows[name] = b
end

-- Gives back n of what was taken at time "at" (a spawn that created fewer zombies).
local function windowSub(name, at, n)
    local b = R.windows[name]
    if not b or type(at) ~= "number" or not (n > 0) then return end
    local k = math.floor(at / BUCKET_MS)
    if b[k] then b[k] = math.max(0, b[k] - n) end
end

-- How many of "want" this job may use now (server budgets); records them.
local function reserve(run, key, kind, want, caps, t)
    if not caps.enforce then return want end
    local allowed = want
    if kind == "zombies" then
        allowed = math.min(allowed, caps.maxZombiesPerJob - run.zombies,
                           caps.maxZombiesPer10Min - windowSum("z:" .. key, t),
                           caps.maxZombiesPer10MinServer - windowSum("z:*", t))
        allowed = math.max(0, math.floor(allowed))
        run.zombies = run.zombies + allowed
        windowAdd("z:" .. key, t, allowed)
        windowAdd("z:*", t, allowed)
    elseif kind == "items" then
        allowed = math.max(0, math.floor(math.min(allowed, caps.maxItemsPer10Min - windowSum("i:" .. key, t))))
        windowAdd("i:" .. key, t, allowed)
    elseif kind == "vehicles" then
        allowed = math.max(0, math.floor(math.min(allowed, caps.maxVehiclesPer10Min - windowSum("v:" .. key, t))))
        windowAdd("v:" .. key, t, allowed)
    elseif kind == "xp" then
        allowed = math.max(0, math.floor(math.min(allowed, caps.maxXpPer10Min - windowSum("x:" .. key, t))))
        windowAdd("x:" .. key, t, allowed)
    elseif kind == "fires" then
        allowed = math.max(0, math.floor(math.min(allowed, caps.maxFiresPer10Min - windowSum("f:" .. key, t),
                                                  caps.maxFiresPer10MinServer - windowSum("f:*", t))))
        windowAdd("f:" .. key, t, allowed)
        windowAdd("f:*", t, allowed)
    elseif kind == "sounds" then
        allowed = math.max(0, math.floor(math.min(allowed, caps.maxSoundsPer10Min - windowSum("s:" .. key, t))))
        windowAdd("s:" .. key, t, allowed)
    end
    return allowed
end

-- Zombies reserved at time "at" and never created: back to the job and 10-minute budgets.
local function refund(run, key, kind, n, caps, at)
    if not caps.enforce or kind ~= "zombies" or type(n) ~= "number" or not (n > 0) then return end
    run.zombies = math.max(0, run.zombies - n)
    windowSub("z:" .. key, at, n)
    windowSub("z:*", at, n)
end

-- Server-wide cooldown: true (and recorded) when the effect may run now.
local function cooldown(kind, ms, t)
    local last = R.cooldowns[kind]
    if last and t - last < ms and t >= last then return false end
    R.cooldowns[kind] = t
    return true
end

-- At most perKey uses a minute per streamer and total in all; true (and recorded) when allowed.
local function minuteOk(prefix, key, t, perKey, total)
    local function recent(name)
        local keep = {}
        for _, at in ipairs(R.broadcasts[name] or {}) do
            if t - at < 60000 and at <= t then keep[#keep + 1] = at end
        end
        R.broadcasts[name] = keep
        return keep
    end
    local mine, all = recent(prefix .. tostring(key)), recent(prefix .. "*")
    if #mine >= perKey or #all >= total then return false end
    mine[#mine + 1] = t
    all[#all + 1] = t
    return true
end

-- Banners shown to every player (notify steps, named zombies that die): 6 a minute per
-- streamer, 20 a minute in all; beyond that they go to the streamer only.
function Talky_ServerRunner.broadcastOk(key, t)
    return minuteOk("b:", key, t or getTimestampMs(), Talky_Config.maxBannersPerMinute, Talky_Config.maxBannersPerMinuteServer)
end

-- "say" lines in the public chat: 12 a minute per streamer, 60 a minute in all.
function Talky_ServerRunner.sayOk(key, t)
    return minuteOk("s:", key, t or getTimestampMs(), Talky_Config.maxSayPerMinute, Talky_Config.maxSayPerMinuteServer)
end

---------------------------------------------------------------- queues

local function count(field)
    local n = 0
    for _, q in pairs(R.queues) do n = n + #q[field] end
    return n
end

-- Room for one more waiting job of this player? (per player and in total)
function Talky_ServerRunner.canQueue(key, caps)
    local q = R.queues[key]
    if q and #q.queued >= caps.maxQueuedJobs then return false end
    return count("queued") < caps.maxQueuedJobsTotal
end

-- run = { seq, id, workflow, user, steps, receivedAt, deadline, test }
function Talky_ServerRunner.enqueue(key, owner, run)
    local q = R.queues[key]
    if not q then
        q = { owner = owner, queued = {}, active = {} }
        R.queues[key] = q
    end
    q.owner = owner
    run.key, run.owner = key, owner
    run.index, run.resumeAt, run.zombies = 1, 0, 0
    run.job = { seq = run.seq, id = run.id, workflow = run.workflow, user = run.user }
    q.queued[#q.queued + 1] = run
end

function Talky_ServerRunner.pendingCount()
    return count("queued") + count("active")
end

-- An event about a job, for the bridge (server mode: with the streamer it ran for).
local function emit(run, event, data)
    Talky_Files.streamerEvent(event, data, run.owner)
end

-- Console lines about one job: through the per-player limiter (one line per reason a minute,
-- 10 a minute per player), so one streamer's jobs cannot flood the server log.
local function logRun(key, reason, msg)
    if TalkyNet.logLimited then TalkyNet.logLimited(key or "?", reason, msg) else TalkyNet.log(msg) end
end

local function fail(run, action, code, detail)
    logRun(run.key, "fail:" .. tostring(action) .. ":" .. tostring(code),
        "job " .. tostring(run.seq) .. ": " .. tostring(action) .. " failed (" .. tostring(code) .. ")"
        .. (detail and (": " .. detail) or ""))
    emit(run, "action_failed", { seq = run.seq, action = action, code = code, error = code })
end

-- Category of an action, as Talky_Actions.sanitizeStep reads it.
local function stepCategory(meta)
    if not meta then return nil end
    return meta.custom and "custom" or meta.category
end

---------------------------------------------------------------- running

local function context(q, key, run, caps, t)
    return {
        mode = TalkyNet.mode(),
        caps = caps,
        owner = q.owner,
        run = run,
        now = t,
        reserve = function(kind, want) return reserve(run, key, kind, want, caps, t) end,
        refund = function(kind, n, at) return refund(run, key, kind, n, caps, at) end,
        cooldown = function(kind, ms) return cooldown(kind, ms, t) end,
        broadcastOk = function() return R.broadcastOk(key, t) end,
        sayOk = function() return R.sayOk(key, t) end,
        emit = function(event, data) return Talky_Files.streamerEvent(event, data, run.owner) end,
    }
end

-- A spawn plan is over (done, failed or stopped): the zombies it did not create go back to
-- the budgets.
local function endSpawn(run, ctx, plan)
    run.spawn = nil
    if plan.count > plan.made then ctx.refund("zombies", plan.count - plan.made, plan.reservedAt) end
end

-- Runs steps until the job finishes, hits a wait or uses the zombie budget of the tick.
-- Returns true when finished.
local function advance(q, key, run, player, t, caps)
    local ctx = context(q, key, run, caps, t)
    while true do
        if run.spawn then
            local plan = run.spawn
            if caps.enforce and not Talky_Config.categoryAllowed(stepCategory(Talky_Actions.meta[run.spawnAction]), caps) then
                -- turned off while the spawn was in progress
                endSpawn(run, ctx, plan)
                fail(run, run.spawnAction, "disabled")
            else
                local n = math.min(R.tickBudget, plan.count - plan.done)
                if n <= 0 then return false end
                R.tickBudget = R.tickBudget - n
                local ok, err = pcall(Talky_Actions.spawnSome, plan, player, n, ctx)
                if not ok then
                    endSpawn(run, ctx, plan)
                    fail(run, run.spawnAction, "error", tostring(err))
                elseif plan.done >= plan.count then
                    endSpawn(run, ctx, plan)
                    local code = Talky_Actions.spawnFailure(plan)
                    if code then fail(run, run.spawnAction, code) end
                else
                    return false
                end
            end
        else
            if run.index > #run.steps then break end
            if t < run.resumeAt then return false end
            local step = run.steps[run.index]
            run.index = run.index + 1
            local action = step.action
            if action == "wait" then
                run.resumeAt = t + Talky_Actions.waitMs(step)
            else
                local meta = Talky_Actions.meta[action]
                if caps.enforce and not Talky_Config.categoryAllowed(stepCategory(meta), caps) then
                    -- the category was turned off after the job was accepted
                    fail(run, action, "disabled")
                elseif meta and meta.spawn then
                    local ok, plan, code = pcall(Talky_Actions.planSpawn, step, player, ctx, meta.spawn)
                    if not ok then
                        fail(run, action, "error", tostring(plan))
                    elseif not plan then
                        fail(run, action, code or "error")
                    else
                        run.spawn, run.spawnAction = plan, action
                    end
                else
                    local code, detail = Talky_Actions.exec(step, player, run.job, ctx)
                    if code then fail(run, action, code, detail) end
                end
            end
        end
    end
    emit(run, "job_done", { seq = run.seq, workflow = run.workflow })
    return true
end

-- Queued jobs past their time to live are dropped (job_expired), the owner online or not.
local function expireQueued(q, t)
    for i = #q.queued, 1, -1 do
        local run = q.queued[i]
        if t > run.deadline then
            table.remove(q.queued, i)
            logRun(run.key, "expired", "job " .. tostring(run.seq) .. " expired before it could start")
            emit(run, "job_expired", { seq = run.seq, workflow = run.workflow })
        end
    end
end

-- Every job of a queue, dropped: job_expired (offline too long) or job_rejected (reason).
local function dropAll(q, reason)
    for _, list in ipairs({ q.queued, q.active }) do
        for _, run in ipairs(list) do
            if reason then
                emit(run, "job_rejected", { seq = run.seq, workflow = run.workflow, reason = reason })
            else
                emit(run, "job_expired", { seq = run.seq, workflow = run.workflow })
            end
        end
    end
    q.queued, q.active = {}, {}
end

-- Server mode: the jobs of a player who is no longer a streamer (an admin removed them) are
-- dropped, each one reported as refused (not_streamer). A Test now of an admin stays while
-- that admin is online and still an admin. Returns how many active jobs were dropped.
local function dropNotStreamer(q, key, player)
    if TalkyNet.mode() ~= "server" or Talky_Streamers.find(q.owner) then return 0 end
    local admin = player ~= nil and Talky_Server ~= nil and Talky_Server.isAdmin ~= nil and Talky_Server.isAdmin(player)
    local dropped, activeDropped = 0, 0
    for _, name in ipairs({ "queued", "active" }) do
        local keep = {}
        for _, run in ipairs(q[name]) do
            if run.test and (admin or player == nil) then
                keep[#keep + 1] = run
            else
                emit(run, "job_rejected", { seq = run.seq, workflow = run.workflow, reason = "not_streamer" })
                dropped = dropped + 1
                if name == "active" then activeDropped = activeDropped + 1 end
            end
        end
        q[name] = keep
    end
    if dropped > 0 then logRun(key, "not_streamer", "jobs of " .. tostring(q.owner) .. " dropped: no longer a streamer") end
    return activeDropped
end

function Talky_ServerRunner.tick()
    if TalkyNet.isEmpty(R.queues) then return end
    local t = getTimestampMs()
    local caps = Talky_Config.caps()
    R.tickBudget = Talky_Config.zombiesPerTick
    local checkExpiry = t - R.lastExpiryCheck >= 1000 or t < R.lastExpiryCheck
    if checkExpiry then R.lastExpiryCheck = t end
    local activeTotal = count("active")
    local emptyKeys = {}
    local server = TalkyNet.mode() == "server"
    for key, q in pairs(R.queues) do
        local player = TalkyNet.findPlayer(q.owner)
        if checkExpiry then activeTotal = activeTotal - dropNotStreamer(q, key, player) end
        if not player then
            q.offlineSince = q.offlineSince or t
            if checkExpiry then expireQueued(q, t) end
            if t - q.offlineSince > R.offlineDropMs then
                TalkyNet.log("jobs of " .. tostring(q.owner) .. " dropped: offline for too long")
                activeTotal = activeTotal - #q.active
                dropAll(q, nil)
            end
        else
            -- no tick ran since the owner was last seen (empty server paused by PauseEmpty):
            -- that time counts as offline too
            local gone = q.offlineSince or q.lastSeen
            if server and gone and t - gone > R.offlineDropMs then
                TalkyNet.log("jobs of " .. tostring(q.owner) .. " dropped: offline for too long")
                activeTotal = activeTotal - #q.active
                dropAll(q, nil)
            end
            q.offlineSince = nil
            q.lastSeen = t
            if checkExpiry then expireQueued(q, t) end
            if not player:isDead() then
                while #q.queued > 0 and #q.active < caps.maxActiveJobs and activeTotal < caps.maxActiveJobsTotal do
                    local run = table.remove(q.queued, 1)
                    if t > run.deadline then
                        emit(run, "job_expired", { seq = run.seq, workflow = run.workflow })
                    else
                        q.active[#q.active + 1] = run
                        activeTotal = activeTotal + 1
                    end
                end
                for i = 1, #q.active do
                    local run = q.active[i]
                    if run and not run.finished then
                        local ok, done = pcall(advance, q, key, run, player, t, caps)
                        if not ok then
                            logRun(key, "stopped", "job " .. tostring(run.seq) .. " stopped: " .. tostring(done))
                            done = true
                        end
                        if done then run.finished = true end
                    end
                end
                for i = #q.active, 1, -1 do
                    if q.active[i].finished then
                        table.remove(q.active, i)
                        activeTotal = activeTotal - 1
                    end
                end
            end
        end
        if #q.queued == 0 and #q.active == 0 then emptyKeys[#emptyKeys + 1] = key end
    end
    for _, key in ipairs(emptyKeys) do R.queues[key] = nil end
end

Events.OnTick.Add(function()
    local ok, err = pcall(Talky_ServerRunner.tick)
    if not ok then TalkyNet.log("runner error: " .. tostring(err)) end
end)

return Talky_ServerRunner
