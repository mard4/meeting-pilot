from __future__ import annotations

import json
import re
import socket
import ssl
import urllib.error
import urllib.request
from contextlib import AbstractContextManager, nullcontext
from typing import Any

import certifi

from ..artifacts import MeetingArtifacts
from ..config import Config
from .apple_intelligence_client import AppleIntelligenceUnavailable, summarize_with_apple_intelligence
from .builtin_model import is_builtin, server as builtin_server
from ..business_glossary import summary_instructions as business_glossary_instructions
from ..language import config_language, language_name
from ..profiles import STUDENT, resolve_profile
from .summary_templates import summary_guidance
from ..tag_catalog import catalog_values


SYSTEM_PROMPT = """You turn meeting transcripts into actionable meeting notes.
Reply with valid JSON only, no Markdown.
Never invent participants, decisions or deadlines: use null when they are missing.
"""

STUDENT_SYSTEM_PROMPT = """You turn lecture transcripts into study notes.
Reply with valid JSON only, no Markdown.
Never invent deadlines, exam information or references: use null or an empty list when they are missing.
"""

PARTICIPANTS_RULE = "Only use calendar_metadata and the participant names identified from Teams for participants; do not treat generic labels such as Speaker 1 or SPEAKER_00 as participant names."


def _meeting_request(language: str) -> tuple[str, dict[str, Any]]:
    task = f"Create structured meeting notes written entirely in {language}: title, tag, theme, summary, topics, decisions, action items, open questions and risks must all be in {language}, translating from the transcript language when it differs. Keep names of people, products and proper nouns as spoken. Generate a concise, descriptive title of 3-8 words that captures the meeting subject. Never include the platform, participant names, email addresses, dates, times, or technical recording filenames in the title. Choose the project tag by analysing the conversation and comparing it with known_projects: reuse a known project only when it is clearly relevant; otherwise propose a concise new project tag. " + PARTICIPANTS_RULE
    schema = {
        "title": "string",
        "tag": "one concise, reusable label for this meeting, 2-5 words, without #",
        "theme": "one concise meeting theme, 2-5 words",
        "date": "ISO date/time string or null",
        "participants": ["string"],
        "summary": "string",
        "topics": ["string"],
        "decisions": [{"text": "string", "owner": "string or null"}],
        "action_items": [
            {
                "owner": "string or null",
                "task": "string",
                "due_date": "string or null",
                "status": "open",
            }
        ],
        "open_questions": ["string"],
        "risks": ["string"],
    }
    return task, schema


def _lecture_request(language: str) -> tuple[str, dict[str, Any]]:
    task = f"Create structured study notes for this lecture written entirely in {language}: title, tag, theme, summary, topics, key concepts, assignments, exam hints, review questions and references must all be in {language}, translating from the transcript language when it differs. Keep names of people, products and proper nouns as spoken. Generate a concise, descriptive title of 3-8 words that captures what the lecture covered. Never include the platform, participant names, email addresses, dates, times, or technical recording filenames in the title. known_projects lists the user's courses: use the course as tag, reusing a known course only when the lecture is clearly about it; otherwise propose a concise new course name. Key concepts are the terms, definitions, formulas and methods the lecture explains, each with a short explanation faithful to the lecturer. Assignments are homework, readings, projects and exam or submission dates the lecturer announced. Exam hints are only what the lecturer said will be examined or stressed as especially important. Review questions are 3-6 questions a student can answer from this lecture alone. References are books, chapters, pages, slides, papers or links that were mentioned. " + PARTICIPANTS_RULE
    schema = {
        "title": "string",
        "tag": "the course this lecture belongs to, 1-5 words, without #",
        "theme": "the lecture's main topic, 2-5 words",
        "date": "ISO date/time string or null",
        "participants": ["string"],
        "summary": "string",
        "topics": ["string"],
        "key_concepts": [{"term": "string", "explanation": "string", "slide": "number of the slide showing it, or null"}],
        "assignments": [{"task": "string", "due_date": "string or null"}],
        "exam_hints": ["string"],
        "review_questions": ["string"],
        "references": ["string"],
    }
    return task, schema


def summarize_with_openai_compatible(
    config: Config, artifacts: MeetingArtifacts, profile: str | None = None
) -> dict[str, Any]:
    transcript = artifacts.transcript_text.strip()
    summary = artifacts.summary_markdown.strip()
    frontmatter = artifacts.frontmatter
    meeting_metadata = artifacts.meeting_metadata
    known_projects = _known_projects(config)
    if not transcript and not summary:
        raise ValueError("No transcript or summary was found for summarization.")

    profile = profile or resolve_profile(config, artifacts.session_dir, meeting_metadata or {}, artifacts.title)
    language = language_name(config_language(config))
    task, schema = _lecture_request(language) if profile == STUDENT else _meeting_request(language)
    user_prompt = {
        "task": task,
        "schema": schema,
        "frontmatter": frontmatter,
        "calendar_metadata": meeting_metadata,
        "known_projects": known_projects,
        "existing_summary": summary,
        "transcript": transcript[:120_000],
    }
    system_prompt = STUDENT_SYSTEM_PROMPT if profile == STUDENT else SYSTEM_PROMPT
    if config.summary_prompt:
        system_prompt += f"\nCustom instructions from the user:\n{config.summary_prompt}\n"
    guidance = summary_guidance(config, artifacts)
    if guidance:
        system_prompt += f"\n{guidance}\n"
    system_prompt += business_glossary_instructions()
    payload = {
        "model": config.summary_model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": json.dumps(user_prompt, ensure_ascii=False)},
        ],
        "temperature": 0.2,
    }
    # The Meeting Pilot model was measured with JSON-constrained output; small models
    # need it to fill the fields reliably.
    if config.summary_response_format_json or is_builtin(config):
        payload["response_format"] = {"type": "json_object"}
    headers = {"Content-Type": "application/json"}
    if config.summary_api_key:
        headers["Authorization"] = f"Bearer {config.summary_api_key}"

    timeout_seconds = max(15, int(getattr(config, "summary_timeout_seconds", 180)))
    with summary_endpoint(config) as base_url:
        ollama = is_ollama(config)
        if ollama:
            url, body = ollama_chat_request(config, payload["messages"], temperature=0.2, json_output=True)
        else:
            url, body = f"{base_url}/chat/completions", payload
        request = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        ssl_context = ssl.create_default_context(cafile=certifi.where())
        print(
            f"Summary request started: model={config.summary_model}, timeout={timeout_seconds}s",
            flush=True,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds, context=ssl_context) as response:
                data = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
            print(f"Summary request failed: {exc}", flush=True)
            raise RuntimeError(f"Summary provider request failed: {exc}") from exc
    print("Summary request completed.", flush=True)

    content = data["message"]["content"] if ollama else data["choices"][0]["message"]["content"]
    try:
        return json.loads(strip_model_wrapping(content))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Summary provider returned non-JSON content: {content[:500]}") from exc


def summary_endpoint(config: Config) -> AbstractContextManager[str]:
    """The provider's base URL; for the Meeting Pilot model, a server started for the request."""
    if is_builtin(config):
        return builtin_server(config)
    return nullcontext(config.summary_base_url)


def is_ollama(config: Config) -> bool:
    return (
        getattr(config, "summary_provider_mode", "") == "local"
        and getattr(config, "summary_runtime", "") == "ollama"
    )


def ollama_chat_request(
    config: Config,
    messages: list[dict[str, str]],
    *,
    temperature: float,
    json_output: bool,
) -> tuple[str, dict[str, Any]]:
    """Ollama's OpenAI-compatible endpoint cannot raise the context window, which
    defaults to a few thousand tokens and silently drops most of a long transcript.
    The native endpoint accepts `num_ctx`, sized here to the actual prompt."""
    base_url = re.sub(r"/v1/?$", "", config.summary_base_url.rstrip("/"))
    prompt_characters = sum(len(message["content"]) for message in messages)
    # ~3 characters per token for mixed Italian/English text, plus room for the answer.
    needed_tokens = prompt_characters // 3 + 4096
    context = 8192
    while context < needed_tokens and context < 65536:
        context *= 2
    body: dict[str, Any] = {
        "model": config.summary_model,
        "messages": messages,
        "stream": False,
        "options": {"temperature": temperature, "num_ctx": context},
    }
    if json_output:
        body["format"] = "json"
    return f"{base_url}/api/chat", body


def strip_model_wrapping(content: str) -> str:
    """Local models often wrap JSON in Markdown fences or prepend a reasoning block."""
    text = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.DOTALL)
    return fenced.group(1) if fenced else text


def summarize(config: Config, artifacts: MeetingArtifacts) -> dict[str, Any]:
    """The summary records whether it was written as meeting or study notes, so
    publishers and later re-publishing render the sections it actually has."""
    profile = resolve_profile(config, artifacts.session_dir, artifacts.meeting_metadata or {}, artifacts.title)
    result: dict[str, Any] | None = None
    if config.summary_provider_mode == "apple":
        try:
            result = summarize_with_apple_intelligence(config, artifacts, profile)
        except AppleIntelligenceUnavailable as exc:
            print(f"{exc}. Falling back to the configured OpenAI-compatible provider...")
            # Imported here: long_transcripts imports this module.
            from .long_transcripts import fit_for_summary

            artifacts = fit_for_summary(config, artifacts, apple_fallback=True)
    if result is None:
        result = summarize_with_openai_compatible(config, artifacts, profile)
    result["profile"] = profile
    return result


def _known_projects(config: Config) -> list[str]:
    try:
        return catalog_values(config)["projects"]
    except (AttributeError, OSError, TypeError):
        return []


def summarize_with_omlx(config: Config, artifacts: MeetingArtifacts) -> dict[str, Any]:
    return summarize_with_openai_compatible(config, artifacts)
