from __future__ import annotations

import json
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from ..config import Config


AUDIO_EXTENSIONS = {".wav", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus", ".mp4"}


def create_session(config: Config, source_audio: Path) -> tuple[Path, Path]:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    slug = _slugify(source_audio.stem)
    session_dir = config.processing_dir / f"{timestamp}-{slug}"
    session_dir.mkdir(parents=True, exist_ok=False)
    audio_file = session_dir / f"audio{source_audio.suffix.lower()}"
    move = config.move_source_audio and _is_relative_to(source_audio.resolve(), config.inbox_audio_dir.resolve())
    if move:
        shutil.move(str(source_audio), str(audio_file))
    else:
        shutil.copy2(str(source_audio), str(audio_file))
    sidecar = sidecar_dir(source_audio)
    if sidecar.is_dir():
        if move:
            shutil.move(str(sidecar), str(session_dir / "sidecar"))
        else:
            shutil.copytree(sidecar, session_dir / "sidecar")
    return session_dir, audio_file


def sidecar_dir(source_audio: Path) -> Path:
    """Per-recording folder the macOS app writes next to the audio: live sidebar notes,
    the chosen summary template, the separate microphone/system-audio tracks, and how it
    was recorded."""
    return source_audio.with_name(source_audio.stem + ".meetingpilot")


def recorded_outside_a_call(source_audio: Path) -> bool:
    """True when the app recorded this with no call detected (sidecar `recording.json`),
    e.g. a lecture from the microphone. Recordings without that file, from older versions
    or external recorders, still count as calls."""
    try:
        payload = json.loads((sidecar_dir(source_audio) / "recording.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return isinstance(payload, dict) and payload.get("call") is False


def audio_duration_seconds(audio_file: Path) -> float | None:
    """Length of a recording as macOS reports it, or None when it cannot be read."""
    try:
        result = subprocess.run(
            ["/usr/bin/afinfo", str(audio_file)],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.search(r"estimated duration:\s*([0-9.]+)\s*sec", result.stdout)
    return float(match.group(1)) if match else None


def timeout_for_audio(base_seconds: int, audio_file: Path) -> int:
    """`base_seconds` suits a meeting; a two-hour lecture or podcast needs at least as
    long as the audio itself on top of it."""
    duration = audio_duration_seconds(audio_file)
    if not duration:
        return base_seconds
    return max(base_seconds, int(duration) + base_seconds)


def validate_audio_file(audio_file: Path) -> None:
    """Reject interrupted MP4/M4A recordings before invoking a transcriber."""
    if not audio_file.is_file() or audio_file.stat().st_size == 0:
        _raise_invalid_audio(audio_file, "Il file audio e' vuoto o non e' disponibile.")
    if audio_file.suffix.lower() not in {".m4a", ".mp4"}:
        return
    if not _mp4_has_moov_atom(audio_file):
        _raise_invalid_audio(
            audio_file,
            "La registrazione e' incompleta e non puo' essere trascritta: "
            "manca l'indice finale dell'audio. Registra di nuovo questa parte della riunione."
        )


def _raise_invalid_audio(audio_file: Path, message: str) -> None:
    try:
        (audio_file.parent / "audio_validation.log").write_text(message + "\n", encoding="utf-8")
    except OSError:
        pass
    raise RuntimeError(message)


def _mp4_has_moov_atom(audio_file: Path) -> bool:
    """Walk MP4 atoms without decoding audio; `moov` is required for playback."""
    try:
        total_size = audio_file.stat().st_size
        with audio_file.open("rb") as handle:
            offset = 0
            while offset + 8 <= total_size:
                handle.seek(offset)
                header = handle.read(8)
                if len(header) != 8:
                    return False
                atom_size = int.from_bytes(header[:4], "big")
                atom_type = header[4:]
                header_size = 8
                if atom_size == 1:
                    extended_size = handle.read(8)
                    if len(extended_size) != 8:
                        return False
                    atom_size = int.from_bytes(extended_size, "big")
                    header_size = 16
                elif atom_size == 0:
                    atom_size = total_size - offset
                if atom_size < header_size or offset + atom_size > total_size:
                    return False
                if atom_type == b"moov":
                    return True
                offset += atom_size
    except OSError:
        return False
    return False


def _slugify(value: str) -> str:
    chars = []
    previous_dash = False
    for char in value.lower():
        if char.isalnum():
            chars.append(char)
            previous_dash = False
        elif not previous_dash:
            chars.append("-")
            previous_dash = True
    return "".join(chars).strip("-") or "meeting"


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True
