from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class KnowledgeDocument:
    source: str
    external_id: str
    title: str
    text: str
    url: str
    updated_at: str | None = None
    metadata: dict[str, Any] | None = None


def default_knowledge_index_path(journal_root: Path) -> Path:
    return journal_root.expanduser() / "knowledge.sqlite"


def index_knowledge_documents(index_path: Path, documents: Iterable[KnowledgeDocument]) -> dict[str, Any]:
    index_path = index_path.expanduser()
    index_path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with sqlite3.connect(index_path) as database:
        database.execute(
            """CREATE TABLE IF NOT EXISTS documents (
                source TEXT NOT NULL,
                external_id TEXT NOT NULL,
                title TEXT NOT NULL,
                text TEXT NOT NULL,
                url TEXT NOT NULL,
                updated_at TEXT,
                metadata_json TEXT,
                indexed_at TEXT NOT NULL,
                PRIMARY KEY(source, external_id)
            )"""
        )
        for document in documents:
            if not document.text.strip():
                continue
            database.execute(
                """INSERT INTO documents(
                       source, external_id, title, text, url, updated_at, metadata_json, indexed_at
                   )
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(source, external_id) DO UPDATE SET
                       title=excluded.title, text=excluded.text, url=excluded.url,
                       updated_at=excluded.updated_at, metadata_json=excluded.metadata_json,
                       indexed_at=excluded.indexed_at""",
                (
                    _normalize_source(document.source),
                    document.external_id,
                    document.title,
                    document.text,
                    document.url,
                    document.updated_at,
                    json.dumps(document.metadata or {}, ensure_ascii=False),
                    datetime.now(timezone.utc).isoformat(),
                ),
            )
            count += 1
    return {"indexed": count, "path": str(index_path)}


def load_knowledge_documents(index_path: Path, sources: tuple[str, ...] = ()) -> list[KnowledgeDocument]:
    index_path = index_path.expanduser()
    if not index_path.exists():
        return []
    try:
        with sqlite3.connect(index_path) as database:
            database.row_factory = sqlite3.Row
            if sources:
                normalized = tuple(_normalize_source(source) for source in sources)
                placeholders = ",".join("?" for _ in normalized)
                rows = database.execute(
                    f"SELECT source, external_id, title, text, url, updated_at, metadata_json FROM documents WHERE source IN ({placeholders})",
                    normalized,
                ).fetchall()
            else:
                rows = database.execute(
                    "SELECT source, external_id, title, text, url, updated_at, metadata_json FROM documents"
                ).fetchall()
    except sqlite3.Error:
        return []
    return [
        KnowledgeDocument(
            source=str(row["source"]),
            external_id=str(row["external_id"]),
            title=str(row["title"]),
            text=str(row["text"]),
            url=str(row["url"]),
            updated_at=str(row["updated_at"] or "") or None,
            metadata=_loads_dict(str(row["metadata_json"] or "{}")),
        )
        for row in rows
    ]


def mongodb_documents_from_collection(
    uri: str,
    database: str,
    collection: str,
    title_field: str = "title",
    text_field: str = "text",
    url_field: str = "url",
    updated_field: str = "updated_at",
    query: dict[str, Any] | None = None,
    limit: int = 500,
) -> list[KnowledgeDocument]:
    try:
        from pymongo import MongoClient
    except ImportError as exc:
        raise RuntimeError("pymongo non installato: installalo per indicizzare MongoDB.") from exc
    client = MongoClient(uri, serverSelectionTimeoutMS=8000)
    cursor = client[database][collection].find(query or {}, limit=max(1, limit))
    documents = []
    for item in cursor:
        external_id = str(item.get("_id"))
        title = str(item.get(title_field) or external_id)
        text = str(item.get(text_field) or "")
        url = str(item.get(url_field) or f"mongodb://{database}/{collection}/{external_id}")
        updated = item.get(updated_field)
        documents.append(
            KnowledgeDocument(
                source="mongodb",
                external_id=external_id,
                title=title,
                text=text,
                url=url,
                updated_at=updated.isoformat() if hasattr(updated, "isoformat") else (str(updated) if updated else None),
                metadata={
                    "database": database,
                    "collection": collection,
                    **_project_metadata_from_record(item),
                },
            )
        )
    return documents


def documents_from_json_file(
    path: Path,
    source: str,
    id_field: str = "id",
    title_field: str = "title",
    text_field: str = "text",
    url_field: str = "url",
    updated_field: str = "updated_at",
) -> list[KnowledgeDocument]:
    records = _read_json_records(path)
    documents = []
    for index, item in enumerate(records, start=1):
        text = str(item.get(text_field) or "")
        if not text.strip():
            continue
        external_id = str(item.get(id_field) or item.get("_id") or index)
        documents.append(
            KnowledgeDocument(
                source=source,
                external_id=external_id,
                title=str(item.get(title_field) or external_id),
                text=text,
                url=str(item.get(url_field) or f"{source}://{external_id}"),
                updated_at=str(item.get(updated_field) or "") or None,
                metadata={key: value for key, value in item.items() if key not in {id_field, title_field, text_field, url_field, updated_field}},
            )
        )
    return documents


def _read_json_records(path: Path) -> list[dict[str, Any]]:
    text = path.expanduser().read_text(encoding="utf-8")
    if path.suffix.lower() == ".jsonl":
        records = []
        for line in text.splitlines():
            if not line.strip():
                continue
            data = json.loads(line)
            if isinstance(data, dict):
                records.append(data)
        return records
    data = json.loads(text)
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict):
        items = data.get("items") or data.get("documents") or data.get("results")
        if isinstance(items, list):
            return [item for item in items if isinstance(item, dict)]
        return [data]
    return []


def _normalize_source(source: str) -> str:
    return source.strip().lower().replace(" ", "_").replace("-", "_")


def _project_metadata_from_record(record: dict[str, Any]) -> dict[str, Any]:
    """Keep project labels queryable without copying arbitrary MongoDB fields."""
    metadata: dict[str, Any] = {}
    for key in ("project", "project_name", "progetto", "projects"):
        if key not in record:
            continue
        try:
            metadata[key] = json.loads(json.dumps(record[key], default=str, ensure_ascii=False))
        except (TypeError, ValueError):
            metadata[key] = str(record[key])
    return metadata


def _loads_dict(value: str) -> dict[str, Any]:
    try:
        data = json.loads(value)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}
