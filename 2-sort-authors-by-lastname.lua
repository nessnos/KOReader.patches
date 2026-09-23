--[[--
KOReader user patch: sort authors by LAST name.

Author metadata is usually stored as "FirstName LastName" (e.g. "Terry Pratchett"),
so author lists end up sorted by first name. This patch keeps the names displayed
exactly as they are, but sorts them by last name ("Pratchett, Terry").

Where it applies:
  * SimpleUI plugin (if installed): Library > Browse by Author list.
  * Stock KOReader: Collections > (menu) > filter by Author(s) list.
  * Stock KOReader: Bookmark browser > Filters > Author(s) list.
  * Stock KOReader: "Sort by: Authors" for books in collections/history
    (can be turned off below with SORT_BOOKS_BY_AUTHOR).
Anything that isn't present in your KOReader/SimpleUI version is simply skipped.

Install: copy this file into  koreader/patches/  (create the folder if needed)
and restart KOReader.

How the last name is found:
  * "Last, First" (already has a comma)  -> part before the comma is the last name.
  * "First Middle Last"                  -> last word is the last name.
  * Suffixes like Jr., Sr., III, PhD are ignored ("Martin Luther King Jr." -> King).
  * Titles like Dr., Prof., Mr. are ignored.
  * Particles (van, von, de, la...) are NOT part of the last name by default,
    like Calibre ("Ludwig van Beethoven" -> Beethoven). Set USE_SURNAME_PREFIXES
    to true to sort him under "van Beethoven" instead.
  * Single names ("Homer", "Colette") sort by that name.
  * Accents are ignored for sorting (É sorts with E), even on devices like Kobo
    that have no locale support.
Tip: for names the rule gets wrong (e.g. "Gabriel García Márquez"), edit the
book's author metadata to "García Márquez, Gabriel" and it will sort correctly.
--]]--

-- ===========================================================================
-- Settings
-- ===========================================================================
local USE_SURNAME_PREFIXES = false -- true: "Ludwig van Beethoven" sorts under "van Beethoven"
local SORT_BOOKS_BY_AUTHOR = true  -- also use last names for "Sort by: Authors" of book lists

local SURNAME_PREFIXES = {
    ["da"] = true, ["das"] = true, ["de"] = true, ["del"] = true, ["della"] = true,
    ["den"] = true, ["der"] = true, ["des"] = true, ["di"] = true, ["do"] = true,
    ["dos"] = true, ["du"] = true, ["la"] = true, ["le"] = true, ["les"] = true,
    ["ten"] = true, ["ter"] = true, ["van"] = true, ["von"] = true, ["zu"] = true,
}
local NAME_TITLES = {
    ["mr"] = true, ["mrs"] = true, ["ms"] = true, ["dr"] = true, ["prof"] = true, ["sir"] = true,
}
local NAME_SUFFIXES = {
    ["jr"] = true, ["sr"] = true, ["junior"] = true, ["senior"] = true,
    ["ii"] = true, ["iii"] = true, ["iv"] = true,
    ["phd"] = true, ["ph.d"] = true, ["md"] = true, ["m.d"] = true, ["esq"] = true,
}

-- ===========================================================================
-- Sort key computation
-- ===========================================================================
local logger = require("logger")
local ffiUtil = require("ffi/util")

local function strcoll(a, b)
    return ffiUtil.strcoll(a, b)
end

-- Fold accented Latin letters to their base letter and lowercase everything,
-- so sorting behaves the same on devices without locale support (Kobo).
local FOLD = {}
do
    local groups = {
        a = "àáâãäåāăąÀÁÂÃÄÅĀĂĄ", c = "çćĉċčÇĆĈĊČ", d = "ďđĎĐ",
        e = "èéêëēĕėęěÈÉÊËĒĔĖĘĚ", g = "ĝğġģĜĞĠĢ", h = "ĥħĤĦ",
        i = "ìíîïĩīĭįıÌÍÎÏĨĪĬĮİ", j = "ĵĴ", k = "ķĶ", l = "ĺļľŀłĹĻĽĿŁ",
        n = "ñńņňÑŃŅŇ", o = "òóôõöøōŏőÒÓÔÕÖØŌŎŐ", r = "ŕŗřŔŖŘ",
        s = "śŝşšŚŜŞŠ", t = "ţťŧŢŤŦ", u = "ùúûüũūŭůűųÙÚÛÜŨŪŬŮŰŲ",
        w = "ŵŴ", y = "ýÿŷÝŸŶ", z = "źżžŹŻŽ",
        ae = "æÆ", oe = "œŒ", ss = "ß", th = "þÞ",
    }
    for base, chars in pairs(groups) do
        for ch in chars:gmatch("[\192-\244][\128-\191]*") do
            FOLD[ch] = base
        end
    end
end

local function fold(s)
    s = s:gsub("[\192-\244][\128-\191]*", FOLD)
    return s:lower()
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function bare(token) -- "Jr.," -> "jr"
    return (token:lower():gsub("[%.,]+$", ""))
end

local key_cache = {}

-- Returns { folded_last_name, folded_given_names }
local function sortKey(name)
    local key = key_cache[name]
    if key then return key end

    local s = trim(name:gsub("%s+", " "))
    local last, given

    -- Comma-separated parts; drop trailing parts that are only suffixes ("King, Jr.")
    local parts = {}
    for part in s:gmatch("[^,]+") do
        part = trim(part)
        if part ~= "" then table.insert(parts, part) end
    end
    while #parts > 1 and NAME_SUFFIXES[bare(parts[#parts])] do
        table.remove(parts)
    end

    if #parts >= 2 then
        -- Already "Last, First"
        last = parts[1]
        given = table.concat(parts, " ", 2)
    else
        local tokens = {}
        for token in (parts[1] or s):gmatch("%S+") do
            table.insert(tokens, token)
        end
        while #tokens > 1 and NAME_TITLES[bare(tokens[1])] do
            table.remove(tokens, 1)
        end
        while #tokens > 1 and NAME_SUFFIXES[bare(tokens[#tokens])] do
            table.remove(tokens)
        end
        if #tokens <= 1 then
            last, given = tokens[1] or s, ""
        else
            local i = #tokens
            if USE_SURNAME_PREFIXES then
                while i > 2 and SURNAME_PREFIXES[tokens[i - 1]:lower()] do
                    i = i - 1
                end
            end
            last = table.concat(tokens, " ", i)
            given = table.concat(tokens, " ", 1, i - 1)
        end
    end

    key = { fold(last), fold(given) }
    key_cache[name] = key
    return key
end

-- Compare two single author names by last name, then given names.
local function authorLess(a, b)
    if a == b then return false end
    -- KOReader's "N/A" placeholder starts with \0 and must stay first
    local a0, b0 = a:byte(1) == 0, b:byte(1) == 0
    if a0 ~= b0 then return a0 end
    local ka, kb = sortKey(a), sortKey(b)
    if ka[1] ~= kb[1] then return strcoll(ka[1], kb[1]) end
    if ka[2] ~= kb[2] then return strcoll(ka[2], kb[2]) end
    return strcoll(a, b)
end

-- Compare two newline-separated author lists ("A\nB"), author by author.
local function authorListLess(a, b)
    if a == b then return false end
    local la, lb = {}, {}
    for n in a:gmatch("[^\n]+") do table.insert(la, n) end
    for n in b:gmatch("[^\n]+") do table.insert(lb, n) end
    for i = 1, math.min(#la, #lb) do
        if la[i] ~= lb[i] then return authorLess(la[i], lb[i]) end
    end
    return #la < #lb
end

-- ===========================================================================
-- Stock KOReader: author value lists (Collections filter, Bookmark browser)
-- ===========================================================================
local ok_bl, BookList = pcall(require, "ui/widget/booklist")
if not ok_bl then BookList = nil end

local function itemAuthorLess(a, b)
    return authorLess(a.text, b.text)
end

local function wrapShowPropValueList(module_path)
    local ok, Module = pcall(require, module_path)
    if not ok or type(Module) ~= "table" or type(Module.showPropValueList) ~= "function"
            or not BookList or type(BookList.getCollateSortFunc) ~= "function" then
        return
    end
    local orig = Module.showPropValueList
    Module.showPropValueList = function(self, prop, ...)
        if prop ~= "authors" then
            return orig(self, prop, ...)
        end
        -- The list is sorted with BookList.getCollateSortFunc() inside the
        -- original function: swap in our comparator just for this call.
        local saved = BookList.getCollateSortFunc
        BookList.getCollateSortFunc = function() return itemAuthorLess end
        local ok_call, err = pcall(orig, self, prop, ...)
        BookList.getCollateSortFunc = saved
        if not ok_call then error(err, 0) end
    end
    logger.info("sort-authors-by-lastname: patched", module_path)
end

wrapShowPropValueList("apps/filemanager/filemanagercollection")
wrapShowPropValueList("ui/widget/bookmarkbrowser")

-- Stock KOReader: "Sort by: Authors" for book lists
if SORT_BOOKS_BY_AUTHOR and BookList and type(BookList.collates) == "table"
        and type(BookList.collates.authors) == "table" then
    local NO_AUTHOR = "\u{FFFF}" -- placeholder KOReader uses for books without author
    BookList.collates.authors.init_sort_func = function()
        return function(a, b)
            local aa, ba = a.doc_props.authors, b.doc_props.authors
            if aa ~= ba then
                if aa == NO_AUTHOR then return false end
                if ba == NO_AUTHOR then return true end
                return authorListLess(aa, ba)
            end
            return BookList.strcoll(a.doc_props.display_title, b.doc_props.display_title)
        end
    end
    logger.info("sort-authors-by-lastname: patched BookList authors collate")
end

-- ===========================================================================
-- SimpleUI plugin: Browse by Author
-- ===========================================================================
local function patchSimpleUI()
    local ok, MetadataSource = pcall(require, "features/library/sui_metadata_source")
    if not ok or type(MetadataSource) ~= "table"
            or type(MetadataSource.getFacetValues) ~= "function" then
        return
    end
    if MetadataSource._sort_authors_by_lastname then return end -- already patched
    MetadataSource._sort_authors_by_lastname = true

    local orig = MetadataSource.getFacetValues
    MetadataSource.getFacetValues = function(bim, base_dir, dimension, ...)
        local values = orig(bim, base_dir, dimension, ...)
        if dimension == "author" and type(values) == "table" and #values > 1 then
            -- values = { {author_name, count, _first=row}, ... } (a copy, safe to sort)
            table.sort(values, function(a, b)
                local av, bv = a[1], b[1]
                if av == bv then return false end
                if not av or av == "" then return false end -- "no author" stays last
                if not bv or bv == "" then return true end
                return authorLess(av, bv)
            end)
        end
        return values
    end
    logger.info("sort-authors-by-lastname: patched SimpleUI author browsing")
end

local userpatch = require("userpatch")
if type(userpatch.registerPatchPluginFunc) == "function" then
    -- Runs each time the SimpleUI plugin is instantiated (its modules are then requireable)
    userpatch.registerPatchPluginFunc("simpleui", function()
        local ok, err = pcall(patchSimpleUI)
        if not ok then logger.warn("sort-authors-by-lastname: SimpleUI patch failed:", err) end
    end)
end
-- In case SimpleUI is already loaded
pcall(patchSimpleUI)
