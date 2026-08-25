import SwiftUI

struct RowButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(help, systemImage: systemName)
                .labelStyle(.iconOnly)
                .font(Theme.Font.label)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: Theme.iconSide, height: Theme.iconSide)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
