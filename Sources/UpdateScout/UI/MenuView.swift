import SwiftUI
import AppKit

@MainActor
struct MenuView: View {
    @EnvironmentObject private var store: UpdateStore

    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var showingSettings = false
    @State private var copiedItemID: String?
    @State private var updatePrompt: UpdatePrompt?

    var body: some View {
        // Grouped once per render: filtering, grouping and sorting the whole
        // item list is not something to repeat for each subview that asks.
        let groups = store.groupedItems(matching: query)

        VStack(spacing: 0) {
            MenuHeader(
                query: $query,
                isSearchPresented: $isSearchPresented,
                showingSettings: showingSettings,
                onToggleSettings: toggleSettings
            )
            .environmentObject(store)

            if showingSettings {
                Divider()
                SettingsPane()
                    .environmentObject(store)
            } else {
                Divider()
                content(groups)
            }

            if let updatePrompt, !showingSettings {
                Divider()
                UpdateConfirmationBar(
                    prompt: updatePrompt,
                    onConfirm: confirmUpdate,
                    onCancel: cancelUpdateConfirmation
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Divider()
            footer(groups)
        }
        .frame(width: 420)
        .onChange(of: store.isScanning) { scanning in
            if scanning {
                query = ""
                isSearchPresented = false
                updatePrompt = nil
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ groups: [SourceGroup]) -> some View {
        let notes = store.issues

        if groups.isEmpty && notes.isEmpty {
            if !query.isEmpty {
                searchEmptyState
                    .frame(maxWidth: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        SourceSectionHeader(
                            title: group.title,
                            symbol: group.symbol,
                            count: group.items.count
                        )

                        ForEach(group.items) { item in
                            UpdateRow(
                                item: item,
                                executionState: store.updateState(for: item),
                                updatesDisabled: store.isScanning || store.isUpdating,
                                justCopied: copiedItemID == item.id,
                                onUpdate: { requestUpdate([item]) },
                                onCopy: { copy(item) },
                                onOpen: { store.openInfo(for: item) },
                                onIgnore: { store.ignore(item) }
                            )
                        }
                    }

                    if !notes.isEmpty { notesBlock(notes) }
                }
                .padding(.bottom, Theme.Space.inner)
            }
            // Height lives on the scroll area rather than the whole VStack: a
            // `.window` MenuBarExtra doesn't reliably give a nested ScrollView a
            // content-derived ideal height, and clamping the outer stack can pin
            // the panel to its minimum regardless of how many rows there are.
            .frame(minHeight: 180, maxHeight: 560)
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: Theme.Space.inner) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No matching updates")
                .font(Theme.Font.body)

            Text("Try a different app or tool name.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.section)
    }

    // MARK: - Notes (skips and failures)

    private func notesBlock(_ notes: [ScanIssue]) -> some View {
        let failures = notes.filter { $0.severity == .failed }

        return VStack(alignment: .leading, spacing: Theme.Space.inner) {
            Text(failures.isEmpty ? "Not checked" : "Needs attention")
                .font(Theme.Font.label)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            ForEach(notes) { note in
                noteRow(note)
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, Theme.Space.row)
    }

    private func noteRow(_ note: ScanIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.inner) {
            Image(systemName: note.severity.symbol)
                .font(Theme.Font.caption)
                // A deliberate skip is information, not a warning. Only real
                // failures get to use the alarming colour.
                .foregroundStyle(note.severity == .failed ? Color.orange : Color.secondary)
                .frame(width: Theme.iconSide - Theme.Space.tight, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.source.title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.primary)
                Text(note.message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private func footer(_ groups: [SourceGroup]) -> some View {
        // During a search, copy only the commands in the visible result set.
        let visible = showingSettings
            ? []
            : groups.flatMap(\.items).filter { $0.upgradeCommand != nil }
        let allRunnable = store.isScanning
            ? []
            : uniqueRunnableItems(store.items.filter(store.canRunUpdate))
        let permissionFallbacks = uniqueRunnableItems(
            store.items.filter { store.updateState(for: $0).isPermissionRequired }
        )
        let total = allRunnable.count

        return HStack(spacing: Theme.Space.row) {
            if showingSettings {
                Text("Updates run only after confirmation")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            } else {
                if store.isUpdating {
                    Button("Stop Updates", systemImage: "stop.fill", action: store.cancelUpdates)
                        .font(Theme.Font.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Stop the current update and clear the queue")
                } else if !allRunnable.isEmpty {
                    Button(action: { requestUpdate(allRunnable) }) {
                        Label("Update All", systemImage: "arrow.down.circle")
                            .font(Theme.Font.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Run all \(total) updates inside UpdateScout")
                } else {
                    Button(emptyUpdateLabel, systemImage: emptyUpdateSymbol, action: {})
                        .font(Theme.Font.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(true)
                        .help(emptyUpdateHelp)
                }

                if permissionFallbacks.isEmpty {
                    Button {
                        store.copyCommands(for: visible)
                    } label: {
                        Label("Copy visible commands", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(visible.isEmpty ? Color.secondary : Color.accentColor)
                    .disabled(visible.isEmpty)
                    .help(visible.isEmpty
                          ? "Nothing to copy"
                          : "Copy \(visible.count) upgrade command\(visible.count == 1 ? "" : "s")")
                } else {
                    Button("Copy Blocked", systemImage: "doc.on.doc") {
                        store.copyCommands(for: permissionFallbacks)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy \(permissionFallbacks.count) command\(permissionFallbacks.count == 1 ? "" : "s") that need permission")
                }
            }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.inner + 2)
    }

    private var emptyUpdateLabel: String {
        if store.isScanning { "Checking…" }
        else if store.items.isEmpty { "Up to Date" }
        else if hasStoppedUpdate { "Refresh Needed" }
        else if allCommandUpdatesSucceeded { "All Updated" }
        else { "Manual Updates" }
    }

    private var emptyUpdateSymbol: String {
        if store.isScanning { "ellipsis" }
        else if store.items.isEmpty { "checkmark" }
        else if hasStoppedUpdate { "arrow.clockwise" }
        else if allCommandUpdatesSucceeded { "checkmark" }
        else { "hand.raised" }
    }

    private var emptyUpdateHelp: String {
        if store.isScanning { "Wait for the update check to finish" }
        else if store.items.isEmpty { "No updates are available" }
        else if hasStoppedUpdate { "Refresh to verify the stopped update before trying again" }
        else if allCommandUpdatesSucceeded { "All command-based updates finished" }
        else { "These items must be opened and updated manually" }
    }

    private var hasStoppedUpdate: Bool {
        store.items.contains { item in
            if case .stopped = store.updateState(for: item) { true } else { false }
        }
    }

    private var allCommandUpdatesSucceeded: Bool {
        let commandItems = store.items.filter { $0.upgradeCommand != nil }
        return !commandItems.isEmpty && commandItems.allSatisfy {
            store.updateState(for: $0) == .succeeded
        }
    }

    private func requestUpdate(_ items: [UpdateItem]) {
        let prompt = UpdatePrompt.confirmation(for: items)
        guard !prompt.items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { updatePrompt = prompt }
    }

    private func confirmUpdate() {
        guard let prompt = updatePrompt else { return }
        withAnimation(.easeInOut(duration: 0.15)) { updatePrompt = nil }
        store.startUpdates(prompt.items)
    }

    private func cancelUpdateConfirmation() {
        withAnimation(.easeInOut(duration: 0.15)) { updatePrompt = nil }
    }

    /// A single command such as `rustup update` may represent several rows.
    /// Update All should run it once, not once per reported toolchain.
    private func uniqueRunnableItems(_ items: [UpdateItem]) -> [UpdateItem] {
        var commands = Set<String>()
        return items.filter { item in
            guard let command = item.upgradeCommand else { return false }
            return commands.insert(command).inserted
        }
    }

    private func copy(_ item: UpdateItem) {
        store.copyCommand(for: item)
        withAnimation(.easeInOut(duration: 0.15)) { copiedItemID = item.id }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedItemID == item.id {
                withAnimation(.easeInOut(duration: 0.15)) { copiedItemID = nil }
            }
        }
    }

    private func toggleSettings() {
        if !showingSettings {
            query = ""
            isSearchPresented = false
            updatePrompt = nil
        }
        withAnimation(.easeInOut(duration: 0.15)) { showingSettings.toggle() }
    }
}
