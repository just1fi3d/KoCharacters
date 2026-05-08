-- utils_shared.lua
-- Pure utility functions shared across character and codex modules.
-- No I/O, no UI, no shared state. Safe to require from any module.

local UtilsShared = {}

-- Union two arrays of strings, preserving order and deduplicating by value.
function UtilsShared.unionArrays(a, b)
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

-- Merge two known_connections arrays, deduplicating by character name.
-- For the same character name (case-insensitive), roles are unioned in insertion order.
-- Entries that don't match "Name (roles)" format are deduplicated by exact string.
function UtilsShared.mergeConnections(a, b)
    local ordered_keys = {}
    local name_map     = {}
    local verbatim     = {}
    local verbatim_set = {}

    local function add(entry)
        if type(entry) ~= "string" or entry == "" then return end
        local name, roles_str = entry:match("^(.-)%s*%((.+)%)%s*$")
        if not name then
            if not verbatim_set[entry] then
                verbatim_set[entry] = true
                table.insert(verbatim, entry)
            end
            return
        end
        name = name:match("^%s*(.-)%s*$")
        local key = name:lower()
        if not name_map[key] then
            name_map[key] = { name = name, role_order = {}, role_set = {} }
            table.insert(ordered_keys, key)
        end
        local rec = name_map[key]
        for role in (roles_str .. ","):gmatch("([^,]+),") do
            role = role:match("^%s*(.-)%s*$")
            if role ~= "" and not rec.role_set[role] then
                rec.role_set[role] = true
                table.insert(rec.role_order, role)
            end
        end
    end

    for _, v in ipairs(a or {}) do add(v) end
    for _, v in ipairs(b or {}) do add(v) end

    local result = {}
    for _, key in ipairs(ordered_keys) do
        local rec = name_map[key]
        if #rec.role_order > 0 then
            table.insert(result, rec.name .. " (" .. table.concat(rec.role_order, ", ") .. ")")
        else
            table.insert(result, rec.name)
        end
    end
    for _, v in ipairs(verbatim) do table.insert(result, v) end
    return result
end

-- Build two lookup tables from a characters array:
--   exact_names:      primary name lower  → true
--   alias_to_canonical: alias lower       → primary name (string)
-- Aliases that match a primary name exactly are skipped (no-op redirect).
function UtilsShared.buildNameMaps(characters)
    local exact_names        = {}
    local alias_to_canonical = {}
    for _, c in ipairs(characters) do
        local primary = c.name or ""
        if primary ~= "" then exact_names[primary:lower()] = true end
    end
    for _, c in ipairs(characters) do
        local primary = c.name or ""
        if primary ~= "" then
            for _, alias in ipairs(c.aliases or {}) do
                local al = alias:lower()
                if alias ~= "" and not exact_names[al] and not alias_to_canonical[al] then
                    alias_to_canonical[al] = primary
                end
            end
        end
    end
    return exact_names, alias_to_canonical
end

-- Given a lowercase partial name, return the single unambiguous full character name
-- where partial_lower is a whole word within the full name, or nil if zero or
-- multiple candidates match. Only checks names, not aliases (aliases are valid
-- exact references and are left unchanged by callers before this is tried).
function UtilsShared.expandPartialName(partial_lower, characters)
    local candidates = {}
    local seen = {}
    for _, c in ipairs(characters) do
        local full = c.name or ""
        if full == "" then
        elseif full:lower() == partial_lower then
            -- exact match — not a partial
        else
            for word in full:lower():gmatch("%S+") do
                if word == partial_lower then
                    if not seen[full] then
                        seen[full] = true
                        table.insert(candidates, full)
                    end
                    break
                end
            end
        end
    end
    return #candidates == 1 and candidates[1] or nil
end

-- Append a page number to a seen_pages array (deduped, sorted). Returns the array.
function UtilsShared.addSeenPage(pages, page_num)
    if not page_num then return pages or {} end
    pages = pages or {}
    for _, p in ipairs(pages) do
        if p == page_num then return pages end
    end
    table.insert(pages, page_num)
    table.sort(pages)
    return pages
end

-- Returns true if page_num is present in a seen_pages array.
function UtilsShared.hasSeenPage(pages, page_num)
    if not pages or not page_num then return false end
    for _, p in ipairs(pages) do
        if p == page_num then return true end
    end
    return false
end

return UtilsShared
