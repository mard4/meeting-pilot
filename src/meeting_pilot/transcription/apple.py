from __future__ import annotations

import subprocess
import json
import os
from pathlib import Path

from ..config import Config
from ..business_glossary import terms as business_glossary_terms
from ..language import config_language, label
from ..platforms.teams.speaker_names import name_speakers_from_teams
from ..slides.deck import load_slides, slide_terms
from .fluid_audio import (
    _fluid_audio_labelled_transcript,
    _labelled_transcript_text,
    _read_json_file,
    _two_track_transcript,
    diarize,
)
from .session import timeout_for_audio


def run_apple_transcriber(config: Config, audio_file: Path) -> None:
    """Transcribe with Apple's on-device recognizer, then label speakers with
    FluidAudio's diarization when it is available. Without diarization, or when it
    fails, the transcript is Apple's plain text as before."""
    session = audio_file.parent
    log_file = session / "apple_transcriber_command.log"
    log_file.write_text("", encoding="utf-8")
    diarization_enabled = getattr(config, "apple_diarization", True)
    if diarization_enabled and _run_apple_on_tracks(config, audio_file, log_file):
        return

    # The raw output lives in a subfolder: the session's top-level .txt files are read as its transcript.
    transcript, words, completed_after_fallback = _transcribe(
        config, session, audio_file, session / "apple_transcriber" / "mixed.txt", log_file
    )
    segments: list[dict[str, object]] = []
    speakers: list[dict[str, str]] = []
    if diarization_enabled and words.get("wordTimings"):
        diarization = _diarize(config, session, audio_file, log_file)
        _, segments, speakers = _fluid_audio_labelled_transcript(words, diarization, transcript)
        if segments:
            segments, speakers = name_speakers_from_teams(session, segments, speakers)
            transcript = _labelled_transcript_text(segments)
    _write_transcript(
        config,
        session,
        transcript,
        segments,
        speakers,
        completed_after_fallback=completed_after_fallback,
    )


def _run_apple_on_tracks(config: Config, audio_file: Path, log_file: Path) -> bool:
    """Transcribe the microphone and system-audio tracks separately when the app saved
    them, as FluidAudio does: the microphone is the person recording, and only the
    system track is split into the other participants. Returns False so the caller
    transcribes the mixed recording when the tracks are missing or a step fails."""
    session = audio_file.parent
    tracks = session / "sidecar" / "tracks"
    me_track, them_track = tracks / "me.m4a", tracks / "them.m4a"
    if not (me_track.is_file() and them_track.is_file()):
        return False
    work = session / "apple_transcriber"
    try:
        _, them_words, _ = _transcribe(config, session, them_track, work / "them.txt", log_file)
        _, me_words, _ = _transcribe(config, session, me_track, work / "me.txt", log_file)
    except RuntimeError as exc:
        print(f"Separate-track transcription failed ({exc}); transcribing the mixed recording instead.")
        return False
    if not (them_words.get("wordTimings") or me_words.get("wordTimings")):
        return False
    diarization = _diarize(config, session, them_track, log_file)
    if not diarization:
        print("Speaker separation failed; transcribing the mixed recording instead.")
        return False
    transcript, segments, speakers = _two_track_transcript(
        me_words,
        them_words,
        diarization,
        me_label=label(config_language(config), "me_speaker"),
    )
    if not transcript:
        return False
    segments, speakers = name_speakers_from_teams(session, segments, speakers)
    _write_transcript(config, session, _labelled_transcript_text(segments), segments, speakers, tracks="separate")
    return True


def _transcribe(
    config: Config, session: Path, audio_file: Path, output_file: Path, log_file: Path
) -> tuple[str, dict, bool]:
    """Apple's transcript of one file, its word timings when the recognizer reports
    them, and whether it only completed after a fallback."""
    output_file.parent.mkdir(parents=True, exist_ok=True)
    words_file = output_file.with_suffix(".words.json")
    output_file.unlink(missing_ok=True)
    words_file.unlink(missing_ok=True)
    timeout_seconds = timeout_for_audio(config.apple_transcriber_timeout_seconds, audio_file)
    command = [
        config.apple_transcriber_cmd,
        str(audio_file),
        str(output_file),
        config.transcription_locale,
    ]
    glossary_file = _glossary_file(session)
    if glossary_file:
        command.append(glossary_file)
    try:
        with log_file.open("a", encoding="utf-8") as log:
            log.write("$ " + " ".join(command) + "\n\n")
            # Flushed first: the helper writes to the same file, so a buffered header would land after its output.
            log.flush()
            result = subprocess.run(
                command,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
                text=True,
                timeout=timeout_seconds,
            )
    except subprocess.TimeoutExpired as exc:
        with log_file.open("a", encoding="utf-8") as log:
            log.write(f"\nTimed out after {timeout_seconds} seconds.\n")
        raise RuntimeError(f"Apple On-Device transcription timed out after {timeout_seconds} seconds. See {log_file}") from exc
    transcript = (
        output_file.read_text(encoding="utf-8", errors="replace").strip() if output_file.is_file() else ""
    )
    if result.returncode != 0:
        # Apple Speech can write a complete transcript and still exit non-zero
        # when its first on-device pass falls back to automatic recognition.
        # Trust the artifact if it is usable; otherwise the UI reports a
        # transcription failure even though the transcript is already saved.
        if transcript:
            return transcript, _read_json_file(words_file), True
        raise RuntimeError(f"Apple On-Device transcription failed with exit code {result.returncode}. See {log_file}")
    return transcript, _read_json_file(words_file), False


def _diarize(config: Config, session: Path, audio_file: Path, log_file: Path) -> dict:
    payload, log = diarize(config, audio_file, session / "fluidaudio_diarization.json")
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write("\n" + log + "\n")
    return payload if payload.get("segments") else {}


def _write_transcript(
    config: Config,
    session: Path,
    transcript: str,
    segments: list[dict[str, object]],
    speakers: list[dict[str, str]],
    **details: object,
) -> None:
    output_file = session / "apple_on_device_transcript.txt"
    output_file.write_text(transcript + "\n", encoding="utf-8")
    metadata: dict[str, object] = {
        "provider": "apple_on_device",
        "locale": config.transcription_locale,
        "transcript_file": output_file.name,
    }
    if segments:
        metadata["diarization"] = "fluid_audio"
        metadata["segments"] = segments
        metadata["speakers"] = speakers
    metadata.update({key: value for key, value in details.items() if value})
    (session / "apple_on_device_transcript.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _glossary_file(session_dir: Path) -> str | None:
    """The business glossary, plus names and terms from the session's slides when it has
    any: both are spellings the recognizer should favour."""
    business_file = os.getenv("BUSINESS_GLOSSARY_FILE", "").strip()
    business = business_glossary_terms()
    from_slides = slide_terms(load_slides(session_dir))
    if not from_slides:
        return business_file if business_file and business else None
    # One term per line; commas separate misheard variants in the glossary format.
    terms = dict.fromkeys(term.replace(",", " ").strip() for term in (*business, *from_slides))
    path = session_dir / "transcription_terms.txt"
    path.write_text("\n".join(term for term in terms if term) + "\n", encoding="utf-8")
    return str(path)
