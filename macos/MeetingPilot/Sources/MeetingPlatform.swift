import Foundation

/// What a meeting app's windows say about a possible call right now.
struct MeetingWindowSnapshot {
    let titles: [String]
    let frontmost: Bool
    let callSignal: Bool
}

/// A desktop meeting app whose calls Meeting Pilot detects, records and stops on.
/// `RecordingController` only talks to this protocol, so adding Zoom or Meet means
/// adding a conformance rather than touching the detection state machine.
protocol MeetingPlatform {
    /// Short product name used in status messages ("Teams").
    var displayName: String { get }
    /// Title used when a call is detected but no window names it.
    var fallbackMeetingTitle: String { get }
    /// Window titles and in-call control signal for the app.
    func windowSnapshot() -> MeetingWindowSnapshot
    /// Meeting title to show in the recording prompt, or nil when no call is visible.
    func meetingPromptTitle() -> String?
    /// Whether the app is capturing the microphone; nil when CoreAudio cannot tell.
    func processIsRunningInput() -> Bool?
    func looksLikeMeetingTitle(_ title: String) -> Bool
}

struct TeamsPlatform: MeetingPlatform {
    let displayName = "Teams"
    let fallbackMeetingTitle = "Riunione Teams"

    func windowSnapshot() -> MeetingWindowSnapshot { teamsWindowSnapshot() }
    func meetingPromptTitle() -> String? { currentTeamsMeetingPromptTitle() }
    func processIsRunningInput() -> Bool? { teamsProcessIsRunningInput() }
    func looksLikeMeetingTitle(_ title: String) -> Bool { looksLikeTeamsMeetingTitle(title) }
}
