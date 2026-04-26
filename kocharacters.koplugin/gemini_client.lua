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
   - Preserve exactly: name, aliases, occupation, role, relationships, first_appearance_quote, identity_tags, defining_moments. These fields are additive — you may add new values if the passage reveals them, but never remove, shorten, or replace values that are already set. A previously blank field may be filled if the passage establishes information for it. A character behaving differently in this passage is not a reason to remove prior aliases, tags, or relationships.
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
- For book_context: start from the current known context ("{{book_context}}") and expand it with anything the passage reveals about genre, setting, country/region, or era. Write as 2-3 sentences. If the passage adds nothing new, return it unchanged. Leave as empty string only if nothing at all is known.
- For name: use the most complete known name as the primary name. If a fuller name is established in this passage for a character currently known by a short name (e.g. "Sam" is confirmed to be "Sam Carter"), use the full name and put the short name in aliases.
- For personality: rewrite as a single unified description of stable character traits — incorporate the existing description and any new observations from this passage into one coherent summary. Do NOT append sentences to the existing text. Do NOT list events or actions.
- For physical_description: rewrite as a single unified description incorporating existing and new explicit appearance details only. Do not infer appearance from actions. If the passage contains no new explicit appearance details, copy physical_description unchanged from the existing profile.
- Never append raw actions or scene summaries to any field. Every field should read like a character description, not a plot summary.
- Never use time-relative words like "currently", "now", or "at this point" in any field — these are signs that scene state is being recorded as character trait.
- For identity_tags: capture core "what they are" markers — faction membership, social class, formal status, and demonstrated abilities. In hard magic systems, named ability classifications belong here ("Mistborn", "Feralchemist"). In any setting, only include abilities the text explicitly establishes or acknowledges — never infer from personality. Update if the passage reveals a new identity (e.g. a secret role is unmasked, a faction is joined or left). Do not duplicate occupation.
- For motivation: infer what the character fundamentally wants or fears. This is stable — only update it if the passage reveals a new explicit goal, fear, or belief the character has never expressed before. A character reacting emotionally to events is not a motivation update. Write as a concise statement ("wants to avenge her brother's death", "fears becoming like her father"). Never write this as a plot summary. Fill only when there is textual evidence of a specific goal, fear, or belief — do not fabricate motivation from role alone. Use empty string if none is established.
- For occupation: use the character's formal role, title, or profession. If not explicitly stated, infer from context or established identity (e.g. if the text establishes someone is a paladin or a general, use that). Do not leave blank simply because identity_tags already captures the role.
- For defining_moments: only capture a "One-Way Door" event — one after which the character's status, body, or knowledge is permanently altered.
    Include: permanent injuries, social exile or promotion, discovering a plot-critical secret, joining or leaving a faction.
    Exclude: combat without consequence, travel, standard dialogue, temporary moods, recurring events.
  Each entry must be one sentence in past tense. Before adding a new entry, check whether the existing list already captures this category of event — if a similar type of event is already recorded, do not add a new entry; a second occurrence of the same event type is not a new One-Way Door. Only append if this is a genuinely distinct threshold not yet captured.
- For relationships: use the exact name as it appears in the existing profiles list above — not a shortened or alternate form. If an existing character is named "Amanda Clarke", write "Amanda Clarke (ally)", never "Amanda (ally)". Format each entry as "Name (relationship type)". Examples: "Amanda (sister)", "Lord Vance (employer)", "Kira (rival)", "The King (ally)". One entry per named person. Never write "Brother to Amanda" or "Amanda - Sister" style.
- For role: default to "supporting" rather than "unknown" unless there is a clear reason the character cannot be classified.

---
EXAMPLE — illustrative only; do not include this in your response:

Input passage:
The warden led Helena down a narrow infirmary corridor. A pale young woman in an orderly's apron looked up — her face disfigured by long deliberate scars running the length of each cheek. "Marino?" Her name was whispered so softly, it could have been a breeze. Helena recognised her: Grace, from the Resistance. She had done this to herself, Helena realised. Made herself ugly so they would not keep her.

Existing: [{"name":"Helena Marino","aliases":[],"identity_tags":["Prisoner","Resistance fighter","Vivimancer"],"occupation":"","first_appearance_quote":"Helena wondered sometimes if she still had eyes.","physical_description":"Frail and emaciated with matted black hair.","personality":"Disciplined and observant, she maintains defiant internal resolve despite profound trauma.","motivation":"Wants to survive her imprisonment and find a way to resist her captors.","defining_moments":["She was subjected to a forced surgical procedure that permanently suppressed her resonance."],"role":"protagonist","relationships":["Kaine Ferron (captor)"]}]

Skip: none

Correct output:
{
  "book_context": "Dark fantasy. An occupied city under a necromantic authoritarian regime.",
  "characters": [
    {
      "name": "Helena Marino",
      "aliases": [],
      "identity_tags": ["Prisoner","Resistance fighter","Vivimancer"],
      "occupation": "",
      "first_appearance_quote": "Helena wondered sometimes if she still had eyes.",
      "physical_description": "Frail and emaciated with matted black hair.",
      "personality": "Disciplined and observant, she maintains defiant internal resolve despite profound trauma.",
      "motivation": "Wants to survive her imprisonment and find a way to resist her captors.",
      "defining_moments": ["She was subjected to a forced surgical procedure that permanently suppressed her resonance."],
      "role": "protagonist",
      "relationships": ["Kaine Ferron (captor)", "Grace (former Resistance comrade)"]
    },
    {
      "name": "Grace",
      "aliases": [],
      "identity_tags": ["Resistance survivor", "Forced laborer"],
      "occupation": "Hospital orderly",
      "first_appearance_quote": "\"Marino?\" Her name was whispered so softly, it could have been a breeze.",
      "physical_description": "Pale with a youthful face disfigured by long, deliberate scars running the length of each cheek.",
      "personality": "Deeply traumatized and fearful, she exhibits a fierce survivalist pragmatism — willing to cause herself permanent harm to evade exploitation by the regime.",
      "motivation": "Wants to survive the regime's occupation while protecting herself from exploitation.",
      "defining_moments": ["She intentionally scarred her own face to avoid being kept by the Undying."],
      "role": "supporting",
      "relationships": ["Helena Marino (former Resistance comrade)"]
    }
  ]
}

Key points shown above:
- Grace's "Hospital orderly" is occupation; "Resistance survivor" and "Forced laborer" are identity_tags (social status under the regime) — never duplicate occupation in identity_tags.
- Grace's personality is a trait summary ("fearful", "survivalist pragmatism") — not events ("she scarred herself").
- Grace's defining_moment is a One-Way Door permanent change, one sentence, past tense.
- Helena is returned only because she appears in the passage; her profile is updated minimally (new relationship added, nothing else changed).
- Relationships use the full name from the existing profiles: "Helena Marino", not "Helena".
---

Return ONLY a valid JSON object with no markdown formatting, no code fences, no explanation, no extra text — just the raw JSON object with this exact structure:
{
  "book_context": "Genre, setting, country/region, and era — 2-3 sentences",
  "characters": [
    {
      "name": "Full name or best available name",
      "aliases": ["nickname", "title"],
      "identity_tags": ["Core faction, class, status, or demonstrated ability markers — e.g. 'Inquisition Member', 'Convicted Outlaw', 'Mistborn', 'Necromancer'. Distinct from occupation. Only include abilities the text explicitly establishes."],
      "occupation": "Job title, profession, or social role (e.g. blacksmith, governess, army captain) — fill from explicit text or established identity; empty string only if genuinely unknown",
      "first_appearance_quote": "A short verbatim quote from the text where they first appear",
      "physical_description": "A concise summary of their appearance based on explicit descriptions only, else empty string",
      "personality": "A concise summary of stable character traits inferred from their behaviour — written as description, not event log",
      "motivation": "What drives this character at their core — their deepest goal, fear, or belief. Fill only when textual evidence supports a specific inference; empty string if none.",
      "defining_moments": ["A One-Way Door event that permanently altered this character's status, body, or knowledge — one sentence, past tense. Only include if this passage contains one."],
      "role": "protagonist or antagonist or supporting",
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
- Preserve exactly: name, aliases, occupation, role, relationships, first_appearance_quote, identity_tags, defining_moments. These fields are additive — you may add new values if the passage reveals them, but never remove, shorten, or replace values that are already set. A previously blank field may be filled if the passage establishes information for it. A character behaving differently in this passage is not a reason to remove prior aliases, tags, or relationships.
- Rewrite as a fresh unified summary: personality, physical_description, motivation. Treat the existing value as input — incorporate it with any new observations into one coherent description. Never append sentences to the existing text.

Rules:
- For personality: rewrite as a single unified description of stable traits — incorporate the existing description and new observations into one coherent summary. Do NOT append. Never list events or actions.
- For physical_description: rewrite as a single unified description incorporating existing and new explicit appearance details only. No action-based inferences. If the passage contains no new explicit appearance details, copy physical_description unchanged from the existing profile.
- Never append raw actions or scene summaries to any field.
- Never use time-relative words like "currently", "now", or "at this point" in any field — these are signs that scene state is being recorded as character trait.
- For defining_moments: ask two questions: (1) Is this a "One-Way Door"? Is the character's status, body, or knowledge permanently altered? (2) Is this a genuinely novel category of event not yet captured in the existing entries? Only append if both answers are yes. If a similar type of event is already recorded, do not add a new entry — recurring instances of the same event type are not new One-Way Doors. Append only; never remove existing entries.
- For identity_tags: update if the passage reveals a new core identity (secret role, faction change, formal status change, or an explicitly established ability). In hard magic systems, named ability classifications belong here ("Mistborn", "Feralchemist"). Only include abilities the text explicitly establishes or acknowledges — never infer from personality. Otherwise preserve unchanged.
- For motivation: only update if the passage reveals a new explicit goal, fear, or belief the character has never expressed before. A character reacting emotionally to events is not a motivation update. Otherwise preserve unchanged.
- For relationships: use the exact name as it appears in the existing character profile above — not a shortened or alternate form. Format each entry as "Name (relationship type)". Examples: "Amanda (sister)", "Lord Vance (employer)". One entry per named person.
- For role: valid values are "protagonist", "antagonist", or "supporting". If the existing role is one of these, preserve it. Default to "supporting" rather than "unknown".

---
EXAMPLE — illustrative only; do not include this in your response:

Character to update:
{"name":"Helena Marino","aliases":[],"identity_tags":["Prisoner","Resistance fighter"],"occupation":"","first_appearance_quote":"Helena wondered sometimes if she still had eyes.","physical_description":"Frail and emaciated with matted black hair.","personality":"Disciplined and observant.","motivation":"Wants to survive her imprisonment.","defining_moments":["She was subjected to a forced surgical procedure that permanently suppressed her resonance."],"role":"protagonist","relationships":["Kaine Ferron (captor)"]}

Passage:
Helena moved through the crowded mess hall without drawing attention, cataloguing faces. She had learned from Kaine Ferron's sessions what it cost to be noticed — stillness was its own armour. Her collar-bones showed sharp above her prison shift. Warden Tane watched her from the doorway, expression flat.

Correct output:
[{"name":"Helena Marino","aliases":[],"identity_tags":["Prisoner","Resistance fighter"],"occupation":"","first_appearance_quote":"Helena wondered sometimes if she still had eyes.","physical_description":"Frail and emaciated with matted black hair; her collar-bones are prominently visible.","personality":"Disciplined and self-contained, she moves through dangerous spaces with deliberate invisibility — cataloguing people before allowing herself to react.","motivation":"Wants to survive her imprisonment.","defining_moments":["She was subjected to a forced surgical procedure that permanently suppressed her resonance."],"role":"protagonist","relationships":["Kaine Ferron (captor)","Warden Tane (guard)"]}]

Key points shown above:
- personality is a fresh unified rewrite, not an append — not "Disciplined and observant. She has learned to move without drawing attention."
- physical_description incorporates new explicit detail from the passage.
- motivation and defining_moments are unchanged — nothing in this passage warrants updating them.
- "Kaine Ferron" uses the exact name from the existing profile, not "Ferron" or "Kaine".
- Warden Tane is added as a new relationship using the name as it appears in the passage.
---

If this character does not appear in the passage at all, return an empty JSON array: []

Return ONLY a valid JSON array with no markdown formatting, no code fences, no explanation — just the raw JSON array containing the single updated character:
[
  {
    "name": "Full name or best available name",
    "aliases": ["nickname", "title"],
    "identity_tags": ["Core faction, class, status, or demonstrated ability markers"],
    "occupation": "Job title, profession, or social role (e.g. blacksmith, governess, army captain) — fill from explicit text or established identity; empty string only if genuinely unknown",
    "first_appearance_quote": "Keep existing quote unless a better one is found in this passage",
    "physical_description": "Merged appearance summary — explicit descriptions only",
    "personality": "Merged personality summary — stable traits inferred from behaviour, written as description not event log",
    "motivation": "What drives this character at their core — stable goal, fear, or belief. Fill only when textual evidence supports a specific inference; empty string if none.",
    "defining_moments": ["One-Way Door events that permanently altered this character — one sentence each, past tense"],
    "role": "protagonist or antagonist or supporting",
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
- name: apply Title Case (e.g. "Transference", "Animancer"). Preserve all-caps acronyms. Do not change proper nouns that are already correctly cased.
- description: remove repetitions, combine fragmented observations into one fluent paragraph. If it has grown into an exhaustive list of observed instances or uses, synthesize into a general characterization of what the thing is and how it works.
- significance: same — one coherent statement of narrative role. Must be distinct from description (not a restatement of what the thing does).
- known_connections: normalize to "Name (relationship)" format. Each character or entity must appear exactly once — if the same character appears with multiple roles, merge into one entry (e.g. "Lord Vance (employer, rival)"). Replace any role descriptors (e.g. "protagonist", "subject") with the character's actual name if it can be inferred from context.
- aliases: deduplicate, remove entries that are just alternate casings of the name

Return ONLY a valid JSON array (no markdown, no code fences) with the same number of entries in the same order. Each element must have exactly these keys:
[{ "name": "...", "type": "...", "description": "...", "significance": "...", "known_connections": ["..."], "aliases": ["..."] }]

---
EXAMPLE — illustrative only; do not include this in your response:

Input:
[{"name":"transference","type":"concept","description":"A vivimantic technique that moves pain or injury from one body to another.; Transference is when a vivimancer takes physical suffering experienced by one person and forces it into another subject. It has been used as an interrogation method. It is a vivimantic technique for moving sensations between subjects.","significance":"Used by regime interrogators to extract confessions.","known_connections":["Helena (subject)","Doctor Stroud (interrogator)","Doctor Stroud (practitioner)"],"aliases":["transferred","transferring"]}]

Correct output:
[{"name":"Transference","type":"concept","description":"A vivimantic technique that moves physical pain or injury from one body into another. It is used as an interrogation method, forcing a subject to experience sensations extracted from another person.","significance":"Used by regime interrogators to extract confessions and break prisoners.","known_connections":["Helena (subject)","Doctor Stroud (practitioner)"],"aliases":["transferred","transferring"]}]

Key points shown above:
- name promoted to Title Case.
- Three description fragments ("A vivimantic technique..."; "Transference is when..."; "It is a vivimantic technique...") merged into one coherent paragraph with no repeated ideas.
- Duplicate known_connections entry for Doctor Stroud collapsed into one canonical form.
---

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
- For defining_moments: consolidate entries that describe the same category of recurring event — if multiple entries cover the same type of action or experience, even if worded differently, merge them into one using the most complete phrasing. Then remove any remaining exact duplicates. Ensure each remaining entry reads as a permanent state change, not a scene description.
- For motivation: if multiple motivations have accumulated, synthesise into one coherent statement.
- For relationships: normalize each entry to "Name (relationship type)" format. E.g. "Brother to Amanda" → "Amanda (brother)", "Amanda — Sister" → "Amanda (sister)", "rival of Kira" → "Kira (rival)". Deduplicate after normalizing. Use the most complete known name for each person.
- For name and aliases: if a more complete name appears in the aliases array (e.g. name is "Sam" but aliases contains "Sam Carter"), promote the fuller name to the primary name field and move the shorter name into aliases. Only promote if the aliased version is clearly more complete, not merely a title variant (e.g. do not promote "Captain Vance" over "Vance").
- For occupation: preserve as-is. Replace placeholder text ("Not specified.", "Unknown", "N/A") with empty string.
- For role: valid values are "protagonist", "antagonist", or "supporting". If the existing role is one of these, preserve it. If it is blank or unclear, default to "supporting".

Return ONLY a valid JSON object (no markdown, no code fences) with exactly these keys:
{
  "name": "...",
  "aliases": ["..."],
  "occupation": "...",
  "identity_tags": ["..."],
  "physical_description": "...",
  "personality": "...",
  "motivation": "...",
  "defining_moments": ["..."],
  "relationships": ["..."],
  "role": "..."
}

---
EXAMPLE — illustrative only; do not include this in your response:

Input:
{"name":"Doctor Stroud","aliases":["Unnamed Interrogator"],"identity_tags":["Regime official","Regime Official","Vivimancer","Interrogator"],"occupation":"Doctor","physical_description":"A woman with a face marked by lines of stark tension, often seen in severe shadows.; She has a squarish face with impatiently pursed lips and blue eyes with deep creases between them; she wears a medical uniform.","personality":"A cold, authoritative, and sharp-tongued professional who maintains a ruthless, unempathetic demeanor focused entirely on the success of her interrogations.; Cold, clinical, and highly professional, she views human subjects as data points. She is prone to intellectual excitement when encountering anomalies, yet remains entirely ruthless in her application of vivimancy to extract information.","motivation":"To uncover the secrets hidden within Helena's mind for the regime.","defining_moments":[],"relationships":["Helena (interrogator)","Morrough (superior)"],"role":"antagonist"}

Correct output:
{"name":"Doctor Stroud","aliases":["Unnamed Interrogator"],"occupation":"Doctor","identity_tags":["Regime Official","Vivimancer","Interrogator"],"physical_description":"A woman with a squarish face, impatiently pursed lips, and blue eyes with deep creases; her expression carries an air of stark tension and she wears a medical uniform.","personality":"Cold, clinical, and authoritative, she views human subjects as data points and maintains a ruthless, unempathetic focus on results. She displays intellectual excitement when encountering anomalies but remains entirely merciless in her application of vivimancy.","motivation":"To uncover the secrets hidden within Helena's mind for the regime.","defining_moments":[],"relationships":["Helena (interrogator)","Morrough (superior)"],"role":"antagonist"}

Key points shown above:
- Semicolon-joined fragments ("...shadows.; She has...") are merged into one fluent sentence.
- Case-duplicate identity_tags ("Regime official" and "Regime Official") are collapsed into one canonical form.
- Personality: two overlapping semicolon-joined paragraphs merged into one coherent description with no repeated ideas.
---

Character profile to clean:
{{character}}
]]

function GeminiClient:new(api_key)
    return setmetatable({ api_key = api_key }, self)
end

-- Extract text content from a parsed Gemini response envelope; returns text or nil, err
local function extractCandidateText(parsed)
    local text = parsed.candidates
        and parsed.candidates[1]
        and parsed.candidates[1].content
        and parsed.candidates[1].content.parts
        and parsed.candidates[1].content.parts[1]
        and parsed.candidates[1].content.parts[1].text
    if not text or text == "" then
        local reason = parsed.candidates and parsed.candidates[1]
            and parsed.candidates[1].finishReason or "unknown"
        return nil, "Gemini returned no text content. Finish reason: " .. reason
    end
    return text
end

-- Strip markdown code fences Gemini sometimes adds despite instructions
local function stripCodeFences(text)
    -- Remove ```json ... ``` or ``` ... ```
    local stripped = text:match("```json%s*(.-)%s*```")
        or text:match("```%s*(.-)%s*```")
        or text
    return stripped:match("^%s*(.-)%s*$")  -- trim whitespace
end

-- Returns true if err is a transient API or network error worth retrying
function GeminiClient.isRetryableError(err)
    if type(err) ~= "string" then return false end
    return err:find("Network error") ~= nil
        or err:find("503")          ~= nil
        or err:find("429")          ~= nil
        or err:find("quota")        ~= nil
        or err:find("high demand")  ~= nil
        or err:find("overload")     ~= nil
end

-- POST prompt to Gemini; returns stripped candidate text, err, usage
function GeminiClient:_post(prompt, temperature, max_tokens)
    local request_body = json.encode({
        contents         = {{ parts = {{ text = prompt }} }},
        generationConfig = {
            temperature     = temperature or 0.2,
            maxOutputTokens = max_tokens  or 8192,
        },
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
    local text, err = extractCandidateText(parsed)
    if not text then return nil, err end
    return stripCodeFences(text), nil, extractUsage(parsed)
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

    local text, text_err = extractCandidateText(parsed)
    if not text then return nil, text_err end

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

    local text, text_err = extractCandidateText(parsed)
    if not text then return nil, text_err end
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

    local text, text_err = extractCandidateText(parsed)
    if not text then return nil, text_err end
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
    local text, err, usage = self:_post(prompt, 0.2, 8192)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    local characters, book_ctx
    if type(result) == "table" and result.characters then
        characters = result.characters
        book_ctx   = result.book_context
    elseif type(result) == "table" then
        characters = result
    else
        return nil, "Expected a JSON object or array, got: " .. type(result)
    end
    if type(characters) ~= "table" then characters = {} end
    return characters, nil, usage, book_ctx
end

-- Re-analyze a single known character against a new page passage
function GeminiClient:reanalyzeCharacter(page_text, char, reanalyze_prompt)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set. Please configure it in the plugin settings."
    end
    local tmpl   = reanalyze_prompt or GeminiClient.DEFAULT_REANALYZE_PROMPT
    local prompt = sub(tmpl, "{{character}}", json.encode(char))
    prompt       = sub(prompt, "{{text}}", page_text)
    local text, err, usage = self:_post(prompt, 0.2, 8192)
    if not text then return nil, err end
    local characters, _, jerr = json.decode(text)
    if not characters then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(characters) ~= "table" then
        return nil, "Expected a JSON array, got: " .. type(characters)
    end
    return characters, nil, usage
end

GeminiClient.DEFAULT_CHARACTERS_CLEANUP_PROMPT = [[
You are cleaning up character profiles from a book. Some text fields contain repeated or redundant information because they were built up incrementally (e.g. "brave; brave" or "tall, dark hair; tall with dark hair").

For each character, clean up the text fields:
- Remove repetitions and redundant phrases
- Combine fragmented observations into fluent descriptions
- If personality reads like a list of actions or events, rewrite it as a trait summary (e.g. "attacked the guard when cornered; fought to protect his sister" → "fiercely protective and willing to use violence when threatened")
- Do not add new information not present in the original fields
- For identity_tags: consolidate similar tags (e.g. merge "Soldier" and "Infantryman" into the more specific one). Remove duplicates.
- For defining_moments: consolidate entries that describe the same category of recurring event — if multiple entries cover the same type of action or experience, even if worded differently, merge them into one using the most complete phrasing. Then remove any remaining exact duplicates. Ensure each remaining entry reads as a permanent state change, not a scene description.
- For motivation: if multiple motivations have accumulated, synthesise into one coherent statement.
- For relationships: normalize each entry to "Name (relationship type)" format. E.g. "Brother to Amanda" → "Amanda (brother)", "Amanda — Sister" → "Amanda (sister)", "rival of Kira" → "Kira (rival)". Deduplicate after normalizing. Use the most complete known name for each person.
- For name and aliases: if a more complete name appears in the aliases array (e.g. name is "Sam" but aliases contains "Sam Carter"), promote the fuller name to the primary name field and move the shorter name into aliases. Only promote if the aliased version is clearly more complete, not merely a title variant (e.g. do not promote "Captain Vance" over "Vance").
- For occupation: preserve as-is. Replace placeholder text ("Not specified.", "Unknown", "N/A") with empty string.
- For role: valid values are "protagonist", "antagonist", or "supporting". If the existing role is one of these, preserve it. If it is blank or unclear, default to "supporting".

Return ONLY a valid JSON array (no markdown, no code fences) with the same number of characters in the same order. Each element must have exactly these keys:
[{ "name": "...", "aliases": ["..."], "occupation": "...", "identity_tags": ["..."], "physical_description": "...", "personality": "...", "motivation": "...", "defining_moments": ["..."], "relationships": ["..."], "role": "..." }]

---
EXAMPLE — illustrative only; do not include this in your response:

Input:
[{"name":"Doctor Stroud","aliases":["Unnamed Interrogator"],"identity_tags":["Regime official","Regime Official","Vivimancer","Interrogator"],"occupation":"Doctor","physical_description":"A woman with a face marked by lines of stark tension, often seen in severe shadows.; She has a squarish face with impatiently pursed lips and blue eyes with deep creases between them; she wears a medical uniform.","personality":"A cold, authoritative, and sharp-tongued professional who maintains a ruthless, unempathetic demeanor focused entirely on the success of her interrogations.; Cold, clinical, and highly professional, she views human subjects as data points. She is prone to intellectual excitement when encountering anomalies, yet remains entirely ruthless in her application of vivimancy to extract information.","motivation":"To uncover the secrets hidden within Helena's mind for the regime.","defining_moments":[],"relationships":["Helena (interrogator)","Morrough (superior)"],"role":"antagonist"}]

Correct output:
[{"name":"Doctor Stroud","aliases":["Unnamed Interrogator"],"occupation":"Doctor","identity_tags":["Regime Official","Vivimancer","Interrogator"],"physical_description":"A woman with a squarish face, impatiently pursed lips, and blue eyes with deep creases; her expression carries an air of stark tension and she wears a medical uniform.","personality":"Cold, clinical, and authoritative, she views human subjects as data points and maintains a ruthless, unempathetic focus on results. She displays intellectual excitement when encountering anomalies but remains entirely merciless in her application of vivimancy.","motivation":"To uncover the secrets hidden within Helena's mind for the regime.","defining_moments":[],"relationships":["Helena (interrogator)","Morrough (superior)"],"role":"antagonist"}]

Key points shown above:
- Semicolon-joined fragments ("...shadows.; She has...") are merged into one fluent sentence.
- Case-duplicate identity_tags ("Regime official" and "Regime Official") are collapsed into one canonical form.
- Personality: two overlapping semicolon-joined paragraphs merged into one coherent description with no repeated ideas.
- Output is a JSON array with exactly the same number of elements as the input, in the same order.
---

Character profiles to clean:
{{characters}}
]]

-- Clean up multiple character profiles in one call
function GeminiClient:cleanCharacters(characters, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not characters or #characters == 0 then return {}, nil end
    local tmpl   = prompt_template or GeminiClient.DEFAULT_CHARACTERS_CLEANUP_PROMPT
    local prompt = sub(tmpl, "{{characters}}", json.encode(characters))
    local text, err, usage = self:_post(prompt, 0.1, 8192)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, usage
end

function GeminiClient:cleanCodexEntries(entries, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not entries or #entries == 0 then return {}, nil end
    local tmpl   = prompt_template or GeminiClient.DEFAULT_CODEX_CLEANUP_PROMPT
    local prompt = sub(tmpl, "{{entries}}", json.encode(entries))
    local text, err, usage = self:_post(prompt, 0.1, 8192)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    if type(result) ~= "table" then return nil, "Expected a JSON array" end
    return result, nil, usage
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
    local tmpl   = prompt_template or GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT
    local prompt = sub(tmpl, "{{characters}}", json.encode(characters))
    local text, err, usage = self:_post(prompt, 0.1, 8192)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, usage
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
    prompt       = sub(prompt, "{{named}}",  json.encode(named_chars))
    local text, err, usage = self:_post(prompt, 0.1, 4096)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, usage
end

GeminiClient.DEFAULT_CROSS_REFERENCE_PROMPT = [[
You are reviewing character profiles from a book to find missing bidirectional information.

For each character, read their defining_moments and relationships for events or connections that involve another named character from the list. If Character A's profile records a significant event affecting Character B, but B's profile has no entry recording that same event from B's perspective, generate an addition for B.

Example of the gap to look for:
- Character A defining_moment: "He abandoned his original body and transferred his consciousness into the corpse of Character B."
- Character B has no defining_moment about this event.
- Correct addition: {"target": "Character B", "field": "defining_moments", "add": "His corpse was reanimated and inhabited by Character A's consciousness."}

More patterns to look for:
- A executed / imprisoned / surgically modified B → B has no entry for that event
- A lists B as a named relationship role (captor, victim, killer, etc.) but B has no corresponding entry for A
- A's defining_moment names B as directly involved but B's profile is silent on that event

Rules:
- Only add facts directly implied by existing profile data. Do not invent.
- Additions only — never remove or modify existing entries.
- For defining_moments: third-person, past tense, factual, same style as existing entries. Skip if the same fact is already covered in B even if worded differently.
- For relationships: "Name (description)" format. Skip if an equivalent entry already exists.
- Skip trivial or symmetric acquaintance-level relationships — focus on significant one-way-door events and named role relationships.
- If there are no meaningful gaps, return an empty array [].

Return ONLY a valid JSON array (no markdown, no code fences). Each element has exactly these keys:
{ "target": "name of character to update", "field": "defining_moments" or "relationships", "add": "string to add to that field's array" }

Character profiles:
{{characters}}
]]

-- Find asymmetric cross-references and return additions to apply to referenced characters.
-- Returns: array of {target, field, add} or nil, err, usage
function GeminiClient:propagateCrossReferences(characters, prompt_template)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    if not characters or #characters < 2 then return {}, nil end
    local tmpl   = prompt_template or GeminiClient.DEFAULT_CROSS_REFERENCE_PROMPT
    local prompt = sub(tmpl, "{{characters}}", json.encode(characters))
    local text, err, usage = self:_post(prompt, 0.1, 4096)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    if type(result) ~= "table" then return nil, "Expected a JSON array" end
    return result, nil, usage
end

-- Clean up a character profile: remove duplicate/redundant text in all fields
function GeminiClient:cleanCharacter(character, cleanup_prompt)
    if not self.api_key or self.api_key == "" then
        return nil, "API key is not set."
    end
    local tmpl   = cleanup_prompt or GeminiClient.DEFAULT_CLEANUP_PROMPT
    local prompt = sub(tmpl, "{{character}}", json.encode(character))
    local text, err, usage = self:_post(prompt, 0.1, 8192)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then return nil, "Invalid JSON: " .. tostring(jerr) end
    return result, nil, usage
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
    local text, err, usage = self:_post(prompt, 0.3, 8192)
    if not text then return nil, err end
    return text:match("^%s*(.-)%s*$"), nil, usage
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
- type: classify as — place (locations, regions, buildings), faction (organizations, groups, institutions), concept (abilities, systems, phenomena, abstract forces, and practitioner roles defined by what someone can do), object (physical items or artifacts), or species (beings biologically or fundamentally distinct from ordinary humans, e.g. reanimated dead, non-human creatures, magical constructs, fantasy races such as elves or dwarves, alien species). A term naming people by an ability they possess is concept, not species — even if the ability is innate or inherited.
- description: what this thing is and how it works — a concise unified characterization. Do not enumerate every observed instance or use. Write as a general reference entry, not a scene summary.
- significance: its narrative role — why it matters to the story, what it changes for characters or the world. This is distinct from description. Leave empty string if not clearly established.
- known_connections: use actual character names from context, never role descriptors like "protagonist", "subject", or "narrator". Format each entry as "Name (relationship)" — e.g. "Kira (wielder)", "The Empire (governing body)", "Allomancy (related magic system)", "Lord Vance (founder)". One entry per named entity. Empty array if none found.
- aliases: alternate names, abbreviations, and derived word forms found in the passage. Include practitioner titles, adjective forms, and plural forms (e.g. for "Vivimancy": "vivimancer", "vivimancers", "vivimantic"). Empty array if none found.
- first_appearance_quote: a short verbatim quote from the passage where this term first appears.
- If the passage doesn't contain enough information to meaningfully describe this term, return just the type and a one-sentence description. Do not fabricate details.

---
EXAMPLE — illustrative only; do not include this in your response:

Term flagged: "Vivimancy"

Passage:
"You have been selected for Transference," Doctor Stroud said, arranging her instruments with practiced efficiency. Vivimancy — the art of moving pain, memory, or sensation between living bodies — was the regime's preferred interrogation method. Its practitioners, vivimancers, were both feared and indispensable. Stroud herself had trained under the Undying before the occupation.

Correct output:
{"name":"Vivimancy","type":"concept","description":"A magical discipline that moves pain, memory, or sensation between living bodies. Practitioners are trained specialists deployed extensively as interrogators.","significance":"The regime's primary interrogation method, making vivimancers indispensable to its power structure.","known_connections":["Doctor Stroud (practitioner)","The Undying (training institution)"],"aliases":["vivimancer","vivimancers","vivimantic"],"first_appearance_quote":"Vivimancy — the art of moving pain, memory, or sensation between living bodies — was the regime's preferred interrogation method."}

Key points shown above:
- description is a general characterization of what vivimancy is, not a scene summary.
- significance is distinct from description — it states narrative role, not mechanism.
- known_connections uses actual names ("Doctor Stroud"), never role descriptors like "the protagonist" or "the subject".
- aliases captures all derived word forms found in the passage.
---

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
- Rewrite description as a reorganized synthesis: read the existing description and the passage, then write a new version that (1) integrates any genuinely new information from the passage, (2) groups related capabilities or properties thematically rather than in arrival order, and (3) merges or removes redundant sentences. Aim for the shortest version that still captures every distinct fact and capability — if the existing description is already comprehensive and the passage adds nothing new, condense and reorganize rather than expanding. Do not enumerate every observed instance; express specific instances as general capabilities.
- Update significance only if the passage meaningfully changes or clarifies its narrative role; otherwise preserve unchanged.
- Extend known_connections with any new ones found in this passage. Each character or entity must appear exactly once — if a character already listed gains a new role, update their existing entry to combine roles (e.g. "Lord Vance (employer, rival)") rather than adding a duplicate. Use actual character names from context, never role descriptors like "protagonist" or "subject". Format each as "Name (relationship)". Normalize any existing entries that don't follow this format.
- Extend aliases with any new ones found, including newly encountered derived word forms. Never duplicate.
- Preserve exactly: name, type, first_appearance_quote.

If an entry does not appear in this passage, omit it from the results entirely.
If no entries appear at all, return an empty array: []

---
EXAMPLE — illustrative only; do not include this in your response:

Existing entries:
[{"name":"Vivimancy","type":"concept","description":"A magical discipline that moves pain, memory, or sensation between living bodies. Practitioners are trained specialists deployed extensively as interrogators.","significance":"The regime's primary interrogation method.","known_connections":["Doctor Stroud (practitioner)"],"aliases":["vivimancer","vivimancers"],"first_appearance_quote":"Vivimancy — the art of moving pain, memory, or sensation between living bodies."}]

Passage:
Helena had not known vivimancy could transfer skill as well as suffering. That was what Morrough had done — taken ten years of a cellist's muscle memory and pressed it into her hands overnight. Vivimantic transference of ability was considered experimental even within the Academy.

Correct output:
[{"name":"Vivimancy","type":"concept","description":"A magical discipline that moves pain, memory, sensation, or learned physical skill between living bodies. Practitioners are trained specialists; more experimental applications include the transference of ability.","significance":"The regime's primary interrogation method, with experimental uses extending to skill transfer.","known_connections":["Doctor Stroud (practitioner)","Morrough (practitioner)","The Academy (governing institution)"],"aliases":["vivimancer","vivimancers","vivimantic"],"first_appearance_quote":"Vivimancy — the art of moving pain, memory, or sensation between living bodies."}]

Key points shown above:
- description is a fresh synthesis — not the old text with a sentence appended.
- significance updated to reflect new narrative scope revealed by this passage.
- known_connections extended with new entries; no duplicates.
- aliases extended with "vivimantic" found in this passage.
- first_appearance_quote preserved exactly.
---

Return ONLY a valid JSON array (no markdown, no code fences) containing only the entries that appeared in the passage:
[
  {
    "name": "...",
    "type": "place or faction or concept or object or species",
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
    local text, err, usage = self:_post(prompt, 0.2, 4096)
    if not text then return nil, err end
    local entry, _, jerr = json.decode(text)
    if not entry then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(entry) ~= "table" or type(entry.name) ~= "string" then
        return nil, "Expected a JSON object with a name field"
    end
    return entry, nil, usage
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
    local text, err, usage = self:_post(prompt, 0.2, 8192)
    if not text then return nil, err end
    local result, _, jerr = json.decode(text)
    if not result then
        return nil, "Gemini returned invalid JSON: " .. tostring(jerr) .. "\nRaw: " .. text:sub(1, 200)
    end
    if type(result) ~= "table" then
        return nil, "Expected a JSON array, got: " .. type(result)
    end
    return result, nil, usage
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
