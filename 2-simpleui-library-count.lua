--[[
2-simpleui-library-count.lua — KOReader user patch
=====================================================
Adds a "Library Count" module to the SimpleUI home screen (and Custom Screens).

    1245                       1245  │  412  │  833
    books                      books │  read │  unread
    412 read · 833 unread

  • Always shows the total number of books in your library (home folder,
    scanned recursively by SimpleUI).
  • Optional: Read (finished) and Unread (not started + On hold) counts.
  • Optional: In progress (books you've started but not finished).
  • Two minimalist styles: Stacked or Row. Alignment, Scale, section label.
  • Tap the module to recount. Long-press opens its settings (SimpleUI default).

Install: copy this file into  koreader/patches/  and restart KOReader.
Then: SimpleUI home screen → long-press / Settings → Arrange / Add module →
enable "Library Count".

Requires the SimpleUI plugin (simpleui.koplugin, v2.5+ folder layout).
--]]

local userpatch = require("userpatch")
local logger    = require("logger")

local MOD_ID = "library_count"
local _M          -- module descriptor (built lazily, once SimpleUI is on package.path)
local _registered_in = nil  -- the Registry table we registered into
local _wrapped_sp    = false

-- ---------------------------------------------------------------------------
-- Module factory
-- ---------------------------------------------------------------------------
local function buildModule()
    local Device          = require("device")
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local LineWidget      = require("ui/widget/linewidget")
    local TextWidget      = require("ui/widget/textwidget")
    local Screen          = Device.screen
    local Blitbuffer      = require("ffi/blitbuffer")
    local BLACK           = Blitbuffer.COLOR_BLACK

    local UI          = require("infra/sui_core")
    local Config      = require("infra/sui_config")
    local SUISettings = require("infra/sui_store")
    local SUIStyle    = require("features/sui_style")

    local _ = function(s) return s end
    do
        local ok, i18n = pcall(require, "infra/sui_i18n")
        if ok and i18n and i18n.translate then _ = i18n.translate end
    end

    local PAD = UI.PAD

    -- Base sizes at 100 % scale (font sizes are in KOReader "points";
    -- Font:getFace scales them for the screen DPI).
    local BASE_BIG_FS   = 46   -- stacked: total
    local BASE_ROW_FS   = 30   -- row: every value
    local BASE_CAP_FS   = 15   -- small caption under values
    local BASE_SUB_FS   = 17   -- stacked: secondary line
    local BASE_PAD_V    = Screen:scaleBySize(6)
    local BASE_GAP      = Screen:scaleBySize(6)
    local BASE_SEP_H    = Screen:scaleBySize(40)

    -- ── Settings ───────────────────────────────────────────────────────────
    local function key(pfx, k) return (pfx or "simpleui_hs_") .. MOD_ID .. "_" .. k end
    local function getBool(pfx, k, def)
        local v = SUISettings:readSetting(key(pfx, k))
        if v == nil then return def end
        return v == true
    end
    local function setBool(pfx, k, v) SUISettings:saveSetting(key(pfx, k), v) end
    local function getStyle(pfx)
        local v = SUISettings:readSetting(key(pfx, "style"))
        return (v == "row") and "row" or "stacked"
    end
    local function getAlign(pfx)
        local v = SUISettings:readSetting(key(pfx, "align"))
        return (v == "left") and "left" or "center"
    end

    local function secondaryItems(pfx)
        local list = {}
        if getBool(pfx, "show_read",    false) then list[#list + 1] = "read"    end
        if getBool(pfx, "show_unread",  false) then list[#list + 1] = "unread"  end
        if getBool(pfx, "show_reading", false) then list[#list + 1] = "reading" end
        return list
    end

    local LABELS = {
        read    = _("read"),
        unread  = _("unread"),
        reading = _("in progress"),
    }

    -- ── Counting ───────────────────────────────────────────────────────────
    local _last_file_n = nil

    local function getSP()
        local SP = package.loaded["modules/module_stats_provider"]
        if not SP then
            local ok, m = pcall(require, "modules/module_stats_provider")
            if ok then SP = m end
        end
        return SP
    end

    local function getCounts()
        local SP = getSP()
        if not (SP and SP.getStatusCounts) then return nil end
        -- A book added/removed changes the file count: drop the cached
        -- status breakdown so the total stays honest. (Directory-mtime
        -- cached by SimpleUI, so this is cheap.)
        pcall(function()
            local LS = require("engines/sui_library_scan")
            local home = LS.resolveHomeDir()
            if home then
                local n = #LS.getFileList(home)
                if _last_file_n and n ~= _last_file_n and SP.invalidateStatusCounts then
                    SP.invalidateStatusCounts()
                end
                _last_file_n = n
            end
        end)
        local ok, c = pcall(SP.getStatusCounts)
        if not ok or type(c) ~= "table" then return nil end
        local unread    = c.unread    or 0
        local reading   = c.reading   or 0
        local complete  = c.complete  or 0
        local abandoned = c.abandoned or 0   -- KOReader's "On hold"
        return {
            total   = unread + reading + complete + abandoned,
            read    = complete,
            unread  = unread + abandoned,
            reading = reading,
        }
    end

    local function forceRecount()
        local SH = package.loaded["modules/module_books_shared"]
        if SH and SH.invalidateSidecarCache then pcall(SH.invalidateSidecarCache) end
        local okLS, LS = pcall(require, "engines/sui_library_scan")
        if okLS and LS and LS.invalidate then pcall(LS.invalidate) end
        local SP = getSP()
        if SP and SP.invalidateStatusCounts then SP.invalidateStatusCounts() end
        _last_file_n = nil
    end

    -- ── Layout ─────────────────────────────────────────────────────────────
    local _h_cache = {}
    local function lineH(face)
        local k = tostring(face.size) .. (face.orig_font or "")
        local h = _h_cache[k]
        if not h then
            local tw = TextWidget:new{ text = "0Ag", face = face }
            h = tw:getSize().h
            tw:free()
            _h_cache[k] = h
        end
        return h
    end

    local function layout(ctx)
        local pfx   = (ctx and ctx.pfx) or "simpleui_hs_"
        local lf    = (ctx and ctx.landscape_factor) or 1
        local scale = Config.getModuleScale(MOD_ID, pfx) * lf
        local function fs(b) return math.max(8, math.floor(b * scale)) end
        local L = {
            pfx    = pfx,
            style  = getStyle(pfx),
            align  = getAlign(pfx),
            items  = secondaryItems(pfx),
            pad_v  = math.max(2, math.floor(BASE_PAD_V * scale)),
            gap    = math.max(1, math.floor(BASE_GAP * scale)),
            sep_h  = math.max(8, math.floor(BASE_SEP_H * scale)),
            face_big  = Font:getFace(SUIStyle.FACE_REGULAR, fs(BASE_BIG_FS)),
            face_row  = Font:getFace(SUIStyle.FACE_REGULAR, fs(BASE_ROW_FS)),
            face_cap  = Font:getFace(SUIStyle.FACE_REGULAR, fs(BASE_CAP_FS)),
            face_sub  = Font:getFace(SUIStyle.FACE_REGULAR, fs(BASE_SUB_FS)),
        }
        if L.style == "row" then
            L.h = L.pad_v * 2 + lineH(L.face_row) + lineH(L.face_cap)
        else
            L.h = L.pad_v * 2 + lineH(L.face_big) + lineH(L.face_cap)
            if #L.items > 0 then
                L.h = L.h + L.gap + lineH(L.face_sub)
            end
        end
        return L
    end

    local function text(t, face, bold, color, max_w)
        return UI.makeColoredText{
            text    = t,
            face    = face,
            bold    = bold,
            fgcolor = color,
            max_width = max_w,
            truncate_with_ellipsis = max_w and true or nil,
        }
    end

    local function totalCaption(n)
        return (n == 1) and _("book") or _("books")
    end

    -- Stacked: big total, caption, then "412 read · 833 unread".
    local function buildStacked(w, L, c)
        local C = SUIStyle.COLOR
        local inner_w = w - PAD * 2
        local vg = VerticalGroup:new{ align = L.align }
        vg[#vg + 1] = text(tostring(c.total), L.face_big, true, BLACK)
        vg[#vg + 1] = text(totalCaption(c.total), L.face_cap, false, BLACK, inner_w)
        if #L.items > 0 then
            vg[#vg + 1] = VerticalSpan:new{ width = L.gap }
            local hg = HorizontalGroup:new{ align = "center" }
            for i, id in ipairs(L.items) do
                if i > 1 then
                    hg[#hg + 1] = text("  ·  ", L.face_sub, false, BLACK)
                end
                hg[#hg + 1] = text(tostring(c[id] or 0), L.face_sub, true, BLACK)
                hg[#hg + 1] = text(" " .. LABELS[id], L.face_sub, false, BLACK)
            end
            vg[#vg + 1] = hg
        end
        local dimen = Geom:new{ w = w, h = L.h }
        if L.align == "left" then
            return FrameContainer:new{
                dimen = dimen, bordersize = 0, margin = 0,
                padding = 0, padding_left = PAD,
                LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = L.h }, vg },
            }
        end
        return CenterContainer:new{ dimen = dimen, vg }
    end

    -- Row: equal columns with hairline separators.
    local function buildRow(w, L, c)
        local C = SUIStyle.COLOR
        local cols = { { v = c.total, lbl = totalCaption(c.total) } }
        for _i, id in ipairs(L.items) do
            cols[#cols + 1] = { v = c[id] or 0, lbl = LABELS[id] }
        end
        local n      = #cols
        local avail  = w - PAD * 2
        local sep_w  = math.max(1, SUIStyle.BORDER_SZ or 1)
        local cell_w = math.floor((avail - sep_w * (n - 1)) / n)
        local row = HorizontalGroup:new{ align = "center" }
        for i, col in ipairs(cols) do
            if i > 1 then
                row[#row + 1] = LineWidget:new{
                    dimen = Geom:new{ w = sep_w, h = L.sep_h },
                    background = C.gray,
                }
            end
            row[#row + 1] = CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = L.h },
                VerticalGroup:new{ align = "center",
                    text(tostring(col.v), L.face_row, i == 1, BLACK, cell_w),
                    text(col.lbl, L.face_cap, false, BLACK, cell_w),
                },
            }
        end
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = L.h }, row }
    end

    -- ── Descriptor ─────────────────────────────────────────────────────────
    local M = {}
    M.id          = MOD_ID
    M.name        = _("Library Count")
    M.label       = _("Library")
    M.enabled_key = MOD_ID .. "_enabled"
    M.default_on  = false
    -- Makes SimpleUI refresh stats (and our counts) after a book is closed.
    M.needs       = { stats = true }

    Config.applyLabelToggle(M, _("Library"))

    function M.build(w, ctx)
        Config.applyLabelToggle(M, _("Library"))
        local L = layout(ctx)
        local c = getCounts() or { total = 0, read = 0, unread = 0, reading = 0 }
        local body = (L.style == "row") and buildRow(w, L, c) or buildStacked(w, L, c)

        local tappable = InputContainer:new{
            dimen = Geom:new{ w = w, h = L.h },
            [1]   = body,
        }
        tappable.ges_events = {
            TapLibraryCount = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
        }
        function tappable:onTapLibraryCount()
            forceRecount()
            if ctx and type(ctx.refresh_fn) == "function" then ctx.refresh_fn() end
            return true
        end
        return tappable
    end

    function M.getHeight(ctx)
        return layout(ctx).h
    end

    function M.invalidateCache()
        forceRecount()
    end

    local function toggleItem(ctx_menu, k, label)
        local pfx, _lc = ctx_menu.pfx, ctx_menu._ or _
        return {
            text           = _lc(label),
            checked_func   = function() return getBool(pfx, k, false) end,
            keep_menu_open = true,
            callback       = function()
                setBool(pfx, k, not getBool(pfx, k, false))
                ctx_menu.refresh()
            end,
        }
    end

    local function radioItem(ctx_menu, k, value, label, getter)
        local pfx, _lc = ctx_menu.pfx, ctx_menu._ or _
        return {
            text           = _lc(label),
            radio          = true,
            keep_menu_open = true,
            checked_func   = function() return getter(pfx) == value end,
            callback       = function()
                SUISettings:saveSetting(key(pfx, k), value)
                ctx_menu.refresh()
            end,
        }
    end

    function M.getMenuItems(ctx_menu)
        local pfx = ctx_menu.pfx
        local _lc = ctx_menu._ or _
        return {
            toggleItem(ctx_menu, "show_read",    "Show read"),
            toggleItem(ctx_menu, "show_unread",  "Show unread (incl. on hold)"),
            {
                text           = _lc("Show in progress"),
                checked_func   = function() return getBool(pfx, "show_reading", false) end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    setBool(pfx, "show_reading", not getBool(pfx, "show_reading", false))
                    ctx_menu.refresh()
                end,
            },
            {
                text = _lc("Style"),
                sub_item_table = {
                    radioItem(ctx_menu, "style", "stacked", "Stacked", getStyle),
                    radioItem(ctx_menu, "style", "row",     "Row",     getStyle),
                },
            },
            {
                text         = _lc("Alignment"),
                enabled_func = function() return getStyle(pfx) == "stacked" end,
                sub_item_table = {
                    radioItem(ctx_menu, "align", "left",   "Left",   getAlign),
                    radioItem(ctx_menu, "align", "center", "Center", getAlign),
                },
            },
            Config.makeScaleItem{
                text_func    = function() return _lc("Scale") end,
                enabled_func = function() return not Config.isScaleLinked() end,
                title        = _lc("Scale"),
                info         = _lc("Scale for this module.\n100% is the default size."),
                get          = function() return Config.getModuleScalePct(MOD_ID, pfx) end,
                set          = function(v) Config.setModuleScale(v, MOD_ID, pfx) end,
                refresh      = ctx_menu.refresh,
            },
            Config.makeLabelToggleItem(MOD_ID, _("Library"), ctx_menu.refresh, _lc),
            {
                text           = _lc("Recount now"),
                keep_menu_open = true,
                callback       = function()
                    forceRecount()
                    ctx_menu.refresh()
                end,
            },
        }
    end

    return M
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------
-- Opening a book turns it from "unread" into "in progress". SimpleUI only
-- does a partial stats invalidation on close in that case, which keeps the
-- status breakdown cached — also drop it so our counts follow along.
local function wrapStatsProvider()
    if _wrapped_sp then return end
    local SP = package.loaded["modules/module_stats_provider"]
    if not SP then
        local ok, m = pcall(require, "modules/module_stats_provider")
        if ok then SP = m end
    end
    if not (SP and SP.invalidateTimeSeries and SP.invalidateStatusCounts) then return end
    local orig = SP.invalidateTimeSeries
    SP.invalidateTimeSeries = function(...)
        SP.invalidateStatusCounts()
        return orig(...)
    end
    _wrapped_sp = true
end

local function register()
    local Registry = package.loaded["modules/moduleregistry"]
    if not Registry then
        local ok, r = pcall(require, "modules/moduleregistry")
        if ok then Registry = r end
    end
    if type(Registry) ~= "table" or type(Registry.register) ~= "function" then
        logger.warn("library-count patch: SimpleUI module registry not found")
        return
    end
    if _registered_in == Registry then return end

    if not _M then
        local ok, mod = pcall(buildModule)
        if not ok then
            logger.warn("library-count patch: failed to build module:", mod)
            return
        end
        _M = mod
    end

    Registry.register(_M)
    _registered_in = Registry
    pcall(wrapStatsProvider)
    logger.info("library-count patch: registered SimpleUI module '" .. MOD_ID .. "'")

    -- If a SimpleUI screen was already built before we got here, make it
    -- re-resolve its module list so the new module shows up right away.
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        local Engine = package.loaded["engines/sui_screen_engine"]
        if Engine and Engine.invalidateAllCfgAndRefresh then
            pcall(Engine.invalidateAllCfgAndRefresh, false)
        end
    end)
end

userpatch.registerPatchPluginFunc("simpleui", function()
    local ok, err = pcall(register)
    if not ok then logger.warn("library-count patch:", err) end
end)
