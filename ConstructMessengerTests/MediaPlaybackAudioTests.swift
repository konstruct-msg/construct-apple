//
//  MediaPlaybackAudioTests.swift
//  ConstructMessengerTests
//
//  A video the person opens plays in `.playback`, which the silent switch does not mute
//  (2026-10-20: gallery videos and video files played silent on a phone in silent mode).
//

#if os(iOS)
import AVFoundation
import XCTest
@testable import Construct_Messenger

final class MediaPlaybackAudioTests: XCTestCase {

    override func tearDown() {
        MediaPlaybackAudio.deactivate()
        super.tearDown()
    }

    /// Mutation: set `.ambient` or `.soloAmbient` — both are muted by the switch — this reddens.
    func testAVideoPlaysInTheCategoryTheSilentSwitchLeavesAlone() {
        MediaPlaybackAudio.activate()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }

    /// Every player of a video the person opened asks for it. Mutation: drop the call from either
    /// file — this reddens.
    func testEveryOpenedVideoActivatesPlayback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (path, calls) in [
            "ConstructMessenger/Views/Chat/MediaGalleryViewer.swift": 2,
            "ConstructMessenger/Views/Chat/FileAttachmentBubbleView.swift": 1,
        ] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "MediaPlaybackAudio.activate()").count - 1, calls, path)
        }
    }
}
#endif
