import MemosCore
import SwiftUI

/// Renders a memo's Markdown natively: headings, paragraphs, task and bullet lists, quotes,
/// code, math and tables. Math is shown as its TeX source, set like code, until it's typeset. Tags are Memos Blue text without a capsule, so they don't compete with the
/// glass controls; with Increase Contrast they're underlined too.
struct MemoContentView: View {
    let content: String
    /// Lets the reader check off tasks. Only for your own memos.
    var onToggleTask: ((Int) -> Void)?
    /// Words to highlight, from search.
    var highlights: [String] = []
    /// Shows the opening heading as the memo's title, in New York.
    var showsTitle = true

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let document = MarkdownCache.document(content)
        VStack(alignment: .leading, spacing: Metrics.blockGap) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(isFirst && showsTitle ? .memoTitle : headingFont(level))
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            Text(inline(text))
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
                Capsule()
                    .fill(.hairline)
                    .frame(width: 3)
                Text(inline(text))
                    .font(.memoBody)
                    .italic()
                    .foregroundStyle(.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(MarkdownCache.code(code, language: language))
                    .font(.memoCode)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .padding(Spacing.l)
            }
            .background(.paper2, in: .rect(cornerRadius: Radius.inner))

        case .math(let tex):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: tex)
                    .font(.memoCode)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .padding(Spacing.l)
            }
            .background(.paper2, in: .rect(cornerRadius: Radius.inner))

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.s) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).font(.emphasis)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).font(.supporting)
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
                Button {
                    // The symbol replace and the strikethrough only play inside an animation.
                    withAnimation(.memosSpring) { onToggleTask?(item.line) }
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.memosBlue : Color.ink2)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(onToggleTask == nil)
                .sensoryFeedback(.selection, trigger: checked)
                .accessibilityLabel(checked ? Text("Completed") : Text("Not completed"))

                Text(inline(item.text))
                    .font(.memoBody)
                    .strikethrough(checked, color: .ink2)
                    .foregroundStyle(checked ? Color.ink2 : Color.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(onToggleTask == nil ? [] : .isButton)
            .accessibilityAction { withAnimation(.memosSpring) { onToggleTask?(item.line) } }

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(verbatim: "•").foregroundStyle(.ink2)
                Text(inline(item.text)).font(.memoBody).foregroundStyle(.ink)
            }
        case .number(let number):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(verbatim: "\(number).").foregroundStyle(.ink2).monospacedDigit()
                Text(inline(item.text)).font(.memoBody).foregroundStyle(.ink)
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

    private func inline(_ text: String) -> AttributedString {
        MarkdownCache.inline(text, highlights: highlights, underlineTags: contrast == .increased)
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
