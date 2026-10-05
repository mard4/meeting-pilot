from __future__ import annotations

import subprocess
import json
import os
from pathlib import Path

from ..config import Config
from ..business_glossary import terms as business_glossary_terms
from ..slides.deck import load_slides, slide_terms
from .session import timeout_for_audio


def run_apple_transcriber(config: Config, audio_file: Path) -> None:
    output_file = audio_file.parent / "apple_on_device_transcript.txt"
    timeout_seconds = timeout_for_audio(config.apple_transcriber_timeout_seconds, audio_file)
    command = [
        config.apple_transcriber_cmd,
        str(audio_file),
        str(output_file),
        config.transcription_locale,
    ]
    glossary_file = _glossary_file(audio_file.parent)
    if glossary_file:
        command.append(glossary_file)
    log_file = audio_file.parent / "apple_transcriber_command.log"
    try:
        with log_file.open("w", encoding="utf-8") as log:
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
    if result.returncode != 0:
        failure_detail = log_file.read_text(encoding="utf-8", errors="replace")
        # Apple Speech can write a complete transcript and still exit non-zero
        # when its first on-device pass falls back to automatic recognition.
        # Trust the artifact if it is usable; otherwise the UI reports a
        # transcription failure even though the transcript is already saved.
        if output_file.is_file() and output_file.stat().st_size > 0:
            transcript = output_file.read_text(encoding="utf-8", errors="replace").strip()
            if transcript:
                (audio_file.parent / "apple_on_device_transcript.json").write_text(
                    json.dumps(
                        {
                            "provider": "apple_on_device",
                            "locale": config.transcription_locale,
                            "transcript_file": output_file.name,
                            "completed_after_fallback": True,
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                    encoding="utf-8",
                )
                return
        raise RuntimeError(f"Apple On-Device transcription failed with exit code {result.returncode}. See {log_file}")
    metadata = {
        "provider": "apple_on_device",
        "locale": config.transcription_locale,
        "transcript_file": output_file.name,
    }
    (audio_file.parent / "apple_on_device_transcript.json").write_text(
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
