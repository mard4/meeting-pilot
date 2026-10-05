from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from ..artifacts import MeetingArtifacts
from ..config import Config
from ..tag_catalog import catalog_values
from ..language import config_language, language_name
from ..profiles import STUDENT, WORKER
from .summary_templates import summary_guidance


class AppleIntelligenceUnavailable(RuntimeError):
    """The system on-device model cannot be used on this Mac right now."""


def summarize_with_apple_intelligence(
    config: Config, artifacts: MeetingArtifacts, profile: str = WORKER
) -> dict[str, Any]:
    command_path = Path(config.apple_intelligence_summarizer_cmd).expanduser()
    if not command_path.is_file():
        raise AppleIntelligenceUnavailable(f"Apple Intelligence helper not found: {command_path}")

    input_path = artifacts.session_dir / "apple_intelligence_input.json"
    output_path = artifacts.session_dir / "apple_intelligence_summary.json"
    log_path = artifacts.session_dir / "apple_intelligence_summarizer.log"
    input_path.write_text(
        json.dumps(
            {
                "transcript": artifacts.transcript_text,
                "existingSummary": artifacts.summary_markdown,
                "frontmatter": artifacts.frontmatter,
                "calendarMetadata": artifacts.meeting_metadata,
                "knownProjects": _known_projects(config),
                "locale": config.transcription_locale,
                "customPrompt": "\n\n".join(
                    part for part in (config.summary_prompt, summary_guidance(config, artifacts)) if part
                ),
                "outputLanguage": language_name(config_language(config)),
                "profile": profile,
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    availability = subprocess.run(
        [str(command_path), "--availability"],
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    try:
        status = json.loads(availability.stdout)
    except json.JSONDecodeError:
        status = {}
    if availability.returncode != 0 or status.get("status") != "available":
        reason = status.get("reason") or availability.stderr.strip() or "unknown reason"
        raise AppleIntelligenceUnavailable(f"Apple Intelligence unavailable: {reason}")

    command = [str(command_path), str(input_path), str(output_path)]
    try:
        with log_path.open("w", encoding="utf-8") as log:
            log.write("$ " + " ".join(command) + "\n\n")
            result = subprocess.run(
                command,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
                text=True,
                timeout=config.apple_intelligence_timeout_seconds,
            )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"Apple Intelligence summarization timed out after "
            f"{config.apple_intelligence_timeout_seconds} seconds. See {log_path}"
        ) from exc
    if result.returncode != 0:
        detail = log_path.read_text(encoding="utf-8", errors="replace")
        if "Apple Intelligence unavailable" in detail:
            raise AppleIntelligenceUnavailable(detail.strip())
        raise RuntimeError(
            f"Apple Intelligence summarization failed with exit code {result.returncode}. See {log_path}"
        )
    try:
        data = json.loads(output_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Apple Intelligence returned invalid JSON. See {log_path}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"Apple Intelligence returned an invalid summary. See {log_path}")
    return _normalize_summary(data, artifacts, profile)


def _known_projects(config: Config) -> list[str]:
    try:
        return catalog_values(config)["projects"]
    except (AttributeError, OSError, TypeError):
        return []


def _normalize_summary(data: dict[str, Any], artifacts: MeetingArtifacts, profile: str = WORKER) -> dict[str, Any]:
    """Enforce facts that guided generation cannot safely infer."""
    participants = artifacts.meeting_metadata.get("participants")
    if not isinstance(participants, list):
        participants = []
    participants = [str(value).strip() for value in participants if str(value).strip()]
    allowed_owners = {value.casefold(): value for value in participants}
    source_context = json.dumps(
        {"frontmatter": artifacts.frontmatter, "calendar_metadata": artifacts.meeting_metadata},
        ensure_ascii=False,
    ).casefold()
    transcript_context = artifacts.transcript_text.casefold()

    data["participants"] = participants
    if not any(key in artifacts.meeting_metadata or key in artifacts.frontmatter for key in ("date", "start", "start_time", "datetime")):
        data["date"] = None

    for decision in data.get("decisions", []):
        if isinstance(decision, dict):
            owner = str(decision.get("owner") or "").strip()
            decision["owner"] = allowed_owners.get(owner.casefold())

    # Lecture assignments carry a due date like action items, but no owner.
    for item in data.get("assignments" if profile == STUDENT else "action_items", []):
        if not isinstance(item, dict):
            continue
        if profile != STUDENT:
            owner = str(item.get("owner") or "").strip()
            item["owner"] = allowed_owners.get(owner.casefold())
            item["status"] = "open"
        due_date = str(item.get("due_date") or "").strip()
        if due_date.casefold() in {"", "nil", "null", "none"}:
            item["due_date"] = None
        elif due_date.casefold() not in transcript_context and due_date.casefold() not in source_context:
            item["due_date"] = None
    return data
