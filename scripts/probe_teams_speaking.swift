// Probe: does the new Microsoft Teams expose "who is speaking" through Accessibility?
//
// Run it DURING a live Teams call while other people talk (gallery view, captions optional):
//   swift scripts/probe_teams_speaking.swift [seconds] [output_dir]
//
// It snapshots the Teams accessibility tree once per second, then reports:
//   1. nodes mentioning speaking/mic/caption keywords
//   2. attributes that changed between snapshots (a speaking indicator should toggle)
// The raw snapshots are kept in output_dir for further analysis.
// The terminal running it needs Accessibility permission (Privacy & Security).

import AppKit
import ApplicationServices
import Foundation

let duration = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 60 : 60
let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : FileManager.default.currentDirectoryPath + "/teams_probe_\(stamp)")

let keywords = [
    "speak", "talk", "parla", "voice", "voce", "mic", "mute", "audio",
    "caption", "sottotitol", "didascal", "active", "attiv", "raised", "hand",
]
let attributes = [
    "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription",
    "AXValue", "AXHelp", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList",
]

guard AXIsProcessTrusted() else {
    print("⚠️  Questo terminale non ha il permesso Accessibilità (Impostazioni → Privacy e sicurezza → Accessibilità).")
    exit(1)
}
guard let teams = NSWorkspace.shared.runningApplications.first(where: {
    ["com.microsoft.teams2", "com.microsoft.teams"].contains($0.bundleIdentifier ?? "")
}) else {
    print("⚠️  Microsoft Teams non è in esecuzione.")
    exit(1)
}

let app = AXUIElementCreateApplication(teams.processIdentifier)
// Chromium/WebView content only builds its accessibility tree when an assistive client asks for it.
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 2)

func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
    if let text = raw as? String { return text.isEmpty ? nil : text }
    if let list = raw as? [String] { return list.isEmpty ? nil : list.joined(separator: " ") }
    if let number = raw as? NSNumber { return number.stringValue }
    return nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success else { return [] }
    return raw as? [AXUIElement] ?? []
}

typealias Node = [String: String]

func snapshot() -> [String: Node] {
    var nodes: [String: Node] = [:]
    func walk(_ element: AXUIElement, path: String, depth: Int) {
        guard depth < 80, nodes.count < 40_000 else { return }
        var node: Node = [:]
        for attribute in attributes {
            if let value = stringValue(element, attribute) { node[attribute] = value }
        }
        // Prefer the DOM id so the same tile is matched across snapshots even if siblings move.
        let key = node["AXDOMIdentifier"].map { "#\($0)" } ?? path
        nodes[key] = node
        for (index, child) in children(element).enumerated() {
            walk(child, path: "\(path)/\(index)", depth: depth + 1)
        }
    }
    walk(app, path: "app", depth: 0)
    return nodes
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
print("Teams pid \(teams.processIdentifier) — campiono per \(duration)s in \(outputDir.path)")
print("Tieni la call visibile e lascia parlare persone diverse.\n")

var snapshots: [(time: Double, nodes: [String: Node])] = []
let start = Date()
for second in 0..<duration {
    let tick = Date()
    let nodes = snapshot()
    let elapsed = tick.timeIntervalSince(start)
    snapshots.append((elapsed, nodes))
    let data = try JSONSerialization.data(withJSONObject: ["t": elapsed, "nodes": nodes], options: [.sortedKeys])
    try data.write(to: outputDir.appendingPathComponent(String(format: "snap_%03d.json", second)))
    print(String(format: "  t=%5.1fs  nodi=%5d  (%.2fs)", elapsed, nodes.count, Date().timeIntervalSince(tick)))
    let wait = 1 - Date().timeIntervalSince(tick)
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
}

// 1. Keyword hits
var report = "# Teams speaking probe — \(stamp)\n\n## Nodi con parole chiave\n"
var hits: [String: Set<String>] = [:]
for (_, nodes) in snapshots {
    for (key, node) in nodes {
        let text = node.filter { $0.key != "AXRole" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " | ")
        if keywords.contains(where: { text.lowercased().contains($0) }) {
            hits[key, default: []].insert(text)
        }
    }
}
for key in hits.keys.sorted() {
    report += "\n\(key)\n" + hits[key]!.sorted().map { "   \($0)" }.joined(separator: "\n") + "\n"
}

// 2. Attributes that toggled over time
report += "\n## Attributi che cambiano nel tempo\n"
let allKeys = Set(snapshots.flatMap { $0.nodes.keys })
for key in allKeys.sorted() {
    var changes: [String] = []
    for attribute in attributes where attribute != "AXRole" {
        var timeline: [String] = []
        var last: String?? = .none
        for (time, nodes) in snapshots {
            let value = nodes[key]?[attribute]
            if last == nil || last! != value {
                timeline.append(String(format: "%.0fs:", time) + (value ?? "∅"))
                last = .some(value)
            }
        }
        if timeline.count > 1 { changes.append("   \(attribute): " + timeline.joined(separator: "  →  ")) }
    }
    if !changes.isEmpty {
        let role = snapshots.lazy.compactMap { $0.nodes[key]?["AXRole"] }.first ?? "?"
        report += "\n\(key) [\(role)]\n" + changes.joined(separator: "\n") + "\n"
    }
}

let reportURL = outputDir.appendingPathComponent("report.txt")
try report.write(to: reportURL, atomically: true, encoding: .utf8)
print("\n✅ Fatto. Report: \(reportURL.path)")
print("   Nodi con parole chiave: \(hits.count)")
