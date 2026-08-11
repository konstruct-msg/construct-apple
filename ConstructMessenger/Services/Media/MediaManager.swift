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
    private let mediaCache = NSCache<NSString, NSData>()
    /// Soft ceiling for a single in-memory entry. Bigger blobs stay **disk-only** (videos,
    /// original HEIC/PNG). Display paths that need the full bytes re-read from disk.
    nonisolated static let maxMemoryItemBytes = 2 * 1024 * 1024
    /// Aggregate cost limit for `mediaCache` (bytes).
    private static let maxMemoryCacheBytes = 32 * 1024 * 1024

    /// Deduplicates concurrent fetches for the same media ID while the first request is in flight.
    private var inFlightDownloads: [String: Task<Data, Error>] = [:]
    /// Media IDs the server reported as gone (expired past retention / never existed), with the
    /// time they were marked. Short-circuits re-download storms: without this, every chat/grid
    /// re-render re-fetches a permanently-missing blob, and each round-trip throws `.notFound`
    /// and emits a (neutral but noisy) transport `rpc-fail` event.
    private var notFoundMedia: [String: Date] = [:]
    /// How long a not-found verdict is trusted before a re-check is allowed.
    private static let notFoundTTL: TimeInterval = 30 * 60

    // MARK: - Persistent Disk Cache

    /// `Application Support/media/` — the user's copy of everything they have received.
    ///
    /// This lived in `Library/Caches/media/` until 2026-08-11, which was wrong in a way that only
    /// shows up as a photo that is simply not there any more. iOS purges Caches whenever the disk
    /// gets tight, without telling the app, and the server drops an uploaded object 7 days after
    /// upload regardless of downloads. Those two facts compose: on day nine, a system purge takes
    /// the last copy in existence.
    ///
    /// Application Support is not purged. See `MediaEvictionPolicy` for the other half — our own
    /// quota sweep was deleting oldest-first, i.e. exactly the files that could never come back.
    private let mediaDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            // Matches the Core Data store (PersistenceController) and MessageKeyStore: readable
            // after the first unlock so a background push can decrypt and attach media, but not
            // while the device has never been unlocked since boot.
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        // Caches is never included in an iCloud backup, so simply moving the directory would have
        // started shipping plaintext photos to iCloud as a side effect of a durability fix. That is
        // a privacy change and it is not this one's to make: excluded, so the posture is unchanged.
        // COST, stated because it is real: restoring the device to a new phone does not bring media
        // with it. Revisit only as a deliberate decision, with the at-rest encryption question
        // answered first.
        var mutable = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        return dir
    }()

    /// Where media used to live. Read-only now: drained by `migrateMediaOutOfCaches()` at launch
    /// and opportunistically on read, exactly like ThumbnailStore.
    private let legacyCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("media", isDirectory: true)
    }()

    private func diskCacheURL(for mediaId: String) -> URL {
        mediaDirectory.appendingPathComponent(mediaId)
    }

    private func saveToDiskcache(_ data: Data, mediaId: String) {
        let url = diskCacheURL(for: mediaId)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadFromDiskCache(mediaId: String) -> Data? {
        if let data = try? Data(contentsOf: diskCacheURL(for: mediaId)) { return data }

        // Not migrated yet. Move it rather than copy: two copies of a video is not a rounding error.
        let legacy = legacyCacheDirectory.appendingPathComponent(mediaId)
        guard let data = try? Data(contentsOf: legacy) else { return nil }
        try? FileManager.default.moveItem(at: legacy, to: diskCacheURL(for: mediaId))
        return data
    }

    /// Moves everything still sitting in `Library/Caches/media/` into the durable store.
    ///
    /// Bulk *and* on-read (above), for the reason the thumbnail migration needed both: a rule that
    /// only runs when someone asks for a specific file never reaches the files nobody opens — and
    /// those are precisely the ones a system purge takes without anyone noticing.
    @discardableResult
    func migrateMediaOutOfCaches() -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: legacyCacheDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ), !entries.isEmpty else { return (0, 0) }

        var moved = 0
        var bytes: Int64 = 0
        for source in entries {
            let destination = mediaDirectory.appendingPathComponent(source.lastPathComponent)
            let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: source)       // already migrated; drop the duplicate
                continue
            }
            do {
                try fm.moveItem(at: source, to: destination)
                try? fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
                moved += 1
                bytes += size
            } catch {
                Log.error("Media migration failed for \(source.lastPathComponent.prefix(8))…: \(error)", category: "MediaManager")
            }
        }
        if moved > 0 {
            Log.info("Media migration: \(moved) file(s), \(bytes / 1024)KB moved out of Caches", category: "MediaManager")
        }
        return (moved, bytes)
    }

    // MARK: - Cache Management

    /// Total bytes used by the disk cache.
    func diskCacheSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Free space up to the quota, deleting only media that could still be fetched again.
    ///
    /// This used to be plain LRU — oldest first — which on a store whose contents expire server-side
    /// after 7 days meant it deleted the irreplaceable files and kept the replaceable ones. Exactly
    /// backwards. `MediaEvictionPolicy` holds the reasoning; the short version is that the only
    /// thing we know is when *we* downloaded a file, and that is enough to prove the server copy is
    /// gone, never that it is still there.
    private func evictToQuota() {
        let maxBytes = UserDefaults.standard.object(forKey: Self.maxDiskCacheBytesKey) as? Int
            ?? Self.defaultMaxDiskCacheBytes
        guard maxBytes > 0 else { return } // 0 = unlimited

        let totalSize = diskCacheSize()
        guard totalSize > Int64(maxBytes) else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let now = Date()
        let candidates = files.map { url -> (id: String, bytes: Int64, secondsSinceDownload: TimeInterval) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            return (
                id: url.lastPathComponent,
                bytes: Int64(values?.fileSize ?? 0),
                secondsSinceDownload: now.timeIntervalSince(modified)
            )
        }

        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: candidates, totalBytes: totalSize, quotaBytes: Int64(maxBytes)
        )
        var freed: Int64 = 0
        for id in doomed {
            let url = mediaDirectory.appendingPathComponent(id)
            freed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: url)
            mediaCache.removeObject(forKey: id as NSString)
        }

        if totalSize - freed > Int64(maxBytes) {
            // Over quota with nothing safe left to delete. Reported rather than resolved: the rest
            // exists only here, and a full disk is a problem the user can see and act on where a
            // missing photo is not. If this line ever shows up in the field it is the signal that
            // storage management has to become a user-facing choice, not a silent sweep.
            Log.info(
                "Media store over quota by \(((totalSize - freed) - Int64(maxBytes)) / 1024)KB — remaining files are past server retention and are the only copies",
                category: "MediaManager"
            )
        } else if !doomed.isEmpty {
            Log.info("Evicted \(doomed.count) re-downloadable file(s), \(freed / 1024)KB — quota", category: "MediaManager")
        }
    }

    /// Evict files older than the configured number of days. Call on app foreground.
    ///
    /// Note what this deletes now that the store is durable: files old enough to be past the
    /// server's retention, i.e. the ones that exist nowhere else. That is the opposite of
    /// `evictToQuota`'s rule, and deliberately so — this one only runs when the user has set a
    /// number of days in settings, which is them saying "I do not want media older than this".
    /// It defaults to 0 (off) and must stay that way.
    func evictOldFiles() {
        let days = UserDefaults.standard.object(forKey: Self.evictAfterDaysKey) as? Int ?? 0
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        var count = 0
        for file in files {
            let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if mod < cutoff {
                try? FileManager.default.removeItem(at: file)
                mediaCache.removeObject(forKey: file.lastPathComponent as NSString)
                count += 1
            }
        }
        if count > 0 {
            Log.info("Evicted \(count) cached file(s) older than \(days) days", category: "MediaManager")
        }
    }

    /// Whether a decrypted blob is small enough to keep in RAM. Pure / nonisolated so tests
    /// and callers can decide without hopping onto the main actor.
    nonisolated static func shouldCacheInMemory(
        byteCount: Int,
        maxItemBytes: Int = maxMemoryItemBytes
    ) -> Bool {
        byteCount > 0 && byteCount <= maxItemBytes
    }

    private func memoryCachedData(for mediaId: String) -> Data? {
        mediaCache.object(forKey: mediaId as NSString) as Data?
    }

    private func storeInMemoryCache(_ data: Data, mediaId: String) {
        guard Self.shouldCacheInMemory(byteCount: data.count) else {
            Log.debug(
                "Skip memory cache for \(mediaId.prefix(8))… (\(data.count / 1024)KB > \(Self.maxMemoryItemBytes / 1024)KB) — disk only",
                category: "MediaManager"
            )
            return
        }
        mediaCache.setObject(data as NSData, forKey: mediaId as NSString, cost: data.count)
    }

    private func clearMemoryCache(reason: String) {
        mediaCache.removeAllObjects()
        Log.info("Media memory cache cleared (\(reason))", category: "MediaManager")
    }

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
    
    // MARK: - Upload Operations
    
    /// Upload image for chat message
    /// - Parameters:
    ///   - image: UIImage to upload
    ///   - recipientId: User ID to encrypt media key for
    /// - Returns: Media metadata for message content
    func uploadImage(
        _ attachment: MediaAttachment,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        // Original-quality: upload the source bytes untouched (preserve HEIC/PNG + mime).
        if attachment.quality == .original {
            return try await uploadOriginalImage(attachment, for: recipientId, onProgress: onProgress)
        }

        Log.info("Uploading image for recipient: \(recipientId) (compressed)", category: "MediaManager")
        guard let image = attachment.displayImage ?? PlatformImage(data: attachment.originalData) else {
            throw MediaOptimizationError.conversionFailed
        }
        let optimized = try MediaOptimizer.optimizeImage(image)

        // Upload with 1 automatic retry on stream failure
        let uploadResult = try await Self.uploadWithRetry(data: optimized.data, mimeType: optimized.metadata.mimeType, onProgress: onProgress)
        Log.info("Image uploaded: \(uploadResult.mediaId)", category: "MediaManager")

        let width = optimized.metadata.width
        let height = optimized.metadata.height
        let blurhash = BlurHash.encode(image)

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
            compressed: false,
            blurhash: blurhash
        )
    }

    /// Upload the original source bytes untouched (no JPEG re-encode), preserving the
    /// real mime (HEIC/PNG/JPEG). A small JPEG thumbnail + pixel dimensions are still
    /// derived from the display image so bubbles render before the full download.
    private func uploadOriginalImage(
        _ attachment: MediaAttachment,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        let data = attachment.originalData
        Log.info("Uploading ORIGINAL image for recipient: \(recipientId) (mime=\(attachment.mimeType), \(data.count) bytes)", category: "MediaManager")
        guard Int64(data.count) <= MessageSizeLimits.maxImageBytes else {
            throw MediaUploadError.fileTooLarge(data.count, Int(MessageSizeLimits.maxImageBytes))
        }
        let uploadResult = try await Self.uploadWithRetry(data: data, mimeType: attachment.mimeType, onProgress: onProgress)
        Log.info("Original image uploaded: \(uploadResult.mediaId)", category: "MediaManager")

        let thumbnail = attachment.displayImage.flatMap { try? MediaOptimizer.generateThumbnail(from: $0) }
        let (width, height) = Self.pixelDimensions(of: attachment.displayImage)
        let blurhash = attachment.displayImage.flatMap { BlurHash.encode($0) }

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: attachment.mimeType,
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: nil,
            thumbnail: thumbnail,
            hash: uploadResult.hash,
            filename: nil,
            compressed: false,
            blurhash: blurhash
        )
    }

    // MARK: - Video upload

    /// Transcode a picked video to the requested quality, then encrypt + upload it.
    /// Progress: transcode maps to 0…0.5, upload to 0.5…1.0, so the sender sees a moving
    /// bar through the (otherwise silent) compression phase — the long part for big clips.
    func uploadVideo(
        _ attachment: MediaAttachment,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        guard let sourceURL = attachment.videoURL else {
            throw MediaUploadError.uploadFailed("Video attachment missing source URL")
        }
        Log.info("Uploading video for \(recipientId) (quality=\(attachment.videoQuality.rawValue))", category: "MediaManager")

        let asset = AVURLAsset(url: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

        let transcodedURL = try await Self.transcodeVideo(
            asset: asset,
            to: outputURL,
            quality: attachment.videoQuality,
            onProgress: onProgress.map { cb in { @Sendable v in cb(v * 0.5) } }
        )
        defer {
            try? FileManager.default.removeItem(at: transcodedURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let videoData = try Data(contentsOf: transcodedURL)
        guard Int64(videoData.count) <= MessageSizeLimits.maxVideoBytes else {
            throw MediaUploadError.fileTooLarge(videoData.count, Int(MessageSizeLimits.maxVideoBytes))
        }

        let uploadResult = try await Self.uploadWithRetry(
            data: videoData,
            mimeType: "video/mp4",
            onProgress: onProgress.map { cb in { @Sendable v in cb(0.5 + v * 0.5) } }
        )
        Log.info("Video uploaded: \(uploadResult.mediaId) (\(videoData.count) bytes)", category: "MediaManager")

        let (width, height) = await Self.videoDisplayDimensions(AVURLAsset(url: transcodedURL))
        let loadedDuration = (try? await asset.load(.duration))?.seconds
        let duration = attachment.duration ?? loadedDuration
        let thumbnail = attachment.displayImage.flatMap { try? MediaOptimizer.generateThumbnail(from: $0) }
        let blurhash = attachment.displayImage.flatMap { BlurHash.encode($0) }

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: "video/mp4",
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: duration,
            thumbnail: thumbnail,
            hash: uploadResult.hash,
            filename: nil,
            compressed: attachment.videoQuality != .original,
            blurhash: blurhash
        )
    }

    /// Export `asset` to `outputURL` at the given quality. `.original` uses passthrough
    /// (container remux only). Reports export progress via `onProgress` (0…1).
    private static func transcodeVideo(
        asset: AVURLAsset,
        to outputURL: URL,
        quality: VideoQuality,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        // Fall back to passthrough if the requested preset isn't compatible with the source.
        let compatible = await AVAssetExportSession.compatibility(ofExportPreset: quality.exportPreset, with: asset, outputFileType: .mp4)
        let preset = compatible ? quality.exportPreset : AVAssetExportPreset1280x720

        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaUploadError.uploadFailed("Cannot create video export session")
        }

        let progressTask: Task<Void, Never>? = onProgress.map { cb in
            Task {
                for await state in export.states(updateInterval: 0.3) {
                    if case .exporting(let progress) = state {
                        cb(progress.fractionCompleted)
                    }
                }
            }
        }
        defer { progressTask?.cancel() }

        try await export.export(to: outputURL, as: .mp4)
        onProgress?(1.0)
        return outputURL
    }

    /// Orientation-corrected display dimensions of a video's first video track.
    private static func videoDisplayDimensions(_ asset: AVURLAsset) async -> (Int?, Int?) {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return (nil, nil)
        }
        let applied = size.applying(transform)
        return (Int(abs(applied.width)), Int(abs(applied.height)))
    }

    /// Persist the full plaintext of a just-sent media item under its `mediaId`, into the
    /// same memory + disk cache the download path reads. The sender's bubble/gallery then
    /// resolve full quality via the normal `downloadAndDecryptMedia` cache-first path —
    /// no network, no low-res-thumbnail fallback.
    /// Seed the local caches with something we just uploaded. Called from `uploadWithRetry` for
    /// every path — see the note there.
    func cacheSentMedia(_ plaintext: Data, mediaId: String) {
        saveToDiskcache(plaintext, mediaId: mediaId)
        storeInMemoryCache(plaintext, mediaId: mediaId)
        // The quota used to be enforced only on the download path, so sent media grew the disk
        // cache with nothing bounding it until the user happened to receive something. That was
        // survivable while only images and video came through here; now every upload does.
        evictToQuota()
    }

    /// Pixel dimensions of an image (nil when unavailable).
    private static func pixelDimensions(of image: PlatformImage?) -> (Int?, Int?) {
        guard let image else { return (nil, nil) }
        #if canImport(UIKit)
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
        #else
        return (Int(image.size.width), Int(image.size.height))
        #endif
    }

    /// Uploads data with up to 2 automatic retries on transient gRPC/VEIL stream failures.
    /// Checks MediaSendCache first — identical plaintext within the 30-minute TTL window
    /// skips re-encryption and re-upload entirely.
    static func uploadWithRetry(
        data: Data,
        mimeType: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaServiceClient.UploadedMedia {
        // Cache hit: same plaintext already uploaded recently → reuse mediaId + AES key.
        // Safe: the key is carried inside the DR-encrypted message payload, so each
        // recipient still gets an independent encrypted envelope.
        if let cached = await MediaSendCache.shared.cachedUpload(for: data) {
            Log.info("Media send cache hit — reusing \(cached.mediaId)", category: "MediaManager")
            onProgress?(1.0)
            MediaManager.shared.cacheSentMedia(data, mediaId: cached.mediaId)
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
                let result = try await MediaServiceClient.shared.uploadData(data, mimeType: mimeType, onProgress: onProgress)
                onProgress?(1.0)
                await MediaSendCache.shared.storeUpload(result, for: data)
                // Keep the plaintext locally so the SENDER never re-downloads their own upload.
                //
                // This used to be the caller's job, and three of the six upload paths did it while
                // three did not — so playing back your own voice note fetched it from the server,
                // seconds after the microphone produced it. There is nothing to decide here and no
                // reason for a caller to know about it: every successful upload passes through this
                // function, so the cache is seeded here and the per-path calls are gone.
                //
                // `data` is exactly what went to the server on every path (video: the transcoded
                // bytes; file: the possibly-ZLIB-compressed bytes), which is also exactly what
                // `downloadAndDecryptMedia` returns — so a cache hit and a download are the same
                // value, not merely similar ones.
                MediaManager.shared.cacheSentMedia(data, mediaId: result.mediaId)
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
    
    // MARK: - Thumbnail Operations
    
    /// Generate thumbnail from UIImage
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    /// - Parameter maxSize: **ignored.** `MediaOptimizer` owns the thumbnail dimension and byte
    ///   budget; this parameter has never been forwarded. It stayed in the signature for the
    ///   existing callers, but the log used to print it — claiming "maxSize: 250.0" while the
    ///   optimizer rendered 400px — so it is no longer reported as if it applied.
    func generateThumbnail(from image: PlatformImage, maxSize: CGFloat = 250) -> Data? {
        Log.debug("Generating thumbnail", category: "MediaManager")
        
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
        // macOS: use explicit bitmap rep to avoid HDR gain map / CGBitmap delegate warnings on certain images
        let dest = NSImage(size: thumbnailSize)
        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(thumbnailSize.width),
            pixelsHigh: Int(thumbnailSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) {
            bitmap.size = thumbnailSize
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = ctx
                // Draw source without forcing HDR headroom mismatch
                image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                           from: NSRect(origin: .zero, size: size),
                           operation: .copy, fraction: 1.0)
            }
            NSGraphicsContext.restoreGraphicsState()
            dest.addRepresentation(bitmap)
        } else {
            dest.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                       from: NSRect(origin: .zero, size: size),
                       operation: .copy, fraction: 1.0)
            dest.unlockFocus()
        }
        return dest
        #endif
    }
    
    // MARK: - Thumbnail Storage

    /// These used to live in UserDefaults — the header here said "temporary solution" and it was
    /// still true four months later, at 37 MB across 994 keys and nine times the CFPreferences
    /// limit. `ThumbnailStore` holds the reasoning; these three stay as the call-site API because
    /// twelve views and two services already speak it.

    func storeThumbnail(_ thumbnailData: Data, for messageId: String, at index: Int = 0) {
        ThumbnailStore.shared.store(thumbnailData, for: messageId, at: index)
        Log.debug("Stored thumbnail[\(index)] for message: \(messageId)", category: "MediaManager")
    }

    func retrieveThumbnail(for messageId: String, at index: Int = 0) -> Data? {
        ThumbnailStore.shared.load(for: messageId, at: index)
    }

    func retrieveThumbnail(for messageId: String) -> Data? {
        retrieveThumbnail(for: messageId, at: 0)
    }

    func removeThumbnail(for messageId: String) {
        ThumbnailStore.shared.remove(for: messageId)
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
