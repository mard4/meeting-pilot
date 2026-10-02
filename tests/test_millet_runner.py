from __future__ import annotations

import subprocess
from pathlib import Path
from types import SimpleNamespace

from meeting_pilot.millet_runner import (
    _fluid_audio_labelled_transcript,
    run_fluid_audio,
    validate_audio_file,
)


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
