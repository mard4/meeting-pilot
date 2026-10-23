import XCTest
@testable import MeetingPilot

final class MCPClientSetupTests: XCTestCase {
    private var folder: URL!
    private let cli = MeetingPilotCLI(
        envURL: URL(fileURLWithPath: "/Users/demo/Library/Application Support/Meeting Pilot/.env"),
        projectRoot: URL(fileURLWithPath: "/tmp")
    )

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MCPClientSetupTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func servers(in url: URL) throws -> [String: Any] {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return config?["mcpServers"] as? [String: Any] ?? [:]
    }

    func testConnectingKeepsTheOtherServersAndSettingsAndDisconnectingRemovesOnlyMeetingPilot() throws {
        let url = folder.appendingPathComponent("claude_desktop_config.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"command":"/bin/other"}},"globalShortcut":"Cmd+Space"}"#.utf8).write(to: url)

        XCTAssertFalse(MCPClientSetup.isConnectedToClaudeDesktop(cli: cli, config: url))
        try MCPClientSetup.setClaudeDesktop(connected: true, cli: cli, config: url)
        XCTAssertTrue(MCPClientSetup.isConnectedToClaudeDesktop(cli: cli, config: url))
        let entry = try servers(in: url)["meeting-pilot"] as? [String: Any]
        XCTAssertEqual(entry?["command"] as? String, cli.path)
        XCTAssertEqual(entry?["args"] as? [String], ["mcp"])
        XCTAssertEqual((entry?["env"] as? [String: String])?["MEETING_PILOT_ENV_FILE"], cli.envURL.path)
        XCTAssertNotNil(try servers(in: url)["other"])

        try MCPClientSetup.setClaudeDesktop(connected: false, cli: cli, config: url)
        XCTAssertEqual(Array(try servers(in: url).keys), ["other"])
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(config?["globalShortcut"] as? String, "Cmd+Space")
    }

    func testConnectingCreatesTheConfigWhenClaudeHasNone() throws {
        let url = folder.appendingPathComponent("Claude/claude_desktop_config.json")
        try MCPClientSetup.setClaudeDesktop(connected: true, cli: cli, config: url)
        XCTAssertTrue(MCPClientSetup.isConnectedToClaudeDesktop(cli: cli, config: url))
    }

    func testAConfigThatIsNotJSONIsReportedInsteadOfReplaced() throws {
        let url = folder.appendingPathComponent("claude_desktop_config.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        XCTAssertTrue(MCPClientSetup.configUnreadable(url))
    }

    func testClaudeCodeCommandQuotesPathsWithSpaces() {
        let command = MCPClientSetup.claudeCodeCommand(cli: cli)
        XCTAssertTrue(command.hasPrefix("claude mcp add --scope user meeting-pilot --env MEETING_PILOT_ENV_FILE='/Users/demo/Library/Application Support/Meeting Pilot/.env' -- '"))
        XCTAssertTrue(command.hasSuffix("' mcp"))
    }

    func testConnectingCodexKeepsTheRestOfItsConfigAndDisconnectingRemovesOnlyMeetingPilot() throws {
        let url = folder.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = """
        model = "gpt-5"

        [mcp_servers.other]
        command = "/bin/other"

        [mcp_servers."meeting-pilot"]
        command = "/old/MeetingPilotCLI"

        [mcp_servers."meeting-pilot".env]
        OLD = "1"

        [profiles.work]
        model = "o3"
        """
        try original.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertFalse(MCPClientSetup.isConnectedToCodex(cli: cli, config: url))
        try MCPClientSetup.setCodex(connected: true, cli: cli, config: url)
        XCTAssertTrue(MCPClientSetup.isConnectedToCodex(cli: cli, config: url))
        let connected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(connected.contains("/old/MeetingPilotCLI"))
        XCTAssertFalse(connected.contains("OLD"))
        XCTAssertTrue(connected.contains("[mcp_servers.other]\ncommand = \"/bin/other\""))
        XCTAssertTrue(connected.contains("[profiles.work]\nmodel = \"o3\""))
        XCTAssertTrue(connected.contains("env = { MEETING_PILOT_ENV_FILE = \"/Users/demo/Library/Application Support/Meeting Pilot/.env\" }"))

        try MCPClientSetup.setCodex(connected: false, cli: cli, config: url)
        XCTAssertFalse(MCPClientSetup.isConnectedToCodex(cli: cli, config: url))
        let disconnected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(disconnected.contains("meeting-pilot"))
        XCTAssertTrue(disconnected.hasPrefix("model = \"gpt-5\"\n\n[mcp_servers.other]"))
        XCTAssertTrue(disconnected.hasSuffix("[profiles.work]\nmodel = \"o3\"\n"))
    }

    func testConnectingCodexCreatesItsConfigWhenThereIsNone() throws {
        let url = folder.appendingPathComponent(".codex/config.toml")
        try MCPClientSetup.setCodex(connected: true, cli: cli, config: url)
        XCTAssertTrue(MCPClientSetup.isConnectedToCodex(cli: cli, config: url))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("[mcp_servers.meeting-pilot]\n"))
    }
}
