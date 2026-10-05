"""Which slide was on screen during each part of the transcript.

Each sentence of the transcript is compared with every slide, alone and together with
about `CONTEXT_WORDS` words on either side of it, by the words they share (TF-IDF, so a course
name in every footer counts for little). The most likely sequence of slides is then
chosen with dynamic programming: staying on a slide is free, moving to the next one
costs a little, skipping ahead or going back costs more. A lecture that barely uses its
slides gets no sections rather than wrong ones.

Everything runs locally and deterministically, without a language model.
"""
from __future__ import annotations

import json
import math
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .deck import Slide

ALIGNMENT_NAME = "slide_alignment.json"
# Words of transcript on each side of a sentence scored with it: enough to recognize a
# slide, little enough to follow one shown for half a minute.
CONTEXT_WORDS = 30
# A transcript without punctuation is cut into pieces of this many words.
MAX_UNIT_WORDS = 40
# A sentence "matches" a slide above this cosine similarity; below `MIN_MATCHED_SHARE`
# of matching sentences the slides are judged unrelated to what was said.
MATCH_SCORE = 0.12
MIN_MATCHED_SHARE = 0.3

START_COST = 0.02
NEXT_COST = 0.06
SKIP_COST = 0.04
BACK_COST = 0.3

_TOKEN = re.compile(r"[^\W\d_]{3,}|\d{2,}")
_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")


@dataclass
class TranscriptUnit:
    text: str
    speaker: str | None = None
    start: float | None = None
    # The first sentence of a transcript line, so sections keep the transcript's breaks.
    starts_line: bool = False

    @property
    def words(self) -> int:
        return len(self.text.split())


@dataclass
class SlideSection:
    page: int
    title: str
    start: float | None = None
    units: list[TranscriptUnit] = field(default_factory=list)

    def lines(self) -> list[str]:
        """The section's transcript, with the full transcript's line breaks and speakers."""
        lines: list[str] = []
        speaker: str | None = None
        for unit in self.units:
            if lines and unit.speaker == speaker and not unit.starts_line:
                lines[-1] += " " + unit.text
            else:
                lines.append(f"{unit.speaker}: {unit.text}" if unit.speaker else unit.text)
                speaker = unit.speaker
        return lines

    def to_dict(self) -> dict[str, Any]:
        return {"page": self.page, "title": self.title, "start": self.start, "lines": self.lines()}


def align_transcript(
    slides: list[Slide], transcript: str, segments: list[dict[str, Any]] | None = None
) -> list[SlideSection]:
    """Consecutive transcript sections, each with the slide shown meanwhile; empty when
    the slides do not match what was said."""
    units = transcript_units(transcript, segments)
    if not slides or not units:
        return []
    scorer = _Scorer(slides)
    # The sentence itself weighs as much as its context, so a change of slide falls on
    # the sentence where the subject changes rather than one before it.
    scores = [
        [(own + around) / 2 for own, around in zip(scorer.scores(unit.text), scorer.scores(_context(units, index)))]
        for index, unit in enumerate(units)
    ]
    matched = sum(1 for row in scores if max(row) >= MATCH_SCORE)
    if matched / len(scores) < MIN_MATCHED_SHARE:
        return []
    sections: list[SlideSection] = []
    for unit, index in zip(units, _best_path(scores)):
        slide = slides[index]
        if not sections or sections[-1].page != slide.page:
            sections.append(SlideSection(page=slide.page, title=slide.title, start=unit.start))
        sections[-1].units.append(unit)
    return sections


def transcript_units(transcript: str, segments: list[dict[str, Any]] | None = None) -> list[TranscriptUnit]:
    """Sentences of the transcript with their speaker and, from FluidAudio's segments,
    an estimate of when each started. The published transcript has one
    `Speaker: text` line per segment; without segments there are no speakers to trust."""
    lines = [line.strip() for line in transcript.splitlines() if line.strip()]
    timed = segments if segments and len(segments) == len(lines) else None
    units: list[TranscriptUnit] = []
    for index, line in enumerate(lines):
        speaker = None
        start = end = None
        if timed:
            segment = timed[index]
            speaker = str(segment.get("speaker") or "") or None
            prefix = f"{speaker}: " if speaker else ""
            if prefix and line.startswith(prefix):
                line = line[len(prefix):]
            start, end = _number(segment.get("start")), _number(segment.get("end"))
        sentences = [part for part in _SENTENCE_END.split(line) if part.strip()]
        total = sum(len(part.split()) for part in sentences) or 1
        offset = 0
        for sentence in sentences:
            for piece in _pieces(sentence):
                when = None
                if start is not None and end is not None:
                    when = round(start + (end - start) * offset / total, 2)
                units.append(TranscriptUnit(text=piece, speaker=speaker, start=when, starts_line=offset == 0))
                offset += len(piece.split())
    return units


def write_alignment(session_dir: Path, sections: list[SlideSection]) -> None:
    path = session_dir / ALIGNMENT_NAME
    if not sections:
        path.unlink(missing_ok=True)
        return
    path.write_text(
        json.dumps({"sections": [section.to_dict() for section in sections]}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _pieces(sentence: str) -> list[str]:
    """A transcript without punctuation is one endless sentence; cut it into pieces."""
    words = sentence.split()
    if len(words) <= MAX_UNIT_WORDS:
        return [sentence.strip()]
    return [" ".join(words[i:i + MAX_UNIT_WORDS]) for i in range(0, len(words), MAX_UNIT_WORDS)]


def _context(units: list[TranscriptUnit], index: int) -> str:
    """A sentence with about `CONTEXT_WORDS` words before and after it."""
    first, words = index, 0
    while first > 0 and words < CONTEXT_WORDS:
        first -= 1
        words += units[first].words
    last, words = index, 0
    while last < len(units) - 1 and words < CONTEXT_WORDS:
        last += 1
        words += units[last].words
    return " ".join(unit.text for unit in units[first:last + 1])


class _Scorer:
    """Cosine similarity between a piece of transcript and each slide, over the slides'
    own vocabulary weighted by TF-IDF."""

    def __init__(self, slides: list[Slide]):
        pages = [Counter(_stems(slide.title) * 2 + _stems(slide.text)) for slide in slides]
        frequency = Counter(stem for counts in pages for stem in counts)
        self.idf = {stem: math.log((len(pages) + 1) / (count + 1)) + 1 for stem, count in frequency.items()}
        self.pages = [self._vector(counts) for counts in pages]

    def scores(self, text: str) -> list[float]:
        vector = self._vector(Counter(stem for stem in _stems(text) if stem in self.idf))
        return [sum(weight * page.get(stem, 0.0) for stem, weight in vector.items()) for page in self.pages]

    def _vector(self, counts: Counter[str]) -> dict[str, float]:
        return _normalized({stem: (1 + math.log(n)) * self.idf[stem] for stem, n in counts.items()})


def _best_path(scores: list[list[float]]) -> list[int]:
    """The slide sequence with the highest total similarity minus the cost of moving.

    Moving costs grow linearly with the distance, so the best slide to arrive from is a
    running maximum: linear in the number of slides instead of quadratic.
    """
    pages = len(scores[0])
    totals = [scores[0][page] - START_COST * page for page in range(pages)]
    pointers: list[list[int]] = []
    for row in scores[1:]:
        ahead = _running_best([(totals[page] + SKIP_COST * page, page) for page in range(pages)])
        behind = _running_best([(totals[page] - SKIP_COST * page, page) for page in reversed(range(pages))])[::-1]
        current, back = [], []
        for page in range(pages):
            options = [(totals[page], page)]
            if ahead[page] is not None:
                value, origin = ahead[page]
                options.append((value - NEXT_COST - SKIP_COST * (page - 1), origin))
            if behind[page] is not None:
                value, origin = behind[page]
                options.append((value - BACK_COST + SKIP_COST * (page + 1), origin))
            # On a tie the slide stays, which is listed first.
            value, origin = max(options, key=lambda option: option[0])
            current.append(value + row[page])
            back.append(origin)
        totals = current
        pointers.append(back)
    page = max(range(pages), key=lambda index: totals[index])
    path = [page]
    for back in reversed(pointers):
        page = back[page]
        path.append(page)
    return list(reversed(path))


def _running_best(values: list[tuple[float, int]]) -> list[tuple[float, int] | None]:
    """For each (value, page), the best (value, page) before it; None for the first."""
    result: list[tuple[float, int] | None] = []
    best: tuple[float, int] | None = None
    for value, page in values:
        result.append(best)
        if best is None or value > best[0]:
            best = (value, page)
    return result


def _move_cost(before: int, after: int) -> float:
    if after == before:
        return 0.0
    if after == before + 1:
        return NEXT_COST
    if after > before:
        return NEXT_COST + SKIP_COST * (after - before - 1)
    return BACK_COST + SKIP_COST * (before - after - 1)


def _stems(text: str) -> list[str]:
    """Content words cut to six letters: a cheap stem that matches "integrale" with
    "integrali" and "entropy" with "entropie" in any of the app's languages."""
    words = (match.group(0).casefold() for match in _TOKEN.finditer(text))
    return [word[:6] for word in words if word not in STOPWORDS]


def _normalized(vector: dict[str, float]) -> dict[str, float]:
    norm = math.sqrt(sum(weight * weight for weight in vector.values()))
    return {stem: weight / norm for stem, weight in vector.items()} if norm else {}


def _number(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


STOPWORDS = frozenset(
    # Italian
    "che chi cui con per tra fra del della delle dei degli dello dal dalla dai dalle nel nella nei nelle "
    "sul sulla sui sulle una uno gli lei lui loro noi voi questo questa questi queste quello quella quelli "
    "sono sei siamo siete era erano essere stato stata fare fatto come anche ancora molto più poi quando "
    "dove perché perche allora quindi però pero cosa qui qua già gia non ogni tutto tutti tutta tutte "
    "abbiamo hanno avere vediamo adesso ora oggi bene okay "
    # English
    "the and for with that this these those from have has had are was were been being you your our "
    "they them their there here what which who whom when where why how not but all any can will would "
    "should could into onto about then than also just very more most some such only now today okay well "
    # French
    "les des une est sont avec pour dans par pas plus que qui sur ces cette mais nous vous ils elles "
    # German
    "der die das und ist sind mit für fur von den dem des ein eine einer nicht auch auf aus bei wir "
    # Spanish and Portuguese
    "los las una por para con del como pero más mas que este esta estos estas son está esta não nao "
    "uma com por para dos das como mas são sao isso esse essa "
    # Dutch
    "het een van voor met zijn niet ook maar wat als bij nog wel deze die dat".split()
)
