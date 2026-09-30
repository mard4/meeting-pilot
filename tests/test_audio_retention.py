from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from transcribe_to_notion.config import Config
from transcribe_to_notion.pipeline import process_audio


def _fake_transcription(config: Config, audio_file: Path) -> None:
    (audio_file.parent / "audio.txt").write_text("Ciao a tutti.", encoding="utf-8")


class AudioRetentionTests(unittest.TestCase):
    def run_pipeline(self, keep_audio: bool) -> tuple[Path, Path, Path]:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        env = {
            "MEETINGS_ROOT": str(root),
            "JOURNAL_ROOT": str(root / "Diary"),
            "PUBLISH_TARGETS": "journal",
            "SUMMARY_ENABLED": "false",
            "CALENDAR_METADATA_ENABLED": "false",
            "MOVE_SOURCE_AUDIO": "false",
            "TRANSCRIPTION_PROVIDER": "fluid",
            "KEEP_AUDIO": "true" if keep_audio else "false",
        }
        self.enterContext(patch.dict(os.environ, env))
        config = Config.from_env()
        config.ensure_dirs()
        source = config.inbox_audio_dir / "Meeting Pilot - call.m4a"
        source.write_bytes(b"audio")

        with patch("transcribe_to_notion.pipeline.validate_audio_file"), patch(
            "transcribe_to_notion.pipeline.run_fluid_audio", side_effect=_fake_transcription
        ):
            destination = process_audio(config, source)

        note = next((root / "Diary").rglob("*.md"))
        return source, destination, note

    def test_audio_is_deleted_after_publication_by_default(self) -> None:
        source, destination, note = self.run_pipeline(keep_audio=False)

        self.assertFalse(source.exists())
        self.assertFalse((destination / "audio.m4a").exists())
        self.assertTrue((destination / "audio.txt").exists())
        self.assertNotIn("audio_path", note.read_text(encoding="utf-8"))
        self.assertNotIn("file://", note.read_text(encoding="utf-8"))

    def test_kept_audio_is_linked_at_its_archived_path(self) -> None:
        source, destination, note = self.run_pipeline(keep_audio=True)

        archived = destination / "audio.m4a"
        self.assertTrue(archived.exists())
        self.assertFalse(source.exists(), "the inbox duplicate is removed")
        self.assertIn(f"({archived.as_uri()})", note.read_text(encoding="utf-8"))

    def test_failed_session_keeps_its_audio_for_retry(self) -> None:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.dict(os.environ, {"MEETINGS_ROOT": str(root), "CALENDAR_METADATA_ENABLED": "false"}))
        config = Config.from_env()
        config.ensure_dirs()
        source = config.inbox_audio_dir / "call.m4a"
        source.write_bytes(b"audio")

        with patch("transcribe_to_notion.pipeline.validate_audio_file"), patch(
            "transcribe_to_notion.pipeline.run_fluid_audio", side_effect=RuntimeError("boom")
        ), self.assertRaises(RuntimeError):
            process_audio(config, source)

        failed = next(config.failed_dir.iterdir())
        self.assertTrue((failed / "audio.m4a").exists())


if __name__ == "__main__":
    unittest.main()
