--[[
2-collections-mosaic.lua  (KOReader user patch)

Shows the Collections list as a mosaic: each collection is drawn as a collage
the size of a normal book cover, made of the covers of its first 4 books
(2x2, edge to edge), with the collection name + book count on a label.

* Follows your library (File browser) display mode from the Cover browser plugin:
  - any "Mosaic ..." mode  -> collections are shown as cover grids
  - "Mosaic with text covers" -> grids with book titles instead of covers
  - list / classic modes   -> the stock collections list is kept
* Uses the same grid size (columns x rows, portrait / landscape) as your library.
* "First 4 books" respects each collection's own sort order (manual, title, ...).
* The "select collections" dialog (adding a book to collections) keeps the stock
  list with checkmarks.
* Exit guard: when you exit KOReader, any window still left open (collections
  list, a collection...) is closed so KOReader can actually quit. Each window
  closed this way is logged in crash.log ("closing window left open on exit").
  "Exit" / "Restart" from quick settings buttons or gestures also work while a
  collection (or another full-screen list) is open.

Install: copy this file to  koreader/patches/  and restart KOReader.
]]

-- Set to "collections" to follow Cover browser's "Collections display mode"
-- setting instead of the library (File browser) display mode.
local FOLLOW = "filemanager"

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local ReadCollection = require("readcollection")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Screen = Device.screen

-- Cover browser modules: only available once plugins are loaded (and if the
-- plugin is enabled), so they are required lazily.
local BookInfoManager, CoverMenu
local function loadCoverBrowser()
    if BookInfoManager and CoverMenu then return true end
    local ok_bim, bim = pcall(require, "bookinfomanager")
    local ok_cm, cm = pcall(require, "covermenu")
    if ok_bim and ok_cm then
        BookInfoManager, CoverMenu = bim, cm
        return true
    end
    logger.dbg("collections-mosaic patch: Cover browser plugin not available")
    return false
end

local BookList = require("ui/widget/booklist")

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function getDisplayMode()
    if FOLLOW == "collections" then
        return BookInfoManager:getSetting("collection_display_mode")
    end
    return BookInfoManager:getSetting("filemanager_display_mode")
end

local function isMosaicWanted()
    if not loadCoverBrowser() then return false end
    local mode = getDisplayMode()
    return type(mode) == "string" and mode:match("^mosaic") ~= nil, mode
end

-- First n books of a collection, in the collection's own sort order
local function getFirstBooks(coll_name, ui, n)
    local coll = ReadCollection.coll[coll_name]
    local books = {}
    if not coll then return books end
    local items = {}
    for _, item in pairs(coll) do
        if item.file and lfs.attributes(item.file, "mode") == "file" then
            table.insert(items, {
                file  = item.file,
                text  = item.text,
                order = item.order or 0,
                attr  = item.attr or lfs.attributes(item.file) or {},
            })
        end
    end
    if #items > 1 then
        local coll_settings = ReadCollection.coll_settings[coll_name] or {}
        local by_order = function(a, b) return a.order < b.order end
        local sorting_func = by_order
        local collate = coll_settings.collate and BookList.collates[coll_settings.collate]
        if collate then
            local ok = pcall(function()
                if collate.item_func then
                    for _, it in ipairs(items) do collate.item_func(it, ui) end
                end
                local f = collate.init_sort_func()
                if coll_settings.collate_reverse then
                    sorting_func = function(a, b) return f(b, a) end
                else
                    sorting_func = f
                end
            end)
            if not ok then sorting_func = by_order end
        end
        if not pcall(table.sort, items, sorting_func) then
            table.sort(items, by_order)
        end
    end
    for i = 1, math.min(n, #items) do
        books[i] = items[i].file
    end
    return books
end

----------------------------------------------------------------------------
-- GridWidget: a book-cover-sized collage of 4 covers (2x2, no gaps) + label
----------------------------------------------------------------------------

local GridWidget = Widget:extend{
    width = 0,        -- whole collage, border included
    height = 0,
    border = Size.border.thin,
    tiles = nil,      -- 4 entries: { x, y, w, h, image = ImageWidget | text = TextBoxWidget | empty = true }
    label = nil,
    label_margin = 0,
}

function GridWidget:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function GridWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local b = self.border
    for _, tile in ipairs(self.tiles) do
        local tx, ty = x + b + tile.x, y + b + tile.y
        if tile.image then
            tile.image:paintTo(bb, tx, ty)
        elseif tile.text then
            -- book without cover (or text covers mode): title on a white tile
            bb:paintRect(tx, ty, tile.w, tile.h, Blitbuffer.COLOR_WHITE)
            local tsize = tile.text:getSize()
            tile.text:paintTo(bb, tx + math.floor((tile.w - tsize.w) / 2),
                ty + math.floor((tile.h - tsize.h) / 2))
        else -- empty slot (collection has fewer than 4 books)
            bb:paintRect(tx, ty, tile.w, tile.h, Blitbuffer.COLOR_GRAY_E)
        end
    end
    -- thin separators, only needed next to tiles that are not covers
    for _, tile in ipairs(self.tiles) do
        if not tile.image then
            bb:paintBorder(x + b + tile.x, y + b + tile.y, tile.w, tile.h, b, Blitbuffer.COLOR_LIGHT_GRAY)
        end
    end
    -- outer border, same as a normal book cover in the mosaic
    bb:paintBorder(x, y, self.width, self.height, b, Blitbuffer.COLOR_BLACK)
    if self.label then
        local lsize = self.label:getSize()
        local lx = x + math.floor((self.width - lsize.w) / 2)
        local ly = y + self.height - b - self.label_margin - lsize.h
        self.label:paintTo(bb, lx, ly)
    end
end

function GridWidget:free()
    for _, tile in ipairs(self.tiles or {}) do
        if tile.image then tile.image:free() end
        if tile.text then tile.text:free(true) end
    end
    if self.label and self.label.free then self.label:free() end
end

----------------------------------------------------------------------------
-- CollectionGridItem: one cell of the grid (based on MosaicMenuItem)
----------------------------------------------------------------------------

local CollectionGridItem = InputContainer:extend{
    entry = nil,
    text = nil,
    mandatory = nil,
    width = nil,
    height = nil,
    menu = nil,
    do_cover_image = true,
    init_done = false,
    bookinfo_found = false,
    font_size = 18,
}

function CollectionGridItem:init()
    self.books = self.entry._books or {}
    self.found_files = {}
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local underline_h = Size.line.focus_indicator
    local underline_padding = Size.padding.tiny
    self._underline_container = UnderlineContainer:new{
        vertical_align = "top",
        padding = underline_padding,
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.width,
            h = self.height + underline_h + underline_padding,
        },
        linesize = underline_h,
    }
    self[1] = self._underline_container
    -- Cover size requested for background extraction: same as a book cell in
    -- the library mosaic, so thumbnails are shared and not re-extracted.
    local border = Size.border.thin
    self.cover_specs = {
        max_cover_w = self.width - 2 * border,
        max_cover_h = self.height - 2 * border,
    }
    self:update()
    self.init_done = true
end

function CollectionGridItem:buildLabel(max_w, max_h)
    local pad = Size.padding.small
    local inner_w = max_w - 2 * (pad + Size.border.thin)
    local count = TextWidget:new{
        text = self.mandatory and tostring(self.mandatory) or "",
        face = Font:getFace("infont", math.max(10, self.font_size - 4)),
        max_width = inner_w,
    }
    local name_max_h = max_h - count:getSize().h - 2 * (pad + Size.border.thin)
    local name = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("cfont", self.font_size),
        width = inner_w,
        alignment = "center",
        bold = true,
    }
    if name:getSize().h > name_max_h and name_max_h > 0 then
        name:free(true)
        name = TextBoxWidget:new{
            text = self.text,
            face = Font:getFace("cfont", self.font_size),
            width = inner_w,
            alignment = "center",
            bold = true,
            height = name_max_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        padding = pad,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            name,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = count:getSize().h },
                count,
            },
        },
    }
end

function CollectionGridItem:update()
    -- Look up the covers we need
    local infos = {}
    local nb_found = 0
    local all_found = true
    for i, file in ipairs(self.books) do
        local bookinfo = BookInfoManager:getBookInfo(file, self.do_cover_image)
        if self.do_cover_image and bookinfo and not bookinfo.ignore_cover then
            if not bookinfo.cover_fetched then
                bookinfo = nil
            elseif bookinfo.has_cover and BookInfoManager.isCachedCoverInvalid(bookinfo, self.cover_specs) then
                if bookinfo.cover_bb then bookinfo.cover_bb:free() end
                bookinfo = nil
            end
        end
        if bookinfo or not self.do_cover_image then
            nb_found = nb_found + 1
            self.found_files[file] = true
        else
            all_found = false
        end
        infos[i] = bookinfo or false
    end
    self.bookinfo_found = all_found

    if self.init_done and nb_found == self._nb_found then
        -- nothing new to show
        for _, bi in ipairs(infos) do
            if bi and bi.cover_bb then bi.cover_bb:free() end
        end
        return
    end
    self._nb_found = nb_found

    -- Geometry: a collage the size of a normal book cover (2:3), split in 4
    local border = Size.border.thin
    local max_w = self.width - 2 * border
    local max_h = self.height - 2 * border
    local inner_w = max_w
    local inner_h = math.floor(inner_w * 3 / 2)
    if inner_h > max_h then
        inner_h = max_h
        inner_w = math.floor(inner_h * 2 / 3)
    end
    local left_w = math.floor(inner_w / 2)
    local top_h = math.floor(inner_h / 2)
    local title_face = Font:getFace("cfont", math.max(9, self.font_size - 7))
    local text_pad = Size.padding.small

    local tiles = {}
    for i = 1, 4 do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local tile = {
            x = col == 0 and 0 or left_w,
            y = row == 0 and 0 or top_h,
            w = col == 0 and left_w or inner_w - left_w,
            h = row == 0 and top_h or inner_h - top_h,
        }
        local file = self.books[i]
        local bookinfo = infos[i]
        if not file then
            tile.empty = true
        elseif bookinfo and self.do_cover_image and bookinfo.has_cover
                and not bookinfo.ignore_cover and bookinfo.cover_bb then
            -- scale to fill the tile, then crop the overflow (centered)
            local scale_factor = math.max(tile.w / bookinfo.cover_w, tile.h / bookinfo.cover_h) + 0.002
            tile.image = ImageWidget:new{
                image = bookinfo.cover_bb,
                scale_factor = scale_factor,
                width = tile.w,
                height = tile.h,
            }
            tile.image:_render()
            self.menu._has_cover_images = true
            self._has_cover_image = true
        else
            if bookinfo and bookinfo.cover_bb then bookinfo.cover_bb:free() end
            local title = bookinfo and not bookinfo.ignore_meta and bookinfo.title
            if not title then
                title = file:match("([^/]+)$") or file
                title = title:gsub("%.[^.]+$", "")
            end
            if not bookinfo and self.do_cover_image then
                title = "…" -- still being extracted
            end
            tile.text = TextBoxWidget:new{
                text = title,
                face = title_face,
                width = tile.w - 2 * text_pad,
                height = tile.h - 2 * text_pad,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                alignment = "center",
            }
        end
        tiles[i] = tile
    end

    local label_margin = math.max(Screen:scaleBySize(3), math.floor(inner_w / 40))
    local label = self:buildLabel(inner_w - 2 * label_margin, math.floor(inner_h * 0.35))

    local grid = GridWidget:new{
        width = inner_w + 2 * border,
        height = inner_h + 2 * border,
        border = border,
        tiles = tiles,
        label = label,
        label_margin = label_margin,
    }

    if self._underline_container[1] then
        self._underline_container[1]:free()
    end
    self._underline_container[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        grid,
    }
end

function CollectionGridItem:getFocusIndicatorRegion()
    return self._underline_container and self._underline_container:getFocusIndicatorRegion()
end

function CollectionGridItem:repaintFocusIndicator(bb)
    return self._underline_container and self._underline_container:repaintFocusIndicator(bb)
end

function CollectionGridItem:onFocus()
    self._underline_container.color = Blitbuffer.COLOR_BLACK
    return true
end

function CollectionGridItem:onUnfocus()
    self._underline_container.color = Blitbuffer.COLOR_WHITE
    return true
end

function CollectionGridItem:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function CollectionGridItem:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

----------------------------------------------------------------------------
-- Menu methods for the collections list
----------------------------------------------------------------------------

local CollMosaic = {}

function CollMosaic:_recalculateDimen()
    self.portrait_mode = Screen:getWidth() <= Screen:getHeight()
    if self.portrait_mode then
        self.nb_cols = BookInfoManager:getSetting("nb_cols_portrait") or 3
        self.nb_rows = BookInfoManager:getSetting("nb_rows_portrait") or 3
    else
        self.nb_cols = BookInfoManager:getSetting("nb_cols_landscape") or 4
        self.nb_rows = BookInfoManager:getSetting("nb_rows_landscape") or 2
    end
    self.perpage = self.nb_rows * self.nb_cols
    self.page_num = math.ceil(#self.item_table / self.perpage)
    if self.page_num > 0 and self.page > self.page_num then self.page = self.page_num end

    self.others_height = 0
    if self.title_bar then
        if not self.is_borderless then
            self.others_height = self.others_height + 2
        end
        if not self.no_title then
            self.others_height = self.others_height + self.title_bar.dimen.h
        end
        if self.page_info then
            self.others_height = self.others_height + self.page_info:getSize().h
        end
    end

    self.item_margin = Screen:scaleBySize(10)
    self.item_height = math.floor((self.inner_dimen.h - self.others_height - (1 + self.nb_rows) * self.item_margin) / self.nb_rows)
    self.item_width = math.floor((self.inner_dimen.w - (1 + self.nb_cols) * self.item_margin) / self.nb_cols)
    self.item_dimen = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
end

function CollMosaic:_updateItemsBuildUI()
    local cur_row
    local idx_offset = (self.page - 1) * self.perpage
    local line_layout = {}
    local select_number
    local font_size = self.nb_cols <= 2 and 20 or self.nb_cols == 3 and 18 or self.nb_cols == 4 and 15 or 13
    self._books_cache = self._books_cache or {}
    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        if index == self.itemnumber then
            select_number = idx
        end
        if entry.name and self._books_cache[entry.name] == nil then
            self._books_cache[entry.name] = getFirstBooks(entry.name, self._manager and self._manager.ui, 4)
        end
        entry._books = entry.name and self._books_cache[entry.name] or {}

        if idx % self.nb_cols == 1 or self.nb_cols == 1 then
            if idx > 1 then
                table.insert(self.layout, line_layout)
            end
            line_layout = {}
            table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
            cur_row = HorizontalGroup:new{}
            table.insert(self.item_group, LeftContainer:new{
                dimen = Geom:new{ w = self.inner_dimen.w, h = self.item_height },
                cur_row,
            })
            table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        end

        local item = CollectionGridItem:new{
            entry = entry,
            text = entry.text,
            mandatory = entry.mandatory,
            width = self.item_width,
            height = self.item_height,
            show_parent = self.show_parent,
            menu = self,
            do_cover_image = self._do_cover_images,
            font_size = font_size,
        }
        table.insert(cur_row, item)
        table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        table.insert(line_layout, item)

        if not item.bookinfo_found then
            -- CoverMenu extracts one file per entry of items_to_update:
            -- register a small proxy for each cover still missing.
            for _, file in ipairs(item.books) do
                if not item.found_files[file] then
                    table.insert(self.items_to_update, {
                        filepath = file,
                        cover_specs = item.cover_specs,
                        text = item.text,
                        item,
                        update = function(proxy)
                            item:update()
                            proxy.bookinfo_found = item.found_files[file] or false
                            proxy._has_cover_image = item._has_cover_image
                        end,
                    })
                end
            end
        end
    end
    table.insert(self.layout, line_layout)
    table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
    return select_number
end

local function enableMosaic(menu, mode)
    menu._collmosaic = true
    menu.updateItems = CoverMenu.updateItems
    -- Never let an error while closing keep the list on screen (a window left
    -- in UIManager's stack prevents KOReader from quitting).
    menu.onCloseWidget = function(this, ...)
        local ok, err = pcall(CoverMenu.onCloseWidget, this, ...)
        if not ok then
            logger.warn("collections-mosaic: error while closing the collections list:", err)
            pcall(Menu.onCloseWidget, this)
        end
    end
    menu._recalculateDimen = CollMosaic._recalculateDimen
    menu._updateItemsBuildUI = CollMosaic._updateItemsBuildUI
    menu._do_cover_images = mode ~= "mosaic_text"
    menu.items_max_lines = nil
    menu._books_cache = {}
    menu:_recalculateDimen() -- so that perpage is right before the first switchItemTable()
end

----------------------------------------------------------------------------
-- Hook
----------------------------------------------------------------------------

local orig_updateCollListItemTable = FileManagerCollection.updateCollListItemTable

function FileManagerCollection:updateCollListItemTable(do_init, item_number)
    local menu = self.coll_list
    if menu and not menu._collmosaic_checked then
        menu._collmosaic_checked = true
        local wanted, mode = isMosaicWanted()
        if wanted and not self.selected_collections then
            enableMosaic(menu, mode)
        end
    end
    if menu and menu._collmosaic and do_init then
        menu._books_cache = {} -- collections may have changed
    end
    return orig_updateCollListItemTable(self, do_init, item_number)
end

-- refreshCollList() is called after changing a collection's settings
-- (filters, connected folders...): its first books may have changed.
local orig_refreshCollList = FileManagerCollection.refreshCollList
function FileManagerCollection:refreshCollList(item)
    if self.coll_list and self.coll_list._books_cache and item and item.name then
        self.coll_list._books_cache[item.name] = nil
    end
    return orig_refreshCollList(self, item)
end

----------------------------------------------------------------------------
-- Exit guard
--
-- KOReader only quits once no window is left open. If the File manager is
-- closed to exit (from any menu, gesture or SimpleUI power button) while
-- the collections list, a collection or another full-screen window is still
-- open on top of it, that window stays behind and KOReader never quits
-- (the screen looks frozen until a hard reboot). So on a real exit, close
-- whatever is left. Opening a book is not affected (tearing_down is set then).
----------------------------------------------------------------------------

local FileManager = require("apps/filemanager/filemanager")

local orig_fm_onClose = FileManager.onClose
function FileManager:onClose(...)
    local exiting = not self.tearing_down
    local ret = orig_fm_onClose(self, ...)
    if exiting then
        UIManager:nextTick(function()
            if FileManager.instance then return end -- a new File manager was opened
            local ReaderUI = package.loaded["apps/reader/readerui"]
            if ReaderUI and ReaderUI.instance then return end -- a book is opening
            local leftovers = {}
            for _, entry in ipairs(UIManager._window_stack or {}) do
                if entry.widget then table.insert(leftovers, entry.widget) end
            end
            for i = #leftovers, 1, -1 do
                local w = leftovers[i]
                logger.warn("collections-mosaic: closing window left open on exit:",
                    w.name or w.id or tostring(w))
                local ok, err = pcall(UIManager.close, UIManager, w)
                if not ok then
                    logger.warn("collections-mosaic: could not close it cleanly:", err)
                    for j = #UIManager._window_stack, 1, -1 do
                        if UIManager._window_stack[j].widget == w then
                            table.remove(UIManager._window_stack, j)
                        end
                    end
                end
            end
        end)
    end
    return ret
end

-- Exit / Restart sent to the window on top (quick settings buttons, gestures
-- and other Dispatcher actions use UIManager:sendEvent) only reach that
-- window. When the collections list, a collection or another full-screen
-- list is on top of the File manager, nobody handles them and nothing
-- happens. Forward them to the File manager (or the reader), which exits
-- normally (and then the guard above closes what's left).
local Event = require("ui/event")

local function forwardToApp(event_name)
    return function(widget, ...)
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local app = (ReaderUI and ReaderUI.instance) or FileManager.instance
        if app and app ~= widget then
            logger.info("collections-mosaic: forwarding", event_name, "from",
                widget.name or widget.id or tostring(widget))
            return app:handleEvent(Event:new(event_name, ...))
        end
    end
end

local orig_uimanager_show = UIManager.show
function UIManager:show(widget, ...)
    if type(widget) == "table" and widget.covers_fullscreen
            and widget ~= FileManager.instance and widget.name ~= "ReaderUI" then
        if widget.onExit == nil then widget.onExit = forwardToApp("Exit") end
        if widget.onRestart == nil then widget.onRestart = forwardToApp("Restart") end
    end
    return orig_uimanager_show(self, widget, ...)
end
