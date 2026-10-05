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


final class PermissionsSetupWindow {
    static let shared = PermissionsSetupWindow()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    func show(rows: [PermissionRow], onEnable: @escaping (PermissionRow) -> Void, onRefresh: (() -> [PermissionRow])? = nil) {
        close()
        let height = min(420, 132 + rows.count * 72)
        let size = NSSize(width: 520, height: height)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Meeting Pilot"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.hidesOnDeactivate = true

        // This panel is a separate NSPanel/NSHostingController hierarchy from the main
        // window, so it doesn't inherit RootView's .preferredColorScheme(model.appTheme)
        // override — without setting it here too, it silently falls back to following
        // the system's actual appearance, which can visibly mismatch the app's chosen
        // theme (e.g. app forced to light, system still in Dark Mode).
        let theme = MeetingPilotTheme(rawValue: UserDefaults.standard.string(forKey: "MeetingPilotAppTheme")) ?? .dark
        let view = PermissionsSetupView(
            initialRows: rows,
            onClose: { [weak self] in self?.close() },
            onEnable: onEnable,
            onRefresh: onRefresh ?? { rows }
        )
        .preferredColorScheme(theme == .light ? .light : .dark)
        let hostingController = NSHostingController(rootView: AnyView(view))
        self.hostingController = hostingController
        panel.contentView = hostingController.view
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }
}

/// Asked once, on a new install or the first launch after updating, before the
/// permission checklist (and again at launch until answered): whether recordings
/// become study notes, meeting notes or either (USER_PROFILE). It has no close button,
/// because every later summary depends on the answer.
final class ProfileSetupWindow {
    static let shared = ProfileSetupWindow()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    func show(onChoose: @escaping (UserProfile) -> Void) {
        close()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 540, height: 284)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Meeting Pilot"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .normal
        panel.hidesOnDeactivate = false

        // A separate window hierarchy: set the app's theme here too (see PermissionsSetupWindow).
        let theme = MeetingPilotTheme(rawValue: UserDefaults.standard.string(forKey: "MeetingPilotAppTheme")) ?? .dark
        let view = ProfileSetupView { [weak self] profile in
            self?.close()
            onChoose(profile)
        }
        .preferredColorScheme(theme == .light ? .light : .dark)
        let hostingController = NSHostingController(rootView: AnyView(view))
        self.hostingController = hostingController
        panel.contentView = hostingController.view
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }
}

struct ProfileSetupView: View {
    let onChoose: (UserProfile) -> Void
    @State private var student = false
    @State private var worker = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                BrandTile(size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized("Studente o lavoratore?"))
                        .font(.mpDisplay(18))
                        .foregroundStyle(MeetingPilotDesign.primaryText(for: colorScheme))
                    Text(localized("Scegli uno o entrambi: Meeting Pilot scriverà note pensate per le tue lezioni, le tue riunioni o tutte e due."))
                        .font(MPFont.body(.medium))
                        .foregroundStyle(MeetingPilotDesign.secondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProfileRoleCards(student: $student, worker: $worker, keepsOne: false)

            HStack {
                Text(localized("Puoi cambiarlo quando vuoi in Impostazioni."))
                    .font(MPFont.callout(.medium))
                    .foregroundStyle(MeetingPilotDesign.tertiaryText(for: colorScheme))
                Spacer()
                Button(localized("Continua")) {
                    onChoose(UserProfile(student: student, worker: worker))
                }
                .buttonStyle(MPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!student && !worker)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MeetingPilotBackdrop())
        .tint(MeetingPilotDesign.accent)
        .foregroundStyle(MeetingPilotDesign.primaryText(for: colorScheme))
    }
}

/// Student and worker as two cards that can both be on.
struct ProfileRoleCards: View {
    @Binding var student: Bool
    @Binding var worker: Bool
    /// Settings always keep one role; the first-launch question starts with none.
    var keepsOne = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RecorderChoiceCard(
                title: "Studente",
                subtitle: "Lezioni e seminari: concetti chiave, compiti, domande di ripasso.",
                assetName: nil,
                fallbackSymbol: "graduationcap.fill",
                selected: student
            ) {
                guard !(keepsOne && student && !worker) else { return }
                student.toggle()
            }
            RecorderChoiceCard(
                title: "Lavoratore",
                subtitle: "Riunioni e call: decisioni, action item, rischi.",
                assetName: nil,
                fallbackSymbol: "briefcase.fill",
                selected: worker
            ) {
                guard !(keepsOne && worker && !student) else { return }
                worker.toggle()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PermissionsSetupView: View {
    @State private var rows: [PermissionRow]
    let onClose: () -> Void
    let onEnable: (PermissionRow) -> Void
    let onRefresh: () -> [PermissionRow]
    @Environment(\.colorScheme) private var colorScheme

    init(initialRows: [PermissionRow], onClose: @escaping () -> Void, onEnable: @escaping (PermissionRow) -> Void, onRefresh: @escaping () -> [PermissionRow]) {
        self._rows = State(initialValue: initialRows)
        self.onClose = onClose
        self.onEnable = onEnable
        self.onRefresh = onRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                BrandTile(size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized("Permessi richiesti"))
                        .font(.mpDisplay(18))
                        .foregroundStyle(MeetingPilotDesign.primaryText(for: colorScheme))
                    Text(localized("Abilita questi permessi per far funzionare Meeting Pilot."))
                        .font(MPFont.body(.medium))
                        .foregroundStyle(MeetingPilotDesign.secondaryText(for: colorScheme))
                    Text("Dopo aver attivato un toggle in macOS premi Aggiorna. Registrazione schermo richiede sempre un riavvio dell'app per essere rilevata; Accessibilita' di solito si aggiorna subito.")
                        .font(MPFont.callout(.medium))
                        .foregroundStyle(MeetingPilotDesign.tertiaryText(for: colorScheme))
                }
                Spacer()
                Button("Aggiorna") {
                    rows = onRefresh()
                }
                .buttonStyle(CompactButtonStyle())
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(MPIconButtonStyle(size: 28))
                .help("Chiudi")
            }

            VStack(spacing: 8) {
                ForEach(rows) { row in
                    PermissionRowView(row: row) {
                        // Release the key window before macOS asks for an
                        // administrator password in System Settings.
                        onClose()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            onEnable(row)
                        }
                    }
                }
            }
            if rows.isEmpty {
                Text("Tutti i permessi risultano abilitati. Se Teams/OCR non funzionano ancora, riavvia Meeting Pilot.")
                    .font(MPFont.subheadline(.semibold))
                    .foregroundStyle(MeetingPilotDesign.success)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeetingPilotDesign.success.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: MPRadius.control))
            }
        }
        .onAppear {
            rows = onRefresh()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MeetingPilotBackdrop())
        .tint(MeetingPilotDesign.accent)
        .foregroundStyle(MeetingPilotDesign.primaryText(for: colorScheme))
    }
}

struct RecentMeetingsList: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let meetings: [MeetingItem]?
    var embedded = false

    init(title: String = "Ultime riunioni", meetings: [MeetingItem]? = nil, embedded: Bool = false) {
        self.title = title
        self.meetings = meetings
        self.embedded = embedded
    }

    private var displayedMeetings: [MeetingItem] {
        meetings ?? model.recentMeetings
    }

    var body: some View {
        if embedded {
            table
        } else {
            VStack(alignment: .leading, spacing: 14) {
                MPSectionTitle(title, detail: displayedMeetings.isEmpty ? nil : "\(displayedMeetings.count)")
                table
            }
            .mpCard(padding: 18)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displayedMeetings.isEmpty {
                emptyState
            } else {
                HStack(spacing: 12) {
                    MPEyebrow("Registrazione").frame(maxWidth: .infinity, alignment: .leading)
                    MPEyebrow("Progetto").frame(width: 140, alignment: .leading)
                    MPEyebrow("Temi").frame(width: 200, alignment: .leading)
                    MPEyebrow("Pubblicata su").frame(width: 96, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                ForEach(Array(displayedMeetings.enumerated()), id: \.element.id) { index, meeting in
                    if index > 0 {
                        Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1).padding(.horizontal, 10)
                    }
                    MeetingRow(meeting: meeting)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(MPFont.hero())
                .foregroundStyle(MeetingPilotDesign.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(MeetingPilotDesign.accentTint))
            Text(localized(meetings == nil ? "Nessuna riunione pubblicata ancora" : "Nessuna riunione oggi"))
                .font(MPFont.body(.semibold))
                .foregroundStyle(MeetingPilotDesign.textColor)
            Text(localized(meetings == nil
                ? "Le riunioni pubblicate appariranno qui."
                : "Le riunioni rilevate dal calendario o registrate manualmente appariranno qui."))
                .font(MPFont.callout())
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

private struct MeetingRow: View {
    @EnvironmentObject private var model: AppModel
    let meeting: MeetingItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(MPFont.body(.medium))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.dateText)
                        .font(MPFont.caption(.medium, design: .monospaced))
                    if !meeting.subtitle.isEmpty {
                        Text("·")
                        Text(meeting.subtitle)
                    }
                }
                .font(MPFont.caption())
                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.assignProject(to: meeting)
            } label: {
                MeetingTagBadge(label: meeting.project ?? localized("Assegna"), color: MeetingPilotDesign.accent, isPlaceholder: meeting.project == nil, systemImage: "folder")
            }
            .buttonStyle(.plain)
            .help("Assegna progetto")
            .frame(width: 140, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(meeting.themes.prefix(2), id: \.self) { theme in
                    MeetingTagBadge(label: theme, color: MeetingPilotDesign.textDimColor, isPlaceholder: false)
                }
                if meeting.themes.count > 2 {
                    Text("+\(meeting.themes.count - 2)")
                        .font(MPFont.caption(.medium))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                }
                Button {
                    model.assignTheme(to: meeting)
                } label: {
                    Image(systemName: "plus")
                        .font(MPFont.micro(.bold))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .overlay(Circle().strokeBorder(MeetingPilotDesign.lineStrongColor, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || meeting.themes.isEmpty ? 1 : 0.5)
                .help("Aggiungi tema")
            }
            .frame(width: 200, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(meeting.publicationTargets.prefix(3)) { target in
                    Button {
                        if let url = target.actionURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        BundledAssetIcon(
                            name: target.service.assetName,
                            fallbackSymbol: target.service.fallbackSymbol,
                            size: target.service.iconSize
                        )
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: MPRadius.chip, style: .continuous)
                                .fill(target.service.needsLightBackground ? Color.white : MeetingPilotDesign.hoverColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(target.actionURL == nil)
                    .help(meetingPublicationLabel(for: target.service))
                }
            }
            .frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous)
                .fill(hovering ? MeetingPilotDesign.hoverColor : .clear)
        )
        .onHover { hovering = $0 }
        .animation(.mpSmooth, value: hovering)
    }
}

struct MeetingTagBadge: View {
    let label: String
    let color: Color
    let isPlaceholder: Bool
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(MPFont.micro(.semibold))
            }
            Text(label)
                .font(MPFont.caption(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isPlaceholder ? MeetingPilotDesign.textFaintColor : color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isPlaceholder ? Color.clear : color.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(isPlaceholder ? MeetingPilotDesign.lineStrongColor : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .frame(maxWidth: 190, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct HistoryView: View {
    var body: some View {
        ContentPane(title: "Cronologia") {
            HistorySection()
                .mpCard(padding: 18)
        }
    }
}

struct HistorySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecentMeetingsList(embedded: true)
            Button {
                model.openProject()
            } label: {
                Label(localized("Apri cartella progetto"), systemImage: "folder")
            }
            .buttonStyle(MPSecondaryButtonStyle(compact: true))
        }
    }
}
