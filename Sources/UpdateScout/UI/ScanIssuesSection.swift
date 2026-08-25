import SwiftUI

@MainActor
struct ScanIssuesSection: View {
    let issues: [ScanIssue]
    let state: (ScanIssue) -> UpdateExecutionState
    let actionsDisabled: Bool
    let onRecover: (ScanIssue) -> Void
    let onCopy: (ScanIssue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.inner) {
            Text(sectionTitle)
                .font(Theme.Font.label)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)

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
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, Theme.Space.row)
    }

    private var sectionTitle: String {
        if issues.contains(where: { $0.severity == .failed }) { "Needs attention" }
        else if issues.contains(where: { $0.recovery != nil }) { "Recommended setup" }
        else { "Not checked" }
    }
}
