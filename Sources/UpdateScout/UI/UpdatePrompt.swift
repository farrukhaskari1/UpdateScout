import Foundation

struct UpdatePrompt: Identifiable {
    let id = UUID()
    let items: [UpdateItem]

    static func confirmation(for items: [UpdateItem]) -> UpdatePrompt {
        UpdatePrompt(items: items.filter { $0.upgradeCommand != nil })
    }
}
