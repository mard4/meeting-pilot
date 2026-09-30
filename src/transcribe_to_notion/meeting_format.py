"""Human-readable meeting facts shared by every publisher (Notion, Obsidian, Diary)."""
from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from .artifacts import MeetingArtifacts

WEEKDAYS = {
    "it": ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"],
    "en": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
}
MONTHS = {
    "it": ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio",
           "agosto", "settembre", "ottobre", "novembre", "dicembre"],
    "en": ["January", "February", "March", "April", "May", "June", "July",
           "August", "September", "October", "November", "December"],
}

TURN_PATTERN = re.compile(r"^\s*([^:\n]{1,60}?):\s+(.+)$")
DONE_STATUSES = {"done", "completed", "closed", "fatto", "completato"}


def meeting_date(artifacts: MeetingArtifacts) -> Any:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    frontmatter = artifacts.frontmatter
    return metadata.get("start") or summary.get("date") or metadata.get("recording_start") or frontmatter.get("date")


def parse_datetime(value: Any) -> datetime | None:
    """Local wall-clock time: aware values are converted, naive ones are taken as local."""
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.astimezone() if parsed.tzinfo else parsed


def has_time(value: Any) -> bool:
    return "T" in str(value or "") or " " in str(value or "").strip()


def when_text(artifacts: MeetingArtifacts, lang: str) -> str:
    """'martedì 29 settembre 2026  ·  10:00–10:35'."""
    raw = meeting_date(artifacts)
    start = parse_datetime(raw)
    if not start:
        return str(raw) if raw else ""
    table = lang if lang in WEEKDAYS else "en"
    text = f"{WEEKDAYS[table][start.weekday()]} {start.day} {MONTHS[table][start.month - 1]} {start.year}"
    if not has_time(raw):
        return text
    text += f"  ·  {start:%H:%M}"
    end = parse_datetime((artifacts.meeting_metadata or {}).get("end"))
    if end and end.date() == start.date():
        text += f"–{end:%H:%M}"
    return text


def duration_text(artifacts: MeetingArtifacts) -> str:
    metadata = artifacts.meeting_metadata or {}
    start, end = parse_datetime(metadata.get("start")), parse_datetime(metadata.get("end"))
    seconds: float | None = None
    if start and end and end > start:
        seconds = (end - start).total_seconds()
    else:
        raw = (artifacts.omlx_summary or {}).get("duration") or artifacts.frontmatter.get("duration")
        try:
            seconds = float(raw) if raw not in (None, "") else None
        except (TypeError, ValueError):
            return str(raw)
    if not seconds:
        return ""
    minutes = round(seconds / 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes:02d} min" if hours else f"{max(minutes, 1)} min"


def participants(artifacts: MeetingArtifacts) -> list[str]:
    metadata = artifacts.meeting_metadata or {}
    values = metadata.get("participants") or artifacts.frontmatter.get("participants") or []
    if isinstance(values, str):
        values = [part for part in values.split(",")]
    names = []
    for item in values:
        name = str((item.get("name") if isinstance(item, dict) else item) or "").strip()
        if name and name not in names:
            names.append(name)
    return names


def present(value: Any) -> str:
    """LLMs write 'null' or 'N/A' for missing owners and dates; treat those as empty."""
    text = str(value or "").strip()
    return "" if text.lower() in {"null", "none", "n/a", "-", "tbd"} else text


def decisions(values: Any) -> list[tuple[str, str]]:
    """(text, owner) pairs."""
    output = []
    for value in _as_list(values):
        if isinstance(value, dict):
            text, owner = present(value.get("text") or value.get("decision")), present(value.get("owner"))
        else:
            text, owner = present(value), ""
        if text:
            output.append((text, owner))
    return output


def action_items(values: Any) -> list[dict[str, Any]]:
    """{'task', 'owner', 'due', 'done'} dicts."""
    output = []
    for value in _as_list(values):
        if isinstance(value, dict):
            task = present(value.get("task") or value.get("text"))
            item = {
                "task": task,
                "owner": present(value.get("owner")),
                "due": present(value.get("due_date")),
                "done": str(value.get("status") or "").lower() in DONE_STATUSES,
            }
        else:
            item = {"task": present(value), "owner": "", "due": "", "done": False}
        if item["task"]:
            output.append(item)
    return output


def iso_day(value: str) -> str:
    """The YYYY-MM-DD prefix when the value is a real date, else ''."""
    match = re.match(r"^\d{4}-\d{2}-\d{2}", value.strip())
    if not match:
        return ""
    try:
        datetime.strptime(match.group(0), "%Y-%m-%d")
    except ValueError:
        return ""
    return match.group(0)


def transcript_turns(transcript: str) -> list[tuple[str, str]]:
    """'Name: text' lines grouped by speaker; empty when the transcript has no speaker labels."""
    turns: list[tuple[str, str]] = []
    for line in transcript.splitlines():
        if not line.strip():
            continue
        match = TURN_PATTERN.match(line)
        if match:
            speaker, text = match.group(1).strip(), match.group(2).strip()
            if turns and turns[-1][0] == speaker:
                turns[-1] = (speaker, f"{turns[-1][1]} {text}")
            else:
                turns.append((speaker, text))
        elif turns:
            turns[-1] = (turns[-1][0], f"{turns[-1][1]} {line.strip()}")
        else:
            return []
    return turns


def _as_list(values: Any) -> list[Any]:
    if not values:
        return []
    return values if isinstance(values, list) else [values]
