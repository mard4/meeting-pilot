from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from transcribe_to_notion.artifacts import MeetingArtifacts
from transcribe_to_notion.notion_publisher import publish_to_notion


class _Pages:
    def __init__(self) -> None:
        self.created: list[dict] = []
        self.updated: list[dict] = []

    def create(self, **payload):
        self.created.append(payload)
        index = len(self.created)
        return {"id": f"page-{index}", "url": f"https://notion.test/page-{index}"}

    def update(self, **payload):
        self.updated.append(payload)
        return payload


class _Databases:
    def retrieve(self, database_id: str):
        return {
            "id": database_id,
            "data_sources": [{"id": f"source-{database_id}"}],
        }


class _DataSources:
    def __init__(self, destination_schema: dict) -> None:
        self.destination_schema = destination_schema
        self.queries: list[dict] = []

    def retrieve(self, data_source_id: str):
        if data_source_id == "source-series-database":
            return {
                "id": data_source_id,
                "properties": {
                    "Name": {"type": "title", "title": {}},
                    "Series Key": {"type": "rich_text", "rich_text": {}},
                    "Type": {"type": "select", "select": {}},
                },
            }
        return {"id": data_source_id, "properties": self.destination_schema}

    def query(self, **payload):
        self.queries.append(payload)
        return {"results": []}


class _FakeNotion:
    def __init__(self, destination_schema: dict) -> None:
        self.pages = _Pages()
        self.databases = _Databases()
        self.data_sources = _DataSources(destination_schema)


def _config():
    return SimpleNamespace(
        notion_token="token",
        notion_database_id="meetings-database",
        notion_series_database_id="series-database",
        notion_occurrences_database_id="meetings-database",
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
        notion_include_transcript=False,
        summary_model="test-model",
    )


def _artifacts(root: Path) -> MeetingArtifacts:
    return MeetingArtifacts(
        session_dir=root,
        audio_file=root / "audio.m4a",
        title="Sprint Review",
        transcript_text="Mario: approvato.",
        summary_markdown="Sintesi.",
        meeting_metadata={
            "title": "Sprint Review",
            "start": "2026-07-28T10:00:00Z",
            "project": "Atlas",
            "theme": "Agentic",
        },
        omlx_summary={"summary": "Sintesi."},
    )


class NotionPublisherTests(unittest.TestCase):
    def _publish(self, fake: _FakeNotion, root: Path):
        client_module = SimpleNamespace(Client=lambda auth: fake)
        with patch.dict("sys.modules", {"notion_client": client_module}):
            return publish_to_notion(_config(), _artifacts(root))

    def test_publishes_one_page_using_actual_title_property_without_series_calls(self) -> None:
        fake = _FakeNotion(
            {"Meeting": {"id": "title", "name": "Meeting", "type": "title", "title": {}}}
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            page = self._publish(fake, root)

            self.assertEqual(page["id"], "page-1")
            self.assertEqual(len(fake.pages.created), 1)
            self.assertEqual(
                fake.pages.created[0]["properties"],
                {
                    "Meeting": {
                        "title": [
                            {
                                "text": {
                                    "content": "Sprint Review - 2026-07-28",
                                }
                            }
                        ]
                    }
                },
            )
            self.assertEqual(fake.pages.updated, [])
            self.assertEqual(fake.data_sources.queries, [])
            self.assertTrue((root / "notion_receipt.json").exists())

    def test_prefers_the_generated_summary_title(self) -> None:
        fake = _FakeNotion({"Name": {"type": "title", "title": {}}})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = _artifacts(root)
            artifacts.meeting_metadata["title"] = "Calendar | Reply | person@example.com"
            artifacts.omlx_summary["title"] = "Pianificazione rilascio prodotto"
            client_module = SimpleNamespace(Client=lambda auth: fake)
            with patch.dict("sys.modules", {"notion_client": client_module}):
                publish_to_notion(_config(), artifacts)

        title = fake.pages.created[0]["properties"]["Name"]["title"][0]["text"]["content"]
        self.assertEqual(title, "Pianificazione rilascio prodotto - 2026-07-28")

    def test_writes_only_existing_properties_with_compatible_types(self) -> None:
        fake = _FakeNotion(
            {
                "Meeting": {"type": "title", "title": {}},
                "Date": {"type": "date", "date": {}},
                "Project": {"type": "rich_text", "rich_text": {}},
            }
        )
        with tempfile.TemporaryDirectory() as temporary:
            self._publish(fake, Path(temporary))

        properties = fake.pages.created[-1]["properties"]
        self.assertIn("Date", properties)
        self.assertNotIn("Project", properties)
        self.assertNotIn("Series", properties)
        self.assertNotIn("Series Key", properties)

    def test_writes_theme_as_one_item_multi_select(self) -> None:
        fake = _FakeNotion(
            {
                "Name": {"type": "title", "title": {}},
                "Tema": {"type": "multi_select", "multi_select": {}},
            }
        )
        with tempfile.TemporaryDirectory() as temporary:
            self._publish(fake, Path(temporary))

        self.assertEqual(
            fake.pages.created[-1]["properties"]["Tema"],
            {"multi_select": [{"name": "Agentic"}]},
        )

    def test_does_not_write_theme_to_select_property(self) -> None:
        fake = _FakeNotion(
            {
                "Name": {"type": "title", "title": {}},
                "Tema": {"type": "select", "select": {}},
            }
        )
        with tempfile.TemporaryDirectory() as temporary:
            self._publish(fake, Path(temporary))

        self.assertNotIn("Tema", fake.pages.created[-1]["properties"])


def _full_config():
    config = _config()
    for name in vars(config):
        if name.startswith("notion_include_"):
            setattr(config, name, True)
    config.output_language = "it"
    return config


def _rich_artifacts(root: Path, transcript: str | None = None) -> MeetingArtifacts:
    artifacts = _artifacts(root)
    artifacts.transcript_text = transcript or "Giulia: Iniziamo.\nMarco: L'onboarding è online.\nGiulia: Bene."
    artifacts.meeting_metadata.update(
        {"match_found": True, "end": "2026-07-28T10:35:00Z", "participants": ["Giulia", "Marco"]}
    )
    artifacts.omlx_summary = {
        "summary": "Primo paragrafo.\n\nSecondo paragrafo.",
        "topics": ["Onboarding", "Login Apple"],
        "decisions": [{"text": "Rilascio con la 2.4", "owner": "Giulia"}],
        "action_items": [
            {"task": "Build TestFlight", "owner": "Marco", "due_date": "2026-10-03", "status": "open"},
            {"task": "Testi consenso", "owner": None, "due_date": "mercoledì", "status": "open"},
        ],
        "open_questions": ["Crash su Android 12?"],
        "risks": [],
    }
    return artifacts


def _walk(blocks, depth=0):
    for block in blocks:
        yield block, depth
        body = block[block["type"]]
        yield from _walk(body.get("children") or [], depth + 1)


def _plain(block) -> str:
    rich = block[block["type"]].get("rich_text") or []
    return "".join(item.get("text", {}).get("content", "") for item in rich)


class NotionBlockLayoutTests(unittest.TestCase):
    def _blocks(self, artifacts):
        from transcribe_to_notion.notion_publisher import _build_blocks

        return _build_blocks(_full_config(), artifacts)

    def assertWithinNotionLimits(self, blocks) -> None:
        self.assertLessEqual(len(blocks), 100)
        for block, depth in _walk(blocks):
            self.assertLessEqual(depth, 2, f"{block['type']} nested too deep")
            body = block[block["type"]]
            self.assertLessEqual(len(body.get("children") or []), 100)
            rich = body.get("rich_text") or []
            self.assertLessEqual(len(rich), 100)
            for item in rich:
                self.assertLessEqual(len(item.get("text", {}).get("content", "")), 2000)

    def test_layout_stays_within_notion_nesting_and_size_limits(self) -> None:
        long_transcript = "\n".join(f"Speaker {i % 3}: " + "parola " * 400 for i in range(450))
        with tempfile.TemporaryDirectory() as temporary:
            blocks = self._blocks(_rich_artifacts(Path(temporary), long_transcript))

        self.assertWithinNotionLimits(blocks)

    def test_header_shows_readable_date_duration_and_participants(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            blocks = self._blocks(_rich_artifacts(Path(temporary)))

        header = _plain(blocks[0])
        self.assertIn("martedì 28 luglio 2026", header)
        self.assertIn("35 min", header)
        self.assertIn("Giulia, Marco", header)
        self.assertNotIn("2026-07-28T", header)

    def test_action_items_are_todos_with_owner_and_real_due_date(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            blocks = self._blocks(_rich_artifacts(Path(temporary)))

        todos = [block for block, _ in _walk(blocks) if block["type"] == "to_do"]
        self.assertEqual(len(todos), 2)
        first = todos[0]["to_do"]["rich_text"]
        self.assertIn(" Marco ", [item.get("text", {}).get("content") for item in first])
        self.assertIn(
            {"type": "mention", "mention": {"type": "date", "date": {"start": "2026-10-03"}}}, first
        )
        self.assertIn("mercoledì", _plain(todos[1]))

    def test_empty_sections_are_omitted_and_summary_keeps_paragraphs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            blocks = self._blocks(_rich_artifacts(Path(temporary)))

        texts = [_plain(block) for block, _ in _walk(blocks)]
        self.assertIn("Domande aperte", texts)
        self.assertNotIn("Rischi", texts)
        self.assertIn("Primo paragrafo.", texts)
        self.assertIn("Secondo paragrafo.", texts)

    def test_transcript_turns_have_bold_speaker_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            blocks = self._blocks(_rich_artifacts(Path(temporary)))

        toggle = blocks[-1]["heading_2"]
        self.assertTrue(toggle["is_toggleable"])
        first_turn = toggle["children"][0]["paragraph"]["rich_text"]
        self.assertEqual(first_turn[0]["text"]["content"], "Giulia")
        self.assertTrue(first_turn[0]["annotations"]["bold"])
        self.assertEqual(len(toggle["children"]), 3)


if __name__ == "__main__":
    unittest.main()
