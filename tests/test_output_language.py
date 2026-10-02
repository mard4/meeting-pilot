from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from meeting_pilot import language
from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.meeting_chat import _chat_system_prompt, quick_prompt_question
from meeting_pilot.obsidian_publisher import publish_to_obsidian


class ResolveOutputLanguageTests(unittest.TestCase):
    def test_explicit_setting_wins_over_macos(self) -> None:
        with mock.patch.dict(os.environ, {"OUTPUT_LANGUAGE": "it-IT"}), mock.patch.object(
            language, "macos_language", return_value="en"
        ):
            self.assertEqual(language.resolve_output_language(), "it")

    def test_follows_macos_language_when_not_set(self) -> None:
        env = {key: value for key, value in os.environ.items() if key != "OUTPUT_LANGUAGE"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            language, "macos_language", return_value="en"
        ):
            self.assertEqual(language.resolve_output_language(), "en")

    def test_unknown_languages_fall_back_to_english_headings(self) -> None:
        self.assertEqual(language.label("sv", "decisions"), "Decisions")
        self.assertEqual(language.language_name("de"), "German")
        self.assertEqual(language.language_name("sv"), "English")

    def test_app_languages_have_their_own_headings(self) -> None:
        self.assertEqual(language.label("es", "decisions"), "Decisiones")
        self.assertEqual(language.label("fr", "decisions"), "Décisions")
        for code in ("es", "fr", "de", "pt", "nl"):
            self.assertEqual(language.LABELS[code].keys(), language.LABELS["en"].keys())


class EnglishOutputTests(unittest.TestCase):
    def test_obsidian_note_uses_english_headings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            session_dir.mkdir()
            artifacts = MeetingArtifacts(
                session_dir=session_dir,
                audio_file=root / "audio.m4a",
                title="Sprint review",
                transcript_text="Anna: shipping Friday.",
                summary_markdown="",
                omlx_summary={
                    "title": "Sprint review",
                    "summary": "Release moved to Friday.",
                    "decisions": [{"text": "Ship on Friday", "owner": "Anna"}],
                    "risks": ["Docs not ready"],
                },
            )
            config = SimpleNamespace(
                obsidian_vault_path=root / "vault",
                obsidian_folder="Meeting Pilot",
                obsidian_filename_template="{date} - {title}.md",
                summary_model="gpt-test",
                transcription_provider="fluid",
                output_language="en",
            )

            note = Path(publish_to_obsidian(config, artifacts)["path"]).read_text(encoding="utf-8")

            self.assertIn("## Summary", note)
            self.assertIn("## Decisions", note)
            self.assertIn("> [!warning] Risks", note)
            self.assertIn("> [!quote]- Full transcript", note)
            self.assertNotIn("Sintesi", note)
            self.assertNotIn("Decisioni", note)

    def test_chat_prompt_and_quick_prompts_follow_language(self) -> None:
        prompt = _chat_system_prompt("en")

        self.assertIn("Answer in English", prompt)
        self.assertIn("<h3>Summary</h3>", prompt)
        self.assertIn("<h3>Inferences</h3>", prompt)
        self.assertIn("Not found in the selected meetings.", prompt)
        self.assertEqual(
            quick_prompt_question("project_decisions", project="Atlas", language="en"),
            "Which decisions were made for the Atlas project?",
        )


if __name__ == "__main__":
    unittest.main()
