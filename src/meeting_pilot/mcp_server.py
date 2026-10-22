"""Meeting Pilot as an MCP server, so Claude and other MCP clients can read the meetings
and lectures this Mac has transcribed.

Started by the client as `MeetingPilotCLI mcp` and spoken to over stdio: one JSON-RPC
message per line in, one per line out. Every tool only reads; the meetings stay on this
Mac until the client's model reads what a tool returns. No SDK: the protocol subset a
tools-only server needs is small, and the CLI bundled in the app stays dependency-free.
"""
from __future__ import annotations

import json
import re
import sqlite3
from importlib import metadata as package_metadata
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, TextIO

from .chat.meeting_chat import (
    MeetingChatFilters,
    _read_transcript,
    _slides_text,
    available_chat_filter_values,
    search_meeting_passages,
)
from .config import Config
from .language import LABELS

SERVER_NAME = "meeting-pilot"
try:
    SERVER_VERSION = package_metadata.version("meeting-pilot")
except package_metadata.PackageNotFoundError:
    SERVER_VERSION = "unknown"
# Newest first; a client asking for another version gets the newest.
PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
# A two-hour lecture is about 120,000 characters: more than a client wants in one reply.
DEFAULT_TRANSCRIPT_CHARS = 40_000

INSTRUCTIONS = (
    "Meeting Pilot holds the meetings, lectures and videos the user recorded or imported on this Mac: "
    "summaries, decisions, action items, study notes, the steps and tools of tutorials, transcripts and slides. Use list_meetings "
    "to browse by date or project, search_meetings to find what was said about something, "
    "get_meeting for one meeting in full and list_open_actions for the tasks still to do. "
    "Cite meetings by title and date."
)


@dataclass(frozen=True)
class Meeting:
    id: str
    title: str
    date: str | None
    project: str
    theme: str
    session: Path | None
    note: Path | None

    def summary(self) -> dict[str, Any]:
        return _read_json(self.session / "omlx_summary.json") if self.session else {}

    def metadata(self) -> dict[str, Any]:
        return _read_json(self.session / "meeting_metadata.json") if self.session else {}

    def page(self) -> tuple[dict[str, str], str, str]:
        """The Diary page as (frontmatter, notes, transcript), for meetings whose archived
        session is gone."""
        return _split_page(_read_text(self.note)) if self.note else ({}, "", "")

    def overview(self) -> dict[str, Any]:
        summary = self.summary()
        metadata = self.metadata()
        if not self.session:
            # The page's frontmatter says what the session would have.
            front = self.page()[0]
            summary = {"profile": {"study": "student", "video": "video"}[front["type"]]} if front.get("type") in {"study", "video"} else {}
            metadata = {key: front[key] for key in ("source_url", "original_path") if front.get(key)}
            if metadata:
                metadata["origin"] = "import"
        overview: dict[str, Any] = {
            "id": self.id,
            "title": self.title,
            "date": self.date,
            "kind": _kind(summary),
            "source": _source(metadata),
        }
        for key, value in (("project", self.project), ("theme", self.theme)):
            if value:
                overview[key] = value
        if metadata.get("source_url"):
            overview["source_url"] = metadata["source_url"]
        if self.note:
            overview["note_path"] = str(self.note)
        return overview


class MeetingCatalog:
    """Every meeting the Diary indexed, plus archived sessions it has no page for."""

    def __init__(self, config: Config):
        self.config = config

    def meetings(self) -> list[Meeting]:
        by_id: dict[str, Meeting] = {}
        for meeting in self._indexed():
            by_id[meeting.id] = meeting
        done = self.config.done_dir.expanduser()
        if done.is_dir():
            for session in done.iterdir():
                if session.is_dir() and session.name not in by_id:
                    by_id[session.name] = _meeting_from_session(session)
        return sorted(by_id.values(), key=lambda meeting: (meeting.date or "", meeting.id), reverse=True)

    def find(self, meeting_id: str) -> Meeting | None:
        wanted = meeting_id.strip()
        return next((meeting for meeting in self.meetings() if meeting.id == wanted), None)

    def _indexed(self) -> list[Meeting]:
        index = self.config.journal_root.expanduser() / "index.sqlite"
        if not index.exists():
            return []
        try:
            with sqlite3.connect(f"file:{index}?mode=ro", uri=True) as database:
                database.row_factory = sqlite3.Row
                columns = {row[1] for row in database.execute("PRAGMA table_info(entries)")}
                optional = ", ".join(name if name in columns else f"'' AS {name}" for name in ("project", "theme", "session_path"))
                rows = database.execute(f"SELECT session_id, title, meeting_date, path, {optional} FROM entries").fetchall()
        except sqlite3.Error:
            return []
        meetings = []
        for row in rows:
            session_id = str(row["session_id"] or "")
            if not session_id:
                continue
            meetings.append(
                Meeting(
                    id=session_id,
                    title=str(row["title"] or session_id),
                    date=str(row["meeting_date"] or "") or None,
                    project=str(row["project"] or ""),
                    theme=str(row["theme"] or ""),
                    session=self._session_dir(session_id, str(row["session_path"] or "")),
                    note=Path(row["path"]) if row["path"] and Path(row["path"]).is_file() else None,
                )
            )
        return meetings

    def _session_dir(self, session_id: str, recorded: str) -> Path | None:
        """Where the session's files are now: the Diary remembers where they were when
        it wrote the page, and sessions move to `done` once published."""
        for candidate in (Path(recorded) if recorded else None, self.config.done_dir.expanduser() / session_id):
            if candidate and candidate.is_dir():
                return candidate
        return None


def _meeting_from_session(session: Path) -> Meeting:
    summary = _read_json(session / "omlx_summary.json")
    metadata = _read_json(session / "meeting_metadata.json")
    return Meeting(
        id=session.name,
        title=str(summary.get("title") or metadata.get("title") or session.name),
        date=str(metadata.get("start") or metadata.get("recording_start") or summary.get("date") or "")[:10] or None,
        project=str(metadata.get("project") or summary.get("tag") or ""),
        theme=str(metadata.get("theme") or summary.get("theme") or ""),
        session=session,
        note=None,
    )


# MARK: - Tools


def list_meetings(catalog: MeetingCatalog, arguments: dict[str, Any]) -> dict[str, Any]:
    start, end = _text(arguments.get("start_date")), _text(arguments.get("end_date"))
    project = _text(arguments.get("project")).lower()
    title = _text(arguments.get("title_contains")).lower()
    limit = _limit(arguments.get("limit"), default=25, maximum=200)
    matches = [
        meeting
        for meeting in catalog.meetings()
        if _in_range(meeting.date, start, end)
        and (not project or project in meeting.project.lower())
        and (not title or title in meeting.title.lower())
    ]
    return {"total": len(matches), "meetings": [meeting.overview() for meeting in matches[:limit]]}


def search_meetings(catalog: MeetingCatalog, arguments: dict[str, Any]) -> dict[str, Any]:
    query = _text(arguments.get("query"))
    if not query:
        raise ToolError("query is required")
    filters = MeetingChatFilters(
        projects=tuple(_strings(arguments.get("projects"))),
        themes=tuple(_strings(arguments.get("themes"))),
        start_date=_text(arguments.get("start_date")) or None,
        end_date=_text(arguments.get("end_date")) or None,
    )
    passages = search_meeting_passages(catalog.config, query, filters, limit=_limit(arguments.get("limit"), default=8, maximum=30))
    return {
        "results": [
            {
                "meeting_id": passage.document.session_id,
                "title": passage.document.title,
                "date": passage.document.date,
                "project": passage.document.project or None,
                "passage": passage.text,
            }
            for passage in passages
        ]
    }


def get_meeting(catalog: MeetingCatalog, arguments: dict[str, Any]) -> dict[str, Any]:
    meeting = catalog.find(_text(arguments.get("meeting_id")))
    if meeting is None:
        raise ToolError("No meeting with this id: use list_meetings or search_meetings to find one.")
    result = meeting.overview()
    summary = meeting.summary()
    metadata = meeting.metadata()
    if summary:
        result["notes"] = {key: value for key, value in summary.items() if key not in {"title", "tag", "theme", "date"} and value}
    transcript = ""
    if meeting.session:
        transcript = _read_transcript(meeting.session)
    elif meeting.note:
        # No archived session: the Diary page is all there is.
        _, notes, transcript = meeting.page()
        result["notes_markdown"] = notes
    participants = metadata.get("participants") or summary.get("participants")
    if participants:
        result["participants"] = participants
    if metadata.get("duration_seconds"):
        result["duration_minutes"] = round(float(metadata["duration_seconds"]) / 60)
    if meeting.session and arguments.get("include_slides", True):
        slides = _slides_text(meeting.session)
        if slides:
            result["slides"] = slides
    if transcript and arguments.get("include_transcript", True):
        offset = max(int(arguments.get("transcript_offset") or 0), 0)
        size = _limit(arguments.get("transcript_max_chars"), default=DEFAULT_TRANSCRIPT_CHARS, maximum=200_000)
        result["transcript"] = transcript[offset:offset + size]
        result["transcript_chars"] = len(transcript)
        if offset + size < len(transcript):
            result["transcript_next_offset"] = offset + size
    return result


def list_open_actions(catalog: MeetingCatalog, arguments: dict[str, Any]) -> dict[str, Any]:
    start, end = _text(arguments.get("start_date")), _text(arguments.get("end_date"))
    project = _text(arguments.get("project")).lower()
    owner = _text(arguments.get("owner")).lower()
    actions = []
    for meeting in catalog.meetings():
        if not _in_range(meeting.date, start, end) or (project and project not in meeting.project.lower()):
            continue
        summary = meeting.summary()
        # Lecture notes call them assignments; a page without its session lists them as tasks.
        items = list(summary.get("action_items") or []) + list(summary.get("assignments") or [])
        if not meeting.session:
            items = _page_tasks(meeting.page()[1])
        for item in items:
            if not isinstance(item, dict) or str(item.get("status") or "open").lower() not in {"open", ""}:
                continue
            if owner and owner not in str(item.get("owner") or "").lower():
                continue
            actions.append(
                {
                    "task": item.get("task"),
                    "owner": item.get("owner"),
                    "due_date": item.get("due_date"),
                    "meeting_id": meeting.id,
                    "meeting": meeting.title,
                    "date": meeting.date,
                    "project": meeting.project or None,
                }
            )
    return {"actions": actions}


def list_projects(catalog: MeetingCatalog, arguments: dict[str, Any]) -> dict[str, Any]:
    return available_chat_filter_values(catalog.config)


_DATE_PROPERTIES = {
    "start_date": {"type": "string", "description": "Inclusive start date, YYYY-MM-DD."},
    "end_date": {"type": "string", "description": "Inclusive end date, YYYY-MM-DD."},
}

TOOLS: dict[str, tuple[Callable[[MeetingCatalog, dict[str, Any]], dict[str, Any]], dict[str, Any]]] = {
    "list_meetings": (
        list_meetings,
        {
            "title": "List meetings",
            "description": "Meetings, lectures and videos, newest first, with their id, title, date, project and kind (meeting, lecture or video). Filter by date, project or words in the title.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    **_DATE_PROPERTIES,
                    "project": {"type": "string", "description": "Project or course name, or part of it."},
                    "title_contains": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 25},
                },
            },
        },
    ),
    "search_meetings": (
        search_meetings,
        {
            "title": "Search meetings",
            "description": "Passages from summaries, transcripts and slides that match the query, best first. Use words likely to have been said.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "projects": {"type": "array", "items": {"type": "string"}},
                    "themes": {"type": "array", "items": {"type": "string"}},
                    **_DATE_PROPERTIES,
                    "limit": {"type": "integer", "minimum": 1, "maximum": 30, "default": 8},
                },
                "required": ["query"],
            },
        },
    ),
    "get_meeting": (
        get_meeting,
        {
            "title": "Get a meeting",
            "description": (
                "One meeting in full: its notes (summary, decisions, action items; for a lecture key concepts, "
                "assignments and exam hints; for a video steps, key points, tools and tips), "
                "participants, slides and transcript. Long transcripts come in parts: "
                "pass transcript_next_offset as transcript_offset for the next one."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "meeting_id": {"type": "string", "description": "The id from list_meetings or search_meetings."},
                    "include_transcript": {"type": "boolean", "default": True},
                    "include_slides": {"type": "boolean", "default": True},
                    "transcript_offset": {"type": "integer", "minimum": 0, "default": 0},
                    "transcript_max_chars": {"type": "integer", "minimum": 1000, "maximum": 200000, "default": DEFAULT_TRANSCRIPT_CHARS},
                },
                "required": ["meeting_id"],
            },
        },
    ),
    "list_open_actions": (
        list_open_actions,
        {
            "title": "List open actions",
            "description": "Open action items from meetings and assignments from lectures, with owner, due date and the meeting they came from.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    **_DATE_PROPERTIES,
                    "project": {"type": "string"},
                    "owner": {"type": "string", "description": "Name of the person responsible, or part of it."},
                },
            },
        },
    ),
    "list_projects": (
        list_projects,
        {
            "title": "List projects and themes",
            "description": "The projects (or courses) and themes meetings are filed under, for filtering the other tools.",
            "inputSchema": {"type": "object", "properties": {}},
        },
    ),
}


# MARK: - Protocol


class ToolError(Exception):
    """A mistake in the call the model can correct, reported as a tool result."""


def tool_descriptions() -> list[dict[str, Any]]:
    return [
        {"name": name, **description, "annotations": {"readOnlyHint": True, "openWorldHint": False}}
        for name, (_, description) in TOOLS.items()
    ]


def handle_message(catalog: MeetingCatalog, message: dict[str, Any]) -> dict[str, Any] | None:
    """The reply to one JSON-RPC message; None for notifications."""
    method = message.get("method")
    if "id" not in message:
        return None
    request_id = message["id"]
    params = message.get("params") if isinstance(message.get("params"), dict) else {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        return _result(request_id, {
            "protocolVersion": requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "title": "Meeting Pilot", "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS,
        })
    if method == "ping":
        return _result(request_id, {})
    if method == "tools/list":
        return _result(request_id, {"tools": tool_descriptions()})
    if method == "tools/call":
        name = params.get("name")
        if name not in TOOLS:
            return _error(request_id, -32602, f"Unknown tool: {name}")
        arguments = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
        try:
            payload = TOOLS[name][0](catalog, arguments)
        except ToolError as exc:
            return _result(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
        except Exception as exc:  # noqa: BLE001 - one broken session must not end the server
            print(f"meeting-pilot mcp: {name} failed: {exc!r}", file=sys.stderr)
            return _result(request_id, {"content": [{"type": "text", "text": f"{name} failed: {exc}"}], "isError": True})
        text = json.dumps(payload, ensure_ascii=False, indent=1)
        return _result(request_id, {"content": [{"type": "text", "text": text}], "structuredContent": payload})
    return _error(request_id, -32601, f"Method not found: {method}")


def serve(config: Config, input_stream: TextIO | None = None, output_stream: TextIO | None = None) -> None:
    """Answers until the client closes stdin. Anything else that prints goes to stderr:
    on stdout it would corrupt the protocol."""
    input_stream = input_stream or sys.stdin
    output_stream = output_stream or sys.stdout
    stdout, sys.stdout = sys.stdout, sys.stderr
    try:
        _answer(MeetingCatalog(config), input_stream, output_stream)
    finally:
        sys.stdout = stdout


def _answer(catalog: MeetingCatalog, input_stream: TextIO, output_stream: TextIO) -> None:
    for line in input_stream:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            _write(output_stream, _error(None, -32700, "Parse error"))
            continue
        if isinstance(message, list):
            replies = [reply for item in message if isinstance(item, dict) and (reply := handle_message(catalog, item))]
            if replies:
                _write(output_stream, replies)
        elif isinstance(message, dict):
            reply = handle_message(catalog, message)
            if reply:
                _write(output_stream, reply)
        else:
            _write(output_stream, _error(None, -32600, "Invalid request"))


def _write(stream: TextIO, payload: Any) -> None:
    stream.write(json.dumps(payload, ensure_ascii=False) + "\n")
    stream.flush()


def _result(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


# MARK: - Helpers


_TRANSCRIPT_HEADINGS = {
    table[key].strip().lower()
    for table in LABELS.values()
    for key in ("full_transcript", "transcript_by_slide", "transcription")
    if key in table
}


def _split_page(text: str) -> tuple[dict[str, str], str, str]:
    front: dict[str, str] = {}
    body = text
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            for line in text[4:end].splitlines():
                key, separator, value = line.partition(":")
                if separator and not line.startswith(" ") and value.strip():
                    front[key.strip()] = value.strip().strip('"')
            body = text[end + 4:].lstrip("\n")
    lines = body.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("## ") and line[3:].strip().lower() in _TRANSCRIPT_HEADINGS:
            return front, "\n".join(lines[:index]).strip(), "\n".join(lines[index + 1:]).strip()
    return front, body.strip(), ""


_TASK = re.compile(r"^\s*- \[ \] (?P<task>.+?)(?: — \*\*(?P<owner>[^*]+)\*\*)?(?: 📅 (?P<due>\S+))?\s*$")


def _page_tasks(notes: str) -> list[dict[str, Any]]:
    """The open tasks of a Diary page, written as `- [ ] task — **Owner** 📅 date`."""
    tasks = []
    for line in notes.splitlines():
        match = _TASK.match(line)
        if match:
            tasks.append({"task": match["task"], "owner": match["owner"], "due_date": match["due"], "status": "open"})
    return tasks


def _kind(summary: dict[str, Any]) -> str:
    if summary.get("profile") == "video" or "steps" in summary or "key_points" in summary:
        return "video"
    return "lecture" if summary.get("profile") == "student" or "key_concepts" in summary else "meeting"


def _source(metadata: dict[str, Any]) -> str:
    if metadata.get("origin") == "import":
        return "youtube" if metadata.get("source_url") else "imported file"
    return "recording"


def _in_range(date: str | None, start: str, end: str) -> bool:
    day = (date or "")[:10]
    if (start or end) and not day:
        return False
    return (not start or day >= start[:10]) and (not end or day <= end[:10])


def _limit(value: Any, default: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return min(max(number, 1), maximum)


def _strings(value: Any) -> list[str]:
    if isinstance(value, str):
        value = [value]
    return [str(item).strip() for item in value or [] if str(item).strip()]


def _text(value: Any) -> str:
    return str(value or "").strip()


def _read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""
