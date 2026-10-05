from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .business_glossary import apply_corrections as apply_glossary_corrections


@dataclass
class MeetingArtifacts:
    session_dir: Path
    audio_file: Path
    title: str
    transcript_text: str = ""
    summary_markdown: str = ""
    frontmatter: dict[str, Any] = field(default_factory=dict)
    millet_json: dict[str, Any] | list[Any] | None = None
    omlx_summary: dict[str, Any] | None = None
    meeting_metadata: dict[str, Any] = field(default_factory=dict)
    # Where the audio will live once the session is archived; None when it is deleted.
    archived_audio_file: Path | None = None
    # Notes the user typed in the live sidebar during the meeting.
    user_notes: str = ""
    # Slides shown during the recording (slides.deck.Slide) and the transcript grouped
    # by the slide shown meanwhile (slides.alignment.SlideSection); empty without slides.
    slides: list[Any] = field(default_factory=list)
    slide_sections: list[Any] = field(default_factory=list)


def collect_artifacts(session_dir: Path, audio_file: Path) -> MeetingArtifacts:
    frontmatter = _read_first_json(session_dir.glob("*.frontmatter.json")) or {}
    # FluidAudio emits both raw ASR and diarization files. The combined result
    # is the one publishers need because it contains the labelled speakers.
    millet_json = _read_json(session_dir / "fluidaudio_transcript.json") or _read_first_json(session_dir.glob("*.json"))
    summary_markdown = _read_first_text(session_dir.glob("*.summary.md"))
    transcript_text = apply_glossary_corrections(_read_transcript_text(session_dir))
    title = str(frontmatter.get("title") or session_dir.name)

    return MeetingArtifacts(
        session_dir=session_dir,
        audio_file=audio_file,
        title=title,
        transcript_text=transcript_text,
        summary_markdown=summary_markdown,
        frontmatter=frontmatter,
        millet_json=millet_json,
        user_notes=_read_first_text([session_dir / "sidecar" / "notes.md"]).strip(),
    )


def write_omlx_summary(session_dir: Path, summary: dict[str, Any]) -> Path:
    path = session_dir / "omlx_summary.json"
    path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def write_notion_receipt(session_dir: Path, payload: dict[str, Any]) -> Path:
    path = session_dir / "notion_receipt.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def write_obsidian_receipt(session_dir: Path, payload: dict[str, Any]) -> Path:
    path = session_dir / "obsidian_receipt.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def write_journal_receipt(session_dir: Path, payload: dict[str, Any]) -> Path:
    path = session_dir / "journal_receipt.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def write_meeting_metadata(session_dir: Path, metadata: dict[str, Any]) -> Path:
    path = session_dir / "meeting_metadata.json"
    path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def _read_first_json(paths) -> dict[str, Any] | list[Any] | None:
    for path in sorted(paths):
        if path.name.endswith(".summary.meta.json"):
            continue
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
    return None


def _read_json(path: Path) -> dict[str, Any] | list[Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _read_first_text(paths) -> str:
    for path in sorted(paths):
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            continue
    return ""


def _read_transcript_text(session_dir: Path) -> str:
    candidates = [
        path
        for path in session_dir.glob("*.txt")
        if not path.name.endswith(".ffmpeg.log")
    ]
    text = _read_first_text(candidates)
    if text:
        return text

    json_path = next(iter(sorted(session_dir.glob("*.json"))), None)
    if not json_path:
        return ""
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    return _transcript_from_json(data)


def _transcript_from_json(data: Any) -> str:
    if isinstance(data, dict):
        segments = data.get("segments") or data.get("transcript")
    else:
        segments = data
    if not isinstance(segments, list):
        return ""

    lines = []
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        speaker = segment.get("speaker") or segment.get("label") or "Speaker"
        text = str(segment.get("text") or "").strip()
        start = segment.get("start")
        end = segment.get("end")
        if not text:
            continue
        if start is not None and end is not None:
            lines.append(f"[{start} --> {end}] {speaker}: {text}")
        else:
            lines.append(f"{speaker}: {text}")
    return "\n".join(lines)
