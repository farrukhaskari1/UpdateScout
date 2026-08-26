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

    private var visibleApps: [InstalledApp] {
        let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedStandardContains(query)
                || $0.bundleID.localizedStandardContains(query)
                || $0.path.localizedStandardContains(query)
        }
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
        .alert("Check all installed apps?", isPresented: $confirmsBulkLookup) {
            Button("Cancel", role: .cancel) {}
            Button("Check with \(settings.bulkLookupProvider.title)") { checkAllApps() }
        } message: {
            Text("This sends \(apps.count) app names and installed versions to \(settings.bulkLookupProvider.title). Results are shown beside every app.")
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

    @ViewBuilder
    private func lookupSummary(_ result: AppLookupResult, installedVersion: String) -> some View {
        let color: Color = result.status == .updateAvailable
            ? .orange
            : (result.status == .upToDate ? .green : .secondary)
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: result.status == .updateAvailable
                  ? "arrow.down.circle.fill"
                  : (result.status == .upToDate ? "checkmark.circle.fill" : "questionmark.circle"))
            Text(result.latestVersion.map { "Latest \($0)" } ?? "Version not verified")
        }
        .font(.caption)
        .foregroundStyle(color)

        Text(result.summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func checkAllApps() {
        isCheckingAll = true
        lookupError = nil
        Task {
            do {
                lookupResults = try await BulkAppLookup.check(
                    apps: apps,
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
        if app.feedURL?.scheme?.lowercased() == "https" { return "automatic update feed" }
        if Registries.officialAppBundleIDs.contains(app.bundleID) { return "official vendor releases" }
        if FileManager.default.fileExists(atPath: "\(app.path)/Contents/_MASReceipt/receipt") {
            return "Mac App Store"
        }
        if configuredGitHubIDs.contains(app.bundleID) { return "GitHub release" }
        if HomebrewProvider.managesApp(at: app.path) { return "Homebrew" }
        return "manual check recommended"
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
