-- Single player: the server/ files run in the same Lua state as the client; jobs go through
-- TalkyNet's local queues (one tick each way) and the caps of talky_config.json apply (0.3.0).

local JSON = H.JSON

section("single player: start")

-- A 0.4.0 bridge writes no "token" here (every mod can read the file) and lists in hookTokens
-- the webhooks with a dedicated token. The fake "token" proves the window never takes one.
local STATUS = {
    ts = NOW, version = "0.4.0", protocol = 2, testNonce = "n0nce-1", port = 7420, token = "GLOBALTOKEN", pending = 2, publicUrl = "",
    webhooks = { "follow", "secret", "points" }, hookTokens = { "secret" },
    recent = {
        { at = "2026-10-25T10:00:00.000Z", source = "hook:follow", workflow = "new_follower", user = "Bob", job = 1, steps = 2 },
        { at = "2026-10-25T10:00:01.000Z", source = "hook:bits", workflow = "bits", user = "Ann", skipped = "cooldown" },
        { at = "2026-10-25T10:00:02.000Z", source = "hook:points", user = "Zed", skipped = "no matching route" },
        { at = "2026-10-25T10:00:03.000Z", source = "game:zombie_killed", workflow = "report", user = "Bob", error = "http refused: host \"evil.example\" is not in httpAllowedHosts (bridge/config.json)" },
        { at = "2026-10-25T10:00:04.000Z", source = "game:job_rejected", workflow = "burn", rejected = "disabled", error = "refused by the server: disabled" },
    },
}
local CONFIG = {
    publicUrl = "https://abc.trycloudflare.com/",
    webhooks = {
        follow = { workflow = "new_follower" },
        -- the dedicated token the F8 window of Talky 0.3.0 saved here (0.4.0 neither reads nor shows it)
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

local fs = {}
fs["talky_config.json"] = JSON.encode(CONFIG, "  ")
fs["talky_status.json"] = JSON.encode(STATUS)
local acc = H.account("Bob", { x = 100, y = 100 })
-- sandbox options of the save turn things off: single player ignores them (talky_config.json caps)
local SP = H.newSP(acc, { fs = fs, sandbox = { Talky = { AllowZombies = false, AllowWeather = false, AllowXp = false,
    AllowFire = false, AllowHelicopter = false, MaxZombiesPerAction = 1, MaxStepsPerJob = 10 } } })
local E, W = SP.E, SP.world

check(E.Talky_Window ~= nil and E.Talky_Actions ~= nil and E.Talky_T ~= nil and E.Talky_Client ~= nil and E.TalkyNet ~= nil,
    "client modules loaded")
check(E.Talky_Server ~= nil and E.Talky_ServerRunner ~= nil and E.Talky_Tags ~= nil, "server modules loaded in the same Lua state")
check(H.g(SP, "Talky_Runner") == nil, "the 0.3.0 client runner is gone")
check(E.TalkyNet.mode() == "sp", "mode: sp")
check(E.Talky_Settings.data ~= nil and E.Talky_Settings.data.webhooks.secret ~= nil, "talky_config.json read at game start")
check(E.Talky_Config.maxZombiesPerAction == 20, "settings from talky_config.json applied")
local gs = H.events(SP, "game_started")
check(#gs == 1 and gs[1].data.mode == "sp" and gs[1].data.host == false, "game_started written to talky_outbox.txt at start (mode sp)")
check(fs["talky_outbox.jsonl"] == nil and #SP.refusedWrites == 0, "nothing written to the 0.3.0 talky_outbox.jsonl (the game refuses .jsonl)")
H.tick(3)
check(E.Talky_Bridge.hello.state == "allowed", "hello answered by the local server code within 3 ticks")
check(E.Talky_Bridge.allowMe() == false, "Allow me does nothing in single player")

---------------------------------------------------------------- the local transport

section("single player: local transport")

-- Both directions go through a queue drained on the next tick, copied with the rules of the
-- network (the game's SinglePlayerClient serializes too): never a direct call (R8).
local gotS, gotC, callsS = nil, nil, 0
E.Talky_Server.commands.probe = function(player, key, args) callsS = callsS + 1; gotS = { player = player, args = args } end
E.Talky_Client.handlers.probe = function(a) gotC = a end
local sentArgs = { n = 1, s = "x", sub = {}, list = { { k = "v" } }, f = function() end, [true] = 1 }
check(E.TalkyNet.toServer("probe", sentArgs) == true and callsS == 0, "toServer queues the message: the server code does not run inside the call")
sentArgs.s = "changed after sending"
sentArgs.list[1].k = "changed"
H.tick(1)
check(callsS == 1 and gotS.player == SP.localPlayer, "delivered on the next tick, with the local player")
local got = gotS.args or {}
check(got ~= sentArgs and got.s == "x" and got.list and got.list[1].k == "v" and got.n == 1, "the server code gets a copy made when it was sent")
check(got.f == nil and got[true] == nil and type(got.sub) == "table", "copied like the network: no function, no boolean key, a nested empty table kept")
E.TalkyNet.toServer("probe", {})
H.tick(1)
check(callsS == 2 and gotS.args == nil, "an empty table arrives as nil")
local back = { text = "hi", nested = { 1, 2 } }
E.TalkyNet.toClient(SP.localPlayer, "probe", back)
check(gotC == nil, "toClient queues too")
back.text = "changed"
H.tick(1)
check(gotC ~= nil and gotC ~= back and gotC.text == "hi" and gotC.nested and gotC.nested[2] == 2, "the client code gets a copy on the next tick")
E.Talky_Server.commands.probe, E.Talky_Client.handlers.probe = nil, nil

---------------------------------------------------------------- the window, in both languages

local function textShown(s)
    local pat = string.gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    for _, t in ipairs(SP.ui.TEXTS) do
        if string.find(t, pat) then return true end
    end
    return false
end
local function findButton(title)
    for i = #SP.ui.BUTTONS, 1, -1 do
        if SP.ui.BUTTONS[i].title == title then return SP.ui.BUTTONS[i] end
    end
    return nil
end
local function noMissingText(label)
    local bad = {}
    for _, t in ipairs(SP.ui.TEXTS) do
        if string.find(t, "UI_Talky_") or string.find(t, "%%%d") then bad[#bad + 1] = t end
    end
    for _, t in ipairs(bad) do print("        untranslated: " .. t) end
    check(#bad == 0, label .. ": no missing key and no unfilled %1 on screen (" .. #SP.ui.TEXTS .. " texts)")
    local missingKeys = {}
    for k in pairs(SP.MISSING) do missingKeys[#missingKeys + 1] = k end
    for k in pairs(SP.BAD_ARGS) do missingKeys[#missingKeys + 1] = "args:" .. k end
    for _, k in ipairs(missingKeys) do print("        " .. k) end
    check(#missingKeys == 0, label .. ": every getText call finds its key with the right arguments")
end

for _, lang in ipairs({ "EN", "FR" }) do
    section("single player: F8 window " .. lang)
    SP.lang = lang
    SP.ui.TEXTS, SP.ui.BUTTONS, SP.MISSING, SP.BAD_ARGS = {}, {}, {}, {}
    NOW = NOW + 10
    STATUS.ts = NOW
    fs["talky_status.json"] = JSON.encode(STATUS)
    E.Talky_Settings.statusReadAt = 0

    if E.Talky_Window.instance then E.Talky_Window.instance:close() end
    E.Talky_Window.toggle()
    local win = E.Talky_Window.instance
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
        local ed = E.Talky_StepEditor.open(nil, function(step) saved = step end)
        for _, s in ipairs(E.Talky_Actions.schema) do
            ed.step = { action = s.action }
            ed:buildFields(true)
        end
        ed.step = { action = "notify" }
        ed:buildFields(true)
        ed:onOk()
        assert(saved and saved.action == "notify", "step editor returns the step")
        assert(saved.text == E.Talky_T("Default_notify"), "translated default text")
        E.Talky_StepEditor.open({ ["if"] = { bits = { gte = 1 } }, ["then"] = {} }, function() end)
        local je = E.Talky_JsonEditor.open("t", "h", { a = 1 }, function() end)
        je.box.text = "{ bad json"
        je:onOk()
        for _, step in ipairs(CONFIG.workflows.new_follower.steps) do SP.ui.TEXTS[#SP.ui.TEXTS + 1] = E.Talky_UI.stepSummary(step) end
    end)
    check(ok2, "step editor and JSON editors build" .. (ok2 and "" or (": " .. tostring(err2))))
    noMissingText(lang)

    if lang == "EN" then
        check(textShown("Status") and textShown("Game events") and textShown("Bridge connected on port 7420 - 2 job(s) waiting"), "English texts shown")
        check(textShown("skipped: cooldown") and textShown("skipped: no matching route"), "skip reasons translated (EN)")
        check(textShown(E.Talky_T("Status_Rejected", E.Talky_T("Reason_disabled"))), "a job the server refused is shown with its reason")
    else
        -- Only ASCII literals here: Kahlua mangles accented characters in compiled Lua
        -- strings (one more reason to keep every text in UI.json).
        check(E.Talky_T("Page_status") == "Statut" and string.find(E.Talky_T("Page_events"), "nements du jeu$") ~= nil, "French page names")
        check(textShown(E.Talky_T("Page_events")) and textShown(E.Talky_T("Page_settings"))
            and textShown(E.Talky_T("Status_Online", "7420", "2")) and string.find(E.Talky_T("Status_Online", "7420", "2"), "sur le port 7420 %- 2 job%(s%) en attente") ~= nil,
            "French texts shown")
        check(textShown(E.Talky_T("Status_Skipped", E.Talky_T("Skip_cooldown")))
            and textShown(E.Talky_T("Status_Skipped", E.Talky_T("Skip_no_matching_route")))
            and E.Talky_T("Skip_no_matching_route") == "aucune route ne correspond", "skip reasons translated (FR)")
    end
    check(textShown("(v0.4.0)"), "bridge version shown on the Status page")
    check(textShown(E.Talky_T("Mode_Solo")), "Status page: single player mode")
    check(not textShown(E.Talky_T("Bridge_TooOld")), "no 'bridge too old' warning with a 0.4.0 bridge")
    check(textShown("erreur : http refused") or textShown("error: http refused"), "bridge errors shown on the Status page")
    check(textShown("(off) off_wf"), "disabled workflows marked (off)")

    -- tokens: none shown, none copied. The clipboard gets the bridge command that copies the
    -- full URL (game Lua can read the clipboard, and the game never knows the tokens).
    local function tokenFree(s)
        s = tostring(s or "")
        return not string.find(s, "GLOBALTOKEN", 1, true) and not string.find(s, "DEDICATEDTOKEN", 1, true)
    end
    local clean = true
    for _, t in ipairs(SP.ui.TEXTS) do if not tokenFree(t) then clean = false; print("        token shown: " .. t) end end
    check(clean, "no page of the window shows a token (the fake one of the status, the 0.3.0 one of talky_config.json)")
    check(textShown("https://abc.trycloudflare.com/hooks/follow?token=*****   ->  new_follower"), "Status page: webhook URLs with the token masked")

    SP.ui.BUTTONS = {}
    win:showPage("status")
    check(textShown(string.sub(E.Talky_T("Status_UrlCommandHelp"), 1, 30)), "Status page: a line explains the copied command")
    local copy = findButton(E.Talky_T("Btn_CopyCommand"))
    SP.ui.CLIPBOARD = nil
    if copy then copy.onclick(copy.target, copy) end
    check(SP.ui.CLIPBOARD == "node bridge\\bridge.js url follow", "Status page: Copy command copies the bridge command of the selected webhook")

    win.selectedHook = "secret"
    SP.ui.ENTRIES, SP.ui.BUTTONS, SP.ui.TEXTS = {}, {}, {}
    win:showPage("webhooks")
    local tokenBox = false
    for _, e in ipairs(SP.ui.ENTRIES) do
        if not tokenFree(e:getInternalText()) or e:isMasked() then tokenBox = true end
    end
    check(not tokenBox, "Webhooks page: no token field (a dedicated token lives in bridge/config.json)")
    check(textShown(E.Talky_T("Hooks_TokenYes")) and textShown(string.sub(E.Talky_T("Hooks_TokenWhere"), 1, 30)),
        "Webhooks page: dedicated token yes, from hookTokens of talky_status.json, and where it is set")
    copy = findButton(E.Talky_T("Btn_CopyCommand"))
    SP.ui.CLIPBOARD = nil
    if copy then copy.onclick(copy.target, copy) end
    check(SP.ui.CLIPBOARD == "node bridge\\bridge.js url secret" and H.hasToast(SP, E.Talky_T("Toast_CommandCopied", "secret")),
        "Webhooks page: Copy command copies the bridge command, with a toast")
    win.selectedHook = "follow"
    SP.ui.TEXTS = {}
    win:showPage("webhooks")
    check(textShown(E.Talky_T("Hooks_TokenNo")) and not textShown(E.Talky_T("Hooks_TokenYes")), "Webhooks page: a webhook missing from hookTokens takes the bridge token")
    win:close()
end
SP.lang = "EN"

check(E.Talky_Settings.hookUrl("follow") == "https://abc.trycloudflare.com/hooks/follow?token=*****"
    and E.Talky_Settings.hookUrl("secret") == "https://abc.trycloudflare.com/hooks/secret?token=*****",
    "hookUrl: the token masked, whatever talky_status.json and talky_config.json hold")
check(E.Talky_Settings.baseUrl() == "https://abc.trycloudflare.com", "trailing slash removed from the public URL")
check(E.Talky_Settings.urlCommand("x & del /q *") == nil and E.Talky_Settings.urlCommand('a"b') == nil
    and E.Talky_Settings.urlCommand(string.rep("a", 65)) == nil and E.Talky_Settings.urlCommand("my-hook_2") == "node bridge\\bridge.js url my-hook_2",
    "urlCommand: only ids of ASCII letters, digits, - and _ (talky_config.json can be written by any mod)")
SP.ui.CLIPBOARD = "before"
E.Talky_Window.toggle()
E.Talky_Window.instance:copyUrlCommand("x & del /q *")
check(SP.ui.CLIPBOARD == "before" and H.hasToast(SP, E.Talky_T("Toast_HookIdUnsafe", "x & del /q *")), "an id with shell characters: nothing copied, a toast says to rename it")
E.Talky_Window.instance:close()

-- Saving keeps valid JSON, and adds no token
E.Talky_Window.toggle()
E.Talky_Window.instance:onSave()
local reread = JSON.tryDecode(fs["talky_config.json"])
check(reread ~= nil and reread.settings.anonymousName == "Ghost" and reread.webhooks.follow.workflow == "new_follower", "Save writes valid JSON with every field")
check(not string.find(fs["talky_config.json"], "GLOBALTOKEN", 1, true) and reread.webhooks.follow.token == nil,
    "Save writes no token into talky_config.json (the fake token of talky_status.json is not taken)")
check(reread.webhooks.secret.token == "DEDICATEDTOKEN", "the token Talky 0.3.0 saved stays as it was: the window does not touch it, the bridge ignores it and says so")
E.Talky_Window.instance:close()

-- a bridge older than 0.4.0 (no protocol and no hookTokens in talky_status.json, a token)
local old = { ts = NOW, version = "0.3.0", port = 7420, token = "OLDBRIDGETOKEN", pending = 0 }
fs["talky_status.json"] = JSON.encode(old)
E.Talky_Settings.statusReadAt = 0
SP.ui.TEXTS = {}
E.Talky_Window.toggle()
E.Talky_Window.instance:showPage("status")
check(E.Talky_Settings.bridgeTooOld() and textShown(string.sub(E.Talky_T("Bridge_TooOld"), 1, 40)), "a 0.3.0 bridge gets the 'bridge too old' warning")
E.Talky_Window.instance.selectedHook = "secret"
E.Talky_Window.instance:showPage("webhooks")
local oldShown = false
for _, t in ipairs(SP.ui.TEXTS) do if string.find(t, "OLDBRIDGETOKEN", 1, true) then oldShown = true end end
SP.ui.CLIPBOARD = nil
local oldCopy = findButton(E.Talky_T("Btn_CopyCommand"))
if oldCopy then oldCopy.onclick(oldCopy.target, oldCopy) end
check(textShown(E.Talky_T("Hooks_TokenUnknown")) and not oldShown and SP.ui.CLIPBOARD == "node bridge\\bridge.js url secret",
    "a 0.3.0 status (a token, no hookTokens): dedicated token unknown, its token neither shown nor copied")
E.Talky_Window.instance:close()
STATUS.ts = NOW
fs["talky_status.json"] = JSON.encode(STATUS)
E.Talky_Settings.statusReadAt = 0

---------------------------------------------------------------- settings and fixed caps

section("single player: caps")

local A = E.Talky_Actions
check(A.waitMs({ seconds = 99999 }) == 600000, "wait capped to 600 s")
check(A.waitMs({ seconds = -3 }) == 0, "negative wait becomes 0")
check(A.waitMs({}) == 1000 and A.waitMs({ seconds = "inf" }) == 1000 and A.waitMs({ seconds = 0 / 0 }) == 1000 and A.waitMs({ seconds = "1e3" }) == 1000,
    "wait without a plain number = 1 s (nan, inf, exponent refused)")
check(A.waitMs({ seconds = "12" }) == 12000 and A.waitMs({ seconds = " 2.5 " }) == 2500, "wait accepts numeric text")

-- talky_config.json edited by hand: values clamped to the bounds of the window
E.Talky_Settings.data.settings.maxZombiesPerAction = 99999
E.Talky_Settings.data.settings.maxActiveJobs = "NaN"
E.Talky_Settings.data.settings.nameTagRange = -5
E.Talky_Settings.apply()
check(E.Talky_Config.maxZombiesPerAction == 300 and E.Talky_Config.maxActiveJobs == 8 and E.Talky_Config.nameTagRange == 5,
    "settings from the file are clamped (99999 -> 300, NaN ignored, -5 -> 5)")
E.Talky_Settings.data.settings.maxZombiesPerAction = 20
E.Talky_Settings.data.settings.maxActiveJobs = nil
E.Talky_Settings.data.settings.nameTagRange = 25
E.Talky_Settings.apply()
local caps = E.Talky_Config.caps()
check(caps.enforce == false and caps.maxZombiesPerAction == 20 and caps.maxQueuedJobs == 200 and caps.maxJobsPerMinute == nil,
    "single player caps: the F8 settings, a queue of 200, no rate limit, no sandbox toggle")

---------------------------------------------------------------- a job end to end

section("single player: jobs")

local long = string.rep("x", 500)
H.setInbox(SP, { { seq = 1, workflow = "wf_a", user = "viewer", steps = {
    { action = "notify", text = long, seconds = 999, color = "#ff0000" },
    { action = "spawn_zombie", name = string.rep("N", 60), count = 2, color = "nothex" },
    { action = "say", text = long },
    { action = "halo", text = long },
    { action = "emit", event = "custom_evt", data = { k = 1 } },
    { action = "weather", type = "storm", hours = 4 },
    { action = "xp", perk = "Strength", amount = 50000 },
    { action = "nosuchaction" },
    { action = "horde", name = "Raid", count = 999, sameName = true },
} } })
H.tick(15)
check(fs["talky_ack.txt"] == "1", "job acked once the local server code accepted it (" .. tostring(fs["talky_ack.txt"]) .. ")")
local toast
for _, t in ipairs(E.Talky_Overlay.toasts) do if string.sub(t.text, 1, 1) == "x" then toast = t end end
check(toast and string.len(toast.text) == 200, "notify text capped to 200 characters")
check(toast and toast.untilMs - NOW > 50000 and toast.untilMs - NOW <= 60000, "notify duration capped to 60 s")
check(#W.zombies == 22, "zombies spawned in the single player world, the horde capped by the F8 setting (2 + 20)")
check(W.zombies[1] and W.zombies[1].id == -1 and string.len(W.zombies[1].md.Talky_name) == 40, "zombie name capped to 40 characters, kept in its modData")
check(W.zombies[1] and W.zombies[1].md.Talky_color == nil, "a bad color is dropped")
check(W.zombies[3] and W.zombies[3].md.Talky_name == "Raid" and W.zombies[3].spottedBy == SP.localPlayer, "horde named, zombies go for the player")
check(acc.said[1] and acc.said[1].side == "sp" and string.len(acc.said[1].text) == 200, "say text capped (player:Say in single player)")
check(SP.halos[1] and string.len(SP.halos[1].text) == 200, "halo text capped")
check(#W.weather == 1 and W.weather[1].stage == 3 and W.weather[1].hours == 4, "storm through triggerCustomWeatherStage")
check(W.xp[1] and W.xp[1].amount == 10000 and W.xp[1].perk == "Strength", "xp capped to 10000 (0.3.0 cap)")
local ce = H.events(SP, "custom_evt")
check(#ce == 1 and ce[1].data.k == 1, "emit step written from the local copy of the job")
local jd = H.events(SP, "job_done")
check(#jd == 1 and jd[1].data.workflow == "wf_a" and jd[1].data.seq == 1, "job_done written")
local af = H.events(SP, "action_failed")
check(#af == 1 and af[1].data.action == "nosuchaction" and af[1].data.code == "unknown_action" and af[1].data.error == "unknown_action",
    "unknown action skipped and reported (code, and error for 0.3.0 workflows), the job goes on")
check(H.count(E.Talky_Client.tags) == 0, "no name registry in single player (names stay in modData)")

-- the overlay finds the names in modData
E.Talky_Overlay.tagged = {}
SP.ui.DRAWN = {}
SP.fire("OnPostUIDraw")
local drawn = false
for _, t in ipairs(SP.ui.DRAWN) do if string.find(t, "^NNNN") then drawn = true end end
check(drawn, "name tag drawn above the zombie")

-- a named zombie dies, twice like a burning zombie; the banner in the player's language
-- (first of a group of 2: the 40-character name is shortened to keep its number)
local first2 = string.rep("N", 37) .. " #1"
check(W.zombies[2] and W.zombies[2].md.Talky_name == string.rep("N", 37) .. " #2", "a group member keeps its number at the end of a long name")
SP.lang = "FR"
H.kill(SP, W.zombies[1], SP.localPlayer, 2)
H.tick(2)
local zk = H.events(SP, "zombie_killed")
check(#zk == 1 and zk[1].data.byPlayer == true and zk[1].data.name == first2, "zombie_killed written once, byPlayer = true")
local banner = false
for _, t in ipairs(H.toastTexts(SP)) do
    if t == E.Talky_T("Toast_ZombieDown", first2) and string.find(t, "pour de bon%.$") then banner = true end
end
check(banner, "zombie death banner translated (FR)")
SP.lang = "EN"
H.kill(SP, W.zombies[2], nil)
H.tick(2)
zk = H.events(SP, "zombie_killed")
check(#zk == 2 and zk[2].data.byPlayer == false, "a zombie the player did not kill: byPlayer = false")

-- weather during a weather period: stopped first
W.weatherRunning = true
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 2, workflow = "w", steps = { { action = "weather", type = "blizzard", hours = 99 } } } })
H.tick(15)
check(#W.weather == 2 and W.weather[2].stage == 7 and W.weather[2].hours == 72, "weather stops the current period first, hours capped to 72")
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 3, workflow = "w", steps = { { action = "weather", stage = 1, hours = 2 }, { action = "weather", type = "clear" } } } })
H.tick(15)
check(#W.weather == 3 and W.weather[3].stage == 1 and W.weatherRunning == false, "single player keeps the raw stage of 0.3.0; clear stops the weather")

-- strict numbers
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 4, workflow = "n", steps = {
    { action = "time", hour = "banan" }, { action = "time", hour = "inf" }, { action = "time", hour = "12abc" },
    { action = "time", hour = "-5" }, { action = "time", hour = "30" }, { action = "time", hour = " 7.5 " },
    { action = "spawn_zombie", count = "1e308" }, { action = "spawn_zombie", count = "0x10" } } } })
local before = #W.zombies
H.tick(15)
local times = W.times
check(times[1] == 0 and times[2] == 0 and times[3] == 0, "hour 'banan', 'inf' and '12abc' fall back to the default")
check(times[4] == 0 and times[5] == 23.99 and times[6] == 7.5, "hour clamped to 0..23.99, numeric text accepted")
check(#W.zombies == before + 2, "count '1e308' and '0x10' fall back to 1")

-- expired job: acked without running
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 5, workflow = "old", expiresAt = NOW - 1, steps = { { action = "time", hour = 5 } } } })
H.tick(15)
check(fs["talky_ack.txt"] == "5" and #W.times == 6, "expired job acked without running")

-- the other actions, single player side
H.bridgeApplyAck(SP)
acc.stats = {}
H.addInbox(SP, { { seq = 6, workflow = "all", steps = {
    { action = "heal" },
    { action = "stat", stat = "panic", op = "set", value = 50 },
    { action = "stat", stat = "BOGUS", value = 1 },
    { action = "sound", name = "ZombieSurprisedPlayer" },
    { action = "noise", radius = 250, sound = "Thunder" },
    { action = "thunder", strike = true },
    { action = "helicopter" },
    { action = "fire", distance = 5 },
    { action = "vehicle", script = "Base.PickUpTruck" },
    { action = "vehicle", script = "Base.NoSuchCar" },
    { action = "give_item", item = "Base.Bandage", count = 500 },
    { action = "give_item", item = "Base.Apple", count = 3, onGround = true },
    { action = "give_item", item = "Base.Nope" },
    { action = "xp", perk = "None", amount = 5 },
    { action = "xp", perk = "MAX", amount = 5 },
    { action = "xp", perk = "FromString", amount = 5 },
    { action = "emit", event = "test_workflow", data = { workflow = "x" } },
} } })
H.tick(15)
check(acc.healed[1] == "sp" and #acc.healed == 1, "heal in the game")
check(acc.stats.PANIC == 50 and acc.statSide == "sp", "stat set in the game (no server sync in single player)")
check(acc.sounds[1] and acc.sounds[1].side == "sp" and acc.sounds[1].name == "ZombieSurprisedPlayer" and acc.sounds[2] and acc.sounds[2].name == "Thunder",
    "sound and noise sound through the player's emitter (playServerSound does nothing in single player)")
check(W.sounds[1] and W.sounds[1].r == 250, "noise radius up to 300 in single player")
check(#W.thunder == 1 and W.thunder[1].transmitted == false and W.thunder[1].strike == true, "thunder through triggerThunderEvent")
check(#W.heli == 1 and W.heli[1].target == "Bob", "helicopter (sandbox toggles ignored in single player)")
check(#W.fires == 1, "fire started")
check(#W.vehicles == 1 and W.vehicles[1].script == "Base.PickUpTruck", "vehicle spawned, an unknown script refused")
check(acc.items[1] and acc.items[1].n == 100 and acc.items[1].side == "sp" and #W.ground == 3, "give_item capped to 100, onGround puts the items on the floor")
local codes = {}
for _, e in ipairs(H.events(SP, "action_failed")) do
    if e.data.seq == 6 then codes[#codes + 1] = e.data.action .. ":" .. e.data.code end
end
table.sort(codes)
check(table.concat(codes, ",") == "give_item:not_found,stat:not_found,vehicle:not_found,xp:not_found,xp:not_found,xp:not_found",
    "unknown stat, vehicle, item and perk (None, MAX, a static method) reported as not_found (" .. table.concat(codes, ",") .. ")")
check(#H.events(SP, "test_workflow") == 0, "an emit step never writes test_workflow")

-- actions of other mods keep the 0.3.0 contract in single player
local got
E.Talky_Actions.register("confetti", function(p, player, job, ctx)
    got = { amount = p.amount, extra = p.extra, user = player:getUsername(), workflow = job.workflow, seq = job.seq }
end)
E.Talky_Actions.register("broken", function() error("boom") end)
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 7, workflow = "party", steps = { { action = "confetti", amount = "5", extra = { a = 1 } }, { action = "broken" }, { action = "notify", text = "after" } } } })
H.tick(15)
check(got and got.amount == "5" and got.extra and got.extra.a == 1 and got.user == "Bob" and got.workflow == "party" and got.seq == 7,
    "an action registered by another mod runs with the step as written and job = { seq, workflow... }")
local broken = false
for _, e in ipairs(H.events(SP, "action_failed")) do
    if e.data.seq == 7 and e.data.action == "broken" and e.data.code == "error" then broken = true end
end
check(broken and H.hasToast(SP, "after"), "an action that raises an error is reported (code error) and the job goes on")

---------------------------------------------------------------- queue, waits, pause, death

section("single player: queue and waits")

-- inbox -> runner -> ack (0.3.0 scenario)
H.bridgeApplyAck(SP)
E.Talky_Overlay.toasts = {}
H.addInbox(SP, {
    { seq = 10, workflow = "a", steps = { { action = "notify", text = "one" } } },
    { seq = 11, workflow = "b", steps = { { action = "wait", seconds = 5000 }, { action = "notify", text = "two" } } },
    { seq = 12, workflow = "c", expiresAt = NOW - 1, steps = { { action = "notify", text = "old" } } },
})
H.tick(15)
check(fs["talky_ack.txt"] == "12", "ack written: both jobs accepted, the expired one skipped (" .. tostring(fs["talky_ack.txt"]) .. ")")
check(H.hasToast(SP, "one") and not H.hasToast(SP, "two") and not H.hasToast(SP, "old"), "first job ran, second job waits, expired job never ran")
H.wait(599000)
check(not H.hasToast(SP, "two"), "still waiting after 599 s")
H.wait(3000)
check(H.hasToast(SP, "two"), "a 5000 s wait ends after 600 s")

-- a full queue answers busy: the job is kept and sent again (0.3.0 dropped it)
H.bridgeApplyAck(SP)
E.Talky_Config.maxQueuedJobs, E.Talky_Config.maxActiveJobs = 3, 2
local jobs = {}
for s = 20, 27 do jobs[#jobs + 1] = { seq = s, workflow = "q" .. s, steps = { { action = "wait", seconds = 20 }, { action = "notify", text = "q" .. s } } } end
H.addInbox(SP, jobs)
H.tick(20)
check(E.Talky_ServerRunner.pendingCount() == 3 and fs["talky_ack.txt"] == "22", "queue full: 3 jobs of the batch taken, 5 answered busy and not acked (" .. tostring(fs["talky_ack.txt"]) .. ")")
H.tick(60)
check(E.Talky_ServerRunner.pendingCount() == 5 and fs["talky_ack.txt"] == "24", "busy jobs sent again 5 s later: the queue fills up again (2 running + 3 waiting)")
H.wait(120000)
check(fs["talky_ack.txt"] == "27" and H.hasToast(SP, "q27"), "busy jobs sent again later, accepted and run (" .. tostring(fs["talky_ack.txt"]) .. ")")
E.Talky_Config.maxQueuedJobs, E.Talky_Config.maxActiveJobs = 200, 8

-- paused game: no tick at all (IngameState skips OnTick)
H.bridgeApplyAck(SP)
SP.paused = true
H.addInbox(SP, { { seq = 30, workflow = "p", steps = { { action = "notify", text = "after pause" } } } })
H.tick(30)
check(fs["talky_ack.txt"] == "27" and not H.hasToast(SP, "after pause"), "nothing read nor run while the game is paused")
SP.paused = false
H.tick(15)
check(fs["talky_ack.txt"] == "30" and H.hasToast(SP, "after pause"), "the job runs once the game goes on")

-- dead player: nothing relayed, a job does not move
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 31, workflow = "d", steps = { { action = "wait", seconds = 2 }, { action = "notify", text = "alive again" } } } })
H.tick(15)
acc.dead = true
H.addInbox(SP, { { seq = 32, workflow = "d2", steps = { { action = "notify", text = "second" } } } })
H.wait(10000)
check(fs["talky_ack.txt"] == "31" and not H.hasToast(SP, "alive again"), "while the player is dead: the running job waits, no new job is read")
acc.dead = false
H.tick(20)
check(fs["talky_ack.txt"] == "32" and H.hasToast(SP, "alive again") and H.hasToast(SP, "second"), "both jobs go on after the respawn")

-- Test now: the nonce of talky_status.json, the translated test name
H.clearOutbox(SP)
E.Talky_Settings.testWorkflow("new_follower")
local tw = H.events(SP, "test_workflow")
check(#tw == 1 and tw[1].data.nonce == "n0nce-1" and tw[1].data.workflow == "new_follower" and tw[1].data.vars.user == "Tester",
    "Test now carries the testNonce of talky_status.json and the translated test name")

-- the outbox writer refused (a 0.3.0 file name): logged once, never an error
E.Talky_Config.outboxFile = "talky_outbox.jsonl"
E.Talky_Bridge.emit("x", {})
E.Talky_Bridge.emit("y", {})
check(H.logCount(SP, "cannot write talky_outbox%.jsonl") == 1 and fs["talky_outbox.jsonl"] == nil, "a refused outbox file is logged once")
E.Talky_Config.outboxFile = "talky_outbox.txt"
SP.refusedWrites = {}

---------------------------------------------------------------- 0.3.0 behaviours kept

section("single player: numbered names, refused steps, old and long jobs")

local function eventsOf(name, seq)
    local out = {}
    for _, e in ipairs(H.events(SP, name)) do if e.data.seq == seq then out[#out + 1] = e end end
    return out
end

-- a group with a 40-character name: every zombie keeps its own number
H.bridgeApplyAck(SP)
local zb = #W.zombies
H.addInbox(SP, { { seq = 40, workflow = "num", steps = { { action = "spawn_zombie", name = string.rep("L", 40), count = 12 } } } })
H.tick(15)
local labels, distinct, longest = {}, 0, 0
for i = zb + 1, #W.zombies do
    local n = W.zombies[i].md.Talky_name or ""
    if not labels[n] then labels[n] = true; distinct = distinct + 1 end
    if string.len(n) > longest then longest = string.len(n) end
end
check(#W.zombies - zb == 12 and distinct == 12 and longest == 40 and labels[string.rep("L", 37) .. " #1"] and labels[string.rep("L", 36) .. " #12"],
    "12 zombies of a 40-character name: 12 different names, ' #1' to ' #12' kept, 40 characters at most")

-- a job whose steps are all refused: action_failed for each, then job_done (0.3.0), no refusal
H.bridgeApplyAck(SP)
E.Talky_Overlay.toasts = {}
H.addInbox(SP, { { seq = 41, workflow = "only_bad", steps = { { action = "nosuchaction" }, { action = "bad-name" } } } })
H.tick(15)
local codes41 = {}
for _, e in ipairs(eventsOf("action_failed", 41)) do codes41[#codes41 + 1] = e.data.action .. ":" .. e.data.code end
table.sort(codes41)
check(table.concat(codes41, ",") == "nosuchaction:unknown_action,step:invalid" and #eventsOf("job_done", 41) == 1
    and #eventsOf("job_rejected", 41) == 0 and #E.Talky_Overlay.toasts == 0 and fs["talky_ack.txt"] == "41",
    "only unknown or unreadable steps: action_failed for each (an unreadable one as 'step'), then job_done; no refusal, no toast ("
    .. table.concat(codes41, ",") .. ")")

-- a job older than 15 minutes (jobTtlSeconds above 900 in the bridge): skipped quietly
H.bridgeApplyAck(SP)
local times42 = #W.times
H.addInbox(SP, { { seq = 42, workflow = "late", createdAt = NOW - 1200000, expiresAt = NOW + 2400000, steps = { { action = "time", hour = 4 } } } })
H.tick(15)
check(fs["talky_ack.txt"] == "42" and #W.times == times42 and #eventsOf("job_rejected", 42) == 0 and #E.Talky_Overlay.toasts == 0
    and H.logHas(SP, "job 42 expired, skipped"), "a job created more than 15 minutes ago is acked and skipped without a refusal banner")

-- a long job: its emit step 40 minutes later is still written, even after other jobs were acked
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 43, workflow = "timer", steps = { { action = "wait", seconds = 600 }, { action = "wait", seconds = 600 },
    { action = "wait", seconds = 600 }, { action = "wait", seconds = 600 }, { action = "emit", event = "event_end", data = { k = 4 } } } } })
H.tick(15)
H.wait(31 * 60000, 10000)
H.bridgeApplyAck(SP)
H.addInbox(SP, { { seq = 44, workflow = "other", steps = { { action = "notify", text = "in between" } } } })
H.wait(10 * 60000, 10000)
local ends = H.events(SP, "event_end")
check(#ends == 1 and ends[1].data.k == 4 and H.hasToast(SP, "in between"), "an emit step 40 minutes into a job is written (the local copy lives as long as the job)")
local copy43
for _, r in pairs(E.Talky_Bridge.relayed) do if r.seq == 43 then copy43 = r end end
check(copy43 and copy43.steps == nil and copy43.done == true and copy43.workflow == "timer", "after job_done the local copy keeps its workflow name only")

-- the 60-a-minute budget is for lines from a remote server: single player writes them all
H.clearOutbox(SP)
for i = 1, 100 do E.TalkyNet.toClient(SP.localPlayer, "emit", { event = "job_done", data = { seq = 5000 + i } }) end
H.tick(2)
check(#H.events(SP, "job_done") == 100, "single player: 100 game events in a minute, all written (as 0.3.0)")

-- a refused Test now: the translated reason, not the English text meant for older windows
STATUS.recent[#STATUS.recent + 1] = { at = "2026-10-25T10:00:05.000Z", source = "test", workflow = "new_follower",
    skipped = "test code mismatch", error = "Test now refused: test code mismatch, press Test now again" }
STATUS.ts = NOW
fs["talky_status.json"] = JSON.encode(STATUS)
E.Talky_Settings.statusReadAt = 0
SP.ui.TEXTS = {}
E.Talky_Window.toggle()
E.Talky_Window.instance:showPage("status")
check(textShown(E.Talky_T("Status_Skipped", E.Talky_T("Skip_test_code_mismatch"))) and not textShown("Test now refused"),
    "a refused Test now shows 'skipped: test code mismatch...' (translated), without the English error")
E.Talky_Window.instance:close()

-- the server code of a single player game did not start: no "server console" to look at
local accQ = H.account("Quiet", { x = 50, y = 50 })
local SQ = H.newSP(accQ, { fs = {}, name = "SP3" })
SQ.E.TalkyNet.serverHandler = nil
H.wait(125000, 1000)
SQ.ui.TEXTS = {}
SQ.E.Talky_Window.toggle()
SQ.E.Talky_Window.instance:showPage("status")
local soloText, serverText = false, false
for _, t in ipairs(SQ.ui.TEXTS) do
    if string.find(t, "Talky game code did not start", 1, true) then soloText = true end
    if string.find(t, "server console", 1, true) then serverText = true end
end
SQ.E.Talky_Window.instance:close()
check(SQ.E.Talky_Bridge.hello.state == "no_answer" and soloText and not serverText and H.logHas(SQ, "errors in console%.txt"),
    "single player without its server code: F8 and the console point to console.txt, not to a server console")
H.hygiene(SQ, "single player without its server code")

H.tick(5)
H.hygiene(SP, "single player")
