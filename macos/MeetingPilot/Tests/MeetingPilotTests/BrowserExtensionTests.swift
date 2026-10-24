import XCTest
@testable import MeetingPilot

final class BrowserExtensionTests: XCTestCase {
    private var folder: URL!
    private var support: URL { folder.appendingPathComponent("Application Support") }
    private var config: URL { support.appendingPathComponent("Meeting Pilot") }
    private let host = URL(fileURLWithPath: "/Applications/Meeting Pilot.app/Contents/MacOS/MeetingPilotBrowserHost")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserExtensionTests-\(UUID().uuidString)")
        for browser in ["Google/Chrome", "BraveSoftware/Brave-Browser"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(browser), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSetupWritesAManifestOnlyForTheBrowsersThisMacHas() throws {
        let names = try BrowserExtensionSetup.configure(configRoot: config, host: host, support: support)
        XCTAssertEqual(names, ["Chrome", "Brave"])
        let manifest = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.meetingpilot.browser.json")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        XCTAssertEqual(payload?["path"] as? String, host.path)
        XCTAssertEqual(payload?["type"] as? String, "stdio")
        XCTAssertEqual(payload?["allowed_origins"] as? [String], [
            "chrome-extension://ipnadmfmihedhmlppdjoldfnjpmjghen/",
            "chrome-extension://blgkijnmbiefebagnjlieceagflahnin/",
        ], "the Chrome Web Store's extension and a development copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Microsoft Edge").path), "no folder for a browser that is not installed")
    }

    func testTheTokenIsPrivateAndKeptAcrossSetups() throws {
        try BrowserExtensionSetup.configure(configRoot: config, host: host, support: support)
        let token = try XCTUnwrap(BrowserExtensionSetup.token(configRoot: config))
        XCTAssertEqual(token.count, 64)
        let permissions = try FileManager.default.attributesOfItem(atPath: BrowserExtensionSetup.tokenURL(configRoot: config).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try BrowserExtensionSetup.configure(configRoot: config, host: host, support: support)
        XCTAssertEqual(BrowserExtensionSetup.token(configRoot: config), token)
    }

    func testLaunchRemovesTheCopyEarlierVersionsMadeForLoadingUnpacked() throws {
        let old = BrowserExtensionSetup.oldExtensionCopy(configRoot: config)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        BrowserExtensionSetup.refreshIfConfigured(configRoot: config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testRemovingLeavesNoManifestOrToken() throws {
        try BrowserExtensionSetup.configure(configRoot: config, host: host, support: support)
        BrowserExtensionSetup.remove(configRoot: config, support: support)
        XCTAssertNil(BrowserExtensionSetup.token(configRoot: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.meetingpilot.browser.json").path))
    }

    func testOnlyTheHostsTokenImportsWithoutAsking() {
        let video = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let withToken = URL(string: "meetingpilot://import?url=\(video)&token=secret")!
        XCTAssertEqual(
            BrowserExtensionSetup.importAction(for: withToken, token: "secret"),
            .importNow(id: "dQw4w9WgXcQ", url: URL(string: video)!)
        )
        XCTAssertEqual(BrowserExtensionSetup.importAction(for: withToken, token: "other"), .askFirst(video))
        XCTAssertEqual(BrowserExtensionSetup.importAction(for: withToken, token: nil), .askFirst(video), "not set up: nothing to compare with")
        XCTAssertEqual(BrowserExtensionSetup.importAction(for: URL(string: "meetingpilot://import?url=\(video)")!, token: "secret"), .askFirst(video))
        XCTAssertEqual(BrowserExtensionSetup.importAction(for: URL(string: "meetingpilot://import?url=https://vimeo.com/1&token=secret")!, token: "secret"), .askFirst("https://vimeo.com/1"))
        XCTAssertEqual(BrowserExtensionSetup.importAction(for: URL(string: "meetingpilot://notion?state=x")!, token: "secret"), .notAnImport)
    }
}
