# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Videos imported from YouTube get the pictures of their screens too, as videos from the Mac do since 0.5.1, from the import sheet and from the browser extension. Meeting Pilot downloads the picture next to the sound, at up to 720p, takes the screens and then deletes it.
- Settings → Import: "Video screens" sets whether a video starts with its screens on (it still can be turned off per video), and "Keep downloaded videos" keeps a video from YouTube, picture and sound together, in Movies › Meeting Pilot, where its note links it. It is off by default: then only the audio and the screens stay.

## [0.5.1] - 2026-10-22

### Added
- Import a YouTube video by pasting its link: the Import button now offers "Files from this Mac…" and "YouTube Link…" (also ⇧⌘I), and the import sheet has a field for the link, filled in when one is already copied. The video's title and length are shown before importing, and its audio is downloaded and transcribed like any imported recording, with slides if you add them. The download uses yt-dlp: the copy installed with Homebrew if there is one, otherwise Meeting Pilot downloads it once (about 37 MB) and keeps it up to date. The note shows YouTube as its source with a link to the video. Live streams can be imported once they have ended.
- Claude and other AI apps can read your meetings and lectures through MCP: summaries, decisions, action items, study notes, slides and transcripts, searched by what was said, by date or by project, plus the open actions across meetings. They can only read, never change anything. Connect Claude Desktop with one click in Settings → Claude and other AI apps, or copy the command for Claude Code or the configuration for Cursor, VS Code, LM Studio and other MCP apps.
- A browser extension for Chrome, Edge, Brave and Arc sends the YouTube video you're watching to Meeting Pilot with one click, from its toolbar button or the right-click menu, and Meeting Pilot imports it right away. It says when a video was already imported, with the option to import it again. The popup shows how far the video got: download, transcription, summary, publishing. Set it up in Settings → Browser extension; the extension has been submitted to the Chrome Web Store and is waiting for review, and until then it can be loaded by hand from the folder Meeting Pilot opens, with "Load unpacked" in `chrome://extensions`.
- A video imported from the Mac (a tutorial, a screen recording, a recorded lecture) gets a picture of each screen it shows, next to what was said while it was on screen, the way slides are shown: in the Diary, Obsidian and Notion, and in the summary. Meeting Pilot looks for the moments the screen changes and stays still, keeps the complete picture (code fully typed, every bullet shown), and leaves out the speaker on camera, so a video of someone talking gets none. It's on for every video and can be turned off per video in the import sheet; adding slides turns it off. Videos from YouTube get screens in a later version.

### Fixed
- The Diary, Obsidian and Apple Notes icons next to a meeting in Overview open its note again: the Diary window shows that meeting's page, Obsidian opens the note, and Apple Notes shows it. They used to open the Markdown file in whatever app macOS uses for it (often Xcode or a text editor), or just Notes; only Notion worked.

## [0.5.0] - 2026-10-19

### Added
- PowerPoint slides (`.pptx`) are shown as pictures, like a PDF: Meeting Pilot turns the deck into a PDF on the Mac, when importing a recording or adding slides later, with a converter built into the app (no Office, Keynote or LibreOffice needed, nothing sent online). The Diary shows the slides next to the transcript, and Obsidian and Notion get them too. If a deck cannot be converted, its text is still used as before. LibreOffice Impress decks (`.odp`) are still read as text only.
- Obsidian and Notion show each slide next to what was said while it was on screen, as the Diary does. In Obsidian each part of the transcript by slide opens with the slide's picture and a link to its page in the PDF; in Notion each slide's toggle holds the picture and the transcript side by side. Meetings already published get the pictures when slides are added again.

### Fixed
- Apple Intelligence summaries of long meetings (about an hour or more) no longer stop with "Exceeded model context window size": the answer is kept within the model's limits, and a part that is still too long is summarized again in smaller pieces.
- Cloud summaries no longer fail with "Bad Request" on models that refuse a custom temperature, such as recent GPT-5 models: the request is sent again without it. Errors from the provider now include the reason it gave.

## [0.4.0] - 2026-10-19

### Added
- Slides and notes can be added in more formats than PDF: PowerPoint (`.pptx`) and LibreOffice Impress (`.odp`) decks, Word (`.docx`, `.doc`), LibreOffice Writer (`.odt`) and RTF documents, and plain text or Markdown notes, when importing a recording or later on one already processed. Decks are matched to the transcript slide by slide; documents are split at page breaks, headings and every few paragraphs. Only a PDF is copied next to the published notes.

### Fixed
- The live sidebar's transcript can be selected and copied. Before, dragging over it moved the whole sidebar; now the sidebar moves by its header.
- After closing the main window, clicking Meeting Pilot in the Dock opens it again. Before, the window was gone for good until the app was quit and reopened.
- The record banner for a Teams call no longer comes back after you close it. Muting yourself, or the call window being minimized for a moment, made the same call look new; now a call has to be gone for a minute before the next one prompts again.
- Speaker names in Teams are found when the call is in its own window. Before, a busy main Teams window could use up the search before the meeting window was reached; the log now also says when tiles are found or why names are missing.
- Importing a recording no longer fails when the slides' text or the recording's duration contain values that could not be written as JSON.

## [0.3.0] - 2026-10-08

### Added
- Join the Meeting Pilot Discord from Settings or the menu bar icon's right-click menu, for questions, ideas and problems.
- Meeting Pilot looks for a new version on GitHub at launch and every 6 hours, and tells you with a notification when there is one. Settings > Updates shows the version you have and an Update and Restart button: the app downloads the DMG, checks its signature, replaces itself in Applications and opens again, with launch at login still working. The same button is in the menu bar popover and its right-click menu. Updating waits while a meeting is being recorded or processed, and automatic checks can be turned off.

### Changed
- Meeting Pilot is signed with an Apple Developer ID and notarized by Apple: it opens on the first try, without going through Privacy & Security › Open Anyway. Because the signature changes this once, macOS asks again for the microphone, screen and system audio recording, Accessibility and Automation permissions, and for access to the saved Notion token and API keys; from then on they stay valid across updates. Builds use the Developer ID found in the keychain on their own, then the "Meeting Pilot Signing" certificate, then an ad hoc signature.

### Security
- The app and every helper run with the hardened runtime, so no library can be injected into the process that holds the microphone, system audio, Accessibility and Automation permissions.
- The helpers the CLI starts (Apple transcriber and summarizer, FluidAudio, llama-server, Teams OCR) always come from the app bundle: paths written in `.env` no longer apply, and `osascript`, `screencapture` and `defaults` are called by full path, so a program planted in Homebrew's folders cannot run with the app's permissions.
- Updates are installed only when signed by the same Developer ID team as the running app, not just with any valid signature, and Gatekeeper checks them like any other download.
- Notion sign-in runs in a web authentication sheet that receives the token itself, so another app registering `meetingpilot://` cannot catch it; the sign-in state is kept in memory and used once.
- The Meeting Pilot model's server needs a key that only the running CLI knows and no longer exposes its slots, so other processes and other accounts on the Mac cannot read the transcripts sent to it.
- Recordings, transcripts, notes and logs are readable by your account only; existing meeting folders and logs are closed on the next launch.
- Builds use the pinned FluidAudio revision and install Python dependencies with the hashes in `uv.lock`; `uv` is no longer copied into the app. `install.sh` stops unless the downloaded app is signed by the Meeting Pilot team and notarized.

## [0.2.1] - 2026-10-07

### Added
- Slides can be added to a meeting already processed, live recordings included: Add Slides in the Diary, or right-click it in the recent meetings. Names and technical words the transcript misheard are corrected from the slides ("Cubernetes", "Kuber netes" become Kubernetes, while plurals and ordinary words are left alone), the summary is written again following the slides, and the notes in the Diary, Obsidian, Notion and Apple Notes are replaced: the old ones go to the Trash, so hand edits can be recovered. `meeting-pilot attach-slides --session-dir DIR [--slides PDF]` does the same from the command line.

### Changed
- Opening the DMG shows a single window with the app on the left, an arrow and the Applications folder on the right, so installing is one drag. The post-installation guide text file is no longer in the DMG.

### Fixed
- Launch at login works again after updating the app: the login item is registered again whenever the app changes, and Settings says when it is switched off in System Settings, with a shortcut to Login Items.
- With Apple Intelligence as the provider, the chat answers with it instead of the OpenAI-compatible endpoint left in the settings, which failed. Chat, retry and save errors now show as one readable sentence instead of a traceback.
- The live sidebar no longer shows "Me" lines during a call. The microphone also hears the others through the speakers, so their words came out twice, once under "Me" even when you weren't talking. The microphone is now transcribed only when the Mac's audio isn't arriving, and those lines carry no label.
- Teams participants whose display name contains a comma ("Rossi, Mario") are named again, in the sidebar and in the notes; before, they were never recognised.
- In the sidebar, a Teams line now ends when the speaking border moves to someone else, so two people talking back to back no longer share one line and one name.

## [0.2.0] - 2026-10-06

### Added
- The Meeting Pilot model: a summary engine that runs on the Mac with nothing else to install. Pick Light (572 MB, Bonsai-4B) or Quality (2.5 GB, Qwen3-4B) in Pipeline › Summary and download it once; the file is checked against a fixed checksum. The llama.cpp engine ships inside the app (about 20 MB) and only runs while it writes notes or answers in the chat, then frees the memory. Macs with 8 GB of memory get a smaller context, and longer transcripts are condensed first.
- A short welcome tour on first launch, and once after updating: who the notes are for, recording and importing, who writes the summary (with Apple Intelligence's status), where notes are published and how the chat answers from them with sources, ending with a sample of the notes you will get, a lecture's linked to its slides. Help › How Meeting Pilot Works replays it.
- Student profile. Meeting Pilot asks once whether you are a student, a worker or both, on a new install and on the first launch after updating, until you answer (Settings › General changes it). Lectures become study notes with key concepts, assignments and deadlines, exam hints, review questions and references, in every destination; work meetings keep decisions, action items, open questions and risks. When you are both, the title decides and the live sidebar can switch a single recording. Notion gets a `Type` column (Work / Study) once you study.
- Audio source for recordings started by hand: microphone only (in-person lectures and meetings), Mac audio only (online lectures, webinars, videos) or both. Set the default in Pipeline › Recording and change it in the record prompt. A detected call always records both.
- When a call starts during a microphone or Mac-audio recording, Meeting Pilot offers to save it and switch to recording the call.
- Import recordings made elsewhere, such as lecture videos and podcasts: Import on the dashboard, in the menu bar, File › Import Recordings (⌘I), or drop files on the window. Each file gets an optional title and the date it was recorded when the media records one (cameras, QuickTime, Voice Memos), otherwise the import date, which you can change, videos are reduced to their audio, and the original stays where it is. Imports never take calendar or Teams details, and their notes link back to the original file.
- Slides next to the transcript: attach the PDF shown in a lecture or presentation when importing it (or drop it with the video). Each part of the transcript is matched to the slide shown meanwhile, on the Mac and without a model; the summary follows the slides and cites them as (slide N); the Diary shows the slides beside the transcript and keeps them in step; Obsidian links each part to its slide page; Notion gets the PDF and one section per slide; the meeting chat can answer from the slide text. Slides that are only pictures are read with on-device OCR, and their names and terms help Apple transcription spell them.
- When importing, someone who is both a student and a worker chooses whether the files become lecture or work notes.
- `meeting-pilot import FILE [--title] [--date] [--slides PDF]` does the same from the command line.
- Notion pages with more than 100 blocks are completed in further requests instead of being cut off.
- Transcripts longer than one summary request (about 1 h 45 of speech) are condensed part by part before summarizing instead of being cut off, and transcription and Apple Intelligence time limits now grow with the length of the recording.

### Changed
- From macOS 26 Apple's on-device recognizer transcribes by default and FluidAudio labels the speakers, in its offline mode, which tells quickly alternating voices apart far better. The Parakeet speech model (~460 MB) is no longer bundled: the FluidAudio card downloads it on request, and older Macs fetch it on their own. The app is about 150 MB instead of 650 MB.

### Fixed
- Recordings made outside a call no longer stop by themselves when Teams releases the microphone, and no longer take the title and participants of an earlier Teams call.

## [0.1.2] - 2026-10-02

### Added
- UI and meeting notes in Spanish, French, German, Portuguese and Dutch, alongside Italian and English.
- Menu bar buttons to open the app, the meeting chat and the live sidebar (the sidebar is available during a recording).

### Fixed
- Dates in pages published to Notion.
- The pipeline watcher is now matched by its executable, and test runs no longer write to the real log.

### Changed
- Python package renamed from `transcribe_to_notion` to `meeting_pilot`; Swift and Python sources grouped into feature folders.

## [0.1.1] - 2026-10-01

### Added
- Confirmation prompts on the Pipeline screen before switching transcription to Apple or AI summaries to the cloud.
- LICENSE (MIT), CONTRIBUTING.md, CODE_OF_CONDUCT.md, this CHANGELOG.
- Privacy & Permissions section in the README.
- English translation of SETUP.md.

### Changed
- `.dmg` build artifacts are no longer tracked in git; distributed via GitHub Releases instead.

### Fixed
- Secret loading.

## [0.1.0]

- Initial local release: Teams meeting capture, on-device transcription (FluidAudio / Apple On-Device), LLM summarization, and publishing to Notion, Obsidian, Apple Notes, or a local Diary.
