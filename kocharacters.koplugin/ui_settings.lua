-- ui_settings.lua
-- Settings menus: AI keys, prompts, behaviour toggles, export config, usage, about.
-- Entry point: UISettings.open(plugin)

local UIManager   = require("ui/uimanager")
local InfoMessage  = require("ui/widget/infomessage")
local Screen       = require("device").screen

local UISettings = {}

-- Shows the prompt edit dialog.
function UISettings.editPrompt(plugin, title, setting_key, default_prompt)
    local InputDialog = require("ui/widget/inputdialog")
    local current    = G_reader_settings:readSetting(setting_key) or default_prompt
    local is_custom  = G_reader_settings:readSetting(setting_key) ~= nil
    local label      = is_custom and "Custom prompt active" or "Using default prompt"
    local dialog
    dialog = InputDialog:new{
        title       = title,
        input       = current,
        description = label .. "\nExtraction: {{existing}} {{skip}} {{text}}\nRe-analyze/Cleanup: {{character}} {{text}}\nPortrait: {{name}} {{role}} {{appearance}} {{personality}} {{relationships}} {{context}}",
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
                        plugin:showMsg("Prompt reset to default.", 2)
                    end,
                },
                {
                    text             = "Save",
                    is_enter_default = true,
                    callback         = function()
                        local text = dialog:getInputText() or ""
                        G_reader_settings:saveSetting(setting_key, text)
                        UIManager:close(dialog)
                        plugin:showMsg("Prompt saved.", 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows the Gemini extraction API key input dialog.
function UISettings.setExtractionApiKey(plugin)
    local InputDialog = require("ui/widget/inputdialog")
    local current_key = G_reader_settings:readSetting("kocharacters_extraction_api_key") or ""
    local dialog
    dialog = InputDialog:new{
        title       = "Gemini Character Extraction Key",
        input       = current_key,
        input_hint  = "AIza...",
        description = "API key used for character extraction, cleanup,\nand relationship mapping.\nGet a free key at aistudio.google.com",
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dialog) end },
            {
                text = "Save", is_enter_default = true,
                callback = function()
                    local key = (dialog:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                    G_reader_settings:saveSetting("kocharacters_extraction_api_key", key)
                    UIManager:close(dialog)
                    plugin:showMsg("Character extraction key saved.", 2)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows the Imagen API key input dialog.
function UISettings.setApiKey(plugin)
    local InputDialog = require("ui/widget/inputdialog")
    local current_key = G_reader_settings:readSetting("kocharacters_imagen_api_key") or ""
    local dialog
    dialog = InputDialog:new{
        title       = "Gemini Image Generation Key",
        input       = current_key,
        input_hint  = "AIza...",
        description = "API key used for portrait generation (Imagen).\nGet a key at aistudio.google.com",
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dialog) end },
            {
                text = "Save", is_enter_default = true,
                callback = function()
                    local key = (dialog:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                    G_reader_settings:saveSetting("kocharacters_imagen_api_key", key)
                    UIManager:close(dialog)
                    plugin:showMsg("Image generation key saved.", 2)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Opens the main settings menu.
function UISettings.open(plugin)
    local Menu        = require("ui/widget/menu")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local TextViewer  = require("ui/widget/textviewer")
    local InputDialog = require("ui/widget/inputdialog")
    local GeminiClient = require("gemini_client")
    local Portrait     = require("portrait")

    local function openAISettings()
        local ai_menu
        ai_menu = Menu:new{
            title      = "AI Settings",
            item_table = {
                {
                    text     = "Gemini Character Extraction key",
                    callback = function() UISettings.setExtractionApiKey(plugin) end,
                    help     = "API key used for character extraction, cleanup, reanalysis, and relationship mapping. Get a free key at aistudio.google.com.\n\nFree tier limits: 15 requests/min, 500 requests/day, 250 000 tokens/min.",
                },
                {
                    text_func = function()
                        local id = G_reader_settings:readSetting("kocharacters_gemini_model")
                                   or GeminiClient.DEFAULT_MODEL
                        for _, m in ipairs(GeminiClient.MODELS) do
                            if m.id == id then return "Gemini model: " .. m.name end
                        end
                        return "Gemini model: " .. id
                    end,
                    callback = function()
                        UISettings.chooseModel(plugin, function()
                            UIManager:close(ai_menu)
                            openAISettings()
                        end)
                    end,
                    help     = "The Gemini model used for all character and codex extraction. Free-tier models are available at no cost but have lower rate limits. Paid models require a billing-enabled API key and offer higher quality or higher throughput.",
                },
                {
                    text     = "Gemini Image Generation key",
                    callback = function() UISettings.setApiKey(plugin) end,
                    help     = "A separate API key used to generate character portrait images with Google Imagen. Can be the same key as the extraction key, or a different one. Requires Imagen API access on your Google Cloud project.",
                },
                {
                    text_func = function()
                        local m = G_reader_settings:readSetting("kocharacters_imagen_model") or "imagen-4.0-fast-generate-001"
                        return "Imagen model: " .. m
                    end,
                    help     = "The Imagen model used to generate character portraits.\n\n• imagen-4.0-fast: quickest, lowest cost\n• imagen-4.0: balanced quality and speed\n• imagen-4.0-ultra: highest quality, slower and more expensive",
                    callback = function()
                        local model_menu
                        local items = {}
                        for _, m in ipairs({
                            "imagen-4.0-fast-generate-001",
                            "imagen-4.0-generate-001",
                            "imagen-4.0-ultra-generate-001",
                        }) do
                            local model = m
                            table.insert(items, {
                                text     = model,
                                callback = function()
                                    G_reader_settings:saveSetting("kocharacters_imagen_model", model)
                                    UIManager:close(model_menu)
                                    UIManager:close(ai_menu)
                                    openAISettings()
                                end,
                            })
                        end
                        model_menu = Menu:new{
                            title       = "Select Imagen Model",
                            item_table  = items,
                            width       = Screen:getWidth(),
                            show_parent = plugin.ui,
                        }
                        UIManager:show(model_menu)
                    end,
                },
                {
                    text     = "Edit extraction prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Extraction Prompt", "kocharacters_extraction_prompt",
                        GeminiClient.DEFAULT_EXTRACTION_PROMPT) end,
                    help     = "The prompt sent to Gemini when scanning a page for new characters. Edit to change which fields are extracted, how characters are described, or to add custom instructions for your genre.",
                },
                {
                    text     = "Edit cleanup prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Cleanup Prompt", "kocharacters_cleanup_prompt",
                        GeminiClient.DEFAULT_CLEANUP_PROMPT) end,
                    help     = "The prompt used when cleaning up a single character. Controls how Gemini merges near-duplicate entries, normalises phrasing, and polishes character text fields.",
                },
                {
                    text     = "Edit batch cleanup prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Batch Cleanup Prompt", "kocharacters_characters_cleanup_prompt",
                        GeminiClient.DEFAULT_CHARACTERS_CLEANUP_PROMPT) end,
                    help     = "The prompt used during 'Cleanup all characters'. Same rules as the single-character cleanup but processes multiple characters in one API call.",
                },
                {
                    text     = "Edit re-analyze prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Re-analyze Prompt", "kocharacters_reanalyze_prompt",
                        GeminiClient.DEFAULT_REANALYZE_PROMPT) end,
                    help     = "The prompt used when you tap 'Re-analyze' on an individual character. Gemini re-reads the character's existing profile alongside the current page text and produces an updated version.",
                },
                {
                    text     = "Edit relationship map prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Relationship Map Prompt", "kocharacters_relationship_map_prompt",
                        GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT) end,
                    help     = "The prompt used to generate the relationship map. Controls how Gemini describes the connections, alliances, conflicts, and dynamics between characters in the book.",
                },
                {
                    text     = "Edit portrait prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Portrait Prompt", "kocharacters_portrait_prompt",
                        Portrait.DEFAULT_PORTRAIT_PROMPT) end,
                    help     = "The prompt template used when generating a character portrait with Imagen. Controls the visual style, composition, and mood. The character's name and description are appended automatically.",
                },
                {
                    text     = "Edit codex image prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Codex Image Prompt", "kocharacters_codex_portrait_prompt",
                        Portrait.DEFAULT_CODEX_PORTRAIT_PROMPT) end,
                    help     = "The prompt template used when generating an image for a codex entry (place, faction, object, etc.) with Imagen. Controls visual style and composition.",
                },
                {
                    text     = "Edit merge detection prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Merge Detection Prompt", "kocharacters_merge_detection_prompt",
                        GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT) end,
                    help     = "The prompt used when checking a batch of characters for near-duplicates. Gemini reviews the list and flags entries that likely represent the same character under different names or spellings.",
                },
                {
                    text     = "Edit codex create prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Codex Create Prompt", "kocharacters_codex_create_prompt",
                        GeminiClient.DEFAULT_CODEX_CREATE_PROMPT) end,
                    help     = "The prompt used when you long-press a word and tap 'Track in Codex'. Controls how Gemini classifies and describes the new world-building entry.",
                },
                {
                    text     = "Edit codex update prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Codex Update Prompt", "kocharacters_codex_update_prompt",
                        GeminiClient.DEFAULT_CODEX_UPDATE_PROMPT) end,
                    help     = "The prompt used during auto-enrichment when known codex entries appear on a scanned page. Controls how Gemini updates existing entries with new context.",
                },
                {
                    text     = "Edit codex cleanup prompt",
                    callback = function() UISettings.editPrompt(plugin,
                        "Codex Cleanup Prompt", "kocharacters_codex_cleanup_prompt",
                        GeminiClient.DEFAULT_CODEX_CLEANUP_PROMPT) end,
                    help     = "The prompt used by 'Cleanup all codex entries'. Controls how Gemini deduplicates and tidies description and connection fields.",
                },
                {
                    text     = "View book context (auto-built)",
                    callback = function()
                        local bid = plugin:getBookID()
                        if not bid then plugin:showMsg("No book open."); return end
                        local ctx = plugin.db:loadBookContext(bid)
                        if not ctx or ctx == "" then
                            plugin:showMsg("No book context yet.\nScan pages or chapters to build it automatically.")
                            return
                        end
                        UIManager:show(ConfirmBox:new{
                            text        = "Book context:\n\n" .. ctx .. "\n\nClear this context?",
                            ok_text     = "Clear",
                            cancel_text = "Keep",
                            ok_callback = function()
                                os.remove(plugin.db:bookContextPath(bid))
                                plugin:showMsg("Book context cleared.", 2)
                            end,
                        })
                    end,
                    help     = "Shows the accumulated summary the plugin has built for this book from previous scans. This context is included in extraction prompts to give Gemini continuity across pages. Tap to view; you can clear it here to start fresh.",
                },
            },
            width       = Screen:getWidth(),
            show_parent = plugin.ui,
            onMenuHold  = function(_, item)
                if item and item.help then
                    UIManager:show(InfoMessage:new{ text = item.help })
                end
            end,
        }
        UIManager:show(ai_menu)
    end

    local settings_menu
    settings_menu = Menu:new{
        title      = "KoCharacters Settings",
        item_table = {
            {
                text     = "AI Settings",
                callback = function() openAISettings() end,
                help     = "Opens AI configuration: set your Gemini API key, Imagen API key, and customise the AI prompts used for extraction, cleanup, reanalysis, and portrait generation.",
            },
            {
                text_func = function()
                    return "Auto-extract on page turn: "
                        .. (G_reader_settings:readSetting("kocharacters_auto_extract") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_auto_extract")
                    G_reader_settings:saveSetting("kocharacters_auto_extract", not on)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help     = "When ON, the plugin automatically scans the current page for new characters each time you turn a page. Requires an extraction API key to be set.",
            },
            {
                text_func = function()
                    return "Auto-extract delay: "
                        .. (G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10) .. "s"
                end,
                help     = "How long (in seconds) the plugin waits after a page turn before scanning. A longer delay prevents accidental scans during quick swipes. Default: 10 s.",
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
                                        UIManager:close(settings_menu)
                                        UISettings.open(plugin)
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
                text_func = function()
                    return "Cleanup batch size: "
                        .. (G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5)
                end,
                help     = "How many characters are sent to Gemini in a single cleanup request. Smaller batches use more API calls but stay safely under the rate limit. Default: 5.",
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title      = "Characters per cleanup batch",
                        input      = tostring(G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5),
                        input_type = "number",
                        buttons    = {{
                            { text = "Cancel", callback = function() UIManager:close(dialog) end },
                            {
                                text             = "Save",
                                is_enter_default = true,
                                callback         = function()
                                    local val = tonumber(dialog:getInputText())
                                    UIManager:close(dialog)
                                    if val and val >= 1 then
                                        G_reader_settings:saveSetting("kocharacters_cleanup_batch_size", math.floor(val))
                                        UIManager:close(settings_menu)
                                        UISettings.open(plugin)
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
                text_func = function()
                    return "Detect duplicates after cleanup: "
                        .. (G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup")
                    G_reader_settings:saveSetting("kocharacters_detect_dupes_after_cleanup", not on)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help     = "When ON, KoCharacters automatically checks for near-duplicate character names after each cleanup run and warns you if any are found.",
            },
            {
                text_func = function()
                    local level = G_reader_settings:readSetting("kocharacters_toast_level") or "full"
                    local labels = { full = "Page + count", count = "Count only", errors = "Errors only", off = "Off" }
                    return "Result toasts: " .. (labels[level] or "Page + count")
                end,
                callback = function()
                    local cycle = { "full", "count", "errors", "off" }
                    local current = G_reader_settings:readSetting("kocharacters_toast_level") or "full"
                    local next_level = "full"
                    for i, v in ipairs(cycle) do
                        if v == current then
                            next_level = cycle[(i % #cycle) + 1]
                            break
                        end
                    end
                    G_reader_settings:saveSetting("kocharacters_toast_level", next_level)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help = "Controls what appears in the on-screen toast after each page scan. 'Page + count' shows the page number and how many items were updated (e.g. p142:3). 'Count only' shows just the number. 'Errors only' suppresses success toasts but still shows API error warnings. 'Off' disables all toasts.",
            },
            {
                text_func = function()
                    return "Scan indicator icon: "
                        .. (G_reader_settings:readSetting("kocharacters_scan_indicator") ~= false and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_scan_indicator") ~= false
                    G_reader_settings:saveSetting("kocharacters_scan_indicator", not on)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help     = "Shows a small icon on-screen while the plugin is scanning a page in the background. Turn OFF if you find it distracting.",
            },
            {
                text_func = function()
                    return "Auto-accept enrichments: "
                        .. (G_reader_settings:readSetting("kocharacters_auto_enrich") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_auto_enrich")
                    G_reader_settings:saveSetting("kocharacters_auto_enrich", not on)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help     = "When ON, AI-enriched character data (extra detail, backstory, traits) is saved automatically without asking for confirmation each time.",
            },
            {
                text_func = function()
                    return "Spoiler protection: "
                        .. (G_reader_settings:readSetting("kocharacters_spoiler_protection") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_spoiler_protection")
                    G_reader_settings:saveSetting("kocharacters_spoiler_protection", not on)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help     = "When ON, characters whose profiles were built from pages you haven't reached yet are hidden as [SPOILER] in the browser. Tap a spoiler entry to reveal it.",
            },
            {
                text_func = function()
                    return "Detail view: "
                        .. (G_reader_settings:readSetting("kocharacters_html_viewer") and "HTML" or "Text")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_html_viewer")
                    G_reader_settings:saveSetting("kocharacters_html_viewer", not on)
                    UIManager:close(settings_menu)
                    UISettings.open(plugin)
                end,
                help     = "Text mode shows plain info in a scrollable text viewer.\nHTML mode renders a richer layout and displays AI-generated portrait images.",
            },
            {
                text     = "View API usage",
                callback = function() plugin:onViewUsage() end,
                help     = "Shows your Gemini API consumption grouped by date: prompt tokens (text sent to the AI), output tokens (text received back), and image generation calls.\n\nUseful for tracking against free-tier limits: 15 requests/min, 500 requests/day, 250 000 tokens/min.",
            },
            {
                text     = "Clear character database",
                callback = function() plugin:onClearDatabase() end,
                help     = "Permanently deletes all character data for every book. This cannot be undone — use with caution.",
            },
            {
                text     = "Reset prompts to default",
                help     = "Restores the built-in AI prompts for extraction, cleanup, reanalysis, relationship mapping, merge detection, and portrait generation. Any customisations you have made will be lost.",
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Reset all prompts to their built-in defaults?",
                        ok_text     = "Reset",
                        ok_callback = function()
                            G_reader_settings:delSetting("kocharacters_extraction_prompt")
                            G_reader_settings:delSetting("kocharacters_cleanup_prompt")
                            G_reader_settings:delSetting("kocharacters_reanalyze_prompt")
                            G_reader_settings:delSetting("kocharacters_relationship_map_prompt")
                            G_reader_settings:delSetting("kocharacters_portrait_prompt")
                            G_reader_settings:delSetting("kocharacters_merge_detection_prompt")
                            plugin:showMsg("Prompts reset to defaults.", 2)
                        end,
                    })
                end,
            },
            {
                text     = "Export settings",
                help     = "Configure the HTTP endpoint URL and API key used when uploading your character database to an external server (e.g. a personal web app or home server).",
                callback = function()
                    local function inputDialog(title, setting_key, hint, on_save)
                        local dialog
                        dialog = InputDialog:new{
                            title      = title,
                            input      = G_reader_settings:readSetting(setting_key) or "",
                            input_hint = hint,
                            buttons    = {{
                                { text = "Cancel", callback = function() UIManager:close(dialog) end },
                                {
                                    text = "Save", is_enter_default = true,
                                    callback = function()
                                        local val = (dialog:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                                        G_reader_settings:saveSetting(setting_key, val)
                                        UIManager:close(dialog)
                                        if on_save then on_save(val) end
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dialog)
                        dialog:onShowKeyboard()
                    end
                    local export_settings_menu
                    export_settings_menu = Menu:new{
                        title      = "Export Settings",
                        item_table = {
                            {
                                text     = "Upload endpoint URL",
                                callback = function()
                                    inputDialog(
                                        "Upload endpoint URL",
                                        "kocharacters_upload_endpoint",
                                        "https://example.com/api/upload",
                                        function() plugin:showMsg("Endpoint saved.", 2) end
                                    )
                                end,
                            },
                            {
                                text     = "Upload API key",
                                callback = function()
                                    inputDialog(
                                        "Upload API key",
                                        "kocharacters_upload_api_key",
                                        "your-secret-key",
                                        function() plugin:showMsg("API key saved.", 2) end
                                    )
                                end,
                            },
                        },
                        width       = Screen:getWidth(),
                        show_parent = plugin.ui,
                    }
                    UIManager:show(export_settings_menu)
                end,
            },
            {
                text     = "About",
                callback = function()
                    local meta = require("_meta")
                    UIManager:show(TextViewer:new{
                        title = "About KoCharacters",
                        text  = "KoCharacters v" .. (meta.version or "?") .. "\n\n"
                             .. "Automatically extract, track, and enrich character profiles from your books using Google Gemini AI. "
                             .. "Generate portraits with Google Imagen. Runs on KOReader on Kindle and other supported devices.\n\n"
                             .. "\xC2\xA9 2026\nNefelodamon\n\n"
                             .. "https://github.com/nefelodamon/KoCharacters",
                        width  = math.floor(Screen:getWidth() * 0.9),
                        height = math.floor(Screen:getHeight() * 0.6),
                    })
                end,
            },
        },
        width       = Screen:getWidth(),
        show_parent = plugin.ui,
        onMenuHold  = function(_, item)
            if item and item.help then
                UIManager:show(InfoMessage:new{ text = item.help })
            end
        end,
    }
    UIManager:show(settings_menu)
end

-- ---------------------------------------------------------------------------
-- Model selector
-- ---------------------------------------------------------------------------

function UISettings.chooseModel(plugin, on_close)
    local GeminiClient = require("gemini_client")
    local json         = require("dkjson")
    local DataStorage  = require("datastorage")
    local Menu         = require("ui/widget/menu")

    local path = DataStorage:getDataDir() .. "/kocharacters/usage_stats.json"
    local tot_prompt, tot_output = 0, 0
    local f = io.open(path, "r")
    if f then
        local stats = json.decode(f:read("*all")) or {}
        f:close()
        for _, d in pairs(stats) do
            tot_prompt = tot_prompt + (d.prompt_tokens or 0)
            tot_output = tot_output + (d.output_tokens or 0)
        end
    end

    local current = G_reader_settings:readSetting("kocharacters_gemini_model")
                    or GeminiClient.DEFAULT_MODEL

    local function fmt_cost(m)
        local c = (tot_prompt / 1e6 * m.input_price) + (tot_output / 1e6 * m.output_price)
        return string.format("$%.2f", c)
    end

    local function build_help(m)
        return m.name .. "\n\n"
            .. m.description .. "\n\n"
            .. "Pricing (per 1M tokens):\n"
            .. string.format("  Input:  $%.3f\n", m.input_price)
            .. string.format("  Output: $%.3f\n", m.output_price)
            .. "\nYour total usage: "
            .. tot_prompt .. " input + " .. tot_output .. " output tokens\n"
            .. "Estimated spend at this model's rates: " .. fmt_cost(m)
    end

    local model_menu
    local items = {}
    for _, m in ipairs(GeminiClient.MODELS) do
        local model = m
        local is_current = (model.id == current)
        local tier    = model.free_tier and "Free" or "Paid"
        local preview = model.preview and "Preview" or "Stable"
        local label   = model.name .. "  [" .. tier .. " · " .. preview .. "]  •  " .. fmt_cost(model) .. " est."
        if is_current then label = label .. "  ✓" end
        table.insert(items, {
            text     = label,
            help     = build_help(model),
            callback = function()
                G_reader_settings:saveSetting("kocharacters_gemini_model", model.id)
                UIManager:close(model_menu)
                if on_close then on_close() end
            end,
        })
    end

    model_menu = Menu:new{
        title      = "Select Gemini Model",
        item_table = items,
        width      = Screen:getWidth(),
        show_parent = plugin.ui,
        onMenuHold  = function(_, item)
            if item and item.help then
                UIManager:show(InfoMessage:new{ text = item.help })
            end
        end,
    }
    UIManager:show(model_menu)
end

-- API usage viewer
-- ---------------------------------------------------------------------------

function UISettings.onViewUsage(plugin)
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
        plugin:showMsg("No API usage recorded yet.", 3)
        return
    end

    local lines = { "Date            Calls  Prompt     Output     Images" }
    table.insert(lines, string.rep("-", 52))
    local tot_calls, tot_prompt, tot_output, tot_images = 0, 0, 0, 0
    for _, date in ipairs(dates) do
        local d = stats[date]
        local c = d.calls         or 0
        local p = d.prompt_tokens or 0
        local o = d.output_tokens or 0
        local i = d.images        or 0
        tot_calls  = tot_calls  + c
        tot_prompt = tot_prompt + p
        tot_output = tot_output + o
        tot_images = tot_images + i
        table.insert(lines, string.format("%-16s %-6d %-10d %-10d %d", date, c, p, o, i))
    end
    table.insert(lines, string.rep("-", 52))
    table.insert(lines, string.format("%-16s %-6d %-10d %-10d %d", "TOTAL", tot_calls, tot_prompt, tot_output, tot_images))

    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title  = "API Usage (Gemini + Imagen)",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

return UISettings
