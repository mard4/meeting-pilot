from __future__ import annotations

import subprocess
import json
import os
from pathlib import Path

from ..config import Config
from ..language import config_language, label
from ..platforms.teams.speaker_names import name_speakers_from_teams

# The CLI defaults to streaming diarization, built for live audio in 10-second chunks,
# which merges voices that alternate quickly: on the AMI test meeting IS1009a it found
# the right 4 speakers offline (24% DER) but confused them streaming (59% DER).
DIARIZATION_OPTIONS = ["--mode", "offline"]


def run_fluid_audio(config: Config, audio_file: Path) -> None:
    """Run FluidAudio ASR and diarization, then join words to speaker segments."""
    audio_file.parent.mkdir(parents=True, exist_ok=True)
    issue_file = audio_file.parent / "transcription_issue.json"
    issue_file.unlink(missing_ok=True)
    if _run_fluid_audio_on_tracks(config, audio_file):
        return
    asr_file = audio_file.parent / "fluidaudio_asr.json"
    diarization_file = audio_file.parent / "fluidaudio_diarization.json"
    command = [
        config.fluid_audio_cmd,
        "transcribe",
        str(audio_file),
        "--output-json",
        str(asr_file),
    ]
    diarization_command = [
        config.fluid_audio_cmd,
        "process",
        str(audio_file),
        "--output",
        str(diarization_file),
        *DIARIZATION_OPTIONS,
    ]
    log_file = audio_file.parent / "fluidaudio_command.log"
    output_file = audio_file.parent / "fluidaudio_transcript.txt"
    environment = os.environ.copy()
    fluid_bin = str(Path(config.fluid_audio_cmd).expanduser().parent)
    environment["PATH"] = fluid_bin + os.pathsep + environment.get("PATH", "")
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            text=True,
            env=environment,
        )
    except FileNotFoundError as exc:
        log_file.write_text(
            f"$ {' '.join(command)}\n\nFluidAudio executable not found: {config.fluid_audio_cmd}\n",
            encoding="utf-8",
        )
        raise RuntimeError(
            "FluidAudio non è installato o il suo eseguibile non è disponibile. "
            "Installalo dalle impostazioni di Meeting Pilot, poi riprova."
        ) from exc

    output = result.stdout or ""
    if result.returncode != 0:
        log_file.write_text("$ " + " ".join(command) + "\n\n" + output, encoding="utf-8")
        raise RuntimeError(f"FluidAudio failed with exit code {result.returncode}. See {log_file}")

    try:
        diarization_result = subprocess.run(
            diarization_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            text=True,
            env=environment,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("FluidAudio non dispone del comando di diarizzazione.") from exc

    diarization_output = diarization_result.stdout or ""
    log_file.write_text(
        "$ " + " ".join(command) + "\n\n" + output
        + "\n\n$ " + " ".join(diarization_command) + "\n\n" + diarization_output,
        encoding="utf-8",
    )
    if diarization_result.returncode != 0:
        raise RuntimeError(
            f"FluidAudio non ha completato la separazione speaker. See {log_file}"
        )

    asr_payload = _read_json_file(asr_file)
    diarization_payload = _read_json_file(diarization_file)
    fallback_transcript = _fluid_audio_transcript_from_output(output)
    transcript, segments, speakers = _fluid_audio_labelled_transcript(
        asr_payload,
        diarization_payload,
        fallback_transcript,
    )
    if segments:
        segments, speakers = name_speakers_from_teams(audio_file.parent, segments, speakers)
        transcript = _labelled_transcript_text(segments)
    if not transcript:
        _write_transcription_issue(issue_file, "no_speech_detected", retryable=False)
        raise RuntimeError(f"FluidAudio completed without producing a transcript. See {log_file}")
    output_file.write_text(transcript + "\n", encoding="utf-8")
    (audio_file.parent / "fluidaudio_transcript.json").write_text(
        json.dumps(
            {
                "provider": "fluid_audio",
                "transcript_file": output_file.name,
                "asr_file": asr_file.name,
                "diarization_file": diarization_file.name,
                "segments": segments,
                "speakers": speakers,
                "model_download": "managed_by_fluid_audio",
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def _run_fluid_audio_on_tracks(config: Config, audio_file: Path) -> bool:
    """Transcribe the microphone and system-audio tracks separately when the app saved them.

    The microphone track is the person recording, so their words get their own label
    without relying on diarization; only the system track is split into the other
    participants. Returns False so the caller falls back to the mixed recording when
    the tracks are missing or FluidAudio fails on them.
    """
    tracks = audio_file.parent / "sidecar" / "tracks"
    me_track, them_track = tracks / "me.m4a", tracks / "them.m4a"
    if not (me_track.is_file() and them_track.is_file()):
        return False

    session = audio_file.parent
    me_asr_file = session / "fluidaudio_me_asr.json"
    them_asr_file = session / "fluidaudio_them_asr.json"
    diarization_file = session / "fluidaudio_diarization.json"
    environment = os.environ.copy()
    fluid_bin = str(Path(config.fluid_audio_cmd).expanduser().parent)
    environment["PATH"] = fluid_bin + os.pathsep + environment.get("PATH", "")
    log: list[str] = []

    def run(command: list[str]) -> bool:
        try:
            result = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
                text=True,
                env=environment,
            )
        except FileNotFoundError:
            log.append("$ " + " ".join(command) + "\n\nFluidAudio executable not found")
            return False
        log.append("$ " + " ".join(command) + "\n\n" + (result.stdout or ""))
        return result.returncode == 0

    succeeded = (
        run([config.fluid_audio_cmd, "transcribe", str(them_track), "--output-json", str(them_asr_file)])
        and run([config.fluid_audio_cmd, "process", str(them_track), "--output", str(diarization_file), *DIARIZATION_OPTIONS])
        and run([config.fluid_audio_cmd, "transcribe", str(me_track), "--output-json", str(me_asr_file)])
    )
    (session / "fluidaudio_command.log").write_text("\n\n".join(log), encoding="utf-8")
    if not succeeded:
        print("Separate-track transcription failed; transcribing the mixed recording instead.")
        return False

    transcript, segments, speakers = _two_track_transcript(
        _read_json_file(me_asr_file),
        _read_json_file(them_asr_file),
        _read_json_file(diarization_file),
        me_label=label(config_language(config), "me_speaker"),
    )
    if not transcript:
        return False
    segments, speakers = name_speakers_from_teams(session, segments, speakers)
    transcript = _labelled_transcript_text(segments)
    output_file = session / "fluidaudio_transcript.txt"
    output_file.write_text(transcript + "\n", encoding="utf-8")
    (session / "fluidaudio_transcript.json").write_text(
        json.dumps(
            {
                "provider": "fluid_audio",
                "tracks": "separate",
                "transcript_file": output_file.name,
                "asr_file": them_asr_file.name,
                "me_asr_file": me_asr_file.name,
                "diarization_file": diarization_file.name,
                "segments": segments,
                "speakers": speakers,
                "model_download": "managed_by_fluid_audio",
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    return True


# The microphone also hears the other participants when the user is on speakers
# rather than headphones; a mic word matching a system-audio word this close in time
# is that echo, not the user speaking.
ECHO_WINDOW_SECONDS = 1.5


def _two_track_transcript(
    me_asr: dict,
    them_asr: dict,
    diarization_payload: dict,
    *,
    me_label: str,
) -> tuple[str, list[dict[str, object]], list[dict[str, str]]]:
    them_words = _timed_words(them_asr)
    diarization_segments = [
        segment for segment in diarization_payload.get("segments", []) if isinstance(segment, dict)
    ]
    raw_speaker_ids: list[str] = []
    for segment in diarization_segments:
        speaker_id = str(segment.get("speakerId") or "").strip()
        if speaker_id and speaker_id not in raw_speaker_ids:
            raw_speaker_ids.append(speaker_id)
    labels = {speaker_id: f"Speaker {index + 1}" for index, speaker_id in enumerate(raw_speaker_ids)}

    labelled: list[tuple[str, float, float, str]] = []
    for text, start, end in them_words:
        speaker_id = _speaker_for_time((start + end) / 2, diarization_segments)
        labelled.append((text, start, end, labels.get(speaker_id, "Speaker 1")))

    them_starts: dict[str, list[float]] = {}
    for text, start, _end in them_words:
        them_starts.setdefault(_echo_key(text), []).append(start)
    me_words = [
        (text, start, end, me_label)
        for text, start, end in _timed_words(me_asr)
        if not any(abs(start - other) <= ECHO_WINDOW_SECONDS for other in them_starts.get(_echo_key(text), ()))
    ]
    labelled.extend(me_words)
    labelled.sort(key=lambda word: word[1])

    grouped: list[dict[str, object]] = []
    for text, start, end, speaker in labelled:
        if grouped and grouped[-1]["speaker"] == speaker:
            grouped[-1]["text"] = f"{grouped[-1]['text']} {text}"
            grouped[-1]["end"] = end
        else:
            grouped.append({"speaker": speaker, "start": start, "end": end, "text": text})

    transcript = _labelled_transcript_text(grouped)
    speakers = [{"id": "me", "label": me_label}] if me_words else []
    used = {segment["speaker"] for segment in grouped}
    speakers += [
        {"id": speaker_id, "label": labels[speaker_id]}
        for speaker_id in raw_speaker_ids
        if labels[speaker_id] in used
    ]
    if not raw_speaker_ids and them_words:
        speakers.append({"id": "them", "label": "Speaker 1"})
    return transcript, grouped, speakers


def diarize(config: Config, audio_file: Path, output_file: Path) -> tuple[dict, str]:
    """Speaker turns only, for transcripts written by another recognizer: the
    payload is empty when FluidAudio is missing or fails, with its log either way."""
    command = [config.fluid_audio_cmd, "process", str(audio_file), "--output", str(output_file), *DIARIZATION_OPTIONS]
    environment = os.environ.copy()
    fluid_bin = str(Path(config.fluid_audio_cmd).expanduser().parent)
    environment["PATH"] = fluid_bin + os.pathsep + environment.get("PATH", "")
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            text=True,
            env=environment,
        )
    except (FileNotFoundError, PermissionError):
        return {}, "$ " + " ".join(command) + "\n\nFluidAudio executable not found"
    log = "$ " + " ".join(command) + "\n\n" + (result.stdout or "")
    if result.returncode != 0:
        return {}, log
    return _read_json_file(output_file), log


def _labelled_transcript_text(segments: list[dict[str, object]]) -> str:
    return "\n".join(f"{segment['speaker']}: {segment['text']}" for segment in segments)


def _timed_words(asr_payload: dict) -> list[tuple[str, float, float]]:
    words = []
    for word in asr_payload.get("wordTimings", []):
        if not isinstance(word, dict):
            continue
        text = str(word.get("word") or "").strip()
        start = _as_float(word.get("startTime"))
        end = _as_float(word.get("endTime"))
        if text and start is not None and end is not None:
            words.append((text, start, end))
    return words


def _echo_key(text: str) -> str:
    return "".join(character for character in text.casefold() if character.isalnum())


def _write_transcription_issue(path: Path, code: str, *, retryable: bool) -> None:
    path.write_text(
        json.dumps({"code": code, "retryable": retryable}, indent=2) + "\n",
        encoding="utf-8",
    )


def _read_json_file(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _fluid_audio_labelled_transcript(
    asr_payload: dict,
    diarization_payload: dict,
    fallback_transcript: str,
) -> tuple[str, list[dict[str, object]], list[dict[str, str]]]:
    words = [word for word in asr_payload.get("wordTimings", []) if isinstance(word, dict)]
    diarization_segments = [
        segment for segment in diarization_payload.get("segments", []) if isinstance(segment, dict)
    ]
    if not words or not diarization_segments:
        return fallback_transcript or str(asr_payload.get("text") or "").strip(), [], []

    raw_speaker_ids = []
    for segment in diarization_segments:
        speaker_id = str(segment.get("speakerId") or "").strip()
        if speaker_id and speaker_id not in raw_speaker_ids:
            raw_speaker_ids.append(speaker_id)
    labels = {speaker_id: f"Speaker {index + 1}" for index, speaker_id in enumerate(raw_speaker_ids)}

    labelled_words: list[tuple[str, float, float, str]] = []
    for word in words:
        text = str(word.get("word") or "").strip()
        start = _as_float(word.get("startTime"))
        end = _as_float(word.get("endTime"))
        if not text or start is None or end is None:
            continue
        midpoint = (start + end) / 2
        speaker_id = _speaker_for_time(midpoint, diarization_segments)
        if speaker_id:
            labelled_words.append((text, start, end, labels[speaker_id]))

    if not labelled_words:
        return fallback_transcript or str(asr_payload.get("text") or "").strip(), [], []

    grouped: list[dict[str, object]] = []
    for text, start, end, speaker in labelled_words:
        if grouped and grouped[-1]["speaker"] == speaker:
            grouped[-1]["text"] = f"{grouped[-1]['text']} {text}"
            grouped[-1]["end"] = end
        else:
            grouped.append({"speaker": speaker, "start": start, "end": end, "text": text})

    transcript = _labelled_transcript_text(grouped)
    speakers = [{"id": speaker_id, "label": labels[speaker_id]} for speaker_id in raw_speaker_ids]
    return transcript, grouped, speakers


def _speaker_for_time(midpoint: float, segments: list[dict]) -> str:
    best_speaker = ""
    best_distance = float("inf")
    for segment in segments:
        speaker_id = str(segment.get("speakerId") or "").strip()
        start = _as_float(segment.get("startTimeSeconds"))
        end = _as_float(segment.get("endTimeSeconds"))
        if not speaker_id or start is None or end is None:
            continue
        if start <= midpoint <= end:
            return speaker_id
        distance = min(abs(midpoint - start), abs(midpoint - end))
        if distance < best_distance:
            best_speaker = speaker_id
            best_distance = distance
    return best_speaker


def _as_float(value: object) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _fluid_audio_transcript_from_output(output: str) -> str:
    """Prefer FluidAudio's labelled final result while accepting the plain CLI output."""
    lines = [line.strip() for line in output.splitlines()]
    labelled = [line.split(":", 1)[1].strip() for line in lines if line.lower().startswith("transcription:")]
    if labelled:
        return "\n".join(part for part in labelled if part).strip()
    ignored_prefixes = ("downloading", "loading", "model", "processing", "warning:")
    return "\n".join(
        line for line in lines
        if line and not line.lower().startswith(ignored_prefixes)
    ).strip()
