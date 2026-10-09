//
//  VoicePlaybackTests.swift
//  ConstructMessengerTests
//
//  The voice player as the bubble reads it (2026-10-09): a pause shows play, a seek moves the
//  position, the speed cycles and is kept. Each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class VoicePlaybackTests: XCTestCase {

    private let player = AudioPlayerService.shared
    private var savedRate: Any?

    override func setUp() {
        super.setUp()
        savedRate = UserDefaults.standard.object(forKey: "voice.playbackRate")
        player.stop()
    }

    override func tearDown() {
        player.stop()
        if let savedRate { UserDefaults.standard.set(savedRate, forKey: "voice.playbackRate") }
        else { UserDefaults.standard.removeObject(forKey: "voice.playbackRate") }
        super.tearDown()
    }

    /// Two seconds of silence as a 16-bit mono WAV, enough for AVAudioPlayer to load and seek.
    private func silence(seconds: Int = 2) -> Data {
        let rate: UInt32 = 8_000
        let samples = Data(count: Int(rate) * seconds * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(samples.count))
        d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count))
        d.append(samples)
        return d
    }

    /// The bug: after a pause the bubble still showed pause. Mutation: drop `isPaused = true` in
    /// `pause()` — the track reads as playing.
    func testAPauseShowsPlayAndKeepsThePlace() {
        let data = silence()
        player.togglePlay(mediaId: "v", data: data)
        XCTAssertTrue(player.isPlaying("v"))
        player.togglePlay(mediaId: "v", data: data)
        XCTAssertFalse(player.isPlaying("v"), "paused: the icon is play")
        XCTAssertTrue(player.isActive("v"), "paused: the position is still this track's")
        player.togglePlay(mediaId: "v", data: data)
        XCTAssertTrue(player.isPlaying("v"), "resumed")
    }

    /// A seek moves the position of the track that plays, and starts another one at its point.
    /// Mutation: ignore the fraction in `seek` — the progress stays at the start.
    func testASeekMovesThePosition() {
        let data = silence()
        player.seek(mediaId: "a", data: data, to: 0.5)
        XCTAssertTrue(player.isPlaying("a"), "a seek on a track not playing starts it")
        XCTAssertEqual(player.progress, 0.5, accuracy: 0.05)
        XCTAssertEqual(player.elapsed, 1, accuracy: 0.1)

        player.togglePlay(mediaId: "a", data: data) // pause
        player.seek(mediaId: "a", data: data, to: 0.25)
        XCTAssertFalse(player.isPlaying("a"), "a seek while paused stays paused")
        XCTAssertEqual(player.progress, 0.25, accuracy: 0.05)

        player.seek(mediaId: "a", data: data, to: 7)
        XCTAssertEqual(player.progress, 1, accuracy: 0.001, "past the end is the end")
    }

    /// 1 → 1.25 → 1.5 → 2 → 1, kept across tracks. Mutation: skip 1.25 in `rates`.
    func testTheSpeedCyclesAndIsKept() {
        XCTAssertEqual(AudioPlayerService.nextRate(after: 1), 1.25)
        XCTAssertEqual(AudioPlayerService.nextRate(after: 1.25), 1.5)
        XCTAssertEqual(AudioPlayerService.nextRate(after: 1.5), 2)
        XCTAssertEqual(AudioPlayerService.nextRate(after: 2), 1)
        XCTAssertEqual(AudioPlayerService.nextRate(after: 3), 1, "an unknown speed starts over")

        let before = player.rate
        player.cycleRate()
        XCTAssertEqual(player.rate, AudioPlayerService.nextRate(after: before))
        XCTAssertEqual(UserDefaults.standard.float(forKey: "voice.playbackRate"), player.rate)
    }

    /// Mutation: drop the clamp in `fraction(at:width:)` — a drag past the edge seeks past it.
    func testTheWaveformPointIsClampedToTheTrack() {
        XCTAssertEqual(VoiceScrub.fraction(at: 50, width: 200), 0.25)
        XCTAssertEqual(VoiceScrub.fraction(at: -10, width: 200), 0)
        XCTAssertEqual(VoiceScrub.fraction(at: 260, width: 200), 1)
        XCTAssertEqual(VoiceScrub.fraction(at: 10, width: 0), 0)
        XCTAssertEqual(VoiceScrub.rateLabel(1), "1×")
        XCTAssertEqual(VoiceScrub.rateLabel(1.25), "1.25×")
        XCTAssertEqual(VoiceScrub.rateLabel(2), "2×")
    }
}
