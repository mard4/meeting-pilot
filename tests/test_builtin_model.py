from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.summarization import builtin_model
from meeting_pilot.summarization.builtin_model import BuiltinModelUnavailable
from meeting_pilot.summarization.omlx_client import summarize_with_openai_compatible

# Stands in for llama-server: answers /health, records each chat request next to
# itself and replies with fixed meeting notes.
FAKE_SERVER = f"""#!{sys.executable}
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

port = int(sys.argv[sys.argv.index("--port") + 1])
Path(__file__).with_name("args.json").write_text(json.dumps(sys.argv[1:]))

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({{"status": "ok"}})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Path(__file__).with_name("request.json").write_text(json.dumps(request))
        Path(__file__).with_name("auth.json").write_text(json.dumps({{
            "header": self.headers.get("Authorization"), "key": os.environ.get("LLAMA_API_KEY"),
        }}))
        notes = {{"title": "Lancio", "summary": "Sintesi", "participants": [], "topics": [], "decisions": [],
                 "action_items": [], "open_questions": [], "risks": []}}
        self.reply({{"choices": [{{"message": {{"content": json.dumps(notes)}}}}]}})

HTTPServer(("127.0.0.1", port), Handler).serve_forever()
"""


class BuiltinModelTests(unittest.TestCase):
    def make_config(self, root: Path, variant: str = "light", command: str | None = None) -> SimpleNamespace:
        return SimpleNamespace(
            summary_provider_mode="builtin",
            summary_runtime="",
            summary_model=variant,
            summary_base_url="http://127.0.0.1:1/v1",
            summary_api_key="",
            summary_prompt="",
            summary_response_format_json=False,
            summary_timeout_seconds=30,
            summary_template="auto",
            output_language="it",
            user_profile="worker",
            journal_root=root,
            builtin_server_cmd=command or str(root / "llama-server"),
            builtin_models_dir=root / "Models",
        )

    def make_fake_server(self, root: Path) -> Path:
        command = root / "llama-server"
        command.write_text(FAKE_SERVER, encoding="utf-8")
        command.chmod(0o755)
        return command

    def install_model(self, config: SimpleNamespace) -> None:
        path = builtin_model.model_path(config)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"gguf")

    def test_light_model_gets_the_presence_penalty_and_quality_does_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command = self.make_fake_server(root)
            light = builtin_model.server_command(self.make_config(root, "light", str(command)), 8080)
            quality = builtin_model.server_command(self.make_config(root, "quality", str(command)), 8080)

        self.assertIn("Bonsai-4B-Q1_0.gguf", light[light.index("-m") + 1])
        self.assertEqual(light[light.index("--presence-penalty") + 1], "1.5")
        self.assertIn("Qwen3-4B-Q4_K_M.gguf", quality[quality.index("-m") + 1])
        self.assertNotIn("--presence-penalty", quality)
        for args in (light, quality):
            self.assertEqual(args[args.index("-n") + 1], str(builtin_model.MAX_OUTPUT_TOKENS))
            self.assertEqual(args[args.index("--reasoning-budget") + 1], "0")
            self.assertEqual(args[args.index("--host") + 1], "127.0.0.1")

    def test_unknown_variant_falls_back_to_light(self) -> None:
        config = self.make_config(Path("/tmp"), "local-model")

        self.assertEqual(builtin_model.variant_name(config), "light")

    def test_missing_model_asks_to_download_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root, command=str(self.make_fake_server(root)))

            with self.assertRaisesRegex(BuiltinModelUnavailable, "scaricalo"):
                with builtin_model.server(config):
                    pass

    def test_missing_engine_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root, command=str(root / "missing-llama-server"))
            self.install_model(config)

            with self.assertRaisesRegex(BuiltinModelUnavailable, "motore"):
                with builtin_model.server(config):
                    pass

    def test_summary_starts_the_server_asks_for_json_and_stops_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root, command=str(self.make_fake_server(root)))
            self.install_model(config)
            artifacts = MeetingArtifacts(
                session_dir=root,
                audio_file=root / "audio.m4a",
                title="Lancio",
                transcript_text="Giulia: il lancio si sposta al 17 novembre.",
            )

            result = summarize_with_openai_compatible(config, artifacts, "worker")
            request = json.loads((root / "request.json").read_text())
            server_pid = builtin_model._SERVER._process.pid
            builtin_model._SERVER.shutdown()

            self.assertEqual(result["title"], "Lancio")
            self.assertEqual(request["response_format"], {"type": "json_object"})
            with self.assertRaises(ProcessLookupError):
                os.kill(server_pid, 0)

    def test_server_requires_a_key_only_this_process_knows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root, command=str(self.make_fake_server(root)))
            self.install_model(config)
            artifacts = MeetingArtifacts(
                session_dir=root, audio_file=root / "audio.m4a", title="Lancio", transcript_text="Giulia: ok."
            )

            summarize_with_openai_compatible(config, artifacts, "worker")
            auth = json.loads((root / "auth.json").read_text())
            args = json.loads((root / "args.json").read_text())
            builtin_model._SERVER.shutdown()

            self.assertTrue(auth["key"])
            self.assertEqual(auth["header"], f"Bearer {auth['key']}")
            # On the command line `ps` would show it to every account.
            self.assertNotIn(auth["key"], args)
            self.assertIn("--no-slots", args)

    def test_server_stays_up_while_in_use_and_is_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = self.make_config(root, command=str(self.make_fake_server(root)))
            self.install_model(config)
            try:
                with builtin_model.server(config) as first:
                    pass
                # Released, but within the idle window: the same server answers.
                with builtin_model.server(config) as second:
                    self.assertEqual(first, second)
            finally:
                builtin_model._SERVER.shutdown()

    def test_smaller_context_on_8_gb_macs_shrinks_the_transcript_limit(self) -> None:
        with mock.patch.object(builtin_model, "context_tokens", return_value=16384):
            small = builtin_model.transcript_limit()
        with mock.patch.object(builtin_model, "context_tokens", return_value=32768):
            large = builtin_model.transcript_limit()

        self.assertLess(small, large)
        self.assertGreater(small, 20_000)


if __name__ == "__main__":
    unittest.main()
