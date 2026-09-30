#if DEBUG
import AppKit
import SwiftUI

/// Renders every main surface to PNG with sample data, then quits. Run with
/// MEETING_PILOT_SNAPSHOT_DIR=<out> MEETING_PILOT_CONFIG_DIR=<scratch> so the
/// real user configuration is never read or repaired.
@MainActor
enum DebugSnapshots {
    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["MEETING_PILOT_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func render(model: AppModel, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["MEETING_PILOT_SNAPSHOT_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        let empty = ProcessInfo.processInfo.environment["MEETING_PILOT_SNAPSHOT_EMPTY"] == "1"
        if !empty { populate(model) }
        if let lang = ProcessInfo.processInfo.environment["MEETING_PILOT_SNAPSHOT_LANG"], !lang.isEmpty { model.appLanguage = lang }

        let sections: [AppSection] = [.dashboard, .chat, .journal, .publicationTargets, .recorder, .settings]
        for theme in MeetingPilotTheme.allCases {
            model.appTheme = theme
            let suffix = theme.rawValue
            for section in sections {
                let name = "window-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))-\(suffix)"
                guard only == nil || name.contains(only!) else { continue }
                model.selectedSection = section
                capture(RootView().environmentObject(model), size: NSSize(width: 1080, height: Double(ProcessInfo.processInfo.environment["MEETING_PILOT_SNAPSHOT_HEIGHT"] ?? "") ?? 740), theme: theme, name: name, in: directory)
            }
            if only == nil || "menubar".contains(only!) || only!.contains("menubar") {
                capture(
                    MenuBarOverview(openApp: {}, openDiary: {}).environmentObject(model),
                    size: NSSize(width: 320, height: 330), theme: theme, name: "menubar-\(suffix)", in: directory
                )
            }
            if only == nil || only!.contains("diary") {
                capture(DiaryNotebookView().environmentObject(model), size: NSSize(width: 820, height: 680), theme: theme, name: "diary-\(suffix)", in: directory)
            }
        }
        if only == nil || only!.contains("prompt") {
            capture(
                RecordingPromptView(meetingTitle: "Weekly product sync", timeoutSeconds: 20, onClose: {}, onRecord: {}),
                size: NSSize(width: 440, height: 82), theme: .dark, name: "recording-prompt", in: directory
            )
        }
        if only == nil || only!.contains("live") {
            let store = LiveSidebarStore()
            store.state = LiveSidebarState(
                segments: [
                    LiveSidebarSegment(speakerId: "S1", startSeconds: 0, endSeconds: 42, qualityScore: 0.9),
                    LiveSidebarSegment(speakerId: "S2", startSeconds: 42, endSeconds: 71, qualityScore: 0.8),
                ],
                transcript: [
                    LiveSidebarTranscriptEntry(text: "Partiamo dalla roadmap del Q4, poi passiamo ai rilasci.", kind: "final", atSeconds: 4),
                    LiveSidebarTranscriptEntry(text: "Il blocco principale è la documentazione.", kind: "partial", atSeconds: 48),
                ]
            )
            capture(LiveSidebarView(store: store, onClose: {}), size: NSSize(width: 340, height: 560), theme: .dark, name: "live-sidebar", in: directory)
        }
    }

    private static func populate(_ model: AppModel) {
        let now = Date()
        model.watcher.watcherActive = true
        model.todayProcessed = 3
        model.queueCount = 1
        model.pipelineStage = 2
        model.recentMeetings = [
            MeetingItem(id: "1", title: "Weekly product sync", subtitle: "Roadmap Q4 e priorità rilascio", dateText: "Oggi, 10:30", date: now.addingTimeInterval(-3600),
                        publicationTargets: [MeetingPublicationTarget(service: .journal, actionURL: nil), MeetingPublicationTarget(service: .notion, actionURL: nil)],
                        project: "Meeting Pilot", theme: "Roadmap", themes: ["Roadmap", "Release"]),
            MeetingItem(id: "2", title: "Design review — onboarding", subtitle: "Tour in-app e dati di esempio", dateText: "Oggi, 09:00", date: now.addingTimeInterval(-7200),
                        publicationTargets: [MeetingPublicationTarget(service: .obsidian, actionURL: nil)],
                        project: "Onboarding", theme: "Design", themes: ["Design"]),
            MeetingItem(id: "3", title: "Client call — Northwind", subtitle: "Pricing e tempistiche di implementazione", dateText: "Ieri, 16:00", date: now.addingTimeInterval(-86400),
                        publicationTargets: [MeetingPublicationTarget(service: .appleNotes, actionURL: nil)],
                        project: "Sales", theme: nil, themes: []),
        ]
        model.processingSessions = [
            ProcessingSession(id: "p1", title: "Standup team piattaforma", date: now, stage: .summarization, updatedAt: now, failureMessage: nil, canRetry: false),
        ]
    }

    private static func capture<V: View>(_ view: V, size: NSSize, theme: MeetingPilotTheme, name: String, in directory: URL) {
        let appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.preferredColorScheme(theme == .light ? .light : .dark))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
#endif
