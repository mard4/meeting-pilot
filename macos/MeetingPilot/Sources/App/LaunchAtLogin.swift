// LaunchAtLogin.swift
// Keeps the "open at login" item registered for the build that is actually installed.

import Foundation
import Security
import ServiceManagement

/// macOS records the login item against the app's code signature. Builds signed ad hoc get
/// a new signature on every update, so a registration made by an older build keeps reading
/// as `.enabled` while macOS no longer launches the new binary at login. Registering again
/// whenever the signature changes keeps the item pointing at the current build.
enum LaunchAtLogin {
    enum Outcome {
        case enabled
        case disabled
        case needsApproval
        case notInApplications
        case failed(Error)
    }

    private static let registeredSignatureKey = "MeetingPilotLaunchAtLoginSignature"

    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.contains("/Applications/")
    }

    static var needsApproval: Bool {
        isInstalledInApplications && SMAppService.mainApp.status == .requiresApproval
    }

    static func apply(_ enabled: Bool) -> Outcome {
        guard isInstalledInApplications else { return .notInApplications }
        let service = SMAppService.mainApp
        let defaults = UserDefaults.standard
        do {
            guard enabled else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
                defaults.removeObject(forKey: registeredSignatureKey)
                return .disabled
            }
            let signature = currentSignature()
            let registeredForThisBuild = defaults.string(forKey: registeredSignatureKey) == signature
            if service.status == .enabled && registeredForThisBuild {
                return .enabled
            }
            if service.status == .enabled {
                // Stale item from a previous build: drop it so the new one replaces it.
                try? service.unregister()
            }
            try service.register()
            defaults.set(signature, forKey: registeredSignatureKey)
            return service.status == .requiresApproval ? .needsApproval : .enabled
        } catch {
            // The user switched the item off in System Settings: only they can turn it back on.
            if service.status == .requiresApproval { return .needsApproval }
            return .failed(error)
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The running binary's cdhash, which changes with every build; the bundle version when
    /// the signature cannot be read.
    private static func currentSignature() -> String {
        let fallback = "build-" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return fallback }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return fallback }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let info = info as? [String: Any],
              let unique = info[kSecCodeInfoUnique as String] as? Data else { return fallback }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
