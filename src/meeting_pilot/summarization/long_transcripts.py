"""Fit a long transcript (a two-hour lecture, a podcast) into one summary request.

The OpenAI-compatible summarizer sends at most `TRANSCRIPT_LIMIT` characters, about an
hour and three quarters of speech, and would silently drop the rest. Longer transcripts
are condensed part by part first, keeping the facts a summary needs, and the summary is
written from the condensed parts. The Apple Intelligence helper splits transcripts on
its own, so it gets the full text.
"""
from __future__ import annotations

import dataclasses
import json
import socket
import ssl
import urllib.error
import urllib.request
from typing import Any

import certifi

from ..artifacts import MeetingArtifacts
from ..config import Config
from .builtin_model import is_builtin, transcript_limit as builtin_transcript_limit
from .omlx_client import is_ollama, ollama_chat_request, strip_model_wrapping, summary_endpoint

# Matches the cap in `summarize_with_openai_compatible`.
TRANSCRIPT_LIMIT = 120_000
PART_CHARACTERS = 40_000

CONDENSE_PROMPT = """You condense one part of a long transcript into dense notes that a later step will summarize.
Keep every term, definition, formula, method, example, name, number, date, deadline, decision, task, question and reference that is mentioned, in the order it comes up.
Drop greetings, filler, repetitions and small talk.
Write in the language of the transcript, as plain text without any preamble.
"""


def fit_for_summary(config: Config, artifacts: MeetingArtifacts, apple_fallback: bool = False) -> MeetingArtifacts:
    """Artifacts whose transcript fits one summary request; the published note keeps
    the full transcript because only this copy is condensed. `apple_fallback` is set
    when Apple Intelligence was chosen but could not run, so the OpenAI-compatible
    provider summarizes after all."""
    transcript = artifacts.transcript_text.strip()
    # The Meeting Pilot model's context is smaller than a server's: its limit is too.
    limit = builtin_transcript_limit() if is_builtin(config) else TRANSCRIPT_LIMIT
    if (config.summary_provider_mode == "apple" and not apple_fallback) or len(transcript) <= limit:
        return artifacts
    parts = split_transcript(transcript, min(PART_CHARACTERS, limit))
    condensed = []
    for index, part in enumerate(parts, start=1):
        print(f"Long transcript: condensing part {index} of {len(parts)}...", flush=True)
        notes = _complete_text(config, CONDENSE_PROMPT, f"Transcript part {index} of {len(parts)}:\n{part}")
        condensed.append(f"[Part {index} of {len(parts)}]\n{notes.strip()}")
    return dataclasses.replace(artifacts, transcript_text="\n\n".join(condensed))


def split_transcript(text: str, maximum_characters: int) -> list[str]:
    """Consecutive parts that break between lines, or inside a line only when it is
    longer than a whole part."""
    parts: list[str] = []
    current = ""
    for line in text.splitlines(keepends=True):
        while len(line) > maximum_characters:
            if current:
                parts.append(current)
                current = ""
            parts.append(line[:maximum_characters])
            line = line[maximum_characters:]
        if current and len(current) + len(line) > maximum_characters:
            parts.append(current)
            current = ""
        current += line
    if current.strip():
        parts.append(current)
    return [part.strip() for part in parts if part.strip()]


def _complete_text(config: Config, system_prompt: str, user_prompt: str) -> str:
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]
    headers = {"Content-Type": "application/json"}
    if config.summary_api_key:
        headers["Authorization"] = f"Bearer {config.summary_api_key}"
    with summary_endpoint(config) as base_url:
        ollama = is_ollama(config)
        if ollama:
            url, body = ollama_chat_request(config, messages, temperature=0.2, json_output=False)
        else:
            url = f"{base_url}/chat/completions"
            body: dict[str, Any] = {"model": config.summary_model, "messages": messages, "temperature": 0.2}
        request = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        timeout_seconds = max(15, int(getattr(config, "summary_timeout_seconds", 180)))
        ssl_context = ssl.create_default_context(cafile=certifi.where())
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds, context=ssl_context) as response:
                data = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
            raise RuntimeError(f"Summary provider request failed: {exc}") from exc
    content = data["message"]["content"] if ollama else data["choices"][0]["message"]["content"]
    return strip_model_wrapping(str(content))
