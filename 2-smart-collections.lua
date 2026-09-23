--[[
    Smart collections for KOReader
    ==============================

    Install: copy this file into  koreader/patches/  and restart KOReader.

    * Collections > menu (top-left) > "New collection" now asks:
      "Normal collection" or "Smart collection".
    * A smart collection is defined by rules, e.g.
          Tags  contains  "fantasy"
          Status  is not  Finished
      and a match mode: ALL rules (AND) or ANY rule (OR).
    * Books are taken from your Home folder and all its subfolders.
      No connected folder is needed.
    * The collection updates itself every time you open it
      (and when you open the collections list, at most every 5 minutes).
    * Long-press a smart collection in the list to edit rules, update now,
      rename, remove, or convert it to a normal collection.

    Available fields: Tags, Author, Title, Series, Series number, Language,
    Description, Status, Rating, Progress (%), Pages, Has highlights,
    File name, File type, Folder (relative to Home).

    Metadata of books that were never opened (and not already known by the
    Cover browser) is read from the file once, then cached in
    koreader/settings/smart_collections_cache.lua, so the first update of a
    big library can take a moment; later updates are fast.
--]]

local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local ReadCollection = require("readcollection")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local FMC = FileManagerCollection

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local LIST_REFRESH_INTERVAL = 300 -- seconds: min delay between auto-updates when opening the collections list
local COLL_REFRESH_INTERVAL = 10  -- seconds: min delay between auto-updates of the same collection
local CACHE_FILE = DataStorage:getSettingsDir() .. "/smart_collections_cache.lua"
local SMART_MARKER = "\u{F0D0}" -- magic wand, shown in the collections list

-- ---------------------------------------------------------------------------
-- Rule definitions
-- ---------------------------------------------------------------------------

local FIELDS = {
    { id = "keywords",     text = _("Tags"),          kind = "text",   meta = true, list = true },
    { id = "authors",      text = _("Author"),        kind = "text",   meta = true, list = true },
    { id = "title",        text = _("Title"),         kind = "text",   meta = true },
    { id = "series",       text = _("Series"),        kind = "text",   meta = true },
    { id = "series_index", text = _("Series number"), kind = "number", meta = true },
    { id = "language",     text = _("Language"),      kind = "text",   meta = true },
    { id = "description",  text = _("Description"),   kind = "text",   meta = true },
    { id = "status",       text = _("Status"),        kind = "status" },
    { id = "rating",       text = _("Rating"),        kind = "number" },
    { id = "progress",     text = _("Progress (%)"),  kind = "number" },
    { id = "pages",        text = _("Pages"),         kind = "number", meta = true },
    { id = "highlights",   text = _("Has highlights"), kind = "bool" },
    { id = "filename",     text = _("File name"),     kind = "text" },
    { id = "filetype",     text = _("File type"),     kind = "text" },
    { id = "folder",       text = _("Folder"),        kind = "text" },
}
local FIELD_BY_ID = {}
for _i, f in ipairs(FIELDS) do FIELD_BY_ID[f.id] = f end

local OPS = {
    text = {
        { "contains",     _("contains") },
        { "not_contains", _("does not contain") },
        { "equals",       _("equals") },
        { "not_equals",   _("does not equal") },
        { "starts_with",  _("starts with") },
        { "is_empty",     _("is empty") },
        { "not_empty",    _("is not empty") },
    },
    number = {
        { "eq", "=" }, { "ne", "≠" },
        { "gt", ">" }, { "ge", "≥" },
        { "lt", "<" }, { "le", "≤" },
    },
    status = {
        { "is",     _("is") },
        { "is_not", _("is not") },
    },
    bool = {
        { "is_true",  _("yes") },
        { "is_false", _("no") },
    },
}
local NO_VALUE_OPS = { is_empty = true, not_empty = true, is_true = true, is_false = true }
local STATUSES = { "new", "reading", "abandoned", "complete" }

local function opText(kind, op)
    for _i, o in ipairs(OPS[kind] or {}) do
        if o[1] == op then return o[2] end
    end
    return op
end

local function statusText(status)
    return BookList.getBookStatusString(status) or status
end

local function describeRule(rule)
    local field = FIELD_BY_ID[rule.field]
    if not field then return "?" end
    if field.kind == "bool" then
        return field.text .. ": " .. opText("bool", rule.op)
    end
    local s = field.text .. " " .. opText(field.kind, rule.op)
    if NO_VALUE_OPS[rule.op] then return s end
    if field.kind == "status" then
        return s .. " " .. statusText(rule.value)
    elseif field.kind == "number" then
        return s .. " " .. tostring(rule.value)
    end
    return s .. " \u{201C}" .. tostring(rule.value) .. "\u{201D}"
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local lower = util.stringLower or string.lower

local function norm(s)
    if s == nil then return nil end
    s = util.trim(tostring(s))
    if s == "" then return nil end
    return lower(s)
end

local function isSmart(name)
    local s = name and ReadCollection.coll_settings and ReadCollection.coll_settings[name]
    return s and type(s.smart) == "table" or false
end

local function getHomeDir()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or lfs.attributes(home, "mode") ~= "directory" then
        local ok, dir = pcall(filemanagerutil.getDefaultDir)
        home = ok and dir or nil
    end
    return home and (ffiUtil.realpath(home) or home)
end

local function getSmartNames()
    local names = {}
    for name in pairs(ReadCollection.coll or {}) do
        if isSmart(name) then table.insert(names, name) end
    end
    return names
end

local last_refresh = {} -- coll_name -> os.time()
local last_list_refresh = 0

-- metadata cache (for books whose metadata had to be read from the file)
local meta_cache
local function getCache()
    if not meta_cache then
        meta_cache = LuaSettings:open(CACHE_FILE)
        meta_cache.data.files = meta_cache.data.files or {}
    end
    return meta_cache
end

local CACHED_PROPS = { "title", "authors", "series", "series_index", "language", "keywords", "description", "pages", "display_title" }
local META_PROPS = { "title", "authors", "series", "series_index", "language", "keywords", "description" }

local function hasMetadata(props)
    if type(props) ~= "table" then return false end
    for _i, k in ipairs(META_PROPS) do
        if props[k] ~= nil and props[k] ~= "" then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Rule evaluation (runs in a subprocess)
-- ---------------------------------------------------------------------------

local function splitList(str, pattern)
    local out = {}
    if type(str) ~= "string" then return out end
    for part in str:gmatch(pattern) do
        local v = norm(part)
        if v then table.insert(out, v) end
    end
    return out
end

local function textMatch(values, op, needle)
    if op == "is_empty" then return #values == 0 end
    if op == "not_empty" then return #values > 0 end
    needle = norm(needle) or ""
    local any = false
    for _i, v in ipairs(values) do
        if op == "contains" or op == "not_contains" then
            any = v:find(needle, 1, true) ~= nil
        elseif op == "equals" or op == "not_equals" then
            any = v == needle
        elseif op == "starts_with" then
            any = v:sub(1, #needle) == needle
        end
        if any then break end
    end
    if op == "not_contains" or op == "not_equals" then
        return not any
    end
    return any
end

local function numberMatch(value, op, target)
    target = tonumber(target)
    if value == nil or target == nil then
        return op == "ne"
    end
    if op == "eq" then return value == target
    elseif op == "ne" then return value ~= target
    elseif op == "gt" then return value > target
    elseif op == "ge" then return value >= target
    elseif op == "lt" then return value < target
    elseif op == "le" then return value <= target
    end
    return false
end

-- Builds a lazy "book" accessor for one file.
local function makeBook(file, fname, rel_folder, bookinfo, cache_files, new_cache, attr)
    local book = {}
    local props_loaded, props
    local info

    local function getInfo()
        if not info then
            local ok, res = pcall(BookList.getBookInfo, file)
            info = ok and res or { been_opened = false }
        end
        return info
    end

    local function getProps()
        if props_loaded then return props end
        props_loaded = true
        local ok, res = pcall(bookinfo.getDocProps, bookinfo, file, nil, true)
        props = ok and res or {}
        if not hasMetadata(props) then
            local mtime = attr and attr.modification
            local cached = cache_files[file]
            if cached and cached.mtime == mtime and cached.size == (attr and attr.size) then
                props = cached.props or {}
            else
                -- read metadata from the file itself (slow once, then cached)
                ok, res = pcall(bookinfo.getDocProps, bookinfo, file, nil, false)
                props = ok and res or {}
                local keep = {}
                for _i, k in ipairs(CACHED_PROPS) do
                    local v = props[k]
                    if k == "description" and type(v) == "string" and #v > 3000 then
                        v = v:sub(1, 3000)
                    end
                    keep[k] = v
                end
                new_cache[file] = { mtime = mtime, size = attr and attr.size, props = keep }
            end
        end
        return props
    end

    function book.values(field_id)
        local field = FIELD_BY_ID[field_id]
        if field_id == "status" then
            return BookList.getBookStatus(file)
        elseif field_id == "rating" then
            local i = getInfo()
            return i.been_opened and (i.rating or 0) or 0
        elseif field_id == "progress" then
            local i = getInfo()
            if not i.been_opened then return 0 end
            if i.status == "complete" then return 100 end
            return math.floor((i.percent_finished or 0) * 1000 + 0.5) / 10
        elseif field_id == "highlights" then
            local i = getInfo()
            return i.been_opened and i.has_annotations and true or false
        elseif field_id == "pages" then
            local i = getInfo()
            local p = i.pages or getProps().pages
            return tonumber(p)
        elseif field_id == "filename" then
            return { norm(fname) }
        elseif field_id == "filetype" then
            local ext = fname:match("%.([^%.]+)$")
            return { norm(ext) }
        elseif field_id == "folder" then
            return { norm(rel_folder) }
        elseif field_id == "series_index" then
            return tonumber(getProps().series_index)
        elseif field and field.meta then
            local p = getProps()
            local v = p[field_id]
            if field_id == "title" then v = v or p.display_title end
            if field_id == "keywords" then
                return splitList(v, "[^\n,;]+")
            elseif field_id == "authors" then
                return splitList(v, "[^\n]+")
            elseif field_id == "description" and type(v) == "string" and util.htmlToPlainTextIfHtml then
                local ok, txt = pcall(util.htmlToPlainTextIfHtml, v)
                if ok then v = txt end
            end
            return { norm(v) }
        end
        return {}
    end
    return book
end

local function ruleMatches(book, rule)
    local field = FIELD_BY_ID[rule.field]
    if not field then return false end
    local v = book.values(rule.field)
    if field.kind == "text" then
        local vals = {}
        for _i, x in ipairs(v or {}) do if x then table.insert(vals, x) end end
        return textMatch(vals, rule.op, rule.value)
    elseif field.kind == "number" then
        return numberMatch(v, rule.op, rule.value)
    elseif field.kind == "status" then
        if rule.op == "is" then return v == rule.value end
        return v ~= rule.value
    elseif field.kind == "bool" then
        if rule.op == "is_true" then return v == true end
        return v ~= true
    end
    return false
end

local function specMatches(book, spec)
    local rules = spec.rules or {}
    if #rules == 0 then return true end
    if spec.match == "any" then
        for _i, rule in ipairs(rules) do
            if ruleMatches(book, rule) then return true end
        end
        return false
    end
    for _i, rule in ipairs(rules) do
        if not ruleMatches(book, rule) then return false end
    end
    return true
end

-- Scans the home folder (recursively), returns matches per collection.
local function scanLibrary(home, specs, bookinfo, cache_files)
    local matches, new_cache, seen = {}, {}, {}
    for name in pairs(specs) do matches[name] = {} end
    local home_len = #home

    local function scan(dir)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for f in iter, dir_obj do
            if f ~= "." and f ~= ".." and f:sub(1, 1) ~= "." then
                local path = dir .. "/" .. f
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    if not f:match("%.sdr$") then
                        scan(path)
                    end
                elseif attr and attr.mode == "file" and DocumentRegistry:hasProvider(path) then
                    local real = ffiUtil.realpath(path) or path
                    if not seen[real] then
                        seen[real] = true
                        local rel = dir:sub(home_len + 2)
                        local book = makeBook(real, f, rel, bookinfo, cache_files, new_cache, attr)
                        for name, spec in pairs(specs) do
                            local ok2, res = pcall(specMatches, book, spec)
                            if ok2 and res then
                                table.insert(matches[name], real)
                            elseif not ok2 then
                                logger.warn("SmartCollections: error evaluating", real, res)
                            end
                        end
                    end
                end
            end
        end
    end
    scan(home)

    local stale = {}
    for file in pairs(cache_files) do
        if not seen[file] then table.insert(stale, file) end
    end
    return { matches = matches, new_cache = new_cache, stale = stale }
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function FMC:refreshSmartCollections(names, done_callback)
    local specs, count = {}, 0
    for _i, name in ipairs(names) do
        if isSmart(name) then
            specs[name] = util.tableDeepCopy(ReadCollection.coll_settings[name].smart)
            count = count + 1
        end
    end
    local function finish()
        if done_callback then done_callback() end
    end
    if count == 0 then return finish() end

    local home = getHomeDir()
    if not home then
        UIManager:show(InfoMessage:new{ text = _("Smart collections: please set a Home folder first.") })
        return finish()
    end

    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local cache = getCache()
        local cache_files = cache.data.files
        local bookinfo = self.ui.bookinfo
        local info = InfoMessage:new{
            text = count == 1 and _("Updating smart collection…") or _("Updating smart collections…"),
        }
        UIManager:show(info)
        UIManager:forceRePaint()
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            return scanLibrary(home, specs, bookinfo, cache_files)
        end, info)
        UIManager:close(info)
        if not completed or type(result) ~= "table" or type(result.matches) ~= "table" then
            logger.warn("SmartCollections: update cancelled or failed")
            return finish()
        end

        -- update cache
        local cache_dirty = false
        for file, entry in pairs(result.new_cache or {}) do
            cache_files[file] = entry
            cache_dirty = true
        end
        for _i, file in ipairs(result.stale or {}) do
            cache_files[file] = nil
            cache_dirty = true
        end
        if cache_dirty then cache:flush() end

        -- update collections
        local now = os.time()
        local to_write = {}
        for name, files in pairs(result.matches) do
            local coll = ReadCollection.coll[name]
            if coll then
                local want = {}
                for _i, file in ipairs(files) do want[file] = true end
                local changed = false
                for file in pairs(coll) do
                    if not want[file] then
                        coll[file] = nil
                        changed = true
                    end
                end
                for _i, file in ipairs(files) do
                    if not coll[file] and lfs.attributes(file, "mode") == "file" then
                        ReadCollection:addItem(file, name)
                        changed = true
                    end
                end
                last_refresh[name] = now
                if changed then
                    to_write[name] = true
                    self.files_updated = self.show_mark
                end
            end
        end
        if next(to_write) then
            ReadCollection:write(to_write)
        end

        -- refresh visible widgets
        if self.coll_list and self.coll_list.item_table then
            for _i, item in ipairs(self.coll_list.item_table) do
                if item.name and result.matches[item.name] then
                    item.mandatory = self.getCollListItemMandatory(item.name)
                end
            end
            self:updateCollListItemTable()
        end
        if self.booklist_menu and result.matches[self.booklist_menu.path] then
            self:updateItemTable()
        end
        finish()
    end)
end

-- ---------------------------------------------------------------------------
-- Hooks: showing collections / list
-- ---------------------------------------------------------------------------

local orig_onShowColl = FMC.onShowColl
function FMC:onShowColl(collection_name)
    local name = collection_name or ReadCollection.default_collection_name
    if isSmart(name) and os.time() - (last_refresh[name] or 0) >= COLL_REFRESH_INTERVAL then
        self:refreshSmartCollections({ name }, function()
            orig_onShowColl(self, collection_name)
        end)
        return true
    end
    return orig_onShowColl(self, collection_name)
end

local orig_onShowCollList = FMC.onShowCollList
function FMC:onShowCollList(file_or_selected_collections, caller_callback, no_dialog)
    local jumps_to_default = ReadCollection.coll_default and not self.booklist_menu
    if file_or_selected_collections == nil and not jumps_to_default
            and os.time() - last_list_refresh >= LIST_REFRESH_INTERVAL then
        local names = {}
        for _i, name in ipairs(getSmartNames()) do
            if os.time() - (last_refresh[name] or 0) >= COLL_REFRESH_INTERVAL then
                table.insert(names, name)
            end
        end
        last_list_refresh = os.time()
        if #names > 0 then
            self:refreshSmartCollections(names, function()
                orig_onShowCollList(self, file_or_selected_collections, caller_callback, no_dialog)
            end)
            return true
        end
    end
    return orig_onShowCollList(self, file_or_selected_collections, caller_callback, no_dialog)
end

-- marker in the collections list
local orig_getCollMarker = FMC.getCollMarker
FMC.getCollMarker = function(coll_name)
    local marker = orig_getCollMarker(coll_name)
    if isSmart(coll_name) then
        return marker and (SMART_MARKER .. " " .. marker) or SMART_MARKER
    end
    return marker
end

-- ---------------------------------------------------------------------------
-- New collection: normal or smart?
-- ---------------------------------------------------------------------------

local orig_addCollection = FMC.addCollection
function FMC:addCollection()
    local dialog
    dialog = ButtonDialog:new{
        title = _("New collection"),
        title_align = "center",
        buttons = {
            {{
                text = _("Normal collection"),
                callback = function()
                    UIManager:close(dialog)
                    orig_addCollection(self)
                end,
            }},
            {{
                text = _("Smart collection (rules)"),
                callback = function()
                    UIManager:close(dialog)
                    self:editCollectionName(function(name)
                        self:showSmartRulesEditor(name, { match = "all", rules = {} }, true)
                    end)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- same as the core addCollection() callback, plus the smart settings
function FMC:createSmartCollection(name, spec)
    self.updated_collections[name] = true
    ReadCollection:addCollection(name)
    ReadCollection.coll_settings[name].smart = spec
    if self.coll_list and self.coll_list.item_table then
        local mandatory
        if self.selected_collections then
            mandatory = self.checkmark
            self.selected_collections[name] = true
        else
            mandatory = self.getCollListItemMandatory(name)
        end
        table.insert(self.coll_list.item_table, {
            text      = name,
            mandatory = mandatory,
            name      = name,
            order     = ReadCollection.coll_settings[name].order,
        })
        self:updateCollListItemTable(false, #self.coll_list.item_table)
    end
    ReadCollection:write({ [name] = true })
end

-- ---------------------------------------------------------------------------
-- Rule editor
-- ---------------------------------------------------------------------------

function FMC:showSmartRulesEditor(name, spec, is_new)
    local dialog
    local function reopen()
        self:showSmartRulesEditor(name, spec, is_new)
    end
    local buttons = {}
    for i, rule in ipairs(spec.rules) do
        table.insert(buttons, {{
            text = describeRule(rule),
            callback = function()
                UIManager:close(dialog)
                self:showSmartRuleActions(spec, i, reopen)
            end,
        }})
    end
    table.insert(buttons, {{
        text = "+ " .. _("Add rule"),
        callback = function()
            UIManager:close(dialog)
            self:pickSmartRule(nil, function(rule)
                if rule then table.insert(spec.rules, rule) end
                reopen()
            end)
        end,
    }})
    table.insert(buttons, {{
        text = spec.match == "any" and _("Books must match: ANY rule") or _("Books must match: ALL rules"),
        callback = function()
            UIManager:close(dialog)
            spec.match = spec.match == "any" and "all" or "any"
            reopen()
        end,
    }})
    table.insert(buttons, {}) -- separator
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
        {
            text = is_new and _("Create") or _("Save"),
            callback = function()
                UIManager:close(dialog)
                if is_new then
                    if ReadCollection.coll[name] then
                        UIManager:show(InfoMessage:new{ text = T(_("Collection already exists: %1"), name) })
                        return
                    end
                    self:createSmartCollection(name, spec)
                else
                    if not ReadCollection.coll_settings[name] then return end
                    ReadCollection.coll_settings[name].smart = spec
                    self.updated_collections[name] = true
                    ReadCollection:write({ [name] = true })
                end
                last_refresh[name] = nil
                self:refreshSmartCollections({ name })
            end,
        },
    })
    local title = T(_("Smart collection: %1"), name)
    if #spec.rules == 0 then
        title = title .. "\n" .. _("No rules yet: all books in Home would be included.")
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function FMC:showSmartRuleActions(spec, idx, reopen)
    local dialog
    dialog = ButtonDialog:new{
        title = describeRule(spec.rules[idx]),
        title_align = "center",
        tap_close_callback = reopen,
        buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        table.remove(spec.rules, idx)
                        reopen()
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:pickSmartRule(spec.rules[idx], function(rule)
                            if rule then spec.rules[idx] = rule end
                            reopen()
                        end)
                    end,
                },
            },
            {{
                text = _("Back"),
                callback = function()
                    UIManager:close(dialog)
                    reopen()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Step-by-step: field -> operator -> value. done(rule) or done(nil) on cancel.
function FMC:pickSmartRule(old_rule, done)
    local function pickValue(field, op)
        if NO_VALUE_OPS[op] then
            return done({ field = field.id, op = op })
        end
        if field.kind == "status" then
            local dialog
            local buttons = {}
            for _i, st in ipairs(STATUSES) do
                table.insert(buttons, {{
                    text = statusText(st),
                    callback = function()
                        UIManager:close(dialog)
                        done({ field = field.id, op = op, value = st })
                    end,
                }})
            end
            dialog = ButtonDialog:new{
                title = field.text .. " " .. opText(field.kind, op) .. "…",
                title_align = "center",
                tap_close_callback = function() done(nil) end,
                buttons = buttons,
            }
            UIManager:show(dialog)
            return
        end
        local hint
        if field.id == "keywords" then hint = "fantasy"
        elseif field.id == "rating" then hint = "0–5"
        elseif field.id == "progress" then hint = "0–100"
        elseif field.id == "filetype" then hint = "epub"
        elseif field.id == "folder" then hint = "Fantasy/Tolkien"
        end
        local input_dialog
        local old_value = old_rule and old_rule.field == field.id and old_rule.value
        input_dialog = InputDialog:new{
            title = field.text .. " " .. opText(field.kind, op) .. "…",
            input = old_value and tostring(old_value) or nil,
            input_hint = hint,
            input_type = field.kind == "number" and "number" or nil,
            buttons = {{
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        done(nil)
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local value = util.trim(input_dialog:getInputText() or "")
                        if value == "" then return end
                        if field.kind == "number" then
                            value = tonumber((value:gsub(",", ".")))
                            if not value then return end
                        end
                        UIManager:close(input_dialog)
                        done({ field = field.id, op = op, value = value })
                    end,
                },
            }},
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    local function pickOp(field)
        local dialog
        local buttons, row = {}, {}
        for _i, o in ipairs(OPS[field.kind]) do
            local op = o[1]
            local mark = old_rule and old_rule.field == field.id and old_rule.op == op and " \u{2713}" or ""
            table.insert(row, {
                text = o[2] .. mark,
                callback = function()
                    UIManager:close(dialog)
                    pickValue(field, op)
                end,
            })
            if #row == 2 then
                table.insert(buttons, row)
                row = {}
            end
        end
        if #row > 0 then table.insert(buttons, row) end
        dialog = ButtonDialog:new{
            title = field.text .. "…",
            title_align = "center",
            tap_close_callback = function() done(nil) end,
            buttons = buttons,
        }
        UIManager:show(dialog)
    end

    local dialog
    local buttons, row = {}, {}
    for _i, field in ipairs(FIELDS) do
        local mark = old_rule and old_rule.field == field.id and " \u{2713}" or ""
        table.insert(row, {
            text = field.text .. mark,
            callback = function()
                UIManager:close(dialog)
                pickOp(field)
            end,
        })
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then table.insert(buttons, row) end
    dialog = ButtonDialog:new{
        title = _("Choose a field"),
        title_align = "center",
        tap_close_callback = function() done(nil) end,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Long-press on a smart collection in the list
-- ---------------------------------------------------------------------------

local orig_onCollListHold = FMC.onCollListHold
function FMC:onCollListHold(item)
    local manager = self._manager
    if manager.selected_collections or not isSmart(item.name) then
        return orig_onCollListHold(self, item)
    end
    local coll_name = item.name
    local dialog
    dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Edit rules"),
                    callback = function()
                        UIManager:close(dialog)
                        manager:showSmartRulesEditor(coll_name,
                            util.tableDeepCopy(ReadCollection.coll_settings[coll_name].smart), false)
                    end,
                },
                {
                    text = _("Update now"),
                    callback = function()
                        UIManager:close(dialog)
                        manager:refreshSmartCollections({ coll_name })
                    end,
                },
            },
            {{
                text = _("Convert to normal collection"),
                callback = function()
                    UIManager:close(dialog)
                    ReadCollection.coll_settings[coll_name].smart = nil
                    last_refresh[coll_name] = nil
                    manager:refreshCollList(item)
                    ReadCollection:write({ [coll_name] = true })
                end,
            }},
            {}, -- separator
            {{
                text = coll_name ~= ReadCollection.coll_default and _("Set default") or _("Reset default"),
                callback = function()
                    UIManager:close(dialog)
                    manager:toggleCollDefault(item)
                end,
            }},
            {
                {
                    text = _("Remove collection"),
                    callback = function()
                        UIManager:close(dialog)
                        manager:removeCollection(item)
                    end,
                },
                {
                    text = _("Rename collection"),
                    callback = function()
                        UIManager:close(dialog)
                        local old_last = last_refresh[coll_name]
                        manager:renameCollection(item)
                        last_refresh[coll_name] = old_last
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- ---------------------------------------------------------------------------
-- Menu inside a smart collection: add "Edit rules" / "Update now",
-- hide the manual "Add books" buttons (they would be undone on next update).
-- ---------------------------------------------------------------------------

local orig_showCollDialog = FMC.showCollDialog
function FMC:showCollDialog()
    local name = self.booklist_menu and self.booklist_menu.path
    if not isSmart(name) then
        return orig_showCollDialog(self)
    end
    local manager = self
    local drop = {
        [_("Add all books from a folder")] = true,
        [_("Add all books from a folder and its subfolders")] = true,
        [_("Add a book to collection")] = true,
    }
    local own_new = rawget(ButtonDialog, "new")
    local base_new = ButtonDialog.new
    local dialog_ref
    rawset(ButtonDialog, "new", function(cls, o)
        rawset(ButtonDialog, "new", own_new) -- one-shot
        if type(o) == "table" and type(o.buttons) == "table" then
            local buttons = {
                {
                    {
                        text = _("Edit smart rules"),
                        callback = function()
                            UIManager:close(dialog_ref)
                            manager:showSmartRulesEditor(name,
                                util.tableDeepCopy(ReadCollection.coll_settings[name].smart), false)
                        end,
                    },
                    {
                        text = _("Update now"),
                        callback = function()
                            UIManager:close(dialog_ref)
                            manager:refreshSmartCollections({ name })
                        end,
                    },
                },
            }
            local last_was_sep = false
            for _i, row in ipairs(o.buttons) do
                local keep = {}
                for _j, b in ipairs(row) do
                    if not (type(b.text) == "string" and drop[b.text]) then
                        table.insert(keep, b)
                    end
                end
                if #row == 0 then
                    if not last_was_sep then table.insert(buttons, keep) end
                    last_was_sep = true
                elseif #keep > 0 then
                    table.insert(buttons, keep)
                    last_was_sep = false
                end
            end
            if #buttons[#buttons] == 0 then table.remove(buttons) end
            o.buttons = buttons
        end
        dialog_ref = base_new(cls, o)
        return dialog_ref
    end)
    local ok, err = pcall(orig_showCollDialog, self)
    rawset(ButtonDialog, "new", own_new)
    if not ok then error(err) end
end

logger.info("SmartCollections patch loaded")
