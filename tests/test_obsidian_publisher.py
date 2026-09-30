from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from transcribe_to_notion.artifacts import MeetingArtifacts
from transcribe_to_notion.obsidian_publisher import publish_to_obsidian


class ObsidianPublisherTests(unittest.TestCase):
    def test_uses_generated_summary_title_before_calendar_title(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            session_dir.mkdir()
            artifacts = MeetingArtifacts(
                session_dir=session_dir,
                audio_file=root / "audio.m4a",
                title="Fallback",
                transcript_text="Testo.",
                summary_markdown="Sintesi.",
                meeting_metadata={"title": "Calendar | Reply | person@example.com"},
                omlx_summary={"title": "Pianificazione rilascio prodotto"},
            )
            config = SimpleNamespace(
                obsidian_vault_path=root / "vault",
                obsidian_folder="Meeting Pilot",
                obsidian_filename_template="{date} - {title}.md",
                summary_model="gpt-test",
                transcription_provider="fluid",
            )

            receipt = publish_to_obsidian(config, artifacts)

            self.assertIn("Pianificazione rilascio prodotto", Path(receipt["path"]).name)

    def test_writes_markdown_note_and_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            session_dir.mkdir()
            vault = root / "vault"
            artifacts = MeetingArtifacts(
                session_dir=session_dir,
                audio_file=root / "audio.m4a",
                title="Riunione Sprint",
                transcript_text="Mario: ok.\nLaura: confermo.",
                summary_markdown="Sintesi breve.",
                meeting_metadata={
                    "title": "Riunione Sprint",
                    "start": "2026-07-23T10:00:00Z",
                    "participants": ["Mario", "Laura"],
                    "project": "Atlas",
                    "theme": "Pianificazione trimestrale",
                },
                omlx_summary={
                    "summary": "Sintesi lunga.",
                    "topics": ["Pianificazione"],
                    "decisions": ["Si parte lunedi."],
                    "action_items": [{"task": "Preparare il budget"}],
                },
            )
            config = SimpleNamespace(
                obsidian_vault_path=vault,
                obsidian_folder="Meeting Pilot",
                obsidian_filename_template="{date} - {title}.md",
                summary_model="gpt-test",
                transcription_provider="fluid",
            )

            receipt = publish_to_obsidian(config, artifacts)

            note_path = Path(receipt["path"])
            self.assertTrue(note_path.exists())
            self.assertIn("Meeting Pilot", note_path.parts)
            content = note_path.read_text(encoding="utf-8")
            self.assertIn('title: "Riunione Sprint"', content)
            self.assertIn('project: "Atlas"', content)
            self.assertIn('theme: "Pianificazione trimestrale"', content)
            self.assertIn("## Sintesi", content)
            self.assertIn("> [!quote]- Transcript completo", content)
            self.assertIn("> **Mario:** ok.", content)
            self.assertIn("participants:\n  - \"Mario\"\n  - \"Laura\"", content)
            self.assertIn("  - atlas\n  - pianificazione-trimestrale", content)
            self.assertIn("> [!info] giovedì 23 luglio 2026", content)
            self.assertIn("- [ ] Preparare il budget", content)
            self.assertTrue((session_dir / "obsidian_receipt.json").exists())


    def test_action_items_use_obsidian_tasks_syntax_and_empty_sections_are_skipped(self) -> None:
        from transcribe_to_notion.obsidian_publisher import _note_content

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = MeetingArtifacts(
                session_dir=root,
                audio_file=root / "audio.m4a",
                title="Sprint",
                omlx_summary={
                    "summary": "Ok.",
                    "action_items": [
                        {"task": "Build TestFlight", "owner": "Marco", "due_date": "2026-10-03", "status": "open"},
                        {"task": "Testi consenso", "owner": "null", "due_date": "mercoledì", "status": "done"},
                    ],
                    "open_questions": ["Crash su Android?"],
                    "risks": [],
                },
            )
            config = SimpleNamespace(summary_model="m", transcription_provider="fluid", output_language="it")

            content = _note_content(config, artifacts, "Sprint", "2026-09-29")

        self.assertIn("- [ ] Build TestFlight — **Marco** 📅 2026-10-03", content)
        self.assertIn("- [x] Testi consenso · *mercoledì*", content)
        self.assertIn("> [!question] Domande aperte\n> - Crash su Android?", content)
        self.assertNotIn("Rischi", content)


if __name__ == "__main__":
    unittest.main()
