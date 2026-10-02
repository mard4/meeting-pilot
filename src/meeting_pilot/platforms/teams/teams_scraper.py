from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from ...config import Config

# Swift sources of the Teams window-id and OCR helpers, run with `swift` when working
# from a checkout. The app passes its compiled copies through MEETING_PILOT_*_COMMAND.
HELPER_SCRIPTS_DIR = Path(__file__).resolve().parents[4] / "macos/MeetingPilot/Scripts"

GENERIC_UI_WORDS = {
    "attiva",
    "back",
    "calendario",
    "calendar",
    "camera",
    "chat",
    "condividi",
    "copia",
    "disattiva",
    "fine",
    "hang up",
    "leave",
    "meeting",
    "meetings",
    "microfono",
    "more",
    "mute",
    "partecipanti",
    "participants",
    "people",
    "persone",
    "teams",
    "unmute",
}

UI_TEXT_FRAGMENTS = (
    "area di testo",
    "button",
    "casella",
    "checkbox",
    "collapse",
    "contenuto web",
    "dialog",
    "dispositivi",
    "finestra",
    "full screen",
    "full immersion",
    "generali",
    "gruppo",
    "menu",
    "notifiche",
    "pulsante",
    "search",
    "schermi",
    "scrivania e dock",
    "sfondo",
    "suono",
    "tab",
    "toolbar",
    "window",
)

PARTICIPANT_MARKERS = (
    "partecipanti",
    "participants",
    "persone",
    "people",
    "in questa riunione",
    "in this meeting",
    "currently in this meeting",
    "invited",
    "invitati",
)

STOP_MARKERS = (
    "chat",
    "reazioni",
    "reactions",
    "condividi",
    "share",
    "altre azioni",
    "more actions",
    "impostazioni",
    "settings",
)


@dataclass(frozen=True)
class TeamsRuntimeMetadata:
    captured_at: str
    source: str
    title: str | None
    participants: list[str]
    confidence: str
    raw_lines: list[str]
    window_titles: list[str]
    screenshot_path: str | None = None
    accessibility_error: str | None = None
    ocr_error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def capture_teams_runtime_metadata(
    config: Config,
    output_path: Path | None = None,
    *,
    use_ocr: bool = True,
    screenshot_path: Path | None = None,
    merge_existing: bool = False,
    title_hint: str | None = None,
    open_participants: bool = False,
) -> TeamsRuntimeMetadata:
    use_ocr = use_ocr and os.getenv("TEAMS_OCR_ENABLED", "false").strip().lower() in {"1", "true", "yes", "on"}
    captured_at = datetime.now().isoformat(timespec="seconds")
    accessibility_lines: list[str] = []
    window_titles: list[str] = []
    accessibility_error = None

    try:
        accessibility_lines, window_titles = _read_accessibility_lines()
    except RuntimeError as exc:
        accessibility_error = str(exc)

    parsed = _parse_lines(accessibility_lines, window_titles)
    if open_participants and not parsed["participants"]:
        try:
            if _open_participants_panel():
                refreshed_lines, refreshed_titles = _read_accessibility_lines()
                accessibility_lines = _dedupe_lines(accessibility_lines + refreshed_lines)
                window_titles = _dedupe_lines(window_titles + refreshed_titles)
                parsed = _parse_lines(accessibility_lines, window_titles)
        except RuntimeError as exc:
            accessibility_error = accessibility_error or str(exc)

    clean_title_hint = _normalize_line(title_hint or "")
    if clean_title_hint and not parsed["title"]:
        parsed["title"] = clean_title_hint
        parsed["confidence"] = "low"
    source = "accessibility"
    raw_lines = accessibility_lines
    ocr_error = None
    final_screenshot_path = None

    if use_ocr and _needs_ocr(parsed):
        if screenshot_path is None:
            screenshot_dir = config.meetings_root / "teams_scrapes"
            screenshot_dir.mkdir(parents=True, exist_ok=True)
            screenshot_path = screenshot_dir / f"teams-{datetime.now().strftime('%Y%m%d-%H%M%S')}.png"
        try:
            ocr_lines = _read_ocr_lines(screenshot_path)
            ocr_parsed = _parse_lines(ocr_lines, window_titles)
            final_screenshot_path = str(screenshot_path)
            raw_lines = _dedupe_lines(accessibility_lines + ocr_lines)
            parsed = _merge_parsed(parsed, ocr_parsed)
            source = "accessibility+ocr" if accessibility_lines else "ocr"
        except RuntimeError as exc:
            ocr_error = str(exc)

    metadata = TeamsRuntimeMetadata(
        captured_at=captured_at,
        source=source,
        title=parsed["title"],
        participants=parsed["participants"],
        confidence=parsed["confidence"],
        raw_lines=raw_lines[:400],
        window_titles=window_titles,
        screenshot_path=final_screenshot_path,
        accessibility_error=accessibility_error,
        ocr_error=ocr_error,
    )

    if output_path:
        output_path = output_path.expanduser()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        payload = metadata.to_dict()
        if merge_existing:
            payload = _merge_saved_metadata(output_path, payload)
            metadata = TeamsRuntimeMetadata(**{key: payload.get(key) for key in TeamsRuntimeMetadata.__dataclass_fields__})
        temporary_path = output_path.with_suffix(f"{output_path.suffix}.tmp")
        temporary_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary_path.replace(output_path)

    return metadata


def _merge_saved_metadata(path: Path, current: dict[str, Any]) -> dict[str, Any]:
    try:
        previous = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        previous = {}
    if not isinstance(previous, dict):
        previous = {}

    merged = dict(current)
    # The first capture is tied to the recording prompt; later UI scans may
    # mistake a participant name for a title, so keep that initial title.
    merged["title"] = previous.get("title") or current.get("title")
    merged["participants"] = _dedupe_lines(
        [str(value) for value in previous.get("participants", []) if value]
        + [str(value) for value in current.get("participants", []) if value]
    )
    merged["raw_lines"] = _dedupe_lines(
        [str(value) for value in previous.get("raw_lines", []) if value]
        + [str(value) for value in current.get("raw_lines", []) if value]
    )[-400:]
    merged["window_titles"] = _dedupe_lines(
        [str(value) for value in previous.get("window_titles", []) if value]
        + [str(value) for value in current.get("window_titles", []) if value]
    )
    merged["source"] = "+".join(
        _dedupe_lines([str(previous.get("source") or ""), str(current.get("source") or "")])
    ).strip("+")
    rank = {"none": 0, "low": 1, "medium": 2, "high": 3}
    previous_confidence = str(previous.get("confidence") or "none")
    current_confidence = str(current.get("confidence") or "none")
    merged["confidence"] = max(
        (previous_confidence, current_confidence),
        key=lambda value: rank.get(value, 0),
    )
    if merged["title"] and len(merged["participants"]) >= 2:
        merged["confidence"] = "medium"
    return merged


def _open_participants_panel() -> bool:
    script = r'''
tell application "System Events"
  if not (exists process "MSTeams") then error "MSTeams is not running"
  tell process "MSTeams"
    repeat with w in windows
      try
        repeat with e in entire contents of w
          set labelText to ""
          try
            set labelText to labelText & " " & (name of e as text)
          end try
          try
            set labelText to labelText & " " & (description of e as text)
          end try
          ignoring case
            if labelText contains "partecipanti" or labelText contains "participants" or labelText is "persone" or labelText is "people" then
              try
                perform action "AXPress" of e
                delay 0.8
                return "pressed"
              end try
            end if
          end ignoring
        end repeat
      end try
    end repeat
  end tell
end tell
return "not-found"
'''
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
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Could not open Teams participants: {exc}") from exc
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "Could not open Teams participants").strip())
    return result.stdout.strip() == "pressed"


def read_saved_teams_runtime_metadata(
    config: Config,
    reference_audio: Path | None = None,
    *,
    maximum_age_seconds: int = 4 * 60 * 60,
) -> dict[str, Any]:
    path = config.teams_runtime_metadata_file
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    captured_at = str(data.get("captured_at") or "").strip()
    if reference_audio is not None and captured_at:
        try:
            captured_time = datetime.fromisoformat(captured_at).timestamp()
            audio_time = reference_audio.stat().st_mtime
        except (OSError, ValueError):
            return {}
        if abs(audio_time - captured_time) > maximum_age_seconds:
            return {}
    useful = {
        "runtime_captured_at": data.get("captured_at"),
        "runtime_source": data.get("source"),
        "runtime_confidence": data.get("confidence"),
        "runtime_screenshot_path": data.get("screenshot_path"),
    }
    title = str(data.get("title") or "").strip()
    participants = data.get("participants")
    if title:
        useful["title"] = title
        useful["runtime_title"] = title
    if isinstance(participants, list):
        clean_participants = [str(item).strip() for item in participants if str(item).strip()]
        if clean_participants:
            useful["participants"] = clean_participants
            useful["runtime_participants"] = clean_participants
    return {key: value for key, value in useful.items() if value}


def _read_accessibility_lines() -> tuple[list[str], list[str]]:
    script = r'''
using terms from application "System Events"
on cleanText(t)
  try
    set t to t as text
    if t is "missing value" then return ""
    return t
  on error
    return ""
  end try
end cleanText

on appendText(outText, labelText, valueText)
  set valueText to my cleanText(valueText)
  if valueText is not "" then
    return outText & labelText & tab & valueText & linefeed
  end if
  return outText
end appendText

on collectElement(e, depth)
  set outText to ""
  try
    set outText to my appendText(outText, "TEXT", name of e)
  end try
  try
    set outText to my appendText(outText, "TEXT", value of e)
  end try
  try
    set outText to my appendText(outText, "TEXT", description of e)
  end try

  if depth < 6 then
    try
      repeat with childElement in UI elements of e
        set outText to outText & my collectElement(childElement, depth + 1)
      end repeat
    end try
  end if
  return outText
end collectElement
end using terms from

tell application "System Events"
  if not (exists process "MSTeams") then
    error "MSTeams is not running"
  end if
  tell process "MSTeams"
    set outText to ""
    repeat with w in windows
      try
        set outText to outText & "WINDOW" & tab & (name of w as text) & linefeed
      end try
      set outText to outText & my collectElement(w, 0)
    end repeat
    return outText
  end tell
end tell
'''
    try:
        result = subprocess.run(
            ["osascript"],
            input=script,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=25,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Accessibility read failed: {exc}") from exc

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "unknown osascript error").strip()
        raise RuntimeError(message)

    lines: list[str] = []
    window_titles: list[str] = []
    for raw in result.stdout.splitlines():
        parts = raw.split("\t", 1)
        if len(parts) == 2 and parts[1].strip():
            value = _normalize_line(parts[1])
            if not value:
                continue
            if parts[0] == "WINDOW":
                window_titles.append(value)
            lines.append(value)
        else:
            value = _normalize_line(raw)
            if value:
                lines.append(value)

    return _dedupe_lines(lines), _dedupe_lines(window_titles)


def _read_ocr_lines(screenshot_path: Path) -> list[str]:
    _bring_teams_to_front()
    script_dir = HELPER_SCRIPTS_DIR
    window_id = _teams_window_id(script_dir)
    try:
        screenshot_result = subprocess.run(
            ["screencapture", "-x", "-l", window_id, str(screenshot_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Screenshot failed: {exc}") from exc
    if screenshot_result.returncode != 0:
        message = (screenshot_result.stderr or screenshot_result.stdout or "screencapture failed").strip()
        raise RuntimeError(f"Screenshot failed: {message}")

    ocr_command = os.getenv("MEETING_PILOT_OCR_COMMAND")
    command = [ocr_command, str(screenshot_path)] if ocr_command else ["swift", str(script_dir / "ocr_vision.swift"), str(screenshot_path)]
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=45,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"OCR failed: {exc}") from exc

    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "unknown OCR error").strip())

    try:
        items = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"OCR returned invalid JSON: {exc}") from exc

    lines = [_normalize_line(str(item.get("text", ""))) for item in items if isinstance(item, dict)]
    return _dedupe_lines([line for line in lines if line])


def _teams_window_id(script_dir: Path) -> str:
    window_command = os.getenv("MEETING_PILOT_TEAMS_WINDOW_COMMAND")
    command = [window_command] if window_command else ["swift", str(script_dir / "teams_window_id.swift")]
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Could not find Teams window id: {exc}") from exc
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "Could not find Teams window id").strip())
    window_id = result.stdout.strip().splitlines()[-1].strip()
    if not window_id.isdigit():
        raise RuntimeError(f"Invalid Teams window id: {window_id}")
    return window_id


def _bring_teams_to_front() -> None:
    script = '''
try
  tell application "Microsoft Teams" to activate
end try
delay 0.3
tell application "System Events"
  if exists process "MSTeams" then
    tell process "MSTeams"
      set frontmost to true
    end tell
  end if
end tell
'''
    subprocess.run(["osascript"], input=script, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def _parse_lines(lines: list[str], window_titles: list[str]) -> dict[str, Any]:
    clean_lines = _dedupe_lines([_normalize_line(line) for line in lines if _normalize_line(line)])
    title = _guess_title(clean_lines, window_titles)
    participants = _guess_participants(clean_lines)

    if title and len(participants) >= 2:
        confidence = "medium"
    elif title or participants:
        confidence = "low"
    else:
        confidence = "none"

    return {"title": title, "participants": participants, "confidence": confidence}


def _merge_parsed(primary: dict[str, Any], fallback: dict[str, Any]) -> dict[str, Any]:
    title = primary["title"] or fallback["title"]
    participants = _dedupe_lines(primary["participants"] + fallback["participants"])
    confidence_rank = {"none": 0, "low": 1, "medium": 2, "high": 3}
    confidence = primary["confidence"]
    if confidence_rank[fallback["confidence"]] > confidence_rank[confidence]:
        confidence = fallback["confidence"]
    if title and len(participants) >= 2:
        confidence = "medium"
    return {"title": title, "participants": participants, "confidence": confidence}


def _needs_ocr(parsed: dict[str, Any]) -> bool:
    return not parsed["title"] or len(parsed["participants"]) < 2


def _guess_title(lines: list[str], window_titles: list[str]) -> str | None:
    candidates = window_titles + lines[:80]
    for line in candidates:
        value = _strip_teams_suffix(line)
        lowered = value.lower()
        if not value or len(value) < 4:
            continue
        if lowered in GENERIC_UI_WORDS:
            continue
        if lowered.startswith("chat |"):
            continue
        if "microsoft teams" in lowered and len(value) <= 24:
            continue
        if any(word in lowered for word in ("meeting", "riunione", "call", "chiamata")):
            return value
    for line in candidates:
        value = _strip_teams_suffix(line)
        if _looks_like_title(value):
            return value
    return None


def _guess_participants(lines: list[str]) -> list[str]:
    participants: list[str] = []
    marker_indexes = [
        index
        for index, line in enumerate(lines)
        if any(marker in line.lower() for marker in PARTICIPANT_MARKERS)
    ]
    for marker_index in marker_indexes:
        for line in lines[marker_index + 1 : marker_index + 90]:
            lowered = line.lower()
            if any(stop == lowered or lowered.startswith(f"{stop} ") for stop in STOP_MARKERS):
                break
            candidate = _clean_participant(line)
            if candidate:
                participants.append(candidate)

    if not participants:
        for line in lines:
            candidate = _clean_participant(line)
            if candidate and _looks_like_person(candidate):
                participants.append(candidate)

    return _dedupe_lines(participants)[:30]


def _clean_participant(line: str) -> str | None:
    value = _normalize_line(line)
    value = re.sub(r"\s*\([^)]*(organizzatore|organizer|presenter|relatore|guest|ospite|external)[^)]*\)\s*", "", value, flags=re.I)
    value = re.sub(r"\s*[-,]\s*(organizzatore|organizer|presenter|relatore|guest|ospite|external)\s*$", "", value, flags=re.I)
    value = re.sub(r"\s+(muted|disattivato|microfono disattivato|speaking|sta parlando)\s*$", "", value, flags=re.I)
    value = value.strip(" -:•\t")
    if not _looks_like_person(value):
        return None
    return value


def _looks_like_person(value: str) -> bool:
    lowered = value.lower().strip()
    if lowered in GENERIC_UI_WORDS or any(marker in lowered for marker in PARTICIPANT_MARKERS):
        return False
    if any(fragment in lowered for fragment in UI_TEXT_FRAGMENTS):
        return False
    if len(value) < 3 or len(value) > 80:
        return False
    if re.search(r"https?://|www\.|@.*\.", value):
        return False
    if re.search(r"\d{2,}", value):
        return False
    words = [word for word in re.split(r"\s+", value) if word]
    if not 1 <= len(words) <= 5:
        return False
    alpha_words = [word for word in words if re.search(r"[A-Za-zÀ-ÖØ-öø-ÿ]", word)]
    if len(alpha_words) != len(words):
        return False
    return True


def _looks_like_title(value: str) -> bool:
    lowered = value.lower()
    if lowered in GENERIC_UI_WORDS:
        return False
    if lowered.startswith("chat |") or any(fragment in lowered for fragment in UI_TEXT_FRAGMENTS):
        return False
    if len(value) < 8 or len(value) > 120:
        return False
    if re.search(r"https?://|www\.", value):
        return False
    if len(value.split()) < 2:
        return False
    return True


def _strip_teams_suffix(value: str) -> str:
    value = re.sub(r"\s*\|\s*Microsoft Teams\s*$", "", value, flags=re.I)
    value = re.sub(r"\s*-\s*Microsoft Teams\s*$", "", value, flags=re.I)
    return value.strip()


def _normalize_line(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _dedupe_lines(lines: list[str]) -> list[str]:
    seen = set()
    deduped = []
    for line in lines:
        key = line.casefold()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(line)
    return deduped
