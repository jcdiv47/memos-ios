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

    private var images: [Attachment] { attachments.filter(\.isImage) }
    private var others: [Attachment] { attachments.filter { !$0.isImage && !$0.isAudio } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                imageGrid
            }
            ForEach(others, id: \.name) { attachment in
                Button {
                    Task { previewURL = try? await session.files.file(attachment) }
                } label: {
                    FileRow(attachment: attachment)
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private var imageGrid: some View {
        let shown = Array(images.prefix(maxImages))
        if shown.count == 1, let only = shown.first {
            AttachmentImage(attachment: only)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 10))
                .onTapGesture { Task { previewURL = try? await session.files.file(only) } }
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: shown.count == 2 || shown.count == 4 ? 2 : 3)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(shown, id: \.name) { attachment in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { AttachmentImage(attachment: attachment) }
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            if attachment.name == shown.last?.name, images.count > shown.count {
                                Text("+\(images.count - shown.count)")
                                    .font(.footnote.weight(.semibold))
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: .capsule)
                                    .padding(6)
                            }
                        }
                        .onTapGesture { Task { previewURL = try? await session.files.file(attachment) } }
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
            Rectangle().fill(.paper2)
            if let image = image ?? session.files.cachedImage(attachment, thumbnail: thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.ink2)
            }
        }
        .clipped()
        .accessibilityLabel(attachment.filename.isEmpty ? "Photo" : attachment.filename)
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
        HStack(spacing: 10) {
            Image(systemName: attachment.systemImage)
                .font(.title3)
                .foregroundStyle(.memosBlue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename)
                    .font(.subheadline.weight(.medium))
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
        .padding(10)
        .background(.paper2, in: .rect(cornerRadius: 10))
    }
}

/// A voice memo: “Transcribed · 0:42” with a play button.
struct AudioAttachmentView: View {
    let attachment: Attachment
    var transcribed = true

    @Environment(AccountSession.self) private var session
    @State private var player = AudioPlayback()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await player.toggle(url: { try await session.files.file(attachment) }) }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.memosBlue)
                    .background(Color.memosBlue.opacity(0.12), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause voice memo" : "Play voice memo")

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.metadata)
                    .foregroundStyle(.ink2)
                ProgressView(value: player.progress)
                    .tint(.memosBlue)
                    // Glides between the 0.2 s ticks instead of stepping.
                    .animation(player.isPlaying ? .linear(duration: AudioPlayback.tick) : nil, value: player.progress)
            }
        }
        .padding(10)
        .background(.paper2, in: .rect(cornerRadius: 10))
        .task(id: attachment.name) {
            if let url = try? await session.files.file(attachment) {
                player.loadDuration(url)
            }
        }
    }

    private var label: String {
        let duration = player.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
        return [transcribed ? "Transcribed" : "Voice memo", duration].compactMap(\.self).joined(separator: " · ")
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
            isPlaying = false
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
        isPlaying = true
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
            self.isPlaying = false
            self.progress = 0
            self.ticker?.cancel()
        }
    }
}
