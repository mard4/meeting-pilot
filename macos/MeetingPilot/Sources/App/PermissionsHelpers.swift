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


func notificationPermissionRow(granted: Bool) -> PermissionRow {
    PermissionRow(
        id: "notifications",
        title: "Notifiche",
        granted: granted,
        settingsURL: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleID)",
        reason: "Serve per avvisarti quando il riepilogo di una call è pronto e pubblicato."
    )
}

enum SystemAudioPermissionState {
    private static let confirmedKey = "MeetingPilotAudioTapCaptureConfirmed"
    private static let attemptedKey = "MeetingPilotAudioTapCaptureAttempted"

    static var confirmed: Bool {
        UserDefaults.standard.bool(forKey: confirmedKey)
    }

    static var attempted: Bool {
        UserDefaults.standard.bool(forKey: attemptedKey)
    }

    static func setConfirmed(_ value: Bool) {
        UserDefaults.standard.set(true, forKey: attemptedKey)
        UserDefaults.standard.set(value, forKey: confirmedKey)
    }
}

func permissions(includeSystemAudio: Bool, includeAppleDictation: Bool = false) -> [PermissionRow] {
    let accessibility = AXIsProcessTrusted()
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var rows = [
        PermissionRow(
            id: "accessibility",
            title: "Accessibilita",
            granted: accessibility,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            reason: "Serve per leggere titolo e partecipanti della riunione da Teams."
        ),
        PermissionRow(
            id: "microphone",
            title: "Microfono",
            granted: microphone,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            reason: "Serve se usi il recorder macOS integrato o controlli audio locali."
        )
    ]
    if includeSystemAudio && SystemAudioPermissionState.attempted {
        rows.append(
            PermissionRow(
                id: "system_audio",
                title: "Audio di sistema",
                granted: SystemAudioPermissionState.confirmed,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                reason: "Serve al recorder macOS per includere l'audio di Teams e le voci degli altri partecipanti. Dopo averlo abilitato, riapri Meeting Pilot."
            )
        )
    }
    if includeAppleDictation {
        let modernAppleSpeech = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        rows.append(
            PermissionRow(
                id: "apple_speech",
                title: modernAppleSpeech ? "Trascrizione Apple on-device" : "Dettatura e riconoscimento Apple",
                granted: modernAppleSpeech || (appleDictationEnabled() && appleSpeechRecognitionAuthorized()),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
                reason: modernAppleSpeech
                    ? "Su macOS Tahoe SpeechAnalyzer trascrive localmente e scarica i modelli necessari dal catalogo condiviso di macOS."
                    : "Apple On-Device richiede Dettatura attiva e l'autorizzazione Riconoscimento vocale per trascrivere localmente l'audio."
            )
        )
    }
    return rows
}

func appleDictationEnabled() -> Bool {
    if let preferences = UserDefaults(suiteName: "com.apple.assistant.support"),
       preferences.object(forKey: "Dictation Enabled") != nil {
        return preferences.bool(forKey: "Dictation Enabled")
    }
    if let preferences = UserDefaults(suiteName: "com.apple.HIToolbox"),
       preferences.object(forKey: "AppleDictationAutoEnable") != nil {
        return preferences.bool(forKey: "AppleDictationAutoEnable")
    }
    return false
}

func appleSpeechRecognitionAuthorized() -> Bool {
    SFSpeechRecognizer.authorizationStatus() == .authorized
}

func requestAccessibilityPermission() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

func relaunchApp() {
    let bundleURL = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
        DispatchQueue.main.async {
            if error == nil {
                NSApp.terminate(nil)
            }
        }
    }
}

func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        completion(true)
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    default:
        completion(false)
    }
}
