from __future__ import annotations

import json
from pathlib import Path


TEAMS_SPEAKERS_FILE = "teams_speakers.json"
# A diarized speaker takes a Teams name only when that participant's speaking border was
# lit for most of the time the speaker talked, and for long enough to not be a fluke.
MIN_OVERLAP_SHARE = 0.5
MIN_OVERLAP_SECONDS = 2.0


def name_speakers_from_teams(
    session_dir: Path,
    grouped: list[dict[str, object]],
    speakers: list[dict[str, str]],
) -> tuple[list[dict[str, object]], list[dict[str, str]]]:
    """Replace FluidAudio's "Speaker N" labels with the Teams participants talking at the same time.

    `teams_speakers.json` is written by the macOS app's TeamsSpeakerTracker; labels it
    can't vouch for (including the user's own "me" label) are left untouched.
    """
    talking = _read_teams_segments(session_dir / "sidecar" / TEAMS_SPEAKERS_FILE)
    if not talking or not grouped:
        return grouped, speakers

    candidates = {speaker["label"] for speaker in speakers if speaker.get("id") != "me"}
    renames = {}
    for speaker_label in candidates:
        spans = [
            (float(segment["start"]), float(segment["end"]))
            for segment in grouped
            if segment["speaker"] == speaker_label
        ]
        spoken = sum(end - start for start, end in spans)
        overlaps = {
            name: sum(_overlap(span, window) for span in spans for window in windows)
            for name, windows in talking.items()
        }
        name, overlap = max(overlaps.items(), key=lambda item: item[1])
        if overlap >= MIN_OVERLAP_SECONDS and spoken > 0 and overlap / spoken >= MIN_OVERLAP_SHARE:
            renames[speaker_label] = name
    if not renames:
        return grouped, speakers

    named: list[dict[str, object]] = []
    for segment in grouped:
        speaker_label = renames.get(str(segment["speaker"]), segment["speaker"])
        if named and named[-1]["speaker"] == speaker_label:
            named[-1]["text"] = f"{named[-1]['text']} {segment['text']}"
            named[-1]["end"] = segment["end"]
        else:
            named.append({**segment, "speaker": speaker_label})

    renamed_speakers: list[dict[str, str]] = []
    for speaker in speakers:
        if speaker["label"] in renames:
            speaker = {**speaker, "label": renames[speaker["label"]], "source": "teams"}
        if all(existing["label"] != speaker["label"] for existing in renamed_speakers):
            renamed_speakers.append(speaker)
    return named, renamed_speakers


def _read_teams_segments(path: Path) -> dict[str, list[tuple[float, float]]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    talking: dict[str, list[tuple[float, float]]] = {}
    for segment in payload.get("segments", []) if isinstance(payload, dict) else []:
        if not isinstance(segment, dict):
            continue
        name = str(segment.get("name") or "").strip()
        try:
            start, end = float(segment["start"]), float(segment["end"])
        except (KeyError, TypeError, ValueError):
            continue
        if name and end > start:
            talking.setdefault(name, []).append((start, end))
    return talking


def _overlap(first: tuple[float, float], second: tuple[float, float]) -> float:
    return max(0.0, min(first[1], second[1]) - max(first[0], second[0]))
