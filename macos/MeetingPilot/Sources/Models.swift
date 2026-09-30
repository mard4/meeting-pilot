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
