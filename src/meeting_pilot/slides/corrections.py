"""Spellings the slides correct in a transcript.

Speech recognition mishears names and technical words it has never seen ("Cubernetes",
"Kuber netes" for Kubernetes). Once the slides are known, a transcript word that is not
on any slide but is very close to one of their names, acronyms or technical words is
taken as a mishearing of it. The corrections are saved beside the slides as
`slides/corrections.json` (`{"misheard": "Correct"}`) and applied whenever the session's
transcript is read, so the transcription files themselves stay as they came out.
"""
from __future__ import annotations

import json
import re
from collections.abc import Iterable
from difflib import SequenceMatcher
from pathlib import Path

from .deck import Slide, slide_terms, slides_dir

CORRECTIONS_NAME = "corrections.json"

# Close enough to be the same word misheard, far enough apart to leave unrelated words alone.
_MIN_SIMILARITY = 0.84
_MIN_LENGTH = 5
_WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*")


def find_corrections(transcript: str, slides: list[Slide]) -> dict[str, str]:
    """Each misheard spelling in the transcript, with the slide term it stands for."""
    terms = [
        term for term in slide_terms(slides, limit=300)
        if " " not in term and len(term) >= _MIN_LENGTH and _WORD.fullmatch(term)
    ]
    if not terms or not transcript.strip():
        return {}
    on_slides = {word.casefold() for slide in slides for word in _WORD.findall(slide.text)}
    corrections: dict[str, str] = {}
    words = list(dict.fromkeys(_WORD.findall(transcript)))
    for heard in words:
        if len(heard) >= _MIN_LENGTH and heard.casefold() not in on_slides:
            term = _closest(heard, terms)
            if term:
                corrections[heard] = _cased_like(heard, term)
    # A word split in two ("Kuber netes"): only halves that are neither words of the
    # slides, nor already corrected, nor short words like "e" or "il" next to a term.
    spoken = _WORD.findall(transcript)
    for left, right in zip(spoken, spoken[1:]):
        heard = f"{left} {right}"
        if heard in corrections or min(len(left), len(right)) < 3:
            continue
        if any(half.casefold() in on_slides or half in corrections for half in (left, right)):
            continue
        term = _closest(heard, terms)
        if term:
            corrections[heard] = _cased_like(heard, term)
    return corrections


def save_corrections(session_dir: Path, corrections: dict[str, str]) -> None:
    path = slides_dir(session_dir) / CORRECTIONS_NAME
    if corrections:
        path.write_text(json.dumps(corrections, ensure_ascii=False, indent=2), encoding="utf-8")
    else:
        path.unlink(missing_ok=True)


def load_corrections(session_dir: Path) -> dict[str, str]:
    try:
        payload = json.loads((slides_dir(session_dir) / CORRECTIONS_NAME).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    return {str(heard): str(term) for heard, term in payload.items() if str(heard).strip() and str(term).strip()}


def _closest(heard: str, terms: Iterable[str]) -> str | None:
    spaced = " " in heard
    joined = heard.replace(" ", "").casefold()
    best, best_score = None, _MIN_SIMILARITY
    for term in terms:
        wanted = term.casefold()
        if spaced and joined == wanted:
            return term
        if abs(len(wanted) - len(joined)) > 3 or (not spaced and _same_word_inflected(joined, wanted)):
            continue
        score = SequenceMatcher(None, joined, wanted).ratio()
        if score >= best_score:
            best, best_score = term, score
    return best


def _cased_like(heard: str, term: str) -> str:
    """"work space" becomes "workspace", not "Workspace", when the slide only capitalized
    it as a title; names and acronyms keep their own capitals."""
    if heard[:1].islower() and term[:1].isupper() and term[1:].islower():
        return term[:1].lower() + term[1:]
    return term


def _same_word_inflected(heard: str, term: str) -> bool:
    """"modello" and "modelli", "sistema" and "sistemi": the same word, not a mishearing."""
    if heard == term:
        return True
    shared = 0
    for a, b in zip(heard, term):
        if a != b:
            break
        shared += 1
    return len(heard) - shared <= 2 and len(term) - shared <= 2
