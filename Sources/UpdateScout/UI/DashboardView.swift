import SwiftUI
import AppKit

enum DashboardPage: String, CaseIterable, Identifiable {
    static let defaultsKey = "dashboardPage"
    case apps
    case settings

    var id: String { rawValue }
    var title: String { self == .apps ? "Installed Apps" : "Settings" }
}

@MainActor
struct DashboardView: View {
    @AppStorage(DashboardPage.defaultsKey) private var page = DashboardPage.apps.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(DashboardPage.allCases) { page in
                    Text(page.title).tag(page.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding()

            Divider()

            if page == DashboardPage.settings.rawValue {
                SettingsPane()
            } else {
                InstalledAppsView()
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

@MainActor
private struct InstalledAppsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var apps: [InstalledApp] = []
    @State private var configuredGitHubIDs: Set<String> = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var isCheckingAll = false
    @State private var lookupResults: [String: AppLookupResult] = [:]
    @State private var lookupError: String?
    @State private var confirmsBulkLookup = false

    @State private var showsOnlyUncheckable = false

    private var visibleApps: [InstalledApp] {
        var sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if showsOnlyUncheckable { sorted = sorted.filter(cannotBeChecked) }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedStandardContains(query)
                || $0.bundleID.localizedStandardContains(query)
                || $0.path.localizedStandardContains(query)
        }
    }

    /// Apps whose version nobody can confirm: no update mechanism we detect,
    /// and either no lookup has run or the lookup came back unverified.
    private func cannotBeChecked(_ app: InstalledApp) -> Bool {
        guard updateMechanism(for: app) == nil else { return false }
        guard let result = lookupResults[BulkAppLookup.identity(for: app)] else { return true }
        return result.status == .unverified
    }

    private var uncheckableApps: [InstalledApp] {
        apps.filter(cannotBeChecked)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isLoading ? "Finding installed apps…" : "\(apps.count) installed apps")
                        .font(.title2.bold())
                    Text("Versions are read directly from each app on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    confirmsBulkLookup = true
                } label: {
                    if isCheckingAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Check All Apps", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || apps.isEmpty || isCheckingAll)
                .help("Check every installed app with \(settings.bulkLookupProvider.title)")

                TextField("Search apps", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding()

            if !isLoading && !uncheckableApps.isEmpty {
                uncheckableBanner
            } else if showsOnlyUncheckable {
                // The banner owns the "Only these" toggle. If a lookup verifies
                // the last unverifiable app while it's on, the banner leaves and
                // takes the only way to switch it off with it.
                Color.clear.frame(height: 0).onAppear { showsOnlyUncheckable = false }
            }

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Reading applications")
                Spacer()
            } else {
                List(visibleApps, id: \.path) { app in
                    HStack(spacing: 12) {
                        if let icon = AppIconLoader.shared.icon(atPath: app.path) {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 34, height: 34)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.body.bold())
                            Text("Version \(app.shortVersion) · \(coverage(for: app))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(app.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)

                            if let result = lookupResults[BulkAppLookup.identity(for: app)] {
                                lookupSummary(result, installedVersion: app.shortVersion)
                            }
                        }

                        Spacer()

                        if let url = lookupResults[BulkAppLookup.identity(for: app)]?.sourceURL {
                            Button("Source") { NSWorkspace.shared.open(url) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .task {
            let result = await Shell.offPool {
                (AppInventory.scan(), GitHubAppProvider.configuredBundleIDs())
            }
            apps = result.0
            configuredGitHubIDs = result.1
            isLoading = false
        }
        .alert("Check apps that need a manual update?", isPresented: $confirmsBulkLookup) {
            Button("Cancel", role: .cancel) {}
            Button("Check with \(settings.bulkLookupProvider.title)") { checkAllApps() }
                .disabled(unidentifiedApps.isEmpty)
        } message: {
            // Names and versions only — `BulkAppLookup.identity` deliberately
            // never emits a filesystem path, so this stays true.
            Text(unidentifiedApps.isEmpty
                 ? "Every installed app already has a known update mechanism, so there is nothing to look up."
                 : "This sends the name and installed version of \(unidentifiedApps.count) app\(unidentifiedApps.count == 1 ? "" : "s") — the ones with no update mechanism we can detect — to \(settings.bulkLookupProvider.title). No file paths or personal data are sent. Apps already covered by Homebrew, the App Store, or an update feed are not included.")
        }
        .alert("Automatic check failed", isPresented: Binding(
            get: { lookupError != nil },
            set: { if !$0 { lookupError = nil } }
        )) {
            Button("OK", role: .cancel) { lookupError = nil }
        } message: {
            Text(lookupError ?? "Unknown error")
        }
    }

    /// The apps nobody can verify, called out rather than left buried in a long
    /// list — these are the only ones the user has to go and check by hand.
    private var uncheckableBanner: some View {
        // Computed once: `uncheckableApps` stats every app on disk, and the
        // banner referenced it six times per body evaluation — on every
        // keystroke in the search field.
        let uncheckable = uncheckableApps

        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.inner) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(uncheckable.count) app\(uncheckable.count == 1 ? "" : "s") can't be checked automatically")
                    .font(.callout.bold())
                Text(uncheckable.prefix(4).map { "\($0.name) \($0.shortVersion)" }
                        .joined(separator: " · ")
                     + (uncheckable.count > 4 ? " and \(uncheckable.count - 4) more" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("Only these", isOn: $showsOnlyUncheckable)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button("Copy List") { copyUncheckableList() }
                .controlSize(.small)
                .help("Copy every unverifiable app and its installed version")
        }
        .padding(.horizontal)
        .padding(.bottom, Theme.Space.row)
    }

    private func copyUncheckableList() {
        let lines = uncheckableApps.map { app -> String in
            let mechanism = lookupResults[BulkAppLookup.identity(for: app)] == nil
                ? "no update mechanism detected"
                : "version could not be verified"
            return "\(app.name)\t\(app.shortVersion)\t\(mechanism)"
        }
        let text = """
        Apps requiring a manual update check — \(uncheckableApps.count) total
        Name\tInstalled version\tReason

        \(lines.joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func lookupSummary(_ result: AppLookupResult, installedVersion: String) -> some View {
        let color: Color = result.status == .updateAvailable
            ? .orange
            : (result.status == .upToDate ? .green : .secondary)
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: result.status == .updateAvailable
                  ? "arrow.down.circle.fill"
                  : (result.status == .upToDate ? "checkmark.circle.fill" : "questionmark.circle"))
            // These apps have no update mechanism we can drive, so the actionable
            // wording is what to do by hand — not just what the latest version is.
            Text(headline(for: result, installedVersion: installedVersion))
        }
        .font(.caption)
        .foregroundStyle(color)

        Text(result.summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func headline(for result: AppLookupResult, installedVersion: String) -> String {
        switch result.status {
        case .updateAvailable:
            guard let latest = result.latestVersion else { return "Update available — install it manually" }
            return "Update manually: \(installedVersion) → \(latest)"
        case .upToDate:
            return result.latestVersion.map { "Up to date (\($0))" } ?? "Up to date"
        case .unverified:
            return "Could not verify a current version"
        }
    }

    private func checkAllApps() {
        // Belt and braces behind the alert's `.disabled`: with an empty list,
        // `BulkAppLookup.check` validates credentials first and would report a
        // missing API key rather than "nothing to do".
        guard !unidentifiedApps.isEmpty else { return }
        isCheckingAll = true
        lookupError = nil
        Task {
            do {
                lookupResults = try await BulkAppLookup.check(
                    apps: unidentifiedApps,
                    provider: settings.bulkLookupProvider,
                    prompt: settings.bulkLookupPrompt,
                    googleEngineID: settings.googleSearchEngineID,
                    anthropicModel: settings.anthropicModel,
                    customEndpoint: settings.customAIEndpoint,
                    customModel: settings.customAIModel
                )
            } catch {
                lookupError = error.localizedDescription
            }
            isCheckingAll = false
        }
    }

    private func coverage(for app: InstalledApp) -> String {
        updateMechanism(for: app) ?? "manual check recommended"
    }

    /// How this app keeps itself current, or nil if nothing we know about does.
    private func updateMechanism(for app: InstalledApp) -> String? {
        if app.feedURL?.scheme?.lowercased() == "https" { return "automatic update feed" }
        if Registries.officialAppBundleIDs.contains(app.bundleID) { return "official vendor releases" }
        if FileManager.default.fileExists(atPath: "\(app.path)/Contents/_MASReceipt/receipt") {
            return "Mac App Store"
        }
        if configuredGitHubIDs.contains(app.bundleID) { return "GitHub release" }
        if HomebrewProvider.managesApp(at: app.path) { return "Homebrew" }
        return nil
    }

    /// The apps worth asking about: everything already covered by a feed, a
    /// package manager, or the App Store is tracked accurately for free, so
    /// sending it to an AI service costs tokens and tells us nothing new.
    private var unidentifiedApps: [InstalledApp] {
        apps.filter { updateMechanism(for: $0) == nil }
    }
}

enum AppVersionLookup {
    static func searchWeb(for issue: ScanIssue) {
        guard let name = issue.subject else { return }
        searchWeb(name: name, installedVersion: installedVersion(in: issue.message))
    }

    static func askChatGPT(about issue: ScanIssue) {
        guard let name = issue.subject else { return }
        askChatGPT(name: name, installedVersion: installedVersion(in: issue.message))
    }

    static func searchWeb(name: String, installedVersion: String) {
        open(base: "https://www.google.com/search", parameter: "q", value: query(name, installedVersion))
    }

    static func askChatGPT(name: String, installedVersion: String) {
        let prompt = "Find the latest stable macOS version of \(name). I have version \(installedVersion). Use the official vendor or release page and give me its link."
        open(base: "https://chatgpt.com/", parameter: "q", value: prompt)
    }

    private static func query(_ name: String, _ installedVersion: String) -> String {
        "\(name) latest stable macOS version official release (installed \(installedVersion))"
    }

    private static func installedVersion(in message: String) -> String {
        message.split(separator: " ").dropFirst().first.map(String.init) ?? "unknown"
    }

    private static func open(base: String, parameter: String, value: String) {
        guard var components = URLComponents(string: base) else { return }
        components.queryItems = [URLQueryItem(name: parameter, value: value)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
