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


func expandPath(_ value: String) -> URL {
    URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
}

func compactPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

func providerBaseURLIsLocal(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return true }
    return value.contains("127.0.0.1") || value.contains("localhost")
}

func defaultProviderBaseURL(for mode: String) -> String {
    mode == "api" ? "https://api.openai.com/v1" : "http://127.0.0.1:8000/v1"
}

func defaultLocalModelsDir() -> String {
    NSString(string: "~/.omlx/models").expandingTildeInPath
}

func normalizedLocalModelsDir(_ value: String?) -> String {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "~/Downloads" || trimmed == "\(NSHomeDirectory())/Downloads" {
        return defaultLocalModelsDir()
    }
    return expandPath(trimmed).path
}

func discoverLocalModelNames(in folder: String) -> [String] {
    let rootPath = NSString(string: folder.isEmpty ? defaultLocalModelsDir() : folder).expandingTildeInPath
    let root = URL(fileURLWithPath: rootPath)
    let fileManager = FileManager.default
    guard let topLevel = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var candidates: [(display: String, path: String)] = []

    for item in topLevel {
        guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        let children = (try? fileManager.contentsOfDirectory(
            at: item,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let modelChildren = children.filter { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && looksLikeModelFolder(child)
        }

        if modelChildren.isEmpty, looksLikeModelFolder(item) {
            candidates.append((item.lastPathComponent, item.path))
        } else {
            for child in modelChildren {
                candidates.append((child.lastPathComponent, child.path))
            }
        }
    }

    let grouped = Dictionary(grouping: candidates, by: \.display)
    return candidates.map { candidate in
        if let duplicates = grouped[candidate.display], duplicates.count > 1 {
            let parent = URL(fileURLWithPath: candidate.path).deletingLastPathComponent().lastPathComponent
            return "\(parent)/\(candidate.display)"
        }
        return candidate.display
    }
    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

func looksLikeModelFolder(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    if name.hasPrefix(".") { return false }
    let markerFiles = ["config.json", "tokenizer.json", "model.safetensors.index.json"]
    if markerFiles.contains(where: { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) {
        return true
    }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return files.contains { file in
        file.hasSuffix(".safetensors") || file.hasSuffix(".gguf") || file.hasSuffix(".mlx")
    }
}

func envBool(_ env: [String: String], _ key: String, _ defaultValue: Bool) -> Bool {
    guard let value = env[key] else { return defaultValue }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
}

func globalEnvBool(_ env: [String: String], _ key: String, legacyKey: String, _ defaultValue: Bool) -> Bool {
    if env[key] != nil {
        return envBool(env, key, defaultValue)
    }
    return envBool(env, legacyKey, defaultValue)
}

func defaultRecorderOpenTarget(for mode: String, folder: String) -> String {
    switch mode {
    case "transcribex":
        return "TranscribeX"
    case "custom":
        return folder
    default:
        return folder
    }
}

func defaultRecorderFolder(for mode: String) -> String {
    switch mode {
    case "transcribex":
        return "\(NSHomeDirectory())/Documents/transcribex/media"
    default:
        return "\(NSHomeDirectory())/TeamsMeetings/inbox_audio"
    }
}

/// Local servers that expose an OpenAI-compatible API. None of them ships with
/// Meeting Pilot: the user installs the one they want, if any.
enum LocalRuntime: String, CaseIterable, Identifiable {
    case omlx, ollama, lmstudio, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .omlx: return "oMLX"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .other: return "Personalizzato"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .omlx: return "http://127.0.0.1:8000/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .lmstudio: return "http://127.0.0.1:1234/v1"
        case .other: return ""
        }
    }

    var downloadURL: URL? {
        switch self {
        case .ollama: return URL(string: "https://ollama.com/download")
        case .lmstudio: return URL(string: "https://lmstudio.ai/download")
        case .omlx, .other: return nil
        }
    }

    var assetName: String? {
        switch self {
        case .omlx: return "omlx_logo.svg"
        case .ollama: return "ollama_white.png"
        case .lmstudio: return "lm-studio-icon-color.png"
        case .other: return nil
        }
    }

    /// Monochrome logos are tinted with the text color so they work in both themes.
    var templateIcon: Bool { self == .ollama }

    var fallbackSymbol: String {
        switch self {
        case .omlx: return "cpu"
        case .ollama: return "shippingbox"
        case .lmstudio: return "square.stack.3d.up"
        case .other: return "slider.horizontal.3"
        }
    }

    static func inferred(from baseURL: String) -> LocalRuntime {
        let value = baseURL.lowercased()
        if value.contains(":11434") { return .ollama }
        if value.contains(":1234") { return .lmstudio }
        if value.isEmpty || value.contains(":8000") { return .omlx }
        return .other
    }
}

struct RecommendedLocalModel: Identifiable {
    let id: String
    let title: String
    let detail: String

    /// Multilingual instruction models that fit common Mac memory sizes.
    static let ollama = [
        RecommendedLocalModel(id: "qwen3:8b", title: "Qwen3 8B", detail: "~5 GB · consigliato con 16 GB di RAM"),
        RecommendedLocalModel(id: "gemma3:4b", title: "Gemma 3 4B", detail: "~3 GB · più leggero, per Mac con 8 GB"),
    ]
}

struct LocalModelDownload: Equatable {
    var model: String
    var progress: Double?
    var status: String
    var failed = false
}

/// nil when nothing answers; an empty list when the server answers but refuses to
/// list models (typically a missing secret).
func fetchLocalModelIDs(baseURL: String, apiKey: String) async -> [String]? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty, let url = URL(string: trimmed + "/models") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 2)
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !key.isEmpty {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let status = (response as? HTTPURLResponse)?.statusCode
    else {
        return nil
    }
    if status == 401 || status == 403 { return [] }
    guard status == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    let entries = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
    let ids = entries.compactMap { ($0["id"] ?? $0["name"] ?? $0["model"]) as? String }
    return Array(Set(ids)).sorted()
}
