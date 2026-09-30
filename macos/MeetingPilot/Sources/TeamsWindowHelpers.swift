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


struct TeamsWindowSnapshot {
    let titles: [String]
    let frontmost: Bool
    let callSignal: Bool
}

func currentTeamsMeetingPromptTitle() -> String? {
    let snapshot = teamsWindowSnapshot()
    var candidate: String?
    for title in snapshot.titles {
        if looksLikeTeamsMeetingTitle(title) {
            candidate = candidate ?? cleanTeamsWindowTitle(title)
        }
    }
    if let candidate {
        return candidate
    }
    if snapshot.callSignal {
        return bestTeamsMeetingFallbackTitle(from: snapshot.titles) ?? "Riunione Teams"
    }
    return nil
}

func defaultInputDeviceIsRunning() -> Bool {
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var deviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &deviceAddress,
        0,
        nil,
        &deviceSize,
        &deviceID
    ) == noErr, deviceID != kAudioObjectUnknown else {
        return false
    }

    var running: UInt32 = 0
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &runningAddress),
          AudioObjectGetPropertyData(
              deviceID,
              &runningAddress,
              0,
              nil,
              &runningSize,
              &running
          ) == noErr else {
        return false
    }
    return running != 0
}

func teamsProcessIsRunningInput() -> Bool? {
    var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &byteCount) == noErr else {
        return nil
    }
    let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return false }
    var processObjects = Array(repeating: AudioObjectID(0), count: count)
    let listStatus = processObjects.withUnsafeMutableBytes { buffer in
        AudioObjectGetPropertyData(system, &listAddress, 0, nil, &byteCount, buffer.baseAddress!)
    }
    guard listStatus == noErr else { return nil }

    for processObject in processObjects {
        var pid = pid_t(0)
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(processObject, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
              let app = NSRunningApplication(processIdentifier: pid) else { continue }
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        guard name.contains("teams") || bundle.contains("teams") else { continue }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(processObject, &runningAddress, 0, nil, &runningSize, &running) == noErr,
           running != 0 {
            return true
        }
    }
    return false
}

func teamsWindowSnapshot() -> TeamsWindowSnapshot {
    let frontmostApp = NSWorkspace.shared.frontmostApplication
    let frontmostName = frontmostApp?.localizedName?.lowercased() ?? ""
    let frontmostBundle = frontmostApp?.bundleIdentifier?.lowercased() ?? ""
    let frontmost = frontmostName.contains("teams") || frontmostBundle.contains("teams")

    let axSnapshot = teamsWindowAccessibilitySnapshot()
    let cgTitles = teamsWindowTitlesViaCoreGraphics()
    return TeamsWindowSnapshot(
        titles: dedupPreservingOrder(axSnapshot.titles + cgTitles),
        frontmost: frontmost,
        callSignal: axSnapshot.callSignal
    )
}

func teamsWindowTitlesViaCoreGraphics() -> [String] {
    guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return windowInfo.compactMap { item -> String? in
        let ownerRaw = item[kCGWindowOwnerName as String] as? String ?? ""
        let owner = ownerRaw.lowercased()
        guard owner.contains("microsoft teams") || owner == "msteams" || owner == "teams" else { return nil }
        let layer = item[kCGWindowLayer as String] as? Int ?? 0
        let title = (item[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard layer == 0 || looksLikeTeamsCompactMeetingTitle(title) else { return nil }
        return title.isEmpty ? nil : title
    }
}

func teamsWindowAccessibilitySnapshot() -> (titles: [String], callSignal: Bool) {
    guard AXIsProcessTrusted() else { return ([], false) }

    let teamsApps = NSWorkspace.shared.runningApplications.filter { app in
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        return name.contains("teams") || bundle.contains("teams")
    }
    guard !teamsApps.isEmpty else { return ([], false) }

    var titles: [String] = []
    var callSignal = false
    for app in teamsApps {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { continue }

        for window in windows.prefix(6) {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                titles.append(title)
            }
            if !callSignal {
                callSignal = teamsCallSignal(in: collectAccessibilityText(from: window).joined(separator: " "))
            }
        }
    }
    return (titles, callSignal)
}

func collectAccessibilityText(from root: AXUIElement, maxNodes: Int = 180) -> [String] {
    var queue = [root]
    var values: [String] = []
    var visited = 0
    let textAttributes = [
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXValueAttribute,
        kAXRoleDescriptionAttribute,
        kAXHelpAttribute
    ]
    let childAttributes = [
        kAXChildrenAttribute,
        kAXVisibleChildrenAttribute
    ]

    while let element = queue.first, visited < maxNodes {
        queue.removeFirst()
        visited += 1

        for attribute in textAttributes {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
               let value = (valueRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                values.append(value)
            }
        }

        for attribute in childAttributes {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
    }

    return values
}

func dedupPreservingOrder(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}

func cleanTeamsWindowTitle(_ title: String) -> String {
    title.replacingOccurrences(of: " | Microsoft Teams", with: "")
        .replacingOccurrences(of: " - Microsoft Teams", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func bestTeamsMeetingFallbackTitle(from titles: [String]) -> String? {
    for title in titles {
        let cleaned = cleanTeamsWindowTitle(title)
        if looksLikeSpecificTeamsMeetingTitle(cleaned) {
            return cleaned
        }
    }
    return nil
}

func looksLikeTeamsCompactMeetingTitle(_ title: String) -> Bool {
    let lower = title.lowercased()
    return lower.contains("visualizzazione compatta delle riunioni")
        || lower.contains("compact meeting")
        || lower.contains("meeting compact")
}

func teamsCallSignal(in text: String) -> Bool {
    teamsCallSignalScore(in: text) >= 2
}

func teamsCallSignalScore(in text: String) -> Int {
    let lower = text.lowercased()
    let signalGroups = [
        ["abbandona", "appendi", "hang up", "leave"],
        ["microfono", "microphone", "mute", "unmute"],
        ["fotocamera", "videocamera", "camera"],
        ["contenuti", "condividi", "share", "content"],
        ["partecipanti", "participants"],
        ["mano", "raise hand"],
        ["reazioni", "reactions"]
    ]
    return signalGroups.reduce(0) { count, group in
        count + (group.contains { lower.contains($0) } ? 1 : 0)
    }
}

func looksLikeSpecificTeamsMeetingTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if trimmed.isEmpty || lower == "microsoft teams" || lower == "teams" || lower == "msteams" {
        return false
    }
    if lower == "com.microsoft.teams2" {
        return false
    }
    if lower.contains("centro di controllo") || lower.contains("control center") {
        return false
    }
    if looksLikeTeamsCompactMeetingTitle(lower) {
        return false
    }
    let genericTitles = [
        "activity",
        "attivita",
        "calendar",
        "calendario",
        "calls",
        "chiamate",
        "chat",
        "teams",
        "notifiche",
        "notifications",
        "settings",
        "impostazioni"
    ]
    if genericTitles.contains(lower) {
        return false
    }
    let nonMeetingPrefixes = [
        "activity |",
        "attivita |",
        "calendar |",
        "calendario |",
        "calls |",
        "chiamate |",
        "chat |",
        "teams |",
        "files |",
        "file |",
        "apps |",
        "app |"
    ]
    if nonMeetingPrefixes.contains(where: { lower.hasPrefix($0) }) {
        return false
    }
    return true
}

func looksLikeTeamsMeetingTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if trimmed.isEmpty || lower == "microsoft teams" {
        return false
    }
    if lower.contains("centro di controllo") || lower.contains("control center") || lower == "com.microsoft.teams2" {
        return false
    }
    let nonMeetingPrefixes = [
        "activity |",
        "attivita |",
        "calendar |",
        "calendario |",
        "calls |",
        "chiamate |",
        "chat |",
        "teams |"
    ]
    if nonMeetingPrefixes.contains(where: { lower.hasPrefix($0) }) {
        return false
    }
    if lower.contains("visualizzazione compatta delle riunioni") || lower.contains("compact meeting") {
        return true
    }
    if lower.contains("meeting") || lower.contains("riunione") || lower.contains("call") || lower.contains("chiamata") {
        return true
    }
    let separators = trimmed.filter { $0 == "|" }.count
    if (lower.contains("| microsoft teams") || lower.contains("- microsoft teams"))
        && separators >= 2
        && !lower.hasPrefix("calendar |")
        && !lower.hasPrefix("calendario |")
        && !lower.hasPrefix("chat |") {
        return true
    }
    return false
}
