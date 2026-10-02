from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from meeting_pilot.platforms.teams.teams_scraper import (
    HELPER_SCRIPTS_DIR,
    capture_teams_runtime_metadata,
    read_saved_teams_runtime_metadata,
)


class TeamsScraperTests(unittest.TestCase):
    def test_checkout_fallback_finds_the_helper_scripts(self) -> None:
        self.assertTrue((HELPER_SCRIPTS_DIR / "teams_window_id.swift").is_file())
        self.assertTrue((HELPER_SCRIPTS_DIR / "ocr_vision.swift").is_file())

    def test_stale_runtime_metadata_is_not_attached_to_a_new_recording(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "teams-runtime.json"
            runtime.write_text(
                json.dumps(
                    {
                        "captured_at": "2026-07-21T10:00:00",
                        "source": "accessibility",
                        "title": "Riunione vecchia",
                        "participants": ["Persona sbagliata"],
                        "confidence": "high",
                    }
                ),
                encoding="utf-8",
            )
            audio = root / "audio.m4a"
            audio.touch()
            recording_time = datetime.fromisoformat("2026-07-22T10:00:00").timestamp()
            os.utime(audio, (recording_time, recording_time))
            config = type("Config", (), {"teams_runtime_metadata_file": runtime})()

            metadata = read_saved_teams_runtime_metadata(config, reference_audio=audio)

            self.assertEqual(metadata, {})

    def test_title_hint_is_used_when_accessibility_has_no_title(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "teams-runtime.json"
            config = type("Config", (), {"meetings_root": Path(temporary)})()

            with patch(
                "meeting_pilot.platforms.teams.teams_scraper._read_accessibility_lines",
                return_value=([], []),
            ):
                metadata = capture_teams_runtime_metadata(
                    config,
                    output,
                    use_ocr=False,
                    title_hint="Call estemporanea",
                )

            self.assertEqual(metadata.title, "Call estemporanea")
            self.assertEqual(json.loads(output.read_text())["title"], "Call estemporanea")

    def test_merge_accumulates_participants_without_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "teams-runtime.json"
            output.write_text(
                json.dumps(
                    {
                        "captured_at": "2026-07-22T10:00:00",
                        "source": "accessibility",
                        "title": "Allineamento",
                        "participants": ["Mario Rossi"],
                        "confidence": "low",
                        "raw_lines": [],
                        "window_titles": [],
                        "screenshot_path": None,
                        "accessibility_error": None,
                        "ocr_error": None,
                    }
                ),
                encoding="utf-8",
            )
            config = type("Config", (), {"meetings_root": Path(temporary)})()

            with patch(
                "meeting_pilot.platforms.teams.teams_scraper._read_accessibility_lines",
                return_value=(
                    ["Partecipanti", "Mario Rossi", "Laura Bianchi", "Chat"],
                    ["Allineamento | Microsoft Teams"],
                ),
            ):
                metadata = capture_teams_runtime_metadata(
                    config,
                    output,
                    use_ocr=False,
                    merge_existing=True,
                )

            self.assertEqual(metadata.title, "Allineamento")
            self.assertEqual(metadata.participants, ["Mario Rossi", "Laura Bianchi"])
            self.assertEqual(metadata.confidence, "medium")


if __name__ == "__main__":
    unittest.main()
