import AVFoundation
import MemosCore
import QuickLook
import SwiftUI

/// Photos and files attached to a memo. Drawn opaque, like the memo they belong to.
struct AttachmentGallery: View {
    let attachments: [Attachment]
    var maxImages = 6

    @Environment(AccountSession.self) private var session
    @State private var previewURL: URL?
    /// Everything Quick Look can page through, so a swipe moves to the next attachment.
    @State private var previewItems: [URL] = []

    private var images: [Attachment] { attachments.filter(\.isImage) }
    private var others: [Attachment] { attachments.filter { !$0.isImage && !$0.isAudio } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if !images.isEmpty {
                imageGrid
            }
            ForEach(others, id: \.name) { attachment in
                Button {
                    open(attachment)
                } label: {
                    FileRow(attachment: attachment)
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($previewURL, in: previewItems)
    }

    /// Opens the tapped attachment with the memo's other photos and files beside it, in
    /// order, so a swipe moves between them. Files already on disk open at once.
    private func open(_ attachment: Attachment) {
        Task {
            guard let url = try? await session.files.file(attachment) else { return }
            var items: [URL] = []
            for other in images + others {
                if other.name == attachment.name {
                    items.append(url)
                } else if let file = try? await session.files.file(other) {
                    items.append(file)
                }
            }
            previewItems = items
            previewURL = url
        }
    }

    @ViewBuilder
    private var imageGrid: some View {
        let shown = Array(images.prefix(maxImages))
        if shown.count == 1, let only = shown.first {
            AttachmentImage(attachment: only)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: Radius.inner))
                .onTapGesture { open(only) }
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: shown.count == 2 || shown.count == 4 ? 2 : 3)
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                ForEach(shown, id: \.name) { attachment in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { AttachmentImage(attachment: attachment) }
                        .clipShape(.rect(cornerRadius: Radius.tight))
                        .overlay(alignment: .bottomTrailing) {
                            if attachment.name == shown.last?.name, images.count > shown.count {
                                Text(verbatim: "+\(images.count - shown.count)")
                                    .font(.metadata.weight(.semibold))
                                    .padding(.horizontal, Spacing.m)
                                    .padding(.vertical, Spacing.xs)
                                    .background(.ultraThinMaterial, in: .capsule)
                                    .padding(Spacing.s)
                            }
                        }
                        .onTapGesture { open(attachment) }
                }
            }
        }
    }
}

/// One attachment's image, from the cache or downloaded on appear.
struct AttachmentImage: View {
    let attachment: Attachment
    var thumbnail = true

    @Environment(AccountSession.self) private var session
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.well)
            if let image = image ?? session.files.cachedImage(attachment, thumbnail: thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                Image(icon: .image)
                    .foregroundStyle(.ink2)
            }
        }
        .clipped()
        .accessibilityLabel(attachment.filename.isEmpty ? String(localized: "Photo") : attachment.filename)
        .accessibilityAddTraits(.isImage)
        .task(id: attachment.name) {
            guard image == nil else { return }
            let loaded = await session.files.image(attachment, thumbnail: thumbnail)
            // A cached image is already on screen; only a download fades in.
            withAnimation(.memosFade) { image = loaded }
            failed = loaded == nil
        }
    }
}

struct FileRow: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: Spacing.l) {
            Image(icon: attachment.icon)
                .font(.barSymbol)
                .foregroundStyle(.memosBlue)
                .frame(width: Metrics.iconTile)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(attachment.filename.isEmpty ? String(localized: "Attachment") : attachment.filename)
                    .font(.action)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if attachment.size > 0 {
                    Text(attachment.size.formatted(.byteCount(style: .file)))
                        .font(.metadata)
                        .foregroundStyle(.ink2)
                }
            }
            Spacer(minLength: 0)
        }
        .wellBackground()
    }
}

/// A voice memo: “Transcribed · 0:42” with a play button.
struct AudioAttachmentView: View {
    let attachment: Attachment
    var transcribed = true

    @Environment(AccountSession.self) private var session
    @State private var player = AudioPlayback()

    var body: some View {
        HStack(spacing: Spacing.l) {
            Button {
                Task { await player.toggle(url: { try await session.files.file(attachment) }) }
            } label: {
                Image(icon: player.isPlaying ? .pauseFill : .playFill)
                    .font(.rowSymbol)
                    .frame(width: Metrics.iconTile, height: Metrics.iconTile)
                    .foregroundStyle(.memosBlue)
                    .background(.accentWash, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? Text("Pause voice memo") : Text("Play voice memo"))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(label)
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                ProgressView(value: player.progress)
                    .tint(.memosBlue)
                    // Glides between the 0.2 s ticks instead of stepping.
                    .animation(player.isPlaying ? .linear(duration: AudioPlayback.tick) : nil, value: player.progress)
            }
        }
        .wellBackground()
        .task(id: attachment.name) {
            if let url = try? await session.files.file(attachment) {
                player.loadDuration(url)
            }
        }
    }

    private var label: String {
        let duration = player.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
        return [transcribed ? String(localized: "Transcribed") : String(localized: "Voice memo"), duration].compactMap(\.self).joined(separator: " · ")
    }
}

@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var progress = 0.0
    private(set) var duration: TimeInterval?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    static let tick: TimeInterval = 0.2

    func loadDuration(_ url: URL) {
        duration = (try? AVAudioPlayer(contentsOf: url))?.duration
    }

    func toggle(url: () async throws -> URL) async {
        if let player, player.isPlaying {
            player.pause()
            // The play/pause symbol replace only plays inside an animation.
            withAnimation(.memosSpring) { isPlaying = false }
            ticker?.cancel()
            return
        }
        if player == nil {
            guard let file = try? await url(), let created = try? AVAudioPlayer(contentsOf: file) else { return }
            created.delegate = self
            player = created
            duration = created.duration
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player?.play()
        withAnimation(.memosSpring) { isPlaying = true }
        ticker?.cancel()
        // Stops on pause and at the end, and on its own once the view that owned the player is gone.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tick))
                guard let self, let player = self.player else { return }
                if player.duration > 0 { self.progress = player.currentTime / player.duration }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            withAnimation(.memosSpring) { self.isPlaying = false }
            self.progress = 0
            self.ticker?.cancel()
        }
    }
}
