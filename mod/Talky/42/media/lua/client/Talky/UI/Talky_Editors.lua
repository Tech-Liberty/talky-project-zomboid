-- Modal editors: raw JSON (conditions, routes, control steps) and the per-action step form.

require "ISUI/ISCollapsableWindow"
require "Talky/Talky_Json"
require "Talky/Talky_Text"
require "Talky/Talky_Actions"
require "Talky/UI/Talky_Widgets"

local C = Talky_UI.col
local ROW, PAD = Talky_UI.ROW, 12

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepCopy(val) end
    return out
end
Talky_UI.deepCopy = deepCopy

local function styleWindow(w, title)
    w:setTitle(title)
    w.backgroundColor = { r = C.bg.r, g = C.bg.g, b = C.bg.b, a = 0.98 }
    w.borderColor = { r = C.accent.r, g = C.accent.g, b = C.accent.b, a = 1 }
    w:setResizable(false)
end

local function center(w, h)
    return (getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2
end

---------------------------------------------------------------- JSON editor

Talky_JsonEditor = ISCollapsableWindow:derive("Talky_JsonEditor")

-- Talky_JsonEditor.open(title, help, value, function(newValue) ... end)
function Talky_JsonEditor.open(title, help, value, onSave)
    local w, h = 620, 460
    local x, y = center(w, h)
    local o = Talky_JsonEditor:new(x, y, w, h)
    o.help, o.onSave = help, onSave
    o.text = value == nil and "" or TalkyJson.encode(value, "  ")
    o:initialise()
    o:addToUIManager()
    o:setAlwaysOnTop(true)
    styleWindow(o, title)
    return o
end

function Talky_JsonEditor:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD
    local w = self.width - PAD * 2
    Talky_UI.label(self, PAD, top, self.help or "", C.muted)
    self.box = Talky_UI.multiline(self, PAD, top + ROW + 4, w, self.height - top - ROW * 3 - 20, self.text)
    self.err = Talky_UI.label(self, PAD, self.height - ROW * 2 - 12, "", C.bad)
    local by = self.height - ROW - PAD
    Talky_UI.button(self, self.width - PAD - 120, by, 120, Talky_T("Btn_Ok"), self, Talky_JsonEditor.onOk, "primary")
    Talky_UI.button(self, self.width - PAD * 2 - 240, by, 120, Talky_T("Btn_Cancel"), self, Talky_JsonEditor.close)
    Talky_UI.button(self, PAD, by, 120, Talky_T("Btn_Clear"), self, function(s) s.box:setText("") end)
end

function Talky_JsonEditor:onOk()
    local text = self.box:getText()
    local value = nil
    if string.gsub(text, "%s", "") ~= "" then
        local err
        value, err = TalkyJson.tryDecode(text)
        if value == nil then
            self.err:setName(Talky_T("Editor_InvalidJson", tostring(err)))
            return
        end
    end
    if self.onSave then self.onSave(value) end
    self:close()
end

function Talky_JsonEditor:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

---------------------------------------------------------------- step editor

Talky_StepEditor = ISCollapsableWindow:derive("Talky_StepEditor")

local CONTROL_KEYS = { "if", "random", "repeat", "set", "chance" }

function Talky_StepEditor.isControl(step)
    if step.action then return false end
    for _, k in ipairs(CONTROL_KEYS) do
        if step[k] ~= nil then return true end
    end
    return true
end

-- Talky_StepEditor.open(step or nil, function(newStep) ... end)
function Talky_StepEditor.open(step, onSave)
    if step and Talky_StepEditor.isControl(step) then
        return Talky_JsonEditor.open(Talky_T("Editor_AdvancedTitle"), Talky_T("Editor_AdvancedHelp"), step, onSave)
    end
    local w, h = 560, 520
    local x, y = center(w, h)
    local o = Talky_StepEditor:new(x, y, w, h)
    o.step = step and deepCopy(step) or { action = "notify" }
    o.onSave = onSave
    o:initialise()
    o:addToUIManager()
    o:setAlwaysOnTop(true)
    styleWindow(o, step and Talky_T("Editor_EditAction") or Talky_T("Editor_NewAction"))
    return o
end

function Talky_StepEditor:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + PAD
    Talky_UI.label(self, PAD, top, Talky_T("Editor_Action"), C.muted)
    local options = {}
    for _, s in ipairs(Talky_Actions.schema) do options[#options + 1] = { Talky_Actions.labelOf(s), s.action } end
    self.actionCombo = Talky_UI.combo(self, 140, top, self.width - 140 - PAD, options, self.step.action, self,
        function(s, action) s.step.action = action; s:buildFields(true) end)
    self.fieldsTop = top + ROW + 14
    local by = self.height - ROW - PAD
    Talky_UI.button(self, self.width - PAD - 120, by, 120, Talky_T("Btn_Ok"), self, Talky_StepEditor.onOk, "primary")
    Talky_UI.button(self, self.width - PAD * 2 - 240, by, 120, Talky_T("Btn_Cancel"), self, Talky_StepEditor.close)
    Talky_UI.button(self, PAD, by, 150, Talky_T("Btn_EditJson"), self, Talky_StepEditor.onJson)
    Talky_UI.label(self, PAD, by - ROW - 4, Talky_T("Editor_Tip"), C.muted)
    self:buildFields(false)
end

function Talky_StepEditor:buildFields(applyDefaults)
    if self.fields then self:removeChild(self.fields) end
    local schema = Talky_Actions.schemaByAction[self.step.action] or { params = {} }
    local h = self.height - self.fieldsTop - ROW * 3
    self.fields = Talky_UI.panel(self, 0, self.fieldsTop, self.width, h)
    self.inputs = {}
    local y = 0
    local labelW, inputX = 210, 230
    local inputW = self.width - inputX - PAD
    for _, p in ipairs(schema.params) do
        local v = self.step[p.key]
        local default = Talky_Actions.defaultOf(p)
        if v == nil and applyDefaults then v = default end
        local label = Talky_Actions.labelOf(p)
        if p.type == "bool" then
            if v == nil then v = default end
            self.inputs[p.key] = { kind = "bool", w = Talky_UI.tick(self.fields, PAD, y, self.width - PAD * 2, label, v == true or v == "true") }
        else
            Talky_UI.label(self.fields, PAD, y, Talky_UI.truncate(label, labelW), C.text)
            if p.type == "choice" then
                local opts = {}
                for _, c in ipairs(p.choices) do opts[#opts + 1] = { c, c } end
                self.inputs[p.key] = { kind = "choice", w = Talky_UI.combo(self.fields, inputX, y, inputW, opts, v or default) }
            else
                self.inputs[p.key] = { kind = "text", w = Talky_UI.entry(self.fields, inputX, y, inputW, v == nil and "" or tostring(v)) }
            end
        end
        y = y + ROW + 6
    end
    if #schema.params == 0 then Talky_UI.label(self.fields, PAD, 0, Talky_T("Editor_NoParams"), C.muted) end
    if schema.where == "bridge" then
        Talky_UI.label(self.fields, PAD, y + 4, Talky_T("Editor_BridgeSide"), C.muted)
    end
end

-- Known fields come from the form; unknown ones (written by hand in JSON) are kept.
function Talky_StepEditor:collect()
    local step = self.step
    for key, input in pairs(self.inputs) do
        if input.kind == "bool" then
            step[key] = input.w:isSelected(1)
        elseif input.kind == "choice" then
            step[key] = input.w:getOptionData(input.w.selected)
        else
            local text = input.w:getText()
            if text == "" then step[key] = nil else step[key] = text end
        end
    end
    return step
end

function Talky_StepEditor:onOk()
    if self.onSave then self.onSave(self:collect()) end
    self:close()
end

function Talky_StepEditor:onJson()
    local onSave = self.onSave
    local step = self:collect()
    self:close()
    Talky_JsonEditor.open(Talky_T("Editor_ActionJsonTitle"), Talky_T("Editor_ActionJsonHelp"), step, onSave)
end

function Talky_StepEditor:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

---------------------------------------------------------------- summaries for lists

local function short(v)
    if type(v) == "table" then return "{...}" end
    return tostring(v)
end

function Talky_UI.stepSummary(step)
    if step.action then
        local s = Talky_Actions.schemaByAction[step.action]
        local parts = {}
        if s then
            for _, p in ipairs(s.params) do
                local v = step[p.key]
                if v ~= nil and v ~= false and v ~= "" then
                    parts[#parts + 1] = (v == true) and Talky_Actions.labelOf(p) or (p.key .. "=" .. short(v))
                end
            end
        end
        local label = s and Talky_Actions.labelOf(s) or step.action
        if #parts == 0 then return label end
        return label .. "  -  " .. table.concat(parts, ", ")
    end
    if step["if"] ~= nil then
        return Talky_T("Summary_If", TalkyJson.encode(step["if"]), #(step["then"] or {}), #(step["else"] or {}))
    end
    if step.random then return Talky_T("Summary_Random", #step.random) end
    if step["repeat"] ~= nil then return Talky_T("Summary_Repeat", short(step["repeat"]), #(step.steps or {})) end
    if step.set then return Talky_T("Summary_Set", TalkyJson.encode(step.set)) end
    if step.chance then return Talky_T("Summary_Chance", short(step.chance), #(step.steps or {})) end
    return TalkyJson.encode(step)
end
