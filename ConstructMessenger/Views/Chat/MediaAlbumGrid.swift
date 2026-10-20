//
//  MediaAlbumGrid.swift
//  Construct Messenger
//
//  The multi-photo album grid (MediaGridView, MediaAlbumGridLayout, GridCell), split out of MediaMessageView.swift.
//

import SwiftUI
import Combine

// MARK: - Multi-image grid (2+ photos)

struct MediaGridView: View {
    let mediaContent: MediaMessageContent
    let message: TranscriptRow
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

struct GridCell: View {
    let mediaContent: MediaMessageContent
    let message: TranscriptRow
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
                    .font(CTFont.ui(22, weight: .semibold)).foregroundColor(Color.CT.onMedia)
            }

            if isUploading {
                Color.black.opacity(0.35)
                let progress = MediaUploadProgressTracker.shared.value(for: message.id)
                if let progress, progress > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(CTFont.secondary).foregroundColor(Color.CT.onMedia).monospacedDigit()
                        .animation(.easeOut(duration: 0.2), value: progress)
                } else {
                    ProgressView().tint(Color.CT.onMedia)
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
                        .foregroundColor(Color.CT.onMedia)
                        .monospacedDigit()
                } else {
                    ProgressView().tint(Color.CT.onMedia)
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
                        .tint(Color.CT.onMedia)
                        .scaleEffect(0.9)
                } else {
                    ProgressView()
                        .tint(Color.CT.onMedia)
                        .scaleEffect(0.9)
                }
                if videoDownloadProgress > 0 {
                    Text("\(Int(videoDownloadProgress * 100))%")
                        .font(CTFont.micro)
                        .foregroundColor(Color.CT.onMedia)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, CTLayout.inlinePad)
            .padding(.vertical, 6)
            .background(
                .black.opacity(0.55),
                in: RoundedRectangle(cornerRadius: ChatUIConstants.Media.cornerRadius, style: .continuous)
            )
        } else if downloadedVideoURL != nil
                    || MediaVideoFile.isLocal(item: itemDict, messageId: message.id, itemIndex: itemIndex) {
            Image(systemName: "play.fill")
                .font(CTIcon.font(CTIcon.row, weight: .regular))
                .foregroundColor(Color.CT.onMedia)
                .frame(
                    width: ChatUIConstants.Voice.controlWidth,
                    height: ChatUIConstants.Voice.controlWidth
                )
                .background(Color.CT.mediaScrim, in: Circle())
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(CTIcon.font(CTIcon.nav, weight: .regular))
                .foregroundColor(Color.CT.onMedia)
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
