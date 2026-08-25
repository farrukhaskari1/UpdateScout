import SwiftUI
import AppKit

/// The whole visual vocabulary of the app, in one place.
///
/// Five type sizes and a 4pt spacing grid. Anything that needs a sixth size or
/// an off-grid inset is a design problem, not a licence to add a constant.
enum Theme {

    // MARK: - Spacing (4pt grid)

    enum Space {
        /// Gap between tightly related items — icon and its label.
        static let tight: CGFloat = 4
        /// Standard gap inside a row.
        static let inner: CGFloat = 8
        /// Row vertical padding, gap between groups of controls.
        static let row: CGFloat = 12
        /// Content inset from the window edge.
        static let edge: CGFloat = 16
        /// Separation between major blocks.
        static let section: CGFloat = 24
    }

    // MARK: - Type scale

    /// Semantic styles honor the user's system text-size preferences.
    enum Font {
        static let title = SwiftUI.Font.headline
        static let body = SwiftUI.Font.callout
        static let control = SwiftUI.Font.callout
        static let caption = SwiftUI.Font.caption
        static let label = SwiftUI.Font.caption.bold()
        static let mono = SwiftUI.Font.caption.monospaced()
        static let monoEmphasis = SwiftUI.Font.caption.monospaced().bold()
    }

    // MARK: - Shape

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
    }

    /// Height of a row's leading icon. Section chevrons and the header badge
    /// occupy the same width, so every text column in the window lines up.
    static let iconSide: CGFloat = 22

    // MARK: - Colour

    /// Hover highlight, matching the weight AppKit menus use.
    static let hover = Color.primary.opacity(0.06)
    /// Fill behind count badges and transient search.
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.4)
    /// Disabled control glyphs.
    static let disabledLabel = Color(nsColor: .tertiaryLabelColor)
}
