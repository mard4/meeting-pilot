from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import requests

from ..artifacts import write_notion_receipt
from ..config import Config
from ..env_file import update_env_file


def assign_meeting_project(
    config: Config,
    session_dir: Path,
    project_name: str,
    env_path: Path | None = None,
) -> dict[str, Any]:
    project = project_name.strip()
    if not project:
        raise ValueError("Project name is required.")
    if not config.notion_token or not config.notion_database_id:
        raise ValueError("NOTION_TOKEN and NOTION_DATABASE_ID are required.")

    receipt_path = session_dir.expanduser() / "notion_receipt.json"
    if not receipt_path.exists():
        raise ValueError(f"Notion receipt not found: {receipt_path}")

    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    page_id = receipt.get("id")
    if not page_id:
        raise ValueError(f"Notion page id not found in {receipt_path}")

    _ensure_project_property(config, project)
    updated_page = _notion_request(
        config,
        "PATCH",
        f"https://api.notion.com/v1/pages/{page_id}",
        json={"properties": {config.notion_project_property: {"select": {"name": project[:100]}}}},
    )

    receipt["meeting_pilot_project"] = project
    write_notion_receipt(session_dir.expanduser(), receipt)
    project_payload = {
        "project": project,
        "notion_page_id": page_id,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    (session_dir.expanduser() / "meeting_project.json").write_text(
        json.dumps(project_payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    if env_path:
        update_env_file(env_path, {"NOTION_PROJECT_PROPERTY": config.notion_project_property})

    return {
        "project": project,
        "notion_page_id": page_id,
        "url": updated_page.get("url") or receipt.get("url"),
        "property": config.notion_project_property,
    }


def _ensure_project_property(config: Config, project: str) -> None:
    data_source_id = _data_source_id(config)
    data_source = _notion_request(
        config,
        "GET",
        f"https://api.notion.com/v1/data_sources/{data_source_id}",
    )
    properties = data_source.get("properties", {})
    if config.notion_project_property in properties:
        return
    _notion_request(
        config,
        "PATCH",
        f"https://api.notion.com/v1/data_sources/{data_source_id}",
        json={
            "properties": {
                config.notion_project_property: {
                    "select": {
                        "options": [
                            {
                                "name": project[:100],
                                "color": "blue",
                            }
                        ]
                    }
                }
            }
        },
    )


def _data_source_id(config: Config) -> str:
    database_id = _clean_id(config.notion_database_id or "")
    database = _notion_request(config, "GET", f"https://api.notion.com/v1/databases/{database_id}")
    data_sources = database.get("data_sources") or []
    if data_sources:
        return data_sources[0]["id"]
    return database_id


def _notion_request(config: Config, method: str, url: str, **kwargs: Any) -> dict[str, Any]:
    response = requests.request(
        method,
        url,
        headers={
            "Authorization": f"Bearer {config.notion_token}",
            "Notion-Version": "2026-03-11",
            "Content-Type": "application/json",
        },
        timeout=30,
        **kwargs,
    )
    if response.status_code >= 400:
        raise RuntimeError(f"Notion API error {response.status_code}: {response.text[:1000]}")
    return response.json() if response.text else {}


def _clean_id(value: str) -> str:
    compact = value.replace("-", "").strip()
    matches = re.findall(r"[0-9a-fA-F]{32}", compact)
    return matches[-1] if matches else compact
