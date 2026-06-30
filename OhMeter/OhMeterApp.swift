import SwiftUI
import AppKit

@main
struct OhMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarManager: StatusBarManager?
    private var codexServer: CodexAppServer?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let server = CodexAppServer()
        self.codexServer = server

        let manager = StatusBarManager(server: server)
        self.statusBarManager = manager

        // Load cached data for instant display, then fetch fresh
        manager.loadFromCache()
        manager.refreshNow()

        startAutoRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexServer?.terminate()
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.statusBarManager?.refreshNow()
        }
    }
}
