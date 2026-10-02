import Foundation

struct TeamsPlatform: MeetingPlatform {
    let displayName = "Teams"
    let fallbackMeetingTitle = "Riunione Teams"

    func windowSnapshot() -> MeetingWindowSnapshot { teamsWindowSnapshot() }
    func meetingPromptTitle() -> String? { currentTeamsMeetingPromptTitle() }
    func processIsRunningInput() -> Bool? { teamsProcessIsRunningInput() }
    func looksLikeMeetingTitle(_ title: String) -> Bool { looksLikeTeamsMeetingTitle(title) }
}
