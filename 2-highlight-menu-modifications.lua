local ReaderHighlight = require("apps/reader/modules/readerhighlight")
local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local util = require("util")
local Event = require("ui/event")
local logger = require("logger")
local Screen = require("device").screen

--=====================================================================
--  SETTINGS — edit these
--=====================================================================

-- Put your icon files (.svg or .png) in:  koreader/icons/
-- and write the file name WITHOUT the extension below.
-- If an icon file is missing, the button shows the text label instead.
--
-- Optional: an icon named "<icon>_on" (e.g. hl_pink_on.svg) is used to show
-- the current colour when you tap an existing highlight (like a circled dot).

-- Row 1: colour buttons (left to right).
-- KOReader colours: "red", "orange", "yellow", "green", "olive", "cyan",
--                   "blue", "purple", "gray" — plus "pink", added below.
local COLOR_BUTTONS = {
    { color = "pink",   icon = "hl_pink",   text = "Pink"   },
    { color = "yellow", icon = "hl_yellow", text = "Yellow" },
    { color = "blue",   icon = "hl_blue",   text = "Blue"   },
    { color = "orange", icon = "hl_orange", text = "Orange" },
    { color = "green",  icon = "hl_green",  text = "Green"  },
    { color = "purple", icon = "hl_purple", text = "Purple" },
}

-- Pink isn't a built-in KOReader colour, so we add it. Change the shade here.
local PINK_HEX = "#FF66B2"

-- Highlight style used by the colour buttons: "lighten" (marker) or "underscore" (underline)
local HIGHLIGHT_STYLE = "lighten"

-- Row 2: shortcut icons (left to right). Reorder or delete lines as you like.
-- Possible actions: "add_note", "dictionary", "translate", "search", "undo",
--                   "wikipedia", "copy", "select", "edit"
--   undo  = on a new selection: cancel it / on an existing highlight: delete it
--   edit  = KOReader's original highlight dialog (style, extend, etc.)
local ACTION_BUTTONS = {
    { action = "add_note",   icon = "hl_note",       text = "Note"    },
    { action = "dictionary", icon = "hl_dictionary", text = "Dict."   },
    { action = "translate",  icon = "hl_translate",  text = "Transl." },
    { action = "search",     icon = "hl_search",     text = "Search"  },
    { action = "undo",       icon = "hl_undo",       text = "Undo"    },
}

-- Tapping a highlight that has a note:
--   false = show this menu (use the Note button to read/edit the note)
--   true  = show the note first, like KOReader normally does
local SHOW_NOTE_FIRST = false

-- Icon sizes (scaled for your screen's dpi)
local COLOR_ICON_SIZE  = Screen:scaleBySize(34)
local ACTION_ICON_SIZE = Screen:scaleBySize(34)

--=====================================================================
--  Add "pink" as a highlight colour
--=====================================================================

if type(Blitbuffer.HIGHLIGHT_COLORS) == "table" and not Blitbuffer.HIGHLIGHT_COLORS["pink"] then
    Blitbuffer.HIGHLIGHT_COLORS["pink"] = PINK_HEX
end

local function addPinkToColorList(list)
    if type(list) ~= "table" then return end
    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry[2] == "pink" then return end
    end
    table.insert(list, { _("Pink"), "pink" })
end
-- so pink also shows in KOReader's own colour picker
addPinkToColorList(ReaderHighlight.highlight_colors)

--=====================================================================
--  Helpers
--=====================================================================

local ICON_DIR = DataStorage:getDataDir() .. "/icons/"
local ICON_EXTS = { ".svg", ".png", ".alpha.png" }

local function iconExists(name)
    if not name or name == "" then return false end
    for _, ext in ipairs(ICON_EXTS) do
        if lfs.attributes(ICON_DIR .. name .. ext, "mode") == "file" then
            return true
        end
    end
    return false
end

-- Puts either the icon or the text label on a button
local function decorate(button, icon, text, size)
    if iconExists(icon) then
        button.icon = icon
        button.icon_width = size
        button.icon_height = size
    else
        button.text = text
    end
    return button
end

local function getItem(this, index)
    return index and this.ui.annotation and this.ui.annotation.annotations[index]
end

--=====================================================================
--  Button definitions
--  index == nil  -> new selection
--  index ~= nil  -> existing highlight that was tapped
--=====================================================================

local ACTIONS = {
    add_note = function(this, index)
        return {
            enabled = index ~= nil or this.hold_pos ~= nil,
            callback = function()
                if index then
                    this:onClose()
                    this:editNote(index)
                else
                    this:addNote()
                    this:onClose()
                end
            end,
        }
    end,
    dictionary = function(this, index)
        return {
            callback = function()
                this:lookupDict(index)
            end,
        }
    end,
    translate = function(this, index)
        return {
            callback = function()
                this:translate(index)
            end,
        }
    end,
    search = function(this, index)
        return {
            callback = function()
                this:onHighlightSearch()
            end,
        }
    end,
    undo = function(this, index)
        return {
            callback = function()
                if index then
                    this:onClose()
                    this:deleteHighlight(index)
                else
                    this:onClose()
                    this:clear()
                end
            end,
        }
    end,
    wikipedia = function(this, index)
        return {
            callback = function()
                UIManager:scheduleIn(0.1, function()
                    this:lookupWikipedia()
                end)
            end,
        }
    end,
    copy = function(this, index)
        local Device = require("device")
        local Notification = require("ui/widget/notification")
        return {
            enabled = Device:hasClipboard(),
            callback = function()
                Device.input.setClipboardText(util.cleanupSelectedText(this.selected_text.text))
                this:onClose()
                UIManager:show(Notification:new{ text = _("Selection copied to clipboard.") })
            end,
        }
    end,
    select = function(this, index)
        return {
            enabled = index == nil and this.hold_pos ~= nil,
            callback = function()
                this:startSelection()
                this:onClose()
            end,
        }
    end,
    edit = function(this, index)
        return {
            enabled = index ~= nil,
            callback = function()
                this:onClose()
                this:_origShowHighlightDialog(index)
            end,
        }
    end,
}

-- Changes the colour of an existing highlight
local function recolor(this, index, color)
    local item = getItem(this, index)
    if not item then return end
    item.color = color
    if item.drawer == "invert" then
        item.drawer = HIGHLIGHT_STYLE
    end
    if this.ui.paging then
        this:writePdfAnnotation("change", item)
    end
    this.ui:handleEvent(Event:new("AnnotationsModified", { item }))
    UIManager:setDirty(this.dialog, "ui")
end

local function buildRows(this, index)
    local item = getItem(this, index)

    -- Row 1: colours
    local color_row = {}
    for _, c in ipairs(COLOR_BUTTONS) do
        local icon = c.icon
        local text = c.text
        if item and item.color == c.color then
            if iconExists(c.icon .. "_on") then icon = c.icon .. "_on" end
            text = "• " .. c.text .. " •"
        end
        table.insert(color_row, decorate({
            enabled = item ~= nil or this.hold_pos ~= nil,
            callback = function()
                if item then
                    recolor(this, index, c.color)
                else
                    this:saveHighlightFormatted(true, HIGHLIGHT_STYLE, c.color)
                end
                this.view.highlight.saved_color = c.color
                this:onClose()
            end,
        }, icon, text, COLOR_ICON_SIZE))
    end

    -- Row 2: shortcuts
    local action_row = {}
    for _, a in ipairs(ACTION_BUTTONS) do
        local make = ACTIONS[a.action]
        if make then
            table.insert(action_row, decorate(make(this, index), a.icon, a.text, ACTION_ICON_SIZE))
        else
            logger.warn("highlight-menu patch: unknown action", a.action)
        end
    end

    local rows = {}
    if #color_row > 0 then table.insert(rows, color_row) end
    if #action_row > 0 then table.insert(rows, action_row) end
    return rows
end

--=====================================================================
--  Our 2-row menu (used for new selections AND existing highlights)
--=====================================================================

function ReaderHighlight:onShowHighlightMenu(index)
    if not self.selected_text then
        return
    end

    self.highlight_dialog = ButtonDialog:new{
        buttons = buildRows(self, index),
        anchor = self._getDialogAnchor and function()
            return self:_getDialogAnchor(self.highlight_dialog, index)
        end or nil,
        tap_close_callback = function()
            if self.hold_pos or index then
                self:clear()
            end
        end,
    }
    UIManager:show(self.highlight_dialog, "[ui]")
    return true
end

--=====================================================================
--  Tapping an existing highlight -> show our menu instead of
--  KOReader's "Delete / Style / Color / Note / …" dialog
--=====================================================================

ReaderHighlight._origShowHighlightDialog = ReaderHighlight.onShowHighlightDialog

function ReaderHighlight:onShowHighlightDialog(index)
    local item = getItem(self, index)
    if not item then
        return self:_origShowHighlightDialog(index)
    end
    self.selected_text = util.tableDeepCopy(item)
    return self:onShowHighlightMenu(index)
end

if not SHOW_NOTE_FIRST and ReaderHighlight.showHighlightNoteOrDialog then
    function ReaderHighlight:showHighlightNoteOrDialog(index)
        return self:onShowHighlightDialog(index)
    end
end

--=====================================================================
--  Custom highlight saving (kept from your original patch)
--  - lets the colour buttons choose colour + style
--  - saves the full chapter path ("Part 1 ▸ Chapter 1")
--=====================================================================
function ReaderHighlight:saveHighlightFormatted(extend_to_sentence, hlStyle, hlColor)
    logger.dbg("save highlight")
    if self.hold_pos and not self.selected_text then
        self:highlightFromHoldPos()
    end
    if self.selected_text and self.selected_text.pos0 and self.selected_text.pos1 then
        local pg_or_xp
        if self.ui.rolling then
            if extend_to_sentence then
                local extended_text = self.ui.document:extendXPointersToSentenceSegment(self.selected_text.pos0, self.selected_text.pos1)
                if extended_text then
                    self.selected_text = extended_text
                end
            end
            pg_or_xp = self.selected_text.pos0
        else
            pg_or_xp = self.selected_text.pos0.page
        end
        local item = {
            page = self.ui.paging and self.selected_text.pos0.page or self.selected_text.pos0,
            pos0 = self.selected_text.pos0,
            pos1 = self.selected_text.pos1,
            text = util.cleanupSelectedText(self.selected_text.text),
            drawer = hlStyle,
            color = hlColor,
            chapter = table.concat(self.ui.toc:getFullTocTitleByPage(pg_or_xp), " ▸ "),
            --chapter = self.ui.toc:getTocTitleByPage(pg_or_xp), -- uncomment for the short chapter name
        }
        if self.ui.paging then
            item.pboxes = self.selected_text.pboxes
            item.ext = self.selected_text.ext
            self:writePdfAnnotation("save", item)
        end
        local index = self.ui.annotation:addItem(item)
        self.view.footer:maybeUpdateFooter()
        self.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index }))
        return index
    end
end
