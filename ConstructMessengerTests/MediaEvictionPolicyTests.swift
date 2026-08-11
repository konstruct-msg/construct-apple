//
//  MediaEvictionPolicyTests.swift
//  ConstructMessengerTests
//
//  Found by reading the media path on 2026-08-11, not from a crash: received media lived in
//  `Library/Caches/media/`, which iOS purges under disk pressure, while the server drops an
//  uploaded object 7 days after upload regardless of downloads. A purge on day nine takes the only
//  copy in existence — and our own quota sweep was plain LRU, deleting oldest-first, which is
//  exactly the set that can never come back.
//
//  The store moved to Application Support. These pin the other half: what may be deleted.
//

import XCTest
@testable import Construct_Messenger

final class MediaEvictionPolicyTests: XCTestCase {

    private let day: TimeInterval = 24 * 60 * 60
    private let quota: Int64 = 1_000

    // MARK: - The rule

    /// Downloaded eight days ago: the object existed on the server then, so it was uploaded no
    /// later than then, so retention has certainly expired. This file is the photo.
    func testAFileOlderThanServerRetentionIsNeverEvicted() {
        XCTAssertFalse(MediaEvictionPolicy.mayEvict(secondsSinceDownload: 8 * day))
    }

    /// Downloaded an hour ago — it *might* still be fetchable. Might is all we get: the upload
    /// could have happened six days before we downloaded it, which is why a failed re-download has
    /// to remain an ordinary handled outcome rather than an impossibility.
    func testARecentFileMayBeEvicted() {
        XCTAssertTrue(MediaEvictionPolicy.mayEvict(secondsSinceDownload: 3_600))
    }

    /// Exactly at the boundary counts as expired. Off by one in the other direction deletes a
    /// photo, so the tie goes to keeping it.
    func testTheBoundaryFavoursKeeping() {
        XCTAssertFalse(
            MediaEvictionPolicy.mayEvict(secondsSinceDownload: MediaEvictionPolicy.serverRetention)
        )
    }

    // MARK: - Selection

    /// The incident, in one assertion: an old irreplaceable file and a fresh replaceable one, over
    /// quota. LRU would take the old one. The policy must take the new one.
    func testItEvictsTheReplaceableFileNotTheIrreplaceableOne() {
        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: [
                (id: "photo-from-last-month", bytes: 900, secondsSinceDownload: 30 * day),
                (id: "downloaded-today",      bytes: 900, secondsSinceDownload: 1 * day),
            ],
            totalBytes: 1_800,
            quotaBytes: quota
        )
        XCTAssertEqual(doomed, ["downloaded-today"])
    }

    /// Within the evictable set the order is still oldest-first — least likely to be looked at
    /// again, and closest to expiring anyway.
    func testOldestOfTheEvictableGoesFirst() {
        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: [
                (id: "an-hour-old",  bytes: 600, secondsSinceDownload: 3_600),
                (id: "six-days-old", bytes: 600, secondsSinceDownload: 6 * day),
            ],
            totalBytes: 1_200,
            quotaBytes: quota
        )
        XCTAssertEqual(doomed, ["six-days-old"])
    }

    /// It stops as soon as the quota is met rather than emptying the evictable set.
    func testItDeletesOnlyWhatTheQuotaRequires() {
        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: [
                (id: "a", bytes: 400, secondsSinceDownload: 5 * day),
                (id: "b", bytes: 400, secondsSinceDownload: 4 * day),
                (id: "c", bytes: 400, secondsSinceDownload: 3 * day),
            ],
            totalBytes: 1_200,
            quotaBytes: quota
        )
        XCTAssertEqual(doomed, ["a"])
    }

    /// Over quota with nothing safe to delete: return nothing and stay over. The caller logs it.
    /// Freeing space here would mean destroying the only copies, which is the failure this exists
    /// to prevent — a full disk is visible to the user, a missing photo is not.
    func testItStaysOverQuotaRatherThanDeleteTheOnlyCopies() {
        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: [
                (id: "old-1", bytes: 900, secondsSinceDownload: 20 * day),
                (id: "old-2", bytes: 900, secondsSinceDownload: 40 * day),
            ],
            totalBytes: 1_800,
            quotaBytes: quota
        )
        XCTAssertTrue(doomed.isEmpty)
    }

    // MARK: - Not firing

    func testNothingIsEvictedWhenUnderQuota() {
        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: [(id: "a", bytes: 100, secondsSinceDownload: 1 * day)],
            totalBytes: 100,
            quotaBytes: quota
        )
        XCTAssertTrue(doomed.isEmpty)
    }

    /// 0 means unlimited in settings, and an unlimited quota that deletes everything would be a
    /// spectacular way to read a config value backwards.
    func testAZeroQuotaMeansUnlimitedNotDeleteEverything() {
        let doomed = MediaEvictionPolicy.filesToEvict(
            candidates: [(id: "a", bytes: 10_000, secondsSinceDownload: 1 * day)],
            totalBytes: 10_000,
            quotaBytes: 0
        )
        XCTAssertTrue(doomed.isEmpty)
    }
}
