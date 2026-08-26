import SwiftUI

/// Visually compact while retaining a descriptive VoiceOver and Voice Control label.
struct IconButton: View {
    let systemName: String
    let help: String
    var isSelected = false
    var isDestructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(help, systemImage: systemName)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foregroundStyle)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundStyle)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var foregroundStyle: Color {
        if !isEnabled { return Theme.disabledLabel }
        if isDestructive { return .red }
        if isSelected { return .accentColor }
        return hovering ? .primary : .secondary
    }

    private var backgroundStyle: Color {
        if isDestructive { return Color.red.opacity(hovering ? 0.16 : 0.1) }
        if isSelected { return Color.accentColor.opacity(0.12) }
        return hovering && isEnabled ? Theme.hover : .clear
    }
}
