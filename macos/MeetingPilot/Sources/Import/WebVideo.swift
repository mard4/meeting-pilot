import Foundation

/// A video on a website, imported by pasting its link. Only YouTube links are accepted
/// for now; yt-dlp, which downloads them, reads many other sites, so another host is a
/// matter of recognizing its links in `WebVideoLink`.
struct WebVideo: Equatable {
    let id: String
    let pageURL: URL
    var title: String
    var durationSeconds: Double?

    /// The key in `MediaImportHistory`: the same video under any link form.
    var fingerprint: String { "youtube:\(id)" }
}

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

enum WebVideoError: LocalizedError {
    case toolDownload(String)
    case failed(String)
    case live

    var errorDescription: String? {
        switch self {
        case .toolDownload(let detail):
            return localized("Download di yt-dlp non riuscito") + ": " + detail
        case .failed(let detail):
            return localized("YouTube non ha risposto come previsto") + ": " + detail
        case .live:
            return localized("Le dirette si possono importare solo quando sono finite.")
        }
    }
}

/// Reads and downloads web videos with yt-dlp: the copy installed with Homebrew if there
/// is one, otherwise the standalone build, downloaded into `folder` the first time a link
/// is pasted and kept up to date from there, since YouTube changes often enough to break
/// older versions.
final class WebVideoDownloader {
    static let toolDownloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    private static let systemTools = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
    private static let updateInterval: TimeInterval = 7 * 24 * 3600

    let folder: URL
    private var installing: Task<URL, Error>?
    private let lock = NSLock()

    init(folder: URL) {
        self.folder = folder
    }

    private var bundledTool: URL { folder.appendingPathComponent("yt-dlp") }

    var toolInstalled: Bool { installedTool() != nil }

    private func installedTool() -> URL? {
        let candidates = Self.systemTools.map { URL(fileURLWithPath: $0) } + [bundledTool]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// yt-dlp, downloaded once if this Mac has none; an older own copy updates itself first.
    func tool() async throws -> URL {
        if let tool = installedTool() {
            if tool == bundledTool { await updateIfStale(tool) }
            return tool
        }
        // Two links pasted at once share one download.
        let task = lock.withLock {
            let task = installing ?? Task { try await self.install() }
            installing = task
            return task
        }
        defer { lock.withLock { installing = nil } }
        return try await task.value
    }

    private func install() async throws -> URL {
        let (download, response) = try await URLSession.shared.download(from: Self.toolDownloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: download)
            throw WebVideoError.toolDownload("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: bundledTool.path) {
                try FileManager.default.removeItem(at: bundledTool)
            }
            try FileManager.default.moveItem(at: download, to: bundledTool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledTool.path)
        } catch {
            throw WebVideoError.toolDownload(error.localizedDescription)
        }
        AppLog.append("yt-dlp scaricato in \(bundledTool.path)")
        return bundledTool
    }

    private func updateIfStale(_ tool: URL) async {
        let modified = (try? FileManager.default.attributesOfItem(atPath: tool.path)[.modificationDate]) as? Date
        guard Date().timeIntervalSince(modified ?? .distantPast) > Self.updateInterval else { return }
        let result = try? await Self.run(tool, ["--update"])
        // Touched even when already current, so the check waits another week.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: tool.path)
        if let result, result.status != 0 {
            AppLog.append("Aggiornamento yt-dlp non riuscito\n\(result.errors)")
        }
    }

    /// Title and length, read before the download so the sheet can show them.
    func info(for link: (id: String, url: URL)) async throws -> WebVideo {
        let tool = try await tool()
        let result = try await Self.run(tool, ["--dump-single-json", "--no-playlist", "--no-warnings", link.url.absoluteString])
        guard result.status == 0,
              let payload = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        else { throw WebVideoError.failed(Self.errorLine(result.errors)) }
        if let live = payload["live_status"] as? String, live == "is_live" || live == "is_upcoming" {
            throw WebVideoError.live
        }
        let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var video = WebVideo(id: link.id, pageURL: link.url, title: title?.isEmpty == false ? title! : link.id)
        if let duration = payload["duration"] as? Double, duration.isFinite, duration > 0 {
            video.durationSeconds = duration
        }
        return video
    }

    /// Downloads the soundtrack into `folder`: YouTube's AAC stream when there is one,
    /// which the transcribers read as it is, otherwise the MP4 video, whose audio the
    /// importer extracts. Neither needs ffmpeg.
    func download(_ video: WebVideo, into folder: URL, progress: @escaping (Double) async -> Void) async throws -> URL {
        let tool = try await tool()
        let arguments = [
            "--format", "bestaudio[ext=m4a]/best[ext=mp4]",
            "--no-playlist", "--no-part", "--no-mtime", "--newline", "--progress",
            "--progress-template", "download:MPPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            "--print", "after_move:filepath",
            "--output", folder.appendingPathComponent("video.%(ext)s").path,
            video.pageURL.absoluteString,
        ]
        var file: URL?
        let result = try await Self.run(tool, arguments) { line in
            if line.hasPrefix("MPPROGRESS ") {
                let numbers = line.split(separator: " ").dropFirst().map { Double($0) }
                if let done = numbers.first ?? nil, let total = (numbers.count > 1 ? numbers[1] : nil) ?? (numbers.count > 2 ? numbers[2] : nil), total > 0 {
                    Task { await progress(min(done / total, 1)) }
                }
            } else if line.hasPrefix("/") {
                file = URL(fileURLWithPath: line)
            }
        }
        guard result.status == 0, let file, FileManager.default.fileExists(atPath: file.path) else {
            throw WebVideoError.failed(Self.errorLine(result.errors))
        }
        return file
    }

    private static func errorLine(_ errors: String) -> String {
        let lines = errors.split(whereSeparator: \.isNewline).map(String.init)
        let error = lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? "yt-dlp"
        return error.replacingOccurrences(of: "ERROR: ", with: "")
    }

    /// Runs yt-dlp, handing each line it prints to `onLine`. Homebrew's folders are on the
    /// PATH so it finds deno, which YouTube's newer players need, when it is installed.
    private static func run(
        _ tool: URL,
        _ arguments: [String],
        onLine: ((String) -> Void)? = nil
    ) async throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let collected = LineCollector(onLine: onLine)
        let errorData = ErrorBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in errorData.append(handle.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    collected.append(output.fileHandleForReading.readDataToEndOfFile())
                    errorData.append(errors.fileHandleForReading.readDataToEndOfFile())
                    collected.finish()
                    continuation.resume(returning: (process.terminationStatus, collected.text, errorData.text))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: WebVideoError.failed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Standard output split into lines as it arrives.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var all = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        all.append(data)
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        lock.unlock()
        lines.forEach { emit($0) }
    }

    func finish() {
        lock.lock()
        let rest = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(rest) }
    }

    private func emit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onLine?(trimmed) }
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}
