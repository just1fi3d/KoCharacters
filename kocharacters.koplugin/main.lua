-- main.lua
-- KoCharacters Plugin for KOReader (Gemini AI, manual trigger)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local TextViewer      = require("ui/widget/textviewer")
local ConfirmBox      = require("ui/widget/confirmbox")
local Screen          = require("device").screen
local logger          = require("logger")
local _               = require("gettext")

local Dispatcher   = require("dispatcher")
local GeminiClient = require("gemini_client")
local CharacterDB  = require("character_db")

-- ---------------------------------------------------------------------------
-- Duplicate detection helpers
-- ---------------------------------------------------------------------------
local function levenshtein(a, b)
    a, b = a:lower(), b:lower()
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev = {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local curr = { [0] = i }
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            curr[j] = math.min(curr[j-1] + 1, prev[j] + 1, prev[j-1] + cost)
        end
        prev = curr
    end
    return prev[lb]
end

-- Compare incoming (new) characters against an existing list; return conflict pairs.
-- Exact name matches are intentional updates handled by merge() — skip them here.
local function findIncomingConflicts(existing, incoming)
    local conflicts = {}
    for _, new_c in ipairs(incoming) do
        local new_low = (new_c.name or ""):lower()
        if #new_low >= 4 then
            for _, ex_c in ipairs(existing) do
                local ex_low = (ex_c.name or ""):lower()
                if #ex_low >= 4 and new_low ~= ex_low then
                    local dist      = levenshtein(new_low, ex_low)
                    local threshold = math.min(#new_low, #ex_low) <= 6 and 1 or 2
                    local substring = new_low:find(ex_low, 1, true) or ex_low:find(new_low, 1, true)
                    if dist <= threshold or substring then
                        table.insert(conflicts, { new_char = new_c, existing_char = ex_c })
                        break
                    end
                end
            end
        end
    end
    return conflicts
end

local function findDuplicatePairs(characters)
    local pairs_found = {}
    for i = 1, #characters do
        for j = i + 1, #characters do
            local a = characters[i].name or ""
            local b = characters[j].name or ""
            if #a >= 4 and #b >= 4 then
                local dist      = levenshtein(a, b)
                local threshold = math.min(#a, #b) <= 6 and 1 or 2
                local a_low     = a:lower()
                local b_low     = b:lower()
                local substring = a_low:find(b_low, 1, true) or b_low:find(a_low, 1, true)
                if dist <= threshold or (substring and a_low ~= b_low) then
                    table.insert(pairs_found, { a, b })
                end
            end
        end
    end
    return pairs_found
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

function KoCharacters:onCharExtractPage()      self:onExtractCurrentPage() end
function KoCharacters:onCharScanChapter()      self:onScanChapter() end
function KoCharacters:onCharViewCharacters()   self:onViewCharacters() end
function KoCharacters:onCharReanalyze()        self:onReanalyzeCharacterPicker() end
function KoCharacters:onCharViewUsage()        self:onViewUsage() end
function KoCharacters:onCharRelationshipMap()  self:onViewRelationshipMap() end

function KoCharacters:init()
    self.db               = CharacterDB
    self._auto_extracting = false
    self._pending_extract = nil
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    logger.info("KoCharacters: plugin initialised")
end

function KoCharacters:_getChapterStartForPage(pageno)
    local doc = self.ui and self.ui.document
    if not doc then return pageno end
    local ok, toc = pcall(function() return doc:getToc() end)
    if not ok or type(toc) ~= "table" or #toc == 0 then return 1 end
    local chapter_start = 1
    for _, entry in ipairs(toc) do
        local ep = tonumber(entry.page) or 0
        if ep <= pageno and ep > chapter_start then chapter_start = ep end
    end
    return chapter_start
end

function KoCharacters:_onPageChanged(pageno)
    if not G_reader_settings:readSetting("kocharacters_auto_extract") then return end

    -- Cancel any pending extraction scheduled for a previous page
    if self._pending_extract then
        UIManager:unschedule(self._pending_extract)
        self._pending_extract = nil
    end

    if self._auto_extracting then return end

    local book_id = self:getBookID()
    if not book_id then return end
    if self.db:isPageScanned(book_id, pageno) then return end

    -- Debounce: wait N seconds before extracting so rapid page flips don't
    -- trigger a cascade of blocking API calls
    local delay = G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10
    self._pending_extract = function()
        self._pending_extract = nil
        if self._auto_extracting then return end
        -- Only extract if the user is still on this page
        if self:getCurrentPage() ~= pageno then return end
        self:autoExtract(pageno)
    end
    UIManager:scheduleIn(delay, self._pending_extract)
end

function KoCharacters:onPageUpdate(pageno)
    self:_onPageChanged(pageno)
end

function KoCharacters:onPosUpdate()
    local pageno
    pcall(function() pageno = self.ui.view.state.page end)
    if pageno then self:_onPageChanged(pageno) end
end

function KoCharacters:autoExtract(page_num)
    if self._auto_extracting then return end
    local api_key = self:getApiKey()
    if api_key == "" then return end
    local book_id = self:getBookID()
    if not book_id then return end

    local page_text, err = self:getCurrentPageText(page_num)
    if not page_text then
        logger.warn("KoCharacters: autoExtract getText failed: " .. tostring(err))
        -- Mark as scanned anyway so we don't retry a page that can't be read
        if page_num then self.db:markPageScanned(book_id, page_num) end
        return
    end

    self._auto_extracting = true
    -- Mark page as scanned now so back/forward navigation won't re-trigger
    if page_num then self.db:markPageScanned(book_id, page_num) end

    local existing   = self.db:load(book_id)
    local page_lower = page_text:lower()
    local skip_names, chars_in_text = {}, {}
    for _, c in ipairs(existing) do
        local found = page_lower:find((c.name or ""):lower(), 1, true)
        if not found and c.aliases then
            for _, alias in ipairs(c.aliases) do
                if alias ~= "" and page_lower:find(alias:lower(), 1, true) then
                    found = true; break
                end
            end
        end
        if found then table.insert(chars_in_text, c) else table.insert(skip_names, c.name) end
    end

    local client = GeminiClient:new(api_key)
    local characters, api_err, usage
    local ok, call_err = pcall(function()
        characters, api_err, usage = client:extractCharacters(
            page_text, skip_names, chars_in_text, self:getExtractionPrompt())
    end)
    if ok and not api_err then self:recordUsage(usage) end

    if not ok or api_err or not characters or #characters == 0 then
        self._auto_extracting = false
        return
    end

    local cur_page = page_num or self:getCurrentPage()
    self:handleIncomingConflicts(book_id, characters, function(resolved)
        if #resolved > 0 then self.db:merge(book_id, resolved, cur_page) end
        self._auto_extracting = false
        self:showMsg("Auto-extracted " .. #characters .. " character(s).", 3)
    end, cur_page, true)
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
                callback = function() self:onExtractCurrentPage() end,
            },
            {
                text     = _("Scan current chapter"),
                callback = function() self:onScanChapter() end,
            },
            {
                text     = _("View saved characters"),
                callback = function() self:onViewCharacters() end,
            },
            {
                text     = _("Re-analyze character..."),
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
                text     = _("Export character list"),
                callback = function() self:onExportCharacters() end,
            },
            {
                text     = _("Settings"),
                callback = function() self:onOpenSettings() end,
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

function KoCharacters:checkAndWarnDuplicates(book_id, on_continue)
    local characters = self.db:load(book_id)
    if #characters < 2 then on_continue(); return end
    local pairs = findDuplicatePairs(characters)
    if #pairs == 0 then on_continue(); return end

    local lines = { "Possible duplicate characters detected:" }
    for _, p in ipairs(pairs) do
        table.insert(lines, '  \xE2\x80\xA2 "' .. p[1] .. '" and "' .. p[2] .. '"')
    end
    table.insert(lines, "\nContinue extraction anyway?")
    UIManager:show(ConfirmBox:new{
        text        = table.concat(lines, "\n"),
        ok_text     = "Continue",
        ok_callback = on_continue,
    })
end

function KoCharacters:handleIncomingConflicts(book_id, new_chars, on_done, page_num, skip_cleanup)
    local existing  = self.db:load(book_id)
    local conflicts = findIncomingConflicts(existing, new_chars)
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

function KoCharacters:getApiKey()
    return G_reader_settings:readSetting("kocharacters_api_key") or ""
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

function KoCharacters:getReanalyzePrompt()
    return G_reader_settings:readSetting("kocharacters_reanalyze_prompt")
        or GeminiClient.DEFAULT_REANALYZE_PROMPT
end

function KoCharacters:getRelationshipMapPrompt()
    return G_reader_settings:readSetting("kocharacters_relationship_map_prompt")
        or GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT
end

function KoCharacters:recordUsage(usage)
    if not usage then return end
    local json        = require("dkjson")
    local DataStorage = require("datastorage")
    local path        = DataStorage:getDataDir() .. "/kocharacters/usage_stats.json"

    local stats = {}
    local f = io.open(path, "r")
    if f then
        stats = json.decode(f:read("*all")) or {}
        f:close()
    end

    local date = os.date("%Y-%m-%d")
    if not stats[date] then
        stats[date] = { calls = 0, prompt_tokens = 0, output_tokens = 0 }
    end
    stats[date].calls         = (stats[date].calls         or 0) + 1
    stats[date].prompt_tokens = (stats[date].prompt_tokens or 0) + (usage.prompt_tokens or 0)
    stats[date].output_tokens = (stats[date].output_tokens or 0) + (usage.output_tokens or 0)

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

    local lines = { "Date            Calls  Prompt     Output" }
    table.insert(lines, string.rep("-", 46))
    local tot_calls, tot_prompt, tot_output = 0, 0, 0
    for _, date in ipairs(dates) do
        local d = stats[date]
        local c = d.calls         or 0
        local p = d.prompt_tokens or 0
        local o = d.output_tokens or 0
        tot_calls  = tot_calls  + c
        tot_prompt = tot_prompt + p
        tot_output = tot_output + o
        table.insert(lines, string.format("%-16s %-6d %-10d %d", date, c, p, o))
    end
    table.insert(lines, string.rep("-", 46))
    table.insert(lines, string.format("%-16s %-6d %-10d %d", "TOTAL", tot_calls, tot_prompt, tot_output))

    UIManager:show(TextViewer:new{
        title  = "Gemini API Usage",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

-- Derive a stable book ID purely from the file path — no document API calls
function KoCharacters:getBookID()
    if self.ui and self.ui.document and self.ui.document.file then
        local path = self.ui.document.file
        -- Simple hash: sum of byte values + length, good enough for a filename key
        local sum = #path
        for i = 1, #path do
            sum = sum + string.byte(path, i)
        end
        local fname = path:match("([^/]+)$") or "book"
        fname = fname:gsub("[^%w%-_]", "_")
        return fname .. "_" .. tostring(sum)
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

function KoCharacters:getCurrentPageText(override_page)
    if not self.ui or not self.ui.document then
        return nil, "No document open"
    end

    local doc = self.ui.document
    local page
    if override_page then
        page = override_page
    else
        pcall(function() page = self.ui.view.state.page end)
    end
    if not page then return nil, "Could not get page number" end

    -- CreDocument (EPUB): getPageXPointer works, getPosFromXPointer works
    -- Use these to get integer position range, then getTextBoxesFromPositions
    if type(doc.getPageXPointer) == "function" then
        logger.info("KoCharacters: using getPageXPointer+getPosFromXPointer strategy")

        local ok1, xp_cur  = pcall(function() return doc:getPageXPointer(page) end)
        local ok2, xp_next = pcall(function() return doc:getPageXPointer(page + 1) end)

        if not ok1 or not xp_cur then
            return nil, "getPageXPointer failed: " .. tostring(xp_cur)
        end

        local ok3, pos_start = pcall(function() return doc:getPosFromXPointer(xp_cur) end)
        if not ok3 then return nil, "getPosFromXPointer failed: " .. tostring(pos_start) end

        local pos_end
        if ok2 and xp_next then
            local ok4, p = pcall(function() return doc:getPosFromXPointer(xp_next) end)
            if ok4 then pos_end = p end
        end
        if not pos_end then pos_end = pos_start + 5000 end

        logger.info("KoCharacters: pos=" .. tostring(pos_start) .. "-" .. tostring(pos_end))

        -- Try getTextBoxesFromPositions (some builds have this)
        local ok5, boxes = pcall(function()
            return doc:getTextBoxesFromPositions(pos_start, pos_end)
        end)
        if ok5 and boxes and type(boxes) == "table" and #boxes > 0 then
            local words = {}
            for _, line in ipairs(boxes) do
                if type(line) == "table" then
                    for _, word in ipairs(line) do
                        if type(word) == "table" and word.word and word.word ~= "" then
                            table.insert(words, word.word)
                        end
                    end
                end
            end
            if #words > 0 then return table.concat(words, " ") end
        end

        -- Use getDocumentFileContent — confirmed working
        local frag_idx = tostring(xp_cur):match("DocFragment%[(%d+)%]")
        logger.info("KoCharacters: frag_idx=" .. tostring(frag_idx))
        -- Get fragment start AND end position from TOC for accurate slicing
        local frag_start_pos = 0
        local frag_end_pos = 0
        local ok_toc, toc = pcall(function() return doc:getToc() end)
        if ok_toc and type(toc) == "table" then
            local best_page = 0
            local best_idx = 0
            for i, entry in ipairs(toc) do
                local ep = tonumber(entry.page) or 0
                if ep <= page and ep > best_page then
                    best_page = ep
                    best_idx = i
                    if entry.xpointer then
                        local ok_xp, p = pcall(function()
                            return doc:getPosFromXPointer(entry.xpointer)
                        end)
                        if ok_xp and p then frag_start_pos = p end
                    end
                end
            end
            -- Get next TOC entry position as fragment end
            local next_entry = toc[best_idx + 1]
            if next_entry and next_entry.xpointer then
                local ok_xp, p = pcall(function()
                    return doc:getPosFromXPointer(next_entry.xpointer)
                end)
                if ok_xp and p then frag_end_pos = p end
            end
        end
        logger.info("KoCharacters: frag_start=" .. frag_start_pos .. " frag_end=" .. frag_end_pos)

        -- Read epub as zip directly — most reliable approach
        local function stripAndSlice(raw)
            local text = raw
            text = text:gsub("<[^>]+>", " ")
            text = text:gsub("&nbsp;",  " ")
            text = text:gsub("&amp;",   "&")
            text = text:gsub("&lt;",    "<")
            text = text:gsub("&gt;",    ">")
            text = text:gsub("&quot;",  '"')
            text = text:gsub("&#%d+;",  " ")
            text = text:gsub("%s+",     " ")
            text = text:gsub("^%s+",    "")
            text = text:gsub("%s+$",    "")
            if #text < 50 then text = raw:sub(1, 4000) end
            local MAX = 2500
            if #text <= MAX then return text end
            -- Use fragment-relative position for accurate slicing
            local frag_span = math.max(
                (frag_end_pos > 0 and frag_end_pos or pos_start + 50000) - frag_start_pos, 1)
            local page_offset = math.max(pos_start - frag_start_pos, 0)
            local ratio = math.min(page_offset / frag_span, 1.0)
            local centre = math.floor(ratio * #text)
            local s = math.max(1, centre - 500)
            local e = math.min(#text, s + MAX)
            logger.info("KoCharacters: ratio=" .. string.format("%.2f", ratio) .. " slice=" .. s .. "-" .. e .. "/" .. #text)
            local slice = text:sub(s, e)
            if #slice < 200 then return text:sub(1, math.min(#text, MAX)) end
            return slice
        end

        local epub_path = doc.file
        logger.info("KoCharacters: epub_path=" .. tostring(epub_path))
        if epub_path then
            logger.info("KoCharacters: starting popen unzip")
            local ok_p, result = pcall(function()
                local h = io.popen("unzip -l '" .. epub_path .. "' 2>/dev/null", "r")
                if not h then return nil, "popen failed" end
                local listing = h:read("*a")
                h:close()
                return listing
            end)
            logger.info("KoCharacters: popen ok=" .. tostring(ok_p) .. " type=" .. type(result) .. " len=" .. (type(result)=="string" and #result or 0))

            if ok_p and type(result) == "string" and #result > 10 then
                local n = tonumber(frag_idx) or 1
                -- Find OPF path in listing
                local opf_path = result:match("([^%s]+%.opf)")
                logger.info("KoCharacters: opf_path=" .. tostring(opf_path))

                if opf_path then
                    local ok2, opf = pcall(function()
                        local h = io.popen("unzip -p '" .. epub_path .. "' '" .. opf_path .. "' 2>/dev/null", "r")
                        if not h then return nil end
                        local s = h:read("*a"); h:close(); return s
                    end)
                    logger.info("KoCharacters: opf ok=" .. tostring(ok2) .. " len=" .. (type(opf)=="string" and #opf or 0))

                    if ok2 and type(opf) == "string" and #opf > 50 then
                        -- Find nth spine itemref
                        local count, item_id = 0, nil
                        for idref in opf:gmatch([[itemref[^>]+idref="([^"]+)"]]) do
                            count = count + 1
                            if count == n then item_id = idref; break end
                        end
                        logger.info("KoCharacters: spine#" .. n .. " id=" .. tostring(item_id))

                        if item_id then
                            local pat1 = [[item[^>]+href="([^"]+)"[^>]+id="]] .. item_id .. [["]]
                            local pat2 = [[item[^>]+id="]] .. item_id .. [["[^>]+href="([^"]+)"]]
                            local href = opf:match(pat2) or opf:match(pat1)
                            logger.info("KoCharacters: chapter href=" .. tostring(href))

                            if href then
                                local base = opf_path:match("^(.*/)") or ""
                                local full = base .. href
                                local ok3, chapter = pcall(function()
                                    local h = io.popen("unzip -p '" .. epub_path .. "' '" .. full .. "' 2>/dev/null", "r")
                                    if not h then return nil end
                                    local s = h:read("*a"); h:close(); return s
                                end)
                                logger.info("KoCharacters: chapter ok=" .. tostring(ok3) .. " len=" .. (type(chapter)=="string" and #chapter or 0))

                                if ok3 and type(chapter) == "string" and #chapter > 100 then
                                    return stripAndSlice(chapter)
                                end
                            end
                        end
                    end
                end
            end
        end

        return nil, "All extraction methods failed for page " .. tostring(page)
    end

    -- Fallback: getTextBoxes
    local boxes
    local ok, err = pcall(function() boxes = doc:getTextBoxes(page) end)
    if not ok then return nil, "getTextBoxes error: " .. tostring(err) end
    if not boxes or #boxes == 0 then return nil, "No text found on this page" end
    local words = {}
    for _, line in ipairs(boxes) do
        if type(line) == "table" then
            for _, word in ipairs(line) do
                if type(word) == "table" and word.word and word.word ~= "" then
                    table.insert(words, word.word)
                end
            end
        end
    end
    if #words == 0 then return nil, "Text boxes empty" end
    return table.concat(words, " ")
end

function KoCharacters:getCurrentChapterPageRange()
    if not self.ui or not self.ui.document then
        return nil, nil, "No document open"
    end

    local doc = self.ui.document
    local current_page
    pcall(function() current_page = self.ui.view.state.page end)
    if not current_page then return nil, nil, "Could not get page number" end

    local total_pages
    pcall(function() total_pages = doc:getPageCount() end)
    total_pages = total_pages or current_page

    local ok_toc, toc = pcall(function() return doc:getToc() end)
    if not ok_toc or type(toc) ~= "table" or #toc == 0 then
        return 1, total_pages, nil
    end

    local chapter_start = 1
    local chapter_idx   = 0
    for i, entry in ipairs(toc) do
        local ep = tonumber(entry.page) or 0
        if ep <= current_page and ep >= chapter_start then
            chapter_start = ep
            chapter_idx   = i
        end
    end

    local chapter_end = total_pages
    local next_entry  = toc[chapter_idx + 1]
    if next_entry then
        local np = tonumber(next_entry.page) or 0
        if np > chapter_start then
            chapter_end = np - 1
        end
    end

    return chapter_start, chapter_end, nil
end

function KoCharacters:formatCharacter(c)
    local lines = {}
    table.insert(lines, "========================")
    table.insert(lines, "Name: " .. (c.name or "Unknown"))
    if c.aliases and #c.aliases > 0 then
        table.insert(lines, "Aliases: " .. table.concat(c.aliases, ", "))
    end
    if c.role and c.role ~= "" then
        table.insert(lines, "Role: " .. c.role)
    end
    if c.physical_description and c.physical_description ~= "" then
        table.insert(lines, "Appearance: " .. c.physical_description)
    end
    if c.personality and c.personality ~= "" then
        table.insert(lines, "Personality: " .. c.personality)
    end
    if c.relationships and #c.relationships > 0 then
        table.insert(lines, "Relationships: " .. table.concat(c.relationships, "; "))
    end
    if c.first_appearance_quote and c.first_appearance_quote ~= "" then
        table.insert(lines, 'First seen: "' .. c.first_appearance_quote .. '"')
    end
    if c.user_notes and c.user_notes ~= "" then
        table.insert(lines, "Notes: " .. c.user_notes)
    end
    if c.source_page then
        table.insert(lines, "Last updated: page " .. c.source_page)
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Edit character
-- ---------------------------------------------------------------------------
function KoCharacters:onEditCharacter(book_id, char)
    local self_ref   = self
    -- Track the name used to look up the record (changes if the user renames)
    local lookup_name = char.name

    local function save()
        self_ref.db:updateCharacter(book_id, lookup_name, char)
        lookup_name = char.name   -- keep in sync if name was changed
        self_ref:showMsg("Saved.", 2)
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

    local function showEditMenu()
        local ok, Menu = pcall(require, "ui/widget/menu")
        if not ok or not Menu then return end

        local items = {
            {
                text     = "Name: " .. (char.name or ""),
                callback = function()
                    editTextField("Name", char.name, false, function(val)
                        if val ~= "" then char.name = val; save() end
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
                        char.aliases = t; save()
                    end)
                end,
            },
            {
                text     = "Role: " .. (char.role or "unknown"),
                callback = function()
                    local role_items = {}
                    for _, r in ipairs({"protagonist","antagonist","supporting","unknown"}) do
                        local role = r
                        table.insert(role_items, {
                            text     = role,
                            callback = function()
                                char.role = role; save()
                            end,
                        })
                    end
                    UIManager:show(Menu:new{
                        title      = "Select Role",
                        item_table = role_items,
                        width      = Screen:getWidth(),
                        show_parent = self_ref.ui,
                    })
                end,
            },
            {
                text     = "Appearance",
                callback = function()
                    editTextField("Appearance", char.physical_description, true, function(val)
                        char.physical_description = val; save()
                    end)
                end,
            },
            {
                text     = "Personality",
                callback = function()
                    editTextField("Personality", char.personality, true, function(val)
                        char.personality = val; save()
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
                        char.relationships = t; save()
                    end)
                end,
            },
            {
                text     = "First appearance quote",
                callback = function()
                    editTextField("First Appearance Quote", char.first_appearance_quote, true, function(val)
                        char.first_appearance_quote = val; save()
                    end)
                end,
            },
            {
                text     = "Notes" .. ((char.user_notes and char.user_notes ~= "") and " ✎" or ""),
                callback = function()
                    editTextField("Notes", char.user_notes, true, function(val)
                        char.user_notes = val ~= "" and val or nil; save()
                    end)
                end,
            },
        }

        UIManager:show(Menu:new{
            title       = "Edit: " .. (char.name or ""),
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = self_ref.ui,
        })
    end

    showEditMenu()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
function KoCharacters:onExtractCurrentPage()
    logger.info("KoCharacters: onExtractCurrentPage called")

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

    self:checkAndWarnDuplicates(book_id, function()
        local page_text, text_err = self:getCurrentPageText()
        if not page_text then
            self:showMsg("Could not read page text:\n" .. tostring(text_err))
            return
        end
        if #page_text < 20 then
            self:showMsg("Page text too short (" .. #page_text .. " chars).\nTry a page with more text.")
            return
        end

        logger.info("KoCharacters: page text length=" .. #page_text .. " preview=" .. page_text:sub(1,150))

        local working_msg = InfoMessage:new{
            text = "Contacting Gemini AI...\nThis may take a few seconds."
        }
        UIManager:show(working_msg)
        UIManager:forceRePaint()

        local all_chars     = self.db:load(book_id)
        local chars_in_text = {}
        local skip_names    = {}
        local page_lower    = page_text:lower()
        for _, c in ipairs(all_chars) do
            local found = c.name and page_lower:find(c.name:lower(), 1, true)
            if not found and c.aliases then
                for _, alias in ipairs(c.aliases) do
                    if alias ~= "" and page_lower:find(alias:lower(), 1, true) then
                        found = true; break
                    end
                end
            end
            if found then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end
        logger.info("KoCharacters: chars_in_text=" .. #chars_in_text .. " skip=" .. #skip_names)

        local client = GeminiClient:new(api_key)
        local characters, err, usage
        local ok, call_err = pcall(function()
            characters, err, usage = client:extractCharacters(page_text, skip_names, chars_in_text, self:getExtractionPrompt())
        end)

        UIManager:close(working_msg)
        if ok and not err then self:recordUsage(usage) end

        if not ok then
            logger.warn("KoCharacters: pcall error: " .. tostring(call_err))
            self:showMsg("Plugin error:\n" .. tostring(call_err), 8)
            return
        end
        if err then
            logger.warn("KoCharacters: API error: " .. tostring(err))
            self:showMsg("Gemini error:\n" .. tostring(err), 8)
            return
        end
        if not characters or #characters == 0 then
            self:showMsg("No new characters found on this page.", 3)
            return
        end

        local cur_page = self:getCurrentPage()
        self:handleIncomingConflicts(book_id, characters, function(resolved)
            if #resolved > 0 then
                self.db:merge(book_id, resolved, cur_page)
            end
            local parts = { "Extracted " .. #characters .. " character(s):\n" }
            for _, c in ipairs(characters) do
                table.insert(parts, self:formatCharacter(c))
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

function KoCharacters:onScanChapter()
    logger.info("KoCharacters: onScanChapter called")

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

    local start_page, end_page, range_err = self:getCurrentChapterPageRange()
    if range_err then
        self:showMsg("Could not determine chapter range:\n" .. tostring(range_err))
        return
    end

    local page_count = end_page - start_page + 1
    UIManager:show(ConfirmBox:new{
        text    = "Scan chapter from page " .. start_page .. " to " .. end_page
                  .. " (" .. page_count .. " page(s))?\n\nGemini will be called once per page.",
        ok_text = "Scan",
        ok_callback = function()
            self:checkAndWarnDuplicates(book_id, function()
                self:doChapterScan(book_id, start_page, end_page)
            end)
        end,
    })
end

function KoCharacters:doChapterScan(book_id, start_page, end_page)
    local PAGES_PER_BATCH = 4

    local client         = GeminiClient:new(self:getApiKey())
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
            if cok and not cerr then self_ref:recordUsage(cusage) end

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
                                if cc.physical_description ~= nil       then orig.physical_description = cc.physical_description end
                                if cc.personality          ~= nil       then orig.personality          = cc.personality          end
                                if cc.role and cc.role ~= ""            then orig.role                 = cc.role                 end
                                if type(cc.relationships) == "table"    then orig.relationships        = cc.relationships        end
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
        self_ref:showMsg(
            "Chapter scan complete.\n"
            .. "Batches: " .. total_batches .. " (".. page_count .. " pages, " .. PAGES_PER_BATCH .. " per batch)\n"
            .. "Characters found/updated: " .. total_found,
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

        local batch_end  = math.min(batch_start + PAGES_PER_BATCH - 1, end_page)
        local batch_num  = math.floor((batch_start - start_page) / PAGES_PER_BATCH) + 1

        if progress_msg then UIManager:close(progress_msg) end
        progress_msg = InfoMessage:new{
            text = "Scanning chapter...\nBatch " .. batch_num .. "/" .. total_batches
                   .. " (pages " .. batch_start .. "–" .. batch_end .. ")",
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        -- Collect and concatenate text from all pages in this batch
        local texts = {}
        for p = batch_start, batch_end do
            local page_text = self_ref:getCurrentPageText(p)
            if page_text and #page_text >= 20 then
                table.insert(texts, page_text)
            end
        end

        -- Mark all pages in batch as scanned regardless of whether we got text
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
            local found = c.name and combined_lower:find(c.name:lower(), 1, true)
            if not found and c.aliases then
                for _, alias in ipairs(c.aliases) do
                    if alias ~= "" and combined_lower:find(alias:lower(), 1, true) then
                        found = true; break
                    end
                end
            end
            if found then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end

        local characters, err, usage
        local ok, call_err = pcall(function()
            characters, err, usage = client:extractCharacters(combined_text, skip_names, chars_in_text, self_ref:getExtractionPrompt())
        end)
        if ok and not err then self_ref:recordUsage(usage) end

        if not ok then
            logger.warn("KoCharacters: batch " .. batch_num .. " pcall: " .. tostring(call_err))
        elseif err then
            logger.warn("KoCharacters: batch " .. batch_num .. " api: " .. tostring(err))
        elseif characters and #characters > 0 then
            local ex_chars     = self_ref.db:load(book_id)
            local ic           = findIncomingConflicts(ex_chars, characters)
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

        UIManager:scheduleIn(3, function() processBatch(batch_end + 1) end)
    end

    processBatch(start_page)
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

    -- Character items
    for _, c in ipairs(sorted) do
        local name = c.name or "Unknown"
        local role = (c.role and c.role ~= "" and c.role ~= "unknown")
                     and (" [" .. c.role .. "]") or ""
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
            text     = name .. role,
            callback = function()
                -- Mark as unlocked so navigating back won't hide this character again
                if not char.unlocked then
                    char.unlocked = true
                    self_ref.db:updateCharacter(book_id, char.name, char)
                end
                local viewer
                viewer = TextViewer:new{
                    title  = name,
                    text   = self_ref:formatCharacter(char),
                    width  = math.floor(Screen:getWidth() * 0.9),
                    height = math.floor(Screen:getHeight() * 0.85),
                    buttons_table = {
                        {
                            {
                                text     = "Re-analyze",
                                callback = function()
                                    UIManager:close(viewer)
                                    self_ref:onReanalyzeCharacter(book_id, char)
                                end,
                            },
                            {
                                text     = "Clean up",
                                callback = function()
                                    UIManager:close(viewer)
                                    self_ref:onCleanCharacter(book_id, char.name)
                                end,
                            },
                            {
                                text     = "Edit",
                                callback = function()
                                    UIManager:close(viewer)
                                    self_ref:onEditCharacter(book_id, char)
                                end,
                            },
                            {
                                text     = "Merge into...",
                                callback = function()
                                    UIManager:close(viewer)
                                    local others = {}
                                    for _, other in ipairs(self_ref.db:load(book_id)) do
                                        if other.name ~= name then
                                            local other_name = other.name
                                            table.insert(others, {
                                                text     = other_name,
                                                callback = function()
                                                    UIManager:show(ConfirmBox:new{
                                                        text        = 'Merge "' .. name .. '" into "' .. other_name .. '"?\n'
                                                                      .. 'Their info will be combined and "' .. name .. '" removed.',
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
                                    local ok_m, Menu2 = pcall(require, "ui/widget/menu")
                                    if ok_m and Menu2 then
                                        UIManager:show(Menu2:new{
                                            title       = 'Merge "' .. name .. '" into...',
                                            item_table  = others,
                                            width       = Screen:getWidth(),
                                            show_parent = self_ref.ui,
                                        })
                                    end
                                end,
                            },
                            {
                                text     = "Delete character",
                                callback = function()
                                    UIManager:close(viewer)
                                    UIManager:show(ConfirmBox:new{
                                        text        = 'Delete "' .. name .. '" from the character list?',
                                        ok_text     = "Delete",
                                        ok_callback = function()
                                            self_ref.db:deleteCharacter(book_id, name)
                                            self_ref:showMsg(name .. " deleted.", 2)
                                        end,
                                    })
                                end,
                            },
                        },
                    },
                }
                UIManager:show(viewer)
            end,
        })
        end  -- else (not spoiler)
    end

    local count_str = query ~= "" and (#filtered .. "/" .. #all_chars) or tostring(#all_chars)
    UIManager:show(Menu:new{
        title       = count_str .. " character(s) — " .. self:getBookTitle(),
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    })
end

function KoCharacters:onExportCharacters()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book.")
        return
    end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters to export yet.")
        return
    end
    local title = self:getBookTitle()
    local DataStorage = require("datastorage")
    local export_path = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "_characters.html"

    local function esc(s)
        s = tostring(s or "")
        s = s:gsub("&", "&amp;")
        s = s:gsub("<", "&lt;")
        s = s:gsub(">", "&gt;")
        s = s:gsub('"', "&quot;")
        return s
    end

    local parts = {}
    local function p(s) table.insert(parts, s) end

    p('<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">')
    p('<meta name="viewport" content="width=device-width,initial-scale=1">')
    p('<title>' .. esc(title) .. '</title>')
    p('<style>')
    p('body{font-family:Georgia,serif;max-width:800px;margin:40px auto;padding:0 20px;background:#fdf6e3;color:#333;}')
    p('h1{font-size:1.6em;border-bottom:2px solid #c9a84c;padding-bottom:8px;color:#5a3e1b;}')
    p('.character{background:#fff;border:1px solid #ddd;border-radius:6px;padding:20px;margin:20px 0;box-shadow:0 1px 3px rgba(0,0,0,.08);}')
    p('.char-name{font-size:1.3em;font-weight:bold;color:#5a3e1b;margin:0 0 4px;}')
    p('.char-role{font-size:.9em;color:#888;margin:0 0 12px;font-style:italic;}')
    p('.field label{font-weight:bold;font-size:.85em;text-transform:uppercase;letter-spacing:.05em;color:#999;}')
    p('.field p{margin:2px 0 10px;line-height:1.5;}')
    p('.aliases,.relationships{color:#555;}')
    p('.quote{border-left:3px solid #c9a84c;padding-left:12px;color:#666;font-style:italic;}')
    p('</style></head><body>')
    p('<h1>' .. esc(title) .. '</h1>')
    p('<p style="color:#888;font-size:.85em;">' .. #characters .. ' character(s)</p>')
    p('<nav style="background:#fff;border:1px solid #ddd;border-radius:6px;padding:16px 20px;margin-bottom:24px;">')
    p('<div style="font-weight:bold;font-size:.85em;text-transform:uppercase;letter-spacing:.05em;color:#999;margin-bottom:8px;">Characters</div>')
    p('<ol style="margin:0;padding-left:20px;column-count:2;column-gap:2em;">')
    for _, c in ipairs(characters) do
        local anchor = esc(c.name or "Unknown"):gsub("%s+", "-"):lower()
        local role = (c.role and c.role ~= "") and (' <span style="color:#aaa;font-size:.85em;">— ' .. esc(c.role) .. '</span>') or ""
        p('<li style="margin-bottom:4px;"><a href="#' .. anchor .. '" style="color:#5a3e1b;text-decoration:none;">' .. esc(c.name or "Unknown") .. '</a>' .. role .. '</li>')
    end
    p('</ol></nav>')

    for _, c in ipairs(characters) do
        local anchor = esc(c.name or "Unknown"):gsub("%s+", "-"):lower()
        p('<div class="character" id="' .. anchor .. '">')
        p('<div class="char-name">' .. esc(c.name or "Unknown") .. '</div>')
        if c.role and c.role ~= "" then
            p('<div class="char-role">' .. esc(c.role) .. '</div>')
        end
        if c.aliases and #c.aliases > 0 then
            p('<div class="field aliases"><label>Also known as</label><p>' .. esc(table.concat(c.aliases, ", ")) .. '</p></div>')
        end
        if c.physical_description and c.physical_description ~= "" then
            p('<div class="field"><label>Appearance</label><p>' .. esc(c.physical_description) .. '</p></div>')
        end
        if c.personality and c.personality ~= "" then
            p('<div class="field"><label>Personality</label><p>' .. esc(c.personality) .. '</p></div>')
        end
        if c.relationships and #c.relationships > 0 then
            local rel_parts = {}
            for _, r in ipairs(c.relationships) do table.insert(rel_parts, esc(r)) end
            p('<div class="field relationships"><label>Relationships</label><p>' .. table.concat(rel_parts, "<br>") .. '</p></div>')
        end
        if c.first_appearance_quote and c.first_appearance_quote ~= "" then
            p('<div class="field"><label>First seen</label><p class="quote">&ldquo;' .. esc(c.first_appearance_quote) .. '&rdquo;</p></div>')
        end
        if c.user_notes and c.user_notes ~= "" then
            p('<div class="field" style="border-top:1px dashed #e0c97a;margin-top:10px;padding-top:10px;"><label>My notes</label><p style="white-space:pre-wrap;">' .. esc(c.user_notes) .. '</p></div>')
        end
        if c.source_page then
            p('<div style="margin-top:10px;font-size:.8em;color:#bbb;text-align:right;">Last updated: page ' .. esc(tostring(c.source_page)) .. '</div>')
        end
        p('</div>')
    end

    p('</body></html>')

    local f = io.open(export_path, "w")
    if not f then
        self:showMsg("Could not write file:\n" .. export_path)
        return
    end
    f:write(table.concat(parts, "\n"))
    f:close()
    self:showMsg("Exported to:\n" .. export_path, 5)
end

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

    local working_msg = InfoMessage:new{
        text = "Cleaning up all " .. #characters .. " character(s)..."
    }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local cleaned, err, usage
    local ok, call_err = pcall(function()
        cleaned, err, usage = client:cleanCharacters(characters)
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
    if not cleaned or type(cleaned) ~= "table" then
        self:showMsg("Cleanup returned no data.", 4)
        return
    end

    local all_chars = self.db:load(book_id)
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

    if changed then self.db:save(book_id, all_chars) end
    self.db:clearPendingCleanup(book_id)
    self:showMsg("Cleanup complete. " .. #cleaned .. " character(s) cleaned.", 4)
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

function KoCharacters:onOpenSettings()
    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok then
        self:onSetApiKey()
        return
    end
    UIManager:show(Menu:new{
        title      = "KoCharacters Settings",
        item_table = {
            {
                text     = "Gemini API key",
                callback = function() self:onSetApiKey() end,
            },
            {
                text = "Auto-extract on page turn: "
                    .. (G_reader_settings:readSetting("kocharacters_auto_extract") and "ON" or "OFF"),
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_auto_extract")
                    G_reader_settings:saveSetting("kocharacters_auto_extract", not on)
                    self:showMsg("Auto-extract: " .. (not on and "ON" or "OFF"), 2)
                end,
            },
            {
                text = "Auto-extract delay: "
                    .. (G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10) .. "s",
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title      = "Auto-extract delay (seconds)",
                        input      = tostring(G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10),
                        input_type = "number",
                        buttons    = {{
                            { text = "Cancel", callback = function() UIManager:close(dialog) end },
                            {
                                text             = "Save",
                                is_enter_default = true,
                                callback         = function()
                                    local val = tonumber(dialog:getInputText())
                                    UIManager:close(dialog)
                                    if val and val > 0 then
                                        G_reader_settings:saveSetting("kocharacters_auto_extract_delay", val)
                                        self:showMsg("Auto-extract delay set to " .. val .. "s", 2)
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text = "Auto-accept enrichments: "
                    .. (G_reader_settings:readSetting("kocharacters_auto_enrich") and "ON" or "OFF"),
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_auto_enrich")
                    G_reader_settings:saveSetting("kocharacters_auto_enrich", not on)
                    self:showMsg("Auto-accept enrichments: " .. (not on and "ON" or "OFF"), 2)
                end,
            },
            {
                text = "Spoiler protection: "
                    .. (G_reader_settings:readSetting("kocharacters_spoiler_protection") and "ON" or "OFF"),
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_spoiler_protection")
                    G_reader_settings:saveSetting("kocharacters_spoiler_protection", not on)
                    self:showMsg("Spoiler protection: " .. (not on and "ON" or "OFF"), 2)
                end,
            },
            {
                text     = "View API usage",
                callback = function() self:onViewUsage() end,
            },
            {
                text     = "Edit extraction prompt",
                callback = function() self:onEditPrompt(
                    "Extraction Prompt",
                    "kocharacters_extraction_prompt",
                    GeminiClient.DEFAULT_EXTRACTION_PROMPT
                ) end,
            },
            {
                text     = "Edit cleanup prompt",
                callback = function() self:onEditPrompt(
                    "Cleanup Prompt",
                    "kocharacters_cleanup_prompt",
                    GeminiClient.DEFAULT_CLEANUP_PROMPT
                ) end,
            },
            {
                text     = "Edit re-analyze prompt",
                callback = function() self:onEditPrompt(
                    "Re-analyze Prompt",
                    "kocharacters_reanalyze_prompt",
                    GeminiClient.DEFAULT_REANALYZE_PROMPT
                ) end,
            },
            {
                text     = "Edit relationship map prompt",
                callback = function() self:onEditPrompt(
                    "Relationship Map Prompt",
                    "kocharacters_relationship_map_prompt",
                    GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT
                ) end,
            },
            {
                text     = "Clear character database",
                callback = function() self:onClearDatabase() end,
            },
            {
                text     = "Reset prompts to default",
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Reset all prompts to their built-in defaults?",
                        ok_text     = "Reset",
                        ok_callback = function()
                            G_reader_settings:delSetting("kocharacters_extraction_prompt")
                            G_reader_settings:delSetting("kocharacters_cleanup_prompt")
                            G_reader_settings:delSetting("kocharacters_reanalyze_prompt")
                            G_reader_settings:delSetting("kocharacters_relationship_map_prompt")
                            self:showMsg("Prompts reset to defaults.", 2)
                        end,
                    })
                end,
            },
        },
        width       = Screen:getWidth(),
        show_parent = self.ui,
    })
end

function KoCharacters:onSetApiKey()
    local current_key = self:getApiKey()
    local dialog
    dialog = InputDialog:new{
        title       = "Gemini API Key",
        input       = current_key,
        input_hint  = "AIza...",
        description = "Enter your Google Gemini API key.\nGet a free key at aistudio.google.com",
        buttons = {
            {
                {
                    text     = "Cancel",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text             = "Save",
                    is_enter_default = true,
                    callback         = function()
                        local key = dialog:getInputText() or ""
                        key = key:match("^%s*(.-)%s*$") or ""
                        G_reader_settings:saveSetting("kocharacters_api_key", key)
                        UIManager:close(dialog)
                        self:showMsg("API key saved.", 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoCharacters:onEditPrompt(title, setting_key, default_prompt)
    local current = G_reader_settings:readSetting(setting_key) or default_prompt
    local is_custom = G_reader_settings:readSetting(setting_key) ~= nil
    local label = is_custom and "Custom prompt active" or "Using default prompt"
    local dialog
    dialog = InputDialog:new{
        title       = title,
        input       = current,
        description = label .. "\nExtraction: {{existing}} {{skip}} {{text}}\nRe-analyze/Cleanup: {{character}} {{text}}",
        allow_newline = true,
        buttons = {
            {
                {
                    text     = "Cancel",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text     = "Reset",
                    callback = function()
                        UIManager:close(dialog)
                        G_reader_settings:delSetting(setting_key)
                        self:showMsg("Prompt reset to default.", 2)
                    end,
                },
                {
                    text             = "Save",
                    is_enter_default = true,
                    callback         = function()
                        local text = dialog:getInputText() or ""
                        G_reader_settings:saveSetting(setting_key, text)
                        UIManager:close(dialog)
                        self:showMsg("Prompt saved.", 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoCharacters:onDebugPageText()
    if not self.ui or not self.ui.document then
        self:showMsg("No document open.")
        return
    end

    local lines = {}

    -- Document type
    table.insert(lines, "Doc file: " .. tostring(self.ui.document.file))
    table.insert(lines, "Doc type: " .. tostring(self.ui.document.dc_language or self.ui.document.ext or "?"))

    -- Page number
    local page
    pcall(function() page = self.ui.view.state.page end)
    table.insert(lines, "Page: " .. tostring(page))

    -- Try getPageText
    local ok1, result1 = pcall(function()
        return self.ui.document:getPageText(page)
    end)
    table.insert(lines, "getPageText ok=" .. tostring(ok1))
    if ok1 then
        table.insert(lines, "getPageText type=" .. type(result1))
        if type(result1) == "string" then
            table.insert(lines, "getPageText len=" .. #result1)
            table.insert(lines, "preview: " .. result1:sub(1, 80))
        elseif type(result1) == "table" then
            table.insert(lines, "getPageText #=" .. #result1)
            -- Show first entry structure
            local first = result1[1]
            if first then
                table.insert(lines, "first entry type=" .. type(first))
                if type(first) == "table" then
                    table.insert(lines, "first[1] type=" .. type(first[1]))
                    if type(first[1]) == "table" then
                        table.insert(lines, "first[1].word=" .. tostring(first[1].word))
                        table.insert(lines, "first[1].text=" .. tostring(first[1].text))
                    end
                end
            end
        else
            table.insert(lines, "value=" .. tostring(result1))
        end
    else
        table.insert(lines, "error: " .. tostring(result1))
    end

    -- Try getTextBoxes on current page and neighbors
    for _, p in ipairs({page, page-1, page+1}) do
        local ok2, result2 = pcall(function()
            return self.ui.document:getTextBoxes(p)
        end)
        local tag = "getTextBoxes[p=" .. tostring(p) .. "] ok=" .. tostring(ok2)
        if ok2 and type(result2) == "table" then
            tag = tag .. " #lines=" .. #result2
            -- Count words and show sample
            local word_count = 0
            local sample = {}
            for _, line in ipairs(result2) do
                if type(line) == "table" then
                    for _, w in ipairs(line) do
                        if type(w) == "table" and w.word then
                            word_count = word_count + 1
                            if #sample < 5 then table.insert(sample, w.word) end
                        end
                    end
                end
            end
            tag = tag .. " #words=" .. word_count
            if #sample > 0 then
                tag = tag .. "\nsample: " .. table.concat(sample, " ")
            end
        elseif not ok2 then
            tag = tag .. " err=" .. tostring(result2):sub(1,60)
        end
        table.insert(lines, tag)
    end

    -- EPUB uses CreDocument engine - probe its specific methods
    local cre_methods = {
        "getTextFromPositions",
        "getPageLinks",
        "drawCurrentViewByPage",
        "getVisiblePageCount",
        "getPageFromXPointer",
        "getCurrentPos",
        "getXPointer",
        "getPosFromXPointer",
        "getDocumentFileContent",
    }
    for _, m in ipairs(cre_methods) do
        local has = type(self.ui.document[m]) == "function"
        if has then table.insert(lines, "has method: " .. m) end
    end

    -- Test full strategy: getPageXPointer -> getPosFromXPointer -> getTextBoxesFromPositions
    local ok_xp1, xp_cur  = pcall(function() return self.ui.document:getPageXPointer(page or 114) end)
    local ok_xp2, xp_next = pcall(function() return self.ui.document:getPageXPointer((page or 114) + 1) end)
    table.insert(lines, "getPageXPointer(cur) ok=" .. tostring(ok_xp1) .. " val=" .. tostring(xp_cur):sub(1,35))
    table.insert(lines, "getPageXPointer(next) ok=" .. tostring(ok_xp2) .. " val=" .. tostring(xp_next):sub(1,35))

    local pos_s, pos_e
    if ok_xp1 then
        local ok3, p = pcall(function() return self.ui.document:getPosFromXPointer(xp_cur) end)
        table.insert(lines, "getPosFromXPointer(cur) ok=" .. tostring(ok3) .. " val=" .. tostring(p))
        if ok3 then pos_s = p end
    end
    if ok_xp2 then
        local ok4, p = pcall(function() return self.ui.document:getPosFromXPointer(xp_next) end)
        table.insert(lines, "getPosFromXPointer(next) ok=" .. tostring(ok4) .. " val=" .. tostring(p))
        if ok4 then pos_e = p end
    end

    if pos_s then
        local ok5, boxes = pcall(function()
            return self.ui.document:getTextBoxesFromPositions(pos_s, pos_e or pos_s + 5000)
        end)
        table.insert(lines, "getTextBoxesFromPositions ok=" .. tostring(ok5))
        if ok5 and type(boxes) == "table" then
            table.insert(lines, "#boxes=" .. #boxes)
        elseif not ok5 then
            table.insert(lines, "err=" .. tostring(boxes):sub(1,60))
        end
    end

    -- Probe getDocumentFileContent with various arg types
    local frag_idx = tostring(xp_cur or ""):match("DocFragment%[(%d+)%]")
    table.insert(lines, "frag_idx=" .. tostring(frag_idx))

    -- Try with number
    local ok_a, r_a = pcall(function() return self.ui.document:getDocumentFileContent(tonumber(frag_idx)) end)
    table.insert(lines, "getDocFC(number) ok=" .. tostring(ok_a) .. " type=" .. type(r_a))

    -- Try with string index
    local ok_b, r_b = pcall(function() return self.ui.document:getDocumentFileContent(frag_idx) end)
    table.insert(lines, "getDocFC(string) ok=" .. tostring(ok_b) .. " type=" .. type(r_b))

    -- Try getDocumentFilePath or similar
    for _, m in ipairs({"getDocumentFilePath","getFilePath","getImageContent","getToc","getMetadata"}) do
        local has = type(self.ui.document[m]) == "function"
        if has then table.insert(lines, "has: " .. m) end
    end

    -- Try getToc to see structure
    local ok_t, toc = pcall(function() return self.ui.document:getToc() end)
    table.insert(lines, "getToc ok=" .. tostring(ok_t))
    if ok_t and type(toc) == "table" then
        table.insert(lines, "toc #=" .. #toc)
        if toc[1] then
            local keys = {}
            for k,v in pairs(toc[1]) do table.insert(keys, k.."="..tostring(v):sub(1,20)) end
            table.insert(lines, "toc[1]: " .. table.concat(keys, " "))
        end
    end

    -- Try getPageLinks which might reveal file paths
    local ok_l, links = pcall(function() return self.ui.document:getPageLinks(page or 114) end)
    table.insert(lines, "getPageLinks ok=" .. tostring(ok_l))
    if ok_l and type(links) == "table" then
        table.insert(lines, "links #=" .. #links)
        if links[1] then
            local keys = {}
            for k,v in pairs(links[1]) do table.insert(keys, k.."="..tostring(v):sub(1,20)) end
            table.insert(lines, "link[1]: " .. table.concat(keys, " "))
        end
    end

    UIManager:show(TextViewer:new{
        title  = "Debug Info",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

function KoCharacters:onReanalyzeCharacter(book_id, char)
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local page_text, perr = self:getCurrentPageText()
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

    self.db:merge(book_id, characters, self:getCurrentPage())
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

    self.db:updateCharacter(book_id, char_name, char)
    self:showMsg('"' .. char_name .. '" cleaned up.', 3)
end

function KoCharacters:onShowLimits()
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local working_msg = InfoMessage:new{ text = "Fetching model info from Gemini..." }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local info, err
    local ok, call_err = pcall(function()
        info, err = client:fetchModelInfo()
    end)

    UIManager:close(working_msg)

    if not ok then
        self:showMsg("Error:\n" .. tostring(call_err), 6)
        return
    end
    if err then
        self:showMsg("API error:\n" .. tostring(err), 6)
        return
    end

    local lines = {}
    table.insert(lines, "Model")
    table.insert(lines, "  Name:    " .. (info.displayName or info.name or "unknown"))
    table.insert(lines, "  Version: " .. (info.name or ""):match("models/(.+)$") or "?")
    table.insert(lines, "")
    table.insert(lines, "Per-request token limits")
    table.insert(lines, "  Input:   " .. tostring(info.inputTokenLimit  or "?"))
    table.insert(lines, "  Output:  " .. tostring(info.outputTokenLimit or "?"))
    table.insert(lines, "")
    table.insert(lines, "Free tier rate limits")
    table.insert(lines, "  15   requests / minute  (RPM)")
    table.insert(lines, "  500  requests / day     (RPD)")
    table.insert(lines, "  250,000  tokens / minute  (TPM)")
    table.insert(lines, "")
    table.insert(lines, "Note: live usage is not exposed by the API.")
    table.insert(lines, "Check aistudio.google.com to monitor usage.")

    UIManager:show(TextViewer:new{
        title  = "Gemini API Limits",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

return KoCharacters
