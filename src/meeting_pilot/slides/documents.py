"""Text per page of the documents that can stand in for a slides PDF: a PowerPoint or
LibreOffice deck, a Word or LibreOffice document, notes in plain text or Markdown.

Decks have slides, so each slide is a page. Documents have no fixed pages, so they are
split where the author broke the page (or where Word last laid one out), at Markdown
headings, and into parts of about `PART_CHARS` when a stretch runs longer, so the parts
can be placed along the transcript like slides.

Office files are zip archives of XML and are read with the standard library; RTF and old
Word files go through `textutil`, which every Mac has.
"""
from __future__ import annotations

import re
import subprocess
import zipfile
from pathlib import Path
from xml.etree import ElementTree

# Extensions read here; `.pdf` is read by `deck.extract_pdf_texts`.
DECK_EXTENSIONS = {".pptx", ".odp"}
DOCUMENT_EXTENSIONS = {".docx", ".odt", ".rtf", ".doc", ".txt", ".md", ".markdown"}
SUPPORTED_EXTENSIONS = DECK_EXTENSIONS | DOCUMENT_EXTENSIONS

PART_CHARS = 1_500
PAGE_BREAK = "\f"

_A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
_W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
_TEXT = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"
_DRAW = "{urn:oasis:names:tc:opendocument:xmlns:drawing:1.0}"
_OFFICE = "{urn:oasis:names:tc:opendocument:xmlns:office:1.0}"


def extract_document_texts(path: Path) -> list[str]:
    """The text of each slide of a deck, or of each part of a document."""
    suffix = path.suffix.lower()
    try:
        if suffix == ".pptx":
            return _pptx_slides(path)
        if suffix == ".odp":
            return _odp_slides(path)
        if suffix == ".docx":
            return split_document(_docx_text(path))
        if suffix == ".odt":
            return split_document(_odt_text(path))
        if suffix in {".rtf", ".doc"}:
            return split_document(_textutil_text(path))
        if suffix in {".txt", ".md", ".markdown"}:
            return split_document(path.read_text(encoding="utf-8", errors="replace"), markdown=suffix != ".txt")
    except (OSError, zipfile.BadZipFile, KeyError, ElementTree.ParseError) as exc:
        raise RuntimeError(f"Cannot read the slides in {path.name}: {exc}") from exc
    raise RuntimeError(f"Cannot read the slides in {path.name}: unsupported format")


def split_document(text: str, markdown: bool = False) -> list[str]:
    """Pages of a document without slides: at page breaks, before Markdown headings,
    and at paragraph ends once a part reaches `PART_CHARS`."""
    parts: list[str] = []
    for page in text.split(PAGE_BREAK):
        sections = re.split(r"(?m)^(?=#{1,6}\s)", page) if markdown else [page]
        for section in sections:
            parts.extend(_paragraph_parts(section))
    return [part for part in parts if part.strip()] or [""]


def _paragraph_parts(text: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    size = 0
    for paragraph in re.split(r"\n\s*\n", text.strip()):
        if current and size + len(paragraph) > PART_CHARS:
            parts.append("\n\n".join(current))
            current, size = [], 0
        current.append(paragraph.strip())
        size += len(paragraph)
    if current:
        parts.append("\n\n".join(current))
    return parts


def _pptx_slides(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if re.fullmatch(r"ppt/slides/slide\d+\.xml", name)]
        # The archive's own order is not the deck's; slide numbers are, unless the user
        # reordered slides, which only `presentation.xml` records.
        order = _pptx_order(archive) or sorted(names, key=lambda name: int(re.findall(r"\d+", name)[-1]))
        slides = []
        for name in order:
            root = ElementTree.fromstring(archive.read(name))
            lines = ["".join(run.text or "" for run in paragraph.iter(f"{_A}t")) for paragraph in root.iter(f"{_A}p")]
            slides.append("\n".join(line for line in lines if line.strip()))
        return slides


def _pptx_order(archive: zipfile.ZipFile) -> list[str]:
    """Slide files in presentation order, from `presentation.xml` and its relationships."""
    try:
        presentation = ElementTree.fromstring(archive.read("ppt/presentation.xml"))
        relationships = ElementTree.fromstring(archive.read("ppt/_rels/presentation.xml.rels"))
    except (KeyError, ElementTree.ParseError):
        return []
    targets = {rel.get("Id"): rel.get("Target", "") for rel in relationships}
    relation = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
    order = []
    for slide in presentation.iter("{http://schemas.openxmlformats.org/presentationml/2006/main}sldId"):
        target = targets.get(slide.get(relation), "")
        name = "ppt/" + target.lstrip("/").removeprefix("ppt/")
        if name in archive.namelist():
            order.append(name)
    return order


def _odp_slides(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        root = ElementTree.fromstring(archive.read("content.xml"))
    slides = []
    for page in root.iter(f"{_DRAW}page"):
        lines = [_odf_text(paragraph) for paragraph in page.iter() if paragraph.tag in {f"{_TEXT}p", f"{_TEXT}h"}]
        slides.append("\n".join(line for line in lines if line.strip()))
    return slides


def _docx_text(path: Path) -> str:
    """Paragraphs separated by blank lines, with a form feed where a page ends."""
    with zipfile.ZipFile(path) as archive:
        root = ElementTree.fromstring(archive.read("word/document.xml"))
    body = root.find(f"{_W}body")
    paragraphs: list[str] = []
    for paragraph in body.iter(f"{_W}p") if body is not None else []:
        text = ""
        for node in paragraph.iter():
            if node.tag == f"{_W}t":
                text += node.text or ""
            elif node.tag == f"{_W}tab":
                text += " "
            elif node.tag == f"{_W}br" and node.get(f"{_W}type") == "page":
                text += PAGE_BREAK
            elif node.tag == f"{_W}br":
                text += "\n"
            elif node.tag == f"{_W}lastRenderedPageBreak" and (text.strip() or paragraphs):
                text += PAGE_BREAK
        paragraphs.append(text)
    return _join_paragraphs(paragraphs)


def _odt_text(path: Path) -> str:
    with zipfile.ZipFile(path) as archive:
        root = ElementTree.fromstring(archive.read("content.xml"))
    text_body = root.find(f"{_OFFICE}body/{_OFFICE}text")
    paragraphs = []
    for node in text_body.iter() if text_body is not None else []:
        if node.tag in {f"{_TEXT}p", f"{_TEXT}h"}:
            paragraphs.append(_odf_text(node))
        elif node.tag == f"{_TEXT}soft-page-break":
            paragraphs.append(PAGE_BREAK)
    return _join_paragraphs(paragraphs)


def _odf_text(node: ElementTree.Element) -> str:
    """A paragraph's text, with the spaces, tabs and line breaks ODF writes as elements."""
    text = node.text or ""
    for child in node:
        if child.tag == f"{_TEXT}s":
            text += " " * int(child.get(f"{_TEXT}c", "1"))
        elif child.tag == f"{_TEXT}tab":
            text += " "
        elif child.tag == f"{_TEXT}line-break":
            text += "\n"
        elif child.tag not in {f"{_TEXT}p", f"{_TEXT}h"}:
            text += _odf_text(child)
        text += child.tail or ""
    return text


def _join_paragraphs(paragraphs: list[str]) -> str:
    text = "\n\n".join(paragraph for paragraph in paragraphs if paragraph.strip() or PAGE_BREAK in paragraph)
    return re.sub(r"\s*\f\s*", PAGE_BREAK, text)


def _textutil_text(path: Path) -> str:
    try:
        result = subprocess.run(
            ["/usr/bin/textutil", "-convert", "txt", "-stdout", str(path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise OSError(f"textutil failed: {exc}") from exc
    if result.returncode != 0:
        raise OSError((result.stderr or "textutil failed").strip())
    return result.stdout
