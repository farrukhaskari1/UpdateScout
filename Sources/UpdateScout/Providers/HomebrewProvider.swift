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
    struct InstalledCaskApps: Sendable, Equatable {
        var paths: Set<String> = []
        var fileNames: Set<String> = []
    }

    /// Exact app artifacts declared by installed casks. Matching names alone
    /// can hide an unrelated manual app, so paths are preferred and filenames
    /// are accepted only in the standard Applications folders.
    private static let caskApps = OSAllocatedUnfairLock(initialState: InstalledCaskApps())

    struct InstalledFormula: Sendable, Equatable {
        let name: String
        let version: String
    }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }

        // `brew outdated` can use locally cached API metadata without learning
        // about a release that has just landed. `update-if-needed` is the cheap,
        // supported way to refresh that metadata: it is normally a no-op, but it
        // closes the window where another updater sees a release before we do.
        let refresh = await Shell.runAsync("brew", ["update-if-needed"], timeout: 240)
        let refreshIssue: ScanIssue? = {
            guard let refresh else {
                return ScanIssue(
                    source: .homebrewFormula,
                    message: "Could not refresh Homebrew metadata; results may be stale."
                )
            }
            guard !refresh.ok else { return nil }
            let detail = refresh.stderr.nonEmpty ?? refresh.stdout.nonEmpty
            return ScanIssue(
                source: .homebrewFormula,
                message: detail.map { "Could not refresh Homebrew metadata: \($0)" }
                    ?? "Could not refresh Homebrew metadata; results may be stale."
            )
        }()

        await Self.cacheInstalledCaskApps()

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
        guard var items = Self.parse(data, iconPath: AppInventory.matchPath(for:)) else {
            return issue(result.stderr.nonEmpty ?? "Unreadable output from `brew outdated`.")
        }

        // Same-day releases can reach the public API before Homebrew refreshes
        // its local package catalog. Check explicitly installed core formulae
        // against that API so fresh releases such as llmfit are not missed.
        if let inventory = await Shell.runAsync(
            "brew", ["info", "--json=v2", "--formula", "--installed"], timeout: 120
        ), inventory.ok, let inventoryData = inventory.stdout.data(using: .utf8) {
            let alreadyReported = Set(
                items.filter { $0.source == .homebrewFormula }.map(\.name)
            )
            let installed = Self.installedRequestedFormulae(from: inventoryData)
                .filter { !alreadyReported.contains($0.name) }
            if let latestVersions = await Registries.homebrewFormulaVersions() {
                let fresh = installed.compactMap { formula -> UpdateItem? in
                    guard let latest = latestVersions[formula.name],
                          Version.isNewer(latest, than: formula.version)
                    else { return nil }
                    return UpdateItem(
                        source: .homebrewFormula,
                        name: formula.name,
                        installedVersion: formula.version,
                        latestVersion: latest,
                        upgradeCommand: "brew update && brew upgrade \(Shell.quoteArgument(formula.name))",
                        infoURL: URL(string: "https://formulae.brew.sh/formula/\(formula.name)")
                    )
                }
                items.append(contentsOf: fresh)
            }
        }
        return ScanResult(items: items, issues: refreshIssue.map { [$0] } ?? [])
    }

    static func installedRequestedFormulae(from data: Data) -> [InstalledFormula] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return (root["formulae"] as? [[String: Any]] ?? []).compactMap { formula in
            guard let name = formula["name"] as? String,
                  !((formula["pinned"] as? Bool) ?? false),
                  (formula["tap"] as? String) == "homebrew/core"
            else { return nil }
            let installs = formula["installed"] as? [[String: Any]] ?? []
            let requestedVersions = installs.compactMap { install -> String? in
                guard (install["installed_on_request"] as? Bool) == true else { return nil }
                return install["version"] as? String
            }
            guard let version = Version.highest(requestedVersions) else { return nil }
            return InstalledFormula(name: name, version: version)
        }
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
                latestVersion: latest, upgradeCommand: "brew upgrade \(Shell.quoteArgument(name))",
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
                upgradeCommand: "brew upgrade --cask \(Shell.quoteArgument(name))",
                infoURL: URL(string: "https://formulae.brew.sh/cask/\(name)"),
                iconPath: iconPath(name)
            ))
        }
        return items
    }

    private static func cacheInstalledCaskApps() async {
        guard let result = await Shell.runAsync(
            "brew", ["info", "--json=v2", "--cask", "--installed"], timeout: 120
        ), result.ok, let data = result.stdout.data(using: .utf8)
        else {
            caskApps.withLock { $0 = InstalledCaskApps() }
            return
        }
        caskApps.withLock { $0 = installedCaskApps(from: data) }
    }

    static func installedCaskApps(from data: Data) -> InstalledCaskApps {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return InstalledCaskApps()
        }
        var inventory = InstalledCaskApps()
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                // Homebrew nests the rename target *inside* the `app` array, as a
                // sibling dictionary of the filename:
                //   "app": ["Foo.app", {"target": "/Applications/Bar.app"}]
                // Casting the array to [String] drops both halves, so casks that
                // rename their app were invisible and got double-reported by the
                // Sparkle scanner.
                for element in artifact["app"] as? [Any] ?? [] {
                    if let source = element as? String {
                        let fileName = URL(fileURLWithPath: source).lastPathComponent
                        if fileName.lowercased().hasSuffix(".app") {
                            inventory.fileNames.insert(fileName)
                        }
                    } else if let dictionary = element as? [String: Any],
                              let target = dictionary["target"] as? String,
                              target.lowercased().hasSuffix(".app") {
                        inventory.paths.insert(
                            URL(fileURLWithPath: target).standardizedFileURL.path
                        )
                        inventory.fileNames.insert(
                            URL(fileURLWithPath: target).lastPathComponent
                        )
                    }
                }
                // Some casks still carry `target` on the artifact itself.
                if let target = artifact["target"] as? String,
                   target.hasPrefix("/"),
                   target.lowercased().hasSuffix(".app") {
                    inventory.paths.insert(
                        URL(fileURLWithPath: target).standardizedFileURL.path
                    )
                    inventory.fileNames.insert(
                        URL(fileURLWithPath: target).lastPathComponent
                    )
                }
            }
        }
        return inventory
    }

    static func managesApp(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return caskApps.withLock { inventory in
            if inventory.paths.contains(url.path) { return true }
            let standardParents: Set<String> = [
                "/Applications",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true)
                    .standardizedFileURL.path
            ]
            return standardParents.contains(url.deletingLastPathComponent().path)
                && inventory.fileNames.contains(url.lastPathComponent)
        }
    }
}
