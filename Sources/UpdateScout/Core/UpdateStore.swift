import Foundation
import Combine
import AppKit
import UserNotifications

/// Owns the scan lifecycle and the results the menu renders.
@MainActor
final class UpdateStore: ObservableObject {

    @Published private(set) var items: [UpdateItem] = []
    @Published private(set) var issues: [ScanIssue] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progressLabel: String = ""
    @Published var lastScan: Date?

    /// Sources the user can toggle, and whether the backing tool exists.
    /// Computed off the main actor once, because probing costs filesystem work.
    @Published private(set) var availableSources: [SourceOption] = []

    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var previouslySeen: Set<String> = []
    /// Kept so a settings change can re-filter without a fresh scan.
    private var lastResult = ScanResult()
    private var settingsObserver: AnyCancellable?

    let settings = UserSettings.shared

    /// Every provider, in the order they're offered in Settings.
    private var allProviders: [any UpdateProvider] {
        [
            SystemUpdateProvider(),
            HomebrewProvider(),
            SparkleAppProvider(),
            GitHubAppProvider(),
            MacAppStoreProvider(),
            MiseProvider(),
            RustupProvider(),
            NpmProvider(),
            PipxProvider(),
            UvToolProvider(),
            PipProvider(),
            GemProvider(),
            CargoProvider(),
            GoBinaryProvider(),
            ComposerProvider(),
            MacPortsProvider(),
            CustomSourceProvider()
        ]
    }

    init() {
        lastScan = settings.lastScanDate
        startTimer()
        probeAvailableSources()

        // Toggling a source should take effect immediately, not at the next scan.
        //
        // The `Task` hop is load-bearing: `@Published` fires on *willSet*, so
        // inside this closure `settings.disabledSources` still holds the old
        // value that `apply` would filter against. Deferring to the next main
        // actor turn lets the setter finish first. Don't inline this call.
        settingsObserver = settings.$disabledSources
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.apply(self.lastResult, final: false) }
            }
    }

    /// Work out which backing tools exist, off the main actor.
    ///
    /// Callable again after Settings creates a config file, so a source doesn't
    /// stay greyed out as "not installed" once its file exists.
    func probeAvailableSources() {
        let providers = allProviders
        Task { [weak self] in
            let options = await Shell.offPool { () -> [SourceOption] in
                var seen = Set<SourceKind>()
                var out: [SourceOption] = []
                for provider in providers where seen.insert(provider.kind).inserted {
                    out.append(SourceOption(kind: provider.kind, installed: provider.isAvailable))
                }
                // Homebrew emits casks too, but has a single provider behind it.
                out.insert(SourceOption(kind: .homebrewCask, installed: Shell.has("brew")), at: 2)
                return out
            }
            await MainActor.run { self?.availableSources = options }
        }
    }

    // MARK: - Grouping for the UI

    func groupedItems(matching query: String, scope: MenuScope = .all) -> [SourceGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var filtered = items.filter { scope.includes($0) }
        if !trimmed.isEmpty {
            filtered = filtered.filter { $0.name.lowercased().contains(trimmed) }
        }

        // Grouped by `groupKey` rather than by source, so each user-defined
        // tool gets its own section instead of sharing one "Custom" pile.
        return Dictionary(grouping: filtered, by: \.groupKey)
            .compactMap { key, value -> SourceGroup? in
                guard let first = value.first else { return nil }
                return SourceGroup(
                    id: key,
                    kind: first.source,
                    title: first.groupTitle ?? first.source.title,
                    items: value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            .sorted {
                $0.rank == $1.rank
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : $0.rank < $1.rank
            }
    }

    var applicationCount: Int { items.filter { $0.source.isApplication }.count }
    var toolCount: Int { items.count - applicationCount }

    // MARK: - Scanning

    /// Stop waiting on the current scan. The subprocess already running finishes
    /// on its own — this just stops us collecting anything more from it.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        progressLabel = ""
    }

    func refresh() {
        guard !isScanning else { return }
        scanTask?.cancel()
        isScanning = true
        progressLabel = "Starting…"

        // The Homebrew provider is the only source of cask items, so it has to
        // run whenever either of its two toggles is on.
        let candidates = allProviders.filter { provider in
            if provider.kind == .homebrewFormula {
                return settings.isEnabled(.homebrewFormula) || settings.isEnabled(.homebrewCask)
            }
            return settings.isEnabled(provider.kind)
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            var collected = ScanResult()

            // `isAvailable` stats the filesystem, so run it off the main actor.
            let usable = await Shell.offPool { candidates.filter { $0.isAvailable } }

            // Homebrew must run first so the Sparkle scanner can skip cask-managed
            // apps. Partitioning explicitly keeps the rest in declaration order —
            // `sorted(by:)` is not stable and would shuffle them between scans.
            let ordered = usable.filter { $0.kind == .homebrewFormula }
                + usable.filter { $0.kind != .homebrewFormula }

            for provider in ordered {
                if Task.isCancelled { break }
                await MainActor.run { self.progressLabel = "Checking \(provider.kind.title)…" }
                let result = await provider.scan()
                collected = collected + result
                // Stream partial results so the menu fills in as it goes.
                let snapshot = collected
                await MainActor.run { self.apply(snapshot, final: false) }
            }

            // If the user cancelled, `cancelScan` already reset the UI state —
            // don't stamp a completion time over it.
            if Task.isCancelled { return }

            // A `let` copy: `collected` is a mutable local, and capturing a var
            // in a concurrently-executing closure is not allowed.
            let finished = collected
            await MainActor.run {
                self.apply(finished, final: true)
                self.isScanning = false
                self.progressLabel = ""
                let now = Date()
                self.lastScan = now
                self.settings.lastScanDate = now
            }
        }
    }

    private func apply(_ result: ScanResult, final: Bool) {
        // Drop duplicates: the same tool can appear via brew and via a language manager.
        // Also honour per-source toggles that a single provider can't apply itself —
        // the Homebrew provider emits both formulae and casks.
        lastResult = result

        var seen = Set<String>()
        let deduped = result.items
            .filter { settings.isEnabled($0.source) }
            .filter { seen.insert($0.id).inserted }

        items = deduped.sorted {
            $0.source.rank == $1.source.rank
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.source.rank < $1.source.rank
        }
        issues = result.issues

        guard final else { return }
        notifyIfNeeded()
        previouslySeen = Set(items.map(\.id))
    }

    private func notifyIfNeeded() {
        // `previouslySeen` is empty until the first completed scan, which
        // deliberately suppresses a notification for the launch-time backlog.
        guard settings.notifyOnNew, Notifications.areAvailable, !previouslySeen.isEmpty else { return }
        let fresh = items.filter { !previouslySeen.contains($0.id) }
        guard !fresh.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "1 new update" : "\(fresh.count) new updates"
        content.body = fresh.prefix(4).map { "\($0.name) \($0.latestVersion)" }.joined(separator: ", ")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Scheduling

    func startTimer() {
        timer?.invalidate()
        let minutes = max(15, settings.refreshIntervalMinutes)
        let interval = TimeInterval(minutes * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale(olderThan: interval * 0.9) }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called when the menu opens — cheap if we scanned recently.
    func refreshIfStale(olderThan seconds: TimeInterval = 15 * 60) {
        guard !isScanning else { return }
        guard let lastScan else { refresh(); return }
        if Date().timeIntervalSince(lastScan) > seconds { refresh() }
    }

    // MARK: - Actions

    func copyCommand(for item: UpdateItem) {
        guard let command = item.upgradeCommand else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    /// Runnable commands and nothing else — no comments, no headers.
    ///
    /// This is pasted straight into an interactive shell, and zsh does not
    /// enable `interactive_comments` by default: a leading `#` becomes a
    /// "command not found", and a trailing `# 1.0 → 1.1` gets handed to the
    /// tool as arguments. Blank lines between groups are the only decoration
    /// that survives a paste, so they're the only decoration here.
    func copyAllCommands() { copyCommands(for: items) }

    func copyCommands(for subset: [UpdateItem]) {
        let grouped = Dictionary(grouping: subset.filter { $0.upgradeCommand != nil }, by: \.source)
            .sorted { $0.key.rank < $1.key.rank }
        guard !grouped.isEmpty else { return }

        var blocks: [String] = []
        for group in grouped {
            let commands = group.value
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .compactMap(\.upgradeCommand)
            if !commands.isEmpty { blocks.append(commands.joined(separator: "\n")) }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(blocks.joined(separator: "\n\n"), forType: .string)
    }

    func openInfo(for item: UpdateItem) {
        guard let url = item.infoURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stop reporting this app. Useful for one that lies about its version, or
    /// that you deliberately keep pinned to an older release.
    func ignore(_ item: UpdateItem) {
        guard let key = item.ignoreKey else { return }
        settings.ignore(bundleID: key)
        items.removeAll { $0.id == item.id }
    }
}
