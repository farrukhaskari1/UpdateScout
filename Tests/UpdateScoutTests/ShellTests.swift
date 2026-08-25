import Foundation
import Testing
@testable import UpdateScout

struct ShellTests {
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
