//
//  AntiSpamService.swift
//  Construct Messenger
//
//  Central coordinator: combines heuristics + trust score + rate limiter
//  into a single SendDecision before every outgoing message.
//

import Foundation

// MARK: - SendDecision

/// What the client should do before sending the next message.
enum SendDecision: Equatable {
    /// Send immediately — no delays.
    case allow

    /// Apply a soft delay before sending.  Show a subtle "sending…" indicator.
    /// - `delay`: seconds to wait.
    case slowDown(delay: TimeInterval)

    /// Apply a longer delay with a visible progress UI.
    /// - `delay`: seconds to wait.
    /// - `level`: PoW-style UI level (4, 6, 8, 10, 12) for UI calibration.
    case sendWithWarning(delay: TimeInterval, level: Int)

    /// Rate limit exceeded.  Cannot send until window resets.
    /// - `resetIn`: seconds until the window resets.
    case rateLimited(resetIn: TimeInterval)
}

// MARK: - AntiSpamService

/// Stateless facade that computes a `SendDecision` for a given outgoing message.
///
/// All state is owned by `LocalRateLimiter`, `LocalTrustScore`, and `SpamHeuristics`.
struct AntiSpamService {

    static let shared = AntiSpamService()
    private init() {}

    private let heuristics = SpamHeuristics()

    // MARK: - Decision

    /// Compute a send decision.  Call this *before* initiating the actual send.
    ///
    /// - Parameters:
    ///   - text: Plaintext body.
    ///   - urls: URLs in the message (pass `[]` if none or if content is media-only).
    /// - Returns: A `SendDecision` telling the caller what to do next.
    func decideBeforeSend(text: String, urls: [URL] = []) -> SendDecision {
        // 1. Hard rate limit check
        switch LocalRateLimiter.shared.checkAndRecord() {
        case .rateLimited(let resetIn):
            return .rateLimited(resetIn: resetIn)
        case .allowed:
            break
        }

        // 2. Spam score (heuristics adjusted by trust)
        let raw      = heuristics.score(text: text, urls: urls)
        let adjusted = raw * (1.0 - LocalTrustScore.shared.score * 0.5)

        // 3. Warning history escalates delays further
        let warnings = LocalRateLimiter.shared.warningsLast24h
        let warningMultiplier: Float = warnings > 0 ? (1.0 + Float(warnings) * 0.15) : 1.0
        let effective = min(adjusted * warningMultiplier, 1.0)

        // 4. Map to decision (mirrors the table in the design document)
        switch effective {
        case ..<0.3:
            return .allow

        case 0.3..<0.6:
            // Soft delay: 3–5 s based on warning count
            let delay: TimeInterval = warnings >= 2 ? 10 : (warnings == 1 ? 5 : 3)
            return .slowDown(delay: delay)

        case 0.6..<0.85:
            // Visible progress bar (levels 6–8)
            let level = warnings >= 2 ? 8 : 6
            let delay: TimeInterval = level == 8 ? 15 : 7
            return .sendWithWarning(delay: delay, level: level)

        default:
            // Strong warning (levels 10–12)
            let level = warnings >= 4 ? 12 : 10
            let delay: TimeInterval = level == 12 ? 80 : 40
            return .sendWithWarning(delay: delay, level: level)
        }
    }

    // MARK: - Post-send callbacks

    /// Call after the message was successfully delivered to the server.
    func recordSuccess(text: String) {
        LocalTrustScore.shared.recordSuccess()
        SpamHeuristics.recordSent(text: text)
    }

    /// Call when we showed the user a spam-warning.
    func recordWarning() {
        LocalTrustScore.shared.recordWarning()
        LocalRateLimiter.shared.recordWarning()
    }
}
