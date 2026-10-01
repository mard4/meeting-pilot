import XCTest
@testable import MeetingPilot

final class ThemeTests: XCTestCase {
    func testSupportedThemesParse() {
        XCTAssertEqual(MeetingPilotTheme(rawValue: "dark"), .dark)
        XCTAssertEqual(MeetingPilotTheme(rawValue: "light"), .light)
    }

    func testUnknownOrMissingThemesAreRejected() {
        XCTAssertNil(MeetingPilotTheme(rawValue: "unknown"))
        XCTAssertNil(MeetingPilotTheme(rawValue: nil as String?))
    }
}
