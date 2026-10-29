-- talky_config.json: webhooks, workflows, game events and the settings of the bridge.
--   single player : the file of this game. The window edits it, the bridge watches it and
--                   reloads on save. talky_status.json is the heartbeat the bridge writes every
--                   2 s (alive, port, test code, ids of the webhooks with a dedicated token,
--                   recent events; no token: every mod can read the file).
--   multiplayer   : the server's file, next to the bridge. An admin's window loads it from the
--                   server and saves it there (Talky_Remote); the bridge's state comes from the
--                   server too, and so do the display settings (names above zombies, banners)
--                   every player applies. A client writes no file.

require "Talky/Talky_Json"
require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Bridge"
require "Talky/Talky_Remote"

Talky_Settings = {
    data = nil,
    status = nil,
    statusReadAt = 0,
}

local function mp() return TalkyNet.mode() == "client" end
Talky_Settings.mp = mp

local function readText(name)
    local lines = Talky_Bridge.readLines(name)
    if not lines then return nil end
    return table.concat(lines, "\n")
end

local function defaults()
    return { publicUrl = "", webhooks = {}, workflows = {}, gameEvents = {}, settings = {} }
end

function Talky_Settings.load()
    if mp() then
        Talky_Settings.data = Talky_Remote.config
        if Talky_Remote.isAdmin() and Talky_Remote.configState == "none" then Talky_Remote.askConfig() end
        Talky_Settings.apply()
        return Talky_Settings.data
    end
    local data
    local text = readText(Talky_Config.configFile)
    if text and text ~= "" then
        local err
        data, err = TalkyJson.tryDecode(text)
        if not data then Talky_Bridge.log("cannot read " .. Talky_Config.configFile .. ": " .. tostring(err)) end
    end
    data = data or defaults()
    for k, v in pairs(defaults()) do
        if data[k] == nil then data[k] = v end
    end
    Talky_Settings.data = data
    Talky_Settings.apply()
    return data
end

-- The window can edit the configuration: always in single player; in multiplayer, an admin
-- whose copy of the server's configuration arrived.
function Talky_Settings.ready()
    if not mp() then return true end
    return Talky_Remote.isAdmin() and Talky_Remote.configState == "ready" and Talky_Remote.config ~= nil
end

-- Values from the file are clamped to the bounds of the window (the file can be edited by hand).
-- Multiplayer: the display settings the server sent (the caps are the server's too).
function Talky_Settings.apply()
    if mp() then return Talky_Remote.applyDisplay(Talky_Remote.display) end
    local s = Talky_Settings.data and Talky_Settings.data.settings or {}
    if type(s) ~= "table" then return end
    for _, opt in ipairs(Talky_Config.editable) do
        local v = s[opt.key]
        if opt.type == "number" then
            v = TalkyNet.num(v, nil, opt.min or -1000000, opt.max or 1000000)
        elseif opt.type == "bool" then
            if type(v) ~= "boolean" then v = nil end
        elseif opt.type == "text" then
            v = TalkyNet.str(v, opt.maxLength or 40, nil)
        elseif opt.type == "choice" then
            local found = false
            for _, c in ipairs(opt.choices) do if c[2] == v then found = true end end
            if not found then v = nil end
        end
        if v ~= nil then Talky_Config[opt.key] = v end
    end
end

-- Single player: writes talky_config.json. Multiplayer: sends the configuration to the server
-- (admins; the server sends its display settings back to every player). Returns ok, reason.
function Talky_Settings.save()
    if mp() then
        if Talky_Settings.ready() then return Talky_Remote.saveConfig(Talky_Settings.data) end
        return false, "not_admin"
    end
    local w = getFileWriter(Talky_Config.configFile, true, false)
    if not w then return false end
    w:write(TalkyJson.encode(Talky_Settings.data, "  "))
    w:close()
    Talky_Settings.apply()
    return true
end

function Talky_Settings.get()
    if mp() then
        if Talky_Settings.ready() then
            Talky_Settings.data = Talky_Remote.config
            return Talky_Settings.data
        end
        -- nothing to edit yet: an empty configuration, never saved
        return defaults()
    end
    return Talky_Settings.data or Talky_Settings.load()
end

-- The table the Settings page edits: the "settings" of talky_config.json (multiplayer: the
-- server's copy an admin edits).
function Talky_Settings.settingsFor(key)
    local d = Talky_Settings.get()
    if type(d.settings) ~= "table" then d.settings = {} end
    return d.settings
end

-- Returns status table (or nil) and whether the bridge is alive. Multiplayer: what the server
-- says of the bridge next to it.
function Talky_Settings.readStatus()
    if mp() then
        local s = Talky_Remote.status
        if not s then return nil, false end
        local b = s.bridge
        return { port = b.port, version = b.version ~= "" and b.version or nil, pending = b.pending, protocol = b.protocol,
                 mode = b.mode, publicUrl = b.publicUrl, recent = s.recent }, b.alive == true
    end
    local now = getTimestampMs()
    if now - Talky_Settings.statusReadAt > 1000 then
        Talky_Settings.statusReadAt = now
        local text = readText(Talky_Config.statusFile)
        if text then Talky_Settings.status = TalkyJson.tryDecode(text) or Talky_Settings.status end
    end
    local st = Talky_Settings.status
    local alive = st ~= nil and type(st.ts) == "number" and now - st.ts < 6000
    return st, alive
end

function Talky_Settings.baseUrl()
    local st = Talky_Settings.status or {}
    local url = Talky_Settings.get().publicUrl
    if not url or url == "" then url = "http://127.0.0.1:" .. tostring(st.port or 7420) end
    return (string.gsub(url, "/+$", ""))
end

-- URL of a webhook with its token masked. The game never builds the real URL: the tokens stay
-- in bridge/config.json, which the game cannot read, and game Lua can read the clipboard.
function Talky_Settings.hookUrl(id)
    return Talky_Settings.baseUrl() .. "/hooks/" .. tostring(id) .. "?token=*****"
end

-- Command that copies the full URL of a webhook, to run in the Talky folder (README: the
-- terminal of "node bridge\bridge.js fire ..."). nil for an id that is not ASCII letters, digits,
-- "-" or "_": talky_config.json can be written by any mod, and a pasted command must not
-- carry shell characters.
function Talky_Settings.urlCommand(id)
    if type(id) ~= "string" or string.len(id) > 64 or not string.match(id, "^[A-Za-z0-9_%-]+$") then return nil end
    return "node bridge\\bridge.js url " .. id
end

-- true / false: the webhook has / has not a dedicated token (ids listed in "hookTokens" of
-- talky_status.json, never the tokens); nil: unknown (no status, or a bridge older than 0.4.0).
function Talky_Settings.hasDedicatedToken(id)
    local st = Talky_Settings.readStatus()
    if type(st) ~= "table" or type(st.hookTokens) ~= "table" then return nil end
    for _, v in ipairs(st.hookTokens) do
        if v == id then return true end
    end
    return false
end

-- Server mode: the address the streamers' widgets call, from what the admin typed:
-- "203.0.113.5" -> "http://203.0.113.5:7420" (http, and the bridge's port, when no scheme is
-- given); "https://talky.example.com/" -> "https://talky.example.com" (a reverse proxy: kept as
-- typed). nil when empty or not http(s).
function Talky_Settings.normalizeAddress(text, port)
    if type(text) ~= "string" then return nil end
    local s = string.match(text, "^%s*(.-)%s*$") or ""
    s = string.gsub(s, "/+$", "")
    if s == "" or string.find(s, "[%s%c\"'<>]") then return nil end
    local scheme = string.match(s, "^(%a[%w+.%-]*)://")
    if scheme then
        scheme = string.lower(scheme)
        if scheme ~= "http" and scheme ~= "https" then return nil end
        if not string.match(s, "^%a[%w+.%-]*://[^/?#]+") then return nil end
        return s
    end
    if not string.find(s, "/") and not string.match(s, ":%d+$") then s = s .. ":" .. tostring(port or 7420) end
    return "http://" .. s
end

-- Server mode: the address of the bridge, as the streamers' widgets call it, or nil.
function Talky_Settings.streamerAddress()
    local port = 7420
    local r = Talky_Remote.streamers
    if r then port = r.port end
    local typed = Talky_Settings.ready() and Talky_Settings.get().publicUrl or nil
    if type(typed) ~= "string" or typed == "" then typed = r and r.publicUrl or "" end
    if typed == "" and Talky_Remote.status then typed = Talky_Remote.status.bridge.publicUrl end
    return Talky_Settings.normalizeAddress(typed, port)
end

local sortedKeys = function(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end
Talky_Settings.sortedKeys = sortedKeys

function Talky_Settings.workflowNames()
    return sortedKeys(Talky_Settings.get().workflows)
end

function Talky_Settings.webhookIds()
    return sortedKeys(Talky_Settings.get().webhooks)
end

-- Asks the bridge to run a workflow as if a webhook had arrived. Single player: the bridge only
-- accepts it with the test code it wrote in talky_status.json at its start (testNonce), read
-- fresh here. Multiplayer (admins): the server writes it, for this player's character.
function Talky_Settings.testWorkflow(name, vars)
    vars = vars or { user = Talky_T("Wf_TestUser") }
    if mp() then return Talky_Remote.test(name, vars) end
    Talky_Settings.statusReadAt = 0
    local st = Talky_Settings.readStatus()
    local nonce = st and TalkyNet.str(st.testNonce, 128, nil) or nil
    return Talky_Bridge.emit("test_workflow", { workflow = name, vars = vars, nonce = nonce })
end

-- A bridge too old for this mode: single player, older than 0.4.0 (it reads
-- talky_outbox.jsonl only and knows no test code); multiplayer, older than 0.5.0 (no server mode).
function Talky_Settings.bridgeTooOld()
    local st, alive = Talky_Settings.readStatus()
    if not alive or type(st) ~= "table" then return false end
    local need = mp() and Talky_Config.bridgeProtocol or 2
    return (TalkyNet.num(st.protocol, 1, 0, 1000000)) < need
end

Events.OnGameStart.Add(Talky_Settings.load)
