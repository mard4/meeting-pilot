from __future__ import annotations

import json
from pathlib import Path

from meeting_pilot.artifacts import collect_artifacts
from meeting_pilot.config import Config
from meeting_pilot.pipeline import attach_slides_later
from meeting_pilot.publishing.journal_publisher import publish_to_journal
from meeting_pilot.slides.corrections import find_corrections, save_corrections
from meeting_pilot.slides.deck import slides_from_texts

DECK = slides_from_texts([
    "Orchestrazione dei container\nKubernetes e Docker\nIl control plane di Kubernetes",
    "Scheduling\nIl kube-scheduler assegna i Pod ai nodi",
    "Termodinamica\nEntropia e formula di Boltzmann",
])


def test_misheard_slide_terms_are_corrected() -> None:
    transcript = (
        "Oggi parliamo di Cubernetes e di come Kuber netes gestisce i container con Docker. "
        "Il modello di Bolzman spiega l'entropia."
    )

    assert find_corrections(transcript, DECK) == {
        "Cubernetes": "Kubernetes",
        "Bolzman": "Boltzmann",
        "Kuber netes": "Kubernetes",
    }


def test_a_word_capitalized_only_as_a_slide_title_keeps_the_sentence_case() -> None:
    deck = slides_from_texts(["Workspace\nSample docs instead of an empty screen"])

    assert find_corrections("You land in a sample work space.", deck) == {"work space": "workspace"}


def test_ordinary_words_and_inflections_are_left_alone() -> None:
    transcript = (
        "I modelli e i sistemi sono importanti, le persone parlano dei nodi. "
        "Lo scheduling è centrale e Docker Il resto no. Le entropie crescono."
    )

    assert find_corrections(transcript, DECK) == {}


def test_saved_corrections_apply_whenever_the_transcript_is_read(tmp_path: Path) -> None:
    (tmp_path / "sidecar" / "slides").mkdir(parents=True)
    (tmp_path / "audio.txt").write_text("Speaker 1: Cubernetes è ovunque", encoding="utf-8")
    (tmp_path / "fluidaudio_transcript.json").write_text(
        json.dumps({"segments": [{"speaker": "Speaker 1", "text": "Cubernetes è ovunque", "start": 0, "end": 2}]}),
        encoding="utf-8",
    )
    save_corrections(tmp_path, {"Cubernetes": "Kubernetes"})

    artifacts = collect_artifacts(tmp_path, tmp_path / "audio.m4a")

    assert artifacts.transcript_text == "Speaker 1: Kubernetes è ovunque"
    assert artifacts.millet_json["segments"][0]["text"] == "Kubernetes è ovunque"
    assert (tmp_path / "audio.txt").read_text(encoding="utf-8") == "Speaker 1: Cubernetes è ovunque"


def test_slides_added_later_replace_the_published_note(tmp_path: Path, monkeypatch) -> None:
    for key, value in {
        "MEETINGS_ROOT": str(tmp_path),
        "JOURNAL_ROOT": str(tmp_path / "Diary"),
        "PUBLISH_TARGETS": "journal",
        "SUMMARY_ENABLED": "false",
        "HOME": str(tmp_path / "home"),
    }.items():
        monkeypatch.setenv(key, value)
    config = Config.from_env()
    config.ensure_dirs()
    session = config.done_dir / "20261007-100000"
    session.mkdir()
    (session / "audio.txt").write_text(
        "Speaker 1: Il control plane di Cubernetes decide dove girano i container.\n"
        "Speaker 1: Il kube-scheduler assegna i Pod ai nodi.",
        encoding="utf-8",
    )
    (session / "meeting_metadata.json").write_text(json.dumps({"title": "Lezione 7"}), encoding="utf-8")
    first = publish_to_journal(config, collect_artifacts(session, session / "audio.m4a"))

    pdf_text = [
        "Orchestrazione dei container\nKubernetes e Docker\nIl control plane di Kubernetes",
        "Scheduling\nIl kube-scheduler assegna i Pod ai nodi",
    ]
    slides = session / "sidecar" / "slides"
    slides.mkdir(parents=True)
    (slides / "slides.json").write_text(
        json.dumps({"pages": [{"page": i, "text": t} for i, t in enumerate(pdf_text, 1)]}), encoding="utf-8"
    )

    attach_slides_later(config, session)

    receipt = json.loads((session / "journal_receipt.json").read_text(encoding="utf-8"))
    note = Path(receipt["path"]).read_text(encoding="utf-8")
    assert "Kubernetes decide" in note and "Cubernetes" not in note
    assert (session / "slide_alignment.json").exists()
    assert list((tmp_path / "Diary").rglob("*.md")) == [Path(receipt["path"])]
    assert (tmp_path / "home" / ".Trash" / Path(first["path"]).name).exists()
