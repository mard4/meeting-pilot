import Foundation

/// The bundled Python CLI, shared by the watcher and the one-shot commands (chat, retries, Teams scrape).
struct MeetingPilotCLI {
    let envURL: URL
    let projectRoot: URL

    var path: String {
        Bundle.main.resourceURL?
            .appendingPathComponent("MeetingPilotCLI/MeetingPilotCLI")
            .path
        ?? projectRoot.appendingPathComponent(".venv311/bin/meeting-pilot").path
    }

    /// Runs a Meeting Pilot CLI command. Call off the main thread.
    func run(_ arguments: [String], standardInput: String? = nil, environment: [String: String] = [:]) -> String {
        Shell.run(path, arguments, standardInput: standardInput, environment: self.environment(environment))
    }

    /// Keychain secrets travel in the environment, never in argv where `ps` shows them.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = EnvFile.secretEnvironment()
        environment["MEETING_PILOT_ENV_FILE"] = envURL.path
        if let certificate = Bundle.main.resourceURL?
            .appendingPathComponent("MeetingPilotCLI/_internal/certifi/cacert.pem").path {
            environment["SSL_CERT_FILE"] = certificate
        }
        // Apps launched from Finder get a bare PATH; the login shell used to add these.
        // They go last: Homebrew's folders are writable by the user, so a planted
        // `osascript` there must not shadow the system one.
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(inherited):/opt/homebrew/bin:/usr/local/bin"
        environment.merge(Self.bundledHelperEnvironment) { $1 }
        return environment.merging(extra) { $1 }
    }

    /// The helpers shipped inside the app. The CLI reads `.env` without overriding the
    /// environment, so these win over any path written there: whatever the CLI starts
    /// runs with this app's privacy permissions, and `.env` is writable by any process.
    static var bundledHelperEnvironment: [String: String] {
        let helpers = Bundle.main.executableURL?.deletingLastPathComponent()
        let resources = Bundle.main.resourceURL
        let commands: [String: URL?] = [
            "APPLE_TRANSCRIBER_CMD": helpers?.appendingPathComponent("AppleTranscriber"),
            "APPLE_INTELLIGENCE_SUMMARIZER_CMD": helpers?.appendingPathComponent("AppleIntelligenceSummarizer"),
            "MEETING_PILOT_OCR_COMMAND": helpers?.appendingPathComponent("TeamsOCR"),
            "MEETING_PILOT_TEAMS_WINDOW_COMMAND": helpers?.appendingPathComponent("TeamsWindowID"),
            "FLUID_AUDIO_CMD": resources?.appendingPathComponent("FluidAudio/bin/fluidaudiocli"),
            "LLAMA_SERVER_CMD": resources?.appendingPathComponent("LlamaCpp/bin/llama-server"),
        ]
        return commands.reduce(into: [:]) { environment, entry in
            if let path = entry.value?.path, FileManager.default.isExecutableFile(atPath: path) {
                environment[entry.key] = path
            }
        }
    }

    static var teamsHelperEnvironment: [String: String] {
        let helpers = Bundle.main.executableURL?.deletingLastPathComponent()
        return [
            "MEETING_PILOT_OCR_COMMAND": helpers?.appendingPathComponent("TeamsOCR").path ?? "",
            "MEETING_PILOT_TEAMS_WINDOW_COMMAND": helpers?.appendingPathComponent("TeamsWindowID").path ?? "",
        ]
    }
}
