import Foundation

/// Mac App Store apps, via the `mas` CLI.
struct MacAppStoreProvider: UpdateProvider {
    let kind: SourceKind = .macAppStore
    var isAvailable: Bool { Shell.has("mas") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("mas", ["outdated"], timeout: 120) else {
            return issue("Could not run `mas outdated`.")
        }
        guard result.ok else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return issue(detail.isEmpty ? "`mas outdated` failed." : detail)
        }

        // Warm the bundle inventory off the cooperative pool; `matchPath` below
        // needs it and the first call walks every .app on disk.
        _ = await Shell.offPool { AppInventory.scan() }

        var items: [UpdateItem] = []
        // Lines look like: "497799835  Xcode (15.0 -> 15.1)"
        let pattern = #"^\s*(\d+)\s+(.+?)\s+\(([^)]*?)\s*(?:->|→)\s*([^)]*?)\)\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

        for line in result.stdout.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex?.firstMatch(in: text, range: range), match.numberOfRanges == 5,
                  let idRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let oldRange = Range(match.range(at: 3), in: text),
                  let newRange = Range(match.range(at: 4), in: text)
            else { continue }

            let appID = String(text[idRange])
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            items.append(UpdateItem(
                source: .macAppStore,
                name: name,
                installedVersion: String(text[oldRange]).trimmingCharacters(in: .whitespaces),
                latestVersion: String(text[newRange]).trimmingCharacters(in: .whitespaces),
                upgradeCommand: "mas upgrade \(appID)",
                infoURL: URL(string: "macappstore://apps.apple.com/app/id\(appID)"),
                iconPath: AppInventory.matchPath(for: name)
            ))
        }
        return ScanResult(items: items, issues: [])
    }
}

/// macOS system and Apple-supplied software updates.
struct SystemUpdateProvider: UpdateProvider {
    let kind: SourceKind = .macOSSystem
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/softwareupdate") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        // A real scan (no `--no-scan`) is the only way to see updates published
        // since the last one Apple ran, and it is slow — hence the long timeout.
        guard let result = await Shell.runRawAsync(
            executable: "/usr/sbin/softwareupdate",
            arguments: ["--list"],
            timeout: 300
        ) else {
            return issue("Could not run `softwareupdate --list`.")
        }

        let combined = result.stdout + "\n" + result.stderr
        var items: [UpdateItem] = []
        let currentOS = ProcessInfo.processInfo.operatingSystemVersion
        let installedOS = "\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)"

        // "No new software available" only rules out *patches*. A major upgrade
        // can still be waiting, so fall through to that check rather than
        // returning early here.
        let hasPatches = !combined.contains("No new software available")

        // Entries look like:
        //   * Label: macOS Sonoma 14.5-23F79
        //   	Title: macOS Sonoma, Version: 14.5, Size: 6000000KiB, Recommended: YES, Action: restart,
        let lines = hasPatches ? combined.split(separator: "\n").map(String.init) : []
        var pendingLabel: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("* Label:") {
                pendingLabel = trimmed.replacingOccurrences(of: "* Label:", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let label = pendingLabel, trimmed.hasPrefix("Title:") else { continue }

            // Fields are comma-separated `Key: Value` pairs, but a title can
            // itself contain a comma — so read the version by key and keep the
            // label as the display name, which is always unambiguous.
            var version = "—"
            for field in trimmed.split(separator: ",") {
                let pair = field.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard pair.count == 2, pair[0] == "Version" else { continue }
                version = pair[1]
                break
            }

            let isOSUpdate = label.lowercased().contains("macos")
            items.append(UpdateItem(
                source: .macOSSystem,
                name: label,
                installedVersion: isOSUpdate ? installedOS : "—",
                latestVersion: version,
                upgradeCommand: "sudo softwareupdate --install \"\(label)\"",
                infoURL: URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate")
            ))
            pendingLabel = nil
        }

        if let upgrade = await majorUpgrade(installedOS: installedOS) {
            items.insert(upgrade, at: 0)
        }
        return ScanResult(items: items, issues: [])
    }

    /// `softwareupdate --list` deliberately hides whole-number macOS upgrades —
    /// it only reports patches within the version you're already on. The full
    /// installer list is the one place the command line admits a new major
    /// release exists.
    private func majorUpgrade(installedOS: String) async -> UpdateItem? {
        guard let result = await Shell.runRawAsync(
            executable: "/usr/sbin/softwareupdate",
            arguments: ["--list-full-installers"],
            timeout: 180
        ), result.ok else { return nil }

        // Lines look like:
        //   * Title: macOS Sequoia, Version: 15.6, Size: 15181740KiB, Build: 24G84
        var best: (version: String, title: String)?
        for line in (result.stdout + "\n" + result.stderr).split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("* Title:") else { continue }

            var title = "macOS"
            var version = ""
            for field in text.dropFirst(2).split(separator: ",") {
                let pair = field.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard pair.count == 2 else { continue }
                if pair[0] == "Title" { title = pair[1] }
                if pair[0] == "Version" { version = pair[1] }
            }
            guard !version.isEmpty else { continue }

            // The list includes every installer this Mac supports, older ones
            // included, so take the maximum rather than the first.
            if let current = best {
                if Version.isNewer(version, than: current.version) { best = (version, title) }
            } else {
                best = (version, title)
            }
        }

        guard let best, Version.isNewer(best.version, than: installedOS) else { return nil }
        // Only surface a genuine major jump; point releases already come through
        // the regular `--list` path above.
        guard Version.bump(from: installedOS, to: best.version) == .major else { return nil }

        return UpdateItem(
            source: .macOSSystem,
            name: "\(best.title) (major upgrade)",
            installedVersion: installedOS,
            latestVersion: best.version,
            upgradeCommand: "softwareupdate --fetch-full-installer --full-installer-version \(best.version)",
            infoURL: URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate")
        )
    }
}
