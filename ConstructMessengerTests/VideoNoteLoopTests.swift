//
//  VideoNoteLoopTests.swift
//  ConstructMessengerTests
//
//  `AVQueuePlayer.loop(_:timeRange:replacing:)` (VideoNoteBubbleView.swift). A second
//  `AVPlayerLooper` over a queue that still holds the first one's items throws an Objective-C
//  exception — the video-note crash of 0.22.5…0.26.16. A failure here is the test process dying.
//

import XCTest
import AVFoundation
@testable import Construct_Messenger

@MainActor
final class VideoNoteLoopTests: XCTestCase {

    /// The bubble's case: a load that was not stopped by its cancellation, then its successor.
    func testLoopingAgainOnTheSamePlayerReplacesTheLoop() async throws {
        let url = try await VideoNoteTrimTests.writeClip(seconds: 1)
        let player = AVQueuePlayer()
        let first = player.loop(AVPlayerItem(url: url), replacing: nil)
        player.play()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(player.items().isEmpty, "the first loop must have queued its items, or nothing was tested")

        let second = player.loop(AVPlayerItem(url: url), replacing: first)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(first.status, .cancelled)
        XCTAssertNotEqual(second.status, .failed)
        XCTAssertFalse(player.items().isEmpty)
    }

    /// The review screen's case: every move of a trim handle loops a new range.
    func testMovingTheTrimRangeReplacesTheLoop() async throws {
        let url = try await VideoNoteTrimTests.writeClip(seconds: 2)
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        for end in [2.0, 1.5, 1.0] {
            looper = player.loop(
                AVPlayerItem(url: url),
                timeRange: CMTimeRange(start: .zero, end: CMTime(seconds: end, preferredTimescale: 600)),
                replacing: looper
            )
            player.play()
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNotEqual(looper?.status, .failed)
        player.stopLooping(looper)
        XCTAssertTrue(player.items().isEmpty)
    }
}
