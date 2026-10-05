import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A file the user is about to import: a lecture video, a podcast, a recording made
/// elsewhere. It becomes a note like any recording, through the inbox and the watcher.
struct MediaImportDraft: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    /// Typed by the user; empty lets the summary choose the title.
    var title = ""
    var recordedAt: Date
    var isVideo = false
    var durationSeconds: Double?
    /// When this same file was imported before.
    var previouslyImportedAt: Date?
    /// Why it cannot be imported (no audio, a format macOS cannot read).
    var problem: String?
    /// The slides shown in it, placed next to the transcript.
    var slidesURL: URL?

    var fileName: String { sourceURL.lastPathComponent }

    /// Also the name of the file in the inbox when no title is typed.
    var suggestedTitle: String { sourceURL.deletingPathExtension().lastPathComponent }

    var canImport: Bool { problem == nil }
}

/// Opened by "Importa", a dropped file, or the menu bar; the sheet reads the files.
struct MediaImportRequest: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]
}

/// Chosen once in the sheet for every file imported together.
struct MediaImportOptions {
    var template = SummaryTemplateCatalog.auto
    /// Lecture or work meeting, for someone who is both; nil decides from the title.
    var profile: UserProfile?
}

struct MediaImportJob: Identifiable, Equatable {
    let id: UUID
    let name: String
    var progress: Double = 0
    var failure: String?
}

enum MediaImportError: LocalizedError {
    case cannotExport(String)

    var errorDescription: String? {
        switch self {
        case .cannotExport(let detail):
            return localized("Estrazione dell'audio non riuscita") + ": " + detail
        }
    }
}

enum MediaImportInspector {
    /// What the open panel and drag and drop accept; anything else AVFoundation can
    /// read is still checked by `draft(for:)`.
    static let contentTypes: [UTType] = [.audio, .movie, .audiovisualContent, .pdf]

    static func isSlides(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    /// Copied into the inbox as they are; everything else is converted to AAC first.
    /// These are the formats both transcribers read directly.
    static let copiedExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "flac"]

    static func draft(for url: URL, history: MediaImportHistory) async -> MediaImportDraft {
        var draft = MediaImportDraft(sourceURL: url, recordedAt: fileDate(of: url))
        if let fingerprint = MediaImportHistory.fingerprint(of: url) {
            draft.previouslyImportedAt = history.importDate(for: fingerprint)
        }
        let asset = AVURLAsset(url: url)
        do {
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                draft.problem = localized("Il file non contiene audio.")
                return draft
            }
            draft.isVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
            let duration = try await asset.load(.duration)
            if duration.isNumeric, duration.seconds > 0 {
                draft.durationSeconds = duration.seconds
            }
            if let item = try await asset.load(.creationDate), let date = try await item.load(.dateValue) {
                draft.recordedAt = date
            }
        } catch {
            draft.problem = localized("Formato non supportato: convertilo in MP4, MOV, M4A o MP3.")
        }
        return draft
    }

    /// A copied or downloaded file is created when it arrives but keeps the original
    /// modification date, so the earlier of the two is closer to the recording.
    private static func fileDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min() ?? Date()
    }
}

/// Files already imported, by content, so importing the same lecture twice asks first.
/// Stored next to `.env` as `imported-media.json`.
final class MediaImportHistory {
    private let url: URL
    private var entries: [String: String]
    /// Read while the sheet inspects files and written by the import task.
    private let lock = NSLock()
    private static let dateFormatter = ISO8601DateFormatter()

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        entries = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func importDate(for fingerprint: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return entries[fingerprint].flatMap { Self.dateFormatter.date(from: $0) }
    }

    func record(_ fingerprint: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[fingerprint] = Self.dateFormatter.string(from: date)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            AppLog.append("Salvataggio cronologia importazioni non riuscito: \(error.localizedDescription)")
        }
    }

    /// Size plus a hash of the first and last megabyte: cheap on a two-hour video and
    /// still different for different recordings.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let chunk = 1 << 20
        var hasher = SHA256()
        try? handle.seek(toOffset: 0)
        hasher.update(data: (try? handle.read(upToCount: chunk)) ?? Data())
        if size > UInt64(2 * chunk) {
            try? handle.seek(toOffset: size - UInt64(chunk))
            hasher.update(data: (try? handle.read(upToCount: chunk)) ?? Data())
        }
        return "\(size)-" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Puts imported files into the inbox one at a time: the audio (a copy, or the
/// soundtrack of a video) next to a sidecar whose `recording.json` says it was imported.
/// Everything is prepared in `.importing/`, which the watcher does not look into, and
/// then moved in sidecar first, so the watcher never sees half a file.
final class MediaImporter: ObservableObject {
    @Published private(set) var jobs: [MediaImportJob] = []
    let history: MediaImportHistory
    var onStatusMessage: ((String) -> Void)?
    var onImported: (() -> Void)?
    private var queue: [(draft: MediaImportDraft, options: MediaImportOptions, inbox: URL, jobID: UUID)] = []
    private var running = false

    init(historyURL: URL) {
        history = MediaImportHistory(url: historyURL)
    }

    var isImporting: Bool { jobs.contains { $0.failure == nil } }

    func start(_ drafts: [MediaImportDraft], options: MediaImportOptions, inbox: URL) {
        for draft in drafts where draft.canImport {
            let id = UUID()
            jobs.append(MediaImportJob(id: id, name: draft.title.isEmpty ? draft.suggestedTitle : draft.title))
            queue.append((draft, options, inbox, id))
        }
        runNext()
    }

    func dismiss(_ job: MediaImportJob) {
        jobs.removeAll { $0.id == job.id }
    }

    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let next = queue.removeFirst()
        Task {
            do {
                try await self.importFile(next.draft, options: next.options, inbox: next.inbox) { progress in
                    await MainActor.run { self.update(next.jobID) { $0.progress = progress } }
                }
                await MainActor.run {
                    self.jobs.removeAll { $0.id == next.jobID }
                    self.onStatusMessage?(localized("Importato, in coda per la trascrizione") + ": " + next.draft.fileName)
                    self.onImported?()
                }
            } catch {
                AppLog.append("Importazione non riuscita (\(next.draft.sourceURL.path)): \(error.localizedDescription)")
                await MainActor.run {
                    self.update(next.jobID) { $0.failure = error.localizedDescription }
                }
            }
            await MainActor.run {
                self.running = false
                self.runNext()
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout MediaImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func importFile(
        _ draft: MediaImportDraft,
        options: MediaImportOptions,
        inbox: URL,
        progress: @escaping (Double) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        let scoped = draft.sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { draft.sourceURL.stopAccessingSecurityScopedResource() } }
        let slidesScoped = draft.slidesURL?.startAccessingSecurityScopedResource() ?? false
        defer { if slidesScoped { draft.slidesURL?.stopAccessingSecurityScopedResource() } }

        let staging = inbox
            .appendingPathComponent(".importing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let sourceExtension = draft.sourceURL.pathExtension.lowercased()
        let copyAsIs = !draft.isVideo && MediaImportInspector.copiedExtensions.contains(sourceExtension)
        let fileName = Self.uniqueFileName(
            title: draft.title.isEmpty ? draft.suggestedTitle : draft.title,
            date: draft.recordedAt,
            fileExtension: copyAsIs ? sourceExtension : "m4a",
            in: inbox
        )
        let stagedAudio = staging.appendingPathComponent(fileName)
        try fileManager.createDirectory(at: MeetingSidecar.directory(for: stagedAudio), withIntermediateDirectories: true)
        try MeetingSidecar.writeImportInfo(Self.importInfo(for: draft), for: stagedAudio)
        if options.template != SummaryTemplateCatalog.auto {
            MeetingSidecar.writeTemplateChoice(options.template, for: stagedAudio)
        }
        if let profile = options.profile {
            MeetingSidecar.writeProfileChoice(profile, for: stagedAudio)
        }
        if let slides = draft.slidesURL {
            try SlideDeck.write(slides, intoSidecarOf: stagedAudio)
        }

        if copyAsIs {
            // A clone on APFS: instant, and no extra space until one of them changes.
            try fileManager.copyItem(at: draft.sourceURL, to: stagedAudio)
        } else {
            try await Self.exportAudio(from: draft.sourceURL, to: stagedAudio, progress: progress)
        }
        await progress(1)

        let finalAudio = inbox.appendingPathComponent(fileName)
        try fileManager.moveItem(at: MeetingSidecar.directory(for: stagedAudio), to: MeetingSidecar.directory(for: finalAudio))
        try fileManager.moveItem(at: stagedAudio, to: finalAudio)
        if let fingerprint = MediaImportHistory.fingerprint(of: draft.sourceURL) {
            history.record(fingerprint)
        }
    }

    static func importInfo(for draft: MediaImportDraft) -> [String: Any] {
        var info: [String: Any] = [
            "media_kind": draft.isVideo ? "video" : "audio",
            "original_name": draft.fileName,
            "original_path": draft.sourceURL.path,
            "recorded_at": localTimestamp(draft.recordedAt),
        ]
        if let duration = draft.durationSeconds {
            info["duration_seconds"] = duration
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            info["title"] = title
        }
        return info
    }

    /// The pipeline reads timestamps without a zone as local time, like the recorder's.
    static func localTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    static func uniqueFileName(title: String, date: Date, fileExtension: String, in folder: URL) -> String {
        let base = NativeAudioRecorder.fileName(for: title, date: date, fileExtension: fileExtension)
        let stem = (base as NSString).deletingPathExtension
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
            || FileManager.default.fileExists(atPath: MeetingSidecar.directory(for: folder.appendingPathComponent(candidate)).path) {
            candidate = "\(stem) \(counter).\(fileExtension)"
            counter += 1
        }
        return candidate
    }

    /// The soundtrack alone, as AAC: a lecture video of several gigabytes becomes a
    /// file the transcribers read like any recording.
    private static func exportAudio(from source: URL, to output: URL, progress: @escaping (Double) async -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaImportError.cannotExport(source.lastPathComponent)
        }
        if #available(macOS 15.0, *) {
            let observer = Task {
                for await state in session.states(updateInterval: 0.3) {
                    if case .exporting(let exportProgress) = state {
                        await progress(exportProgress.fractionCompleted)
                    }
                }
            }
            defer { observer.cancel() }
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            let poller = Task {
                while !Task.isCancelled {
                    await progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            defer { poller.cancel() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                throw MediaImportError.cannotExport(session.error?.localizedDescription ?? source.lastPathComponent)
            }
        }
    }
}
