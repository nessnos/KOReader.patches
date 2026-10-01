--[[
2-no-open-close-popup.lua  —  KOReader user patch
Put this file in koreader/patches/ and restart KOReader.

Hides the two short popups shown while a book loads or unloads:
  * "Opening file '…'."      (KOReader itself, ReaderUI:showReaderCoroutine)
  * "Closing book…"          (SimpleUI / KindleUI, shown from the CloseDocument event)

The screen simply keeps showing what it showed (library or book page) until the
book has finished opening or closing.

How: while a book is being opened or closed, any InfoMessage with timeout 0
(the "auto-close on next tick" notices these two use) is not shown. Errors and
messages that wait for a tap (timeout nil) still appear. It doesn't depend on
the UI language.

If you installed another patch that only hides the opening popup, remove it.
]]

local ReaderUI    = require("apps/reader/readerui")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")

local suppress = 0 -- > 0 while opening/closing

local function isQuickInfoMessage(widget)
    if type(widget) ~= "table" or widget.timeout ~= 0 then return false end
    local mt = getmetatable(widget)
    local guard = 0
    while mt and guard < 20 do
        local cls = mt.__index
        if cls == InfoMessage then return true end
        if type(cls) ~= "table" then break end
        mt = getmetatable(cls)
        guard = guard + 1
    end
    return false
end

local orig_show = UIManager.show
function UIManager:show(widget, ...)
    if suppress > 0 and isQuickInfoMessage(widget) then
        logger.dbg("no-open-close-popup: skipped", tostring(widget.text))
        return
    end
    return orig_show(self, widget, ...)
end

local function finish(ok, ...)
    suppress = suppress - 1
    if not ok then error((...), 0) end
    return ...
end

local function guarded(fn, ...)
    suppress = suppress + 1
    return finish(pcall(fn, ...))
end

-- Opening: the popup is shown synchronously before the reader is built on the next tick.
local orig_showReaderCoroutine = ReaderUI.showReaderCoroutine
function ReaderUI:showReaderCoroutine(...)
    return guarded(orig_showReaderCoroutine, self, ...)
end

-- Closing: SimpleUI/KindleUI shows "Closing book…" from the CloseDocument
-- event, which ReaderUI:onClose sends.
local orig_onClose = ReaderUI.onClose
function ReaderUI:onClose(...)
    return guarded(orig_onClose, self, ...)
end
