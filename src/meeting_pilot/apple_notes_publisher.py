from __future__ import annotations

import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .artifacts import MeetingArtifacts
from .config import Config
from .obsidian_publisher import _include
from .language import config_language, label


def publish_to_apple_notes(config: Config, artifacts: MeetingArtifacts) -> dict[str, Any]:
    title = _note_title(artifacts)
    body = _note_body(config, artifacts)

    with tempfile.TemporaryDirectory(prefix="meeting-pilot-notes-") as tmp:
        tmp_dir = Path(tmp)
        title_path = tmp_dir / "title.txt"
        body_path = tmp_dir / "body.txt"
        title_path.write_text(title, encoding="utf-8")
        body_path.write_text(body, encoding="utf-8")

        script = _apple_script()
        result = subprocess.run(
            ["osascript", "-", str(title_path), str(body_path)],
            input=script,
            text=True,
            capture_output=True,
            check=False,
        )
    if result.returncode != 0:
        raise RuntimeError(f"Apple Notes fallback failed: {result.stderr.strip() or result.stdout.strip()}")

    receipt = {
        "provider": "apple_notes",
        "folder": "Meeting Pilot",
        "title": title,
        "note_id": result.stdout.strip(),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    (artifacts.session_dir / "apple_notes_receipt.json").write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return receipt


def _note_title(artifacts: MeetingArtifacts) -> str:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    title = summary.get("title") or metadata.get("title") or artifacts.title
    date = metadata.get("start") or summary.get("date") or metadata.get("recording_start")
    if date:
        return f"{title} - {str(date).split('T', 1)[0]}"
    return str(title)


def _note_body(config: Config, artifacts: MeetingArtifacts) -> str:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    frontmatter = artifacts.frontmatter
    parts = ["Meeting Pilot"]
    lang = config_language(config)

    def t(key: str) -> str:
        return label(lang, key)

    project = metadata.get("project") or frontmatter.get("project")
    theme = metadata.get("theme") or frontmatter.get("theme")
    if project or theme:
        parts.extend(["", t("classification")])
        if project:
            parts.append(f"{t('project')}: {project}")
        if theme:
            parts.append(f"{t('theme')}: {theme}")
    if _include(config, "summary"):
        parts.extend(["", t("summary"), str(summary.get("summary") or artifacts.summary_markdown or t("no_summary"))])
    if artifacts.user_notes:
        parts.extend(["", t("my_notes"), artifacts.user_notes])
    if _include(config, "overview"):
        parts.extend(["", t("overview"), _overview(artifacts, lang)])
    sections = [
        (t("topics"), summary.get("topics"), _include(config, "topics")),
        (t("decisions"), summary.get("decisions"), _include(config, "decisions")),
        (t("action_items"), summary.get("action_items"), _include(config, "action_items")),
        (t("open_questions"), summary.get("open_questions"), _include(config, "open_questions")),
        (t("risks"), summary.get("risks"), _include(config, "risks")),
    ]
    for heading, values, included in sections:
        if not included:
            continue
        rendered = _render_values(values)
        if rendered:
            parts.extend(["", heading, rendered])

    participants = metadata.get("participants") or frontmatter.get("participants")
    if participants and _include(config, "speakers"):
        parts.extend(["", t("participants"), _render_values(participants)])

    parts.extend(
        [
            "",
            t("details"),
            f"{t('summary_provider')}: {config.summary_model}",
            f"{t('transcription')}: {config.transcription_provider}",
            f"{t('audio')}: {artifacts.archived_audio_file.as_uri()}" if artifacts.archived_audio_file else None,
            f"{t('session')}: {artifacts.session_dir.name}",
        ]
    )

    if artifacts.transcript_text and _include(config, "transcript"):
        parts.extend(["", t("full_transcript"), artifacts.transcript_text])
    return "\n".join(part for part in parts if part is not None)


def _overview(artifacts: MeetingArtifacts, lang: str = "it") -> str:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    lines = []
    title = summary.get("title") or metadata.get("title") or artifacts.title
    if title:
        lines.append(f"{label(lang, 'subject')}: {title}")
    if metadata.get("start"):
        lines.append(f"{label(lang, 'start')}: {metadata.get('start')}")
    if metadata.get("participants"):
        lines.append(label(lang, "participants") + ": " + _render_values(metadata.get("participants")).replace("\n", ", "))
    if not lines:
        lines.append(label(lang, "no_metadata"))
    return "\n".join(lines)


def _render_values(values: Any) -> str:
    if not values:
        return ""
    if isinstance(values, str):
        return values
    if isinstance(values, dict):
        return _render_dict(values)
    if isinstance(values, list):
        output = []
        for value in values:
            if isinstance(value, dict):
                text = _render_dict(value)
            else:
                text = str(value)
            if text.strip():
                output.append(f"- {text}")
        return "\n".join(output)
    return str(values)


def _render_dict(value: dict[str, Any]) -> str:
    keys = ["text", "task", "topic", "title", "question", "risk", "owner", "due_date", "status"]
    parts = [str(value[key]) for key in keys if value.get(key)]
    if parts:
        return " - ".join(parts)
    return " - ".join(str(item) for item in value.values() if item)


def _apple_script() -> str:
    return r'''
on run argv
  set titlePath to item 1 of argv
  set bodyPath to item 2 of argv
  set noteTitle to read POSIX file titlePath as «class utf8»
  set noteBody to read POSIX file bodyPath as «class utf8»

  tell application "Notes"
    if (count of accounts) is 0 then error "No Notes account available"
    set targetAccount to first account
    if not (exists folder "Meeting Pilot" of targetAccount) then
      make new folder at targetAccount with properties {name:"Meeting Pilot"}
    end if
    set targetFolder to folder "Meeting Pilot" of targetAccount
    set createdNote to make new note at targetFolder with properties {name:noteTitle, body:noteBody}
    return id of createdNote
  end tell
end run
'''
