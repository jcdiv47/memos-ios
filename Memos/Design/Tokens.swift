import SwiftUI

// The layout tokens. Every padding, gap and corner in the app comes from here, so screens built
// months apart still line up. See `design/DESIGN_SYSTEM.md` for when to use which.

/// A 4-point scale, with 2 and 6 for the tight spots inside a row.
enum Spacing {
    /// Between a title and its subtitle.
    static let xxs: CGFloat = 2
    /// Between an icon and its label in a pill; between lines of metadata.
    static let xs: CGFloat = 4
    /// Between list items, pills in a row, a stat and its label.
    static let s: CGFloat = 6
    /// Between an icon and its text; a small gap above a footer.
    static let m: CGFloat = 8
    /// Between blocks inside a card, and between cards.
    static let l: CGFloat = 12
    /// Screen margins and card padding.
    static let xl: CGFloat = 16
    /// Around empty states and sheets with a single message.
    static let xxl: CGFloat = 24
    /// Between unrelated groups on one screen.
    static let xxxl: CGFloat = 32
}

/// Corner radii. Corners get smaller as surfaces nest, so an inner corner never looks rounder
/// than the one around it.
enum Radius {
    /// Tiles packed into a grid: photos in a memo, the attachment library.
    static let tight: CGFloat = 6
    /// Anything inside a card or a sheet: a single photo, code, a file, an icon tile, a notice.
    static let inner: CGFloat = 10
    /// Cards and grouped lists, the opaque paper every memo sits on.
    static let card: CGFloat = 16
    /// An opaque panel floating on its own, such as a message over the map.
    static let panel: CGFloat = 24
}

/// Named layout measurements built from the scales above.
enum Metrics {
    /// The left and right margin of every scrolling screen.
    static let screenInset = Spacing.xl
    /// Inside a card.
    static let cardPadding = Spacing.xl
    /// Between cards in a column.
    static let cardGap = Spacing.l
    /// Between blocks inside a card: header, text, photos, reactions.
    static let blockGap = Spacing.l
    /// Above and below the text of a row in a card list.
    static let rowPadding = Spacing.l
    /// The smallest thing a finger should have to hit.
    static let minTapTarget: CGFloat = 44
    /// The square behind a row's or tile's symbol.
    static let iconTile: CGFloat = 32
    /// Where a row's text starts when the row leads with an icon tile or an emoji.
    static let iconRowTextInset = iconTile + Spacing.l
    /// The widest a column of text should run on a wide screen, an unfolded iPhone or an iPad,
    /// before it gets hard to read.
    static let readableWidth: CGFloat = 680
    /// Space at the bottom of a scrolling screen so the last item clears a floating bar.
    static let floatingBarClearance: CGFloat = 80

    /// How much fixed shapes beside text, such as icon tiles and avatars, may grow with Dynamic
    /// Type. They keep pace with the text up to here, then stop so they don't crowd it out.
    static let maxSymbolScale: CGFloat = 1.6

    /// `length` grown by a `@ScaledMetric` factor, up to ``maxSymbolScale``.
    static func scaled(_ length: CGFloat, by factor: CGFloat) -> CGFloat {
        (length * min(factor, maxSymbolScale)).rounded()
    }
}

/// The Dynamic Type growth factor for shapes that sit beside 15-point text. Use with
/// ``Metrics/scaled(_:by:)``: `@ScaledMetric(relativeTo: .subheadline) private var scale = SymbolScale.base`.
enum SymbolScale {
    static let base: CGFloat = 1
}

/// The glass bars we place by hand: the memo's react, comment and share bar, and the composer's
/// formatting bar. The system draws the navigation and bottom toolbars itself.
enum FloatingBar {
    /// A round button's diameter, and the height of a capsule beside it.
    static let height: CGFloat = 48
    /// One symbol button inside a capsule group.
    static let itemWidth: CGFloat = 44
}

/// Avatar diameters.
enum AvatarSize {
    /// A memo's author, a comment, a list row.
    static let small: CGFloat = 28
    /// An Inbox notification.
    static let medium: CGFloat = 32
    /// The account in Settings.
    static let large: CGFloat = 52
}

/// Line widths.
enum Stroke {
    /// A card's edge.
    static let hairline: CGFloat = 0.5
    /// A card's edge with Increase Contrast, and the ring around today in the activity grid.
    static let emphasized: CGFloat = 1
}

extension ShapeStyle where Self == Color {
    /// Memos Blue as a faint wash behind something chosen or tappable: a prominent chip, your own
    /// reaction, an icon tile with something in it.
    static var accentWash: Color { .memosBlue.opacity(0.12) }
    /// Memos Blue behind a word search matched.
    static var searchHighlight: Color { .memosBlue.opacity(0.18) }
}
