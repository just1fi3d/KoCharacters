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
local Portrait     = require("portrait")
local Export       = require("export")
local UISettings   = require("ui_settings")
local UICharacter  = require("ui_character")
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
    self.db = DBCharacter
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
            UICharacter.handleIncomingConflicts(self_ref, book_id, new_chars, on_done, page_num, skip_cleanup)
        end,
        check_warn_duplicates = function(book_id, on_continue)
            UICharacter.checkAndWarnDuplicates(self_ref, book_id, on_continue)
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
                        UICharacter.onWordCharacterLookup(self_ref, word)
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

return KoCharacters
