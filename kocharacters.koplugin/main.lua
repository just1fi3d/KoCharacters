-- main.lua
-- KoCharacters Plugin for KOReader (Gemini AI, manual trigger)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Menu            = require("ui/widget/menu")
local Screen          = require("device").screen
local logger          = require("logger")
local _               = require("gettext")

local Dispatcher   = require("dispatcher")
local GeminiClient = require("gemini_client")
local DBCharacter  = require("db_character")
local DBCodex      = require("db_codex")
local Portrait     = require("portrait")
local Export       = require("export")
local UISettings   = require("ui_settings")
local UICharacter  = require("ui_character")
local UICodex      = require("ui_codex")
local EpubReader   = require("epub_reader")
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

function KoCharacters:setupResources()
    local DataStorage = require("datastorage")
    local lfs         = require("libs/libkoreader-lfs")
    local util        = require("util")
    local data_dir    = DataStorage:getDataDir()

    -- Copy the bundled tab-bar icon to the user icons dir so IconWidget finds it.
    local icon_dest = data_dir .. "/icons/appbar.kocharacters.svg"
    if lfs.attributes(icon_dest, "mode") ~= "file" then
        local icon_src = data_dir .. "/plugins/kocharacters.koplugin/appbar.kocharacters.svg"
        local rf = io.open(icon_src, "r")
        if rf then
            local content = rf:read("*a"); rf:close()
            util.makePath(data_dir .. "/icons")
            local wf = io.open(icon_dest, "w")
            if wf then wf:write(content); wf:close() end
        end
    end

    -- Write reader_menu_order.lua if ko_characters is not already registered there.
    local order_path = DataStorage:getSettingsDir() .. "/reader_menu_order.lua"
    local needs_write = true
    if lfs.attributes(order_path, "mode") == "file" then
        local ok, existing = pcall(dofile, order_path)
        if ok and type(existing) == "table" then
            local buttons = existing["KOMenu:menu_buttons"]
            if type(buttons) == "table" then
                for _, v in ipairs(buttons) do
                    if v == "ko_characters" then needs_write = false; break end
                end
            end
        end
        if needs_write then
            -- Order file exists with different customisations — don't overwrite.
            logger.warn("KoCharacters: reader_menu_order.lua exists but ko_characters missing; add it to KOMenu:menu_buttons manually for the tab icon")
            needs_write = false
        end
    end
    if needs_write then
        local f = io.open(order_path, "w")
        if f then
            f:write('return {\n')
            f:write('    ["KOMenu:menu_buttons"] = {\n')
            f:write('        "navi", "typeset", "setting", "tools", "search", "filemanager", "ko_characters", "main",\n')
            f:write('    },\n')
            f:write('    ko_characters = {},\n')
            f:write('}\n')
            f:close()
        end
    end
end

function KoCharacters:init()
    self.db       = DBCharacter
    self.db_codex = DBCodex
    self:onDispatcherRegisterActions()
    self:setupResources()
    self.ui.menu:registerToMainMenu(self)
    GeminiClient.setThinkingBudget(G_reader_settings:readSetting("kocharacters_thinking_budget"))

    -- Clean up any stale async temp files left by a previous crash/restart.
    local DataStorage = require("datastorage")
    local tmp_dir = DataStorage:getDataDir() .. "/kocharacters"
    local f = io.popen('ls "' .. tmp_dir .. '"/ 2>/dev/null')
    if f then
        for name in f:lines() do
            if name:find("%.async_req_", 1, true) or name:find("%.async_resp_", 1, true)
               or name == ".codex_create_req.json" or name == ".codex_create_resp.json" then
                os.remove(tmp_dir .. "/" .. name)
                logger.info("KoCharacters: cleaned stale async file: " .. name)
            end
        end
        f:close()
    end

    local self_ref = self
    self.extraction = Extraction.new({
        db          = self.db,
        db_codex    = self.db_codex,
        ui          = self.ui,
        get_api_key           = function() return self_ref:getApiKey() end,
        get_model             = function() return self_ref:getGeminiModel() end,
        get_prompt            = function() return self_ref:getExtractionPrompt() end,
        get_codex_update_prompt = function() return self_ref:getCodexUpdatePrompt() end,
        get_book_id           = function() return self_ref:getBookID() end,
        record_usage = function(u) self_ref:recordUsage(u) end,
        show_msg     = function(t, d) self_ref:showMsg(t, d) end,
        append_log   = function(b, m) self_ref:appendActivityLog(b, m) end,
        on_conflicts = function(book_id, new_chars, on_done, page_num, skip_cleanup)
            UICharacter.handleIncomingConflicts(self_ref, book_id, new_chars, on_done, page_num, skip_cleanup)
        end,
        check_warn_duplicates = function(book_id, on_continue)
            UICharacter.checkAndWarnDuplicates(self_ref, book_id, on_continue)
        end,
    })

    -- Add "View character" option to the word selection / highlight popup (only when the word matches a known character)
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        local self_ref = self
        self.ui.highlight:addToHighlightDialog("kocharacters_lookup", function(highlight_instance)
            local selected = highlight_instance.selected_text
            local word = selected and (selected.text or selected.word or "") or ""
            word = word:match("^%s*(.-)%s*$") or ""
            local book_id = self_ref:getBookID()
            local matches = {}
            if word ~= "" and book_id then
                local all_chars = self_ref.db:load(book_id)
                if #all_chars > 0 then
                    matches = UICharacter.findMatchesForWord(all_chars, word)
                end
            end
            return {
                text = "View character",
                show_in_highlight_dialog_func = function() return #matches > 0 end,
                callback = function()
                    if highlight_instance.highlight_dialog then
                        UIManager:close(highlight_instance.highlight_dialog)
                    end
                    pcall(function() highlight_instance:clear() end)
                    UIManager:scheduleIn(0.1, function()
                        UICharacter.onWordCharacterLookup(self_ref, word)
                    end)
                end,
            }
        end)
    end

    -- Add "Track in Codex" / "View in Codex" to the highlight popup
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("kocharacters_codex", function(highlight_instance)
            local selected = highlight_instance.selected_text
            local word = selected and (selected.text or selected.word or "") or ""
            word = word:match("^%s*(.-)%s*$") or ""
            local book_id  = self_ref:getBookID()
            local is_known = book_id and word ~= "" and self_ref.db_codex:isNameKnown(book_id, word)
            return {
                text = is_known and "View in Codex" or "Track in Codex",
                show_in_highlight_dialog_func = function() return book_id ~= nil and word ~= "" end,
                callback = function()
                    if highlight_instance.highlight_dialog then
                        UIManager:close(highlight_instance.highlight_dialog)
                    end
                    pcall(function() highlight_instance:clear() end)
                    UIManager:scheduleIn(0.1, function()
                        if is_known then
                            UICodex.showEntryViewer(self_ref, book_id, self_ref.db_codex:findByName(book_id, word))
                        else
                            self_ref:onTrackInCodex(word)
                        end
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
    -- Numeric entries populate the tab's item list directly.
    -- No "text" key: keeps MenuSorter from treating this as an orphan item.
    -- The icon is picked up from this table by TouchMenu when rendering the tab bar.
    local self_ref = self
    menu_items.ko_characters = {
        icon = "appbar.kocharacters",
        -- Extract
        { text = _("Extract characters from this page"),    callback = function() self_ref.extraction:onExtractCurrentPage() end },
        { text = _("Extract codex entries from this page"), callback = function() self_ref:onEnrichCodexFromPage() end },
        { text = _("Scan current chapter"),                 callback = function() self_ref.extraction:onScanChapter() end },
        { text = _("Scan specific chapter"),                callback = function() self_ref.extraction:onScanSpecificChapter() end, separator = true },
        -- View
        { text = _("View saved characters"),   callback = function() self_ref:onViewCharacters() end },
        { text = _("View saved codex entries"), callback = function() UICodex.showBrowser(self_ref) end },
        { text = _("View relationship map"),   callback = function() self_ref:onViewRelationshipMap() end, separator = true },
        -- Manage
        { text = _("Re-analyze character"),       callback = function() self_ref:onReanalyzeCharacterPicker() end },
        { text = _("Detect & merge duplicates"),  callback = function() self_ref:onMergeDetection() end },
        { text = _("Cleanup all characters"),     callback = function() self_ref:onCleanupAllCharacters() end },
        { text = _("Cleanup all codex entries"),  callback = function() self_ref:onCleanupAllCodexEntries() end },
        { text = _("Sync cross-references"),      callback = function() UICharacter.onPropagateCrossReferences(self_ref) end },
        { text = _("Generate portraits"),         callback = function() Portrait.batchGenerate(self_ref) end, separator = true },
        -- Export / misc
        {
            text     = _("Export..."),
            callback = function()
                local export_menu
                export_menu = Menu:new{
                    title      = "Export",
                    item_table = {
                        { text = "Export character list",          callback = function() UIManager:close(export_menu); Export.exportList(self_ref) end },
                        { text = "Export as ZIP (HTML + portraits)", callback = function() UIManager:close(export_menu); Export.exportZip(self_ref) end },
                        { text = "Upload to server",               callback = function() UIManager:close(export_menu); Export.uploadToServer(self_ref) end },
                    },
                    width       = Screen:getWidth(),
                    show_parent = self_ref.ui,
                }
                UIManager:show(export_menu)
            end,
        },
        { text = _("Activity log"), callback = function() self_ref:onViewActivityLog() end },
        { text = _("Settings..."), callback = function() UISettings.open(self_ref) end },
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

local ACTIVITY_LOG_MAX_LINES = 500

function KoCharacters:appendActivityLog(book_id, message)
    if not book_id then return end
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id
    local util = require("util")
    util.makePath(dir)
    local path = dir .. "/activity.log"
    local f = io.open(path, "a")
    if not f then return end
    f:write("[" .. os.date("%Y-%m-%d %H:%M") .. "] " .. message .. "\n")
    f:close()
    -- Trim to cap
    local rf = io.open(path, "r")
    if not rf then return end
    local lines = {}
    for line in rf:lines() do lines[#lines+1] = line end
    rf:close()
    if #lines > ACTIVITY_LOG_MAX_LINES then
        local wf = io.open(path, "w")
        if wf then
            for i = #lines - ACTIVITY_LOG_MAX_LINES + 1, #lines do
                wf:write(lines[i] .. "\n")
            end
            wf:close()
        end
    end
end

function KoCharacters:onViewActivityLog()
    UICharacter.onViewActivityLog(self)
end

-- duplicate/conflict handling moved to ui_character.lua

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

function KoCharacters:getCharactersCleanupPrompt()
    return G_reader_settings:readSetting("kocharacters_characters_cleanup_prompt")
        or GeminiClient.DEFAULT_CHARACTERS_CLEANUP_PROMPT
end

function KoCharacters:getCleanupPrompt()
    return G_reader_settings:readSetting("kocharacters_cleanup_prompt")
        or GeminiClient.DEFAULT_CLEANUP_PROMPT
end

function KoCharacters:getMergeDetectionPrompt()
    return G_reader_settings:readSetting("kocharacters_merge_detection_prompt")
        or GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT
end

function KoCharacters:getUnnamedMatchPrompt()
    return G_reader_settings:readSetting("kocharacters_unnamed_match_prompt")
        or GeminiClient.DEFAULT_UNNAMED_MATCH_PROMPT
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

function KoCharacters:getCodexCreatePrompt()
    return G_reader_settings:readSetting("kocharacters_codex_create_prompt")
        or GeminiClient.DEFAULT_CODEX_CREATE_PROMPT
end

function KoCharacters:getCodexUpdatePrompt()
    return G_reader_settings:readSetting("kocharacters_codex_update_prompt")
        or GeminiClient.DEFAULT_CODEX_UPDATE_PROMPT
end

function KoCharacters:getCodexCleanupPrompt()
    return G_reader_settings:readSetting("kocharacters_codex_cleanup_prompt")
        or GeminiClient.DEFAULT_CODEX_CLEANUP_PROMPT
end

function KoCharacters:getCrossReferencePrompt()
    return G_reader_settings:readSetting("kocharacters_cross_reference_prompt")
        or GeminiClient.DEFAULT_CROSS_REFERENCE_PROMPT
end

function KoCharacters:getGeminiModel()
    return G_reader_settings:readSetting("kocharacters_gemini_model")
        or GeminiClient.DEFAULT_MODEL
end

function KoCharacters:makeGeminiClient()
    return GeminiClient:new(self:getApiKey(), self:getGeminiModel())
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
    UICharacter.onViewRelationshipMap(self)
end

function KoCharacters:onViewUsage()
    UISettings.onViewUsage(self)
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

function KoCharacters:onEditCharacter(book_id, char, refresh_browser_fn, show_viewer_fn)
    UICharacter.onEditCharacter(self, book_id, char, refresh_browser_fn, show_viewer_fn)
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
    UICharacter.showCharacterViewer(self, book_id, char, sort_mode, query, refresh_browser_fn)
end

function KoCharacters:onViewCharacters()
    UICharacter.onViewCharacters(self)
end

function KoCharacters:showCharacterBrowser(book_id, sort_mode, query)
    UICharacter.showCharacterBrowser(self, book_id, sort_mode, query)
end

-- portrait and export methods moved to portrait.lua and export.lua

function KoCharacters:onCleanupAllCharacters()
    UICharacter.onCleanupAllCharacters(self)
end

function KoCharacters:onCleanupAllCodexEntries()
    UICodex.onCleanupAllEntries(self)
end

function KoCharacters:onMergeDetection()
    UICharacter.onMergeDetection(self)
end

-- settings methods moved to ui_settings.lua

function KoCharacters:onReanalyzeCharacter(book_id, char)
    UICharacter.onReanalyzeCharacter(self, book_id, char)
end

function KoCharacters:onReanalyzeCharacterPicker()
    UICharacter.onReanalyzeCharacterPicker(self)
end

function KoCharacters:onCleanCharacter(book_id, char_name)
    UICharacter.onCleanCharacter(self, book_id, char_name)
end

function KoCharacters:onWordCharacterLookup(word)
    UICharacter.onWordCharacterLookup(self, word)
end

-- ---------------------------------------------------------------------------
-- Codex actions
-- ---------------------------------------------------------------------------

function KoCharacters:onTrackInCodex(word)
    local book_id = self:getBookID()
    if not book_id then self:showMsg("Cannot determine book ID."); return end
    local api_key = self:getApiKey()
    if not api_key or api_key == "" then self:showMsg("API key not set. Configure in settings."); return end

    local page = self:getCurrentPage()
    local page_text = ""
    if page then
        local text = EpubReader.getPageText(self.ui.document, page)
        if text then page_text = text end
    end

    local DataStorage = require("datastorage")
    local tmp_dir     = DataStorage:getDataDir() .. "/kocharacters"
    local req_file    = tmp_dir .. "/.codex_create_req.json"
    local resp_file   = tmp_dir .. "/.codex_create_resp.json"
    os.remove(resp_file)

    local client        = self:makeGeminiClient()
    local ok, build_err = client:buildCodexCreateRequestFile(req_file, page_text, word, self:getCodexCreatePrompt())
    if not ok then
        self:showMsg("Codex: failed to build request: " .. tostring(build_err))
        return
    end

    local url        = client:asyncExtractUrl()
    local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("(.+/)")
    local helper     = plugin_dir .. "async_request.lua"
    local lua_cmd    = string.format(
        'cd /mnt/us/koreader && ./luajit "%s" "%s" "%s" "%s" >/dev/null 2>&1 &',
        helper, req_file, url, resp_file)
    os.execute(lua_cmd)

    self.extraction:showScanIndicator()

    local poll_start   = os.time()
    local poll_timeout = 35
    local self_ref     = self

    local function poll()
        if os.time() - poll_start > poll_timeout then
            os.remove(req_file)
            os.remove(resp_file)
            self_ref.extraction:hideScanIndicator()
            self_ref:showMsg("Codex: request timed out.")
            return
        end

        local f = io.open(resp_file, "r")
        if not f then
            UIManager:scheduleIn(1.5, poll)
            return
        end
        local size = f:seek("end")
        f:close()
        if not size or size == 0 then
            UIManager:scheduleIn(1.5, poll)
            return
        end

        self_ref.extraction:hideScanIndicator()
        os.remove(req_file)
        local entry, err, usage = client:parseCodexCreateResponseFile(resp_file)
        os.remove(resp_file)

        if err then
            self_ref:showMsg("Codex: " .. err)
            self_ref:appendActivityLog(book_id, "Codex: failed to track \"" .. word .. "\": " .. err)
            return
        end

        if usage then self_ref:recordUsage(usage) end
        entry.name = entry.name or word
        local _, added = self_ref.db_codex:merge(book_id, { entry }, page)
        local verb = added > 0 and "added to codex." or "updated in codex."
        self_ref:showMsg("\u{25C8} \"" .. word .. "\" " .. verb, 3)
        self_ref:appendActivityLog(book_id, "Codex: tracked \"" .. word .. "\" (p." .. tostring(page or "?") .. ")")
    end

    UIManager:scheduleIn(1.5, poll)
end

function KoCharacters:onEnrichCodexFromPage()
    local book_id = self:getBookID()
    if not book_id then self:showMsg("Cannot determine book ID."); return end
    local api_key = self:getApiKey()
    if not api_key or api_key == "" then self:showMsg("API key not set. Configure in settings."); return end

    local page = self:getCurrentPage()
    local page_text = ""
    if page then
        local text = EpubReader.getPageText(self.ui.document, page)
        if text then page_text = text end
    end

    local entries = self.db_codex:getEntriesForPage(book_id, page_text)
    if #entries == 0 then
        self:showMsg("No tracked codex entries found on this page.")
        return
    end

    local working = InfoMessage:new{ text = "Enriching " .. #entries .. " codex entr" .. (#entries == 1 and "y" or "ies") .. "\u{2026}" }
    UIManager:show(working)
    UIManager:forceRePaint()

    local client = self:makeGeminiClient()
    local updated, err, usage = client:enrichCodexEntries(page_text, entries, self:getCodexUpdatePrompt())
    UIManager:close(working)

    if err then
        self:showMsg("Codex: " .. err)
        self:appendActivityLog(book_id, "Codex enrich p." .. tostring(page or "?") .. ": " .. err)
        return
    end

    if usage then self:recordUsage(usage) end

    if not updated or #updated == 0 then
        self:showMsg("Codex: no entries updated (none appeared in this passage).")
        return
    end

    self.db_codex:merge(book_id, updated, page)
    self:showMsg("\u{25C8} " .. #updated .. " codex entr" .. (#updated == 1 and "y" or "ies") .. " updated.", 3)
    self:appendActivityLog(book_id, "Codex enrich p." .. tostring(page or "?") .. ": " .. #updated .. " updated")
end

return KoCharacters
