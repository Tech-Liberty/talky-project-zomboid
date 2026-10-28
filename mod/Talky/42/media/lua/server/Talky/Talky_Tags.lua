-- Names above the zombies Talky spawns, and the zombie_killed event.
--   single player : the name stays in the zombie's own modData (0.3.0); the overlay finds it.
--   server        : a live table keyed by the zombie's online id, never saved (ids are reused
--                   after a restart). Clients get each change with sendServerCommand
--                   ("tag" / "untag"), and the whole list on request ("tags", late joiners).
--                   About once a second, entries of dead, recycled or changed zombies go away.
-- Runs on the server and in single player only.

if isClient() then return end

require "Talky/Talky_Config"
require "Talky/Talky_Net"

Talky_Tags = {
    live = {},       -- [tostring(onlineID)] = { z, name, color, owner, ownerKey, p, t }
    count = 0,
    perOwner = {},   -- [ownerKey] = number of entries
    lastSweep = 0,
}

local function now() return getTimestampMs() end

local function delta(e, id)
    return { id = id, n = e.name, c = e.color, p = e.p }
end

-- Removes an entry and tells every client.
function Talky_Tags.remove(key)
    local e = Talky_Tags.live[key]
    if not e then return end
    Talky_Tags.live[key] = nil
    Talky_Tags.count = Talky_Tags.count - 1
    Talky_Tags.perOwner[e.ownerKey] = math.max(0, (Talky_Tags.perOwner[e.ownerKey] or 1) - 1)
    TalkyNet.broadcast("untag", { id = tonumber(key) })
end

local function oldest(ownerKey)
    local key, t
    for k, e in pairs(Talky_Tags.live) do
        if (ownerKey == nil or e.ownerKey == ownerKey) and (t == nil or e.t < t) then key, t = k, e.t end
    end
    return key
end

-- Names a zombie. owner = username of the streamer whose job spawned it.
function Talky_Tags.tag(z, name, col, owner)
    name = TalkyNet.str(name, Talky_Config.maxNameLength, "")
    if name == "" then return end
    col = TalkyNet.color(col, nil)
    local md = z:getModData()
    md.Talky_name = name
    md.Talky_color = col
    if TalkyNet.mode() ~= "server" then
        -- single player: the overlay rescans the zombies now
        TalkyNet.toClient(getPlayer(), "tag", { sp = true })
        return
    end
    local id = z:getOnlineID()
    if type(id) ~= "number" or id < 0 then return end
    local key = tostring(id)
    md.Talky_tag = key
    if Talky_Tags.live[key] then Talky_Tags.remove(key) end
    local ownerKey = TalkyNet.nameKey(tostring(owner or ""))
    while (Talky_Tags.perOwner[ownerKey] or 0) >= Talky_Config.maxTagsPerOwner do
        local k = oldest(ownerKey)
        if not k then break end
        Talky_Tags.remove(k)
    end
    while Talky_Tags.count >= Talky_Config.maxTags do
        local k = oldest(nil)
        if not k then break end
        Talky_Tags.remove(k)
    end
    local p = 0
    pcall(function() p = z:getPersistentOutfitID() end)
    local e = { z = z, name = name, color = col, owner = tostring(owner or ""), ownerKey = ownerKey, p = p, t = now() }
    Talky_Tags.live[key] = e
    Talky_Tags.count = Talky_Tags.count + 1
    Talky_Tags.perOwner[ownerKey] = (Talky_Tags.perOwner[ownerKey] or 0) + 1
    TalkyNet.broadcast("tag", delta(e, id))
end

-- Every entry, to one client, in chunks of 100 (the first one says "start over").
function Talky_Tags.sendSnapshot(player)
    local chunk, first = {}, true
    for key, e in pairs(Talky_Tags.live) do
        chunk[#chunk + 1] = delta(e, tonumber(key))
        if #chunk >= 100 then
            TalkyNet.toClient(player, "tags", { reset = first, list = chunk })
            chunk, first = {}, false
        end
    end
    if first or #chunk > 0 then TalkyNet.toClient(player, "tags", { reset = first, list = chunk }) end
end

local function stillValid(key, e, t)
    local z = e.z
    if z:isDead() then return false end
    if tostring(z:getOnlineID()) ~= key then return false end
    local md = z:getModData()
    if md.Talky_tag ~= key or md.Talky_name ~= e.name then return false end
    return t - e.t < Talky_Config.tagTtlMs
end

function Talky_Tags.sweep()
    local t = now()
    if t - Talky_Tags.lastSweep < 1000 and t >= Talky_Tags.lastSweep then return end
    Talky_Tags.lastSweep = t
    local gone = {}
    for key, e in pairs(Talky_Tags.live) do
        local ok, keep = pcall(stillValid, key, e, t)
        if not ok or not keep then gone[#gone + 1] = key end
    end
    for _, key in ipairs(gone) do Talky_Tags.remove(key) end
end

---------------------------------------------------------------- deaths

-- zombie_killed for the bridge of the owner, and the banner (owner, or everyone with
-- Talky.BannerAudience = 2, within the banner budget of notify steps: 6 a minute per streamer,
-- 20 in all; beyond, to the owner only). Nothing when the owner is offline.
-- Talky_ServerRunner is read at call time: it requires this file, a require here would loop.
local function killed(owner, ownerName, ownerKey, name, byPlayer)
    if not owner then return end
    TalkyNet.toClient(owner, "emit", { event = "zombie_killed", data = { name = name, byPlayer = byPlayer == true } })
    local fx = { kind = "notify", tkey = "Toast_ZombieDown", arg = name, color = "#ff5555" }
    local caps = Talky_Config.caps()
    local R = Talky_ServerRunner
    if caps.enforce and caps.audience == 2 and (not (R and R.broadcastOk) or R.broadcastOk(ownerKey, getTimestampMs())) then
        fx.from = TalkyNet.str(ownerName, 32, "")
        TalkyNet.broadcast("fx", fx)
    else
        TalkyNet.toClient(owner, "fx", fx)
    end
end

local function attackerName(zombie)
    local ok, attacker = pcall(function() return zombie:getAttackedBy() end)
    if not ok or attacker == nil then return nil end
    local ok2, name = pcall(function() return attacker:getUsername() end)
    if not ok2 or name == nil then return nil end
    return tostring(name)
end

-- Fires once per zombie: burning zombies trigger OnZombieDead twice.
function Talky_Tags.onZombieDead(zombie)
    local mode = TalkyNet.mode()
    if mode == "client" then return end
    local md = zombie:getModData()
    if mode == "sp" then
        local name = md.Talky_name
        if not name or md.Talky_killed then return end
        md.Talky_killed = true
        local player = getPlayer()
        local ok, attacker = pcall(function() return zombie:getAttackedBy() end)
        killed(player, TalkyNet.username(player), TalkyNet.userKey(player), tostring(name), ok and player ~= nil and attacker == player)
        return
    end
    local key = md.Talky_tag
    local e = key and Talky_Tags.live[key]
    if not e or e.z ~= zombie then return end
    Talky_Tags.remove(key)
    local by = attackerName(zombie)
    local owner = TalkyNet.findPlayer(e.owner)
    killed(owner, e.owner, e.ownerKey, e.name, by ~= nil and TalkyNet.nameKey(by) == e.ownerKey)
end

Events.OnZombieDead.Add(function(zombie)
    local ok, err = pcall(Talky_Tags.onZombieDead, zombie)
    if not ok then TalkyNet.log("zombie death: " .. tostring(err)) end
end)

Events.OnTick.Add(function()
    if Talky_Tags.count > 0 then
        local ok, err = pcall(Talky_Tags.sweep)
        if not ok then TalkyNet.log("tag sweep: " .. tostring(err)) end
    end
end)

return Talky_Tags
