// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Reuses the same pre-staged FluidAudio checkout that Scripts/build_app.sh already
// requires for building `fluidaudiocli` (see FLUID_AUDIO_SOURCE there), so the app and
// the CLI resource it bundles stay on the same FluidAudio revision.
let fluidAudioSourcePath =
    ProcessInfo.processInfo.environment["FLUID_AUDIO_SOURCE"]
    ?? (NSHomeDirectory() + "/Library/Application Support/Meeting Pilot/FluidAudioRuntime/source")

let package = Package(
    name: "MeetingPilot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: fluidAudioSourcePath)
    ],
    targets: [
        .executableTarget(
            name: "MeetingPilot",
            dependencies: [
                .product(name: "FluidAudio", package: "source")
            ],
            path: "Sources",
            exclude: [
                "Transcription/AppleTranscriber.swift",
                "Summarization/AppleIntelligenceSummarizer.swift",
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                // The app sources predate Swift 6's strict concurrency checking (e.g.
                // kAXTrustedCheckOptionPrompt.takeUnretainedValue() in PermissionsHelpers.swift).
                // Pinning to .v5 keeps the lenient mode until they are migrated.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .testTarget(
            name: "MeetingPilotTests",
            dependencies: ["MeetingPilot"],
            path: "Tests/MeetingPilotTests"
        ),
    ]
)
