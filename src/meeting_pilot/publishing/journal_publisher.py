from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..artifacts import MeetingArtifacts, write_journal_receipt
from .obsidian_publisher import _note_content, _note_date, _note_title, _sanitize_filename, _unique_path
from ..config import Config


def publish_to_journal(config: Config, artifacts: MeetingArtifacts) -> dict[str, Any]:
    """Write a portable local meeting page and its small, rebuildable search index."""
    root = config.journal_root.expanduser()
    title = _note_title(artifacts)
    date = _note_date(artifacts)
    dated_folder = root / _date_folder(date)
    dated_folder.mkdir(parents=True, exist_ok=True)
    note_path = _unique_path(dated_folder / f"{_sanitize_filename(date)} - {_sanitize_filename(title)}.md")
    note_path.write_text(_note_content(config, artifacts, title, date, header_callout=False), encoding="utf-8")
    _index_note(root / "index.sqlite", artifacts, title, date, note_path)

    receipt = {
        "provider": "journal",
        "root": str(root),
        "title": title,
        "path": str(note_path),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    write_journal_receipt(artifacts.session_dir, receipt)
    return receipt


def _date_folder(date: str) -> Path:
    try:
        parsed = datetime.fromisoformat(date.replace("Z", "+00:00"))
        return Path(f"{parsed.year:04d}") / f"{parsed.month:02d}"
    except ValueError:
        return Path("Senza data")


def _index_note(index_path: Path, artifacts: MeetingArtifacts, title: str, date: str, note_path: Path) -> None:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    with sqlite3.connect(index_path) as database:
        database.execute(
            """CREATE TABLE IF NOT EXISTS entries (
                session_id TEXT PRIMARY KEY, title TEXT NOT NULL, meeting_date TEXT,
                summary TEXT, path TEXT NOT NULL, updated_at TEXT NOT NULL
            )"""
        )
        _ensure_index_columns(database)
        database.execute(
            """INSERT INTO entries(
                   session_id, title, meeting_date, summary, path, updated_at,
                   project, theme, destination, session_path
               )
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(session_id) DO UPDATE SET title=excluded.title,
                   meeting_date=excluded.meeting_date, summary=excluded.summary,
                   path=excluded.path, updated_at=excluded.updated_at,
                   project=excluded.project, theme=excluded.theme,
                   destination=excluded.destination, session_path=excluded.session_path""",
            (
                artifacts.session_dir.name,
                title,
                date,
                str(summary.get("summary") or artifacts.summary_markdown or ""),
                str(note_path),
                datetime.now(timezone.utc).isoformat(),
                str(metadata.get("project") or summary.get("tag") or ""),
                str(metadata.get("theme") or summary.get("theme") or ""),
                "Diario",
                str(artifacts.session_dir),
            ),
        )


def _ensure_index_columns(database: sqlite3.Connection) -> None:
    existing = {row[1] for row in database.execute("PRAGMA table_info(entries)")}
    for name, definition in {
        "project": "TEXT",
        "theme": "TEXT",
        "destination": "TEXT",
        "session_path": "TEXT",
    }.items():
        if name not in existing:
            database.execute(f"ALTER TABLE entries ADD COLUMN {name} {definition}")
