"""Lecture or presentation slides next to the transcript.

`deck` reads the text of each slide, `alignment` finds which slide was shown during
each part of the transcript, and `attach_slides` does both for a session so the
summary can follow the slides and the published note can group the transcript by them.
"""
from __future__ import annotations

from ..artifacts import MeetingArtifacts
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
