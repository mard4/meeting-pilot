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


enum CommunicationDestination: String, CaseIterable, Identifiable {
    case teams = "Teams"
    case slack = "Slack"

    var id: String { rawValue }
    var assetName: String {
        self == .teams ? "microsoft_teams_logo.png" : "Slack-Logo.webp"
    }

    var fallbackSymbol: String { self == .teams ? "person.3" : "number" }
}

struct CommunicationNavigation: View {
    @Binding var selected: CommunicationDestination

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CommunicationDestination.allCases) { destination in
                Button {
                    selected = destination
                } label: {
                    HStack(spacing: 6) {
                        BundledAssetIcon(name: destination.assetName, fallbackSymbol: destination.fallbackSymbol, size: 20)
                            .frame(width: 20, height: 20)
                        Text(destination.rawValue)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(selected == destination ? MeetingPilotDesign.accent.opacity(0.36) : Color.adaptiveWhite(0.06))
                    .foregroundStyle(selected == destination ? .white : Color.adaptiveWhite(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

struct TeamsConfigurationSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var detectionDebug = "Premi Debug rilevazione durante una call Teams."
    @State private var destination: CommunicationDestination = .teams
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
        VStack(alignment: .leading, spacing: 10) {
            CommunicationNavigation(selected: $destination)
            if destination == .teams {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: hasMeetingDetails ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(hasMeetingDetails ? MeetingPilotDesign.success : MeetingPilotDesign.accent)
                        .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(localized(hasMeetingDetails ? "Call Teams rilevata" : "In attesa di una call Teams"))
                            .font(.system(size: 15, weight: .semibold))
                        Text(hasMeetingDetails ? model.recording.runtimeTitle : localized("Apri o avvia una riunione Teams per recuperare automaticamente i dettagli."))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MeetingPilotDesign.textDimColor)
                            .lineLimit(2)
                        Text(participantsText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MeetingPilotDesign.textFaintColor)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

                HStack {
                    Button("Recupera da Teams") { model.runTeamsScrape() }
                        .buttonStyle(PrimaryButtonStyle())
                    Text(localized(model.statusMessage))
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                }
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
                .font(.system(size: 13, weight: .semibold))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
            } else {
                SettingsRow(label: "Slack", value: "In arrivo")
            }
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
    Locale(identifier: Bundle.main.preferredLocalizations.first == "en" ? "en_US" : "it_IT")
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
