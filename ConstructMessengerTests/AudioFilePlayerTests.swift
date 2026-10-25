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

    override func tearDown() async throws {
        player.stop()
        try await super.tearDown()
    }

    /// `seconds` of silence, 8 kHz 16-bit mono.
    static func silence(seconds: Int = 2) -> Data {
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
        player.togglePlay(mediaId: "m-lock", data: Self.silence(), naturalRate: true, title: "a.wav")
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

        player.togglePlay(mediaId: "m-rate", data: Self.silence(), naturalRate: true, title: "a.wav")
        player.togglePlay(mediaId: "m-rate", data: Data(), naturalRate: true, title: "a.wav") // pause
        player.togglePlay(mediaId: "m-rate", data: Data(), naturalRate: true, title: "a.wav") // resume
        XCTAssertEqual(player.currentRate, 1, accuracy: 0.001)
    }
}

/// The now-playing banner (2026-10-15): a track keeps playing after its chat is left, and the
/// banner — on every screen but that chat — is what still names it and controls it.
@MainActor
final class NowPlayingBannerTests: XCTestCase {

    private let player = AudioPlayerService.shared
    private let screen = ChatOnScreen.shared
    private let a = PlaybackSource(chatId: "chat-a", messageId: "msg-1", fileName: "song.wav")

    override func tearDown() async throws {
        player.stop()
        screen.disappeared(screen.chatId ?? "")
        _ = screen.takeFocus(in: a.chatId)
        _ = screen.takeJump(in: a.chatId)
        try await super.tearDown()
    }

    /// In the track's own chat the banner scrolls to the message; elsewhere it opens the chat.
    /// Mutation: always `.openChat` — the first assertion reddens.
    func testATapInTheTracksOwnChatScrollsInPlace() {
        XCTAssertEqual(ChatOnScreen.bannerTap(for: a, onScreen: a.chatId), .scrollInPlace)
        XCTAssertEqual(ChatOnScreen.bannerTap(for: a, onScreen: "chat-b"), .openChat)
        XCTAssertEqual(ChatOnScreen.bannerTap(for: a, onScreen: nil), .openChat, "the chat list, settings")
    }

    /// A jump is for the chat it names, and is taken once.
    func testAJumpIsTakenOnceByItsChat() {
        screen.requestJump(a)
        XCTAssertNil(screen.takeJump(in: "chat-b"))
        XCTAssertEqual(screen.takeJump(in: a.chatId), a.messageId)
        XCTAssertNil(screen.takeJump(in: a.chatId), "once")
    }

    func testATrackKeepsItsMessageThroughAPauseAndLosesItOnStop() {
        player.togglePlay(mediaId: "m-src", data: AudioFilePlayerTests.silence(), naturalRate: true, title: "song.wav", source: a)
        XCTAssertEqual(player.source, a)
        XCTAssertTrue(player.pauseCurrent())
        XCTAssertEqual(player.source, a, "a paused track still has its banner")

        let voice = PlaybackSource(chatId: "chat-b", messageId: "msg-2")
        player.togglePlay(mediaId: "m-voice", data: AudioFilePlayerTests.silence(), source: voice)
        XCTAssertEqual(player.source, voice, "the next track replaces it")

        player.stop()
        XCTAssertNil(player.source)
    }

    func testATrackThatEndsTakesTheBannerWithIt() {
        player.togglePlay(mediaId: "m-end", data: AudioFilePlayerTests.silence(seconds: 1), source: a)
        let ended = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated { AudioPlayerService.shared.playingMediaId == nil }
        }, evaluatedWith: nil)
        wait(for: [ended], timeout: 5)
        XCTAssertNil(player.source)
    }

    /// Pushing chat B over chat A shows B before A has gone; A leaving must not clear B.
    func testOnlyTheChatOnScreenClearsItself() {
        screen.appeared("chat-a")
        screen.appeared("chat-b")
        screen.disappeared("chat-a")
        XCTAssertEqual(screen.chatId, "chat-b")
        screen.disappeared("chat-b")
        XCTAssertNil(screen.chatId)
    }

    func testTheWayBackScrollsOnceAndOnlyInItsChat() {
        screen.requestFocus(a)
        XCTAssertNil(screen.takeFocus(in: "chat-b"))
        XCTAssertEqual(screen.takeFocus(in: "chat-a"), "msg-1")
        XCTAssertNil(screen.takeFocus(in: "chat-a"), "a later open lands where it always does")
    }
}
