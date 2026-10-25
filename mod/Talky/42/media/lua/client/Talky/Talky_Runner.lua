-- Runs jobs received from the bridge. A job is an ordered list of steps;
-- steps run one after another, "wait" pauses the job without blocking the others.

require "Talky/Talky_Config"
require "Talky/Talky_Bridge"

Talky_Runner = {
    active = {},  -- { job = job, index = 1, resumeAt = 0 }
    queued = {},
}

local function gamePaused()
    return isGamePaused()
end

function Talky_Runner.enqueue(job)
    if job.expiresAt and job.expiresAt < getTimestampMs() then
        Talky_Bridge.log("job " .. tostring(job.seq) .. " expired, skipped")
        return
    end
    if type(job.steps) ~= "table" then return end
    if #Talky_Runner.queued >= Talky_Config.maxQueuedJobs then
        Talky_Bridge.log("job " .. tostring(job.seq) .. " dropped: " .. #Talky_Runner.queued .. " jobs already waiting")
        return
    end
    table.insert(Talky_Runner.queued, { job = job, index = 1, resumeAt = 0 })
end

-- "wait" is capped so a job cannot hold one of the maxActiveJobs slots for ever.
local function waitMs(step)
    local secs = tonumber(step.seconds) or 1
    if secs < 0 then secs = 0 end
    if secs > Talky_Config.maxWaitSeconds then secs = Talky_Config.maxWaitSeconds end
    return secs * 1000
end
Talky_Runner.waitMs = waitMs

-- Runs steps until the job finishes or hits a wait. Returns true when finished.
local function advance(run, player, now)
    local steps = run.job.steps
    while run.index <= #steps do
        if now < run.resumeAt then return false end
        local step = steps[run.index]
        run.index = run.index + 1
        if step.action == "wait" then
            run.resumeAt = now + waitMs(step)
        else
            local ok, err = pcall(Talky_Actions.run, step, player, run.job)
            if not ok then
                Talky_Bridge.log("action " .. tostring(step.action) .. " failed: " .. tostring(err))
                Talky_Bridge.emit("action_failed", { seq = run.job.seq, action = step.action, error = tostring(err) })
            end
        end
    end
    Talky_Bridge.emit("job_done", { seq = run.job.seq, workflow = run.job.workflow })
    return true
end

local function onTick()
    if #Talky_Runner.active == 0 and #Talky_Runner.queued == 0 then return end
    local player = getPlayer()
    if not player or player:isDead() or gamePaused() then return end

    while #Talky_Runner.queued > 0 and #Talky_Runner.active < Talky_Config.maxActiveJobs do
        table.insert(Talky_Runner.active, table.remove(Talky_Runner.queued, 1))
    end

    local now = getTimestampMs()
    for i = #Talky_Runner.active, 1, -1 do
        if advance(Talky_Runner.active[i], player, now) then
            table.remove(Talky_Runner.active, i)
        end
    end
end

Talky_Bridge.onJob = Talky_Runner.enqueue
Events.OnTick.Add(onTick)
