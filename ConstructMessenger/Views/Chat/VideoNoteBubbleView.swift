//
//  VideoNoteBubbleView.swift
//  Construct Messenger
//
//  A video note in the transcript: a short video recorded in the chat, shown whole — never
//  cropped to a circle — playing muted on a loop while it is on screen, and opening full screen
//  with sound on tap. `decisions/video-notes-are-uncropped-and-expand.md`.
//
//  The inline loop plays a composition of the video track alone. A muted player still owns an
//  audio track, and with it a claim on the audio session; a note scrolling past must not pause
//  whatever the user is listening to.
//

import SwiftUI
import AVFoundation

struct VideoNoteBubbleView: View {
    let item: [String: Any]
    let message: Message
    let itemIndex: Int
    let isPlaceholder: Bool
    let isSelected: Bool
    /// Opens the note full screen, with sound. Called only once the file is local.
    let onTap: () -> Void

    @State private var videoURL: URL?
    @State private var poster: PlatformImage?
    @State private var isOnScreen = false
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var isMissingMedia = false
    /// What was said, recognised on this device (`message.transcript`, as for voice).
    @State private var transcript: String?
    @State private var isTranscribing = false
    @State private var showsTranscript = true

    private var size: CGSize {
        let width = ChatUIConstants.VideoNote.width
        var aspect = ChatUIConstants.VideoNote.aspectRatio
        if let w = item["width"] as? Int, let h = item["height"] as? Int, w > 0, h > 0 {
            aspect = CGFloat(w) / CGFloat(h)
        }
        return CGSize(width: width, height: width / aspect)
    }

    private var isUploading: Bool { isPlaceholder && message.deliveryStatus == .sending }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatUIConstants.Bubble.stackSpacing) {
            card
            if showsTranscript, let transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(CTFont.message(ChatUIConstants.Typography.messageTextSize))
                    .foregroundColor(Color.CT.text)
                    .frame(width: size.width, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .onAppear { transcript = message.transcript }
    }

    private var card: some View {
        ZStack {
            if let poster {
                Image(platformImage: poster).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.CT.bgMsg)
            }
            if let videoURL, isOnScreen {
                LoopingVideoView(url: videoURL)
            }
            centerGlyph
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) { if !isUploading { chip } }
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous)
                .stroke(isSelected ? Color.CT.accent : Color.clear,
                        lineWidth: ChatUIConstants.Media.selectionStrokeWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .onAppear {
            isOnScreen = true
            loadPoster()
            videoURL = MediaVideoCache.shared.url(for: message.id, at: itemIndex)
            if videoURL == nil, shouldFetchWithoutAsking { fetch(thenOpen: false) }
        }
        .onDisappear { isOnScreen = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("video_note", comment: "A video note in the transcript"))
        .accessibilityAddTraits(.isButton)
        // After the element above, so VoiceOver reaches it on its own.
        .overlay(alignment: .topTrailing) { if !isPlaceholder, !isMissingMedia { transcriptButton } }
    }

    // MARK: Transcript

    /// Recognise the note's speech, or show / hide what was recognised. On this device only
    /// (`VoiceTranscriptionService`), from the decrypted file.
    @ViewBuilder
    private var transcriptButton: some View {
        let has = transcript?.isEmpty == false
        if has || VoiceTranscriptionService.shared.isAvailable {
            Button {
                if has { showsTranscript.toggle() } else { transcribe() }
            } label: {
                Group {
                    if isTranscribing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: has && showsTranscript ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: ChatUIConstants.VideoNote.transcriptIconSize))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .background(.black.opacity(0.45), in: Circle().inset(by: CTLayout.inlinePad))
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .accessibilityLabel(Text(LocalizedStringKey(
                has ? (showsTranscript ? "stt_hide_transcript" : "stt_show_transcript") : "stt_transcribe_button"
            )))
        }
    }

    private func transcribe() {
        guard !isTranscribing else { return }
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                let url = try await MediaVideoFile.fetch(item: item, messageId: message.id, itemIndex: itemIndex)
                await MainActor.run { videoURL = url }
                let audio = try await MediaVideoFile.speech(of: url)
                guard let context = message.managedObjectContext else { return }
                try await VoiceTranscriptionService.shared.transcribe(audioData: audio, message: message, context: context)
                transcript = message.transcript
                showsTranscript = true
            } catch {
                Log.error("Video note transcription failed: \(error)", category: "VideoNoteBubbleView")
            }
        }
    }

    // MARK: Overlays

    /// Duration, and that the sound is off here — it plays with sound full screen.
    private var chip: some View {
        HStack(spacing: ChatUIConstants.VideoNote.chipSpacing) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: ChatUIConstants.VideoNote.chipIconSize))
            if let d = item["duration"] as? Double, d > 0 {
                Text(formatMediaDuration(d)).monospacedDigit()
            }
        }
        .font(CTFont.badge)
        .foregroundColor(.white)
        .padding(.horizontal, ChatUIConstants.VideoNote.chipHorizontalPadding)
        .padding(.vertical, ChatUIConstants.VideoNote.chipVerticalPadding)
        .background(.black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: ChatUIConstants.Media.badgeCornerRadius, style: .continuous))
        .padding(CTLayout.inlinePad)
    }

    @ViewBuilder
    private var centerGlyph: some View {
        if isUploading {
            ProgressView().tint(.white)
        } else if isMissingMedia {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: ChatUIConstants.Media.statusOverlayIconSize, weight: .semibold))
                .foregroundColor(Color.CT.danger)
                .accessibilityLabel(NSLocalizedString("media_unavailable", comment: ""))
        } else if isDownloading {
            if downloadProgress > 0 {
                ProgressView(value: downloadProgress).progressViewStyle(.circular).tint(.white)
            } else {
                ProgressView().tint(.white)
            }
        } else if videoURL == nil {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: ChatUIConstants.VideoNote.downloadIconSize))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
    }

    // MARK: Loading

    /// A note is small (seconds of 720p HEVC), but the user's auto-download setting still decides.
    private var shouldFetchWithoutAsking: Bool {
        guard !isPlaceholder, !isMissingMedia else { return false }
        let reachability = NetworkReachabilityManager.shared
        return MediaAutoDownloadPolicy.shouldFetchOnArrival(
            setting: MediaAutoDownloadPolicy.current(),
            sizeBytes: Int64((item["size"] as? Int) ?? 0),
            isExpensive: reachability.isExpensive,
            isConstrained: reachability.isConstrained
        )
    }

    private func loadPoster() {
        if let cached = MediaImageCache.shared.paintable(for: message.id, at: itemIndex) {
            poster = cached
        } else if let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
                  let image = PlatformImage(data: data) {
            poster = image
        } else if let hash = item["blurhash"] as? String, !hash.isEmpty {
            // A blurhash is a few colours; a tiny decode is all of it.
            poster = BlurHash.decode(hash, size: ChatUIConstants.VideoNote.blurDecodeSize)
        }
    }

    private func open() {
        guard !isPlaceholder, !isMissingMedia else { return }
        if videoURL != nil { onTap() } else { fetch(thenOpen: true) }
    }

    private func fetch(thenOpen: Bool) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        let total = Double((item["size"] as? Int) ?? 0)
        Task {
            do {
                let url = try await MediaVideoFile.fetch(
                    item: item, messageId: message.id, itemIndex: itemIndex
                ) { received in
                    guard total > 0 else { return }
                    let fraction = min(0.99, Double(received) / total)
                    Task { @MainActor in downloadProgress = fraction }
                }
                await MainActor.run {
                    videoURL = url
                    isDownloading = false
                    if thenOpen { onTap() }
                }
            } catch {
                let disposition = MediaLoadFailurePolicy.disposition(for: error)
                await MainActor.run {
                    isDownloading = false
                    isMissingMedia = disposition == .permanentlyUnavailable
                }
            }
        }
    }
}

// MARK: - Video file

/// A media item's video as a local file — what a player needs. Cache-first: the decrypted bytes
/// come from `downloadAndDecryptMedia`, which checks memory and disk before the network, and the
/// file is remembered in `MediaVideoCache` for the message and item.
enum MediaVideoFile {
    static func fetch(
        item: [String: Any],
        messageId: String,
        itemIndex: Int,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> URL {
        if let cached = await MainActor.run(body: { MediaVideoCache.shared.url(for: messageId, at: itemIndex) }) {
            return cached
        }
        guard let mediaId = item["mediaId"] as? String,
              let mediaUrl = item["mediaUrl"] as? String,
              let mediaKey = (item["mediaKey"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { throw MediaUploadError.uploadFailed("Video descriptor incomplete") }

        let data = try await MediaManager.shared.downloadAndDecryptMedia(
            mediaId: mediaId, mediaUrl: mediaUrl, mediaKey: mediaKey, onProgress: onProgress
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(mediaFileExtension(for: item["mediaType"] as? String))
        try data.write(to: url)
        await MainActor.run { MediaVideoCache.shared.store(url, for: messageId, at: itemIndex) }
        await GalleryVideoPage.cacheFirstFramePoster(from: url, messageId: messageId, itemIndex: itemIndex)
        return url
    }
}

extension MediaVideoFile {
    /// The audio of a video, as m4a — what the recognisers take. Stays on the device.
    static func speech(of url: URL) async throws -> Data {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaUploadError.uploadFailed("Cannot extract audio")
        }
        try await export.export(to: out, as: .m4a)
        return try Data(contentsOf: out)
    }
}

// MARK: - Muted loop

/// Plays `url`'s video track on a loop, with no audio track at all (see the file header).
struct LoopingVideoView: View {
    let url: URL
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        PlayerLayerView(player: player)
            .task(id: url) {
                guard let item = await Self.silentItem(for: url) else { return }
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                looper = AVPlayerLooper(player: player, templateItem: item)
                player.play()
            }
            .onDisappear {
                player.pause()
                looper = nil
                player.removeAllItems()
            }
    }

    private static func silentItem(for url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration) else { return nil }
        let composition = AVMutableComposition()
        guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)) != nil
        else { return nil }
        copy.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        return AVPlayerItem(asset: composition)
    }
}

#if canImport(UIKit)
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}
#else
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
#endif
