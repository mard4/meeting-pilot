from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from ..artifacts import MeetingArtifacts, write_notion_receipt
from ..config import Config
from ..language import config_language, label
from ..profiles import STUDENT, WORKER, artifacts_profile, user_profile
from .meeting_format import (
    action_items,
    decisions,
    duration_text,
    iso_day,
    key_concepts,
    meeting_date,
    participants,
    transcript_turns,
    when_text,
)

# Notion rejects a create request whose children nest deeper than two levels or
# hold more than 100 items per array, and caps each rich text item at 2000 chars.
MAX_CHILDREN = 100
MAX_RICH_TEXT = 100
MAX_TEXT = 2000

SPEAKER_COLORS = ["blue", "green", "orange", "purple", "pink", "brown", "red", "yellow"]
CHIP_COLORS = ["blue_background", "purple_background", "green_background", "orange_background", "pink_background"]



def publish_to_notion(config: Config, artifacts: MeetingArtifacts) -> dict[str, Any]:
    if not config.notion_token or not config.notion_database_id:
        raise ValueError("NOTION_TOKEN and NOTION_DATABASE_ID are required.")

    from notion_client import Client

    notion = Client(auth=config.notion_token)
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    series_title = str(summary.get("title") or metadata.get("title") or artifacts.title)
    title = _occurrence_title(artifacts, series_title)
    occurrences_source = _data_source(notion, config.notion_database_id)
    occurrences_source_id = str(occurrences_source["id"])
    occurrences_schema = occurrences_source.get("properties") or {}
    wanted = _build_properties(config, artifacts, title, schema=occurrences_schema, keep_unsupported=True)
    occurrences_schema = _ensure_properties(notion, occurrences_source_id, occurrences_schema, wanted)
    page = notion.pages.create(
        parent={"type": "data_source_id", "data_source_id": occurrences_source_id},
        properties=_properties_supported_by_schema(wanted, occurrences_schema),
        icon={"type": "emoji", "emoji": "🗒️"},
        children=_build_blocks(config, artifacts),
    )
    write_notion_receipt(artifacts.session_dir, page)
    return page


def _build_properties(
    config: Config,
    artifacts: MeetingArtifacts,
    title: str,
    schema: dict[str, Any] | None = None,
    keep_unsupported: bool = False,
) -> dict[str, Any]:
    summary = artifacts.omlx_summary or {}
    metadata = artifacts.meeting_metadata or {}
    frontmatter = artifacts.frontmatter
    participants_text = ", ".join(participants(artifacts))

    title_property = _title_property_name(schema or {}, config.notion_title_property)
    properties: dict[str, Any] = {title_property: {"title": [{"text": {"content": title[:2000]}}]}}
    date = meeting_date(artifacts)
    if date:
        properties[_date_property_name(schema or {})] = {"date": {"start": _notion_date(str(date))}}
    project = metadata.get("project") or frontmatter.get("project")
    project_select_name = _notion_select_name(project)
    if project_select_name:
        properties[config.notion_project_property] = {"select": {"name": project_select_name}}
    theme_name = _notion_select_name(metadata.get("theme") or frontmatter.get("theme"))
    if theme_name:
        properties["Tema"] = {"multi_select": [{"name": theme_name}]}
    if participants_text:
        properties["Participants"] = {"rich_text": [_rich_text(participants_text)]}
    if metadata.get("url") or frontmatter.get("url"):
        properties["URL"] = {"url": str(metadata.get("url") or frontmatter.get("url"))}
    # Work and study notes share one table; the column only appears once the user studies.
    if user_profile(config) != WORKER:
        lecture = artifacts_profile(config, artifacts) == STUDENT
        properties["Type"] = {"select": {"name": "Study" if lecture else "Work"}}
    properties.update({
        "Source": {"select": {"name": "Teams"}},
        "Status": {"select": {"name": "Pubblicato"}},
        "Model": {"rich_text": [_rich_text(config.summary_model)]},
        "Session ID": {"rich_text": [_rich_text(artifacts.session_dir.name)]},
    })
    if artifacts.archived_audio_file:
        properties["Audio Path"] = {"rich_text": [_rich_text(str(artifacts.archived_audio_file))]}

    language = summary.get("language") or frontmatter.get("language")
    if language:
        properties["Language"] = {"rich_text": [_rich_text(str(language))]}

    duration = duration_text(artifacts) or summary.get("duration") or frontmatter.get("duration")
    if duration:
        properties["Duration"] = {"rich_text": [_rich_text(str(duration))]}

    return properties if keep_unsupported else _properties_supported_by_schema(properties, schema)


def _notion_date(value: str) -> str:
    """Recording times are local wall-clock times; Notion reads a bare datetime as UTC,
    which shifts the meeting by the Mac's offset. Attach the local offset explicitly."""
    if "T" not in value:
        return value
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    return parsed.isoformat() if parsed.tzinfo else parsed.astimezone().isoformat()


def _notion_select_name(value: object) -> str:
    """Notion select options cannot contain commas; keep generated tags publishable."""
    text = re.sub(r"\s+", " ", str(value or "").replace(",", " - ")).strip()
    return text[:100]


def _data_source(notion: Any, database_id: str) -> dict[str, Any]:
    database = notion.databases.retrieve(database_id=database_id)
    sources = database.get("data_sources") or []
    if sources and sources[0].get("id"):
        source_id = str(sources[0]["id"])
        source = notion.data_sources.retrieve(data_source_id=source_id)
        if isinstance(source, dict):
            return source
    # Workspaces created using the pre-2025 API may use the same identifier for
    # the database container and its only data source.
    source = notion.data_sources.retrieve(data_source_id=database_id)
    if not isinstance(source, dict):
        raise ValueError(f"Notion did not return the data source {database_id}.")
    return source


def _schema_property_type(schema: dict[str, Any], name: str) -> str:
    value = schema.get(name) or {}
    return str(value.get("type") or "") if isinstance(value, dict) else ""


def _title_property_name(schema: dict[str, Any], preferred: str) -> str:
    if _schema_property_type(schema, preferred) == "title":
        return preferred
    for name, value in schema.items():
        if isinstance(value, dict) and value.get("type") == "title":
            return str(name)
    return preferred


def _date_property_name(schema: dict[str, Any]) -> str:
    """Reuse an existing date column even when it is named 'Data' (or any case variant)."""
    for candidate in ("Date", "Data"):
        if _schema_property_type(schema, candidate) == "date":
            return candidate
    for name, value in schema.items():
        if isinstance(value, dict) and value.get("type") == "date" and str(name).lower() in {"date", "data"}:
            return str(name)
    return "Date"


def _ensure_properties(
    notion: Any, data_source_id: str, schema: dict[str, Any], properties: dict[str, Any]
) -> dict[str, Any]:
    """Databases created by notion-setup start with only a title; add the metadata
    columns the first time they are needed so date, project and topic are visible
    in table views. Existing columns are never changed, even with a different type."""
    missing = {
        name: {requested_type: {}}
        for name, value in properties.items()
        if name not in schema
        for requested_type in [next(iter(value), "") if isinstance(value, dict) else ""]
        if requested_type and requested_type != "title"
    }
    if not missing:
        return schema
    try:
        updated = notion.data_sources.update(data_source_id=data_source_id, properties=missing)
    except Exception as error:  # A read-only integration still publishes the page body.
        print(f"Notion columns not added ({', '.join(missing)}): {error}", flush=True)
        return schema
    return (updated or {}).get("properties") or {**schema, **missing}


def _properties_supported_by_schema(
    properties: dict[str, Any], schema: dict[str, Any] | None
) -> dict[str, Any]:
    if not schema:
        return properties
    supported: dict[str, Any] = {}
    for name, value in properties.items():
        actual_type = _schema_property_type(schema, name)
        requested_type = next(iter(value), "") if isinstance(value, dict) else ""
        if actual_type and actual_type == requested_type:
            supported[name] = value
    return supported


def _occurrence_title(artifacts: MeetingArtifacts, series_title: str) -> str:
    date = meeting_date(artifacts)
    if date:
        date_text = str(date).split("T", 1)[0]
        return f"{series_title} - {date_text}"
    return series_title


def _build_blocks(config: Config, artifacts: MeetingArtifacts) -> list[dict[str, Any]]:
    summary = artifacts.omlx_summary or {}
    blocks: list[dict[str, Any]] = []
    lang = config_language(config)

    def t(key: str) -> str:
        return label(lang, key)

    if config.notion_include_overview:
        blocks.append(_header_callout(config, artifacts, lang))

    if config.notion_include_summary:
        blocks.extend(_heading(t("summary")))
        blocks.extend(_paragraphs(str(summary.get("summary") or artifacts.summary_markdown or t("no_summary"))))
    if config.notion_include_topics:
        topics = _values(summary.get("topics"))
        if topics:
            blocks.append(_chips_paragraph(topics))

    if artifacts.user_notes:
        blocks.append(_titled_callout("📝", t("my_notes"), "purple_background", _paragraphs(artifacts.user_notes)))

    if artifacts_profile(config, artifacts) == STUDENT:
        blocks.extend(_lecture_blocks(config, summary, lang))
    else:
        blocks.extend(_meeting_blocks(config, summary, lang))

    if artifacts.archived_audio_file or config.notion_include_transcript:
        blocks.append(_divider())
    if artifacts.archived_audio_file:
        # Notion only links web URLs, so the local recording is shown as a path to open from Finder.
        blocks.append(_callout(f"{t('audio')}: {artifacts.archived_audio_file}", color="gray_background", icon="🎧"))
    if config.notion_include_transcript:
        blocks.append(_transcript_toggle(t("full_transcript"), artifacts.transcript_text or t("no_transcript")))
    return blocks[:MAX_CHILDREN]


def _meeting_blocks(config: Config, summary: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    def t(key: str) -> str:
        return label(lang, key)

    blocks: list[dict[str, Any]] = []
    columns = []
    if config.notion_include_decisions:
        columns.append(_heading("✅ " + t("decisions"), level=3) + _decision_items(summary.get("decisions"), lang))
    if config.notion_include_action_items:
        columns.append(_heading("☑️ " + t("action_items"), level=3) + _action_items(summary.get("action_items"), lang))
    if columns:
        blocks.append(_divider())
        blocks.extend(columns[0] if len(columns) == 1 else [_columns(columns)])

    callouts = []
    if config.notion_include_open_questions and _values(summary.get("open_questions")):
        callouts.append(_list_callout("❓", t("open_questions"), summary.get("open_questions"), "yellow_background"))
    if config.notion_include_risks and _values(summary.get("risks")):
        callouts.append(_list_callout("⚠️", t("risks"), summary.get("risks"), "red_background"))
    if callouts:
        blocks.append(_divider())
        blocks.extend(callouts)
    return blocks


def _lecture_blocks(config: Config, summary: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    """Concepts are often a few lines each, so they get the full width instead of columns."""
    def t(key: str) -> str:
        return label(lang, key)

    blocks: list[dict[str, Any]] = []
    if config.notion_include_key_concepts:
        blocks.append(_divider())
        blocks.extend(_heading("💡 " + t("key_concepts"), level=3))
        blocks.extend(_concept_items(summary.get("key_concepts"), lang))
    if config.notion_include_assignments:
        blocks.append(_divider())
        blocks.extend(_heading("📌 " + t("assignments"), level=3))
        blocks.extend(_action_items(summary.get("assignments"), lang, empty="no_assignments"))

    callouts = []
    if config.notion_include_exam_hints and _values(summary.get("exam_hints")):
        callouts.append(_list_callout("🎯", t("exam_hints"), summary.get("exam_hints"), "green_background"))
    if config.notion_include_review_questions and _values(summary.get("review_questions")):
        callouts.append(_list_callout("❓", t("review_questions"), summary.get("review_questions"), "yellow_background"))
    if config.notion_include_references and _values(summary.get("references")):
        callouts.append(_list_callout("📚", t("references"), summary.get("references"), "gray_background"))
    if callouts:
        blocks.append(_divider())
        blocks.extend(callouts)
    return blocks


def _header_callout(config: Config, artifacts: MeetingArtifacts, lang: str) -> dict[str, Any]:
    metadata = artifacts.meeting_metadata or {}
    frontmatter = artifacts.frontmatter
    lines: list[list[dict[str, Any]]] = []

    when = when_text(artifacts, lang)
    duration = duration_text(artifacts)
    if when:
        line = [_text(when, bold=True)]
        if duration:
            line.append(_text(f"  ·  {duration}", color="gray"))
        lines.append(line)
    people = participants(artifacts)
    if not when and not people:
        lines.append([_text(label(lang, "calendar_metadata_missing"), italic=True, color="gray")])
    if people:
        lines.append([_text("👥  "), _text(", ".join(people))])

    speakers = [name for name in _speaker_labels(artifacts) if name not in people]
    if speakers and config.notion_include_speakers:
        lines.append([_text("🎙️  ")] + _chips(speakers, colors=["gray_background"]))

    tags = [
        str(value)
        for value in (metadata.get("project") or frontmatter.get("project"), metadata.get("theme") or frontmatter.get("theme"))
        if value
    ]
    if tags:
        lines.append([_text("🏷️  ")] + _chips(tags))

    rich_text: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        if index:
            rich_text.append(_text("\n"))
        rich_text.extend(line)
    return {
        "object": "block",
        "type": "callout",
        "callout": {
            "rich_text": rich_text[:MAX_RICH_TEXT] or [_text(label(lang, "no_metadata"))],
            "icon": {"type": "emoji", "emoji": "🗓️"},
            "color": "gray_background",
        },
    }


def _heading(text: str, level: int = 2) -> list[dict[str, Any]]:
    kind = f"heading_{level}"
    return [{"object": "block", "type": kind, kind: {"rich_text": [_text(text)]}}]


def _divider() -> dict[str, Any]:
    return {"object": "block", "type": "divider", "divider": {}}


def _callout(text: str, color: str = "default", icon: str | None = None) -> dict[str, Any]:
    callout: dict[str, Any] = {
        "rich_text": [_text(text)],
        "color": color,
    }
    if icon:
        callout["icon"] = {"type": "emoji", "emoji": icon}
    return {
        "object": "block",
        "type": "callout",
        "callout": callout,
    }


def _titled_callout(icon: str, title: str, color: str, children: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "object": "block",
        "type": "callout",
        "callout": {
            "rich_text": [_text(title, bold=True)],
            "icon": {"type": "emoji", "emoji": icon},
            "color": color,
            "children": children[:MAX_CHILDREN],
        },
    }


def _list_callout(icon: str, title: str, values: Any, color: str) -> dict[str, Any]:
    return _titled_callout(icon, title, color, [_bulleted(item) for item in _values(values)])


def _paragraphs(text: str, max_blocks: int = 20) -> list[dict[str, Any]]:
    """One block per paragraph of the source, so the summary keeps its own breaks."""
    blocks = []
    for part in re.split(r"\n\s*\n", text.strip()):
        if part.strip():
            blocks.append(_paragraph_rich([_text(chunk) for chunk in _chunks(part, MAX_TEXT)]))
    return blocks[:max_blocks]


def _paragraph(text: str) -> dict[str, Any]:
    return _paragraph_rich([_text(text)])


def _paragraph_rich(rich_text: list[dict[str, Any]]) -> dict[str, Any]:
    return {"object": "block", "type": "paragraph", "paragraph": {"rich_text": rich_text[:MAX_RICH_TEXT]}}


def _empty_note(text: str) -> dict[str, Any]:
    return _paragraph_rich([_text(text, italic=True, color="gray")])


def _values(values: Any) -> list[str]:
    if not values:
        return []
    if isinstance(values, str):
        return [values]
    output = []
    if isinstance(values, list):
        for value in values:
            if isinstance(value, dict):
                output.append(_dict_value_text(value))
            else:
                output.append(str(value))
    else:
        output.append(str(values))
    return [item.strip() for item in output if item and item.strip()]


def _dict_value_text(value: dict[str, Any]) -> str:
    preferred = [
        "term",
        "explanation",
        "text",
        "task",
        "topic",
        "title",
        "question",
        "risk",
        "owner",
        "due_date",
    ]
    parts = [str(value.get(key)) for key in preferred if value.get(key)]
    if parts:
        return " - ".join(parts)
    return " - ".join(str(item) for item in value.values() if item)


def _decision_items(values: Any, lang: str) -> list[dict[str, Any]]:
    items = []
    for text, owner in decisions(values):
        rich_text = [_text(text[:MAX_TEXT])]
        if owner:
            rich_text.append(_text(f"  — {owner}", color="gray"))
        items.append(_bullet_rich(rich_text))
    return items[: MAX_CHILDREN - 1] or [_empty_note(label(lang, "no_decisions"))]


def _concept_items(values: Any, lang: str) -> list[dict[str, Any]]:
    items = []
    for term, explanation in key_concepts(values):
        rich_text = [_text(term[:MAX_TEXT], bold=True)]
        if explanation:
            rich_text.append(_text(f" — {explanation}"[:MAX_TEXT]))
        items.append(_bullet_rich(rich_text))
    return items[: MAX_CHILDREN - 1] or [_empty_note(label(lang, "no_key_concepts"))]


def _action_items(values: Any, lang: str, empty: str = "no_action_items") -> list[dict[str, Any]]:
    items = []
    for item in action_items(values):
        rich_text = [_text(item["task"][:MAX_TEXT])]
        if item["owner"]:
            rich_text.extend([_text("  "), _text(f" {item['owner']} ", bold=True, color="blue_background")])
        if item["due"]:
            rich_text.append(_text("  📅 "))
            rich_text.append(_date_mention(item["due"]) or _text(item["due"], color="orange"))
        items.append({"object": "block", "type": "to_do", "to_do": {"rich_text": rich_text, "checked": item["done"]}})
    return items[: MAX_CHILDREN - 1] or [_empty_note(label(lang, empty))]


def _date_mention(value: str) -> dict[str, Any] | None:
    """Real Notion dates show up in reminders and calendars; free text like 'venerdì' stays text."""
    day = iso_day(value)
    return {"type": "mention", "mention": {"type": "date", "date": {"start": day}}} if day else None


def _columns(columns: list[list[dict[str, Any]]]) -> dict[str, Any]:
    return {
        "object": "block",
        "type": "column_list",
        "column_list": {
            "children": [
                {"object": "block", "type": "column", "column": {"children": children or [_paragraph("")]}}
                for children in columns
            ]
        },
    }


def _chips(values: list[str], colors: list[str] = CHIP_COLORS) -> list[dict[str, Any]]:
    rich_text: list[dict[str, Any]] = []
    for index, value in enumerate(values[:20]):
        if index:
            rich_text.append(_text("  "))
        rich_text.append(_text(f" {value} ", color=colors[index % len(colors)]))
    return rich_text


def _chips_paragraph(values: list[str]) -> dict[str, Any]:
    return _paragraph_rich([_text("🔖  ")] + _chips(values, colors=["gray_background"]))


def _bulleted(text: str) -> dict[str, Any]:
    return _bullet_rich([_text(text[:MAX_TEXT])])


def _bullet_rich(rich_text: list[dict[str, Any]]) -> dict[str, Any]:
    return {"object": "block", "type": "bulleted_list_item", "bulleted_list_item": {"rich_text": rich_text}}


def _transcript_toggle(title: str, transcript: str) -> dict[str, Any]:
    return {
        "object": "block",
        "type": "heading_2",
        "heading_2": {
            "rich_text": [_text("🎙️ " + title)],
            "is_toggleable": True,
            "children": _transcript_blocks(transcript),
        },
    }


def _transcript_blocks(transcript: str) -> list[dict[str, Any]]:
    """One paragraph per speaker turn, with the name in bold and a stable color per speaker.

    Long meetings have more turns than a block may hold children, so turns are packed
    several per paragraph (separated by line breaks) to stay inside Notion's limits.
    """
    turns = transcript_turns(transcript)
    if not turns:
        return [_paragraph(chunk) for chunk in _chunks(transcript, MAX_TEXT)][:MAX_CHILDREN]

    colors: dict[str, str] = {}
    turn_texts = []
    for speaker, text in turns:
        color = colors.setdefault(speaker, SPEAKER_COLORS[len(colors) % len(SPEAKER_COLORS)])
        rich_text = [_text(speaker, bold=True, color=color), _text("  ")]
        rich_text.extend(_text(chunk) for chunk in _chunks(text, MAX_TEXT))
        turn_texts.append(rich_text)

    per_block = -(-len(turn_texts) // MAX_CHILDREN)
    blocks: list[dict[str, Any]] = []
    current: list[dict[str, Any]] = []
    count = 0
    for rich_text in turn_texts:
        if current and (count >= per_block or len(current) + len(rich_text) + 1 > MAX_RICH_TEXT):
            blocks.append(_paragraph_rich(current))
            current, count = [], 0
        if current:
            current.append(_text("\n\n"))
        current.extend(rich_text)
        count += 1
    if current:
        blocks.append(_paragraph_rich(current))
    return blocks[:MAX_CHILDREN]


def _text(content: str, bold: bool = False, italic: bool = False, color: str = "default") -> dict[str, Any]:
    item: dict[str, Any] = {"type": "text", "text": {"content": content[:MAX_TEXT]}}
    if bold or italic or color != "default":
        item["annotations"] = {"bold": bold, "italic": italic, "color": color}
    return item


def _rich_text(content: str) -> dict[str, Any]:
    return {"type": "text", "text": {"content": content[:2000]}}


def _chunks(text: str, size: int) -> list[str]:
    clean = text.strip()
    if not clean:
        return []
    return [clean[index : index + size] for index in range(0, len(clean), size)]


def _speaker_labels(artifacts: MeetingArtifacts) -> list[str]:
    data = artifacts.millet_json
    if not isinstance(data, dict):
        return []
    speakers = data.get("speakers")
    if not isinstance(speakers, list):
        return []
    labels = []
    for speaker in speakers:
        if not isinstance(speaker, dict):
            continue
        name = str(speaker.get("label") or speaker.get("id") or "").strip()
        if name and name not in labels:
            labels.append(name)
    return labels
