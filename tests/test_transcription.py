from __future__ import annotations

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

from meeting_pilot.transcription.apple import run_apple_transcriber
from meeting_pilot.transcription.fluid_audio import (
    _fluid_audio_labelled_transcript,
    run_fluid_audio,
)
from meeting_pilot.transcription.session import validate_audio_file


def test_run_fluid_audio_writes_standard_transcript_artifacts(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio")
    fluid = tmp_path / "runtime/bin/fluidaudiocli"
    fluid.parent.mkdir(parents=True)
    fluid.write_text("#!/bin/zsh\n", encoding="utf-8")
    fluid.chmod(0o755)

    commands: list[list[str]] = []

    def fake_run(command, **_kwargs):
        commands.append(command)
        if command[1] == "transcribe":
            output_path = Path(command[command.index("--output-json") + 1])
            output_path.write_text(
                '{"text":"testo locale da FluidAudio","wordTimings":[]}',
                encoding="utf-8",
            )
            return SimpleNamespace(returncode=0, stdout="Transcription: testo locale da FluidAudio")
        output_path = Path(command[command.index("--output") + 1])
        output_path.write_text('{"segments":[]}', encoding="utf-8")
        return SimpleNamespace(returncode=0, stdout="Diarization completed")

    monkeypatch.setattr(subprocess, "run", fake_run)

    config = SimpleNamespace(fluid_audio_cmd=str(fluid))
    run_fluid_audio(config, audio)

    assert (tmp_path / "fluidaudio_transcript.txt").read_text(encoding="utf-8").strip() == "testo locale da FluidAudio"
    metadata = (tmp_path / "fluidaudio_transcript.json").read_text(encoding="utf-8")
    assert '"provider": "fluid_audio"' in metadata
    assert (tmp_path / "fluidaudio_asr.json").exists()
    assert (tmp_path / "fluidaudio_diarization.json").exists()
    assert [command[1] for command in commands] == ["transcribe", "process"]
    assert commands[1][-2:] == ["--mode", "offline"]


def test_run_fluid_audio_records_a_non_retryable_issue_when_no_speech_is_detected(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio")
    fluid = tmp_path / "runtime/bin/fluidaudiocli"
    fluid.parent.mkdir(parents=True)
    fluid.write_text("#!/bin/zsh\n", encoding="utf-8")
    fluid.chmod(0o755)

    def fake_run(command, **_kwargs):
        if command[1] == "transcribe":
            output_path = Path(command[command.index("--output-json") + 1])
            output_path.write_text('{"text":"","wordTimings":[]}', encoding="utf-8")
        else:
            output_path = Path(command[command.index("--output") + 1])
            output_path.write_text('{"segments":[]}', encoding="utf-8")
        return SimpleNamespace(returncode=0, stdout="")

    monkeypatch.setattr(subprocess, "run", fake_run)

    try:
        run_fluid_audio(SimpleNamespace(fluid_audio_cmd=str(fluid)), audio)
    except RuntimeError as error:
        assert "without producing a transcript" in str(error)
    else:
        raise AssertionError("Expected an empty FluidAudio result to fail")

    assert (tmp_path / "transcription_issue.json").read_text(encoding="utf-8") == (
        '{\n'
        '  "code": "no_speech_detected",\n'
        '  "retryable": false\n'
        '}\n'
    )


def test_fluid_audio_combines_word_timestamps_with_speaker_segments() -> None:
    transcript, segments, speakers = _fluid_audio_labelled_transcript(
        {
            "text": "Ciao a tutti.",
            "wordTimings": [
                {"word": "Ciao", "startTime": 0.0, "endTime": 0.5},
                {"word": "a", "startTime": 0.5, "endTime": 0.7},
                {"word": "tutti.", "startTime": 1.0, "endTime": 1.5},
            ],
        },
        {
            "segments": [
                {"speakerId": "SPEAKER_00", "startTimeSeconds": 0.0, "endTimeSeconds": 0.8},
                {"speakerId": "SPEAKER_01", "startTimeSeconds": 0.8, "endTimeSeconds": 1.6},
            ]
        },
        "Ciao a tutti.",
    )

    assert transcript == "Speaker 1: Ciao a\nSpeaker 2: tutti."
    assert [speaker["label"] for speaker in speakers] == ["Speaker 1", "Speaker 2"]
    assert [segment["speaker"] for segment in segments] == ["Speaker 1", "Speaker 2"]


def test_validate_audio_file_rejects_incomplete_m4a_without_moov_atom(tmp_path: Path) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"\x00\x00\x00\x10ftypM4A \x00\x00\x00\x00mdatbroken")

    try:
        validate_audio_file(audio)
    except RuntimeError as error:
        assert "incompleta" in str(error)
    else:
        raise AssertionError("Expected incomplete M4A validation failure")


def test_validate_audio_file_accepts_m4a_with_moov_atom(tmp_path: Path) -> None:
    audio = tmp_path / "audio.m4a"
    # 16-byte ftyp (major brand + minor version) followed by an empty moov atom.
    audio.write_bytes(b"\x00\x00\x00\x10ftypM4A \x00\x00\x00\x00" + b"\x00\x00\x00\x08moov")

    validate_audio_file(audio)


def _apple_config(tmp_path: Path, **overrides) -> SimpleNamespace:
    values = {
        "apple_transcriber_cmd": str(tmp_path / "AppleTranscriber"),
        "apple_transcriber_timeout_seconds": 60,
        "transcription_locale": "it-IT",
        "fluid_audio_cmd": str(tmp_path / "fluidaudiocli"),
        "apple_diarization": True,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def _fake_apple_and_fluid(words_by_audio: dict[str, list[tuple[str, float, float]]], segments: list[dict], calls: list):
    """Stands in for the Apple helper (text plus a .words.json) and FluidAudio's `process`."""

    def fake_run(command, **_kwargs):
        calls.append(command)
        if command[0] == "/usr/bin/afinfo":
            return SimpleNamespace(returncode=0, stdout="")
        if len(command) > 1 and command[1] == "process":
            Path(command[command.index("--output") + 1]).write_text(
                json.dumps({"segments": segments}), encoding="utf-8"
            )
            return SimpleNamespace(returncode=0, stdout="Diarization completed")
        words = words_by_audio[Path(command[1]).name]
        output = Path(command[2])
        output.write_text(" ".join(word for word, _start, _end in words), encoding="utf-8")
        output.with_suffix(".words.json").write_text(
            json.dumps({"wordTimings": [
                {"word": word, "startTime": start, "endTime": end} for word, start, end in words
            ]}),
            encoding="utf-8",
        )
        return SimpleNamespace(returncode=0, stdout="")

    return fake_run


def test_apple_transcript_gets_speakers_from_fluid_audio_diarization(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio")
    calls: list = []
    monkeypatch.setattr(subprocess, "run", _fake_apple_and_fluid(
        {"audio.m4a": [("Buongiorno", 0.0, 0.5), ("a", 0.5, 0.7), ("tutti.", 0.7, 1.0), ("Ciao!", 2.0, 2.4)]},
        [
            {"speakerId": "A", "startTimeSeconds": 0.0, "endTimeSeconds": 1.5},
            {"speakerId": "B", "startTimeSeconds": 1.5, "endTimeSeconds": 3.0},
        ],
        calls,
    ))

    run_apple_transcriber(_apple_config(tmp_path), audio)

    assert (tmp_path / "apple_on_device_transcript.txt").read_text(encoding="utf-8").strip() == (
        "Speaker 1: Buongiorno a tutti.\nSpeaker 2: Ciao!"
    )
    metadata = json.loads((tmp_path / "apple_on_device_transcript.json").read_text(encoding="utf-8"))
    assert metadata["diarization"] == "fluid_audio"
    assert [segment["speaker"] for segment in metadata["segments"]] == ["Speaker 1", "Speaker 2"]
    # Raw helper output stays out of the session's top level, where .txt files are read as the transcript.
    assert sorted(path.name for path in tmp_path.glob("*.txt")) == ["apple_on_device_transcript.txt"]


def test_apple_transcript_keeps_plain_text_when_diarization_fails(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio")
    calls: list = []
    monkeypatch.setattr(subprocess, "run", _fake_apple_and_fluid(
        {"audio.m4a": [("Buongiorno", 0.0, 0.5), ("a", 0.5, 0.7), ("tutti.", 0.7, 1.0)]},
        [],
        calls,
    ))

    run_apple_transcriber(_apple_config(tmp_path), audio)

    assert (tmp_path / "apple_on_device_transcript.txt").read_text(encoding="utf-8").strip() == "Buongiorno a tutti."
    metadata = json.loads((tmp_path / "apple_on_device_transcript.json").read_text(encoding="utf-8"))
    assert "segments" not in metadata


def test_apple_transcript_skips_diarization_when_disabled(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio")
    calls: list = []
    monkeypatch.setattr(subprocess, "run", _fake_apple_and_fluid(
        {"audio.m4a": [("Buongiorno", 0.0, 0.5)]},
        [{"speakerId": "A", "startTimeSeconds": 0.0, "endTimeSeconds": 1.0}],
        calls,
    ))

    run_apple_transcriber(_apple_config(tmp_path, apple_diarization=False), audio)

    assert not any(len(command) > 1 and command[1] == "process" for command in calls)
    assert (tmp_path / "apple_on_device_transcript.txt").read_text(encoding="utf-8").strip() == "Buongiorno"


def test_apple_transcribes_separate_tracks_and_labels_the_microphone(tmp_path: Path, monkeypatch) -> None:
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"audio")
    tracks = tmp_path / "sidecar" / "tracks"
    tracks.mkdir(parents=True)
    (tracks / "me.m4a").write_bytes(b"me")
    (tracks / "them.m4a").write_bytes(b"them")
    calls: list = []
    monkeypatch.setattr(subprocess, "run", _fake_apple_and_fluid(
        {
            "me.m4a": [("Ciao", 0.0, 0.4), ("Marco.", 0.4, 0.8)],
            "them.m4a": [("Ciao,", 3.0, 3.3), ("benvenuto.", 3.3, 3.8)],
        },
        [{"speakerId": "X", "startTimeSeconds": 2.9, "endTimeSeconds": 4.0}],
        calls,
    ))

    run_apple_transcriber(_apple_config(tmp_path, output_language="it"), audio)

    assert (tmp_path / "apple_on_device_transcript.txt").read_text(encoding="utf-8").strip() == (
        "Io: Ciao Marco.\nSpeaker 1: Ciao, benvenuto."
    )
    metadata = json.loads((tmp_path / "apple_on_device_transcript.json").read_text(encoding="utf-8"))
    assert metadata["tracks"] == "separate"
    # The mixed recording is not transcribed when the tracks succeed.
    assert not any(len(command) > 1 and command[1] == str(audio) for command in calls)
