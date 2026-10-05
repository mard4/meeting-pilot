import AppKit
import SwiftUI

/// The first-launch tour: who the notes are for, how recordings get in (record or
/// import), who writes the notes and where they go. Shown until the user answers who
/// they are, and from Help afterwards. It has no close button because every later
/// summary depends on that answer.
final class WelcomeWindow {
    static let shared = WelcomeWindow()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    /// `onProfile` runs as soon as the user says who they are, so quitting halfway
    /// through the tour keeps the answer. `onFinish` gets the page to set up next, if any.
    func show(
        model: AppModel,
        initialProfile: UserProfile?,
        onProfile: @escaping (UserProfile) -> Void,
        onFinish: @escaping (AppSection?) -> Void
    ) {
        close()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: WelcomeView.size),
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
        let view = WelcomeView(initialProfile: initialProfile, onProfile: onProfile) { [weak self] section in
            self?.close()
            onFinish(section)
        }
        .environmentObject(model)
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

enum WelcomeStep: Int, CaseIterable {
    case welcome, profile, capture, notes, publish, chat, ready
}

/// Something the user chose to set up after the tour, opened in the main window.
enum WelcomeSetup: Hashable {
    case notion, obsidian, summaryEngine

    var section: AppSection {
        self == .summaryEngine ? .recorder : .publicationTargets
    }
}

struct WelcomeView: View {
    static let size = NSSize(width: 680, height: 520)

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: WelcomeStep
    @State private var forward = true
    @State private var student: Bool
    @State private var worker: Bool
    @State private var setupLater: [WelcomeSetup] = []
    let onProfile: (UserProfile) -> Void
    let onFinish: (AppSection?) -> Void

    init(
        initialProfile: UserProfile?,
        step: WelcomeStep = .welcome,
        onProfile: @escaping (UserProfile) -> Void,
        onFinish: @escaping (AppSection?) -> Void
    ) {
        _step = State(initialValue: step)
        _student = State(initialValue: initialProfile?.isStudent ?? false)
        _worker = State(initialValue: initialProfile?.isWorker ?? false)
        self.onProfile = onProfile
        self.onFinish = onFinish
    }

    private var profile: UserProfile? {
        student || worker ? UserProfile(student: student, worker: worker) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                page(step)
                    .id(step)
                    .transition(pageTransition)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)
            footer
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(MeetingPilotBackdrop())
        .foregroundStyle(MeetingPilotDesign.textColor)
        .tint(MeetingPilotDesign.accent)
    }

    @ViewBuilder
    private func page(_ step: WelcomeStep) -> some View {
        switch step {
        case .welcome: WelcomeIntroPage()
        case .profile: WelcomeProfilePage(student: $student, worker: $worker)
        case .capture: WelcomeCapturePage(profile: profile ?? .worker)
        case .notes: WelcomeNotesPage(setupLater: $setupLater)
        case .publish: WelcomePublishPage(setupLater: $setupLater)
        case .chat: WelcomeChatPage(profile: profile ?? .worker)
        case .ready: WelcomeReadyPage(profile: profile ?? .worker, setupLater: setupLater)
        }
    }

    /// Pages slide the way the user is going; with Reduce Motion they only fade.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            WelcomeProgress(current: step.rawValue, count: WelcomeStep.allCases.count)
            Spacer()
            if step != .welcome {
                Button(localized("Indietro")) { go(by: -1) }
                    .buttonStyle(MPSecondaryButtonStyle())
            }
            Button {
                advance()
            } label: {
                Text(localized(primaryTitle))
            }
            .buttonStyle(MPPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(step == .profile && profile == nil)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Inizia"
        case .ready: return setupLater.isEmpty ? "Apri Meeting Pilot" : "Configura ora"
        default: return "Continua"
        }
    }

    private func advance() {
        if step == .profile, let profile {
            onProfile(profile)
        }
        if step == .ready {
            onFinish(setupLater.first?.section)
        } else {
            go(by: 1)
        }
    }

    private func go(by offset: Int) {
        guard let next = WelcomeStep(rawValue: step.rawValue + offset) else { return }
        forward = offset > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .mpSmooth) {
            step = next
        }
    }
}

/// One capsule per page; the current one stretches.
private struct WelcomeProgress: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? MeetingPilotDesign.accent : (index < current ? MeetingPilotDesign.accent.opacity(0.4) : MeetingPilotDesign.lineStrongColor))
                    .frame(width: index == current ? 22 : 6, height: 6)
            }
        }
        .animation(.mpSnappy, value: current)
        .accessibilityElement()
        .accessibilityLabel(String(format: localized("Passo %d di %d"), current + 1, count))
    }
}

private struct WelcomePageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MPEyebrow(eyebrow, color: MeetingPilotDesign.accent)
            Text(localized(title))
                .font(.mpDisplay(22))
            Text(localized(subtitle))
                .font(MPFont.body())
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Welcome

private struct WelcomeIntroPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                BrandTile(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting Pilot")
                        .font(.mpDisplay(26))
                    Text(localized("Lezioni e riunioni diventano note, da sole."))
                        .font(MPFont.headline(.medium))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                }
            }
            WelcomeFlow()
            Text(localized("La trascrizione avviene sempre sul tuo Mac. In due minuti scegli per chi sono le note, come iniziare e dove pubblicarle."))
                .font(MPFont.body())
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Record or import, transcribe, summarize, publish: a pulse travels through the four
/// steps, the way a recording does. Still under Reduce Motion.
private struct WelcomeFlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let steps: [(symbol: String, title: String)] = [
        ("record.circle", "Registra o importa"),
        ("waveform", "Trascrive"),
        ("sparkles", "Riassume"),
        ("paperplane", "Pubblica"),
    ]
    private let stepDuration = 0.9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            // Steps light up one after another, then all stay lit for a beat before it restarts.
            let phases = Double(steps.count + 1)
            let phase = reduceMotion ? phases - 1 : (context.date.timeIntervalSinceReferenceDate / stepDuration).truncatingRemainder(dividingBy: phases)
            let active = Int(phase)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let lit = index <= active
                    VStack(spacing: 8) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(lit ? Color.white : MeetingPilotDesign.textFaintColor)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(lit ? MeetingPilotDesign.accent : MeetingPilotDesign.elevatedColor))
                            .overlay(Circle().strokeBorder(lit ? Color.clear : MeetingPilotDesign.lineStrongColor, lineWidth: 1))
                            .scaleEffect(index == active ? 1.08 : 1)
                            .shadow(color: MeetingPilotDesign.accent.opacity(lit ? 0.35 : 0), radius: 10, y: 3)
                            .animation(.mpSnappy, value: active)
                        Text(localized(step.title))
                            .font(MPFont.callout(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(lit ? MeetingPilotDesign.textColor : MeetingPilotDesign.textFaintColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 110)
                    if index < steps.count - 1 {
                        WelcomeConnector(fill: index < active ? 1 : (index == active ? phase - Double(active) : 0))
                            .padding(.top, 25)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .mpCard(padding: 0)
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeConnector: View {
    let fill: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(MeetingPilotDesign.lineStrongColor)
                Capsule().fill(MeetingPilotDesign.accent).frame(width: geometry.size.width * fill)
            }
        }
        .frame(height: 2)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Who

private struct WelcomeProfilePage: View {
    @Binding var student: Bool
    @Binding var worker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomePageHeader(
                eyebrow: "Per chi",
                title: "Studente, lavoratore o entrambi?",
                subtitle: "Le note seguono quello che registri: una lezione diventa appunti di studio, una riunione un verbale con le cose da fare."
            )
            ProfileRoleCards(student: $student, worker: $worker, keepsOne: false)
            VStack(alignment: .leading, spacing: 8) {
                if student {
                    WelcomeSectionChips(symbol: "graduationcap", sections: ["Concetti chiave", "Compiti e scadenze", "Per l'esame", "Domande di ripasso"])
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if worker {
                    WelcomeSectionChips(symbol: "briefcase", sections: ["Decisioni", "Action item", "Domande aperte", "Rischi"])
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.mpSmooth, value: student)
            .animation(.mpSmooth, value: worker)
            Text(localized("Se scegli entrambi, il titolo decide; puoi cambiare tipo a ogni registrazione e in Impostazioni."))
                .font(MPFont.callout())
                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeSectionChips: View {
    let symbol: String
    let sections: [String]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(MPFont.caption(.semibold))
                .foregroundStyle(MeetingPilotDesign.accent)
                .frame(width: 18)
            ForEach(sections, id: \.self) { section in
                MPBadge(text: section)
            }
        }
    }
}

// MARK: - Record or import

private struct WelcomeCapturePage: View {
    let profile: UserProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WelcomePageHeader(
                eyebrow: "Come iniziare",
                title: "Registra dal vivo o importa un file",
                subtitle: "Due strade, stesse note: trascrizione, sintesi e pubblicazione partono da sole."
            )
            HStack(alignment: .top, spacing: 12) {
                WelcomeCaptureCard(
                    symbol: "record.circle",
                    title: "Registra",
                    shortcut: "⇧⌘R",
                    text: "Quando inizia una call Teams, Meeting Pilot propone di registrarla. In aula o in sala riunioni premi Registra e scegli microfono, audio del Mac o entrambi.",
                    examples: examples(student: ["Lezione in aula", "Lezione online"], worker: ["Call Teams", "Riunione in presenza"]),
                    effect: .pulse
                )
                WelcomeCaptureCard(
                    symbol: "square.and.arrow.down",
                    title: "Importa",
                    shortcut: "⌘I",
                    text: "Trascina nella finestra un video, un podcast o una registrazione fatta altrove. Aggiungi il PDF delle slide: la trascrizione si divide slide per slide.",
                    examples: examples(student: ["Video della lezione + slide", "Podcast"], worker: ["Webinar registrato", "Registrazione di una call"]),
                    effect: .bounce
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func examples(student: [String], worker: [String]) -> [String] {
        switch profile {
        case .student: return student
        case .worker: return worker
        case .both: return [student[0], worker[0]]
        }
    }
}

private struct WelcomeCaptureCard: View {
    enum Effect { case pulse, bounce }

    let symbol: String
    let title: String
    let shortcut: String
    let text: String
    let examples: [String]
    let effect: Effect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                icon
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.accent)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).fill(MeetingPilotDesign.accentTint))
                Text(localized(title))
                    .font(MPFont.headline())
                Spacer()
                Text(shortcut)
                    .font(MPFont.callout(.semibold, design: .monospaced))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: MPRadius.chip, style: .continuous).fill(MeetingPilotDesign.hoverColor))
            }
            Text(localized(text))
                .font(MPFont.callout())
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            WelcomeFlowLayout(spacing: 6) {
                ForEach(examples, id: \.self) { example in
                    MPBadge(text: example, tone: .accent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mpCard(padding: 16)
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: symbol)
        if reduceMotion {
            image
        } else if effect == .pulse {
            // Recording is live: the dot keeps breathing.
            image.symbolEffect(.pulse, options: .repeating)
        } else {
            // A file lands in the tray as the page appears.
            image.symbolEffect(.bounce.down, options: .repeat(2), value: appeared)
        }
    }
}

// MARK: - Who writes the notes

private struct WelcomeNotesPage: View {
    @EnvironmentObject private var model: AppModel
    @Binding var setupLater: [WelcomeSetup]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomePageHeader(
                eyebrow: "La sintesi",
                title: "Chi scrive le note",
                subtitle: "Un modello legge la trascrizione e scrive la sintesi. Scegli quanto deve restare sul tuo Mac."
            )
            VStack(spacing: 8) {
                WelcomeEngineRow(
                    symbol: "apple.logo",
                    title: "Apple Intelligence",
                    detail: appleDetail,
                    current: model.providerMode == "apple",
                    tone: model.appleIntelligenceAvailable ? .success : .warning
                ) {
                    if !model.appleIntelligenceAvailable {
                        Button(localized("Attiva")) { model.openAppleIntelligenceSettings() }
                            .buttonStyle(MPSecondaryButtonStyle(compact: true))
                            .help(localized("Apre Impostazioni di Sistema › Apple Intelligence e Siri"))
                    }
                }
                WelcomeEngineRow(
                    symbol: "cpu",
                    title: "Modello locale",
                    detail: "oMLX, Ollama o LM Studio sul tuo Mac: privato, serve un modello scaricato.",
                    current: model.providerMode == "local"
                )
                WelcomeEngineRow(
                    symbol: "cloud",
                    title: "Cloud",
                    detail: "OpenAI, Gemini, Claude o compatibili: serve una chiave API, la trascrizione viene inviata al servizio.",
                    current: model.providerMode == "api"
                )
            }
            WelcomeLaterToggle(setup: .summaryEngine, title: "Scegli il modello in Pipeline alla fine", setupLater: $setupLater)
        }
    }

    private var appleDetail: String {
        model.appleIntelligenceAvailable
            ? localized("Attivo su questo Mac: le note vengono scritte senza lasciare il computer.")
            : localized("Non attivo") + ": " + localized(model.appleIntelligenceReason)
    }
}

private struct WelcomeEngineRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let current: Bool
    var tone: MPTone = .neutral
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(current ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).fill(current ? MeetingPilotDesign.accentTint : MeetingPilotDesign.hoverColor))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(localized(title)).font(MPFont.body(.semibold))
                    if current {
                        MPBadge(text: "In uso", tone: tone == .neutral ? .accent : tone)
                    }
                }
                Text(localized(detail))
                    .font(MPFont.caption())
                    .foregroundStyle(tone == .warning && current ? MeetingPilotDesign.warning : MeetingPilotDesign.textDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(
            RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous)
                .strokeBorder(current ? MeetingPilotDesign.accent.opacity(0.45) : MeetingPilotDesign.lineColor, lineWidth: 1)
        )
    }
}

extension WelcomeEngineRow where Accessory == EmptyView {
    init(symbol: String, title: String, detail: String, current: Bool, tone: MPTone = .neutral) {
        self.init(symbol: symbol, title: title, detail: detail, current: current, tone: tone) { EmptyView() }
    }
}

/// "Set this up when the tour ends": the page opens in the main window afterwards.
private struct WelcomeLaterToggle: View {
    let setup: WelcomeSetup
    let title: String
    @Binding var setupLater: [WelcomeSetup]

    var body: some View {
        let chosen = setupLater.contains(setup)
        Button {
            withAnimation(.mpSnappy) {
                if chosen {
                    setupLater.removeAll { $0 == setup }
                } else {
                    setupLater.append(setup)
                }
            }
        } label: {
            Label(localized(title), systemImage: chosen ? "checkmark.circle.fill" : "circle")
                .font(MPFont.callout(.medium))
                .foregroundStyle(chosen ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Where notes go

private struct WelcomePublishPage: View {
    @EnvironmentObject private var model: AppModel
    @Binding var setupLater: [WelcomeSetup]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomePageHeader(
                eyebrow: "Pubblicazione",
                title: "Dove vanno le note",
                subtitle: "Ogni nota arriva in tutte le destinazioni attive. Puoi cambiarle quando vuoi in Pubblicazione."
            )
            VStack(spacing: 8) {
                WelcomeDestinationRow(asset: nil, symbol: "book.pages", title: "Diario", detail: "Sul tuo Mac, con ricerca e chat sulle note.") {
                    destinationToggle("journal")
                }
                WelcomeDestinationRow(asset: "apple_notes_logo.png", symbol: "note.text", title: "Apple Notes", detail: "Una nota per lezione o riunione nell'app Note.") {
                    destinationToggle("apple_notes")
                }
                WelcomeDestinationRow(asset: "Notion_app_logo.png", symbol: "doc.text", title: "Notion", detail: "Un database nel tuo workspace.") {
                    connectLater(.notion, connected: !model.notion.occurrencesDatabaseId.isEmpty)
                }
                WelcomeDestinationRow(asset: "2023_Obsidian_logo.svg", symbol: "book.closed.fill", title: "Obsidian", detail: "Note Markdown nel tuo vault.") {
                    connectLater(.obsidian, connected: !model.obsidianVaultPath.isEmpty)
                }
            }
        }
    }

    private func destinationToggle(_ target: String) -> some View {
        Toggle("", isOn: Binding(
            get: { model.publicationTargets.contains(target) },
            set: { _ in model.togglePublicationTarget(target) }
        ))
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
    }

    @ViewBuilder
    private func connectLater(_ setup: WelcomeSetup, connected: Bool) -> some View {
        if connected {
            MPBadge(text: "Collegato", tone: .success)
        } else {
            let chosen = setupLater.contains(setup)
            Button {
                withAnimation(.mpSnappy) {
                    if chosen {
                        setupLater.removeAll { $0 == setup }
                    } else {
                        setupLater.append(setup)
                    }
                }
            } label: {
                Label(localized(chosen ? "Alla fine" : "Collega"), systemImage: chosen ? "checkmark" : "link")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(MPSecondaryButtonStyle(compact: true))
            .help(localized("Si apre in Pubblicazione quando finisci la presentazione"))
        }
    }
}

private struct WelcomeDestinationRow<Accessory: View>: View {
    let asset: String?
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            BundledAssetIcon(name: asset, fallbackSymbol: symbol, size: 20)
                .foregroundStyle(MeetingPilotDesign.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).fill(MeetingPilotDesign.hoverColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(title)).font(MPFont.body(.semibold))
                Text(localized(detail))
                    .font(MPFont.caption())
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }
}

// MARK: - Ready

private struct WelcomeReadyPage: View {
    let profile: UserProfile
    let setupLater: [WelcomeSetup]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomePageHeader(
                eyebrow: "Pronto",
                title: "Ecco cosa ricevi dopo ogni registrazione",
                subtitle: "La nota arriva da sola, con la trascrizione completa e il file originale a portata di clic."
            )
            HStack(alignment: .top, spacing: 12) {
                if profile.isStudent {
                    WelcomeSampleNote(
                        kind: "Lezione",
                        title: "Termodinamica · Lezione 3",
                        rows: [
                            WelcomeSampleRow("lightbulb", "Concetti chiave", "Entropia e secondo principio", link: "Slide 4"),
                            WelcomeSampleRow("checklist", "Compiti e scadenze", "Esercizi 1–5 entro martedì"),
                        ],
                        showsSlides: true
                    )
                }
                if profile.isWorker {
                    WelcomeSampleNote(
                        kind: "Riunione",
                        title: "Roadmap Q4 · Sync settimanale",
                        rows: [
                            WelcomeSampleRow("checkmark.seal", "Decisioni", "Prima la modalità offline"),
                            WelcomeSampleRow("checklist", "Action item", "Giulia: piano di rilascio entro venerdì"),
                            WelcomeSampleRow("exclamationmark.triangle", "Rischi", "Sincronizzazione in ritardo"),
                        ]
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !setupLater.isEmpty {
                Label(laterText, systemImage: "arrow.right.circle")
                    .font(MPFont.callout(.medium))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var laterText: String {
        let names = setupLater.map { setup -> String in
            switch setup {
            case .notion: return "Notion"
            case .obsidian: return "Obsidian"
            case .summaryEngine: return localized("il modello della sintesi")
            }
        }
        return String(format: localized("Dopo: configura %@"), ListFormatter.localizedString(byJoining: names))
    }
}

private struct WelcomeSampleRow {
    let symbol: String
    let title: String
    let text: String
    /// Where the line comes from in the slides, shown as a link chip.
    var link: String? = nil

    init(_ symbol: String, _ title: String, _ text: String, link: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.link = link
    }
}

/// A miniature of the note the user will get, its sections arriving one by one. A
/// lecture's ends with its slides, kept in step with the transcript.
private struct WelcomeSampleNote: View {
    let kind: String
    let title: String
    let rows: [WelcomeSampleRow]
    var showsSlides = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    private var parts: Int { rows.count + (showsSlides ? 1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                MPBadge(text: kind, tone: .accent)
                MPBadge(text: "Sintesi", systemImage: "sparkles")
            }
            Text(localized(title))
                .font(MPFont.headline())
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.symbol)
                        .font(MPFont.caption(.semibold))
                        .foregroundStyle(MeetingPilotDesign.accent)
                        .frame(width: 16)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localized(row.title))
                            .font(MPFont.caption(.semibold))
                        HStack(spacing: 6) {
                            Text(localized(row.text))
                                .font(MPFont.caption())
                                .foregroundStyle(MeetingPilotDesign.textDimColor)
                                .fixedSize(horizontal: false, vertical: true)
                            if let link = row.link {
                                MPBadge(text: link, tone: .accent, systemImage: "link")
                            }
                        }
                    }
                }
                .modifier(WelcomeArrival(visible: index < shown))
            }
            if showsSlides {
                WelcomeSlideStrip()
                    .modifier(WelcomeArrival(visible: rows.count < shown))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mpCard(padding: 16)
        .onAppear {
            guard !reduceMotion else {
                shown = parts
                return
            }
            for index in 0..<parts {
                withAnimation(.mpSmooth.delay(0.25 + Double(index) * 0.18)) {
                    shown = index + 1
                }
            }
        }
    }
}

/// Fades and lifts a part into place as it arrives.
private struct WelcomeArrival: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
    }
}

/// The slides PDF beside the transcript, as in the Diary: the slide being discussed
/// lights up and its part of the transcript shows underneath. Still under Reduce Motion.
private struct WelcomeSlideStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let slides: [(title: String, quote: String)] = [
        ("Sistema e ambiente", "«Il sistema scambia calore e lavoro con l'ambiente…»"),
        ("Primo principio", "«L'energia interna si conserva…»"),
        ("Entropia", "«L'entropia misura il disordine…»"),
        ("Ciclo di Carnot", "«Due isoterme e due adiabatiche…»"),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.4)) { context in
            let current = reduceMotion
                ? slides.count - 1
                : Int(context.date.timeIntervalSinceReferenceDate / 1.4) % slides.count
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(MPFont.caption(.semibold))
                    .foregroundStyle(MeetingPilotDesign.accent)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("Trascrizione per slide"))
                        .font(MPFont.caption(.semibold))
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            ForEach(slides.indices, id: \.self) { index in
                                WelcomeSlidePage(number: index + 1, current: index == current)
                            }
                        }
                        Text(String(format: localized("Slide %d"), current + 1) + " · " + localized(slides[current].title))
                            .font(MPFont.caption(.semibold))
                            .foregroundStyle(MeetingPilotDesign.accent)
                            .lineLimit(1)
                            .id("title-\(current)")
                            .transition(.opacity)
                    }
                    Text(localized(slides[current].quote))
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .lineLimit(1)
                        .id("quote-\(current)")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.mpSmooth, value: current)
        }
    }
}

/// A page of the slides PDF in miniature.
private struct WelcomeSlidePage: View {
    let number: Int
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Capsule().fill(current ? MeetingPilotDesign.accent : MeetingPilotDesign.textFaintColor).frame(width: 12, height: 2)
            Capsule().fill(MeetingPilotDesign.lineStrongColor).frame(width: 16, height: 1.5)
            Capsule().fill(MeetingPilotDesign.lineStrongColor).frame(width: 10, height: 1.5)
        }
        .frame(width: 26, height: 18)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(current ? MeetingPilotDesign.accentTint : MeetingPilotDesign.hoverColor))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(current ? MeetingPilotDesign.accent : MeetingPilotDesign.lineColor, lineWidth: 1))
        .scaleEffect(current ? 1.12 : 1)
        .accessibilityLabel(String(format: localized("Slide %d"), number))
    }
}

// MARK: - Chat

private struct WelcomeChatPage: View {
    let profile: UserProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomePageHeader(
                eyebrow: "Chat",
                title: "Chiedi alle tue note",
                subtitle: "Fai una domanda: Meeting Pilot cerca tra lezioni e riunioni e risponde citando da dove viene ogni frase."
            )
            WelcomeChatDemo(example: profile.isStudent ? .student : .worker)
            Label(
                localized("Dalla barra laterale o dalla barra dei menu. Scegli corsi o progetti e temi per restringere la ricerca."),
                systemImage: "bubble.left.and.text.bubble.right"
            )
            .font(MPFont.callout())
            .foregroundStyle(MeetingPilotDesign.textFaintColor)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeChatExample {
    let filters: [(symbol: String, text: String)]
    let question: String
    /// Answer text, each part followed by the number of the source it cites.
    let answer: [(text: String, source: Int)]
    let sources: [(title: String, destination: String, symbol: String)]

    static let student = WelcomeChatExample(
        filters: [("folder", "Termodinamica"), ("tag", "Esame")],
        question: "Cosa ha detto il prof sull'esame?",
        answer: [("Ci sarà una domanda sul ciclo di Carnot", 1), ("e conviene ripassare il secondo principio", 2)],
        sources: [("Termodinamica · Lezione 3", "Diario", "book.pages"), ("Termodinamica · Lezione 4", "Notion", "doc.text")]
    )

    static let worker = WelcomeChatExample(
        filters: [("folder", "Atlas App"), ("tag", "Roadmap")],
        question: "Cosa abbiamo deciso sulla modalità offline?",
        answer: [("Arriva prima del connettore Salesforce", 1), ("e Giulia prepara il piano di rilascio entro venerdì", 2)],
        sources: [("Roadmap Q4 · Sync settimanale", "Diario", "book.pages"), ("Design review · Onboarding", "Notion", "doc.text")]
    )
}

/// A conversation playing out: the question, the model thinking, the answer with its
/// citations, then the sources they open. Shown complete under Reduce Motion.
private struct WelcomeChatDemo: View {
    let example: WelcomeChatExample
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 nothing, 1 question, 2 thinking, 3 answer, 4 and 5 each source.
    @State private var phase = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(example.filters, id: \.text) { filter in
                    MPBadge(text: filter.text, systemImage: filter.symbol)
                }
                Spacer()
            }
            HStack {
                Spacer(minLength: 80)
                Text(localized(example.question))
                    .font(MPFont.callout(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MeetingPilotDesign.accentTint))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MeetingPilotDesign.accent.opacity(0.35), lineWidth: 1))
            }
            .modifier(WelcomeArrival(visible: phase >= 1))

            ZStack(alignment: .leading) {
                if phase == 2 {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .symbolEffect(.pulse, options: .repeating)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
                        .transition(.opacity)
                }
                if phase >= 3 {
                    answer
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.trailing, 60)
            .frame(minHeight: 40, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(example.sources.enumerated()), id: \.offset) { index, source in
                    HStack(spacing: 8) {
                        WelcomeCitation(number: index + 1)
                        Text(localized(source.title))
                            .font(MPFont.caption(.semibold))
                        MPBadge(text: source.destination, systemImage: source.symbol)
                        Spacer()
                    }
                    .modifier(WelcomeArrival(visible: phase >= 4 + index))
                }
            }
        }
        .mpCard(padding: 16)
        .task {
            guard !reduceMotion else {
                phase = 5
                return
            }
            for (next, pause) in [(1, 0.35), (2, 0.6), (3, 1.1), (4, 0.45), (5, 0.25)] {
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.mpSmooth) { phase = next }
            }
        }
    }

    private var answer: some View {
        example.answer.enumerated().reduce(Text("")) { text, part in
            text
                + Text((part.offset > 0 ? " " : "") + localized(part.element.text) + " ")
                    .font(MPFont.callout())
                + Text("[\(part.element.source)]")
                    .font(MPFont.caption(.bold))
                    .foregroundColor(MeetingPilotDesign.accent)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The numbered citation the chat puts after a sentence and before its source.
private struct WelcomeCitation: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(MPFont.caption(.bold, design: .monospaced))
            .foregroundStyle(MeetingPilotDesign.accent)
            .frame(width: 18, height: 18)
            .background(Circle().fill(MeetingPilotDesign.accentTint))
    }
}

/// Wrapping row for example badges.
private struct WelcomeFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
