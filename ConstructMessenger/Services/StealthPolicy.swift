//
//  StealthPolicy.swift
//  Construct Messenger
//
//  Central policy for Stealth / Sealed Sender (Ghost Mode).
//  Decides:
//  - whether to use sealed sender at all (hides sender identity from the server)
//  - whether/when to consume a Privacy Pass token (per-stream vs per-message)
//
//  Token consumption is rate-limited in per-stream mode (1 token per recipient per ~24h).
//  The SealedInner certificate seal (actual sender hiding) is independent of token spend.
//
//  Explicit exclusions (even when stealth is enabled):
//  - E2E heartbeats (ct=13) — see decisions/stealth-heartbeat-exclusion.md
//  - Multi-device internal sync (low value, server already knows it's the same user)
//  - Pure session control messages (END_SESSION, resets, etc.)
//

import Foundation
import Observation

/// Scope for when to apply sealed-sender + consume Privacy Pass tokens.
enum StealthScope: String, CaseIterable, Identifiable {
    case perStream
    case perMessage

    var id: String { rawValue }

    var isPerMessage: Bool { self == .perMessage }

    static func from(isPerMessage: Bool) -> StealthScope {
        isPerMessage ? .perMessage : .perStream
    }
}

@Observable
@MainActor
final class StealthPolicy {
    static let shared = StealthPolicy()

    private static let lastStreamKey = "stealth_last_stream_token_v1"
    private static let perStreamWindow: TimeInterval = 86_400 // 24h

    private var lastStreamConsumption: [String: Date] = [:]
    private var lastStreamLoaded = false

    private init() {}

    // MARK: - Public queries

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "stealth_mode_enabled")
    }

    /// true  = per-message (consume token on every send)
    /// false = per-stream   (consume at most once per recipient per day)
    var isPerMessage: Bool {
        UserDefaults.standard.bool(forKey: "stealth_per_message")
    }

    /// Should we build a SealedInner for this send?
    ///
    /// This returns true when stealth is globally enabled.
    ///
    /// **Scope (what we include):**
    /// - Regular user messages (text, media, voice, files, replies)
    /// - Edits (for consistency with the message being edited)
    /// - E2E delivery receipts (to prevent correlation)
    /// - Profile shares
    /// - Call signaling (high privacy value)
    ///
    /// **Explicitly excluded (even when enabled):**
    /// - E2E heartbeats (ct=13) — see decisions/stealth-heartbeat-exclusion.md
    /// - Multi-device internal traffic (SenderSync, fan-out to own devices, reset broadcasts)
    /// - Pure session control messages (END_SESSION, sessionReset*, etc.)
    ///
    /// Per-stream token consumption is handled separately in consumeTokenIfNeeded.
    /// See overall stealth scope decisions.
    func shouldUseSealedSender() -> Bool {
        isEnabled
    }

    /// Should we spend a token for this recipient under the current scope?
    func shouldConsumeToken(for recipient: String) -> Bool {
        guard isEnabled else { return false }

        if isPerMessage {
            return true
        }

        // per-stream mode
        loadLastStreamIfNeeded()

        if let last = lastStreamConsumption[recipient],
           Date().timeIntervalSince(last) < Self.perStreamWindow {
            return false
        }
        return true
    }

    /// Ask the policy whether we should attach a token right now.
    /// If yes, consumes one from the wallet and updates per-stream timestamp.
    /// Returns the token (or nil if we shouldn't / wallet empty).
    @discardableResult
    func consumeTokenIfNeeded(for recipient: String) -> BlindToken? {
        guard shouldConsumeToken(for: recipient) else {
            return nil
        }

        guard let token = TokenWalletService.shared.consumeToken() else {
            return nil
        }

        if !isPerMessage {
            lastStreamConsumption[recipient] = Date()
            saveLastStreamConsumption()
        }

        return token
    }

    // MARK: - Persistence for per-stream state

    private func loadLastStreamIfNeeded() {
        guard !lastStreamLoaded else { return }
        if let data = KeychainManager.shared.loadRawData(forKey: Self.lastStreamKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastStreamConsumption = map
        }
        lastStreamLoaded = true
    }

    private func saveLastStreamConsumption() {
        guard let data = try? JSONEncoder().encode(lastStreamConsumption) else { return }
        KeychainManager.shared.saveRawData(data, forKey: Self.lastStreamKey)
    }

    /// Call on logout or when resetting stealth state.
    func clearStreamState() {
        lastStreamConsumption.removeAll()
        KeychainManager.shared.deleteData(forKey: Self.lastStreamKey)
        lastStreamLoaded = false
    }
}
