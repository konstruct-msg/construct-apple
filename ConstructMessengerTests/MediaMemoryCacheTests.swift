//
//  MediaMemoryCacheTests.swift
//  ConstructMessengerTests
//
//  Build 586: one 11.8 MB video landed in the in-memory media cache
//  (`Cached media (12890KB / 51200KB)`) while the user hopped between media
//  chats and resident climbed toward ~460 MB. The dict-backed cache only
//  refused *new* inserts past 50 MB and never dropped large blobs. These
//  pure decisions pin the new rules: large items stay disk-only.
//

import XCTest
@testable import Construct_Messenger

final class MediaMemoryCacheTests: XCTestCase {

    /// The smoking gun from the log — a full video must never be admitted to RAM.
    func testElevenMegabyteVideoIsNotCachedInMemory() {
        let videoBytes = 11_891_380  // log: Media decrypted: 11891380 bytes
        XCTAssertFalse(
            MediaManager.shouldCacheInMemory(byteCount: videoBytes),
            "build 586 put this blob in mediaCache; it must stay disk-only"
        )
    }

    func testTypicalChatImageIsCachedInMemory() {
        // ~200 KB JPEG thumbnail/bubble payload
        XCTAssertTrue(MediaManager.shouldCacheInMemory(byteCount: 200_000))
    }

    func testBoundaryAtMaxItemBytes() {
        let max = MediaManager.maxMemoryItemBytes
        XCTAssertTrue(MediaManager.shouldCacheInMemory(byteCount: max))
        XCTAssertFalse(MediaManager.shouldCacheInMemory(byteCount: max + 1))
    }

    func testZeroAndNegativeNeverCache() {
        XCTAssertFalse(MediaManager.shouldCacheInMemory(byteCount: 0))
        XCTAssertFalse(MediaManager.shouldCacheInMemory(byteCount: -1))
    }

    /// Max item is a deliberate decision, not a habit — keep it in a band that fits
    /// chat photos but excludes video / original HEIC dumps.
    func testMaxMemoryItemIsInAReasonableBand() {
        XCTAssertGreaterThanOrEqual(MediaManager.maxMemoryItemBytes, 512 * 1024)
        XCTAssertLessThanOrEqual(MediaManager.maxMemoryItemBytes, 4 * 1024 * 1024)
    }
}
