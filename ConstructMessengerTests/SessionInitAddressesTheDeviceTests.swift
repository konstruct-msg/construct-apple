//
//  SessionInitAddressesTheDeviceTests.swift
//  Construct Messenger
//
//  Both X3DH paths open a session under the device named by the bundle in hand. Everything they
//  then say about that session must name the same device.
//
//  Measured 2026-09-06, a two-device peer against a one-device peer: the RESPONDER walk opened on
//  attempt 2 of 2 — against the device that is *not* the pinned one — and the persist that
//  followed addressed the pinned one. `exportSession` found nothing there, logged
//  `Session export failed: SessionNotFound`, and wrote nothing; the next lookup asked the pinned
//  device again, got no session, treated the peer's next message as mid-ratchet, and sent
//  END_SESSION. Three of three inits that opened against a non-pinned device failed this way, and
//  none of the inits that opened against the pinned one did — the whole run's loop, from one word.
//
//  The suite id was already written under the device on the line above, which is what made the
//  split invisible: the two halves of one fact sat next to each other and disagreed.
//

import XCTest
@testable import Construct_Messenger

/// Enough of `OrchestratorCore` to drive one init. `init(noHandle:)` is the generated escape hatch
/// for exactly this — no Rust handle is touched, and every method the service calls is overridden.
private final class RecordingCore: OrchestratorCore, @unchecked Sendable {
    /// Kept alive for the life of the test process, and that is not tidiness — it is required.
    /// The generated `OrchestratorCore.deinit` frees its Rust handle unconditionally, so a fake
    /// built with `noHandle` traps the moment ARC releases it (`Crash: Construct Messenger at
    /// RecordingCore.deinit`, before any assertion runs). `deinit` cannot be overridden away in
    /// Swift — a subclass's runs first and the superclass's follows — so the only way not to free
    /// handle 0 is never to deallocate. Bounded by the process; these are three small objects.
    private static var kept: [RecordingCore] = []

    var sessionExistsFor: Set<String> = []
    /// Set to make `reopenSession` refuse, the way the core does for a bundle it cannot trust.
    var reopenRefusal: Error?
    private(set) var initReceivingContactIds: [String] = []
    private(set) var initSendingContactIds: [String] = []
    private(set) var reopenContactIds: [String] = []

    init() {
        super.init(noHandle: NoHandle())
        Self.kept.append(self)
    }

    /// Required by the generated superclass; a handle is never used here.
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func hasSession(contactId: String) -> Bool { sessionExistsFor.contains(contactId) }

    override func getSessionSuiteId(contactId: String) -> UInt16 { 3 }

    override func initReceivingSessionFromWirePayload(
        contactId: String,
        recipientBundle: BinaryKeyBundle,
        wirePayload: [UInt8]
    ) throws -> SessionInitResult {
        initReceivingContactIds.append(contactId)
        return SessionInitResult(
            sessionId: "session-\(contactId)",
            decryptedMessage: Array("hello".utf8),
            storageKey: [],
            kyberPrekeys: nil
        )
    }

    override func reopenSession(contactId: String, recipientBundle: BinaryKeyBundle) throws -> String {
        reopenContactIds.append(contactId)
        if let reopenRefusal { throw reopenRefusal }
        return "session-\(contactId)"
    }

    override func exportSession(contactId: String) throws -> [UInt8] {
        Array("held-\(contactId)".utf8)
    }

    override func initSession(contactId: String, recipientBundle: BinaryKeyBundle) throws -> String {
        initSendingContactIds.append(contactId)
        return "session-\(contactId)"
    }
}

final class SessionInitAddressesTheDeviceTests: XCTestCase {

    /// A peer account, and a bundle key that is deliberately **not** the one this account has
    /// pinned. That is the only configuration in which the bug shows: with a single-device peer,
    /// or with the pinned device answering first, account and device resolve to the same string
    /// and passing either one works.
    private let account = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
    private let bundleIdentityKey = Data((0..<32).map { UInt8($0 &+ 7) })

    /// The device the bundle names — the same derivation the seam uses, so this is the id the
    /// session is actually opened under.
    private var bundleDevice: String {
        SessionAddressing.cryptoIdentity(ofIdentityKey: bundleIdentityKey) ?? ""
    }

    private func bundle() -> (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String) {
        (
            identityPublic: bundleIdentityKey,
            signedPrekeyPublic: Data(repeating: 0x22, count: 32),
            signature: Data(repeating: 0x33, count: 64),
            verifyingKey: Data(repeating: 0x44, count: 32),
            suiteId: "1"
        )
    }

    /// The same device's bundle as the INITIATOR path takes it. The fake core never reads the
    /// Kyber fields, so they are left out.
    private func served() -> PublicKeyBundleData {
        let b = bundle()
        return PublicKeyBundleData(
            userId: account,
            username: "",
            identityPublic: b.identityPublic,
            signedPrekeyPublic: b.signedPrekeyPublic,
            signature: b.signature,
            verifyingKey: b.verifyingKey,
            suiteId: 1,
            spkUploadedAt: 0,
            spkRotationEpoch: 0,
            kyberSpkUploadedAt: 0,
            kyberSpkRotationEpoch: 0
        )
    }

    private func firstMessage() -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            from: account,
            to: "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167",
            ephemeralPublicKey: Data(repeating: 0x55, count: 32),
            messageNumber: 0,
            content: Data(repeating: 0x66, count: 283),
            suiteId: 1,
            timestamp: 1_788_698_000,
            oneTimePreKeyId: 1_000_710,
            kemCiphertext: Data(repeating: 0x77, count: 1568),
            contentType: 0,
            kyberOtpkId: 1_000_004,
            // The responder init reads the payload as received; the fake core never parses it.
            rawPayload: Data(repeating: 0x88, count: 64)
        )
    }

    override func setUp() {
        super.setUp()
        // The pin would otherwise be read from Core Data. Overriding it is what lets the test
        // state the premise out loud: the contact list names a *different* device.
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { _ in
            Data((0..<32).map { UInt8($0 &+ 200) })
        }
    }

    override func tearDown() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        super.tearDown()
    }

    func testRespondingInitPersistsUnderTheDeviceItOpened() throws {
        let core = RecordingCore()
        var saved: [String] = []

        _ = try CryptoSessionInitializationService().initReceivingSession(
            for: account,
            recipientBundle: bundle(),
            firstMessage: firstMessage(),
            core: core,
            archiveSession: { _, _ in },
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.initReceivingContactIds, [bundleDevice],
                       "premise: the session opens under the bundle's device")
        XCTAssertEqual(saved, [bundleDevice],
                       "the persist must name the device the session was opened under — given the "
                       + "account it resolves to the pinned device and exports a session that is not there")
    }

    func testSendingInitPersistsUnderTheDeviceItOpened() throws {
        let core = RecordingCore()
        var saved: [String] = []

        try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            archiveSession: { _, _ in },
            archiveReplacedSession: { _, _, _ in },
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.initSendingContactIds, [bundleDevice])
        XCTAssertEqual(saved, [bundleDevice],
                       "the INITIATOR path is the mirror image and had the same defect")
    }

    /// The archive is guarded on `hasSession(contactId:)` — an answer about one device. Handing
    /// the account to the archive that follows makes the question and the action address different
    /// peers' devices.
    func testArchiveBeforeReinitNamesTheDeviceThatWasAskedAbout() throws {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        var archived: [String] = []

        _ = try CryptoSessionInitializationService().initReceivingSession(
            for: account,
            recipientBundle: bundle(),
            firstMessage: firstMessage(),
            core: core,
            archiveSession: { peer, _ in archived.append(peer) },
            saveSession: { _ in }
        )

        XCTAssertEqual(archived, [bundleDevice],
                       "the archive must put away the session `hasSession` just found, not whichever "
                       + "device the contact list pins")
    }

    /// A session held with the device is replaced by the core's reopen — built first — and the
    /// replaced ratchet archived afterwards from the bytes exported before. Nothing is archived
    /// up front: that is what left a pair with no session when the init was then refused.
    func testSendingInitOverAHeldSessionReopensAndArchivesAfter() throws {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        var archivedFirst: [String] = []
        var archivedReplaced: [(String, Data)] = []
        var saved: [String] = []

        try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            archiveSession: { peer, _ in archivedFirst.append(peer) },
            archiveReplacedSession: { peer, bytes, _ in archivedReplaced.append((peer, bytes)) },
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.reopenContactIds, [bundleDevice])
        XCTAssertEqual(core.initSendingContactIds, [], "a held session goes through reopen, not init")
        XCTAssertEqual(archivedFirst, [], "nothing is torn down before the new session exists")
        XCTAssertEqual(archivedReplaced.map(\.0), [bundleDevice])
        XCTAssertEqual(archivedReplaced.first?.1, Data("held-\(bundleDevice)".utf8),
                       "the archive holds the session as it was before the reopen")
        XCTAssertEqual(saved, [bundleDevice])
    }

    /// The reopen refused (PQ_REQUIRED — a peer still on a build from before PQXDH v2): the held
    /// session stays, nothing is archived or saved, and the caller hears why.
    func testRefusedReopenKeepsTheHeldSessionAndSaysWhy() {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        core.reopenRefusal = CryptoError.SessionInitializationFailed(
            message: "PQ_REQUIRED: bundle has no hybrid identity key"
        )
        var archived: [String] = []
        var saved: [String] = []

        XCTAssertThrowsError(try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            archiveSession: { peer, _ in archived.append(peer) },
            archiveReplacedSession: { peer, _, _ in archived.append(peer) },
            saveSession: { saved.append($0) }
        )) { error in
            guard case SessionError.peerNotPostQuantum(let reason)? = error as? SessionError else {
                return XCTFail("expected peerNotPostQuantum, got \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("PQ_REQUIRED"))
        }
        XCTAssertEqual(archived, [])
        XCTAssertEqual(saved, [])
    }
}
