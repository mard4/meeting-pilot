"""Lecture or presentation slides next to the transcript.

`deck` reads the text of each slide, `alignment` finds which slide was shown during
each part of the transcript, and `attach_slides` does both for a session so the
summary can follow the slides and the published note can group the transcript by them.
`cite_slides` then shows which slide each key concept of the summary comes from.
"""
from __future__ import annotations

import re
from typing import Any

from ..artifacts import MeetingArtifacts
from ..language import label
from .alignment import align_transcript, write_alignment
from .deck import load_slides


def attach_slides(artifacts: MeetingArtifacts) -> None:
    """Loads the session's slides and places them along the transcript; a no-op for
    the many recordings without slides."""
    slides = load_slides(artifacts.session_dir)
    artifacts.slides = slides
    if not slides:
        artifacts.slide_sections = []
        return
    timed = artifacts.millet_json if isinstance(artifacts.millet_json, dict) else {}
    segments = timed.get("segments") if isinstance(timed.get("segments"), list) else None
    artifacts.slide_sections = align_transcript(slides, artifacts.transcript_text, segments)
    write_alignment(artifacts.session_dir, artifacts.slide_sections)
    matched = f"{len(artifacts.slide_sections)} sections" if artifacts.slide_sections else "not matched to the transcript"
    print(f"Slides: {len(slides)} pages, {matched}.", flush=True)


def cite_slides(artifacts: MeetingArtifacts, lang: str) -> None:
    """Writes the slide the summary gave each key concept as "(slide N)" after its
    explanation, so every destination shows it. Models follow a field more reliably
    than an instruction to cite inline."""
    summary = artifacts.omlx_summary
    if not summary or not artifacts.slides:
        return
    pages = {slide.page for slide in artifacts.slides}
    for concept in summary.get("key_concepts") or []:
        if not isinstance(concept, dict):
            continue
        page = _page_number(concept.get("slide"))
        if page not in pages:
            continue
        citation = f"({label(lang, 'slide')} {page})"
        explanation = str(concept.get("explanation") or "").strip()
        if citation not in explanation:
            concept["explanation"] = f"{explanation} {citation}".strip()


def _page_number(value: Any) -> int | None:
    """3, 3.0, "3" or "slide 3"; None for null and anything without a number."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    match = re.search(r"\d+", str(value))
    return int(match.group(0)) if match else None
