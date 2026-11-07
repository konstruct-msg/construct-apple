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

import CoreData
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

    // MARK: - todo/268: a device seen is not a device judged

    private final class Alarms: @unchecked Sendable {
        var raised = 0
        var contactExists = true
    }

    private final class FailingKeyValue: KeyValueStore, @unchecked Sendable {
        struct Unreadable: Error {}
        func put(_ key: String, _ value: Data) throws {}
        func get(_ key: String) throws -> Data? { throw Unreadable() }
        func remove(_ key: String) throws {}
        func entries(withPrefix prefix: String) throws -> [(key: String, value: Data)] { throw Unreadable() }
    }

    private final class UnwritableKeyValue: KeyValueStore, @unchecked Sendable {
        struct Unwritable: Error {}
        func put(_ key: String, _ value: Data) throws { throw Unwritable() }
        func get(_ key: String) throws -> Data? { nil }
        func remove(_ key: String) throws {}
        func entries(withPrefix prefix: String) throws -> [(key: String, value: Data)] { [] }
    }

    /// The production order, on the real core: read what is trusted, record, judge, mark.
    private func answer(
        _ bundles: [DeviceBundleData], of peer: String, me: Device, alarms: Alarms, coreUp: Bool = true
    ) async {
        let core = me.core
        await PeerDeviceVetting.recordAnswer(
            ofPeer: peer,
            bundles: bundles,
            activeSet: bundles.map(\.deviceId),
            isFullAnswer: true,
            judge: { coreUp ? core.judgePeerDevices(trustedDeviceIds: $0, offered: $1) : nil },
            raiseAlarm: { _ in
                alarms.raised += 1
                return alarms.contactExists
            }
        )
    }

    private func pin(_ d: Device, of peer: String) {
        SessionAddressing.recordDevices([(deviceId: d.id, identityKey: d.entry.bundle.identityPublic)], ofPeer: peer)
    }

    private func bare(_ d: Device) -> DeviceBundleData {
        DeviceBundleData(deviceId: d.id, bundle: d.entry.bundle, platform: .unspecified, hybridIdentityKey: Data())
    }

    private func makeContact(_ id: String, in container: NSPersistentContainer, pinning key: Data? = nil) throws {
        let user = User(context: container.viewContext)
        user.id = id
        user.username = ""
        user.displayName = "Bob"
        user.isContact = true
        user.isBlocked = false
        user.isSharingWithMe = false
        user.amISharingWith = false
        user.addedAt = Date()
        user.knownIdentityKey = key
        try container.viewContext.save()
    }

    private func withPeerStore(_ body: (String) async throws -> Void) async throws {
        let suite = "PeerDeviceJudgement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        LocalRepositories.usePeerDevicesForTesting(CoreDataPeerDeviceStore(container: PersistenceController(inMemory: true).container))
        LocalRepositories.useKeyValueForTesting(DefaultsKeyValueStore(defaults: defaults))
        defer {
            LocalRepositories.usePeerDevicesForTesting(nil)
            LocalRepositories.useKeyValueForTesting(nil)
            defaults.removePersistentDomain(forName: suite)
        }
        try await body("e7a4e3d2-0000-4000-8000-0000000000aa")
    }

    /// The control: first seen on a full answer with its keys, the alarm has always worked. It
    /// raises once: a device the user was warned about and kept is not announced on every fetch.
    func testADeviceFirstSeenOnAFullAnswerRaisesTheAlarmOnce() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 0, "a first meeting")
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1, "warned once")
        }
    }

    /// The stand of 2026-11-06: an answer with no hybrid key pins the device and judges nothing,
    /// and the answer with the key then read it as known.
    func testADeviceFirstServedWithoutItsHybridKeyRaisesTheAlarmWhenItsKeyArrives() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            await answer([phone.entry, bare(rogue)], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 0, "it can receive nothing yet")
            XCTAssertEqual(PeerDeviceJudgement.unjudged(ofPeer: peer), [rogue.id])
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
        }
    }

    /// `getPreKeyBundle` pins whichever device the server answers for; opening a session from a
    /// first message pins the one its certificate names, and the server signs that certificate.
    /// Both come through `recordDevices`, which judges nothing.
    func testADeviceFirstSeenWithoutAFullAnswerRaisesTheAlarmOnTheNextOne() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            pin(rogue, of: peer)
            XCTAssertEqual(SessionAddressing.deviceIds(ofPeer: peer).sorted(), [phone.id, rogue.id].sorted(), "delivery still sees it")
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
        }
    }

    /// A narrowed answer pins what it names and judges nothing: it may leave out the signer.
    func testADeviceFirstSeenOnANarrowedAnswerRaisesTheAlarmOnTheNextFullOne() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            let core = me.core
            await PeerDeviceVetting.recordAnswer(
                ofPeer: peer, bundles: [rogue.entry], activeSet: [phone.id, rogue.id], isFullAnswer: false,
                judge: { core.judgePeerDevices(trustedDeviceIds: $0, offered: $1) },
                raiseAlarm: { _ in alarms.raised += 1; return true }
            )
            XCTAssertEqual(alarms.raised, 0)
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
        }
    }

    func testADeviceAnsweredWhileTheCoreWasDownRaisesTheAlarmOnceItIsUp() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms, coreUp: false)
            XCTAssertEqual(alarms.raised, 0)
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
        }
    }

    /// `KeyChangeUX.raise` answers false when the contact has no row yet: the alarm is still owed.
    func testAnAlarmNobodyCouldRaiseIsRaisedAgain() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            alarms.contactExists = false
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
            alarms.contactExists = true
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 2)
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 2)
        }
    }

    /// Without the invite's mark the account would read as a first meeting, and everything offered
    /// with it, the server's device included, would be accepted.
    func testAnInvitesDeviceIsWhatTheOthersAreJudgedAgainst() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let container = PersistenceController(inMemory: true).container
            LocalRepositories.useContactsForTesting(container)
            defer { LocalRepositories.useContactsForTesting(nil) }
            try makeContact(peer, in: container)
            ContactLinkService.shared.pinKnownIdentityKey(contactId: peer, identityKey: phone.entry.bundle.identityPublic)
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
            let alarms = Alarms()
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
        }
    }

    /// A read that fails must not read as "nothing trusted": the core would call it a first meeting
    /// and accept everything offered.
    func testAFailedReadJudgesNothing() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            let working = LocalRepositories.keyValue
            LocalRepositories.useKeyValueForTesting(FailingKeyValue())
            XCTAssertNil(PeerDeviceJudgement.trusted(ofPeer: peer))
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            LocalRepositories.useKeyValueForTesting(working)
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id], "the rogue was not accepted meanwhile")
            await answer([phone.entry, rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
        }
    }

    /// The rows from before judging count as judged, once. A row added after the seed does not.
    func testTheSeedMarksOnlyTheRowsThatWereThere() async throws {
        let (phone, later) = (try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let store = LocalRepositories.peerDevices
            _ = try store.record([PeerDeviceRecord(deviceId: phone.id, accountId: peer, identityKey: phone.entry.bundle.identityPublic, firstSeenAt: Date())])
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
            _ = try store.record([PeerDeviceRecord(deviceId: later.id, accountId: peer, identityKey: later.entry.bundle.identityPublic, firstSeenAt: Date())])
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
            XCTAssertEqual(PeerDeviceJudgement.unjudged(ofPeer: peer), [later.id])
        }
    }

    /// The first write after the update must not be taken for a row from before it. Without the
    /// seed in `recordDevices`, a device pinned first would be marked by the seed the read runs.
    func testAPinBeforeAnyReadIsNotTakenForAnOldRow() async throws {
        let rogue = try makeDevice()
        try await withPeerStore { peer in
            pin(rogue, of: peer)
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [])
            XCTAssertEqual(PeerDeviceJudgement.unjudged(ofPeer: peer), [rogue.id])
        }
    }

    /// A contact with no rows keeps the device its pinned key derives to, as before this existed.
    func testAnAccountWithNoRowsKeepsItsPinnedDevice() async throws {
        let phone = try makeDevice()
        try await withPeerStore { peer in
            let container = PersistenceController(inMemory: true).container
            LocalRepositories.useContactsForTesting(container)
            defer { LocalRepositories.useContactsForTesting(nil) }
            try makeContact(peer, in: container, pinning: phone.entry.bundle.identityPublic)
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
            XCTAssertEqual(PeerDeviceJudgement.unjudged(ofPeer: peer), [])
        }
    }

    /// Every judged device retired, and what is left has no verdict: this must not read as a first
    /// meeting, or a server passes any device by showing it once without its keys. The same answer
    /// is what a real recovery can look like, between the new device's bundle and its hybrid key.
    func testADeviceLeftAfterEveryJudgedOneRetiredIsNoFirstMeeting() async throws {
        let (phone, rogue, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            await answer([bare(rogue)], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(PeerDeviceJudgement.unjudged(ofPeer: peer), [rogue.id])
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
            await answer([rogue.entry], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(alarms.raised, 1)
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [rogue.id], "A verdict was given, so the device that left stops counting")
        }
    }

    /// A second unjudged device passing through must not erase that the account had a verdict.
    func testAnUnjudgedDeviceLeavingKeepsTheJudgedOneThatLeft() async throws {
        let (phone, first, second, me) = (try makeDevice(), try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            await answer([bare(first)], of: peer, me: me, alarms: alarms)
            await answer([bare(second)], of: peer, me: me, alarms: alarms)
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [phone.id])
        }
    }

    /// A device that never had a verdict leaves nothing behind: the account is still at its first meeting.
    func testADeviceRetiredWithoutAVerdictLeavesNothingBehind() async throws {
        let (first, second) = (try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            pin(first, of: peer)
            SessionAddressing.reconcileDevices(
                [(deviceId: second.id, identityKey: second.entry.bundle.identityPublic)],
                activeSet: [second.id],
                ofPeer: peer
            )
            XCTAssertEqual(PeerDeviceJudgement.trusted(ofPeer: peer), [])
        }
    }

    /// A seed that failed left every old row unmarked, which reads as nothing trusted.
    func testAFailedSeedJudgesNothing() async throws {
        let phone = try makeDevice()
        try await withPeerStore { peer in
            _ = try LocalRepositories.peerDevices.record([
                PeerDeviceRecord(deviceId: phone.id, accountId: peer, identityKey: phone.entry.bundle.identityPublic, firstSeenAt: Date())
            ])
            LocalRepositories.useKeyValueForTesting(UnwritableKeyValue())
            XCTAssertNil(PeerDeviceJudgement.trusted(ofPeer: peer))
        }
    }

    /// A retired device's mark goes with it: seen again, it is judged again.
    func testARetiredDeviceIsJudgedAgainIfItComesBack() async throws {
        let (phone, other, me) = (try makeDevice(), try makeDevice(), try makeDevice())
        try await withPeerStore { peer in
            let alarms = Alarms()
            await answer([phone.entry, other.entry], of: peer, me: me, alarms: alarms)
            await answer([phone.entry], of: peer, me: me, alarms: alarms)
            pin(other, of: peer)
            XCTAssertEqual(PeerDeviceJudgement.unjudged(ofPeer: peer), [other.id])
        }
    }

    func testKeyChangedAndInvalidSettleNothing() {
        let device = { (id: String) in OfferedPeerDevice(
            deviceId: id,
            keys: DeviceCertKeys(identityPublic: Data(), verifyingKey: Data(), hybridPublic: Data(), hybridBinding: Data()),
            certificate: nil
        ) }
        let offered = ["a", "b", "c", "d", "e", "f"].map(device)
        let verdicts: [PeerDeviceVerdict] = [.pinned, .firstOfAccount, .vouched(by: "a"), .unvouched, .keyChanged, .invalid]
        XCTAssertEqual(PeerDeviceVetting.judged(offered: offered, verdicts: verdicts, alarmNotRaised: []), ["a", "b", "c", "d"])
        XCTAssertEqual(PeerDeviceVetting.judged(offered: offered, verdicts: verdicts, alarmNotRaised: ["d"]), ["a", "b", "c"])
    }

    /// The marks say who a contact's devices are, so they leave with the account.
    func testAWipeRemovesTheMarks() throws {
        let suite = "PeerDeviceJudgementWipe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1]), forKey: PeerDeviceJudgement.keyFamily + "v1.abc")
        defaults.set(Data([1]), forKey: PeerDeviceJudgement.seededKey)
        defaults.set(Data([1]), forKey: PeerDeviceJudgement.formerKey("abc"))
        AccountWipeKeys.wipe(defaults)
        XCTAssertNil(defaults.data(forKey: PeerDeviceJudgement.formerKey("abc")))
        XCTAssertNil(defaults.data(forKey: PeerDeviceJudgement.keyFamily + "v1.abc"))
        XCTAssertNil(defaults.data(forKey: PeerDeviceJudgement.seededKey))
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

    /// A device name with query delimiters, `%` or Cyrillic in it comes out of the QR as it went in,
    /// and does not take the fields after it with it.
    func testADeviceNameSurvivesTheJoinRequestQR() {
        let fp = String(repeating: "ab", count: 32)
        for name in ["Mac & iPad", "a=b+c", "100% Mac", "Мой Mac"] {
            let url = "konstruct://link-to-me?id=d&pubkey=p&fp=\(fp)&name=\(DeviceLinkViewModel.queryValue(name))&platform=desktop"
            XCTAssertEqual(DeviceLinkViewModel.joinRequestName(from: url), name)
            XCTAssertEqual(DeviceLinkViewModel.extractFp(from: url), Data(repeating: 0xAB, count: 32))
            XCTAssertEqual(URLComponents(string: url)?.queryItems?.first { $0.name == "platform" }?.value, "desktop")
        }
        // A QR from before this change (`.urlQueryAllowed`) still reads.
        XCTAssertEqual(DeviceLinkViewModel.joinRequestName(from: "konstruct://link-to-me?id=d&name=My%20Mac"), "My Mac")
    }
}
