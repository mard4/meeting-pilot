import XCTest
@testable import MeetingPilot

/// A scripted meeting app, so the detection and auto-stop state machine can run
/// without Teams, Accessibility or CoreAudio.
private final class FakeMeetingPlatform: MeetingPlatform {
    let displayName = "Teams"
    let fallbackMeetingTitle = "Riunione Teams"
    var title: String?
    var input: Bool? = false
    var titles: [String] = []
    var callSignal = false

    func windowSnapshot() -> MeetingWindowSnapshot {
        MeetingWindowSnapshot(titles: titles, frontmost: false, callSignal: callSignal)
    }
    func meetingPromptTitle() -> String? { title }
    func processIsRunningInput() -> Bool? { input }
    func looksLikeMeetingTitle(_ title: String) -> Bool { looksLikeTeamsMeetingTitle(title) }
}

final class RecordingControllerDetectionTests: XCTestCase {
    private var platform: FakeMeetingPlatform!
    private var controller: RecordingController!

    override func setUp() {
        platform = FakeMeetingPlatform()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        controller = RecordingController(
            cli: MeetingPilotCLI(envURL: root.appendingPathComponent(".env"), projectRoot: root),
            platform: platform
        )
        // A long delay keeps the real prompt window from ever appearing during tests.
        controller.settings = {
            RecorderSettings(mode: "macos_prompt", folder: "", openTarget: "", promptEnabled: true,
                             promptDelaySeconds: 3600, teamsOCREnabled: false)
        }
    }

    // MARK: Prompting

    func testNoCallVisible() {
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Nessuna call Teams rilevata")
    }

    func testCallWindowWithoutMicrophoneIsNotAMeeting() {
        platform.title = "Weekly sync"
        platform.input = false
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Teams aperto, nessuna call audio attiva")
    }

    func testCallWindowWithMicrophoneIsDetected() {
        platform.title = "Weekly sync"
        platform.input = true
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Call Teams rilevata: Weekly sync")
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Call Teams rilevata: Weekly sync")
    }

    func testPromptsDisabledLeavesStatusUntouched() {
        controller.settings = { .init(mode: "macos_prompt", folder: "", openTarget: "", promptEnabled: false,
                                      promptDelaySeconds: 3600, teamsOCREnabled: false) }
        platform.title = "Weekly sync"
        platform.input = true
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Non ancora letto")
    }

    func testManualPromptTitleFallsBackToPlatformTitle() {
        XCTAssertEqual(controller.currentMeetingPromptTitle(), "Riunione Teams")
        platform.title = "Roadmap"
        XCTAssertEqual(controller.currentMeetingPromptTitle(), "Roadmap")
    }

    // MARK: Automatic stop (native recording)

    func testMicrophoneInUseKeepsRecording() {
        controller.nativeRecordingActive = true
        platform.input = true
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Registrazione call Teams in corso")
    }

    func testMicrophoneReleaseStartsStopCountdownAndReturnCancelsIt() {
        controller.nativeRecordingActive = true
        platform.input = true
        controller.pollMeeting()

        platform.input = false
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Verifico fine call Teams...")
        controller.pollMeeting()
        XCTAssertTrue(controller.runtimeStatus.hasPrefix("Fine call rilevata: salvataggio tra "))
        XCTAssertTrue(controller.nativeRecordingActive)

        platform.input = true
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Registrazione call Teams in corso")
    }

    func testCallControlsKeepRecordingWhenMicrophoneUnknown() {
        controller.nativeRecordingActive = true
        platform.input = nil
        platform.callSignal = true
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Registrazione call Teams in corso")

        platform.callSignal = false
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Verifico fine call Teams...")
    }

    func testRecapWindowDoesNotBlockStopAfterCallControlsWereSeen() {
        controller.nativeRecordingActive = true
        platform.input = nil
        platform.callSignal = true
        controller.pollMeeting()

        platform.callSignal = false
        platform.titles = ["Weekly sync meeting"]
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Verifico fine call Teams...")
    }

    func testMeetingWindowAloneKeepsRecordingBeforeControlsAreSeen() {
        controller.nativeRecordingActive = true
        platform.input = nil
        platform.titles = ["Weekly sync meeting"]
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Registrazione call Teams in corso")
    }

    func testNeverAutoStopsWithoutObservingAMeeting() {
        controller.nativeRecordingActive = true
        platform.input = nil
        controller.pollMeeting()
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Non ancora letto")
        XCTAssertTrue(controller.nativeRecordingActive)
    }

    // MARK: External recorder

    func testExternalRecorderWaitsForConfirmationBeforeFinishing() {
        controller.externalRecordingActive = true
        platform.input = true
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Registrazione esterna in corso")

        platform.input = false
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Verifico fine call Teams...")
        controller.pollMeeting()
        XCTAssertEqual(controller.runtimeStatus, "Fine call rilevata: attendo conferma...")
        XCTAssertTrue(controller.externalRecordingActive)
    }
}
