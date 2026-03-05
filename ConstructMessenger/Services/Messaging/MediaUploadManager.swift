import Foundation
import UIKit
import os.log

/// Manages media message upload, encoding, and sending
@MainActor
class MediaUploadManager {
    
    // MARK: - Media Upload Result
    
    struct MediaUploadResult {
        let messageContent: String
        let thumbnails: [Data]
    }
    
    // MARK: - Media Message Sending
    
    /// Uploads media and builds message content
    /// - Parameters:
    ///   - images: Array of images to send
    ///   - caption: Optional text caption
    ///   - recipientId: ID of the recipient user
    /// - Returns: MediaUploadResult with content and thumbnails
    /// - Throws: MediaUploadError if upload fails
    func uploadMediaAndBuildContent(
        images: [UIImage],
        caption: String,
        recipientId: String
    ) async throws -> MediaUploadResult {
        var mediaDataList: [MediaMessageData] = []
        var thumbnails: [Data] = []
        
        // Upload each image using MediaManager
        for (index, image) in images.enumerated() {
            Log.info("📤 Uploading image \(index + 1)/\(images.count)", category: "MediaUploadManager")
            
            // Generate thumbnail before upload (for local storage on sender side)
            if let thumbnail = MediaManager.shared.generateThumbnail(from: image) {
                thumbnails.append(thumbnail)
                Log.debug("📸 Generated thumbnail: \(thumbnail.count) bytes", category: "MediaUploadManager")
            }
            
            // Upload via MediaManager
            let mediaData = try await MediaManager.shared.uploadImage(image, for: recipientId)
            mediaDataList.append(mediaData)
            
            Log.info("✅ Image \(index + 1) uploaded: \(mediaData.mediaId)", category: "MediaUploadManager")
        }
        
        // Build message content with media references
        let messageContent = buildMediaMessageContent(
            caption: caption,
            mediaList: mediaDataList
        )
        
        return MediaUploadResult(messageContent: messageContent, thumbnails: thumbnails)
    }
    
    // MARK: - Media Content Builder
    
    /// Builds JSON content for media message
    /// - Parameters:
    ///   - caption: Text caption
    ///   - mediaList: List of uploaded media data
    /// - Returns: JSON string for message content
    private func buildMediaMessageContent(caption: String, mediaList: [MediaMessageData]) -> String {
        // Build JSON content for media message
        // Format: {"type":"media","caption":"...","media":[...]}
        // ✅ FIX: Remove thumbnails from JSON to avoid exceeding 64KB limit
        // Thumbnails can be generated client-side from downloaded media
        struct MediaContent: Codable {
            let type: String
            let caption: String
            let media: [MediaMessageDataWithoutThumbnail]
        }
        
        // MediaMessageData without thumbnail to reduce JSON size
        struct MediaMessageDataWithoutThumbnail: Codable {
            let mediaId: String
            let mediaUrl: String
            let mediaKey: String
            let mediaType: String
            let size: Int
            let width: Int?
            let height: Int?
            let duration: TimeInterval?
            let hash: String
            // thumbnail excluded to keep JSON under 64KB
        }
        
        let mediaWithoutThumbnails = mediaList.map { media in
            MediaMessageDataWithoutThumbnail(
                mediaId: media.mediaId,
                mediaUrl: media.mediaUrl,
                mediaKey: media.mediaKey,
                mediaType: media.mediaType,
                size: media.size,
                width: media.width,
                height: media.height,
                duration: media.duration,
                hash: media.hash
            )
        }
        
        let content = MediaContent(
            type: "media",
            caption: caption,
            media: mediaWithoutThumbnails
        )
        
        let encoder = JSONEncoder()
        // ✅ Use camelCase for consistency with messaging-service API
        
        guard let jsonData = try? encoder.encode(content),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            Log.error("❌ Failed to encode media message content", category: "MediaUploadManager")
            return caption
        }
        
        // Debug: Log the actual JSON we're creating
        Log.debug("📋 Created media JSON (\(jsonString.count) chars): \(jsonString.prefix(200))...", category: "MediaUploadManager")
        
        // ✅ Check JSON size before sending
        let jsonSize = jsonString.utf8.count
        let maxSize = 64 * 1024 // 64KB limit
        if jsonSize > maxSize {
            Log.error("❌ Media message JSON too large: \(jsonSize) bytes (max \(maxSize))", category: "MediaUploadManager")
            // Try without some optional fields
            let minimalMedia = mediaWithoutThumbnails.map { media in
                MediaMessageDataWithoutThumbnail(
                    mediaId: media.mediaId,
                    mediaUrl: media.mediaUrl,
                    mediaKey: media.mediaKey,
                    mediaType: media.mediaType,
                    size: media.size,
                    width: nil,
                    height: nil,
                    duration: nil,
                    hash: media.hash
                )
            }
            
            let minimalContent = MediaContent(
                type: "media",
                caption: caption.prefix(100).description, // Truncate caption if needed
                media: minimalMedia
            )
            
            if let minimalJsonData = try? encoder.encode(minimalContent),
               let minimalJsonString = String(data: minimalJsonData, encoding: .utf8) {
                Log.info("✅ Using minimal media JSON: \(minimalJsonString.utf8.count) bytes", category: "MediaUploadManager")
                return minimalJsonString
            }
        }
        
        return jsonString
    }
}
