from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import certifi

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.omlx_client import summarize_with_openai_compatible
from meeting_pilot.tag_catalog import add_catalog_value


class OpenAICompatibleClientTests(unittest.TestCase):
    def test_uses_bundled_certificate_authority_for_https(self) -> None:
        config = SimpleNamespace(
            summary_model="gpt-test",
            summary_response_format_json=True,
            summary_api_key="secret",
            summary_base_url="https://api.example.test/v1",
            summary_prompt="",
            summary_timeout_seconds=75,
        )
        artifacts = MeetingArtifacts(
            session_dir=Path("/tmp/test-session"),
            audio_file=Path("/tmp/test-session/audio.m4a"),
            title="Riunione",
            transcript_text="Trascrizione di prova",
        )
        response = MagicMock()
        response.read.return_value = json.dumps(
            {"choices": [{"message": {"content": '{"title":"Riunione"}'}}]}
        ).encode()
        response.__enter__.return_value = response
        ssl_context = object()

        with patch(
            "meeting_pilot.omlx_client.ssl.create_default_context",
            return_value=ssl_context,
        ) as create_context, patch(
            "meeting_pilot.omlx_client.urllib.request.urlopen",
            return_value=response,
        ) as urlopen:
            result = summarize_with_openai_compatible(config, artifacts)

        self.assertEqual(result["title"], "Riunione")
        create_context.assert_called_once_with(cafile=certifi.where())
        self.assertIs(urlopen.call_args.kwargs["context"], ssl_context)
        self.assertEqual(urlopen.call_args.kwargs["timeout"], 75)
        request = urlopen.call_args.args[0]
        payload = json.loads(request.data.decode("utf-8"))
        user_prompt = json.loads(payload["messages"][1]["content"])
        self.assertEqual(
            user_prompt["schema"]["theme"],
            "one concise meeting theme, 2-5 words",
        )

    def test_supplies_curated_projects_to_the_summary_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(
                summary_model="gpt-test",
                summary_response_format_json=True,
                summary_api_key="",
                summary_base_url="https://api.example.test/v1",
                summary_prompt="",
                summary_timeout_seconds=75,
                journal_root=root / "Diary",
            )
            add_catalog_value(config, "project", "Robin")
            response = MagicMock()
            response.read.return_value = json.dumps(
                {"choices": [{"message": {"content": '{"title":"Riunione","tag":"Robin"}'}}]}
            ).encode()
            response.__enter__.return_value = response

            with patch(
                "meeting_pilot.omlx_client.urllib.request.urlopen",
                return_value=response,
            ) as urlopen:
                summarize_with_openai_compatible(
                    config,
                    MeetingArtifacts(
                        session_dir=root / "session",
                        audio_file=root / "audio.m4a",
                        title="Riunione",
                        transcript_text="Parliamo di Robin.",
                    ),
                )

            request = urlopen.call_args.args[0]
            payload = json.loads(request.data.decode("utf-8"))
            user_prompt = json.loads(payload["messages"][1]["content"])
            self.assertEqual(user_prompt["known_projects"], ["Robin"])


if __name__ == "__main__":
    unittest.main()


class OllamaRuntimeTests(unittest.TestCase):
    def _config(self) -> SimpleNamespace:
        return SimpleNamespace(
            summary_model="qwen3:8b",
            summary_provider_mode="local",
            summary_runtime="ollama",
            summary_response_format_json=False,
            summary_api_key=None,
            summary_base_url="http://127.0.0.1:11434/v1",
            summary_prompt="",
            summary_timeout_seconds=900,
        )

    def _summarize(self, transcript: str, content: str) -> tuple[dict, dict, str]:
        artifacts = MeetingArtifacts(
            session_dir=Path("/tmp/test-session"),
            audio_file=Path("/tmp/test-session/audio.m4a"),
            title="Riunione",
            transcript_text=transcript,
        )
        response = MagicMock()
        response.read.return_value = json.dumps({"message": {"content": content}}).encode()
        response.__enter__.return_value = response
        with patch("meeting_pilot.omlx_client.urllib.request.urlopen", return_value=response) as urlopen:
            result = summarize_with_openai_compatible(self._config(), artifacts)
        request = urlopen.call_args.args[0]
        return result, json.loads(request.data.decode("utf-8")), request.full_url

    def test_uses_native_chat_endpoint_with_json_format(self) -> None:
        result, body, url = self._summarize(
            "Trascrizione breve",
            '<think>ragiono</think>\n```json\n{"title":"Riunione"}\n```',
        )

        self.assertEqual(result["title"], "Riunione")
        self.assertEqual(url, "http://127.0.0.1:11434/api/chat")
        self.assertEqual(body["format"], "json")
        self.assertFalse(body["stream"])
        self.assertEqual(body["options"]["num_ctx"], 8192)

    def test_context_window_grows_with_the_transcript(self) -> None:
        _, body, _ = self._summarize("parola " * 20_000, '{"title":"Lunga"}')

        self.assertGreaterEqual(body["options"]["num_ctx"] * 3, len("parola " * 20_000))
        self.assertLessEqual(body["options"]["num_ctx"], 65536)
