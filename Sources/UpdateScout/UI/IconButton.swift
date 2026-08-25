import SwiftUI

/// Visually compact while retaining a descriptive VoiceOver and Voice Control label.
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(help, systemImage: systemName)
                .labelStyle(.iconOnly)
                .font(Theme.Font.control)
                .foregroundStyle(isEnabled ? Color.secondary : Theme.disabledLabel)
                .frame(width: Theme.iconSide, height: Theme.iconSide)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(hovering && isEnabled ? Theme.hover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
