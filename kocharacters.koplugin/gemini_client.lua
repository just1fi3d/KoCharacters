-- gemini_client.lua
-- Handles all communication with the Google Gemini API (free tier)
-- Model: gemini-1.5-flash — free at aistudio.google.com

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
2. Update the profiles of EXISTING characters (listed below) who appear in this passage — preserve all existing fields and enrich them with any new information found.

Existing character profiles to UPDATE (return updated profile only if they appear in this passage):
{{existing}}

Characters to SKIP entirely (do not return these):
{{skip}}

Rules:
- Only include characters who have a name (first name, last name, or title+name). Skip unnamed background figures.
- For existing characters: only return them if they actually appear in this passage. Preserve existing data and add/improve any fields.
- For new characters: only include if there is enough information to build a meaningful profile.
- If there is nothing to report, return an empty JSON array: []
- For personality: infer stable character traits (e.g. "cautious", "hot-tempered", "fiercely loyal") from how characters act and react. Do NOT list events or actions — synthesize what those reveal about who they are.
- For physical_description: summarise explicit appearance details only. Do not infer appearance from actions.
- Never append raw actions or scene summaries to any field. Every field should read like a character description, not a plot summary.
- For identity_tags: capture core "what they are" markers — faction membership, social class, formal status, and demonstrated abilities. In hard magic systems, named ability classifications belong here ("Mistborn", "Feralchemist"). In any setting, only include abilities the text explicitly establishes or acknowledges — never infer from personality. Update if the passage reveals a new identity (e.g. a secret role is unmasked, a faction is joined or left). Do not duplicate occupation.
- For motivation: infer what the character fundamentally wants or fears. This is stable — only update it if the passage meaningfully changes or clarifies it. Write as a concise statement ("wants to avenge her brother's death", "fears becoming like her father"). Never write this as a plot summary.
- For defining_moments: only capture a "One-Way Door" event — one after which the character's status, body, or knowledge is permanently altered.
    Include: permanent injuries, social exile or promotion, discovering a plot-critical secret, joining or leaving a faction.
    Exclude: combat without consequence, travel, standard dialogue, temporary moods.
  Each entry must be one sentence in past tense. Append new entries; never duplicate existing ones.

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
      "relationships": ["Relationship to other characters if mentioned"]
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

Read the passage below and enrich the character's profile with any new information. For personality and physical_description, merge new observations into the existing description — synthesising a coherent summary, not appending new events. Preserve all existing data; only add or improve.

Rules:
- For personality: infer stable traits from how the character acts and reacts. Write a synthesised description ("reckless and fiercely loyal"), never a list of actions ("jumped off a bridge to save his friend").
- For physical_description: merge explicit appearance details only. No action-based inferences.
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
    "relationships": ["Updated relationship list"]
  }
]

Passage:
---
{{text}}
---
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

Return ONLY a valid JSON object (no markdown, no code fences) with exactly these keys:
{
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

    -- Parse the outer Gemini response envelope
    local raw = table.concat(response_body)
    local parsed, _, err = json.decode(raw)
    if not parsed then
        return nil, "Failed to parse Gemini response: " .. tostring(err)
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
        -- Check for safety blocks or other finish reasons
        local reason = parsed.candidates
            and parsed.candidates[1]
            and parsed.candidates[1].finishReason
            or "unknown"
        return nil, "Gemini returned no text content. Finish reason: " .. reason
    end

    -- Strip any accidental code fences
    text = stripCodeFences(text)

    -- Parse the JSON object Gemini returned
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
        -- bare array (legacy or fallback)
        characters = result
    else
        return nil, "Expected a JSON object or array, got: " .. type(result)
    end

    if type(characters) ~= "table" then
        characters = {}
    end

    return characters, nil, extractUsage(parsed), book_context
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

Return ONLY a valid JSON array (no markdown, no code fences) with the same number of characters in the same order. Each element must have exactly these keys:
[{ "name": "...", "identity_tags": ["..."], "physical_description": "...", "personality": "...", "motivation": "...", "defining_moments": ["..."], "relationships": ["..."], "role": "..." }]

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
