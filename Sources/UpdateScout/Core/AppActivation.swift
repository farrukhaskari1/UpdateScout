import AppKit

enum AppActivation {
    /// Activates this accessory app after a menu-bar interaction without
    /// dropping support for macOS 13.
    @MainActor
    static func bringForward() {
        if #available(macOS 14, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
