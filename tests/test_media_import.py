from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import pytest

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.config import Config
from meeting_pilot.media_import import import_media_file, import_metadata, imported_media
from meeting_pilot.pipeline import process_audio
from meeting_pilot.publishing.meeting_format import duration_text
from meeting_pilot.summarization import long_transcripts
from meeting_pilot.summarization.apple_intelligence_client import _timeout_for_transcript
from meeting_pilot.summarization.long_transcripts import fit_for_summary, split_transcript
from meeting_pilot.transcription import session as session_module
from meeting_pilot.transcription.session import sidecar_dir, timeout_for_audio

LECTURE = {
    "call": False,
    "origin": "import",
    "media_kind": "video",
    "original_name": "Lezione 3.mp4",
    "original_path": "/Users/studente/Lezioni/Lezione 3.mp4",
    "recorded_at": "2026-09-28T10:00:00",
    "duration_seconds": 5400.0,
}


def _config(tmp_path: Path, monkeypatch, summary: bool = False) -> Config:
    for key, value in {
        "MEETINGS_ROOT": str(tmp_path),
        "JOURNAL_ROOT": str(tmp_path / "Diary"),
        "PUBLISH_TARGETS": "journal",
        "SUMMARY_ENABLED": "true" if summary else "false",
        "CALENDAR_METADATA_ENABLED": "true",
        "MOVE_SOURCE_AUDIO": "true",
        "TRANSCRIPTION_PROVIDER": "fluid",
    }.items():
        monkeypatch.setenv(key, value)
    config = Config.from_env()
    config.ensure_dirs()
    return config


def _import_into_inbox(config: Config, info: dict) -> Path:
    """What the app leaves in the inbox after importing a file."""
    source = config.inbox_audio_dir / "Meeting Pilot - 2026-09-28 10-00-00 - Lezione 3.m4a"
    source.write_bytes(b"audio")
    sidecar_dir(source).mkdir()
    (sidecar_dir(source) / "recording.json").write_text(json.dumps(info), encoding="utf-8")
    return source


def _run(config: Config, source: Path, monkeypatch, summary: dict | None = None) -> Path:
    config.teams_runtime_metadata_file.write_text(
        json.dumps({
            "captured_at": datetime.now().isoformat(),
            "source": "accessibility",
            "title": "Weekly sync",
            "participants": ["Giulia Bianchi"],
            "confidence": "high",
        }),
        encoding="utf-8",
    )

    def transcribe(_config: Config, audio_file: Path) -> None:
        (audio_file.parent / "audio.txt").write_text("Oggi parliamo di termodinamica.", encoding="utf-8")

    def no_calendar(*_args, **_kwargs):
        raise AssertionError("an import must not be matched against the calendar")

    monkeypatch.setattr("meeting_pilot.pipeline.validate_audio_file", lambda _path: None)
    monkeypatch.setattr("meeting_pilot.pipeline.run_fluid_audio", transcribe)
    monkeypatch.setattr("meeting_pilot.pipeline.find_meeting_metadata", no_calendar)
    monkeypatch.setattr("meeting_pilot.pipeline.summarize", lambda _config, _artifacts: dict(summary or {}))
    return process_audio(config, source)


def _journal_note(tmp_path: Path) -> str:
    notes = list((tmp_path / "Diary").rglob("*.md"))
    assert len(notes) == 1
    return notes[0].read_text(encoding="utf-8")


def test_only_imports_are_described_as_imports(tmp_path: Path) -> None:
    audio = tmp_path / "recording.m4a"
    assert imported_media(audio) is None

    sidecar_dir(audio).mkdir()
    (sidecar_dir(audio) / "recording.json").write_text('{"audio_source": "microphone", "call": false}', encoding="utf-8")
    assert imported_media(audio) is None, "a recording made in the app is not an import"

    (sidecar_dir(audio) / "recording.json").write_text(json.dumps(LECTURE), encoding="utf-8")
    assert imported_media(audio)["original_name"] == "Lezione 3.mp4"


def test_import_metadata_keeps_the_recording_date_and_only_a_typed_title() -> None:
    metadata = import_metadata(LECTURE)

    assert metadata["recording_start"] == "2026-09-28T10:00:00"
    assert metadata["duration_seconds"] == 5400.0
    assert metadata["match_found"] is False
    assert "title" not in metadata

    titled = import_metadata({**LECTURE, "title": "  Termodinamica, lezione 3 "})
    assert titled["title"] == "Termodinamica, lezione 3"
    assert titled["title_from_user"] is True


def test_imported_lecture_gets_no_calendar_or_teams_metadata(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    session = _run(config, _import_into_inbox(config, LECTURE), monkeypatch)

    metadata = json.loads((session / "meeting_metadata.json").read_text(encoding="utf-8"))
    assert metadata["origin"] == "import"
    assert metadata["recording_start"] == "2026-09-28T10:00:00"
    assert metadata.get("title") != "Weekly sync"
    assert "participants" not in metadata
    assert (session / "sidecar" / "recording.json").exists()


def test_typed_title_wins_over_the_generated_one(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch, summary=True)
    source = _import_into_inbox(config, {**LECTURE, "title": "Termodinamica 3"})
    session = _run(config, source, monkeypatch, summary={"title": "Introduzione all'entropia", "summary": "..."})

    saved = json.loads((session / "omlx_summary.json").read_text(encoding="utf-8"))
    assert saved["title"] == "Termodinamica 3"
    assert 'title: "Termodinamica 3"' in _journal_note(tmp_path)


def test_without_a_typed_title_the_generated_one_is_kept(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch, summary=True)
    session = _run(config, _import_into_inbox(config, LECTURE), monkeypatch, summary={"title": "Introduzione all'entropia"})

    assert json.loads((session / "omlx_summary.json").read_text(encoding="utf-8"))["title"] == "Introduzione all'entropia"


def test_note_says_the_recording_was_imported_and_where_the_original_is(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    _run(config, _import_into_inbox(config, LECTURE), monkeypatch)

    note = _journal_note(tmp_path)
    assert 'title: "Lezione 3"' in note, "without a summary the file names the note, not the session"
    assert 'source: "File importato"' in note
    assert 'original_path: "/Users/studente/Lezioni/Lezione 3.mp4"' in note
    assert 'duration: "1 h 30 min"' in note
    assert "date: 2026-09-28" in note


def test_meeting_recordings_still_come_from_teams(tmp_path: Path, monkeypatch) -> None:
    config = _config(tmp_path, monkeypatch)
    monkeypatch.setattr(
        "meeting_pilot.pipeline.find_meeting_metadata",
        lambda *_args, **_kwargs: {"recording_start": "2026-09-28T10:00:00", "match_found": False},
    )
    source = config.inbox_audio_dir / "Meeting Pilot - 2026-09-28 10-00-00 - Sync.m4a"
    source.write_bytes(b"audio")

    def transcribe(_config: Config, audio_file: Path) -> None:
        (audio_file.parent / "audio.txt").write_text("Ciao a tutti.", encoding="utf-8")

    monkeypatch.setattr("meeting_pilot.pipeline.validate_audio_file", lambda _path: None)
    monkeypatch.setattr("meeting_pilot.pipeline.run_fluid_audio", transcribe)
    process_audio(config, source)

    assert 'source: "Teams"' in _journal_note(tmp_path)


def test_duration_comes_from_the_imported_file_when_nothing_else_has_it(tmp_path: Path) -> None:
    artifacts = MeetingArtifacts(session_dir=tmp_path, audio_file=tmp_path / "audio.m4a", title="x")
    artifacts.meeting_metadata = {"duration_seconds": 7260.0}

    assert duration_text(artifacts) == "2 h 01 min"


def _capture_process(monkeypatch, tmp_path: Path) -> dict:
    """Records what the command-line import hands to the pipeline, while its temporary
    files still exist."""
    calls: dict = {}

    def process(_config, audio, dry_run=False):
        calls["audio"] = audio
        calls["audio_bytes"] = audio.read_bytes()
        calls["info"] = imported_media(audio)
        slides = sidecar_dir(audio) / "slides" / "slides.pdf"
        calls["slides"] = slides.read_bytes() if slides.exists() else None
        return tmp_path / "done"

    monkeypatch.setattr("meeting_pilot.pipeline.process_audio", process)
    return calls


def test_command_line_import_extracts_a_video_soundtrack(tmp_path: Path, monkeypatch) -> None:
    video = tmp_path / "Lezione 4.mov"
    video.write_bytes(b"video")
    deck = tmp_path / "Lezione 4.pdf"
    deck.write_bytes(b"%PDF slides")
    extracted = []

    def extract(source: Path, output: Path) -> Path:
        extracted.append(source)
        output.write_bytes(b"audio")
        return output

    monkeypatch.setattr("meeting_pilot.media_import.extract_audio", extract)
    monkeypatch.setattr("meeting_pilot.media_import.audio_duration_seconds", lambda _path: 3600.0)
    calls = _capture_process(monkeypatch, tmp_path)

    import_media_file(SimpleNamespace(), video, title="Lezione 4", recorded_at="2026-09-30T14:00", slides=deck)

    assert extracted == [video.resolve()]
    assert calls["audio"].suffix == ".m4a"
    assert calls["info"]["media_kind"] == "video"
    assert calls["info"]["original_path"] == str(video.resolve())
    assert calls["info"]["recorded_at"] == "2026-09-30T14:00"
    assert calls["info"]["title"] == "Lezione 4"
    assert calls["info"]["duration_seconds"] == 3600.0
    assert calls["slides"] == b"%PDF slides"


def test_command_line_import_copies_audio_files_and_leaves_the_original_alone(tmp_path: Path, monkeypatch) -> None:
    podcast = tmp_path / "Episodio 12.mp3"
    podcast.write_bytes(b"audio")
    monkeypatch.setattr("meeting_pilot.media_import.audio_duration_seconds", lambda _path: None)
    calls = _capture_process(monkeypatch, tmp_path)

    import_media_file(SimpleNamespace(), podcast)

    assert calls["audio"] != podcast.resolve() and calls["audio_bytes"] == b"audio"
    assert calls["info"]["media_kind"] == "audio"
    assert "title" not in calls["info"]
    assert calls["info"]["recorded_at"].startswith(datetime.fromtimestamp(podcast.stat().st_mtime).strftime("%Y-%m-%d"))
    assert calls["slides"] is None
    assert podcast.exists() and not sidecar_dir(podcast).exists()


def test_short_transcripts_and_apple_intelligence_are_not_condensed(tmp_path: Path, monkeypatch) -> None:
    def no_request(*_args):
        raise AssertionError("no condensing request expected")

    monkeypatch.setattr(long_transcripts, "_complete_text", no_request)
    artifacts = MeetingArtifacts(session_dir=tmp_path, audio_file=tmp_path / "a.m4a", title="x", transcript_text="breve")
    assert fit_for_summary(SimpleNamespace(summary_provider_mode="local"), artifacts) is artifacts

    artifacts.transcript_text = "parola " * 30_000
    assert fit_for_summary(SimpleNamespace(summary_provider_mode="apple"), artifacts) is artifacts


def test_long_transcript_is_condensed_part_by_part_without_touching_the_published_one(tmp_path: Path, monkeypatch) -> None:
    requests = []

    def condense(_config, _system, user_prompt):
        requests.append(user_prompt)
        return f"note {len(requests)}"

    monkeypatch.setattr(long_transcripts, "_complete_text", condense)
    transcript = "\n".join(f"Speaker 1: frase numero {index} sulla termodinamica." for index in range(5_000))
    artifacts = MeetingArtifacts(session_dir=tmp_path, audio_file=tmp_path / "a.m4a", title="x", transcript_text=transcript)

    fitted = fit_for_summary(SimpleNamespace(summary_provider_mode="local"), artifacts)

    parts = len(split_transcript(transcript, long_transcripts.PART_CHARACTERS))
    assert len(transcript) > long_transcripts.TRANSCRIPT_LIMIT
    assert parts > 1 and len(requests) == parts
    assert requests[0].startswith(f"Transcript part 1 of {parts}:\nSpeaker 1: frase numero 0")
    assert fitted.transcript_text.startswith(f"[Part 1 of {parts}]\nnote 1")
    assert len(fitted.transcript_text) < long_transcripts.TRANSCRIPT_LIMIT
    assert artifacts.transcript_text == transcript
    assert fitted.session_dir == artifacts.session_dir


def test_split_transcript_breaks_between_lines_and_keeps_everything() -> None:
    text = "\n".join(["a" * 30, "b" * 30, "c" * 30, "d" * 100])

    parts = split_transcript(text, 70)

    assert parts[0] == "a" * 30 + "\n" + "b" * 30
    assert parts[1] == "c" * 30
    assert "".join(parts).replace("\n", "") == text.replace("\n", "")
    assert all(len(part) <= 70 for part in parts)


def test_transcription_timeout_grows_with_the_audio(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(session_module, "audio_duration_seconds", lambda _path: 7200.0)
    assert timeout_for_audio(900, tmp_path / "lecture.m4a") == 8100

    monkeypatch.setattr(session_module, "audio_duration_seconds", lambda _path: None)
    assert timeout_for_audio(900, tmp_path / "lecture.m4a") == 900


@pytest.mark.parametrize(("characters", "expected"), [(1_000, 1800), (120_000, 2520)])
def test_apple_intelligence_timeout_grows_with_the_transcript(characters: int, expected: int) -> None:
    assert _timeout_for_transcript(1800, "x" * characters) == expected
