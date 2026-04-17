-- ui_codex.lua
-- KoCharacters: Codex browser, viewer, and editor.

local UIManager  = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu       = require("ui/widget/menu")
local Screen     = require("device").screen
local _          = require("gettext")

local UIShared = require("ui_shared")

local UICodex = {}

local TYPE_ORDER = { place = 1, faction = 2, concept = 3, object = 4, species = 5, unknown = 6 }

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
-- Entry viewer
-- ---------------------------------------------------------------------------

function UICodex.showEntryViewer(plugin, book_id, entry, refresh_browser_fn)
    if not entry then
        plugin:showMsg("Codex entry not found.")
        return
    end

    local name = entry.name or "Unknown"

    local function make_buttons(close_fn)
        return {{
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
        }}
    end

    local viewer
    viewer = TextViewer:new{
        title         = name,
        text          = formatEntryText(entry),
        width         = math.floor(Screen:getWidth() * 0.9),
        height        = math.floor(Screen:getHeight() * 0.85),
        buttons_table = make_buttons(function() UIManager:close(viewer) end),
    }
    UIManager:show(viewer)
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

function UICodex.showBrowser(plugin)
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

    local sorted = {}
    for _, e in ipairs(entries) do table.insert(sorted, e) end
    table.sort(sorted, function(a, b)
        local ta = TYPE_ORDER[a.type or "unknown"] or 6
        local tb = TYPE_ORDER[b.type or "unknown"] or 6
        if ta ~= tb then return ta < tb end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    local function refresh_browser()
        UIManager:close(browser_menu)
        UICodex.showBrowser(plugin)
    end

    local items = {}
    for _, e in ipairs(sorted) do
        local entry      = e
        local type_badge = (e.type and e.type ~= "" and e.type ~= "unknown")
            and (" [" .. e.type .. "]") or ""
        table.insert(items, {
            text     = (e.name or "Unknown") .. type_badge,
            callback = function()
                UICodex.showEntryViewer(plugin, book_id, entry, refresh_browser)
            end,
        })
    end

    local count = #entries
    browser_menu = Menu:new{
        title       = count .. " codex entr" .. (count == 1 and "y" or "ies") .. " \u{2014} " .. plugin:getBookTitle(),
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = plugin.ui,
    }
    UIManager:show(browser_menu)
end

return UICodex
