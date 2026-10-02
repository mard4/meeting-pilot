from __future__ import annotations

import json
import sqlite3
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from meeting_pilot.artifacts import MeetingArtifacts, write_journal_receipt, write_omlx_summary
from meeting_pilot.publishing.journal_publisher import publish_to_journal
from meeting_pilot.chat.meeting_chat import (
    MeetingChatCitation,
    MeetingChatFilters,
    answer_meeting_question,
    available_chat_filter_values,
    available_chat_projects,
    quick_prompt_question,
    save_meeting_chat_result,
)
from meeting_pilot.tag_catalog import add_catalog_value, discard_unconfirmed_initial_imports, import_catalog_from_sources


class MeetingChatTests(unittest.TestCase):
    def test_filter_values_and_multi_selection_cover_projects_and_themes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            for identifier, project, theme, transcript in (
                ("20260710-alpha", "Alpha", "Rilascio", "Decisione: pubblicare Alpha."),
                ("20260711-beta", "Beta", "Sicurezza", "Decisione: verificare Beta."),
            ):
                session = done / identifier
                session.mkdir(parents=True)
                (session / "meeting_metadata.json").write_text(
                    json.dumps({"title": identifier, "project": project, "theme": theme}),
                    encoding="utf-8",
                )
                (session / "transcript.txt").write_text(transcript, encoding="utf-8")

            config = SimpleNamespace(done_dir=done, journal_root=root / "Diary")
            add_catalog_value(config, "project", "Alpha")
            add_catalog_value(config, "project", "Beta")
            add_catalog_value(config, "topic", "Rilascio")
            add_catalog_value(config, "topic", "Sicurezza")
            values = available_chat_filter_values(config)
            passages = answer_meeting_question(
                config,
                "Quali decisioni sono state prese?",
                MeetingChatFilters(projects=("Alpha", "Beta"), themes=("Sicurezza",)),
                provider=lambda _system, _prompt: "<section><h3>Fatti</h3><p>Beta verificata. [1]</p><h3>Decisioni</h3><p>Verifica Beta. [1]</p><h3>Inferenze</h3><p>Nessuna.</p></section>",
            )

            self.assertEqual(values["projects"], ["Alpha", "Beta"])
            self.assertEqual(values["themes"], ["Rilascio", "Sicurezza"])
            self.assertEqual([citation.title for citation in passages.citations], ["20260711-beta"])

    def test_selected_taxonomy_filters_keep_matching_meeting_context_for_generic_questions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "done" / "20260805-robin"
            session.mkdir(parents=True)
            (session / "meeting_metadata.json").write_text(
                json.dumps({"title": "Guardrails", "project": "robin", "theme": "Guardrails e streaming"}),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text(
                "Il team ha concordato la prossima integrazione dei controlli di sicurezza.",
                encoding="utf-8",
            )

            result = answer_meeting_question(
                SimpleNamespace(done_dir=root / "done", journal_root=root / "Diary"),
                "Cosa è stato deciso?",
                MeetingChatFilters(projects=("robin",), themes=("Guardrails e streaming",)),
                provider=lambda _system, _prompt: "<section><h3>Fatti</h3><ul><li>Integrazione prevista. [1]</li></ul><h3>Decisioni</h3><ul><li>Controlli di sicurezza. [1]</li></ul><h3>Inferenze</h3><ul><li>Nessuna.</li></ul></section>",
            )

            self.assertEqual([citation.title for citation in result.citations], ["Guardrails"])

    def test_available_chat_projects_uses_only_the_curated_local_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            session = done / "20260710-isycontrol"
            session.mkdir(parents=True)
            (session / "meeting_project.json").write_text(
                json.dumps({"project": "isycontrol"}),
                encoding="utf-8",
            )
            config = SimpleNamespace(done_dir=done, journal_root=root / "Diary")
            add_catalog_value(config, "project", "Curated")

            projects = available_chat_projects(config)

            self.assertEqual(projects, ["Curated"])

    def test_catalog_is_case_insensitive_and_preserves_the_confirmed_label(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(journal_root=root / "Diary")

            add_catalog_value(config, "project", "Buddy")
            add_catalog_value(config, "project", "buddy")
            add_catalog_value(config, "topic", "Release")

            self.assertEqual(available_chat_filter_values(config), {"projects": ["Buddy"], "themes": ["Release"]})

    def test_migration_removes_only_values_from_the_old_unconfirmed_notion_import(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(journal_root=root / "Diary")
            path = config.journal_root / "tag-catalog.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({
                "projects": [
                    {"name": "Stale", "sources": ["notion_initial_import"]},
                    {"name": "Approved", "sources": ["notion_initial_import", "manual"]},
                ],
                "topics": [],
            }), encoding="utf-8")

            values = discard_unconfirmed_initial_imports(config)

            self.assertEqual(values, {"projects": ["Approved"], "topics": []})

    def test_explicit_source_import_collects_completed_sessions_and_obsidian_notes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            session = done / "20260805-robin"
            session.mkdir(parents=True)
            (session / "meeting_project.json").write_text(json.dumps({"project": "Robin"}), encoding="utf-8")
            (session / "meeting_theme.json").write_text(json.dumps({"theme": "Guardrails"}), encoding="utf-8")
            vault = root / "vault" / "Meeting Pilot"
            vault.mkdir(parents=True)
            (vault / "note.md").write_text("---\nproject: Buddy\ntheme: Accessi\n---\n", encoding="utf-8")
            config = SimpleNamespace(
                journal_root=root / "Diary",
                done_dir=done,
                obsidian_vault_path=root / "vault",
                obsidian_folder="Meeting Pilot",
                notion_token="",
                notion_database_id="",
            )

            values = import_catalog_from_sources(config, ("completed", "obsidian"))

            self.assertEqual(values["projects"], ["Buddy", "Robin"])
            self.assertEqual(values["topics"], ["Accessi", "Guardrails"])

    def test_obsidian_only_import_does_not_add_tags_from_completed_sessions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            session = done / "20260805-robin"
            session.mkdir(parents=True)
            (session / "meeting_project.json").write_text(json.dumps({"project": "Robin"}), encoding="utf-8")
            (session / "meeting_theme.json").write_text(json.dumps({"theme": "Guardrails"}), encoding="utf-8")
            vault = root / "vault" / "Meeting Pilot"
            vault.mkdir(parents=True)
            (vault / "note.md").write_text("---\nproject: Buddy\ntheme: Accessi\n---\n", encoding="utf-8")
            config = SimpleNamespace(
                journal_root=root / "Diary",
                done_dir=done,
                obsidian_vault_path=root / "vault",
                obsidian_folder="Meeting Pilot",
            )

            values = import_catalog_from_sources(config, ("obsidian",))

            self.assertEqual(values["projects"], ["Buddy"])
            self.assertEqual(values["topics"], ["Accessi"])

    def test_notion_import_removes_only_stale_values_previously_imported_by_meeting_pilot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(journal_root=root / "Diary", notion_token="token", notion_database_id="database")
            catalog = config.journal_root / "tag-catalog.json"
            catalog.parent.mkdir(parents=True)
            catalog.write_text(json.dumps({
                "projects": [
                    {"name": "Manual", "sources": ["manual"]},
                    {"name": "Stale", "sources": ["sources:completed,journal,knowledge,notion,obsidian"]},
                    {"name": "Old Notion", "sources": ["notion_confirmed_import"]},
                ],
                "topics": [{"name": "Old topic", "sources": ["notion_confirmed_import"]}],
            }), encoding="utf-8")

            with patch("meeting_pilot.tag_catalog.bootstrap_catalog_from_notion", return_value={
                "projects": ["Current Notion"],
                "topics": ["Current topic"],
            }):
                values = import_catalog_from_sources(config, ("notion",))

            self.assertEqual(values["projects"], ["Current Notion", "Manual"])
            self.assertEqual(values["topics"], ["Current topic"])

    def test_source_sync_removes_values_previously_imported_from_deselected_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(journal_root=root / "Diary")
            catalog = config.journal_root / "tag-catalog.json"
            catalog.parent.mkdir(parents=True)
            catalog.write_text(json.dumps({
                "projects": [
                    {"name": "Notion only", "sources": ["import:notion"]},
                    {"name": "Obsidian stale", "sources": ["import:obsidian"]},
                    {"name": "Manual", "sources": ["manual"]},
                ],
                "topics": [{"name": "Old topic", "sources": ["import:notion"]}],
            }), encoding="utf-8")

            with patch("meeting_pilot.tag_catalog._obsidian_candidates", return_value={
                "projects": ["Obsidian current"],
                "topics": ["Obsidian topic"],
            }):
                values = import_catalog_from_sources(config, ("obsidian",))

            self.assertEqual(values["projects"], ["Manual", "Obsidian current"])
            self.assertEqual(values["topics"], ["Obsidian topic"])

    def test_notion_catalog_requests_use_the_bundled_certificate_store(self) -> None:
        source = (Path(__file__).parents[1] / "src/meeting_pilot/tag_catalog.py").read_text()

        self.assertIn("import certifi", source)
        self.assertIn("ssl.create_default_context(cafile=certifi.where())", source)

    def test_notion_import_reads_tags_assigned_to_pages_not_historical_property_options(self) -> None:
        from meeting_pilot.tag_catalog import bootstrap_catalog_from_notion

        config = SimpleNamespace(
            notion_token="token",
            notion_database_id="database",
            notion_project_property="Project",
        )
        responses = [
            {"data_sources": [{"id": "source-id"}]},
            {"properties": {
                "Project": {"select": {"options": [{"name": "Historical project"}]}},
                "Tema": {"multi_select": {"options": [{"name": "Historical topic"}]}},
            }},
            {"results": [{"properties": {
                "Project": {"type": "select", "select": {"name": "Current project"}},
                "Tema": {"type": "multi_select", "multi_select": [{"name": "Current topic"}]},
            }}], "has_more": False, "next_cursor": None},
        ]

        with patch("meeting_pilot.tag_catalog._notion_request", side_effect=responses) as request:
            values = bootstrap_catalog_from_notion(config)

        self.assertEqual(values, {"projects": ["Current project"], "topics": ["Current topic"]})
        self.assertEqual(request.call_args_list[-1].args[1], "/v1/data_sources/source-id/query")
        self.assertEqual(request.call_args_list[-1].kwargs["method"], "POST")

    def test_cli_lists_projects_from_meetings_and_knowledge_base(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "meetings" / "done"
            session = done / "20260710-isycontrol"
            session.mkdir(parents=True)
            (session / "meeting_metadata.json").write_text(
                json.dumps({"project": "isycontrol"}),
                encoding="utf-8",
            )
            journal = root / "Diary"
            add_catalog_value(SimpleNamespace(journal_root=journal), "project", "Curated")
            env_path = root / ".env"
            env_path.write_text(
                f"DONE_DIR={done}\nJOURNAL_ROOT={journal}\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [sys.executable, "-m", "meeting_pilot.cli", "chat-projects"],
                cwd=Path(__file__).parents[1],
                env={**os.environ, "PYTHONPATH": "src", "MEETING_PILOT_ENV_FILE": str(env_path)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

            self.assertEqual(json.loads(completed.stdout), {"projects": ["Curated"]})

    def test_journal_index_keeps_project_theme_and_destination_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "session"
            session.mkdir()
            journal = root / "Diary"
            artifacts = MeetingArtifacts(
                session_dir=session,
                audio_file=root / "audio.m4a",
                title="Riunione Isycontrol",
                meeting_metadata={
                    "title": "Riunione Isycontrol",
                    "start": "2026-07-10T09:00:00Z",
                    "project": "isycontrol",
                    "theme": "rilascio",
                },
                omlx_summary={"summary": "Decisione: rilasciare dashboard a luglio."},
            )
            config = SimpleNamespace(
                journal_root=journal,
                summary_model="local",
                transcription_provider="apple",
            )

            publish_to_journal(config, artifacts)

            with sqlite3.connect(journal / "index.sqlite") as database:
                row = database.execute(
                    "SELECT project, theme, destination, session_path FROM entries"
                ).fetchone()
            self.assertEqual(row, ("isycontrol", "rilascio", "Diario", str(session)))

    def test_chat_sends_only_relevant_passages_and_returns_citations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            done.mkdir()
            session = done / "20260710-isycontrol"
            session.mkdir()
            (session / "meeting_metadata.json").write_text(
                json.dumps(
                    {
                        "title": "Riunione Isycontrol",
                        "start": "2026-07-10T09:00:00Z",
                        "project": "isycontrol",
                        "theme": "rilascio",
                    }
                ),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text(
                "Abbiamo parlato del meteo per molte righe.\n"
                "Decisione: isycontrol esce in beta privata entro luglio con Marco owner.\n"
                "Altro tema completamente irrilevante sul budget eventi.",
                encoding="utf-8",
            )
            write_omlx_summary(
                session,
                {
                    "title": "Riunione Isycontrol",
                    "date": "2026-07-10T09:00:00Z",
                    "summary": "Decisione: beta privata isycontrol entro luglio.",
                },
            )
            note = root / "Diary" / "2026" / "07" / "Riunione.md"
            note.parent.mkdir(parents=True)
            note.write_text("# Riunione", encoding="utf-8")
            write_journal_receipt(session, {"path": str(note)})
            captured: dict[str, str] = {}

            def provider(system_prompt: str, user_prompt: str) -> str:
                captured["user_prompt"] = user_prompt
                return "Fatti: beta privata isycontrol entro luglio. [1]\nDecisioni: Marco owner. [1]\nInferenze: nessuna."

            result = answer_meeting_question(
                SimpleNamespace(done_dir=done, journal_root=root / "Diary"),
                "Cosa è stato deciso su isycontrol?",
                MeetingChatFilters(project="isycontrol", sources=("journal",)),
                provider=provider,
            )

            self.assertIn("Marco owner", result.answer)
            self.assertEqual(result.citations[0].title, "Riunione Isycontrol")
            self.assertEqual(result.citations[0].destination, "Diario")
            self.assertIn("beta privata isycontrol", captured["user_prompt"])
            self.assertNotIn("meteo", captured["user_prompt"])
            self.assertNotIn("budget eventi", captured["user_prompt"])

    def test_chat_prompt_requires_facts_decisions_and_inferences_sections(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            done.mkdir()
            session = done / "20260710-isycontrol"
            session.mkdir()
            (session / "meeting_metadata.json").write_text(
                json.dumps({"title": "Riunione Isycontrol", "project": "isycontrol"}),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text(
                "Decisione: congelare lo scope della beta isycontrol.",
                encoding="utf-8",
            )
            captured: dict[str, str] = {}

            def provider(system_prompt: str, user_prompt: str) -> str:
                captured["system_prompt"] = system_prompt
                return "Fatti:\n- Scope beta citato. [1]\n\nDecisioni:\n- Scope congelato. [1]\n\nInferenze:\n- Nessuna."

            answer_meeting_question(
                SimpleNamespace(done_dir=done, journal_root=root / "Diary"),
                quick_prompt_question("project_decisions", project="isycontrol"),
                MeetingChatFilters(project="isycontrol"),
                provider=provider,
            )

            self.assertIn("<section>", captured["system_prompt"])
            self.assertIn("<h3>Sommario</h3>", captured["system_prompt"])
            self.assertIn("<h3>Fatti</h3>", captured["system_prompt"])
            self.assertIn("<h3>Decisioni</h3>", captured["system_prompt"])
            self.assertIn("<h3>Inferenze</h3>", captured["system_prompt"])
            self.assertIn("do not leave out", captured["system_prompt"])
            self.assertIn("Answer in Italian", captured["system_prompt"])
            self.assertIn("complete, verifiable coverage", captured["system_prompt"])
            self.assertIn("<li>", captured["system_prompt"])
            self.assertLess(
                captured["system_prompt"].index("<h3>Sommario</h3>"),
                captured["system_prompt"].index("<h3>Fatti</h3>"),
            )

    def test_chat_source_numbers_match_the_unique_clickable_citations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "done" / "20260807-chat"
            session.mkdir(parents=True)
            (session / "meeting_metadata.json").write_text(
                json.dumps({"title": "Allineamento", "project": "Robin"}),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text(
                "Decisioni uno rilevanti. Decisioni due rilevanti.",
                encoding="utf-8",
            )
            captured: dict[str, str] = {}

            def provider(_system_prompt: str, user_prompt: str) -> str:
                captured["user_prompt"] = user_prompt
                return "<section><h3>Sommario</h3><p>Decisioni confermate. [1]</p><h3>Fatti</h3><ul><li>Due decisioni. [1]</li></ul><h3>Decisioni</h3><ul><li>Confermate. [1]</li></ul><h3>Inferenze</h3><ul><li>Nessuna.</li></ul></section>"

            result = answer_meeting_question(
                SimpleNamespace(done_dir=root / "done", journal_root=root / "Diary"),
                "Quali decisioni?",
                provider=provider,
            )

            sources = json.loads(captured["user_prompt"])["sources"]
            self.assertEqual([source["id"] for source in sources], [1, 1])
            self.assertEqual(len(result.citations), 1)

    def test_quick_prompts_include_phase_two_summaries(self) -> None:
        self.assertEqual(
            quick_prompt_question("project_decisions", project="isycontrol"),
            "Quali decisioni sono state prese per il progetto isycontrol?",
        )
        self.assertIn("azioni aperte", quick_prompt_question("open_actions", project="isycontrol"))
        self.assertIn("rischi", quick_prompt_question("risks_blocks", project="isycontrol"))
        self.assertIn("evoluto", quick_prompt_question("theme_evolution", theme="rilascio"))
        self.assertIn("ultima settimana", quick_prompt_question("last_week_changes", project="isycontrol"))

    def test_chat_result_can_be_saved_explicitly_to_journal_and_obsidian(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(
                journal_root=root / "Diary",
                obsidian_vault_path=root / "Vault",
                obsidian_folder="Meeting Pilot",
                notion_token=None,
                notion_app_page_id=None,
                notion_parent_page_id=None,
            )
            citations = [
                MeetingChatCitation(
                    title="Riunione Isycontrol",
                    date="2026-07-10T09:00:00Z",
                    destination="Diario",
                    url="file:///tmp/riunione.md",
                )
            ]

            journal_receipt = save_meeting_chat_result(
                config,
                answer="Fatti:\n- Beta privata. [1]",
                citations=citations,
                destination="journal",
                question="Decisioni isycontrol",
            )
            obsidian_receipt = save_meeting_chat_result(
                config,
                answer="Fatti:\n- Beta privata. [1]",
                citations=citations,
                destination="obsidian",
                question="Decisioni isycontrol",
            )

            journal_page = Path(journal_receipt["path"])
            obsidian_page = Path(obsidian_receipt["path"])
            self.assertTrue(journal_page.exists())
            self.assertTrue(obsidian_page.exists())
            self.assertIn("Decisioni isycontrol", journal_page.read_text(encoding="utf-8"))
            self.assertIn("Riunione Isycontrol", obsidian_page.read_text(encoding="utf-8"))

    def test_chat_does_not_call_provider_when_selected_meetings_do_not_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            done.mkdir()
            session = done / "20260710-other"
            session.mkdir()
            (session / "meeting_metadata.json").write_text(
                json.dumps({"title": "Altro progetto", "project": "atlas"}),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text("Decisione su atlas.", encoding="utf-8")

            def provider(_system_prompt: str, _user_prompt: str) -> str:
                raise AssertionError("provider should not be called without relevant passages")

            result = answer_meeting_question(
                SimpleNamespace(done_dir=done, journal_root=root / "Diary"),
                "Cosa è stato deciso su isycontrol?",
                MeetingChatFilters(project="isycontrol"),
                provider=provider,
            )

            self.assertEqual(result.answer, "Non trovato nei meeting selezionati.")
            self.assertEqual(result.citations, [])

    def test_chat_rejects_uncited_provider_answers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            done = root / "done"
            done.mkdir()
            session = done / "20260710-isycontrol"
            session.mkdir()
            (session / "meeting_metadata.json").write_text(
                json.dumps({"title": "Riunione Isycontrol", "project": "isycontrol"}),
                encoding="utf-8",
            )
            (session / "transcript.txt").write_text(
                "Decisione: beta privata entro luglio.",
                encoding="utf-8",
            )

            result = answer_meeting_question(
                SimpleNamespace(done_dir=done, journal_root=root / "Diary"),
                "Decisioni isycontrol",
                MeetingChatFilters(project="isycontrol"),
                provider=lambda _system, _user: "Fatti: beta privata.\nDecisioni: luglio.\nInferenze: nessuna.",
            )

            self.assertEqual(result.answer, "Non trovato nei meeting selezionati.")
            self.assertEqual(result.citations, [])

    def test_chat_result_requires_citations_before_saving(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = SimpleNamespace(journal_root=root / "Diary")

            with self.assertRaises(ValueError):
                save_meeting_chat_result(
                    config,
                    answer="Fatti:\n- Beta privata.",
                    citations=[],
                    destination="journal",
                    question="Decisioni isycontrol",
                )

    def test_cli_chat_returns_json_not_found_without_calling_a_provider(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env_path = root / ".env"
            env_path.write_text(
                f"MEETINGS_ROOT={root / 'meetings'}\n"
                f"DONE_DIR={root / 'meetings' / 'done'}\n"
                f"JOURNAL_ROOT={root / 'Diary'}\n",
                encoding="utf-8",
            )
            environment = {
                **os.environ,
                "PYTHONPATH": "src",
                "MEETING_PILOT_ENV_FILE": str(env_path),
            }

            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "meeting_pilot.cli",
                    "chat",
                    "--question",
                    "Cosa è stato deciso su isycontrol?",
                    "--project",
                    "isycontrol",
                ],
                cwd=Path(__file__).parents[1],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

            payload = json.loads(completed.stdout)
            self.assertEqual(payload["answer"], "Non trovato nei meeting selezionati.")
            self.assertEqual(payload["citations"], [])


if __name__ == "__main__":
    unittest.main()
