//
//  MediaUploadService.swift
//  Construct Messenger
//
//  Service for uploading encrypted media files to the media server.
//  Uses one-time upload tokens from construct-server.
//
//  Flow:
//  1. Request upload token from WebSocket
//  2. Encrypt media with random key
//  3. Upload encrypted blob to media server
//  4. Send message with media URL + encrypted key
//

import Foundation
import CryptoKit
import UIKit

// MARK: - Media Upload Error
enum MediaUploadError: LocalizedError {
    case notAuthenticated
    case tokenRequestFailed(String)
    case tokenTimeout
    case uploadFailed(String)
    case encryptionFailed
    case invalidResponse
    case fileTooLarge(Int, Int)  // actual, max
    case mediaServerDisabled
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be authenticated to upload media"
        case .tokenRequestFailed(let reason):
            return "Failed to get upload token: \(reason)"
        case .tokenTimeout:
            return "Upload token request timed out"
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        case .encryptionFailed:
            return "Failed to encrypt media"
        case .invalidResponse:
            return "Invalid response from media server"
        case .fileTooLarge(let actual, let max):
            return "File too large: \(actual / 1024 / 1024)MB exceeds limit of \(max / 1024 / 1024)MB"
        case .mediaServerDisabled:
            return "Media uploads are not enabled on this server"
        }
    }
}

// MARK: - Media Upload Service
class MediaUploadService {
    static let shared = MediaUploadService()
    
    private var pendingTokenRequests: [String: CheckedContinuation<MediaTokenData, Error>] = [:]
    private let queue = DispatchQueue(label: "com.construct.mediaupload", attributes: .concurrent)
    
    private init() {}
    
    // MARK: - Public API
    
    /// Upload media to server using MediaAPI
    /// - Parameters:
    ///   - optimizedMedia: Already optimized media from MediaOptimizer
    ///   - recipientId: User ID of the recipient (for encrypting media key)
    /// - Returns: MediaMessage data to include in chat message
    func uploadMedia(_ optimizedMedia: OptimizedMedia, for recipientId: String) async throws -> MediaMessageData {
        Log.info("📤 Starting media upload (\(optimizedMedia.data.count) bytes)", category: "MediaUpload")
        
        // ✅ Use MediaAPI for upload (handles encryption, multipart upload)
        let uploadResult: MediaAPI.UploadedMedia
        if #available(iOS 18.0, *) {
            uploadResult = try await MediaServiceClient.shared.uploadData(
                optimizedMedia.data,
                mimeType: optimizedMedia.metadata.mimeType
            )
        } else {
            uploadResult = try await MediaAPI.shared.uploadData(
                optimizedMedia.data,
                mimeType: optimizedMedia.metadata.mimeType
            )
        }
        Log.info("✅ Media uploaded: \(uploadResult.mediaId)", category: "MediaUpload")
        
        // Use raw base64 key - entire message will be encrypted via Double Ratchet
        let mediaKeyBase64 = uploadResult.encryptionKey.base64EncodedString()
        
        // Build media message data
        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: mediaKeyBase64,
            mediaType: uploadResult.mimeType,
            size: optimizedMedia.metadata.originalSize,
            width: optimizedMedia.metadata.width,
            height: optimizedMedia.metadata.height,
            duration: optimizedMedia.metadata.duration,
            thumbnail: nil,  // Client-side generation from downloaded media
            hash: uploadResult.hash
        )
    }
    
    /// Upload image using MediaAPI
    func uploadImage(_ image: UIImage, for recipientId: String) async throws -> MediaMessageData {
        let uploadResult: MediaAPI.UploadedMedia
        if #available(iOS 18.0, *) {
            uploadResult = try await MediaServiceClient.shared.uploadImage(image, quality: 0.8)
        } else {
            uploadResult = try await MediaAPI.shared.uploadImage(image, quality: 0.8)
        }
        Log.info("✅ Image uploaded: \(uploadResult.mediaId)", category: "MediaUpload")
        
        // Use raw base64 key - entire message will be encrypted via Double Ratchet
        let mediaKeyBase64 = uploadResult.encryptionKey.base64EncodedString()
        
        // Extract image dimensions
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        
        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: mediaKeyBase64,
            mediaType: uploadResult.mimeType,
            size: uploadResult.encryptedData.count,
            width: width,
            height: height,
            duration: nil,
            thumbnail: nil,
            hash: uploadResult.hash
        )
    }
    
    // MARK: - Download Media
    
    /// Download and decrypt media from media server using MediaAPI
    /// - Parameters:
    ///   - mediaUrl: URL to download encrypted media from
    ///   - mediaKeyBase64: Base64-encoded media key (raw key, not Double Ratchet encrypted)
    /// - Returns: Decrypted media data
    func downloadAndDecryptMedia(mediaUrl: String, mediaKeyBase64: String) async throws -> Data {
        Log.info("📥 Downloading media from: \(mediaUrl)", category: "MediaUpload")
        
        // Decode media key
        guard let keyData = Data(base64Encoded: mediaKeyBase64) else {
            throw MediaUploadError.encryptionFailed
        }
        
        // Download encrypted data
        let encryptedData: Data
        if #available(iOS 18.0, *) {
            let mediaId = URL(string: mediaUrl)?.lastPathComponent ?? mediaUrl
            encryptedData = try await MediaServiceClient.shared.downloadEncryptedFile(mediaId: mediaId)
        } else {
            encryptedData = try await MediaAPI.shared.downloadEncryptedFile(from: mediaUrl)
        }
        
        // Decrypt using CryptoManager
        let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: keyData)
        
        Log.info("✅ Media decrypted: \(decryptedData.count) bytes", category: "MediaUpload")
        return decryptedData
    }
}

// MARK: - Media Message Data
/// Data to include in chat message for media
struct MediaMessageData: Codable {
    let mediaId: String
    let mediaUrl: String
    let mediaKey: String  // Encrypted with Double Ratchet
    let mediaType: String  // MIME type
    let size: Int
    let width: Int?
    let height: Int?
    let duration: TimeInterval?
    let thumbnail: String?  // Base64 JPEG
    let hash: String  // SHA-256 of encrypted file (for server verification)
}

// MARK: - CryptoManager Extension
extension CryptoManager {
    
    /// Decrypt media data using symmetric key
    /// The key should be raw AES key (32 bytes) extracted from decrypted message content
    /// This method decrypts media using the symmetric key
    func decryptMediaData(_ encryptedData: Data, with keyData: Data) throws -> Data {
        Log.debug("🔓 Decrypting media: encryptedSize=\(encryptedData.count), keySize=\(keyData.count)", category: "MediaUpload")
        
        guard keyData.count == 32 else {
            Log.error("❌ Invalid key size: \(keyData.count) (expected 32)", category: "MediaUpload")
            throw MediaUploadError.encryptionFailed
        }
        
        let key = SymmetricKey(data: keyData)
        
        // ✅ Use AES-GCM (matches MediaAPI encryption)
        // Format: [12 bytes nonce][N bytes ciphertext][16 bytes tag]
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            Log.debug("   SealedBox created: nonce=\(sealedBox.nonce.withUnsafeBytes { Data($0).count }) bytes", category: "MediaUpload")
            
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            Log.debug("✅ Media decrypted successfully: \(decryptedData.count) bytes", category: "MediaUpload")
            
            return decryptedData
        } catch {
            Log.error("❌ AES-GCM decryption failed: \(error)", category: "MediaUpload")
            throw MediaUploadError.encryptionFailed
        }
    }
}
