import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .layoutPriority(1)
            content
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(0)
                .clipped()
                .id(model.selectedSection)
                .transition(.opacity)
        }
        .animation(.mpSmooth, value: model.selectedSection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MeetingPilotBackdrop())
        .foregroundStyle(MeetingPilotDesign.textColor)
        .tint(MeetingPilotDesign.accent)
        .preferredColorScheme(model.appTheme == .light ? .light : .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedSection {
        case .dashboard:
            DashboardView()
        case .history:
            HistoryView()
        case .recorder:
            RecorderView()
        case .provider:
            ProviderView()
        case .chat:
            ChatView()
        case .publicationTargets:
            PublicationTargetsView()
        case .journal:
            JournalView()
        case .notion:
            NotionView()
        case .obsidian:
            ObsidianView()
        case .appleNotes:
            AppleNotesView()
        case .teams:
            TeamsScraperView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandTile(size: 30)
                Text("Meeting Pilot")
                    .font(.mpDisplay(13))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    groupLabel("Monitoraggio")
                    SidebarRow(section: .dashboard, symbol: "square.grid.2x2")
                    SidebarRow(section: .chat, symbol: "bubble.left.and.text.bubble.right")
                    SidebarRow(section: .journal, symbol: "book.pages")

                    groupLabel("Configurazione")
                        .padding(.top, 14)
                    SidebarRow(section: .publicationTargets, symbol: "square.stack.3d.up")
                    SidebarRow(section: .recorder, symbol: "point.3.connected.trianglepath.dotted")
                    SidebarRow(section: .settings, symbol: "gearshape")
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 12)

            SidebarStatusFooter()
                .padding(8)
        }
        .frame(width: MeetingPilotDesign.sidebarWidth)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MPRadius.window, style: .continuous)
                .fill(MeetingPilotDesign.sidebarColor.opacity(0.72))
        )
        .meetingPilotGlass(
            in: RoundedRectangle(cornerRadius: MPRadius.window, style: .continuous),
            interactive: false
        )
        .padding(10)
    }

    private func groupLabel(_ title: String) -> some View {
        MPEyebrow(title)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let section: AppSection
    let symbol: String
    @State private var hovering = false

    private var selected: Bool { model.selectedSection == section }

    var body: some View {
        Button {
            model.selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(MPFont.subheadline(.medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
                    .frame(width: 20)
                Text(localized(section.rawValue))
                    .font(MPFont.body(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? MeetingPilotDesign.textColor : MeetingPilotDesign.textDimColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous)
                    .fill(selected ? MeetingPilotDesign.accentTint : (hovering ? MeetingPilotDesign.hoverColor : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.mpSnappy, value: selected)
        .help(localized(section.rawValue))
    }
}

/// Always-visible answer to "will my next meeting be picked up?".
private struct SidebarStatusFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: model.watcher.watcherActive ? MeetingPilotDesign.success : MeetingPilotDesign.warning, pulsing: model.watcher.watcherActive)
            Text(localized(model.watcher.watcherActive ? "Rilevamento attivo" : "Rilevamento in pausa"))
                .font(MPFont.callout(.medium))
                .foregroundStyle(MeetingPilotDesign.textColor)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous)
                .fill(MeetingPilotDesign.hoverColor)
        )
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1 : 0.4)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { pulse = true }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showHistory = false

    private var dateEyebrow: String {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MPPageHeader(title: "Panoramica", eyebrow: dateEyebrow) {
                    RecordingControls()
                }

                HStack(spacing: 12) {
                    StatTile(title: "Riunioni oggi", value: "\(model.todayProcessed)", symbol: "checkmark.seal")
                    StatTile(title: "In coda", value: "\(model.queueCount)", symbol: "tray.full")
                }

                if !model.watcher.watcherActive {
                    MPCallout(
                        tone: .warning,
                        systemImage: "pause.circle",
                        title: "Rilevamento automatico in pausa",
                        message: "Le nuove riunioni non vengono registrate né elaborate finché non lo riattivi."
                    ) {
                        Button(localized("Riattiva")) {
                            model.startWatcher()
                        }
                        .buttonStyle(MPPrimaryButtonStyle(compact: true))
                    }
                }

                if model.recording.nativeRecordingActive {
                    NativeRecordingStatusCard()
                }
                if model.needsAccessibilityWarning {
                    AccessibilityWarningCard()
                }
                if model.showTranscriptionRetryCard {
                    TranscriptionRetryCard()
                }
                if model.showSummaryRetryCard {
                    SummaryRetryCard()
                }

                if PipelineCard.isRelevant(model) {
                    PipelineCard()
                }

                RecentMeetingsList(title: "Riunioni di oggi", meetings: model.todayMeetings)

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation(.mpSmooth) { showHistory.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(MPFont.subheadline(.medium))
                                .foregroundStyle(MeetingPilotDesign.accent)
                            Text(localized("Cronologia"))
                                .font(MPFont.body(.semibold))
                            Text(localized("Tutte le riunioni elaborate"))
                                .font(MPFont.callout())
                                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(MPFont.caption(.semibold))
                                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                                .rotationEffect(.degrees(showHistory ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showHistory {
                        HistorySection()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .mpCard(padding: 14)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tone: MPTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(MPFont.caption(.semibold))
                    .foregroundStyle(tone == .neutral ? MeetingPilotDesign.textFaintColor : tone.color)
                MPEyebrow(title)
            }
            Text(value)
                .font(.mpDisplay(24, weight: .medium))
                .foregroundStyle(tone == .neutral ? MeetingPilotDesign.textColor : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mpCard(padding: 16)
    }
}

// MARK: - Pipeline

/// Only shown while something is moving through the pipeline or needs attention;
/// an idle five-step diagram tells the user nothing.
struct PipelineCard: View {
    @EnvironmentObject private var model: AppModel

    /// A paused watcher and missing Accessibility have their own callouts, so only real
    /// activity or sessions (including failed ones) bring the card up.
    static func isRelevant(_ model: AppModel) -> Bool {
        model.recording.nativeRecordingActive
            || model.recording.externalRecordingActive
            || model.queueCount > 0
            || (1..<5).contains(model.pipelineStage)
            || !model.processingSessions.isEmpty
    }

    /// Paused detection and missing Accessibility are reported by their own callouts,
    /// so the badge only speaks about the sessions shown here.
    private var badge: (String, MPTone) {
        model.processingSessions.contains { $0.stage == .failed }
            ? ("Richiede attenzione", .warning)
            : ("In corso", .accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                MPSectionTitle("In elaborazione")
                MPBadge(text: badge.0, tone: badge.1)
            }
            PipelineProgress()
            if !model.processingSessions.isEmpty {
                ProcessingQueueList()
            }
        }
        .mpCard(padding: 18)
    }
}

struct ProcessingQueueList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.processingSessions.prefix(3)) { session in
                let failed = session.stage == .failed
                HStack(spacing: 12) {
                    Image(systemName: session.stage.symbol)
                        .font(MPFont.callout(.semibold))
                        .foregroundStyle(failed ? MeetingPilotDesign.warning : MeetingPilotDesign.accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill((failed ? MeetingPilotDesign.warning : MeetingPilotDesign.accent).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(MPFont.body(.medium))
                            .lineLimit(1)
                        Text(localized(session.failureMessage ?? (session.date.map(meetingDateText) ?? "In elaborazione")))
                            .font(MPFont.caption())
                            .foregroundStyle(failed ? MeetingPilotDesign.warning : MeetingPilotDesign.textFaintColor)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    MPBadge(text: session.stage.title, tone: failed ? .warning : .accent)
                    if failed && session.canRetry {
                        Button {
                            model.retryProcessingSession(session)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(MPIconButtonStyle(size: 28))
                        .help("Riprova")
                    }
                    if failed {
                        Button(role: .destructive) {
                            model.discardProcessingSession(session)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(MPIconButtonStyle(size: 28))
                        .help("Sposta nel Cestino")
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous)
                        .fill(MeetingPilotDesign.hoverColor)
                )
            }
            if model.processingSessions.count > 3 {
                Text(String(format: localized("+ altre %d in coda"), model.processingSessions.count - 3))
                    .font(MPFont.caption())
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PipelineProgress: View {
    @EnvironmentObject private var model: AppModel

    var steps: [PipelineStep] {
        let stage = model.pipelineStage
        return [
            PipelineStep(title: "Rilevamento", state: stage == 0 ? .active : .done, count: model.pipelineCounts.detection),
            PipelineStep(title: "Registrazione", state: state(for: 1, current: stage), count: model.pipelineCounts.recording),
            PipelineStep(title: "Trascrizione", state: state(for: 2, current: stage), count: model.pipelineCounts.transcription),
            PipelineStep(title: "Sintesi", state: state(for: 3, current: stage), count: model.pipelineCounts.summarization),
            PipelineStep(title: "Pubblicazione", state: state(for: 4, current: stage), count: model.pipelineCounts.publishing)
        ]
    }

    private func state(for step: Int, current: Int) -> StepState {
        if current >= 5 || current > step { return .done }
        if current == step { return .active }
        return .pending
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        connector(visible: index > 0, done: step.state != .pending)
                        StepDot(state: step.state, count: step.count, number: index + 1)
                        connector(visible: index < steps.count - 1, done: steps[min(index + 1, steps.count - 1)].state != .pending)
                    }
                    Text(localized(step.title))
                        .font(MPFont.caption(step.state == .active ? .semibold : .regular))
                        .foregroundStyle(step.state == .pending ? MeetingPilotDesign.textFaintColor : MeetingPilotDesign.textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.mpSmooth, value: model.pipelineStage)
    }

    private func connector(visible: Bool, done: Bool) -> some View {
        Rectangle()
            .fill(visible ? (done ? MeetingPilotDesign.success.opacity(0.7) : MeetingPilotDesign.lineStrongColor) : .clear)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }
}

struct StepDot: View {
    let state: StepState
    let count: Int
    var number: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activePulse = false

    private var color: Color {
        switch state {
        case .done: return MeetingPilotDesign.success
        case .active: return MeetingPilotDesign.accent
        case .pending: return MeetingPilotDesign.textFaintColor
        }
    }

    var body: some View {
        ZStack {
            // The active step is doing real work right now, so a soft breathing ring is
            // live status, not decoration — pending/done stay still.
            if state == .active && !reduceMotion {
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .frame(width: 26, height: 26)
                    .scaleEffect(activePulse ? 1.35 : 1)
                    .opacity(activePulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: activePulse)
            }

            switch state {
            case .done:
                Circle().fill(color.opacity(0.16)).frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(MPFont.caption(.bold))
                    .foregroundStyle(color)
            case .active:
                Circle().fill(color).frame(width: 26, height: 26)
                    .shadow(color: color.opacity(0.45), radius: 6)
                if count > 0 {
                    Text("\(count)")
                        .font(MPFont.callout(.bold))
                        .foregroundStyle(.white)
                } else {
                    Circle().fill(.white).frame(width: 8, height: 8)
                }
            case .pending:
                Circle().strokeBorder(MeetingPilotDesign.lineStrongColor, lineWidth: 1.5).frame(width: 26, height: 26)
                Text("\(number)")
                    .font(MPFont.caption(.medium, design: .monospaced))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 34, height: 34)
        .onAppear { activePulse = true }
    }
}

// MARK: - Alerts

struct NativeRecordingStatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MPCallout(
            tone: .accent,
            systemImage: model.recording.nativeRecordingPaused ? "pause.fill" : "record.circle",
            title: model.recording.nativeRecordingPaused ? "Registrazione in pausa" : "Registrazione in corso",
            message: model.recording.nativeRecordingPath.isEmpty ? "File audio in scrittura" : compactPath(model.recording.nativeRecordingPath)
        ) {
            Button {
                LiveSidebarWindow.shared.toggle(audioFileURL: model.recording.nativeRecordingPath.isEmpty ? nil : URL(fileURLWithPath: model.recording.nativeRecordingPath))
            } label: {
                Label(localized("Sidebar dal vivo"), systemImage: "sidebar.right")
            }
            .buttonStyle(MPSecondaryButtonStyle(compact: true))
        }
    }
}

struct AccessibilityWarningCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MPCallout(
            tone: .warning,
            systemImage: "hand.raised",
            title: "Accessibilità non attiva",
            message: model.recorderMode == "transcribex"
                ? "La registrazione continua, ma Meeting Pilot non può leggere titolo e partecipanti da Teams né controllare il recorder esterno."
                : "La registrazione continua, ma Meeting Pilot non può leggere titolo e partecipanti da Teams."
        ) {
            Button(localized("Ho attivato")) {
                model.confirmAccessibilityPermission()
            }
            .buttonStyle(MPSecondaryButtonStyle(compact: true))
            Button(localized("Apri Accessibilità")) {
                model.openAccessibilitySettings()
            }
            .buttonStyle(MPPrimaryButtonStyle(compact: true))
        }
    }
}

struct TranscriptionRetryCard: View {
    @EnvironmentObject private var model: AppModel

    private var title: String {
        if model.transcriptionRetryInProgress { return "Trascrizione in corso" }
        return model.nonRetryableTranscriptionIssue == nil ? "Trascrizione non completata" : "Nessun parlato rilevato"
    }

    private var message: String {
        model.nonRetryableTranscriptionIssue
            ?? (model.transcriptionAudioUnreadable
                ? "Il file audio è incompleto o non leggibile: non può essere trascritto. Registra nuovamente la call."
                : (model.appleDictationRequired
                    ? "L'audio è salvo. Il motore Apple richiede che Dettatura sia attiva nelle impostazioni della tastiera."
                    : "L'audio è salvo: puoi ripartire dalla trascrizione senza registrare nuovamente la call."))
    }

    var body: some View {
        MPCallout(
            tone: model.transcriptionRetryInProgress ? .accent : .warning,
            systemImage: model.transcriptionRetryInProgress ? "waveform" : "exclamationmark.triangle",
            title: title,
            message: message
        ) {
            if model.appleDictationRequired && !model.transcriptionRetryInProgress {
                Button(localized("Apri Dettatura")) {
                    model.openAppleDictationSettings()
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
            }
            if !model.transcriptionAudioUnreadable && model.nonRetryableTranscriptionIssue == nil {
                Button(localized(model.transcriptionRetryInProgress ? "Riprovo…" : "Riprova trascrizione")) {
                    model.retryFailedTranscription()
                }
                .buttonStyle(MPPrimaryButtonStyle(compact: true))
                .disabled(model.transcriptionRetryInProgress)
            }
            Button {
                model.dismissTranscriptionRetryCard()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MPIconButtonStyle(size: 26))
            .disabled(model.transcriptionRetryInProgress)
            .help("Chiudi")
        }
    }
}

struct SummaryRetryCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MPCallout(
            tone: model.retryInProgress ? .accent : .warning,
            systemImage: model.retryInProgress ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle",
            title: model.retryInProgress ? "Sintesi in corso" : "Sintesi LLM non completata",
            message: "Il transcript è salvo: puoi ripartire dalla sintesi senza riascoltare la call."
        ) {
            Button(localized(model.retryInProgress ? "Riprovo…" : "Riprova sintesi")) {
                model.retryFailedSummary()
            }
            .buttonStyle(MPPrimaryButtonStyle(compact: true))
            .disabled(model.retryInProgress)
            Button {
                model.dismissSummaryRetryCard()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MPIconButtonStyle(size: 26))
            .disabled(model.retryInProgress)
            .help("Chiudi")
        }
    }
}

// MARK: - Recording controls

struct RecordingControls: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if model.recording.nativeRecordingActive {
                if compact {
                    Button { model.recording.toggleNativeRecordingPause() } label: {
                        Image(systemName: model.recording.nativeRecordingPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(MPIconButtonStyle(size: 30))
                    .help(localized(model.recording.nativeRecordingPaused ? "Riprendi registrazione" : "Metti in pausa"))
                    Button { model.recording.stopNativeRecording() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(MPIconButtonStyle(size: 30, active: true))
                    .help("Ferma e salva la registrazione")
                } else {
                    Button {
                        LiveSidebarWindow.shared.toggle(audioFileURL: model.recording.nativeRecordingPath.isEmpty ? nil : URL(fileURLWithPath: model.recording.nativeRecordingPath))
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(MPIconButtonStyle(size: 32))
                    .help("Mostra la sidebar dal vivo con trascrizione e parlanti")
                    Button { model.recording.toggleNativeRecordingPause() } label: {
                        Label(localized(model.recording.nativeRecordingPaused ? "Riprendi" : "Pausa"), systemImage: model.recording.nativeRecordingPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(MPSecondaryButtonStyle())
                    .help(localized(model.recording.nativeRecordingPaused ? "Riprendi registrazione" : "Metti in pausa"))
                    Button { model.recording.stopNativeRecording() } label: {
                        Label(localized("Ferma"), systemImage: "stop.fill")
                    }
                    .buttonStyle(MPPrimaryButtonStyle())
                    .help("Ferma e salva la registrazione")
                }
            } else if compact {
                Button { model.recording.showManualRecordingPrompt() } label: {
                    Image(systemName: "record.circle")
                }
                .buttonStyle(MPIconButtonStyle(size: 30, active: true))
                .help("Avvia registrazione")
            } else {
                Button { model.recording.showManualRecordingPrompt() } label: {
                    Label(localized("Registra"), systemImage: "record.circle")
                }
                .buttonStyle(MPPrimaryButtonStyle())
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Avvia registrazione (⇧⌘R)")
            }
        }
        .fixedSize()
    }
}
