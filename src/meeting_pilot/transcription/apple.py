from __future__ import annotations

import subprocess
import json
import os
from pathlib import Path

from ..config import Config
from ..business_glossary import terms as business_glossary_terms


def run_apple_transcriber(config: Config, audio_file: Path) -> None:
    output_file = audio_file.parent / "apple_on_device_transcript.txt"
    command = [
        config.apple_transcriber_cmd,
        str(audio_file),
        str(output_file),
        config.transcription_locale,
    ]
    glossary_file = os.getenv("BUSINESS_GLOSSARY_FILE", "").strip()
    if glossary_file and business_glossary_terms():
        command.append(glossary_file)
    log_file = audio_file.parent / "apple_transcriber_command.log"
    try:
        with log_file.open("w", encoding="utf-8") as log:
            log.write("$ " + " ".join(command) + "\n\n")
            result = subprocess.run(
                command,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
                text=True,
                timeout=config.apple_transcriber_timeout_seconds,
            )
    except subprocess.TimeoutExpired as exc:
        with log_file.open("a", encoding="utf-8") as log:
            log.write(f"\nTimed out after {config.apple_transcriber_timeout_seconds} seconds.\n")
        raise RuntimeError(f"Apple On-Device transcription timed out after {config.apple_transcriber_timeout_seconds} seconds. See {log_file}") from exc
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
