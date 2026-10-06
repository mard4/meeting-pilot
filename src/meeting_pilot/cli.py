from __future__ import annotations

import argparse
import json
import os
import re
import sys
import traceback
import urllib.error
from pathlib import Path

from .config import Config
from .env_file import update_env_file
from .chat.knowledge_base import (
    default_knowledge_index_path,
    documents_from_json_file,
    index_knowledge_documents,
    mongodb_documents_from_collection,
)
from .chat.meeting_chat import (
    MeetingChatFilters,
    MeetingChatResult,
    answer_meeting_question,
    available_chat_filter_values,
    available_chat_projects,
    citations_from_payload,
    quick_prompt_question,
    result_to_dict,
    save_meeting_chat_result,
)
from .publishing.notion_projects import assign_meeting_project
from .tag_catalog import add_catalog_value, bootstrap_catalog_from_notion, catalog_values, discard_unconfirmed_initial_imports, import_catalog_from_notion, import_catalog_from_sources
from .publishing.notion_setup import NotionSetupError, provision_notion_workspace
from .media_import import import_media_file
from .pipeline import process_audio, retry_from_transcript, retry_transcription
from .platforms.teams.teams_scraper import capture_teams_runtime_metadata
from .watcher import _source_key, mark_processed, watch
from .language import config_language, label, resolve_output_language


def main() -> None:
    try:
        _main()
    except Exception as exc:  # noqa: BLE001 - every failure ends in one readable line
        # The app logs the whole output and shows its last line, so the traceback
        # stays in the log and the person reads a sentence.
        traceback.print_exc()
        raise SystemExit(describe_error(exc, resolve_output_language(), "command_failed")) from exc


def _main() -> None:
    env_path = _env_path()
    _load_dotenv(env_path)
    parser = argparse.ArgumentParser(prog="meeting-pilot")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_once = subparsers.add_parser("run-once", help="Process one audio file immediately.")
    run_once.add_argument("audio_file", type=Path)
    run_once.add_argument("--dry-run", action="store_true", help="Skip Notion publishing.")

    import_parser = subparsers.add_parser(
        "import", help="Process a recording made elsewhere, such as a lecture video or a podcast."
    )
    import_parser.add_argument("media_file", type=Path)
    import_parser.add_argument("--title", help="Use this title instead of a generated one.")
    import_parser.add_argument("--date", help="When it was recorded, e.g. 2026-09-28T10:00. Defaults to now.")
    import_parser.add_argument("--slides", type=Path, help="PDF of the slides shown, placed next to the transcript.")
    import_parser.add_argument("--dry-run", action="store_true", help="Skip publishing.")

    watch_parser = subparsers.add_parser("watch", help="Watch the inbox folder forever.")
    watch_parser.add_argument("--dry-run", action="store_true", help="Skip Notion publishing.")

    retry_summary = subparsers.add_parser("retry-summary", help="Retry summary and publishing from an existing transcript.")
    retry_summary.add_argument("--session-dir", type=Path, required=True)
    retry_summary.add_argument("--dry-run", action="store_true", help="Skip Notion publishing.")

    retry_transcript = subparsers.add_parser("retry-transcription", help="Retry transcription and continue the pipeline from saved audio.")
    retry_transcript.add_argument("--session-dir", type=Path, required=True)
    retry_transcript.add_argument("--dry-run", action="store_true", help="Skip Notion publishing.")

    scrape_parser = subparsers.add_parser("teams-scrape", help="Read title and participants from the current Teams window.")
    scrape_parser.add_argument("--output", type=Path, help="Write metadata JSON to this path.")
    scrape_parser.add_argument("--no-ocr", action="store_true", help="Disable screenshot + Vision OCR fallback.")
    scrape_parser.add_argument("--screenshot", type=Path, help="Screenshot path for OCR fallback.")
    scrape_parser.add_argument("--print-raw", action="store_true", help="Print raw UI/OCR lines too.")
    scrape_parser.add_argument("--merge", action="store_true", help="Merge participants with previously saved metadata.")
    scrape_parser.add_argument("--title-hint", help="Use this title if Teams does not expose one.")
    scrape_parser.add_argument("--open-participants", action="store_true", help="Try to open the Teams participants panel first.")

    notion_setup = subparsers.add_parser(
        "notion-setup",
        help="Reuse or create the single Notion meeting destination.",
    )
    notion_setup.add_argument("--token", help="Notion integration token.")
    notion_setup.add_argument("--parent-page-id", help="Notion page shared with the integration; Meeting Pilot will create its workspace inside it.")
    notion_setup.add_argument("--write-env", action="store_true", help="Persist created ids to .env.")

    notion_project = subparsers.add_parser("notion-assign-project", help="Assign an existing Notion meeting page to a project.")
    notion_project.add_argument("--session-dir", type=Path, required=True, help="Processed meeting session directory.")
    notion_project.add_argument("--project", required=True, help="Project name, e.g. buddy.")
    notion_project.add_argument("--write-env", action="store_true", help="Persist the project property name to .env.")

    chat_parser = subparsers.add_parser("chat", help="Ask a question against locally indexed meetings.")
    chat_parser.add_argument("--question", help="Question to answer from selected meetings.")
    chat_parser.add_argument(
        "--prompt",
        choices=("project_decisions", "open_actions", "risks_blocks", "theme_evolution", "last_week_changes"),
        help="Use a built-in cross-meeting prompt.",
    )
    chat_parser.add_argument("--project", action="append", help="Filter by meeting project. Repeat for multiple projects.")
    chat_parser.add_argument("--theme", action="append", help="Filter by meeting theme. Repeat for multiple themes.")
    chat_parser.add_argument("--start-date", help="Inclusive ISO start date filter.")
    chat_parser.add_argument("--end-date", help="Inclusive ISO end date filter.")
    chat_parser.add_argument("--scope", choices=("meetings", "knowledge", "both"), default="meetings")
    chat_parser.add_argument(
        "--source",
        action="append",
        choices=("journal", "notion", "obsidian", "apple_notes"),
        help="Restrict to a publication destination. Repeat for multiple sources.",
    )
    chat_parser.add_argument(
        "--external-source",
        action="append",
        choices=("notion", "obsidian", "mongodb", "google_drive", "sharepoint"),
        help="Restrict knowledge-base search to an external source. Repeat for multiple sources.",
    )

    chat_projects = subparsers.add_parser("chat-projects", help="List projects available to the local meeting chat.")
    chat_projects.add_argument(
        "--external-source",
        action="append",
        choices=("notion", "obsidian", "mongodb", "google_drive", "sharepoint"),
        help="Only include projects from selected knowledge-base sources. Repeat for multiple sources.",
    )

    chat_filter_values = subparsers.add_parser("chat-filter-values", help="List projects and themes available to the local meeting chat.")
    chat_filter_values.add_argument(
        "--external-source",
        action="append",
        choices=("notion", "obsidian", "mongodb", "google_drive", "sharepoint"),
        help="Only include values from selected knowledge-base sources. Repeat for multiple sources.",
    )

    tag_catalog_values = subparsers.add_parser("tag-catalog-values", help="List the curated local project and topic catalog.")
    tag_catalog_add = subparsers.add_parser("tag-catalog-add", help="Add a confirmed value to the local project and topic catalog.")
    tag_catalog_add.add_argument("--kind", required=True, choices=("project", "topic"))
    tag_catalog_add.add_argument("--value", required=True)
    tag_catalog_import = subparsers.add_parser("tag-catalog-import-notion", help="Preview or explicitly import configured Notion project and topic options.")
    tag_catalog_import.add_argument("--apply", action="store_true", help="Save the displayed values to the local catalog.")
    tag_catalog_import_sources = subparsers.add_parser("tag-catalog-import-sources", help="Explicitly import projects and topics from configured local sources.")
    tag_catalog_import_sources.add_argument(
        "--source",
        action="append",
        choices=("journal", "completed", "notion", "obsidian", "apple_notes", "knowledge"),
        help="Source to import. Repeat to choose multiple sources; omit for all configured sources.",
    )
    tag_catalog_migrate = subparsers.add_parser("tag-catalog-migrate", help="Remove unconfirmed values created by older automatic imports.")

    chat_save = subparsers.add_parser("chat-save", help="Save a confirmed meeting chat answer.")
    chat_save.add_argument("--destination", choices=("journal", "notion", "obsidian"))
    chat_save.add_argument("--question")
    chat_save.add_argument("--answer")
    chat_save.add_argument("--citations-json", default="[]")
    chat_save.add_argument("--payload-stdin", action="store_true", help="Read destination, question, answer and citations from stdin JSON.")

    kb_file = subparsers.add_parser("kb-index-file", help="Index an external JSON/JSONL knowledge export locally.")
    kb_file.add_argument("--source", required=True, choices=("notion", "obsidian", "mongodb", "google_drive", "sharepoint"))
    kb_file.add_argument("--input", type=Path, required=True)
    kb_file.add_argument("--id-field", default="id")
    kb_file.add_argument("--title-field", default="title")
    kb_file.add_argument("--text-field", default="text")
    kb_file.add_argument("--url-field", default="url")
    kb_file.add_argument("--updated-field", default="updated_at")

    kb_mongodb = subparsers.add_parser("kb-index-mongodb", help="Index selected MongoDB documents locally.")
    kb_mongodb.add_argument("--uri")
    kb_mongodb.add_argument("--uri-stdin", action="store_true", help="Read MongoDB URI from stdin.")
    kb_mongodb.add_argument("--database", required=True)
    kb_mongodb.add_argument("--collection", required=True)
    kb_mongodb.add_argument("--query-json", default="{}")
    kb_mongodb.add_argument("--limit", type=int, default=500)
    kb_mongodb.add_argument("--title-field", default="title")
    kb_mongodb.add_argument("--text-field", default="text")
    kb_mongodb.add_argument("--url-field", default="url")
    kb_mongodb.add_argument("--updated-field", default="updated_at")

    args = parser.parse_args()
    config = Config.from_env()

    if args.command == "run-once":
        source = args.audio_file.expanduser()
        key = _source_key(source)
        process_audio(config, source, dry_run=args.dry_run)
        mark_processed(config, source, key)
        return

    if args.command == "import":
        import_media_file(
            config, args.media_file, title=args.title, recorded_at=args.date, slides=args.slides, dry_run=args.dry_run
        )
        return

    if args.command == "watch":
        watch(config, lambda audio_file: process_audio(config, audio_file, dry_run=args.dry_run))
        return

    if args.command == "retry-summary":
        retry_from_transcript(config, args.session_dir, dry_run=args.dry_run)
        return

    if args.command == "retry-transcription":
        retry_transcription(config, args.session_dir, dry_run=args.dry_run)
        return

    if args.command == "teams-scrape":
        output_path = args.output or config.teams_runtime_metadata_file
        metadata = capture_teams_runtime_metadata(
            config,
            output_path,
            use_ocr=not args.no_ocr,
            screenshot_path=args.screenshot,
            merge_existing=args.merge,
            title_hint=args.title_hint,
            open_participants=args.open_participants,
        )
        payload = metadata.to_dict()
        if not args.print_raw:
            payload["raw_lines"] = f"{len(metadata.raw_lines)} line(s); use --print-raw to show them"
            payload["window_titles"] = f"{len(metadata.window_titles)} title(s); use --print-raw to show them"
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.command == "notion-setup":
        if args.token or args.parent_page_id:
            update_values = {}
            if args.token:
                update_values["NOTION_TOKEN"] = args.token
            if args.parent_page_id:
                update_values["NOTION_PARENT_PAGE_ID"] = args.parent_page_id
            update_env_file(env_path, update_values)
            _load_dotenv(env_path)
            config = Config.from_env()
        try:
            result = provision_notion_workspace(config, env_path if args.write_env else None)
        except NotionSetupError as exc:
            raise SystemExit(f"Errore configurazione Notion: {exc}") from exc
        except Exception as exc:
            message = str(exc)
            if "Could not find page" in message or "not shared with your integration" in message:
                raise SystemExit(
                    "Errore configurazione Notion: condividi la pagina parent con "
                    "l'integrazione Notion prima di creare lo spazio Meeting Pilot."
                ) from exc
            raise SystemExit(f"Errore Notion: {message}") from exc
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    if args.command == "notion-assign-project":
        result = assign_meeting_project(
            config,
            args.session_dir,
            args.project,
            env_path if args.write_env else None,
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    if args.command == "chat":
        question = args.question
        if args.prompt:
            question = quick_prompt_question(
                args.prompt,
                project=(args.project or [None])[0],
                theme=(args.theme or [None])[0],
                language=config_language(config),
            )
        if not question:
            raise SystemExit("chat requires --question or --prompt.")
        try:
            result = answer_meeting_question(
                config,
                question,
                MeetingChatFilters(
                    projects=tuple(args.project or ()),
                    themes=tuple(args.theme or ()),
                    start_date=args.start_date,
                    end_date=args.end_date,
                    sources=tuple(args.source or ()),
                    search_scope=args.scope,
                    external_sources=tuple(args.external_source or ()),
                ),
            )
        except RuntimeError as exc:
            # The app reads stdout and stderr together and shows the answer as is, so a
            # failing provider gets one sentence in the JSON, not a traceback.
            result = MeetingChatResult(answer=_chat_failure_message(config, exc))
        print(json.dumps(result_to_dict(result), ensure_ascii=False, indent=2))
        return

    if args.command == "chat-projects":
        print(
            json.dumps(
                {"projects": available_chat_projects(config, tuple(args.external_source or ()))},
                ensure_ascii=False,
            )
        )
        return

    if args.command == "chat-filter-values":
        print(
            json.dumps(
                available_chat_filter_values(config, tuple(args.external_source or ())),
                ensure_ascii=False,
            )
        )
        return

    if args.command == "tag-catalog-values":
        print(json.dumps(_chat_catalog_payload(catalog_values(config)), ensure_ascii=False))
        return

    if args.command == "tag-catalog-add":
        print(json.dumps(_chat_catalog_payload(add_catalog_value(config, args.kind, args.value)), ensure_ascii=False))
        return

    if args.command == "tag-catalog-import-notion":
        values = import_catalog_from_notion(config) if args.apply else bootstrap_catalog_from_notion(config)
        print(json.dumps(_chat_catalog_payload(values), ensure_ascii=False))
        return

    if args.command == "tag-catalog-import-sources":
        values = import_catalog_from_sources(config, tuple(args.source or ()))
        print(json.dumps(_chat_catalog_payload(values), ensure_ascii=False))
        return

    if args.command == "tag-catalog-migrate":
        print(json.dumps(_chat_catalog_payload(discard_unconfirmed_initial_imports(config)), ensure_ascii=False))
        return

    if args.command == "chat-save":
        if args.payload_stdin:
            try:
                payload = json.loads(sys.stdin.read())
            except json.JSONDecodeError as exc:
                raise SystemExit(f"payload JSON non valido: {exc}") from exc
            if not isinstance(payload, dict):
                raise SystemExit("payload JSON deve essere un oggetto.")
            destination = str(payload.get("destination") or "")
            question = str(payload.get("question") or "")
            answer = str(payload.get("answer") or "")
            raw_citations = payload.get("citations") if isinstance(payload.get("citations"), list) else []
        else:
            destination = args.destination or ""
            question = args.question or ""
            answer = args.answer or ""
            try:
                raw_citations = json.loads(args.citations_json)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"citations JSON non valido: {exc}") from exc
        if destination not in {"journal", "notion", "obsidian"}:
            raise SystemExit("destination richiesta: journal, notion o obsidian.")
        if not question or not answer:
            raise SystemExit("question e answer sono obbligatori.")
        result = save_meeting_chat_result(
            config,
            answer=answer,
            citations=citations_from_payload(raw_citations if isinstance(raw_citations, list) else []),
            destination=destination,
            question=question,
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    if args.command == "kb-index-file":
        documents = documents_from_json_file(
            args.input,
            source=args.source,
            id_field=args.id_field,
            title_field=args.title_field,
            text_field=args.text_field,
            url_field=args.url_field,
            updated_field=args.updated_field,
        )
        result = index_knowledge_documents(default_knowledge_index_path(config.journal_root), documents)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    if args.command == "kb-index-mongodb":
        uri = sys.stdin.read().strip() if args.uri_stdin else (args.uri or "")
        if not uri:
            raise SystemExit("MongoDB URI richiesto.")
        try:
            query = json.loads(args.query_json)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"query JSON non valido: {exc}") from exc
        if not isinstance(query, dict):
            raise SystemExit("query JSON deve essere un oggetto.")
        documents = mongodb_documents_from_collection(
            uri=uri,
            database=args.database,
            collection=args.collection,
            title_field=args.title_field,
            text_field=args.text_field,
            url_field=args.url_field,
            updated_field=args.updated_field,
            query=query,
            limit=args.limit,
        )
        result = index_knowledge_documents(default_knowledge_index_path(config.journal_root), documents)
        print(json.dumps(result, ensure_ascii=False, indent=2))


def _chat_failure_message(config: Config, error: Exception) -> str:
    return describe_error(error, config_language(config), "chat_provider_failed")


def describe_error(error: Exception, language: str, template: str) -> str:
    """One sentence for the app: a provider that rejects the key says so, anything else keeps its message."""
    http_error = error if isinstance(error, urllib.error.HTTPError) else error.__cause__
    if isinstance(http_error, urllib.error.HTTPError) and http_error.code in {401, 403}:
        reason = label(language, "provider_unauthorized")
    else:
        reason = re.sub(r"^(Meeting chat|Summary) provider request failed: ", "", str(error)).rstrip(".")
    return label(language, template).format(reason=reason)


def _chat_catalog_payload(values: dict[str, list[str]]) -> dict[str, list[str]]:
    """Keep every catalog command compatible with the macOS chat payload."""
    return {
        "projects": values.get("projects", []),
        "themes": values.get("themes", values.get("topics", [])),
    }


def _env_path() -> Path:
    configured = os.environ.get("MEETING_PILOT_ENV_FILE")
    if configured:
        return Path(configured).expanduser()
    return Path.cwd() / ".env"


def _load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        value = value.strip().strip('"').strip("'")
        try:
            os.environ.setdefault(key, value)
        except OSError:
            # Ignore malformed entries left by a manually edited or corrupted
            # environment file instead of preventing every retry from starting.
            continue


if __name__ == "__main__":
    main()
