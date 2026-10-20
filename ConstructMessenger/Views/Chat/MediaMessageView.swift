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
enum MediaPreviewLayout {
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
    let message: TranscriptRow
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
            .font(CTFont.message(ChatUIConstants.Typography.messageTextSize))
            .foregroundColor(Color.CT.text)
            .frame(maxWidth: MediaPreviewLayout.maxWidth, alignment: .leading)
            // Captions are message content. They wrap to their intrinsic height instead of
            // accepting a compressed one-line proposal from the surrounding transcript row.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, ChatUIConstants.Media.captionTopPadding)
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

extension View {
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

