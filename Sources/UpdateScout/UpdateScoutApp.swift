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
                         showCount: settings.showBadgeCount)
        }
        .menuBarExtraStyle(.window)

        Window("Update Scout", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentMinSize)
    }
}

/// A scout mark in the menu bar, with an optional count when updates are available.
private struct MenuBarLabel: View {
    let count: Int
    let showCount: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: MacHardwareIcon.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 18, height: 16)
            if showCount && count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            count > 0
                ? "\(MacHardwareIcon.machineName), \(count) updates available"
                : "\(MacHardwareIcon.machineName), no updates available"
        )
    }
}

/// Uses the Mac's marketing family rather than a generic menu-bar glyph.
/// `system_profiler` is queried once per launch because modern identifiers such
/// as `Mac16,7` no longer reveal whether the machine is a notebook or desktop.
enum MacHardwareIcon {
    static let identity: (name: String, model: String?) = detectIdentity()
    static let machineName = identity.name
    static let symbolName = symbol(machineName: identity.name, modelIdentifier: identity.model)

    static func symbol(machineName: String?, modelIdentifier: String?) -> String {
        let name = machineName?.lowercased() ?? ""
        let model = modelIdentifier?.lowercased() ?? ""

        if name.contains("macbook") || model.hasPrefix("macbook") {
            return available("macbook.gen2", fallback: "macbook")
        }
        if name.contains("mac studio") { return available("macstudio.fill", fallback: "desktopcomputer") }
        if name.contains("mac mini") || model.hasPrefix("macmini") {
            return available("macmini.gen3.fill", fallback: "macmini.fill")
        }
        if name.contains("imac") || model.hasPrefix("imac") { return "desktopcomputer" }
        if name.contains("mac pro") || model.hasPrefix("macpro") {
            return available("macpro.gen3.fill", fallback: "desktopcomputer")
        }
        return "desktopcomputer"
    }

    private static func detectIdentity() -> (name: String, model: String?) {
        guard let result = try? Shell.run(
            "system_profiler",
            ["SPHardwareDataType", "-json"],
            timeout: 5
        ),
        result.ok,
        let identity = parseIdentity(from: Data(result.stdout.utf8))
        else { return ("Mac", nil) }

        return identity
    }

    static func parseIdentity(from data: Data) -> (name: String, model: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardware = (json["SPHardwareDataType"] as? [[String: Any]])?.first
        else { return nil }
        let name = hardware["machine_name"] as? String ?? "Mac"
        let model = hardware["machine_model"] as? String
        return (name, model)
    }

    private static func available(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil
            ? fallback
            : preferred
    }
}

/// Notifications need a bundled, identified process. Running the bare binary
/// straight out of `swift build` doesn't qualify.
enum Notifications {
    static var areAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard areAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("UpdateScout notification authorization failed: \(error.localizedDescription)") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        // Recovering the login shell's PATH costs a subprocess; do it before the
        // first menu open so the Settings pane doesn't stutter.
        Task { _ = await Shell.offPool { Shell.searchPath } }

        // UNUserNotificationCenter throws for an unbundled process, which is
        // what `swift run` produces. Only ask when we're a real .app.
        if UserSettings.shared.notifyOnNew, Notifications.areAvailable {
            Notifications.requestAuthorization()
        }
    }

    /// Flush preferences before we go.
    ///
    /// `UserDefaults` writes are coalesced and flushed on a timer, so a hard
    /// termination — `pkill` during a reinstall, for instance — can lose the
    /// last few changes. Losing the selected AI service silently resets it to
    /// the default, which then reports "add an OpenAI API key" for a service
    /// the user never chose.
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
    }
}
