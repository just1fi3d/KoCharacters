-- underline.lua
-- Underlines tracked character and codex names on the rendered page, with an
-- optional tap / double-tap action that opens the matching entry.
--
-- How it works (crengine/EPUB only):
--   1. scan  — doc:findAllText over an alternation of all tracked names returns
--              xpointer ranges; each is verified via getTextFromXPointers and
--              cached to disk (underline_cache.json), incrementally per name.
--   2. paint — view.paintTo is wrapped; each repaint resolves the matches near
--              the current position (getPosFromXPointer window) into screen
--              boxes via getScreenBoxesFromPositions and draws an underline.
--   3. tap   — highlight's onTap is wrapped (single tap) and a double_tap touch
--              zone registered; a hit on an underline box opens the entry.
--
-- Entries extracted mid-session get a debounced incremental rescan (one
-- findAllText per extraction event, batching all new names), so they are
-- underlined from the next page turn onward. The "Underline new entries
-- immediately" setting (default ON) can disable this; the match set then
-- refreshes only on book open or via "Rescan book now" in settings.

local UIManager   = require("ui/uimanager")
local Screen      = require("device").screen
local Blitbuffer  = require("ffi/blitbuffer")
local json        = require("dkjson")
local logger      = require("logger")

local UICharacter = require("ui_character")
local UICodex     = require("ui_codex")

-- Returns true if the screensaver is currently up (device asleep/suspended showing
-- the cover). A debounced incremental rescan can still fire in the background while
-- asleep (a plugged-in device stays awake enough to keep running); repainting over
-- the screensaver flashes the e-ink and leaves it darker than its normal render.
local function isScreenSaverActive()
    local Device = require("device")
    return Device.screen_saver_mode == true
end

local UNDERLINE_COLOR    = Blitbuffer.Color8(0x55)
local MAX_HITS           = 10000
local MAX_BOXES_PER_PAGE = 80
local MIN_NAME_LEN       = 3

local Underline = {}
Underline.__index = Underline

function Underline.new(plugin)
    local self = setmetatable({}, Underline)
    self.plugin          = plugin
    self._matches        = nil   -- sorted by .pos: {s, e, n (name_low), pos}
    self._scanned_names  = nil   -- set of name_low covered by _matches
    self._targets        = nil   -- name_low -> {text, kind} for the current match set
    self._pos_hash       = nil   -- rendering hash the .pos values were computed under
    self._box_cache      = nil
    self._box_cache_sig  = nil
    self._current_boxes  = {}
    self._hooked         = false
    self._unsupported    = false
    self._refresh_queued = false
    return self
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function Underline:isEnabled()
    return G_reader_settings:isTrue("kocharacters_underline_enabled")
end

-- "off" | "single" | "double"
function Underline:tapMode()
    return G_reader_settings:readSetting("kocharacters_underline_tap") or "off"
end

function Underline:includeCodex()
    return G_reader_settings:nilOrTrue("kocharacters_underline_codex")
end

function Underline:autoAddNew()
    return G_reader_settings:nilOrTrue("kocharacters_underline_auto_add")
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Underline:onReaderReady()
    local doc = self.plugin.ui.document
    if not doc or not doc.file
        or type(doc.findAllText) ~= "function"
        or type(doc.getScreenBoxesFromPositions) ~= "function"
        or type(doc.getPosFromXPointer) ~= "function" then
        self._unsupported = true
        return
    end
    self._unsupported = false
    self:_installHooks()
    if self:isEnabled() then
        -- Defer the initial load/scan so it never delays the first page render.
        local uself = self
        UIManager:scheduleIn(1.5, function()
            pcall(function() uself:refresh(false) end)
        end)
    end
end

function Underline:_installHooks()
    if self._hooked then return end
    local uself = self

    local view = self.plugin.ui.view
    local orig_paint = view.paintTo
    view.paintTo = function(view_self, bb, x, y)
        orig_paint(view_self, bb, x, y)
        -- This only runs when the reader page is genuinely being drawn, which
        -- can't happen while the screensaver covers it — so a refresh deferred
        -- because the device was asleep is safe to run from here: it means the
        -- device just woke, with no polling needed to detect that.
        if uself._refresh_pending_wake then
            uself._refresh_pending_wake = false
            UIManager:scheduleIn(0, function() pcall(function() uself:refresh(false) end) end)
        end
        local ok, err = pcall(function() uself:_drawUnderlines(bb) end)
        if not ok then logger.warn("KoCharacters: underline draw error: " .. tostring(err)) end
    end

    -- Single tap: wrap ReaderHighlight's onTap — it already overrides the
    -- page-turn zones, so consuming a hit here cleanly beats tap_forward.
    local hl = self.plugin.ui.highlight
    if hl then
        local orig_tap = hl.onTap
        hl.onTap = function(hl_self, arg, ges)
            if ges and uself:_handleTap(ges, "single") then return true end
            if orig_tap then return orig_tap(hl_self, arg, ges) end
        end
    end

    -- Double tap: needs its own touch zone. Only fires if the user has enabled
    -- double taps in KOReader (Taps and gestures — off by default).
    pcall(function()
        uself.plugin.ui:registerTouchZones({
            {
                id  = "kocharacters_underline_double_tap",
                ges = "double_tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler = function(ges) return uself:_handleTap(ges, "double") end,
            },
        })
    end)

    self._hooked = true
end

-- Called after extraction merges new characters/codex entries into the DB.
-- Runs a debounced incremental scan for the new names (default). With "auto
-- add" off, does nothing — new names then appear on the next book open or
-- manual rescan.
function Underline:onDataChanged()
    if self._unsupported or not self:isEnabled() or not self:autoAddNew() then return end
    if not self._scanned_names then return end  -- initial scan hasn't run yet
    if self._refresh_queued then return end
    -- Cheap in-memory diff first: skip disk/scan work when nothing changed.
    -- A change is a new name, a removed name, or a name whose kind flipped
    -- (entry moved between codex and characters); a kind flip needs no rescan
    -- but must rebuild _targets or taps keep resolving against the old side.
    local targets = self:_buildTargets()
    local changed = false
    for name_low, t in pairs(targets) do
        local prev = self._targets and self._targets[name_low]
        if not self._scanned_names[name_low] or (prev and prev.kind ~= t.kind) then
            changed = true; break
        end
    end
    if not changed then
        for name_low in pairs(self._scanned_names) do
            if not targets[name_low] then changed = true; break end
        end
    end
    if not changed then return end
    self._refresh_queued = true
    local uself = self
    UIManager:scheduleIn(2, function()
        uself._refresh_queued = false
        if isScreenSaverActive() then
            -- Device asleep (still running because it's plugged in): don't scan/
            -- repaint over the screensaver. Defer to the paintTo hook below,
            -- which only ever runs once the reader page is genuinely being
            -- drawn again — i.e. after the screensaver is gone — so there's no
            -- polling and no cost while asleep.
            uself._refresh_pending_wake = true
            return
        end
        pcall(function() uself:refresh(false) end)
    end)
end

-- ---------------------------------------------------------------------------
-- Name collection
-- ---------------------------------------------------------------------------

-- The DB stores names with ASCII apostrophes but book text usually has the
-- typographic one (U+2019). All target keys and verification text are
-- normalised to ASCII; the scan pattern accepts either form.
local function normApostrophe(s)
    return (s:gsub("\226\128\153", "'"))
end

-- Returns name_low -> { text = original-case name, kind = "char"|"codex",
-- token = true for standalone name-part tokens }.
-- Character names win over aliases, characters win over codex entries, and
-- standalone name-part tokens come last so they never shadow an exact name.
function Underline:_buildTargets()
    local targets = {}
    local function add(text, kind, is_token)
        if type(text) ~= "string" then return end
        text = text:match("^%s*(.-)%s*$") or ""
        if #text < MIN_NAME_LEN or text:find("\n") then return end
        local low = normApostrophe(text):lower()
        if not targets[low] then
            targets[low] = { text = text, kind = kind, token = is_token or nil }
        end
    end

    local book_id = self.plugin:getBookID()
    if not book_id then return targets end

    local chars = self.plugin.db:load(book_id)
    for _, c in ipairs(chars) do add(c.name, "char") end
    for _, c in ipairs(chars) do
        for _, alias in ipairs(c.aliases or {}) do add(alias, "char") end
    end
    if self:includeCodex() then
        local entries = self.plugin.db_codex:load(book_id)
        for _, e in ipairs(entries) do add(e.name, "codex") end
        for _, e in ipairs(entries) do
            for _, alias in ipairs(e.aliases or {}) do add(alias, "codex") end
        end
    end

    -- Standalone name parts: "Rovigo" from "Rovigo d'Astibar" should still be
    -- underlined when it appears alone. Tokens of ≥4 chars are added for
    -- characters only, and only up to the first lowercase-initial token:
    -- everything after a particle ("of", "di", "bar") is a locative or
    -- patronymic reference to something other than this character — "Garin of
    -- Lower Corte" must not claim standalone "Corte" (the province), and
    -- "Devin d'Asoli bar Garin" must not claim "Garin" (the father).
    -- Non-ASCII initials ("Éanna"), which %l can't classify, don't stop the
    -- scan. Tokens containing an apostrophe ("d'Astibar") are skipped — with
    -- several characters sharing a locative surname a tap on it would be
    -- ambiguous.
    for _, c in ipairs(chars) do
        local names = { c.name }
        for _, alias in ipairs(c.aliases or {}) do names[#names + 1] = alias end
        for _, full in ipairs(names) do
            if type(full) == "string" then
                for token in full:gmatch("%S+") do
                    token = token:gsub("^%p+", ""):gsub("%p+$", "")
                    if token:match("^[%l%d]") then break end
                    if #token >= 4
                        and not token:find("'") and not token:find("\226\128\153") then
                        add(token, "char", true)
                    end
                end
            end
        end
    end
    return targets
end

-- ---------------------------------------------------------------------------
-- Scan + cache
-- ---------------------------------------------------------------------------

local _RE_MAGIC = {
    ["."] = true, ["^"] = true, ["$"] = true, ["*"] = true, ["+"] = true,
    ["?"] = true, ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
    ["{"] = true, ["}"] = true, ["|"] = true, ["\\"] = true,
}
local function reEscape(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if _RE_MAGIC[c] then out[#out + 1] = "\\" end
        out[#out + 1] = c
    end
    return table.concat(out)
end

-- Full names may appear lowercase in prose (codex entries for common nouns:
-- "casks of buinath") or start with a lowercased article ("the Palm"), while
-- the stored name is capitalized — so the first letter matches either case.
-- Later letters stay case-sensitive: "The Palm" must not match "the palm"
-- (the hand), and name-part tokens stay fully case-sensitive so "Lower"
-- can't underline ordinary prose.
local function firstLetterCaseClass(esc)
    local c = esc:sub(1, 1)
    local u, l = c:upper(), c:lower()
    if u == l then return esc end
    return "[" .. u .. l .. "]" .. esc:sub(2)
end

-- Bump when scan semantics change (v2: apostrophe normalisation + name-part
-- tokens; v3: case-tolerant word-initial letters for full names; v4: name-part
-- tokens stop at the first lowercase-initial word; v5: reject hits with a
-- non-empty matched_word_prefix/suffix, i.e. matches sitting inside a larger
-- word — crengine's \b doesn't reliably stop this on its own, e.g. "Elf"
-- matching inside "himself"; v6: no \b on non-ASCII/punctuation name edges,
-- which crengine's ASCII-only \b made unmatchable, e.g. "Brontë"); a version
-- mismatch discards the cache so old books rescan.
local CACHE_VERSION = 6

function Underline:_cachePath(book_id)
    return self.plugin.db:bookDir(book_id) .. "/underline_cache.json"
end

-- xpointers look like ".../text().162" — split into node path and char offset.
local function xpOffset(xp)
    local prefix, num = xp:match("^(.*%.)(%d+)$")
    if not prefix then return xp, 0 end
    return prefix, tonumber(num)
end

-- Drop matches fully contained inside a longer match on the same text node —
-- e.g. codex "Astibar" inside character "Rovigo d'Astibar", or the standalone
-- "Rovigo" token inside the full name. Runs on the in-memory set only; the
-- cache keeps every raw match so removing an entry later can't lose data.
local function dropContained(matches)
    local infos = {}
    for i, m in ipairs(matches) do
        local sn, so = xpOffset(m.s)
        local en, eo = xpOffset(m.e)
        infos[i] = { m = m, sn = sn, so = so, eo = eo, single = (sn == en) }
    end
    table.sort(infos, function(a, b)
        if a.sn ~= b.sn then return a.sn < b.sn end
        if a.so ~= b.so then return a.so < b.so end
        return a.eo > b.eo
    end)
    local out, actives, cur_node = {}, {}, nil
    for _, info in ipairs(infos) do
        if info.sn ~= cur_node then cur_node = info.sn; actives = {} end
        local contained = false
        if info.single then
            for _, a in ipairs(actives) do
                if a.so <= info.so and a.eo >= info.eo
                    and not (a.so == info.so and a.eo == info.eo) then
                    contained = true; break
                end
            end
        end
        if not contained then
            out[#out + 1] = info.m
            if info.single then actives[#actives + 1] = info end
        end
    end
    return out
end

local function readCache(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a"); f:close()
    return json.decode(content)
end

-- Chapter openers often put the first letter in its own inline node
-- ("<span class="DROP-CAPS">A</span>lex nailed…"), and the full-name pattern in
-- _scanNames never matches across that boundary. Search the names minus their first
-- letter instead, step back one visible char to the drop cap, and accept a hit only
-- if the combined text is exactly a tracked name. Returns matches, ok; ok=false means
-- the call ran past DROPCAP_MAX_SEC and the caller should give up on this pass.
local DROPCAP_MAX_SEC = 15

function Underline:_scanDropCapNames(doc, names, targets)
    local out = {}
    if type(doc.getPrevVisibleChar) ~= "function" then return out, true end
    local alts, tails = {}, {}
    for _, name_low in ipairs(names) do
        local text = normApostrophe(targets[name_low].text)
        if text:match("^%a") and #text >= 4 then
            local tail = text:sub(2)
            tails[tail:lower()] = true
            local esc = reEscape(tail):gsub("'", "['\226\128\153]")
            alts[#alts + 1] = esc .. (tail:match("[%w_]$") and "\\b" or "")
        end
    end
    if #alts == 0 then return out, true end
    table.sort(alts, function(a, b) return #a > #b end)
    local t0 = os.time()
    local ok, hits = pcall(doc.findAllText, doc, "(" .. table.concat(alts, "|") .. ")", false, 1, MAX_HITS, true)
    if not ok or type(hits) ~= "table" then
        if not ok then logger.warn("KoCharacters: drop-cap findAllText failed: " .. tostring(hits)) end
        return out, true
    end
    for _, m in ipairs(hits) do
        if os.time() - t0 > DROPCAP_MAX_SEC then return out, false end
        local xp_start, xp_end = m.start, m["end"]
        local prefix = m.matched_word_prefix or ""
        -- A drop-cap tail starts at offset 0 of the text node following the drop cap's
        -- node; ordinary mid-sentence mentions don't, so skip them before the costlier
        -- per-hit document calls.
        if xp_start and xp_end and #prefix <= 1 and xp_start:find("%.0$")
            and not xp_start:find("/h[1-6][%[/]") then
            local okp, xp_prev = pcall(doc.getPrevVisibleChar, doc, xp_start)
            if okp and type(xp_prev) == "string" and xp_prev ~= xp_start then
                local okt, text = pcall(doc.getTextFromXPointers, doc, xp_prev, xp_end)
                if okt and type(text) == "string" and text:match("^%a") then
                    local low = normApostrophe(text):lower()
                    if targets[low] and tails[low:sub(2)] then
                        out[#out + 1] = { s = xp_prev, e = xp_end, n = low }
                    end
                end
            end
        end
    end
    return out, os.time() - t0 <= DROPCAP_MAX_SEC
end

-- Run findAllText for the given list of names; returns raw matches {s, e, n}.
-- Heading hits (chapter/book titles) are dropped.
function Underline:_scanNames(doc, names, targets)
    local alts = {}
    for _, name_low in ipairs(names) do
        local target = targets[name_low]
        local esc = reEscape(normApostrophe(target.text))
        if not target.token then esc = firstLetterCaseClass(esc) end
        -- Match either apostrophe form in the book text
        alts[#alts + 1] = (esc:gsub("'", "['\226\128\153]"))
    end
    if #alts == 0 then return {} end
    -- Longest first: alternation is leftmost-first, so "Devin" before
    -- "Devin d'Asoli" would stop the match (and the underline) at "Devin".
    table.sort(alts, function(a, b) return #a > #b end)
    -- crengine's regex (SRELL, no Unicode data) has ASCII-only \b: an edge
    -- next to a non-ASCII letter or punctuation ("Brontë", "Éanna") never
    -- sees a boundary, so the name could never match. Only anchor edges that
    -- are ASCII word chars; the matched_word_prefix/suffix check below still
    -- rejects hits sitting inside a larger word.
    for i, alt in ipairs(alts) do
        local lead  = alt:match("^%[?[%w_]") and "\\b" or ""
        local trail = alt:match("[%w_]$") and "\\b" or ""
        alts[i] = lead .. alt .. trail
    end
    local pattern = "(" .. table.concat(alts, "|") .. ")"

    local ok, hits = pcall(doc.findAllText, doc, pattern, false, 1, MAX_HITS, true)
    if not ok or type(hits) ~= "table" then
        if not ok then logger.warn("KoCharacters: findAllText failed: " .. tostring(hits)) end
        return {}
    end

    local out = {}
    for _, m in ipairs(hits) do
        local xp_start = m.start
        local xp_end   = m["end"]
        -- crengine's \b assertion doesn't reliably stop regex matches at word
        -- boundaries (e.g. "Elf" matching inside "himself"); matched_word_prefix/
        -- suffix are non-empty whenever the hit sits inside a larger word, so use
        -- them as a second boundary check independent of the regex engine's own.
        local whole_word = (m.matched_word_prefix == nil or m.matched_word_prefix == "")
            and (m.matched_word_suffix == nil or m.matched_word_suffix == "")
        if xp_start and xp_end and whole_word and not xp_start:find("/h[1-6][%[/]") then
            -- matched_text includes context words — recover the exact hit text.
            local okt, text = pcall(doc.getTextFromXPointers, doc, xp_start, xp_end)
            if okt and type(text) == "string" then
                local low = normApostrophe(text:match("^%s*(.-)%s*$") or ""):lower()
                if targets[low] then
                    out[#out + 1] = { s = xp_start, e = xp_end, n = low }
                end
            end
        end
    end
    return out
end

-- Runs step(batch) over `names` in adaptively sized batches, yielding to the UI
-- between batches so the reader can keep turning pages. findAllText is one blocking
-- C call over the whole book, so the work is cut into short calls (halved when a call
-- freezes the UI for BATCH_SLOW_SEC+, doubled when under BATCH_FAST_SEC) instead of
-- one long freeze. `gap` is the idle time between batches: long for background scans
-- so page turns get through, short for a user-requested rescan.
-- step returns false to stop; on_done(completed_count, stopped_early) runs last.
local BATCH_SLOW_SEC, BATCH_FAST_SEC = 2.5, 1.0

local function monotonicSec()
    local ok, time = pcall(require, "ui/time")
    if ok and time and time.monotonic and time.to_s then
        return function() return time.to_s(time.monotonic()) end
    end
    return os.time
end
local nowSec = monotonicSec()

local function runBatches(self, names, size, max_size, gap, step, on_progress, on_done)
    local i, doc = 1, self.plugin.ui.document
    local function nextBatch()
        if self._scan_cancel or self.plugin.ui.document ~= doc or i > #names then
            return on_done(i - 1, self._scan_cancel or i <= #names)
        end
        local batch = {}
        for k = i, math.min(i + size - 1, #names) do batch[#batch + 1] = names[k] end
        local t0 = nowSec()
        local keep_going = step(batch)
        local dt = nowSec() - t0
        i = i + #batch
        if dt >= BATCH_SLOW_SEC then size = math.max(1, math.floor(size / 2))
        elseif dt < BATCH_FAST_SEC then size = math.min(max_size, size * 2) end
        on_progress(i - 1, #names)
        if keep_going == false then return on_done(i - 1, true) end
        UIManager:scheduleIn(gap, nextBatch)
    end
    UIManager:scheduleIn(gap, nextBatch)
end

-- Small top-right progress toast. Replaced in place on each update; repaints only
-- its own region with a "fast" refresh so the page underneath isn't flashed.
function Underline:_showProgressToast(text)
    if isScreenSaverActive() then return end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextWidget     = require("ui/widget/textwidget")
    local Font           = require("ui/font")
    self:_hideProgressToast()
    local toast = FrameContainer:new{
        toast      = true,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 1,
        padding    = 4,
        TextWidget:new{ text = text, face = Font:getFace("cfont", 16) },
    }
    local size = toast:getSize()
    local x = Screen:getWidth() - size.w
    toast.dimen = require("ui/geometry"):new{ x = x, y = 0, w = size.w, h = size.h }
    self._progress_toast = toast
    UIManager:show(toast, "fast", toast.dimen, x, 0)
end

function Underline:_hideProgressToast()
    local toast = self._progress_toast
    if not toast then return end
    self._progress_toast = nil
    UIManager:close(toast, "fast", toast.dimen)
end

function Underline:isScanning()
    return self._scanning == true
end

-- Stops a running scan after the current batch; names scanned so far stay cached.
function Underline:cancelScan()
    if self._scanning then
        self._scan_cancel  = true
        self._rescan_after = false
    end
end

-- Load the disk cache, scan any names not yet covered (full-name pass, then the
-- drop-cap pass), drop names no longer tracked, persist, then compute screen
-- positions and activate the match set. The scans run in yielding batches with a
-- non-modal corner toast; cancelScan() stops early, keeping whatever was covered.
-- interactive=true shows a summary when finished (settings-menu triggered).
function Underline:refresh(interactive)
    if self._unsupported then return end
    if self._scanning then self._rescan_after = true; return end
    local doc     = self.plugin.ui.document
    local book_id = self.plugin:getBookID()
    if not doc or not book_id then return end

    local targets = self:_buildTargets()
    local path    = self:_cachePath(book_id)

    local mtime = nil
    pcall(function() mtime = require("libs/libkoreader-lfs").attributes(doc.file, "modification") end)

    local cache = readCache(path)
    if type(cache) ~= "table" or type(cache.matches) ~= "table" or type(cache.names) ~= "table"
        or cache.version ~= CACHE_VERSION
        or (mtime and cache.mtime ~= mtime) then
        cache = { mtime = mtime, names = {}, matches = {} }  -- stale or absent → full rescan
    end

    -- covered: name_low sets for each pass. The drop-cap pass was added to v6
    -- caches later, so a missing list simply means "not run yet" for those names.
    local covered, dc_covered = {}, {}
    for _, n in ipairs(cache.names) do covered[n] = true end
    for _, n in ipairs(type(cache.dropcap) == "table" and cache.dropcap or {}) do dc_covered[n] = true end

    local to_scan, dc_to_scan, removed = {}, {}, {}
    for name_low in pairs(targets) do
        if not covered[name_low] then to_scan[#to_scan + 1] = name_low end
        if not dc_covered[name_low] then dc_to_scan[#dc_to_scan + 1] = name_low end
    end
    for name_low in pairs(covered) do
        if not targets[name_low] then removed[name_low] = true end
    end

    local matches, have = {}, {}
    local function addMatch(m)
        local key = m.n .. "|" .. m.s .. "|" .. m.e
        if have[key] then return end
        have[key] = true
        matches[#matches + 1] = m
    end
    for _, m in ipairs(cache.matches) do
        if m.n and targets[m.n] and not removed[m.n] then addMatch(m) end
    end

    local uself = self
    local function finish(full_done, dc_done)
        -- Only names actually scanned count as covered, so a cancelled scan
        -- resumes where it left off on the next refresh.
        local names_list, dc_list = {}, {}
        for name_low in pairs(targets) do
            if covered[name_low] then names_list[#names_list + 1] = name_low end
            if dc_covered[name_low] then dc_list[#dc_list + 1] = name_low end
        end
        local f = io.open(path, "w")
        if f then
            f:write(json.encode({ version = CACHE_VERSION, mtime = mtime, names = names_list,
                                  dropcap = dc_list, matches = matches }))
            f:close()
        end

        uself._targets       = targets
        uself._matches       = dropContained(matches)
        uself._scanned_names = {}
        for _, name_low in ipairs(names_list) do uself._scanned_names[name_low] = true end
        uself._pos_hash      = nil   -- force position (re)computation
        uself._box_cache_sig = nil

        -- Repaint so the change shows on the current page (underlines of deleted
        -- entries vanish, freshly scanned names appear) without a page turn.
        if full_done > 0 or dc_done > 0 or next(removed) then
            UIManager:setDirty(nil, "ui")
        end
        if interactive then
            uself.plugin:showMsg("Underlines: " .. #matches .. " occurrence(s) of "
                .. #names_list .. " tracked name(s).", 3)
        end
    end

    if #to_scan == 0 and #dc_to_scan == 0 then
        finish(0, 0)
        return
    end

    self._scanning, self._scan_cancel = true, false
    -- Progress is a small corner toast: toasts never consume input, so the reader
    -- keeps turning pages and tapping normally while the scan runs. Cancel lives in
    -- the underline settings menu ("Cancel underline scan").
    local last_msg_ts = 0
    local function showProgress(label, done, total, force)
        if not (interactive or #to_scan > 3 or #dc_to_scan > 3) then return end
        if not force and nowSec() - last_msg_ts < 3 then return end
        last_msg_ts = nowSec()
        uself:_showProgressToast("Underlining " .. label .. " " .. done .. "/" .. total)
    end
    local function endScan(full_done, dc_done)
        uself:_hideProgressToast()
        uself._scanning = false
        local again = uself._rescan_after
        uself._rescan_after = false
        finish(full_done, dc_done)
        if again and not uself._scan_cancel then
            UIManager:scheduleIn(0.5, function() pcall(function() uself:refresh(false) end) end)
        end
    end

    local gap = interactive and 0.2 or 1.0
    local full_done = 0
    local function runDropCapPass()
        local dc_done = 0
        local aborted = false
        runBatches(self, dc_to_scan, 2, 12, gap,
            function(batch)
                local found, in_time = uself:_scanDropCapNames(doc, batch, targets)
                for _, m in ipairs(found) do addMatch(m) end
                if not in_time then
                    aborted = true
                    logger.warn("KoCharacters: drop-cap scan too slow; skipping it for this book")
                    -- Mark everything covered so a slow device isn't re-stalled on every open.
                    for _, n in ipairs(dc_to_scan) do dc_covered[n] = true end
                    return false
                end
                for _, n in ipairs(batch) do dc_covered[n] = true end
            end,
            function(done, total) showProgress("drop caps", done, total) end,
            function(done) endScan(full_done, aborted and 0 or done) end)
    end

    runBatches(self, to_scan, 2, 16, gap,
        function(batch)
            for _, m in ipairs(uself:_scanNames(doc, batch, targets)) do addMatch(m) end
            for _, n in ipairs(batch) do covered[n] = true end
        end,
        function(done, total) showProgress("names", done, total) end,
        function(done, stopped)
            full_done = done
            if stopped or uself._scan_cancel or #dc_to_scan == 0 then
                return endScan(full_done, 0)
            end
            runDropCapPass()
        end)
    if #to_scan > 0 then showProgress("names", 0, #to_scan, true) end
end

-- Compute (or recompute after reflow) document positions for every match and
-- sort by position. Cheap C calls; runs once per rendering hash.
function Underline:_ensurePositions(doc)
    local hash
    pcall(function() hash = doc:getDocumentRenderingHash() end)
    hash = hash or false   -- false (not nil) so a missing API doesn't recompute every paint
    if self._pos_hash == hash then return end
    for _, m in ipairs(self._matches) do
        local ok, pos = pcall(doc.getPosFromXPointer, doc, m.s)
        m.pos = (ok and type(pos) == "number") and pos or -1
    end
    table.sort(self._matches, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
    self._pos_hash      = hash
    self._box_cache_sig = nil
end

-- ---------------------------------------------------------------------------
-- Paint
-- ---------------------------------------------------------------------------

function Underline:_boxCacheSig(doc)
    local ok, sig = pcall(function()
        return table.concat({
            doc:getCurrentPage(), doc:getCurrentPos(), doc:getDocumentRenderingHash(),
            Screen:getWidth(), Screen:getHeight(), tostring(self._matches),
        }, "|")
    end)
    return ok and sig or nil
end

function Underline:_resolveBoxes(doc)
    local boxes_out = {}
    local pos0 = nil
    pcall(function() pos0 = doc:getCurrentPos() end)
    if type(pos0) ~= "number" then return boxes_out end
    local window_end = pos0 + Screen:getHeight() * 3

    -- Binary search the first match at/after the top of the current view.
    local lo, hi = 1, #self._matches
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if (self._matches[mid].pos or 0) < pos0 - 50 then lo = mid + 1 else hi = mid end
    end

    for i = lo, #self._matches do
        local m = self._matches[i]
        if (m.pos or 0) > window_end then break end
        if #boxes_out >= MAX_BOXES_PER_PAGE then break end
        local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, m.s, m.e, true)
        if ok and type(boxes) == "table" then
            for _, box in ipairs(boxes) do
                if box.w and box.h and box.w > 0 and box.h > 0 then
                    boxes_out[#boxes_out + 1] = { box = box, match = m }
                end
            end
        end
    end
    return boxes_out
end

function Underline:_drawUnderlines(bb)
    if self._unsupported or not self:isEnabled() then return end
    if not self._matches or #self._matches == 0 then
        self._current_boxes = {}
        return
    end
    local doc = self.plugin.ui.document
    if not doc then return end

    self:_ensurePositions(doc)

    local sig = self:_boxCacheSig(doc)
    if sig and sig == self._box_cache_sig and self._box_cache then
        self._current_boxes = self._box_cache
    else
        self._current_boxes = self:_resolveBoxes(doc)
        self._box_cache     = self._current_boxes
        self._box_cache_sig = sig
    end

    local width = Screen:scaleBySize(2)
    for _, e in ipairs(self._current_boxes) do
        local b = e.box
        bb:paintRect(b.x, b.y + b.h - width, b.w, width, UNDERLINE_COLOR)
    end
end

-- ---------------------------------------------------------------------------
-- Tap
-- ---------------------------------------------------------------------------

function Underline:_handleTap(ges, source)
    if self._unsupported or not self:isEnabled() then return false end
    if self:tapMode() ~= source then return false end
    if not self._current_boxes or #self._current_boxes == 0 then return false end
    if not ges or not ges.pos then return false end

    local x, y = ges.pos.x, ges.pos.y
    for _, e in ipairs(self._current_boxes) do
        local b = e.box
        if x >= b.x and x <= b.x + b.w and y >= b.y - 4 and y <= b.y + b.h + 4 then
            self:_openEntry(e.match)
            return true
        end
    end
    return false
end

function Underline:_openEntry(match)
    local target = self._targets and self._targets[match.n]
    if not target then return end
    local plugin = self.plugin
    UIManager:scheduleIn(0.1, function()
        local book_id = plugin:getBookID()
        if not book_id then return end
        -- Resolve at tap time rather than trusting the cached kind: after an
        -- entry moves between codex and characters the underline outlives the
        -- old kind until the debounced refresh lands, so a miss on the
        -- recorded side falls back to the other one.
        if target.kind == "char" then
            if plugin.db:findByName(book_id, target.text) then
                UICharacter.onWordCharacterLookup(plugin, target.text)
            else
                local entry = plugin.db_codex:findByName(book_id, target.text)
                if entry then UICodex.showEntryViewer(plugin, book_id, entry)
                else UICharacter.onWordCharacterLookup(plugin, target.text) end
            end
        else
            local entry = plugin.db_codex:findByName(book_id, target.text)
            if entry then UICodex.showEntryViewer(plugin, book_id, entry)
            else UICharacter.onWordCharacterLookup(plugin, target.text) end
        end
    end)
end

return Underline
