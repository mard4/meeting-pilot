from __future__ import annotations

import json
import os
import re
import sqlite3
import ssl
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import certifi

from .config import Config
from .chat.knowledge_base import default_knowledge_index_path, load_knowledge_documents


CATALOG_FILENAME = "tag-catalog.json"
_KINDS = ("projects", "topics")
_LEGACY_BROAD_IMPORT_SOURCE = "sources:completed,journal,knowledge,notion,obsidian"
_NOTION_MANAGED_SOURCES = {"notion_confirmed_import", _LEGACY_BROAD_IMPORT_SOURCE}
_IMPORT_SOURCE_PREFIX = "import:"


def catalog_path(config: Config) -> Path:
    """Keep the curated taxonomy beside the local Diary, not in a remote destination."""
    return config.journal_root.expanduser() / CATALOG_FILENAME


def catalog_values(config: Config) -> dict[str, list[str]]:
    catalog = _load(catalog_path(config))
    return {
        kind: sorted(
            (str(item.get("name") or "").strip() for item in catalog[kind]),
            key=str.casefold,
        )
        for kind in _KINDS
    }


def add_catalog_value(config: Config, kind: str, value: str, source: str = "manual") -> dict[str, list[str]]:
    normalized_kind = _normalize_kind(kind)
    name = value.strip()
    if not name:
        raise ValueError("Tag name is required.")
    path = catalog_path(config)
    catalog = _load(path)
    key = name.casefold()
    now = datetime.now(timezone.utc).isoformat()
    for item in catalog[normalized_kind]:
        if str(item.get("name") or "").strip().casefold() == key:
            sources = {str(entry) for entry in item.get("sources", [])}
            sources.add(source)
            item["sources"] = sorted(sources)
            item["updated_at"] = now
            _save(path, catalog)
            return catalog_values(config)
    catalog[normalized_kind].append(
        {"name": name, "created_at": now, "updated_at": now, "sources": [source]}
    )
    _save(path, catalog)
    return catalog_values(config)


def bootstrap_catalog_from_notion(config: Config) -> dict[str, list[str]]:
    """Read tags currently used by pages in the configured Notion data source."""
    if not config.notion_token or not config.notion_database_id:
        return {"projects": [], "topics": []}

    source_id, _ = _notion_data_source(config)
    project_property = config.notion_project_property or "Project"
    topic_property = os.getenv("NOTION_THEME_PROPERTY", "Tema").strip() or "Tema"
    projects: set[str] = set()
    topics: set[str] = set()
    cursor: str | None = None

    # Options in a Notion property are historical schema values. The chat
    # catalog must instead mirror values actually assigned to pages.
    for _ in range(20):
        body: dict[str, Any] = {"page_size": 100}
        if cursor:
            body["start_cursor"] = cursor
        payload = _notion_request(
            config,
            f"/v1/data_sources/{source_id}/query",
            method="POST",
            body=body,
        )
        for page in payload.get("results") or []:
            if not isinstance(page, dict):
                continue
            properties = page.get("properties") or {}
            if not isinstance(properties, dict):
                continue
            projects.update(_notion_page_property_values(properties.get(project_property)))
            topics.update(_notion_page_property_values(properties.get(topic_property)))
        cursor = str(payload.get("next_cursor") or "").strip() or None
        if not payload.get("has_more") or not cursor:
            break
    return {
        "projects": sorted(projects, key=str.casefold),
        "topics": sorted(topics, key=str.casefold),
    }


def import_catalog_from_notion(config: Config) -> dict[str, list[str]]:
    """Synchronize the local catalog with the configured Notion pages."""
    return import_catalog_from_sources(config, ("notion",))


def import_catalog_from_sources(config: Config, sources: tuple[str, ...] = ()) -> dict[str, list[str]]:
    """Synchronize imported catalog values with the selected sources."""
    selected = {source.strip().lower() for source in sources if source.strip()}
    if not selected:
        selected = {"journal", "completed", "notion", "obsidian", "apple_notes", "knowledge"}
    loaders = {
        "journal": lambda: _journal_candidates(config),
        "completed": lambda: _completed_session_candidates(config),
        "notion": lambda: bootstrap_catalog_from_notion(config),
        "obsidian": lambda: _obsidian_candidates(config),
        "apple_notes": lambda: _apple_notes_candidates(config),
        "knowledge": lambda: _knowledge_candidates(config),
    }
    loaded: dict[str, dict[str, list[str]]] = {}
    for source in selected:
        loader = loaders.get(source)
        if loader is None:
            continue
        try:
            loaded[source] = loader()
        except Exception:
            # A temporarily unavailable source must not erase its previously
            # imported values. It will be reconciled on the next successful sync.
            continue
    return _sync_catalog_from_sources(config, selected, loaded)


def _sync_catalog_from_sources(
    config: Config,
    selected: set[str],
    loaded: dict[str, dict[str, list[str]]],
) -> dict[str, list[str]]:
    path = catalog_path(config)
    catalog = _load(path)
    now = datetime.now(timezone.utc).isoformat()
    changed = False

    for kind in _KINDS:
        current: dict[str, tuple[str, set[str]]] = {}
        for source, values in loaded.items():
            marker = _import_marker(source)
            for value in values.get(kind, []):
                name = value.strip()
                if not name:
                    continue
                key = name.casefold()
                existing = current.get(key)
                if existing:
                    current[key] = (existing[0], existing[1] | {marker})
                else:
                    current[key] = (name, {marker})
        retained: list[dict[str, Any]] = []
        existing: set[str] = set()
        for entry in catalog[kind]:
            name = str(entry.get("name") or "").strip()
            key = name.casefold()
            sources = {str(value) for value in entry.get("sources", [])}
            existing.add(key)
            manual_sources = {value for value in sources if not _is_import_marker(value)}
            retained_failed_source_markers = {
                value
                for value in sources
                if (source := _source_for_import_marker(value)) in selected and source not in loaded
            }
            imported_sources = current.get(key, (name, set()))[1]
            combined_sources = manual_sources | retained_failed_source_markers | imported_sources
            if not combined_sources:
                changed = True
                continue
            if combined_sources != sources:
                entry["sources"] = sorted(combined_sources)
                entry["updated_at"] = now
                changed = True
            retained.append(entry)
        for key, (name, markers) in current.items():
            if key not in existing:
                retained.append(
                    {"name": name, "created_at": now, "updated_at": now, "sources": sorted(markers)}
                )
                changed = True
        catalog[kind] = retained

    if changed:
        _save(path, catalog)
    return catalog_values(config)


def _import_marker(source: str) -> str:
    return f"{_IMPORT_SOURCE_PREFIX}{source}"


def _is_import_marker(source: str) -> bool:
    return source.startswith(_IMPORT_SOURCE_PREFIX) or source in _NOTION_MANAGED_SOURCES or source.startswith("sources:")


def _source_for_import_marker(marker: str) -> str | None:
    if marker.startswith(_IMPORT_SOURCE_PREFIX):
        return marker.removeprefix(_IMPORT_SOURCE_PREFIX)
    if marker == "notion_confirmed_import":
        return "notion"
    return None


def discard_unconfirmed_initial_imports(config: Config) -> dict[str, list[str]]:
    """Migrate the short-lived automatic import to the confirmed-only policy."""
    path = catalog_path(config)
    catalog = _load(path)
    changed = False
    for kind in _KINDS:
        confirmed = []
        for entry in catalog[kind]:
            sources = set(str(value) for value in entry.get("sources", []))
            if sources == {"notion_initial_import"}:
                changed = True
                continue
            confirmed.append(entry)
        catalog[kind] = confirmed
    if changed:
        _save(path, catalog)
    return catalog_values(config)


def _normalize_kind(kind: str) -> str:
    normalized = kind.strip().lower()
    aliases = {"project": "projects", "projects": "projects", "theme": "topics", "topic": "topics", "topics": "topics"}
    if normalized not in aliases:
        raise ValueError(f"Unsupported tag catalog kind: {kind}")
    return aliases[normalized]


def _load(path: Path) -> dict[str, list[dict[str, Any]]]:
    empty: dict[str, list[dict[str, Any]]] = {kind: [] for kind in _KINDS}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return empty
    if not isinstance(payload, dict):
        return empty
    for kind in _KINDS:
        entries = payload.get(kind)
        if isinstance(entries, list):
            empty[kind] = [entry for entry in entries if isinstance(entry, dict)]
    return empty


def _save(path: Path, catalog: dict[str, list[dict[str, Any]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _merge_candidates(target: dict[str, set[str]], values: dict[str, list[str]]) -> None:
    target["projects"].update(value.strip() for value in values.get("projects", []) if value.strip())
    target["topics"].update(value.strip() for value in values.get("topics", []) if value.strip())


def _safe_candidates(loader: Any) -> dict[str, list[str]]:
    try:
        return loader()
    except Exception:
        # Importing from one unavailable integration must not discard values
        # available from the user's other explicitly selected sources.
        return {"projects": [], "topics": []}


def _journal_candidates(config: Config) -> dict[str, list[str]]:
    root = getattr(config, "journal_root", None)
    if not root:
        return {"projects": [], "topics": []}
    path = Path(root).expanduser() / "index.sqlite"
    if not path.exists():
        return {"projects": [], "topics": []}
    try:
        with sqlite3.connect(path) as database:
            columns = {row[1] for row in database.execute("PRAGMA table_info(entries)")}
            project = "project" if "project" in columns else "''"
            theme = "theme" if "theme" in columns else "''"
            rows = database.execute(f"SELECT {project}, {theme} FROM entries").fetchall()
    except sqlite3.Error:
        return {"projects": [], "topics": []}
    return {
        "projects": [str(project or "") for project, _ in rows],
        "topics": [str(theme or "") for _, theme in rows],
    }


def _completed_session_candidates(config: Config) -> dict[str, list[str]]:
    done_dir = getattr(config, "done_dir", None)
    if not done_dir:
        return {"projects": [], "topics": []}
    projects: list[str] = []
    topics: list[str] = []
    for session in Path(done_dir).expanduser().glob("*"):
        if not session.is_dir():
            continue
        metadata = _read_json(session / "meeting_metadata.json")
        summary = _read_json(session / "omlx_summary.json")
        assigned_project = _read_json(session / "meeting_project.json")
        assigned_theme = _read_json(session / "meeting_theme.json")
        projects.extend(_values(assigned_project.get("project") or metadata.get("project") or summary.get("tag")))
        topics.extend(_values(assigned_theme.get("theme") or metadata.get("theme") or summary.get("theme")))
    return {"projects": projects, "topics": topics}


def _obsidian_candidates(config: Config) -> dict[str, list[str]]:
    vault = getattr(config, "obsidian_vault_path", None)
    if not vault:
        return {"projects": [], "topics": []}
    root = Path(vault).expanduser()
    folder = str(getattr(config, "obsidian_folder", "") or "").strip("/")
    if folder:
        root = root / folder
    if not root.exists():
        return {"projects": [], "topics": []}
    projects: list[str] = []
    topics: list[str] = []
    for note in root.rglob("*.md"):
        try:
            content = note.read_text(encoding="utf-8", errors="replace")[:8_000]
        except OSError:
            continue
        frontmatter = re.match(r"^---\s*\n(.*?)\n---", content, flags=re.DOTALL)
        if not frontmatter:
            continue
        projects.extend(_yaml_values(frontmatter.group(1), "project"))
        topics.extend(_yaml_values(frontmatter.group(1), "theme"))
    return {"projects": projects, "topics": topics}


def _apple_notes_candidates(config: Config) -> dict[str, list[str]]:
    """Read only tags from sessions that were actually published to Apple Notes."""
    done_dir = getattr(config, "done_dir", None)
    if not done_dir:
        return {"projects": [], "topics": []}
    projects: list[str] = []
    topics: list[str] = []
    for session in Path(done_dir).expanduser().glob("*"):
        if not session.is_dir() or not (session / "apple_notes_receipt.json").exists():
            continue
        metadata = _read_json(session / "meeting_metadata.json")
        summary = _read_json(session / "omlx_summary.json")
        assigned_project = _read_json(session / "meeting_project.json")
        assigned_theme = _read_json(session / "meeting_theme.json")
        projects.extend(_values(assigned_project.get("project") or metadata.get("project") or summary.get("tag")))
        topics.extend(_values(assigned_theme.get("theme") or metadata.get("theme") or summary.get("theme")))
    return {"projects": projects, "topics": topics}


def _knowledge_candidates(config: Config) -> dict[str, list[str]]:
    root = getattr(config, "journal_root", None)
    if not root:
        return {"projects": [], "topics": []}
    index_path = getattr(config, "knowledge_index_path", None) or default_knowledge_index_path(Path(root))
    try:
        documents = load_knowledge_documents(Path(index_path), ())
    except (OSError, sqlite3.Error):
        return {"projects": [], "topics": []}
    projects: list[str] = []
    topics: list[str] = []
    for document in documents:
        metadata = document.metadata or {}
        projects.extend(_values(metadata.get("project") or metadata.get("projects") or metadata.get("progetto")))
        topics.extend(_values(metadata.get("theme") or metadata.get("themes") or metadata.get("topic") or metadata.get("topics") or metadata.get("tema")))
    return {"projects": projects, "topics": topics}


def _read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _values(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, (list, tuple, set)):
        return [str(item).strip() for item in value if str(item).strip()]
    return []


def _yaml_values(frontmatter: str, key: str) -> list[str]:
    match = re.search(rf"(?m)^{re.escape(key)}:\s*(.+)$", frontmatter)
    if not match:
        return []
    value = match.group(1).strip().strip('"\'')
    if value.startswith("[") and value.endswith("]"):
        return [part.strip().strip('"\'') for part in value[1:-1].split(",") if part.strip()]
    return [value] if value else []


def _notion_data_source(config: Config) -> tuple[str, dict[str, Any]]:
    database_id = _clean_id(config.notion_database_id or "")
    database = _notion_request(config, f"/v1/databases/{database_id}")
    source_id = ((database.get("data_sources") or [{}])[0].get("id")) or database_id
    source = _notion_request(config, f"/v1/data_sources/{source_id}")
    properties = source.get("properties") if isinstance(source.get("properties"), dict) else {}
    return str(source_id), properties


def _notion_page_property_values(property_value: Any) -> set[str]:
    if not isinstance(property_value, dict):
        return set()
    kind = str(property_value.get("type") or "")
    value = property_value.get(kind)
    if kind in {"select", "status"} and isinstance(value, dict):
        name = str(value.get("name") or "").strip()
        return {name} if name else set()
    if kind == "multi_select" and isinstance(value, list):
        return {
            str(option.get("name") or "").strip()
            for option in value
            if isinstance(option, dict) and str(option.get("name") or "").strip()
        }
    return set()


def _notion_request(
    config: Config,
    path: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(
        f"https://api.notion.com{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {config.notion_token}",
            "Notion-Version": "2026-03-11",
            "Content-Type": "application/json",
        },
    )
    ssl_context = ssl.create_default_context(cafile=certifi.where())
    with urllib.request.urlopen(request, timeout=20, context=ssl_context) as response:  # nosec B310: fixed Notion API origin
        payload = json.loads(response.read().decode("utf-8"))
    return payload if isinstance(payload, dict) else {}


def _clean_id(value: str) -> str:
    compact = value.replace("-", "").strip()
    matches = re.findall(r"[0-9a-fA-F]{32}", compact)
    return matches[-1] if matches else compact
