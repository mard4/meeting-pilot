"""The Meeting Pilot model (summary mode "builtin"): a small model the app downloads,
served by the llama.cpp server bundled in the app.

Nothing runs between meetings. The first request starts the server on a free local
port; it stops after a couple of idle minutes, or with this process, so the model's
3-5 GB of memory are held only while it works. The server settings are the ones
tools/local_model_eval.py measured on real and Italian meetings.
"""
from __future__ import annotations

import atexit
import os
import secrets
import shutil
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from ..config import Config


@dataclass(frozen=True)
class Variant:
    file_name: str
    server_args: tuple[str, ...] = ()


# The app downloads these files (BuiltinModelVariant in BuiltinModel.swift); keep the
# names in sync.
VARIANTS = {
    # Bonsai-4B: Qwen3-4B at one bit per weight. It loops without a presence penalty.
    "light": Variant("Bonsai-4B-Q1_0.gguf", ("--presence-penalty", "1.5")),
    "quality": Variant("Qwen3-4B-Q4_K_M.gguf"),
}
DEFAULT_VARIANT = "light"

# A summary is 1-2k tokens; small models sometimes repeat themselves until the
# context is full, so the answer is cut here instead.
MAX_OUTPUT_TOKENS = 4096
IDLE_SECONDS = 120
STARTUP_SECONDS = 180
# Measured ~3.7 characters per token on Italian and English transcripts; 3 keeps a margin.
CHARACTERS_PER_TOKEN = 3
PROMPT_TOKENS = 2048


class BuiltinModelUnavailable(RuntimeError):
    pass


def is_builtin(config: Config) -> bool:
    return getattr(config, "summary_provider_mode", "") == "builtin"


def variant_name(config: Config) -> str:
    name = str(getattr(config, "summary_model", "") or "").strip().lower()
    return name if name in VARIANTS else DEFAULT_VARIANT


def model_path(config: Config) -> Path:
    return Path(config.builtin_models_dir).expanduser() / VARIANTS[variant_name(config)].file_name


def context_tokens() -> int:
    """Most of the server's memory is the context, so Macs with 8 GB get half of it."""
    try:
        memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (ValueError, OSError):
        memory = 0
    return 32768 if memory > 12 * 1024**3 else 16384


def transcript_limit() -> int:
    """Characters of transcript one request can carry; longer ones are condensed first."""
    return (context_tokens() - MAX_OUTPUT_TOKENS - PROMPT_TOKENS) * CHARACTERS_PER_TOKEN


def server_command(config: Config, port: int) -> list[str]:
    return [
        _resolve_command(config.builtin_server_cmd),
        "-m", str(model_path(config)),
        "--host", "127.0.0.1",
        "--port", str(port),
        "-c", str(context_tokens()),
        "-np", "1",
        "-ngl", "99",
        "-n", str(MAX_OUTPUT_TOKENS),
        # Both models are Qwen3, which reasons before answering by default; notes don't
        # need it and it would cost most of the time.
        "--jinja",
        "--reasoning-budget", "0",
        "--no-webui",
        # The prompts are meeting transcripts; nothing else needs the slots monitor.
        "--no-slots",
        *VARIANTS[variant_name(config)].server_args,
    ]


@contextmanager
def server(config: Config) -> Iterator[str]:
    """The base URL of a running server for the configured model, kept alive while in use."""
    base_url = _SERVER.acquire(config)
    try:
        yield base_url
    finally:
        _SERVER.release()


def request_headers() -> dict[str, str]:
    """What every request to the server must carry: it listens on localhost, where any
    process and any other account on the Mac could otherwise read the transcripts sent."""
    return {"Authorization": f"Bearer {API_KEY}"}


def _resolve_command(command: str) -> str:
    path = Path(command).expanduser()
    if path.is_file() and os.access(path, os.X_OK):
        return str(path)
    found = shutil.which(command)
    if found:
        return found
    raise BuiltinModelUnavailable(
        f"Il motore del modello Meeting Pilot non è stato trovato ({command}). Reinstalla l'app."
    )


class _Server:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._process: subprocess.Popen | None = None
        self._watchdog: subprocess.Popen | None = None
        self._model: Path | None = None
        self._base_url = ""
        self._users = 0
        self._idle_timer: threading.Timer | None = None

    def acquire(self, config: Config) -> str:
        with self._lock:
            self._cancel_idle_timer()
            path = model_path(config)
            if not path.is_file():
                raise BuiltinModelUnavailable(
                    "Il modello Meeting Pilot non è ancora scaricato: scaricalo in Impostazioni › Sintesi."
                )
            if self._model != path or not self._running():
                self._stop()
                self._start(config, path)
            self._users += 1
            return self._base_url

    def release(self) -> None:
        with self._lock:
            self._users = max(0, self._users - 1)
            if self._users == 0 and self._running():
                self._idle_timer = threading.Timer(IDLE_SECONDS, self.stop)
                self._idle_timer.daemon = True
                self._idle_timer.start()

    def stop(self) -> None:
        with self._lock:
            if self._users == 0:
                self._stop()

    def shutdown(self) -> None:
        with self._lock:
            self._stop()

    def _running(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def _start(self, config: Config, path: Path) -> None:
        port = _free_port()
        command = server_command(config, port)
        log_path = path.parent / "llama-server.log"
        with log_path.open("w") as log:
            # The key goes through the environment, not argv, where `ps` would show it.
            process = subprocess.Popen(
                command, stdout=log, stderr=subprocess.STDOUT, env={**os.environ, "LLAMA_API_KEY": API_KEY}
            )
        # atexit doesn't run when this process is killed; the watchdog stops the server then.
        watchdog = subprocess.Popen(
            ["/bin/sh", "-c", 'while kill -0 "$1" 2>/dev/null; do sleep 5; done; kill "$2" 2>/dev/null', "sh",
             str(os.getpid()), str(process.pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        base_url = f"http://127.0.0.1:{port}"
        print(f"Starting the Meeting Pilot model ({path.name})...", flush=True)
        deadline = time.monotonic() + STARTUP_SECONDS
        while time.monotonic() < deadline:
            if process.poll() is not None:
                watchdog.kill()
                raise BuiltinModelUnavailable(f"Il modello Meeting Pilot non è partito: {_log_tail(log_path)}")
            try:
                with urllib.request.urlopen(base_url + "/health", timeout=2) as response:
                    if response.status == 200:
                        break
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                pass
            time.sleep(0.5)
        else:
            process.kill()
            watchdog.kill()
            raise BuiltinModelUnavailable("Il modello Meeting Pilot non ha risposto in tempo.")
        self._process, self._watchdog, self._model = process, watchdog, path
        self._base_url = base_url + "/v1"

    def _stop(self) -> None:
        self._cancel_idle_timer()
        if self._process is not None and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._process.kill()
        if self._watchdog is not None and self._watchdog.poll() is None:
            self._watchdog.kill()
        self._process = self._watchdog = self._model = None
        self._base_url = ""

    def _cancel_idle_timer(self) -> None:
        if self._idle_timer is not None:
            self._idle_timer.cancel()
            self._idle_timer = None


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _log_tail(path: Path) -> str:
    try:
        lines = [line for line in path.read_text(errors="replace").splitlines() if line.strip()]
    except OSError:
        return "nessun log"
    return " | ".join(lines[-3:])[:500]


API_KEY = secrets.token_urlsafe(32)
_SERVER = _Server()
atexit.register(_SERVER.shutdown)
