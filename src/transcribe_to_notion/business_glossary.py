from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class GlossaryEntry:
    """One line of the glossary file: `term, misheard variant, misheard variant`."""

    term: str
    variants: tuple[str, ...] = ()


def entries() -> tuple[GlossaryEntry, ...]:
    path = os.getenv("BUSINESS_GLOSSARY_FILE", "").strip()
    if not path:
        return ()
    try:
        lines = Path(path).expanduser().read_text(encoding="utf-8").splitlines()
    except OSError:
        return ()
    result: dict[str, GlossaryEntry] = {}
    for line in lines:
        parts = [part.strip() for part in line.split(",") if part.strip()]
        if not parts:
            continue
        term = parts[0]
        variants = tuple(
            dict.fromkeys(v for v in parts[1:] if v.casefold() != term.casefold())
        )
        result.setdefault(term, GlossaryEntry(term=term, variants=variants))
    return tuple(result.values())


def terms() -> tuple[str, ...]:
    """Correct spellings only: variants are known mistakes and must not be suggested."""
    return tuple(entry.term for entry in entries())


def apply_corrections(text: str, glossary: tuple[GlossaryEntry, ...] | None = None) -> str:
    glossary = entries() if glossary is None else glossary
    replacements = {
        variant.casefold(): entry.term
        for entry in glossary
        for variant in entry.variants
    }
    if not text or not replacements:
        return text
    # Longest first so "isi control" wins over a shorter overlapping variant.
    alternatives = sorted(replacements, key=len, reverse=True)
    pattern = re.compile(
        r"(?<!\w)(" + "|".join(re.escape(v) for v in alternatives) + r")(?!\w)",
        re.IGNORECASE,
    )
    return pattern.sub(lambda match: replacements[match.group(0).casefold()], text)


def summary_instructions() -> str:
    glossary = entries()
    if not glossary:
        return ""
    lines = [
        "Business glossary: use exactly these spellings when relevant: "
        + ", ".join(entry.term for entry in glossary)
        + ". Never invent acronyms or meanings."
    ]
    corrections = [
        f"{', '.join(repr(v) for v in entry.variants)} -> {entry.term!r}"
        for entry in glossary
        if entry.variants
    ]
    if corrections:
        lines.append(
            "The transcript may still contain these mishearings; always write the correct term instead: "
            + "; ".join(corrections)
            + "."
        )
    return "\n" + "\n".join(lines) + "\n"
