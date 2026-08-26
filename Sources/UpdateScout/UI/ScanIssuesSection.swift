import SwiftUI

@MainActor
struct ScanIssuesSection: View {
    let issues: [ScanIssue]
    let state: (ScanIssue) -> UpdateExecutionState
    let actionsDisabled: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onRecover: (ScanIssue) -> Void
    let onCopy: (ScanIssue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inner) {
            Button(action: onToggle) {
                HStack(spacing: Theme.Space.inner) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.Font.label)
                    Text(sectionTitle)
                        .font(Theme.Font.label)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Text("\(issues.count)")
                        .font(Theme.Font.label)
                        .monospacedDigit()
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(issues) { issue in
                    ScanIssueRow(
                        issue: issue,
                        executionState: state(issue),
                        actionsDisabled: actionsDisabled,
                        onRecover: { onRecover(issue) },
                        onCopy: { onCopy(issue) }
                    )
                }
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, Theme.Space.row)
    }

    private var sectionTitle: String {
        if issues.contains(where: { $0.severity == .failed }) { "Needs attention" }
        else if issues.contains(where: { $0.recovery != nil }) { "Recommended setup" }
        else { "Not checked" }
    }
}
