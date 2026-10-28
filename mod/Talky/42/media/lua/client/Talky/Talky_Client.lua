-- What the Talky server code sends to this game (module "Talky"; in single player the same
-- messages come through TalkyNet's local queue):
--   helloAck { v, allowed, reason, caps, server, mode }      -> Talky_Bridge (relay on/off)
--   jobAcks  { list = { { seq, id, ok, reason, retry_ms, truncated } } } -> Talky_Bridge (ack file)
--   fx       { kind = notify | say | halo | heal, ... }       -> effects on this client
--   emit     { event, data }   -> outbox, only zombie_killed, job_done, action_failed,
--                                job_rejected and job_expired, with fixed fields. job_done,
--                                job_expired and job_rejected also carry the job id (never
--                                written): the job is over, its local copy is dropped.
--   emitStep { seq, id, index } -> outbox, event and data taken from our own copy of the job
--   tag { id, n, c, p } / untag { id } / tags { reset, list } -> names above zombies (multiplayer)
-- Server text is never trusted: lengths, colors and numbers are checked here again.

require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Bridge"
require "Talky/Talky_Overlay"

Talky_Client = {
    tags = {},        -- [tostring(onlineID)] = { name, color, p }   (multiplayer)
    tagCount = 0,
    tagsVersion = 0,  -- changes with every update, the overlay then matches the zombies again
    tagsRequested = false,
}

local str, num, color = TalkyNet.str, TalkyNet.num, TalkyNet.color
local MAX_TAGS = 256

---------------------------------------------------------------- fx

-- Translated banners the server may ask for (the text is built here, in this player's language).
local BANNER_KEYS = { Toast_ZombieDown = true }

local function fxNotify(a)
    local text
    if a.tkey then
        local key = str(a.tkey, 32, "")
        if not BANNER_KEYS[key] then return end
        text = Talky_T(key, str(a.arg, Talky_Config.maxNameLength, ""))
    else
        text = str(a.text, Talky_Config.maxTextLength, "")
    end
    local from = str(a.from, 32, "")
    if from ~= "" then text = "[" .. from .. "] " .. text end
    Talky_Overlay.toast(text, color(a.color, nil), num(a.seconds, nil, 1, Talky_Config.maxToastSeconds))
end

local function fxSay(a)
    local player = getPlayer()
    if not player then return end
    local text = str(a.text, Talky_Config.maxTextLength, "")
    if text == "" then return end
    -- player:Say() is local only; in multiplayer the "say" chat shows it to nearby players,
    -- unless the server's "say" budget is spent (quiet: the overhead line only)
    if TalkyNet.mode() == "client" and a.quiet ~= true then processSayMessage(text) else player:Say(text) end
end

local function fxHalo(a)
    local player = getPlayer()
    if player then HaloTextHelper.addText(player, str(a.text, Talky_Config.maxTextLength, "")) end
end

-- "dead" already reported for these jobs (one line per job, whatever the number of heal fx)
local healReported, healReportedCount = {}, 0

local function fxHeal(a)
    local player = getPlayer()
    if not player or player:isDead() then
        local seq = TalkyNet.seq(a.seq)
        -- only for a job this game relayed, once per job, and within the budget of the lines the
        -- server asks for (R10): a server cannot make this game write the outbox at will
        local job = seq and Talky_Bridge.findJob(str(a.id, 64, nil), seq)
        if not job or job.done or healReported[seq] then return end
        if healReportedCount >= 256 then healReported, healReportedCount = {}, 0 end
        healReported[seq] = true
        healReportedCount = healReportedCount + 1
        Talky_Bridge.emitFromServer("action_failed", { seq = seq, action = "heal", code = "dead", error = "dead" })
        return
    end
    player:getBodyDamage():RestoreToFullHealth()
end

local FX = { notify = fxNotify, say = fxSay, halo = fxHalo, heal = fxHeal }

---------------------------------------------------------------- events for the bridge

local REASONS = { not_allowed = true, invalid = true, duplicate = true, unknown_action = true, disabled = true, expired = true }

-- Workflow of a job from our own copy (found by id when the server gives one, by seq
-- otherwise), else the server's.
local function workflowOf(seq, given, id)
    local job = seq and Talky_Bridge.findJob(id, seq)
    if job and type(job.workflow) == "string" then return str(job.workflow, 64, "") end
    return str(given, 64, "")
end

local function jobId(d)
    return str(d.id, 64, nil)
end

local function code(v)
    local c = str(v, 32, nil)
    if c and string.match(c, "^[%w_]+$") then return c end
    return nil
end

-- Fixed field sets: anything else from the server is dropped.
local EMITS = {
    zombie_killed = function(d)
        local name = str(d.name, Talky_Config.maxNameLength, nil)
        if not name then return nil end
        return { name = name, byPlayer = d.byPlayer == true }
    end,
    job_done = function(d)
        local seq = TalkyNet.seq(d.seq)
        if not seq then return nil end
        return { seq = seq, workflow = workflowOf(seq, d.workflow, jobId(d)) }
    end,
    action_failed = function(d)
        local seq, action, c = TalkyNet.seq(d.seq), code(d.action), code(d.code)
        if not seq or not action or not c then return nil end
        return { seq = seq, action = action, code = c, error = c }
    end,
    job_rejected = function(d)
        local seq, reason = TalkyNet.seq(d.seq), str(d.reason, 32, nil)
        if not seq or not reason or not REASONS[reason] then return nil end
        return { seq = seq, workflow = workflowOf(seq, d.workflow, jobId(d)), reason = reason }
    end,
    job_expired = function(d)
        local seq = TalkyNet.seq(d.seq)
        if not seq then return nil end
        return { seq = seq, workflow = workflowOf(seq, d.workflow, jobId(d)) }
    end,
}

-- The job is over: the steps of its local copy (kept for its emit steps) can go.
local ENDS = { job_done = true, job_expired = true, job_rejected = true }

local function onEmit(a)
    local event = str(a.event, 32, "")
    local check = EMITS[event]
    if not check then return end
    local raw = type(a.data) == "table" and a.data or {}
    local data = check(raw)
    if not data then return end
    -- dropped before the line is written: the 60-a-minute budget cannot keep a copy alive
    if ENDS[event] then Talky_Bridge.forget(jobId(raw)) end
    Talky_Bridge.emitFromServer(event, data)
end

---------------------------------------------------------------- name tags (multiplayer)

local function setTag(e)
    if type(e) ~= "table" then return end
    local id = TalkyNet.int(e.id, nil, -1, 1000000)
    local name = str(e.n, Talky_Config.maxNameLength, nil)
    if not id or id < 0 or not name or name == "" then return end
    local key = tostring(id)
    if not Talky_Client.tags[key] then
        if Talky_Client.tagCount >= MAX_TAGS then return end
        Talky_Client.tagCount = Talky_Client.tagCount + 1
    end
    Talky_Client.tags[key] = { name = name, color = color(e.c, nil), p = TalkyNet.int(e.p, 0, -2147483648, 2147483647) }
end

local function onTag(a)
    if a.sp then
        Talky_Overlay.rescanSoon()
        return
    end
    setTag(a)
    Talky_Client.tagsVersion = Talky_Client.tagsVersion + 1
end

local function onUntag(a)
    local id = TalkyNet.int(a.id, nil, -1, 1000000)
    if not id then return end
    local key = tostring(id)
    if Talky_Client.tags[key] then
        Talky_Client.tags[key] = nil
        Talky_Client.tagCount = Talky_Client.tagCount - 1
        Talky_Client.tagsVersion = Talky_Client.tagsVersion + 1
    end
end

local function onTags(a)
    if a.reset then Talky_Client.tags, Talky_Client.tagCount = {}, 0 end
    if type(a.list) == "table" then
        for i = 1, math.min(#a.list, MAX_TAGS) do pcall(setTag, a.list[i]) end
    end
    Talky_Client.tagsVersion = Talky_Client.tagsVersion + 1
end

---------------------------------------------------------------- dispatch

local function onHelloAck(a)
    Talky_Bridge.onHelloAck(a)
    -- names already above zombies, once per session (late join)
    if not Talky_Client.tagsRequested and TalkyNet.mode() == "client" then
        Talky_Client.tagsRequested = true
        TalkyNet.toServer("tags", {})
    end
end

Talky_Client.handlers = {
    helloAck = onHelloAck,
    jobAcks = function(a) Talky_Bridge.onJobAcks(a) end,
    fx = function(a)
        local f = FX[str(a.kind, 16, "")]
        if f then f(a) end
    end,
    emit = onEmit,
    emitStep = function(a) Talky_Bridge.onEmitStep(a) end,
    tag = onTag,
    untag = onUntag,
    tags = onTags,
}

function Talky_Client.dispatch(command, args)
    local h = Talky_Client.handlers[command]
    if not h then return end
    h(type(args) == "table" and args or {})
end

TalkyNet.clientHandler = Talky_Client.dispatch

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= TalkyNet.MODULE then return end
    local ok, err = pcall(Talky_Client.dispatch, command, args)
    if not ok then TalkyNet.log("server message " .. tostring(command) .. ": " .. tostring(err)) end
end)

return Talky_Client
