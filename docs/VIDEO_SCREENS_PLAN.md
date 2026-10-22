# Screens from videos: plan

Status: plan agreed, 2026-10-22 (decisions in §8). Phase 1 built on `feature/video-screens`.

## 1. What it is for

A tutorial, a screen recording or a recorded lecture shows on screen what the speaker
talks about: slides, code, an app's window, a diagram. Today an imported video keeps only
its audio, unless the user also adds the slides as a PDF. With this feature Meeting Pilot
takes a picture of each screen the video shows and places it next to what was said while
it was visible. The Diary, Obsidian and Notion show it the way they show slides now.

It is the "slide-change detection from video frames" left for later in the file import
plan.

## 2. Reuse: screens become a slide deck

Slides already have everything downstream:

- `sidecar/slides/` in the session with `slides.pdf` (one page per slide) and `slides.json`
  (each page's text), written by `SlideDeck.write` in the app.
- `slides/deck.py` reads them (`load_slides`, `slide_images` draws a JPEG per page).
- `slides/alignment.py` decides which slide was shown during each part of the transcript
  and writes `slide_alignment.json`.
- The summary follows the slides (`slide_outline`, `cite_slides`), slide words correct the
  transcript (`corrections.py`), and every publisher shows "transcript by slide" with
  pictures.

So the screens of a video are written **as a slide deck**: a PDF with one page per screen
and the text Vision reads on each. Everything above works unchanged. One file is new:
`sidecar/slides/screens.json`, with when each screen was visible:

```json
{"source": "video", "screens": [{"page": 1, "start": 0.0, "end": 42.5}, {"page": 2, "start": 42.5, "end": 97.0}]}
```

## 3. Finding the screens (Swift, at import)

In `MediaImporter`, after the audio is in place and before the files move to the inbox.
It uses AVFoundation and Vision, as slide OCR already does.

1. **Sample** one frame per second with `AVAssetImageGenerator`, scaled down to 160 px and
   in grayscale, with hardware decoding. A one-hour video gives 3,600 small frames, read
   in roughly a minute.
2. **Measure change** between consecutive frames: the share of 8×8 cells whose mean
   brightness changed by more than a threshold. A small moving face in a corner (webcam
   overlay) or a moving cursor changes few cells. A new slide, a switched window or a
   new page of code changes many.
3. **Cut screens** where the change is large, and keep a screen only if it stays still for
   at least about 3 seconds (`MIN_SCREEN_SECONDS`). Transitions, fades and fast scrolling
   are not screens of their own.
4. **Pick the picture** near the *end* of each screen, not the start. In a tutorial the
   screen fills up while the speaker works (code typed, bullets appearing), so the last
   still moment is the complete one. Its time range is the screen's start and end.
5. **Merge builds.** A slide whose bullets appear one by one gives several screens in a row
   where each one's text contains the previous one's. They become one screen (the last),
   with the time range of all of them.
6. **Throw away faces and empty frames.** Vision face detection: a frame where a face takes
   up a large part of the picture is the speaker on camera, not a screen. A frame that is
   almost one colour (black between scenes) is not a screen either.
7. **Decide whether it is worth it.** Under `MIN_SCREENS` (about 3), or when most of the
   video is the speaker's face, the video gets no screens and imports as it does today.
   The ceiling is `MAX_SCREENS = 1000`: a safety net against a video that changes every few
   seconds for hours, not a limit a normal video meets. If it is reached, the change
   threshold rises until the screens fit.
8. **Write the deck**: full-size frames (1280 px wide, JPEG 0.75) into `slides.pdf` with
   PDFKit, Vision text per page into `slides.json`, times into `screens.json`, all
   through `SlideDeck.write`'s folder.

Code: `Sources/Import/VideoScreens.swift`, with the detection steps as functions
that are testable on synthetic frames.

## 4. Videos from YouTube

The YouTube import downloads only the audio (`bestaudio[ext=m4a]`). For screens it also
downloads the picture, as a separate video-only stream. The two never need merging, so
there is still no ffmpeg:

- `bestvideo[ext=mp4][vcodec^=avc1][height<=720]`. H.264 in MP4 is what AVFoundation reads
  on every Mac; VP9 and AV1 WebM are not. 720p reads slides and most code; a one-hour
  tutorial is roughly 150–300 MB.
- The download shows in the import progress as a second part, after the audio.
- **The video is deleted** once the screens are taken, unless Settings → Import → "Keep
  downloaded videos" is on (off by default). Then AVFoundation puts the video stream and
  the audio together into one playable `.mp4` (`AVMutableComposition`, exported as
  passthrough, still without ffmpeg) in `~/Movies/Meeting Pilot/`, and the note links it as
  `original_path`, the way it links a video imported from the Mac.

## 5. Placing screens along the transcript (Python)

When `screens.json` exists, `attach_slides` places screens **by time** instead of by words.
The time is known, so guessing from words would only add mistakes:

- Every transcript unit needs a start time. Segments are not enough: with one speaker
  Apple's transcriber returns a single segment for minutes of speech (the 4.5-minute
  tutorial imported on 2026-10-22 has one). Word timings are in
  `apple_transcriber/mixed.words.json` and in FluidAudio's output. `transcript_units` gets
  each unit's start from its first word.
- A unit belongs to the screen visible when it starts. Screens nobody spoke over still get
  a section with their picture and no lines, because a tutorial often shows a result in
  silence.
- Without word timings (an old transcriber, a transcript pasted in), it falls back to
  today's alignment by words, using the screens' Vision text.

**Context of the summary model.** Screens are many more than slides, and each one's text
goes into the summary prompt through `slide_outline`. It already has a budget (1,500
characters for the on-device model, 20,000 for the others), but it fills the budget from
the first slide and drops the rest, which would cut the second half of a long video.
For screens the budget is spread over the whole video instead: shorter text per screen,
and above a few hundred screens one line every few screens, chosen evenly in time. The
summary covers the whole video at any count. The chat and the MCP server search screens
the way they search slides, in passages, so their size doesn't matter there.

New: `align_by_time(slides, units, screens)` in `slides/alignment.py`, used by
`attach_slides` when `screens.json` is there. The rest of the pipeline is untouched.

## 6. In the app

- Import sheet, on each video row: a toggle "Schermate del video" with the film-frames
  icon, **on by default**. Choosing slides or notes for the row turns it off, because
  slides from the author beat pictures of them.
- Import progress: "Schermate: 12 trovate" once detection ends, so a long video doesn't
  look stuck.
- YouTube from the import sheet and from the browser extension: same default. The
  extension imports with the defaults, so it gets screens too.
- Diary: nothing new. Screens show where slides show.
- Settings → Import: the default for the toggle, for people who import mostly podcasts, and
  "Keep downloaded videos" (§4).

## 7. Phases

| Phase | Content | Size |
|---|---|---|
| 1. Local videos | `VideoScreens.swift` (sampling, change, still screens, faces, builds), PDF + OCR + `screens.json`, `align_by_time` with word timings, toggle in the import sheet | about 1 week |
| 2. YouTube | Video-only stream download next to the audio, progress in two parts, default for the extension | 2–3 days |
| 3. Tuning on real videos | A small set of real videos (slides lecture, code tutorial, app demo, talking head with slides inset, webinar) with expected screen counts as a regression test; thresholds set from it | 2–3 days |
| 4. Later | Screens for a video already imported (needs the video again), a "jump to this moment" link from a screen to the video's time (YouTube `&t=`), screens in the live sidebar for screen sharing in calls | — |

## 8. Decisions (taken 2026-10-22)

1. **On by default for every video.** Detection gives up by itself on a talking head, so a
   podcast-like video imports as today.
2. **720p** for YouTube.
3. **Ceiling: 1000 screens** (`MAX_SCREENS`). Pictures are not what fills the model's
   context; their text is, and the summary budget is spread over the video (§5).
4. **The downloaded video is not kept**, unless the user turns on "Keep downloaded videos"
   in Settings (off by default, §4).

## 9. Risks

- **Talking-head video with slides in a small inset:** the inset changes few cells. A
  later refinement can find the inset (the area that changes at slide changes) and
  measure inside it.
- **Constantly moving content** (a game, live coding with scrolling): few still moments,
  so few screens. Better few than one per second.
- **Notion page size:** hundreds of pictures make a heavy page and many API calls (Notion
  takes at most 100 blocks per request, so the publisher already sends them in batches).
  Pictures are 1280 px JPEG 0.75, about 100–200 KB each. With the ceiling this high, a
  long video can still mean a few hundred uploads to Notion; the Diary and Obsidian keep
  them locally.
- **Time:** sampling a long video takes a minute or two on top of the import. It runs in
  the import task with progress, before the watcher sees the file.
