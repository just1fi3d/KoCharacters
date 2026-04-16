-- epub_reader.lua
-- Extracts plain text from EPUB documents for character analysis.
-- All functions are pure: they take explicit arguments, hold no state.

local logger = require("logger")

local EpubReader = {}

-- Returns plain text for the given page, or (nil, err_string) on failure.
-- doc  — the KOReader document object (self.ui.document)
-- page — integer page number
function EpubReader.getPageText(doc, page)
    if not doc then return nil, "No document open" end
    if not page then return nil, "Could not get page number" end

    -- CreDocument (EPUB): getPageXPointer works, getPosFromXPointer works.
    -- Use these to get integer position range, then getTextBoxesFromPositions.
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

        -- Get fragment start AND end position from TOC for accurate slicing
        local frag_idx = tostring(xp_cur):match("DocFragment%[(%d+)%]")
        logger.info("KoCharacters: frag_idx=" .. tostring(frag_idx))

        local frag_start_pos = 0
        local frag_end_pos   = 0
        local ok_toc, toc = pcall(function() return doc:getToc() end)
        if ok_toc and type(toc) == "table" then
            local best_page = 0
            local best_idx  = 0
            for i, entry in ipairs(toc) do
                local ep = tonumber(entry.page) or 0
                if ep <= page and ep > best_page then
                    best_page = ep
                    best_idx  = i
                    if entry.xpointer then
                        local ok_xp, p = pcall(function()
                            return doc:getPosFromXPointer(entry.xpointer)
                        end)
                        if ok_xp and p then frag_start_pos = p end
                    end
                end
            end
            local next_entry = toc[best_idx + 1]
            if next_entry and next_entry.xpointer then
                local ok_xp, p = pcall(function()
                    return doc:getPosFromXPointer(next_entry.xpointer)
                end)
                if ok_xp and p then frag_end_pos = p end
            end
        end
        logger.info("KoCharacters: frag_start=" .. frag_start_pos .. " frag_end=" .. frag_end_pos)

        -- Strips HTML tags and slices to ~2500 chars centred on the current page position.
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
            local frag_span   = math.max(
                (frag_end_pos > 0 and frag_end_pos or pos_start + 50000) - frag_start_pos, 1)
            local page_offset = math.max(pos_start - frag_start_pos, 0)
            local ratio       = math.min(page_offset / frag_span, 1.0)
            local centre      = math.floor(ratio * #text)
            local s           = math.max(1, centre - 500)
            local e           = math.min(#text, s + MAX)
            logger.info("KoCharacters: ratio=" .. string.format("%.2f", ratio)
                .. " slice=" .. s .. "-" .. e .. "/" .. #text)
            local slice = text:sub(s, e)
            if #slice < 200 then return text:sub(1, math.min(#text, MAX)) end
            return slice
        end

        -- Read EPUB as a zip — most reliable approach on this build
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
            logger.info("KoCharacters: popen ok=" .. tostring(ok_p)
                .. " type=" .. type(result)
                .. " len=" .. (type(result) == "string" and #result or 0))

            if ok_p and type(result) == "string" and #result > 10 then
                local n        = tonumber(frag_idx) or 1
                local opf_path = result:match("([^%s]+%.opf)")
                logger.info("KoCharacters: opf_path=" .. tostring(opf_path))

                if opf_path then
                    local ok2, opf = pcall(function()
                        local h = io.popen(
                            "unzip -p '" .. epub_path .. "' '" .. opf_path .. "' 2>/dev/null", "r")
                        if not h then return nil end
                        local s = h:read("*a"); h:close(); return s
                    end)
                    logger.info("KoCharacters: opf ok=" .. tostring(ok2)
                        .. " len=" .. (type(opf) == "string" and #opf or 0))

                    if ok2 and type(opf) == "string" and #opf > 50 then
                        local count, item_id = 0, nil
                        for idref in opf:gmatch([[itemref[^>]+idref="([^"]+)"]]) do
                            count = count + 1
                            if count == n then item_id = idref; break end
                        end
                        logger.info("KoCharacters: spine#" .. n .. " id=" .. tostring(item_id))

                        if item_id then
                            local manifest = {}
                            for tag in opf:gmatch("<item%s[^>]+/>") do
                                local id   = tag:match([[id="([^"]+)"]])
                                local href = tag:match([[href="([^"]+)"]])
                                if id and href then manifest[id] = href end
                            end
                            local href = manifest[item_id]
                            logger.info("KoCharacters: chapter href=" .. tostring(href))

                            if href then
                                local base = opf_path:match("^(.*/)") or ""
                                local full = base .. href
                                local ok3, chapter = pcall(function()
                                    local h = io.popen(
                                        "unzip -p '" .. epub_path .. "' '" .. full .. "' 2>/dev/null", "r")
                                    if not h then return nil end
                                    local s = h:read("*a"); h:close(); return s
                                end)
                                logger.info("KoCharacters: chapter ok=" .. tostring(ok3)
                                    .. " len=" .. (type(chapter) == "string" and #chapter or 0))

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

    -- Fallback for non-EPUB documents: getTextBoxes
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

-- Returns (chapter_start_page, chapter_end_page, err_string).
-- doc          — the KOReader document object (self.ui.document)
-- current_page — integer page number the reader is currently on
function EpubReader.getChapterRange(doc, current_page)
    if not doc then return nil, nil, "No document open" end
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

return EpubReader
