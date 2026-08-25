import Foundation

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
