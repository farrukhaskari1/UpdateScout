import Foundation

/// Binaries installed with `cargo install`, checked against crates.io.
struct CargoProvider: UpdateProvider {
    let kind: SourceKind = .cargo
    var isAvailable: Bool { Shell.has("cargo") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }
        guard let result = await Shell.runAsync("cargo", ["install", "--list"], timeout: 120) else {
            return issue("Could not run `cargo install --list`.")
        }
        guard result.ok else { return issue(result.stderr.nonEmpty ?? "`cargo install --list` failed.") }

        let installed = Self.installedPackages(result.stdout)
        let items = await Registries.mapConcurrently(installed) { entry -> UpdateItem? in
            guard let latest = await Registries.cratesLatest(entry.name),
                  Version.isNewer(latest, than: entry.version)
            else { return nil }
            return UpdateItem(
                source: .cargo, name: entry.name, installedVersion: entry.version,
                latestVersion: latest, upgradeCommand: "cargo install \(Shell.quoteArgument(entry.name)) --force",
                infoURL: URL(string: "https://crates.io/crates/\(entry.name)")
            )
        }
        return ScanResult(items: items, issues: [])
    }

    static func installedPackages(_ output: String) -> [PackageRef] {
        var installed: [PackageRef] = []
        for line in output.split(separator: "\n") {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let cleaned = line.replacingOccurrences(of: ":", with: "")
            let parts = cleaned.split(separator: " ").map(String.init)
            guard parts.count >= 2, parts[1].hasPrefix("v") else { continue }
            // Skip git/path installs — crates.io has nothing to say about them.
            guard !cleaned.contains("(") else { continue }
            installed.append(PackageRef(name: parts[0], version: String(parts[1].dropFirst())))
        }

        return installed
    }
}

/// Binaries in GOBIN/GOPATH/bin, checked against the Go module proxy.
struct GoBinaryProvider: UpdateProvider {
    let kind: SourceKind = .golang
    var isAvailable: Bool { Shell.has("go") }

    func scan() async -> ScanResult {
        guard isAvailable else { return ScanResult() }

        // Where does `go install` put things?
        var binDir: String?
        if let env = await Shell.runAsync("go", ["env", "GOBIN"], timeout: 30) {
            let value = env.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { binDir = value }
        }
        if binDir == nil, let env = await Shell.runAsync("go", ["env", "GOPATH"], timeout: 30) {
            let value = env.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { binDir = "\(value)/bin" }
        }
        guard let binDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: binDir),
              !names.isEmpty
        else { return ScanResult() }

        // `go version -m <binary>` reveals the module path and version it was built from.
        var installed: [PackageRef] = []
        for name in names {
            let path = "\(binDir)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let info = await Shell.runAsync("go", ["version", "-m", path], timeout: 30), info.ok else { continue }

            var modulePath: String?
            var moduleVersion: String?
            for line in info.stdout.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                    .map(String.init)
                    .filter { !$0.isEmpty }
                guard fields.count >= 3, fields[0] == "mod" else { continue }
                modulePath = fields[1]
                moduleVersion = fields[2]
                break
            }
            guard let modulePath, let moduleVersion, moduleVersion.hasPrefix("v"),
                  !moduleVersion.contains("devel")
            else { continue }
            installed.append(PackageRef(name: name, version: moduleVersion, extra: modulePath))
        }

        let items = await Registries.mapConcurrently(installed) { entry -> UpdateItem? in
            guard let module = entry.extra,
                  let latest = await Registries.goModuleLatest(module),
                  Version.isNewer(latest, than: entry.version)
            else { return nil }
            let upgradeTarget = Shell.quoteArgument("\(module)@latest")
            return UpdateItem(
                source: .golang,
                name: entry.name,
                installedVersion: entry.version,
                latestVersion: latest,
                upgradeCommand: "go install \(upgradeTarget)",
                infoURL: URL(string: "https://pkg.go.dev/\(module)")
            )
        }
        return ScanResult(items: items, issues: [])
    }
}
