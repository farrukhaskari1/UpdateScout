import Foundation

/// A safe way to resolve a skipped source without modifying protected system
/// runtimes. The optional command is confirmed before execution.
struct IssueRecovery: Hashable, Sendable {
    let label: String
    let command: String?
    let disablesSource: SourceKind?
    let enablesSource: SourceKind?

    init(
        label: String,
        command: String? = nil,
        disablesSource: SourceKind? = nil,
        enablesSource: SourceKind? = nil
    ) {
        self.label = label
        self.command = command
        self.disablesSource = disablesSource
        self.enablesSource = enablesSource
    }
}
