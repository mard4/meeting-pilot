"""Compare small local models on Meeting Pilot's own summary prompts.

Each candidate runs in llama.cpp's `llama-server`, the engine a built-in model would
ship with, and summarizes the same transcripts through the app's real code path
(`fit_for_summary` + `summarize`), so prompts, schema and chunking match production.

    uv run python tools/local_model_eval.py prepare
    uv run python tools/local_model_eval.py run [--models bonsai-4b,qwen3-4b] [--cases ami-ES2002a]
    uv run --with anthropic python tools/local_model_eval.py judge [--include-private]
    uv run python tools/local_model_eval.py report

Everything (models, cases, results, report) lands in Datasets/local_model_eval/, which
is gitignored: delete that folder to free the space.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

WORK = ROOT / "Datasets" / "local_model_eval"
MODELS_DIR = WORK / "models"
CASES_DIR = WORK / "cases"
RESULTS_DIR = WORK / "results"
JUDGE_DIR = WORK / "judge"
CUSTOM_DIR = WORK / "custom"
AMI_DIR = ROOT / "Datasets" / "ami_public_1.6.2"
APP_MEETINGS_DIR = Path("~/TeamsMeetings/done").expanduser()

NITE_ID = "{http://nite.sourceforge.net/}id"
CONTEXT_TOKENS = 32768
# A finished summary is 1-2k tokens; small models sometimes loop until the context is
# full, which the app must also cut short.
MAX_OUTPUT_TOKENS = 4096

# Bonsai is Qwen3 compressed to 1-2 bits per weight, so the Qwen3 Q4 builds of the same
# base show what the compression costs.
MODELS: dict[str, dict[str, Any]] = {
    "bonsai-1.7b": {"repo": "prism-ml/Bonsai-1.7B-gguf", "file": "Bonsai-1.7B-Q1_0.gguf", "default": True},
    "bonsai-4b": {"repo": "prism-ml/Bonsai-4B-gguf", "file": "Bonsai-4B-Q1_0.gguf", "default": True},
    "ternary-bonsai-4b": {"repo": "prism-ml/Ternary-Bonsai-4B-gguf", "file": "Ternary-Bonsai-4B-Q2_0.gguf", "default": True},
    "qwen3-1.7b": {"repo": "unsloth/Qwen3-1.7B-GGUF", "file": "Qwen3-1.7B-Q4_K_M.gguf", "default": True},
    "qwen3-4b": {"repo": "Qwen/Qwen3-4B-GGUF", "file": "Qwen3-4B-Q4_K_M.gguf", "default": True},
    # The newer non-thinking 4B, as a quality ceiling for this size.
    "qwen3-4b-2507": {"repo": "unsloth/Qwen3-4B-Instruct-2507-GGUF", "file": "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", "default": False},
}

MEETING_KEYS = ["title", "tag", "theme", "date", "participants", "summary", "topics", "decisions", "action_items", "open_questions", "risks"]
LECTURE_KEYS = ["title", "tag", "theme", "date", "participants", "summary", "topics", "key_concepts", "assignments", "exam_hints", "review_questions", "references"]
LIST_KEYS = {"participants", "topics", "decisions", "action_items", "open_questions", "risks", "key_concepts", "assignments", "exam_hints", "review_questions", "references"}

ITALIAN_WORDS = {"il", "lo", "la", "di", "che", "e", "è", "per", "un", "una", "del", "della", "sono", "con", "non", "nel", "alla", "delle", "dei", "gli", "le", "sul", "come", "anche"}
ENGLISH_WORDS = {"the", "and", "of", "to", "is", "that", "for", "with", "are", "will", "was", "this", "on", "be", "it", "they"}


# --------------------------------------------------------------------------- prepare

def prepare(args: argparse.Namespace) -> None:
    CASES_DIR.mkdir(parents=True, exist_ok=True)
    CUSTOM_DIR.mkdir(parents=True, exist_ok=True)
    cases = ami_cases(args.ami) + app_cases(args.app) + custom_cases()
    for old in CASES_DIR.glob("*.json"):
        old.unlink()
    for case in cases:
        (CASES_DIR / f"{case['id']}.json").write_text(json.dumps(case, ensure_ascii=False, indent=2), encoding="utf-8")
    for case in cases:
        print(f"{case['id']:<40} {case['source']:<7} {case['profile']:<8} {len(case['transcript']):>7} chars")
    print(f"\n{len(cases)} cases in {CASES_DIR}")
    if not any(c["source"] == "custom" for c in cases):
        print(f"Tip: drop Italian transcripts into {CUSTOM_DIR} as .txt (name lectures *.lecture.txt) and run prepare again.")


def ami_cases(count: int) -> list[dict[str, Any]]:
    """AMI meetings are real recorded design meetings with human-written summaries,
    decisions and action items, so they double as a reference for coverage."""
    if count <= 0 or not (AMI_DIR / "abstractive").is_dir():
        return []
    candidates = []
    for path in sorted((AMI_DIR / "abstractive").glob("*.abssumm.xml")):
        meeting = path.name.split(".")[0]
        transcript = ami_transcript(meeting)
        # Long enough to be a real meeting, short enough to fit one request (no chunking).
        if 15_000 <= len(transcript) <= 60_000:
            candidates.append((meeting, transcript, path))
    if not candidates:
        return []
    step = max(1, len(candidates) // count)
    picked = candidates[::step][:count]
    return [
        {
            "id": f"ami-{meeting}",
            "source": "ami",
            "title": f"Riunione di progetto {meeting}",
            "profile": "worker",
            "transcript": transcript,
            "reference": ami_reference(path),
        }
        for meeting, transcript, path in picked
    ]


def ami_transcript(meeting: str) -> str:
    segments: list[tuple[float, str, str]] = []
    for words_path in sorted((AMI_DIR / "words").glob(f"{meeting}.*.words.xml")):
        speaker = words_path.name.split(".")[1]
        words = [w for w in ET.parse(words_path).getroot() if w.tag == "w"]
        index = {w.get(NITE_ID): i for i, w in enumerate(words)}
        segments_path = AMI_DIR / "segments" / f"{meeting}.{speaker}.segments.xml"
        if not segments_path.exists():
            continue
        for segment in ET.parse(segments_path).getroot():
            child = next(iter(segment), None)
            ids = re.findall(r"id\(([^)]+)\)", child.get("href", "")) if child is not None else []
            if not ids or ids[0] not in index:
                continue
            start, end = index[ids[0]], index.get(ids[-1], index[ids[0]])
            text = ""
            for w in words[start : end + 1]:
                token = w.text or ""
                text += token if (w.get("punc") == "true" or not text) else " " + token
            if text.strip():
                segments.append((float(segment.get("transcriber_start", 0)), speaker, text.strip()))
    segments.sort()
    lines: list[str] = []
    last = None
    for _, speaker, text in segments:
        if speaker == last:
            lines[-1] += " " + text
        else:
            lines.append(f"Speaker {speaker}: {text}")
            last = speaker
    return "\n".join(lines)


def ami_reference(path: Path) -> dict[str, list[str]]:
    root = ET.parse(path).getroot()
    reference: dict[str, list[str]] = {}
    for section in ("abstract", "decisions", "actions", "problems"):
        reference[section] = [
            (s.text or "").strip()
            for element in root.iter(section)
            for s in element.iter("sentence")
            if (s.text or "").strip()
        ]
    return reference


def app_cases(count: int) -> list[dict[str, Any]]:
    """Meetings this Mac already processed; they stay local unless judged with --include-private."""
    if count <= 0 or not APP_MEETINGS_DIR.is_dir():
        return []
    cases = []
    for session in sorted(APP_MEETINGS_DIR.iterdir(), reverse=True):
        transcript_path = next(iter(sorted(session.glob("*_transcript.txt"))), None)
        if transcript_path is None:
            continue
        transcript = transcript_path.read_text(encoding="utf-8").strip()
        if len(transcript) < 500:
            continue
        try:
            metadata = json.loads((session / "meeting_metadata.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            metadata = {}
        cases.append({
            "id": "app-" + re.sub(r"[^a-z0-9]+", "-", session.name.lower())[:40].strip("-"),
            "source": "app",
            "title": str(metadata.get("title") or metadata.get("subject") or session.name),
            "profile": "worker",
            "transcript": transcript,
        })
        if len(cases) == count:
            break
    return cases


def custom_cases() -> list[dict[str, Any]]:
    cases = []
    for path in sorted(CUSTOM_DIR.glob("*.txt")):
        lecture = path.name.endswith(".lecture.txt")
        stem = path.name.removesuffix(".lecture.txt").removesuffix(".txt")
        case = {
            "id": "custom-" + re.sub(r"[^a-z0-9]+", "-", stem.lower()).strip("-"),
            "source": "custom",
            "title": stem.replace("_", " ").replace("-", " "),
            "profile": "student" if lecture else "worker",
            "transcript": path.read_text(encoding="utf-8").strip(),
        }
        # Optional <name>.reference.json: what a good summary must contain, shown in the
        # report and given to the judge.
        reference = path.with_name(f"{stem}.reference.json")
        if reference.exists():
            case["reference"] = json.loads(reference.read_text(encoding="utf-8"))
        cases.append(case)
    return cases


def load_cases(only: str | None) -> list[dict[str, Any]]:
    cases = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(CASES_DIR.glob("*.json"))]
    if only:
        wanted = set(only.split(","))
        cases = [c for c in cases if c["id"] in wanted]
    if not cases:
        sys.exit("No cases: run `prepare` first.")
    return cases


# --------------------------------------------------------------------------- run

def run(args: argparse.Namespace) -> None:
    server = args.llama_server or os.getenv("LLAMA_SERVER") or shutil.which("llama-server")
    if not server:
        sys.exit("llama-server not found: `brew install llama.cpp`, or pass --llama-server /path/to/llama-server.")
    names = args.models.split(",") if args.models else [n for n, m in MODELS.items() if m["default"]]
    unknown = [n for n in names if n not in MODELS]
    if unknown:
        sys.exit(f"Unknown models: {', '.join(unknown)}. Known: {', '.join(MODELS)}")
    cases = load_cases(args.cases)
    for name in names:
        model_path = download(name)
        variant = f"{name}+{args.label}" if args.label else name
        print(f"\n=== {variant} ({model_path.stat().st_size / 1e6:.0f} MB) ===")
        out_dir = RESULTS_DIR / variant
        out_dir.mkdir(parents=True, exist_ok=True)
        try:
            llama = LlamaServer(server, model_path, out_dir / "llama-server.log", args.server_args.split()).__enter__()
        except RuntimeError as exc:
            print(f"  skipped: {exc}")
            continue
        try:
            for case in cases:
                target = out_dir / f"{case['id']}.json"
                if target.exists() and not args.force:
                    print(f"  {case['id']}: already done (use --force to redo)")
                    continue
                result = summarize_case(case, llama, variant, args.json_mode)
                target.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
                status = "ok" if result["summary"] is not None else f"FAILED: {result['error'][:120]}"
                print(f"  {case['id']}: {result['seconds']:.0f}s, {result['generated_tokens']} tokens out, {status}")
        finally:
            llama.__exit__()
    print(f"\nResults in {RESULTS_DIR}. Next: `judge` (optional) and `report`.")


def download(name: str) -> Path:
    spec = MODELS[name]
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    target = MODELS_DIR / spec["file"]
    expected = remote_size(spec["repo"], spec["file"])
    if target.exists() and (expected is None or target.stat().st_size == expected):
        return target
    partial = target.with_suffix(".part")
    url = f"https://huggingface.co/{spec['repo']}/resolve/main/{spec['file']}"
    have = partial.stat().st_size if partial.exists() else 0
    request = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    print(f"Downloading {spec['file']} ({(expected or 0) / 1e6:.0f} MB)…")
    with urllib.request.urlopen(request, timeout=60) as response, partial.open("ab" if have else "wb") as handle:
        if have and response.status != 206:
            handle.truncate(0)
            have = 0
        done, last_print = have, 0.0
        while chunk := response.read(1 << 20):
            handle.write(chunk)
            done += len(chunk)
            if expected and time.time() - last_print > 2:
                print(f"  {done / expected:6.1%}", end="\r", flush=True)
                last_print = time.time()
    if expected is not None and partial.stat().st_size != expected:
        sys.exit(f"{spec['file']}: got {partial.stat().st_size} bytes, expected {expected}. Run again to resume.")
    partial.rename(target)
    print(f"  saved {target}")
    return target


def remote_size(repo: str, file: str) -> int | None:
    try:
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/tree/main", timeout=30) as response:
            entries = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None
    return next((e.get("size") for e in entries if e.get("path") == file), None)


class LlamaServer:
    """One model at a time, one slot, the full context: what the app would run."""

    def __init__(self, binary: str, model: Path, log_path: Path, extra_args: list[str]):
        self.binary, self.model, self.log_path, self.extra_args = binary, model, log_path, extra_args
        self.port = free_port()
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.process: subprocess.Popen | None = None

    def __enter__(self) -> "LlamaServer":
        self.log = self.log_path.open("w")
        self.process = subprocess.Popen(
            [
                self.binary, "-m", str(self.model),
                "--host", "127.0.0.1", "--port", str(self.port),
                "-c", str(CONTEXT_TOKENS), "-np", "1", "-ngl", "99", "-n", str(MAX_OUTPUT_TOKENS),
                # Qwen3-based models think by default; summaries don't need it and it
                # would cost most of the time budget.
                "--jinja", "--reasoning-budget", "0",
                "--metrics",
                *self.extra_args,
            ],
            stdout=self.log, stderr=subprocess.STDOUT,
        )
        deadline = time.time() + 300
        while time.time() < deadline:
            if self.process.poll() is not None:
                self.log.close()
                raise RuntimeError(f"llama-server exited early; see {self.log_path}")
            try:
                with urllib.request.urlopen(self.base_url + "/health", timeout=2) as response:
                    if response.status == 200:
                        return self
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                pass
            time.sleep(1)
        self.__exit__()
        raise RuntimeError(f"llama-server did not become ready; see {self.log_path}")

    def __exit__(self, *_: object) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.log.close()

    def metrics(self) -> dict[str, float]:
        try:
            with urllib.request.urlopen(self.base_url + "/metrics", timeout=5) as response:
                text = response.read().decode()
        except (urllib.error.URLError, TimeoutError):
            return {}
        values = {}
        for line in text.splitlines():
            match = re.match(r"llamacpp:(\w+)\s+([0-9.eE+-]+)$", line)
            if match:
                values[match.group(1)] = float(match.group(2))
        return values

    def rss_mb(self) -> float:
        if not self.process:
            return 0.0
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.process.pid)], capture_output=True, text=True).stdout
        return int(out.strip() or 0) / 1024


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def summarize_case(case: dict[str, Any], llama: LlamaServer, model_name: str, json_mode: bool) -> dict[str, Any]:
    with tempfile.TemporaryDirectory() as scratch:
        os.environ.update({
            "SUMMARY_PROVIDER_MODE": "local",
            "SUMMARY_RUNTIME": "other",
            "SUMMARY_BASE_URL": llama.base_url + "/v1",
            "SUMMARY_MODEL": model_name,
            "SUMMARY_API_KEY": "",
            "SUMMARY_RESPONSE_FORMAT_JSON": "true" if json_mode else "false",
            "SUMMARY_TIMEOUT_SECONDS": "1800",
            "SUMMARY_TEMPLATE": "auto",
            "OUTPUT_LANGUAGE": "it",
            "USER_PROFILE": case["profile"],
            # Keep the user's tag catalog and Diary out of the prompt, so every run sees the same input.
            "MEETINGS_ROOT": scratch,
            "JOURNAL_ROOT": scratch,
        })
        from meeting_pilot.artifacts import MeetingArtifacts
        from meeting_pilot.config import Config
        from meeting_pilot.summarization.long_transcripts import fit_for_summary
        from meeting_pilot.summarization.omlx_client import summarize

        config = Config.from_env()
        artifacts = MeetingArtifacts(
            session_dir=Path(scratch),
            audio_file=Path(scratch) / "audio.m4a",
            title=case["title"],
            transcript_text=case["transcript"],
            meeting_metadata={"title": case["title"]},
        )
        before = llama.metrics()
        started = time.time()
        summary, error = None, None
        try:
            summary = summarize(config, fit_for_summary(config, artifacts))
        except Exception as exc:  # noqa: BLE001 - every failure is a data point here
            error = f"{type(exc).__name__}: {exc}"
        seconds = time.time() - started
        after = llama.metrics()
    return {
        "model": model_name,
        "case": case["id"],
        "summary": summary,
        "error": error,
        "seconds": seconds,
        "prompt_tokens": int(after.get("prompt_tokens_total", 0) - before.get("prompt_tokens_total", 0)),
        "generated_tokens": int(after.get("tokens_predicted_total", 0) - before.get("tokens_predicted_total", 0)),
        "rss_mb": llama.rss_mb(),
    }


# --------------------------------------------------------------------------- checks

def checks(case: dict[str, Any], result: dict[str, Any]) -> dict[str, Any]:
    summary = result.get("summary")
    if not isinstance(summary, dict):
        return {"valid": False, "complete": False, "italian": False, "decisions": 0, "actions": 0}
    keys = LECTURE_KEYS if case["profile"] == "student" else MEETING_KEYS
    complete = all(k in summary for k in keys) and all(
        isinstance(summary.get(k), list) for k in keys if k in LIST_KEYS
    )
    text = " ".join(str(summary.get(k) or "") for k in ("title", "summary", "topics")).lower()
    words = re.findall(r"[a-zàèéìòù]+", text)
    italian_hits = sum(w in ITALIAN_WORDS for w in words)
    english_hits = sum(w in ENGLISH_WORDS for w in words)
    return {
        "valid": True,
        "complete": complete,
        "italian": italian_hits > 2 * english_hits and italian_hits >= 5,
        "decisions": len(summary.get("decisions") or summary.get("key_concepts") or []),
        "actions": len(summary.get("action_items") or summary.get("assignments") or []),
    }


def load_results() -> dict[str, dict[str, dict[str, Any]]]:
    results: dict[str, dict[str, dict[str, Any]]] = {}
    for model_dir in sorted(RESULTS_DIR.glob("*")):
        if model_dir.is_dir():
            results[model_dir.name] = {
                p.stem: json.loads(p.read_text(encoding="utf-8")) for p in sorted(model_dir.glob("*.json"))
            }
    return results


# --------------------------------------------------------------------------- judge

JUDGE_SCHEMA = {
    "type": "object",
    "properties": {
        "scores": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "faithfulness": {"type": "integer"},
                    "coverage": {"type": "integer"},
                    "italian": {"type": "integer"},
                    "structure": {"type": "integer"},
                    "invented_facts": {"type": "array", "items": {"type": "string"}},
                    "comment": {"type": "string"},
                },
                "required": ["label", "faithfulness", "coverage", "italian", "structure", "invented_facts", "comment"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["scores"],
    "additionalProperties": False,
}

JUDGE_INSTRUCTIONS = """You grade meeting notes written by small local language models for a note-taking app.
The notes must be written in Italian and follow a fixed JSON structure.
Each candidate is labelled with a letter; you do not know which model wrote it. Grade each one independently against the transcript, from 1 (unusable) to 5 (as good as a careful human):
- faithfulness: everything stated is supported by the transcript; invented names, numbers, decisions, owners or deadlines weigh heavily.
- coverage: the main points, decisions and action items of the meeting are there (the reference summary, when given, lists what humans considered essential).
- italian: natural, correct Italian; English left untranslated or broken grammar lowers it.
- structure: the right content in the right fields (decisions are decisions, action items have tasks and owners when known, nothing duplicated or empty that the transcript would fill).
List each invented fact briefly in invented_facts. Keep comment to one or two sentences."""


def judge(args: argparse.Namespace) -> None:
    import anthropic

    client = anthropic.Anthropic()
    JUDGE_DIR.mkdir(parents=True, exist_ok=True)
    results = load_results()
    for case in load_cases(args.cases):
        if case["source"] != "ami" and not args.include_private:
            print(f"{case['id']}: skipped (own transcript; pass --include-private to send it to Claude)")
            continue
        target = JUDGE_DIR / f"{case['id']}.json"
        if target.exists() and not args.force:
            print(f"{case['id']}: already judged")
            continue
        candidates = [(m, r[case["id"]]) for m, r in results.items() if case["id"] in r and r[case["id"]]["summary"]]
        if not candidates:
            continue
        random.Random(case["id"]).shuffle(candidates)
        labels = {chr(ord("A") + i): model for i, (model, _) in enumerate(candidates)}
        parts = [f"<transcript>\n{case['transcript']}\n</transcript>"]
        if case.get("reference"):
            parts.append(f"<reference_summary>\n{json.dumps(case['reference'], ensure_ascii=False, indent=1)}\n</reference_summary>")
        for label, (_, result) in zip(labels, candidates):
            parts.append(f'<candidate label="{label}">\n{json.dumps(result["summary"], ensure_ascii=False, indent=1)}\n</candidate>')
        response = client.beta.messages.create(
            model="claude-opus-5-5",
            max_tokens=16000,
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            system=JUDGE_INSTRUCTIONS,
            output_config={"effort": "high", "format": {"type": "json_schema", "schema": JUDGE_SCHEMA}},
            messages=[{"role": "user", "content": "\n\n".join(parts)}],
        )
        if response.stop_reason == "refusal":
            print(f"{case['id']}: the judge declined")
            continue
        text = next(b.text for b in response.content if b.type == "text")
        scores = json.loads(text)["scores"]
        for score in scores:
            score["model"] = labels.get(score["label"], "?")
        target.write_text(json.dumps({"labels": labels, "scores": scores}, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{case['id']}: judged {len(scores)} candidates")


def load_judgements() -> dict[str, dict[str, dict[str, Any]]]:
    """case id -> model -> scores"""
    judged: dict[str, dict[str, dict[str, Any]]] = {}
    for path in JUDGE_DIR.glob("*.json"):
        data = json.loads(path.read_text(encoding="utf-8"))
        judged[path.stem] = {s["model"]: s for s in data["scores"]}
    return judged


# --------------------------------------------------------------------------- report

DIMENSIONS = ["faithfulness", "coverage", "italian", "structure"]


def report(_: argparse.Namespace) -> None:
    cases = {c["id"]: c for c in load_cases(None)}
    results = load_results()
    judged = load_judgements()
    if not results:
        sys.exit("No results: run `run` first.")

    rows = []
    for model, by_case in results.items():
        runs = [(cases[c], r) for c, r in by_case.items() if c in cases]
        checked = [checks(case, r) for case, r in runs]
        scores = [judged[c][model] for c in by_case if model in judged.get(c, {})]
        spec = MODELS.get(model.split("+")[0])
        size = (MODELS_DIR / spec["file"]).stat().st_size / 1e6 if spec and (MODELS_DIR / spec["file"]).exists() else 0
        rows.append({
            "model": model,
            "size": size,
            "valid": share(c["valid"] for c in checked),
            "complete": share(c["complete"] for c in checked),
            "italian": share(c["italian"] for c in checked),
            "seconds": mean(r["seconds"] for _, r in runs),
            "gen_rate": mean(r["generated_tokens"] / r["seconds"] for _, r in runs if r["seconds"] > 0),
            "rss": max((r["rss_mb"] for _, r in runs), default=0),
            "judge": {d: mean(s[d] for s in scores) for d in DIMENSIONS} if scores else None,
            "invented": sum(len(s["invented_facts"]) for s in scores) if scores else None,
        })
    rows.sort(key=lambda r: (-(mean(r["judge"].values()) if r["judge"] else 0), r["size"]))

    out = WORK / "report.html"
    out.write_text(render(rows, cases, results, judged), encoding="utf-8")
    for row in rows:
        overall = f"{mean(row['judge'].values()):.2f}" if row["judge"] else "—"
        print(f"{row['model']:<20} {row['size']:>6.0f} MB  JSON {row['valid']:>4.0%}  IT {row['italian']:>4.0%}  {row['seconds']:>5.0f}s  judge {overall}")
    print(f"\nReport: {out}")


def share(values: Any) -> float:
    values = list(values)
    return sum(values) / len(values) if values else 0.0


def mean(values: Any) -> float:
    values = list(values)
    return sum(values) / len(values) if values else 0.0


def render(rows: list[dict[str, Any]], cases: dict[str, Any], results: dict[str, Any], judged: dict[str, Any]) -> str:
    esc = html.escape
    table = "".join(
        "<tr>"
        f"<th scope=row>{esc(r['model'])}</th>"
        f"<td>{r['size']:.0f} MB</td>"
        f"<td>{r['valid']:.0%}</td><td>{r['complete']:.0%}</td><td>{r['italian']:.0%}</td>"
        f"<td>{r['seconds']:.0f} s</td><td>{r['gen_rate']:.0f}</td><td>{r['rss'] / 1024:.1f} GB</td>"
        + ("".join(f"<td>{r['judge'][d]:.1f}</td>" for d in DIMENSIONS) + f"<td><b>{mean(r['judge'].values()):.2f}</b></td><td>{r['invented']}</td>"
           if r["judge"] else "<td colspan=6 class=muted>not judged</td>")
        + "</tr>"
        for r in rows
    )
    order = [r["model"] for r in rows]
    sections = []
    for case_id, case in cases.items():
        columns = []
        if case.get("reference"):
            ref = case["reference"]
            columns.append(
                "<article class=ref><h4>Reference</h4>"
                + "".join(f"<h5>{esc(k)}</h5><ul>{''.join(f'<li>{esc(s)}</li>' for s in v)}</ul>" for k, v in ref.items() if v)
                + "</article>"
            )
        for model in order:
            result = results.get(model, {}).get(case_id)
            if not result:
                continue
            score = judged.get(case_id, {}).get(model)
            badge = (f"<p class=score>{' · '.join(f'{d[:5]} {score[d]}' for d in DIMENSIONS)}</p><p class=muted>{esc(score['comment'])}</p>"
                     + (f"<p class=bad>Invented: {esc('; '.join(score['invented_facts']))}</p>" if score["invented_facts"] else "")
                     if score else "")
            body = render_summary(result["summary"]) if result["summary"] else f"<p class=bad>{esc(result['error'] or 'no output')}</p>"
            columns.append(f"<article><h4>{esc(model)} <span class=muted>{result['seconds']:.0f} s</span></h4>{badge}{body}</article>")
        sections.append(
            f"<section><h3>{esc(case_id)} <span class=muted>{esc(case['source'])} · {esc(case['profile'])} · {len(case['transcript']):,} chars</span></h3>"
            f"<details><summary>Transcript</summary><pre>{esc(case['transcript'][:20000])}</pre></details>"
            f"<div class=grid>{''.join(columns)}</div></section>"
        )
    head_dims = "".join(f"<th>{d}</th>" for d in DIMENSIONS)
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Local Model Eval</title><style>
:root{{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--card:#f5f5f7;--bad:#c4302b;--accent:#0a66c2}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111;--fg:#f2f2f7;--muted:#98989d;--line:#2c2c2e;--card:#1c1c1e;--bad:#ff6961;--accent:#64a8ff}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1600px;margin:auto}}
table{{border-collapse:collapse;width:100%;overflow-x:auto;display:block}}th,td{{padding:6px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}}
th[scope=row],thead th:first-child{{text-align:left}}.muted{{color:var(--muted);font-weight:normal}}.bad{{color:var(--bad)}}.score{{color:var(--accent);font-weight:600;margin:0}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px}}article{{background:var(--card);border-radius:10px;padding:12px}}
article.ref{{outline:1px dashed var(--muted)}}h4{{margin:0 0 6px}}h5{{margin:10px 0 2px;color:var(--muted);font-size:12px;text-transform:uppercase}}
ul{{margin:0;padding-left:18px}}pre{{white-space:pre-wrap;font-size:12px;max-height:300px;overflow:auto}}section{{margin-top:32px}}
</style></head><body>
<h1>Local model eval</h1>
<p class=muted>Same Meeting Pilot prompts, Italian output, llama.cpp, {CONTEXT_TOKENS} token context. Judge: Claude Opus 5.5, blind, 1–5.</p>
<table><thead><tr><th>Model</th><th>Size</th><th>Valid JSON</th><th>All fields</th><th>Italian</th><th>Avg time</th><th>Out tok/s</th><th>Peak RAM</th>{head_dims}<th>Overall</th><th>Invented</th></tr></thead><tbody>{table}</tbody></table>
{''.join(sections)}
</body></html>"""


def render_summary(summary: dict[str, Any]) -> str:
    esc = html.escape
    parts = [f"<p><b>{esc(str(summary.get('title') or ''))}</b> <span class=muted>#{esc(str(summary.get('tag') or ''))}</span></p>",
             f"<p>{esc(str(summary.get('summary') or ''))}</p>"]
    for key in ("topics", "decisions", "action_items", "open_questions", "risks", "key_concepts", "assignments", "exam_hints", "review_questions", "references"):
        items = summary.get(key)
        if not items:
            continue
        rendered = []
        for item in items if isinstance(items, list) else [items]:
            if isinstance(item, dict):
                rendered.append(" — ".join(str(v) for v in item.values() if v not in (None, "", "open")))
            else:
                rendered.append(str(item))
        parts.append(f"<h5>{esc(key)}</h5><ul>{''.join(f'<li>{esc(r)}</li>' for r in rendered)}</ul>")
    return "".join(parts)


# --------------------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("prepare", help="build test cases from AMI, this Mac's meetings and custom/*.txt")
    p.add_argument("--ami", type=int, default=6, help="AMI meetings to include")
    p.add_argument("--app", type=int, default=3, help="already-processed meetings from ~/TeamsMeetings/done")
    p.set_defaults(func=prepare)

    p = sub.add_parser("run", help="download each model, serve it and summarize every case")
    p.add_argument("--models", help=f"comma-separated; default: {','.join(n for n, m in MODELS.items() if m['default'])}")
    p.add_argument("--cases", help="comma-separated case ids")
    p.add_argument("--llama-server", help="path to llama-server")
    p.add_argument("--no-json-mode", dest="json_mode", action="store_false", help="don't constrain output to JSON")
    p.add_argument("--force", action="store_true", help="redo cases that already have a result")
    p.add_argument("--server-args", default="", help='extra llama-server flags, e.g. "--presence-penalty 1.5"')
    p.add_argument("--label", help="save results as <model>+<label>, to compare settings side by side")
    p.set_defaults(func=run)

    p = sub.add_parser("judge", help="optional: blind 1-5 scoring with Claude (needs anthropic credentials)")
    p.add_argument("--cases", help="comma-separated case ids")
    p.add_argument("--include-private", action="store_true", help="also send this Mac's own and custom transcripts")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=judge)

    p = sub.add_parser("report", help="write Datasets/local_model_eval/report.html")
    p.set_defaults(func=report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
