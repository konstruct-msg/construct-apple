//
//  IceConnectionReducerTests.swift
//  ConstructMessengerTests
//
//  Unit tests for ICE connection state machine reducer.
//  Pure function tests — no mocks, no I/O, no async.
//

import XCTest
@testable import Construct_Messenger

final class IceConnectionReducerTests: XCTestCase {
    
    // MARK: - Helper
    
    private func apply(_ event: IceConnectionEvent, to state: IceConnectionState) -> IceConnectionState {
        IceConnectionReducer.reduce(state: state, event: event)
    }
    
    // MARK: - Lifecycle Events
    
    func testStartRequested_NoStateChange() {
        let states: [IceConnectionState] = [.off, .standby(port: 12345, webTunnel: false), .active(port: 12345, webTunnel: true), .cooldown]
        for state in states {
            let next = apply(.startRequested(mode: .auto), to: state)
            XCTAssertEqual(next, state, "startRequested should not change state directly")
        }
    }
    
    func testStopRequested_ReturnsOff() {
        let states: [IceConnectionState] = [.standby(port: 12345, webTunnel: false), .active(port: 12345, webTunnel: true), .cooldown]
        for state in states {
            let next = apply(.stopRequested, to: state)
            XCTAssertEqual(next, .off, "stopRequested should return .off from any state")
        }
    }
    
    func testModeChanged_NoStateChange() {
        let state: IceConnectionState = .active(port: 12345, webTunnel: true)
        let next = apply(.modeChanged(old: .auto, new: .on), to: state)
        XCTAssertEqual(next, state, "modeChanged should not alter connection state")
    }
    
    // MARK: - Proxy Start/Stop
    
    func testProxyStarted_FromOff() {
        let next = apply(.proxyStarted(port: 54321, webTunnel: true), to: .off)
        XCTAssertEqual(next, .active(port: 54321, webTunnel: true))
    }
    
    func testProxyStarted_FromStandby() {
        let next = apply(.proxyStarted(port: 54321, webTunnel: false), to: .standby(port: 12345, webTunnel: false))
        XCTAssertEqual(next, .standby(port: 54321, webTunnel: false))
    }
    
    func testProxyStarted_FromActive() {
        let next = apply(.proxyStarted(port: 54321, webTunnel: true), to: .active(port: 12345, webTunnel: false))
        XCTAssertEqual(next, .active(port: 54321, webTunnel: true))
    }
    
    func testProxyStarted_DuringCooldown() {
        let next = apply(.proxyStarted(port: 54321, webTunnel: false), to: .cooldown)
        XCTAssertEqual(next, .cooldown, "proxy started during cooldown should stay in cooldown")
    }
    
    func testProxyStartFailed_ReturnsOff() {
        let states: [IceConnectionState] = [.off, .standby(port: 12345, webTunnel: false), .active(port: 12345, webTunnel: true)]
        for state in states {
            let next = apply(.proxyStartFailed(error: "test"), to: state)
            XCTAssertEqual(next, .off)
        }
    }
    
    func testProxyStopped_ReturnsOff() {
        let states: [IceConnectionState] = [.standby(port: 12345, webTunnel: false), .active(port: 12345, webTunnel: true)]
        for state in states {
            let next = apply(.proxyStopped, to: state)
            XCTAssertEqual(next, .off)
        }
    }
    
    // MARK: - Standby Pre-warm
    
    func testStandbyPrewarmCompleted_FromOff() {
        let next = apply(.standbyPrewarmCompleted(port: 54321, webTunnel: false), to: .off)
        XCTAssertEqual(next, .standby(port: 54321, webTunnel: false))
    }
    
    func testStandbyPrewarmCompleted_FromActive() {
        let next = apply(.standbyPrewarmCompleted(port: 54321, webTunnel: false), to: .active(port: 12345, webTunnel: true))
        XCTAssertEqual(next, .standby(port: 54321, webTunnel: false))
    }
    
    // MARK: - DPI Auto-Mode
    
    func testDpiConfirmed_FromStandby() {
        let next = apply(.dpiConfirmed, to: .standby(port: 54321, webTunnel: true))
        XCTAssertEqual(next, .active(port: 54321, webTunnel: true), "DPI confirmation should promote standby to active")
    }
    
    func testDpiConfirmed_FromActive_NoChange() {
        let state: IceConnectionState = .active(port: 54321, webTunnel: true)
        let next = apply(.dpiConfirmed, to: state)
        XCTAssertEqual(next, state)
    }
    
    func testDirectBlocked_FromStandby() {
        let next = apply(.directBlocked, to: .standby(port: 54321, webTunnel: false))
        XCTAssertEqual(next, .active(port: 54321, webTunnel: false))
    }
    
    func testDirectVerified_FromStandby_NoChange() {
        let state: IceConnectionState = .standby(port: 54321, webTunnel: false)
        let next = apply(.directVerified, to: state)
        XCTAssertEqual(next, state, "direct verified while standby should stay in standby")
    }
    
    // MARK: - Failures
    
    func testRelayFailed_FromActive_ReturnsCooldown() {
        let next = apply(.relayFailed(address: "relay:443", reason: .streamTimeout), to: .active(port: 54321, webTunnel: true))
        XCTAssertEqual(next, .cooldown)
    }
    
    func testWebTunnelBlocked_FromActive_NoStateChange() {
        let state: IceConnectionState = .active(port: 54321, webTunnel: true)
        let next = apply(.webTunnelBlocked(address: "relay:443"), to: state)
        XCTAssertEqual(next, state, "webTunnelBlocked is handled by coordinator, not state change")
    }
    
    func testForegroundProxyDead_FromActive() {
        let next = apply(.foregroundProxyDead, to: .active(port: 54321, webTunnel: true))
        XCTAssertEqual(next, .cooldown)
    }
    
    func testForegroundProxyDead_FromStandby() {
        let next = apply(.foregroundProxyDead, to: .standby(port: 54321, webTunnel: false))
        XCTAssertEqual(next, .off)
    }
    
    // MARK: - Cooldown
    
    func testCooldownStarted_FromActive() {
        let next = apply(.cooldownStarted(duration: 60), to: .active(port: 54321, webTunnel: true))
        XCTAssertEqual(next, .cooldown)
    }
    
    func testCooldownStarted_FromCooldown_NoChange() {
        let state: IceConnectionState = .cooldown
        let next = apply(.cooldownStarted(duration: 60), to: state)
        XCTAssertEqual(next, state)
    }
    
    func testCooldownExpired_FromCooldown() {
        let next = apply(.cooldownExpired, to: .cooldown)
        XCTAssertEqual(next, .off)
    }
    
    func testCooldownExpired_FromOff_NoChange() {
        let state: IceConnectionState = .off
        let next = apply(.cooldownExpired, to: state)
        XCTAssertEqual(next, state)
    }
    
    // MARK: - Network Changes
    
    func testNetworkPathChanged_FromActive() {
        let next = apply(.networkPathChanged(kind: .newInterface), to: .active(port: 54321, webTunnel: true))
        XCTAssertEqual(next, .off, "network change should reset to off for restart")
    }
    
    func testNetworkPathChanged_FromStandby() {
        let next = apply(.networkPathChanged(kind: .connectivityChanged), to: .standby(port: 54321, webTunnel: false))
        XCTAssertEqual(next, .off)
    }
    
    func testNetworkPathChanged_FromCooldown() {
        let next = apply(.networkPathChanged(kind: .newInterface), to: .cooldown)
        XCTAssertEqual(next, .off, "network change should clear cooldown")
    }
    
    // MARK: - Snapshot Derivation
    
    func testSnapshot_Off() {
        let snapshot = IceConnectionReducer.snapshot(state: .off)
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.proxyPort, 0)
        XCTAssertFalse(snapshot.isWebTunnelActive)
        XCTAssertFalse(snapshot.isStandbyPrewarm)
        XCTAssertTrue(snapshot.isOnCooldown)
    }
    
    func testSnapshot_Standby() {
        let snapshot = IceConnectionReducer.snapshot(state: .standby(port: 54321, webTunnel: false))
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertEqual(snapshot.proxyPort, 54321)
        XCTAssertFalse(snapshot.isWebTunnelActive)
        XCTAssertTrue(snapshot.isStandbyPrewarm)
        XCTAssertFalse(snapshot.isOnCooldown)
    }
    
    func testSnapshot_Active_Obfs4() {
        let snapshot = IceConnectionReducer.snapshot(state: .active(port: 54321, webTunnel: false))
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertEqual(snapshot.proxyPort, 54321)
        XCTAssertFalse(snapshot.isWebTunnelActive)
        XCTAssertFalse(snapshot.isStandbyPrewarm)
        XCTAssertFalse(snapshot.isOnCooldown)
    }
    
    func testSnapshot_Active_WebTunnel() {
        let snapshot = IceConnectionReducer.snapshot(state: .active(port: 54321, webTunnel: true))
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertEqual(snapshot.proxyPort, 54321)
        XCTAssertTrue(snapshot.isWebTunnelActive)
        XCTAssertFalse(snapshot.isStandbyPrewarm)
        XCTAssertFalse(snapshot.isOnCooldown)
    }
    
    func testSnapshot_Cooldown() {
        let snapshot = IceConnectionReducer.snapshot(state: .cooldown)
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.proxyPort, 0)
        XCTAssertFalse(snapshot.isWebTunnelActive)
        XCTAssertFalse(snapshot.isStandbyPrewarm)
        XCTAssertTrue(snapshot.isOnCooldown)
    }
}
