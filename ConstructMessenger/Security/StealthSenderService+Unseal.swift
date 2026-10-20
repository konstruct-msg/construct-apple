//
//  StealthSenderService+Unseal.swift
//  Construct Messenger
//
//  Seal/unseal of the sender certificate and verify/attest (trust label).
//
//  Moved verbatim out of StealthSenderService.swift (TODO 184); behaviour unchanged.
//

import CoreData
import Foundation
import SwiftProtobuf

extension StealthSenderService {

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

    /// The signature half of the label: what the core says, expiry aside.
    func attestSignature(_ cert: Shared_Proto_Core_V1_SenderCertificate) -> SenderTrust {
        switch coreVerdict(cert) {
        case .vouched, .expired: return .vouched(.signature)
        case .noKey: return .unvouched(.noKey)
        case .badSignature: return .unvouched(.badSignature)
        }
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
}
