# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security
- The app and its helpers run with the hardened runtime even without a Developer ID, so no library can be injected into the process that holds the microphone, system audio, Accessibility and Automation permissions. The Python CLI is the only exception.
- The helpers the CLI starts (Apple transcriber and summarizer, FluidAudio, llama-server, Teams OCR) always come from the app bundle: paths written in `.env` no longer apply, and `osascript`, `screencapture` and `defaults` are called by full path, so a program planted in Homebrew's folders cannot run with the app's permissions.
- Updates are installed only when signed by the same signer as the running app, not just with any valid signature.
- Notion sign-in runs in a web authentication sheet that receives the token itself, so another app registering `meetingpilot://` cannot catch it; the sign-in state is kept in memory and used once.
- The Meeting Pilot model's server needs a key that only the running CLI knows and no longer exposes its slots, so other processes and other accounts on the Mac cannot read the transcripts sent to it.
- Recordings, transcripts, notes and logs are readable by your account only; existing meeting folders and logs are closed on the next launch.
- Builds use the pinned FluidAudio revision and install Python dependencies with the hashes in `uv.lock`; `uv` is no longer copied into the app. `install.sh` stops if the downloaded app's signature does not verify.

## [0.3.0] - 2026-10-08

### Added
- Meeting Pilot looks for a new version on GitHub at launch and every 6 hours, and tells you with a notification when there is one. Settings > Updates shows the version you have and an Update and Restart button: the app downloads the DMG, checks its signature, replaces itself in Applications and opens again, with launch at login still working. The same button is in the menu bar popover and its right-click menu. Updating waits while a meeting is being recorded or processed, and automatic checks can be turned off.

### Changed
- Release builds are signed with the "Meeting Pilot Signing" certificate when it is in the keychain, instead of an ad hoc signature that changes with every build, so microphone, screen recording, accessibility and automation permissions and launch at login stay valid after an update. Without the certificate builds stay ad hoc; DISTRIBUZIONE.md explains how to create it once.

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
