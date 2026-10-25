-- On-screen toasts and name tags above named zombies.
-- Drawn with the TextManager in OnPostUIDraw so nothing blocks mouse clicks.

require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Bridge"

Talky_Overlay = {
    toasts = {},   -- { text, r, g, b, until }
    tagged = {},   -- { zombie, name, r, g, b }
    lastScan = 0,
}

local function hexToRgb(hex, dr, dg, db)
    if type(hex) ~= "string" then return dr, dg, db end
    hex = string.gsub(hex, "#", "")
    if string.len(hex) ~= 6 then return dr, dg, db end
    return tonumber(string.sub(hex, 1, 2), 16) / 255,
           tonumber(string.sub(hex, 3, 4), 16) / 255,
           tonumber(string.sub(hex, 5, 6), 16) / 255
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

function Talky_Overlay.tagZombie(zombie, name, color)
    name = string.sub(tostring(name), 1, Talky_Config.maxNameLength)
    local md = zombie:getModData()
    md.Talky_name = name
    md.Talky_color = color
    local r, g, b = hexToRgb(color, 0.6, 0.4, 1)
    table.insert(Talky_Overlay.tagged, { zombie = zombie, name = name, r = r, g = g, b = b })
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

-- Zombies that were tagged before a reload keep their name in modData; pick them up again.
local function rescan(player)
    local list = getCell():getZombieList()
    if not list then return end
    local known = {}
    for _, t in ipairs(Talky_Overlay.tagged) do known[t.zombie] = true end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local md = z:getModData()
        if md.Talky_name and not known[z] and not z:isDead() then
            local r, g, b = hexToRgb(md.Talky_color, 0.6, 0.4, 1)
            table.insert(Talky_Overlay.tagged, { zombie = z, name = md.Talky_name, r = r, g = g, b = b })
        end
    end
end

local function drawTags(tm, player, now)
    if now - Talky_Overlay.lastScan > 5000 then
        Talky_Overlay.lastScan = now
        pcall(rescan, player)
    end
    local pnum = player:getPlayerNum()
    local px, py = player:getX(), player:getY()
    local range = Talky_Config.nameTagRange
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    for i = #Talky_Overlay.tagged, 1, -1 do
        local t = Talky_Overlay.tagged[i]
        local z = t.zombie
        if z:isDead() or not z:getCurrentSquare() then
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
    if Talky_Config.showNameTags then drawTags(tm, player, now) end
end

local function onZombieDead(zombie)
    local name = zombie:getModData().Talky_name
    if not name then return end
    local player = getPlayer()
    local ok, attacker = pcall(function() return zombie:getAttackedBy() end)
    local byPlayer = ok and player ~= nil and attacker == player
    Talky_Overlay.toast(Talky_T("Toast_ZombieDown", name), "#ff5555")
    Talky_Bridge.emit("zombie_killed", { name = name, byPlayer = byPlayer })
end

local function onPlayerDeath(player)
    Talky_Bridge.emit("player_died", {
        hoursSurvived = math.floor(player:getHoursSurvived()),
        zombieKills = player:getZombieKills(),
    })
end

Events.OnPostUIDraw.Add(onPostUIDraw)
Events.OnZombieDead.Add(onZombieDead)
Events.OnPlayerDeath.Add(onPlayerDeath)
