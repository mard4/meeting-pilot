from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

from meeting_pilot.platforms.teams.speaker_names import name_speakers_from_teams
from meeting_pilot.summarization.summary_templates import summary_guidance


def _write_teams_speakers(session: Path, segments: list[dict]) -> None:
    sidecar = session / "sidecar"
    sidecar.mkdir(parents=True)
    (sidecar / "teams_speakers.json").write_text(
        json.dumps({"source": "teams_accessibility", "segments": segments}), encoding="utf-8"
    )


def test_speakers_take_the_name_of_the_teams_tile_lit_while_they_talk(tmp_path: Path) -> None:
    _write_teams_speakers(
        tmp_path,
        [
            {"name": "Giulia Bianchi", "start": 0.2, "end": 6.1},
            {"name": "Marco Rossi", "start": 9.8, "end": 15.0},
        ],
    )
    grouped = [
        {"speaker": "Speaker 1", "start": 0.5, "end": 6.0, "text": "Buongiorno a tutti."},
        {"speaker": "Io", "start": 6.2, "end": 9.5, "text": "Ciao."},
        {"speaker": "Speaker 2", "start": 10.0, "end": 14.5, "text": "Parto io con gli aggiornamenti."},
    ]
    speakers = [
        {"id": "me", "label": "Io"},
        {"id": "S1", "label": "Speaker 1"},
        {"id": "S2", "label": "Speaker 2"},
    ]

    named, named_speakers = name_speakers_from_teams(tmp_path, grouped, speakers)

    assert [segment["speaker"] for segment in named] == ["Giulia Bianchi", "Io", "Marco Rossi"]
    assert named_speakers == [
        {"id": "me", "label": "Io"},
        {"id": "S1", "label": "Giulia Bianchi", "source": "teams"},
        {"id": "S2", "label": "Marco Rossi", "source": "teams"},
    ]


def test_speakers_without_enough_teams_overlap_keep_their_label(tmp_path: Path) -> None:
    _write_teams_speakers(tmp_path, [{"name": "Giulia Bianchi", "start": 0.0, "end": 1.0}])
    grouped = [{"speaker": "Speaker 1", "start": 0.0, "end": 10.0, "text": "Un lungo intervento."}]
    speakers = [{"id": "S1", "label": "Speaker 1"}]

    assert name_speakers_from_teams(tmp_path, grouped, speakers) == (grouped, speakers)


def test_split_clusters_of_the_same_person_are_merged(tmp_path: Path) -> None:
    _write_teams_speakers(tmp_path, [{"name": "Giulia Bianchi", "start": 0.0, "end": 12.0}])
    grouped = [
        {"speaker": "Speaker 1", "start": 0.0, "end": 5.0, "text": "Prima parte"},
        {"speaker": "Speaker 2", "start": 5.5, "end": 11.0, "text": "seconda parte."},
    ]
    speakers = [{"id": "S1", "label": "Speaker 1"}, {"id": "S2", "label": "Speaker 2"}]

    named, named_speakers = name_speakers_from_teams(tmp_path, grouped, speakers)

    assert named == [{"speaker": "Giulia Bianchi", "start": 0.0, "end": 11.0, "text": "Prima parte seconda parte."}]
    assert named_speakers == [{"id": "S1", "label": "Giulia Bianchi", "source": "teams"}]


def test_without_teams_data_the_transcript_is_unchanged(tmp_path: Path) -> None:
    grouped = [{"speaker": "Speaker 1", "start": 0.0, "end": 3.0, "text": "Ciao."}]
    speakers = [{"id": "S1", "label": "Speaker 1"}]

    assert name_speakers_from_teams(tmp_path, grouped, speakers) == (grouped, speakers)


def test_summary_guidance_tells_the_model_which_labels_are_real_names(tmp_path: Path) -> None:
    artifacts = SimpleNamespace(
        session_dir=tmp_path,
        meeting_metadata={},
        title="Allineamento",
        user_notes="",
        millet_json={"speakers": [{"id": "S1", "label": "Giulia Bianchi", "source": "teams"}]},
    )
    config = SimpleNamespace(summary_template="general", env_file=tmp_path / ".env")

    guidance = summary_guidance(config, artifacts)

    assert "Giulia Bianchi" in guidance
    assert "real participant names" in guidance
