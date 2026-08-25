import Foundation
import Testing
@testable import UpdateScout

struct ShellTests {
    @Test
    func safelyReplacesBareAndQuotedPlaceholders() {
        let value = "package'; touch /tmp/nope; '"
        let expected = "tool upgrade 'package'\\''; touch /tmp/nope; '\\'''"

        #expect(Shell.replacingShellPlaceholder(
            in: "tool upgrade {name}", placeholder: "{name}", with: value
        ) == expected)
        #expect(Shell.replacingShellPlaceholder(
            in: "tool upgrade \"{name}\"", placeholder: "{name}", with: value
        ) == expected)
        #expect(Shell.replacingShellPlaceholder(
            in: "tool upgrade '{name}'", placeholder: "{name}", with: value
        ) == expected)
    }

    @Test
    func detectsAdministratorAndPermissionFailures() {
        #expect(Shell.requiresAdministratorPrivileges("sudo softwareupdate --install update"))
        #expect(Shell.requiresAdministratorPrivileges("  sudo port upgrade tool"))
        #expect(!Shell.requiresAdministratorPrivileges("brew upgrade sudo"))

        let denied = CommandResult(stdout: "", stderr: "User canceled.", exitCode: 1)
        let ordinaryFailure = CommandResult(stdout: "", stderr: "Package not found", exitCode: 1)
        #expect(Shell.isPermissionFailure(denied))
        #expect(!Shell.isPermissionFailure(ordinaryFailure))
    }

    @Test
    func runsOrdinaryUpdateCommandInsideApp() async throws {
        let result = try #require(await Shell.runUpdateCommand("printf updatescout"))
        #expect(result.ok)
        #expect(result.stdout == "updatescout")
    }

    @Test
    func refusesUntrustedPrivilegedCommands() async throws {
        let result = try #require(await Shell.runUpdateCommand(
            "sudo custom-tool update",
            allowAdministratorPrivileges: true
        ))
        #expect(!result.ok)
        #expect(Shell.isPermissionFailure(result))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationTerminatesSubprocess() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            await Shell.runRawAsync(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30"],
                timeout: 60
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value

        #expect(result == nil)
        #expect(start.duration(to: clock.now) < .seconds(5))
    }
}
