from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.profiles import STUDENT, WORKER, resolve_profile
from meeting_pilot.publishing.apple_notes_publisher import _note_body
from meeting_pilot.publishing.notion_publisher import _build_blocks, _build_properties
from meeting_pilot.publishing.obsidian_publisher import _note_content
from meeting_pilot.summarization.apple_intelligence_client import _normalize_summary
from meeting_pilot.summarization.omlx_client import summarize_with_openai_compatible
from meeting_pilot.summarization.summary_templates import summary_guidance

LECTURE_SUMMARY = {
    "profile": "student",
    "title": "Limiti e continuità",
    "summary": "La lezione introduce i limiti di funzione.",
    "topics": ["Limiti", "Continuità"],
    "key_concepts": [
        {"term": "Limite", "explanation": "Il valore a cui tende f(x) quando x si avvicina a un punto."},
        {"term": "Funzione continua", "explanation": "Il limite in un punto coincide con il valore."},
    ],
    "assignments": [{"task": "Esercizi 1-10 del capitolo 3", "due_date": "2026-10-12"}],
    "exam_hints": ["Il teorema di Weierstrass sarà all'esame."],
    "review_questions": ["Quando una funzione è continua in un punto?"],
    "references": ["Bramanti, capitolo 3"],
}


def _session(tmp_path: Path, **sidecar: str) -> Path:
    session = tmp_path / "session"
    for name, content in sidecar.items():
        (session / "sidecar").mkdir(parents=True, exist_ok=True)
        (session / "sidecar" / name).write_text(content, encoding="utf-8")
    session.mkdir(parents=True, exist_ok=True)
    return session


def _lecture(tmp_path: Path) -> MeetingArtifacts:
    return MeetingArtifacts(
        session_dir=_session(tmp_path),
        audio_file=tmp_path / "audio.m4a",
        title="Lezione",
        transcript_text="Prof: oggi parliamo di limiti.",
        meeting_metadata={"start": "2026-10-05T09:00:00", "project": "Analisi 1", "theme": "Limiti"},
        omlx_summary=dict(LECTURE_SUMMARY),
    )


def _config(**overrides):
    config = SimpleNamespace(
        user_profile="student",
        output_language="it",
        summary_model="test",
        transcription_provider="fluid",
        notion_title_property="Name",
        notion_project_property="Project",
    )
    for section in (
        "overview", "summary", "topics", "decisions", "action_items", "open_questions", "risks", "speakers",
        "transcript", "key_concepts", "assignments", "exam_hints", "review_questions", "references",
    ):
        setattr(config, f"notion_include_{section}", True)
    for key, value in overrides.items():
        setattr(config, key, value)
    return config


# Which profile a recording gets


def test_profile_comes_from_the_sidebar_then_the_user_then_the_title(tmp_path: Path) -> None:
    plain = _session(tmp_path / "plain")
    chosen = _session(tmp_path / "chosen", **{"profile.json": '{"profile": "worker"}'})

    assert resolve_profile(SimpleNamespace(user_profile="student"), plain, {}, "Weekly sync") == STUDENT
    assert resolve_profile(SimpleNamespace(user_profile="worker"), plain, {}, "Lezione di Fisica") == WORKER
    assert resolve_profile(SimpleNamespace(user_profile="student"), chosen, {}, "Lezione di Fisica") == WORKER
    assert resolve_profile(SimpleNamespace(), plain, {}, "Lezione") == WORKER, "existing installs stay workers"


def test_someone_both_student_and_worker_gets_lectures_from_the_title(tmp_path: Path) -> None:
    both = SimpleNamespace(user_profile="both")
    session = _session(tmp_path)

    assert resolve_profile(both, session, {"title": "Lezione 4 - Analisi"}, "") == STUDENT
    assert resolve_profile(both, session, {}, "Corso di Fisica Tecnica") == STUDENT
    assert resolve_profile(both, session, {"subject": "Vorlesung Statistik"}, "") == STUDENT
    assert resolve_profile(both, session, {"title": "Progetti in corso"}, "") == WORKER
    assert resolve_profile(both, session, {"title": "Riunione di prova"}, "") == WORKER
    assert resolve_profile(both, session, {"title": "Weekly sync"}, "") == WORKER


# Published notes


def test_obsidian_lecture_note_has_study_sections_instead_of_meeting_ones(tmp_path: Path) -> None:
    note = _note_content(_config(), _lecture(tmp_path), "Limiti e continuità", "2026-10-05")

    assert "## Concetti chiave" in note
    assert "- **Limite** — Il valore a cui tende f(x) quando x si avvicina a un punto." in note
    assert "## Compiti e scadenze" in note
    assert "- [ ] Esercizi 1-10 del capitolo 3 📅 2026-10-12" in note
    assert "> [!tip] Per l'esame\n> - Il teorema di Weierstrass sarà all'esame." in note
    assert "> [!question] Domande di ripasso" in note
    assert "## Riferimenti\n\n- Bramanti, capitolo 3" in note
    assert "**Corso:** Analisi 1" in note
    assert 'type: "study"' in note
    assert "  - lecture" in note
    for meeting_heading in ("## Decisioni", "## Action item"):
        assert meeting_heading not in note


def test_disabled_lecture_sections_are_left_out(tmp_path: Path) -> None:
    config = _config(notion_include_review_questions=False, notion_include_key_concepts=False)
    note = _note_content(config, _lecture(tmp_path), "Limiti", "2026-10-05")

    assert "Domande di ripasso" not in note
    assert "Concetti chiave" not in note
    assert "Compiti e scadenze" in note


def test_notion_lecture_page_has_study_blocks_and_a_study_type(tmp_path: Path) -> None:
    artifacts = _lecture(tmp_path)
    config = _config(user_profile="both")

    blocks = _build_blocks(config, artifacts)
    text = json.dumps(blocks, ensure_ascii=False)
    properties = _build_properties(config, artifacts, "Limiti", keep_unsupported=True)

    assert "💡 Concetti chiave" in text and "📌 Compiti e scadenze" in text
    assert "🎯" in text and "Per l'esame" in text and "Domande di ripasso" in text and "Bramanti" in text
    assert "Decisioni" not in text
    assert sum(block["type"] == "to_do" for block in blocks) == 1
    assert properties["Type"] == {"select": {"name": "Study"}}


def test_notion_type_column_only_appears_for_people_who_study(tmp_path: Path) -> None:
    artifacts = _lecture(tmp_path)
    artifacts.omlx_summary = {"profile": "worker", "summary": "Riunione."}

    worker = _build_properties(_config(user_profile="worker"), artifacts, "Sync", keep_unsupported=True)
    both = _build_properties(_config(user_profile="both"), artifacts, "Sync", keep_unsupported=True)

    assert "Type" not in worker
    assert both["Type"] == {"select": {"name": "Work"}}


def test_apple_notes_lecture_lists_study_sections(tmp_path: Path) -> None:
    body = _note_body(_config(), _lecture(tmp_path))

    assert "Corso: Analisi 1" in body
    assert "Concetti chiave\n- Limite - Il valore a cui tende" in body
    assert "Per l'esame\n- Il teorema di Weierstrass" in body
    assert "Decisioni" not in body


# What the model is asked for


def _request_body(profile: str, tmp_path: Path) -> dict:
    config = SimpleNamespace(
        summary_model="test", summary_response_format_json=False, summary_api_key=None,
        summary_base_url="https://api.example.test/v1", summary_prompt="", summary_timeout_seconds=60,
        user_profile=profile, output_language="it",
    )
    artifacts = MeetingArtifacts(
        session_dir=_session(tmp_path), audio_file=tmp_path / "audio.m4a", title="Registrazione",
        transcript_text="Prof: oggi vediamo i limiti.",
    )
    response = MagicMock()
    response.read.return_value = json.dumps({"choices": [{"message": {"content": "{}"}}]}).encode()
    response.__enter__.return_value = response
    with patch("meeting_pilot.summarization.omlx_client.urllib.request.urlopen", return_value=response) as urlopen:
        summarize_with_openai_compatible(config, artifacts)
    return json.loads(urlopen.call_args.args[0].data.decode("utf-8"))


def test_lectures_ask_the_model_for_study_notes(tmp_path: Path) -> None:
    body = _request_body("student", tmp_path)
    system, user = body["messages"][0]["content"], json.loads(body["messages"][1]["content"])

    assert system.startswith("You turn lecture transcripts into study notes.")
    assert set(user["schema"]) >= {"key_concepts", "assignments", "exam_hints", "review_questions", "references"}
    assert not set(user["schema"]) & {"decisions", "action_items", "open_questions", "risks"}


def test_meetings_still_ask_for_meeting_notes(tmp_path: Path) -> None:
    body = _request_body("worker", tmp_path)
    user = json.loads(body["messages"][1]["content"])

    assert body["messages"][0]["content"].startswith("You turn meeting transcripts into actionable meeting notes.")
    assert set(user["schema"]) >= {"decisions", "action_items", "open_questions", "risks"}
    assert "key_concepts" not in user["schema"]


def test_apple_intelligence_drops_assignment_dates_nobody_said(tmp_path: Path) -> None:
    artifacts = _lecture(tmp_path)
    artifacts.transcript_text = "Prof: gli esercizi sono per il 12 ottobre."
    data = {"assignments": [
        {"task": "Esercizi", "due_date": "12 ottobre"},
        {"task": "Lettura", "due_date": "2026-11-30"},
    ]}

    result = _normalize_summary(data, artifacts, STUDENT)

    assert [item["due_date"] for item in result["assignments"]] == ["12 ottobre", None]


def test_built_in_work_templates_do_not_shape_a_lecture(tmp_path: Path) -> None:
    session = _session(tmp_path, **{"template.json": '{"template": "standup"}'})
    artifacts = SimpleNamespace(session_dir=session, meeting_metadata={}, title="Lezione", user_notes="", omlx_summary=None)

    assert "standup" not in summary_guidance(SimpleNamespace(user_profile="student"), artifacts)
    assert "standup" in summary_guidance(SimpleNamespace(user_profile="worker"), artifacts)
