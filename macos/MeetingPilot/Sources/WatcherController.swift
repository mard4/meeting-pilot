import Foundation

/// Owns the long-running `transcribe-to-notion watch` process.
final class WatcherController: ObservableObject {
    @Published var watcherActive = false

    private let cli: MeetingPilotCLI
    /// Pkill/pgrep and process launches stay off the main thread; serial so a restart
    /// can't interleave with a stop.
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).watcher")
    private var process: Process?

    init(cli: MeetingPilotCLI) {
        self.cli = cli
    }

    /// Completion runs on the main thread with whether the watcher is running afterwards.
    func start(completion: @escaping (Bool) -> Void) {
        queue.async {
            self.launchProcess()
            let running = isWatcherProcessRunning()
            DispatchQueue.main.async { completion(running) }
        }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async {
            stopWatcherProcesses()
            DispatchQueue.main.async { completion() }
        }
    }

    /// The watcher reads .env only at startup, so settings changes need a restart to apply.
    func restartIfRunning(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let running = isWatcherProcessRunning()
            if running {
                stopWatcherProcesses()
                self.launchProcess()
            }
            DispatchQueue.main.async { completion?(running) }
        }
    }

    func whenNotRunning(_ action: @escaping () -> Void) {
        queue.async {
            guard !isWatcherProcessRunning() else { return }
            DispatchQueue.main.async { action() }
        }
    }

    func refreshRunningState() {
        queue.async {
            let running = isWatcherProcessRunning()
            DispatchQueue.main.async { self.watcherActive = running }
        }
    }

    /// Call on `queue`.
    private func launchProcess() {
        do {
            process = try Shell.launch(
                cli.path,
                ["watch"],
                environment: cli.environment(["PYTHONUNBUFFERED": "1"]),
                standardOutput: AppLog.directory.appendingPathComponent("transcribe-to-notion.log"),
                standardError: AppLog.directory.appendingPathComponent("transcribe-to-notion.err.log")
            )
        } catch {
            AppLog.append("Avvio watcher non riuscito: \(error.localizedDescription)")
        }
    }
}
