//
//  GRPCCallExecutorTests.swift
//  ConstructMessengerTests
//
//  Targeted tests for the P1 dual-proxy-lifecycle fix:
//  when ConnectionLoop owns the proxy (isConnectionLoopActive=true),
//  handleICEFailure() must route to ConnectionLoop, not IceProxyManager.
//
//  Test design note:
//    The two paths produce different observable state changes:
//
//    staleLocalProxy + CL active:
//      fix  → ConnectionLoop.prepare() runs → clears _overrideProxyPort → .propagate
//      bug  → IceProxyManager.restartAfterCrash() fails → port preserved → .retry
//
//    background RPC + CL active:
//      fix  → ConnectionLoop.recordFailure() → directFails incremented
//      bug  → IceProxyManager.scheduleRotation() → directFails untouched → still 0
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class GRPCCallExecutorTests: XCTestCase {

    // MARK: - isConnectionLoopActive gate

    func test_isConnectionLoopActive_falseWhenNoPortSet() {
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        XCTAssertFalse(GRPCChannelManager.shared.isConnectionLoopActive)
    }

    func test_isConnectionLoopActive_trueAfterSetDirectProxyPort() {
        GRPCChannelManager.shared.setDirectProxyPort(54321)
        XCTAssertTrue(GRPCChannelManager.shared.isConnectionLoopActive)
        GRPCChannelManager.shared.setDirectProxyPort(nil)
    }

    func test_isConnectionLoopActive_falseAfterPortCleared() {
        GRPCChannelManager.shared.setDirectProxyPort(54321)
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        XCTAssertFalse(GRPCChannelManager.shared.isConnectionLoopActive)
    }

    // MARK: - P1: staleLocalProxy routing

    /// staleLocalProxy + ConnectionLoop active → prepare() is called (clears port when
    /// shouldUseICE=false) → .propagate.
    ///
    /// Without the fix: IceProxyManager.restartAfterCrash() fails silently (no real proxy
    /// in tests), _overrideProxyPort stays 54321, iceProxyPort() returns 54321 → .retry.
    func test_staleLocalProxy_connectionLoopActive_callsPrepare_notRestartAfterCrash() async {
        CensoredNetworkDetector._testOverride = false
        await ConnectionLoop.shared.reset()  // directFails=0, shouldUseICE=false

        GRPCChannelManager.shared.setDirectProxyPort(54321)
        // No defer: prepare() will clear the port; we assert that below.

        let action = await GRPCCallExecutor.shared.handleICEFailure(
            reason: .staleLocalProxy,
            error: RPCError(code: .unavailable, message: "Connection refused (127.0.0.1:54321)"),
            invalidatesConnectionOnFailure: false
        )

        XCTAssertEqual(action, .propagate,
            "staleLocalProxy with ConnectionLoop active: prepare() must run (not restartAfterCrash)")
        XCTAssertFalse(GRPCChannelManager.shared.isConnectionLoopActive,
            "prepare() must have cleared override port (shouldUseICE=false, no ICE activation yet)")

        // Cleanup
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        CensoredNetworkDetector._testOverride = nil
        await ConnectionLoop.shared.reset()
    }

    // MARK: - P1: background RPC routing

    /// Background RPC failure + ConnectionLoop active → routes to ConnectionLoop.recordFailure(),
    /// which increments directFails. Two failures → shouldUseICE=true.
    ///
    /// Without the fix: routes to IceProxyManager.scheduleRotation() (which calls runtime.stop()
    /// on the same Rust FFI that ConnectionLoop.IceProxy manages). directFails stays 0.
    func test_backgroundRPCFailure_connectionLoopActive_routesToConnectionLoop() async {
        CensoredNetworkDetector._testOverride = false
        await ConnectionLoop.shared.reset()  // directFails=0

        GRPCChannelManager.shared.setDirectProxyPort(54321)

        let error = RPCError(code: .unavailable, message: "connection lost")
        _ = await GRPCCallExecutor.shared.handleICEFailure(
            reason: .transportUnknown, error: error, invalidatesConnectionOnFailure: false)
        _ = await GRPCCallExecutor.shared.handleICEFailure(
            reason: .transportUnknown, error: error, invalidatesConnectionOnFailure: false)

        // With fix: directFails incremented twice (0→1→2) → shouldUseICE=true
        // Without fix: scheduleRotation() runs instead → directFails stays 0 → shouldUseICE=false
        let shouldUseICE = await ConnectionLoop.shared.shouldUseICE
        XCTAssertTrue(shouldUseICE,
            "Two background RPC failures must route through ConnectionLoop.recordFailure(), not IceProxyManager.scheduleRotation()")

        // Cleanup
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        CensoredNetworkDetector._testOverride = nil
        await ConnectionLoop.shared.reset()
    }

    // MARK: - P1: legacy path preserved

    /// When ConnectionLoop is NOT active, the legacy IceProxyManager path is used.
    /// Background transport failure with no active relay → .propagate (no rotation possible).
    func test_backgroundRPCFailure_connectionLoopInactive_usesLegacyPath() async {
        GRPCChannelManager.shared.setDirectProxyPort(nil)

        let action = await GRPCCallExecutor.shared.handleICEFailure(
            reason: .transportUnknown,
            error: RPCError(code: .unavailable, message: "connection lost"),
            invalidatesConnectionOnFailure: false
        )
        XCTAssertEqual(action, .propagate)
    }
}
