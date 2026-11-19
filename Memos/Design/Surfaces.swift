import SwiftUI

// The opaque surfaces. Paper is the screen, Card is what you wrote, Well is a recess inside a
// card. Glass is only for controls, and never sits on glass.

/// The opaque surface every memo is drawn on: paper for what you wrote, glass only for what you do.
struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content
            .background(.card, in: .rect(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(increased ? .ink2 : .hairline, lineWidth: increased ? Stroke.emphasized : Stroke.hairline)
            }
    }
}

/// A recessed box inside a card or a sheet: a file, a voice memo, a notice.
struct WellBackground: ViewModifier {
    var padding: CGFloat = Spacing.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.well, in: .rect(cornerRadius: Radius.inner))
    }
}

extension View {
    /// Draws the view on a card. Add the padding first: `.padding(Metrics.cardPadding).cardBackground()`.
    func cardBackground() -> some View { modifier(CardBackground()) }

    /// Pads the view and sets it in a well.
    func wellBackground(padding: CGFloat = Spacing.l) -> some View { modifier(WellBackground(padding: padding)) }

    /// Paper behind a `List` or `Form` instead of the system's grouped gray. Pair with
    /// ``cardRows()`` on its sections so the rows match the cards elsewhere.
    func paperBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(.paper)
    }

    /// Rows of a grouped `List` or `Form` drawn on Card, like every other card in the app.
    func cardRows() -> some View { listRowBackground(Color.card) }

    /// Caps a column at a readable width and centres it, for an unfolded iPhone or an iPad.
    /// Does nothing on a phone held normally.
    func readableWidth() -> some View {
        frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Rows on one card, separated by hairlines: saved views, months. Each child view is a row.
struct CardList<Content: View>: View {
    /// Where the hairlines start. Rows that lead with an icon start them under the text, as the
    /// system lists do: ``Metrics/iconRowTextInset``.
    var dividerInset: CGFloat = 0
    @ViewBuilder var content: Content

    /// The inset follows the icon column, which grows with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var scale = SymbolScale.base

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        CardDivider()
                            .padding(.leading, Metrics.scaled(dividerInset, by: scale))
                    }
                    row
                }
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .cardBackground()
    }
}

/// The hairline between rows on a card.
struct CardDivider: View {
    var body: some View {
        // One device pixel, in Hairline rather than the system separator's cooler gray.
        Divider()
            .overlay(.hairline)
            .accessibilityHidden(true)
    }
}
