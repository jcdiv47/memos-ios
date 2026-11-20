import MemosCore
import SwiftUI

/// A memo on the timeline: opaque paper, never glass.
struct MemoCard: View {
    let memo: Memo
    var highlights: [String] = []
    /// Shows the memo's Space in the metadata row, when the timeline spans every Space.
    var showsSpace = true
    /// Shows who wrote it. Your own timeline leaves it out: every memo there is yours.
    var showsAuthor = true

    @Environment(AccountSession.self) private var session

    private var isMine: Bool { memo.creator == session.user }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockGap) {
            MemoHeader(memo: memo, showsSpace: showsSpace, showsAuthor: showsAuthor)

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
                            .labelStyle(.compact)
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
                .labelStyle(.compact)
                .font(.metadata)
                .foregroundStyle(.ink2)
        } else if let failed = session.store.failedChange(for: memo.name) {
            Label("Couldn’t upload: \(failed.failure ?? "")", systemImage: "exclamationmark.triangle")
                .labelStyle(.compact)
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
        // Every memo in the on-device library is yours; naming the author says nothing.
        let showsAuthor = showsAuthor && !session.isOnDevice
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
                    .foregroundStyle(.memosBlue)
                    .accessibilityLabel("Pinned")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
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
        } else if !session.isOnDevice {
            Image(systemName: memo.visibility.systemImage)
                .accessibilityLabel(memo.visibility.label)
        }
        if let spaceTitle {
            Text(verbatim: "· \(spaceTitle)")
        }
    }
}

extension AccountSession {
    /// A memo's title, or “Sensitive content” while a tag rule hides it, for places too small
    /// to blur.
    func redactedTitle(of memo: Memo) -> String {
        isHidden(memo) ? String(localized: "Sensitive content") : memo.displayTitle
    }

    /// Whether one of your tag rules blurs the memo and you haven't shown it.
    func isHidden(_ memo: Memo) -> Bool {
        store.profile.tagBlurRules.blurs(memo) && !revealedMemos.contains(memo.name)
    }
}

/// A memo's body, blurred when one of its tags is set to blur in your tag settings on the web,
/// such as `#nsfw`, until ``RevealToggle`` shows it.
struct SensitiveContent<Content: View>: View {
    let memo: Memo
    @ViewBuilder var content: Content

    @Environment(AccountSession.self) private var session

    var body: some View {
        let blurs = session.store.profile.tagBlurRules.blurs(memo)
        let hidden = session.isHidden(memo)
        let body = content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .blur(radius: hidden ? 16 : 0)
            .allowsHitTesting(!hidden)
        Group {
            if blurs {
                // While hidden, one element stands in for the whole body: `accessibilityHidden`,
                // and an element ignoring its children, both left the text, tasks and tags
                // readable. Revealed, VoiceOver reads a copy of the body. The drawn body stays
                // one view either way, so the blur itself animates rather than cross-fading.
                body.accessibilityRepresentation {
                    if hidden {
                        Text("Sensitive content")
                    } else {
                        content
                    }
                }
            } else {
                body
            }
        }
        .overlay {
            if hidden {
                // Says why the text is blurred, and the whole blurred area shows it: a bigger
                // target than the eye. A tap rather than a button, which a timeline card would
                // still list for VoiceOver beside the eye it duplicates.
                Pill {
                    Label("Sensitive", systemImage: "eye.slash")
                        .labelStyle(.compact)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.memosSpring) { _ = session.revealedMemos.insert(memo.name) }
                    }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.s) {
            ForEach(memo.reactionCounts, id: \.emoji) { reaction in
                let chip = ReactionChip(emoji: reaction.emoji, count: reaction.count, mine: reaction.creators.contains(session.user))
                // On the timeline the chips only report; a disabled button would dim the emoji.
                Group {
                    if let onTap {
                        Button { onTap(reaction.emoji) } label: { chip }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: "\(reaction.emoji) \(reaction.count)"))
                    } else {
                        chip
                    }
                }
                // A new emoji pops in beside the others rather than fading up from nothing; one
                // taken back leaves quietly. Bounce only on arrival.
                .transition(.asymmetric(
                    insertion: reduceMotion
                        ? AnyTransition.opacity.animation(.memosFade)
                        : AnyTransition.scale(scale: 0.6).combined(with: .opacity).animation(.reactionPop),
                    removal: AnyTransition.opacity.animation(.memosFade)
                ))
            }
        }
        // Reactions land from a refresh after the request, outside any animation of their own.
        .animation(reduceMotion ? .memosFade : .reactionPop, value: memo.reactions.count)
    }
}

/// One emoji and its count, tinted when you're among the reactors.
private struct ReactionChip: View {
    let emoji: String
    let count: Int
    let mine: Bool

    var body: some View {
        Pill(isSelected: mine) {
            Text(emoji)
            Text(count, format: .number)
                .contentTransition(.numericText(value: Double(count)))
        }
        .contentShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(emoji) \(count)"))
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
