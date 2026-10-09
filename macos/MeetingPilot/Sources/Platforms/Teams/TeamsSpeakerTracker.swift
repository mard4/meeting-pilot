import AppKit
import ApplicationServices
import Foundation

/// Records who is talking in the Teams call while the meeting is being recorded, so the
/// pipeline can put real names on FluidAudio's anonymous speaker clusters.
///
/// New Teams is a Chromium web view: each remote participant's tile is an `AXMenuItem`
/// titled "<Name>, <context menu hint>", with the name (which may itself contain a comma,
/// as in "Rossi, Mario") also shown as a text label inside it. While that person talks, a
/// direct child group gains the `vdi-frame-occlusion` DOM class (the coloured speaking
/// border). The user's own preview has no such border; their voice is already identified
/// from the microphone track.
/// Times are seconds of recorded audio (pauses excluded), written to the sidecar as
/// `teams_speakers.json` — a contract with `speaker_names.py`. The live sidebar asks
/// `dominantSpeaker(from:to:)` in system-uptime seconds instead, so it can name lines
/// while the meeting is still going.
final class TeamsSpeakerTracker {
    private static let teamsBundleIDs: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]
    private static let speakingClass = "vdi-frame-occlusion"
    private static let pollInterval: DispatchTimeInterval = .milliseconds(300)
    /// Tiles appear, move and disappear as people join or the layout changes.
    private static let rescanInterval: TimeInterval = 3
    /// Nodes walked per window when looking for tiles. Per window rather than for the
    /// whole app: the main Teams window (chats, activity) can use up a shared budget
    /// before the walk ever reaches a separate meeting window.
    private static let scanBudgetPerWindow = 6_000
    /// How long Teams may run with no tile found before the log says so.
    private static let noTilesReportSeconds: TimeInterval = 20

    private let outputURL: URL
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).teams-speakers", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var teamsPID: pid_t?
    private var tileContainers: [AXUIElement] = []
    /// Tile title → participant name, so the labels inside a tile are read once per rescan
    /// rather than on every poll. Cleared on rescan, as labels can appear after the tile.
    private var tileNames: [String: String?] = [:]
    private var lastScan: TimeInterval = 0
    private var recordedBeforePause: TimeInterval = 0
    private var activeSince: TimeInterval?
    private var talkingSince: [String: TimeInterval] = [:]
    private var segments: [(name: String, start: TimeInterval, end: TimeInterval)] = []
    /// The same turns on the uptime clock, kept only as long as the sidebar can ask about them.
    private var liveTalkingSince: [String: TimeInterval] = [:]
    private var liveTurns: [(name: String, start: TimeInterval, end: TimeInterval)] = []
    private static let liveHistorySeconds: TimeInterval = 120
    /// What has been logged, so each condition is reported once per recording: a failure
    /// here used to leave no trace, so a sidebar without names couldn't be told apart
    /// from a call nobody spoke in.
    private var reported: Set<String> = []
    private var teamsSeenSince: TimeInterval?
    private var lastScanSummary = ""

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() {
        activeSince = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func pause() {
        queue.async {
            guard let activeSince = self.activeSince else { return }
            let now = self.recordedTime()
            self.closeAll(at: now)
            self.recordedBeforePause += ProcessInfo.processInfo.systemUptime - activeSince
            self.activeSince = nil
        }
    }

    func resume() {
        queue.async {
            guard self.activeSince == nil else { return }
            self.activeSince = ProcessInfo.processInfo.systemUptime
        }
    }

    /// Stops polling and writes what was seen. Synchronous, so the file exists before the
    /// recording's lock is removed and the watcher moves the sidecar away.
    func finish() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if activeSince != nil {
                closeAll(at: recordedTime())
                activeSince = nil
            }
            write()
            if teamsSeenSince != nil {
                let names = Set(segments.map { $0.name }).sorted()
                AppLog.append(names.isEmpty
                    ? "Speaker Teams: nessuno visto parlare durante la registrazione"
                    : "Speaker Teams: \(segments.count) turni di \(names.joined(separator: ", "))")
            }
        }
    }

    /// The participant whose speaking border overlapped `[start, end]` (system uptime) the
    /// longest, or nil when nobody's did. Thread-safe.
    func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> String? {
        queue.sync {
            let now = ProcessInfo.processInfo.systemUptime
            let ongoing = liveTalkingSince.map { (name: $0.key, start: $0.value, end: now) }
            var overlap: [String: TimeInterval] = [:]
            for turn in liveTurns + ongoing {
                let shared = min(end, turn.end) - max(start, turn.start)
                if shared > 0 { overlap[turn.name, default: 0] += shared }
            }
            return overlap.max { $0.value < $1.value }?.key
        }
    }

    private func recordedTime() -> TimeInterval {
        recordedBeforePause + (activeSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }

    private func poll() {
        guard activeSince != nil else { return }
        guard AXIsProcessTrusted() else {
            reportOnce("ax", "Speaker Teams non disponibili: manca il permesso Accessibilità")
            return
        }
        guard let teams = NSWorkspace.shared.runningApplications.first(where: {
            Self.teamsBundleIDs.contains($0.bundleIdentifier ?? "")
        }) else {
            closeAll(at: recordedTime())
            teamsPID = nil
            return
        }
        let app = AXUIElementCreateApplication(teams.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if teamsPID != teams.processIdentifier {
            // Chromium only builds the web content's accessibility tree for clients that ask.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            teamsPID = teams.processIdentifier
            tileContainers = []
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if teamsSeenSince == nil { teamsSeenSince = uptime }
        // Also paced while nothing is found: each scan walks every Teams window.
        if uptime - lastScan >= Self.rescanInterval {
            tileNames = [:]
            tileContainers = findTileContainers(in: app)
            lastScan = uptime
            if tileContainers.isEmpty, let since = teamsSeenSince, uptime - since >= Self.noTilesReportSeconds {
                reportOnce("tiles", "Speaker Teams: nessun riquadro partecipante trovato (\(lastScanSummary))")
            } else if !tileContainers.isEmpty {
                reportOnce("found", "Speaker Teams: riquadri partecipanti trovati (\(lastScanSummary))")
            }
        }

        var talking = Set<String>()
        for container in tileContainers {
            for tile in children(of: container) {
                guard let name = tileName(tile) else { continue }
                if children(of: tile).contains(where: { hasSpeakingBorder($0) }) {
                    talking.insert(name)
                }
            }
        }

        if !talking.isEmpty {
            reportOnce("talking", "Speaker Teams: primo bordo \"sta parlando\" visto")
        }
        let now = recordedTime()
        for name in talking where talkingSince[name] == nil {
            talkingSince[name] = now
            liveTalkingSince[name] = uptime
        }
        for (name, start) in talkingSince where !talking.contains(name) {
            segments.append((name, start, now))
            talkingSince[name] = nil
            if let liveStart = liveTalkingSince.removeValue(forKey: name) {
                liveTurns.append((name, liveStart, uptime))
            }
        }
        liveTurns.removeAll { uptime - $0.end > Self.liveHistorySeconds }
    }

    private func closeAll(at time: TimeInterval) {
        for (name, start) in talkingSince {
            segments.append((name, start, time))
        }
        talkingSince = [:]
        let uptime = ProcessInfo.processInfo.systemUptime
        for (name, start) in liveTalkingSince {
            liveTurns.append((name, start, uptime))
        }
        liveTalkingSince = [:]
    }

    /// Parents of the participant tiles. A tile is confirmed by its name also appearing as a
    /// text label inside it (see `tileName`), which keeps other context-menu items (chat,
    /// roster) out and doesn't depend on the Teams UI language. Windows are walked one at a
    /// time, the meeting window first, each with its own node budget, and the walk stops at
    /// the first window holding tiles.
    private func findTileContainers(in app: AXUIElement) -> [AXUIElement] {
        let windows = elements(app, kAXWindowsAttribute)
        let titled = windows.map { (window: $0, title: string($0, kAXTitleAttribute) ?? "") }
        let ordered = titled.filter { looksLikeTeamsMeetingTitle($0.title) }
            + titled.filter { !looksLikeTeamsMeetingTitle($0.title) }
        var summary: [String] = []
        for (window, title) in ordered {
            let (containers, visited) = findTileContainers(under: window)
            summary.append("\"\(title)\": \(visited) elementi, \(containers.count) gruppi di riquadri")
            if !containers.isEmpty {
                lastScanSummary = summary.joined(separator: "; ")
                return containers
            }
        }
        // No window list (seen while Teams starts up): fall back to the app's own children.
        if windows.isEmpty {
            let (containers, visited) = findTileContainers(under: app)
            summary.append("nessuna finestra, \(visited) elementi dall'app")
            lastScanSummary = summary.joined(separator: "; ")
            return containers
        }
        lastScanSummary = summary.joined(separator: "; ")
        return []
    }

    private func findTileContainers(under root: AXUIElement) -> (containers: [AXUIElement], visited: Int) {
        var containers: [AXUIElement] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 60, visited < Self.scanBudgetPerWindow else { return }
            visited += 1
            let role = string(element, kAXRoleAttribute)
            if role == kAXMenuBarRole || role == kAXMenuRole { return }
            if role == kAXMenuItemRole, tileName(element) != nil {
                if let parent = parent(of: element), !containers.contains(where: { CFEqual($0, parent) }) {
                    containers.append(parent)
                }
                return
            }
            for child in children(of: element) {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return (containers, visited)
    }

    private func reportOnce(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        AppLog.append(message)
    }

    private func tileName(_ element: AXUIElement) -> String? {
        guard string(element, kAXRoleAttribute) == kAXMenuItemRole,
              let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
        else { return nil }
        if let cached = tileNames[title] { return cached }
        let name = Self.participantName(title: title, labels: texts(in: element, depth: 0))
        tileNames.updateValue(name, forKey: title)
        return name
    }

    /// The tile label the title starts with, followed by its comma. Cutting the title at the
    /// first comma instead turned "Rossi, Mario" into "Rossi", which then matched no label,
    /// so such participants were never tracked. The longest label wins, so "Rossi, Mario"
    /// beats a stray "Rossi".
    static func participantName(title: String, labels: [String]) -> String? {
        let title = normalizedName(title)
        return labels
            .map(normalizedName)
            .filter { !$0.isEmpty && title.hasPrefix($0 + ",") }
            .max { $0.count < $1.count }
    }

    private func texts(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 10 else { return [] }
        var found: [String] = []
        for child in children(of: element) {
            if string(child, kAXRoleAttribute) == kAXStaticTextRole, let value = string(child, kAXValueAttribute) {
                found.append(value)
            }
            found += texts(in: child, depth: depth + 1)
        }
        return found
    }

    private func hasSpeakingBorder(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &raw) == .success,
              let classes = raw as? [String]
        else { return false }
        return classes.contains(Self.speakingClass)
    }

    private func write() {
        guard !segments.isEmpty else { return }
        let payload: [String: Any] = [
            "source": "teams_accessibility",
            "segments": segments.sorted { $0.start < $1.start }.map {
                ["name": $0.name, "start": rounded($0.start), "end": rounded($0.end)]
            },
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
        } catch {
            AppLog.append("Speaker Teams non salvati: \(error.localizedDescription)")
        }
    }

    private func rounded(_ value: TimeInterval) -> Double {
        (value * 100).rounded() / 100
    }

    private static func normalizedName(_ value: String) -> String {
        value.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let text = raw as? String, !text.isEmpty
        else { return nil }
        return text
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }
}
