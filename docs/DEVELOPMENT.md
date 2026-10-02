# Development

This guide is for developers who want to run Meeting Pilot's pipeline from source, use it headless, or contribute. If you just want to use the app, [download it](https://github.com/mard4/meeting-pilot/releases) and follow the [README](../README.md).

Meeting Pilot has two parts:

- **macOS app** (`macos/MeetingPilot/`, Swift Package Manager): menu bar app, meeting detection, recorder, live sidebar, settings and chat UI.
- **Python pipeline** (`src/meeting_pilot/`): transcription, summarization and publishing, exposed as the `meeting-pilot` CLI.

See [CONTRIBUTING.md](../.github/CONTRIBUTING.md) for code style, tests and pull requests, and [SETUP.md](SETUP.md) for the full step-by-step bootstrap.

## Run from source

For development or headless use, the pipeline is also a Python CLI:

```bash
python3 -m venv .venv311
source .venv311/bin/activate
pip install -e .
cp docs/env.example .env   # then fill it in
```

```bash
meeting-pilot run-once /path/to/audio.m4a            # process one file
meeting-pilot run-once /path/to/audio.m4a --dry-run  # without publishing
meeting-pilot watch                                  # watch the inbox folder
meeting-pilot teams-scrape --output ~/TeamsMeetings/teams-runtime.json
meeting-pilot chat --question "What did we decide about offline mode?" \
  --project "Atlas App" --theme Roadmap --theme Launch
```

Meetings move through `~/TeamsMeetings/{inbox_audio,processing,done,failed}`. `teams-scrape` reads the meeting title and participants from the Teams window (Accessibility first, on-device OCR as a fallback); the next processing run uses them.

To start the watcher at login without the app:

```bash
mkdir -p ~/Library/LaunchAgents
cp docs/launchd/com.transcribe-to-notion.watch.plist.example ~/Library/LaunchAgents/com.transcribe-to-notion.watch.plist
launchctl load ~/Library/LaunchAgents/com.transcribe-to-notion.watch.plist
tail -f ~/Library/Logs/transcribe-to-notion.log ~/Library/Logs/transcribe-to-notion.err.log
```

The full step-by-step bootstrap is in [SETUP.md](SETUP.md).

## Main environment variables

The app writes these for you; set them by hand only when running from source. See [`env.example`](env.example) for the complete list.

| Variable | Purpose |
| --- | --- |
| `PUBLISH_TARGETS` | `journal`, `notion`, `obsidian`, `apple_notes` (comma-separated). Defaults to the local Diary. |
| `JOURNAL_ROOT` | Diary root, default `~/Library/Application Support/Meeting Pilot/Diary` (Markdown by year/month plus a rebuildable `index.sqlite`). |
| `NOTION_TOKEN`, `NOTION_PARENT_PAGE_ID` | Notion integration token and the page Meeting Pilot publishes under. |
| `NOTION_DATABASE_ID`, `NOTION_PAGE_NAME` | The meetings table (found or created by setup) and its page name, default `Meeting Pilot`. |
| `NOTION_PROJECT_PROPERTY`, `NOTION_INCLUDE_*` | Project column name (default `Project`) and which sections each page includes. |
| `OBSIDIAN_VAULT_PATH`, `OBSIDIAN_FOLDER`, `OBSIDIAN_FILENAME_TEMPLATE` | Vault root, folder inside it (default `Meeting Pilot`) and filename template (default `{date} - {title}.md`). |
| `SUMMARY_PROVIDER_MODE` | `apple` (Apple Intelligence), `local` (oMLX/Ollama/LM Studio) or `api`. |
| `SUMMARY_BASE_URL`, `SUMMARY_MODEL`, `SUMMARY_API_KEY` | OpenAI-compatible endpoint, model and key. |
| `SUMMARY_PROMPT` | Optional extra instructions applied to every summary. |
| `TRANSCRIPTION_PROVIDER` | `fluid` (bundled, with speaker separation) or `apple`. |
| `MEETINGS_ROOT`, `INBOX_AUDIO_DIR` | Archive root (default `~/TeamsMeetings`) and the folder the watcher reads recordings from. |
| `RECORDER_MODE`, `RECORDING_PROMPT_ENABLED`, `RECORDING_PROMPT_DELAY_SECONDS` | Recorder mode (`macos_prompt` by default) and the banner shown when a meeting starts. |
