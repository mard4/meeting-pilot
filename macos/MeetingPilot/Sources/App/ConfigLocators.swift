import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import FoundationModels
import Speech
import Security
import ServiceManagement
import SwiftUI
import UserNotifications


enum ProjectLocator {
    static func findProjectRoot() -> URL {
        if let value = ProcessInfo.processInfo.environment["MEETING_PILOT_PROJECT_ROOT"], !value.isEmpty {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        }
        if let resource = Bundle.main.url(forResource: "default-project-root", withExtension: "txt"),
           let text = try? String(contentsOf: resource, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return URL(fileURLWithPath: text)
        }
#if DEBUG
        // Running from a checkout (swift run, Xcode): this file sits at
        // <repo>/macos/MeetingPilot/Sources/App/, so the repo is five levels up.
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: checkout.appendingPathComponent("pyproject.toml").path) {
            return checkout
        }
#endif
        return ConfigLocator.configDirectory()
    }
}

enum ConfigLocator {
    static func configDirectory() -> URL {
#if DEBUG
        // Lets the snapshot harness run without touching the real user configuration.
        if let override = ProcessInfo.processInfo.environment["MEETING_PILOT_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
#endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
        return base.appendingPathComponent("Meeting Pilot", isDirectory: true)
    }

    static func ensureConfigFile(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            EnvFile.restrictPermissions(of: url)
            EnvFile.migrateSecretsToKeychain(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try defaultEnvText().write(to: url, atomically: true, encoding: .utf8)
            EnvFile.restrictPermissions(of: url)
        } catch {
            EnvFile.report("Non riesco a creare la configurazione", url: url, error: error)
        }
    }

    private static func defaultEnvText() -> String {
        let appleAvailable = currentAppleIntelligenceAvailability().available
        let defaultSummaryMode = appleAvailable ? "apple" : "local"
        let appleDefaultState = appleAvailable ? "true" : "pending"
        return """
        NOTION_TOKEN=
        NOTION_PARENT_PAGE_ID=
        NOTION_APP_PAGE_ID=
        NOTION_SERIES_DATABASE_ID=
        NOTION_OCCURRENCES_DATABASE_ID=
        NOTION_DATABASE_ID=
        NOTION_PAGE_NAME=Meeting Pilot
        NOTION_TITLE_PROPERTY=Name
        NOTION_PROJECT_PROPERTY=Project
        INCLUDE_OVERVIEW=true
        INCLUDE_SUMMARY=true
        INCLUDE_TOPICS=true
        INCLUDE_DECISIONS=true
        INCLUDE_ACTION_ITEMS=true
        INCLUDE_OPEN_QUESTIONS=true
        INCLUDE_RISKS=true
        INCLUDE_SPEAKERS=true
        INCLUDE_TRANSCRIPT=true

        SUMMARY_ENABLED=true
        SUMMARY_PROVIDER_MODE=\(defaultSummaryMode)
        APPLE_INTELLIGENCE_DEFAULT_APPLIED=\(appleDefaultState)
        APPLE_INTELLIGENCE_SUMMARIZER_CMD=
        APPLE_INTELLIGENCE_TIMEOUT_SECONDS=1800
        LOCAL_MODELS_DIR=~/.omlx/models
        SUMMARY_BASE_URL=http://127.0.0.1:8000/v1
        SUMMARY_MODEL=local-model
        LOCAL_SUMMARY_MODEL=
        REMOTE_SUMMARY_MODEL=
        SUMMARY_API_KEY=
        REMOTE_SUMMARY_API_KEY=
        LOCAL_SUMMARY_API_KEY=
        SUMMARY_RESPONSE_FORMAT_JSON=false
        SUMMARY_PROMPT=

        MEETINGS_ROOT=~/TeamsMeetings
        RECORDER_MODE=macos_prompt
        INBOX_AUDIO_DIR=~/TeamsMeetings/inbox_audio
        RECORDING_PROMPT_ENABLED=true
        RECORDING_PROMPT_DELAY_SECONDS=3
        RECORDER_OPEN_TARGET=
        MOVE_SOURCE_AUDIO=false
        KEEP_AUDIO=false

        CALENDAR_METADATA_ENABLED=true
        MACOS_CALENDAR_METADATA_ENABLED=false
        CALENDAR_LOOKUP_WINDOW_MINUTES=90
        TEAMS_RUNTIME_METADATA_FILE=~/TeamsMeetings/teams-runtime.json
        TEAMS_OCR_ENABLED=false

        TRANSCRIPTION_PROVIDER=fluid
        TRANSCRIPTION_LOCALE=it-IT
        APPLE_TRANSCRIBER_TIMEOUT_SECONDS=900
        APPLE_TRANSCRIBER_CMD=
        FLUID_AUDIO_CMD=

        WATCH_POLL_SECONDS=5
        FILE_STABLE_SECONDS=10
        AUTO_START_WATCHER=true
        LAUNCH_AT_LOGIN=true
        """
    }
}

struct NativeNotionWorkspace {
    let appPageID: String
    let occurrencesDatabaseID: String
    let reusedDestination: Bool
}

enum NativeNotionProvisioner {
    static func provision(
        token: String,
        parentPageID: String,
        existingAppPageID: String,
        existingOccurrencesDatabaseID: String = "",
        destinationName: String
    ) throws -> NativeNotionWorkspace {
        let name = destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NotionProvisionError("Inserisci il nome della pagina Notion")
        }
        let parentID = cleanID(parentPageID.isEmpty ? existingAppPageID : parentPageID)
        guard !parentID.isEmpty else {
            throw NotionProvisionError("Seleziona una pagina parent in Notion")
        }

        let parentChildren = try listChildBlocks(pageID: parentID, token: token)
        if let directDatabase = childDatabases(in: parentChildren).first(where: {
            titlesMatch($0.title, name)
        }) {
            return NativeNotionWorkspace(
                appPageID: parentID,
                occurrencesDatabaseID: cleanID(directDatabase.id),
                reusedDestination: true
            )
        }

        for block in parentChildren where block["type"] as? String == "child_page" {
            guard let pageID = block["id"] as? String else { continue }
            let page = try request(
                path: "pages/\(cleanID(pageID))",
                token: token,
                method: "GET"
            )
            guard titlesMatch(pageTitle(page), name) else { continue }
            let databases = try listChildDatabases(pageID: pageID, token: token)
            guard !databases.isEmpty else {
                throw NotionProvisionError(
                    "La pagina Notion \"\(name)\" esiste già ma non contiene una tabella utilizzabile."
                )
            }
            let configured = databases.first {
                cleanID($0.id) == cleanID(existingOccurrencesDatabaseID)
            }
            let database = configured ?? databases[0]
            return NativeNotionWorkspace(
                appPageID: cleanID(pageID),
                occurrencesDatabaseID: cleanID(database.id),
                reusedDestination: true
            )
        }

        let page = try request(
            path: "pages",
            token: token,
            body: [
                "parent": ["type": "page_id", "page_id": parentID],
                "properties": [
                    "title": [["type": "text", "text": ["content": name]]]
                ]
            ]
        )
        let appPageID = try requiredID(in: page, label: "pagina \(name)")
        let database = try request(
            path: "databases",
            token: token,
            method: "POST",
            body: [
                "parent": ["type": "page_id", "page_id": cleanID(appPageID)],
                "title": [["type": "text", "text": ["content": name]]],
                "properties": ["Name": ["title": [:]]]
            ]
        )
        return NativeNotionWorkspace(
            appPageID: cleanID(appPageID),
            occurrencesDatabaseID: try requiredID(in: database, label: "tabella \(name)"),
            reusedDestination: false
        )
    }

    private struct ChildDatabase {
        let id: String
        let title: String
    }

    private static func listChildBlocks(pageID: String, token: String) throws -> [[String: Any]] {
        let response = try request(path: "blocks/\(cleanID(pageID))/children?page_size=100", token: token, method: "GET")
        return response["results"] as? [[String: Any]] ?? []
    }

    private static func childDatabases(in blocks: [[String: Any]]) -> [ChildDatabase] {
        blocks.compactMap { block in
            guard block["type"] as? String == "child_database",
                  let id = block["id"] as? String,
                  let child = block["child_database"] as? [String: Any] else { return nil }
            return ChildDatabase(id: id, title: child["title"] as? String ?? "")
        }
    }

    private static func listChildDatabases(pageID: String, token: String) throws -> [ChildDatabase] {
        childDatabases(in: try listChildBlocks(pageID: pageID, token: token))
    }

    private static func pageTitle(_ page: [String: Any]) -> String {
        guard let properties = page["properties"] as? [String: Any] else { return "" }
        for value in properties.values {
            guard let property = value as? [String: Any],
                  property["type"] as? String == "title",
                  let segments = property["title"] as? [[String: Any]] else { continue }
            return segments.map { segment in
                if let plainText = segment["plain_text"] as? String {
                    return plainText
                }
                return (segment["text"] as? [String: Any])?["content"] as? String ?? ""
            }.joined()
        }
        return ""
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }

    private static func request(path: String, token: String, method: String = "POST", body: [String: Any]? = nil) throws -> [String: Any] {
        guard let url = URL(string: "https://api.notion.com/v1/\(path)") else {
            throw NotionProvisionError("URL Notion non valido")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: URLResponse?
        var responseError: Error?
        URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            responseData = data
            response = urlResponse
            responseError = error
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 50) == .success else {
            throw NotionProvisionError("Connessione a Notion scaduta")
        }
        if let responseError { throw responseError }
        let data = responseData ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = json["message"] as? String ?? "richiesta rifiutata"
            throw NotionProvisionError(message)
        }
        return json
    }

    private static func requiredID(in object: [String: Any], label: String) throws -> String {
        guard let id = object["id"] as? String, !id.isEmpty else {
            throw NotionProvisionError("Notion non ha restituito l'ID per \(label)")
        }
        return id
    }

    private static func cleanID(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "-", with: "")
        let pattern = "[0-9a-fA-F]{32}"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(in: compact, range: NSRange(compact.startIndex..., in: compact)).last,
              let range = Range(match.range, in: compact) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(compact[range])
    }

    private struct NotionProvisionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Tokens and API keys live in the login Keychain, not in `.env`: the app reads them
/// back through `EnvFile.load` and hands them to the CLI as environment variables.
/// They share a single item, so macOS asks for access at most once instead of once per key.
enum SecretStore {
    private static let service = AppIdentity.bundleID
    /// Pre-release builds stored secrets under the old placeholder bundle ID.
    private static let legacyService = "it.local.MeetingPilot"
    private static let account = "secrets"
    private static let queue = DispatchQueue(label: "\(AppIdentity.bundleID).secrets")
    /// Read lazily, on the first secret anyone asks for.
    private static var cache: [String: String]?
    /// A denied read is not retried until the user saves a secret, so one "Deny" means
    /// one prompt, not one per refresh.
    private static var readFailed = false

    static func value(for key: String) -> String? {
        queue.sync { loadAll()?[key] }
    }

    /// Writes all values in one Keychain update. An empty value deletes the key.
    @discardableResult
    static func set(_ values: [String: String]) -> Bool {
        queue.sync {
            readFailed = false
            // Without the current contents a write would drop the secrets we couldn't read.
            guard var secrets = loadAll() else { return false }
            for (key, value) in values { secrets[key] = value.isEmpty ? nil : value }
            guard write(secrets) else { return false }
            cache = secrets
            return true
        }
    }

    private static func loadAll() -> [String: String]? {
        if let cache { return cache }
        if readFailed { return nil }
        switch read(account: account, service: service) {
        case .found(let data):
            if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                cache = decoded
            } else {
                AppLog.append("Segreti nel Portachiavi illeggibili, verranno sovrascritti al prossimo salvataggio")
                cache = [:]
            }
        case .missing:
            cache = migratePerKeyItems()
        case .failed(let status):
            AppLog.append("Lettura Keychain non riuscita: \(status)")
        }
        readFailed = cache == nil
        return cache
    }

    /// Older versions kept one item per key, under the current or the legacy service.
    /// They are folded into the shared item and deleted only once it is written.
    private static func migratePerKeyItems() -> [String: String]? {
        var secrets: [String: String] = [:]
        var found: [(key: String, service: String)] = []
        for key in EnvFile.secretKeys {
            for itemService in [service, legacyService] {
                switch read(account: key, service: itemService) {
                case .found(let data):
                    found.append((key, itemService))
                    if secrets[key] == nil, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                        secrets[key] = value
                    }
                case .missing:
                    continue
                case .failed(let status):
                    AppLog.append("Migrazione Keychain \(key) non riuscita: \(status)")
                    return nil
                }
            }
        }
        guard !found.isEmpty else { return [:] }
        guard write(secrets) else { return nil }
        for item in found {
            SecItemDelete(query(account: item.key, service: item.service) as CFDictionary)
        }
        AppLog.append("Segreti del Portachiavi riuniti in un solo elemento: \(secrets.keys.sorted().joined(separator: ", "))")
        return secrets
    }

    private enum ReadResult {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private static func read(account: String, service: String) -> ReadResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account, service: service).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return .found(data) }
        return status == errSecItemNotFound ? .missing : .failed(status)
    }

    private static func write(_ secrets: [String: String]) -> Bool {
        let base = query(account: account, service: service)
        let status: OSStatus
        if secrets.isEmpty {
            let deleted = SecItemDelete(base as CFDictionary)
            status = deleted == errSecItemNotFound ? errSecSuccess : deleted
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(secrets) else { return false }
            let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecItemNotFound {
                status = SecItemAdd(base.merging([
                    kSecValueData as String: data,
                    kSecAttrLabel as String: "Meeting Pilot",
                ]) { $1 } as CFDictionary, nil)
            } else {
                status = updated
            }
        }
        if status != errSecSuccess { AppLog.append("Salvataggio Keychain non riuscito: \(status)") }
        return status == errSecSuccess
    }

    private static func query(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum AppIdentity {
    /// Must match CFBundleIdentifier in Info.plist. Changing it after release resets
    /// every user's TCC permissions and orphans their Keychain items.
    static let bundleID = "io.github.mard4.MeetingPilot"
}

private struct KeychainWriteError: LocalizedError {
    let key: String
    var errorDescription: String? { key }
}

enum EnvFile {
    static let secretKeys: Set<String> = [
        "NOTION_TOKEN", "SUMMARY_API_KEY", "LOCAL_SUMMARY_API_KEY", "REMOTE_SUMMARY_API_KEY", "OMLX_API_KEY",
    ]

    /// The only secrets the Python CLI reads; the per-mode keys are app-side state.
    private static let cliSecretKeys = ["NOTION_TOKEN", "SUMMARY_API_KEY", "OMLX_API_KEY"]

    /// Secrets for a CLI child process. Passed through the environment, never on the
    /// command line, where `ps` would show them to every account on the Mac.
    static func secretEnvironment() -> [String: String] {
        cliSecretKeys.reduce(into: [:]) { environment, key in
            if let value = SecretStore.value(for: key), !value.isEmpty { environment[key] = value }
        }
    }

    static func restrictPermissions(of url: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLog.append("Permessi 0600 su \(url.path) non applicati: \(error.localizedDescription)")
        }
    }

    /// One-time move of plaintext secrets left by older versions (or pasted by hand)
    /// into the Keychain. A key is removed from the file only once the Keychain holds it.
    static func migrateSecretsToKeychain(at url: URL) {
        let plaintext = parse(readExisting(url) ?? "").filter { secretKeys.contains($0.key) && !$0.value.isEmpty }
        guard !plaintext.isEmpty else { return }
        guard SecretStore.set(plaintext) else { return }
        updateFile(at: url, values: plaintext.mapValues { _ in "" })
        AppLog.append("Segreti spostati da .env al Keychain: \(plaintext.keys.sorted().joined(separator: ", "))")
    }

    /// Set by AppModel to surface config failures in the UI; every failure is logged
    /// regardless.
    static var onFailure: ((String) -> Void)?

    static func report(_ message: String, url: URL, error: Error) {
        AppLog.append("\(message) (\(url.path)): \(error.localizedDescription)")
        let text = "\(message): \(error.localizedDescription)"
        DispatchQueue.main.async { onFailure?(text) }
    }

    /// Missing file reads as empty. An existing file that can't be read returns nil so
    /// callers never rewrite it from scratch and wipe the saved settings.
    private static func readExisting(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            report("Non riesco a leggere la configurazione", url: url, error: error)
            return nil
        }
    }

    @discardableResult
    private static func write(_ lines: [String], to url: URL) -> Bool {
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            restrictPermissions(of: url)
            return true
        } catch {
            report("Non riesco a salvare la configurazione", url: url, error: error)
            return false
        }
    }

    static func sanitize(at url: URL) -> Bool {
        guard let existing = readExisting(url) else { return false }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let valid = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return true }
            guard trimmed.contains("=") else { return false }
            let key = String(trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces)
            return !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        guard valid != lines else { return false }
        return write(valid, to: url)
    }

    static func load(from url: URL) -> [String: String] {
        var values = parse(readExisting(url) ?? "")
        for key in secretKeys {
            if let secret = SecretStore.value(for: key), !secret.isEmpty { values[key] = secret }
        }
        return values
    }

    private static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || !line.contains("=") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }

    @discardableResult
    static func update(at url: URL, values: [String: String]) -> Bool {
        let secrets = values.filter { secretKeys.contains($0.key) }
        var values = values.filter { !secretKeys.contains($0.key) }
        if !secrets.isEmpty {
            guard SecretStore.set(secrets) else {
                let keys = secrets.keys.sorted().joined(separator: ", ")
                report("Non riesco a salvare nel Portachiavi", url: url, error: KeychainWriteError(key: keys))
                return false
            }
            // Drop any plaintext copy; an empty line is harmless for the CLI loader.
            for key in secrets.keys { values[key] = "" }
        }
        return updateFile(at: url, values: values)
    }

    @discardableResult
    private static func updateFile(at url: URL, values: [String: String]) -> Bool {
        guard let existing = readExisting(url) else { return false }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return true }
            guard trimmed.contains("=") else { return false }
            let key = String(trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces)
            return !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        var remaining = values
        var seenKeys = Set<String>()
        var normalizedLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || !trimmed.contains("=") {
                normalizedLines.append(line)
                continue
            }
            let key = String(trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                normalizedLines.append(line)
                continue
            }
            guard seenKeys.insert(key).inserted else { continue }
            if let value = remaining.removeValue(forKey: key) {
                normalizedLines.append("\(key)=\(format(value))")
            } else {
                normalizedLines.append(line)
            }
        }

        if !remaining.isEmpty && !normalizedLines.isEmpty && normalizedLines.last != "" {
            normalizedLines.append("")
        }
        for key in remaining.keys.sorted() {
            normalizedLines.append("\(key)=\(format(remaining[key] ?? ""))")
        }

        return write(normalizedLines, to: url)
    }

    static func remove(at url: URL, keys: Set<String>) {
        guard !keys.isEmpty, let existing = readExisting(url), !existing.isEmpty else { return }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let retained = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.contains("=") else { return true }
            let key = String(trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces)
            return !keys.contains(key)
        }
        write(retained, to: url)
    }

    private static func format(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#\"'"))) == nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum AppLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    static let appURL = directory.appendingPathComponent("MeetingPilot.log")

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func append(_ message: String) {
        ensureDirectory()
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: appURL.path) {
            try? data.write(to: appURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: appURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// Runs executables directly: no shell, so no dotfiles are loaded, arguments need no
/// quoting, and nothing a profile prints can end up in the output we parse.
enum Shell {
    /// Stdout and stderr together, as the callers show or parse both.
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        standardInput: String? = nil,
        environment: [String: String] = [:]
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = Pipe()
        if standardInput != nil {
            process.standardInput = inputPipe
        }
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        if let standardInput {
            inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        }
        try? inputPipe.fileHandleForWriting.close()
        // Drain before waiting: a child that fills the pipe buffer would otherwise block forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Starts a long-running process that outlives this call, appending its output to log files.
    static func launch(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        standardOutput: URL,
        standardError: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try appendingHandle(for: standardOutput)
        process.standardError = try appendingHandle(for: standardError)
        try process.run()
        return process
    }

    /// Full command lines of running processes, for `pgrep -f`-style matching.
    static func processCommands() -> [String] {
        run("/bin/ps", ["-ax", "-o", "command="]).split(separator: "\n").map(String.init)
    }

    private static func appendingHandle(for url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
