-- What the Talky server code sends to this game (module "Talky"; in single player the same
-- messages come through TalkyNet's local queue):
--   fx { kind = notify | say | halo | heal, ... }  -> effects on this client (a job's banner, the
--                                                    streamer's own character)
--   tag { id, n, c, p } / untag { id } / tags { reset, list } -> names above zombies (multiplayer)
--   status, streamers, streamerAck, config, configSaved, testAck, refused -> Talky_Remote (the
--                                                    F8 window in multiplayer)
--   display { settings }                           -> the display settings of the server's
--                                                    configuration, saved by an admin
-- The jobs and their events never pass through a client: the server reads and writes the
-- bridge's files itself. Server text is never trusted: lengths, colors and numbers are checked
-- here again.

require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Overlay"
require "Talky/Talky_Remote"

Talky_Client = {
    tags = {},        -- [tostring(onlineID)] = { name, color, p }   (multiplayer)
    tagCount = 0,
    tagsVersion = 0,  -- changes with every update, the overlay then matches the zombies again
}

local str, num, color = TalkyNet.str, TalkyNet.num, TalkyNet.color
local MAX_TAGS = 256

---------------------------------------------------------------- fx

-- Translated banners the server may ask for (the text is built here, in this player's language).
local BANNER_KEYS = { Toast_ZombieDown = true }

local function fxNotify(a)
    local text
    if a.tkey then
        local key = str(a.tkey, 32, "")
        if not BANNER_KEYS[key] then return end
        text = Talky_T(key, str(a.arg, Talky_Config.maxNameLength, ""))
    else
        text = str(a.text, Talky_Config.maxTextLength, "")
    end
    local from = str(a.from, 32, "")
    if from ~= "" then text = "[" .. from .. "] " .. text end
    Talky_Overlay.toast(text, color(a.color, nil), num(a.seconds, nil, 1, Talky_Config.maxToastSeconds))
end

local function fxSay(a)
    local player = getPlayer()
    if not player then return end
    local text = str(a.text, Talky_Config.maxTextLength, "")
    if text == "" then return end
    -- player:Say() is local only; in multiplayer the "say" chat shows it to nearby players,
    -- unless the server's "say" budget is spent (quiet: the overhead line only)
    if TalkyNet.mode() == "client" and a.quiet ~= true then processSayMessage(text) else player:Say(text) end
end

local function fxHalo(a)
    local player = getPlayer()
    if player then HaloTextHelper.addText(player, str(a.text, Talky_Config.maxTextLength, "")) end
end

-- Health belongs to the player's own game in multiplayer. The server already checked that the
-- character is alive ("dead" otherwise); a death in between: nothing to heal.
local function fxHeal()
    local player = getPlayer()
    if not player or player:isDead() then return end
    player:getBodyDamage():RestoreToFullHealth()
end

local FX = { notify = fxNotify, say = fxSay, halo = fxHalo, heal = fxHeal }

---------------------------------------------------------------- name tags (multiplayer)

local function setTag(e)
    if type(e) ~= "table" then return end
    local id = TalkyNet.int(e.id, nil, -1, 1000000)
    local name = str(e.n, Talky_Config.maxNameLength, nil)
    if not id or id < 0 or not name or name == "" then return end
    local key = tostring(id)
    if not Talky_Client.tags[key] then
        if Talky_Client.tagCount >= MAX_TAGS then return end
        Talky_Client.tagCount = Talky_Client.tagCount + 1
    end
    Talky_Client.tags[key] = { name = name, color = color(e.c, nil), p = TalkyNet.int(e.p, 0, -2147483648, 2147483647) }
end

local function onTag(a)
    if a.sp then
        Talky_Overlay.rescanSoon()
        return
    end
    setTag(a)
    Talky_Client.tagsVersion = Talky_Client.tagsVersion + 1
end

local function onUntag(a)
    local id = TalkyNet.int(a.id, nil, -1, 1000000)
    if not id then return end
    local key = tostring(id)
    if Talky_Client.tags[key] then
        Talky_Client.tags[key] = nil
        Talky_Client.tagCount = Talky_Client.tagCount - 1
        Talky_Client.tagsVersion = Talky_Client.tagsVersion + 1
    end
end

local function onTags(a)
    if a.reset then Talky_Client.tags, Talky_Client.tagCount = {}, 0 end
    if type(a.list) == "table" then
        for i = 1, math.min(#a.list, MAX_TAGS) do pcall(setTag, a.list[i]) end
    end
    Talky_Client.tagsVersion = Talky_Client.tagsVersion + 1
end

---------------------------------------------------------------- dispatch

Talky_Client.handlers = {
    fx = function(a)
        local f = FX[str(a.kind, 16, "")]
        if f then f(a) end
    end,
    tag = onTag,
    untag = onUntag,
    tags = onTags,
    status = function(a) Talky_Remote.onStatus(a) end,
    streamers = function(a) Talky_Remote.onStreamers(a) end,
    streamerAck = function(a) Talky_Remote.onStreamerAck(a) end,
    config = function(a) Talky_Remote.onConfig(a) end,
    configSaved = function(a) Talky_Remote.onConfigSaved(a) end,
    display = function(a) Talky_Remote.onDisplay(a) end,
    testAck = function(a) Talky_Remote.onTestAck(a) end,
    refused = function(a) Talky_Remote.onRefused(a) end,
}

function Talky_Client.dispatch(command, args)
    local h = Talky_Client.handlers[command]
    if not h then return end
    h(type(args) == "table" and args or {})
end

TalkyNet.clientHandler = Talky_Client.dispatch

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= TalkyNet.MODULE then return end
    local ok, err = pcall(Talky_Client.dispatch, command, args)
    if not ok then TalkyNet.log("server message " .. tostring(command) .. ": " .. tostring(err)) end
end)

return Talky_Client
