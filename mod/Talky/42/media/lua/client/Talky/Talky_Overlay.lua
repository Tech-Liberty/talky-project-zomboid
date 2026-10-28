-- On-screen toasts and name tags above named zombies.
-- Drawn with the TextManager in OnPostUIDraw so nothing blocks mouse clicks.
--   single player : the names are in the zombies' modData (written by Talky_Tags), found by a
--                   rescan every 5 s, or at once when Talky_Tags just named one.
--   multiplayer   : the names come from the server (Talky_Client.tags, keyed by online id);
--                   the zombies around are matched again every second and on every change.
-- zombie_killed is sent by the server code (Talky_Tags), never from here.

require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Net"
require "Talky/Talky_Bridge"

Talky_Overlay = {
    toasts = {},   -- { text, r, g, b, until }
    tagged = {},   -- { zombie, name, r, g, b, id }
    lastScan = 0,
    scanVersion = -1,
}

-- "#rrggbb" -> r, g, b in 0..1; anything else gives the default color.
local function hexToRgb(hex, dr, dg, db)
    if type(hex) ~= "string" then return dr, dg, db end
    hex = string.gsub(hex, "#", "")
    if string.len(hex) ~= 6 then return dr, dg, db end
    local r = tonumber(string.sub(hex, 1, 2), 16)
    local g = tonumber(string.sub(hex, 3, 4), 16)
    local b = tonumber(string.sub(hex, 5, 6), 16)
    if not r or not g or not b then return dr, dg, db end
    return r / 255, g / 255, b / 255
end
Talky_Overlay.hexToRgb = hexToRgb

function Talky_Overlay.toast(text, color, seconds)
    local r, g, b = hexToRgb(color, 1, 0.85, 0.3)
    table.insert(Talky_Overlay.toasts, {
        text = tostring(text), r = r, g = g, b = b,
        untilMs = getTimestampMs() + (seconds or Talky_Config.toastSeconds) * 1000,
    })
    while #Talky_Overlay.toasts > 5 do table.remove(Talky_Overlay.toasts, 1) end
end

-- Single player: names a zombie of this game and shows it at once.
function Talky_Overlay.tagZombie(zombie, name, color)
    name = TalkyNet.str(name, Talky_Config.maxNameLength, "") or ""
    local md = zombie:getModData()
    md.Talky_name = name
    md.Talky_color = color
    local r, g, b = hexToRgb(color, 0.6, 0.4, 1)
    table.insert(Talky_Overlay.tagged, { zombie = zombie, name = name, r = r, g = g, b = b })
end

-- A name was just given (single player): rescan on the next frame.
function Talky_Overlay.rescanSoon()
    Talky_Overlay.lastScan = 0
end

local function shadowText(tm, font, x, y, text, r, g, b, a)
    tm:DrawStringCentre(font, x + 1, y + 1, text, 0, 0, 0, a * 0.8)
    tm:DrawStringCentre(font, x, y, text, r, g, b, a)
end

local function drawToasts(tm, now)
    local y = Talky_Config.toastY
    local cx = getCore():getScreenWidth() / 2
    local lineH = getTextManager():getFontHeight(UIFont.Large) + 6
    for i = #Talky_Overlay.toasts, 1, -1 do
        local t = Talky_Overlay.toasts[i]
        local left = t.untilMs - now
        if left <= 0 then
            table.remove(Talky_Overlay.toasts, i)
        else
            local a = math.min(1, left / 800)
            shadowText(tm, UIFont.Large, cx, y, t.text, t.r, t.g, t.b, a)
            y = y + lineH
        end
    end
end

-- Single player: zombies that were tagged before a reload keep their name in modData; pick them up again.
local function rescanModData()
    local list = getCell():getZombieList()
    if not list then return end
    local known = {}
    for _, t in ipairs(Talky_Overlay.tagged) do known[t.zombie] = true end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local md = z:getModData()
        if md.Talky_name and not known[z] and not z:isDead() then
            local r, g, b = hexToRgb(md.Talky_color, 0.6, 0.4, 1)
            table.insert(Talky_Overlay.tagged, { zombie = z, name = tostring(md.Talky_name), r = r, g = g, b = b })
        end
    end
end

-- Multiplayer: the zombies around whose online id (and outfit) match a name from the server.
local function rescanServerTags()
    local tags = Talky_Client and Talky_Client.tags or {}
    local tagged = {}
    if TalkyNet.isEmpty(tags) then
        Talky_Overlay.tagged = tagged
        return
    end
    local list = getCell():getZombieList()
    if not list then return end
    for i = 0, list:size() - 1 do
        pcall(function()
            local z = list:get(i)
            local id = z:getOnlineID()
            local e = tags[tostring(id)]
            if e and not z:isDead() and (e.p == 0 or z:getPersistentOutfitID() == e.p) then
                local r, g, b = hexToRgb(e.color, 0.6, 0.4, 1)
                tagged[#tagged + 1] = { zombie = z, name = e.name, r = r, g = g, b = b, id = id }
            end
        end)
    end
    Talky_Overlay.tagged = tagged
end

local function drawTags(tm, player, now)
    local mp = TalkyNet.mode() == "client"
    if mp then
        local version = Talky_Client and Talky_Client.tagsVersion or 0
        if now - Talky_Overlay.lastScan > 1000 or version ~= Talky_Overlay.scanVersion then
            Talky_Overlay.lastScan, Talky_Overlay.scanVersion = now, version
            pcall(rescanServerTags)
        end
    elseif now - Talky_Overlay.lastScan > 5000 then
        Talky_Overlay.lastScan = now
        pcall(rescanModData)
    end
    local pnum = player:getPlayerNum()
    local px, py = player:getX(), player:getY()
    local range = Talky_Config.nameTagRange
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    for i = #Talky_Overlay.tagged, 1, -1 do
        local t = Talky_Overlay.tagged[i]
        local z = t.zombie
        if z:isDead() or not z:getCurrentSquare() or (t.id and z:getOnlineID() ~= t.id) then
            table.remove(Talky_Overlay.tagged, i)
        else
            local zx, zy, zz = z:getX(), z:getY(), z:getZ()
            if math.abs(zx - px) < range and math.abs(zy - py) < range and z:getAlpha(pnum) > 0.1 then
                local sx = isoToScreenX(pnum, zx, zy, zz + 0.75)
                local sy = isoToScreenY(pnum, zx, zy, zz + 0.75) - fontH
                shadowText(tm, UIFont.Small, sx, sy, t.name, t.r, t.g, t.b, 1)
            end
        end
    end
end

local function onPostUIDraw()
    local player = getPlayer()
    if not player then return end
    local tm = getTextManager()
    local now = getTimestampMs()
    if #Talky_Overlay.toasts > 0 then drawToasts(tm, now) end
    if Talky_Config.showNameTags then
        local ok, err = pcall(drawTags, tm, player, now)
        if not ok and Talky_Config.debug then TalkyNet.log("name tags: " .. tostring(err)) end
    end
end

local function onPlayerDeath(player)
    Talky_Bridge.emit("player_died", {
        hoursSurvived = math.floor(player:getHoursSurvived()),
        zombieKills = player:getZombieKills(),
    })
end

Events.OnPostUIDraw.Add(onPostUIDraw)
Events.OnPlayerDeath.Add(onPlayerDeath)

return Talky_Overlay
