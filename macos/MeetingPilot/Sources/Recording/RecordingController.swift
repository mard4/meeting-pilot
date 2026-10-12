import AppKit
import ApplicationServices
import Foundation

/// What the built-in recorder captures when no call is detected (RECORDING_AUDIO_SOURCE).
/// A detected call always records `.both`.
enum RecordingAudioSource: String, CaseIterable, Identifiable {
    /// Only the microphone: an in-person lecture or meeting, everyone in one room.
    case microphone
    /// Only what the Mac plays: an online lecture, webinar or video you don't speak in.
    case system
    /// Microphone and Mac audio: a call, with you and the others on separate tracks.
    case both

    var id: String { rawValue }
    var capturesMicrophone: Bool { self != .system }
    var capturesSystemAudio: Bool { self != .microphone }

    var title: String {
        switch self {
        case .microphone: return "Microfono"
        case .system: return "Audio del Mac"
        case .both: return "Entrambi"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone: return "Lezioni e riunioni in presenza: registra tutta la stanza."
        case .system: return "Lezioni online, webinar e video in cui non parli."
        case .both: return "Tu dal microfono, gli altri dall'audio del Mac."
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        case .both: return "person.2.wave.2.fill"
        }
    }
}

/// The recorder configuration from .env that recording decisions depend on.
struct RecorderSettings {
    var mode: String
    var folder: String
    var openTarget: String
    var promptEnabled: Bool
    var promptDelaySeconds: Int
    var teamsOCREnabled: Bool
    var audioSource: RecordingAudioSource = .both

    static let fallback = RecorderSettings(
        mode: "macos_prompt", folder: "", openTarget: "", promptEnabled: true, promptDelaySeconds: 3, teamsOCREnabled: false
    )
}

/// Meeting detection for a `MeetingPlatform`, the recording prompt, native/external
/// recording and the automatic stop when the call ends, plus the Teams metadata
/// captured meanwhile.
final class RecordingController: ObservableObject {
    @Published var nativeRecordingActive = false
    @Published var nativeRecordingPaused = false
    @Published var externalRecordingActive = false
    @Published var nativeRecordingPath = ""
    /// Started while a call was detected. Only call recordings capture Teams metadata
    /// and stop by themselves when the call ends.
    @Published var nativeRecordingIsCall = false
    @Published var runtimeStatus = "Non ancora letto"
    @Published var runtimeTitle = "-"
    @Published var runtimeParticipants = "-"

    var onStatusMessage: (String) -> Void = { _ in }
    var onNeedsRefresh: () -> Void = {}
    /// Where detection and recording events are written; tests swap it out.
    var log: (String) -> Void = { AppLog.append($0) }
    var settings: () -> RecorderSettings = { .fallback }

    private(set) var externalRecordingStartedAt: Date?

    private let cli: MeetingPilotCLI
    private let platform: MeetingPlatform
    private let nativeRecorder = NativeAudioRecorder()
    private var meetingDetectionTimer: Timer?
    private var teamsMetadataCaptureTimer: Timer?
    private var transcribeXAutomation: TranscribeXAutomation?
    private var teamsMetadataCaptureInProgress = false
    private var reportedAccessibilityMissingForActiveRecording = false
    private var activeRecordingTitle = ""
    private var meetingWasDetected = false
    private var recordingPromptShownForCurrentMeeting = false
    private var switchPromptShownForCurrentCall = false
    private var microphoneWasActive = false
    private var recordingObservedMeeting = false
    private var recordingObservedStrongCallSignal = false
    private var recordingObservedAppAudioInput = false
    private var meetingEndCandidateSince: Date?
    private let automaticStopConfirmationSeconds = 15

    init(cli: MeetingPilotCLI, platform: MeetingPlatform = TeamsPlatform()) {
        self.cli = cli
        self.platform = platform
        nativeRecorder.onStateChange = { [weak self] active, path in
            DispatchQueue.main.async {
                self?.nativeRecordingActive = active
                if !active {
                    self?.nativeRecordingPaused = false
                    self?.nativeRecordingIsCall = false
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
                    self?.log("Registrazione salvata con avviso: \(url.lastPathComponent)\n\(warning.localizedDescription)")
                } else {
                    self?.onStatusMessage("Registrazione completa salvata")
                    self?.log("Registrazione salvata: \(url.lastPathComponent)")
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
            self?.pollMeeting()
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
        meetingWasDetected = false
        recordingPromptShownForCurrentMeeting = false
    }

    func showRecordingPrompt(
        title: String,
        delaySeconds: Int? = nil,
        requiresActiveMeeting: Bool = false
    ) {
        let delay = TimeInterval(max(0, delaySeconds ?? settings().promptDelaySeconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard !requiresActiveMeeting || self.hasActiveAudioMeeting() else {
                self.recordingPromptShownForCurrentMeeting = false
                return
            }
            RecordingPromptWindow.shared.show(
                meetingTitle: title,
                timeoutSeconds: 15,
                onRecord: { [weak self] _ in
                    self?.handleRecordAction(meetingTitle: title)
                }
            )
        }
    }

    /// The visible meeting's title, or the platform's generic one.
    func currentMeetingPromptTitle() -> String {
        platform.meetingPromptTitle() ?? platform.fallbackMeetingTitle
    }

    /// With a call in progress Record means the call; otherwise the built-in recorder asks
    /// what to capture, starting from the default in Settings.
    func showManualRecordingPrompt() {
        let settings = settings()
        guard settings.mode == "macos_prompt", !hasActiveAudioMeeting() else {
            showRecordingPrompt(title: currentMeetingPromptTitle(), delaySeconds: 0)
            return
        }
        RecordingPromptWindow.shared.show(
            meetingTitle: "",
            timeoutSeconds: 30,
            audioSource: settings.audioSource,
            onRecord: { [weak self] source in
                self?.handleRecordAction(meetingTitle: localized("Registrazione"), source: source ?? settings.audioSource)
            }
        )
    }

    /// `source` only applies when no call is detected: a call in progress when Record is
    /// pressed is always recorded whole, with both microphone and Mac audio.
    func handleRecordAction(meetingTitle: String, source: RecordingAudioSource = .both) {
        let settings = settings()
        let isCall = hasActiveAudioMeeting()
        if settings.mode == "macos_prompt" {
            if isCall { warnAboutMissingAccessibilityBeforeRecording() }
            startNativeRecording(title: meetingTitle, source: isCall ? .both : source, isCall: isCall)
            return
        }
        warnAboutMissingAccessibilityBeforeRecording()
        if settings.mode == "transcribex" {
            startTranscribeXRecording(title: meetingTitle, folder: settings.folder)
            return
        }
        beginExternalRecordingState(title: meetingTitle)
        openRecorderTarget()
        onNeedsRefresh()
    }

    func startNativeRecording(title: String, source: RecordingAudioSource = .both, isCall: Bool = true) {
        nativeRecorder.start(
            folder: URL(fileURLWithPath: settings().folder),
            title: title,
            source: source,
            isCall: isCall
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.onStatusMessage("Registrazione avviata")
                    self.nativeRecordingPath = url.path
                    self.nativeRecordingIsCall = isCall
                    self.switchPromptShownForCurrentCall = false
                    if isCall {
                        self.startAutomaticTeamsMetadataCapture(title: title)
                        self.observeCallAtRecordingStart()
                    }
                    self.log("Registrazione avviata (\(source.rawValue)\(isCall ? ", call" : "")): \(url.lastPathComponent)")
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
            log("Registrazione nativa ripresa")
        } else {
            guard nativeRecorder.pause() else {
                onStatusMessage("Non riesco a mettere in pausa la registrazione")
                return
            }
            nativeRecordingPaused = true
            onStatusMessage("Registrazione in pausa")
            log("Registrazione nativa in pausa")
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

    /// Called every couple of seconds: prompts when a call starts, or watches for
    /// its end while recording.
    func pollMeeting() {
        if nativeRecordingActive {
            if nativeRecordingIsCall {
                monitorAutomaticRecordingStop()
            } else {
                offerSwitchToCallIfNeeded()
            }
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

        let title = platform.meetingPromptTitle()
        let appInputActive = platform.processIsRunningInput() == true
        let activeMeeting = title != nil && appInputActive
        let meetingJustStarted = activeMeeting && !meetingWasDetected
        meetingWasDetected = activeMeeting

        guard let title, activeMeeting else {
            runtimeStatus = title == nil
                ? "Nessuna call \(platform.displayName) rilevata"
                : "\(platform.displayName) aperto, nessuna call audio attiva"
            recordingPromptShownForCurrentMeeting = false
            return
        }

        guard meetingJustStarted || microphoneJustActivated else {
            runtimeStatus = "Call \(platform.displayName) rilevata: \(title)"
            return
        }
        guard !recordingPromptShownForCurrentMeeting else { return }

        runtimeStatus = "Call \(platform.displayName) rilevata: \(title)"
        recordingPromptShownForCurrentMeeting = true
        showRecordingPrompt(title: title, requiresActiveMeeting: true)
    }

    /// A microphone or Mac-audio recording never stops by itself. When a call starts
    /// meanwhile, offer once per call to save it and record the call instead.
    private func offerSwitchToCallIfNeeded() {
        guard let title = platform.meetingPromptTitle(), platform.processIsRunningInput() == true else {
            switchPromptShownForCurrentCall = false
            return
        }
        runtimeStatus = "Call \(platform.displayName) rilevata: \(title)"
        guard !switchPromptShownForCurrentCall else { return }
        switchPromptShownForCurrentCall = true
        let delay = TimeInterval(max(0, settings().promptDelaySeconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.nativeRecordingActive, !self.nativeRecordingIsCall, self.hasActiveAudioMeeting() else { return }
            RecordingPromptWindow.shared.show(
                meetingTitle: title,
                timeoutSeconds: 15,
                actionTitle: "Passa alla call",
                onRecord: { [weak self] _ in
                    self?.switchToCallRecording(title: title)
                }
            )
        }
    }

    /// Saves the running recording as its own meeting and starts recording the call right
    /// away; the first file is finished in the background.
    private func switchToCallRecording(title: String) {
        guard nativeRecordingActive, !nativeRecordingIsCall else { return }
        if let url = nativeRecorder.stopWithoutWaiting() {
            log("Registrazione salvata per passare alla call \(platform.displayName): \(url.lastPathComponent)")
        }
        nativeRecordingPaused = false
        handleRecordAction(meetingTitle: title)
    }

    private func warnAboutMissingAccessibilityBeforeRecording() {
        guard !AXIsProcessTrusted() else { return }
        onStatusMessage("Registrazione avviata senza Accessibilità: titolo e partecipanti Teams potrebbero mancare")
        log("Avviso: registrazione avviata senza Accessibilità; metadati Teams non disponibili")
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
                    self.log("Registrazione TranscribeX avviata automaticamente per: \(title)")
                case .failure(let error):
                    self.externalRecordingDidFinish()
                    self.onStatusMessage("TranscribeX non ha avviato la registrazione")
                    self.log("Avvio automatico TranscribeX fallito: \(error.localizedDescription)")
                    presentErrorAlert("Non riesco ad avviare TranscribeX", detail: error.localizedDescription)
                }
                self.onNeedsRefresh()
            }
        }
    }

    private func beginExternalRecordingState(title: String) {
        externalRecordingActive = true
        externalRecordingStartedAt = Date()
        observeCallAtRecordingStart()
        runtimeStatus = "Registrazione esterna in corso"
        log("Recorder esterno avviato per: \(title)")
        startAutomaticTeamsMetadataCapture(title: title)
    }

    private func observeCallAtRecordingStart() {
        let snapshot = platform.windowSnapshot()
        let appInput = platform.processIsRunningInput()
        recordingObservedStrongCallSignal = snapshot.callSignal
        recordingObservedAppAudioInput = appInput == true
        recordingObservedMeeting = appInput == true || snapshot.callSignal || snapshot.titles.contains { platform.looksLikeMeetingTitle($0) }
        meetingEndCandidateSince = nil
    }

    private func resetObservedCall() {
        recordingObservedMeeting = false
        recordingObservedStrongCallSignal = false
        recordingObservedAppAudioInput = false
        meetingEndCandidateSince = nil
    }

    private func finishNativeRecording(automatic: Bool) {
        stopAutomaticTeamsMetadataCapture()
        let url = nativeRecorder.stop()
        resetObservedCall()
        nativeRecordingPaused = false
        onStatusMessage(url == nil
            ? "Registrazione fermata"
            : (automatic ? "Call terminata: preparo l'audio completo..." : "Preparo l'audio completo..."))
        if let url {
            log("Stop registrazione\(automatic ? " automatico" : "") richiesto: preparo \(url.lastPathComponent)")
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
                log("Acquisizione partecipanti sospesa: Meeting Pilot non dispone di Accessibilità")
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
                // AppleScript's -2700 "is not running" also lands in accessibility_error;
                // that's Teams being closed, not a missing permission.
                if accessibilityError.contains("is not running") && participants.isEmpty {
                    self.log("Metadati Teams non disponibili: Teams non è aperto")
                } else if !accessibilityError.isEmpty && participants.isEmpty {
                    self.onStatusMessage("Consenti Accessibilità a Meeting Pilot per recuperare i partecipanti")
                    self.log("Metadati Teams non disponibili: manca il permesso Accessibilità\n\(output)")
                } else if payload?["confidence"] != nil {
                    self.log("Metadati Teams aggiornati automaticamente")
                    self.onNeedsRefresh()
                } else {
                    self.log("Acquisizione automatica metadati Teams non riuscita: \(output)")
                }
            }
        }
    }

    private func hasActiveAudioMeeting() -> Bool {
        platform.meetingPromptTitle() != nil && platform.processIsRunningInput() == true
    }

    private func monitorAutomaticRecordingStop() {
        let snapshot = platform.windowSnapshot()
        let titleLooksLikeMeeting = snapshot.titles.contains { platform.looksLikeMeetingTitle($0) }
        let appInput = platform.processIsRunningInput()

        if appInput == true {
            recordingObservedAppAudioInput = true
            recordingObservedMeeting = true
            if meetingEndCandidateSince != nil {
                log("Stop automatico annullato: \(platform.displayName) usa nuovamente il microfono")
            }
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione call \(platform.displayName) in corso"
            return
        }

        if recordingObservedAppAudioInput && appInput == false {
            beginOrCompleteAutomaticStop(reason: "\(platform.displayName) non usa più il microfono")
            return
        }

        if snapshot.callSignal {
            recordingObservedMeeting = true
            recordingObservedStrongCallSignal = true
            if meetingEndCandidateSince != nil {
                log("Stop automatico annullato: controlli call \(platform.displayName) nuovamente presenti")
            }
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione call \(platform.displayName) in corso"
            return
        }

        // After seeing actual in-call controls, their disappearance is the
        // meaningful end signal. The app may keep a recap/window with the same
        // meeting title open after hang-up, so that title must not block stop.
        if !recordingObservedStrongCallSignal && titleLooksLikeMeeting {
            recordingObservedMeeting = true
            if meetingEndCandidateSince != nil {
                log("Stop automatico annullato: finestra call \(platform.displayName) nuovamente presente")
            }
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione call \(platform.displayName) in corso"
            return
        }

        // Never auto-stop if Accessibility never let us observe a real meeting
        // window. In that case the explicit Stop action remains the safe path.
        guard recordingObservedMeeting else { return }
        beginOrCompleteAutomaticStop(reason: "Controlli call \(platform.displayName) scomparsi")
    }

    private func monitorExternalRecordingState() {
        let snapshot = platform.windowSnapshot()
        let titleLooksLikeMeeting = snapshot.titles.contains { platform.looksLikeMeetingTitle($0) }
        let appInput = platform.processIsRunningInput()

        if appInput == true || snapshot.callSignal || (!recordingObservedStrongCallSignal && titleLooksLikeMeeting) {
            recordingObservedMeeting = true
            recordingObservedAppAudioInput = recordingObservedAppAudioInput || appInput == true
            recordingObservedStrongCallSignal = recordingObservedStrongCallSignal || snapshot.callSignal
            meetingEndCandidateSince = nil
            runtimeStatus = "Registrazione esterna in corso"
            return
        }

        guard recordingObservedMeeting else { return }
        if meetingEndCandidateSince == nil {
            meetingEndCandidateSince = Date()
            runtimeStatus = "Verifico fine call \(platform.displayName)..."
            return
        }
        let elapsed = Date().timeIntervalSince(meetingEndCandidateSince ?? Date())
        guard elapsed >= Double(automaticStopConfirmationSeconds) else {
            runtimeStatus = "Fine call rilevata: attendo conferma..."
            return
        }

        externalRecordingDidFinish()
        resetObservedCall()
        runtimeStatus = "Call terminata: attendo il file audio"
        log("Call con recorder esterno terminata: attendo il file audio completo")
        onNeedsRefresh()
    }

    private func beginOrCompleteAutomaticStop(reason: String) {
        if meetingEndCandidateSince == nil {
            meetingEndCandidateSince = Date()
            log("\(reason): avvio attesa stop automatico di \(automaticStopConfirmationSeconds) secondi")
            runtimeStatus = "Verifico fine call \(platform.displayName)..."
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
