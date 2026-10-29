-- The files the Talky server code shares with the bridge, in Zomboid/Lua of the process that
-- runs it: the dedicated server (the account that runs it, or its -cachedir), the server of a
-- hosted game, or the single player game. The only server file that opens files.
--   read : talky_inbox.jsonl (jobs), talky_ack.txt (at start), talky_streamers.json,
--          talky_status.json, talky_config.json (for the admins' F8 window)
--   write: talky_ack.txt, talky_outbox.txt (game events, streamer requests), talky_config.json
--          (saved from the admins' F8 window)
-- The game lets mods write .ini, .cfg, .txt, .log and .json files only.
-- Runs on the server and in single player only.

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Json"
require "Talky/Talky_Net"

Talky_Files = { warned = {} }

-- Only these names, whatever a caller asks (a typo must not write elsewhere in Zomboid/Lua).
local NAMES = {}
for _, k in ipairs({ "inboxFile", "ackFile", "outboxFile", "configFile", "statusFile", "streamersFile" }) do
    NAMES[Talky_Config[k]] = true
end

local function known(name)
    if NAMES[name] then return true end
    TalkyNet.log("file refused: " .. tostring(name))
    return false
end

-- Lines of a file, or nil when it does not exist.
function Talky_Files.readLines(name)
    if not known(name) then return nil end
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

function Talky_Files.readText(name)
    local lines = Talky_Files.readLines(name)
    if not lines then return nil end
    return table.concat(lines, "\n")
end

local function warnOnce(name)
    if Talky_Files.warned[name] then return end
    Talky_Files.warned[name] = true
    TalkyNet.log("cannot write " .. tostring(name))
end

-- Replaces the file (append = false) or adds to it. false when the game refused it.
function Talky_Files.write(name, text, append)
    if not known(name) then return false end
    local w = getFileWriter(name, true, append == true)
    if not w then
        warnOnce(name)
        return false
    end
    w:write(text)
    w:close()
    return true
end

-- One line of talky_outbox.txt for the bridge: { event, data, ts }.
function Talky_Files.event(event, data)
    return Talky_Files.write(Talky_Config.outboxFile,
        TalkyJson.encode({ event = event, data = data or {}, ts = getTimestampMs() }) .. "\n", true)
end

-- An event about a job or a player. Server mode: it names the streamer ("streamer"), whose
-- character the workflows the bridge runs for it go to.
function Talky_Files.streamerEvent(event, data, owner)
    data = data or {}
    if TalkyNet.mode() == "server" and type(owner) == "string" and owner ~= "" then data.streamer = owner end
    return Talky_Files.event(event, data)
end

return Talky_Files
