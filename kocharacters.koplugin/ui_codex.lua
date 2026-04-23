-- ui_codex.lua
-- KoCharacters: Codex browser, viewer, and editor.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer  = require("ui/widget/textviewer")
local ConfirmBox  = require("ui/widget/confirmbox")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen
local _           = require("gettext")

local GeminiClient   = require("gemini_client")
local Portrait       = require("portrait")
local UIShared       = require("ui_shared")
local UtilsCharacter = require("utils_character")

local UICodex = {}

local TYPE_ORDER = { place = 1, faction = 2, concept = 3, object = 4, species = 5, unknown = 6 }

-- ---------------------------------------------------------------------------
-- Plain-text formatter (fallback when HTML viewer is disabled)
-- ---------------------------------------------------------------------------

local function formatEntryText(entry)
    local lines = {}

    local type_label = (entry.type and entry.type ~= "" and entry.type ~= "unknown")
        and ("[" .. entry.type:upper() .. "]") or "[UNKNOWN TYPE]"
    table.insert(lines, type_label)
    table.insert(lines, "")

    if entry.description and entry.description ~= "" then
        table.insert(lines, entry.description)
        table.insert(lines, "")
    end

    if entry.significance and entry.significance ~= "" then
        table.insert(lines, "Significance")
        table.insert(lines, entry.significance)
        table.insert(lines, "")
    end

    if entry.known_connections and #entry.known_connections > 0 then
        local items = {}
        for _, c in ipairs(entry.known_connections) do
            if c ~= "" then table.insert(items, c) end
        end
        if #items > 0 then
            table.insert(lines, "Known connections: " .. table.concat(items, ", "))
            table.insert(lines, "")
        end
    end

    if entry.aliases and #entry.aliases > 0 then
        local items = {}
        for _, a in ipairs(entry.aliases) do
            if a ~= "" then table.insert(items, a) end
        end
        if #items > 0 then
            table.insert(lines, "Also known as: " .. table.concat(items, ", "))
            table.insert(lines, "")
        end
    end

    if entry.first_appearance_quote and entry.first_appearance_quote ~= "" then
        local page_str = entry.first_seen_page and (" p." .. tostring(entry.first_seen_page)) or ""
        table.insert(lines, "First seen" .. page_str .. ": \u{201C}" .. entry.first_appearance_quote .. "\u{201D}")
        table.insert(lines, "")
    end

    if entry.user_notes and entry.user_notes ~= "" then
        table.insert(lines, "Notes")
        table.insert(lines, entry.user_notes)
        table.insert(lines, "")
    end

    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- HTML formatter
-- ---------------------------------------------------------------------------

local function linkifyText(text, specs, esc_fn)
    if not text or text == "" or not specs or #specs == 0 then
        return esc_fn(text or "")
    end
    local segments = {{ text = text, linked = false }}
    for _, spec in ipairs(specs) do
        if #spec.name >= 3 then
            local name_lower = spec.name:lower()
            local new_segs = {}
            for _, seg in ipairs(segments) do
                if seg.linked then
                    new_segs[#new_segs+1] = seg
                else
                    local s       = seg.text
                    local s_lower = s:lower()
                    local pos, emit = 1, 1
                    while true do
                        local si, ei = s_lower:find(name_lower, pos, true)
                        if not si then
                            if emit <= #s then
                                new_segs[#new_segs+1] = { text = s:sub(emit), linked = false }
                            end
                            break
                        end
                        local before = si > 1  and s:sub(si-1, si-1) or " "
                        local after  = ei < #s and s:sub(ei+1, ei+1) or " "
                        if not before:match("[%a%d_%-]") and not after:match("[%a%d_%-]") then
                            if si > emit then
                                new_segs[#new_segs+1] = { text = s:sub(emit, si-1), linked = false }
                            end
                            new_segs[#new_segs+1] = {
                                text   = s:sub(si, ei),
                                linked = true,
                                scheme = spec.scheme,
                                target = spec.target,
                            }
                            pos = ei + 1; emit = ei + 1
                        else
                            pos = si + 1
                        end
                    end
                end
            end
            segments = new_segs
        end
    end
    local parts = {}
    for _, seg in ipairs(segments) do
        if seg.linked then
            parts[#parts+1] = '<a href="' .. seg.scheme .. ':' .. esc_fn(seg.target) .. '">'
                .. esc_fn(seg.text) .. '</a>'
        else
            parts[#parts+1] = esc_fn(seg.text)
        end
    end
    return table.concat(parts)
end

-- opts.link_specs — array of {name, scheme, target} sorted longest-first; wraps names in links
local function formatHTML(entry, portrait_path, container_w, opts)
    opts = opts or {}
    local link_specs = opts.link_specs or {}

    local function esc(s)
        s = tostring(s or "")
        s = s:gsub("&",  "&amp;")
        s = s:gsub("<",  "&lt;")
        s = s:gsub(">",  "&gt;")
        s = s:gsub('"',  "&quot;")
        return s
    end

    local function linkify(text)
        return linkifyText(text, link_specs, esc)
    end

    local css = table.concat({
        "@page{margin:0;}",
        "html,body{margin:0;padding:0;}",
        "body{font-family:Georgia,serif;padding:12px 14px;background:#fff;color:#111;line-height:1.3;}",
        "h1{font-size:1.45em;color:#000;margin:0 0 3px;font-weight:bold;}",
        ".type{color:#444;font-style:italic;margin:0;font-size:0.87em;}",
        ".section{margin-top:16px;padding-top:12px;border-top:1px solid #ccc;}",
        ".label{font-size:0.76em;text-transform:uppercase;letter-spacing:.09em;color:#333;font-weight:bold;margin:0 0 5px;}",
        "p{margin:0;font-size:0.87em;text-align:justify;}",
        "ul{margin:4px 0 0 0;padding-left:36px;font-size:0.87em;}",
        "ul li{margin-bottom:3px;}",
        ".quote{border-left:2px solid #888;padding-left:10px;color:#444;font-style:italic;}",
        ".foot{font-size:.72em;color:#aaa;margin-top:16px;}",
        "a{color:#333;text-decoration:underline;}",
        "img.portrait{display:block;width:100%;height:auto;border-radius:3px;}",
    })

    local p = {}

    p[#p+1] = '<h1>' .. esc(entry.name or "Unknown") .. '</h1>'
    if entry.type and entry.type ~= "" and entry.type ~= "unknown" then
        p[#p+1] = '<p class="type">' .. esc(entry.type:upper()) .. '</p>'
    end

    if portrait_path then
        local body_w = (container_w or 300) - 28
        local img_w  = math.floor(body_w * 0.4)
        p[#p+1] = '<div style="margin-top:8px;"><img width="' .. img_w .. '" src="' .. portrait_path .. '"></div>'
    end

    if entry.description and entry.description ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Description</div><p>'
            .. linkify(entry.description) .. '</p></div>'
    end

    if entry.significance and entry.significance ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Significance</div><p>'
            .. linkify(entry.significance) .. '</p></div>'
    end

    if entry.known_connections and #entry.known_connections > 0 then
        local items = {}
        for _, c in ipairs(entry.known_connections) do
            if c ~= "" then
                -- Parse "Name (relationship)" format — name becomes a tappable link
                local conn_name, rel = c:match("^(.-)%s*%((.-)%)%s*$")
                if conn_name and conn_name ~= "" then
                    items[#items+1] = '<li><a href="entity:' .. esc(conn_name) .. '">'
                        .. esc(conn_name) .. '</a> (' .. esc(rel) .. ')</li>'
                else
                    items[#items+1] = '<li><a href="entity:' .. esc(c) .. '">' .. esc(c) .. '</a></li>'
                end
            end
        end
        if #items > 0 then
            p[#p+1] = '<div class="section"><div class="label">Known Connections</div><ul>'
                .. table.concat(items) .. '</ul></div>'
        end
    end

    if entry.aliases and #entry.aliases > 0 then
        local items = {}
        for _, a in ipairs(entry.aliases) do
            if a ~= "" then items[#items+1] = '<li>' .. esc(a) .. '</li>' end
        end
        if #items > 0 then
            p[#p+1] = '<div class="section"><div class="label">Also Known As</div><ul>'
                .. table.concat(items) .. '</ul></div>'
        end
    end

    if entry.first_appearance_quote and entry.first_appearance_quote ~= "" then
        local seen_label = "First Seen"
        if entry.first_seen_page then
            seen_label = seen_label .. " (page " .. tostring(entry.first_seen_page) .. ")"
        end
        p[#p+1] = '<div class="section"><div class="label">' .. seen_label
            .. '</div><p class="quote">&ldquo;' .. esc(entry.first_appearance_quote)
            .. '&rdquo;</p></div>'
    end

    if entry.user_notes and entry.user_notes ~= "" then
        p[#p+1] = '<div class="section"><div class="label">My Notes</div>'
            .. '<p style="white-space:pre-wrap;">' .. esc(entry.user_notes) .. '</p></div>'
    end

    if entry.source_page then
        p[#p+1] = '<p class="foot">Last updated: page ' .. tostring(entry.source_page) .. '</p>'
    end

    return css, table.concat(p)
end

-- ---------------------------------------------------------------------------
-- Entry viewer
-- ---------------------------------------------------------------------------

function UICodex.showEntryViewer(plugin, book_id, entry, refresh_browser_fn)
    if not entry then
        plugin:showMsg("Codex entry not found.")
        return
    end

    local name = entry.name or "Unknown"

    local function make_buttons(close_fn)
        return {
            {
                {
                    text = "Edit",
                    callback = function()
                        close_fn()
                        UICodex.onEditEntry(plugin, book_id, entry, refresh_browser_fn, function()
                            local fresh = plugin.db_codex:findByName(book_id, name)
                            UICodex.showEntryViewer(plugin, book_id, fresh or entry, refresh_browser_fn)
                        end)
                    end,
                },
                {
                    text = "Gen. image",
                    callback = function()
                        close_fn()
                        Portrait.onGenerateCodex(plugin, book_id, entry)
                        UIManager:scheduleIn(0.15, function()
                            local fresh = plugin.db_codex:findByName(book_id, name)
                            UICodex.showEntryViewer(plugin, book_id, fresh or entry, refresh_browser_fn)
                        end)
                    end,
                },
                {
                    text = "Clean up",
                    callback = function()
                        close_fn()
                        UICodex.onCleanupEntry(plugin, book_id, entry, refresh_browser_fn)
                    end,
                },
                {
                    text = "Delete",
                    callback = function()
                        close_fn()
                        UIManager:show(ConfirmBox:new{
                            text        = 'Delete "' .. name .. '" from the codex?',
                            ok_text     = "Delete",
                            ok_callback = function()
                                plugin.db_codex:deleteEntry(book_id, name)
                                plugin:showMsg('"' .. name .. '" deleted from codex.', 2)
                                if refresh_browser_fn then refresh_browser_fn() end
                            end,
                        })
                    end,
                },
                {
                    text     = "Close",
                    callback = function()
                        close_fn()
                        if refresh_browser_fn then refresh_browser_fn() end
                    end,
                },
            },
        }
    end

    if not G_reader_settings:readSetting("kocharacters_html_viewer") then
        local viewer
        viewer = TextViewer:new{
            title         = name,
            text          = formatEntryText(entry),
            width         = math.floor(Screen:getWidth() * 0.9),
            height        = math.floor(Screen:getHeight() * 0.85),
            buttons_table = make_buttons(function() UIManager:close(viewer) end),
        }
        UIManager:show(viewer)
        return
    end

    -- HTML viewer
    local inner_w       = Screen:getWidth() - 8 - 4
    local viewer_close  = {}

    local function entityLinkCallback(link)
        local link_url = type(link) == "table" and (link.uri or "") or tostring(link)
        local scheme, target = link_url:match("^([^:]+):(.+)$")
        if not scheme then return end
        target = target:match("^%s*(.-)%s*$") or ""
        if target == "" then return end
        local target_lower = target:lower()

        if scheme == "entity" or scheme == "codex" then
            local found_codex = plugin.db_codex:findByName(book_id, target)
            if found_codex then
                if viewer_close.close then viewer_close.close() end
                UIManager:scheduleIn(0.15, function()
                    UICodex.showEntryViewer(plugin, book_id, found_codex, refresh_browser_fn)
                end)
                return
            end
            -- Fall through to character search
        end

        if scheme == "entity" or scheme == "char" then
            local UICharacter = require("ui_character")
            local found_char = UtilsCharacter.findByPartialName(plugin.db:load(book_id), target_lower)
            if found_char then
                if viewer_close.close then viewer_close.close() end
                UIManager:scheduleIn(0.15, function()
                    UICharacter.showCharacterViewer(plugin, book_id, found_char, nil, nil, refresh_browser_fn)
                end)
            end
        end
    end

    local DataStorage    = require("datastorage")
    local portraits_dir  = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/codex_portraits"
    local portrait_path  = Portrait.codexPath(book_id, entry)
    local portrait_fname = nil
    local pf = io.open(portrait_path, "rb")
    if pf then pf:close(); portrait_fname = portrait_path:match("([^/]+)$") end

    -- Build link specs so named characters and codex entries in prose fields become clickable
    local self_names_lower = { [(entry.name or ""):lower()] = true }
    for _, a in ipairs(entry.aliases or {}) do
        if a ~= "" then self_names_lower[a:lower()] = true end
    end
    local link_specs = {}
    for _, c in ipairs(plugin.db:load(book_id)) do
        local cname = c.name or ""
        if cname ~= "" then
            link_specs[#link_specs+1] = { name = cname, scheme = "char", target = cname }
            for _, a in ipairs(c.aliases or {}) do
                if a ~= "" then
                    link_specs[#link_specs+1] = { name = a, scheme = "char", target = cname }
                end
            end
        end
    end
    for _, e in ipairs(plugin.db_codex:load(book_id)) do
        local ename = e.name or ""
        if ename ~= "" and not self_names_lower[ename:lower()] then
            link_specs[#link_specs+1] = { name = ename, scheme = "codex", target = ename }
            for _, a in ipairs(e.aliases or {}) do
                if a ~= "" and not self_names_lower[a:lower()] then
                    link_specs[#link_specs+1] = { name = a, scheme = "codex", target = ename }
                end
            end
        end
    end
    table.sort(link_specs, function(a, b) return #a.name > #b.name end)

    local html_css, html_body = formatHTML(entry, portrait_fname, inner_w, { link_specs = link_specs })

    UIShared.showHtmlViewer{
        inner_w       = inner_w,
        html_body     = html_body,
        html_css      = html_css,
        resource_dir  = portraits_dir,
        close_ref     = viewer_close,
        link_callback = entityLinkCallback,
        make_buttons  = function(close_fn)
            return make_buttons(close_fn)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Entry editor
-- ---------------------------------------------------------------------------

function UICodex.onEditEntry(plugin, book_id, entry, refresh_browser_fn, show_viewer_fn)
    local original_name = entry.name
    local edit_menu
    local closing_for_save = false

    local function showEditMenu()
        local function save()
            plugin.db_codex:updateEntry(book_id, original_name, entry)
            original_name = entry.name
        end

        local function after_save()
            closing_for_save = true
            UIManager:close(edit_menu)
            closing_for_save = false
            if refresh_browser_fn then refresh_browser_fn() end
            showEditMenu()
        end

        local editTextField = UIShared.editTextField

        local items = {
            {
                text     = "Name: " .. (entry.name or ""),
                callback = function()
                    editTextField("Name", entry.name, false, function(val)
                        if val ~= "" then entry.name = val; save(); after_save() end
                    end)
                end,
            },
            {
                text     = "Type: " .. (entry.type or "unknown"),
                callback = function()
                    local type_menu
                    local type_items = {}
                    for _, t in ipairs({"place","faction","concept","object","species","unknown"}) do
                        local tval = t
                        table.insert(type_items, {
                            text     = tval,
                            callback = function()
                                entry.type = tval; save()
                                UIManager:close(type_menu)
                                after_save()
                            end,
                        })
                    end
                    type_menu = Menu:new{
                        title       = "Select Type",
                        item_table  = type_items,
                        width       = Screen:getWidth(),
                        show_parent = plugin.ui,
                    }
                    UIManager:show(type_menu)
                end,
            },
            {
                text     = "Aliases: " .. table.concat(entry.aliases or {}, ", "),
                callback = function()
                    editTextField("Aliases (comma-separated)", table.concat(entry.aliases or {}, ", "), false, function(val)
                        local t = {}
                        for a in val:gmatch("[^,]+") do
                            local s = a:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        entry.aliases = t; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Description",
                callback = function()
                    editTextField("Description", entry.description, true, function(val)
                        entry.description = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Significance",
                callback = function()
                    editTextField("Significance", entry.significance, true, function(val)
                        entry.significance = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Known connections (one per line)",
                callback = function()
                    editTextField("Known Connections", table.concat(entry.known_connections or {}, "\n"), true, function(val)
                        local t = {}
                        for r in val:gmatch("[^\n]+") do
                            local s = r:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        entry.known_connections = t; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Notes" .. ((entry.user_notes and entry.user_notes ~= "") and " \u{270E}" or ""),
                callback = function()
                    editTextField("Notes", entry.user_notes, true, function(val)
                        entry.user_notes = val ~= "" and val or nil; save(); after_save()
                    end)
                end,
            },
        }

        edit_menu = Menu:new{
            title       = "Edit: " .. (entry.name or ""),
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = plugin.ui,
        }
        edit_menu.onClose = function()
            if not closing_for_save and show_viewer_fn then
                UIManager:close(edit_menu)
                show_viewer_fn()
            else
                UIManager:close(edit_menu)
            end
            return true
        end
        edit_menu.onReturn = function()
            UIManager:close(edit_menu)
            if show_viewer_fn then show_viewer_fn() end
        end
        UIManager:show(edit_menu)
    end

    showEditMenu()
end

-- ---------------------------------------------------------------------------
-- Codex browser
-- ---------------------------------------------------------------------------

local TYPE_FILTER_CYCLE  = { "all", "place", "faction", "concept", "object", "species" }
local TYPE_FILTER_LABELS = { all = "All types", place = "Places", faction = "Factions", concept = "Concepts", object = "Objects", species = "Species" }

function UICodex.showBrowser(plugin, type_filter)
    type_filter = type_filter or "all"

    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end

    local entries = plugin.db_codex:load(book_id)
    if #entries == 0 then
        plugin:showMsg('No codex entries yet.\nLong-press a word and tap "Track in Codex".')
        return
    end

    local browser_menu

    -- Filter by type
    local filtered = {}
    for _, e in ipairs(entries) do
        if type_filter == "all" or (e.type or "unknown") == type_filter then
            table.insert(filtered, e)
        end
    end

    local sorted = {}
    for _, e in ipairs(filtered) do table.insert(sorted, e) end
    table.sort(sorted, function(a, b)
        local ta = TYPE_ORDER[a.type or "unknown"] or 6
        local tb = TYPE_ORDER[b.type or "unknown"] or 6
        if ta ~= tb then return ta < tb end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    local function refresh_browser()
        UIManager:close(browser_menu)
        UICodex.showBrowser(plugin, type_filter)
    end

    -- Spoiler protection: mask entries whose first_seen_page is ahead of current page
    if G_reader_settings:readSetting("kocharacters_spoiler_protection") then
        local cur_page = plugin:getCurrentPage() or 0
        local masked = {}
        for _, e in ipairs(sorted) do
            if not e.unlocked and e.first_seen_page and e.first_seen_page > cur_page then
                table.insert(masked, { name = "[SPOILER] page " .. e.first_seen_page, _spoiler = true, _real_name = e.name })
            else
                table.insert(masked, e)
            end
        end
        sorted = masked
    end

    -- Find next filter in cycle
    local next_filter = "all"
    for i, f in ipairs(TYPE_FILTER_CYCLE) do
        if f == type_filter then
            next_filter = TYPE_FILTER_CYCLE[i % #TYPE_FILTER_CYCLE + 1]
            break
        end
    end
    local filter_label = "[ Filter: " .. (TYPE_FILTER_LABELS[type_filter] or type_filter) .. " ]"

    local items = {}
    table.insert(items, {
        text     = filter_label,
        callback = function()
            UIManager:close(browser_menu)
            UICodex.showBrowser(plugin, next_filter)
        end,
    })

    for _, e in ipairs(sorted) do
        local entry      = e
        local type_badge = (not e._spoiler and e.type and e.type ~= "" and e.type ~= "unknown")
            and (" [" .. e.type .. "]") or ""
        if e._spoiler then
            local real_name = e._real_name
            table.insert(items, {
                text     = e.name,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Unlock this codex entry and reveal its details?",
                        ok_text     = "Unlock",
                        ok_callback = function()
                            local all = plugin.db_codex:load(book_id)
                            for _, en in ipairs(all) do
                                if en.name == real_name then
                                    en.unlocked = true
                                    plugin.db_codex:updateEntry(book_id, real_name, en)
                                    break
                                end
                            end
                            refresh_browser()
                        end,
                    })
                end,
            })
        else
            table.insert(items, {
                text     = (e.name or "Unknown") .. type_badge,
                callback = function()
                    if not entry.unlocked then
                        entry.unlocked = true
                        plugin.db_codex:updateEntry(book_id, entry.name, entry)
                    end
                    UICodex.showEntryViewer(plugin, book_id, entry, refresh_browser)
                end,
            })
        end
    end

    local count       = #filtered
    local count_total = #entries
    local count_str   = type_filter == "all"
        and (count .. " codex entr" .. (count == 1 and "y" or "ies"))
        or  (count .. "/" .. count_total .. " codex entr" .. (count == 1 and "y" or "ies"))
    browser_menu = Menu:new{
        title       = count_str .. " \u{2014} " .. plugin:getBookTitle(),
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = plugin.ui,
    }
    UIManager:show(browser_menu)
end

-- ---------------------------------------------------------------------------
-- Cleanup a single codex entry
-- ---------------------------------------------------------------------------

function UICodex.onCleanupEntry(plugin, book_id, entry, refresh_browser_fn)
    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local name = entry.name or "Unknown"
    local msg = InfoMessage:new{ text = 'Cleaning up "' .. name .. '"...' }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local cleaned, err, usage
    local ok, call_err = pcall(function()
        cleaned, err, usage = client:cleanCodexEntries({ entry }, plugin:getCodexCleanupPrompt())
    end)
    UIManager:close(msg)

    if not ok then
        plugin:showMsg("Plugin error:\n" .. tostring(call_err), 8)
        return
    end
    if err then
        plugin:showMsg("Gemini error:\n" .. tostring(err), 8)
        return
    end

    if cleaned and type(cleaned) == "table" and cleaned[1] then
        plugin:recordUsage(usage)
        local cc = cleaned[1]
        local all_entries = plugin.db_codex:load(book_id)
        for _, orig in ipairs(all_entries) do
            if orig.name == name then
                if cc.description       ~= nil then orig.description       = cc.description       end
                if cc.significance      ~= nil then orig.significance      = cc.significance      end
                if type(cc.known_connections) == "table" then orig.known_connections = cc.known_connections end
                if type(cc.aliases)      == "table" then orig.aliases      = cc.aliases           end
                break
            end
        end
        plugin.db_codex:save(book_id, all_entries)
        plugin.db_codex:normalizeConnections(book_id, plugin.db:load(book_id))
    end

    plugin:showMsg('"' .. name .. '" cleaned up.', 3)
    local fresh = plugin.db_codex:findByName(book_id, name)
    UICodex.showEntryViewer(plugin, book_id, fresh or entry, refresh_browser_fn)
end

-- ---------------------------------------------------------------------------
-- Cleanup all entries
-- ---------------------------------------------------------------------------

function UICodex.onCleanupAllEntries(plugin)
    local book_id = plugin:getBookID()
    if not book_id then return end
    local entries = plugin.db_codex:load(book_id)
    if #entries == 0 then
        plugin:showMsg("No codex entries to clean up.", 3)
        return
    end

    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local BATCH_SIZE = 5
    local client     = GeminiClient:new(api_key)
    local total      = #entries
    local i          = 1
    local progress_msg

    local function step()
        if i > total then
            if progress_msg then UIManager:close(progress_msg); progress_msg = nil end
            plugin:appendActivityLog(book_id, "Codex cleanup: " .. total .. " entr" .. (total == 1 and "y" or "ies") .. " cleaned")
            plugin:showMsg("Codex cleanup complete.", 4)
            return
        end

        local batch = {}
        for j = i, math.min(i + BATCH_SIZE - 1, total) do
            table.insert(batch, entries[j])
        end
        local batch_end = math.min(i + BATCH_SIZE - 1, total)

        if progress_msg then UIManager:close(progress_msg) end
        progress_msg = InfoMessage:new{
            text = "Cleaning codex entries " .. i .. "–" .. batch_end .. " of " .. total .. "..."
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        local cleaned, err, usage
        local ok, call_err = pcall(function()
            cleaned, err, usage = client:cleanCodexEntries(batch, plugin:getCodexCleanupPrompt())
        end)
        UIManager:close(progress_msg); progress_msg = nil
        if ok and not err then plugin:recordUsage(usage) end

        if not ok then
            plugin:showMsg("Plugin error:\n" .. tostring(call_err), 8)
            return
        end
        if err then
            plugin:showMsg("Gemini error:\n" .. tostring(err), 8)
            return
        end

        if cleaned and type(cleaned) == "table" then
            local all_entries = plugin.db_codex:load(book_id)
            local changed     = false
            for _, cc in ipairs(cleaned) do
                if cc.name then
                    for _, orig in ipairs(all_entries) do
                        if orig.name == cc.name then
                            if cc.description       ~= nil then orig.description       = cc.description       end
                            if cc.significance      ~= nil then orig.significance      = cc.significance      end
                            if type(cc.known_connections) == "table" then orig.known_connections = cc.known_connections end
                            if type(cc.aliases)      == "table" then orig.aliases      = cc.aliases           end
                            changed = true; break
                        end
                    end
                end
            end
            if changed then
                plugin.db_codex:save(book_id, all_entries)
                plugin.db_codex:normalizeConnections(book_id, plugin.db:load(book_id))
            end
        end

        i = i + BATCH_SIZE
        if i <= total then
            UIManager:scheduleIn(3, step)
        else
            step()
        end
    end

    UIManager:show(ConfirmBox:new{
        text        = "Clean up all " .. total .. " codex entr" .. (total == 1 and "y" or "ies") .. "?\nThis will deduplicate and tidy text fields via Gemini.",
        ok_text     = "Clean up",
        ok_callback = function() step() end,
    })
end

return UICodex
