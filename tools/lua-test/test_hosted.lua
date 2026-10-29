-- Hosted game: the host's game is an MP client of a coop server started on the same PC: both
-- processes share Zomboid/Lua, where the bridge runs in server mode. The coop server reads the
-- jobs; the host's game never touches the bridge's files. The host's account has the default
-- role: a streamer, but not an admin until "Allow me".

local JSON = H.JSON

section("hosted game")

local hostFS = {}
-- a save made before 0.4.0: no Talky sandbox options at all
local HS = H.newServer("HS", { fs = hostFS, sandbox = {}, serverName = "host world" })
H.bridgeUp(HS, { publicUrl = "http://198.51.100.7:7420" })
H.setStreamers(HS, { "Big Host" })
check(HS.E.Talky_Config.readSandbox().MaxZombiesPerAction == 30 and HS.E.Talky_Config.caps().maxZombiesPerAction == 30,
    "no Talky sandbox options in the save: the defaults apply")
local accH = H.account("Big Host", { x = 200, y = 200 })
local HC = H.newClient("HC", accH, HS, { fs = hostFS, host = true })
H.setInbox(HS, { { seq = 1, workflow = "h", target = "Big Host", steps = { { action = "spawn_zombie", name = "Hosty" }, { action = "notify", text = "hosted" } } } })
H.wait(5000, 100)
check(hostFS["talky_ack.txt"] == "1" and #HS.world.zombies == 1 and HS.world.zombies[1].md.Talky_name == "Hosty" and H.hasToast(HC, "hosted"),
    "the job ran once on the coop server, around the host (a streamer, whatever the role), acked once")
check(#H.events(HS, "job_done") == 1 and H.events(HS, "job_done")[1].data.streamer == "Big Host", "one job_done in the shared outbox, for the host")
local gs = H.events(HS, "game_started")
check(#gs == 1 and gs[1].data.mode == "server", "game_started written once, by the coop server; the host's game writes none")
local RH = HC.E.Talky_Remote
check(RH.isStreamer() and not RH.isAdmin() and RH.isHost(), "the host: a streamer, not an admin (default role), and the client knows it is the host")

-- the F8 window explains it and offers "Allow me (host)"
HC.ui.TEXTS, HC.ui.BUTTONS = {}, {}
HC.E.Talky_Window.toggle()
local win = HC.E.Talky_Window.instance
win:showPage("webhooks")
local helpShown, reserved, button = false, false, nil
for _, t in ipairs(HC.ui.TEXTS) do
    if t == HC.E.Talky_T("Server_HostNotAdmin") then helpShown = true end
    if t == HC.E.Talky_T("Admin_Only") then reserved = true end
end
for _, b in ipairs(HC.ui.BUTTONS) do if b.title == HC.E.Talky_T("Btn_AllowMe") then button = b end end
check(reserved and helpShown and button ~= nil, "Webhooks page: reserved to admins, the host message and the 'Allow me (host)' button")
if button then button.onclick(button.target, button) end
win:close()
check(HC.commands[1] == '/setaccesslevel "Big Host" admin', "Allow me sends /setaccesslevel for the host's own username (" .. tostring(HC.commands[1]) .. ")")
check(H.hasToast(HC, HC.E.Talky_T("Toast_AllowMeSent")), "with a toast")
H.wait(5000, 100)
check(accH.role == "admin" and HS.adminLog[#HS.adminLog] == "role of Big Host = admin", "the coop server lets its host change its own role")
check(RH.isAdmin() and RH.configState == "ready", "the status asked again: the host is an admin now, the configuration loaded")

-- the host manages the streamers: a friend joins and is added
local accF = H.account("Friend", { x = 600, y = 600 })
local FC = H.newClient("FC", accF, HS, { fs = {} })
H.wait(5000, 100)
local fst = FC.E.Talky_Remote
check(not fst.isStreamer() and not fst.isAdmin() and not fst.isHost(), "a friend of the host: not a streamer, not an admin, not the host")
FC.ui.TEXTS, FC.ui.BUTTONS = {}, {}
FC.E.Talky_Window.toggle()
FC.E.Talky_Window.instance:showPage("webhooks")
local fb = false
for _, b in ipairs(FC.ui.BUTTONS) do if b.title == FC.E.Talky_T("Btn_AllowMe") then fb = true end end
FC.E.Talky_Window.instance:close()
check(not fb, "no 'Allow me' button for a player who is not the host")
FC.E.Talky_Remote.allowMe()
H.wait(5000, 100)
check(accF.role == "user" and string.find(HS.adminLog[#HS.adminLog], "^refused") ~= nil and not fst.isAdmin(), "the same command from a friend is refused by the server")
RH.streamerOp("add", "Friend")
H.tick(3)
check(table.concat(H.bridgeRequests(HS), ",") == "add:Friend", "the host adds the friend: the bridge on the host's PC draws the token")
H.wait(2000, 100)
H.bridgeApplyAck(HS)
H.addInbox(HS, { { seq = 2, workflow = "f", target = "Friend", steps = { { action = "notify", text = "for the friend" } } } })
H.wait(2000, 100)
check(H.hasToast(FC, "for the friend") and not H.hasToast(HC, "for the friend"), "the friend's job runs in the friend's game")

-- the host's F8 window: the address of the bridge and the friend's token, to send in private
HC.ui.TEXTS, HC.ui.BUTTONS, HC.ui.CLIPBOARD = {}, {}, nil
HC.E.Talky_Window.toggle()
H.tick(3)
win = HC.E.Talky_Window.instance
win.selectedStreamer = "Friend"
win:showPage("webhooks")
-- the list of the streamers comes from the server a moment later: the page is drawn again
H.tick(3)
for i = #HC.ui.BUTTONS, 1, -1 do
    local b = HC.ui.BUTTONS[i]
    if b.title == HC.E.Talky_T("Btn_CopyForStreamer") then b.onclick(b.target, b); break end
end
win:close()
local tokF = H.tokenOf(HS, "Friend")
check(HC.ui.CLIPBOARD == HC.E.Talky_T("Stream_WidgetUrl", "http://198.51.100.7:7420") .. "\n" .. HC.E.Talky_T("Stream_WidgetToken", tokF),
    "the host copies the address of the bridge (publicUrl of the bridge) and the friend's token")
local shownToken = false
for _, t in ipairs(HC.ui.TEXTS) do if string.find(t, tokF, 1, true) then shownToken = true end end
check(not shownToken, "the token stays masked on the host's screen")

-- a username Allow me cannot quote
local accQ = H.account('Bad"Name', { x = 900, y = 900 })
local QC = H.newClient("QC", accQ, HS, { fs = {}, host = true })
H.wait(1000, 100)
check(QC.E.Talky_Remote.allowMe() == false and #QC.commands == 0, "Allow me refuses a username with a quote")

H.tick(3)
H.hygiene(HS, "coop server")
H.hygiene(HC, "host's game")
H.hygiene(FC, "friend's game")
H.hygiene(QC, "quote")
