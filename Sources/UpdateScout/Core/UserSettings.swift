import Foundation
import Combine
import ServiceManagement

/// Persisted preferences. Reads are thread-safe (UserDefaults is); writes happen on the main actor.
@MainActor
final class UserSettings: ObservableObject {

    static let shared = UserSettings()

    private enum Key {
        static let disabledSources = "disabledSources"
        static let ignoredBundleIDs = "ignoredBundleIDs"
        static let lastScanDate = "lastScanDate"
        static let showBadgeCount = "showBadgeCount"
        static let notifyOnNew = "notifyOnNew"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
    }

    private let defaults = UserDefaults.standard

    /// pip is off by default because it can target an externally-managed Python.
    private static let defaultDisabled: Set<String> = [SourceKind.pip.rawValue]

    @Published var disabledSources: Set<String> {
        didSet { defaults.set(Array(disabledSources), forKey: Key.disabledSources) }
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

    @Published private(set) var ignoredBundleIDs: Set<String> {
        didSet { defaults.set(Array(ignoredBundleIDs), forKey: Key.ignoredBundleIDs) }
    }

    @Published private(set) var settingsError: String?

    private init() {
        if let stored = defaults.array(forKey: Key.disabledSources) as? [String] {
            disabledSources = Set(stored)
        } else {
            disabledSources = Self.defaultDisabled
        }
        showBadgeCount = defaults.object(forKey: Key.showBadgeCount) as? Bool ?? true
        notifyOnNew = defaults.object(forKey: Key.notifyOnNew) as? Bool ?? false
        refreshIntervalMinutes = defaults.object(forKey: Key.refreshIntervalMinutes) as? Int ?? 60
        let stamp = defaults.double(forKey: Key.lastScanDate)
        lastScanDate = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        ignoredBundleIDs = Set(defaults.array(forKey: Key.ignoredBundleIDs) as? [String] ?? [])
        settingsError = nil
    }

    func isEnabled(_ source: SourceKind) -> Bool {
        !disabledSources.contains(source.rawValue)
    }

    func setEnabled(_ enabled: Bool, for source: SourceKind) {
        if enabled { disabledSources.remove(source.rawValue) }
        else { disabledSources.insert(source.rawValue) }
    }

    // MARK: - Per-app ignore list

    func isIgnored(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return ignoredBundleIDs.contains(bundleID)
    }

    func ignore(bundleID: String) {
        ignoredBundleIDs.insert(bundleID)
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
        settingsError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            settingsError = "Could not change the login item: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    func clearError() { settingsError = nil }
}
