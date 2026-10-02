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

        let sections: [AppSection] = [.dashboard, .history, .chat, .journal, .publicationTargets, .notion, .obsidian, .recorder, .provider, .settings]
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
                    MenuBarOverview(openApp: {}, openChat: {}, openDiary: {}).environmentObject(model),
                    size: NSSize(width: 320, height: 330), theme: theme, name: "menubar-\(suffix)", in: directory
                )
            }
            if only == nil || only!.contains("diary") {
                capture(DiaryNotebookView().environmentObject(model), size: NSSize(width: 820, height: 680), theme: theme, name: "diary-\(suffix)", in: directory)
            }
        }
        if only == nil || only!.contains("prompt") {
            capture(
                RecordingPromptView(meetingTitle: "Q4 Product Roadmap Sync", timeoutSeconds: 20, onClose: {}, onRecord: {}),
                size: NSSize(width: 440, height: 82), theme: .dark, name: "recording-prompt", in: directory
            )
        }
        if only == nil || only!.contains("live") {
            let store = LiveSidebarStore()
            store.state = LiveSidebarState(
                segments: [
                    LiveSidebarSegment(speakerId: "S1", startSeconds: 0, endSeconds: 42, qualityScore: 0.9),
                    LiveSidebarSegment(speakerId: "S2", startSeconds: 42, endSeconds: 71, qualityScore: 0.8),
                    LiveSidebarSegment(speakerId: "S3", startSeconds: 71, endSeconds: 118, qualityScore: 0.85),
                    LiveSidebarSegment(speakerId: "S1", startSeconds: 118, endSeconds: 160, qualityScore: 0.9),
                ],
                transcript: [
                    LiveSidebarTranscriptEntry(text: "Goal today: leave this call with a Q4 roadmap we actually believe in.", kind: "final", atSeconds: 4, speaker: "me", name: nil),
                    LiveSidebarTranscriptEntry(text: "Churn interviews were clear: eleven of eighteen accounts lost work offline.", kind: "final", atSeconds: 48, speaker: "them", name: "Giulia Bianchi"),
                    LiveSidebarTranscriptEntry(text: "That matches support tickets. Sync errors are up twenty percent since August.", kind: "final", atSeconds: 77, speaker: "them", name: "Marco Rossi"),
                    LiveSidebarTranscriptEntry(text: "So offline mode moves ahead of the Salesforce connector.", kind: "final", atSeconds: 121, speaker: "me", name: nil),
                    LiveSidebarTranscriptEntry(text: "I can live with that if we tell Northwind early", kind: "partial", atSeconds: 150, speaker: "them", name: "Giulia Bianchi"),
                ]
            )
            store.notes = "- Offline mode → priority #1\n- Salesforce connector slips to Q1\n- Call Northwind this week"
            capture(LiveSidebarView(store: store, onClose: {}), size: NSSize(width: 340, height: 560), theme: .dark, name: "live-sidebar", in: directory)
        }
    }

    private static func populate(_ model: AppModel) {
        let now = Date()
        if let diary = ProcessInfo.processInfo.environment["MEETING_PILOT_SNAPSHOT_DIARY"], !diary.isEmpty { model.journalRoot = diary }
        model.watcher.watcherActive = true
        model.accessibilityGranted = true
        model.publicationTargets = ["journal", "notion", "obsidian"]
        model.obsidianVaultPath = NSString(string: "~/Meeting Pilot Demo Vault").expandingTildeInPath
        model.notion.token = "demo"
        model.notion.occurrencesDatabaseId = "demo"
        model.notion.pageName = "Atlas Team"
        model.todayProcessed = 2
        model.queueCount = 1
        model.pipelineStage = 2
        let all: [MeetingPublicationTarget] = [.init(service: .journal, actionURL: nil), .init(service: .notion, actionURL: nil), .init(service: .obsidian, actionURL: nil)]
        func item(_ id: String, _ title: String, _ subtitle: String, _ dateText: String, _ hoursAgo: Double, _ project: String, _ theme: String) -> MeetingItem {
            MeetingItem(id: id, title: title, subtitle: subtitle, dateText: dateText, date: now.addingTimeInterval(-hoursAgo * 3600),
                        publicationTargets: all, project: project, theme: theme, themes: [theme])
        }
        model.recentMeetings = [
            item("1", "Design Review — Onboarding Flow", "3-step onboarding with a sample workspace", "Today, 14:30", 1, "Atlas App", "Design"),
            item("2", "Q4 Product Roadmap Sync", "Offline mode first, Salesforce connector to Q1", "Today, 10:00", 5, "Atlas App", "Roadmap"),
            item("3", "Client Call — Northwind Traders", "Expansion to 300 seats, Okta SSO, EU residency", "Yesterday, 16:00", 22, "Northwind", "Sales"),
            item("4", "Weekly Engineering Standup", "4.1.3 hotfix shipped, CI down to 11 minutes", "Yesterday, 09:30", 29, "Platform", "Engineering"),
            item("5", "Hiring Debrief — Senior iOS Engineer", "Offer pending one reference call", "Mon, 17:00", 45, "People", "Hiring"),
            item("6", "Launch Plan — Atlas 4.2", "December 3 launch, \"Your work, even without Wi-Fi\"", "Fri, 11:00", 120, "Atlas App", "Launch"),
            item("7", "Q4 Budget Review", "$60k reallocated to launch and infrastructure", "Thu, 15:00", 144, "Finance", "Budget"),
        ]
        model.processingSessions = [
            ProcessingSession(id: "p1", title: "Customer Advisory Board — prep", date: now, stage: .summarization, updatedAt: now, failureMessage: nil, canRetry: false),
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
