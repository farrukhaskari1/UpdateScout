import Foundation
import Testing
@testable import UpdateScout

struct TerminalUpdateScriptTests {
    @Test
    func quotesShellArguments() {
        #expect(Shell.quoteArgument("plain") == "'plain'")
        #expect(Shell.quoteArgument("it's complicated") == "'it'\\''s complicated'")
        #expect(Shell.quoteArgument("$(touch /tmp/nope)") == "'$(touch /tmp/nope)'")
    }

    @Test
    func generatesVisibleSequentialUpdateScript() {
        let item = UpdateItem(
            source: .custom,
            name: "Tool'; touch /tmp/nope; '",
            installedVersion: "1.0",
            latestVersion: "2.0",
            upgradeCommand: "tool upgrade 'safe-name'",
            infoURL: nil
        )
        let script = TerminalUpdateScript.content(
            for: [item],
            scriptPath: "/tmp/Update Scout/it's.command"
        )

        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("tool upgrade 'safe-name'"))
        #expect(script.contains("updatescout_failures"))
        #expect(script.contains("rm -f -- '/tmp/Update Scout/it'\\''s.command'"))
        #expect(!script.contains("echo \"Tool'; touch"))
    }
}
