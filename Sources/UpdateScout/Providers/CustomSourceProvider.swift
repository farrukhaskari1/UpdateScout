import Foundation

/// A tool the user taught UpdateScout about, declared in
/// `~/.config/updatescout/sources.json`.
///
/// Two shapes are supported, because CLI tools report versions in two ways:
///
/// **Table mode** — the tool can list what's outdated itself. Give a command
/// and a regex with named groups `name`, `current`, `latest`:
/// ```json
/// {
///   "id": "mytool",
///   "title": "My Tool",
///   "requires": "mytool",
///   "command": ["mytool", "outdated"],
///   "rowPattern": "^(?<name>\\S+)\\s+(?<current>\\S+)\\s+->\\s+(?<latest>\\S+)$",
///   "upgrade": "mytool upgrade {name}"
/// }
/// ```
///
/// **Single-binary mode** — the tool only knows its own version. Give a command
/// that prints it, a regex with a `current` group, and where to look up latest:
/// ```json
/// {
///   "id": "deno",
///   "title": "Deno",
///   "requires": "deno",
///   "command": ["deno", "--version"],
///   "currentPattern": "deno (?<current>[0-9][0-9A-Za-z.+-]*)",
///   "latestFrom": { "github": "denoland/deno" },
///   "upgrade": "deno upgrade"
/// }
/// ```
struct CustomSource: Decodable, Sendable {
    /// Stable identifier, used for the collapse state and the ignore list.
    let id: String
    /// Section heading.
    let title: String
    /// Executable that must exist on PATH for this source to run.
    let requires: String
    /// Command and arguments to run. First element may be a bare tool name.
    let command: [String]
    /// Table mode: regex with `name`, `current`, `latest` named groups.
    let rowPattern: String?
    /// Single-binary mode: regex with a `current` named group.
    let currentPattern: String?
    /// Single-binary mode: where the newest version comes from.
    let latestFrom: LatestSource?
    /// Upgrade command. `{name}` is replaced with the package name.
    let upgrade: String?
    /// Optional page to open from the row.
    let infoURL: String?

    struct LatestSource: Decodable, Sendable {
        /// `owner/repo` — uses the latest GitHub release tag.
        let github: String?
        /// Package name on PyPI.
        let pypi: String?
        /// Crate name on crates.io.
        let crates: String?
        /// Go module path.
        let goModule: String?
    }
}

/// Runs every user-declared source.
struct CustomSourceProvider: UpdateProvider {
    let kind: SourceKind = .custom

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/updatescout/sources.json")
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.configURL.path) }

    /// Deliberately not `Result`: its `Failure` must conform to `Error`, and
    /// the failure here is a message for the user, not a thrown value.
    private enum Loaded: Sendable {
        case success([CustomSource])
        case failure(String)
    }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }

        // Reading the file and probing PATH both hit the disk, so they belong
        // off the cooperative pool like every other provider's setup work.
        let loaded: Loaded = await Shell.offPool {
            do {
                let data = try Data(contentsOf: Self.configURL)
                let decoded = try JSONDecoder().decode([CustomSource].self, from: data)
                return .success(decoded.filter { Shell.has($0.requires) })
            } catch {
                return .failure(error.localizedDescription)
            }
        }

        let sources: [CustomSource]
        switch loaded {
        case .success(let decoded): sources = decoded
        case .failure(let message): return issue("sources.json couldn't be read — \(message)")
        }

        var result = ScanResult()
        for source in sources {
            result = result + (await run(source))
        }
        return result
    }

    // MARK: - One source

    private func run(_ source: CustomSource) async -> ScanResult {
        guard let tool = source.command.first else {
            return issue("\(source.title): `command` is empty.")
        }
        let arguments = Array(source.command.dropFirst())

        guard let output = await Shell.runAsync(tool, arguments, timeout: 180) else {
            return issue("\(source.title): couldn't run `\(source.command.joined(separator: " "))`.")
        }
        let text = output.stdout + "\n" + output.stderr

        let parsed: ScanResult
        if let pattern = source.rowPattern {
            parsed = tableMode(source, text: text, pattern: pattern)
        } else if let pattern = source.currentPattern {
            parsed = await singleBinaryMode(source, text: text, pattern: pattern)
        } else {
            return issue("\(source.title): needs either `rowPattern` or `currentPattern`.")
        }

        // Some outdated commands intentionally exit non-zero when they found
        // updates. Accept useful parsed output, but surface an otherwise empty
        // non-zero response as a failure.
        if !output.ok, parsed.items.isEmpty, parsed.issues.isEmpty {
            return issue("\(source.title): \(output.stderr.nonEmpty ?? "command failed with exit code \(output.exitCode)")")
        }
        return parsed
    }

    /// The tool reported its own outdated list; pull rows out of it.
    private func tableMode(_ source: CustomSource, text: String, pattern: String) -> ScanResult {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return issue("\(source.title): `rowPattern` isn't a valid regular expression.")
        }

        var items: [UpdateItem] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let name = match.group("name", in: text),
                  let current = match.group("current", in: text),
                  let latest = match.group("latest", in: text)
            else { continue }
            guard Version.isNewer(latest, than: current) else { continue }
            items.append(item(source, name: name, current: current, latest: latest))
        }
        return ScanResult(items: items, issues: [])
    }

    /// The tool only knows its own version; ask a registry for the newest.
    private func singleBinaryMode(_ source: CustomSource,
                                  text: String,
                                  pattern: String) async -> ScanResult {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return issue("\(source.title): `currentPattern` isn't a valid regular expression.")
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let current = match.group("current", in: text)
        else {
            return issue("\(source.title): `currentPattern` didn't match the command output.")
        }

        guard let latest = await lookupLatest(source.latestFrom) else {
            return issue("\(source.title): couldn't look up the latest version.")
        }
        guard Version.isNewer(latest, than: current) else { return ScanResult() }

        return ScanResult(
            items: [item(source, name: source.title, current: current, latest: latest)],
            issues: []
        )
    }

    private func lookupLatest(_ from: CustomSource.LatestSource?) async -> String? {
        guard let from else { return nil }
        if let repo = from.github {
            guard let release = await Registries.githubLatestRelease(repo) else { return nil }
            return release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        }
        if let package = from.pypi { return await Registries.pypiLatest(package) }
        if let crate = from.crates { return await Registries.cratesLatest(crate) }
        if let module = from.goModule { return await Registries.goModuleLatest(module) }
        return nil
    }

    private func item(_ source: CustomSource,
                      name: String,
                      current: String,
                      latest: String) -> UpdateItem {
        UpdateItem(
            source: .custom,
            name: name,
            installedVersion: current,
            latestVersion: latest,
            upgradeCommand: source.upgrade.map {
                Shell.replacingShellPlaceholder(in: $0, placeholder: "{name}", with: name)
            },
            infoURL: source.infoURL.flatMap { URL(string: $0.replacingOccurrences(of: "{name}", with: name)) },
            groupID: source.id,
            groupTitle: source.title
        )
    }
}

private extension NSTextCheckingResult {
    /// Named capture group as a String, or nil if it didn't participate.
    func group(_ name: String, in text: String) -> String? {
        let nsRange = range(withName: name)
        guard nsRange.location != NSNotFound,
              let swiftRange = Range(nsRange, in: text)
        else { return nil }
        let value = String(text[swiftRange]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
