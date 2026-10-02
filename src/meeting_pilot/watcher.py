from __future__ import annotations

import json
import os
import time
import traceback
from pathlib import Path

from .config import Config
from .transcription.session import AUDIO_EXTENSIONS


def iter_ready_audio_files(config: Config) -> list[Path]:
    now = time.time()
    processed = _load_processed(config)
    ready = []
    try:
        audio_files = sorted(config.inbox_audio_dir.iterdir())
    except OSError as exc:
        print(
            f"Cannot access inbox folder {config.inbox_audio_dir}: {exc}. "
            "Grant Meeting Pilot access to the recorder folder and restart the watcher."
        )
        return []
    for path in audio_files:
        if not path.is_file() or path.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        # The native macOS recorder writes directly into the inbox. Do not
        # process a partially-written audio file; the app removes this sidecar
        # as soon as recording stops.
        stat = path.stat()
        marker = Path(f"{path}.recording")
        if marker.exists():
            if _is_orphaned_recording_marker(marker, stat, now, config.file_stable_seconds):
                marker.unlink(missing_ok=True)
            else:
                continue
        if _source_key(path) in processed:
            continue
        if now - stat.st_mtime >= config.file_stable_seconds and stat.st_size > 0:
            ready.append(path)
    return ready


def _is_orphaned_recording_marker(marker: Path, audio_stat: object, now: float, stable_seconds: int) -> bool:
    try:
        marker_stat = marker.stat()
    except OSError:
        return False
    # Active recorder files are updated continuously. Recover only a marker
    # older than the completed audio and quiet long enough to be trustworthy.
    return (
        audio_stat.st_size > 0
        and audio_stat.st_mtime > marker_stat.st_mtime
        and now - audio_stat.st_mtime >= max(stable_seconds * 3, 90)
    )


def watch(config: Config, handler) -> None:
    config.ensure_dirs()
    print(f"Watching {config.inbox_audio_dir}")
    _resume_interrupted_sessions(config)
    while True:
        for audio_file in iter_ready_audio_files(config):
            # Keyed up front: a successful run may delete the source audio.
            key = _source_key(audio_file)
            mark_processing(config, audio_file, key)
            try:
                destination = handler(audio_file)
            except Exception:
                mark_failed(config, audio_file, key)
                traceback.print_exc()
                continue
            if destination:
                mark_processed(config, audio_file, key)
        time.sleep(config.watch_poll_seconds)


def _resume_interrupted_sessions(config: Config) -> None:
    """Continue work left in processing when the app or watcher was restarted."""
    try:
        sessions = sorted(path for path in config.processing_dir.iterdir() if path.is_dir())
    except OSError as exc:
        print(f"Cannot inspect interrupted sessions in {config.processing_dir}: {exc}")
        return

    if not sessions:
        return

    # Import here to keep the watcher usable as the low-level queue module.
    from .pipeline import retry_from_transcript, retry_transcription

    for session in sessions:
        if not _claim_session_recovery(session):
            continue
        try:
            has_transcript = any(
                path.suffix.lower() == ".txt" and not path.name.lower().endswith(".ffmpeg.log") and path.stat().st_size > 0
                for path in session.iterdir()
            )
            if has_transcript:
                print(f"Resuming summary from interrupted session: {session}")
                retry_from_transcript(config, session)
            else:
                print(f"Resuming transcription from interrupted session: {session}")
                retry_transcription(config, session)
        except Exception:
            print(f"Could not resume interrupted session: {session}")
            traceback.print_exc()
        finally:
            if session.exists():
                (session / ".recovery.lock").unlink(missing_ok=True)


def _claim_session_recovery(session: Path) -> bool:
    """Atomically acquire recovery, replacing a lock left behind by a stopped watcher."""
    lock = session / ".recovery.lock"
    for _ in range(2):
        try:
            with lock.open("x", encoding="utf-8") as handle:
                handle.write(str(os.getpid()))
            return True
        except FileExistsError:
            try:
                owner_pid = int(lock.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                owner_pid = None
            if owner_pid and _process_is_running(owner_pid):
                return False
            try:
                lock.unlink()
            except FileNotFoundError:
                continue
            except OSError:
                return False
    return False


def _process_is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def mark_processing(config: Config, path: Path, key: str | None = None) -> None:
    _mark(config, path, "processing", key)


def mark_processed(config: Config, path: Path, key: str | None = None) -> None:
    _mark(config, path, "processed", key)


def mark_failed(config: Config, path: Path, key: str | None = None) -> None:
    _mark(config, path, "failed", key)


def _mark(config: Config, path: Path, status: str, key: str | None = None) -> None:
    processed = _load_processed(config)
    processed[key or _source_key(path)] = {"path": str(path), "status": status, "updated_at": time.time()}
    config.processed_sources_file.parent.mkdir(parents=True, exist_ok=True)
    config.processed_sources_file.write_text(json.dumps(processed, indent=2, sort_keys=True), encoding="utf-8")


def _load_processed(config: Config) -> dict[str, dict[str, object]]:
    try:
        return json.loads(config.processed_sources_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _source_key(path: Path) -> str:
    stat = path.stat()
    return f"{path.resolve()}::{stat.st_size}::{int(stat.st_mtime)}"
