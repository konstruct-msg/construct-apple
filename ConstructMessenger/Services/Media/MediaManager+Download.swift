//
//  MediaManager+Download.swift
//  Construct Messenger
//
//  MediaManager: download and decrypt of media and avatars. Split out of MediaManager.swift.
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
import AVFoundation
import GRPCCore

extension MediaManager {
    // MARK: - Download Operations
    
    /// Download and decrypt media from message
    /// - Parameters:
    ///   - mediaUrl: URL to download encrypted media from
    ///   - mediaKey: Raw 32-byte AES-256-GCM key (already decrypted as part of message)
    /// - Returns: Decrypted media data
    func downloadAndDecryptMedia(mediaId: String, mediaUrl: String, mediaKey: Data, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        // 1. In-memory cache
        let cacheKey = mediaId
        if let cachedData = memoryCachedData(for: cacheKey) {
            Log.debug("Media cache hit (memory) for: \(mediaId.prefix(8))...", category: "MediaManager")
            return cachedData
        }

        // 2. Persistent disk cache — survives app updates and restarts
        if let diskData = loadFromDiskCache(mediaId: mediaId) {
            Log.debug("Media cache hit (disk) for: \(mediaId.prefix(8))...", category: "MediaManager")
            // Promote only when small enough — never pull a multi‑MB video back into RAM.
            storeInMemoryCache(diskData, mediaId: cacheKey)
            return diskData
        }

        // 3. Negative cache — the server already reported this blob gone (expired past the 7d
        //    retention, or never existed). Fail fast locally so we don't re-hit the network and
        //    emit a transport rpc-fail event on every grid/chat re-render.
        if let markedAt = notFoundMedia[cacheKey] {
            if Date().timeIntervalSince(markedAt) < Self.notFoundTTL {
                throw RPCError(code: .notFound, message: "Media file not found on disk")
            }
            notFoundMedia.removeValue(forKey: cacheKey)  // TTL elapsed — allow one re-check
        }

        guard mediaKey.count == 32 else {
            Log.error("Invalid media key size: \(mediaKey.count) (expected 32)", category: "MediaManager")
            throw MediaManagerError.invalidMediaKey
        }
        if let task = inFlightDownloads[cacheKey] {
            Log.debug("Joining in-flight download for: \(mediaId.prefix(8))...", category: "MediaManager")
            return try await task.value
        }

        Log.info("Downloading media from: \(mediaUrl)", category: "MediaManager")
        let task = Task<Data, Error> {
            let encryptedData = try await Self.downloadWithRetry(mediaId: mediaId, onProgress: onProgress)
            Log.debug("   Downloaded encrypted data: \(encryptedData.count) bytes", category: "MediaManager")
            let decryptedData = try CryptoManager.shared.decryptMediaData(encryptedData, with: mediaKey)
            Log.info("Media decrypted: \(decryptedData.count) bytes", category: "MediaManager")
            return decryptedData
        }
        inFlightDownloads[cacheKey] = task
        defer { inFlightDownloads.removeValue(forKey: cacheKey) }
        let decryptedData: Data
        do {
            decryptedData = try await task.value
        } catch let error as RPCError where error.code == .notFound {
            // Permanently gone — record so concurrent/subsequent renders short-circuit above.
            notFoundMedia[cacheKey] = Date()
            Log.info("Media \(mediaId.prefix(8))… not found on server (expired/removed) — negative-caching for \(Int(Self.notFoundTTL))s", category: "MediaManager")
            throw error
        }

        // Persist to disk cache so media survives app restarts and updates
        saveToDiskcache(decryptedData, mediaId: mediaId)
        evictToQuota()
        storeInMemoryCache(decryptedData, mediaId: cacheKey)

        return decryptedData
    }

    /// `includingDisk: true` deletes the user's received media permanently — anything past the
    /// server's 7-day retention cannot be fetched again. That is a legitimate thing for a person to
    /// ask for (it is wired to an explicit control in Data & Storage settings) and it is not
    /// something anything else should call.
    func clearCache(includingDisk: Bool = false) {
        mediaCache.removeAllObjects()
        notFoundMedia.removeAll()
        if includingDisk {
            try? FileManager.default.removeItem(at: mediaDirectory)
            try? FileManager.default.createDirectory(
                at: mediaDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
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
}
