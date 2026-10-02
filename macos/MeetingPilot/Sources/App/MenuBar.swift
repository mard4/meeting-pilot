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


struct MenuBarOverview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    let openApp: () -> Void
    let openChat: () -> Void
    let openDiary: () -> Void

    private var pipelineSteps: [PipelineStep] {
        let stage = model.pipelineStage
        return [
            PipelineStep(title: "Rileva", state: stage == 0 ? .active : .done),
            PipelineStep(title: "Registra", state: menuBarState(for: 1, current: stage)),
            PipelineStep(title: "Trascrive", state: menuBarState(for: 2, current: stage)),
            PipelineStep(title: "Sintesi", state: menuBarState(for: 3, current: stage)),
            PipelineStep(title: "Pubblica", state: menuBarState(for: 4, current: stage))
        ]
    }

    private var liveSidebarAvailable: Bool {
        model.recording.nativeRecordingActive && !model.recording.nativeRecordingPath.isEmpty
    }

    /// Icon and short title sharing the row equally; long translations scale down
    /// rather than push the row past the popover's width.
    private func menuButtonLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(localized(title))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    private func menuBarState(for step: Int, current: Int) -> StepState {
        if current >= 5 || current > step { return .done }
        if current == step { return .active }
        return .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandTile(size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting Pilot")
                        .font(.mpDisplay(12))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.watcher.watcherActive ? MeetingPilotDesign.success : MeetingPilotDesign.warning)
                            .frame(width: 6, height: 6)
                        Text(localized(model.recording.nativeRecordingActive
                            ? (model.recording.nativeRecordingPaused ? "Registrazione in pausa" : "Registrazione in corso")
                            : (model.watcher.watcherActive ? "Rilevamento attivo" : "Rilevamento in pausa")))
                            .font(.system(size: 11))
                            .foregroundStyle(MeetingPilotDesign.textDimColor)
                    }
                }
                Spacer()
                RecordingControls(compact: true)
            }

            HStack(spacing: 0) {
                ForEach(Array(pipelineSteps.enumerated()), id: \.element.id) { index, step in
                    VStack(spacing: 3) {
                        StepDot(state: step.state, count: step.count, number: index + 1)
                            .scaleEffect(0.7)
                            .frame(height: 24)
                        Text(localized(step.title))
                            .font(.system(size: 9, weight: step.state == .active ? .semibold : .regular))
                            .foregroundStyle(step.state == .pending ? MeetingPilotDesign.textFaintColor : MeetingPilotDesign.textColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .help(localized(step.title))
                }
            }
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))

            if let session = model.processingSessions.first {
                Button(action: openApp) {
                    MenuBarProcessingRow(session: session)
                }
                .buttonStyle(.plain)
                .help("Apri Meeting Pilot per gestire l'elaborazione")
            }

            MPEyebrow("Riunioni di oggi")

            if model.todayMeetings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Nessuna riunione completata oggi"))
                        .font(.system(size: 12, weight: .medium))
                    Text(localized("Le nuove trascrizioni compariranno qui."))
                        .font(.system(size: 11))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(model.todayMeetings.prefix(model.processingSessions.isEmpty ? 3 : 2))) { meeting in
                        MenuBarMeetingRow(meeting: meeting, action: openApp)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button(action: openApp) {
                    menuButtonLabel("Apri", systemImage: "macwindow")
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
                .help(localized("Apri Meeting Pilot"))
                Button(action: openChat) {
                    menuButtonLabel("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
                .help(localized("Apri la chat delle riunioni"))
                // The live sidebar belongs to the recording's audio file, so it only
                // exists while a native recording is running.
                Button {
                    LiveSidebarWindow.shared.toggle(audioFileURL: URL(fileURLWithPath: model.recording.nativeRecordingPath))
                } label: {
                    menuButtonLabel("Sidebar", systemImage: "sidebar.right")
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
                .disabled(!liveSidebarAvailable)
                .help(localized(liveSidebarAvailable
                    ? "Mostra la sidebar dal vivo con trascrizione e parlanti"
                    : "La sidebar dal vivo è disponibile durante una registrazione"))
                Button(action: openDiary) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
                .fixedSize()
                .help(localized("Apri Diario"))
            }
        }
        .padding(14)
        .frame(width: 320, height: 330, alignment: .topLeading)
        .background(MeetingPilotBackdrop())
        .foregroundStyle(MeetingPilotDesign.textColor)
        .tint(MeetingPilotDesign.accent)
    }
}

private struct MenuBarMeetingRow: View {
    let meeting: MeetingItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(MeetingPilotDesign.success).frame(width: 5, height: 5)
                Text(meeting.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(meeting.dateText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? MeetingPilotDesign.hoverColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuBarProcessingRow: View {
    let session: ProcessingSession

    var body: some View {
        let failed = session.stage == .failed
        HStack(spacing: 8) {
            Image(systemName: session.stage.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(failed ? MeetingPilotDesign.warning : MeetingPilotDesign.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill((failed ? MeetingPilotDesign.warning : MeetingPilotDesign.accent).opacity(0.13)))
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            MPBadge(text: session.stage.title, tone: failed ? .warning : .accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MeetingPilotDesign.accentTint.opacity(failed ? 0 : 1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((failed ? MeetingPilotDesign.warning : MeetingPilotDesign.accent).opacity(0.25), lineWidth: 1))
    }
}
