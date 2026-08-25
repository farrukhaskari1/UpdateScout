import AppKit
import SwiftUI

/// Temporarily keeps the menu panel visible while the user confirms or runs an
/// update. Outside those states, the system's normal menu-bar behavior is left
/// unchanged.
@MainActor
struct MenuPanelBehavior: NSViewRepresentable {
    let keepsVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        applyAfterAttachment(of: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.apply(to: view.window, keepsVisible: keepsVisible)
        if view.window == nil {
            applyAfterAttachment(of: view, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.restoreSystemBehavior()
    }

    private func applyAfterAttachment(of view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [keepsVisible] in
            coordinator.apply(to: view.window, keepsVisible: keepsVisible)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var originalLevel: NSWindow.Level?
        private var originallyHidOnDeactivate: Bool?
        private var isKeepingVisible = false

        func apply(to newWindow: NSWindow?, keepsVisible: Bool) {
            guard let newWindow else { return }
            if window !== newWindow {
                restoreSystemBehavior()
                window = newWindow
                originalLevel = newWindow.level
                originallyHidOnDeactivate = newWindow.hidesOnDeactivate
            }
            guard keepsVisible != isKeepingVisible else { return }

            if keepsVisible {
                newWindow.hidesOnDeactivate = false
                newWindow.level = .floating
                newWindow.orderFrontRegardless()
                AppActivation.bringForward()
                isKeepingVisible = true
            } else {
                restoreSystemBehavior()
            }
        }

        func restoreSystemBehavior() {
            if let window {
                if let originalLevel { window.level = originalLevel }
                if let originallyHidOnDeactivate {
                    window.hidesOnDeactivate = originallyHidOnDeactivate
                }
            }
            isKeepingVisible = false
        }
    }
}
