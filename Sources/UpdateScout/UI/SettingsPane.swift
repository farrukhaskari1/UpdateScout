import SwiftUI
import AppKit

@MainActor
struct SettingsPane: View {
    @EnvironmentObject private var store: UpdateStore
    @ObservedObject private var settings = UserSettings.shared
    @State private var customSourceStatus = ""
    @State private var launchAtLogin = false
    @State private var fileError: String?
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var googleKey = ""
    @State private var customAIKey = ""
    @State private var hasOpenAIKey = false
    @State private var hasAnthropicKey = false
    @State private var hasGoogleKey = false
    @State private var hasCustomAIKey = false
    @State private var credentialStatus = ""

    // Dismissal is the header chevron's job — this pane doesn't need to know.
    private let intervals = [30, 60, 180, 360, 720, 1440]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                sources
                behaviour
                appearance
                automaticLookup
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
        .frame(minHeight: 420)
        .task { await refreshCredentialStatus() }
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

    private var appearance: some View {
        SettingsSection(title: "Interface") {
            Toggle("Show update count beside the Mac icon", isOn: $settings.showBadgeCount)
            Toggle("Show status summary", isOn: $settings.showStatusCard)
            Toggle("Show search control", isOn: $settings.showSearchControl)
            Toggle("Show Installed Apps control", isOn: $settings.showInstalledAppsControl)
            Toggle("Show Copy Commands control", isOn: $settings.showCopyCommandsControl)
        }
        .toggleStyle(.checkbox)
        .font(Theme.Font.caption)
    }

    private var automaticLookup: some View {
        SettingsSection(title: "Automatic app lookup") {
            Picker("Service", selection: $settings.bulkLookupProvider) {
                ForEach(BulkLookupProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.menu)

            Text("Your installed-app names and versions are sent only when you press Check All Apps.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch settings.bulkLookupProvider {
            case .chatGPT:
                credentialField(
                    title: "OpenAI API key",
                    text: $openAIKey,
                    isSaved: hasOpenAIKey,
                    save: saveOpenAIKey
                )
            case .claude:
                credentialField(
                    title: "Anthropic API key",
                    text: $anthropicKey,
                    isSaved: hasAnthropicKey,
                    save: saveAnthropicKey
                )
                TextField("Claude model", text: $settings.anthropicModel)
                    .textFieldStyle(.roundedBorder)
                Text("Claude searches the web during the check and returns an official source for each result. Web search usage is billed by Anthropic.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .google:
                credentialField(
                    title: "Google API key",
                    text: $googleKey,
                    isSaved: hasGoogleKey,
                    save: saveGoogleKey
                )
                TextField("Programmable Search Engine ID", text: $settings.googleSearchEngineID)
                    .textFieldStyle(.roundedBorder)
                Text("Google Custom Search is available only to existing customers and is scheduled to end in 2027.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .custom:
                TextField("OpenAI-compatible chat completions URL", text: $settings.customAIEndpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("Model name", text: $settings.customAIModel)
                    .textFieldStyle(.roundedBorder)
                credentialField(
                    title: "API key (optional for local AI)",
                    text: $customAIKey,
                    isSaved: hasCustomAIKey,
                    save: saveCustomAIKey
                )
                Text("Use an HTTPS service or a local endpoint such as http://localhost:11434/v1/chat/completions. Current web results require the chosen service or model to provide its own search capability.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Prompt")
                .font(Theme.Font.caption.bold())
            TextEditor(text: $settings.bulkLookupPrompt)
                .font(Theme.Font.caption)
                .frame(minHeight: 96)
                .padding(Theme.Space.inner)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            HStack(spacing: Theme.Space.inner) {
                Button("Restore Prompt") {
                    settings.bulkLookupPrompt = UserSettings.defaultLookupPrompt
                }
                .controlSize(.small)
                if !credentialStatus.isEmpty {
                    Text(credentialStatus)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func credentialField(
        title: String,
        text: Binding<String>,
        isSaved: Bool,
        save: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Theme.Space.inner) {
            SecureField(isSaved ? "Saved in Keychain" : title, text: text)
                .textFieldStyle(.roundedBorder)
            Button("Save", action: save)
                .controlSize(.small)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var customTools: some View {
        SettingsSection(title: "Custom CLI tools") {
            Text("Teach Update Scout about any tool by declaring how to read its version. No rebuild needed — the file is re-read on every scan.")
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

    private func saveOpenAIKey() {
        let value = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await SecureCredentialStore.shared.save(value, for: .openAIAPIKey)
                openAIKey = ""
                hasOpenAIKey = true
                credentialStatus = "OpenAI key saved securely"
            } catch {
                fileError = "Could not save the OpenAI key: \(error.localizedDescription)"
            }
        }
    }

    private func saveGoogleKey() {
        let value = googleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await SecureCredentialStore.shared.save(value, for: .googleAPIKey)
                googleKey = ""
                hasGoogleKey = true
                credentialStatus = "Google key saved securely"
            } catch {
                fileError = "Could not save the Google key: \(error.localizedDescription)"
            }
        }
    }

    private func saveAnthropicKey() {
        let value = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await SecureCredentialStore.shared.save(value, for: .anthropicAPIKey)
                anthropicKey = ""
                hasAnthropicKey = true
                credentialStatus = "Anthropic key saved securely"
            } catch {
                fileError = "Could not save the Anthropic key: \(error.localizedDescription)"
            }
        }
    }

    private func saveCustomAIKey() {
        let value = customAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await SecureCredentialStore.shared.save(value, for: .customAIAPIKey)
                customAIKey = ""
                hasCustomAIKey = true
                credentialStatus = "Custom AI key saved securely"
            } catch {
                fileError = "Could not save the custom AI key: \(error.localizedDescription)"
            }
        }
    }

    private func refreshCredentialStatus() async {
        hasOpenAIKey = ((try? await SecureCredentialStore.shared.load(.openAIAPIKey)) ?? nil) != nil
        hasAnthropicKey = ((try? await SecureCredentialStore.shared.load(.anthropicAPIKey)) ?? nil) != nil
        hasGoogleKey = ((try? await SecureCredentialStore.shared.load(.googleAPIKey)) ?? nil) != nil
        hasCustomAIKey = ((try? await SecureCredentialStore.shared.load(.customAIAPIKey)) ?? nil) != nil
    }

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
