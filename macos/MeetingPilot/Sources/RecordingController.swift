import AppKit
import ApplicationServices
import Foundation

/// The recorder configuration from .env that recording decisions depend on.
struct RecorderSettings {
    var mode: String
    var folder: String
    var openTarget: String
    var promptEnabled: Bool
    var promptDelaySeconds: Int
    var teamsOCREnabled: Bool

    static let fallback = RecorderSettings(
        mode: "macos_prompt", folder: "", openTarget: "", promptEnabled: true, promptDelaySeconds: 3, teamsOCREnabled: false
    )
}

/// Teams meeting detection, the recording prompt, native/external recording and the
/// automatic stop when the call ends, plus the Teams metadata captured meanwhile.
final class RecordingController: ObservableObject {
    @Published var nativeRecordingActive = false
    @Published var nativeRecordingPaused = false
    @Published var externalRecordingActive = false
    @Published var nativeRecordingPath = ""
    @Published var runtimeStatus = "Non ancora letto"
    @Published var runtimeTitle = "-"
    @Published var runtimeParticipants = "-"

    var onStatusMessage: (String) -> Void = { _ in }
    var onNeedsRefresh: () -> Void = {}
    var settings: () -> RecorderSettings = { .fallback }

    private(set) var externalRecordingStartedAt: Date?

    private let cli: MeetingPilotCLI
    private let nativeRecorder = NativeAudioRecorder()
    private var meetingDetectionTimer: Timer?
    private var teamsMetadataCaptureTimer: Timer?
    private var transcribeXAutomation: TranscribeXAutomation?
    private var teamsMetadataCaptureInProgress = false
    private var reportedAccessibilityMissingForActiveRecording = false
    private var activeRecordingTitle = ""
    private var teamsMeetingWasDetected = false
    private var recordingPromptShownForCurrentMeeting = false
    private var microphoneWasActive = false
    private var recordingObservedTeamsMeeting = false
    private var recordingObservedStrongCallSignal = false
    private var recordingObservedTeamsAudioInput = false
    private var meetingEndCandidateSince: Date?
    private let automaticStopConfirmationSeconds = 15

    init(cli: MeetingPilotCLI) {
        self.cli = cli
        nativeRecorder.onStateChange = { [weak self] active, path in
            DispatchQueue.main.async {
                self?.nativeRecordingActive = active
                if !active {
                    self?.nativeRecordingPaused = false
                }
                self?.nativeRecordingPath = path?.path ?? ""
                if active {
                    LiveSidebarWindow.shared.show(audioFileURL: path)
                } else {
                    LiveSidebarWindow.shared.close()
                }
            }
        }
        nativeRecorder.onFinished = { [weak self] url, warning in
            DispatchQueue.main.async {
                if let warning {
                    self?.onStatusMessage("Registrazione salvata con avviso")
                    AppLog.append("Registrazione salvata con avviso: \(url.lastPathComponent)\n\(warning.localizedDescription)")
                } else {
                    self?.onStatusMessage("Registrazione completa salvata")
                    AppLog.append("Registrazione audio sistema + microfono salvata: \(url.lastPathComponent)")
                }
                self?.onNeedsRefresh()
            }
        }
    }

    var hasActiveRecording: Bool {
        nativeRecordingActive || externalRecordingActive
    }

    func startMeetingDetectionMonitor() {
        meetingDetectionTimer?.invalidate()
        meetingDetectionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollTeamsMeeting()
        }
    }

    func applyRuntimeMetadata(_ runtime: RuntimeMetadataSnapshot) {
        runtimeStatus = runtime.status
        runtimeTitle = runtime.title
        runtimeParticipants = runtime.participants
    }

    /// The refresh snapshot saw the external recorder's audio file land in the inbox.
    func externalRecordingDidFinish() {
        externalRecordingActive = false
        externalRecordingStartedAt = nil
        stopAutomaticTeamsMetadataCapture()
    }

    /// After a recorder change, prompt again for a meeting that is already in progress
    /// instead of waiting for the next one.
    func resetMeetingDetection() {
        teamsMeetingWasDetected = false
        recordingPromptShownForCurrentMeeting = false
    }

    func showRecordingPrompt(
        title: String,
        delaySeconds: Int? = nil,
        requiresActiveTeamsMeeting: Bool = false
    ) {
        let delay = TimeInterval(max(0, delaySeconds ?? settings().promptDelaySeconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard !requiresActiveTeamsMeeting || self.hasActiveTeamsAudioMeeting() else {
                self.recordingPromptShownForCurrentMeeting = false
                return
            }
            RecordingPromptWindow.shared.show(
                meetingTitle: title,
                timeoutSeconds: 15,
                onRecord: { [weak self] in
                    self?.handleRecordAction(meetingTitle: title)
                }
            )
        }
    }

    func showManualRecordingPrompt() {
        let title = currentTeamsMeetingPromptTitle() ?? "Riunione Teams"
        showRecordingPrompt(title: title, delaySeconds: 0)
    }

    func handleRecordAction(meetingTitle: String) {
        warnAboutMissingAccessibilityBeforeRecording()
        let settings = settings()
        if settings.mode == "macos_prompt" {
            startNativeRecording(title: meetingTitle)
            return
        }
        if settings.mode == "transcribex" {
            startTranscribeXRecording(title: meetingTitle, folder: settings.folder)
            return
        }
        beginExternalRecordingState(title: meetingTitle)
        openRecorderTarget()
        onNeedsRefresh()
    }

    func startNativeRecording(title: String) {
        nativeRecorder.start(folder: URL(fileURLWithPath: settings().folder), title: title) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.onStatusMessage("Registrazione avviata")
                    self.nativeRecordingPath = url.path
                    self.startAutomaticTeamsMetadataCapture(title: title)
                    self.observeTeamsCallAtRecordingStart()
                    AppLog.append("Registrazione avviata: \(url.lastPathComponent)")
                case .failure(let error):
                    self.onStatusMessage("Recorder non avviato")
                    presentErrorAlert("Non riesco ad avviare il recorder macOS", detail: error.localizedDescription)
                }
                self.onNeedsRefresh()
            }
        }
    }

    func stopNativeRecording() {
        guard nativeRecordingActive else {
            onStatusMessage("Nessuna registrazione attiva")
            return
        }
        finishNativeRecording(automatic: false)
    }

    func toggleNativeRecordingPause() {
        guard nativeRecordingActive else {
            showManualRecordingPrompt()
            return
        }
        if nativeRecordingPaused {
            guard nativeRecorder.resume() else {
                onStatusMessage("Non riesco a riprendere la registrazione")
                return
            }
            nativeRecordingPaused = false
            onStatusMessage("Registrazione ripresa")
            AppLog.append("Registrazione nativa ripresa")
        } else {
            guard nativeRecorder.pause() else {
                onStatusMessage("Non riesco a mettere in pausa la registrazione")
                return
            }
            nativeRecordingPaused = true
            onStatusMessage("Registrazione in pausa")
            AppLog.append("Registrazione nativa in pausa")
        }
        onNeedsRefresh()
    }

    func openRecorderTarget() {
        let settings = settings()
        let target = settings.openTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: settings.folder))
            return
        }
        if target.hasPrefix("/") || target.hasPrefix("~") {
            NSWorkspace.shared.open(expandPath(target))
            return
        }
        if let url = URL(string: target), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.run("/usr/bin/open", ["-a", target])
        }
    }

    /// Called every couple of seconds: prompts when a Teams call starts, or watches for
    /// its end while recording.
    func pollTeamsMeeting() {
        if nativeRecordingActive {
            monitorAutomaticRecordingStop()
            return
        }
        if externalRecordingActive {
            monitorExternalRecordingState()
            return
        }
        guard settings().promptEnabled else { return }

        let microphoneActive = defaultInputDeviceIsRunning()
        let microphoneJustActivated = microphoneActive && !microphoneWasActive
        microphoneWasActive = microphoneActive

        let title = currentTeamsMeetingPromptTitle()
        let teamsInputActive = teamsProcessIsRunningInput() == true
        let activeTeamsMeeting = title != nil && teamsInputActive
        let meetingJustStarted = activeTeamsMeeting && !teamsMeetingWasDetected
        teamsMeetingWasDetected = activeTeamsMeeting

        guard let title, activeTeamsMeeting else {
            runtimeStatus = title == nil
                ? "Nessuna call Teams rilevata"
                : "Teams aperto, nessuna call audio attiva"
            recordingPromptShownForCurrentMeeting = false
            return
        }

        guard meetingJustStarted || microphoneJustActivated else {
            runtimeStatus = "Call Teams rilevata: \(title)"
            return
        }
        guard !recordingPromptShownForCurrentMeeting else { return }

        runtimeStatus = "Call Teams rilevata: \(title)"
        recordingPromptShownForCurrentMeeting = true
        showRecordingPrompt(title: title, requiresActiveTeamsMeeting: true)
    }

    private func warnAboutMissingAccessibilityBeforeRecording() {
        guard !AXIsProcessTrusted() else { return }
        onStatusMessage("Registrazione avviata senza Accessibilità: titolo e partecipanti Teams potrebbero mancare")
        AppLog.append("Avviso: registrazione avviata senza Accessibilità; metadati Teams non disponibili")
        requestAccessibilityPermission()
    }

    private func startTranscribeXRecording(title: String, folder: String) {
        guard AXIsProcessTrusted() else {
            onStatusMessage("Accessibilità richiesta per comandare TranscribeX")
            requestAccessibilityPermission()
            presentErrorAlert(
                "Consenti Accessibilità a Meeting Pilot",
                detail: "Per avviare automaticamente TranscribeX, abilita Meeting Pilot in Impostazioni di Sistema > Privacy e sicurezza > Accessibilità, poi premi nuovamente Avvia."
            )
            return
        }

        onStatusMessage("Avvio automatico di TranscribeX...")
        runtimeStatus = "Apro TranscribeX e avvio la registrazione"
        let automation = TranscribeXAutomation(outputFolder: URL(fileURLWithPath: folder))
        transcribeXAutomation = automation
        automation.start { [weak self, weak automation] result in
            DispatchQueue.main.async {
                guard let self, self.transcribeXAutomation === automation else { return }
                self.transcribeXAutomation = nil
                switch result {
                case .success:
                    self.beginExternalRecordingState(title: title)
                    self.onStatusMessage("TranscribeX sta registrando")
                    AppLog.append("Registrazione TranscribeX avviata automaticamente per: \(title)")
                case .failure(let error):
                    self.externalRecordingDidFinish()
                    self.onStatusMessage("TranscribeX non ha avviato la registrazione")
                    AppLog.append("Avvio automatico TranscribeX fallito: \(error.localizedDescription)")
                    presentErrorAlert("Non riesco ad avviare TranscribeX", detail: error.localizedDescription)
                }
                self.onNeedsRefresh()
            }
        }
    }

    private func beginExternalRecordingState(title: String) {
        externalRecordingActive = true
        externalRecordingStartedAt = Date()
        observeTeamsCallAtRecordingStart()
        runtimeStatus = "Registrazione esterna in corso"
        AppLog.append("Recorder esterno avviato per: \(title)")
        startAutomaticTeamsMetadataCapture(title: title)
    }

    private func observeTeamsCallAtRecordingStart() {
        let snapshot = teamsWindowSnapshot()
        let teamsInput = teamsProcessIsRunningInput()
        recordingObservedStrongCallSignal = snapshot.callSignal
        recordingObservedTeamsAudioInput = teamsInput == true
        recordingObservedTeamsMeeting = teamsInput == true || snapshot.callSignal || snapshot.titles.contains { looksLikeTeamsMeetingTitle($0) }
        meetingEndCandidateSince = nil
    }

    private func resetObservedTeamsCall() {
        recordingObservedTeamsMeeting = false
        recordingObservedStrongCallSignal = false
        recordingObservedTeamsAudioInput = false
        meetingEndCandidateSince = nil
    }

    private func finishNativeRecording(automatic: Bool) {
        stopAutomaticTeamsMetadataCapture()
        let url = nativeRecorder.stop()
        resetObservedTeamsCall()
        nativeRecordingPaused = false
        onStatusMessage(url == nil
            ? "Registrazione fermata"
            : (automatic ? "Call terminata: preparo l'audio completo..." : "Preparo l'audio completo..."))
        if let url {
            AppLog.append("Stop registrazione\(automatic ? " automatico" : "") richiesto: unisco audio di sistema e microfono in \(url.lastPathComponent)")
        }
        onNeedsRefresh()
    }

    private func startAutomaticTeamsMetadataCapture(title: String) {
        teamsMetadataCaptureTimer?.invalidate()
        activeRecordingTitle = title
        reportedAccessibilityMissingForActiveRecording = false
        // Automatic polling must never steal focus from the app the person is using.
        captureTeamsMetadata(merge: false, openParticipants: false)
        teamsMetadataCaptureTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.captureTeamsMetadata(merge: true, openParticipants: false)
        }
        if let teamsMetadataCaptureTimer {
            RunLoop.main.add(teamsMetadataCaptureTimer, forMode: .common)
        }
    }

    private func stopAutomaticTeamsMetadataCapture() {
        teamsMetadataCaptureTimer?.invalidate()
        teamsMetadataCaptureTimer = nil
        activeRecordingTitle = ""
        reportedAccessibilityMissingForActiveRecording = false
    }

    private func captureTeamsMetadata(
        merge: Bool,
        openParticipants: Bool,
        allowForegroundFallback: Bool = false
    ) {
        guard AXIsProcessTrusted() else {
            if !reportedAccessibilityMissingForActiveRecording {
                reportedAccessibilityMissingForActiveRecording = true
                onStatusMessage("Accessibilità non disponibile: partecipanti non acquisiti")
                AppLog.append("Acquisizione partecipanti sospesa: Meeting Pilot non dispone di Accessibilità")
            }
            return
        }
        guard !teamsMetadataCaptureInProgress else { return }
        teamsMetadataCaptureInProgress = true
        let title = activeRecordingTitle
        let ocrEnabled = settings().teamsOCREnabled
        let cli = cli
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var arguments = ["teams-scrape"]
            if !(ocrEnabled && allowForegroundFallback) { arguments.append("--no-ocr") }
            arguments += ["--title-hint", title]
            if merge { arguments.append("--merge") }
            if openParticipants { arguments.append("--open-participants") }
            let output = cli.run(arguments, environment: MeetingPilotCLI.teamsHelperEnvironment)
            DispatchQueue.main.async {
                guard let self else { return }
                self.teamsMetadataCaptureInProgress = false
                let payload = output.data(using: .utf8).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
                let accessibilityError = (payload?["accessibility_error"] as? String) ?? ""
                let participants = (payload?["participants"] as? [String]) ?? []
                if !accessibilityError.isEmpty && participants.isEmpty {
                    self.onStatusMessage("Consenti Accessibilità a Meeting Pilot per recuperare i partecipanti")
                    AppLog.append("Metadati Teams non disponibili: manca il permesso Accessibilità\n\(output)")
                } else if payload?["confidence"] != nil {
                    AppLog.append("Metadati Teams aggiornati automaticamente")
                    self.onNeedsRefresh()
                } else {
                    AppLog.append("Acquisizione automatica metadati Teams non riuscita: \(output)")
                }
            }
        }
    }

    private func hasActiveTeamsAudioMeeting() -> Bool {
        currentTeamsMeetingPromptTitle() != nil && teamsProcessIsRunningInput() == true
    }

    private func monitorAutomaticRecordingStop() {
        let snapshot = teamsWindowSnapshot()
        let titleLooksLikeMeeting = snapshot.titles.contains { looksLikeTeamsMeetingTitle($0) }
        let teamsInput = teamsProcessIsRunningInput()

        if teamsInput == true {
            recordingObservedTeamsAudioInput = true
            recordingObservedTeamsMeeting = true
            if meetingEndCandidateSince != nil {
                AppLog.append("Stop automatico annullato: Teams usa nuovamente il microfono")
            }
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione call Teams in corso"
            return
        }

        if recordingObservedTeamsAudioInput && teamsInput == false {
            beginOrCompleteAutomaticStop(reason: "Teams non usa più il microfono")
            return
        }

        if snapshot.callSignal {
            recordingObservedTeamsMeeting = true
            recordingObservedStrongCallSignal = true
            if meetingEndCandidateSince != nil {
                AppLog.append("Stop automatico annullato: controlli call Teams nuovamente presenti")
            }
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione call Teams in corso"
            return
        }

        // After seeing actual in-call controls, their disappearance is the
        // meaningful end signal. Teams may keep a recap/window with the same
        // meeting title open after hang-up, so that title must not block stop.
        if !recordingObservedStrongCallSignal && titleLooksLikeMeeting {
            recordingObservedTeamsMeeting = true
            if meetingEndCandidateSince != nil {
                AppLog.append("Stop automatico annullato: finestra call Teams nuovamente presente")
            }
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione call Teams in corso"
            return
        }

        // Never auto-stop if Accessibility never let us observe a real meeting
        // window. In that case the explicit Stop action remains the safe path.
        guard recordingObservedTeamsMeeting else { return }
        beginOrCompleteAutomaticStop(reason: "Controlli call Teams scomparsi")
    }

    private func monitorExternalRecordingState() {
        let snapshot = teamsWindowSnapshot()
        let titleLooksLikeMeeting = snapshot.titles.contains { looksLikeTeamsMeetingTitle($0) }
        let teamsInput = teamsProcessIsRunningInput()

        if teamsInput == true || snapshot.callSignal || (!recordingObservedStrongCallSignal && titleLooksLikeMeeting) {
            recordingObservedTeamsMeeting = true
            recordingObservedTeamsAudioInput = recordingObservedTeamsAudioInput || teamsInput == true
            recordingObservedStrongCallSignal = recordingObservedStrongCallSignal || snapshot.callSignal
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione esterna in corso"
            return
        }

        guard recordingObservedTeamsMeeting else { return }
        if meetingEndCandidateSince == nil {
            meetingEndCandidateSince = Date()
            runtimeStatus = "Verifico fine call Teams..."
            return
        }
        let elapsed = Date().timeIntervalSince(meetingEndCandidateSince ?? Date())
        guard elapsed >= Double(automaticStopConfirmationSeconds) else {
            runtimeStatus = "Fine call rilevata: attendo conferma..."
            return
        }

        externalRecordingDidFinish()
        resetObservedTeamsCall()
        runtimeStatus = "Call terminata: attendo il file audio"
        AppLog.append("Call con recorder esterno terminata: attendo il file audio completo")
        onNeedsRefresh()
    }

    private func beginOrCompleteAutomaticStop(reason: String) {
        if meetingEndCandidateSince == nil {
            meetingEndCandidateSince = Date()
            AppLog.append("\(reason): avvio attesa stop automatico di \(automaticStopConfirmationSeconds) secondi")
            runtimeStatus = "Verifico fine call Teams..."
            return
        }
        let elapsed = Date().timeIntervalSince(meetingEndCandidateSince ?? Date())
        let remaining = max(0, automaticStopConfirmationSeconds - Int(elapsed))
        runtimeStatus = "Fine call rilevata: salvataggio tra \(remaining)s"
        if elapsed >= Double(automaticStopConfirmationSeconds) {
            finishNativeRecording(automatic: true)
        }
    }
}
