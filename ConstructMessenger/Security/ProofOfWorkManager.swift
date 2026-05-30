// ProofOfWorkManager.swift
// Wrapper for Rust Argon2id Proof of Work implementation

import Foundation

/// Callback observer for PoW progress updates
final class PowProgressObserver: PowProgressCallback, @unchecked Sendable {
    private let onProgress: (Float) -> Void
    private var lastProgress: Float = 0.0
    
    init(onProgress: @escaping (Float) -> Void) {
        self.onProgress = onProgress
    }
    
    func onProgress(currentNonce: UInt64, attempts: UInt64, estimatedProgress: Float) {
        // Only update if progress changed significantly (> 1%)
        if abs(estimatedProgress - lastProgress) >= 0.01 {
            lastProgress = estimatedProgress
            
            // Call on main thread for UI updates with smooth animation
            DispatchQueue.main.async { [weak self] in
                self?.onProgress(estimatedProgress)
            }
        }
    }
}

/// Manager for computing and verifying Proof of Work challenges
/// Uses Argon2id memory-hard algorithm to prevent bot spam
class ProofOfWorkManager {
    
    /// Compute PoW with real-time progress updates
    ///
    /// - Parameters:
    ///   - challenge: Random challenge string from server
    ///   - difficulty: Required number of leading zero bits (8 = normal, 12 = under attack)
    ///   - onProgress: Callback for progress updates (0.0 - 1.0), called on main thread
    /// - Returns: PowSolution containing nonce and hash
    ///
    /// - Note: This is CPU-intensive! Runs on background thread.
    ///         difficulty=4:  ~20-30 seconds
    ///         difficulty=8:  ~3-5 minutes
    ///         difficulty=12: ~1-2 hours
    static func computeWithProgress(
        challenge: String,
        difficulty: UInt32,
        onProgress: @escaping (Float) -> Void
    ) async -> PowSolution {
        return await Task.detached(priority: .userInitiated) {
            // Create progress observer
            let observer = PowProgressObserver(onProgress: onProgress)
            
            // Call Rust implementation with progress callback
            let solution = computePowWithProgress(
                challenge: challenge,
                difficulty: difficulty,
                progressCallback: observer
            )
            
            Log.info("[PoW] Found solution after \(solution.nonce) attempts")
            Log.info("[PoW] Hash: \(solution.hash)")
            
            return solution
        }.value
    }
    
    /// Compute a Proof of Work solution (legacy, without progress)
    ///
    /// - Parameters:
    ///   - challenge: Random challenge string from server
    ///   - difficulty: Required number of leading zero bits (8 = normal, 12 = under attack)
    /// - Returns: PowSolution containing nonce and hash
    ///
    /// - Note: Prefer `computeWithProgress` for better UX
    static func compute(
        challenge: String,
        difficulty: UInt32,
        onProgress: ((UInt64) -> Void)? = nil
    ) async -> PowSolution {
        return await Task.detached(priority: .userInitiated) {
            // Call Rust implementation
            let solution = computePow(challenge: challenge, difficulty: difficulty)
            
            Log.info("[PoW] Found solution after \(solution.nonce) attempts")
            Log.info("[PoW] Hash: \(solution.hash)")
            
            return solution
        }.value
    }
    
    /// Verify a PoW solution (optional client-side check)
    ///
    /// - Parameters:
    ///   - challenge: Original challenge
    ///   - solution: Computed solution
    ///   - difficulty: Required difficulty
    /// - Returns: true if valid, false otherwise
    static func verify(
        challenge: String,
        solution: PowSolution,
        difficulty: UInt32
    ) -> Bool {
        return verifyPow(
            challenge: challenge,
            solution: solution,
            requiredDifficulty: difficulty
        )
    }
}

/// Manager for device-based authentication
class DeviceIDManager {
    
    /// Derive a deterministic device ID from identity public key
    ///
    /// - Parameter identityPublicKey: Ed25519 public key (32 bytes)
    /// - Returns: Hex-encoded device ID (32 characters)
    ///
    /// - Note: Same key always produces same device_id (deterministic)
    static func deriveDeviceID(from identityPublicKey: Data) -> String {
        let deviceID = deriveDeviceId(identityPublicKey: [UInt8](identityPublicKey))
        
        Log.info("[DeviceID] Derived device ID: \(deviceID)")
        
        return deviceID
    }
    
    /// Format a federated identifier
    ///
    /// - Parameters:
    ///   - deviceID: Local device ID (32 hex chars)
    ///   - serverHostname: Server hostname (e.g., "konstruct.cc")
    /// - Returns: Federated ID (e.g., "abc123@ams.konstruct.cc")
    static func formatFederatedID(
        deviceID: String,
        serverHostname: String
    ) -> String {
        return formatFederatedId(
            deviceId: deviceID,
            serverHostname: serverHostname
        )
    }
}

// MARK: - Preview/Testing Helpers

#if DEBUG
extension ProofOfWorkManager {
    
    /// Quick test with low difficulty (for development)
    static func quickTest() async {
        Log.info("[PoW Test] Starting quick test (difficulty=4)...")
        
        let start = Date()
        let solution = await compute(
            challenge: "test_challenge_12345",
            difficulty: 4
        )
        let elapsed = Date().timeIntervalSince(start)
        
        Log.info("[PoW Test] Completed in \(String(format: "%.1f", elapsed))s")
        Log.info("[PoW Test] Nonce: \(solution.nonce)")
        Log.info("[PoW Test] Hash: \(solution.hash)")
        
        // Verify solution
        let isValid = verify(
            challenge: "test_challenge_12345",
            solution: solution,
            difficulty: 4
        )
        Log.info("[PoW Test] Verification: \(isValid ? "PASSED" : "FAILED")")
    }
}

extension DeviceIDManager {
    
    /// Quick test with known value
    static func quickTest() {
        Log.info("[DeviceID Test] Starting test...")
        
        // Test with all-zeros key (known result)
        let zeroKey = Data(count: 32)
        let deviceID = deriveDeviceID(from: zeroKey)
        
        // Known value from Rust test
        let expected = "66687aadf862bd776c8fc18b8e9f8e20"
        
        if deviceID == expected {
            Log.info("[DeviceID Test] PASSED: \(deviceID)")
        } else {
            Log.error("[DeviceID Test] FAILED")
            Log.error("[DeviceID Test] Expected: \(expected)")
            Log.error("[DeviceID Test] Got: \(deviceID)")
        }
        
        // Test federated format
        let federated = formatFederatedID(
            deviceID: deviceID,
            serverHostname: "ams.konstruct.cc"
        )
        Log.info("[DeviceID Test] Federated: \(federated)")
    }
}
#endif
