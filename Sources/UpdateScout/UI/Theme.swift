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

    /// Five sizes, none below 11pt.
    ///
    /// macOS 27's design pass is explicitly about readability and contrast, and
    /// the 8–10pt text this replaced failed both. Hierarchy comes from weight
    /// and colour, not from shrinking text until it disappears.
    enum Font {
        /// Window title.
        static let title = SwiftUI.Font.system(size: 14, weight: .semibold)
        /// Row names, primary content.
        static let body = SwiftUI.Font.system(size: 13, weight: .medium)
        /// Controls and buttons — matches the macOS small-control size.
        static let control = SwiftUI.Font.system(size: 12)
        /// Subtitles and secondary content.
        static let caption = SwiftUI.Font.system(size: 11.5)
        /// Uppercase section labels and count badges.
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// Version strings — monospaced so digits line up column to column.
        static let mono = SwiftUI.Font.system(size: 11.5, design: .monospaced)
        static let monoEmphasis = SwiftUI.Font.system(size: 11.5, weight: .semibold, design: .monospaced)
    }

    // MARK: - Shape

    enum Radius {
        static let control: CGFloat = 6
    }

    /// Height of a row's leading icon. Section chevrons and the header badge
    /// occupy the same width, so every text column in the window lines up.
    static let iconSide: CGFloat = 22

    // MARK: - Colour

    /// Hover highlight, matching the weight AppKit menus use.
    static let hover = Color.primary.opacity(0.06)
    /// Fill behind count badges and the search field.
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.4)
    /// Disabled control glyphs.
    static let disabledLabel = Color(nsColor: .tertiaryLabelColor)
}
