//
//  StealthSenderService+Unseal.swift
//  Construct Messenger
//
//  Seal of the sender certificate, and the trust label layered over the core's verdict.
//
//  The open half moved into the core: `open_sealed` (TODO 140) unseals the certificate and
//  returns its `CertificateVerdict`. What stays here is the seal (send path) and the trust
//  label that layers the local KT anchor over that verdict.
//

import CoreData
import Foundation

extension StealthSenderService {

    // MARK: - Seal
    //
    // The box is the core's (`sealed_seal_sender_cert`). Until 2026-09-29 this file carried its
    // own CryptoKit copy of it, and opening needed our identity private key read from the
    // Keychain on every sealed message.

    /// Encrypts `certBytes` (serialized SenderCertificate proto) to the recipient's
    /// X25519 identity key.
    func sealSenderCert(_ certBytes: Data, recipientIdentityKey: Data) throws -> Data {
        try sealedSealSenderCert(certBytes: certBytes, recipientIdentityKey: recipientIdentityKey)
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

    /// The trust label for an opened certificate. `verdict` is the core's (`open_sealed`,
    /// `certificate_verdict`); this only layers the local KT anchor on top of it. Never gates
    /// delivery — only labels trust. Ladder, strongest-first (sealed-sender-resilience §2
    /// lever C):
    ///  1. Expiry: an expired cert is `.unvouched(.expired)` regardless of KT match — the
    ///     cert TTL bounds replay of an old sealed message (delivery still proceeds).
    ///  2. KT: cert identity key == our KT-`.verified` `knownIdentityKey` for the sender →
    ///     `.vouched(.kt)`, no bundle key involved at all. A `.keyChanged`/`.failed`/
    ///     `.unverified` status does NOT vouch even on a key match (that is exactly the
    ///     MITM-suspicion case KT exists to catch).
    ///  3. Signature (lever B): fall back to the core's signature verdict for a first contact.
    func attest(_ cert: SenderCertificate, verdict: CertificateVerdict) -> SenderTrust {
        if verdict == .expired { return .unvouched(.expired) }

        if let kt = ktVerifiedIdentity(for: cert.userId),
           kt.status == .verified,
           kt.key == cert.identityKey {
            return .vouched(.kt)
        }

        switch verdict {
        case .vouched, .expired: return .vouched(.signature)
        case .noKey: return .unvouched(.noKey)
        case .badSignature: return .unvouched(.badSignature)
        }
    }
}
