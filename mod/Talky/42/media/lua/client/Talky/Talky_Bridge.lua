-- File-based IPC with the Talky bridge (Kahlua cannot open sockets).
--   inbox  : one JSON job per line, each with an increasing "seq"
--   ack    : we write the last seq we executed; the bridge then compacts the inbox
--   outbox : we append game events (zombie killed, player died...) for the bridge

require "Talky/Talky_Json"
require "Talky/Talky_Config"

Talky_Bridge = {
    lastSeq = 0,
    lastPoll = 0,
    onJob = nil, -- set by Talky_Runner
}

function Talky_Bridge.log(msg)
    print("[Talky] " .. tostring(msg))
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

local function writeAck(seq)
    local w = getFileWriter(Talky_Config.ackFile, true, false)
    if not w then return end
    w:write(tostring(seq))
    w:close()
end

function Talky_Bridge.loadAck()
    local lines = readAll(Talky_Config.ackFile)
    Talky_Bridge.lastSeq = (lines and tonumber(lines[1])) or 0
end

function Talky_Bridge.emit(event, data)
    local w = getFileWriter(Talky_Config.outboxFile, true, true)
    if not w then return end
    w:write(TalkyJson.encode({ event = event, data = data or {}, ts = getTimestampMs() }) .. "\n")
    w:close()
end

function Talky_Bridge.poll()
    local lines = readAll(Talky_Config.inboxFile)
    if not lines then return end
    local maxSeq = Talky_Bridge.lastSeq
    for i = 1, #lines do
        local line = lines[i]
        if line ~= "" then
            local job, err = TalkyJson.tryDecode(line)
            if not job then
                Talky_Bridge.log("bad inbox line: " .. tostring(err))
            elseif type(job.seq) == "number" and job.seq > Talky_Bridge.lastSeq then
                if Talky_Bridge.onJob then Talky_Bridge.onJob(job) end
                if job.seq > maxSeq then maxSeq = job.seq end
            end
        end
    end
    if maxSeq ~= Talky_Bridge.lastSeq then
        Talky_Bridge.lastSeq = maxSeq
        writeAck(maxSeq)
    end
end

local function onTick()
    local now = getTimestampMs()
    if now - Talky_Bridge.lastPoll < Talky_Config.pollIntervalMs then return end
    Talky_Bridge.lastPoll = now
    local player = getPlayer()
    if not player or player:isDead() then return end
    local ok, err = pcall(Talky_Bridge.poll)
    if not ok then Talky_Bridge.log("poll error: " .. tostring(err)) end
end

Events.OnGameStart.Add(function()
    Talky_Bridge.loadAck()
    Talky_Bridge.log("ready, last seq = " .. Talky_Bridge.lastSeq)
    Talky_Bridge.emit("game_started", {})
end)
Events.OnTick.Add(onTick)
