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


struct TeamsConfigurationSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var detectionDebug = "Premi Debug rilevazione durante una call Teams."
    @State private var showAdvancedTools = false

    private var hasMeetingDetails: Bool {
        model.recording.runtimeTitle != "-" && !model.recording.runtimeTitle.isEmpty
    }

    private var participantsText: String {
        model.recording.runtimeParticipants == "-" || model.recording.runtimeParticipants.isEmpty
            ? localized("I partecipanti compariranno qui quando Teams li rende disponibili.")
            : model.recording.runtimeParticipants
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                // The Teams logo, with the call state as a small badge on its corner.
                BundledAssetIcon(name: "microsoft_teams_logo.png", fallbackSymbol: "person.3.fill", size: 26)
                    .frame(width: 30, height: 30)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: hasMeetingDetails ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white, hasMeetingDetails ? MeetingPilotDesign.success : MeetingPilotDesign.accent)
                            .background(Circle().fill(MeetingPilotDesign.surfaceColor).padding(-1.5))
                            .offset(x: 4, y: 4)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(hasMeetingDetails ? "Call Teams rilevata" : "In attesa di una call Teams"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(hasMeetingDetails ? model.recording.runtimeTitle : localized("Apri o avvia una riunione Teams per recuperare automaticamente i dettagli."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .lineLimit(2)
                    Text(participantsText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Recupera da Teams") { model.runTeamsScrape() }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 2)

            Rectangle()
                .fill(MeetingPilotDesign.lineColor)
                .frame(height: 1)

            DisclosureGroup("Strumenti avanzati", isExpanded: $showAdvancedTools) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow(label: "Stato ultimo recupero", value: model.recording.runtimeStatus)
                    SettingsRow(label: "Oggetto", value: model.recording.runtimeTitle)
                    SettingsRow(label: "Partecipanti", value: participantsText)
                    HStack {
                        Button("Ispeziona Teams") {
                            detectionDebug = "Leggo gli elementi Accessibilità di Teams…"
                            model.inspectTeamsAccessibility { snapshot in
                                detectionDebug = snapshot
                            }
                        }
                        .buttonStyle(CompactButtonStyle())
                        .help("Mostra gli elementi Accessibilità esposti da Teams durante la call")
                        Spacer()
                    }
                    Text(localized(detectionDebug))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.top, 10)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 2)
        }
    }
}

struct TeamsScraperView: View {
    var body: some View {
        ContentPane(title: "Comunicazione") {
            TeamsConfigurationSection()
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentPane(title: "Permessi macOS") {
            Text("Abilita solo cio' che manca. Ogni pulsante apre direttamente la sezione corretta di macOS.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MeetingPilotDesign.textDimColor)
            SettingsRow(label: "App in esecuzione", value: compactPath(model.runningAppPath))
            Text("I permessi macOS valgono per questa copia esatta dell'app. Se abiliti Meeting Pilot in Applications ma stai usando una copia dal DMG o dalla build, lo stato puo' restare negato.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MeetingPilotDesign.textDimColor)

            HStack {
                Button("Aggiorna stato permessi") {
                    model.refreshPermissionRows()
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("La verifica interroga nuovamente macOS.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
            }

            ForEach(model.permissionRows) { row in
                PermissionRowView(row: row) {
                    model.openPermissionSettings(row)
                }
            }

            if !model.missingPermissionRows.isEmpty {
                Button("Mostra checklist iniziale") {
                    PermissionsSetupWindow.shared.show(rows: model.missingPermissionRows) { row in
                        model.openPermissionSettings(row)
                    } onRefresh: {
                        model.refreshPermissionRows()
                        return model.missingPermissionRows
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentPane(title: "Log") {
            HStack {
                Button("Aggiorna") { model.refreshLogs() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Copia log") { model.copyLogs() }
                    .buttonStyle(CompactButtonStyle())
                Button("Apri cartella") { model.openLogs() }
                    .buttonStyle(CompactButtonStyle())
            }
            ScrollView {
                Text(model.logTail.isEmpty ? localized("Nessun evento registrato. Premi Aggiorna dopo un tentativo di elaborazione.") : model.logTail)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 320)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
        }
    }
}

/// Locale matching the in-app language choice, for user-facing dates.
var appLocale: Locale {
    Locale(identifier: (AppLanguage(code: Bundle.main.preferredLocalizations.first) ?? .en).localeIdentifier)
}

func localized(_ value: String) -> String {
    let direct = Bundle.main.localizedString(forKey: value, value: value, table: "Localizable")
    if direct != value { return direct }
    // Status messages are often "Fixed prefix: dynamic detail" (an error, a path, a name):
    // translate the fixed part and keep the detail verbatim.
    if let separator = value.range(of: ": ") {
        let head = String(value[..<separator.lowerBound])
        let translatedHead = Bundle.main.localizedString(forKey: head, value: head, table: "Localizable")
        if translatedHead != head {
            let tail = String(value[separator.upperBound...])
            let translatedTail = Bundle.main.localizedString(forKey: tail, value: tail, table: "Localizable")
            return translatedHead + ": " + translatedTail
        }
    }
    return value
}
