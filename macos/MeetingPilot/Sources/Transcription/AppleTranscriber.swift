import Foundation
import Speech
import AVFoundation
import CoreMedia

private final class AsyncResultBox<Value>: @unchecked Sendable {
    var value: Result<Value, Error>?
}

/// Same shape as FluidAudio's `wordTimings`, so the pipeline can match words to its speaker turns.
struct TimedWord: Encodable, Sendable {
    let word: String
    let startTime: Double
    let endTime: Double
}

enum AppleTranscriberError: LocalizedError {
    case usage
    case recognizerUnavailable
    case onDeviceUnavailable
    case localeUnavailable
    case notAuthorized
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: AppleTranscriber <input-audio> <output-txt> [locale]"
        case .recognizerUnavailable:
            return "Speech recognizer unavailable for the selected locale."
        case .onDeviceUnavailable:
            return "Apple On-Device transcription is unavailable for the selected locale."
        case .localeUnavailable:
            return "Apple transcription is unavailable for the selected locale."
        case .notAuthorized:
            return "Speech recognition authorization was not granted."
        case .failed(let message):
            return message
        }
    }
}

@main
struct AppleTranscriber {
    static func main() {
        do {
            try run()
        } catch {
            fputs((error.localizedDescription + "\n"), stderr)
            exit(1)
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count >= 3 else {
            throw AppleTranscriberError.usage
        }

        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let localeID = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "it-IT"
        // Each glossary line is "term, misheard variant, …": only the term is a spelling to favour.
        let glossaryTerms = CommandLine.arguments.count >= 5
            ? ((try? String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { $0.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } }
                .filter { !$0.isEmpty }
            : []

        let transcript: String
        var words: [TimedWord] = []
        if #available(macOS 26.0, *) {
            (transcript, words) = try waitForResult {
                try await recognizeWithSpeechAnalyzer(input, localeID: localeID)
            }
        } else {
            transcript = try recognizeWithLegacySpeech(input, localeID: localeID, glossaryTerms: glossaryTerms)
        }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppleTranscriberError.failed("Apple transcription returned an empty transcript.")
        }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript.write(to: output, atomically: true, encoding: .utf8)
        if !words.isEmpty {
            // "<output>.words.json", next to the transcript.
            let wordsURL = output.deletingPathExtension().appendingPathExtension("words.json")
            try JSONEncoder().encode(["wordTimings": words]).write(to: wordsURL, options: .atomic)
        }
        print(output.path)
    }

    @available(macOS 26.0, *)
    private static func recognizeWithSpeechAnalyzer(_ input: URL, localeID: String) async throws -> (String, [TimedWord]) {
        guard SpeechTranscriber.isAvailable else {
            throw AppleTranscriberError.onDeviceUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw AppleTranscriberError.localeUnavailable
        }

        // The `.transcription` preset plus each run's audio time range, which places words in speaker turns.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            fputs("Downloading Apple speech assets for \(locale.identifier)…\n", stderr)
            try await request.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: input)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )
        var transcript = ""
        var words: [TimedWord] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                transcript = mergeTranscript(transcript, with: text)
            }
            // Results come in audio order; one starting before the last word is a repeat.
            let resultWords = timedWords(in: result.text)
            if let first = resultWords.first, let last = words.last, first.startTime < last.startTime {
                continue
            }
            words += resultWords
        }
        _ = analyzer
        return (transcript, words)
    }

    /// A run can hold several words under one time range; their time is split evenly.
    @available(macOS 26.0, *)
    private static func timedWords(in text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange, range.start.isNumeric, range.duration.isNumeric else { continue }
            let tokens = String(text[run.range].characters).split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty else { continue }
            let start = range.start.seconds
            let step = range.duration.seconds / Double(tokens.count)
            for (index, token) in tokens.enumerated() {
                words.append(TimedWord(
                    word: String(token),
                    startTime: start + step * Double(index),
                    endTime: start + step * Double(index + 1)
                ))
            }
        }
        return words
    }

    @available(macOS 26.0, *)
    private static func mergeTranscript(_ existing: String, with next: String) -> String {
        guard !existing.isEmpty else { return next }
        guard !next.isEmpty else { return existing }
        if existing.contains(next) { return existing }
        if next.contains(existing) { return next }

        let existingWords = existing.split(whereSeparator: \.isWhitespace)
        let nextWords = next.split(whereSeparator: \.isWhitespace)
        let overlapLimit = min(existingWords.count, nextWords.count)
        for count in stride(from: overlapLimit, through: 1, by: -1) {
            if existingWords.suffix(count).elementsEqual(nextWords.prefix(count)) {
                return existing + " " + nextWords.dropFirst(count).joined(separator: " ")
            }
        }
        return existing + " " + next
    }

    private static func recognizeWithLegacySpeech(
        _ input: URL,
        localeID: String,
        glossaryTerms: [String]
    ) throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleTranscriberError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            throw AppleTranscriberError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleTranscriberError.onDeviceUnavailable
        }

        var transcript = try recognize(input, with: recognizer, requiresOnDevice: true, glossaryTerms: glossaryTerms)
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = try recognize(input, with: recognizer, requiresOnDevice: false, glossaryTerms: glossaryTerms)
        }
        return transcript
    }

    private static func waitForResult<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AsyncResultBox<T>()
        Task {
            do {
                box.value = .success(try await operation())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let value = box.value else {
            throw AppleTranscriberError.failed("Apple transcription did not return a result.")
        }
        return try value.get()
    }

    private static func recognize(
        _ input: URL,
        with recognizer: SFSpeechRecognizer,
        requiresOnDevice: Bool,
        glossaryTerms: [String]
    ) throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: input)
        request.requiresOnDeviceRecognition = requiresOnDevice
        request.contextualStrings = glossaryTerms
        request.shouldReportPartialResults = false

        var transcript = ""
        var recognitionError: Error?
        var recognitionCompleted = false
        let task = recognizer.recognitionTask(with: request) { result, error in
            // Speech can deliver this callback on the main queue, so keep the
            // run loop alive instead of waiting on a semaphore.
            DispatchQueue.main.async {
                if let result {
                    transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        recognitionCompleted = true
                    }
                }
                if let error {
                    recognitionError = error
                    recognitionCompleted = true
                }
            }
        }

        let recognitionDeadline = Date().addingTimeInterval(900)
        while !recognitionCompleted && Date() < recognitionDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        task.cancel()
        guard recognitionCompleted else {
            throw AppleTranscriberError.failed("Apple transcription timed out.")
        }
        if let recognitionError {
            throw AppleTranscriberError.failed(recognitionError.localizedDescription)
        }
        return transcript
    }
}
