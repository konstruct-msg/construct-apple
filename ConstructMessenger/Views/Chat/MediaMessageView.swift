//
//  MediaMessageView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import Combine
import GRPCCore

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if itemCount <= 1 {
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
                Text(mediaContent.caption)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.top, 2)
            }
        }
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
    @State private var isLoading = false
    @State private var loadError: String?
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
        let poster = MediaImageCache.shared.image(for: message.id, at: itemIndex) ?? thumbnailImage ?? blurPreview
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
                    .font(CTFont.regular(11)).foregroundColor(.white).monospacedDigit()
            } else {
                ProgressView().scaleEffect(0.75).tint(.white)
                Text(LocalizedStringKey("uploading"))
                    .font(CTFont.regular(11)).foregroundColor(.white)
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
        if isDownloadingVideo {
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
                        .font(CTFont.regular(11))
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
                .font(.system(size: CTLayout.navIconSizeLg))
                .foregroundColor(.white)
                .frame(
                    width: ChatUIConstants.Media.playButtonSize,
                    height: ChatUIConstants.Media.playButtonSize
                )
                .background(.black.opacity(0.45), in: Circle())
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
    }

    private func durationBadge(_ seconds: Double) -> some View {
        Text(formatMediaDuration(seconds))
            .font(CTFont.regular(11)).foregroundColor(.white).monospacedDigit()
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
                        .font(CTFont.regular(12))
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
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(CTFont.regular(36)).foregroundColor(.orange)
                        .lineLimit(1).fixedSize()
                    Text(LocalizedStringKey("failed_to_load")).font(CTFont.regular(11)).foregroundColor(Color.CT.textDim)
                    Button { loadThumbnail(forceRetry: true) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .regular))
                            Text(LocalizedStringKey("retry"))
                        }
                        .font(CTFont.regular(11)).foregroundColor(Color.CT.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.CT.accent.opacity(0.1))
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.3), lineWidth: 1))
                    }
                }
            }
            .overlay(Rectangle().stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2))
    }

    private var emptyPlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: previewSize.width, height: previewSize.height)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundColor(Color.CT.textDim)
            }
            .overlay(Rectangle().stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2))
    }

    // MARK: Load logic

    private func loadThumbnail(forceRetry: Bool = false) {
        if thumbnailImage != nil || isLoading { return }
        if loadError != nil && !forceRetry { return }
        loadError = nil
        isAwaitingDescriptor = false
        hasReceivedBytes = false
        downloadProgress = 0

        // Decode the transmitted BlurHash into a blurred preview shown while downloading.
        if blurPreview == nil, let bh = itemDict["blurhash"] as? String, !bh.isEmpty {
            blurPreview = decodeBlurPreview(bh)
        }

        // Fast first paint from a locally-stored thumbnail (placeholder / sent), then
        // upgrade to full quality below. The sender's full image is cached at send time
        // (MediaManager.cacheSentMedia), so the upgrade is a cache hit — no re-download.
        if message.isSentByMe,
           let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
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
                guard let image = PlatformImage(data: imageData) else {
                    await MainActor.run {
                        isLoading = false
                        if thumbnailImage == nil { loadError = "Invalid image data" }
                        hasReceivedBytes = false
                        downloadProgress = 0
                    }
                    return
                }
                // Full image → gallery cache; a 320px thumb keeps the bubble light.
                let thumbnail = MediaManager.shared.generateThumbnailImage(from: image, maxSize: 320)
                await MainActor.run {
                    MediaImageCache.shared.store(image, for: message.id, at: itemIndex)
                    thumbnailImage = thumbnail
                    isLoading = false
                    hasReceivedBytes = true
                    downloadProgress = 1.0
                }
            } catch {
                Log.error("Single media load failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                await MainActor.run {
                    isLoading = false
                    if thumbnailImage == nil { loadError = error.localizedDescription }
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
        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyStr = itemDict["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr) else { return }

        isDownloadingVideo = true
        videoDownloadProgress = 0
        let total = Double((itemDict["size"] as? Int) ?? 0)
        let fileExtension = mediaFileExtension(for: itemDict["mediaType"] as? String)
        let onProgress: @Sendable (Int64) -> Void = { received in
            let fraction = total > 0 ? min(0.99, Double(received) / total) : 0
            Task { @MainActor in
                videoDownloadProgress = total > 0 ? fraction : 0
            }
        }

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId,
                    mediaUrl: mediaUrl,
                    mediaKey: mediaKey,
                    onProgress: onProgress
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExtension)
                try data.write(to: url)
                await MainActor.run {
                    MediaVideoCache.shared.store(url, for: message.id, at: itemIndex)
                    downloadedVideoURL = url
                    isDownloadingVideo = false
                    videoDownloadProgress = 1
                    onTap()
                }
                await GalleryVideoPage.cacheFirstFramePoster(from: url, messageId: message.id, itemIndex: itemIndex)
            } catch {
                Log.error("Video preload failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                await MainActor.run {
                    isDownloadingVideo = false
                    videoDownloadProgress = 0
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
        // 4 = balanced 2×2, 5+ = editorial hero + expanded 2-column tail. Outer corners are
        // rounded by clipping the whole album; inner tiles are square with 2px gaps.
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
        VStack(spacing: spacing) {
            ForEach(Array(stride(from: startIndex, to: itemCount, by: 2)), id: \.self) { rowStart in
                HStack(spacing: spacing) {
                    tile(rowStart, t, t)
                    if rowStart + 1 < itemCount {
                        tile(rowStart + 1, t, t)
                    } else {
                        Color.clear
                            .frame(width: t, height: t)
                    }
                }
            }
        }
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
            if isVideo, let poster = MediaImageCache.shared.image(for: message.id, at: itemIndex) ?? thumbnailImage ?? blurPreview {
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
                    .font(.title2.weight(.semibold)).foregroundColor(.white)
            }

            if isUploading {
                Color.black.opacity(0.35)
                let progress = MediaUploadProgressTracker.shared.value(for: message.id)
                if let progress, progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(CTFont.regular(12)).foregroundColor(.white).monospacedDigit()
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
                if downloadedVideoURL != nil {
                    onTap()
                } else {
                    startVideoDownloadAndOpen()
                }
            } else if loadFailed {
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
            .font(.system(size: 22, weight: loadFailed ? .semibold : .regular))
            .foregroundColor(loadFailed ? .orange : Color.CT.textDim)
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
                        .font(CTFont.regular(11))
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
        if isDownloadingVideo {
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
                        .font(CTFont.regular(10))
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
                .font(.system(size: CTLayout.sectionGap))
                .foregroundColor(.white)
                .frame(
                    width: ChatUIConstants.Voice.controlWidth,
                    height: ChatUIConstants.Voice.controlWidth
                )
                .background(.black.opacity(0.45), in: Circle())
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
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
        if thumbnailImage != nil || isLoading { return }
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
        if let cached = MediaImageCache.shared.image(for: message.id, at: itemIndex) {
            thumbnailImage = cached
            return
        }
        // Fast paint from a local thumbnail (sent), then upgrade to full via the cache.
        if message.isSentByMe,
           let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
           let img = PlatformImage(data: data) {
            thumbnailImage = img
            MediaImageCache.shared.store(img, for: message.id, at: itemIndex)
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
                    MediaImageCache.shared.store(image, for: message.id, at: itemIndex)
                    thumbnailImage = thumb
                    isLoading = false
                    hasReceivedBytes = true
                    downloadProgress = 1.0
                }
            } catch {
                Log.error("Grid media load failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                await MainActor.run {
                    isLoading = false
                    loadFailed = true
                    isMissingMedia = isMediaMissingError(error)
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
        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyStr = itemDict["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr) else { return }

        isDownloadingVideo = true
        videoDownloadProgress = 0
        let total = Double((itemDict["size"] as? Int) ?? 0)
        let fileExtension = mediaFileExtension(for: itemDict["mediaType"] as? String)
        let onProgress: @Sendable (Int64) -> Void = { received in
            let fraction = total > 0 ? min(0.99, Double(received) / total) : 0
            Task { @MainActor in
                videoDownloadProgress = total > 0 ? fraction : 0
            }
        }

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId,
                    mediaUrl: mediaUrl,
                    mediaKey: mediaKey,
                    onProgress: onProgress
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExtension)
                try data.write(to: url)
                await MainActor.run {
                    MediaVideoCache.shared.store(url, for: message.id, at: itemIndex)
                    downloadedVideoURL = url
                    isDownloadingVideo = false
                    videoDownloadProgress = 1
                    onTap()
                }
                await GalleryVideoPage.cacheFirstFramePoster(from: url, messageId: message.id, itemIndex: itemIndex)
            } catch {
                Log.error("Grid video preload failed for \(mediaId.prefix(8))…: \(error)", category: "MediaMessageView")
                await MainActor.run {
                    isDownloadingVideo = false
                    videoDownloadProgress = 0
                }
            }
        }
    }
}

private func isMediaMissingError(_ error: Error) -> Bool {
    guard let rpcError = error as? RPCError else { return false }
    return rpcError.code == .notFound
}

/// "m:ss" for a media duration.
func formatMediaDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

private func mediaFileExtension(for mediaType: String?) -> String {
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
