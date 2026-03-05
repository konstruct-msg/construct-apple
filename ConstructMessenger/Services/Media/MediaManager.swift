//
//  MediaManager.swift
//  Construct Messenger
//
//  Unified manager for all media operations (upload, download, thumbnails)
//  Extracted from MediaUploadService + ChatsViewModel + ChatViewModel
//  Created on 2026-01-31 (Phase 1.2 Refactoring)
//

import Foundation
import UIKit
import CryptoKit

/// Unified manager for all media operations
@MainActor
class MediaManager {
    
    // MARK: - Singleton
    
    static let shared = MediaManager()
    
    // MARK: - In-Memory Cache
    
    /// Cache for downloaded/decrypted media to avoid re-downloading
    private var mediaCache: [String: Data] = [:]
    private let maxCacheSize = 50 * 1024 * 1024  // 50 MB
    private var currentCacheSize = 0
    
    private init() {}
    
    // MARK: - Upload Operations
    
    /// Upload image for chat message
    /// - Parameters:
    ///   - image: UIImage to upload
    ///   - recipientId: User ID to encrypt media key for
    /// - Returns: Media metadata for message content
    func uploadImage(_ image: UIImage, for recipientId: String) async throws -> MediaMessageData {
        Log.info("📤 Uploading image for recipient: \(recipientId)", category: "MediaManager")
        
        // Optimize before upload (resize + compress + strip metadata)
        let optimized = try MediaOptimizer.optimizeImage(image)
        
        // Upload optimized data
        let uploadResult = try await MediaServiceClient.shared.uploadData(
                optimized.data,
                mimeType: optimized.metadata.mimeType
            )
        Log.info("✅ Image uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        
        // ✅ Use raw base64 key - entire message will be encrypted via Double Ratchet
        // No need for double encryption of the media key
        let mediaKeyBase64 = uploadResult.encryptionKey.base64EncodedString()
        
        // Extract image dimensions
        let width = optimized.metadata.width
        let height = optimized.metadata.height
        let thumbnailBase64 = optimized.thumbnail?.base64EncodedString()
        
        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: mediaKeyBase64,
            mediaType: uploadResult.mimeType,
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: nil,
            thumbnail: thumbnailBase64,
            hash: uploadResult.hash
        )
    }
    
    /// Upload avatar image (profile sharing)
    /// - Parameter image: Avatar image to upload
    /// - Returns: Avatar upload result with raw encryption key
    func uploadAvatar(_ image: UIImage) async throws -> AvatarUploadResult {
        Log.info("📤 Uploading avatar", category: "MediaManager")
        
        // Optimize avatar (resize + compress) using ImageHelper
        guard let avatarData = ImageHelper.prepareAvatarImage(image) else {
            throw MediaManagerError.optimizationFailed
        }
        
        let uploadResult = try await MediaServiceClient.shared.uploadData(
                avatarData,
                mimeType: "image/jpeg"
            )
        Log.info("✅ Avatar uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        
        // For avatars, return raw base64 key (not Double Ratchet encrypted)
        // The entire profile message will be encrypted with Double Ratchet
        let keyBase64 = uploadResult.encryptionKey.base64EncodedString()
        
        return AvatarUploadResult(
            mediaUrl: uploadResult.mediaUrl,
            encryptionKey: keyBase64,  // Raw base64 key
            mediaId: uploadResult.mediaId,
            hash: uploadResult.hash
        )
    }
    
    // MARK: - Download Operations
    
    /// Download and decrypt media from message
    /// - Parameters:
    ///   - mediaUrl: URL to download encrypted media from
    ///   - mediaKeyBase64: Raw AES key in base64 (already decrypted as part of message)
    /// - Returns: Decrypted media data
    func downloadAndDecryptMedia(mediaId: String, mediaUrl: String, mediaKeyBase64: String) async throws -> Data {
        // Check cache first
        let cacheKey = mediaId
        if let cachedData = mediaCache[cacheKey] {
            Log.debug("✅ Media cache hit for: \(mediaId.prefix(8))...", category: "MediaManager")
            return cachedData
        }
        
        Log.info("📥 Downloading media from: \(mediaUrl)", category: "MediaManager")
        Log.debug("   Media key (base64, first 20 chars): \(mediaKeyBase64.prefix(20))...", category: "MediaManager")
        
        // Decode raw AES key from base64
        guard let keyData = Data(base64Encoded: mediaKeyBase64) else {
            Log.error("❌ Invalid base64 media key", category: "MediaManager")
            throw MediaManagerError.invalidMediaKey
        }
        
        guard keyData.count == 32 else {
            Log.error("❌ Invalid media key size: \(keyData.count) (expected 32)", category: "MediaManager")
            throw MediaManagerError.invalidMediaKey
        }
        
        Log.debug("   Decoded media key: \(keyData.count) bytes", category: "MediaManager")
        
        let encryptedData = try await MediaServiceClient.shared.downloadEncryptedFile(mediaId: mediaId)
        Log.debug("   Downloaded encrypted data: \(encryptedData.count) bytes", category: "MediaManager")
        
        // Decrypt media using symmetric AES key
        Log.debug("   Calling CryptoManager.decryptMediaData...", category: "MediaManager")
        let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: keyData)
        
        Log.info("✅ Media decrypted: \(decryptedData.count) bytes", category: "MediaManager")
        
        // Store in cache if space available
        if currentCacheSize + decryptedData.count < maxCacheSize {
            mediaCache[cacheKey] = decryptedData
            currentCacheSize += decryptedData.count
            Log.debug("💾 Cached media (\(currentCacheSize / 1024)KB / \(maxCacheSize / 1024)KB)", category: "MediaManager")
        } else {
            Log.debug("⚠️ Cache full, not caching this media", category: "MediaManager")
        }
        
        return decryptedData
    }
    
    /// Clear media cache to free memory
    func clearCache() {
        mediaCache.removeAll()
        currentCacheSize = 0
        Log.info("🗑️ Media cache cleared", category: "MediaManager")
    }
    
    /// Download and decrypt avatar (profile sharing)
    /// - Parameters:
    ///   - mediaId: UUID of the media file
    ///   - mediaUrl: Download URL (used for logging only)
    ///   - mediaKeyBase64: Base64-encoded encryption key (raw AES key)
    /// - Returns: Decrypted avatar image data
    func downloadAndDecryptAvatar(mediaId: String, mediaUrl: String, mediaKeyBase64: String) async throws -> Data {
        Log.info("📥 Downloading avatar from: \(mediaUrl)", category: "MediaManager")
        
        guard let keyData = Data(base64Encoded: mediaKeyBase64) else {
            throw MediaManagerError.invalidMediaKey
        }
        
        let encryptedData = try await MediaServiceClient.shared.downloadEncryptedFile(mediaId: mediaId)
        
        let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: keyData)
        
        Log.info("✅ Avatar decrypted: \(decryptedData.count) bytes", category: "MediaManager")
        return decryptedData
    }
    
    // MARK: - Thumbnail Operations
    
    /// Generate thumbnail from UIImage
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    func generateThumbnail(from image: UIImage, maxSize: CGFloat = 250) -> Data? {
        Log.debug("🖼️ Generating thumbnail (maxSize: \(maxSize))", category: "MediaManager")
        
        do {
            let optimized = try MediaOptimizer.generateThumbnail(from: image)
            Log.debug("✅ Thumbnail generated: \(optimized.count) bytes", category: "MediaManager")
            return optimized
        } catch {
            Log.error("❌ Failed to generate thumbnail: \(error)", category: "MediaManager")
            return nil
        }
    }
    
    /// Generate thumbnail from Data
    /// - Parameters:
    ///   - data: Image data
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    func generateThumbnail(from data: Data, maxSize: CGFloat = 250) -> Data? {
        guard let image = UIImage(data: data) else {
            Log.error("❌ Failed to create UIImage from data", category: "MediaManager")
            return nil
        }
        
        return generateThumbnail(from: image, maxSize: maxSize)
    }
    
    /// Generate thumbnail with custom UIImage renderer (for MessageBubble compatibility)
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension
    /// - Returns: Thumbnail UIImage
    func generateThumbnailImage(from image: UIImage, maxSize: CGFloat) -> UIImage {
        let size = image.size
        let scale: CGFloat
        
        if size.width > size.height {
            scale = maxSize / size.width
        } else {
            scale = maxSize / size.height
        }
        
        let thumbnailSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }
    }
    
    // MARK: - Thumbnail Storage (UserDefaults - temporary solution)
    
    /// Store thumbnail locally for message
    /// - Parameters:
    ///   - thumbnailData: Thumbnail image data
    ///   - messageId: Message ID to associate with
    func storeThumbnail(_ thumbnailData: Data, for messageId: String) {
        UserDefaults.standard.set(thumbnailData, forKey: "message_thumbnail_\(messageId)")
        Log.debug("💾 Stored thumbnail for message: \(messageId)", category: "MediaManager")
    }
    
    /// Retrieve stored thumbnail for message
    /// - Parameter messageId: Message ID
    /// - Returns: Thumbnail data if exists
    func retrieveThumbnail(for messageId: String) -> Data? {
        return UserDefaults.standard.data(forKey: "message_thumbnail_\(messageId)")
    }
    
    /// Remove stored thumbnail for message
    /// - Parameter messageId: Message ID
    func removeThumbnail(for messageId: String) {
        UserDefaults.standard.removeObject(forKey: "message_thumbnail_\(messageId)")
    }
}

// MARK: - Supporting Types

/// Result of avatar upload
struct AvatarUploadResult {
    let mediaUrl: String
    let encryptionKey: String  // Raw base64 key (not Double Ratchet encrypted)
    let mediaId: String
    let hash: String
}

/// Media manager errors
enum MediaManagerError: LocalizedError {
    case invalidMediaKey
    case decryptionFailed
    case optimizationFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidMediaKey:
            return "Invalid media encryption key"
        case .decryptionFailed:
            return "Failed to decrypt media"
        case .optimizationFailed:
            return "Failed to optimize image"
        }
    }
}
