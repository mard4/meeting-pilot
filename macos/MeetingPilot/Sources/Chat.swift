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


struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var question = ""
    @State private var projects: Set<String> = []
    @State private var themes: Set<String> = []
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var startDateEnabled = false
    @State private var endDateEnabled = false
    @State private var dateFilter = "all"
    @State private var sources: Set<String> = ["journal", "notion", "obsidian", "apple_notes"]
    @State private var catalogSources: Set<String> = ["journal", "notion", "obsidian", "apple_notes"]
    @State private var catalogSourceStatus = ""
    @State private var searchScope = "meetings"
    @State private var externalSources: Set<String> = []
    @State private var mongoURI = ""
    @State private var mongoDatabase = ""
    @State private var mongoCollection = ""
    @State private var indexStatus = ""
    @State private var answer = ""
    @State private var citations: [MeetingChatCitationPayload] = []
    @State private var isAsking = false
    @State private var saveStatus = ""
    @State private var askedQuestion = ""
    @State private var showFilters = false

    private let defaultMeetingSources: Set<String> = ["journal", "notion", "obsidian", "apple_notes"]

    private var appliedFilterCount: Int {
        let sourceFilter = sources == defaultMeetingSources ? 0 : 1
        let scopeFilter = searchScope == "meetings" ? 0 : 1
        let dateRangeFilter = dateFilter == "all" ? 0 : 1
        let externalFilter = searchScope == "meetings" ? 0 : externalSources.count
        return projects.count + themes.count + sourceFilter + scopeFilter + dateRangeFilter + externalFilter
    }

    var body: some View {
        chatContent
            .onAppear {
                model.refreshChatFilterValues()
            }
            .onChange(of: model.chatProjects) { values in
                projects.formIntersection(values)
            }
            .onChange(of: model.chatThemes) { values in
                themes.formIntersection(values)
            }
            .onChange(of: externalSources) { _ in
                model.refreshChatFilterValues(externalSources: externalSources)
            }
            .onChange(of: catalogSources) { _ in
                syncCatalogSources()
            }
    }

    private var chatContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            MPPageHeader(title: "Chat", subtitle: "Fai domande sulle tue riunioni: ogni risposta cita le fonti.")

            chatFilterBar

            Group {
                if answer.isEmpty {
                    emptyChatState
                } else {
                    conversation
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            chatComposer
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chatFilterBar: some View {
        HStack(spacing: 10) {
            Button {
                showFilters.toggle()
            } label: {
                MPFilterPill(icon: "slider.horizontal.3", text: localized("Filtri"), active: appliedFilterCount > 0 || showFilters, count: appliedFilterCount)
            }
            .buttonStyle(.plain)
            .help("Apri filtri")
            .popover(isPresented: $showFilters, arrowEdge: .top) {
                ScrollView {
                    chatFilterPanel
                        .padding(2)
                }
                .frame(width: 620, height: 520)
            }

            ChatCatalogSourcesMenu(selection: $catalogSources, status: catalogSourceStatus)

            ChatMultiSelectMenu(
                title: "Progetti",
                values: model.chatProjects,
                selection: $projects,
                prominent: true,
                icon: "folder.fill",
                kind: "project"
            )

            ChatMultiSelectMenu(
                title: "Temi",
                values: model.chatThemes,
                selection: $themes,
                prominent: true,
                icon: "tag.fill",
                kind: "topic"
            )

            Text(String(format: localized("Cerchi in: %1$@ · %2$@ · %3$lld fonti"), scopeLabel, dateFilterLabel, sources.count))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func syncCatalogSources() {
        model.importTagCatalogFromSources(sources: catalogSources) { _, status in
            catalogSourceStatus = status
        }
    }

    private var chatFilterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatFilterField(label: "Cerca in") {
                HStack(spacing: 8) {
                    ChatChoiceChip("Meeting", isSelected: searchScope == "meetings") { searchScope = "meetings" }
                    ChatChoiceChip("Knowledge base", isSelected: searchScope == "knowledge") { searchScope = "knowledge" }
                    ChatChoiceChip("Entrambe", isSelected: searchScope == "both") { searchScope = "both" }
                }
            }

            ChatFilterField(label: "Periodo") {
                HStack(spacing: 8) {
                    ChatChoiceChip("Tutte le date", isSelected: dateFilter == "all") {
                    dateFilter = "all"
                    startDateEnabled = false
                    endDateEnabled = false
                    }
                    ChatChoiceChip("Ultimi 30 giorni", isSelected: dateFilter == "last30") {
                    dateFilter = "last30"
                    startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                    endDate = Date()
                    startDateEnabled = true
                    endDateEnabled = true
                    }
                    ChatChoiceChip("Intervallo personalizzato", isSelected: dateFilter == "custom") {
                        dateFilter = "custom"
                        startDateEnabled = true
                        endDateEnabled = true
                    }
                }
            }

            if dateFilter == "custom" {
                HStack(alignment: .bottom, spacing: 10) {
                    ChatFilterField(label: "Da") {
                        DatePicker("", selection: $startDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    ChatFilterField(label: "A") {
                        DatePicker("", selection: $endDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }

            ChatFilterField(label: "Fonti meeting") {
                HStack(spacing: 8) {
                    ChatSourceIconToggle(source: "journal", sources: $sources)
                    ChatSourceIconToggle(source: "notion", sources: $sources)
                    ChatSourceIconToggle(source: "obsidian", sources: $sources)
                    ChatSourceIconToggle(source: "apple_notes", sources: $sources)
                }
            }

            DisclosureGroup("Fonti esterne") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ChatSourceIconToggle(source: "notion", sources: $externalSources, knowledgeBase: true)
                        ChatSourceIconToggle(source: "obsidian", sources: $externalSources, knowledgeBase: true)
                        ChatSourceIconToggle(source: "mongodb", sources: $externalSources, knowledgeBase: true)
                    }
                    if externalSources.contains("mongodb") {
                        HStack(alignment: .bottom, spacing: 10) {
                            ChatFilterField(label: "URI MongoDB") { TextField("mongodb://localhost:27017", text: $mongoURI).textFieldStyle(.roundedBorder) }
                            ChatFilterField(label: "Database") { TextField("meeting_docs", text: $mongoDatabase).textFieldStyle(.roundedBorder) }
                            ChatFilterField(label: "Collection") { TextField("pages", text: $mongoCollection).textFieldStyle(.roundedBorder) }
                            Button(action: indexMongoDB) { Image(systemName: "arrow.triangle.2.circlepath") }
                                .buttonStyle(CompactButtonStyle())
                                .help("Indicizza MongoDB")
                        }
                        if !indexStatus.isEmpty {
                            Text(indexStatus).font(.system(size: 10, weight: .medium)).foregroundStyle(MeetingPilotDesign.textFaintColor)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MeetingPilotDesign.textDimColor)

            Divider().background(Color.adaptiveWhite(0.14))
            HStack {
                Button("Reimposta") {
                    projects.removeAll()
                    themes.removeAll()
                    sources = ["journal", "notion", "obsidian", "apple_notes"]
                    searchScope = "meetings"
                    dateFilter = "all"
                    startDateEnabled = false
                    endDateEnabled = false
                }
                .buttonStyle(CompactButtonStyle())
                Spacer()
                Button("Applica") {
                    showFilters = false
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }

    private var emptyChatState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 12)
            BrandTile(size: 52)
                .shadow(color: MeetingPilotDesign.accent.opacity(0.25), radius: 18)
            Text(localized("Fai una domanda alle tue riunioni"))
                .font(.mpDisplay(20))
                .multilineTextAlignment(.center)
            Text(localized("Ogni risposta cita le fonti da cui arriva: Diario, Notion, Obsidian e knowledge base."))
                .font(.system(size: 13))
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            VStack(spacing: 7) {
                ChatSuggestionButton(decisionSuggestion) { setQuickPrompt(decisionSuggestion) }
                ChatSuggestionButton("Quali azioni sono ancora aperte?") { setQuickPrompt(localized("Quali azioni sono ancora aperte?")) }
                ChatSuggestionButton("Riassumi l'ultima settimana") { setQuickPrompt(localized("Riassumi l'ultima settimana")) }
            }
            .frame(maxWidth: 620)
            Spacer(minLength: 12)
        }
        .frame(minHeight: 250)
    }

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !askedQuestion.isEmpty {
                    Text(askedQuestion)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MeetingPilotDesign.accentTint))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MeetingPilotDesign.accent.opacity(0.3), lineWidth: 1))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ChatHTMLAnswer(
                        text: answer,
                        citations: citations,
                        openCitation: openChatCitation
                    )
                        .frame(minHeight: 160)
                    if !citations.isEmpty {
                        Divider().background(Color.adaptiveWhite(0.14))
                        Text("Fonti citate")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                            ForEach(citations) { citation in
                                Button { openChatCitation(citation) } label: {
                                    Label(citation.destination, systemImage: "link")
                                }
                                .buttonStyle(ChatOutlinedButtonStyle(isSelected: false))
                                .help("\(citation.title)\(citation.date.map { " · \($0)" } ?? "")")
                            }
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !answer.isEmpty {
                HStack(spacing: 7) {
                    Text("Salva risposta in")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    ChatSaveButton("Diario", symbol: "book.closed", action: { saveMeetingChat(destination: "journal") })
                    ChatSaveButton("Notion", symbol: "doc.text", action: { saveMeetingChat(destination: "notion") })
                    ChatSaveButton("Obsidian", symbol: "square.and.arrow.down", action: { saveMeetingChat(destination: "obsidian") })
                    Text(saveStatus).font(.system(size: 10, weight: .medium)).foregroundStyle(MeetingPilotDesign.textFaintColor)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ChatQuickPromptButton("Decisioni") { setQuickPrompt(String(format: localized("Quali decisioni sono state prese per il progetto %@?"), projectText)) }
                    ChatQuickPromptButton("Azioni aperte") { setQuickPrompt(String(format: localized("Quali sono le azioni aperte e i responsabili per il progetto %@?"), projectText)) }
                    ChatQuickPromptButton("Rischi e blocchi") { setQuickPrompt(String(format: localized("Quali rischi e blocchi emergono per il progetto %@?"), projectText)) }
                    ChatQuickPromptButton("Evoluzione tema") { setQuickPrompt(String(format: localized("Come si è evoluto il tema %@ nei meeting selezionati?"), themeText)) }
                    ChatQuickPromptButton("Ultima settimana") { setQuickPrompt(String(format: localized("Cosa è cambiato dall'ultima settimana per il progetto %@?"), projectText)) }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                TextField(localized("Chiedi qualcosa sui meeting selezionati"), text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { ask() }
                Button(action: ask) {
                    HStack(spacing: 6) {
                        if isAsking {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                        }
                        Text(localized(isAsking ? "Invio..." : "Invia"))
                    }
                }
                .buttonStyle(MPPrimaryButtonStyle(compact: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isAsking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Invia domanda (⌘↩)")
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(MeetingPilotDesign.lineStrongColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            if isAsking {
                Text("Cerco nelle fonti selezionate...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
            }
        }
    }

    private var scopeLabel: String {
        switch searchScope {
        case "knowledge": return localized("Knowledge base")
        case "both": return localized("Meeting e KB")
        default: return localized("Meeting")
        }
    }

    private var dateFilterLabel: String {
        switch dateFilter {
        case "last30": return localized("Ultimi 30 giorni")
        case "custom": return localized("Intervallo personalizzato")
        default: return localized("Tutte le date")
        }
    }

    private var decisionSuggestion: String {
        projects.isEmpty
            ? localized("Cosa è stato deciso questo mese?")
            : String(format: localized("Cosa è stato deciso su %@ questo mese?"), projectText)
    }

    private var projectText: String {
        projects.isEmpty ? localized("selezionati") : projects.sorted().joined(separator: ", ")
    }

    private var themeText: String {
        themes.isEmpty ? localized("selezionati") : themes.sorted().joined(separator: ", ")
    }

    private func setQuickPrompt(_ value: String) {
        question = value
    }

    private func ask() {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAsking, !trimmedQuestion.isEmpty else { return }
        isAsking = true
        askedQuestion = trimmedQuestion
        model.askMeetingChat(
            question: trimmedQuestion,
            projects: projects,
            themes: themes,
            startDate: dateFilter == "all" ? nil : startDate,
            endDate: dateFilter == "all" ? nil : endDate,
            sources: sources,
            searchScope: searchScope,
            externalSources: externalSources
        ) { response in
            answer = response.answer
            citations = response.citations
            isAsking = false
            question = ""
        }
    }

    private func indexMongoDB() {
        model.indexMongoDBKnowledgeBase(
            uri: mongoURI,
            database: mongoDatabase,
            collection: mongoCollection
        ) { message in
            indexStatus = message
            externalSources.insert("mongodb")
            model.refreshChatFilterValues(externalSources: externalSources)
            if searchScope == "meetings" {
                searchScope = "both"
            }
        }
    }

    private func saveMeetingChat(destination: String) {
        model.saveMeetingChat(
            destination: destination,
            question: askedQuestion,
            answer: answer,
            citations: citations
        ) { message in
            saveStatus = message
        }
    }

    private func openChatCitation(_ citation: MeetingChatCitationPayload) {
        guard let url = URL(string: citation.url) else { return }
        NSWorkspace.shared.open(url)
    }

}

struct ChatQuickPromptButton: View {
    let label: String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        ChatChoiceChip(label, isSelected: false, action: action)
    }
}

struct ChatOutlinedButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(isSelected ? MeetingPilotDesign.accentTint : (configuration.isPressed ? MeetingPilotDesign.hoverColor : Color.clear)))
            .overlay(Capsule().strokeBorder(isSelected ? MeetingPilotDesign.accent.opacity(0.6) : MeetingPilotDesign.lineStrongColor, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.mpSnappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct ChatChoiceChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    init(_ label: String, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(localized(label), action: action)
            .buttonStyle(ChatOutlinedButtonStyle(isSelected: isSelected))
    }
}

struct ChatSuggestionButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(localized(label))
                    .font(.system(size: 13))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? MeetingPilotDesign.accent : MeetingPilotDesign.textFaintColor)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? MeetingPilotDesign.elevatedColor : MeetingPilotDesign.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? MeetingPilotDesign.lineStrongColor : MeetingPilotDesign.lineColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.mpSmooth, value: hovering)
    }
}

struct ChatSaveButton: View {
    let label: String
    let symbol: String
    let action: () -> Void

    init(_ label: String, symbol: String, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(localized(label), systemImage: symbol)
        }
        .buttonStyle(ChatOutlinedButtonStyle(isSelected: false))
        .help(String(format: localized("Salva in %@"), localized(label)))
    }
}

struct ChatSourceIconToggle: View {
    let source: String
    @Binding var sources: Set<String>
    var knowledgeBase = false

    private var title: String {
        switch source {
        case "journal": return "Diario"
        case "notion": return knowledgeBase ? "Notion knowledge base" : "Notion"
        case "obsidian": return knowledgeBase ? "Obsidian knowledge base" : "Obsidian"
        case "apple_notes": return "Apple Notes"
        case "mongodb": return "MongoDB"
        default: return source
        }
    }

    private var assetName: String? {
        switch source {
        case "notion": return "Notion_app_logo.png"
        case "obsidian": return "2023_Obsidian_logo.svg"
        case "apple_notes": return "apple_notes_logo.png"
        default: return nil
        }
    }

    private var fallbackSymbol: String {
        switch source {
        case "journal": return "book.pages"
        case "mongodb": return "cylinder.split.1x2"
        case "apple_notes": return "note.text"
        default: return "doc.text"
        }
    }

    var body: some View {
        Button {
            if sources.contains(source) {
                sources.remove(source)
            } else {
                sources.insert(source)
            }
        }
        label: {
            HStack(spacing: 7) {
                BundledAssetIcon(name: assetName, fallbackSymbol: fallbackSymbol, size: 16)
                    .frame(width: 18, height: 18)
                Text(localized(title))
                    .lineLimit(1)
            }
        }
        .buttonStyle(ChatOutlinedButtonStyle(isSelected: sources.contains(source)))
        .help(localized(title))
        .accessibilityLabel(localized(title))
    }
}

struct ChatCatalogSourcesMenu: View {
    @Binding var selection: Set<String>
    let status: String
    @State private var showPicker = false

    private var summary: String {
        selection.isEmpty ? localized("Nessuna fonte") : "\(selection.count) \(localized("fonti"))"
    }

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            MPFilterPill(icon: "square.stack.3d.up", text: summary, active: false, showsChevron: true)
        }
        .buttonStyle(.plain)
        .help(localized("Scegli le fonti per progetti e temi"))
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(localized("Fonti per progetti e temi"))
                    .font(.system(size: 13, weight: .bold))
                Text(localized("La selezione sincronizza automaticamente il catalogo."))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)

                HStack(spacing: 8) {
                    ChatSourceIconToggle(source: "journal", sources: $selection)
                    ChatSourceIconToggle(source: "notion", sources: $selection)
                }
                HStack(spacing: 8) {
                    ChatSourceIconToggle(source: "obsidian", sources: $selection)
                    ChatSourceIconToggle(source: "apple_notes", sources: $selection)
                }

                if !status.isEmpty {
                    Text(localized(status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}

struct ChatMultiSelectMenu: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPicker = false
    @State private var searchQuery = ""
    let title: String
    let values: [String]
    @Binding var selection: Set<String>
    var prominent = false
    var icon: String? = nil
    var kind = "project"

    private var summary: String {
        guard !selection.isEmpty else {
            return String(format: localized("Tutti i %@"), localized(title).lowercased())
        }
        return selection.count == 1 ? (selection.first ?? localized(title)) : "\(selection.count) \(localized("selezionati"))"
    }

    private var matchingValues: [String] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return values
            .filter { query.isEmpty || $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(query) }
            .sorted { left, right in
                let leftRank = matchRank(left, query: query)
                let rightRank = matchRank(right, query: query)
                if leftRank != rightRank { return leftRank < rightRank }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    var body: some View {
        Button {
            searchQuery = ""
            showPicker.toggle()
        } label: {
            MPFilterPill(icon: icon.map { $0.replacingOccurrences(of: ".fill", with: "") }, text: summary, active: !selection.isEmpty, showsChevron: true)
                .frame(maxWidth: 220)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(String(format: localized("Seleziona uno o più %@"), localized(title).lowercased()))
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(localized("Cerca"), text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(localized("Cerca")) \(localized(title).lowercased())")

                HStack(spacing: 8) {
                    Button(String(format: localized("Tutti i %@"), localized(title).lowercased())) {
                        selection.removeAll()
                    }
                    .buttonStyle(ChatOutlinedButtonStyle(isSelected: false))
                    .disabled(selection.isEmpty)

                    Button("\(localized("Aggiungi")) \(localized(title).lowercased())…") {
                        showPicker = false
                        addCatalogValue()
                    }
                    .buttonStyle(ChatOutlinedButtonStyle(isSelected: false))

                    Spacer(minLength: 0)
                }

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if matchingValues.isEmpty {
                            Text(localized("Nessun valore corrispondente"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(matchingValues, id: \.self) { value in
                                Button {
                                    if selection.contains(value) {
                                        selection.remove(value)
                                    } else {
                                        selection.insert(value)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selection.contains(value) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selection.contains(value) ? MeetingPilotDesign.accent : Color.adaptiveWhite(0.42))
                                        Text(value)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 30)
                                    .background(selection.contains(value) ? MeetingPilotDesign.accent.opacity(0.13) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 210)
            }
            .padding(12)
            .frame(width: 310)
        }
    }

    private func addCatalogValue() {
        let alert = NSAlert()
        alert.messageText = String(format: localized("Aggiungi %@"), localized(title).lowercased())
        alert.informativeText = localized("Il valore verrà aggiunto al catalogo locale di Meeting Pilot.")
        alert.addButton(withTitle: localized("Aggiungi"))
        alert.addButton(withTitle: localized("Annulla"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = localized(title)
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.addTagCatalogValue(kind: kind, value: value) { values in
            guard values != nil, !value.isEmpty else { return }
            selection.insert(value)
        }
    }

    private func matchRank(_ value: String, query: String) -> Int {
        guard !query.isEmpty else { return 2 }
        let normalized = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if normalized.hasPrefix(query) { return 0 }
        return normalized.contains(query) ? 1 : 2
    }
}

struct ChatAnswerSection: Identifiable {
    let title: String
    let items: [String]

    var id: String { title }

    var isSummary: Bool {
        ["sommario", "summary"].contains(title.lowercased())
    }
}

struct ChatHTMLAnswer: View {
    let text: String
    let citations: [MeetingChatCitationPayload]
    let openCitation: (MeetingChatCitationPayload) -> Void

    private var sections: [ChatAnswerSection] {
        chatAnswerSections(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                ChatAnswerSectionView(
                    section: section,
                    citations: citations,
                    openCitation: openCitation
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatAnswerSectionView: View {
    let section: ChatAnswerSection
    let citations: [MeetingChatCitationPayload]
    let openCitation: (MeetingChatCitationPayload) -> Void

    private var style: (color: Color, icon: String) {
        switch section.title.lowercased() {
        case "decisioni", "decisions": return (MeetingPilotDesign.success, "checkmark.seal.fill")
        case "inferenze", "inferences": return (MeetingPilotDesign.warning, "arrow.triangle.branch")
        default: return (MeetingPilotDesign.accent, "doc.text.fill")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: style.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(style.color)
                Text(localized(section.title))
                    .font(.system(size: 14, weight: .bold))
                Text("\(section.items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.adaptiveWhite(0.08))
                    .clipShape(Capsule())
            }

            if section.isSummary {
                ChatAnswerSummary(
                    text: section.items.joined(separator: " "),
                    citations: citations,
                    accent: style.color,
                    openCitation: openCitation
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        ChatAnswerItem(
                            text: item,
                            citations: citations,
                            accent: style.color,
                            openCitation: openCitation
                        )
                    }
                }
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(style.color.opacity(0.62))
                        .frame(width: 2)
                }
            }
        }
    }
}

struct ChatAnswerSummary: View {
    let text: String
    let citations: [MeetingChatCitationPayload]
    let accent: Color
    let openCitation: (MeetingChatCitationPayload) -> Void

    private var citationNumbers: [Int] { citationSourceNumbers(in: text) }

    private var bodyText: String {
        text.replacingOccurrences(of: "\\s*\\[\\d+(?:\\s*,\\s*\\d+)*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bodyText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(MeetingPilotDesign.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !citationNumbers.isEmpty {
                ChatCitationLinks(
                    numbers: citationNumbers,
                    citations: citations,
                    accent: accent,
                    openCitation: openCitation
                )
            }
        }
        .padding(12)
        .background(accent.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.30)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatAnswerItem: View {
    let text: String
    let citations: [MeetingChatCitationPayload]
    let accent: Color
    let openCitation: (MeetingChatCitationPayload) -> Void

    private var citationNumbers: [Int] {
        citationSourceNumbers(in: text)
    }

    private var bodyText: String {
        text.replacingOccurrences(of: "\\s*\\[\\d+(?:\\s*,\\s*\\d+)*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(accent.opacity(0.82))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(bodyText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !citationNumbers.isEmpty {
                    ChatCitationLinks(
                        numbers: citationNumbers,
                        citations: citations,
                        accent: accent,
                        openCitation: openCitation
                    )
                }
            }
        }
    }
}

private func chatAnswerSections(_ answer: String) -> [ChatAnswerSection] {
    let html = chatAnswerHTML(answer)
    let pattern = #"<h3[^>]*>(.*?)</h3>(.*?)(?=<h3|</section>|$)"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
        return [ChatAnswerSection(title: localized("Risposta"), items: [chatPlainText(html)])]
    }
    let fullRange = NSRange(html.startIndex..., in: html)
    let sections = expression.matches(in: html, range: fullRange).compactMap { match -> ChatAnswerSection? in
        guard let titleRange = Range(match.range(at: 1), in: html),
              let contentRange = Range(match.range(at: 2), in: html) else { return nil }
        let title = chatPlainText(String(html[titleRange]))
        let content = String(html[contentRange])
        let items = chatHTMLListItems(content)
        return title.isEmpty || items.isEmpty ? nil : ChatAnswerSection(title: title, items: items)
    }
    if !sections.isEmpty { return sections }
    let fallback = chatPlainText(html)
    return [ChatAnswerSection(title: localized("Risposta"), items: fallback.isEmpty ? [localized("Non trovato nei meeting selezionati.")] : [fallback])]
}

private func chatHTMLListItems(_ html: String) -> [String] {
    let pattern = #"<li[^>]*>(.*?)</li>"#
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
        return [chatPlainText(html)].filter { !$0.isEmpty }
    }
    let range = NSRange(html.startIndex..., in: html)
    let items = expression.matches(in: html, range: range).compactMap { match -> String? in
        guard let itemRange = Range(match.range(at: 1), in: html) else { return nil }
        let item = chatPlainText(String(html[itemRange]))
        return item.isEmpty ? nil : item
    }
    return items.isEmpty ? [chatPlainText(html)].filter { !$0.isEmpty } : items
}

private func chatPlainText(_ html: String) -> String {
    let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    return withoutTags
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ChatCitationLinks: View {
    let numbers: [Int]
    let citations: [MeetingChatCitationPayload]
    let accent: Color
    let openCitation: (MeetingChatCitationPayload) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(numbers, id: \.self) { number in
                if let citation = citations[safe: number - 1] {
                    Button { openCitation(citation) } label: {
                        HStack(spacing: 4) {
                            ChatCitationSourceIcon(destination: citation.destination)
                            Text("[\\(number)]")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.14))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(chatCitationHelp(citation))
                }
            }
        }
    }
}

struct ChatCitationSourceIcon: View {
    let destination: String

    private var service: MeetingPublicationService? {
        switch destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "diario", "journal": return .journal
        case "notion", "notion kb": return .notion
        case "obsidian", "obsidian kb": return .obsidian
        case "apple notes": return .appleNotes
        default: return nil
        }
    }

    var body: some View {
        if let service {
            BundledAssetIcon(
                name: service.assetName,
                fallbackSymbol: service.fallbackSymbol,
                size: 12
            )
            .padding(2)
            .background(service.needsLightBackground ? Color.adaptiveWhite(0.94) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .bold))
        }
    }
}

private func citationSourceNumbers(in text: String) -> [Int] {
    guard let expression = try? NSRegularExpression(pattern: #"\[(\d+(?:\s*,\s*\d+)*)\]"#) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Array(Set(expression.matches(in: text, range: range).flatMap { match -> [Int] in
        guard let valuesRange = Range(match.range(at: 1), in: text) else { return [] }
        return String(text[valuesRange]).split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    })).sorted()
}

private func chatCitationHelp(_ citation: MeetingChatCitationPayload) -> String {
    let date = citation.date.map { " · \($0)" } ?? ""
    return "\(citation.destination) · \(citation.title)\(date)"
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func chatAnswerHTML(_ answer: String) -> String {
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: "<[^>]+>", options: .regularExpression) != nil {
        return trimmed.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
    }
    return markdownAnswerHTML(trimmed)
}

private func markdownAnswerHTML(_ markdown: String) -> String {
    var html: [String] = []
    var listItems: [String] = []

    func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func formatted(_ value: String) -> String {
        escaped(value)
            .components(separatedBy: "**")
            .enumerated()
            .map { index, part in index.isMultiple(of: 2) ? part : "<strong>\(part)</strong>" }
            .joined()
    }

    func flushList() {
        guard !listItems.isEmpty else { return }
        html.append("<ul>\(listItems.joined())</ul>")
        listItems.removeAll()
    }

    for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            listItems.append("<li>\(formatted(String(line.dropFirst(2))))</li>")
        } else {
            flushList()
            if line.hasSuffix(":") {
                html.append("<h3>\(escaped(String(line.dropLast())))</h3>")
            } else if !line.isEmpty {
                html.append("<p>\(formatted(line))</p>")
            }
        }
    }
    flushList()
    return html.joined()
}

struct ChatFilterField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MPEyebrow(label)
            content
        }
    }
}

struct PublicationDestinationCard<Content: View>: View {
    let title: String
    let assetName: String?
    let fallbackSymbol: String
    let lightIconBackground: Bool
    let status: String
    let isConnected: Bool
    let target: String?
    let subtitle: String?
    @ViewBuilder let content: Content
    @State private var isExpanded = false
    @State private var hovering = false

    init(
        title: String,
        assetName: String? = nil,
        fallbackSymbol: String,
        lightIconBackground: Bool = false,
        status: String,
        isConnected: Bool,
        target: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.assetName = assetName
        self.fallbackSymbol = fallbackSymbol
        self.lightIconBackground = lightIconBackground
        self.status = status
        self.isConnected = isConnected
        self.target = target
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.mpSmooth) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 14) {
                        Group {
                            if let assetName {
                                BundledAssetIcon(name: assetName, fallbackSymbol: fallbackSymbol, size: lightIconBackground ? 22 : 26)
                            } else {
                                Image(systemName: fallbackSymbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(MeetingPilotDesign.accent)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(lightIconBackground ? Color.white : MeetingPilotDesign.hoverColor)
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(localized(title))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MeetingPilotDesign.textColor)
                            if let subtitle {
                                Text(localized(subtitle))
                                    .font(.system(size: 12))
                                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        MPBadge(text: status, tone: isConnected ? .success : .neutral)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(format: localized(isExpanded ? "Comprimi %@" : "Configura %@"), localized(title)))

                if let target {
                    PublicationToggle(target: target)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 20)
                    .onTapGesture { withAnimation(.mpSmooth) { isExpanded.toggle() } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(hovering && !isExpanded ? MeetingPilotDesign.hoverColor : Color.clear)
            .onHover { hovering = $0 }

            if isExpanded {
                Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MeetingPilotDesign.cornerRadius, style: .continuous)
                .fill(MeetingPilotDesign.surfaceColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: MeetingPilotDesign.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MeetingPilotDesign.cornerRadius, style: .continuous)
                .strokeBorder(isExpanded ? MeetingPilotDesign.lineStrongColor : MeetingPilotDesign.lineColor, lineWidth: 1)
        )
    }
}

/// Trigger for a filter popover/menu: quiet by default, crimson only when it narrows results.
struct MPFilterPill: View {
    let icon: String?
    let text: String
    var active = false
    var count: Int? = nil
    var showsChevron = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(text)
                .lineLimit(1)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(MeetingPilotDesign.accent))
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(active ? MeetingPilotDesign.accent : MeetingPilotDesign.textColor)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(active ? MeetingPilotDesign.accentTint : (hovering ? MeetingPilotDesign.hoverColor : MeetingPilotDesign.surfaceColor)))
        .overlay(Capsule().strokeBorder(active ? MeetingPilotDesign.accent.opacity(0.55) : MeetingPilotDesign.lineStrongColor, lineWidth: 1))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.mpSmooth, value: active)
    }
}
