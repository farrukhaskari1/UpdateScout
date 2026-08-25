enum UpdatePrompt {
    case updates([UpdateItem])
    case recovery(ScanIssue)

    static func confirmation(for items: [UpdateItem]) -> UpdatePrompt {
        .updates(items.filter { $0.upgradeCommand != nil })
    }

    static func confirmation(for issue: ScanIssue) -> UpdatePrompt? {
        guard issue.recovery != nil else { return nil }
        return .recovery(issue)
    }

    var items: [UpdateItem] {
        if case .updates(let items) = self { items } else { [] }
    }

    var title: String {
        switch self {
        case .updates(let items) where items.count == 1:
            "Update \(items.first?.name ?? "this item")?"
        case .updates(let items):
            "Run \(items.count) updates?"
        case .recovery(let issue):
            "\(issue.recovery?.label ?? "Fix")?"
        }
    }

    var summary: String {
        switch self {
        case .updates(let items) where items.count == 1:
            "UpdateScout will run this command inside the app. macOS may ask for administrator permission."
        case .updates:
            "UpdateScout will run these commands one by one. You can stop the queue at any time."
        case .recovery(let issue)
            where issue.recovery?.command != nil && issue.recovery?.disablesSource != nil:
            "UpdateScout will install the safer package tool, switch source tracking to it, then check again. Existing packages are not moved."
        case .recovery(let issue) where issue.recovery?.command != nil:
            "UpdateScout will run this setup command inside the app, then check your sources again."
        case .recovery:
            "UpdateScout will switch source tracking to the safer package tool, then check again. Existing packages are not moved."
        }
    }

    var commandPreview: String? {
        switch self {
        case .updates(let items):
            items.count == 1 ? items.first?.upgradeCommand : nil
        case .recovery(let issue):
            issue.recovery?.command
        }
    }

    var confirmLabel: String {
        switch self {
        case .updates(let items): items.count == 1 ? "Update" : "Update All"
        case .recovery(let issue): issue.recovery?.label ?? "Fix"
        }
    }
}
