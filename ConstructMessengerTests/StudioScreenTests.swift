//
//  StudioScreenTests.swift
//  ConstructMessengerTests
//
//  The host's screen in Studio, without WebRTC (`decisions/studio-mode-on-desktop.md`, step 5):
//  the capture's size, the screen's section found in an offer, and the guest's hold that keeps
//  the picture with the sound. Each test names the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

final class StudioScreenTests: XCTestCase {

    // MARK: Size

    /// A 5K display comes down to 1440p, aspect kept; a small one is not blown up.
    ///
    /// Mutation: drop the `1` from `min` — a 1080p display is scaled up to 1440p; this reddens.
    /// Mutation: scale by width alone — a tall display comes out higher than 1440; this reddens.
    func testTheCaptureFitsAbout1440pAndNeverGrows() {
        XCTAssertEqual(StudioScreen.fit(width: 5_120, height: 2_880).width, 2_560)
        XCTAssertEqual(StudioScreen.fit(width: 5_120, height: 2_880).height, 1_440)
        XCTAssertEqual(StudioScreen.fit(width: 1_920, height: 1_080).width, 1_920)
        XCTAssertEqual(StudioScreen.fit(width: 1_920, height: 1_080).height, 1_080)
        let tall = StudioScreen.fit(width: 3_024, height: 1_964)
        XCTAssertLessThanOrEqual(tall.height, 1_440)
        XCTAssertLessThanOrEqual(tall.width, 2_560)
        XCTAssertEqual(Double(tall.width) / Double(tall.height), 3_024.0 / 1_964.0, accuracy: 0.01)
    }

    /// The encoder's 4:2:0 frames have even sides.
    ///
    /// Mutation: drop `& ~1` — this reddens.
    func testTheCaptureHasEvenSides() {
        let odd = StudioScreen.fit(width: 3_457, height: 2_235)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
        XCTAssertEqual(StudioScreen.fit(width: 0, height: 100).width, 0)
    }

    // MARK: The screen's section

    /// The screen is the video section whose msid names Studio's stream, wherever it stands; the
    /// camera's section is not it.
    ///
    /// Mutation: return the first video section's mid — the camera's ("1") is returned; this
    /// reddens.
    func testTheScreenSectionIsFoundByItsStream() {
        let offer = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:0", "a=msid:audio a0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=mid:1", "a=msid:video video0",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "a=mid:2",
            "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=mid:3", "a=sendonly", "a=msid:studio-screen studio-screen0",
        ].joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(StudioOffer.screenMid(sdp: offer), "3")

        let screenFirst = [
            "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=msid:studio-screen studio-screen0", "a=mid:4",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:5",
        ].joined(separator: "\r\n")
        XCTAssertEqual(StudioOffer.screenMid(sdp: screenFirst), "4", "msid before mid, section not last")
    }

    func testAnOfferWithoutAScreenHasNoScreenSection() {
        let offer = [
            "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=mid:1", "a=msid:video video0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:2",
        ].joined(separator: "\r\n")
        XCTAssertNil(StudioOffer.screenMid(sdp: offer))
        // A stream whose id only starts like the screen's is not it.
        XCTAssertNil(StudioOffer.screenMid(sdp: "m=video 9 X 96\r\na=mid:1\r\na=msid:studio-screen-2 t\r\n"))
    }

    // MARK: The hold

    /// A frame is shown `delay` after it arrived, not before.
    ///
    /// Mutation: drop `+ delay` in `due` — the frame is shown on arrival; this reddens.
    func testAFrameWaitsForItsDelay() {
        var hold = StudioScreenDelay<Int>(delay: 0.4)
        hold.arrive(1, at: 10.0)
        XCTAssertNil(hold.due(at: 10.0))
        XCTAssertNil(hold.due(at: 10.39))
        XCTAssertEqual(hold.due(at: 10.401), 1)
        XCTAssertNil(hold.due(at: 11), "a frame is shown once")
    }

    /// Of the frames due at once, the newest is shown and the older ones go; frames not yet due
    /// stay.
    ///
    /// Mutation: return the first due frame — the oldest is shown, the cursor lags the sound;
    /// this reddens.
    /// Mutation: `removeFirst(last)` — the shown frame stays and is shown again; this reddens.
    func testTheNewestDueFrameIsShownAndTheOlderOnesDropped() {
        var hold = StudioScreenDelay<Int>(delay: 0.4)
        hold.arrive(1, at: 10.00)
        hold.arrive(2, at: 10.03)
        hold.arrive(3, at: 10.06)
        hold.arrive(4, at: 10.50)
        XCTAssertEqual(hold.due(at: 10.47), 3)
        XCTAssertEqual(hold.count, 1, "1 and 2 dropped, 4 waits")
        XCTAssertNil(hold.due(at: 10.6))
        XCTAssertEqual(hold.due(at: 10.95), 4)
    }

    /// Past its capacity the hold lets the oldest go, so a stalled view cannot pile up frames.
    ///
    /// Mutation: drop the capacity check — this reddens.
    func testTheHoldIsBounded() {
        var hold = StudioScreenDelay<Int>(delay: 0.4, capacity: 3)
        for n in 1...5 { hold.arrive(n, at: Double(n)) }
        XCTAssertEqual(hold.count, 3)
        XCTAssertEqual(hold.due(at: 3.5), 3, "1 and 2 were let go")
    }
}
