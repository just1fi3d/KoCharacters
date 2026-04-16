-- utils_character.lua
-- Pure utility functions for character data: duplicate detection and display formatting.
-- No I/O, no UI, no shared state. Safe to require from any module.

local UtilsCharacter = {}

-- ---------------------------------------------------------------------------
-- Duplicate detection
-- ---------------------------------------------------------------------------

function UtilsCharacter.levenshtein(a, b)
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

-- Returns true when two already-lowercased names are similar enough to be duplicates.
-- Both names must be at least 4 characters; exact matches are not considered similar
-- (they are intentional updates, not conflicts).
function UtilsCharacter.namesAreSimilar(a_low, b_low)
    if #a_low < 4 or #b_low < 4 then return false end
    if a_low == b_low then return false end
    local dist      = UtilsCharacter.levenshtein(a_low, b_low)
    local threshold = math.min(#a_low, #b_low) <= 6 and 1 or 2
    local substring = a_low:find(b_low, 1, true) or b_low:find(a_low, 1, true)
    return dist <= threshold or substring ~= nil
end

-- Compare incoming (new) characters against an existing list; return conflict pairs.
-- Exact name matches are intentional updates handled by merge() — skip them here.
function UtilsCharacter.findIncomingConflicts(existing, incoming)
    local conflicts = {}
    for _, new_c in ipairs(incoming) do
        local new_low = (new_c.name or ""):lower()
        for _, ex_c in ipairs(existing) do
            local ex_low = (ex_c.name or ""):lower()
            if UtilsCharacter.namesAreSimilar(new_low, ex_low) then
                table.insert(conflicts, { new_char = new_c, existing_char = ex_c })
                break
            end
        end
    end
    return conflicts
end

-- Collapse near-duplicate names within a single incoming batch before DB insertion.
-- Merges the second into the first (fills in missing fields), returns deduped list.
function UtilsCharacter.deduplicateIncoming(chars)
    if #chars < 2 then return chars end
    local removed = {}
    for i = 1, #chars do
        if not removed[i] then
            local a     = chars[i]
            local a_low = (a.name or ""):lower()
            for j = i + 1, #chars do
                if not removed[j] then
                    local b     = chars[j]
                    local b_low = (b.name or ""):lower()
                    if UtilsCharacter.namesAreSimilar(a_low, b_low) then
                        if (a.role == nil or a.role == "") and b.role and b.role ~= "" then
                            a.role = b.role
                        end
                        if (a.physical_description == nil or a.physical_description == "")
                            and b.physical_description and b.physical_description ~= "" then
                            a.physical_description = b.physical_description
                        end
                        if (a.personality == nil or a.personality == "")
                            and b.personality and b.personality ~= "" then
                            a.personality = b.personality
                        end
                        removed[j] = true
                    end
                end
            end
        end
    end
    local result = {}
    for i, c in ipairs(chars) do
        if not removed[i] then table.insert(result, c) end
    end
    return result
end

-- Check within an existing DB list for near-duplicate pairs.
-- Used by checkAndWarnDuplicates before manual extraction actions.
function UtilsCharacter.findDuplicatePairs(characters)
    local pairs_found = {}
    for i = 1, #characters do
        for j = i + 1, #characters do
            local a_low = (characters[i].name or ""):lower()
            local b_low = (characters[j].name or ""):lower()
            if UtilsCharacter.namesAreSimilar(a_low, b_low) then
                table.insert(pairs_found, { characters[i].name or "", characters[j].name or "" })
            end
        end
    end
    return pairs_found
end

-- ---------------------------------------------------------------------------
-- Character display formatting
-- ---------------------------------------------------------------------------

-- Returns a plain-text multi-line string for TextViewer display.
function UtilsCharacter.formatText(c)
    local lines = {}

    table.insert(lines, "NAME")
    table.insert(lines, c.name or "Unknown")

    if c.aliases and #c.aliases > 0 then
        table.insert(lines, "")
        table.insert(lines, "ALIASES")
        table.insert(lines, table.concat(c.aliases, ", "))
    end

    if c.role and c.role ~= "" then
        table.insert(lines, "")
        table.insert(lines, "ROLE")
        table.insert(lines, c.role)
    end

    if c.occupation and c.occupation ~= "" then
        table.insert(lines, "")
        table.insert(lines, "OCCUPATION")
        table.insert(lines, c.occupation)
    end

    if c.identity_tags and #c.identity_tags > 0 then
        table.insert(lines, "")
        table.insert(lines, "IDENTITY")
        table.insert(lines, table.concat(c.identity_tags, ", "))
    end

    if c.motivation and c.motivation ~= "" then
        table.insert(lines, "")
        table.insert(lines, "MOTIVATION")
        table.insert(lines, c.motivation)
    end

    if c.defining_moments and #c.defining_moments > 0 then
        table.insert(lines, "")
        table.insert(lines, "DEFINING MOMENTS")
        for _, m in ipairs(c.defining_moments) do
            table.insert(lines, "• " .. m)
        end
    end

    if c.physical_description and c.physical_description ~= "" then
        table.insert(lines, "")
        table.insert(lines, "APPEARANCE")
        table.insert(lines, c.physical_description)
    end

    if c.personality and c.personality ~= "" then
        table.insert(lines, "")
        table.insert(lines, "PERSONALITY")
        table.insert(lines, c.personality)
    end

    if c.relationships and #c.relationships > 0 then
        table.insert(lines, "")
        table.insert(lines, "RELATIONSHIPS")
        table.insert(lines, table.concat(c.relationships, "\n"))
    end

    if c.first_appearance_quote and c.first_appearance_quote ~= "" then
        table.insert(lines, "")
        local seen_label = "FIRST SEEN"
        if c.first_seen_page then
            seen_label = seen_label .. " (page " .. c.first_seen_page .. ")"
        end
        table.insert(lines, seen_label)
        table.insert(lines, '"' .. c.first_appearance_quote .. '"')
    end

    if c.user_notes and c.user_notes ~= "" then
        table.insert(lines, "")
        table.insert(lines, "NOTES")
        table.insert(lines, c.user_notes)
    end

    if c.source_page then
        table.insert(lines, "")
        table.insert(lines, "LAST UPDATED")
        table.insert(lines, "Page " .. c.source_page)
    end

    return table.concat(lines, "\n")
end

-- Returns (css_string, html_body_string) for ScrollHtmlWidget display.
-- portrait_path — absolute path to portrait image, or nil
-- container_w   — widget container width in pixels
function UtilsCharacter.formatHTML(char, portrait_path, container_w)
    local function esc(s)
        s = tostring(s or "")
        s = s:gsub("&",  "&amp;")
        s = s:gsub("<",  "&lt;")
        s = s:gsub(">",  "&gt;")
        s = s:gsub('"',  "&quot;")
        return s
    end

    local css = table.concat({
        "@page{margin:0;}",
        "html,body{margin:0;padding:0;}",
        "body{font-family:Georgia,serif;padding:12px 14px;background:#fff;color:#111;line-height:1.3;}",
        "table{border-collapse:collapse;border-spacing:0;width:100%;}",
        "td{padding:0;vertical-align:top;}",
        "img.portrait{display:block;width:100%;height:auto;border-radius:3px;}",
        "h1{font-size:1.45em;color:#000;margin:0 0 3px;font-weight:bold;}",
        ".role{color:#444;font-style:italic;margin:0;font-size:0.87em;}",
        ".section{margin-top:16px;padding-top:12px;border-top:1px solid #ccc;}",
        ".label{font-size:0.76em;text-transform:uppercase;letter-spacing:.09em;color:#333;font-weight:bold;margin:0 0 5px;}",
        "p{margin:0;font-size:0.87em;text-align:justify;}",
        "ul{margin:4px 0 0 0;padding-left:36px;font-size:0.87em;}",
        "ul li{margin-bottom:3px;}",
        ".quote{border-left:2px solid #888;padding-left:10px;color:#444;font-style:italic;}",
        ".foot{font-size:.72em;color:#aaa;margin-top:16px;}",
        "a{color:#333;text-decoration:underline;}",
    })

    local p = {}

    local name_html = '<h1>' .. esc(char.name or "Unknown") .. '</h1>'
    local role_html = ""
    if char.role and char.role ~= "" and char.role ~= "unknown" then
        role_html = '<p class="role">' .. esc(char.role) .. '</p>'
    end

    local aliases_html = ""
    if char.aliases and #char.aliases > 0 then
        local styled_items = {}
        for _, a in ipairs(char.aliases) do
            styled_items[#styled_items+1] =
                '<li style="font-family:Georgia,serif;">' .. esc(a) .. '</li>'
        end
        aliases_html = '<div style="margin-top:8px;font-family:Georgia,serif;">'
            .. '<div class="label">Also known as</div><ul>'
            .. table.concat(styled_items) .. '</ul></div>'
    end

    p[#p+1] = name_html
    p[#p+1] = role_html
    if portrait_path then
        local body_w = (container_w or 300) - 28  -- subtract body padding (14px each side)
        local img_w  = math.floor(body_w * 0.4)
        local text_w = body_w - img_w - 12
        p[#p+1] = '<div style="display:table;width:' .. body_w .. 'px;">'
        p[#p+1] = '<div style="display:table-row;">'
        p[#p+1] = '<div style="display:table-cell;width:' .. img_w
            .. 'px;vertical-align:top;padding-right:8px;"><img width="' .. (img_w-8)
            .. '" src="' .. portrait_path .. '"></div>'
        p[#p+1] = '<div style="display:table-cell;width:' .. text_w
            .. 'px;vertical-align:top;font-family:Georgia,serif;">' .. aliases_html .. '</div>'
        p[#p+1] = '</div></div>'
    else
        p[#p+1] = aliases_html
    end

    if char.identity_tags and #char.identity_tags > 0 then
        local items = {}
        for _, t in ipairs(char.identity_tags) do
            items[#items+1] = '<li>' .. esc(t) .. '</li>'
        end
        p[#p+1] = '<div class="section"><div class="label">Identity</div><ul>'
            .. table.concat(items) .. '</ul></div>'
    end
    if char.motivation and char.motivation ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Motivation</div><p>'
            .. esc(char.motivation) .. '</p></div>'
    end
    if char.defining_moments and #char.defining_moments > 0 then
        local items = {}
        for _, m in ipairs(char.defining_moments) do
            items[#items+1] = '<li>' .. esc(m) .. '</li>'
        end
        p[#p+1] = '<div class="section"><div class="label">Defining Moments</div><ul>'
            .. table.concat(items) .. '</ul></div>'
    end
    if char.physical_description and char.physical_description ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Appearance</div><p>'
            .. esc(char.physical_description) .. '</p></div>'
    end
    if char.personality and char.personality ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Personality</div><p>'
            .. esc(char.personality) .. '</p></div>'
    end
    if char.relationships and #char.relationships > 0 then
        local items = {}
        for _, r in ipairs(char.relationships) do
            local rel_name, rel_type = r:match("^(.-)%s*%((.-)%)%s*$")
            if rel_name and rel_name ~= "" then
                items[#items+1] = '<li><a href="char:' .. esc(rel_name) .. '">'
                    .. esc(rel_name) .. '</a> (' .. esc(rel_type) .. ')</li>'
            else
                items[#items+1] = '<li>' .. esc(r) .. '</li>'
            end
        end
        p[#p+1] = '<div class="section"><div class="label">Relationships</div><ul>'
            .. table.concat(items) .. '</ul></div>'
    end
    if char.first_appearance_quote and char.first_appearance_quote ~= "" then
        local seen_label = "First seen"
        if char.first_seen_page then
            seen_label = seen_label .. " (page " .. tostring(char.first_seen_page) .. ")"
        end
        p[#p+1] = '<div class="section"><div class="label">' .. seen_label
            .. '</div><p class="quote">&ldquo;' .. esc(char.first_appearance_quote)
            .. '&rdquo;</p></div>'
    end
    if char.user_notes and char.user_notes ~= "" then
        p[#p+1] = '<div class="section"><div class="label">My notes</div>'
            .. '<p style="white-space:pre-wrap;">' .. esc(char.user_notes) .. '</p></div>'
    end
    if char.source_page then
        p[#p+1] = '<p class="foot">Last updated: page ' .. tostring(char.source_page) .. '</p>'
    end

    return css, table.concat(p)
end

return UtilsCharacter
