-- A dedicated server over its life, in server mode: it starts again with an ack file that has
-- holes, a streamer is removed then added again, a job expires in the server queue, and the
-- bridge, having lost its state, gives a seq again.

local JSON = H.JSON

local SANDBOX = { Talky = {} }
local TV = SANDBOX.Talky

local function setSandbox(values)
    for k, v in pairs(values) do TV[k] = v end
    NOW = NOW + 1100
end

local function notifyJob(seq, opts)
    local j = { seq = seq, target = "Streamer", steps = { { action = "notify", text = "j" .. seq } } }
    for k, v in pairs(opts or {}) do j[k] = v end
    return j
end

local function count(list, pred)
    local n = 0
    for _, e in ipairs(list) do if pred(e) then n = n + 1 end end
    return n
end

---------------------------------------------------------------- restart with holes in the ack file

section("lifecycle: the server starts again with an ack file that has holes")

-- the server took jobs 1, 2 and 4 before it stopped (3 waited behind a full queue)
local fs = {}
H.setInbox({ fs = fs }, { notifyJob(1), notifyJob(2), notifyJob(3), notifyJob(4), notifyJob(5) })
fs["talky_ack.txt"] = "2 4\n"
local S = H.newServer("SRV2", { sandbox = SANDBOX, fs = fs })
H.bridgeUp(S)
H.setStreamers(S, { "Streamer", "Oldie" })
local accA = H.account("Streamer", { x = 100, y = 100 })
local A = H.newClient("A", accA, S, { fs = {} })
H.wait(5000, 100)
local SI = S.E.Talky_Inbox
check(SI.started and H.logHas(S, "inbox ready, last seq = 2 %(server%)"), "ack file '2 4' read back at the first read: S = 2")
check(H.hasToast(A, "j3") and H.hasToast(A, "j5"), "jobs 3 and 5 taken and run")
check(not H.hasToast(A, "j1") and not H.hasToast(A, "j2") and not H.hasToast(A, "j4"), "jobs 1, 2 and 4 never run again")
check(fs["talky_ack.txt"] == "5", "ack file: '5' (" .. tostring(fs["talky_ack.txt"]) .. ")")

-- an ack file of Talky 0.3.0 ("S", no line end), on another server
local fsO = {}
H.setInbox({ fs = fsO }, { notifyJob(6, { target = "Oldie" }), notifyJob(7, { target = "Oldie" }), notifyJob(8, { target = "Oldie" }) })
fsO["talky_ack.txt"] = "7"
local SO = H.newServer("SRVO", { sandbox = { Talky = {} }, fs = fsO })
H.bridgeUp(SO)
H.setStreamers(SO, { "Oldie" })
local accO = H.account("Oldie", { x = 600, y = 600 })
local O = H.newClient("O", accO, SO, { fs = {} })
H.wait(5000, 100)
check(SO.E.Talky_Inbox.lastSeq == 8 and H.hasToast(O, "j8") and not H.hasToast(O, "j6") and not H.hasToast(O, "j7") and fsO["talky_ack.txt"] == "8",
    "a 0.3.0 ack file '7' is read as S = 7: only job 8 runs; ack file '8'")

---------------------------------------------------------------- a streamer removed, then added again

section("lifecycle: a streamer removed, then added again")

S.streamers = { { name = "Oldie", token = H.newToken() } }
H.writeStreamers(S)
H.bridgeApplyAck(S)
H.addInbox(S, { notifyJob(6, { workflow = "late_perm" }) })
H.wait(2000, 100)
local rj = H.events(S, "job_rejected")
check(fs["talky_ack.txt"] == "6" and #rj == 1 and rj[1].data.seq == 6 and rj[1].data.reason == "not_streamer" and rj[1].data.workflow == "late_perm"
    and rj[1].data.streamer == "Streamer", "the next job is refused for good: acked, job_rejected { reason = not_streamer, streamer }")
check(not H.hasToast(A, "j6") and H.logHas(S, "job 6 refused: not_streamer"), "never run; the server console says why")
S.streamers[#S.streamers + 1] = { name = "Streamer", token = H.newToken() }
H.writeStreamers(S)
H.bridgeApplyAck(S)
H.addInbox(S, { notifyJob(7) })
H.wait(2000, 100)
check(H.hasToast(A, "j7") and fs["talky_ack.txt"] == "7", "added again (a new token): the next job runs")

---------------------------------------------------------------- a job that expires in the server queue

section("lifecycle: a job that waits too long in the server queue")

setSandbox({ MaxActiveJobs = 1 })
H.bridgeApplyAck(S)
H.addInbox(S, {
    { seq = 8, workflow = "long", target = "Streamer", steps = { { action = "wait", seconds = 30 }, { action = "notify", text = "j8" } } },
    { seq = 9, workflow = "short_life", target = "Streamer", expiresAt = NOW + 10000, steps = { { action = "notify", text = "j9" } } },
})
H.wait(3000, 100)
check(fs["talky_ack.txt"] == "9" and S.E.Talky_ServerRunner.pendingCount() == 2, "both jobs accepted; the second waits behind the first (MaxActiveJobs = 1)")
H.wait(12000, 100)
local je = H.events(S, "job_expired")
check(#je == 1 and je[1].data.seq == 9 and je[1].data.workflow == "short_life" and je[1].data.streamer == "Streamer",
    "past its time to live in the queue: job_expired { seq, workflow, streamer } for the bridge")
H.wait(20000, 100)
check(H.hasToast(A, "j8") and not H.hasToast(A, "j9") and S.E.Talky_ServerRunner.pendingCount() == 0, "the first job finished, the expired one never ran")
setSandbox({ MaxActiveJobs = 4 })

---------------------------------------------------------------- a seq given again

section("lifecycle: the bridge lost its state and gives a seq again")

-- job 11 waits in the inbox (rate limited); the bridge loses bridge-state.json and writes a new
-- job with the same seq 11 (another createdAt, so another id): only the new one runs
H.wait(61000)
setSandbox({ MaxJobsPerMinute = 1 })
H.bridgeApplyAck(S)
local oldCreated = NOW - 5000
H.addInbox(S, { notifyJob(10, { workflow = "ten" }), notifyJob(11, { createdAt = oldCreated, workflow = "old_11", steps = { { action = "notify", text = "old11" } } }) })
H.wait(1500, 100)
check(fs["talky_ack.txt"] == "10" and not H.hasToast(A, "old11"), "job 10 taken, job 11 waits (one job a minute)")
H.setInbox(S, { notifyJob(11, { workflow = "new_11", steps = { { action = "notify", text = "new11" } } }) })
setSandbox({ MaxJobsPerMinute = 30 })
H.wait(62000, 500)
check(H.hasToast(A, "new11") and not H.hasToast(A, "old11") and fs["talky_ack.txt"] == "11", "the new job 11 is taken, runs and is acked; the old one never ran")
local done11 = count(H.events(S, "job_done"), function(e) return e.data.seq == 11 and e.data.workflow == "new_11" end)
check(done11 == 1, "its job_done carries its own workflow")

---------------------------------------------------------------- an unreadable ack file

section("lifecycle: an unreadable ack file")

fsO["talky_ack.txt"] = "garbage\n"
SO.E.Talky_Inbox.loadAck()
check(SO.E.Talky_Inbox.lastSeq == 0 and SO.E.TalkyNet.isEmpty(SO.E.Talky_Inbox.acked), "no number in the ack file: S = 0, nothing taken")

H.tick(3)
H.hygiene(S, "SRV2")
H.hygiene(SO, "SRVO")
H.hygiene(A, "A")
H.hygiene(O, "O")
