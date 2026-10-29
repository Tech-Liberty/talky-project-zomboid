-- Lua tests of the Talky mod, run in Kahlua (the game's Lua VM) by LuaSim.java; see
-- tools/test-lua.ps1. harness.lua fakes the game: one Lua state per game process (single
-- player game, dedicated server, hosted game, clients), the network between them and the
-- world API with the behaviour of each side. The scenarios:
--   test_files.lua   sources, translations, sandbox options, network copy rules, no relay left
--   test_solo.lua    single player: the F8 window, jobs end to end, caps (0.3.0 behaviour)
--   test_server.lua  dedicated server in server mode, several clients: the jobs of the bridge
--                    routed by target, admins managing the streamers, acks, caps, budgets,
--                    name tags, events for the bridge, offline streamers, the F8 window
--   test_lifecycle.lua  a server over its life: restart with holes in the ack file, a streamer
--                    removed and added again, a job expiring in the queue, a seq given again
--   test_hosted.lua  hosted game: the host's client and the coop server share Zomboid/Lua
-- Set H.verbose = true below to print every console line of every process.

__FAILURES = 0
TOTAL = 0
NOW = 1000000

function check(cond, msg)
    TOTAL = TOTAL + 1
    if cond then
        print("  ok    " .. msg)
    else
        __FAILURES = __FAILURES + 1
        print("  FAIL  " .. msg)
    end
end

function section(name)
    print("")
    print(name)
end

local function loadTestFile(name)
    local fn, err = __load(_G, __TEST_DIR .. "/" .. name, name)
    if not fn then error("cannot load " .. name .. ": " .. tostring(err or "missing file")) end
    return fn
end

loadTestFile("harness.lua")()
H.verbose = false

print("network args copied with " .. tostring(__NET_COPY))

for _, name in ipairs({ "test_files.lua", "test_solo.lua", "test_server.lua", "test_lifecycle.lua", "test_hosted.lua" }) do
    H.reset()
    local ok, err = pcall(loadTestFile(name))
    if not ok then
        __FAILURES = __FAILURES + 1
        TOTAL = TOTAL + 1
        print("  FAIL  " .. name .. " stopped: " .. tostring(err))
    end
end

print("")
print((TOTAL - __FAILURES) .. "/" .. TOTAL .. " passed")
