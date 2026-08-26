import SwiftUI
import AppKit

/// One outdated thing: icon, name, old → new, and a way to act on it.
@MainActor
struct UpdateRow: View {
    let item: UpdateItem
    let executionState: UpdateExecutionState
    let updatesDisabled: Bool
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

                        if let detail = executionState.detail {
                            Text(detail)
                                .font(Theme.Font.caption)
                                .foregroundStyle(executionState.isPermissionRequired ? .orange : .red)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: Theme.Space.inner)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.versionSummary)
            .accessibilityHint(helpText)
            .disabled(updatesDisabled && item.upgradeCommand != nil)

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
                executionButton
            } else if item.infoURL != nil {
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open the download page for \(item.name)")
            }
        }
    }

    @ViewBuilder
    private var executionButton: some View {
        Group {
            switch executionState {
            case .idle:
                Button("Update", action: onUpdate)
                    .disabled(updatesDisabled)
                    .help("Run the update inside Update Scout")
            case .queued:
                Button("Queued", action: {})
                    .disabled(true)
            case .running:
                Button(action: {}) {
                    HStack(spacing: Theme.Space.tight) {
                        ProgressView().controlSize(.mini)
                        Text("Updating")
                    }
                }
                .disabled(true)
            case .succeeded:
                Button("Updated", systemImage: "checkmark", action: {})
                    .disabled(true)
            case .permissionRequired:
                Button(
                    justCopied ? "Copied" : "Copy Command",
                    systemImage: justCopied ? "checkmark" : "doc.on.doc",
                    action: onCopy
                )
                .help("Copy the command to run it manually")
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise", action: onUpdate)
                    .disabled(updatesDisabled)
                    .help("Try this update again")
            case .stopped:
                Button("Stopped", systemImage: "stop.fill", action: {})
                    .disabled(true)
                    .help("Refresh before retrying this update")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var rowMenu: some View {
        if let command = item.upgradeCommand {
            Button("Run Update") { onUpdate() }
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
        if item.upgradeCommand != nil { return "Run the \(item.name) update inside Update Scout" }
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
