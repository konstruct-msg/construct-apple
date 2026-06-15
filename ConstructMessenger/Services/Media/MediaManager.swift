//
//  MediaManager.swift
//  Construct Messenger
//
//  Unified manager for all media operations (upload, download, thumbnails)
//  Extracted from MediaUploadService + ChatsViewModel + ChatViewModel
//  Created on 2026-01-31 (Phase 1.2 Refactoring)
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
import CoreGraphics
#endif
import CryptoKit
import UniformTypeIdentifiers
import GRPCCore

/// Unified manager for all media operations
@MainActor
class MediaManager {
    
    // MARK: - Singleton
    
    static let shared = MediaManager()
    
    // MARK: - UserDefaults Keys

    static let maxDiskCacheBytesKey = "media.maxDiskCacheBytes"
    static let evictAfterDaysKey = "media.evictAfterDays"
    /// Default quota: 1 GB (0 = unlimited)
    static let defaultMaxDiskCacheBytes: Int = 1_073_741_824

    // MARK: - In-Memory Cache
    
    /// Cache for downloaded/decrypted media to avoid re-downloading
    private var mediaCache: [String: Data] = [:]
    private let maxCacheSize = 50 * 1024 * 1024  // 50 MB
    private var currentCacheSize = 0

    // MARK: - Persistent Disk Cache

    /// Library/Caches/media/ — survives app updates, can be evicted by OS under disk pressure
    private let diskCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func diskCacheURL(for mediaId: String) -> URL {
        diskCacheDirectory.appendingPathComponent(mediaId)
    }

    private func saveToDiskcache(_ data: Data, mediaId: String) {
        let url = diskCacheURL(for: mediaId)
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDiskCache(mediaId: String) -> Data? {
        let url = diskCacheURL(for: mediaId)
        return try? Data(contentsOf: url)
    }

    // MARK: - Cache Management

    /// Total bytes used by the disk cache.
    func diskCacheSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Evict oldest files (by modification date) until cache is under quota.
    private func evictToQuota() {
        let maxBytes = UserDefaults.standard.object(forKey: Self.maxDiskCacheBytesKey) as? Int
            ?? Self.defaultMaxDiskCacheBytes
        guard maxBytes > 0 else { return } // 0 = unlimited

        var currentSize = diskCacheSize()
        guard currentSize > Int64(maxBytes) else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let sorted = files.sorted {
            let aDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate < bDate
        }

        for file in sorted {
            guard currentSize > Int64(maxBytes) else { break }
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: file)
            mediaCache.removeValue(forKey: file.lastPathComponent)
            currentSize -= size
            Log.debug("Evicted \(file.lastPathComponent.prefix(8))… (\(size / 1024)KB) — quota", category: "MediaManager")
        }
    }

    /// Evict files older than the configured number of days. Call on app foreground.
    func evictOldFiles() {
        let days = UserDefaults.standard.object(forKey: Self.evictAfterDaysKey) as? Int ?? 0
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        var count = 0
        for file in files {
            let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if mod < cutoff {
                try? FileManager.default.removeItem(at: file)
                mediaCache.removeValue(forKey: file.lastPathComponent)
                count += 1
            }
        }
        if count > 0 {
            Log.info("Evicted \(count) cached file(s) older than \(days) days", category: "MediaManager")
        }
    }
    
    private init() {}
    
    // MARK: - Upload Operations
    
    /// Upload image for chat message
    /// - Parameters:
    ///   - image: UIImage to upload
    ///   - recipientId: User ID to encrypt media key for
    /// - Returns: Media metadata for message content
    func uploadImage(_ attachment: MediaAttachment, for recipientId: String) async throws -> MediaMessageData {
        Log.info("Uploading image for recipient: \(recipientId) (quality=\(attachment.quality))", category: "MediaManager")

        // Phase 1a: behaviour-preserving — still optimize the display image regardless of
        // `quality`. Phase 1b will branch on `.original` to upload `attachment.originalData`.
        guard let image = attachment.displayImage ?? PlatformImage(data: attachment.originalData) else {
            throw MediaOptimizationError.conversionFailed
        }
        let optimized = try MediaOptimizer.optimizeImage(image)

        // Upload with 1 automatic retry on stream failure
        let uploadResult = try await Self.uploadWithRetry(data: optimized.data, mimeType: optimized.metadata.mimeType)
        Log.info("Image uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        
        let width = optimized.metadata.width
        let height = optimized.metadata.height

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: uploadResult.mimeType,
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: nil,
            thumbnail: optimized.thumbnail,
            hash: uploadResult.hash,
            filename: nil,
            compressed: false
        )
    }

    /// Uploads data with up to 2 automatic retries on transient gRPC/VEIL stream failures.
    /// Checks MediaSendCache first — identical plaintext within the 30-minute TTL window
    /// skips re-encryption and re-upload entirely.
    static func uploadWithRetry(data: Data, mimeType: String) async throws -> MediaServiceClient.UploadedMedia {
        // Cache hit: same plaintext already uploaded recently → reuse mediaId + AES key.
        // Safe: the key is carried inside the DR-encrypted message payload, so each
        // recipient still gets an independent encrypted envelope.
        if let cached = await MediaSendCache.shared.cachedUpload(for: data) {
            Log.info("Media send cache hit — reusing \(cached.mediaId)", category: "MediaManager")
            return cached
        }

        // .cancelled       → in-flight RPC killed when the persistent connection was torn down
        // .unavailable     → server/transport unreachable
        // .deadlineExceeded → upload timed out (large file on slow link)
        // .unknown         → gRPC-swift wraps Swift CancellationError from the transport as .unknown
        //                     when VEIL proxy restarts mid-stream (e.g. foreground wake)
        //                     log: unknown: "The transport threw an unexpected error." (cause: "CancellationError()")
        let retryableCodes: Set<RPCError.Code> = [.cancelled, .unavailable, .deadlineExceeded, .unknown]
        let delays: [UInt64] = NetworkTiming.Media.retryDelaysNs

        var lastError: Error?
        for delay in ([0] + delays.map { Optional($0) }) as [UInt64?] {
            do {
                if let ns = delay {
                    try await Task.sleep(nanoseconds: ns)
                }
                let result = try await MediaServiceClient.shared.uploadData(data, mimeType: mimeType)
                await MediaSendCache.shared.storeUpload(result, for: data)
                return result
            } catch let error as GRPCCore.RPCError where retryableCodes.contains(error.code) {
                lastError = error
                Log.info("Upload dropped (code=\(error.code)) — will retry", category: "MediaManager")
            }
        }
        throw lastError ?? RPCError(code: .unknown, message: "Upload failed: no error captured")
    }

    /// Downloads encrypted media data with up to 3 automatic retries on transient VEIL/stream failures.
    private static func downloadWithRetry(mediaId: String, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        let retryableCodes: Set<RPCError.Code> = [.cancelled, .unavailable, .deadlineExceeded, .unknown]
        // Generous delays: media downloads take 40 s to fail under DPI; VEIL needs ~1–2 s to come up.
        let delays: [UInt64] = [3_000_000_000, 8_000_000_000, 15_000_000_000]

        // Pre-flight: if DPI was confirmed this session and VEIL proxy isn't routing yet,
        // start it and wait before the first download attempt.  Without this, a long-running
        // streaming RPC goes direct and gets silently blocked by the middlebox.
        await ensureVEILForMedia()

        var lastError: Error?
        for (index, delay) in ([0] + delays.map { Optional($0) }).enumerated() {
            do {
                if let ns = delay {
                    try await Task.sleep(nanoseconds: ns)
                }
                return try await MediaServiceClient.shared.downloadEncryptedFile(mediaId: mediaId, onProgress: onProgress)
            } catch let error as GRPCCore.RPCError where retryableCodes.contains(error.code) {
                lastError = error
                Log.info("Download dropped (code=\(error.code)) — will retry", category: "MediaManager")
                // Start VEIL after any transient failure and wait for it to be ready so the
                // next attempt uses the obfs4 tunnel instead of the blocked direct path.
                if error.code == .unavailable || error.code == .deadlineExceeded {
                    await ensureVEILForMedia()
                }
                _ = index  // suppress unused-variable warning
            }
        }
        throw lastError ?? RPCError(code: .unknown, message: "Download failed: no error captured")
    }

    /// No-op: ConnectionLoop manages proxy lifecycle — readiness is guaranteed
    /// when veilProxyPort() is non-nil and GRPCCallExecutor routes through it.
    private static func ensureVEILForMedia() async {}

    /// Upload a file (document, PDF, etc.) for a chat message.
    /// Text-based files are transparently compressed with ZLIB before encryption if beneficial.
    /// - Parameter url: Security-scoped URL of the file
    /// - Returns: Media metadata for message content
    func uploadFile(_ url: URL) async throws -> MediaMessageData {
        let filename = url.lastPathComponent
        Log.info("Uploading file: \(filename)", category: "MediaManager")

        guard url.startAccessingSecurityScopedResource() else {
            throw MediaUploadError.uploadFailed("Cannot access file")
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let originalData = try Data(contentsOf: url)
        let detectedMimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        // Attempt ZLIB compression for compressible file types
        let (dataToUpload, compressed) = Self.compressIfBeneficial(originalData, mimeType: detectedMimeType)

        let uploadResult = try await Self.uploadWithRetry(data: dataToUpload, mimeType: detectedMimeType)
        Log.info("File uploaded: \(uploadResult.mediaId) compressed=\(compressed)", category: "MediaManager")

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: detectedMimeType,
            size: originalData.count,         // original size shown to user
            width: nil,
            height: nil,
            duration: nil,
            thumbnail: nil,
            hash: uploadResult.hash,
            filename: filename,
            compressed: compressed
        )
    }

    // MARK: - Voice message upload

    /// Upload an AAC/M4A voice recording.
    /// - Parameters:
    ///   - url: Local temp file URL (caller is responsible for deleting after this returns)
    ///   - duration: Recording duration in seconds
    ///   - waveform: ~100 normalized amplitude samples (0.0–1.0) for waveform display
    /// - Returns: `VoiceMessageContent` ready to be JSON-encoded as the message payload
    func uploadAudio(_ url: URL, duration: TimeInterval, waveform: [Float]) async throws -> VoiceMessageContent {
        Log.info("Uploading voice message (duration \(Int(duration))s)", category: "MediaManager")
        let data = try Data(contentsOf: url)
        let uploadResult = try await Self.uploadWithRetry(data: data, mimeType: "audio/m4a")
        Log.info("Voice uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        return VoiceMessageContent(
            type: "voice",
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: "audio/m4a",
            size: data.count,
            duration: duration,
            waveform: waveform,
            hash: uploadResult.hash
        )
    }

    // MARK: - Compression Helpers

    /// MIME types that are already compressed — re-compressing is wasteful
    private static let alreadyCompressedMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic",
        "video/mp4", "video/quicktime", "video/mpeg", "video/x-msvideo",
        "audio/mpeg", "audio/aac", "audio/mp4", "audio/ogg",
        "application/pdf",
        "application/zip", "application/gzip", "application/x-bzip2",
        "application/x-rar-compressed", "application/x-7z-compressed"
    ]

    /// Compress with ZLIB if:
    ///   a) the MIME type is not already compressed, AND
    ///   b) compression reduces size by at least 10%
    /// Returns (data, wasCompressed).
    static func compressIfBeneficial(_ data: Data, mimeType: String) -> (Data, Bool) {
        guard !alreadyCompressedMimeTypes.contains(mimeType),
              data.count > 512 else {   // no point compressing tiny files
            return (data, false)
        }
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            return (data, false)
        }
        let ratio = Double(compressed.count) / Double(data.count)
        if ratio < 0.90 {
            Log.debug("Compressed \(data.count) → \(compressed.count) bytes (\(Int(ratio * 100))%)", category: "MediaManager")
            return (compressed, true)
        }
        return (data, false)
    }

    /// Decompress ZLIB-compressed data (used on the receiver side)
    static func decompress(_ data: Data) throws -> Data {
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else {
            throw MediaUploadError.encryptionFailed   // reuse existing error type
        }
        return decompressed
    }

    /// Upload avatar image (profile sharing)
    /// - Parameter image: Avatar image to upload
    /// - Returns: Avatar upload result with raw encryption key
    func uploadAvatar(_ image: PlatformImage) async throws -> AvatarUploadResult {
        Log.info("Uploading avatar", category: "MediaManager")
        
        // Optimize avatar (resize + compress) using ImageHelper
        guard let avatarData = ImageHelper.prepareAvatarImage(image) else {
            throw MediaManagerError.optimizationFailed
        }
        
        let uploadResult = try await Self.uploadWithRetry(
                data: avatarData,
                mimeType: "image/jpeg"
            )
        Log.info("Avatar uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        
        return AvatarUploadResult(
            mediaUrl: uploadResult.mediaUrl,
            encryptionKey: uploadResult.encryptionKey,
            mediaId: uploadResult.mediaId,
            hash: uploadResult.hash
        )
    }
    
    // MARK: - Download Operations
    
    /// Download and decrypt media from message
    /// - Parameters:
    ///   - mediaUrl: URL to download encrypted media from
    ///   - mediaKey: Raw 32-byte AES-256-GCM key (already decrypted as part of message)
    /// - Returns: Decrypted media data
    func downloadAndDecryptMedia(mediaId: String, mediaUrl: String, mediaKey: Data, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        // 1. In-memory cache
        let cacheKey = mediaId
        if let cachedData = mediaCache[cacheKey] {
            Log.debug("Media cache hit (memory) for: \(mediaId.prefix(8))...", category: "MediaManager")
            return cachedData
        }

        // 2. Persistent disk cache — survives app updates and restarts
        if let diskData = loadFromDiskCache(mediaId: mediaId) {
            Log.debug("Media cache hit (disk) for: \(mediaId.prefix(8))...", category: "MediaManager")
            if currentCacheSize + diskData.count < maxCacheSize {
                mediaCache[cacheKey] = diskData
                currentCacheSize += diskData.count
            }
            return diskData
        }
        
        guard mediaKey.count == 32 else {
            Log.error("Invalid media key size: \(mediaKey.count) (expected 32)", category: "MediaManager")
            throw MediaManagerError.invalidMediaKey
        }

        Log.info("Downloading media from: \(mediaUrl)", category: "MediaManager")

        let encryptedData = try await Self.downloadWithRetry(mediaId: mediaId, onProgress: onProgress)
        Log.debug("   Downloaded encrypted data: \(encryptedData.count) bytes", category: "MediaManager")

        let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: mediaKey)
        
        Log.info("Media decrypted: \(decryptedData.count) bytes", category: "MediaManager")
        
        // Persist to disk cache so media survives app restarts and updates
        saveToDiskcache(decryptedData, mediaId: mediaId)
        evictToQuota()

        // Store in memory cache if space available
        if currentCacheSize + decryptedData.count < maxCacheSize {
            mediaCache[cacheKey] = decryptedData
            currentCacheSize += decryptedData.count
            Log.debug("Cached media (\(currentCacheSize / 1024)KB / \(maxCacheSize / 1024)KB)", category: "MediaManager")
        } else {
            Log.debug("Cache full, not caching this media", category: "MediaManager")
        }
        
        return decryptedData
    }

    /// Download, decrypt, and optionally decompress a file attachment.
    /// - Parameters:
    ///   - mediaId: UUID of the media file
    ///   - mediaUrl: Download URL (used for logging)
    ///   - mediaKey: Raw 32-byte AES-256-GCM key
    ///   - compressed: Whether the payload was ZLIB-compressed before encryption
    /// - Returns: Original (decompressed if needed) file data
    func downloadAndDecryptFile(
        mediaId: String,
        mediaUrl: String,
        mediaKey: Data,
        compressed: Bool
    ) async throws -> Data {
        let decryptedData = try await downloadAndDecryptMedia(
            mediaId: mediaId,
            mediaUrl: mediaUrl,
            mediaKey: mediaKey
        )
        guard compressed else { return decryptedData }

        Log.debug("Decompressing file attachment (\(decryptedData.count) bytes)", category: "MediaManager")
        let decompressed = try Self.decompress(decryptedData)
        Log.info("Decompressed: \(decryptedData.count) → \(decompressed.count) bytes", category: "MediaManager")
        return decompressed
    }
    func clearCache(includingDisk: Bool = false) {
        mediaCache.removeAll()
        currentCacheSize = 0
        if includingDisk {
            try? FileManager.default.removeItem(at: diskCacheDirectory)
            try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
            Log.info("Media cache cleared (memory + disk)", category: "MediaManager")
        } else {
            Log.info("Media cache cleared (memory only)", category: "MediaManager")
        }
    }
    
    /// Download and decrypt avatar (profile sharing)
    /// - Parameters:
    ///   - mediaId: UUID of the media file
    ///   - mediaUrl: Download URL (used for logging only)
    ///   - mediaKey: Raw 32-byte AES-256-GCM key
    /// - Returns: Decrypted avatar image data
    func downloadAndDecryptAvatar(mediaId: String, mediaUrl: String, mediaKey: Data) async throws -> Data {
        Log.info("Downloading avatar from: \(mediaUrl)", category: "MediaManager")

        let encryptedData = try await Self.downloadWithRetry(mediaId: mediaId)
        let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: mediaKey)

        Log.info("Avatar decrypted: \(decryptedData.count) bytes", category: "MediaManager")
        return decryptedData
    }
    
    // MARK: - Thumbnail Operations
    
    /// Generate thumbnail from UIImage
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    func generateThumbnail(from image: PlatformImage, maxSize: CGFloat = 250) -> Data? {
        Log.debug("Generating thumbnail (maxSize: \(maxSize))", category: "MediaManager")
        
        do {
            let optimized = try MediaOptimizer.generateThumbnail(from: image)
            Log.debug("Thumbnail generated: \(optimized.count) bytes", category: "MediaManager")
            return optimized
        } catch {
            Log.error("Failed to generate thumbnail: \(error)", category: "MediaManager")
            return nil
        }
    }
    
    /// Generate thumbnail from Data
    /// - Parameters:
    ///   - data: Image data
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    func generateThumbnail(from data: Data, maxSize: CGFloat = 250) -> Data? {
        guard let image = PlatformImage(data: data) else {
            Log.error("Failed to create PlatformImage from data", category: "MediaManager")
            return nil
        }
        
        return generateThumbnail(from: image, maxSize: maxSize)
    }
    
    /// Generate thumbnail with custom UIImage renderer (for MessageBubble compatibility)
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension
    /// - Returns: Thumbnail UIImage
    func generateThumbnailImage(from image: PlatformImage, maxSize: CGFloat) -> PlatformImage {
        let size = image.size
        let scale = size.width > size.height ? maxSize / size.width : maxSize / size.height
        let thumbnailSize = CGSize(width: size.width * scale, height: size.height * scale)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }
        #else
        let dest = NSImage(size: thumbnailSize)
        dest.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        dest.unlockFocus()
        return dest
        #endif
    }
    
    // MARK: - Thumbnail Storage (UserDefaults - temporary solution)
    
    /// Store thumbnail locally for message
    /// - Parameters:
    ///   - thumbnailData: Thumbnail image data
    ///   - messageId: Message ID to associate with
    func storeThumbnail(_ thumbnailData: Data, for messageId: String, at index: Int = 0) {
        UserDefaults.standard.set(thumbnailData, forKey: "message_thumbnail_\(messageId)_\(index)")
        // Keep legacy key for index 0 — backward compat with existing thumbnails
        if index == 0 {
            UserDefaults.standard.set(thumbnailData, forKey: "message_thumbnail_\(messageId)")
        }
        Log.debug("Stored thumbnail[\(index)] for message: \(messageId)", category: "MediaManager")
    }
    
    /// Retrieve stored thumbnail for message
    /// - Parameter messageId: Message ID
    /// - Returns: Thumbnail data if exists
    func retrieveThumbnail(for messageId: String, at index: Int = 0) -> Data? {
        // Try indexed key first
        if let data = UserDefaults.standard.data(forKey: "message_thumbnail_\(messageId)_\(index)") {
            return data
        }
        // Fall back to legacy unindexed key for index 0
        if index == 0 {
            return UserDefaults.standard.data(forKey: "message_thumbnail_\(messageId)")
        }
        return nil
    }

    func retrieveThumbnail(for messageId: String) -> Data? {
        retrieveThumbnail(for: messageId, at: 0)
    }
    
    /// Remove stored thumbnail for message
    /// - Parameter messageId: Message ID
    func removeThumbnail(for messageId: String) {
        // Remove indexed keys (up to 10) + legacy key
        for i in 0..<10 {
            UserDefaults.standard.removeObject(forKey: "message_thumbnail_\(messageId)_\(i)")
        }
        UserDefaults.standard.removeObject(forKey: "message_thumbnail_\(messageId)")
    }
}

// MARK: - Supporting Types

/// Result of avatar upload
struct AvatarUploadResult {
    let mediaUrl: String
    let encryptionKey: Data
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
