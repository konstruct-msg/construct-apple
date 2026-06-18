//
//  ReplyPreviewContent.swift
//  Construct Messenger
//
//  Renders the reply-to context in both the compose bar (MessageInputView)
//  and the in-bubble reply indicator (MessageBubble).
//  Detects media / file JSON and shows a thumbnail or icon instead of raw JSON.

import SwiftUI

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

    private var mediaContent: MediaMessageContent? { parseMediaContent(from: content) }

    private var fileContent: FileMessageContent? {
        guard let c = content,
              let data = c.data(using: .utf8),
              let json = try? JSONDecoder().decode(FileMessageContent.self, from: data),
              json.type == "file" else { return nil }
        return json
    }

    var body: some View {
        if mediaContent != nil {
            HStack(spacing: 6) {
                thumbnailView
                Text(mediaCaptionLabel)
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                    .lineLimit(1)
            }
            .onAppear { loadThumbnail() }
        } else if let fc = fileContent {
            HStack(spacing: 6) {
                Text(fileAscii(for: fc.files.first?.mediaType))
                    .font(CTFont.regular(14))
                    .foregroundColor(Color.CT.textDim)
                    .lineLimit(1).fixedSize()
                Text(fc.files.first?.filename ?? NSLocalizedString("file_attachment", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                    .lineLimit(1)
            }
        } else {
            Text(content ?? "")
                .font(CTFont.regular(12))
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
                        Image(systemName: "photo")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(1).fixedSize()
                    )
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(Rectangle())
    }

    private var mediaCaptionLabel: String {
        let caption = mediaContent?.caption ?? ""
        if !caption.isEmpty { return caption }
        let mediaType = mediaContent?.media["mediaType"] as? String ?? ""
        if mediaType.hasPrefix("video/") {
            return NSLocalizedString("video", comment: "")
        }
        return NSLocalizedString("photo", comment: "")
    }

    private func fileAscii(for mimeType: String?) -> String {
        guard let mime = mimeType else { return "[doc]" }
        if mime.hasPrefix("image/") { return "[img]" }
        if mime.hasPrefix("video/") { return "[vid]" }
        if mime.hasPrefix("audio/") { return "[♪]" }
        if mime.contains("pdf") { return "[pdf]" }
        return "[doc]"
    }

    @available(*, unavailable)
    private func fileIcon(for mimeType: String?) -> String { "" }

    private func loadThumbnail() {
        guard let id = messageId,
              let data = MediaManager.shared.retrieveThumbnail(for: id),
              let img = PlatformImage.platformImage(data: data) else { return }
        thumbnail = img
    }
}
