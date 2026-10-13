--[[
    2-sleepscreen-progress-bar.lua  (KOReader user patch)

    Draws a plain reading-progress bar (no text) along one edge of the sleep
    screen, painted ON TOP of whatever the sleep screen shows (book cover,
    custom image, random image, book status, message...).

    Install: copy into  koreader/patches/  and restart KOReader.
    Settings: Settings > Screen > Sleep screen > Progress bar
      - Show progress bar        on/off
      - Position                 top / bottom / left / right
      - Thickness                px
      - Distance from edge       px  (0 = against the bezel)
      - Margin at both ends      px  (0 = full width / full height)
      - Read part color          gray presets, color presets (color screens), custom #RRGGBB
      - Unread part color        none (transparent) or any color
      - Reverse fill direction   (default: left→right / top→bottom)

    Progress source:
      - a book is open           → live current page / page count
      - file manager             → percent_finished saved in the book's .sdr
      - "custom image or cover"  → that chosen document's saved progress
    No book / never opened     → no bar.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local SETTING = "sleepscreen_progress_bar"

local DEFAULTS = {
    enabled = true,
    position = "bottom", -- top | bottom | left | right
    thickness = 10,      -- px
    edge_margin = 0,     -- px between bar and screen edge
    end_margin = 0,      -- px trimmed at both ends of the bar
    color = "#000000",   -- read part
    track = nil,         -- unread part (nil = transparent)
    reverse = false,
}

local function getSettings()
    local s = G_reader_settings:readSetting(SETTING) or {}
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil and k ~= "track" then s[k] = v end
    end
    return s
end

local function saveSetting(key, value)
    local s = G_reader_settings:readSetting(SETTING) or {}
    s[key] = value
    G_reader_settings:saveSetting(SETTING, s)
end

-- ---------------------------------------------------------------------------
-- Progress
-- ---------------------------------------------------------------------------
local function getProgress()
    local file
    if G_reader_settings:readSetting("screensaver_type") == "document_cover" then
        file = G_reader_settings:readSetting("screensaver_document_cover")
    end

    local reader = require("apps/reader/readerui").instance
    if reader and reader.document and (not file or file == reader.document.file) then
        local ok, pct = pcall(function()
            local cur = reader:getCurrentPage()
            local total = reader.document:getPageCount()
            if cur and total and total > 0 then return cur / total end
        end)
        if ok and pct then return pct end
        file = file or reader.document.file
    end

    file = file or G_reader_settings:readSetting("lastfile")
    if file and BookList.hasBookBeenOpened(file) then
        local ds = BookList.getDocSettings(file)
        local pct = ds and ds:readSetting("percent_finished")
        if type(pct) == "number" then return pct end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
local function paintRect(bb, x, y, w, h, hex)
    if w <= 0 or h <= 0 or not hex then return end
    local c = Blitbuffer.colorFromString(hex)
    if not c then return end
    -- Night mode inverts the whole screen: pre-invert so the real color shows.
    if Screen.night_mode then c = c:invert() end
    if Screen:isColorEnabled() then
        bb:paintRectRGB32(x, y, w, h, c)
    else
        bb:paintRect(x, y, w, h, c:getColor8())
    end
end

local function drawBar(bb, x0, y0, pct, s)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local t = math.max(1, math.floor(s.thickness))
    local em, im = math.max(0, s.edge_margin), math.max(0, s.end_margin)
    pct = math.max(0, math.min(1, pct))

    local horizontal = (s.position == "top" or s.position == "bottom")
    local bx, by, bw, bh
    if horizontal then
        bx, bw, bh = im, sw - 2 * im, t
        by = (s.position == "top") and em or (sh - em - t)
    else
        by, bh, bw = im, sh - 2 * im, t
        bx = (s.position == "left") and em or (sw - em - t)
    end
    if bw <= 0 or bh <= 0 then return end
    bx, by = x0 + bx, y0 + by

    -- unread part (track) first, then read part on top
    if s.track then paintRect(bb, bx, by, bw, bh, s.track) end

    if horizontal then
        local fw = math.floor(bw * pct + 0.5)
        local fx = s.reverse and (bx + bw - fw) or bx
        paintRect(bb, fx, by, fw, bh, s.color)
    else
        local fh = math.floor(bh * pct + 0.5)
        local fy = s.reverse and (by + bh - fh) or by
        paintRect(bb, bx, fy, bw, fh, s.color)
    end
end

-- ---------------------------------------------------------------------------
-- Hook the sleep screen widget
-- ---------------------------------------------------------------------------
local orig_init = ScreenSaverWidget.init
ScreenSaverWidget.init = function(self, ...)
    orig_init(self, ...)
    local s = getSettings()
    if s.enabled then
        local ok, pct = pcall(getProgress)
        if ok then
            self._ssbar_pct = pct
        else
            logger.warn("sleepscreen-progress-bar: progress error", pct)
        end
    end
end

local orig_paintTo = ScreenSaverWidget.paintTo or InputContainer.paintTo
ScreenSaverWidget.paintTo = function(self, bb, x, y)
    orig_paintTo(self, bb, x, y)
    if self._ssbar_pct then
        local ok, err = pcall(drawBar, bb, x or 0, y or 0, self._ssbar_pct, getSettings())
        if not ok then logger.warn("sleepscreen-progress-bar: draw error", err) end
    end
end

-- ---------------------------------------------------------------------------
-- Menu: Settings > Screen > Sleep screen > Progress bar
-- ---------------------------------------------------------------------------
local GRAYS = {
    { _("Black"), "#000000" },
    { _("Dark gray"), "#555555" },
    { _("Gray"), "#888888" },
    { _("Light gray"), "#BBBBBB" },
    { _("White"), "#FFFFFF" },
}
local COLORS = {
    { _("Red"), "#E53935" },
    { _("Orange"), "#FB8C00" },
    { _("Yellow"), "#FDD835" },
    { _("Green"), "#43A047" },
    { _("Blue"), "#1E88E5" },
    { _("Purple"), "#8E24AA" },
}

local function colorName(hex)
    if not hex then return _("none") end
    for _i, c in ipairs(GRAYS) do if c[2]:upper() == hex:upper() then return c[1] end end
    for _i, c in ipairs(COLORS) do if c[2]:upper() == hex:upper() then return c[1] end end
    return hex
end

local function isPreset(hex)
    if not hex then return true end
    for _i, c in ipairs(GRAYS) do if c[2]:upper() == hex:upper() then return true end end
    for _i, c in ipairs(COLORS) do if c[2]:upper() == hex:upper() then return true end end
    return false
end

local function colorMenu(key, allow_none)
    local items = {}
    if allow_none then
        table.insert(items, {
            text = _("None (transparent)"),
            radio = true,
            checked_func = function() return getSettings()[key] == nil end,
            callback = function() saveSetting(key, nil) end,
            separator = true,
        })
    end
    local function add(list, sep)
        for i, c in ipairs(list) do
            table.insert(items, {
                text = c[1],
                radio = true,
                checked_func = function()
                    local v = getSettings()[key]
                    return v and v:upper() == c[2]:upper()
                end,
                callback = function() saveSetting(key, c[2]) end,
                separator = sep and i == #list,
            })
        end
    end
    add(GRAYS, true)
    if Screen:isColorEnabled() then add(COLORS, true) end
    table.insert(items, {
        text_func = function()
            local v = getSettings()[key]
            return (v and not isPreset(v)) and T(_("Custom: %1"), v) or _("Custom (#RRGGBB)…")
        end,
        radio = true,
        checked_func = function() return not isPreset(getSettings()[key]) end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local InputDialog = require("ui/widget/inputdialog")
            local dialog
            dialog = InputDialog:new{
                title = _("Bar color (hex)"),
                input = getSettings()[key] or "#000000",
                input_hint = "#RRGGBB",
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    { text = _("Set"), is_enter_default = true, callback = function()
                        local v = dialog:getInputText():gsub("%s", "")
                        if not v:match("^#") then v = "#" .. v end
                        if v:match("^#%x%x%x%x%x%x$") then
                            saveSetting(key, v:upper())
                            UIManager:close(dialog)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        else
                            local Notification = require("ui/widget/notification")
                            Notification:notify(_("Use the format #RRGGBB"))
                        end
                    end },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    })
    return items
end

local function spinItem(text, key, min, max, title)
    return {
        text_func = function() return T(text, getSettings()[key]) end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = title,
                value = getSettings()[key],
                value_min = min,
                value_max = max,
                value_step = 1,
                value_hold_step = 10,
                default_value = DEFAULTS[key],
                unit = "px",
                callback = function(spin)
                    saveSetting(key, spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

local function positionItem(text, value)
    return {
        text = text,
        radio = true,
        checked_func = function() return getSettings().position == value end,
        callback = function() saveSetting("position", value) end,
    }
end

local function buildMenu()
    local enabled = function() return getSettings().enabled end
    local menu = {
        text = _("Progress bar"),
        sub_item_table = {
            {
                text = _("Show progress bar"),
                checked_func = enabled,
                callback = function() saveSetting("enabled", not getSettings().enabled) end,
                separator = true,
            },
            {
                text_func = function()
                    local p = getSettings().position
                    local names = { top = _("top"), bottom = _("bottom"), left = _("left"), right = _("right") }
                    return T(_("Position: %1"), names[p] or p)
                end,
                enabled_func = enabled,
                sub_item_table = {
                    positionItem(_("Top"), "top"),
                    positionItem(_("Bottom"), "bottom"),
                    positionItem(_("Left"), "left"),
                    positionItem(_("Right"), "right"),
                },
            },
            spinItem(_("Thickness: %1 px"), "thickness", 1, 300, _("Bar thickness")),
            spinItem(_("Distance from edge: %1 px"), "edge_margin", 0, 500, _("Distance from screen edge")),
            spinItem(_("Margin at both ends: %1 px"), "end_margin", 0, 800, _("Margin at both ends")),
            {
                text_func = function() return T(_("Read part color: %1"), colorName(getSettings().color)) end,
                enabled_func = enabled,
                sub_item_table_func = function() return colorMenu("color", false) end,
            },
            {
                text_func = function() return T(_("Unread part color: %1"), colorName(getSettings().track)) end,
                enabled_func = enabled,
                sub_item_table_func = function() return colorMenu("track", true) end,
            },
            {
                text = _("Reverse fill direction"),
                help_text = _("Default fills left → right (top/bottom bars) and top → bottom (left/right bars)."),
                enabled_func = enabled,
                checked_func = function() return getSettings().reverse end,
                callback = function() saveSetting("reverse", not getSettings().reverse) end,
            },
        },
    }
    for i = 3, 5 do menu.sub_item_table[i].enabled_func = enabled end
    return menu
end

-- The sleep screen menu is (re)loaded with dofile() each time the main menu is built.
local orig_dofile = dofile
dofile = function(path, ...)
    local res = { orig_dofile(path, ...) }
    if type(path) == "string" and path:match("screensaver_menu%.lua$") and type(res[1]) == "table" then
        local ok, item = pcall(buildMenu)
        if ok then
            table.insert(res[1], math.min(3, #res[1] + 1), item)
        else
            logger.warn("sleepscreen-progress-bar: menu error", item)
        end
    end
    return unpack(res)
end
