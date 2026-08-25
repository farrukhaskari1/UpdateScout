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
        let found = searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first(where: fileManager.isExecutableFile(atPath:))
        whichCache.withLock { $0[name] = found }
        return found
    }

    static func has(_ name: String) -> Bool { which(name) != nil }

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

    func readToEnd() { output.append(pipe.fileHandleForReading.readDataToEndOfFile(), to: stream) }
}

private final class ProcessOutput: Sendable {
    enum Stream: Sendable { case stdout, stderr }
    private struct State: Sendable { var stdout = Data(); var stderr = Data() }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ data: Data, to stream: Stream) {
        state.withLock {
            switch stream {
            case .stdout: $0.stdout.append(data)
            case .stderr: $0.stderr.append(data)
            }
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data) { state.withLock { ($0.stdout, $0.stderr) } }
}
