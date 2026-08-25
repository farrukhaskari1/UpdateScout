import Foundation

/// pipx-managed CLI tools. pipx can't report latest versions itself, so we ask PyPI.
struct PipxProvider: UpdateProvider {
    let kind: SourceKind = .pipx
    var isAvailable: Bool { Shell.has("pipx") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("pipx", ["list", "--json"], timeout: 120),
              let data = result.stdout.data(using: .utf8),
              let installed = Self.installedPackages(data)
        else {
            return issue("Could not read `pipx list --json`.")
        }

        let items = await Registries.mapConcurrently(installed) { entry -> UpdateItem? in
            guard let latest = await Registries.pypiLatest(entry.name),
                  Version.isNewer(latest, than: entry.version)
            else { return nil }
            return UpdateItem(
                source: .pipx, name: entry.name, installedVersion: entry.version,
                latestVersion: latest, upgradeCommand: "pipx upgrade \(Shell.quoteArgument(entry.name))",
                infoURL: URL(string: "https://pypi.org/project/\(entry.name)/")
            )
        }
        return ScanResult(items: items, issues: [])
    }

    static func installedPackages(_ data: Data) -> [PackageRef]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let venvs = root["venvs"] as? [String: Any] else { return nil }
        var installed: [PackageRef] = []
        for (_, raw) in venvs {
            guard let venv = raw as? [String: Any],
                  let metadata = venv["metadata"] as? [String: Any],
                  let main = metadata["main_package"] as? [String: Any],
                  let name = main["package"] as? String,
                  let version = main["package_version"] as? String
            else { continue }
            installed.append(PackageRef(name: name, version: version))
        }

        return installed
    }
}

/// uv-managed tools (`uv tool install ...`).
struct UvToolProvider: UpdateProvider {
    let kind: SourceKind = .uv
    var isAvailable: Bool { Shell.has("uv") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("uv", ["tool", "list"], timeout: 120) else {
            return issue("Could not run `uv tool list`.")
        }
        guard result.ok else { return issue(result.stderr.nonEmpty ?? "`uv tool list` failed.") }

        let installed = Self.installedPackages(result.stdout)
        let items = await Registries.mapConcurrently(installed) { entry -> UpdateItem? in
            guard let latest = await Registries.pypiLatest(entry.name),
                  Version.isNewer(latest, than: entry.version)
            else { return nil }
            return UpdateItem(
                source: .uv, name: entry.name, installedVersion: entry.version,
                latestVersion: latest, upgradeCommand: "uv tool upgrade \(Shell.quoteArgument(entry.name))",
                infoURL: URL(string: "https://pypi.org/project/\(entry.name)/")
            )
        }
        return ScanResult(items: items, issues: [])
    }

    static func installedPackages(_ output: String) -> [PackageRef] {
        var installed: [PackageRef] = []
        for line in output.split(separator: "\n") {
            guard !line.hasPrefix(" "), !line.hasPrefix("-") else { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let version = parts[1].hasPrefix("v") ? String(parts[1].dropFirst()) : parts[1]
            guard version.first?.isNumber == true else { continue }
            installed.append(PackageRef(name: parts[0], version: version))
        }

        return installed
    }
}

/// Packages in the user's default pip environment.
///
/// Off by default — a system Python's site-packages is usually managed by
/// Homebrew, and upgrading it by hand breaks things.
struct PipProvider: UpdateProvider {
    let kind: SourceKind = .pip
    var isAvailable: Bool { Shell.has("pip3") || Shell.has("pip") }

    /// PEP 668: Homebrew and system Pythons drop an `EXTERNALLY-MANAGED` marker
    /// beside the stdlib. `pip install --upgrade` against one fails outright,
    /// and the `--break-system-packages` override does what it says. Offering a
    /// command that either errors or breaks the install is worse than silence.
    private func externallyManagedMarker(for tool: String) async -> String? {
        guard let python = interpreter(behind: tool) else { return nil }
        guard let result = await Shell.runRawAsync(
            executable: python,
            arguments: ["-c", "import sysconfig,os;p=os.path.join(sysconfig.get_paths()['stdlib'],'EXTERNALLY-MANAGED');print(p if os.path.exists(p) else '')"],
            timeout: 30
        ), result.ok else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The interpreter a pip script actually runs under, read from its shebang.
    ///
    /// Asking `python3` on PATH is not good enough: Homebrew's `pip3` and the
    /// Command Line Tools' `python3` routinely resolve to different prefixes,
    /// and probing the wrong one gives the wrong answer in both directions.
    private func interpreter(behind tool: String) -> String? {
        guard let script = Shell.which(tool) else { return nil }
        if let handle = FileHandle(forReadingAtPath: script) {
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 512)
            if let firstLine = String(decoding: head, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
               firstLine.hasPrefix("#!") {
                // Handle both `#!/path/python3` and `#!/usr/bin/env python3`.
                let parts = firstLine.dropFirst(2)
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                    .map(String.init)
                if let first = parts.first {
                    if first.hasSuffix("/env"), parts.count > 1 {
                        return Shell.which(parts[1])
                    }
                    if FileManager.default.isExecutableFile(atPath: first) { return first }
                }
            }
        }
        return Shell.which("python3") ?? Shell.which("python")
    }

    func scan() async -> ScanResult {
        let tool = Shell.has("pip3") ? "pip3" : "pip"
        guard Shell.has(tool) else { return ScanResult() }

        if await externallyManagedMarker(for: tool) != nil {
            return skipped("This Python is externally managed (PEP 668). Upgrade through Homebrew, pipx, or uv instead.")
        }

        guard let result = await Shell.runAsync(
            tool, ["list", "--outdated", "--format=json", "--disable-pip-version-check"],
            timeout: 240
        ) else {
            return issue("Could not run `\(tool) list --outdated`.")
        }
        guard let data = result.stdout.data(using: .utf8),
              let items = Self.parse(data, tool: tool)
        else { return issue("Unreadable output from `\(tool) list --outdated`.") }
        return ScanResult(items: items, issues: [])
    }

    static func parse(_ data: Data, tool: String = "pip3") -> [UpdateItem]? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var items: [UpdateItem] = []
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let current = entry["version"] as? String,
                  let latest = entry["latest_version"] as? String
            else { continue }
            items.append(UpdateItem(
                source: .pip,
                name: name,
                installedVersion: current,
                latestVersion: latest,
                upgradeCommand: "\(tool) install --upgrade \(Shell.quoteArgument(name))",
                infoURL: URL(string: "https://pypi.org/project/\(name)/")
            ))
        }
        return items
    }
}
