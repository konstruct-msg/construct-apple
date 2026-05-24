//
//  IceDirectProbeService.swift
//  Construct Messenger
//
//  Direct connection probing for ICE auto-mode.
//

import Foundation
import Network

/// Result of a direct connection probe.
enum IceDirectProbeResult: Equatable {
    /// Direct connection succeeded.
    case success(latency: TimeInterval)
    /// Direct connection failed (timeout, refused, etc.).
    case failure(reason: String)
}

/// Service for probing direct gRPC connectivity.
///
/// This type performs actual network probes. The coordinator decides
/// what to do with the results (activate ICE, keep standby, etc.).
actor IceDirectProbeService {
    private var lastProbeResult: IceDirectProbeResult?
    private var lastProbeTime: Date?
    
    /// Probe direct TLS connection to the given host.
    ///
    /// - Parameters:
    ///   - host: Hostname to probe (e.g. "ams.konstruct.cc").
    ///   - port: Port number (default 443).
    ///   - timeout: Connection timeout (default 5s).
    /// - Returns: Probe result (success with latency, or failure reason).
    func probeTLSConnection(host: String, port: Int = 443, timeout: TimeInterval = 5.0) async -> IceDirectProbeResult {
        let start = Date()
        
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .https,
                                          using: .tls)
            let flag = OnceResumeFlag()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard flag.trigger() else { return }
                    connection.cancel()
                    let latency = Date().timeIntervalSince(start)
                    continuation.resume(returning: .success(latency: latency))
                    
                case .failed(let error):
                    guard flag.trigger() else { return }
                    continuation.resume(returning: .failure(reason: "NW error: \(error.localizedDescription)"))
                    
                case .cancelled:
                    guard flag.trigger() else { return }
                    continuation.resume(returning: .failure(reason: "cancelled"))
                    
                default:
                    break
                }
            }
            
            connection.start(queue: .global(qos: .utility))
            
            // Timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard flag.trigger() else { return }
                connection.cancel()
                continuation.resume(returning: .failure(reason: "timeout"))
            }
        }
    }
    
    /// Probe direct gRPC connection (HTTP/2).
    ///
    /// - Parameters:
    ///   - host: Hostname to probe.
    ///   - timeout: Connection timeout (default 5s).
    /// - Returns: Probe result.
    func probeGRPCConnection(host: String, timeout: TimeInterval = 5.0) async -> IceDirectProbeResult {
        // For now, TLS probe is sufficient — gRPC layer will handle HTTP/2.
        return await probeTLSConnection(host: host, timeout: timeout)
    }
    
    /// Last probe result (if any).
    func lastResult() -> IceDirectProbeResult? {
        lastProbeResult
    }
    
    /// Record a probe result for later retrieval.
    func recordResult(_ result: IceDirectProbeResult) {
        lastProbeResult = result
        lastProbeTime = Date()
    }
}

/// Thread-safe flag for once-only continuation resume.
private final class OnceResumeFlag: @unchecked Sendable {
    private var triggered = false
    private let lock = NSLock()
    
    func trigger() -> Bool {
        lock.withLock {
            guard !triggered else { return false }
            triggered = true
            return true
        }
    }
}
