//
//  MediaContentTypes.swift
//  Construct Messenger
//
//  Shared types for media and file message content parsing.
//  Included in both the iOS/Catalyst and native macOS Desktop targets.
//

import Foundation

// MARK: - Media message

struct MediaMessageContent {
    let caption: String
    let media: [String: Any]
}

/// Parses a message's `decryptedContent` string into `MediaMessageContent`.
/// Returns nil if the content is not a media-type JSON payload.
func parseMediaContent(from content: String?) -> MediaMessageContent? {
    guard let content,
          let data = content.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == "media",
          let mediaArray = json["media"] as? [[String: Any]] else {
        return nil
    }
    let firstMedia = mediaArray.first ?? [:]
    return MediaMessageContent(
        caption: json["caption"] as? String ?? "",
        media: firstMedia
    )
}

// MARK: - File message

struct FileMessageContent: Codable {
    let type: String
    let caption: String
    let files: [FileEntry]

    struct FileEntry: Codable {
        let mediaId: String
        let mediaUrl: String
        let mediaKey: String
        let mediaType: String
        let size: Int
        let hash: String
        let filename: String
        let compressed: Bool
    }
}
