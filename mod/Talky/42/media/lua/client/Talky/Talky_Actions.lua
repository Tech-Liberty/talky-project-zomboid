-- Game action registry. Each handler receives (params, player, job).
-- Add your own with Talky_Actions.register("name", function(p, player, job) ... end).

require "Talky/Talky_Config"
require "Talky/Talky_Text"
require "Talky/Talky_Bridge"
require "Talky/Talky_Overlay"

Talky_Actions = { handlers = {} }

function Talky_Actions.register(name, fn)
    Talky_Actions.handlers[name] = fn
end

function Talky_Actions.run(step, player, job)
    local fn = Talky_Actions.handlers[step.action]
    if not fn then error("unknown action '" .. tostring(step.action) .. "'") end
    fn(step, player, job)
end

---------------------------------------------------------------- helpers

local function num(v, default, min, max)
    v = tonumber(v) or default
    if min and v < min then v = min end
    if max and v > max then v = max end
    return v
end

local function bool(v, default)
    if v == nil then return default end
    return v == true or v == "true" or v == 1
end

-- Random free square on the player's floor, between minDist and maxDist tiles away.
local function findSquare(player, minDist, maxDist, outsideOnly)
    local cell = getCell()
    local px, py, pz = player:getX(), player:getY(), math.floor(player:getZ())
    for _ = 1, 40 do
        local a = ZombRandFloat(0, 6.2832)
        local d = ZombRandFloat(minDist, maxDist)
        local sq = cell:getGridSquare(math.floor(px + math.cos(a) * d), math.floor(py + math.sin(a) * d), pz)
        if sq and sq:isFree(false) and (not outsideOnly or sq:isOutside()) then
            return sq
        end
    end
    return player:getCurrentSquare()
end
Talky_Actions.findSquare = findSquare

local function aggro(zombie, player)
    if not pcall(function() zombie:spotted(player, true) end) then
        pcall(function() zombie:pathToCharacter(player) end)
    end
end

---------------------------------------------------------------- feedback

-- Texts shown in game are capped (the bridge applies the same cap).
local function clipText(v)
    return string.sub(tostring(v or ""), 1, Talky_Config.maxTextLength)
end
Talky_Actions.clipText = clipText

Talky_Actions.register("notify", function(p)
    local seconds = tonumber(p.seconds)
    if seconds then seconds = num(seconds, Talky_Config.toastSeconds, 1, Talky_Config.maxToastSeconds) end
    Talky_Overlay.toast(clipText(p.text), p.color, seconds)
end)

Talky_Actions.register("say", function(p, player)
    player:Say(clipText(p.text))
end)

Talky_Actions.register("halo", function(p, player)
    HaloTextHelper.addText(player, clipText(p.text))
end)

Talky_Actions.register("emit", function(p)
    Talky_Bridge.emit(p.event or "custom", p.data)
end)

---------------------------------------------------------------- zombies

-- spawn_zombie: name, count, distance, minDistance, outfit, crawler, health, onFire,
--               fakeDead, aggro, cluster (all in one spot), radius, color
Talky_Actions.register("spawn_zombie", function(p, player)
    local count = math.floor(num(p.count, 1, 1, Talky_Config.maxZombiesPerAction))
    local maxD = num(p.distance, 12, 2, Talky_Config.maxSpawnDistance)
    local minD = num(p.minDistance, math.max(2, maxD * 0.6), 1, maxD)
    local radius = num(p.radius, 3, 0, 20)
    local outfit = p.outfit
    if outfit == "" or outfit == "random" then outfit = nil end
    local crawler, onFire, fakeDead = bool(p.crawler, false), bool(p.onFire, false), bool(p.fakeDead, false)
    local health = num(p.health, 1, 0.1, 10)
    local doAggro = bool(p.aggro, true)

    local center = findSquare(player, minD, maxD, bool(p.outside, false))
    for i = 1, count do
        local sq = center
        if not bool(p.cluster, false) then
            sq = findSquare(player, minD, maxD, bool(p.outside, false))
        end
        local x, y = sq:getX(), sq:getY()
        if bool(p.cluster, false) and radius > 0 then
            x = x + ZombRand(-radius, radius + 1)
            y = y + ZombRand(-radius, radius + 1)
        end
        -- B42 signature: x, y, z, count, outfit, femaleChance, crawler, isFallOnFront, isFakeDead,
        -- knockedDown, isInvulnerable, isSitting, health, isRecordingAnims, heightOffset, isRagdolling, onFire
        local list = addZombiesInOutfit(x, y, sq:getZ(), 1, outfit, 50, crawler, false, fakeDead,
                                        false, false, false, health, false, 0, false, onFire)
        if list then
            for j = 0, list:size() - 1 do
                local z = list:get(j)
                if p.name and p.name ~= "" then
                    local label = tostring(p.name)
                    if count > 1 and not bool(p.sameName, false) then label = label .. " #" .. i end
                    Talky_Overlay.tagZombie(z, label, p.color)
                end
                if doAggro then aggro(z, player) end
            end
        end
    end
end)

-- Shortcut for a big group spawned around one spot.
Talky_Actions.register("horde", function(p, player, job)
    p.cluster = true
    p.count = p.count or 15
    p.radius = p.radius or 5
    p.distance = p.distance or 25
    Talky_Actions.handlers.spawn_zombie(p, player, job)
end)

---------------------------------------------------------------- world

-- Noise that attracts every zombie within radius.
Talky_Actions.register("noise", function(p, player)
    local radius = num(p.radius, 60, 1, 300)
    addSound(player, math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()),
             radius, num(p.volume, radius, 1, 300))
    if p.sound then player:getEmitter():playSound(p.sound) end
end)

Talky_Actions.register("sound", function(p, player)
    player:getEmitter():playSound(tostring(p.name or "ZombieSurprisedPlayer"))
end)

Talky_Actions.register("helicopter", function()
    testHelicopter()
end)

Talky_Actions.register("thunder", function(p, player)
    local thunder = getClimateManager():getThunderStorm()
    thunder:triggerThunderEvent(math.floor(player:getX()), math.floor(player:getY()),
                                bool(p.strike, false), true, true)
end)

-- weather: type = storm | blizzard | tropical | clear, or a raw "stage" number; hours = duration
local weatherStages = { storm = 3, blizzard = 7, tropical = 8 }
Talky_Actions.register("weather", function(p)
    local clim = getWorld():getClimateManager()
    if p.type == "clear" then
        clim:stopWeatherAndThunder()
        return
    end
    local stage = tonumber(p.stage) or weatherStages[p.type or "storm"]
    if not stage then error("unknown weather type " .. tostring(p.type)) end
    clim:triggerCustomWeatherStage(stage, num(p.hours, 6, 1, 72))
end)

Talky_Actions.register("time", function(p)
    getGameTime():setTimeOfDay(num(p.hour, 0, 0, 23.99))
end)

Talky_Actions.register("fire", function(p, player)
    local sq = findSquare(player, num(p.minDistance, 3, 1, 30), num(p.distance, 6, 2, 40), false)
    IsoFireManager.StartFire(getCell(), sq, true, 100, 500)
end)

Talky_Actions.register("vehicle", function(p, player)
    local sq = findSquare(player, 4, num(p.distance, 8, 4, 40), true)
    addVehicleDebug(tostring(p.script or "Base.CarNormal"), IsoDirections.S, nil, sq)
end)

---------------------------------------------------------------- player

Talky_Actions.register("give_item", function(p, player)
    local item = tostring(p.item or "Base.Apple")
    local count = math.floor(num(p.count, 1, 1, 100))
    if bool(p.onGround, false) then
        local sq = player:getCurrentSquare()
        for _ = 1, count do sq:AddWorldInventoryItem(instanceItem(item), 0.5, 0.5, 0) end
    else
        player:getInventory():AddItems(item, count)
    end
end)

Talky_Actions.register("heal", function(p, player)
    player:getBodyDamage():RestoreToFullHealth()
end)

-- stat: stat = CharacterStat name (PANIC, STRESS, FATIGUE, HUNGER, THIRST, INTOXICATION...),
--       op = set | add | remove, value
Talky_Actions.register("stat", function(p, player)
    local stat = CharacterStat[string.upper(tostring(p.stat))]
    if not stat then error("unknown stat " .. tostring(p.stat)) end
    local stats = player:getStats()
    local value = num(p.value, 0)
    if p.op == "set" then stats:set(stat, value)
    elseif p.op == "remove" then stats:remove(stat, value)
    else stats:set(stat, stats:get(stat) + value) end
end)

Talky_Actions.register("xp", function(p, player)
    local perk = Perks[tostring(p.perk)]
    if not perk then error("unknown perk " .. tostring(p.perk)) end
    addXp(player, perk, num(p.amount, 10, 0, 10000))
end)

---------------------------------------------------------------- schema for the editor window
-- Every field is typed as text so it can hold a template ({{user}}, {{bits | div:100}}...),
-- except "bool" (tick box) and "choice" (combo). "where" = game | bridge.
-- Labels are translation keys (labelKey -> UI_Talky_<labelKey>); a schema entry added by
-- another mod may use a plain "label" instead. "defaultKey" = translated default text.

local T, N, B = "text", "number", "bool"
Talky_Actions.schema = {
    { action = "notify", labelKey = "Act_notify", params = {
        { key = "text", labelKey = "Param_Text", type = T, defaultKey = "Default_notify" },
        { key = "color", labelKey = "Param_Color", type = T, default = "#b388ff" },
        { key = "seconds", labelKey = "Param_Duration", type = N } } },
    { action = "spawn_zombie", labelKey = "Act_spawn_zombie", params = {
        { key = "name", labelKey = "Param_Name", type = T, default = "{{user}}" },
        { key = "count", labelKey = "Param_Count", type = N, default = "1" },
        { key = "distance", labelKey = "Param_MaxDistance", type = N, default = "14" },
        { key = "minDistance", labelKey = "Param_MinDistance", type = N },
        { key = "outfit", labelKey = "Param_Outfit", type = T },
        { key = "health", labelKey = "Param_Health", type = N },
        { key = "color", labelKey = "Param_NameColor", type = T, default = "#b388ff" },
        { key = "crawler", labelKey = "Param_Crawler", type = B },
        { key = "onFire", labelKey = "Param_OnFire", type = B },
        { key = "fakeDead", labelKey = "Param_FakeDead", type = B },
        { key = "sameName", labelKey = "Param_SameName", type = B },
        { key = "aggro", labelKey = "Param_Aggro", type = B, default = true } } },
    { action = "horde", labelKey = "Act_horde", params = {
        { key = "name", labelKey = "Param_NameOptional", type = T, defaultKey = "Default_horde" },
        { key = "count", labelKey = "Param_Count", type = N, default = "15" },
        { key = "distance", labelKey = "Param_Distance", type = N, default = "25" },
        { key = "radius", labelKey = "Param_GroupRadius", type = N, default = "5" },
        { key = "sameName", labelKey = "Param_SameName", type = B, default = true } } },
    { action = "noise", labelKey = "Act_noise", params = {
        { key = "radius", labelKey = "Param_Radius", type = N, default = "60" },
        { key = "sound", labelKey = "Param_SoundOptional", type = T } } },
    { action = "helicopter", labelKey = "Act_helicopter", params = {} },
    { action = "weather", labelKey = "Act_weather", params = {
        { key = "type", labelKey = "Param_Type", type = "choice", choices = { "storm", "blizzard", "tropical", "clear" }, default = "storm" },
        { key = "hours", labelKey = "Param_WeatherHours", type = N, default = "4" } } },
    { action = "thunder", labelKey = "Act_thunder", params = { { key = "strike", labelKey = "Param_Strike", type = B } } },
    { action = "time", labelKey = "Act_time", params = { { key = "hour", labelKey = "Param_Hour", type = N, default = "0" } } },
    { action = "fire", labelKey = "Act_fire", params = { { key = "distance", labelKey = "Param_Distance", type = N, default = "6" } } },
    { action = "vehicle", labelKey = "Act_vehicle", params = {
        { key = "script", labelKey = "Param_Vehicle", type = T, default = "Base.PickUpTruck" },
        { key = "distance", labelKey = "Param_Distance", type = N, default = "8" } } },
    { action = "give_item", labelKey = "Act_give_item", params = {
        { key = "item", labelKey = "Param_Item", type = T, default = "Base.Bandage" },
        { key = "count", labelKey = "Param_Quantity", type = N, default = "1" },
        { key = "onGround", labelKey = "Param_OnGround", type = B } } },
    { action = "heal", labelKey = "Act_heal", params = {} },
    { action = "stat", labelKey = "Act_stat", params = {
        { key = "stat", labelKey = "Param_Stat", type = "choice", default = "PANIC",
          choices = { "PANIC", "STRESS", "FATIGUE", "HUNGER", "THIRST", "ENDURANCE", "BOREDOM", "UNHAPPINESS", "INTOXICATION" } },
        { key = "op", labelKey = "Param_Op", type = "choice", choices = { "add", "set", "remove" }, default = "add" },
        { key = "value", labelKey = "Param_Value", type = N, default = "50" } } },
    { action = "xp", labelKey = "Act_xp", params = {
        { key = "perk", labelKey = "Param_Perk", type = T, default = "Strength" },
        { key = "amount", labelKey = "Param_Amount", type = N, default = "25" } } },
    { action = "say", labelKey = "Act_say", params = { { key = "text", labelKey = "Param_Text", type = T, defaultKey = "Default_say" } } },
    { action = "halo", labelKey = "Act_halo", params = { { key = "text", labelKey = "Param_Text", type = T, default = "+1 {{user}}" } } },
    { action = "sound", labelKey = "Act_sound", params = { { key = "name", labelKey = "Param_Sound", type = T, default = "ZombieSurprisedPlayer" } } },
    { action = "wait", labelKey = "Act_wait", params = { { key = "seconds", labelKey = "Param_Seconds", type = N, default = "2" } } },
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
