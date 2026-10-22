# Meeting Pilot browser extension: plan

Status: plan agreed, 2026-10-22. Phase 1 built on `feature/browser-extension`.

## 1. What the extension is for

The Mac app stays where the work happens: recording, on-device transcription, summaries,
Diary, publishing. The extension only connects the browser to it:

1. **Send the open tab to Meeting Pilot.** On a YouTube video, one click imports it, through
   the YouTube import added in 0.5.1. No copying the link.
2. **Know when a meeting starts and ends in the browser.** Google Meet, Teams on the web and
   Zoom's web client run in a tab, where the app's Teams detection (window titles,
   Accessibility, the Teams process using the microphone) sees nothing reliable. The
   extension tells the app "a call started on Meet, called X, with these people", and the
   app shows its usual recording prompt and stops when the call ends.
3. **Later: who is speaking.** Meet and Teams web mark the active speaker in the page, as the
   Teams app does for `TeamsSpeakerTracker`. Speaker names could then reach the transcript.

What it does **not** do: capture audio. The recorder already taps all of the Mac's audio
(`CATapDescription(stereoGlobalTapButExcludeProcesses: [])` in `Recording/Recording.swift`)
plus the microphone, so a call in Chrome is recorded today. Capturing the tab in the
extension (`chrome.tabCapture` plus an offscreen document) would duplicate that. It would
also need a click on every call, and streaming audio to the app would be the hardest part
of the whole project.

A web version of Meeting Pilot is out of scope: it would mean servers, accounts and
uploading meeting audio, the opposite of what the app promises. The MCP server (0.5.1)
already covers reading meetings from outside the app.

## 2. How the extension talks to the app

**Native messaging.** It is Chrome's standard channel between an extension and a desktop
app: Chrome starts a small program named in a manifest file and talks to it over stdio,
one JSON message at a time. Only the extension IDs listed in that manifest can connect,
so no website can talk to it. This is unlike a local HTTP or WebSocket server, which any
page could try to reach.

- **Host:** a new small Swift executable in the app bundle,
  `Contents/MacOS/MeetingPilotBrowserHost`, built like `TeamsWindowID`. It relays each
  message to the running app with `DistributedNotificationCenter`, or an XPC/Mach service if
  replies need to be reliable, and returns the app's answer. If the app is not running, it
  opens the app (`NSWorkspace`, as `meetingpilot://` does now) and retries.
- **Manifest:** `com.meetingpilot.browser.json`, written by the app (Settings → "Browser")
  into each browser's `NativeMessagingHosts` folder under `~/Library/Application Support/`:
  `Google/Chrome`, `Microsoft Edge`, `BraveSoftware/Brave-Browser`, `Arc/User Data`,
  `Chromium`. It names the host's path and the extension's fixed ID (`allowed_origins`).
- **Fixed extension ID:** set with `"key"` in the extension's `manifest.json`, so the ID is the
  same unpacked and in the Chrome Web Store, and the app's manifest always matches.
- **Fallback without the host:** "Send to Meeting Pilot" can open
  `meetingpilot://import?url=…`. `CFBundleURLSchemes` already registers `meetingpilot`, today
  only for the Notion callback in `App.swift`. Chrome asks "Open Meeting Pilot?" the first
  time.

Messages (JSON, versioned with `"v": 1`):

| From extension | Meaning | App does |
|---|---|---|
| `{"type": "hello"}` | Handshake | Replies with app version and whether recording is possible |
| `{"type": "import", "url": …, "force": false}` | Send this tab | Imports it right away with the defaults (§6); replies `queued`, `already_imported` (with date) or an error |
| `{"type": "call_started", "platform": "meet", "tab": 12, "title": …, "participants": […]}` | Call began | Recording prompt, as for Teams |
| `{"type": "call_updated", …}` | Title or participants changed | Updates the live sidebar and the metadata |
| `{"type": "call_ended", "tab": 12}` | Left the call or closed the tab | Stops a recording it started for this call |
| `{"type": "speaking", "names": […], "t": …}` | Active speaker (phase 3) | Fed to the speaker tracker |

## 3. Changes to the Mac app

- `Platforms/Browser/BrowserMeetingPlatform.swift`: a `MeetingPlatform` conformance. The
  protocol was made for this ("adding Zoom or Meet means adding a conformance"). Its state
  comes from the host's messages, not from windows: `meetingPromptTitle()` is the title the
  extension sent, and `windowSnapshot().callSignal` is "a call is open". `RecordingController`
  then handles prompt, auto-stop and the live sidebar unchanged.
- Recording metadata: the title and participants go into the sidecar the way Teams scraping
  feeds `teams_runtime_metadata` today, so the pipeline needs no change. A calendar match
  still wins when there is one. `recording.json` gets `"platform": "meet"`.
- Import from a link without the sheet: `AppModel.importLink(_:force:)`, see §6.3.
- Settings → new "Browser" row: install or remove the native-messaging manifests and show
  whether the extension has connected. It is the same pattern as the Claude Desktop row in
  `MCPClients.swift`.
- `build_app.sh`: build, sign (hardened runtime) and notarize the host with the other helpers.

## 4. The extension

Manifest V3, plain JavaScript with no build step, in `browser/extension/` in this repo.

- **Permissions:** `nativeMessaging`, `activeTab` (for "send this tab"), `storage`, and host
  permissions only for `https://meet.google.com/*`, `https://teams.microsoft.com/*`,
  `https://teams.live.com/*`, `https://*.zoom.us/wc/*`. No `<all_urls>`, no history, no
  reading other sites.
- **Toolbar button and context menu:** "Send to Meeting Pilot". It is enabled on video pages:
  YouTube for now, other sites when the app accepts them (yt-dlp already reads them).
- **Content scripts per meeting site:** watch the page for "in a call" (Meet: the leave-call
  button and the call controls; Teams web: the hang-up button; Zoom web: the meeting
  footer), read the meeting title and the participant list, and report changes.
  Selectors are kept in one file per site, because these pages change without notice. A
  broken selector must only mean "no prompt", never a wrong recording.
- **Service worker:** keeps one native-messaging port, tracks which tab has the call, and
  sends `call_ended` when the tab closes or navigates away.
- **Popup:** connection state ("Meeting Pilot is ready / not installed / not running"), the
  send button, and a link to set up the host.

## 5. Phases

| Phase | Content | Size |
|---|---|---|
| 1. Send to Meeting Pilot | Native host + manifest install from Settings, extension with toolbar button and popup, direct `import`, `meetingpilot://import` fallback, extension folder in the app and zip in the GitHub release, setup steps in Settings | about 3 days |
| 2. Meet in the browser | `BrowserMeetingPlatform`, Meet content script (call state, title, participants), prompt and auto-stop, metadata to the pipeline | medium: about 1 week |
| 3. Teams web and Zoom web | One content script each, same messages | a few days each |
| 4. Speaker names | Active-speaker events, merged like `TeamsSpeakerTracker` | medium, fragile |
| 5. Other browsers | Safari Web Extension inside the app (Xcode's converter; messaging goes through the containing app, not a manifest), Firefox (`browser.runtime.connectNative`, its own manifest folder) | medium |

Phase 1 already builds the channel that phases 2–4 use, so nothing is thrown away.

## 6. Decisions (taken 2026-10-22)

1. **Distribution: manual install from GitHub for now; Chrome Web Store later.** No
   developer account and no fee for now (the Web Store's is a one-time $5).
   - Each release attaches `MeetingPilot-Browser-Extension-X.Y.Z.zip` to the GitHub release,
     next to the DMG. The app also ships the same folder in its bundle and copies it to
     `~/Library/Application Support/Meeting Pilot/Browser Extension/` on launch, so the
     installed extension always matches the app's version.
   - Setup, guided from Settings → "Browser": turn on Developer mode in
     `chrome://extensions` (`edge://`, `brave://` and so on), click "Load unpacked", choose that
     folder. "Show folder" reveals it in the Finder. The install steps also go on the website
     and in the README.
   - The extension's `manifest.json` carries a `"key"` (a public key generated once and kept
     in the repo; the private key stays out of it), so the unpacked extension has the same ID
     on every Mac and the native host manifest can name it.
   - Updates: the app replaces the folder when it updates; Chrome picks the new files up at
     its next start, or right away with the reload button in `chrome://extensions`. The popup
     says when the extension is older than the app.
   - Later, the Web Store assigns its own ID: the host manifest's `allowed_origins` will then
     list both IDs, so manual installs keep working. Edge Add-ons is free and can come at
     the same time.
2. **Browsers: every Chromium browser.** Chrome, Edge, Brave and Arc in phase 1. The app
   writes the host manifest into each one's folder that exists. Safari and Firefox stay in
   phase 5.
3. **"Send" imports straight away, with the default note type and template.** No sheet.
   The app therefore has to give the feedback itself: a notification "Importing *title*…"
   and then the usual progress card, plus an error notification if yt-dlp fails. A video
   already imported is not imported again silently: the popup shows "Already imported on
   …" with an "Import again" button. Slides can still be added afterwards from the Diary.
   `import` messages go to a new `AppModel.importLink(_:)` that runs the same
   `WebVideoDownloader.info` → `MediaImporter.start` path as the sheet, without UI.
4. **First meeting site: Google Meet.**

## 7. Risks

- **Meeting pages change their DOM.** Mitigation: selectors in one file per site, a
  self-check that reports "detection unavailable" in the popup instead of guessing, and the
  existing manual Record button as fallback.
- **Meet's tab title is the meeting code, not its name.** The name comes from the call info
  panel or, more reliably, from the calendar match the pipeline already does.
- **Two prompts for one call:** Teams web in Chrome while the Teams app is also open.
  `RecordingController` must treat any active recording as "already recording", whichever
  platform started it.
- **Store review** for `nativeMessaging` with meeting-site host permissions: the
  justification is straightforward ("detects when you are in a call so the Meeting Pilot Mac
  app can offer to record it; nothing leaves the Mac").
