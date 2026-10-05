from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.publishing.apple_notes_publisher import _note_body
from meeting_pilot.publishing.journal_publisher import publish_to_journal
from meeting_pilot.publishing.notion_publisher import _build_blocks, publish_to_notion
from meeting_pilot.publishing.obsidian_publisher import publish_to_obsidian
from meeting_pilot.slides import attach_slides

DECK = ["Termodinamica\nSistema ambiente energia calore", "Entropia\nDisordine microstati Boltzmann"]
# About a minute on each slide; a slide shown for less than one window (~80 words) is
# folded into its neighbour.
LECTURE = "\n".join(
    ["Il sistema scambia energia e calore con l'ambiente, in termodinamica."] * 12
    + ["L'entropia misura il disordine e Boltzmann conta i microstati."] * 12
)


def _lecture_artifacts(root: Path) -> MeetingArtifacts:
    session = root / "session"
    slides = session / "sidecar" / "slides"
    slides.mkdir(parents=True)
    (slides / "slides.pdf").write_bytes(b"%PDF-1.4 slides")
    (slides / "slides.json").write_text(
        json.dumps({"pages": [{"page": i, "text": text} for i, text in enumerate(DECK, 1)]}), encoding="utf-8"
    )
    artifacts = MeetingArtifacts(
        session_dir=session,
        audio_file=session / "audio.m4a",
        title="Fisica 1",
        transcript_text=LECTURE,
        meeting_metadata={"title": "Fisica 1", "recording_start": "2026-09-28T10:00:00", "origin": "import"},
        omlx_summary={"summary": "Termodinamica ed entropia."},
    )
    attach_slides(artifacts)
    assert [section.page for section in artifacts.slide_sections] == [1, 2]
    return artifacts


def test_diary_note_keeps_the_slides_beside_it_and_groups_the_transcript(tmp_path: Path) -> None:
    artifacts = _lecture_artifacts(tmp_path)
    config = SimpleNamespace(journal_root=tmp_path / "Diary", summary_model="m", transcription_provider="fluid")

    note = Path(publish_to_journal(config, artifacts)["path"])
    text = note.read_text(encoding="utf-8")

    assert note.with_suffix(".pdf").read_bytes() == b"%PDF-1.4 slides"
    assert f'slides: "{note.stem}.pdf"' in text
    assert "## Trascrizione per slide" in text
    assert "> [!slide]- Slide 1 · Termodinamica" in text
    assert "> [!slide]- Slide 2 · Entropia\n> L'entropia misura il disordine" in text
    assert "Transcript completo" not in text


def test_obsidian_note_links_each_section_to_its_slide_page(tmp_path: Path) -> None:
    artifacts = _lecture_artifacts(tmp_path)
    vault = tmp_path / "Vault"
    config = SimpleNamespace(
        obsidian_vault_path=vault,
        obsidian_folder="Meeting Pilot",
        obsidian_filename_template="{date} - {title}.md",
        summary_model="m",
        transcription_provider="fluid",
    )

    note = Path(publish_to_obsidian(config, artifacts)["path"])
    text = note.read_text(encoding="utf-8")

    pdf = f"Meeting Pilot/Slides/{note.stem}.pdf"
    assert (vault / pdf).read_bytes() == b"%PDF-1.4 slides"
    assert f'slides: "[[{pdf}]]"' in text
    assert f"> [!slide]- Slide 2 · Entropia\n> [[{pdf}#page=2|Apri la slide 2]]\n>\n> L'entropia" in text


def test_notes_without_slides_keep_the_single_transcript(tmp_path: Path) -> None:
    session = tmp_path / "session"
    session.mkdir()
    artifacts = MeetingArtifacts(session_dir=session, audio_file=session / "a.m4a", title="Sync", transcript_text="Mario: ok.")
    attach_slides(artifacts)
    config = SimpleNamespace(journal_root=tmp_path / "Diary", summary_model="m", transcription_provider="fluid")

    text = Path(publish_to_journal(config, artifacts)["path"]).read_text(encoding="utf-8")

    assert "> [!quote]- Transcript completo" in text
    assert "slides:" not in text
    assert not list((tmp_path / "Diary").rglob("*.pdf"))


def test_apple_notes_group_the_transcript_by_slide(tmp_path: Path) -> None:
    artifacts = _lecture_artifacts(tmp_path)
    config = SimpleNamespace(summary_model="m", transcription_provider="fluid")

    body = _note_body(config, artifacts)

    assert "Trascrizione per slide" in body
    assert "Slide 2 · Entropia\nL'entropia misura il disordine" in body


def _notion_config(**overrides):
    values = dict(
        notion_token="token",
        notion_database_id="meetings-database",
        notion_title_property="Name",
        notion_project_property="Project",
        notion_include_overview=False,
        notion_include_summary=True,
        notion_include_topics=False,
        notion_include_decisions=False,
        notion_include_action_items=False,
        notion_include_open_questions=False,
        notion_include_risks=False,
        notion_include_speakers=False,
        notion_include_transcript=True,
        summary_model="test-model",
    )
    values.update(overrides)
    return SimpleNamespace(**values)


def test_notion_shows_the_uploaded_slides_and_one_toggle_per_slide(tmp_path: Path) -> None:
    artifacts = _lecture_artifacts(tmp_path)

    blocks = _build_blocks(_notion_config(), artifacts, slides_upload="upload-1")

    pdf = next(block for block in blocks if block["type"] == "pdf")
    assert pdf["pdf"] == {"type": "file_upload", "file_upload": {"id": "upload-1"}}
    toggles = [block["heading_3"] for block in blocks if block["type"] == "heading_3" and block["heading_3"].get("is_toggleable")]
    assert [toggle["rich_text"][0]["text"]["content"] for toggle in toggles] == ["Slide 1 · Termodinamica", "Slide 2 · Entropia"]
    assert "Boltzmann" in json.dumps(toggles[1]["children"], ensure_ascii=False)


class _FakeNotion:
    """Records pages, appended blocks and file uploads."""

    def __init__(self) -> None:
        self.created: list[dict] = []
        self.appended: list[list[dict]] = []
        self.sent: list[tuple] = []
        fake = self

        class Pages:
            def create(self, **payload):
                fake.created.append(payload)
                return {"id": "page-1", **payload}

        class Children:
            def append(self, block_id, children):
                fake.appended.append(children)

        class Uploads:
            def create(self, **payload):
                return {"id": "upload-1", **payload}

            def send(self, upload_id, file):
                fake.sent.append((upload_id, file))

        class Sources:
            def retrieve(self, data_source_id):
                return {"id": data_source_id, "properties": {"Name": {"type": "title", "title": {}}}}

            def update(self, data_source_id, properties):
                return {"id": data_source_id, "properties": properties}

        class Databases:
            def retrieve(self, database_id):
                return {"id": database_id, "data_sources": [{"id": "source-1"}]}

        self.pages = Pages()
        self.blocks = SimpleNamespace(children=Children())
        self.file_uploads = Uploads()
        self.data_sources = Sources()
        self.databases = Databases()


def test_notion_uploads_the_slides_and_appends_blocks_past_the_first_hundred(tmp_path: Path) -> None:
    artifacts = _lecture_artifacts(tmp_path)
    # Many short slide sections: more page blocks than one request may create.
    artifacts.slide_sections = artifacts.slide_sections * 70
    fake = _FakeNotion()

    with patch.dict("sys.modules", {"notion_client": SimpleNamespace(Client=lambda auth: fake)}):
        publish_to_notion(_notion_config(), artifacts)

    assert fake.sent[0][0] == "upload-1"
    assert fake.sent[0][1][1] == b"%PDF-1.4 slides"
    assert len(fake.created[0]["children"]) == 100
    assert fake.appended and all(len(batch) <= 100 for batch in fake.appended)
    total = len(fake.created[0]["children"]) + sum(len(batch) for batch in fake.appended)
    assert total == len(_build_blocks(_notion_config(), artifacts, slides_upload="upload-1"))
