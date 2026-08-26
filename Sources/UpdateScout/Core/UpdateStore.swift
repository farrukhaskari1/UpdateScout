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
    @Published private(set) var hasCompletedScanThisLaunch = false
    @Published private(set) var updateStates: [String: UpdateExecutionState] = [:]
    @Published private(set) var recoveryStates: [String: UpdateExecutionState] = [:]
    @Published private(set) var isUpdating = false
    @Published private(set) var updateProgressLabel = ""
    @Published var lastScan: Date?

    /// Sources the user can toggle, and whether the backing tool exists.
    /// Computed off the main actor once, because probing costs filesystem work.
    @Published private(set) var availableSources: [SourceOption] = []

    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var previouslySeen: Set<String> = []
    /// Kept so a settings change can re-filter without a fresh scan.
    private var lastResult = ScanResult()
    private var settingsObserver: AnyCancellable?
    private var notificationObserver: AnyCancellable?

    let settings = UserSettings.shared

    /// Every provider, in the order they're offered in Settings.
    private var allProviders: [any UpdateProvider] {
        [
            SystemUpdateProvider(),
            HomebrewProvider(),
            SparkleAppProvider(
                ignoredBundleIDs: settings.ignoredBundleIDs,
                deduplicateHomebrewCasks: settings.isEnabled(.homebrewCask),
                coveredGitHubBundleIDs: settings.isEnabled(.githubApp)
                    ? GitHubAppProvider.configuredBundleIDs()
                    : [],
                macAppStoreCoverageEnabled: settings.isEnabled(.macAppStore) && Shell.has("mas")
            ),
            GitHubAppProvider(ignoredBundleIDs: settings.ignoredBundleIDs),
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
                Task { @MainActor in
                    self.apply(self.lastResult, final: false)
                    self.refresh()
                }
            }

        notificationObserver = settings.$notifyOnNew
            .dropFirst()
            .filter { $0 }
            .sink { _ in Notifications.requestAuthorization() }
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

    func groupedItems(matching query: String) -> [SourceGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered = items
        if !trimmed.isEmpty {
            filtered = filtered.filter { $0.name.localizedStandardContains(trimmed) }
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

    func issues(matching query: String) -> [ScanIssue] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return issues }
        return issues.filter { issue in
            issue.subject?.localizedStandardContains(trimmed) == true
                || issue.message.localizedStandardContains(trimmed)
                || issue.source.title.localizedStandardContains(trimmed)
        }
    }

    var applicationCount: Int { items.filter { $0.source.isApplication }.count }
    var toolCount: Int { items.count - applicationCount }
    var hasFailures: Bool { issues.contains { $0.severity == .failed } }
    var isRecovering: Bool { recoveryStates.values.contains(where: \.isActive) }

    // MARK: - Scanning

    /// Cancel all provider tasks and terminate their active subprocesses.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        progressLabel = ""
    }

    func refresh() {
        guard !isScanning, !isUpdating else { return }
        scanTask?.cancel()
        updateStates = [:]
        recoveryStates = [:]
        isScanning = true
        progressLabel = "Preparing sources"

        // The Homebrew provider is the only source of cask items, so it has to
        // run whenever either of its two toggles is on.
        let candidates = allProviders.filter { provider in
            if provider.kind == .homebrewFormula {
                return settings.isEnabled(.homebrewFormula) || settings.isEnabled(.homebrewCask)
            }
            return settings.isEnabled(provider.kind)
        }

        scanTask = Task { [weak self] in await self?.performScan(candidates) }
    }

    private func performScan(_ candidates: [any UpdateProvider]) async {
        var collected = ScanResult()
        let usable = await Shell.offPool { candidates.filter(\.isAvailable) }
        guard !Task.isCancelled else { return }

        // Homebrew remains the prerequisite for cask/Sparkle de-duplication.
        if let homebrew = usable.first(where: { $0.kind == .homebrewFormula }) {
            progressLabel = "Scanning Homebrew"
            let result = await homebrew.scan()
            guard !Task.isCancelled else { return }
            collected = collected + result
            apply(collected, final: false)
        }

        let remaining = usable.filter { $0.kind != .homebrewFormula }
        collected = await scanConcurrently(remaining, appendingTo: collected)
        guard !Task.isCancelled else { return }

        apply(collected, final: true)
        isScanning = false
        progressLabel = ""
        scanTask = nil
        hasCompletedScanThisLaunch = true
        let now = Date.now
        lastScan = now
        settings.lastScanDate = now
    }

    /// Independent providers run concurrently, capped to avoid launching every
    /// package manager and network request on the machine at once.
    private func scanConcurrently(
        _ providers: [any UpdateProvider],
        appendingTo initial: ScanResult,
        limit: Int = 4
    ) async -> ScanResult {
        guard !providers.isEmpty else { return initial }
        var collected = initial
        var completed = 0
        progressLabel = "0 of \(providers.count) sources"

        await withTaskGroup(of: ScanResult.self) { group in
            var iterator = providers.makeIterator()
            for _ in 0..<min(limit, providers.count) {
                guard let provider = iterator.next() else { break }
                group.addTask { await provider.scan() }
            }

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                collected = collected + result
                completed += 1
                progressLabel = "\(completed) of \(providers.count) sources"
                apply(collected, final: false)

                if let provider = iterator.next() {
                    group.addTask { await provider.scan() }
                }
            }
        }
        return collected
    }

    private func apply(_ result: ScanResult, final: Bool) {
        // Drop duplicates: the same tool can appear via brew and via a language manager.
        // Also honour per-source toggles that a single provider can't apply itself —
        // the Homebrew provider emits both formulae and casks.
        lastResult = result

        var seen = Set<String>()
        let deduped = result.items
            .filter { settings.isEnabled($0.source) }
            .filter { item in item.ignoreKey.map { !settings.isIgnored($0) } ?? true }
            .filter { seen.insert($0.id).inserted }

        items = deduped.sorted {
            $0.source.rank == $1.source.rank
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.source.rank < $1.source.rank
        }
        issues = result.issues.filter { settings.isEnabled($0.source) }

        guard final else { return }
        notifyIfNeeded()
        previouslySeen = Set(items.map(\.notificationID))
    }

    private func notifyIfNeeded() {
        // `previouslySeen` is empty until the first completed scan, which
        // deliberately suppresses a notification for the launch-time backlog.
        guard settings.notifyOnNew, Notifications.areAvailable, !previouslySeen.isEmpty else { return }
        let fresh = items.filter { !previouslySeen.contains($0.notificationID) }
        guard !fresh.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "1 new update" : "\(fresh.count) new updates"
        content.body = fresh.prefix(4).map { "\($0.name) \($0.latestVersion)" }.joined(separator: ", ")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("UpdateScout notification failed: \(error.localizedDescription)") }
        }
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
        guard hasCompletedScanThisLaunch else { refresh(); return }
        guard let lastScan else { refresh(); return }
        if Date.now.timeIntervalSince(lastScan) > seconds { refresh() }
    }

    // MARK: - Actions

    func updateState(for item: UpdateItem) -> UpdateExecutionState {
        guard let command = item.upgradeCommand else { return .idle }
        return updateStates[command] ?? .idle
    }

    func canRunUpdate(_ item: UpdateItem) -> Bool {
        item.upgradeCommand != nil && updateState(for: item).canRun
    }

    func recoveryState(for issue: ScanIssue) -> UpdateExecutionState {
        recoveryStates[issue.id] ?? .idle
    }

    func startUpdates(_ requestedItems: [UpdateItem]) {
        guard !isUpdating, !isScanning else { return }
        var seen = Set<String>()
        let runnable = requestedItems.filter { item in
            guard let command = item.upgradeCommand,
                  updateState(for: item).canRun
            else { return false }
            return seen.insert(command).inserted
        }
        guard !runnable.isEmpty else { return }

        isUpdating = true
        for item in runnable {
            if let command = item.upgradeCommand { updateStates[command] = .queued }
        }
        updateTask = Task { [weak self] in
            await self?.performUpdates(runnable)
        }
    }

    func cancelUpdates() {
        updateTask?.cancel()
    }

    func startRecovery(_ issue: ScanIssue) {
        guard !isUpdating, !isScanning,
              let recovery = issue.recovery,
              recoveryState(for: issue).canRun
        else { return }

        guard let command = recovery.command else {
            applySourceChanges(from: recovery)
            refresh()
            return
        }

        isUpdating = true
        recoveryStates[issue.id] = .running
        updateProgressLabel = "Setting up \(issue.source.title)"
        updateTask = Task { [weak self] in
            await self?.performRecovery(issue, recovery: recovery, command: command)
        }
    }

    private func performRecovery(
        _ issue: ScanIssue,
        recovery: IssueRecovery,
        command: String
    ) async {
        let result = await Shell.runUpdateCommand(command)
        if Task.isCancelled {
            recoveryStates[issue.id] = .stopped("Stopped. Refresh before trying again.")
            finishRecovery()
            return
        }

        guard let result else {
            recoveryStates[issue.id] = .failed(
                "The setup command could not be started. Copy it and run it manually."
            )
            finishRecovery()
            return
        }

        if result.ok {
            recoveryStates[issue.id] = .succeeded
            Shell.invalidateExecutableCache()
            applySourceChanges(from: recovery)
            finishRecovery()
            probeAvailableSources()
            refresh()
        } else if Shell.isPermissionFailure(result) {
            recoveryStates[issue.id] = .permissionRequired(
                "Permission wasn’t granted. Copy the setup command to run it manually."
            )
            finishRecovery()
        } else {
            recoveryStates[issue.id] = .failed(Shell.conciseError(from: result))
            finishRecovery()
        }
    }

    private func applySourceChanges(from recovery: IssueRecovery) {
        if let source = recovery.disablesSource {
            settings.setEnabled(false, for: source)
        }
        if let source = recovery.enablesSource {
            settings.setEnabled(true, for: source)
        }
    }

    private func finishRecovery() {
        isUpdating = false
        updateProgressLabel = ""
        updateTask = nil
    }

    private func performUpdates(_ runnable: [UpdateItem]) async {
        for (index, item) in runnable.enumerated() {
            guard !Task.isCancelled, let command = item.upgradeCommand else { break }
            updateStates[command] = .running
            updateProgressLabel = "\(index + 1) of \(runnable.count) · \(item.name)"

            let mayElevate = item.source == .macOSSystem || item.source == .macports
            let result = await Shell.runUpdateCommand(
                command,
                allowAdministratorPrivileges: mayElevate
            )
            if Task.isCancelled { break }

            guard let result else {
                updateStates[command] = .failed("The command could not be started. Copy it and run it manually.")
                continue
            }
            if result.ok {
                updateStates[command] = .succeeded
            } else if Shell.isPermissionFailure(result) {
                updateStates[command] = .permissionRequired(
                    "Permission wasn’t granted. Copy the command to run it manually."
                )
            } else {
                updateStates[command] = .failed(Shell.conciseError(from: result))
            }
        }

        if Task.isCancelled {
            for (command, state) in updateStates {
                switch state {
                case .queued:
                    updateStates[command] = .idle
                case .running:
                    updateStates[command] = .stopped(
                        "Stopped. It may still be finishing; refresh before retrying."
                    )
                default:
                    break
                }
            }
        }
        isUpdating = false
        updateProgressLabel = ""
        updateTask = nil
    }

    func copyCommand(for item: UpdateItem) {
        guard let command = item.upgradeCommand else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    func copyRecoveryCommand(for issue: ScanIssue) {
        guard let command = issue.recovery?.command else { return }
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
