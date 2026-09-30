import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import FoundationModels
import Speech
import ServiceManagement
import SwiftUI
import UserNotifications


func meetingDisplayTitle(_ value: String) -> String {
    let emailPattern = #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#
    let datePattern = #"(?i)\b(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}\s+(?:gen|feb|mar|apr|mag|giu|lug|ago|set|ott|nov|dic)[a-z]*\s+\d{4})(?:[ T,]+\d{1,2}[:.-]\d{2}(?:[:.-]\d{2})?)?\b"#
    let compactTimestampPattern = #"\b\d{8}[-_]\d{6}\b"#
    let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|-–—"))

    var cleaned = value
        .replacingOccurrences(of: emailPattern, with: "", options: .regularExpression)
        .replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        .replacingOccurrences(of: compactTimestampPattern, with: "", options: .regularExpression)

    cleaned = cleaned
        .components(separatedBy: "|")
        .map { $0.trimmingCharacters(in: trimCharacters) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
        .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s*[-–—]\s*(?:[-–—]\s*)+"#, with: " - ", options: .regularExpression)
        .trimmingCharacters(in: trimCharacters)

    return cleaned.isEmpty ? "Riunione senza titolo" : cleaned
}

func loadRecentMeetings(from url: URL) -> [MeetingItem] {
    let sessions = ((try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        .prefix(30)

    return sessions.map { session in
        let sessionDate = (try? session.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let metadata = readJSON(session.appendingPathComponent("meeting_metadata.json"))
        let summary = readJSON(session.appendingPathComponent("omlx_summary.json"))
        let notionReceipt = readJSON(session.appendingPathComponent("notion_receipt.json"))
        let journalReceipt = readJSON(session.appendingPathComponent("journal_receipt.json"))
        let obsidianReceipt = readJSON(session.appendingPathComponent("obsidian_receipt.json"))
        let appleNotesReceipt = readJSON(session.appendingPathComponent("apple_notes_receipt.json"))
        let publicationSnapshot = readJSON(session.appendingPathComponent("publication_targets.json"))
        let projectInfo = readJSON(session.appendingPathComponent("meeting_project.json"))
        let themeInfo = readJSON(session.appendingPathComponent("meeting_theme.json"))
        let title = (metadata["title"] as? String) ?? (summary["title"] as? String) ?? session.lastPathComponent
        let speakers = speakerCount(in: session)
        let subtitle = speakers > 0 ? "\(speakers) speaker" : session.lastPathComponent
        let meetingDate = meetingDate(metadata: metadata, summary: summary, fallback: sessionDate)
        let dateText = meetingDateText(meetingDate)
        let publicationTargets = meetingPublicationTargets(
            notionReceipt: notionReceipt,
            journalReceipt: journalReceipt,
            obsidianReceipt: obsidianReceipt,
            appleNotesReceipt: appleNotesReceipt,
            configuredTargets: publicationSnapshot["targets"] as? [String] ?? []
        )
        let project = (projectInfo["project"] as? String)
            ?? (notionReceipt["meeting_pilot_project"] as? String)
            ?? (metadata["project"] as? String)
        let theme = (themeInfo["theme"] as? String)
            ?? (notionReceipt["meeting_pilot_theme"] as? String)
            ?? (metadata["theme"] as? String)
        let themes = ((themeInfo["themes"] as? [String])
            ?? (notionReceipt["meeting_pilot_themes"] as? [String])
            ?? (metadata["themes"] as? [String])
            ?? (theme.map { [$0] } ?? []))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return MeetingItem(
            id: session.path,
            title: meetingDisplayTitle(title),
            subtitle: subtitle,
            dateText: dateText,
            date: meetingDate,
            publicationTargets: publicationTargets,
            project: project,
            theme: theme,
            themes: themes
        )
    }
    .sorted { left, right in
        (left.date ?? .distantPast) > (right.date ?? .distantPast)
    }
}

func meetingPublicationTargets(
    notionReceipt: [String: Any],
    journalReceipt: [String: Any],
    obsidianReceipt: [String: Any],
    appleNotesReceipt: [String: Any],
    configuredTargets: [String]
) -> [MeetingPublicationTarget] {
    var targets: [MeetingPublicationTarget] = []

    if let rawPath = journalReceipt["path"] as? String,
       !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        targets.append(MeetingPublicationTarget(service: .journal, actionURL: URL(fileURLWithPath: rawPath)))
    }

    if let rawURL = notionReceipt["url"] as? String,
       let url = URL(string: rawURL) {
        targets.append(MeetingPublicationTarget(service: .notion, actionURL: url))
    }

    if let rawPath = obsidianReceipt["path"] as? String,
       !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        targets.append(MeetingPublicationTarget(service: .obsidian, actionURL: URL(fileURLWithPath: rawPath)))
    }

    if !appleNotesReceipt.isEmpty {
        let primary = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let fallback = URL(fileURLWithPath: "/Applications/Notes.app")
        let notesURL = FileManager.default.fileExists(atPath: primary.path) ? primary : fallback
        targets.append(MeetingPublicationTarget(service: .appleNotes, actionURL: notesURL))
    }

    let services = Set(targets.map(\.service))
    for rawTarget in configuredTargets {
        let service: MeetingPublicationService?
        switch rawTarget {
        case "journal": service = .journal
        case "notion": service = .notion
        case "obsidian": service = .obsidian
        case "apple_notes": service = .appleNotes
        default: service = nil
        }
        if let service, !services.contains(service) {
            targets.append(MeetingPublicationTarget(service: service, actionURL: nil))
        }
    }

    return targets
}

func meetingPublicationLabel(for service: MeetingPublicationService) -> String {
    switch service {
    case .journal:
        return "Apri nel Diario"
    case .notion:
        return "Apri in Notion"
    case .obsidian:
        return "Apri in Obsidian"
    case .appleNotes:
        return "Apri Apple Notes"
    }
}

func meetingDate(metadata: [String: Any], summary: [String: Any], fallback: Date?) -> Date? {
    let raw = (metadata["start"] as? String)
        ?? (metadata["recording_start"] as? String)
        ?? (summary["date"] as? String)
    return raw.flatMap(parseFlexibleDate) ?? fallback
}

func meetingDateText(_ date: Date?) -> String {
    guard let date else { return localized("Data non disponibile") }
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.setLocalizedDateFormatFromTemplate("ddMMMyyyyHHmm")
    return formatter.string(from: date)
}

func parseFlexibleDate(_ value: String) -> Date? {
    let text = value.replacingOccurrences(of: "Z", with: "")
    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd"
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: text) {
            return date
        }
    }
    return nil
}

func readJSON(_ url: URL) -> [String: Any] {
    guard
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
}

func speakerCount(in session: URL) -> Int {
    let files = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" && !file.lastPathComponent.contains("summary") && !file.lastPathComponent.contains("receipt") {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        if let speakers = object["speakers"] as? [[String: Any]], !speakers.isEmpty {
            return speakers.count
        }
        if let count = object["speakerCount"] as? Int, count > 0 {
            return count
        }
    }
    return 0
}
