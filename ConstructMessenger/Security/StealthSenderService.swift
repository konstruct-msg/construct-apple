//
//  StealthSenderService.swift
//  Construct Messenger
//
//  ConstructSEALED: sealed sender — hides sender identity from the server.
//  Analogous to Signal's Sealed Sender but without phone numbers.
//
//  Send:  seal(certBytes, recipientIdentityKey) → box
//  Recv:  unseal(sealedInner, ourIdentityPrivKey) → SenderCertificate
//  Verify: Ed25519 signature against bundle_signing_key from well-known
//

import Foundation
import CoreData
import CryptoKit
import SwiftProtobuf
import Observation

/// Opens a ConstructSEALED envelope, recovering the real sender and content type.
///
/// A protocol (rather than a direct `StealthSenderService.shared` call) so the unseal boundary
/// in `MessageRouter` is an explicit, substitutable dependency — that boundary is where
/// `f39e03b4` silently dropped every sealed control message, undetected because no test could
/// reach it. See client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md.
@MainActor
protocol SealedSenderResolving {
    func resolveSender(sealedInnerBytes: Data) -> ResolvedSender?
}

@Observable
@MainActor
final class StealthSenderService: SealedSenderResolving {
    static let shared = StealthSenderService()

    // Cache key in UserDefaults
    private static let certCacheKey = "construct.sealed_sender_cert"
    private static let certExpiryKey = "construct.sealed_sender_cert_expiry"
    /// The `currentUserId` the cached cert was issued for. The cert embeds a server-attested
    /// `senderUserID`; if the local identity changes (delete account → re-register) without the
    /// cache being cleared, a stale cert would keep sealing outgoing messages under the OLD user
    /// id — recipients then attribute them to a "ghost" identity and they never reach the new
    /// chat (the 2026-07-26 emulator→device failure). Binding the cache to its owner makes a
    /// mismatched cert self-invalidate regardless of whether `clearCertCache()` was called.
    private static let certOwnerKey = "construct.sealed_sender_cert_owner"

    private init() {}

    // MARK: - Sender Certificate (from auth-service)

    /// Returns cached cert bytes, or fetches a fresh one from auth-service.
    /// stealth-sealed-sender-v2 Phase 4: sealed sending is always on now, so this fetch
    /// sits on every message's hot path once the cache expires — bounded retry with
    /// backoff covers transient network failures instead of failing the send on the
    /// first hiccup.
    func getSenderCertificate() async throws -> Data {
        // Return cached cert if still valid (with 5-min leeway)
        if let cached = loadCachedCert() {
            return cached
        }
        let response = try await withRetry(maxAttempts: 3, backoff: 0.5, label: "getSenderCertificate") {
            try await AuthServiceClient.shared.getSenderCertificate()
        }
        cacheCert(response.certificate, expiresAt: response.expiresAt)
        // Piggyback: the server delivers its X25519 token-encryption key alongside the cert
        // (same authenticated gRPC channel, same 24h lifecycle). This is the robust source
        // for the seal key — the HTTP well-known can fail on-device (self-signed native/VEIL
        // listener + ATS), leaving the client unable to seal tokens → decrypt_failed.
        if !response.tokenEncryptionKey.isEmpty {
            await ServerKeyManager.shared.cacheFromGRPC(response.tokenEncryptionKey)
        }
        return response.certificate
    }

    private func loadCachedCert() -> Data? {
        guard
            let data = UserDefaults.standard.data(forKey: Self.certCacheKey),
            let expiry = UserDefaults.standard.object(forKey: Self.certExpiryKey) as? Double,
            Date().timeIntervalSince1970 < expiry - 300 // 5-min leeway
        else { return nil }
        // Identity binding: reject a cert cached under a DIFFERENT user id (stale after a
        // delete-account → re-register without clearCertCache). Sealing with it would attribute
        // our messages to the old "ghost" identity. A nil/empty owner means legacy cache written
        // before this key existed — treat as stale and refetch (cheap, once).
        let owner = UserDefaults.standard.string(forKey: Self.certOwnerKey)
        guard let owner, !owner.isEmpty, owner == AuthSessionManager.shared.currentUserId else {
            Log.info("Stealth: discarding cached sender cert — owner \(owner?.prefix(8).description ?? "nil") ≠ current \(AuthSessionManager.shared.currentUserId?.prefix(8).description ?? "nil"); refetching", category: "Stealth")
            return nil
        }
        return data
    }

    private func cacheCert(_ cert: Data, expiresAt: Int64) {
        UserDefaults.standard.set(cert, forKey: Self.certCacheKey)
        UserDefaults.standard.set(Double(expiresAt), forKey: Self.certExpiryKey)
        UserDefaults.standard.set(AuthSessionManager.shared.currentUserId, forKey: Self.certOwnerKey)
    }

    /// Call when logging out / identity changes (delete account, re-register, local reset).
    func clearCertCache() {
        UserDefaults.standard.removeObject(forKey: Self.certCacheKey)
        UserDefaults.standard.removeObject(forKey: Self.certExpiryKey)
        UserDefaults.standard.removeObject(forKey: Self.certOwnerKey)
    }

    // MARK: - Verify / attest (stored state and test seams)

    #if DEBUG
    /// Test seam: additional trusted bundle keys (raw 32-byte) handed to the core beside the real
    /// ones, to exercise the pin/rotation path without shipping a private key for a real pin.
    /// Empty in production paths.
    var extraTrustedBundleKeysForTesting: [Data] = []
    #endif

    #if DEBUG
    /// Test seam: the core to ask instead of `CryptoManager.shared`'s, which unit tests do not
    /// start. A real core either way — the verdict is never stubbed.
    var verdictCoreForTesting: OrchestratorCore?
    #endif

    #if DEBUG
    /// Test seam: overrides the KT-verified-identity lookup so unit tests exercise the KT
    /// cross-check without a Core Data stack. `nil` (default) uses the real `User` store.
    var ktLookupOverrideForTesting: ((String) -> (key: Data, status: KTStatus)?)?
    #endif

    /// The account address a sealed envelope names its recipient by. Injected so a test can build
    /// an envelope without a store — but read on every send, so it exists in every build.
    var accountAddressLookup: (String) -> Data? = { accountId in
        AccountAddress.of(accountId: accountId)
    }

}

/// Whose device a sealed copy we cannot open was addressed to.
///
/// Carried as the label on `stealth_copy_for_sibling`, replacing the call-site name that had
/// been there — there is one call site, so that label said nothing. See
/// `StealthSenderService.classifyOtherDevice(_:ourDeviceIds:)` for why the three cases are
/// three different states rather than a yes and a no.
enum SealedCopyOrigin: String {
    case sibling
    case notOurs = "not_ours"
    case unverified
}

enum StealthError: Error {
    case invalidBoxLength
    case decryptionFailed
    case invalidCertificate
    case expired
}

// MARK: - sealed-sender-resilience trust model

/// How a sealed sender's identity binding was attested.
///  - `.kt` (lever C): the cert's identity key matches the recipient's locally stored,
///    KT-`.verified` `knownIdentityKey` for that contact — the strongest verdict, with
///    zero dependency on any bundle key / well-known / landing.
///  - `.signature` (lever B): the cert's Ed25519 signature validated against a
///    fetched-or-pinned bundle key. Fallback used for first contact (no local KT key yet).
enum SenderVouchBasis: Equatable {
    case kt
    case signature
    /// A session envelope: the writer is the device whose session pair the tag matched. Vouched
    /// by the session itself — post-quantum, and no server key involved.
    case session
}

/// Why an attestation did not vouch. Delivery proceeds anyway (ratchet is the real
/// auth); the reason is only for DEBUG telemetry and self-healing (a `.noKey`/`.badSignature`
/// kicks a background bundle-key refresh).
enum SenderVouchReason: Equatable {
    case expired       // cert past its expires_at
    case badSignature  // signature did not validate against any trusted bundle key
    case noKey         // no usable bundle key at all (fetched nil AND pins unusable)
}

enum SenderTrust: Equatable {
    case vouched(SenderVouchBasis)
    case unvouched(SenderVouchReason)
}

/// Result of unsealing a ConstructSEALED message: the recovered sender + content type
/// plus the attestation verdict. Returned by `StealthSenderService.resolveSender`;
/// `nil` from that call means the box could not be opened at all.
struct ResolvedSender: Equatable {
    let senderId: String
    /// The device that wrote this message, from `SenderCertificate.sender_device_id`.
    ///
    /// The sealed path is the only one that can answer this. The relay blanks
    /// `Envelope.sender_device` on delivery on purpose — server metadata must not carry E2E
    /// meaning — so before the unseal the field is empty on every delivered message, and §D
    /// tried to recover it from a tag on the wire id. That id does not survive: the sealed
    /// branch of `send_message` rebuilds the delivered envelope from `sealed_inner` alone and
    /// stamps a server id, so the tag was written into the one field guaranteed not to arrive
    /// (see `ServerMessageIdMap`, which exists because the sender has to translate that id back).
    ///
    /// The certificate was already the answer. `identity-service` fills `sender_device_id` from
    /// the caller's `x-device-id`, checks it against an active row in `devices`, and covers it
    /// with the same signature that vouches the sender. It is sealed to the recipient's identity
    /// key, so the relay never reads it — which is the property §D wanted and a MAC only
    /// approximates.
    ///
    /// Not gated on `trust`: an unvouched certificate makes this an unauthenticated claim, and so
    /// is `senderId` beside it, which already routes. Naming the wrong device costs one failed
    /// decrypt before the walk resumes; the ratchet is the real auth here as everywhere else.
    let senderDeviceId: String
    let contentType: UInt8
    let trust: SenderTrust
    /// The certificate as unsealed, for the core. It is what a first message opens a session
    /// from: the key it names is the key the session opens with, once the core has checked the
    /// server's signature (`decisions/first-message-opens-without-the-server.md`). `trust` above is
    /// this app's label for the transcript; it does not decide whether a session opens.
    /// `nil` for a session envelope, which names the writer by its session instead.
    let senderCertificate: SenderCertificate?
    /// Set when the message came in a session envelope: the session its tag matched and the
    /// opened body (the wire payload, or a DECRYPTION_ERROR).
    let envelope: OpenedSessionEnvelope?
    /// Set when the message came as a first flight sealed whole: the wire payload that was inside
    /// it beside the certificate (`SealedInner.first_flight`).
    let firstFlightPayload: Data?

    init(
        senderId: String,
        senderDeviceId: String,
        contentType: UInt8,
        trust: SenderTrust,
        senderCertificate: SenderCertificate?,
        envelope: OpenedSessionEnvelope? = nil,
        firstFlightPayload: Data? = nil
    ) {
        self.senderId = senderId
        self.senderDeviceId = senderDeviceId
        self.contentType = contentType
        self.trust = trust
        self.senderCertificate = senderCertificate
        self.envelope = envelope
        self.firstFlightPayload = firstFlightPayload
    }
}

/// What `CryptoManager.openEnvelope` gave back, as the receive path needs it.
struct OpenedSessionEnvelope: Equatable {
    let sessionId: String
    let body: Data
}
