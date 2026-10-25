-- Opening key, listed in Options > Keybinds under "Talky" (saved by the game with its own keys).

require "Talky/UI/Talky_Window"

local BIND = "Talky_OpenMenu"

Events.OnGameBoot.Add(function()
    if type(keyBinding) ~= "table" then return end
    table.insert(keyBinding, { value = "[Talky]" })
    table.insert(keyBinding, { value = BIND, key = Keyboard.KEY_F8 })
end)

Events.OnKeyPressed.Add(function(key)
    if not getPlayer() then return end
    local bound = getCore():getKey(BIND)
    if bound == 0 or bound == nil then bound = Keyboard.KEY_F8 end
    if key == bound then Talky_Window.toggle() end
end)
