from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from .language import resolve_output_language


def _bool_env(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _global_bool_env(name: str, legacy_name: str, default: bool) -> bool:
    """Prefer the shared page-format setting, preserving existing Notion settings."""
    if os.getenv(name) is not None:
        return _bool_env(name, default)
    return _bool_env(legacy_name, default)


def _path_env(name: str, default: str) -> Path:
    return Path(os.getenv(name, default)).expanduser()


@dataclass(frozen=True)
class Config:
    meetings_root: Path
    inbox_audio_dir: Path
    processing_dir: Path
    done_dir: Path
    failed_dir: Path
    processed_sources_file: Path
    move_source_audio: bool
    keep_audio: bool
    calendar_metadata_enabled: bool
    calendar_lookup_window_minutes: int
    outlook_sqlite_path: Path
    teams_runtime_metadata_file: Path
    transcription_provider: str
    transcription_locale: str
    apple_transcriber_cmd: str
    apple_transcriber_timeout_seconds: int
    fluid_audio_cmd: str
    apple_diarization: bool
    summary_enabled: bool
    summary_provider_mode: str
    summary_runtime: str
    summary_base_url: str
    summary_model: str
    summary_prompt: str
    summary_api_key: str | None
    summary_response_format_json: bool
    summary_timeout_seconds: int
    apple_intelligence_summarizer_cmd: str
    apple_intelligence_timeout_seconds: int
    publish_targets: tuple[str, ...]
    publish_targets_explicit: bool
    publish_target: str
    journal_root: Path
    obsidian_vault_path: Path | None
    obsidian_folder: str
    obsidian_filename_template: str
    notion_token: str | None
    notion_parent_page_id: str | None
    notion_app_page_id: str | None
    notion_series_database_id: str | None
    notion_occurrences_database_id: str | None
    notion_database_id: str | None
    notion_page_name: str
    notion_title_property: str
    notion_project_property: str
    notion_include_overview: bool
    notion_include_summary: bool
    notion_include_topics: bool
    notion_include_decisions: bool
    notion_include_action_items: bool
    notion_include_open_questions: bool
    notion_include_risks: bool
    notion_include_speakers: bool
    notion_include_transcript: bool
    watch_poll_seconds: int
    file_stable_seconds: int
    output_language: str = "it"
    # "auto" picks a template from the meeting title; see summary_templates.py.
    summary_template: str = "auto"
    # "worker", "student" or "both"; see profiles.py.
    user_profile: str = "worker"
    # Sections only lectures have (see profiles.py); the shared ones use the fields above.
    notion_include_key_concepts: bool = True
    notion_include_assignments: bool = True
    notion_include_exam_hints: bool = True
    notion_include_review_questions: bool = True
    notion_include_references: bool = True
    # The Meeting Pilot model (summary mode "builtin"): the bundled llama.cpp server and
    # the folder the app downloads its models into. See summarization/builtin_model.py.
    builtin_server_cmd: str = "llama-server"
    builtin_models_dir: Path = Path("~/Library/Application Support/Meeting Pilot/Models").expanduser()

    @classmethod
    def from_env(cls) -> "Config":
        root = _path_env("MEETINGS_ROOT", "~/TeamsMeetings")
        return cls(
            meetings_root=root,
            inbox_audio_dir=_path_env("INBOX_AUDIO_DIR", str(root / "inbox_audio")),
            processing_dir=_path_env("PROCESSING_DIR", str(root / "processing")),
            done_dir=_path_env("DONE_DIR", str(root / "done")),
            failed_dir=_path_env("FAILED_DIR", str(root / "failed")),
            processed_sources_file=_path_env("PROCESSED_SOURCES_FILE", str(root / "processed_sources.json")),
            move_source_audio=_bool_env("MOVE_SOURCE_AUDIO", True),
            keep_audio=_bool_env("KEEP_AUDIO", False),
            calendar_metadata_enabled=_bool_env("CALENDAR_METADATA_ENABLED", True),
            calendar_lookup_window_minutes=int(os.getenv("CALENDAR_LOOKUP_WINDOW_MINUTES", "90")),
            outlook_sqlite_path=_path_env(
                "OUTLOOK_SQLITE_PATH",
                "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/Outlook.sqlite",
            ),
            teams_runtime_metadata_file=_path_env("TEAMS_RUNTIME_METADATA_FILE", str(root / "teams-runtime.json")),
            transcription_provider=os.getenv("TRANSCRIPTION_PROVIDER", "fluid").strip().lower(),
            transcription_locale=os.getenv("TRANSCRIPTION_LOCALE", "it-IT"),
            apple_transcriber_cmd=os.getenv(
                "APPLE_TRANSCRIBER_CMD",
                "macos/MeetingPilot/build/Meeting Pilot.app/Contents/MacOS/AppleTranscriber",
            ),
            apple_transcriber_timeout_seconds=int(os.getenv("APPLE_TRANSCRIBER_TIMEOUT_SECONDS", "900")),
            fluid_audio_cmd=os.getenv("FLUID_AUDIO_CMD", "fluidaudiocli"),
            # Apple's recognizer has no speakers of its own; FluidAudio's diarization adds them.
            apple_diarization=_bool_env("APPLE_DIARIZATION", True),
            summary_enabled=_bool_env("SUMMARY_ENABLED", _bool_env("OMLX_ENABLED", True)),
            summary_provider_mode=os.getenv("SUMMARY_PROVIDER_MODE", "local").strip().lower(),
            summary_runtime=os.getenv("SUMMARY_RUNTIME", "").strip().lower(),
            summary_base_url=os.getenv("SUMMARY_BASE_URL", os.getenv("OMLX_BASE_URL", "http://127.0.0.1:8000/v1")).rstrip("/"),
            summary_model=os.getenv("SUMMARY_MODEL", os.getenv("OMLX_MODEL", "local-model")),
            summary_prompt=os.getenv("SUMMARY_PROMPT", "").strip(),
            summary_api_key=os.getenv("SUMMARY_API_KEY", os.getenv("OMLX_API_KEY")),
            summary_response_format_json=_bool_env(
                "SUMMARY_RESPONSE_FORMAT_JSON",
                _bool_env("OMLX_RESPONSE_FORMAT_JSON", False),
            ),
            # Models running on the Mac are far slower than cloud APIs on long meetings.
            summary_timeout_seconds=max(
                15,
                int(os.getenv(
                    "SUMMARY_TIMEOUT_SECONDS",
                    "900" if os.getenv("SUMMARY_PROVIDER_MODE", "local").strip().lower() in {"local", "builtin"} else "180",
                )),
            ),
            apple_intelligence_summarizer_cmd=os.getenv(
                "APPLE_INTELLIGENCE_SUMMARIZER_CMD",
                "macos/MeetingPilot/build/Meeting Pilot.app/Contents/MacOS/AppleIntelligenceSummarizer",
            ),
            apple_intelligence_timeout_seconds=int(os.getenv("APPLE_INTELLIGENCE_TIMEOUT_SECONDS", "1800")),
            publish_targets=_publish_targets_from_env(),
            publish_targets_explicit=_bool_env("PUBLISH_TARGETS_EXPLICIT", False),
            publish_target=os.getenv("PUBLISH_TARGET", "auto").strip().lower(),
            journal_root=_path_env(
                "JOURNAL_ROOT",
                "~/Library/Application Support/Meeting Pilot/Diary",
            ),
            obsidian_vault_path=_path_env("OBSIDIAN_VAULT_PATH", "") if os.getenv("OBSIDIAN_VAULT_PATH") else None,
            obsidian_folder=os.getenv("OBSIDIAN_FOLDER", "Meeting Pilot"),
            obsidian_filename_template=os.getenv("OBSIDIAN_FILENAME_TEMPLATE", "{date} - {title}.md"),
            notion_token=os.getenv("NOTION_TOKEN"),
            notion_parent_page_id=os.getenv("NOTION_PARENT_PAGE_ID"),
            notion_app_page_id=os.getenv("NOTION_APP_PAGE_ID"),
            notion_series_database_id=os.getenv("NOTION_SERIES_DATABASE_ID"),
            notion_occurrences_database_id=os.getenv("NOTION_OCCURRENCES_DATABASE_ID"),
            notion_database_id=os.getenv("NOTION_OCCURRENCES_DATABASE_ID") or os.getenv("NOTION_DATABASE_ID"),
            notion_page_name=os.getenv("NOTION_PAGE_NAME", "Meeting Pilot").strip() or "Meeting Pilot",
            notion_title_property=os.getenv("NOTION_TITLE_PROPERTY", "Name"),
            notion_project_property=os.getenv("NOTION_PROJECT_PROPERTY", "Project"),
            notion_include_overview=_global_bool_env("INCLUDE_OVERVIEW", "NOTION_INCLUDE_OVERVIEW", True),
            notion_include_summary=_global_bool_env("INCLUDE_SUMMARY", "NOTION_INCLUDE_SUMMARY", True),
            notion_include_topics=_global_bool_env("INCLUDE_TOPICS", "NOTION_INCLUDE_TOPICS", True),
            notion_include_decisions=_global_bool_env("INCLUDE_DECISIONS", "NOTION_INCLUDE_DECISIONS", True),
            notion_include_action_items=_global_bool_env("INCLUDE_ACTION_ITEMS", "NOTION_INCLUDE_ACTION_ITEMS", True),
            notion_include_open_questions=_global_bool_env("INCLUDE_OPEN_QUESTIONS", "NOTION_INCLUDE_OPEN_QUESTIONS", True),
            notion_include_risks=_global_bool_env("INCLUDE_RISKS", "NOTION_INCLUDE_RISKS", True),
            notion_include_speakers=_global_bool_env("INCLUDE_SPEAKERS", "NOTION_INCLUDE_SPEAKERS", True),
            notion_include_transcript=_global_bool_env("INCLUDE_TRANSCRIPT", "NOTION_INCLUDE_TRANSCRIPT", True),
            watch_poll_seconds=int(os.getenv("WATCH_POLL_SECONDS", "5")),
            file_stable_seconds=int(os.getenv("FILE_STABLE_SECONDS", "10")),
            output_language=resolve_output_language(),
            summary_template=os.getenv("SUMMARY_TEMPLATE", "auto").strip() or "auto",
            builtin_server_cmd=os.getenv("LLAMA_SERVER_CMD", "llama-server"),
            builtin_models_dir=_path_env("BUILTIN_MODELS_DIR", "~/Library/Application Support/Meeting Pilot/Models"),
            user_profile=os.getenv("USER_PROFILE", "worker").strip().lower() or "worker",
            notion_include_key_concepts=_bool_env("INCLUDE_KEY_CONCEPTS", True),
            notion_include_assignments=_bool_env("INCLUDE_ASSIGNMENTS", True),
            notion_include_exam_hints=_bool_env("INCLUDE_EXAM_HINTS", True),
            notion_include_review_questions=_bool_env("INCLUDE_REVIEW_QUESTIONS", True),
            notion_include_references=_bool_env("INCLUDE_REFERENCES", True),
        )

    def ensure_dirs(self) -> None:
        for folder in (
            self.inbox_audio_dir,
            self.processing_dir,
            self.done_dir,
            self.failed_dir,
        ):
            folder.mkdir(parents=True, exist_ok=True)


def _publish_targets_from_env() -> tuple[str, ...]:
    raw = os.getenv("PUBLISH_TARGETS", os.getenv("PUBLISH_TARGET", "")).strip().lower()
    if not raw:
        return ()
    parts = [
        item.strip()
        for item in raw.split(",")
        if item.strip() and item.strip() != "auto"
    ]
    normalized = []
    for item in parts:
        if item in {"apple", "apple-notes", "apple_notes"}:
            item = "apple_notes"
        if item in {"notion", "obsidian", "apple_notes", "journal"} and item not in normalized:
            normalized.append(item)
    return tuple(normalized)
