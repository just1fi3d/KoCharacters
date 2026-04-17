-- export.lua
-- Character export: HTML list, ZIP archive, and server upload.
-- All functions take plugin as first arg; plugin is used as a thin service locator.

local UIManager   = require("ui/uimanager")
local InfoMessage  = require("ui/widget/infomessage")
local logger       = require("logger")

local Export = {}

local function portraitSafeName(name)
    return (name:gsub("[^%w%-]", "_"):lower())
end

-- Writes an HTML character list to <book_dir>/characters.html.
-- Returns the export path on success, or nil on failure.
function Export.exportList(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book.")
        return
    end
    local characters = plugin.db:load(book_id)
    if #characters == 0 then
        plugin:showMsg("No characters to export yet.")
        return
    end
    local title = plugin:getBookTitle()
    local DataStorage = require("datastorage")
    local export_path = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/characters.html"

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
    p('body{font-family:Georgia,serif;max-width:860px;margin:40px auto;padding:0 20px;background:#fdf6e3;color:#333;}')
    p('h1{font-size:1.6em;border-bottom:2px solid #c9a84c;padding-bottom:8px;color:#5a3e1b;}')
    p('.character{display:flex;align-items:stretch;background:#fff;border:1px solid #ddd;border-radius:8px;margin:24px 0;box-shadow:0 2px 8px rgba(0,0,0,.1);overflow:hidden;}')
    p('.char-portrait{flex:0 0 240px;background:#1c1812;border-right:1px solid #e0d8cc;}')
    p('.char-portrait a{display:block;height:100%;}')
    p('.char-portrait img{width:240px;height:100%;object-fit:cover;object-position:top center;display:block;cursor:zoom-in;transition:opacity .15s;}')
    p('.char-portrait img:hover{opacity:.88;}')
    p('.char-info{flex:1;padding:22px 26px;min-width:0;}')
    p('.char-name{font-size:1.35em;font-weight:bold;color:#5a3e1b;margin:0 0 2px;}')
    p('.char-role{font-size:.88em;color:#aaa;font-style:italic;margin:0 0 16px;}')
    p('.field{margin-bottom:12px;}')
    p('.field label{display:block;font-weight:bold;font-size:.78em;text-transform:uppercase;letter-spacing:.07em;color:#bbb;margin-bottom:2px;}')
    p('.field p{margin:0;line-height:1.6;color:#444;}')
    p('.quote{border-left:3px solid #c9a84c;padding-left:12px;color:#888;font-style:italic;}')
    p('#lb{display:none;position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:999;align-items:center;justify-content:center;cursor:zoom-out;}')
    p('#lb.on{display:flex;}')
    p('#lb img{max-width:92vw;max-height:92vh;object-fit:contain;border-radius:4px;box-shadow:0 8px 40px rgba(0,0,0,.7);}')
    p('@media(max-width:580px){.character{flex-direction:column;}.char-portrait{flex:none;width:100%;border-right:none;border-bottom:1px solid #e0d8cc;}.char-portrait img{width:100%;height:260px;}.char-info{padding:16px;}}')
    p('</style></head><body>')
    p('<div id="lb" onclick="this.classList.remove(\'on\')"><img id="lb-img" src="" alt=""></div>')
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
        local portrait_rel
        local portraits_base = "portraits/"
        local portraits_abs  = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits/"
        if c.portrait_file and c.portrait_file ~= "" then
            local pf = io.open(portraits_abs .. c.portrait_file, "r")
            if pf then pf:close(); portrait_rel = portraits_base .. c.portrait_file end
        end
        if not portrait_rel then
            local safe_name = portraitSafeName(c.name or "Unknown")
            for _, ext in ipairs({ ".jpg", ".png" }) do
                local pf = io.open(portraits_abs .. safe_name .. ext, "r")
                if pf then pf:close(); portrait_rel = portraits_base .. safe_name .. ext; break end
            end
        end
        if portrait_rel then
            local img_src = portrait_rel
            local alt     = esc(c.name or "Unknown")
            p('<div class="char-portrait">')
            p('<a href="' .. img_src .. '" onclick="event.preventDefault();document.getElementById(\'lb-img\').src=this.href;document.getElementById(\'lb\').classList.add(\'on\');">')
            p('<img src="' .. img_src .. '" alt="Portrait of ' .. alt .. '">')
            p('</a>')
            p('</div>')
        end
        p('<div class="char-info">')
        p('<div class="char-name">' .. esc(c.name or "Unknown") .. '</div>')
        if c.role and c.role ~= "" then
            p('<div class="char-role">' .. esc(c.role) .. '</div>')
        end
        if c.occupation and c.occupation ~= "" then
            p('<div class="field"><label>Occupation</label><p>' .. esc(c.occupation) .. '</p></div>')
        end
        if c.aliases and #c.aliases > 0 then
            p('<div class="field aliases"><label>Also known as</label><p>' .. esc(table.concat(c.aliases, ", ")) .. '</p></div>')
        end
        if c.identity_tags and #c.identity_tags > 0 then
            local tag_parts = {}
            for _, t in ipairs(c.identity_tags) do table.insert(tag_parts, esc(t)) end
            p('<div class="field"><label>Identity</label><p>' .. table.concat(tag_parts, ", ") .. '</p></div>')
        end
        if c.motivation and c.motivation ~= "" then
            p('<div class="field"><label>Motivation</label><p>' .. esc(c.motivation) .. '</p></div>')
        end
        if c.defining_moments and #c.defining_moments > 0 then
            local moment_parts = {}
            for _, m in ipairs(c.defining_moments) do table.insert(moment_parts, esc(m)) end
            p('<div class="field"><label>Defining Moments</label><p>' .. table.concat(moment_parts, "<br>") .. '</p></div>')
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
            local seen_label = "First seen"
            if c.first_seen_page then seen_label = seen_label .. " (page " .. esc(tostring(c.first_seen_page)) .. ")" end
            p('<div class="field"><label>' .. seen_label .. '</label><p class="quote">&ldquo;' .. esc(c.first_appearance_quote) .. '&rdquo;</p></div>')
        end
        if c.user_notes and c.user_notes ~= "" then
            p('<div class="field" style="border-top:1px dashed #e0c97a;margin-top:10px;padding-top:10px;"><label>My notes</label><p style="white-space:pre-wrap;">' .. esc(c.user_notes) .. '</p></div>')
        end
        if c.source_page then
            p('<div style="margin-top:10px;font-size:.8em;color:#bbb;">Last updated: page ' .. esc(tostring(c.source_page)) .. '</div>')
        end
        p('</div>')
        p('</div>')
    end

    -- Codex section
    local codex_entries = plugin.db_codex and plugin.db_codex:load(book_id) or {}
    if #codex_entries > 0 then
        table.sort(codex_entries, function(a, b)
            local order = { place = 1, faction = 2, concept = 3, object = 4, species = 5, unknown = 6 }
            local ta = order[a.type or "unknown"] or 6
            local tb = order[b.type or "unknown"] or 6
            if ta ~= tb then return ta < tb end
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)

        p('<h1 style="margin-top:48px;">Codex</h1>')
        p('<p style="color:#888;font-size:.85em;">' .. #codex_entries .. ' entr' .. (#codex_entries == 1 and 'y' or 'ies') .. '</p>')
        p('<nav style="background:#fff;border:1px solid #ddd;border-radius:6px;padding:16px 20px;margin-bottom:24px;">')
        p('<div style="font-weight:bold;font-size:.85em;text-transform:uppercase;letter-spacing:.05em;color:#999;margin-bottom:8px;">Entries</div>')
        p('<ol style="margin:0;padding-left:20px;column-count:2;column-gap:2em;">')
        for _, e in ipairs(codex_entries) do
            local anchor  = "codex-" .. esc(e.name or "Unknown"):gsub("%s+", "-"):lower()
            local badge   = (e.type and e.type ~= "" and e.type ~= "unknown") and (' <span style="color:#aaa;font-size:.85em;">— ' .. esc(e.type) .. '</span>') or ""
            p('<li style="margin-bottom:4px;"><a href="#' .. anchor .. '" style="color:#5a3e1b;text-decoration:none;">' .. esc(e.name or "Unknown") .. '</a>' .. badge .. '</li>')
        end
        p('</ol></nav>')

        local codex_portraits_abs = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/codex_portraits/"
        for _, e in ipairs(codex_entries) do
            local anchor = "codex-" .. esc(e.name or "Unknown"):gsub("%s+", "-"):lower()
            p('<div class="character" id="' .. anchor .. '">')
            local portrait_rel = nil
            local safe_name = portraitSafeName(e.name or "Unknown")
            local id_name   = (e.id and e.id ~= "") and e.id or nil
            for _, candidate in ipairs({ id_name and (id_name .. ".png") or nil, safe_name .. ".png" }) do
                if candidate then
                    local pf = io.open(codex_portraits_abs .. candidate, "r")
                    if pf then pf:close(); portrait_rel = "codex_portraits/" .. candidate; break end
                end
            end
            if portrait_rel then
                local alt = esc(e.name or "Unknown")
                p('<div class="char-portrait">')
                p('<a href="' .. portrait_rel .. '" onclick="event.preventDefault();document.getElementById(\'lb-img\').src=this.href;document.getElementById(\'lb\').classList.add(\'on\');">')
                p('<img src="' .. portrait_rel .. '" alt="Image of ' .. alt .. '">')
                p('</a>')
                p('</div>')
            end
            p('<div class="char-info">')
            p('<div class="char-name">' .. esc(e.name or "Unknown") .. '</div>')
            if e.type and e.type ~= "" and e.type ~= "unknown" then
                p('<div class="char-role">' .. esc(e.type:upper()) .. '</div>')
            end
            if e.description and e.description ~= "" then
                p('<div class="field"><label>Description</label><p>' .. esc(e.description) .. '</p></div>')
            end
            if e.significance and e.significance ~= "" then
                p('<div class="field"><label>Significance</label><p>' .. esc(e.significance) .. '</p></div>')
            end
            if e.known_connections and #e.known_connections > 0 then
                local parts2 = {}
                for _, c in ipairs(e.known_connections) do table.insert(parts2, esc(c)) end
                p('<div class="field"><label>Known Connections</label><p>' .. table.concat(parts2, "<br>") .. '</p></div>')
            end
            if e.aliases and #e.aliases > 0 then
                p('<div class="field"><label>Also Known As</label><p>' .. esc(table.concat(e.aliases, ", ")) .. '</p></div>')
            end
            if e.first_appearance_quote and e.first_appearance_quote ~= "" then
                local seen_label = "First seen"
                if e.first_seen_page then seen_label = seen_label .. " (page " .. esc(tostring(e.first_seen_page)) .. ")" end
                p('<div class="field"><label>' .. seen_label .. '</label><p class="quote">&ldquo;' .. esc(e.first_appearance_quote) .. '&rdquo;</p></div>')
            end
            if e.user_notes and e.user_notes ~= "" then
                p('<div class="field" style="border-top:1px dashed #e0c97a;margin-top:10px;padding-top:10px;"><label>My notes</label><p style="white-space:pre-wrap;">' .. esc(e.user_notes) .. '</p></div>')
            end
            p('</div>')
            p('</div>')
        end
    end

    p('</body></html>')

    local f = io.open(export_path, "w")
    if not f then
        plugin:showMsg("Could not write file:\n" .. export_path)
        return nil
    end
    f:write(table.concat(parts, "\n"))
    f:close()
    plugin:showMsg("Exported to:\n" .. export_path, 5)
    return export_path
end

-- Creates a ZIP archive containing characters.html and the portraits directory.
function Export.exportZip(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book.")
        return
    end
    local characters = plugin.db:load(book_id)
    if #characters == 0 then
        plugin:showMsg("No characters to export yet.")
        return
    end

    local msg = InfoMessage:new{ text = "Building ZIP…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local DataStorage = require("datastorage")
    local base_dir    = DataStorage:getDataDir() .. "/kocharacters/" .. book_id
    local zip_path    = base_dir .. "/characters.zip"

    -- Generate the HTML first (silent — exportList shows its own message after)
    Export.exportList(plugin)

    os.remove(zip_path)

    -- Build zip: HTML + portraits + codex_portraits, paths relative to base_dir
    local function dirExists(path)
        local f = io.open(path .. "/.test_probe", "r")
        if f then f:close() end
        local h = io.popen('[ -d "' .. path .. '" ] && echo y')
        local r = h and h:read("*a") or ""
        if h then h:close() end
        return r:find("y") ~= nil
    end

    local zip_files = '"characters.html"'
    if dirExists(base_dir .. "/portraits")         then zip_files = zip_files .. ' "portraits"' end
    if dirExists(base_dir .. "/codex_portraits")   then zip_files = zip_files .. ' "codex_portraits"' end
    local codex_json = base_dir .. "/codex.json"
    local fc = io.open(codex_json, "r")
    if fc then fc:close(); zip_files = zip_files .. ' "codex.json"' end

    local cmd = string.format(
        'cd "%s" && zip -r "characters.zip" %s 2>/dev/null; echo $?',
        base_dir, zip_files
    )
    local handle = io.popen(cmd)
    local result = handle and handle:read("*a") or ""
    if handle then handle:close() end

    UIManager:close(msg)

    local exit_code = tonumber(result:match("%d+$") or "1")
    if exit_code ~= 0 then
        plugin:showMsg("ZIP creation failed.\nIs 'zip' available on this device?", 6)
        return
    end

    plugin:showMsg("ZIP saved to:\n" .. zip_path, 6)
end

-- Uploads a tar.gz archive of the book's character data to a configured HTTP endpoint.
function Export.uploadToServer(plugin)
    local book_id = plugin:getBookID()
    if not book_id then
        plugin:showMsg("Cannot identify book.")
        return
    end
    local characters = plugin.db:load(book_id)
    if #characters == 0 then
        plugin:showMsg("No characters to upload yet.")
        return
    end

    local endpoint = G_reader_settings:readSetting("kocharacters_upload_endpoint") or ""
    local api_key  = G_reader_settings:readSetting("kocharacters_upload_api_key") or ""
    if endpoint == "" then
        plugin:showMsg("No upload endpoint configured.\nGo to Settings → Export settings.")
        return
    end

    local msg = InfoMessage:new{ text = "Preparing upload…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local DataStorage = require("datastorage")
    local json        = require("dkjson")
    local util        = require("util")
    local base_dir    = DataStorage:getDataDir() .. "/kocharacters/" .. book_id
    local archive_name = (book_id:match("^(.-)_%d+$") or book_id) .. ".tar.gz"
    local archive_path = base_dir .. "/" .. archive_name

    local function fileExists(path)
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    end

    -- -----------------------------------------------------------------------
    -- Step 1: Build book_meta.json from doc_settings
    -- -----------------------------------------------------------------------
    local meta = {}
    if plugin.ui and plugin.ui.doc_settings then
        local ok, props = pcall(function() return plugin.ui.doc_settings:readSetting("doc_props") end)
        if ok and props then
            meta.title        = props.title or ""
            meta.authors      = props.authors or ""
            meta.series       = props.series or ""
            meta.series_index = props.series_index
            meta.language     = props.language or ""
            if props.description then
                meta.description = props.description:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
            end
            if props.identifiers then
                local ids = {}
                for line in (props.identifiers .. "\n"):gmatch("([^\n]+)\n") do
                    local k, v = line:match("^([^:]+):(.+)$")
                    if k and v then ids[k:lower()] = v end
                end
                if next(ids) then meta.identifiers = ids end
            end
            if props.keywords then
                local kw = {}
                for line in (props.keywords .. "\n"):gmatch("([^\n]+)\n") do
                    local w = line:match("^%s*(.-)%s*$")
                    if w ~= "" then table.insert(kw, w) end
                end
                if #kw > 0 then meta.keywords = kw end
            end
        end
        local ok2, pages = pcall(function() return plugin.ui.doc_settings:readSetting("doc_pages") end)
        if ok2 and pages then meta.total_pages = pages end
        local ok3, pct = pcall(function() return plugin.ui.doc_settings:readSetting("percent_finished") end)
        if ok3 and pct then meta.percent_finished = math.floor(pct * 1000 + 0.5) / 10 end
        local ok4, summary = pcall(function() return plugin.ui.doc_settings:readSetting("summary") end)
        if ok4 and summary then
            meta.reading_status = summary.status
            meta.last_read      = summary.modified
        end
        local ok5, stats = pcall(function() return plugin.ui.doc_settings:readSetting("stats") end)
        if ok5 and stats then
            meta.highlights = stats.highlights or 0
            meta.notes      = stats.notes or 0
        end
    end
    meta.book_context = plugin.db:loadBookContext(book_id)

    if plugin.ui then
        local ok_md5, md5val = pcall(function()
            return plugin.ui.doc_settings and plugin.ui.doc_settings:readSetting("partial_md5_checksum")
        end)
        if ok_md5 and md5val and md5val ~= "" then
            meta.partial_md5 = md5val
        else
            local ok_fd, digest = pcall(function()
                return plugin.ui.document and plugin.ui.document:fastDigest()
            end)
            if ok_fd and digest and digest ~= "" then meta.partial_md5 = digest end
        end
    end

    local meta_path = base_dir .. "/book_meta.json"

    -- -----------------------------------------------------------------------
    -- Step 2: Extract cover image from epub
    -- -----------------------------------------------------------------------
    local cover_path = base_dir .. "/cover.jpg"
    os.remove(cover_path)
    local epub_path = (plugin.ui and plugin.ui.document and plugin.ui.document.file) or ""
    if epub_path ~= "" then
        local opf_raw = ""
        local h = io.popen(string.format('unzip -p "%s" "*.opf" 2>/dev/null', epub_path))
        if h then opf_raw = h:read("*a") or ""; h:close() end

        local cover_item = opf_raw:match('<item[^>]+properties="cover%-image"[^>]+href="([^"]+)"')
                        or opf_raw:match('<item[^>]+href="([^"]+)"[^>]+properties="cover%-image"')
        if not cover_item then
            local cover_id = opf_raw:match('<meta[^>]+name="cover"[^>]+content="([^"]+)"')
                          or opf_raw:match('<meta[^>]+content="([^"]+)"[^>]+name="cover"')
            if cover_id then
                local cover_id_pat = cover_id:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
                cover_item = opf_raw:match('<item[^>]+id="' .. cover_id_pat .. '"[^>]+href="([^"]+)"')
                          or opf_raw:match('<item[^>]+href="([^"]+)"[^>]+id="' .. cover_id_pat .. '"')
            end
        end

        if not cover_item then
            local list_h = io.popen(string.format('unzip -l "%s" 2>/dev/null | grep -i "\\.jpg"', epub_path))
            if list_h then
                local best_size, best_name = 0, nil
                for line in list_h:lines() do
                    local size, name = line:match("^%s*(%d+)%s+%S+%s+%S+%s+(.+%.jpg)%s*$")
                    size = tonumber(size) or 0
                    if size > best_size then best_size = size; best_name = name end
                end
                list_h:close()
                if best_name then cover_item = best_name end
            end
        end

        if cover_item then
            local function extractCover(path_in_zip)
                local ph = io.popen(string.format(
                    'unzip -p "%s" "%s" 2>/dev/null', epub_path, path_in_zip), "r")
                if not ph then return false end
                local data = ph:read("*a"); ph:close()
                if not data or #data < 4 then return false end
                local b1, b2, b3 = data:byte(1), data:byte(2), data:byte(3)
                local is_jpeg = (b1 == 0xFF and b2 == 0xD8)
                local is_png  = (b1 == 0x89 and b2 == 0x50 and b3 == 0x4E)
                if not is_jpeg and not is_png then return false end
                local wf = io.open(cover_path, "wb")
                if not wf then return false end
                wf:write(data); wf:close()
                return true
            end

            local ok_cover = extractCover(cover_item)
            logger.info("KoCharacters: upload cover_item=" .. tostring(cover_item) .. " ok=" .. tostring(ok_cover))
            if not ok_cover and not cover_item:find("/") then
                ok_cover = extractCover("OEBPS/" .. cover_item)
                logger.info("KoCharacters: upload cover OEBPS fallback ok=" .. tostring(ok_cover))
            end
            if ok_cover then meta.cover = "cover.jpg" end
        else
            logger.info("KoCharacters: upload cover_item not found in OPF")
        end
    end

    local mf = io.open(meta_path, "w")
    if mf then mf:write(json.encode(meta, { indent = true })); mf:close() end

    -- -----------------------------------------------------------------------
    -- Step 3: Build tar.gz with all files
    -- -----------------------------------------------------------------------
    local function dirExists(path)
        local h = io.popen('[ -d "' .. path .. '" ] && echo y')
        local r = h and h:read("*a") or ""
        if h then h:close() end
        return r:find("y") ~= nil
    end

    os.remove(archive_path)
    local files = '"characters.json" "book_meta.json"'
    if fileExists(cover_path)                        then files = files .. ' "cover.jpg"' end
    if dirExists(base_dir .. "/portraits")           then files = files .. ' "portraits"' end
    if fileExists(base_dir .. "/codex.json")         then files = files .. ' "codex.json"' end
    if dirExists(base_dir .. "/codex_portraits")     then files = files .. ' "codex_portraits"' end
    logger.info("KoCharacters: upload tar files=" .. files)

    os.execute(string.format('cd "%s" && tar -czf "%s" %s 2>/dev/null', base_dir, archive_name, files))
    if not fileExists(archive_path) then
        os.execute(string.format('cd "%s" && tar -czf "%s" "characters.json" "book_meta.json" 2>/dev/null', base_dir, archive_name))
    end

    os.remove(meta_path)
    os.remove(cover_path)

    if not fileExists(archive_path) then
        UIManager:close(msg)
        plugin:showMsg("Failed to create upload archive.", 5)
        return
    end

    UIManager:close(msg)
    msg = InfoMessage:new{ text = "Uploading to server…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local code_file = base_dir .. "/.curl_code"
    local curl_cmd
    if api_key ~= "" then
        curl_cmd = string.format(
            'curl -s -k --tlsv1.2 --ciphers DEFAULT -o /dev/null -w "%%{http_code}" --max-time 60 -F "file=@%s" -H "X-Api-Key: %s" "%s" > "%s"',
            archive_path, api_key, endpoint, code_file
        )
    else
        curl_cmd = string.format(
            'curl -s -k --tlsv1.2 --ciphers DEFAULT -o /dev/null -w "%%{http_code}" --max-time 60 -F "file=@%s" "%s" > "%s"',
            archive_path, endpoint, code_file
        )
    end

    os.execute(curl_cmd)
    os.remove(archive_path)

    local http_code = "0"
    local fc = io.open(code_file, "r")
    if fc then http_code = fc:read("*a") or "0"; fc:close() end
    os.remove(code_file)

    UIManager:close(msg)

    local code = tonumber(http_code:match("%d+") or "0") or 0
    if code >= 200 and code < 300 then
        plugin:showMsg("Upload successful. (" .. tostring(code) .. ")", 4)
    elseif code == 0 then
        plugin:showMsg("Upload failed: no response.\nCheck the endpoint URL and network.", 6)
    else
        plugin:showMsg("Upload failed: HTTP " .. tostring(code) .. ".\nCheck endpoint and API key.", 6)
    end
end

return Export
