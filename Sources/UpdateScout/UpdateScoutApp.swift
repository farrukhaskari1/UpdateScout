import SwiftUI
import AppKit
import UserNotifications

@main
struct UpdateScoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UpdateStore()
    @ObservedObject private var settings = UserSettings.shared

    var body: some Scene {
        MenuBarExtra {
            // `.window` style builds this content when the panel opens, so
            // onAppear is our "menu was opened" hook.
            MenuView()
                .environmentObject(store)
                .onAppear { store.refreshIfStale() }
        } label: {
            MenuBarLabel(count: store.items.count,
                         scanning: store.isScanning,
                         showCount: settings.showBadgeCount)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon in the menu bar: a count when something is outdated, a plain glyph otherwise.
private struct MenuBarLabel: View {
    let count: Int
    let scanning: Bool
    let showCount: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if showCount && count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }

    private var symbol: String {
        if scanning { return "arrow.triangle.2.circlepath" }
        return count > 0 ? "arrow.down.circle.fill" : "checkmark.circle"
    }
}

/// Notifications need a bundled, identified process. Running the bare binary
/// straight out of `swift build` doesn't qualify.
enum Notifications {
    static var areAvailable: Bool { Bundle.main.bundleIdentifier != nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // Recovering the login shell's PATH costs a subprocess; do it before the
        // first menu open so the Settings pane doesn't stutter.
        DispatchQueue.global(qos: .utility).async { _ = Shell.searchPath }

        // UNUserNotificationCenter throws for an unbundled process, which is
        // what `swift run` produces. Only ask when we're a real .app.
        if UserSettings.shared.notifyOnNew, Notifications.areAvailable {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
}
