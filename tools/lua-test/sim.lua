-- Lua tests of the Talky mod, run in Kahlua (the game's Lua VM) by LuaSim.java; see
-- tools/test-lua.ps1. harness.lua fakes the game: one Lua state per game process (single
-- player game, dedicated server, hosted game, clients), the network between them and the
-- world API with the behaviour of each side. The scenarios:
--   test_files.lua   sources, translations, sandbox options, network copy rules
--   test_solo.lua    single player: the F8 window, jobs end to end, caps (0.3.0 behaviour)
--   test_server.lua  dedicated server with several clients: permissions, relay, acks, caps,
--                    budgets, name tags, events back to the bridge, reconnects
--   test_lifecycle.lua  one streamer over a session: restart with holes in the ack file,
--                    permission taken away and given back, a job expiring in the server queue
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
