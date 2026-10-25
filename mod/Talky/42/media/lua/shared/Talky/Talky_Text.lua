-- Interface texts. Every key "X" lives in media/lua/shared/Translate/<LANG>/UI.json as
-- "UI_Talky_X"; the game falls back to EN when the player's language has no file or key.
-- Values use %1, %2... for arguments (no other "%": the game formats them with Java).

Talky_Text = {}

local PREFIX = "UI_Talky_"

local function str(v)
    if v == nil then return "" end
    return tostring(v)
end

-- Translated text, or nil when the key does not exist.
function Talky_Text.getOrNil(key, ...)
    local full = PREFIX .. key
    local n = select("#", ...)
    local a, b, c, d = ...
    local txt
    if n == 0 then
        txt = getTextOrNull(full)
    elseif n == 1 then
        txt = getTextOrNull(full, str(a))
    elseif n == 2 then
        txt = getTextOrNull(full, str(a), str(b))
    elseif n == 3 then
        txt = getTextOrNull(full, str(a), str(b), str(c))
    else
        txt = getTextOrNull(full, str(a), str(b), str(c), str(d))
    end
    if txt == nil or txt == "" then return nil end
    return txt
end

-- Talky_T("Status_Online", port, pending): translated text, or the key itself when missing.
function Talky_T(key, ...)
    return Talky_Text.getOrNil(key, ...) or (PREFIX .. key)
end

-- "fr" or "en" from the game language, used as default for settings.language.
function Talky_Text.gameLanguage()
    local ok, name = pcall(function() return Translator.getLanguage():name() end)
    if ok and name == "FR" then return "fr" end
    return "en"
end

return Talky_Text
