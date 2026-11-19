import SwiftUI

// Small pieces that several screens draw the same way. Reach for one of these before styling a
// view by hand.

// MARK: Chips and pills

/// A small opaque chip, used for visibility and Space inside glass surfaces: no glass on glass.
struct ChipStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.action)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .foregroundStyle(prominent ? Color.memosBlue : Color.ink)
            .background(prominent ? Color.accentWash : Color.well, in: .capsule)
            .opacity(configuration.isPressed ? Press.opacity : 1)
            .scaleEffect(configuration.isPressed ? Press.scale : 1)
            .animation(.memosPress, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ChipStyle {
    static var chip: ChipStyle { ChipStyle() }
    static var prominentChip: ChipStyle { ChipStyle(prominent: true) }
}

/// A compact count in a capsule, like a reaction under a memo. Selected pills are tinted.
struct Pill<Label: View>: View {
    var isSelected = false
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: Spacing.xs) { label }
            .font(.metadata.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(isSelected ? Color.memosBlue : Color.ink2)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(isSelected ? Color.accentWash : Color.well, in: .capsule)
    }
}

// MARK: Headings and rows

/// The heading over a group of cards: “Saved views”, a year. Lines up with the text inside the
/// cards below it, and can carry a trailing detail such as a count.
struct SectionHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.m)
            trailing
                .fontWeight(.regular)
                .monospacedDigit()
        }
        .font(.sectionTitle)
        .foregroundStyle(.ink2)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.top, Spacing.m)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title: Text(title)) { EmptyView() }
    }
}

extension SectionHeader {
    init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: Text(title), trailing: trailing)
    }

    init(verbatim title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: Text(verbatim: title), trailing: trailing)
    }
}

/// A symbol on a tinted square, leading a tile or a row. Dims to Ink 3 on a well when there's
/// nothing behind it yet.
struct IconTile: View {
    let systemImage: String
    var isEmpty = false

    @ScaledMetric(relativeTo: .subheadline) private var scale = SymbolScale.base

    var body: some View {
        let side = Metrics.scaled(Metrics.iconTile, by: scale)
        Image(systemName: systemImage)
            .font(.rowSymbol)
            .foregroundStyle(isEmpty ? Color.ink3 : Color.memosBlue)
            .frame(width: side, height: side)
            .background(isEmpty ? Color.well : Color.accentWash, in: .rect(cornerRadius: Radius.inner))
            .accessibilityHidden(true)
    }
}

/// The trailing chevron on rows that open a page.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.metadata.weight(.semibold))
            .foregroundStyle(.ink3)
            .accessibilityHidden(true)
    }
}

/// Something unread. Rarely urgent in a notes app, so a dot rather than a count.
struct UnreadDot: View {
    /// Rings the dot in Paper so it separates from a symbol or avatar it overlaps.
    var ringed = false

    var body: some View {
        Circle()
            .fill(.memosBlue)
            .stroke(.paper, lineWidth: ringed ? 2 : 0)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

// MARK: Buttons

/// The label of a full-width prominent button, such as Continue at sign-in: centred, semibold,
/// and a spinner in its place while the action runs so the button keeps its size.
struct WideButtonLabel: View {
    let title: LocalizedStringKey
    var isWorking = false

    var body: some View {
        ZStack {
            Text(title)
                .fontWeight(.semibold)
                .opacity(isWorking ? 0 : 1)
            if isWorking {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget - Spacing.m)
    }
}

// MARK: Conditional modifiers

extension View {
    /// Pull to refresh where there's something to refresh from. Off in the on-device library, so
    /// the gesture doesn't promise a sync that never happens.
    @ViewBuilder
    func refreshable(if enabled: Bool, action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        if enabled {
            refreshable { await action() }
        } else {
            self
        }
    }

    /// A title menu where there's something to put in it.
    @ViewBuilder
    func toolbarTitleMenu<Content: View>(if enabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        if enabled {
            toolbarTitleMenu(content: content)
        } else {
            self
        }
    }
}

// MARK: People

/// A letter avatar. `size` is the diameter at the default text size; pass the result of
/// ``Metrics/scaled(_:by:)`` if it should grow with Dynamic Type, as ``UserAvatar`` does.
struct Avatar: View {
    let name: String
    var size: CGFloat = AvatarSize.small

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.ink)
            .frame(width: size, height: size)
            .background(.well, in: .circle)
            .accessibilityHidden(true)
    }
}

// MARK: Messages

/// A short message that floats in at the top of a screen and goes away on its own, such as
/// “Connect to react.” A control-layer surface, so glass.
struct Toast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.supporting)
            .foregroundStyle(.ink)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.m)
            .glassEffect(in: .capsule)
    }
}

/// An icon tight against its text, on the text's baseline, for metadata inside cards. A List
/// row's default label reserves an icon column, which leaves a gap that reads as a bug.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}
