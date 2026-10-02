import XCTest
@testable import MeetingPilot

final class WatcherProcessTests: XCTestCase {
    private let bundled = "/Applications/Meeting Pilot.app/Contents/Resources/MeetingPilotCLI/MeetingPilotCLI"

    func testBundledCLIWatchIsTheWatcher() {
        XCTAssertTrue(isWatcherCommand(executable: bundled, arguments: "\(bundled) watch"))
    }

    func testCheckoutScriptUnderPythonIsTheWatcher() {
        XCTAssertTrue(isWatcherCommand(
            executable: "/repo/.venv311/bin/python3.11",
            arguments: "/repo/.venv311/bin/python3.11 /repo/.venv311/bin/meeting-pilot watch"
        ))
    }

    func testOtherCLICommandsAreNotTheWatcher() {
        XCTAssertFalse(isWatcherCommand(executable: bundled, arguments: "\(bundled) teams-scrape --no-ocr"))
        XCTAssertFalse(isWatcherCommand(executable: bundled, arguments: "\(bundled) chat --question watch me"))
    }

    func testShellsMentioningTheWatcherAreNotTheWatcher() {
        XCTAssertFalse(isWatcherCommand(executable: "/bin/zsh", arguments: "/bin/zsh -c pgrep -fl \"MeetingPilotCLI watch\""))
        XCTAssertFalse(isWatcherCommand(executable: "/usr/bin/grep", arguments: "grep MeetingPilotCLI watch"))
        XCTAssertFalse(isWatcherCommand(executable: "/usr/bin/python3", arguments: "python3 -c print('meeting-pilot watch')"))
    }
}
