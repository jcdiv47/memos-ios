import MemosCore
import SwiftUI

/// Renders a memo's Markdown natively: headings, paragraphs, task and bullet lists, quotes,
/// code, math and tables. Math is typeset by SwiftMath; TeX it can't set is shown as written,
/// set like code. Tags are Memos Blue text without a capsule, so they don't compete with the
/// glass controls; with Increase Contrast they're underlined too.
struct MemoContentView: View {
    let content: String
    /// Lets the reader check off tasks. Only for your own memos.
    var onToggleTask: ((Int) -> Void)?
    /// Words to highlight, from search.
    var highlights: [String] = []
    /// Shows the opening heading as the memo's title, in New York.
    var showsTitle = true
    /// The title's font: `.memoTitle` on a card, `.largeTitleSerif` on the memo's own page.
    var titleFont: Font = .memoTitle
    /// Builds blocks only as they scroll into view. For the memo's own page, inside its scroll
    /// view: laying out every highlighted code block and formula of a long memo up front held
    /// the push for a fifth of a second. A card is clipped to a few hundred points and measured
    /// whole, so it stays eager.
    var lazy = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let blocks = Array(MarkdownCache.document(content).blocks.enumerated())
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: Metrics.blockGap) {
                    ForEach(blocks, id: \.offset) { index, block in
                        blockView(block, isFirst: index == 0)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Metrics.blockGap) {
                    ForEach(blocks, id: \.offset) { index, block in
                        blockView(block, isFirst: index == 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, style: isFirst && showsTitle ? .title3 : headingStyle(level))
                .font(isFirst && showsTitle ? titleFont : headingFont(level))
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            inline(text)
                .font(.memoBody)
                .foregroundStyle(.ink)

        case .list(let items):
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(items, id: \.line) { item in
                    listItem(item)
                        .padding(.leading, CGFloat(item.depth) * 18)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: Spacing.l) {
                // Hairline is only for card edges and dividers, and nearly vanishes on paper.
                Capsule()
                    .fill(Color.ink3.opacity(0.45))
                    .frame(width: 3)
                inline(text)
                    .font(.memoBody)
                    .italic()
                    .foregroundStyle(.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(MarkdownCache.code(code, language: language, appearance: CodePalette.Appearance(colorScheme, contrast)))
                    .font(.memoCode)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .padding(Spacing.l)
            }
            .background(.paper2, in: .rect(cornerRadius: Radius.inner))

        case .math(let tex):
            if let math = MarkdownCache.math(tex, fontSize: pointSize(.body), display: true) {
                // Centred like the web's display math, and scrolled sideways when it's too wide.
                ViewThatFits(in: .horizontal) {
                    math.view.frame(maxWidth: .infinity)
                    ScrollView(.horizontal, showsIndicators: false) { math.view }
                }
                .foregroundStyle(.ink)
                .padding(.vertical, Spacing.s)
            } else {
                mathSource(tex)
            }

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.s) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inline(cell, style: .subheadline).font(.emphasis)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell, style: .subheadline).font(.supporting)
                            }
                        }
                    }
                }
                .foregroundStyle(.ink)
            }

        case .rule:
            CardDivider()
        }
    }

    @ViewBuilder
    private func listItem(_ item: ListItem) -> some View {
        switch item.marker {
        case .task(let checked):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                let box = Image(icon: checked ? .squareCheckFill : .square)
                    .foregroundStyle(checked ? Color.memosBlue : Color.ink2)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                Group {
                    if let onToggleTask {
                        Button {
                            // The symbol replace and the strikethrough only play inside an animation.
                            withAnimation(.memosSpring) { onToggleTask(item.line) }
                        } label: {
                            box
                        }
                        .buttonStyle(.glyphPress)
                    } else {
                        // Someone else's list reads at full strength; a disabled button would dim it.
                        box
                    }
                }
                .sensoryFeedback(.selection, trigger: checked)
                .accessibilityLabel(checked ? Text("Completed") : Text("Not completed"))

                // Tags keep their Memos Blue in a done task; only the words around them dim.
                if let strike = strikeOnly(item.text) {
                    inline(item.text)
                        .font(.memoBody)
                        .foregroundStyle(checked ? Color.ink2 : Color.ink)
                        .modifier(TaskStrike(checked: checked, strike: strike.font(.memoBody)))
                } else {
                    inline(item.text)
                        .font(.memoBody)
                        .strikethrough(checked, color: .ink2)
                        .foregroundStyle(checked ? Color.ink2 : Color.ink)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(onToggleTask == nil ? [] : .isButton)
            .accessibilityAction { withAnimation(.memosSpring) { onToggleTask?(item.line) } }

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(verbatim: "•").foregroundStyle(.ink2)
                inline(item.text).font(.memoBody).foregroundStyle(.ink)
            }
        case .number(let number):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(verbatim: "\(number).").foregroundStyle(.ink2).monospacedDigit()
                inline(item.text).font(.memoBody).foregroundStyle(.ink)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    /// TeX SwiftMath couldn't set, as written.
    private func mathSource(_ tex: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: tex)
                .font(.memoCode)
                .foregroundStyle(.ink)
                .textSelection(.enabled)
                .padding(Spacing.l)
        }
        .background(.paper2, in: .rect(cornerRadius: Radius.inner))
    }

    private func headingStyle(_ level: Int) -> UIFont.TextStyle {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }

    /// The text style's size at the current Dynamic Type setting, for typesetting math to match.
    private func pointSize(_ style: UIFont.TextStyle) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
    }

    /// Only the strike through a task's text, laid out exactly like the text so it can be drawn
    /// over it: every glyph clear, the line in Ink 2. Nil when the text has inline math, whose
    /// typeset pieces can't be copied without their glyphs; that text keeps a plain strikethrough.
    private func strikeOnly(_ text: String) -> Text? {
        var attributed = MarkdownCache.inline(text, highlights: highlights, underlineTags: contrast == .increased)
        guard !attributed.runs[InlineMathAttribute.self].contains(where: { $0.0 != nil }) else { return nil }
        attributed.foregroundColor = .clear
        attributed.backgroundColor = nil
        attributed.link = nil
        attributed.underlineStyle = nil
        attributed.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .ink2)
        return Text(attributed)
    }

    /// A block's inline Markdown, with each `$math$` run typeset in place. `style` is the text
    /// style of the font the block is set in, so formulas match its size.
    private func inline(_ text: String, style: UIFont.TextStyle = .body) -> Text {
        let attributed = MarkdownCache.inline(text, highlights: highlights, underlineTags: contrast == .increased)
        let runs = attributed.runs[InlineMathAttribute.self, AttributeScopes.FoundationAttributes.LinkAttribute.self]
        guard runs.contains(where: { $0.0 != nil && $0.1 == nil }) else { return Text(attributed) }
        let size = pointSize(style)
        // One Text from all the pieces. Built at run time, the key is never looked up in or added
        // to the string catalog, and the memo's text stays in its own pieces, never in the format.
        var pieces = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: runs.count)
        for (tex, link, range) in runs {
            if let tex, link == nil, let math = MarkdownCache.math(tex, fontSize: size, display: false) {
                pieces.appendInterpolation(math.inlineText)
            } else {
                pieces.appendInterpolation(Text(AttributedString(attributed[range])))
            }
        }
        return Text(LocalizedStringKey(stringInterpolation: pieces))
    }
}

enum InlineMarkdown {
    /// Inline Markdown with tags as `memos://tag/…` links in Memos Blue, and search matches
    /// highlighted.
    static func render(_ text: String, highlights: [String] = [], underlineTags: Bool = false) -> AttributedString {
        var attributed = InlineParsing.attributed(text)

        let plain = String(attributed.characters)
        for match in TagScanner.matches(in: plain) {
            guard let range = attributedRange(match.range, in: plain, of: attributed) else { continue }
            if attributed[range].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true || $0.link != nil }) {
                continue
            }
            attributed[range].foregroundColor = .memosBlue
            attributed[range].link = URL(string: "memos://tag/\(match.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? match.tag)")
            attributed[range].underlineStyle = underlineTags ? .single : nil
        }

        for word in highlights where !word.isEmpty {
            var searchStart = plain.startIndex
            while let found = plain.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<plain.endIndex) {
                if let range = attributedRange(found, in: plain, of: attributed) {
                    attributed[range].backgroundColor = Color.searchHighlight
                    attributed[range].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = found.upperBound
            }
        }
        return attributed
    }

    private static func attributedRange(_ range: Range<String.Index>, in plain: String, of attributed: AttributedString) -> Range<AttributedString.Index>? {
        let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let length = plain.distance(from: range.lowerBound, to: range.upperBound)
        let characters = attributed.characters
        guard lower + length <= characters.count else { return nil }
        let start = characters.index(characters.startIndex, offsetBy: lower)
        let end = characters.index(start, offsetBy: length)
        return start..<end
    }
}

/// Draws a done task's strike from the leading edge, as if crossed out with a pen, a beat after
/// the box fills. Unchecking fades it rather than drawing it back. Reduce Motion fades both ways.
/// `.strikethrough` can't animate, so the strike is a clear copy of the text laid over it.
private struct TaskStrike: ViewModifier {
    let checked: Bool
    let strike: Text

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat
    @State private var visible: Double

    init(checked: Bool, strike: Text) {
        self.checked = checked
        self.strike = strike
        _reveal = State(initialValue: checked ? 1 : 0)
        _visible = State(initialValue: checked ? 1 : 0)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                strike
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: reveal, anchor: .leading)
                    }
                    .opacity(visible)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .onChange(of: checked) { _, isChecked in
                var instant = Transaction()
                instant.disablesAnimations = true
                if isChecked {
                    withTransaction(instant) {
                        reveal = reduceMotion ? 1 : 0
                        visible = reduceMotion ? 0 : 1
                    }
                    // A beat after the box, so the eye goes from the box to the words.
                    withAnimation(.memosFade.delay(0.06)) {
                        if reduceMotion { visible = 1 } else { reveal = 1 }
                    }
                } else {
                    withTransaction(instant) { reveal = 1 }
                    withAnimation(.memosFade) { visible = 0 }
                }
            }
    }
}
