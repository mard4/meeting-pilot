from __future__ import annotations

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

from transcribe_to_notion.artifacts import collect_artifacts
from transcribe_to_notion.millet_runner import _two_track_transcript, create_session, run_fluid_audio
from transcribe_to_notion.pipeline import _discard_audio
from transcribe_to_notion.summary_templates import resolve_template, summary_guidance


def _session_with_sidecar(tmp_path: Path, **files: str) -> Path:
    session = tmp_path / "session"
    for relative, content in files.items():
        path = session / "sidecar" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    session.mkdir(exist_ok=True)
    return session


def test_create_session_moves_the_recording_sidecar_into_the_session(tmp_path: Path) -> None:
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    audio = inbox / "Meeting Pilot - 2026-09-29 10-00-00 - Weekly.m4a"
    audio.write_bytes(b"audio")
    sidecar = inbox / "Meeting Pilot - 2026-09-29 10-00-00 - Weekly.meetingpilot"
    (sidecar / "tracks").mkdir(parents=True)
    (sidecar / "notes.md").write_text("- budget Q4", encoding="utf-8")
    config = SimpleNamespace(processing_dir=tmp_path / "processing", move_source_audio=True, inbox_audio_dir=inbox)

    session_dir, _audio_file = create_session(config, audio)

    assert (session_dir / "sidecar" / "notes.md").read_text(encoding="utf-8") == "- budget Q4"
    assert (session_dir / "sidecar" / "tracks").is_dir()
    assert not sidecar.exists()


def test_collect_artifacts_reads_the_notes_typed_in_the_live_sidebar(tmp_path: Path) -> None:
    session = _session_with_sidecar(tmp_path, **{"notes.md": "  chiedere a Luca il budget  \n"})

    artifacts = collect_artifacts(session, session / "audio.m4a")

    assert artifacts.user_notes == "chiedere a Luca il budget"


def test_template_choice_order_is_sidebar_then_default_then_title(tmp_path: Path) -> None:
    config = SimpleNamespace(summary_template="auto")
    plain = _session_with_sidecar(tmp_path)

    assert resolve_template(config, plain, {"title": "Daily scrum team"}, "").id == "standup"
    assert resolve_template(config, plain, {"title": "Salute e benessere"}, "").id == "general"
    assert resolve_template(SimpleNamespace(summary_template="interview"), plain, {"title": "Daily"}, "").id == "interview"

    chosen = _session_with_sidecar(tmp_path / "chosen", **{"template.json": '{"template": "client_call"}'})
    assert resolve_template(SimpleNamespace(summary_template="interview"), chosen, {"title": "Daily"}, "").id == "client_call"


def test_custom_templates_are_loaded_and_matched_before_builtins(tmp_path: Path, monkeypatch) -> None:
    templates_file = tmp_path / "summary-templates.json"
    templates_file.write_text(
        json.dumps({"templates": [{"id": "board", "name": "Board", "instructions": "Focus on votes.", "keywords": ["daily"]}]}),
        encoding="utf-8",
    )
    monkeypatch.setenv("SUMMARY_TEMPLATES_FILE", str(templates_file))

    template = resolve_template(SimpleNamespace(summary_template="auto"), _session_with_sidecar(tmp_path), {"title": "Daily"}, "")

    assert template.id == "board"
    assert template.instructions == "Focus on votes."


def test_summary_guidance_includes_template_notes_and_who_is_me(tmp_path: Path) -> None:
    session = _session_with_sidecar(tmp_path, **{"template.json": '{"template": "standup"}'})
    artifacts = SimpleNamespace(
        session_dir=session,
        meeting_metadata={},
        title="",
        user_notes="- rilascio venerdì",
        millet_json={"speakers": [{"id": "me", "label": "Io"}, {"id": "0", "label": "Speaker 1"}]},
    )

    guidance = summary_guidance(SimpleNamespace(summary_template="auto"), artifacts)

    assert "Meeting type: Standup." in guidance
    assert "- rilascio venerdì" in guidance
    assert 'labelled "Io" are the user who recorded' in guidance


def test_summary_guidance_is_empty_for_a_general_meeting_without_notes(tmp_path: Path) -> None:
    artifacts = SimpleNamespace(
        session_dir=_session_with_sidecar(tmp_path), meeting_metadata={}, title="Chiacchiere", user_notes="", millet_json=None
    )

    assert summary_guidance(SimpleNamespace(summary_template="auto"), artifacts) == ""


def _words(*items: tuple[str, float]) -> dict:
    return {"wordTimings": [{"word": word, "startTime": start, "endTime": start + 0.3} for word, start in items]}


def test_two_track_transcript_labels_the_microphone_and_drops_its_echo() -> None:
    them = _words(("ciao", 0.0), ("come", 0.4), ("va", 0.8))
    # The mic heard "come va" through the speakers ~0.2s late, then the user answered.
    me = _words(("come", 0.6), ("va", 1.0), ("bene", 2.0), ("grazie", 2.4))
    diarization = {"segments": [{"speakerId": "7", "startTimeSeconds": 0.0, "endTimeSeconds": 1.5}]}

    transcript, segments, speakers = _two_track_transcript(me, them, diarization, me_label="Io")

    assert transcript == "Speaker 1: ciao come va\nIo: bene grazie"
    assert [segment["speaker"] for segment in segments] == ["Speaker 1", "Io"]
    assert speakers == [{"id": "me", "label": "Io"}, {"id": "7", "label": "Speaker 1"}]


def _fake_fluid(tmp_path: Path) -> Path:
    fluid = tmp_path / "runtime/bin/fluidaudiocli"
    fluid.parent.mkdir(parents=True)
    fluid.write_text("#!/bin/zsh\n", encoding="utf-8")
    fluid.chmod(0o755)
    return fluid


def test_run_fluid_audio_transcribes_the_saved_tracks_separately(tmp_path: Path, monkeypatch) -> None:
    session = _session_with_sidecar(tmp_path, **{"tracks/me.m4a": "me", "tracks/them.m4a": "them"})
    audio = session / "audio.m4a"
    audio.write_bytes(b"mixed")
    transcribed: list[str] = []

    def fake_run(command, **_kwargs):
        if command[1] == "transcribe":
            transcribed.append(Path(command[2]).name)
            words = _words(("sì", 3.0)) if command[2].endswith("me.m4a") else _words(("pronto", 0.0))
            Path(command[command.index("--output-json") + 1]).write_text(json.dumps(words), encoding="utf-8")
        else:
            Path(command[command.index("--output") + 1]).write_text('{"segments":[]}', encoding="utf-8")
        return SimpleNamespace(returncode=0, stdout="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    run_fluid_audio(SimpleNamespace(fluid_audio_cmd=str(_fake_fluid(tmp_path))), audio)

    assert transcribed == ["them.m4a", "me.m4a"]
    assert (session / "fluidaudio_transcript.txt").read_text(encoding="utf-8") == "Speaker 1: pronto\nIo: sì\n"
    assert json.loads((session / "fluidaudio_transcript.json").read_text(encoding="utf-8"))["tracks"] == "separate"


def test_run_fluid_audio_falls_back_to_the_mixed_recording_when_a_track_fails(tmp_path: Path, monkeypatch) -> None:
    session = _session_with_sidecar(tmp_path, **{"tracks/me.m4a": "me", "tracks/them.m4a": "them"})
    audio = session / "audio.m4a"
    audio.write_bytes(b"mixed")

    def fake_run(command, **_kwargs):
        if "them.m4a" in command[2]:
            return SimpleNamespace(returncode=1, stdout="decode error")
        if command[1] == "transcribe":
            Path(command[command.index("--output-json") + 1]).write_text(
                '{"text":"testo misto","wordTimings":[]}', encoding="utf-8"
            )
            return SimpleNamespace(returncode=0, stdout="Transcription: testo misto")
        Path(command[command.index("--output") + 1]).write_text('{"segments":[]}', encoding="utf-8")
        return SimpleNamespace(returncode=0, stdout="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    run_fluid_audio(SimpleNamespace(fluid_audio_cmd=str(_fake_fluid(tmp_path))), audio)

    assert (session / "fluidaudio_transcript.txt").read_text(encoding="utf-8").strip() == "testo misto"


def test_discarding_audio_also_removes_the_separate_tracks(tmp_path: Path) -> None:
    session = _session_with_sidecar(tmp_path, **{"tracks/me.m4a": "me", "notes.md": "note"})
    audio = session / "audio.m4a"
    audio.write_bytes(b"mixed")
    artifacts = SimpleNamespace(audio_file=audio, session_dir=session)

    _discard_audio(SimpleNamespace(keep_audio=False, inbox_audio_dir=tmp_path / "inbox"), artifacts)

    assert not (session / "sidecar" / "tracks").exists()
    assert (session / "sidecar" / "notes.md").exists()


def test_published_note_includes_the_notes_typed_during_the_meeting(tmp_path: Path) -> None:
    from transcribe_to_notion.artifacts import MeetingArtifacts
    from transcribe_to_notion.obsidian_publisher import publish_to_obsidian

    session = tmp_path / "session"
    session.mkdir()
    artifacts = MeetingArtifacts(
        session_dir=session,
        audio_file=tmp_path / "audio.m4a",
        title="Vendite",
        omlx_summary={"title": "Aggiornamento vendite", "summary": "Vendite in crescita."},
        user_notes="- presentazione venerdì",
    )
    config = SimpleNamespace(
        obsidian_vault_path=tmp_path / "vault",
        obsidian_folder="Meeting Pilot",
        obsidian_filename_template="{date} - {title}.md",
        summary_model="test",
        transcription_provider="fluid",
    )

    note = Path(publish_to_obsidian(config, artifacts)["path"]).read_text(encoding="utf-8")

    assert "## Le mie note\n- presentazione venerdì" in note
