//
//  BlindTokenService.swift
//  Construct Messenger
//
//  Privacy Pass Phase 2 — VOPRF-based blind token replenishment.
//
//  Flow (per-batch):
//    1. Generate N random 32-byte nonces locally.
//    2. Blind each nonce: ppBlindToken(nonce) → (blinded_point, blind_factor).
//    3. Send blinded_points to server via IssueTokens gRPC.
//    4. For each returned evaluated_point: optionally verify, then finalize:
//         token = ppFinalizeToken(evaluated, blind_factor, nonce)
//    5. Deliver finalized BlindTokens to TokenWalletService.
//
//  Rate limit: server enforces 20 tokens/hr. Client respects this by capping
//  a single replenish() call at 20 tokens and enforcing a 1-hour cooldown.
//

import Foundation

@MainActor
final class BlindTokenService {
    static let shared = BlindTokenService()

    /// Maximum tokens to request in one IssueTokens call (server limit: 20/hr).
    nonisolated static let batchSize = 20
    /// Don't replenish again within this window (mirrors server hourly bucket).
    private static let cooldown: TimeInterval = 3600

    private var lastReplenishDate: Date?
    private var isReplenishing = false

    private init() {}

    // MARK: - Public API

    /// Replenish the token wallet up to `count` new blind tokens.
    /// Silently skips if already replenishing or within cooldown.
    /// - Parameter count: Number of tokens to request (capped at batchSize).
    func replenish(count: Int = batchSize) async {
        guard !isReplenishing else {
            Log.debug("BlindToken: replenishment already in progress — skipping", category: "BlindToken")
            return
        }
        if let last = lastReplenishDate, Date().timeIntervalSince(last) < Self.cooldown {
            Log.debug("BlindToken: cooldown active — skipping", category: "BlindToken")
            return
        }

        let n = min(count, Self.batchSize)
        guard n > 0 else { return }

        isReplenishing = true
        defer { isReplenishing = false }

        do {
            let tokens = try await issueTokens(count: n)
            TokenWalletService.shared.deposit(tokens)
            lastReplenishDate = Date()
            Log.info("BlindToken: replenished \(tokens.count) tokens (wallet=\(TokenWalletService.shared.balance))", category: "BlindToken")
        } catch {
            Log.error("BlindToken: replenishment failed — \(error)", category: "BlindToken")
            // Set date on failure too so cooldown prevents log spam / rapid retries (e.g. "not configured").
            lastReplenishDate = Date()
        }
    }

    /// Special bootstrap for the very first batch of stealth tokens.
    /// - Called at registration and when user first enables Stealth.
    /// - Bypasses the cooldown so the user gets an initial balance immediately.
    /// - Only does work if the wallet is nearly empty.
    /// - Normal top-ups continue to use `replenish()`.
    func bootstrapInitialBatch() async {
        guard !isReplenishing else {
            Log.debug("BlindToken: bootstrap skipped (already replenishing)", category: "BlindToken")
            return
        }
        if TokenWalletService.shared.balance >= 10 {
            Log.debug("BlindToken: bootstrap skipped (wallet already has \(TokenWalletService.shared.balance) tokens)", category: "BlindToken")
            return
        }

        if let last = lastReplenishDate, Date().timeIntervalSince(last) < Self.cooldown {
            Log.debug("BlindToken: bootstrap cooldown active — skipping", category: "BlindToken")
            return
        }

        // Force bypass of cooldown for the absolute first batch (only if no recent attempt).
        lastReplenishDate = nil

        Log.info("BlindToken: starting initial bootstrap batch", category: "BlindToken")
        await replenish(count: Self.batchSize)
    }

    // MARK: - Core OPRF flow

    /// Run the full blind → issue → finalize pipeline and return valid tokens.
    private func issueTokens(count: Int) async throws -> [BlindToken] {
        // 1. Generate nonces and blind them.
        var nonces: [[UInt8]] = []
        var blindFactors: [[UInt8]] = []
        var blindedPoints: [Data] = []

        for _ in 0..<count {
            var nonce = [UInt8](repeating: 0, count: 32)
            let rc = SecRandomCopyBytes(kSecRandomDefault, 32, &nonce)
            guard rc == errSecSuccess else {
                throw BlindTokenError.entropyFailure
            }

            let packed = try ppBlindToken(nonce: nonce)
            guard packed.count == 64 else {
                throw BlindTokenError.invalidBlindOutput
            }

            let blinded = Array(packed[0..<32])
            let factor  = Array(packed[32..<64])

            nonces.append(nonce)
            blindFactors.append(factor)
            blindedPoints.append(Data(blinded))
        }

        // 2. Send to server.
        let response = try await callIssueTokens(blindedPoints: blindedPoints)

        guard response.evaluatedPoints.count == count else {
            throw BlindTokenError.responseMismatch(expected: count, got: response.evaluatedPoints.count)
        }

        let serverPubkey = response.serverPubkey.isEmpty ? [UInt8](repeating: 0, count: 32) : Array(response.serverPubkey)

        // 3. Finalize each evaluated point.
        var tokens: [BlindToken] = []
        for i in 0..<count {
            let evaluated = Array(response.evaluatedPoints[i])

            // Optionally verify the point is on-curve + matches server pubkey.
            if !ppVerifyClient(evaluatedBytes: evaluated, nonce: nonces[i], serverPubkeyBytes: serverPubkey) {
                Log.error("BlindToken: evaluated point \(i) failed verification — skipping", category: "BlindToken")
                continue
            }

            let tokenBytes = try ppFinalizeToken(
                evaluatedBytes: evaluated,
                blindFactorBytes: blindFactors[i],
                nonce: nonces[i]
            )

            tokens.append(BlindToken(nonce: Data(nonces[i]), token: Data(tokenBytes)))
        }

        return tokens
    }

    // MARK: - gRPC call

    private func callIssueTokens(
        blindedPoints: [Data]
    ) async throws -> Shared_Proto_Services_V1_IssueTokensResponse {
        try await AuthServiceClient.shared.issueTokens(blindedPoints: blindedPoints)
    }
}

// MARK: - Errors

enum BlindTokenError: Error, LocalizedError {
    case entropyFailure
    case invalidBlindOutput
    case responseMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .entropyFailure:
            return "SecRandomCopyBytes failed — system entropy unavailable"
        case .invalidBlindOutput:
            return "ppBlindToken returned unexpected output size (expected 64 bytes)"
        case .responseMismatch(let expected, let got):
            return "IssueTokens response mismatch: expected \(expected) points, got \(got)"
        }
    }
}
