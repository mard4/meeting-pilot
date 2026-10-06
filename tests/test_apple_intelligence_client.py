from __future__ import annotations

import tempfile
import json
import unittest
from pathlib import Path
from types import SimpleNamespace

from meeting_pilot.summarization.apple_intelligence_client import (
    AppleIntelligenceUnavailable,
    chat_with_apple_intelligence,
    summarize_with_apple_intelligence,
)
from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.tag_catalog import add_catalog_value


class AppleIntelligenceClientTests(unittest.TestCase):
    def make_artifacts(self, root: Path) -> MeetingArtifacts:
        return MeetingArtifacts(
            session_dir=root,
            audio_file=root / "audio.m4a",
            title="Riunione",
            transcript_text="Mario approva il piano. Laura prepara il preventivo.",
            meeting_metadata={"participants": ["Mario", "Laura"]},
        )

    def make_helper(self, root: Path, availability: str, failure: str = "") -> Path:
        helper = root / "AppleIntelligenceSummarizer"
        run = (
            f"printf '%s\\n' '{failure}' >&2\nexit 2"
            if failure
            else """printf '%s\\n' '{"title":"Riunione","summary":"Sintesi","participants":[],"topics":[],"decisions":[],"action_items":[],"open_questions":[],"risks":[]}' > "$2\""""
        )
        helper.write_text(
            f"""#!/bin/sh
if [ "$1" = "--availability" ]; then
  printf '%s\\n' '{{"status":"{availability}","reason":"test reason"}}'
  exit 0
fi
{run}
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

    def config(self, helper: Path) -> SimpleNamespace:
        return SimpleNamespace(
            apple_intelligence_summarizer_cmd=str(helper),
            apple_intelligence_timeout_seconds=30,
            transcription_locale="it-IT",
            summary_prompt="",
        )

    def test_a_failed_summary_reports_the_helpers_reason(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = self.make_helper(root, "available", failure="Apple Intelligence is busy; retry later")

            with self.assertRaisesRegex(RuntimeError, "busy; retry later") as raised:
                summarize_with_apple_intelligence(self.config(helper), self.make_artifacts(root))

            self.assertNotIsInstance(raised.exception, AppleIntelligenceUnavailable)

    def test_an_unsupported_language_falls_back_without_the_command_line(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reason = "Apple Intelligence unavailable: the transcript language is not supported"
            helper = self.make_helper(root, "available", failure=reason)

            with self.assertRaises(AppleIntelligenceUnavailable) as raised:
                summarize_with_apple_intelligence(self.config(helper), self.make_artifacts(root))

            self.assertEqual(str(raised.exception), reason)

    def test_a_helper_that_cannot_start_counts_as_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = self.make_helper(root, "available")
            helper.chmod(0o644)

            with self.assertRaises(AppleIntelligenceUnavailable):
                summarize_with_apple_intelligence(self.config(helper), self.make_artifacts(root))

    def test_chat_answers_through_the_native_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "AppleIntelligenceSummarizer"
            helper.write_text(
                """#!/bin/sh
[ "$1" = "--chat" ] || exit 9
cp "$2" "$(dirname "$0")/seen.json"
printf '%s' '{"answer":"<section>Beta [1]</section>"}' > "$3"
""",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            answer = chat_with_apple_intelligence(self.config(helper), "istruzioni", "domanda")

            self.assertEqual(answer, "<section>Beta [1]</section>")
            seen = json.loads((root / "seen.json").read_text(encoding="utf-8"))
            self.assertEqual(seen, {"system": "istruzioni", "prompt": "domanda"})

    def test_chat_reports_why_apple_intelligence_failed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "AppleIntelligenceSummarizer"
            helper.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'Apple Intelligence unavailable: Apple Intelligence is not enabled in System Settings' >&2\nexit 2\n",
                encoding="utf-8",
            )
            helper.chmod(0o755)

            with self.assertRaisesRegex(AppleIntelligenceUnavailable, "not enabled in System Settings"):
                chat_with_apple_intelligence(self.config(helper), "istruzioni", "domanda")


if __name__ == "__main__":
    unittest.main()
