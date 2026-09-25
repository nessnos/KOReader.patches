--[[
2-collection-shuffle.lua  —  KOReader user patch (goes in koreader/patches/)

Adds a "Shuffle" sort method to a collection's "Sort by" dialog
(open a collection → menu icon top-left → "Sort by…" / Arrange).

When a collection is set to Shuffle, its books get a new random order:
  * every time the SimpleUI home page (or a SimpleUI custom screen) opens,
    so a Featured Collection module shows different covers each time;
  * every time you open the collection itself in KOReader;
  * when you tap "Shuffle" again in the Sort dialog (= reshuffle now).

How it works: a shuffled collection is stored as a normal *manual* collection
(collate = nil) with an extra flag `shuffle = true` in its settings, and the
patch rewrites the in-memory `order` of its books. SimpleUI's Featured
Collection sorts by that `order`, so it picks up the new order automatically.
If you ever remove this patch, the collection simply stays in manual order
(the last shuffle) — nothing breaks.

Choosing any other sort method (or Manual sorting) turns Shuffle off.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local ReadCollection = require("readcollection")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

pcall(require, "random") -- seeds math.random with the current time

local SHUFFLE_ID = "__shuffle__"

-- ---------------------------------------------------------------------------
-- Core: give every book of a collection a fresh random order (1..n)
-- ---------------------------------------------------------------------------
local function isShuffled(coll_name)
    local cs = ReadCollection.coll_settings and ReadCollection.coll_settings[coll_name]
    return cs and cs.shuffle and not cs.collate or false
end

local function shuffleCollection(coll_name)
    local coll = ReadCollection.coll and ReadCollection.coll[coll_name]
    if not coll then return end
    local items = {}
    for _, item in pairs(coll) do
        items[#items + 1] = item
    end
    for i = #items, 2, -1 do -- Fisher–Yates
        local j = math.random(i)
        items[i], items[j] = items[j], items[i]
    end
    for i, item in ipairs(items) do
        item.order = i
    end
end

local function shuffleAllFlagged()
    if not (ReadCollection.coll and ReadCollection.coll_settings) then return end
    for coll_name in pairs(ReadCollection.coll) do
        if isShuffled(coll_name) then
            shuffleCollection(coll_name)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 1. setCollate: handle our pseudo-collate, reshuffle when a collection opens
-- ---------------------------------------------------------------------------
local orig_setCollate = FileManagerCollection.setCollate
function FileManagerCollection:setCollate(collate_id, collate_reverse)
    local coll_name = self.booklist_menu and self.booklist_menu.path
    local cs = coll_name and ReadCollection.coll_settings[coll_name]
    if cs then
        if collate_id == SHUFFLE_ID then
            -- "Shuffle" picked in the Sort dialog
            cs.shuffle = true
            collate_id, collate_reverse = false, false -- store as manual collection
            shuffleCollection(coll_name)
        elseif collate_id ~= nil then
            -- any other sort method (or Manual sorting) picked → Shuffle off
            cs.shuffle = nil
        elseif isShuffled(coll_name) then
            -- plain setCollate() = collection being opened → new order
            shuffleCollection(coll_name)
        end
    end
    return orig_setCollate(self, collate_id, collate_reverse)
end

-- ---------------------------------------------------------------------------
-- 2. Sort dialog: add a "Shuffle" button
-- ---------------------------------------------------------------------------
local orig_showArrange = FileManagerCollection.showArrangeBooksDialog
function FileManagerCollection:showArrangeBooksDialog()
    local fmc = self
    local coll_name = self.booklist_menu and self.booklist_menu.path
    local shuffled = coll_name and isShuffled(coll_name)

    local had_own_new = rawget(ButtonDialog, "new")
    local orig_new = ButtonDialog.new
    local dialog

    ButtonDialog.new = function(cls, o)
        local ok, err = pcall(function()
            local buttons = o and o.buttons
            if type(buttons) ~= "table" then return end
            -- When Shuffle is active, KOReader thinks the collection is manual:
            -- move the checkmark from "Manual sorting" to "Shuffle".
            if shuffled then
                local manual = _("Manual sorting")
                for _i, row in ipairs(buttons) do
                    for _j, btn in ipairs(row) do
                        if type(btn.text) == "string" and btn.text:find(manual, 1, true) == 1 then
                            btn.text = manual
                        end
                    end
                end
            end
            local shuffle_row = {{
                text = _("Shuffle") .. (shuffled and "  ✓" or ""),
                callback = function()
                    if dialog then UIManager:close(dialog) end
                    fmc.updated_collections[coll_name] = true
                    fmc:setCollate(SHUFFLE_ID)
                    fmc:updateItemTable()
                    pcall(ReadCollection.write, ReadCollection, { [coll_name] = true })
                end,
            }}
            -- Insert right before the separator ({}) that precedes "Manual sorting".
            local pos = #buttons + 1
            for i, row in ipairs(buttons) do
                if type(row) == "table" and #row == 0 then pos = i break end
            end
            table.insert(buttons, pos, shuffle_row)
        end)
        if not ok then logger.warn("collection-shuffle: could not add button:", err) end
        dialog = orig_new(cls, o)
        return dialog
    end

    local ok, res = pcall(orig_showArrange, self)
    -- restore ButtonDialog.new no matter what
    if had_own_new then ButtonDialog.new = had_own_new else ButtonDialog.new = nil end
    if not ok then error(res) end
    return res
end

-- ---------------------------------------------------------------------------
-- 3. SimpleUI home page: reshuffle every time it is shown
--    (the home screen widget is named "homescreen"; a fresh one is created
--    each time you go Home, so its modules read the new order)
-- ---------------------------------------------------------------------------
local orig_show = UIManager.show
UIManager.show = function(um, widget, ...)
    if type(widget) == "table" and widget.name == "homescreen" then
        local ok, err = pcall(shuffleAllFlagged)
        if not ok then logger.warn("collection-shuffle: shuffle failed:", err) end
    end
    return orig_show(um, widget, ...)
end

logger.info("collection-shuffle: patch loaded")
