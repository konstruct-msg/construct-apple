//
//  MediaVideoFileLocalTests.swift
//  ConstructMessengerTests
//
//  A video whose bytes are already on this device shows play, not download — the sender's own
//  video showed a download arrow (2026-10-14), as did any video after a relaunch.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class MediaVideoFileLocalTests: XCTestCase {

    private let mediaId = "test-media-\(UUID().uuidString.lowercased())"
    private let messageId = "test-message-\(UUID().uuidString.lowercased())"

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: MediaManager.onDiskURL(for: mediaId))
    }

    private var item: [String: Any] { ["mediaId": mediaId, "mediaType": "video/mp4"] }

    func testAVideoNowhereLocalOffersTheDownload() {
        XCTAssertFalse(MediaVideoFile.isLocal(item: item, messageId: messageId, itemIndex: 0))
        XCTAssertFalse(MediaVideoFile.isLocal(item: [:], messageId: messageId, itemIndex: 0))
    }

    /// Where a sent video lands at upload, and a received one after its download.
    func testBytesInTheMediaCacheMeanPlay() {
        XCTAssertTrue(MediaManager.importHistoryBlob(Data([1, 2, 3]), mediaId: mediaId))
        XCTAssertTrue(MediaVideoFile.isLocal(item: item, messageId: messageId, itemIndex: 0))
    }

    func testAFileAlreadyMadeForTheMessageMeansPlay() {
        MediaVideoCache.shared.store(URL(fileURLWithPath: "/tmp/x.mp4"), for: messageId, at: 1)
        XCTAssertTrue(MediaVideoFile.isLocal(item: [:], messageId: messageId, itemIndex: 1))
        XCTAssertFalse(MediaVideoFile.isLocal(item: [:], messageId: messageId, itemIndex: 0), "per item")
    }
}
