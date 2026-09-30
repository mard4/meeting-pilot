import Foundation

/// The bundled Python CLI, shared by the watcher and the one-shot commands (chat, retries, Teams scrape).
struct MeetingPilotCLI {
    let envURL: URL
    let projectRoot: URL

    var path: String {
        Bundle.main.resourceURL?
            .appendingPathComponent("MeetingPilotCLI/MeetingPilotCLI")
            .path
        ?? projectRoot.appendingPathComponent(".venv311/bin/transcribe-to-notion").path
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
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(inherited)"
        return environment.merging(extra) { $1 }
    }

    static var teamsHelperEnvironment: [String: String] {
        let helpers = Bundle.main.executableURL?.deletingLastPathComponent()
        return [
            "MEETING_PILOT_OCR_COMMAND": helpers?.appendingPathComponent("TeamsOCR").path ?? "",
            "MEETING_PILOT_TEAMS_WINDOW_COMMAND": helpers?.appendingPathComponent("TeamsWindowID").path ?? "",
        ]
    }
}
