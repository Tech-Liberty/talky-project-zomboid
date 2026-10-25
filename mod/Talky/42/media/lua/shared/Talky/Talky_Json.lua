-- Minimal JSON encoder/decoder for Kahlua (Project Zomboid's Lua VM has no json lib).
-- Decodes objects, arrays, strings (with \uXXXX in the BMP), numbers, true/false/null.

TalkyJson = TalkyJson or {}

local sub, byte, find = string.sub, string.byte, string.find

local function skipWs(s, i)
    local _, e = find(s, "^[ \n\r\t]*", i)
    return e + 1
end

local decodeValue

local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function decodeString(s, i)
    -- s[i] == '"'
    local out, n = {}, 0
    local j = i + 1
    while true do
        local c = sub(s, j, j)
        if c == "" then error("TalkyJson: unterminated string") end
        if c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local e = sub(s, j + 1, j + 1)
            if e == "u" then
                local code = tonumber(sub(s, j + 2, j + 5), 16) or 63
                n = n + 1; out[n] = string.char(code)
                j = j + 6
            else
                n = n + 1; out[n] = escapes[e] or e
                j = j + 2
            end
        else
            -- copy a run of plain characters in one go
            local _, e = find(s, '^[^"\\]+', j)
            n = n + 1; out[n] = sub(s, j, e)
            j = e + 1
        end
    end
end

local function decodeNumber(s, i)
    local _, e = find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not e then error("TalkyJson: bad number at " .. i) end
    return tonumber(sub(s, i, e)), e + 1
end

local function decodeArray(s, i)
    local arr, n = {}, 0
    i = skipWs(s, i + 1)
    if sub(s, i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = decodeValue(s, i)
        n = n + 1; arr[n] = v
        i = skipWs(s, i)
        local c = sub(s, i, i)
        if c == "]" then return arr, i + 1 end
        if c ~= "," then error("TalkyJson: expected , or ] at " .. i) end
        i = skipWs(s, i + 1)
    end
end

local function decodeObject(s, i)
    local obj = {}
    i = skipWs(s, i + 1)
    if sub(s, i, i) == "}" then return obj, i + 1 end
    while true do
        if sub(s, i, i) ~= '"' then error("TalkyJson: expected key at " .. i) end
        local k
        k, i = decodeString(s, i)
        i = skipWs(s, i)
        if sub(s, i, i) ~= ":" then error("TalkyJson: expected : at " .. i) end
        local v
        v, i = decodeValue(s, skipWs(s, i + 1))
        obj[k] = v
        i = skipWs(s, i)
        local c = sub(s, i, i)
        if c == "}" then return obj, i + 1 end
        if c ~= "," then error("TalkyJson: expected , or } at " .. i) end
        i = skipWs(s, i + 1)
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = sub(s, i, i)
    if c == "{" then return decodeObject(s, i) end
    if c == "[" then return decodeArray(s, i) end
    if c == '"' then return decodeString(s, i) end
    if sub(s, i, i + 3) == "true" then return true, i + 4 end
    if sub(s, i, i + 4) == "false" then return false, i + 5 end
    if sub(s, i, i + 3) == "null" then return nil, i + 4 end
    return decodeNumber(s, i)
end

function TalkyJson.decode(s)
    local v = decodeValue(s, 1)
    return v
end

-- Returns value or nil, err (never throws)
function TalkyJson.tryDecode(s)
    local ok, v = pcall(TalkyJson.decode, s)
    if ok then return v end
    return nil, v
end

local function encodeString(s)
    s = string.gsub(s, '[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", byte(c))
    end)
    return '"' .. s .. '"'
end

local function isArray(t)
    local n = #t
    if n == 0 then return false end -- empty tables encode as {} (Kahlua has no next())
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n then return false end
    end
    return true
end

-- encode(v) is compact; encode(v, "  ") is indented with sorted keys (for files people may edit).
function TalkyJson.encode(v, indent, depth)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return tostring(v)
    end
    if t == "string" then return encodeString(v) end
    if t == "table" then
        depth = depth or 0
        local nl, pad, padIn, sep = "", "", "", ":"
        if indent then
            nl = "\n"
            pad = string.rep(indent, depth)
            padIn = pad .. indent
            sep = ": "
        end
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = padIn .. TalkyJson.encode(v[i], indent, depth + 1) end
            return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        if #keys == 0 then return "{}" end
        if indent then table.sort(keys) end
        for i, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            parts[i] = padIn .. encodeString(k) .. sep .. TalkyJson.encode(val, indent, depth + 1)
        end
        return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "}"
    end
    return encodeString(tostring(v))
end

return TalkyJson
