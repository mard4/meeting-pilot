from __future__ import annotations

import json
import shutil
from pathlib import Path
from types import SimpleNamespace

import pytest

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.config import Config
from meeting_pilot.pipeline import process_audio
from meeting_pilot.slides import attach_slides
from meeting_pilot.slides.alignment import SlideSection, TranscriptUnit, align_transcript, transcript_units
from meeting_pilot.slides.deck import load_slides, slide_outline, slide_terms, slides_from_texts
from meeting_pilot.summarization.summary_templates import summary_guidance
from meeting_pilot.transcription.apple import _glossary_file
from meeting_pilot.transcription.session import sidecar_dir

DECK = [
    "Termodinamica: introduzione\nSistema e ambiente\nScambi di energia come calore",
    "Primo principio\nConservazione dell'energia interna\nVariazione = calore assorbito meno lavoro",
    "Entropia\nMisura del disordine\nMicrostati e formula di Boltzmann\nProcessi irreversibili",
    "Ciclo di Carnot\nRendimento della macchina termica\nDue isoterme e due adiabatiche tra sorgenti",
]

TALK = {
    1: "Partiamo dal sistema termodinamico e dal suo ambiente: il sistema scambia energia con l'ambiente sotto forma di calore.",
    2: "Il primo principio dice che l'energia interna si conserva: la sua variazione è il calore assorbito meno il lavoro compiuto.",
    3: "L'entropia misura il disordine: Boltzmann la lega al numero di microstati, e nei processi irreversibili l'entropia cresce.",
    4: "Il ciclo di Carnot usa due isoterme e due adiabatiche tra due sorgenti, e il suo rendimento è il massimo per una macchina termica.",
}


def _lecture(order: list[int], repeats: int = 4) -> str:
    """One speaker line per sentence, talking about each slide in `order`."""
    return "\n".join(f"Speaker 1: {TALK[page]}" for page in order for _ in range(repeats))


def test_slide_titles_come_from_the_first_line_and_text_is_tidied() -> None:
    slides = slides_from_texts(["  Entropia \n\n  Misura   del disordine ", "", "Carnot"])

    assert [slide.title for slide in slides] == ["Entropia", "", "Carnot"]
    assert slides[0].text == "Entropia\nMisura del disordine"
    assert [slide.page for slide in slides] == [1, 2, 3]


def test_lecture_that_follows_the_slides_is_split_into_one_section_per_slide() -> None:
    sections = align_transcript(slides_from_texts(DECK), _lecture([1, 2, 3, 4]))

    assert [section.page for section in sections] == [1, 2, 3, 4]
    assert sections[2].title == "Entropia"
    assert "Boltzmann" in " ".join(sections[2].lines())


def test_going_back_to_an_earlier_slide_is_followed() -> None:
    sections = align_transcript(slides_from_texts(DECK), _lecture([1, 2, 3, 2, 4]))

    assert [section.page for section in sections] == [1, 2, 3, 2, 4]


def test_a_slide_discussed_only_briefly_keeps_its_own_section() -> None:
    sections = align_transcript(slides_from_texts(DECK), "\n".join(
        [f"Speaker 1: {TALK[1]}"] * 5 + [f"Speaker 1: {TALK[2]}"] * 2 + [f"Speaker 1: {TALK[3]}"] * 5
    ))

    assert [section.page for section in sections] == [1, 2, 3]


def test_slides_unrelated_to_what_was_said_give_no_sections() -> None:
    transcript = _lecture([1, 2, 3, 4])
    unrelated = slides_from_texts(["Marketing plan\nQ4 budget and campaign channels", "Hiring\nOpen roles and interviews"])

    assert align_transcript(unrelated, transcript) == []
    assert align_transcript([], transcript) == []
    assert align_transcript(slides_from_texts(DECK), "") == []


def test_sections_start_when_their_first_sentence_was_spoken() -> None:
    lines = [f"Speaker 1: {TALK[page]}" for page in (1, 1, 1, 1, 3, 3, 3, 3)]
    segments = [{"speaker": "Speaker 1", "start": index * 10.0, "end": index * 10.0 + 9.0} for index in range(len(lines))]

    sections = align_transcript(slides_from_texts(DECK), "\n".join(lines), segments)

    assert [section.page for section in sections] == [1, 3]
    assert sections[0].start == 0.0
    assert sections[1].start == 40.0


def test_speakers_are_kept_only_when_segments_confirm_them() -> None:
    transcript = "Docente: Oggi parliamo di entropia. Poi vediamo il Carnot.\nStudente: Una domanda."
    segments = [
        {"speaker": "Docente", "start": 0.0, "end": 8.0},
        {"speaker": "Studente", "start": 8.0, "end": 10.0},
    ]

    units = transcript_units(transcript, segments)
    assert [(unit.speaker, unit.text) for unit in units] == [
        ("Docente", "Oggi parliamo di entropia."),
        ("Docente", "Poi vediamo il Carnot."),
        ("Studente", "Una domanda."),
    ]
    assert units[1].start == 4.0
    assert all(unit.speaker is None for unit in transcript_units("Nota: questa frase non ha un parlante."))


def test_section_lines_join_consecutive_sentences_of_the_same_speaker() -> None:
    section = SlideSection(page=1, title="x", units=[
        TranscriptUnit("Prima frase.", "Docente", starts_line=True),
        TranscriptUnit("Seconda frase.", "Docente"),
        TranscriptUnit("Domanda?", "Studente", starts_line=True),
        TranscriptUnit("Un paragrafo.", starts_line=True),
        TranscriptUnit("Che continua."),
        TranscriptUnit("Un altro paragrafo.", starts_line=True),
    ])

    assert section.lines() == [
        "Docente: Prima frase. Seconda frase.",
        "Studente: Domanda?",
        "Un paragrafo. Che continua.",
        "Un altro paragrafo.",
    ]


def test_outline_lists_slides_with_text_or_only_titles_for_the_on_device_model() -> None:
    slides = slides_from_texts(DECK)

    full = slide_outline(slides)
    assert full.splitlines()[2].startswith("Slide 3: Entropia — Misura del disordine")
    compact = slide_outline(slides, compact=True)
    assert compact.splitlines() == [
        "Slide 1: Termodinamica: introduzione",
        "Slide 2: Primo principio",
        "Slide 3: Entropia",
        "Slide 4: Ciclo di Carnot",
    ]
    many = slides_from_texts([f"Titolo {index}\n" + "parola " * 150 for index in range(400)])
    assert slide_outline(many).splitlines()[-1].startswith("(slides ")


def test_slide_terms_are_names_and_acronyms_not_words_that_start_a_bullet() -> None:
    slides = slides_from_texts(["Protocolli\nIl modello ISO/OSI e TCP\nRouting con OSPF di Dijkstra\nLivello 3 e IPv6"])

    terms = slide_terms(slides)

    assert {"Protocolli", "ISO/OSI", "TCP", "OSPF", "Dijkstra", "IPv6"} <= set(terms)
    assert "Routing" not in terms and "Livello" not in terms


def _make_pdf(path: Path, pages: list[list[str]]) -> None:
    """A minimal PDF with one text line per entry, readable by PDFKit."""
    objects = [b"", b"", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    kids = []
    for lines in pages:
        body = b"BT /F1 18 Tf 50 750 Td 22 TL " + b" ".join(b"(" + line.encode("latin-1") + b") Tj T*" for line in lines) + b" ET"
        objects.append(b"<< /Length %d >>\nstream\n" % len(body) + body + b"\nendstream")
        objects.append(
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R "
            b"/Resources << /Font << /F1 3 0 R >> >> >>" % len(objects)
        )
        kids.append(len(objects))
    objects[0] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objects[1] = b"<< /Type /Pages /Kids [" + b" ".join(b"%d 0 R" % kid for kid in kids) + b"] /Count %d >>" % len(kids)
    output = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(output))
        output += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(output)
    output += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    output += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    output += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    path.write_bytes(bytes(output))


@pytest.mark.skipif(shutil.which("osascript") is None, reason="PDFKit is read through macOS osascript")
def test_a_pdf_without_extracted_text_is_read_with_pdfkit(tmp_path: Path) -> None:
    folder = tmp_path / "sidecar" / "slides"
    folder.mkdir(parents=True)
    _make_pdf(folder / "slides.pdf", [["Entropia", "Misura del disordine"], ["Ciclo di Carnot"]])

    slides = load_slides(tmp_path)

    assert [(slide.page, slide.title) for slide in slides] == [(1, "Entropia"), (2, "Ciclo di Carnot")]
    saved = json.loads((folder / "slides.json").read_text(encoding="utf-8"))
    assert saved["pages"][0]["text"].startswith("Entropia")


def test_text_extracted_by_the_app_is_used_as_it_is(tmp_path: Path) -> None:
    folder = tmp_path / "sidecar" / "slides"
    folder.mkdir(parents=True)
    (folder / "slides.json").write_text(json.dumps({"pages": [{"page": 1, "text": "Testo da OCR"}]}), encoding="utf-8")

    assert [slide.title for slide in load_slides(tmp_path)] == ["Testo da OCR"]
    assert load_slides(tmp_path / "nothing") == []


def _session_with_slides(tmp_path: Path, texts: list[str]) -> Path:
    folder = tmp_path / "sidecar" / "slides"
    folder.mkdir(parents=True)
    (folder / "slides.json").write_text(
        json.dumps({"pages": [{"page": i, "text": t} for i, t in enumerate(texts, 1)]}), encoding="utf-8"
    )
    return tmp_path


def test_attach_slides_saves_where_each_slide_was_shown(tmp_path: Path) -> None:
    session = _session_with_slides(tmp_path, DECK)
    artifacts = MeetingArtifacts(session_dir=session, audio_file=session / "audio.m4a", title="x",
                                 transcript_text=_lecture([1, 2, 3, 4]))

    attach_slides(artifacts)

    assert len(artifacts.slides) == 4
    saved = json.loads((session / "slide_alignment.json").read_text(encoding="utf-8"))
    assert [section["page"] for section in saved["sections"]] == [1, 2, 3, 4]
    assert saved["sections"][3]["title"] == "Ciclo di Carnot"


def test_summary_is_told_about_the_slides(tmp_path: Path) -> None:
    session = _session_with_slides(tmp_path, DECK)
    artifacts = MeetingArtifacts(session_dir=session, audio_file=session / "audio.m4a", title="x", transcript_text="...")
    attach_slides(artifacts)

    local = summary_guidance(SimpleNamespace(summary_template="auto", summary_provider_mode="local"), artifacts)
    on_device = summary_guidance(SimpleNamespace(summary_template="auto", summary_provider_mode="apple"), artifacts)

    assert "(slide N)" in local
    assert "Slide 2: Primo principio — Conservazione" in local
    assert "Slide 2: Primo principio\n" in on_device and "Conservazione" not in on_device
    assert "Slide" not in summary_guidance(
        SimpleNamespace(summary_template="auto", summary_provider_mode="local"),
        MeetingArtifacts(session_dir=tmp_path / "none", audio_file=tmp_path / "a.m4a", title="x"),
    )


def test_apple_transcription_favours_terms_from_the_slides(tmp_path: Path, monkeypatch) -> None:
    glossary = tmp_path / "glossary.txt"
    glossary.write_text("Meeting Pilot, meeting pilota\n", encoding="utf-8")
    monkeypatch.setenv("BUSINESS_GLOSSARY_FILE", str(glossary))

    assert _glossary_file(tmp_path / "no-slides") == str(glossary)

    session = _session_with_slides(tmp_path / "lecture", ["Reti\nIl protocollo TCP e OSPF"])
    terms = Path(_glossary_file(session)).read_text(encoding="utf-8").splitlines()
    assert terms[0] == "Meeting Pilot"
    assert {"TCP", "OSPF", "Reti"} <= set(terms)


def test_imported_lecture_with_slides_goes_through_the_pipeline(tmp_path: Path, monkeypatch) -> None:
    for key, value in {
        "MEETINGS_ROOT": str(tmp_path),
        "JOURNAL_ROOT": str(tmp_path / "Diary"),
        "PUBLISH_TARGETS": "journal",
        "SUMMARY_ENABLED": "false",
        "CALENDAR_METADATA_ENABLED": "false",
        "TRANSCRIPTION_PROVIDER": "fluid",
    }.items():
        monkeypatch.setenv(key, value)
    config = Config.from_env()
    config.ensure_dirs()
    source = config.inbox_audio_dir / "Meeting Pilot - 2026-09-28 10-00-00 - Fisica.m4a"
    source.write_bytes(b"audio")
    sidecar = sidecar_dir(source)
    (sidecar / "slides").mkdir(parents=True)
    (sidecar / "recording.json").write_text(json.dumps({"call": False, "origin": "import"}), encoding="utf-8")
    (sidecar / "slides" / "slides.json").write_text(
        json.dumps({"pages": [{"page": i, "text": t} for i, t in enumerate(DECK, 1)]}), encoding="utf-8"
    )

    def transcribe(_config: Config, audio_file: Path) -> None:
        (audio_file.parent / "audio.txt").write_text(_lecture([1, 2, 3, 4]), encoding="utf-8")

    monkeypatch.setattr("meeting_pilot.pipeline.validate_audio_file", lambda _path: None)
    monkeypatch.setattr("meeting_pilot.pipeline.run_fluid_audio", transcribe)
    session = process_audio(config, source)

    saved = json.loads((session / "slide_alignment.json").read_text(encoding="utf-8"))
    assert [section["page"] for section in saved["sections"]] == [1, 2, 3, 4]


def test_fast_slide_sequence_matches_trying_every_move() -> None:
    import random

    from meeting_pilot.slides import alignment

    def brute_force(scores):
        pages = len(scores[0])
        totals = [scores[0][page] - alignment.START_COST * page for page in range(pages)]
        for row in scores[1:]:
            totals = [
                max(totals[before] - alignment._move_cost(before, page) for before in range(pages)) + row[page]
                for page in range(pages)
            ]
        return max(totals)

    def path_total(scores, path):
        total = scores[0][path[0]] - alignment.START_COST * path[0]
        for step in range(1, len(path)):
            total += scores[step][path[step]] - alignment._move_cost(path[step - 1], path[step])
        return total

    generator = random.Random(7)
    for _ in range(200):
        pages, steps = generator.randint(1, 7), generator.randint(1, 12)
        scores = [[generator.random() for _ in range(pages)] for _ in range(steps)]
        path = alignment._best_path(scores)
        assert len(path) == steps
        assert abs(path_total(scores, path) - brute_force(scores)) < 1e-9


def test_meeting_chat_can_answer_from_the_slides(tmp_path: Path) -> None:
    from meeting_pilot.chat.meeting_chat import _documents_from_done_dir, _meeting_documents

    session = tmp_path / "done" / "20260928-100000-fisica"
    _session_with_slides(session, ["Ciclo di Carnot\nRendimento = 1 - Tc/Th"])
    (session / "audio.txt").write_text("Oggi parliamo del ciclo.", encoding="utf-8")
    (session / "omlx_summary.json").write_text(json.dumps({"title": "Fisica", "summary": "Lezione."}), encoding="utf-8")
    (session / "journal_receipt.json").write_text(json.dumps({"path": str(tmp_path / "note.md")}), encoding="utf-8")

    done = _documents_from_done_dir(tmp_path / "done")
    assert done and all("Slide 1: Ciclo di Carnot Rendimento = 1 - Tc/Th" in document.text for document in done)

    config = SimpleNamespace(journal_root=tmp_path / "Diary", done_dir=tmp_path / "done")
    assert any("Rendimento = 1 - Tc/Th" in document.text for document in _meeting_documents(config))


def test_key_concepts_cite_the_slide_the_summary_names(tmp_path: Path) -> None:
    from meeting_pilot.slides import cite_slides

    artifacts = MeetingArtifacts(session_dir=tmp_path, audio_file=tmp_path / "a.m4a", title="x")
    artifacts.slides = slides_from_texts(DECK)
    artifacts.omlx_summary = {"key_concepts": [
        {"term": "Entropia", "explanation": "Misura del disordine.", "slide": 3},
        {"term": "Carnot", "explanation": "Rendimento massimo.", "slide": "slide 4"},
        {"term": "Calore", "explanation": "Energia scambiata.", "slide": None},
        {"term": "Altro", "explanation": "Non sulle slide.", "slide": 12},
    ]}

    cite_slides(artifacts, "it")
    cite_slides(artifacts, "it")

    explanations = [concept["explanation"] for concept in artifacts.omlx_summary["key_concepts"]]
    assert explanations == [
        "Misura del disordine. (Slide 3)",
        "Rendimento massimo. (Slide 4)",
        "Energia scambiata.",
        "Non sulle slide.",
    ]
    artifacts.omlx_summary["key_concepts"][0]["explanation"] = "Misura del disordine."
    cite_slides(artifacts, "de")
    assert artifacts.omlx_summary["key_concepts"][0]["explanation"] == "Misura del disordine. (Folie 3)"


def test_lecture_summaries_ask_for_the_slide_of_each_key_concept(tmp_path: Path) -> None:
    from meeting_pilot.summarization.omlx_client import _lecture_request

    _task, schema = _lecture_request("Italian")
    assert "slide" in schema["key_concepts"][0]

    session = _session_with_slides(tmp_path, DECK)
    artifacts = MeetingArtifacts(session_dir=session, audio_file=session / "a.m4a", title="x", transcript_text="...")
    attach_slides(artifacts)
    guidance = summary_guidance(SimpleNamespace(summary_template="auto", summary_provider_mode="api"), artifacts)
    assert "in its slide field" in guidance
