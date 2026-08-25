import Foundation
import Combine
import ServiceManagement

/// Persisted preferences. Reads are thread-safe (UserDefaults is); writes happen on the main actor.
final class UserSettings: ObservableObject {

    static let shared = UserSettings()

    private enum Key {
        static let collapsedSources = "collapsedSources"
        static let disabledSources = "disabledSources"
        static let ignoredBundleIDs = "ignoredBundleIDs"
        static let lastScanDate = "lastScanDate"
        static let showBadgeCount = "showBadgeCount"
        static let notifyOnNew = "notifyOnNew"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
    }

    private let defaults = UserDefaults.standard

    /// Sources that are off by default: pip touches system Python, and macOS
    /// system updates are noisy for people who update via System Settings.
    private static let defaultDisabled: Set<String> = [SourceKind.pip.rawValue]

    @Published var disabledSources: Set<String> {
        didSet { defaults.set(Array(disabledSources), forKey: Key.disabledSources) }
    }

    /// Sections the user has folded shut. Remembered across launches.
    @Published var collapsedSources: Set<String> {
        didSet { defaults.set(Array(collapsedSources), forKey: Key.collapsedSources) }
    }

    @Published var showBadgeCount: Bool {
        didSet { defaults.set(showBadgeCount, forKey: Key.showBadgeCount) }
    }

    @Published var notifyOnNew: Bool {
        didSet { defaults.set(notifyOnNew, forKey: Key.notifyOnNew) }
    }

    @Published var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: Key.refreshIntervalMinutes) }
    }

    @Published var lastScanDate: Date? {
        didSet { defaults.set(lastScanDate?.timeIntervalSince1970 ?? 0, forKey: Key.lastScanDate) }
    }

    private init() {
        if let stored = defaults.array(forKey: Key.disabledSources) as? [String] {
            disabledSources = Set(stored)
        } else {
            disabledSources = Self.defaultDisabled
        }
        collapsedSources = Set(defaults.array(forKey: Key.collapsedSources) as? [String] ?? [])
        showBadgeCount = defaults.object(forKey: Key.showBadgeCount) as? Bool ?? true
        notifyOnNew = defaults.object(forKey: Key.notifyOnNew) as? Bool ?? false
        refreshIntervalMinutes = defaults.object(forKey: Key.refreshIntervalMinutes) as? Int ?? 60
        let stamp = defaults.double(forKey: Key.lastScanDate)
        lastScanDate = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Keyed by `SourceGroup.id`, which is a source's raw value for built-ins
    /// and `custom|<tool id>` for user-defined tools.
    func isCollapsed(_ groupID: String) -> Bool {
        collapsedSources.contains(groupID)
    }

    func toggleCollapsed(_ groupID: String) {
        if collapsedSources.contains(groupID) {
            collapsedSources.remove(groupID)
        } else {
            collapsedSources.insert(groupID)
        }
    }

    func setAllCollapsed(_ collapsed: Bool, groupIDs: [String]) {
        if collapsed {
            collapsedSources.formUnion(groupIDs)
        } else {
            collapsedSources.subtract(groupIDs)
        }
    }

    func isEnabled(_ source: SourceKind) -> Bool {
        !disabledSources.contains(source.rawValue)
    }

    func setEnabled(_ enabled: Bool, for source: SourceKind) {
        if enabled { disabledSources.remove(source.rawValue) }
        else { disabledSources.insert(source.rawValue) }
    }

    // MARK: - Per-app ignore list (read from any thread)

    func isIgnored(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let list = defaults.array(forKey: Key.ignoredBundleIDs) as? [String] ?? []
        return list.contains(bundleID)
    }

    func ignore(bundleID: String) {
        var list = defaults.array(forKey: Key.ignoredBundleIDs) as? [String] ?? []
        guard !list.contains(bundleID) else { return }
        list.append(bundleID)
        defaults.set(list, forKey: Key.ignoredBundleIDs)
        objectWillChange.send()
    }

    // MARK: - Launch at login

    /// Cached, because `SMAppService.status` is synchronous IPC and the settings
    /// pane would otherwise query it on every render.
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("UpdateScout: could not change login item — \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }
}
