//
//  StealthSenderService+Send.swift
//  Construct Messenger
//
//  Send path: buildSealedInner and recipient identity key lookup.
//
//  Moved verbatim out of StealthSenderService.swift (TODO 184); behaviour unchanged.
//

import CoreData
import Foundation
import SwiftProtobuf

extension StealthSenderService {

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
            // So the server's verdict on this envelope finds the recipient (`noteVerdict`).
            IntakeCredentialService.shared.notePresented(deliveryTag: inner.deliveryTag, forRecipient: recipientUserId)
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
