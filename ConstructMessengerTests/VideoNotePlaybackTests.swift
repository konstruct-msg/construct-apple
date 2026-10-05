//
//  VideoNotePlaybackTests.swift
//  ConstructMessengerTests
//
//  The video note that plays with sound, expanded in place (`VideoNotePlayback`). Each test names
//  the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class VideoNotePlaybackTests: XCTestCase {

    private let playback = VideoNotePlayback.shared
    private let url = URL(fileURLWithPath: "/dev/null/note.mov")
    private let a = VideoNotePlayback.Key(messageId: "a", itemIndex: 0)
    private let b = VideoNotePlayback.Key(messageId: "b", itemIndex: 0)

    override func setUp() async throws {
        playback.collapse()
    }

    override func tearDown() async throws {
        playback.collapse()
    }

    /// Mutation: make a second tap re-expand — the note restarts instead of pausing.
    func testTapsExpandThenPauseThenResume() {
        playback.tap(a, url: url)
        XCTAssertEqual(playback.expanded, a)
        XCTAssertFalse(playback.isPaused)

        playback.tap(a, url: url)
        XCTAssertEqual(playback.expanded, a, "a pause keeps the note expanded")
        XCTAssertTrue(playback.isPaused)

        playback.tap(a, url: url)
        XCTAssertFalse(playback.isPaused)
    }

    /// Mutation: drop the `collapse()` at the top of `expand` — two notes play over each other.
    func testOnlyOneNoteIsExpanded() {
        playback.tap(a, url: url)
        let first = playback.player
        playback.tap(b, url: url)
        XCTAssertEqual(playback.expanded, b)
        XCTAssertFalse(playback.player === first, "the first note's player is gone")
    }

    func testScrollingAnotherNoteAwayLeavesThisOnePlaying() {
        playback.tap(a, url: url)
        playback.collapse(ifShowing: b)
        XCTAssertEqual(playback.expanded, a)
        playback.collapse(ifShowing: a)
        XCTAssertNil(playback.expanded)
        XCTAssertNil(playback.player)
    }

    /// Mutation: remove the collapse from `AudioPlayerService.play` — a voice message and the
    /// note's sound play together.
    func testAVoiceMessageFoldsTheNoteBack() {
        playback.tap(a, url: url)
        AudioPlayerService.shared.togglePlay(mediaId: "voice", data: Data())
        XCTAssertNil(playback.expanded)
        AudioPlayerService.shared.stop()
    }

    func testTheSpeedCyclesAndResetsOnCollapse() {
        playback.tap(a, url: url)
        XCTAssertEqual(playback.rate, 1)
        playback.cycleRate()
        XCTAssertEqual(playback.rate, 1.5)
        playback.cycleRate()
        XCTAssertEqual(playback.rate, 2)
        playback.cycleRate()
        XCTAssertEqual(playback.rate, 1)
        playback.cycleRate()
        playback.collapse()
        XCTAssertEqual(playback.rate, 1, "the next note starts at normal speed")
    }

    func testRateLabels() {
        XCTAssertEqual(VideoNoteBubbleView.rateLabel(1), "1×")
        XCTAssertEqual(VideoNoteBubbleView.rateLabel(1.5), "1.5×")
        XCTAssertEqual(VideoNoteBubbleView.rateLabel(2), "2×")
    }

    /// The expanded note leaves the opposite gutter free (the chat stays visible) and never
    /// shrinks below the collapsed size, whatever geometry says mid-layout.
    func testTheExpandedWidth() {
        let phone = ChatUIConstants.VideoNote.expandedWidth(in: 393)
        XCTAssertGreaterThan(phone, ChatUIConstants.VideoNote.width)
        XCTAssertLessThanOrEqual(phone, 393 - ChatUIConstants.Bubble.sideGutter)

        XCTAssertEqual(ChatUIConstants.VideoNote.expandedWidth(in: 1366), ChatUIConstants.VideoNote.maxExpandedWidth)
        XCTAssertEqual(ChatUIConstants.VideoNote.expandedWidth(in: 100), ChatUIConstants.VideoNote.width)
        XCTAssertEqual(
            ChatUIConstants.VideoNote.expandedWidth(in: .nan),
            ChatUIConstants.VideoNote.expandedWidth(in: ChatUIConstants.Bubble.defaultContainerWidth)
        )
    }
}
