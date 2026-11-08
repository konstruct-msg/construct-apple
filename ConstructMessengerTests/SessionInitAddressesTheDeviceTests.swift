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

import Synchronization
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
    private static let kept = Mutex<[RecordingCore]>([])

    var sessionExistsFor: Set<String> = []
    /// Set to make `reopenSession` refuse, the way the core does for a bundle it cannot trust.
    var reopenRefusal: Error?
    private(set) var initReceivingContactIds: [String] = []
    private(set) var initSendingContactIds: [String] = []
    private(set) var reopenContactIds: [String] = []
    private(set) var reopenStaleContactIds: [String] = []
    private(set) var initStaleContactIds: [String] = []

    init() {
        super.init(noHandle: NoHandle())
        Self.kept.withLock { $0.append(self) }
    }

    /// Required by the generated superclass; a handle is never used here.
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func hasSession(contactId: String) -> Bool { sessionExistsFor.contains(contactId) }

    override func getSessionSuiteId(contactId: String) -> UInt16 { 3 }

    override func initReceivingSessionFromWirePayload(
        senderCertificate: SenderCertificate,
        wirePayload: Data
    ) throws -> SessionInitResult {
        // The core files the session under the device the certificate names and answers with it.
        initReceivingContactIds.append(senderCertificate.deviceId)
        return SessionInitResult(
            sessionId: senderCertificate.deviceId,
            decryptedMessage: Data("hello".utf8),
            storageKey: Data(),
            kyberPrekeys: nil
        )
    }

    override func reopenSession(contactId: String, recipientBundle: BinaryKeyBundle) throws -> String {
        reopenContactIds.append(contactId)
        if let reopenRefusal { throw reopenRefusal }
        return "session-\(contactId)"
    }

    override func reopenSessionAllowingStale(contactId: String, recipientBundle: BinaryKeyBundle) throws -> String {
        reopenStaleContactIds.append(contactId)
        return "session-\(contactId)"
    }

    override func initSessionAllowingStale(contactId: String, recipientBundle: BinaryKeyBundle) throws -> String {
        initStaleContactIds.append(contactId)
        return "session-\(contactId)"
    }

    override func exportSession(contactId: String) throws -> Data {
        Data("held-\(contactId)".utf8)
    }

    override func initSession(contactId: String, recipientBundle: BinaryKeyBundle) throws -> String {
        initSendingContactIds.append(contactId)
        return "session-\(contactId)"
    }
}

@MainActor
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
            timestamp: 1_788_698_000,
            contentType: 0,
            // Names the bundle's device; the fake core does not check the signature.
            senderCertificate: SenderCertificate(
                userId: account, domain: "test.example", identityKey: bundleIdentityKey,
                deviceId: bundleDevice, issuedAt: 1, expiresAt: 2, signature: Data(repeating: 0x09, count: 64),
                serverKid: Data(), serverSignatureHybrid: Data()
            ),
            // A handshake header, so the message classifies as one; the fake core never decrypts it.
            rawPayload: handBuiltWirePayload(
                messageNumber: 0,
                suiteId: 1,
                kemCiphertext: [UInt8](repeating: 0x77, count: 1568)
            )
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        // The pin would otherwise be read from Core Data. Overriding it is what lets the test
        // state the premise out loud: the contact list names a *different* device.
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { _ in
            Data((0..<32).map { UInt8($0 &+ 200) })
        }
    }

    override func tearDown() async throws {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        try await super.tearDown()
    }

    func testRespondingInitPersistsUnderTheDeviceItOpened() throws {
        let core = RecordingCore()
        var saved: [String] = []

        _ = try CryptoSessionInitializationService().openReceiving(
            firstMessage(),
            core: core,
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.initReceivingContactIds, [bundleDevice],
                       "premise: the session opens under the certificate's device")
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
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.reopenContactIds, [bundleDevice])
        XCTAssertEqual(saved, [bundleDevice],
                       "the INITIATOR path is the mirror image and had the same defect")
    }

    /// A degraded open over a held session goes through the same reopen, so what the peer already
    /// sent on it still reads. Until core 0.63 this path dropped the session first.
    func testADegradedInitOverAHeldSessionReopensToo() throws {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        var saved: [String] = []

        try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            allowStale: true,
            core: core,
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.reopenStaleContactIds, [bundleDevice])
        XCTAssertEqual(core.reopenContactIds, [], "the strict reopen refuses a stale bundle")
        XCTAssertEqual(core.initStaleContactIds, [], "an init would refuse while a session is held")
        XCTAssertEqual(saved, [bundleDevice])
    }

    /// With nothing held there is nothing to keep, and the core's reopen opens.
    func testADegradedInitWithNothingHeldOpens() throws {
        let core = RecordingCore()
        var saved: [String] = []

        try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            allowStale: true,
            core: core,
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.reopenStaleContactIds, [bundleDevice])
        XCTAssertEqual(core.initStaleContactIds, [])
        XCTAssertEqual(saved, [bundleDevice])
    }

    /// Whether a session is held is not asked here: the core's reopen reads it (todo/253). Neither
    /// case reaches `init`, which would refuse over a held session and, refused, leave an `Opening`
    /// to time out. Mutation: pick `init` when nothing is held — this reddens.
    func testNoInitIsChosenHereEitherWay() throws {
        for held in [false, true] {
            for stale in [false, true] {
                let core = RecordingCore()
                core.sessionExistsFor = held ? [bundleDevice] : []

                try CryptoSessionInitializationService().initializeSession(
                    for: account, bundle: served(), allowStale: stale, core: core, saveSession: { _ in }
                )

                XCTAssertEqual(core.initSendingContactIds + core.initStaleContactIds, [], "held=\(held) stale=\(stale)")
                XCTAssertEqual(core.reopenContactIds + core.reopenStaleContactIds, [bundleDevice], "held=\(held) stale=\(stale)")
            }
        }
    }

    /// A session held with the device is replaced by the core's reopen — built first — and kept
    /// by the core as a previous state. Nothing is archived: up front that left a pair with no
    /// session when the init was then refused, and afterwards it duplicated what the core keeps.
    func testSendingInitOverAHeldSessionReopensAndArchivesNothing() throws {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        var saved: [String] = []

        try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(core.reopenContactIds, [bundleDevice])
        XCTAssertEqual(core.initSendingContactIds, [], "a held session goes through reopen, not init")
        XCTAssertEqual(saved, [bundleDevice])
    }

    /// The reopen refused (`PqRequired` — a peer still on a build from before PQXDH v2): the held
    /// session stays, nothing is archived or saved, and the caller hears why.
    func testRefusedReopenKeepsTheHeldSessionAndSaysWhy() {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        core.reopenRefusal = CryptoError.PqRequired(reason: .hybridIdentityMissing)
        var saved: [String] = []

        XCTAssertThrowsError(try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            saveSession: { saved.append($0) }
        )) { error in
            guard case SessionError.peerNotPostQuantum(let reason)? = error as? SessionError else {
                return XCTFail("expected peerNotPostQuantum, got \(error)")
            }
            XCTAssertEqual(reason, .hybridIdentityMissing)
        }
        XCTAssertEqual(saved, [])
    }

    /// The core's refusals reach the caller with their numbers: nothing is read out of a text.
    func testStaleBundleHearsTheAgeTheCoreMeasured() {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        core.reopenRefusal = CryptoError.PeerSpkStale(ageSecs: 2 * 86_400)

        XCTAssertThrowsError(try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            saveSession: { _ in }
        )) { error in
            guard case SessionError.peerSPKStale(let days)? = error as? SessionError else {
                return XCTFail("expected peerSPKStale, got \(error)")
            }
            XCTAssertEqual(days, 2)
        }
    }

    func testReplayedBundleNamesBothEpochs() {
        let core = RecordingCore()
        core.sessionExistsFor = [bundleDevice]
        core.reopenRefusal = CryptoError.PeerSpkEpochRegressed(received: 4, known: 5)

        XCTAssertThrowsError(try CryptoSessionInitializationService().initializeSession(
            for: account,
            bundle: served(),
            core: core,
            saveSession: { _ in }
        )) { error in
            guard case SessionError.staleSPKBundle(let detail)? = error as? SessionError else {
                return XCTFail("expected staleSPKBundle, got \(error)")
            }
            XCTAssertEqual(detail, "epoch 4 is below the 5 already admitted")
        }
    }
}
