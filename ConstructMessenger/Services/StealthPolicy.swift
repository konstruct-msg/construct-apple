//
//  StealthPolicy.swift
//  Construct Messenger
//
//  Central policy for Stealth / Sealed Sender (Ghost Mode).
//  Decides:
//  - whether to use sealed sender at all (hides sender identity from the server)
//  - whether to consume a Privacy Pass token for a send
//
//  Token model: **per-message** — a token accompanies every sealed send. The former
//  per-stream scope (1 token per recipient per 24h) was removed 2026-07-15: under
//  MSG_STEALTH_TOKEN_POLICY=enforce every sealed envelope must carry a valid token
//  (the server cannot tell message kinds apart inside the seal), so a device still on
//  per-stream would have ~all its sends dropped. A legacy explicit per-stream choice
//  in UserDefaults silently overrode the per-message default — observed on device
//  2026-07-14. See decisions/sealed-sender-anti-abuse-economics.md.
//
//  **This file no longer holds the exclusion list.** It held one until 2026-08-30, in a comment,
//  and the comment was wrong in two of its three lines: session control has been sealed since
//  2026-07-27 and heartbeats since 2026-08-30, each of which stopped being an exclusion without
//  anything here changing. What is exempt is now `SealingExemption` — a closed set of values the
//  chokepoint checks and a test pins to named files. Prose does not go red.
//

import Foundation
import Observation

@Observable
@MainActor
final class StealthPolicy {
    static let shared = StealthPolicy()

    private init() {
        Self.cleanupLegacyScopeState()
    }

    // MARK: - Public queries

    /// Always on (stealth-sealed-sender-v2 Phase 4). DEBUG builds keep a developer
    /// override via the same UserDefaults key (surfaced in Diagnostics → Developer) so
    /// the legacy identified-send path can still be exercised without recompiling;
    /// Release builds have no way to disable it.
    var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.object(forKey: "stealth_mode_enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "stealth_mode_enabled")
        #else
        true
        #endif
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
    /// - Peer session control: session_ready / tie-break ping / SESSION_RESET_INIT / END_SESSION
    ///   (2026-07-27 — decisions/sealed-sender-session-control-channel.md). These carry a directed
    ///   sender→recipient+conversation tuple; with all user traffic sealed they are now the primary
    ///   cleartext session-graph leak, so they are sealed too. Enforced fail-closed at the send
    ///   chokepoints (SessionCoordinator.sendSessionControlCore / MessagingServiceClient.sendEndSession).
    ///
    /// **What is exempt is not decided here.** A send declares `SendSealing` at the chokepoint
    /// and the only standing exemption is `.ownDevices`; see `SendSealing.swift`. This asks a
    /// narrower question — whether to build a seal at all — and the answer is the global switch.
    func shouldUseSealedSender() -> Bool {
        isEnabled
    }

    /// A Privacy Pass token accompanies every sealed send (per-message — the only
    /// model compatible with server-side enforce).
    func shouldConsumeToken() -> Bool {
        isEnabled
    }

    /// Consume one token from the wallet for a sealed send.
    /// Returns nil when stealth is disabled or the wallet is empty (the caller then
    /// sends token-less: anti-abuse degrades, anonymity and delivery stay intact).
    @discardableResult
    func consumeTokenIfNeeded() -> BlindToken? {
        guard shouldConsumeToken() else { return nil }
        return TokenWalletService.shared.consumeToken()
    }

    // MARK: - Legacy per-stream cleanup

    /// One-time cleanup of the removed per-stream scope machinery:
    /// - `stealth_per_message` UserDefaults key — a legacy explicit "per-stream" choice
    ///   beat the per-message default and made the device send token-less silently
    ///   (fatal under enforce).
    /// - Keychain per-stream consumption map (`stealth_last_stream_token_v1`).
    /// Idempotent and cheap; runs on every init so stragglers self-heal.
    private static func cleanupLegacyScopeState() {
        if UserDefaults.standard.object(forKey: "stealth_per_message") != nil {
            UserDefaults.standard.removeObject(forKey: "stealth_per_message")
            Log.info("StealthPolicy: removed legacy stealth_per_message scope override — per-message is the only model", category: "Stealth")
        }
        KeychainManager.shared.deleteData(forKey: "stealth_last_stream_token_v1")
    }
}
