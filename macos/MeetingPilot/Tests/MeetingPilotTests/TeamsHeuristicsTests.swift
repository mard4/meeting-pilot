import XCTest
@testable import MeetingPilot

/// Pins the Teams title and call-signal heuristics so platform refactors cannot
/// silently change which windows count as a meeting.
final class TeamsHeuristicsTests: XCTestCase {
    func testMeetingTitlesAreRecognised() {
        XCTAssertTrue(looksLikeTeamsMeetingTitle("Weekly sync | Riunione | Microsoft Teams"))
        XCTAssertTrue(looksLikeTeamsMeetingTitle("Standup meeting"))
        XCTAssertTrue(looksLikeTeamsMeetingTitle("Chiamata con Luca"))
        XCTAssertTrue(looksLikeTeamsMeetingTitle("Visualizzazione compatta delle riunioni"))
        XCTAssertTrue(looksLikeTeamsMeetingTitle("Compact meeting view"))
        XCTAssertTrue(looksLikeTeamsMeetingTitle("Design review | Acme | Microsoft Teams"))
    }

    func testNonMeetingTitlesAreRejected() {
        XCTAssertFalse(looksLikeTeamsMeetingTitle(""))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("   "))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("Microsoft Teams"))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("com.microsoft.teams2"))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("Centro di controllo"))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("Chat | Luca | Microsoft Teams"))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("Calendario | Microsoft Teams"))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("Activity | Meeting notes"))
        XCTAssertFalse(looksLikeTeamsMeetingTitle("Design review | Microsoft Teams"))
    }

    func testSpecificMeetingTitles() {
        XCTAssertTrue(looksLikeSpecificTeamsMeetingTitle("Design review"))
        XCTAssertFalse(looksLikeSpecificTeamsMeetingTitle("Teams"))
        XCTAssertFalse(looksLikeSpecificTeamsMeetingTitle("msteams"))
        XCTAssertFalse(looksLikeSpecificTeamsMeetingTitle("Calendario"))
        XCTAssertFalse(looksLikeSpecificTeamsMeetingTitle("Files | Shared"))
        XCTAssertFalse(looksLikeSpecificTeamsMeetingTitle("Compact meeting"))
    }

    func testCompactMeetingTitles() {
        XCTAssertTrue(looksLikeTeamsCompactMeetingTitle("Visualizzazione compatta delle riunioni"))
        XCTAssertTrue(looksLikeTeamsCompactMeetingTitle("Meeting compact view"))
        XCTAssertFalse(looksLikeTeamsCompactMeetingTitle("Weekly sync"))
    }

    func testCleaningRemovesTeamsSuffix() {
        XCTAssertEqual(cleanTeamsWindowTitle("Weekly sync | Microsoft Teams"), "Weekly sync")
        XCTAssertEqual(cleanTeamsWindowTitle("Weekly sync - Microsoft Teams "), "Weekly sync")
        XCTAssertEqual(cleanTeamsWindowTitle("Weekly sync"), "Weekly sync")
    }

    func testFallbackTitlePicksFirstSpecificTitle() {
        XCTAssertEqual(
            bestTeamsMeetingFallbackTitle(from: ["Microsoft Teams", "Chat | Luca", "Roadmap | Microsoft Teams"]),
            "Roadmap"
        )
        XCTAssertNil(bestTeamsMeetingFallbackTitle(from: ["Microsoft Teams", "Calendario"]))
    }

    func testCallSignalNeedsTwoControlGroups() {
        XCTAssertEqual(teamsCallSignalScore(in: ""), 0)
        XCTAssertEqual(teamsCallSignalScore(in: "Mute"), 1)
        XCTAssertFalse(teamsCallSignal(in: "Mute unmute microphone"))
        XCTAssertTrue(teamsCallSignal(in: "Leave Mute"))
        XCTAssertEqual(teamsCallSignalScore(in: "Abbandona Microfono Fotocamera Condividi Partecipanti Mano Reazioni"), 7)
    }

    func testDedupKeepsFirstOccurrenceOrder() {
        XCTAssertEqual(dedupPreservingOrder(["b", "a", "b", "c", "a"]), ["b", "a", "c"])
    }

    func testParticipantNameComesFromTheTileLabel() {
        XCTAssertEqual(
            TeamsSpeakerTracker.participantName(title: "Giulia Bianchi, Altre opzioni", labels: ["Giulia Bianchi"]),
            "Giulia Bianchi")
        XCTAssertEqual(
            TeamsSpeakerTracker.participantName(title: "Rossi, Mario, More options", labels: ["Rossi, Mario", "Rossi"]),
            "Rossi, Mario")
        XCTAssertEqual(
            TeamsSpeakerTracker.participantName(title: "D’Amico, Anna, Altre opzioni", labels: ["D'Amico, Anna "]),
            "D'Amico, Anna")
    }

    func testParticipantNameNeedsAMatchingLabel() {
        XCTAssertNil(TeamsSpeakerTracker.participantName(title: "Chat, Apri", labels: ["Riunione"]))
        XCTAssertNil(TeamsSpeakerTracker.participantName(title: "Giulia Bianchi, Altre opzioni", labels: []))
        XCTAssertNil(TeamsSpeakerTracker.participantName(title: "Giulia Bianchi", labels: ["Giulia Bianchi"]))
    }
}
