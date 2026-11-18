import SwiftUI

/// The type roles. Every style is a Dynamic Type text style, so it scales up to AX5. New York
/// stands in for the web wordmark's Source Serif and is used only for titles, so the timeline
/// reads as notes rather than a magazine. Pick by role, not by size: a view that wants “a bit
/// smaller” almost always wants the next role down.
extension Font {
    // MARK: Writing

    /// New York Bold, 34 pt: the large title.
    static let largeTitleSerif = Font.system(.largeTitle, design: .serif).bold()
    /// New York Semibold, 20 pt, from a memo's first heading, and an instance's name at sign-in.
    static let memoTitle = Font.system(.title3, design: .serif).weight(.semibold)
    /// SF Pro Text, 17 pt: what you wrote.
    static let memoBody = Font.body
    /// SF Mono, 15 pt: code, filters and links shown as text.
    static let memoCode = Font.system(.subheadline, design: .monospaced)

    // MARK: Interface

    /// 15 pt semibold, in Ink 2: the heading over a group of cards, such as “Saved views”.
    static let sectionTitle = Font.subheadline.weight(.semibold)
    /// 17 pt: the main line of a row in a card list.
    static let rowTitle = Font.body
    /// 15 pt semibold: a name, or a tile's title.
    static let emphasis = Font.subheadline.weight(.semibold)
    /// 15 pt: descriptions, explanations, a row's supporting line.
    static let supporting = Font.subheadline
    /// 15 pt medium: text that acts, such as Show more, a chip, a banner's buttons.
    static let action = Font.subheadline.weight(.medium)
    /// SF Pro, 13 pt, drawn in Ink 2: when, who can see it, where.
    static let metadata = Font.footnote
    /// 12 pt: legends and the label under a number.
    static let legend = Font.caption
    /// 11 pt: the smallest text, for labels around a chart.
    static let fine = Font.caption2
    /// 22 pt semibold: a number that is the point of the row, like a streak.
    static let stat = Font.title2.weight(.semibold)
    /// SF Mono, 12 pt: a saved view's filter under its name.
    static let fineCode = Font.system(.caption, design: .monospaced)
}

/// Symbol sizes for icons that stand alone, so a toolbar, a floating bar and a row agree.
extension Font {
    /// A symbol in a floating glass button or the composer's bar.
    static let barSymbol = Font.title3
    /// A symbol in an icon tile or beside a row's text.
    static let rowSymbol = Font.subheadline.weight(.medium)
    /// A small status symbol beside metadata: pinned, revealed.
    static let statusSymbol = Font.caption
}
