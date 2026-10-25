-- Main Talky window: sidebar of pages, everything editable, saved to talky_config.json.

require "ISUI/ISCollapsableWindow"
require "Talky/Talky_Text"
require "Talky/Talky_Settings"
require "Talky/Talky_Overlay"
require "Talky/UI/Talky_Widgets"
require "Talky/UI/Talky_Editors"

Talky_Window = ISCollapsableWindow:derive("Talky_Window")

local C = Talky_UI.col
local ROW, PAD = Talky_UI.ROW, 12
local SIDEBAR = 170

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
    local w, h = 940, 620
    local o = Talky_Window:new((getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2, w, h)
    o:initialise()
    o:addToUIManager()
    Talky_Window.instance = o
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

function Talky_Window:onSave()
    if Talky_Settings.save() then
        self.dirty = false
        Talky_Overlay.toast(Talky_T("Toast_Saved"), "#8b5cf6", 3)
    end
end

function Talky_Window:onReload()
    Talky_Settings.load()
    self.dirty = false
    self:showPage(self.pageId)
end

local function title(page, text, y)
    Talky_UI.label(page, 0, y or 0, text, C.text, UIFont.Medium)
end

---------------------------------------------------------------- page: status

function Talky_Window:page_status(page)
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
    local list = Talky_UI.list(page, 0, y, page.width - 160, ROW * 6)
    for _, id in ipairs(Talky_Settings.webhookIds()) do
        local hook = d.webhooks[id]
        local target = hook.routes and Talky_T("Status_Routes") or tostring(hook.workflow or "?")
        list:addItem(Talky_Settings.baseUrl() .. "/hooks/" .. id .. "?token=*****   ->  " .. target, id)
    end
    Talky_UI.button(page, page.width - 150, y, 150, Talky_T("Btn_CopyUrl"), self, function()
        local item = list.items[list.selected]
        if item then
            Clipboard.setClipboard(Talky_Settings.hookUrl(item.item))
            Talky_Overlay.toast(Talky_T("Toast_UrlCopied", item.item), "#8b5cf6", 3)
        end
    end, "primary")
    y = y + ROW * 6 + 12

    Talky_UI.label(page, 0, y, Talky_T("Status_Recent"), C.muted)
    y = y + ROW
    local log = Talky_UI.list(page, 0, y, page.width, page.height - y)
    for _, e in ipairs((st and st.recent) or {}) do
        local when = string.sub(tostring(e.at or ""), 12, 19)
        local txt = when .. "  " .. tostring(e.source or "-") .. "  ->  " .. tostring(e.workflow or "-") .. "  (" .. tostring(e.user or "-") .. ")"
        if e.skipped then txt = txt .. "  " .. Talky_T("Status_Skipped", skipReason(e.skipped)) end
        if e.error then txt = txt .. "  " .. Talky_T("Status_Error", tostring(e.error)) end
        log:addItem(txt, e)
    end
    if #log.items == 0 then log:addItem(Talky_T("Status_Nothing"), nil) end
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
    local d = self:data()
    title(page, Talky_T("Page_webhooks"))
    local y = ROW + 10
    Talky_UI.label(page, 0, y, Talky_T("Hooks_Intro"), C.muted)
    y = y + ROW + 6
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

    Talky_UI.label(page, x, y, Talky_T("Hooks_Token"), C.muted)
    -- Masked like a password field: the window can be on stream.
    local tokenEntry = Talky_UI.entry(page, x, y + ROW, w, hook.token or "", self, function(win, text)
        if text == "" then hook.token = nil else hook.token = text end
        win:markDirty()
    end)
    tokenEntry:setMasked(true)
    y = y + ROW * 2 + 16

    Talky_UI.button(page, x, y, 200, Talky_T("Btn_CopyFullUrl"), self, function()
        Clipboard.setClipboard(Talky_Settings.hookUrl(id))
        Talky_Overlay.toast(Talky_T("Toast_UrlCopied", id), "#8b5cf6", 3)
    end, "primary")
    Talky_UI.label(page, x, y + ROW + 8, Talky_T("Hooks_BodyHint"), C.muted)
    Talky_UI.label(page, x, y + ROW * 2 + 8, Talky_T("Hooks_BodyExample"), C.text)
end

---------------------------------------------------------------- page: workflows

local function newWorkflowName(d, base)
    local n, name = 1, base
    while d.workflows[name] do n = n + 1; name = base .. "_" .. n end
    return name
end

function Talky_Window:page_workflows(page)
    local d = self:data()
    title(page, Talky_T("Page_workflows"))
    local y = ROW + 10
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

    -- test
    Talky_UI.label(page, x, y, Talky_T("Wf_TestWith"), C.muted)
    local testEntry = Talky_UI.entry(page, x + 150, y, 160, self.testUser or Talky_T("Wf_TestUser"), self, function(win, t) win.testUser = t end)
    Talky_UI.button(page, x + 320, y, 140, Talky_T("Btn_TestNow"), self, function(win)
        if win.dirty then win:onSave() end -- the bridge runs the saved version
        Talky_Settings.testWorkflow(name, { user = testEntry:getText(), user_name = testEntry:getText(), bits = 500, viewers = 10, tier = "1000" })
        Talky_Overlay.toast(Talky_T("Toast_TestSent", name), "#8b5cf6", 3)
    end, "primary")
    Talky_UI.button(page, x + w - 150, y, 150, Talky_T("Btn_WorkflowJson"), self, function(win)
        Talky_JsonEditor.open(Talky_T("Wf_JsonTitle", name), Talky_T("Wf_JsonHelp"), wf, function(v)
            if v then d.workflows[name] = v end
            win:markDirty()
            win:showPage("workflows")
        end)
    end)
end

---------------------------------------------------------------- page: game events

function Talky_Window:page_events(page)
    local d = self:data()
    title(page, Talky_T("Page_events"))
    local y = ROW + 10
    Talky_UI.label(page, 0, y, Talky_T("Events_Intro"), C.muted)
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

function Talky_Window:page_settings(page)
    local d = self:data()
    if type(d.settings) ~= "table" then d.settings = {} end
    title(page, Talky_T("Page_settings"))
    local y = ROW + 16
    for _, opt in ipairs(Talky_Config.editable) do
        local value = d.settings[opt.key]
        if value == nil then value = Talky_Config[opt.key] end
        local label = Talky_T(opt.labelKey)
        if opt.type == "bool" then
            Talky_UI.tick(page, 0, y, page.width, label, value == true, self, function(win, on)
                d.settings[opt.key] = on
                win:markDirty()
            end)
        elseif opt.type == "choice" then
            Talky_UI.label(page, 0, y, label, C.text)
            local opts = {}
            for _, c in ipairs(opt.choices) do opts[#opts + 1] = { Talky_T(c[1]), c[2] } end
            Talky_UI.combo(page, 360, y, 200, opts, value, self, function(win, v)
                d.settings[opt.key] = v
                win:markDirty()
            end)
        elseif opt.type == "text" then
            Talky_UI.label(page, 0, y, label, C.text)
            Talky_UI.entry(page, 360, y, 200, tostring(value or ""), self, function(win, text)
                d.settings[opt.key] = string.sub(text, 1, opt.maxLength or 40)
                win:markDirty()
            end)
        else
            Talky_UI.label(page, 0, y, label, C.text)
            local e = Talky_UI.entry(page, 360, y, 120, tostring(value), self, function(win, text)
                local n = tonumber(text)
                if n then
                    if opt.min and n < opt.min then n = opt.min end
                    if opt.max and n > opt.max then n = opt.max end
                    d.settings[opt.key] = n
                    win:markDirty()
                end
            end)
            e:setOnlyNumbers(true)
            if opt.min then Talky_UI.label(page, 495, y, opt.min .. " - " .. opt.max, C.muted) end
        end
        y = y + ROW + 10
    end
    y = y + 10
    Talky_UI.label(page, 0, y, Talky_T("Settings_Shortcut"), C.muted)
    Talky_UI.label(page, 0, y + ROW, Talky_T("Settings_File", Talky_Config.configFile), C.muted)
end
