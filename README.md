# Character Extractor — KOReader Plugin

Manually extract and track character profiles from your book using the **Google Gemini AI API** (free tier).

---

## How to get a free Gemini API key

1. Go to **aistudio.google.com** and sign in with your Google account
2. Click **"Get API key"** in the left sidebar
3. Click **"Create API key"** — choose "Create API key in new project"
4. Copy the key (it starts with `AIza…`)
5. That's it — no credit card required, free tier gives ~1,500 requests/day

---

## Installation

1. Copy the `charextractor.koplugin/` folder into your KOReader `plugins/` directory.
2. Restart KOReader.
3. Open any book, tap the menu → **Character Extractor** → **Settings**.
4. Paste your Gemini API key and save.

---

## Usage

All actions live under the reader menu → **Character Extractor**:

| Menu item | What it does |
|---|---|
| **Extract characters from this page** | Sends the current page text to Gemini and saves any new characters found |
| **View saved characters** | Browse the full character list for this book; tap a name for their profile |
| **Export character list** | Writes a plain `.txt` file to `<koreader_data>/charextractor/` |
| **Clear character database** | Deletes saved characters for the current book |
| **Settings** | Enter / update your Gemini API key |

---

## How it works

1. On trigger, the plugin reads the current page text via `document:getPageText()`.
2. It loads the list of already-known character names for this book from a local JSON file.
3. It sends the page text + known names to `gemini-1.5-flash` with a structured prompt.
4. Gemini returns a JSON array of character profiles.
5. New characters are merged into the per-book database (stored in `<koreader_data>/charextractor/<book_md5>.json`).
6. Results are shown immediately; the full list is always available via "View saved characters".

---

## Data storage

- Character databases: `<koreader_data>/charextractor/<book_md5>.json`
- Exports: `<koreader_data>/charextractor/<book_md5>_characters.txt`

---

## Requirements

- KOReader with `ssl.https` / `socket.http` support (standard on most builds)
- A free Google Gemini API key from aistudio.google.com

---

## Character profile fields

Each character profile captures:
- **Name** and **aliases**
- **Role** (protagonist / antagonist / supporting / unknown)
- **Physical description**
- **Personality traits**
- **Relationships** to other characters
- **First appearance quote** from the text
