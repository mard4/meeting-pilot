import AppKit
import SwiftUI

/// Connects Claude, Codex and other MCP clients to the meetings: they start the bundled
/// CLI as `MeetingPilotCLI mcp`, which only reads. Claude Desktop and Codex are set up by
/// writing their config files; the others get a command or a snippet to paste.
enum MCPClientSetup {
    static let serverName = "meeting-pilot"

    static var claudeDesktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// What every client is told to run. The CLI finds `.env` on its own too, but naming
    /// it keeps a moved configuration working.
    static func server(cli: MeetingPilotCLI) -> [String: Any] {
        ["command": cli.path, "args": ["mcp"], "env": ["MEETING_PILOT_ENV_FILE": cli.envURL.path]]
    }

    static func snippet(cli: MeetingPilotCLI) -> String {
        let payload: [String: Any] = ["mcpServers": [serverName: server(cli: cli)]]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func claudeCodeCommand(cli: MeetingPilotCLI) -> String {
        "claude mcp add --scope user \(serverName) --env MEETING_PILOT_ENV_FILE=\(shellQuoted(cli.envURL.path)) -- \(shellQuoted(cli.path)) mcp"
    }

    static func isConnectedToClaudeDesktop(cli: MeetingPilotCLI, config url: URL = claudeDesktopConfig) -> Bool {
        guard let entry = (readConfig(url)["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else { return false }
        return entry["command"] as? String == cli.path
    }

    /// Adds or removes Meeting Pilot in Claude Desktop's config, keeping everything else
    /// in it. Claude Desktop reads the file when it starts.
    static func setClaudeDesktop(connected: Bool, cli: MeetingPilotCLI, config url: URL = claudeDesktopConfig) throws {
        var config = readConfig(url)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = connected ? server(cli: cli) : nil
        config["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A file that exists but is not JSON is never overwritten: it may hold servers the
    /// user wrote by hand with a typo.
    private static func readConfig(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func configUnreadable(_ url: URL = claudeDesktopConfig) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) == nil
    }

    /// Shared by the Codex app, CLI and IDE extension; `CODEX_HOME` moves it.
    static var codexConfig: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("config.toml")
    }

    static func codexTable(cli: MeetingPilotCLI) -> String {
        """
        [mcp_servers.\(serverName)]
        command = \(tomlString(cli.path))
        args = ["mcp"]
        env = { MEETING_PILOT_ENV_FILE = \(tomlString(cli.envURL.path)) }
        """
    }

    static func isConnectedToCodex(cli: MeetingPilotCLI, config url: URL = codexConfig) -> Bool {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let commandLine = "command = \(tomlString(cli.path))"
        var inMeetingPilot = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inMeetingPilot = isMeetingPilotTable(trimmed)
            } else if inMeetingPilot && trimmed.replacingOccurrences(of: " ", with: "") == commandLine.replacingOccurrences(of: " ", with: "") {
                return true
            }
        }
        return false
    }

    /// Codex's config is TOML, so instead of parsing it the Meeting Pilot table (and any
    /// subtable of it) is cut out line by line and, to connect, written again at the end;
    /// every other line stays as the user wrote it.
    static func setCodex(connected: Bool, cli: MeetingPilotCLI, config url: URL = codexConfig) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var inMeetingPilot = false
        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inMeetingPilot = isMeetingPilotTable(trimmed) }
            if !inMeetingPilot { kept.append(line) }
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        if connected {
            if !kept.isEmpty { kept.append("") }
            kept.append(codexTable(cli: cli))
        }
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `[mcp_servers.meeting-pilot]`, its quoted spelling, or a subtable such as `.env`.
    private static func isMeetingPilotTable(_ header: String) -> Bool {
        let name = header
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .components(separatedBy: "#")[0]
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "]", with: "")
        let table = "mcp_servers.\(serverName)"
        return name == table || name.hasPrefix(table + ".")
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The rows of the MCP group in Settings.
struct MCPClientRows: View {
    @EnvironmentObject private var model: AppModel
    @State private var connected = false
    @State private var codexConnected = false
    @State private var copied: String?

    var body: some View {
        SettingsLine(
            title: "Claude Desktop",
            detail: connected
                ? "Collegato: riavvia Claude se è aperto, poi chiedigli delle tue riunioni."
                : "Claude legge riunioni, lezioni, azioni e trascrizioni da questo Mac. Non può modificarle.",
            icon: SettingsIcon(symbol: "sparkles")
        ) {
            Button(localized(connected ? "Scollega" : "Collega")) {
                toggleClaudeDesktop()
            }
            .buttonStyle(CompactButtonStyle())
        }
        SettingsDivider()
        SettingsLine(
            title: "Claude Code",
            detail: "Copia il comando e incollalo nel Terminale.",
            icon: SettingsIcon(symbol: "terminal")
        ) {
            copyButton(id: "code") { MCPClientSetup.claudeCodeCommand(cli: model.cli) }
        }
        SettingsDivider()
        SettingsLine(
            title: "Codex",
            detail: codexConnected
                ? "Collegato: riavvia Codex se è aperto, poi chiedigli delle tue riunioni."
                : "Codex legge riunioni, lezioni, azioni e trascrizioni da questo Mac. Non può modificarle.",
            icon: SettingsIcon(symbol: "chevron.left.forwardslash.chevron.right")
        ) {
            Button(localized(codexConnected ? "Scollega" : "Collega")) {
                toggleCodex()
            }
            .buttonStyle(CompactButtonStyle())
        }
        SettingsDivider()
        SettingsLine(
            title: "Altre app MCP",
            detail: "Per Cursor, VS Code, LM Studio e le altre app che usano MCP: incolla la configurazione nelle loro impostazioni.",
            icon: SettingsIcon(symbol: "puzzlepiece.extension")
        ) {
            copyButton(id: "json") { MCPClientSetup.snippet(cli: model.cli) }
        }
        .onAppear {
            connected = MCPClientSetup.isConnectedToClaudeDesktop(cli: model.cli)
            codexConnected = MCPClientSetup.isConnectedToCodex(cli: model.cli)
        }
    }

    private func copyButton(id: String, text: @escaping () -> String) -> some View {
        Button(localized(copied == id ? "Copiato" : "Copia")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if copied == id { copied = nil }
            }
        }
        .buttonStyle(CompactButtonStyle())
    }

    private func toggleClaudeDesktop() {
        if MCPClientSetup.configUnreadable() {
            model.statusMessage = localized("Il file di configurazione di Claude non è JSON valido: correggilo o usa Copia per le altre app.")
            return
        }
        do {
            try MCPClientSetup.setClaudeDesktop(connected: !connected, cli: model.cli)
            connected.toggle()
            model.statusMessage = localized(connected ? "Meeting Pilot collegato a Claude Desktop" : "Meeting Pilot scollegato da Claude Desktop")
        } catch {
            AppLog.append("Configurazione di Claude Desktop non riuscita: \(error.localizedDescription)")
            model.statusMessage = localized("Configurazione di Claude Desktop non riuscita") + ": " + error.localizedDescription
        }
    }

    private func toggleCodex() {
        do {
            try MCPClientSetup.setCodex(connected: !codexConnected, cli: model.cli)
            codexConnected.toggle()
            model.statusMessage = localized(codexConnected ? "Meeting Pilot collegato a Codex" : "Meeting Pilot scollegato da Codex")
        } catch {
            AppLog.append("Configurazione di Codex non riuscita: \(error.localizedDescription)")
            model.statusMessage = localized("Configurazione di Codex non riuscita") + ": " + error.localizedDescription
        }
    }
}
