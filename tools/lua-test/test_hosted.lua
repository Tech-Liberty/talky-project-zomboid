-- Hosted game: the host's game is an MP client of a coop server started on the same PC with
-- -cachedir: both processes share Zomboid/Lua. The host's account has the default role.

local JSON = H.JSON

section("hosted game")

local hostFS = {}
-- a 0.4.0 bridge writes no token in talky_status.json; the fake one here proves the window
-- never takes it (the host's game and the coop server share this folder)
hostFS["talky_status.json"] = JSON.encode({ ts = NOW, version = "0.4.0", protocol = 2, port = 7420, token = "HOSTFAKETOKEN", testNonce = "h", pending = 1,
    hookTokens = {} })
hostFS["talky_config.json"] = JSON.encode({ publicUrl = "https://host.example", webhooks = { follow = { workflow = "h" } } })
-- a save made before 0.4.0: no Talky sandbox options at all
local HS = H.newServer("HS", { fs = hostFS, sandbox = {}, serverName = "host world" })
check(HS.E.Talky_Config.readSandbox().AllowAdmins == true and HS.E.Talky_Config.caps().maxZombiesPerAction == 30,
    "no Talky sandbox options in the save: the defaults apply")
local accH = H.account("Big Host", { x = 200, y = 200 })
local HC = H.newClient("HC", accH, HS, { fs = hostFS, host = true })
H.setInbox(HC, { { seq = 1, workflow = "h", steps = { { action = "spawn_zombie", name = "Hosty" }, { action = "notify", text = "hosted" } } } })
H.wait(5000, 100)
local st = HC.E.Talky_Bridge.serverStatus()
check(st.state == "denied" and st.host == true and st.username == "Big Host", "the host's default role is refused; the client knows it is the host")
check(hostFS["talky_ack.txt"] == nil and #HS.world.zombies == 0, "nothing relayed nor acked while refused (the job stays for later)")
local gs = H.events(HC, "game_started")
check(#gs == 1 and gs[1].data.host == true and gs[1].data.server == "host world", "game_started {host = true, server name}")

-- the F8 Status page explains it and offers "Allow me (host)"
HC.ui.TEXTS, HC.ui.BUTTONS = {}, {}
HC.E.Talky_Window.toggle()
local win = HC.E.Talky_Window.instance
win:showPage("status")
local helpShown, button = false, nil
for _, t in ipairs(HC.ui.TEXTS) do
    if t == HC.E.Talky_T("Server_NotAllowedHost", "Big Host") or string.find(t, "click Allow me", 1, true) then helpShown = true end
end
for _, b in ipairs(HC.ui.BUTTONS) do if b.title == HC.E.Talky_T("Btn_AllowMe") then button = b end end
check(helpShown and button ~= nil, "Status page: host message and the 'Allow me (host)' button")
if button then button.onclick(button.target, button) end
win:close()
check(HC.commands[1] == '/setaccesslevel "Big Host" admin', "Allow me sends /setaccesslevel for the host's own username (" .. tostring(HC.commands[1]) .. ")")
check(H.hasToast(HC, HC.E.Talky_T("Toast_AllowMeSent")), "with a toast")
H.wait(5000, 100)
check(accH.role == "admin" and HS.adminLog[#HS.adminLog] == "role of Big Host = admin", "the coop server lets its host change its own role")
-- hello again every 3 s; the server answers one hello per 5 s per player
H.wait(3000, 100)
check(HC.E.Talky_Bridge.hello.state == "allowed", "hello again: allowed within a few seconds")
H.wait(3000, 100)
check(hostFS["talky_ack.txt"] == "1" and #HS.world.zombies == 1 and HS.world.zombies[1].md.Talky_name == "Hosty" and H.hasToast(HC, "hosted"),
    "the job ran once on the coop server, acked once")
check(#H.events(HC, "job_done") == 1, "one job_done in the shared outbox")

-- the host's F8 window: the copy button gives the bridge command, no token anywhere
HC.ui.TEXTS, HC.ui.BUTTONS, HC.ui.CLIPBOARD = {}, {}, nil
HC.E.Talky_Window.toggle()
win = HC.E.Talky_Window.instance
win:showPage("status")
for i = #HC.ui.BUTTONS, 1, -1 do
    local b = HC.ui.BUTTONS[i]
    if b.title == HC.E.Talky_T("Btn_CopyCommand") then b.onclick(b.target, b); break end
end
win.selectedHook = "follow"
win:showPage("webhooks")
win:onSave()
win:close()
local hostLeak = string.find(hostFS["talky_config.json"] or "", "HOSTFAKETOKEN", 1, true) ~= nil
for _, t in ipairs(HC.ui.TEXTS) do if string.find(t, "HOSTFAKETOKEN", 1, true) then hostLeak = true end end
local noToken = false
for _, t in ipairs(HC.ui.TEXTS) do if t == HC.E.Talky_T("Hooks_TokenNo") then noToken = true end end
check(HC.ui.CLIPBOARD == "node bridge\\bridge.js url follow" and not hostLeak and noToken,
    "hosted game: Copy command copies the bridge command; the status token is shown, copied and saved nowhere; hookTokens {} = the bridge token")

-- a friend in the hosted game cannot use the host's way in
local accF = H.account("Friend", { x = 600, y = 600 })
local FC = H.newClient("FC", accF, HS, { fs = {} })
H.wait(5000, 100)
local fst = FC.E.Talky_Bridge.serverStatus()
check(fst.state == "denied" and fst.host == false, "a friend of the host: refused, not the host")
FC.ui.TEXTS, FC.ui.BUTTONS = {}, {}
FC.E.Talky_Window.toggle()
FC.E.Talky_Window.instance:showPage("status")
local fb = false
for _, b in ipairs(FC.ui.BUTTONS) do if b.title == FC.E.Talky_T("Btn_AllowMe") then fb = true end end
FC.E.Talky_Window.instance:close()
check(not fb, "no 'Allow me' button for a player who is not the host")
FC.E.Talky_Bridge.allowMe()
H.wait(35000, 500)
check(accF.role == "user" and FC.E.Talky_Bridge.hello.state == "denied" and string.find(HS.adminLog[#HS.adminLog], "^refused") ~= nil,
    "the same command from a friend is refused by the server")
-- once the host lists the friend (sandbox option), the friend's next hello is accepted
HS.E.SandboxVars.Talky = { AllowedPlayers = "friend" }
H.wait(31000, 500)
check(FC.E.Talky_Bridge.hello.state == "allowed", "a permission given during the game is picked up by the next hello (every 30 s)")

-- a username Allow me cannot quote
local accQ = H.account('Bad"Name', { x = 900, y = 900 })
local QC = H.newClient("QC", accQ, HS, { fs = {}, host = true })
H.wait(1000, 100)
check(QC.E.Talky_Bridge.allowMe() == false and #QC.commands == 0, "Allow me refuses a username with a quote")

H.tick(3)
H.hygiene(HS, "coop server")
H.hygiene(HC, "host's game")
H.hygiene(FC, "friend's game")
H.hygiene(QC, "quote")
