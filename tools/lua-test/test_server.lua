-- Dedicated server in server mode: the bridge runs on the machine of the server and shares its
-- Zomboid/Lua (S.fs). It writes the jobs with "target" = the streamer whose token the webhook
-- call carried; the server reads them itself and runs them around that streamer. No client
-- relays anything.
--   A   "Streamer"  a streamer, default role
--   M   "Mod"       a streamer, moderator role (an admin of Talky: CreateHorde)
--   B   "Other"     neither
--   ADM "Boss"      admin role, not a streamer
--   C   "Late"      joins later, added as a streamer by the admin

local JSON = H.JSON

local SANDBOX = { Talky = { BannerAudience = 1 } }
local S = H.newServer("SRV", { sandbox = SANDBOX, fs = {} })
local SE, SW = S.E, S.world
local TV = SANDBOX.Talky
H.bridgeUp(S)
H.setStreamers(S, { "Streamer", "Mod" })

-- sandbox values are read again after 1 s (Talky_Config.readSandbox cache)
local function setSandbox(values)
    for k, v in pairs(values) do TV[k] = v end
    NOW = NOW + 1100
end

local seq = 0
-- A job as the bridge writes it after a webhook call with the token of `target`.
local function send(target, steps, opts)
    seq = seq + 1
    local j = { seq = seq, steps = steps, target = target }
    for k, v in pairs(opts or {}) do j[k] = v end
    H.bridgeApplyAck(S)
    H.addInbox(S, { j })
    return seq
end
local function ack() return S.fs["talky_ack.txt"] end
local function showAck() return (string.gsub(tostring(ack()), "\n", "\\n")) end
local function eventsOf(name, s)
    local out = {}
    for _, e in ipairs(H.events(S, name)) do
        if s == nil or e.data.seq == s then out[#out + 1] = e end
    end
    return out
end
local function failures(s)
    local out = {}
    for _, e in ipairs(eventsOf("action_failed", s)) do out[#out + 1] = e.data.action .. ":" .. e.data.code end
    table.sort(out)
    return table.concat(out, ",")
end
local function rejected(s)
    local e = eventsOf("job_rejected", s)[1]
    return e and e.data.reason, e and e.data.streamer
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

check(SE.Talky_Server ~= nil and SE.Talky_ServerRunner ~= nil and SE.Talky_Tags ~= nil and SE.Talky_Actions ~= nil
    and SE.Talky_Inbox ~= nil and SE.Talky_Streamers ~= nil and SE.Talky_Files ~= nil, "server modules loaded")
check(H.g(S, "Talky_Client") == nil and H.g(S, "Talky_Bridge") == nil and H.g(S, "Talky_Overlay") == nil and H.g(S, "Talky_Window") == nil
    and H.g(S, "Talky_Remote") == nil, "no client module on the server")
check(H.logHas(S, "^%[Talky%] server ready %(Talky 0%.5%.0%)$"), "'[Talky] server ready (Talky 0.5.0)' in the server console")
check(SE.TalkyNet.mode() == "server", "mode: server")
local gs = H.events(S, "game_started")
check(#gs == 1 and gs[1].data.mode == "server" and gs[1].data.streamer == nil, "game_started written by the server when it starts (OnGameStart does not exist there)")

local accA = H.account("Streamer", { x = 100, y = 100 })
local accB = H.account("Other", { x = 400, y = 400 })
local accM = H.account("Mod", { x = 700, y = 700, role = "moderator" })
local accAdm = H.account("Boss", { x = 1000, y = 1000, role = "admin" })
local A = H.newClient("A", accA, S, { fs = {} })
local B = H.newClient("B", accB, S, { fs = {} })
local M = H.newClient("M", accM, S, { fs = {} })
local ADM = H.newClient("ADM", accAdm, S, { fs = {} })
check(H.g(A, "Talky_Server") == nil and H.g(A, "Talky_Inbox") == nil and H.g(A, "Talky_Client") ~= nil and H.g(A, "Talky_Remote") ~= nil,
    "client: the server files return at once on a client")
check(A.E.TalkyNet.mode() == "client", "mode: client")
H.tick(5)
check(H.net.nullPlayer >= 4 and A.E.Talky_Remote.state == "waiting", "the first status requests are lost while the server has no player for the connection")
H.wait(4000, 100)
local RA, RB, RM, RADM = A.E.Talky_Remote, B.E.Talky_Remote, M.E.Talky_Remote, ADM.E.Talky_Remote
check(RA.state == "ready" and RA.isStreamer() and not RA.isAdmin(), "A: the server answers, a streamer, not an admin")
check(RB.state == "ready" and not RB.isStreamer() and not RB.isAdmin(), "B: neither streamer nor admin")
check(RM.isStreamer() and RM.isAdmin(), "M: a streamer, and an admin of Talky (moderator role: CreateHorde)")
check(RADM.isAdmin() and not RADM.isStreamer(), "ADM: admin role, not a streamer")
local hc = RA.status.caps
check(hc and hc.maxZombiesPerAction == 30 and hc.maxZombiesPerJob == 60 and hc.maxSpawnDistance == 40 and hc.maxJobsPerMinute == 30
    and hc.allow.fire == false and hc.allow.helicopter == false and hc.allow.zombies == true, "the status carries the server limits (sandbox defaults)")
check(RA.status.bridge.alive and RA.status.bridge.mode == "server" and RA.status.bridge.protocol == 3, "the status says the bridge of the server runs in server mode")
check(A.sent.tags == 1 and B.sent.tags == 1, "each client asks once for the names already given (late join)")
check(A.sent.jobs == nil and A.sent.hello == nil and A.fs["talky_ack.txt"] == nil and A.fs["talky_outbox.txt"] == nil,
    "no client sends a job nor a hello, none writes the bridge's files")
check(RADM.configState == "ready" and RADM.config ~= nil, "an admin gets the server's configuration once the server said so")

---------------------------------------------------------------- the relay of 0.4.0 is gone

section("dedicated server: the relay of 0.4.0 is gone")

check(SE.Talky_Server.commands.jobs == nil and SE.Talky_Server.commands.hello == nil and SE.Talky_Server.acceptJob == nil,
    "the server has no jobs or hello command")
check(SE.Talky_Config.readSandbox().AllowedPlayers == nil and SE.Talky_Config.readSandbox().AllowAdmins == nil,
    "the sandbox options AllowedPlayers and AllowAdmins are gone")
A.received = {}
A.E.TalkyNet.toServer("jobs", { v = 1, list = { { seq = 5, id = "5:1", steps = { { action = "horde", count = 5 } } } } })
A.E.TalkyNet.toServer("hello", { v = 1, client = "0.4.0" })
H.tick(3)
check(#A.received == 0 and SW.alive() == 0, "a 'jobs' or 'hello' command of a 0.4.0 client gets no answer and runs nothing")
setSandbox({ AllowedPlayers = "other", AllowAdmins = true })
local sB = send("Other", { { action = "spawn_zombie", name = "NotMine" } }, { workflow = "intruder" })
H.wait(2000, 100)
local rB, rBs = rejected(sB)
check(ack() == tostring(sB) and rB == "not_streamer" and rBs == "Other" and zombiesNamed("NotMine") == 0,
    "a job for a player who is not a streamer: acked, job_rejected not_streamer, nothing runs (the old AllowedPlayers option counts for nothing)")
TV.AllowedPlayers, TV.AllowAdmins = nil, nil
local sNo = send(nil, { { action = "noise" } }, { workflow = "solo_bridge" })
H.wait(2000, 100)
check(rejected(sNo) == "not_streamer" and #SW.sounds == 0, "a job without target (a bridge in solo mode next to a server): not_streamer")

---------------------------------------------------------------- routing

section("dedicated server: the token names the streamer, the job runs around them")

local s1 = send("Streamer", {
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
    { action = "emit", event = "streamer_add", data = { name = "Evil" } },
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
check(ack() == tostring(s1), "acked by the server itself (" .. showAck() .. ")")
check(SW.alive() == 30 and zombiesNamed("Raider") == 30, "horde capped to 30 (MaxZombiesPerAction), spawned in the server world")
check(perTick == 10, "at most 10 zombies created per tick (" .. perTick .. ")")
local near = true
for _, z in ipairs(SW.zombies) do if not within(z, accA, 40) or z.spottedBy ~= A.conn.serverPlayer then near = false end end
check(near, "every zombie within MaxSpawnDistance of the streamer the token named, and after that streamer")
check(H.count(A.E.Talky_Client.tags) == 30 and H.count(B.E.Talky_Client.tags) == 30, "the 30 names reached the clients")
check(H.hasToast(A, "hello all") and not H.hasToast(B, "hello all") and not H.hasToast(B, "[Streamer] hello all"), "banner shown to the streamer only (BannerAudience 1)")
check(#accA.healed == 1 and accA.healed[1] == "client", "heal runs on the streamer's client (client-owned health)")
check(accA.stats.PANIC == 50 and accA.statSide == "server" and SW.statSyncs[1] and SW.statSyncs[1].user == "Streamer" and SW.statSyncs[1].mask == 8192,
    "stat set on the server and synced with getBitMaskForStat")
check(accA.items[1] and accA.items[1].side == "server" and accA.items[1].n == 100 and SW.itemSyncs == 1, "give_item on the server, 100 at most, sent with sendAddItemsToContainer")
check(#SW.ground == 2 and SW.ground[1].t == "Base.Bandage", "onGround items through AddWorldInventoryItem (sent to the clients)")
check(SW.xp[1] and SW.xp[1].amount == 1000 and SW.xp[1].user == "Streamer" and SW.xp[1].perk == "Strength", "xp capped to 1000, given to the streamer")
check(SW.weather[1] and SW.weather[1].transmitted and SW.weather[1].hours == 12 and SW.weatherStops >= 1, "storm: stopWeatherAndThunder, then transmitServerTriggerStorm, 12 h at most, raw stage ignored")
check(A.chat[1] == "thanks" and #accA.said == 0, "say goes through the multiplayer chat (processSayMessage)")
check(A.halos[1] and A.halos[1].text == "+1" and A.halos[1].side == "client", "halo shown by the streamer's client")
local cm = H.events(S, "custom_mp")
check(#cm == 1 and cm[1].data.z == 2 and cm[1].data.streamer == "Streamer", "an emit step is written by the server, with the streamer")
check(#H.events(S, "test_workflow") == 0 and #H.events(S, "streamer_add") == 0, "an emit step never writes test_workflow nor a streamer request")
check(failures(s1) == "emit:invalid,emit:invalid,fire:disabled,helicopter:disabled" and #SW.fires == 0 and #SW.heli == 0,
    "fire and helicopter off by default on a server, reserved events refused (" .. failures(s1) .. ")")
check(SW.serverSounds[1] == "ZombieSurprisedPlayer" and #accA.sounds == 0, "sound through playServerSound, heard by the nearby clients")
check(SW.sounds[1] and SW.sounds[1].r == 80, "noise radius capped to 80 (MaxNoiseRadius)")
check(#SW.thunder == 1 and SW.thunder[1].transmitted, "thunder through triggerThunderEvent (sent with the climate packet)")
check(SW.times[1] == 22, "time set on the server")
local jd = eventsOf("job_done", s1)
check(#jd == 1 and jd[1].data.workflow == "raid" and jd[1].data.streamer == "Streamer" and jd[1].data.id == nil, "job_done { seq, workflow, streamer } in the server's outbox")
local af = eventsOf("action_failed", s1)
check(af[1] and af[1].data.error == af[1].data.code and af[1].data.streamer == "Streamer", "action_failed carries code, error (0.3.0) and the streamer")

-- the other streamer: their own character, whatever the case of the name the bridge wrote
local zm = #SW.zombies
local sM1 = send("mod", { { action = "horde", name = "ModHorde", count = 5, sameName = true } }, { workflow = "m1" })
H.wait(2000, 100)
local aroundM = #SW.zombies == zm + 5
for i = zm + 1, #SW.zombies do
    if not within(SW.zombies[i], accM, 40) or SW.zombies[i].spottedBy ~= M.conn.serverPlayer then aroundM = false end
end
local jdM = eventsOf("job_done", sM1)[1]
check(aroundM and jdM and jdM.data.streamer == "Mod", "target 'mod': the zombies go around Mod, job_done names 'Mod' (the name of the list)")

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
local kills = H.events(S, "zombie_killed")
check(#kills == 1 and kills[1].data.name == "Raider" and kills[1].data.byPlayer == true and kills[1].data.streamer == "Streamer",
    "zombie_killed once (OnZombieDead fired twice), for the streamer whose job spawned it, byPlayer = true")
check(H.hasToast(A, "Raider is down... for good.") and not H.hasToast(B, "Raider is down... for good."), "death banner for the streamer only")
check(B.E.Talky_Client.tags[tostring(zed.id)] == nil and H.count(B.E.Talky_Client.tags) == 34, "untag reached the other client")
H.kill(S, SW.zombies[2], B.conn.serverPlayer)
H.tick(2)
kills = H.events(S, "zombie_killed")
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
kills = H.events(S, "zombie_killed")
check(#kills == 4 and kills[3].data.name == string.rep("a", 39) and kills[4].data.name == "Zo\195\169", "zombie_killed names written to the outbox without '?'")
end

-- a late joiner gets the names
local accC = H.account("Late", { x = 900, y = 900 })
local C = H.newClient("C", accC, S, { fs = {} })
H.wait(5000, 100)
check(H.count(C.E.Talky_Client.tags) == 33, "a late joiner receives the names (" .. H.count(C.E.Talky_Client.tags) .. ")")
check(C.E.Talky_Remote.state == "ready" and not C.E.Talky_Remote.isStreamer(), "C: not a streamer yet")

-- recycled zombie: online id and modData reset, the sweep drops it
SW.recycle(SW.zombies[3], 77)
H.wait(2000, 100)
check(C.E.Talky_Client.tags[tostring(102)] == nil and H.count(C.E.Talky_Client.tags) == 32 and H.count(A.E.Talky_Client.tags) == 32,
    "a recycled zombie loses its name everywhere")
SW.zombies[4].dead = true
H.wait(2000, 100)
check(H.count(A.E.Talky_Client.tags) == 31 and SE.Talky_Tags.count == 31, "a dead zombie is swept too")

---------------------------------------------------------------- what the server reads

section("dedicated server: the inbox, line by line")

-- values a webhook could make the bridge write: strict numbers on the server
SE.Talky_ServerRunner.cooldowns = {}
local timesBefore, zBefore = #SW.times, #SW.zombies
H.bridgeApplyAck(S)
seq = seq + 1
local sNum = seq
S.fs["talky_inbox.jsonl"] = (S.fs["talky_inbox.jsonl"] or "") .. '{"seq":' .. sNum .. ',"target":"Streamer","workflow":"n","createdAt":' .. string.format("%.0f", NOW)
    .. ',"expiresAt":' .. string.format("%.0f", NOW + 60000) .. ',"steps":[{"action":"time","hour":"nan"},'
    .. '{"action":"spawn_zombie","count":1e308,"name":["table"],"distance":-1e308,"health":"inf"},'
    .. '{"action":"xp","perk":"Strength","amount":"1e9"},{"action":"give_item","item":"Base.Apple","count":"-inf"},'
    .. '{"action":"stat","stat":"PANIC","op":"set","value":"NaN"},{"action":"noise","radius":"0x10","volume":1e999}]}\n'
H.wait(3000, 100)
check(SW.times[timesBefore + 1] == 0, "'nan' hour falls back to the default")
local zNew = SW.zombies[zBefore + 1]
check(#SW.zombies == zBefore + 30 and zNew.md.Talky_name == nil and zNew.health == 1, "a huge count is capped (30), a table name dropped, 'inf' health -> 1")
check(SW.xp[#SW.xp].amount == 10 and accA.items[#accA.items].n == 1 and accA.stats.PANIC == 0 and SW.sounds[#SW.sounds].r == 60,
    "texts that are not plain numbers fall back to their defaults (xp 10, items 1, stat 0, radius 60)")

-- lines the bridge would never write: skipped, acked when they have a seq
H.bridgeApplyAck(S)
local sDead = seq + 1
seq = sDead
S.fs["talky_inbox.jsonl"] = (S.fs["talky_inbox.jsonl"] or "") .. "{not json\n" .. JSON.encode({ seq = sDead, target = "Streamer", workflow = "x", createdAt = NOW, expiresAt = NOW + 60000 }) .. "\n"
H.wait(2000, 100)
check(ack() == tostring(sDead) and H.logCount(S, "bad inbox line") == 1, "an unreadable line is skipped (logged), a line without steps is acked")

-- disabled and unknown steps
local sDis = send("Streamer", { { action = "fire" } }, { workflow = "burn" })
H.wait(2000, 100)
local rj = eventsOf("job_rejected", sDis)
check(ack() == tostring(sDis) and #rj == 1 and rj[1].data.reason == "disabled" and rj[1].data.workflow == "burn" and rj[1].data.streamer == "Streamer",
    "a job with only turned-off steps is refused for good: acked + job_rejected")
local sUnk = send("Streamer", { { action = "fly_to_moon" }, { action = "notify", text = "still runs" } })
H.wait(2000, 100)
check(failures(sUnk) == "fly_to_moon:unknown_action" and H.hasToast(A, "still runs") and ack() == tostring(sUnk), "an unknown step is skipped and reported, the rest of the job runs")
local sBadName = send("Streamer", { { action = "give-item" }, "junk", { action = "notify", text = "after a bad name" } })
H.wait(2000, 100)
check(failures(sBadName) == "step:invalid" and H.hasToast(A, "after a bad name"),
    "unreadable steps (a name with '-', not a table): reported once as action 'step', code invalid, the rest runs (" .. failures(sBadName) .. ")")
local sOld = send("Streamer", { { action = "notify", text = "too old" } }, { createdAt = NOW - 1200000, expiresAt = NOW + 600000 })
H.wait(2000, 100)
check(ack() == tostring(sOld) and not H.hasToast(A, "too old") and #eventsOf("job_rejected", sOld) == 0 and H.logHas(S, "job " .. sOld .. " expired, skipped"),
    "a job created more than 15 minutes ago is acked and skipped quietly")

---------------------------------------------------------------- acks

section("dedicated server: acks")

-- one streamer's jobs wait (queue full), the other streamer's are taken: holes in the ack line
setSandbox({ MaxQueuedJobs = 1, MaxActiveJobs = 1 })
local h1 = send("Streamer", { { action = "wait", seconds = 30 }, { action = "notify", text = "h1" } })
local h2 = send("Streamer", { { action = "notify", text = "h2" } })
local h3 = send("Streamer", { { action = "notify", text = "h3" } })
local h4 = send("Mod", { { action = "notify", text = "h4" } })
H.wait(3000, 100)
check(ack() == tostring(h2) .. " " .. tostring(h4) .. "\n",
    "Streamer: one job running, one waiting, the third left in the inbox; Mod's job taken: ack '" .. h2 .. " " .. h4 .. "' (" .. showAck() .. ")")
local mark, extra = H.parseAck(ack())
check(mark == h2 and extra[1] == h4 and #extra == 1 and H.hasToast(M, "h4"), "the bridge reads S and the extra seq; Mod's job ran")
check(tonumber(string.match(ack(), "^%d+")) == h2, "a 0.3.0 bridge (parseInt) reads S only and keeps job " .. h3)
H.wait(40000, 500)
check(ack() == tostring(h4) and H.hasToast(A, "h2") and H.hasToast(A, "h3"), "then Streamer's jobs are taken in order and run (" .. showAck() .. ")")
setSandbox({ MaxQueuedJobs = 10, MaxActiveJobs = 4 })

---------------------------------------------------------------- queue limits

section("dedicated server: queue and rate limits")

-- busy: the server queue is full, the job stays in the inbox
setSandbox({ MaxQueuedJobs = 1, MaxActiveJobs = 1 })
local first = seq + 1
for i = 1, 4 do send("Streamer", { { action = "wait", seconds = 20 }, { action = "notify", text = "q" .. i } }) end
H.wait(5000, 100)
check(ack() == tostring(first + 1), "one job running, one waiting, the two others left in the inbox, not acked (" .. showAck() .. ")")
H.wait(120000, 500)
check(ack() == tostring(first + 3) and H.hasToast(A, "q4"), "they are taken later, in order, and run (" .. showAck() .. ")")
do
-- a refused step of a job left in the inbox: reported once, when the job is taken
send("Streamer", { { action = "wait", seconds = 20 }, { action = "notify", text = "b1" } })
send("Streamer", { { action = "wait", seconds = 20 }, { action = "notify", text = "b2" } })
local sBusy = send("Streamer", { { action = "notify", text = "b3" }, { action = "helicopter" } })
H.wait(8000, 500)
local busyEarly = failures(sBusy)
H.wait(62000, 500)
check(busyEarly == "" and failures(sBusy) == "helicopter:disabled" and H.hasToast(A, "b3"),
    "a turned-off step of a waiting job: one action_failed once the job is taken, not one per read (" .. failures(sBusy) .. ")")
end
setSandbox({ MaxQueuedJobs = 10, MaxActiveJobs = 4 })

-- rate limited: MaxJobsPerMinute per streamer
H.wait(61000)
setSandbox({ MaxJobsPerMinute = 3 })
first = seq + 1
for i = 1, 5 do send("Streamer", { { action = "notify", text = "r" .. i } }) end
local sOtherRl = send("Mod", { { action = "notify", text = "mod not limited" } })
H.wait(1500, 100)
check(ack() == tostring(first + 2) .. " " .. tostring(sOtherRl) .. "\n" and H.hasToast(M, "mod not limited"),
    "4th job of the minute of Streamer waits in the inbox; Mod's own budget is untouched (" .. showAck() .. ")")
check(SE.Talky_Inbox.retryAt.streamer and SE.Talky_Inbox.retryAt.streamer - NOW > 50000, "read again when the minute ends")
H.wait(62000, 500)
check(ack() == tostring(sOtherRl) and H.hasToast(A, "r5"), "then taken")
do
-- one read of 10 jobs x 100 unknown steps: 20 action_failed per job at most, and the refused
-- jobs count in the per-minute window
H.wait(61000)
setSandbox({ MaxJobsPerMinute = 10 })
local floodFirst = seq + 1
for j = 1, 10 do
    local st = {}
    for k = 1, 100 do st[k] = { action = "u" .. k } end
    send("Streamer", st)
end
local afterFlood = send("Streamer", { { action = "notify", text = "after flood" } })
H.wait(1500, 100)
local floodLines = 0
for s = floodFirst, floodFirst + 9 do floodLines = floodLines + #eventsOf("action_failed", s) end
check(floodLines == 200 and rejected(floodFirst) == "unknown_action" and ack() == tostring(afterFlood - 1) and not H.hasToast(A, "after flood"),
    "10 jobs x 100 unknown steps: refused, 200 outbox lines and not 1000; they use up the per-minute window (" .. floodLines .. ")")
setSandbox({ MaxJobsPerMinute = 30 })
H.wait(62000, 1000)
check(H.hasToast(A, "after flood"), "the next job runs once the minute is over")
end

-- token bucket: 5 commands a second, 10 at once
A.received = {}
for _ = 1, 30 do A.E.sendClientCommand(A.localPlayer, "Talky", "status", {}) end
H.tick(1)
H.tick(1)
local n = 0
for _, c in ipairs(A.received) do if c == "status" then n = n + 1 end end
check(n == 10, "30 commands in one tick: 10 handled (burst), the rest dropped silently (" .. n .. ")")
local logsBefore = #S.log
A.received = {}
A.E.sendClientCommand(A.localPlayer, "Talky", "selfdestruct", { now = true })
A.E.sendClientCommand(A.localPlayer, "Other", "status", {})
H.wait(1000, 100)
check(#A.received == 0 and #S.log == logsBefore, "unknown command or other module: no answer, no log")

---------------------------------------------------------------- caps and budgets

section("dedicated server: caps and budgets")

local R = SE.Talky_ServerRunner
local function fresh()
    R.windows, R.cooldowns, R.broadcasts = {}, {}, {}
    SE.Talky_Inbox.jobTimes = {}
    H.wait(1000)
end

-- zombies: 60 per job
fresh()
local zb = SW.alive()
local sJ = send("Streamer", { { action = "horde", count = 30 }, { action = "horde", count = 30 }, { action = "horde", count = 30 } })
H.wait(3000, 100)
check(SW.alive() - zb == 60 and failures(sJ) == "horde:budget", "60 zombies per job (MaxZombiesPerJob), the third horde: budget")
send("Streamer", { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
send("Streamer", { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
H.wait(4000, 100)
check(SW.alive() - zb == 150, "150 zombies per player per 10 minutes (" .. (SW.alive() - zb) .. ")")
H.wait(601000, 5000)
send("Streamer", { { action = "spawn_zombie", count = 5 } })
H.wait(2000, 100)
check(SW.alive() - zb == 155, "the budget comes back after 10 minutes")
-- server-wide budget, shared by two streamers
fresh()
setSandbox({ MaxZombiesPer10MinServer = 100 })
zb = SW.alive()
send("Streamer", { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
send("Mod", { { action = "horde", count = 30 }, { action = "horde", count = 30 } })
local maxTick, prev = 0, SW.alive()
for _ = 1, 40 do
    H.tick(1)
    if SW.alive() - prev > maxTick then maxTick = SW.alive() - prev end
    prev = SW.alive()
end
check(SW.alive() - zb == 100, "server-wide budget shared by every streamer (MaxZombiesPer10MinServer = 100: " .. (SW.alive() - zb) .. ")")
check(maxTick <= 10, "10 zombies per tick for the whole server, two streamers at once (" .. maxTick .. ")")
setSandbox({ MaxZombiesPer10MinServer = 400 })

-- items, vehicles, xp
fresh()
local itemsBefore = #accA.items
local sI = send("Streamer", { { action = "give_item", item = "Base.Apple", count = 100 }, { action = "give_item", item = "Base.Apple", count = 100 },
    { action = "give_item", item = "Base.Apple", count = 100 }, { action = "give_item", item = "Base.Apple", count = 100 } })
H.wait(2000, 100)
check(#accA.items == itemsBefore + 3 and failures(sI) == "give_item:budget", "300 items per 10 minutes, then budget")
local vBefore = #SW.vehicles
local sV = send("Streamer", { { action = "vehicle" }, { action = "vehicle", script = "Base.PickUpTruck" }, { action = "vehicle" } })
H.wait(2000, 100)
check(#SW.vehicles == vBefore + 2 and failures(sV) == "vehicle:budget", "2 vehicles per 10 minutes, then budget")
local xpBefore = #SW.xp
local sX = send("Streamer", { { action = "xp", perk = "Strength", amount = 1000 }, { action = "xp", perk = "Fitness", amount = 1000 },
    { action = "xp", perk = "Strength", amount = 1000 }, { action = "xp", perk = "Strength", amount = 1000 },
    { action = "xp", perk = "Strength", amount = 1000 }, { action = "xp", perk = "Strength", amount = 1000 } })
H.wait(2000, 100)
check(#SW.xp == xpBefore + 5 and failures(sX) == "xp:budget", "5000 XP per 10 minutes, then budget")
do
fresh()
local sXf = send("Streamer", { { action = "xp", perk = "Strength", amount = "0.0001" }, { action = "xp", perk = "Strength", amount = 0.5 },
    { action = "xp", perk = "Strength", amount = 1.9 } })
H.wait(2000, 100)
check(failures(sXf) == "xp:invalid,xp:invalid" and SW.xp[#SW.xp].amount == 1, "server: XP below 1 is invalid, 1.9 gives 1 (whole amounts)")
for _ = 1, 5 do
    local st = {}
    for k = 1, 10 do st[k] = { action = "xp", perk = "Fitness", amount = 1 } end
    send("Streamer", st)
    H.wait(15000, 1000)
end
local wx, wsum = R.windows["x:streamer"] or {}, 0
for _, v in pairs(wx) do wsum = wsum + v end
check(H.count(wx) >= 2 and H.count(wx) <= 60 and wsum == 51, "a 10-minute budget is kept in 10-second buckets (" .. H.count(wx) .. " keys, " .. wsum .. " XP)")
fresh()
local snd = {}
for i = 1, 70 do snd[i] = { action = (i % 2 == 0) and "sound" or "noise", radius = 5 } end
local sn0, ss0 = #SW.sounds, #SW.serverSounds
local sSnd = send("Streamer", snd)
H.wait(2000, 100)
local nFail = 0
for _, e in ipairs(eventsOf("action_failed", sSnd)) do if e.data.code == "budget" then nFail = nFail + 1 end end
check((#SW.sounds - sn0) + (#SW.serverSounds - ss0) == 60 and nFail == 10, "60 noise and sound steps per streamer per 10 minutes, then budget")
H.wait(61000)
local logNope = #S.log
local nope = {}
for k = 1, 20 do nope[k] = { action = "stat", stat = "NOPE" } end
local sNope = send("Streamer", nope)
H.wait(2000, 100)
local nopeLines = 0
for i = logNope + 1, #S.log do if string.find(S.log[i], "stat failed (not_found)", 1, true) then nopeLines = nopeLines + 1 end end
check(nopeLines == 1 and #eventsOf("action_failed", sNope) == 20, "20 failing steps: one console line a minute for that reason, every action_failed still written (" .. nopeLines .. ")")
end

-- what the server accepts
fresh()
setSandbox({ ItemDenylist = "Base.Katana, Base.Axe" })
local sVal = send("Streamer", {
    { action = "give_item", item = "Base.HiddenThing" }, { action = "give_item", item = "Base.OldThing" },
    { action = "give_item", item = "Apple" }, { action = "give_item", item = "base.katana" }, { action = "give_item", item = "Base.Axe" },
    { action = "xp", perk = "Passiv", amount = 10 }, { action = "xp", perk = "None", amount = 10 },
    { action = "vehicle", script = "Base.Tank" }, { action = "stat", stat = "GODMODE", value = 1 },
    { action = "weather", type = "acid_rain" },
})
H.wait(2000, 100)
check(failures(sVal) == "give_item:not_found,give_item:not_found,give_item:not_found,give_item:not_found,give_item:not_found,"
    .. "stat:not_found,vehicle:not_found,weather:not_found,xp:not_found,xp:not_found",
    "server refuses hidden, obsolete, short and denylisted items, skill categories, unknown vehicles, stats and weathers (" .. failures(sVal) .. ")")
setSandbox({ ItemDenylist = "" })
accA.z = 1
local sUp = send("Streamer", { { action = "vehicle" } })
H.wait(2000, 100)
accA.z = 0
check(failures(sUp) == "vehicle:no_square", "no vehicle above the ground floor")

-- steps per job and total wait
fresh()
local steps = {}
for i = 1, 150 do steps[i] = { action = "halo", text = "h" .. i } end
local nBefore = #A.halos
local sSteps = send("Streamer", steps)
H.wait(3000, 100)
check(#A.halos == nBefore + 100 and A.halos[#A.halos].text == "h100" and H.logHas(S, "job " .. sSteps .. ": 50 step%(s%) dropped"),
    "150 steps: the first 100 run (MaxStepsPerJob), the server console says 50 were dropped")
local sLong = send("Streamer", { { action = "wait", seconds = 600 }, { action = "wait", seconds = 600 }, { action = "wait", seconds = 600 }, { action = "notify", text = "late" } })
H.wait(880000, 5000)
check(not H.hasToast(A, "late"), "three 600 s waits: still waiting after 880 s")
H.wait(60000, 1000)
check(H.hasToast(A, "late") and #eventsOf("job_done", sLong) == 1, "the waits of one job end after 900 s in total (not 1800 s)")

-- server-wide cooldowns
fresh()
local wBefore, tBefore, thBefore = #SW.weather, #SW.times, #SW.thunder
local sCd = send("Streamer", { { action = "weather", type = "blizzard", hours = 2 }, { action = "time", hour = 3 }, { action = "thunder" }, { action = "thunder" } })
local sCdM = send("Mod", { { action = "weather", type = "storm" }, { action = "time", hour = 5 } })
H.wait(3000, 100)
check(#SW.weather == wBefore + 1 and SW.weather[#SW.weather].stage == 7 and not SW.weather[#SW.weather].transmitted,
    "blizzard: stopWeatherAndThunder then triggerCustomWeatherStage")
check(#SW.times == tBefore + 1 and #SW.thunder == thBefore + 1 and failures(sCd) == "thunder:cooldown", "time once, thunder once in 30 s")
check(failures(sCdM) == "time:cooldown,weather:cooldown", "cooldowns are server-wide: the other streamer waits too")
H.wait(31 * 60000, 10000)
local sCd2 = send("Mod", { { action = "weather", type = "storm" }, { action = "time", hour = 5 } })
H.wait(2000, 100)
check(failures(sCd2) == "" and #SW.times == tBefore + 2, "after the cooldowns, weather and time work again")

-- helicopter and fire, once a server allows them
fresh()
setSandbox({ AllowHelicopter = true, AllowFire = true })
local sH = send("Streamer", { { action = "helicopter" } })
H.wait(2000, 100)
check(failures(sH) == "helicopter:helicopter_random_target" and #SW.heli == 0, "several players online: the helicopter is refused (it would pick a random player)")
setSandbox({ HelicopterAnyTarget = true })
local sH2 = send("Streamer", { { action = "helicopter" }, { action = "helicopter" } })
H.wait(2000, 100)
check(#SW.heli == 1 and failures(sH2) == "helicopter:cooldown", "HelicopterAnyTarget: testHelicopter runs, then a 60 min cooldown")
local fBefore = #SW.fires
local zf = #SW.zombies
send("Streamer", { { action = "fire" }, { action = "spawn_zombie", onFire = true } })
H.wait(2000, 100)
check(#SW.fires == fBefore + 1 and SW.zombies[zf + 1] and SW.zombies[zf + 1].onFire == true, "AllowFire: fire and burning zombies")
do
fresh()
local twelve = {}
for i = 1, 12 do twelve[i] = { action = "fire" } end
local f0 = #SW.fires
local sFa = send("Streamer", twelve)
H.wait(2000, 100)
check(#SW.fires - f0 == 10 and failures(sFa) == "fire:budget,fire:budget", "10 fires per streamer per 10 minutes, then budget")
local sFm = send("Mod", twelve)
H.wait(2000, 100)
R.windows["f:streamer"] = nil
local sFs = send("Streamer", { { action = "fire" } })
H.wait(2000, 100)
check(#SW.fires - f0 == 20 and failures(sFm) == "fire:budget,fire:budget" and failures(sFs) == "fire:budget", "20 fires per 10 minutes on the whole server")
end
setSandbox({ AllowHelicopter = false, AllowFire = false, HelicopterAnyTarget = false })
zf = #SW.zombies
send("Streamer", { { action = "spawn_zombie", onFire = true } })
H.wait(2000, 100)
check(SW.zombies[zf + 1] and SW.zombies[zf + 1].onFire == false, "fire turned off: zombies are not set on fire either")

-- other players nearby, safehouses
fresh()
accB.x, accB.y = accA.x + 1, accA.y
local zp = #SW.zombies
local sP = send("Streamer", { { action = "spawn_zombie", name = "Near", distance = 12 }, { action = "vehicle" } })
H.wait(2000, 100)
check(#SW.zombies == zp and failures(sP) == "spawn_zombie:no_square,vehicle:no_square", "no spawn nor vehicle next to another player (ProtectRadius)")
setSandbox({ ProtectRadius = 0 })
send("Streamer", { { action = "spawn_zombie", name = "Near", distance = 12 } })
H.wait(2000, 100)
check(#SW.zombies == zp + 1, "ProtectRadius 0: allowed")
setSandbox({ ProtectRadius = 15 })
accB.x, accB.y = 400, 400
SW.addSafehouse({ x1 = 50, y1 = 50, x2 = 150, y2 = 150, members = { other = true } })
zp = #SW.zombies
local sSh = send("Streamer", { { action = "spawn_zombie", name = "Inside", distance = 12 } })
H.wait(2000, 100)
check(#SW.zombies == zp and failures(sSh) == "spawn_zombie:no_square", "no spawn inside another player's safehouse")
SW.safehouses[1].members.streamer = true
send("Streamer", { { action = "spawn_zombie", name = "Inside", distance = 12 } })
H.wait(2000, 100)
check(#SW.zombies == zp + 1, "allowed in a safehouse the streamer belongs to")
SW.safehouses = {}

-- category toggles
setSandbox({ AllowZombies = false, AllowXp = false, AllowItems = false, AllowVehicles = false, AllowPlayerEffects = false,
             AllowWeather = false, AllowTime = false, AllowSounds = false })
local sOff = send("Streamer", { { action = "spawn_zombie" }, { action = "horde" }, { action = "xp", perk = "Strength" }, { action = "give_item" },
    { action = "vehicle" }, { action = "heal" }, { action = "stat", stat = "PANIC" }, { action = "weather" }, { action = "thunder" },
    { action = "time" }, { action = "noise" }, { action = "sound" }, { action = "notify", text = "only me" } })
H.wait(2000, 100)
check(failures(sOff) == "give_item:disabled,heal:disabled,horde:disabled,noise:disabled,sound:disabled,spawn_zombie:disabled,stat:disabled,"
    .. "thunder:disabled,time:disabled,vehicle:disabled,weather:disabled,xp:disabled" and H.hasToast(A, "only me"),
    "every category can be turned off; banners still work")
setSandbox({ AllowZombies = true, AllowXp = true, AllowItems = true, AllowVehicles = true, AllowPlayerEffects = true,
             AllowWeather = true, AllowTime = true, AllowSounds = true })

do
-- the game creates no zombie (zombies turned off in the world): reported, the budget given back
fresh()
SW.zombiesDisabled = true
local zNone = #SW.zombies
local sNoZ = send("Streamer", { { action = "spawn_zombie", count = 5 }, { action = "horde", count = 20 } })
H.wait(3000, 100)
SW.zombiesDisabled = false
local zsum = 0
for _, v in pairs(R.windows["z:streamer"] or {}) do zsum = zsum + v end
check(failures(sNoZ) == "horde:refused,spawn_zombie:refused" and #SW.zombies == zNone and zsum == 0,
    "a spawn that creates no zombie: action_failed refused, its budget given back (" .. failures(sNoZ) .. ", " .. zsum .. ")")
-- rules changed after a job was accepted: they apply to it too
fresh()
local zc = SW.alive()
local sCat = send("Streamer", { { action = "spawn_zombie", count = 1 }, { action = "wait", seconds = 5 }, { action = "spawn_zombie", count = 1 } })
H.wait(2000, 100)
local catFirst = SW.alive() - zc
setSandbox({ AllowZombies = false })
H.wait(6000, 100)
check(catFirst == 1 and SW.alive() - zc == 1 and failures(sCat) == "spawn_zombie:disabled",
    "zombies turned off while a job runs: its next spawn step is refused (disabled)")
setSandbox({ AllowZombies = true })
local zh = SW.alive()
local sHo = send("Streamer", { { action = "horde", count = 30 } })
local hordeStarted = false
for _ = 1, 40 do
    H.tick(1)
    if SW.alive() > zh then hordeStarted = true; break end
end
setSandbox({ AllowZombies = false })
H.tick(3)
local hordeMade = SW.alive() - zh
check(hordeStarted and hordeMade > 0 and hordeMade < 30 and failures(sHo) == "horde:disabled",
    "zombies turned off during a horde: the rest of it is not created (" .. hordeMade .. " of 30)")
setSandbox({ AllowZombies = true })
end

-- actions registered by other mods
local got
SE.Talky_Actions.register("confetti", function(p, player, job, ctx) got = { amount = p.amount, extra = p.extra, user = player:getUsername(), wf = job.workflow } end,
    { network = true, params = { amount = "number" } })
SE.Talky_Actions.register("local_only", function() got = "local" end)
local sC1 = send("Streamer", { { action = "confetti", amount = "5" }, { action = "local_only" } })
H.wait(2000, 100)
check(got == nil and failures(sC1) == "confetti:disabled,local_only:unknown_action", "another mod's actions: off unless Talky.AllowCustomActions, never without network = true")
setSandbox({ AllowCustomActions = true })
send("Streamer", { { action = "confetti", amount = "1e9", extra = { evil = true } } }, { workflow = "party" })
H.wait(2000, 100)
check(got and got.amount == nil and got.extra == nil and got.user == "Streamer" and got.wf == "party", "AllowCustomActions: runs with the declared params only, strictly parsed")
send("Streamer", { { action = "confetti", amount = 7.5 } })
H.wait(2000, 100)
check(got and got.amount == 7.5, "a declared number param reaches the action")
SE.Talky_Actions.register("crash", function() error("bad\n[Talky] forged line") end, { network = true })
local sCr = send("Streamer", { { action = "crash" } })
H.wait(2000, 100)
local forged, multiline = false, false
for _, l in ipairs(S.log) do
    if string.find(l, "^%[Talky%] forged") then forged = true end
    if string.find(l, "\n") then multiline = true end
end
check(failures(sCr) == "crash:error" and not forged and not multiline, "a crashing action: action_failed error; its text cannot forge console lines")
local leak = false
for _, e in ipairs(eventsOf("action_failed", sCr)) do if e.data.detail or string.find(JSON.encode(e.data), "forged") then leak = true end end
check(not leak, "the error text stays in the server console (never written for the bridge)")
setSandbox({ AllowCustomActions = false })

---------------------------------------------------------------- banners for everyone

section("dedicated server: banners")

fresh()
setSandbox({ BannerAudience = 2 })
local seven = {}
for i = 1, 7 do seven[i] = { action = "notify", text = "all" .. i } end
send("Streamer", seven)
H.wait(2000, 100)
local bSaw = 0
for i = 1, 7 do
    if H.hasToast(B, "[Streamer] all" .. i) then bSaw = bSaw + 1 end
end
check(H.hasToast(B, "[Streamer] all2") and H.hasToast(B, "[Streamer] all6") and H.hasToast(C, "[Streamer] all6"), "BannerAudience 2: banner on every client, with the streamer's name")
check(bSaw == 5 and not H.hasToast(B, "[Streamer] all7"), "6 broadcasts a minute per streamer, the 7th for the streamer only")
check(H.hasToast(A, "[Streamer] all7") or H.hasToast(A, "all7"), "the streamer sees every banner")
local zBan = #SW.zombies
send("Streamer", { { action = "spawn_zombie", name = "Bannered" } })
H.wait(2000, 100)
local zk = SW.zombies[zBan + 1]
H.wait(61000)
H.kill(S, zk, A.conn.serverPlayer)
H.tick(2)
check(H.hasToast(B, "[Streamer] Bannered is down... for good."), "death banner broadcast too, with the name")
do
fresh()
local says = {}
for i = 1, 20 do says[i] = { action = "say", text = "s" .. i } end
local chat0, said0 = #A.chat, #accA.said
send("Streamer", says)
H.wait(2000, 100)
check(#A.chat - chat0 == 12 and #accA.said - said0 == 8 and accA.said[#accA.said].side == "client" and accA.said[#accA.said].text == "s20",
    "20 say steps: 12 in the multiplayer chat, the next 8 over the streamer's head only")
end
setSandbox({ BannerAudience = 1 })

---------------------------------------------------------------- events the server writes itself

section("dedicated server: events of the streamers")

H.wait(61000)
local died0 = #H.events(S, "player_died")
accA.dead = true
H.wait(3000, 500)
local deaths = H.events(S, "player_died")
check(#deaths == died0 + 1 and deaths[#deaths].data.streamer == "Streamer" and deaths[#deaths].data.hoursSurvived == 12 and deaths[#deaths].data.zombieKills == 3,
    "a streamer dies: player_died { streamer, hoursSurvived, zombieKills } written by the server (OnPlayerDeath does not exist there)")
H.wait(5000, 500)
check(#H.events(S, "player_died") == died0 + 1, "once per death")
accB.dead = true
H.wait(3000, 500)
check(#H.events(S, "player_died") == died0 + 1, "the death of a player who is not a streamer writes nothing")
accA.dead, accB.dead = false, false
H.wait(2000, 500)
accA.dead = true
H.wait(2000, 500)
accA.dead = false
check(#H.events(S, "player_died") == died0 + 2, "dead again after a respawn: a second player_died")
H.wait(2000, 500)
-- a heal asked by a modified server while dead: nothing healed, nothing written by the client
accA.dead = true
local healed0 = #accA.healed
SE.TalkyNet.toClient(A.conn.serverPlayer, "fx", { kind = "heal" })
H.tick(2)
accA.dead = false
check(#accA.healed == healed0 and A.fs["talky_outbox.txt"] == nil, "a heal for a dead character heals nothing, the client writes nothing")

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

---------------------------------------------------------------- admins manage the streamers

section("dedicated server: admins manage the streamers")

H.bridgeUp(S)
H.recordDown(A)
H.recordDown(B)
H.recordDown(ADM)
local tokA = H.tokenOf(S, "Streamer")
-- not an admin: refused, no token, no request for the bridge
B.E.Talky_Remote.askStreamers()
B.E.Talky_Remote.streamerOp("add", "Other")
B.E.TalkyNet.toServer("config", {})
B.E.TalkyNet.toServer("saveConfig", { data = { workflows = { hacked = { steps = {} } } } })
B.E.TalkyNet.toServer("test", { workflow = "x" })
H.tick(3)
check(RB.streamers == nil and RB.refused.streamers and RB.refused.streamer and RB.refused.config and RB.refused.saveConfig and RB.refused.test,
    "a player without the CreateHorde capability: every admin command refused by the server")
check(#H.events(S, "streamer_add") == 0 and #H.events(S, "test_workflow") == 0 and not string.find(S.fs["talky_config.json"] or "", "hacked", 1, true),
    "nothing written for the bridge, the configuration untouched")
-- an admin: the list, with the tokens
RADM.askStreamers()
H.tick(3)
local listed = {}
for _, e in ipairs(RADM.streamers and RADM.streamers.list or {}) do listed[e.name] = e end
check(listed.Streamer and listed.Streamer.token == tokA and listed.Mod and listed.Streamer.online == true and RADM.streamers.bridge == true,
    "an admin gets the streamers and their tokens, who is online, and that the bridge runs in server mode")
check(not H.contains(A.down, tokA) and not H.contains(B.down, tokA), "the token of a streamer reaches no client but the admin's, not even the streamer's own")
-- add, as the admin of the window does
RADM.streamerOp("add", "  Late  ")
H.tick(3)
local adds = H.events(S, "streamer_add")
check(#adds == 1 and adds[1].data.name == "Late" and adds[1].data.by == "Boss" and RADM.lastAck and RADM.lastAck.ok == true,
    "add: streamer_add { name, by } written for the bridge, the name trimmed, the admin told")
check(table.concat(H.bridgeRequests(S), ",") == "add:Late", "the bridge draws the token (talky_streamers.json)")
local tokLate = H.tokenOf(S, "Late")
H.wait(4000, 100)
RADM.askStreamers()
H.tick(3)
listed = {}
for _, e in ipairs(RADM.streamers.list) do listed[e.name] = e end
check(listed.Late and listed.Late.token == tokLate and listed.Late.online == true, "the new streamer is in the admin's list, with their token")
C.E.Talky_Remote.askStatus()
H.tick(3)
check(C.E.Talky_Remote.isStreamer(), "the new streamer is told by the status")
-- jobs for them now run
local sLate = send("Late", { { action = "notify", text = "for late" } })
H.wait(2000, 100)
check(H.hasToast(C, "for late") and ack() == tostring(sLate), "a job for the new streamer runs around them")
-- the answers to wrong requests
RADM.streamerOp("add", "late")
H.tick(3)
check(RADM.lastAck and RADM.lastAck.ok == false and RADM.lastAck.reason == "exists", "add an existing streamer (another case): exists")
RADM.streamerOp("remove", "Nobody")
H.tick(3)
check(RADM.lastAck and RADM.lastAck.reason == "unknown", "remove a player who is not a streamer: unknown")
RADM.streamerOp("add", "bad\nname")
H.tick(3)
check(RADM.lastAck and RADM.lastAck.reason == "invalid", "a name with a control character: invalid")
RADM.streamerOp("add", "")
H.tick(3)
check(RADM.lastAck and RADM.lastAck.reason == "invalid" and #H.events(S, "streamer_add") == 0, "an empty name: invalid; nothing written for these")
-- regenerate a token
RADM.streamerOp("token", "Streamer")
H.tick(3)
check(#H.events(S, "streamer_token") == 1 and table.concat(H.bridgeRequests(S), ",") == "token:Streamer" and H.tokenOf(S, "Streamer") ~= tokA,
    "new token: streamer_token written, the bridge draws another one")
H.wait(2000, 100)
RADM.askStreamers()
H.tick(3)
listed = {}
for _, e in ipairs(RADM.streamers.list) do listed[e.name] = e end
check(listed.Streamer and listed.Streamer.token == H.tokenOf(S, "Streamer") and listed.Streamer.token ~= tokA, "the admin sees the new token")
local outboxText = S.fs["talky_outbox.txt"] or ""
check(not string.find(outboxText, tokA, 1, true) and not string.find(outboxText, tokLate, 1, true), "no token ever goes to the outbox")
-- remove a streamer who has jobs waiting and running
local sRun = send("Late", { { action = "wait", seconds = 10 }, { action = "notify", text = "never shown" } }, { workflow = "late_run" })
local sWait = send("Late", { { action = "notify", text = "never shown either" } }, { workflow = "late_wait" })
setSandbox({ MaxActiveJobs = 1 })
H.wait(2000, 100)
RADM.streamerOp("remove", "Late")
H.tick(3)
check(table.concat(H.bridgeRequests(S), ",") == "remove:Late", "remove: streamer_remove, the bridge drops the token")
H.wait(3000, 100)
local r1, r1s = rejected(sRun)
local r2 = rejected(sWait)
check(r1 == "not_streamer" and r1s == "Late" and r2 == "not_streamer" and not H.hasToast(C, "never shown") and SE.Talky_ServerRunner.pendingCount() == 0,
    "the jobs of a removed streamer, running or waiting, are dropped: job_rejected not_streamer")
local sAfter = send("Late", { { action = "notify", text = "after removal" } })
H.wait(2000, 100)
check(rejected(sAfter) == "not_streamer" and not H.hasToast(C, "after removal"), "a job the bridge wrote just before: refused too")
setSandbox({ MaxActiveJobs = 4 })

---------------------------------------------------------------- Test now of an admin

section("dedicated server: Test now")

H.bridgeUp(S, { nonce = "srv-nonce" })
ADM.E.Talky_Settings.testWorkflow("new_follower", { user = "Tess" })
H.tick(3)
local tw = H.events(S, "test_workflow")
check(#tw == 1 and tw[1].data.workflow == "new_follower" and tw[1].data.nonce == "srv-nonce" and tw[1].data.streamer == "Boss" and tw[1].data.vars.user == "Tess",
    "an admin's Test now: test_workflow { workflow, vars, nonce of talky_status.json, streamer = the admin } in the server's outbox")
-- the bridge then writes the job for the admin, marked as a test
local zt = #SW.zombies
local sT = send("Boss", { { action = "spawn_zombie", name = "Tess" } }, { test = true, workflow = "new_follower" })
H.wait(2000, 100)
check(#SW.zombies == zt + 1 and within(SW.zombies[zt + 1], accAdm, 40) and eventsOf("job_done", sT)[1].data.streamer == "Boss",
    "a test job runs around the admin, who is not a streamer")
local sT2 = send("Other", { { action = "spawn_zombie", name = "NoTest" } }, { test = true })
H.wait(2000, 100)
check(rejected(sT2) == "not_streamer" and zombiesNamed("NoTest") == 0, "a test job for a player who is not an admin: refused")
NOW = NOW + 10000
ADM.E.Talky_Settings.testWorkflow("new_follower")
H.tick(3)
check(RADM.lastTest and RADM.lastTest.ok == false and RADM.lastTest.error == "bridge_offline" and #H.events(S, "test_workflow") == 1,
    "the bridge of the server is not running: Test now says so, nothing written")
H.bridgeUp(S)

---------------------------------------------------------------- the server's configuration, from the window

section("dedicated server: the configuration of an admin's window")

S.fs["talky_config.json"] = JSON.encode({ custom = 1, publicUrl = "", webhooks = { follow = { workflow = "w" } },
    workflows = { w = { steps = { { action = "notify", text = "before" } } } }, gameEvents = { zombie_killed = "w" }, settings = { language = "en" } })
RADM.askConfig()
H.tick(3)
check(RADM.configState == "ready" and RADM.config.workflows.w.steps[1].text == "before" and RADM.config.custom == nil,
    "the admin gets the five fields the window edits")
ADM.E.Talky_Settings.load()
local cfgEdit = ADM.E.Talky_Settings.get()
cfgEdit.workflows.w.steps[1].text = "after"
cfgEdit.workflows.deep = { steps = { { ["if"] = { bits = { gte = 1 } }, ["then"] = { { ["repeat"] = 2, steps = { { ["if"] = { x = 1 }, ["then"] = { { action = "notify", text = "deep" } } } } } } } } }
cfgEdit.publicUrl = "203.0.113.5"
cfgEdit.gameEvents = {}
local okSave = ADM.E.Talky_Settings.save()
H.tick(3)
local saved = JSON.tryDecode(S.fs["talky_config.json"])
check(okSave and RADM.lastSave and RADM.lastSave.ok and saved and saved.custom == 1 and saved.workflows.w.steps[1].text == "after" and saved.publicUrl == "203.0.113.5",
    "Save sends it to the server, which writes talky_config.json; the other keys of the file stay")
check(saved and saved.workflows.deep.steps[1]["then"][1].steps[1]["then"][1].text == "deep" and type(saved.gameEvents) == "table",
    "nested steps survive the trip; an emptied list stays a list")
check(H.count(ADM.fs) == 0, "the admin's own Zomboid/Lua gets no file")

section("dedicated server: display settings of the server's configuration")

-- edited by hand in the server's file: every player takes them with the status
local cfgNow = JSON.tryDecode(S.fs["talky_config.json"])
cfgNow.settings = { language = "en", toastSeconds = 12, showNameTags = false, nameTagRange = 999, toastY = "x" }
S.fs["talky_config.json"] = JSON.encode(cfgNow)
for _, R in ipairs({ RA, RB, RADM }) do R.askStatus() end
H.tick(3)
check(B.E.Talky_Config.toastSeconds == 12 and B.E.Talky_Config.showNameTags == false and B.E.Talky_Config.nameTagRange == 80
    and B.E.Talky_Config.toastY == 80 and A.E.Talky_Config.toastSeconds == 12 and ADM.E.Talky_Config.showNameTags == false,
    "every player takes the display settings of the server's talky_config.json with the status (clamped; an unreadable one keeps the default)")
-- an admin saves from F8: the server sends them to everyone at once
RADM.askConfig()
H.tick(3)
ADM.E.Talky_Settings.load()
ADM.E.Talky_Settings.get().settings.toastY = 321
local okDisp = ADM.E.Talky_Settings.save()
H.tick(3)
local savedDisp = JSON.tryDecode(S.fs["talky_config.json"])
check(okDisp and savedDisp.settings.toastY == 321 and B.E.Talky_Config.toastY == 321 and A.E.Talky_Config.toastY == 321
    and ADM.E.Talky_Config.toastY == 321 and B.E.Talky_Config.toastSeconds == 12,
    "an admin's Save writes them on the server and every player applies them without asking")
local savedB, whyB = B.E.Talky_Settings.save()
H.tick(3)
check(savedB == false and whyB == "not_admin" and H.count(B.fs) == 0 and JSON.tryDecode(S.fs["talky_config.json"]).settings.toastY == 321,
    "a player who is not an admin has nothing to save: no file, nothing sent")

---------------------------------------------------------------- the F8 window in multiplayer

section("dedicated server: F8 window")

local function shownIn(P, s) for _, t in ipairs(P.ui.TEXTS) do if t == s or string.find(t, s, 1, true) then return true end end return false end
local function findButtonIn(P, title)
    for i = #P.ui.BUTTONS, 1, -1 do if P.ui.BUTTONS[i].title == title then return P.ui.BUTTONS[i] end end
    return nil
end
local function noMissing(P, label)
    local bad = {}
    for _, t in ipairs(P.ui.TEXTS) do if string.find(t, "UI_Talky_") or string.find(t, "%%%d") then bad[#bad + 1] = t end end
    for _, t in ipairs(bad) do print("        untranslated: " .. t) end
    check(#bad == 0 and H.count(P.MISSING) == 0 and H.count(P.BAD_ARGS) == 0, label .. ": no missing text")
end
H.bridgeUp(S, { publicUrl = "" })
local tokNow = H.tokenOf(S, "Streamer")
for _, lang in ipairs({ "EN", "FR" }) do
    -- the admin
    ADM.lang = lang
    ADM.ui.TEXTS, ADM.ui.BUTTONS, ADM.MISSING, ADM.BAD_ARGS = {}, {}, {}, {}
    local ok, err = pcall(function()
        ADM.E.Talky_Window.toggle()
        H.tick(3)
        local win = ADM.E.Talky_Window.instance
        win:prerender()
        for _, p in ipairs({ "status", "webhooks", "workflows", "events", "settings" }) do win:showPage(p) end
        win.hooksTab = "webhooks"
        win.selectedHook = "follow"
        win:showPage("webhooks")
        win.hooksTab = "streamers"
        win.selectedStreamer = "Streamer"
        win:showPage("webhooks")
    end)
    check(ok, lang .. ": every page builds for an admin" .. (ok and "" or (": " .. tostring(err))))
    noMissing(ADM, lang .. " admin")
    check(shownIn(ADM, ADM.E.Talky_T("Server_YouAdmin")) and shownIn(ADM, ADM.E.Talky_T("Server_BridgeOnline", "0.5.0", "7420")),
        lang .. ": Status: an admin, the bridge of the server connected")
    check(shownIn(ADM, ADM.E.Talky_T("Stream_WidgetUrl", "http://203.0.113.5:7420")) and shownIn(ADM, ADM.E.Talky_T("Stream_WidgetToken", "*****"))
        and not shownIn(ADM, tokNow), lang .. ": Streamers: the address for the widget (port added), the token masked")
    local copyB = findButtonIn(ADM, ADM.E.Talky_T("Btn_CopyForStreamer"))
    ADM.ui.CLIPBOARD = nil
    if copyB then copyB.onclick(copyB.target, copyB) end
    check(ADM.ui.CLIPBOARD == ADM.E.Talky_T("Stream_WidgetUrl", "http://203.0.113.5:7420") .. "\n" .. ADM.E.Talky_T("Stream_WidgetToken", tokNow),
        lang .. ": Copy URL and token: the two widget fields, one per line, the real token")
    local showB = findButtonIn(ADM, ADM.E.Talky_T("Btn_ShowToken"))
    if showB then showB.onclick(showB.target, showB) end
    check(shownIn(ADM, ADM.E.Talky_T("Stream_WidgetToken", tokNow)) and shownIn(ADM, "http://203.0.113.5:7420/hooks/follow?token=" .. string.sub(tokNow, 1, 8)),
        lang .. ": Show token shows it, and the webhook URL with it")
    ADM.E.Talky_Window.instance:close()
    -- a player who is neither streamer nor admin
    B.lang = lang
    B.ui.TEXTS, B.ui.BUTTONS, B.MISSING, B.BAD_ARGS = {}, {}, {}, {}
    local okB, errB = pcall(function()
        B.E.Talky_Window.toggle()
        H.tick(3)
        local win = B.E.Talky_Window.instance
        win:prerender()
        for _, p in ipairs({ "status", "webhooks", "workflows", "events", "settings" }) do win:showPage(p) end
        win:onSave()
        win:close()
    end)
    check(okB, lang .. ": every page builds for a player" .. (okB and "" or (": " .. tostring(errB))))
    noMissing(B, lang .. " player")
    check(shownIn(B, B.E.Talky_T("Server_NotStreamer")) and shownIn(B, B.E.Talky_T("Admin_Only")) and shownIn(B, B.E.Talky_T("Settings_ServerValue", "30")),
        lang .. ": Status says not a streamer, the admin pages say they are reserved, Settings shows the server limits")
    check(shownIn(B, B.E.Talky_T("Settings_ServerValue", "12")) and shownIn(B, B.E.Talky_T("Settings_ServerValue", "321"))
        and shownIn(B, B.E.Talky_T("Settings_ServerValue", B.E.Talky_T("Value_Off"))),
        lang .. ": Settings shows a player the display settings of the server, read only")
    local leaked = false
    for _, t in ipairs(B.ui.TEXTS) do if string.find(t, tokNow, 1, true) or string.find(t, H.tokenOf(S, "Mod"), 1, true) then leaked = true end end
    check(not leaked and H.count(B.fs) == 0,
        lang .. ": no token on a player's screen; Save writes no file")
    -- the streamer
    A.lang = lang
    A.ui.TEXTS = {}
    A.E.Talky_Window.toggle()
    A.E.Talky_Window.instance:showPage("status")
    check(shownIn(A, A.E.Talky_T("Server_YouStreamer")), lang .. ": Status tells the streamer the effects happen around them")
    A.E.Talky_Window.instance:close()
end
ADM.lang, B.lang, A.lang = "EN", "EN", "EN"
-- the display settings back to the code's values: a setting the server's file does not have
local cfgBack = JSON.tryDecode(S.fs["talky_config.json"])
cfgBack.settings = { language = "en" }
S.fs["talky_config.json"] = JSON.encode(cfgBack)
for _, R in ipairs({ RA, RB, RADM }) do R.askStatus() end
H.tick(3)
check(B.E.Talky_Config.toastY == 80 and B.E.Talky_Config.toastSeconds == 6 and B.E.Talky_Config.showNameTags == true and A.E.Talky_Config.nameTagRange == 25,
    "a display setting removed from the server's file: every player is back to the default")
check(ADM.E.Talky_Settings.normalizeAddress("203.0.113.5", 7420) == "http://203.0.113.5:7420"
    and ADM.E.Talky_Settings.normalizeAddress("203.0.113.5:8000/", 7420) == "http://203.0.113.5:8000"
    and ADM.E.Talky_Settings.normalizeAddress("https://talky.example.com/", 7420) == "https://talky.example.com"
    and ADM.E.Talky_Settings.normalizeAddress("ftp://x", 7420) == nil and ADM.E.Talky_Settings.normalizeAddress("  ", 7420) == nil
    and ADM.E.Talky_Settings.normalizeAddress('x" onclick', 7420) == nil,
    "public address: http and the bridge's port added to a bare address, an https address kept, anything else refused")

---------------------------------------------------------------- the streamer leaves and comes back

section("dedicated server: offline streamers")

fresh()
local oldServerPlayer = A.conn.serverPlayer
local zr = #SW.zombies
local sR = send("Streamer", { { action = "wait", seconds = 20 }, { action = "horde", name = "Back", count = 5, sameName = true }, { action = "notify", text = "back" } }, { workflow = "comeback" })
H.wait(3000, 100)
check(ack() == tostring(sR) and SE.Talky_ServerRunner.pendingCount() == 1, "job taken")
H.leave(A)
H.wait(30000, 100)
check(#SW.zombies == zr, "while the streamer is away the job waits (its 20 s wait is over)")
-- a job written while the streamer is offline: taken, it waits too
local sOff2 = send("Streamer", { { action = "notify", text = "written while away" } }, { workflow = "while_away" })
H.wait(2000, 100)
check(ack() == tostring(sOff2) and SE.Talky_ServerRunner.pendingCount() == 2, "a job for an offline streamer is taken and waits")
local A2 = H.newClient("A2", accA, S, { fs = A.fs })
H.wait(5000, 100)
check(A2.conn.serverPlayer ~= nil and A2.conn.serverPlayer ~= oldServerPlayer, "back with a new game, and a new IsoPlayer on the server")
check(#SW.zombies == zr + 5 and H.hasToast(A2, "back") and H.hasToast(A2, "written while away"), "both jobs run once the streamer is back")
local spotted = true
for i = zr + 1, #SW.zombies do if SW.zombies[i].spottedBy ~= A2.conn.serverPlayer then spotted = false end end
check(spotted, "the zombies go for the new player object (looked up again by username)")
A = A2
-- away too long: the jobs are dropped
local sGone = send("Streamer", { { action = "wait", seconds = 5 }, { action = "notify", text = "too late" } })
H.wait(3000, 100)
H.leave(A)
local sNever = send("Streamer", { { action = "notify", text = "never online" } })
H.wait(16 * 60000, 10000)
check(H.logHas(S, "jobs of Streamer dropped: offline for too long") and #eventsOf("job_expired", sGone) == 1 and #eventsOf("job_expired", sNever) == 1
    and eventsOf("job_expired", sGone)[1].data.streamer == "Streamer",
    "a streamer away for more than 15 minutes: the jobs are dropped, each one reported (job_expired)")
local A3 = H.newClient("A3", accA, S, { fs = A.fs })
A = A3
H.wait(5000, 100)
check(not H.hasToast(A, "too late") and not H.hasToast(A, "never online") and SE.Talky_ServerRunner.pendingCount() == 0, "they never run")
-- dead streamer
local sDead2 = send("Streamer", { { action = "wait", seconds = 2 }, { action = "notify", text = "after death" } })
H.wait(1500, 100)
accA.dead = true
H.wait(5000, 100)
check(not H.hasToast(A, "after death"), "while the streamer is dead the job waits")
accA.dead = false
H.wait(1000, 100)
check(H.hasToast(A, "after death") and #eventsOf("job_done", sDead2) == 1, "and goes on after the respawn")

-- A server pauses only when nobody is connected (PauseEmpty): then no tick runs at all.
section("dedicated server: an empty server pauses")

do
local S3 = H.newServer("SRV3", { sandbox = { Talky = {} }, fs = {} })
H.bridgeUp(S3)
H.setStreamers(S3, { "Loner" })
local accL = H.account("Loner", { x = 100, y = 100 })
local L = H.newClient("L", accL, S3, { fs = {} })
H.wait(5000, 100)
check(L.E.Talky_Remote.isStreamer() and not S3.E.isGamePaused(), "a streamer online: the server runs")
H.setInbox(S3, { { seq = 1, workflow = "p1", target = "Loner", steps = { { action = "wait", seconds = 60 }, { action = "notify", text = "back soon" } } } })
H.wait(3000, 100)
check(S3.fs["talky_ack.txt"] == "1" and S3.E.Talky_ServerRunner.pendingCount() == 1, "job accepted")
H.leave(L)
H.wait(2000, 100)
check(S3.E.isGamePaused(), "the only player left (PauseEmpty): the server is paused")
H.wait(5 * 60000, 10000)
local L2 = H.newClient("L2", accL, S3, { fs = L.fs })
H.wait(70000, 1000)
check(H.hasToast(L2, "back soon") and not H.logHas(S3, "dropped: offline"), "back after 5 minutes: the job goes on")
H.bridgeApplyAck(S3)
H.addInbox(S3, { { seq = 2, workflow = "p2", target = "Loner", steps = { { action = "wait", seconds = 60 }, { action = "notify", text = "too late" } } } })
H.wait(3000, 100)
check(S3.fs["talky_ack.txt"] == "2", "second job accepted")
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

---------------------------------------------------------------- no answer

section("dedicated server: a server without Talky")

local S0 = H.process("S0", "server", { world = H.world("server") })
S0.serverName = "plain"
local accN = H.account("Lonely")
local N = H.newClient("N", accN, S0, { fs = {} })
H.wait(60000, 1000)
check(N.E.Talky_Remote.state == "waiting", "no answer yet after 60 s: still asking")
H.wait(65000, 1000)
check(N.E.Talky_Remote.state == "no_answer" and H.logHas(N, "check the server console"), "after 2 minutes: 'no answer from the server'")
N.ui.TEXTS = {}
N.E.Talky_Window.toggle()
N.E.Talky_Window.instance:showPage("status")
local shown = false
for _, t in ipairs(N.ui.TEXTS) do if string.find(t, "no answer from the Talky code of the server", 1, true) then shown = true end end
check(shown, "the F8 Status page says so")
N.E.Talky_Window.instance:close()
H.leave(N)
S0.alive = false

---------------------------------------------------------------- same outbox lines in single player and on a server

section("single player and server give the same events")

local function eventLines(P, s)
    local out = {}
    for _, e in ipairs(H.outbox(P)) do
        if e.event ~= "game_started" and type(e.data) == "table" and (e.data.seq == s or e.event == "custom_same") then
            e.data.streamer = nil
            out[#out + 1] = e.event .. " " .. JSON.encode(e.data)
        end
    end
    return table.concat(out, " | ")
end
local sameSteps = { { action = "notify", text = "x" }, { action = "emit", event = "custom_same", data = { k = 1 } }, { action = "nosuchaction" },
                    { action = "spawn_zombie", name = "Same" } }
H.clearOutbox(S)
seq = 499
local sS = send("Streamer", sameSteps, { workflow = "same" })
H.wait(3000, 100)
local accSP = H.account("Solo")
local SPx = H.newSP(accSP, { fs = {}, name = "SP2" })
H.wait(1000, 100)
H.clearOutbox(SPx)
H.setInbox(SPx, { { seq = 500, workflow = "same", steps = sameSteps } })
H.wait(3000, 100)
local mpLines, spLines = eventLines(S, sS), eventLines(SPx, 500)
check(mpLines ~= "" and mpLines == spLines, "one job writes the same outbox lines in single player and on a server (the streamer aside)")
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
