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
