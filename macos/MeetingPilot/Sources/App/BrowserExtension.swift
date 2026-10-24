import AppKit
import Security
import SwiftUI

/// Connects the browser extension (`browser/extension`) to the app. Setting up writes the
/// native messaging manifest that lets Chromium browsers start `MeetingPilotBrowserHost`
/// for the extension and the token the host uses to ask the app to import. The extension
/// itself comes from the Chrome Web Store.
enum BrowserExtensionSetup {
    /// The extension as the Chrome Web Store publishes it (published 2026-10-24).
    static let storeExtensionID = "ipnadmfmihedhmlppdjoldfnjpmjghen"
    /// Loaded unpacked from the repo while developing, fixed by the public `key` in its manifest.json.
    static let unpackedExtensionID = "blgkijnmbiefebagnjlieceagflahnin"
    /// Both may connect: the store's and a development copy.
    static let extensionIDs = [storeExtensionID, unpackedExtensionID]
    static let storeURL = URL(string: "https://chromewebstore.google.com/detail/\(storeExtensionID)")!
    static let hostName = "com.meetingpilot.browser"

    /// Each browser's folder under ~/Library/Application Support; NativeMessagingHosts goes in it.
    static let browsers: [(name: String, folder: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Edge", "Microsoft Edge"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi"),
        ("Chromium", "Chromium"),
    ]

    private static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static var hostExecutable: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MeetingPilotBrowserHost")
    }

    /// Where earlier versions copied the extension for loading unpacked; removed at launch.
    static func oldExtensionCopy(configRoot: URL) -> URL {
        configRoot.appendingPathComponent("Browser Extension", isDirectory: true)
    }

    static func tokenURL(configRoot: URL) -> URL {
        configRoot.appendingPathComponent("browser-host-token")
    }

    /// The browsers this Mac has, by their Application Support folder.
    static func installedBrowsers(in support: URL = applicationSupport) -> [(name: String, manifest: URL)] {
        browsers.compactMap { browser in
            let folder = support.appendingPathComponent(browser.folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return (browser.name, folder.appendingPathComponent("NativeMessagingHosts/\(hostName).json"))
        }
    }

    static func manifest(host: URL) -> [String: Any] {
        [
            "name": hostName,
            "description": "Meeting Pilot",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
    }

    /// Set up when the token exists and some browser's manifest points at this app's host.
    static func isConfigured(configRoot: URL, support: URL = applicationSupport) -> Bool {
        guard FileManager.default.fileExists(atPath: tokenURL(configRoot: configRoot).path), let host = hostExecutable else { return false }
        return installedBrowsers(in: support).contains { browser in
            guard let data = try? Data(contentsOf: browser.manifest),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return payload["path"] as? String == host.path
        }
    }

    /// Returns the names of the browsers set up.
    @discardableResult
    static func configure(configRoot: URL, host: URL? = hostExecutable, support: URL = applicationSupport) throws -> [String] {
        guard let host else { throw CocoaError(.fileNoSuchFile) }
        let fileManager = FileManager.default
        let token = tokenURL(configRoot: configRoot)
        if !fileManager.fileExists(atPath: token.path) {
            try fileManager.createDirectory(at: configRoot, withIntermediateDirectories: true)
            try newToken().write(to: token, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        }
        let data = try JSONSerialization.data(withJSONObject: manifest(host: host), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let browsers = installedBrowsers(in: support)
        for browser in browsers {
            try fileManager.createDirectory(at: browser.manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: browser.manifest, options: .atomic)
        }
        return browsers.map(\.name)
    }

    /// Removes the manifests and the token: the extension then says "Not set up".
    static func remove(configRoot: URL, support: URL = applicationSupport) {
        for browser in installedBrowsers(in: support) {
            try? FileManager.default.removeItem(at: browser.manifest)
        }
        try? FileManager.default.removeItem(at: tokenURL(configRoot: configRoot))
    }

    /// At launch, once set up: a moved or updated app gets its manifests refreshed, and a
    /// browser installed since then is added.
    static func refreshIfConfigured(configRoot: URL) {
        try? FileManager.default.removeItem(at: oldExtensionCopy(configRoot: configRoot))
        guard FileManager.default.fileExists(atPath: tokenURL(configRoot: configRoot).path) else { return }
        do {
            try configure(configRoot: configRoot)
        } catch {
            AppLog.append("Aggiornamento estensione del browser non riuscito: \(error.localizedDescription)")
        }
    }

    enum ImportAction: Equatable {
        case notAnImport
        /// Sent by the native host, which knows the token.
        case importNow(id: String, url: URL)
        /// Any other `meetingpilot://import` link: the sheet shows it and waits.
        case askFirst(String)
    }

    static func importAction(for url: URL, token expected: String?) -> ImportAction {
        guard url.scheme == "meetingpilot", url.host == "import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .notAnImport }
        let link = components.queryItems?.first { $0.name == "url" }?.value ?? ""
        let token = components.queryItems?.first { $0.name == "token" }?.value
        if let expected, token == expected, let parsed = WebVideoLink.youtube(link) {
            return .importNow(id: parsed.id, url: parsed.url)
        }
        return .askFirst(link)
    }

    static func token(configRoot: URL) -> String? {
        let value = try? String(contentsOf: tokenURL(configRoot: configRoot), encoding: .utf8)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Settings → "Browser".
struct BrowserExtensionRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var configured = false

    var body: some View {
        SettingsLine(
            title: "Browser",
            detail: configured
                ? "Collegato: aggiungi l'estensione dal Chrome Web Store (anche per Edge, Brave e Arc)."
                : "I video di YouTube da Chrome, Edge, Brave o Arc, con un clic.",
            icon: SettingsIcon(symbol: "globe")
        ) {
            HStack(spacing: 6) {
                if configured {
                    Button(localized("Chrome Web Store")) {
                        NSWorkspace.shared.open(BrowserExtensionSetup.storeURL)
                    }
                    .buttonStyle(CompactButtonStyle())
                    .help(localized("Installa l'estensione dal Chrome Web Store"))
                    Button(localized("Scollega")) {
                        BrowserExtensionSetup.remove(configRoot: model.configRoot)
                        configured = false
                        model.statusMessage = localized("Browser scollegati da Meeting Pilot")
                    }
                    .buttonStyle(CompactButtonStyle())
                } else {
                    Button(localized("Configura")) {
                        configure()
                    }
                    .buttonStyle(CompactButtonStyle())
                }
            }
            .fixedSize()
        }
        .onAppear { configured = BrowserExtensionSetup.isConfigured(configRoot: model.configRoot) }
    }

    private func configure() {
        do {
            let browsers = try BrowserExtensionSetup.configure(configRoot: model.configRoot)
            configured = !browsers.isEmpty
            model.statusMessage = browsers.isEmpty
                ? localized("Nessun browser Chromium trovato: installane uno e riprova.")
                : localized("Browser configurati") + ": " + browsers.joined(separator: ", ")
            if !browsers.isEmpty { NSWorkspace.shared.open(BrowserExtensionSetup.storeURL) }
        } catch {
            AppLog.append("Configurazione dei browser non riuscita: \(error.localizedDescription)")
            model.statusMessage = localized("Configurazione dei browser non riuscita") + ": " + error.localizedDescription
        }
    }
}
