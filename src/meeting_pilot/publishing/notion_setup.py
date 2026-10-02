from __future__ import annotations

from pathlib import Path
import re
from typing import Any

from ..config import Config
from ..env_file import update_env_file


class NotionSetupError(ValueError):
    """Raised when Notion setup cannot start because required settings are missing."""


def provision_notion_workspace(config: Config, env_path: Path | None = None) -> dict[str, Any]:
    if not config.notion_token:
        raise NotionSetupError("Inserisci il token dell'integrazione Notion.")
    if not config.notion_parent_page_id and not config.notion_app_page_id:
        raise NotionSetupError(
            "Incolla l'URL o l'ID di una pagina Notion condivisa con l'integrazione."
        )

    from notion_client import Client

    notion = Client(auth=config.notion_token)
    destination_name = str(
        getattr(config, "notion_page_name", "Meeting Pilot") or ""
    ).strip()
    if not destination_name:
        raise NotionSetupError("Inserisci il nome della pagina Notion.")

    parent_page_id = _clean_id(config.notion_parent_page_id or config.notion_app_page_id or "")
    existing_database_id = (
        config.notion_occurrences_database_id or config.notion_database_id or ""
    )
    found = _find_destination(
        notion,
        parent_page_id,
        destination_name,
        configured_app_page_id=config.notion_app_page_id or "",
        configured_database_id=existing_database_id,
    )
    created_app_page = False
    if found:
        app_page_id, occurrences_database_id = found
    else:
        created_page = notion.pages.create(
            parent={"type": "page_id", "page_id": parent_page_id},
            properties={"title": [{"text": {"content": destination_name}}]},
        )
        app_page_id = str(created_page["id"])
        occurrences_database = notion.databases.create(
            parent={"type": "page_id", "page_id": _clean_id(app_page_id)},
            title=[{"type": "text", "text": {"content": destination_name}}],
            properties={"Name": {"title": {}}},
        )
        occurrences_database_id = str(occurrences_database["id"])
        created_app_page = True

    values = {
        "NOTION_APP_PAGE_ID": app_page_id,
        "NOTION_SERIES_DATABASE_ID": "",
        "NOTION_OCCURRENCES_DATABASE_ID": occurrences_database_id,
        "NOTION_DATABASE_ID": occurrences_database_id,
        "NOTION_PAGE_NAME": destination_name,
        "NOTION_TITLE_PROPERTY": "Name",
        "NOTION_PROJECT_PROPERTY": "Project",
    }
    if env_path:
        update_env_file(env_path, values)

    return {
        "app_page_id": app_page_id,
        "series_database_id": "",
        "occurrences_database_id": occurrences_database_id,
        "destination_name": destination_name,
        "created_app_page": created_app_page,
        "reused_destination": not created_app_page,
    }


def _find_destination(
    notion: Any,
    parent_page_id: str,
    destination_name: str,
    *,
    configured_app_page_id: str = "",
    configured_database_id: str = "",
) -> tuple[str, str] | None:
    children = _list_children(notion, parent_page_id)
    expected = _normalized_title(destination_name)

    for block in children:
        if block.get("type") != "child_database" or not block.get("id"):
            continue
        title = str((block.get("child_database") or {}).get("title") or "")
        if _normalized_title(title) == expected:
            return parent_page_id, str(block["id"])

    for block in children:
        if block.get("type") != "child_page" or not block.get("id"):
            continue
        page_id = str(block["id"])
        page = notion.pages.retrieve(page_id=_clean_id(page_id))
        if _normalized_title(_page_title(page)) != expected:
            continue
        databases = _child_databases(notion, page_id)
        if not databases:
            raise NotionSetupError(
                f'La pagina Notion "{destination_name}" esiste già ma non contiene '
                "una tabella utilizzabile."
            )
        return page_id, str(databases[0]["id"])

    return None


def _list_children(notion: Any, block_id: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    cursor: str | None = None
    while True:
        arguments: dict[str, Any] = {
            "block_id": _clean_id(block_id),
            "page_size": 100,
        }
        if cursor:
            arguments["start_cursor"] = cursor
        response = notion.blocks.children.list(**arguments)
        results.extend(
            item for item in response.get("results", []) if isinstance(item, dict)
        )
        if not response.get("has_more") or not response.get("next_cursor"):
            return results
        cursor = str(response["next_cursor"])


def _child_databases(notion: Any, page_id: str) -> list[dict[str, Any]]:
    return [
        block
        for block in _list_children(notion, page_id)
        if block.get("type") == "child_database" and block.get("id")
    ]


def _page_title(page: dict[str, Any]) -> str:
    properties = page.get("properties") or {}
    for value in properties.values():
        if not isinstance(value, dict) or value.get("type") != "title":
            continue
        title = value.get("title") or []
        return "".join(
            str(item.get("plain_text") or ((item.get("text") or {}).get("content")) or "")
            for item in title
            if isinstance(item, dict)
        )
    return ""


def _normalized_title(value: str) -> str:
    return value.strip().casefold()


def _clean_id(value: str) -> str:
    compact = value.replace("-", "").strip()
    matches = re.findall(r"[0-9a-fA-F]{32}", compact)
    return matches[-1] if matches else compact
