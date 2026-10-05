# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Student profile. On first launch Meeting Pilot asks whether you are a student, a worker or both (Settings › General changes it). Lectures become study notes with key concepts, assignments and deadlines, exam hints, review questions and references, in every destination; work meetings keep decisions, action items, open questions and risks. When you are both, the title decides and the live sidebar can switch a single recording. Notion gets a `Type` column (Work / Study) once you study.
- Audio source for recordings started by hand: microphone only (in-person lectures and meetings), Mac audio only (online lectures, webinars, videos) or both. Set the default in Pipeline › Recording and change it in the record prompt. A detected call always records both.
- When a call starts during a microphone or Mac-audio recording, Meeting Pilot offers to save it and switch to recording the call.

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
