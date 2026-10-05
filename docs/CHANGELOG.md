# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
