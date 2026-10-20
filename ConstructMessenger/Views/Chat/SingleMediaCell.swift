//
//  SingleMediaCell.swift
//  Construct Messenger
//
//  The single-photo/video cell of a media bubble, split out of MediaMessageView.swift.
//

import SwiftUI
import Combine

// MARK: - Single image cell

struct SingleMediaCell: View {
    let mediaContent: MediaMessageContent
    let message: TranscriptRow
    let itemIndex: Int
    let isPlaceholder: Bool
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnailImage: PlatformImage?
    /// True once `thumbnailImage` holds a decode of the real media rather than the stored preview.
    /// The two used to be indistinguishable because only our own sends ever had a preview to paint.
    @State private var hasFullCopy = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isMissingMedia = false
    /// The media descriptor (mediaId/mediaUrl/mediaKey) is not readable yet — distinct from
    /// `loadError`, which means a download was attempted and failed. Kept apart because the two
    /// were one state and the "not yet" case rendered as "Failed to load" for a frame on every
    /// outgoing photo.
    @State private var isAwaitingDescriptor = false
    @State private var downloadProgress: Double = 0
    @State private var hasReceivedBytes = false
    @State private var blurPreview: PlatformImage?
    @State private var downloadedVideoURL: URL?
    @State private var isDownloadingVideo = false
    @State private var videoDownloadProgress: Double = 0

    /// Matches the album grid's outer radius (`MediaGridView`) so single and multi-item
    /// media round identically.
    private let cornerRadius: CGFloat = ChatUIConstants.Media.cornerRadius

    private var itemDict: [String: Any] {
        mediaContent.mediaItems.indices.contains(itemIndex)
            ? mediaContent.mediaItems[itemIndex]
            : mediaContent.media
    }

    private var isVideo: Bool {
        (itemDict["mediaType"] as? String)?.hasPrefix("video/") == true
    }

    private var previewSize: CGSize {
        MediaPreviewLayout.previewSize(
            for: itemDict,
            image: thumbnailImage ?? blurPreview
        )
    }

    var body: some View {
        Group {
            if isVideo {
                videoCell
            } else if let thumbnail = thumbnailImage {
                let isUploading = isPlaceholder && message.deliveryStatus == .sending
                Image(platformImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if isUploading { uploadingBadge }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous)
                            .stroke(
                                isSelected ? Color.CT.accent : Color.clear,
                                lineWidth: ChatUIConstants.Media.selectionStrokeWidth
                            )
                    )
                    .onTapGesture { onTap() }
            } else if isLoading || isAwaitingDescriptor {
                // "Waiting for the descriptor" and "downloading" look the same to the user and
                // both end in a picture. Only a real failure gets the warning + Retry.
                loadingPlaceholder
            } else if isMissingMedia {
                unavailablePlaceholder
            } else if loadError != nil {
                errorPlaceholder
            } else {
                emptyPlaceholder
            }
        }
        // Outer clip so every state — photo, video poster, loading/error/empty placeholder —
        // rounds identically to the album grid, regardless of which branch renders.
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: thumbnailImage != nil)
        .onAppear {
            if isVideo {
                syncCachedVideoURL()
                loadVideoPoster()
            } else {
                loadThumbnail()
            }
        }
        // `onAppear` is the only thing that drove the load, so a bubble that appeared before its
        // media descriptor was written had nothing to bring it back — the old code papered over
        // that by rendering the failure state, which at least offered a Retry button. Now that the
        // not-yet state renders as loading, it must actually resolve: re-drive the load when the
        // descriptor lands.
        .onChange(of: itemDict["mediaId"] as? String) { _, newMediaId in
            guard !isVideo, isAwaitingDescriptor, newMediaId != nil else { return }
            loadThumbnail(forceRetry: true)
        }
    }

    /// Video bubble: poster (sender) or blurhash preview (receiver) + play + duration.
    /// Never downloads the full video — playback happens on tap in the gallery.
    private var videoCell: some View {
        let poster = MediaImageCache.shared.paintable(for: message.id, at: itemIndex)
            ?? thumbnailImage ?? blurPreview
        let isUploading = isPlaceholder && message.deliveryStatus == .sending
        return ZStack {
            if let poster {
                Image(platformImage: poster)
                    .resizable()
                    .scaledToFill()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipped()
            } else {
                Rectangle().fill(Color.CT.bgMsg)
                    .frame(width: previewSize.width, height: previewSize.height)
            }
            if !isUploading { videoOverlayGlyph }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if !isUploading, let d = itemDict["duration"] as? Double, d > 0 {
                durationBadge(d)
                    .padding(.leading, CTLayout.inlinePad)
            }
        }
        .overlay(alignment: .bottom) { if isUploading { uploadingBadge } }
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous)
                .stroke(
                    isSelected ? Color.CT.accent : Color.clear,
                    lineWidth: ChatUIConstants.Media.selectionStrokeWidth
                )
        )
        .onTapGesture {
            guard !isPlaceholder else { return }
            guard !isMissingMedia else { return }
            if downloadedVideoURL != nil {
                onTap()
            } else {
                startVideoDownloadAndOpen()
            }
        }
    }

    private func loadVideoPoster() {
        if blurPreview == nil, let bh = itemDict["blurhash"] as? String, !bh.isEmpty {
            blurPreview = decodeBlurPreview(bh)
        }
        if thumbnailImage == nil,
           let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
           let img = PlatformImage(data: data) {
            thumbnailImage = img
        }
    }

    private func syncCachedVideoURL() {
        downloadedVideoURL = MediaVideoCache.shared.url(for: message.id, at: itemIndex)
    }

    // MARK: Placeholder views

    @ViewBuilder
    private var uploadingBadge: some View {
        let progress = MediaUploadProgressTracker.shared.value(for: message.id)
        HStack(spacing: 6) {
            if let progress, progress > 0 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.CT.onMedia)
                    .frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(CTFont.caption).foregroundColor(Color.CT.onMedia).monospacedDigit()
            } else {
                ProgressView().scaleEffect(0.75).tint(Color.CT.onMedia)
                Text(LocalizedStringKey("uploading"))
                    .font(CTFont.caption).foregroundColor(Color.CT.onMedia)
            }
        }
        .padding(.horizontal, CTLayout.inlinePad).padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
        .background(Color.CT.mediaBadge)
        .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.badgeCornerRadius, style: .continuous))
        .padding(.bottom, CTLayout.inlinePad)
        .animation(.easeOut(duration: 0.2), value: progress)
    }

    @ViewBuilder
    private var videoOverlayGlyph: some View {
        if isMissingMedia {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTIcon.font(CTIcon.nav, weight: .semibold))
                .foregroundColor(Color.CT.danger)
                .accessibilityLabel(NSLocalizedString("media_unavailable", comment: ""))
        } else if isDownloadingVideo {
            VStack(spacing: 6) {
                if videoDownloadProgress > 0 {
                    ProgressView(value: videoDownloadProgress)
                        .progressViewStyle(.circular)
                        .tint(Color.CT.onMedia)
                        .scaleEffect(1.1)
                } else {
                    ProgressView()
                        .tint(Color.CT.onMedia)
                        .scaleEffect(1.1)
                }
                if videoDownloadProgress > 0 {
                    Text("\(Int(videoDownloadProgress * 100))%")
                        .font(CTFont.caption)
                        .foregroundColor(Color.CT.onMedia)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, CTLayout.chromeGap)
            .padding(.vertical, CTLayout.inlinePad)
            .background(
                .black.opacity(0.55),
                in: RoundedRectangle(cornerRadius: ChatUIConstants.Media.overlayChipRadius, style: .continuous)
            )
        } else if downloadedVideoURL != nil
                    || MediaVideoFile.isLocal(item: itemDict, messageId: message.id, itemIndex: itemIndex) {
            Image(systemName: "play.fill")
                .font(CTIcon.font(CTIcon.navLg, weight: .regular))
                .foregroundColor(Color.CT.onMedia)
                .frame(
                    width: ChatUIConstants.Media.playButtonSize,
                    height: ChatUIConstants.Media.playButtonSize
                )
                .background(Color.CT.mediaScrim, in: Circle())
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                .foregroundColor(Color.CT.onMedia)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
    }

    private func durationBadge(_ seconds: Double) -> some View {
        Text(formatMediaDuration(seconds))
            .font(CTFont.caption).foregroundColor(Color.CT.onMedia).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.CT.mediaBadge)
            .clipShape(Capsule())
            .padding(8)
    }

    private var loadingPlaceholder: some View {
        ZStack {
            if let preview = blurPreview {
                // Blurred preview from the transmitted BlurHash — clears to the full image.
                Image(platformImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipped()
            } else {
                Rectangle().fill(Color.CT.bgMsg)
                    .frame(width: previewSize.width, height: previewSize.height)
            }

            // Liquid Glass progress chip over the preview.
            Group {
                if hasReceivedBytes && downloadProgress > 0 && downloadProgress < 1 {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(CTFont.secondary)
                        .foregroundColor(Color.CT.onMedia)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(Color.CT.onMedia)
                }
            }
            .padding(14)
            .ctGlassCircle()
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous))
    }

    private func decodeBlurPreview(_ hash: String) -> PlatformImage? {
        let size = previewSize
        let maxEdge: CGFloat = 32
        let scale = maxEdge / max(size.width, size.height)
        return BlurHash.decode(
            hash,
            size: CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        )
    }

    private var errorPlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: previewSize.width, height: previewSize.height)
            .overlay {
                VStack(spacing: ChatUIConstants.Media.failureStackSpacing) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                        .foregroundColor(Color.CT.danger)
                        .lineLimit(1).fixedSize()
                    Text(LocalizedStringKey("failed_to_load")).font(CTFont.caption).foregroundColor(Color.CT.textDim)
                    Button { loadThumbnail(forceRetry: true) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(CTIcon.font(CTIcon.caption, weight: .regular))
                            Text(LocalizedStringKey("retry"))
                        }
                        .font(CTFont.caption).foregroundColor(Color.CT.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.CT.accent.opacity(0.1))
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.3), lineWidth: 1))
                    }
                }
            }
            .overlay(Rectangle().stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2))
    }

    private var unavailablePlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: previewSize.width, height: previewSize.height)
            .overlay {
                VStack(spacing: ChatUIConstants.Media.failureStackSpacing) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                        .foregroundColor(Color.CT.danger)
                        .lineLimit(1).fixedSize()
                    Text(LocalizedStringKey("media_unavailable"))
                        .font(CTFont.caption)
                        .foregroundColor(Color.CT.textDim)
                }
            }
            .overlay(Rectangle().stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2))
    }

    private var emptyPlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: previewSize.width, height: previewSize.height)
            .overlay {
                Image(systemName: "photo")
                    .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                    .foregroundColor(Color.CT.textDim)
            }
            .overlay(Rectangle().stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2))
    }

    // MARK: Load logic

    private func loadThumbnail(forceRetry: Bool = false) {
        // `hasFullCopy`, not `thumbnailImage != nil`. Since the stored thumbnail is now painted for
        // received media too, `thumbnailImage` is set before the download even starts — so the old
        // guard would have made every re-appear a no-op and left the bubble at 320px permanently
        // whenever the first download failed.
        if hasFullCopy || isLoading { return }
        if loadError != nil && !forceRetry { return }
        loadError = nil
        isMissingMedia = false
        isAwaitingDescriptor = false
        hasReceivedBytes = false
        downloadProgress = 0

        // A copy from an earlier appearance of this row. LazyVStack recreates the view when it
        // scrolls back in, which resets `@State`, so without this the bubble re-decodes media it
        // already has — and `hasFullCopy` would read false for a row that is fully loaded.
        if let cached = MediaImageCache.shared.resolvedCopy(for: message.id, at: itemIndex) {
            thumbnailImage = cached
            hasFullCopy = true
            return
        }

        // Decode the transmitted BlurHash into a blurred preview shown while downloading.
        if blurPreview == nil, let bh = itemDict["blurhash"] as? String, !bh.isEmpty {
            blurPreview = decodeBlurPreview(bh)
        }

        // Fast first paint from the locally-stored thumbnail, then upgrade to full quality below.
        // For our own sends the upgrade is a cache hit (cacheSentMedia); for received media it is
        // the download that is already starting a few lines down.
        //
        // This used to be gated on `message.isSentByMe`, which left the *received* thumbnail with
        // no consumer at all: the sender generates it, it is chunked into the sealed message and
        // spends a stealth token per chunk, `MediaWireCodec.storeThumbnails` persists it — and the
        // bubble painted a 32×32 blurhash instead and waited for the full file. We were paying for
        // a preview and then not showing it. (Video never had the gate; `loadVideoPoster` has been
        // using the same field for both directions all along, which is what made the asymmetry
        // visible.)
        if let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
           let img = PlatformImage(data: data) {
            thumbnailImage = img
        }

        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyStr = itemDict["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr)
        else {
            // NOT a failure — the descriptor is not readable *yet*. On our own send this row is
            // created moments before its thumbnail is stored and before the media JSON lands, so
            // for one frame the bubble has neither; painting `errorPlaceholder` there is what made
            // "Failed to load / Retry" flash on every photo we sent (reported 2026-08-04). Rule 1a
            // applied to UI: a not-yet state must not wear the failure's clothes.
            if thumbnailImage == nil {
                isAwaitingDescriptor = true
                Log.debug("Media descriptor not ready yet for \(message.id.prefix(8))…[\(itemIndex)] — showing placeholder, not an error", category: "MediaMessageView")
            }
            return
        }
        isAwaitingDescriptor = false
        if thumbnailImage == nil { isLoading = true }
        // Real byte-level progress: encrypted total comes from the descriptor `size`.
        let total = Double((itemDict["size"] as? Int) ?? 0)
        let onProgress: @Sendable (Int64) -> Void = { received in
            let frac = total > 0 ? min(0.9, Double(received) / total) : 0
            Task { @MainActor in
                if isLoading {
                    hasReceivedBytes = true
                    if total > 0 {
                        downloadProgress = frac
                    }
                }
            }
        }
        Task {
            do {
                let imageData = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId,
                    mediaUrl: mediaUrl,
                    mediaKey: mediaKey,
                    onProgress: onProgress
                )
                await MainActor.run { if isLoading { downloadProgress = 0.95 } }
                // Decode at bubble size. This used to be `PlatformImage(data:)` — a full-resolution
                // decode (~11.8 MB for a 1440×2048 photo) whose only purposes were to make a 320px
                // thumbnail from it and to hand the gallery a copy it can fetch itself. The bubble
                // never needed those pixels, and holding them is what took footprint to 447 MB.
                guard let displayImage = ImageDownsampler.image(from: imageData) else {
                    await MainActor.run {
                        isLoading = false
                        if thumbnailImage == nil { loadError = "Invalid image data" }
                        hasReceivedBytes = false
                        downloadProgress = 0
                    }
                    return
                }
                await MainActor.run {
                    // Display compartment only. The gallery, save and share still want the real
                    // thing and load it on demand from MediaManager — a disk-cache hit, not a
                    // re-download. Storing this copy under the full-resolution key would make
                    // "save to photos" quietly write a 1024px file.
                    MediaImageCache.shared.storeDisplay(displayImage, for: message.id, at: itemIndex)
                    thumbnailImage = displayImage
                    hasFullCopy = true
                    isLoading = false
                    hasReceivedBytes = true
                    downloadProgress = 1.0
                }
            } catch {
                let disposition = MediaLoadFailurePolicy.disposition(for: error)
                if disposition == .permanentlyUnavailable {
                    Log.debug("Single media unavailable for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                } else {
                    Log.error("Single media load failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                }
                await MainActor.run {
                    isLoading = false
                    if thumbnailImage == nil {
                        isMissingMedia = disposition == .permanentlyUnavailable
                        loadError = error.userFacingMessage
                    }
                    hasReceivedBytes = false
                    downloadProgress = 0
                }
            }
        }
    }

    private func startVideoDownloadAndOpen() {
        if let cachedURL = MediaVideoCache.shared.url(for: message.id, at: itemIndex) {
            downloadedVideoURL = cachedURL
            onTap()
            return
        }
        guard !isDownloadingVideo else { return }
        guard let mediaId = itemDict["mediaId"] as? String else { return }

        isDownloadingVideo = true
        videoDownloadProgress = 0
        let total = Double((itemDict["size"] as? Int) ?? 0)
        let onProgress: @Sendable (Int64) -> Void = { received in
            let fraction = total > 0 ? min(0.99, Double(received) / total) : 0
            Task { @MainActor in
                videoDownloadProgress = total > 0 ? fraction : 0
            }
        }

        Task {
            do {
                let url = try await MediaVideoFile.fetch(
                    item: itemDict, messageId: message.id, itemIndex: itemIndex, onProgress: onProgress
                )
                await MainActor.run {
                    downloadedVideoURL = url
                    isDownloadingVideo = false
                    videoDownloadProgress = 1
                    onTap()
                }
            } catch {
                let disposition = MediaLoadFailurePolicy.disposition(for: error)
                if disposition == .permanentlyUnavailable {
                    Log.debug("Video unavailable for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                } else {
                    Log.error("Video preload failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                }
                await MainActor.run {
                    isDownloadingVideo = false
                    videoDownloadProgress = 0
                    isMissingMedia = disposition == .permanentlyUnavailable
                }
            }
        }
    }
}
