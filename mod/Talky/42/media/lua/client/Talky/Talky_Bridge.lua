-- The few things the game client writes for the bridge itself, in single player only (the
-- jobs are read by the server code, Talky_Inbox, which also writes their results):
--   game_started  when the game starts       { mode = "sp", host = false, server = "" }
--   player_died   when the player dies       (Talky_Overlay)
--   test_workflow the Test now button        (Talky_Settings)
-- In multiplayer the client never touches the bridge's files: in a hosted game they are the
-- server's own files (the server of a hosted game shares Zomboid/Lua with the host's game), and
-- on a dedicated server the bridge is on another machine. The server code writes these events
-- there (game_started, player_died of a streamer; Test now of an admin through Talky_Remote).

require "Talky/Talky_Json"
require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"

Talky_Bridge = {
    writerWarned = false,
    gameStartedSent = false,
}

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

-- One line of talky_outbox.txt. Single player only: false (nothing written) in multiplayer.
function Talky_Bridge.emit(event, data)
    if TalkyNet.mode() ~= "sp" then return false end
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

-- Translated reason of a refused job (UI_Talky_Reason_<code>), or the code itself.
function Talky_Bridge.reasonText(reason)
    local key = "Reason_" .. tostring(reason)
    return Talky_Text.getOrNil(key) or tostring(reason)
end

-- Single player: the server code (server/ files, loaded with the game) reads the jobs. When it
-- did not load, nothing runs: say where the error is.
function Talky_Bridge.serverCodeLoaded()
    return Talky_Inbox ~= nil and Talky_Server ~= nil
end

function Talky_Bridge.start()
    if TalkyNet.mode() ~= "sp" then return end
    if not Talky_Bridge.serverCodeLoaded() then
        Talky_Bridge.log("the Talky game code did not load: look for [Talky] errors in console.txt")
    end
    if not Talky_Bridge.gameStartedSent then
        Talky_Bridge.gameStartedSent = true
        Talky_Bridge.emit("game_started", { mode = "sp", host = false, server = "" })
    end
end

Events.OnGameStart.Add(Talky_Bridge.start)

return Talky_Bridge
