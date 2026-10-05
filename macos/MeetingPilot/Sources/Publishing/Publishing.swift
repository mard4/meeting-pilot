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


struct SectionToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(localized(title), isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 12, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PageSectionsCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var included: [PageSection: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionGrid(PageSection.shared)
            if model.userProfile.isWorker {
                sectionGroup("Riunioni di lavoro", sections: PageSection.meeting)
            }
            if model.userProfile.isStudent {
                sectionGroup("Lezioni", sections: PageSection.lecture)
            }

            Button("Salva formato") {
                model.savePageSections(included)
            }
            .buttonStyle(CompactButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
        .onAppear {
            included = model.includedSections
        }
    }

    private func sectionGroup(_ title: String, sections: [PageSection]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized(title))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MeetingPilotDesign.textDimColor)
            sectionGrid(sections)
        }
        .padding(.top, 4)
    }

    private func sectionGrid(_ sections: [PageSection]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 9) {
            ForEach(sections) { section in
                SectionToggle(section.title, isOn: Binding(
                    get: { included[section] ?? true },
                    set: { included[section] = $0 }
                ))
            }
        }
    }
}

struct AudioRetentionCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Conserva la registrazione"))
                    .font(.system(size: 13, weight: .semibold))
                Text(localized(model.keepAudio
                    ? "L'audio resta sul Mac e ogni nota contiene il link al file."
                    : "L'audio viene eliminato appena la riunione è pubblicata. Trascrizione e sintesi restano."))
                    .font(MPFont.callout())
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(localized("Conserva la registrazione"), isOn: Binding(
                get: { model.keepAudio },
                set: { model.saveKeepAudio($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }
}

struct PublicationToggle: View {
    @EnvironmentObject private var model: AppModel
    let target: String

    private var isOn: Bool {
        model.publicationTargets.contains(target)
    }

    var body: some View {
        Toggle("Pubblica", isOn: Binding(
            get: { isOn },
            set: { _ in model.togglePublicationTarget(target) }
        ))
        .toggleStyle(.switch)
        .labelsHidden()
        .help(localized(isOn ? "Disattiva pubblicazione" : "Attiva pubblicazione"))
    }
}

struct NotionConfigurationForm: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var parentPageId = ""
    @State private var pageName = "Meeting Pilot"
    @State private var showAdvancedSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.notion.occurrencesDatabaseId.isEmpty {
                Button {
                    model.notion.startOAuth()
                } label: {
                    Label("Collega Notion", systemImage: "link")
                }
                .buttonStyle(CompactButtonStyle())
            }

            if !model.statusMessage.isEmpty {
                Text(localized(model.statusMessage))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 10) {
                Button {
                    model.notion.openDatabase()
                } label: {
                    SettingsRow(label: "Spazio", value: model.notion.pageName)
                }
                .buttonStyle(.plain)

                if !model.notion.occurrencesDatabaseId.isEmpty {
                    Button {
                        model.notion.startOAuth()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(CompactButtonStyle())
                    .help("Cambia spazio")
                    .accessibilityLabel("Cambia spazio")
                }
            }

            if model.notion.pageChoices.count > 1 {
                HStack(spacing: 10) {
                    Text(localized("Crea dentro"))
                        .font(MPFont.callout(.medium))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                    Picker(localized("Crea dentro"), selection: Binding(
                        get: {
                            model.notion.pageChoices.first {
                                NotionPageChoice.normalized($0.id) == NotionPageChoice.normalized(model.notion.parentPageId)
                            }
                        },
                        set: { choice in
                            if let choice { model.notion.chooseParentPage(choice) }
                        }
                    )) {
                        ForEach(model.notion.pageChoices) { choice in
                            Text(choice.title).tag(Optional(choice))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("Pagina Notion in cui Meeting Pilot crea il suo spazio")
                }
            } else if let parentTitle = model.notion.parentPageTitle {
                SettingsRow(label: "Crea dentro", value: parentTitle)
            }

            HStack(spacing: 10) {
                EditableField(label: "Nome pagina", text: $pageName, placeholder: "Meeting Pilot")
                Button {
                    model.notion.saveSettings(
                        token: token,
                        parentPageId: parentPageId,
                        pageName: pageName
                    )
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(CompactButtonStyle())
                .help("Salva nome")
                .accessibilityLabel("Salva nome")
            }

            if model.notion.token.isEmpty || model.notion.occurrencesDatabaseId.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MeetingPilotDesign.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fallback Apple Notes attivo")
                            .font(.system(size: 13, weight: .bold))
                        Text("Se Notion non e' configurato, le riunioni vengono salvate nelle Note del Mac, cartella Meeting Pilot.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MeetingPilotDesign.textDimColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(MeetingPilotDesign.accent.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider().background(Color.adaptiveWhite(0.14))

            DisclosureGroup("Configurazione avanzata (token e pagina manuali)", isExpanded: $showAdvancedSetup) {
                VStack(spacing: 10) {
                    SecureEditableField(label: "Token personale Notion", text: $token, placeholder: "ntn_...")
                    EditableField(label: "Pagina Notion parent", text: $parentPageId, placeholder: "Incolla URL o ID pagina Notion")
                    HStack {
                        Button("Salva e crea spazio") {
                            model.notion.saveSettings(
                                token: token,
                                parentPageId: parentPageId,
                                pageName: pageName
                            )
                        }
                        .buttonStyle(CompactButtonStyle())
                        Button("Riprova") {
                            model.notion.provisionWorkspace(
                                token: token,
                                parentPageId: parentPageId,
                                pageName: pageName
                            )
                        }
                        .buttonStyle(CompactButtonStyle())
                        Button("Apri token Notion") { model.notion.openTokenPage() }
                            .buttonStyle(CompactButtonStyle())
                    }
                }
                .padding(.top, 10)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MeetingPilotDesign.textDimColor)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
        }
        .onAppear {
            token = model.notion.token
            parentPageId = model.notion.parentPageId
            pageName = model.notion.pageName
        }
    }
}

struct NotionView: View {
    var body: some View {
        ContentPane(title: "Notion") {
            NotionConfigurationForm()
        }
    }
}

struct ObsidianConfigurationForm: View {
    @EnvironmentObject private var model: AppModel
    @State private var vaultPath = ""
    @State private var folder = ""
    @State private var filenameTemplate = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let selected = model.chooseObsidianVault() {
                    vaultPath = selected
                    model.saveObsidianSettings(
                        vaultPath: selected,
                        folder: folder,
                        filenameTemplate: filenameTemplate
                    )
                }
            } label: {
                Label("Scegli vault", systemImage: "folder.badge.plus")
            }
            .buttonStyle(CompactButtonStyle())

            EditableField(label: "Cartella note", text: $folder, placeholder: "Meeting Pilot")
            EditableField(label: "Template nome file", text: $filenameTemplate, placeholder: "{date} - {title}.md")

            HStack {
                Button {
                    model.openObsidianVault(at: vaultPath)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(CompactButtonStyle())
                .disabled(vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Apri vault")

                Button {
                    model.openObsidianApp()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(CompactButtonStyle())
                .help("Apri Obsidian")

                Button {
                    model.saveObsidianSettings(
                        vaultPath: vaultPath,
                        folder: folder,
                        filenameTemplate: filenameTemplate
                    )
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Salva Obsidian")
            }
        }
        .onAppear {
            vaultPath = model.obsidianVaultPath
            folder = model.obsidianFolder
            filenameTemplate = model.obsidianFilenameTemplate
        }
    }
}

struct ObsidianView: View {
    var body: some View {
        ContentPane(title: "Obsidian") {
            ObsidianConfigurationForm()
        }
    }
}

struct AppleNotesConfigurationForm: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Le riunioni vengono salvate nell'account Apple Notes, nella cartella Meeting Pilot.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MeetingPilotDesign.textDimColor)
            HStack {
                Button("Apri Apple Notes") {
                    model.openAppleNotes()
                }
                .buttonStyle(CompactButtonStyle())

                Text(localized(model.statusMessage))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
            }

        }
    }
}

struct AppleNotesView: View {
    var body: some View {
        ContentPane(title: "Apple Notes") {
            AppleNotesConfigurationForm()
        }
    }
}
