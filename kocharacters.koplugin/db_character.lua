-- db_character.lua
-- Manages per-book character storage using JSON files in the history directory

local json        = require("dkjson")
local DataStorage = require("datastorage")
local util        = require("util")
local logger      = require("logger")

local _id_seq = 0
local function generateId()
    _id_seq = _id_seq + 1
    return tostring(os.time()) .. "_" .. tostring(_id_seq)
end

-- Union two arrays of strings, preserving order and deduplicating by value.
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

-- Merge two text fields: skip if one already contains the other (case-insensitive)
local function mergeText(a, b)
    if not a or a == "" then return b or "" end
    if not b or b == "" then return a end
    if a == b then return a end
    local al, bl = a:lower(), b:lower()
    if al:find(bl, 1, true) then return a end
    if bl:find(al, 1, true) then return b end
    return a .. "; " .. b
end

local CharacterDB = {}
CharacterDB.__index = CharacterDB

-- Return (and create) the per-book directory
function CharacterDB:bookDir(book_md5)
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_md5
    util.makePath(dir)
    return dir
end

-- Return the path to the JSON file for a given book
function CharacterDB:dbPath(book_md5)
    return self:bookDir(book_md5) .. "/characters.json"
end

-- Load the character list for a book (returns empty table if none saved)
function CharacterDB:load(book_md5)
    local path = self:dbPath(book_md5)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    local data, _, err = json.decode(content)
    if not data then
        return {}
    end
    -- Backfill missing IDs (one-time migration for existing DBs)
    local needs_save = false
    for _, c in ipairs(data) do
        if not c.id or c.id == "" then
            c.id = generateId()
            needs_save = true
        end
    end
    if needs_save then self:save(book_md5, data) end
    return data
end

-- Save the full character list for a book
function CharacterDB:save(book_md5, characters)
    -- Safety net: ensure every character has an ID before persisting
    for _, c in ipairs(characters) do
        if not c.id or c.id == "" then
            c.id = generateId()
        end
    end
    local path = self:dbPath(book_md5)
    local f = io.open(path, "w")
    if not f then
        return false, "Cannot write to " .. path
    end
    f:write(json.encode(characters, { indent = true }))
    f:close()
    return true
end

-- Merge new characters into the existing DB.
-- Existing characters whose name matches are updated (replaced); new names are appended.
-- Returns: merged list, count of newly added
function CharacterDB:merge(book_md5, new_characters, page_num)
    local existing = self:load(book_md5)

    -- Build index: lowercased name/alias -> position in existing list
    local name_to_idx = {}
    for i, c in ipairs(existing) do
        if c.name then name_to_idx[c.name:lower()] = i end
        if c.aliases then
            for _, alias in ipairs(c.aliases) do
                if alias ~= "" then name_to_idx[alias:lower()] = i end
            end
        end
    end

    local added = 0
    local changed = false
    for _, c in ipairs(new_characters) do
        if c.name then
            local idx = name_to_idx[c.name:lower()]
            if idx then
                local id          = existing[idx].id                     -- preserve stable ID
                local notes       = existing[idx].user_notes             -- never overwrite user notes
                local first_seen  = existing[idx].first_seen_page        -- set once, never updated
                local first_quote = existing[idx].first_appearance_quote -- set once, never updated
                local prev_moments = existing[idx].defining_moments or {}
                existing[idx] = c
                existing[idx].id = id or generateId()
                if notes       and notes ~= ""       then existing[idx].user_notes          = notes       end
                if first_seen                        then existing[idx].first_seen_page      = first_seen  end
                if first_quote and first_quote ~= "" then existing[idx].first_appearance_quote = first_quote end
                if page_num                          then existing[idx].source_page          = page_num    end
                existing[idx].defining_moments = unionArrays(prev_moments, existing[idx].defining_moments)
                changed = true
            else
                c.id = generateId()
                if page_num then c.source_page = page_num; c.first_seen_page = page_num end
                table.insert(existing, c)
                name_to_idx[c.name:lower()] = #existing
                added = added + 1
                changed = true
            end
        end
    end

    if changed then
        self:save(book_md5, existing)
    end

    return existing, added
end

-- Return a flat list of known character names for the Claude prompt
function CharacterDB:getKnownNames(book_md5)
    local characters = self:load(book_md5)
    local names = {}
    for _, c in ipairs(characters) do
        table.insert(names, c.name)
        if c.aliases then
            for _, alias in ipairs(c.aliases) do
                table.insert(names, alias)
            end
        end
    end
    return names
end

-- Merge source character into target: combines fields, removes source
function CharacterDB:mergeCharacters(book_md5, source_name, target_name)
    if source_name == target_name then return false end
    local characters = self:load(book_md5)
    local source, target, source_idx = nil, nil, nil
    for i, c in ipairs(characters) do
        if c.name == source_name then source = c; source_idx = i end
        if c.name == target_name then target = c end
    end
    if not source or not target or not source_idx then return false end

    -- Aliases: union of both, plus the source name itself
    local alias_set = {}
    for _, a in ipairs(target.aliases or {}) do if a ~= "" then alias_set[a] = true end end
    for _, a in ipairs(source.aliases or {}) do if a ~= "" then alias_set[a] = true end end
    alias_set[source_name] = true  -- source name becomes an alias of target
    local merged_aliases = {}
    for a in pairs(alias_set) do table.insert(merged_aliases, a) end


    -- Relationships: union
    local rel_set = {}
    for _, r in ipairs(target.relationships or {}) do if r ~= "" then rel_set[r] = true end end
    for _, r in ipairs(source.relationships or {}) do if r ~= "" then rel_set[r] = true end end
    local merged_rels = {}
    for r in pairs(rel_set) do table.insert(merged_rels, r) end

    -- identity_tags: union of both
    local tag_set = {}
    for _, t in ipairs(target.identity_tags or {}) do if t ~= "" then tag_set[t] = true end end
    for _, t in ipairs(source.identity_tags or {}) do if t ~= "" then tag_set[t] = true end end
    local merged_tags = {}
    for t in pairs(tag_set) do table.insert(merged_tags, t) end

    -- defining_moments: union of both (append-only, preserve all distinct events)
    local merged_moments = unionArrays(target.defining_moments, source.defining_moments)

    -- motivation: prefer target's if set, otherwise take source's
    local motivation = (target.motivation and target.motivation ~= "") and target.motivation
                       or (source.motivation or "")

    -- Role: prefer a non-unknown value
    local role = target.role or "unknown"
    if (role == "unknown" or role == "") and source.role and source.role ~= "unknown" then
        role = source.role
    end

    -- First appearance quote: keep target's if set
    local quote = target.first_appearance_quote or ""
    if quote == "" then quote = source.first_appearance_quote or "" end

    local notes_a = target.user_notes or ""
    local notes_b = source.user_notes or ""
    local merged_notes = notes_a ~= "" and notes_b ~= "" and (notes_a .. "\n" .. notes_b)
                      or notes_a ~= "" and notes_a
                      or notes_b ~= "" and notes_b
                      or nil

    target.aliases                = merged_aliases
    target.identity_tags          = merged_tags
    target.physical_description   = mergeText(target.physical_description, source.physical_description)
    target.personality            = mergeText(target.personality, source.personality)
    target.motivation             = motivation
    target.defining_moments       = merged_moments
    target.relationships          = merged_rels
    target.role                   = role
    target.first_appearance_quote = quote
    target.user_notes             = merged_notes

    table.remove(characters, source_idx)
    local ok, err = self:save(book_md5, characters)
    if not ok then
        logger.warn("KoCharacters: mergeCharacters save failed: " .. tostring(err))
        return false
    end
    return true
end

-- Enrich an existing character with data from an external profile (not in DB)
-- The external name becomes an alias; all fields are merged.
function CharacterDB:enrichCharacter(book_md5, existing_name, extra, page_num)
    local characters = self:load(book_md5)
    for _, c in ipairs(characters) do
        if c.name == existing_name then
            local alias_set = {}
            for _, a in ipairs(c.aliases   or {}) do if a ~= "" then alias_set[a] = true end end
            for _, a in ipairs(extra.aliases or {}) do if a ~= "" then alias_set[a] = true end end
            if extra.name and extra.name ~= existing_name then alias_set[extra.name] = true end
            local merged_aliases = {}
            for a in pairs(alias_set) do table.insert(merged_aliases, a) end


            local rel_set = {}
            for _, r in ipairs(c.relationships   or {}) do if r ~= "" then rel_set[r] = true end end
            for _, r in ipairs(extra.relationships or {}) do if r ~= "" then rel_set[r] = true end end
            local merged_rels = {}
            for r in pairs(rel_set) do table.insert(merged_rels, r) end

            -- identity_tags: union
            local tag_set = {}
            for _, t in ipairs(c.identity_tags    or {}) do if t ~= "" then tag_set[t] = true end end
            for _, t in ipairs(extra.identity_tags or {}) do if t ~= "" then tag_set[t] = true end end
            local merged_tags = {}
            for t in pairs(tag_set) do table.insert(merged_tags, t) end

            -- defining_moments: append incoming to existing (never overwrite)
            local merged_moments = unionArrays(c.defining_moments, extra.defining_moments)

            -- motivation: take extra's value only if current is empty
            local motivation = (c.motivation and c.motivation ~= "") and c.motivation
                               or (extra.motivation or "")

            local role = c.role or "unknown"
            if (role == "unknown" or role == "") and extra.role and extra.role ~= "unknown" then
                role = extra.role
            end

            c.aliases              = merged_aliases
            c.identity_tags        = merged_tags
            c.physical_description = mergeText(c.physical_description, extra.physical_description)
            c.personality          = mergeText(c.personality,          extra.personality)
            c.motivation           = motivation
            c.defining_moments     = merged_moments
            c.relationships        = merged_rels
            c.role                 = role
            if (not c.first_appearance_quote or c.first_appearance_quote == "") and extra.first_appearance_quote then
                c.first_appearance_quote = extra.first_appearance_quote
            end
            if page_num then c.source_page = page_num end
            c.needs_cleanup = true

            local ok, err = self:save(book_md5, characters)
            if not ok then
                logger.warn("KoCharacters: enrichCharacter save failed: " .. tostring(err))
                return false
            end
            return true
        end
    end
    return false
end

-- Update a character record in place, looked up by original_name
function CharacterDB:updateCharacter(book_md5, original_name, updated_char)
    local characters = self:load(book_md5)
    for i, c in ipairs(characters) do
        if c.name == original_name then
            updated_char.id = updated_char.id or c.id  -- preserve ID across updates
            characters[i] = updated_char
            local ok, err = self:save(book_md5, characters)
            if not ok then
                logger.warn("KoCharacters: updateCharacter save failed: " .. tostring(err))
                return false
            end
            return true
        end
    end
    return false
end

-- Delete a single character by name from a book's database
function CharacterDB:deleteCharacter(book_md5, name)
    local characters = self:load(book_md5)
    local new_list = {}
    for _, c in ipairs(characters) do
        if c.name ~= name then
            table.insert(new_list, c)
        end
    end
    self:save(book_md5, new_list)
end

-- Delete the database for a book
function CharacterDB:clear(book_md5)
    local path = self:dbPath(book_md5)
    os.remove(path)
end

-- ---------------------------------------------------------------------------
-- Scanned pages tracking
-- ---------------------------------------------------------------------------
function CharacterDB:scannedPath(book_md5)
    return self:bookDir(book_md5) .. "/scanned.json"
end

-- Internal: load raw scanned data.
-- New format: { page_count = N, pages = [...] }
-- Old format (plain array): migrated transparently on next write.
-- Returns: set (keyed by page num), stored_page_count (or nil)
function CharacterDB:_loadScannedData(book_md5)
    local path = self:scannedPath(book_md5)
    local f = io.open(path, "r")
    if not f then return {}, nil end
    local content = f:read("*a")
    f:close()
    local data = json.decode(content) or {}
    if data.pages then
        local set = {}
        for _, p in ipairs(data.pages) do set[p] = true end
        return set, data.page_count
    else
        local set = {}
        for _, p in ipairs(data) do set[p] = true end
        return set, nil
    end
end

-- Internal: persist scanned set + page_count
function CharacterDB:_saveScannedData(book_md5, set, page_count)
    local list = {}
    for p in pairs(set) do table.insert(list, p) end
    local path = self:scannedPath(book_md5)
    local f = io.open(path, "w")
    if f then
        f:write(json.encode({ page_count = page_count, pages = list }))
        f:close()
    else
        logger.warn("KoCharacters: could not write scanned pages to " .. path)
    end
end

-- Returns a set (table keyed by page number) of already-scanned pages
function CharacterDB:loadScannedPages(book_md5)
    local set, _ = self:_loadScannedData(book_md5)
    return set
end

-- Returns the page count stored alongside the scanned list, or nil if not yet recorded
function CharacterDB:getScannedPageCount(book_md5)
    local _, count = self:_loadScannedData(book_md5)
    return count
end

-- Persist the current document page count alongside the scanned list
function CharacterDB:saveScannedPageCount(book_md5, page_count)
    local set, _ = self:_loadScannedData(book_md5)
    self:_saveScannedData(book_md5, set, page_count)
end

function CharacterDB:isPageScanned(book_md5, page_num)
    return self:loadScannedPages(book_md5)[page_num] == true
end

function CharacterDB:markPageScanned(book_md5, page_num)
    local set, count = self:_loadScannedData(book_md5)
    if set[page_num] then return end
    set[page_num] = true
    self:_saveScannedData(book_md5, set, count)
end

-- Mark a range of pages as scanned in one file write
function CharacterDB:markPagesScanned(book_md5, from_page, to_page)
    local set, count = self:_loadScannedData(book_md5)
    for p = from_page, to_page do set[p] = true end
    self:_saveScannedData(book_md5, set, count)
end

function CharacterDB:clearScannedPages(book_md5)
    os.remove(self:scannedPath(book_md5))
end

-- ---------------------------------------------------------------------------
-- Pending cleanup flag
-- ---------------------------------------------------------------------------
function CharacterDB:pendingCleanupPath(book_md5)
    return self:bookDir(book_md5) .. "/pending_cleanup"
end

function CharacterDB:markPendingCleanup(book_md5)
    local f = io.open(self:pendingCleanupPath(book_md5), "w")
    if f then f:close() end
end

function CharacterDB:hasPendingCleanup(book_md5)
    local f = io.open(self:pendingCleanupPath(book_md5), "r")
    if f then f:close(); return true end
    return false
end

function CharacterDB:clearPendingCleanup(book_md5)
    os.remove(self:pendingCleanupPath(book_md5))
end

-- ---------------------------------------------------------------------------
-- Pending pages (pages that failed to scan due to network error)
-- ---------------------------------------------------------------------------
function CharacterDB:pendingPagesPath(book_md5)
    return self:bookDir(book_md5) .. "/pending_pages.json"
end

function CharacterDB:loadPendingPages(book_md5)
    local f = io.open(self:pendingPagesPath(book_md5), "r")
    if not f then return {} end
    local content = f:read("*a"); f:close()
    return json.decode(content) or {}
end

function CharacterDB:hasPendingPages(book_md5)
    return #self:loadPendingPages(book_md5) > 0
end

function CharacterDB:markPagePending(book_md5, page_num)
    local pages = self:loadPendingPages(book_md5)
    for _, p in ipairs(pages) do if p == page_num then return end end
    table.insert(pages, page_num)
    local path = self:pendingPagesPath(book_md5)
    local f = io.open(path, "w")
    if f then f:write(json.encode(pages)); f:close()
    else logger.warn("KoCharacters: could not write pending pages to " .. path) end
end

-- Remove a list of page numbers from the pending list
function CharacterDB:removePendingPages(book_md5, pages_to_remove)
    if not pages_to_remove or #pages_to_remove == 0 then return end
    local remove_set = {}
    for _, p in ipairs(pages_to_remove) do remove_set[p] = true end
    local pages = self:loadPendingPages(book_md5)
    local new_list = {}
    for _, p in ipairs(pages) do if not remove_set[p] then table.insert(new_list, p) end end
    if #new_list == 0 then
        os.remove(self:pendingPagesPath(book_md5))
    else
        local path = self:pendingPagesPath(book_md5)
        local f = io.open(path, "w")
        if f then f:write(json.encode(new_list)); f:close()
        else logger.warn("KoCharacters: could not write pending pages to " .. path) end
    end
end

function CharacterDB:clearPendingPages(book_md5)
    os.remove(self:pendingPagesPath(book_md5))
end

-- ---------------------------------------------------------------------------
-- Book context (auto-built genre/era/setting summary)
-- ---------------------------------------------------------------------------
function CharacterDB:bookContextPath(book_md5)
    return self:bookDir(book_md5) .. "/book_context.txt"
end

function CharacterDB:loadBookContext(book_md5)
    local path = self:bookContextPath(book_md5)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a")
    f:close()
    return content or ""
end

function CharacterDB:saveBookContext(book_md5, context)
    local path = self:bookContextPath(book_md5)
    local f = io.open(path, "w")
    if f then f:write(context); f:close()
    else logger.warn("KoCharacters: could not write book context to " .. path) end
end

return CharacterDB
