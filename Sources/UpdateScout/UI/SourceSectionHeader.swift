import SwiftUI

/// A quiet divider for one source in the always-expanded update list.
struct SourceSectionHeader: View {
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack(spacing: Theme.Space.inner) {
            Image(systemName: symbol)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: Theme.iconSide)
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
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.inner)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) updates")
    }
}
