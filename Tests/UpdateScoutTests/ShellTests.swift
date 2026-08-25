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
