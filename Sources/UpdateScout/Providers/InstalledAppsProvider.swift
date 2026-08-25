import Foundation

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

    private static let cacheLock = NSLock()
    private static var cache: (apps: [InstalledApp], stamp: Date)?

    /// Walking every bundle costs a few hundred plist reads, and two providers
    /// need the same list, so results are reused for a minute.
    static func scan() -> [InstalledApp] {
        cacheLock.lock()
        if let cache, Date().timeIntervalSince(cache.stamp) < 60 {
            let apps = cache.apps
            cacheLock.unlock()
            return apps
        }
        cacheLock.unlock()

        let apps = walk()

        cacheLock.lock()
        cache = (apps, Date())
        cacheLock.unlock()
        return apps
    }

    private static func walk() -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        var seenPaths = Set<String>()

        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = "\(root)/\(entry)"
                guard seenPaths.insert(path).inserted else { continue }
                if let app = read(at: path) { apps.append(app) }
            }
        }
        return apps
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
    var isAvailable: Bool { true }

    /// Feeds we should not hit: Apple's own apps and anything with an https-less URL.
    private func isUsable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        return true
    }

    func scan() async -> ScanResult {
        let apps = AppInventory.scan().filter { app in
            guard let feed = app.feedURL, isUsable(feed) else { return false }
            guard !app.bundleID.hasPrefix("com.apple.") else { return false }
            // Homebrew already reports its own casks; don't double-list.
            guard !HomebrewProvider.managesApp(named: app.name) else { return false }
            guard !UserSettings.shared.isIgnored(app.bundleID) else { return false }
            return true
        }

        let items = await Registries.mapConcurrently(apps, limit: 6) { app -> UpdateItem? in
            guard let feed = app.feedURL,
                  let data = await Registries.data(from: feed)
            else { return nil }

            let entries = AppcastParser.parse(data)
            guard let best = AppcastParser.bestEntry(in: entries) else { return nil }

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
            guard isNewer else { return nil }

            let displayLatest = latestShort ?? latestBuild ?? "?"
            // If the marketing version didn't move, show the build numbers instead —
            // "3.4.1 → 3.4.1" would be useless.
            let showBuilds = displayLatest == app.shortVersion
            return UpdateItem(
                source: .sparkleApp,
                name: app.name,
                installedVersion: showBuilds ? app.buildVersion : app.shortVersion,
                latestVersion: showBuilds ? (latestBuild ?? displayLatest) : displayLatest,
                upgradeCommand: nil,
                infoURL: best.link ?? feed,
                ignoreKey: app.bundleID,
                iconPath: app.path
            )
        }

        return ScanResult(items: items, issues: [])
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

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/updatescout/github-apps.json")
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.configURL.path) }

    func scan() async -> ScanResult {
        guard isAvailable,
              let data = try? Data(contentsOf: Self.configURL),
              let mapping = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !mapping.isEmpty
        else { return ScanResult() }

        let apps = AppInventory.scan()
        let pinned: [PackageRef] = apps.compactMap { app in
            guard let repo = mapping[app.bundleID] else { return nil }
            guard !UserSettings.shared.isIgnored(app.bundleID) else { return nil }
            return PackageRef(name: app.name,
                              version: app.shortVersion,
                              extra: repo,
                              bundleID: app.bundleID)
        }

        let items = await Registries.mapConcurrently(pinned, limit: 4) { entry -> UpdateItem? in
            guard let repo = entry.extra,
                  let release = await Registries.githubLatestRelease(repo)
            else { return nil }
            let tag = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            guard Version.isNewer(tag, than: entry.version) else { return nil }
            return UpdateItem(
                source: .githubApp,
                name: entry.name,
                installedVersion: entry.version,
                latestVersion: tag,
                upgradeCommand: nil,
                infoURL: release.url ?? URL(string: "https://github.com/\(repo)/releases"),
                ignoreKey: entry.bundleID,
                iconPath: AppInventory.matchPath(for: entry.name)
            )
        }
        return ScanResult(items: items, issues: [])
    }
}
