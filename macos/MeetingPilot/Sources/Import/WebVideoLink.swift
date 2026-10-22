import Foundation

/// Only Foundation: `Scripts/browser_host.swift`, the browser extension's native host, is
/// compiled with this file to recognize the links it is sent.
enum WebVideoLink {
    private static let youtubeHosts: Set<String> = ["youtube.com", "youtube-nocookie.com"]

    /// The video a pasted link points at, as its canonical watch page; nil for anything
    /// that is not a single YouTube video (a channel, a playlist, another site).
    static func youtube(_ text: String) -> (id: String, url: URL)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let components = URLComponents(string: trimmed), var host = components.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        let path = components.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" {
            id = path.first
        } else if youtubeHosts.contains(host) {
            if path.first == "watch" {
                id = components.queryItems?.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) {
                id = path[1]
            }
        }
        guard let id, isVideoID(id), let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { return nil }
        return (id, url)
    }

    private static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
