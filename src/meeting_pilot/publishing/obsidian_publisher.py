from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..artifacts import MeetingArtifacts, write_obsidian_receipt
from ..config import Config
from ..language import config_language, label
from .meeting_format import (
    action_items,
    decisions,
    duration_text,
    has_time,
    iso_day,
    meeting_date,
    parse_datetime,
    participants,
    present,
    transcript_turns,
    when_text,
)


def publish_to_obsidian(config: Config, artifacts: MeetingArtifacts) -> dict[str, Any]:
    if not config.obsidian_vault_path:
        raise ValueError("OBSIDIAN_VAULT_PATH is required.")

    vault_root = config.obsidian_vault_path.expanduser()
    vault_root.mkdir(parents=True, exist_ok=True)
    folder = vault_root / config.obsidian_folder
    folder.mkdir(parents=True, exist_ok=True)

    title = _note_title(artifacts)
    note_date = _note_date(artifacts)
    filename = _render_filename(config.obsidian_filename_template, title, note_date)
    note_path = _unique_path(folder / filename)
    content = _note_content(config, artifacts, title, note_date)
    note_path.write_text(content, encoding="utf-8")

    receipt = {
        "provider": "obsidian",
        "vault_path": str(vault_root),
        "folder": config.obsidian_folder,
        "title": title,
        "path": str(note_path),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    write_obsidian_receipt(artifacts.session_dir, receipt)
    return receipt


def _note_title(artifacts: MeetingArtifacts) -> str:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    title = summary.get("title") or metadata.get("title") or artifacts.title
    return str(title).strip() or "Meeting"


def _note_date(artifacts: MeetingArtifacts) -> str:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    frontmatter = artifacts.frontmatter
    value = metadata.get("start") or summary.get("date") or metadata.get("recording_start") or frontmatter.get("date")
    if not value:
        return "undated"
    return str(value).split("T", 1)[0]


def _render_filename(template: str, title: str, date: str) -> str:
    safe_title = _sanitize_filename(title)
    safe_date = _sanitize_filename(date)
    filename = template.format(title=safe_title, date=safe_date)
    filename = filename.strip() or f"{safe_date} - {safe_title}.md"
    if not filename.lower().endswith(".md"):
        filename += ".md"
    return _sanitize_filename(filename, keep_extensions=True)


def _unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    suffix = path.suffix
    stem = path.stem
    parent = path.parent
    index = 2
    while True:
        candidate = parent / f"{stem}-{index}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def _note_content(
    config: Config,
    artifacts: MeetingArtifacts,
    title: str,
    date: str,
    header_callout: bool = True,
) -> str:
    """Obsidian-flavoured Markdown, also read by the in-app Diary.

    The Diary draws date, duration and participants in its own header from the
    frontmatter, so it asks for the note without the header callout.
    """
    lang = config_language(config)

    def t(key: str) -> str:
        return label(lang, key)

    summary = artifacts.omlx_summary or {}
    parts = ["---", *_frontmatter_lines(config, artifacts, title, date), "---", "", f"# {title}"]

    if header_callout and _include(config, "overview"):
        parts.extend(["", *_header_callout(artifacts, lang)])

    if _include(config, "summary"):
        parts.extend(["", f"## {t('summary')}", "", str(summary.get("summary") or artifacts.summary_markdown or t("no_summary")).strip()])
    topics = _plain_values(summary.get("topics")) if _include(config, "topics") else []
    if topics:
        parts.extend(["", f"**{t('topics')}:** " + " · ".join(topics)])

    if artifacts.user_notes:
        parts.extend(["", f"## {t('my_notes')}", artifacts.user_notes])

    if _include(config, "decisions"):
        rows = [f"- {text}" + (f" — *{owner}*" if owner else "") for text, owner in decisions(summary.get("decisions"))]
        parts.extend(["", f"## {t('decisions')}", "", *(rows or [f"*{t('no_decisions')}*"])])

    if _include(config, "action_items"):
        rows = [_task_line(item) for item in action_items(summary.get("action_items"))]
        parts.extend(["", f"## {t('action_items')}", "", *(rows or [f"*{t('no_action_items')}*"])])

    for key, kind in (("open_questions", "question"), ("risks", "warning")):
        values = _plain_values(summary.get(key)) if _include(config, key) else []
        if values:
            parts.extend(["", f"> [!{kind}] {t(key)}", *(f"> - {value}" for value in values)])

    if artifacts.archived_audio_file:
        parts.extend(["", f"🎧 [{t('open_audio')}]({artifacts.archived_audio_file.as_uri()})"])

    if artifacts.transcript_text and _include(config, "transcript"):
        parts.extend(["", *_transcript_callout(t("full_transcript"), artifacts.transcript_text)])

    return "\n".join(parts).rstrip() + "\n"


def _frontmatter_lines(config: Config, artifacts: MeetingArtifacts, title: str, date: str) -> list[str]:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    frontmatter = artifacts.frontmatter
    lines = [f'title: "{_yaml_escape(title)}"', f"date: {date}" if iso_day(date) else f'date: "{_yaml_escape(date)}"']

    # Unquoted local times are typed as Date & time properties by Obsidian.
    raw_start = meeting_date(artifacts)
    start = parse_datetime(raw_start)
    if start and has_time(raw_start):
        lines.append(f"start: {start:%Y-%m-%dT%H:%M}")
        end = parse_datetime(metadata.get("end"))
        if end:
            lines.append(f"end: {end:%Y-%m-%dT%H:%M}")
    duration = duration_text(artifacts)
    if duration:
        lines.append(f'duration: "{_yaml_escape(duration)}"')

    project = metadata.get("project") or frontmatter.get("project")
    if project:
        lines.append(f'project: "{_yaml_escape(str(project))}"')
    theme = metadata.get("theme") or frontmatter.get("theme")
    if theme:
        lines.append(f'theme: "{_yaml_escape(str(theme))}"')

    people = participants(artifacts)
    if people:
        lines.append("participants:")
        lines.extend(f'  - "{_yaml_escape(name)}"' for name in people)

    tags = ["meeting", *(_tag(value) for value in (project, theme) if value)]
    lines.append("tags:")
    lines.extend(f"  - {tag}" for tag in dict.fromkeys(tag for tag in tags if tag))

    lines.extend([
        'source: "Teams"',
        'status: "Published"',
        f'model: "{_yaml_escape(str(config.summary_model))}"',
        f'transcription_provider: "{_yaml_escape(str(config.transcription_provider))}"',
        f'session_id: "{_yaml_escape(artifacts.session_dir.name)}"',
    ])
    series_key = _series_key(summary.get("title") or metadata.get("title") or artifacts.title)
    if series_key:
        lines.append(f'series_key: "{_yaml_escape(series_key)}"')
    language = summary.get("language") or frontmatter.get("language")
    if language:
        lines.append(f'language: "{_yaml_escape(str(language))}"')
    if artifacts.archived_audio_file:
        lines.append(f'audio_path: "{_yaml_escape(str(artifacts.archived_audio_file))}"')
    return lines


def _header_callout(artifacts: MeetingArtifacts, lang: str) -> list[str]:
    metadata = artifacts.meeting_metadata or {}
    when = when_text(artifacts, lang)
    duration = duration_text(artifacts)
    people = participants(artifacts)
    if not when and not people:
        return [f"> [!info] {label(lang, 'calendar_metadata_missing')}"]
    heading = "  ·  ".join(part for part in (when, duration) if part) or label(lang, "participants")
    lines = [f"> [!info] {heading}"]
    if people:
        lines.append(f"> **{label(lang, 'participants')}:** " + ", ".join(people))
    tags = [
        f"**{label(lang, key)}:** {value}"
        for key, value in (
            ("project", metadata.get("project") or artifacts.frontmatter.get("project")),
            ("theme", metadata.get("theme") or artifacts.frontmatter.get("theme")),
        )
        if value
    ]
    if tags:
        lines.append("> " + "  ·  ".join(tags))
    return lines


def _task_line(item: dict[str, Any]) -> str:
    """Obsidian Tasks syntax: the due date emoji goes last so the plugin can parse it."""
    line = f"- [{'x' if item['done'] else ' '}] {item['task']}"
    if item["owner"]:
        line += f" — **{item['owner']}**"
    if item["due"]:
        day = iso_day(item["due"])
        line += f" 📅 {day}" if day else f" · *{item['due']}*"
    return line


def _transcript_callout(title: str, transcript: str) -> list[str]:
    """Collapsed by default: the transcript is long and rarely re-read."""
    lines = [f"> [!quote]- {title}"]
    turns = transcript_turns(transcript)
    if not turns:
        return lines + [f"> {line}" if line.strip() else ">" for line in transcript.strip().splitlines()]
    for index, (speaker, text) in enumerate(turns):
        if index:
            lines.append(">")
        lines.append(f"> **{speaker}:** {text}")
    return lines


def _include(config: Config, section: str) -> bool:
    return bool(getattr(config, f"notion_include_{section}", True))


def _plain_values(values: Any) -> list[str]:
    if not values:
        return []
    items = values if isinstance(values, list) else [values]
    output = []
    for value in items:
        text = present(_render_dict(value) if isinstance(value, dict) else value)
        if text:
            output.append(text)
    return output


def _render_dict(value: dict[str, Any]) -> str:
    keys = ["text", "task", "topic", "title", "question", "risk", "owner", "due_date", "status"]
    parts = [str(value[key]) for key in keys if value.get(key)]
    if parts:
        return " - ".join(parts)
    return " - ".join(str(item) for item in value.values() if item)


def _tag(value: Any) -> str:
    """Obsidian tags cannot hold spaces or most punctuation."""
    text = re.sub(r"[^\w/-]+", "-", str(value).strip().lower()).strip("-")
    return text if text and not text.isdigit() else ""


def _series_key(value: Any) -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"\b(20\d{2})[-/]\d{1,2}[-/]\d{1,2}\b", "", text)
    text = re.sub(r"\s+", " ", text).strip(" -–—")
    return text


def _sanitize_filename(value: str, keep_extensions: bool = False) -> str:
    text = value.strip()
    if not keep_extensions:
        text = re.sub(r"\.[A-Za-z0-9]+$", "", text)
    text = text.replace("/", "-").replace("\\", "-")
    text = re.sub(r"[<>:\"|?*\n\r\t]", "-", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text or "note"


def _yaml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')
