import Foundation
import Testing
@testable import UpdateScout

struct ProviderParserTests {
    @Test func parsesHomebrewJSONVariants() throws {
        let items = try #require(HomebrewProvider.parse(try TestFixture.data("homebrew", extension: "json")))
        #expect(items.map(\.name) == ["ripgrep", "raycast"])
        #expect(items[0].upgradeCommand == "brew upgrade 'ripgrep'")
        #expect(items[1].source == .homebrewCask)
    }

    @Test func selectsRequestedUnpinnedCoreFormulaeForFreshnessCheck() throws {
        let json = #"""
        {"formulae":[
          {"name":"llmfit","tap":"homebrew/core","pinned":false,
           "installed":[{"version":"1.1.10","installed_on_request":true}]},
          {"name":"dependency","tap":"homebrew/core","pinned":false,
           "installed":[{"version":"2.0","installed_on_request":false}]},
          {"name":"held","tap":"homebrew/core","pinned":true,
           "installed":[{"version":"3.0","installed_on_request":true}]},
          {"name":"custom","tap":"owner/tap","pinned":false,
           "installed":[{"version":"4.0","installed_on_request":true}]}
        ]}
        """#.data(using: .utf8)!

        #expect(HomebrewProvider.installedRequestedFormulae(from: json) == [
            HomebrewProvider.InstalledFormula(name: "llmfit", version: "1.1.10")
        ])
    }

    /// Mirrors the shape `brew info --json=v2 --cask --installed` actually emits:
    /// the rename target is a dictionary *inside* the `app` array, not a key on
    /// the artifact. An earlier fixture put it on the artifact, which let a
    /// parser that couldn't read real Homebrew output pass.
    @Test func parsesExactApplicationArtifactsFromInstalledCasks() {
        let json = #"""
        {"casks":[
          {"token":"example","artifacts":[
            {"app":["Example.app",{"target":"/Applications/Example Renamed.app"}]},
            {"binary":["example"]}
          ]},
          {"token":"plain","artifacts":[{"app":["Plain.app"]}]},
          {"token":"cli-only","artifacts":[{"binary":["tool"]}]}
        ]}
        """#.data(using: .utf8)!

        #expect(HomebrewProvider.installedCaskApps(from: json) ==
            HomebrewProvider.InstalledCaskApps(
                paths: ["/Applications/Example Renamed.app"],
                fileNames: ["Example.app", "Example Renamed.app", "Plain.app"]
            ))
    }

    /// A cask that carries `target` on the artifact itself still resolves.
    @Test func parsesLegacyTargetOnArtifact() {
        let json = #"""
        {"casks":[
          {"token":"legacy","artifacts":[
            {"app":["Legacy.app"],"target":"/Applications/Legacy Renamed.app"}
          ]}
        ]}
        """#.data(using: .utf8)!

        let inventory = HomebrewProvider.installedCaskApps(from: json)
        #expect(inventory.paths.contains("/Applications/Legacy Renamed.app"))
        #expect(inventory.fileNames.contains("Legacy.app"))
    }

    @Test func parsesMacAppStoreArrows() throws {
        let items = MacAppStoreProvider.parse(try TestFixture.text("mas", extension: "txt"))
        #expect(items.count == 2)
        #expect(items[0].installedVersion == "15.0")
        #expect(items[1].latestVersion == "2.1")
    }

    @Test func parsesMiseJSON() throws {
        let items = try #require(MiseProvider.parse(try TestFixture.data("mise", extension: "json")))
        #expect(items.count == 1)
        #expect(items.first?.name == "node")
        #expect(items.first?.latestVersion == "22.5.1")
    }

    @Test func parsesSoftwareUpdates() throws {
        let output = try TestFixture.text("softwareupdate", extension: "txt")
        let items = SystemUpdateProvider.parseListOutput(output, installedOS: "15.5.0")
        #expect(items.count == 2)
        #expect(items[0].installedVersion == "15.5.0")
        #expect(items[1].installedVersion == "—")
    }

    @Test func choosesNewestFullInstaller() throws {
        let output = try TestFixture.text("full-installers", extension: "txt")
        let best = try #require(SystemUpdateProvider.bestFullInstaller(in: output))
        #expect(best.title == "macOS Sequoia")
        #expect(best.version == "15.6")
    }

    @Test func parsesStableCompatibleAppcast() throws {
        let entries = AppcastParser.parse(try TestFixture.data("appcast", extension: "xml"))
        let best = try #require(AppcastParser.bestEntry(in: entries))
        #expect(best.shortVersion == "2.5")
        #expect(best.link?.absoluteString == "https://example.com/releases/2.5")
    }

    @Test func surfacesOnlyAppsWithoutAUsableUpdateSource() {
        func app(_ name: String, id: String, path: String? = nil, feed: String? = nil) -> InstalledApp {
            InstalledApp(
                name: name,
                bundleID: id,
                path: path ?? "/Applications/\(name).app",
                shortVersion: "1.0",
                buildVersion: "1",
                feedURL: feed.flatMap(URL.init(string:))
            )
        }

        let uncovered = SparkleAppProvider.uncoveredApps(
            in: [
                app("Manual", id: "com.example.manual"),
                app("Sparkle", id: "com.example.sparkle", feed: "https://example.com/feed.xml"),
                app("Unsafe Feed", id: "com.example.http", feed: "http://example.com/feed.xml"),
                app("Pinned", id: "com.example.pinned"),
                app("Store", id: "com.example.store"),
                app("Apple", id: "com.apple.example")
            ],
            ignoredBundleIDs: [],
            configuredGitHubBundleIDs: ["com.example.pinned"],
            deduplicateHomebrewCasks: false,
            fileExists: { $0.contains("Store.app/Contents/_MASReceipt") }
        )

        #expect(uncovered.map(\.name) == ["Manual", "Unsafe Feed"])
        let issues = SparkleAppProvider.uncoveredIssues(for: uncovered)
        #expect(issues.map(\.subject) == ["Manual", "Unsafe Feed"])
        #expect(issues.allSatisfy { $0.severity == .skipped })

        let duplicates = SparkleAppProvider.uncoveredIssues(for: [
            app("Manual", id: "com.example.one", path: "/Applications/Manual.app"),
            app("Manual", id: "com.example.two", path: "/tmp/example-home/Applications/Manual.app")
        ])
        #expect(Set(duplicates.map(\.id)).count == 2)

        let storeAppWithoutStoreCoverage = SparkleAppProvider.uncoveredApps(
            in: [app("Store", id: "com.example.store")],
            ignoredBundleIDs: [],
            configuredGitHubBundleIDs: [],
            deduplicateHomebrewCasks: false,
            excludeMacAppStoreReceipts: false,
            fileExists: { $0.contains("_MASReceipt") }
        )
        #expect(storeAppWithoutStoreCoverage.map(\.name) == ["Store"])
    }

    @Test func mergesApplicationFoldersWithOnlyShallowHomeResults() {
        let paths = AppInventory.candidatePaths(
            folderPaths: [
                "/Applications/Direct.app",
                "/Applications/Folder/Nested.app",
                "/Applications/Unity/Hub/Editor/6000.5/PlaybackEngines/Variations/UnityPlayer.app",
                "/Applications/Host.app/Contents/Helpers/Helper.app"
            ],
            spotlightPaths: [
                "/tmp/example-home/Downloads/Manual.app",
                "/tmp/example-home/Projects/Product/dist/BuildCopy.app",
                "/tmp/example-home/Projects/Build/TooDeep.app",
                "/tmp/example-home/Library/Caches/Cached.app",
                "/tmp/example-home/.hidden/Hidden.app"
            ],
            homeDirectory: "/tmp/example-home"
        )

        #expect(paths == [
            "/Applications/Direct.app",
            "/Applications/Folder/Nested.app",
            "/tmp/example-home/Downloads/Manual.app"
        ])
    }

    @Test func keepsCanonicalApplicationWhenBundleIdentifiersRepeat() {
        func app(_ name: String, id: String, path: String) -> InstalledApp {
            InstalledApp(
                name: name,
                bundleID: id,
                path: path,
                shortVersion: "1.0",
                buildVersion: "1",
                feedURL: nil
            )
        }

        let apps = AppInventory.deduplicatedApps([
            app("Update Scout", id: "com.local.updatescout", path: "/tmp/example-home/Downloads/Update Scout.app"),
            app("Update Scout", id: "com.local.updatescout", path: "/Applications/Update Scout.app"),
            app("Other", id: "com.example.other", path: "/Applications/Other.app")
        ])

        #expect(apps.map(\.path) == [
            "/Applications/Other.app",
            "/Applications/Update Scout.app"
        ])
    }

    @Test func parsesVersionsFromOfficialVendorPages() {
        #expect(Registries.officialAppBundleIDs.contains("io.github.mfat.sshpilot"))
        #expect(Registries.officialAppBundleIDs.contains("org.pqrs.Karabiner-Elements.Settings"))
        #expect(Registries.firstVersion(
            in: Data("<h1>Updated to 8.12.34</h1>".utf8),
            after: "Updated to "
        ) == "8.12.34")
        #expect(Registries.firstVersion(
            in: Data("<h2>Slack 4.51.191</h2>".utf8),
            after: "Slack "
        ) == "4.51.191")
        #expect(Registries.firstVersion(
            in: Data("Updated to beta".utf8),
            after: "Updated to "
        ) == nil)
    }

    @Test func choosesMenuBarIconForMacFamily() {
        #expect(MacHardwareIcon.symbol(machineName: "MacBook Pro", modelIdentifier: "Mac16,7") == "macbook.gen2")
        #expect(MacHardwareIcon.symbol(machineName: "MacBook Air", modelIdentifier: "Mac16,12") == "macbook.gen2")
        #expect(MacHardwareIcon.symbol(machineName: "Mac mini", modelIdentifier: "Mac16,10") == "macmini.gen3.fill")
        #expect(MacHardwareIcon.symbol(machineName: "Mac Studio", modelIdentifier: "Mac15,14") == "macstudio.fill")
        #expect(MacHardwareIcon.symbol(machineName: "iMac", modelIdentifier: "iMac21,1") == "desktopcomputer")
        #expect(MacHardwareIcon.symbol(machineName: "Mac Pro", modelIdentifier: "MacPro7,1") == "macpro.gen3.fill")
    }

    @Test func parsesCurrentSystemProfilerHardwareIdentity() throws {
        let data = Data("""
        {"SPHardwareDataType":[{"machine_name":"MacBook Pro","machine_model":"Mac16,7"}]}
        """.utf8)
        let identity = try #require(MacHardwareIcon.parseIdentity(from: data))
        #expect(identity.name == "MacBook Pro")
        #expect(identity.model == "Mac16,7")
    }

    @Test func extractsVersionFromGoogleResultWithoutRepeatingInstalledVersion() {
        let text = "Example 2.4.1 is available. Previously installed 2.3.0."
        #expect(BulkAppLookup.firstVersion(in: text, excluding: "2.3.0") == "2.4.1")
        #expect(BulkAppLookup.firstVersion(in: "Installed 2.3.0", excluding: "2.3.0") == nil)
    }

    @Test func bulkLookupProvidersIncludeClaudeAndCustomAI() {
        #expect(BulkLookupProvider.claude.title == "Claude")
        #expect(BulkLookupProvider.custom.title == "Custom AI")
    }

    @Test func parsesFencedAIResults() throws {
        let text = """
        ```json
        {"apps":[{"id":"com.example.App","latest_version":"2.0","status":"updateAvailable","summary":"Official release notes list 2.0.","source_url":"https://example.com/releases"}]}
        ```
        """
        let results = try BulkAppLookup.parseLooseResults(text, service: "Test AI")
        #expect(results.count == 1)
        #expect(results.first?.status == .updateAvailable)
        #expect(results.first?.latestVersion == "2.0")
    }

    @Test func customAIEndpointRequiresHTTPSUnlessLocal() throws {
        #expect(try BulkAppLookup.validatedCustomEndpoint("https://ai.example.com/v1/chat/completions").host == "ai.example.com")
        #expect(try BulkAppLookup.validatedCustomEndpoint("http://localhost:11434/v1/chat/completions").host == "localhost")
        #expect(throws: (any Error).self) {
            try BulkAppLookup.validatedCustomEndpoint("http://ai.example.com/v1/chat/completions")
        }
    }

    @Test func parsesRuntimeManagers() throws {
        let rustup = RustupProvider.parse(try TestFixture.text("rustup", extension: "txt"))
        let gems = GemProvider.parse(try TestFixture.text("gem", extension: "txt"))
        let npm = try #require(NpmProvider.parse(try TestFixture.data("npm", extension: "json")))
        let composer = try #require(ComposerProvider.parse(try TestFixture.data("composer", extension: "json")))
        let ports = MacPortsProvider.parse(try TestFixture.text("macports", extension: "txt"))
        #expect(rustup.first?.name == "stable-aarch64-apple-darwin")
        #expect(gems.count == 2)
        #expect(npm.count == 2)
        #expect(composer.first?.name == "laravel/installer")
        #expect(ports.map(\.name) == ["git", "curl"])
    }

    @Test func parsesPythonAndRustInventories() throws {
        let pipx = try #require(PipxProvider.installedPackages(try TestFixture.data("pipx", extension: "json")))
        let uv = UvToolProvider.installedPackages(try TestFixture.text("uv", extension: "txt"))
        let pip = try #require(PipProvider.parse(try TestFixture.data("pip", extension: "json")))
        let cargo = CargoProvider.installedPackages(try TestFixture.text("cargo", extension: "txt"))
        #expect(pipx.first?.name == "ruff")
        #expect(uv.map(\.name) == ["ruff", "black"])
        #expect(pip.first?.upgradeCommand == "pip3 install --upgrade 'requests'")
        #expect(cargo.count == 1)
        #expect(cargo.first?.name == "ripgrep")
    }
}
