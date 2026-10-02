# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
