from __future__ import annotations

import os
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from transcribe_to_notion.watcher import iter_ready_audio_files
from transcribe_to_notion import watcher


class WatcherTests(unittest.TestCase):
    def test_recovery_claim_replaces_an_orphaned_empty_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            session = Path(temporary) / "session"
            session.mkdir()
            (session / ".recovery.lock").touch()

            self.assertTrue(watcher._claim_session_recovery(session))
            self.assertEqual((session / ".recovery.lock").read_text(encoding="utf-8"), str(os.getpid()))

    def test_ready_audio_recovers_an_orphaned_recording_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inbox = Path(temporary) / "inbox"
            inbox.mkdir()
            audio = inbox / "meeting.m4a"
            marker = Path(f"{audio}.recording")
            audio.write_bytes(b"audio")
            marker.touch()
            now = time.time()
            os.utime(marker, (now - 180, now - 180))
            os.utime(audio, (now - 120, now - 120))
            config = SimpleNamespace(
                inbox_audio_dir=inbox,
                processed_sources_file=Path(temporary) / "processed.json",
                file_stable_seconds=10,
            )

            self.assertEqual(iter_ready_audio_files(config), [audio])
            self.assertFalse(marker.exists())

    def test_recent_recording_marker_keeps_audio_out_of_the_queue(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inbox = Path(temporary) / "inbox"
            inbox.mkdir()
            audio = inbox / "meeting.m4a"
            marker = Path(f"{audio}.recording")
            audio.write_bytes(b"audio")
            marker.touch()
            config = SimpleNamespace(
                inbox_audio_dir=inbox,
                processed_sources_file=Path(temporary) / "processed.json",
                file_stable_seconds=10,
            )

            self.assertEqual(iter_ready_audio_files(config), [])
            self.assertTrue(marker.exists())
