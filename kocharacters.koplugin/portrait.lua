-- portrait.lua
-- Portrait generation via Google Imagen.
-- Pure helpers (path, has) take only data args.
-- Action functions (generate, onGenerate, batchGenerate) take plugin as first arg.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Screen      = require("device").screen
local logger      = require("logger")

local Portrait = {}

Portrait.DEFAULT_PORTRAIT_PROMPT = [[Oil painting portrait of a fictional {{role}} character. Square composition, 1024x1024. No text. No words. No letters. No labels. No watermarks. No inscriptions. Pure image only. Appearance: {{appearance}} Personality expressed through posture and expression: {{personality}} Occupation: {{occupation}} — the character's clothing, accessories, tools, and background environment must authentically reflect this occupation and social standing (e.g. a blacksmith wears a leather apron near a forge, a physician carries instruments in a study, a soldier wears armour or uniform). Book setting: {{book_context}} CRITICAL: Render the character's appearance EXACTLY as described — including scars, weathering, unconventional features, age, and any traits that deviate from conventional beauty. Do not idealize or beautify. A battle-worn character must look battle-worn; a severe character must look severe. Use historically accurate clothing, hairstyle, and background consistent with the character's era, occupation, and the book setting. Paint in the style of a master portrait painter from that same era — matching the composition, lighting, brushwork, color palette, and aesthetic conventions of period-authentic portraiture (e.g. Renaissance, Baroque, Victorian, etc. as appropriate). Fine detail in fabric, face, and any occupation-relevant objects or surroundings.]]

local function portraitSafeName(name)
    return (name:gsub("[^%w%-]", "_"):lower())
end

-- Returns the absolute path where a portrait for this character should be stored.
-- Creates the portraits directory if needed.
function Portrait.path(book_id, char)
    local DataStorage = require("datastorage")
    local util        = require("util")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"
    util.makePath(dir)
    local filename = (char.id and char.id ~= "") and (char.id .. ".png")
                     or (portraitSafeName(char.name or "unknown") .. ".png")
    return dir .. "/" .. filename
end

-- Returns true if a portrait image file exists for this character.
function Portrait.has(book_id, char)
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits/"
    if char.portrait_file and char.portrait_file ~= "" then
        local f = io.open(dir .. char.portrait_file, "r")
        if f then f:close(); return true end
    end
    local safe = portraitSafeName(char.name or "")
    for _, ext in ipairs({ ".jpg", ".png" }) do
        local f = io.open(dir .. safe .. ext, "r")
        if f then f:close(); return true end
    end
    return false
end

-- Core generation: calls Imagen, decodes the response, saves the file.
-- Returns nil on success, or an error string on failure.
function Portrait.generate(plugin, book_id, char)
    local DataStorage = require("datastorage")
    local json        = require("dkjson")
    local util        = require("util")
    local portraits_dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"
    util.makePath(portraits_dir)

    local name  = char.name or "Unknown"
    local role  = (char.role and char.role ~= "" and char.role ~= "unknown") and char.role or ""
    local occ   = char.occupation or ""
    local phys  = char.physical_description or ""
    local pers  = char.personality or ""
    local quote = char.first_appearance_quote or ""
    local rels  = (char.relationships and #char.relationships > 0)
                  and table.concat(char.relationships, "; ") or ""

    local function sub(s, key, val)
        return (s:gsub("{{" .. key .. "}}", function() return val end))
    end
    local book_context = plugin.db:loadBookContext(book_id)
    local tmpl   = plugin:getPortraitPrompt()
    local prompt = sub(sub(sub(sub(sub(sub(sub(sub(tmpl,
        "name", name), "role", role), "occupation", occ),
        "appearance", phys), "personality", pers),
        "relationships", rels), "context", quote),
        "book_context", book_context)

    local api_key   = plugin:getImagenApiKey()
    local out_path  = Portrait.path(book_id, char)
    local req_file  = portraits_dir .. "/.imagen_req.json"
    local resp_file = portraits_dir .. "/.imagen_resp.json"

    local fq = io.open(req_file, "w")
    if not fq then return "Could not write request file." end
    fq:write(json.encode({
        instances  = {{ prompt = prompt }},
        parameters = { sampleCount = 1, aspectRatio = "1:1" },
    }))
    fq:close()

    local imagen_model = G_reader_settings:readSetting("kocharacters_imagen_model")
                         or "imagen-4.0-fast-generate-001"
    local url = "https://generativelanguage.googleapis.com/v1beta/models/"
                .. imagen_model .. ":predict?key=" .. api_key
    os.execute(string.format(
        'curl -s --max-time 120 -X POST -H "Content-Type: application/json" -d @"%s" "%s" -o "%s"',
        req_file, url, resp_file
    ))
    os.remove(req_file)

    local f = io.open(resp_file, "r")
    if not f then return "No response from Imagen API." end
    local raw = f:read("*a")
    f:close()
    os.remove(resp_file)

    local parsed = json.decode(raw)
    if not parsed then return "Could not parse Imagen response:\n" .. raw:sub(1, 200) end
    if parsed.error then
        return "Imagen error:\n" .. (parsed.error.message or json.encode(parsed.error))
    end

    local b64 = parsed.predictions
                and parsed.predictions[1]
                and parsed.predictions[1].bytesBase64Encoded
    if not b64 or b64 == "" then
        return "Imagen returned no image.\n" .. raw:sub(1, 200)
    end

    local tmp_b64 = portraits_dir .. "/.tmp_b64"
    local fb = io.open(tmp_b64, "w")
    if not fb then return "Could not write temp file." end
    fb:write(b64)
    fb:close()

    local ret = os.execute('base64 -d "' .. tmp_b64 .. '" > "' .. out_path .. '"')
    os.remove(tmp_b64)
    if ret ~= 0 then return "Failed to decode portrait image." end

    local portrait_filename = (char.id and char.id ~= "") and (char.id .. ".png")
                              or (portraitSafeName(char.name) .. ".png")
    char.portrait_file = portrait_filename
    plugin.db:updateCharacter(book_id, char.name, char)
    plugin:recordUsage({ images = 1 })
    return nil
end

-- Shows progress UI, calls Portrait.generate, shows result.
function Portrait.onGenerate(plugin, book_id, char)
    local msg = InfoMessage:new{
        text = "Generating portrait for " .. (char.name or "character") .. "…"
    }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local err = Portrait.generate(plugin, book_id, char)
    UIManager:close(msg)
    if err then
        plugin:showMsg(err, 8)
    else
        plugin:showMsg("Portrait saved for " .. (char.name or "character") .. ".", 3)
    end
end

-- Selection menu for batch portrait generation.
function Portrait.batchGenerate(plugin)
    local book_id = plugin:getBookID()
    if not book_id then plugin:showMsg("No book open."); return end

    local characters = plugin.db:load(book_id)
    if #characters == 0 then
        plugin:showMsg("No characters saved yet.")
        return
    end

    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok then return end

    local selected = {}
    local menu_ref

    local function showSelectionMenu()
        local n = 0
        for _ in pairs(selected) do n = n + 1 end

        local items = {}
        table.insert(items, {
            text = n > 0
                and ("Generate portraits for " .. n .. " character(s)")
                or  "(tap characters to select)",
            callback = function()
                if n == 0 then return end
                UIManager:close(menu_ref)

                local to_gen = {}
                for i, c in ipairs(characters) do
                    if selected[i] then table.insert(to_gen, c) end
                end

                local succeeded, failed = 0, {}
                for idx, char in ipairs(to_gen) do
                    local prog = InfoMessage:new{
                        text = "Generating portrait " .. idx .. "/" .. #to_gen
                              .. "\n" .. (char.name or "")
                    }
                    UIManager:show(prog)
                    UIManager:forceRePaint()
                    local gen_err = Portrait.generate(plugin, book_id, char)
                    UIManager:close(prog)
                    if gen_err then
                        table.insert(failed, (char.name or "?") .. ": " .. gen_err)
                    else
                        succeeded = succeeded + 1
                    end
                end

                local summary = "Done. " .. succeeded .. "/" .. #to_gen .. " portrait(s) saved."
                if #failed > 0 then
                    summary = summary .. "\n\nFailed:\n" .. table.concat(failed, "\n")
                end
                plugin:showMsg(summary, 6)
            end,
        })

        for i, c in ipairs(characters) do
            local has_img = Portrait.has(book_id, c)
            local check   = selected[i] and "[x] " or "[ ] "
            local img_tag = has_img and " [img]" or ""
            local idx     = i
            table.insert(items, {
                text = check .. (c.name or "Unknown") .. img_tag,
                callback = function()
                    selected[idx] = not selected[idx] or nil
                    UIManager:close(menu_ref)
                    showSelectionMenu()
                end,
            })
        end

        menu_ref = Menu:new{
            title       = "Select characters — [img] = portrait exists",
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = plugin.ui,
        }
        UIManager:show(menu_ref)
    end

    showSelectionMenu()
end

Portrait.DEFAULT_CODEX_PORTRAIT_PROMPT = [[Visual depiction of a fictional {{type}} from a book. Square composition, 1024x1024. No text. No words. No letters. No labels. No watermarks. No inscriptions. Pure image only. Subject: {{name}}. Description: {{description}} Significance: {{significance}} Book setting: {{book_context}} Paint in a rich, detailed style consistent with the book's setting and era. The image should serve as an encyclopaedia illustration — evocative, accurate, and atmospheric.]]

Portrait.DEFAULT_CODEX_CONCEPT_PORTRAIT_PROMPT = [[Abstract symbolic illustration of a fictional concept from a book. Square composition, 1024x1024. Absolutely no text. No words. No letters. No labels. No watermarks. No inscriptions. Pure image only. Concept: {{name}}. {{description}} Book setting: {{book_context}} Do not attempt a literal depiction. Instead create a purely visual, atmospheric image — use light, color, texture, and symbolic imagery to evoke the feeling and significance of this concept. Style: dark fantasy illustration, painterly, atmospheric, no typography of any kind.]]

-- Returns the absolute path where a portrait for this codex entry should be stored.
function Portrait.codexPath(book_id, entry)
    local DataStorage = require("datastorage")
    local util        = require("util")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/codex_portraits"
    util.makePath(dir)
    local filename = (entry.id and entry.id ~= "") and (entry.id .. ".png")
                     or (portraitSafeName(entry.name or "unknown") .. ".png")
    return dir .. "/" .. filename
end

-- Returns true if a portrait image file exists for this codex entry.
function Portrait.codexHas(book_id, entry)
    local path = Portrait.codexPath(book_id, entry)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Core generation for a codex entry: calls Imagen, decodes, saves.
-- Returns nil on success, or an error string on failure.
function Portrait.generateCodex(plugin, book_id, entry)
    local DataStorage = require("datastorage")
    local json        = require("dkjson")
    local util        = require("util")
    local portraits_dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/codex_portraits"
    util.makePath(portraits_dir)

    local name  = entry.name or "Unknown"
    local etype = entry.type or "concept"
    local desc  = entry.description or ""
    local sig   = entry.significance or ""

    local function sub(s, key, val)
        return (s:gsub("{{" .. key .. "}}", function() return val end))
    end

    local book_context = plugin.db:loadBookContext(book_id)
    local default_tmpl = (etype == "concept")
        and Portrait.DEFAULT_CODEX_CONCEPT_PORTRAIT_PROMPT
        or  Portrait.DEFAULT_CODEX_PORTRAIT_PROMPT
    local tmpl   = G_reader_settings:readSetting("kocharacters_codex_portrait_prompt")
                   or default_tmpl
    local prompt = sub(sub(sub(sub(sub(tmpl,
        "name", name), "type", etype), "description", desc),
        "significance", sig), "book_context", book_context)

    local api_key   = plugin:getImagenApiKey()
    local out_path  = Portrait.codexPath(book_id, entry)
    local req_file  = portraits_dir .. "/.imagen_req.json"
    local resp_file = portraits_dir .. "/.imagen_resp.json"

    local fq = io.open(req_file, "w")
    if not fq then return "Could not write request file." end
    fq:write(json.encode({
        instances  = {{ prompt = prompt }},
        parameters = { sampleCount = 1, aspectRatio = "1:1" },
    }))
    fq:close()

    local imagen_model = G_reader_settings:readSetting("kocharacters_imagen_model")
                         or "imagen-4.0-fast-generate-001"
    local url = "https://generativelanguage.googleapis.com/v1beta/models/"
                .. imagen_model .. ":predict?key=" .. api_key
    os.execute(string.format(
        'curl -s --max-time 120 -X POST -H "Content-Type: application/json" -d @"%s" "%s" -o "%s"',
        req_file, url, resp_file
    ))
    os.remove(req_file)

    local f = io.open(resp_file, "r")
    if not f then return "No response from Imagen API." end
    local raw = f:read("*a")
    f:close()
    os.remove(resp_file)

    local parsed = json.decode(raw)
    if not parsed then return "Could not parse Imagen response:\n" .. raw:sub(1, 200) end
    if parsed.error then
        return "Imagen error:\n" .. (parsed.error.message or json.encode(parsed.error))
    end

    local b64 = parsed.predictions
                and parsed.predictions[1]
                and parsed.predictions[1].bytesBase64Encoded
    if not b64 or b64 == "" then
        return "Imagen returned no image.\n" .. raw:sub(1, 200)
    end

    local tmp_b64 = portraits_dir .. "/.tmp_b64"
    local fb = io.open(tmp_b64, "w")
    if not fb then return "Could not write temp file." end
    fb:write(b64)
    fb:close()

    local ret = os.execute('base64 -d "' .. tmp_b64 .. '" > "' .. out_path .. '"')
    os.remove(tmp_b64)
    if ret ~= 0 then return "Failed to decode portrait image." end

    plugin:recordUsage({ images = 1 })
    return nil
end

-- Shows progress UI, calls Portrait.generateCodex, shows result.
function Portrait.onGenerateCodex(plugin, book_id, entry)
    local msg = InfoMessage:new{
        text = "Generating image for " .. (entry.name or "entry") .. "…"
    }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local err = Portrait.generateCodex(plugin, book_id, entry)
    UIManager:close(msg)
    if err then
        plugin:showMsg(err, 8)
    else
        plugin:showMsg("Image saved for " .. (entry.name or "entry") .. ".", 3)
    end
end

return Portrait
