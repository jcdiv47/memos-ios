import MemosCore
import SwiftUI

/// A memo on the timeline: opaque paper, never glass.
struct MemoCard: View {
    let memo: Memo
    var highlights: [String] = []
    /// Shows the memo's Space in the metadata row, when the timeline spans every Space.
    var showsSpace = true

    @Environment(AccountSession.self) private var session

    private var isMine: Bool { memo.creator == session.user }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoHeader(memo: memo, showsSpace: showsSpace)

            if let notice = notice {
                notice
            }

            if let audio = memo.audioAttachment {
                AudioAttachmentView(attachment: audio)
            }

            CollapsedContent {
                MemoContentView(
                    content: memo.content,
                    onToggleTask: isMine ? { line in session.store.toggleTask(memo.name, line: line) } : nil,
                    highlights: highlights
                )
            }

            if memo.attachments.contains(where: { !$0.isAudio }) {
                AttachmentGallery(attachments: memo.attachments.filter { !$0.isAudio }, maxImages: 6)
            }

            if let location = memo.locationIfSet, !location.placeholder.isEmpty {
                Label(location.placeholder, systemImage: "mappin.and.ellipse")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                    // The symbol’s own name is “Remove Map Pin”.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Location, \(location.placeholder)")
            }

            if !memo.reactions.isEmpty {
                ReactionSummary(memo: memo)
            }
        }
        .padding(Metrics.cardPadding)
        .cardBackground()
    }

    private var notice: AnyView? {
        if session.store.conflictCounterpart(of: memo.name) != nil {
            return AnyView(
                Label("Edited on another device. Your version was saved separately.", systemImage: "arrow.triangle.branch")
                    .font(.metadata)
                    .foregroundStyle(.ink2)
            )
        }
        if let failed = session.store.failedChange(for: memo.name) {
            return AnyView(
                Label("Couldn’t upload: \(failed.failure ?? "")", systemImage: "exclamationmark.triangle")
                    .font(.metadata)
                    .foregroundStyle(.danger)
            )
        }
        return nil
    }
}

/// Author, time, and the memo's audience: “Yesterday, 6:40 PM · Protected · Studio”.
struct MemoHeader: View {
    let memo: Memo
    var showsSpace = true
    var showsAuthor = true

    @Environment(AccountSession.self) private var session

    var body: some View {
        let name = session.people.name(for: memo.creator)
        HStack(alignment: .center, spacing: 8) {
            if showsAuthor {
                Avatar(name: name, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                if showsAuthor {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink)
                }
                metadata
            }
            Spacer(minLength: 0)
            if memo.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.ink2)
                    .accessibilityLabel("Pinned")
            }
        }
    }

    private var metadata: some View {
        let waiting = session.store.isWaitingToSync(memo.name)
        let spaceTitle = showsSpace ? session.space(named: memo.spaceName)?.title : nil
        // Wraps under the content at large text sizes instead of truncating.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { metadataParts(waiting: waiting, spaceTitle: spaceTitle) }
            VStack(alignment: .leading, spacing: 2) { metadataParts(waiting: waiting, spaceTitle: spaceTitle) }
        }
        .font(.metadata)
        .foregroundStyle(.ink2)
    }

    @ViewBuilder
    private func metadataParts(waiting: Bool, spaceTitle: String?) -> some View {
        Text(MemoDate.timeline(memo.createdAt))
        if waiting {
            Image(systemName: "clock")
                .accessibilityLabel("Waiting to sync")
        } else {
            Image(systemName: memo.visibility.systemImage)
                .accessibilityLabel(memo.visibility.label)
        }
        if let spaceTitle {
            Text("· \(spaceTitle)")
        }
    }
}

/// “❤️ 3 🌅 1”, opaque counts under a memo.
struct ReactionSummary: View {
    let memo: Memo
    var onTap: ((String) -> Void)?

    @Environment(AccountSession.self) private var session

    var body: some View {
        HStack(spacing: 6) {
            ForEach(memo.reactionCounts, id: \.emoji) { reaction in
                let mine = reaction.creators.contains(session.user)
                Button {
                    onTap?(reaction.emoji)
                } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.count)")
                            .font(.footnote.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(mine ? Color.memosBlue : Color.ink2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(mine ? Color.memosBlue.opacity(0.12) : Color.paper2, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .accessibilityLabel("\(reaction.emoji) \(reaction.count)")
            }
        }
    }
}

/// Keeps a long memo from filling the timeline: past a screenful of text the card fades out
/// and says there's more. The whole memo is a tap away, in its detail.
private struct CollapsedContent<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fullHeight: CGFloat = 0

    /// Grows with the text size, so the cut stays around the same number of lines.
    private var limit: CGFloat { dynamicTypeSize.isAccessibilitySize ? 900 : 420 }
    private var isCollapsed: Bool { fullHeight > limit + 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(maxHeight: isCollapsed ? limit : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.8), .init(color: isCollapsed ? .clear : .black, location: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            if isCollapsed {
                Text("Show more")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.memosBlue)
                    .accessibilityHidden(true)
            }
        }
    }
}
