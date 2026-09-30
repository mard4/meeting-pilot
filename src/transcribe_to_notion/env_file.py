from __future__ import annotations

import os
from pathlib import Path


def update_env_file(path: Path, values: dict[str, str]) -> None:
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = existing.splitlines()
    remaining = dict(values)
    seen_keys: set[str] = set()
    normalized_lines: list[str] = []

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            normalized_lines.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if not key:
            normalized_lines.append(line)
            continue
        if key in seen_keys:
            continue
        seen_keys.add(key)
        if key in remaining:
            normalized_lines.append(f"{key}={_format_env_value(remaining.pop(key))}")
        else:
            normalized_lines.append(line)

    if remaining and normalized_lines and normalized_lines[-1].strip():
        normalized_lines.append("")
    for key in sorted(remaining):
        normalized_lines.append(f"{key}={_format_env_value(remaining[key])}")

    # The file can hold tokens and API keys: keep it readable by its owner only.
    path.touch(mode=0o600, exist_ok=True)
    os.chmod(path, 0o600)
    path.write_text("\n".join(normalized_lines) + "\n", encoding="utf-8")


def _format_env_value(value: str) -> str:
    if not value:
        return ""
    if any(char.isspace() for char in value) or any(char in value for char in ("#", '"', "'")):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value
