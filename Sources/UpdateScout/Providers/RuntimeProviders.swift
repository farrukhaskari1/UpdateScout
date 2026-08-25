import Foundation

/// mise (formerly rtx) — language runtimes and tools.
struct MiseProvider: UpdateProvider {
    let kind: SourceKind = .mise
    var isAvailable: Bool { Shell.has("mise") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("mise", ["outdated", "--json"], timeout: 180) else {
            return issue("Could not run `mise outdated`.")
        }
        guard let data = result.stdout.data(using: .utf8),
              let items = Self.parse(data)
        else {
            // Older mise versions print a table; nothing to parse reliably.
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ScanResult()
                : issue("`mise outdated --json` returned unexpected output — update mise.")
        }

        return ScanResult(items: items, issues: [])
    }

    static func parse(_ data: Data) -> [UpdateItem]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var items: [UpdateItem] = []
        for (tool, raw) in root {
            guard let entry = raw as? [String: Any] else { continue }
            let current = entry["current"] as? String ?? "—"
            let latest = entry["latest"] as? String ?? "—"
            guard current != "—", latest != "—", Version.isNewer(latest, than: current) else { continue }
            items.append(UpdateItem(
                source: .mise,
                name: tool,
                installedVersion: current,
                latestVersion: latest,
                upgradeCommand: "mise upgrade \(tool)",
                infoURL: nil
            ))
        }
        return items
    }
}

/// rustup toolchains.
struct RustupProvider: UpdateProvider {
    let kind: SourceKind = .rustup
    var isAvailable: Bool { Shell.has("rustup") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("rustup", ["check"], timeout: 120) else {
            return issue("Could not run `rustup check`.")
        }
        // rustup uses 100 specifically to mean that updates are available.
        guard result.ok || result.exitCode == 100 else {
            return issue(result.stderr.nonEmpty ?? "`rustup check` failed.")
        }
        return ScanResult(items: Self.parse(result.stdout), issues: [])
    }

    static func parse(_ output: String) -> [UpdateItem] {
        var items: [UpdateItem] = []
        // "stable-aarch64-apple-darwin - Update available : 1.76.0 -> 1.77.0"
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard text.contains("Update available") else { continue }
            // The toolchain name is the whole field before " - ". Splitting on a
            // bare "-" would truncate "stable-aarch64-apple-darwin" to "stable".
            let head = text.components(separatedBy: " - ").first?
                .trimmingCharacters(in: .whitespaces) ?? "toolchain"
            guard let versionsPart = text.components(separatedBy: ":").last else { continue }
            let versions = versionsPart.components(separatedBy: "->").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard versions.count == 2 else { continue }
            items.append(UpdateItem(
                source: .rustup,
                name: head,
                installedVersion: versions[0],
                latestVersion: versions[1],
                upgradeCommand: "rustup update",
                infoURL: nil
            ))
        }
        return items
    }
}

/// Globally installed RubyGems.
struct GemProvider: UpdateProvider {
    let kind: SourceKind = .gem
    var isAvailable: Bool { Shell.has("gem") }

    /// Apple's bundled Ruby. Its gems are system-managed: `gem outdated` happily
    /// lists dozens of them, but `gem update <name>` answers "Nothing to update"
    /// or "not currently installed" because the default gems are pinned and the
    /// gem home isn't writable. Reporting them is pure noise.
    private var isSystemRuby: Bool {
        guard let path = Shell.which("gem") else { return false }
        return path.hasPrefix("/usr/bin/") || path.hasPrefix("/System/")
    }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard !isSystemRuby else {
            return skipped("Using macOS system Ruby, whose gems can't be updated. Install Ruby via Homebrew, rbenv, or mise to track these.")
        }
        guard let result = await Shell.runAsync("gem", ["outdated"], timeout: 240) else {
            return issue("Could not run `gem outdated`.")
        }
        guard result.ok else { return issue(result.stderr.nonEmpty ?? "`gem outdated` failed.") }

        return ScanResult(items: Self.parse(result.stdout), issues: [])
    }

    static func parse(_ output: String) -> [UpdateItem] {
        var items: [UpdateItem] = []
        // "rails (7.0.4 < 7.1.2)"
        let pattern = #"^(\S+)\s+\(([^<]+)<\s*([^)]+)\)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex?.firstMatch(in: text, range: range), match.numberOfRanges == 4,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let oldRange = Range(match.range(at: 2), in: text),
                  let newRange = Range(match.range(at: 3), in: text)
            else { continue }
            let name = String(text[nameRange])
            items.append(UpdateItem(
                source: .gem,
                name: name,
                installedVersion: String(text[oldRange]).trimmingCharacters(in: .whitespaces),
                latestVersion: String(text[newRange]).trimmingCharacters(in: .whitespaces),
                upgradeCommand: "gem update \(name)",
                infoURL: URL(string: "https://rubygems.org/gems/\(name)")
            ))
        }
        return items
    }
}

/// Globally installed npm packages.
struct NpmProvider: UpdateProvider {
    let kind: SourceKind = .npm
    var isAvailable: Bool { Shell.has("npm") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        // npm exits non-zero when outdated packages exist, so ignore the exit code.
        guard let result = await Shell.runAsync("npm", ["outdated", "-g", "--json"], timeout: 240) else {
            return issue("Could not run `npm outdated -g`.")
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return ScanResult() }
        guard let data = trimmed.data(using: .utf8), let items = Self.parse(data)
        else { return issue("Unreadable output from `npm outdated -g`.") }
        return ScanResult(items: items, issues: [])
    }

    static func parse(_ data: Data) -> [UpdateItem]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var items: [UpdateItem] = []
        for (name, raw) in root {
            // npm 9+ can return an array when a package is installed in several places.
            let entry: [String: Any]?
            if let dict = raw as? [String: Any] { entry = dict }
            else if let list = raw as? [[String: Any]] { entry = list.first }
            else { entry = nil }

            guard let entry,
                  let current = entry["current"] as? String,
                  let latest = entry["latest"] as? String,
                  Version.isNewer(latest, than: current)
            else { continue }

            items.append(UpdateItem(
                source: .npm,
                name: name,
                installedVersion: current,
                latestVersion: latest,
                upgradeCommand: "npm install -g \(name)@latest",
                infoURL: URL(string: "https://www.npmjs.com/package/\(name)")
            ))
        }
        return items
    }
}

/// MacPorts.
struct MacPortsProvider: UpdateProvider {
    let kind: SourceKind = .macports
    var isAvailable: Bool { Shell.has("port") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("port", ["outdated"], timeout: 240) else {
            return issue("Could not run `port outdated`.")
        }

        guard result.ok else { return issue(result.stderr.nonEmpty ?? "`port outdated` failed.") }
        let text = result.stdout
        if text.contains("No installed ports are outdated") { return ScanResult() }
        return ScanResult(items: Self.parse(text), issues: [])
    }

    static func parse(_ output: String) -> [UpdateItem] {
        var items: [UpdateItem] = []
        // "portname       1.0.0 < 1.1.0"  (the header line is skipped by the pattern)
        let pattern = #"^(\S+)\s+([0-9][^\s<]*)\s*<\s*([0-9]\S*)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

        for line in output.split(separator: "\n") {
            let row = String(line)
            let range = NSRange(row.startIndex..., in: row)
            guard let match = regex?.firstMatch(in: row, range: range), match.numberOfRanges == 4,
                  let nameRange = Range(match.range(at: 1), in: row),
                  let oldRange = Range(match.range(at: 2), in: row),
                  let newRange = Range(match.range(at: 3), in: row)
            else { continue }

            let name = String(row[nameRange])
            items.append(UpdateItem(
                source: .macports,
                name: name,
                installedVersion: String(row[oldRange]),
                latestVersion: String(row[newRange]),
                // MacPorts needs root; the app only ever hands over the string.
                upgradeCommand: "sudo port upgrade \(name)",
                infoURL: URL(string: "https://ports.macports.org/port/\(name)/")
            ))
        }
        return items
    }
}

/// Globally installed Composer packages.
struct ComposerProvider: UpdateProvider {
    let kind: SourceKind = .composer
    var isAvailable: Bool { Shell.has("composer") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync(
            "composer", ["global", "outdated", "--direct", "--format=json", "--no-interaction"],
            timeout: 240
        ) else {
            return issue("Could not run `composer global outdated`.")
        }
        guard let data = result.stdout.data(using: .utf8), let items = Self.parse(data)
        else { return issue("Unreadable output from `composer global outdated`.") }
        return ScanResult(items: items, issues: [])
    }

    static func parse(_ data: Data) -> [UpdateItem]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = root["installed"] as? [[String: Any]] else { return nil }
        var items: [UpdateItem] = []
        for entry in installed {
            guard let name = entry["name"] as? String,
                  let current = entry["version"] as? String,
                  let latest = entry["latest"] as? String,
                  Version.isNewer(latest, than: current)
            else { continue }
            items.append(UpdateItem(
                source: .composer,
                name: name,
                installedVersion: current,
                latestVersion: latest,
                upgradeCommand: "composer global update \(name)",
                infoURL: URL(string: "https://packagist.org/packages/\(name)")
            ))
        }
        return items
    }
}
