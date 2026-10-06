import FluidAudio
import Foundation

/// Parakeet, FluidAudio's speech model (about 460 MB), is no longer bundled: from macOS 26
/// Apple's recognizer transcribes and FluidAudio only labels speakers. It is downloaded
/// here, into the folder `fluidaudiocli` reads, when someone chooses FluidAudio or on a
/// Mac where Apple's recognizer cannot place words in time.
extension AppModel {
    static let parakeetDownloadSize = "460 MB"

    var parakeetModelsInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// `selectWhenReady` switches transcription to FluidAudio once the model is in place.
    func downloadParakeet(selectWhenReady: Bool) {
        guard parakeetDownloadProgress == nil else { return }
        parakeetDownloadProgress = 0
        statusMessage = "Download del modello Parakeet…"
        Task {
            do {
                try await AsrModels.download(version: .v3) { progress in
                    Task { @MainActor [weak self] in
                        // Progress can arrive after completion; never move the bar back or past the end.
                        guard let self, let current = self.parakeetDownloadProgress else { return }
                        self.parakeetDownloadProgress = max(current, min(progress.fractionCompleted, 1))
                    }
                }
                await MainActor.run {
                    self.parakeetDownloadProgress = nil
                    self.fluidAudioInstalled = self.fluidTranscriptionAvailable(in: EnvFile.load(from: self.envURL))
                    self.statusMessage = "Modello Parakeet pronto"
                    if selectWhenReady && self.fluidAudioInstalled {
                        self.saveRecorderSettings(
                            mode: self.recorderMode,
                            folder: self.recorderFolder,
                            promptEnabled: self.recordingPromptEnabled,
                            promptDelaySeconds: self.recordingPromptDelaySeconds,
                            openTarget: self.recorderOpenTarget,
                            transcriptionProvider: "fluid"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.parakeetDownloadProgress = nil
                    AppLog.append("Download Parakeet non riuscito: \(error.localizedDescription)")
                    self.statusMessage = "Download di Parakeet non riuscito: \(error.localizedDescription)"
                }
            }
        }
    }
}
