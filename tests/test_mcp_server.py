from __future__ import annotations

import io
import json
import sqlite3
from pathlib import Path

from meeting_pilot.config import Config
from meeting_pilot.mcp_server import serve

LECTURE_PAGE = """---
title: "Entropia"
date: 2026-10-09
project: "Fisica"
type: "study"
original_path: "/Users/studente/Lezioni/Lezione 3.mp3"
---

# Entropia

## Summary

L'entropia misura il disordine.

- [ ] Esercizi capitolo 4 — **Studente** 📅 2026-10-16
- [x] Leggere il capitolo 3

## Transcript by slide

> **Speaker 1:** Oggi parliamo di entropia e del secondo principio.
"""


def _config(tmp_path: Path, monkeypatch) -> Config:
    monkeypatch.setenv("MEETINGS_ROOT", str(tmp_path))
    monkeypatch.setenv("JOURNAL_ROOT", str(tmp_path / "Diary"))
    config = Config.from_env()
    config.ensure_dirs()
    return config


def _archived_meeting(config: Config) -> None:
    session = config.done_dir / "20260930-150500-roadmap"
    session.mkdir(parents=True)
    (session / "omlx_summary.json").write_text(json.dumps({
        "title": "Q4 Roadmap",
        "tag": "Atlas",
        "summary": "Offline mode slips to Q1.",
        "decisions": [{"text": "Ship offline mode in Q1", "owner": "Priya"}],
        "action_items": [
            {"task": "Write the offline spec", "owner": "Lucas", "due_date": "2026-10-07", "status": "open"},
            {"task": "Book the venue", "owner": "Priya", "status": "done"},
        ],
    }), encoding="utf-8")
    (session / "meeting_metadata.json").write_text(json.dumps({
        "recording_start": "2026-09-30T15:05:00", "participants": ["Priya", "Lucas"], "duration_seconds": 1800,
    }), encoding="utf-8")
    (session / "transcript.txt").write_text("Priya: the offline mode needs another quarter. " * 50, encoding="utf-8")


def _diary_lecture(config: Config) -> None:
    """A Diary page whose archived session is gone."""
    note = config.journal_root / "2026" / "10" / "2026-10-09 - Entropia.md"
    note.parent.mkdir(parents=True)
    note.write_text(LECTURE_PAGE, encoding="utf-8")
    with sqlite3.connect(config.journal_root / "index.sqlite") as database:
        database.execute(
            "CREATE TABLE entries (session_id TEXT PRIMARY KEY, title TEXT NOT NULL, meeting_date TEXT, summary TEXT,"
            " path TEXT NOT NULL, updated_at TEXT NOT NULL, project TEXT, theme TEXT, destination TEXT, session_path TEXT)"
        )
        database.execute(
            "INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("20261009-lecture", "Entropia", "2026-10-09", "L'entropia misura il disordine.", str(note),
             "2026-10-09", "Fisica", "Termodinamica", "Diario", str(config.meetings_root / "processing" / "gone")),
        )


def _session(config: Config, *messages: dict) -> list[dict]:
    output = io.StringIO()
    serve(config, io.StringIO("\n".join(json.dumps(message) for message in messages) + "\n"), output)
    return [json.loads(line) for line in output.getvalue().splitlines()]


def _call(config: Config, name: str, **arguments) -> dict:
    reply = _session(config, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}})[0]
    return reply["result"]


def test_handshake_lists_read_only_tools_and_ignores_notifications(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    replies = _session(
        config,
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "resources/list"},
    )
    assert [reply["id"] for reply in replies] == [1, 2, 3], "a notification gets no reply"
    assert replies[0]["result"]["protocolVersion"] == "2025-03-26"
    assert replies[0]["result"]["serverInfo"]["name"] == "meeting-pilot"
    tools = replies[1]["result"]["tools"]
    assert {tool["name"] for tool in tools} == {"list_meetings", "search_meetings", "get_meeting", "list_open_actions", "list_projects"}
    assert all(tool["annotations"]["readOnlyHint"] for tool in tools)
    assert replies[2]["error"]["code"] == -32601


def test_unknown_protocol_version_gets_the_newest(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    reply = _session(config, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})[0]
    assert reply["result"]["protocolVersion"] == "2025-06-18"


def test_meetings_from_the_diary_and_the_archive_newest_first(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    _archived_meeting(config)
    _diary_lecture(config)

    meetings = _call(config, "list_meetings")["structuredContent"]["meetings"]
    assert [(meeting["title"], meeting["date"], meeting["kind"]) for meeting in meetings] == [
        ("Entropia", "2026-10-09", "lecture"),
        ("Q4 Roadmap", "2026-09-30", "meeting"),
    ]
    assert meetings[0]["source"] == "imported file"
    only_september = _call(config, "list_meetings", end_date="2026-09-30")["structuredContent"]
    assert [meeting["title"] for meeting in only_september["meetings"]] == ["Q4 Roadmap"]


def test_an_archived_meeting_comes_with_its_notes_and_a_transcript_in_parts(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    _archived_meeting(config)

    meeting = _call(config, "get_meeting", meeting_id="20260930-150500-roadmap", transcript_max_chars=1000)["structuredContent"]
    assert meeting["notes"]["decisions"] == [{"text": "Ship offline mode in Q1", "owner": "Priya"}]
    assert meeting["participants"] == ["Priya", "Lucas"]
    assert meeting["duration_minutes"] == 30
    assert len(meeting["transcript"]) == 1000
    assert meeting["transcript_next_offset"] == 1000

    rest = _call(config, "get_meeting", meeting_id="20260930-150500-roadmap", transcript_offset=1000, transcript_max_chars=200000)
    assert "transcript_next_offset" not in rest["structuredContent"]


def test_a_page_without_its_session_splits_notes_from_transcript(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    _diary_lecture(config)

    meeting = _call(config, "get_meeting", meeting_id="20261009-lecture")["structuredContent"]
    assert "L'entropia misura il disordine." in meeting["notes_markdown"]
    assert "secondo principio" not in meeting["notes_markdown"]
    assert "secondo principio" in meeting["transcript"]


def test_open_actions_come_from_summaries_and_from_pages(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    _archived_meeting(config)
    _diary_lecture(config)

    actions = _call(config, "list_open_actions")["structuredContent"]["actions"]
    assert [(action["task"], action["owner"], action["due_date"]) for action in actions] == [
        ("Esercizi capitolo 4", "Studente", "2026-10-16"),
        ("Write the offline spec", "Lucas", "2026-10-07"),
    ], "done tasks are left out"
    assert [action["task"] for action in _call(config, "list_open_actions", owner="lucas")["structuredContent"]["actions"]] == [
        "Write the offline spec"
    ]


def test_search_finds_what_was_said(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    _archived_meeting(config)

    results = _call(config, "search_meetings", query="offline quarter")["structuredContent"]["results"]
    assert results and results[0]["meeting_id"] == "20260930-150500-roadmap"


def test_mistakes_are_tool_errors_the_model_can_read(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    assert _call(config, "get_meeting", meeting_id="missing")["isError"] is True
    assert _call(config, "search_meetings")["isError"] is True


def test_nothing_but_protocol_reaches_stdout(tmp_path: Path, monkeypatch, capsys) -> None:
    config = _config(tmp_path, monkeypatch)
    output = io.StringIO()
    serve(config, io.StringIO('not json\n{"jsonrpc":"2.0","id":1,"method":"ping"}\n'), output)
    replies = [json.loads(line) for line in output.getvalue().splitlines()]
    assert replies[0]["error"]["code"] == -32700
    assert replies[1]["result"] == {}
