from __future__ import annotations

import shutil
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from meeting_pilot.slides.alignment import SlideSection, TranscriptUnit
from meeting_pilot.slides.deck import slide_images, slides_from_texts
from tests.test_notion_publisher import _FakeNotion, _artifacts, _full_config
from tests.test_slides import _make_pdf


def _unit(speaker: str, text: str) -> TranscriptUnit:
    return TranscriptUnit(text=text, speaker=speaker, start=None, starts_line=True)


def _lecture(session: Path):
    artifacts = _artifacts(session)
    artifacts.slides = slides_from_texts(["Entropia", "Carnot"])
    artifacts.slide_sections = [
        SlideSection(page=1, title="Entropia", units=[_unit("Prof", "Il disordine cresce.")]),
        SlideSection(page=2, title="Carnot", units=[_unit("Prof", "Il ciclo ideale.")]),
        SlideSection(page=1, title="Entropia", units=[_unit("Prof", "Torniamo all'entropia.")]),
    ]
    return artifacts


def _with_pdf(session: Path) -> Path:
    folder = session / "sidecar" / "slides"
    folder.mkdir(parents=True)
    _make_pdf(folder / "slides.pdf", [["Entropia"], ["Carnot"]])
    return folder


@pytest.mark.skipif(shutil.which("osascript") is None, reason="PDFKit is drawn through macOS osascript")
def test_each_slide_is_drawn_once_as_a_picture(tmp_path: Path) -> None:
    folder = _with_pdf(tmp_path)

    images = slide_images(tmp_path)

    assert sorted(images) == [1, 2]
    assert images[1].read_bytes()[:3] == b"\xff\xd8\xff"
    drawn = images[1].stat().st_mtime_ns
    assert slide_images(tmp_path) == images
    assert images[1].stat().st_mtime_ns == drawn
    assert (folder / "images").is_dir()


def test_no_pictures_without_a_pdf(tmp_path: Path) -> None:
    assert slide_images(tmp_path) == {}


def _fake_pictures(session: Path) -> dict[int, Path]:
    folder = session / "sidecar" / "slides" / "images"
    folder.mkdir(parents=True, exist_ok=True)
    pictures = {}
    for page in (1, 2):
        pictures[page] = folder / f"slide-{page}.jpg"
        pictures[page].write_bytes(b"\xff\xd8\xff picture")
    return pictures


def test_obsidian_heads_each_slide_part_with_its_picture(tmp_path: Path) -> None:
    from meeting_pilot.publishing.obsidian_publisher import publish_to_obsidian

    session = tmp_path / "session"
    _with_pdf(session)
    vault = tmp_path / "vault"
    config = SimpleNamespace(
        obsidian_vault_path=vault,
        obsidian_folder="Meetings",
        obsidian_filename_template="{title}.md",
        summary_model="gpt-test",
        transcription_provider="fluid",
        output_language="it",
    )
    with patch("meeting_pilot.publishing.obsidian_publisher.slide_images", lambda _: _fake_pictures(session)):
        receipt = publish_to_obsidian(config, _lecture(session))

    note = Path(receipt["path"])
    text = note.read_text(encoding="utf-8")
    pictures = vault / "Meetings" / "Slides" / note.stem
    assert sorted(path.name for path in pictures.iterdir()) == ["slide-1.jpg", "slide-2.jpg"]
    assert text.count(f"> ![[Meetings/Slides/{note.stem}/slide-1.jpg|480]]") == 2
    assert f"> ![[Meetings/Slides/{note.stem}/slide-2.jpg|480]]" in text
    assert text.index("slide-2.jpg") < text.index("Il ciclo ideale.")


class _Uploads:
    def __init__(self) -> None:
        self.sent: list[str] = []

    def create(self, **payload):
        return {"id": f"upload-{payload['filename']}"}

    def send(self, upload_id: str, file):
        self.sent.append(upload_id)


class _Children:
    def __init__(self, fake) -> None:
        self.fake = fake
        self.appended: list[tuple[str, list]] = []

    def list(self, block_id: str, **_cursor):
        created = self.fake.pages.created[-1]["children"]
        results = []
        for index, block in enumerate(created):
            body = block[block["type"]]
            results.append({"id": f"block-{index}", "type": block["type"], "has_children": bool(body.get("children")), **{block["type"]: body}})
        for rich in (result.get(result["type"], {}).get("rich_text") or [] for result in results):
            for part in rich:
                part["plain_text"] = part["text"]["content"]
        return {"results": results, "has_more": False}

    def append(self, block_id: str, children: list):
        self.appended.append((block_id, children))


def test_notion_shows_each_slide_beside_what_was_said_on_it(tmp_path: Path) -> None:
    from meeting_pilot.publishing.notion_publisher import publish_to_notion

    fake = _FakeNotion({"Name": {"type": "title", "title": {}}})
    fake.file_uploads = _Uploads()
    fake.blocks = SimpleNamespace(children=_Children(fake))
    _with_pdf(tmp_path)
    client_module = SimpleNamespace(Client=lambda auth: fake)
    with (
        patch.dict("sys.modules", {"notion_client": client_module}),
        patch("meeting_pilot.publishing.notion_publisher.slide_images", lambda _: _fake_pictures(tmp_path)),
    ):
        publish_to_notion(_full_config(), _lecture(tmp_path))

    assert fake.file_uploads.sent[:2] == ["upload-slide-1.jpg", "upload-slide-2.jpg"]
    toggles = [block for block in fake.pages.created[-1]["children"] if block["type"] == "heading_3"]
    assert [block["heading_3"].get("children") for block in toggles] == [None, None, None]
    filled = fake.blocks.children.appended
    assert len(filled) == 3
    pictures, said = [], []
    for _, children in filled:
        left, right = children[0]["column_list"]["children"]
        pictures.append(left["column"]["children"][0]["image"]["file_upload"]["id"])
        said.append(right["column"]["children"][0]["paragraph"]["rich_text"][-1]["text"]["content"])
    assert pictures == ["upload-slide-1.jpg", "upload-slide-2.jpg", "upload-slide-1.jpg"]
    assert said == ["Il disordine cresce.", "Il ciclo ideale.", "Torniamo all'entropia."]
