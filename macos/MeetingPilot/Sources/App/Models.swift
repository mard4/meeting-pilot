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


/// Languages for the UI and the meeting notes. Each one needs a Resources/<code>.lproj
/// table and must be a language hint of the live Nemotron model (its Latin-script
/// variant), so a choice here also drives live transcription.
enum AppLanguage: String, CaseIterable, Identifiable {
    case it
    case en
    case es
    case fr
    case de
    case pt
    case nl

    var id: String { rawValue }

    /// Shown in its own language, so the picker stays readable whatever the UI language.
    var nativeName: String {
        switch self {
        case .it: return "Italiano"
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .pt: return "Português"
        case .nl: return "Nederlands"
        }
    }

    var asrLanguageCode: String {
        switch self {
        case .it: return "it-IT"
        case .en: return "en-US"
        case .es: return "es-ES"
        case .fr: return "fr-FR"
        case .de: return "de-DE"
        case .pt: return "pt-BR"
        case .nl: return "nl-NL"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .it: return "it_IT"
        case .en: return "en_US"
        case .es: return "es_ES"
        case .fr: return "fr_FR"
        case .de: return "de_DE"
        case .pt: return "pt_BR"
        case .nl: return "nl_NL"
        }
    }

    /// The relaunch happens before the new localization loads, so this is per language.
    var updatedMessage: String {
        switch self {
        case .it: return "Lingua aggiornata"
        case .en: return "Language updated"
        case .es: return "Idioma actualizado"
        case .fr: return "Langue mise à jour"
        case .de: return "Sprache aktualisiert"
        case .pt: return "Idioma atualizado"
        case .nl: return "Taal bijgewerkt"
        }
    }

    /// Accepts "fr", "fr-FR", "fr_CA" style codes.
    init?(code: String?) {
        guard let code, let language = Self(rawValue: String(code.prefix(2)).lowercased()) else { return nil }
        self = language
    }

    /// The saved choice, else the first supported macOS language, else English.
    static var current: AppLanguage {
        if let saved = AppLanguage(code: UserDefaults.standard.string(forKey: "MeetingPilotAppLanguage")) {
            return saved
        }
        return Locale.preferredLanguages.lazy.compactMap { AppLanguage(code: $0) }.first ?? .en
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case history = "Cronologia"
    case recorder = "Pipeline"
    case provider = "Provider"
    case chat = "Chat"
    case publicationTargets = "Connettori"
    case journal = "Diario"
    case notion = "Notion"
    case obsidian = "Obsidian"
    case appleNotes = "Apple Notes"
    case teams = "Teams"
    case settings = "Impostazioni"

    var id: String { rawValue }
}

struct MeetingItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let dateText: String
    let date: Date?
    let publicationTargets: [MeetingPublicationTarget]
    let project: String?
    let theme: String?
    let themes: [String]
}

enum MeetingPublicationService: String {
    case journal
    case notion
    case obsidian
    case appleNotes

    var assetName: String? {
        switch self {
        case .journal:
            return nil
        case .notion:
            return "Notion_app_logo.png"
        case .obsidian:
            return "2023_Obsidian_logo.svg"
        case .appleNotes:
            return nil
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .journal:
            return "book.pages"
        case .notion:
            return "doc.text"
        case .obsidian:
            return "book.closed.fill"
        case .appleNotes:
            return "note.text"
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .journal:
            return 16
        case .notion:
            return 15
        case .obsidian, .appleNotes:
            return 16
        }
    }

    var needsLightBackground: Bool {
        self == .notion
    }
}

struct MeetingPublicationTarget: Identifiable {
    let service: MeetingPublicationService
    let actionURL: URL?

    var id: String {
        "\(service.rawValue)::\(actionURL?.absoluteString ?? "none")"
    }
}

struct MeetingChatResponse: Decodable {
    let answer: String
    let citations: [MeetingChatCitationPayload]
}

struct MeetingChatFilterValuesPayload: Decodable {
    let projects: [String]
    let themes: [String]
}

struct MeetingChatCitationPayload: Decodable, Identifiable {
    let title: String
    let date: String?
    let destination: String
    let url: String

    var id: String { "\(title)::\(url)" }
}

struct PipelineStep: Identifiable {
    let id = UUID()
    let title: String
    let state: StepState
    let count: Int

    init(title: String, state: StepState, count: Int = 0) {
        self.title = title
        self.state = state
        self.count = count
    }
}

struct PipelineStageCounts {
    let detection: Int
    let recording: Int
    let transcription: Int
    let summarization: Int
    let publishing: Int

    init(detection: Int = 0, recording: Int = 0, transcription: Int = 0, summarization: Int = 0, publishing: Int = 0) {
        self.detection = detection
        self.recording = recording
        self.transcription = transcription
        self.summarization = summarization
        self.publishing = publishing
    }
}

enum ProcessingStage: Int, Comparable {
    case transcription
    case summarization
    case publishing
    case failed

    static func < (lhs: ProcessingStage, rhs: ProcessingStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .transcription: return "Trascrizione"
        case .summarization: return "Sintesi"
        case .publishing: return "Pubblicazione"
        case .failed: return "Richiede attenzione"
        }
    }

    var symbol: String {
        switch self {
        case .transcription: return "waveform"
        case .summarization: return "sparkles"
        case .publishing: return "arrow.up.doc"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

struct ProcessingSession: Identifiable {
    let id: String
    let title: String
    let date: Date?
    let stage: ProcessingStage
    let updatedAt: Date
    let failureMessage: String?
    let canRetry: Bool
}

struct TranscriptionIssue {
    let code: String
    let message: String
    let retryable: Bool
}

struct PermissionRow: Identifiable {
    let id: String
    let title: String
    let granted: Bool
    let settingsURL: String
    let reason: String
}

struct RefreshInput {
    let inbox: URL
    let processedSources: URL
    let root: URL
    let runtime: URL
    let stableSeconds: Int
    let recorderMode: String
    let transcriptionProvider: String
    let nativeRecordingActive: Bool
    let externalRecordingActive: Bool
    let externalRecordingStartedAt: Date?
}

struct RuntimeMetadataSnapshot {
    let status: String
    let title: String
    let participants: String
}

struct RefreshSnapshot {
    let watcherActive: Bool
    let queueCount: Int
    let externalRecordingFinished: Bool
    let retryableFailedSession: String
    let retryableTranscriptionSession: String
    let pipelineStage: Int
    let pipelineCounts: PipelineStageCounts
    let processingSessions: [ProcessingSession]
    let todayProcessed: Int
    let recentMeetings: [MeetingItem]
    let logTail: String
    let permissionRows: [PermissionRow]
    let accessibilityGranted: Bool
    let runtime: RuntimeMetadataSnapshot
}

enum StepState {
    case done
    case active
    case pending
}

/// Who uses the app (USER_PROFILE). A worker's recordings become meeting notes, a
/// student's become study notes, and someone who is both gets either, decided per
/// recording (see `profiles.py`).
enum UserProfile: String {
    case worker
    case student
    case both

    init(student: Bool, worker: Bool) {
        switch (student, worker) {
        case (true, true): self = .both
        case (true, false): self = .student
        default: self = .worker
        }
    }

    var isStudent: Bool { self != .worker }
    var isWorker: Bool { self != .student }
}

/// A section of the published note, saved as `INCLUDE_<rawValue>` in .env and read by
/// every publisher. Meetings and lectures share the first group; the other two only
/// appear in their own kind of note.
enum PageSection: String, CaseIterable, Identifiable {
    case overview = "OVERVIEW"
    case summary = "SUMMARY"
    case topics = "TOPICS"
    case speakers = "SPEAKERS"
    case transcript = "TRANSCRIPT"
    case decisions = "DECISIONS"
    case actionItems = "ACTION_ITEMS"
    case openQuestions = "OPEN_QUESTIONS"
    case risks = "RISKS"
    case keyConcepts = "KEY_CONCEPTS"
    case assignments = "ASSIGNMENTS"
    case examHints = "EXAM_HINTS"
    case reviewQuestions = "REVIEW_QUESTIONS"
    case references = "REFERENCES"

    static let shared: [PageSection] = [.overview, .summary, .topics, .speakers, .transcript]
    static let meeting: [PageSection] = [.decisions, .actionItems, .openQuestions, .risks]
    static let lecture: [PageSection] = [.keyConcepts, .assignments, .examHints, .reviewQuestions, .references]

    var id: String { rawValue }
    var envKey: String { "INCLUDE_\(rawValue)" }
    /// Sections older than profiles were first saved for Notion only.
    var legacyEnvKey: String? { PageSection.lecture.contains(self) ? nil : "NOTION_INCLUDE_\(rawValue)" }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .summary: return "Sintesi"
        case .topics: return "Topic"
        case .speakers: return "Speaker rilevati"
        case .transcript: return "Transcript completo"
        case .decisions: return "Decisioni"
        case .actionItems: return "Action item"
        case .openQuestions: return "Domande aperte"
        case .risks: return "Rischi"
        case .keyConcepts: return "Concetti chiave"
        case .assignments: return "Compiti e scadenze"
        case .examHints: return "Per l'esame"
        case .reviewQuestions: return "Domande di ripasso"
        case .references: return "Riferimenti"
        }
    }
}
