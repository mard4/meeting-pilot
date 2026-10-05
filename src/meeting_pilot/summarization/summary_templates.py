from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..profiles import STUDENT, artifacts_profile

AUTO = "auto"
GENERAL = "general"


@dataclass(frozen=True)
class SummaryTemplate:
    id: str
    name: str
    instructions: str
    # Matched against the meeting title when the template is picked automatically.
    keywords: tuple[str, ...] = ()


BUILTIN_TEMPLATES: tuple[SummaryTemplate, ...] = (
    SummaryTemplate(
        id=GENERAL,
        name="General",
        instructions="",
    ),
    SummaryTemplate(
        id="one_on_one",
        name="1:1",
        instructions=(
            "This is a one-to-one meeting. In the summary, cover how the other person is doing, "
            "feedback given in either direction, career or growth topics, and blockers they raised. "
            "Action items must say clearly who owns them."
        ),
        keywords=("1:1", "1-1", "1on1", "one on one", "one-on-one", "one to one", "one-to-one"),
    ),
    SummaryTemplate(
        id="standup",
        name="Standup",
        instructions=(
            "This is a standup. Write the summary as one short entry per person: what they finished, "
            "what they are working on next, and any blocker. Put every blocker in risks."
        ),
        keywords=("standup", "stand-up", "stand up", "daily", "scrum"),
    ),
    SummaryTemplate(
        id="client_call",
        name="Client call",
        instructions=(
            "This is a call with a client or prospect. In the summary, cover the client's needs and pain "
            "points, objections, budget and timeline signals, and competitors mentioned. Action items must "
            "include the agreed next steps and follow-ups owed to the client."
        ),
        keywords=("client", "cliente", "customer", "sales", "vendita", "demo", "prospect", "offerta"),
    ),
    SummaryTemplate(
        id="interview",
        name="Interview",
        instructions=(
            "This is a job interview. In the summary, cover the candidate's background, strengths, concerns, "
            "and answers to key questions. Keep assessments factual and tied to what was said; never invent "
            "a hiring decision."
        ),
        keywords=("interview", "colloquio", "candidato", "candidata", "candidate", "hiring", "selezione"),
    ),
    SummaryTemplate(
        id="project_review",
        name="Project review",
        instructions=(
            "This is a project status or review meeting. In the summary, cover progress against plan, "
            "what changed since last time, scope or timeline changes, and dependencies. Put slipping "
            "deadlines and dependencies in risks."
        ),
        keywords=(
            "review", "retro", "retrospettiva", "sprint", "kickoff", "kick-off", "stato avanzamento",
            "sal", "status", "avanzamento",
        ),
    ),
)


def custom_templates() -> tuple[SummaryTemplate, ...]:
    """User templates from SUMMARY_TEMPLATES_FILE, written by the app's Settings."""
    path = os.getenv("SUMMARY_TEMPLATES_FILE", "").strip()
    if not path:
        return ()
    try:
        payload = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ()
    items = payload.get("templates") if isinstance(payload, dict) else None
    result = []
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        template_id = str(item.get("id") or "").strip()
        name = str(item.get("name") or "").strip()
        instructions = str(item.get("instructions") or "").strip()
        if not template_id or not name or template_id in {AUTO, GENERAL}:
            continue
        keywords = tuple(
            str(keyword).strip() for keyword in item.get("keywords") or [] if str(keyword).strip()
        )
        result.append(SummaryTemplate(template_id, name, instructions, keywords))
    return tuple(result)


def all_templates() -> tuple[SummaryTemplate, ...]:
    return custom_templates() + BUILTIN_TEMPLATES


def resolve_template(config: object, session_dir: Path, meeting_metadata: dict[str, Any], title: str) -> SummaryTemplate:
    """Per-meeting choice from the live sidebar, then the default from Settings, then a
    keyword match on the meeting title, then General."""
    templates = {template.id: template for template in all_templates()}
    for choice in (_sidecar_choice(session_dir), getattr(config, "summary_template", AUTO)):
        if choice and choice != AUTO and choice in templates:
            return templates[choice]
    titles = [
        str(value)
        for value in (meeting_metadata.get("title"), meeting_metadata.get("subject"), title)
        if value
    ]
    # Custom templates come first so a user's own keywords win over the built-ins.
    for template in all_templates():
        if any(_keyword_matches(keyword, text) for keyword in template.keywords for text in titles):
            return template
    return templates[GENERAL]


def _sidecar_choice(session_dir: Path) -> str:
    try:
        payload = json.loads((session_dir / "sidecar" / "template.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    return str(payload.get("template") or "").strip() if isinstance(payload, dict) else ""


def _keyword_matches(keyword: str, text: str) -> bool:
    # Word boundaries so "sal" matches "SAL marzo" but not "salute".
    pattern = r"(?<![\w])" + re.escape(keyword.casefold()) + r"(?![\w])"
    return re.search(pattern, text.casefold()) is not None


def summary_guidance(config: object, artifacts: object) -> str:
    """Extra system-prompt text shared by every summary provider: the meeting type
    and the notes the user typed during the call."""
    template = resolve_template(
        config,
        artifacts.session_dir,
        artifacts.meeting_metadata or {},
        artifacts.title,
    )
    parts = []
    transcript_json = getattr(artifacts, "millet_json", None)
    speakers = transcript_json.get("speakers") if isinstance(transcript_json, dict) else None
    me = next((s for s in speakers or [] if isinstance(s, dict) and s.get("id") == "me"), None)
    if me:
        parts.append(
            f"Transcript lines labelled \"{me.get('label')}\" are the user who recorded the meeting; "
            "the other speaker labels are the remote participants."
        )
    teams_names = [
        str(s.get("label")) for s in speakers or [] if isinstance(s, dict) and s.get("source") == "teams"
    ]
    if teams_names:
        parts.append(
            "These transcript labels are real participant names, identified from who was talking in "
            f"the Teams call: {', '.join(teams_names)}. Use them as participants and action item owners."
        )
    # The built-in templates describe work meetings (owners, blockers, clients); a lecture
    # takes its structure from the study-notes schema. The user's own templates still apply.
    lecture = artifacts_profile(config, artifacts) == STUDENT
    if template.instructions and not (lecture and template in BUILTIN_TEMPLATES):
        parts.append(f"Meeting type: {template.name}.\n{template.instructions}")
    notes = (getattr(artifacts, "user_notes", "") or "").strip()
    if notes:
        parts.append(
            "The user typed these notes during the meeting. Treat each one as important: make sure "
            "the summary, decisions and action items cover every point, expanded with details from "
            "the transcript. Where a note conflicts with the transcript, follow the transcript.\n"
            f"User notes:\n{notes[:8000]}"
        )
    return "\n\n".join(parts)
