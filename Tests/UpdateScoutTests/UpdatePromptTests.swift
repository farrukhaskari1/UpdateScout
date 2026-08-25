import Testing
@testable import UpdateScout

struct UpdatePromptTests {
    @Test
    func describesSingleBulkAndRecoveryConfirmations() throws {
        let first = UpdateItem(
            source: .homebrewFormula,
            name: "tool-one",
            installedVersion: "1.0",
            latestVersion: "2.0",
            upgradeCommand: "brew upgrade 'tool-one'",
            infoURL: nil
        )
        let second = UpdateItem(
            source: .pipx,
            name: "tool-two",
            installedVersion: "1.0",
            latestVersion: "2.0",
            upgradeCommand: "pipx upgrade 'tool-two'",
            infoURL: nil
        )

        let single = UpdatePrompt.confirmation(for: [first])
        #expect(single.title == "Update tool-one?")
        #expect(single.confirmLabel == "Update")
        #expect(single.commandPreview == "brew upgrade 'tool-one'")

        let bulk = UpdatePrompt.confirmation(for: [first, second])
        #expect(bulk.title == "Run 2 updates?")
        #expect(bulk.confirmLabel == "Update All")
        #expect(bulk.commandPreview == nil)

        let issue = ScanIssue(
            source: .gem,
            message: "Use a managed Ruby.",
            severity: .skipped,
            recovery: IssueRecovery(label: "Install Ruby", command: "brew install ruby")
        )
        let recovery = try #require(UpdatePrompt.confirmation(for: issue))
        #expect(recovery.title == "Install Ruby?")
        #expect(recovery.confirmLabel == "Install Ruby")
        #expect(recovery.commandPreview == "brew install ruby")
    }
}
