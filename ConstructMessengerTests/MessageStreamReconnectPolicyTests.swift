//
//  MessageStreamReconnectPolicyTests.swift
//  ConstructMessengerTests
//
//  Build 587 (device 4D5928CB, 19:19–19:22):
//
//      MessageStream open timed out — reconnecting
//      MessageStream reconnecting immediately (VEIL=false)
//      …repeat while app flapped active/background…
//      RUNTIME cpu=150–216% thermal=serious
//
//  Two pure decisions caused the thrash:
//   1. Open-timeout always continued immediately, even on the same path (H2 after H2).
//   2. `isActivelyConnecting` was false during backoff (`retryCount > 0`), so foreground
//      settle forceReconnect'd a live connectLoop.
//

import XCTest
@testable import Construct_Messenger

final class MessageStreamReconnectPolicyTests: XCTestCase {

    // MARK: - Open timeout disposition

    /// The one case that may skip backoff: H3 on direct failed, try H2 once.
    func testH3DirectTimeout_IsImmediateH2Failover() {
        XCTAssertEqual(
            MessageStreamManager.openTimeoutDisposition(
                lastTransportWasFastUdp: true,
                prefersVEIL: false,
                routingKeyUnchanged: true,
                wasDirectRouting: true
            ),
            .immediateTransportFailover
        )
    }

    /// The defect: same-path open timeout (H2, or already failed over) must not tight-loop.
    func testSamePathOpenTimeout_UsesBackoff() {
        XCTAssertEqual(
            MessageStreamManager.openTimeoutDisposition(
                lastTransportWasFastUdp: false,
                prefersVEIL: false,
                routingKeyUnchanged: true,
                wasDirectRouting: true
            ),
            .exponentialBackoff,
            "H2 open timeout must not reconnect immediately (587 storm)"
        )
    }

    func testOpenTimeoutWhileVEILPreferred_UsesBackoff() {
        XCTAssertEqual(
            MessageStreamManager.openTimeoutDisposition(
                lastTransportWasFastUdp: true,
                prefersVEIL: true,
                routingKeyUnchanged: true,
                wasDirectRouting: true
            ),
            .exponentialBackoff
        )
    }

    func testOpenTimeoutWhenRoutingKeyChanged_UsesBackoff() {
        XCTAssertEqual(
            MessageStreamManager.openTimeoutDisposition(
                lastTransportWasFastUdp: true,
                prefersVEIL: false,
                routingKeyUnchanged: false,
                wasDirectRouting: true
            ),
            .exponentialBackoff
        )
    }

    // MARK: - isActivelyConnecting

    /// A connectLoop mid-backoff still owns the stream — foreground must not forceReconnect.
    func testConnectLoopInBackoff_IsStillActivelyConnecting() {
        XCTAssertTrue(
            MessageStreamManager.isActivelyConnecting(hasStreamTask: true, isConnected: false),
            "retryCount must not gate this — backoff is still a live connectLoop"
        )
    }

    func testLiveStream_IsNotActivelyConnecting() {
        XCTAssertFalse(
            MessageStreamManager.isActivelyConnecting(hasStreamTask: true, isConnected: true)
        )
    }

    func testIdle_IsNotActivelyConnecting() {
        XCTAssertFalse(
            MessageStreamManager.isActivelyConnecting(hasStreamTask: false, isConnected: false)
        )
    }
}
