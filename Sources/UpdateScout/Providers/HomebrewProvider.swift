import Foundation
import os

/// `brew outdated --json=v2 --greedy` covers both CLI formulae and GUI casks.
///
/// Emits into two buckets so the menu can separate "apps" from "command line tools".
struct HomebrewProvider: UpdateProvider {
    let kind: SourceKind = .homebrewFormula
    var isAvailable: Bool { Shell.has("brew") }

    /// Cask tokens installed on this machine — used to stop the Sparkle scanner
    /// from reporting apps Homebrew already manages.
    ///
    /// `OSAllocatedUnfairLock` rather than `NSLock`: this is written from an
    /// async function, and `NSLock.lock()` is unavailable from async contexts
    /// (a warning in Swift 5 mode, an error in Swift 6).
    private static let caskTokens = OSAllocatedUnfairLock(initialState: Set<String>())

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }

        // Homebrew 4 refreshes its JSON metadata on demand, so no `brew update`
        // is needed here — that would cost a git fetch on every scan.
        await Self.cacheCaskTokens()

        guard let result = await Shell.runAsync(
            "brew",
            ["outdated", "--json=v2", "--greedy"],
            timeout: 240
        ) else {
            return issue("Could not run `brew outdated`.")
        }

        guard let data = result.stdout.data(using: .utf8) else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return issue(detail.isEmpty ? "Unreadable output from `brew outdated`." : detail)
        }

        // Warm the bundle inventory off the cooperative pool before the loop —
        // the first `matchPath` would otherwise do a few hundred plist reads
        // inline. Subsequent calls hit AppInventory's cache.
        _ = await Shell.offPool { AppInventory.scan() }
        guard let items = Self.parse(data, iconPath: AppInventory.matchPath(for:)) else {
            return issue(result.stderr.nonEmpty ?? "Unreadable output from `brew outdated`.")
        }
        return ScanResult(items: items, issues: [])
    }

    /// Pure parser used by production and fixture tests.
    static func parse(_ data: Data, iconPath: (String) -> String? = { _ in nil }) -> [UpdateItem]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var items: [UpdateItem] = []

        for entry in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let installed = Version.highest(entry["installed_versions"] as? [String] ?? []) ?? "—"
            let latest = entry["current_version"] as? String ?? "—"
            guard Version.isNewer(latest, than: installed) else { continue }
            items.append(UpdateItem(
                source: .homebrewFormula, name: name, installedVersion: installed,
                latestVersion: latest, upgradeCommand: "brew upgrade \(name)",
                infoURL: URL(string: "https://formulae.brew.sh/formula/\(name)")
            ))
        }

        for entry in root["casks"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let installed = (entry["installed_versions"] as? [String]).flatMap(Version.highest)
                ?? entry["installed_versions"] as? String
                ?? entry["installed_version"] as? String
                ?? "—"
            let latest = entry["current_version"] as? String ?? "—"
            // `--greedy` includes self-updating casks whose recorded version is "latest".
            guard latest != "latest", installed != "latest" else { continue }
            guard Version.isNewer(latest, than: installed) else { continue }
            items.append(UpdateItem(
                source: .homebrewCask,
                name: name,
                installedVersion: installed,
                latestVersion: latest,
                upgradeCommand: "brew upgrade --cask \(name)",
                infoURL: URL(string: "https://formulae.brew.sh/cask/\(name)"),
                iconPath: iconPath(name)
            ))
        }
        return items
    }

    /// Record every installed cask token, normalised, for de-duplication.
    private static func cacheCaskTokens() async {
        guard let result = await Shell.runAsync("brew", ["list", "--cask", "-1"], timeout: 60),
              result.ok
        else {
            // Better to double-report an app than to suppress it based on a
            // cask list from a previous, possibly different, scan.
            caskTokens.withLock { $0 = [] }
            return
        }
        let tokens = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        caskTokens.withLock { $0 = Set(tokens) }
    }

    /// True if an app name like "Visual Studio Code" looks like an installed cask.
    static func managesApp(named appName: String) -> Bool {
        let normalized = appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return caskTokens.withLock { tokens in
            if tokens.contains(normalized) { return true }
            // "iterm2" cask vs "iTerm" app, "google-chrome" vs "Google Chrome"
            let squashed = normalized.replacingOccurrences(of: "-", with: "")
            return tokens.contains { $0.replacingOccurrences(of: "-", with: "") == squashed }
        }
    }
}
