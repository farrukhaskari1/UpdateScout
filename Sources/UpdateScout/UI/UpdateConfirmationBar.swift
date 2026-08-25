import SwiftUI

struct UpdateConfirmationBar: View {
    let prompt: UpdatePrompt
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inner) {
            Label(prompt.title, systemImage: "checkmark.shield")
                .font(Theme.Font.body.bold())

            Text(prompt.summary)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command = prompt.commandPreview {
                Text(command)
                    .font(Theme.Font.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(Theme.Space.inner)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.subtleFill)
                    )
            }

            HStack(spacing: Theme.Space.inner) {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(prompt.confirmLabel, systemImage: "arrow.down.circle", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.row)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .contain)
    }
}
