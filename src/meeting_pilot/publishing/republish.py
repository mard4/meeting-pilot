"""Taking back a meeting's earlier notes before publishing it again.

When a published meeting is processed again (slides attached later), its new notes
replace the old ones instead of sitting next to them. Nothing is deleted outright: local
notes go to the Trash, the Notion page to Notion's trash and the Apple Notes note to
Recently Deleted, so an edit made by hand can still be recovered.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from typing import Any

from ..config import Config

RECEIPTS = {
    "journal": "journal_receipt.json",
    "obsidian": "obsidian_receipt.json",
    "notion": "notion_receipt.json",
    "apple_notes": "apple_notes_receipt.json",
}


def withdraw_previous_notes(config: Config, session_dir: Path, targets: tuple[str, ...]) -> None:
    """Withdraws the earlier note of each target about to publish the meeting again; a
    target dropped since then keeps its note, as nothing would replace it."""
    for target in targets:
        receipt = _receipt(session_dir, target)
        if not receipt:
            continue
        try:
            _withdraw(config, target, receipt)
        except Exception as exc:  # A leftover note is better than a failed republish.
            print(f"Could not remove the previous {target} note: {exc}")


def _receipt(session_dir: Path, target: str) -> dict[str, Any]:
    name = RECEIPTS.get(target)
    if not name:
        return {}
    try:
        payload = json.loads((session_dir / name).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _withdraw(config: Config, target: str, receipt: dict[str, Any]) -> None:
    if target == "journal" and receipt.get("path"):
        note = Path(receipt["path"])
        _move_to_trash(note)
        _move_to_trash(note.with_suffix(".pdf"))
    elif target == "obsidian" and receipt.get("path"):
        note = Path(receipt["path"])
        _move_to_trash(note)
        _move_to_trash(note.parent / "Slides" / f"{note.stem}.pdf")
    elif target == "notion" and receipt.get("id") and config.notion_token:
        from notion_client import Client

        Client(auth=config.notion_token).pages.update(page_id=receipt["id"], in_trash=True)
    elif target == "apple_notes" and receipt.get("note_id"):
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", "on run argv", "-e", 'tell application "Notes" to delete note id (item 1 of argv)',
             "-e", "end run", str(receipt["note_id"])],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    else:
        return
    print(f"Previous {target} note removed.")


def _move_to_trash(path: Path) -> None:
    if not path.is_file():
        return
    trash = Path.home() / ".Trash"
    trash.mkdir(parents=True, exist_ok=True)
    destination = trash / path.name
    counter = 2
    while destination.exists():
        destination = trash / f"{path.stem} {counter}{path.suffix}"
        counter += 1
    shutil.move(str(path), str(destination))
