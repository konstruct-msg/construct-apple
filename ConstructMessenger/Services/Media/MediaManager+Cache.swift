//
//  MediaManager+Cache.swift
//  Construct Messenger
//
//  MediaManager: persistent disk cache, memory cache and eviction. Split out of MediaManager.swift.
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
    /// Durable plaintext cache. `nonisolated` so HistorySync can import/export
    /// on a background context without hopping to the main actor.
    nonisolated static var onDiskDirectory: URL {
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
    }

    var mediaDirectory: URL { Self.onDiskDirectory }


    private func diskCacheURL(for mediaId: String) -> URL {
        mediaDirectory.appendingPathComponent(mediaId)
    }

    nonisolated static func onDiskURL(for mediaId: String) -> URL {
        onDiskDirectory.appendingPathComponent(mediaId)
    }

    /// What a media file is sealed to: its id, so a file renamed to another id does not open.
    nonisolated static func sealContext(for mediaId: String) -> String {
        "media/\(mediaId)"
    }

    nonisolated static func hasOnDiskFile(mediaId: String) -> Bool {
        FileManager.default.fileExists(atPath: onDiskURL(for: mediaId).path)
    }

    /// Import a CTH1 blob. Does not rewrite an existing file and does not evict.
    /// - Returns: `false` if the file was already present.
    @discardableResult
    nonisolated static func importHistoryBlob(_ data: Data, mediaId: String) -> Bool {
        let url = onDiskURL(for: mediaId)
        if FileManager.default.fileExists(atPath: url.path) { return false }
        return AtRestFiles.write(data, to: url, context: sealContext(for: mediaId))
    }

    nonisolated static func onDiskFileSize(mediaId: String) -> UInt64? {
        AtRestFiles.clearSize(of: onDiskURL(for: mediaId))
    }

    nonisolated static func loadOnDisk(mediaId: String) -> Data? {
        AtRestFiles.read(onDiskURL(for: mediaId), context: sealContext(for: mediaId))
    }

    func saveToDiskcache(_ data: Data, mediaId: String) {
        AtRestFiles.write(data, to: diskCacheURL(for: mediaId), context: Self.sealContext(for: mediaId))
    }

    func loadFromDiskCache(mediaId: String) -> Data? {
        if let data = AtRestFiles.read(diskCacheURL(for: mediaId), context: Self.sealContext(for: mediaId)) {
            return data
        }

        // Not migrated yet. Move it rather than copy: two copies of a video is not a rounding error.
        let legacy = legacyCacheDirectory.appendingPathComponent(mediaId)
        guard let data = try? Data(contentsOf: legacy) else { return nil }
        if AtRestFiles.write(data, to: diskCacheURL(for: mediaId), context: Self.sealContext(for: mediaId)) {
            try? FileManager.default.removeItem(at: legacy)
        }
        return data
    }

    /// Seals every media file still in the clear — written before 2026-09-30, when media lay open
    /// in the container. Streaming, so a video is not loaded whole. Launch, background.
    nonisolated static func sealClearFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: onDiskDirectory, includingPropertiesForKeys: nil
        ) else { return }
        var sealed = 0
        for url in entries where !url.lastPathComponent.hasPrefix(".") {
            if AtRestFiles.sealInPlace(url, context: sealContext(for: url.lastPathComponent)) { sealed += 1 }
        }
        if sealed > 0 { Log.info("Media: sealed \(sealed) clear file(s)", category: "MediaManager") }
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
                AtRestFiles.sealInPlace(destination, context: Self.sealContext(for: source.lastPathComponent))
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
    func evictToQuota() {
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

    func memoryCachedData(for mediaId: String) -> Data? {
        mediaCache.object(forKey: mediaId as NSString) as Data?
    }

    func storeInMemoryCache(_ data: Data, mediaId: String) {
        guard Self.shouldCacheInMemory(byteCount: data.count) else {
            Log.debug(
                "Skip memory cache for \(mediaId.prefix(8))… (\(data.count / 1024)KB > \(Self.maxMemoryItemBytes / 1024)KB) — disk only",
                category: "MediaManager"
            )
            return
        }
        mediaCache.setObject(data as NSData, forKey: mediaId as NSString, cost: data.count)
    }

    func clearMemoryCache(reason: String) {
        mediaCache.removeAllObjects()
        Log.info("Media memory cache cleared (\(reason))", category: "MediaManager")
    }

}
