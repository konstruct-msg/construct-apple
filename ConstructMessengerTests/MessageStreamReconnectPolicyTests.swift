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

    // MARK: - Live-stream skip on a path change

    /// Device log 2026-08-24: QUIC connected in 85ms at 09:43:19, the interface flipped at
    /// 09:43:26, the reconnect was skipped as "already live", and the stream then spent 35s
    /// sending into a path the peer could not answer (`tx_pkts=42 rx_pkts=16`) before the idle
    /// timeout disabled QUIC for the rest of the session.
    func testFastUdpStream_IsReconnectedOnPathChange() {
        XCTAssertTrue(
            MessageStreamManager.mustReconnectDespiteLiveStream(
                reason: MessageStreamManager.networkPathChangeReason,
                liveStreamIsFastUdp: true
            ),
            "the routing key survives a WiFi↔cellular handoff; the QUIC connection does not"
        )
    }

    /// The skip's original purpose: VEIL probe → `setVeilPort` posts a routing change for a
    /// stream that already moved. Tearing that down is the dual-accept receipt storm.
    func testFastUdpStream_KeepsSkipForNonPathReasons() {
        XCTAssertFalse(
            MessageStreamManager.mustReconnectDespiteLiveStream(
                reason: "veilPortChanged",
                liveStreamIsFastUdp: true
            )
        )
    }

    /// H2 is unaffected: TCP either survives the handoff or fails loudly, and that case belongs
    /// to the heartbeat watchdog rather than to an unconditional teardown on every flap.
    func testH2Stream_KeepsSkipOnPathChange() {
        XCTAssertFalse(
            MessageStreamManager.mustReconnectDespiteLiveStream(
                reason: MessageStreamManager.networkPathChangeReason,
                liveStreamIsFastUdp: false
            )
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
