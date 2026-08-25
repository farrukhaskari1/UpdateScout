import AppKit
import SwiftUI

/// Real Finder icons for the apps in the list.
///
/// `NSWorkspace.icon(forFile:)` hits the disk, and the menu re-renders on every
/// hover, so results are cached for the lifetime of the process.
@MainActor
final class AppIconLoader {

    static let shared = AppIconLoader()

    private var cache: [String: NSImage?] = [:]

    private init() {}

    func icon(atPath path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = cache[path] { return cached }

        var image: NSImage?
        if FileManager.default.fileExists(atPath: path) {
            let loaded = NSWorkspace.shared.icon(forFile: path)
            // 2× the largest slot we draw into, so Retina picks a crisp rep.
            loaded.size = NSSize(width: 64, height: 64)
            image = loaded
        }
        cache[path] = image
        return image
    }
}

/// An app's own icon when we can find one, otherwise a tinted glyph standing in
/// for the source it came from.
struct SourceIcon: View {
    let item: UpdateItem
    var side: CGFloat = Theme.iconSide

    var body: some View {
        Group {
            if let icon = AppIconLoader.shared.icon(atPath: item.iconPath) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .overlay(
                        Image(systemName: item.source.symbol)
                            .font(.system(size: side * 0.5, weight: .medium))
                            .foregroundStyle(tint)
                    )
            }
        }
        .frame(width: side, height: side)
    }

    private var tint: Color {
        switch item.source {
        case .macOSSystem:                    return .primary
        case .homebrewCask, .homebrewFormula: return .orange
        case .macAppStore:                    return .blue
        case .sparkleApp, .githubApp:         return .purple
        case .mise, .rustup:                  return .pink
        default:                              return .teal
        }
    }
}
