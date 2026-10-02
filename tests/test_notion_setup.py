from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from meeting_pilot.notion_setup import NotionSetupError, provision_notion_workspace


def _title_property(value: str) -> dict:
    return {
        "properties": {
            "title": {
                "type": "title",
                "title": [{"plain_text": value}],
            }
        }
    }


class _Pages:
    def __init__(self, owner: "_FakeNotion") -> None:
        self.owner = owner
        self.created: list[dict] = []

    def create(self, **payload):
        self.created.append(payload)
        return {"id": "created-page", **_title_property(self.owner.destination_name)}

    def retrieve(self, page_id: str):
        title = next(
            value
            for key, value in self.owner.page_titles.items()
            if key.replace("-", "") == page_id.replace("-", "")
        )
        return {"id": page_id, **_title_property(title)}


class _Databases:
    def __init__(self, owner: "_FakeNotion") -> None:
        self.owner = owner
        self.created: list[dict] = []
        self.updated: list[dict] = []

    def create(self, **payload):
        self.created.append(payload)
        return {"id": "created-database"}

    def update(self, **payload):
        self.updated.append(payload)
        return payload

    def retrieve(self, database_id: str):
        return {"id": database_id, "data_sources": [{"id": f"source-{database_id}"}]}


class _Children:
    def __init__(self, owner: "_FakeNotion") -> None:
        self.owner = owner

    def list(self, block_id: str, page_size: int = 100):
        results = next(
            (
                value
                for key, value in self.owner.children.items()
                if key.replace("-", "") == block_id.replace("-", "")
            ),
            [],
        )
        return {"results": list(results)}


class _DataSources:
    def __init__(self) -> None:
        self.updated: list[dict] = []

    def retrieve(self, data_source_id: str):
        return {"id": data_source_id, "properties": {"Name": {"type": "title"}}}

    def update(self, **payload):
        self.updated.append(payload)
        return payload


class _Views:
    def __init__(self) -> None:
        self.created: list[dict] = []

    def list(self, **_payload):
        return {"results": []}

    def create(self, **payload):
        self.created.append(payload)
        return payload

    def retrieve(self, view_id: str):
        return {"id": view_id}

    def update(self, **payload):
        return payload


class _FakeNotion:
    def __init__(
        self,
        *,
        destination_name: str = "Client Calls",
        children: dict[str, list[dict]] | None = None,
        page_titles: dict[str, str] | None = None,
    ) -> None:
        self.destination_name = destination_name
        self.children = children or {}
        self.page_titles = page_titles or {}
        self.pages = _Pages(self)
        self.databases = _Databases(self)
        self.blocks = SimpleNamespace(children=_Children(self))
        self.data_sources = _DataSources()
        self.views = _Views()


def _config(**overrides):
    values = {
        "notion_token": "token",
        "notion_parent_page_id": "parent",
        "notion_app_page_id": None,
        "notion_series_database_id": None,
        "notion_occurrences_database_id": None,
        "notion_database_id": None,
        "notion_page_name": "Client Calls",
    }
    values.update(overrides)
    return SimpleNamespace(**values)


class NotionSetupTests(unittest.TestCase):
    def _provision(self, fake: _FakeNotion, config=None, env_path: Path | None = None):
        client_module = SimpleNamespace(Client=lambda auth: fake)
        with patch.dict("sys.modules", {"notion_client": client_module}):
            return provision_notion_workspace(config or _config(), env_path)

    def test_reuses_matching_direct_database_without_creating_anything(self) -> None:
        fake = _FakeNotion(
            children={
                "parent": [
                    {
                        "id": "direct-database",
                        "type": "child_database",
                        "child_database": {"title": " client calls "},
                    }
                ]
            }
        )

        result = self._provision(fake)

        self.assertTrue(result.get("reused_destination"))
        self.assertEqual(result["occurrences_database_id"], "direct-database")
        self.assertEqual(fake.pages.created, [])
        self.assertEqual(fake.databases.created, [])
        self.assertEqual(fake.databases.updated, [])
        self.assertEqual(fake.views.created, [])

    def test_reuses_matching_page_table_and_persists_single_destination(self) -> None:
        fake = _FakeNotion(
            children={
                "parent": [{"id": "existing-page", "type": "child_page", "child_page": {}}],
                "existing-page": [
                    {
                        "id": "nested-database",
                        "type": "child_database",
                        "child_database": {"title": "Any table title"},
                    }
                ],
            },
            page_titles={"existing-page": "CLIENT CALLS"},
        )
        with tempfile.TemporaryDirectory() as temporary:
            env_path = Path(temporary) / ".env"

            result = self._provision(fake, env_path=env_path)

            values = env_path.read_text(encoding="utf-8")
        self.assertEqual(result["app_page_id"], "existing-page")
        self.assertEqual(result["occurrences_database_id"], "nested-database")
        self.assertTrue(result["reused_destination"])
        self.assertIn("NOTION_PAGE_NAME=\"Client Calls\"", values)
        self.assertIn("NOTION_SERIES_DATABASE_ID=", values)
        self.assertIn("NOTION_DATABASE_ID=nested-database", values)
        self.assertEqual(fake.pages.created, [])
        self.assertEqual(fake.databases.created, [])

    def test_creates_one_named_page_and_minimal_table_when_parent_is_empty(self) -> None:
        fake = _FakeNotion(children={"parent": []})

        result = self._provision(fake)

        self.assertTrue(result["created_app_page"])
        self.assertFalse(result.get("reused_destination"))
        self.assertEqual(result["destination_name"], "Client Calls")
        self.assertEqual(len(fake.pages.created), 1)
        self.assertEqual(
            fake.pages.created[0]["properties"]["title"][0]["text"]["content"],
            "Client Calls",
        )
        self.assertEqual(len(fake.databases.created), 1)
        self.assertEqual(fake.databases.created[0]["properties"], {"Name": {"title": {}}})
        self.assertEqual(fake.views.created, [])

    def test_does_not_reuse_a_stale_configured_destination_after_renaming(self) -> None:
        fake = _FakeNotion(children={"parent": []}, destination_name="Teams Meetings")
        result = self._provision(
            fake,
            config=_config(
                notion_page_name="Teams Meetings",
                notion_app_page_id="old-meeting-pilot-page",
                notion_occurrences_database_id="old-meeting-pilot-database",
                notion_database_id="old-meeting-pilot-database",
            ),
        )

        self.assertTrue(result["created_app_page"])
        self.assertEqual(len(fake.pages.created), 1)
        self.assertEqual(
            fake.pages.created[0]["properties"]["title"][0]["text"]["content"],
            "Teams Meetings",
        )

    def test_refuses_to_duplicate_matching_page_without_table(self) -> None:
        fake = _FakeNotion(
            children={
                "parent": [{"id": "existing-page", "type": "child_page", "child_page": {}}],
                "existing-page": [],
            },
            page_titles={"existing-page": "Client Calls"},
        )

        with self.assertRaisesRegex(NotionSetupError, "non contiene una tabella"):
            self._provision(fake)

        self.assertEqual(fake.pages.created, [])
        self.assertEqual(fake.databases.created, [])


if __name__ == "__main__":
    unittest.main()
