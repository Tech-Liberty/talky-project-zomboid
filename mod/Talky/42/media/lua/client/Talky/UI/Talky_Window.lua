-- Main Talky window: sidebar of pages, everything editable, saved to talky_config.json.
--   single player : the files of this game (the bridge runs on this PC).
--   multiplayer   : what the server says (Talky_Remote). Every player sees the Status page;
--                   the admins (CreateHorde role) manage the streamers (Webhooks page) and the
--                   server's talky_config.json (Workflows, Game events, Settings of the bridge).

require "ISUI/ISCollapsableWindow"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Settings"
require "Talky/Talky_Bridge"
require "Talky/Talky_Remote"
require "Talky/Talky_Overlay"
require "Talky/UI/Talky_Widgets"
require "Talky/UI/Talky_Editors"

Talky_Window = ISCollapsableWindow:derive("Talky_Window")

local C = Talky_UI.col
local ROW, PAD = Talky_UI.ROW, 12
local SIDEBAR = 170

local function fit(text, w)
    return Talky_UI.truncate(text, w)
end

local PAGES = {
    { id = "status",    labelKey = "Page_status" },
    { id = "webhooks",  labelKey = "Page_webhooks" },
    { id = "workflows", labelKey = "Page_workflows" },
    { id = "events",    labelKey = "Page_events" },
    { id = "settings",  labelKey = "Page_settings" },
}

local GAME_EVENTS = {
    { id = "zombie_killed", labelKey = "Event_zombie_killed", vars = "{{name}}, {{byPlayer}}" },
    { id = "player_died",   labelKey = "Event_player_died",   vars = "{{hoursSurvived}}, {{zombieKills}}" },
    { id = "game_started",  labelKey = "Event_game_started",  vars = "" },
}

-- Reasons the bridge gives (in English) for a skipped event, shown translated when known.
local function skipReason(reason)
    local key = "Skip_" .. string.gsub(tostring(reason), "[^%w]", "_")
    return Talky_Text.getOrNil(key) or tostring(reason)
end

---------------------------------------------------------------- open / close

function Talky_Window.toggle()
    if Talky_Window.instance and Talky_Window.instance:isVisible() then
        Talky_Window.instance:close()
        return
    end
    Talky_Settings.load()
    if Talky_Remote.active() then
        Talky_Remote.askStatus()
        -- a fresh copy of the server's configuration (another admin may have changed it)
        if Talky_Remote.isAdmin() and Talky_Remote.configState ~= "loading" then Talky_Remote.askConfig() end
    end
    local w, h = 940, 620
    local o = Talky_Window:new((getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2, w, h)
    o:initialise()
    o:addToUIManager()
    Talky_Window.instance = o
end

-- Multiplayer: what the server says changes the page only when it changes what the page shows
-- (a page drawn again loses the text box being typed in).
local function remoteSignature(what)
    local R = Talky_Remote
    if what == "streamers" then
        local parts = {}
        for _, e in ipairs(R.streamers and R.streamers.list or {}) do
            parts[#parts + 1] = e.name .. "=" .. e.token .. (e.online and "+" or "")
        end
        local s = R.streamers
        return table.concat(parts, ",") .. "|" .. tostring(s and s.publicUrl) .. "|" .. tostring(s and s.bridge)
    end
    local s = R.status
    if not s then return R.state end
    local recent = s.recent and s.recent[1]
    return R.state .. "|" .. tostring(s.admin) .. tostring(s.streamer) .. tostring(s.bridge.alive) .. s.bridge.mode
        .. tostring(s.bridge.protocol) .. "|" .. tostring(recent and recent.at) .. tostring(s.bridge.pending)
end

function Talky_Remote.onChange(what)
    local win = Talky_Window.instance
    if not win then return end
    if what == "status" or what == "streamers" then
        local sig = remoteSignature(what)
        if win.remoteSig and win.remoteSig[what] == sig then return end
        win.remoteSig = win.remoteSig or {}
        win.remoteSig[what] = sig
    elseif what == "configSaved" then
        local r = Talky_Remote.lastSave
        if r and r.ok then
            win.dirty = false
            Talky_Overlay.toast(Talky_T("Toast_SavedServer"), "#8b5cf6", 3)
        else
            Talky_Overlay.toast(Talky_T("Toast_SaveFailed", Talky_T("Save_" .. tostring(r and r.error or "error"))), "#ff5555", 4)
        end
        return
    elseif what == "testAck" then
        local r = Talky_Remote.lastTest
        if r and not r.ok then Talky_Overlay.toast(Talky_T("Toast_TestFailed", Talky_T("Test_" .. tostring(r.error or "invalid"))), "#ff5555", 4) end
        return
    elseif what == "streamerAck" then
        local a = Talky_Remote.lastAck
        if a and not a.ok then
            Talky_Overlay.toast(Talky_T("Toast_StreamerRefused", Talky_T("Ack_" .. tostring(a.reason or "error"))), "#ff5555", 4)
        elseif a then
            Talky_Overlay.toast(Talky_T("Toast_StreamerAsked", a.name), "#8b5cf6", 3)
        end
    elseif what == "config" then
        Talky_Settings.data = Talky_Remote.config
        win.dirty = false
    elseif what == "display" then
        -- new display settings: only the read-only Settings page shows them (an admin may be typing)
        if win.pageId ~= "settings" or Talky_Settings.ready() then return end
    end
    win:showPage(win.pageId)
end

function Talky_Window:initialise()
    ISCollapsableWindow.initialise(self)
    self:setTitle("Talky")
    self.backgroundColor = { r = C.bg.r, g = C.bg.g, b = C.bg.b, a = C.bg.a }
    self.borderColor = { r = C.accent.r, g = C.accent.g, b = C.accent.b, a = 1 }
    self:setResizable(false)
    self.dirty = false
    self.pageId = "status"
end

function Talky_Window:close()
    self:setVisible(false)
    self:removeFromUIManager()
    Talky_Window.instance = nil
end

function Talky_Window:data() return Talky_Settings.get() end

function Talky_Window:markDirty()
    self.dirty = true
end

---------------------------------------------------------------- frame

function Talky_Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight()
    self.navButtons = {}
    local y = top + 56
    for _, p in ipairs(PAGES) do
        local b = Talky_UI.button(self, PAD, y, SIDEBAR - PAD * 2, Talky_T(p.labelKey), self, Talky_Window.onNav)
        b.pageId = p.id
        self.navButtons[p.id] = b
        y = y + ROW + 6
    end
    local fy = self.height - ROW - PAD
    self.saveBtn = Talky_UI.button(self, self.width - PAD - 150, fy, 150, Talky_T("Btn_Save"), self, Talky_Window.onSave, "primary")
    Talky_UI.button(self, self.width - PAD * 2 - 270, fy, 120, Talky_T("Btn_Close"), self, Talky_Window.close)
    Talky_UI.button(self, SIDEBAR + PAD, fy, 170, Talky_T("Btn_Reload"), self, Talky_Window.onReload)
    self:showPage(self.pageId)
end

function Talky_Window:prerender()
    ISCollapsableWindow.prerender(self)
    Talky_Remote.refresh(self.pageId)
    local top = self:titleBarHeight()
    -- sidebar
    self:drawRect(0, top, SIDEBAR, self.height - top, 1, C.panel.r, C.panel.g, C.panel.b)
    self:drawRect(SIDEBAR, top, 1, self.height - top, 1, C.border.r, C.border.g, C.border.b)
    self:drawText("TALKY", PAD, top + 10, C.accent.r, C.accent.g, C.accent.b, 1, UIFont.Large)
    self:drawText("LibertyTalk Live Events", PAD, top + 34, C.muted.r, C.muted.g, C.muted.b, 1, UIFont.Small)
    -- bridge status pill at the bottom of the sidebar
    local _, alive = Talky_Settings.readStatus()
    local c = alive and C.ok or C.bad
    local sy = self.height - ROW - PAD
    self:drawRect(PAD, sy + ROW / 2 - 4, 8, 8, 1, c.r, c.g, c.b)
    self:drawText(alive and Talky_T("Bridge_Online") or Talky_T("Bridge_Offline"), PAD + 16, sy + (ROW - Talky_UI.LINE) / 2, c.r, c.g, c.b, 1, UIFont.Small)
    -- highlight current page
    for id, b in pairs(self.navButtons) do
        if id == self.pageId then
            b.backgroundColor = { r = C.accent.r * 0.55, g = C.accent.g * 0.55, b = C.accent.b * 0.55, a = 1 }
        else
            b.backgroundColor = { r = 0.16, g = 0.15, b = 0.20, a = 1 }
        end
    end
    self.saveBtn:setTitle(self.dirty and Talky_T("Btn_SaveDirty") or Talky_T("Btn_Save"))
end

function Talky_Window:onNav(button)
    self:showPage(button.pageId)
end

function Talky_Window:showPage(id)
    if self.page then self:removeChild(self.page) end
    self.pageId = id
    local top = self:titleBarHeight() + PAD
    local x = SIDEBAR + PAD
    self.page = Talky_UI.panel(self, x, top, self.width - x - PAD, self.height - top - ROW - PAD * 3)
    self.page.win = self
    local builder = Talky_Window["page_" .. id]
    builder(self, self.page)
end

-- Multiplayer: the configuration of an admin is sent to the server (the toast comes with its
-- answer, Talky_Remote.onChange); another player has nothing to save.
function Talky_Window:onSave()
    local ok, reason = Talky_Settings.save()
    if Talky_Settings.mp() then
        if Talky_Settings.ready() and not ok then
            Talky_Overlay.toast(Talky_T("Toast_SaveFailed", Talky_T("Save_" .. tostring(reason or "error"))), "#ff5555", 4)
        end
        return
    end
    if ok then
        self.dirty = false
        Talky_Overlay.toast(Talky_T("Toast_Saved"), "#8b5cf6", 3)
    end
end

function Talky_Window:onReload()
    if Talky_Settings.mp() and Talky_Remote.isAdmin() then Talky_Remote.askConfig() end
    Talky_Settings.load()
    self.dirty = false
    self:showPage(self.pageId)
end

-- Multiplayer pages an admin only may open: nil when the page may be built, else the y below
-- the message drawn instead (not an admin, or the server's configuration not there yet).
function Talky_Window:adminGate(page, y)
    if not Talky_Settings.mp() then return nil end
    local w = page.width
    if not Talky_Remote.isAdmin() then
        Talky_UI.label(page, 0, y, fit(Talky_T("Admin_Only"), w), C.muted)
        y = y + ROW
        if Talky_Remote.isHost() then
            Talky_UI.label(page, 0, y, fit(Talky_T("Server_HostNotAdmin"), w - 200), C.text)
            Talky_UI.button(page, w - 190, y, 190, Talky_T("Btn_AllowMe"), self, function(win)
                if Talky_Remote.allowMe() then Talky_Overlay.toast(Talky_T("Toast_AllowMeSent"), "#8b5cf6", 4) end
            end, "primary")
            y = y + ROW
        end
        return y
    end
    if not Talky_Settings.ready() then
        if Talky_Remote.configState == "error" then
            Talky_UI.label(page, 0, y, fit(Talky_T("Admin_LoadError", tostring(Talky_Remote.configError)), w), C.bad)
        else
            Talky_UI.label(page, 0, y, fit(Talky_T("Admin_Loading"), w), C.muted)
        end
        return y + ROW
    end
    return nil
end

local function title(page, text, y)
    Talky_UI.label(page, 0, y or 0, text, C.text, UIFont.Medium)
end

---------------------------------------------------------------- page: status

local reasonText = Talky_Bridge.reasonText

-- Comma-separated names of the categories the server turned off ("" when none).
-- Texts: UI_Talky_Cat_<category>.
local function disabledCategories(caps)
    local names = {}
    for _, cat in ipairs(Talky_Config.categories) do
        local key = "Cat_" .. cat
        if caps.allow and caps.allow[cat] == false then names[#names + 1] = Talky_T(key) end
    end
    return table.concat(names, ", ")
end

-- The server's limits and the categories it turned off. Returns the next y.
local function capsLines(page, y, caps)
    if not caps then return y end
    local w = page.width
    Talky_UI.label(page, 0, y, fit(Talky_T("Server_Caps", caps.maxZombiesPerAction or "?", caps.maxZombiesPerJob or "?",
        caps.maxSpawnDistance or "?", caps.maxActiveJobs or "?"), w), C.muted)
    y = y + ROW
    local off = disabledCategories(caps)
    if off ~= "" then
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_Disabled", off), w), C.muted)
        y = y + ROW
    end
    return y
end

-- The last events of the bridge (solo: talky_status.json; multiplayer: from the server, admins).
local function recentList(page, y, recent)
    Talky_UI.label(page, 0, y, Talky_T("Status_Recent"), C.muted)
    y = y + ROW
    local log = Talky_UI.list(page, 0, y, page.width, page.height - y)
    for _, e in ipairs(recent or {}) do
        local when = string.sub(tostring(e.at or ""), 12, 19)
        local txt = when .. "  " .. tostring(e.source or "-") .. "  ->  " .. tostring(e.workflow or "-") .. "  (" .. tostring(e.user or "-") .. ")"
        if e.streamer then txt = txt .. "  " .. Talky_T("Status_ForStreamer", tostring(e.streamer)) end
        if e.skipped then txt = txt .. "  " .. Talky_T("Status_Skipped", skipReason(e.skipped)) end
        if e.rejected then
            txt = txt .. "  " .. Talky_T("Status_Rejected", reasonText(e.rejected))
        elseif e.error and not e.skipped then
            -- "error" is the English text for windows older than 0.4.0; "skipped" is translated
            txt = txt .. "  " .. Talky_T("Status_Error", tostring(e.error))
        end
        log:addItem(txt, e)
    end
    if #log.items == 0 then log:addItem(Talky_T("Status_Nothing"), nil) end
end

-- "Copy command" buttons: the clipboard gets the bridge command that copies the full URL
-- (node bridge\bridge.js url <id>), never a URL with its token.
function Talky_Window:copyUrlCommand(id)
    local cmd = Talky_Settings.urlCommand(id)
    if not cmd then
        Talky_Overlay.toast(Talky_T("Toast_HookIdUnsafe", tostring(id)), "#ff5555", 4)
        return
    end
    Clipboard.setClipboard(cmd)
    Talky_Overlay.toast(Talky_T("Toast_CommandCopied", id), "#8b5cf6", 4)
end

function Talky_Window:page_status(page)
    if Talky_Settings.mp() then return self:page_status_mp(page) end
    local d = self:data()
    local st, alive = Talky_Settings.readStatus()
    title(page, Talky_T("Page_status"))
    local y = ROW + 10
    if alive then
        local line = Talky_T("Status_Online", tostring(st.port), tostring(st.pending or 0))
        if st.version then line = line .. "  (v" .. tostring(st.version) .. ")" end
        Talky_UI.label(page, 0, y, line, C.ok)
    else
        Talky_UI.label(page, 0, y, Talky_T("Status_Offline"), C.bad)
    end
    y = y + ROW
    if Talky_Settings.bridgeTooOld() then
        Talky_UI.label(page, 0, y, fit(Talky_T("Bridge_TooOld"), page.width), C.bad)
        y = y + ROW
    end
    -- the server/ files read the jobs: when they did not load, nothing runs (errors in console.txt)
    if Talky_Bridge.serverCodeLoaded() then
        Talky_UI.label(page, 0, y, fit(Talky_T("Mode_Solo"), page.width), C.muted)
    else
        Talky_UI.label(page, 0, y, fit(Talky_T("Solo_NoAnswer"), page.width), C.bad)
    end
    y = y + ROW + 12

    Talky_UI.label(page, 0, y, Talky_T("Status_PublicUrl"), C.muted)
    y = y + ROW
    Talky_UI.entry(page, 0, y, page.width, d.publicUrl, self, function(win, text)
        d.publicUrl = text
        win:markDirty()
    end)
    y = y + ROW + 12

    Talky_UI.label(page, 0, y, Talky_T("Status_HookUrls"), C.muted)
    y = y + ROW
    local listRows = 6
    local list = Talky_UI.list(page, 0, y, page.width - 160, ROW * listRows)
    for _, id in ipairs(Talky_Settings.webhookIds()) do
        local hook = d.webhooks[id]
        local target = hook.routes and Talky_T("Status_Routes") or tostring(hook.workflow or "?")
        list:addItem(Talky_Settings.hookUrl(id) .. "   ->  " .. target, id)
    end
    Talky_UI.button(page, page.width - 150, y, 150, Talky_T("Btn_CopyCommand"), self, function(win)
        local item = list.items[list.selected]
        if item then win:copyUrlCommand(item.item) end
    end, "primary")
    y = y + ROW * listRows + 4
    Talky_UI.label(page, 0, y, fit(Talky_T("Status_UrlCommandHelp"), page.width), C.muted)
    y = y + ROW + 8
    recentList(page, y, st and st.recent)
end

-- Multiplayer: the answer of the server, this player's place (streamer, admin), the bridge of
-- the server, its limits; for the admins, the last events of the bridge.
function Talky_Window:page_status_mp(page)
    local R = Talky_Remote
    local w = page.width
    title(page, Talky_T("Page_status"))
    local y = ROW + 10
    local s = R.status
    if not s then
        local key = R.state == "no_answer" and "Server_NoAnswer" or "Server_Waiting"
        Talky_UI.label(page, 0, y, fit(Talky_T(key), w), R.state == "no_answer" and C.bad or C.muted)
        return
    end
    Talky_UI.label(page, 0, y, fit(Talky_T("Server_Ready", s.version), w), C.ok)
    y = y + ROW
    if s.streamer then
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_YouStreamer"), w), C.ok)
    else
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_NotStreamer"), w), C.muted)
    end
    y = y + ROW
    if s.admin then
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_YouAdmin"), w), C.text)
        y = y + ROW
    elseif R.isHost() then
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_HostNotAdmin"), w - 200), C.text)
        Talky_UI.button(page, w - 190, y, 190, Talky_T("Btn_AllowMe"), self, function(win)
            if R.allowMe() then Talky_Overlay.toast(Talky_T("Toast_AllowMeSent"), "#8b5cf6", 4) end
        end, "primary")
        y = y + ROW
    end
    local b = s.bridge
    if not b.alive then
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_BridgeOffline"), w), C.bad)
        y = y + ROW
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_BridgeOfflineHelp"), w), C.muted)
    elseif b.mode ~= "server" then
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_BridgeSolo"), w), C.bad)
    elseif b.protocol < Talky_Config.bridgeProtocol then
        Talky_UI.label(page, 0, y, fit(Talky_T("Bridge_TooOldServer"), w), C.bad)
    else
        Talky_UI.label(page, 0, y, fit(Talky_T("Server_BridgeOnline", b.version, tostring(b.port)), w), C.ok)
    end
    y = y + ROW
    y = capsLines(page, y, s.caps) + 12
    if s.admin then recentList(page, y, s.recent) end
end

---------------------------------------------------------------- page: webhooks

local function workflowOptions(withNone, withRoutes)
    local opts = {}
    if withNone then opts[#opts + 1] = { Talky_T("Opt_None"), "" } end
    for _, n in ipairs(Talky_Settings.workflowNames()) do opts[#opts + 1] = { n, n } end
    if withRoutes then opts[#opts + 1] = { Talky_T("Opt_Routes"), "__routes" } end
    return opts
end

function Talky_Window:page_webhooks(page)
    if Talky_Settings.mp() then return self:page_webhooks_mp(page) end
    title(page, Talky_T("Page_webhooks"))
    local y = ROW + 10
    Talky_UI.label(page, 0, y, Talky_T("Hooks_Intro"), C.muted)
    y = y + ROW + 6
    self:webhookEditor(page, y, true)
end

-- The webhooks (one /hooks/<id> each) and the selected one: its workflow or its routes. Single
-- player also shows whether it has a dedicated token and the Copy command button.
function Talky_Window:webhookEditor(page, y, solo)
    local d = self:data()
    local listW = 220
    local list = Talky_UI.list(page, 0, y, listW, page.height - y - ROW - 8, self, function(win, id)
        win.selectedHook = id
        win:showPage("webhooks")
    end)
    for _, id in ipairs(Talky_Settings.webhookIds()) do
        list:addItem(id, id)
        if id == self.selectedHook then list.selected = #list.items end
    end
    Talky_UI.button(page, 0, page.height - ROW, 105, Talky_T("Btn_New"), self, function(win)
        local n, id = 1, "webhook1"
        while d.webhooks[id] do n = n + 1; id = "webhook" .. n end
        d.webhooks[id] = { workflow = Talky_Settings.workflowNames()[1] }
        win.selectedHook = id
        win:markDirty()
        win:showPage("webhooks")
    end)
    Talky_UI.button(page, 115, page.height - ROW, 105, Talky_T("Btn_Delete"), self, function(win)
        if win.selectedHook then
            d.webhooks[win.selectedHook] = nil
            win.selectedHook = nil
            win:markDirty()
            win:showPage("webhooks")
        end
    end, "danger")

    local id = self.selectedHook
    local hook = id and d.webhooks[id]
    local x, w = listW + 20, page.width - listW - 20
    if not hook then
        Talky_UI.label(page, x, y, Talky_T("Hooks_SelectLeft"), C.muted)
        return
    end

    Talky_UI.label(page, x, y, Talky_T("Hooks_Id"), C.muted)
    local idEntry = Talky_UI.entry(page, x, y + ROW, w - 130, id)
    Talky_UI.button(page, x + w - 120, y + ROW, 120, Talky_T("Btn_Rename"), self, function(win)
        local newId = string.gsub(idEntry:getText(), "[^%w_%-]", "")
        if newId ~= "" and newId ~= id and not d.webhooks[newId] then
            d.webhooks[newId] = hook
            d.webhooks[id] = nil
            win.selectedHook = newId
            win:markDirty()
            win:showPage("webhooks")
        end
    end)
    y = y + ROW * 2 + 12

    Talky_UI.label(page, x, y, Talky_T("Hooks_Runs"), C.muted)
    local current = hook.routes and "__routes" or hook.workflow
    if type(current) == "table" then current = current[1] end
    Talky_UI.combo(page, x, y + ROW, w, workflowOptions(false, true), current, self, function(win, value)
        if value == "__routes" then
            hook.routes = hook.routes or { { when = { reward_title = { contains = "example" } }, workflow = Talky_Settings.workflowNames()[1] } }
            hook.workflow = nil
        else
            hook.workflow = value
            hook.routes = nil
        end
        win:markDirty()
        win:showPage("webhooks")
    end)
    y = y + ROW * 2 + 12

    if hook.routes then
        Talky_UI.label(page, x, y, Talky_T("Hooks_RoutesCount", #hook.routes), C.text)
        Talky_UI.button(page, x, y + ROW + 4, 200, Talky_T("Btn_EditRoutes"), self, function(win)
            Talky_JsonEditor.open(Talky_T("Hooks_RoutesTitle", id), Talky_T("Hooks_RoutesHelp"),
                hook.routes, function(v) hook.routes = v or {}; win:markDirty(); win:showPage("webhooks") end)
        end)
        y = y + ROW * 2 + 16
    end

    if solo then
        -- Read only: a dedicated token lives in bridge/config.json (the game cannot read it); the
        -- bridge lists in talky_status.json which webhooks have one, never the token.
        Talky_UI.label(page, x, y, Talky_T("Hooks_TokenTitle"), C.muted)
        local dedicated = Talky_Settings.hasDedicatedToken(id)
        local tokenKey = dedicated == true and "Hooks_TokenYes" or dedicated == false and "Hooks_TokenNo" or "Hooks_TokenUnknown"
        Talky_UI.label(page, x, y + ROW, fit(Talky_T(tokenKey), w), dedicated == nil and C.muted or C.text)
        Talky_UI.label(page, x, y + ROW * 2, fit(Talky_T("Hooks_TokenWhere"), w), C.muted)
        y = y + ROW * 3 + 12
        Talky_UI.button(page, x, y, 200, Talky_T("Btn_CopyCommand"), self, function(win)
            win:copyUrlCommand(id)
        end, "primary")
        y = y + ROW + 8
    else
        Talky_UI.label(page, x, y, fit(Talky_T("Hooks_ServerToken"), w), C.muted)
        y = y + ROW + 8
    end
    Talky_UI.label(page, x, y, Talky_T("Hooks_BodyHint"), C.muted)
    Talky_UI.label(page, x, y + ROW, Talky_T("Hooks_BodyExample"), C.text)
end

-- Multiplayer, admins: the streamers of the server (their tokens, the address of the bridge)
-- and the webhooks of the server's configuration.
function Talky_Window:page_webhooks_mp(page)
    title(page, Talky_T("Page_webhooks"))
    local y = ROW + 10
    if self:adminGate(page, y) then return end
    self.hooksTab = self.hooksTab or "streamers"
    Talky_UI.button(page, 0, y, 160, Talky_T("Tab_Streamers"), self, function(win)
        win.hooksTab = "streamers"
        win:showPage("webhooks")
    end, self.hooksTab == "streamers" and "primary" or nil)
    Talky_UI.button(page, 170, y, 160, Talky_T("Tab_Webhooks"), self, function(win)
        win.hooksTab = "webhooks"
        win:showPage("webhooks")
    end, self.hooksTab == "webhooks" and "primary" or nil)
    y = y + ROW + 10
    if self.hooksTab == "webhooks" then
        Talky_UI.label(page, 0, y, fit(Talky_T("Hooks_IntroServer"), page.width), C.muted)
        return self:webhookEditor(page, y + ROW + 6, false)
    end
    self:streamersPanel(page, y)
end

-- The streamers: add one (a username), then, for the selected one, what goes into their
-- LibertyTalk widget. The token is masked until "Show token"; Copy puts the address and the
-- token in the clipboard, to send to the streamer (never on stream).
function Talky_Window:streamersPanel(page, y)
    local R = Talky_Remote
    local d = self:data()
    local w = page.width
    -- a fresh list (prerender asks again every 3 s while this page is open)
    local asked = R.streamersAskedAt
    if not R.streamers or not asked or getTimestampMs() - asked >= 3000 or getTimestampMs() < asked then R.askStreamers() end
    Talky_UI.label(page, 0, y, fit(Talky_T("Stream_Address"), w), C.muted)
    y = y + ROW
    Talky_UI.entry(page, 0, y, w, d.publicUrl or "", self, function(win, text)
        d.publicUrl = text
        win:markDirty()
    end)
    y = y + ROW + 2
    Talky_UI.label(page, 0, y, fit(Talky_T("Stream_AddressHelp"), w), C.muted)
    Talky_UI.label(page, 0, y + ROW, fit(Talky_T("Stream_AddressHttps"), w), C.muted)
    y = y + ROW * 2 + 6
    local s = R.streamers
    if s and not s.bridge then
        Talky_UI.label(page, 0, y, fit(Talky_T("Stream_BridgeOff"), w), C.bad)
        y = y + ROW
    end
    local listW = 220
    local top = y
    local by = page.height - ROW * 2 - 6
    local list = Talky_UI.list(page, 0, y, listW, by - y - 6, self, function(win, name)
        if name then
            win.selectedStreamer = name
            win.showToken = false
            win:showPage("webhooks")
        end
    end)
    local entry
    for _, e in ipairs(s and s.list or {}) do
        list:addItem(e.online and Talky_T("Stream_Online", e.name) or e.name, e.name)
        if self.selectedStreamer and TalkyNet.nameKey(e.name) == TalkyNet.nameKey(self.selectedStreamer) then
            list.selected = #list.items
            entry = e
        end
    end
    if #list.items == 0 then list:addItem(Talky_T("Stream_None"), nil) end
    Talky_UI.entry(page, 0, by, listW, self.newStreamer or "", self, function(win, text) win.newStreamer = text end)
    Talky_UI.button(page, 0, by + ROW + 6, listW, Talky_T("Btn_AddStreamer"), self, function(win)
        local name = string.match(tostring(win.newStreamer or ""), "^%s*(.-)%s*$") or ""
        if name == "" then return end
        if R.streamerOp("add", name) then
            win.selectedStreamer = name
            win.newStreamer = ""
            win.showToken = false
            win:showPage("webhooks")
        end
    end, "primary")

    local x, dw = listW + 20, w - listW - 20
    if not entry then
        local key = self.selectedStreamer and "Stream_Pending" or "Stream_SelectLeft"
        Talky_UI.label(page, x, top, fit(Talky_T(key, tostring(self.selectedStreamer)), dw), C.muted)
        return
    end
    local addr = Talky_Settings.streamerAddress()
    local yy = top
    Talky_UI.label(page, x, yy, fit(entry.online and Talky_T("Stream_Online", entry.name) or entry.name, dw), C.text, UIFont.Medium)
    yy = yy + ROW + 6
    Talky_UI.label(page, x, yy, fit(Talky_T("Stream_ForWidget"), dw), C.muted)
    yy = yy + ROW
    local token = self.showToken and entry.token or "*****"
    if addr then
        Talky_UI.label(page, x, yy, fit(Talky_T("Stream_WidgetUrl", addr), dw), C.text)
    else
        Talky_UI.label(page, x, yy, fit(Talky_T("Stream_AddressMissing"), dw), C.bad)
    end
    yy = yy + ROW
    Talky_UI.label(page, x, yy, fit(Talky_T("Stream_WidgetToken", token), dw), C.text)
    yy = yy + ROW + 6
    if addr then
        -- the form of a webhook URL, for a LibertyTalk workflow written by hand
        Talky_UI.label(page, x, yy, fit(Talky_T("Stream_HookUrl"), dw), C.muted)
        Talky_UI.label(page, x, yy + ROW, fit(addr .. "/hooks/follow?token=" .. token, dw), C.muted)
        yy = yy + ROW * 2 + 6
    end
    local bw = math.floor((dw - 10) / 2)
    Talky_UI.button(page, x, yy, bw, Talky_T(self.showToken and "Btn_HideToken" or "Btn_ShowToken"), self, function(win)
        win.showToken = not win.showToken
        win:showPage("webhooks")
    end)
    Talky_UI.button(page, x + bw + 10, yy, bw, Talky_T("Btn_CopyForStreamer"), self, function(win)
        win:copyForStreamer(entry)
    end, "primary")
    yy = yy + ROW + 6
    Talky_UI.button(page, x, yy, bw, Talky_T("Btn_NewToken"), self, function(win)
        R.streamerOp("token", entry.name)
        win.showToken = false
    end)
    Talky_UI.button(page, x + bw + 10, yy, bw, Talky_T("Btn_RemoveStreamer"), self, function(win)
        R.streamerOp("remove", entry.name)
        win.selectedStreamer = nil
        win:showPage("webhooks")
    end, "danger")
    yy = yy + ROW + 8
    Talky_UI.label(page, x, yy, fit(Talky_T("Stream_CopyHelp"), dw), C.muted)
end

-- The two values of the streamer's LibertyTalk widget, one per line.
function Talky_Window:copyForStreamer(entry)
    local addr = Talky_Settings.streamerAddress()
    if not addr then
        Talky_Overlay.toast(Talky_T("Stream_AddressMissing"), "#ff5555", 4)
        return
    end
    Clipboard.setClipboard(Talky_T("Stream_WidgetUrl", addr) .. "\n" .. Talky_T("Stream_WidgetToken", entry.token))
    Talky_Overlay.toast(Talky_T("Toast_StreamerCopied", entry.name), "#8b5cf6", 5)
end

---------------------------------------------------------------- page: workflows

local function newWorkflowName(d, base)
    local n, name = 1, base
    while d.workflows[name] do n = n + 1; name = base .. "_" .. n end
    return name
end

function Talky_Window:page_workflows(page)
    title(page, Talky_T("Page_workflows"))
    local y = ROW + 10
    if self:adminGate(page, y) then return end
    local d = self:data()
    local listW = 200
    local list = Talky_UI.list(page, 0, y, listW, page.height - y - ROW * 2 - 14, self, function(win, name)
        win.selectedWf = name
        win.selectedStep = nil
        win:showPage("workflows")
    end)
    for _, name in ipairs(Talky_Settings.workflowNames()) do
        local wf = d.workflows[name]
        list:addItem((wf.enabled == false and (Talky_T("Wf_Off") .. " ") or "") .. name, name)
        if name == self.selectedWf then list.selected = #list.items end
    end
    local by = page.height - ROW * 2 - 6
    Talky_UI.button(page, 0, by, 95, Talky_T("Btn_New"), self, function(win)
        local name = newWorkflowName(d, "workflow")
        d.workflows[name] = { steps = { { action = "notify", text = "{{user}} !" } } }
        win.selectedWf = name
        win:markDirty()
        win:showPage("workflows")
    end)
    Talky_UI.button(page, 105, by, 95, Talky_T("Btn_Duplicate"), self, function(win)
        if not win.selectedWf then return end
        local name = newWorkflowName(d, win.selectedWf)
        d.workflows[name] = Talky_UI.deepCopy(d.workflows[win.selectedWf])
        win.selectedWf = name
        win:markDirty()
        win:showPage("workflows")
    end)
    Talky_UI.button(page, 0, by + ROW + 6, 200, Talky_T("Btn_Delete"), self, function(win)
        if not win.selectedWf then return end
        d.workflows[win.selectedWf] = nil
        win.selectedWf = nil
        win:markDirty()
        win:showPage("workflows")
    end, "danger")

    local name = self.selectedWf
    local wf = name and d.workflows[name]
    local x, w = listW + 20, page.width - listW - 20
    if not wf then
        Talky_UI.label(page, x, y, Talky_T("Wf_SelectLeft"), C.muted)
        return
    end
    wf.steps = wf.steps or {}

    -- name + enabled
    local nameEntry = Talky_UI.entry(page, x, y, w - 250, name)
    Talky_UI.button(page, x + w - 240, y, 110, Talky_T("Btn_Rename"), self, function(win)
        local newName = string.gsub(nameEntry:getText(), "[^%w_%-]", "")
        if newName == "" or newName == name or d.workflows[newName] then return end
        d.workflows[newName] = wf
        d.workflows[name] = nil
        -- keep references from webhooks and game events
        for _, hook in pairs(d.webhooks) do
            if hook.workflow == name then hook.workflow = newName end
            for _, r in ipairs(hook.routes or {}) do if r.workflow == name then r.workflow = newName end end
        end
        for ev, target in pairs(d.gameEvents) do if target == name then d.gameEvents[ev] = newName end end
        win.selectedWf = newName
        win:markDirty()
        win:showPage("workflows")
    end)
    Talky_UI.tick(page, x + w - 120, y, 120, Talky_T("Wf_Enabled"), wf.enabled ~= false, self, function(win, on)
        if on then wf.enabled = nil else wf.enabled = false end
        win:markDirty()
    end)
    y = y + ROW + 10

    -- cooldowns / chance
    local third = (w - 20) / 3
    local fields = {
        { key = "cooldownSeconds", labelKey = "Wf_Cooldown" },
        { key = "userCooldownSeconds", labelKey = "Wf_UserCooldown" },
        { key = "chance", labelKey = "Wf_Chance" },
    }
    for i, f in ipairs(fields) do
        local fx = x + (i - 1) * (third + 10)
        Talky_UI.label(page, fx, y, Talky_T(f.labelKey), C.muted)
        Talky_UI.entry(page, fx, y + ROW, third, wf[f.key] or "", self, function(win, text)
            wf[f.key] = tonumber(text)
            win:markDirty()
        end)
    end
    y = y + ROW * 2 + 10

    -- condition
    local cond = wf.when and TalkyJson.encode(wf.when) or Talky_T("Wf_Always")
    Talky_UI.label(page, x, y, Talky_UI.truncate(Talky_T("Wf_Condition", cond), w - 230), C.text)
    Talky_UI.button(page, x + w - 210, y, 210, Talky_T("Btn_EditCondition"), self, function(win)
        Talky_JsonEditor.open(Talky_T("Wf_ConditionTitle", name), Talky_T("Wf_ConditionHelp"), wf.when,
            function(v) wf.when = v; win:markDirty(); win:showPage("workflows") end)
    end)
    y = y + ROW + 12

    -- steps
    Talky_UI.label(page, x, y, Talky_T("Wf_Steps"), C.muted)
    y = y + ROW
    local stepsH = page.height - y - ROW * 2 - 18
    local steps = Talky_UI.list(page, x, y, w, stepsH, self, function(win, index) win.selectedStep = index end)
    local function editStep(index)
        Talky_StepEditor.open(wf.steps[index], function(step)
            if step == nil then table.remove(wf.steps, index) else wf.steps[index] = step end
            self:markDirty()
            self:showPage("workflows")
        end)
    end
    steps:setOnMouseDoubleClick(self, function(_, index) editStep(index) end)
    for i, step in ipairs(wf.steps) do
        steps:addItem(i .. ".  " .. Talky_UI.truncate(Talky_UI.stepSummary(step), w - 50), i)
        if i == self.selectedStep then steps.selected = i end
    end
    y = y + stepsH + 6

    local bw = 96
    local function move(delta)
        local i = self.selectedStep
        local j = i and i + delta
        if not i or j < 1 or j > #wf.steps then return end
        wf.steps[i], wf.steps[j] = wf.steps[j], wf.steps[i]
        self.selectedStep = j
        self:markDirty()
        self:showPage("workflows")
    end
    Talky_UI.button(page, x, y, bw, Talky_T("Btn_AddAction"), self, function(win)
        Talky_StepEditor.open(nil, function(step)
            table.insert(wf.steps, (win.selectedStep or #wf.steps) + 1, step)
            win:markDirty()
            win:showPage("workflows")
        end)
    end, "primary")
    Talky_UI.button(page, x + (bw + 6), y, bw, Talky_T("Btn_AddAdvanced"), self, function(win)
        Talky_JsonEditor.open(Talky_T("Editor_AdvancedTitle"), '{ "if": {"bits":{"gte":500}}, "then": [ ... ], "else": [ ... ] }',
            { ["if"] = { bits = { gte = 100 } }, ["then"] = { { action = "helicopter" } }, ["else"] = { { action = "noise", radius = 30 } } },
            function(v) if v then table.insert(wf.steps, v); win:markDirty(); win:showPage("workflows") end end)
    end)
    Talky_UI.button(page, x + (bw + 6) * 2, y, bw, Talky_T("Btn_Edit"), self, function(win)
        if win.selectedStep then editStep(win.selectedStep) end
    end)
    Talky_UI.button(page, x + (bw + 6) * 3, y, 40, "^", self, function() move(-1) end)
    Talky_UI.button(page, x + (bw + 6) * 3 + 46, y, 40, "v", self, function() move(1) end)
    Talky_UI.button(page, x + (bw + 6) * 3 + 92, y, bw, Talky_T("Btn_Delete"), self, function(win)
        if win.selectedStep then
            table.remove(wf.steps, win.selectedStep)
            win.selectedStep = nil
            win:markDirty()
            win:showPage("workflows")
        end
    end, "danger")
    y = y + ROW + 8

    -- test: both buttons sized to their text, the name field takes what is left
    -- (fixed widths hid "Tester maintenant" under "Workflow en JSON" in French)
    local tm = getTextManager()
    local testText, jsonText = Talky_T("Btn_TestNow"), Talky_T("Btn_WorkflowJson")
    local testW = tm:MeasureStringX(Talky_UI.FONT, testText) + 24
    local jsonW = tm:MeasureStringX(Talky_UI.FONT, jsonText) + 24
    local entryW = math.max(80, math.min(160, w - 150 - 10 - testW - 6 - jsonW))
    Talky_UI.label(page, x, y, Talky_T("Wf_TestWith"), C.muted)
    local testEntry = Talky_UI.entry(page, x + 150, y, entryW, self.testUser or Talky_T("Wf_TestUser"), self, function(win, t) win.testUser = t end)
    Talky_UI.button(page, x + 150 + entryW + 10, y, testW, testText, self, function(win)
        if win.dirty then win:onSave() end -- the bridge runs the saved version
        Talky_Settings.testWorkflow(name, { user = testEntry:getText(), user_name = testEntry:getText(), bits = 500, viewers = 10, tier = "1000" })
        -- multiplayer: the bridge of the server runs it around this admin
        Talky_Overlay.toast(Talky_T(Talky_Settings.mp() and "Toast_TestSentServer" or "Toast_TestSent", name), "#8b5cf6", 3)
    end, "primary")
    Talky_UI.button(page, x + w - jsonW, y, jsonW, jsonText, self, function(win)
        Talky_JsonEditor.open(Talky_T("Wf_JsonTitle", name), Talky_T("Wf_JsonHelp"), wf, function(v)
            if v then d.workflows[name] = v end
            win:markDirty()
            win:showPage("workflows")
        end)
    end)
end

---------------------------------------------------------------- page: game events

function Talky_Window:page_events(page)
    title(page, Talky_T("Page_events"))
    local y = ROW + 10
    if self:adminGate(page, y) then return end
    local d = self:data()
    Talky_UI.label(page, 0, y, fit(Talky_T(Talky_Settings.mp() and "Events_IntroServer" or "Events_Intro"), page.width), C.muted)
    y = y + ROW + 14
    for _, ev in ipairs(GAME_EVENTS) do
        Talky_UI.label(page, 0, y, Talky_T(ev.labelKey), C.text)
        if ev.vars ~= "" then Talky_UI.label(page, 0, y + ROW - 4, Talky_T("Events_Vars", ev.vars), C.muted) end
        local current = d.gameEvents[ev.id]
        if type(current) == "table" then current = current[1] end
        Talky_UI.combo(page, 300, y, page.width - 300, workflowOptions(true, false), current or "", self, function(win, value)
            if value == "" then d.gameEvents[ev.id] = nil else d.gameEvents[ev.id] = value end
            win:markDirty()
        end)
        y = y + ROW * 2 + 14
    end
end

---------------------------------------------------------------- page: settings

-- Multiplayer: the caps come from the server (read only); the display settings and the settings
-- of the bridge (language, anonymous name) are those of the server's configuration, edited by
-- the admins; the other players see the display settings read only.
local function shownValue(opt, v)
    if opt.type == "bool" then return Talky_T(v == true and "Value_On" or "Value_Off") end
    return v ~= nil and tostring(v) or "?"
end

function Talky_Window:page_settings(page)
    title(page, Talky_T("Page_settings"))
    local y = ROW + 16
    local mp = Talky_Settings.mp()
    local serverCaps = mp and Talky_Remote.status and Talky_Remote.status.caps or nil
    local editServer = not mp or Talky_Settings.ready()
    if mp then
        Talky_UI.label(page, 0, y, Talky_UI.truncate(Talky_T("Settings_ServerNote"), page.width), C.muted)
        y = y + ROW + 6
    end
    for _, opt in ipairs(Talky_Config.editable) do
        local shown = not mp or opt.server or opt.display or editServer
        if shown then
            local s = Talky_Settings.settingsFor(opt.key)
            local value = s[opt.key]
            if value == nil then value = Talky_Config[opt.key] end
            local label = Talky_T(opt.labelKey)
            if mp and opt.server then
                Talky_UI.label(page, 0, y, label, C.text)
                local v = serverCaps and serverCaps[opt.server]
                Talky_UI.label(page, 360, y, Talky_T("Settings_ServerValue", v ~= nil and tostring(v) or "?"), C.muted)
            elseif mp and not editServer then
                -- a display setting of the server, for a player who is not an admin
                Talky_UI.label(page, 0, y, label, C.text)
                local v = Talky_Remote.display[opt.key]
                if v == nil then v = Talky_Config[opt.key] end
                Talky_UI.label(page, 360, y, Talky_T("Settings_ServerValue", shownValue(opt, v)), C.muted)
            elseif opt.type == "bool" then
                Talky_UI.tick(page, 0, y, page.width, label, value == true, self, function(win, on)
                    s[opt.key] = on
                    win:markDirty()
                end)
            elseif opt.type == "choice" then
                Talky_UI.label(page, 0, y, label, C.text)
                local opts = {}
                for _, c in ipairs(opt.choices) do opts[#opts + 1] = { Talky_T(c[1]), c[2] } end
                Talky_UI.combo(page, 360, y, 200, opts, value, self, function(win, v)
                    s[opt.key] = v
                    win:markDirty()
                end)
            elseif opt.type == "text" then
                Talky_UI.label(page, 0, y, label, C.text)
                Talky_UI.entry(page, 360, y, 200, tostring(value or ""), self, function(win, text)
                    s[opt.key] = TalkyNet.cut(text, opt.maxLength or 40)
                    win:markDirty()
                end)
            else
                Talky_UI.label(page, 0, y, label, C.text)
                local e = Talky_UI.entry(page, 360, y, 120, tostring(value), self, function(win, text)
                    local n = tonumber(text)
                    if n then
                        if opt.min and n < opt.min then n = opt.min end
                        if opt.max and n > opt.max then n = opt.max end
                        s[opt.key] = n
                        win:markDirty()
                    end
                end)
                e:setOnlyNumbers(true)
                if opt.min then Talky_UI.label(page, 495, y, opt.min .. " - " .. opt.max, C.muted) end
            end
            y = y + ROW + 10
        end
    end
    y = y + 10
    Talky_UI.label(page, 0, y, Talky_T("Settings_Shortcut"), C.muted)
    if mp then
        Talky_UI.label(page, 0, y + ROW, fit(Talky_T("Settings_FileServer"), page.width), C.muted)
    else
        Talky_UI.label(page, 0, y + ROW, Talky_T("Settings_File", Talky_Config.configFile), C.muted)
    end
end
