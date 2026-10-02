# Operational Setup

This document describes how to set up the local app from scratch:

```text
macOS recorder -> audio file -> FluidAudio / Apple On-Device -> summary provider -> Notion/Obsidian
```

## 1. macOS Prerequisites

Install Homebrew if it isn't already present:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

FluidAudio is bundled with the app; it doesn't require external installation.

## 2. App's local Python environment

From the repository root:

```bash
cd /path/to/meeting-pilot
python3 -m venv .venv311
.venv311/bin/python -m pip install --upgrade pip setuptools wheel
.venv311/bin/python -m pip install -e .
```

Verify:

```bash
.venv311/bin/meeting-pilot --help
```

## 3. oMLX

If `omlx` is already installed:

```bash
omlx --help
omlx serve --model-dir ~/.omlx/models --port 8000
```

If you use the managed server:

```bash
omlx start
```

Check the available models:

```bash
KEY=$(python3 - <<'PY'
import json
from pathlib import Path
settings = json.loads(Path.home().joinpath('.omlx/settings.json').read_text())
print(settings['auth']['api_key'])
PY
)
curl -sS http://127.0.0.1:8000/v1/models -H "Authorization: Bearer $KEY"
```

In a typical `.env`, the local provider looks like:

```text
SUMMARY_PROVIDER_MODE=local
LOCAL_MODELS_DIR=~/Downloads
SUMMARY_BASE_URL=http://127.0.0.1:8000/v1
SUMMARY_MODEL=Qwen3-4B-Instruct-2507-4bit
```

On macOS 26 or later, with Apple Intelligence enabled and available, the app instead uses the on-device provider as the default:

```text
SUMMARY_PROVIDER_MODE=apple
APPLE_INTELLIGENCE_SUMMARIZER_CMD=/Applications/Meeting Pilot.app/Contents/MacOS/AppleIntelligenceSummarizer
APPLE_INTELLIGENCE_TIMEOUT_SECONDS=1800
```

If the Mac isn't compatible, is running an older macOS version, or the model isn't ready, the UI disables the Apple option and keeps local oMLX as the fallback.

To use OpenAI/GPT instead of oMLX:

```text
SUMMARY_PROVIDER_MODE=api
SUMMARY_BASE_URL=https://api.openai.com/v1
SUMMARY_MODEL=gpt-4.1-mini
SUMMARY_API_KEY=sk-...
SUMMARY_RESPONSE_FORMAT_JSON=true
```

## 4. Notion

You'll need:

- `NOTION_TOKEN`: your Notion integration token.
- `NOTION_PARENT_PAGE_ID`: the Notion page selected as the parent destination.
- `NOTION_PAGE_NAME`: name of the page/table, default `Meeting Pilot`.
- `NOTION_DATABASE_ID`: the single table where notes are created.
- `NOTION_TITLE_PROPERTY`: default `Name`.

From Meeting Pilot you can use **Change workspace** to reopen Notion and pick
a different parent page. You can also edit **Page name**.

If the parent page already contains a table with that name, or a page with
that name containing a table, Meeting Pilot reuses it and shows
"Page already exists, linked". If none exists, it creates a page with a single
table and the required title column `Name`.

No `SERIES` or `OCCURRENCES` structures, extra views, or optional columns are
created. Columns like `Date`, `Project`, `Status`, and `Participants` can be
added later: during publication the app only fills columns that already exist
and have a compatible type.

## 4b. Obsidian

If you prefer local Markdown notes, set an Obsidian vault in `.env`:

```text
OBSIDIAN_VAULT_PATH=~/ObsidianVault
OBSIDIAN_FOLDER=Meeting Pilot
OBSIDIAN_FILENAME_TEMPLATE={date} - {title}.md
PUBLISH_TARGET=obsidian
```

When `PUBLISH_TARGET=obsidian`, the pipeline writes the note into the vault. If no destination is configured, it falls back to the local Diary: `~/Library/Application Support/Meeting Pilot/Diary`, with one Markdown page per meeting and a rebuildable SQLite index.

## 5. `.env` configuration

The `.env` file is loaded automatically by the CLI. Variables already set in the environment take precedence over it.

In the Meeting Pilot app, secrets (`NOTION_TOKEN`, `SUMMARY_API_KEY`, `LOCAL_SUMMARY_API_KEY`, `REMOTE_SUMMARY_API_KEY`, `OMLX_API_KEY`) are not stored in `~/Library/Application Support/Meeting Pilot/.env`. They live in the login Keychain (service `io.github.mard4.MeetingPilot`; items saved by older builds under `it.local.MeetingPilot` are migrated on first read), and the app passes them to the CLI as environment variables. Values found in the file on launch are moved to the Keychain automatically. The file is kept at `0600` (owner only), both by the app and by `update_env_file`.

Main fields:

```text
NOTION_TOKEN=...
NOTION_PARENT_PAGE_ID=...
NOTION_APP_PAGE_ID=...
NOTION_SERIES_DATABASE_ID=...
NOTION_OCCURRENCES_DATABASE_ID=...
NOTION_DATABASE_ID=...
NOTION_PAGE_NAME=Meeting Pilot
PUBLISH_TARGET=obsidian
NOTION_TITLE_PROPERTY=Name
NOTION_PROJECT_PROPERTY=Project
OBSIDIAN_VAULT_PATH=~/ObsidianVault
OBSIDIAN_FOLDER=Meeting Pilot
OBSIDIAN_FILENAME_TEMPLATE={date} - {title}.md
NOTION_INCLUDE_OVERVIEW=true
NOTION_INCLUDE_SUMMARY=true
NOTION_INCLUDE_TOPICS=true
NOTION_INCLUDE_DECISIONS=true
NOTION_INCLUDE_ACTION_ITEMS=true
NOTION_INCLUDE_OPEN_QUESTIONS=true
NOTION_INCLUDE_RISKS=true
NOTION_INCLUDE_SPEAKERS=true
NOTION_INCLUDE_TRANSCRIPT=true

SUMMARY_ENABLED=true
SUMMARY_PROVIDER_MODE=local
LOCAL_MODELS_DIR=~/Downloads
SUMMARY_BASE_URL=http://127.0.0.1:8000/v1
SUMMARY_MODEL=Qwen3-4B-Instruct-2507-4bit
SUMMARY_PROMPT=Always highlight decisions, owners, deadlines, and risks without inventing information.
SUMMARY_API_KEY=...
SUMMARY_RESPONSE_FORMAT_JSON=false

MEETINGS_ROOT=~/TeamsMeetings
RECORDER_MODE=transcribex
INBOX_AUDIO_DIR=~/Documents/transcribex/media
RECORDING_PROMPT_ENABLED=true
RECORDING_PROMPT_DELAY_SECONDS=3
RECORDER_OPEN_TARGET=TranscribeX
MOVE_SOURCE_AUDIO=false
CALENDAR_METADATA_ENABLED=true
CALENDAR_LOOKUP_WINDOW_MINUTES=90
OUTLOOK_SQLITE_PATH=~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/Outlook.sqlite
TEAMS_RUNTIME_METADATA_FILE=~/TeamsMeetings/teams-runtime.json
TRANSCRIPTION_PROVIDER=fluid
FLUID_AUDIO_CMD=
```

## 7. Automatic audio folder

Configure TranscribeX / the macOS recorder to automatically save audio files to the path you set in `INBOX_AUDIO_DIR`, for example:

```text
~/Documents/transcribex/media
```

The pipeline then creates:

```text
~/TeamsMeetings/
  inbox_audio/
  processing/
  done/
  failed/
```

With `MOVE_SOURCE_AUDIO=false`, the pipeline copies audio from TranscribeX instead of moving it. Already-processed files are tracked in `~/TeamsMeetings/processed_sources.json`, so the watcher doesn't republish the same recording in a loop.

## 8. Manual execution

To process a single file:

```bash
.venv311/bin/meeting-pilot run-once /path/to/audio.m4a
```

To start the watcher:

```bash
.venv311/bin/meeting-pilot watch
```

Dry run without publishing to Notion:

```bash
.venv311/bin/meeting-pilot run-once /path/to/audio.m4a --dry-run
```

To read the subject and participants from the active Teams window:

```bash
.venv311/bin/meeting-pilot teams-scrape --output ~/TeamsMeetings/teams-runtime.json
```

The command first tries AppleScript/Accessibility. If the UI doesn't expose enough text, it brings Teams to the foreground, takes a screenshot, and uses Apple Vision OCR.
Without `--output`, it saves automatically to `TEAMS_RUNTIME_METADATA_FILE`, which the next processing run reads to enrich the Notion page.

Required macOS permissions:

- Privacy & Security -> Accessibility: enable the app you launch the command from, e.g. Terminal, iTerm, ghostty, or Codex.
- Privacy & Security -> Screen Recording: enable the same app for the OCR fallback.

If you change permissions while the terminal is open, quit and reopen the app before trying again.

## 9. Automatic startup with launchd

Install the job:

```bash
mkdir -p ~/Library/LaunchAgents
cp docs/launchd/com.meeting-pilot.watch.plist.example ~/Library/LaunchAgents/com.meeting-pilot.watch.plist
launchctl load ~/Library/LaunchAgents/com.meeting-pilot.watch.plist
```

Logs:

```bash
tail -f ~/Library/Logs/meeting-pilot.log
tail -f ~/Library/Logs/meeting-pilot.err.log
```

Stop:

```bash
launchctl unload ~/Library/LaunchAgents/com.meeting-pilot.watch.plist
```

## 10. Quick check

```bash
cd /path/to/meeting-pilot
.venv311/bin/meeting-pilot --help
.venv311/bin/meeting-pilot --help
curl -sS http://127.0.0.1:8000/v1/models -H "Authorization: Bearer $(awk -F= '/^SUMMARY_API_KEY=/{print $2}' .env)"
```

When `HF_TOKEN` is set, rerun:

```bash
.venv311/bin/meeting-pilot --help
```
