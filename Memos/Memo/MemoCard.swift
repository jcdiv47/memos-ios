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

            notice

            SensitiveContent(memo: memo) {
                VStack(alignment: .leading, spacing: 10) {
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
                }
            }

            if !memo.reactions.isEmpty {
                ReactionSummary(memo: memo)
            }
        }
        .padding(Metrics.cardPadding)
        .cardBackground()
    }

    @ViewBuilder
    private var notice: some View {
        if session.store.conflictCounterpart(of: memo.name) != nil {
            Label("Edited on another device. Your version was saved separately.", systemImage: "arrow.triangle.branch")
                .font(.metadata)
                .foregroundStyle(.ink2)
        } else if let failed = session.store.failedChange(for: memo.name) {
            Label("Couldn’t upload: \(failed.failure ?? "")", systemImage: "exclamationmark.triangle")
                .font(.metadata)
                .foregroundStyle(.danger)
        }
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
                UserAvatar(user: memo.creator, size: 28)
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
            Text(verbatim: "· \(spaceTitle)")
        }
    }
}

/// A memo's body, blurred when one of its tags is set to blur in your tag settings on the web,
/// such as `#nsfw`. One tap shows it until the view goes away, as on the web.
struct SensitiveContent<Content: View>: View {
    let memo: Memo
    @ViewBuilder var content: Content

    @Environment(AccountSession.self) private var session
    @State private var revealed = false

    var body: some View {
        let sensitive = session.store.profile.tagBlurRules.blurs(memo)
        let hidden = sensitive && !revealed
        VStack(alignment: .leading, spacing: 10) {
            content
                // Centers the button across the card, with room for it under a one-line memo.
                .frame(maxWidth: .infinity, minHeight: hidden ? 44 : nil, alignment: .topLeading)
                .blur(radius: hidden ? 16 : 0)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
                .overlay {
                    if hidden {
                        Button("Show sensitive content", systemImage: "eye") {
                            withAnimation(.memosSpring) { revealed = true }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.glass)
                        .tint(.ink)
                    }
                }

            // The web has no way back; here one tap blurs it again.
            if sensitive && revealed {
                Button {
                    withAnimation(.memosSpring) { revealed = false }
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .font(.metadata)
                .foregroundStyle(.ink2)
                .accessibilityLabel("Hide sensitive content")
            }
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
                        Text(reaction.count, format: .number)
                            .font(.footnote.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(mine ? Color.memosBlue : Color.ink2)
                            .contentTransition(.numericText(value: Double(reaction.count)))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(mine ? Color.memosBlue.opacity(0.12) : Color.well, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .accessibilityLabel(Text(verbatim: "\(reaction.emoji) \(reaction.count)"))
            }
        }
        // Reactions land from a refresh after the request, outside any animation of their own.
        .animation(.memosSpring, value: memo.reactions.count)
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
                // Fades into the opaque card rather than masking, which would render every card
                // offscreen while the timeline scrolls.
                .overlay {
                    if isCollapsed {
                        LinearGradient(
                            stops: [.init(color: .card.opacity(0), location: 0.8), .init(color: .card, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    }
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
