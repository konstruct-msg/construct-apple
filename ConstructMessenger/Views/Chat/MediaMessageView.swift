//
//  MediaMessageView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import Combine

/// Single-item bubble sizing: preserve real orientation, clamp extreme aspect ratios
/// (Telegram/Signal-style — panoramas and tall screenshots don't dominate the stream).
private enum MediaPreviewLayout {
    static let maxWidth: CGFloat = 260
    /// Portrait limit — no taller than 2:3 (w/h ≥ 2/3).
    static let minAspectRatio: CGFloat = 2.0 / 3.0
    /// Landscape limit — no wider than 3:2 (w/h ≤ 3/2).
    static let maxAspectRatio: CGFloat = 3.0 / 2.0
    static let defaultAspectRatio: CGFloat = 3.0 / 4.0

    static func clampedAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return defaultAspectRatio }
        let ratio = width / height
        return min(max(ratio, minAspectRatio), maxAspectRatio)
    }

    static func aspectRatio(for item: [String: Any], image: PlatformImage? = nil) -> CGFloat {
        if let w = item["width"] as? Int, let h = item["height"] as? Int, w > 0, h > 0 {
            return clampedAspectRatio(width: CGFloat(w), height: CGFloat(h))
        }
        if let image, image.size.width > 0, image.size.height > 0 {
            return clampedAspectRatio(width: image.size.width, height: image.size.height)
        }
        return defaultAspectRatio
    }

    static func previewSize(for item: [String: Any], image: PlatformImage? = nil) -> CGSize {
        let aspect = aspectRatio(for: item, image: image)
        return CGSize(width: maxWidth, height: maxWidth / aspect)
    }
}

struct MediaMessageView: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let isSelected: Bool
    /// Album item index the user tapped (0 for a single-photo message).
    let onTapFullScreen: ((Int) -> Void)?

    /// True when this message is a local upload placeholder (not yet sent to server).
    private var isPlaceholder: Bool {
        (mediaContent.media["_placeholder"] as? Bool) == true
    }

    private var itemCount: Int { mediaContent.mediaItems.count }

    /// A video note is one video; the presentation on anything else is ignored — the ordinary
    /// bubble for what the item is.
    private var isVideoNote: Bool {
        MediaPresentation.of(mediaContent.media) == .videoNote
            && (mediaContent.media["mediaType"] as? String)?.hasPrefix("video/") == true
    }

    /// A placeholder for files being sent: their rows, not a photo cell (TODO 10).
    private var uploadingFiles: [(name: String, size: Int?)]? {
        guard isPlaceholder else { return nil }
        let files = mediaContent.mediaItems.compactMap { item in
            (item["fileName"] as? String).map { (name: $0, size: item["size"] as? Int) }
        }
        return files.isEmpty ? nil : files
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let uploadingFiles {
                UploadingFilesView(
                    files: uploadingFiles,
                    caption: mediaContent.caption,
                    messageId: message.id,
                    isUploading: message.deliveryStatus == .sending
                )
            } else if itemCount <= 1, isVideoNote {
                VideoNoteBubbleView(
                    item: mediaContent.media,
                    message: message,
                    itemIndex: 0,
                    isPlaceholder: isPlaceholder,
                    isSelected: isSelected,
                    onOpenFullScreen: { if !isPlaceholder { onTapFullScreen?(0) } }
                )
            } else if itemCount <= 1 {
                SingleMediaCell(
                    mediaContent: mediaContent,
                    message: message,
                    itemIndex: 0,
                    isPlaceholder: isPlaceholder,
                    isSelected: isSelected,
                    onTap: { if !isPlaceholder { onTapFullScreen?(0) } }
                )
            } else {
                MediaGridView(
                    mediaContent: mediaContent,
                    message: message,
                    isPlaceholder: isPlaceholder,
                    isSelected: isSelected,
                    onTapItem: { index in if !isPlaceholder { onTapFullScreen?(index) } }
                )
            }

            if !mediaContent.caption.isEmpty {
                MediaCaptionText(caption: mediaContent.caption)
            }
        }
    }
}

struct MediaCaptionText: View {
    let caption: String

    var body: some View {
        Text(caption)
            .font(CTFont.message(ChatUIConstants.Typography.captionSize))
            .foregroundColor(Color.CT.text)
            .frame(maxWidth: MediaPreviewLayout.maxWidth, alignment: .leading)
            // Captions are message content. They wrap to their intrinsic height instead of
            // accepting a compressed one-line proposal from the surrounding transcript row.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, ChatUIConstants.Media.captionTopPadding)
    }
}

// MARK: - Single image cell

private struct SingleMediaCell: View {
    let mediaContent: MediaMessageContent
    let message: Message
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
                    .tint(.white)
                    .frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(CTFont.caption).foregroundColor(.white).monospacedDigit()
            } else {
                ProgressView().scaleEffect(0.75).tint(.white)
                Text(LocalizedStringKey("uploading"))
                    .font(CTFont.caption).foregroundColor(.white)
            }
        }
        .padding(.horizontal, CTLayout.inlinePad).padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
        .background(.black.opacity(0.55))
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
                        .tint(.white)
                        .scaleEffect(1.1)
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.1)
                }
                if videoDownloadProgress > 0 {
                    Text("\(Int(videoDownloadProgress * 100))%")
                        .font(CTFont.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, CTLayout.chromeGap)
            .padding(.vertical, CTLayout.inlinePad)
            .background(
                .black.opacity(0.55),
                in: RoundedRectangle(cornerRadius: ChatUIConstants.Media.overlayChipRadius, style: .continuous)
            )
        } else if downloadedVideoURL != nil {
            Image(systemName: "play.fill")
                .font(CTIcon.font(CTIcon.navLg, weight: .regular))
                .foregroundColor(.white)
                .frame(
                    width: ChatUIConstants.Media.playButtonSize,
                    height: ChatUIConstants.Media.playButtonSize
                )
                .background(.black.opacity(0.45), in: Circle())
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
    }

    private func durationBadge(_ seconds: Double) -> some View {
        Text(formatMediaDuration(seconds))
            .font(CTFont.caption).foregroundColor(.white).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55))
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
                        .foregroundColor(.white)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(.white)
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
                        loadError = error.localizedDescription
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

// MARK: - Multi-image grid (2+ photos)

private struct MediaGridView: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let isPlaceholder: Bool
    let isSelected: Bool
    let onTapItem: (Int) -> Void

    private let albumWidth: CGFloat = 244
    private let spacing: CGFloat = ChatUIConstants.Media.albumTileGap

    private var itemCount: Int { mediaContent.mediaItems.count }

    var body: some View {
        // Square-crop mosaic: 2 = two squares, 3 = big-left + 2 stacked right,
        // 4 = balanced 2×2, 5+ = editorial hero + 2-column tail (a leftover last
        // tile spans full width). Outer corners are rounded by clipping the whole
        // album; inner tiles are square with 2px gaps.
        Group {
            switch itemCount {
            case 2:  twoLayout
            case 3:  threeLayout
            case 4:  fourLayout
            default: editorialExpandedLayout
            }
        }
        .frame(width: albumWidth)
        .clipShape(RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous)
                .stroke(
                    isSelected ? Color.CT.accent : Color.clear,
                    lineWidth: ChatUIConstants.Media.selectionStrokeWidth
                )
        )
    }

    private func tile(_ index: Int, _ w: CGFloat, _ h: CGFloat, extra: Int = 0) -> some View {
        GridCell(
            mediaContent: mediaContent,
            message: message,
            itemIndex: index,
            isPlaceholder: isPlaceholder,
            extraCount: extra,
            onTap: { onTapItem(index) }
        )
        .frame(width: w, height: h)
        .clipped()
    }

    private var twoLayout: some View {
        let t = (albumWidth - spacing) / 2
        return HStack(spacing: spacing) {
            tile(0, t, t)
            tile(1, t, t)
        }
    }

    private var threeLayout: some View {
        let bigW = (albumWidth - spacing) * 0.64
        let smallW = albumWidth - spacing - bigW
        let bigH = bigW
        let smallH = (bigH - spacing) / 2
        return HStack(spacing: spacing) {
            tile(0, bigW, bigH)
            VStack(spacing: spacing) {
                tile(1, smallW, smallH)
                tile(2, smallW, smallH)
            }
        }
    }

    private var fourLayout: some View {
        let t = (albumWidth - spacing) / 2
        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                tile(0, t, t)
                tile(1, t, t)
            }
            HStack(spacing: spacing) {
                tile(2, t, t)
                tile(3, t, t)
            }
        }
    }

    private var editorialExpandedLayout: some View {
        let heroHeight = albumWidth * 0.72
        return VStack(spacing: spacing) {
            tile(0, albumWidth, heroHeight)
            editorialTailLayout(startingAt: 1)
        }
    }

    @ViewBuilder
    private func editorialTailLayout(startingAt startIndex: Int) -> some View {
        let t = (albumWidth - spacing) / 2
        let rows = MediaAlbumGridLayout.tailRows(itemCount: itemCount, startingAt: startIndex)
        VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.count == 2 {
                    HStack(spacing: spacing) {
                        tile(row[0], t, t)
                        tile(row[1], t, t)
                    }
                } else if let only = row.first {
                    // Leftover last photo spans the album, rather than hanging in the left
                    // column next to an empty cell.
                    tile(only, albumWidth, t)
                }
            }
        }
    }
}

/// How the 5+ mosaic's tail is grouped. Extracted so a hanging last tile is a
/// named decision a test can break, not a `Color.clear` spacer in the view.
enum MediaAlbumGridLayout {
    /// Rows of 2, with a leftover last index in its own row (drawn full-width).
    static func tailRows(itemCount: Int, startingAt startIndex: Int) -> [[Int]] {
        guard startIndex < itemCount else { return [] }
        var rows: [[Int]] = []
        var i = startIndex
        while i < itemCount {
            if i + 1 < itemCount {
                rows.append([i, i + 1])
                i += 2
            } else {
                rows.append([i])
                i += 1
            }
        }
        return rows
    }
}

private struct GridCell: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let itemIndex: Int
    let isPlaceholder: Bool
    let extraCount: Int
    let onTap: () -> Void

    @State private var thumbnailImage: PlatformImage?
    /// See the single-image bubble: distinguishes "showing the stored preview" from "loaded".
    @State private var hasFullCopy = false
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var downloadProgress: Double = 0
    @State private var hasReceivedBytes = false
    @State private var isMissingMedia = false
    @State private var blurPreview: PlatformImage?
    @State private var downloadedVideoURL: URL?
    @State private var isDownloadingVideo = false
    @State private var videoDownloadProgress: Double = 0

    private var itemDict: [String: Any] {
        mediaContent.mediaItems.indices.contains(itemIndex) ? mediaContent.mediaItems[itemIndex] : [:]
    }

    private var isVideo: Bool {
        (itemDict["mediaType"] as? String)?.hasPrefix("video/") == true
    }

    var body: some View {
        ZStack {
            if isVideo, let poster = MediaImageCache.shared.paintable(for: message.id, at: itemIndex)
                ?? thumbnailImage ?? blurPreview {
                Image(platformImage: poster).resizable().scaledToFill()
            } else if let img = thumbnailImage {
                Image(platformImage: img).resizable().scaledToFill()
            } else {
                if isLoading {
                    loadingPlaceholder
                } else {
                    idlePlaceholder
                }
            }

            let isUploading = isPlaceholder && message.deliveryStatus == .sending
            if isVideo && !isUploading {
                videoOverlayGlyph
            }

            if extraCount > 0 {
                Color.black.opacity(0.5)
                Text("+\(extraCount)")
                    .font(CTFont.ui(22, weight: .semibold)).foregroundColor(.white)
            }

            if isUploading {
                Color.black.opacity(0.35)
                let progress = MediaUploadProgressTracker.shared.value(for: message.id)
                if let progress, progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(CTFont.secondary).foregroundColor(.white).monospacedDigit()
                        .animation(.easeOut(duration: 0.2), value: progress)
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isVideo {
                guard !isPlaceholder else { return }
                guard !isMissingMedia else { return }
                if downloadedVideoURL != nil {
                    onTap()
                } else {
                    startVideoDownloadAndOpen()
                }
            } else if loadFailed && !isMissingMedia {
                loadThumbnail(forceRetry: true)
            } else if !isPlaceholder, thumbnailImage != nil {
                onTap()
            }
        }
        .onAppear {
            if isVideo {
                syncCachedVideoURL()
                loadVideoPoster()
            } else {
                loadThumbnail()
            }
        }
    }

    private func loadVideoPoster() {
        if blurPreview == nil, let bh = itemDict["blurhash"] as? String, !bh.isEmpty {
            blurPreview = BlurHash.decode(bh, size: CGSize(width: 32, height: 32))
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

    @ViewBuilder
    private var idlePlaceholder: some View {
        Color.CT.bgMsg
        Image(systemName: placeholderSymbolName)
            .font(CTIcon.font(CTIcon.navLg, weight: loadFailed ? .semibold : .regular))
            .foregroundColor(loadFailed ? Color.CT.danger : Color.CT.textDim)
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        ZStack {
            if let preview = blurPreview {
                Image(platformImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.CT.bgMsg
            }
            Group {
                if hasReceivedBytes && downloadProgress > 0 && downloadProgress < 1 {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(CTFont.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(12)
            .ctGlassCircle()
        }
    }

    @ViewBuilder
    private var videoOverlayGlyph: some View {
        if isMissingMedia {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTIcon.font(CTIcon.nav, weight: .semibold))
                .foregroundColor(Color.CT.danger)
                .accessibilityLabel(NSLocalizedString("media_unavailable", comment: ""))
        } else if isDownloadingVideo {
            VStack(spacing: 4) {
                if videoDownloadProgress > 0 {
                    ProgressView(value: videoDownloadProgress)
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.9)
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.9)
                }
                if videoDownloadProgress > 0 {
                    Text("\(Int(videoDownloadProgress * 100))%")
                        .font(CTFont.micro)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, CTLayout.inlinePad)
            .padding(.vertical, 6)
            .background(
                .black.opacity(0.55),
                in: RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous)
            )
        } else if downloadedVideoURL != nil {
            Image(systemName: "play.fill")
                .font(CTIcon.font(CTIcon.row, weight: .regular))
                .foregroundColor(.white)
                .frame(
                    width: ChatUIConstants.Voice.controlWidth,
                    height: ChatUIConstants.Voice.controlWidth
                )
                .background(.black.opacity(0.45), in: Circle())
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(CTIcon.font(CTIcon.nav, weight: .regular))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
    }

    private var placeholderSymbolName: String {
        if isMissingMedia {
            return "exclamationmark.triangle.fill"
        }
        return loadFailed ? "arrow.clockwise" : "photo"
    }

    private func loadThumbnail(forceRetry: Bool = false) {
        // See the single-image loader: `thumbnailImage` is now set from the stored preview before
        // the download starts, so it can no longer stand in for "loaded".
        if hasFullCopy || isLoading { return }
        if loadFailed && !forceRetry { return }
        if forceRetry {
            loadFailed = false
            isMissingMedia = false
            hasReceivedBytes = false
            downloadProgress = 0
        }
        loadFailed = false
        isMissingMedia = false
        hasReceivedBytes = false
        downloadProgress = 0
        // `resolvedCopy`, not `paintable`: only a real decode of the media means "nothing left to
        // load". Returning early on a poster would leave a failed download stuck at 320px forever,
        // with no error and no retry — the tile would look fine and never improve.
        if let cached = MediaImageCache.shared.resolvedCopy(for: message.id, at: itemIndex) {
            thumbnailImage = cached
            hasFullCopy = true
            return
        }
        // Fast paint from the stored thumbnail — for received media too, see loadThumbnail. Paint
        // and keep going; the download below is what finishes the job.
        if let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
           let img = PlatformImage(data: data) {
            thumbnailImage = img
            MediaImageCache.shared.storePoster(img, for: message.id, at: itemIndex)
        }
        if blurPreview == nil, let bh = itemDict["blurhash"] as? String, !bh.isEmpty {
            blurPreview = BlurHash.decode(bh, size: CGSize(width: 32, height: 32))
        }
        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyStr = itemDict["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr)
        else { return }
        isLoading = true
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
                await MainActor.run {
                    if isLoading {
                        downloadProgress = 0.95
                    }
                }
                guard let image = PlatformImage(data: imageData) else {
                    await MainActor.run {
                        isLoading = false
                        loadFailed = true
                        hasReceivedBytes = false
                        downloadProgress = 0
                    }
                    return
                }
                // Full image → gallery cache; a 200px thumb keeps the tile light.
                let thumb = MediaManager.shared.generateThumbnailImage(from: image, maxSize: 200)
                await MainActor.run {
                    MediaImageCache.shared.storeOriginal(image, for: message.id, at: itemIndex)
                    thumbnailImage = thumb
                    hasFullCopy = true
                    isLoading = false
                    hasReceivedBytes = true
                    downloadProgress = 1.0
                }
            } catch {
                let disposition = MediaLoadFailurePolicy.disposition(for: error)
                if disposition == .permanentlyUnavailable {
                    Log.debug("Grid media unavailable for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                } else {
                    Log.error("Grid media load failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                }
                await MainActor.run {
                    isLoading = false
                    loadFailed = true
                    isMissingMedia = disposition == .permanentlyUnavailable
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
                    Log.debug("Grid video unavailable for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                } else {
                    Log.error("Grid video preload failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
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

/// "m:ss" for a media duration.
func formatMediaDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

func mediaFileExtension(for mediaType: String?) -> String {
    switch mediaType {
    case "video/quicktime":
        return "mov"
    case let type? where type.hasPrefix("video/"):
        return "mp4"
    default:
        return "mp4"
    }
}

// MARK: - Liquid Glass helper

private extension View {
    /// Liquid Glass background on iOS 26+, `.ultraThinMaterial` fallback otherwise.
    @ViewBuilder func ctGlassCircle() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
        #else
        self.background(.ultraThinMaterial, in: Circle())
        #endif
    }
}

/// The files of a send still uploading, drawn as the file bubble will draw them — symbol, name,
/// size — with the upload's progress under them. Until 2026-10-06 a set of files was one empty
/// photo cell captioned with the first file's name (TODO 10).
private struct UploadingFilesView: View {
    let files: [(name: String, size: Int?)]
    let caption: String
    let messageId: String
    let isUploading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CTRadius.badge) {
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: CTLayout.chromeGap) {
                    Image(systemName: FileAttachmentBubbleView.symbolName(for: file.name))
                        .font(CTIcon.font(CTIcon.navLg, weight: .regular))
                        .foregroundStyle(Color.CT.outMsgText)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(CTFont.ui(13, weight: .medium))
                            .foregroundColor(Color.CT.outMsgText)
                            .lineLimit(1)
                        if let size = file.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(CTFont.mono(ChatUIConstants.Typography.systemSize))
                                .foregroundColor(Color.CT.outMsgText.opacity(0.7))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if isUploading {
                progress
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(CTFont.ui(ChatUIConstants.Typography.captionSize))
                    .foregroundColor(Color.CT.outMsgText)
                    .padding(.top, 2)
            }
        }
        .padding(ChatUIConstants.Bubble.horizontalPadding)
        .background(CTMessageBubbleTheme.background(isSentByMe: true))
        .clipShape(CTShape.control())
        .overlay(CTShape.control().stroke(Color.CT.noise, lineWidth: ChatUIConstants.Bubble.strokeWidth))
    }

    @ViewBuilder
    private var progress: some View {
        let value = MediaUploadProgressTracker.shared.value(for: messageId)
        HStack(spacing: CTLayout.inlinePad) {
            if let value, value > 0 {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .tint(Color.CT.outMsgText)
                Text("\(Int(value * 100))%")
                    .font(CTFont.mono(ChatUIConstants.Typography.systemSize))
                    .foregroundColor(Color.CT.outMsgText.opacity(0.7))
                    .monospacedDigit()
            } else {
                ProgressView().scaleEffect(0.75).tint(Color.CT.outMsgText)
                Text(LocalizedStringKey("uploading"))
                    .font(CTFont.mono(ChatUIConstants.Typography.systemSize))
                    .foregroundColor(Color.CT.outMsgText.opacity(0.7))
            }
        }
        .animation(.easeOut(duration: 0.2), value: value)
    }
}
