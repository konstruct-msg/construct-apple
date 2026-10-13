//
//  StreamHeartbeatScheduleTests.swift
//  ConstructMessengerTests
//
//  2026-08-10, two phones on one Wi-Fi, VPN and VEIL off on the sending device. Messages went out
//  and nothing ever came back. The host was not blocked and DPI was not involved:
//
//      17:32:04  sendMessage … event=rpc-ok(via=direct, 229ms)      ← unary, same host:port
//      17:32:13  openStream transport=H2 → ams.konstruct.cc:443
//      17:32:15  MessageStream open timed out — reconnecting        ← stream, 2000ms, same channel
//      … repeated every reconnect, cursor frozen at 1786354222051-0 for the whole session
//
//  A gRPC server-streaming handler flushes no response headers until it has something to send.
//  The heartbeat loop slept before its first send, so the client subscribed and then said nothing
//  for 25s; with no queued backlog the server answered nothing, and the 2.0s direct accept
//  timeout read that silence as a dead transport. The peer device looked fine only because it was
//  on VEIL, whose accept budget is 20s.
//
//  This had been masked: until the task-group fix earlier the same day, the accept timeout could
//  not leave its group until the stream task ended, and by then the server's eventual headers had
//  set isConnected — so the `catch` swallowed the timeout and kept the stream. Enforcing the
//  timeout correctly is what made the real defect reachable.
//

import XCTest
@testable import Construct_Messenger

final class StreamHeartbeatScheduleTests: XCTestCase {

    func testTheFirstHeartbeatIsImmediate() {
        // The whole incident in one assertion: 25s of client silence on a fresh stream is 25s in
        // which a quiet server has no reason to flush headers, against a 2s accept budget.
        XCTAssertEqual(StreamHeartbeatSchedule.delayBeforeHeartbeat(index: 0), 0)
    }

    /// After the first, the client says nothing on its own (2026-10-13): the server sends
    /// heartbeats itself, and a second fixed period on the wire is one more for an observer.
    func testThereIsNoSecondHeartbeat() {
        for index in 1...10 {
            XCTAssertNil(StreamHeartbeatSchedule.delayBeforeHeartbeat(index: index), "heartbeat #\(index)")
        }
    }

    func testTheScheduleIsDefinedForADegenerateIndex() {
        // A negative index can only come from a caller bug; it must not delay the one that matters.
        XCTAssertEqual(StreamHeartbeatSchedule.delayBeforeHeartbeat(index: -1), 0)
    }

    func testTheFirstSendHappensBeforeTheAcceptTimeout() {
        // Stated as elapsed time rather than as a delay, because that is the property the server
        // cares about: it must hear from us inside the accept budget. 2.0s is
        // NetworkTiming.GRPC.streamOpenAcceptTimeout.
        let elapsedBeforeFirstSend = StreamHeartbeatSchedule.delayBeforeHeartbeat(index: 0) ?? .infinity
        XCTAssertLessThan(
            elapsedBeforeFirstSend,
            NetworkTiming.GRPC.streamOpenAcceptTimeout,
            "the client must speak before the accept timeout fires, or a healthy stream is torn down"
        )
    }
}
