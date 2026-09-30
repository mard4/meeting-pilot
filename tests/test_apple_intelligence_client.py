from __future__ import annotations

import tempfile
import json
import unittest
from pathlib import Path
from types import SimpleNamespace

from transcribe_to_notion.apple_intelligence_client import (
    AppleIntelligenceUnavailable,
    summarize_with_apple_intelligence,
)
from transcribe_to_notion.artifacts import MeetingArtifacts
from transcribe_to_notion.tag_catalog import add_catalog_value


class AppleIntelligenceClientTests(unittest.TestCase):
    def make_artifacts(self, root: Path) -> MeetingArtifacts:
        return MeetingArtifacts(
            session_dir=root,
            audio_file=root / "audio.m4a",
            title="Riunione",
            transcript_text="Mario approva il piano. Laura prepara il preventivo.",
            meeting_metadata={"participants": ["Mario", "Laura"]},
        )

    def make_helper(self, root: Path, availability: str) -> Path:
        helper = root / "AppleIntelligenceSummarizer"
        helper.write_text(
            f"""#!/bin/sh
if [ "$1" = "--availability" ]; then
  printf '%s\\n' '{{"status":"{availability}","reason":"test reason"}}'
  exit 0
fi
printf '%s\\n' '{{"title":"Riunione","summary":"Sintesi","participants":[],"topics":[],"decisions":[],"action_items":[],"open_questions":[],"risks":[]}}' > "$2"
""",
            encoding="utf-8",
        )
        helper.chmod(0o755)
        return helper

    def test_runs_native_helper_and_reads_structured_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = self.make_helper(root, "available")
            config = SimpleNamespace(
                apple_intelligence_summarizer_cmd=str(helper),
                apple_intelligence_timeout_seconds=30,
                transcription_locale="it-IT",
                summary_prompt="",
            )

            result = summarize_with_apple_intelligence(config, self.make_artifacts(root))

            self.assertEqual(result["title"], "Riunione")
            self.assertEqual(result["participants"], ["Mario", "Laura"])
            self.assertTrue((root / "apple_intelligence_input.json").exists())
            self.assertTrue((root / "apple_intelligence_summarizer.log").exists())

    def test_passes_curated_projects_to_the_on_device_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = self.make_helper(root, "available")
            config = SimpleNamespace(
                apple_intelligence_summarizer_cmd=str(helper),
                apple_intelligence_timeout_seconds=30,
                transcription_locale="it-IT",
                summary_prompt="",
                journal_root=root / "Diary",
            )
            add_catalog_value(config, "project", "Robin")

            summarize_with_apple_intelligence(config, self.make_artifacts(root))

            payload = json.loads((root / "apple_intelligence_input.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["knownProjects"], ["Robin"])

    def test_reports_unavailable_model_before_summarizing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = self.make_helper(root, "unavailable")
            config = SimpleNamespace(
                apple_intelligence_summarizer_cmd=str(helper),
                apple_intelligence_timeout_seconds=30,
                transcription_locale="it-IT",
                summary_prompt="",
            )

            with self.assertRaisesRegex(AppleIntelligenceUnavailable, "test reason"):
                summarize_with_apple_intelligence(config, self.make_artifacts(root))


if __name__ == "__main__":
    unittest.main()
