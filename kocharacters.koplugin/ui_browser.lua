-- ui_browser.lua
-- KoCharacters: character browser, viewer, editor, conflict resolution, cleanup, merge detection.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer  = require("ui/widget/textviewer")
local ConfirmBox  = require("ui/widget/confirmbox")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen
local logger      = require("logger")
local _           = require("gettext")

local GeminiClient = require("gemini_client")
local CharUtils    = require("char_utils")
local EpubReader   = require("epub_reader")
local Portrait     = require("portrait")

local UIBrowser = {}

-- ---------------------------------------------------------------------------
-- Duplicate detection helpers (also called from extraction.lua via DI)
-- ---------------------------------------------------------------------------

function UIBrowser.checkAndWarnDuplicates(plugin, book_id, on_continue)
    local characters = plugin.db:load(book_id)
    if #characters < 2 then on_continue(); return end
    local dup_pairs = CharUtils.findDuplicatePairs(characters)
    if #dup_pairs == 0 then on_continue(); return end

    local function processPairs(remaining)
        if #remaining == 0 then on_continue(); return end

        local p    = remaining[1]
        local rest = { table.unpack(remaining, 2) }
        local a, b = p[1], p[2]

        local viewer
        viewer = TextViewer:new{
            title  = "Possible duplicate " .. (#dup_pairs - #remaining + 1) .. "/" .. #dup_pairs,
            text   = '"' .. a .. '" and "' .. b .. '" look like the same character.\n\nMerge them?',
            width  = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.6),
            buttons_table = {{
                {
                    text     = 'Merge into "' .. b .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        plugin.db:mergeCharacters(book_id, a, b)
                        processPairs(rest)
                    end,
                },
                {
                    text     = 'Merge into "' .. a .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        plugin.db:mergeCharacters(book_id, b, a)
                        processPairs(rest)
                    end,
                },
                {
                    text     = "Skip",
                    callback = function()
                        UIManager:close(viewer)
                        processPairs(rest)
                    end,
                },
            }},
        }
        UIManager:show(viewer)
    end

    processPairs(dup_pairs)
end

function UIBrowser.handleIncomingConflicts(plugin, book_id, new_chars, on_done, page_num, skip_cleanup)
    new_chars = CharUtils.deduplicateIncoming(new_chars)
    local existing  = plugin.db:load(book_id)
    local conflicts = CharUtils.findIncomingConflicts(existing, new_chars)
    if #conflicts == 0 then on_done(new_chars); return end

    -- Auto-accept mode: enrich all conflicts silently, show a toast summary
    if G_reader_settings:readSetting("kocharacters_auto_enrich") then
        local enriched_names = {}
        local conflict_set   = {}
        for _, conflict in ipairs(conflicts) do
            local new_c = conflict.new_char
            local ex_c  = conflict.existing_char
            plugin.db:enrichCharacter(book_id, ex_c.name, new_c, page_num)
            table.insert(enriched_names, ex_c.name)
            conflict_set[(new_c.name or ""):lower()] = true
        end
        local resolved = {}
        for _, c in ipairs(new_chars) do
            if not conflict_set[(c.name or ""):lower()] then
                table.insert(resolved, c)
            end
        end
        if #enriched_names > 0 then
            if skip_cleanup then plugin.db:markPendingCleanup(book_id) end
            plugin:showMsg("Enriched: " .. table.concat(enriched_names, ", "), 3)
        end
        on_done(resolved)
        return
    end

    local to_enrich = {}   -- new_char_name_lower -> existing_char_name

    local function finalize(resolved)
        local enriched_names = {}
        for _, ex_name in pairs(to_enrich) do enriched_names[ex_name] = true end

        local enriched_chars = {}
        for _, c in ipairs(plugin.db:load(book_id)) do
            if enriched_names[c.name] then table.insert(enriched_chars, c) end
        end

        if #enriched_chars == 0 then
            on_done(resolved)
            return
        end

        if skip_cleanup then
            plugin.db:markPendingCleanup(book_id)
            on_done(resolved)
            return
        end

        local enriched_names_list = {}
        for _, ec in ipairs(enriched_chars) do table.insert(enriched_names_list, ec.name or "?") end
        local working_msg = InfoMessage:new{
            text = "Cleaning up " .. #enriched_chars .. " enriched character(s):\n"
                   .. table.concat(enriched_names_list, ", ")
        }
        UIManager:show(working_msg)
        UIManager:forceRePaint()

        local client = GeminiClient:new(plugin:getApiKey())
        local cleaned, err, usage1
        local ok, call_err = pcall(function()
            cleaned, err, usage1 = client:cleanCharacters(enriched_chars)
        end)
        UIManager:close(working_msg)
        if ok and not err then plugin:recordUsage(usage1) end

        if ok and not err and cleaned and type(cleaned) == "table" then
            local all_chars = plugin.db:load(book_id)
            local changed   = false
            for i, cc in ipairs(cleaned) do
                if cc.name then
                    local apply_msg = InfoMessage:new{
                        text = "Applying cleanup " .. i .. "/" .. #cleaned .. ": " .. cc.name .. "..."
                    }
                    UIManager:show(apply_msg)
                    UIManager:forceRePaint()
                    for _, orig in ipairs(all_chars) do
                        if orig.name == cc.name then
                            if cc.physical_description ~= nil then orig.physical_description = cc.physical_description end
                            if cc.personality          ~= nil then orig.personality          = cc.personality          end
                            if cc.role and cc.role ~= ""      then orig.role                 = cc.role                 end
                            if type(cc.relationships) == "table" then orig.relationships     = cc.relationships        end
                            orig.needs_cleanup = nil
                            changed = true
                            break
                        end
                    end
                    UIManager:close(apply_msg)
                end
            end
            if changed then plugin.db:save(book_id, all_chars) end
        else
            logger.warn("KoCharacters: batch cleanup failed: " .. tostring(call_err or err))
        end

        on_done(resolved)
    end

    local function processConflicts(remaining)
        if #remaining == 0 then
            for new_name_low, ex_name in pairs(to_enrich) do
                for _, c in ipairs(new_chars) do
                    if (c.name or ""):lower() == new_name_low then
                        plugin.db:enrichCharacter(book_id, ex_name, c, page_num)
                        break
                    end
                end
            end
            local resolved = {}
            for _, c in ipairs(new_chars) do
                if not to_enrich[(c.name or ""):lower()] then
                    table.insert(resolved, c)
                end
            end
            finalize(resolved)
            return
        end

        local conflict = remaining[1]
        local rest     = { table.unpack(remaining, 2) }
        local new_c    = conflict.new_char
        local ex_c     = conflict.existing_char

        local lines = { 'New:      "' .. new_c.name .. '"', 'Existing: "' .. ex_c.name .. '"', "" }
        if new_c.role and new_c.role ~= ""                                  then table.insert(lines, "New role: "        .. new_c.role)                 end
        if new_c.physical_description and new_c.physical_description ~= ""  then table.insert(lines, "New appearance: " .. new_c.physical_description) end
        if ex_c.role and ex_c.role ~= ""                                    then table.insert(lines, "Existing role: "   .. ex_c.role)                  end

        local viewer
        viewer = TextViewer:new{
            title  = "Match " .. (#conflicts - #remaining + 1) .. " / " .. #conflicts .. ": same person?",
            text   = table.concat(lines, "\n"),
            width  = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.85),
            buttons_table = {{
                {
                    text     = 'Enrich "' .. ex_c.name .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        to_enrich[(new_c.name or ""):lower()] = ex_c.name
                        processConflicts(rest)
                    end,
                },
                {
                    text     = "Add as new",
                    callback = function()
                        UIManager:close(viewer)
                        processConflicts(rest)
                    end,
                },
            }},
        }
        UIManager:show(viewer)
    end

    processConflicts(conflicts)
end

-- ---------------------------------------------------------------------------
-- Edit character
-- ---------------------------------------------------------------------------

function UIBrowser.onEditCharacter(plugin, book_id, char, refresh_browser_fn, show_viewer_fn)
    local lookup_name = char.name

    local function save()
        plugin.db:updateCharacter(book_id, lookup_name, char)
        lookup_name = char.name
    end

    local edit_menu
    local closing_for_save = false
    local function showEditMenu()
        local ok, Menu2 = pcall(require, "ui/widget/menu")
        if not ok or not Menu2 then return end

        local function after_save()
            closing_for_save = true
            UIManager:close(edit_menu)
            closing_for_save = false
            if refresh_browser_fn then refresh_browser_fn() end
            showEditMenu()
        end

        local function editTextField(label, current, multiline, on_save)
            local dialog
            dialog = InputDialog:new{
                title         = "Edit " .. label,
                input         = current or "",
                input_type    = multiline and "text" or "string",
                allow_newline = multiline,
                buttons       = {{
                    { text = "Cancel", callback = function() UIManager:close(dialog) end },
                    {
                        text             = "Save",
                        is_enter_default = not multiline,
                        callback         = function()
                            UIManager:close(dialog)
                            on_save(dialog:getInputText() or "")
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        local items = {
            {
                text     = "Name: " .. (char.name or ""),
                callback = function()
                    editTextField("Name", char.name, false, function(val)
                        if val ~= "" then char.name = val; save(); after_save() end
                    end)
                end,
            },
            {
                text     = "Aliases: " .. table.concat(char.aliases or {}, ", "),
                callback = function()
                    editTextField("Aliases (comma-separated)", table.concat(char.aliases or {}, ", "), false, function(val)
                        local t = {}
                        for a in val:gmatch("[^,]+") do
                            local s = a:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        char.aliases = t; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Role: " .. (char.role or "unknown"),
                callback = function()
                    local role_menu
                    local role_items = {}
                    for _, r in ipairs({"protagonist","antagonist","supporting","unknown"}) do
                        local role = r
                        table.insert(role_items, {
                            text     = role,
                            callback = function()
                                char.role = role; save()
                                UIManager:close(role_menu)
                                after_save()
                            end,
                        })
                    end
                    role_menu = Menu2:new{
                        title       = "Select Role",
                        item_table  = role_items,
                        width       = Screen:getWidth(),
                        show_parent = plugin.ui,
                    }
                    UIManager:show(role_menu)
                end,
            },
            {
                text     = "Occupation",
                callback = function()
                    editTextField("Occupation", char.occupation, false, function(val)
                        char.occupation = val ~= "" and val or nil; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Appearance",
                callback = function()
                    editTextField("Appearance", char.physical_description, true, function(val)
                        char.physical_description = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Personality",
                callback = function()
                    editTextField("Personality", char.personality, true, function(val)
                        char.personality = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Relationships (one per line)",
                callback = function()
                    editTextField("Relationships", table.concat(char.relationships or {}, "\n"), true, function(val)
                        local t = {}
                        for r in val:gmatch("[^\n]+") do
                            local s = r:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        char.relationships = t; save(); after_save()
                    end)
                end,
            },
            {
                text     = "First appearance quote",
                callback = function()
                    editTextField("First Appearance Quote", char.first_appearance_quote, true, function(val)
                        char.first_appearance_quote = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Notes" .. ((char.user_notes and char.user_notes ~= "") and " ✎" or ""),
                callback = function()
                    editTextField("Notes", char.user_notes, true, function(val)
                        char.user_notes = val ~= "" and val or nil; save(); after_save()
                    end)
                end,
            },
        }

        edit_menu = Menu2:new{
            title       = "Edit: " .. (char.name or ""),
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
-- Character viewer
-- ---------------------------------------------------------------------------

function UIBrowser.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
    local name = char.name or "Unknown"

    local function make_buttons(close_fn)
        local others_for_merge = {}
        for _, other in ipairs(plugin.db:load(book_id)) do
            if other.name ~= name then
                local other_name = other.name
                table.insert(others_for_merge, {
                    text     = other_name,
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text        = 'Merge "' .. name .. '" into "' .. other_name .. '"?\n'
                                          .. '"' .. name .. '" will be removed.',
                            ok_text     = "Merge",
                            ok_callback = function()
                                plugin.db:mergeCharacters(book_id, name, other_name)
                                plugin:showMsg('"' .. name .. '" merged into "' .. other_name .. '".', 3)
                            end,
                        })
                    end,
                })
            end
        end
        local function do_merge()
            close_fn()
            local ok_m, Menu2 = pcall(require, "ui/widget/menu")
            if ok_m and Menu2 then
                UIManager:show(Menu2:new{
                    title       = 'Merge "' .. name .. '" into...',
                    item_table  = others_for_merge,
                    width       = Screen:getWidth(),
                    show_parent = plugin.ui,
                })
            end
        end
        local function do_delete()
            close_fn()
            UIManager:show(ConfirmBox:new{
                text        = 'Delete "' .. name .. '" from the character list?',
                ok_text     = "Delete",
                ok_callback = function()
                    plugin.db:deleteCharacter(book_id, name)
                    plugin:showMsg(name .. " deleted.", 2)
                end,
            })
        end
        return {
            {
                { text = "Re-analyze", callback = function() close_fn(); UIBrowser.onReanalyzeCharacter(plugin, book_id, char) end },
                { text = "Clean up",   callback = function() close_fn(); UIBrowser.onCleanCharacter(plugin, book_id, char.name) end },
                { text = "Edit",       callback = function()
                    close_fn()
                    local function show_viewer_fn()
                        UIBrowser.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
                    end
                    UIBrowser.onEditCharacter(plugin, book_id, char, refresh_browser_fn, show_viewer_fn)
                end },
            },
            {
                { text = "Gen. portrait", callback = function()
                    close_fn()
                    Portrait.onGenerate(plugin, book_id, char)
                    UIBrowser.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
                end },
                { text = "Merge into...", callback = do_merge },
                { text = "Delete",        callback = do_delete },
            },
        }
    end

    -- Text viewer fallback when HTML mode is disabled
    if not G_reader_settings:readSetting("kocharacters_html_viewer") then
        local viewer
        viewer = TextViewer:new{
            title  = char.name or "Character",
            text   = CharUtils.formatText(char),
            width  = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.85),
            buttons_table = make_buttons(function()
                UIManager:close(viewer)
                if refresh_browser_fn then refresh_browser_fn() end
            end),
        }
        UIManager:show(viewer)
        return
    end

    -- HTML viewer using ScrollHtmlWidget
    do
        local ok_s, ScrollHtmlWidget = pcall(require, "ui/widget/scrollhtmlwidget")
        local ok_f, FrameContainer   = pcall(require, "ui/widget/container/framecontainer")
        local ok_c, CenterContainer  = pcall(require, "ui/widget/container/centercontainer")
        local ok_v, VerticalGroup    = pcall(require, "ui/widget/verticalgroup")
        local ok_b, ButtonTable      = pcall(require, "ui/widget/buttontable")
        local Size                   = require("ui/size")
        local Blitbuffer             = require("ffi/blitbuffer")
        local Geom                   = require("ui/geometry")

        if ok_s and ok_f and ok_c and ok_v and ok_b then
            local DataStorage   = require("datastorage")
            local portraits_dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"

            local portrait_filename = nil
            local portrait_path = Portrait.path(book_id, char)
            local pf = io.open(portrait_path, "rb")
            if pf then pf:close(); portrait_filename = portrait_path:match("([^/]+)$") end

            local w = Screen:getWidth()  - 8
            local h = Screen:getHeight() - 8
            local border   = 2
            local inner_w  = w - 2*border

            local html_css, html_body = CharUtils.formatHTML(char, portrait_filename, inner_w)

            local dialog_ref = {}
            local function close_fn()
                if dialog_ref[1] then UIManager:close(dialog_ref[1]) end
                local Device = require("device")
                UIManager:scheduleIn(0.1, function() Device.screen:refreshFull(0, 0, Device.screen:getWidth(), Device.screen:getHeight()) end)
            end

            local rows = make_buttons(close_fn)
            table.insert(rows[#rows], { text = "Close", callback = function()
                close_fn()
                if refresh_browser_fn then refresh_browser_fn() end
            end })

            local btable   = ButtonTable:new{ width = inner_w, buttons = rows }
            local btable_h = btable:getSize().h
            local inner_h  = h - 2*border

            local function charLinkCallback(link)
                local link_url = type(link) == "table" and (link.uri or "") or tostring(link)
                if link_url:sub(1, 5) ~= "char:" then return end
                local link_name = (link_url:sub(6):match("^%s*(.-)%s*$") or ""):lower()
                if link_name == "" then return end
                local found
                for _, c in ipairs(plugin.db:load(book_id)) do
                    local cname = (c.name or ""):lower()
                    if cname:find(link_name, 1, true) or link_name:find(cname, 1, true) then
                        found = c; break
                    end
                    for _, alias in ipairs(c.aliases or {}) do
                        local al = alias:lower()
                        if al:find(link_name, 1, true) or link_name:find(al, 1, true) then
                            found = c; break
                        end
                    end
                    if found then break end
                end
                if found then
                    close_fn()
                    UIManager:scheduleIn(0.15, function()
                        UIBrowser.showCharacterViewer(plugin, book_id, found, sort_mode, query, refresh_browser_fn)
                    end)
                end
            end

            local html_widget = ScrollHtmlWidget:new{
                html_body               = html_body,
                css                     = html_css,
                html_resource_directory = portraits_dir,
                width                   = inner_w,
                height                  = inner_h - btable_h,
                html_link_tapped_callback = charLinkCallback,
            }

            local frame = FrameContainer:new{
                radius     = Size.radius.window,
                padding    = 0,
                bordersize = border,
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new{
                    align = "left",
                    html_widget,
                    btable,
                },
            }

            local center = CenterContainer:new{
                dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
                frame,
            }

            html_widget.dialog = center
            dialog_ref[1]      = center
            UIManager:show(center)
            UIManager:scheduleIn(0.3, function()
                local Device = require("device")
                Device.screen:refreshFull(0, 0, Device.screen:getWidth(), Device.screen:getHeight())
            end)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Character browser
-- ---------------------------------------------------------------------------

function UIBrowser.onViewCharacters(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end
    if #plugin.db:load(book_id) == 0 then
        plugin:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end
    UIBrowser.showCharacterBrowser(plugin, book_id, "default", "")
end

function UIBrowser.showCharacterBrowser(plugin, book_id, sort_mode, query)
    local ok, Menu2 = pcall(require, "ui/widget/menu")
    if not ok or not Menu2 then return end

    local all_chars = plugin.db:load(book_id)

    -- Filter
    local q = query:lower()
    local filtered = {}
    for _, c in ipairs(all_chars) do
        if q == "" then
            table.insert(filtered, c)
        else
            local hay = table.concat({
                c.name or "", c.role or "",
                c.physical_description or "", c.personality or "",
                c.user_notes or "",
                table.concat(c.aliases or {}, " "),
                table.concat(c.relationships or {}, " "),
            }, " "):lower()
            if hay:find(q, 1, true) then table.insert(filtered, c) end
        end
    end

    -- Spoiler protection: mask characters whose first_seen_page is ahead of current page
    if G_reader_settings:readSetting("kocharacters_spoiler_protection") then
        local cur_page = plugin:getCurrentPage() or 0
        local masked = {}
        for _, c in ipairs(filtered) do
            if not c.unlocked and c.first_seen_page and c.first_seen_page > cur_page then
                table.insert(masked, { name = "Unknown character (page " .. c.first_seen_page .. ")", _spoiler = true, _real_name = c.name })
            else
                table.insert(masked, c)
            end
        end
        filtered = masked
    end

    -- Sort
    local sorted = {}
    for _, c in ipairs(filtered) do table.insert(sorted, c) end
    if sort_mode == "name" then
        table.sort(sorted, function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    elseif sort_mode == "role" then
        local order = { protagonist = 1, antagonist = 2, supporting = 3, unknown = 4 }
        table.sort(sorted, function(a, b)
            local ra = order[a.role or "unknown"] or 4
            local rb = order[b.role or "unknown"] or 4
            if ra ~= rb then return ra < rb end
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    end

    -- Control items (search + sort) pinned at the top
    local items = {}
    local sort_labels = { default = "Added order", name = "Name A→Z", role = "Role" }
    local sort_cycle  = { default = "name", name = "role", role = "default" }

    local search_text = query ~= ""
        and ("Search: \"" .. query .. "\" (" .. #filtered .. "/" .. #all_chars .. ")")
        or  "Search..."
    table.insert(items, {
        text     = "[ " .. search_text .. " ]",
        callback = function()
            local dialog
            dialog = InputDialog:new{
                title      = "Search characters",
                input      = query,
                input_type = "string",
                buttons    = {{
                    {
                        text     = "Clear",
                        callback = function()
                            UIManager:close(dialog)
                            UIBrowser.showCharacterBrowser(plugin, book_id, sort_mode, "")
                        end,
                    },
                    {
                        text     = "Cancel",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text             = "Search",
                        is_enter_default = true,
                        callback         = function()
                            local q2 = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                            UIManager:close(dialog)
                            UIBrowser.showCharacterBrowser(plugin, book_id, sort_mode, q2)
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    })

    table.insert(items, {
        text     = "[ Sort: " .. (sort_labels[sort_mode] or sort_mode) .. " — tap to change ]",
        callback = function()
            UIBrowser.showCharacterBrowser(plugin, book_id, sort_cycle[sort_mode] or "default", query)
        end,
    })

    -- Forward-declare browser_menu and refresh_browser BEFORE the loop so the
    -- callbacks inside the loop capture them as upvalues (not nil globals).
    local browser_menu
    local function refresh_browser()
        UIManager:close(browser_menu)
        UIBrowser.showCharacterBrowser(plugin, book_id, sort_mode, query)
    end

    -- Character items
    for _, c in ipairs(sorted) do
        local name    = c.name or "Unknown"
        local role    = (c.role and c.role ~= "" and c.role ~= "unknown")
                        and (" [" .. c.role .. "]") or ""
        local cleanup = c.needs_cleanup and " *" or ""
        local char = c
        if c._spoiler then
            local real_name = c._real_name
            table.insert(items, {
                text = name,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Unlock this character and reveal their details?",
                        ok_text     = "Unlock",
                        ok_callback = function()
                            local chars = plugin.db:load(book_id)
                            for _, ch in ipairs(chars) do
                                if ch.name == real_name then
                                    ch.unlocked = true
                                    plugin.db:updateCharacter(book_id, real_name, ch)
                                    break
                                end
                            end
                            UIBrowser.showCharacterBrowser(plugin, book_id, sort_mode, query)
                        end,
                    })
                end,
            })
        else
        table.insert(items, {
            text     = name .. role .. cleanup,
            callback = function()
                if not char.unlocked then
                    char.unlocked = true
                    plugin.db:updateCharacter(book_id, char.name, char)
                end
                UIBrowser.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser)
            end,
        })
        end  -- else (not spoiler)
    end

    local count_str = query ~= "" and (#filtered .. "/" .. #all_chars) or tostring(#all_chars)
    browser_menu = Menu2:new{
        title       = count_str .. " character(s) — " .. plugin:getBookTitle(),
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = plugin.ui,
    }
    UIManager:show(browser_menu)
end

-- ---------------------------------------------------------------------------
-- Cleanup all characters
-- ---------------------------------------------------------------------------

function UIBrowser.onCleanupAllCharacters(plugin)
    local book_id = plugin:getBookID()
    if not book_id then return end
    local characters = plugin.db:load(book_id)
    if #characters == 0 then
        plugin:showMsg("No characters to clean up.", 3)
        return
    end

    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local flagged = {}
    for _, c in ipairs(characters) do
        if c.needs_cleanup then table.insert(flagged, c) end
    end
    local n_flagged = #flagged
    local n_all     = #characters

    local BATCH_SIZE = G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5

    local function runCleanup(chars_to_clean)
        local client    = GeminiClient:new(api_key)
        local all_chars = plugin.db:load(book_id)
        local changed   = false
        local total     = #chars_to_clean

        local i = 1
        while i <= total do
            local batch = {}
            for j = i, math.min(i + BATCH_SIZE - 1, total) do
                table.insert(batch, chars_to_clean[j])
            end

            local batch_end = math.min(i + BATCH_SIZE - 1, total)
            local working_msg = InfoMessage:new{
                text = "Cleaning up characters " .. i .. "–" .. batch_end .. " of " .. total .. "..."
            }
            UIManager:show(working_msg)
            UIManager:forceRePaint()

            local cleaned, err, usage
            local ok, call_err = pcall(function()
                cleaned, err, usage = client:cleanCharacters(batch)
            end)
            UIManager:close(working_msg)
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
                for idx, cc in ipairs(cleaned) do
                    if cc.name then
                        local apply_msg = InfoMessage:new{
                            text = "Applying cleanup " .. (i + idx - 1) .. "/" .. total .. ": " .. cc.name .. "..."
                        }
                        UIManager:show(apply_msg)
                        UIManager:forceRePaint()
                        for _, orig in ipairs(all_chars) do
                            if orig.name == cc.name then
                                if cc.physical_description ~= nil    then orig.physical_description = cc.physical_description end
                                if cc.personality          ~= nil    then orig.personality          = cc.personality          end
                                if cc.role and cc.role ~= ""         then orig.role                 = cc.role                 end
                                if type(cc.relationships) == "table" then orig.relationships        = cc.relationships        end
                                orig.needs_cleanup = nil
                                changed = true; break
                            end
                        end
                        UIManager:close(apply_msg)
                    end
                end
            end

            i = i + BATCH_SIZE
            if i <= total then
                os.execute("sleep 3")
            end
        end

        if changed then plugin.db:save(book_id, all_chars) end
        plugin.db:clearPendingCleanup(book_id)
        plugin:appendActivityLog(book_id, "Cleanup all: " .. total .. " character(s) cleaned")
        if G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup") then
            UIBrowser.onMergeDetection(plugin)
        else
            plugin:showMsg("Cleanup complete.", 4)
        end
    end

    local dialog
    local flagged_label = n_flagged > 0
        and ("Flagged only (" .. n_flagged .. ")")
        or  "Flagged only (none)"
    dialog = TextViewer:new{
        title  = "Cleanup scope",
        text   = n_flagged .. " of " .. n_all .. " character(s) flagged for cleanup.",
        width  = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.4),
        buttons_table = {{
            {
                text     = flagged_label,
                enabled  = n_flagged > 0,
                callback = function()
                    UIManager:close(dialog)
                    runCleanup(flagged)
                end,
            },
            {
                text     = "All (" .. n_all .. ")",
                callback = function()
                    UIManager:close(dialog)
                    runCleanup(characters)
                end,
            },
            {
                text     = "Cancel",
                callback = function() UIManager:close(dialog) end,
            },
        }},
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Merge detection (AI-powered duplicate detection)
-- ---------------------------------------------------------------------------

function UIBrowser.onMergeDetection(plugin)
    local book_id = plugin:getBookID()
    if not book_id then return end

    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local all_chars = plugin.db:load(book_id)
    if #all_chars < 2 then
        plugin:showMsg("Not enough characters to merge.", 3)
        return
    end

    local detect_msg = InfoMessage:new{ text = "Checking for duplicate characters..." }
    UIManager:show(detect_msg)
    UIManager:forceRePaint()

    local slim_chars = {}
    for _, c in ipairs(all_chars) do
        table.insert(slim_chars, {
            name                 = c.name,
            aliases              = c.aliases,
            physical_description = c.physical_description,
            personality          = c.personality,
            role                 = c.role,
            occupation           = c.occupation,
            relationships        = c.relationships,
        })
    end

    local client = GeminiClient:new(api_key)
    local groups, derr, dusage
    local dok, dcall_err = pcall(function()
        groups, derr, dusage = client:detectMergeGroups(slim_chars, plugin:getMergeDetectionPrompt())
    end)
    UIManager:close(detect_msg)
    if dok and not derr then plugin:recordUsage(dusage) end

    if not dok then
        plugin:showMsg("Plugin error:\n" .. tostring(dcall_err), 8)
        return
    end
    if derr then
        plugin:showMsg("Gemini error:\n" .. tostring(derr), 8)
        return
    end
    if not groups or #groups == 0 then
        plugin:showMsg("No duplicate characters detected.", 4)
        return
    end

    local valid_groups = {}
    local name_set = {}
    for _, c in ipairs(all_chars) do name_set[c.name] = true end
    for _, g in ipairs(groups) do
        if g.keep and name_set[g.keep] and type(g.absorb) == "table" then
            local valid = true
            for _, a in ipairs(g.absorb) do
                if not name_set[a] then valid = false; break end
            end
            if valid and #g.absorb > 0 then
                table.insert(valid_groups, g)
            end
        end
    end

    if #valid_groups == 0 then
        plugin:showMsg("No duplicate characters detected.", 4)
        return
    end

    local group_idx   = 1
    local merged_count = 0

    local function applyNext()
        if group_idx > #valid_groups then
            if merged_count > 0 then
                plugin:appendActivityLog(book_id, "Merged " .. merged_count .. " duplicate(s)")
            end
            local msg = merged_count > 0
                and (merged_count .. " character(s) merged.")
                or  "No characters merged."
            plugin:showMsg(msg, 4)
            return
        end

        local g = valid_groups[group_idx]
        group_idx = group_idx + 1

        local absorb_names = table.concat(g.absorb, ", ")
        local reason = g.reason or "similar profiles"
        local confirm_text = string.format(
            'Merge %d of %d\n\n"%s" and "%s" appear to be the same character.\n\nReason: %s\n\nMerge into "%s"?',
            group_idx - 1, #valid_groups,
            g.keep, absorb_names,
            reason, g.keep
        )

        UIManager:show(ConfirmBox:new{
            text        = confirm_text,
            ok_text     = "Merge",
            cancel_text = "Skip",
            ok_callback = function()
                for _, src in ipairs(g.absorb) do
                    plugin.db:mergeCharacters(book_id, src, g.keep)
                    merged_count = merged_count + 1
                end
                applyNext()
            end,
            cancel_callback = function()
                applyNext()
            end,
        })
    end

    applyNext()
end

-- ---------------------------------------------------------------------------
-- Re-analyze / clean individual characters
-- ---------------------------------------------------------------------------

function UIBrowser.onReanalyzeCharacter(plugin, book_id, char)
    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local page_text, perr = EpubReader.getPageText(plugin.ui.document, plugin:getCurrentPage())
    if not page_text then
        plugin:showMsg("Could not get page text:\n" .. tostring(perr))
        return
    end

    local working_msg = InfoMessage:new{ text = 'Re-analyzing "' .. char.name .. '"...' }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local characters, api_err, usage
    local ok, call_err = pcall(function()
        characters, api_err, usage = client:reanalyzeCharacter(
            page_text, char, plugin:getReanalyzePrompt())
    end)

    UIManager:close(working_msg)
    if ok and not api_err then plugin:recordUsage(usage) end

    if not ok then
        plugin:showMsg("Plugin error:\n" .. tostring(call_err), 8)
        return
    end
    if api_err then
        plugin:showMsg("Gemini error:\n" .. tostring(api_err), 8)
        return
    end
    if not characters or #characters == 0 then
        plugin:showMsg('"' .. char.name .. '" was not found on this page.', 4)
        return
    end

    local reanalyze_page = plugin:getCurrentPage()
    plugin.db:merge(book_id, characters, reanalyze_page)
    plugin:appendActivityLog(book_id, 'Re-analyzed "' .. char.name .. '" (p.' .. (reanalyze_page or "?") .. ")")
    plugin:showMsg('"' .. char.name .. '" updated.', 3)
end

function UIBrowser.onReanalyzeCharacterPicker(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end
    local characters = plugin.db:load(book_id)
    if #characters == 0 then
        plugin:showMsg("No characters saved yet.")
        return
    end

    local items = {}
    for _, c in ipairs(characters) do
        local char = c
        local role = (c.role and c.role ~= "") and (" [" .. c.role .. "]") or ""
        table.insert(items, {
            text     = (c.name or "Unknown") .. role,
            callback = function()
                UIBrowser.onReanalyzeCharacter(plugin, book_id, char)
            end,
        })
    end

    local ok, Menu2 = pcall(require, "ui/widget/menu")
    if ok and Menu2 then
        UIManager:show(Menu2:new{
            title       = "Re-analyze which character?",
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = plugin.ui,
        })
    end
end

function UIBrowser.onCleanCharacter(plugin, book_id, char_name)
    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local characters = plugin.db:load(book_id)
    local char = nil
    for _, c in ipairs(characters) do
        if c.name == char_name then char = c; break end
    end
    if not char then plugin:showMsg("Character not found.", 3); return end

    local working_msg = InfoMessage:new{ text = 'Cleaning up "' .. char_name .. '"...' }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local result, err, usage
    local ok, call_err = pcall(function()
        result, err, usage = client:cleanCharacter(char, plugin:getCleanupPrompt())
    end)

    UIManager:close(working_msg)
    if ok and not err then plugin:recordUsage(usage) end

    if not ok then plugin:showMsg("Error:\n" .. tostring(call_err), 6); return end
    if err    then plugin:showMsg("Gemini error:\n" .. tostring(err), 6); return end

    if result.physical_description then char.physical_description = result.physical_description end
    if result.personality          then char.personality          = result.personality          end
    if result.role and result.role ~= "" then char.role = result.role end
    if result.relationships and type(result.relationships) == "table" then
        char.relationships = result.relationships
    end
    char.needs_cleanup = nil

    plugin.db:updateCharacter(book_id, char_name, char)
    plugin:appendActivityLog(book_id, 'Cleaned up "' .. char_name .. '"')
    plugin:showMsg('"' .. char_name .. '" cleaned up.', 3)
end

-- ---------------------------------------------------------------------------
-- Word-selection character lookup (called from highlight popup)
-- ---------------------------------------------------------------------------

function UIBrowser.onWordCharacterLookup(plugin, word)
    if not word or word == "" then
        plugin:showMsg("No word selected.")
        return
    end

    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end

    local all_chars = plugin.db:load(book_id)
    if #all_chars == 0 then
        plugin:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end

    local stop = { the=1, a=1, an=1, of=1, ["in"]=1, at=1, to=1, ["and"]=1, ["or"]=1, ["for"]=1,
                   with=1, by=1, on=1, from=1, is=1, was=1, he=1, she=1, his=1, her=1 }
    local word_lower = word:lower()
    local tokens = { word_lower }
    for w in word_lower:gmatch("%a+") do
        if #w >= 3 and not stop[w] then
            table.insert(tokens, w)
        end
    end

    local function charMatches(c)
        local name_l = (c.name or ""):lower()
        for _, tok in ipairs(tokens) do
            if name_l:find(tok, 1, true) then return true end
        end
        for _, alias in ipairs(c.aliases or {}) do
            local alias_l = alias:lower()
            for _, tok in ipairs(tokens) do
                if alias_l:find(tok, 1, true) then return true end
            end
        end
        return false
    end

    local matches = {}
    for _, c in ipairs(all_chars) do
        if charMatches(c) then table.insert(matches, c) end
    end

    if #matches == 0 then
        plugin:showMsg('"' .. word .. '" not found in character database.')
        return
    end

    if #matches == 1 then
        UIBrowser.showCharacterViewer(plugin, book_id, matches[1])
        return
    end

    UIBrowser.showCharacterBrowser(plugin, book_id, "default", word)
end

return UIBrowser
