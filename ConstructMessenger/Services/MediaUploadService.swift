//
//  MediaUploadService.swift
//  Construct Messenger
//
//  Shared media types and CryptoManager media extension.
//  Use MediaManager for all upload/download operations.
//

import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Media Upload Error
enum MediaUploadError: LocalizedError {
    case encryptionFailed
    case uploadFailed(String)
    case fileTooLarge(Int, Int)  // actual, max

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt/decrypt media"
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        case .fileTooLarge(let actual, let max):
            return "File too large: \(actual / 1024 / 1024)MB exceeds limit of \(max / 1024 / 1024)MB"
        }
    }
}

// MARK: - Media Message Data
/// Data to include in chat message for media
struct MediaMessageData: Codable {
    let mediaId: String
    let mediaUrl: String
    let mediaKey: Data      // Raw AES key — JSONEncoder emits base64 transparently
    let mediaType: String
    let size: Int
    let width: Int?
    let height: Int?
    let duration: TimeInterval?
    let thumbnail: Data?    // JPEG thumbnail — JSONEncoder emits base64 transparently
    let hash: String        // SHA-256 of encrypted file
    let filename: String?   // Original filename for document attachments
    let compressed: Bool?   // true = ZLIB-compressed before AES encryption; decompress after decrypt
    let blurhash: String?   // Compact blurred-preview string (shown before full download)

    init(
        mediaId: String,
        mediaUrl: String,
        mediaKey: Data,
        mediaType: String,
        size: Int,
        width: Int?,
        height: Int?,
        duration: TimeInterval?,
        thumbnail: Data?,
        hash: String,
        filename: String?,
        compressed: Bool?,
        blurhash: String? = nil
    ) {
        self.mediaId = mediaId
        self.mediaUrl = mediaUrl
        self.mediaKey = mediaKey
        self.mediaType = mediaType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.thumbnail = thumbnail
        self.hash = hash
        self.filename = filename
        self.compressed = compressed
        self.blurhash = blurhash
    }
}

// MARK: - CryptoManager Media Extension
extension CryptoManager {
    /// Decrypt media data using raw 32-byte AES-256-GCM key
    /// Format: [12 bytes nonce][ciphertext][16 bytes tag]
    func decryptMediaData(_ encryptedData: Data, with keyData: Data) throws -> Data {
        guard keyData.count == 32 else {
            Log.error("Invalid key size: \(keyData.count) (expected 32)", category: "MediaUpload")
            throw MediaUploadError.encryptionFailed
        }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        } catch {
            Log.error("AES-GCM decryption failed: \(error)", category: "MediaUpload")
            throw MediaUploadError.encryptionFailed
        }
    }
}
