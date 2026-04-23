-- ui_character.lua
-- KoCharacters: character browser, viewer, editor, conflict resolution, cleanup, merge detection.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer  = require("ui/widget/textviewer")
local ConfirmBox  = require("ui/widget/confirmbox")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen
local logger      = require("logger")
local _           = require("gettext")

local GeminiClient     = require("gemini_client")
local UtilsCharacter   = require("utils_character")
local UIShared         = require("ui_shared")
local EpubReader       = require("epub_reader")
local Portrait         = require("portrait")

local UICharacter = {}

local function toSlimChar(c)
    return {
        name                 = c.name,
        aliases              = c.aliases,
        physical_description = c.physical_description,
        personality          = c.personality,
        role                 = c.role,
        occupation           = c.occupation,
        relationships        = c.relationships,
    }
end

-- ---------------------------------------------------------------------------
-- Duplicate detection helpers (also called from extraction.lua via DI)
-- ---------------------------------------------------------------------------

function UICharacter.checkAndWarnDuplicates(plugin, book_id, on_continue)
    local characters = plugin.db:load(book_id)
    if #characters < 2 then on_continue(); return end
    local dup_pairs = UtilsCharacter.findDuplicatePairs(characters)
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

function UICharacter.handleIncomingConflicts(plugin, book_id, new_chars, on_done, page_num, skip_cleanup)
    new_chars = UtilsCharacter.deduplicateIncoming(new_chars)
    local existing  = plugin.db:load(book_id)
    local conflicts = UtilsCharacter.findIncomingConflicts(existing, new_chars)
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
            cleaned, err, usage1 = client:cleanCharacters(enriched_chars, plugin:getCharactersCleanupPrompt())
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
                        local match = orig.name == cc.name
                        if not match then
                            for _, alias in ipairs(orig.aliases or {}) do
                                if alias == cc.name then match = true; break end
                            end
                        end
                        if match then
                            if cc.name ~= orig.name                  then orig.name              = cc.name              end
                            if type(cc.aliases) == "table"           then orig.aliases            = cc.aliases           end
                            if cc.physical_description ~= nil        then orig.physical_description = cc.physical_description end
                            if cc.personality          ~= nil        then orig.personality        = cc.personality        end
                            if cc.motivation           ~= nil        then orig.motivation         = cc.motivation         end
                            if cc.role and cc.role ~= ""             then orig.role               = cc.role               end
                            if type(cc.relationships)  == "table"    then orig.relationships      = cc.relationships      end
                            if type(cc.identity_tags)  == "table"    then orig.identity_tags      = cc.identity_tags      end
                            if type(cc.defining_moments) == "table"  then orig.defining_moments   = cc.defining_moments   end
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

function UICharacter.onEditCharacter(plugin, book_id, char, refresh_browser_fn, show_viewer_fn)
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

        local editTextField = UIShared.editTextField

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
                text     = "Identity tags: " .. table.concat(char.identity_tags or {}, ", "),
                callback = function()
                    editTextField("Identity tags (comma-separated)", table.concat(char.identity_tags or {}, ", "), false, function(val)
                        local t = {}
                        for a in val:gmatch("[^,]+") do
                            local s = a:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        char.identity_tags = t; save(); after_save()
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
                text     = "Motivation",
                callback = function()
                    editTextField("Motivation", char.motivation, true, function(val)
                        char.motivation = val ~= "" and val or nil; save(); after_save()
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
                text     = "Defining moments (one per line)",
                callback = function()
                    editTextField("Defining Moments", table.concat(char.defining_moments or {}, "\n"), true, function(val)
                        local t = {}
                        for r in val:gmatch("[^\n]+") do
                            local s = r:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        char.defining_moments = t; save(); after_save()
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

function UICharacter.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
    local name = char.name or "Unknown"

    -- Find codex entries that reference this character by name or alias (used by both HTML and buttons)
    local char_names = { [char.name] = true }
    for _, a in ipairs(char.aliases or {}) do
        if a and a ~= "" then char_names[a] = true end
    end
    -- Codex known_connections often use a single name token (e.g. "Helena") for a character
    -- whose full name is "Helena Marino". Add individual tokens (≥4 chars) so partial matches work.
    local initial_names = {}
    for n in pairs(char_names) do initial_names[#initial_names+1] = n end
    for _, n in ipairs(initial_names) do
        for token in n:gmatch("%S+") do
            if #token >= 4 then char_names[token] = true end
        end
    end
    local all_codex = plugin.db_codex:load(book_id)
    local related_codex = {}
    local function nameInText(name, text)
        local nl, tl = name:lower(), text:lower()
        local pos = 1
        while true do
            local si, ei = tl:find(nl, pos, true)
            if not si then return false end
            local before = si > 1    and text:sub(si-1, si-1) or " "
            local after  = ei < #text and text:sub(ei+1, ei+1) or " "
            if not before:match("[%a%d_%-]") and not after:match("[%a%d_%-]") then return true end
            pos = si + 1
        end
    end
    for _, entry in ipairs(all_codex) do
        local matched = false
        for _, conn in ipairs(entry.known_connections or {}) do
            if matched then break end
            for n in pairs(char_names) do
                if nameInText(n, conn) then
                    table.insert(related_codex, entry)
                    matched = true
                    break
                end
            end
        end
    end

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
                { text = "Clean up",   callback = function() close_fn(); UICharacter.onCleanCharacter(plugin, book_id, char.name) end },
                { text = "Edit",       callback = function()
                    close_fn()
                    local function show_viewer_fn()
                        UICharacter.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
                    end
                    UICharacter.onEditCharacter(plugin, book_id, char, refresh_browser_fn, show_viewer_fn)
                end },
            },
            {
                { text = "Gen. portrait", callback = function()
                    close_fn()
                    Portrait.onGenerate(plugin, book_id, char)
                    UICharacter.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
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
            text   = UtilsCharacter.formatText(char),
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

    -- HTML viewer using ScrollHtmlWidget (via UIShared)
    do
        local DataStorage   = require("datastorage")
        local portraits_dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"

        local portrait_filename = nil
        local portrait_path = Portrait.path(book_id, char)
        local pf = io.open(portrait_path, "rb")
        if pf then pf:close(); portrait_filename = portrait_path:match("([^/]+)$") end

        local inner_w = Screen:getWidth() - 8 - 4  -- screen - outer margin - 2*border

        -- Build link specs for inline text linkification (all chars + codex, excluding self)
        local self_names_lower = { [(char.name or ""):lower()] = true }
        for _, a in ipairs(char.aliases or {}) do
            if a ~= "" then self_names_lower[a:lower()] = true end
        end
        local link_specs = {}
        for _, c in ipairs(plugin.db:load(book_id)) do
            local cname = c.name or ""
            if cname ~= "" and not self_names_lower[cname:lower()] then
                link_specs[#link_specs+1] = { name = cname, scheme = "char", target = cname }
                for _, a in ipairs(c.aliases or {}) do
                    if a ~= "" and not self_names_lower[a:lower()] then
                        link_specs[#link_specs+1] = { name = a, scheme = "char", target = cname }
                    end
                end
            end
        end
        for _, e in ipairs(all_codex) do
            local ename = e.name or ""
            if ename ~= "" then
                link_specs[#link_specs+1] = { name = ename, scheme = "codex", target = ename }
                for _, a in ipairs(e.aliases or {}) do
                    if a ~= "" then
                        link_specs[#link_specs+1] = { name = a, scheme = "codex", target = ename }
                    end
                end
            end
        end
        table.sort(link_specs, function(a, b) return #a.name > #b.name end)

        local html_css, html_body = UtilsCharacter.formatHTML(char, portrait_filename, inner_w, {
            link_specs    = link_specs,
            codex_entries = related_codex,
        })

        local viewer_close = {}

        local function back_to_current()
            UICharacter.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser_fn)
        end

        local function charLinkCallback(link)
            local link_url = type(link) == "table" and (link.uri or "") or tostring(link)
            local scheme, target = link_url:match("^([^:]+):(.+)$")
            if not scheme then return end
            target = (target:match("^%s*(.-)%s*$") or "")
            if target == "" then return end
            local target_lower = target:lower()

            if scheme == "char" then
                local found = UtilsCharacter.findByPartialName(plugin.db:load(book_id), target_lower)
                if found then
                    if viewer_close.close then viewer_close.close() end
                    UIManager:scheduleIn(0.15, function()
                        UICharacter.showCharacterViewer(plugin, book_id, found, sort_mode, query, back_to_current)
                    end)
                end
            elseif scheme == "codex" then
                local UICodex = require("ui_codex")
                local found
                for _, e in ipairs(all_codex) do
                    if (e.name or ""):lower() == target_lower then
                        found = e; break
                    end
                end
                if not found then
                    for _, e in ipairs(all_codex) do
                        local ename = (e.name or ""):lower()
                        if ename:find(target_lower, 1, true) or target_lower:find(ename, 1, true) then
                            found = e; break
                        end
                    end
                end
                if found then
                    if viewer_close.close then viewer_close.close() end
                    UIManager:scheduleIn(0.15, function()
                        UICodex.showEntryViewer(plugin, book_id, found, back_to_current)
                    end)
                end
            end
        end

        UIShared.showHtmlViewer{
            inner_w       = inner_w,
            html_body     = html_body,
            html_css      = html_css,
            resource_dir  = portraits_dir,
            close_ref     = viewer_close,
            link_callback = charLinkCallback,
            make_buttons  = function(close_fn)
                local rows = make_buttons(close_fn)
                table.insert(rows[#rows], { text = "Close", callback = function()
                    close_fn()
                    if refresh_browser_fn then refresh_browser_fn() end
                end })
                return rows
            end,
        }
    end
end

-- ---------------------------------------------------------------------------
-- Character browser
-- ---------------------------------------------------------------------------

function UICharacter.onViewCharacters(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end
    if #plugin.db:load(book_id) == 0 then
        plugin:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end
    UICharacter.showCharacterBrowser(plugin, book_id, "default", "")
end

function UICharacter.showCharacterBrowser(plugin, book_id, sort_mode, query)
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

    -- Forward-declare browser_menu here so ALL callbacks (search, sort, characters)
    -- capture the same upvalue slot; it is assigned at the bottom of this function.
    local browser_menu

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
                            UIManager:close(browser_menu)
                            UICharacter.showCharacterBrowser(plugin, book_id, sort_mode, "")
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
                            UIManager:close(browser_menu)
                            UICharacter.showCharacterBrowser(plugin, book_id, sort_mode, q2)
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
            UIManager:close(browser_menu)
            UICharacter.showCharacterBrowser(plugin, book_id, sort_cycle[sort_mode] or "default", query)
        end,
    })

    local function refresh_browser()
        UIManager:close(browser_menu)
        UICharacter.showCharacterBrowser(plugin, book_id, sort_mode, query)
    end

    -- Character items
    for _, c in ipairs(sorted) do
        local name      = c.name or "Unknown"
        local role      = (c.role and c.role ~= "" and c.role ~= "unknown")
                          and (" [" .. c.role .. "]") or ""
        local cleanup   = c.needs_cleanup and " *" or ""
        local last_page = c.last_seen_page or c.source_page
        local page_str  = last_page and (" · p." .. last_page) or ""
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
                            UICharacter.showCharacterBrowser(plugin, book_id, sort_mode, query)
                        end,
                    })
                end,
            })
        else
        table.insert(items, {
            text     = name .. role .. page_str .. cleanup,
            callback = function()
                if not char.unlocked then
                    char.unlocked = true
                    plugin.db:updateCharacter(book_id, char.name, char)
                end
                UICharacter.showCharacterViewer(plugin, book_id, char, sort_mode, query, refresh_browser)
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

function UICharacter.onCleanupAllCharacters(plugin)
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

            local cleaned = UIShared.callApi(plugin, function()
                return client:cleanCharacters(batch, plugin:getCharactersCleanupPrompt())
            end, working_msg)
            if not cleaned then return end

            if cleaned and type(cleaned) == "table" then
                for idx, cc in ipairs(cleaned) do
                    if cc.name then
                        local apply_msg = InfoMessage:new{
                            text = "Applying cleanup " .. (i + idx - 1) .. "/" .. total .. ": " .. cc.name .. "..."
                        }
                        UIManager:show(apply_msg)
                        UIManager:forceRePaint()
                        for _, orig in ipairs(all_chars) do
                            -- Match by name, or by alias (handles name promotion cases)
                            local match = orig.name == cc.name
                            if not match then
                                for _, alias in ipairs(orig.aliases or {}) do
                                    if alias == cc.name then match = true; break end
                                end
                            end
                            if match then
                                if cc.name ~= orig.name                  then orig.name              = cc.name              end
                                if type(cc.aliases) == "table"           then orig.aliases            = cc.aliases           end
                                if cc.physical_description ~= nil        then orig.physical_description = cc.physical_description end
                                if cc.personality          ~= nil        then orig.personality        = cc.personality        end
                                if cc.motivation           ~= nil        then orig.motivation         = cc.motivation         end
                                if cc.role and cc.role ~= ""             then orig.role               = cc.role               end
                                if type(cc.relationships)  == "table"    then orig.relationships      = cc.relationships      end
                                if type(cc.identity_tags)  == "table"    then orig.identity_tags      = cc.identity_tags      end
                                if type(cc.defining_moments) == "table"  then orig.defining_moments   = cc.defining_moments   end
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

        local function afterUnnamedCheck()
            if G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup") then
                UICharacter.onMergeDetection(plugin)
            else
                plugin:showMsg("Cleanup complete.", 4)
            end
        end

        UICharacter.onDetectUnnamedMatches(plugin, book_id, afterUnnamedCheck)
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

function UICharacter.onMergeDetection(plugin)
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
    for _, c in ipairs(all_chars) do table.insert(slim_chars, toSlimChar(c)) end

    local client = GeminiClient:new(api_key)
    local groups = UIShared.callApi(plugin, function()
        return client:detectMergeGroups(slim_chars, plugin:getMergeDetectionPrompt())
    end, detect_msg)
    if not groups then return end
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
-- Unnamed character matching (triggered after cleanup)
-- ---------------------------------------------------------------------------

function UICharacter.onDetectUnnamedMatches(plugin, book_id, on_done)
    local api_key = plugin:getApiKey()
    if api_key == "" then
        if on_done then on_done() end
        return
    end

    local all_chars = plugin.db:load(book_id)

    local unnamed, named = {}, {}
    for _, c in ipairs(all_chars) do
        table.insert(c.name:match("^Unnamed") and unnamed or named, toSlimChar(c))
    end

    if #unnamed == 0 then
        if on_done then on_done() end
        return
    end

    local detect_msg = InfoMessage:new{ text = "Checking unnamed characters for matches..." }
    UIManager:show(detect_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local groups, derr, dusage
    local dok, dcall_err = pcall(function()
        groups, derr, dusage = client:detectUnnamedMatches(unnamed, named, plugin:getUnnamedMatchPrompt())
    end)
    UIManager:close(detect_msg)
    if dok and not derr then plugin:recordUsage(dusage) end

    if not dok then
        plugin:showMsg("Plugin error:\n" .. tostring(dcall_err), 8)
        if on_done then on_done() end
        return
    end
    if derr then
        plugin:showMsg("Gemini error:\n" .. tostring(derr), 8)
        if on_done then on_done() end
        return
    end
    if not groups or #groups == 0 then
        if on_done then on_done() end
        return
    end

    -- Validate: keep must be a named character, absorb must be an unnamed one
    local name_set, unnamed_set = {}, {}
    for _, c in ipairs(all_chars) do
        if c.name:match("^Unnamed") then
            unnamed_set[c.name] = true
        else
            name_set[c.name] = true
        end
    end

    local valid_groups = {}
    for _, g in ipairs(groups) do
        if g.keep and name_set[g.keep] and type(g.absorb) == "table" and #g.absorb > 0 then
            local valid = true
            for _, a in ipairs(g.absorb) do
                if not unnamed_set[a] then valid = false; break end
            end
            if valid then table.insert(valid_groups, g) end
        end
    end

    if #valid_groups == 0 then
        if on_done then on_done() end
        return
    end

    local group_idx    = 1
    local merged_count = 0

    local function applyNext()
        if group_idx > #valid_groups then
            if merged_count > 0 then
                plugin:appendActivityLog(book_id, "Resolved " .. merged_count .. " unnamed character(s)")
                plugin:showMsg(merged_count .. " unnamed character(s) merged.", 4)
            end
            if on_done then on_done() end
            return
        end

        local g = valid_groups[group_idx]
        group_idx = group_idx + 1

        local absorb_names = table.concat(g.absorb, ", ")
        local reason = g.reason or "matching profiles"
        local confirm_text = string.format(
            'Unnamed match %d of %d\n\n"%s" appears to be "%s".\n\nReason: %s\n\nMerge "%s" into "%s"?',
            group_idx - 1, #valid_groups,
            absorb_names, g.keep,
            reason,
            absorb_names, g.keep
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

function UICharacter.onReanalyzeCharacter(plugin, book_id, char)
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
    local characters = UIShared.callApi(plugin, function()
        return client:reanalyzeCharacter(page_text, char, plugin:getReanalyzePrompt())
    end, working_msg)
    if not characters then return end
    if not characters or #characters == 0 then
        plugin:showMsg('"' .. char.name .. '" was not found on this page.', 4)
        return
    end

    local reanalyze_page = plugin:getCurrentPage()
    plugin.db:merge(book_id, characters, reanalyze_page)
    plugin:appendActivityLog(book_id, 'Re-analyzed "' .. char.name .. '" (p.' .. (reanalyze_page or "?") .. ")")
    plugin:showMsg('"' .. char.name .. '" updated.', 3)
end

function UICharacter.onReanalyzeCharacterPicker(plugin)
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
                UICharacter.onReanalyzeCharacter(plugin, book_id, char)
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

function UICharacter.onCleanCharacter(plugin, book_id, char_name)
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
    local result = UIShared.callApi(plugin, function()
        return client:cleanCharacter(char, plugin:getCleanupPrompt())
    end, working_msg)
    if not result then return end

    local new_name = result.name
    if new_name and new_name ~= "" and new_name ~= char.name then
        -- Name promotion: remove new name from aliases, add old name to aliases
        local old_name = char.name
        local alias_set = {}
        for _, a in ipairs(result.aliases or char.aliases or {}) do
            if a ~= "" and a ~= new_name then alias_set[a] = true end
        end
        alias_set[old_name] = true
        local new_aliases = {}
        for a in pairs(alias_set) do table.insert(new_aliases, a) end
        char.name    = new_name
        char.aliases = new_aliases
    elseif type(result.aliases) == "table" then
        char.aliases = result.aliases
    end
    if result.physical_description and result.physical_description ~= "" then
        char.physical_description = result.physical_description
    end
    if result.personality and result.personality ~= "" then
        char.personality = result.personality
    end
    if result.motivation and result.motivation ~= "" then
        char.motivation = result.motivation
    end
    if result.role and result.role ~= "" then char.role = result.role end
    if type(result.relationships) == "table" then
        char.relationships = result.relationships
    end
    if type(result.identity_tags) == "table" then
        char.identity_tags = result.identity_tags
    end
    if type(result.defining_moments) == "table" then
        char.defining_moments = result.defining_moments
    end
    char.needs_cleanup = nil

    -- updateCharacter matches by char_name (original), replaces with char (may have new name)
    plugin.db:updateCharacter(book_id, char_name, char)
    local display_name = char.name
    plugin:appendActivityLog(book_id, 'Cleaned up "' .. display_name .. '"')
    plugin:showMsg('"' .. display_name .. '" cleaned up.', 3)
end

-- ---------------------------------------------------------------------------
-- Word-selection character lookup (called from highlight popup)
-- ---------------------------------------------------------------------------

local _stop_words = { the=1, a=1, an=1, of=1, ["in"]=1, at=1, to=1, ["and"]=1, ["or"]=1, ["for"]=1,
                      with=1, by=1, on=1, from=1, is=1, was=1, he=1, she=1, his=1, her=1 }

function UICharacter.findMatchesForWord(all_chars, word)
    local word_lower = word:lower()
    local tokens = { word_lower }
    for w in word_lower:gmatch("%a+") do
        if #w >= 3 and not _stop_words[w] then
            table.insert(tokens, w)
        end
    end
    local matches = {}
    for _, c in ipairs(all_chars) do
        local matched = false
        local name_l = (c.name or ""):lower()
        for _, tok in ipairs(tokens) do
            if name_l:find(tok, 1, true) then matched = true; break end
        end
        if not matched then
            for _, alias in ipairs(c.aliases or {}) do
                local alias_l = alias:lower()
                for _, tok in ipairs(tokens) do
                    if alias_l:find(tok, 1, true) then matched = true; break end
                end
                if matched then break end
            end
        end
        if matched then table.insert(matches, c) end
    end
    return matches
end

function UICharacter.onWordCharacterLookup(plugin, word)
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

    local matches = UICharacter.findMatchesForWord(all_chars, word)

    if #matches == 0 then
        plugin:showMsg('"' .. word .. '" not found in character database.')
        return
    end

    if #matches == 1 then
        UICharacter.showCharacterViewer(plugin, book_id, matches[1])
        return
    end

    UICharacter.showCharacterBrowser(plugin, book_id, "default", word)
end

-- ---------------------------------------------------------------------------
-- Cross-reference propagation
-- ---------------------------------------------------------------------------

function UICharacter.onPropagateCrossReferences(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end
    local characters = plugin.db:load(book_id)
    if #characters < 2 then
        plugin:showMsg("Not enough characters to cross-reference.", 3)
        return
    end
    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local working_msg = InfoMessage:new{ text = "Scanning for cross-reference gaps..." }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local updates = UIShared.callApi(plugin, function()
        return client:propagateCrossReferences(characters, plugin:getCrossReferencePrompt())
    end, working_msg)
    if not updates then return end

    if #updates == 0 then
        plugin:showMsg("No cross-reference gaps found.", 4)
        return
    end

    local name_set = {}
    for _, c in ipairs(characters) do name_set[c.name] = true end
    local VALID_FIELDS = { defining_moments = true, relationships = true, identity_tags = true }
    local valid = {}
    for _, u in ipairs(updates) do
        if u.target and name_set[u.target] and u.field and VALID_FIELDS[u.field]
                and type(u.add) == "string" and u.add ~= "" then
            table.insert(valid, u)
        end
    end

    if #valid == 0 then
        plugin:showMsg("No valid cross-reference gaps found.", 4)
        return
    end

    local apply_count = 0
    local all_chars   = plugin.db:load(book_id)

    local function applyNext(remaining)
        if #remaining == 0 then
            if apply_count > 0 then
                plugin.db:save(book_id, all_chars)
                plugin:appendActivityLog(book_id, "Cross-referenced " .. apply_count .. " field(s)")
                plugin:showMsg(apply_count .. " cross-reference(s) applied.", 4)
            else
                plugin:showMsg("No cross-references applied.", 4)
            end
            return
        end

        local u    = remaining[1]
        local rest = { table.unpack(remaining, 2) }
        UIManager:show(ConfirmBox:new{
            text        = 'Add to ' .. u.target .. '\u{2019}s ' .. u.field:gsub("_", " ")
                          .. '?\n\n"' .. u.add .. '"',
            ok_text     = "Add",
            cancel_text = "Skip",
            ok_callback = function()
                for _, c in ipairs(all_chars) do
                    if c.name == u.target then
                        local arr = c[u.field] or {}
                        table.insert(arr, u.add)
                        c[u.field] = arr
                        apply_count = apply_count + 1
                        break
                    end
                end
                applyNext(rest)
            end,
            cancel_callback = function()
                applyNext(rest)
            end,
        })
    end

    applyNext(valid)
end

-- ---------------------------------------------------------------------------
-- Relationship map
-- ---------------------------------------------------------------------------

function UICharacter.onViewRelationshipMap(plugin)
    local api_key = plugin:getApiKey()
    if api_key == "" then
        plugin:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end

    local characters = plugin.db:load(book_id)
    if #characters < 2 then
        plugin:showMsg("Need at least 2 saved characters to build a relationship map.")
        return
    end

    local working_msg = InfoMessage:new{ text = "Building relationship map..." }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local map_text, err, usage
    local ok, call_err = pcall(function()
        map_text, err, usage = client:buildRelationshipMap(characters, plugin:getRelationshipMapPrompt())
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

    UIManager:show(TextViewer:new{
        title  = "Relationship Map — " .. plugin:getBookTitle(),
        text   = map_text,
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

-- ---------------------------------------------------------------------------
-- Activity log viewer
-- ---------------------------------------------------------------------------

function UICharacter.onViewActivityLog(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book — is a document open?")
        return
    end
    local DataStorage = require("datastorage")
    local log_path = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/activity.log"
    local f = io.open(log_path, "r")
    if not f then
        plugin:showMsg("No activity logged yet for this book.", 3)
        return
    end
    local lines = {}
    for line in f:lines() do table.insert(lines, line) end
    f:close()
    if #lines == 0 then
        plugin:showMsg("Activity log is empty.", 3)
        return
    end
    local reversed = {}
    for i = #lines, 1, -1 do table.insert(reversed, lines[i]) end
    UIManager:show(TextViewer:new{
        title  = "Activity Log — " .. plugin:getBookTitle(),
        text   = table.concat(reversed, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

return UICharacter
