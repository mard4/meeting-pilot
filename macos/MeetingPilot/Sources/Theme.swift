import Foundation

enum MeetingPilotTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    init?(rawValue: String?) {
        guard let rawValue, let theme = Self(rawValue: rawValue) else { return nil }
        self = theme
    }
}
