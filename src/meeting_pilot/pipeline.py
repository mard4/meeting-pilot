from __future__ import annotations

import shutil
import json
import re
from pathlib import Path

from .artifacts import MeetingArtifacts, collect_artifacts, write_meeting_metadata, write_omlx_summary
from .publishing.apple_notes_publisher import publish_to_apple_notes
from .config import Config
from .publishing.journal_publisher import publish_to_journal
from .publishing.obsidian_publisher import publish_to_obsidian
from .meeting_metadata import find_meeting_metadata
from .transcription.apple import run_apple_transcriber
from .transcription.fluid_audio import run_fluid_audio
from .transcription.session import create_session, validate_audio_file
from .publishing.notion_publisher import publish_to_notion
from .summarization.omlx_client import summarize
from .platforms.teams.teams_scraper import read_saved_teams_runtime_metadata
from .tag_catalog import catalog_values


def process_audio(config: Config, source_audio: Path, dry_run: bool = False) -> Path:
    config.ensure_dirs()
    meeting_metadata = find_meeting_metadata(config, source_audio)
    runtime_metadata = read_saved_teams_runtime_metadata(config, reference_audio=source_audio)
    if runtime_metadata:
        meeting_metadata = {**runtime_metadata, **meeting_metadata}
        if runtime_metadata.get("title") and not meeting_metadata.get("match_found"):
            meeting_metadata["title"] = runtime_metadata["title"]
        if runtime_metadata.get("participants") and not meeting_metadata.get("participants"):
            meeting_metadata["participants"] = runtime_metadata["participants"]
    session_dir, audio_file = create_session(config, source_audio)
    (session_dir / "publication_targets.json").write_text(
        json.dumps({"targets": list(config.publish_targets)}, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        print(f"Session: {session_dir}")
        validate_audio_file(audio_file)
        if meeting_metadata:
            write_meeting_metadata(session_dir, meeting_metadata)
        if config.transcription_provider == "apple":
            print("Running Apple On-Device transcription...")
            run_apple_transcriber(config, audio_file)
        elif config.transcription_provider == "fluid":
            print("Running FluidAudio transcription...")
            run_fluid_audio(config, audio_file)
        else:
            raise ValueError(f"Unsupported transcription provider: {config.transcription_provider}")
        artifacts = collect_artifacts(session_dir, audio_file)
        artifacts.meeting_metadata = meeting_metadata

        if config.summary_enabled:
            summary_name = "Apple Intelligence" if config.summary_provider_mode == "apple" else config.summary_model
            print(f"Summarizing with {summary_name}...", flush=True)
            artifacts.omlx_summary = summarize(config, artifacts)
            write_omlx_summary(session_dir, artifacts.omlx_summary)
            print("Summary saved.", flush=True)

        _apply_meeting_tag(artifacts, config=config)

        destination = _done_destination(config, session_dir, "rerun")
        if dry_run:
            print("Dry-run enabled, skipping publish step.")
        else:
            _prepare_audio_link(config, artifacts, destination)
            _publish_artifacts(config, artifacts)
            _discard_audio(config, artifacts, source_audio)

        shutil.move(str(session_dir), str(destination))
        print(f"Done: {destination}")
        return destination
    except Exception:
        destination = config.failed_dir / session_dir.name
        if destination.exists():
            destination = destination.with_name(f"{destination.name}-failed")
        shutil.move(str(session_dir), str(destination))
        print(f"Failed: {destination}")
        raise


def retry_from_transcript(config: Config, session_dir: Path, dry_run: bool = False) -> Path:
    """Resume a failed session without recording or transcribing it again."""
    session_dir = session_dir.expanduser().resolve()
    if not session_dir.is_dir():
        raise ValueError(f"Session folder not found: {session_dir}")
    audio_candidates = sorted(
        path for path in session_dir.iterdir()
        if path.suffix.lower() in {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus", ".mp4"}
    )
    if not audio_candidates:
        raise ValueError("No audio file found in the failed session.")

    artifacts = collect_artifacts(session_dir, audio_candidates[0])
    if not artifacts.transcript_text.strip():
        raise ValueError("No existing transcript found; the session cannot resume from summary.")
    metadata_path = session_dir / "meeting_metadata.json"
    if metadata_path.exists():
        try:
            import json
            artifacts.meeting_metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            artifacts.meeting_metadata = {}

    print(f"Retrying summary from existing transcript: {session_dir}", flush=True)
    existing_summary = session_dir / "omlx_summary.json"
    if existing_summary.exists():
        try:
            import json
            artifacts.omlx_summary = json.loads(existing_summary.read_text(encoding="utf-8"))
            print("Using the summary already generated by the previous attempt.")
        except (OSError, ValueError):
            artifacts.omlx_summary = None
    if config.summary_enabled and not artifacts.omlx_summary:
        print("Resumed session is starting summary generation...", flush=True)
        artifacts.omlx_summary = summarize(config, artifacts)
        write_omlx_summary(session_dir, artifacts.omlx_summary)
        print("Resumed session summary saved.", flush=True)

    _apply_meeting_tag(artifacts, config=config)

    destination = _done_destination(config, session_dir, "retry")
    if not dry_run:
        _prepare_audio_link(config, artifacts, destination)
        _publish_artifacts(config, artifacts)
        _discard_audio(config, artifacts)

    shutil.move(str(session_dir), str(destination))
    print(f"Done: {destination}")
    return destination


def retry_transcription(config: Config, session_dir: Path, dry_run: bool = False) -> Path:
    """Resume a failed session from its saved audio file."""
    session_dir = session_dir.expanduser().resolve()
    if not session_dir.is_dir():
        raise ValueError(f"Session folder not found: {session_dir}")
    audio_candidates = sorted(
        path for path in session_dir.iterdir()
        if path.suffix.lower() in {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus", ".mp4"}
    )
    if not audio_candidates:
        raise ValueError("No audio file found in the failed session.")
    audio_file = audio_candidates[0]

    print(f"Retrying transcription from saved audio: {audio_file}")
    validate_audio_file(audio_file)
    if config.transcription_provider == "apple":
        run_apple_transcriber(config, audio_file)
    elif config.transcription_provider == "fluid":
        run_fluid_audio(config, audio_file)
    else:
        raise ValueError(f"Unsupported transcription provider: {config.transcription_provider}")

    artifacts = collect_artifacts(session_dir, audio_file)
    if not artifacts.transcript_text.strip():
        raise ValueError("Transcription completed without producing a usable transcript.")
    metadata_path = session_dir / "meeting_metadata.json"
    if metadata_path.exists():
        try:
            import json
            artifacts.meeting_metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            artifacts.meeting_metadata = {}

    if config.summary_enabled:
        print("Transcription retry completed; starting summary generation...", flush=True)
        artifacts.omlx_summary = summarize(config, artifacts)
        write_omlx_summary(session_dir, artifacts.omlx_summary)
        print("Summary saved.", flush=True)

    _apply_meeting_tag(artifacts, config=config)

    destination = _done_destination(config, session_dir, "retry")
    if not dry_run:
        _prepare_audio_link(config, artifacts, destination)
        _publish_artifacts(config, artifacts)
        _discard_audio(config, artifacts)

    shutil.move(str(session_dir), str(destination))
    print(f"Done: {destination}")
    return destination


def _done_destination(config: Config, session_dir: Path, collision_suffix: str) -> Path:
    destination = config.done_dir / session_dir.name
    if destination.exists():
        destination = destination.with_name(f"{destination.name}-{collision_suffix}")
    return destination


def _prepare_audio_link(config: Config, artifacts: MeetingArtifacts, destination: Path) -> None:
    """Publishers link the audio at its archived path, which exists only after the final move."""
    if config.keep_audio and artifacts.audio_file.exists():
        artifacts.archived_audio_file = destination / artifacts.audio_file.name


def _discard_audio(config: Config, artifacts: MeetingArtifacts, source_audio: Path | None = None) -> None:
    """Drop recordings once published; failed sessions keep theirs so they can be retried."""
    # The native recorder copies into the session, so the inbox original is a duplicate either way.
    if source_audio is not None and source_audio.exists() and _is_inside(source_audio, config.inbox_audio_dir):
        source_audio.unlink(missing_ok=True)
    if not config.keep_audio:
        artifacts.audio_file.unlink(missing_ok=True)
        # The separate microphone/system tracks are recordings too.
        shutil.rmtree(artifacts.session_dir / "sidecar" / "tracks", ignore_errors=True)
        print("Audio deleted after publication (KEEP_AUDIO=false).")


def _is_inside(path: Path, folder: Path) -> bool:
    try:
        path.resolve().relative_to(folder.expanduser().resolve())
        return True
    except ValueError:
        return False


def _publish_artifacts(config: Config, artifacts: MeetingArtifacts) -> None:
    targets = _publish_targets(config)
    if targets:
        errors: list[str] = []
        published = 0
        for target in targets:
            try:
                _publish_single_target(config, artifacts, target)
                published += 1
            except Exception as exc:
                message = f"{target}: {exc}"
                errors.append(message)
                print(f"Publication warning: {message}")
        if errors and published == 0:
            raise RuntimeError("Nessun target di pubblicazione è riuscito: " + " | ".join(errors))
        return
    if getattr(config, "publish_targets_explicit", False):
        print("No publication target enabled; skipping publication.")
        return
    if config.notion_token and config.notion_database_id:
        print("Publishing to Notion...")
        publish_to_notion(config, artifacts)
        return
    if config.obsidian_vault_path:
        print("Publishing to Obsidian...")
        publish_to_obsidian(config, artifacts)
        return
    print("No external target configured, saving to the local Diary...")
    publish_to_journal(config, artifacts)


def _apply_meeting_tag(artifacts: MeetingArtifacts, config: Config | None = None) -> None:
    """Persist generated labels without overwriting human edits."""
    metadata = artifacts.meeting_metadata
    summary = artifacts.omlx_summary or {}
    existing = _clean_tag(metadata.get("project") or artifacts.frontmatter.get("project"))
    generated = _clean_tag(summary.get("tag"))
    fallback = _tag_from_title(
        summary.get("title") or metadata.get("title") or artifacts.title
    )
    tag = existing or generated or fallback
    theme = _clean_tag(
        metadata.get("theme")
        or artifacts.frontmatter.get("theme")
        or summary.get("theme")
    )
    if not tag and not theme:
        return
    if tag:
        metadata["project"] = _canonical_project_name(config, tag)
    if theme:
        metadata["theme"] = theme
    artifacts.meeting_metadata = metadata
    write_meeting_metadata(artifacts.session_dir, metadata)


def _canonical_project_name(config: Config | None, value: str) -> str:
    """Reuse the exact spelling of a curated project when the model selected it."""
    if config is None:
        return value
    try:
        for candidate in catalog_values(config)["projects"]:
            if candidate.casefold() == value.casefold():
                return candidate
    except (AttributeError, OSError, TypeError):
        pass
    return value


def _clean_tag(value: object) -> str:
    text = str(value or "").strip().lstrip("#")
    text = re.sub(r"\s+", " ", text)
    return text[:80]


def _tag_from_title(value: object) -> str:
    text = _clean_tag(value)
    text = re.sub(r"^(riunione|meeting|call)\s+(teams\s+)?", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\b\d{1,2}[:.]\d{2}\b", "", text)
    text = re.sub(r"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b", "", text)
    text = re.sub(r"\s+", " ", text).strip(" -_/")
    if text.casefold() in {"", "teams", "di prova", "microfono attivo in teams"}:
        return ""
    return text[:80]


def _publish_targets(config: Config) -> tuple[str, ...]:
    configured = getattr(config, "publish_targets", ())
    if configured:
        return tuple(configured)
    target = getattr(config, "publish_target", "auto").strip().lower()
    if target in {"notion", "obsidian", "journal"}:
        return (target,)
    if target in {"apple_notes", "apple-notes", "apple"}:
        return ("apple_notes",)
    return ()


def _publish_single_target(config: Config, artifacts: MeetingArtifacts, target: str) -> None:
    if target == "notion":
        print("Publishing to Notion...")
        if not config.notion_token or not config.notion_database_id:
            raise ValueError("PUBLISH_TARGETS includes notion but NOTION_TOKEN or NOTION_DATABASE_ID is missing.")
        publish_to_notion(config, artifacts)
        return
    if target == "obsidian":
        print("Publishing to Obsidian...")
        if not config.obsidian_vault_path:
            raise ValueError("PUBLISH_TARGETS includes obsidian but OBSIDIAN_VAULT_PATH is missing.")
        publish_to_obsidian(config, artifacts)
        return
    if target == "apple_notes":
        print("Publishing to Apple Notes...")
        publish_to_apple_notes(config, artifacts)
        return
    if target == "journal":
        print("Publishing to local Diary...")
        publish_to_journal(config, artifacts)
        return
    raise ValueError(f"Unknown publish target: {target}")
