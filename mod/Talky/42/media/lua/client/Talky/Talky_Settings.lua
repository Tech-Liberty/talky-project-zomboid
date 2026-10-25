-- talky_config.json: webhooks, workflows, game events and in-game settings.
-- The window edits it, the bridge watches it and reloads on save.
-- talky_status.json: heartbeat the bridge writes every 2 s (alive, port, token, recent events).

require "Talky/Talky_Json"
require "Talky/Talky_Config"
require "Talky/Talky_Text"
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

function Talky_Settings.apply()
    local s = Talky_Settings.data and Talky_Settings.data.settings or {}
    for _, opt in ipairs(Talky_Config.editable) do
        local v = s[opt.key]
        if opt.type == "number" then v = tonumber(v) end
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

-- URL with the token the bridge expects for this webhook: its dedicated token when it
-- has one (the bridge then refuses the global token), otherwise the global one.
function Talky_Settings.hookUrl(id)
    local st = Talky_Settings.status or {}
    local hook = (Talky_Settings.get().webhooks or {})[id]
    local token = st.token
    if type(hook) == "table" and type(hook.token) == "string" and hook.token ~= "" then
        token = hook.token
    end
    return Talky_Settings.baseUrl() .. "/hooks/" .. id .. "?token=" .. tostring(token or "TOKEN")
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

-- Asks the bridge to run a workflow as if a webhook had arrived.
function Talky_Settings.testWorkflow(name, vars)
    Talky_Bridge.emit("test_workflow", { workflow = name, vars = vars or { user = Talky_T("Wf_TestUser") } })
end

Events.OnGameStart.Add(Talky_Settings.load)
