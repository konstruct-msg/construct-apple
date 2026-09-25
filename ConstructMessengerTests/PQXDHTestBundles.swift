//
//  PQXDHTestBundles.swift
//  ConstructMessengerTests
//
//  Two cores that open a session with each other have to look, to each other, the way a server
//  shows them after PQXDH v2: classic prekeys plus a Kyber SPK signed with its `created_at`, a
//  hybrid identity and the Ed25519 signature binding it. A bundle without those is refused by the
//  initiator (`PQ_REQUIRED`), so every test that builds sessions between two cores goes through
//  here rather than assembling a `BinaryKeyBundle` field by field.
//
//  Everything is produced by the core under test; nothing here signs or encapsulates by itself.
//

import Foundation
@testable import Construct_Messenger

extension OrchestratorCore {

    /// This device's bundle as the key service would serve it: registration fields, the current
    /// Kyber SPK (committed now if there is none), optionally one Kyber one-time key, and the
    /// hybrid identity with its binding. `suiteId` is the classic crypto suite servers advertise.
    func pqxdhTestBundle(withOneTimeKey: Bool = false) throws -> BinaryKeyBundle {
        let fields = try getRegistrationBundleFields()
        let hybrid = try ensureHybridSignatureKey()
        let binding = try signBundleData(bundleDataJson: buildHybridIdentityBindMessage(hybridPublicKey: hybrid))
        let spk: KyberPrekeyUpload
        if let current = try currentKyberSpkUpload() {
            spk = current
        } else {
            _ = try beginKyberSpkRotation()
            _ = commitKyberSpkRotation()
            spk = try XCTUnwrapCurrent(currentKyberSpkUpload())
        }
        let otpk = withOneTimeKey ? try generateKyberOneTimePrekeys(count: 1).first : nil
        let now = UInt64(Date().timeIntervalSince1970)
        return BinaryKeyBundle(
            identityPublic: fields.identityPublic,
            signedPrekeyPublic: fields.signedPrekeyPublic,
            signature: fields.signature,
            verifyingKey: fields.verifyingKey,
            suiteId: fields.suiteId,
            oneTimePrekeyPublic: nil,
            oneTimePrekeyId: nil,
            spkUploadedAt: now,
            spkRotationEpoch: 1,
            kyberSpkUploadedAt: now,
            kyberSpkRotationEpoch: 1,
            kyberPreKeyPublic: spk.publicKey,
            kyberPreKeyId: spk.keyId,
            kyberPreKeyCreatedAt: spk.createdAt,
            kyberPreKeySignature: spk.signature,
            kyberPreKeyHybridSignature: spk.hybridSignature,
            kyberOneTimePrekeyPublic: otpk?.publicKey,
            kyberOneTimePrekeyId: otpk?.keyId,
            kyberOneTimePrekeyCreatedAt: otpk?.createdAt,
            kyberOneTimePrekeySignature: otpk?.signature,
            kyberOneTimePrekeyHybridSignature: otpk?.hybridSignature,
            hybridIdentityKey: hybrid,
            hybridIdentitySignature: binding
        )
    }

    /// The responder side from what the initiator's `encryptMessage` returned, packed the way
    /// the wire carries it — the handshake header included.
    func pqxdhTestReceive(
        from contactId: String,
        senderBundle: BinaryKeyBundle,
        first: EncryptedMessageComponents
    ) throws -> SessionInitResult {
        try initReceivingSessionFromWirePayload(
            contactId: contactId,
            recipientBundle: senderBundle,
            wirePayload: try first.pqxdhTestWirePayload()
        )
    }
}

extension EncryptedMessageComponents {
    /// The envelope's `encrypted_payload` for these components, packed by the core.
    func pqxdhTestWirePayload(previousChainLength: UInt32 = 0) throws -> [UInt8] {
        try wirePayloadPack(payload: WirePayload(
            dhPublicKey: ephemeralPublicKey,
            messageNumber: messageNumber,
            oneTimePrekeyId: oneTimePrekeyId,
            kyberOtpkId: kyberPrekeyId,
            previousChainLength: previousChainLength,
            suiteId: suiteId,
            kemCiphertext: kemCiphertext.isEmpty ? nil : kemCiphertext,
            sealedBox: content,
            pqMessageEpoch: pqMessageEpoch,
            pqRatchetField: pqRatchetField
        ))
    }
}

extension MessageCryptoService.EncryptedMessageComponents {
    /// The app's components exactly as the core returned them. Tests used to fill these by hand
    /// with `suiteId: 1` and empty PQ fields, which stopped being true when suite 3 became the
    /// only suite — and a hand copy is how fields get dropped.
    init(from core: EncryptedMessageComponents) {
        self.init(
            ephemeralPublicKey: Data(core.ephemeralPublicKey),
            messageNumber: core.messageNumber,
            content: Data(core.content),
            suiteId: core.suiteId,
            oneTimePreKeyId: core.oneTimePrekeyId,
            storageKey: Data(core.storageKey),
            pqMessageEpoch: core.pqMessageEpoch,
            pqRatchetField: Data(core.pqRatchetField),
            kemCiphertext: Data(core.kemCiphertext),
            kyberPrekeyId: core.kyberPrekeyId
        )
    }
}

private struct MissingKyberSPK: Error {}

private func XCTUnwrapCurrent(_ value: KyberPrekeyUpload?) throws -> KyberPrekeyUpload {
    guard let value else { throw MissingKyberSPK() }
    return value
}
