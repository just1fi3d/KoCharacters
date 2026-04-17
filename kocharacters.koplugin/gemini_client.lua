-- gemini_client.lua
-- Handles all communication with the Google Gemini API (free tier)
-- Model: gemini-3.1-flash-lite-preview — free at aistudio.google.com

local json  = require("dkjson")
local https = require("ssl.https")
local ltn12 = require("ltn12")

local GeminiClient = {}
GeminiClient.__index = GeminiClient

local MODEL        = "gemini-3.1-flash-lite-preview"
local API_BASE     = "https://generativelanguage.googleapis.com/v1beta/models/" .. MODEL .. ":generateContent"
local API_MODELS_BASE = "https://generativelanguage.googleapis.com/v1beta/models/"

-- Safe placeholder substitution (handles % in values correctly)
local function sub(s, placeholder, value)
    return (s:gsub(placeholder, function() return value end))
end

-- Extract token usage from a parsed Gemini response
local function extractUsage(parsed)
    local m = parsed and parsed.usageMetadata
    if not m then return nil end
    return {
        prompt_tokens = m.promptTokenCount    or 0,
        output_tokens = m.candidatesTokenCount or 0,
        total_tokens  = m.totalTokenCount      or 0,
    }
end

GeminiClient.DEFAULT_EXTRACTION_PROMPT = [[
You are analyzing a passage from a novel or book.

Your tasks:
1. Extract any NEW named characters who are introduced or significantly described in this passage.
2. Update the profiles of EXISTING characters (listed below) who appear in this passage.
   - Preserve exactly: name, aliases, occupation, role, relationships, first_appearance_quote, identity_tags, defining_moments.
   - Rewrite as a fresh unified summary: personality, physical_description, motivation. Treat the existing value as input — incorporate it with any new observations into one coherent description. Never append sentences to the existing text.

Existing character profiles to UPDATE (return updated profile only if they appear in this passage):
{{existing}}

Characters to SKIP entirely (do not return these):
{{skip}}

Rules:
- Only include characters who have a name (first name, last name, or title+name). Skip unnamed background figures.
- For existing characters: only return them if they actually appear in this passage.
- For new characters: only include if there is enough information to build a meaningful profile.
- If there is nothing to report, return an empty JSON array: []
- Never use placeholder text such as "Not specified.", "Unknown", or "N/A" in any field. Use an empty string if information is unavailable.
- For personality: rewrite as a single unified description of stable character traits — incorporate the existing description and any new observations from this passage into one coherent summary. Do NOT append sentences to the existing text. Do NOT list events or actions.
- For physical_description: rewrite as a single unified description incorporating existing and new explicit appearance details only. Do not infer appearance from actions.
- Never append raw actions or scene summaries to any field. Every field should read like a character description, not a plot summary.
- For identity_tags: capture core "what they are" markers — faction membership, social class, formal status, and demonstrated abilities. In hard magic systems, named ability classifications belong here ("Mistborn", "Feralchemist"). In any setting, only include abilities the text explicitly establishes or acknowledges — never infer from personality. Update if the passage reveals a new identity (e.g. a secret role is unmasked, a faction is joined or left). Do not duplicate occupation.
- For motivation: infer what the character fundamentally wants or fears. This is stable — only update it if the passage meaningfully changes or clarifies it. Write as a concise statement ("wants to avenge her brother's death", "fears becoming like her father"). Never write this as a plot summary.
- For defining_moments: only capture a "One-Way Door" event — one after which the character's status, body, or knowledge is permanently altered.
    Include: permanent injuries, social exile or promotion, discovering a plot-critical secret, joining or leaving a faction.
    Exclude: combat without consequence, travel, standard dialogue, temporary moods.
  Each entry must be one sentence in past tense. Append new entries; never duplicate existing ones.
- For relationships: use the exact name as it appears in the existing profiles list above — not a shortened or alternate form. Format each entry as "Name (relationship type)". Examples: "Amanda (sister)", "Lord Vance (employer)", "Kira (rival)", "The King (ally)". One entry per named person. Never write "Brother to Amanda" or "Amanda - Sister" style.
- For role: default to "supporting" rather than "unknown" unless there is a clear reason the character cannot be classified.
- For name: use the most complete known name as the primary name. If a fuller name is established in this passage for a character currently known by a short name (e.g. "Luc" is confirmed to be "Luc Holdfast"), use the full name and put the short name in aliases.

Return ONLY a valid JSON object with no markdown formatting, no code fences, no explanation, no extra text — just the raw JSON object with this exact structure:
{
  "book_context": "2-3 sentences describing the genre, country/region, and historical period or era of the story. Current known context: {{book_context}} — update and expand this if the passage adds new information, otherwise return it unchanged. Leave empty string only if nothing is known.",
  "characters": [
    {
      "name": "Full name or best available name",
      "aliases": ["nickname", "title"],
      "identity_tags": ["Core faction, class, status, or demonstrated ability markers — e.g. 'Inquisition Member', 'Convicted Outlaw', 'Mistborn', 'Necromancer'. Distinct from occupation. Only include abilities the text explicitly establishes."],
      "occupation": "Job title, profession, or social role (e.g. blacksmith, governess, army captain) — empty string if unknown",
      "first_appearance_quote": "A short verbatim quote from the text where they first appear",
      "physical_description": "A concise summary of their appearance based on explicit descriptions only, else empty string",
      "personality": "A concise summary of stable character traits inferred from their behaviour — written as description, not event log",
      "motivation": "What drives this character at their core — their deepest goal, fear, or belief. Infer from choices and stated desires. Empty string if unknown.",
      "defining_moments": ["A One-Way Door event that permanently altered this character's status, body, or knowledge — one sentence, past tense. Only include if this passage contains one."],
      "role": "protagonist or antagonist or supporting or unknown",
      "relationships": ["Name (relationship type) — e.g. \"Amanda (sister)\", \"Lord Vance (employer)\", \"Kira (rival)\". One entry per named person."]
    }
  ]
}

If there are no characters to report, use an empty array for "characters": []

Page text:
---
{{text}}
---
]]

GeminiClient.DEFAULT_REANALYZE_PROMPT = [[
You are updating the profile of a specific character in a novel based on a new passage.

The character to update is:
{{character}}

Read the passage below and update the character's profile.
- Preserve exactly: name, aliases, occupation, role, relationships, first_appearance_quote, identity_tags, defining_moments.
- Rewrite as a fresh unified summary: personality, physical_description, motivation. Treat the existing value as input — incorporate it with any new observations into one coherent description. Never append sentences to the existing text.

Rules:
- For personality: rewrite as a single unified description of stable traits — incorporate the existing description and new observations into one coherent summary. Do NOT append. Never list events or actions.
- For physical_description: rewrite as a single unified description incorporating existing and new explicit appearance details only. No action-based inferences.
- Never append raw actions or scene summaries to any field.
- For defining_moments: ask — is this a "One-Way Door"? Is the character's status, body, or knowledge permanently altered? If yes, add one past-tense sentence. If no, do not add anything. Append only; never remove or duplicate existing entries.
- For identity_tags: update if the passage reveals a new core identity (secret role, faction change, formal status change, or an explicitly established ability). Otherwise preserve unchanged.
- For motivation: enrich if the passage meaningfully clarifies or changes what the character wants or fears; otherwise preserve unchanged.

If this character does not appear in the passage at all, return an empty JSON array: []

Return ONLY a valid JSON array with no markdown formatting, no code fences, no explanation — just the raw JSON array containing the single updated character:
[
  {
    "name": "Full name or best available name",
    "aliases": ["nickname", "title"],
    "identity_tags": ["Core faction, class, status, or demonstrated ability markers"],
    "occupation": "Job title, profession, or social role — empty string if unknown",
    "first_appearance_quote": "Keep existing quote unless a better one is found in this passage",
    "physical_description": "Merged appearance summary — explicit descriptions only",
    "personality": "Merged personality summary — stable traits inferred from behaviour, written as description not event log",
    "motivation": "What drives this character at their core — stable goal, fear, or belief. Empty string if unknown.",
    "defining_moments": ["One-Way Door events that permanently altered this character — one sentence each, past tense"],
    "role": "protagonist or antagonist or supporting or unknown",
    "relationships": ["Name (relationship type) — e.g. \"Amanda (sister)\", \"Lord Vance (employer)\". One entry per named person."]
  }
]

Passage:
---
{{text}}
---
]]

GeminiClient.DEFAULT_CODEX_CLEANUP_PROMPT = [[
You are cleaning up world-building entries from a book. Some text fields may contain repeated or redundant information built up incrementally.

For each entry, clean up these fields:
- description: remove repetitions, combine fragmented observations into one fluent paragraph. If it has grown into an exhaustive list of observed instances or uses, synthesize into a general characterization of what the thing is and how it works.
- significance: same — one coherent statement of narrative role. Must be distinct from description (not a restatement of what the thing does).
- known_connections: normalize to "Name (relationship)" format, deduplicate. Replace any role descriptors (e.g. "protagonist", "subject") with the character's actual name if it can be inferred from context.
- aliases: deduplicate, remove entries that are just alternate casings of the name

Return ONLY a valid JSON array (no markdown, no code fences) with the same number of entries in the same order. Each element must have exactly these keys:
[{ "name": "...", "description": "...", "significance": "...", "known_connections": ["..."], "aliases": ["..."] }]

Entries to clean:
{{entries}}
]]

GeminiClient.DEFAULT_CLEANUP_PROMPT = [[
You are cleaning up a character profile from a book. Some text fields contain repeated or redundant information because they were built up incrementally (e.g. "brave; brave" or "tall, dark hair; tall with dark hair").

Clean up each text field:
- Remove repetitions and redundant phrases
- Combine fragmented observations into a single fluent description
- If personality reads like a list of events or actions, rewrite it as a trait summary (e.g. "attacked the guard when cornered; fought to protect his sister" → "fiercely protective and willing to use violence when threatened")
- Do not add new information not present in the original fields
- For identity_tags: consolidate similar tags (e.g. merge "Soldier" and "Infantryman" into the more specific one). Remove duplicates.
- For defining_moments: deduplicate. Ensure each entry reads as a permanent state change, not a scene description. Do not rephrase — preserve original wording for distinct events.
- For motivation: if multiple motivations have accumulated, synthesise into one coherent statement.
- For relationships: normalize each entry to "Name (relationship type)" format. E.g. "Brother to Amanda" → "Amanda (brother)", "Amanda — Sister" → "Amanda (sister)", "rival of Kira" → "Kira (rival)". Deduplicate after normalizing. Use the most complete known name for each person.
- For name and aliases: if a more complete name appears in the aliases array (e.g. name is "Luc" but aliases contains "Luc Holdfast"), promote the fuller name to the primary name field and move the shorter name into aliases. Only promote if the aliased version is clearly more complete, not merely a title variant (e.g. do not promote "Warden Mandl" over "Mandl").
- For role: valid values are "protagonist", "antagonist", or "supporting". If the existing role is one of these, preserve it. If it is blank or unclear, default to "supporting".

Return ONLY a valid JSON object (no markdown, no code fences) with exactly these keys:
{
  "name": "...",
  "aliases": ["..."],
  "identity_tags": ["..."],
  "physical_description": "...",
  "personality": "...",
  "motivation": "...",
  "defining_moments": ["..."],
  "relationships": ["..."],
  "role": "..."
}

Character profile to clean:
{{character}}
]]

function GeminiClient:new(api_key)
    return setmetatable({ api_key = api_key }, self)
end

-- Build the extraction prompt
function GeminiClient:buildPrompt(page_text, skip_names, existing_characters, template, book_context)
    local skip_str = "none"
    if skip_names and #skip_names > 0 then
        skip_str = table.concat(skip_names, ", ")
    end

    local existing_str = "none"
    if existing_characters and #existing_characters > 0 then
        existing_str = json.encode(existing_characters)
    end

    local ctx_str = (book_context and book_context ~= "") and book_context or "none"

    local tmpl = template or GeminiClient.DEFAULT_EXTRACTION_PROMPT
    tmpl = sub(tmpl, "{{existing}}",     existing_str)
    tmpl = sub(tmpl, "{{skip}}",         skip_str)
    tmpl = sub(tmpl, "{{text}}",         page_text)
    tmpl = sub(tmpl, "{{book_context}}", ctx_str)
    return tmpl
end

-- Strip markdown code fences Gemini sometimes adds despite instructions
local function stripCodeFences(text)
    -- Remove ```json ... ``` or ``` ... ```
    local stripped = text:match("```json%s*(.-)%s*```")
        or text:match("```%s*(.-)%s*```")
        or text
    return stripped:match("^%s*(.-)%s*$")  -- trim whitespace
end

-- Parse a raw Gemini response body string; returns characters, nil, usage, book_context or nil, err
function GeminiClient:_parseResponseBody(raw)
    local parsed, _, err = json.decode(raw)
    if not parsed then
        return nil, "Failed to parse Gemini response: " .. tostring(err)
    end

    if type(parsed) == "table" and parsed.error then
        local status_code = parsed.error.code or "?"
        local detail = parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status_code) .. "): " .. detail
    end

    -- Navigate to the text content
    -- Structure: parsed.candidates[1].content.parts[1].text
    local text
    if parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1] then
        text = parsed.candidates[1].content.parts[1].text
    end

    if not text or text == "" then
        local reason = parsed.candidates
            and parsed.candidates[1]
            and parsed.candidates[1].finishReason
            or "unknown"
        return nil, "Gemini returned no text content. Finish reason: " .. reason
    end

    text = stripCodeFences(text)

    local result, _, jerr = json.decode(text)
    if not result then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end

    -- Support both new object format {characters, book_context} and legacy bare array
    local characters, book_context
    if type(result) == "table" and result.characters then
        characters   = result.characters
        book_context = result.book_context
    elseif type(result) == "table" and not result.characters then
        characters = result
    else
        return nil, "Expected a JSON object or array, got: " .. type(result)
    end

    if type(characters) ~= "table" then
        characters = {}
    end

    return characters, nil, extractUsage(parsed), book_context
end

-- Write request JSON to path for async curl use; returns true or nil, err
function GeminiClient:buildRequestFile(path, page_text, skip_names, existing_characters, template, book_context)
    local prompt = self:buildPrompt(page_text, skip_names, existing_characters, template, book_context)
    local request_body = json.encode({
        contents = {
            { parts = { { text = prompt } } }
        },
        generationConfig = {
            temperature     = 0.2,
            maxOutputTokens = 8192,
        }
    })
    local f = io.open(path, "w")
    if not f then return nil, "Could not write request file: " .. path end
    f:write(request_body)
    f:close()
    return true
end

-- Read and parse a curl response file; returns characters, nil, usage, book_context or nil, err
function GeminiClient:parseResponseFile(path)
    local f = io.open(path, "r")
    if not f then return nil, "Response file not found: " .. path end
    local raw = f:read("*a")
    f:close()
    return self:_parseResponseBody(raw)
end

-- Write a codex enrichment request body to a file for async dispatch.
function GeminiClient:buildCodexRequestFile(path, page_text, entries, prompt_template)
    local tmpl   = prompt_template or GeminiClient.DEFAULT_CODEX_UPDATE_PROMPT
    local prompt = sub(tmpl, "{{entries}}", json.encode(entries))
    prompt       = sub(prompt, "{{text}}", page_text)
    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.2, maxOutputTokens = 8192 },
    })
    local f = io.open(path, "w")
    if not f then return nil, "Could not write codex request file: " .. path end
    f:write(request_body)
    f:close()
    return true
end

-- Read and parse a codex enrichment response file; returns entries, nil, usage or nil, err
function GeminiClient:parseCodexResponseFile(path)
    local f = io.open(path, "r")
    if not f then return nil, "Response file not found: " .. path end
    local raw = f:read("*a")
    f:close()

    local parsed, _, err = json.decode(raw)
    if not parsed then
        return nil, "Failed to parse Gemini response: " .. tostring(err)
    end
    if type(parsed) == "table" and parsed.error then
        local detail = parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(parsed.error.code or "?") .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text. Finish reason: " .. reason
    end

    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(result) ~= "table" then
        return nil, "Expected a JSON array, got: " .. type(result)
    end
    return result, nil, extractUsage(parsed)
end

-- Write a codex create request body to a file for async dispatch.
function GeminiClient:buildCodexCreateRequestFile(path, page_text, name, prompt_template)
    local tmpl   = prompt_template or GeminiClient.DEFAULT_CODEX_CREATE_PROMPT
    local prompt = sub(tmpl, "{{name}}", name)
    prompt       = sub(prompt, "{{text}}", page_text)
    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.2, maxOutputTokens = 4096 },
    })
    local f = io.open(path, "w")
    if not f then return nil, "Could not write codex create request file: " .. path end
    f:write(request_body)
    f:close()
    return true
end

-- Read and parse a codex create response file; returns entry, nil, usage or nil, err
function GeminiClient:parseCodexCreateResponseFile(path)
    local f = io.open(path, "r")
    if not f then return nil, "Response file not found: " .. path end
    local raw = f:read("*a")
    f:close()

    local parsed, _, err = json.decode(raw)
    if not parsed then
        return nil, "Failed to parse Gemini response: " .. tostring(err)
    end
    if type(parsed) == "table" and parsed.error then
        local detail = parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(parsed.error.code or "?") .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text. Finish reason: " .. reason
    end

    text = stripCodeFences(text)
    local entry, _, jerr = json.decode(text)
    if not entry then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(entry) ~= "table" or type(entry.name) ~= "string" then
        return nil, "Expected a JSON object with a name field"
    end
    return entry, nil, extractUsage(parsed)
end

-- Returns the full extraction API URL with key for use in async curl commands
function GeminiClient:asyncExtractUrl()
    return API_BASE .. "?key=" .. self.api_key
end

-- Send request to Gemini and return parsed character list or error
function GeminiClient:extractCharacters(page_text, skip_names, existing_characters, extraction_prompt, book_context)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set. Please configure it in the plugin settings."
    end

    local prompt = self:buildPrompt(page_text, skip_names, existing_characters, extraction_prompt, book_context)

    -- Gemini request body
    local request_body = json.encode({
        contents = {
            {
                parts = {
                    { text = prompt }
                }
            }
        },
        generationConfig = {
            temperature     = 0.2,
            maxOutputTokens = 8192,
        }
    })

    local response_body = {}
    local url = API_BASE .. "?key=" .. self.api_key

    local ok, status = https.request({
        url    = url,
        method = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then
        return nil, "Network error: " .. tostring(status)
    end

    if status ~= 200 then
        -- Try to extract a helpful error message from the response body
        local raw = table.concat(response_body)
        local parsed = json.decode(raw)
        local detail = parsed and parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    return self:_parseResponseBody(table.concat(response_body))
end

-- Re-analyze a single known character against a new page passage
function GeminiClient:reanalyzeCharacter(page_text, char, reanalyze_prompt)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set. Please configure it in the plugin settings."
    end

    local tmpl = reanalyze_prompt or GeminiClient.DEFAULT_REANALYZE_PROMPT
    local prompt = sub(tmpl, "{{character}}", json.encode(char))
    prompt = sub(prompt, "{{text}}", page_text)

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.2, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url    = API_BASE .. "?key=" .. self.api_key,
        method = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end

    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse Gemini response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text. Finish reason: " .. reason
    end

    text = stripCodeFences(text)
    local characters, _, jerr = json.decode(text)
    if not characters then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(characters) ~= "table" then
        return nil, "Expected a JSON array, got: " .. type(characters)
    end
    return characters, nil, extractUsage(parsed)
end

-- Clean up multiple character profiles in one call
function GeminiClient:cleanCharacters(characters)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not characters or #characters == 0 then return {}, nil end

    local prompt = string.format([[
You are cleaning up character profiles from a book. Some text fields contain repeated or redundant information because they were built up incrementally (e.g. "brave; brave" or "tall, dark hair; tall with dark hair").

For each character, clean up the text fields:
- Remove repetitions and redundant phrases
- Combine fragmented observations into fluent descriptions
- If personality reads like a list of actions or events, rewrite it as a trait summary (e.g. "attacked the guard when cornered; fought to protect his sister" → "fiercely protective and willing to use violence when threatened")
- Do not add new information not present in the original fields
- For identity_tags: consolidate similar tags (e.g. merge "Soldier" and "Infantryman" into the more specific one). Remove duplicates.
- For defining_moments: deduplicate. Ensure each entry reads as a permanent state change, not a scene description. Do not rephrase — preserve original wording for distinct events.
- For motivation: if multiple motivations have accumulated, synthesise into one coherent statement.
- For relationships: normalize each entry to "Name (relationship type)" format. E.g. "Brother to Amanda" → "Amanda (brother)", "Amanda — Sister" → "Amanda (sister)", "rival of Kira" → "Kira (rival)". Deduplicate after normalizing. Use the most complete known name for each person.
- For name and aliases: if a more complete name appears in the aliases array (e.g. name is "Luc" but aliases contains "Luc Holdfast"), promote the fuller name to the primary name field and move the shorter name into aliases. Only promote if the aliased version is clearly more complete, not merely a title variant (e.g. do not promote "Warden Mandl" over "Mandl").
- For role: valid values are "protagonist", "antagonist", or "supporting". If the existing role is one of these, preserve it. If it is blank or unclear, default to "supporting".

Return ONLY a valid JSON array (no markdown, no code fences) with the same number of characters in the same order. Each element must have exactly these keys:
[{ "name": "...", "aliases": ["..."], "identity_tags": ["..."], "physical_description": "...", "personality": "...", "motivation": "...", "defining_moments": ["..."], "relationships": ["..."], "role": "..." }]

Character profiles to clean:
%s
]], json.encode(characters))

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.1, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url     = API_BASE .. "?key=" .. self.api_key,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end
    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end
    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then return nil, "Gemini returned no text" end
    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, extractUsage(parsed)
end

function GeminiClient:cleanCodexEntries(entries, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not entries or #entries == 0 then return {}, nil end

    local tmpl   = prompt_template or GeminiClient.DEFAULT_CODEX_CLEANUP_PROMPT
    local prompt = sub(tmpl, "{{entries}}", json.encode(entries))

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.1, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url     = API_BASE .. "?key=" .. self.api_key,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end

    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then return nil, "Gemini returned no text" end

    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    if type(result) ~= "table" then return nil, "Expected a JSON array" end
    return result, nil, extractUsage(parsed)
end

GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT = [[
You are analyzing a list of character profiles from a book to find characters that are almost certainly the same person referred to by different names, titles, or aliases.

Rules:
- Only suggest a merge when you are HIGHLY CONFIDENT the two characters are the same person. There must be strong supporting evidence across multiple fields (e.g. matching physical description AND matching relationships AND names that are clearly variants of each other).
- Do NOT suggest merges based on name similarity alone.
- Do NOT suggest merges based on a single shared trait.
- Prefer to keep the most complete or most commonly used name as "keep".
- A character can only appear in one merge group.
- If you find no high-confidence merges, return an empty array.

Return ONLY a valid JSON array (no markdown, no code fences). Each element must have exactly these keys:
[{ "keep": "primary name to keep", "absorb": ["name to merge in", ...], "reason": "one-sentence explanation of why these are the same person" }]

Character profiles:
{{characters}}
]]

-- Detect groups of characters that are almost certainly the same person
-- Returns: array of {keep, absorb, reason} or nil, err, usage
function GeminiClient:detectMergeGroups(characters, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not characters or #characters < 2 then return {}, nil end

    local tmpl = prompt_template or GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT
    local prompt = sub(tmpl, "{{characters}}", json.encode(characters))

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.1, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url     = API_BASE .. "?key=" .. self.api_key,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end
    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end
    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then return nil, "Gemini returned no text" end
    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, extractUsage(parsed)
end

GeminiClient.DEFAULT_UNNAMED_MATCH_PROMPT = [[
You are given two lists of character profiles from the same book.

UNNAMED characters (names like "Unnamed Girl", "Unnamed Soldier") are characters whose names were not known when they were first encountered.
NAMED characters are characters whose names are known.

Your task: determine whether any unnamed character is almost certainly the same person as a named character, based on physical description, personality, relationships, or other profile details.

Rules:
- Only suggest a match when you are HIGHLY CONFIDENT. Physical description must be consistent — do not match on personality alone.
- Never match two unnamed characters together.
- A character can only appear in one match.
- If no high-confidence matches exist, return an empty array.

Return ONLY a valid JSON array (no markdown, no code fences). Each element must have exactly these keys:
[{ "keep": "the named character's name", "absorb": ["the unnamed character's name"], "reason": "one-sentence explanation" }]

Unnamed characters:
{{unnamed}}

Named characters:
{{named}}
]]

-- Detect which unnamed characters match named characters by profile similarity
-- Returns: array of {keep, absorb, reason} or nil, err, usage
function GeminiClient:detectUnnamedMatches(unnamed_chars, named_chars, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not unnamed_chars or #unnamed_chars == 0 then return {}, nil end
    if not named_chars   or #named_chars   == 0 then return {}, nil end

    local tmpl   = prompt_template or GeminiClient.DEFAULT_UNNAMED_MATCH_PROMPT
    local prompt = sub(tmpl, "{{unnamed}}", json.encode(unnamed_chars))
    prompt       = sub(prompt, "{{named}}",   json.encode(named_chars))

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.1, maxOutputTokens = 4096 },
    })

    local response_body = {}
    local ok, status = https.request({
        url     = API_BASE .. "?key=" .. self.api_key,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end
    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end
    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then return nil, "Gemini returned no text" end
    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, extractUsage(parsed)
end

-- Clean up a character profile: remove duplicate/redundant text in all fields
function GeminiClient:cleanCharacter(character, cleanup_prompt)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end

    local tmpl = cleanup_prompt or GeminiClient.DEFAULT_CLEANUP_PROMPT
    local prompt = sub(tmpl, "{{character}}", json.encode(character))

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.1, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url     = API_BASE .. "?key=" .. self.api_key,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end

    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then return nil, "Gemini returned no text" end

    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, extractUsage(parsed)
end

GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT = [[
You are analyzing a cast of characters from a novel and their relationships to each other.

Below is a list of character profiles in JSON. Read all of them, then produce a clean text-based relationship map.

Rules:
- List every character by name.
- Under each character, indent and list their significant connections to OTHER named characters in this list.
- Use a short relationship label (e.g. "wife of", "rival of", "mentor to", "allied with").
- If two characters share a mutual relationship, show it from both sides.
- Omit characters who have no connections to anyone else in the list.
- Do not add any introduction, explanation, or conclusion — output only the map.

Format exactly like this example:
Character Name
  → Other Character — relationship label
  → Another Character — relationship label

Character profiles:
{{characters}}
]]

-- Build a text relationship map from all characters using Gemini
function GeminiClient:buildRelationshipMap(characters, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set. Please configure it in the plugin settings."
    end
    if not characters or #characters == 0 then
        return nil, "No characters to map."
    end

    local tmpl   = prompt_template or GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT
    local prompt = sub(tmpl, "{{characters}}", json.encode(characters))

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.3, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url    = API_BASE .. "?key=" .. self.api_key,
        method = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end

    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse Gemini response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text. Finish reason: " .. reason
    end

    return text:match("^%s*(.-)%s*$"), nil, extractUsage(parsed)
end

-- ---------------------------------------------------------------------------
-- Codex
-- ---------------------------------------------------------------------------

GeminiClient.DEFAULT_CODEX_CREATE_PROMPT = [[
You are analyzing a passage from a novel or book.

A reader has flagged the following term for tracking: "{{name}}"

Your tasks:
1. Determine the entity type: place, faction, concept, object, or species.
2. Populate a codex entry based on the passage.

Rules:
- name: capitalize as a proper noun or world-specific term (e.g. "Resonance", "Transference", "The Iron Guild"). Use title case for multi-word names.
- description: what this thing is and how it works — a concise unified characterization. Do not enumerate every observed instance or use. Write as a general reference entry, not a scene summary.
- significance: its narrative role — why it matters to the story, what it changes for characters or the world. This is distinct from description. Leave empty string if not clearly established.
- known_connections: use actual character names from context, never role descriptors like "protagonist", "subject", or "narrator". Format each entry as "Name (relationship)" — e.g. "Kira (wielder)", "The Empire (governing body)", "Allomancy (related magic system)", "Lord Vance (founder)". One entry per named entity. Empty array if none found.
- aliases: alternate names, abbreviations, and derived word forms found in the passage. Include practitioner titles, adjective forms, and plural forms (e.g. for "Vivimancy": "vivimancer", "vivimancers", "vivimantic"). Empty array if none found.
- first_appearance_quote: a short verbatim quote from the passage where this term first appears.
- If the passage doesn't contain enough information to meaningfully describe this term, return just the type and a one-sentence description. Do not fabricate details.

Return ONLY a valid JSON object (no markdown, no code fences, no explanation):
{
  "name": "{{name}}",
  "type": "place or faction or concept or object or species",
  "description": "...",
  "significance": "...",
  "known_connections": ["Name (relationship) — one entry per named entity"],
  "aliases": ["..."],
  "first_appearance_quote": "..."
}

Passage:
---
{{text}}
---
]]

GeminiClient.DEFAULT_CODEX_UPDATE_PROMPT = [[
You are updating codex entries for a novel based on a new passage.

The entries below are world-building elements already tracked by the reader.

For each entry that appears in this passage:
- Rewrite description as a fresh unified synthesis incorporating the existing value and any new information from this passage. Never append — always rewrite as one coherent general characterization. Do not enumerate every observed instance or use; synthesize into a general description of what the thing is and how it works.
- Update significance only if the passage meaningfully changes or clarifies its narrative role; otherwise preserve unchanged.
- Extend known_connections with any new ones found in this passage; never duplicate existing entries. Use actual character names from context, never role descriptors like "protagonist" or "subject". Format each as "Name (relationship)" — e.g. "Kira (wielder)", "The Empire (governing body)", "Allomancy (related magic system)". Normalize any existing entries that don't follow this format.
- Extend aliases with any new ones found, including newly encountered derived word forms. Never duplicate.
- Preserve exactly: name, type, first_appearance_quote.

If an entry does not appear in this passage, omit it from the results entirely.
If no entries appear at all, return an empty array: []

Return ONLY a valid JSON array (no markdown, no code fences) containing only the entries that appeared in the passage:
[
  {
    "name": "...",
    "type": "place or faction or concept or object or species or unknown",
    "description": "...",
    "significance": "...",
    "known_connections": ["Name (relationship) — one entry per named entity"],
    "aliases": ["..."],
    "first_appearance_quote": "..."
  }
]

Existing entries to check:
{{entries}}

Passage:
---
{{text}}
---
]]

-- Create a new codex entry from a highlighted term.
-- Returns: entry table or nil, err, usage
function GeminiClient:createCodexEntry(page_text, name, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set. Please configure it in the plugin settings."
    end

    local tmpl   = prompt_template or GeminiClient.DEFAULT_CODEX_CREATE_PROMPT
    local prompt = sub(tmpl, "{{name}}", name)
    prompt       = sub(prompt, "{{text}}", page_text)

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.2, maxOutputTokens = 4096 },
    })

    local response_body = {}
    local ok, status = https.request({
        url    = API_BASE .. "?key=" .. self.api_key,
        method = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end

    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse Gemini response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text. Finish reason: " .. reason
    end

    text = stripCodeFences(text)
    local entry, _, jerr = json.decode(text)
    if not entry then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(entry) ~= "table" or type(entry.name) ~= "string" then
        return nil, "Expected a JSON object with a name field"
    end
    return entry, nil, extractUsage(parsed)
end

-- Enrich a batch of existing codex entries against a page passage.
-- Returns: array of updated entries (only those found in the passage), nil, usage
-- or nil, err
function GeminiClient:enrichCodexEntries(page_text, entries, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set. Please configure it in the plugin settings."
    end
    if not entries or #entries == 0 then return {}, nil end

    local tmpl   = prompt_template or GeminiClient.DEFAULT_CODEX_UPDATE_PROMPT
    local prompt = sub(tmpl, "{{entries}}", json.encode(entries))
    prompt       = sub(prompt, "{{text}}", page_text)

    local request_body = json.encode({
        contents = {{ parts = {{ text = prompt }} }},
        generationConfig = { temperature = 0.2, maxOutputTokens = 8192 },
    })

    local response_body = {}
    local ok, status = https.request({
        url    = API_BASE .. "?key=" .. self.api_key,
        method = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink   = ltn12.sink.table(response_body),
    })

    if not ok then return nil, "Network error: " .. tostring(status) end

    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then return nil, "Failed to parse Gemini response" end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end

    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text. Finish reason: " .. reason
    end

    text = stripCodeFences(text)
    local result, _, jerr = json.decode(text)
    if not result then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(result) ~= "table" then
        return nil, "Expected a JSON array, got: " .. type(result)
    end
    return result, nil, extractUsage(parsed)
end

-- Fetch model metadata from the Gemini models endpoint
function GeminiClient:fetchModelInfo()
    local url = API_MODELS_BASE .. MODEL .. "?key=" .. self.api_key
    local response_body = {}
    local ok, status = https.request({
        url     = url,
        method  = "GET",
        headers = { ["Content-Type"] = "application/json" },
        sink    = ltn12.sink.table(response_body),
    })
    if not ok then
        return nil, "Network error: " .. tostring(status)
    end
    local raw    = table.concat(response_body)
    local parsed = json.decode(raw)
    if not parsed then
        return nil, "Failed to parse response"
    end
    if status ~= 200 then
        local detail = parsed.error and parsed.error.message or raw:sub(1, 200)
        return nil, "API error (HTTP " .. tostring(status) .. "): " .. detail
    end
    return parsed, nil
end

return GeminiClient
