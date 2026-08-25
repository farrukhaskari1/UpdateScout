import AppKit
import Foundation

/// Builds a short-lived, user-visible Terminal script for confirmed updates.
///
/// Update commands intentionally run in Terminal instead of a hidden child
/// process: users can see every command, answer password prompts, and inspect
/// any failure before closing the window.
enum TerminalUpdateScript {
    static func run(items: [UpdateItem]) throws {
        let runnable = items.filter { $0.upgradeCommand != nil }
        guard !runnable.isEmpty else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateScout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let scriptURL = directory
            .appendingPathComponent("update-\(UUID().uuidString).command")
        let script = content(for: runnable, scriptPath: scriptURL.path)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-a", "Terminal", scriptURL.path]
        try launcher.run()
    }

    static func content(for items: [UpdateItem], scriptPath: String) -> String {
        let runnable = items.compactMap { item -> (String, String)? in
            guard let command = item.upgradeCommand else { return nil }
            return (item.name, command)
        }

        let itemWord = runnable.count == 1 ? "item" : "items"
        let heading = "UpdateScout — updating \(runnable.count) \(itemWord)"
        var lines = [
            "#!/bin/zsh",
            "export PATH=\(Shell.quoteArgument(Shell.searchPath))",
            "updatescout_failures=0",
            "clear",
            "printf '%s\\n' \(Shell.quoteArgument(heading))",
            "printf '%s\\n' 'Keep this window open until the updates finish.'"
        ]

        for (index, entry) in runnable.enumerated() {
            lines.append("")
            lines.append("printf '\\n[%d/%d] %s\\n' \(index + 1) \(runnable.count) \(Shell.quoteArgument(entry.0))")
            lines.append(entry.1)
            lines.append("if [[ $? -ne 0 ]]; then updatescout_failures=$((updatescout_failures + 1)); fi")
        }

        lines += [
            "",
            "rm -f -- \(Shell.quoteArgument(scriptPath))",
            "rmdir -- \(Shell.quoteArgument(URL(fileURLWithPath: scriptPath).deletingLastPathComponent().path)) 2>/dev/null || true",
            "printf '\\n'",
            "if (( updatescout_failures == 0 )); then",
            "  printf '%s\\n' 'All updates finished.'",
            "else",
            "  printf '%d update(s) failed. Review the output above.\\n' $updatescout_failures",
            "fi",
            "printf '%s\\n' 'You can close this window.'",
            ""
        ]
        return lines.joined(separator: "\n")
    }
}
