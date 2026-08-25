struct UpdatePrompt {
    let items: [UpdateItem]

    static func confirmation(for items: [UpdateItem]) -> UpdatePrompt {
        UpdatePrompt(items: items.filter { $0.upgradeCommand != nil })
    }

    var title: String {
        if items.count == 1 {
            let itemName = items.first?.name ?? "this item"
            return "Update \(itemName)?"
        }
        return "Run \(items.count) updates?"
    }

    var summary: String {
        if items.count == 1 {
            "UpdateScout will run this command inside the app. macOS may ask for administrator permission."
        } else {
            "UpdateScout will run these commands one by one. You can stop the queue at any time."
        }
    }

    var commandPreview: String? {
        items.count == 1 ? items.first?.upgradeCommand : nil
    }

    var confirmLabel: String {
        items.count == 1 ? "Update" : "Update All"
    }
}
