import SwiftUI
import AppKit

@MainActor
struct MenuView: View {
    @EnvironmentObject private var store: UpdateStore

    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var showingSettings = false
    @State private var copiedItemID: String?

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

            Divider()
            footer(groups)
        }
        .frame(width: 420)
        .onChange(of: store.isScanning) { scanning in
            if scanning {
                query = ""
                isSearchPresented = false
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
                                justCopied: copiedItemID == item.id,
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
        let total = store.items.filter { $0.upgradeCommand != nil }.count

        return HStack(spacing: Theme.Space.row) {
            if showingSettings {
                Text("Never installs anything")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    store.copyCommands(for: visible)
                } label: {
                    Label(visible.count == total ? "Copy commands" : "Copy \(visible.count) shown",
                          systemImage: "doc.on.doc")
                        .font(Theme.Font.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(visible.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(visible.isEmpty)
                .help(visible.isEmpty
                      ? "Nothing to copy"
                      : "Copy \(visible.count) upgrade command\(visible.count == 1 ? "" : "s")")
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
        }
        withAnimation(.easeInOut(duration: 0.15)) { showingSettings.toggle() }
    }
}
