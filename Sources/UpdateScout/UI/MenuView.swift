import SwiftUI
import AppKit

@MainActor
struct MenuView: View {
    @EnvironmentObject private var store: UpdateStore
    @ObservedObject private var settings = UserSettings.shared

    @State private var query = ""
    @State private var scope: MenuScope = .all
    @State private var showingSettings = false
    @State private var copiedItemID: String?

    var body: some View {
        // Grouped once per render: filtering, grouping and sorting the whole
        // item list is not something to repeat for each subview that asks.
        let groups = store.groupedItems(matching: query, scope: scope)

        VStack(spacing: 0) {
            header

            if showingSettings {
                Divider()
                SettingsPane()
                    .environmentObject(store)
            } else {
                if !store.items.isEmpty { filterBar(groups) }
                Divider()
                content(groups)
            }

            Divider()
            footer(groups)
        }
        .frame(width: 420)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.inner) {
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

            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16)
            }

            IconButton(
                systemName: store.isScanning ? "xmark" : "arrow.clockwise",
                help: store.isScanning ? "Stop checking" : "Check for updates now"
            ) {
                if store.isScanning { store.cancelScan() } else { store.refresh() }
            }

            IconButton(
                systemName: showingSettings ? "chevron.backward" : "gearshape",
                help: showingSettings ? "Back to updates" : "Settings"
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { showingSettings.toggle() }
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
            .overlay(
                Image(systemName: store.items.isEmpty ? "checkmark" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusTint)
            )
    }

    private var statusTint: Color { store.items.isEmpty ? .green : .accentColor }

    private var headline: String {
        if store.items.isEmpty { return store.isScanning ? "Checking…" : "Up to date" }
        return store.items.count == 1 ? "1 update" : "\(store.items.count) updates"
    }

    private var subhead: String {
        if store.isScanning, !store.progressLabel.isEmpty { return store.progressLabel }
        var pieces: [String] = []
        if store.applicationCount > 0 { pieces.append("\(store.applicationCount) app\(store.applicationCount == 1 ? "" : "s")") }
        if store.toolCount > 0 { pieces.append("\(store.toolCount) tool\(store.toolCount == 1 ? "" : "s")") }
        if let last = store.lastScan {
            pieces.append("checked \(Self.relative.localizedString(for: last, relativeTo: Date()))")
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

    // MARK: - Filter bar

    /// Two full-width rows rather than one cramped line. Golden Gate's toolbar
    /// guidance is uniformity and legibility over density, and three controls
    /// fighting for 420pt was the opposite of both.
    private func filterBar(_ groups: [SourceGroup]) -> some View {
        VStack(spacing: Theme.Space.inner) {
            searchField

            HStack(spacing: Theme.Space.inner) {
                Picker("", selection: $scope) {
                    ForEach(MenuScope.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)

                let ids = groups.map(\.id)
                let collapsedAll = !ids.isEmpty && ids.allSatisfy { settings.isCollapsed($0) }

                IconButton(
                    systemName: collapsedAll ? "chevron.down" : "chevron.up",
                    help: collapsedAll ? "Expand all sections" : "Collapse all sections"
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        settings.setAllCollapsed(!collapsedAll, groupIDs: ids)
                    }
                }
                .disabled(ids.isEmpty)
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.bottom, Theme.Space.row)
    }

    /// Full width, with the clear button inside the field at the trailing edge
    /// where macOS puts it — not floating between two other controls.
    private var searchField: some View {
        HStack(spacing: Theme.Space.inner) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)

            TextField("Search updates", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.control)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.inner)
        .padding(.vertical, Theme.Space.tight + 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.subtleFill)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ groups: [SourceGroup]) -> some View {
        // Notes about pip belong on the Tools tab, not the Apps tab.
        let notes = store.issues.filter { scope.includes(sourceKind: $0.source) }

        if groups.isEmpty && notes.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty { emptyState.frame(maxWidth: .infinity) }

                    ForEach(groups) { group in
                        SectionDisclosure(
                            title: group.title,
                            symbol: group.symbol,
                            count: group.items.count,
                            isCollapsed: settings.isCollapsed(group.id)
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                settings.toggleCollapsed(group.id)
                            }
                        }

                        if !settings.isCollapsed(group.id) {
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
        if store.isScanning { return "Checking…" }
        if !store.items.isEmpty { return "Nothing to show" }
        return "Everything is up to date"
    }

    private var emptyDetail: String {
        if store.isScanning { return store.progressLabel }
        if !store.items.isEmpty {
            // The list can be emptied by the search field or by the scope
            // picker, and those want different sentences.
            if query.isEmpty { return "No \(scope.label.lowercased()) need updating right now." }
            return "Nothing matches “\(query)”."
        }
        guard let last = store.lastScan else { return "" }
        return "Last checked \(Self.relative.localizedString(for: last, relativeTo: Date()))."
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
        // Copy what's on screen, not everything: with the scope set to Apps,
        // copying the tool commands too would be a nasty surprise.
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
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedItemID == item.id {
                withAnimation(.easeInOut(duration: 0.15)) { copiedItemID = nil }
            }
        }
    }
}

// MARK: - Section header

/// A whole-width button, so the entire header row toggles the section rather
/// than only the chevron.
private struct SectionDisclosure: View {
    let title: String
    let symbol: String
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Space.inner) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    // Occupies the icon column so the label lines up with the
                    // row names underneath it.
                    .frame(width: Theme.iconSide, alignment: .center)

                Text(title)
                    .font(Theme.Font.label)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Text("\(count)")
                    .font(Theme.Font.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.tight + 1)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.subtleFill))

                Spacer()

                Image(systemName: symbol)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.vertical, Theme.Space.inner)
            .contentShape(Rectangle())
            .background(hovering ? Theme.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Toolbar button

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Color.secondary : Theme.disabledLabel)
                .frame(width: Theme.iconSide, height: Theme.iconSide)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(hovering && isEnabled ? Theme.hover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
