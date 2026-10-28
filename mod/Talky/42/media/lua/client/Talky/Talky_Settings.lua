-- talky_config.json: webhooks, workflows, game events and in-game settings.
-- The window edits it, the bridge watches it and reloads on save.
-- talky_status.json: heartbeat the bridge writes every 2 s (alive, port, test code, ids of the
-- webhooks with a dedicated token, recent events). No token: every mod can read the file.

require "Talky/Talky_Json"
require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Bridge"

Talky_Settings = {
    data = nil,
    status = nil,
    statusReadAt = 0,
}

local function readText(name)
    local lines = Talky_Bridge.readLines(name)
    if not lines then return nil end
    return table.concat(lines, "\n")
end

local function defaults()
    return { publicUrl = "", webhooks = {}, workflows = {}, gameEvents = {}, settings = {} }
end

function Talky_Settings.load()
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

-- Values from the file are clamped to the bounds of the window (the file can be edited by hand).
function Talky_Settings.apply()
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

function Talky_Settings.save()
    local w = getFileWriter(Talky_Config.configFile, true, false)
    if not w then return false end
    w:write(TalkyJson.encode(Talky_Settings.data, "  "))
    w:close()
    Talky_Settings.apply()
    return true
end

function Talky_Settings.get()
    return Talky_Settings.data or Talky_Settings.load()
end

-- Returns status table (or nil) and whether the bridge is alive.
function Talky_Settings.readStatus()
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

local function sortedKeys(t)
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

-- Asks the bridge to run a workflow as if a webhook had arrived. The bridge only accepts it
-- with the test code it wrote in talky_status.json at its start (testNonce), read fresh here.
function Talky_Settings.testWorkflow(name, vars)
    Talky_Settings.statusReadAt = 0
    local st = Talky_Settings.readStatus()
    local nonce = st and TalkyNet.str(st.testNonce, 128, nil) or nil
    Talky_Bridge.emit("test_workflow", { workflow = name, vars = vars or { user = Talky_T("Wf_TestUser") }, nonce = nonce })
end

-- Bridge older than 0.4.0: it reads talky_outbox.jsonl only and knows no test code.
function Talky_Settings.bridgeTooOld()
    local st, alive = Talky_Settings.readStatus()
    if not alive or type(st) ~= "table" then return false end
    return (TalkyNet.num(st.protocol, 1, 0, 1000000)) < 2
end

Events.OnGameStart.Add(Talky_Settings.load)
