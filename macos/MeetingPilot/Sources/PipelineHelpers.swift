import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import FoundationModels
import Speech
import ServiceManagement
import SwiftUI
import UserNotifications


func diagnosticLogText(meetingsRoot: URL) -> String {
    let logRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    var sections: [String] = []
    let globalLogs = [
        ("APP", AppLog.appURL),
        ("PIPELINE", logRoot.appendingPathComponent("transcribe-to-notion.log")),
        ("ERRORI", logRoot.appendingPathComponent("transcribe-to-notion.err.log"))
    ]
    for (title, url) in globalLogs {
        let rawContent = readLogTail(url, maximumBytes: 48_000)
        let content = title == "APP" ? recentLogEntries(rawContent) : rawContent
        if !content.isEmpty { sections.append("===== \(title) =====\n\(content)") }
    }

    if let failed = newestDirectory(in: meetingsRoot.appendingPathComponent("failed")) {
        let candidates = ["apple_transcriber_command.log", "fluidaudio_command.log"]
        for name in candidates {
            let content = readLogTail(failed.appendingPathComponent(name), maximumBytes: 32_000)
            if !content.isEmpty {
                sections.append("===== ULTIMA SESSIONE FALLITA · \(name) =====\n\(content)")
            }
        }
    }
    return sections.joined(separator: "\n\n")
}

func recentLogEntries(_ content: String) -> String {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    let yesterday = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let todayLines = lines.filter { $0.contains("[\(today)") }
    if !todayLines.isEmpty { return todayLines.joined(separator: "\n") }
    let yesterdayLines = lines.filter { $0.contains("[\(yesterday)") }
    return yesterdayLines.isEmpty ? content : yesterdayLines.joined(separator: "\n")
}

func readLogTail(_ url: URL, maximumBytes: Int) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func makeRefreshSnapshot(_ input: RefreshInput) -> RefreshSnapshot {
    let watcherActive = isWatcherProcessRunning()
    let queueCount = countPendingAudioFiles(
        in: input.inbox,
        processedSourcesFile: input.processedSources,
        stableSeconds: input.stableSeconds
    )
    let processingRoot = input.root.appendingPathComponent("processing")
    let doneRoot = input.root.appendingPathComponent("done")
    let failedRoot = input.root.appendingPathComponent("failed")
    let activeCommands = transcriptionProcessCommands()
    let externalRecordingFinished = input.externalRecordingActive
        && (queueCount > 0
            || hasSessionNewerThan(input.externalRecordingStartedAt, in: processingRoot)
            || hasSessionNewerThan(input.externalRecordingStartedAt, in: doneRoot))
    let retryableFailedSession = retryableSummarySession(in: failedRoot)?.path ?? ""
    let retryableTranscriptionSession = findRetryableTranscriptionSession(
        in: processingRoot,
        activeCommands: activeCommands
    )?.path
        ?? findRetryableTranscriptionSession(
            in: failedRoot,
            activeCommands: activeCommands
        )?.path
        ?? ""
    let activeRecording = input.nativeRecordingActive || input.externalRecordingActive
    let pipelineStage = currentPipelineStage(
        nativeRecording: activeRecording,
        queueCount: queueCount,
        processingRoot: processingRoot,
        doneRoot: doneRoot,
        failedRoot: failedRoot
    )
    let pipelineCounts = pipelineStageCounts(
        nativeRecording: activeRecording,
        queueCount: queueCount,
        processingRoot: processingRoot
    )
    let runtime = runtimeMetadataSnapshot(from: input.runtime)

    return RefreshSnapshot(
        watcherActive: watcherActive,
        queueCount: queueCount,
        externalRecordingFinished: externalRecordingFinished,
        retryableFailedSession: retryableFailedSession,
        retryableTranscriptionSession: retryableTranscriptionSession,
        pipelineStage: pipelineStage,
        pipelineCounts: pipelineCounts,
        processingSessions: activeProcessingSessions(processingRoot: processingRoot, failedRoot: failedRoot),
        todayProcessed: countTodaySessions(in: doneRoot),
        recentMeetings: loadRecentMeetings(from: doneRoot),
        logTail: diagnosticLogText(meetingsRoot: input.root),
        permissionRows: permissions(
            includeSystemAudio: input.recorderMode == "macos_prompt",
            includeAppleDictation: input.transcriptionProvider == "apple"
        ),
        accessibilityGranted: AXIsProcessTrusted(),
        runtime: runtime
    )
}

private func runtimeMetadataSnapshot(from url: URL) -> RuntimeMetadataSnapshot {
    guard
        let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return RuntimeMetadataSnapshot(status: "Non ancora letto", title: "-", participants: "-")
    }
    let confidence = json["confidence"] as? String ?? "unknown"
    let source = json["source"] as? String ?? "unknown"
    let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "-"
    let participants = (json["participants"] as? [String])?.joined(separator: ", ") ?? "-"
    return RuntimeMetadataSnapshot(
        status: "\(confidence) via \(source)",
        title: title,
        participants: participants.isEmpty ? "-" : participants
    )
}

func currentPipelineStage(
    nativeRecording: Bool,
    queueCount: Int,
    processingRoot: URL,
    doneRoot: URL,
    failedRoot: URL
) -> Int {
    if nativeRecording { return 1 }

    if let session = newestDirectory(in: processingRoot) {
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []).map { $0.lowercased() })
        if names.contains("notion_receipt.json") { return 5 }
        if names.contains("omlx_summary.json") { return 4 }
        if names.contains("apple_on_device_transcript.txt")
            || names.contains("transcript.txt")
            || names.contains("audio.txt") { return 3 }
        return 2
    }

    if queueCount > 0 { return 2 }

    if let completed = newestDirectory(in: doneRoot),
       let modified = try? completed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
       Date().timeIntervalSince(modified) < 600 {
        return 5
    }

    // A recent failed session should not leave a misleading completed state.
    if let failed = newestDirectory(in: failedRoot),
       let modified = try? failed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
       Date().timeIntervalSince(modified) < 600 {
        return 0
    }
    return 0
}

func pipelineStageCounts(
    nativeRecording: Bool,
    queueCount: Int,
    processingRoot: URL
) -> PipelineStageCounts {
    let sessions = ((try? FileManager.default.contentsOfDirectory(
        at: processingRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    var transcription = 0
    var summarization = 0
    var publishing = 0
    for session in sessions {
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []).map { $0.lowercased() })
        if names.contains("omlx_summary.json") {
            publishing += 1
        } else if names.contains("apple_on_device_transcript.txt")
                    || names.contains("transcript.txt")
                    || names.contains("audio.txt") {
            summarization += 1
        } else {
            transcription += 1
        }
    }

    return PipelineStageCounts(
        detection: queueCount,
        recording: nativeRecording ? 1 : 0,
        transcription: transcription,
        summarization: summarization,
        publishing: publishing
    )
}

func activeProcessingSessions(processingRoot: URL, failedRoot: URL) -> [ProcessingSession] {
    sessions(in: processingRoot, failed: false) + sessions(in: failedRoot, failed: true)
}

private func sessions(in root: URL, failed: Bool) -> [ProcessingSession] {
    let directories = ((try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    return directories.compactMap { session in
        let metadata = readJSON(session.appendingPathComponent("meeting_metadata.json"))
        let summary = readJSON(session.appendingPathComponent("omlx_summary.json"))
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []).map { $0.lowercased() })
        let stage: ProcessingStage
        if failed {
            stage = .failed
        } else if names.contains("omlx_summary.json") {
            stage = .publishing
        } else if names.contains("fluidaudio_transcript.txt") || names.contains("apple_on_device_transcript.txt") || names.contains("transcript.txt") || names.contains("audio.txt") {
            stage = .summarization
        } else {
            stage = .transcription
        }
        let updated = (try? session.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rawTitle = (metadata["title"] as? String) ?? (summary["title"] as? String) ?? session.lastPathComponent
        let issue = failed ? transcriptionIssue(in: session) : nil
        return ProcessingSession(
            id: session.path,
            title: processingSessionTitle(rawTitle),
            date: meetingDate(metadata: metadata, summary: summary, fallback: updated),
            stage: stage,
            updatedAt: updated,
            failureMessage: issue?.message,
            canRetry: issue?.retryable ?? true
        )
    }
    .sorted { $0.updatedAt > $1.updatedAt }
}

func transcriptionIssue(in session: URL) -> TranscriptionIssue? {
    let issueURL = session.appendingPathComponent("transcription_issue.json")
    if let data = try? Data(contentsOf: issueURL),
       let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let code = payload["code"] as? String,
       let retryable = payload["retryable"] as? Bool {
        return transcriptionIssue(code: code, retryable: retryable)
    }

    let asrURL = session.appendingPathComponent("fluidaudio_asr.json")
    if let data = try? Data(contentsOf: asrURL),
       let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let text = payload["text"] as? String,
       text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let words = payload["wordTimings"] as? [Any], words.isEmpty {
        return transcriptionIssue(code: "no_speech_detected", retryable: false)
    }

    return nil
}

private func transcriptionIssue(code: String, retryable: Bool) -> TranscriptionIssue? {
    switch code {
    case "no_speech_detected":
        return TranscriptionIssue(
            code: code,
            message: "Nessun parlato rilevato nell'audio. Riprova trascrizione non cambierà il risultato.",
            retryable: retryable
        )
    default:
        return nil
    }
}

private func processingSessionTitle(_ value: String) -> String {
    let withoutPrefix = value.replacingOccurrences(
        of: #"^\d{8}-\d{6}-meeting-pilot-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-"#,
        with: "",
        options: .regularExpression
    )
    let normalized = withoutPrefix.replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return meetingDisplayTitle(normalized)
}

func newestDirectory(in root: URL) -> URL? {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return items
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .max {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
}

func hasSessionNewerThan(_ date: Date?, in root: URL) -> Bool {
    guard let date, let session = newestDirectory(in: root) else { return false }
    let modified = (try? session.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    return modified >= date
}

func retryableSummarySession(in failedRoot: URL) -> URL? {
    let sessions = (try? FileManager.default.contentsOfDirectory(
        at: failedRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return sessions
        .filter { session in
            guard (try? session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []
            let hasTranscript = files.contains { $0.lowercased().hasSuffix(".txt") && !$0.lowercased().hasSuffix(".ffmpeg.log") }
            let alreadyPublished = files.contains("notion_receipt.json")
            return hasTranscript && !alreadyPublished
        }
        .max {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
}

func transcriptionProcessCommands() -> [String] {
    Shell.processCommands()
        .map { $0.lowercased() }
        .filter { $0.contains("appletranscriber") || $0.contains("fluidaudiocli") || $0.contains("retry-transcription") }
}

let watcherCommandMarkers = ["MeetingPilotCLI watch", "transcribe-to-notion watch"]

func isWatcherProcessRunning() -> Bool {
    Shell.processCommands().contains { command in watcherCommandMarkers.contains { command.contains($0) } }
}

func stopWatcherProcesses() {
    for marker in watcherCommandMarkers {
        Shell.run("/usr/bin/pkill", ["-f", marker])
    }
}

func isTranscriptionProcessActive(for session: URL, activeCommands: [String]? = nil) -> Bool {
    let audioExtensions = Set(["wav", "m4a", "mp3", "aac", "flac", "ogg", "opus", "mp4"])
    let audioPaths = ((try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? [])
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .map(\.path)
    let watchedPaths = [session.path] + audioPaths
    let commands = activeCommands ?? transcriptionProcessCommands()
    let markers = ["appletranscriber", "fluidaudiocli", "retry-transcription"]
    return commands.contains { command in
        markers.contains(where: command.contains)
            && watchedPaths.contains { command.contains($0.lowercased()) }
    }
}

func claimTranscriptionRetry(for session: URL) -> URL? {
    let claim = session.appendingPathComponent(".meeting-pilot-transcription-retry.lock", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: false)
        return claim
    } catch {
        return nil
    }
}

func releaseTranscriptionRetryClaim(_ claim: URL) {
    try? FileManager.default.removeItem(at: claim)
}

func findRetryableTranscriptionSession(in failedRoot: URL, activeCommands: [String]) -> URL? {
    let audioExtensions = Set(["wav", "m4a", "mp3", "aac", "flac", "ogg", "opus", "mp4"])
    let sessions = (try? FileManager.default.contentsOfDirectory(
        at: failedRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return sessions
        .filter { session in
            guard (try? session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            guard let sessionDate = meetingSessionDate(from: session.lastPathComponent),
                  Date().timeIntervalSince(sessionDate) < 72 * 60 * 60 else { return false }
            let files = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let hasAudio = files.contains { file in
                guard audioExtensions.contains(file.pathExtension.lowercased()) else { return false }
                guard let audio = try? AVAudioFile(forReading: file) else { return false }
                return audio.length > 0
            }
            let hasTranscript = files.contains { file in
                guard file.pathExtension.lowercased() == "txt", !file.lastPathComponent.lowercased().hasSuffix(".ffmpeg.log") else { return false }
                return ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            }
            let hasPublicationReceipt = files.contains {
                $0.lastPathComponent.lowercased().hasSuffix("_receipt.json")
            }
            return hasAudio && !hasTranscript && !hasPublicationReceipt
                && !isTranscriptionProcessActive(for: session, activeCommands: activeCommands)
        }
        .max {
            let left = meetingSessionDate(from: $0.lastPathComponent) ?? .distantPast
            let right = meetingSessionDate(from: $1.lastPathComponent) ?? .distantPast
            return left < right
        }
}

func meetingSessionDate(from directoryName: String) -> Date? {
    guard directoryName.count >= 15 else { return nil }
    let prefix = String(directoryName.prefix(15))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.date(from: prefix)
}

func countPendingAudioFiles(in url: URL, processedSourcesFile: URL, stableSeconds: Int) -> Int {
    let extensions = Set(["m4a", "mp3", "wav", "aac", "flac", "mp4", "mov"])
    let processed = loadProcessedSourceKeys(from: processedSourcesFile)
    let now = Date().timeIntervalSince1970
    let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
    return items.filter { item in
        guard extensions.contains(item.pathExtension.lowercased()) else { return false }
        guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return false }
        guard let modified = values.contentModificationDate, let size = values.fileSize, size > 0 else { return false }
        guard now - modified.timeIntervalSince1970 >= Double(stableSeconds) else { return false }
        return !processed.contains(sourceKey(for: item, size: size, modified: modified))
    }.count
}

func loadProcessedSourceKeys(from url: URL) -> Set<String> {
    guard
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    return Set(object.keys)
}

func sourceKey(for url: URL, size: Int, modified: Date) -> String {
    let resolved = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
    return "\(resolved)::\(size)::\(Int(modified.timeIntervalSince1970))"
}

func fileStableSeconds(_ env: [String: String]) -> Int {
    Int(env["FILE_STABLE_SECONDS"] ?? "10") ?? 10
}

func countTodaySessions(in url: URL) -> Int {
    let calendar = Calendar.current
    let items = (try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return items.filter { item in
        guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
              values.isDirectory == true,
              let date = values.contentModificationDate else { return false }
        return calendar.isDateInToday(date)
    }.count
}
