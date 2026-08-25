import SwiftUI
import AppKit

/// One outdated thing: icon, name, old → new, and a way to act on it.
@MainActor
struct UpdateRow: View {
    let item: UpdateItem
    let justCopied: Bool
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onIgnore: () -> Void

    @State private var hovering = false

    var body: some View {
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

            trailing
                .animation(.easeInOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.vertical, Theme.Space.inner)
        .contentShape(Rectangle())
        .background(hovering ? Theme.hover : .clear)
        .onHover { hovering = $0 }
        .onTapGesture {
            if item.upgradeCommand != nil { onCopy() } else { onOpen() }
        }
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
        if justCopied {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: "checkmark")
                Text("Copied")
            }
            .font(Theme.Font.label)
            .foregroundStyle(.green)
        } else if hovering {
            HStack(spacing: 2) {
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
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if let command = item.upgradeCommand {
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
        if let command = item.upgradeCommand { return "Click to copy: \(command)" }
        return "Update this one from inside the app — click to open its page"
    }

    private var bumpColor: Color {
        switch item.bump {
        case .major: return .orange
        case .minor: return .accentColor
        case .patch: return .secondary
        }
    }
}

/// Compact hover action button used inside a row.
private struct RowButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
