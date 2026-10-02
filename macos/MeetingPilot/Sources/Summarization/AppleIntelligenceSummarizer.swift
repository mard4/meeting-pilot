import Foundation
import FoundationModels
import NaturalLanguage
import Translation

enum AppleIntelligenceSummarizerError: LocalizedError {
    case usage
    case invalidInput(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: AppleIntelligenceSummarizer --availability | <input-json> <output-json>"
        case .invalidInput(let detail):
            return "Invalid summarizer input: \(detail)"
        case .unavailable(let detail):
            return "Apple Intelligence unavailable: \(detail)"
        }
    }
}

struct SummarizerInput: Decodable {
    let transcript: String
    let existingSummary: String?
    let frontmatter: [String: JSONValue]?
    let calendarMetadata: [String: JSONValue]?
    let knownProjects: [String]?
    let locale: String?
    let customPrompt: String?
    let outputLanguage: String?
}

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

@main
struct AppleIntelligenceSummarizer {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--availability"] {
                printAvailability()
                return
            }
            guard arguments.count == 2 else {
                throw AppleIntelligenceSummarizerError.usage
            }
            guard #available(macOS 26.0, *) else {
                throw AppleIntelligenceSummarizerError.unavailable("requires macOS 26 or later")
            }
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                throw AppleIntelligenceSummarizerError.unavailable(availabilityReason(model.availability))
            }
            let inputURL = URL(fileURLWithPath: arguments[0])
            let outputURL = URL(fileURLWithPath: arguments[1])
            let input = try JSONDecoder().decode(SummarizerInput.self, from: Data(contentsOf: inputURL))
            guard !input.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(input.existingSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppleIntelligenceSummarizerError.invalidInput("transcript and existing summary are empty")
            }
            let transcript = try await transcriptInSupportedLanguage(input, model: model)
            let notes = try await summarize(input, transcript: transcript, model: model)
            let object = try JSONSerialization.jsonObject(with: Data(notes.utf8))
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: outputURL, options: .atomic)
        } catch {
            let detail = error.localizedDescription
            let message = detail.localizedCaseInsensitiveContains("unsupported language")
                ? "Apple Intelligence unavailable: the transcript language is not supported"
                : detail
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            Foundation.exit(2)
        }
    }

    static func printAvailability() {
        let status: [String: String]
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if model.availability != .available {
                status = ["status": "unavailable", "reason": availabilityReason(model.availability)]
            } else {
                status = ["status": "available", "reason": ""]
            }
        } else {
            status = ["status": "unavailable", "reason": "requires macOS 26 or later"]
        }
        let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        print(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"status\":\"unavailable\"}")
    }

    @available(macOS 26.0, *)
    static func availabilityReason(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return ""
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled in System Settings"
        case .unavailable(.modelNotReady):
            return "the on-device model is not ready or is still downloading"
        case .unavailable(.deviceNotEligible):
            return "this Mac does not support Apple Intelligence"
        case .unavailable:
            return "the on-device model is currently unavailable"
        }
    }

    @available(macOS 26.0, *)
    static func summarize(_ input: SummarizerInput, transcript: PreparedTranscript, model: SystemLanguageModel) async throws -> String {
        let chunks = splitText(transcript.text, maximumCharacters: 6_000)
        var partialNotes: [String] = []
        let chunkSchema = try makeChunkSchema()
        let localeInstruction = transcript.translatedFrom.map {
            "The transcript was machine-translated to \(transcript.languageName) from \($0); names may be transliterated."
        } ?? "The transcript is in \(transcript.languageName)."
        let customInstruction = (input.customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let customInstructionText = customInstruction.isEmpty ? "" : "\nAdditional user instructions:\n\(customInstruction)"
        let language = input.outputLanguage ?? "Italian"
        let languageInstruction = "Write every field in \(language), translating from the transcript language when it differs; keep names of people, products and proper nouns as spoken."
        for (index, chunk) in chunks.enumerated() {
            let session = LanguageModelSession(model: model, instructions: """
                \(localeInstruction)
                Extract faithful operational notes from a meeting transcript. Never invent names, dates, decisions, owners, deadlines, questions, or risks. Keep the result concise. \(languageInstruction)
                \(customInstructionText)
                """)
            let response = try await session.respond(
                to: """
                Transcript part \(index + 1) of \(chunks.count):
                \(chunk)
                """,
                schema: chunkSchema
            )
            partialNotes.append(response.content.jsonString)
        }

        let condensed = try await condenseIfNeeded(partialNotes, model: model)
        let context = try metadataContext(input)
        let encodedPartials = "[" + condensed.joined(separator: ",") + "]"
        let finalSession = LanguageModelSession(model: model, instructions: """
            \(localeInstruction)
            Create structured meeting notes using only the supplied extracts and metadata. Never invent information. Create a concise descriptive title of 3-8 words for the meeting subject; never include platform names, attendee names, email addresses, dates, times, or technical recording filenames. Choose the project tag by analysing the conversation and comparing it with known_projects: reuse a known project only when it is clearly relevant; otherwise propose a concise new project tag. Participants may only come from calendar_metadata and the participant names identified from Teams; generic labels such as Speaker 1 or SPEAKER_00 are not names. Use nil when a date, owner, or deadline is unknown. Every action item status must be exactly "open". Provide one concise reusable tag and one concise theme of 2-5 words when the meeting has a clear subject. \(languageInstruction)
            \(customInstructionText)
            """)
        let response = try await finalSession.respond(
            to: """
            Metadata:
            \(context)

            Existing summary, if any:
            \(input.existingSummary ?? "")

            Faithful transcript extracts:
            \(encodedPartials)
            """,
            schema: try makeMeetingSchema()
        )
        return response.content.jsonString
    }

    @available(macOS 26.0, *)
    static func condenseIfNeeded(_ notes: [String], model: SystemLanguageModel) async throws -> [String] {
        guard notes.count > 8 else { return notes }
        var result: [String] = []
        let schema = try makeChunkSchema()
        for start in stride(from: 0, to: notes.count, by: 6) {
            let end = min(start + 6, notes.count)
            let batch = Array(notes[start..<end])
            let session = LanguageModelSession(model: model, instructions: """
                Merge meeting-note extracts without adding facts. Preserve decisions, action items, open questions, risks, and meaningful topics. Remove only duplication and keep the result concise.
                """)
            let response = try await session.respond(
                to: "[" + batch.joined(separator: ",") + "]",
                schema: schema
            )
            result.append(response.content.jsonString)
        }
        return try await condenseIfNeeded(result, model: model)
    }

    @available(macOS 26.0, *)
    static func makeChunkSchema() throws -> GenerationSchema {
        let string = DynamicGenerationSchema(type: String.self)
        let strings = DynamicGenerationSchema(arrayOf: string)
        let root = DynamicGenerationSchema(
            name: "ChunkNotes",
            description: "Faithful concise notes extracted from one or more transcript parts",
            properties: [
                .init(name: "summary", description: "Concise factual summary", schema: string),
                .init(name: "topics", schema: strings),
                .init(name: "decisions", schema: strings),
                .init(name: "action_items", schema: strings),
                .init(name: "open_questions", schema: strings),
                .init(name: "risks", schema: strings),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    @available(macOS 26.0, *)
    static func makeMeetingSchema() throws -> GenerationSchema {
        let string = DynamicGenerationSchema(type: String.self)
        let strings = DynamicGenerationSchema(arrayOf: string)
        let decision = DynamicGenerationSchema(
            name: "MeetingDecision",
            properties: [
                .init(name: "text", schema: string),
                .init(name: "owner", schema: string, isOptional: true),
            ]
        )
        let action = DynamicGenerationSchema(
            name: "MeetingActionItem",
            properties: [
                .init(name: "owner", schema: string, isOptional: true),
                .init(name: "task", schema: string),
                .init(name: "due_date", schema: string, isOptional: true),
                .init(name: "status", description: "Always the exact string open", schema: string),
            ]
        )
        let decisions = DynamicGenerationSchema(arrayOf: .init(referenceTo: "MeetingDecision"))
        let actions = DynamicGenerationSchema(arrayOf: .init(referenceTo: "MeetingActionItem"))
        let root = DynamicGenerationSchema(
            name: "StructuredMeetingNotes",
            properties: [
                .init(name: "title", schema: string),
                .init(name: "tag", description: "Concise reusable meeting label without #", schema: string, isOptional: true),
                .init(name: "theme", description: "Concise meeting theme of 2-5 words", schema: string, isOptional: true),
                .init(name: "date", description: "ISO date/time", schema: string, isOptional: true),
                .init(name: "participants", schema: strings),
                .init(name: "summary", schema: string),
                .init(name: "topics", schema: strings),
                .init(name: "decisions", schema: decisions),
                .init(name: "action_items", schema: actions),
                .init(name: "open_questions", schema: strings),
                .init(name: "risks", schema: strings),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [decision, action])
    }

    struct PreparedTranscript {
        let text: String
        let languageName: String
        let translatedFrom: String?
    }

    /// The on-device model's language support is independent of the Mac's UI locale, so
    /// eligibility is decided on the transcript itself. Unsupported languages are routed
    /// through the on-device Translation framework rather than leaving the Mac.
    @available(macOS 26.0, *)
    static func transcriptInSupportedLanguage(_ input: SummarizerInput, model: SystemLanguageModel) async throws -> PreparedTranscript {
        let language = detectLanguage(input.transcript, fallbackLocale: input.locale)
        let name = englishName(of: language)
        let supported = model.supportedLanguages.contains { $0.languageCode == language.languageCode }
        if supported || input.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PreparedTranscript(text: input.transcript, languageName: name, translatedFrom: nil)
        }

        let pivot = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: language, to: pivot)
        guard status == .installed else {
            throw AppleIntelligenceSummarizerError.unavailable(
                "the transcript language (\(name)) is not supported by Apple Intelligence. "
                + "Download \(name) and English in System Settings › General › Language & Region › Translation Languages "
                + "to translate it on-device first"
            )
        }
        let session = TranslationSession(installedSource: language, target: pivot)
        var translated: [String] = []
        for chunk in splitText(input.transcript, maximumCharacters: 2_000) {
            translated.append(try await session.translate(chunk).targetText)
        }
        return PreparedTranscript(text: translated.joined(separator: "\n"), languageName: englishName(of: pivot), translatedFrom: name)
    }

    static func detectLanguage(_ text: String, fallbackLocale: String?) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(20_000)))
        if let dominant = recognizer.dominantLanguage, dominant != .undetermined {
            return Locale.Language(identifier: dominant.rawValue)
        }
        return Locale(identifier: fallbackLocale ?? Locale.current.identifier).language
    }

    static func englishName(of language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    static func splitText(_ text: String, maximumCharacters: Int) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for paragraph in normalized.components(separatedBy: .newlines) {
            let candidate = current.isEmpty ? paragraph : current + "\n" + paragraph
            if candidate.count <= maximumCharacters {
                current = candidate
                continue
            }
            if !current.isEmpty { chunks.append(current) }
            var remainder = paragraph
            while remainder.count > maximumCharacters {
                let end = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
                chunks.append(String(remainder[..<end]))
                remainder = String(remainder[end...])
            }
            current = remainder
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func metadataContext(_ input: SummarizerInput) throws -> String {
        try jsonString([
            "frontmatter": JSONValue.object(input.frontmatter ?? [:]),
            "calendar_metadata": JSONValue.object(input.calendarMetadata ?? [:]),
            "known_projects": JSONValue.array((input.knownProjects ?? []).map(JSONValue.string)),
        ])
    }

    static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
