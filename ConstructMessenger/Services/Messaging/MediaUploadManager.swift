import Foundation
#if canImport(UIKit)
import UIKit
#endif
import os.log

/// Manages media message upload, encoding, and sending
@MainActor
class MediaUploadManager {
    
    // MARK: - Media Upload Result
    
    struct MediaUploadResult {
        let messageContent: String          // local JSON (for display + multi-device sync)
        let mediaList: [MediaMessageData]    // for building the binary wire proto (.mediaAlbum)
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
    /// Aggregates per-item upload fractions into one overall album fraction.
    private actor ProgressAggregator {
        private var fractions: [Double]
        init(count: Int) { fractions = Array(repeating: 0, count: max(count, 1)) }
        func update(index: Int, fraction: Double) -> Double {
            if fractions.indices.contains(index) { fractions[index] = fraction }
            return fractions.reduce(0, +) / Double(fractions.count)
        }
    }

    /// - Parameter onProgress: overall album upload fraction (0.0…1.0), reported as items
    ///   upload concurrently. Called off the main actor — marshal before touching UI.
    func uploadMediaAndBuildContent(
        attachments: [MediaAttachment],
        caption: String,
        recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaUploadResult {
        let aggregator = onProgress != nil ? ProgressAggregator(count: attachments.count) : nil
        // Local thumbnails for the sender placeholder (per item, in order).
        let thumbnails: [Data] = attachments.compactMap { att in
            att.displayImage.flatMap { MediaManager.shared.generateThumbnail(from: $0) }
        }

        // Upload with bounded concurrency so large albums (up to 99) overlap their I/O
        // without unbounded memory/connections. Order is preserved across batches.
        let maxConcurrent = 4
        var mediaDataList: [MediaMessageData] = []
        mediaDataList.reserveCapacity(attachments.count)

        var index = 0
        while index < attachments.count {
            let end = min(index + maxConcurrent, attachments.count)
            let base = index
            let batch = Array(attachments[index..<end])
            Log.info("Uploading album batch \(base + 1)…\(end) of \(attachments.count)", category: "MediaUploadManager")

            let uploaded: [(Int, MediaMessageData)] = try await withThrowingTaskGroup(
                of: (Int, MediaMessageData).self
            ) { group in
                for (offset, attachment) in batch.enumerated() {
                    let itemIndex = base + offset
                    group.addTask {
                        let itemProgress: (@Sendable (Double) -> Void)? = aggregator.map { agg in
                            { @Sendable fraction in
                                Task {
                                    let overall = await agg.update(index: itemIndex, fraction: fraction)
                                    onProgress?(overall)
                                }
                            }
                        }
                        let data = try await MediaManager.shared.uploadImage(
                            attachment, for: recipientId, onProgress: itemProgress)
                        return (itemIndex, data)
                    }
                }
                var acc: [(Int, MediaMessageData)] = []
                for try await pair in group { acc.append(pair) }
                return acc
            }
            mediaDataList.append(contentsOf: uploaded.sorted { $0.0 < $1.0 }.map { $0.1 })
            index = end
        }
        
        // Build message content with media references
        let messageContent = buildMediaMessageContent(
            caption: caption,
            mediaList: mediaDataList
        )
        
        return MediaUploadResult(messageContent: messageContent, mediaList: mediaDataList, thumbnails: thumbnails)
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
        // Remove thumbnails from JSON to avoid exceeding 64KB limit
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
            let mediaKey: Data
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
        // Use camelCase for consistency with messaging-service API
        
        guard let jsonData = try? encoder.encode(content),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            Log.error("Failed to encode media message content", category: "MediaUploadManager")
            return caption
        }
        
        // Debug: Log the actual JSON we're creating
        Log.debug("Created media JSON (\(jsonString.count) chars): \(jsonString.prefix(200))...", category: "MediaUploadManager")
        
        // Check JSON size before sending
        let jsonSize = jsonString.utf8.count
        let maxSize = 64 * 1024 // 64KB limit
        if jsonSize > maxSize {
            Log.error("Media message JSON too large: \(jsonSize) bytes (max \(maxSize))", category: "MediaUploadManager")
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
                Log.info("Using minimal media JSON: \(minimalJsonString.utf8.count) bytes", category: "MediaUploadManager")
                return minimalJsonString
            }
        }
        
        return jsonString
    }

    // MARK: - File Upload

    struct FileUploadResult {
        let messageContent: String
    }

    /// Uploads file attachments and builds a `{"type":"file",...}` message JSON.
    /// Text-based files are ZLIB-compressed before AES encryption if beneficial.
    func uploadFilesAndBuildContent(urls: [URL], caption: String) async throws -> FileUploadResult {
        var fileDataList: [FileMessageEntry] = []

        for url in urls {
            Log.info("Uploading file: \(url.lastPathComponent)", category: "MediaUploadManager")
            let mediaData = try await MediaManager.shared.uploadFile(url)
            fileDataList.append(FileMessageEntry(
                mediaId: mediaData.mediaId,
                mediaUrl: mediaData.mediaUrl,
                mediaKey: mediaData.mediaKey,
                mediaType: mediaData.mediaType,
                size: mediaData.size,
                hash: mediaData.hash,
                filename: mediaData.filename ?? url.lastPathComponent,
                compressed: mediaData.compressed ?? false
            ))
        }

        let content = FileMessageContent(type: "file", caption: caption, files: fileDataList)
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(content),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MediaUploadError.uploadFailed("Failed to encode file message JSON")
        }
        return FileUploadResult(messageContent: jsonString)
    }

    private struct FileMessageContent: Codable {
        let type: String
        let caption: String
        let files: [FileMessageEntry]
    }

    private struct FileMessageEntry: Codable {
        let mediaId: String
        let mediaUrl: String
        let mediaKey: Data
        let mediaType: String
        let size: Int
        let hash: String
        let filename: String
        let compressed: Bool
    }
}
