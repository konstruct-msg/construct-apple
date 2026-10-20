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
import AVFoundation
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

    /// Cost-limited cache of decrypted media. Prefer `NSCache` over a `Dictionary`:
    /// it evicts under pressure and enforces `totalCostLimit`. A plain dict only refused
    /// *new* inserts at 50 MB and never dropped old ones — build 586 still held an 11.8 MB
    /// video in RAM while resident climbed toward ~460 MB hopping between media chats.
    let mediaCache = NSCache<NSString, NSData>()
    /// Soft ceiling for a single in-memory entry. Bigger blobs stay **disk-only** (videos,
    /// original HEIC/PNG). Display paths that need the full bytes re-read from disk.
    nonisolated static let maxMemoryItemBytes = 2 * 1024 * 1024
    /// Aggregate cost limit for `mediaCache` (bytes).
    private static let maxMemoryCacheBytes = 32 * 1024 * 1024

    /// Deduplicates concurrent fetches for the same media ID while the first request is in flight.
    var inFlightDownloads: [String: Task<Data, Error>] = [:]
    /// Media IDs the server reported as gone (expired past retention / never existed), with the
    /// time they were marked. Short-circuits re-download storms: without this, every chat/grid
    /// re-render re-fetches a permanently-missing blob, and each round-trip throws `.notFound`
    /// and emits a (neutral but noisy) transport `rpc-fail` event.
    var notFoundMedia: [String: Date] = [:]
    /// How long a not-found verdict is trusted before a re-check is allowed.
    static let notFoundTTL: TimeInterval = 30 * 60

    /// Where media used to live. Read-only now: drained by `migrateMediaOutOfCaches()` at launch
    /// and opportunistically on read, exactly like ThumbnailStore.
    let legacyCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("media", isDirectory: true)
    }()

    private init() {
        mediaCache.totalCostLimit = Self.maxMemoryCacheBytes
        mediaCache.countLimit = 64
        mediaCache.name = "MediaManager.mediaCache"
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearMemoryCache(reason: "memory_warning")
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Disk cache remains; drop RAM so background jetsam is less likely after a media chat.
            Task { @MainActor in
                self?.clearMemoryCache(reason: "background")
            }
        }
        #endif
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
