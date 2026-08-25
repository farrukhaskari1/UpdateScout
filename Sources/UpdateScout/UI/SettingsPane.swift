import SwiftUI
import AppKit

@MainActor
struct SettingsPane: View {
    @EnvironmentObject private var store: UpdateStore
    @ObservedObject private var settings = UserSettings.shared
    @State private var customSourceStatus = ""
    @State private var launchAtLogin = false
    @State private var fileError: String?

    // Dismissal is the header chevron's job — this pane doesn't need to know.
    private let intervals = [30, 60, 180, 360, 720, 1440]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                sources
                behaviour
                customTools
                pinnedApps
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.vertical, Theme.Space.edge)
        }
        .frame(minHeight: 180, maxHeight: 560)
    }

    // MARK: - Sections

    private var sources: some View {
        SettingsSection(title: "Sources") {
            ForEach(store.availableSources) { entry in
                Toggle(isOn: binding(for: entry.kind)) {
                    HStack(spacing: Theme.Space.tight + 1) {
                        Text(entry.kind.title)
                            .font(Theme.Font.caption)
                        if !entry.installed {
                            Text("not installed")
                                .font(Theme.Font.label)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!entry.installed)
            }
        }
    }

    private var behaviour: some View {
        SettingsSection(title: "Behaviour") {
            Toggle("Show count in the menu bar", isOn: $settings.showBadgeCount)
                .toggleStyle(.checkbox)
                .font(Theme.Font.caption)

            Toggle("Notify me when something new appears", isOn: $settings.notifyOnNew)
                .toggleStyle(.checkbox)
                .font(Theme.Font.caption)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(Theme.Font.caption)
                .onAppear {
                    settings.refreshLaunchAtLogin()
                    launchAtLogin = settings.launchAtLogin
                }
                .onChange(of: launchAtLogin) { enabled in
                    settings.setLaunchAtLogin(enabled)
                    launchAtLogin = settings.launchAtLogin
                }

            HStack(spacing: Theme.Space.inner) {
                Text("Check every")
                    .font(Theme.Font.caption)
                Picker("", selection: $settings.refreshIntervalMinutes) {
                    ForEach(intervals, id: \.self) { minutes in
                        Text(label(for: minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 104)
                .onChange(of: settings.refreshIntervalMinutes) { _ in
                    store.startTimer()
                }
            }
            .padding(.top, Theme.Space.tight)
        }
    }

    private var customTools: some View {
        SettingsSection(title: "Custom CLI tools") {
            Text("Teach UpdateScout about any tool by declaring how to read its version. No rebuild needed — the file is re-read on every scan.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.inner) {
                Button("Edit sources.json") { revealCustomSources() }
                    .controlSize(.small)
                Text(customSourceStatus)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Theme.Space.tight)
        }
        // Read once on appear, not on every re-render — a view body is no place
        // to touch the disk, and this pane redraws on every toggle.
        .onAppear { customSourceStatus = Self.readCustomSourceStatus() }
    }

    private static func readCustomSourceStatus() -> String {
        let url = CustomSourceProvider.configURL
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return "not set up yet" }
        return list.count == 1 ? "1 tool declared" : "\(list.count) tools declared"
    }

    private var pinnedApps: some View {
        SettingsSection(title: "Pinned GitHub apps") {
            Text("Apps without a Sparkle feed can be tracked by mapping their bundle ID to a GitHub repo.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Reveal config file") { revealConfig() }
                .controlSize(.small)
                .padding(.top, Theme.Space.tight)
        }
    }

    // MARK: - Helpers

    private func binding(for kind: SourceKind) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(kind) },
            set: { settings.setEnabled($0, for: kind) }
        )
    }

    private func label(for minutes: Int) -> String {
        switch minutes {
        case ..<60: return "\(minutes) min"
        case 1440:  return "day"
        default:    return "\(minutes / 60) hr"
        }
    }

    private var errorMessage: String? { fileError ?? settings.settingsError }

    /// Seeds the file from the bundled sample the first time, so there's
    /// something working to edit rather than an empty buffer.
    private func revealCustomSources() {
        let url = CustomSourceProvider.configURL
        fileError = nil
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                let seed = Bundle.main.url(forResource: "sources.sample", withExtension: "json")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    ?? "[\n]\n"
                try seed.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            customSourceStatus = Self.readCustomSourceStatus()
            store.probeAvailableSources()
        } catch {
            fileError = "Could not create sources.json: \(error.localizedDescription)"
        }
    }

    private func revealConfig() {
        let url = GitHubAppProvider.configURL
        fileError = nil
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                let sample = """
                {
                  "com.example.MyApp": "owner/repo"
                }
                """
                try sample.write(to: url, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            store.probeAvailableSources()
        } catch {
            fileError = "Could not create github-apps.json: \(error.localizedDescription)"
        }
    }
}
