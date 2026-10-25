-- Runs the Talky mod in Kahlua with a fake game API (run by LuaSim.java, see tools/test-lua.ps1).
-- Checks: every file loads, every translation key exists in EN and FR with the same
-- arguments, every page of the F8 window builds in both languages without a missing
-- text, the copied URL carries the right token, and the caps on wait / texts / names.

local ROOT = __MOD_ROOT
__FAILURES = 0
local total = 0

local function check(cond, msg)
    total = total + 1
    if cond then
        print("  ok    " .. msg)
    else
        __FAILURES = __FAILURES + 1
        print("  FAIL  " .. msg)
    end
end

local noop = function() end

---------------------------------------------------------------- fake game API

NOW = 1000000
function getTimestampMs() return NOW end

-- Zomboid/Lua as an in-memory table
FS = {}
local function splitLines(s)
    local out, pos = {}, 1
    local n = string.len(s)
    while pos <= n do
        local e = string.find(s, "\n", pos)
        if not e then
            out[#out + 1] = string.sub(s, pos)
            break
        end
        out[#out + 1] = string.sub(s, pos, e - 1)
        pos = e + 1
    end
    return out
end
function getFileReader(name)
    local content = FS[name]
    if content == nil then return nil end
    local lines, i = splitLines(content), 0
    return { readLine = function() i = i + 1; return lines[i] end, close = noop }
end
function getFileWriter(name, create, append)
    local buf = ""
    if append then buf = FS[name] or "" end
    return {
        write = function(_, s) buf = buf .. s end,
        close = function() FS[name] = buf end,
    }
end

-- Translations, read from the mod's UI.json files
UI_EN, UI_FR, UI_CUR = {}, {}, {}
MISSING, BAD_ARGS = {}, {}
CUR_LANG = "EN"
function getTextOrNull(key, ...)
    local v = UI_CUR[key]
    if v == nil then v = UI_EN[key] end
    if v == nil then
        MISSING[key] = true
        return nil
    end
    local args = { ... }
    v = string.gsub(v, "%%(%d)", function(d)
        local a = args[tonumber(d)]
        if a == nil then
            BAD_ARGS[key] = true
            return "%" .. d
        end
        return tostring(a)
    end)
    return v
end
function getText(key, ...) return getTextOrNull(key, ...) or key end
Translator = { getLanguage = function() return { name = function() return CUR_LANG end } end }

-- Events
local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end, Remove = noop }
    rawset(t, name, e)
    return e
end })
local function fire(name, a, b)
    for _, fn in ipairs(handlers[name] or {}) do fn(a, b) end
end

-- Player, zombies, world
SAID, HALO = nil, nil
PLAYER = {
    isDead = function() return false end,
    Say = function(_, text) SAID = text end,
    getPlayerNum = function() return 0 end,
    getX = function() return 100 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
}
function getPlayer() return PLAYER end
function isGamePaused() return false end
HaloTextHelper = { addText = function(_, text) HALO = text end }

-- Texts shown by the fake UI
TEXTS = {}
local function record(t)
    if t ~= nil then TEXTS[#TEXTS + 1] = tostring(t) end
end

UIFont = { Small = "Small", Medium = "Medium", Large = "Large" }
local TM = {
    getFontHeight = function() return 14 end,
    MeasureStringX = function(_, _, s) return string.len(tostring(s)) * 7 end,
    DrawStringCentre = noop,
}
function getTextManager() return TM end
local CORE = {
    getScreenWidth = function() return 1920 end,
    getScreenHeight = function() return 1080 end,
    getKey = function() return 0 end,
}
function getCore() return CORE end
CLIPBOARD = nil
Clipboard = { setClipboard = function(s) CLIPBOARD = s end }
Keyboard = { KEY_F8 = 66 }
keyBinding = {}

-- Minimal ISUI: enough for the Talky window to build its pages
BUTTONS = {}
local Base = {}
Base.__index = Base
function Base:derive(name)
    local cls = {}
    cls.__index = cls
    cls.Type = name
    return setmetatable(cls, { __index = self })
end
function Base:new(x, y, w, h)
    local o = { x = x, y = y, width = w, height = h, children = {} }
    return setmetatable(o, self)
end
function Base:initialise() end
function Base:instantiate() end
function Base:addChild(c) table.insert(self.children, c) end
function Base:removeChild() end
function Base:addToUIManager()
    if self.createChildren and not self.__created then
        self.__created = true
        self:createChildren()
    end
end
function Base:removeFromUIManager() end
function Base:setVisible(v) self.visible = v end
function Base:isVisible() return self.visible ~= false end
function Base:setAlwaysOnTop() end
function Base:setResizable() end
function Base:setTitle(t) self.title = t; record(t) end
function Base:titleBarHeight() return 16 end
function Base:drawRect() end
function Base:drawText(t) record(t) end
function Base:createChildren() end
function Base:prerender() end

ISCollapsableWindow = Base:derive("ISCollapsableWindow")
ISPanel = Base:derive("ISPanel")

ISButton = Base:derive("ISButton")
function ISButton:new(x, y, w, h, title, target, onclick)
    local o = Base.new(self, x, y, w, h)
    o.title, o.target, o.onclick = title, target, onclick
    record(title)
    table.insert(BUTTONS, o)
    return o
end

ISLabel = Base:derive("ISLabel")
function ISLabel:new(x, y, h, name)
    local o = Base.new(self, x, y, 0, h)
    o.name = name
    record(name)
    return o
end
function ISLabel:setName(n) self.name = n; record(n) end

ENTRIES = {}
ISTextEntryBox = Base:derive("ISTextEntryBox")
function ISTextEntryBox:new(text, x, y, w, h)
    local o = Base.new(self, x, y, w, h)
    o.text = text
    table.insert(ENTRIES, o)
    return o
end
-- Like the game: a masked box shows stars, getInternalText() keeps the real text
function ISTextEntryBox:getText()
    if self.masked then return string.rep("*", string.len(tostring(self.text or ""))) end
    return self.text
end
function ISTextEntryBox:getInternalText() return self.text end
function ISTextEntryBox:setText(t) self.text = t end
function ISTextEntryBox:setMasked(b) self.masked = b end
function ISTextEntryBox:isMasked() return self.masked == true end
function ISTextEntryBox:setOnlyNumbers() end
function ISTextEntryBox:setMultipleLine() end
function ISTextEntryBox:setMaxLines() end
function ISTextEntryBox:addScrollBars() end

ISComboBox = Base:derive("ISComboBox")
function ISComboBox:new(x, y, w, h, target, onchange)
    local o = Base.new(self, x, y, w, h)
    o.options, o.selected, o.target, o.onchange = {}, 1, target, onchange
    return o
end
function ISComboBox:addOptionWithData(text, data)
    table.insert(self.options, { text = text, data = data })
    record(text)
end
function ISComboBox:getOptionData(i)
    local opt = self.options[i]
    return opt and opt.data
end

ISTickBox = Base:derive("ISTickBox")
function ISTickBox:new(x, y, w, h, name, target, onchange)
    local o = Base.new(self, x, y, w, h)
    o.sel = {}
    return o
end
function ISTickBox:addOption(t) record(t) end
function ISTickBox:setSelected(i, v) self.sel[i] = v end
function ISTickBox:isSelected(i) return self.sel[i] == true end

ISScrollingListBox = Base:derive("ISScrollingListBox")
function ISScrollingListBox:new(x, y, w, h)
    local o = Base.new(self, x, y, w, h)
    o.items, o.selected = {}, 1
    return o
end
function ISScrollingListBox:addItem(text, item)
    table.insert(self.items, { text = text, item = item })
    record(text)
end
function ISScrollingListBox:setOnMouseDownFunction() end
function ISScrollingListBox:setOnMouseDoubleClick() end

---------------------------------------------------------------- loading the mod

local loaded, missingRequires = {}, {}
local function loadFile(dir, mod)
    local src = __readFile(ROOT .. "/" .. dir .. "/" .. mod .. ".lua")
    if not src then return false end
    local fn, err = loadstring(src, mod)
    if not fn then error("cannot compile " .. mod .. ": " .. tostring(err)) end
    fn()
    return true
end
function require(mod)
    if loaded[mod] then return end
    loaded[mod] = true
    if not loadFile("shared", mod) and not loadFile("client", mod) then
        missingRequires[#missingRequires + 1] = mod
    end
end

local function stripLua(p) return string.sub(p, 1, string.len(p) - 4) end
local sources = {}
local function loadAll(prefix)
    for _, rel in ipairs(__LUA_FILES) do
        if string.sub(rel, 1, string.len(prefix)) == prefix then
            sources[#sources + 1] = __readFile(ROOT .. "/" .. rel)
            require(stripLua(string.sub(rel, string.len(prefix) + 1)))
        end
    end
end

print("loading")
-- TalkyJson first: needed to read the translation files
require("Talky/Talky_Json")
UI_EN = TalkyJson.decode(__readFile(ROOT .. "/shared/Translate/EN/UI.json"))
UI_FR = TalkyJson.decode(__readFile(ROOT .. "/shared/Translate/FR/UI.json"))
UI_CUR = UI_EN
loadAll("shared/")
loadAll("client/")
local onlyVanilla = true
for _, m in ipairs(missingRequires) do
    if string.sub(m, 1, 5) ~= "ISUI/" then
        onlyVanilla = false
        print("        missing require: " .. m)
    end
end
check(onlyVanilla, "every require of a Talky file resolves (only vanilla ISUI files are faked)")
check(Talky_Window ~= nil and Talky_Actions ~= nil and Talky_Runner ~= nil and Talky_T ~= nil, "all modules loaded")

---------------------------------------------------------------- translation files

print("translations")
local function keysOf(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end
local function placeholders(v)
    local found = {}
    for d in string.gmatch(v, "%%(%d)") do found[#found + 1] = d end
    table.sort(found)
    return table.concat(found, ",")
end

local sameKeys, sameArgs, noStrayPercent = true, true, true
for _, k in ipairs(keysOf(UI_EN)) do
    if UI_FR[k] == nil then sameKeys = false; print("        missing in FR: " .. k) end
end
for _, k in ipairs(keysOf(UI_FR)) do
    if UI_EN[k] == nil then sameKeys = false; print("        missing in EN: " .. k) end
end
for _, k in ipairs(keysOf(UI_EN)) do
    local en, fr = UI_EN[k], UI_FR[k]
    if fr and placeholders(en) ~= placeholders(fr) then sameArgs = false; print("        arguments differ: " .. k) end
    for _, v in ipairs({ en, fr or "" }) do
        local stripped = string.gsub(v, "%%%d", "")
        if string.find(stripped, "%%") then noStrayPercent = false; print("        stray % in " .. k) end
    end
end
check(sameKeys, "EN and FR UI.json have the same keys")
check(sameArgs, "EN and FR texts take the same %1, %2... arguments")
check(noStrayPercent, "no '%' outside %1..%9 (the game formats texts with Java)")

-- Every key named in the code exists
local referenced, unknown = {}, {}
local patterns = { 'Talky_T%("([%w_]+)"', 'getOrNil%("([%w_]+)"', 'labelKey%s*=%s*"([%w_]+)"', 'defaultKey%s*=%s*"([%w_]+)"', '{%s*"(Lang_%w+)"' }
for _, src in ipairs(sources) do
    for _, pat in ipairs(patterns) do
        for key in string.gmatch(src, pat) do referenced[key] = true end
    end
end
local count = 0
for key in pairs(referenced) do
    count = count + 1
    if UI_EN["UI_Talky_" .. key] == nil then unknown[#unknown + 1] = key end
end
for _, k in ipairs(unknown) do print("        unknown key: UI_Talky_" .. k) end
check(count > 100 and #unknown == 0, "every key used by the code exists in UI.json (" .. count .. " keys)")

---------------------------------------------------------------- game start

local STATUS = {
    ts = NOW, version = "0.3.0", port = 7420, token = "GLOBALTOKEN", pending = 2, publicUrl = "",
    webhooks = { "follow", "secret", "points" },
    recent = {
        { at = "2026-10-25T10:00:00.000Z", source = "hook:follow", workflow = "new_follower", user = "Bob", job = 1, steps = 2 },
        { at = "2026-10-25T10:00:01.000Z", source = "hook:bits", workflow = "bits", user = "Ann", skipped = "cooldown" },
        { at = "2026-10-25T10:00:02.000Z", source = "hook:points", user = "Zed", skipped = "no matching route" },
        { at = "2026-10-25T10:00:03.000Z", source = "game:zombie_killed", workflow = "report", user = "Bob", error = "http refused: host \"evil.example\" is not in httpAllowedHosts (bridge/config.json)" },
    },
}
local CONFIG = {
    publicUrl = "https://abc.trycloudflare.com/",
    webhooks = {
        follow = { workflow = "new_follower" },
        secret = { workflow = "new_follower", token = "DEDICATEDTOKEN" },
        points = { routes = { { when = { reward_title = { contains = "heli" } }, workflow = "new_follower" } } },
    },
    workflows = {
        new_follower = { cooldownSeconds = 5, when = { bits = { gte = 1 } }, steps = {
            { action = "notify", text = "{{user}}", color = "#ffffff" },
            { ["if"] = { bits = { gte = 100 } }, ["then"] = { { action = "helicopter" } }, ["else"] = { { action = "noise" } } },
            { random = { { { action = "heal" } }, { { action = "noise" } } } },
            { ["repeat"] = 3, steps = { { action = "noise" } } },
            { set = { x = 1 } },
            { chance = 0.5, steps = { { action = "heal" } } },
            { action = "spawn_zombie", name = "{{user}}", crawler = true },
        } },
        off_wf = { enabled = false, steps = {} },
    },
    gameEvents = { zombie_killed = "new_follower" },
    settings = { language = "fr", anonymousName = "Ghost", maxZombiesPerAction = 20 },
}

local function hasMissingText()
    local bad = {}
    for _, t in ipairs(TEXTS) do
        if string.find(t, "UI_Talky_") or string.find(t, "%%%d") or string.find(t, "%%%d%$s") then bad[#bad + 1] = t end
    end
    return bad
end
local function escapePattern(s)
    return (string.gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end
local function textShown(s)
    local pat = escapePattern(s)
    for _, t in ipairs(TEXTS) do
        if string.find(t, pat) then return true end
    end
    return false
end
local function findButton(title)
    for i = #BUTTONS, 1, -1 do
        if BUTTONS[i].title == title then return BUTTONS[i] end
    end
    return nil
end

FS["talky_config.json"] = TalkyJson.encode(CONFIG, "  ")
FS["talky_status.json"] = TalkyJson.encode(STATUS)
fire("OnGameBoot")
fire("OnGameStart")
check(Talky_Settings.data ~= nil and Talky_Settings.data.webhooks.secret ~= nil, "talky_config.json read at game start")
check(Talky_Config.maxZombiesPerAction == 20, "settings from talky_config.json applied")
check(string.find(FS["talky_outbox.jsonl"] or "", '"game_started"') ~= nil, "game_started sent to the bridge")

---------------------------------------------------------------- the window, in both languages

for _, lang in ipairs({ "EN", "FR" }) do
    print("window " .. lang)
    CUR_LANG = lang
    UI_CUR = lang == "FR" and UI_FR or UI_EN
    TEXTS, BUTTONS, MISSING, BAD_ARGS = {}, {}, {}, {}
    NOW = NOW + 10
    STATUS.ts = NOW
    FS["talky_status.json"] = TalkyJson.encode(STATUS)
    Talky_Settings.statusReadAt = 0

    if Talky_Window.instance then Talky_Window.instance:close() end
    Talky_Window.toggle()
    local win = Talky_Window.instance
    check(win ~= nil, "F8 window opens")
    win:prerender()
    local ok, err = pcall(function()
        win:showPage("status")
        win.selectedHook = "secret"; win:showPage("webhooks")
        win.selectedHook = "points"; win:showPage("webhooks")
        win.selectedHook = nil; win:showPage("webhooks")
        win.selectedWf = "new_follower"; win:showPage("workflows")
        win.selectedWf = nil; win:showPage("workflows")
        win:showPage("events")
        win:showPage("settings")
        win:markDirty(); win:prerender()
    end)
    check(ok, "every page builds" .. (ok and "" or (": " .. tostring(err))))

    -- step editor with every action, then the JSON editors
    local ok2, err2 = pcall(function()
        local saved
        local ed = Talky_StepEditor.open(nil, function(step) saved = step end)
        for _, s in ipairs(Talky_Actions.schema) do
            ed.step = { action = s.action }
            ed:buildFields(true)
        end
        ed.step = { action = "notify" }
        ed:buildFields(true)
        ed:onOk()
        assert(saved and saved.action == "notify", "step editor returns the step")
        assert(saved.text == Talky_T("Default_notify"), "translated default text")
        Talky_StepEditor.open({ ["if"] = { bits = { gte = 1 } }, ["then"] = {} }, noop)
        local je = Talky_JsonEditor.open("t", "h", { a = 1 }, noop)
        je.box.text = "{ bad json"
        je:onOk()
        for _, step in ipairs(CONFIG.workflows.new_follower.steps) do record(Talky_UI.stepSummary(step)) end
    end)
    check(ok2, "step editor and JSON editors build" .. (ok2 and "" or (": " .. tostring(err2))))

    local bad = hasMissingText()
    for _, t in ipairs(bad) do print("        untranslated: " .. t) end
    check(#bad == 0, "no missing key and no unfilled %1 on screen (" .. #TEXTS .. " texts)")
    local missingKeys = {}
    for k in pairs(MISSING) do missingKeys[#missingKeys + 1] = k end
    for k in pairs(BAD_ARGS) do missingKeys[#missingKeys + 1] = "args:" .. k end
    for _, k in ipairs(missingKeys) do print("        " .. k) end
    check(#missingKeys == 0, "every getText call finds its key with the right arguments")

    if lang == "EN" then
        check(textShown("Status") and textShown("Game events") and textShown("Bridge connected on port 7420 - 2 job(s) waiting"), "English texts shown")
        check(textShown("skipped: cooldown") and textShown("skipped: no matching route"), "skip reasons translated (EN)")
    else
        -- Only ASCII literals here: Kahlua mangles accented characters in compiled Lua
        -- strings (one more reason to keep every text in UI.json).
        check(Talky_T("Page_status") == "Statut" and string.find(Talky_T("Page_events"), "nements du jeu$") ~= nil,
            "French page names")
        check(textShown(Talky_T("Page_events")) and textShown(Talky_T("Page_settings"))
            and textShown(Talky_T("Status_Online", "7420", "2")) and string.find(Talky_T("Status_Online", "7420", "2"), "sur le port 7420 %- 2 job%(s%) en attente") ~= nil,
            "French texts shown")
        check(textShown(Talky_T("Status_Skipped", Talky_T("Skip_cooldown")))
            and textShown(Talky_T("Status_Skipped", Talky_T("Skip_no_matching_route")))
            and Talky_T("Skip_no_matching_route") == "aucune route ne correspond", "skip reasons translated (FR)")
    end
    check(textShown("(v0.3.0)"), "bridge version shown on the Status page")
    check(textShown("erreur : http refused") or textShown("error: http refused"), "bridge errors shown on the Status page")
    check(textShown("(off) off_wf"), "disabled workflows marked (off)")

    -- copy buttons
    win.selectedHook = "secret"
    ENTRIES = {}
    win:showPage("webhooks")
    local tokenBox
    for _, e in ipairs(ENTRIES) do
        if e:getInternalText() == "DEDICATEDTOKEN" then tokenBox = e end
    end
    check(tokenBox ~= nil and tokenBox:isMasked() and tokenBox:getText() ~= "DEDICATEDTOKEN", "a webhook's own token is in a masked field")
    if tokenBox then
        tokenBox.text = "NEWTOKEN"
        tokenBox.onTextChangeFunction(tokenBox.target, tokenBox)
        check(Talky_Settings.get().webhooks.secret.token == "NEWTOKEN", "typing in the masked field sets the real token")
        tokenBox.text = "DEDICATEDTOKEN"
        tokenBox.onTextChangeFunction(tokenBox.target, tokenBox)
    end
    local copy = findButton(Talky_T("Btn_CopyFullUrl"))
    CLIPBOARD = nil
    if copy then copy.onclick(copy.target, copy) end
    check(CLIPBOARD == "https://abc.trycloudflare.com/hooks/secret?token=DEDICATEDTOKEN", "copied URL of a webhook with its own token carries that token")
    check(textShown(Talky_T("Toast_UrlCopied", "secret")) or #Talky_Overlay.toasts > 0, "copy confirmation toast")
    win:close()
end

check(Talky_Settings.hookUrl("follow") == "https://abc.trycloudflare.com/hooks/follow?token=GLOBALTOKEN", "other webhooks use the global token")
check(Talky_Settings.baseUrl() == "https://abc.trycloudflare.com", "trailing slash removed from the public URL")

-- Saving keeps valid JSON
Talky_Window.toggle()
Talky_Window.instance:onSave()
local reread = TalkyJson.tryDecode(FS["talky_config.json"])
check(reread ~= nil and reread.webhooks.secret.token == "DEDICATEDTOKEN" and reread.settings.anonymousName == "Ghost", "Save writes valid JSON with every field")
Talky_Window.instance:close()

---------------------------------------------------------------- caps and actions

print("caps")
CUR_LANG, UI_CUR = "EN", UI_EN
check(Talky_Runner.waitMs({ seconds = 99999 }) == 600000, "wait capped to 600 s")
check(Talky_Runner.waitMs({ seconds = -3 }) == 0, "negative wait becomes 0")
check(Talky_Runner.waitMs({}) == 1000, "wait without seconds = 1 s")

local long = string.rep("x", 500)
Talky_Overlay.toasts = {}
Talky_Actions.run({ action = "notify", text = long, seconds = 999 }, PLAYER, {})
local toast = Talky_Overlay.toasts[#Talky_Overlay.toasts]
check(toast and string.len(toast.text) == 200, "notify text capped to 200 characters")
check(toast and toast.untilMs - NOW == 60000, "notify duration capped to 60 s")
Talky_Actions.run({ action = "say", text = long }, PLAYER, {})
check(SAID and string.len(SAID) == 200, "say text capped to 200 characters")
Talky_Actions.run({ action = "halo", text = long }, PLAYER, {})
check(HALO and string.len(HALO) == 200, "halo text capped to 200 characters")

local md = {}
local zombie = { getModData = function() return md end, isDead = function() return false end }
Talky_Overlay.tagZombie(zombie, long, "#ffffff")
check(string.len(md.Talky_name) == 60, "zombie name capped to 60 characters")

-- a named zombie dies: translated banner + event for the bridge
FS["talky_outbox.jsonl"] = nil
Talky_Overlay.toasts = {}
CUR_LANG, UI_CUR = "FR", UI_FR
fire("OnZombieDead", { getModData = function() return { Talky_name = "Bob" } end, getAttackedBy = function() return PLAYER end })
local last = Talky_Overlay.toasts[#Talky_Overlay.toasts]
check(last and last.text == Talky_T("Toast_ZombieDown", "Bob") and string.find(last.text, "^Bob est tomb.+pour de bon%.$") ~= nil,
    "zombie death banner translated (FR)")
check(string.find(FS["talky_outbox.jsonl"] or "", '"zombie_killed"') ~= nil, "zombie_killed sent to the bridge")
CUR_LANG, UI_CUR = "EN", UI_EN

-- inbox -> runner -> ack
Talky_Runner.queued, Talky_Runner.active = {}, {}
Talky_Bridge.lastSeq = 0
FS["talky_inbox.jsonl"] = TalkyJson.encode({ seq = 1, workflow = "a", steps = { { action = "notify", text = "one" } }, expiresAt = NOW + 60000 }) .. "\n"
    .. TalkyJson.encode({ seq = 2, workflow = "b", steps = { { action = "wait", seconds = 5000 }, { action = "notify", text = "two" } }, expiresAt = NOW + 60000 }) .. "\n"
    .. TalkyJson.encode({ seq = 3, workflow = "c", steps = { { action = "notify", text = "old" } }, expiresAt = NOW - 1 }) .. "\n"
Talky_Bridge.poll()
check(FS["talky_ack.txt"] == "3", "ack written with the last seq read")
check(#Talky_Runner.queued == 2, "expired job skipped, the others queued")
Talky_Overlay.toasts = {}
fire("OnTick")
check(#Talky_Overlay.toasts == 1 and Talky_Overlay.toasts[1].text == "one", "first job ran on the next tick")
check(#Talky_Runner.active == 1, "second job waits")
NOW = NOW + 600000
fire("OnTick")
check(#Talky_Runner.active == 0 and Talky_Overlay.toasts[#Talky_Overlay.toasts].text == "two", "a 5000 s wait ends after 600 s")

Talky_Runner.queued = {}
for i = 1, Talky_Config.maxQueuedJobs + 5 do
    Talky_Runner.enqueue({ seq = 100 + i, steps = { { action = "noise" } }, expiresAt = NOW + 60000 })
end
check(#Talky_Runner.queued == Talky_Config.maxQueuedJobs, "queue capped to " .. Talky_Config.maxQueuedJobs .. " jobs")
Talky_Runner.queued = {}

-- in-game test button
FS["talky_outbox.jsonl"] = nil
Talky_Settings.testWorkflow("new_follower")
check(string.find(FS["talky_outbox.jsonl"] or "", '"Tester"') ~= nil, "test button sends the translated test name")

print("")
print((total - __FAILURES) .. "/" .. total .. " passed")
