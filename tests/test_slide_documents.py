from __future__ import annotations

import json
import zipfile
from pathlib import Path
from types import SimpleNamespace
from xml.sax.saxutils import escape

import pytest

from meeting_pilot.media_import import import_media_file
from meeting_pilot.slides.deck import copy_slides_source, load_slides, slides_source
from meeting_pilot.slides.documents import PART_CHARS, extract_document_texts, split_document
from meeting_pilot.transcription.session import sidecar_dir

A = "http://schemas.openxmlformats.org/drawingml/2006/main"
P = "http://schemas.openxmlformats.org/presentationml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
ODF = (
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"'
)


def _pptx(path: Path, slides: list[list[str]], order: list[int] | None = None) -> Path:
    """A minimal deck; `order` lists slide files in presentation order (1-based)."""
    order = order or list(range(1, len(slides) + 1))
    with zipfile.ZipFile(path, "w") as archive:
        for number, lines in enumerate(slides, start=1):
            paragraphs = "".join(
                f"<a:p><a:r><a:t>{escape(line[: len(line) // 2])}</a:t></a:r><a:r><a:t>{escape(line[len(line) // 2:])}</a:t></a:r></a:p>"
                for line in lines
            )
            archive.writestr(
                f"ppt/slides/slide{number}.xml",
                f'<p:sld xmlns:p="{P}" xmlns:a="{A}"><p:cSld><p:spTree><p:sp><p:txBody>{paragraphs}</p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
            )
        ids = "".join(f'<p:sldId id="{255 + n}" r:id="rId{n}"/>' for n in order)
        archive.writestr("ppt/presentation.xml", f'<p:presentation xmlns:p="{P}" xmlns:r="{R}"><p:sldIdLst>{ids}</p:sldIdLst></p:presentation>')
        rels = "".join(f'<Relationship Id="rId{n}" Target="slides/slide{n}.xml"/>' for n in order)
        archive.writestr("ppt/_rels/presentation.xml.rels", f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{rels}</Relationships>')
    return path


def _docx(path: Path, paragraphs: list[str]) -> Path:
    """A minimal Word document; a paragraph "<page>" is a page break."""
    body = "".join(
        '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' if text == "<page>" else f"<w:p><w:r><w:t>{escape(text)}</w:t></w:r></w:p>"
        for text in paragraphs
    )
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("word/document.xml", f'<w:document xmlns:w="{W}"><w:body>{body}</w:body></w:document>')
    return path


def test_a_powerpoint_deck_gives_one_page_per_slide_in_presentation_order(tmp_path: Path) -> None:
    deck = _pptx(tmp_path / "Lezione.pptx", [["Entropia", "Misura del disordine"], ["Ciclo di Carnot"]], order=[2, 1])

    assert extract_document_texts(deck) == ["Ciclo di Carnot", "Entropia\nMisura del disordine"]


def test_a_libreoffice_deck_gives_one_page_per_slide(tmp_path: Path) -> None:
    deck = tmp_path / "Lezione.odp"
    with zipfile.ZipFile(deck, "w") as archive:
        archive.writestr(
            "content.xml",
            f"<office:document-content {ODF}><office:body><office:presentation>"
            "<draw:page><draw:frame><draw:text-box><text:p>Entropia</text:p><text:p>Misura<text:s/>del disordine</text:p></draw:text-box></draw:frame></draw:page>"
            "<draw:page><draw:frame><draw:text-box><text:p>Ciclo di Carnot</text:p></draw:text-box></draw:frame></draw:page>"
            "</office:presentation></office:body></office:document-content>",
        )

    assert extract_document_texts(deck) == ["Entropia\nMisura del disordine", "Ciclo di Carnot"]


def test_a_word_document_is_split_at_its_page_breaks(tmp_path: Path) -> None:
    document = _docx(tmp_path / "Appunti.docx", ["Termodinamica", "Sistema e ambiente", "<page>", "Entropia"])

    assert extract_document_texts(document) == ["Termodinamica\n\nSistema e ambiente", "Entropia"]


def test_a_libreoffice_document_is_read(tmp_path: Path) -> None:
    document = tmp_path / "Appunti.odt"
    with zipfile.ZipFile(document, "w") as archive:
        archive.writestr(
            "content.xml",
            f"<office:document-content {ODF}><office:body><office:text>"
            "<text:h>Termodinamica</text:h><text:p>Sistema <text:span>e ambiente</text:span></text:p>"
            "</office:text></office:body></office:document-content>",
        )

    assert extract_document_texts(document) == ["Termodinamica\n\nSistema e ambiente"]


def test_markdown_notes_are_split_at_headings(tmp_path: Path) -> None:
    notes = tmp_path / "Appunti.md"
    notes.write_text("# Entropia\nMisura del disordine\n\n## Ciclo di Carnot\nDue isoterme\n", encoding="utf-8")

    assert extract_document_texts(notes) == ["# Entropia\nMisura del disordine", "## Ciclo di Carnot\nDue isoterme"]


def test_long_text_is_cut_at_paragraph_ends() -> None:
    paragraph = "parola " * (PART_CHARS // 14)
    parts = split_document("\n\n".join([paragraph] * 4))

    assert len(parts) == 2
    assert all(len(part) <= PART_CHARS + 10 for part in parts)


def test_an_unreadable_document_says_which_file(tmp_path: Path) -> None:
    broken = tmp_path / "Rotto.docx"
    broken.write_bytes(b"not a zip")

    with pytest.raises(RuntimeError, match="Rotto.docx"):
        extract_document_texts(broken)


def test_a_document_copied_as_slides_is_read_and_its_text_saved(tmp_path: Path) -> None:
    folder = tmp_path / "sidecar" / "slides"
    copy = copy_slides_source(_pptx(tmp_path / "Lezione 7.pptx", [["Entropia"], ["Ciclo di Carnot"]]), folder)

    assert copy.name == "slides.pptx" and slides_source(folder) == copy
    assert [(slide.page, slide.title) for slide in load_slides(tmp_path)] == [(1, "Entropia"), (2, "Ciclo di Carnot")]
    saved = json.loads((folder / "slides.json").read_text(encoding="utf-8"))
    assert saved["source_name"] == "slides.pptx"


def test_unsupported_slides_are_refused(tmp_path: Path) -> None:
    sheet = tmp_path / "Voti.xlsx"
    sheet.write_bytes(b"x")

    with pytest.raises(ValueError, match="Unsupported slides format"):
        copy_slides_source(sheet, tmp_path / "slides")


def test_command_line_import_takes_a_word_document_as_slides(tmp_path: Path, monkeypatch) -> None:
    podcast = tmp_path / "Lezione 8.mp3"
    podcast.write_bytes(b"audio")
    notes = _docx(tmp_path / "Lezione 8.docx", ["Entropia"])
    monkeypatch.setattr("meeting_pilot.media_import.audio_duration_seconds", lambda _path: None)
    seen = {}

    def process(_config, audio, dry_run=False):
        seen["slides"] = sorted(path.name for path in (sidecar_dir(audio) / "slides").iterdir())
        return tmp_path / "done"

    monkeypatch.setattr("meeting_pilot.pipeline.process_audio", process)

    import_media_file(SimpleNamespace(), podcast, slides=notes)

    assert seen["slides"] == ["slides.docx"]
