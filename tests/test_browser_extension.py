"""The browser extension in browser/extension, loaded unpacked and copied by the app."""
from __future__ import annotations

import base64
import hashlib
import json
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTENSION = ROOT / "browser" / "extension"
APP_EXTENSION_ID = re.search(
    r'unpackedExtensionID = "([a-p]{32})"',
    (ROOT / "macos/MeetingPilot/Sources/App/BrowserExtension.swift").read_text(encoding="utf-8"),
).group(1)


def _manifest() -> dict:
    return json.loads((EXTENSION / "manifest.json").read_text(encoding="utf-8"))


def test_extension_version_is_the_apps() -> None:
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert _manifest()["version"] == project["project"]["version"], "package_browser_extension.sh refuses a mismatch"


def test_the_key_gives_the_id_the_native_host_allows() -> None:
    digest = hashlib.sha256(base64.b64decode(_manifest()["key"])).hexdigest()[:32]
    extension_id = "".join(chr(ord("a") + int(character, 16)) for character in digest)
    assert extension_id == APP_EXTENSION_ID


def test_permissions_stay_minimal() -> None:
    manifest = _manifest()
    assert set(manifest["permissions"]) == {"nativeMessaging", "activeTab", "contextMenus"}
    assert "host_permissions" not in manifest


def test_every_language_has_every_message_the_extension_uses() -> None:
    sources = "".join(path.read_text(encoding="utf-8") for path in EXTENSION.glob("*.[hj][ts]*"))
    used = set(re.findall(r'getMessage\("([A-Za-z_]+)"', sources)) | set(re.findall(r'data-i18n="([A-Za-z_]+)"', sources))
    for call in re.findall(r"\bt\(([^)]*)\)", sources):
        used |= set(re.findall(r'"([A-Za-z_]+)"', call))
    used |= set(re.findall(r"__MSG_([A-Za-z_]+)__", json.dumps(_manifest())))
    used |= {f"error_{code}" for code in re.findall(r'"(host_missing|not_a_video|not_configured|app_unavailable)"', sources)}
    used.add("error_unknown")
    languages = sorted(path.name for path in (EXTENSION / "_locales").iterdir())
    assert languages == ["de", "en", "es", "fr", "it", "nl", "pt"]
    english = set(json.loads((EXTENSION / "_locales/en/messages.json").read_text(encoding="utf-8")))
    assert used <= english, used - english
    for language in languages:
        messages = json.loads((EXTENSION / "_locales" / language / "messages.json").read_text(encoding="utf-8"))
        assert set(messages) == english, language
