import Foundation

/// How far through a run of updates we are.
///
/// A count and a name rather than a formatted string, so the UI can render a
/// determinate bar as well as a label — a package manager gives no signal about
/// progress *within* one command, but "3 of 7" across the queue is honest and
/// is the part the user actually waits on.
struct UpdateProgress: Equatable, Sendable {
    /// Commands finished, successfully or not.
    var completed: Int
    var total: Int
    /// The app or tool being updated right now.
    var currentName: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    /// "3 of 7 · Raycast"
    var label: String {
        "\(min(completed + 1, total)) of \(total) · \(currentName)"
    }
}

enum UpdateExecutionState: Equatable, Sendable {
    case idle
    case queued
    case running
    case succeeded
    case permissionRequired(String)
    case failed(String)
    case stopped(String)

    var isActive: Bool {
        self == .queued || self == .running
    }

    var canRun: Bool {
        switch self {
        case .idle, .permissionRequired, .failed: true
        case .queued, .running, .succeeded, .stopped: false
        }
    }

    var detail: String? {
        switch self {
        case .permissionRequired(let message), .failed(let message), .stopped(let message): message
        case .idle, .queued, .running, .succeeded: nil
        }
    }

    var isPermissionRequired: Bool {
        if case .permissionRequired = self { true } else { false }
    }
}
