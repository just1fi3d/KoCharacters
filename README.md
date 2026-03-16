# KoCharacters — KOReader Plugin

Automatically extract, track, and enrich character profiles from your books using the **Google Gemini AI API** (free tier). Runs on KOReader on Kindle and other supported devices.

---

## How to get a free Gemini API key

1. Go to **aistudio.google.com** and sign in with your Google account
2. Click **"Get API key"** in the left sidebar
3. Click **"Create API key"** — choose "Create API key in new project"
4. Copy the key (it starts with `AIza…`)
5. That's it — no credit card required, free tier gives 500 requests/day and 1M tokens/day

---

## Installation

1. Copy the `kocharacters.koplugin/` folder into your KOReader `plugins/` directory
2. Restart KOReader
3. Open any book, tap the menu → **KoCharacters** → **Settings**
4. Paste your Gemini API key and save

---

## Menu overview

All actions live under the reader menu → **KoCharacters**:

| Menu item | What it does |
|---|---|
| **Extract characters from this page** | Sends the current page text to Gemini and saves any characters found or updated |
| **Scan current chapter** | Scans every page in the current chapter, 4 pages per Gemini call |
| **Scan specific chapter…** | Shows a list of all chapters (with scan status) so you can pick one to scan |
| **View saved characters** | Browse the full character list; tap a name to see their profile, edit fields, or unlock spoilers |
| **Re-analyze character…** | Pick a character and re-run Gemini against the current page to enrich their profile |
| **View relationship map** | Gemini reads all saved profiles and produces a text relationship map |
| **Cleanup all characters** | Batch-deduplicates redundant text in all character profiles via Gemini |
| **Export character list** | Writes a plain `.txt` file to `<koreader_data>/kocharacters/` |
| **Settings** | Configure API key, auto-extract, scan indicator, spoiler protection, and prompts |

---

## How it works

### Character extraction

1. The plugin reads the current page text by parsing the epub directly via `unzip` — this is the most reliable method on the supported KOReader build
2. It loads all already-known characters for this book from the local JSON database
3. Known characters whose name or alias appears in the page text are passed to Gemini as **full profiles to update**; the rest are passed as a **skip list**
4. Gemini returns a JSON array of new and updated character profiles, inferring personality traits and appearance from the text
5. New characters are inserted into the database; existing characters are fully updated in-place with enriched information
6. Scanned pages are tracked in a sidecar file so they are never re-processed

### Incremental enrichment

Every time a known character appears on a scanned page, their full current profile is sent to Gemini alongside the page text. Gemini merges any new details — additional appearance clues, personality traits inferred from actions, new relationships — into the existing profile. Profiles build up progressively as you read.

Gemini is instructed to write **synthesised descriptions, not event logs** — personality fields read as character traits ("reckless and fiercely loyal") rather than lists of actions.

There are two enrichment paths depending on how Gemini names the character:

- **Exact name match** — Gemini returns "John" and "John" already exists. The existing record is silently replaced with the updated version on every page the character appears on. This is the normal path and happens automatically with no notification.
- **Near-duplicate name** — Gemini returns "Jon" or "Mr. Smith" for an existing "John" or "Smith" (Levenshtein distance ≤ 2, or one name is a substring of the other). The plugin detects the conflict and calls `enrichCharacter` to merge the new details into the existing record, then sets the **"cleanup needed"** flag since the merged fields may contain redundant text.

### Duplicate and conflict detection

When Gemini returns characters that look like existing ones (Levenshtein distance ≤ 2, or one name is a substring of another), the plugin detects the conflict and offers to enrich the existing character rather than create a duplicate. Within a single Gemini response, near-duplicates are collapsed before insertion.

### Auto-extract

When enabled, the plugin automatically scans each new page as you turn to it, after a configurable debounce delay (default 10 seconds). A small **scanning icon** appears in the top-left corner while the Gemini call is in progress. When the call completes, the icon is replaced by a **character count badge** showing how many characters were found or updated, which fades after 4 seconds. Both indicators can be disabled in Settings.

### Chapter scan

Scans every page in a chapter in batches of 4 pages per Gemini call, sleeping 3 seconds between batches to stay within the free-tier rate limit (15 RPM). The "Scan specific chapter" option shows all TOC chapters with their page ranges and a scan status indicator (`[✓ done]`, `[~ N/M pages]`, or unseen).

### Cleanup needed

The **KoCharacters** menu title shows **"— cleanup needed"** when auto-extract has enriched one or more existing characters (merged new details from a near-duplicate) but skipped the Gemini deduplication pass to avoid blocking. Over multiple page scans, enriched fields can accumulate redundant phrases (e.g. "brave; brave" or "tall with dark hair; tall, dark hair").

Run **"Cleanup all characters"** to send all affected profiles to Gemini for a single deduplication pass. The flag also clears automatically at the end of a chapter scan.

### Spoiler protection

Characters have an `unlocked` field. When spoiler protection is enabled in Settings, characters first seen beyond your current page are shown as `[SPOILER]` in the browser. Tapping a spoiler entry unlocks it.

### Relationship map

Sends all saved character profiles to Gemini in one call and asks it to produce a text-based relationship map, listing each character's connections with short relationship labels.

---

## Data storage

| Path | Contents |
|---|---|
| `<koreader_data>/kocharacters/<book_id>.json` | Per-book character database |
| `<koreader_data>/kocharacters/<book_id>_scanned.json` | Scanned page index |
| `<koreader_data>/kocharacters/usage_stats.json` | Daily Gemini API usage log |
| `<koreader_data>/kocharacters/<book_id>_characters.txt` | Exported character list |

The book ID is derived from the filename and a byte-sum hash of the file path — no MD5, no document API calls required.

---

## Character profile fields

| Field | Description |
|---|---|
| **Name** | Full name or best available name |
| **Aliases** | Nicknames, titles, alternate names |
| **Role** | protagonist / antagonist / supporting / unknown |
| **Physical description** | Appearance details from explicit descriptions |
| **Personality** | Stable traits synthesised from behaviour |
| **Relationships** | Connections to other named characters |
| **First appearance quote** | Short verbatim quote from the text |
| **Notes** | User-editable free text field |
| **Last updated** | Page number of the most recent update |

---

## Settings

| Setting | Description |
|---|---|
| **Gemini API key** | Your key from aistudio.google.com |
| **Auto-extract on page turn** | Automatically scan each page as you read |
| **Auto-extract delay** | Seconds to wait after a page turn before calling Gemini (default 10s) |
| **Scan indicator icon** | Show/hide the scanning and count icons in the top-left corner |
| **Auto-accept enrichments** | Silently enrich existing characters when near-duplicates are detected, instead of prompting |
| **Spoiler protection** | Hide characters first seen beyond your current page |
| **Edit prompts** | Customise the Gemini prompts for extraction, cleanup, re-analysis, and relationship mapping |

---

## Requirements

- KOReader with `ssl.https` / `ltn12` support (standard on Kindle builds)
- A free Google Gemini API key from aistudio.google.com
- `unzip` available on the device (standard on Kindle)
