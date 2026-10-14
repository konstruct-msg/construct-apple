import XCTest
#if canImport(MediaPlayer)
import MediaPlayer
#endif
@testable import Construct_Messenger

/// A music file in a chat: the slider's times, the lock screen's view of it and its buttons, and
/// the track's own speed through a pause (2026-10-14).
@MainActor
final class AudioFilePlayerTests: XCTestCase {

    private let player = AudioPlayerService.shared

    override func tearDown() {
        player.stop()
        super.tearDown()
    }

    /// One second of silence, 8 kHz 16-bit mono.
    private func silence(seconds: Int = 2) -> Data {
        let rate = 8000, samples = rate * seconds, bytes = samples * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        return d
    }

    func testTheSliderTimesSplitTheTrack() {
        let t = AudioPosition.times(fraction: 0.25, duration: 200)
        XCTAssertEqual(t.elapsed, 50, accuracy: 0.001)
        XCTAssertEqual(t.remaining, 150, accuracy: 0.001)
        XCTAssertEqual(AudioPosition.times(fraction: 1.5, duration: 10).remaining, 0, accuracy: 0.001)
    }

    #if canImport(MediaPlayer)
    func testTheLockScreenShowsTheTrackByItsNameAndKnowsAPause() {
        let info = NowPlaying.info(.init(title: "Blur Quantum - Pulsar.mp3", duration: 180, elapsed: 30, isPlaying: false))
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Blur Quantum - Pulsar")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval, 30)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertNil(info[MPMediaItemPropertyArtist], "nothing about the chat goes to the lock screen")
    }
    #endif

    func testTheLockScreenButtonsDriveTheLoadedTrack() {
        XCTAssertFalse(player.pauseCurrent(), "nothing loaded — the button is greyed")
        player.togglePlay(mediaId: "m-lock", data: silence(), naturalRate: true, title: "a.wav")
        XCTAssertTrue(player.pauseCurrent())
        XCTAssertTrue(player.isPaused)
        XCTAssertTrue(player.seekCurrent(to: 1))
        XCTAssertEqual(player.elapsed, 1, accuracy: 0.05)
        XCTAssertTrue(player.toggleCurrent())
        XCTAssertFalse(player.isPaused)
    }

    /// Music plays at its own speed after a pause, whatever speed voice messages use.
    func testAMusicTrackResumesAtItsOwnSpeed() {
        let original = player.rate
        while player.rate != 2 { player.cycleRate() }
        defer { while player.rate != original { player.cycleRate() } }

        player.togglePlay(mediaId: "m-rate", data: silence(), naturalRate: true, title: "a.wav")
        player.togglePlay(mediaId: "m-rate", data: Data(), naturalRate: true, title: "a.wav") // pause
        player.togglePlay(mediaId: "m-rate", data: Data(), naturalRate: true, title: "a.wav") // resume
        XCTAssertEqual(player.currentRate, 1, accuracy: 0.001)
    }
}
