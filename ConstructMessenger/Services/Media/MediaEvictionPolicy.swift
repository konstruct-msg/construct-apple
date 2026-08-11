//
//  MediaEvictionPolicy.swift
//  Construct Messenger
//
//  Which downloaded media may be deleted to reclaim space, and which is the only copy left.
//
//  The server keeps an uploaded object for 7 days from upload; downloads do not extend it
//  (media-service MEDIA_FILE_TTL_SECONDS). After that the blob is gone for everyone. So a photo
//  the user received nine days ago exists in exactly one place: this device.
//
//  Until 2026-08-11 that place was `Library/Caches/media/`, which iOS is free to purge whenever
//  the disk gets tight, and which our own quota sweep emptied oldest-first — i.e. it deleted
//  precisely the files that could never come back, and kept the ones that could. Both mechanisms
//  destroyed irreplaceable data while looking like ordinary cache management.
//
//  The store moved to Application Support. This is the other half: eviction now prefers what is
//  still re-downloadable.
//

import Foundation

enum MediaEvictionPolicy {

    /// How long the server keeps an uploaded object, from upload.
    ///
    /// Mirrors `MEDIA_FILE_TTL_SECONDS` in media-service. If that changes server-side this must
    /// change with it — a value that is too large here silently starts deleting irreplaceable
    /// files again, which is the failure this whole type exists to prevent. Too small only costs
    /// disk.
    static let serverRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a downloaded file may be deleted to satisfy a storage quota.
    ///
    /// The clock we have is when *we* downloaded it, not when it was uploaded. That is enough for
    /// a one-directional guarantee, and only in one direction:
    ///
    ///   · The object existed on the server at download time, so upload ≤ download.
    ///     Therefore retention ends no later than `download + serverRetention`.
    ///   · So `sinceDownload >= serverRetention` means the server copy is **certainly** gone.
    ///     This file is the only one, and deleting it destroys the user's photo.
    ///   · `sinceDownload < serverRetention` means it *might* still be fetchable — the upload could
    ///     have been six days before we downloaded it. Not a promise, which is why re-download
    ///     failure has to stay a normal, handled outcome rather than an assertion.
    ///
    /// Note this inverts LRU on purpose: the newest files are the evictable ones. That is worse
    /// for cache hit rate and it is the correct trade — a re-download costs bytes, a wrong
    /// deletion costs the picture.
    static func mayEvict(
        secondsSinceDownload: TimeInterval,
        serverRetention: TimeInterval = serverRetention
    ) -> Bool {
        secondsSinceDownload < serverRetention
    }

    /// Files to delete, in order, to bring `totalBytes` under `quotaBytes`.
    ///
    /// Returns only what `mayEvict` allows, oldest-first within that set, and stops as soon as the
    /// quota is met. If the evictable files are not enough, it returns all of them and the caller
    /// is over quota — deliberately. Going further would mean deleting photos that exist nowhere
    /// else, and a full disk is a problem the user can see and act on; a missing photo is not.
    static func filesToEvict(
        candidates: [(id: String, bytes: Int64, secondsSinceDownload: TimeInterval)],
        totalBytes: Int64,
        quotaBytes: Int64,
        serverRetention: TimeInterval = serverRetention
    ) -> [String] {
        guard quotaBytes > 0, totalBytes > quotaBytes else { return [] }

        let evictable = candidates
            .filter { mayEvict(secondsSinceDownload: $0.secondsSinceDownload, serverRetention: serverRetention) }
            .sorted { $0.secondsSinceDownload > $1.secondsSinceDownload }   // oldest of the evictable first

        var remaining = totalBytes
        var doomed: [String] = []
        for file in evictable {
            guard remaining > quotaBytes else { break }
            doomed.append(file.id)
            remaining -= file.bytes
        }
        return doomed
    }
}
