import MemosCore
import SwiftUI

/// Which way a link between memos runs, from the memo on screen.
enum LinkDirection {
    /// This memo links to the other one.
    case referencing
    /// The other memo links to this one.
    case referencedBy

    var systemImage: String {
        switch self {
        case .referencing: "link"
        case .referencedBy: "signpost.right"
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .referencing: LocalizedStringResource("Referencing", comment: "A memo this memo links to.")
        case .referencedBy: LocalizedStringResource("Referenced by", comment: "A memo that links to this memo.")
        }
    }
}

/// The memos a memo links to, then the ones linking to it, as rows like the web's. Tapping one
/// opens it.
struct MemoLinks: View {
    let memo: Memo
    /// Says which way each row runs in words, not just with its symbol. For the detail, which
    /// has the room.
    var showsDirection = false

    @Environment(AccountSession.self) private var session

    var body: some View {
        // Two memos can link each other, so a name can appear in both directions.
        let rows = memo.references.map { (id: "out-\($0)", name: $0, direction: LinkDirection.referencing) }
            + memo.referencedBy.map { (id: "in-\($0)", name: $0, direction: LinkDirection.referencedBy) }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(rows, id: \.id) { _, name, direction in
                    Button {
                        session.show(memo: name)
                    } label: {
                        LinkedMemoRow(
                            snippet: session.linkSnippet(name, from: memo),
                            direction: direction,
                            showsDirection: showsDirection
                        )
                    }
                    .buttonStyle(.cardPress)
                }
            }
        }
    }
}

/// One linked memo: the direction's symbol and the start of the memo.
struct LinkedMemoRow<Trailing: View>: View {
    let snippet: String?
    let direction: LinkDirection
    var showsDirection = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.m) {
            content
            trailing
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(.well, in: .rect(cornerRadius: Radius.inner))
        .contentShape(.rect)
    }

    /// Read as one element; a trailing button stays its own.
    private var content: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: direction.systemImage)
                .font(.rowSymbol)
                .foregroundStyle(.ink2)
                .accessibilityHidden(true)
            Group {
                if let snippet {
                    Text(verbatim: snippet).foregroundStyle(.ink)
                } else {
                    // Not on this device, and the server sent no snippet with the link.
                    Text("Linked memo").italic().foregroundStyle(.ink2)
                }
            }
            .font(.supporting)
            .lineLimit(1)
            Spacer(minLength: Spacing.m)
            if showsDirection {
                Text(direction.label)
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(Text(direction.label)): \(snippet ?? String(localized: "Linked memo"))"))
    }
}

extension LinkedMemoRow where Trailing == EmptyView {
    init(snippet: String?, direction: LinkDirection, showsDirection: Bool = false) {
        self.init(snippet: snippet, direction: direction, showsDirection: showsDirection) { EmptyView() }
    }
}

extension AccountSession {
    /// The start of a linked memo on one line: from the copy on this device when there is one,
    /// so it reads as the memo does now, otherwise from what the server sent with the link.
    func linkSnippet(_ name: String, from memo: Memo?) -> String? {
        let snippet: String?
        if let linked = store.memo(named: name) {
            // A linked memo blurred by one of your tags reads as it does on its card.
            if isHidden(linked) { return String(localized: "Sensitive content") }
            snippet = linked.snippet.isEmpty ? String(linked.content.prefix(120)) : linked.snippet
        } else {
            snippet = memo?.relationSnippet(for: name)
        }
        let line = snippet?
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}

/// Picks one of your memos to link to, newest first, narrowed by what you type.
struct LinkMemoPicker: View {
    /// The memo being edited, which can't link to itself, and the ones already linked.
    let excluded: Set<String>
    var onPick: (String) -> Void

    @Environment(AccountSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Memo] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return session.memos(MemoQuery(scope: .mine, order: .newest))
            .lazy
            .filter { !excluded.contains($0.name) }
            .filter { memo in words.allSatisfy { memo.content.localizedStandardContains($0) } }
            .prefix(100)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            let results = self.results
            List(results, id: \.name) { memo in
                Button {
                    onPick(memo.name)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(verbatim: session.linkSnippet(memo.name, from: nil) ?? "")
                            .font(.rowTitle)
                            .foregroundStyle(.ink)
                            .lineLimit(2)
                        Text(MemoDate.timeline(memo.createdAt))
                            .font(.metadata)
                            .foregroundStyle(.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .cardRows()
            }
            .paperBackground()
            .overlay {
                if results.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No memos to link", systemImage: "link")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search your memos"))
            .navigationTitle(Text("Link Memo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
        }
    }
}
