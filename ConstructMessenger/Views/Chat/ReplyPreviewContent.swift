//
//  ReplyPreviewContent.swift
//  Construct Messenger
//
//  Renders the reply-to context in both the compose bar (MessageInputView)
//  and the in-bubble reply indicator (MessageBubble).
//  Detects media / file JSON and shows a thumbnail or icon instead of raw JSON.

import SwiftUI
import Combine

private enum ReplyPreviewLayout {
    static let spacing: CGFloat = 6
    static let iconSize: CGFloat = 14
    static let labelSize: CGFloat = 12
}

struct ReplyPreviewContent: View {
    /// The content string — `replyToContent` stored on the replying message,
    /// or `decryptedContent` of the original message when composing.
    let content: String?
    /// Message ID used to look up a local thumbnail via MediaManager.
    /// Pass `message.replyToMessageId` (bubble) or `replyingTo.id` (input bar).
    let messageId: String?
    /// Side length of the thumbnail square (36 for input bar, 40 for bubble).
    let thumbnailSize: CGFloat
    /// Number of text lines allowed (1 for input bar, 2 for bubble).
    let lineLimit: Int

    @State private var thumbnail: PlatformImage? = nil

    private var preview: ReplyPreviewPayload? { ReplyPreviewPayload.fromStoredContent(content) }
    private var mediaContent: MediaMessageContent? { parseMediaContent(from: content) }
    private var firstMediaItem: [String: Any]? { mediaContent?.mediaItems.first ?? mediaContent?.media }

    @ViewBuilder
    var body: some View {
        if let preview, preview.kind == .image || preview.kind == .video || preview.kind == .animated {
            HStack(spacing: ReplyPreviewLayout.spacing) {
                thumbnailView
                Text(preview.localizedDisplayText)
                    .font(CTFont.regular(ReplyPreviewLayout.labelSize))
                    .foregroundColor(Color.CT.textDim)
                    .lineLimit(lineLimit)
            }
            .onAppear { loadThumbnailIfNeeded() }
        } else if let preview, preview.kind != .text {
            HStack(spacing: ReplyPreviewLayout.spacing) {
                Image(systemName: symbolName(for: preview.kind))
                    .font(.system(size: ReplyPreviewLayout.iconSize, weight: .regular))
                    .foregroundColor(Color.CT.textDim)
                    .lineLimit(1).fixedSize()
                Text(preview.localizedDisplayText)
                    .font(CTFont.regular(ReplyPreviewLayout.labelSize))
                    .foregroundColor(Color.CT.textDim)
                    .lineLimit(lineLimit)
            }
        } else {
            Text(preview?.localizedDisplayText ?? "")
                .font(CTFont.regular(ReplyPreviewLayout.labelSize))
                .foregroundColor(Color.CT.textDim)
                .lineLimit(lineLimit)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let img = thumbnail {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.CT.bgMsg
                    .overlay(
                        Image(systemName: preview?.kind == .video ? "video" : "photo")
                            .font(.system(size: ReplyPreviewLayout.iconSize, weight: .regular))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(1).fixedSize()
                    )
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(Rectangle())
    }

    private func symbolName(for kind: ReplyPreviewPayload.Kind) -> String {
        switch kind {
        case .audio: return "waveform"
        case .file: return "doc"
        case .profile: return "person.crop.rectangle"
        case .sticker: return "face.smiling"
        case .unknownAttachment: return "paperclip"
        case .image, .animated: return "photo"
        case .video: return "video"
        case .text: return "text.alignleft"
        }
    }

    private func loadThumbnailIfNeeded() {
        guard thumbnail == nil else { return }
        Task { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        if let img = cachedThumbnailImage() {
            thumbnail = img
            return
        }

        guard let item = firstMediaItem,
              let mediaId = item["mediaId"] as? String,
              let mediaUrl = item["mediaUrl"] as? String,
              let mediaKeyStr = item["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr),
              let id = messageId
        else { return }

        do {
            let data = try await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: mediaId,
                mediaUrl: mediaUrl,
                mediaKey: mediaKey
            )

            let mediaType = (item["mediaType"] as? String ?? "").lowercased()
            if mediaType.hasPrefix("video/") {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("reply-preview-\(mediaId).mp4")
                try? data.write(to: tempURL, options: .atomic)
                guard let posterData = try? await MediaOptimizer.generateVideoThumbnail(from: tempURL),
                      let poster = PlatformImage(data: posterData) else { return }
                MediaManager.shared.storeThumbnail(posterData, for: id)
                MediaImageCache.shared.storePoster(poster, for: id)
                thumbnail = poster
                return
            }

            guard let image = PlatformImage(data: data) else { return }
            // `thumbnailSize * 3` is 120px — a reply bar is 40pt. This went into the full-resolution
            // compartment until 2026-08-11, which is what "save to Photos" and "share" write out:
            // replying to a photo quietly downgraded that photo's saved copy to 120px.
            // (`generateThumbnail(from:maxSize:)` ignores maxSize — MediaOptimizer owns the budget —
            // so the persisted copy below is the normal 320px one, not 120px.)
            let preview = MediaManager.shared.generateThumbnailImage(from: image, maxSize: thumbnailSize * 3)
            if let previewData = MediaManager.shared.generateThumbnail(from: preview, maxSize: thumbnailSize * 3) {
                MediaManager.shared.storeThumbnail(previewData, for: id)
            }
            MediaImageCache.shared.storePoster(preview, for: id)
            thumbnail = preview
        } catch {
            Log.debug("Reply preview thumbnail load failed: \(error)", category: "ReplyPreview")
        }
    }

    @MainActor
    private func cachedThumbnailImage() -> PlatformImage? {
        if let id = messageId,
           let data = MediaManager.shared.retrieveThumbnail(for: id),
           let img = PlatformImage.platformImage(data: data) {
            return img
        }
        if let id = messageId,
           let cached = MediaImageCache.shared.paintable(for: id) {
            return cached
        }
        return nil
    }
}
