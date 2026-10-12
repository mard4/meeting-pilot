import XCTest
@testable import MeetingPilot

final class AppUpdaterTests: XCTestCase {
    func testVersionsCompareNumberByNumber() throws {
        let current = try XCTUnwrap(AppVersion("0.2.1"))
        XCTAssertLessThan(current, try XCTUnwrap(AppVersion("v0.2.2")))
        XCTAssertLessThan(current, try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9")), try XCTUnwrap(AppVersion("0.10")))
        XCTAssertFalse(current < AppVersion("0.2.1")!)
        XCTAssertEqual(try XCTUnwrap(AppVersion("0.3")), try XCTUnwrap(AppVersion("v0.3.0")))
        XCTAssertEqual(AppVersion("1.0.0-beta")?.description, "1.0.0")
    }

    func testUnreadableVersionsAreRejected() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testLatestReleaseOffersTheDMG() throws {
        let json = """
        {
          "tag_name": "v0.3.0",
          "body": "Aggiornamento dall'app\\n",
          "html_url": "https://github.com/mard4/meeting-pilot/releases/tag/v0.3.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt"},
            {"name": "MeetingPilot.dmg", "browser_download_url": "https://github.com/mard4/meeting-pilot/releases/download/v0.3.0/MeetingPilot.dmg"}
          ]
        }
        """
        let release = try XCTUnwrap(AppRelease.parse(Data(json.utf8)))
        XCTAssertEqual(release.version.description, "0.3.0")
        XCTAssertEqual(release.notes, "Aggiornamento dall'app")
        XCTAssertEqual(release.dmgURL.lastPathComponent, "MeetingPilot.dmg")
    }

    func testReleasesWithoutDMGOrMarkedPrereleaseAreIgnored() {
        let noDMG = #"{"tag_name": "v0.3.0", "html_url": "https://github.com/x", "assets": []}"#
        XCTAssertNil(AppRelease.parse(Data(noDMG.utf8)))
        let prerelease = """
        {"tag_name": "v0.3.0", "html_url": "https://github.com/x", "prerelease": true,
         "assets": [{"name": "MeetingPilot.dmg", "browser_download_url": "https://github.com/x.dmg"}]}
        """
        XCTAssertNil(AppRelease.parse(Data(prerelease.utf8)))
    }

    func testInstallerScriptWaitsForTheAppAndRestoresOnFailure() {
        let script = AppUpdater.installerScript
        XCTAssertTrue(script.contains(#"kill -0 "$pid""#))
        XCTAssertTrue(script.contains(#"ditto "$staged" "$installed""#))
        XCTAssertTrue(script.contains(#"mv "$backup" "$installed""#))
        XCTAssertTrue(script.contains(#"open "$installed""#))
    }

    /// A valid signature is not enough: an ad hoc one anybody can make must not pass for
    /// an update of this app.
    func testUpdateSignedBySomeoneElseIsRejected() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterTest-\(UUID().uuidString)/Meeting Pilot.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let executables = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executables.appendingPathComponent("MeetingPilot").path)
        let info: [String: Any] = ["CFBundleIdentifier": AppIdentity.bundleID, "CFBundleExecutable": "MeetingPilot"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)

        XCTAssertNotNil(AppUpdater.signatureFailure(of: app))
    }
}
