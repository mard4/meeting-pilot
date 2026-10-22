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

@main
enum BrowserHost {
    static func main() {
        guard let message = readMessage() else { fail("bad_message") }

        switch message["type"] as? String {
        case "hello":
            reply(["ok": true, "app_version": appVersion, "configured": token() != nil])

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

        default:
            fail("unknown_type")
        }
    }
}
