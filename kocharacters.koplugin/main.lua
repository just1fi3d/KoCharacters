-- main.lua
-- KoCharacters Plugin for KOReader (Gemini AI, manual trigger)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local TextViewer      = require("ui/widget/textviewer")
local ConfirmBox      = require("ui/widget/confirmbox")
local Menu            = require("ui/widget/menu")
local Screen          = require("device").screen
local logger          = require("logger")
local _               = require("gettext")

local Dispatcher   = require("dispatcher")
local GeminiClient = require("gemini_client")
local CharacterDB  = require("character_db")
local EpubReader   = require("epub_reader")
local CharUtils    = require("char_utils")
local Portrait     = require("portrait")
local Export       = require("export")
local UISettings   = require("ui_settings")
local Extraction   = require("extraction")

local function portraitSafeName(name)
    return (name:gsub("[^%w%-]", "_"):lower())
end

-- ---------------------------------------------------------------------------
-- Plugin definition
-- ---------------------------------------------------------------------------
local KoCharacters = WidgetContainer:extend{
    name        = "kocharacters",
    is_doc_only = true,
}

function KoCharacters:onDispatcherRegisterActions()
    Dispatcher:registerAction("kochar_page", {
        category = "none",
        event    = "CharExtractPage",
        title    = _("KoCharacters: Extract from page"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_chapter", {
        category = "none",
        event    = "CharScanChapter",
        title    = _("KoCharacters: Scan chapter"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_view", {
        category = "none",
        event    = "CharViewCharacters",
        title    = _("KoCharacters: View characters"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_reanalyze", {
        category = "none",
        event    = "CharReanalyze",
        title    = _("KoCharacters: Re-analyze character..."),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_usage", {
        category = "none",
        event    = "CharViewUsage",
        title    = _("KoCharacters: View API usage"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_relmap", {
        category = "none",
        event    = "CharRelationshipMap",
        title    = _("KoCharacters: View relationship map"),
        reader   = true,
    })
end

function KoCharacters:onCharExtractPage()      self.extraction:onExtractCurrentPage() end
function KoCharacters:onCharScanChapter()      self.extraction:onScanChapter() end
function KoCharacters:onCharViewCharacters()   self:onViewCharacters() end
function KoCharacters:onCharReanalyze()        self:onReanalyzeCharacterPicker() end
function KoCharacters:onCharViewUsage()        self:onViewUsage() end
function KoCharacters:onCharRelationshipMap()  self:onViewRelationshipMap() end

function KoCharacters:init()
    self.db = CharacterDB
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    local self_ref = self
    self.extraction = Extraction.new({
        db          = self.db,
        ui          = self.ui,
        get_api_key = function() return self_ref:getApiKey() end,
        get_prompt  = function() return self_ref:getExtractionPrompt() end,
        get_book_id = function() return self_ref:getBookID() end,
        record_usage = function(u) self_ref:recordUsage(u) end,
        show_msg     = function(t, d) self_ref:showMsg(t, d) end,
        append_log   = function(b, m) self_ref:appendActivityLog(b, m) end,
        on_conflicts = function(book_id, new_chars, on_done, page_num, skip_cleanup)
            self_ref:handleIncomingConflicts(book_id, new_chars, on_done, page_num, skip_cleanup)
        end,
        check_warn_duplicates = function(book_id, on_continue)
            self_ref:checkAndWarnDuplicates(book_id, on_continue)
        end,
    })

    -- Add "Find character" option to the word selection / highlight popup
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        local self_ref = self
        self.ui.highlight:addToHighlightDialog("kocharacters_lookup", function(highlight_instance)
            return {
                text = "Find character",
                callback = function()
                    local selected = highlight_instance.selected_text
                    local word = selected and (selected.text or selected.word or "") or ""
                    word = word:match("^%s*(.-)%s*$") or ""
                    if highlight_instance.highlight_dialog then
                        UIManager:close(highlight_instance.highlight_dialog)
                    end
                    -- Clear the text selection so it doesn't show the highlight menu
                    -- again after the character viewer is closed.
                    pcall(function() highlight_instance:clear() end)
                    UIManager:scheduleIn(0.1, function()
                        self_ref:onWordCharacterLookup(word)
                    end)
                end,
            }
        end)
    end

    self:_runOnTimeMigrations()
    logger.info("KoCharacters: plugin initialised")
end

-- One-time migration: assign IDs to existing characters and rename portrait files to <id>.png
function KoCharacters:_runOnTimeMigrations()
    if G_reader_settings:readSetting("kocharacters_id_migration_v3") then return end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs then
        G_reader_settings:saveSetting("kocharacters_id_migration_v3", true)
        return
    end

    local DataStorage = require("datastorage")
    local base_dir    = DataStorage:getDataDir() .. "/kocharacters"
    local attr        = lfs.attributes(base_dir)
    if not attr or attr.mode ~= "directory" then
        G_reader_settings:saveSetting("kocharacters_id_migration_v3", true)
        return
    end

    local total_chars, total_portraits = 0, 0

    for entry in lfs.dir(base_dir) do
        if entry ~= "." and entry ~= ".." then
            local book_dir = base_dir .. "/" .. entry
            local ba = lfs.attributes(book_dir)
            if ba and ba.mode == "directory" then
                -- load() backfills IDs for any character missing one and saves automatically
                local chars = self.db:load(entry)
                total_chars = total_chars + #chars

                -- Rename portrait files from name-based to id-based
                local portraits_dir = book_dir .. "/portraits"
                local changed = false
                for _, c in ipairs(chars) do
                    if c.id and c.id ~= "" then
                        local expected = c.id .. ".png"
                        -- Current portrait_file already correct
                        if c.portrait_file == expected then
                            -- nothing to do
                        else
                            -- Determine the old filename: stored portrait_file or name-based fallback
                            local old_filename = (c.portrait_file and c.portrait_file ~= "")
                                and c.portrait_file
                                or (portraitSafeName(c.name or "") .. ".png")
                            local old_path = portraits_dir .. "/" .. old_filename
                            local fcheck = io.open(old_path, "r")
                            if fcheck then
                                fcheck:close()
                                os.rename(old_path, portraits_dir .. "/" .. expected)
                                c.portrait_file = expected
                                changed = true
                                total_portraits = total_portraits + 1
                            end
                        end
                    end
                end
                if changed then self.db:save(entry, chars) end
            end
        end
    end

    G_reader_settings:saveSetting("kocharacters_id_migration_v3", true)
    logger.info(string.format(
        "KoCharacters: migration complete — %d character(s) assigned IDs, %d portrait(s) renamed",
        total_chars, total_portraits
    ))
end

function KoCharacters:onPageUpdate(pageno)
    self.extraction:onPageChanged(pageno)
end

function KoCharacters:onPosUpdate()
    local pageno
    pcall(function() pageno = self.ui.view.state.page end)
    if pageno then self.extraction:onPageChanged(pageno) end
end

function KoCharacters:onReaderReady()
    self.extraction:onReaderReady()
end

function KoCharacters:onCloseDocument()
    self.extraction:cleanup()
end

function KoCharacters:onScanPendingPages(book_id)
    self.extraction:onScanPendingPages(book_id)
end

function KoCharacters:addToMainMenu(menu_items)
    menu_items.ko_characters = {
        text_func = function()
            local book_id = self:getBookID()
            local n = book_id and #self.db:load(book_id) or 0
            local base = n == 0 and _("KoCharacters") or (_("KoCharacters") .. " (" .. n .. ")")
            if book_id and self.db:hasPendingCleanup(book_id) then
                base = base .. " — cleanup needed"
            end
            return base
        end,
        sub_item_table = {
            {
                text     = _("Extract characters from this page"),
                callback = function() self.extraction:onExtractCurrentPage() end,
            },
            {
                text     = _("Scan current chapter"),
                callback = function() self.extraction:onScanChapter() end,
            },
            {
                text     = _("Scan specific chapter"),
                callback = function() self.extraction:onScanSpecificChapter() end,
            },
            {
                text     = _("View saved characters"),
                callback = function() self:onViewCharacters() end,
            },
            {
                text     = _("Re-analyze character"),
                callback = function() self:onReanalyzeCharacterPicker() end,
            },
            {
                text     = _("View relationship map"),
                callback = function() self:onViewRelationshipMap() end,
            },
            {
                text     = _("Cleanup all characters"),
                callback = function() self:onCleanupAllCharacters() end,
            },
            {
                text     = _("Detect & merge duplicates"),
                callback = function() self:onMergeDetection() end,
            },
            {
                text     = _("Generate portraits"),
                callback = function() Portrait.batchGenerate(self) end,
            },
            {
                text     = _("Export..."),
                callback = function()
                    local self_ref = self
                    local export_menu
                    export_menu = Menu:new{
                        title      = "Export",
                        item_table = {
                            {
                                text     = "Export character list",
                                callback = function() UIManager:close(export_menu); Export.exportList(self_ref) end,
                            },
                            {
                                text     = "Export as ZIP (HTML + portraits)",
                                callback = function() UIManager:close(export_menu); Export.exportZip(self_ref) end,
                            },
                            {
                                text     = "Upload to server",
                                callback = function() UIManager:close(export_menu); Export.uploadToServer(self_ref) end,
                            },
                        },
                        width       = Screen:getWidth(),
                        show_parent = self.ui,
                    }
                    UIManager:show(export_menu)
                end,
            },
            {
                text     = _("Activity log"),
                callback = function() self:onViewActivityLog() end,
            },
            {
                text     = _("Settings..."),
                callback = function() UISettings.open(self) end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function KoCharacters:showMsg(text, timeout)
    UIManager:show(InfoMessage:new{
        text    = text,
        timeout = timeout or 4,
    })
end

function KoCharacters:appendActivityLog(book_id, message)
    if not book_id then return end
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id
    local util = require("util")
    util.makePath(dir)
    local f = io.open(dir .. "/activity.log", "a")
    if not f then return end
    f:write("[" .. os.date("%Y-%m-%d %H:%M") .. "] " .. message .. "\n")
    f:close()
end

function KoCharacters:onViewActivityLog()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end
    local DataStorage = require("datastorage")
    local log_path = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/activity.log"
    local f = io.open(log_path, "r")
    if not f then
        self:showMsg("No activity logged yet for this book.", 3)
        return
    end
    local lines = {}
    for line in f:lines() do table.insert(lines, line) end
    f:close()
    if #lines == 0 then
        self:showMsg("Activity log is empty.", 3)
        return
    end
    local reversed = {}
    for i = #lines, 1, -1 do table.insert(reversed, lines[i]) end
    UIManager:show(TextViewer:new{
        title  = "Activity Log — " .. self:getBookTitle(),
        text   = table.concat(reversed, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

function KoCharacters:checkAndWarnDuplicates(book_id, on_continue)
    local characters = self.db:load(book_id)
    if #characters < 2 then on_continue(); return end
    local dup_pairs = CharUtils.findDuplicatePairs(characters)
    if #dup_pairs == 0 then on_continue(); return end

    local self_ref = self

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
                        self_ref.db:mergeCharacters(book_id, a, b)
                        processPairs(rest)
                    end,
                },
                {
                    text     = 'Merge into "' .. a .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        self_ref.db:mergeCharacters(book_id, b, a)
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

function KoCharacters:handleIncomingConflicts(book_id, new_chars, on_done, page_num, skip_cleanup)
    new_chars = CharUtils.deduplicateIncoming(new_chars)
    local existing  = self.db:load(book_id)
    local conflicts = CharUtils.findIncomingConflicts(existing, new_chars)
    if #conflicts == 0 then on_done(new_chars); return end

    -- Auto-accept mode: enrich all conflicts silently, show a toast summary
    if G_reader_settings:readSetting("kocharacters_auto_enrich") then
        local enriched_names = {}
        local conflict_set   = {}
        for _, conflict in ipairs(conflicts) do
            local new_c = conflict.new_char
            local ex_c  = conflict.existing_char
            self.db:enrichCharacter(book_id, ex_c.name, new_c, page_num)
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
            if skip_cleanup then self.db:markPendingCleanup(book_id) end
            self:showMsg("Enriched: " .. table.concat(enriched_names, ", "), 3)
        end
        on_done(resolved)
        return
    end

    local self_ref  = self
    local to_enrich = {}   -- new_char_name_lower -> existing_char_name

    local function finalize(resolved)
        -- Collect existing chars that were just enriched
        local enriched_names = {}
        for _, ex_name in pairs(to_enrich) do enriched_names[ex_name] = true end

        local enriched_chars = {}
        for _, c in ipairs(self_ref.db:load(book_id)) do
            if enriched_names[c.name] then table.insert(enriched_chars, c) end
        end

        if #enriched_chars == 0 then
            on_done(resolved)
            return
        end

        if skip_cleanup then
            self_ref.db:markPendingCleanup(book_id)
            on_done(resolved)
            return
        end

        -- One Gemini call to clean up all enriched profiles
        local enriched_names_list = {}
        for _, ec in ipairs(enriched_chars) do table.insert(enriched_names_list, ec.name or "?") end
        local working_msg = InfoMessage:new{
            text = "Cleaning up " .. #enriched_chars .. " enriched character(s):\n"
                   .. table.concat(enriched_names_list, ", ")
        }
        UIManager:show(working_msg)
        UIManager:forceRePaint()

        local client = GeminiClient:new(self_ref:getApiKey())
        local cleaned, err, usage1
        local ok, call_err = pcall(function()
            cleaned, err, usage1 = client:cleanCharacters(enriched_chars)
        end)
        UIManager:close(working_msg)
        if ok and not err then self_ref:recordUsage(usage1) end

        if ok and not err and cleaned and type(cleaned) == "table" then
            local all_chars = self_ref.db:load(book_id)
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
            if changed then self_ref.db:save(book_id, all_chars) end
        else
            logger.warn("KoCharacters: batch cleanup failed: " .. tostring(call_err or err))
        end

        on_done(resolved)
    end

    local function processConflicts(remaining)
        if #remaining == 0 then
            -- Apply all enrichments, then clean
            for new_name_low, ex_name in pairs(to_enrich) do
                for _, c in ipairs(new_chars) do
                    if (c.name or ""):lower() == new_name_low then
                        self_ref.db:enrichCharacter(book_id, ex_name, c, page_num)
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
        if new_c.role and new_c.role ~= ""                              then table.insert(lines, "New role: "        .. new_c.role)                 end
        if new_c.physical_description and new_c.physical_description ~= "" then table.insert(lines, "New appearance: " .. new_c.physical_description) end
        if ex_c.role and ex_c.role ~= ""                                then table.insert(lines, "Existing role: "   .. ex_c.role)                  end

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

-- Key for Gemini text calls (character extraction, cleanup, etc.)
function KoCharacters:getApiKey()
    return G_reader_settings:readSetting("kocharacters_extraction_api_key") or ""
end

-- Key for Imagen image generation
function KoCharacters:getImagenApiKey()
    return G_reader_settings:readSetting("kocharacters_imagen_api_key") or ""
end

function KoCharacters:getCurrentPage()
    local page
    pcall(function() page = self.ui.view.state.page end)
    return page
end

function KoCharacters:getExtractionPrompt()
    return G_reader_settings:readSetting("kocharacters_extraction_prompt")
        or GeminiClient.DEFAULT_EXTRACTION_PROMPT
end

function KoCharacters:getCleanupPrompt()
    return G_reader_settings:readSetting("kocharacters_cleanup_prompt")
        or GeminiClient.DEFAULT_CLEANUP_PROMPT
end

function KoCharacters:getMergeDetectionPrompt()
    return G_reader_settings:readSetting("kocharacters_merge_detection_prompt")
        or GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT
end

function KoCharacters:getReanalyzePrompt()
    return G_reader_settings:readSetting("kocharacters_reanalyze_prompt")
        or GeminiClient.DEFAULT_REANALYZE_PROMPT
end

function KoCharacters:getRelationshipMapPrompt()
    return G_reader_settings:readSetting("kocharacters_relationship_map_prompt")
        or GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT
end

function KoCharacters:getPortraitPrompt()
    return G_reader_settings:readSetting("kocharacters_portrait_prompt")
        or Portrait.DEFAULT_PORTRAIT_PROMPT
end

function KoCharacters:recordUsage(usage)
    local json        = require("dkjson")
    local DataStorage = require("datastorage")
    local util        = require("util")
    local dir         = DataStorage:getDataDir() .. "/kocharacters"
    util.makePath(dir)
    local path = dir .. "/usage_stats.json"

    local stats = {}
    local f = io.open(path, "r")
    if f then
        stats = json.decode(f:read("*all")) or {}
        f:close()
    end

    local date = os.date("%Y-%m-%d")
    if not stats[date] then
        stats[date] = { calls = 0, prompt_tokens = 0, output_tokens = 0, images = 0 }
    end
    stats[date].calls         = (stats[date].calls         or 0) + 1
    stats[date].prompt_tokens = (stats[date].prompt_tokens or 0) + (usage and usage.prompt_tokens or 0)
    stats[date].output_tokens = (stats[date].output_tokens or 0) + (usage and usage.output_tokens or 0)
    if usage and usage.images then
        stats[date].images = (stats[date].images or 0) + usage.images
    end

    local fw = io.open(path, "w")
    if fw then fw:write(json.encode(stats)); fw:close() end
end

function KoCharacters:onViewRelationshipMap()
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    local characters = self.db:load(book_id)
    if #characters < 2 then
        self:showMsg("Need at least 2 saved characters to build a relationship map.")
        return
    end

    local working_msg = InfoMessage:new{ text = "Building relationship map..." }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local map_text, err, usage
    local ok, call_err = pcall(function()
        map_text, err, usage = client:buildRelationshipMap(characters, self:getRelationshipMapPrompt())
    end)

    UIManager:close(working_msg)
    if ok and not err then self:recordUsage(usage) end

    if not ok then
        self:showMsg("Plugin error:\n" .. tostring(call_err), 8)
        return
    end
    if err then
        self:showMsg("Gemini error:\n" .. tostring(err), 8)
        return
    end

    UIManager:show(TextViewer:new{
        title  = "Relationship Map — " .. self:getBookTitle(),
        text   = map_text,
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

function KoCharacters:onViewUsage()
    local json        = require("dkjson")
    local DataStorage = require("datastorage")
    local path        = DataStorage:getDataDir() .. "/kocharacters/usage_stats.json"

    local stats = {}
    local f = io.open(path, "r")
    if f then
        stats = json.decode(f:read("*all")) or {}
        f:close()
    end

    local dates = {}
    for date in pairs(stats) do table.insert(dates, date) end
    table.sort(dates, function(a, b) return a > b end)

    if #dates == 0 then
        self:showMsg("No API usage recorded yet.", 3)
        return
    end

    local lines = { "Date            Calls  Prompt     Output     Images" }
    table.insert(lines, string.rep("-", 52))
    local tot_calls, tot_prompt, tot_output, tot_images = 0, 0, 0, 0
    for _, date in ipairs(dates) do
        local d = stats[date]
        local c = d.calls         or 0
        local p = d.prompt_tokens or 0
        local o = d.output_tokens or 0
        local i = d.images        or 0
        tot_calls  = tot_calls  + c
        tot_prompt = tot_prompt + p
        tot_output = tot_output + o
        tot_images = tot_images + i
        table.insert(lines, string.format("%-16s %-6d %-10d %-10d %d", date, c, p, o, i))
    end
    table.insert(lines, string.rep("-", 52))
    table.insert(lines, string.format("%-16s %-6d %-10d %-10d %d", "TOTAL", tot_calls, tot_prompt, tot_output, tot_images))

    UIManager:show(TextViewer:new{
        title  = "API Usage (Gemini + Imagen)",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

-- Derive a stable book ID purely from the file path — no document API calls
function KoCharacters:getBookID()
    if self.ui and self.ui.document and self.ui.document.file then
        local path = self.ui.document.file
        -- Hash for uniqueness (two books can share a title)
        local sum = #path
        for i = 1, #path do sum = sum + string.byte(path, i) end

        -- Prefer metadata title, fall back to filename without extension
        local title = ""
        if self.ui.doc_settings then
            local ok, props = pcall(function() return self.ui.doc_settings:readSetting("doc_props") end)
            if ok and props and props.title and props.title ~= "" then
                title = props.title
            end
        end
        if title == "" then
            local fname = path:match("([^/]+)$") or "book"
            title = fname:gsub("%.[^%.]+$", "")  -- strip extension
        end

        -- Sanitize: keep letters, digits, spaces, hyphens; collapse whitespace to underscore
        title = title:gsub("[^%w%s%-]", ""):gsub("%s+", "_"):gsub("_+", "_")
        title = title:match("^_*(.-)_*$") or title  -- trim leading/trailing underscores
        if title == "" then title = "book" end

        return title .. "_" .. tostring(sum)
    end
    return nil
end

function KoCharacters:getBookTitle()
    if self.ui and self.ui.doc_settings then
        local ok, props = pcall(function()
            return self.ui.doc_settings:readSetting("doc_props")
        end)
        if ok and props and props.title and props.title ~= "" then
            return props.title
        end
    end
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file:match("([^/]+)$") or "Unknown Book"
    end
    return "Unknown Book"
end

-- ---------------------------------------------------------------------------
-- Edit character
-- ---------------------------------------------------------------------------
function KoCharacters:onEditCharacter(book_id, char, refresh_browser_fn, show_viewer_fn)
    local self_ref   = self
    -- Track the name used to look up the record (changes if the user renames)
    local lookup_name = char.name

    local function save()
        self_ref.db:updateCharacter(book_id, lookup_name, char)
        lookup_name = char.name   -- keep in sync if name was changed
    end

    local edit_menu          -- forward reference so callbacks can close+reopen it
    local closing_for_save = false  -- guard: suppress close_callback during after_save
    local function showEditMenu()
        local ok, Menu = pcall(require, "ui/widget/menu")
        if not ok or not Menu then return end

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
                    role_menu = Menu:new{
                        title      = "Select Role",
                        item_table = role_items,
                        width      = Screen:getWidth(),
                        show_parent = self_ref.ui,
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

        edit_menu = Menu:new{
            title       = "Edit: " .. (char.name or ""),
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = self_ref.ui,
        }
        -- onClose fires only for the physical back key (not when an InputDialog
        -- takes focus), so it is safe to navigate back to the viewer here.
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
-- Actions (extraction delegates — implementations in extraction.lua)
-- ---------------------------------------------------------------------------
function KoCharacters:onExtractCurrentPage() self.extraction:onExtractCurrentPage() end

function KoCharacters:onScanChapter()         self.extraction:onScanChapter() end

function KoCharacters:onScanSpecificChapter() self.extraction:onScanSpecificChapter() end

function KoCharacters:doChapterScan(book_id, start_page, end_page)
    self.extraction:doChapterScan(book_id, start_page, end_page)
end

function KoCharacters:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser_fn)
    local self_ref = self
    local name     = char.name or "Unknown"

    -- Shared button rows for both viewers
    local function make_buttons(close_fn)
        local others_for_merge = {}
        for _, other in ipairs(self_ref.db:load(book_id)) do
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
                                self_ref.db:mergeCharacters(book_id, name, other_name)
                                self_ref:showMsg('"' .. name .. '" merged into "' .. other_name .. '".', 3)
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
                    show_parent = self_ref.ui,
                })
            end
        end
        local function do_delete()
            close_fn()
            UIManager:show(ConfirmBox:new{
                text        = 'Delete "' .. name .. '" from the character list?',
                ok_text     = "Delete",
                ok_callback = function()
                    self_ref.db:deleteCharacter(book_id, name)
                    self_ref:showMsg(name .. " deleted.", 2)
                end,
            })
        end
        return {
            {
                { text = "Re-analyze", callback = function() close_fn(); self_ref:onReanalyzeCharacter(book_id, char) end },
                { text = "Clean up",   callback = function() close_fn(); self_ref:onCleanCharacter(book_id, char.name) end },
                { text = "Edit",       callback = function()
                    close_fn()
                    local function show_viewer_fn()
                        self_ref:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser_fn)
                    end
                    self_ref:onEditCharacter(book_id, char, refresh_browser_fn, show_viewer_fn)
                end },
            },
            {
                { text = "Gen. portrait", callback = function()
                    close_fn()
                    Portrait.onGenerate(self_ref, book_id, char)
                    self_ref:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser_fn)
                end },
                { text = "Merge into...", callback = do_merge },
                { text = "Delete",        callback = do_delete },
            },
        }
    end

    -- Text viewer fallback when HTML mode is disabled
    if not G_reader_settings:readSetting("kocharacters_html_viewer") then
        local self_ref = self
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
                for _, c in ipairs(self_ref.db:load(book_id)) do
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
                        self_ref:showCharacterViewer(book_id, found, sort_mode, query, refresh_browser_fn)
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

function KoCharacters:onViewCharacters()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end
    if #self.db:load(book_id) == 0 then
        self:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end
    self:showCharacterBrowser(book_id, "default", "")
end

function KoCharacters:showCharacterBrowser(book_id, sort_mode, query)
    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok or not Menu then return end

    local all_chars = self.db:load(book_id)
    local self_ref  = self

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
        local cur_page = self:getCurrentPage() or 0
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
                            self_ref:showCharacterBrowser(book_id, sort_mode, "")
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
                            self_ref:showCharacterBrowser(book_id, sort_mode, q2)
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
            self_ref:showCharacterBrowser(book_id, sort_cycle[sort_mode] or "default", query)
        end,
    })

    -- Forward-declare browser_menu and refresh_browser BEFORE the loop so the
    -- callbacks inside the loop capture them as upvalues (not nil globals).
    local browser_menu
    local function refresh_browser()
        UIManager:close(browser_menu)
        self_ref:showCharacterBrowser(book_id, sort_mode, query)
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
                            local chars = self_ref.db:load(book_id)
                            for _, ch in ipairs(chars) do
                                if ch.name == real_name then
                                    ch.unlocked = true
                                    self_ref.db:updateCharacter(book_id, real_name, ch)
                                    break
                                end
                            end
                            self_ref:showCharacterBrowser(book_id, sort_mode, query)
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
                    self_ref.db:updateCharacter(book_id, char.name, char)
                end
                self_ref:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser)
            end,
        })
        end  -- else (not spoiler)
    end

    local count_str = query ~= "" and (#filtered .. "/" .. #all_chars) or tostring(#all_chars)
    browser_menu = Menu:new{
        title       = count_str .. " character(s) — " .. self:getBookTitle(),
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    }
    UIManager:show(browser_menu)
end

-- portrait and export methods moved to portrait.lua and export.lua

function KoCharacters:onCleanupAllCharacters()
    local book_id = self:getBookID()
    if not book_id then return end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters to clean up.", 3)
        return
    end

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    -- Count flagged characters
    local flagged = {}
    for _, c in ipairs(characters) do
        if c.needs_cleanup then table.insert(flagged, c) end
    end
    local n_flagged = #flagged
    local n_all     = #characters

    local self_ref = self

    -- Step 2: after text cleanup, optionally run merge detection
    local function runMergeDetection() self_ref:onMergeDetection() end

    local BATCH_SIZE = G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5

    local function runCleanup(chars_to_clean)
        local client    = GeminiClient:new(api_key)
        local all_chars = self.db:load(book_id)
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
            if ok and not err then self_ref:recordUsage(usage) end

            if not ok then
                self_ref:showMsg("Plugin error:\n" .. tostring(call_err), 8)
                return
            end
            if err then
                self_ref:showMsg("Gemini error:\n" .. tostring(err), 8)
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

        if changed then self_ref.db:save(book_id, all_chars) end
        self_ref.db:clearPendingCleanup(book_id)
        self_ref:appendActivityLog(book_id, "Cleanup all: " .. total .. " character(s) cleaned")
        if G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup") then
            runMergeDetection()
        else
            self_ref:showMsg("Cleanup complete.", 4)
        end
    end

    -- Ask the user which characters to clean up
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

function KoCharacters:onMergeDetection()
    local book_id = self:getBookID()
    if not book_id then return end

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local all_chars = self.db:load(book_id)
    if #all_chars < 2 then
        self:showMsg("Not enough characters to merge.", 3)
        return
    end

    local self_ref = self

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
        groups, derr, dusage = client:detectMergeGroups(slim_chars, self_ref:getMergeDetectionPrompt())
    end)
    UIManager:close(detect_msg)
    if dok and not derr then self_ref:recordUsage(dusage) end

    if not dok then
        self_ref:showMsg("Plugin error:\n" .. tostring(dcall_err), 8)
        return
    end
    if derr then
        self_ref:showMsg("Gemini error:\n" .. tostring(derr), 8)
        return
    end
    if not groups or #groups == 0 then
        self_ref:showMsg("No duplicate characters detected.", 4)
        return
    end

    -- Filter out groups where any name no longer exists in the DB
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
        self_ref:showMsg("No duplicate characters detected.", 4)
        return
    end

    local group_idx = 1
    local merged_count = 0

    local function applyNext()
        if group_idx > #valid_groups then
            if merged_count > 0 then
                self_ref:appendActivityLog(book_id, "Merged " .. merged_count .. " duplicate(s)")
            end
            local msg = merged_count > 0
                and (merged_count .. " character(s) merged.")
                or  "No characters merged."
            self_ref:showMsg(msg, 4)
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
                    self_ref.db:mergeCharacters(book_id, src, g.keep)
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

function KoCharacters:onClearDatabase()
    local book_id = self:getBookID()
    if not book_id then return end
    UIManager:show(ConfirmBox:new{
        text        = "Delete all saved characters for this book?",
        ok_text     = "Delete",
        ok_callback = function()
            self.db:clear(book_id)
            self.db:clearScannedPages(book_id)
            self.db:clearPendingCleanup(book_id)
            self:showMsg("Character database cleared.", 3)
        end,
    })
end

-- settings methods moved to ui_settings.lua

function KoCharacters:onReanalyzeCharacter(book_id, char)
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local page_text, perr = EpubReader.getPageText(self.ui.document, self:getCurrentPage())
    if not page_text then
        self:showMsg("Could not get page text:\n" .. tostring(perr))
        return
    end

    local working_msg = InfoMessage:new{ text = 'Re-analyzing "' .. char.name .. '"...' }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local characters, api_err, usage
    local ok, call_err = pcall(function()
        characters, api_err, usage = client:reanalyzeCharacter(
            page_text, char, self:getReanalyzePrompt())
    end)

    UIManager:close(working_msg)
    if ok and not api_err then self:recordUsage(usage) end

    if not ok then
        self:showMsg("Plugin error:\n" .. tostring(call_err), 8)
        return
    end
    if api_err then
        self:showMsg("Gemini error:\n" .. tostring(api_err), 8)
        return
    end
    if not characters or #characters == 0 then
        self:showMsg('"' .. char.name .. '" was not found on this page.', 4)
        return
    end

    local reanalyze_page = self:getCurrentPage()
    self.db:merge(book_id, characters, reanalyze_page)
    self:appendActivityLog(book_id, 'Re-analyzed "' .. char.name .. '" (p.' .. (reanalyze_page or "?") .. ")")
    self:showMsg('"' .. char.name .. '" updated.', 3)
end

function KoCharacters:onReanalyzeCharacterPicker()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters saved yet.")
        return
    end

    local self_ref = self
    local items = {}
    for _, c in ipairs(characters) do
        local char = c
        local role = (c.role and c.role ~= "") and (" [" .. c.role .. "]") or ""
        table.insert(items, {
            text     = (c.name or "Unknown") .. role,
            callback = function()
                self_ref:onReanalyzeCharacter(book_id, char)
            end,
        })
    end

    local ok, Menu = pcall(require, "ui/widget/menu")
    if ok and Menu then
        UIManager:show(Menu:new{
            title       = "Re-analyze which character?",
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = self.ui,
        })
    end
end

function KoCharacters:onCleanCharacter(book_id, char_name)
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local characters = self.db:load(book_id)
    local char = nil
    for _, c in ipairs(characters) do
        if c.name == char_name then char = c; break end
    end
    if not char then self:showMsg("Character not found.", 3); return end

    local working_msg = InfoMessage:new{ text = 'Cleaning up "' .. char_name .. '"...' }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local result, err, usage
    local ok, call_err = pcall(function()
        result, err, usage = client:cleanCharacter(char, self:getCleanupPrompt())
    end)

    UIManager:close(working_msg)
    if ok and not err then self:recordUsage(usage) end

    if not ok then self:showMsg("Error:\n" .. tostring(call_err), 6); return end
    if err    then self:showMsg("Gemini error:\n" .. tostring(err), 6); return end

    -- Apply cleaned fields back to the character
    if result.physical_description then char.physical_description = result.physical_description end
    if result.personality          then char.personality          = result.personality          end
    if result.role and result.role ~= "" then char.role = result.role end
    if result.relationships and type(result.relationships) == "table" then
        char.relationships = result.relationships
    end
    char.needs_cleanup = nil

    self.db:updateCharacter(book_id, char_name, char)
    self:appendActivityLog(book_id, 'Cleaned up "' .. char_name .. '"')
    self:showMsg('"' .. char_name .. '" cleaned up.', 3)
end

-- ---------------------------------------------------------------------------
-- Word-selection character lookup (called from highlight popup)
-- ---------------------------------------------------------------------------
function KoCharacters:onWordCharacterLookup(word)
    if not word or word == "" then
        self:showMsg("No word selected.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    local all_chars = self.db:load(book_id)
    if #all_chars == 0 then
        self:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end

    -- Build a list of search tokens from the selected text:
    -- always include the full phrase, plus each individual word (3+ chars, skip stopwords)
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
        self:showMsg('"' .. word .. '" not found in character database.')
        return
    end

    if #matches == 1 then
        self:showCharacterViewer(book_id, matches[1])
        return
    end

    -- Multiple matches — open browser pre-filtered by the selected word
    self:showCharacterBrowser(book_id, "default", word)
end

return KoCharacters
