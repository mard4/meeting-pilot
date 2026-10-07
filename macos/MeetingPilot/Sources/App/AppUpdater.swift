// AppUpdater.swift
// Finds new releases on GitHub and installs them in place of the running app.

import AppKit
import Foundation
import UserNotifications

/// A release version such as "v0.2.1" or "0.3", compared number by number.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Pre-release or build suffixes ("0.3.0-beta", "0.3.0+5") don't count.
        let core = text.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// The newest published release, when it carries a DMG to install from.
struct AppRelease: Equatable {
    let version: AppVersion
    let notes: String
    let pageURL: URL
    let dmgURL: URL

    static func == (lhs: AppRelease, rhs: AppRelease) -> Bool {
        lhs.version == rhs.version && lhs.dmgURL == rhs.dmgURL
    }

    /// Reads GitHub's `releases/latest` answer; drafts, pre-releases and releases without a
    /// DMG are not offered.
    static func parse(_ data: Data) -> AppRelease? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              let version = AppVersion(payload.tag_name),
              let dmg = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
        else { return nil }
        return AppRelease(
            version: version,
            notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: payload.html_url,
            dmgURL: dmg.browser_download_url
        )
    }
}

/// Checks GitHub for a newer release at launch and every few hours, and on request
/// downloads its DMG, checks the app inside, swaps it in for the installed one and
/// relaunches. Builds are signed ad hoc, so the new app gets a new signature: on its first
/// launch `LaunchAtLogin.apply` sees the changed cdhash and registers the login item again.
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var automaticChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecks, forKey: Self.automaticChecksKey)
            if automaticChecks {
                scheduleAutomaticChecks()
            } else {
                timer?.invalidate()
            }
        }
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/mard4/meeting-pilot/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/mard4/meeting-pilot/releases/latest")!
    private static let automaticChecksKey = "MeetingPilotAutomaticUpdateChecks"
    private static let notifiedVersionKey = "MeetingPilotNotifiedUpdateVersion"
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    private var timer: Timer?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    init() {
        automaticChecks = UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    static var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") ?? AppVersion("0")!
    }

    var availableRelease: AppRelease? {
        switch state {
        case .available(let release), .downloading(let release): return release
        default: return nil
        }
    }

    /// The app can only replace itself when it runs from a folder the user can write to,
    /// not from the DMG or a translocated copy; otherwise the update opens the release page.
    static var canInstallInPlace: Bool {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        guard bundle.pathExtension == "app",
              !path.hasPrefix("/Volumes/"),
              !path.contains("/AppTranslocation/")
        else { return false }
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: path)
    }

    func startAutomaticChecks() {
        guard automaticChecks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.automaticChecks else { return }
            self.check(userInitiated: false)
        }
        scheduleAutomaticChecks()
    }

    private func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading: return
        default: break
        }
        if userInitiated { state = .checking }
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MeetingPilot/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(AppRelease.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                if case .downloading = self.state { return }
                guard error == nil, status == 200 else {
                    // A failed background check stays quiet; the next one will try again.
                    if userInitiated {
                        self.state = .failed(localized("Non riesco a controllare gli aggiornamenti. Controlla la connessione."))
                    } else if case .checking = self.state {
                        self.state = .idle
                    }
                    return
                }
                guard let release, Self.currentVersion < release.version else {
                    self.state = .upToDate
                    return
                }
                self.state = .available(release)
                if !userInitiated { self.notifyOnce(about: release) }
            }
        }.resume()
    }

    private func notifyOnce(about release: AppRelease) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedVersionKey) != release.version.description else { return }
        defaults.set(release.version.description, forKey: Self.notifiedVersionKey)
        let content = UNMutableNotificationContent()
        content.title = localized("Aggiornamento disponibile")
        content.body = String(format: localized("Meeting Pilot %@ è pronto. Aggiorna da Impostazioni o dal menu."), release.version.description)
        let request = UNNotificationRequest(identifier: "meeting-pilot-update-\(release.version)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Unable to schedule Meeting Pilot update notification: %@", error.localizedDescription)
            }
        }
    }

    /// Downloads and stages the release, then hands over to `relaunch`, which must quit the
    /// app: the installer waits for this process to exit before touching the bundle.
    func install(relaunch: @escaping () -> Void) {
        guard let release = availableRelease else { return }
        if case .downloading = state { return }
        guard Self.canInstallInPlace else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .downloading(release)
        AppLog.append("Scarico Meeting Pilot \(release.version)")
        session.downloadTask(with: release.dmgURL) { [weak self] location, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var outcome: Result<URL, UpdateError>
            if let location, error == nil, status == 200 {
                outcome = Self.stage(downloadedDMG: location, expected: release.version)
            } else {
                outcome = .failure(.download(error?.localizedDescription ?? "HTTP \(status)"))
            }
            if case .success(let stagedApp) = outcome {
                do {
                    try Self.launchInstaller(stagedApp: stagedApp, replacing: Bundle.main.bundleURL)
                } catch {
                    outcome = .failure(.install(error.localizedDescription))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success:
                    AppLog.append("Installo Meeting Pilot \(release.version) e riavvio")
                    relaunch()
                case .failure(let failure):
                    AppLog.append("Aggiornamento non riuscito: \(failure.detail)")
                    self.state = .failed(localized(failure.message))
                }
            }
        }.resume()
    }

    enum UpdateError: Error {
        case download(String)
        case invalid(String)
        case install(String)

        var message: String {
            switch self {
            case .download: return "Download dell'aggiornamento non riuscito. Riprova più tardi."
            case .invalid: return "L'aggiornamento scaricato non è valido. Scaricalo dalla pagina delle release."
            case .install: return "Non riesco a installare l'aggiornamento. Scaricalo dalla pagina delle release."
            }
        }

        var detail: String {
            switch self {
            case .download(let text), .invalid(let text), .install(let text): return text
            }
        }
    }

    /// Mounts the DMG, copies the app out with `ditto` (which keeps signature and execute
    /// bits), and accepts it only if its signature verifies and it is the expected version
    /// of this same app. Runs off the main thread.
    private static func stage(downloadedDMG: URL, expected: AppVersion) -> Result<URL, UpdateError> {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("MeetingPilotUpdate-\(UUID().uuidString)")
        let dmg = work.appendingPathComponent("MeetingPilot.dmg")
        let mountPoint = work.appendingPathComponent("mount")
        let staging = work.appendingPathComponent("staged")
        do {
            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.moveItem(at: downloadedDMG, to: dmg)
        } catch {
            return .failure(.download(error.localizedDescription))
        }

        let attach = runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mountPoint.path])
        guard attach.status == 0 else { return .failure(.invalid("hdiutil attach: \(attach.output)")) }
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let contents = (try? fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let mountedApp = contents.first(where: { $0.pathExtension == "app" }) else {
            return .failure(.invalid("no .app in the DMG"))
        }
        let stagedApp = staging.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        let copy = runTool("/usr/bin/ditto", [mountedApp.path, stagedApp.path])
        guard copy.status == 0 else { return .failure(.install("ditto: \(copy.output)")) }

        guard let info = Bundle(url: stagedApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == AppIdentity.bundleID,
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version == expected
        else { return .failure(.invalid("bundle identifier or version mismatch")) }

        let verify = runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        guard verify.status == 0 else { return .failure(.invalid("codesign: \(verify.output)")) }
        return .success(stagedApp)
    }

    /// Starts a small shell script that outlives the app: it waits for this process to
    /// quit, swaps the bundles (putting the old one back if the copy fails) and opens the
    /// installed app.
    private static func launchInstaller(stagedApp: URL, replacing installedApp: URL) throws {
        let work = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        let script = work.appendingPathComponent("install.sh")
        try installerScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            stagedApp.path,
            installedApp.path,
            work.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static let installerScript = """
    #!/bin/sh
    # Arguments: pid of the running app, staged app, installed app, work folder.
    pid="$1"; staged="$2"; installed="$3"; work="$4"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.5
      waited=$((waited + 1))
      [ "$waited" -gt 240 ] && exit 1
    done
    backup="$work/previous.app"
    if mv "$installed" "$backup"; then
      if ditto "$staged" "$installed"; then
        rm -rf "$backup"
      else
        rm -rf "$installed"
        mv "$backup" "$installed"
      fi
    fi
    xattr -dr com.apple.quarantine "$installed" 2>/dev/null
    open "$installed"
    rm -rf "$work"
    """

    private static func runTool(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
