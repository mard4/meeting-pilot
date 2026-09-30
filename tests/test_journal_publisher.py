from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from transcribe_to_notion.artifacts import MeetingArtifacts
from transcribe_to_notion.journal_publisher import publish_to_journal


class JournalPublisherTests(unittest.TestCase):
    def test_writes_portable_page_and_rebuildable_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "session"
            session.mkdir()
            journal = root / "Diary"
            artifacts = MeetingArtifacts(
                session_dir=session,
                audio_file=root / "audio.m4a",
                title="Riunione Sprint",
                summary_markdown="Sintesi breve.",
                meeting_metadata={
                    "title": "Riunione Sprint",
                    "start": "2026-07-24T10:00:00Z",
                    "project": "Atlas",
                    "theme": "Pianificazione trimestrale",
                },
                omlx_summary={"summary": "Sintesi lunga."},
            )
            config = SimpleNamespace(
                journal_root=journal,
                summary_model="apple",
                transcription_provider="apple",
            )

            receipt = publish_to_journal(config, artifacts)

            page = Path(receipt["path"])
            self.assertTrue(page.exists())
            self.assertEqual(page.parent, journal / "2026" / "07")
            self.assertIn("## Sintesi", page.read_text(encoding="utf-8"))
            self.assertIn('project: "Atlas"', page.read_text(encoding="utf-8"))
            self.assertIn('theme: "Pianificazione trimestrale"', page.read_text(encoding="utf-8"))
            self.assertNotIn("[!info]", page.read_text(encoding="utf-8"), "the app header already shows these")
            self.assertTrue((session / "journal_receipt.json").exists())
            with sqlite3.connect(journal / "index.sqlite") as database:
                self.assertEqual(database.execute("SELECT title FROM entries").fetchone()[0], "Riunione Sprint")


if __name__ == "__main__":
    unittest.main()
