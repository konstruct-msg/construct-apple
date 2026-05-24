//
//  IceDPIHeuristicTests.swift
//  ConstructMessengerTests
//
//  Unit tests for Bayesian DPI detection heuristic.
//  Pure function tests — no I/O, no async, fully deterministic.
//

import XCTest
@testable import Construct_Messenger

final class IceDPIHeuristicTests: XCTestCase {
    
    // MARK: - Constants Verification
    
    func testDefaultPrior() {
        XCTAssertEqual(IceDPIHeuristic.defaultPrior, 0.10, accuracy: 0.001)
    }
    
    func testPFailGivenDPI() {
        XCTAssertEqual(IceDPIHeuristic.pFailGivenDPI, 0.90, accuracy: 0.001)
    }
    
    func testPFailGivenNoDPI() {
        XCTAssertEqual(IceDPIHeuristic.pFailGivenNoDPI, 0.05, accuracy: 0.001)
    }
    
    func testActivateThreshold() {
        XCTAssertEqual(IceDPIHeuristic.activateThreshold, 0.80, accuracy: 0.001)
    }
    
    // MARK: - Bayesian Update After Failure
    
    func testUpdateAfterFailure_FromPrior() {
        // P(DPI | fail) = P(fail | DPI) × P(DPI) / P(fail)
        // P(fail) = 0.90 × 0.10 + 0.05 × 0.90 = 0.09 + 0.045 = 0.135
        // P(DPI | fail) = 0.90 × 0.10 / 0.135 = 0.09 / 0.135 ≈ 0.667
        let posterior = IceDPIHeuristic.updateAfterFailure(prior: 0.10)
        XCTAssertEqual(posterior, 0.6667, accuracy: 0.001)
    }
    
    func testUpdateAfterFailure_SecondFailure() {
        // Starting from elevated posterior (after 1 failure)
        let prior = 0.6667
        // P(fail) = 0.90 × 0.6667 + 0.05 × 0.3333 ≈ 0.600 + 0.017 = 0.617
        // P(DPI | fail) = 0.90 × 0.6667 / 0.617 ≈ 0.972
        let posterior = IceDPIHeuristic.updateAfterFailure(prior: prior)
        XCTAssertEqual(posterior, 0.9724, accuracy: 0.001)
    }
    
    func testUpdateAfterFailure_ThirdFailure_ReachesThreshold() {
        let prior1 = IceDPIHeuristic.updateAfterFailure(prior: 0.10)
        let prior2 = IceDPIHeuristic.updateAfterFailure(prior: prior1)
        let posterior = IceDPIHeuristic.updateAfterFailure(prior: prior2)
        
        XCTAssertGreaterThanOrEqual(posterior, IceDPIHeuristic.activateThreshold)
        XCTAssertTrue(IceDPIHeuristic.shouldActivate(posterior: posterior))
    }
    
    func testUpdateAfterFailure_CapsAtMax() {
        var prior = 0.10
        for _ in 0..<10 {
            prior = IceDPIHeuristic.updateAfterFailure(prior: prior)
        }
        XCTAssertLessThan(posterior, 1.0)
        XCTAssertEqual(posterior, 0.9999, accuracy: 0.0001)
    }
    
    // MARK: - Bayesian Update After Success
    
    func testUpdateAfterSuccess_FromElevatedPosterior() {
        // After a failure, posterior is ~0.667
        let prior = 0.6667
        // P(ok) = P(ok | DPI) × P(DPI) + P(ok | no DPI) × (1 - P(DPI))
        // P(ok) = 0.10 × 0.6667 + 0.95 × 0.3333 ≈ 0.067 + 0.317 = 0.384
        // P(DPI | ok) = 0.10 × 0.6667 / 0.384 ≈ 0.174
        let posterior = IceDPIHeuristic.updateAfterSuccess(prior: prior)
        XCTAssertEqual(posterior, 0.1739, accuracy: 0.001)
    }
    
    func testUpdateAfterSuccess_FromPrior() {
        // Success from prior should decrease posterior slightly
        let posterior = IceDPIHeuristic.updateAfterSuccess(prior: 0.10)
        XCTAssertLessThan(posterior, 0.10)
        XCTAssertEqual(posterior, 0.0105, accuracy: 0.001)
    }
    
    func testUpdateAfterSuccess_FloorsAtMin() {
        var prior = 0.99
        for _ in 0..<10 {
            prior = IceDPIHeuristic.updateAfterSuccess(prior: prior)
        }
        XCTAssertGreaterThan(posterior, 0.0)
        XCTAssertEqual(posterior, 0.0001, accuracy: 0.0001)
    }
    
    // MARK: - Activation Threshold
    
    func testShouldActivate_BelowThreshold() {
        XCTAssertFalse(IceDPIHeuristic.shouldActivate(posterior: 0.50))
        XCTAssertFalse(IceDPIHeuristic.shouldActivate(posterior: 0.79))
    }
    
    func testShouldActivate_AtThreshold() {
        XCTAssertTrue(IceDPIHeuristic.shouldActivate(posterior: 0.80))
    }
    
    func testShouldActivate_AboveThreshold() {
        XCTAssertTrue(IceDPIHeuristic.shouldActivate(posterior: 0.85))
        XCTAssertTrue(IceDPIHeuristic.shouldActivate(posterior: 0.95))
    }
    
    // MARK: - Reset
    
    func testReset_ToDefaultPrior() {
        let reset = IceDPIHeuristic.reset()
        XCTAssertEqual(reset, IceDPIHeuristic.defaultPrior)
    }
    
    func testReset_ToCustomPrior() {
        let reset = IceDPIHeuristic.reset(to: 0.50)
        XCTAssertEqual(reset, 0.50, accuracy: 0.001)
    }
    
    // MARK: - IceDPIState Value Type
    
    func testIceDPIState_InitialState() {
        var state = IceDPIState()
        XCTAssertEqual(state.posterior, 0.10, accuracy: 0.001)
        XCTAssertFalse(state.dpiConfirmed)
        XCTAssertEqual(state.detectionProbability, 0.10, accuracy: 0.001)
        XCTAssertFalse(state.shouldActivateICE)
    }
    
    func testIceDPIState_RecordFailure() {
        var state = IceDPIState()
        state.recordFailure()
        XCTAssertGreaterThan(state.posterior, 0.10)
    }
    
    func testIceDPIState_RecordSuccess() {
        var state = IceDPIState()
        state.recordSuccess()
        XCTAssertLessThan(state.posterior, 0.10)
    }
    
    func testIceDPIState_Reset() {
        var state = IceDPIState()
        state.recordFailure()
        state.recordFailure()
        XCTAssertGreaterThan(state.posterior, 0.10)
        
        state.reset()
        XCTAssertEqual(state.posterior, 0.10, accuracy: 0.001)
        XCTAssertFalse(state.dpiConfirmed)
    }
    
    func testIceDPIState_ConfirmDPI() {
        var state = IceDPIState()
        state.confirmDPI()
        XCTAssertTrue(state.dpiConfirmed)
    }
    
    func testIceDPIState_ShouldActivateICE() {
        var state = IceDPIState()
        XCTAssertFalse(state.shouldActivateICE)
        
        // Simulate 3 failures to reach threshold
        state.recordFailure()
        state.recordFailure()
        state.recordFailure()
        XCTAssertTrue(state.shouldActivateICE)
    }
    
    // MARK: - Integration: Simulated Real-World Scenario
    
    func testSimulatedDPIEnvironment() {
        var state = IceDPIState()
        
        // Clean network: 2 successes, posterior decreases
        state.recordSuccess()
        state.recordSuccess()
        XCTAssertLessThan(state.posterior, 0.10)
        XCTAssertFalse(state.shouldActivateICE)
        
        // Network switches to DPI environment: consecutive failures
        state.recordFailure()
        XCTAssertFalse(state.shouldActivateICE)  // Not yet
        
        state.recordFailure()
        XCTAssertTrue(state.shouldActivateICE, "Should activate after 2 failures from elevated prior")
        
        state.confirmDPI()
        XCTAssertTrue(state.dpiConfirmed)
    }
    
    func testSimulatedFalsePositive() {
        var state = IceDPIState()
        
        // Single failure (false positive)
        state.recordFailure()
        XCTAssertFalse(state.shouldActivateICE)
        
        // Then success (network was fine)
        state.recordSuccess()
        XCTAssertLessThan(state.posterior, 0.10)
        XCTAssertFalse(state.shouldActivateICE)
    }
}
