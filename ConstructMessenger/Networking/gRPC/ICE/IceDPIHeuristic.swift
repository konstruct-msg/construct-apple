//
//  IceDPIHeuristic.swift
//  Construct Messenger
//
//  Bayesian DPI detection heuristic for ICE auto-mode.
//

import Foundation

/// Bayesian DPI detection model.
///
/// This type is pure and contains no state. It computes posterior probabilities
/// given prior and likelihood parameters. The coordinator owns the running posterior.
enum IceDPIHeuristic {
    /// Default prior: 10% of networks have DPI.
    static let defaultPrior: Double = 0.10
    
    /// P(stream timeout | DPI present) — DPI blocks ~90% of connection attempts.
    static let pFailGivenDPI: Double = 0.90
    
    /// P(stream timeout | no DPI) — ambient ~5% failure rate on clean networks.
    static let pFailGivenNoDPI: Double = 0.05
    
    /// P(success | DPI present)
    static let pOkGivenDPI: Double = 1.0 - pFailGivenDPI
    
    /// P(success | no DPI)
    static let pOkGivenNoDPI: Double = 1.0 - pFailGivenNoDPI
    
    /// Posterior threshold to trigger ICE activation (≥80% confident DPI is present).
    static let activateThreshold: Double = 0.80
    
    /// Update posterior after a direct connection failure (timeout).
    ///
    /// Uses Bayes' theorem:
    ///   P(DPI | fail) = P(fail | DPI) × P(DPI) / P(fail)
    ///   where P(fail) = P(fail | DPI) × P(DPI) + P(fail | no DPI) × (1 - P(DPI))
    ///
    /// - Parameters:
    ///   - prior: Current P(DPI) before observing this failure.
    ///   - pFailGivenDPI: P(failure | DPI present).
    ///   - pFailGivenNoDPI: P(failure | no DPI).
    /// - Returns: Updated posterior P(DPI | failure).
    static func updateAfterFailure(prior: Double, pFailGivenDPI: Double = Self.pFailGivenDPI, pFailGivenNoDPI: Double = Self.pFailGivenNoDPI) -> Double {
        let pFail = prior * pFailGivenDPI + (1.0 - prior) * pFailGivenNoDPI
        let posterior = (pFailGivenDPI * prior) / pFail
        return min(0.9999, posterior)
    }
    
    /// Update posterior after a direct connection success.
    ///
    /// Uses Bayes' theorem:
    ///   P(DPI | ok) = P(ok | DPI) × P(DPI) / P(ok)
    ///   where P(ok) = P(ok | DPI) × P(DPI) + P(ok | no DPI) × (1 - P(DPI))
    ///
    /// - Parameters:
    ///   - prior: Current P(DPI) before observing this success.
    ///   - pOkGivenDPI: P(success | DPI present).
    ///   - pOkGivenNoDPI: P(success | no DPI).
    /// - Returns: Updated posterior P(DPI | success).
    static func updateAfterSuccess(prior: Double, pOkGivenDPI: Double = Self.pOkGivenDPI, pOkGivenNoDPI: Double = Self.pOkGivenNoDPI) -> Double {
        let pOk = prior * pOkGivenDPI + (1.0 - prior) * pOkGivenNoDPI
        let posterior = (pOkGivenDPI * prior) / pOk
        return max(0.0001, posterior)
    }
    
    /// Whether the posterior has reached the ICE activation threshold.
    static func shouldActivate(posterior: Double, threshold: Double = Self.activateThreshold) -> Bool {
        posterior >= threshold
    }
    
    /// Reset posterior to the prior (call on network interface change).
    static func reset(to prior: Double = Self.defaultPrior) -> Double {
        prior
    }
}

/// DPI heuristic state held by the coordinator.
struct IceDPIState: Equatable {
    /// Current posterior P(DPI present).
    var posterior: Double = IceDPIHeuristic.defaultPrior
    
    /// Whether DPI has been confirmed and ICE activated this session.
    var dpiConfirmed: Bool = false
    
    /// Current posterior estimate.
    var detectionProbability: Double { posterior }
    
    /// Whether ICE should be activated based on current posterior.
    var shouldActivateICE: Bool {
        IceDPIHeuristic.shouldActivate(posterior: posterior)
    }
    
    /// Record a direct failure and update posterior.
    mutating func recordFailure() {
        posterior = IceDPIHeuristic.updateAfterFailure(prior: posterior)
    }
    
    /// Record a direct success and update posterior.
    mutating func recordSuccess() {
        posterior = IceDPIHeuristic.updateAfterSuccess(prior: posterior)
    }
    
    /// Reset to prior (call on network interface change).
    mutating func reset() {
        posterior = IceDPIHeuristic.reset()
        dpiConfirmed = false
    }
    
    /// Mark DPI as confirmed (ICE activated).
    mutating func confirmDPI() {
        dpiConfirmed = true
    }
}
