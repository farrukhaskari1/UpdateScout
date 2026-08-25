import SwiftUI
import AppKit

/// One outdated thing: icon, name, old → new, and a way to act on it.
@MainActor
struct UpdateRow: View {
    let item: UpdateItem
    let justCopied: Bool
    let onUpdate: () -> Void
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onIgnore: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.inner) {
            Button(action: primaryAction) {
                HStack(spacing: Theme.Space.inner) {
                    SourceIcon(item: item)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(Theme.Font.body)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        versionLine
                    }

                    Spacer(minLength: Theme.Space.inner)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.versionSummary)
            .accessibilityHint(helpText)

            trailing
                .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.inner)
        .background(hovering ? Theme.hover : .clear)
        .onHover { hovering = $0 }
        .contextMenu { rowMenu }
        .help(helpText)
    }

    // MARK: - Version

    private var versionLine: some View {
        HStack(spacing: Theme.Space.tight) {
            // Some sources can't tell us what's installed — show just the new
            // version rather than a meaningless "— → 1.2".
            if Version.isUsable(item.installedVersion) {
                Text(item.installedVersion)
                    .font(Theme.Font.mono)
                    .foregroundStyle(.secondary)

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(item.latestVersion)
                .font(Theme.Font.monoEmphasis)
                .foregroundStyle(bumpColor)

            if item.bump == .major {
                Text("major")
                    .font(Theme.Font.label)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Theme.Space.tight + 1)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
        }
        .lineLimit(1)
    }

    // MARK: - Actions

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: Theme.Space.tight) {
            if justCopied {
                Image(systemName: "checkmark")
                    .font(Theme.Font.label)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Command copied")
            } else if hovering {
                if item.upgradeCommand != nil {
                    RowButton(systemName: "doc.on.doc", help: "Copy upgrade command", action: onCopy)
                }
                if item.infoURL != nil {
                    RowButton(
                        systemName: "arrow.up.forward",
                        help: item.upgradeCommand == nil ? "Open download page" : "Open release notes",
                        action: onOpen
                    )
                }
            }

            if item.upgradeCommand != nil {
                Button("Update", action: onUpdate)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Update \(item.name) in Terminal")
            } else if item.infoURL != nil {
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open the download page for \(item.name)")
            }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if let command = item.upgradeCommand {
            Button("Update in Terminal") { onUpdate() }
            Divider()
            Button("Copy “\(command)”") { onCopy() }
        }
        if item.infoURL != nil {
            Button(item.upgradeCommand == nil ? "Open download page" : "Open release notes") { onOpen() }
        }
        if let path = item.iconPath {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        if item.ignoreKey != nil {
            Divider()
            Button("Stop reporting \(item.name)") { onIgnore() }
        }
    }

    private var helpText: String {
        if item.upgradeCommand != nil { return "Update \(item.name) in Terminal" }
        return "Open the download page for \(item.name)"
    }

    private func primaryAction() {
        if item.upgradeCommand != nil { onUpdate() } else { onOpen() }
    }

    private var bumpColor: Color {
        switch item.bump {
        case .major: return .orange
        case .minor: return .accentColor
        case .patch: return .secondary
        }
    }
}
