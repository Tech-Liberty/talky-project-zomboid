-- Game action registry, shared by single player and the Talky server code (the job runner
-- lives in server/Talky/Talky_ServerRunner.lua; in single player server/ files run too).
-- Each handler receives (params, player, job, ctx):
--   player = the streamer's IsoPlayer (the target of the job), job = { seq, id, workflow, user },
--   ctx    = { mode, caps, owner, now, reserve, refund, cooldown, broadcastOk, sayOk, emit }
--            (see Talky_Actions.context).
-- A handler returns nil when done, or a short code ("cooldown", "no_square"...) when it
-- could not act; it raises an error only for bugs.
--
-- Where each effect happens:
--   world : here (server, or the single player game): zombies, items, weather...
--   owner : on the streamer's own client (heal), sent with TalkyNet.toClient "fx"
--   ui    : on the client too (notify, say, halo); emit writes an event for the bridge here
--           (ctx.emit: the outbox of the server, or of the single player game)
--
-- Add your own with Talky_Actions.register("name", function(p, player, job, ctx) ... end, opts).
-- opts (optional) = { side = "world", category = "...", network = true, params = { key = "string"|"number"|"bool" } }.
-- In single player every registered action runs, as in 0.3.0. On a server only actions with
-- network = true run, when the sandbox option Talky.AllowCustomActions is on, and only the
-- declared params reach them.
-- Never require a client/ file here: this file also runs on the dedicated server.

require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"

Talky_Actions = { handlers = {}, meta = {} }

local str, bool, color = TalkyNet.str, TalkyNet.bool, TalkyNet.color

-- Strict number (TalkyNet.num) whose default is clamped too, like 0.3.0. def = nil -> nil.
local function num(v, def, lo, hi)
    local n = TalkyNet.num(v, nil, lo, hi)
    if n ~= nil or def == nil then return n end
    if def < lo then return lo elseif def > hi then return hi end
    return def
end

local function normParams(params)
    local out = {}
    if type(params) ~= "table" then return out end
    for key, spec in pairs(params) do
        if type(key) == "string" then
            if spec == "number" then out[key] = { t = "n" }
            elseif spec == "bool" or spec == "boolean" then out[key] = { t = "b" }
            elseif spec == "string" then out[key] = { t = "s", max = 200 }
            elseif type(spec) == "table" and spec.t then out[key] = spec end
        end
    end
    return out
end

function Talky_Actions.register(name, fn, opts)
    Talky_Actions.handlers[name] = fn
    opts = type(opts) == "table" and opts or {}
    Talky_Actions.meta[name] = {
        custom = true,
        side = opts.side or "world",
        category = opts.category,
        network = opts.network == true,
        params = normParams(opts.params),
    }
end

-- Built-in actions: network-safe, typed parameters.
local function builtin(name, meta, fn)
    Talky_Actions.handlers[name] = fn
    meta.builtin = true
    meta.network = true
    meta.params = meta.params or {}
    Talky_Actions.meta[name] = meta
end

-- Context used when an action runs outside the job runner (Talky_Actions.run).
function Talky_Actions.context(owner)
    return {
        mode = TalkyNet.mode(),
        caps = Talky_Config.caps(),
        owner = owner or "",
        now = getTimestampMs(),
        reserve = function(_, n) return n end,
        refund = function() end,
        cooldown = function() return true end,
        broadcastOk = function() return true end,
        sayOk = function() return true end,
        emit = function() return false end,
    }
end

-- Events an emit step may not write: only the game itself writes them (test_workflow,
-- game_started, player_died), they report a refusal (job_rejected, job_expired), or they ask
-- the bridge to change the streamers of a server (streamer_*).
Talky_Actions.RESERVED_EVENTS = {
    test_workflow = true, game_started = true, player_died = true, job_rejected = true, job_expired = true,
    streamer_add = true, streamer_remove = true, streamer_token = true,
}

-- Runs one step now. Raises an error when the action is unknown or fails (0.3.0 behaviour).
function Talky_Actions.run(step, player, job, ctx)
    local fn = Talky_Actions.handlers[step.action]
    if not fn then error("unknown action '" .. tostring(step.action) .. "'") end
    ctx = ctx or Talky_Actions.context(TalkyNet.username(player))
    local code = fn(step, player, job or {}, ctx)
    if type(code) == "string" then error(code) end
end

-- Runs one step and returns nil, or a failure code ("error" when the handler raised one,
-- with the error text as second value).
function Talky_Actions.exec(step, player, job, ctx)
    local fn = Talky_Actions.handlers[step.action]
    if not fn then return "unknown_action" end
    local ok, res = pcall(fn, step, player, job, ctx)
    if not ok then return "error", tostring(res) end
    if type(res) == "string" then return res end
    return nil
end

---------------------------------------------------------------- step validation

-- Clean copy of a step that came from a job: only the declared parameters, with their
-- type and hard bounds; any other value (tables, Java objects...) is dropped.
-- Returns step, nil, action  or  nil, code, action  (code = invalid | unknown_action | disabled).
-- A step that cannot be read (not a table, no action, or a name with other characters than
-- letters, digits and _) is reported with action "step": the client only passes names that
-- match ^[%w_]+$ on to the bridge.
function Talky_Actions.sanitizeStep(step, index, caps)
    if type(step) ~= "table" then return nil, "invalid", "step" end
    local action = str(step.action, 32, nil)
    if not action or not string.match(action, "^[%w_]+$") then return nil, "invalid", "step" end
    local meta = Talky_Actions.meta[action]
    if not Talky_Actions.handlers[action] or not meta then return nil, "unknown_action", action end
    if meta.custom then
        if not caps.enforce then
            -- single player: the step as it came, like 0.3.0
            local copy = TalkyNet.copy(step) or {}
            copy._i = index
            return copy, nil, action
        end
        if not meta.network then return nil, "unknown_action", action end
        if not Talky_Config.categoryAllowed("custom", caps) then return nil, "disabled", action end
    elseif not Talky_Config.categoryAllowed(meta.category, caps) then
        return nil, "disabled", action
    end
    local clean = { action = action, _i = index }
    for key, spec in pairs(meta.params) do
        local v = step[key]
        if v ~= nil and not (spec.spOnly and caps.enforce) then
            if spec.t == "n" then
                v = num(v, nil, spec.lo or -1000000, spec.hi or 1000000)
            elseif spec.t == "s" then
                v = str(v, spec.max or 200, nil)
            elseif spec.t == "b" then
                local t = type(v)
                if t == "boolean" or t == "string" or t == "number" then v = bool(v, false) else v = nil end
            elseif spec.t == "c" then
                v = color(v, nil)
            elseif spec.t == "d" then
                -- plain data (the event of an emit step): a copy, 8 levels and 8 KB at most
                if type(v) == "table" then v = TalkyNet.copy(v, 8) or {} else v = nil end
                if v ~= nil and TalkyNet.netSize(v) > 8192 then v = nil end
            else
                v = nil
            end
            if v ~= nil then clean[key] = v end
        end
    end
    return clean, nil, action
end

-- "wait" length in ms (each wait is capped so a job cannot hold a slot for ever).
function Talky_Actions.waitMs(step)
    return num(step and step.seconds, 1, 0, Talky_Config.maxWaitSeconds) * 1000
end

---------------------------------------------------------------- helpers

-- Server: no effect inside another player's safehouse, nor near another online player
-- (sandbox Talky.ProtectRadius). Always true in single player.
function Talky_Actions.squareAllowed(sq, player, caps)
    if not caps or not caps.enforce then return true end
    if SafeHouse and SafeHouse.getSafeHouse then
        local ok, sh = pcall(function() return SafeHouse.getSafeHouse(sq) end)
        if ok and sh then
            local ok2, allowed = pcall(function() return sh:playerAllowed(player) end)
            if not ok2 or not allowed then return false end
        end
    end
    local r = caps.protectRadius or 0
    if r > 0 then
        local ok, near = pcall(function()
            local list = getOnlinePlayers()
            local me = TalkyNet.userKey(player)
            local x, y = sq:getX(), sq:getY()
            for i = 0, list:size() - 1 do
                local o = list:get(i)
                if o and TalkyNet.userKey(o) ~= me and not o:isDead() then
                    local dx, dy = o:getX() - x, o:getY() - y
                    if dx * dx + dy * dy <= r * r then return true end
                end
            end
            return false
        end)
        if not ok or near then return false end
    end
    return true
end

-- Random free square on the player's floor, between minDist and maxDist tiles away.
-- Single player: falls back to the player's square (0.3.0). Server: nil when none fits.
local function findSquare(player, minDist, maxDist, outsideOnly, ctx)
    local cell = getCell()
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    local caps = ctx and ctx.caps
    local strict = caps and caps.enforce
    for _ = 1, 40 do
        local a = ZombRandFloat(0, 6.2832)
        local d = ZombRandFloat(minDist, maxDist)
        local sq = cell:getGridSquare(math.floor(px + math.cos(a) * d), math.floor(py + math.sin(a) * d), pz)
        if sq and sq:isFree(false) and (not outsideOnly or sq:isOutside())
            and (not strict or Talky_Actions.squareAllowed(sq, player, caps)) then
            return sq
        end
    end
    if strict then return nil end
    return player:getCurrentSquare()
end
Talky_Actions.findSquare = findSquare

local function aggro(zombie, player)
    if not pcall(function() zombie:spotted(player, true) end) then
        pcall(function() zombie:pathToCharacter(player) end)
    end
end

-- Texts shown in game are capped (the bridge applies the same cap).
local function clipText(v)
    return str(v, Talky_Config.maxTextLength, "") or ""
end
Talky_Actions.clipText = clipText

local function soundName(v)
    local s = str(v, 64, nil)
    if s and string.match(s, "^[%w_%.%-]+$") then return s end
    return nil
end

-- Sound heard around the player: by every nearby client on a server, locally otherwise.
local function playSound(player, name)
    if TalkyNet.mode() == "server" then
        playServerSound(name, player:getCurrentSquare())
    else
        player:getEmitter():playSound(name)
    end
end

-- Name list of a sandbox string option ("a, b; c"), lower-cased.
local function listHas(list, value)
    if type(list) ~= "string" or list == "" then return false end
    value = string.lower(value)
    for entry in string.gmatch(list, "[^,;%s]+") do
        if string.lower(entry) == value then return true end
    end
    return false
end
Talky_Actions.listHas = listHas

-- Banner: to the streamer, or to everyone when the server says so (Talky.BannerAudience = 2),
-- then prefixed with the streamer's name on the other clients.
function Talky_Actions.banner(player, args, ctx)
    local caps = ctx and ctx.caps
    if caps and caps.enforce and caps.audience == 2 and (not ctx.broadcastOk or ctx.broadcastOk()) then
        args.from = TalkyNet.str(ctx.owner, 32, "")
        TalkyNet.broadcast("fx", args)
    else
        TalkyNet.toClient(player, "fx", args)
    end
end

local function tag(zombie, label, col, owner)
    if Talky_Tags and Talky_Tags.tag then Talky_Tags.tag(zombie, label, col, owner) end
end

---------------------------------------------------------------- feedback (client side)

local S = function(max) return { t = "s", max = max } end
local N = function(lo, hi) return { t = "n", lo = lo, hi = hi } end
local B = { t = "b" }
local C = { t = "c" }

builtin("notify", { side = "ui", params = { text = S(200), color = C, seconds = N(1, 60) } }, function(p, player, job, ctx)
    Talky_Actions.banner(player, {
        kind = "notify",
        text = clipText(p.text),
        color = color(p.color, nil),
        seconds = num(p.seconds, nil, 1, Talky_Config.maxToastSeconds),
    }, ctx)
end)

-- In multiplayer the line goes to the public chat of the players nearby (and to the radios of
-- the streamer's channel): on a server at most Talky_Config.maxSayPerMinute a minute per
-- streamer and maxSayPerMinuteServer in all; beyond, "quiet" = the overhead line only.
builtin("say", { side = "ui", params = { text = S(200) } }, function(p, player, job, ctx)
    local fx = { kind = "say", text = clipText(p.text) }
    if ctx and ctx.caps and ctx.caps.enforce and ctx.sayOk and not ctx.sayOk() then fx.quiet = true end
    TalkyNet.toClient(player, "fx", fx)
end)

builtin("halo", { side = "ui", params = { text = S(200) } }, function(p, player)
    TalkyNet.toClient(player, "fx", { kind = "halo", text = clipText(p.text) })
end)

-- An event for the bridge, written where the job runs (ctx.emit: the outbox next to the
-- inbox the job came from). Server mode: with the streamer of the job.
builtin("emit", { side = "ui", params = { event = S(64), data = { t = "d" } } }, function(p, player, job, ctx)
    local event = str(p.event, 64, nil) or "custom"
    if event == "" then event = "custom" end
    if Talky_Actions.RESERVED_EVENTS[event] then return "invalid" end
    if not ctx or not ctx.emit or not ctx.emit(event, type(p.data) == "table" and p.data or {}) then return "error" end
end)

builtin("wait", { side = "world", params = { seconds = N(0, 600) } }, function() end)

---------------------------------------------------------------- zombies

local SPAWN_PARAMS = {
    name = S(40), count = N(1, 300), distance = N(2, 150), minDistance = N(1, 150), radius = N(0, 20),
    outfit = S(80), health = N(0.1, 10), color = C, crawler = B, onFire = B, fakeDead = B,
    aggro = B, outside = B, cluster = B, sameName = B,
}

-- Cluster member square: re-checked on a server, otherwise the plain offset (0.3.0).
local function clusterXY(plan, player, ctx)
    local cx, cy = plan.cx, plan.cy
    if not ctx.caps.enforce then
        return cx + ZombRand(-plan.radius, plan.radius + 1), cy + ZombRand(-plan.radius, plan.radius + 1)
    end
    local cell = getCell()
    for _ = 1, 6 do
        local x = cx + ZombRand(-plan.radius, plan.radius + 1)
        local y = cy + ZombRand(-plan.radius, plan.radius + 1)
        local sq = cell:getGridSquare(x, y, plan.cz)
        if sq and sq:isFree(false) and Talky_Actions.squareAllowed(sq, player, ctx.caps) then return x, y end
    end
    return cx, cy
end

-- Prepares a spawn: count capped by the action cap, then by ctx.reserve (job and
-- 10-minute budgets on a server). Returns plan, or nil and a code.
-- defaults: { count, distance, radius, forceCluster } (horde).
function Talky_Actions.planSpawn(p, player, ctx, defaults)
    defaults = defaults or {}
    local caps = ctx.caps
    local want = math.floor(num(p.count, defaults.count or 1, 1, caps.maxZombiesPerAction))
    local maxD = num(p.distance, defaults.distance or 12, 2, caps.maxSpawnDistance)
    local minD = num(p.minDistance, math.max(2, maxD * 0.6), 1, maxD)
    local outside = bool(p.outside, false)
    local cluster = defaults.forceCluster == true or bool(p.cluster, false)
    local outfit = str(p.outfit, 80, nil)
    if outfit == "" or outfit == "random" then outfit = nil end
    local onFire = bool(p.onFire, false)
    if not Talky_Config.categoryAllowed("fire", caps) then onFire = false end
    local plan = {
        want = want, count = want, done = 0, skipped = 0, made = 0,
        minD = minD, maxD = maxD, outside = outside, cluster = cluster,
        radius = num(p.radius, defaults.radius or 3, 0, 20),
        outfit = outfit, crawler = bool(p.crawler, false), fakeDead = bool(p.fakeDead, false), onFire = onFire,
        health = num(p.health, 1, 0.1, 10), aggro = bool(p.aggro, true),
        name = str(p.name, Talky_Config.maxNameLength, "") or "", sameName = bool(p.sameName, false),
        color = color(p.color, nil),
    }
    if cluster then
        local sq = findSquare(player, minD, maxD, outside, ctx)
        if not sq then return nil, "no_square" end
        plan.cx, plan.cy, plan.cz = sq:getX(), sq:getY(), sq:getZ()
    end
    if ctx.reserve then
        plan.count = math.floor(ctx.reserve("zombies", want))
        plan.reservedAt = ctx.now
    end
    if plan.count < 1 then return nil, "budget" end
    return plan
end

-- Failure code of a finished plan that created no zombie: no free square for any of them, or
-- the game created none ("refused": zombies turned off in the world, no square there, no free
-- zombie id - addZombiesInOutfit then returns an empty list). nil when one at least was made.
function Talky_Actions.spawnFailure(plan)
    if plan.made > 0 then return nil end
    if plan.skipped >= plan.count then return "no_square" end
    return "refused"
end

-- Spawns up to n more zombies of a plan. Returns how many were created.
function Talky_Actions.spawnSome(plan, player, n, ctx)
    local made = 0
    local last = math.min(plan.count, plan.done + n)
    for i = plan.done + 1, last do
        plan.done = i
        local x, y, z
        if plan.cluster then
            z = plan.cz
            if plan.radius > 0 then x, y = clusterXY(plan, player, ctx) else x, y = plan.cx, plan.cy end
        else
            local sq = findSquare(player, plan.minD, plan.maxD, plan.outside, ctx)
            if sq then x, y, z = sq:getX(), sq:getY(), sq:getZ() end
        end
        if x then
            -- B42 signature: x, y, z, count, outfit, femaleChance, crawler, isFallOnFront, isFakeDead,
            -- knockedDown, isInvulnerable, isSitting, health, isRecordingAnims, heightOffset, isRagdolling, onFire
            local list = addZombiesInOutfit(x, y, z, 1, plan.outfit, 50, plan.crawler, false, plan.fakeDead,
                                            false, false, false, plan.health, false, 0, false, plan.onFire)
            if not list or list:size() == 0 then
                plan.empty = (plan.empty or 0) + 1
            else
                for j = 0, list:size() - 1 do
                    local zed = list:get(j)
                    made = made + 1
                    if plan.name ~= "" then
                        local label = plan.name
                        if plan.count > 1 and not plan.sameName then
                            -- the number always fits: the name is shortened to make room for it
                            local suffix = " #" .. i
                            label = TalkyNet.cut(plan.name, Talky_Config.maxNameLength - string.len(suffix)) .. suffix
                        end
                        tag(zed, label, plan.color, ctx.owner)
                    end
                    if plan.aggro then aggro(zed, player) end
                end
            end
        else
            plan.skipped = plan.skipped + 1
        end
    end
    plan.made = plan.made + made
    return made
end

-- spawn_zombie: name, count, distance, minDistance, outfit, crawler, health, onFire,
--               fakeDead, aggro, cluster (all in one spot), radius, color, sameName, outside
builtin("spawn_zombie", { side = "world", category = "zombies", spawn = {}, params = SPAWN_PARAMS }, function(p, player, job, ctx)
    local plan, code = Talky_Actions.planSpawn(p, player, ctx)
    if not plan then return code end
    Talky_Actions.spawnSome(plan, player, plan.count, ctx)
    return Talky_Actions.spawnFailure(plan)
end)

-- Shortcut for a big group spawned around one spot.
local HORDE = { count = 15, radius = 5, distance = 25, forceCluster = true }
builtin("horde", { side = "world", category = "zombies", spawn = HORDE, params = SPAWN_PARAMS }, function(p, player, job, ctx)
    local plan, code = Talky_Actions.planSpawn(p, player, ctx, HORDE)
    if not plan then return code end
    Talky_Actions.spawnSome(plan, player, plan.count, ctx)
    return Talky_Actions.spawnFailure(plan)
end)

---------------------------------------------------------------- world

-- Server: noise and sound share a budget (Talky_Config.maxSoundsPer10Min per player): each
-- one reaches every client nearby, and one job could otherwise play 100 in one tick.
local function soundBudget(ctx)
    return not ctx.caps.enforce or ctx.reserve("sounds", 1) >= 1
end

-- Noise that attracts every zombie within radius.
builtin("noise", { side = "world", category = "sounds", params = { radius = N(1, 300), volume = N(1, 300), sound = S(64) } }, function(p, player, job, ctx)
    if not soundBudget(ctx) then return "budget" end
    local maxR = ctx.caps.maxNoiseRadius
    local radius = math.floor(num(p.radius, math.min(60, maxR), 1, maxR))
    addSound(player, math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()),
             radius, math.floor(num(p.volume, radius, 1, maxR)))
    local s = soundName(p.sound)
    if s then playSound(player, s) end
end)

builtin("sound", { side = "world", category = "sounds", params = { name = S(64) } }, function(p, player, job, ctx)
    local s = soundName(p.name or "ZombieSurprisedPlayer")
    if not s then return "not_found" end
    if not soundBudget(ctx) then return "budget" end
    playSound(player, s)
end)

-- On a server the helicopter goes to a random player (Lua cannot aim it).
builtin("helicopter", { side = "world", category = "helicopter" }, function(p, player, job, ctx)
    local caps = ctx.caps
    if caps.enforce then
        local list = getOnlinePlayers()
        if not caps.sandbox.HelicopterAnyTarget and list and list:size() > 1 then return "helicopter_random_target" end
        if not ctx.cooldown("helicopter", caps.sandbox.HelicopterCooldownMinutes * 60000) then return "cooldown" end
    end
    testHelicopter()
end)

builtin("thunder", { side = "world", category = "weather", params = { strike = B } }, function(p, player, job, ctx)
    local caps = ctx.caps
    if caps.enforce and not ctx.cooldown("thunder", caps.sandbox.ThunderCooldownSeconds * 1000) then return "cooldown" end
    getClimateManager():getThunderStorm():triggerThunderEvent(math.floor(player:getX()), math.floor(player:getY()),
                                                              bool(p.strike, false), true, true)
end)

-- weather: type = storm | blizzard | tropical | clear; hours = duration (game hours).
-- Single player also accepts a raw "stage" number (0.3.0).
local WEATHER_STAGES = { storm = 3, blizzard = 7, tropical = 8 }
builtin("weather", { side = "world", category = "weather", params = { type = S(16), hours = N(1, 72), stage = { t = "n", lo = 0, hi = 11, spOnly = true } } }, function(p, player, job, ctx)
    local caps = ctx.caps
    local stage
    if not caps.enforce then stage = TalkyNet.int(p.stage, nil, 0, 11) end
    local clear = false
    if stage == nil then
        local kind = str(p.type, 16, "storm")
        if kind == "clear" then
            clear = true
        else
            stage = WEATHER_STAGES[kind]
            if not stage then return "not_found" end
        end
    end
    if caps.enforce and not ctx.cooldown("weather", caps.sandbox.WeatherCooldownMinutes * 60000) then return "cooldown" end
    local clim = getClimateManager()
    -- A storm is refused while another weather period runs: stop it first.
    clim:stopWeatherAndThunder()
    if clear then return end
    local hours = num(p.hours, 6, 1, caps.maxWeatherHours)
    if TalkyNet.mode() == "server" and stage == 3 then
        clim:transmitServerTriggerStorm(hours)
    elseif not clim:triggerCustomWeatherStage(stage, hours) then
        return "refused"
    end
end)

builtin("time", { side = "world", category = "time", params = { hour = N(0, 23.99) } }, function(p, player, job, ctx)
    local caps = ctx.caps
    if caps.enforce and not ctx.cooldown("time", caps.sandbox.TimeCooldownMinutes * 60000) then return "cooldown" end
    getGameTime():setTimeOfDay(num(p.hour, 0, 0, 23.99))
end)

-- Server: Talky_Config.maxFiresPer10Min per player and maxFiresPer10MinServer in all (a fire
-- spreads); the budget is taken once a square is found, like vehicles.
builtin("fire", { side = "world", category = "fire", params = { minDistance = N(1, 30), distance = N(2, 40) } }, function(p, player, job, ctx)
    local sq = findSquare(player, num(p.minDistance, 3, 1, 30), num(p.distance, 6, 2, 40), false, ctx)
    if not sq then return "no_square" end
    if ctx.caps.enforce and ctx.reserve("fires", 1) < 1 then return "budget" end
    IsoFireManager.StartFire(getCell(), sq, true, 100, 500)
end)

local function vehicleExists(script)
    local ok, v = pcall(function() return getScriptManager():getVehicle(script) end)
    return ok and v ~= nil
end

builtin("vehicle", { side = "world", category = "vehicles", params = { script = S(80), distance = N(4, 40) } }, function(p, player, job, ctx)
    local script = str(p.script, 80, "Base.CarNormal")
    if not vehicleExists(script) then return "not_found" end
    if ctx.caps.enforce and math.floor(player:getZ()) ~= 0 then return "no_square" end
    local sq = findSquare(player, 4, num(p.distance, 8, 4, 40), true, ctx)
    if not sq then return "no_square" end
    if ctx.caps.enforce and ctx.reserve("vehicles", 1) < 1 then return "budget" end
    addVehicleDebug(script, IsoDirections.S, nil, sq)
end)

---------------------------------------------------------------- player

-- Server: full type exactly as in the scripts, not obsolete nor hidden, not in Talky.ItemDenylist.
local function itemAllowed(item, caps)
    local ok, s = pcall(function() return getScriptManager():FindItem(item) end)
    if not ok or s == nil then return false end
    if not caps.enforce then return true end
    local ok2, good = pcall(function() return s:getFullName() == item and not s:getObsolete() and not s:isHidden() end)
    if not ok2 or not good then return false end
    return not listHas(caps.sandbox.ItemDenylist, item)
end

builtin("give_item", { side = "world", category = "items", params = { item = S(80), count = N(1, 100), onGround = B } }, function(p, player, job, ctx)
    local caps = ctx.caps
    local item = str(p.item, 80, "Base.Apple")
    if not itemAllowed(item, caps) then return "not_found" end
    local count = math.floor(num(p.count, 1, 1, caps.maxItemsPerAction))
    if caps.enforce then
        count = math.floor(ctx.reserve("items", count))
        if count < 1 then return "budget" end
    end
    if bool(p.onGround, false) then
        local sq = player:getCurrentSquare()
        if not sq then return "no_square" end
        -- the text overload sends the item to the clients on a server
        for _ = 1, count do sq:AddWorldInventoryItem(item, 0.5, 0.5, 0) end
    else
        local inv = player:getInventory()
        local items = inv:AddItems(item, count)
        if TalkyNet.mode() == "server" and items then sendAddItemsToContainer(inv, items) end
    end
end)

-- Health is owned by the player's client in multiplayer: healed there.
builtin("heal", { side = "owner", category = "playerEffects" }, function(p, player)
    if player:isDead() then return "dead" end
    TalkyNet.toClient(player, "fx", { kind = "heal" })
end)

-- stat: stat = CharacterStat name (PANIC, STRESS, FATIGUE, HUNGER, THIRST, INTOXICATION...),
--       op = set | add | remove, value
local STAT_NAMES = {}
for _, s in ipairs({ "ANGER", "BOREDOM", "DISCOMFORT", "ENDURANCE", "FATIGUE", "FITNESS", "FOOD_SICKNESS", "HUNGER",
    "IDLENESS", "INTOXICATION", "MORALE", "NICOTINE_WITHDRAWAL", "PAIN", "PANIC", "POISON", "SANITY", "SICKNESS",
    "STRESS", "TEMPERATURE", "THIRST", "UNHAPPINESS", "WETNESS", "ZOMBIE_FEVER", "ZOMBIE_INFECTION" }) do
    STAT_NAMES[s] = true
end

builtin("stat", { side = "world", category = "playerEffects", params = { stat = S(32), op = S(8), value = N(-1000, 1000) } }, function(p, player)
    local name = string.upper(str(p.stat, 32, "") or "")
    if not STAT_NAMES[name] or not CharacterStat[name] then return "not_found" end
    local stat = CharacterStat[name]
    local stats = player:getStats()
    local value = num(p.value, 0, -1000, 1000)
    local op = str(p.op, 8, "add")
    if op == "set" then stats:set(stat, value)
    elseif op == "remove" then stats:remove(stat, value)
    else stats:set(stat, stats:get(stat) + value) end
    if TalkyNet.mode() == "server" then
        syncPlayerStats(player, SyncPlayerStatsPacket.getBitMaskForStat(stat))
    end
end)

-- Perks.<name>: a skill, never None/MAX; on a server only leaf skills (not the categories).
local function perkAllowed(perk, strict)
    -- static methods of Perks come back as functions
    local t = type(perk)
    if perk == nil or t == "function" or t == "string" or t == "number" or t == "boolean" then return false end
    if perk == Perks.None or perk == Perks.MAX then return false end
    if not strict then return true end
    local ok, parent = pcall(function() return perk:getParent() end)
    return ok and parent ~= nil and parent ~= Perks.None
end

builtin("xp", { side = "world", category = "xp", params = { perk = S(32), amount = N(0, 10000) } }, function(p, player, job, ctx)
    local caps = ctx.caps
    local name = str(p.perk, 32, "") or ""
    if not string.match(name, "^%a+$") then return "not_found" end
    local perk = Perks[name]
    if not perkAllowed(perk, caps.enforce) then return "not_found" end
    local amount = num(p.amount, 10, 0, caps.maxXpPerAction)
    if caps.enforce then
        -- whole amounts on a server (single player keeps the fractions of 0.3.0)
        amount = math.floor(amount)
        if amount < 1 then return "invalid" end
        amount = ctx.reserve("xp", amount)
        if amount <= 0 then return "budget" end
    end
    addXp(player, perk, amount)
end)

---------------------------------------------------------------- schema for the editor window
-- Every field is typed as text so it can hold a template ({{user}}, {{bits | div:100}}...),
-- except "bool" (tick box) and "choice" (combo). "where" = game | bridge.
-- Labels are translation keys (labelKey -> UI_Talky_<labelKey>); a schema entry added by
-- another mod may use a plain "label" instead. "defaultKey" = translated default text.

local T, NUM, BOOL = "text", "number", "bool"
Talky_Actions.schema = {
    { action = "notify", labelKey = "Act_notify", params = {
        { key = "text", labelKey = "Param_Text", type = T, defaultKey = "Default_notify" },
        { key = "color", labelKey = "Param_Color", type = T, default = "#b388ff" },
        { key = "seconds", labelKey = "Param_Duration", type = NUM } } },
    { action = "spawn_zombie", labelKey = "Act_spawn_zombie", params = {
        { key = "name", labelKey = "Param_Name", type = T, default = "{{user}}" },
        { key = "count", labelKey = "Param_Count", type = NUM, default = "1" },
        { key = "distance", labelKey = "Param_MaxDistance", type = NUM, default = "14" },
        { key = "minDistance", labelKey = "Param_MinDistance", type = NUM },
        { key = "outfit", labelKey = "Param_Outfit", type = T },
        { key = "health", labelKey = "Param_Health", type = NUM },
        { key = "color", labelKey = "Param_NameColor", type = T, default = "#b388ff" },
        { key = "crawler", labelKey = "Param_Crawler", type = BOOL },
        { key = "onFire", labelKey = "Param_OnFire", type = BOOL },
        { key = "fakeDead", labelKey = "Param_FakeDead", type = BOOL },
        { key = "sameName", labelKey = "Param_SameName", type = BOOL },
        { key = "aggro", labelKey = "Param_Aggro", type = BOOL, default = true } } },
    { action = "horde", labelKey = "Act_horde", params = {
        { key = "name", labelKey = "Param_NameOptional", type = T, defaultKey = "Default_horde" },
        { key = "count", labelKey = "Param_Count", type = NUM, default = "15" },
        { key = "distance", labelKey = "Param_Distance", type = NUM, default = "25" },
        { key = "radius", labelKey = "Param_GroupRadius", type = NUM, default = "5" },
        { key = "sameName", labelKey = "Param_SameName", type = BOOL, default = true } } },
    { action = "noise", labelKey = "Act_noise", params = {
        { key = "radius", labelKey = "Param_Radius", type = NUM, default = "60" },
        { key = "sound", labelKey = "Param_SoundOptional", type = T } } },
    { action = "helicopter", labelKey = "Act_helicopter", params = {} },
    { action = "weather", labelKey = "Act_weather", params = {
        { key = "type", labelKey = "Param_Type", type = "choice", choices = { "storm", "blizzard", "tropical", "clear" }, default = "storm" },
        { key = "hours", labelKey = "Param_WeatherHours", type = NUM, default = "4" } } },
    { action = "thunder", labelKey = "Act_thunder", params = { { key = "strike", labelKey = "Param_Strike", type = BOOL } } },
    { action = "time", labelKey = "Act_time", params = { { key = "hour", labelKey = "Param_Hour", type = NUM, default = "0" } } },
    { action = "fire", labelKey = "Act_fire", params = { { key = "distance", labelKey = "Param_Distance", type = NUM, default = "6" } } },
    { action = "vehicle", labelKey = "Act_vehicle", params = {
        { key = "script", labelKey = "Param_Vehicle", type = T, default = "Base.PickUpTruck" },
        { key = "distance", labelKey = "Param_Distance", type = NUM, default = "8" } } },
    { action = "give_item", labelKey = "Act_give_item", params = {
        { key = "item", labelKey = "Param_Item", type = T, default = "Base.Bandage" },
        { key = "count", labelKey = "Param_Quantity", type = NUM, default = "1" },
        { key = "onGround", labelKey = "Param_OnGround", type = BOOL } } },
    { action = "heal", labelKey = "Act_heal", params = {} },
    { action = "stat", labelKey = "Act_stat", params = {
        { key = "stat", labelKey = "Param_Stat", type = "choice", default = "PANIC",
          choices = { "PANIC", "STRESS", "FATIGUE", "HUNGER", "THIRST", "ENDURANCE", "BOREDOM", "UNHAPPINESS", "INTOXICATION" } },
        { key = "op", labelKey = "Param_Op", type = "choice", choices = { "add", "set", "remove" }, default = "add" },
        { key = "value", labelKey = "Param_Value", type = NUM, default = "50" } } },
    { action = "xp", labelKey = "Act_xp", params = {
        { key = "perk", labelKey = "Param_Perk", type = T, default = "Strength" },
        { key = "amount", labelKey = "Param_Amount", type = NUM, default = "25" } } },
    { action = "say", labelKey = "Act_say", params = { { key = "text", labelKey = "Param_Text", type = T, defaultKey = "Default_say" } } },
    { action = "halo", labelKey = "Act_halo", params = { { key = "text", labelKey = "Param_Text", type = T, default = "+1 {{user}}" } } },
    { action = "sound", labelKey = "Act_sound", params = { { key = "name", labelKey = "Param_Sound", type = T, default = "ZombieSurprisedPlayer" } } },
    { action = "wait", labelKey = "Act_wait", params = { { key = "seconds", labelKey = "Param_Seconds", type = NUM, default = "2" } } },
    { action = "emit", labelKey = "Act_emit", params = {
        { key = "event", labelKey = "Param_Event", type = T, default = "custom" } } },
    { action = "log", labelKey = "Act_log", where = "bridge", params = {
        { key = "message", labelKey = "Param_Message", type = T, default = "{{user}}" } } },
    { action = "http", labelKey = "Act_http", where = "bridge", params = {
        { key = "url", labelKey = "Param_Url", type = T },
        { key = "method", labelKey = "Param_Method", type = "choice", choices = { "POST", "GET", "PUT" }, default = "POST" } } },
}

-- Display label of an action or a parameter (translated when it has a labelKey).
function Talky_Actions.labelOf(entry)
    if entry == nil then return "" end
    if entry.labelKey then return Talky_T(entry.labelKey) end
    return tostring(entry.label or entry.action or entry.key or "")
end

-- Default value of a parameter (translated when it has a defaultKey).
function Talky_Actions.defaultOf(param)
    if param.defaultKey then return Talky_T(param.defaultKey) end
    return param.default
end

Talky_Actions.schemaByAction = {}
for _, s in ipairs(Talky_Actions.schema) do Talky_Actions.schemaByAction[s.action] = s end

return Talky_Actions
