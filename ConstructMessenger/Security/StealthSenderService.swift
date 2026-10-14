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

    // MARK: - Seal / unseal
    //
    // The box is the core's (`sealed_seal_sender_cert`, `OrchestratorCore.open_sealed_to_device`).
    // Until 2026-09-29 this file carried its own CryptoKit copy of it, and opening needed our
    // identity private key read from the Keychain on every sealed message.

    /// Encrypts `certBytes` (serialized SenderCertificate proto) to the recipient's
    /// X25519 identity key.
    func sealSenderCert(_ certBytes: Data, recipientIdentityKey: Data) throws -> Data {
        try sealedSealSenderCert(certBytes: certBytes, recipientIdentityKey: recipientIdentityKey)
    }

    /// Opens a sealed sender certificate with this device's identity key, inside the core.
    func unsealSenderCert(_ sealedBox: Data) throws -> Shared_Proto_Core_V1_SenderCertificate {
        let certBytes = try CryptoManager.shared.openSealedToDevice(sealedBox)
        return try Shared_Proto_Core_V1_SenderCertificate(serializedBytes: certBytes)
    }

    // MARK: - Verify / attest

    #if DEBUG
    /// Test seam: additional trusted bundle keys (raw 32-byte) handed to the core beside the real
    /// ones, to exercise the pin/rotation path without shipping a private key for a real pin.
    /// Empty in production paths.
    var extraTrustedBundleKeysForTesting: [Data] = []
    #endif

    /// The core's verdict on the certificate, as this app's label. Until 2026-10-03 this was an
    /// Ed25519 check written here, beside the one the core makes before opening a session from the
    /// same certificate; the two disagreed on age (the core allows the relay's 7 days) and on the
    /// device (the core checks the key derives to it). One check now, the core's, which also knows
    /// the delegated hybrid keys (`decisions/server-keys-rooted-offline-and-hybrid.md`).
    ///
    /// Returns a *reason* rather than a bare Bool so the caller can tell "no key to check with"
    /// apart from "signature genuinely bad" (the 2026-07-05 nil-key failure was mislogged as
    /// `signature invalid` when they were conflated).
    func coreVerdict(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> CertificateVerdict {
        #if DEBUG
        let extra = extraTrustedBundleKeysForTesting
        if let core = verdictCoreForTesting {
            core.setTrustedServerKeys(keys: BundleSigningTrust.trustedKeyBytes() + extra)
            return core.certificateVerdict(certificate: SenderCertificate(proto: cert))
        }
        #else
        let extra: [Data] = []
        #endif
        return CryptoManager.shared.certificateVerdict(SenderCertificate(proto: cert), extraKeys: extra)
            ?? .noKey
    }

    #if DEBUG
    /// Test seam: the core to ask instead of `CryptoManager.shared`'s, which unit tests do not
    /// start. A real core either way — the verdict is never stubbed.
    var verdictCoreForTesting: OrchestratorCore?
    #endif

    /// The signature half of the label: what the core says, expiry aside.
    func attestSignature(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> SenderTrust {
        switch coreVerdict(cert) {
        case .vouched, .expired: return .vouched(.signature)
        case .noKey: return .unvouched(.noKey)
        case .badSignature: return .unvouched(.badSignature)
        }
    }

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

    /// The recipient's locally stored, previously-KT-verified identity key for `userId`
    /// (plus its status), read from their contact row. `nil` for a first contact
    /// (no bundle fetched / verified yet). sealed-sender-resilience lever C source.
    private func ktVerifiedIdentity(for userId: String) -> (key: Data, status: KTStatus)? {
        #if DEBUG
        if let override = ktLookupOverrideForTesting { return override(userId) }
        #endif
        guard let contact = try? LocalRepositories.contacts.contact(userId),
              let key = contact.knownIdentityKey else { return nil }
        return (key, contact.ktStatus)
    }

    /// The full attestation verdict for an unsealed certificate. Never gates delivery —
    /// only labels trust. Ladder, strongest-first (sealed-sender-resilience §2 lever C):
    ///  1. Expiry: an expired cert is `.unvouched(.expired)` regardless of KT match — the
    ///     cert TTL bounds replay of an old sealed message (delivery still proceeds).
    ///  2. KT: cert identity key == our KT-`.verified` `knownIdentityKey` for the sender →
    ///     `.vouched(.kt)`, no bundle key involved at all. A `.keyChanged`/`.failed`/
    ///     `.unverified` status does NOT vouch even on a key match (that is exactly the
    ///     MITM-suspicion case KT exists to catch).
    ///  3. Signature (lever B): fall back to the bundle-key check for a first contact.
    func attest(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> SenderTrust {
        let verdict = coreVerdict(cert)
        if verdict == .expired { return .unvouched(.expired) }

        if let kt = ktVerifiedIdentity(for: cert.senderUserID),
           kt.status == .verified,
           kt.key == cert.senderIdentityKey {
            return .vouched(.kt)
        }

        switch verdict {
        case .vouched, .expired: return .vouched(.signature)
        case .noKey: return .unvouched(.noKey)
        case .badSignature: return .unvouched(.badSignature)
        }
    }

    // MARK: - Resolve sender (receive path, full pipeline)

    /// Decrypts SealedInner bytes to recover the sender user ID, the real content type
    /// carried inside SealedInner (stealth-sealed-sender-v2 Phase 3 — the outer
    /// Envelope.content_type is forced generic for sealed sends, so this is the only
    /// place the recipient can recover whether this was a message/receipt/call signal),
    /// and an attestation verdict.
    ///
    /// sealed-sender-resilience lever A: returns `nil` **only** when the sealed box
    /// itself cannot be opened (no sender/payload recoverable). An expired or
    /// unverifiable certificate is NOT a nil — the sender id and payload are already in
    /// hand, so the caller delivers the message `.unvouched` through the normal ratchet
    /// decrypt (which is the real authentication) instead of dropping it. The
    /// certificate is anti-abuse/anonymity metadata, not the security root.
    /// The device this sealed copy names, when that device is not this one.
    ///
    /// `SealedInner.recipient_device` is plaintext by design — the field exists so the relay can
    /// write the copy to one mailbox instead of all of them — and until now nothing read it back.
    /// The sender has populated it since §A.0; this is the missing consumer.
    ///
    /// It matters because the alternative is not a wasted parse. While `MSG_MAILBOX_USER_WRITE=1`
    /// every device of an account still receives the whole account stream, so each sibling's copy
    /// lands here, fails to unseal — it is sealed to a key we do not have — and is then treated as
    /// a *broken* message: deferred for a redelivery that cannot succeed, holding the stream cursor
    /// for the round trip, triggering a bundle-key refresh, and counting against
    /// `stealth_unseal_failure`, which is one of the numbers the release gate reads. On a
    /// multi-device account that is every message to every sibling. It is the 155-of-155 shape the
    /// Desktop investigation started from.
    ///
    /// **Empty is not a mismatch.** An empty `recipient_device` means the sender predates the
    /// field, and an empty local identity means the Keychain is unreadable. Either way we cannot
    /// tell, and the honest answer is "no" — the ordinary path then reports the failure as it
    /// always did. Only a device id that is present, ours is present, and the two differ, is a
    /// copy we can be sure was never meant for us.
    ///
    /// A parse failure is likewise not a mismatch: a `SealedInner` we cannot read is exactly the
    /// corruption the normal path exists to report.
    ///
    /// **It returns the id rather than a `Bool`** because the `Bool` could not say *whose* device
    /// it was, and the answer to that is the difference between an expected duplicate and a
    /// misrouted envelope. On 2026-09-02 a run that was supposed to be one device per account
    /// dropped ten copies here; establishing that they belonged to a powered-off Desktop on our
    /// own account, rather than to a stranger, took six passes of reverse-tracing message ids
    /// across two logs, because the only thing recorded was that a copy had been dropped. See
    /// `classifyOtherDevice(_:ourDeviceIds:)`, which is the half that needs the account.
    ///
    /// `nonisolated`: it reads two arguments and no actor state, and the receive path that
    /// calls it has no reason to be pinned to the main actor for a plaintext field comparison.
    nonisolated static func otherDeviceAddressed(sealedInnerBytes: Data, ourDeviceId: String) -> String? {
        guard !ourDeviceId.isEmpty,
              let inner = try? Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInnerBytes),
              !inner.recipientDevice.isEmpty,
              inner.recipientDevice != ourDeviceId
        else { return nil }
        return inner.recipientDevice
    }

    /// Whose device a copy we cannot open was addressed to.
    ///
    /// The drop is right in every case — a copy sealed to a key we do not hold can never open
    /// here — so this changes no behaviour. What it changes is what the number means, and the
    /// three cases are three different states of the system:
    ///
    /// - `.sibling` — a device of our own account. Expected while `MSG_MAILBOX_USER_WRITE=1`
    ///   writes every message to the account-wide stream; the count is the measure of that
    ///   duplication and should fall to zero on its own after the cutover.
    /// - `.notOurs` — a device that is not in our account's **current** active set. Two causes
    ///   this cannot separate locally, which is why the name says what is known rather than what
    ///   is suspected: the relay wrote a copy into a mailbox it does not belong in, or the device
    ///   was ours and has since been revoked. A revoke is always followed by a burst of these,
    ///   because the mailbox still holds copies addressed to the device that was removed — 24 of
    ///   them on 2026-09-02, every one from the backlog. So a single reading is not a defect; a
    ///   count that keeps rising on a run with no recent revoke is.
    /// - `.unverified` — our own device set is not known in this process yet. **Not `.notOurs`.**
    ///   An empty set is the state of a cold cache, and reporting a verdict from an absent fact is
    ///   the same trap as reading a missing Prometheus series as a zero.
    nonisolated static func classifyOtherDevice(_ deviceId: String, ourDeviceIds: [String]) -> SealedCopyOrigin {
        guard !ourDeviceIds.isEmpty else { return .unverified }
        return ourDeviceIds.contains(deviceId) ? .sibling : .notOurs
    }

    func resolveSender(sealedInnerBytes: Data) -> ResolvedSender? {
        let cert: Shared_Proto_Core_V1_SenderCertificate
        let contentType: UInt8
        var firstFlightPayload: Data?
        do {
            let sealedInner = try Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInnerBytes)
            if !sealedInner.sessionEnvelope.isEmpty {
                return resolveEnvelopeSender(sealedInner.sessionEnvelope)
            }
            if !sealedInner.firstFlight.isEmpty {
                let opened = try CryptoManager.shared.openFirstFlight(sealedInner.firstFlight)
                cert = try Shared_Proto_Core_V1_SenderCertificate(serializedBytes: opened.certificate)
                firstFlightPayload = opened.wirePayload
            } else {
                guard !sealedInner.senderCertCiphertext.isEmpty else { return nil }
                cert = try unsealSenderCert(sealedInner.senderCertCiphertext)
            }
            contentType = UInt8(sealedInner.contentType.rawValue)
        } catch {
            // Unseal failed — genuinely unrecoverable (wrong key / corruption / not for us).
            Log.error("Stealth: unseal failed: \(error)", category: "Stealth")
            return nil
        }

        // Attestation (never gates delivery — only tags trust): expiry → KT → signature.
        let trust = attest(cert)
        switch trust {
        case .vouched(let basis):
            Log.debug("Stealth: resolved sender \(cert.senderUserID.prefix(8))… (vouched via \(basis))", category: "Stealth")
        case .unvouched(let reason):
            Log.info("Stealth: resolved sender \(cert.senderUserID.prefix(8))… UNVOUCHED (\(reason)) — delivering via ratchet", category: "Stealth")
        }
        // Expiry bounds replay of this envelope; the identity key is still theirs if the
        // signature vouches. Pinning it here is what lets a later sealed *send* proceed
        // for a contact whose bundle path never kept the key (IK_MISS[no_key], 2026-08-19).
        //
        // `attest` above has already verified the signature whenever it returned
        // `.vouched(.signature)`, and this runs once per incoming sealed message — the
        // 2026-08-19 replay put 4211 of them through in 65 seconds, so verifying twice is
        // not free. Every other verdict re-verifies, because none of them is a statement
        // about the signature: `.expired` short-circuits before `attest` looks at it, and
        // `.kt` is a different basis entirely.
        if case .vouched(.signature) = trust {
            pinIdentity(cert)
        } else {
            rememberIdentityFromCertificate(cert)
        }
        return ResolvedSender(
            senderId: cert.senderUserID,
            senderDeviceId: cert.senderDeviceID,
            contentType: contentType,
            trust: trust,
            senderCertificate: SenderCertificate(proto: cert),
            firstFlightPayload: firstFlightPayload
        )
    }

    /// A session envelope names its writer by the session pair its tag matches, which the core
    /// finds (`decisions/sealed-envelope-keyed-by-the-session.md`). The kind byte inside it says
    /// whether the body is a wire payload or a DECRYPTION_ERROR (28); the outer content type is
    /// generic for both, so the server cannot tell them apart.
    private func resolveEnvelopeSender(_ envelope: Data) -> ResolvedSender? {
        guard let opened = CryptoManager.shared.openEnvelope(envelope) else {
            // No pair matches: not ours, or from a session this device never held — the same
            // drop path as a box that does not open.
            Log.error("Stealth: no session envelope pair matched", category: "Stealth")
            return nil
        }
        guard let account = Self.account(ofEnvelopeWriter: opened.contactId) else {
            Log.error(
                "Stealth: envelope writer \(opened.contactId.prefix(8))… is in no known account",
                category: "Stealth"
            )
            return nil
        }
        let decryptionErrorKind: UInt8 = 2
        let contentType = opened.kind == decryptionErrorKind
            ? UInt8(Shared_Proto_Core_V1_ContentType.decryptionError.rawValue)
            : UInt8(Shared_Proto_Core_V1_ContentType.unspecified.rawValue)
        if opened.retired {
            Log.info(
                "Stealth: envelope from \(opened.contactId.prefix(8))… on a session no longer held — the core answers it",
                category: "Stealth"
            )
        }
        return ResolvedSender(
            senderId: account,
            senderDeviceId: opened.contactId,
            contentType: contentType,
            trust: .vouched(.session),
            senderCertificate: nil,
            envelope: OpenedSessionEnvelope(sessionId: opened.sessionId, body: opened.body)
        )
    }

    /// The account a session envelope's writer belongs to: a peer device from the device set or
    /// the pinned key, or one of our own devices (SENDER_SYNC).
    private static func account(ofEnvelopeWriter deviceId: String) -> String? {
        if let peer = SessionAddressing.peer(ofDevice: deviceId) {
            return peer.accountId
        }
        guard let me = AuthSessionManager.shared.currentUserId, !me.isEmpty else { return nil }
        let ours = MultiDeviceSendCoordinator.shared.knownOwnDeviceIds(myUserId: me)
        return ours.contains(deviceId) ? me : nil
    }

    /// Pin `cert.senderIdentityKey` when the signature vouches, ignoring expiry.
    ///
    /// `attest` returns `.unvouched(.expired)` before it ever looks at the signature, so a
    /// contact we have been receiving sealed mail from can still have `knownIdentityKey ==
    /// nil`. The send path then fails closed forever. Signature-vouched is the same TOFU
    /// `rememberIdentityKeyIfUnknown` already accepts from a bundle fetch.
    ///
    /// Verifies the signature itself. The one caller that has already verified it takes
    /// `pinIdentity` instead — see there for why that shortcut is not a parameter on this method.
    func rememberIdentityFromCertificate(_ cert: Shared_Proto_Core_V1_SenderCertificate) {
        guard case .vouched = attestSignature(cert) else { return }
        pinIdentity(cert)
    }

    /// Pin without verifying. **Only reachable from a branch that has just verified.**
    ///
    /// This started as an `alreadyAttested:` parameter on `rememberIdentityFromCertificate`,
    /// which made "the signature is good" something a caller asserts rather than something the
    /// code establishes — in the one method whose entire job is deciding whether to trust a key.
    /// A private function whose proof is three lines above its only call site cannot be handed a
    /// lie by a future caller; a defaulted parameter can.
    private func pinIdentity(_ cert: Shared_Proto_Core_V1_SenderCertificate) {
        guard !cert.senderUserID.isEmpty, !cert.senderIdentityKey.isEmpty else { return }
        ContactLinkService.shared.rememberIdentityKeyIfUnknown(
            userId: cert.senderUserID,
            identityKey: cert.senderIdentityKey,
            source: "sealed_cert",
            // Driven by an incoming envelope. A sender must not be able to put a row in our
            // store by sending to us — that is how a deleted contact kept coming back while
            // the server replayed their backlog (device logs 2026-08-19).
            createIfMissing: false
        )
    }

    // MARK: - Build SealedInner for sending

    /// Builds SealedInner proto bytes for a sealed sender message.
    ///
    /// `SealedInner` is a **plaintext** proto — the relay parses it — so `content_type` here is
    /// server-visible. Since 2026-08-03 the real type rides in KNST byte 5 inside the ciphertext,
    /// and this field is limited to the two types that must be recognised before decryption. The
    /// parameter is a `SealedEnvelopeType` and not a raw proto enum so that limit is a compile
    /// error rather than a convention: `.generic` serialises to nothing at all.
    func buildSealedInner(
        recipientUserId: String,
        certBytes: Data,
        recipientIdentityKey: Data,
        encryptedPayload: Data,
        contentType: SealedEnvelopeType,
        spendUnit: TokenSpendUnit? = nil,
        /// Set by the one-shot retry in `StealthSendRecovery` after the server refused a sealed
        /// envelope on Privacy Pass grounds. Such a refusal proves the intake credential was not
        /// honoured — had it been, the server would never have looked at tokens — so the rebuilt
        /// envelope must pay rather than present the same credential and be refused identically.
        afterCredentialRejection: Bool = false,
        /// A session envelope the core sealed (`CryptoManager.sealEnvelope`, or a DECRYPTION_ERROR
        /// it built). When set, it replaces both the certificate and `encryptedPayload`: the
        /// session names the writer, and the wire payload is inside it.
        sessionEnvelope: Data? = nil,
        /// A first flight the core sealed whole (`CryptoManager.sealFirstFlight`): the certificate
        /// and the wire payload are inside it, so it replaces both as an envelope does.
        firstFlight: Data? = nil
    ) async throws -> Data {
        var inner = Shared_Proto_Core_V1_SealedInner()
        // The recipient by their address when this device knows it, by the server's id otherwise.
        // Only this field: the intake credential and the token below stay keyed by the account
        // id, because the server resolves the address to that id before it checks either.
        inner.recipientUserID = AccountAddress.recipientField(
            accountId: recipientUserId,
            address: accountAddressLookup(recipientUserId)
        )
        // The one device this envelope is for. Derived from the very key the certificate was
        // just sealed to, and not passed in or looked up, because those are the two ways it
        // could disagree with the ciphertext: a parameter can be handed the wrong device by a
        // future caller, and a store lookup answers about the account rather than about these
        // bytes. Deriving makes "who this is sealed to" and "who this is routed to" one value.
        //
        // Empty is this field's own "every active device of the recipient" — what every sealed
        // envelope meant before it existed, and why a peer's other devices each received a
        // ciphertext they could not decrypt. `sealSenderCert` on the line above has already
        // accepted this key, so it is a valid 32-byte X25519 public key and the derivation
        // cannot return nil here; `?? ""` rather than a force-unwrap so that the impossible case
        // degrades to that old delivery instead of trapping a send that is otherwise fine.
        inner.recipientDevice = SessionAddressing.cryptoIdentity(ofIdentityKey: recipientIdentityKey) ?? ""
        if let sessionEnvelope {
            inner.sessionEnvelope = sessionEnvelope
        } else if let firstFlight {
            inner.firstFlight = firstFlight
        } else {
            inner.senderCertCiphertext = try sealSenderCert(certBytes, recipientIdentityKey: recipientIdentityKey)
            inner.encryptedPayload = encryptedPayload
        }
        // `.generic` is UNSPECIFIED = 0, which proto3 omits — the field does not reach the wire.
        inner.contentType = contentType.proto
        inner.deliveryTag = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        // Present only on multi-envelope messages. A nil unit leaves the field empty, which the
        // server reads as legacy per-envelope redemption — the path every single-envelope send
        // still takes, unchanged.
        if let spendUnit {
            inner.tokenSpendID = spendUnit.spendId
        }

        // A token accompanies every sealed send (per-message — the only model compatible
        // with server-side enforce; per-stream removed 2026-07-15). `wantedToken` is
        // captured before consuming so "stealth disabled" is distinguishable from
        // "wallet empty" in the else-branch logging below.
        //
        // Within a spend unit only one envelope pays; the rest ride on its redemption. The
        // payer is whoever *succeeds*, not whoever is first — see TokenSpendUnit for why an
        // empty wallet on chunk 0 must not condemn chunks 1…29.
        // An envelope the recipient has vouched for owes nothing, so the token machinery below is
        // skipped entirely. Attached per envelope rather than per spend unit: the tag is bound to
        // the recipient and the epoch, not to this message, so every envelope of a vouched send
        // carries the same one and none of them needs a unit to ride on.
        //
        // Nil is the ordinary case during rollout — we hold no key for this peer yet — and it is
        // not a failure: the envelope pays with a token exactly as it did before this existed.
        // Grandfathering is lazy by decision, so the peer's key arrives the first time they write
        // to us rather than in a sweep.
        //
        // A rebuild after a Privacy Pass refusal declines the credential outright. The refusal is
        // the server saying it did not accept it, and presenting it again buys the identical
        // refusal — which is what turned a 17-to-8 `unrecognised`-to-`vouched` ratio into failed
        // sends on 2026-09-14 rather than into envelopes that simply paid.
        let intakeTagSealed: Data?
        if afterCredentialRejection {
            IntakeCredentialService.shared.noteCredentialRejected(forRecipient: recipientUserId)
            intakeTagSealed = nil
        } else {
            intakeTagSealed = await IntakeCredentialService.shared.sealedTag(forRecipient: recipientUserId)
        }
        if let intakeTagSealed {
            inner.intakeTagSealed = intakeTagSealed
        }

        let unitAlreadyPaid = spendUnit.map { !$0.shouldAttemptPayment } ?? false
        let wantedToken = intakeTagSealed == nil && TokenSpendUnit.shouldAttemptPayment(
            policyWantsToken: StealthPolicy.shared.shouldConsumeToken(),
            unitPaid: unitAlreadyPaid
        )
        // Peek the server token-encryption key BEFORE consuming a wallet token. An
        // unsealable token is rejected server-side (`decrypt_failed`, fatal under enforce),
        // so if we cannot seal we must NOT spend the token — leave it in the wallet for a
        // later send once the key is cached (it arrives via GetSenderCertificateResponse).
        let canSeal = await ServerKeyManager.shared.hasTokenEncryptionKey()
        // An empty wallet is not a verdict — it is a race with issuance. Reading it once and
        // stepping over it is how 93 of 271 sealed sends in one busy hour went out token-less
        // *past a batch that was already in flight* (the 99 "replenishment already in progress"
        // lines are the same event from the issuer's end). Under enforce those are rejected
        // sends, so the wait is cheaper than the failure. Bounded, and skipped entirely while
        // the issuer is backing us off — see BlindTokenService.ensureTokenAvailable.
        if wantedToken, canSeal, TokenWalletService.shared.balance == 0 {
            await BlindTokenService.shared.ensureTokenAvailable()
        }
        if intakeTagSealed != nil {
            // The one line that distinguishes "vouched" from "wallet empty" in a device log. Both
            // send without a token; only one of them is the mechanism working.
            Log.info("Stealth: sealed send VOUCHED by intake tag — no token owed", category: "Stealth")
        } else if unitAlreadyPaid {
            // Covered by an earlier envelope of the same logical message. Deliberately silent
            // about the wallet — nothing was spent. Logged so an album's cost is legible in a
            // device log as one WITH-token line followed by N covered ones.
            Log.debug(
                "Stealth: sealed send covered by unit \(spendUnit?.spendId.prefix(4).map { String(format: "%02x", $0) }.joined() ?? "") — no token spent",
                category: "Stealth"
            )
        } else if wantedToken, canSeal,
           let token = StealthPolicy.shared.consumeTokenIfNeeded(),
           let sealedToken = await ServerKeyManager.shared.sealTokenBytes(token.token) {
            inner.tokenNonce = token.nonce
            // token_bytes sealed to the server's X25519 key so relay operators cannot read
            // the spent token (VEIL ghost-mode) and the server can redeem it.
            inner.tokenBytes = sealedToken
            // Only now is the unit paid for. Marking it before the seal succeeded would leave
            // the remaining envelopes riding on a redemption that never happened.
            spendUnit?.markPaid()
            // Positive-path visibility: confirms a token was actually attached (successful
            // consume was previously silent — the wallet could only be inferred, not seen).
            Log.info("Stealth: sealed send WITH token (wallet=\(TokenWalletService.shared.balance) left)", category: "Stealth")
        } else if wantedToken {
            // Policy wanted a token but we sent without one — seal + send anyway (the
            // certificate seal hides the sender regardless). Anti-abuse degraded, anonymity
            // intact — the invariant we deliberately preserve. Distinguish the two causes so
            // an on-device diagnosis is unambiguous:
            //   • server key not yet cached → cannot seal (kick a fetch so the next send seals)
            //   • wallet empty → issuance not keeping up
            PerformanceMetrics.shared.record(.stealthTokenlessSend, label: String(recipientUserId.prefix(8)))
            if !canSeal {
                Log.info("Stealth: sealed send WITHOUT token — server key not yet cached, cannot seal (would-be decrypt_failed avoided)", category: "Stealth")
                Task { await ServerKeyManager.shared.prefetch() }
            } else {
                Log.info("Stealth: sealed send WITHOUT token — wallet empty (anti-abuse degraded, anonymity intact)", category: "Stealth")
            }
        }

        // Reactive top-up: per-message scope drains the wallet steadily, so refill toward
        // the server hourly cap as we spend rather than waiting for foreground/background
        // triggers. No-op when the wallet is above the low-water mark or within cooldown.
        Task { await BlindTokenService.shared.topUpIfLow() }

        return try inner.serializedData()
    }

    /// Static bridge for calling from non-MainActor contexts (e.g. ChunkedMessageSender).
    /// getSenderCertificate() already handles caching; we just hop to MainActor for the async call.
    static func buildSealedInner(
        recipientUserId: String,
        recipientIdentityKey: Data,
        encryptedPayload: Data,
        contentType: SealedEnvelopeType,
        spendUnit: TokenSpendUnit? = nil,
        afterCredentialRejection: Bool = false,
        /// A session envelope the core already sealed — a DECRYPTION_ERROR answered along a pair.
        envelope: Data? = nil
    ) async throws -> Data {
        // A message on an established session goes as a session envelope: the core seals it, or
        // says it must go with a certificate (a first flight, or a session older than the
        // envelope). Only a wire payload is ever offered — a DECRYPTION_ERROR the core already
        // sealed arrives as `envelope`.
        var sessionEnvelope = envelope
        if sessionEnvelope == nil, contentType == .generic,
           let device = SessionAddressing.cryptoIdentity(ofIdentityKey: recipientIdentityKey) {
            sessionEnvelope = CryptoManager.shared.sealEnvelope(forDevice: device, wirePayload: encryptedPayload)
        }
        // No certificate is fetched for an envelope: nothing in it would carry one.
        // getSenderCertificate is @MainActor async — call it directly (will hop automatically)
        let certBytes = sessionEnvelope == nil
            ? try await StealthSenderService.shared.getSenderCertificate()
            : Data()
        // A first flight goes sealed whole: its PQXDH header names the initiator's KEM identity
        // key, which must not travel beside the certificate box (FF-1,
        // `decisions/first-flight-sealed-whole.md`). The core says whether this payload is one;
        // a throw is a first flight it could not seal, and that one is not sent at all.
        var firstFlight: Data?
        if sessionEnvelope == nil,
           let device = SessionAddressing.cryptoIdentity(ofIdentityKey: recipientIdentityKey) {
            firstFlight = try CryptoManager.shared.sealFirstFlight(
                forDevice: device,
                recipientIdentityKey: recipientIdentityKey,
                wirePayload: encryptedPayload,
                certificate: certBytes
            )
        }
        return try await StealthSenderService.shared.buildSealedInner(
            recipientUserId: recipientUserId,
            certBytes: certBytes,
            recipientIdentityKey: recipientIdentityKey,
            encryptedPayload: encryptedPayload,
            contentType: contentType,
            spendUnit: spendUnit,
            afterCredentialRejection: afterCredentialRejection,
            sessionEnvelope: sessionEnvelope,
            firstFlight: firstFlight
        )
    }

    /// Resolve the recipient's Curve25519 identity public key (for sealing) from the persisted `User`
    /// row, or nil if not known yet. Keyed strictly by `recipientId` so it is unambiguous from any
    /// send path (the shared source used by both the live-send and retry paths). Callers gate on
    /// `StealthPolicy.shared.shouldUseSealedSender()` and, when this returns nil under stealth-on,
    /// MUST queue rather than send identified (see `StealthDowngradeBlocked`). Reads saved state,
    /// from any thread.
    static func recipientIdentityKey(recipientId: String) -> Data? {
        let user = try? LocalRepositories.contacts.contact(recipientId)
        if let key = user?.knownIdentityKey { return key }

        // `recipientId` may be a **device id**: the core names contacts that way, and the paths
        // that reach here from a core action — END_SESSION above all — pass what the core gave
        // them. `User.id` is an account id, so that lookup finds nothing and the sealed send fails
        // closed. Resolve it the other way round before giving up.
        //
        // This is not a fallback for a missing pin; it is the same pin, reached from the other
        // space. If it also finds nothing, the two misses below are the real diagnosis.
        if SessionAddressing.isCryptoIdentity(recipientId),
           let key = SessionAddressing.identityKey(ofDevice: recipientId) {
            return key
        }
        // A miss here fails every sealed send to this peer closed, permanently, and the thrown
        // `StealthDowngradeBlocked` only says the key is absent — never which absence it is. That
        // gap is why TODO #45 could not be attributed to a branch from a device log. The two cases
        // have different causes and different fixes, so they get different lines.
        Log.error(
            user == nil
                ? "IK_MISS[no_row]: no User row for \(recipientId.prefix(8))… (\(SessionAddressing.isCryptoIdentity(recipientId) ? "a device id, and no pinned key derives to it" : "an account id")) — sealed send cannot proceed"
                : "IK_MISS[no_key]: User row for \(recipientId.prefix(8))… exists but knownIdentityKey is nil (isContact=\(user!.isContact) kt=\(user!.ktStatus)) — sealed send cannot proceed",
            category: "Stealth"
        )
        return nil
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
