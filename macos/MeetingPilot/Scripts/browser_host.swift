// The browser extension's native messaging host, `Contents/MacOS/MeetingPilotBrowserHost`.
//
// Chrome (and Edge, Brave, Arc) start it for each message the extension sends, as named by
// `com.meetingpilot.browser.json` in their NativeMessagingHosts folder, which the app writes
// from Settings → Browser. Only the extension ID listed there can start it. One message in
// on stdin, one reply out on stdout, each a JSON object behind its length as a 32-bit
// little-endian integer; then it exits.
//
// The app does the work: an import goes to it as `meetingpilot://import?url=…&token=…`.
// The token, written by the app next to `.env`, is what lets it import without asking; a
// `meetingpilot://` link opened by any web page carries none and only fills the import sheet.
//
// Compiled with Sources/Import/WebVideoLink.swift by Scripts/build_app.sh.

import CryptoKit
import Foundation

let protocolVersion = 1
let configDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Meeting Pilot", isDirectory: true)

func readMessage() -> [String: Any]? {
    let input = FileHandle.standardInput
    let header = input.readData(ofLength: 4)
    guard header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    // Chrome sends at most 4 GB; an extension message is a few hundred bytes.
    guard length > 0, length < 1 << 20 else { return nil }
    let body = input.readData(ofLength: length)
    guard body.count == length else { return nil }
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
}

func reply(_ payload: [String: Any]) -> Never {
    var message = payload
    message["v"] = protocolVersion
    let body = (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
    var length = UInt32(body.count).littleEndian
    let output = FileHandle.standardOutput
    output.write(Data(bytes: &length, count: 4))
    output.write(body)
    exit(0)
}

func fail(_ code: String) -> Never {
    reply(["ok": false, "error": code])
}

var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
}

/// When `MediaImportHistory` (`imported-media.json`) says this video was imported.
func importDate(of fingerprint: String) -> String? {
    guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent("imported-media.json")),
          let entries = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return nil }
    return entries[fingerprint]
}

/// What the copy of the extension in Application Support looks like now (its files, sizes
/// and dates). The app replaces that copy when it updates, but a browser keeps running an
/// unpacked extension as it loaded it; the popup compares this with what it last saw and
/// reloads itself when it changed.
func extensionStamp() -> String? {
    let folder = configDirectory.appendingPathComponent("Browser Extension", isDirectory: true)
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
    var lines: [String] = []
    for case let file as URL in files {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize else { continue }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        lines.append("\(file.path.dropFirst(folder.path.count)):\(size):\(Int(modified))")
    }
    guard !lines.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

func token() -> String? {
    let value = try? String(contentsOf: configDirectory.appendingPathComponent("browser-host-token"), encoding: .utf8)
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

/// `open -g` starts the app if it is not running and leaves the browser in front.
func openInApp(_ url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", url.absoluteString]
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

// MARK: - Where an imported video is in the pipeline

/// The pipeline's folders, as `.env` names them (see `config.py`).
struct PipelineFolders {
    let inbox: URL
    let processing: URL
    let done: URL
    let failed: URL
    let diary: URL
    /// The watcher's record of every inbox file it handled: `{"<key>": {"path", "status"}}`.
    let processedSources: URL

    init() {
        var values: [String: String] = [:]
        let env = (try? String(contentsOf: configDirectory.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        for line in env.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        func path(_ key: String, _ fallback: String) -> URL {
            let value = values[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        let root = path("MEETINGS_ROOT", "~/TeamsMeetings").path
        inbox = path("INBOX_AUDIO_DIR", "\(root)/inbox_audio")
        processing = path("PROCESSING_DIR", "\(root)/processing")
        done = path("DONE_DIR", "\(root)/done")
        failed = path("FAILED_DIR", "\(root)/failed")
        diary = path("JOURNAL_ROOT", configDirectory.appendingPathComponent("Diary").path)
        processedSources = URL(fileURLWithPath: (values["PROCESSED_SOURCES_FILE"].flatMap { $0.isEmpty ? nil : $0 }.map { ($0 as NSString).expandingTildeInPath }) ?? "\(root)/processed_sources.json")
    }
}

func children(of folder: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
}

func sourceURL(inJSON file: URL) -> String? {
    guard let data = try? Data(contentsOf: file),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return payload["source_url"] as? String
}

/// A sidecar folder (`… .meetingpilot`) whose `recording.json` imported this video.
func sidecarImports(_ url: String, in folder: URL) -> Bool {
    children(of: folder).contains { item in
        item.pathExtension == "meetingpilot" && sourceURL(inJSON: item.appendingPathComponent("recording.json")) == url
    }
}

/// The audio in the inbox that imported this video. The sidecar outlives its audio there,
/// and the watcher may keep the audio after handling it.
func inboxAudio(for url: String, in inbox: URL) -> URL? {
    let items = children(of: inbox)
    for sidecar in items where sidecar.pathExtension == "meetingpilot" {
        guard sourceURL(inJSON: sidecar.appendingPathComponent("recording.json")) == url else { continue }
        let stem = sidecar.deletingPathExtension().lastPathComponent
        if let audio = items.first(where: { $0.pathExtension != "meetingpilot" && $0.deletingPathExtension().lastPathComponent == stem }) {
            return audio
        }
    }
    return nil
}

/// What the watcher wrote for this inbox file in `processed_sources.json`: "processed",
/// "failed", or nil when it has not handled it yet.
func watcherStatus(of audio: URL, in record: URL) -> String? {
    guard let data = try? Data(contentsOf: record),
          let entries = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return nil }
    let path = audio.standardizedFileURL.path
    return entries.values.first { ($0["path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }?["status"] as? String
}

func session(for url: String, in folder: URL) -> URL? {
    children(of: folder).first { sourceURL(inJSON: $0.appendingPathComponent("meeting_metadata.json")) == url }
}

/// The step a session got to: its transcript is a top-level .txt, its summary omlx_summary.json.
func step(of session: URL) -> String {
    let files = children(of: session).map(\.lastPathComponent)
    if files.contains("omlx_summary.json") { return "publish" }
    if files.contains(where: { $0.hasSuffix(".txt") }) { return "summarize" }
    return "transcribe"
}

/// A Diary page whose frontmatter links the video: the session may be gone once published.
func diaryHasNote(for url: String, in diary: URL) -> Bool {
    guard let pages = FileManager.default.enumerator(at: diary, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
    let needle = "source_url: \"\(url)\""
    for case let page as URL in pages where page.pathExtension == "md" {
        if let text = try? String(contentsOf: page, encoding: .utf8), text.contains(needle) { return true }
    }
    return false
}

/// `step` is download, transcribe, summarize or publish; `state` is active, queued, failed or done.
func pipelineStatus(of link: (id: String, url: URL)) -> [String: Any] {
    let url = link.url.absoluteString
    let folders = PipelineFolders()
    let staging = folders.inbox.appendingPathComponent(".importing", isDirectory: true)
    // From the surest sign to the least: a download or a session at work says what is
    // happening now, a finished one what happened, the inbox only what is waiting.
    if children(of: staging).contains(where: { sidecarImports(url, in: $0) }) {
        return ["step": "download", "state": "active"]
    }
    if let session = session(for: url, in: folders.processing) {
        return ["step": step(of: session), "state": "active"]
    }
    if let session = session(for: url, in: folders.failed) {
        return ["step": step(of: session), "state": "failed"]
    }
    if session(for: url, in: folders.done) != nil || diaryHasNote(for: url, in: folders.diary) {
        return ["step": "publish", "state": "done"]
    }
    if let audio = inboxAudio(for: url, in: folders.inbox) {
        switch watcherStatus(of: audio, in: folders.processedSources) {
        case "processed":
            return ["step": "publish", "state": "done"]
        case "failed":
            // Its session, which said at which step, may be gone: the first one is the safe guess.
            return ["step": "transcribe", "state": "failed"]
        default:
            return ["step": "transcribe", "state": "queued"]
        }
    }
    // Imported, but no session left and no Diary page: published to Notion or Obsidian only.
    if importDate(of: "youtube:\(link.id)") != nil {
        return ["step": "publish", "state": "done"]
    }
    return ["state": "none"]
}

@main
enum BrowserHost {
    static func main() {
        guard let message = readMessage() else { fail("bad_message") }

        switch message["type"] as? String {
        case "hello":
            var hello: [String: Any] = ["ok": true, "app_version": appVersion, "configured": token() != nil]
            if let stamp = extensionStamp() { hello["extension_stamp"] = stamp }
            reply(hello)

        case "import":
            guard let link = WebVideoLink.youtube(message["url"] as? String ?? "") else { fail("not_a_video") }
            if message["force"] as? Bool != true, let date = importDate(of: "youtube:\(link.id)") {
                reply(["ok": false, "error": "already_imported", "imported_at": date])
            }
            guard let token = token() else { fail("not_configured") }
            var components = URLComponents()
            components.scheme = "meetingpilot"
            components.host = "import"
            components.queryItems = [URLQueryItem(name: "url", value: link.url.absoluteString), URLQueryItem(name: "token", value: token)]
            guard let url = components.url, openInApp(url) else { fail("app_unavailable") }
            reply(["ok": true, "status": "queued"])

        case "status":
            guard let link = WebVideoLink.youtube(message["url"] as? String ?? "") else { fail("not_a_video") }
            var status = pipelineStatus(of: link)
            status["ok"] = true
            if let date = importDate(of: "youtube:\(link.id)") { status["imported_at"] = date }
            reply(status)

        default:
            fail("unknown_type")
        }
    }
}
