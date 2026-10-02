import AppKit
import ApplicationServices
import CoreAudio

// Helpers any MeetingPlatform can use: they know nothing about a specific app.

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
