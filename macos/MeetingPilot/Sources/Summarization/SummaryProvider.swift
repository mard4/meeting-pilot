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


struct SummaryConfigurationForm: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode = "local"
    @State private var remoteProviderKind = "gpt"
    @State private var baseURL = ""
    @State private var localBaseURL = ""
    @State private var remoteBaseURL = ""
    @State private var modelsDir = ""
    @State private var summaryModel = ""
    @State private var localSummaryModel = ""
    @State private var remoteSummaryModel = ""
    @State private var apiKey = ""
    @State private var localAPIKey = ""
    @State private var remoteAPIKey = ""
    @State private var jsonMode = false
    @State private var localModelOptions: [String] = []
    @State private var autoSaveTask: DispatchWorkItem?
    @State private var showAdvanced = false
    @State private var localRuntime = LocalRuntime.omlx.rawValue
    @State private var confirmingCloudProvider = false

    private var selectedRuntime: LocalRuntime { LocalRuntime(rawValue: localRuntime) ?? .omlx }
    private var runtimeModels: [String]? { model.localRuntimeModels[localRuntime] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                appleEngineCard
                    .frame(maxHeight: .infinity)
                RecorderChoiceCard(
                    title: "Meeting Pilot",
                    subtitle: "Il modello di Meeting Pilot, sul Mac. Si scarica una volta, niente da installare.",
                    assetName: nil,
                    fallbackSymbol: "sparkles",
                    selected: mode == "builtin"
                ) {
                    selectProviderMode("builtin")
                }
                .frame(maxHeight: .infinity)
                RecorderChoiceCard(
                    title: "Modello locale",
                    subtitle: "oMLX, Ollama o LM Studio, se li hai installati sul Mac.",
                    assetName: nil,
                    fallbackSymbol: "cpu",
                    selected: mode == "local"
                ) {
                    selectProviderMode("local")
                }
                .frame(maxHeight: .infinity)
                RecorderChoiceCard(
                    title: "Cloud",
                    subtitle: "OpenAI, Gemini, Claude o compatibile. Il transcript viene inviato al provider.",
                    assetName: nil,
                    fallbackSymbol: "cloud",
                    selected: mode == "api"
                ) {
                    // Cloud is the only mode where meeting content leaves the Mac, so confirm first.
                    if mode != "api" {
                        confirmingCloudProvider = true
                    }
                }
                .frame(maxHeight: .infinity)
                .alert("Il transcript verrà inviato al cloud", isPresented: $confirmingCloudProvider) {
                    Button("Annulla", role: .cancel) {}
                    Button("Usa Cloud") {
                        selectProviderMode("api")
                    }
                } message: {
                    Text("Con un provider cloud, il transcript di ogni riunione viene inviato al servizio scelto (OpenAI, Gemini, Claude o compatibile) per generare la sintesi. Con Apple Intelligence o un modello locale resta tutto sul Mac.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if mode == "builtin" {
                SettingsFormPanel { builtinSettingsRows }
            } else if mode == "local" {
                SettingsFormPanel { localSettingsRows }
            } else if mode == "api" {
                SettingsFormPanel { cloudSettingsRows }
            }

            // The Meeting Pilot model has no server to test: each row shows whether it is ready.
            if mode == "local" || mode == "api" {
                HStack(spacing: 10) {
                    Button {
                        // Testing used to operate only on the transient form state.
                        // A successful test could therefore be followed by a 401 in
                        // the watcher, which reads the persisted .env instead.
                        let resolvedBaseURL = mode == "api" && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? remoteOfficialBaseURL(for: remoteProviderKind)
                            : baseURL
                        saveProviderSettings()
                        model.testProviderConnection(mode: mode, baseURL: resolvedBaseURL, apiKey: apiKey, model: summaryModel)
                        if mode == "local" { probeRuntimes() }
                    } label: {
                        Label(localized("Verifica connessione"), systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
                    if !model.providerStatusMessage.isEmpty {
                        ProviderTestStatus(message: model.providerStatusMessage)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            mode = model.providerMode
            localBaseURL = model.localProviderBaseURL
            remoteBaseURL = model.remoteProviderBaseURL
            baseURL = mode == "local" ? localBaseURL : (mode == "api" ? remoteBaseURL : model.providerBaseURL)
            modelsDir = model.localModelsDir
            localSummaryModel = model.localProviderModel
            remoteSummaryModel = model.remoteProviderModel
            summaryModel = mode == "local" ? localSummaryModel : (mode == "api" ? remoteSummaryModel : model.providerModel)
            localAPIKey = model.localProviderAPIKey
            remoteAPIKey = model.remoteProviderAPIKey
            apiKey = mode == "local" ? localAPIKey : (mode == "api" ? remoteAPIKey : "")
            jsonMode = model.providerJSONMode
            remoteProviderKind = model.remoteProviderKind
            localRuntime = model.localRuntime
            model.providerStatusMessage = ""
            // Cloud defaults must not leak into the local endpoint: the two modes share `baseURL`.
            if mode == "api" {
                applyRemoteProviderDefaults(force: false)
            } else if mode == "local" && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                baseURL = selectedRuntime.defaultBaseURL
            }
            refreshLocalModelOptions()
            if mode == "local" { probeRuntimes() }
        }
        .onChange(of: baseURL) { value in
            if mode == "local" { localBaseURL = value }
            if mode == "api" { remoteBaseURL = value }
            scheduleAutomaticProviderSave()
        }
        .onChange(of: modelsDir) { _ in scheduleAutomaticProviderSave() }
        // A finished download selects its model from AppModel; keep the form in step.
        .onChange(of: model.builtinSummaryModel) { value in
            if mode == "builtin" { summaryModel = value }
        }
        .onChange(of: summaryModel) { _ in scheduleAutomaticProviderSave() }
        .onChange(of: apiKey) { _ in scheduleAutomaticProviderSave() }
        .onChange(of: jsonMode) { _ in scheduleAutomaticProviderSave() }
        .onChange(of: remoteProviderKind) { _ in
            // onAppear also assigns the kind; only a user choice in Cloud mode should apply defaults.
            guard mode == "api" else { return }
            model.providerModelOptions = []
            model.providerStatusMessage = ""
            applyRemoteProviderDefaults()
            persistSelectedProvider()
        }
        .onDisappear {
            autoSaveTask?.cancel()
            saveProviderSettings(deferred: true)
        }
    }

    /// Apple Intelligence can't be selected while macOS reports it unavailable, but the
    /// card stays fully legible and carries the fix inline instead of a separate banner.
    private var appleEngineCard: some View {
        let available = model.appleIntelligenceAvailable
        let reason = model.appleIntelligenceReason
        let fixable = !available
            && !reason.contains("non supporta")
            && !reason.contains("macOS 26")
            && !reason.hasPrefix("Verifica")
        return RecorderChoiceCard(
            title: "Apple Intelligence",
            subtitle: available ? "Integrato in macOS, nessuna configurazione." : reason,
            assetName: nil,
            fallbackSymbol: "apple.logo",
            selected: mode == "apple",
            recommended: available,
            unavailable: !available,
            unavailableActionTitle: fixable ? "Apri Impostazioni" : nil,
            unavailableAction: { model.openAppleIntelligenceSettings() }
        ) {
            selectProviderMode("apple")
        }
    }

    @ViewBuilder
    private var builtinSettingsRows: some View {
        Text(localized("Gira sul Mac con il motore incluso nell'app. Si avvia solo mentre scrive le note, poi libera la memoria."))
            .font(MPFont.callout())
            .foregroundStyle(MeetingPilotDesign.textDimColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
        ForEach(BuiltinModelVariant.allCases) { variant in
            Divider()
            BuiltinModelRow(variant: variant, selected: summaryModel == variant.rawValue) {
                summaryModel = variant.rawValue
                persistSelectedProvider()
            }
        }
    }

    @ViewBuilder
    private var localSettingsRows: some View {
        SettingsFormRow(label: "Server") {
            HStack(spacing: 6) {
                ForEach(LocalRuntime.allCases) { runtime in
                    LocalRuntimeChip(
                        runtime: runtime,
                        selected: localRuntime == runtime.rawValue,
                        running: model.localRuntimeModels[runtime.rawValue] != nil
                    ) {
                        selectLocalRuntime(runtime)
                    }
                }
            }
        }
        if model.localRuntimesProbed && runtimeModels == nil {
            Divider()
            runtimeOfflineRow
        }
        Divider()
        SettingsFormRow(label: "Modello", hint: localModelHint) {
            if selectedRuntime == .omlx {
                LocalModelPicker(
                    options: Array(Set(localModelOptions + (runtimeModels ?? []))).sorted(),
                    selectedModel: $summaryModel,
                    onRefresh: {
                        refreshLocalModelOptions()
                        probeRuntimes()
                    },
                    onChooseFolder: {
                        if let selected = model.chooseModelsFolder() {
                            modelsDir = selected
                            refreshLocalModelOptions()
                        }
                    }
                )
            } else {
                ModelNameField(placeholder: localized("Nome del modello"), text: $summaryModel, options: runtimeModels ?? [])
            }
        }
        if selectedRuntime == .ollama && runtimeModels != nil {
            Divider()
            SettingsFormRow(label: "Scarica", hint: "Facoltativo. Il modello viene scaricato da Ollama e resta sul Mac.") {
                OllamaModelDownloadControl(
                    installed: Set(runtimeModels ?? []),
                    onDownload: { name in
                        model.downloadOllamaModel(name, baseURL: baseURL) {
                            summaryModel = name
                            probeRuntimes()
                        }
                    }
                )
            }
        }
        if selectedRuntime == .other {
            Divider()
            localConnectionRows
        } else {
            Divider()
            advancedToggle
            if showAdvanced {
                localConnectionRows
            }
        }
    }

    @ViewBuilder
    private var localConnectionRows: some View {
        SettingsFormRow(label: "Endpoint") {
            TextField(selectedRuntime == .other ? "http://127.0.0.1:8080/v1" : selectedRuntime.defaultBaseURL, text: $baseURL)
                .textFieldStyle(DarkTextFieldStyle())
                .onSubmit { probeRuntimes() }
        }
        SettingsFormRow(label: "Secret", hint: "Serve solo se il server richiede una chiave.") {
            RevealableSecretField(placeholder: "Facoltativo", text: $apiKey)
        }
    }

    private var runtimeOfflineRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(MeetingPilotDesign.warning)
            Text(selectedRuntime == .other
                 ? localized("Nessun server risponde a questo indirizzo.")
                 : String(format: localized("%@ non risponde. Avvialo, oppure installalo se vuoi usarlo."), selectedRuntime.title))
                .font(MPFont.callout())
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let url = selectedRuntime.downloadURL {
                Link(destination: url) {
                    Label(String(format: localized("Scarica %@"), selectedRuntime.title), systemImage: "arrow.up.right")
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
            }
            Button {
                probeRuntimes()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(MPIconButtonStyle(size: 28))
            .help(localized("Controlla di nuovo"))
        }
        .padding(.vertical, 10)
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(.mpSmooth) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(MPFont.caption(.semibold))
                    .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                Text(localized("Avanzate"))
                    .font(MPFont.callout(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(MeetingPilotDesign.textDimColor)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var localModelHint: String? {
        guard let models = runtimeModels, models.isEmpty else { return nil }
        switch selectedRuntime {
        case .ollama: return "Nessun modello installato in Ollama."
        case .lmstudio: return "Scarica e carica un modello dall'app LM Studio."
        default: return "Il server non elenca modelli: controlla il secret o scrivi il nome a mano."
        }
    }

    @ViewBuilder
    private var cloudSettingsRows: some View {
        SettingsFormRow(label: "Provider") {
            HStack(spacing: 6) {
                ForEach(CloudProviderOption.all) { option in
                    CloudProviderChip(option: option, selected: remoteProviderKind == option.kind) {
                        remoteProviderKind = option.kind
                    }
                }
            }
        }
        Divider()
        if remoteProviderKind == "other" {
            SettingsFormRow(label: "Endpoint") {
                TextField(remoteEndpointPlaceholder(for: remoteProviderKind), text: $baseURL)
                    .textFieldStyle(DarkTextFieldStyle())
            }
            Divider()
        }
        SettingsFormRow(label: "API key") {
            VStack(alignment: .leading, spacing: 5) {
                RevealableSecretField(placeholder: "Incolla la chiave", text: $apiKey)
                if let url = apiKeyPageURL(for: remoteProviderKind) {
                    Link(destination: url) {
                        Label(localized("Ottieni una API key"), systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                            .font(MPFont.caption(.medium))
                    }
                    .foregroundStyle(MeetingPilotDesign.accent)
                }
            }
        }
        Divider()
        SettingsFormRow(
            label: "Modello",
            hint: model.providerModelOptions.isEmpty
                ? "Verifica la connessione per scegliere tra i modelli disponibili."
                : nil
        ) {
            ModelNameField(
                placeholder: remoteModelPlaceholder(for: remoteProviderKind),
                text: $summaryModel,
                options: model.providerModelOptions
            )
        }
        if remoteProviderKind != "other" {
            Divider()
            advancedToggle
            if showAdvanced {
                SettingsFormRow(label: "Endpoint") {
                    TextField(remoteEndpointPlaceholder(for: remoteProviderKind), text: $baseURL)
                        .textFieldStyle(DarkTextFieldStyle())
                }
            }
        }
    }

    private func scheduleAutomaticProviderSave() {
        autoSaveTask?.cancel()
        let task = DispatchWorkItem { saveProviderSettings() }
        autoSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: task)
    }

    private func saveProviderSettings(deferred: Bool = false) {
        if mode == "local" {
            localAPIKey = apiKey
            localSummaryModel = summaryModel
            localBaseURL = baseURL
        } else if mode == "api" {
            remoteAPIKey = apiKey
            remoteSummaryModel = summaryModel
            remoteBaseURL = baseURL
        }
        let resolvedBaseURL = mode == "api" && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? remoteOfficialBaseURL(for: remoteProviderKind)
            : baseURL
        let appModel = model
        let (mode, modelsDir, summaryModel, apiKey, jsonMode, remoteProviderKind, localRuntime) =
            (self.mode, self.modelsDir, self.summaryModel, self.apiKey, self.jsonMode, self.remoteProviderKind, self.localRuntime)
        let save = {
            appModel.saveProviderSettings(
                mode: mode,
                baseURL: resolvedBaseURL,
                localModelsDir: modelsDir,
                model: summaryModel,
                apiKey: apiKey,
                jsonMode: jsonMode,
                remoteProviderKind: remoteProviderKind,
                localRuntime: localRuntime
            )
        }
        if deferred {
            DispatchQueue.main.async(execute: save)
        } else {
            save()
        }
    }

    private func refreshLocalModelOptions() {
        let targetDirectory = modelsDir
        DispatchQueue.global(qos: .utility).async {
            let options = discoverLocalModelNames(in: targetDirectory)
            DispatchQueue.main.async {
                guard self.modelsDir == targetDirectory else { return }
                self.localModelOptions = options
                if self.mode == "local",
                   self.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let first = options.first {
                    self.summaryModel = first
                }
            }
        }
    }

    private func applyRemoteProviderDefaults(force: Bool = true) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || trimmedBaseURL.isEmpty || isOfficialRemoteBaseURL(trimmedBaseURL) {
            baseURL = remoteOfficialBaseURL(for: remoteProviderKind)
        }

        if summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summaryModel = remoteDefaultModel(for: remoteProviderKind)
        }
    }

    private func selectProviderMode(_ newMode: String) {
        if mode == "local" {
            localAPIKey = apiKey
            localSummaryModel = summaryModel
        } else if mode == "api" {
            remoteAPIKey = apiKey
            remoteSummaryModel = summaryModel
        }

        mode = newMode

        if newMode == "apple" {
            apiKey = ""
        } else if newMode == "builtin" {
            apiKey = ""
            summaryModel = model.builtinSummaryModel
        } else if newMode == "local" {
            apiKey = localAPIKey
            summaryModel = localSummaryModel
            baseURL = localBaseURL.isEmpty ? selectedRuntime.defaultBaseURL : localBaseURL
            refreshLocalModelOptions()
            probeRuntimes()
        } else if newMode == "api" {
            apiKey = remoteAPIKey
            summaryModel = remoteSummaryModel
            baseURL = remoteBaseURL.isEmpty ? remoteOfficialBaseURL(for: remoteProviderKind) : remoteBaseURL
        }

        persistSelectedProvider()
    }

    private func persistSelectedProvider() {
        if mode == "local" {
            localAPIKey = apiKey
            localSummaryModel = summaryModel
        } else if mode == "api" {
            remoteAPIKey = apiKey
            remoteSummaryModel = summaryModel
        }
        let resolvedBaseURL = mode == "api" && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? remoteOfficialBaseURL(for: remoteProviderKind)
            : baseURL
        model.saveProviderSettings(
            mode: mode,
            baseURL: resolvedBaseURL,
            localModelsDir: modelsDir,
            model: summaryModel,
            apiKey: apiKey,
            jsonMode: jsonMode,
            remoteProviderKind: remoteProviderKind,
            localRuntime: localRuntime
        )
    }

    private func probeRuntimes() {
        model.probeLocalRuntimes(selected: localRuntime, baseURL: baseURL, apiKey: apiKey)
    }

    private func selectLocalRuntime(_ runtime: LocalRuntime) {
        guard runtime.rawValue != localRuntime else { return }
        localRuntime = runtime.rawValue
        baseURL = runtime.defaultBaseURL
        showAdvanced = runtime == .other
        let available = model.localRuntimeModels[runtime.rawValue] ?? []
        if !available.contains(summaryModel) {
            summaryModel = available.first ?? ""
        }
        persistSelectedProvider()
        probeRuntimes()
    }
}

/// One Meeting Pilot model: pick it once it is on the Mac, otherwise download it here.
struct BuiltinModelRow: View {
    @EnvironmentObject private var model: AppModel
    let variant: BuiltinModelVariant
    let selected: Bool
    let onSelect: () -> Void
    @State private var confirmingDelete = false

    private var installed: Bool { model.builtinModelsInstalled.contains(variant.rawValue) }
    private var download: BuiltinModelDownload? {
        model.builtinModelDownload?.variant == variant ? model.builtinModelDownload : nil
    }
    private var downloading: Bool { download != nil && download?.failure == nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: selected && installed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(selected && installed ? MeetingPilotDesign.accent : Color.adaptiveWhite(installed ? 0.35 : 0.15))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(localized(variant.title))
                        .font(MPFont.body(.semibold))
                    Text(variant.sizeLabel)
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                }
                Text(localized(variant.detail))
                    .font(MPFont.callout())
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let download, download.failure == nil {
                    ProgressView(value: download.verifying ? 1 : download.progress)
                        .tint(MeetingPilotDesign.accent)
                    Text(download.verifying
                         ? localized("Verifica del file…")
                         : String(format: localized("Download… %d%%"), Int(download.progress * 100)))
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                } else if let failure = download?.failure {
                    Text(failure)
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(variant.sourceName) · Apache 2.0")
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                }
            }
            Spacer(minLength: 8)
            if downloading {
                Button(localized("Annulla")) { model.cancelBuiltinModelDownload() }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
                    .disabled(download?.verifying == true)
            } else if installed {
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(MPIconButtonStyle(size: 28))
                .help(localized("Elimina il modello dal Mac"))
            } else {
                Button {
                    model.downloadBuiltinModel(variant, selectWhenReady: true)
                } label: {
                    Label(String(format: localized("Scarica (%@)"), variant.sizeLabel), systemImage: "arrow.down.circle")
                }
                .buttonStyle(MPSecondaryButtonStyle(compact: true))
                // One download at a time keeps disk and bandwidth predictable.
                .disabled(model.builtinModelDownload != nil && model.builtinModelDownload?.failure == nil)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if installed { onSelect() }
        }
        .alert(String(format: localized("Eliminare il modello %@?"), localized(variant.title)), isPresented: $confirmingDelete) {
            Button(localized("Annulla"), role: .cancel) {}
            Button(localized("Elimina"), role: .destructive) { model.deleteBuiltinModel(variant) }
        } message: {
            Text(String(format: localized("Libera %@. Potrai riscaricarlo quando vuoi."), variant.sizeLabel))
        }
    }
}

/// Inline result of "Verifica connessione". Autosave is silent; only a test reports here.
struct ProviderTestStatus: View {
    let message: String

    private var inProgress: Bool { message.hasPrefix("Test connessione") }

    private var isError: Bool {
        let lower = message.lowercased()
        return ["errore", "non riesco", "fallito", "non riuscit", "non disponibile", "non esiste"]
            .contains { lower.contains($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if inProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? MeetingPilotDesign.warning : MeetingPilotDesign.success)
            }
            Text(localized(message))
                .foregroundStyle(isError ? MeetingPilotDesign.warning : MeetingPilotDesign.textDimColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(MPFont.callout(.medium))
    }
}

/// One grouped surface for an engine's settings: label-left rows separated by hairlines,
/// instead of a bordered card per field.
struct SettingsFormPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous)
                    .fill(MeetingPilotDesign.hoverColor)
            )
    }
}

struct SettingsFormRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(localized(label))
                .font(MPFont.callout(.medium))
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 5) {
                content
                if let hint {
                    Text(localized(hint))
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }
}

struct RevealableSecretField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(localized(placeholder), text: $text)
                } else {
                    SecureField(localized(placeholder), text: $text)
                }
            }
            .textFieldStyle(DarkTextFieldStyle())
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(MPIconButtonStyle(size: 30))
            .help(localized(revealed ? "Nascondi" : "Mostra"))
        }
    }
}

/// Free-text model name with a picker once the provider has listed its models.
struct ModelNameField: View {
    let placeholder: String
    @Binding var text: String
    let options: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(DarkTextFieldStyle())
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { text = option }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous)
                        .strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1)
                )
                .help(String(format: localized("%lld modelli disponibili"), options.count))
            }
        }
    }
}

struct CloudProviderOption: Identifiable {
    let kind: String
    let title: String
    let assetName: String?
    let fallbackSymbol: String
    var id: String { kind }

    static let all = [
        CloudProviderOption(kind: "gpt", title: "OpenAI", assetName: "openai.png", fallbackSymbol: "sparkles"),
        CloudProviderOption(kind: "gemini", title: "Gemini", assetName: "gemini_logo2.webp", fallbackSymbol: "diamond"),
        CloudProviderOption(kind: "claude", title: "Claude", assetName: "claude_logo", fallbackSymbol: "sun.max"),
        CloudProviderOption(kind: "other", title: "Personalizzato", assetName: nil, fallbackSymbol: "slider.horizontal.3"),
    ]
}

struct ProviderChip: View {
    let title: String
    let assetName: String?
    let fallbackSymbol: String
    let selected: Bool
    var templateIcon = false
    /// nil hides the status dot; otherwise green when the server answered.
    var running: Bool? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                BundledAssetIcon(name: assetName, fallbackSymbol: fallbackSymbol, size: 14, templateRendering: templateIcon)
                Text(localized(title))
                    .font(MPFont.callout(selected ? .semibold : .medium))
                    .lineLimit(1)
                if let running {
                    Circle()
                        .fill(running ? MeetingPilotDesign.success : MeetingPilotDesign.lineStrongColor)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected ? MeetingPilotDesign.textColor : MeetingPilotDesign.textDimColor)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Capsule().fill(selected ? MeetingPilotDesign.accentTint : (hovering ? MeetingPilotDesign.hoverColor : MeetingPilotDesign.elevatedColor))
            )
            .overlay(
                Capsule().strokeBorder(selected ? MeetingPilotDesign.accent.opacity(0.7) : MeetingPilotDesign.lineStrongColor, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // No selection animation: the form restores the saved choice on appear, and an
        // animated highlight would visibly slide from the default chip every time.
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CloudProviderChip: View {
    let option: CloudProviderOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        ProviderChip(title: option.title, assetName: option.assetName, fallbackSymbol: option.fallbackSymbol, selected: selected, action: action)
    }
}

struct LocalRuntimeChip: View {
    let runtime: LocalRuntime
    let selected: Bool
    let running: Bool
    let action: () -> Void

    var body: some View {
        ProviderChip(
            title: runtime.title,
            assetName: runtime.assetName,
            fallbackSymbol: runtime.fallbackSymbol,
            selected: selected,
            templateIcon: runtime.templateIcon,
            running: runtime == .other ? nil : running,
            action: action
        )
        .help(localized(running ? "In esecuzione" : "Non in esecuzione"))
    }
}

/// Optional model download through the user's Ollama; nothing is fetched until they pick one.
struct OllamaModelDownloadControl: View {
    @EnvironmentObject private var model: AppModel
    let installed: Set<String>
    let onDownload: (String) -> Void

    var body: some View {
        if let download = model.modelDownload, !download.failed {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = download.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(download.progress.map { "\(download.model) · \(Int($0 * 100))%" } ?? "\(download.model) · \(download.status)")
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .lineLimit(1)
                }
                Button(localized("Annulla")) { model.cancelModelDownload() }
                    .buttonStyle(MPSecondaryButtonStyle(compact: true))
            }
            .tint(MeetingPilotDesign.accent)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Menu {
                    ForEach(RecommendedLocalModel.ollama) { option in
                        Button {
                            onDownload(option.id)
                        } label: {
                            Text("\(option.title) — \(localized(option.detail))")
                        }
                        .disabled(installed.contains(option.id))
                    }
                } label: {
                    Label(localized("Scarica un modello consigliato"), systemImage: "arrow.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if let download = model.modelDownload, download.failed {
                    Text(String(format: localized("Download di %@ non riuscito: %@"), download.model, download.status))
                        .font(MPFont.caption())
                        .foregroundStyle(MeetingPilotDesign.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

func apiKeyPageURL(for kind: String) -> URL? {
    switch kind {
    case "gpt": return URL(string: "https://platform.openai.com/api-keys")
    case "gemini": return URL(string: "https://aistudio.google.com/apikey")
    case "claude": return URL(string: "https://console.anthropic.com/settings/keys")
    default: return nil
    }
}

/// What goes into the summary, independent of which engine writes it.
struct SummaryContentSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var summaryPrompt = ""
    @State private var businessGlossary = ""
    @State private var customTemplates: [CustomSummaryTemplate] = []
    @State private var saveTask: DispatchWorkItem?
    @State private var expanded: String?

    private var glossaryTermCount: Int {
        businessGlossary
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    var body: some View {
        SettingsFormPanel {
            SummaryEditorToggle(
                title: "Modello di sintesi",
                value: SummaryTemplateCatalog.name(for: model.summaryTemplate, custom: customTemplates),
                icon: "doc.text",
                isExpanded: expanded == "template"
            ) { toggle("template") }
            if expanded == "template" {
                SummaryTemplateEditor(
                    defaultTemplate: Binding(get: { model.summaryTemplate }, set: { model.saveSummaryTemplate($0) }),
                    customTemplates: $customTemplates
                )
                .padding(.bottom, 12)
            }
            Divider()
            SummaryEditorToggle(
                title: "Prompt personalizzato",
                value: summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Predefinito" : "Personalizzato",
                icon: "text.quote",
                isExpanded: expanded == "prompt"
            ) { toggle("prompt") }
            if expanded == "prompt" {
                MultilineEditableField(
                    label: "Istruzioni aggiuntive per la sintesi",
                    text: $summaryPrompt,
                    placeholder: "Esempio: evidenzia sempre decisioni, responsabili, scadenze e rischi. Non inventare informazioni."
                )
                .padding(.bottom, 12)
            }
            Divider()
            SummaryEditorToggle(
                title: "Vocabolario aziendale",
                value: glossaryTermCount == 0 ? "Vuoto" : String(format: localized("%lld termini"), glossaryTermCount),
                icon: "character.book.closed",
                isExpanded: expanded == "glossary"
            ) { toggle("glossary") }
            if expanded == "glossary" {
                GlossaryTableEditor(text: $businessGlossary)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            summaryPrompt = model.summaryPrompt
            businessGlossary = model.businessGlossary
            customTemplates = model.customSummaryTemplates
            if let requestedEditor = model.summaryEditorToOpen {
                expanded = requestedEditor
                model.summaryEditorToOpen = nil
            }
        }
        .onChange(of: summaryPrompt) { _ in scheduleSave() }
        .onChange(of: businessGlossary) { _ in scheduleSave() }
        .onChange(of: customTemplates) { _ in scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            // Saving can shell out synchronously (watcher restart); run it after the view
            // update that removed this form, not inside it, to avoid a re-entrant layout.
            let prompt = summaryPrompt
            let glossary = businessGlossary
            let templates = customTemplates
            let appModel = model
            DispatchQueue.main.async {
                appModel.saveSummaryPrompt(prompt)
                appModel.saveBusinessGlossary(glossary)
                appModel.saveCustomSummaryTemplates(templates)
            }
        }
    }

    private func toggle(_ editor: String) {
        withAnimation(.mpSmooth) {
            expanded = expanded == editor ? nil : editor
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem {
            model.saveSummaryPrompt(summaryPrompt)
            model.saveBusinessGlossary(businessGlossary)
            model.saveCustomSummaryTemplates(customTemplates)
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
    }
}

/// Default template for new meetings plus the user's own templates. Each meeting can
/// still override the default from the live sidebar.
struct SummaryTemplateEditor: View {
    @Binding var defaultTemplate: String
    @Binding var customTemplates: [CustomSummaryTemplate]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsFormRow(
                label: "Predefinito",
                hint: "Automatico sceglie in base al titolo della riunione. Puoi cambiarlo per ogni riunione dalla barra laterale dal vivo."
            ) {
                Picker("", selection: $defaultTemplate) {
                    ForEach(SummaryTemplateCatalog.options(custom: customTemplates)) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            ForEach($customTemplates) { $template in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(localized("Nome del modello"), text: $template.name)
                            .textFieldStyle(DarkTextFieldStyle())
                        Button {
                            customTemplates.removeAll { $0.id == template.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(MPIconButtonStyle(size: 28))
                        .help(localized("Elimina modello"))
                    }
                    TextField(
                        localized("Parole chiave nel titolo, separate da virgole"),
                        text: Binding(
                            get: { template.keywords.joined(separator: ", ") },
                            set: { template.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        )
                    )
                    .textFieldStyle(DarkTextFieldStyle())
                    MultilineEditableField(
                        label: "Istruzioni",
                        text: $template.instructions,
                        placeholder: "Esempio: elenca le decisioni per reparto e chiudi con i prossimi passi."
                    )
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.fieldColor.opacity(0.5)))
            }
            Button {
                customTemplates.append(
                    CustomSummaryTemplate(
                        id: "custom_" + UUID().uuidString.prefix(8).lowercased(),
                        name: localized("Nuovo modello"),
                        instructions: "",
                        keywords: []
                    )
                )
            } label: {
                Label(localized("Aggiungi modello"), systemImage: "plus")
            }
            .buttonStyle(MPSecondaryButtonStyle())
        }
    }
}

struct SummaryEditorToggle: View {
    let title: String
    let value: String
    let icon: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(MPFont.body(.medium))
                    .foregroundStyle(MeetingPilotDesign.accent)
                    .frame(width: 20)
                Text(localized(title))
                    .font(MPFont.body(.medium))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                Spacer()
                Text(localized(value))
                    .font(MPFont.callout())
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                Image(systemName: "chevron.right")
                    .font(MPFont.caption(.semibold))
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProviderView: View {
    var body: some View {
        ContentPane(title: "Sintesi (AI)") {
            SummaryConfigurationForm()
            MPSectionTitle("Contenuto della sintesi")
                .padding(.top, 8)
            SummaryContentSection()
        }
    }
}

func inferredRemoteProviderKind(baseURL: String, model: String) -> String {
    let base = baseURL.lowercased()
    let normalizedModel = model.lowercased()
    if base.contains("generativelanguage.googleapis.com") || normalizedModel.contains("gemini") {
        return "gemini"
    }
    if base.contains("anthropic") || normalizedModel.contains("claude") {
        return "claude"
    }
    if base.contains("openai") || normalizedModel.contains("gpt") || normalizedModel.contains("o1") || normalizedModel.contains("o3") || normalizedModel.contains("o4") {
        return "gpt"
    }
    return "other"
}

func currentAppleIntelligenceAvailability() -> (available: Bool, reason: String) {
    guard #available(macOS 26.0, *) else {
        return (false, "Richiede macOS 26 o successivo")
    }
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        return (true, "Disponibile su questo Mac")
    case .unavailable(.appleIntelligenceNotEnabled):
        return (false, "Apple Intelligence non è attivata nelle Impostazioni di Sistema")
    case .unavailable(.modelNotReady):
        return (false, "Il modello Apple Intelligence non è ancora pronto")
    case .unavailable(.deviceNotEligible):
        return (false, "Questo Mac non supporta Apple Intelligence")
    case .unavailable:
        return (false, "Apple Intelligence non è attualmente disponibile")
    }
}

func remoteProviderDisplayName(baseURL: String, model: String) -> String {
    switch inferredRemoteProviderKind(baseURL: baseURL, model: model) {
    case "claude":
        return "Claude-compatible"
    case "gemini":
        return "Gemini-compatible"
    case "other":
        return "Custom endpoint"
    default:
        return "GPT-compatible"
    }
}

private func remoteEndpointPlaceholder(for kind: String) -> String {
    switch kind {
    case "claude":
        return remoteOfficialBaseURL(for: kind)
    case "gemini":
        return remoteOfficialBaseURL(for: kind)
    case "other":
        return "https://your-endpoint/v1"
    default:
        return remoteOfficialBaseURL(for: kind)
    }
}

private func remoteModelPlaceholder(for kind: String) -> String {
    switch kind {
    case "claude":
        return remoteDefaultModel(for: kind)
    case "gemini":
        return remoteDefaultModel(for: kind)
    case "other":
        return "custom-model"
    default:
        return remoteDefaultModel(for: kind)
    }
}

private func remoteOfficialBaseURL(for kind: String) -> String {
    switch kind {
    case "claude":
        return "https://api.anthropic.com/v1/"
    case "gemini":
        return "https://generativelanguage.googleapis.com/v1beta/openai/"
    case "other":
        return ""
    default:
        return "https://api.openai.com/v1"
    }
}

private func remoteDefaultModel(for kind: String) -> String {
    switch kind {
    case "claude":
        return "claude-sonnet-4-20250514"
    case "gemini":
        return "gemini-2.5-flash"
    case "other":
        return "custom-model"
    default:
        return "gpt-4o-mini"
    }
}

private func isOfficialRemoteBaseURL(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == remoteOfficialBaseURL(for: "gpt")
        || trimmed == remoteOfficialBaseURL(for: "claude")
        || trimmed == remoteOfficialBaseURL(for: "gemini")
}

func parsePublicationTargets(_ env: [String: String]) -> Set<String> {
    let raw = env["PUBLISH_TARGETS"] ?? env["PUBLISH_TARGET"] ?? ""
    let parsed = raw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty && $0 != "auto" }
    if !parsed.isEmpty {
        return Set(parsed)
    }
    // Mirrors the pipeline fallback (pipeline.py `_publish_artifacts`). The default
    // .env ships the Notion and Obsidian keys empty, so a key alone is not a connection.
    if envBool(env, "PUBLISH_TARGETS_EXPLICIT", false) {
        return []
    }
    let filled = { (key: String) in !(env[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if filled("NOTION_TOKEN"), filled("NOTION_DATABASE_ID") || filled("NOTION_OCCURRENCES_DATABASE_ID") {
        return ["notion"]
    }
    if filled("OBSIDIAN_VAULT_PATH") {
        return ["obsidian"]
    }
    return ["journal"]
}

func normalizePublicationTargets(_ targets: Set<String>) -> [String] {
    let order = ["journal", "obsidian", "notion", "apple_notes"]
    return order.filter { targets.contains($0) }
}

struct LocalModelPicker: View {
    let options: [String]
    @Binding var selectedModel: String
    let onRefresh: () -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if options.isEmpty {
                    TextField(localized("Nome del modello"), text: $selectedModel)
                        .textFieldStyle(DarkTextFieldStyle())
                } else {
                    Menu {
                        ForEach(options, id: \.self) { option in
                            Button(option) { selectedModel = option }
                        }
                    } label: {
                        HStack {
                            Text(selectedModel.isEmpty ? localized("Scegli modello") : selectedModel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(MPFont.caption(.semibold))
                                .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MeetingPilotDesign.fieldColor))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MeetingPilotDesign.lineStrongColor, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MPIconButtonStyle(size: 30))
                .help(localized("Aggiorna lista modelli"))

                Button(action: onChooseFolder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(MPIconButtonStyle(size: 30))
                .help(localized("Scegli cartella modelli"))
            }

            Text(options.isEmpty
                 ? localized("Nessun modello trovato nella cartella: scrivi il nome a mano.")
                 : String(format: localized("%lld modelli trovati."), options.count))
                .font(MPFont.caption())
                .foregroundStyle(MeetingPilotDesign.textFaintColor)
        }
    }
}


struct PermissionRowView: View {
    let row: PermissionRow
    let onEnable: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(row.granted ? MeetingPilotDesign.success : MeetingPilotDesign.warning)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized(row.title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.primaryText(for: colorScheme))
                Text(localized(row.reason))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MeetingPilotDesign.secondaryText(for: colorScheme))
            }
            Spacer()
            if row.granted {
                Text("OK")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MeetingPilotDesign.success)
            } else {
                Button("Abilita", action: onEnable)
                    .buttonStyle(CompactButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MeetingPilotDesign.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1))
    }
}

struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MPSecondaryButtonStyle(compact: true).makeBody(configuration: configuration)
    }
}
