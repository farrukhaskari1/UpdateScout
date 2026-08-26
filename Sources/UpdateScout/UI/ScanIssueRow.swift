import SwiftUI

@MainActor
struct ScanIssueRow: View {
    let issue: ScanIssue
    let executionState: UpdateExecutionState
    let actionsDisabled: Bool
    let onRecover: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.inner) {
            issueIcon

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(issue.subject ?? issue.source.title)
                    .font(Theme.Font.body.bold())

                Text(issue.message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = executionState.detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(executionState.isPermissionRequired ? .orange : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Theme.Space.inner)

            if issue.recovery != nil {
                recoveryButton
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var issueIcon: some View {
        if let icon = AppIconLoader.shared.icon(atPath: issue.iconPath) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Theme.iconSide, height: Theme.iconSide)
                .accessibilityHidden(true)
        } else {
            Image(systemName: issue.severity.symbol)
                .font(Theme.Font.caption)
                .foregroundStyle(issue.severity == .failed ? Color.orange : Color.secondary)
                .frame(width: Theme.iconSide, alignment: .center)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var recoveryButton: some View {
        switch executionState {
        case .idle:
            Button(issue.recovery?.label ?? "Fix", action: onRecover)
                .disabled(actionsDisabled)
        case .queued, .running:
            Button(action: {}) {
                HStack(spacing: Theme.Space.tight) {
                    ProgressView().controlSize(.mini)
                    Text("Working")
                }
            }
            .disabled(true)
        case .succeeded:
            Button("Done", systemImage: "checkmark", action: {})
                .disabled(true)
        case .permissionRequired:
            if issue.recovery?.command != nil {
                Button("Copy Command", systemImage: "doc.on.doc", action: onCopy)
            }
        case .failed, .stopped:
            Button("Retry", systemImage: "arrow.clockwise", action: onRecover)
                .disabled(actionsDisabled)
        }
    }
}
