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
        VStack(alignment: .leading, spacing: 10) {
            MemoHeader(memo: memo, showsSpace: showsSpace, showsAuthor: showsAuthor)

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
                            .labelStyle(.compact)
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
            RevealToggle(memo: memo)
            if memo.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
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

extension AccountSession {
    /// A memo's title, or “Sensitive content” while a tag rule hides it, for places too small
    /// to blur.
    func redactedTitle(of memo: Memo) -> String {
        store.profile.tagBlurRules.blurs(memo) && !revealedMemos.contains(memo.name)
            ? String(localized: "Sensitive content")
            : memo.displayTitle
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
        let hidden = blurs && !session.revealedMemos.contains(memo.name)
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
                Label("Sensitive", systemImage: "eye.slash")
                    .labelStyle(.compact)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.well, in: .capsule)
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
                    .font(.caption)
                    .foregroundStyle(.ink2)
                    // A pin-sized symbol, with a finger-sized target.
                    .frame(minWidth: 28, minHeight: 28)
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
        HStack(spacing: 6) {
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
                // A new emoji pops in beside the others rather than fading up from nothing.
                .transition(.scale(scale: 0.6).combined(with: .opacity))
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
        HStack(spacing: 4) {
            Text(emoji)
            Text(count, format: .number)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(mine ? Color.memosBlue : Color.ink2)
                .contentTransition(.numericText(value: Double(count)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(mine ? Color.memosBlue.opacity(0.12) : Color.well, in: .capsule)
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
