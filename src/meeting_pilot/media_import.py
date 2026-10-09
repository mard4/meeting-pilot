"""Recordings the user imported (a lecture video, a podcast) instead of recording them.

The macOS app copies the audio into the inbox with a sidecar `recording.json` like:

    {"call": false, "origin": "import", "media_kind": "video",
     "original_name": "Lezione 3.mp4", "original_path": "/Users/.../Lezione 3.mp4",
     "recorded_at": "2026-09-28T10:00:00", "duration_seconds": 5400.0,
     "title": "Lezione 3"}

`title` is present only when the user typed one. An import is not a call, so it gets
no calendar or Teams metadata, and its date is when it was recorded, not imported.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

from .artifacts import MeetingArtifacts
from .config import Config
from .slides.deck import SLIDES_FOLDER, copy_slides_source, is_slides_file
from .transcription.session import audio_duration_seconds, sidecar_dir

IMPORT_ORIGIN = "import"
# Containers whose soundtrack is extracted first; `.mp4` is usually a video too.
VIDEO_EXTENSIONS = {".mov", ".mp4", ".m4v"}


def imported_media(source_audio: Path) -> dict[str, Any] | None:
    """The import description written next to an inbox file, or None for recordings."""
    return read_import_info(sidecar_dir(source_audio))


def read_import_info(sidecar: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads((sidecar / "recording.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or payload.get("origin") != IMPORT_ORIGIN:
        return None
    return payload


def import_metadata(info: dict[str, Any]) -> dict[str, Any]:
    """Meeting metadata for an import, in the shape calendar matching produces."""
    metadata: dict[str, Any] = {"match_found": False, "origin": IMPORT_ORIGIN}
    recorded_at = _text(info.get("recorded_at"))
    if recorded_at:
        metadata["recording_start"] = recorded_at
    duration = _seconds(info.get("duration_seconds"))
    if duration:
        metadata["duration_seconds"] = duration
    for key in ("media_kind", "original_name", "original_path"):
        value = _text(info.get(key))
        if value:
            metadata[key] = value
    title = _text(info.get("title"))
    if title:
        metadata["title"] = title
        metadata["title_from_user"] = True
    return metadata


def is_import(metadata: dict[str, Any] | None) -> bool:
    return bool(metadata) and metadata.get("origin") == IMPORT_ORIGIN


def import_media_file(
    config: Config,
    media: Path,
    title: str | None = None,
    recorded_at: str | None = None,
    slides: Path | None = None,
    dry_run: bool = False,
) -> Path:
    """Command-line import: prepares the audio and its sidecar as the app does, then
    runs the pipeline on them."""
    from .pipeline import process_audio

    media = media.expanduser().resolve()
    if not media.is_file():
        raise ValueError(f"File not found: {media}")
    if slides is not None and not slides.expanduser().is_file():
        raise ValueError(f"Slides not found: {slides}")
    if slides is not None and not is_slides_file(slides):
        raise ValueError(f"Unsupported slides format: {slides.name}")
    video = media.suffix.lower() in VIDEO_EXTENSIONS
    info: dict[str, Any] = {
        "call": False,
        "origin": IMPORT_ORIGIN,
        "media_kind": "video" if video else "audio",
        "original_name": media.name,
        "original_path": str(media),
        # The file's own date is when it was downloaded or copied, not recorded.
        "recorded_at": recorded_at or datetime.now().isoformat(timespec="seconds"),
    }
    if title and title.strip():
        info["title"] = title.strip()
    with tempfile.TemporaryDirectory(prefix="meeting-pilot-import-") as temporary:
        audio = Path(temporary) / (f"{media.stem}.m4a" if video else media.name)
        if video:
            extract_audio(media, audio)
        else:
            shutil.copy2(media, audio)
        duration = audio_duration_seconds(audio)
        if duration:
            info["duration_seconds"] = duration
        sidecar = sidecar_dir(audio)
        sidecar.mkdir()
        (sidecar / "recording.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
        if slides is not None:
            copy_slides_source(slides.expanduser(), sidecar / SLIDES_FOLDER)
        return process_audio(config, audio, dry_run=dry_run)


def extract_audio(video: Path, output: Path) -> Path:
    """The soundtrack of a lecture video as AAC, with the converter macOS ships."""
    command = ["/usr/bin/avconvert", "--source", str(video), "--preset", "PresetAppleM4A", "--output", str(output), "--replace"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise RuntimeError(f"Cannot extract the audio from {video.name}: {exc}") from exc
    if result.returncode != 0 or not output.is_file():
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"Cannot extract the audio from {video.name}: {detail or 'avconvert failed'}")
    return output


def use_file_name_as_title(artifacts: MeetingArtifacts) -> None:
    """Without a summary, an import is named after its file rather than its session."""
    metadata = artifacts.meeting_metadata or {}
    original = Path(_text(metadata.get("original_name"))).stem
    if is_import(metadata) and original and not artifacts.frontmatter.get("title"):
        artifacts.title = original


def apply_user_title(artifacts: MeetingArtifacts) -> None:
    """A title the user typed when importing wins over the generated one."""
    metadata = artifacts.meeting_metadata or {}
    if not metadata.get("title_from_user") or not artifacts.omlx_summary:
        return
    title = _text(metadata.get("title"))
    if title:
        artifacts.omlx_summary["title"] = title


def _text(value: Any) -> str:
    return str(value or "").strip()


def _seconds(value: Any) -> float | None:
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    return seconds if seconds > 0 else None
