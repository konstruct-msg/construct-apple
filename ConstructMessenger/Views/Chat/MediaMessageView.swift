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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if isUploading { uploadingBadge }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
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
                .font(.caption2.weight(.medium)).foregroundColor(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55)).clipShape(Capsule())
        .padding(.bottom, 8)
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.2)).frame(width: 200, height: 200)
            .overlay {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.5).tint(Color.blue)
                    if downloadProgress > 0 && downloadProgress < 1 {
                        Text("\(Int(downloadProgress * 100))%").font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(LocalizedStringKey("loading")).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
    }

    private var errorPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.2)).frame(width: 200, height: 200)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40)).foregroundColor(.orange)
                    Text(LocalizedStringKey("failed_to_load")).font(.caption).foregroundColor(.secondary)
                    Button { loadThumbnail() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(LocalizedStringKey("retry"))
                        }
                        .font(.caption).foregroundColor(.blue)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1)).cornerRadius(8)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2))
    }

    private var emptyPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.2)).frame(width: 200, height: 200)
            .overlay { Image(systemName: "photo").font(.system(size: 40)).foregroundColor(.gray) }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2))
    }

    // MARK: Load logic

    private func loadThumbnail() {
        loadError = nil
        if message.isSentByMe {
            if let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
               let img = PlatformImage(data: data)
            {
                thumbnailImage = img
                MediaImageCache.shared.store(img, for: message.id, at: itemIndex)
                return
            }
        }
        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyBase64 = itemDict["mediaKey"] as? String
        else {
            loadError = "Missing media info"
            return
        }
        isLoading = true
        downloadProgress = 0.1
        Task {
            do {
                let imageData = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId,
                    mediaUrl: mediaUrl,
                    mediaKeyBase64: mediaKeyBase64
                )
                await MainActor.run { downloadProgress = 0.9 }
                guard let image = PlatformImage(data: imageData) else {
                    await MainActor.run {
                        isLoading = false
                        loadError = "Invalid image data"
                        downloadProgress = 0
                    }
                    return
                }
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
                    loadError = error.localizedDescription
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

    private let gridSize: CGFloat = 120
    private let spacing: CGFloat = 3
    private let maxVisible = 4

    private var itemCount: Int { mediaContent.mediaItems.count }
    private var visibleCount: Int { min(itemCount, maxVisible) }

    var body: some View {
        let columns = [
            GridItem(.fixed(gridSize), spacing: spacing),
            GridItem(.fixed(gridSize), spacing: spacing),
        ]
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(0..<visibleCount, id: \.self) { index in
                GridCell(
                    mediaContent: mediaContent,
                    message: message,
                    itemIndex: index,
                    isPlaceholder: isPlaceholder,
                    extraCount: index == maxVisible - 1 ? max(0, itemCount - maxVisible) : 0,
                    onTap: { onTapItem(index) }
                )
                .frame(width: gridSize, height: gridSize)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: gridSize * 2 + spacing)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2))
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
                Color.gray.opacity(0.2)
                Image(systemName: "photo").foregroundColor(.gray)
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
        if message.isSentByMe {
            if let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
               let img = PlatformImage(data: data)
            {
                thumbnailImage = img
                MediaImageCache.shared.store(img, for: message.id, at: itemIndex)
                return
            }
        }
        guard let mediaId = itemDict["mediaId"] as? String,
              let mediaUrl = itemDict["mediaUrl"] as? String,
              let mediaKeyBase64 = itemDict["mediaKey"] as? String
        else { return }
        Task {
            guard let imageData = try? await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: mediaId,
                mediaUrl: mediaUrl,
                mediaKeyBase64: mediaKeyBase64
            ),
                let image = PlatformImage(data: imageData)
            else { return }
            let thumb = MediaManager.shared.generateThumbnailImage(from: image, maxSize: 200)
            await MainActor.run {
                MediaImageCache.shared.store(image, for: message.id, at: itemIndex)
                thumbnailImage = thumb
            }
        }
    }
}

