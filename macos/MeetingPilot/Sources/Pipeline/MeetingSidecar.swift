import Foundation

/// Per-recording folder written next to the audio in the inbox
/// (`<recording>.meetingpilot/`). The Python pipeline moves it into the processing
/// session as `sidecar/` (see `millet_runner.sidecar_dir`), so these file names are a
/// contract with that side.
enum MeetingSidecar {
    static func directory(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("meetingpilot")
    }

    static func notesURL(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("notes.md")
    }

    static func templateURL(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("template.json")
    }

    static func liveStateURL(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("live_state.json")
    }

    /// `me.m4a` (microphone) and `them.m4a` (system audio), transcribed separately so the
    /// person recording gets their own speaker label.
    static func tracksDirectory(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("tracks", isDirectory: true)
    }

    /// Who was talking in the Teams call and when, written by `TeamsSpeakerTracker`.
    static func teamsSpeakersURL(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("teams_speakers.json")
    }

    /// `{"audio_source": "microphone" | "system" | "both", "call": Bool}`. The pipeline
    /// only applies Teams metadata to recordings that were calls.
    static func recordingInfoURL(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("recording.json")
    }

    static func writeRecordingInfo(source: RecordingAudioSource, isCall: Bool, for audioURL: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["audio_source": source.rawValue, "call": isCall])
            try data.write(to: recordingInfoURL(for: audioURL), options: .atomic)
        } catch {
            AppLog.append("Salvataggio informazioni registrazione non riuscito: \(error.localizedDescription)")
        }
    }

    /// `{"profile": "worker" | "student"}`, chosen in the live sidebar; absent means the
    /// pipeline decides from the title (see `profiles.py`).
    static func profileURL(for audioURL: URL) -> URL {
        directory(for: audioURL).appendingPathComponent("profile.json")
    }

    static func readProfileChoice(for audioURL: URL) -> UserProfile? {
        guard let data = try? Data(contentsOf: profileURL(for: audioURL)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = payload["profile"] as? String
        else { return nil }
        return UserProfile(rawValue: choice).flatMap { $0 == .both ? nil : $0 }
    }

    static func writeProfileChoice(_ choice: UserProfile?, for audioURL: URL) {
        let url = profileURL(for: audioURL)
        guard let choice else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["profile": choice.rawValue])
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.append("Salvataggio tipo di nota non riuscito: \(error.localizedDescription)")
        }
    }

    static func readTemplateChoice(for audioURL: URL) -> String {
        guard let data = try? Data(contentsOf: templateURL(for: audioURL)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = payload["template"] as? String
        else { return SummaryTemplateCatalog.auto }
        return choice
    }

    static func writeTemplateChoice(_ choice: String, for audioURL: URL) {
        // No createDirectory: the recorder creates the folder at start, and once the
        // pipeline has moved it into a session, recreating it would leave an orphan.
        let url = templateURL(for: audioURL)
        do {
            let data = try JSONSerialization.data(withJSONObject: ["template": choice])
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.append("Salvataggio modello di sintesi non riuscito: \(error.localizedDescription)")
        }
    }
}

struct SummaryTemplateOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A user-defined template, stored in `summary-templates.json` next to `.env` and read by
/// `summary_templates.custom_templates()` in the pipeline.
struct CustomSummaryTemplate: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var instructions: String
    var keywords: [String]
}

/// Built-in ids mirror `BUILTIN_TEMPLATES` in `summary_templates.py`; the instructions
/// themselves live only on the Python side.
enum SummaryTemplateCatalog {
    static let auto = "auto"
    static let fileName = "summary-templates.json"

    static var builtIn: [SummaryTemplateOption] {
        [
            SummaryTemplateOption(id: "general", name: localized("Generale")),
            SummaryTemplateOption(id: "one_on_one", name: "1:1"),
            SummaryTemplateOption(id: "standup", name: "Standup"),
            SummaryTemplateOption(id: "client_call", name: localized("Chiamata cliente")),
            SummaryTemplateOption(id: "interview", name: localized("Colloquio")),
            SummaryTemplateOption(id: "project_review", name: localized("Revisione progetto")),
        ]
    }

    /// Automatic first, then the user's own templates, then the built-ins — the same
    /// precedence the pipeline uses when matching titles.
    static func options(custom: [CustomSummaryTemplate]) -> [SummaryTemplateOption] {
        [SummaryTemplateOption(id: auto, name: localized("Automatico"))]
            + custom.map { SummaryTemplateOption(id: $0.id, name: $0.name) }
            + builtIn
    }

    static func name(for id: String, custom: [CustomSummaryTemplate]) -> String {
        options(custom: custom).first { $0.id == id }?.name ?? localized("Automatico")
    }

    static func loadCustom(from url: URL) -> [CustomSummaryTemplate] {
        struct File: Codable { var templates: [CustomSummaryTemplate] }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.templates
    }

    static func saveCustom(_ templates: [CustomSummaryTemplate], to url: URL) throws {
        struct File: Codable { var templates: [CustomSummaryTemplate] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(templates: templates)).write(to: url, options: .atomic)
    }
}
