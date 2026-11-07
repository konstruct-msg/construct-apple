//
//  RetiringKeepsWhatWasInFlightTests.swift
//  Construct Messenger
//
//  A message the peer sent before a session was retired still reads. Real core, real keys: this is
//  what `discardAllSessions` cost at an invite redeem (todo/259). Previous states are the core's
//  (`decisions/the-core-keeps-previous-states-the-app-keeps-no-archive.md`).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class RetiringKeepsWhatWasInFlightTests: XCTestCase {
    private var alice: OrchestratorCore!
    private var bob: OrchestratorCore!
    private var bobId = ""
    private var aliceId = ""
    private var coreBefore: OrchestratorCore?

    private func device() throws -> (core: OrchestratorCore, id: String) {
        let bootstrap = try createCryptoCore()
        let id = deriveDeviceId(identityPublicKey: try bootstrap.getRegistrationBundleFields().identityPublic)
        let core = try createOrchestratorCoreFromKeys(keysData: try bootstrap.exportPrivateKeys(), myUserId: id)
        _ = try core.ensureHybridSignatureKey()
        return (core, id)
    }

    override func setUp() async throws {
        try await super.setUp()
        (alice, aliceId) = try device()
        (bob, bobId) = try device()
        coreBefore = CryptoManager.shared.orchestratorCore
        CryptoManager.shared.orchestratorCore = alice
        _ = try alice.initSession(contactId: bobId, recipientBundle: try bob.pqxdhTestBundle())
        let first = try alice.encryptToWire(contactId: bobId, plaintext: Data("hello".utf8))
        _ = try bob.pqxdhTestReceive(from: alice, wirePayload: first)
    }

    override func tearDown() async throws {
        CryptoManager.shared.orchestratorCore = coreBefore
        KeychainManager.shared.deleteSession(for: bobId)
        try await super.tearDown()
    }

    func testAMessageSentBeforeTheRetireStillReads() throws {
        let late = try bob.encryptToWire(contactId: aliceId, plaintext: Data("late".utf8))

        XCTAssertTrue(CryptoManager.shared.retireSession(device: bobId))

        XCTAssertFalse(alice.hasSession(contactId: bobId), "the next send opens a new state")
        XCTAssertEqual(try alice.decryptWirePayload(contactId: bobId, wirePayload: late).plaintext, Data("late".utf8))
    }

    /// A chat nobody opened this run has its session on disk only. Retiring it must load it first,
    /// or nothing is retired and the old state comes back as current on the next load.
    func testASessionOnlyOnDiskIsRetiredToo() throws {
        let late = try bob.encryptToWire(contactId: aliceId, plaintext: Data("late".utf8))
        CryptoManager.shared.saveSessionToKeychain(forDevice: bobId)
        XCTAssertTrue(alice.removeSession(contactId: bobId))
        XCTAssertTrue(CryptoManager.shared.hasStoredSessionState(for: bobId))

        XCTAssertTrue(CryptoManager.shared.retireSession(device: bobId))

        XCTAssertFalse(alice.hasSession(contactId: bobId))
        XCTAssertEqual(try alice.decryptWirePayload(contactId: bobId, wirePayload: late).plaintext, Data("late".utf8))
    }

    /// The retired state reaches the Keychain, so a restart does not bring it back as current.
    func testTheRetireIsSaved() throws {
        CryptoManager.shared.saveSessionToKeychain(forDevice: bobId)
        let before = KeychainManager.shared.loadSessionData(for: bobId)

        XCTAssertTrue(CryptoManager.shared.retireSession(device: bobId))

        XCTAssertNotNil(KeychainManager.shared.loadSessionData(for: bobId))
        XCTAssertNotEqual(KeychainManager.shared.loadSessionData(for: bobId), before)
    }
}
