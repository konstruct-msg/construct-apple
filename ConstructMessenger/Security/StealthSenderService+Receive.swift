//
//  StealthSenderService+Receive.swift
//  Construct Messenger
//
//  Receive-path sender resolution: resolveSender, envelope writer,
//  identity pinning from the certificate.
//
//  Moved verbatim out of StealthSenderService.swift (TODO 184); behaviour unchanged.
//

import CoreData
import Foundation
import SwiftProtobuf

extension StealthSenderService {

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

    /// Whether a sealed inner names no recipient device. Such a copy is written to every device
    /// of the account (the server treats unnamed as "for all"), so on an account with more than
    /// one device a copy that does not open here is most likely a sibling's. Android senders
    /// omitted the field until construct-android `04d666f` (vault TODO 161). A parse failure is
    /// not "unnamed": that is corruption, and the normal path reports it.
    nonisolated static func namesNoRecipientDevice(sealedInnerBytes: Data) -> Bool {
        guard let inner = try? Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInnerBytes) else { return false }
        return inner.recipientDevice.isEmpty
    }

    /// What an unseal failure does with the message. One redelivery normally — a box that fails
    /// right after an identity-key rotation deserves a second chance — but an unnamed copy on a
    /// multi-device account is decided already: it was sealed to a sibling, and redelivering it
    /// opens nothing, costs an unseal and, on 2026-10-16, a push per redelivery. Dropped at once.
    enum UnsealFailureDisposition: Equatable { case deferOnce, drop }

    nonisolated static func unsealFailureDisposition(
        namesNoRecipientDevice: Bool,
        ownDeviceCount: Int,
        alreadyDeferred: Bool
    ) -> UnsealFailureDisposition {
        if alreadyDeferred { return .drop }
        if namesNoRecipientDevice && ownDeviceCount > 1 { return .drop }
        return .deferOnce
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
}
