from __future__ import annotations

import locale
import os
import re
import subprocess

DEFAULT_LANGUAGE = "it"

LANGUAGE_NAMES = {
    "it": "Italian",
    "en": "English",
    "fr": "French",
    "de": "German",
    "es": "Spanish",
    "pt": "Portuguese",
    "nl": "Dutch",
}

# Headings and fixed phrases written into published notes. Only Italian and English
# are maintained; every other language falls back to English headings while the
# model still writes the note body in that language.
LABELS: dict[str, dict[str, str]] = {
    "it": {
        "summary": "Sintesi",
        "overview": "Overview",
        "topics": "Topic",
        "decisions": "Decisioni",
        "action_items": "Action item",
        "open_questions": "Domande aperte",
        "risks": "Rischi",
        "participants": "Partecipanti",
        "speakers_detected": "Speaker rilevati",
        "speaker": "Speaker",
        "me_speaker": "Io",
        "my_notes": "Le mie note",
        "full_transcript": "Transcript completo",
        "classification": "Classificazione",
        "project": "Progetto",
        "theme": "Tema",
        "details": "Dettagli",
        "summary_provider": "Provider sintesi",
        "transcription": "Trascrizione",
        "audio": "Audio",
        "open_audio": "Ascolta la registrazione",
        "session": "Sessione",
        "subject": "Oggetto",
        "start": "Inizio",
        "end": "Fine",
        "calendar": "Calendario",
        "recording": "Registrazione",
        "calendar_metadata_missing": "Metadata calendario: non trovati",
        "teams_ui_metadata": "Metadata Teams UI",
        "ui_participants": "Partecipanti UI",
        "due": "Scadenza",
        "no_summary": "Nessuna sintesi disponibile.",
        "no_decisions": "Nessuna decisione rilevata.",
        "no_open_questions": "Nessuna domanda aperta rilevata.",
        "no_risks": "Nessun rischio rilevato.",
        "no_action_items": "Nessun action item rilevato.",
        "no_transcript": "Transcript non disponibile.",
        "no_overview": "Overview non disponibile.",
        "no_metadata": "Metadata meeting non disponibili.",
        "chat_not_found": "Non trovato nei meeting selezionati.",
        "chat_summary": "Sommario",
        "chat_facts": "Fatti",
        "chat_decisions": "Decisioni",
        "chat_inferences": "Inferenze",
        "chat_empty_section": "Nessun elemento rilevato nei passaggi selezionati.",
        "selected": "selezionato",
        "chat_question": "Domanda",
        "chat_saved": "Salvato",
        "chat_answer": "Risposta",
        "chat_sources": "Fonti",
    },
    "en": {
        "summary": "Summary",
        "overview": "Overview",
        "topics": "Topics",
        "decisions": "Decisions",
        "action_items": "Action items",
        "open_questions": "Open questions",
        "risks": "Risks",
        "participants": "Participants",
        "speakers_detected": "Detected speakers",
        "speaker": "Speakers",
        "me_speaker": "Me",
        "my_notes": "My notes",
        "full_transcript": "Full transcript",
        "classification": "Classification",
        "project": "Project",
        "theme": "Topic",
        "details": "Details",
        "summary_provider": "Summary provider",
        "transcription": "Transcription",
        "audio": "Audio",
        "open_audio": "Listen to the recording",
        "session": "Session",
        "subject": "Subject",
        "start": "Start",
        "end": "End",
        "calendar": "Calendar",
        "recording": "Recording",
        "calendar_metadata_missing": "Calendar metadata: not found",
        "teams_ui_metadata": "Teams UI metadata",
        "ui_participants": "UI participants",
        "due": "Due",
        "no_summary": "No summary available.",
        "no_decisions": "No decisions detected.",
        "no_open_questions": "No open questions detected.",
        "no_risks": "No risks detected.",
        "no_action_items": "No action items detected.",
        "no_transcript": "Transcript not available.",
        "no_overview": "Overview not available.",
        "no_metadata": "Meeting metadata not available.",
        "chat_not_found": "Not found in the selected meetings.",
        "chat_summary": "Summary",
        "chat_facts": "Facts",
        "chat_decisions": "Decisions",
        "chat_inferences": "Inferences",
        "chat_empty_section": "Nothing relevant in the selected passages.",
        "selected": "selected",
        "chat_question": "Question",
        "chat_saved": "Saved",
        "chat_answer": "Answer",
        "chat_sources": "Sources",
    },
}

NOT_FOUND_ANSWERS = frozenset(labels["chat_not_found"] for labels in LABELS.values())


def normalize_language(value: str | None) -> str | None:
    """'en-IT', 'en_US', 'English' style values -> two-letter code."""
    if not value:
        return None
    match = re.match(r"\s*([A-Za-z]{2})", value)
    return match.group(1).lower() if match else None


def macos_language() -> str | None:
    try:
        result = subprocess.run(
            ["defaults", "read", "-g", "AppleLanguages"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r'"?([A-Za-z]{2}[A-Za-z_-]*)"?', result.stdout.replace("(", " "))
    return normalize_language(match.group(1)) if match else None


def resolve_output_language() -> str:
    """OUTPUT_LANGUAGE (set by the app when the user picks a language) wins; otherwise
    follow the macOS language, then the process locale."""
    explicit = normalize_language(os.getenv("OUTPUT_LANGUAGE"))
    if explicit:
        return explicit
    system = macos_language() or normalize_language(locale.getlocale()[0])
    return system or DEFAULT_LANGUAGE


def config_language(config: object) -> str:
    return getattr(config, "output_language", None) or DEFAULT_LANGUAGE


def language_name(code: str) -> str:
    return LANGUAGE_NAMES.get(code, "English")


def label(code: str, key: str) -> str:
    table = LABELS.get(code) or LABELS["en"]
    return table[key]
