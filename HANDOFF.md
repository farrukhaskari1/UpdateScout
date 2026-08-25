# UpdateScout — handoff

Context for whoever picks this up next (Codex, another agent, or future you).
Written by Claude in a Cowork session on 2026-08-25.

## What this is

A macOS menu bar app (`MenuBarExtra`, SwiftUI, macOS 13+) that lists everything
on the machine with a newer version available — GUI apps and CLI tools — and
gives you the upgrade command. **It never installs anything.** Every action is
copy-to-clipboard or open-a-URL. That constraint was chosen deliberately by the
user and should not be relaxed without asking.

## Build status

**It compiles.** Confirmed 2026-08-25 against Apple Swift 6.3.3
(swiftlang-6.3.3.1.3), target `arm64-apple-macosx26.0` — a clean
`swift build -c release` producing a 1.0 MB Mach-O and an ad-hoc signed
`dist/UpdateScout.app`.

Two caveats on that:

1. Two changes landed *after* that build — the app icon and the macOS
   major-version upgrade check in `AppleProviders.swift`. **Rebuild before
   trusting the current tree.**
2. Compiling is not running. Nobody has confirmed the menu actually populates,
   that the login-shell `PATH` recovery finds the user's tools, or that any
   individual parser produces correct output on real data. See the gaps below.

The code was originally written in a Linux sandbox with no Swift toolchain and
reviewed statically three times by separate agents acting as the compiler; three
rounds of defects were found and fixed before it ever met a real compiler.

## Requirements as the user stated them

Gathered up front, verbatim intent:

| Question | Answer |
|---|---|
| What happens on finding an update | Detect only, show the new version, hand over the command |
| Which sources | "everything installed" — Homebrew, language package managers, Mac App Store, non-Homebrew GUI apps |
| How built | SwiftUI MenuBarExtra Xcode project |
| How often | On open + hourly background |

Delivered as a SwiftPM package rather than a literal `.xcodeproj` — Xcode opens
`Package.swift` natively (`xed .`), and hand-writing a project file is fragile.
If the user specifically wants an `.xcodeproj`, that conversion is still open.

## Architecture

```
Sources/UpdateScout/
  UpdateScoutApp.swift        @main, MenuBarExtra, AppDelegate (.accessory policy)
  Core/
    Shell.swift               login-PATH recovery, timeout-safe subprocess runner
    Version.swift             loose version comparator
    Models.swift              UpdateItem, SourceKind, UpdateProvider protocol, SourceGroup/SourceOption
    Registries.swift          PyPI / crates.io / Go proxy / GitHub lookups, PackageRef
    UserSettings.swift        prefs, ignore list, SMAppService login item
    UpdateStore.swift         @MainActor scan lifecycle, scheduling, grouping
  Providers/                  one type per source, all conforming to UpdateProvider
  UI/                         MenuView, UpdateRow, SettingsPane
```

Adding a source: conform to `UpdateProvider`, add a `SourceKind` case (title,
SF Symbol, rank), append an instance to `UpdateStore.allProviders`. It shows up
in Settings automatically.

## Non-obvious decisions — do not "simplify" these

1. **`Shell.searchPath` spawns `zsh -lc` once.** A GUI app launched from Finder
   inherits a bare `PATH` and cannot see `brew`, `mise`, `npm`. Cached for the
   process lifetime. The lock is deliberately *not* held across the subprocess.

2. **`Shell.runAsync` exists so blocking `waitUntilExit` stays off the
   cooperative thread pool.** Swift concurrency has ~1 thread per core; a few
   slow `brew` calls would otherwise starve the URLSession continuations that
   the registry lookups depend on. Providers must not call the sync `run`.

3. **The `Task { @MainActor in ... }` hop in `UpdateStore.init`'s Combine sink
   is load-bearing.** `@Published` fires on *willSet*, so inside the closure the
   old value is still in place. Inlining the call gives one-toggle-stale
   filtering. There's a comment; keep it.

4. **Homebrew runs first** in the scan order so `SparkleAppProvider` can skip
   apps already managed as casks. `sorted(by:)` is not stable, hence the
   explicit partition.

5. **`Version.isNewer` refuses non-numeric input** ("—", "latest", ""). Without
   that guard, placeholders compare as infinitely old and every row becomes a
   phantom update. This bit us once already.

6. **`brew update` is deliberately NOT called.** Homebrew 4 refreshes its JSON
   metadata on demand; an explicit update would cost a git fetch every scan.

7. **pip is disabled by default** — upgrading a Homebrew/system Python's
   site-packages by hand breaks the install. When enabled, it also refuses to
   run against a PEP 668 externally-managed interpreter, detected by reading
   the shebang of the actual `pip3` on PATH (not by asking `python3`, which
   routinely resolves to a different prefix).

8. **`copyAllCommands` emits runnable commands and nothing else.** No `#`
   headers, no trailing `# 1.0 → 1.1` annotations. zsh does not enable
   `interactive_comments` by default, so a leading `#` becomes "command not
   found" and a trailing one is passed to the tool as arguments. This was
   tried and reverted — don't add it back.

9. **System Ruby is skipped.** `gem outdated` on `/usr/bin/gem` lists dozens of
   default gems that `gem update` then refuses to touch. Same class of problem
   as pip; same resolution.

10. **`UI/Theme.swift` is the whole visual vocabulary** — a 4pt spacing grid and
    four type sizes. New UI pulls from `Theme.Space` / `Theme.Font`; it does not
    invent constants. `Theme.iconSide` is what makes the header badge, section
    chevrons, and row icons share one text column, so changing it realigns the
    window rather than breaking it. Note `Theme.Font` shadows `SwiftUI.Font`
    inside `enum Theme`, which is why those statics are written out as
    `SwiftUI.Font.system(...)`.

11. **Skips are not failures.** `ScanIssue.severity` distinguishes
    `.skipped` (we chose not to check — grey minus, "Not checked") from
    `.failed` (we tried and couldn't — orange triangle, "Needs attention").
    Providers call `skipped(_:)` or `issue(_:)` accordingly. Rendering a
    deliberate skip as a warning makes working-as-designed behaviour look
    broken, which is exactly the bug this replaced.

12. **Notes are filtered by the active tab.** A pip skip has no business
    appearing under Apps. `MenuScope.includes(sourceKind:)` gates them.

## Known gaps and open items

- [ ] **Never actually run.** It builds; nobody has watched it work. Highest
      priority is launching it and checking the menu populates at all.
- [ ] **Built on macOS 26 / Swift 6.3 but declares a macOS 13 deployment target.**
      Nothing verifies it still builds or behaves on 13/14/15. If back-compat
      doesn't matter, raising the target in `Package.swift` would let the code
      drop several workarounds (`Color.opacity` instead of `ShapeStyle.opacity`,
      the single-argument `onChange`, the explicit `@MainActor` on View structs).
- [ ] **Swift 6 language mode not attempted.** The package pins
      `swift-tools-version: 5.9` / language mode 5. Known blockers for a Swift 6
      migration: the non-Sendable captures in `Shell.runRaw`. (The
      `HomebrewProvider` mutable-static blocker was resolved by moving to
      `OSAllocatedUnfairLock`.)
- [ ] **Not tested against real tool output.** Every parser was written against
      remembered output formats, not captured samples. `mas outdated`,
      `mise outdated --json`, `softwareupdate --list-full-installers`, and the
      Homebrew cask `installed_versions` shape (array vs string) are the most
      likely to be wrong. `preview.sh` in this repo dumps the real output from
      the user's machine — diff it against what the parsers expect.
- [ ] **Sparkle appcast coverage is unmeasured.** Unknown what fraction of the
      user's `/Applications` actually has a `SUFeedURL`.
- [ ] **Electron apps and bespoke updaters are invisible.** No Sparkle feed, not
      a cask, not App Store → not reported. The GitHub pin file
      (`~/.config/updatescout/github-apps.json`) is the manual escape hatch.
- [ ] **No tests.** No `Tests/` target exists. `Version.compare` is the obvious
      first candidate — it's pure, and it's where the subtle bugs live.
- [ ] **No app icon design review.** `Resources/make_icon.py` generates
      `AppIcon.icns` procedurally (Pillow). Legible to 32px, mushy at 16px.
- [ ] **`.xcodeproj` not provided** — SwiftPM package instead, see above.
- [ ] **Ad-hoc signature only.** Fine locally; not distributable. No
      notarization, no hardened runtime, no Sparkle self-update for the app
      itself.

## Things that were fixed in review — don't reintroduce them

- `\.kind` key path into a tuple element (illegal) → `SourceGroup`/`SourceOption`
- `ShapeStyle.opacity()` on `.quaternary`/`.background` (macOS 14) → `Color.opacity`
- `Version.compare("1.2", "1.2.0")` returning "newer" → trailing-zero handling
- Capturing the mutable `collected` in a concurrent closure → `let` snapshot
- Disabling "Homebrew Formulae" silently killing casks → both toggles checked
- rustup toolchain names truncated at the first hyphen
- `softwareupdate --list --no-scan` reporting only stale cached results

## Build

```bash
./build.sh            # → dist/UpdateScout.app
./build.sh --install  # → /Applications, then launches it
./preview.sh          # read-only survey of what's installed and outdated
```

Requires macOS 13+ and the Xcode command line tools. `make_icon.py` needs Pillow
but only runs if `AppIcon.icns` is missing (it's committed).
