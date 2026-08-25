import Foundation

/// Where an outdated thing came from.
enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case homebrewFormula
    case homebrewCask
    case macAppStore
    case macOSSystem
    case sparkleApp
    case githubApp
    case mise
    case rustup
    case gem
    case npm
    case composer
    case pipx
    case pip
    case uv
    case cargo
    case golang
    case macports
    /// Anything the user declared in `~/.config/updatescout/sources.json`.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrewFormula: return "Homebrew Formulae"
        case .homebrewCask:    return "Homebrew Casks"
        case .macAppStore:     return "Mac App Store"
        case .macOSSystem:     return "macOS System"
        case .sparkleApp:      return "Apps (Sparkle)"
        case .githubApp:       return "Apps (GitHub Releases)"
        case .mise:            return "mise"
        case .rustup:          return "rustup"
        case .gem:             return "RubyGems"
        case .npm:             return "npm (global)"
        case .composer:        return "Composer (global)"
        case .pipx:            return "pipx"
        case .pip:             return "pip"
        case .uv:              return "uv tools"
        case .cargo:           return "cargo"
        case .golang:          return "Go binaries"
        case .macports:        return "MacPorts"
        case .custom:          return "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .homebrewFormula, .homebrewCask, .macports: return "shippingbox"
        case .custom:                         return "puzzlepiece.extension"
        case .macAppStore:                    return "bag"
        case .macOSSystem:                    return "apple.logo"
        case .sparkleApp, .githubApp:         return "app.badge"
        case .mise, .rustup:                  return "wrench.and.screwdriver"
        case .gem, .npm, .composer,
             .pipx, .pip, .uv, .cargo,
             .golang:                         return "terminal"
        }
    }

    /// Display order in the menu.
    var rank: Int {
        switch self {
        case .macOSSystem:     return 0
        case .homebrewCask:    return 1
        case .sparkleApp:      return 2
        case .githubApp:       return 3
        case .macAppStore:     return 4
        case .homebrewFormula: return 5
        case .mise:            return 6
        case .rustup:          return 7
        case .npm:             return 8
        case .pipx:            return 9
        case .uv:              return 10
        case .pip:             return 11
        case .gem:             return 12
        case .cargo:           return 13
        case .golang:          return 14
        case .composer:        return 15
        case .macports:        return 16
        case .custom:          return 17
        }
    }

    /// Whether this is a GUI application (vs a CLI tool).
    var isApplication: Bool {
        switch self {
        case .homebrewCask, .macAppStore, .sparkleApp, .githubApp, .macOSSystem: return true
        default: return false
        }
    }
}

/// One thing that has a newer version available.
struct UpdateItem: Identifiable, Hashable, Sendable {
    let source: SourceKind
    let name: String
    let installedVersion: String
    let latestVersion: String
    /// The command you'd run to upgrade it, or nil for things you update by hand.
    let upgradeCommand: String?
    /// Release notes / download page, if we know one.
    let infoURL: URL?
    /// Bundle identifier for GUI apps, so the user can mute a noisy one.
    let ignoreKey: String?
    /// Path to a `.app` bundle, so the row can show the real icon.
    let iconPath: String?
    /// Stable section identity for user-defined tools, so renaming a tool's
    /// display title doesn't silently discard its collapse state.
    let groupID: String?
    /// Section heading override, so each user-defined tool gets its own group
    /// instead of everything landing in one "Custom" pile.
    let groupTitle: String?

    init(source: SourceKind,
         name: String,
         installedVersion: String,
         latestVersion: String,
         upgradeCommand: String?,
         infoURL: URL?,
         ignoreKey: String? = nil,
         iconPath: String? = nil,
         groupID: String? = nil,
         groupTitle: String? = nil) {
        self.source = source
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.upgradeCommand = upgradeCommand
        self.infoURL = infoURL
        self.ignoreKey = ignoreKey
        self.iconPath = iconPath
        self.groupID = groupID
        self.groupTitle = groupTitle
    }

    var id: String { "\(groupKey):\(name)" }

    /// Which section this belongs to, and the key the collapse state persists
    /// under. Built-ins group by source; custom tools group by their declared
    /// `id`, never by their display title.
    var groupKey: String {
        guard let groupID else { return source.rawValue }
        return "\(source.rawValue)|\(groupID)"
    }

    var bump: Version.Bump { Version.bump(from: installedVersion, to: latestVersion) }

    var versionSummary: String { "\(installedVersion) → \(latestVersion)" }

    /// Includes the offered version so a newer release of an already-outdated
    /// package can trigger a fresh notification.
    var notificationID: String { "\(id):\(latestVersion)" }
}

/// Updates from one source, ready for a `ForEach`.
///
/// A named type rather than a tuple: Swift key paths can't address tuple
/// elements, so `ForEach` over an array of tuples doesn't compile. `id` is the
/// group key — a source's raw value for built-ins, `custom|<tool id>` otherwise.
struct SourceGroup: Identifiable {
    /// Stable across launches — this is also the collapse-state key.
    let id: String
    let kind: SourceKind
    let title: String
    let items: [UpdateItem]

    var symbol: String { kind.symbol }
    var rank: Int { kind.rank }
}

/// A toggleable source in Settings, and whether its backing tool exists.
struct SourceOption: Identifiable, Sendable {
    let kind: SourceKind
    let installed: Bool
    var id: SourceKind { kind }
}

/// Why a source produced no results.
///
/// A deliberate skip and a genuine failure look identical if you render both as
/// a warning, which makes working-as-designed behaviour look broken.
enum IssueSeverity: Sendable {
    /// We chose not to check — nothing is wrong.
    case skipped
    /// We tried and couldn't.
    case failed

    var symbol: String {
        switch self {
        case .skipped: return "minus.circle"
        case .failed:  return "exclamationmark.triangle.fill"
        }
    }
}

/// A source produced no results, surfaced so silent gaps don't read as "all up to date".
struct ScanIssue: Identifiable, Hashable, Sendable {
    let source: SourceKind
    let message: String
    let severity: IssueSeverity

    init(source: SourceKind, message: String, severity: IssueSeverity = .failed) {
        self.source = source
        self.message = message
        self.severity = severity
    }

    var id: String { "\(source.rawValue):\(message)" }
}


struct ScanResult: Sendable {
    var items: [UpdateItem] = []
    var issues: [ScanIssue] = []

    static func + (lhs: ScanResult, rhs: ScanResult) -> ScanResult {
        ScanResult(items: lhs.items + rhs.items, issues: lhs.issues + rhs.issues)
    }
}

/// Everything a provider needs to know, and how it reports back.
protocol UpdateProvider: Sendable {
    var kind: SourceKind { get }
    /// Cheap check — is the underlying tool even installed?
    var isAvailable: Bool { get }
    func scan() async -> ScanResult
}

extension UpdateProvider {
    /// Something went wrong.
    func issue(_ message: String) -> ScanResult {
        ScanResult(items: [], issues: [ScanIssue(source: kind, message: message, severity: .failed)])
    }

    /// We deliberately didn't check, and here's why.
    func skipped(_ message: String) -> ScanResult {
        ScanResult(items: [], issues: [ScanIssue(source: kind, message: message, severity: .skipped)])
    }
}

extension String {
    /// Trimmed text when useful for a user-facing diagnostic.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
