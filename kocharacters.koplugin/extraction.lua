-- extraction.lua
-- KoCharacters: auto-extract queue, chapter scan, manual extract, pending pages

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local TextViewer  = require("ui/widget/textviewer")
local Menu        = require("ui/widget/menu")
local Screen      = require("device").screen
local logger      = require("logger")
local _           = require("gettext")

local GeminiClient = require("gemini_client")
local UtilsCharacter = require("utils_character")
local EpubReader   = require("epub_reader")

local Extraction = {}
Extraction.__index = Extraction

-- Returns true if character c is mentioned in text_lower.
-- Checks full name, aliases, and individual name tokens (≥4 chars) with word boundaries,
-- so "Marino" matches a page that says "Marino" even when the full name is "Helena Marino".
local function charInText(c, text_lower)
    local function wordFind(pattern)
        local pos = 1
        while true do
            local si, ei = text_lower:find(pattern, pos, true)
            if not si then return false end
            local before = si > 1           and text_lower:sub(si-1, si-1) or " "
            local after  = ei < #text_lower and text_lower:sub(ei+1, ei+1) or " "
            if not before:match("[%a%d_%-]") and not after:match("[%a%d_%-]") then return true end
            pos = si + 1
        end
    end
    local name_lower = (c.name or ""):lower()
    if wordFind(name_lower) then return true end
    for _, alias in ipairs(c.aliases or {}) do
        if alias ~= "" and wordFind(alias:lower()) then return true end
    end
    for token in name_lower:gmatch("%S+") do
        if #token >= 4 and wordFind(token) then return true end
    end
    return false
end

-- deps:
--   db            (value)    — DBCharacter instance
--   ui            (value)    — plugin's self.ui (live reference; .document/.view populated later)
--   get_api_key              (function) — returns current Gemini API key string
--   get_prompt               (function) — returns current extraction prompt string
--   get_codex_update_prompt  (function) — returns current codex update prompt string
--   get_book_id   (function) — returns current book ID or nil
--   record_usage  (function) — records API usage stats
--   show_msg      (function) — shows an InfoMessage toast
--   append_log    (function) — appends a line to the book's activity log
--   on_conflicts  (function) — handleIncomingConflicts callback (ui_character, injected to break circular dep)
--   check_warn_duplicates (function) — checkAndWarnDuplicates callback (same reason)
function Extraction.new(deps)
    local self = setmetatable({}, Extraction)
    -- Static values
    self.db       = deps.db
    self.db_codex = deps.db_codex
    self.ui       = deps.ui
    -- Mutable/behavioural deps
    self._get_api_key              = deps.get_api_key
    self._get_prompt               = deps.get_prompt
    self._get_codex_update_prompt  = deps.get_codex_update_prompt
    self._get_book_id              = deps.get_book_id
    self._record_usage    = deps.record_usage
    self._show_msg        = deps.show_msg
    self._append_log      = deps.append_log
    self._on_conflicts    = deps.on_conflicts
    self._check_warn_dups = deps.check_warn_duplicates
    -- Extraction state
    self._auto_extracting  = false
    self._pending_extract  = nil
    self._extract_queue    = {}
    self._extract_running  = false
    self._poll_timer       = nil
    self._curl_req_file    = nil
    self._curl_resp_file   = nil
    self._pending_notified = false
    -- Page-count cache for scanned-history invalidation
    self._cached_page_count     = nil
    -- In-memory set of pages where codex enrichment has run this session.
    -- Cleared when a new codex entry is added so new entries get picked up.
    self._codex_scanned         = {}
    -- Pages where codex enrichment hit a retryable API error and had entries to match.
    -- Drained (re-enqueued) after the next successful codex call.
    self._codex_pending         = {}
    -- Indicator widget state
    self._scan_indicator        = nil
    self._count_indicator       = nil
    self._count_indicator_timer = nil
    return self
end

function Extraction:_getCurrentPage()
    local page
    pcall(function() page = self.ui.view.state.page end)
    return page
end

-- ---------------------------------------------------------------------------
-- Scan indicators
-- ---------------------------------------------------------------------------

function Extraction:showScanIndicator()
    if G_reader_settings:readSetting("kocharacters_scan_indicator") == false then return end
    if self._scan_indicator then return end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget    = require("ui/widget/imagewidget")
    local Blitbuffer     = require("ffi/blitbuffer")
    local icon_path      = debug.getinfo(1, "S").source:sub(2):match("(.+/)") .. "assets/scanning.svg"
    self._scan_indicator = FrameContainer:new{
        toast      = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 4,
        ImageWidget:new{
            file   = icon_path,
            width  = 40,
            height = 40,
        },
    }
    UIManager:show(self._scan_indicator)
    UIManager:setDirty(self._scan_indicator, "fast")
    UIManager:forceRePaint()
end

function Extraction:hideScanIndicator()
    if self._scan_indicator then
        UIManager:close(self._scan_indicator)
        self._scan_indicator = nil
        UIManager:setDirty(nil, "fast")
        UIManager:forceRePaint()
    end
end

function Extraction:showExtractedCount(count, pageno)
    local level = G_reader_settings:readSetting("kocharacters_toast_level") or "full"
    if level == "off" or level == "errors" then return end
    if self._count_indicator then
        UIManager:close(self._count_indicator)
        if self._count_indicator_timer then
            UIManager:unschedule(self._count_indicator_timer)
        end
    end
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local ImageWidget     = require("ui/widget/imagewidget")
    local TextWidget      = require("ui/widget/textwidget")
    local Font            = require("ui/font")
    local Blitbuffer      = require("ffi/blitbuffer")
    local plugin_dir      = debug.getinfo(1, "S").source:sub(2):match("(.+/)")
    self._count_indicator = FrameContainer:new{
        toast      = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 4,
        HorizontalGroup:new{
            ImageWidget:new{
                file   = plugin_dir .. "assets/characters.svg",
                width  = 40,
                height = 40,
            },
            TextWidget:new{
                text = (level == "full" and pageno) and ("p" .. pageno .. ":" .. count) or tostring(count),
                face = Font:getFace("cfont", 20),
            },
        },
    }
    UIManager:show(self._count_indicator)
    UIManager:setDirty(self._count_indicator, "fast")
    UIManager:forceRePaint()
    self._count_indicator_timer = function()
        self._count_indicator_timer = nil
        if self._count_indicator then
            UIManager:close(self._count_indicator)
            UIManager:setDirty(nil, "fast")
            UIManager:forceRePaint()
            self._count_indicator = nil
        end
    end
    UIManager:scheduleIn(4, self._count_indicator_timer)
end

function Extraction:showExtractError()
    local level = G_reader_settings:readSetting("kocharacters_toast_level") or "full"
    if level == "off" then return end
    if self._count_indicator then
        UIManager:close(self._count_indicator)
        if self._count_indicator_timer then
            UIManager:unschedule(self._count_indicator_timer)
        end
    end
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget      = require("ui/widget/textwidget")
    local Font            = require("ui/font")
    local Blitbuffer      = require("ffi/blitbuffer")
    self._count_indicator = FrameContainer:new{
        toast      = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 4,
        HorizontalGroup:new{
            TextWidget:new{
                text = "⚠ API busy",
                face = Font:getFace("cfont", 20),
            },
        },
    }
    UIManager:show(self._count_indicator)
    UIManager:setDirty(self._count_indicator, "fast")
    UIManager:forceRePaint()
    self._count_indicator_timer = function()
        self._count_indicator_timer = nil
        if self._count_indicator then
            UIManager:close(self._count_indicator)
            UIManager:setDirty(nil, "fast")
            UIManager:forceRePaint()
            self._count_indicator = nil
        end
    end
    UIManager:scheduleIn(4, self._count_indicator_timer)
end

function Extraction:showCodexExtractedCount(count, pageno)
    local level = G_reader_settings:readSetting("kocharacters_toast_level") or "full"
    if level == "off" or level == "errors" then return end
    if self._count_indicator then
        UIManager:close(self._count_indicator)
        if self._count_indicator_timer then
            UIManager:unschedule(self._count_indicator_timer)
        end
    end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextWidget     = require("ui/widget/textwidget")
    local Font           = require("ui/font")
    local Blitbuffer     = require("ffi/blitbuffer")
    self._count_indicator = FrameContainer:new{
        toast      = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 4,
        TextWidget:new{
            text = (level == "full" and pageno) and ("\u{25C8} p" .. pageno .. ":" .. count) or ("\u{25C8} " .. tostring(count)),
            face = Font:getFace("cfont", 20),
        },
    }
    UIManager:show(self._count_indicator)
    UIManager:setDirty(self._count_indicator, "fast")
    UIManager:forceRePaint()
    self._count_indicator_timer = function()
        self._count_indicator_timer = nil
        if self._count_indicator then
            UIManager:close(self._count_indicator)
            UIManager:setDirty(nil, "fast")
            UIManager:forceRePaint()
            self._count_indicator = nil
        end
    end
    UIManager:scheduleIn(4, self._count_indicator_timer)
end

-- ---------------------------------------------------------------------------
-- Scanned-history invalidation
-- ---------------------------------------------------------------------------

-- Checks whether the document's page count has changed since it was last recorded
-- (e.g. font size / margin adjustment causes re-render with different pagination).
-- If so, wipes the stale scanned list so auto-extract resumes on all pages.
-- Caches the last-seen count so the file system is only touched when the count changes.
function Extraction:_checkAndInvalidateScannedPages(book_id)
    local total_pages
    pcall(function() total_pages = self.ui.document:getPageCount() end)
    if not total_pages then return end

    if self._cached_page_count == total_pages then return end
    self._cached_page_count = total_pages

    local stored_count = self.db:getScannedPageCount(book_id)
    if stored_count ~= nil and stored_count ~= total_pages then
        self.db:clearScannedPages(book_id)
        logger.info(string.format(
            "KoCharacters: page count changed (%d → %d), cleared scan history",
            stored_count, total_pages))
    end
    self.db:saveScannedPageCount(book_id, total_pages)
end

-- ---------------------------------------------------------------------------
-- Page turn debounce
-- ---------------------------------------------------------------------------

function Extraction:onPageChanged(pageno)
    if not G_reader_settings:readSetting("kocharacters_auto_extract") then return end

    if self._pending_extract then
        UIManager:unschedule(self._pending_extract)
        self._pending_extract = nil
    end

    if self._auto_extracting then return end

    local book_id = self._get_book_id()
    if not book_id then return end

    self:_checkAndInvalidateScannedPages(book_id)

    local char_scanned = self.db:isPageScanned(book_id, pageno)
    if char_scanned then
        if self._codex_scanned[pageno] then return end
        if #self.db_codex:load(book_id) == 0 then return end
    end

    -- Re-render the indicator so it survives the e-ink page-turn refresh
    if self._extract_running and self._scan_indicator then
        UIManager:setDirty(self._scan_indicator, "fast")
    end

    local delay = G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10
    self._pending_extract = function()
        self._pending_extract = nil
        if self:_getCurrentPage() ~= pageno then return end
        self:_enqueuePageJobs(pageno, char_scanned)
    end
    UIManager:scheduleIn(delay, self._pending_extract)
end

-- ---------------------------------------------------------------------------
-- Reader lifecycle events
-- ---------------------------------------------------------------------------

function Extraction:onReaderReady()
    local book_id = self._get_book_id()
    if not book_id then return end

    self:_checkAndInvalidateScannedPages(book_id)

    -- Only prompt once per book per session
    local greeted = G_reader_settings:readSetting("kocharacters_greeted_books") or {}
    if greeted[book_id] then return end
    greeted[book_id] = true
    G_reader_settings:saveSetting("kocharacters_greeted_books", greeted)

    local auto_on = G_reader_settings:readSetting("kocharacters_auto_extract") and true or false
    local msg, ok_text, cancel_text
    if auto_on then
        msg         = "KoCharacters: auto-extract is ON.\nKeep it enabled for this book?"
        ok_text     = "Keep ON"
        cancel_text = "Turn OFF"
    else
        msg         = "KoCharacters: auto-extract is OFF.\nEnable it for this book?"
        ok_text     = "Enable"
        cancel_text = "Keep OFF"
    end

    UIManager:show(ConfirmBox:new{
        text            = msg,
        ok_text         = ok_text,
        cancel_text     = cancel_text,
        ok_callback     = function()
            G_reader_settings:saveSetting("kocharacters_auto_extract", true)
        end,
        cancel_callback = function()
            G_reader_settings:saveSetting("kocharacters_auto_extract", false)
        end,
    })
end

function Extraction:cleanup()
    if self._poll_timer then
        UIManager:unschedule(self._poll_timer)
        self._poll_timer = nil
    end
    if self._curl_req_file  then os.remove(self._curl_req_file);  self._curl_req_file  = nil end
    if self._curl_resp_file then os.remove(self._curl_resp_file); self._curl_resp_file = nil end
    self._extract_queue   = {}
    self._extract_running = false
    self._codex_scanned   = {}
    self._codex_pending   = {}
end

-- ---------------------------------------------------------------------------
-- Async queue
-- ---------------------------------------------------------------------------

-- char_scanned: true if the character page-scan is already done (codex-only job)
function Extraction:_enqueuePageJobs(pageno, char_scanned)
    local book_id = self._get_book_id()
    if not book_id then return end

    local has_char, has_codex = false, false
    for _, job in ipairs(self._extract_queue) do
        if job.pageno == pageno then
            if job.type == "character" then has_char = true end
            if job.type == "codex"     then has_codex = true end
        end
    end

    if not char_scanned and not has_char then
        -- Character job also runs codex enrichment on the same page text
        table.insert(self._extract_queue, { type = "character", pageno = pageno })
    elseif char_scanned and not has_codex then
        table.insert(self._extract_queue, { type = "codex", pageno = pageno })
    end

    if not self._extract_running then
        self:_processNextInQueue()
    end
end

function Extraction:_processNextInQueue()
    if #self._extract_queue == 0 then
        self._extract_running = false
        self:hideScanIndicator()
        return
    end

    local api_key = self._get_api_key()
    if api_key == "" then
        self._extract_queue   = {}
        self._extract_running = false
        return
    end

    self._extract_running = true
    local job     = table.remove(self._extract_queue, 1)
    local book_id = self._get_book_id()
    if not book_id then self:_processNextInQueue(); return end

    if job.type == "character" then
        self:_processCharacterJob(job, book_id)
    elseif job.type == "codex" then
        self:_processCodexJob(job, book_id)
    else
        self:_processNextInQueue()
    end
end

function Extraction:_processCharacterJob(job, book_id)
    local pageno = job.pageno

    -- Re-check: page may have been scanned by a previous queue item
    if self.db:isPageScanned(book_id, pageno) then
        self:_processNextInQueue()
        return
    end

    local page_text, err = EpubReader.getPageText(self.ui.document, pageno)
    if not page_text or #page_text < 20 then
        self.db:markPageScanned(book_id, pageno)
        self:_processNextInQueue()
        return
    end

    -- Build existing/skip lists
    local existing   = self.db:load(book_id)
    local page_lower = page_text:lower()
    local skip_names, chars_in_text = {}, {}
    for _, c in ipairs(existing) do
        if charInText(c, page_lower) then table.insert(chars_in_text, c)
        else table.insert(skip_names, c.name) end
    end

    local DataStorage    = require("datastorage")
    local tmp_dir        = DataStorage:getDataDir() .. "/kocharacters"
    self._curl_req_file  = tmp_dir .. "/.async_req_"  .. tostring(pageno) .. ".json"
    self._curl_resp_file = tmp_dir .. "/.async_resp_" .. tostring(pageno) .. ".json"
    os.remove(self._curl_resp_file)

    local api_key    = self._get_api_key()
    local client     = GeminiClient:new(api_key)
    local ok, build_err = client:buildRequestFile(
        self._curl_req_file, page_text, skip_names, chars_in_text,
        self._get_prompt(), self.db:loadBookContext(book_id))

    if not ok then
        logger.warn("KoCharacters: async buildRequestFile failed: " .. tostring(build_err))
        self.db:markPageScanned(book_id, pageno)
        self:_processNextInQueue()
        return
    end

    local url        = client:asyncExtractUrl()
    local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("(.+/)")
    local helper     = plugin_dir .. "async_request.lua"
    local lua_cmd    = string.format(
        'cd /mnt/us/koreader && ./luajit "%s" "%s" "%s" "%s" >/dev/null 2>&1 &',
        helper, self._curl_req_file, url, self._curl_resp_file)
    logger.info("KoCharacters: async launch page=" .. tostring(pageno))
    os.execute(lua_cmd)

    self:showScanIndicator()

    local poll_start   = os.time()
    local poll_timeout = 35
    local page_ref     = pageno
    local book_ref     = book_id
    local resp_file    = self._curl_resp_file
    local req_file     = self._curl_req_file
    local self_ref     = self

    local function poll()
        self_ref._poll_timer = nil

        if os.time() - poll_start > poll_timeout then
            logger.warn("KoCharacters: async poll timeout for page " .. tostring(page_ref))
            os.remove(req_file)
            os.remove(resp_file)
            self_ref.db:markPagePending(book_ref, page_ref)
            self_ref:showExtractError()
            self_ref._append_log(book_ref, "Auto-extract p." .. page_ref .. ": timed out — will retry")
            self_ref:_processNextInQueue()
            return
        end

        local f = io.open(resp_file, "r")
        if not f then
            self_ref._poll_timer = function() poll() end
            UIManager:scheduleIn(1.5, self_ref._poll_timer)
            return
        end
        local size = f:seek("end")
        f:close()
        if not size or size == 0 then
            self_ref._poll_timer = function() poll() end
            UIManager:scheduleIn(1.5, self_ref._poll_timer)
            return
        end

        logger.info("KoCharacters: async response ready page=" .. tostring(page_ref) .. " size=" .. tostring(size))
        os.remove(req_file)
        local characters, api_err, usage, book_context = client:parseResponseFile(resp_file)
        os.remove(resp_file)

        if api_err then
            logger.warn("KoCharacters: async api_err page=" .. tostring(page_ref) .. ": " .. tostring(api_err))
            local is_retryable = type(api_err) == "string"
                and (api_err:find("Network error") or api_err:find("503") or api_err:find("429")
                     or api_err:find("quota") or api_err:find("high demand") or api_err:find("overload"))
            local err_str = tostring(api_err):sub(1, 120)
            if is_retryable then
                local retries = (job.retries or 0)
                if retries < 2 then
                    local delay = 8 * (2 ^ retries)
                    job.retries = retries + 1
                    table.insert(self_ref._extract_queue, 1, job)
                    self_ref._append_log(book_ref, "Auto-extract p." .. page_ref .. ": API busy — retry " .. job.retries .. "/2 in " .. delay .. "s")
                    UIManager:scheduleIn(delay, function() self_ref:_processNextInQueue() end)
                else
                    self_ref.db:markPagePending(book_ref, page_ref)
                    self_ref:showExtractError()
                    self_ref._append_log(book_ref, "Auto-extract p." .. page_ref .. ": API busy — max retries, marked pending (" .. err_str .. ")")
                    self_ref:_processNextInQueue()
                end
            else
                self_ref.db:markPageScanned(book_ref, page_ref)
                self_ref._append_log(book_ref, "Auto-extract p." .. page_ref .. ": API error — skipped (" .. err_str .. ")")
                self_ref:_processNextInQueue()
            end
            return
        end

        if usage then self_ref._record_usage(usage) end
        if book_context and book_context ~= "" then
            self_ref.db:saveBookContext(book_ref, book_context)
        end

        self_ref.db:markPageScanned(book_ref, page_ref)

        if not characters or #characters == 0 then
            self_ref:showExtractedCount(0, page_ref)
            self_ref:_runCodexEnrichment(book_ref, page_ref, page_text, function()
                self_ref:_checkAndPromptPendingPages(book_ref)
                self_ref:_processNextInQueue()
            end)
            return
        end

        self_ref._on_conflicts(book_ref, characters, function(resolved)
            if #resolved > 0 then
                self_ref.db:merge(book_ref, resolved, page_ref)
            end
            local _names = {}
            for _, c in ipairs(characters) do table.insert(_names, c.name or "?") end
            self_ref._append_log(book_ref, "Auto-extract p." .. page_ref .. ": " .. #characters .. " character(s) found (" .. table.concat(_names, ", ") .. ")")
            self_ref:showExtractedCount(#characters, page_ref)
            self_ref:_runCodexEnrichment(book_ref, page_ref, page_text, function()
                self_ref:_checkAndPromptPendingPages(book_ref)
                self_ref:_processNextInQueue()
            end)
        end, page_ref, true)
    end

    self._poll_timer = function() poll() end
    UIManager:scheduleIn(1.5, self._poll_timer)
end

function Extraction:_processCodexJob(job, book_id)
    local pageno    = job.pageno
    local page_text = EpubReader.getPageText(self.ui.document, pageno)
    if not page_text or #page_text < 20 then
        self:_processNextInQueue()
        return
    end
    self:_runCodexEnrichment(book_id, pageno, page_text, function()
        self:_processNextInQueue()
    end)
end

-- Async codex enrichment — spawns a subprocess and polls, then calls on_done when finished.
-- retries tracks how many times this page has already been retried (default 0, max 2).
function Extraction:_runCodexEnrichment(book_id, pageno, page_text, on_done, retries)
    if self._codex_scanned[pageno] then
        if on_done then on_done() end
        return
    end

    local entries = self.db_codex:getEntriesForPage(book_id, page_text)
    if #entries == 0 then
        if on_done then on_done() end
        return
    end

    self:showScanIndicator()

    local api_key     = self._get_api_key()
    local client      = GeminiClient:new(api_key)
    local DataStorage = require("datastorage")
    local tmp_dir     = DataStorage:getDataDir() .. "/kocharacters"
    local req_file    = tmp_dir .. "/.codex_req_"  .. tostring(pageno) .. ".json"
    local resp_file   = tmp_dir .. "/.codex_resp_" .. tostring(pageno) .. ".json"
    os.remove(resp_file)

    local ok, build_err = client:buildCodexRequestFile(req_file, page_text, entries,
        self._get_codex_update_prompt and self._get_codex_update_prompt())
    if not ok then
        logger.warn("KoCharacters: codex buildRequestFile failed: " .. tostring(build_err))
        self._codex_scanned[pageno] = true
        if on_done then on_done() end
        return
    end

    local url        = client:asyncExtractUrl()
    local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("(.+/)")
    local helper     = plugin_dir .. "async_request.lua"
    local lua_cmd    = string.format(
        'cd /mnt/us/koreader && ./luajit "%s" "%s" "%s" "%s" >/dev/null 2>&1 &',
        helper, req_file, url, resp_file)
    logger.info("KoCharacters: codex async launch page=" .. tostring(pageno))
    os.execute(lua_cmd)

    local poll_start   = os.time()
    local poll_timeout = 35
    local self_ref     = self

    local function poll()
        if os.time() - poll_start > poll_timeout then
            logger.warn("KoCharacters: codex poll timeout page=" .. tostring(pageno))
            os.remove(req_file)
            os.remove(resp_file)
            self_ref._codex_pending[pageno] = true
            self_ref:showExtractError()
            self_ref._append_log(book_id, "Codex auto-enrich p." .. pageno .. ": timed out — will retry")
            if on_done then on_done() end
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

        os.remove(req_file)
        local updated, api_err, usage = client:parseCodexResponseFile(resp_file)
        os.remove(resp_file)

        if api_err then
            local is_retryable = type(api_err) == "string"
                and (api_err:find("Network error") or api_err:find("503")
                     or api_err:find("429") or api_err:find("quota") or api_err:find("overload"))
            local err_str = tostring(api_err):sub(1, 120)
            if is_retryable then
                local r = retries or 0
                if r < 2 then
                    local delay = 8 * (2 ^ r)
                    self_ref._append_log(book_id, "Codex auto-enrich p." .. pageno .. ": API busy — retry " .. (r + 1) .. "/2 in " .. delay .. "s")
                    UIManager:scheduleIn(delay, function()
                        self_ref:_runCodexEnrichment(book_id, pageno, page_text, on_done, r + 1)
                    end)
                else
                    self_ref._codex_pending[pageno] = true
                    self_ref:showExtractError()
                    self_ref._append_log(book_id, "Codex auto-enrich p." .. pageno .. ": API busy — max retries, marked pending (" .. err_str .. ")")
                    if on_done then on_done() end
                end
            else
                self_ref._codex_scanned[pageno] = true
                self_ref._append_log(book_id, "Codex auto-enrich p." .. pageno .. ": API error — skipped (" .. err_str .. ")")
                if on_done then on_done() end
            end
            return
        end

        if usage then self_ref._record_usage(usage) end
        self_ref._codex_scanned[pageno] = true
        self_ref._codex_pending[pageno] = nil
        if updated and #updated > 0 then
            self_ref.db_codex:merge(book_id, updated, pageno)
            self_ref.db_codex:normalizeConnections(book_id, self_ref.db:load(book_id))
            self_ref:showCodexExtractedCount(#updated, pageno)
            local _names = {}
            for _, e in ipairs(updated) do table.insert(_names, e.name or "?") end
            self_ref._append_log(book_id, "Codex auto-enrich p." .. pageno .. ": " .. #updated .. " updated (" .. table.concat(_names, ", ") .. ")")
        end
        self_ref:_drainCodexPending()
        if on_done then on_done() end
    end

    UIManager:scheduleIn(1.5, poll)
end

function Extraction:clearCodexScanned()
    self._codex_scanned = {}
end

-- Re-enqueue pages that had a retryable codex error. Called after a successful
-- codex API response, while the API is demonstrably reachable.
function Extraction:_drainCodexPending()
    local pending = {}
    for pageno in pairs(self._codex_pending) do
        table.insert(pending, pageno)
    end
    if #pending == 0 then return end
    self._codex_pending = {}
    for _, pageno in ipairs(pending) do
        if not self._codex_scanned[pageno] then
            local already = false
            for _, job in ipairs(self._extract_queue) do
                if job.pageno == pageno and job.type == "codex" then
                    already = true; break
                end
            end
            if not already then
                table.insert(self._extract_queue, { type = "codex", pageno = pageno })
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Sync extraction (legacy path — currently unused, kept for reference)
-- ---------------------------------------------------------------------------

function Extraction:autoExtract(page_num)
    if self._auto_extracting then return end
    local api_key = self._get_api_key()
    if api_key == "" then return end
    local book_id = self._get_book_id()
    if not book_id then return end

    local page_text, err = EpubReader.getPageText(self.ui.document, page_num)
    if not page_text then
        logger.warn("KoCharacters: autoExtract getText failed: " .. tostring(err))
        if page_num then self.db:markPageScanned(book_id, page_num) end
        return
    end

    self._auto_extracting = true
    self:showScanIndicator()

    local existing   = self.db:load(book_id)
    local page_lower = page_text:lower()
    local skip_names, chars_in_text = {}, {}
    for _, c in ipairs(existing) do
        if charInText(c, page_lower) then table.insert(chars_in_text, c)
        else table.insert(skip_names, c.name) end
    end

    local client = GeminiClient:new(api_key)
    local characters, api_err, usage, book_context
    local ok, call_err = pcall(function()
        characters, api_err, usage, book_context = client:extractCharacters(
            page_text, skip_names, chars_in_text, self._get_prompt(),
            self.db:loadBookContext(book_id))
    end)
    if ok and not api_err then self._record_usage(usage) end
    if ok and book_context and book_context ~= "" then
        self.db:saveBookContext(book_id, book_context)
    end

    if not ok or api_err then
        self:hideScanIndicator()
        self._auto_extracting = false
        local is_network = not ok or (type(api_err) == "string" and api_err:find("Network error"))
        if is_network then
            if page_num then self.db:markPagePending(book_id, page_num) end
        else
            if page_num then self.db:markPageScanned(book_id, page_num) end
        end
        return
    end

    if page_num then self.db:markPageScanned(book_id, page_num) end

    if not characters or #characters == 0 then
        self:hideScanIndicator()
        self._auto_extracting = false
        return
    end

    local cur_page = page_num or self:_getCurrentPage()
    self._on_conflicts(book_id, characters, function(resolved)
        if #resolved > 0 then self.db:merge(book_id, resolved, cur_page) end
        self:hideScanIndicator()
        self._auto_extracting = false
        self:showExtractedCount(#characters, cur_page)
        self:_checkAndPromptPendingPages(book_id)
    end, cur_page, true)
end

-- ---------------------------------------------------------------------------
-- Pending pages
-- ---------------------------------------------------------------------------

function Extraction:_checkAndPromptPendingPages(book_id)
    if self._pending_notified then return end
    local char_pages  = self.db:loadPendingPages(book_id)
    local codex_count = 0
    for _ in pairs(self._codex_pending) do codex_count = codex_count + 1 end
    if #char_pages == 0 and codex_count == 0 then return end
    self._pending_notified = true

    local parts = {}
    if #char_pages > 0 then
        parts[#parts+1] = #char_pages .. " character page(s)"
    end
    if codex_count > 0 then
        parts[#parts+1] = codex_count .. " codex page(s)"
    end

    local self_ref = self
    UIManager:show(ConfirmBox:new{
        text    = table.concat(parts, " and ") .. " couldn't be scanned while the API was busy.\nRetry now?",
        ok_text = "Retry",
        ok_callback = function()
            if #char_pages > 0 then self_ref:onScanPendingPages(book_id) end
            if codex_count > 0 then
                self_ref:_drainCodexPending()
                if not self_ref._extract_running and #self_ref._extract_queue > 0 then
                    self_ref:_processNextInQueue()
                end
            end
        end,
    })
end

function Extraction:onScanPendingPages(book_id)
    book_id = book_id or self._get_book_id()
    if not book_id then return end

    local pages = self.db:loadPendingPages(book_id)
    if #pages == 0 then self._show_msg("No offline-pending pages."); return end
    table.sort(pages)

    local client      = GeminiClient:new(self._get_api_key())
    local scanned_ok  = {}
    local total_found = 0
    local total       = #pages
    local self_ref    = self
    local progress_msg

    local function finish(stopped_early)
        if progress_msg then UIManager:close(progress_msg); progress_msg = nil end
        self_ref.db:removePendingPages(book_id, scanned_ok)
        for _, p in ipairs(scanned_ok) do self_ref.db:markPageScanned(book_id, p) end
        local remaining = self_ref.db:loadPendingPages(book_id)
        local msg = "Offline scan complete.\n"
            .. #scanned_ok .. "/" .. total .. " pages scanned.\n"
            .. "Characters found/updated: " .. total_found
        if #remaining > 0 then
            msg = msg .. "\n" .. #remaining .. " page(s) still pending."
        end
        if stopped_early then
            msg = "Network error during scan.\n"
                .. #scanned_ok .. " page(s) scanned before failure.\n"
                .. (total - #scanned_ok) .. " page(s) still pending."
        end
        self_ref._show_msg(msg, 6)
    end

    local function processPage(idx)
        if idx > total then finish(false); return end

        local page_num = pages[idx]
        if progress_msg then UIManager:close(progress_msg) end
        progress_msg = InfoMessage:new{
            text = "Scanning offline pages...\n" .. idx .. "/" .. total
                   .. " (page " .. page_num .. ")",
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        local page_text = EpubReader.getPageText(self_ref.ui.document, page_num)
        if not page_text or #page_text < 20 then
            table.insert(scanned_ok, page_num)
            UIManager:scheduleIn(0.1, function() processPage(idx + 1) end)
            return
        end

        local all_chars  = self_ref.db:load(book_id)
        local page_lower = page_text:lower()
        local chars_in_text, skip_names = {}, {}
        for _, c in ipairs(all_chars) do
            if charInText(c, page_lower) then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end

        local characters, api_err, usage, book_context
        local ok, call_err = pcall(function()
            characters, api_err, usage, book_context = client:extractCharacters(
                page_text, skip_names, chars_in_text, self_ref._get_prompt(),
                self_ref.db:loadBookContext(book_id))
        end)
        if ok and not api_err then self_ref._record_usage(usage) end
        if ok and book_context and book_context ~= "" then
            self_ref.db:saveBookContext(book_id, book_context)
        end

        local is_network = not ok or (type(api_err) == "string" and api_err:find("Network error"))
        if is_network then
            finish(true)
            return
        end

        if api_err then
            local err_str = tostring(api_err):sub(1, 120)
            logger.warn("KoCharacters: pending scan p" .. page_num .. ": " .. err_str)
            local is_retryable = api_err:find("Network error") or api_err:find("503")
                or api_err:find("429") or api_err:find("quota")
                or api_err:find("high demand") or api_err:find("overload")
            if is_retryable then
                self_ref.db:markPagePending(book_id, page_num)
                self_ref._append_log(book_id, "Pending scan p." .. page_num .. ": API busy — kept pending (" .. err_str .. ")")
            else
                table.insert(scanned_ok, page_num)
                self_ref._append_log(book_id, "Pending scan p." .. page_num .. ": API error — skipped (" .. err_str .. ")")
            end
        elseif characters and #characters > 0 then
            local ex_chars = self_ref.db:load(book_id)
            local ic = UtilsCharacter.findIncomingConflicts(ex_chars, characters)
            local conflict_set = {}
            for _, c in ipairs(ic) do
                conflict_set[(c.new_char.name or ""):lower()] = true
                self_ref.db:enrichCharacter(book_id, c.existing_char.name, c.new_char, page_num)
            end
            local remaining_chars = {}
            for _, c in ipairs(characters) do
                if not conflict_set[(c.name or ""):lower()] then table.insert(remaining_chars, c) end
            end
            if #remaining_chars > 0 then self_ref.db:merge(book_id, remaining_chars, page_num) end
            total_found = total_found + #characters
            table.insert(scanned_ok, page_num)
            local _names = {}
            for _, c in ipairs(characters) do table.insert(_names, c.name or "?") end
            self_ref._append_log(book_id, "Pending scan p." .. page_num .. ": " .. #characters .. " character(s) found (" .. table.concat(_names, ", ") .. ")")
        else
            table.insert(scanned_ok, page_num)
        end

        UIManager:scheduleIn(4, function() processPage(idx + 1) end)
    end

    processPage(1)
end

-- ---------------------------------------------------------------------------
-- Manual extract: current page
-- ---------------------------------------------------------------------------

function Extraction:onExtractCurrentPage()
    logger.info("KoCharacters: onExtractCurrentPage called")

    local api_key = self._get_api_key()
    if api_key == "" then
        self._show_msg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self._get_book_id()
    if not book_id then
        self._show_msg("Cannot identify book — is a document open?")
        return
    end

    local self_ref = self
    self._check_warn_dups(book_id, function()
        local page_text, text_err = EpubReader.getPageText(self_ref.ui.document, self_ref:_getCurrentPage())
        if not page_text then
            self_ref._show_msg("Could not read page text:\n" .. tostring(text_err))
            return
        end
        if #page_text < 20 then
            self_ref._show_msg("Page text too short (" .. #page_text .. " chars).\nTry a page with more text.")
            return
        end

        logger.info("KoCharacters: page text length=" .. #page_text .. " preview=" .. page_text:sub(1,150))

        local working_msg = InfoMessage:new{
            text = "Contacting Gemini AI...\nThis may take a few seconds."
        }
        UIManager:show(working_msg)
        UIManager:forceRePaint()

        local all_chars     = self_ref.db:load(book_id)
        local chars_in_text = {}
        local skip_names    = {}
        local page_lower    = page_text:lower()
        for _, c in ipairs(all_chars) do
            if charInText(c, page_lower) then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end
        logger.info("KoCharacters: chars_in_text=" .. #chars_in_text .. " skip=" .. #skip_names)

        local client = GeminiClient:new(api_key)
        local characters, err, usage, book_context
        local ok, call_err = pcall(function()
            characters, err, usage, book_context = client:extractCharacters(
                page_text, skip_names, chars_in_text, self_ref._get_prompt(),
                self_ref.db:loadBookContext(book_id))
        end)

        UIManager:close(working_msg)
        if ok and not err then self_ref._record_usage(usage) end

        if ok and book_context and book_context ~= "" then
            self_ref.db:saveBookContext(book_id, book_context)
        end

        if not ok then
            logger.warn("KoCharacters: pcall error: " .. tostring(call_err))
            self_ref._show_msg("Plugin error:\n" .. tostring(call_err), 8)
            return
        end
        if err then
            logger.warn("KoCharacters: API error: " .. tostring(err))
            self_ref._show_msg("Gemini error:\n" .. tostring(err), 8)
            return
        end
        if not characters or #characters == 0 then
            self_ref._show_msg("No new characters found on this page.", 3)
            return
        end

        local cur_page = self_ref:_getCurrentPage()
        self_ref.db:markPageScanned(book_id, cur_page)
        self_ref._on_conflicts(book_id, characters, function(resolved)
            if #resolved > 0 then
                self_ref.db:merge(book_id, resolved, cur_page)
            end
            local _names = {}
            for _, c in ipairs(characters) do table.insert(_names, c.name or "?") end
            self_ref._append_log(book_id, "Manual extract p." .. cur_page .. ": " .. #characters .. " character(s) found (" .. table.concat(_names, ", ") .. ")")
            self_ref:_checkAndPromptPendingPages(book_id)
            local parts = { "Extracted " .. #characters .. " character(s):\n" }
            for _, c in ipairs(characters) do
                table.insert(parts, UtilsCharacter.formatText(c))
                table.insert(parts, "")
            end
            UIManager:show(TextViewer:new{
                title  = "Extracted Characters",
                text   = table.concat(parts, "\n"),
                width  = math.floor(Screen:getWidth() * 0.9),
                height = math.floor(Screen:getHeight() * 0.85),
            })
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Chapter scan
-- ---------------------------------------------------------------------------

function Extraction:onScanChapter()
    logger.info("KoCharacters: onScanChapter called")

    local api_key = self._get_api_key()
    if api_key == "" then
        self._show_msg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self._get_book_id()
    if not book_id then
        self._show_msg("Cannot identify book — is a document open?")
        return
    end

    local start_page, end_page, range_err = EpubReader.getChapterRange(self.ui.document, self:_getCurrentPage())
    if range_err then
        self._show_msg("Could not determine chapter range:\n" .. tostring(range_err))
        return
    end

    local page_count = end_page - start_page + 1
    local scanned    = self.db:loadScannedPages(book_id)
    local unscanned  = 0
    for p = start_page, end_page do if not scanned[p] then unscanned = unscanned + 1 end end
    local skip_note  = unscanned < page_count
        and "\n(" .. (page_count - unscanned) .. " already-scanned page(s) will be skipped)" or ""

    local self_ref = self
    UIManager:show(ConfirmBox:new{
        text    = "Scan chapter from page " .. start_page .. " to " .. end_page
                  .. " (" .. unscanned .. "/" .. page_count .. " page(s) to scan)?" .. skip_note,
        ok_text = "Scan",
        ok_callback = function()
            self_ref._check_warn_dups(book_id, function()
                self_ref:doChapterScan(book_id, start_page, end_page)
            end)
        end,
    })
end

function Extraction:onScanSpecificChapter()
    logger.info("KoCharacters: onScanSpecificChapter called")

    local api_key = self._get_api_key()
    if api_key == "" then
        self._show_msg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self._get_book_id()
    if not book_id then
        self._show_msg("Cannot identify book — is a document open?")
        return
    end

    local doc = self.ui and self.ui.document
    if not doc then
        self._show_msg("No document open.")
        return
    end

    local ok_toc, toc = pcall(function() return doc:getToc() end)
    if not ok_toc or type(toc) ~= "table" or #toc == 0 then
        self._show_msg("No table of contents found in this book.")
        return
    end

    local total_pages
    pcall(function() total_pages = doc:getPageCount() end)
    total_pages = total_pages or 9999

    -- Build chapter list with page ranges
    local chapters = {}
    for i, entry in ipairs(toc) do
        local start_p    = tonumber(entry.page) or 1
        local next_entry = toc[i + 1]
        local end_p
        if next_entry then
            end_p = math.max(start_p, (tonumber(next_entry.page) or start_p + 1) - 1)
        else
            end_p = total_pages
        end
        table.insert(chapters, {
            title   = entry.title or ("Chapter " .. i),
            start_p = start_p,
            end_p   = end_p,
        })
    end

    local scanned  = self.db:loadScannedPages(book_id)
    local self_ref = self
    local items    = {}
    for _, ch in ipairs(chapters) do
        local ch_ref    = ch
        local ch_total  = ch_ref.end_p - ch_ref.start_p + 1
        local scanned_count = 0
        for p = ch_ref.start_p, ch_ref.end_p do
            if scanned[p] then scanned_count = scanned_count + 1 end
        end
        local scan_label = ""
        if scanned_count == ch_total then
            scan_label = " [✓ done]"
        elseif scanned_count > 0 then
            scan_label = " [~ " .. scanned_count .. "/" .. ch_total .. " pages]"
        end
        table.insert(items, {
            text = ch_ref.title .. "  (pp. " .. ch_ref.start_p .. "–" .. ch_ref.end_p .. ")" .. scan_label,
            callback = function()
                local page_count = ch_ref.end_p - ch_ref.start_p + 1
                local ch_scanned = self_ref.db:loadScannedPages(book_id)
                local unscanned  = 0
                for p = ch_ref.start_p, ch_ref.end_p do if not ch_scanned[p] then unscanned = unscanned + 1 end end
                local skip_note  = unscanned < page_count
                    and "\n(" .. (page_count - unscanned) .. " already-scanned page(s) will be skipped)" or ""
                UIManager:show(ConfirmBox:new{
                    text    = 'Scan "' .. ch_ref.title .. '"\n'
                              .. "Pages " .. ch_ref.start_p .. "–" .. ch_ref.end_p
                              .. " (" .. unscanned .. "/" .. page_count .. " page(s) to scan)?" .. skip_note,
                    ok_text = "Scan",
                    ok_callback = function()
                        self_ref._check_warn_dups(book_id, function()
                            self_ref:doChapterScan(book_id, ch_ref.start_p, ch_ref.end_p)
                        end)
                    end,
                })
            end,
        })
    end

    UIManager:show(Menu:new{
        title       = "Select Chapter to Scan",
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    })
end

function Extraction:doChapterScan(book_id, start_page, end_page)
    local PAGES_PER_BATCH = 4

    local client         = GeminiClient:new(self._get_api_key())
    local scanned        = self.db:loadScannedPages(book_id)
    local page_count     = end_page - start_page + 1
    local total_batches  = math.ceil(page_count / PAGES_PER_BATCH)
    local total_found    = 0
    local enriched_names = {}
    local progress_msg
    local self_ref       = self

    local function doCleanup()
        if progress_msg then UIManager:close(progress_msg); progress_msg = nil end

        local enriched_list = {}
        for _, c in ipairs(self_ref.db:load(book_id)) do
            if enriched_names[c.name] then table.insert(enriched_list, c) end
        end
        if #enriched_list > 0 then
            local enriched_name_strs = {}
            for _, ec in ipairs(enriched_list) do table.insert(enriched_name_strs, ec.name or "?") end
            local cleanup_msg = InfoMessage:new{
                text = "Cleaning up " .. #enriched_list .. " enriched character(s)..."
            }
            UIManager:show(cleanup_msg)
            UIManager:forceRePaint()

            local cleaned, cerr, cusage
            local cok, ccall_err = pcall(function()
                cleaned, cerr, cusage = client:cleanCharacters(enriched_list)
            end)
            UIManager:close(cleanup_msg)
            if cok and not cerr then self_ref._record_usage(cusage) end

            if cok and not cerr and cleaned and type(cleaned) == "table" then
                local all_chars = self_ref.db:load(book_id)
                local changed   = false
                for i, cc in ipairs(cleaned) do
                    if cc.name then
                        local apply_msg = InfoMessage:new{
                            text = "Applying cleanup " .. i .. "/" .. #cleaned .. "..."
                        }
                        UIManager:show(apply_msg)
                        UIManager:forceRePaint()
                        for _, orig in ipairs(all_chars) do
                            if orig.name == cc.name then
                                if cc.physical_description ~= nil    then orig.physical_description = cc.physical_description end
                                if cc.personality          ~= nil    then orig.personality          = cc.personality          end
                                if cc.role and cc.role ~= ""         then orig.role                 = cc.role                 end
                                if type(cc.relationships) == "table" then orig.relationships        = cc.relationships        end
                                changed = true; break
                            end
                        end
                        UIManager:close(apply_msg)
                    end
                end
                if changed then self_ref.db:save(book_id, all_chars) end
            else
                logger.warn("KoCharacters: scan cleanup failed: " .. tostring(ccall_err or cerr))
            end
        end

        self_ref.db:clearPendingCleanup(book_id)
        self_ref._append_log(book_id, "Chapter scan pp." .. start_page .. "-" .. end_page .. ": " .. total_found .. " character(s) found")
        self_ref._show_msg(
            "Chapter scan complete.\n"
            .. "Batches: " .. total_batches .. " (" .. page_count .. " pages, " .. PAGES_PER_BATCH .. " per batch)\n"
            .. "Characters found/updated: " .. total_found .. "\n"
            .. "(Codex entries enriched per batch where matched)",
            6
        )
    end

    -- processBatch collects text from up to PAGES_PER_BATCH pages, sends one
    -- API call, then schedules the next batch via UIManager:scheduleIn to keep
    -- the UI responsive.
    local function processBatch(batch_start)
        if batch_start > end_page then
            doCleanup()
            return
        end

        local batch_end = math.min(batch_start + PAGES_PER_BATCH - 1, end_page)
        local batch_num = math.floor((batch_start - start_page) / PAGES_PER_BATCH) + 1

        if progress_msg then UIManager:close(progress_msg) end
        progress_msg = InfoMessage:new{
            text = "Scanning chapter...\nBatch " .. batch_num .. "/" .. total_batches
                   .. " (pages " .. batch_start .. "–" .. batch_end .. ")",
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        -- Collect text from unscanned pages in this batch
        local texts = {}
        for p = batch_start, batch_end do
            if not scanned[p] then
                local page_text = EpubReader.getPageText(self_ref.ui.document, p)
                if page_text and #page_text >= 20 then
                    table.insert(texts, page_text)
                end
                scanned[p] = true  -- update local set so re-used batches stay consistent
            end
        end

        -- Mark all pages in batch as scanned
        self_ref.db:markPagesScanned(book_id, batch_start, batch_end)

        if #texts == 0 then
            logger.info("KoCharacters: batch " .. batch_num .. " had no readable pages, skipping")
            UIManager:scheduleIn(0.5, function() processBatch(batch_end + 1) end)
            return
        end

        local combined_text  = table.concat(texts, "\n---\n")
        local combined_lower = combined_text:lower()
        local all_chars      = self_ref.db:load(book_id)
        local chars_in_text  = {}
        local skip_names     = {}
        for _, c in ipairs(all_chars) do
            if charInText(c, combined_lower) then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end

        local characters, err, usage, book_context
        local ok, call_err = pcall(function()
            characters, err, usage, book_context = client:extractCharacters(
                combined_text, skip_names, chars_in_text, self_ref._get_prompt(),
                self_ref.db:loadBookContext(book_id))
        end)
        if ok and not err then self_ref._record_usage(usage) end

        if ok and book_context and book_context ~= "" then
            self_ref.db:saveBookContext(book_id, book_context)
        end

        if not ok then
            local err_str = tostring(call_err):sub(1, 80)
            logger.warn("KoCharacters: batch " .. batch_num .. " pcall: " .. err_str)
            self_ref._append_log(book_id, "Chapter scan pp." .. batch_start .. "-" .. batch_end .. ": error (" .. err_str .. ")")
        elseif err then
            local err_str = tostring(err):sub(1, 80)
            logger.warn("KoCharacters: batch " .. batch_num .. " api: " .. err_str)
            self_ref._append_log(book_id, "Chapter scan pp." .. batch_start .. "-" .. batch_end .. ": API error (" .. err_str .. ")")
        elseif characters and #characters > 0 then
            local ex_chars     = self_ref.db:load(book_id)
            local ic           = UtilsCharacter.findIncomingConflicts(ex_chars, characters)
            local conflict_set = {}
            for _, c in ipairs(ic) do
                conflict_set[(c.new_char.name or ""):lower()] = true
                self_ref.db:enrichCharacter(book_id, c.existing_char.name, c.new_char, batch_end)
                enriched_names[c.existing_char.name] = true
                logger.info("KoCharacters: batch auto-enriched '" .. c.existing_char.name .. "'")
            end
            local remaining = {}
            for _, c in ipairs(characters) do
                if not conflict_set[(c.name or ""):lower()] then table.insert(remaining, c) end
            end
            if #remaining > 0 then self_ref.db:merge(book_id, remaining, batch_end) end
            total_found = total_found + #characters
        end

        -- Codex enrichment for this batch
        local codex_entries = self_ref.db_codex:getEntriesForPage(book_id, combined_text)
        if #codex_entries > 0 then
            local updated, cerr, cusage
            local cok, ccall_err = pcall(function()
                updated, cerr, cusage = client:enrichCodexEntries(
                    combined_text, codex_entries, self_ref._get_codex_update_prompt())
            end)
            if cok and not cerr then self_ref._record_usage(cusage) end
            if cok and not cerr and updated and #updated > 0 then
                self_ref.db_codex:merge(book_id, updated, batch_end)
                self_ref._append_log(book_id, "Chapter scan codex pp." .. batch_start
                    .. "-" .. batch_end .. ": " .. #updated .. " updated")
            elseif cerr then
                logger.warn("KoCharacters: chapter scan codex batch " .. batch_num
                    .. ": " .. tostring(cerr))
                self_ref._append_log(book_id, "Chapter scan codex pp." .. batch_start
                    .. "-" .. batch_end .. ": API error (" .. tostring(cerr):sub(1, 80) .. ")")
            end
        end

        UIManager:scheduleIn(3, function() processBatch(batch_end + 1) end)
    end

    processBatch(start_page)
end

return Extraction
