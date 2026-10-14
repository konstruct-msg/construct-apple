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

import CryptoKit
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

    /// The responder side from what the initiator's `encryptToWire` returned — the handshake header
    /// included — opened with `sender`'s certificate as `TestCertificateServer.shared` issues it.
    /// Nothing else names the key a first message opens with
    /// (`decisions/first-message-opens-without-the-server.md`).
    func pqxdhTestReceive(from sender: OrchestratorCore, first: Data) throws -> SessionInitResult {
        try pqxdhTestReceive(from: sender, wirePayload: first)
    }

    /// The same, from a wire payload as received.
    func pqxdhTestReceive(from sender: OrchestratorCore, wirePayload: Data) throws -> SessionInitResult {
        TestCertificateServer.shared.trust(in: self)
        return try initReceivingSessionFromWirePayload(
            senderCertificate: try TestCertificateServer.shared.certificate(for: sender),
            wirePayload: wirePayload
        )
    }
}

/// A fresh device, named — as every real device is — by the id its identity key derives to. A
/// session opened from a sender certificate is filed under that id, so a test peer called
/// `"alice-…"` could never be found again by that name.
func makeTestDevice() throws -> (core: OrchestratorCore, deviceId: String) {
    let bootstrap = try createCryptoCore()
    let deviceId = deriveDeviceId(
        identityPublicKey: try bootstrap.getRegistrationBundleFields().identityPublic
    )
    let core = try createOrchestratorCoreFromKeys(
        keysData: try bootstrap.exportPrivateKeys(),
        myUserId: deviceId
    )
    // Every device that publishes a bundle holds one; its KEM identity key derives from it, and an
    // initiator without one cannot open (`decisions/responder-authenticates-initiator-by-kem.md`).
    _ = try core.ensureHybridSignatureKey()
    return (core, deviceId)
}

/// The Ed25519 certificate payload `identity-service` signs (variant 0: direct concatenation,
/// big-endian times). Test-only since 2026-10-03: the app no longer checks certificates itself —
/// the core does — so only tests that sign one need the bytes.
func legacyCertPayload(userID: String, domain: String, ik: Data, deviceID: String, issued: Int64, expires: Int64) -> Data {
    var p = Data()
    p.append(contentsOf: userID.utf8)
    p.append(contentsOf: domain.utf8)
    p.append(ik)
    p.append(contentsOf: deviceID.utf8)
    withUnsafeBytes(of: issued.bigEndian) { p.append(contentsOf: $0) }
    withUnsafeBytes(of: expires.bigEndian) { p.append(contentsOf: $0) }
    return p
}

/// Signs sender certificates the way `identity-service` does (Ed25519 over `legacyCertPayload`),
/// for tests that open sessions from them.
final class TestCertificateServer {
    static let shared = TestCertificateServer()

    let key = Curve25519.Signing.PrivateKey()

    var verifyingKey: Data { key.publicKey.rawRepresentation }

    /// Make `core` accept certificates from this server.
    func trust(in core: OrchestratorCore) {
        core.setTrustedServerKeys(keys: [verifyingKey])
    }

    /// `device`'s certificate, issued now for a day.
    func certificate(for device: OrchestratorCore, account: String = "test-account") throws -> SenderCertificate {
        let identityKey = Data(try device.getRegistrationBundleFields().identityPublic)
        return try certificate(identityKey: identityKey, account: account)
    }

    func certificate(
        identityKey: Data,
        account: String = "test-account",
        deviceId: String? = nil,
        issuedAt: Date = Date()
    ) throws -> SenderCertificate {
        let device = deviceId ?? deriveDeviceId(identityPublicKey: identityKey)
        let issued = Int64(issuedAt.timeIntervalSince1970)
        let expires = issued + 86_400
        let payload = legacyCertPayload(
            userID: account, domain: "test.example", ik: identityKey,
            deviceID: device, issued: issued, expires: expires
        )
        return SenderCertificate(
            userId: account,
            domain: "test.example",
            identityKey: identityKey,
            deviceId: device,
            issuedAt: issued,
            expiresAt: expires,
            signature: try key.signature(for: payload),
            serverKid: Data(),
            serverSignatureHybrid: Data()
        )
    }
}

/// A wire payload with arbitrary header fields and a noise body, laid out by hand per
/// `construct-core/src/wire_payload.rs` — for routing fixtures that must name a message number or
/// a handshake the core never produced. Not a way to send: this app does not pack payloads, and a
/// message built here never decrypts.
func handBuiltWirePayload(
    messageNumber: UInt32,
    suiteId: UInt16,
    kemCiphertext: [UInt8]? = nil,
    pqMessageEpoch: UInt32 = 0,
    sealedBox: [UInt8] = [UInt8](repeating: 2, count: 48)
) -> Data {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    let kem = kemCiphertext ?? []
    var out: [UInt8] = le(messageNumber) + [UInt8](repeating: 1, count: 32) + le(UInt32(0)) + le(UInt32(0))
    out += le(UInt16(kem.count)) + le(UInt32(0))
    out += le(kem.isEmpty ? suiteId : suiteId | 0x0100)   // PQXDH_V2_FLAG follows the ciphertext
    out += kem
    // PQ-ratchet section (suite 4): epoch, key index 0 (one LEB128 byte), no field.
    if suiteId == 4 { out += le(pqMessageEpoch) + [0, 0] }
    return Data(out + sealedBox)
}

private struct MissingKyberSPK: Error {}

private func XCTUnwrapCurrent(_ value: KyberPrekeyUpload?) throws -> KyberPrekeyUpload {
    guard let value else { throw MissingKyberSPK() }
    return value
}
