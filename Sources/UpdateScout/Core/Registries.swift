import Foundation

/// Lookups against public package registries, for tools whose CLI can't tell us
/// the latest version without also installing it.
/// An installed package we want to look up in a registry.
///
/// A named struct rather than a tuple so it is unambiguously `Sendable` when
/// it crosses into a task group.
struct PackageRef: Sendable {
    let name: String
    let version: String
    /// Go module path, GitHub `owner/repo`, or whatever else the provider needs.
    let extra: String?
    /// Bundle identifier, when this ref came from an installed app.
    let bundleID: String?

    init(name: String, version: String, extra: String? = nil, bundleID: String? = nil) {
        self.name = name
        self.version = version
        self.extra = extra
        self.bundleID = bundleID
    }
}

struct OfficialAppRelease: Sendable, Equatable {
    let version: String
    let infoURL: URL
}

enum Registries {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "UpdateScout/1.0 (+macOS menu bar update checker)"]
        return URLSession(configuration: config)
    }()

    private static func json(_ url: URL) async -> Any? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
    }

    /// Latest non-yanked, non-prerelease version on PyPI.
    static func pypiLatest(_ package: String) async -> String? {
        guard let encoded = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://pypi.org/pypi/\(encoded)/json"),
              let root = await json(url) as? [String: Any],
              let info = root["info"] as? [String: Any],
              let version = info["version"] as? String
        else { return nil }
        return version
    }

    /// Latest published version on crates.io.
    static func cratesLatest(_ crate: String) async -> String? {
        guard let encoded = crate.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)"),
              let root = await json(url) as? [String: Any],
              let crateInfo = root["crate"] as? [String: Any]
        else { return nil }
        return (crateInfo["max_stable_version"] as? String) ?? (crateInfo["max_version"] as? String)
    }

    /// Latest tagged version of a Go module via the module proxy.
    static func goModuleLatest(_ modulePath: String) async -> String? {
        // The proxy requires uppercase letters to be escaped as "!" + lowercase.
        let escaped = modulePath.map { char -> String in
            char.isUppercase ? "!\(char.lowercased())" : String(char)
        }.joined()
        guard let url = URL(string: "https://proxy.golang.org/\(escaped)/@latest"),
              let root = await json(url) as? [String: Any],
              let version = root["Version"] as? String
        else { return nil }
        return version
    }

    /// Latest non-draft, non-prerelease release tag for `owner/repo`.
    static func githubLatestRelease(_ repo: String) async -> (tag: String, url: URL?)? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Optional token lifts the 60/hour anonymous rate limit.
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = root["tag_name"] as? String
            else { return nil }
            let page = (root["html_url"] as? String).flatMap(URL.init(string:))
            return (tag, page)
        } catch {
            return nil
        }
    }

    /// Exact vendor-owned release sources for popular apps that use private
    /// self-updaters and do not expose a Sparkle feed in their bundle.
    private static let officialGitHubAppRepositories: [String: String] = [
        "io.github.mfat.sshpilot": "mfat/sshpilot",
        "org.pqrs.Karabiner-Elements.Settings": "pqrs-org/Karabiner-Elements"
    ]

    static let officialAppBundleIDs: Set<String> = Set([
        "com.1password.1password",
        "com.google.Chrome",
        "com.tinyspeck.slackmacgap"
    ]).union(officialGitHubAppRepositories.keys)

    static func officialAppLatest(_ bundleID: String) async -> OfficialAppRelease? {
        switch bundleID {
        case "com.google.Chrome":
            #if arch(arm64)
            let platform = "mac_arm64"
            #else
            let platform = "mac"
            #endif
            guard let url = URL(string: "https://versionhistory.googleapis.com/v1/chrome/platforms/\(platform)/channels/stable/versions?pageSize=1"),
                  let root = await json(url) as? [String: Any],
                  let versions = root["versions"] as? [[String: Any]],
                  let version = versions.first?["version"] as? String,
                  let page = URL(string: "https://chromereleases.googleblog.com/search/label/Stable%20updates")
            else { return nil }
            return OfficialAppRelease(version: version, infoURL: page)

        case "com.1password.1password":
            guard let url = URL(string: "https://releases.1password.com/mac/stable/"),
                  let data = await data(from: url),
                  let version = firstVersion(in: data, after: "Updated to ")
            else { return nil }
            return OfficialAppRelease(version: version, infoURL: url)

        case "com.tinyspeck.slackmacgap":
            guard let url = URL(string: "https://slack.com/release-notes/mac"),
                  let data = await data(from: url),
                  let version = firstVersion(in: data, after: "Slack ")
            else { return nil }
            return OfficialAppRelease(version: version, infoURL: url)

        default:
            guard let repo = officialGitHubAppRepositories[bundleID],
                  let release = await githubLatestRelease(repo)
            else { return nil }
            let version = release.tag.hasPrefix("v")
                ? String(release.tag.dropFirst())
                : release.tag
            guard let page = release.url ?? URL(string: "https://github.com/\(repo)/releases")
            else { return nil }
            return OfficialAppRelease(version: version, infoURL: page)
        }
    }

    /// Extract a dotted numeric version immediately following a stable marker.
    /// Kept pure so vendor-page changes can be covered by fixture tests.
    static func firstVersion(in data: Data, after marker: String) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var remainder = text[...]
        while let markerRange = remainder.range(of: marker) {
            let suffix = remainder[markerRange.upperBound...]
            let version = suffix.prefix { $0.isNumber || $0 == "." }
            if version.first?.isNumber == true, version.last?.isNumber == true {
                return String(version)
            }
            remainder = suffix
        }
        return nil
    }

    /// Current versions published by Homebrew's official API. The complete
    /// catalog is fetched once per scan instead of issuing one request for every
    /// installed formula. Caching is bypassed so this can close the brief gap in
    /// which a release is public but the local Homebrew catalog is still stale.
    static func homebrewFormulaVersions() async -> [String: String]? {
        guard let url = URL(string: "https://formulae.brew.sh/api/formula.json") else {
            return nil
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let formulae = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return nil }
            return formulae.reduce(into: [:]) { result, formula in
                guard let name = formula["name"] as? String,
                      let versions = formula["versions"] as? [String: Any],
                      let stable = versions["stable"] as? String
                else { return }
                let revision = formula["revision"] as? Int ?? 0
                result[name] = revision > 0 ? "\(stable)_\(revision)" : stable
            }
        } catch {
            return nil
        }
    }

    /// Fetch raw bytes (used for Sparkle appcast XML).
    static func data(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Run up to `limit` async lookups at a time.
    static func mapConcurrently<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int = 8,
        transform: @escaping @Sendable (Input) async -> Output?
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        var results: [Output] = []
        var index = 0

        await withTaskGroup(of: Output?.self) { group in
            let initial = min(limit, inputs.count)
            for _ in 0..<initial {
                let input = inputs[index]
                index += 1
                group.addTask { await transform(input) }
            }
            while let finished = await group.next() {
                if let finished { results.append(finished) }
                if index < inputs.count {
                    let input = inputs[index]
                    index += 1
                    group.addTask { await transform(input) }
                }
            }
        }
        return results
    }
}
