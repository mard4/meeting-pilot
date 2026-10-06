import CryptoKit
import Foundation

/// The Meeting Pilot model (summary mode "builtin"): one of two small models the app
/// downloads on request, served by the llama.cpp server bundled in the app. The
/// pipeline starts that server only while it summarizes or answers in chat; see
/// summarization/builtin_model.py, which expects the same file names.
enum BuiltinModelVariant: String, CaseIterable, Identifiable {
    case light, quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Leggero"
        case .quality: return "Qualità"
        }
    }

    var detail: String {
        switch self {
        case .light: return "Piccolo e veloce. Ricontrolla date e numeri nelle note."
        case .quality: return "Note più precise su decisioni, date e responsabili."
        }
    }

    var sizeLabel: String {
        switch self {
        case .light: return "572 MB"
        case .quality: return "2,5 GB"
        }
    }

    /// Credited in Settings; both are Apache-2.0.
    var sourceName: String {
        switch self {
        case .light: return "Bonsai-4B (PrismML)"
        case .quality: return "Qwen3-4B (Qwen)"
        }
    }

    var fileName: String {
        switch self {
        case .light: return "Bonsai-4B-Q1_0.gguf"
        case .quality: return "Qwen3-4B-Q4_K_M.gguf"
        }
    }

    /// Pinned to a revision and checked against its SHA-256, so a changed upload can't
    /// replace the model that was evaluated.
    private var repository: String {
        switch self {
        case .light: return "prism-ml/Bonsai-4B-gguf"
        case .quality: return "Qwen/Qwen3-4B-GGUF"
        }
    }

    private var revision: String {
        switch self {
        case .light: return "78f2c2bacd0904ffaba24b4873ed975e5818354a"
        case .quality: return "bc640142c66e1fdd12af0bd68f40445458f3869b"
        }
    }

    var sha256: String {
        switch self {
        case .light: return "4524b3f997f0f06444e568d1f26e2efd69effa3218c7ad3047432fb171e42168"
        case .quality: return "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"
        }
    }

    var byteCount: Int64 {
        switch self {
        case .light: return 572_270_624
        case .quality: return 2_497_280_256
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    var fileURL: URL { builtinModelsDirectory().appendingPathComponent(fileName) }

    /// The size check is enough here: the file is only moved into place after its hash matched.
    var isInstalled: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        return size == byteCount
    }
}

func builtinModelsDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Meeting Pilot/Models", isDirectory: true)
}

func bundledLlamaServerPath() -> String {
    Bundle.main.resourceURL?.appendingPathComponent("LlamaCpp/bin/llama-server").path ?? "llama-server"
}

struct BuiltinModelDownload: Equatable {
    var variant: BuiltinModelVariant
    var progress: Double
    var verifying = false
    var failure: String?
}

enum BuiltinModelDownloadError: LocalizedError {
    case notEnoughSpace(String)
    case badResponse(Int)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let size):
            return String(format: localized("Spazio su disco insufficiente: servono %@ liberi."), size)
        case .badResponse(let status):
            return String(format: localized("Il server ha risposto con l'errore %d."), status)
        case .checksumMismatch:
            return localized("Il file scaricato è danneggiato. Riprova.")
        }
    }
}

extension AppModel {
    func refreshBuiltinModels() {
        builtinModelsInstalled = Set(BuiltinModelVariant.allCases.filter(\.isInstalled).map(\.rawValue))
    }

    /// `selectWhenReady` switches summaries to this model once it is verified.
    func downloadBuiltinModel(_ variant: BuiltinModelVariant, selectWhenReady: Bool) {
        guard builtinModelDownload == nil || builtinModelDownload?.failure != nil else { return }
        let directory = builtinModelsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? .max
            // The download and its verified copy briefly coexist on disk.
            if free < variant.byteCount + 500_000_000 {
                throw BuiltinModelDownloadError.notEnoughSpace(variant.sizeLabel)
            }
        } catch {
            builtinModelDownload = BuiltinModelDownload(variant: variant, progress: 0, failure: error.localizedDescription)
            return
        }
        builtinModelDownload = BuiltinModelDownload(variant: variant, progress: 0)
        statusMessage = String(format: localized("Download del modello %@…"), localized(variant.title))

        let partial = directory.appendingPathComponent(variant.fileName + ".partial")
        let task = URLSession.shared.downloadTask(with: variant.downloadURL) { [weak self] location, response, error in
            // `location` is deleted when this handler returns, so it is moved right away.
            var result: Result<Void, Error>
            if let error {
                result = .failure(error)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failure(BuiltinModelDownloadError.badResponse(status))
            } else if let location {
                result = Result {
                    try? FileManager.default.removeItem(at: partial)
                    try FileManager.default.moveItem(at: location, to: partial)
                }
            } else {
                result = .failure(URLError(.unknown))
            }
            DispatchQueue.main.async {
                self?.builtinModelDownload?.verifying = true
            }
            DispatchQueue.global(qos: .utility).async {
                if case .success = result {
                    result = Result {
                        guard try sha256Hex(of: partial) == variant.sha256 else {
                            throw BuiltinModelDownloadError.checksumMismatch
                        }
                        try? FileManager.default.removeItem(at: variant.fileURL)
                        try FileManager.default.moveItem(at: partial, to: variant.fileURL)
                    }
                }
                if case .failure = result {
                    try? FileManager.default.removeItem(at: partial)
                }
                DispatchQueue.main.async {
                    self?.finishBuiltinModelDownload(variant, result: result, selectWhenReady: selectWhenReady)
                }
            }
        }
        builtinModelDownloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                guard let self, var download = self.builtinModelDownload, download.variant == variant, !download.verifying else { return }
                // Progress can arrive out of order; never move the bar back.
                download.progress = max(download.progress, min(fraction, 1))
                self.builtinModelDownload = download
            }
        }
        builtinModelDownloadTask = task
        task.resume()
    }

    func cancelBuiltinModelDownload() {
        builtinModelDownloadTask?.cancel()
    }

    func deleteBuiltinModel(_ variant: BuiltinModelVariant) {
        try? FileManager.default.removeItem(at: variant.fileURL)
        refreshBuiltinModels()
        statusMessage = String(format: localized("Modello %@ eliminato"), localized(variant.title))
    }

    private func finishBuiltinModelDownload(_ variant: BuiltinModelVariant, result: Result<Void, Error>, selectWhenReady: Bool) {
        builtinModelDownloadTask = nil
        builtinModelDownloadObservation = nil
        refreshBuiltinModels()
        switch result {
        case .success:
            builtinModelDownload = nil
            statusMessage = String(format: localized("Modello %@ pronto"), localized(variant.title))
            if selectWhenReady {
                selectBuiltinModel(variant)
            }
        case .failure(let error as URLError) where error.code == .cancelled:
            builtinModelDownload = nil
            statusMessage = localized("Download annullato")
        case .failure(let error):
            AppLog.append("Download del modello \(variant.fileName) non riuscito: \(error.localizedDescription)")
            builtinModelDownload = BuiltinModelDownload(variant: variant, progress: 0, failure: error.localizedDescription)
            statusMessage = String(format: localized("Download non riuscito: %@"), error.localizedDescription)
        }
    }

    /// Makes the Meeting Pilot model the summary engine, using this variant.
    func selectBuiltinModel(_ variant: BuiltinModelVariant) {
        saveProviderSettings(
            mode: "builtin",
            baseURL: "",
            localModelsDir: localModelsDir,
            model: variant.rawValue,
            apiKey: "",
            jsonMode: providerJSONMode
        )
    }
}

private func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
