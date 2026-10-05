from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from meeting_pilot.summarization.apple_intelligence_client import AppleIntelligenceUnavailable
from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.summarization.omlx_client import summarize


class SummaryProviderDispatchTests(unittest.TestCase):
    def test_falls_back_when_apple_intelligence_becomes_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = MeetingArtifacts(
                session_dir=root,
                audio_file=root / "audio.m4a",
                title="Riunione",
                transcript_text="Testo della riunione",
            )
            config = SimpleNamespace(summary_provider_mode="apple")
            fallback = {"title": "Fallback"}

            with patch(
                "meeting_pilot.summarization.omlx_client.summarize_with_apple_intelligence",
                side_effect=AppleIntelligenceUnavailable("not ready"),
            ), patch(
                "meeting_pilot.summarization.omlx_client.summarize_with_openai_compatible",
                return_value=fallback,
            ) as compatible:
                result = summarize(config, artifacts)

            self.assertEqual(result, {"title": "Fallback", "profile": "worker"})
            compatible.assert_called_once_with(config, artifacts, "worker")

    def test_the_fallback_condenses_a_transcript_too_long_for_one_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = MeetingArtifacts(
                session_dir=root,
                audio_file=root / "audio.m4a",
                title="Lezione",
                transcript_text="Oggi vediamo i limiti.\n" * 8_000,
            )
            config = SimpleNamespace(summary_provider_mode="apple")

            with patch(
                "meeting_pilot.summarization.omlx_client.summarize_with_apple_intelligence",
                side_effect=AppleIntelligenceUnavailable("language not supported"),
            ), patch(
                "meeting_pilot.summarization.long_transcripts._complete_text",
                return_value="Limiti.",
            ), patch(
                "meeting_pilot.summarization.omlx_client.summarize_with_openai_compatible",
                return_value={"title": "Limiti"},
            ) as compatible:
                summarize(config, artifacts)

            summarized = compatible.call_args.args[1]
            self.assertTrue(summarized.transcript_text.startswith("[Part 1 of "))

    def test_a_lecture_is_summarized_as_study_notes_and_says_so(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = MeetingArtifacts(
                session_dir=root,
                audio_file=root / "audio.m4a",
                title="Lezione di Analisi 1",
                transcript_text="Oggi vediamo i limiti.",
            )
            config = SimpleNamespace(summary_provider_mode="local", user_profile="both")

            with patch(
                "meeting_pilot.summarization.omlx_client.summarize_with_openai_compatible",
                return_value={"title": "Limiti"},
            ) as compatible:
                result = summarize(config, artifacts)

            self.assertEqual(result["profile"], "student")
            compatible.assert_called_once_with(config, artifacts, "student")


if __name__ == "__main__":
    unittest.main()
