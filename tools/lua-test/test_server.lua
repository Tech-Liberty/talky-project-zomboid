-- Dedicated server with several clients. Each process is a Lua state of its own; the
-- streamers' games relay their bridge's jobs to the server, which runs them around the sender.
--   A "Streamer"   in Talky.AllowedPlayers (written "streamer"), the main streamer
--   B "Other"      no permission
--   M "Mod"        moderator role (AllowAdmins)
--   C "Late"       joins later

local JSON = H.JSON

local SANDBOX = { Talky = { AllowedPlayers = "streamer; someone,  other2", AllowAdmins = true, BannerAudience = 1 } }
local S = H.newServer("SRV", { sandbox = SANDBOX })
local SE, SW = S.E, S.world
local TV = SANDBOX.Talky

-- sandbox values are read again after 1 s (Talky_Config.readSandbox cache)
local function setSandbox(values)
    for k, v in pairs(values) do TV[k] = v end
    NOW = NOW + 1100
end

local seqs = {}
-- Appends a job to the client's inbox, like the bridge (after it dropped the acked ones).
local function send(P, steps, opts)
    opts = opts or {}
    seqs[P] = (seqs[P] or 0) + 1
    local j = { seq = seqs[P], steps = steps }
    for k, v in pairs(opts) do j[k] = v end
    H.bridgeApplyAck(P)
    H.addInbox(P, { j })
    return j.seq
end
local function ack(P) return P.fs["talky_ack.txt"] end
local function showAck(P) return (string.gsub(tostring(ack(P)), "\n", "\\n")) end
local function failures(P, s)
    local out = {}
    for _, e in ipairs(H.events(P, "action_failed")) do
        if e.data.seq == s then out[#out + 1] = e.data.action .. ":" .. e.data.code end
    end
    table.sort(out)
    return table.concat(out, ",")
end
local function zombiesNamed(name)
    local n = 0
    for _, z in ipairs(SW.zombies) do if not z.dead and z.md.Talky_name == name then n = n + 1 end end
    return n
end
local function within(z, acc, d)
    local dx, dy = z.x - acc.x, z.y - acc.y
    return dx * dx + dy * dy <= d * d
end

section("dedicated server: start")

check(SE.Talky_Server ~= nil and SE.Talky_ServerRunner ~= nil and SE.Talky_Tags ~= nil and SE.Talky_Actions ~= nil, "server modules loaded")
check(H.g(S, "Talky_Client") == nil and H.g(S, "Talky_Bridge") == nil and H.g(S, "Talky_Overlay") == nil and H.g(S, "Talky_Window") == nil, "no client module on the server")
check(H.logHas(S, "^%[Talky%] server ready %(Talky 0%.4%.0, protocol 1%)$"), "'[Talky] server ready (Talky 0.4.0, protocol 1)' in the server console")
check(SE.TalkyNet.mode() == "server", "mode: server")

local accA = H.account("Streamer", { x = 100, y = 100 })
local accB = H.account("Other", { x = 400, y = 400 })
local accM = H.account("Mod", { x = 700, y = 700, role = "moderator" })
local A = H.newClient("A", accA, S, { fs = {} })
local B = H.newClient("B", accB, S, { fs = {} })
local M = H.newClient("M", accM, S, { fs = {} })
check(H.g(A, "Talky_Server") == nil and H.g(A, "Talky_ServerRunner") == nil and H.g(A, "Talky_Tags") == nil and H.g(A, "Talky_Client") ~= nil,
    "client: the server files return at once on a client")
check(A.E.TalkyNet.mode() == "client", "mode: client")
H.tick(5)
check(H.net.nullPlayer >= 3 and A.E.Talky_Bridge.hello.state == "waiting", "the first hellos are lost while the server has no player for the connection")
check(#H.events(A, "game_started") == 0, "no game_started before the server answered")
H.wait(4000, 100)
check(A.E.Talky_Bridge.hello.state == "allowed", "A (in Talky.AllowedPlayers, other case, ';' separator): allowed after a hello again 3 s later")
check(B.E.Talky_Bridge.hello.state == "denied", "B (not listed, default role): refused")
check(M.E.Talky_Bridge.hello.state == "allowed", "M (moderator role, AllowAdmins): allowed")
local gs = H.events(A, "game_started")
check(#gs == 1 and gs[1].data.mode == "client" and gs[1].data.host == false and gs[1].data.server == "talkytest", "game_started after helloAck {mode client, host false, server}")
local hc = A.E.Talky_Bridge.hello.caps
check(hc and hc.maxZombiesPerAction == 30 and hc.maxZombiesPerJob == 60 and hc.maxSpawnDistance == 40 and hc.maxJobsPerMinute == 30
    and hc.allow.fire == false and hc.allow.helicopter == false and hc.allow.zombies == true, "helloAck carries the server limits (sandbox defaults)")
check(A.sent.tags == 1 and B.sent.tags == 1, "each client asks once for the names already given (late join)")

-- permission rule, case by case (server side)
local function allowed(role, name)
    local acc = H.account(name or "Nobody", { role = role })
    return SE.Talky_Server.isAllowed(H.player(acc, S))
end
check(allowed("admin") and allowed("moderator"), "AllowAdmins: admin and moderator roles (CreateHorde capability) allowed")
check(not allowed("gm") and not allowed("observer") and not allowed("user") and not allowed(false), "gm, observer, default role and no role refused")
check(allowed("user", "SOMEONE") and allowed("user", "Other2") and not allowed("user", "some"), "AllowedPlayers: case-insensitive, whole names, ',' ';' separators, entries trimmed")
setSandbox({ AllowAdmins = false })
check(not allowed("admin") and allowed("user", "streamer"), "AllowAdmins off: only the listed players")
setSandbox({ AllowAdmins = true })
do
-- a username may hold a space (never ',' nor ';'): splitting on spaces would let anyone
-- create the account "big" and pass
setSandbox({ AllowedPlayers = "streamer; someone,  other2, Big Boss" })
check(allowed("user", "Big Boss") and allowed("user", "big boss") and not allowed("user", "big") and not allowed("user", "boss"),
    "AllowedPlayers: a space is part of a name ('Big Boss' allowed, the accounts 'big' and 'boss' not)")
-- the game's account database folds A-Z only (SQLite LOWER): two names that differ by the case
-- of an accented letter are two accounts (decimal escapes: "\195\132" = A with umlaut)
local AE, ae, AEUP, KELVIN = "\195\132xel", "\195\164xel", "\195\132XEL", "\226\132\170evin"
setSandbox({ AllowedPlayers = "streamer, " .. AE .. ", Kevin" })
check(allowed("user", AE) and allowed("user", AEUP) and not allowed("user", ae), "AllowedPlayers: an accented capital is not folded (another account), A-Z are")
check(allowed("user", "kevin") and not allowed("user", KELVIN), "AllowedPlayers: the Kelvin sign is not the letter K")
check(SE.TalkyNet.nameKey(AE) ~= SE.TalkyNet.nameKey(ae) and SE.TalkyNet.nameKey("AXEL") == "axel" and SE.TalkyNet.userKey(A.localPlayer) == "streamer",
    "TalkyNet.nameKey folds A-Z only")
local pLow, pUp = H.player(H.account(ae), S), H.player(H.account(AE), S)
local realOnline = SE.getOnlinePlayers
SE.getOnlinePlayers = function() return H.list({ pLow, pUp }) end
local fUp, fLow, fCase = SE.TalkyNet.findPlayer(AE), SE.TalkyNet.findPlayer(ae), SE.TalkyNet.findPlayer(AEUP)
SE.getOnlinePlayers = realOnline
check(fUp == pUp and fLow == pLow and fCase == pUp, "findPlayer: two accounts that only differ by an accented capital are never mixed up")
setSandbox({ AllowedPlayers = "streamer; someone,  other2" })
end

---------------------------------------------------------------- one job, end to end

section("dedicated server: a job runs around its sender")

local s1 = send(A, {
    { action = "notify", text = "hello all", color = "#00ff00" },
    { action = "horde", name = "Raider", count = 999, sameName = true },
    { action = "heal" },
    { action = "stat", stat = "PANIC", op = "set", value = 50 },
    { action = "give_item", item = "Base.Apple", count = 500 },
    { action = "give_item", item = "Base.Bandage", count = 2, onGround = true },
    { action = "xp", perk = "Strength", amount = 99999 },
    { action = "weather", type = "storm", hours = 48, stage = 1 },
    { action = "say", text = "thanks" },
    { action = "halo", text = "+1" },
    { action = "emit", event = "custom_mp", data = { z = 2 } },
    { action = "fire" },
    { action = "helicopter" },
    { action = "emit", event = "test_workflow", data = { workflow = "x" } },
    { action = "sound", name = "ZombieSurprisedPlayer" },
    { action = "noise", radius = 500 },
    { action = "thunder" },
    { action = "time", hour = 22 },
}, { workflow = "raid" })
local perTick, last = 0, 0
for _ = 1, 30 do
    H.tick(1)
    local n = SW.alive()
    if n - last > perTick then perTick = n - last end
    last = n
end
check(ack(A) == "1", "acked after the server's jobAck")
check(SW.alive() == 30 and zombiesNamed("Raider") == 30, "horde capped to 30 (MaxZombiesPerAction), spawned in the server world")
check(perTick == 10, "at most 10 zombies created per tick (" .. perTick .. ")")
local near = true
for _, z in ipairs(SW.zombies) do if not within(z, accA, 40) or z.spottedBy ~= A.conn.serverPlayer then near = false end end
check(near, "every zombie within MaxSpawnDistance of the streamer, and after the streamer's server-side player")
check(H.count(A.E.Talky_Client.tags) == 30 and H.count(B.E.Talky_Client.tags) == 30, "the 30 names reached both clients")
check(H.hasToast(A, "hello all") and not H.hasToast(B, "hello all") and not H.hasToast(B, "[Streamer] hello all"), "banner shown to the streamer only (BannerAudience 1)")
check(#accA.healed == 1 and accA.healed[1] == "client", "heal runs on the streamer's client (client-owned health)")
check(accA.stats.PANIC == 50 and accA.statSide == "server" and SW.statSyncs[1] and SW.statSyncs[1].user == "Streamer" and SW.statSyncs[1].mask == 8192,
    "stat set on the server and synced with getBitMaskForStat")
check(accA.items[1] and accA.items[1].side == "server" and accA.items[1].n == 100 and SW.itemSyncs == 1, "give_item on the server, 100 at most, sent with sendAddItemsToContainer")
check(#SW.ground == 2 and SW.ground[1].t == "Base.Bandage", "onGround items through AddWorldInventoryItem (sent to the clients)")
check(SW.xp[1] and SW.xp[1].amount == 1000 and SW.xp[1].user == "Streamer" and SW.xp[1].perk == "Strength", "xp capped to 1000, given to the sender")
check(SW.weather[1] and SW.weather[1].transmitted and SW.weather[1].hours == 12 and SW.weatherStops >= 1, "storm: stopWeatherAndThunder, then transmitServerTriggerStorm, 12 h at most, raw stage ignored")
check(A.chat[1] == "thanks" and #accA.said == 0, "say goes through the multiplayer chat (processSayMessage)")
check(A.halos[1] and A.halos[1].text == "+1" and A.halos[1].side == "client", "halo shown by the streamer's client")
local cm = H.events(A, "custom_mp")
check(#cm == 1 and cm[1].data.z == 2, "emit step written by the client from its own copy of the job")
check(#H.events(A, "test_workflow") == 0, "an emit step never writes test_workflow")
check(failures(A, s1) == "fire:disabled,helicopter:disabled" and #SW.fires == 0 and #SW.heli == 0, "fire and helicopter off by default on a server (action_failed disabled)")
check(SW.serverSounds[1] == "ZombieSurprisedPlayer" and #accA.sounds == 0, "sound through playServerSound, heard by the nearby clients")
check(SW.sounds[1] and SW.sounds[1].r == 80, "noise radius capped to 80 (MaxNoiseRadius)")
check(#SW.thunder == 1 and SW.thunder[1].transmitted, "thunder through triggerThunderEvent (sent with the climate packet)")
check(SW.times[1] == 22, "time set on the server")
check(#H.events(A, "job_done") == 1 and H.events(A, "job_done")[1].data.workflow == "raid", "job_done for the streamer's bridge")
check(#H.events(B, "job_done") == 0 and #H.events(B, "custom_mp") == 0 and #H.events(B, "action_failed") == 0, "nothing for the other player's bridge")

---------------------------------------------------------------- names above zombies

section("dedicated server: name tags")

B.ui.DRAWN = {}
local bx, by = accB.x, accB.y
accB.x, accB.y = SW.zombies[1].x, SW.zombies[1].y
B.fire("OnPostUIDraw")
accB.x, accB.y = bx, by
local bDrawn = false
for _, t in ipairs(B.ui.DRAWN) do if t == "Raider" then bDrawn = true end end
check(bDrawn, "the other player's client draws the names (matched on online id and outfit)")

local zed = SW.zombies[1]
H.kill(S, zed, A.conn.serverPlayer, 2)
H.tick(2)
local kills = H.events(A, "zombie_killed")
check(#kills == 1 and kills[1].data.name == "Raider" and kills[1].data.byPlayer == true, "zombie_killed once (OnZombieDead fired twice), to the owner, byPlayer = true")
check(H.hasToast(A, "Raider is down... for good.") and not H.hasToast(B, "Raider is down... for good."), "death banner for the streamer only")
check(B.E.Talky_Client.tags[tostring(zed.id)] == nil and H.count(B.E.Talky_Client.tags) == 29, "untag reached the other client")
check(#H.events(B, "zombie_killed") == 0, "no zombie_killed on the other player's bridge (client-side OnZombieDead ignored)")
H.kill(S, SW.zombies[2], B.conn.serverPlayer)
H.tick(2)
kills = H.events(A, "zombie_killed")
check(#kills == 2 and kills[2].data.byPlayer == false, "killed by another player: byPlayer = false")

do
-- names cut in the middle of an emoji (two UTF-16 units in Kahlua): the lone first half would
-- reach the clients and the bridge as '?'
local EMOJI = "\240\159\152\128"
local cut39 = SE.TalkyNet.str(string.rep("a", 39) .. EMOJI .. "z", 40, "")
check(cut39 == string.rep("a", 39) and SE.TalkyNet.str(string.rep("a", 38) .. EMOJI .. "z", 40, "") == string.rep("a", 38) .. EMOJI,
    "TalkyNet.str never keeps half of an emoji; a whole one at the end is kept")
check(string.len(SE.Talky_Actions.clipText(string.rep("b", 199) .. EMOJI)) == 199, "a 200-unit text ending in half an emoji loses that half")
local zU = SW.newZombie(5000, 5000, 0, { health = 1 })
local zAcc = SW.newZombie(5001, 5000, 0, { health = 1 })
SE.Talky_Tags.tag(zU, string.rep("a", 39) .. EMOJI .. "z", nil, "Streamer")
SE.Talky_Tags.tag(zAcc, "Zo\195\169", nil, "Streamer")
H.tick(2)
local tU, tAcc = B.E.Talky_Client.tags[tostring(zU.id)], B.E.Talky_Client.tags[tostring(zAcc.id)]
check(tU and tU.name == string.rep("a", 39) and tAcc and tAcc.name == "Zo\195\169", "names reach the other clients without '?', accents kept")
H.kill(S, zU, nil)
H.kill(S, zAcc, nil)
H.tick(2)
kills = H.events(A, "zombie_killed")
check(#kills == 4 and kills[3].data.name == string.rep("a", 39) and kills[4].data.name == "Zo\195\169", "zombie_killed names written to the outbox without '?'")
end

-- a late joiner gets the names
local accC = H.account("Late", { x = 900, y = 900 })
local C = H.newClient("C", accC, S, { fs = {} })
H.wait(5000, 100)
check(H.count(C.E.Talky_Client.tags) == 28, "a late joiner receives the names (" .. H.count(C.E.Talky_Client.tags) .. ")")

-- recycled zombie: online id and modData reset, the sweep drops it
SW.recycle(SW.zombies[3], 77)
H.wait(2000, 100)
check(C.E.Talky_Client.tags[tostring(102)] == nil and H.count(C.E.Talky_Client.tags) == 27 and H.count(A.E.Talky_Client.tags) == 27,
    "a recycled zombie loses its name everywhere")
-- a dead zombie no one reported
SW.zombies[4].dead = true
H.wait(2000, 100)
check(H.count(A.E.Talky_Client.tags) == 26 and SE.Talky_Tags.count == 26, "a dead zombie is swept too")

---------------------------------------------------------------- refusals

section("dedicated server: refusals")

-- a refused player crafts a jobs message (modified client)
B.received = {}
NOW = NOW + 31000
B.E.TalkyNet.toServer("jobs", { v = 1, list = { { seq = 5, id = "5:1", steps = { { action = "horde" } } } } })
H.tick(2)
local aliveBefore = SW.alive()
check(B.received[1] == "jobAcks" and SW.alive() == aliveBefore, "jobs of a refused player are answered not_allowed and never run")
B.received = {}
B.E.TalkyNet.toServer("jobs", { v = 1, list = { { seq = 6, id = "6:1", steps = { { action = "horde" } } } } })
H.tick(2)
check(#B.received == 0, "a refused player is answered at most once per 30 s")
check(H.logCount(S, "other: jobs refused: not allowed") == 1, "and logged once")

-- strict numbers and types on the server (modified client)
SE.Talky_ServerRunner.cooldowns = {}
local timesBefore, zBefore = #SW.times, #SW.zombies
A.E.TalkyNet.toServer("jobs", { v = 1, list = { { seq = 50, id = "50:1", steps = {
    { action = "time", hour = 0 / 0 },
    { action = "spawn_zombie", count = 0 / 0, name = { "table" }, distance = math.huge, health = 0 / 0 },
    { action = "xp", perk = "Strength", amount = 0 / 0 },
    { action = "give_item", item = "Base.Apple", count = -math.huge },
    { action = "stat", stat = "PANIC", op = "set", value = 0 / 0 },
    { action = "noise", radius = 0 / 0, volume = math.huge },
} } } })
H.tick(5)
check(SW.times[timesBefore + 1] == 0, "NaN hour falls back to the default")
local zNew = SW.zombies[zBefore + 1]
check(#SW.zombies == zBefore + 1 and zNew.md.Talky_name == nil and zNew.health == 1 and within(zNew, accA, 12), "NaN count -> 1, NaN health -> 1, infinite distance -> default, a table name dropped")
check(SW.xp[#SW.xp].amount == 10 and accA.items[#accA.items].n == 1 and accA.stats.PANIC == 0 and SW.sounds[#SW.sounds].r == 60,
    "NaN and infinite amounts fall back to their defaults (xp 10, items 1, stat 0, radius 60)")
A.received = {}
local misuseBefore = #A.misuse
A.E.TalkyNet.toServer("jobs", { v = 1, list = {
    { seq = 2 ^ 60, id = "a:1", steps = {} },
    { seq = 0 / 0, id = "b:1", steps = {} },
    { seq = -4, steps = {} },
    { seq = 1.5, id = "c:1", steps = {} },
    { seq = 51, id = "51:1", steps = "nope" },
    { seq = 52, id = "52:1" },
    { id = "bad id\n", steps = {} },
    "junk",
    { seq = 53, id = "53:1", steps = { { action = "notify", text = "fine" } }, player = A.conn.serverPlayer },
} })
-- the game object in the last job was dropped by the network (recorded on the sender's side)
check(#A.misuse == misuseBefore + 1 and H.net.javaDropped >= 1, "a game object in the args never reaches the server (dropped by the network)")
A.misuse[#A.misuse] = nil
H.tick(3)
local nAcks = 0
for _, c in ipairs(A.received) do if c == "jobAcks" then nAcks = nAcks + 1 end end
check(nAcks == 1, "a batch of bad jobs gets one jobAcks message")

-- game objects the network DOES deliver (TableNetworkUtils sends IsoDirections, InventoryItem,
-- IsoDeadBody): the server gets a Java object (userdata) where it expects plain data
if __NET_COPY == "TableNetworkUtils" then
    local Dir = A.E.IsoDirections.N
    local seenTypes, acksSeen = {}, {}
    local realOnCommand = SE.Talky_Server.onCommand
    SE.Talky_Server.onCommand = function(command, player, args)
        if type(args) == "table" then seenTypes[#seenTypes + 1] = type(args.list) end
        return realOnCommand(command, player, args)
    end
    local realJobAcks = A.E.Talky_Client.handlers.jobAcks
    A.E.Talky_Client.handlers.jobAcks = function(a)
        for _, x in ipairs(type(a.list) == "table" and a.list or {}) do if x.seq then acksSeen[x.seq] = x end end
        return realJobAcks(a)
    end
    local misuseDir, errorsDir, logDir = #A.misuse, #S.errors, #S.log
    A.received = {}
    A.E.TalkyNet.toServer("jobs", { v = 1, list = Dir })
    H.tick(3)
    check(seenTypes[1] == "userdata" and #A.received == 0, "a direction as the job list (modified client): the server gets a userdata, answers nothing")
    A.E.TalkyNet.toServer("jobs", { v = 1, list = {
        { seq = 54, id = "54:1", steps = Dir },
        { seq = 55, id = "55:1", steps = { { action = "notify", text = Dir, color = Dir, seconds = Dir }, Dir } },
    } })
    H.tick(5)
    check(acksSeen[54] and acksSeen[54].reason == "invalid" and acksSeen[55] and acksSeen[55].ok == true and failures(A, 55) == "step:invalid",
        "steps = a direction: invalid; a direction as a step or a value: dropped, the job runs")
    local ud = H.netArgs(A, { d = Dir }).d
    local TN = SE.TalkyNet
    check(type(ud) == "userdata" and TN.num(ud, 7, 0, 10) == 7 and TN.str(ud, 10, "d") == "d" and TN.seq(ud) == nil and TN.color(ud, "c") == "c"
        and TN.bool(ud, false) == false and TN.copy({ x = ud, y = 1 }).x == nil and select(2, SE.Talky_Actions.sanitizeStep(ud, 1, SE.Talky_Config.caps())) == "invalid",
        "every parser of the server refuses a game object")
    local logOk = true
    for i = logDir + 1, #S.log do if string.find(S.log[i], "failed:", 1, true) or string.find(S.log[i], "error", 1, true) then logOk = false end end
    check(#S.errors == errorsDir and logOk, "no Lua error on the server")
    SE.Talky_Server.onCommand, A.E.Talky_Client.handlers.jobAcks = realOnCommand, realJobAcks
    for i = #A.misuse, misuseDir + 1, -1 do A.misuse[i] = nil end
end
-- unit view of the same answers
local function acceptOne(raw, v)
    return SE.Talky_Server.acceptJob(A.conn.serverPlayer, "streamer", raw, v or 1, NOW, SE.Talky_Config.caps())
end
local r1 = acceptOne({ seq = 2 ^ 60, id = "x:1", steps = {} })
local r2 = acceptOne({ seq = 0 / 0, id = "y:1", steps = {} })
local r3 = acceptOne({ seq = -4, steps = {} })
local r4 = acceptOne({ seq = 70, id = "70:1", steps = {} }, 2)
local r5 = acceptOne({ seq = 71, id = "71:1", steps = "x" })
local r6 = acceptOne({ seq = 72, id = "72:1", ttl_ms = 0, steps = { { action = "notify" } } })
local r7 = acceptOne({ seq = 73, id = "73:1", age_ms = 900000, steps = { { action = "notify" } } })
local r8 = acceptOne({ seq = 74, id = "74:1", steps = { { action = "fly_to_moon" } } })
check(r1.ok == false and r1.reason == "invalid" and r1.seq == nil and r1.id == "x:1", "seq above 2^53: invalid, answered by id")
check(r2.ok == false and r2.reason == "invalid" and r2.id == "y:1", "NaN seq: invalid (never used as a table key)")
check(r3 == nil, "negative seq without id: nothing to answer")
check(r4.reason == "invalid" and r5.reason == "invalid", "other protocol version, steps not a table: invalid")
check(r6.reason == "expired" and r7.reason == "expired", "ttl_ms 0 or age_ms 900000: expired")
check(r8.reason == "unknown_action", "only unknown actions: unknown_action")
H.tick(5)
check(H.hasToast(A, "fine"), "the good job of the batch ran")

-- disabled and unknown steps
local sDis = send(A, { { action = "fire" } }, { workflow = "burn" })
H.wait(2000, 100)
local rj = H.events(A, "job_rejected")
check(ack(A) == tostring(sDis) and #rj == 1 and rj[1].data.reason == "disabled" and rj[1].data.workflow == "burn" and rj[1].data.seq == sDis,
    "a job with only turned-off steps is refused for good: acked + job_rejected")
check(H.hasToast(A, A.E.Talky_T("Toast_JobRejected", sDis, A.E.Talky_T("Reason_disabled"))), "refusal toast with the translated reason")
check(A.E.Talky_Bridge.serverStatus().lastReject.seq == sDis, "the F8 Status page knows the last refused job")
local sUnk = send(A, { { action = "fly_to_moon" }, { action = "notify", text = "still runs" } })
H.wait(2000, 100)
check(failures(A, sUnk) == "fly_to_moon:unknown_action" and H.hasToast(A, "still runs") and ack(A) == tostring(sUnk), "an unknown step is skipped and reported, the rest of the job runs")
do
local sBadName = send(A, { { action = "give-item" }, "junk", { action = "notify", text = "after a bad name" } })
H.wait(2000, 100)
check(failures(A, sBadName) == "step:invalid" and H.hasToast(A, "after a bad name"),
    "unreadable steps (a name with '-', not a table): reported once as action 'step', code invalid, the rest runs (" .. failures(A, sBadName) .. ")")
end

-- a line the bridge wrote without steps: acked, never sent
local sDead = seqs[A] + 1
seqs[A] = sDead
H.bridgeApplyAck(A)
A.fs["talky_inbox.jsonl"] = A.fs["talky_inbox.jsonl"] .. JSON.encode({ seq = sDead, workflow = "x", createdAt = NOW, expiresAt = NOW + 60000 }) .. "\n"
H.wait(2000, 100)
check(ack(A) == tostring(sDead), "an inbox line without steps is acked and skipped")

---------------------------------------------------------------- lost answers, duplicates, watermark

section("dedicated server: acks")

H.net.dropDown = function(m) return m.conn.client == A and m.command == "jobAcks" end
local sDup = send(A, { { action = "noise", radius = 5 } }, { workflow = "dup" })
local soundsBefore = #SW.sounds
H.wait(3000, 100)
check(ack(A) == tostring(sDup - 1), "answer lost: not acked")
check(#SW.sounds == soundsBefore + 1, "the job ran once on the server")
H.wait(16000, 100)
check(A.E.Talky_Bridge.noAnswer == 1, "the F8 Status page counts the job without answer")
H.net.dropDown = nil
H.wait(16000, 100)
check(ack(A) == tostring(sDup) and #SW.sounds == soundsBefore + 1, "sent again after 30 s, answered duplicate, acked, not run twice")
check(#H.events(A, "job_rejected") == 1, "duplicate is not shown as a refusal")
check(A.E.Talky_Bridge.noAnswer == 0 or (function() H.wait(1000) return A.E.Talky_Bridge.noAnswer == 0 end)(), "no job without answer left")

-- answers out of order
local s3 = send(A, { { action = "notify", text = "three" } })
H.net.hold = function(m) return m.conn.client == A and m.command == "jobAcks" and m.args.list[1].seq == s3 end
H.wait(2000, 100)
H.net.hold = nil
local s4 = send(A, { { action = "notify", text = "four" } })
H.wait(2000, 100)
local expect = tostring(s3 - 1) .. " " .. tostring(s4) .. "\n"
check(ack(A) == expect, "answer for " .. s4 .. " before " .. s3 .. ": ack '" .. tostring(s3 - 1) .. " " .. s4 .. "' (" .. showAck(A) .. ")")
local mark, extra = H.parseAck(ack(A))
check(mark == s3 - 1 and extra[1] == s4 and #extra == 1, "the 0.4.0 bridge reads S and the extra seq")
check(tonumber(string.match(ack(A), "^%d+")) == s3 - 1, "a 0.3.0 bridge (parseInt) reads S only and keeps job " .. s3)
H.releaseHeld()
check(ack(A) == tostring(s4), "then the answer for " .. s3 .. ": ack '" .. s4 .. "'")

-- a job lost on the way to the server, the next one accepted: the lost one is not acked
local s6 = send(A, { { action = "notify", text = "six" } }, { workflow = "w6" })
H.net.dropUp = function(m) return m.conn.client == A and m.command == "jobs" end
H.wait(1500, 100)
H.net.dropUp = nil
local s7 = send(A, { { action = "notify", text = "seven" } }, { workflow = "w7" })
H.wait(2500, 100)
check(ack(A) == tostring(s6 - 1) .. " " .. tostring(s7) .. "\n", "job " .. s6 .. " lost, job " .. s7 .. " accepted: ack '" .. tostring(s6 - 1) .. " " .. s7 .. "' (" .. showAck(A) .. ")")
H.bridgeApplyAck(A)
local inbox = H.inboxSeqs(A)
check(#inbox == 1 and inbox[1] == s6 and not H.hasToast(A, "six"), "job " .. s6 .. " is still in the inbox and has not run")
H.wait(31000, 100)
-- the bridge already dropped job s7 (an extra seq of the ack file): S is now s6
check(ack(A) == tostring(s6) and H.hasToast(A, "six"), "sent again after 30 s and run; the ack file says '" .. s6 .. "' (" .. showAck(A) .. ")")

-- an answer the client does not know: kept, sent again 10 s later
local ackBefore = ack(A)
local sW = send(A, { { action = "notify", text = "weird" } })
H.net.dropDown = function(m) return m.conn.client == A and m.command == "jobAcks" end
H.wait(1500, 100)
H.net.dropDown = nil
local p
for _, q in pairs(A.E.Talky_Bridge.pending) do if q.seq == sW then p = q end end
A.E.Talky_Client.dispatch("jobAcks", { list = { { seq = sW, id = p and p.id, ok = false, reason = "strange_reason" } } })
check(p ~= nil and A.E.Talky_Bridge.pending[p.id] ~= nil and p.retryAt == NOW + 10000 and ack(A) == ackBefore,
    "an unknown reason is treated as 'try again in 10 s', not acked")
H.wait(12000, 100)
check(ack(A) == tostring(sW), "then sent again: duplicate, acked")

---------------------------------------------------------------- queue limits

section("dedicated server: queue and rate limits")

-- busy: the server queue is full
setSandbox({ MaxQueuedJobs = 1, MaxActiveJobs = 1 })
local first = seqs[A] + 1
for i = 1, 4 do send(A, { { action = "wait", seconds = 20 }, { action = "notify", text = "q" .. i } }) end
H.wait(1500, 100)
check(ack(A) == tostring(first), "one job taken, the others busy and not acked (" .. showAck(A) .. ")")
H.wait(120000, 500)
check(ack(A) == tostring(first + 3) and H.hasToast(A, "q4"), "busy jobs sent again later, accepted and run (" .. showAck(A) .. ")")
do
-- a refused step of a job answered busy (sent again every 5 s): reported once, when accepted
send(A, { { action = "wait", seconds = 20 }, { action = "notify", text = "b1" } })
send(A, { { action = "wait", seconds = 20 }, { action = "notify", text = "b2" } })
local sBusy = send(A, { { action = "notify", text = "b3" }, { action = "helicopter" } })
H.wait(8000, 500)
local busyEarly = failures(A, sBusy)
H.wait(62000, 500)
check(busyEarly == "" and failures(A, sBusy) == "helicopter:disabled" and H.hasToast(A, "b3"),
    "a turned-off step of a busy job: one action_failed once the job is accepted, not one per try (" .. failures(A, sBusy) .. ")")
end
setSandbox({ MaxQueuedJobs = 10, MaxActiveJobs = 4 })

-- rate limited: 30 jobs a minute per player
H.wait(61000)
setSandbox({ MaxJobsPerMinute = 3 })
first = seqs[A] + 1
for i = 1, 5 do send(A, { { action = "notify", text = "r" .. i } }) end
H.wait(1500, 100)
local pending = A.E.Talky_Bridge.pending
local retry
for _, q in pairs(pending) do if q.seq == first + 3 then retry = q.retryAt - NOW end end
check(ack(A) == tostring(first + 2) and retry and retry > 50000 and retry <= 60100, "4th job of the minute: rate_limited, retried when the minute ends (" .. tostring(retry) .. " ms)")
H.wait(62000, 500)
check(ack(A) == tostring(first + 4) and H.hasToast(A, "r5"), "then accepted")
do
-- the same for a job answered rate_limited
H.wait(61000)
setSandbox({ MaxJobsPerMinute = 1 })
send(A, { { action = "notify", text = "rl1" } })
local sRl = send(A, { { action = "notify", text = "rl2" }, { action = "helicopter" } })
H.wait(1500, 100)
local rlEarly = failures(A, sRl)
H.wait(65000, 500)
check(rlEarly == "" and failures(A, sRl) == "helicopter:disabled" and H.hasToast(A, "rl2"),
    "a turned-off step of a rate_limited job: reported once, when the job is accepted (" .. failures(A, sRl) .. ")")
-- one "jobs" message of 10 jobs x 100 unknown steps: 20 action_failed per job at most, and
-- the refused jobs count in the per-minute window
H.wait(61000)
setSandbox({ MaxJobsPerMinute = 10 })
A.received = {}
local flood = {}
for j = 1, 10 do
    local st = {}
    for k = 1, 100 do st[k] = { action = "u" .. k } end
    flood[j] = { seq = 700 + j, id = (700 + j) .. ":1", steps = st }
end
A.E.TalkyNet.toServer("jobs", { v = 1, list = flood })
H.tick(2)
local floodEmits = 0
for _, c in ipairs(A.received) do if c == "emit" then floodEmits = floodEmits + 1 end end
local afterFlood = SE.Talky_Server.acceptJob(A.conn.serverPlayer, "streamer", { seq = 720, id = "720:1", steps = { { action = "notify" } } }, 1, NOW, SE.Talky_Config.caps())
check(floodEmits == 200 and afterFlood.reason == "rate_limited",
    "10 jobs x 100 unknown steps: 200 server messages, not 1000; refused jobs use up the per-minute window (" .. floodEmits .. ")")
check(H.logCount(A, "game event%(s%) dropped: more than 60 a minute from the server") == 1, "the client says once that it dropped events over 60 a minute")
setSandbox({ MaxJobsPerMinute = 30 })
H.wait(61000)
end

-- token bucket: 5 commands a second, 10 at once
A.received = {}
for i = 1, 30 do A.E.sendClientCommand(A.localPlayer, "Talky", "jobs", { v = 99, list = { { seq = 900 + i, id = (900 + i) .. ":1", steps = {} } } }) end
H.tick(1)
H.tick(1)
local n = 0
for _, c in ipairs(A.received) do if c == "jobAcks" then n = n + 1 end end
check(n == 10, "30 commands in one tick: 10 handled (burst), the rest dropped silently (" .. n .. ")")
local logsBefore = #S.log
A.received = {}
A.E.sendClientCommand(A.localPlayer, "Talky", "selfdestruct", { now = true })
A.E.sendClientCommand(A.localPlayer, "Other", "jobs", { v = 1, list = { { seq = 999, id = "999:1", steps = { { action = "notify" } } } } })
H.wait(1000, 100)
check(#A.received == 0 and #S.log == logsBefore, "unknown command or other module: no answer, no log")

---------------------------------------------------------------- caps and budgets

section("dedicated server: caps and budgets")

local R = SE.Talky_ServerRunner
local function fresh()
    R.windows, R.cooldowns, R.broadcasts = {}, {}, {}
    H.wait(1000)
end

-- zombies: 60 per job
fresh()
local zb = SW.alive()
local sJ = send(A, { { action = "horde", count = 30 }, { action = "horde", count = 30 }, { action = "horde", count = 30 } })
H.wait(3000, 100)
check(SW.alive() - zb == 60 and failures(A, sJ) == "horde:budget", "60 zombies per job (MaxZombiesPerJob), the third horde: budget")
-- 150 per player per 10 minutes
send(A, { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
send(A, { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
H.wait(4000, 100)
check(SW.alive() - zb == 150, "150 zombies per player per 10 minutes (" .. (SW.alive() - zb) .. ")")
H.wait(601000, 5000)
local sAfter = send(A, { { action = "spawn_zombie", count = 5 } })
H.wait(2000, 100)
check(SW.alive() - zb == 155, "the budget comes back after 10 minutes")
-- server-wide budget, shared by two streamers
fresh()
setSandbox({ MaxZombiesPer10MinServer = 100 })
zb = SW.alive()
send(A, { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
local sM = send(M, { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
local maxTick, prev = 0, SW.alive()
for _ = 1, 40 do
    H.tick(1)
    if SW.alive() - prev > maxTick then maxTick = SW.alive() - prev end
    prev = SW.alive()
end
check(SW.alive() - zb == 100, "server-wide budget shared by every streamer (MaxZombiesPer10MinServer = 100: " .. (SW.alive() - zb) .. ")")
check(maxTick <= 10, "10 zombies per tick for the whole server, two streamers at once (" .. maxTick .. ")")
local mz = 0
for _, z in ipairs(SW.zombies) do if not z.dead and z.spottedBy == M.conn.serverPlayer then mz = mz + 1 end end
check(mz > 0 and mz < 60, "the moderator's zombies spawned around the moderator (" .. mz .. ")")
setSandbox({ MaxZombiesPer10MinServer = 400 })

-- items, vehicles, xp
fresh()
local itemsBefore = #accA.items
local sI = send(A, { { action = "give_item", item = "Base.Apple", count = 100 }, { action = "give_item", item = "Base.Apple", count = 100 },
    { action = "give_item", item = "Base.Apple", count = 100 }, { action = "give_item", item = "Base.Apple", count = 100 } })
H.wait(2000, 100)
check(#accA.items == itemsBefore + 3 and failures(A, sI) == "give_item:budget", "300 items per 10 minutes, then budget")
local vBefore = #SW.vehicles
local sV = send(A, { { action = "vehicle" }, { action = "vehicle", script = "Base.PickUpTruck" }, { action = "vehicle" } })
H.wait(2000, 100)
check(#SW.vehicles == vBefore + 2 and failures(A, sV) == "vehicle:budget", "2 vehicles per 10 minutes, then budget")
local xpBefore = #SW.xp
local sX = send(A, { { action = "xp", perk = "Strength", amount = 1000 }, { action = "xp", perk = "Fitness", amount = 1000 },
    { action = "xp", perk = "Strength", amount = 1000 }, { action = "xp", perk = "Strength", amount = 1000 },
    { action = "xp", perk = "Strength", amount = 1000 }, { action = "xp", perk = "Strength", amount = 1000 } })
H.wait(2000, 100)
check(#SW.xp == xpBefore + 5 and failures(A, sX) == "xp:budget", "5000 XP per 10 minutes, then budget")
do
-- whole XP amounts on a server; budget windows stay small whatever the amounts
fresh()
local sXf = send(A, { { action = "xp", perk = "Strength", amount = "0.0001" }, { action = "xp", perk = "Strength", amount = 0.5 },
    { action = "xp", perk = "Strength", amount = 1.9 } })
H.wait(2000, 100)
check(failures(A, sXf) == "xp:invalid,xp:invalid" and SW.xp[#SW.xp].amount == 1, "server: XP below 1 is invalid, 1.9 gives 1 (whole amounts)")
for _ = 1, 5 do
    local st = {}
    for k = 1, 10 do st[k] = { action = "xp", perk = "Fitness", amount = 1 } end
    send(A, st)
    H.wait(15000, 1000)
end
local wx, wsum = R.windows["x:streamer"] or {}, 0
for _, n in pairs(wx) do wsum = wsum + n end
check(H.count(wx) >= 2 and H.count(wx) <= 60 and wsum == 51, "a 10-minute budget is kept in 10-second buckets (" .. H.count(wx) .. " keys, " .. wsum .. " XP)")
-- noise and sound: 60 per streamer per 10 minutes
fresh()
local snd = {}
for i = 1, 70 do snd[i] = { action = (i % 2 == 0) and "sound" or "noise", radius = 5 } end
local sn0, ss0 = #SW.sounds, #SW.serverSounds
local sSnd = send(A, snd)
H.wait(2000, 100)
local nFail = 0
for _, e in ipairs(H.events(A, "action_failed")) do if e.data.seq == sSnd and e.data.code == "budget" then nFail = nFail + 1 end end
check((#SW.sounds - sn0) + (#SW.serverSounds - ss0) == 60 and nFail == 10, "60 noise and sound steps per streamer per 10 minutes, then budget")
-- a job of failing steps cannot flood the server console
H.wait(61000)
local logNope = #S.log
local nope = {}
for k = 1, 20 do nope[k] = { action = "stat", stat = "NOPE" } end
local sNope = send(A, nope)
H.wait(2000, 100)
local nopeLines, nopeEvents = 0, 0
for i = logNope + 1, #S.log do if string.find(S.log[i], "stat failed (not_found)", 1, true) then nopeLines = nopeLines + 1 end end
for _, e in ipairs(H.events(A, "action_failed")) do if e.data.seq == sNope then nopeEvents = nopeEvents + 1 end end
check(nopeLines == 1 and nopeEvents == 20, "20 failing steps: one console line a minute for that reason, every action_failed still sent (" .. nopeLines .. ")")
end

-- what the server accepts
fresh()
setSandbox({ ItemDenylist = "Base.Katana, Base.Axe" })
local sVal = send(A, {
    { action = "give_item", item = "Base.HiddenThing" }, { action = "give_item", item = "Base.OldThing" },
    { action = "give_item", item = "Apple" }, { action = "give_item", item = "base.katana" }, { action = "give_item", item = "Base.Axe" },
    { action = "xp", perk = "Passiv", amount = 10 }, { action = "xp", perk = "None", amount = 10 },
    { action = "vehicle", script = "Base.Tank" }, { action = "stat", stat = "GODMODE", value = 1 },
    { action = "weather", type = "acid_rain" },
})
H.wait(2000, 100)
check(failures(A, sVal) == "give_item:not_found,give_item:not_found,give_item:not_found,give_item:not_found,give_item:not_found,"
    .. "stat:not_found,vehicle:not_found,weather:not_found,xp:not_found,xp:not_found",
    "server refuses hidden, obsolete, short and denylisted items, skill categories, unknown vehicles, stats and weathers (" .. failures(A, sVal) .. ")")
setSandbox({ ItemDenylist = "" })
accA.z = 1
local sUp = send(A, { { action = "vehicle" } })
H.wait(2000, 100)
accA.z = 0
check(failures(A, sUp) == "vehicle:no_square", "no vehicle above the ground floor")

-- steps per job and total wait
fresh()
local steps = {}
for i = 1, 150 do steps[i] = { action = "halo", text = "h" .. i } end
local nBefore = #A.halos
send(A, steps)
H.wait(3000, 100)
check(#A.halos == nBefore + 100 and A.halos[#A.halos].text == "h100" and H.logHas(A, "50 step%(s%) dropped by the server"),
    "150 steps: the first 100 run (MaxStepsPerJob, cut by the client already), the client logs the 50 dropped")

do
-- big jobs: cut to the server's limit and sent in messages that fit the game's packet buffer
-- (1,000,000 bytes that never grow: an overflow throws out of sendClientCommand)
fresh()
setSandbox({ MaxStepsPerJob = 500, MaxQueuedJobs = 20 })
local hcaps = A.E.Talky_Bridge.hello.caps
hcaps.maxStepsPerJob = 500
local sentJobs, logBig = A.sent.jobs or 0, #A.log
local firstBig = seqs[A] + 1
for i = 1, 10 do
    local txt = (i % 2 == 0) and string.rep("\195\169", 200) or string.rep("y", 200)
    local st = {}
    for k = 1, 500 do st[k] = { action = "wait", seconds = 0, text = txt } end
    send(A, st)
end
for _ = 1, 15 do
    H.wait(1000, 100)
    H.bridgeApplyAck(A)
end
local bigErr = false
for i = logBig + 1, #A.log do
    if string.find(A.log[i], "poll error", 1, true) or string.find(A.log[i], "cannot send", 1, true) then bigErr = true end
end
check(ack(A) == tostring(firstBig + 9) and not bigErr and (A.sent.jobs or 0) - sentJobs >= 10,
    "10 jobs x 500 steps of 200 characters: all accepted, one by one, no send error (" .. ((A.sent.jobs or 0) - sentJobs) .. " messages)")
-- TableNetworkUtils writes this table in 51 bytes: type 1 + count 4, then per pair a type byte
-- each side, strings with a 2-byte length and UTF-8 (2 bytes per accented letter), double 8
local estimate = A.E.Talky_Bridge.netSize({ s = string.rep("\195\169", 10), n = 1, b = true })
check(estimate >= 51 and estimate <= 3 * 51, "the size estimate is above what the game writes, by 3 times at most (" .. estimate .. " for 51 bytes)")
check(A.E.Talky_Bridge.netSize({ s = string.rep("x", 11000) }) > 900000 and A.E.Talky_Bridge.netSize({ s = string.rep("x", 10900) }) < 40000,
    "a string that may pass 32,767 bytes (length written as a signed short) makes a job too large to send")
local sHuge = send(A, { { action = "notify", text = string.rep("x", 310000) } })
local sAfterHuge = send(A, { { action = "notify", text = "after huge" } })
H.wait(3000, 100)
local rjHuge
for _, e in ipairs(H.events(A, "job_rejected")) do if e.data.seq == sHuge then rjHuge = e end end
check(rjHuge and rjHuge.data.reason == "too_large" and H.hasToast(A, "after huge") and ack(A) == tostring(sAfterHuge)
    and H.hasToast(A, A.E.Talky_T("Toast_JobTooLarge", sHuge)), "a job too large for one message: never sent, refused for good, the next job goes on")
local stCut = {}
for k = 1, 499 do stCut[k] = { action = "wait", seconds = 0 } end
stCut[500] = { action = "emit", event = "cut_kept" }
stCut[501] = { action = "emit", event = "cut_away" }
send(A, stCut)
H.wait(3000, 100)
check(#H.events(A, "cut_kept") == 1 and #H.events(A, "cut_away") == 0 and H.logHas(A, ": 1 step%(s%) dropped by the server"),
    "the last step kept by the cut is an emit step: written from the local copy (same index)")
-- the send itself fails (the estimate missed): one job per message, then the job alone is dropped
local realToServer = A.E.TalkyNet.toServer
A.E.TalkyNet.toServer = function(command, args)
    if command == "jobs" then error("java.nio.BufferOverflowException") end
    return realToServer(command, args)
end
local sBo1 = send(A, { { action = "notify", text = "bo1" } })
local sBo2 = send(A, { { action = "notify", text = "bo2" } })
H.wait(1100, 100)
local singleMode = A.E.Talky_Bridge.singleUntil ~= nil
H.wait(3000, 100)
A.E.TalkyNet.toServer = realToServer
local rjBo = {}
for _, e in ipairs(H.events(A, "job_rejected")) do if e.data.reason == "too_large" then rjBo[e.data.seq] = true end end
check(singleMode and rjBo[sBo1] and rjBo[sBo2] and H.logCount(A, "cannot send") == 1 and ack(A) == tostring(sBo2),
    "a send that throws: one job per message next, a job that still fails alone is refused; one console line")
setSandbox({ MaxStepsPerJob = 100, MaxQueuedJobs = 10 })
hcaps.maxStepsPerJob = 100
end
local sLong = send(A, { { action = "wait", seconds = 600 }, { action = "wait", seconds = 600 }, { action = "wait", seconds = 600 }, { action = "notify", text = "late" } })
H.wait(880000, 5000)
check(not H.hasToast(A, "late"), "three 600 s waits: still waiting after 880 s")
H.wait(60000, 1000)
check(H.hasToast(A, "late"), "the waits of one job end after 900 s in total (not 1800 s)")

-- server-wide cooldowns
fresh()
local wBefore, tBefore, thBefore = #SW.weather, #SW.times, #SW.thunder
local sCd = send(A, { { action = "weather", type = "blizzard", hours = 2 }, { action = "time", hour = 3 }, { action = "thunder" }, { action = "thunder" } })
local sCdM = send(M, { { action = "weather", type = "storm" }, { action = "time", hour = 5 } })
H.wait(3000, 100)
check(#SW.weather == wBefore + 1 and SW.weather[#SW.weather].stage == 7 and not SW.weather[#SW.weather].transmitted,
    "blizzard: stopWeatherAndThunder then triggerCustomWeatherStage")
check(#SW.times == tBefore + 1 and #SW.thunder == thBefore + 1 and failures(A, sCd) == "thunder:cooldown",
    "time once, thunder once in 30 s")
check(failures(M, sCdM) == "time:cooldown,weather:cooldown", "cooldowns are server-wide: the other streamer waits too")
H.wait(31 * 60000, 10000)
local sCd2 = send(M, { { action = "weather", type = "storm" }, { action = "time", hour = 5 } })
H.wait(2000, 100)
check(failures(M, sCd2) == "" and #SW.times == tBefore + 2, "after the cooldowns, weather and time work again")

-- helicopter and fire, once a server allows them
fresh()
setSandbox({ AllowHelicopter = true, AllowFire = true })
local sH = send(A, { { action = "helicopter" } })
H.wait(2000, 100)
check(failures(A, sH) == "helicopter:helicopter_random_target" and #SW.heli == 0, "several players online: the helicopter is refused (it would pick a random player)")
setSandbox({ HelicopterAnyTarget = true })
local sH2 = send(A, { { action = "helicopter" }, { action = "helicopter" } })
H.wait(2000, 100)
check(#SW.heli == 1 and failures(A, sH2) == "helicopter:cooldown", "HelicopterAnyTarget: testHelicopter runs, then a 60 min cooldown")
local fBefore = #SW.fires
local zf = #SW.zombies
local sF = send(A, { { action = "fire" }, { action = "spawn_zombie", onFire = true } })
H.wait(2000, 100)
check(#SW.fires == fBefore + 1 and SW.zombies[zf + 1] and SW.zombies[zf + 1].onFire == true, "AllowFire: fire and burning zombies")
do
-- fires: 10 per streamer and 20 on the whole server per 10 minutes
fresh()
local twelve = {}
for i = 1, 12 do twelve[i] = { action = "fire" } end
local f0 = #SW.fires
local sFa = send(A, twelve)
H.wait(2000, 100)
check(#SW.fires - f0 == 10 and failures(A, sFa) == "fire:budget,fire:budget", "10 fires per streamer per 10 minutes, then budget")
local sFm = send(M, twelve)
H.wait(2000, 100)
R.windows["f:streamer"] = nil
local sFs = send(A, { { action = "fire" } })
H.wait(2000, 100)
check(#SW.fires - f0 == 20 and failures(M, sFm) == "fire:budget,fire:budget" and failures(A, sFs) == "fire:budget",
    "20 fires per 10 minutes on the whole server")
end
setSandbox({ AllowHelicopter = false, AllowFire = false, HelicopterAnyTarget = false })
zf = #SW.zombies
send(A, { { action = "spawn_zombie", onFire = true } })
H.wait(2000, 100)
check(SW.zombies[zf + 1] and SW.zombies[zf + 1].onFire == false, "fire turned off: zombies are not set on fire either")

-- other players nearby, safehouses
fresh()
accB.x, accB.y = accA.x + 1, accA.y
local zp = #SW.zombies
local sP = send(A, { { action = "spawn_zombie", name = "Near", distance = 12 }, { action = "vehicle" } })
H.wait(2000, 100)
check(#SW.zombies == zp and failures(A, sP) == "spawn_zombie:no_square,vehicle:no_square", "no spawn nor vehicle next to another player (ProtectRadius)")
setSandbox({ ProtectRadius = 0 })
local sP2 = send(A, { { action = "spawn_zombie", name = "Near", distance = 12 } })
H.wait(2000, 100)
check(#SW.zombies == zp + 1, "ProtectRadius 0: allowed")
setSandbox({ ProtectRadius = 15 })
accB.x, accB.y = 400, 400
SW.addSafehouse({ x1 = 50, y1 = 50, x2 = 150, y2 = 150, members = { other = true } })
zp = #SW.zombies
local sSh = send(A, { { action = "spawn_zombie", name = "Inside", distance = 12 } })
H.wait(2000, 100)
check(#SW.zombies == zp and failures(A, sSh) == "spawn_zombie:no_square", "no spawn inside another player's safehouse")
SW.safehouses[1].members.streamer = true
send(A, { { action = "spawn_zombie", name = "Inside", distance = 12 } })
H.wait(2000, 100)
check(#SW.zombies == zp + 1, "allowed in a safehouse the streamer belongs to")
SW.safehouses = {}

-- category toggles
setSandbox({ AllowZombies = false, AllowXp = false, AllowItems = false, AllowVehicles = false, AllowPlayerEffects = false,
             AllowWeather = false, AllowTime = false, AllowSounds = false })
local sOff = send(A, { { action = "spawn_zombie" }, { action = "horde" }, { action = "xp", perk = "Strength" }, { action = "give_item" },
    { action = "vehicle" }, { action = "heal" }, { action = "stat", stat = "PANIC" }, { action = "weather" }, { action = "thunder" },
    { action = "time" }, { action = "noise" }, { action = "sound" }, { action = "notify", text = "only me" } })
H.wait(2000, 100)
check(failures(A, sOff) == "give_item:disabled,heal:disabled,horde:disabled,noise:disabled,sound:disabled,spawn_zombie:disabled,stat:disabled,"
    .. "thunder:disabled,time:disabled,vehicle:disabled,weather:disabled,xp:disabled" and H.hasToast(A, "only me"),
    "every category can be turned off; banners still work")
setSandbox({ AllowZombies = true, AllowXp = true, AllowItems = true, AllowVehicles = true, AllowPlayerEffects = true,
             AllowWeather = true, AllowTime = true, AllowSounds = true })

do
-- the game creates no zombie (zombies turned off in the world: addZombiesInOutfit returns an
-- empty list): reported, and the zombies reserved go back to the budgets
fresh()
SW.zombiesDisabled = true
local zNone = #SW.zombies
local sNoZ = send(A, { { action = "spawn_zombie", count = 5 }, { action = "horde", count = 20 } })
H.wait(3000, 100)
SW.zombiesDisabled = false
local zsum = 0
for _, n in pairs(R.windows["z:streamer"] or {}) do zsum = zsum + n end
check(failures(A, sNoZ) == "horde:refused,spawn_zombie:refused" and #SW.zombies == zNone and zsum == 0,
    "a spawn that creates no zombie: action_failed refused, its budget given back (" .. failures(A, sNoZ) .. ", " .. zsum .. ")")

-- rules changed after a job was accepted: they apply to it too
fresh()
local zc = SW.alive()
local sCat = send(A, { { action = "spawn_zombie", count = 1 }, { action = "wait", seconds = 5 }, { action = "spawn_zombie", count = 1 } })
H.wait(2000, 100)
local catFirst = SW.alive() - zc
setSandbox({ AllowZombies = false })
H.wait(6000, 100)
-- (seq 74 is also the one of a hand-made job above: only this job's spawn steps count)
local catFails = {}
for _, e in ipairs(H.events(A, "action_failed")) do
    if e.data.seq == sCat and e.data.action == "spawn_zombie" then catFails[#catFails + 1] = e.data.code end
end
check(catFirst == 1 and SW.alive() - zc == 1 and table.concat(catFails, ",") == "disabled",
    "zombies turned off while a job runs: its next spawn step is refused (disabled) (" .. table.concat(catFails, ",") .. ")")
setSandbox({ AllowZombies = true })
local zh = SW.alive()
local sHo = send(A, { { action = "horde", count = 30 } })
local hordeStarted = false
for _ = 1, 40 do
    H.tick(1)
    if SW.alive() > zh then hordeStarted = true; break end
end
setSandbox({ AllowZombies = false })
H.tick(3)
local hordeMade = SW.alive() - zh
check(hordeStarted and hordeMade > 0 and hordeMade < 30 and failures(A, sHo) == "horde:disabled",
    "zombies turned off during a horde: the rest of it is not created (" .. hordeMade .. " of 30)")
setSandbox({ AllowZombies = true })
local sRev = send(A, { { action = "wait", seconds = 5 }, { action = "notify", text = "revoked" } }, { workflow = "rev" })
H.wait(2000, 100)
setSandbox({ AllowedPlayers = "someone" })
H.wait(1000, 100)
local rjRev
for _, e in ipairs(H.events(A, "job_rejected")) do if e.data.seq == sRev then rjRev = e end end
check(rjRev and rjRev.data.reason == "not_allowed" and rjRev.data.workflow == "rev" and SE.Talky_ServerRunner.pendingCount() == 0,
    "a streamer taken off Talky.AllowedPlayers: the jobs already accepted are dropped (job_rejected not_allowed)")
setSandbox({ AllowedPlayers = "streamer; someone,  other2" })
H.wait(6000, 100)
check(not H.hasToast(A, "revoked"), "and never run")
end

-- actions registered by other mods
local got
SE.Talky_Actions.register("confetti", function(p, player, job, ctx) got = { amount = p.amount, extra = p.extra, user = player:getUsername(), wf = job.workflow } end,
    { network = true, params = { amount = "number" } })
SE.Talky_Actions.register("local_only", function() got = "local" end)
local sC1 = send(A, { { action = "confetti", amount = "5" }, { action = "local_only" } })
H.wait(2000, 100)
check(got == nil and failures(A, sC1) == "confetti:disabled,local_only:unknown_action", "another mod's actions: off unless Talky.AllowCustomActions, never without network = true")
setSandbox({ AllowCustomActions = true })
local sC2 = send(A, { { action = "confetti", amount = "1e9", extra = { evil = true } } }, { workflow = "party" })
H.wait(2000, 100)
check(got and got.amount == nil and got.extra == nil and got.user == "Streamer" and got.wf == "party", "AllowCustomActions: runs with the declared params only, strictly parsed")
send(A, { { action = "confetti", amount = 7.5 } })
H.wait(2000, 100)
check(got and got.amount == 7.5, "a declared number param reaches the action")
SE.Talky_Actions.register("crash", function() error("bad\n[Talky] forged line") end, { network = true })
local sCr = send(A, { { action = "crash" } })
H.wait(2000, 100)
local forged, multiline = false, false
for _, l in ipairs(S.log) do
    if string.find(l, "^%[Talky%] forged") then forged = true end
    if string.find(l, "\n") then multiline = true end
end
check(failures(A, sCr) == "crash:error" and not forged and not multiline, "a crashing action: action_failed error; its text cannot forge console lines")
local leak = false
for _, e in ipairs(H.events(A, "action_failed")) do if e.data.seq == sCr and (e.data.detail or string.find(JSON.encode(e.data), "forged")) then leak = true end end
check(not leak, "the error text stays in the server console (never sent to the bridge)")
setSandbox({ AllowCustomActions = false })

---------------------------------------------------------------- banners for everyone

section("dedicated server: banners")

fresh()
setSandbox({ BannerAudience = 2 })
local seven = {}
for i = 1, 7 do seven[i] = { action = "notify", text = "all" .. i } end
send(A, seven)
H.wait(2000, 100)
local bSaw, aSaw = 0, 0
for i = 1, 7 do
    if H.hasToast(B, "[Streamer] all" .. i) then bSaw = bSaw + 1 end
end
for _, t in ipairs(H.toastTexts(A)) do if string.find(t, "all%d") then aSaw = aSaw + 1 end end
-- the overlay keeps the 5 last banners
check(H.hasToast(B, "[Streamer] all2") and H.hasToast(B, "[Streamer] all6") and H.hasToast(C, "[Streamer] all6"), "BannerAudience 2: banner on every client, with the streamer's name")
check(bSaw == 5 and not H.hasToast(B, "[Streamer] all7"), "6 broadcasts a minute per streamer, the 7th for the streamer only")
check(H.hasToast(A, "[Streamer] all7") or H.hasToast(A, "all7"), "the streamer sees every banner")
local zBan = #SW.zombies
send(A, { { action = "spawn_zombie", name = "Bannered" } })
H.wait(2000, 100)
local zk = SW.zombies[zBan + 1]
H.wait(61000)
H.kill(S, zk, A.conn.serverPlayer)
H.tick(2)
check(H.hasToast(B, "[Streamer] Bannered is down... for good."), "death banner broadcast too, with the name")
do
-- death banners use the same budget as notify steps: 7 named zombies die in one minute
H.wait(61000)
local zSeven = #SW.zombies
send(A, { { action = "spawn_zombie", name = "Seven", count = 7 } })
H.wait(2000, 100)
H.wait(61000)
local bDeaths, aDeaths = 0, 0
local realFxB, realFxA = B.E.Talky_Client.handlers.fx, A.E.Talky_Client.handlers.fx
B.E.Talky_Client.handlers.fx = function(a) if a.tkey == "Toast_ZombieDown" then bDeaths = bDeaths + 1 end return realFxB(a) end
A.E.Talky_Client.handlers.fx = function(a) if a.tkey == "Toast_ZombieDown" then aDeaths = aDeaths + 1 end return realFxA(a) end
for i = zSeven + 1, #SW.zombies do H.kill(S, SW.zombies[i], A.conn.serverPlayer) end
H.tick(2)
B.E.Talky_Client.handlers.fx, A.E.Talky_Client.handlers.fx = realFxB, realFxA
check(#SW.zombies - zSeven == 7 and bDeaths == 6 and aDeaths == 7,
    "7 named zombies die in a minute: 6 death banners for everyone, the 7th for the streamer only (" .. bDeaths .. ", " .. aDeaths .. ")")
-- "say" goes to the public chat of the players nearby: 12 lines a minute per streamer
fresh()
local says = {}
for i = 1, 20 do says[i] = { action = "say", text = "s" .. i } end
local chat0, said0 = #A.chat, #accA.said
send(A, says)
H.wait(2000, 100)
check(#A.chat - chat0 == 12 and #accA.said - said0 == 8 and accA.said[#accA.said].side == "client" and accA.said[#accA.said].text == "s20",
    "20 say steps: 12 in the multiplayer chat, the next 8 over the streamer's head only")
end
setSandbox({ BannerAudience = 1 })

---------------------------------------------------------------- what the client accepts from the server

section("dedicated server: events back to the bridge")

local sMine = send(A, { { action = "notify", text = "mine" } }, { workflow = "mine" })
H.wait(2000, 100)
H.wait(61000)
local SA = A.conn.serverPlayer
H.clearOutbox(A)
SE.TalkyNet.toClient(SA, "emit", { event = "test_workflow", data = { workflow = "x" } })
SE.TalkyNet.toClient(SA, "emit", { event = "game_started", data = { mode = "sp" } })
SE.TalkyNet.toClient(SA, "emit", { event = "player_died", data = {} })
SE.TalkyNet.toClient(SA, "emit", { event = "zombie_killed", data = { name = string.rep("z", 90), byPlayer = "yes", extra = 1 } })
SE.TalkyNet.toClient(SA, "emit", { event = "job_rejected", data = { seq = 1, reason = "because" } })
SE.TalkyNet.toClient(SA, "emit", { event = "action_failed", data = { seq = 1, action = "a b", code = "x" } })
SE.TalkyNet.toClient(SA, "emit", { event = "job_done", data = { seq = sMine, workflow = "spoofed" } })
SE.TalkyNet.toClient(SA, "emit", { event = "custom", data = { a = 1 } })
SE.TalkyNet.toClient(SA, "emitStep", { seq = 99999, index = 1 })
SE.TalkyNet.toClient(SA, "fx", { kind = "notify", text = "c", color = "javascript:alert(1)" })
SE.TalkyNet.toClient(SA, "fx", { kind = "notify", tkey = "Status_Online", arg = "x" })
SE.TalkyNet.toClient(SA, "fx", { kind = "eval", code = "os.exit()" })
H.tick(2)
local names = {}
for _, e in ipairs(H.outbox(A)) do names[#names + 1] = e.event end
check(table.concat(names, ",") == "zombie_killed,job_done", "only zombie_killed, job_done, action_failed, job_rejected, job_expired pass (" .. table.concat(names, ",") .. ")")
local zk2 = H.events(A, "zombie_killed")[1]
check(zk2 and string.len(zk2.data.name) == 40 and zk2.data.byPlayer == false and zk2.data.extra == nil, "zombie_killed cut to its fixed fields")
local jd = H.events(A, "job_done")[1]
check(jd and jd.data.workflow == "mine", "job_done takes the workflow of the client's own copy of the job")
check(not H.hasToast(A, A.E.Talky_T("Status_Online", "x")) and H.hasToast(A, "c"), "only the zombie banner may be asked by key; a bad color is ignored")
do
H.wait(61000)
H.clearOutbox(A)
local DROPPED = "game event%(s%) dropped: more than 60 a minute from the server"
local dropLogs = H.logCount(A, DROPPED)
for i = 1, 70 do SE.TalkyNet.toClient(SA, "emit", { event = "job_done", data = { seq = i } }) end
H.tick(2)
check(#H.events(A, "job_done") == 60, "at most 60 lines a minute asked by the server")
check(H.logCount(A, DROPPED) == dropLogs + 1, "the 10 dropped lines are reported in one console line")
H.wait(61000)

-- an emit step named again by the server is written once; after job_done, not at all
H.clearOutbox(A)
local sEm = send(A, { { action = "emit", event = "once_evt", data = { k = 1 } }, { action = "wait", seconds = 5 }, { action = "emit", event = "next_evt" } })
H.wait(2000, 100)
local emId
for id, r in pairs(A.E.Talky_Bridge.relayed) do if r.seq == sEm then emId = id end end
for _ = 1, 5 do SE.TalkyNet.toClient(SA, "emitStep", { seq = sEm, id = emId, index = 1 }) end
H.tick(2)
check(emId ~= nil and #H.events(A, "once_evt") == 1, "an emit step the server names 5 more times is written once")
H.wait(6000, 100)
check(#H.events(A, "next_evt") == 1, "the next emit step of the same job is still written")
SE.TalkyNet.toClient(SA, "emitStep", { seq = sEm, id = emId, index = 3 })
H.tick(2)
check(#H.events(A, "next_evt") == 1 and A.E.Talky_Bridge.relayed[emId] and A.E.Talky_Bridge.relayed[emId].steps == nil,
    "after job_done the job's steps are gone: a replayed emit step writes nothing")
-- heal while the streamer is dead: one "dead" line per job of this game, nothing for others
local sHeal = send(A, { { action = "wait", seconds = 30 }, { action = "notify", text = "healed later" } })
H.wait(2000, 100)
accA.dead = true
H.clearOutbox(A)
for _ = 1, 200 do SE.TalkyNet.toClient(SA, "fx", { kind = "heal", seq = sHeal }) end
for i = 1, 200 do SE.TalkyNet.toClient(SA, "fx", { kind = "heal", seq = 880000 + i }) end
SE.TalkyNet.toClient(SA, "fx", { kind = "heal" })
H.tick(2)
local deadLines = H.events(A, "action_failed")
check(#H.outbox(A) == 1 and deadLines[1] and deadLines[1].data.seq == sHeal and deadLines[1].data.code == "dead",
    "401 heal fx while dead: one action_failed dead for the job of this game, none for unknown jobs (" .. #H.outbox(A) .. " lines)")
accA.dead = false
H.wait(31000, 500)
check(H.hasToast(A, "healed later"), "the job goes on after the respawn")
H.wait(61000)
end

---------------------------------------------------------------- name tags: limits

section("dedicated server: name tag limits")

local T = SE.Talky_Tags
local function fakeZombie()
    return SW.newZombie(5000, 5000, 0, { health = 1 })
end
for _, z in ipairs(SW.zombies) do z.dead = true end
H.wait(2000, 100)
check(T.count == 0 and H.count(A.E.Talky_Client.tags) == 0, "registry empty once every zombie is gone")
local first32
for i = 1, 40 do
    local z = fakeZombie()
    if i == 1 then first32 = z end
    T.tag(z, "a" .. i, "#ff0000", "Streamer")
end
H.tick(2)
check(T.count == 32 and T.perOwner.streamer == 32 and A.E.Talky_Client.tags[tostring(first32.id)] == nil and H.count(A.E.Talky_Client.tags) == 32,
    "32 names per streamer, the oldest go first (and leave the clients)")
for o = 1, 4 do
    for i = 1, 32 do T.tag(fakeZombie(), "o" .. o .. "_" .. i, nil, "owner" .. o) end
end
H.tick(2)
check(T.count == 128 and H.count(B.E.Talky_Client.tags) == 128, "128 names in total")
local accD = H.account("Latest", { x = 1200, y = 1200 })
local D = H.newClient("D", accD, S, { fs = {} })
local chunks = 0
H.wait(5000, 100)
for _, c in ipairs(D.received) do if c == "tags" then chunks = chunks + 1 end end
check(chunks == 2 and H.count(D.E.Talky_Client.tags) == 128, "late joiner: 128 names in 2 messages (100 + 28)")
D.received = {}
D.E.TalkyNet.toServer("tags", {})
H.tick(2)
check(#D.received == 0, "the names are sent at most once per 10 s per player")
SE.TalkyNet.toClient(D.conn.serverPlayer, "tags", { reset = true, list = { { id = 1, n = "x", c = "not a color" }, { id = "bad" }, "junk", { id = 2, n = string.rep("q", 99), c = "#00ff00" } } })
H.tick(2)
check(H.count(D.E.Talky_Client.tags) == 2 and D.E.Talky_Client.tags["1"].color == nil and string.len(D.E.Talky_Client.tags["2"].name) == 40,
    "a bad entry from the server is dropped, a bad color ignored, names cut to 40")
D.ui.DRAWN = {}
D.fire("OnPostUIDraw")
check(#D.errors == 0, "the overlay draws without error")
H.wait(31 * 60000, 30000)
check(T.count == 0 and H.count(B.E.Talky_Client.tags) == 0, "names older than 30 minutes are dropped")

---------------------------------------------------------------- the streamer leaves and comes back

section("dedicated server: reconnect")

fresh()
local oldServerPlayer = A.conn.serverPlayer
local zr = #SW.zombies
local sR = send(A, { { action = "wait", seconds = 20 }, { action = "horde", name = "Back", count = 5, sameName = true }, { action = "notify", text = "back" },
    { action = "emit", event = "after_return", data = { k = 1 } } }, { workflow = "comeback" })
-- the server's answer is lost: the next game will send the job again
H.net.dropDown = function(m) return m.conn.client == A and m.command == "jobAcks" end
H.wait(3000, 100)
H.net.dropDown = nil
check(ack(A) ~= tostring(sR) and SE.Talky_ServerRunner.pendingCount() == 1, "job taken by the server, its answer lost")
H.leave(A)
H.wait(30000, 100)
check(#SW.zombies == zr, "while the streamer is away the job waits (its 20 s wait is over)")
local A2 = H.newClient("A2", accA, S, { fs = A.fs })
seqs[A2] = seqs[A]
H.wait(5000, 100)
check(A2.E.Talky_Bridge.hello.state == "allowed" and A2.conn.serverPlayer ~= nil and A2.conn.serverPlayer ~= oldServerPlayer,
    "back with a new game, and a new IsoPlayer on the server")
check(#SW.zombies == zr + 5, "the job went on once the streamer was back")
local spotted = true
for i = zr + 1, #SW.zombies do if SW.zombies[i].spottedBy ~= A2.conn.serverPlayer then spotted = false end end
check(spotted, "the zombies go for the new player object (looked up again by username)")
check(H.hasToast(A2, "back"), "the banner reaches the new game")
check(ack(A2) == tostring(sR) and #SW.zombies == zr + 5, "the new game sent the job again: duplicate, acked, not run twice")
local jdR = H.events(A2, "job_done")
check(#jdR >= 1 and jdR[#jdR].data.seq == sR and jdR[#jdR].data.workflow == "comeback", "job_done reaches the bridge after the reconnect")
check(#H.events(A2, "after_return") == 0, "an emit step of a job sent before the reconnect is lost (the new game has no copy of it yet)")
A = A2
-- away too long: the jobs are dropped
local sGone = send(A, { { action = "wait", seconds = 5 }, { action = "notify", text = "too late" } })
H.wait(3000, 100)
check(ack(A) == tostring(sGone), "job accepted")
H.leave(A)
H.wait(16 * 60000, 10000)
check(H.logHas(S, "jobs of Streamer dropped: offline for too long"), "a streamer away for more than 15 minutes loses the jobs")
local A3 = H.newClient("A3", accA, S, { fs = A.fs })
seqs[A3] = seqs[A]
A = A3
H.wait(5000, 100)
check(not H.hasToast(A, "too late") and SE.Talky_ServerRunner.pendingCount() == 0, "they never run")
-- dead streamer, paused server
local sDead2 = send(A, { { action = "wait", seconds = 2 }, { action = "notify", text = "after death" } })
H.wait(1500, 100)
accA.dead = true
H.wait(5000, 100)
check(not H.hasToast(A, "after death"), "while the streamer is dead the job waits")
accA.dead = false
H.wait(1000, 100)
check(H.hasToast(A, "after death"), "and goes on after the respawn")

-- A server pauses only when nobody is connected (PauseEmpty): then no tick runs at all.
section("dedicated server: an empty server pauses")

do
local S3 =H.newServer("SRV3", { sandbox = { Talky = { AllowedPlayers = "loner" } } })
local accL = H.account("Loner", { x = 100, y = 100 })
local L = H.newClient("L", accL, S3, { fs = {} })
H.wait(5000, 100)
check(L.E.Talky_Bridge.hello.state == "allowed" and not S3.E.isGamePaused(), "a player online: the server runs")
H.setInbox(L, { { seq = 1, workflow = "p1", steps = { { action = "wait", seconds = 60 }, { action = "notify", text = "back soon" } } } })
H.wait(3000, 100)
check(L.fs["talky_ack.txt"] == "1" and S3.E.Talky_ServerRunner.pendingCount() == 1, "job accepted")
H.leave(L)
H.wait(2000, 100)
check(S3.E.isGamePaused(), "the only player left (PauseEmpty): the server is paused")
H.wait(5 * 60000, 10000)
local L2 = H.newClient("L2", accL, S3, { fs = L.fs })
H.wait(70000, 1000)
check(H.hasToast(L2, "back soon") and not H.logHas(S3, "dropped: offline"), "back after 5 minutes: the job goes on")
H.bridgeApplyAck(L2)
H.addInbox(L2, { { seq = 2, workflow = "p2", steps = { { action = "wait", seconds = 60 }, { action = "notify", text = "too late" } } } })
H.wait(3000, 100)
check(L2.fs["talky_ack.txt"] == "2", "second job accepted")
H.leave(L2)
H.wait(16 * 60000, 20000)
local L3 = H.newClient("L3", accL, S3, { fs = L2.fs })
H.wait(70000, 1000)
check(H.logHas(S3, "jobs of Loner dropped: offline for too long") and not H.hasToast(L3, "too late") and S3.E.Talky_ServerRunner.pendingCount() == 0,
    "away 16 minutes from a paused server: the jobs are dropped all the same (no tick ran, the time counts)")
S3.pauseEmpty = false
H.leave(L3)
H.wait(1000)
check(not S3.E.isGamePaused(), "PauseEmpty off: an empty server is not paused")
H.hygiene(S3, "SRV3")
S3.alive = false
end

---------------------------------------------------------------- versions, no answer

section("dedicated server: versions and silence")

local accV = H.account("Old", { x = 1500, y = 1500 })
local V = H.newClient("V", accV, S, { fs = {} })
V.E.Talky_Config.protocolVersion = 99
H.wait(5000, 100)
check(V.E.Talky_Bridge.hello.state == "version" and H.logHas(S, "protocol 99 instead of 1"), "protocol mismatch: reported on both sides, nothing relayed")
H.leave(V)

-- a server without Talky (or whose Talky failed to load): no answer
local S0 = H.process("S0", "server", { world = H.world("server") })
S0.serverName = "plain"
local accN = H.account("Lonely")
local N = H.newClient("N", accN, S0, { fs = {} })
H.wait(60000, 1000)
check(N.E.Talky_Bridge.hello.state == "waiting", "no answer yet after 60 s: still asking")
H.wait(65000, 1000)
check(N.E.Talky_Bridge.hello.state == "no_answer" and H.logHas(N, "check the server console"), "after 2 minutes: 'no answer from the server'")
N.ui.TEXTS = {}
N.E.Talky_Window.toggle()
N.E.Talky_Window.instance:showPage("status")
local shown = false
for _, t in ipairs(N.ui.TEXTS) do if string.find(t, "no answer from the server", 1, true) then shown = true end end
check(shown, "the F8 Status page says so")
N.E.Talky_Window.instance:close()
H.leave(N)
S0.alive = false

---------------------------------------------------------------- the F8 window in multiplayer

section("dedicated server: F8 window")

-- a webhook for the copy buttons; the fake "token" of the status (a 0.4.0 bridge writes none)
-- proves the window never takes one, on the screen, in the clipboard or in talky_config.json
A.fs["talky_config.json"] = JSON.encode({ publicUrl = "https://mp.example", webhooks = { follow = { workflow = "wf" }, ["z;z"] = { workflow = "wf" } } })
for _, lang in ipairs({ "EN", "FR" }) do
    A.lang = lang
    A.ui.TEXTS, A.ui.BUTTONS, A.MISSING, A.BAD_ARGS = {}, {}, {}, {}
    A.fs["talky_status.json"] = JSON.encode({ ts = NOW, version = "0.4.0", protocol = 2, port = 7420, token = "SERVERFAKETOKEN", testNonce = "abc",
        hookTokens = { "follow" }, recent = {
        { at = "2026-10-25T10:00:00.000Z", source = "game:job_rejected", workflow = "burn", rejected = "disabled", error = "refused by the server: disabled" } } })
    A.E.Talky_Settings.statusReadAt = 0
    local copied = {}
    local ok, err = pcall(function()
        A.E.Talky_Window.toggle()
        local win = A.E.Talky_Window.instance
        win:prerender()
        win:showPage("status")
        for i = #A.ui.BUTTONS, 1, -1 do
            local b = A.ui.BUTTONS[i]
            if b.title == A.E.Talky_T("Btn_CopyCommand") then A.ui.CLIPBOARD = nil; b.onclick(b.target, b); copied[#copied + 1] = tostring(A.ui.CLIPBOARD); break end
        end
        for _, id in ipairs({ "follow", "z;z" }) do
            win.selectedHook = id
            A.ui.CLIPBOARD = nil
            win:showPage("webhooks")
            local b = A.ui.BUTTONS[#A.ui.BUTTONS]
            if b and b.title == A.E.Talky_T("Btn_CopyCommand") then b.onclick(b.target, b); copied[#copied + 1] = tostring(A.ui.CLIPBOARD) end
        end
        win:showPage("settings")
        win:onSave()
        win:close()
    end)
    check(ok, lang .. ": F8 Status, Webhooks and Settings pages build in multiplayer" .. (ok and "" or (": " .. tostring(err))))
    local leaked = string.find(A.fs["talky_config.json"] or "", "SERVERFAKETOKEN", 1, true) ~= nil
    for _, t in ipairs(A.ui.TEXTS) do if string.find(t, "SERVERFAKETOKEN", 1, true) then leaked = true end end
    check(not leaked and copied[1] == "node bridge\\bridge.js url follow"
        and copied[2] == "node bridge\\bridge.js url follow" and copied[3] == "nil",
        lang .. ": copy buttons copy the bridge command (nothing for an id with a semicolon); the status token is shown nowhere, copied nowhere, saved nowhere")
    local bad = {}
    for _, t in ipairs(A.ui.TEXTS) do if string.find(t, "UI_Talky_") or string.find(t, "%%%d") then bad[#bad + 1] = t end end
    for _, t in ipairs(bad) do print("        untranslated: " .. t) end
    check(#bad == 0 and H.count(A.MISSING) == 0 and H.count(A.BAD_ARGS) == 0, lang .. ": no missing text on the multiplayer pages")
    local function shownText(s) for _, t in ipairs(A.ui.TEXTS) do if t == s or string.find(t, s, 1, true) then return true end end return false end
    check(shownText(A.E.Talky_T("Mode_Server")) and shownText(A.E.Talky_T("Settings_ServerValue", "30")),
        lang .. ": Status shows the server's answer, Settings shows the server limits read only")
    check(shownText(A.E.Talky_T("Hooks_TokenYes")) and shownText(A.E.Talky_T("Hooks_TokenNo")), lang .. ": Webhooks page: dedicated token yes / no, from hookTokens")
end
A.fs["talky_config.json"] = nil
A.E.Talky_Settings.load()
A.lang = "EN"
H.clearOutbox(A)
A.E.Talky_Settings.testWorkflow("wf")
local twm = H.events(A, "test_workflow")
check(#twm == 1 and twm[1].data.nonce == "abc", "Test now writes test_workflow locally, with the nonce")

---------------------------------------------------------------- same outbox lines in single player and on a server

section("single player and server give the same events")

local function eventLines(P, s)
    local out = {}
    for _, e in ipairs(H.outbox(P)) do
        if e.event ~= "game_started" and type(e.data) == "table" and (e.data.seq == s or e.event == "custom_same") then
            out[#out + 1] = e.event .. " " .. JSON.encode(e.data)
        end
    end
    return table.concat(out, " | ")
end
local sameSteps = { { action = "notify", text = "x" }, { action = "emit", event = "custom_same", data = { k = 1 } }, { action = "nosuchaction" },
                    { action = "spawn_zombie", name = "Same" } }
H.clearOutbox(A)
seqs[A] = 499
local sS = send(A, sameSteps, { workflow = "same" })
H.wait(3000, 100)
local accSP = H.account("Solo")
local SPx = H.newSP(accSP, { fs = {}, name = "SP2" })
H.wait(1000, 100)
H.clearOutbox(SPx)
H.setInbox(SPx, { { seq = 500, workflow = "same", steps = sameSteps } })
H.wait(3000, 100)
local mpLines, spLines = eventLines(A, sS), eventLines(SPx, 500)
check(mpLines ~= "" and mpLines == spLines, "one job writes the same outbox lines in single player and in multiplayer")
if mpLines ~= spLines then print("        MP: " .. mpLines); print("        SP: " .. spLines) end

---------------------------------------------------------------- every process stayed clean

H.tick(3)
for _, P in ipairs(H.procs) do
    if P.kind == "server" and P ~= S then
        -- the server without Talky: nothing to check
    else
        H.hygiene(P, P.name)
    end
end
