import Foundation

/// Result of running an external command.
struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var ok: Bool { exitCode == 0 }
}

enum ShellError: Error {
    case notFound(String)
}

/// Runs external tools with the user's real login PATH.
///
/// A GUI app launched from Finder inherits a minimal PATH (`/usr/bin:/bin:...`),
/// so `brew`, `mise`, `npm` and friends are invisible unless we recover the
/// login shell's PATH once and reuse it.
enum Shell {

    // MARK: - PATH resolution

    private static let pathLock = NSLock()
    private static var cachedPath: String?

    private static let fallbackPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        // MacPorts. Without this, `port` is invisible whenever the login-shell
        // PATH probe fails or the user's rc files aren't zsh.
        "/opt/local/bin", "/opt/local/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/run/current-system/sw/bin",          // Nix
        "/nix/var/nix/profiles/default/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    static var searchPath: String {
        pathLock.lock()
        let cached = cachedPath
        pathLock.unlock()
        if let cached { return cached }

        // The zsh subprocess below takes up to 20 seconds. Holding the lock
        // across it would stall every concurrent `which` call, so we compute
        // first and only lock to publish — a duplicate computation on a cold
        // race is far cheaper than a convoy.
        var parts: [String] = []

        // Ask the login shell what PATH really is.
        if let result = try? runRaw(
            executable: "/bin/zsh",
            arguments: ["-lc", "printf %s \"$PATH\""],
            environment: ProcessInfo.processInfo.environment,
            timeout: 20
        ), result.ok {
            parts += result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":")
                .map(String.init)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        parts += [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.rbenv/shims",
            "\(home)/.pyenv/shims",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/Library/Application Support/Herd/bin"
        ]
        parts += fallbackPath

        // De-duplicate, preserving order.
        var seen = Set<String>()
        let deduped = parts.filter { seen.insert($0).inserted && !$0.isEmpty }

        let joined = deduped.joined(separator: ":")
        pathLock.lock()
        if let winner = cachedPath {
            pathLock.unlock()
            return winner
        }
        cachedPath = joined
        pathLock.unlock()
        return joined
    }

    /// Environment handed to every child process.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // Keep tool output machine-readable and quiet.
        // Homebrew treats these as set/unset, not true/false — "0" would still
        // disable auto-update, and we want fresh metadata.
        env.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    // MARK: - Locating executables

    private static let whichLock = NSLock()
    private static var whichCache: [String: String?] = [:]

    /// Absolute path of `name` on the login PATH, or nil.
    static func which(_ name: String) -> String? {
        whichLock.lock()
        if let cached = whichCache[name] {
            whichLock.unlock()
            return cached
        }
        whichLock.unlock()

        let fm = FileManager.default
        var found: String?
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                found = candidate
                break
            }
        }

        whichLock.lock()
        whichCache[name] = found
        whichLock.unlock()
        return found
    }

    static func has(_ name: String) -> Bool { which(name) != nil }

    // MARK: - Running

    /// Run a tool by name (resolved on the login PATH).
    @discardableResult
    static func run(_ tool: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 120) throws -> CommandResult {
        guard let executable = which(tool) else { throw ShellError.notFound(tool) }
        return try runRaw(executable: executable,
                          arguments: arguments,
                          environment: childEnvironment,
                          timeout: timeout)
    }

    /// Async wrapper that keeps the blocking `waitUntilExit` off the cooperative
    /// thread pool. Swift's concurrency pool has roughly one thread per core, and
    /// a few slow `brew`/`npm` invocations would otherwise starve every other task
    /// — including the URLSession continuations the registry lookups depend on.
    static func runAsync(_ tool: String,
                         _ arguments: [String],
                         timeout: TimeInterval = 120) async -> CommandResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? run(tool, arguments, timeout: timeout))
            }
        }
    }

    /// Same, for tools addressed by absolute path.
    static func runRawAsync(executable: String,
                            arguments: [String],
                            timeout: TimeInterval = 120) async -> CommandResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = try? runRaw(executable: executable,
                                         arguments: arguments,
                                         environment: childEnvironment,
                                         timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

    /// Run a synchronous block off the cooperative pool.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Low-level process runner with a hard timeout and deadlock-free pipe draining.
    static func runRaw(executable: String,
                       arguments: [String],
                       environment: [String: String]?,
                       timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        var outData = Data()
        var errData = Data()
        let dataLock = NSLock()
        let group = DispatchGroup()

        func drain(_ pipe: Pipe, into sink: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                dataLock.lock()
                sink(data)
                dataLock.unlock()
                group.leave()
            }
        }

        drain(outPipe) { outData.append($0) }
        drain(errPipe) { errData.append($0) }

        try process.run()

        // Hard timeout: terminate, then kill.
        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}
