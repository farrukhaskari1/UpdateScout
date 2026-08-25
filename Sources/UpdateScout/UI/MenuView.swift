import SwiftUI
import AppKit

@MainActor
struct MenuView: View {
    @EnvironmentObject private var store: UpdateStore

    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var showingSettings = false
    @State private var copiedItemID: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        // Grouped once per render: filtering, grouping and sorting the whole
        // item list is not something to repeat for each subview that asks.
        let groups = store.groupedItems(matching: query)

        VStack(spacing: 0) {
            header

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
            if scanning { closeSearch() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.inner) {
            if isSearchPresented && !showingSettings {
                searchField
                    .transition(.opacity)
            } else {
                statusBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(Theme.Font.title)
                    Text(subhead)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Space.tight)
            }

            if !showingSettings && !store.isScanning && (isSearchPresented || !store.items.isEmpty) {
                IconButton(
                    systemName: isSearchPresented ? "xmark" : "magnifyingglass",
                    help: isSearchPresented ? "Close search" : "Search updates"
                ) {
                    isSearchPresented ? closeSearch() : openSearch()
                }
            }

            if store.isScanning {
                Button("Stop", systemImage: "stop.fill", action: store.cancelScan)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop checking for updates")
            } else {
                IconButton(
                    systemName: "arrow.clockwise",
                    help: "Check for updates now",
                    action: store.refresh
                )
            }

            IconButton(
                systemName: showingSettings ? "chevron.backward" : "gearshape",
                help: showingSettings ? "Back to updates" : "Settings"
            ) {
                toggleSettings()
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.row)
    }

    /// Same footprint as a row icon, so the title aligns with the rows below it.
    private var statusBadge: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(statusTint.opacity(0.15))
            .frame(width: Theme.iconSide, height: Theme.iconSide)
            .overlay {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(statusTint)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(statusTint)
                }
            }
            .accessibilityHidden(true)
    }

    private var statusTint: Color {
        if store.isScanning { return .accentColor }
        if store.hasFailures { return .orange }
        if !store.hasCompletedScanThisLaunch { return .secondary }
        return store.items.isEmpty ? .green : .accentColor
    }

    private var statusSymbol: String {
        if store.hasFailures { return "exclamationmark" }
        if !store.hasCompletedScanThisLaunch { return "questionmark" }
        return store.items.isEmpty ? "checkmark" : "arrow.down"
    }

    private var headline: String {
        if store.isScanning { return "Checking for updates" }
        if !store.items.isEmpty { return store.items.count == 1 ? "1 update" : "\(store.items.count) updates" }
        if !store.hasCompletedScanThisLaunch { return "Not checked" }
        if store.hasFailures { return "Check incomplete" }
        return "Up to date"
    }

    private var subhead: String {
        if store.isScanning, !store.progressLabel.isEmpty { return store.progressLabel }
        var pieces: [String] = []
        if store.applicationCount > 0 { pieces.append("\(store.applicationCount) app\(store.applicationCount == 1 ? "" : "s")") }
        if store.toolCount > 0 { pieces.append("\(store.toolCount) tool\(store.toolCount == 1 ? "" : "s")") }
        if let last = store.lastScan {
            pieces.append("checked \(Self.relative.localizedString(for: last, relativeTo: .now))")
        } else if pieces.isEmpty {
            pieces.append("not checked yet")
        }
        return pieces.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Search

    /// Search is an occasional header action, not permanent navigation. When
    /// active it borrows the title's space and keeps the primary actions put.
    private var searchField: some View {
        HStack(spacing: Theme.Space.inner) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)

            TextField("Apps and tools", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.control)
                .focused($isSearchFocused)
                .onExitCommand(perform: closeSearch)
                .accessibilityLabel("Search updates")
        }
        .padding(.horizontal, Theme.Space.inner)
        .padding(.vertical, Theme.Space.tight + 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.subtleFill)
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ groups: [SourceGroup]) -> some View {
        let notes = store.issues

        if groups.isEmpty && notes.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty { emptyState.frame(maxWidth: .infinity) }

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

    private var emptyState: some View {
        VStack(spacing: Theme.Space.inner) {
            Image(systemName: store.isScanning ? "hourglass" : "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(store.isScanning ? Color.secondary : .green)

            Text(emptyTitle)
                .font(Theme.Font.body)

            if !emptyDetail.isEmpty {
                Text(emptyDetail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, 40)
    }

    private var emptyTitle: String {
        if store.isScanning { return "Checking for updates" }
        if !store.items.isEmpty { return "Nothing to show" }
        if store.hasFailures { return "No updates found — some checks failed" }
        if !store.hasCompletedScanThisLaunch { return "Ready to check" }
        return "Everything is up to date"
    }

    private var emptyDetail: String {
        if store.isScanning { return store.progressLabel }
        if !store.items.isEmpty {
            return "Nothing matches “\(query)”."
        }
        guard let last = store.lastScan else { return "" }
        return "Last checked \(Self.relative.localizedString(for: last, relativeTo: .now))."
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

    private func openSearch() {
        withAnimation(.easeInOut(duration: 0.15)) { isSearchPresented = true }
        Task {
            await Task.yield()
            isSearchFocused = true
        }
    }

    private func closeSearch() {
        isSearchFocused = false
        query = ""
        withAnimation(.easeInOut(duration: 0.15)) { isSearchPresented = false }
    }

    private func toggleSettings() {
        if !showingSettings { closeSearch() }
        withAnimation(.easeInOut(duration: 0.15)) { showingSettings.toggle() }
    }
}
