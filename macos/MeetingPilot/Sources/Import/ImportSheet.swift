import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lists the files to import, each with a title and the date it was recorded, before
/// they go to the inbox. Opened by `AppModel.importRequest`.
struct MediaImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var drafts: [MediaImportDraft] = []
    @State private var requested: [URL] = []
    /// PDFs chosen or dropped before the recording they belong to has been read.
    @State private var pendingSlides: [URL] = []
    @State private var loading = 0
    @State private var options = MediaImportOptions()
    @State private var dropTargeted = false

    /// `drafts` lets the debug snapshots show the sheet without reading real files.
    init(drafts: [MediaImportDraft] = []) {
        _drafts = State(initialValue: drafts)
    }

    private var importable: [MediaImportDraft] { drafts.filter(\.canImport) }

    private var templateOptions: [SummaryTemplateOption] {
        SummaryTemplateCatalog.options(custom: model.customSummaryTemplates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(MPFont.headline())
                    .foregroundStyle(MeetingPilotDesign.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(MeetingPilotDesign.accentTint))
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Importa registrazioni"))
                        .font(.mpDisplay(18))
                    Text(localized("Lezioni, podcast o registrazioni fatte altrove diventano note come le tue riunioni."))
                        .font(MPFont.callout())
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($drafts) { $draft in
                        MediaImportRow(draft: $draft, chooseSlides: model.chooseSlidesPDF) {
                            drafts.removeAll { $0.id == draft.id }
                        }
                    }
                    if !pendingSlides.isEmpty && loading == 0 {
                        Label(
                            localized("Slide in attesa della registrazione") + ": "
                                + pendingSlides.map(\.lastPathComponent).joined(separator: ", "),
                            systemImage: "doc.richtext"
                        )
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                    if loading > 0 {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(localized("Lettura dei file…"))
                                .font(MPFont.callout())
                                .foregroundStyle(MeetingPilotDesign.textDimColor)
                            Spacer()
                        }
                        .padding(12)
                    }
                    if drafts.isEmpty && loading == 0 {
                        Text(localized("Trascina qui i file o scegline altri."))
                            .font(MPFont.callout())
                            .foregroundStyle(MeetingPilotDesign.textFaintColor)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 380)
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous)
                    .strokeBorder(MeetingPilotDesign.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .opacity(dropTargeted ? 1 : 0)
            )

            HStack(spacing: 10) {
                Button {
                    model.chooseFilesToImport()
                } label: {
                    Label(localized("Aggiungi file…"), systemImage: "plus")
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))

                if model.userProfile == .both {
                    profileMenu
                }
                Menu {
                    ForEach(templateOptions) { option in
                        Button {
                            options.template = option.id
                        } label: {
                            if option.id == options.template {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                } label: {
                    Label(
                        localized("Modello di sintesi") + ": " + SummaryTemplateCatalog.name(for: options.template, custom: model.customSummaryTemplates),
                        systemImage: "doc.text"
                    )
                        .font(MPFont.callout(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(localized("Modello di sintesi per i file importati"))
                Spacer()
            }

            if !model.watcher.watcherActive {
                Label(
                    localized("Il rilevamento automatico è in pausa: i file verranno trascritti quando lo riattivi."),
                    systemImage: "pause.circle"
                )
                .font(MPFont.caption())
                .foregroundStyle(MeetingPilotDesign.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                Button(localized("Annulla")) {
                    model.importRequest = nil
                }
                .buttonStyle(MPSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button {
                    model.importMedia(importable, options: options)
                } label: {
                    Label(importButtonTitle, systemImage: "square.and.arrow.down")
                }
                .buttonStyle(MPPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(importable.isEmpty || loading > 0)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(MeetingPilotBackdrop())
        .foregroundStyle(MeetingPilotDesign.textColor)
        .tint(MeetingPilotDesign.accent)
        .onAppear { load(model.importRequest?.urls ?? []) }
        .onChange(of: model.importRequest?.urls ?? []) { _, urls in load(urls) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedFiles(providers) { model.requestImport($0) }
            return true
        }
    }

    /// The same choice as in the live sidebar, for someone who both studies and works.
    private static let profileOptions: [(choice: UserProfile?, title: String, symbol: String)] = [
        (nil, "Dal titolo", "sparkles"),
        (.worker, "Riunione di lavoro", "briefcase"),
        (.student, "Lezione", "graduationcap"),
    ]

    private var profileMenu: some View {
        let current = Self.profileOptions.first { $0.choice == options.profile } ?? Self.profileOptions[0]
        return Menu {
            ForEach(Self.profileOptions, id: \.title) { option in
                Button {
                    options.profile = option.choice
                } label: {
                    if option.choice == options.profile {
                        Label(localized(option.title), systemImage: "checkmark")
                    } else {
                        Label(localized(option.title), systemImage: option.symbol)
                    }
                }
            }
        } label: {
            Label(localized("Tipo di nota") + ": " + localized(current.title), systemImage: current.symbol)
                .font(MPFont.callout(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var importButtonTitle: String {
        importable.count == 1
            ? localized("Importa")
            : String(format: localized("Importa %d file"), importable.count)
    }

    /// Reads each new file once; drafts keep the order the files were chosen in. PDFs
    /// are slides for the recordings, attached once every recording has been read.
    private func load(_ urls: [URL]) {
        let new = urls.filter { !requested.contains($0) }
        guard !new.isEmpty else { return }
        requested += new
        pendingSlides += new.filter(MediaImportInspector.isSlides)
        let media = new.filter { !MediaImportInspector.isSlides($0) }
        loading += media.count
        attachPendingSlides()
        let history = model.importer.history
        for url in media {
            Task {
                let draft = await MediaImportInspector.draft(for: url, history: history)
                drafts.append(draft)
                drafts.sort { (requested.firstIndex(of: $0.sourceURL) ?? 0) < (requested.firstIndex(of: $1.sourceURL) ?? 0) }
                loading -= 1
                attachPendingSlides()
            }
        }
    }

    private func attachPendingSlides() {
        guard loading == 0 else { return }
        while let pdf = pendingSlides.first {
            let candidates = drafts.filter { $0.slidesURL == nil && $0.canImport }
            guard let match = SlideDeck.bestMatch(for: pdf, among: candidates),
                  let index = drafts.firstIndex(where: { $0.id == match.id })
            else { return }
            drafts[index].slidesURL = pdf
            pendingSlides.removeFirst()
        }
    }
}

private struct MediaImportRow: View {
    @Binding var draft: MediaImportDraft
    let chooseSlides: () -> URL?
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: draft.isVideo ? "film" : "waveform")
                .font(MPFont.body(.medium))
                .foregroundStyle(draft.canImport ? MeetingPilotDesign.accent : MeetingPilotDesign.warning)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).fill(MeetingPilotDesign.accentTint))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(draft.fileName)
                        .font(MPFont.callout(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let duration = draft.durationSeconds {
                        Text(importDurationText(duration))
                            .font(MPFont.caption(design: .monospaced))
                            .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    }
                }
                if let problem = draft.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        TextField(localized("Titolo scelto dalla sintesi"), text: $draft.title)
                            .textFieldStyle(DarkTextFieldStyle())
                            .help(localized("Lascia vuoto per usare il titolo generato con la sintesi"))
                        DatePicker("", selection: $draft.recordedAt, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .fixedSize()
                            .help(localized("Quando è stata registrata: la nota finisce in questo giorno del Diario"))
                    }
                    slidesLine
                    if let previous = draft.previouslyImportedAt {
                        Label(
                            localized("Già importato il") + " "
                                + previous.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.warning)
                    }
                }
            }

            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MPIconButtonStyle(size: 26))
            .help(localized("Togli dall'importazione"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }
}

private extension MediaImportRow {
    @ViewBuilder
    var slidesLine: some View {
        HStack(spacing: 6) {
            if let slides = draft.slidesURL {
                Label(slides.lastPathComponent, systemImage: "doc.richtext")
                    .font(MPFont.caption(.medium))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    draft.slidesURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                .help(localized("Togli le slide"))
            } else {
                Button {
                    if let url = chooseSlides() { draft.slidesURL = url }
                } label: {
                    Label(localized("Aggiungi slide PDF…"), systemImage: "doc.richtext")
                        .font(MPFont.caption(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MeetingPilotDesign.accent)
                .help(localized("Le slide vengono affiancate alla trascrizione e guidano la sintesi"))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shown in the dashboard while files are copied or their audio extracted; once in the
/// inbox they show up in the pipeline like any recording.
struct MediaImportProgressCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MPSectionTitle("Importazione")
            ForEach(model.importer.jobs) { job in
                HStack(spacing: 10) {
                    Image(systemName: job.failure == nil ? "square.and.arrow.down" : "exclamationmark.triangle")
                        .foregroundStyle(job.failure == nil ? MeetingPilotDesign.accent : MeetingPilotDesign.warning)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name)
                            .font(MPFont.callout(.medium))
                            .lineLimit(1)
                        if let failure = job.failure {
                            Text(failure)
                                .font(MPFont.caption())
                                .foregroundStyle(MeetingPilotDesign.textDimColor)
                                .lineLimit(2)
                        } else {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                        }
                    }
                    if job.failure != nil {
                        Button {
                            model.importer.dismiss(job)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(MPIconButtonStyle(size: 26))
                        .help(localized("Nascondi"))
                    }
                }
            }
        }
        .mpCard(padding: 14)
    }
}

/// Dropping files anywhere on the main window opens the import sheet with them.
struct MediaImportDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: MPRadius.window, style: .continuous)
                            .fill(MeetingPilotDesign.canvasColor.opacity(0.75))
                        RoundedRectangle(cornerRadius: MPRadius.window, style: .continuous)
                            .strokeBorder(MeetingPilotDesign.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        Label(localized("Rilascia per importare"), systemImage: "square.and.arrow.down")
                            .font(MPFont.headline())
                            .foregroundStyle(MeetingPilotDesign.accent)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                loadDroppedFiles(providers) { model.requestImport($0) }
                return true
            }
    }
}

/// File URLs from a drop, delivered together on the main thread.
func loadDroppedFiles(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        if !urls.isEmpty { completion(urls) }
    }
}

func importDurationText(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    let hours = minutes / 60
    return hours > 0 ? String(format: "%d h %02d min", hours, minutes % 60) : "\(max(minutes, 1)) min"
}
