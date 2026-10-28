-- Sources, translations, sandbox options, and the copy rules of the network.

local ROOT, MEDIA = __MOD_ROOT, __MOD_MEDIA

---------------------------------------------------------------- sources

section("sources")

local sources = {}   -- rel -> text
for _, rel in ipairs(__LUA_FILES) do sources[rel] = __readFile(ROOT .. "/" .. rel) or "" end

-- Code without comments (good enough for these greps: no "--" inside the mod's strings).
local function code(text)
    text = string.gsub(text, "%-%-%[%[.-%]%]", "")
    local out = {}
    for _, line in ipairs(H.splitLines(text)) do
        local cut = string.find(line, "%-%-")
        if cut then line = string.sub(line, 1, cut - 1) end
        out[#out + 1] = line
    end
    return table.concat(out, "\n")
end

local function startsWith(s, p) return string.sub(s, 1, string.len(p)) == p end

local nonAscii, noGuard, fileIO, clientNames, forbidden, badCalls = {}, {}, {}, {}, {}, {}
local clientModules = {}
for rel in pairs(sources) do
    if startsWith(rel, "client/") then clientModules[string.sub(rel, 8, string.len(rel) - 4)] = true end
end
local CLIENT_GLOBALS = { "Talky_Bridge", "Talky_Overlay", "Talky_Client", "Talky_Settings", "Talky_Window", "Talky_UI",
                         "Talky_StepEditor", "Talky_JsonEditor", "Talky_Runner" }
local SERVER_FORBIDDEN = { "getPlayerFromUsername", "isAdmin%s*%(", "isCoopHost", "hasAdminPower", "getAccessLevel" }

for rel, text in pairs(sources) do
    for i = 1, string.len(text) do
        if string.byte(text, i) > 127 then nonAscii[#nonAscii + 1] = rel; break end
    end
    local c = code(text)
    if string.find(c, "[^%w_%.:]next%s*%(") then badCalls[#badCalls + 1] = rel .. " (next)" end
    if string.find(c, "ModData%.") then badCalls[#badCalls + 1] = rel .. " (global ModData)" end
    if startsWith(rel, "server/") then
        local first
        for _, line in ipairs(H.splitLines(c)) do
            if string.match(line, "%S") then first = line; break end
        end
        if not first or not string.match(first, "^%s*if%s+isClient%(%)%s+then%s+return%s+end%s*$") then noGuard[#noGuard + 1] = rel end
    end
    if startsWith(rel, "shared/") or startsWith(rel, "server/") then
        for _, f in ipairs({ "getFileReader", "getFileWriter", "getModFile" }) do
            if string.find(c, f) then fileIO[#fileIO + 1] = rel .. " (" .. f .. ")" end
        end
        for _, g in ipairs(CLIENT_GLOBALS) do
            if string.find(c, g .. "[^%w_]") then clientNames[#clientNames + 1] = rel .. " (" .. g .. ")" end
        end
        for mod in string.gmatch(c, "require%s*%(?%s*[\"']([^\"']+)[\"']") do
            if clientModules[mod] then clientNames[#clientNames + 1] = rel .. " (require " .. mod .. ")" end
        end
        for _, pat in ipairs(SERVER_FORBIDDEN) do
            if string.find(c, pat) then forbidden[#forbidden + 1] = rel .. " (" .. pat .. ")" end
        end
    end
end
local function show(list) table.sort(list); return #list > 0 and (" (" .. table.concat(list, ", ") .. ")") or "" end
check(#nonAscii == 0, "every Lua file is ASCII (Kahlua mangles accented characters in compiled strings)" .. show(nonAscii))
check(#noGuard == 0, "every server/ file starts with 'if isClient() then return end' (server files also run on clients)" .. show(noGuard))
check(#fileIO == 0, "shared/ and server/ files never open files (a hosted game's server shares Zomboid/Lua)" .. show(fileIO))
check(#clientNames == 0, "shared/ and server/ files never name or require a client/ module (it would run on the server)" .. show(clientNames))
check(#forbidden == 0, "shared/ and server/ files never call getPlayerFromUsername, isAdmin, isCoopHost, hasAdminPower, getAccessLevel" .. show(forbidden))
check(#badCalls == 0, "no next() (missing in this Kahlua) and no global ModData (R9)" .. show(badCalls))
-- talky_status.json carries no token since 0.4.0 and a webhook's token lives in bridge/config.json:
-- no code reads a "token" field (the window never builds nor copies a URL with a token)
local tokenReads = {}
for rel, text in pairs(sources) do
    local c = code(text)
    if string.find(c, "%.token[^%w_]") or string.find(c, "%[%s*[\"']token[\"']%s*%]") then tokenReads[#tokenReads + 1] = rel end
end
check(#tokenReads == 0, "no Lua file of the mod reads a token field (talky_status.json has none, webhook tokens stay in bridge/config.json)" .. show(tokenReads))

---------------------------------------------------------------- UI translations

section("translations")

local UI_EN, UI_FR = H.UI.EN, H.UI.FR
local function keysOf(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end
local function placeholders(v)
    local found = {}
    for d in string.gmatch(v, "%%(%d)") do found[#found + 1] = d end
    table.sort(found)
    return table.concat(found, ",")
end

check(H.count(UI_EN) > 100 and H.count(UI_FR) > 100, "UI.json read in EN and FR")
local sameKeys, sameArgs, noStrayPercent = true, true, true
for _, k in ipairs(keysOf(UI_EN)) do
    if UI_FR[k] == nil then sameKeys = false; print("        missing in FR: " .. k) end
end
for _, k in ipairs(keysOf(UI_FR)) do
    if UI_EN[k] == nil then sameKeys = false; print("        missing in EN: " .. k) end
end
for _, k in ipairs(keysOf(UI_EN)) do
    local en, fr = UI_EN[k], UI_FR[k]
    if fr and placeholders(en) ~= placeholders(fr) then sameArgs = false; print("        arguments differ: " .. k) end
    for _, v in ipairs({ en, fr or "" }) do
        local stripped = string.gsub(v, "%%%d", "")
        if string.find(stripped, "%%") then noStrayPercent = false; print("        stray % in " .. k) end
    end
end
check(sameKeys, "EN and FR UI.json have the same keys")
check(sameArgs, "EN and FR texts take the same %1, %2... arguments")
check(noStrayPercent, "no '%' outside %1..%9 (the game formats texts with Java)")

-- Every key named in the code exists
local referenced, unknown = {}, {}
local patterns = { 'Talky_T%("([%w_]+)"', 'getOrNil%("([%w_]+)"', 'labelKey%s*=%s*"([%w_]+)"', 'defaultKey%s*=%s*"([%w_]+)"', '{%s*"(Lang_%w+)"' }
for _, src in pairs(sources) do
    for _, pat in ipairs(patterns) do
        for key in string.gmatch(src, pat) do referenced[key] = true end
    end
end
-- keys built at run time: Reason_<code> (refusals for good; too_large = never sent by this game,
-- unknown = the bridge's word for a reason it could not read), Cat_<category> (F8 Status page)
for _, r in ipairs({ "not_allowed", "invalid", "duplicate", "unknown_action", "disabled", "expired", "too_large", "unknown" }) do
    referenced["Reason_" .. r] = true
end
for _, cat in ipairs({ "zombies", "items", "vehicles", "xp", "playerEffects", "weather", "time", "fire", "helicopter", "sounds" }) do
    referenced["Cat_" .. cat] = true
end
local count = 0
for key in pairs(referenced) do
    count = count + 1
    if UI_EN["UI_Talky_" .. key] == nil then unknown[#unknown + 1] = key end
end
table.sort(unknown)
for _, k in ipairs(unknown) do print("        unknown key: UI_Talky_" .. k) end
check(count > 100 and #unknown == 0, "every key used by the code exists in UI.json (" .. count .. " keys)")

---------------------------------------------------------------- sandbox options

section("sandbox options")

local text = __readFile(MEDIA .. "/sandbox-options.txt")
check(text ~= nil, "media/sandbox-options.txt exists")
text = text or ""
local firstLine
for _, l in ipairs(H.splitLines(text)) do
    if string.match(l, "%S") then firstLine = l; break end
end
check(firstLine ~= nil and string.match(firstLine, "^%s*VERSION%s*=%s*1%s*,%s*$") ~= nil, "starts with 'VERSION = 1,' (the game drops the file otherwise)")

local options, order, problems = {}, {}, {}
for name, body in string.gmatch(text, "option%s+([%w_%.]+)%s*{(.-)}") do
    local o = { name = name }
    for k, v in string.gmatch(body, "([%w_]+)%s*=%s*([^,\n]*),") do o[k] = string.match(v, "^%s*(.-)%s*$") end
    options[name] = o
    order[#order + 1] = name
end
local TYPES = { boolean = true, double = true, enum = true, integer = true, string = true }
for _, name in ipairs(order) do
    local o = options[name]
    local short = string.match(name, "^Talky%.([%w_]+)$")
    if not short then problems[#problems + 1] = name .. ": not Talky.<Name>" end
    if not TYPES[o.type or ""] then problems[#problems + 1] = name .. ": type " .. tostring(o.type) end
    if o.default == nil then problems[#problems + 1] = name .. ": no default (a string option without one is dropped)" end
    if o.page ~= "Talky" then problems[#problems + 1] = name .. ": page " .. tostring(o.page) end
    if short and o.translation ~= "Talky_" .. short then problems[#problems + 1] = name .. ": translation " .. tostring(o.translation) end
    if o.type == "integer" or o.type == "double" then
        local lo, hi, def = tonumber(o.min or ""), tonumber(o.max or ""), tonumber(o.default or "")
        if not lo or not hi or not def or def < lo or def > hi then problems[#problems + 1] = name .. ": bad min/max/default" end
    elseif o.type == "boolean" then
        if o.default ~= "true" and o.default ~= "false" then problems[#problems + 1] = name .. ": boolean default " .. tostring(o.default) end
    elseif o.type == "enum" then
        local n, def = tonumber(o.numValues or ""), tonumber(o.default or "")
        if not n or not def or def < 1 or def > n then problems[#problems + 1] = name .. ": bad enum" end
        if short and o.valueTranslation ~= "Talky_" .. short then problems[#problems + 1] = name .. ": valueTranslation" end
    end
end
for _, p in ipairs(problems) do print("        " .. p) end
check(#order > 20 and #problems == 0, "every option is well formed (" .. #order .. " options)")

-- the same list in Talky_Config.sandbox (defaults used when SandboxVars.Talky is missing)
local CE = __newEnv()
CE.getTimestampMs = function() return NOW end
local fn = __load(CE, ROOT .. "/shared/Talky/Talky_Config.lua", "shared/Talky/Talky_Config.lua")
fn()
local config = CE.Talky_Config
local TYPE_OF = { bool = "boolean", int = "integer", enum = "enum", string = "string" }
local mismatch, seen = {}, {}
for _, s in ipairs(config.sandbox) do
    local o = options["Talky." .. s.name]
    seen["Talky." .. s.name] = true
    if not o then
        mismatch[#mismatch + 1] = s.name .. " missing in sandbox-options.txt"
    else
        if TYPE_OF[s.type] ~= o.type then mismatch[#mismatch + 1] = s.name .. " type" end
        local def = o.default
        if s.type == "bool" then def = (def == "true") elseif s.type ~= "string" then def = tonumber(def) end
        if def ~= s.default then mismatch[#mismatch + 1] = s.name .. " default " .. tostring(o.default) .. " / " .. tostring(s.default) end
        if s.type == "int" and (tonumber(o.min) ~= s.min or tonumber(o.max) ~= s.max) then mismatch[#mismatch + 1] = s.name .. " bounds" end
        if s.type == "enum" and tonumber(o.numValues) ~= s.max then mismatch[#mismatch + 1] = s.name .. " numValues" end
    end
end
for _, name in ipairs(order) do
    if not seen[name] then mismatch[#mismatch + 1] = name .. " missing in Talky_Config.sandbox" end
end
for _, m in ipairs(mismatch) do print("        " .. m) end
check(#mismatch == 0, "sandbox-options.txt and Talky_Config.sandbox list the same options, types, defaults and bounds")

-- translations: lua/shared/Translate/<LANG>/Sandbox.json
local SB_EN, SB_FR = H.SANDBOX_TEXT.EN, H.SANDBOX_TEXT.FR
local expected = { Sandbox_Talky = true }
for _, name in ipairs(order) do
    local short = string.match(name, "^Talky%.([%w_]+)$") or name
    expected["Sandbox_Talky_" .. short] = true
    expected["Sandbox_Talky_" .. short .. "_tooltip"] = true
    if options[name].type == "enum" then
        for i = 1, tonumber(options[name].numValues or "0") or 0 do expected["Sandbox_Talky_" .. short .. "_option" .. i] = true end
    end
end
local sbMissing, sbExtra = {}, {}
for _, lang in ipairs({ "EN", "FR" }) do
    local t = H.SANDBOX_TEXT[lang]
    for k in pairs(expected) do
        if type(t[k]) ~= "string" or t[k] == "" then sbMissing[#sbMissing + 1] = lang .. " " .. k end
    end
    for k in pairs(t) do
        if not expected[k] then sbExtra[#sbExtra + 1] = lang .. " " .. k end
    end
end
check(H.count(SB_EN) > 0 and H.count(SB_EN) == H.count(SB_FR), "Sandbox.json in EN and FR (" .. H.count(SB_EN) .. " keys each)")
check(#sbMissing == 0, "every option has its name and tooltip (and enum values) in EN and FR" .. show(sbMissing))
check(#sbExtra == 0, "no Sandbox.json key without an option" .. show(sbExtra))

---------------------------------------------------------------- network copy rules

section("network copy")

-- TalkyNet.copy (the single player queue) must deliver what the network delivers.
local P = H.process("copy", "sp", {})
P.E.require("Talky/Talky_Net")
local TN = P.E.TalkyNet

local function same(a, b, depth)
    depth = depth or 0
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then
        if a ~= a and b ~= b then return true end
        return a == b
    end
    if depth > 20 then return false end
    for k, v in pairs(a) do
        if not same(v, b[k], depth + 1) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local samples = {
    { s = "x\nnew line", n = 1.5, b = false, sub = {}, deep = { { 1, 2 }, { x = {} } }, f = function() end, [true] = 1, [2.5] = "k" },
    {},
    { list = {} },
    { 1, 2, 3, v = 0 / 0, h = math.huge },
    { player = H.java("IsoPlayer", { getUsername = function() return "x" end }), ok = 1 },
}
local allSame = true
for i, s in ipairs(samples) do
    local net = H.netArgs(P, s)
    local mine = TN.copy(s)
    if i == 5 then
        -- the game drops a game object; the single player copy of a fake (Lua table) object
        -- cannot know it is one: compare without it
        mine.player = nil
    end
    if not same(net, mine) then allSame = false; print("        sample " .. i .. " differs") end
end
P.misuse = {}
check(allSame, "TalkyNet.copy delivers what the game's serializer delivers (" .. tostring(__NET_COPY) .. ")")
local c = H.netArgs(P, samples[1])
check(c.f == nil and c[true] == nil and type(c.sub) == "table" and c.deep[2].x ~= nil and c[2.5] == "k",
    "functions and boolean keys are dropped, nested empty tables kept")
check(H.netArgs(P, {}) == nil and H.netArgs(P, nil) == nil, "an empty table arrives as nil")
local nan = H.netArgs(P, { v = 0 / 0, h = math.huge })
check(nan.v ~= nan.v and nan.h == math.huge, "NaN and infinities cross the network: the receiver must check every number")
P.misuse = {}
H.net.javaDropped = 0
H.netArgs(P, samples[5])
check(H.net.javaDropped == 1 and #P.misuse == 1, "a game object in the args is dropped (and reported by the harness)")
P.misuse = {}
if __NET_COPY == "TableNetworkUtils" then
    -- the game's serializer sends directions (and items, dead bodies): a Java object arrives
    local d = H.netArgs(P, { d = P.E.IsoDirections.N, ok = 1 })
    check(d and type(d.d) == "userdata" and d.ok == 1 and #P.misuse == 1, "an IsoDirections in the args arrives as a game object (userdata), and is reported")
    P.misuse = {}
    -- the game's packet buffer holds 1,000,000 bytes: past it, sending throws (strings of
    -- 30,000 bytes: the length of a string is written as a signed short)
    local function texts(n)
        local t = {}
        for i = 1, n do t[i] = string.rep("x", 30000) end
        return t
    end
    local okBig = pcall(H.netArgs, P, { list = texts(30) })
    local okHuge = pcall(H.netArgs, P, { list = texts(34) })
    check(okBig and not okHuge, "a message past the game's 1,000,000-byte buffer throws, like sendClientCommand in the game")
end
check(#P.errors == 0, "TalkyNet loads alone")
