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
    let media: [String: Any]      // first item — kept for backward compat with single-image callers
    let mediaItems: [[String: Any]]  // all items (1 or more)

    init(caption: String, mediaItems: [[String: Any]]) {
        self.caption = caption
        self.mediaItems = mediaItems
        self.media = mediaItems.first ?? [:]
    }
}

/// Parses a message's `decryptedContent` string into `MediaMessageContent`.
/// Returns nil if the content is not a media-type JSON payload.
func parseMediaContent(from content: String?) -> MediaMessageContent? {
    guard let content,
          let data = content.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == "media",
          let mediaArray = json["media"] as? [[String: Any]],
          !mediaArray.isEmpty else {
        return nil
    }
    return MediaMessageContent(
        caption: json["caption"] as? String ?? "",
        mediaItems: mediaArray
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

// MARK: - Voice message

struct VoiceMessageContent: Codable {
    let type: String           // always "voice"
    let mediaId: String
    let mediaUrl: String
    let mediaKey: String       // base64 AES-256-GCM key (same encryption as image/file media)
    let mediaType: String      // "audio/m4a"
    let size: Int
    let duration: TimeInterval
    let waveform: [Float]      // ~100 normalized amplitude samples (0.0–1.0) sampled during recording
    let hash: String
}

/// Parses a message's `decryptedContent` into `VoiceMessageContent`.
/// Returns nil if the content is not a voice-type JSON payload.
func parseVoiceContent(from content: String?) -> VoiceMessageContent? {
    guard let content,
          let data = content.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String,
          type == "voice"
    else { return nil }
    return try? JSONDecoder().decode(VoiceMessageContent.self, from: data)
}
