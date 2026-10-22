import AppKit
import SwiftUI

/// Connects Claude and other MCP clients to the meetings: they start the bundled CLI as
/// `MeetingPilotCLI mcp`, which only reads. Claude Desktop is set up by writing its
/// config file; the others get a command or a snippet to paste.
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

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The rows of the "Claude and other AI apps" group in Settings.
struct MCPClientRows: View {
    @EnvironmentObject private var model: AppModel
    @State private var connected = false
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
            title: "Altre app MCP",
            detail: "Per Cursor, VS Code, LM Studio e le altre app che usano MCP: incolla la configurazione nelle loro impostazioni.",
            icon: SettingsIcon(symbol: "puzzlepiece.extension")
        ) {
            copyButton(id: "json") { MCPClientSetup.snippet(cli: model.cli) }
        }
        .onAppear { connected = MCPClientSetup.isConnectedToClaudeDesktop(cli: model.cli) }
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
}
