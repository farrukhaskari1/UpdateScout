import Foundation
import os

/// A `.app` bundle found on disk.
struct InstalledApp: Sendable {
    let name: String
    let bundleID: String
    let path: String
    let shortVersion: String   // CFBundleShortVersionString — what humans see
    let buildVersion: String   // CFBundleVersion — what Sparkle compares
    let feedURL: URL?
}

/// Walks the Applications folders and reads each bundle's Info.plist.
enum AppInventory {

    static let searchRoots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications",
            "/Applications/Utilities",
            "\(home)/Applications",
            "/Applications/Setapp"
        ]
    }()

    private struct Cache: Sendable {
        var apps: [InstalledApp]
        var stamp: Date
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache?.none)

    /// Walking every bundle costs a few hundred plist reads, and two providers
    /// need the same list, so results are reused for a minute.
    static func scan() -> [InstalledApp] {
        if let apps = cache.withLock({ cached -> [InstalledApp]? in
            guard let cached, Date.now.timeIntervalSince(cached.stamp) < 60 else { return nil }
            return cached.apps
        }) { return apps }

        let apps = walk()

        cache.withLock { $0 = Cache(apps: apps, stamp: .now) }
        return apps
    }

    private static func walk() -> [InstalledApp] {
        let fm = FileManager.default
        var folderPaths: [String] = []

        for root in searchRoots {
            guard fm.fileExists(atPath: root),
                  let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsPackageDescendants]
                  )
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                folderPaths.append(url.path)
            }
        }

        // A manually installed app can live just outside the conventional
        // Applications folders. Include only shallow, non-hidden results from
        // the user's home so Downloads/Foo.app can be explained without also
        // treating build products, nested helpers, or Library caches as apps.
        let home = fm.homeDirectoryForCurrentUser.path
        let spotlight = (try? Shell.run(
            "mdfind",
            ["-onlyin", home, "kMDItemContentType == 'com.apple.application-bundle'"],
            timeout: 30
        ).stdout.split(separator: "\n").map(String.init)) ?? []

        let apps = candidatePaths(
            folderPaths: folderPaths,
            spotlightPaths: spotlight,
            homeDirectory: home
        ).compactMap(read(at:))
        return deduplicatedApps(apps)
    }

    static func candidatePaths(
        folderPaths: [String],
        spotlightPaths: [String],
        homeDirectory: String
    ) -> [String] {
        struct Candidate { let original: String; let cameFromSpotlight: Bool }
        let candidates = folderPaths.map { Candidate(original: $0, cameFromSpotlight: false) }
            + spotlightPaths.map { Candidate(original: $0, cameFromSpotlight: true) }
        let homeURL = URL(fileURLWithPath: homeDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
        let excludedFolders: Set<String> = [
            "library", "build", ".build", "deriveddata", "dist", "node_modules",
            "outputs", "playbackengines", "target"
        ]
        var seen = Set<String>()
        var result: [String] = []

        for candidate in candidates {
            let originalURL = URL(fileURLWithPath: candidate.original)
            let resolvedURL = originalURL.resolvingSymlinksInPath().standardizedFileURL
            let resolvedPath = resolvedURL.path
            let parents = resolvedURL.deletingLastPathComponent().pathComponents
            guard originalURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  !resolvedPath.hasPrefix("/System/"),
                  !resolvedPath.hasPrefix("/Library/Apple/"),
                  !parents.contains(where: { $0.lowercased().hasSuffix(".app") }),
                  !parents.contains(where: { excludedFolders.contains($0.lowercased()) })
            else { continue }

            if candidate.cameFromSpotlight {
                let homeComponents = homeURL.pathComponents
                let pathComponents = resolvedURL.pathComponents
                guard pathComponents.starts(with: homeComponents) else { continue }
                let relative = Array(pathComponents.dropFirst(homeComponents.count))
                let directories = relative.dropLast()
                guard (1...3).contains(relative.count),
                      directories.allSatisfy({ !$0.hasPrefix(".") }),
                      directories.allSatisfy({ !excludedFolders.contains($0.lowercased()) })
                else { continue }
            }

            if seen.insert(resolvedPath).inserted { result.append(candidate.original) }
        }
        return result
    }

    /// Keep one launchable installation for each bundle identifier. Build copies
    /// often carry the same identifier as the app in /Applications and should
    /// never inflate the installed-app count.
    static func deduplicatedApps(_ apps: [InstalledApp]) -> [InstalledApp] {
        func rank(_ app: InstalledApp) -> (Int, Int) {
            let path = URL(fileURLWithPath: app.path).standardizedFileURL.path
            let components = URL(fileURLWithPath: path).pathComponents
            if path.hasPrefix("/Applications/") && components.count == 3 { return (0, path.count) }
            if path.contains("/Applications/") { return (1, path.count) }
            return (2, path.count)
        }

        var selected: [String: InstalledApp] = [:]
        for app in apps {
            let key = app.bundleID.isEmpty
                ? URL(fileURLWithPath: app.path).standardizedFileURL.path.lowercased()
                : app.bundleID.lowercased()
            guard let current = selected[key] else {
                selected[key] = app
                continue
            }
            if rank(app) < rank(current) { selected[key] = app }
        }
        return Array(selected.values).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Best-effort match from a Homebrew cask token or an App Store display
    /// name to an installed bundle, so the row can show that app's real icon.
    ///
    /// "google-chrome" → Google Chrome.app, "iterm2" → iTerm.app. Squashing
    /// separators handles most of the gap between the two naming worlds.
    static func matchPath(for name: String) -> String? {
        func squash(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let needle = squash(name)
        guard !needle.isEmpty else { return nil }

        let apps = scan()
        if let exact = apps.first(where: { squash($0.name) == needle }) { return exact.path }
        // "iterm2" cask vs "iTerm" app — allow the token to carry a suffix.
        return apps.first {
            let candidate = squash($0.name)
            return !candidate.isEmpty && (needle.hasPrefix(candidate) || candidate.hasPrefix(needle))
                && abs(candidate.count - needle.count) <= 2
        }?.path
    }

    static func read(at path: String) -> InstalledApp? {
        let plistPath = "\(path)/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }

        let fileName = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? fileName
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let short = plist["CFBundleShortVersionString"] as? String ?? ""
        let build = plist["CFBundleVersion"] as? String ?? short

        let feedString = (plist["SUFeedURL"] as? String)
            ?? (plist["SUOriginalFeedURL"] as? String)
            ?? (plist["SPUFeedURL"] as? String)
        let feed = feedString.flatMap { URL(string: $0) }

        guard !short.isEmpty || !build.isEmpty else { return nil }
        return InstalledApp(
            name: name,
            bundleID: bundleID,
            path: path,
            shortVersion: short.isEmpty ? build : short,
            buildVersion: build,
            feedURL: feed
        )
    }
}

/// Apps that ship a Sparkle appcast — the standard way non-App-Store Mac apps
/// publish updates. Covers most manually installed software.
struct SparkleAppProvider: UpdateProvider {
    let kind: SourceKind = .sparkleApp
    let ignoredBundleIDs: Set<String>
    let deduplicateHomebrewCasks: Bool
    let coveredGitHubBundleIDs: Set<String>
    let macAppStoreCoverageEnabled: Bool
    var isAvailable: Bool { true }

    private struct FeedCheck: Sendable {
        let item: UpdateItem?
        let issue: ScanIssue?
    }

    /// Feeds we should not hit: Apple's own apps and anything with an https-less URL.
    private static func isUsable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        return true
    }

    func scan() async -> ScanResult {
        let inventory = AppInventory.scan()
        let apps = inventory.filter { app in
            guard let feed = app.feedURL, Self.isUsable(feed) else { return false }
            guard !app.bundleID.hasPrefix("com.apple.") else { return false }
            // Homebrew already reports its own casks; don't double-list.
            guard !deduplicateHomebrewCasks || !HomebrewProvider.managesApp(at: app.path) else { return false }
            guard !ignoredBundleIDs.contains(app.bundleID) else { return false }
            return true
        }

        let checks = await Registries.mapConcurrently(apps, limit: 6) { app -> FeedCheck? in
            guard let feed = app.feedURL,
                  let data = await Registries.data(from: feed)
            else {
                return FeedCheck(
                    item: nil,
                    issue: ScanIssue(
                        source: .sparkleApp,
                        subject: app.name,
                        message: "Could not read this app's update feed.",
                        severity: .failed,
                        iconPath: app.path,
                        identity: app.path
                    )
                )
            }

            let entries = AppcastParser.parse(data)
            guard let best = AppcastParser.bestEntry(in: entries) else {
                return FeedCheck(
                    item: nil,
                    issue: ScanIssue(
                        source: .sparkleApp,
                        subject: app.name,
                        message: "This app's update feed did not contain a usable release.",
                        severity: .failed,
                        iconPath: app.path,
                        identity: app.path
                    )
                )
            }

            // Sparkle compares CFBundleVersion against sparkle:version. Fall back to
            // the marketing version when the feed only publishes that.
            let latestBuild = best.version
            let latestShort = best.shortVersion

            let isNewer: Bool
            if let latestBuild, !app.buildVersion.isEmpty {
                isNewer = Version.isNewer(latestBuild, than: app.buildVersion)
            } else if let latestShort {
                isNewer = Version.isNewer(latestShort, than: app.shortVersion)
            } else {
                isNewer = false
            }
            guard isNewer else { return FeedCheck(item: nil, issue: nil) }

            let displayLatest = latestShort ?? latestBuild ?? "?"
            // If the marketing version didn't move, show the build numbers instead —
            // "3.4.1 → 3.4.1" would be useless.
            let showBuilds = displayLatest == app.shortVersion
            return FeedCheck(
                item: UpdateItem(
                    source: .sparkleApp,
                    name: app.name,
                    installedVersion: showBuilds ? app.buildVersion : app.shortVersion,
                    latestVersion: showBuilds ? (latestBuild ?? displayLatest) : displayLatest,
                    upgradeCommand: nil,
                    infoURL: best.link ?? feed,
                    ignoreKey: app.bundleID,
                    iconPath: app.path
                ),
                issue: nil
            )
        }

        let vendorApps = inventory.filter { app in
            guard Registries.officialAppBundleIDs.contains(app.bundleID),
                  !ignoredBundleIDs.contains(app.bundleID)
            else { return false }
            return !deduplicateHomebrewCasks || !HomebrewProvider.managesApp(at: app.path)
        }
        let vendorChecks = await Registries.mapConcurrently(vendorApps, limit: 3) { app -> FeedCheck? in
            guard let release = await Registries.officialAppLatest(app.bundleID) else {
                return FeedCheck(
                    item: nil,
                    issue: ScanIssue(
                        source: .sparkleApp,
                        subject: app.name,
                        message: "Could not read this app's official release page.",
                        severity: .failed,
                        iconPath: app.path,
                        identity: app.path
                    )
                )
            }
            guard Version.isNewer(release.version, than: app.shortVersion) else {
                return FeedCheck(item: nil, issue: nil)
            }
            return FeedCheck(
                item: UpdateItem(
                    source: .sparkleApp,
                    name: app.name,
                    installedVersion: app.shortVersion,
                    latestVersion: release.version,
                    upgradeCommand: nil,
                    infoURL: release.infoURL,
                    ignoreKey: app.bundleID,
                    iconPath: app.path
                ),
                issue: nil
            )
        }

        let uncovered = Self.uncoveredApps(
            in: inventory,
            ignoredBundleIDs: ignoredBundleIDs,
            configuredGitHubBundleIDs: coveredGitHubBundleIDs,
            officialVendorBundleIDs: Registries.officialAppBundleIDs,
            deduplicateHomebrewCasks: deduplicateHomebrewCasks,
            excludeMacAppStoreReceipts: macAppStoreCoverageEnabled
        )
        let allChecks = checks + vendorChecks
        let issues = allChecks.compactMap(\.issue) + Self.uncoveredIssues(for: uncovered)
        return ScanResult(items: allChecks.compactMap(\.item), issues: issues)
    }

    /// Inventory entries that no enabled built-in app provider can verify.
    /// These used to disappear silently, making "no updates" look more certain
    /// than it was. Keep the list visible without treating self-managed apps as
    /// a scan failure.
    static func uncoveredApps(
        in apps: [InstalledApp],
        ignoredBundleIDs: Set<String>,
        configuredGitHubBundleIDs: Set<String>,
        officialVendorBundleIDs: Set<String> = [],
        deduplicateHomebrewCasks: Bool,
        excludeMacAppStoreReceipts: Bool = true,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> [InstalledApp] {
        apps.filter { app in
            guard !app.bundleID.hasPrefix("com.apple.") else { return false }
            guard !ignoredBundleIDs.contains(app.bundleID) else { return false }
            guard !configuredGitHubBundleIDs.contains(app.bundleID) else { return false }
            guard !officialVendorBundleIDs.contains(app.bundleID) else { return false }
            guard app.feedURL.map(Self.isUsable) != true else { return false }
            guard !excludeMacAppStoreReceipts
                    || !fileExists("\(app.path)/Contents/_MASReceipt/receipt")
            else { return false }
            guard !deduplicateHomebrewCasks || !HomebrewProvider.managesApp(at: app.path) else {
                return false
            }
            return true
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func uncoveredIssues(for apps: [InstalledApp]) -> [ScanIssue] {
        apps.map { app in
            ScanIssue(
                source: .sparkleApp,
                subject: app.name,
                message: "Version \(app.shortVersion) uses an unknown or self-managed updater; "
                    + "Update Scout could not verify it.",
                severity: .skipped,
                iconPath: app.path,
                identity: app.path
            )
        }
    }
}

/// Apps you've pinned to a GitHub repo yourself.
///
/// Reads `~/.config/updatescout/github-apps.json`:
/// ```json
/// { "com.example.MyApp": "owner/repo" }
/// ```
/// Keys are bundle identifiers; values are GitHub `owner/repo` slugs.
struct GitHubAppProvider: UpdateProvider {
    let kind: SourceKind = .githubApp
    let ignoredBundleIDs: Set<String>

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/updatescout/github-apps.json")
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.configURL.path) }

    private struct PinnedApp: Sendable {
        let app: InstalledApp
        let repo: String
    }

    private struct ReleaseCheck: Sendable {
        let item: UpdateItem?
        let issue: ScanIssue?
    }

    static func configuredBundleIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: configURL),
              let mapping = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [] }
        return Set(mapping.keys)
    }

    func scan() async -> ScanResult {
        guard isAvailable,
              let data = try? Data(contentsOf: Self.configURL),
              let mapping = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !mapping.isEmpty
        else { return ScanResult() }

        let apps = AppInventory.scan()
        let pinned: [PinnedApp] = apps.compactMap { app in
            guard let repo = mapping[app.bundleID] else { return nil }
            guard !ignoredBundleIDs.contains(app.bundleID) else { return nil }
            return PinnedApp(app: app, repo: repo)
        }

        let checks = await Registries.mapConcurrently(pinned, limit: 4) { pinned -> ReleaseCheck? in
            guard let release = await Registries.githubLatestRelease(pinned.repo) else {
                return ReleaseCheck(
                    item: nil,
                    issue: ScanIssue(
                        source: .githubApp,
                        subject: pinned.app.name,
                        message: "Could not check the configured GitHub release page.",
                        severity: .failed,
                        iconPath: pinned.app.path,
                        identity: pinned.app.path
                    )
                )
            }
            let tag = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            guard Version.isNewer(tag, than: pinned.app.shortVersion) else {
                return ReleaseCheck(item: nil, issue: nil)
            }
            return ReleaseCheck(
                item: UpdateItem(
                    source: .githubApp,
                    name: pinned.app.name,
                    installedVersion: pinned.app.shortVersion,
                    latestVersion: tag,
                    upgradeCommand: nil,
                    infoURL: release.url ?? URL(string: "https://github.com/\(pinned.repo)/releases"),
                    ignoreKey: pinned.app.bundleID,
                    iconPath: pinned.app.path
                ),
                issue: nil
            )
        }
        return ScanResult(
            items: checks.compactMap(\.item),
            issues: checks.compactMap(\.issue)
        )
    }
}
