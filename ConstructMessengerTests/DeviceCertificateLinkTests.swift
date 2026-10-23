//
//  DeviceCertificateLinkTests.swift
//  ConstructMessengerTests
//
//  The link side of device certificates (decisions/devices-of-an-account-sign-each-other.md):
//  what this app reads out of the QR and out of the directory, handed to the real core.
//  The signing, the evidence check and the verdicts are the core's and tested there; what can go
//  wrong here is the mapping — a field taken from the wrong place signs nothing the peer can
//  verify, silently.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class DeviceCertificateLinkTests: XCTestCase {

    /// A device with real keys, and its bundle as the directory would serve it.
    private struct Device {
        let core: OrchestratorCore
        let id: String
        let entry: DeviceBundleData
    }

    private func makeDevice() throws -> Device {
        let keys = try createCryptoCore()
        let fields = try keys.getRegistrationBundleFields()
        let id = deriveDeviceId(identityPublicKey: fields.identityPublic)
        let core = try createOrchestratorCoreFromKeys(keysData: try keys.exportPrivateKeys(), myUserId: id)
        let hybrid = try core.ensureHybridSignatureKey()
        let binding = try core.signWithDeviceKey(message: core.buildHybridIdentityBindMessage(hybridPublicKey: hybrid))
        var bundle = PublicKeyBundleData(
            userId: "e7a4e3d2-0000-4000-8000-000000000001",
            username: "",
            identityPublic: fields.identityPublic,
            signedPrekeyPublic: fields.signedPrekeyPublic,
            signature: fields.signature,
            verifyingKey: fields.verifyingKey,
            suiteId: fields.suiteId,
            spkUploadedAt: 0,
            spkRotationEpoch: 0,
            kyberSpkUploadedAt: 0,
            kyberSpkRotationEpoch: 0
        )
        bundle.hybridIdentityKey = hybrid
        bundle.hybridIdentitySignature = binding
        return Device(
            core: core,
            id: id,
            entry: DeviceBundleData(deviceId: id, bundle: bundle, platform: .unspecified, hybridIdentityKey: hybrid)
        )
    }

    private func offered(_ d: Device, certificate: Data?) throws -> OfferedPeerDevice {
        OfferedPeerDevice(
            deviceId: d.id,
            keys: try XCTUnwrap(DeviceCertificateIssuer.subjectKeys(from: d.entry)),
            certificate: certificate
        )
    }

    /// The keys read from the directory are the ones the QR fingerprint names: the core signs
    /// them, and a peer that trusts the signer reads the new device as vouched for.
    func testFlowBCertificateFromDirectoryKeysIsVouchedByAPeer() throws {
        let (old, new) = (try makeDevice(), try makeDevice())
        let subject = try XCTUnwrap(DeviceCertificateIssuer.subjectKeys(from: new.entry))
        let fp = historyQrFingerprint(identityPublic: new.entry.bundle.identityPublic, hybridPublic: new.entry.hybridIdentityKey)

        let certificate = try old.core.issueDeviceCertificate(
            subject: subject,
            evidence: DeviceCertificateIssuer.Evidence.qrFingerprint(fp).core
        )

        let peer = try makeDevice()
        let verdicts = peer.core.judgePeerDevices(
            trustedDeviceIds: [old.id],
            offered: [try offered(old, certificate: nil), try offered(new, certificate: certificate)]
        )
        XCTAssertEqual(verdicts, [.pinned, .vouched(by: old.id)])
    }

    /// Flow A: the proof the new device sends under the QR secret is accepted by the old
    /// device for the keys the directory serves, and for no others.
    func testFlowAProofCoversTheDirectoryKeysOnly() throws {
        let (old, new, other) = (try makeDevice(), try makeDevice(), try makeDevice())
        let secret = newDeviceLinkSecret()
        let proof = try new.core.deviceLinkKeyProof(secret: secret)
        let evidence = DeviceCertificateIssuer.Evidence.qrSecret(secret: secret, proof: proof).core

        XCTAssertNoThrow(try old.core.issueDeviceCertificate(
            subject: try XCTUnwrap(DeviceCertificateIssuer.subjectKeys(from: new.entry)),
            evidence: evidence
        ))
        XCTAssertThrowsError(try old.core.issueDeviceCertificate(
            subject: try XCTUnwrap(DeviceCertificateIssuer.subjectKeys(from: other.entry)),
            evidence: evidence
        )) { error in
            guard case DeviceCertError.EvidenceMismatch = error else {
                return XCTFail("expected EvidenceMismatch, got \(error)")
            }
        }
    }

    /// Until the new device has published its hybrid key and binding there is nothing to sign —
    /// the issuer waits rather than asking the core to sign a partial bundle.
    func testNoSubjectKeysBeforeTheHybridKeyIsPublished() throws {
        let d = try makeDevice()
        var withoutBinding = d.entry
        var bundle = d.entry.bundle
        bundle.hybridIdentitySignature = nil
        withoutBinding = DeviceBundleData(deviceId: d.id, bundle: bundle, platform: .unspecified, hybridIdentityKey: d.entry.hybridIdentityKey)
        XCTAssertNil(DeviceCertificateIssuer.subjectKeys(from: withoutBinding))

        let withoutKey = DeviceBundleData(deviceId: d.id, bundle: d.entry.bundle, platform: .unspecified, hybridIdentityKey: Data())
        XCTAssertNil(DeviceCertificateIssuer.subjectKeys(from: withoutKey))
    }

    // MARK: - Receiving side: which devices raise the alarm

    private func vouch(_ signer: Device, for subject: Device) throws -> Data {
        let fp = historyQrFingerprint(identityPublic: subject.entry.bundle.identityPublic, hybridPublic: subject.entry.hybridIdentityKey)
        return try signer.core.issueDeviceCertificate(
            subject: try XCTUnwrap(DeviceCertificateIssuer.subjectKeys(from: subject.entry)),
            evidence: .qrFingerprint(fingerprint: fp)
        )
    }

    private func withCertificate(_ d: Device, _ certificate: Data?) -> DeviceBundleData {
        var entry = d.entry
        entry.deviceCertificate = certificate
        return entry
    }

    /// A contact with a trusted phone links a Mac (vouched) and the server adds a device of its
    /// own (not vouched): the alarm names the server's device and only it.
    func testOnlyTheDeviceNobodyVouchedForRaisesTheAlarm() throws {
        let (phone, mac, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice(), try makeDevice())
        let bundles = [
            withCertificate(phone, nil),
            withCertificate(mac, try vouch(phone, for: mac)),
            withCertificate(rogue, nil),
        ]
        let offered = PeerDeviceVetting.offered(bundles)
        let verdicts = me.core.judgePeerDevices(trustedDeviceIds: [phone.id], offered: offered)
        XCTAssertEqual(PeerDeviceVetting.unvouched(trusted: [phone.id], offered: offered, verdicts: verdicts), [rogue.id])
    }

    /// The first time an account is seen there is nothing to compare against: no alarm.
    func testAnAccountSeenForTheFirstTimeRaisesNothing() throws {
        let (phone, other, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        let offered = PeerDeviceVetting.offered([withCertificate(phone, nil), withCertificate(other, nil)])
        let verdicts = me.core.judgePeerDevices(trustedDeviceIds: [], offered: offered)
        XCTAssertEqual(PeerDeviceVetting.unvouched(trusted: [], offered: offered, verdicts: verdicts), [])
    }

    /// A device already pinned here is not alarmed about again, even if nobody vouched for it.
    func testADeviceAlreadyTrustedIsNotAlarmedAgain() {
        let offered = [OfferedPeerDevice(
            deviceId: "aa", keys: DeviceCertKeys(identityPublic: Data(), verifyingKey: Data(), hybridPublic: Data(), hybridBinding: Data()),
            certificate: nil
        )]
        XCTAssertEqual(PeerDeviceVetting.unvouched(trusted: ["aa"], offered: offered, verdicts: [.unvouched]), [])
        XCTAssertEqual(PeerDeviceVetting.unvouched(trusted: [], offered: offered, verdicts: [.unvouched]), ["aa"])
    }

    /// A bundle without the hybrid key cannot open a session with anyone, so it is not judged.
    func testABundleWithoutTheHybridKeyIsNotJudged() throws {
        let d = try makeDevice()
        let bare = DeviceBundleData(deviceId: d.id, bundle: d.entry.bundle, platform: .unspecified, hybridIdentityKey: Data())
        XCTAssertTrue(PeerDeviceVetting.offered([bare]).isEmpty)
        XCTAssertEqual(PeerDeviceVetting.offered([d.entry]).map(\.deviceId), [d.id])
    }

    /// The certificate the directory served reaches the core with the bundle.
    func testTheServedCertificateIsHandedToTheCore() throws {
        let d = try makeDevice()
        XCTAssertEqual(PeerDeviceVetting.offered([withCertificate(d, Data([1, 2]))]).first?.certificate, Data([1, 2]))
    }

    func testLinkSecretAndFingerprintAreReadFromTheQR() {
        let s = String(repeating: "07", count: 32)
        let fp = String(repeating: "ab", count: 32)
        let flowA = "konstruct://link?token=tok&fp=\(fp)&s=\(s)"
        XCTAssertEqual(DeviceLinkViewModel.extractHex32("s", from: flowA), Data(repeating: 0x07, count: 32))
        XCTAssertNil(DeviceLinkViewModel.extractHex32("s", from: "konstruct://link?token=tok&fp=\(fp)"))
        XCTAssertNil(DeviceLinkViewModel.extractHex32("s", from: "konstruct://link?token=tok&s=07"))

        let flowB = "konstruct://link-to-me?id=d&pubkey=p&fp=\(fp)&name=Mac&platform=desktop"
        XCTAssertEqual(DeviceLinkViewModel.extractFp(from: flowB), Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(DeviceLinkViewModel.hex(Data([0x00, 0x0f, 0xff])), "000fff")
    }
}
