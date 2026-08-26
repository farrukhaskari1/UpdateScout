@preconcurrency import Foundation
import os

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

enum ShellError: Error { case notFound(String) }

/// Runs external tools with the user's real login PATH.
enum Shell {
    private static let pathCache = OSAllocatedUnfairLock(initialState: String?.none)
    private static let whichCache = OSAllocatedUnfairLock(initialState: [String: String?]())
    private static let fallbackPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "/opt/local/bin", "/opt/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    static var searchPath: String {
        if let cached = pathCache.withLock({ $0 }) { return cached }
        var parts: [String] = []
        if let result = try? runRaw(
            executable: "/bin/zsh", arguments: ["-lc", "printf %s \"$PATH\""],
            environment: ProcessInfo.processInfo.environment, timeout: 20
        ), result.ok {
            parts += result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":").map(String.init)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        parts += [
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin",
            "\(home)/.mise/shims", "\(home)/.asdf/shims", "\(home)/.rbenv/shims",
            "\(home)/.pyenv/shims", "\(home)/.bun/bin", "\(home)/.volta/bin",
            "\(home)/Library/Application Support/Herd/bin"
        ]
        parts += fallbackPath
        var seen = Set<String>()
        let resolved = parts.filter { seen.insert($0).inserted && !$0.isEmpty }.joined(separator: ":")
        return pathCache.withLock { cached in
            if let cached { return cached }
            cached = resolved
            return resolved
        }
    }

    static var childEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["LANG"] = "en_US.UTF-8"
        return environment
    }

    static func which(_ name: String) -> String? {
        let cached = whichCache.withLock { cache -> (Bool, String?) in
            (cache.keys.contains(name), cache[name] ?? nil)
        }
        if cached.0 { return cached.1 }
        let fileManager = FileManager.default
        var found = searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first(where: fileManager.isExecutableFile(atPath:))
        // Homebrew's Ruby is keg-only, so its `gem` may not be in PATH. Prefer
        // it only when PATH otherwise falls back to Apple's protected runtime;
        // an explicit mise/rbenv/asdf choice still wins.
        if (name == "gem" || name == "ruby"),
           found?.hasPrefix("/usr/bin/") == true || found?.hasPrefix("/System/") == true {
            found = [
                "/opt/homebrew/opt/ruby/bin/\(name)",
                "/usr/local/opt/ruby/bin/\(name)"
            ].first(where: fileManager.isExecutableFile(atPath:)) ?? found
        }
        let resolved = found
        whichCache.withLock { $0[name] = resolved }
        return resolved
    }

    static func has(_ name: String) -> Bool { which(name) != nil }

    /// Newly installed runtimes and package managers must be discoverable by
    /// the refresh that follows an in-app setup action.
    static func invalidateExecutableCache() {
        pathCache.withLock { $0 = nil }
        whichCache.withLock { $0.removeAll() }
    }

    /// Quote one value as a literal zsh argument. Used for generated scripts,
    /// never for an entire command line.
    static func quoteArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Replace a command-template placeholder with one safely quoted argument.
    /// Existing templates often wrap `{name}` in their own single or double
    /// quotes; remove that wrapper first so the quotes don't become data.
    static func replacingShellPlaceholder(
        in template: String,
        placeholder: String,
        with value: String
    ) -> String {
        let quoted = quoteArgument(value)
        return template
            .replacingOccurrences(of: "\"\(placeholder)\"", with: quoted)
            .replacingOccurrences(of: "'\(placeholder)'", with: quoted)
            .replacingOccurrences(of: placeholder, with: quoted)
    }

    static func requiresAdministratorPrivileges(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "sudo" || trimmed.hasPrefix("sudo ")
    }

    static func isPermissionFailure(_ result: CommandResult) -> Bool {
        let message = (result.stderr + "\n" + result.stdout).lowercased()
        return [
            "permission denied", "operation not permitted", "not authorized",
            "authorization denied", "user canceled", "must be root",
            "requires root", "password is required", "no tty present"
        ].contains { message.contains($0) }
    }

    /// Run one confirmed update. Ordinary commands stay under the current user;
    /// a leading `sudo` is replaced by the standard macOS administrator prompt.
    static func runUpdateCommand(
        _ command: String,
        allowAdministratorPrivileges: Bool = false,
        timeout: TimeInterval = 30 * 60
    ) async -> CommandResult? {
        if requiresAdministratorPrivileges(command) {
            guard allowAdministratorPrivileges,
                  let privilegedCommand = trustedPrivilegedCommand(command)
            else {
                return CommandResult(
                    stdout: "",
                    stderr: "Authorization denied: administrator execution is not available for this update source.",
                    exitCode: 77
                )
            }
            return await runRawAsync(
                executable: "/usr/bin/osascript",
                arguments: [
                    "-e", "on run argv",
                    "-e", "do shell script (item 1 of argv) with administrator privileges",
                    "-e", "end run",
                    "--", privilegedCommand
                ],
                timeout: timeout
            )
        }

        return await runRawAsync(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            timeout: timeout
        )
    }

    /// Only built-in providers with known root-owned executables may elevate.
    /// Custom commands still get the Copy Command fallback.
    static func trustedPrivilegedCommand(_ command: String) -> String? {
        let stripped = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst("sudo".count)
            .trimmingCharacters(in: .whitespaces)
        let executables = [
            "softwareupdate": "/usr/sbin/softwareupdate",
            "port": "/opt/local/bin/port"
        ]

        for (name, path) in executables where stripped == name || stripped.hasPrefix("\(name) ") {
            guard isRootOwnedExecutable(path) else { return nil }
            return quoteArgument(path) + String(stripped.dropFirst(name.count))
        }
        return nil
    }

    private static func isRootOwnedExecutable(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return owner.intValue == 0 && permissions.intValue & 0o022 == 0
    }

    static func conciseError(from result: CommandResult) -> String {
        let raw = result.stderr.nonEmpty ?? result.stdout.nonEmpty ?? "Command exited with status \(result.exitCode)."
        let singleLine = raw
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(220))
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> CommandResult {
        guard let executable = which(tool) else { throw ShellError.notFound(tool) }
        return try runRaw(executable: executable, arguments: arguments, environment: childEnvironment, timeout: timeout)
    }

    static func runAsync(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) async -> CommandResult? {
        guard let executable = which(tool) else { return nil }
        return await runRawAsync(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Cancelling the caller terminates the current subprocess, escalating to
    /// SIGKILL only if that same process is still alive three seconds later.
    static func runRawAsync(
        executable: String, arguments: [String], timeout: TimeInterval = 120
    ) async -> CommandResult? {
        let execution = ProcessExecution(
            executable: executable, arguments: arguments,
            environment: childEnvironment, timeout: timeout
        )
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: try? execution.run())
                }
            }
        } onCancel: {
            execution.cancel()
        }
        return Task.isCancelled ? nil : result
    }

    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    static func runRaw(
        executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) throws -> CommandResult {
        try ProcessExecution(
            executable: executable, arguments: arguments, environment: environment, timeout: timeout
        ).run()
    }
}

/// Foundation's process types predate Sendable. This wrapper is their explicit
/// synchronization boundary and is single-use.
private final class ProcessExecution: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let timeout: TimeInterval
    private let processState = OSAllocatedUnfairLock(initialState: Process?.none)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    func run() throws -> CommandResult {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let output = ProcessOutput()
        let group = DispatchGroup()
        drain(stdoutPipe, into: output, stream: .stdout, group: group)
        drain(stderrPipe, into: output, stream: .stderr, group: group)

        processState.withLock { $0 = process }
        if cancelled.withLock({ $0 }) {
            processState.withLock { $0 = nil }
            throw CancellationError()
        }
        do { try process.run() } catch {
            processState.withLock { $0 = nil }
            throw error
        }
        if cancelled.withLock({ $0 }) { terminateCurrentProcess() }

        let watchdog = DispatchWorkItem { [self] in terminateCurrentProcess() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()
        processState.withLock { $0 = nil }

        let captured = output.snapshot()
        return CommandResult(
            stdout: String(decoding: captured.stdout, as: UTF8.self),
            stderr: String(decoding: captured.stderr, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        terminateCurrentProcess()
    }

    private func terminateCurrentProcess() {
        let processID: pid_t? = processState.withLock { process in
            guard let process, process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        guard let processID else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in
            processState.withLock { process in
                guard let process, process.processIdentifier == processID, process.isRunning else { return }
                kill(processID, SIGKILL)
            }
        }
    }

    private func drain(_ pipe: Pipe, into output: ProcessOutput, stream: ProcessOutput.Stream, group: DispatchGroup) {
        let reader = PipeReader(pipe: pipe, output: output, stream: stream)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            reader.readToEnd()
            group.leave()
        }
    }
}

private final class PipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private let output: ProcessOutput
    private let stream: ProcessOutput.Stream

    init(pipe: Pipe, output: ProcessOutput, stream: ProcessOutput.Stream) {
        self.pipe = pipe
        self.output = output
        self.stream = stream
    }

    func readToEnd() {
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            guard !chunk.isEmpty else { return }
            // Continue draining even after the retained prefix is full. That
            // prevents a noisy child from blocking on its pipe without letting
            // an update command turn arbitrary output into arbitrary memory use.
            output.append(chunk, to: stream)
        }
    }
}

private final class ProcessOutput: Sendable {
    enum Stream: Sendable { case stdout, stderr }
    private struct State: Sendable { var stdout = Data(); var stderr = Data() }
    private static let maximumBytesPerStream = 16 * 1_024 * 1_024
    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ data: Data, to stream: Stream) {
        state.withLock {
            switch stream {
            case .stdout:
                let remaining = max(0, Self.maximumBytesPerStream - $0.stdout.count)
                if remaining > 0 { $0.stdout.append(data.prefix(remaining)) }
            case .stderr:
                let remaining = max(0, Self.maximumBytesPerStream - $0.stderr.count)
                if remaining > 0 { $0.stderr.append(data.prefix(remaining)) }
            }
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data) { state.withLock { ($0.stdout, $0.stderr) } }
}
