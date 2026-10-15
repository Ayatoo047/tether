import AppKit
import SwiftUI

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var devices = DeviceStore()
    @StateObject private var transfers = TransferManager.shared

    var body: some Scene {
        WindowGroup("Tether") {
            ContentView()
                .environmentObject(devices)
                .environmentObject(transfers)
                .frame(minWidth: 900, minHeight: 540)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.removeItem(at: AppPaths.drags)
        // Hidden preference (also settable as a launch argument: -startBrowserLink YES).
        Task { @MainActor in
            if UserDefaults.standard.bool(forKey: "startBrowserLink") {
                WebLinkServer.shared.start()
            } else {
                WebLinkServer.shared.restoreIfEnabled()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
