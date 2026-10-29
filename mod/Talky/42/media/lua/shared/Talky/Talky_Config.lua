-- Defaults. Everything in "editable" can be changed in-game (Talky window > Settings);
-- those changes are saved in talky_config.json and applied over these values.
-- On a multiplayer server the limits come from the sandbox options instead (see "sandbox"
-- below and media/sandbox-options.txt): talky_config.json only applies in single player.
-- Two modes: single player (the bridge on the player's PC, next to the game) and server (the
-- bridge on the machine of the server, which reads its jobs itself; see Talky_Inbox).

Talky_Config = {
    version         = "0.5.0",
    bridgeProtocol  = 3,   -- talky_status.json "protocol" of a bridge that knows server mode (0.5.0)

    -- Files exchanged with the bridge, relative to Zomboid/Lua/ of the game, or of the server
    -- in multiplayer (the account that runs it, or its -cachedir)
    inboxFile  = "talky_inbox.jsonl",   -- bridge -> game (jobs; server mode: "target" = streamer)
    ackFile    = "talky_ack.txt",       -- game -> bridge ("S" or "S s1 s2 ...", see Talky_Inbox)
    outboxFile = "talky_outbox.txt",    -- game -> bridge (game events, streamer requests). The game
                                        -- only lets mods write .ini/.cfg/.txt/.log/.json files.
    configFile = "talky_config.json",   -- webhooks + workflows + settings, edited by the window, read by the bridge
    statusFile = "talky_status.json",   -- bridge -> game heartbeat
    streamersFile = "talky_streamers.json", -- bridge -> server: the streamers and their tokens (server mode)

    pollIntervalMs = 1000,

    -- Safety caps in single player, whatever a webhook asks for
    maxZombiesPerAction = 60,
    maxActiveJobs       = 8,
    maxSpawnDistance    = 60,

    -- Fixed caps (same values in the bridge)
    maxWaitSeconds  = 600,   -- longest "wait" step
    maxTextLength   = 200,   -- notify / say / halo text
    maxToastSeconds = 60,    -- longest banner
    maxNameLength   = 40,    -- name above a zombie
    maxQueuedJobs   = 200,   -- single player: jobs waiting for a free slot
    maxStreamers    = 200,   -- server mode (the bridge keeps as many)
    maxStreamerName = 64,

    -- Fixed limits of the Talky server code (multiplayer)
    maxJobTtlMs         = 900000,  -- a job not started 15 min after the bridge created it is dropped
    maxWaitPerJobMs     = 900000,  -- total of the "wait" steps of one job
    maxQueuedJobsTotal  = 50,      -- every player together
    maxActiveJobsTotal  = 12,
    zombiesPerTick      = 10,      -- zombies created per tick, server-wide (the rest waits a tick)
    maxItemsPerAction   = 100,
    maxXpPerAction      = 1000,
    maxWeatherHours     = 12,
    maxFiresPer10Min       = 10,   -- fire steps per player per 10 minutes
    maxFiresPer10MinServer = 20,   -- every player together
    maxSoundsPer10Min      = 60,   -- noise and sound steps per player per 10 minutes
    maxBannersPerMinute       = 6,    -- banners shown to every player (BannerAudience 2), per streamer
    maxBannersPerMinuteServer = 20,   -- every streamer together; beyond: to the streamer only
    maxSayPerMinute        = 12,   -- "say" lines in the public chat, per streamer
    maxSayPerMinuteServer  = 60,   -- every streamer together; beyond: an overhead line only
    maxTags             = 128,     -- named zombies tracked by the server
    maxTagsPerOwner     = 32,
    tagTtlMs            = 1800000,

    showNameTags   = true,
    nameTagRange   = 25,       -- tiles
    toastSeconds   = 6,
    toastY         = 80,       -- px from the top of the screen

    -- Read by the bridge: language of its own texts, name used for anonymous events
    language       = "en",
    anonymousName  = "",

    debug          = false,
}

-- Settings the window exposes, in display order. labelKey -> UI_Talky_<labelKey> in UI.json.
-- "server" = name of the server limit shown instead in multiplayer (read only).
-- "display" = a setting of the players' screens (names above zombies, banners). In multiplayer
-- every client takes it from the settings of the server's talky_config.json (set by an admin
-- in F8), sent with the "status" answer and again to everyone when an admin saves.
Talky_Config.editable = {
    { key = "maxZombiesPerAction", labelKey = "Set_maxZombiesPerAction", type = "number", min = 1, max = 300, server = "maxZombiesPerAction" },
    { key = "maxActiveJobs",       labelKey = "Set_maxActiveJobs",       type = "number", min = 1, max = 50,  server = "maxActiveJobs" },
    { key = "maxSpawnDistance",    labelKey = "Set_maxSpawnDistance",    type = "number", min = 5, max = 150, server = "maxSpawnDistance" },
    { key = "showNameTags",        labelKey = "Set_showNameTags",        type = "bool",   display = true },
    { key = "nameTagRange",        labelKey = "Set_nameTagRange",        type = "number", min = 5, max = 80,  display = true },
    { key = "toastSeconds",        labelKey = "Set_toastSeconds",        type = "number", min = 1, max = 30,  display = true },
    { key = "toastY",              labelKey = "Set_toastY",              type = "number", min = 0, max = 1000, display = true },
    { key = "language",            labelKey = "Set_language",            type = "choice",
      choices = { { "Lang_en", "en" }, { "Lang_fr", "fr" } } },
    { key = "anonymousName",       labelKey = "Set_anonymousName",       type = "text", maxLength = 40 },
}

---------------------------------------------------------------- sandbox options (server)

-- SandboxVars.Talky.<name>, declared in media/sandbox-options.txt with the same bounds.
-- A save made before 0.4.0 has no Talky options: the defaults below apply. Who may use Talky is
-- not an option: the streamers an admin added (F8 > Webhooks, talky_streamers.json).
Talky_Config.sandbox = {
    { name = "MaxZombiesPerAction",       type = "int",    default = 30,   min = 1,  max = 300 },
    { name = "MaxZombiesPerJob",          type = "int",    default = 60,   min = 1,  max = 500 },
    { name = "MaxZombiesPer10Min",        type = "int",    default = 150,  min = 1,  max = 2000 },
    { name = "MaxZombiesPer10MinServer",  type = "int",    default = 400,  min = 1,  max = 5000 },
    { name = "MaxSpawnDistance",          type = "int",    default = 40,   min = 5,  max = 150 },
    { name = "MaxStepsPerJob",            type = "int",    default = 100,  min = 10, max = 500 },
    { name = "MaxQueuedJobs",             type = "int",    default = 10,   min = 1,  max = 50 },
    { name = "MaxActiveJobs",             type = "int",    default = 4,    min = 1,  max = 20 },
    { name = "MaxJobsPerMinute",          type = "int",    default = 30,   min = 1,  max = 120 },
    { name = "AllowZombies",              type = "bool",   default = true },
    { name = "AllowItems",                type = "bool",   default = true },
    { name = "MaxItemsPer10Min",          type = "int",    default = 300,  min = 1,  max = 5000 },
    { name = "ItemDenylist",              type = "string", default = "" },
    { name = "AllowVehicles",             type = "bool",   default = true },
    { name = "MaxVehiclesPer10Min",       type = "int",    default = 2,    min = 1,  max = 20 },
    { name = "AllowXp",                   type = "bool",   default = true },
    { name = "MaxXpPer10Min",             type = "int",    default = 5000, min = 1,  max = 100000 },
    { name = "AllowPlayerEffects",        type = "bool",   default = true },
    { name = "AllowWeather",              type = "bool",   default = true },
    { name = "WeatherCooldownMinutes",    type = "int",    default = 15,   min = 0,  max = 240 },
    { name = "ThunderCooldownSeconds",    type = "int",    default = 30,   min = 0,  max = 3600 },
    { name = "AllowTime",                 type = "bool",   default = true },
    { name = "TimeCooldownMinutes",       type = "int",    default = 30,   min = 0,  max = 240 },
    { name = "AllowFire",                 type = "bool",   default = false },
    { name = "AllowHelicopter",           type = "bool",   default = false },
    { name = "HelicopterAnyTarget",       type = "bool",   default = false },
    { name = "HelicopterCooldownMinutes", type = "int",    default = 60,   min = 0,  max = 600 },
    { name = "AllowSounds",               type = "bool",   default = true },
    { name = "MaxNoiseRadius",            type = "int",    default = 80,   min = 1,  max = 300 },
    { name = "ProtectRadius",             type = "int",    default = 15,   min = 0,  max = 100 },
    { name = "BannerAudience",            type = "enum",   default = 1,    min = 1,  max = 2 },
    { name = "AllowCustomActions",        type = "bool",   default = false },
}

-- Sandbox toggle of each action category (see Talky_Actions.builtin).
Talky_Config.categoryToggle = {
    zombies = "AllowZombies", items = "AllowItems", vehicles = "AllowVehicles", xp = "AllowXp",
    playerEffects = "AllowPlayerEffects", weather = "AllowWeather", time = "AllowTime",
    fire = "AllowFire", helicopter = "AllowHelicopter", sounds = "AllowSounds",
    custom = "AllowCustomActions",
}
Talky_Config.categories = { "zombies", "items", "vehicles", "xp", "playerEffects", "weather", "time", "fire", "helicopter", "sounds" }

local function clampNum(v, def, lo, hi)
    if type(v) == "string" then v = tonumber(v) end
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return def end
    v = math.floor(v)
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local sandboxCache, sandboxReadAt = nil, -1000000

-- Values of the sandbox options, typed and clamped (an admin may hand-edit the file).
-- Cached for one second.
function Talky_Config.readSandbox()
    local now = getTimestampMs()
    if sandboxCache and now - sandboxReadAt < 1000 and now >= sandboxReadAt then return sandboxCache end
    local raw = (type(SandboxVars) == "table" and type(SandboxVars.Talky) == "table") and SandboxVars.Talky or {}
    local out = {}
    for _, o in ipairs(Talky_Config.sandbox) do
        local v = raw[o.name]
        if o.type == "bool" then
            if type(v) == "boolean" then out[o.name] = v else out[o.name] = o.default end
        elseif o.type == "string" then
            if type(v) == "string" then out[o.name] = string.sub(v, 1, 4000) else out[o.name] = o.default end
        else
            out[o.name] = clampNum(v, o.default, o.min, o.max)
        end
    end
    sandboxCache, sandboxReadAt = out, now
    return out
end

-- Effective limits for the code that runs jobs (Talky_ServerRunner, Talky_Actions):
--   single player : the F8 settings (talky_config.json), as in 0.3.0, clamped to their bounds;
--                   no budget, toggle or cooldown ("enforce" = false).
--   server        : the sandbox options.
function Talky_Config.caps()
    local mode = TalkyNet and TalkyNet.mode() or "sp"
    if mode ~= "server" then
        return {
            enforce             = false,
            maxZombiesPerAction = clampNum(Talky_Config.maxZombiesPerAction, 60, 1, 300),
            maxSpawnDistance    = clampNum(Talky_Config.maxSpawnDistance, 60, 5, 150),
            maxActiveJobs       = clampNum(Talky_Config.maxActiveJobs, 8, 1, 50),
            maxActiveJobsTotal  = 50,
            maxQueuedJobs       = Talky_Config.maxQueuedJobs,
            maxQueuedJobsTotal  = Talky_Config.maxQueuedJobs,
            maxStepsPerJob      = 500,
            maxWaitPerJobMs     = 1000000000,
            maxItemsPerAction   = 100,
            maxXpPerAction      = 10000,
            maxWeatherHours     = 72,
            maxNoiseRadius      = 300,
            audience            = 1,
        }
    end
    local sv = Talky_Config.readSandbox()
    return {
        enforce             = true,
        sandbox             = sv,
        maxZombiesPerAction = sv.MaxZombiesPerAction,
        maxZombiesPerJob    = sv.MaxZombiesPerJob,
        maxZombiesPer10Min  = sv.MaxZombiesPer10Min,
        maxZombiesPer10MinServer = sv.MaxZombiesPer10MinServer,
        maxSpawnDistance    = sv.MaxSpawnDistance,
        maxActiveJobs       = sv.MaxActiveJobs,
        maxActiveJobsTotal  = Talky_Config.maxActiveJobsTotal,
        maxQueuedJobs       = sv.MaxQueuedJobs,
        maxQueuedJobsTotal  = Talky_Config.maxQueuedJobsTotal,
        maxJobsPerMinute    = sv.MaxJobsPerMinute,
        maxStepsPerJob      = sv.MaxStepsPerJob,
        maxWaitPerJobMs     = Talky_Config.maxWaitPerJobMs,
        maxItemsPerAction   = Talky_Config.maxItemsPerAction,
        maxItemsPer10Min    = sv.MaxItemsPer10Min,
        maxVehiclesPer10Min = sv.MaxVehiclesPer10Min,
        maxXpPerAction      = Talky_Config.maxXpPerAction,
        maxXpPer10Min       = sv.MaxXpPer10Min,
        maxFiresPer10Min       = Talky_Config.maxFiresPer10Min,
        maxFiresPer10MinServer = Talky_Config.maxFiresPer10MinServer,
        maxSoundsPer10Min      = Talky_Config.maxSoundsPer10Min,
        maxWeatherHours     = Talky_Config.maxWeatherHours,
        maxNoiseRadius      = sv.MaxNoiseRadius,
        protectRadius       = sv.ProtectRadius,
        audience            = sv.BannerAudience,
    }
end

-- Is this action category allowed by the server? Always true in single player.
function Talky_Config.categoryAllowed(category, caps)
    if not caps.enforce or category == nil then return true end
    local toggle = Talky_Config.categoryToggle[category]
    if not toggle then return true end
    return caps.sandbox[toggle] == true
end

-- The display settings of a "settings" table (talky_config.json), typed and clamped to the bounds
-- of the window; missing or unreadable ones are left out (the client keeps its default).
function Talky_Config.displayOf(settings)
    local out = {}
    if type(settings) ~= "table" then return out end
    for _, opt in ipairs(Talky_Config.editable) do
        if opt.display then
            local v = settings[opt.key]
            if opt.type == "bool" then
                if type(v) == "boolean" then out[opt.key] = v end
            else
                out[opt.key] = clampNum(v, nil, opt.min, opt.max)
            end
        end
    end
    return out
end

-- Limits sent to the client in the "status" answer, shown read only on the F8 window (plain data).
function Talky_Config.publicCaps()
    local c = Talky_Config.caps()
    local allow = {}
    for _, cat in ipairs(Talky_Config.categories) do allow[cat] = Talky_Config.categoryAllowed(cat, c) end
    return {
        maxZombiesPerAction = c.maxZombiesPerAction,
        maxZombiesPerJob    = c.maxZombiesPerJob or c.maxZombiesPerAction,
        maxSpawnDistance    = c.maxSpawnDistance,
        maxActiveJobs       = c.maxActiveJobs,
        maxQueuedJobs       = c.maxQueuedJobs,
        maxJobsPerMinute    = c.maxJobsPerMinute or 0,
        maxStepsPerJob      = c.maxStepsPerJob,
        audience            = c.audience,
        allow               = allow,
    }
end

return Talky_Config
