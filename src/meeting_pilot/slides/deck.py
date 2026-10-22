"""The slides shown during a lecture or presentation, as text per page.

The macOS app copies the PDF into the sidecar as `slides/slides.pdf` and writes its text
(with on-device OCR for pages that are only images) to `slides/slides.json`:

    {"source_name": "Lezione 7.pdf", "pages": [{"page": 1, "text": "..."}, ...]}

A PDF without `slides.json`, as the command line leaves it, is read here with PDFKit
through JavaScript for Automation, which every Mac has.

Slides can also come as another document (a PowerPoint deck, a Word file, notes in
Markdown, see `documents.py`), copied in as `slides/slides.<extension>`; the pipeline
writes their text to `slides.json` the first time it reads them. Only a PDF is copied
next to the published notes.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .documents import SUPPORTED_EXTENSIONS, extract_document_texts

SLIDES_FOLDER = "slides"
PDF_NAME = "slides.pdf"
TEXT_NAME = "slides.json"
# Written by the app for a video's screens (VideoScreens.swift): when each page was on screen.
SCREENS_NAME = "screens.json"
# One picture per slide, which Obsidian and Notion show beside what was said on it.
IMAGES_FOLDER = "images"
IMAGE_WIDTH = 1280
SOURCE_STEM = "slides"
# What can be attached as slides: a PDF, or a document read by `documents.py`.
SLIDES_EXTENSIONS = {".pdf"} | SUPPORTED_EXTENSIONS

_EXTRACT_SCRIPT = """
ObjC.import('PDFKit');
function run(argv) {
  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  if (!doc || doc.isNil()) return 'null';
  var pages = [];
  for (var i = 0; i < doc.pageCount; i++) {
    var text = doc.pageAtIndex(i).string;
    pages.push(text && !text.isNil() ? ObjC.unwrap(text) : '');
  }
  return JSON.stringify(pages);
}
"""

_RENDER_SCRIPT = """
ObjC.import('PDFKit');
ObjC.import('AppKit');
function run(argv) {
  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  if (!doc || doc.isNil()) return 'null';
  var width = parseFloat(argv[2]);
  var names = [];
  for (var i = 0; i < doc.pageCount; i++) {
    var page = doc.pageAtIndex(i);
    var bounds = page.boundsForBox($.kPDFDisplayBoxMediaBox);
    var size = $.NSMakeSize(width, width * bounds.size.height / bounds.size.width);
    var image = page.thumbnailOfSizeForBox(size, $.kPDFDisplayBoxMediaBox);
    var rep = $.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
    var data = rep.representationUsingTypeProperties($.NSBitmapImageFileTypeJPEG, $({NSImageCompressionFactor: 0.85}));
    var name = 'slide-' + (i + 1) + '.jpg';
    if (!data.writeToFileAtomically(argv[1] + '/' + name, true)) return 'null';
    names.push(name);
  }
  return JSON.stringify(names);
}
"""


@dataclass(frozen=True)
class Slide:
    page: int
    title: str
    text: str

    def to_dict(self) -> dict[str, Any]:
        return {"page": self.page, "title": self.title, "text": self.text}


@dataclass(frozen=True)
class Screen:
    page: int
    start: float
    end: float


def load_screens(session_dir: Path) -> list[Screen]:
    """When each screen of an imported video was visible; empty for slides and documents."""
    try:
        payload = json.loads((slides_dir(session_dir) / SCREENS_NAME).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    screens = []
    for item in payload.get("screens") or [] if isinstance(payload, dict) else []:
        try:
            screens.append(Screen(page=int(item["page"]), start=float(item["start"]), end=float(item["end"])))
        except (KeyError, TypeError, ValueError):
            continue
    return sorted(screens, key=lambda screen: screen.start)


def slides_dir(session_dir: Path) -> Path:
    return session_dir / "sidecar" / SLIDES_FOLDER


def slides_pdf(session_dir: Path) -> Path | None:
    """The session's slides PDF, which publishers copy next to the note."""
    pdf = slides_dir(session_dir) / PDF_NAME
    return pdf if pdf.is_file() else None


def slide_images(session_dir: Path) -> dict[int, Path]:
    """A JPEG of each page of the session's slides PDF by page number, drawn once with
    PDFKit through JavaScript for Automation and kept in the sidecar; empty without a PDF
    or when it cannot be drawn, and the notes then link the PDF only."""
    pdf = slides_pdf(session_dir)
    if pdf is None:
        return {}
    folder = slides_dir(session_dir) / IMAGES_FOLDER
    images = {int(path.stem.rsplit("-", 1)[-1]): path for path in folder.glob("slide-*.jpg")}
    if images and min(path.stat().st_mtime for path in images.values()) >= pdf.stat().st_mtime:
        return dict(sorted(images.items()))
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-", str(pdf), str(folder), str(IMAGE_WIDTH)],
            input=_RENDER_SCRIPT,
            capture_output=True,
            text=True,
            check=False,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"Slide pictures not drawn: {exc}")
        shutil.rmtree(folder, ignore_errors=True)
        return {}
    try:
        names = json.loads(result.stdout or "null")
    except json.JSONDecodeError:
        names = None
    if not isinstance(names, list):
        print(f"Slide pictures not drawn: {(result.stderr or 'not a PDF').strip()}")
        shutil.rmtree(folder, ignore_errors=True)
        return {}
    return {page: folder / str(name) for page, name in enumerate(names, 1)}


def is_slides_file(path: Path) -> bool:
    return path.suffix.lower() in SLIDES_EXTENSIONS


def copy_slides_source(source: Path, folder: Path) -> Path:
    """Copies a PDF or document into a sidecar's slides folder as `slides.<extension>`."""
    if not is_slides_file(source):
        supported = ", ".join(sorted(SLIDES_EXTENSIONS))
        raise ValueError(f"Unsupported slides format: {source.name} (supported: {supported})")
    folder.mkdir(parents=True, exist_ok=True)
    copy = folder / (PDF_NAME if source.suffix.lower() == ".pdf" else f"{SOURCE_STEM}{source.suffix.lower()}")
    shutil.copy2(source, copy)
    return copy


def slides_source(folder: Path) -> Path | None:
    """The PDF or document the slides were read from."""
    pdf = folder / PDF_NAME
    if pdf.is_file():
        return pdf
    return next(
        (path for path in sorted(folder.glob(f"{SOURCE_STEM}.*")) if path.name != TEXT_NAME and is_slides_file(path)),
        None,
    )


def load_slides(session_dir: Path) -> list[Slide]:
    """The session's slides, or an empty list when it has none."""
    folder = slides_dir(session_dir)
    try:
        payload = json.loads((folder / TEXT_NAME).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        payload = None
    if isinstance(payload, dict) and isinstance(payload.get("pages"), list):
        texts = [str(page.get("text") or "") for page in payload["pages"] if isinstance(page, dict)]
        return slides_from_texts(texts)
    source = slides_source(folder)
    if source is None:
        return []
    texts = extract_pdf_texts(source) if source.suffix.lower() == ".pdf" else extract_document_texts(source)
    (folder / TEXT_NAME).write_text(
        json.dumps({"source_name": source.name, "pages": [{"page": i, "text": t} for i, t in enumerate(texts, 1)]},
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return slides_from_texts(texts)


def extract_pdf_texts(pdf: Path) -> list[str]:
    try:
        result = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-", str(pdf)],
            input=_EXTRACT_SCRIPT,
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Cannot read the slides in {pdf.name}: {exc}") from exc
    try:
        pages = json.loads(result.stdout or "null")
    except json.JSONDecodeError:
        pages = None
    if result.returncode != 0 or not isinstance(pages, list):
        raise RuntimeError(f"Cannot read the slides in {pdf.name}: {(result.stderr or 'not a PDF').strip()}")
    return [str(text or "") for text in pages]


def slides_from_texts(texts: list[str]) -> list[Slide]:
    return [Slide(page=index, title=_title(text), text=_clean(text)) for index, text in enumerate(texts, start=1)]


def slide_outline(slides: list[Slide], compact: bool = False, spread: bool = False) -> str:
    """One line per slide for the summary prompt. `compact` keeps only titles, for the
    small context of the on-device model. `spread`, for the screens of a video, shares the
    budget over the whole video instead of filling it from the start: a long tutorial
    would otherwise lose its second half."""
    budget = 1_500 if compact else 20_000
    if spread and slides:
        return _spread_outline(slides, budget, compact)
    lines: list[str] = []
    used = 0
    for slide in slides:
        line = f"Slide {slide.page}: {slide.title or '—'}"
        body = slide.text[len(slide.title):].strip() if slide.text.startswith(slide.title) else slide.text
        if not compact and body:
            line += " — " + " ".join(body.split())[:600]
        if used + len(line) > budget:
            lines.append(f"(slides {slide.page}–{slides[-1].page} omitted)")
            break
        lines.append(line)
        used += len(line) + 1
    return "\n".join(lines)


# The shortest line worth giving a screen: its title, and a few words of it.
_MIN_SCREEN_LINE = {True: 40, False: 140}


def _spread_outline(slides: list[Slide], budget: int, compact: bool) -> str:
    count = max(1, min(len(slides), budget // _MIN_SCREEN_LINE[compact]))
    if count >= len(slides):
        chosen = slides
    else:
        # Evenly in the video's order, first and last included.
        picks = sorted({round(index * (len(slides) - 1) / max(count - 1, 1)) for index in range(count)})
        chosen = [slides[index] for index in picks]
    width = budget // len(chosen) - 1
    lines = []
    for slide in chosen:
        line = f"Slide {slide.page}: {slide.title or '—'}"
        body = slide.text[len(slide.title):].strip() if slide.text.startswith(slide.title) else slide.text
        if not compact and body:
            line += " — " + " ".join(body.split())
        lines.append(line[:width])
    if len(chosen) < len(slides):
        lines.append(f"({len(chosen)} of {len(slides)} screens shown, evenly through the video)")
    return "\n".join(lines)


def slide_terms(slides: list[Slide], limit: int = 100) -> list[str]:
    """Names, acronyms and technical words from the slides, which speech recognition
    tends to misspell: short titles, acronyms, words mixing letters and digits, and
    capitalized words that do not merely start a bullet."""
    counts: Counter[str] = Counter()
    for slide in slides:
        if slide.title and len(slide.title.split()) <= 4:
            counts[slide.title] += 2
        for line in slide.text.splitlines():
            for index, word in enumerate(re.findall(r"[^\W_][\w'’/-]*[^\W_]", line)):
                acronym = word.isupper() and len(word) >= 2
                mixed = any(ch.isdigit() for ch in word) and any(ch.isalpha() for ch in word)
                name = index > 0 and word[0].isupper() and len(word) >= 3
                if acronym or mixed or name:
                    counts[word] += 1
    return [word for word, _ in counts.most_common(limit)]


def _title(text: str) -> str:
    for line in text.splitlines():
        line = " ".join(line.split())
        if len(line) >= 2:
            return line[:120]
    return ""


def _clean(text: str) -> str:
    return "\n".join(" ".join(line.split()) for line in text.splitlines() if line.strip())

