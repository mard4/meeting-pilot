from __future__ import annotations

import os
import stat
import tempfile
import unittest
from pathlib import Path

from transcribe_to_notion.env_file import update_env_file


class EnvFileTests(unittest.TestCase):
    def test_update_makes_the_file_owner_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            existing = Path(temporary) / ".env"
            existing.write_text("NOTION_TOKEN=secret\n", encoding="utf-8")
            os.chmod(existing, 0o644)
            created = Path(temporary) / "new.env"

            update_env_file(existing, {"OTHER_SETTING": "true"})
            update_env_file(created, {"NOTION_TOKEN": "secret"})

            self.assertEqual(stat.S_IMODE(existing.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(created.stat().st_mode), 0o600)

    def test_update_removes_duplicate_keys_and_keeps_the_new_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".env"
            path.write_text(
                "NOTION_DATABASE_ID=old-destination\n"
                "OTHER_SETTING=true\n"
                "NOTION_DATABASE_ID=stale-destination\n",
                encoding="utf-8",
            )

            update_env_file(path, {"NOTION_DATABASE_ID": "teams-meetings"})

            self.assertEqual(
                path.read_text(encoding="utf-8"),
                "NOTION_DATABASE_ID=teams-meetings\nOTHER_SETTING=true\n",
            )
