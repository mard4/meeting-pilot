from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from meeting_pilot.knowledge_base import KnowledgeDocument, index_knowledge_documents
from meeting_pilot.meeting_chat import MeetingChatFilters, answer_meeting_question


class KnowledgeBaseChatTests(unittest.TestCase):
    def test_chat_can_answer_from_mongodb_knowledge_base_with_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index_knowledge_documents(
                root / "kb.sqlite",
                [
                    KnowledgeDocument(
                        source="mongodb",
                        external_id="req-123",
                        title="Isycontrol requisiti beta",
                        text="MongoDB dice che la beta isycontrol richiede audit log e ruoli admin.",
                        url="mongodb://local/meeting_docs/req-123",
                        updated_at="2026-07-28T12:00:00Z",
                    )
                ],
            )
            captured: dict[str, str] = {}

            def provider(system_prompt: str, user_prompt: str) -> str:
                captured["user_prompt"] = user_prompt
                return "Fatti:\n- La beta richiede audit log e ruoli admin. [1]\n\nDecisioni:\n- Non trovato.\n\nInferenze:\n- Nessuna."

            result = answer_meeting_question(
                SimpleNamespace(done_dir=root / "done", journal_root=root / "Diary", knowledge_index_path=root / "kb.sqlite"),
                "Cosa serve per la beta isycontrol?",
                MeetingChatFilters(search_scope="knowledge", external_sources=("mongodb",)),
                provider=provider,
            )

            self.assertIn("audit log", captured["user_prompt"])
            self.assertEqual(result.citations[0].destination, "MongoDB")
            self.assertEqual(result.citations[0].url, "mongodb://local/meeting_docs/req-123")

    def test_search_scope_can_exclude_knowledge_base_or_meetings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            session = done / "20260710-isycontrol"
            session.mkdir(parents=True)
            (session / "meeting_metadata.json").write_text(
                json.dumps({"title": "Meeting isycontrol", "project": "isycontrol"}),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text("Decisione meeting: beta privata a luglio.", encoding="utf-8")
            index_knowledge_documents(
                root / "kb.sqlite",
                [
                    KnowledgeDocument(
                        source="mongodb",
                        external_id="kb-1",
                        title="Documento beta",
                        text="Documento esterno: audit log obbligatorio.",
                        url="mongodb://local/docs/kb-1",
                        updated_at="2026-07-28T12:00:00Z",
                    )
                ],
            )
            config = SimpleNamespace(done_dir=done, journal_root=root / "Diary", knowledge_index_path=root / "kb.sqlite")

            meeting_result = answer_meeting_question(
                config,
                "beta isycontrol",
                MeetingChatFilters(project="isycontrol", search_scope="meetings"),
                provider=lambda _system, _user: "Fatti:\n- Meeting. [1]\n\nDecisioni:\n- Beta privata. [1]\n\nInferenze:\n- Nessuna.",
            )
            knowledge_result = answer_meeting_question(
                config,
                "audit log beta",
                MeetingChatFilters(search_scope="knowledge", external_sources=("mongodb",)),
                provider=lambda _system, _user: "Fatti:\n- KB. [1]\n\nDecisioni:\n- Non trovato.\n\nInferenze:\n- Nessuna.",
            )

            self.assertEqual(meeting_result.citations[0].destination, "Sessione completata")
            self.assertEqual(knowledge_result.citations[0].destination, "MongoDB")

    def test_knowledge_scope_requires_explicit_external_source_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            index_knowledge_documents(
                root / "kb.sqlite",
                [
                    KnowledgeDocument(
                        source="mongodb",
                        external_id="kb-1",
                        title="Documento beta",
                        text="Audit log obbligatorio.",
                        url="mongodb://local/docs/kb-1",
                    )
                ],
            )

            result = answer_meeting_question(
                SimpleNamespace(done_dir=root / "done", journal_root=root / "Diary", knowledge_index_path=root / "kb.sqlite"),
                "audit log",
                MeetingChatFilters(search_scope="knowledge"),
                provider=lambda _system, _user: "Fatti:\n- Audit log. [1]\n\nDecisioni:\n- Non trovato.\n\nInferenze:\n- Nessuna.",
            )

            self.assertEqual(result.answer, "Non trovato nei meeting selezionati.")
            self.assertEqual(result.citations, [])

    def test_cli_indexes_external_jsonl_file_into_local_knowledge_base(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env_path = root / ".env"
            env_path.write_text(
                f"JOURNAL_ROOT={root / 'Diary'}\nDONE_DIR={root / 'done'}\n",
                encoding="utf-8",
            )
            source = root / "mongodb-export.jsonl"
            source.write_text(
                json.dumps(
                    {
                        "id": "doc-1",
                        "title": "MongoDB roadmap",
                        "text": "La roadmap MongoDB cita audit log per isycontrol.",
                        "url": "mongodb://local/docs/doc-1",
                        "updated_at": "2026-07-28T12:00:00Z",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "meeting_pilot.cli",
                    "kb-index-file",
                    "--source",
                    "mongodb",
                    "--input",
                    str(source),
                ],
                cwd=Path(__file__).parents[1],
                env={**os.environ, "PYTHONPATH": "src", "MEETING_PILOT_ENV_FILE": str(env_path)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

            payload = json.loads(completed.stdout)
            self.assertEqual(payload["indexed"], 1)
            self.assertTrue((root / "Diary" / "knowledge.sqlite").exists())


if __name__ == "__main__":
    unittest.main()
