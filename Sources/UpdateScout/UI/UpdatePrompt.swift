import Foundation

struct UpdatePrompt: Identifiable {
    enum Kind {
        case confirmation([UpdateItem])
        case failure(String)
    }

    let id = UUID()
    let kind: Kind

    static func confirmation(for items: [UpdateItem]) -> UpdatePrompt {
        UpdatePrompt(kind: .confirmation(items.filter { $0.upgradeCommand != nil }))
    }

    static func failure(_ message: String) -> UpdatePrompt {
        UpdatePrompt(kind: .failure(message))
    }
}
