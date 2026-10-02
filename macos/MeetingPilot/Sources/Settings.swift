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


enum SettingsPane: String, CaseIterable, Identifiable {
    case overview = "Generale"
    case permissions = "Permessi"
    case logs = "Log"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .logs: return "text.alignleft"
        }
    }
}

struct BundledAssetIcon: View {
    let name: String?
    let fallbackSymbol: String
    var size: CGFloat = 15
    var templateRendering: Bool = false

    var body: some View {
        if let name,
           let image = NSImage.trimmedBundledAsset(named: name) {
            Image(nsImage: image)
                .renderingMode(templateRendering ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size - 2, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MPSegmentedTabs(selection: $pane, items: SettingsPane.allCases, title: { $0.rawValue }, symbol: { $0.symbol })
                .padding(.horizontal, 28)
                .padding(.top, 20)

            Group {
                switch pane {
                case .overview:
                    SettingsOverviewView(
                        openPermissions: { pane = .permissions }
                    )
                case .permissions:
                    PermissionsView()
                case .logs:
                    LogsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(pane)
            .transition(.opacity)
        }
        .animation(.mpSmooth, value: pane)
    }
}

/// Pill-shaped segmented control for switching sub-pages inside one section.
struct MPSegmentedTabs<Item: Hashable>: View {
    @Binding var selection: Item
    let items: [Item]
    let title: (Item) -> String
    var symbol: ((Item) -> String)? = nil
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 6) {
                        if let symbol {
                            Image(systemName: symbol(item))
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(localized(title(item)))
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? MeetingPilotDesign.textColor : MeetingPilotDesign.textDimColor)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background {
                        if selected {
                            Capsule()
                                .fill(MeetingPilotDesign.elevatedColor)
                                .overlay(Capsule().strokeBorder(MeetingPilotDesign.lineStrongColor, lineWidth: 1))
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "tab", in: indicator)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(MeetingPilotDesign.hoverColor))
        .animation(.mpSnappy, value: selection)
    }
}

/// Two icon buttons (sun / moon) rather than a text-labeled segmented picker — matches
/// System Settings' own Appearance control, needs no translation, and reads at a glance.
struct ThemeIconPicker: View {
    @Binding var selection: MeetingPilotTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            themeButton(.light, symbol: "sun.max.fill", label: "Chiaro")
            themeButton(.dark, symbol: "moon.fill", label: "Scuro")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(MeetingPilotDesign.hoverColor))
        .animation(.mpSnappy, value: selection)
    }

    private func themeButton(_ theme: MeetingPilotTheme, symbol: String, label: String) -> some View {
        let isSelected = selection == theme
        return Button {
            selection = theme
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                Text(localized(label))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? MeetingPilotDesign.accentTint : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? MeetingPilotDesign.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        // maxWidth: .infinity must sit on the Button itself, not just its label — an
        // HStack sizes based on its direct children's flexibility, and a frame buried
        // inside a button's label doesn't reliably propagate as that child's own
        // flexibility, which is what left one segment full-width and the other a sliver.
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel(localized(label))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct SettingsOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let openPermissions: () -> Void
    @State private var audioFolder = ""
    @State private var isRelaunchingForLanguage = false

    var body: some View {
        ContentPane(title: "Impostazioni", subtitle: "Lingua, aspetto, permessi e stato dei servizi.") {
            if model.projectAccessSuspended {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accesso cartella progetto richiesto")
                        .font(.system(size: 14, weight: .bold))
                    Text("macOS sta bloccando la lettura del progetto in Documents. Premi Consenti nel popup, poi riprova qui.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                    Button("Riprova accesso progetto") {
                        model.retryProjectAccess()
                    }
                    .buttonStyle(CompactButtonStyle())
                }
                .padding(12)
                .background(MeetingPilotDesign.warning.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(spacing: 10) {
                SettingsShortcutRow(
                    icon: "lock.shield",
                    title: "Permessi macOS",
                    value: String(format: localized("%ld di %ld"), model.permissionsReady, model.permissionRows.count),
                    accent: model.permissionsReady == model.permissionRows.count ? MeetingPilotDesign.success : MeetingPilotDesign.warning,
                    action: openPermissions
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("Lingua app"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MeetingPilotDesign.tertiaryText(for: colorScheme))
                if isRelaunchingForLanguage {
                    // saveAppLanguage() relaunches the whole process — Bundle.main's
                    // locale is bound at launch and can't be hot-swapped — so without
                    // this, picking a language just makes the app silently vanish for
                    // ~250ms, which reads as a crash, not a language change.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(localized("Riavvio in corso..."))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MeetingPilotDesign.secondaryText(for: colorScheme))
                    }
                    .frame(height: 24)
                } else {
                    Picker("Lingua app", selection: Binding(
                        get: { model.appLanguage },
                        set: { selected in
                            isRelaunchingForLanguage = true
                            model.saveAppLanguage(selected)
                        }
                    )) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.nativeName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("Tema app"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MeetingPilotDesign.tertiaryText(for: colorScheme))
                ThemeIconPicker(selection: Binding(
                    get: { model.appTheme },
                    set: { model.saveAppTheme($0) }
                ))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            VStack(spacing: 10) {
                SettingsRow(
                    label: "Recorder",
                    value: model.recorderDisplayName,
                    detail: compactPath(model.inboxLabel)
                )
                SettingsRow(label: "Provider", value: model.providerDisplayName)
                Button {
                    model.selectedSection = .journal
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MeetingPilotDesign.accent)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Destinazioni")
                                .font(.system(size: 14, weight: .bold))
                            Text("Gestisci Diario, Notion, Obsidian e Apple Notes")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MeetingPilotDesign.textDimColor)
                        }
                        Spacer()
                        Text("Gestisci")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MeetingPilotDesign.textDimColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Apri le destinazioni di pubblicazione")
                SettingsConnectionStatusRow(
                    title: "Notion",
                    status: model.notion.occurrencesDatabaseId.isEmpty ? "Non collegato" : "Collegato",
                    isConnected: !model.notion.occurrencesDatabaseId.isEmpty,
                    assetName: "Notion_app_logo.png",
                    fallbackSymbol: "doc.text",
                    lightIconBackground: true
                )
                SettingsConnectionStatusRow(
                    title: "Obsidian",
                    status: model.obsidianVaultPath.isEmpty ? "Non collegato" : "Collegato",
                    isConnected: !model.obsidianVaultPath.isEmpty,
                    assetName: "2023_Obsidian_logo.svg",
                    fallbackSymbol: "book.closed.fill"
                )
                SettingsRow(
                    label: "Trascrizione",
                    value: model.transcriptionDisplayName,
                    assetName: "recorder_logo.png",
                    fallbackSymbol: "mic.fill",
                    iconSize: 21,
                    iconTemplateRendering: true
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Cartella audio")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                HStack {
                    TextField("Percorso cartella audio", text: $audioFolder)
                        .textFieldStyle(DarkTextFieldStyle())
                    Button {
                        if let selected = model.chooseRecorderFolder() {
                            audioFolder = selected
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(CompactButtonStyle())
                    .help("Scegli cartella audio")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            LaunchAtLoginCard()
        }
        .onAppear {
            audioFolder = model.recorderFolder
        }
        .onChange(of: audioFolder) { _ in model.saveRecorderFolder(audioFolder) }
    }
}

struct LaunchAtLoginCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .foregroundStyle(MeetingPilotDesign.accent)
                Text("Avvia al login")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Image(systemName: model.launchAtLogin ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.launchAtLogin ? MeetingPilotDesign.success : Color.adaptiveWhite(0.35))
            }
            LoginLaunchChoice(
                title: "Avvia Meeting Pilot automaticamente all'accesso del Mac",
                selected: model.launchAtLogin
            ) {
                model.saveLaunchAtLogin(true)
            }
            LoginLaunchChoice(
                title: "Non avviare Meeting Pilot automaticamente all'accesso del Mac",
                selected: !model.launchAtLogin
            ) {
                model.saveLaunchAtLogin(false)
            }
            if !model.statusMessage.isEmpty {
                Text(localized(model.statusMessage))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }
}

struct LoginLaunchChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? MeetingPilotDesign.accent : Color.adaptiveWhite(0.32))
                Text(localized(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsShortcutRow: View {
    let icon: String
    let title: String
    let value: String
    let accent: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 22)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized(title))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MeetingPilotDesign.primaryText(for: colorScheme))
                    Text(localized(value))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MeetingPilotDesign.tertiaryText(for: colorScheme))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
