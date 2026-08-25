import Testing
@testable import UpdateScout

struct UpdateExecutionStateTests {
    @Test
    func exposesRunnableAndFallbackStates() {
        #expect(UpdateExecutionState.idle.canRun)
        #expect(UpdateExecutionState.failed("Failed").canRun)
        #expect(UpdateExecutionState.permissionRequired("Denied").canRun)
        #expect(!UpdateExecutionState.queued.canRun)
        #expect(!UpdateExecutionState.running.canRun)
        #expect(!UpdateExecutionState.succeeded.canRun)
        #expect(!UpdateExecutionState.stopped("Stopped").canRun)
        #expect(UpdateExecutionState.permissionRequired("Denied").isPermissionRequired)
    }
}
