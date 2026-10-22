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

final class PublicationLinksTests: XCTestCase {
    func testObsidianOpensANoteByItsPathEvenWithSpacesAndAccents() {
        let note = URL(fileURLWithPath: "/Users/demo/Vault/Meeting Pilot/2026-10-09 - Perché è così.md")
        let url = AppModel.obsidianURL(for: note)
        XCTAssertEqual(url?.scheme, "obsidian")
        XCTAssertEqual(url?.host, "open")
        let path = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
        XCTAssertEqual(path, note.path)
    }

    func testAppleNotesTargetKeepsTheNoteFromItsReceipt() {
        let targets = meetingPublicationTargets(
            notionReceipt: [:], journalReceipt: [:], obsidianReceipt: [:],
            appleNotesReceipt: ["note_id": "x-coredata://ABC/ICNote/p42\n"], configuredTargets: []
        )
        XCTAssertEqual(targets.first?.service, .appleNotes)
        XCTAssertEqual(targets.first?.noteID, "x-coredata://ABC/ICNote/p42")
    }
}
