from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from transcribe_to_notion.apple_intelligence_client import AppleIntelligenceUnavailable
from transcribe_to_notion.artifacts import MeetingArtifacts
from transcribe_to_notion.omlx_client import summarize


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
                "transcribe_to_notion.omlx_client.summarize_with_apple_intelligence",
                side_effect=AppleIntelligenceUnavailable("not ready"),
            ), patch(
                "transcribe_to_notion.omlx_client.summarize_with_openai_compatible",
                return_value=fallback,
            ) as compatible:
                result = summarize(config, artifacts)

            self.assertEqual(result, fallback)
            compatible.assert_called_once_with(config, artifacts)


if __name__ == "__main__":
    unittest.main()
