-- Small helpers around the vanilla ISUI widgets, with Talky's dark/purple look.

require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISTickBox"
require "ISUI/ISScrollingListBox"

Talky_UI = {
    FONT = UIFont.Small,
    FONT_MED = UIFont.Medium,
    LINE = getTextManager():getFontHeight(UIFont.Small),
    ROW = getTextManager():getFontHeight(UIFont.Small) + 10,
    col = {
        bg      = { r = 0.06, g = 0.06, b = 0.08, a = 0.97 },
        panel   = { r = 0.10, g = 0.10, b = 0.13, a = 1 },
        border  = { r = 0.25, g = 0.22, b = 0.32, a = 1 },
        accent  = { r = 0.55, g = 0.36, b = 0.96, a = 1 },
        text    = { r = 0.92, g = 0.92, b = 0.95, a = 1 },
        muted   = { r = 0.60, g = 0.60, b = 0.68, a = 1 },
        ok      = { r = 0.30, g = 0.85, b = 0.45, a = 1 },
        bad     = { r = 0.95, g = 0.30, b = 0.30, a = 1 },
    },
}

local C = Talky_UI.col

function Talky_UI.button(parent, x, y, w, title, target, onclick, style)
    local b = ISButton:new(x, y, w, Talky_UI.ROW, title, target, onclick)
    b:initialise()
    b:instantiate()
    b.borderColor = { r = C.border.r, g = C.border.g, b = C.border.b, a = 1 }
    if style == "primary" then
        b.backgroundColor = { r = C.accent.r * 0.7, g = C.accent.g * 0.7, b = C.accent.b * 0.7, a = 1 }
        b.backgroundColorMouseOver = { r = C.accent.r, g = C.accent.g, b = C.accent.b, a = 1 }
    elseif style == "danger" then
        b.backgroundColor = { r = 0.35, g = 0.08, b = 0.08, a = 1 }
        b.backgroundColorMouseOver = { r = 0.55, g = 0.12, b = 0.12, a = 1 }
    else
        b.backgroundColor = { r = 0.16, g = 0.15, b = 0.20, a = 1 }
        b.backgroundColorMouseOver = { r = 0.26, g = 0.22, b = 0.36, a = 1 }
    end
    parent:addChild(b)
    return b
end

function Talky_UI.label(parent, x, y, text, color, font)
    color = color or C.text
    local l = ISLabel:new(x, y, Talky_UI.ROW, text, color.r, color.g, color.b, color.a or 1, font or Talky_UI.FONT, true)
    l:initialise()
    parent:addChild(l)
    return l
end

-- onChange(target, text) is called on every keystroke.
function Talky_UI.entry(parent, x, y, w, text, target, onChange, h)
    local e = ISTextEntryBox:new(tostring(text or ""), x, y, w, h or Talky_UI.ROW)
    e:initialise()
    e:instantiate()
    e.backgroundColor = { r = 0.03, g = 0.03, b = 0.05, a = 1 }
    e.borderColor = { r = C.border.r, g = C.border.g, b = C.border.b, a = 1 }
    if onChange then
        e.target = target
        e.onTextChangeFunction = function(t, box) onChange(t, box:getInternalText()) end
    end
    parent:addChild(e)
    return e
end

function Talky_UI.multiline(parent, x, y, w, h, text)
    local e = ISTextEntryBox:new(tostring(text or ""), x, y, w, h)
    e:initialise()
    e:instantiate()
    e:setMultipleLine(true)
    e:setMaxLines(500)
    e:addScrollBars()
    e.backgroundColor = { r = 0.03, g = 0.03, b = 0.05, a = 1 }
    parent:addChild(e)
    return e
end

-- options: list of { text, data }; onChange(target, data)
function Talky_UI.combo(parent, x, y, w, options, selectedData, target, onChange)
    local c = ISComboBox:new(x, y, w, Talky_UI.ROW, target, function(t, box)
        if onChange then onChange(t, box:getOptionData(box.selected)) end
    end)
    c:initialise()
    c:instantiate()
    for _, o in ipairs(options) do
        c:addOptionWithData(o[1], o[2])
        if o[2] == selectedData then c.selected = #c.options end
    end
    parent:addChild(c)
    return c
end

-- onChange(target, checked)
function Talky_UI.tick(parent, x, y, w, text, checked, target, onChange)
    local t = ISTickBox:new(x, y, w, Talky_UI.ROW, "", target, function(tg, _, sel) if onChange then onChange(tg, sel) end end)
    t:initialise()
    t:instantiate()
    t:addOption(text)
    t:setSelected(1, checked == true)
    t.textColor = { r = C.text.r, g = C.text.g, b = C.text.b, a = 1 }
    parent:addChild(t)
    return t
end

-- onSelect(target, item)
function Talky_UI.list(parent, x, y, w, h, target, onSelect)
    local l = ISScrollingListBox:new(x, y, w, h)
    l:initialise()
    l:instantiate()
    l.font = Talky_UI.FONT
    l.fontHgt = Talky_UI.LINE
    l.itemheight = Talky_UI.LINE + 8
    l.drawBorder = true
    l.backgroundColor = { r = 0.03, g = 0.03, b = 0.05, a = 1 }
    l.borderColor = { r = C.border.r, g = C.border.g, b = C.border.b, a = 1 }
    l.selectionColor = { r = C.accent.r, g = C.accent.g, b = C.accent.b, a = 0.35 }
    if onSelect then l:setOnMouseDownFunction(target, onSelect) end
    parent:addChild(l)
    return l
end

-- Transparent container used for a page or a modal body.
function Talky_UI.panel(parent, x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p:initialise()
    p.background = false
    p.border = false
    if parent then parent:addChild(p) end
    return p
end

function Talky_UI.truncate(text, maxW, font)
    text = tostring(text or "")
    local tm = getTextManager()
    if tm:MeasureStringX(font or Talky_UI.FONT, text) <= maxW then return text end
    while string.len(text) > 1 and tm:MeasureStringX(font or Talky_UI.FONT, text .. "...") > maxW do
        text = string.sub(text, 1, string.len(text) - 1)
    end
    return text .. "..."
end
