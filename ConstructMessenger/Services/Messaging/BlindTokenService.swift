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
//  Rate limit: the server bounds each IssueTokens call at 20 blinded points and caps
//  issuance per user per hour (TOKEN_ISSUANCE_MAX_PER_HOUR, default 120). The client
//  batches at 20/call and paces successful batches by a short cooldown, topping the wallet
//  up reactively (topUpIfLow) toward that cap for per-message scope; hitting the cap yields
//  .rateLimited → a full-hour back-off.
//

import Foundation
import GRPCCore

/// Classified result of the most recent token-issuance attempt. Surfaced (DEBUG
/// Diagnostics) so an empty wallet is diagnosable instead of silent — in particular
/// `.serverDisabled` (identity-service `TOKEN_ISSUER_KEY` unset) vs a transient blip.
enum IssuanceOutcome: Equatable {
    case ok(Int)             // n tokens deposited
    case serverDisabled      // server: issuance not configured (UNAVAILABLE "not configured")
    case rateLimited         // server: 20/hr bucket exhausted (RESOURCE_EXHAUSTED)
    case unauthenticated     // access token rejected (UNAUTHENTICATED)
    case verifyRejected      // every evaluated point failed client verify (bad/rotated issuer key)
    case transportError      // network / plain UNAVAILABLE — transient
    case malformed           // response count mismatch / bad blind output

    /// Steady/expected states back off the full hour; transient transport failures
    /// retry soon so a network blip doesn't strand the wallet empty for an hour.
    var backsOffFullHour: Bool {
        switch self {
        case .transportError, .unauthenticated: return false
        default: return true
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .ok(let n): return "ok(\(n))"
        case .serverDisabled: return "server issuance disabled"
        case .rateLimited: return "rate limited (20/hr)"
        case .unauthenticated: return "unauthenticated"
        case .verifyRejected: return "issuer-key/verify rejected"
        case .transportError: return "transport error"
        case .malformed: return "malformed response"
        }
    }
}

@MainActor
final class BlindTokenService {
    static let shared = BlindTokenService()

    /// Maximum blinded points per IssueTokens call (server bounds a request at 20).
    nonisolated static let batchSize = 20
    /// Pace between *successful* batches. Short (not the server's hourly window) so the
    /// wallet can be topped up across several batches toward the server hourly cap for
    /// per-message scope (Phase B). Hitting the cap returns `.rateLimited` → full-hour
    /// back-off, which is the real ceiling.
    private static let successCooldown: TimeInterval = 90
    /// Back-off for steady/expected server states (issuance disabled, hourly cap hit):
    /// retrying sooner won't help until the next hour.
    private static let rateLimitBackoff: TimeInterval = 3600
    /// Brief back-off for transient transport failures — a network blip shouldn't keep
    /// the wallet empty for a full hour.
    private static let transientRetry: TimeInterval = 120
    /// Reactive top-up threshold: below this the wallet is refilled (per-message scope
    /// drains it steadily, unlike per-stream's ~1/recipient/day).
    private static let lowWaterMark = 20

    /// When the next replenish attempt becomes eligible (nil = eligible now).
    private var cooldownUntil: Date?
    private var isReplenishing = false

    /// Result + timestamp of the most recent issuance attempt (for DEBUG Diagnostics).
    private(set) var lastOutcome: IssuanceOutcome?
    private(set) var lastOutcomeDate: Date?

    private init() {}

    private func record(_ outcome: IssuanceOutcome) {
        lastOutcome = outcome
        lastOutcomeDate = Date()
    }

    // MARK: - Public API

    /// Replenish the token wallet up to `count` new blind tokens.
    /// Silently skips if already replenishing or within cooldown.
    /// - Parameter count: Number of tokens to request (capped at batchSize).
    func replenish(count: Int = batchSize) async {
        guard !isReplenishing else {
            Log.debug("BlindToken: replenishment already in progress — skipping", category: "BlindToken")
            return
        }
        if let until = cooldownUntil, Date() < until {
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
            record(.ok(tokens.count))
            cooldownUntil = Date().addingTimeInterval(Self.successCooldown)
            Log.info("BlindToken: replenished \(tokens.count) tokens (wallet=\(TokenWalletService.shared.balance))", category: "BlindToken")
        } catch {
            // Classify so the wallet-empty cause is diagnosable, and so transient failures
            // don't inherit the full hourly lockout that steady server states warrant.
            let outcome = Self.classify(error)
            record(outcome)
            let backoff = outcome.backsOffFullHour ? Self.rateLimitBackoff : Self.transientRetry
            cooldownUntil = Date().addingTimeInterval(backoff)
            Log.error("BlindToken: replenishment failed [\(outcome.diagnosticLabel)] — \(error)", category: "BlindToken")
        }
    }

    /// Reactive top-up for per-message scope: pull a fresh batch when the wallet runs low.
    /// Called from the send path after a token is consumed (and on empty-wallet sends), so
    /// the wallet chases the server hourly cap instead of waiting for the next foreground /
    /// background trigger. Cheap and idempotent — guarded by the balance threshold, the
    /// success cooldown, and `isReplenishing`; a hit hourly cap self-limits via `.rateLimited`.
    /// Enforce-rejection recovery (FAILED_PRECONDITION "privacy_pass:*"): the server just
    /// rejected our token, so any active cooldown is stale by definition — clear it and
    /// pull a fresh batch immediately so the one-shot sealed retry has a valid token.
    /// Still serialized by `isReplenishing`; a hit hourly cap re-arms the full back-off
    /// via `.rateLimited` as usual.
    func forceReplenish() async {
        cooldownUntil = nil
        await replenish()
    }

    func topUpIfLow() async {
        guard TokenWalletService.shared.balance < Self.lowWaterMark else { return }
        await replenish()
    }

    /// Map a thrown issuance error to a diagnostic outcome. The raw `RPCError` propagates
    /// from `GRPCCallExecutor` (it rethrows unwrapped), so server status codes are legible
    /// here: identity-service returns UNAVAILABLE "…not configured" when `TOKEN_ISSUER_KEY`
    /// is unset, RESOURCE_EXHAUSTED for the 20/hr cap, UNAUTHENTICATED for a bad token.
    private static func classify(_ error: Error) -> IssuanceOutcome {
        if let bt = error as? BlindTokenError {
            switch bt {
            case .allPointsRejected: return .verifyRejected
            case .responseMismatch, .invalidBlindOutput: return .malformed
            case .entropyFailure: return .transportError  // local, retry soon
            }
        }
        if let rpc = error as? RPCError {
            switch rpc.code {
            case .unavailable:
                let m = rpc.message.lowercased()
                return (m.contains("not configured") || m.contains("token issuance"))
                    ? .serverDisabled : .transportError
            case .resourceExhausted: return .rateLimited
            case .unauthenticated: return .unauthenticated
            default: return .transportError
            }
        }
        return .transportError
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

        if let until = cooldownUntil, Date() < until {
            Log.debug("BlindToken: bootstrap cooldown active — skipping", category: "BlindToken")
            return
        }

        // Force bypass of cooldown for the absolute first batch (only if no recent attempt).
        cooldownUntil = nil

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

        // Server returned a full response but every point failed client verification —
        // a bad/rotated issuer key, not a transient fault. Surface it distinctly instead
        // of logging "replenished 0" as if it were success.
        if tokens.isEmpty && count > 0 {
            throw BlindTokenError.allPointsRejected
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
    case allPointsRejected

    var errorDescription: String? {
        switch self {
        case .entropyFailure:
            return "SecRandomCopyBytes failed — system entropy unavailable"
        case .invalidBlindOutput:
            return "ppBlindToken returned unexpected output size (expected 64 bytes)"
        case .responseMismatch(let expected, let got):
            return "IssueTokens response mismatch: expected \(expected) points, got \(got)"
        case .allPointsRejected:
            return "Every evaluated point failed client verification (bad/rotated issuer key)"
        }
    }
}
