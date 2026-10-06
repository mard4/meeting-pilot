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


@main
struct MeetingPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        MeetingPilotFonts.register()
    }

    var body: some Scene {
        WindowGroup("Meeting Pilot") {
            // RootView applies the theme; reading it here would not update, as this
            // closure doesn't observe the model.
            RootView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 760, minHeight: 540)
        }
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(localized("Importa registrazioni…")) {
                    appDelegate.importFiles()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(before: .windowList) {
                HideFromScreenSharingCommand()
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button(localized("Come funziona Meeting Pilot")) {
                    appDelegate.showWelcome(initialProfile: appDelegate.model.userProfile)
                }
            }
        }
    }
}

/// Window › Hide Meeting Pilot from Screen Sharing, a checkmark item in step with Settings.
struct HideFromScreenSharingCommand: View {
    @AppStorage(ScreenSharingPrivacy.appHiddenKey) private var hidden = false

    var body: some View {
        Toggle(localized("Nascondi Meeting Pilot nelle condivisioni schermo"), isOn: Binding(
            get: { hidden },
            set: { ScreenSharingPrivacy.setAppHidden($0) }
        ))
        .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}

extension NSImage {
    static func meetingPilotAppIcon() -> NSImage? {
        BrandMarkGeometry.templateImage(pointSize: 18)
    }

    private static let trimmedAssetCache = NSCache<NSString, NSImage>()

    static func trimmedBundledAsset(named name: String) -> NSImage? {
        if let cached = trimmedAssetCache.object(forKey: name as NSString) { return cached }
        guard let trimmed = trimBundledAsset(named: name) else { return nil }
        trimmedAssetCache.setObject(trimmed, forKey: name as NSString)
        return trimmed
    }

    private static func trimBundledAsset(named name: String) -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name),
              let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.hasAlpha,
              let pixels = bitmap.bitmapData
        else {
            return nil
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bytesPerPixel - 1
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let row = pixels.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<width where row[x * bytesPerPixel + alphaOffset] > 4 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return image }
        let padding = 8
        // Bitmap rows run top-down and CGImage cropping uses the same pixel space, so crop
        // there rather than drawing through NSImage (points, bottom-up origin).
        let crop = CGRect(
            x: max(0, minX - padding),
            y: max(0, minY - padding),
            width: min(width, maxX + padding + 1) - max(0, minX - padding),
            height: min(height, maxY + padding + 1) - max(0, minY - padding)
        )
        guard let cropped = bitmap.cgImage?.cropping(to: crop) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: crop.width, height: crop.height))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var diaryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if let directory = DebugSnapshots.outputDirectory {
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.forEach { $0.orderOut(nil) }
            DebugSnapshots.render(model: model, to: directory)
            exit(0)
        }
#endif
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = model.appTheme.appearance
        ScreenSharingPrivacy.install()
        UNUserNotificationCenter.current().delegate = self
        NotificationBridge.configureCategories()
        NotificationBridge.requestAuthorization()
        model.refresh()
        model.startAutoRefresh()
        model.openDiaryWindow = { [weak self] in self?.showDiaryWindow() }
#if DEBUG
        // Marketing recording of the chat: no detection, watcher or permission prompts.
        let demoChat = ProcessInfo.processInfo.environment["MEETING_PILOT_DEMO_CHAT"].map { !$0.isEmpty } ?? false
        if demoChat {
            model.selectedSection = .chat
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showMainWindow()
                if let window = self?.mainWindow, let screen = window.screen ?? NSScreen.main {
                    let size = NSSize(width: 1280, height: 820)
                    let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
                    window.setFrame(NSRect(origin: origin, size: size), display: true)
                }
            }
        }
#else
        let demoChat = false
#endif
        if !demoChat {
            model.recording.startMeetingDetectionMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.model.startInstalledServicesAutomatically()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.welcomeThenPermissions()
            }
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            if let image = NSImage.meetingPilotAppIcon() {
                button.image = image
                button.imagePosition = .imageOnly
            }
            button.toolTip = "Meeting Pilot"
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let overviewView = AppThemed { MenuBarOverview(
            openApp: { [weak self] in
                self?.closePopover()
                self?.showMainWindow()
            },
            openChat: { [weak self] in
                self?.closePopover()
                self?.model.selectedSection = .chat
                self?.showMainWindow()
            },
            openDiary: { [weak self] in
                self?.closePopover()
                self?.showDiaryWindow()
            },
            openImport: { [weak self] in
                self?.closePopover()
                self?.importFiles()
            }
        ) }
            .environmentObject(model)
            .frame(width: 320, height: 330)

        popover.contentSize = NSSize(width: 320, height: 330)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: overviewView)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { model.notion.handleOAuthCallback($0) }
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
    }

    /// The sheet belongs to the main window, so it opens first; the file panel then
    /// appears over it.
    func importFiles() {
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.model.chooseFilesToImport()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionRows()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.recording.nativeRecordingActive else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = localized("Registrazione in corso")
        alert.informativeText = localized("Ferma la registrazione prima di uscire. Chiudere ora interromperebbe l'audio e il file non sarebbe recuperabile.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("Continua a registrare"))
        alert.runModal()
        return .terminateCancel
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showPopover(sender)
            return
        }
        if event.type == .rightMouseUp {
            showMenu()
            return
        }
        popover.isShown ? closePopover() : showPopover(sender)
    }

    private func showPopover(_ sender: NSStatusBarButton) {
        model.refresh()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: localized("Apri Diario"), action: #selector(openDiaryFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Apri Meeting Pilot"), action: #selector(openFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: localized("Avvia registrazione"), action: #selector(testRecordingPrompt), keyEquivalent: ""))
        let pauseRecordingItem = NSMenuItem(
            title: localized(model.recording.nativeRecordingPaused ? "Riprendi registrazione" : "Pausa registrazione"),
            action: #selector(toggleNativeRecordingPause),
            keyEquivalent: ""
        )
        pauseRecordingItem.isEnabled = model.recording.nativeRecordingActive
        menu.addItem(pauseRecordingItem)
        let stopRecordingItem = NSMenuItem(title: localized("Ferma registrazione nativa"), action: #selector(stopNativeRecording), keyEquivalent: "")
        stopRecordingItem.isEnabled = model.recording.nativeRecordingActive
        menu.addItem(stopRecordingItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: localized("Esci"), action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openFromMenu() {
        showMainWindow()
    }

    private func showMainWindow() {
        model.refresh()
        mainWindow = existingMainWindow() ?? mainWindow
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
    }

    private func existingMainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window !== diaryWindow && window.title == "Meeting Pilot"
        }
    }

    @objc private func openDiaryFromMenu() {
        showDiaryWindow()
    }

    private func showDiaryWindow() {
        model.refresh()
        if diaryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meeting Pilot — Diario"
            window.minSize = NSSize(width: 620, height: 480)
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: AppThemed { DiaryNotebookView() }
                    .environmentObject(model)
            )
            diaryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        diaryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func startWatcher() {
        model.startWatcher()
    }

    @objc private func stopWatcher() {
        model.stopWatcher()
    }

    @objc private func stopNativeRecording() {
        model.recording.stopNativeRecording()
    }

    @objc private func toggleNativeRecordingPause() {
        model.recording.toggleNativeRecordingPause()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Until the user has said who it is for (new installs and updates alike), the tour
    /// comes first, then the permission checklist.
    private func welcomeThenPermissions() {
        guard model.needsProfileChoice else {
            showMissingPermissionsIfNeeded()
            return
        }
        showWelcome(initialProfile: nil)
    }

    /// The tour again, from Help, with the saved profile already chosen.
    func showWelcome(initialProfile: UserProfile?) {
        WelcomeWindow.shared.show(model: model, initialProfile: initialProfile) { [weak self] profile in
            self?.model.saveUserProfile(profile)
        } onFinish: { [weak self] section in
            if let section {
                self?.model.selectedSection = section
                self?.showMainWindow()
            }
            self?.showMissingPermissionsIfNeeded()
        }
    }

    private func showMissingPermissionsIfNeeded() {
        let missing = model.missingPermissionRows
        guard !missing.isEmpty else { return }
        PermissionsSetupWindow.shared.show(rows: missing) { row in
            self.model.openPermissionSettings(row)
        } onRefresh: {
            self.model.refreshPermissionRows()
            return self.model.missingPermissionRows
        }
    }

    @objc private func testRecordingPrompt() {
        model.recording.showRecordingPrompt(title: model.recording.currentMeetingPromptTitle(), delaySeconds: 1)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let title = response.notification.request.content.userInfo[NotificationBridge.meetingTitleKey] as? String
            ?? "Riunione Teams"
        switch response.actionIdentifier {
        case NotificationBridge.recordActionIdentifier:
            model.recording.handleRecordAction(meetingTitle: title)
        case UNNotificationDefaultActionIdentifier, NotificationBridge.openActionIdentifier:
            showMainWindow()
        default:
            break
        }
    }

}
