import AppKit
import SwiftUI

enum MeetingPilotTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    init?(rawValue: String?) {
        guard let rawValue, let theme = Self(rawValue: rawValue) else { return nil }
        self = theme
    }

    var colorScheme: ColorScheme { self == .light ? .light : .dark }

    /// AppKit's own drawing (title bars, menus, switches, windows opened later) follows
    /// the app-wide appearance, not SwiftUI's color scheme.
    var appearance: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
}

/// The in-app theme for root views AppKit hosts (the menu bar popover, the Diary): they
/// are built once, so the theme is read here, where SwiftUI re-renders it on a change.
struct AppThemed<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @ViewBuilder let content: Content

    var body: some View {
        content.preferredColorScheme(model.appTheme.colorScheme)
    }
}
