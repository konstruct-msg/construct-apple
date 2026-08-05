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

/// What a send that needs a token should do right now.
///
/// Extracted because the answer turns on a distinction the old single `cooldownUntil` could not
/// make: **pacing is a politeness we chose, back-off is the server saying no.** Both were one
/// date, so an empty wallet during a burst was held back by our own 90s pacing exactly as if the
/// issuer had refused — and under `enforce` that is not a degraded anti-abuse property, it is a
/// message the server rejects.
enum ReplenishGate: Equatable {
    /// Start a batch now (or the wallet is empty and waiting is the lesser cost).
    case start
    /// One is already running — wait for it instead of sending token-less past it.
    case waitForInFlight
    /// The issuer refused (rate limit / not configured). Waiting only adds latency.
    case blockedByBackoff
    /// Wallet is merely low and we are pacing successful batches. Nothing is at stake.
    case blockedByPacing
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

    /// How long a send with an empty wallet waits for tokens before going ahead without one.
    /// Sized against the alternative, not against comfort: under `enforce` a token-less send is
    /// rejected and retried, which costs a round trip anyway — so a bounded wait here is cheaper
    /// than the failure it prevents. It is paid at most once per batch (20 tokens serve the next
    /// 20 sends), and not at all while the issuer is backing us off.
    static let tokenWaitTimeout: TimeInterval = 2.0
    private static let tokenWaitPollMs: UInt64 = 40

    /// Pacing between *successful* batches — our own politeness. Never blocks an empty wallet.
    private var pacingUntil: Date?
    /// Back-off after the issuer refused (rate limit, not configured, bad auth). This one does
    /// block: it is the server's answer, and re-asking inside it cannot succeed.
    private var backoffUntil: Date?
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

    /// What to do about an empty-or-low wallet right now. Pure so the burst behaviour can be
    /// asserted in a test instead of inferred from a six-hour device log.
    static func gate(
        balance: Int,
        isReplenishing: Bool,
        pacingUntil: Date?,
        backoffUntil: Date?,
        now: Date = Date()
    ) -> ReplenishGate {
        if isReplenishing { return .waitForInFlight }
        if let backoffUntil, backoffUntil > now { return .blockedByBackoff }
        // An empty wallet outranks our own pacing: the pacing exists to be polite to an issuer
        // that answers refusals explicitly, and being polite here costs a rejected message.
        if balance == 0 { return .start }
        if let pacingUntil, pacingUntil > now { return .blockedByPacing }
        return .start
    }

    private var currentGate: ReplenishGate {
        Self.gate(
            balance: TokenWalletService.shared.balance,
            isReplenishing: isReplenishing,
            pacingUntil: pacingUntil,
            backoffUntil: backoffUntil
        )
    }

    /// Replenish the token wallet up to `count` new blind tokens.
    /// Silently skips if already replenishing or held by pacing / back-off.
    /// - Parameter count: Number of tokens to request (capped at batchSize).
    func replenish(count: Int = batchSize) async {
        switch currentGate {
        case .waitForInFlight:
            Log.debug("BlindToken: replenishment already in progress — skipping", category: "BlindToken")
            return
        case .blockedByBackoff:
            Log.debug("BlindToken: issuer back-off active — skipping", category: "BlindToken")
            return
        case .blockedByPacing:
            Log.debug("BlindToken: pacing between batches — skipping", category: "BlindToken")
            return
        case .start:
            break
        }

        let n = min(count, Self.batchSize)
        guard n > 0 else { return }

        // Claimed here, with no await in between, so a send that starts waiting on the very next
        // line cannot observe an idle service and give up before this batch exists.
        isReplenishing = true
        await performReplenish(count: n)
    }

    /// The batch itself. Assumes `isReplenishing` is already claimed by the caller.
    private func performReplenish(count n: Int) async {
        defer { isReplenishing = false }

        do {
            let tokens = try await issueTokens(count: n)
            TokenWalletService.shared.deposit(tokens)
            record(.ok(tokens.count))
            pacingUntil = Date().addingTimeInterval(Self.successCooldown)
            backoffUntil = nil
            Log.info("BlindToken: replenished \(tokens.count) tokens (wallet=\(TokenWalletService.shared.balance))", category: "BlindToken")
        } catch {
            // Classify so the wallet-empty cause is diagnosable, and so transient failures
            // don't inherit the full hourly lockout that steady server states warrant.
            let outcome = Self.classify(error)
            record(outcome)
            let backoff = outcome.backsOffFullHour ? Self.rateLimitBackoff : Self.transientRetry
            backoffUntil = Date().addingTimeInterval(backoff)
            Log.error("BlindToken: replenishment failed [\(outcome.diagnosticLabel)] — \(error)", category: "BlindToken")
        }
    }

    /// Give a send that needs a token the chance to have one, bounded by `timeout`.
    ///
    /// The send path used to read the wallet once and step over an empty one, so a burst that
    /// outran issuance sent token-less past a batch that was already in flight — 93 of 271 sealed
    /// sends in one hour of the 2026-08-04 run, alongside 99 "replenishment already in progress"
    /// skips. Those two lines are the same event seen from both ends.
    ///
    /// Returns whether a token is available now. Never waits on an issuer back-off: the server
    /// already answered, and adding two seconds to a send it will refuse anyway helps nobody.
    @discardableResult
    func ensureTokenAvailable(timeout: TimeInterval = tokenWaitTimeout) async -> Bool {
        if TokenWalletService.shared.balance > 0 { return true }

        switch currentGate {
        case .blockedByBackoff:
            PerformanceMetrics.shared.record(.tokenWalletWait, label: "backoff")
            return false
        case .blockedByPacing:
            // Unreachable while the wallet is empty (`gate` returns .start), kept explicit so a
            // future change to that rule fails here rather than silently reinstating the wait.
            PerformanceMetrics.shared.record(.tokenWalletWait, label: "pacing")
            return false
        case .start:
            isReplenishing = true                       // claim before the await, as above
            Task { [weak self] in await self?.performReplenish(count: Self.batchSize) }
        case .waitForInFlight:
            break
        }

        let deadline = Date().addingTimeInterval(timeout)
        while isReplenishing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(Self.tokenWaitPollMs))
        }
        let served = TokenWalletService.shared.balance > 0
        PerformanceMetrics.shared.record(.tokenWalletWait, label: served ? "served" : "timeout")
        return served
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
        pacingUntil = nil
        backoffUntil = nil
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

        if let until = backoffUntil, Date() < until {
            Log.debug("BlindToken: bootstrap skipped — issuer back-off active", category: "BlindToken")
            return
        }

        // Force bypass of pacing for the absolute first batch (a refusal still holds us back).
        pacingUntil = nil

        Log.info("BlindToken: starting initial bootstrap batch", category: "BlindToken")
        await replenish(count: Self.batchSize)
    }

    // MARK: - Phase C: pinned issuer keys (verifiable VOPRF)

    /// Client-pinned issuer public keys `K = k·G` (compressed Ristretto, 32 bytes), keyed by
    /// `issuer_key_version`. The batched DLEQ proof in `IssueTokensResponse` is verified against
    /// the PIN — never the echoed `serverPubkey`, which a malicious/coerced issuer could vary per
    /// user to key-tag. A pin is an out-of-band constant, like the VEIL bundle-signing-key pin:
    /// obtain it once from the `serverPubkey` of a trusted `IssueTokens` response (there is no
    /// well-known — everything reaches the client over gRPC) and bake it in here.
    ///
    /// **Rollout safety:** when no pin exists for the returned version, DLEQ verification is skipped
    /// and issuance falls back to the legacy per-point check — a not-yet-pinned or freshly-rotated
    /// key never bricks token issuance. Verification activates the moment the matching pin lands.
    /// Rotation: ship the next key here alongside the current one (a set), then retire the old.
    // Pinned issuer public key(s) K = k·G, base64-decoded from identity-service's boot log
    // ("Privacy Pass issuer commitment initialized (DLEQ verifiable) issuer_public=… version=…").
    // Add the next key alongside the current one when rotating, then retire the old.
    private static let issuerKeyPins: [UInt32: [UInt8]] = [
        // v1 — zFQy29lYJWV8AkJPtya3/P+xlS/t9bDJqHWuGG5qKTM=
        1: [
            0xcc, 0x54, 0x32, 0xdb, 0xd9, 0x58, 0x25, 0x65,
            0x7c, 0x02, 0x42, 0x4f, 0xb7, 0x26, 0xb7, 0xfc,
            0xff, 0xb1, 0x95, 0x2f, 0xed, 0xf5, 0xb0, 0xc9,
            0xa8, 0x75, 0xae, 0x18, 0x6e, 0x6a, 0x29, 0x33,
        ],
    ]

    static func pinnedIssuerKey(version: UInt32) -> [UInt8]? {
        issuerKeyPins[version]
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

        // 2b. Phase C — verifiable issuance. When this issuer key version is pinned, verify the
        // batched DLEQ proof against the PINNED K (never the echoed serverPubkey, which a
        // malicious/coerced issuer could vary per user to key-tag). This proves every evaluated
        // point used the single committed k. No pin for this version ⇒ skip, so a not-yet-pinned
        // or freshly-rotated key never bricks issuance (the legacy per-point check below still runs).
        if let pinnedK = Self.pinnedIssuerKey(version: response.issuerKeyVersion) {
            if !response.serverPubkey.isEmpty && Array(response.serverPubkey) != pinnedK {
                Log.error("BlindToken: serverPubkey ≠ pinned issuer key v\(response.issuerKeyVersion) — rejecting batch (key-tag?)", category: "BlindToken")
                throw BlindTokenError.allPointsRejected
            }
            guard !response.dleqProof.isEmpty else {
                Log.error("BlindToken: pinned issuer key v\(response.issuerKeyVersion) but response carried no DLEQ proof — rejecting batch", category: "BlindToken")
                throw BlindTokenError.allPointsRejected
            }
            let verified = ppVerifyDleq(
                blinded: blindedPoints.map { [UInt8]($0) },
                evaluated: response.evaluatedPoints.map { [UInt8]($0) },
                proof: [UInt8](response.dleqProof),
                issuerPublic: pinnedK
            )
            guard verified else {
                Log.error("BlindToken: DLEQ proof FAILED against pinned issuer key v\(response.issuerKeyVersion) — rejecting batch (issuer key-tag)", category: "BlindToken")
                throw BlindTokenError.allPointsRejected
            }
            Log.info("BlindToken: DLEQ verified against pinned issuer key v\(response.issuerKeyVersion) (\(count) pts)", category: "BlindToken")
        }

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
