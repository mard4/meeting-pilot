import Foundation

@main
struct ThemeTests {
    static func main() {
        expect(MeetingPilotTheme(rawValue: "dark") == .dark, "dark theme is supported")
        expect(MeetingPilotTheme(rawValue: "light") == .light, "light theme is supported")
        expect(MeetingPilotTheme(rawValue: "unknown") == nil, "unknown themes are rejected")
        expect(MeetingPilotTheme(rawValue: nil) == nil, "missing themes are rejected")
        print("theme tests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
