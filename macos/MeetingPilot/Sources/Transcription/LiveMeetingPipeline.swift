import AVFoundation
import CoreAudio
import FluidAudio
import Foundation

/// Feeds the raw system-audio tap into FluidAudio's `DiarizerManager` while a meeting is
/// still recording, so speaker turns can be surfaced before the meeting ends, and runs
/// streaming ASR on system audio ("them"), and on the microphone ("me") only while the
/// system audio isn't arriving. Lines from the system leg are named after the Teams
/// participant who was talking while they were spoken (see `TeamsSpeakerTracker`).
///
/// This is best-effort and additive: any failure here (missing models, conversion errors,
/// a slow diarization pass) must never affect the primary recording path in
/// `MeetingAudioRecorder`. Only the system-audio leg is diarized — the microphone
/// is by definition the local participant, so it's labelled rather than clustered.
/// A microphone-only recording has no system audio: there the microphone hears the whole
/// room and is the diarized leg ("room"), with no "me" leg at all.
/// `@unchecked Sendable`: all mutable state is confined to `queue`, a single serial
/// dispatch queue, so it's safe to capture `self` in the `@Sendable` closures handed to
/// `StreamingNemotronMultilingualAsrManager` (an actor) even though the compiler can't
/// verify that itself.
final class LiveMeetingPipeline: @unchecked Sendable {
    /// The audio whose voices are clustered into speakers.
    enum DiarizedLeg {
        /// The Mac's audio during a call: everyone but the person recording ("them").
        case systemAudio
        /// The only microphone of an in-person recording: everyone, including the person recording ("room").
        case roomMicrophone
    }

    struct LiveSpeakerSegment: Codable {
        let speakerId: String
        let startSeconds: Double
        let endSeconds: Double
        let qualityScore: Float
    }

    struct LiveTranscriptEntry: Codable {
        let text: String
        let kind: String  // "partial" (ghost text, may be revised) or "final" (line closed on a pause)
        let atSeconds: Double
        let speaker: String  // "me" (microphone), "them" (system audio) or "room" (microphone-only recording)
        /// The Teams participant who was talking, for "them" lines when the tracker saw one.
        let name: String?
    }

    /// Diarization runs a few seconds behind real time (one call per window), so the
    /// window length trades sidebar latency against DiarizerManager's per-call cost.
    private static let windowSeconds: Double = 12
    private static let targetSampleRate: Double = 16000

    /// Nemotron has no end-of-utterance signal — its partials just keep growing — so a
    /// sidebar line is closed after this much quiet audio, or after
    /// `maxUtteranceSeconds` of uninterrupted speech so a monologue can't become one
    /// endless paragraph.
    private static let pauseSecondsToCloseLine: Double = 1.2
    private static let maxUtteranceSeconds: Double = 30
    /// RMS below this counts as a pause. Teams system audio is digitally clean between
    /// speakers, so it only needs to sit above codec/comfort noise; a microphone always
    /// carries room noise, so its floor is higher.
    private static let systemSilenceRMS: Float = 0.005
    private static let microphoneSilenceRMS: Float = 0.015
    /// Without the "system audio recording" permission macOS still creates the tap but
    /// feeds it exact zeros, so the others' voices only reach the microphone (through the
    /// speakers) and every line comes out as "me". Exact silence this long while the
    /// microphone hears speech means that, not a quiet call.
    private static let silentTapCheckSeconds: Double = 20
    /// Teams moves the speaking border a little after the audio starts and drops it a
    /// little after it stops, so a line's span is widened by these before matching.
    private static let speakerLeadSeconds: TimeInterval = 0.5
    private static let speakerTrailSeconds: TimeInterval = 1.0
    /// Teams calls rarely leave a clean pause between two people, so a system-audio line
    /// is also closed when the Teams speaking border moves to someone else; otherwise one
    /// line held both people's words under a single name. "Who is talking now" is the
    /// dominant border over this trailing window, checked this often. The line's own
    /// speaker is read only after this much of its speech, past the previous speaker's
    /// lingering border, and the line is split only after twice that, so crosstalk
    /// doesn't shred it into scraps.
    private static let speakerChangeWindowSeconds: TimeInterval = 1.0
    private static let speakerChangeCheckSeconds: TimeInterval = 0.3
    private static let speechSecondsBeforeLineSpeaker: Double = 1.2
    /// 1120 ms is FluidAudio's smallest chunk that keeps punctuation stable over long
    /// sessions (the 560 ms tier drifts, see its `downloadAndPreloadShared` docs).
    private static let asrChunkMs = 1120

    private let sessionFolder: URL
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let manager = DiarizerManager(config: .default)
    private let asrLanguage: String

    /// All diarization calls and buffer bookkeeping happen on this single serial queue so
    /// `performCompleteDiarization` is never invoked concurrently with itself — the
    /// FluidAudio docs call diarizer instances not thread-safe. Each ASR manager
    /// is itself an actor (self-serializing); its input is yielded from this same
    /// queue so it stays in audio-arrival order even though it executes elsewhere.
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).live-diarizer", qos: .utility)
    private var modelsReady = false
    private var pendingSamples: [Float] = []
    private var windowStartOffset: Double = 0
    private var segments: [LiveSpeakerSegment] = []
    private var transcript: [LiveTranscriptEntry] = []
    private var sessionStartedAt = Date()

    private var diarizedAsr: AsrLeg!
    /// Created on the first microphone buffer, since only then is its format known.
    private var microphoneAsr: AsrLeg?
    private var finalized = false
    private var systemSeconds: Double = 0
    private var systemHeardSignal = false
    private var microphoneHeardSpeech = false
    private var systemAudioSilent = false
    /// Names the participant talking between two system-uptime instants.
    private var speakerResolver: ((TimeInterval, TimeInterval) -> String?)?
    /// Both legs share one download + preload. FluidAudio doesn't coordinate concurrent
    /// calls, so on a Mac without the model cached two legs downloading into the same
    /// folder at once could fail one of them — typically leaving the system leg dead, so
    /// the others were only heard through the microphone and labelled "me".
    private var sharedAsrModels: Task<SharedNemotronMultilingualModels, Error>!

    /// One streaming ASR manager per audio leg: Nemotron keeps per-utterance decoder
    /// state, so interleaving two speakers through one manager would garble both.
    /// Buffers go through one ordered stream drained by a single task — spawning a
    /// `Task` per buffer let them reach the actor out of order and interleave across its
    /// internal `await`s, which garbled the transcript.
    private final class AsrLeg: @unchecked Sendable {
        let speaker: String
        let sampleRate: Double
        let silenceRMS: Float
        let manager = StreamingNemotronMultilingualAsrManager()
        let input: AsyncStream<AsrChunk>.Continuation
        let stream: AsyncStream<AsrChunk>
        var ready = false  // confined to the pipeline's queue
        /// System uptime when the open line's first speech was captured; confined to the queue.
        var utteranceStartedAt: TimeInterval?

        init(speaker: String, sampleRate: Double, silenceRMS: Float) {
            self.speaker = speaker
            self.sampleRate = sampleRate
            self.silenceRMS = silenceRMS
            (stream, input) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        }
    }

    private struct AsrChunk: @unchecked Sendable {
        let pcm: AVAudioPCMBuffer
        let seconds: Double
        let isSilent: Bool
        /// System uptime when the chunk's last sample was captured.
        let capturedAt: TimeInterval
    }

    /// Returns nil (rather than throwing) when the system audio format can't be bridged
    /// to FluidAudio's expected 16kHz mono input — live diarization is simply skipped.
    convenience init?(sourceFormat sourceASBD: AudioStreamBasicDescription, sessionFolder: URL) {
        var asbd = sourceASBD
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        self.init(format: sourceFormat, sessionFolder: sessionFolder, diarizedLeg: .systemAudio)
    }

    init?(format sourceFormat: AVAudioFormat, sessionFolder: URL, diarizedLeg: DiarizedLeg) {
        guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            return nil
        }
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.sessionFolder = sessionFolder
        self.sessionStartedAt = Date()
        self.asrLanguage = AppLanguage.current.asrLanguageCode

        queue.async { [self] in loadDiarizationModels() }
        let language = asrLanguage
        sharedAsrModels = Task {
            try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: language, chunkMs: Self.asrChunkMs)
        }
        let leg = diarizedLeg == .systemAudio
            ? AsrLeg(speaker: "them", sampleRate: sourceFormat.sampleRate, silenceRMS: Self.systemSilenceRMS)
            : AsrLeg(speaker: "room", sampleRate: sourceFormat.sampleRate, silenceRMS: Self.microphoneSilenceRMS)
        diarizedAsr = leg
        startAsr(leg)
    }

    private func loadDiarizationModels() {
        let modelsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization")
        let segmentationModel = modelsDir.appendingPathComponent("pyannote_segmentation.mlmodelc")
        let embeddingModel = modelsDir.appendingPathComponent("wespeaker_v2.mlmodelc")
        do {
            let models = try DiarizerModels.load(
                localSegmentationModel: segmentationModel, localEmbeddingModel: embeddingModel)
            manager.initialize(models: models)
            modelsReady = true
        } catch {
            NSLog("LiveMeetingPipeline: diarization models unavailable, live speaker sidebar disabled: \(error)")
        }
    }

    private func startAsr(_ leg: AsrLeg) {
        Task { [self] in
            await loadAsrModels(leg)
            await drainAsrInput(leg)
        }
    }

    /// The streaming ASR model is not part of the app's bundled FluidAudio resources —
    /// this downloads it from Hugging Face on first use (~590 MB,
    /// `Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`) and reuses the cache after.
    private func loadAsrModels(_ leg: AsrLeg) async {
        let speaker = leg.speaker
        await leg.manager.setPartialCallback { [weak self, weak leg] text in
            guard let leg else { return }
            self?.recordTranscript(text, kind: "partial", leg: leg)
        }
        do {
            let shared = try await sharedAsrModels.value
            try await leg.manager.loadFromShared(shared)
            await leg.manager.setLanguage(asrLanguage)
            queue.sync { leg.ready = true }
            NSLog("LiveMeetingPipeline: streaming ASR ready for \(speaker)")
        } catch {
            AppLog.append("Trascrizione dal vivo non disponibile per \(speaker == "them" ? "audio di sistema" : "microfono"): \(error.localizedDescription)")
        }
    }

    /// Partials carry the whole utterance so far, so each one replaces that speaker's
    /// trailing partial instead of stacking a new line; the final that closes the line
    /// replaces it too. The other leg may have appended lines in between.
    private func recordTranscript(_ text: String, kind: String, leg: AsrLeg) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let speaker = leg.speaker
        queue.async { [self] in
            let atSeconds = Date().timeIntervalSince(sessionStartedAt)
            let now = ProcessInfo.processInfo.systemUptime
            let name = speakerName(for: leg, from: leg.utteranceStartedAt ?? now, to: now)
            let entry = LiveTranscriptEntry(text: text, kind: kind, atSeconds: atSeconds, speaker: speaker, name: name)
            if let index = openPartialIndex(for: speaker) {
                transcript[index] = entry
            } else {
                transcript.append(entry)
            }
            writeLiveState()
        }
    }

    /// Called by the recorder once the Teams tracker is running.
    func setSpeakerResolver(_ resolver: @escaping (TimeInterval, TimeInterval) -> String?) {
        queue.async { [self] in speakerResolver = resolver }
    }

    /// Only remote voices get a Teams name; the microphone is always the local user.
    private func speakerName(for leg: AsrLeg, from start: TimeInterval, to end: TimeInterval) -> String? {
        guard leg.speaker == "them" else { return nil }
        return speakerResolver?(start - Self.speakerLeadSeconds, end + Self.speakerTrailSeconds)
    }

    /// The Teams participant talking just before `uptime`, without the widening
    /// `speakerName` applies to a whole line.
    private func currentSpeaker(for leg: AsrLeg, at uptime: TimeInterval) -> String? {
        guard leg.speaker == "them", let resolver = queue.sync(execute: { speakerResolver }) else { return nil }
        return resolver(uptime - Self.speakerChangeWindowSeconds, uptime)
    }

    private func openPartialIndex(for speaker: String) -> Int? {
        guard let index = transcript.lastIndex(where: { $0.speaker == speaker }),
              transcript[index].kind == "partial"
        else { return nil }
        return index
    }

    private func drainAsrInput(_ leg: AsrLeg) async {
        guard queue.sync(execute: { leg.ready }) else { return }
        var utteranceSeconds: Double = 0
        var pauseSeconds: Double = 0
        var heardSpeech = false
        var lastSpeechAt: TimeInterval?
        var speechSeconds: Double = 0
        var lineSpeaker: String?
        var lastSpeakerCheck: TimeInterval = 0
        for await chunk in leg.stream {
            do {
                _ = try await leg.manager.process(audioBuffer: chunk.pcm)
            } catch {
                NSLog("LiveMeetingPipeline: streaming ASR pass failed (\(leg.speaker)): \(error)")
            }
            utteranceSeconds += chunk.seconds
            if chunk.isSilent {
                pauseSeconds += chunk.seconds
            } else {
                pauseSeconds = 0
                speechSeconds += chunk.seconds
                if !heardSpeech {
                    let start = chunk.capturedAt - chunk.seconds
                    queue.sync { leg.utteranceStartedAt = start }
                }
                heardSpeech = true
                lastSpeechAt = chunk.capturedAt
            }
            var speakerChanged = false
            if !chunk.isSilent, speechSeconds >= Self.speechSecondsBeforeLineSpeaker,
               chunk.capturedAt - lastSpeakerCheck >= Self.speakerChangeCheckSeconds {
                lastSpeakerCheck = chunk.capturedAt
                if let current = currentSpeaker(for: leg, at: chunk.capturedAt) {
                    if lineSpeaker == nil {
                        lineSpeaker = current
                    } else if current != lineSpeaker, speechSeconds >= 2 * Self.speechSecondsBeforeLineSpeaker {
                        speakerChanged = true
                    }
                }
            }
            let paused = heardSpeech && pauseSeconds >= Self.pauseSecondsToCloseLine
            if paused || speakerChanged || utteranceSeconds >= Self.maxUtteranceSeconds {
                await closeLine(leg, lastSpeechAt: lastSpeechAt)
                utteranceSeconds = 0
                pauseSeconds = 0
                heardSpeech = false
                lastSpeechAt = nil
                speechSeconds = 0
                lineSpeaker = nil
            }
        }
        await closeLine(leg, lastSpeechAt: lastSpeechAt)
    }

    /// Flushes the buffered audio into a "final" line and starts a fresh utterance, so
    /// the next partial opens a new sidebar line instead of extending this one.
    private func closeLine(_ leg: AsrLeg, lastSpeechAt: TimeInterval?) async {
        var text = ""
        do {
            text = try await leg.manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("LiveMeetingPipeline: failed to flush ASR utterance (\(leg.speaker)): \(error)")
        }
        await leg.manager.reset()
        let speaker = leg.speaker
        queue.async { [self] in
            // An empty flush (noise that produced only a stray partial) drops that
            // partial, so it isn't silently overwritten by the next line.
            let partial = openPartialIndex(for: speaker)
            let startedAt = leg.utteranceStartedAt
            leg.utteranceStartedAt = nil
            if text.isEmpty {
                if let partial { transcript.remove(at: partial) }
            } else {
                let atSeconds = Date().timeIntervalSince(sessionStartedAt)
                // The whole line's span decides the name; a partial's guess is only the fallback.
                let end = lastSpeechAt ?? ProcessInfo.processInfo.systemUptime
                let name = speakerName(for: leg, from: startedAt ?? end, to: end) ?? partial.flatMap { transcript[$0].name }
                let entry = LiveTranscriptEntry(
                    text: text, kind: "final", atSeconds: atSeconds, speaker: speaker, name: name)
                if let partial {
                    transcript[partial] = entry
                } else {
                    transcript.append(entry)
                }
            }
            writeLiveState()
        }
    }

    /// Microphone buffers from the recorder's `AVAudioEngine` input tap, when the Mac's
    /// audio is recorded too: the microphone is then the person recording ("me").
    /// The sidebar shows only the others, so the microphone is transcribed only while the
    /// system-audio tap is silent: the speakers' sound reaches the microphone too, and
    /// transcribing it otherwise put a duplicate of the others' lines under "me".
    func ingestMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [self] in
            guard !finalized else { return }
            if !microphoneHeardSpeech, Self.rms(copy) >= Self.microphoneSilenceRMS { microphoneHeardSpeech = true }
            guard systemAudioSilent else { return }
            let leg: AsrLeg
            if let existing = microphoneAsr {
                leg = existing
            } else {
                leg = AsrLeg(speaker: "me", sampleRate: copy.format.sampleRate, silenceRMS: Self.microphoneSilenceRMS)
                microphoneAsr = leg
                startAsr(leg)
            }
            feedAsr(copy, into: leg)
        }
    }

    /// Microphone buffers of a microphone-only recording (`.roomMicrophone`): the whole
    /// room, diarized like the Mac's audio is during a call.
    func ingestRoom(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [self] in
            guard !finalized else { return }
            processDiarization(copy)
            feedAsr(copy, into: diarizedAsr)
        }
    }

    /// The engine may reuse a tap buffer after the tap block returns, so it is copied first.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let src = source[index].mData, let dst = destination[index].mData else { continue }
            memcpy(dst, src, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }

    /// Must be called from the IOProc block. Copies the buffer synchronously (raw Core
    /// Audio memory is only valid for the duration of the callback) and hands the copy to
    /// `queue` for the actual conversion + diarization work, keeping the audio-capture
    /// callback itself cheap.
    func ingest(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        guard frameCount > 0, let pcmCopy = copyToPCMBuffer(bufferList, frameCount: frameCount) else { return }
        queue.async { [self] in
            checkSystemSignal(pcmCopy)
            processDiarization(pcmCopy)
            feedAsr(pcmCopy, into: diarizedAsr)
        }
    }

    private func checkSystemSignal(_ pcm: AVAudioPCMBuffer) {
        systemSeconds += Double(pcm.frameLength) / sourceFormat.sampleRate
        if Self.rms(pcm) > 0 {
            systemHeardSignal = true
            if systemAudioSilent {
                systemAudioSilent = false
                // The microphone stops being transcribed, so its open line would never close.
                if let partial = openPartialIndex(for: "me") { transcript.remove(at: partial) }
                writeLiveState()
            }
        } else if !systemHeardSignal, !systemAudioSilent, microphoneHeardSpeech,
                  systemSeconds >= Self.silentTapCheckSeconds {
            systemAudioSilent = true
            AppLog.append("Audio di sistema muto da \(Int(systemSeconds))s mentre il microfono sente parlato: permesso Registrazione audio di sistema mancante?")
            writeLiveState()
        }
    }

    private func copyToPCMBuffer(
        _ bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32
    ) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        for index in 0..<min(destination.count, source.count) {
            let byteCount = Int(source[index].mDataByteSize)
            guard byteCount > 0, let src = source[index].mData, let dst = destination[index].mData else { continue }
            memcpy(dst, src, byteCount)
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return pcm
    }

    /// `process(audioBuffer:)` resamples internally, so ASR gets the original
    /// source-format buffer directly — no need to share the diarization resample step.
    /// Yielded from `queue` (serial) so the stream preserves audio-arrival order.
    private func feedAsr(_ pcm: AVAudioPCMBuffer, into leg: AsrLeg) {
        guard leg.ready else { return }
        leg.input.yield(
            AsrChunk(
                pcm: pcm,
                seconds: Double(pcm.frameLength) / leg.sampleRate,
                isSilent: Self.rms(pcm) < leg.silenceRMS,
                capturedAt: ProcessInfo.processInfo.systemUptime))
    }

    /// Interleaved float buffers keep every channel in `floatChannelData[0]`; a
    /// non-float source format (never seen from the tap) counts as speech, which only
    /// means lines close on `maxUtteranceSeconds` instead of on pauses.
    private static func rms(_ pcm: AVAudioPCMBuffer) -> Float {
        guard let data = pcm.floatChannelData else { return 1 }
        let channels = Int(pcm.format.channelCount)
        let planes = pcm.format.isInterleaved ? 1 : channels
        let samplesPerPlane = Int(pcm.frameLength) * (pcm.format.isInterleaved ? channels : 1)
        guard samplesPerPlane > 0 else { return 0 }
        var sum: Float = 0
        for plane in 0..<planes {
            for index in 0..<samplesPerPlane {
                let sample = data[plane][index]
                sum += sample * sample
            }
        }
        return (sum / Float(samplesPerPlane * planes)).squareRoot()
    }

    private func processDiarization(_ pcm: AVAudioPCMBuffer) {
        guard modelsReady else { return }
        guard let resampled = resample(pcm) else { return }

        pendingSamples.append(contentsOf: resampled)
        let windowSampleCount = Int(Self.windowSeconds * Self.targetSampleRate)
        guard pendingSamples.count >= windowSampleCount else { return }

        let window = pendingSamples
        let offset = windowStartOffset
        pendingSamples.removeAll(keepingCapacity: true)
        windowStartOffset += Double(window.count) / Self.targetSampleRate

        do {
            let result = try manager.performCompleteDiarization(window, sampleRate: Int(Self.targetSampleRate), atTime: offset)
            segments.append(
                contentsOf: result.segments.map {
                    LiveSpeakerSegment(
                        speakerId: $0.speakerId,
                        startSeconds: Double($0.startTimeSeconds),
                        endSeconds: Double($0.endTimeSeconds),
                        qualityScore: $0.qualityScore)
                })
            writeLiveState()
        } catch {
            NSLog("LiveMeetingPipeline: diarization pass failed: \(error)")
        }
    }

    private func resample(_ pcm: AVAudioPCMBuffer) -> [Float]? {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

        var conversionError: NSError?
        var consumed = false
        // `.noDataNow`, not `.endOfStream`: the converter is reused for every IOProc
        // buffer, and signalling end-of-stream leaves it permanently drained so every
        // later call returns zero frames (live diarization then never fills a window).
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        guard conversionError == nil, let channelData = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }

    private struct LiveState: Codable {
        let segments: [LiveSpeakerSegment]
        let transcript: [LiveTranscriptEntry]
        let systemAudioSilent: Bool
    }

    private func writeLiveState() {
        let url = sessionFolder.appendingPathComponent("live_state.json")
        do {
            let data = try JSONEncoder().encode(LiveState(segments: segments, transcript: transcript, systemAudioSilent: systemAudioSilent))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("LiveMeetingPipeline: failed to write live_state.json: \(error)")
        }
    }

    /// Ends the ASR stream; the drain task then flushes the trailing audio into a final
    /// transcript chunk. Best-effort and asynchronous — recording finalization does not
    /// wait on this, since `live_state.json` is a supplementary artifact.
    func finalize() {
        queue.async { [self] in
            finalized = true
            diarizedAsr.input.finish()
            microphoneAsr?.input.finish()
        }
    }
}
