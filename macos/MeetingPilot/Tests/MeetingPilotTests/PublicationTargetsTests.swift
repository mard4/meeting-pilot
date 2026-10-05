import XCTest
@testable import MeetingPilot

final class PublicationTargetsTests: XCTestCase {
    /// A fresh install writes the Notion keys with empty values; that must not read as
    /// a Notion connection.
    func testFreshInstallDefaultsToTheDiary() {
        let env = ["NOTION_TOKEN": "", "NOTION_DATABASE_ID": "", "NOTION_OCCURRENCES_DATABASE_ID": ""]
        XCTAssertEqual(parsePublicationTargets(env), ["journal"])
        XCTAssertEqual(parsePublicationTargets([:]), ["journal"])
    }

    func testConfiguredNotionOrObsidianWinsWithoutAnExplicitChoice() {
        XCTAssertEqual(parsePublicationTargets(["NOTION_TOKEN": "secret", "NOTION_OCCURRENCES_DATABASE_ID": "db"]), ["notion"])
        XCTAssertEqual(parsePublicationTargets(["NOTION_TOKEN": "secret", "NOTION_DATABASE_ID": ""]), ["journal"])
        XCTAssertEqual(parsePublicationTargets(["OBSIDIAN_VAULT_PATH": "~/Vault"]), ["obsidian"])
    }

    func testExplicitChoiceIsKept() {
        XCTAssertEqual(parsePublicationTargets(["PUBLISH_TARGETS": "journal, notion"]), ["journal", "notion"])
        XCTAssertEqual(parsePublicationTargets(["PUBLISH_TARGETS": "", "PUBLISH_TARGETS_EXPLICIT": "true"]), [])
    }
}
