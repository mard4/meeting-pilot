"""Video notes: a tutorial, a talk or a podcast imported from a link is not a meeting."""
from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.profiles import STUDENT, VIDEO, WORKER, resolve_profile
from meeting_pilot.publishing.apple_notes_publisher import _note_body
from meeting_pilot.publishing.notion_publisher import _build_blocks, _build_properties
from meeting_pilot.publishing.obsidian_publisher import _note_content
from meeting_pilot.summarization.omlx_client import summarize_with_openai_compatible
from meeting_pilot.summarization.summary_templates import summary_guidance

YOUTUBE = {
    "origin": "import",
    "media_kind": "video",
    "source_url": "https://www.youtube.com/watch?v=eqdOPEigqSU",
    "recording_start": "2026-10-22T16:52:46",
    "project": "Ableton Live",
    "theme": "Sound design",
}

VIDEO_SUMMARY = {
    "profile": "video",
    "title": "Rumble kick per la techno",
    "summary": "Il video mostra come costruire un rumble kick in Ableton Live partendo da una cassa corta.",
    "topics": ["Rumble kick", "Sidechain"],
    "steps": [
        {"step": "Accorcia la cassa", "details": None},
        {"step": "Aggiungi un delay sincronizzato", "details": "2 a sinistra, 3 a destra, feedback 0, drive 40%"},
    ],
    "key_points": ["Il rumble va tenuto mono."],
    "tools": [{"name": "Drum Buss", "use": "accordare la cassa con la manopola freq"}, {"name": "EQ Eight", "use": None}],
    "tips": ["Metti il sidechain prima dell'EQ per togliere il click."],
    "references": ["Sample pack Driving Techno"],
}


def _session(tmp_path: Path, profile: str | None = None) -> Path:
    session = tmp_path / "session"
    (session / "sidecar").mkdir(parents=True, exist_ok=True)
    if profile:
        (session / "sidecar" / "profile.json").write_text(json.dumps({"profile": profile}), encoding="utf-8")
    return session


def _video(tmp_path: Path) -> MeetingArtifacts:
    return MeetingArtifacts(
        session_dir=_session(tmp_path),
        audio_file=tmp_path / "audio.m4a",
        title="Rumble kick",
        transcript_text="Speaker 1: oggi facciamo un rumble kick.",
        meeting_metadata=dict(YOUTUBE),
        omlx_summary=dict(VIDEO_SUMMARY),
    )


def _config(**overrides):
    config = SimpleNamespace(
        user_profile="worker",
        output_language="it",
        summary_model="test",
        transcription_provider="apple",
        notion_title_property="Name",
        notion_project_property="Project",
        summary_template="auto",
    )
    for section in (
        "overview", "summary", "topics", "decisions", "action_items", "open_questions", "risks", "speakers",
        "transcript", "key_concepts", "assignments", "exam_hints", "review_questions", "references",
    ):
        setattr(config, f"notion_include_{section}", True)
    for key, value in overrides.items():
        setattr(config, key, value)
    return config


# Which notes an import becomes


def test_a_video_from_a_link_gets_video_notes_whoever_the_user_is(tmp_path: Path) -> None:
    for profile in ("worker", "student", "both"):
        assert resolve_profile(_config(user_profile=profile), _session(tmp_path), YOUTUBE, "Rumble kick") == VIDEO


def test_a_file_from_the_mac_keeps_todays_rule(tmp_path: Path) -> None:
    from_the_mac = {"origin": "import", "media_kind": "video", "original_path": "/Users/me/Zoom.mp4"}
    assert resolve_profile(_config(), _session(tmp_path), from_the_mac, "Sync settimanale") == WORKER
    assert resolve_profile(_config(user_profile="both"), _session(tmp_path), from_the_mac, "Lezione 3") == STUDENT


def test_the_import_sheets_choice_wins(tmp_path: Path) -> None:
    from_the_mac = {"origin": "import", "original_path": "/Users/me/Tutorial.mov"}
    assert resolve_profile(_config(), _session(tmp_path, "video"), from_the_mac, "Tutorial") == VIDEO
    assert resolve_profile(_config(), _session(tmp_path, "worker"), YOUTUBE, "Riunione caricata su YouTube") == WORKER


# What the model is asked for


def _request_body(tmp_path: Path) -> dict:
    config = SimpleNamespace(
        summary_model="test", summary_response_format_json=False, summary_api_key=None,
        summary_base_url="https://api.example.test/v1", summary_prompt="", summary_timeout_seconds=60,
        user_profile="worker", output_language="it",
    )
    artifacts = MeetingArtifacts(
        session_dir=_session(tmp_path), audio_file=tmp_path / "audio.m4a", title="Rumble kick",
        transcript_text="Speaker 1: oggi facciamo un rumble kick.", meeting_metadata=dict(YOUTUBE),
    )
    response = MagicMock()
    response.read.return_value = json.dumps({"choices": [{"message": {"content": "{}"}}]}).encode()
    response.__enter__.return_value = response
    with patch("meeting_pilot.summarization.omlx_client.urllib.request.urlopen", return_value=response) as urlopen:
        summarize_with_openai_compatible(config, artifacts)
    return json.loads(urlopen.call_args.args[0].data.decode("utf-8"))


def test_videos_ask_the_model_for_steps_and_tools_not_decisions(tmp_path: Path) -> None:
    body = _request_body(tmp_path)
    system, user = body["messages"][0]["content"], json.loads(body["messages"][1]["content"])

    assert "not a meeting" in system
    assert set(user["schema"]) >= {"steps", "key_points", "tools", "tips", "references"}
    assert not set(user["schema"]) & {"decisions", "action_items", "open_questions", "risks"}


def test_built_in_meeting_templates_do_not_shape_a_video(tmp_path: Path) -> None:
    artifacts = _video(tmp_path)
    artifacts.title = "Client demo of the plugin"
    assert "client or prospect" not in summary_guidance(_config(summary_template="client_call"), artifacts)


# What the notes show


def test_the_diary_and_obsidian_show_steps_tools_and_tips(tmp_path: Path) -> None:
    note = _note_content(_config(), _video(tmp_path), "Rumble kick per la techno", "2026-10-22")

    assert "## Passaggi\n\n1. Accorcia la cassa\n2. Aggiungi un delay sincronizzato — 2 a sinistra, 3 a destra, feedback 0, drive 40%" in note
    assert "## Idee chiave\n\n- Il rumble va tenuto mono." in note
    assert "- **Drum Buss** — accordare la cassa con la manopola freq" in note
    assert "- **EQ Eight**\n" in note
    assert "> [!tip] Consigli\n> - Metti il sidechain prima dell'EQ" in note
    assert "## Riferimenti\n\n- Sample pack Driving Techno" in note
    assert 'type: "video"' in note and "  - video" in note
    assert "**Ambito:** Ableton Live" in note
    for meeting_heading in ("## Decisioni", "## Action item", "Domande aperte", "Rischi"):
        assert meeting_heading not in note


def test_a_talk_without_steps_leaves_the_section_out(tmp_path: Path) -> None:
    artifacts = _video(tmp_path)
    artifacts.omlx_summary = {**VIDEO_SUMMARY, "steps": [], "tools": []}
    note = _note_content(_config(), artifacts, "Un talk", "2026-10-22")
    assert "## Passaggi" not in note and "## Strumenti" not in note
    assert "## Idee chiave" in note


def test_notion_numbers_the_steps_and_types_the_page_video(tmp_path: Path) -> None:
    artifacts = _video(tmp_path)
    blocks = _build_blocks(_config(), artifacts)
    text = json.dumps(blocks, ensure_ascii=False)
    properties = _build_properties(_config(), artifacts, "Rumble kick", keep_unsupported=True)

    assert sum(block["type"] == "numbered_list_item" for block in blocks) == 2
    assert "🪜 Passaggi" in text and "🧰 Strumenti e impostazioni" in text and "Consigli" in text
    assert "Decisioni" not in text and not any(block["type"] == "to_do" for block in blocks)
    # The column appears for a video even for someone who only works.
    assert properties["Type"] == {"select": {"name": "Video"}}


def test_apple_notes_list_the_video_sections(tmp_path: Path) -> None:
    body = _note_body(_config(), _video(tmp_path))

    assert "Ambito: Ableton Live" in body
    assert "Passaggi\n- Accorcia la cassa\n- Aggiungi un delay sincronizzato - 2 a sinistra" in body
    assert "Strumenti e impostazioni\n- Drum Buss - accordare la cassa" in body
    assert "Decisioni" not in body
