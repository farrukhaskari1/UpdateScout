import SwiftUI

/// Stable panel navigation with transient status and search beneath it.
struct MenuHeader: View {
    @EnvironmentObject private var store: UpdateStore

    @Binding var query: String
    @Binding var isSearchPresented: Bool
    let showingSettings: Bool
    let onToggleSettings: () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            toolbar

            if !showingSettings {
                if isSearchPresented {
                    searchField
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    statusCard
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.row)
        .onChange(of: isSearchPresented) { presented in
            if presented {
                Task {
                    await Task.yield()
                    isSearchFocused = true
                }
            } else {
                isSearchFocused = false
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.inner) {
            if showingSettings {
                IconButton(
                    systemName: "chevron.backward",
                    help: "Back to updates",
                    action: onToggleSettings
                )

                Text("Settings")
                    .font(Theme.Font.title)
            } else {
                Text("UpdateScout")
                    .font(Theme.Font.title)

                Spacer(minLength: Theme.Space.inner)

                if !store.isScanning && (isSearchPresented || !store.items.isEmpty) {
                    IconButton(
                        systemName: isSearchPresented ? "xmark" : "magnifyingglass",
                        help: isSearchPresented ? "Close search" : "Search updates",
                        action: toggleSearch
                    )
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
                    systemName: "gearshape",
                    help: "Settings",
                    action: onToggleSettings
                )
            }

            if showingSettings { Spacer() }
        }
    }

    private var statusCard: some View {
        HStack(spacing: Theme.Space.row) {
            statusIndicator

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(headline)
                    .font(Theme.Font.body.bold())

                Text(subhead)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.inner)
        }
        .padding(Theme.Space.row)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.subtleFill)
        )
        .accessibilityElement(children: .combine)
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusTint.opacity(0.14))
            .frame(width: 28, height: 28)
            .overlay {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(statusTint)
                } else {
                    Image(systemName: statusSymbol)
                        .font(Theme.Font.caption.bold())
                        .foregroundStyle(statusTint)
                }
            }
            .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.inner) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search apps and tools", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.control)
                .focused($isSearchFocused)
                .onExitCommand(perform: closeSearch)
                .accessibilityLabel("Search updates")
        }
        .padding(Theme.Space.row)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.subtleFill)
        )
    }

    private var headline: String {
        if store.isScanning { return "Checking your Mac" }
        if !store.items.isEmpty {
            return store.items.count == 1 ? "1 update available" : "\(store.items.count) updates available"
        }
        if !store.hasCompletedScanThisLaunch { return "Ready when you are" }
        if store.hasFailures { return "Some checks need attention" }
        return "Everything is up to date"
    }

    private var subhead: String {
        if store.isScanning, !store.progressLabel.isEmpty { return store.progressLabel }

        var pieces: [String] = []
        if store.applicationCount > 0 {
            pieces.append("\(store.applicationCount) app\(store.applicationCount == 1 ? "" : "s")")
        }
        if store.toolCount > 0 {
            pieces.append("\(store.toolCount) tool\(store.toolCount == 1 ? "" : "s")")
        }
        if let last = store.lastScan {
            pieces.append("checked \(Self.relative.localizedString(for: last, relativeTo: .now))")
        } else if pieces.isEmpty {
            pieces.append("Check your apps and tools for updates")
        }
        return pieces.joined(separator: " · ")
    }

    private var statusTint: Color {
        if store.isScanning { return .accentColor }
        if store.hasFailures { return .orange }
        if !store.hasCompletedScanThisLaunch { return .secondary }
        return store.items.isEmpty ? .green : .accentColor
    }

    private var statusSymbol: String {
        if store.hasFailures { return "exclamationmark.triangle.fill" }
        if !store.hasCompletedScanThisLaunch { return "clock" }
        return store.items.isEmpty ? "checkmark" : "arrow.down"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func toggleSearch() {
        if isSearchPresented {
            closeSearch()
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { isSearchPresented = true }
        }
    }

    private func closeSearch() {
        isSearchFocused = false
        query = ""
        withAnimation(.easeInOut(duration: 0.15)) { isSearchPresented = false }
    }
}
