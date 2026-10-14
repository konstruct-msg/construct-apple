//
//  PushWakeTests.swift
//  ConstructMessengerTests
//
//  Two decisions from the 2026-09-24 two-phone run (build 689).
//
//  ffeeddc6, direct: "Но они у тебя хотя бы приходят" was sent at 10:41:23 and
//  the banner arrived at 10:42:49. The push launch had opened a MessageStream,
//  the server treated that as online, and the next wake waited for the 109s
//  heartbeat timeout.
//
//  9a921fe2, VEIL: silent pushes arrived and every background fetch died with
//  connection refused on 127.0.0.1:62404. A background staleLocalProxy is
//  ignored, so the listener was never replaced and no banner was posted.
//

import XCTest
@testable import Construct_Messenger

final class PushWakeTests: XCTestCase {

    /// A push launch is already in the background. Opening a stream there is
    /// what suppressed the next push.
    ///
    /// Mutation: `return true` — the stream opens on the wake again.
    func testABackgroundWakeDoesNotOpenAMessageStream() {
        XCTAssertFalse(shouldOpenMessageStream(applicationIsBackground: true))
    }

    /// Foreground, and the grace period before a real background, still open.
    func testAForegroundStatusChangeStillOpensTheStream() {
        XCTAssertTrue(shouldOpenMessageStream(applicationIsBackground: false))
    }

    /// The unary fetch is the wake. Reconnecting would mark the account online.
    ///
    /// Mutation: drop the background term — `return !foregroundLiveStream`.
    func testABackgroundSilentPushDoesNotReconnectTheStream() {
        XCTAssertFalse(
            shouldReconnectStreamOnSilentPush(applicationIsBackground: true, foregroundLiveStream: false)
        )
        XCTAssertFalse(
            shouldReconnectStreamOnSilentPush(applicationIsBackground: true, foregroundLiveStream: true)
        )
    }

    /// The reconnect-storm skip stays. A live foreground stream is not torn down
    /// by the push that the message itself produced.
    func testALiveForegroundStreamIsNotReconnectedByASilentPush() {
        XCTAssertFalse(
            shouldReconnectStreamOnSilentPush(applicationIsBackground: false, foregroundLiveStream: true)
        )
    }

    /// Foreground, stream down: the push is the signal to reconnect.
    func testADownForegroundStreamStillReconnects() {
        XCTAssertTrue(
            shouldReconnectStreamOnSilentPush(applicationIsBackground: false, foregroundLiveStream: false)
        )
    }

    /// The wake replaces a dead VEIL listener. It does not count as a background
    /// RPC failure, which stays ignored.
    ///
    /// Mutation: handle `.backgroundWake` like a background `rpcFailed` — return
    /// the active state and no effects.
    func testABackgroundWakeOnVeilReplacesTheListener() {
        let active = TransportState.veilActive(
            relay: "live.nearsky.org:443",
            port: 62404,
            since: Date(timeIntervalSince1970: 1_790_246_000)
        )
        let outcome = TransportReducer.reduce(
            state: active,
            event: .backgroundWake,
            config: .default,
            now: Date(timeIntervalSince1970: 1_790_246_100)
        )
        XCTAssertEqual(outcome.state, .veilProbing)
        XCTAssertTrue(outcome.effects.contains(.requestProxyStop))
        XCTAssertTrue(outcome.effects.contains(.requestProxyStart))
        XCTAssertTrue(outcome.effects.contains(.setVeilPort(nil)))
    }

    /// A push must not move a direct phone onto the relay. ffeeddc6 was on
    /// direct; the delay there was the stream, not the path.
    ///
    /// Mutation: `return rotateRelay()` for every state.
    func testABackgroundWakeOnDirectDoesNotStartVeil() {
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .backgroundWake,
            config: .default,
            now: Date(timeIntervalSince1970: 1_790_246_100)
        )
        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 0))
        XCTAssertFalse(outcome.effects.contains(.requestProxyStart))
    }

    /// The ignore stays. A suspended RPC that finds a dead port is not, by
    /// itself, a reason to probe — that fires for every background call.
    ///
    /// Mutation: drop `foreground` from the veilActive rpcFailed guard.
    func testABackgroundStaleProxyStillDoesNotRotate() {
        let since = Date(timeIntervalSince1970: 1_790_246_000)
        let active = TransportState.veilActive(relay: "live.nearsky.org:443", port: 62404, since: since)
        let outcome = TransportReducer.reduce(
            state: active,
            event: .rpcFailed(
                kind: .staleLocalProxy,
                via: .veil(port: 62404, relay: "live.nearsky.org:443"),
                foreground: false
            ),
            config: .default,
            now: since.addingTimeInterval(30)
        )
        XCTAssertEqual(outcome.state, active)
        XCTAssertTrue(outcome.effects.isEmpty)
    }
}
