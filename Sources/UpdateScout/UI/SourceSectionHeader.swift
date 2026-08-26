import SwiftUI

/// A quiet divider for one source in the always-expanded update list.
struct SourceSectionHeader: View {
    let title: String
    let symbol: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Space.inner) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.iconSide)
                    .accessibilityHidden(true)

                Image(systemName: symbol)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(title)
                    .font(Theme.Font.label)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Text("\(count)")
                    .font(Theme.Font.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.tight + 1)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.subtleFill))

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.inner)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) updates, \(isCollapsed ? "collapsed" : "expanded")")
    }
}
