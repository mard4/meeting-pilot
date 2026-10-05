import AppKit
import SwiftUI

/// Standalone Diary window: the same browser as the Diario section, without app chrome.
struct DiaryNotebookView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MPPageHeader(title: "Diario", eyebrow: "Note delle riunioni")
            JournalBrowser()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MeetingPilotBackdrop())
        .foregroundStyle(MeetingPilotDesign.textColor)
        .tint(MeetingPilotDesign.accent)
    }
}

struct JournalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reloadToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MPPageHeader(title: "Diario", subtitle: "Le note delle riunioni, in Markdown sul tuo Mac.") {
                HStack(spacing: 8) {
                    Button {
                        model.showDiaryWindow()
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .buttonStyle(MPIconButtonStyle(size: 32))
                    .help("Apri il Diario in una finestra")

                    Button {
                        model.openJournal(at: model.journalRoot)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(MPIconButtonStyle(size: 32))
                    .help("Mostra la cartella del Diario nel Finder")

                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(MPIconButtonStyle(size: 32))
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Aggiorna le pagine del Diario (⌘R)")
                }
            }
            JournalBrowser(reloadToken: reloadToken)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct JournalBrowser: View {
    @EnvironmentObject private var model: AppModel
    var reloadToken = 0
    @State private var root = ""
    @State private var documents: [JournalDocument] = []
    @State private var selectedDocument: JournalDocument?
    @State private var documentText = ""
    @State private var isEditing = false
    @State private var documentStatus = ""
    @State private var loadFailed = false
    @State private var query = ""

    private var filteredDocuments: [JournalDocument] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return documents }
        return documents.filter { $0.searchText.localizedCaseInsensitiveContains(needle) }
    }

    private var monthSections: [(title: String, documents: [JournalDocument])] {
        var sections: [(title: String, documents: [JournalDocument])] = []
        for document in filteredDocuments {
            let title = journalMonthText(document.date)
            if sections.last?.title == title {
                sections[sections.count - 1].documents.append(document)
            } else {
                sections.append((title, [document]))
            }
        }
        return sections
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(MPFont.caption(.semibold))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    TextField(localized("Cerca nelle note"), text: $query)
                        .textFieldStyle(.plain)
                        .font(MPFont.callout())
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        }
                        .buttonStyle(.plain)
                        .help("Cancella ricerca")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).fill(MeetingPilotDesign.fieldColor))
                .overlay(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if documents.isEmpty {
                            Text(localized("Nessuna pagina ancora. Le nuove sintesi appariranno qui quando il Diario viene usato come fallback o destinazione."))
                                .font(MPFont.callout())
                                .foregroundStyle(MeetingPilotDesign.textDimColor)
                                .padding(8)
                        } else if filteredDocuments.isEmpty {
                            Text(localized("Nessuna pagina trovata"))
                                .font(MPFont.callout())
                                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                                .padding(8)
                        }
                        ForEach(monthSections, id: \.title) { section in
                            HStack {
                                MPEyebrow(section.title)
                                Spacer()
                                Text("\(section.documents.count)")
                                    .font(MPFont.micro(.semibold, design: .monospaced))
                                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, section.title == monthSections.first?.title ? 2 : 12)
                            .padding(.bottom, 4)
                            ForEach(section.documents) { document in
                                JournalDocumentRow(document: document, selected: selectedDocument == document) {
                                    select(document)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 260)
            .frame(maxHeight: .infinity, alignment: .top)
            .mpCard(padding: 10)

            VStack(alignment: .leading, spacing: 0) {
                if let selectedDocument {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            MPEyebrow(journalLongDateText(selectedDocument), color: MeetingPilotDesign.accent)
                            Text(localized("Modificata") + " " + journalDateText(selectedDocument.modifiedAt))
                                .font(MPFont.caption(design: .monospaced))
                                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !documentStatus.isEmpty {
                            MPBadge(text: documentStatus, tone: documentStatus == "Salvato" ? .success : .warning)
                        }
                        if isEditing {
                            Button {
                                saveSelectedDocument()
                            } label: {
                                Label(localized("Salva"), systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(MPPrimaryButtonStyle(compact: true))
                            .keyboardShortcut("s", modifiers: .command)
                            .help("Salva modifiche (⌘S)")
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([selectedDocument.url])
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(MPIconButtonStyle(size: 28))
                        .help("Mostra la pagina nel Finder")
                        Picker("Vista", selection: $isEditing) {
                            Image(systemName: "eye").tag(false).help("Leggi")
                            Image(systemName: "pencil").tag(true).help("Modifica")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 96)
                        .disabled(loadFailed)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)

                    Group {
                        if isEditing {
                            TextEditor(text: $documentText)
                                .font(MPFont.body(design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(12)
                        } else {
                            JournalNoteReader(document: selectedDocument, text: documentText)
                                .id(selectedDocument.id)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(MPFont.hero())
                            .foregroundStyle(MeetingPilotDesign.accent)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(MeetingPilotDesign.accentTint))
                        Text(localized("Seleziona una pagina per leggerla o modificarla."))
                            .font(MPFont.body())
                            .foregroundStyle(MeetingPilotDesign.textDimColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.card, style: .continuous)
                    .fill(MeetingPilotDesign.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.card, style: .continuous)
                    .strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1)
            )
        }
        .frame(minHeight: 420, maxHeight: .infinity)
        .onAppear {
            root = model.journalRoot
            refreshDocuments()
        }
        .onChange(of: reloadToken) { _, _ in refreshDocuments() }
    }

    private func refreshDocuments() {
        let targetRoot = root
        DispatchQueue.global(qos: .utility).async {
            let loadedDocuments = journalDocuments(at: targetRoot)
            DispatchQueue.main.async {
                guard self.root == targetRoot else { return }
                self.documents = loadedDocuments
                if let selectedDocument = self.selectedDocument {
                    if let refreshed = loadedDocuments.first(where: { $0 == selectedDocument }) {
                        // Same file, fresher metadata (title, summary) after a save.
                        self.selectedDocument = refreshed
                    } else {
                        self.selectedDocument = nil
                        self.documentText = ""
                    }
                }
                if self.selectedDocument == nil, let newest = loadedDocuments.first {
                    self.select(newest)
                }
            }
        }
    }

    private func select(_ document: JournalDocument) {
        selectedDocument = document
        isEditing = false
        do {
            documentText = try String(contentsOf: document.url, encoding: .utf8)
            documentStatus = ""
            loadFailed = false
        } catch {
            // Keep the editor empty but refuse to save it, or an unreadable note
            // would be overwritten with nothing.
            documentText = ""
            documentStatus = "Errore lettura: \(error.localizedDescription)"
            loadFailed = true
            AppLog.append("Lettura nota del Diario non riuscita (\(document.url.path)): \(error.localizedDescription)")
        }
    }

    private func saveSelectedDocument() {
        guard let selectedDocument, !loadFailed else { return }
        do {
            try documentText.write(to: selectedDocument.url, atomically: true, encoding: .utf8)
            documentStatus = "Salvato"
            refreshDocuments()
        } catch {
            documentStatus = "Errore salvataggio: \(error.localizedDescription)"
            AppLog.append("Salvataggio nota del Diario non riuscito (\(selectedDocument.url.path)): \(error.localizedDescription)")
        }
    }
}

private struct JournalDocumentRow: View {
    let document: JournalDocument
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(MPFont.body(selected ? .semibold : .medium))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(journalShortDateText(document))
                        .font(MPFont.footnote(design: .monospaced))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    if let project = document.project {
                        Text(project)
                            .font(MPFont.footnote(.semibold))
                            .foregroundStyle(MeetingPilotDesign.accent)
                            .lineLimit(1)
                    }
                }
                if let snippet = document.snippet {
                    Text(snippet)
                        .font(MPFont.callout())
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous)
                    .fill(selected ? MeetingPilotDesign.accentTint : (hovering ? MeetingPilotDesign.hoverColor : .clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(MeetingPilotDesign.accent).frame(width: 3, height: 18).offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PublicationTargetsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentPane(title: "Connettori", subtitle: "Scegli dove pubblicare le note di ogni riunione. Puoi attivarne più di uno.") {
            VStack(spacing: 10) {
                PublicationDestinationCard(
                    title: "Notion",
                    assetName: "Notion_app_logo.png",
                    fallbackSymbol: "doc.text",
                    lightIconBackground: true,
                    status: model.notion.occurrencesDatabaseId.isEmpty ? "Non collegato" : "Collegato",
                    isConnected: !model.notion.occurrencesDatabaseId.isEmpty,
                    target: "notion",
                    subtitle: "Database nel tuo workspace Notion"
                ) {
                    NotionConfigurationForm()
                }
                PublicationDestinationCard(
                    title: "Obsidian",
                    assetName: "2023_Obsidian_logo.svg",
                    fallbackSymbol: "book.closed.fill",
                    status: model.obsidianVaultPath.isEmpty ? "Non collegato" : "Collegato",
                    isConnected: !model.obsidianVaultPath.isEmpty,
                    target: "obsidian",
                    subtitle: "Note Markdown nel tuo vault"
                ) {
                    ObsidianConfigurationForm()
                }
                PublicationDestinationCard(
                    title: "Apple Notes",
                    assetName: "apple_notes_logo.png",
                    fallbackSymbol: "note.text",
                    status: model.publicationTargets.contains("apple_notes") ? "Attivo" : "Non collegato",
                    isConnected: model.publicationTargets.contains("apple_notes"),
                    target: "apple_notes",
                    subtitle: "Una nota per riunione nell'app Note"
                ) {
                    AppleNotesConfigurationForm()
                }
                PublicationDestinationCard(
                    title: "Diario locale",
                    fallbackSymbol: "book.pages",
                    status: model.publicationTargets.contains("journal") ? "Attivo" : "Disattivato",
                    isConnected: model.publicationTargets.contains("journal"),
                    target: "journal",
                    subtitle: "Pagine Markdown con ricerca e cronologia"
                ) {
                    Text(localized("Ogni riunione diventa una pagina Markdown nella cartella del Diario. L'indice di ricerca si rigenera da solo."))
                        .font(MPFont.callout())
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                MPSectionTitle("Sezioni pagina", detail: "Condivise da tutte le destinazioni.")
                PageSectionsCard()
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 10) {
                MPSectionTitle("Audio", detail: "Cosa succede alla registrazione dopo la pubblicazione.")
                AudioRetentionCard()
            }
            .padding(.top, 14)
        }
    }
}

/// Reading view for a Diary page: the YAML front matter becomes a header with
/// badges instead of raw `key: "value"` lines.
struct JournalNoteReader: View {
    let document: JournalDocument
    let text: String
    /// The slide shown beside a page that has slides, chosen in either pane.
    @State private var selectedSlide: Int?

    var body: some View {
        let note = parseJournalNote(text)
        if let slides = journalSlidesURL(for: note, document: document) {
            // Side by side only where both stay readable; a narrow window keeps the page
            // and opens the slides from the header instead.
            GeometryReader { geometry in
                if geometry.size.width >= 640 {
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            reader(note)
                            Rectangle().fill(MeetingPilotDesign.lineColor).frame(width: 1)
                            JournalSlidesPane(url: slides, page: selectedSlide) { page in
                                // Paging through the slides brings their part of the transcript into view.
                                selectedSlide = page
                                withAnimation(.mpSmooth) { proxy.scrollTo("slide-\(page)", anchor: .top) }
                            }
                            .frame(width: min(520, max(240, geometry.size.width * 0.42)))
                        }
                    }
                } else {
                    reader(note)
                }
            }
        } else {
            reader(note)
        }
    }

    private func reader(_ note: JournalNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(note)
                Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)
                MarkdownReader(
                    text: note.body,
                    hiddenTitle: note.meta["title"] ?? document.title,
                    selectedSlide: selectedSlide,
                    onSelectSlide: { selectedSlide = $0 }
                )
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func header(_ note: JournalNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.title)
                .font(.mpDisplay(22))
                .foregroundStyle(MeetingPilotDesign.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            JournalFlowLayout(spacing: 6) {
                if document.hasTime {
                    MPBadge(text: journalTimeText(document.date), systemImage: "clock")
                }
                if let project = document.project {
                    MPBadge(text: project, tone: .accent, systemImage: "folder")
                }
                if let theme = document.theme {
                    MPBadge(text: theme, systemImage: "tag")
                }
                if let duration = note.value("duration") {
                    MPBadge(text: duration, systemImage: "timer")
                }
                if let source = note.value("source") {
                    // Calls come from Teams; anything else was imported from a file.
                    MPBadge(text: source, systemImage: source == "Teams" ? "video" : "square.and.arrow.down")
                }
            }

            if let participants = note.value("participants") {
                Label(participants, systemImage: "person.2")
                    .font(MPFont.callout())
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                let engines = [note.value("model"), note.value("transcription_provider").map(journalTranscriptionLabel)]
                    .compactMap { $0 }
                if !engines.isEmpty {
                    Label(engines.joined(separator: " · "), systemImage: "cpu")
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                }
                Spacer(minLength: 0)
                if let slides = journalSlidesURL(for: note, document: document) {
                    Button {
                        NSWorkspace.shared.open(slides)
                    } label: {
                        Label(localized("Slide"), systemImage: "doc.richtext")
                    }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
                    .help("Apri le slide in Anteprima")
                }
                if let originalPath = note.value("original_path"), FileManager.default.fileExists(atPath: originalPath) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: originalPath)])
                    } label: {
                        Label(localized("File originale"), systemImage: "film")
                    }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
                    .help("Mostra nel Finder il video o l'audio importato")
                }
                if let audioPath = note.value("audio_path"), FileManager.default.fileExists(atPath: audioPath) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: audioPath)])
                    } label: {
                        Label(localized("Registrazione"), systemImage: "waveform")
                    }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
                    .help("Mostra la registrazione nel Finder")
                }
            }
        }
    }
}

struct MarkdownReader: View {
    let text: String
    /// The page's own `# Title` repeats the header above it, so it is skipped.
    var hiddenTitle: String? = nil
    /// For a transcript grouped by slide: the slide shown beside it, and what choosing
    /// one of its parts does.
    var selectedSlide: Int? = nil
    var onSelectSlide: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parseContent(text).enumerated()), id: \.offset) { _, element in
                renderElement(element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func renderElement(_ element: ContentElement) -> some View {
        switch element {
        case .heading1(let text):
            Text(text).font(.mpDisplay(20)).padding(.top, 4)
        case .heading2(let text):
            Text(text).font(MPFont.title()).foregroundStyle(MeetingPilotDesign.textColor).padding(.top, 12)
        case .heading3(let text):
            MPEyebrow(text, color: MeetingPilotDesign.accent).padding(.top, 8)
        case .paragraph(let text):
            Text(inlineMarkdown(text)).font(MPFont.body()).foregroundStyle(MeetingPilotDesign.textDimColor).lineSpacing(3)
                .frame(maxWidth: 680, alignment: .leading)
        case .keyValue(let key, let value):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key)
                    .font(MPFont.callout(.medium))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    .frame(width: 110, alignment: .leading)
                Text(inlineMarkdown(journalReadableValue(value)))
                    .font(MPFont.body())
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        case .bullet(let text):
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(MeetingPilotDesign.accent).frame(width: 5, height: 5).padding(.top, 7)
                Text(inlineMarkdown(text)).font(MPFont.body()).lineSpacing(3)
                    .frame(maxWidth: 680, alignment: .leading)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number)
                    .font(MPFont.callout(.semibold, design: .monospaced))
                    .foregroundStyle(MeetingPilotDesign.accent)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inlineMarkdown(text)).font(MPFont.body()).lineSpacing(3)
                    .frame(maxWidth: 680, alignment: .leading)
            }
        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? MeetingPilotDesign.success : MeetingPilotDesign.textFaintColor)
                Text(inlineMarkdown(readableDueDates(text))).font(MPFont.body()).lineSpacing(3)
                    .strikethrough(done, color: MeetingPilotDesign.textFaintColor)
                    .foregroundStyle(done ? MeetingPilotDesign.textDimColor : MeetingPilotDesign.textColor)
                    .frame(maxWidth: 680, alignment: .leading)
            }
        case .quote(let text):
            HStack(spacing: 10) {
                Capsule().fill(MeetingPilotDesign.accent.opacity(0.6)).frame(width: 3)
                Text(inlineMarkdown(text)).font(MPFont.body()).italic()
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .frame(maxWidth: 660, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(MPFont.callout(design: .monospaced))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .padding(12)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).fill(MeetingPilotDesign.fieldColor))
            .overlay(RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
        case .transcript(let lines):
            TranscriptBlock(lines: lines)
        case .slideTranscript(let page, let title, let lines, let anchor):
            let block = SlideTranscriptBlock(
                page: page,
                title: title,
                lines: lines,
                selected: selectedSlide == page,
                onSelect: onSelectSlide.map { select in { select(page) } }
            )
            // The first part spoken on a slide is where paging to it scrolls.
            if anchor {
                block.id("slide-\(page)")
            } else {
                block
            }
        case .callout(let kind, let title, let content):
            JournalCallout(kind: kind, title: title, content: content)
        case .divider:
            Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1).padding(.vertical, 6)
        }
    }

    private func parseContent(_ text: String) -> [ContentElement] {
        var elements: [ContentElement] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var codeLines: [String]?
        var inTranscriptSection = false
        var skippedTitle = false
        var anchoredSlides: Set<Int> = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if codeLines == nil, let header = calloutHeader(line) {
                var content: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    content.append(unquoted(lines[index]))
                    index += 1
                }
                if header.kind == "slide", let page = slideNumber(header.title) {
                    // Obsidian copies of the page link each part to its slide: `[[slides.pdf#page=3|…]]`.
                    let turns = content
                        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[[") }
                        .map { $0.replacingOccurrences(of: "**", with: "") }
                    let title = header.title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                    elements.append(.slideTranscript(
                        page: page,
                        title: title.isEmpty ? header.title : title,
                        lines: transcriptLines(turns),
                        anchor: anchoredSlides.insert(page).inserted
                    ))
                } else if header.kind == "quote", isTranscriptHeading(header.title) {
                    let turns = content.map { $0.replacingOccurrences(of: "**", with: "") }
                    elements.append(.heading2(header.title))
                    elements.append(.transcript(transcriptLines(turns)))
                } else {
                    elements.append(.callout(header.kind, header.title, content.joined(separator: "\n")))
                }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let block = codeLines {
                    elements.append(inTranscriptSection ? .transcript(transcriptLines(block)) : .code(block.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }
            let cleaned = stripHTML(line).trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }

            if cleaned.hasPrefix("# ") {
                let title = String(cleaned.dropFirst(2))
                if !skippedTitle, let hiddenTitle, title.trimmingCharacters(in: .whitespaces) == hiddenTitle {
                    skippedTitle = true
                    continue
                }
                elements.append(.heading1(title))
            } else if cleaned.hasPrefix("## ") {
                let heading = String(cleaned.dropFirst(3))
                inTranscriptSection = isTranscriptHeading(heading)
                elements.append(.heading2(heading))
            } else if cleaned.hasPrefix("### ") {
                elements.append(.heading3(String(cleaned.dropFirst(4))))
            } else if let task = taskItem(cleaned) {
                elements.append(task)
            } else if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") {
                elements.append(.bullet(String(cleaned.dropFirst(2))))
            } else if let numbered = numberedItem(cleaned) {
                elements.append(numbered)
            } else if cleaned.hasPrefix("> ") {
                elements.append(.quote(String(cleaned.dropFirst(2))))
            } else if cleaned == "---" || cleaned == "***" {
                elements.append(.divider)
            } else if let pair = keyValue(cleaned) {
                elements.append(.keyValue(pair.key, pair.value))
            } else {
                elements.append(.paragraph(cleaned))
            }
        }
        if let block = codeLines, !block.isEmpty {
            elements.append(inTranscriptSection ? .transcript(transcriptLines(block)) : .code(block.joined(separator: "\n")))
        }
        return elements
    }

    /// Obsidian callouts: `> [!warning] Title`, optionally foldable with `+` or `-`.
    private func calloutHeader(_ line: String) -> (kind: String, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.range(of: #"^> ?\[![A-Za-z-]+\][+-]?"#, options: .regularExpression) else { return nil }
        let marker = trimmed[match]
        guard let open = marker.range(of: "[!"), let close = marker.range(of: "]") else { return nil }
        let kind = marker[open.upperBound..<close.lowerBound].lowercased()
        let title = trimmed[match.upperBound...].trimmingCharacters(in: .whitespaces)
        return (kind, title)
    }

    private func unquoted(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces).dropFirst()
        if text.hasPrefix(" ") { text = text.dropFirst() }
        return String(text)
    }

    /// Tasks carry Obsidian Tasks due dates ("📅 2026-10-03"); show them as a local date.
    private func readableDueDates(_ text: String) -> String {
        guard let match = text.range(of: #"📅 \d{4}-\d{2}-\d{2}"#, options: .regularExpression),
              let date = parseDay(String(text[match].dropFirst(2))) else { return text }
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return text.replacingCharacters(in: match, with: "📅 " + formatter.string(from: date))
    }

    /// "Slide 3 · Entropia", "Folie 3 · …": the first number is the page.
    private func slideNumber(_ title: String) -> Int? {
        title.range(of: #"\d+"#, options: .regularExpression).flatMap { Int(title[$0]) }
    }

    private func isTranscriptHeading(_ heading: String) -> Bool {
        let lowered = heading.lowercased()
        return lowered.contains("transcript") || lowered.contains("trascrizion")
    }

    private func transcriptLines(_ block: [String]) -> [String] {
        block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func taskItem(_ line: String) -> ContentElement? {
        for prefix in ["- [ ] ", "* [ ] "] where line.hasPrefix(prefix) {
            return .task(false, String(line.dropFirst(prefix.count)))
        }
        for prefix in ["- [x] ", "- [X] ", "* [x] ", "* [X] "] where line.hasPrefix(prefix) {
            return .task(true, String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    private func numberedItem(_ line: String) -> ContentElement? {
        guard let match = line.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) else { return nil }
        let number = line[match].trimmingCharacters(in: .whitespaces)
        return .numbered(number, String(line[match.upperBound...]))
    }

    /// Short "Label: value" lines (the Overview block) read better as a table.
    private func keyValue(_ line: String) -> (key: String, value: String)? {
        guard line.range(of: #"^[\p{L}][\p{L} ]{1,23}: \S"#, options: .regularExpression) != nil,
              let separator = line.range(of: ": ") else { return nil }
        return (String(line[..<separator.lowerBound]), String(line[separator.upperBound...]))
    }

    /// Inline Markdown keeps links (e.g. the archived recording) clickable.
    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// The full transcript is long and rarely re-read: collapsed by default,
/// with speakers set apart from what they said.
private struct TranscriptBlock: View {
    let lines: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.mpSnappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(MeetingPilotDesign.accent)
                    Text(localized(expanded ? "Nascondi trascrizione" : "Mostra trascrizione"))
                        .font(MPFont.callout(.medium))
                        .foregroundStyle(MeetingPilotDesign.textColor)
                    Spacer()
                    Text("\(lines.count) " + localized(lines.count == 1 ? "intervento" : "interventi"))
                        .font(MPFont.caption(design: .monospaced))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    Image(systemName: "chevron.down")
                        .font(MPFont.caption(.semibold))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let turn = transcriptTurn(line)
                        VStack(alignment: .leading, spacing: 2) {
                            if let speaker = turn.speaker {
                                Text(speaker)
                                    .font(MPFont.caption(.semibold))
                                    .foregroundStyle(MeetingPilotDesign.accent)
                            }
                            Text(turn.text)
                                .font(MPFont.body())
                                .foregroundStyle(MeetingPilotDesign.textColor)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).fill(MeetingPilotDesign.fieldColor))
        .overlay(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }

}

/// "Name: what they said", with names short enough not to be a sentence with a colon.
func transcriptTurn(_ line: String) -> (speaker: String?, text: String) {
    if let separator = line.range(of: ": "), line.distance(from: line.startIndex, to: separator.lowerBound) <= 32 {
        return (String(line[..<separator.lowerBound]), String(line[separator.upperBound...]))
    }
    return (nil, line)
}

enum ContentElement {
    case heading1(String)
    case heading2(String)
    case heading3(String)
    case paragraph(String)
    case keyValue(String, String)
    case bullet(String)
    case numbered(String, String)
    case task(Bool, String)
    case quote(String)
    case code(String)
    case transcript([String])
    case slideTranscript(page: Int, title: String, lines: [String], anchor: Bool)
    case callout(String, String, String)
    case divider
}

/// Obsidian callouts (open questions, risks, notes) as tinted cards.
private struct JournalCallout: View {
    let kind: String
    let title: String
    let content: String

    var body: some View {
        let style = Self.style(for: kind)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(MPFont.callout(.semibold))
            } icon: {
                Image(systemName: style.icon)
            }
            .foregroundStyle(style.tone.color)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownReader(text: content)
            }
        }
        .padding(14)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).fill(style.tone.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).strokeBorder(style.tone.color.opacity(0.22), lineWidth: 1))
    }

    private static func style(for kind: String) -> (tone: MPTone, icon: String) {
        switch kind {
        case "warning", "caution", "attention", "danger", "error", "bug", "failure", "fail", "missing":
            return (.accent, "exclamationmark.triangle")
        case "question", "help", "faq":
            return (.warning, "questionmark.circle")
        case "success", "check", "done", "tip", "hint", "important":
            return (.success, "checkmark.circle")
        case "note":
            return (.neutral, "pencil")
        case "info", "todo", "abstract", "summary", "tldr":
            return (.neutral, "info.circle")
        default:
            return (.neutral, "text.quote")
        }
    }
}

/// Wrapping row for header badges.
private struct JournalFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

// MARK: - Diary pages

struct JournalDocument: Identifiable, Hashable {
    let url: URL
    let title: String
    /// Meeting start when known, otherwise the page date or file date.
    let date: Date
    let hasTime: Bool
    let modifiedAt: Date
    let project: String?
    let theme: String?
    let snippet: String?
    let searchText: String

    var id: String { url.path }

    // Identity is the file: a refreshed page (new summary, new title) stays selected.
    static func == (lhs: JournalDocument, rhs: JournalDocument) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct JournalNote {
    var meta: [String: String]
    var body: String

    func value(_ key: String) -> String? {
        guard let value = meta[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

func parseJournalNote(_ text: String) -> JournalNote {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
    else { return JournalNote(meta: [:], body: text) }

    var meta: [String: String] = [:]
    var listKey: String?
    for line in lines[1..<end] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- "), let key = listKey {
            let item = yamlScalar(String(trimmed.dropFirst(2)))
            meta[key] = [meta[key], item].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
            continue
        }
        guard let separator = line.range(of: ":") else { continue }
        let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = yamlScalar(line[separator.upperBound...].trimmingCharacters(in: .whitespaces))
        meta[key] = value
        listKey = value.isEmpty ? key : nil
    }
    return JournalNote(meta: meta, body: lines[(end + 1)...].joined(separator: "\n"))
}

private func yamlScalar(_ raw: String) -> String {
    guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
    return String(raw.dropFirst().dropLast())
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

func journalDocuments(at root: String) -> [JournalDocument] {
    let expanded = NSString(string: root).expandingTildeInPath
    let directory = URL(fileURLWithPath: expanded, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension.lowercased() == "md" else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let modifiedAt = values?.contentModificationDate ?? .distantPast
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return journalDocument(url: url, text: text, modifiedAt: modifiedAt)
    }
    .sorted { $0.date == $1.date ? $0.modifiedAt > $1.modifiedAt : $0.date > $1.date }
}

private func journalDocument(url: URL, text: String, modifiedAt: Date) -> JournalDocument {
    let note = parseJournalNote(text)
    let fileTitle = url.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} - "#, with: "", options: .regularExpression)
    let rawTitle = note.value("title") ?? fileTitle
    let title = isSessionSlug(rawTitle) ? localized("Riunione senza titolo") : rawTitle

    let dated = meetingStart(in: note)
        ?? note.value("date").flatMap { parseDay($0) }.map { ($0, false) }
        ?? note.value("session_id").flatMap { parseSessionStamp($0) }.map { ($0, true) }
        ?? (modifiedAt, true)

    let project = note.value("project").flatMap { isSessionSlug($0) ? nil : $0 }
    let theme = note.value("theme").flatMap { isSessionSlug($0) ? nil : $0 }

    return JournalDocument(
        url: url,
        title: title,
        date: dated.0,
        hasTime: dated.1,
        modifiedAt: modifiedAt,
        project: project,
        theme: theme,
        snippet: summarySnippet(note.body),
        searchText: [title, project ?? "", theme ?? "", note.body].joined(separator: "\n")
    )
}

/// Filenames and titles generated before metadata was known look like
/// `20260721-234121-meeting-pilot-…`: never show those as a title.
private func isSessionSlug(_ value: String) -> Bool {
    value.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) != nil
        || value.range(of: #"\d{4}-\d{2}-\d{2}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        || value.contains("meeting-pilot")
}

private func meetingStart(in note: JournalNote) -> (Date, Bool)? {
    if let start = note.value("start"), let date = parseLocalTimestamp(start) {
        return (date, true)
    }
    // Notes written before the frontmatter carried `start` keep it in the overview.
    for line in note.body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["Inizio: ", "Start: "] where trimmed.hasPrefix(prefix) {
            if let date = parseLocalTimestamp(String(trimmed.dropFirst(prefix.count))) {
                return (date, true)
            }
        }
    }
    return nil
}

private func parseLocalTimestamp(_ value: String) -> Date? {
    if let date = try? Date(value, strategy: .iso8601) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: String(value.prefix(19))) { return date }
    }
    return nil
}

private func parseDay(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: String(value.prefix(10)))
}

private func parseSessionStamp(_ value: String) -> Date? {
    guard value.range(of: #"^\d{8}-\d{6}"#, options: .regularExpression) != nil else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.date(from: String(value.prefix(15)))
}

/// First line of the summary section, for the list preview.
private func summarySnippet(_ body: String) -> String? {
    var inSummary = false
    for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("## ") {
            let heading = trimmed.dropFirst(3).lowercased()
            if inSummary { return nil }
            inSummary = heading.hasPrefix("sintesi") || heading.hasPrefix("summary") || heading.hasPrefix("riepilogo")
            continue
        }
        guard inSummary, !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("```") else { continue }
        let text = trimmed.replacingOccurrences(of: #"^([-*] |\d+[.)] )"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        if text.hasPrefix("Nessuna sintesi") || text.hasPrefix("No summary") { return nil }
        return text
    }
    return nil
}

private func journalTranscriptionLabel(_ provider: String) -> String {
    switch provider.lowercased() {
    case "fluid", "fluidaudio": return "FluidAudio"
    case "apple": return "Apple On-Device"
    default: return provider
    }
}

/// ISO timestamps in the page body ("2026-08-04T14:36:59") read as a local date.
private func journalReadableValue(_ value: String) -> String {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}"#, options: .regularExpression) != nil,
          let date = parseLocalTimestamp(value) else { return value }
    return journalDateText(date)
}

func journalDateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func journalMonthText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
    return formatter.string(from: date)
}

private func journalLongDateText(_ document: JournalDocument) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.dateStyle = .full
    return formatter.string(from: document.date)
}

private func journalShortDateText(_ document: JournalDocument) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.setLocalizedDateFormatFromTemplate(document.hasTime ? "EEEdMMMHHmm" : "EEEdMMM")
    return formatter.string(from: document.date)
}

private func journalTimeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
