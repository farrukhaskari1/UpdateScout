import SwiftUI

/// What's being updated, and how far through the queue we are.
///
/// The bar tracks *commands completed*, not bytes — `brew upgrade` reports no
/// progress of its own, so anything finer would be invented. Counting the queue
/// is honest and is the part the user is actually waiting on.
struct UpdateProgressBar: View {
    let progress: UpdateProgress
    // `var` with a default: a `let` optional gets no implicit nil in the
    // memberwise init, so omitting the handler wouldn't compile.
    var onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.inner) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12)

                Text("Updating \(progress.currentName)")
                    .font(Theme.Font.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Theme.Space.tight)

                Text(position)
                    .font(Theme.Font.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if let onStop {
                    Button("Stop", action: onStop)
                        .buttonStyle(.plain)
                        .font(Theme.Font.label)
                        .foregroundStyle(Color.accentColor)
                        .help("Finish the running command, then stop")
                }
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.25), value: progress.fraction)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.inner)
        // `.contain` rather than `.combine`: combining would fold the Stop
        // button into the parent element and hide it from VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Updating \(progress.currentName), \(position)")
    }

    /// Shared by the visible label and the accessibility label so they can't
    /// drift apart by one.
    private var position: String {
        "\(min(progress.completed + 1, progress.total)) of \(progress.total)"
    }
}
