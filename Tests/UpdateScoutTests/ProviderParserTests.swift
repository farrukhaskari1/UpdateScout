import Foundation
import Testing
@testable import UpdateScout

struct ProviderParserTests {
    @Test func parsesHomebrewJSONVariants() throws {
        let items = try #require(HomebrewProvider.parse(try TestFixture.data("homebrew", extension: "json")))
        #expect(items.map(\.name) == ["ripgrep", "raycast"])
        #expect(items[0].upgradeCommand == "brew upgrade ripgrep")
        #expect(items[1].source == .homebrewCask)
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
        #expect(pip.first?.upgradeCommand == "pip3 install --upgrade requests")
        #expect(cargo.count == 1)
        #expect(cargo.first?.name == "ripgrep")
    }
}
