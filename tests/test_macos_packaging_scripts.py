from __future__ import annotations

import os
import plistlib
import re
import subprocess
from pathlib import Path

APP_SRC = Path(__file__).resolve().parents[1] / "macos/MeetingPilot"


def test_ad_hoc_build_embeds_a_stable_tcc_requirement() -> None:
    script = (APP_SRC / "Scripts/build_app.sh").read_text()

    assert "Print :CFBundleIdentifier' \"$APP_SRC/Info.plist\"" in script
    assert '-r="designated => identifier \\"$BUNDLE_ID\\""' in script


def test_bundle_id_is_consistent_everywhere() -> None:
    bundle_id = plistlib.loads((APP_SRC / "Info.plist").read_bytes())["CFBundleIdentifier"]
    swift = (APP_SRC / "Sources/App/ConfigLocators.swift").read_text()
    distribution = (APP_SRC / "Installer/Distribution.xml").read_text()

    assert not bundle_id.startswith("it.local.")
    assert re.search(r'static let bundleID = "([^"]+)"', swift).group(1) == bundle_id
    assert f'pkg-ref id="{bundle_id}.pkg"' in distribution


def test_developer_id_build_uses_hardened_runtime_entitlements() -> None:
    script = (APP_SRC / "Scripts/build_app.sh").read_text()
    entitlements = plistlib.loads((APP_SRC / "MeetingPilot.entitlements").read_bytes())

    assert entitlements["com.apple.security.device.audio-input"] is True
    assert entitlements["com.apple.security.automation.apple-events"] is True
    assert '--entitlements "$APP_ENTITLEMENTS" "$APP_DIR"' in script
    assert "--options runtime" in script


def test_make_dmg_notarizes_when_a_profile_is_set() -> None:
    script = (APP_SRC / "Scripts/make_dmg.sh").read_text()
    notarize = (APP_SRC / "Scripts/notarize.sh").read_text()

    assert '"$APP_SRC/Scripts/notarize.sh" "$DMG_PATH"' in script
    assert "notarytool submit" in notarize
    assert "stapler staple" in notarize


def test_build_app_regenerates_bundle_icon_from_app_icon_asset() -> None:
    script = (Path(__file__).resolve().parents[1] / "macos/MeetingPilot/Scripts/build_app.sh").read_text()

    assert 'APP_ICON_SOURCE="$APP_SRC/assets/app_icon.png"' in script
    assert 'sips -z "$size" "$size" "$APP_ICON_SOURCE"' in script
    assert 'ICON_PATH="$APP_SRC/Resources/AppIcon.icns"' in script
    assert 'iconutil -c icns "$ICONSET_DIR" -o "$ICON_PATH"' in script


def test_make_dmg_verifies_existing_app_before_packaging(tmp_path: Path) -> None:
    build_dir = tmp_path / "build"
    app_dir = build_dir / "Meeting Pilot.app"
    macos_dir = app_dir / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True)
    launcher = macos_dir / "MeetingPilot"
    launcher.write_text("#!/bin/sh\n", encoding="utf-8")
    launcher.chmod(0o755)

    tool_dir = tmp_path / "bin"
    tool_dir.mkdir()
    log_path = tmp_path / "tool.log"

    (tool_dir / "codesign").write_text(
        "#!/bin/sh\n"
        "printf 'codesign %s\\n' \"$*\" >> \"$TOOL_LOG\"\n"
        "exit 0\n",
        encoding="utf-8",
    )
    (tool_dir / "xattr").write_text(
        "#!/bin/sh\n"
        "printf 'xattr %s\\n' \"$*\" >> \"$TOOL_LOG\"\n"
        "exit 0\n",
        encoding="utf-8",
    )
    (tool_dir / "osascript").write_text(
        "#!/bin/sh\n"
        "cat > /dev/null\n"
        "printf 'osascript\\n' >> \"$TOOL_LOG\"\n",
        encoding="utf-8",
    )
    (tool_dir / "hdiutil").write_text(
        "#!/bin/sh\n"
        "printf 'hdiutil %s\\n' \"$*\" >> \"$TOOL_LOG\"\n"
        "case \"$1\" in\n"
        "  attach) printf '/dev/disk9s1\\tApple_HFS\\t/Volumes/Meeting Pilot\\n'; exit 0 ;;\n"
        "  detach) exit 0 ;;\n"
        "esac\n"
        "out=''\n"
        "for arg in \"$@\"; do out=\"$arg\"; done\n"
        "mkdir -p \"$(dirname \"$out\")\"\n"
        ": > \"$out\"\n",
        encoding="utf-8",
    )
    for tool in tool_dir.iterdir():
        tool.chmod(0o755)

    env = os.environ.copy()
    env["MEETING_PILOT_BUILD_DIR"] = str(build_dir)
    env["PATH"] = f"{tool_dir}:{env['PATH']}"
    env["TOOL_LOG"] = str(log_path)

    subprocess.run(
        ["bash", "macos/MeetingPilot/Scripts/make_dmg.sh"],
        check=True,
        env=env,
        cwd=Path(__file__).resolve().parents[1],
    )

    log_lines = log_path.read_text(encoding="utf-8").splitlines()
    verify_index = next(
        i for i, line in enumerate(log_lines) if line.startswith("codesign --verify")
    )
    create_index = next(
        i for i, line in enumerate(log_lines) if line.startswith("hdiutil create")
    )
    assert verify_index < create_index
    layout_index = log_lines.index("osascript")
    convert_index = next(
        i for i, line in enumerate(log_lines) if line.startswith("hdiutil convert")
    )
    assert create_index < layout_index < convert_index
