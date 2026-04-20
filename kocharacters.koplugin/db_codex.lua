-- db_codex.lua
-- Manages per-book codex storage using JSON files alongside characters.json

local json        = require("dkjson")
local DataStorage = require("datastorage")
local util        = require("util")
local logger      = require("logger")

local _id_seq = 0
local function generateId()
    _id_seq = _id_seq + 1
    return tostring(os.time()) .. "_" .. tostring(_id_seq)
end

local function unionArrays(a, b)
    local seen = {}
    local result = {}
    for _, v in ipairs(a or {}) do
        if v ~= "" and not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    for _, v in ipairs(b or {}) do
        if v ~= "" and not seen[v] then seen[v] = true; table.insert(result, v) end
    end
    return result
end

local CodexDB = {}
CodexDB.__index = CodexDB

function CodexDB:bookDir(book_md5)
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_md5
    util.makePath(dir)
    return dir
end

function CodexDB:dbPath(book_md5)
    return self:bookDir(book_md5) .. "/codex.json"
end

function CodexDB:load(book_md5)
    local path = self:dbPath(book_md5)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a"); f:close()
    local data, _, err = json.decode(content)
    if not data then return {} end
    local needs_save = false
    for _, e in ipairs(data) do
        if not e.id or e.id == "" then
            e.id = generateId()
            needs_save = true
        end
    end
    if needs_save then self:save(book_md5, data) end
    return data
end

function CodexDB:save(book_md5, entries)
    for _, e in ipairs(entries) do
        if not e.id or e.id == "" then e.id = generateId() end
    end
    local path = self:dbPath(book_md5)
    local f = io.open(path, "w")
    if not f then return false, "Cannot write to " .. path end
    f:write(json.encode(entries, { indent = true }))
    f:close()
    return true
end

-- Upsert entries from an enrichment result.
-- Synthesis fields (description, significance) are taken from the incoming entry — Gemini
-- already rewrote them as a fresh unified summary incorporating the existing values.
-- Preserve-and-extend fields (aliases, known_connections) are unioned in Lua because
-- Gemini may not see the full existing list.
-- first_seen_page and first_appearance_quote are set once and never overwritten.
-- Returns: merged list, count of newly added
function CodexDB:merge(book_md5, new_entries, page_num)
    local existing = self:load(book_md5)

    local name_to_idx = {}
    for i, e in ipairs(existing) do
        if e.name then name_to_idx[e.name:lower()] = i end
        for _, alias in ipairs(e.aliases or {}) do
            if alias ~= "" then name_to_idx[alias:lower()] = i end
        end
    end

    local added = 0
    local changed = false
    for _, e in ipairs(new_entries) do
        if e.name then
            local idx = name_to_idx[e.name:lower()]
            if idx then
                local ex = existing[idx]
                e.id                   = ex.id or generateId()
                e.user_notes           = ex.user_notes
                e.first_seen_page      = ex.first_seen_page
                e.first_appearance_quote = (ex.first_appearance_quote and ex.first_appearance_quote ~= "")
                                           and ex.first_appearance_quote
                                           or e.first_appearance_quote
                e.aliases              = unionArrays(ex.aliases, e.aliases)
                e.known_connections    = unionArrays(ex.known_connections, e.known_connections)
                if page_num then e.source_page = page_num end
                existing[idx] = e
                changed = true
            else
                e.id = generateId()
                if page_num then
                    e.source_page     = page_num
                    e.first_seen_page = e.first_seen_page or page_num
                end
                table.insert(existing, e)
                name_to_idx[e.name:lower()] = #existing
                added = added + 1
                changed = true
            end
        end
    end

    if changed then self:save(book_md5, existing) end
    return existing, added
end

-- Update a single entry in place, looked up by original name
function CodexDB:updateEntry(book_md5, original_name, updated_entry)
    local entries = self:load(book_md5)
    for i, e in ipairs(entries) do
        if e.name == original_name then
            updated_entry.id = updated_entry.id or e.id
            entries[i] = updated_entry
            local ok, err = self:save(book_md5, entries)
            if not ok then
                logger.warn("KoCharacters: CodexDB:updateEntry save failed: " .. tostring(err))
                return false
            end
            return true
        end
    end
    return false
end

function CodexDB:deleteEntry(book_md5, name)
    local entries = self:load(book_md5)
    local new_list = {}
    for _, e in ipairs(entries) do
        if e.name ~= name then table.insert(new_list, e) end
    end
    self:save(book_md5, new_list)
end

-- Returns the matching entry (or nil) for a name or alias — used by the highlight dialog
function CodexDB:findByName(book_md5, name_or_alias)
    local lower = name_or_alias:lower()
    for _, e in ipairs(self:load(book_md5)) do
        if e.name and e.name:lower() == lower then return e end
        for _, alias in ipairs(e.aliases or {}) do
            if alias:lower() == lower then return e end
        end
    end
    return nil
end

-- Returns true if the name/alias is already tracked
function CodexDB:isNameKnown(book_md5, name_or_alias)
    return self:findByName(book_md5, name_or_alias) ~= nil
end

-- Word-boundary match: single-word terms use frontier patterns to avoid substring false
-- positives (e.g. alias "resonant" matching "dissonant"). Multi-word terms fall back to
-- plain substring since frontier patterns don't span spaces reliably.
local function termInText(lower_term, lower_text)
    if lower_term:find("%s") then
        return lower_text:find(lower_term, 1, true) ~= nil
    end
    local escaped = lower_term:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    return lower_text:find("%f[%w]" .. escaped .. "%f[%W]") ~= nil
end

-- Returns entries whose name or any alias appears in page_text (case-insensitive, word-boundary)
function CodexDB:getEntriesForPage(book_md5, page_text)
    local lower_text = page_text:lower()
    local matched = {}
    for _, e in ipairs(self:load(book_md5)) do
        local found = false
        if e.name and termInText(e.name:lower(), lower_text) then
            found = true
        end
        if not found then
            for _, alias in ipairs(e.aliases or {}) do
                if alias ~= "" and termInText(alias:lower(), lower_text) then
                    found = true
                    break
                end
            end
        end
        if found then table.insert(matched, e) end
    end
    return matched
end

function CodexDB:clear(book_md5)
    os.remove(self:dbPath(book_md5))
end

-- Expand partial names in known_connections to full character names where unambiguous.
-- E.g. "Helena (subject)" → "Helena Marino (subject)" if Helena Marino is the only match.
-- characters: array of character records from CharacterDB:load()
function CodexDB:normalizeConnections(book_md5, characters)
    if not characters or #characters == 0 then return end
    local entries = self:load(book_md5)
    if #entries == 0 then return end

    -- Returns true if partial_lower is a word-boundary prefix of full_lower but not equal
    local function isPartialPrefix(partial_lower, full_lower)
        if partial_lower == full_lower then return false end
        return full_lower:sub(1, #partial_lower + 1) == partial_lower .. " "
    end

    -- Build a set of exact character names (lower) for already-full check
    local exact = {}
    for _, c in ipairs(characters) do
        if c.name and c.name ~= "" then exact[c.name:lower()] = true end
        for _, alias in ipairs(c.aliases or {}) do
            if alias ~= "" then exact[alias:lower()] = true end
        end
    end

    local changed = false
    for _, entry in ipairs(entries) do
        if entry.known_connections then
            local new_conns = {}
            for _, conn in ipairs(entry.known_connections) do
                local name_part, rel_part = conn:match("^(.-)%s*%((.-)%)%s*$")
                if name_part and rel_part then
                    name_part = name_part:match("^%s*(.-)%s*$")
                    local name_lower = name_part:lower()
                    if exact[name_lower] then
                        -- Already a full known name — leave unchanged
                        table.insert(new_conns, conn)
                    else
                        -- Find characters whose full name starts with name_part (word boundary)
                        local candidates = {}
                        for _, c in ipairs(characters) do
                            local full_lower = (c.name or ""):lower()
                            if isPartialPrefix(name_lower, full_lower) then
                                local dup = false
                                for _, existing in ipairs(candidates) do
                                    if existing == c.name then dup = true; break end
                                end
                                if not dup then table.insert(candidates, c.name) end
                            end
                        end
                        if #candidates == 1 then
                            table.insert(new_conns, candidates[1] .. " (" .. rel_part .. ")")
                            changed = true
                        else
                            table.insert(new_conns, conn)
                        end
                    end
                else
                    table.insert(new_conns, conn)
                end
            end
            entry.known_connections = new_conns
        end
    end

    if changed then self:save(book_md5, entries) end
end

return CodexDB
