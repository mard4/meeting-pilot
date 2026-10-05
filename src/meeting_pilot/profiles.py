"""Work or study: which kind of notes a recording becomes.

USER_PROFILE says who uses the app: "worker", "student" or "both". Every recording is
then either a work meeting or a lecture, and that decides the summary sections the
model writes and the publishers render.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

WORKER = "worker"
STUDENT = "student"
BOTH = "both"

# Matched against the meeting title when the user is both a student and a worker.
# Words that also name ordinary work meetings ("prova", "class", "lab", "in corso") are left out;
# the live sidebar can still switch any single recording.
STUDENT_KEYWORDS = (
    # Italian
    "lezione", "lezioni", "corso di", "esercitazione", "esercitazioni", "seminario", "laboratorio",
    "esame", "ricevimento", "tutorato", "università", "universita", "tesi",
    # English
    "lecture", "lectures", "lesson", "course", "seminar", "exam", "office hours", "study group",
    "thesis", "university",
    # French
    "examen", "séminaire", "université",
    # German
    "vorlesung", "übung", "prüfung", "universität",
    # Spanish
    "clase", "asignatura", "universidad", "tutoría",
    # Portuguese
    "aula", "disciplina", "seminário", "universidade",
    # Dutch
    "hoorcollege", "werkcollege", "tentamen", "universiteit",
)


def user_profile(config: object) -> str:
    value = str(getattr(config, "user_profile", WORKER) or WORKER).strip().lower()
    return value if value in {WORKER, STUDENT, BOTH} else WORKER


def resolve_profile(config: object, session_dir: Path, meeting_metadata: dict[str, Any], title: str) -> str:
    """Per-meeting choice from the live sidebar, then the user's only profile, then a
    keyword match on the meeting title, then work."""
    choice = _sidecar_choice(session_dir)
    if choice in {WORKER, STUDENT}:
        return choice
    profile = user_profile(config)
    if profile != BOTH:
        return profile
    titles = [
        str(value)
        for value in (meeting_metadata.get("title"), meeting_metadata.get("subject"), title)
        if value
    ]
    if any(_keyword_matches(keyword, text) for keyword in STUDENT_KEYWORDS for text in titles):
        return STUDENT
    return WORKER


def artifacts_profile(config: object, artifacts: object) -> str:
    """The profile a summary was written for, or the one this recording resolves to."""
    summary = getattr(artifacts, "omlx_summary", None) or {}
    if summary.get("profile") in {WORKER, STUDENT}:
        return summary["profile"]
    return resolve_profile(
        config,
        artifacts.session_dir,
        getattr(artifacts, "meeting_metadata", None) or {},
        getattr(artifacts, "title", ""),
    )


def _sidecar_choice(session_dir: Path) -> str:
    try:
        payload = json.loads((session_dir / "sidecar" / "profile.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    return str(payload.get("profile") or "").strip() if isinstance(payload, dict) else ""


def _keyword_matches(keyword: str, text: str) -> bool:
    # Word boundaries so "esame" matches "Esame di Fisica" but not "riesame".
    pattern = r"(?<![\w])" + re.escape(keyword.casefold()) + r"(?![\w])"
    return re.search(pattern, text.casefold()) is not None
