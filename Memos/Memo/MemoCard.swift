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
        VStack(alignment: .leading, spacing: Metrics.blockGap) {
            MemoHeader(memo: memo, showsSpace: showsSpace)

            notice

            SensitiveContent(memo: memo) {
                VStack(alignment: .leading, spacing: Metrics.blockGap) {
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

                    MemoLinks(memo: memo)
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
        HStack(alignment: .center, spacing: Spacing.m) {
            if showsAuthor {
                UserAvatar(user: memo.creator, size: AvatarSize.small)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if showsAuthor {
                    Text(name)
                        .font(.emphasis)
                        .foregroundStyle(.ink)
                }
                metadata
            }
            Spacer(minLength: 0)
            RevealToggle(memo: memo)
            if memo.pinned {
                Image(systemName: "pin.fill")
                    .font(.statusSymbol)
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
            HStack(spacing: Spacing.xs) { metadataParts(waiting: waiting, spaceTitle: spaceTitle) }
            VStack(alignment: .leading, spacing: Spacing.xxs) { metadataParts(waiting: waiting, spaceTitle: spaceTitle) }
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
/// such as `#nsfw`, until ``RevealToggle`` shows it.
struct SensitiveContent<Content: View>: View {
    let memo: Memo
    @ViewBuilder var content: Content

    @Environment(AccountSession.self) private var session

    var body: some View {
        let hidden = session.store.profile.tagBlurRules.blurs(memo) && !session.revealedMemos.contains(memo.name)
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .blur(radius: hidden ? 16 : 0)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

/// The eye beside a sensitive memo's pin: shows its blurred body, and blurs it again, which the
/// web has no way to do. Nothing for a memo with no blurred tag.
struct RevealToggle: View {
    let memo: Memo

    @Environment(AccountSession.self) private var session

    var body: some View {
        if session.store.profile.tagBlurRules.blurs(memo) {
            let revealed = session.revealedMemos.contains(memo.name)
            Button {
                withAnimation(.memosSpring) {
                    if revealed { session.revealedMemos.remove(memo.name) } else { session.revealedMemos.insert(memo.name) }
                }
            } label: {
                Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.statusSymbol)
                    .foregroundStyle(.ink2)
                    // A pin-sized symbol, with a finger-sized target.
                    .frame(minWidth: AvatarSize.small, minHeight: AvatarSize.small)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? Text("Hide sensitive content") : Text("Show sensitive content"))
        }
    }
}

/// “❤️ 3 🌅 1”, opaque counts under a memo.
struct ReactionSummary: View {
    let memo: Memo
    var onTap: ((String) -> Void)?

    @Environment(AccountSession.self) private var session

    var body: some View {
        HStack(spacing: Spacing.s) {
            ForEach(memo.reactionCounts, id: \.emoji) { reaction in
                let mine = reaction.creators.contains(session.user)
                Button {
                    onTap?(reaction.emoji)
                } label: {
                    Pill(isSelected: mine) {
                        Text(reaction.emoji)
                        Text(reaction.count, format: .number)
                            .contentTransition(.numericText(value: Double(reaction.count)))
                    }
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
        VStack(alignment: .leading, spacing: Spacing.s) {
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
                    .font(.action)
                    .foregroundStyle(.memosBlue)
                    .accessibilityHidden(true)
            }
        }
    }
}
