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
                    SettingsOverviewView()
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
    @State private var audioFolder = ""
    @State private var isRelaunchingForLanguage = false

    // Recorder, transcription, summary and destinations live in Pipeline and
    // Publishing, and permissions in their own tab: General keeps only the app itself.
    var body: some View {
        ContentPane(title: "Impostazioni", subtitle: "Profilo, aspetto e preferenze dell'app.") {
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

            SettingsGroup(title: "Profilo") {
                ProfileSettingsRow()
            }

            SettingsGroup(title: "Aspetto") {
                SettingsLine(title: "Lingua app", icon: SettingsIcon(symbol: "globe")) {
                    if isRelaunchingForLanguage {
                        // saveAppLanguage() relaunches the whole process — Bundle.main's
                        // locale is bound at launch and can't be hot-swapped — so without
                        // this, picking a language just makes the app silently vanish for
                        // ~250ms, which reads as a crash, not a language change.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(localized("Riavvio in corso..."))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MeetingPilotDesign.textDimColor)
                        }
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
                SettingsDivider()
                SettingsLine(title: "Tema app", icon: SettingsIcon(symbol: "circle.lefthalf.filled")) {
                    ThemeIconPicker(selection: Binding(
                        get: { model.appTheme },
                        set: { model.saveAppTheme($0) }
                    ))
                    .frame(width: 200)
                }
            }

            SettingsGroup(title: "Registrazione") {
                AppScreenSharingRow()
                SettingsDivider()
                SidebarScreenSharingRow()
                SettingsDivider()
                SettingsLine(
                    title: "Cartella audio",
                    detail: "Dove arrivano le registrazioni da elaborare.",
                    icon: SettingsIcon(symbol: "folder.fill", badge: "waveform")
                ) {
                    HStack(spacing: 6) {
                        TextField("Percorso cartella audio", text: $audioFolder)
                            .textFieldStyle(DarkTextFieldStyle())
                            .frame(width: 240)
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
            }

            SettingsGroup(title: "Sistema") {
                LaunchAtLoginCard()
            }
        }
        .onAppear {
            audioFolder = model.recorderFolder
        }
        .onChange(of: audioFolder) { _ in model.saveRecorderFolder(audioFolder) }
    }
}

/// A titled card of rows, as narrow as its controls need rather than the whole window.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(title))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MeetingPilotDesign.tertiaryText(for: colorScheme))
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

/// Label (and an optional explanation) on the left, its control on the right, with an
/// icon in front so a row is recognised before it is read.
struct SettingsLine<Control: View>: View {
    let title: String
    var detail: String? = nil
    var icon: SettingsIcon? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon {
                icon
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                if let detail {
                    Text(localized(detail))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 10)
    }
}

/// The tinted tile in front of a settings row; `badge` adds a small second symbol in
/// its corner where no single SF Symbol says it (a folder of audio).
struct SettingsIcon: View {
    let symbol: String
    var badge: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(MeetingPilotDesign.accentTint)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.accent)
            )
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(MeetingPilotDesign.accent)
                        .padding(2)
                        .background(Circle().fill(MeetingPilotDesign.surfaceColor))
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(MeetingPilotDesign.lineColor)
            .frame(height: 1)
    }
}

/// Student, worker or both (USER_PROFILE); one of the two always stays selected.
struct ProfileSettingsRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsLine(
            title: "Tipo di note",
            detail: model.userProfile == .both
                ? "Una registrazione diventa una lezione quando il titolo lo dice, ad esempio \"Lezione\" o \"Corso di\". Durante la registrazione puoi cambiarlo nella sidebar dal vivo."
                : "Lezioni: concetti chiave e compiti. Riunioni: decisioni e action item.",
            icon: SettingsIcon(symbol: "person.text.rectangle.fill")
        ) {
            HStack(spacing: 6) {
                ProfileChip(title: "Studente", symbol: "graduationcap.fill", selected: model.userProfile.isStudent) {
                    let profile = model.userProfile
                    guard !(profile.isStudent && !profile.isWorker) else { return }
                    model.saveUserProfile(UserProfile(student: !profile.isStudent, worker: profile.isWorker))
                }
                ProfileChip(title: "Lavoratore", symbol: "briefcase.fill", selected: model.userProfile.isWorker) {
                    let profile = model.userProfile
                    guard !(profile.isWorker && !profile.isStudent) else { return }
                    model.saveUserProfile(UserProfile(student: profile.isStudent, worker: !profile.isWorker))
                }
            }
        }
    }
}

private struct ProfileChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark" : symbol)
                    .font(.system(size: 11, weight: .bold))
                Text(localized(title))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(selected ? MeetingPilotDesign.accentTint : MeetingPilotDesign.hoverColor))
            .overlay(Capsule().strokeBorder(selected ? MeetingPilotDesign.accent.opacity(0.45) : MeetingPilotDesign.lineColor, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct SidebarScreenSharingRow: View {
    @AppStorage(LiveSidebarWindow.hiddenFromScreenSharingKey) private var hidden = true

    var body: some View {
        SettingsLine(
            title: "Nascondi la barra laterale nelle condivisioni schermo",
            detail: "Chi guarda la tua condivisione o registrazione dello schermo non vede trascrizione e note.",
            icon: SettingsIcon(symbol: "sidebar.right")
        ) {
            Toggle("", isOn: Binding(
                get: { hidden },
                set: { LiveSidebarWindow.shared.setHiddenFromScreenSharing($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(MeetingPilotDesign.accent)
        }
    }
}

struct AppScreenSharingRow: View {
    @AppStorage(ScreenSharingPrivacy.appHiddenKey) private var hidden = false

    var body: some View {
        SettingsLine(
            title: "Nascondi Meeting Pilot nelle condivisioni schermo",
            detail: "Tutte le finestre dell'app restano invisibili a chi guarda. Anche da Finestra o con ⇧⌘H.",
            // The closest SF Symbol to incognito.
            icon: SettingsIcon(symbol: "sunglasses.fill")
        ) {
            Toggle("", isOn: Binding(
                get: { hidden },
                set: { ScreenSharingPrivacy.setAppHidden($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(MeetingPilotDesign.accent)
        }
    }
}

struct LaunchAtLoginCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsLine(
            title: "Avvia al login",
            detail: model.launchAtLoginNeedsApproval
                ? "Disattivato in Impostazioni di Sistema > Generale > Elementi login."
                : "Apri Meeting Pilot quando accedi al Mac.",
            icon: SettingsIcon(symbol: "power")
        ) {
            if model.launchAtLoginNeedsApproval {
                Button(localized("Apri Impostazioni")) { LaunchAtLogin.openSystemSettings() }
            }
            Toggle("", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.saveLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(MeetingPilotDesign.accent)
        }
    }
}
