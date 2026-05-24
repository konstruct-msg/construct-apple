//
//  IceAutoModeCoordinator.swift
//  Construct Messenger
//
//  Coordinator for ICE auto-mode (DPI detection and standby pre-warm).
//

import Foundation

/// Coordinator for ICE auto-mode decisions.
///
/// This type owns:
/// - DPI posterior state and Bayesian updates
/// - Standby pre-warm policy
/// - Direct probe scheduling and interpretation
///
/// It emits events (`IceConnectionEvent`) rather than mutating state directly.
/// The manager applies these events through the reducer.
@MainActor
final class IceAutoModeCoordinator: ObservableObject {
    static let shared = IceAutoModeCoordinator()
    
    private init() {}
    
    // MARK: - DPI State
    
    /// DPI heuristic state (posterior, confirmed flag).
    private var dpiState = IceDPIState()
    
    /// Current posterior P(DPI present).
    var dpiDetectionProbability: Double { dpiState.detectionProbability }
    
    /// Whether DPI has been confirmed and ICE should be active.
    var dpiConfirmed: Bool { dpiState.dpiConfirmed }
    
    /// Whether ICE should be activated based on current posterior.
    var shouldActivateICE: Bool { dpiState.shouldActivateICE }
    
    // MARK: - Direct Probe Service
    
    private let probeService = IceDirectProbeService()
    private var backgroundProbeTask: Task<Void, Never>?
    
    // MARK: - Standby Pre-warm
    
    /// Whether standby pre-warm is currently running.
    @Published private(set) var isStandbyPrewarmRunning: Bool = false
    
    /// Decide whether to start standby pre-warm.
    ///
    /// Called on app launch or network change when mode is `.auto`.
    /// Returns `true` if pre-warm should start.
    func shouldStartStandbyPrewarm(lastSuccessfulPath: String?) -> Bool {
        // Pre-warm if:
        // 1. Last session used ICE (likely DPI environment)
        // 2. Or posterior is already elevated from recent failures
        guard lastSuccessfulPath == "ice" || dpiState.posterior > IceDPIHeuristic.defaultPrior else {
            return false
        }
        Log.info("🧊 Standby pre-warm decision: YES (path=\(lastSuccessfulPath ?? "nil"), posterior=\(String(format: "%.1f", dpiState.posterior * 100))%)", category: "ICE")
        return true
    }
    
    /// Record a direct connection failure (DPI evidence).
    ///
    /// - Returns: `.directBlocked` if ICE should activate, `.directVerified` otherwise.
    func recordDirectFailure() -> IceConnectionEvent? {
        dpiState.recordFailure()
        Log.debug("🧊 DPI posterior after failure: \(String(format: "%.1f", dpiState.posterior * 100))%", category: "ICE")
        
        if dpiState.shouldActivateICE && !dpiState.dpiConfirmed {
            Log.info("🧊 DPI threshold reached (\(String(format: "%.1f", dpiState.posterior * 100))%) — ICE should activate", category: "ICE")
            return .directBlocked
        }
        return nil
    }
    
    /// Record a direct connection success (evidence against DPI).
    func recordDirectSuccess() {
        dpiState.recordSuccess()
        Log.debug("🧊 DPI posterior after success: \(String(format: "%.1f", dpiState.posterior * 100))%", category: "ICE")
    }
    
    /// Record that a direct stream was successfully established (used by MessageStream).
    ///
    /// - Returns: Event to emit (if any).
    func recordDirectStreamConnected() -> IceConnectionEvent? {
        recordDirectSuccess()
        // If we're in standby and direct works, stay in standby (user might switch to .off).
        return nil
    }
    
    /// Activate DPI mode (called when ICE is confirmed necessary).
    func activateDPI() {
        dpiState.confirmDPI()
        Log.info("🧊 DPI confirmed — ICE mode activated for this session", category: "ICE")
    }
    
    /// Reset DPI state (call on network interface change).
    func resetForNetworkChange() {
        dpiState.reset()
        Log.debug("🧊 DPI state reset to prior (\(Int(IceDPIHeuristic.defaultPrior * 100))%)", category: "ICE")
    }
    
    // MARK: - Background Direct Probe
    
    /// Schedule a background probe to check if direct gRPC is reachable.
    ///
    /// Called when ICE is active in `.auto` mode to periodically check
    /// if direct connection has become available (for potential demotion).
    func scheduleBackgroundProbe(host: String, interval: TimeInterval = 60.0) {
        backgroundProbeTask?.cancel()
        backgroundProbeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                
                let result = await probeService.probeGRPCConnection(host: host)
                await handleProbeResult(result)
            }
        }
    }
    
    /// Cancel any ongoing background probe.
    func cancelBackgroundProbe() {
        backgroundProbeTask?.cancel()
        backgroundProbeTask = nil
    }
    
    @MainActor
    private func handleProbeResult(_ result: IceDirectProbeResult) {
        switch result {
        case .success(let latency):
            Log.debug("🧊 Background direct probe succeeded (latency: \(Int(latency * 1000))ms)", category: "ICE")
            recordDirectSuccess()
            // If direct works and we're in standby, coordinator may decide to demote.
            // For now, just record — demotion policy is TBD.
            
        case .failure(let reason):
            Log.debug("🧊 Background direct probe failed: \(reason)", category: "ICE")
            // Don't activate ICE from background probe — only foreground failures do that.
            break
        }
    }
}
