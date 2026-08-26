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
        static let showSearchControl = "showSearchControl"
        static let showStatusCard = "showStatusCard"
        static let showUpdateProgress = "showUpdateProgress"
        static let showInstalledAppsControl = "showInstalledAppsControl"
        static let showCopyCommandsControl = "showCopyCommandsControl"
        static let notifyOnNew = "notifyOnNew"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let bulkLookupProvider = "bulkLookupProvider"
        static let bulkLookupPrompt = "bulkLookupPrompt"
        static let googleSearchEngineID = "googleSearchEngineID"
        static let anthropicModel = "anthropicModel"
        static let customAIEndpoint = "customAIEndpoint"
        static let customAIModel = "customAIModel"
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

    @Published var showSearchControl: Bool {
        didSet { defaults.set(showSearchControl, forKey: Key.showSearchControl) }
    }

    @Published var showStatusCard: Bool {
        didSet { defaults.set(showStatusCard, forKey: Key.showStatusCard) }
    }

    /// Show the progress bar while updates run. On by default — an update that
    /// gives no feedback looks like a hang.
    @Published var showUpdateProgress: Bool {
        didSet { defaults.set(showUpdateProgress, forKey: Key.showUpdateProgress) }
    }

    @Published var showInstalledAppsControl: Bool {
        didSet { defaults.set(showInstalledAppsControl, forKey: Key.showInstalledAppsControl) }
    }

    @Published var showCopyCommandsControl: Bool {
        didSet { defaults.set(showCopyCommandsControl, forKey: Key.showCopyCommandsControl) }
    }

    @Published var notifyOnNew: Bool {
        didSet { defaults.set(notifyOnNew, forKey: Key.notifyOnNew) }
    }

    @Published var refreshIntervalMinutes: Int {
        didSet { defaults.set(refreshIntervalMinutes, forKey: Key.refreshIntervalMinutes) }
    }

    @Published var bulkLookupProvider: BulkLookupProvider {
        didSet { defaults.set(bulkLookupProvider.rawValue, forKey: Key.bulkLookupProvider) }
    }

    @Published var bulkLookupPrompt: String {
        didSet { defaults.set(bulkLookupPrompt, forKey: Key.bulkLookupPrompt) }
    }

    @Published var googleSearchEngineID: String {
        didSet { defaults.set(googleSearchEngineID, forKey: Key.googleSearchEngineID) }
    }

    @Published var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: Key.anthropicModel) }
    }

    @Published var customAIEndpoint: String {
        didSet { defaults.set(customAIEndpoint, forKey: Key.customAIEndpoint) }
    }

    @Published var customAIModel: String {
        didSet { defaults.set(customAIModel, forKey: Key.customAIModel) }
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
        showBadgeCount = defaults.object(forKey: Key.showBadgeCount) as? Bool ?? false
        showSearchControl = defaults.object(forKey: Key.showSearchControl) as? Bool ?? true
        showStatusCard = defaults.object(forKey: Key.showStatusCard) as? Bool ?? true
        showUpdateProgress = defaults.object(forKey: Key.showUpdateProgress) as? Bool ?? true
        showInstalledAppsControl = defaults.object(forKey: Key.showInstalledAppsControl) as? Bool ?? true
        showCopyCommandsControl = defaults.object(forKey: Key.showCopyCommandsControl) as? Bool ?? true
        notifyOnNew = defaults.object(forKey: Key.notifyOnNew) as? Bool ?? false
        refreshIntervalMinutes = defaults.object(forKey: Key.refreshIntervalMinutes) as? Int ?? 60
        bulkLookupProvider = BulkLookupProvider(
            rawValue: defaults.string(forKey: Key.bulkLookupProvider) ?? ""
        ) ?? .chatGPT
        bulkLookupPrompt = defaults.string(forKey: Key.bulkLookupPrompt) ?? Self.defaultLookupPrompt
        googleSearchEngineID = defaults.string(forKey: Key.googleSearchEngineID) ?? ""
        anthropicModel = defaults.string(forKey: Key.anthropicModel) ?? "claude-sonnet-5"
        customAIEndpoint = defaults.string(forKey: Key.customAIEndpoint) ?? ""
        customAIModel = defaults.string(forKey: Key.customAIModel) ?? ""
        let stamp = defaults.double(forKey: Key.lastScanDate)
        lastScanDate = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        ignoredBundleIDs = Set(defaults.array(forKey: Key.ignoredBundleIDs) as? [String] ?? [])
        settingsError = nil
    }

    static let defaultLookupPrompt = """
    Find the latest stable macOS release for every installed app. Prefer the official vendor,
    official release notes, App Store listing, appcast, or official repository. Ignore beta,
    nightly, preview, and Windows-only releases. Never guess when no reliable version is found.
    Search the internet to determine whether each listed app is current, and give the newer
    build or release number when one exists.
    """

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
