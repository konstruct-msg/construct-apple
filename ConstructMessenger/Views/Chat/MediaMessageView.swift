//
//  MediaMessageView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import Combine
import GRPCCore

struct MediaMessageView: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let isSelected: Bool
    let onTapFullScreen: (() -> Void)?

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
                    onTap: { if !isPlaceholder { onTapFullScreen?() } }
                )
            } else {
                MediaGridView(
                    mediaContent: mediaContent,
                    message: message,
                    isPlaceholder: isPlaceholder,
                    isSelected: isSelected,
                    onTapItem: { _ in if !isPlaceholder { onTapFullScreen?() } }
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
    @State private var downloadProgress: Double = 0
    @State private var hasReceivedBytes = false
    @State private var blurPreview: PlatformImage?

    private var itemDict: [String: Any] {
        mediaContent.mediaItems.indices.contains(itemIndex)
            ? mediaContent.mediaItems[itemIndex]
            : mediaContent.media
    }

    private var isVideo: Bool {
        (itemDict["mediaType"] as? String)?.hasPrefix("video/") == true
    }

    var body: some View {
        Group {
            if isVideo {
                videoCell
            } else if let thumbnail = thumbnailImage {
                let isUploading = isPlaceholder && message.deliveryStatus == .sending
                Image(platformImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) {
                        if isUploading { uploadingBadge }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture { onTap() }
            } else if isLoading {
                loadingPlaceholder
            } else if loadError != nil {
                errorPlaceholder
            } else {
                emptyPlaceholder
            }
        }
        .animation(.easeInOut(duration: 0.25), value: thumbnailImage != nil)
        .onAppear { if isVideo { loadVideoPoster() } else { loadThumbnail() } }
    }

    /// Video bubble: poster (sender) or blurhash preview (receiver) + play + duration.
    /// Never downloads the full video — playback happens on tap in the gallery.
    private var videoCell: some View {
        let poster = thumbnailImage ?? blurPreview
        let isUploading = isPlaceholder && message.deliveryStatus == .sending
        return ZStack {
            if let poster {
                Image(platformImage: poster)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 320)
            } else {
                Rectangle().fill(Color.CT.bgMsg)
                    .frame(width: previewSize.width, height: previewSize.height)
            }
            if !isUploading { videoPlayGlyph }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if !isUploading, let d = itemDict["duration"] as? Double, d > 0 { durationBadge(d) }
        }
        .overlay(alignment: .bottom) { if isUploading { uploadingBadge } }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2)
        )
        .onTapGesture { if !isPlaceholder { onTap() } }
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
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: progress)
    }

    private var videoPlayGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 22))
            .foregroundColor(.white)
            .frame(width: 54, height: 54)
            .background(.black.opacity(0.45), in: Circle())
    }

    private func durationBadge(_ seconds: Double) -> some View {
        Text(formatMediaDuration(seconds))
            .font(CTFont.regular(11)).foregroundColor(.white).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Display size for the loading preview, from the descriptor's pixel dimensions
    /// (so the blurred preview matches the final image's shape), capped to the bubble.
    private var previewSize: CGSize {
        let maxW: CGFloat = 260, maxH: CGFloat = 320
        guard let w = (itemDict["width"] as? Int).map(CGFloat.init), w > 0,
              let h = (itemDict["height"] as? Int).map(CGFloat.init), h > 0 else {
            return CGSize(width: 200, height: 200)
        }
        let scale = min(maxW / w, maxH / h, 1)
        return CGSize(width: max(120, w * scale), height: max(120, h * scale))
    }

    private var errorPlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: 200, height: 200)
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
            .fill(Color.CT.bgMsg).frame(width: 200, height: 200)
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
        hasReceivedBytes = false
        downloadProgress = 0

        // Decode the transmitted BlurHash into a blurred preview shown while downloading.
        if blurPreview == nil, let bh = itemDict["blurhash"] as? String, !bh.isEmpty {
            blurPreview = BlurHash.decode(bh, size: CGSize(width: 32, height: 32))
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
            if thumbnailImage == nil { loadError = "Missing media info" }
            return
        }
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
}

// MARK: - Multi-image grid (2+ photos)

private struct MediaGridView: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let isPlaceholder: Bool
    let isSelected: Bool
    let onTapItem: (Int) -> Void

    private let albumWidth: CGFloat = 244
    private let spacing: CGFloat = 2

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
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.CT.accent : Color.clear, lineWidth: 2))
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

    private var itemDict: [String: Any] {
        mediaContent.mediaItems.indices.contains(itemIndex) ? mediaContent.mediaItems[itemIndex] : [:]
    }

    private var isVideo: Bool {
        (itemDict["mediaType"] as? String)?.hasPrefix("video/") == true
    }

    var body: some View {
        ZStack {
            if let img = thumbnailImage {
                Image(platformImage: img).resizable().scaledToFill()
            } else if isVideo, let preview = blurPreview {
                Image(platformImage: preview).resizable().scaledToFill()
            } else {
                if isLoading {
                    loadingPlaceholder
                } else {
                    idlePlaceholder
                }
            }

            let isUploading = isPlaceholder && message.deliveryStatus == .sending
            if isVideo && !isUploading {
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45), in: Circle())
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
                if !isPlaceholder { onTap() }
            } else if loadFailed {
                loadThumbnail(forceRetry: true)
            } else if !isPlaceholder, thumbnailImage != nil {
                onTap()
            }
        }
        .onAppear { if isVideo { loadVideoPoster() } else { loadThumbnail() } }
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
