-- A streamer's game over a session on a dedicated server: it starts again with an ack file
-- that has holes, loses its permission and gets it back, has a job that expires in the
-- server queue, and sends a job twice after a lost answer.

local SANDBOX = { Talky = { AllowedPlayers = "streamer, oldie" } }
local S = H.newServer("SRV2", { sandbox = SANDBOX })
local TV = SANDBOX.Talky

-- sandbox values are read again after 1 s (Talky_Config.readSandbox cache)
local function setSandbox(values)
    for k, v in pairs(values) do TV[k] = v end
    NOW = NOW + 1100
end

local function notifyJob(seq, opts)
    local j = { seq = seq, steps = { { action = "notify", text = "j" .. seq } } }
    for k, v in pairs(opts or {}) do j[k] = v end
    return j
end

local function count(list, pred)
    local n = 0
    for _, e in ipairs(list) do if pred(e) then n = n + 1 end end
    return n
end

---------------------------------------------------------------- restart with holes in the ack file

section("lifecycle: the game starts again with an ack file that has holes")

-- the previous game took jobs 1, 2 and 4 (an answer for 3 never came), then quit
local fs = {}
H.setInbox({ fs = fs }, { notifyJob(1), notifyJob(2), notifyJob(3), notifyJob(4), notifyJob(5) })
fs["talky_ack.txt"] = "2 4\n"
local accA = H.account("Streamer", { x = 100, y = 100 })
local A = H.newClient("A", accA, S, { fs = fs })
local AB = A.E.Talky_Bridge
check(AB.lastSeq == 2 and AB.acked[4] == true and AB.acked[3] == nil, "ack file '2 4' read back at game start: S = 2, job 4 taken")
H.wait(5000, 100)
check(AB.hello.state == "allowed", "allowed")
check(H.hasToast(A, "j3") and H.hasToast(A, "j5"), "jobs 3 and 5 sent and run")
check(not H.hasToast(A, "j1") and not H.hasToast(A, "j2") and not H.hasToast(A, "j4"), "jobs 1, 2 and 4 never sent again")
check(fs["talky_ack.txt"] == "5", "ack file: '5' (" .. tostring(fs["talky_ack.txt"]) .. ")")

-- an ack file of Talky 0.3.0 ("S", no line end)
local fsO = {}
H.setInbox({ fs = fsO }, { notifyJob(6), notifyJob(7), notifyJob(8) })
fsO["talky_ack.txt"] = "7"
local accO = H.account("Oldie", { x = 600, y = 600 })
local O = H.newClient("O", accO, S, { fs = fsO })
check(O.E.Talky_Bridge.lastSeq == 7 and O.E.TalkyNet.isEmpty(O.E.Talky_Bridge.acked), "a 0.3.0 ack file '7' is read as S = 7")
H.wait(5000, 100)
check(H.hasToast(O, "j8") and not H.hasToast(O, "j6") and not H.hasToast(O, "j7") and fsO["talky_ack.txt"] == "8",
    "only job 8 is sent; ack file '8'")

---------------------------------------------------------------- permission taken away during the game

section("lifecycle: permission taken away, then given back")

setSandbox({ AllowedPlayers = "oldie" })
H.bridgeApplyAck(A)
H.addInbox(A, { notifyJob(6, { workflow = "late_perm" }) })
H.wait(2000, 100)
local rj = H.events(A, "job_rejected")
check(fs["talky_ack.txt"] == "6" and #rj == 1 and rj[1].data.seq == 6 and rj[1].data.reason == "not_allowed" and rj[1].data.workflow == "late_perm",
    "the next job is refused for good: acked, job_rejected { reason = not_allowed }")
check(not H.hasToast(A, "j6") and H.hasToast(A, A.E.Talky_T("Toast_JobRejected", 6, A.E.Talky_T("Reason_not_allowed"))),
    "never run; the refusal toast says why")
check(AB.hello.state == "denied" and H.logHas(S, "streamer: jobs refused: not allowed"), "the client stops relaying; the server console says why")
local sentBefore = A.sent.jobs or 0
H.bridgeApplyAck(A)
H.addInbox(A, { notifyJob(7) })
H.wait(10000, 100)
check(fs["talky_ack.txt"] == "6" and not H.hasToast(A, "j7") and (A.sent.jobs or 0) == sentBefore, "while refused, a new job stays in the inbox, unsent")
setSandbox({ AllowedPlayers = "Streamer, oldie" })
H.wait(31000, 500)
check(AB.hello.state == "allowed" and H.hasToast(A, "j7") and fs["talky_ack.txt"] == "7",
    "permission given back: accepted at the next hello (every 30 s), the waiting job runs")

---------------------------------------------------------------- a job that expires in the server queue

section("lifecycle: a job that waits too long in the server queue")

setSandbox({ MaxActiveJobs = 1 })
H.bridgeApplyAck(A)
H.addInbox(A, {
    { seq = 8, workflow = "long", steps = { { action = "wait", seconds = 30 }, { action = "notify", text = "j8" } } },
    { seq = 9, workflow = "short_life", expiresAt = NOW + 10000, steps = { { action = "notify", text = "j9" } } },
})
H.wait(3000, 100)
check(fs["talky_ack.txt"] == "9" and S.E.Talky_ServerRunner.pendingCount() == 2, "both jobs accepted; the second waits behind the first (MaxActiveJobs = 1)")
H.wait(12000, 100)
local je = H.events(A, "job_expired")
check(#je == 1 and je[1].data.seq == 9 and je[1].data.workflow == "short_life", "past its time to live in the queue: job_expired for the bridge")
H.wait(20000, 100)
check(H.hasToast(A, "j8") and not H.hasToast(A, "j9") and S.E.Talky_ServerRunner.pendingCount() == 0, "the first job finished, the expired one never ran")
setSandbox({ MaxActiveJobs = 4 })

---------------------------------------------------------------- a job sent twice

section("lifecycle: a job sent twice after a lost answer")

H.net.dropDown = function(m) return m.conn.client == A and m.command == "jobAcks" end
H.bridgeApplyAck(A)
H.addInbox(A, { { seq = 10, steps = { { action = "fly_to_moon" }, { action = "notify", text = "j10" } } } })
H.wait(3000, 100)
H.net.dropDown = nil
check(fs["talky_ack.txt"] == "9" and H.hasToast(A, "j10"), "the job ran, its answer was lost: not acked")
H.wait(31000, 500)
local fails = count(H.events(A, "action_failed"), function(e) return e.data.seq == 10 end)
local runs = count(H.toastTexts(A), function(t) return t == "j10" end)
check(fs["talky_ack.txt"] == "10" and fails == 1 and runs == 1, "sent again, answered duplicate: acked; one action_failed and one run, not two")

---------------------------------------------------------------- a seq given again

section("lifecycle: the bridge lost its state and gives a seq again")

-- job 11 is sent and lost on the way; the bridge loses bridge-state.json and writes a new job
-- with the same seq 11 (another createdAt, so another id); a late answer about the first one
-- must not take the new one
H.net.dropUp = function(m) return m.conn.client == A and m.command == "jobs" end
H.bridgeApplyAck(A)
local oldCreated = NOW - 5000
H.addInbox(A, { notifyJob(11, { createdAt = oldCreated, workflow = "old_11", steps = { { action = "notify", text = "old11" } } }) })
H.wait(1500, 100)
local oldId = "11:" .. string.format("%.0f", oldCreated)
check(AB.pending[oldId] ~= nil, "job 11 read and sent (lost on the way)")
H.setInbox(A, { notifyJob(11, { workflow = "new_11", steps = { { action = "notify", text = "new11" } } }) })
H.wait(1100, 100)
local newP
for _, p in pairs(AB.pending) do if p.seq == 11 then newP = p end end
check(AB.pending[oldId] == nil and newP ~= nil and newP.id ~= oldId, "the inbox read again: the new job 11 is pending, the old one is gone")
A.E.Talky_Client.dispatch("jobAcks", { list = { { seq = 11, id = oldId, ok = true } } })
A.E.Talky_Client.dispatch("jobAcks", { list = { { seq = 11, id = "11:12345", reason = "duplicate" } } })
check(fs["talky_ack.txt"] == "10" and newP and AB.pending[newP.id] == newP, "answers naming another job 11 ack nothing")
H.net.dropUp = nil
H.wait(31000, 500)
check(H.hasToast(A, "new11") and not H.hasToast(A, "old11") and fs["talky_ack.txt"] == "11", "the new job 11 is sent again, runs and is acked")
local done11 = count(H.events(A, "job_done"), function(e) return e.data.seq == 11 and e.data.workflow == "new_11" end)
check(done11 == 1, "its job_done carries its own workflow (found by the job id)")

---------------------------------------------------------------- an unreadable ack file

section("lifecycle: an unreadable ack file")

fsO["talky_ack.txt"] = "garbage\n"
O.E.Talky_Bridge.loadAck()
check(O.E.Talky_Bridge.lastSeq == 0 and O.E.TalkyNet.isEmpty(O.E.Talky_Bridge.acked), "no number in the ack file: S = 0, nothing taken")

H.tick(3)
H.hygiene(S, "SRV2")
H.hygiene(A, "A")
H.hygiene(O, "O")
