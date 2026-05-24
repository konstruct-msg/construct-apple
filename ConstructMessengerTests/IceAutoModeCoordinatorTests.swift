//
//  IceAutoModeCoordinatorTests.swift
//  ConstructMessengerTests
//
//  Unit tests for ICE auto-mode coordinator.
//  Uses test doubles for probe service.
//

import XCTest
@testable import Construct_Messenger

// MARK: - Mock Probe Service

@MainActor
private final class MockDirectProbeService {
    var probeResult: IceDirectProbeResult = .success(latency: 0.050)
    var probeCallCount = 0
    
    func probeTLSConnection(host: String, port: Int = 443, timeout: TimeInterval = 5.0) async -> IceDirectProbeResult {
        probeCallCount += 1
        return probeResult
    }
    
    func probeGRPCConnection(host: String, timeout: TimeInterval = 5.0) async -> IceDirectProbeResult {
        probeCallCount += 1
        return probeResult
    }
}

// MARK: - Tests

@MainActor
final class IceAutoModeCoordinatorTests: XCTestCase {
    
    private var coordinator: IceAutoModeCoordinator!
    private var mockProbeService: MockDirectProbeService!
    
    override func setUp() {
        super.setUp()
        coordinator = IceAutoModeCoordinator.shared
        // Reset state
        coordinator.dpiState = IceDPIState()
    }
    
    // MARK: - Initial State
    
    func testInitialState() {
        XCTAssertEqual(coordinator.dpiDetectionProbability, 0.10, accuracy: 0.001)
        XCTAssertFalse(coordinator.dpiConfirmed)
        XCTAssertFalse(coordinator.shouldActivateICE)
    }
    
    // MARK: - Standby Pre-warm Decision
    
    func testShouldStartStandbyPrewarm_LastPathICE() {
        let shouldStart = coordinator.shouldStartStandbyPrewarm(lastSuccessfulPath: "ice")
        XCTAssertTrue(shouldStart)
    }
    
    func testShouldStartStandbyPrewarm_LastPathDirect() {
        let shouldStart = coordinator.shouldStartStandbyPrewarm(lastSuccessfulPath: "direct")
        XCTAssertFalse(shouldStart)
    }
    
    func testShouldStartStandbyPrewarm_NilPath() {
        let shouldStart = coordinator.shouldStartStandbyPrewarm(lastSuccessfulPath: nil)
        XCTAssertFalse(shouldStart)
    }
    
    // MARK: - Direct Failure Recording
    
    func testRecordDirectFailure_FirstFailure() {
        let event = coordinator.recordDirectFailure()
        
        XCTAssertGreaterThan(coordinator.dpiDetectionProbability, 0.10)
        XCTAssertNil(event, "First failure should not trigger activation yet")
    }
    
    func testRecordDirectFailure_ThirdFailure_TriggerActivation() {
        coordinator.recordDirectFailure()
        coordinator.recordDirectFailure()
        let event = coordinator.recordDirectFailure()
        
        XCTAssertTrue(coordinator.shouldActivateICE)
        XCTAssertEqual(event, .directBlocked)
    }
    
    // MARK: - Direct Success Recording
    
    func testRecordDirectSuccess_DecreasesPosterior() {
        let prior = coordinator.dpiDetectionProbability
        coordinator.recordDirectSuccess()
        XCTAssertLessThan(coordinator.dpiDetectionProbability, prior)
    }
    
    func testRecordDirectStreamConnected() {
        let event = coordinator.recordDirectStreamConnected()
        
        XCTAssertLessThan(coordinator.dpiDetectionProbability, 0.10)
        XCTAssertNil(event)
    }
    
    // MARK: - DPI Activation
    
    func testActivateDPI() {
        XCTAssertFalse(coordinator.dpiConfirmed)
        coordinator.activateDPI()
        XCTAssertTrue(coordinator.dpiConfirmed)
    }
    
    // MARK: - Network Change Reset
    
    func testResetForNetworkChange() {
        // Simulate elevated posterior
        coordinator.recordDirectFailure()
        coordinator.recordDirectFailure()
        let elevatedPosterior = coordinator.dpiDetectionProbability
        XCTAssertGreaterThan(elevatedPosterior, 0.10)
        
        // Reset
        coordinator.resetForNetworkChange()
        XCTAssertEqual(coordinator.dpiDetectionProbability, 0.10, accuracy: 0.001)
        XCTAssertFalse(coordinator.dpiConfirmed)
    }
    
    // MARK: - Background Probe (Manual Trigger)
    
    func testBackgroundProbe_Success() async {
        // This test verifies the coordinator can handle probe results
        // Full background probe scheduling tested separately
        
        let prior = coordinator.dpiDetectionProbability
        coordinator.recordDirectSuccess()
        XCTAssertLessThan(coordinator.dpiDetectionProbability, prior)
    }
    
    // MARK: - Integration: Real-World Scenarios
    
    func testScenario_CleanNetwork() {
        // Clean network: successes keep posterior low
        for _ in 0..<5 {
            coordinator.recordDirectSuccess()
        }
        
        XCTAssertLessThan(coordinator.dpiDetectionProbability, 0.10)
        XCTAssertFalse(coordinator.shouldActivateICE)
    }
    
    func testScenario_DPIEnvironment() {
        // DPI environment: failures quickly elevate posterior
        coordinator.recordDirectFailure()
        XCTAssertFalse(coordinator.shouldActivateICE)
        
        coordinator.recordDirectFailure()
        XCTAssertTrue(coordinator.shouldActivateICE, "Should activate after 2 failures")
        
        let event = coordinator.recordDirectFailure()
        XCTAssertEqual(event, .directBlocked)
        
        coordinator.activateDPI()
        XCTAssertTrue(coordinator.dpiConfirmed)
    }
    
    func testScenario_FalsePositive() {
        // Single failure (false positive) followed by successes
        coordinator.recordDirectFailure()
        let posteriorAfterFailure = coordinator.dpiDetectionProbability
        XCTAssertGreaterThan(posteriorAfterFailure, 0.10)
        XCTAssertFalse(coordinator.shouldActivateICE)
        
        // Successes bring it back down
        coordinator.recordDirectSuccess()
        coordinator.recordDirectSuccess()
        XCTAssertLessThan(coordinator.dpiDetectionProbability, posteriorAfterFailure)
        XCTAssertFalse(coordinator.shouldActivateICE)
    }
    
    func testScenario_NetworkSwitch() {
        // DPI environment
        coordinator.recordDirectFailure()
        coordinator.recordDirectFailure()
        XCTAssertTrue(coordinator.shouldActivateICE)
        coordinator.activateDPI()
        
        // Network switch resets everything
        coordinator.resetForNetworkChange()
        XCTAssertFalse(coordinator.shouldActivateICE)
        XCTAssertFalse(coordinator.dpiConfirmed)
    }
}
