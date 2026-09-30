from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from .config import Config


MONTHS = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
]


@dataclass(frozen=True)
class CalendarCandidate:
    title: str
    start: datetime | None
    end: datetime | None
    calendar: str | None = None
    location: str | None = None
    url: str | None = None
    notes: str | None = None
    participants: tuple[str, ...] = ()
    source: str = "unknown"

    def score(self, target: datetime) -> float:
        if self.start and self.end and self.start <= target <= self.end:
            return 0
        if self.start:
            return abs((self.start - target).total_seconds())
        return 999_999

    def to_dict(self) -> dict[str, Any]:
        return {
            "title": self.title,
            "start": self.start.isoformat() if self.start else None,
            "end": self.end.isoformat() if self.end else None,
            "calendar": self.calendar,
            "location": self.location,
            "url": self.url,
            "notes": self.notes,
            "participants": list(self.participants),
            "source": self.source,
        }


def find_meeting_metadata(config: Config, source_audio: Path) -> dict[str, Any]:
    if not config.calendar_metadata_enabled:
        return {}

    target = _datetime_from_filename(source_audio) or datetime.fromtimestamp(source_audio.stat().st_mtime)
    window = timedelta(minutes=config.calendar_lookup_window_minutes)
    candidates = []
    candidates.extend(_query_outlook_sqlite(config, target, window))
    if os.getenv("MACOS_CALENDAR_METADATA_ENABLED", "false").strip().lower() in {"1", "true", "yes", "on"}:
        candidates.extend(_query_calendar_app(target, window))
    if not candidates:
        return {"recording_start": target.isoformat(), "match_found": False}

    best = sorted(candidates, key=lambda candidate: candidate.score(target))[0]
    metadata = best.to_dict()
    metadata["recording_start"] = target.isoformat()
    metadata["match_found"] = True
    return metadata


def _datetime_from_filename(path: Path) -> datetime | None:
    match = re.search(r"(20\d{2})-(\d{2})-(\d{2})[ _-](\d{2})-(\d{2})-(\d{2})", path.name)
    if not match:
        return None
    year, month, day, hour, minute, second = map(int, match.groups())
    return datetime(year, month, day, hour, minute, second)


def _query_outlook_sqlite(config: Config, target: datetime, window: timedelta) -> list[CalendarCandidate]:
    path = config.outlook_sqlite_path
    if not path.exists():
        return []
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as connection:
            rows = connection.execute(
                """
                select Calendar_StartDateUTC, Calendar_EndDateUTC, Calendar_AttendeeCount, PathToDataFile
                from CalendarEvents
                where Calendar_StartDateUTC is not null
                """
            ).fetchall()
    except sqlite3.Error:
        return []

    candidates = []
    for start_raw, end_raw, attendee_count, data_path in rows:
        start = _parse_sqlite_date(start_raw)
        end = _parse_sqlite_date(end_raw)
        if not start or abs((start - target).total_seconds()) > window.total_seconds():
            continue
        title = Path(str(data_path)).stem if data_path else "Outlook meeting"
        candidates.append(
            CalendarCandidate(
                title=title,
                start=start,
                end=end,
                participants=tuple(f"{attendee_count} attendee(s)" for _ in [0] if attendee_count),
                source="outlook_sqlite",
            )
        )
    return candidates


def _query_calendar_app(target: datetime, window: timedelta) -> list[CalendarCandidate]:
    script = _calendar_applescript(target - window, target + window)
    try:
        result = subprocess.run(
            ["osascript"],
            input=script,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0 or not result.stdout.strip():
        return []

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    candidates = []
    for item in data:
        start = _parse_calendar_date(item.get("start"))
        end = _parse_calendar_date(item.get("end"))
        title = str(item.get("title") or "").strip()
        if not title:
            continue
        participants = tuple(value for value in item.get("participants", []) if value)
        candidates.append(
            CalendarCandidate(
                title=title,
                start=start,
                end=end,
                calendar=item.get("calendar"),
                location=item.get("location"),
                url=item.get("url"),
                notes=item.get("notes"),
                participants=participants,
                source="calendar_app",
            )
        )
    return candidates


def _calendar_applescript(start: datetime, end: datetime) -> str:
    return f"""
on pad2(n)
  if n < 10 then return "0" & (n as text)
  return n as text
end pad2

on jsonEscape(t)
  set t to t as text
  set AppleScript's text item delimiters to "\\\\"
  set parts to text items of t
  set AppleScript's text item delimiters to "\\\\\\\\"
  set t to parts as text
  set AppleScript's text item delimiters to "\\""
  set parts to text items of t
  set AppleScript's text item delimiters to "\\\\\\""
  set t to parts as text
  set AppleScript's text item delimiters to ""
  return t
end jsonEscape

on isoDate(d)
  return ((year of d) as text) & "-" & my pad2((month of d) as integer) & "-" & my pad2(day of d) & "T" & my pad2(hours of d) & ":" & my pad2(minutes of d) & ":" & my pad2(seconds of d)
end isoDate

on makeStartDate()
  set resultDate to current date
  set year of resultDate to {start.year}
  set month of resultDate to {MONTHS[start.month - 1]}
  set day of resultDate to {start.day}
  set hours of resultDate to {start.hour}
  set minutes of resultDate to {start.minute}
  set seconds of resultDate to {start.second}
  return resultDate
end makeStartDate

on makeEndDate()
  set resultDate to current date
  set year of resultDate to {end.year}
  set month of resultDate to {MONTHS[end.month - 1]}
  set day of resultDate to {end.day}
  set hours of resultDate to {end.hour}
  set minutes of resultDate to {end.minute}
  set seconds of resultDate to {end.second}
  return resultDate
end makeEndDate

set startWindow to my makeStartDate()
set endWindow to my makeEndDate()

tell application "Calendar"
  set eventJsons to {{}}
  repeat with c in calendars
    set calendarName to name of c
    set evs to every event of c whose start date ≤ endWindow and end date ≥ startWindow
    repeat with e in evs
      set participantJsons to {{}}
      try
        repeat with a in attendees of e
          set attendeeText to ""
          try
            set attendeeText to display name of a
          end try
          if attendeeText is "" then
            try
              set attendeeText to email of a
            end try
          end if
          if attendeeText is not "" then set end of participantJsons to "\\"" & my jsonEscape(attendeeText) & "\\""
        end repeat
      end try
      set AppleScript's text item delimiters to ","
      set participantsJson to participantJsons as text
      set AppleScript's text item delimiters to ""

      set titleText to ""
      set locationText to ""
      set urlText to ""
      set notesText to ""
      try
        set titleText to summary of e
      end try
      try
        set locationText to location of e
      end try
      try
        set urlText to url of e
      end try
      try
        set notesText to description of e
      end try

      set eventJson to "{{\\"title\\":\\"" & my jsonEscape(titleText) & "\\",\\"calendar\\":\\"" & my jsonEscape(calendarName) & "\\",\\"start\\":\\"" & my isoDate(start date of e) & "\\",\\"end\\":\\"" & my isoDate(end date of e) & "\\",\\"location\\":\\"" & my jsonEscape(locationText) & "\\",\\"url\\":\\"" & my jsonEscape(urlText) & "\\",\\"notes\\":\\"" & my jsonEscape(notesText) & "\\",\\"participants\\":[" & participantsJson & "]}}"
      set end of eventJsons to eventJson
    end repeat
  end repeat
  set AppleScript's text item delimiters to ","
  set outputJson to "[" & (eventJsons as text) & "]"
  set AppleScript's text item delimiters to ""
  return outputJson
end tell
"""


def _parse_sqlite_date(value: Any) -> datetime | None:
    if not value:
        return None
    text = str(value).replace("Z", "")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def _parse_calendar_date(value: Any) -> datetime | None:
    if not value:
        return None
    text = str(value)
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%A, %d %B %Y at %H:%M:%S", "%A %d %B %Y at %H:%M:%S", "%d %B %Y at %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None
