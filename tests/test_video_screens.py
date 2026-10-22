"""Screens of an imported video, written by the app as a slide deck with screens.json."""
from __future__ import annotations

import json
from pathlib import Path

from meeting_pilot.artifacts import MeetingArtifacts
from meeting_pilot.slides import attach_slides
from meeting_pilot.slides.alignment import TranscriptUnit, align_by_time, retime_units, video_time, word_starts
from meeting_pilot.slides.deck import Screen, Slide, load_screens, slide_outline, slides_dir

TRANSCRIPT = (
    "Speaker 1: Hi, today we build an extension. First install Node from nodejs.org. "
    "Then open Visual Studio Code and create a folder. Now we run the extension in Live."
)


def _session(tmp_path: Path, screens: list[dict], words: list[float] | None = None) -> Path:
    session = tmp_path / "session"
    folder = slides_dir(session)
    folder.mkdir(parents=True)
    pages = [{"page": item["page"], "text": f"Screen text {item['page']}"} for item in screens]
    (folder / "slides.json").write_text(json.dumps({"source_name": "Tutorial.mp4", "pages": pages}), encoding="utf-8")
    (folder / "screens.json").write_text(json.dumps({"source": "video", "screens": screens}), encoding="utf-8")
    if words is not None:
        (session / "apple_transcriber").mkdir()
        (session / "apple_transcriber" / "mixed.words.json").write_text(
            json.dumps({"wordTimings": [{"word": "w", "startTime": start, "endTime": start + 0.4} for start in words]}),
            encoding="utf-8",
        )
    return session


def _artifacts(session: Path) -> MeetingArtifacts:
    # One segment for all of it, as Apple's transcriber gives a single speaker.
    segments = {"segments": [{"speaker": "Speaker 1", "start": 0.0, "end": 60.0, "text": TRANSCRIPT.split(": ", 1)[1]}]}
    return MeetingArtifacts(
        session_dir=session, audio_file=session / "audio.m4a", transcript_text=TRANSCRIPT,
        millet_json=segments, frontmatter={}, summary_markdown="", title="Tutorial",
    )


def test_screens_are_placed_by_when_they_were_visible(tmp_path: Path) -> None:
    # One timed word per transcript word, a second apart: the sentences start at words 0, 6, 11 and 20.
    words = [float(index) for index in range(27)]
    session = _session(tmp_path, [
        {"page": 1, "start": 0, "end": 6}, {"page": 2, "start": 6, "end": 11},
        {"page": 3, "start": 11, "end": 20}, {"page": 4, "start": 20, "end": 60},
    ], words)
    artifacts = _artifacts(session)
    attach_slides(artifacts)

    sections = [(section.page, section.title, " ".join(unit.text for unit in section.units)) for section in artifacts.slide_sections]
    assert [page for page, _, _ in sections] == [1, 2, 3, 4]
    assert sections[1][2].startswith("First install Node")
    assert sections[2][2].startswith("Then open Visual Studio Code")
    assert sections[3][2].startswith("Now we run")
    assert sections[1][1] == "0:06", "a screen is named by its moment, not its first line of text"
    assert artifacts.slide_screens and artifacts.slide_screens[0] == Screen(page=1, start=0.0, end=6.0)


def test_a_screen_nobody_spoke_over_keeps_its_section() -> None:
    slides = [Slide(page=page, title=f"t{page}", text="") for page in (1, 2, 3)]
    units = [TranscriptUnit(text="hello there", start=1.0), TranscriptUnit(text="and later", start=25.0)]
    screens = [Screen(1, 0, 10), Screen(2, 10, 20), Screen(3, 20, 40)]
    sections = align_by_time(slides, units, screens)
    assert [len(section.units) for section in sections] == [1, 0, 1]


def test_speech_before_the_first_screen_goes_to_it() -> None:
    slides = [Slide(page=1, title="", text=""), Slide(page=2, title="", text="")]
    sections = align_by_time(slides, [TranscriptUnit(text="intro", start=0.5)], [Screen(1, 3, 10), Screen(2, 10, 20)])
    assert [len(section.units) for section in sections] == [1, 0]


def test_units_get_their_start_from_the_word_timings_by_their_place() -> None:
    units = [TranscriptUnit(text="one two"), TranscriptUnit(text="three four five six"), TranscriptUnit(text="seven eight")]
    retime_units(units, [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0])
    assert [unit.start for unit in units] == [0.0, 2.0, 6.0]


def test_word_timings_come_from_apple_or_fluidaudio(tmp_path: Path) -> None:
    assert word_starts(tmp_path) == []
    (tmp_path / "fluidaudio_asr.json").write_text(json.dumps({"wordTimings": [{"word": "a", "startTime": 1.5}]}), encoding="utf-8")
    assert word_starts(tmp_path) == [1.5]


def test_without_word_timings_screens_fall_back_to_matching_words(tmp_path: Path) -> None:
    session = _session(tmp_path, [{"page": 1, "start": 0, "end": 30}, {"page": 2, "start": 30, "end": 60}])
    artifacts = _artifacts(session)
    attach_slides(artifacts)
    # The screens' text shares no words with the transcript, so the word alignment gives up.
    assert artifacts.slide_sections == []
    assert len(artifacts.slides) == 2


def test_slides_from_a_pdf_have_no_screens(tmp_path: Path) -> None:
    assert load_screens(tmp_path) == []


def test_the_outline_of_many_screens_covers_the_whole_video() -> None:
    slides = [Slide(page=page, title=f"Screen {page}", text=f"Screen {page} " + "code " * 60) for page in range(1, 801)]
    outline = slide_outline(slides, spread=True)
    assert len(outline) <= 20_000 + 200
    assert "Slide 1:" in outline and "Slide 800:" in outline, "first and last screen both reach the summary"
    assert "screens shown, evenly through the video" in outline
    compact = slide_outline(slides, compact=True, spread=True)
    assert len(compact) <= 1_500 + 100 and "Slide 800:" in compact


def test_a_few_screens_keep_all_their_text_in_the_outline() -> None:
    slides = [Slide(page=page, title=f"Screen {page}", text=f"Screen {page} details {page}") for page in range(1, 4)]
    outline = slide_outline(slides, spread=True)
    assert outline.count("\n") == 2 and "details 3" in outline


def test_video_time() -> None:
    assert [video_time(seconds) for seconds in (0, 65.9, 3725)] == ["0:00", "1:05", "1:02:05"]
