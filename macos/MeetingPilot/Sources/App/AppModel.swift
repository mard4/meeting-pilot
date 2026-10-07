import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import FoundationModels
import Speech
import ServiceManagement
import Combine
import SwiftUI
import UserNotifications


final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection = .dashboard
    @Published var todayProcessed = 0
    @Published var queueCount = 0
    @Published var providerMode = "apple"
    @Published var remoteProviderKind = "gpt"
    @Published var providerModel = "-"
    @Published var localProviderModel = ""
    @Published var remoteProviderModel = ""
    @Published var providerBaseURL = ""
    @Published var localProviderBaseURL = ""
    @Published var remoteProviderBaseURL = ""
    @Published var providerAPIKey = ""
    @Published var localProviderAPIKey = ""
    @Published var remoteProviderAPIKey = ""
    @Published var providerJSONMode = false
    @Published var summaryPrompt = ""
    @Published var summaryEditorToOpen: String?
    @Published var appleIntelligenceAvailable = false
    @Published var appleIntelligenceReason = "Verifica disponibilità in corso…"
    @Published var localModelsDir = ""
    @Published var recorderMode = "macos_prompt"
    @Published var recorderFolder = ""
    @Published var recordingPromptEnabled = true
    @Published var recordingPromptDelaySeconds = 3
    @Published var recorderOpenTarget = ""
    /// What the built-in recorder captures outside calls (RECORDING_AUDIO_SOURCE).
    @Published var recordingAudioSource: RecordingAudioSource = .both
    @Published var transcriptionProvider = "fluid"
    @Published var appLanguage = "it"
    @Published var appTheme: MeetingPilotTheme = .dark
    @Published var fluidAudioInstalled = false
    /// Fraction of the Parakeet download, or nil when none is running.
    @Published var parakeetDownloadProgress: Double?
    /// The Meeting Pilot model: which variant summaries use, which are on disk, and the
    /// running or failed download (BuiltinModel.swift).
    @Published var builtinSummaryModel = BuiltinModelVariant.light.rawValue
    @Published var builtinModelsInstalled: Set<String> = []
    @Published var builtinModelDownload: BuiltinModelDownload?
    var builtinModelDownloadTask: URLSessionDownloadTask?
    var builtinModelDownloadObservation: NSKeyValueObservation?
    var parakeetAutomaticDownloadAttempted = false
    @Published var publicationTargets: Set<String> = []
    @Published var journalRoot = ""
    @Published var obsidianVaultPath = ""
    @Published var businessGlossary = ""
    /// Default summary template id from SUMMARY_TEMPLATE; "auto" matches the meeting title.
    @Published var summaryTemplate = SummaryTemplateCatalog.auto
    @Published var customSummaryTemplates: [CustomSummaryTemplate] = []
    @Published var teamsOCREnabled = false
    @Published var obsidianFolder = "Meeting Pilot"
    @Published var obsidianFilenameTemplate = "{date} - {title}.md"
    /// Which sections published notes include; a missing entry means included.
    @Published var includedSections: [PageSection: Bool] = [:]
    /// USER_PROFILE: whether recordings become meeting notes, study notes or either.
    @Published var userProfile: UserProfile = .worker
    /// Asked in the welcome tour before the permissions, until answered; see `WelcomeWindow`.
    @Published var needsProfileChoice = false
    @Published var keepAudio = false
    @Published var permissionsReady = 0
    @Published var permissionRows: [PermissionRow] = []
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var launchAtLogin = true
    @Published var launchAtLoginNeedsApproval = false
    @Published var inboxLabel = "~/TeamsMeetings/inbox_audio"
    @Published var meetingsRoot = ""
    @Published var recentMeetings: [MeetingItem] = []
    @Published var logTail = ""
    @Published var statusMessage = ""
    @Published var providerStatusMessage = ""
    @Published var providerModelOptions: [String] = []
    @Published var localRuntime = LocalRuntime.omlx.rawValue
    /// Runtimes that answered on their endpoint, keyed by `LocalRuntime.rawValue`.
    @Published var localRuntimeModels: [String: [String]] = [:]
    @Published var localRuntimesProbed = false
    @Published var modelDownload: LocalModelDownload?
    private var modelDownloadTask: Task<Void, Never>?
    @Published var pipelineStage = 0
    @Published var pipelineCounts = PipelineStageCounts()
    @Published var processingSessions: [ProcessingSession] = []
    @Published var retryableFailedSession = ""
    @Published var retryInProgress = false
    @Published var retryableTranscriptionSession = ""
    @Published var chatProjects: [String] = []
    @Published var chatThemes: [String] = []
    @Published var transcriptionRetryInProgress = false
    @Published private var dismissedSummaryRetrySession = ""
    @Published private var dismissedTranscriptionRetrySession = ""
    @Published var projectAccessSuspended = false
    @Published var runningAppPath = ""
    /// Files waiting in the import sheet; set by the Import button, a drop or the menu.
    @Published var importRequest: MediaImportRequest?
    var openDiaryWindow: (() -> Void)?

    let projectRoot: URL
    let configRoot: URL
    let envURL: URL
    let cli: MeetingPilotCLI
    let watcher: WatcherController
    let recording: RecordingController
    let notion: NotionConnection
    let importer: MediaImporter
    private var childChangeSubscriptions: [AnyCancellable] = []
    private var timer: Timer?
    private var accessibilityPermissionTimer: Timer?
    private var appleSpeechAuthorizationPrompted = false
    private var projectAccessFailureCount = 0
    private let refreshQueue = DispatchQueue(label: "\(AppIdentity.bundleID).refresh", qos: .utility)
    private var refreshWorkInFlight = false
    private var refreshRequestedWhileBusy = false

    var todayMeetings: [MeetingItem] {
        recentMeetings.filter { meeting in
            guard let date = meeting.date else { return false }
            return Calendar.current.isDateInToday(date)
        }
    }

    var showSummaryRetryCard: Bool {
        retryInProgress || (!retryableFailedSession.isEmpty && retryableFailedSession != dismissedSummaryRetrySession)
    }

    var showTranscriptionRetryCard: Bool {
        transcriptionRetryInProgress || (!retryableTranscriptionSession.isEmpty && retryableTranscriptionSession != dismissedTranscriptionRetrySession)
    }

    var needsAccessibilityWarning: Bool {
        !accessibilityGranted
    }

    var appleDictationRequired: Bool {
        guard transcriptionProvider == "apple", !retryableTranscriptionSession.isEmpty else { return false }
        let log = URL(fileURLWithPath: retryableTranscriptionSession)
            .appendingPathComponent("apple_transcriber_command.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return text.localizedCaseInsensitiveContains("Siri and Dictation are disabled")
    }

    var transcriptionAudioUnreadable: Bool {
        guard !retryableTranscriptionSession.isEmpty else { return false }
        let log = URL(fileURLWithPath: retryableTranscriptionSession)
            .appendingPathComponent("apple_transcriber_command.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return text.localizedCaseInsensitiveContains("impossibile aprire")
            || text.localizedCaseInsensitiveContains("moov atom not found")
            || text.localizedCaseInsensitiveContains("invalid data found")
    }

    var nonRetryableTranscriptionIssue: String? {
        guard !retryableTranscriptionSession.isEmpty else { return nil }
        let issue = transcriptionIssue(in: URL(fileURLWithPath: retryableTranscriptionSession))
        return issue?.retryable == false ? issue?.message : nil
    }

    func dismissSummaryRetryCard() {
        dismissedSummaryRetrySession = retryableFailedSession
    }

    func dismissTranscriptionRetryCard() {
        dismissedTranscriptionRetrySession = retryableTranscriptionSession
    }

    var providerDisplayName: String {
        if providerMode == "apple" { return "Apple Intelligence · on-device" }
        if providerMode == "builtin" {
            let variant = BuiltinModelVariant(rawValue: providerModel) ?? .light
            return "Meeting Pilot · \(localized(variant.title))"
        }
        let prefix = providerMode == "api"
            ? remoteProviderDisplayName(baseURL: providerBaseURL, model: providerModel)
            : (LocalRuntime(rawValue: localRuntime) ?? .omlx).title
        return "\(prefix) · \(providerModel)"
    }

    var recorderDisplayName: String {
        switch recorderMode {
        case "macos_prompt": return "Recorder macOS"
        case "custom": return "Recorder personalizzato"
        default: return "Recorder esterno (TranscribeX)"
        }
    }

    /// Apple On-Device transcribes in the app language; there is no separate setting.
    var transcriptionLocale: String {
        (AppLanguage(code: appLanguage) ?? .en).asrLanguageCode
    }

    var transcriptionDisplayName: String {
        switch transcriptionProvider {
        case "fluid":
            return fluidAudioInstalled ? "FluidAudio" : "FluidAudio non disponibile"
        default:
            return "Apple On-Device · \(transcriptionLocale)"
        }
    }

    var usesSpeechAnalyzer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    init() {
        self.projectRoot = ProjectLocator.findProjectRoot()
        self.configRoot = ConfigLocator.configDirectory()
        self.envURL = configRoot.appendingPathComponent(".env")
        self.cli = MeetingPilotCLI(envURL: envURL, projectRoot: projectRoot)
        self.watcher = WatcherController(cli: cli)
        self.recording = RecordingController(cli: cli)
        self.notion = NotionConnection(envURL: envURL)
        self.importer = MediaImporter(historyURL: configRoot.appendingPathComponent("imported-media.json"))
        let glossaryURL = configRoot.appendingPathComponent("business-glossary.txt")
        self.businessGlossary = (try? String(contentsOf: glossaryURL, encoding: .utf8)) ?? ""
        self.runningAppPath = Bundle.main.bundleURL.path
        // Until the user picks a language in Settings, UI and meeting notes follow macOS.
        let savedLanguage = UserDefaults.standard.string(forKey: "MeetingPilotAppLanguage")
        self.appLanguage = AppLanguage.current.rawValue
        self.appTheme = MeetingPilotTheme(rawValue: UserDefaults.standard.string(forKey: "MeetingPilotAppTheme")) ?? .dark
        EnvFile.onFailure = { [weak self] message in self?.statusMessage = message }
        ConfigLocator.ensureConfigFile(at: envURL)
        // Asked once of everyone, new installs and updates alike, until they answer;
        // meanwhile recordings stay meeting notes.
        needsProfileChoice = !UserProfile.isChosen(EnvFile.load(from: envURL)["USER_PROFILE"])
        EnvFile.update(at: envURL, values: ["BUSINESS_GLOSSARY_FILE": glossaryURL.path])
        let templatesURL = configRoot.appendingPathComponent(SummaryTemplateCatalog.fileName)
        self.customSummaryTemplates = SummaryTemplateCatalog.loadCustom(from: templatesURL)
        EnvFile.update(at: envURL, values: ["SUMMARY_TEMPLATES_FILE": templatesURL.path])
        if savedLanguage != nil {
            EnvFile.update(at: envURL, values: ["OUTPUT_LANGUAGE": appLanguage])
        }
        EnvFile.update(at: envURL, values: ["TRANSCRIPTION_LOCALE": transcriptionLocale])
        prepareBundledFluidAudio()
        connectControllers()
    }

    /// Views observe AppModel only, so forward the controllers' changes to it.
    private func connectControllers() {
        let children: [AnyPublisher<Void, Never>] = [
            watcher.objectWillChange.eraseToAnyPublisher(),
            recording.objectWillChange.eraseToAnyPublisher(),
            notion.objectWillChange.eraseToAnyPublisher(),
            importer.objectWillChange.eraseToAnyPublisher(),
        ]
        childChangeSubscriptions = children.map { publisher in
            publisher.sink { [weak self] in self?.objectWillChange.send() }
        }
        recording.settings = { [weak self] in self?.recorderSettings ?? .fallback }
        recording.onStatusMessage = { [weak self] message in self?.statusMessage = message }
        recording.onNeedsRefresh = { [weak self] in self?.refresh() }
        notion.onStatusMessage = { [weak self] message in self?.statusMessage = message }
        notion.onNeedsRefresh = { [weak self] in self?.refresh() }
        importer.onStatusMessage = { [weak self] message in self?.statusMessage = message }
        importer.onImported = { [weak self] in self?.refresh() }
    }

    private var recorderSettings: RecorderSettings {
        RecorderSettings(
            mode: recorderMode,
            folder: recorderFolder,
            openTarget: recorderOpenTarget,
            promptEnabled: recordingPromptEnabled,
            promptDelaySeconds: recordingPromptDelaySeconds,
            teamsOCREnabled: teamsOCREnabled,
            audioSource: recordingAudioSource
        )
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh(forceProjectAccess: Bool = false) {
        if projectAccessSuspended && !forceProjectAccess {
            refreshLightweightStatus()
            return
        }
        if refreshWorkInFlight {
            refreshRequestedWhileBusy = true
            return
        }

        var env = EnvFile.load(from: envURL)
        if EnvFile.sanitize(at: envURL) {
            env = EnvFile.load(from: envURL)
        }
        let appleStatus = currentAppleIntelligenceAvailability()
        appleIntelligenceAvailable = appleStatus.available
        appleIntelligenceReason = appleStatus.reason
        var configRepairs: [String: String] = [:]
        let configuredAppleCommand = env["APPLE_TRANSCRIBER_CMD"] ?? ""
        if configuredAppleCommand.isEmpty
            || configuredAppleCommand.contains("/macos/MeetingPilot/build")
            || !FileManager.default.isExecutableFile(atPath: configuredAppleCommand) {
            configRepairs["APPLE_TRANSCRIBER_CMD"] = appleTranscriberCommandPath()
        }
        let configuredAppleSummarizer = env["APPLE_INTELLIGENCE_SUMMARIZER_CMD"] ?? ""
        if configuredAppleSummarizer.isEmpty
            || configuredAppleSummarizer.contains("/macos/MeetingPilot/build")
            || !FileManager.default.isExecutableFile(atPath: configuredAppleSummarizer) {
            configRepairs["APPLE_INTELLIGENCE_SUMMARIZER_CMD"] = appleIntelligenceSummarizerCommandPath()
        }
        let configuredSummaryMode = env["SUMMARY_PROVIDER_MODE"] ?? ""
        let appleDefaultState = env["APPLE_INTELLIGENCE_DEFAULT_APPLIED"] ?? ""
        if appleDefaultState != "true" {
            if appleStatus.available && (configuredSummaryMode.isEmpty || configuredSummaryMode == "local") {
                configRepairs["SUMMARY_PROVIDER_MODE"] = "apple"
                configRepairs["APPLE_INTELLIGENCE_DEFAULT_APPLIED"] = "true"
            } else if appleStatus.available {
                configRepairs["APPLE_INTELLIGENCE_DEFAULT_APPLIED"] = "true"
            } else if !appleStatus.available {
                if configuredSummaryMode.isEmpty || configuredSummaryMode == "apple" {
                    configRepairs["SUMMARY_PROVIDER_MODE"] = "local"
                }
                if appleDefaultState != "pending" {
                    configRepairs["APPLE_INTELLIGENCE_DEFAULT_APPLIED"] = "pending"
                }
            }
        } else if configuredSummaryMode == "apple" && !appleStatus.available {
            configRepairs["SUMMARY_PROVIDER_MODE"] = "local"
            configRepairs["APPLE_INTELLIGENCE_DEFAULT_APPLIED"] = "pending"
            statusMessage = "Apple Intelligence non disponibile: uso oMLX locale"
        }
        if env["APPLE_TRANSCRIBER_TIMEOUT_SECONDS"] == "240" {
            configRepairs["APPLE_TRANSCRIBER_TIMEOUT_SECONDS"] = "900"
        }
        // The Meeting Pilot model's engine ships inside the app, like FluidAudio's CLI.
        if FileManager.default.isExecutableFile(atPath: bundledLlamaServerPath())
            && env["LLAMA_SERVER_CMD"] != bundledLlamaServerPath() {
            configRepairs["LLAMA_SERVER_CMD"] = bundledLlamaServerPath()
        }
        // Both engines need the bundled CLI: FluidAudio for everything, Apple for speaker diarization.
        if FileManager.default.isExecutableFile(atPath: bundledFluidAudioCommandPath())
            && env["FLUID_AUDIO_CMD"] != bundledFluidAudioCommandPath() {
            configRepairs["FLUID_AUDIO_CMD"] = bundledFluidAudioCommandPath()
        }
        // From macOS 26 Apple's recognizer plus FluidAudio's diarization is the default, so the
        // Parakeet model is no longer bundled; it is switched to once, and Parakeet stays a choice.
        if usesSpeechAnalyzer && env["APPLE_TRANSCRIPTION_DEFAULT_APPLIED"] != "true" {
            configRepairs["TRANSCRIPTION_PROVIDER"] = "apple"
            configRepairs["APPLE_TRANSCRIBER_CMD"] = appleTranscriberCommandPath()
            configRepairs["APPLE_TRANSCRIPTION_DEFAULT_APPLIED"] = "true"
        } else if env["TRANSCRIPTION_PROVIDER"] != "apple" && !fluidTranscriptionAvailable(in: env) {
            configRepairs["TRANSCRIPTION_PROVIDER"] = "apple"
            configRepairs["APPLE_TRANSCRIBER_CMD"] = appleTranscriberCommandPath()
        } else if env["TRANSCRIPTION_PROVIDER"] != "apple" && env["TRANSCRIPTION_PROVIDER"] != "fluid" {
            configRepairs["TRANSCRIPTION_PROVIDER"] = "fluid"
        }
        if !configRepairs.isEmpty {
            EnvFile.update(at: envURL, values: configRepairs)
            env.merge(configRepairs) { _, repaired in repaired }
        }
        projectAccessFailureCount = 0
        projectAccessSuspended = false

        let configuredRecorderMode = env["RECORDER_MODE"] ?? "macos_prompt"
        let inbox = expandPath(env["INBOX_AUDIO_DIR"] ?? defaultRecorderFolder(for: configuredRecorderMode))
        let root = expandPath(env["MEETINGS_ROOT"] ?? "~/TeamsMeetings")
        let processedSources = expandPath(env["PROCESSED_SOURCES_FILE"] ?? "\(root.path)/processed_sources.json")
        let runtime = expandPath(env["TEAMS_RUNTIME_METADATA_FILE"] ?? "~/TeamsMeetings/teams-runtime.json")

        providerMode = env["SUMMARY_PROVIDER_MODE"] ?? (appleStatus.available ? "apple" : (providerBaseURLIsLocal(env["SUMMARY_BASE_URL"] ?? env["OMLX_BASE_URL"]) ? "local" : "api"))
        providerModel = env["SUMMARY_MODEL"] ?? env["OMLX_MODEL"] ?? "-"
        localProviderModel = env["LOCAL_SUMMARY_MODEL"] ?? (providerMode == "local" ? providerModel : "")
        remoteProviderModel = env["REMOTE_SUMMARY_MODEL"] ?? (providerMode == "api" ? providerModel : "")
        let configuredSummaryBaseURL = env["SUMMARY_BASE_URL"] ?? env["OMLX_BASE_URL"] ?? ""
        localProviderBaseURL = env["LOCAL_SUMMARY_BASE_URL"]
            ?? (providerMode == "local" ? configuredSummaryBaseURL : defaultProviderBaseURL(for: "local"))
        remoteProviderBaseURL = env["REMOTE_SUMMARY_BASE_URL"]
            ?? (providerMode == "api" ? configuredSummaryBaseURL : defaultProviderBaseURL(for: "api"))
        providerBaseURL = providerMode == "local"
            ? localProviderBaseURL
            : (providerMode == "api" ? remoteProviderBaseURL : configuredSummaryBaseURL)
        remoteProviderKind = env["REMOTE_PROVIDER_KIND"] ?? inferredRemoteProviderKind(baseURL: providerBaseURL, model: providerModel)
        localRuntime = env["LOCAL_SUMMARY_RUNTIME"] ?? LocalRuntime.inferred(from: localProviderBaseURL).rawValue
        localProviderAPIKey = env["LOCAL_SUMMARY_API_KEY"] ?? env["OMLX_API_KEY"] ?? (providerMode == "local" ? (env["SUMMARY_API_KEY"] ?? "") : "")
        remoteProviderAPIKey = env["REMOTE_SUMMARY_API_KEY"] ?? (providerMode == "api" ? (env["SUMMARY_API_KEY"] ?? "") : "")
        providerAPIKey = providerMode == "local" ? localProviderAPIKey : (providerMode == "api" ? remoteProviderAPIKey : "")
        providerJSONMode = (env["SUMMARY_RESPONSE_FORMAT_JSON"] ?? "false").lowercased() == "true"
        summaryPrompt = env["SUMMARY_PROMPT"] ?? ""
        summaryTemplate = env["SUMMARY_TEMPLATE"].flatMap { $0.isEmpty ? nil : $0 } ?? SummaryTemplateCatalog.auto
        localModelsDir = normalizedLocalModelsDir(env["LOCAL_MODELS_DIR"] ?? env["OMLX_MODELS_DIR"])
        builtinSummaryModel = env["BUILTIN_SUMMARY_MODEL"].flatMap(BuiltinModelVariant.init(rawValue:))?.rawValue
            ?? BuiltinModelVariant.light.rawValue
        refreshBuiltinModels()
        recorderMode = configuredRecorderMode
        // The macOS recorder is driven by the Teams meeting banner. The legacy
        // banner toggle was removed from Settings, so an old persisted `false`
        // must never silently disable meeting detection.
        recordingPromptEnabled = configuredRecorderMode == "macos_prompt"
            || (env["RECORDING_PROMPT_ENABLED"] ?? "true").lowercased() == "true"
        recordingPromptDelaySeconds = Int(env["RECORDING_PROMPT_DELAY_SECONDS"] ?? "3") ?? 3
        recorderOpenTarget = env["RECORDER_OPEN_TARGET"] ?? defaultRecorderOpenTarget(for: recorderMode, folder: inbox.path)
        recordingAudioSource = env["RECORDING_AUDIO_SOURCE"].flatMap(RecordingAudioSource.init(rawValue:)) ?? .both
        transcriptionProvider = env["TRANSCRIPTION_PROVIDER"] == "apple" ? "apple" : "fluid"
        teamsOCREnabled = (env["TEAMS_OCR_ENABLED"] ?? "false").lowercased() == "true"
        fluidAudioInstalled = fluidTranscriptionAvailable(in: env)
        // Before macOS 26 Apple's recognizer has no word timings, so it cannot label speakers:
        // Parakeet is fetched on its own and becomes the engine once it is ready.
        if !usesSpeechAnalyzer && !parakeetModelsInstalled && parakeetDownloadProgress == nil
            && !parakeetAutomaticDownloadAttempted {
            parakeetAutomaticDownloadAttempted = true
            downloadParakeet(selectWhenReady: true)
        }
        requestAppleSpeechAuthorizationIfNeeded()
        notion.load(from: env)
        publicationTargets = parsePublicationTargets(env)
        launchAtLogin = envBool(env, "LAUNCH_AT_LOGIN", true)
        launchAtLoginNeedsApproval = launchAtLogin && LaunchAtLogin.needsApproval
        journalRoot = expandPath(env["JOURNAL_ROOT"] ?? "~/Library/Application Support/Meeting Pilot/Diary").path
        obsidianVaultPath = env["OBSIDIAN_VAULT_PATH"] ?? ""
        obsidianFolder = env["OBSIDIAN_FOLDER"] ?? "Meeting Pilot"
        obsidianFilenameTemplate = env["OBSIDIAN_FILENAME_TEMPLATE"] ?? "{date} - {title}.md"
        includedSections = Dictionary(uniqueKeysWithValues: PageSection.allCases.map { section in
            let included = section.legacyEnvKey.map { globalEnvBool(env, section.envKey, legacyKey: $0, true) }
                ?? envBool(env, section.envKey, true)
            return (section, included)
        })
        userProfile = env["USER_PROFILE"].flatMap(UserProfile.init(rawValue:)) ?? .worker
        keepAudio = envBool(env, "KEEP_AUDIO", false)
        recorderFolder = inbox.path
        inboxLabel = compactPath(inbox.path)
        meetingsRoot = compactPath(root.path)
        // The expensive equivalents now run in makeRefreshSnapshot on the
        // utility queue: let activeTranscriptionCommands = transcriptionProcessCommands()
        // and activeCommands: activeTranscriptionCommands.
        scheduleRefreshSnapshot(
            RefreshInput(
                inbox: inbox,
                processedSources: processedSources,
                root: root,
                runtime: runtime,
                stableSeconds: fileStableSeconds(env),
                recorderMode: recorderMode,
                transcriptionProvider: transcriptionProvider,
                nativeRecordingActive: recording.nativeRecordingActive,
                externalRecordingActive: recording.externalRecordingActive,
                externalRecordingStartedAt: recording.externalRecordingStartedAt
            )
        )
    }

    private func scheduleRefreshSnapshot(_ input: RefreshInput) {
        refreshWorkInFlight = true
        refreshQueue.async { [weak self] in
            let snapshot = makeRefreshSnapshot(input)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyRefreshSnapshot(snapshot, doneRoot: input.root.appendingPathComponent("done"))
                self.refreshWorkInFlight = false
                if self.refreshRequestedWhileBusy {
                    self.refreshRequestedWhileBusy = false
                    self.refresh()
                }
            }
        }
    }

    private func applyRefreshSnapshot(_ snapshot: RefreshSnapshot, doneRoot: URL) {
        watcher.watcherActive = snapshot.watcherActive
        queueCount = snapshot.queueCount
        if snapshot.externalRecordingFinished {
            recording.externalRecordingDidFinish()
        }
        retryableFailedSession = snapshot.retryableFailedSession
        retryableTranscriptionSession = snapshot.retryableTranscriptionSession
        pipelineStage = snapshot.pipelineStage
        pipelineCounts = snapshot.pipelineCounts
        processingSessions = snapshot.processingSessions
        todayProcessed = snapshot.todayProcessed
        recentMeetings = snapshot.recentMeetings
        logTail = snapshot.logTail
        permissionRows = snapshot.permissionRows
        accessibilityGranted = snapshot.accessibilityGranted
        permissionsReady = permissionRows.filter(\.granted).count
        recording.applyRuntimeMetadata(snapshot.runtime)
        notion.notifyForNewPublications(in: doneRoot)
        refreshNotificationPermissionRow()
    }

    func retryProjectAccess() {
        projectAccessSuspended = false
        projectAccessFailureCount = 0
        refresh(forceProjectAccess: true)
    }

    private func refreshLightweightStatus() {
        watcher.refreshRunningState()
        let env = EnvFile.load(from: envURL)
        let root = expandPath(env["MEETINGS_ROOT"] ?? "~/TeamsMeetings")
        logTail = diagnosticLogText(meetingsRoot: root)
        permissionRows = permissions(
            includeSystemAudio: recorderMode == "macos_prompt",
            includeAppleDictation: transcriptionProvider == "apple"
        )
        accessibilityGranted = AXIsProcessTrusted()
        permissionsReady = permissionRows.filter(\.granted).count
        refreshNotificationPermissionRow()
        recording.pollMeeting()
    }

    var missingPermissionRows: [PermissionRow] {
        permissionRows.filter { !$0.granted }
    }

    func refreshPermissionRows() {
        permissionRows = permissions(
            includeSystemAudio: recorderMode == "macos_prompt",
            includeAppleDictation: transcriptionProvider == "apple"
        )
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted {
            accessibilityPermissionTimer?.invalidate()
            accessibilityPermissionTimer = nil
        }
        permissionsReady = permissionRows.filter(\.granted).count
        refreshNotificationPermissionRow()
    }

    private func refreshNotificationPermissionRow() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionRows.removeAll { $0.id == "notifications" }
                self.permissionRows.append(notificationPermissionRow(granted: granted))
                self.permissionsReady = self.permissionRows.filter(\.granted).count
            }
        }
    }

    func openPermissionSettings(_ row: PermissionRow) {
        if row.id == "notifications" {
            NotificationBridge.requestAuthorization { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshPermissionRows()
                    if !granted,
                       let url = URL(string: row.settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            return
        }
        if row.id == "accessibility" {
            requestAccessibilityPermission()
            watchAccessibilityPermission()
        }
        if row.id == "microphone" {
            requestMicrophonePermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.statusMessage = granted
                        ? "Microfono concesso"
                        : "Microfono non concesso: controlla Privacy e sicurezza"
                    self?.refresh()
                }
            }
        }
        if row.id == "system_audio" {
            PermissionCoachWindow.shared.show(
                permissionTitle: row.title,
                settingsPath: "Impostazioni di Sistema > Privacy e sicurezza > Registrazione schermo e audio di sistema",
                autoDetect: nil,
                onRestart: { relaunchApp() }
            )
        }
        if let url = URL(string: row.settingsURL) {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissionRows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.refreshPermissionRows()
        }
    }

    func startWatcher() {
        let env = EnvFile.load(from: envURL)
        let selectedProviderAvailable: Bool
        switch transcriptionProvider {
        case "fluid":
            selectedProviderAvailable = fluidTranscriptionAvailable(in: env)
        default:
            selectedProviderAvailable = true
        }
        if !selectedProviderAvailable {
            EnvFile.update(at: envURL, values: [
                "TRANSCRIPTION_PROVIDER": "apple",
                "APPLE_TRANSCRIBER_CMD": appleTranscriberCommandPath()
            ])
            transcriptionProvider = "apple"
            statusMessage = "Uso trascrizione Apple integrata su questo Mac"
        }
        watcher.start { running in
            self.statusMessage = running
                ? "Elaborazione automatica avviata"
                : "Non riesco ad avviare l'elaborazione: controlla Log"
            self.refresh()
        }
    }

    func startInstalledServicesAutomatically() {
        let env = EnvFile.load(from: envURL)
        if envBool(env, "AUTO_START_WATCHER", true) {
            watcher.whenNotRunning {
                self.startWatcher()
                AppLog.append("Elaborazione automatica avviata con Meeting Pilot")
            }
        }

        guard envBool(env, "LAUNCH_AT_LOGIN", true) else { return }
        switch LaunchAtLogin.apply(true) {
        case .enabled:
            launchAtLoginNeedsApproval = false
        case .needsApproval:
            launchAtLoginNeedsApproval = true
            AppLog.append("Avvio al login disattivato in Impostazioni di Sistema > Generale > Elementi login")
        case .failed(let error):
            AppLog.append("Impossibile registrare avvio al login: \(error.localizedDescription)")
        case .disabled, .notInApplications:
            break
        }
    }

    func saveLaunchAtLogin(_ enabled: Bool) {
        EnvFile.update(at: envURL, values: ["LAUNCH_AT_LOGIN": enabled ? "true" : "false"])
        launchAtLogin = enabled
        launchAtLoginNeedsApproval = false
        switch LaunchAtLogin.apply(enabled) {
        case .enabled:
            statusMessage = "Avvio al login abilitato"
        case .disabled:
            statusMessage = "Avvio al login disabilitato"
        case .needsApproval:
            launchAtLoginNeedsApproval = true
            statusMessage = "Attiva Meeting Pilot in Impostazioni di Sistema > Generale > Elementi login"
            LaunchAtLogin.openSystemSettings()
        case .notInApplications:
            statusMessage = "Installa Meeting Pilot in Applicazioni per gestire l'avvio al login"
        case .failed(let error):
            statusMessage = "Non riesco a modificare l'avvio al login: \(error.localizedDescription)"
            AppLog.append(statusMessage)
        }
    }

    func saveAppLanguage(_ language: String) {
        guard let language = AppLanguage(code: language) else { return }
        let selected = language.rawValue
        guard selected != appLanguage else { return }
        appLanguage = selected
        UserDefaults.standard.set(selected, forKey: "MeetingPilotAppLanguage")
        UserDefaults.standard.set([selected], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        // The watcher reads .env only at startup, so restart it to pick up the new
        // summary, heading and Apple transcription language. Deferred out of the
        // settings view update.
        EnvFile.update(at: envURL, values: ["OUTPUT_LANGUAGE": selected, "TRANSCRIPTION_LOCALE": language.asrLanguageCode])
        watcher.restartIfRunning()
        statusMessage = language.updatedMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            relaunchApp()
        }
    }

    func saveAppTheme(_ theme: MeetingPilotTheme) {
        guard theme != appTheme else { return }
        appTheme = theme
        NSApp.appearance = theme.appearance
        UserDefaults.standard.set(theme.rawValue, forKey: "MeetingPilotAppTheme")
        statusMessage = theme == .light ? "Tema chiaro attivato" : "Tema scuro attivato"
    }

    func stopWatcher() {
        watcher.stop {
            self.statusMessage = "Rilevamento automatico in pausa"
            self.refresh()
        }
    }

    private func bundledFluidAudioCommandPath() -> String {
        Bundle.main.resourceURL?
            .appendingPathComponent("FluidAudio/bin/fluidaudiocli").path ?? "fluidaudiocli"
    }

    private func prepareBundledFluidAudio() {
        guard let resources = Bundle.main.resourceURL else { return }
        let command = resources.appendingPathComponent("FluidAudio/bin/fluidaudiocli")
        let bundledModels = resources.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: command.path),
              FileManager.default.fileExists(atPath: bundledModels.path)
        else { return }

        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // Parakeet is only bundled by older builds; newer ones download it on request.
            // Copied file by file so an existing folder gains models added by a later
            // build, such as the offline diarization ones.
            for model in ["parakeet-tdt-0.6b-v3", "speaker-diarization"] {
                let source = bundledModels.appendingPathComponent(model, isDirectory: true)
                let target = destination.appendingPathComponent(model, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for item in try FileManager.default.contentsOfDirectory(atPath: source.path)
                where !FileManager.default.fileExists(atPath: target.appendingPathComponent(item).path) {
                    try FileManager.default.copyItem(
                        at: source.appendingPathComponent(item),
                        to: target.appendingPathComponent(item)
                    )
                }
            }
            EnvFile.remove(at: envURL, keys: ["MILLET_CMD", "MILLET_EXTRA_ARGS", "HF_HOME"])
            EnvFile.update(at: envURL, values: ["FLUID_AUDIO_CMD": command.path])
        } catch {
            AppLog.append("Preparazione FluidAudio inclusa non riuscita: \(error.localizedDescription)")
            statusMessage = "Non riesco a preparare i modelli FluidAudio: \(error.localizedDescription)"
        }
    }

    /// FluidAudio transcribes only with its CLI and the downloaded Parakeet model.
    func fluidTranscriptionAvailable(in env: [String: String]) -> Bool {
        fluidAudioCommandAvailable(in: env) && parakeetModelsInstalled
    }

    private func fluidAudioCommandAvailable(in env: [String: String]) -> Bool {
        let bundledCommand = bundledFluidAudioCommandPath()
        if FileManager.default.isExecutableFile(atPath: bundledCommand) { return true }
        let rawCommand = (env["FLUID_AUDIO_CMD"] ?? "fluidaudiocli")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCommand.isEmpty else { return false }
        if rawCommand.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expandPath(rawCommand).path)
        }
        return ["/opt/homebrew/bin/\(rawCommand)", "/usr/local/bin/\(rawCommand)"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func retryFailedSummary() {
        guard !retryableFailedSession.isEmpty, !retryInProgress else { return }
        let session = retryableFailedSession
        retryInProgress = true
        pipelineStage = 3
        statusMessage = "Riprovo la sintesi dal transcript..."
        DispatchQueue.global(qos: .userInitiated).async {
            let output = self.cli.run(["retry-summary", "--session-dir", session])
            DispatchQueue.main.async {
                self.retryInProgress = false
                if output.contains("Done:") {
                    self.statusMessage = "Sintesi completata e riunione pubblicata"
                } else {
                    let detail = cliFailureLine(output)
                    self.statusMessage = detail.isEmpty ? "Nuovo tentativo di sintesi fallito" : detail
                    AppLog.append("Retry sintesi fallito\n\(output)")
                }
                self.refresh()
            }
        }
    }

    func retryFailedTranscription() {
        guard !retryableTranscriptionSession.isEmpty, !transcriptionRetryInProgress else { return }
        let session = retryableTranscriptionSession
        let sessionURL = URL(fileURLWithPath: session)
        if let issue = unrecoverableTranscriptionIssue(for: sessionURL) {
            statusMessage = issue
            presentErrorAlert("Audio non trascrivibile", detail: issue)
            return
        }
        guard !isTranscriptionProcessActive(for: sessionURL) else {
            statusMessage = "La trascrizione e' ancora in corso per questa riunione"
            refresh()
            return
        }
        guard let retryClaim = claimTranscriptionRetry(for: sessionURL) else {
            statusMessage = "Un nuovo tentativo di trascrizione e' gia' in corso"
            refresh()
            return
        }
        transcriptionRetryInProgress = true
        pipelineStage = 2
        statusMessage = "Riprovo la trascrizione dall'audio salvato..."
        DispatchQueue.global(qos: .userInitiated).async {
            defer { releaseTranscriptionRetryClaim(retryClaim) }
            let output = self.cli.run(["retry-transcription", "--session-dir", session])
            DispatchQueue.main.async {
                self.transcriptionRetryInProgress = false
                if output.contains("Done:") {
                    self.statusMessage = "Trascrizione completata e riunione pubblicata"
                } else {
                    let detail = cliFailureLine(output)
                    self.statusMessage = detail.isEmpty ? "Nuovo tentativo di trascrizione fallito" : detail
                    AppLog.append("Retry trascrizione fallito\n\(output)")
                }
                self.refresh()
            }
        }
    }

    func retryProcessingSession(_ session: ProcessingSession) {
        guard session.stage == .failed else { return }
        let sessionURL = URL(fileURLWithPath: session.id)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sessionURL.path)) ?? []
        let hasTranscript = files.contains {
            $0.lowercased().hasSuffix(".txt") && !$0.lowercased().hasSuffix(".ffmpeg.log")
        }

        if hasTranscript {
            guard !retryInProgress else { return }
            retryInProgress = true
            pipelineStage = 3
            statusMessage = "Riprovo la sintesi dal transcript..."
            DispatchQueue.global(qos: .userInitiated).async {
                let output = self.cli.run(["retry-summary", "--session-dir", session.id])
                DispatchQueue.main.async {
                    self.retryInProgress = false
                    self.statusMessage = output.contains("Done:")
                        ? "Sintesi completata e riunione pubblicata"
                        : "Nuovo tentativo di sintesi fallito"
                    if !output.contains("Done:") { AppLog.append("Retry sintesi fallito\n\(output)") }
                    self.refresh()
                }
            }
            return
        }

        if let issue = unrecoverableTranscriptionIssue(for: sessionURL) {
            statusMessage = issue
            presentErrorAlert("Audio non trascrivibile", detail: issue)
            return
        }
        guard !transcriptionRetryInProgress else { return }
        guard !isTranscriptionProcessActive(for: sessionURL) else {
            statusMessage = "La trascrizione e' gia' in corso per questa riunione"
            return
        }
        guard let retryClaim = claimTranscriptionRetry(for: sessionURL) else {
            statusMessage = "Un nuovo tentativo di trascrizione e' gia' in corso"
            return
        }
        transcriptionRetryInProgress = true
        pipelineStage = 2
        statusMessage = "Riprovo la trascrizione dall'audio salvato..."
        DispatchQueue.global(qos: .userInitiated).async {
            defer { releaseTranscriptionRetryClaim(retryClaim) }
            let output = self.cli.run(["retry-transcription", "--session-dir", session.id])
            DispatchQueue.main.async {
                self.transcriptionRetryInProgress = false
                self.statusMessage = output.contains("Done:")
                    ? "Trascrizione completata e riunione pubblicata"
                    : "Nuovo tentativo di trascrizione fallito"
                if !output.contains("Done:") { AppLog.append("Retry trascrizione fallito\n\(output)") }
                self.refresh()
            }
        }
    }

    func discardProcessingSession(_ session: ProcessingSession) {
        guard session.stage == .failed else { return }
        let alert = NSAlert()
        alert.messageText = localized("Spostare questa elaborazione nel Cestino?")
        alert.informativeText = localized("Potrai recuperarla dal Cestino del Finder finché non lo svuoti.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("Sposta nel Cestino"))
        alert.addButton(withTitle: localized("Annulla"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: session.id), resultingItemURL: nil)
            statusMessage = "Elaborazione spostata nel Cestino"
            refresh()
        } catch {
            presentErrorAlert("Non riesco a spostare l'elaborazione nel Cestino", detail: error.localizedDescription)
        }
    }

    private func unrecoverableTranscriptionIssue(for sessionURL: URL) -> String? {
        if let issue = transcriptionIssue(in: sessionURL), !issue.retryable {
            return issue.message
        }
        let logs = ["audio_validation.log", "fluidaudio_command.log", "apple_transcriber_command.log"]
        let details = logs.compactMap {
            try? String(contentsOf: sessionURL.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n").lowercased()
        guard details.contains("manca l'indice finale")
                || details.contains("moov atom not found")
                || (details.contains("extaudiofileopenurl") && details.contains("dta?"))
        else { return nil }
        return "La registrazione e' incompleta e non puo' essere trascritta. Registra di nuovo questa parte della riunione."
    }

    func openAppleDictationSettings() {
        statusMessage = "Attiva Dettatura, poi torna in Meeting Pilot e premi Riprova trascrizione"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAppleIntelligenceSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.speech"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func requestAppleSpeechAuthorizationIfNeeded() {
        guard transcriptionProvider == "apple", !usesSpeechAnalyzer, !appleSpeechAuthorizationPrompted else { return }
        appleSpeechAuthorizationPrompted = true
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    func runTeamsScrape() {
        statusMessage = "Lettura Teams in corso..."
        DispatchQueue.global(qos: .userInitiated).async {
            let output = self.cli.run(["teams-scrape"], environment: MeetingPilotCLI.teamsHelperEnvironment)
            DispatchQueue.main.async {
                self.statusMessage = output.contains("\"confidence\"") ? "Teams scraper completato" : output
                self.refresh()
            }
        }
    }

    func inspectTeamsAccessibility(completion: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else {
            completion("Accessibilità non autorizzata. Abilita Meeting Pilot in Impostazioni di Sistema e riprova durante una call Teams.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = self.configRoot.appendingPathComponent("teams-accessibility-inspection.json")
            let output = self.cli.run(
                ["teams-scrape", "--no-ocr", "--print-raw", "--output", snapshot.path],
                environment: MeetingPilotCLI.teamsHelperEnvironment
            )
            let display: String
            if let data = output.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let titles = (payload["window_titles"] as? [String]) ?? []
                let lines = (payload["raw_lines"] as? [String]) ?? []
                let header = "FINESTRE TEAMS\n\(titles.joined(separator: "\n"))\n\nELEMENTI ACCESSIBILITÀ\n"
                display = header + lines.joined(separator: "\n")
            } else {
                display = output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async {
                completion(display.isEmpty ? "Teams non ha restituito elementi Accessibilità." : display)
            }
        }
    }

    func askMeetingChat(
        question: String,
        projects: Set<String>,
        themes: Set<String>,
        startDate: Date?,
        endDate: Date?,
        sources: Set<String>,
        searchScope: String = "meetings",
        externalSources: Set<String> = [],
        completion: @escaping (MeetingChatResponse) -> Void
    ) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            completion(MeetingChatResponse(answer: "Scrivi una domanda sui meeting.", citations: []))
            return
        }
        statusMessage = "Cerco nei meeting selezionati..."
        AppLog.append("Chat: ricerca avviata (ambito: \(searchScope), progetti: \(projects.count), temi: \(themes.count), fonti: \(sources.count))")
        DispatchQueue.global(qos: .userInitiated).async {
            var arguments = ["chat", "--question", trimmedQuestion, "--scope", searchScope]
            for project in projects.sorted() {
                arguments += ["--project", project]
            }
            for theme in themes.sorted() {
                arguments += ["--theme", theme]
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            if let startDate {
                arguments += ["--start-date", formatter.string(from: startDate)]
            }
            if let endDate {
                arguments += ["--end-date", formatter.string(from: endDate)]
            }
            for source in sources.sorted() {
                arguments += ["--source", source]
            }
            for source in externalSources.sorted() {
                arguments += ["--external-source", source]
            }
            let output = self.cli.run(arguments)
            let response: MeetingChatResponse
            if let data = output.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(MeetingChatResponse.self, from: data) {
                response = decoded
            } else {
                response = MeetingChatResponse(
                    answer: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? localized("Non trovato nei meeting selezionati.")
                        : output.trimmingCharacters(in: .whitespacesAndNewlines),
                    citations: []
                )
            }
            DispatchQueue.main.async {
                self.statusMessage = "Chat aggiornata"
                AppLog.append("Chat: risposta ricevuta (citazioni: \(response.citations.count))")
                completion(response)
            }
        }
    }

    func refreshChatFilterValues(externalSources: Set<String> = []) {
        DispatchQueue.global(qos: .userInitiated).async {
            // A remote source may suggest values, but only locally confirmed tags
            // can enter these menus. Migrate the short-lived older auto-import.
            _ = self.cli.run(["tag-catalog-migrate"])
            let output = self.cli.run(["chat-filter-values"])
            let values = output.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(MeetingChatFilterValuesPayload.self, from: $0) }
            DispatchQueue.main.async {
                self.chatProjects = values?.projects ?? []
                self.chatThemes = values?.themes ?? []
            }
        }
    }

    func addTagCatalogValue(kind: String, value: String, completion: @escaping (MeetingChatFilterValuesPayload?) -> Void) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let output = self.cli.run(["tag-catalog-add", "--kind", kind, "--value", trimmedValue])
            let values = output.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(MeetingChatFilterValuesPayload.self, from: $0) }
            DispatchQueue.main.async {
                if let values {
                    self.chatProjects = values.projects
                    self.chatThemes = values.themes
                }
                completion(values)
            }
        }
    }

    func importTagCatalogFromSources(
        sources: Set<String>,
        completion: @escaping (MeetingChatFilterValuesPayload?, String) -> Void
    ) {
        guard !sources.isEmpty else {
            completion(nil, localized("Nessuna fonte selezionata supporta l'importazione"))
            return
        }
        let existingProjects = Set(chatProjects)
        let existingThemes = Set(chatThemes)
        DispatchQueue.global(qos: .userInitiated).async {
            var arguments = ["tag-catalog-import-sources"]
            for source in sources.sorted() {
                arguments += ["--source", source]
            }
            let output = self.cli.run(arguments)
            let values = output.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(MeetingChatFilterValuesPayload.self, from: $0) }
            DispatchQueue.main.async {
                if let values {
                    self.chatProjects = values.projects
                    self.chatThemes = values.themes
                    let importedCount = values.projects.filter { !existingProjects.contains($0) }.count
                        + values.themes.filter { !existingThemes.contains($0) }.count
                    let removedCount = existingProjects.filter { !values.projects.contains($0) }.count
                        + existingThemes.filter { !values.themes.contains($0) }.count
                    completion(
                        values,
                        importedCount > 0
                            ? String(format: localized("Importati %lld nuovi valori"), importedCount)
                            : (removedCount > 0
                                ? String(format: localized("Rimossi %lld valori non presenti in Notion"), removedCount)
                                : localized("Nessun nuovo valore importato"))
                    )
                } else {
                    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(nil, detail.isEmpty ? localized("Importazione dalle fonti non riuscita") : detail)
                }
            }
        }
    }

    func indexMongoDBKnowledgeBase(
        uri: String,
        database: String,
        collection: String,
        completion: @escaping (String) -> Void
    ) {
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURI.isEmpty, !trimmedDatabase.isEmpty, !trimmedCollection.isEmpty else {
            completion("Configura URI, database e collection")
            return
        }
        statusMessage = "Indicizzo MongoDB..."
        DispatchQueue.global(qos: .userInitiated).async {
            let output = self.cli.run(
                ["kb-index-mongodb", "--uri-stdin", "--database", trimmedDatabase, "--collection", trimmedCollection],
                standardInput: trimmedURI
            )
            DispatchQueue.main.async {
                let message = output.contains("\"indexed\"")
                    ? "MongoDB indicizzato"
                    : (output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Indicizzazione MongoDB non riuscita" : output)
                self.statusMessage = message
                completion(message)
            }
        }
    }

    func saveMeetingChat(
        destination: String,
        question: String,
        answer: String,
        citations: [MeetingChatCitationPayload],
        completion: @escaping (String) -> Void
    ) {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion("Nessuna risposta da salvare")
            return
        }
        statusMessage = "Salvo risposta chat..."
        DispatchQueue.global(qos: .userInitiated).async {
            let citationPayload = citations.map {
                [
                    "title": $0.title,
                    "date": $0.date ?? "",
                    "destination": $0.destination,
                    "url": $0.url
                ]
            }
            let payload: [String: Any] = [
                "destination": destination,
                "question": question,
                "answer": answer,
                "citations": citationPayload
            ]
            let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
            let output = self.cli.run(["chat-save", "--payload-stdin"], standardInput: payloadJSON)
            DispatchQueue.main.async {
                let message = output.contains("\"provider\"")
                    ? "Risposta salvata"
                    : (cliFailureLine(output).isEmpty ? "Salvataggio non riuscito" : cliFailureLine(output))
                if !output.contains("\"provider\"") { AppLog.append("Salvataggio chat fallito\n\(output)") }
                self.statusMessage = message
                completion(message)
            }
        }
    }

    func saveProviderSettings(mode: String, baseURL: String, localModelsDir: String, model: String, apiKey: String, jsonMode: Bool, remoteProviderKind: String? = nil, localRuntime: String? = nil, summaryPrompt: String? = nil) {
        if mode == "apple" && !appleIntelligenceAvailable {
            providerStatusMessage = "Apple Intelligence non disponibile: \(appleIntelligenceReason)"
            return
        }
        let resolvedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultProviderBaseURL(for: mode)
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedLocalBaseURL = mode == "local"
            ? resolvedBaseURL
            : (localProviderBaseURL.isEmpty ? defaultProviderBaseURL(for: "local") : localProviderBaseURL)
        let savedRemoteBaseURL = mode == "api"
            ? resolvedBaseURL
            : (remoteProviderBaseURL.isEmpty ? defaultProviderBaseURL(for: "api") : remoteProviderBaseURL)
        let activeBaseURL = mode == "local"
            ? savedLocalBaseURL
            : (mode == "api" ? savedRemoteBaseURL : resolvedBaseURL)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let localKey = mode == "local" ? trimmedKey : localProviderAPIKey
        let remoteKey = mode == "api" ? trimmedKey : remoteProviderAPIKey
        let localModel = mode == "local" ? trimmedModel : localProviderModel
        let remoteModel = mode == "api" ? trimmedModel : remoteProviderModel
        EnvFile.update(
            at: envURL,
            values: [
                "SUMMARY_PROVIDER_MODE": mode,
                "LOCAL_MODELS_DIR": localModelsDir.trimmingCharacters(in: .whitespacesAndNewlines),
                "SUMMARY_BASE_URL": activeBaseURL,
                "LOCAL_SUMMARY_BASE_URL": savedLocalBaseURL,
                "REMOTE_SUMMARY_BASE_URL": savedRemoteBaseURL,
                "SUMMARY_MODEL": trimmedModel,
                "LOCAL_SUMMARY_MODEL": localModel,
                "REMOTE_SUMMARY_MODEL": remoteModel,
                "SUMMARY_API_KEY": trimmedKey,
                "LOCAL_SUMMARY_API_KEY": localKey,
                "REMOTE_SUMMARY_API_KEY": remoteKey,
                // The Meeting Pilot model always answers in JSON (builtin_model.py); the others follow the setting.
                "SUMMARY_RESPONSE_FORMAT_JSON": mode == "builtin" ? "true" : (mode == "local" || mode == "apple" ? "false" : (jsonMode ? "true" : "false")),
                "BUILTIN_SUMMARY_MODEL": mode == "builtin" ? trimmedModel : builtinSummaryModel,
                "SUMMARY_PROMPT": (summaryPrompt ?? self.summaryPrompt).trimmingCharacters(in: .whitespacesAndNewlines),
                "REMOTE_PROVIDER_KIND": remoteProviderKind ?? self.remoteProviderKind,
                "LOCAL_SUMMARY_RUNTIME": localRuntime ?? self.localRuntime,
                // Read by the pipeline only for local mode (e.g. Ollama's native API).
                "SUMMARY_RUNTIME": mode == "local" ? (localRuntime ?? self.localRuntime) : "",
                "APPLE_INTELLIGENCE_DEFAULT_APPLIED": "true"
            ]
        )
        localProviderModel = localModel
        remoteProviderModel = remoteModel
        if mode == "builtin" { builtinSummaryModel = trimmedModel }
        if let localRuntime { self.localRuntime = localRuntime }
        localProviderBaseURL = savedLocalBaseURL
        remoteProviderBaseURL = savedRemoteBaseURL
        providerBaseURL = activeBaseURL
        watcher.restartIfRunning()
        // Settings autosave; a stale test result would describe the previous values.
        providerStatusMessage = ""
        refresh()
    }

    func saveSummaryPrompt(_ prompt: String) {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leaving the Pipeline page saves unconditionally; without this guard every visit
        // restarted a running watcher even though nothing changed.
        guard value != summaryPrompt else { return }
        EnvFile.update(at: envURL, values: ["SUMMARY_PROMPT": value])
        summaryPrompt = value
        watcher.restartIfRunning()
    }

    func saveSummaryTemplate(_ id: String) {
        guard id != summaryTemplate else { return }
        EnvFile.update(at: envURL, values: ["SUMMARY_TEMPLATE": id])
        summaryTemplate = id
        watcher.restartIfRunning()
    }

    /// The pipeline re-reads this file for every meeting, so no watcher restart is needed.
    func saveCustomSummaryTemplates(_ templates: [CustomSummaryTemplate]) {
        let cleaned = templates.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard cleaned != customSummaryTemplates else { return }
        let url = configRoot.appendingPathComponent(SummaryTemplateCatalog.fileName)
        do {
            try SummaryTemplateCatalog.saveCustom(cleaned, to: url)
        } catch {
            AppLog.append("Salvataggio modelli di sintesi non riuscito (\(url.path)): \(error.localizedDescription)")
            statusMessage = "Non riesco a salvare i modelli di sintesi: \(error.localizedDescription)"
            return
        }
        customSummaryTemplates = cleaned
        if !SummaryTemplateCatalog.options(custom: cleaned).contains(where: { $0.id == summaryTemplate }) {
            saveSummaryTemplate(SummaryTemplateCatalog.auto)
        }
    }

    func testProviderConnection(mode: String, baseURL: String, apiKey: String, model: String) {
        if mode == "apple" {
            let status = currentAppleIntelligenceAvailability()
            appleIntelligenceAvailable = status.available
            appleIntelligenceReason = status.reason
            providerStatusMessage = status.available ? "Apple Intelligence disponibile" : "Apple Intelligence non disponibile: \(status.reason)"
            return
        }
        let resolvedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultProviderBaseURL(for: mode)
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        providerStatusMessage = "Test connessione..."
        DispatchQueue.global(qos: .userInitiated).async {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // The key goes through curl's stdin config, not argv, so `ps` can't show it.
            var arguments = ["-sS", "-m", "8", "\(resolvedBaseURL)/models"]
            var curlConfig: String?
            if !key.isEmpty {
                arguments += ["-K", "-"]
                let escapedKey = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                curlConfig = "header = \"Authorization: Bearer \(escapedKey)\"\n"
            }
            let output = Shell.run("/usr/bin/curl", arguments, standardInput: curlConfig)
            let requestedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard self.isProviderModelsResponse(output) else {
                    self.providerModelOptions = []
                    self.providerStatusMessage = "Connessione non riuscita"
                    return
                }
                self.providerModelOptions = self.providerModelIDs(in: output)
                guard !requestedModel.isEmpty else {
                    self.providerStatusMessage = "Connessione OK"
                    return
                }
                self.providerStatusMessage = self.providerModelExists(requestedModel, in: output)
                    ? "Connessione OK · modello disponibile"
                    : String(format: localized("Connessione OK, ma il modello %@ non esiste"), requestedModel)
            }
        }
    }

    private func isProviderModelsResponse(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return response["data"] is [Any] || response["models"] is [Any]
    }

    /// Checks every known runtime at its default port, and the selected one at the
    /// endpoint the user configured, so the form can say which are actually running.
    func probeLocalRuntimes(selected: String, baseURL: String, apiKey: String) {
        var targets: [(runtime: String, url: String, key: String)] = LocalRuntime.allCases
            .filter { $0 != .other && $0.rawValue != selected }
            .map { ($0.rawValue, $0.defaultBaseURL, "") }
        let selectedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (LocalRuntime(rawValue: selected)?.defaultBaseURL ?? "")
            : baseURL
        targets.append((selected, selectedURL, apiKey))
        Task {
            var found: [String: [String]] = [:]
            await withTaskGroup(of: (String, [String]?).self) { group in
                for target in targets {
                    group.addTask { (target.runtime, await fetchLocalModelIDs(baseURL: target.url, apiKey: target.key)) }
                }
                for await (runtime, models) in group {
                    if let models { found[runtime] = models }
                }
            }
            let result = found
            await MainActor.run {
                self.localRuntimeModels = result
                self.localRuntimesProbed = true
            }
        }
    }

    /// Optional: pulls a model through the user's own Ollama install, streaming progress.
    func downloadOllamaModel(_ name: String, baseURL: String, onFinished: @escaping () -> Void) {
        guard modelDownload == nil || modelDownload?.failed == true else { return }
        modelDownload = LocalModelDownload(model: name, progress: nil, status: "Avvio download…")
        let root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/v1/?$"#, with: "", options: .regularExpression)
        modelDownloadTask = Task {
            do {
                guard let url = URL(string: root + "/api/pull") else { throw URLError(.badURL) }
                var request = URLRequest(url: url, timeoutInterval: 3600)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                for try await line in bytes.lines {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let message = event["error"] as? String {
                        throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    }
                    let total = (event["total"] as? Double) ?? 0
                    let completed = (event["completed"] as? Double) ?? 0
                    let status = (event["status"] as? String) ?? ""
                    await MainActor.run {
                        self.modelDownload = LocalModelDownload(
                            model: name,
                            progress: total > 0 ? completed / total : nil,
                            status: status
                        )
                    }
                }
                await MainActor.run {
                    self.modelDownload = nil
                    self.modelDownloadTask = nil
                    onFinished()
                }
            } catch {
                await MainActor.run {
                    self.modelDownloadTask = nil
                    self.modelDownload = Task.isCancelled
                        ? nil
                        : LocalModelDownload(model: name, progress: nil, status: error.localizedDescription, failed: true)
                }
            }
        }
    }

    func cancelModelDownload() {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelDownload = nil
    }

    private func providerModelIDs(in output: String) -> [String] {
        guard let data = output.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        let candidates = (response["data"] as? [[String: Any]]) ?? (response["models"] as? [[String: Any]]) ?? []
        let ids = candidates.compactMap { ($0["id"] ?? $0["name"] ?? $0["model"]) as? String }
        return Array(Set(ids)).sorted()
    }

    private func providerModelExists(_ requestedModel: String, in output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        let candidates = (response["data"] as? [[String: Any]]) ?? (response["models"] as? [[String: Any]]) ?? []
        return candidates.contains { candidate in
            [candidate["id"], candidate["name"], candidate["model"]]
                .compactMap { $0 as? String }
                .contains(requestedModel)
        }
    }

    func savePageSections(_ sections: [PageSection: Bool]) {
        EnvFile.update(
            at: envURL,
            values: Dictionary(uniqueKeysWithValues: sections.map { ($0.key.envKey, $0.value ? "true" : "false") })
        )
        statusMessage = "Formato note salvato"
        refresh()
    }

    func saveUserProfile(_ profile: UserProfile) {
        EnvFile.update(at: envURL, values: ["USER_PROFILE": profile.rawValue])
        userProfile = profile
        needsProfileChoice = false
        statusMessage = "Profilo salvato"
        watcher.restartIfRunning()
    }

    func saveKeepAudio(_ keep: Bool) {
        EnvFile.update(at: envURL, values: ["KEEP_AUDIO": keep ? "true" : "false"])
        statusMessage = keep ? "L'audio delle riunioni verrà conservato" : "L'audio verrà eliminato dopo la pubblicazione"
        refresh()
    }

    func saveRecorderSettings(mode: String, folder: String, promptEnabled: Bool, promptDelaySeconds: Int, openTarget: String, transcriptionProvider: String) {
        if transcriptionProvider == "fluid" && !fluidTranscriptionAvailable(in: EnvFile.load(from: envURL)) {
            statusMessage = "Scarica prima il modello Parakeet"
            return
        }
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultRecorderFolder(for: mode)
            : folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOpenTarget = openTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedOpenTarget: String
        switch mode {
        case "transcribex":
            resolvedOpenTarget = "TranscribeX"
        case "macos_prompt":
            resolvedOpenTarget = ""
        default:
            resolvedOpenTarget = trimmedOpenTarget.isEmpty ? trimmedFolder : trimmedOpenTarget
        }
        EnvFile.update(
            at: envURL,
            values: [
                "RECORDER_MODE": mode,
                "INBOX_AUDIO_DIR": trimmedFolder,
                "RECORDING_PROMPT_ENABLED": (mode == "macos_prompt" || promptEnabled) ? "true" : "false",
                "RECORDING_PROMPT_DELAY_SECONDS": "\(max(1, promptDelaySeconds))",
                "RECORDER_OPEN_TARGET": resolvedOpenTarget,
                "TRANSCRIPTION_PROVIDER": transcriptionProvider,
                "TRANSCRIPTION_LOCALE": transcriptionLocale,
                "APPLE_TRANSCRIBER_CMD": appleTranscriberCommandPath()
            ]
        )
        statusMessage = "Recorder salvato"
        watcher.restartIfRunning { restarted in
            if restarted { self.statusMessage = "Recorder salvato" }
        }
        recording.resetMeetingDetection()
        requestAppleSpeechAuthorizationIfNeeded()
        refresh()
    }

    func saveRecordingAudioSource(_ source: RecordingAudioSource) {
        guard source != recordingAudioSource else { return }
        EnvFile.update(at: envURL, values: ["RECORDING_AUDIO_SOURCE": source.rawValue])
        recordingAudioSource = source
        statusMessage = "Recorder salvato"
    }

    func saveRecorderFolder(_ folder: String) {
        saveRecorderSettings(
            mode: recorderMode,
            folder: folder,
            promptEnabled: recordingPromptEnabled,
            promptDelaySeconds: recordingPromptDelaySeconds,
            openTarget: recorderOpenTarget,
            transcriptionProvider: transcriptionProvider
        )
    }

    func savePublicationTargets(_ targets: Set<String>) {
        let normalized = normalizePublicationTargets(targets)
        EnvFile.update(
            at: envURL,
            values: [
                "PUBLISH_TARGETS": normalized.joined(separator: ","),
                "PUBLISH_TARGETS_EXPLICIT": "true"
            ]
        )
        publicationTargets = Set(normalized)
        statusMessage = "Servizi pubblicazione salvati"
        refresh()
    }

    func openJournal(at root: String? = nil) {
        let path = (root ?? journalRoot).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let url = expandPath(path)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            AppLog.append("Creazione cartella Diario non riuscita (\(url.path)): \(error.localizedDescription)")
            statusMessage = "Non riesco a creare la cartella del Diario: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func showDiaryWindow() {
        openDiaryWindow?()
    }

    func togglePublicationTarget(_ target: String) {
        var updated = publicationTargets
        if updated.contains(target) {
            updated.remove(target)
        } else {
            updated.insert(target)
        }
        savePublicationTargets(updated)
    }

    func saveObsidianSettings(vaultPath: String, folder: String, filenameTemplate: String) {
        let trimmedVaultPath = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTemplate = filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if publicationTargets.contains("obsidian") && trimmedVaultPath.isEmpty {
            statusMessage = "Scegli prima il vault Obsidian"
            return
        }
        EnvFile.update(
            at: envURL,
            values: [
                "OBSIDIAN_VAULT_PATH": trimmedVaultPath,
                "OBSIDIAN_FOLDER": trimmedFolder.isEmpty ? "Meeting Pilot" : trimmedFolder,
                "OBSIDIAN_FILENAME_TEMPLATE": trimmedTemplate.isEmpty ? "{date} - {title}.md" : trimmedTemplate
            ]
        )
        statusMessage = "Obsidian salvato"
        refresh()
    }

    func saveBusinessGlossary(_ value: String) {
        let lines = value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = Array(NSOrderedSet(array: lines)) as? [String] ?? lines
        let text = normalized.joined(separator: "\n")
        let url = configRoot.appendingPathComponent("business-glossary.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.append("Salvataggio vocabolario non riuscito (\(url.path)): \(error.localizedDescription)")
            statusMessage = "Non riesco a salvare il vocabolario: \(error.localizedDescription)"
            return
        }
        businessGlossary = text
        EnvFile.update(at: envURL, values: ["BUSINESS_GLOSSARY_FILE": url.path])
        statusMessage = "Vocabolario aziendale salvato"
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MediaImportInspector.contentTypes
        panel.prompt = localized("Importa")
        panel.message = localized("Scegli registrazioni, video di lezioni o podcast da trascrivere, e se vuoi il PDF delle slide.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        requestImport(panel.urls)
    }

    func chooseSlidesPDF() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = localized("Scegli")
        panel.message = localized("Scegli il PDF delle slide mostrate durante la registrazione.")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Adds to a sheet that is already open instead of replacing its files.
    func requestImport(_ urls: [URL]) {
        guard var request = importRequest else {
            importRequest = MediaImportRequest(urls: urls)
            return
        }
        request.urls += urls.filter { !request.urls.contains($0) }
        importRequest = request
    }

    /// Imported files land in the same inbox the recorder writes to, so the watcher
    /// transcribes and publishes them like recordings.
    func importMedia(_ drafts: [MediaImportDraft], options: MediaImportOptions) {
        importRequest = nil
        let inbox = recorderFolder.isEmpty ? defaultRecorderFolder(for: recorderMode) : recorderFolder
        importer.start(drafts, options: options, inbox: expandPath(inbox))
    }

    func chooseRecorderFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: recorderFolder.isEmpty ? defaultRecorderFolder(for: recorderMode) : recorderFolder)
        panel.prompt = "Scegli"
        panel.message = "Scegli la cartella dove il recorder salva automaticamente gli audio."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func chooseRecorderApp() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Scegli app"
        panel.message = "Scegli il recorder da aprire quando premi Avvia."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func chooseObsidianVault() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = obsidianVaultPath.isEmpty ? projectRoot : URL(fileURLWithPath: expandPath(obsidianVaultPath).path)
        panel.prompt = "Scegli"
        panel.message = "Scegli la cartella principale del vault Obsidian."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func chooseModelsFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: defaultLocalModelsDir()).expandingTildeInPath)
        panel.prompt = "Scegli"
        panel.message = "Scegli la cartella dove scarichi o conservi i modelli locali."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func openObsidianVault(at path: String? = nil) {
        let targetPath = (path ?? obsidianVaultPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            statusMessage = "Scegli prima il vault Obsidian"
            return
        }

        let url = expandPath(targetPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        statusMessage = "Vault Obsidian aperto"
    }

    func openObsidianApp() {
        let appURL = URL(fileURLWithPath: "/Applications/Obsidian.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    if let error {
                        self?.statusMessage = "Impossibile aprire Obsidian: \(error.localizedDescription)"
                    } else {
                        self?.statusMessage = "Obsidian aperto"
                    }
                }
            }
            return
        }

        let obsidianScheme = URL(string: "obsidian://open")!
        if NSWorkspace.shared.open(obsidianScheme) {
            statusMessage = "Obsidian aperto"
        } else {
            statusMessage = "Obsidian non è installato"
        }
    }

    func openAppleNotes() {
        let appURL = URL(fileURLWithPath: "/System/Applications/Notes.app")
        if NSWorkspace.shared.open(appURL) {
            statusMessage = "Apple Notes aperto"
        } else if NSWorkspace.shared.open(URL(string: "notes:")!) {
            statusMessage = "Apple Notes aperto"
        } else {
            statusMessage = "Apple Notes non è disponibile"
        }
    }

    func openAccessibilitySettings() {
        requestAccessibilityPermission()
        statusMessage = "Abilita Meeting Pilot in Accessibilità, poi torna qui: acquisiremo titolo e partecipanti Teams."
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        watchAccessibilityPermission()
    }

    func confirmAccessibilityPermission() {
        refreshPermissionRows()
        if accessibilityGranted {
            statusMessage = "Accessibilità attiva"
        } else {
            statusMessage = "Accessibilità non ancora attiva: abilita Meeting Pilot nelle Impostazioni di Sistema"
        }
    }

    private func watchAccessibilityPermission() {
        accessibilityPermissionTimer?.invalidate()
        PermissionCoachWindow.shared.show(
            permissionTitle: "Accessibilita",
            settingsPath: "Impostazioni di Sistema > Privacy e sicurezza > Accessibilita",
            autoDetect: { AXIsProcessTrusted() }
        )
        var remainingChecks = 45
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.refreshPermissionRows()
            remainingChecks -= 1
            if self.accessibilityGranted {
                self.statusMessage = "Accessibilità attiva"
                timer.invalidate()
            } else if remainingChecks == 0 {
                timer.invalidate()
                PermissionCoachWindow.shared.close()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPermissionTimer = timer
    }

    private func appleTranscriberCommandPath() -> String {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("AppleTranscriber")
            .path
        ?? projectRoot.appendingPathComponent("macos/MeetingPilot/build/Meeting Pilot.app/Contents/MacOS/AppleTranscriber").path
    }

    private func appleIntelligenceSummarizerCommandPath() -> String {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("AppleIntelligenceSummarizer")
            .path
        ?? projectRoot.appendingPathComponent("macos/MeetingPilot/build/Meeting Pilot.app/Contents/MacOS/AppleIntelligenceSummarizer").path
    }

    func openLogs() {
        AppLog.ensureDirectory()
        NSWorkspace.shared.open(AppLog.directory)
    }

    func refreshLogs() {
        let env = EnvFile.load(from: envURL)
        logTail = diagnosticLogText(meetingsRoot: expandPath(env["MEETINGS_ROOT"] ?? "~/TeamsMeetings"))
    }

    func copyLogs() {
        refreshLogs()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logTail, forType: .string)
        statusMessage = "Log copiati"
    }

    func openProject() {
        NSWorkspace.shared.open(projectRoot)
    }

    func assignProject(to meeting: MeetingItem) {
        assignTag(
            to: meeting,
            title: "Modifica progetto",
            message: "Il progetto organizza questa riunione in Meeting Pilot e Notion.",
            placeholder: "es. Agentic AI",
            currentValue: meeting.project,
            propertyName: "Project",
            metadataKey: "project",
            metadataFilename: "meeting_project.json",
            receiptKey: "meeting_pilot_project",
            successLabel: "Progetto salvato"
        )
    }

    func assignTheme(to meeting: MeetingItem) {
        assignTag(
            to: meeting,
            title: "Aggiungi tema",
            message: "Il tema verrà aggiunto a questa riunione in Meeting Pilot e Notion.",
            placeholder: "es. Pianificazione trimestrale",
            currentValue: nil,
            existingValues: meeting.themes,
            propertyName: "Tema",
            metadataKey: "theme",
            metadataFilename: "meeting_theme.json",
            receiptKey: "meeting_pilot_theme",
            successLabel: "Tema salvato"
        )
    }

    private func assignTag(
        to meeting: MeetingItem,
        title: String,
        message: String,
        placeholder: String,
        currentValue: String?,
        existingValues: [String] = [],
        propertyName: String,
        metadataKey: String,
        metadataFilename: String,
        receiptKey: String,
        successLabel: String
    ) {
        let alert = NSAlert()
        alert.messageText = localized(title)
        alert.informativeText = localized(message)
        alert.addButton(withTitle: localized("Salva"))
        alert.addButton(withTitle: localized("Annulla"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = placeholder
        input.stringValue = currentValue ?? ""
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let values = metadataKey == "theme"
            ? Array(Set(existingValues + [value])).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            : [value]

        statusMessage = "Salvo \(metadataKey)..."
        do {
            try saveLocalMeetingTag(
                sessionDirectory: URL(fileURLWithPath: meeting.id),
                values: values,
                metadataKey: metadataKey,
                metadataFilename: metadataFilename
            )
        } catch {
            AppLog.append("Salvataggio \(metadataFilename) non riuscito (\(meeting.id)): \(error.localizedDescription)")
            statusMessage = "Non riesco a salvare il tag: \(error.localizedDescription)"
            return
        }
        addConfirmedTagToCatalog(kind: metadataKey == "project" ? "project" : "topic", value: value)
        let notionToken = notion.token
        let notionDatabaseID = notion.occurrencesDatabaseId
        let syncToNotion = publicationTargets.contains("notion") && !notionToken.isEmpty && !notionDatabaseID.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            guard syncToNotion else {
                DispatchQueue.main.async {
                    self.statusMessage = "\(successLabel): \(value)"
                    self.refresh()
                }
                return
            }
            let result = NotionProjectAssigner.assign(
                sessionDirectory: URL(fileURLWithPath: meeting.id),
                values: values,
                token: notionToken,
                databaseID: notionDatabaseID,
                propertyName: propertyName,
                metadataKey: metadataKey,
                metadataFilename: metadataFilename,
                receiptKey: receiptKey
            )
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.statusMessage = "\(successLabel): \(value)"
                case .failure(let error):
                    self.statusMessage = "\(localized(successLabel)): \(value) · \(localized("Notion non sincronizzato"))"
                    AppLog.append("Sincronizzazione Notion del tag non riuscita: \(error.localizedDescription)")
                }
                self.refresh()
            }
        }
    }

    private func saveLocalMeetingTag(
        sessionDirectory: URL,
        values: [String],
        metadataKey: String,
        metadataFilename: String
    ) throws {
        let metadata: [String: Any] = [
            metadataKey: values.first ?? "",
            "\(metadataKey)s": values,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sessionDirectory.appendingPathComponent(metadataFilename), options: .atomic)
    }

    private func addConfirmedTagToCatalog(kind: String, value: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = self.cli.run(["tag-catalog-add", "--kind", kind, "--value", value])
            DispatchQueue.main.async {
                self.refreshChatFilterValues()
            }
        }
    }
}

func presentErrorAlert(_ title: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = localized(title)
    alert.informativeText = localized(detail.isEmpty ? "Nessun dettaglio restituito dal comando." : detail)
    alert.alertStyle = .warning
    alert.addButton(withTitle: localized("OK"))
    alert.runModal()
}

/// The CLI prints its progress and, on failure, a traceback before one readable
/// last line; the app shows that line and keeps the rest for the log.
func cliFailureLine(_ output: String) -> String {
    output
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last(where: { !$0.isEmpty }) ?? ""
}
