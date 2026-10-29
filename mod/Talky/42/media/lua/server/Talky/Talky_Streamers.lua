-- The streamers of a server (server mode): the players an admin added in F8 > Webhooks. The
-- bridge draws a token for each one and writes the list to talky_streamers.json:
--   { "rev": n, "streamers": [ { "name": "<username>", "token": "<hex>", "createdAt": ms } ] }
-- A job of the inbox runs only for one of them ("target"); their token reaches the clients of
-- the admins only (Talky_Server, "streamers" command). Changes go the other way through the
-- outbox: streamer_add / streamer_remove / streamer_token { name, by } (Talky_Server).
-- Read again at most once a second. Runs on the server and in single player only (where it
-- stays empty: single player has no streamer list).

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Json"
require "Talky/Talky_Net"
require "Talky/Talky_Files"

Talky_Streamers = {
    text = nil,      -- last text read
    list = {},       -- { { name, token, key, createdAt } }, in the order of the file
    byKey = {},      -- [TalkyNet.nameKey(name)] = entry
    rev = 0,
    readAt = nil,
}

local S = Talky_Streamers

-- A username as the bridge accepts it: trimmed, 1 to 64 characters, no control character.
function Talky_Streamers.cleanName(v)
    if type(v) ~= "string" then return nil end
    local name = string.match(v, "^%s*(.-)%s*$")
    if not name or name == "" or string.len(name) > Talky_Config.maxStreamerName or string.find(name, "%c") then return nil end
    return name
end

local function parse(text)
    local data = text and TalkyJson.tryDecode(text)
    local list, byKey = {}, {}
    if type(data) == "table" and type(data.streamers) == "table" then
        for i = 1, math.min(#data.streamers, Talky_Config.maxStreamers) do
            local e = data.streamers[i]
            local name = type(e) == "table" and S.cleanName(e.name)
            local token = type(e) == "table" and type(e.token) == "string" and string.match(e.token, "^%x+$") and e.token or nil
            if name and token then
                local key = TalkyNet.nameKey(name)
                if not byKey[key] then
                    local entry = { name = name, token = token, key = key, createdAt = TalkyNet.num(e.createdAt, 0, 0, 1e15) }
                    list[#list + 1] = entry
                    byKey[key] = entry
                end
            end
        end
    end
    return list, byKey, type(data) == "table" and TalkyNet.int(data.rev, 0, 0, 1e12) or 0
end

-- Reads talky_streamers.json again when the last read is a second old (single player: never).
function Talky_Streamers.refresh(force)
    if TalkyNet.mode() ~= "server" then return S end
    local t = getTimestampMs()
    if not force and S.readAt and t - S.readAt < 1000 and t >= S.readAt then return S end
    S.readAt = t
    local text = Talky_Files.readText(Talky_Config.streamersFile)
    if text ~= S.text then
        S.text = text
        S.list, S.byKey, S.rev = parse(text)
    end
    return S
end

-- The entry of a username (A-Z not case-sensitive, like the game's accounts), or nil.
function Talky_Streamers.find(name)
    if type(name) ~= "string" then return nil end
    S.refresh()
    return S.byKey[TalkyNet.nameKey(name)]
end

function Talky_Streamers.isStreamer(player)
    if not player then return false end
    return S.find(TalkyNet.username(player)) ~= nil
end

function Talky_Streamers.all()
    S.refresh()
    return S.list
end

return Talky_Streamers
