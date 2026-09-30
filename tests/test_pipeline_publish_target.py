from __future__ import annotations

import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from transcribe_to_notion.artifacts import MeetingArtifacts
from transcribe_to_notion import watcher
from transcribe_to_notion.pipeline import _apply_meeting_tag, _publish_artifacts


def test_session_recovery_claim_allows_only_one_owner(tmp_path: Path) -> None:
    """A second watcher must not resume a session already being recovered."""
    session = tmp_path / "session"
    session.mkdir()

    assert watcher._claim_session_recovery(session) is True
    assert watcher._claim_session_recovery(session) is False


class PipelinePublishTargetTests(unittest.TestCase):
    def test_prefers_notion_when_configured(self) -> None:
        config = SimpleNamespace(
            notion_token="token",
            notion_database_id="db",
            obsidian_vault_path=Path("/tmp/vault"),
        )
        artifacts = MeetingArtifacts(session_dir=Path("/tmp/session"), audio_file=Path("/tmp/audio.m4a"), title="Riunione")

        with patch("transcribe_to_notion.pipeline.publish_to_notion") as notion, patch(
            "transcribe_to_notion.pipeline.publish_to_obsidian"
        ) as obsidian, patch("transcribe_to_notion.pipeline.publish_to_apple_notes") as notes:
            _publish_artifacts(config, artifacts)

        notion.assert_called_once_with(config, artifacts)
        obsidian.assert_not_called()
        notes.assert_not_called()

    def test_uses_obsidian_when_notion_is_missing(self) -> None:
        config = SimpleNamespace(
            notion_token=None,
            notion_database_id=None,
            publish_target="obsidian",
            obsidian_vault_path=Path("/tmp/vault"),
        )
        artifacts = MeetingArtifacts(session_dir=Path("/tmp/session"), audio_file=Path("/tmp/audio.m4a"), title="Riunione")

        with patch("transcribe_to_notion.pipeline.publish_to_notion") as notion, patch(
            "transcribe_to_notion.pipeline.publish_to_obsidian"
        ) as obsidian, patch("transcribe_to_notion.pipeline.publish_to_apple_notes") as notes:
            _publish_artifacts(config, artifacts)

        notion.assert_not_called()
        obsidian.assert_called_once_with(config, artifacts)
        notes.assert_not_called()

    def test_explicit_obsidian_target_does_not_depend_on_notion(self) -> None:
        config = SimpleNamespace(
            notion_token="token",
            notion_database_id="db",
            publish_target="obsidian",
            obsidian_vault_path=Path("/tmp/vault"),
        )
        artifacts = MeetingArtifacts(session_dir=Path("/tmp/session"), audio_file=Path("/tmp/audio.m4a"), title="Riunione")

        with patch("transcribe_to_notion.pipeline.publish_to_notion") as notion, patch(
            "transcribe_to_notion.pipeline.publish_to_obsidian"
        ) as obsidian, patch("transcribe_to_notion.pipeline.publish_to_apple_notes") as notes:
            _publish_artifacts(config, artifacts)

        notion.assert_not_called()
        obsidian.assert_called_once_with(config, artifacts)
        notes.assert_not_called()

    def test_falls_back_to_local_journal_when_no_target_configured(self) -> None:
        config = SimpleNamespace(
            notion_token=None,
            notion_database_id=None,
            publish_target="auto",
            obsidian_vault_path=None,
        )
        artifacts = MeetingArtifacts(session_dir=Path("/tmp/session"), audio_file=Path("/tmp/audio.m4a"), title="Riunione")

        with patch("transcribe_to_notion.pipeline.publish_to_notion") as notion, patch(
            "transcribe_to_notion.pipeline.publish_to_obsidian"
        ) as obsidian, patch("transcribe_to_notion.pipeline.publish_to_apple_notes") as notes, patch(
            "transcribe_to_notion.pipeline.publish_to_journal"
        ) as journal:
            _publish_artifacts(config, artifacts)

        notion.assert_not_called()
        obsidian.assert_not_called()
        notes.assert_not_called()
        journal.assert_called_once_with(config, artifacts)

    def test_does_not_publish_when_user_explicitly_disables_all_targets(self) -> None:
        config = SimpleNamespace(
            notion_token=None,
            notion_database_id=None,
            publish_target="auto",
            publish_targets=(),
            publish_targets_explicit=True,
            obsidian_vault_path=None,
        )
        artifacts = MeetingArtifacts(session_dir=Path("/tmp/session"), audio_file=Path("/tmp/audio.m4a"), title="Riunione")

        with patch("transcribe_to_notion.pipeline.publish_to_journal") as journal:
            _publish_artifacts(config, artifacts)

        journal.assert_not_called()

    def test_publishes_multiple_selected_services(self) -> None:
        config = SimpleNamespace(
            notion_token="token",
            notion_database_id="db",
            obsidian_vault_path=Path("/tmp/vault"),
            publish_targets=("obsidian", "notion"),
        )
        artifacts = MeetingArtifacts(session_dir=Path("/tmp/session"), audio_file=Path("/tmp/audio.m4a"), title="Riunione")

        with patch("transcribe_to_notion.pipeline.publish_to_notion") as notion, patch(
            "transcribe_to_notion.pipeline.publish_to_obsidian"
        ) as obsidian, patch("transcribe_to_notion.pipeline.publish_to_apple_notes") as notes:
            _publish_artifacts(config, artifacts)

        obsidian.assert_called_once_with(config, artifacts)
        notion.assert_called_once_with(config, artifacts)
        notes.assert_not_called()

    def test_generates_tag_from_summary_without_overwriting_manual_tag(self) -> None:
        artifacts = MeetingArtifacts(
            session_dir=Path("/tmp/session"),
            audio_file=Path("/tmp/audio.m4a"),
            title="Riunione Teams",
            meeting_metadata={"title": "Riunione Teams Progetto Atlas"},
            omlx_summary={"tag": "Architettura Atlas"},
        )
        with patch("transcribe_to_notion.pipeline.write_meeting_metadata"):
            _apply_meeting_tag(artifacts)
        self.assertEqual(artifacts.meeting_metadata["project"], "Architettura Atlas")

        artifacts.meeting_metadata["project"] = "Scelta manuale"
        with patch("transcribe_to_notion.pipeline.write_meeting_metadata"):
            _apply_meeting_tag(artifacts)
        self.assertEqual(artifacts.meeting_metadata["project"], "Scelta manuale")

    def test_generates_theme_from_summary(self) -> None:
        artifacts = MeetingArtifacts(
            session_dir=Path("/tmp/session"),
            audio_file=Path("/tmp/audio.m4a"),
            title="Riunione Teams",
            meeting_metadata={},
            omlx_summary={"theme": "Pianificazione trimestrale"},
        )

        with patch("transcribe_to_notion.pipeline.write_meeting_metadata"):
            _apply_meeting_tag(artifacts)

        self.assertEqual(
            artifacts.meeting_metadata["theme"],
            "Pianificazione trimestrale",
        )

    def test_preserves_manually_assigned_theme(self) -> None:
        artifacts = MeetingArtifacts(
            session_dir=Path("/tmp/session"),
            audio_file=Path("/tmp/audio.m4a"),
            title="Riunione Teams",
            meeting_metadata={"theme": "Tema manuale"},
            omlx_summary={"theme": "Tema generato"},
        )

        with patch("transcribe_to_notion.pipeline.write_meeting_metadata"):
            _apply_meeting_tag(artifacts)

        self.assertEqual(artifacts.meeting_metadata["theme"], "Tema manuale")


if __name__ == "__main__":
    unittest.main()
