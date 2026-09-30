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


// MARK: - Live meeting sidebar

/// Mirrors the JSON schema `LiveMeetingPipeline` writes to `live_state.json`. Deliberately
/// a separate, plain Codable type rather than reusing that class's nested types, so this
/// UI layer doesn't need to import FluidAudio at all.
struct LiveSidebarSegment: Codable, Identifiable {
    var id: String { "\(speakerId)-\(startSeconds)" }
    let speakerId: String
    let startSeconds: Double
    let endSeconds: Double
    let qualityScore: Float
}

struct LiveSidebarTranscriptEntry: Codable, Identifiable {
    var id: String { "\(speaker ?? "")-\(atSeconds)-\(kind)-\(text.prefix(16))" }
    let text: String
    let kind: String  // "partial" or "final" — see LiveMeetingPipeline.LiveTranscriptEntry
    let atSeconds: Double
    let speaker: String?  // "me" or "them"; absent in files written before the microphone leg
}

struct LiveSidebarState: Codable {
    var segments: [LiveSidebarSegment] = []
    var transcript: [LiveSidebarTranscriptEntry] = []
}

/// Polls `live_state.json` on disk rather than being wired directly to `LiveMeetingPipeline`
/// (which lives inside `SystemMeetingAudioRecorder`, not reachable from `AppModel`/SwiftUI
/// today) — keeps the live-diarization internals fully decoupled from the UI layer.
final class LiveSidebarStore: ObservableObject {
    @Published var state = LiveSidebarState()
    @Published var notes = ""
    @Published private(set) var templateChoice = SummaryTemplateCatalog.auto
    @Published private(set) var templateOptions: [SummaryTemplateOption] = []
    private var lastLoadedData: Data?
    private var audioURL: URL?
    private var notesSaveWork: DispatchWorkItem?

    /// Everything is per recording (see `MeetingSidecar`), so switching recordings starts
    /// from that recording's saved notes and template rather than the previous one's.
    func begin(audioURL: URL) {
        self.audioURL = audioURL
        lastLoadedData = nil
        state = LiveSidebarState()
        notes = (try? String(contentsOf: MeetingSidecar.notesURL(for: audioURL), encoding: .utf8)) ?? ""
        templateChoice = MeetingSidecar.readTemplateChoice(for: audioURL)
        let customURL = ConfigLocator.configDirectory().appendingPathComponent(SummaryTemplateCatalog.fileName)
        templateOptions = SummaryTemplateCatalog.options(custom: SummaryTemplateCatalog.loadCustom(from: customURL))
    }

    func notesDidChange() {
        notesSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNotes() }
        notesSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Only writes into an existing folder: after the recording ends the pipeline moves
    /// it into the session, and a late save must not recreate it in the inbox.
    func saveNotes() {
        notesSaveWork?.cancel()
        notesSaveWork = nil
        guard let audioURL,
              FileManager.default.fileExists(atPath: MeetingSidecar.directory(for: audioURL).path)
        else { return }
        let url = MeetingSidecar.notesURL(for: audioURL)
        guard !notes.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try notes.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.append("Salvataggio note non riuscito: \(error.localizedDescription)")
        }
    }

    func selectTemplate(_ id: String) {
        guard let audioURL else { return }
        templateChoice = id
        MeetingSidecar.writeTemplateChoice(id, for: audioURL)
    }

    var templateName: String {
        templateOptions.first { $0.id == templateChoice }?.name ?? localized("Automatico")
    }

    func load(from url: URL) {
        guard let data = try? Data(contentsOf: url), data != lastLoadedData else { return }
        guard let decoded = try? JSONDecoder().decode(LiveSidebarState.self, from: data) else { return }
        lastLoadedData = data
        DispatchQueue.main.async { [weak self] in
            self?.state = decoded
        }
    }
}

/// Borderless panels refuse key status by default, which would leave the notes editor
/// unable to receive typing.
private final class LiveSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class LiveSidebarWindow {
    static let shared = LiveSidebarWindow()

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private let store = LiveSidebarStore()

    /// `audioFileURL` is the recording's audio file (`RecordingController.nativeRecordingPath`);
    /// `live_state.json`, notes and the template choice live in its `MeetingSidecar` folder.
    func toggle(audioFileURL: URL?) {
        if panel != nil {
            close()
        } else {
            show(audioFileURL: audioFileURL)
        }
    }

    func show(audioFileURL: URL?) {
        close()
        guard let audioFileURL else { return }
        let liveStateURL = MeetingSidecar.liveStateURL(for: audioFileURL)
        store.begin(audioURL: audioFileURL)

        // Borderless, matching RecordingPromptWindow/PermissionCoachWindow: a native
        // .titled AppKit titlebar would stack a second, opaque chrome system above the
        // glass content below it. The SwiftUI header supplies the only title chrome, so
        // the material reads as one continuous surface rather than two seams.
        let size = NSSize(width: 340, height: 620)
        let panel = LiveSidebarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Take keyboard focus only when the notes editor is clicked, so the meeting app
        // stays frontmost the rest of the time.
        panel.becomesKeyOnlyIfNeeded = true
        // The sidebar's text is drawn for a dark surface; pin the glass to dark so it stays
        // legible when macOS itself is in light mode.
        panel.appearance = NSAppearance(named: .darkAqua)

        let view = LiveSidebarView(store: store, onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
        self.panel = panel

        store.load(from: liveStateURL)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak store] _ in
            store?.load(from: liveStateURL)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func close() {
        store.saveNotes()
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 24)
    }
}

struct LiveSidebarView: View {
    @ObservedObject var store: LiveSidebarStore
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var livePulse = false

    private static let speakerPalette: [Color] = [
        MeetingPilotDesign.accent, .orange, .pink, .purple, .teal, .yellow,
    ]

    private func speakerColor(_ speakerId: String) -> Color {
        let index = abs(speakerId.hashValue) % Self.speakerPalette.count
        return Self.speakerPalette[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if !store.state.segments.isEmpty {
                speakerStrip
                Divider().overlay(Color.white.opacity(0.08))
            }
            transcriptList
            Divider().overlay(Color.white.opacity(0.08))
            notesSection
        }
        .frame(minWidth: 280, minHeight: 420)
        // Dark base under the glass keeps white text legible over bright windows.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: 0x0A0A0C)).opacity(0.78))
        )
        // Real Liquid Glass on macOS 26+, regularMaterial fallback below that.
        .meetingPilotGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .foregroundStyle(.white)
        .onAppear { livePulse = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandTile(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(localized("Dal vivo"))
                    .font(.mpDisplay(12))
                Text(localized("Trascrizione e parlanti"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(MeetingPilotDesign.accentStrong)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 1 : (livePulse ? 1 : 0.35))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: livePulse)
                Text("REC")
                    .font(.mpEyebrow(9))
                    .tracking(1)
            }
            .foregroundStyle(MeetingPilotDesign.accentStrong)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(MeetingPilotDesign.accent.opacity(0.16)))
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MPIconButtonStyle(size: 24))
            .help("Chiudi")
        }
        .padding(12)
        // A flat tint, not a second material: the whole panel is already real glass
        // via meetingPilotGlass() above, and stacking glass-on-glass muddies both.
        .background(Color.white.opacity(0.05))
    }

    /// Speaker turns and transcript lines come from two independent live passes
    /// (diarization and streaming ASR) that aren't time-aligned yet, so they're shown as
    /// separate sections rather than merged into per-line speaker attribution.
    private var speakerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.state.segments.suffix(12)) { segment in
                    Text("\(segment.speakerId) · \(Int(segment.startSeconds))s")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(speakerColor(segment.speakerId).opacity(0.22))
                        .foregroundStyle(speakerColor(segment.speakerId))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Granola-style notes: the summary treats each line typed here as a point it must
    /// cover (see `summary_guidance` in the pipeline).
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localized("Le tue note"))
                    .font(.mpEyebrow(10))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Menu {
                    ForEach(store.templateOptions) { option in
                        Button {
                            store.selectTemplate(option.id)
                        } label: {
                            if option.id == store.templateChoice {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                } label: {
                    Label(store.templateName, systemImage: "doc.text")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(localized("Modello di sintesi per questa riunione"))
            }
            ZStack(alignment: .topLeading) {
                if store.notes.isEmpty {
                    Text(localized("Scrivi i punti importanti: la sintesi li approfondirà."))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $store.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .onChange(of: store.notes) { store.notesDidChange() }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            .frame(height: 150)
        }
        .padding(12)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.state.transcript.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 18))
                                .foregroundStyle(MeetingPilotDesign.accentStrong)
                                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                            Text(localized("In attesa di parlato..."))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(store.state.transcript) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            if let speaker = entry.speaker {
                                Text(speaker == "me" ? localized("Io") : localized("Altri"))
                                    .font(.mpEyebrow(9))
                                    .tracking(0.6)
                                    .foregroundStyle(speaker == "me" ? MeetingPilotDesign.accentStrong : .white.opacity(0.5))
                            }
                            Text(entry.text)
                                .font(.system(size: 13, weight: entry.kind == "final" ? .medium : .regular))
                                .foregroundStyle(entry.kind == "final" ? .white.opacity(0.92) : .white.opacity(0.5))
                                .italic(entry.kind != "final")
                        }
                        .id(entry.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.state.transcript.count) {
                guard let last = store.state.transcript.last else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

enum NotificationBridge {
    static let categoryIdentifier = "MEETING_PILOT_MEETING_DETECTED"
    static let recordActionIdentifier = "MEETING_PILOT_RECORD"
    static let openActionIdentifier = "MEETING_PILOT_OPEN"
    static let meetingTitleKey = "meetingTitle"

    static func configureCategories() {
        let record = UNNotificationAction(
            identifier: recordActionIdentifier,
            title: localized("Registra"),
            options: [.foreground]
        )
        let open = UNNotificationAction(
            identifier: openActionIdentifier,
            title: localized("Apri Meeting Pilot"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [record, open],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted || error != nil {
                NSLog("Meeting Pilot notifications are unavailable: %@", error?.localizedDescription ?? "not authorized")
            }
            completion?(granted && error == nil)
        }
    }

    static func showNotionPublished(title: String) {
        let content = UNMutableNotificationContent()
        content.title = localized("Call pubblicata su Notion")
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "meeting-pilot-notion-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Unable to schedule Meeting Pilot notification: %@", error.localizedDescription)
            }
        }
    }
}

struct RecordingPromptView: View {
    let meetingTitle: String
    let timeoutSeconds: TimeInterval
    let onClose: () -> Void
    let onRecord: () -> Void

    @State private var progress = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            BrandTile(size: 40)

            VStack(alignment: .leading, spacing: 3) {
                MPEyebrow("Riunione rilevata", color: MeetingPilotDesign.accentStrong)
                Text(meetingTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MPIconButtonStyle(size: 30))
            .help("Ignora")

            Button(action: onRecord) {
                Label(localized("Registra"), systemImage: "record.circle")
            }
            .buttonStyle(MPPrimaryButtonStyle())
            .help("Avvia registrazione")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 440, height: 82)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: 0x131316)))
        )
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                Capsule()
                    .fill(MeetingPilotDesign.accentStrong)
                    .frame(width: max(0, (proxy.size.width - 28) * progress), height: 2)
                    .offset(x: 14, y: proxy.size.height - 4)
            }
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onAppear {
            progress = 1
            withAnimation(.linear(duration: timeoutSeconds)) {
                progress = 0
            }
        }
    }
}
