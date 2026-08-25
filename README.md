# UpdateScout

A local-first macOS menu bar app that finds and launches updates for native apps
and developer tools in one place. Every command-based update is confirmed first
and then runs inside the app.

> **Project status:** Source release. Build locally on macOS 13 or later. Signed
> public binaries are planned but are not available yet.

## Why UpdateScout

- One always-visible list for applications and command-line tools.
- Built-in checks for Homebrew, the Mac App Store, macOS, Sparkle, language
  package managers, runtime managers, and more.
- Extensible JSON-defined sources without recompiling the app.
- Local-first operation with no account, analytics, or central inventory server.
- Explicit by design: updates run only after confirmation, with visible progress
  and results. If permission is declined, the command remains available to copy.

## Interface

```
UpdateScout                         ⌕  ⟳  ⚙
┌───────────────────────────────────────────┐
│ ↓  14 updates available                  │
│    5 apps · 9 tools · checked 2m ago     │
└───────────────────────────────────────────┘
─────────────────────────────────────────────
 MACOS SYSTEM                            1
 ● macOS Sequoia          15.5 → 15.6
 HOMEBREW CASKS                          3
 ● raycast                1.82 → 1.85    Update
 ● zed                    0.147 → 0.150  Update
 APPS (SPARKLE)                          2
 ● Bartender              5.0.49 → 5.2   Open
 HOMEBREW FORMULAE                       4
 ● ripgrep                14.1.0 → 14.1.1 Update
 MISE                                    1
 ● node                   20.11.0 → 22.5.1 Update
─────────────────────────────────────────────
 Update All   ⧉                         Quit
```

Click **Update** on a row to review and run its command inside UpdateScout, or use
**Update All** to run every available command in sequence. Apps without a safe
command show **Open** instead, taking you to their normal download page. Copying
commands and opening release notes remain available as secondary actions. Update
confirmation appears inline in the menu so it remains visible and actionable.
The panel stays in front while a confirmation or update is active, then returns
to normal menu-bar behavior when the action finishes.
Apps and command-line tools stay together in one always-expanded list. Search is
kept in the top action row; click the magnifying glass only when you need it.

## Build from source

Requires macOS 13 or later and a Swift 6.2-or-newer Xcode toolchain.

```bash
cd UpdateScout
chmod +x build.sh
./build.sh --install
```

That compiles a release binary, wraps it in `UpdateScout.app`, ad-hoc signs it, copies it to `/Applications`, and launches it. Look for the icon in your menu bar — there is no Dock icon or window.

Without `--install` it just builds into `./dist/UpdateScout.app`.

**To work on it in Xcode:** `xed .` — Xcode opens Swift packages natively. Note that running from Xcode's play button launches the bare binary rather than the bundle, so login-item registration won't work; use `./build.sh --install` for real use.

## What it checks

| Source | How it's checked | Needs |
|---|---|---|
| Homebrew formulae | `brew outdated --json=v2` | `brew` |
| Homebrew casks | same, with `--greedy` | `brew` |
| MacPorts | `port outdated` | `port` |
| Mac App Store | `mas outdated` | `brew install mas` |
| macOS updates | `softwareupdate --list`, plus `--list-full-installers` for major upgrades | built in |
| Apps with Sparkle feeds | reads each `.app`'s `SUFeedURL`, fetches the appcast | built in |
| Apps pinned to GitHub | GitHub releases API | config file, see below |
| mise | `mise outdated --json` | `mise` |
| rustup | `rustup check` | `rustup` |
| npm globals | `npm outdated -g --json` | `npm` |
| pipx | `pipx list --json` + PyPI | `pipx` |
| uv tools | `uv tool list` + PyPI | `uv` |
| pip | `pip list --outdated` | `pip3` — **off by default** |
| RubyGems | `gem outdated` | `gem` |
| cargo | `cargo install --list` + crates.io | `cargo` |
| Go binaries | `go version -m` + proxy.golang.org | `go` |
| Composer globals | `composer global outdated` | `composer` |
| **Anything else you declare** | your command + a regex | see below |

Sources whose tool isn't installed are skipped silently and shown greyed out in Settings.

## Teaching it about a new tool

You don't have to wait for a provider to be written. Settings → **Edit sources.json** creates `~/.config/updatescout/sources.json`, seeded with working examples for Deno, Bun, pkgx, Nix, the GitHub CLI, krew, and Helm. It's re-read on every scan, so no rebuild is needed.

Two shapes, matching the two ways CLI tools report versions.

**Table mode** — the tool can list what's outdated itself. Give a command and a regex with named groups `name`, `current`, `latest`:

```json
{
  "id": "mytool",
  "title": "My Tool",
  "requires": "mytool",
  "command": ["mytool", "outdated"],
  "rowPattern": "^(?<name>\\S+)\\s+(?<current>\\S+)\\s+->\\s+(?<latest>\\S+)$",
  "upgrade": "mytool upgrade {name}"
}
```

**Single-binary mode** — the tool only knows its own version. Give a regex with a `current` group and say where the newest version lives:

```json
{
  "id": "deno",
  "title": "Deno",
  "requires": "deno",
  "command": ["deno", "--version"],
  "currentPattern": "deno (?<current>[0-9][0-9A-Za-z.+-]*)",
  "latestFrom": { "github": "denoland/deno" },
  "upgrade": "deno upgrade"
}
```

`latestFrom` accepts `github` (`owner/repo`), `pypi`, `crates`, or `goModule`. `{name}` in `upgrade` and `infoURL` is replaced with the package name. `requires` gates the whole entry — if that executable isn't on your PATH, the source is skipped without complaint.

Patterns use ICU syntax (`(?<name>…)`), not Python's `(?P<name>…)`. Each entry becomes its own section, keyed on `id`, so two entries can't collide even when they share a title.

### Why pip is off by default

A system or Homebrew Python's `site-packages` is managed by the thing that installed it. Running `pip install --upgrade` against it tends to break the install. Turn it on only if you know your default Python is one you own.

## Sparkle app detection

Most Mac apps distributed outside the App Store use [Sparkle](https://sparkle-project.org), which means their `Info.plist` carries a `SUFeedURL` pointing at an update feed. UpdateScout reads every `.app` in `/Applications`, `/Applications/Utilities`, `~/Applications`, and `/Applications/Setapp`, fetches those feeds, and compares versions.

It skips:

- Apple's own apps (`com.apple.*`)
- anything Homebrew already manages as a cask, so you don't see it twice
- appcast entries on a beta or nightly channel
- entries whose `sparkle:minimumSystemVersion` is newer than your macOS

Apps that don't use Sparkle — Electron apps with bespoke updaters, App Store apps, anything with a custom mechanism — won't appear here. Those either show up under Homebrew or the Mac App Store, or need a GitHub pin.

## Pinning an app to GitHub releases

For an app with no Sparkle feed but a public GitHub repo, create `~/.config/updatescout/github-apps.json`:

```json
{
  "com.example.MyApp": "owner/repo",
  "md.obsidian": "obsidianmd/obsidian-releases"
}
```

Keys are bundle identifiers (`osascript -e 'id of app "Whatever"'` prints one). The Settings pane has a button that creates this file and reveals it in Finder.

Anonymous GitHub API access is limited to 60 requests an hour. If you pin many apps, export a `GITHUB_TOKEN` in your login environment.

## Privacy and security

UpdateScout inventories software locally and contacts the public services needed
to compare versions, including vendor appcasts and package registries. It does
not include analytics, telemetry, advertising, or an UpdateScout-operated
server. Scan results and ignored items remain on your Mac.

An optional `GITHUB_TOKEN` is read from the process environment only to increase
GitHub API limits. It is never written to the repository or application
preferences. Keep tokens out of config files, screenshots, logs, issues, and
pull requests.

The app executes an upgrade command only after you click **Update** or
**Update All** and confirm the prompt. Progress and results remain visible in
the app. Commands that require administrator rights use the standard macOS
authorization prompt; if permission is declined, UpdateScout shows a **Copy
Command** fallback. Elevation is limited to UpdateScout's built-in macOS and
MacPorts commands; privileged custom-source commands are never elevated and are
offered for copying instead. Custom-source upgrade templates are user-controlled
shell commands and should be reviewed before use.

To report a vulnerability, follow [SECURITY.md](SECURITY.md). Please do not put
sensitive security details in a public issue.

## Behaviour

- **Refreshes** when you open the menu (if the last scan is over 15 minutes old) and on a background timer, hourly by default. Change the interval in Settings.
- **Streams results** — Homebrew runs first for cask de-duplication, then up to four independent providers run concurrently.
- **Dot colour** marks the size of the jump: orange for a major version, blue for minor, grey for a patch.
- **Right-click any app row** to stop reporting it — useful for one that misreports its version or that you keep deliberately pinned. Ignored bundle IDs are stored in `UserDefaults`.
- **The refresh button becomes a stop button** mid-scan. Cancelling terminates active provider subprocesses and stops their network tasks.
- **Confirms before updating.** Commands never run from a scan or background timer. They run only after an Update confirmation. Tools such as `sudo softwareupdate` may trigger the standard macOS administrator prompt; declining it leaves a Copy Command fallback.

## Things worth knowing

**First launch is the slow one.** The app recovers your login shell's `PATH` with a `zsh -lc` subprocess so it can find `brew`, `mise`, `npm` and the rest — a GUI app launched from Finder otherwise inherits a bare `PATH` and would find none of them. That result is cached for the process lifetime.

**Version comparison is heuristic.** Package ecosystems disagree about what a version string looks like. The comparator handles the common shapes (`1.2.3`, `2024.06.1`, `1.2.3_1`, `3.1.0-beta.2`) and treats prerelease tags as older than the bare release. Occasionally a project with an unusual scheme will produce a false positive; the fix is to ignore that row rather than to trust it blindly.

**`brew outdated --greedy` includes self-updating casks.** Apps that update themselves get listed here too. They're filtered when Homebrew records their version as `latest`, but some will still show up and then quietly update themselves before you get to them.

**Launch at login** uses `SMAppService`, which needs the app to live in `/Applications` and carry a signature. The ad-hoc signature from `build.sh` is enough. If you move the bundle after enabling it, toggle it off and on again.

## Layout

```
Sources/UpdateScout/
  UpdateScoutApp.swift        @main, MenuBarExtra, app delegate
  Core/
    Shell.swift               login-PATH recovery, timeout-safe subprocesses
    Version.swift             the version comparator
    Models.swift              UpdateItem, SourceKind, UpdateProvider protocol
    Registries.swift          PyPI / crates.io / Go proxy / GitHub lookups
    UserSettings.swift        preferences, ignore list, login item
    UpdateStore.swift         scan lifecycle, scheduling, grouping
  Providers/
    HomebrewProvider.swift
    AppleProviders.swift      Mac App Store, softwareupdate
    RuntimeProviders.swift    mise, rustup, gem, npm, composer, MacPorts
    PythonProviders.swift     pipx, uv, pip
    CompiledLangProviders.swift  cargo, go
    CustomSourceProvider.swift   user-declared tools from sources.json
    AppcastParser.swift       Sparkle appcast XML
    InstalledAppsProvider.swift  .app inventory, Sparkle, GitHub pins
  UI/
    Theme.swift               spacing grid, type scale, shared colours
    MenuView.swift            the panel
    MenuHeader.swift          toolbar, status card, transient search
    SourceSectionHeader.swift always-visible source headings
    UpdateRow.swift           one row
    AppIconLoader.swift       Finder icons, cached
    SettingsPane.swift        toggles
```

### Adding a source

Conform to `UpdateProvider`, then add an instance to `allProviders` in `UpdateStore`:

```swift
struct MyProvider: UpdateProvider {
    let kind: SourceKind = .myThing
    var isAvailable: Bool { Shell.has("mytool") }

    func scan() async -> ScanResult {
        guard let result = Shell.tryRun("mytool", ["outdated", "--json"]) else {
            return issue("Could not run `mytool outdated`.")
        }
        // ... parse, build UpdateItems, compare with Version.isNewer
        return ScanResult(items: items, issues: [])
    }
}
```

Add a case to `SourceKind` with a title, SF Symbol, and display rank, and it appears in Settings automatically.

## Tests and releases

`swift test` runs the strict Swift 6 test suite entirely offline using captured
provider-output fixtures. `./build.sh` creates a locally ad-hoc-signed app;
`release.sh` creates a universal Developer ID-signed and notarized build when the
required Apple credentials are supplied through its documented environment
variables. CI repeats tests, a release build, bundle assembly, signature
verification, and plist validation.

See [ROADMAP.md](ROADMAP.md) for the future product paths and the privacy or
credential decisions each one requires.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and
please keep fixtures synthetic and free of machine-specific paths, usernames,
private registry addresses, and credentials.

Maintainers preparing the first public repository or release should follow
[PUBLISHING.md](PUBLISHING.md).

## License

UpdateScout is available under the [MIT License](LICENSE).
