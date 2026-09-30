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


enum TranscribeXAutomationError: LocalizedError {
    case accessibilityDenied
    case appNotInstalled
    case launchFailed(String)
    case controlsNotFound
    case recordingNotConfirmed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Meeting Pilot non ha il permesso Accessibilità necessario per premere i controlli di TranscribeX."
        case .appNotInstalled:
            return "TranscribeX non è installato nella cartella Applicazioni."
        case .launchFailed(let detail):
            return "Non riesco ad aprire TranscribeX: \(detail)"
        case .controlsNotFound:
            return "TranscribeX è aperto, ma non trovo i controlli “Recording App” e “Start Recording”. Apri la schermata principale di TranscribeX e riprova."
        case .recordingNotConfirmed:
            return "Ho inviato il comando a TranscribeX, ma non è comparso alcun nuovo file audio. Controlla i permessi di registrazione schermo di TranscribeX."
        }
    }
}

final class TranscribeXAutomation {
    private enum Phase {
        case locateControls
        case confirmRecording
    }

    private let bundleIdentifier = "com.wlly.janome.AudioTranscribe"
    private let outputFolder: URL
    private let requestedAt = Date()
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AudioTranscribe/data/log/app.log")
    private var initialLogSize: UInt64 = 0
    private var phase = Phase.locateControls
    private var attempts = 0
    private var completion: ((Result<Void, Error>) -> Void)?

    init(outputFolder: URL) {
        self.outputFolder = outputFolder
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        guard AXIsProcessTrusted() else {
            finish(.failure(TranscribeXAutomationError.accessibilityDenied))
            return
        }
        initialLogSize = fileSize(at: logURL)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            finish(.failure(TranscribeXAutomationError.appNotInstalled))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.finish(.failure(TranscribeXAutomationError.launchFailed(error.localizedDescription)))
                    return
                }
                application?.activate(options: [.activateIgnoringOtherApps])
                self.scheduleStep(after: 0.8)
            }
        }
    }

    private func scheduleStep(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.step()
        }
    }

    private func step() {
        guard completion != nil else { return }
        if recordingWasConfirmed() {
            finish(.success(()))
            return
        }

        attempts += 1
        switch phase {
        case .locateControls:
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                if attempts < 12 {
                    scheduleStep(after: 0.5)
                } else {
                    finish(.failure(TranscribeXAutomationError.launchFailed("processo non disponibile")))
                }
                return
            }

            app.activate(options: [.activateIgnoringOtherApps])
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let elements = accessibilityElements(from: root)

            if pressFirst(
                in: elements,
                matching: ["start recording", "avvia registrazione", "start record", "record now"]
            ) {
                phase = .confirmRecording
                attempts = 0
                scheduleStep(after: 0.7)
                return
            }

            if pressFirst(
                in: elements,
                matching: ["microsoft teams"],
                exact: true
            ) {
                scheduleStep(after: 0.6)
                return
            }

            if pressFirst(
                in: elements,
                matching: ["recording app", "app audio recording"],
                exact: true
            ) {
                scheduleStep(after: 0.7)
                return
            }

            if attempts < 16 {
                scheduleStep(after: 0.5)
            } else {
                finish(.failure(TranscribeXAutomationError.controlsNotFound))
            }

        case .confirmRecording:
            if attempts < 16 {
                scheduleStep(after: 0.5)
            } else {
                finish(.failure(TranscribeXAutomationError.recordingNotConfirmed))
            }
        }
    }

    private func recordingWasConfirmed() -> Bool {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let currentSize = attributes[.size] as? NSNumber,
           currentSize.uint64Value > initialLogSize,
           let handle = try? FileHandle(forReadingFrom: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: initialLogSize)
                let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if text.localizedCaseInsensitiveContains("[AppAudioRecordingVM] recording started") {
                    return true
                }
            } catch {
                AppLog.append("Verifica log TranscribeX non riuscita: \(error.localizedDescription)")
            }
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: outputFolder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.contains { url in
            guard ["m4a", "wav", "caf", "mp3"].contains(url.pathExtension.lowercased()) else { return false }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return date >= requestedAt.addingTimeInterval(-1)
        }
    }

    private func accessibilityElements(from root: AXUIElement, maximumCount: Int = 900) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [AXUIElement] = [root]
        var index = 0
        while index < queue.count, result.count < maximumCount {
            let element = queue[index]
            index += 1
            result.append(element)
            if let children = attribute(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return result
    }

    private func pressFirst(
        in elements: [AXUIElement],
        matching phrases: [String],
        exact: Bool = false
    ) -> Bool {
        for element in elements {
            guard isEnabled(element), supportsPress(element) else { continue }
            let label = accessibilityLabel(for: element)
            guard !label.isEmpty else { continue }
            let matches = phrases.contains { phrase in
                let target = normalized(phrase)
                return exact
                    ? (label == target || label.hasPrefix("\(target) ") || label.hasSuffix(" \(target)"))
                    : label.contains(target)
            }
            if matches, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                AppLog.append("Controllo TranscribeX premuto: \(label)")
                return true
            }
        }
        return false
    }

    private func accessibilityLabel(for element: AXUIElement) -> String {
        let names: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXIdentifierAttribute as CFString
        ]
        let parts = names.compactMap { name -> String? in
            guard let value = attribute(name, of: element) else { return nil }
            return value as? String
        }
        return normalized(parts.joined(separator: " "))
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let values = actions as? [String] else { return false }
        return values.contains(kAXPressAction as String)
    }

    private func isEnabled(_ element: AXUIElement) -> Bool {
        guard let value = attribute(kAXEnabledAttribute as CFString, of: element) else { return true }
        if let enabled = value as? Bool { return enabled }
        if let enabled = value as? NSNumber { return enabled.boolValue }
        return true
    }

    private func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func fileSize(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
}

enum NativeRecorderError: LocalizedError {
    case microphoneDenied
    case systemAudioDenied
    case systemAudioRequiresTapAPI
    case alreadyRecording
    case couldNotCreateFile
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Permesso microfono non concesso. Apri Impostazioni macOS > Privacy e sicurezza > Microfono."
        case .systemAudioDenied:
            return "Per registrare anche le voci degli altri, abilita Meeting Pilot in Solo registrazione audio di sistema, quindi riapri l'app prima di riprovare."
        case .systemAudioRequiresTapAPI:
            return "La registrazione combinata di audio di sistema e microfono richiede macOS 14.2 o successivo."
        case .alreadyRecording:
            return "C'e' gia' una registrazione nativa in corso."
        case .couldNotCreateFile:
            return "Non riesco a creare il file audio nella cartella configurata."
        case .couldNotStart:
            return "Il recorder audio di sistema non e' riuscito ad avviare la registrazione."
        }
    }
}

final class NativeAudioRecorder: NSObject {
    private var recorder: AnyObject?
    private var currentURL: URL?
    private var recording = false
    private var paused = false
    private var stopping = false
    var onStateChange: ((Bool, URL?) -> Void)?
    var onFinished: ((URL, Error?) -> Void)?

    var isRecording: Bool {
        recording
    }

    func start(folder: URL, title: String, completion: @escaping (Result<URL, Error>) -> Void) {
        if isRecording {
            completion(.failure(NativeRecorderError.alreadyRecording))
            return
        }

        let startRecording = { [weak self] in
            guard let self else { return }
            guard #available(macOS 14.2, *) else {
                completion(.failure(NativeRecorderError.systemAudioRequiresTapAPI))
                return
            }

            let recorder = SystemMeetingAudioRecorder()
            self.recorder = recorder
            recorder.start(folder: folder, title: title) { [weak self, weak recorder] result in
                guard let self, recorder != nil else { return }
                switch result {
                case .success(let url):
                    SystemAudioPermissionState.setConfirmed(true)
                    self.recording = true
                    self.paused = false
                    self.stopping = false
                    self.currentURL = url
                    self.onStateChange?(true, url)
                    completion(.success(url))
                case .failure(let error):
                    SystemAudioPermissionState.setConfirmed(false)
                    self.recorder = nil
                    self.currentURL = nil
                    self.recording = false
                    self.paused = false
                    self.stopping = false
                    completion(.failure(error))
                }
            } onFinished: { [weak self, weak recorder] url, warning in
                guard let self, recorder != nil else { return }
                self.recorder = nil
                self.currentURL = url
                self.recording = false
                self.stopping = false
                self.onStateChange?(false, url)
                self.onFinished?(url, warning)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    granted ? startRecording() : completion(.failure(NativeRecorderError.microphoneDenied))
                }
            }
        default:
            completion(.failure(NativeRecorderError.microphoneDenied))
        }
    }

    func stop() -> URL? {
        let url = currentURL
        guard recording, !stopping else { return url }
        stopping = true
        if #available(macOS 14.2, *), let recorder = recorder as? SystemMeetingAudioRecorder {
            recorder.stop()
        }
        return url
    }

    func pause() -> Bool {
        guard recording, !paused, !stopping,
              #available(macOS 14.2, *),
              let recorder = recorder as? SystemMeetingAudioRecorder else { return false }
        recorder.pause()
        paused = true
        return true
    }

    func resume() -> Bool {
        guard recording, paused, !stopping,
              #available(macOS 14.2, *),
              let recorder = recorder as? SystemMeetingAudioRecorder else { return false }
        recorder.resume()
        paused = false
        return true
    }

    fileprivate static func fileName(for title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let date = formatter.string(from: Date())
        let cleanTitle = sanitize(title).prefix(80)
        return "Meeting Pilot - \(date) - \(cleanTitle).m4a"
    }

    fileprivate static func lockURL(for audioURL: URL) -> URL {
        URL(fileURLWithPath: audioURL.path + ".recording")
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Teams meeting" : text.replacingOccurrences(of: "  ", with: " ")
    }
}

@available(macOS 14.2, *)
final class SystemMeetingAudioRecorder: NSObject {
    private let ioQueue = DispatchQueue(label: "\(AppIdentity.bundleID).system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var systemAudioFile: ExtAudioFileRef?
    private var microphoneRecorder: AVAudioRecorder?
    /// A second, read-only client of the microphone that only feeds live transcription;
    /// the file on disk still comes from `microphoneRecorder`, so a failure here can
    /// never cost the recording.
    private var liveMicrophoneEngine: AVAudioEngine?
    private var finalURL: URL?
    private var systemAudioURL: URL?
    private var microphoneURL: URL?
    private var finishHandler: ((URL, Error?) -> Void)?
    private var finalizationStarted = false
    private var paused = false
    private var livePipeline: LiveMeetingPipeline?
    private var speakerTracker: TeamsSpeakerTracker?

    func start(
        folder: URL,
        title: String,
        completion: @escaping (Result<URL, Error>) -> Void,
        onFinished: @escaping (URL, Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let finalURL = folder.appendingPathComponent(NativeAudioRecorder.fileName(for: title))
                let temporaryStem = "MeetingPilot-\(UUID().uuidString)"
                let systemAudioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(temporaryStem)-system.caf")
                let microphoneURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(temporaryStem)-microphone.m4a")
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.removeItem(at: systemAudioURL)
                try? FileManager.default.removeItem(at: microphoneURL)
                guard FileManager.default.createFile(
                    atPath: NativeAudioRecorder.lockURL(for: finalURL).path,
                    contents: Data()
                ) else {
                    throw NativeRecorderError.couldNotCreateFile
                }

                self.finalURL = finalURL
                self.systemAudioURL = systemAudioURL
                self.microphoneURL = microphoneURL
                self.finishHandler = onFinished

                let sidecar = MeetingSidecar.directory(for: finalURL)
                try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
                try self.createSystemAudioTap(outputURL: systemAudioURL, sessionFolder: sidecar)
                try self.prepareMicrophone(outputURL: microphoneURL)
                try self.requireNoError(
                    AudioDeviceStart(self.aggregateDeviceID, self.ioProcID),
                    operation: "Avvio acquisizione audio di sistema"
                )
                guard self.microphoneRecorder?.record() == true else {
                    throw NativeRecorderError.couldNotStart
                }
                self.startLiveMicrophone()
                let speakerTracker = TeamsSpeakerTracker(outputURL: MeetingSidecar.teamsSpeakersURL(for: finalURL))
                speakerTracker.start()
                self.speakerTracker = speakerTracker
                completion(.success(finalURL))
            } catch {
                self.cleanupFailedStart()
                completion(.failure(error))
            }
        }
    }

    func stop() {
        guard !finalizationStarted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.stopCaptureComponents()
            self.beginFinalization()
        }
    }

    func pause() {
        guard !paused, !finalizationStarted else { return }
        ioQueue.async {
            self.microphoneRecorder?.pause()
            self.liveMicrophoneEngine?.pause()
            self.speakerTracker?.pause()
            if self.aggregateDeviceID != kAudioObjectUnknown, let ioProcID = self.ioProcID {
                AudioDeviceStop(self.aggregateDeviceID, ioProcID)
            }
            self.paused = true
        }
    }

    func resume() {
        guard paused, !finalizationStarted else { return }
        ioQueue.async {
            guard self.aggregateDeviceID != kAudioObjectUnknown, let ioProcID = self.ioProcID else { return }
            guard AudioDeviceStart(self.aggregateDeviceID, ioProcID) == noErr else { return }
            self.microphoneRecorder?.record()
            try? self.liveMicrophoneEngine?.start()
            self.speakerTracker?.resume()
            self.paused = false
        }
    }

    private func beginFinalization() {
        guard !finalizationStarted,
              let systemAudioURL,
              let microphoneURL,
              let finalURL else { return }
        finalizationStarted = true
        livePipeline?.finalize()
        livePipeline = nil
        speakerTracker?.finish()
        speakerTracker = nil
        Task {
            do {
                try await mixAudioTracks(from: [systemAudioURL, microphoneURL], into: finalURL)
                await saveSeparateTracks(system: systemAudioURL, microphone: microphoneURL, for: finalURL)
                try? FileManager.default.removeItem(at: systemAudioURL)
                try? FileManager.default.removeItem(at: microphoneURL)
                try? FileManager.default.removeItem(at: NativeAudioRecorder.lockURL(for: finalURL))
                complete(url: finalURL, warning: nil)
            } catch {
                finishWithFallback(error)
            }
        }
    }

    /// Keeps the microphone and system audio as separate files so the pipeline can label
    /// the person recording without relying on diarization. Best-effort: the mixed file is
    /// already saved, and the pipeline falls back to it when these tracks are missing.
    /// Runs before the `.recording` lock is removed, so the watcher never sees half of them.
    private func saveSeparateTracks(system systemURL: URL, microphone microphoneURL: URL, for finalURL: URL) async {
        let tracks = MeetingSidecar.tracksDirectory(for: finalURL)
        do {
            try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
            // The system tap is raw float PCM (~1.4 GB/hour); the microphone is already AAC.
            let exporter = AVAssetExportSession(asset: AVURLAsset(url: systemURL), presetName: AVAssetExportPresetAppleM4A)
            guard let exporter else { throw NativeRecorderError.couldNotCreateFile }
            try await exporter.export(to: tracks.appendingPathComponent("them.m4a"), as: .m4a)
            try FileManager.default.copyItem(at: microphoneURL, to: tracks.appendingPathComponent("me.m4a"))
        } catch {
            try? FileManager.default.removeItem(at: tracks)
            AppLog.append("Tracce separate non salvate, verrà usata la registrazione unica: \(error.localizedDescription)")
        }
    }

    private func mixAudioTracks(from sourceURLs: [URL], into outputURL: URL) async throws {
        let composition = AVMutableComposition()
        var mixedTracks: [AVMutableCompositionTrack] = []
        for sourceURL in sourceURLs {
            let source = AVURLAsset(url: sourceURL)
            let sourceTracks = try await source.loadTracks(withMediaType: .audio)
            for sourceTrack in sourceTracks {
                guard let track = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                let timeRange = try await sourceTrack.load(.timeRange)
                try track.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
                mixedTracks.append(track)
            }
        }
        guard !mixedTracks.isEmpty,
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw NativeRecorderError.couldNotCreateFile }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixedTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(mixedTracks.count > 1 ? 0.82 : 1.0, at: .zero)
            return parameters
        }
        exporter.audioMix = audioMix
        try? FileManager.default.removeItem(at: outputURL)
        try await exporter.export(to: outputURL, as: .m4a)
    }

    private func finishWithFallback(_ error: Error) {
        guard let finalURL else { return }
        // Preserve the microphone recording as a usable fallback instead of
        // losing the whole meeting if the final mix cannot be exported.
        if let microphoneURL, FileManager.default.fileExists(atPath: microphoneURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
            do {
                try FileManager.default.moveItem(at: microphoneURL, to: finalURL)
            } catch {
                // The microphone track stays where it is; say where, so it can be recovered by hand.
                AppLog.append("Recupero traccia microfono non riuscito, resta in \(microphoneURL.path): \(error.localizedDescription)")
            }
        }
        if let systemAudioURL { try? FileManager.default.removeItem(at: systemAudioURL) }
        try? FileManager.default.removeItem(at: NativeAudioRecorder.lockURL(for: finalURL))
        complete(url: finalURL, warning: error)
    }

    private func complete(url: URL, warning: Error?) {
        let handler = finishHandler
        finishHandler = nil
        handler?(url, warning)
    }

    private func cleanupFailedStart() {
        livePipeline?.finalize()
        livePipeline = nil
        speakerTracker?.finish()
        speakerTracker = nil
        stopCaptureComponents()
        if let systemAudioURL { try? FileManager.default.removeItem(at: systemAudioURL) }
        if let microphoneURL { try? FileManager.default.removeItem(at: microphoneURL) }
        if let finalURL {
            try? FileManager.default.removeItem(at: NativeAudioRecorder.lockURL(for: finalURL))
            try? FileManager.default.removeItem(at: MeetingSidecar.directory(for: finalURL))
        }
        finishHandler = nil
    }

    private func createSystemAudioTap(outputURL: URL, sessionFolder: URL) throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "Meeting Pilot System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try requireNoError(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "Creazione tap audio di sistema"
        )
        self.tapID = tapID

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.stride)
        var tapUID: CFString = "" as CFString
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) {
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
        }
        try requireNoError(uidStatus, operation: "Lettura identificatore tap audio")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Pilot Audio Capture",
            kAudioAggregateDeviceUIDKey: "\(AppIdentity.bundleID).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        try requireNoError(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
            operation: "Creazione dispositivo audio privato"
        )
        self.aggregateDeviceID = aggregateDeviceID

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        try requireNoError(
            AudioObjectGetPropertyData(aggregateDeviceID, &formatAddress, 0, nil, &formatSize, &format),
            operation: "Lettura formato audio di sistema"
        )
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw NativeRecorderError.couldNotStart
        }

        livePipeline = LiveMeetingPipeline(sourceFormat: format, sessionFolder: sessionFolder)

        var file: ExtAudioFileRef?
        try requireNoError(
            ExtAudioFileCreateWithURL(
                outputURL as CFURL,
                kAudioFileCAFType,
                &format,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &file
            ),
            operation: "Creazione file audio di sistema"
        )
        guard let file else { throw NativeRecorderError.couldNotCreateFile }
        self.systemAudioFile = file

        var ioProcID: AudioDeviceIOProcID?
        let bytesPerFrame = max(UInt32(1), format.mBytesPerFrame)
        try requireNoError(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, ioQueue) { [weak self] _, inputData, _, _, _ in
                guard inputData.pointee.mNumberBuffers > 0 else { return }
                let firstBuffer = inputData.pointee.mBuffers
                let frames = firstBuffer.mDataByteSize / bytesPerFrame
                if frames > 0 {
                    ExtAudioFileWriteAsync(file, frames, inputData)
                    self?.livePipeline?.ingest(inputData, frameCount: frames)
                }
            },
            operation: "Preparazione acquisizione audio di sistema"
        )
        self.ioProcID = ioProcID
    }

    private func prepareMicrophone(outputURL: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.prepareToRecord()
        microphoneRecorder = recorder
    }

    private func startLiveMicrophone() {
        guard let pipeline = livePipeline else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("LiveMeetingPipeline: microphone input format unavailable, live transcript of own voice disabled")
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            pipeline.ingestMicrophone(buffer)
        }
        do {
            try engine.start()
            liveMicrophoneEngine = engine
        } catch {
            input.removeTap(onBus: 0)
            NSLog("LiveMeetingPipeline: microphone engine failed, live transcript of own voice disabled: \(error)")
        }
    }

    private func stopCaptureComponents() {
        microphoneRecorder?.stop()
        microphoneRecorder = nil
        liveMicrophoneEngine?.inputNode.removeTap(onBus: 0)
        liveMicrophoneEngine?.stop()
        liveMicrophoneEngine = nil

        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if let systemAudioFile {
            ExtAudioFileDispose(systemAudioFile)
        }
        systemAudioFile = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func requireNoError(_ status: OSStatus, operation: String) throws {
        guard status != noErr else { return }
        if status == kAudioDevicePermissionsError {
            throw NativeRecorderError.systemAudioDenied
        }
        throw NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) non riuscita (codice \(status))."]
        )
    }
}

final class RecordingPromptWindow {
    static let shared = RecordingPromptWindow()

    private var panel: NSPanel?
    private var closeWorkItem: DispatchWorkItem?

    func show(meetingTitle: String, timeoutSeconds: TimeInterval, onRecord: @escaping () -> Void) {
        close()

        let size = NSSize(width: 440, height: 82)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let view = RecordingPromptView(
            meetingTitle: meetingTitle,
            timeoutSeconds: timeoutSeconds,
            onClose: { [weak self] in self?.close() },
            onRecord: { [weak self] in
                self?.close()
                onRecord()
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
        self.panel = panel

        let item = DispatchWorkItem { [weak self] in
            self?.close()
        }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
    }

    func close() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 18
        )
    }
}

/// Drives the floating coaching bubble's live state. Owned by `PermissionCoachWindow`
/// rather than the SwiftUI view itself, since the view is a value type recreated by
/// `NSHostingController` and can't hold the poll `Timer` across updates.
final class PermissionCoachState: ObservableObject {
    @Published var granted = false
}

/// A floating, non-activating bubble that stays on screen (above System Settings, which
/// takes keyboard/mouse focus) pointing the user at the exact toggle to flip — modeled on
/// Granola's "drag app to this list" coaching overlay. For permissions macOS lets us poll
/// live (Accessibility), it auto-detects the grant and closes itself; for permissions that
/// only update after a relaunch (Screen/System Audio Recording), it instead offers a
/// restart action once the user confirms they flipped the toggle.
final class PermissionCoachWindow {
    static let shared = PermissionCoachWindow()

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private var autoCloseWorkItem: DispatchWorkItem?
    private let state = PermissionCoachState()

    func show(
        permissionTitle: String,
        settingsPath: String,
        autoDetect: (() -> Bool)?,
        onRestart: (() -> Void)? = nil
    ) {
        close()
        state.granted = false

        let size = NSSize(width: 360, height: 168)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let view = PermissionCoachView(
            state: state,
            permissionTitle: permissionTitle,
            settingsPath: settingsPath,
            canAutoDetect: autoDetect != nil,
            onClose: { [weak self] in self?.close() },
            onRestart: onRestart
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
        self.panel = panel

        if let autoDetect {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard !self.state.granted, autoDetect() else { return }
                self.state.granted = true
                timer.invalidate()
                let item = DispatchWorkItem { [weak self] in self?.close() }
                self.autoCloseWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        autoCloseWorkItem?.cancel()
        autoCloseWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.minX + 24, y: frame.minY + 24)
    }
}

struct PermissionCoachView: View {
    @ObservedObject var state: PermissionCoachState
    let permissionTitle: String
    let settingsPath: String
    let canAutoDetect: Bool
    let onClose: () -> Void
    let onRestart: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attiva \(permissionTitle)")
                        .font(.system(size: 15, weight: .bold))
                    Text(settingsPath)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.accent)
                    // A slow, low-amplitude idle pulse — enough to draw the eye to a
                    // still-open coaching bubble without the exaggerated bounce of a
                    // notification badge. Off entirely under Reduce Motion.
                    .offset(y: pulse && !reduceMotion ? -2 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                Text("Trova **Meeting Pilot** nell'elenco che si e' aperto e attiva l'interruttore accanto al nome.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if state.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MeetingPilotDesign.success)
                    Text("Permesso concesso")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MeetingPilotDesign.success)
                } else if canAutoDetect {
                    ProgressView()
                        .controlSize(.small)
                    Text("In attesa del permesso...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                } else if let onRestart {
                    Text("Questo permesso si aggiorna solo dopo un riavvio dell'app.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button("Riavvia ora") {
                        onClose()
                        onRestart()
                    }
                    .buttonStyle(CompactButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        // Real Liquid Glass on macOS 26+ (this app's own meetingPilotGlass() helper),
        // regularMaterial fallback below that — see the helper's definition near the
        // top of this file for why: .glassEffect() isn't available pre-26.
        .meetingPilotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        .overlay(alignment: .top) {
            // Faint top-edge highlight: on the pre-26 material fallback this is the
            // closest approximation of Liquid Glass's real-time specular lensing.
            LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.78)) {
                appeared = true
            }
            pulse = true
        }
    }
}
