-- Defaults. Everything in "editable" can be changed in-game (Talky window > Settings);
-- those changes are saved in talky_config.json and applied over these values.

Talky_Config = {
    -- Files exchanged with the bridge, relative to <user>/Zomboid/Lua/
    inboxFile  = "talky_inbox.jsonl",   -- bridge -> game (jobs)
    ackFile    = "talky_ack.txt",       -- game -> bridge (last processed seq)
    outboxFile = "talky_outbox.jsonl",  -- game -> bridge (game events)
    configFile = "talky_config.json",   -- webhooks + workflows + settings, edited by the window, read by the bridge
    statusFile = "talky_status.json",   -- bridge -> game heartbeat

    pollIntervalMs = 1000,

    -- Safety caps, whatever a webhook asks for
    maxZombiesPerAction = 60,
    maxActiveJobs       = 8,
    maxSpawnDistance    = 60,

    -- Fixed caps (same values in the bridge)
    maxWaitSeconds  = 600,   -- longest "wait" step
    maxTextLength   = 200,   -- notify / say / halo text
    maxToastSeconds = 60,    -- longest banner
    maxNameLength   = 60,    -- name above a zombie
    maxQueuedJobs   = 200,   -- jobs waiting for a free slot; newer ones are dropped

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
Talky_Config.editable = {
    { key = "maxZombiesPerAction", labelKey = "Set_maxZombiesPerAction", type = "number", min = 1, max = 300 },
    { key = "maxActiveJobs",       labelKey = "Set_maxActiveJobs",       type = "number", min = 1, max = 50 },
    { key = "maxSpawnDistance",    labelKey = "Set_maxSpawnDistance",    type = "number", min = 5, max = 150 },
    { key = "showNameTags",        labelKey = "Set_showNameTags",        type = "bool" },
    { key = "nameTagRange",        labelKey = "Set_nameTagRange",        type = "number", min = 5, max = 80 },
    { key = "toastSeconds",        labelKey = "Set_toastSeconds",        type = "number", min = 1, max = 30 },
    { key = "toastY",              labelKey = "Set_toastY",              type = "number", min = 0, max = 1000 },
    { key = "language",            labelKey = "Set_language",            type = "choice",
      choices = { { "Lang_en", "en" }, { "Lang_fr", "fr" } } },
    { key = "anonymousName",       labelKey = "Set_anonymousName",       type = "text", maxLength = 40 },
}

return Talky_Config
