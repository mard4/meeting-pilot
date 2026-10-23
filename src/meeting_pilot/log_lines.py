"""Every line of a log starts with when it was written, in the app log's format
(`[2026-10-23T07:05:58Z] `), so the pipeline's logs read alongside the app's."""

from __future__ import annotations

import re
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Any, Sequence

_STAMP = re.compile(r"^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] ")


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("[%Y-%m-%dT%H:%M:%SZ] ")


def stamped(text: str) -> str:
    """Each line of `text` with the current time before it; blank lines stay blank."""
    prefix = stamp()
    return "".join(prefix + line if line.strip() else line for line in text.splitlines(keepends=True))


def unstamped(line: str) -> str:
    return _STAMP.sub("", line)


class StampedStream:
    """A text stream that puts the time before each line written to it: the watcher's
    output and errors, which the app writes to its log files."""

    def __init__(self, stream: IO[str]) -> None:
        self._stream = stream
        self._at_line_start = True

    def write(self, text: str) -> int:
        pieces = []
        for piece in text.splitlines(keepends=True):
            if self._at_line_start and piece.strip():
                pieces.append(stamp())
            pieces.append(piece)
            self._at_line_start = piece.endswith(("\n", "\r"))
        self._stream.write("".join(pieces))
        return len(text)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._stream, name)


def copy_stamped(stream: IO[str], log_path: Path) -> threading.Thread:
    """Appends what `stream` prints to `log_path`, a line at a time with when it arrived."""

    def copy() -> None:
        with log_path.open("a", encoding="utf-8") as log:
            for line in stream:
                log.write(stamped(line) if line.strip() else line)
                log.flush()

    thread = threading.Thread(target=copy, daemon=True)
    thread.start()
    return thread


def run_logged(
    command: Sequence[str], log_path: Path, *, timeout: float | None = None, env: dict[str, str] | None = None
) -> int:
    """Runs `command` with its output and errors appended to `log_path` as they come,
    after the command line. Raises `subprocess.TimeoutExpired` once `timeout` passes,
    the command stopped."""
    with log_path.open("a", encoding="utf-8") as log:
        log.write(stamped("$ " + " ".join(command) + "\n"))
    process = subprocess.Popen(
        list(command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", env=env
    )
    assert process.stdout is not None
    reader = copy_stamped(process.stdout, log_path)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        reader.join(timeout=5)
        raise
    # A helper's own children can keep the pipe open after it exits.
    reader.join(timeout=30)
    return process.returncode
