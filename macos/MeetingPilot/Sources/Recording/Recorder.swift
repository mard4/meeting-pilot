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


struct RecorderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode = "macos_prompt"
    @State private var folder = ""
    @State private var openTarget = ""
    @State private var transcriptionProvider = "fluid"
    @State private var confirmingAppleTranscription = false

    var body: some View {
        ContentPane(title: "Pipeline", subtitle: "Come Meeting Pilot registra, trascrive e sintetizza le riunioni.") {
            if model.needsAccessibilityWarning {
                AccessibilityWarningCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Registrazione")
                    .font(.system(size: 15, weight: .semibold))

                HStack(alignment: .top, spacing: 8) {
                    RecorderChoiceCard(
                        title: "Recorder integrato",
                        subtitle: "Microfono e audio del Mac, senza altre app.",
                        assetName: nil,
                        fallbackSymbol: "apple.logo",
                        selected: mode == "macos_prompt",
                        recommended: true
                    ) {
                        selectRecorderMode("macos_prompt")
                    }
                    RecorderChoiceCard(
                        title: "Recorder esterno",
                        subtitle: "Avanzato · usa TranscribeX, app di terze parti.",
                        assetName: "transcribeX.png",
                        fallbackSymbol: "waveform",
                        selected: mode == "transcribex"
                    ) {
                        selectRecorderMode("transcribex")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if mode == "macos_prompt" {
                    AudioSourceSection()
                }

                if mode == "transcribex" {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 9) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(MeetingPilotDesign.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("App di terze parti, non necessaria")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Serve solo se preferisci TranscribeX al recorder integrato. Scaricalo dal sito ufficiale.")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                            }
                            Spacer()
                            Button {
                                if let url = URL(string: "https://www.transcribex.io/") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            .buttonStyle(CompactButtonStyle())
                            .help("Scarica TranscribeX")
                        }
                    }
                    .padding(10)
                    .background(MeetingPilotDesign.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Text("Trascrizione")
                    .font(.system(size: 15, weight: .semibold))

                HStack(alignment: .top, spacing: 8) {
                    RecorderChoiceCard(
                        title: "Apple On‑Device",
                        subtitle: "Veloce, senza riconoscimento dei parlanti.",
                        assetName: nil,
                        fallbackSymbol: "apple.logo",
                        selected: transcriptionProvider == "apple",
                        recommended: false
                    ) {
                        // Switching away from FluidAudio loses speaker diarization, so confirm first.
                        if transcriptionProvider != "apple" {
                            confirmingAppleTranscription = true
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .alert("Nessun riconoscimento dei parlanti", isPresented: $confirmingAppleTranscription) {
                        Button("Resta su FluidAudio", role: .cancel) {}
                        Button("Usa Apple") {
                            selectTranscriptionProvider("apple")
                        }
                    } message: {
                        Text("Con Apple On‑Device la trascrizione non riconosce i singoli parlanti. FluidAudio invece li riconosce ed è comunque locale e privato: l'audio non lascia il Mac.")
                    }
                    RecorderChoiceCard(
                        title: "FluidAudio",
                        subtitle: "Riconosce chi parla.",
                        assetName: "fluidaudio.png",
                        fallbackSymbol: "waveform.path.ecg",
                        selected: transcriptionProvider == "fluid",
                        recommended: true
                    ) {
                        selectTranscriptionProvider("fluid")
                    }
                    .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Text("Sintesi (AI)")
                    .font(.system(size: 15, weight: .semibold))
                SummaryConfigurationForm()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Text("Teams")
                    .font(.system(size: 15, weight: .semibold))
                TeamsConfigurationSection()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            if mode != "macos_prompt" {
            VStack(alignment: .leading, spacing: 12) {
                if mode == "custom" {
                    VStack(alignment: .leading, spacing: 8) {
                        EditableField(
                            label: "Recorder da aprire",
                            text: $openTarget,
                            placeholder: "/Applications/Nome recorder.app"
                        )
                        Button {
                            if let selected = model.chooseRecorderApp() {
                                openTarget = selected
                            }
                        } label: {
                            Label("Scegli un'app…", systemImage: "app.badge.checkmark")
                        }
                        .buttonStyle(CompactButtonStyle())
                    }
                } else if mode != "macos_prompt" {
                    EditableField(
                        label: "App, cartella o URL da aprire con Avvia",
                        text: $openTarget,
                        placeholder: "/Applications/App.app, cartella audio o URL"
                    )
                }

            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
            }
        }
        .onAppear {
            mode = model.recorderMode
            folder = model.recorderFolder
            openTarget = model.recorderOpenTarget
            transcriptionProvider = model.transcriptionProvider
        }
    }

    private func selectRecorderMode(_ newMode: String) {
        guard mode != newMode else { return }
        mode = newMode
        folder = defaultRecorderFolder(for: newMode)

        switch newMode {
        case "macos_prompt":
            openTarget = ""
        case "custom":
            openTarget = defaultRecorderOpenTarget(for: newMode, folder: folder)
        default:
            openTarget = defaultRecorderOpenTarget(for: newMode, folder: folder)
        }

        // The recorder choice is the primary setting, so persist it immediately.
        // This keeps the Overview and the notification action in sync even if the
        // user changes section without pressing the wider "Salva recorder" button.
        model.saveRecorderSettings(
            mode: mode,
            folder: folder,
            promptEnabled: model.recordingPromptEnabled,
            promptDelaySeconds: model.recordingPromptDelaySeconds,
            openTarget: openTarget,
            transcriptionProvider: transcriptionProvider
        )
    }

    private func selectTranscriptionProvider(_ newProvider: String) {
        guard transcriptionProvider != newProvider else { return }
        transcriptionProvider = newProvider
        if newProvider == "fluid" && !model.fluidAudioInstalled {
            model.statusMessage = "FluidAudio non è disponibile in questa installazione"
            return
        }
        model.saveRecorderSettings(
            mode: mode,
            folder: folder,
            promptEnabled: model.recordingPromptEnabled,
            promptDelaySeconds: model.recordingPromptDelaySeconds,
            openTarget: openTarget,
            transcriptionProvider: transcriptionProvider
        )
    }
}

/// The default source for recordings started by hand; a detected call overrides it.
struct AudioSourceSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MPSectionTitle("Sorgente audio")
            HStack(alignment: .top, spacing: 8) {
                ForEach(RecordingAudioSource.allCases) { source in
                    RecorderChoiceCard(
                        title: source.title,
                        subtitle: source.subtitle,
                        assetName: nil,
                        fallbackSymbol: source.symbol,
                        selected: model.recordingAudioSource == source
                    ) {
                        model.saveRecordingAudioSource(source)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "phone.fill")
                Text(localized("Le call rilevate, come Teams, registrano sempre microfono e audio del Mac."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MeetingPilotDesign.textDimColor)
        }
        .padding(.top, 4)
    }
}

struct RecorderChoiceCard: View {
    let title: String
    let subtitle: String
    let assetName: String?
    let fallbackSymbol: String
    let selected: Bool
    var recommended = false
    /// Can't be chosen right now; the subtitle then explains why, in the warning tone.
    var unavailable = false
    var unavailableActionTitle: String? = nil
    var unavailableAction: () -> Void = {}
    let action: () -> Void

    var body: some View {
        if unavailable {
            card
        } else {
            Button(action: action) { card }
                .buttonStyle(.plain)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? MeetingPilotDesign.accent.opacity(0.34) : Color.adaptiveWhite(0.09))
                    BundledAssetIcon(name: assetName, fallbackSymbol: fallbackSymbol, size: 24)
                }
                .frame(width: 40, height: 40)
                Spacer(minLength: 4)
                if !unavailable {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(selected ? MeetingPilotDesign.accent : Color.adaptiveWhite(0.25))
                }
            }

            Text(localized(title))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.adaptiveWhite())

            if !subtitle.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if unavailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    Text(localized(subtitle))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(unavailable ? MeetingPilotDesign.warning : MeetingPilotDesign.textDimColor)
            }

            if unavailable, let unavailableActionTitle {
                Button(localized(unavailableActionTitle), action: unavailableAction)
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
            } else if recommended {
                Text("CONSIGLIATO")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(selected ? .white : MeetingPilotDesign.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(selected ? MeetingPilotDesign.accent : MeetingPilotDesign.accent.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: selected
                    ? [MeetingPilotDesign.accent.opacity(0.27), MeetingPilotDesign.accent.opacity(0.13)]
                    : [Color.adaptiveWhite(0.07), Color.adaptiveWhite(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? MeetingPilotDesign.accent.opacity(0.85) : Color.adaptiveWhite(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
