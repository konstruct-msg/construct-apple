//
//  MediaMessageView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

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

    private var itemDict: [String: Any] {
        mediaContent.mediaItems.indices.contains(itemIndex)
            ? mediaContent.mediaItems[itemIndex]
            : mediaContent.media
    }

    var body: some View {
        Group {
            if let thumbnail = thumbnailImage {
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
        .onAppear { loadThumbnail() }
    }

    // MARK: Placeholder views

    private var uploadingBadge: some View {
        HStack(spacing: 5) {
            ProgressView().scaleEffect(0.75).tint(.white)
            Text(LocalizedStringKey("uploading"))
                .font(CTFont.regular(11)).foregroundColor(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55))
        .padding(.bottom, 8)
    }

    private var loadingPlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: 200, height: 200)
            .overlay {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.5).tint(Color.CT.accent)
                    if downloadProgress > 0 && downloadProgress < 1 {
                        Text("\(Int(downloadProgress * 100))%").font(CTFont.regular(11)).foregroundColor(Color.CT.textDim)
                    } else {
                        Text(LocalizedStringKey("loading")).font(CTFont.regular(11)).foregroundColor(Color.CT.textDim)
                    }
                }
            }
    }

    private var errorPlaceholder: some View {
        Rectangle()
            .fill(Color.CT.bgMsg).frame(width: 200, height: 200)
            .overlay {
                VStack(spacing: 12) {
                    Text("[!]")
                        .font(CTFont.bold(36)).foregroundColor(.orange)
                        .lineLimit(1).fixedSize()
                    Text(LocalizedStringKey("failed_to_load")).font(CTFont.regular(11)).foregroundColor(Color.CT.textDim)
                    Button { loadThumbnail() } label: {
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

    private func loadThumbnail() {
        if thumbnailImage != nil || isLoading { return }
        loadError = nil

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
        if thumbnailImage == nil { isLoading = true; downloadProgress = 0.02 }
        // Real byte-level progress: encrypted total comes from the descriptor `size`.
        let total = Double((itemDict["size"] as? Int) ?? 0)
        let onProgress: @Sendable (Int64) -> Void = { received in
            guard total > 0 else { return }
            // Reserve the top 10% for the decrypt + thumbnail step below.
            let frac = min(0.9, Double(received) / total)
            Task { @MainActor in if isLoading { downloadProgress = frac } }
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
                    downloadProgress = 1.0
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    if thumbnailImage == nil { loadError = error.localizedDescription }
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
    private let maxVisible = 4

    private var itemCount: Int { mediaContent.mediaItems.count }
    private var visibleCount: Int { min(itemCount, maxVisible) }

    var body: some View {
        // Square-crop mosaic: 2 = two squares, 3 = big-left + 2 stacked right,
        // 4 = 2×2, 5+ = 2×2 with a "+N" overlay on the last tile. Outer corners are
        // rounded by clipping the whole album; inner tiles are square with 2px gaps.
        Group {
            switch visibleCount {
            case 2:  twoLayout
            case 3:  threeLayout
            default: fourLayout
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
        let extra = itemCount > maxVisible ? itemCount - maxVisible : 0
        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                tile(0, t, t)
                tile(1, t, t)
            }
            HStack(spacing: spacing) {
                tile(2, t, t)
                tile(3, t, t, extra: extra)
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

    private var itemDict: [String: Any] {
        mediaContent.mediaItems.indices.contains(itemIndex) ? mediaContent.mediaItems[itemIndex] : [:]
    }

    var body: some View {
        ZStack {
            if let img = thumbnailImage {
                Image(platformImage: img).resizable().scaledToFill()
            } else {
                Color.CT.bgMsg
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundColor(Color.CT.textDim)
            }

            if extraCount > 0 {
                Color.black.opacity(0.5)
                Text("+\(extraCount)")
                    .font(.title2.weight(.semibold)).foregroundColor(.white)
            }

            if isPlaceholder && message.deliveryStatus == .sending {
                Color.black.opacity(0.3)
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isPlaceholder { onTap() } }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        if thumbnailImage != nil { return }
        // Fast paint from a local thumbnail (sent), then upgrade to full via the cache.
        if message.isSentByMe,
           let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
           let img = PlatformImage(data: data) {
            thumbnailImage = img
        }
        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyStr = itemDict["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr)
        else { return }
        Task {
            guard let imageData = try? await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: mediaId,
                mediaUrl: mediaUrl,
                mediaKey: mediaKey
            ),
                let image = PlatformImage(data: imageData)
            else { return }
            // Full image → gallery cache; a 200px thumb keeps the tile light.
            let thumb = MediaManager.shared.generateThumbnailImage(from: image, maxSize: 200)
            await MainActor.run {
                MediaImageCache.shared.store(image, for: message.id, at: itemIndex)
                thumbnailImage = thumb
            }
        }
    }
}

