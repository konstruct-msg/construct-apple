//
//  SessionSuiteHasOneCarrierTests.swift
//  Construct Messenger
//
//  The suite a session negotiated is in the session's own record, and the core answers it. A copy
//  beside it could only disagree (todo/255).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class SessionSuiteHasOneCarrierTests: XCTestCase {
    private var alice: OrchestratorCore!
    private var bob: OrchestratorCore!
    private var bobId = ""
    private var coreBefore: OrchestratorCore?

    private func device() throws -> (core: OrchestratorCore, id: String) {
        let bootstrap = try createCryptoCore()
        let id = deriveDeviceId(identityPublicKey: try bootstrap.getRegistrationBundleFields().identityPublic)
        let core = try createOrchestratorCoreFromKeys(keysData: try bootstrap.exportPrivateKeys(), myUserId: id)
        _ = try core.ensureHybridSignatureKey()
        return (core, id)
    }

    /// The Keychain name older builds kept their copy under.
    private var copyAccount: String { "construct.session.suite.\(bobId)" }

    private func plantACopy(_ suite: UInt16) {
        var value = suite
        let data = Data(bytes: &value, count: MemoryLayout<UInt16>.size)
        XCTAssertTrue(KeychainManager.shared.saveData(data, forKey: copyAccount, accessible: kSecAttrAccessibleAfterFirstUnlock))
    }

    override func setUp() async throws {
        try await super.setUp()
        (alice, _) = try device()
        (bob, bobId) = try device()
        coreBefore = CryptoManager.shared.orchestratorCore
        CryptoManager.shared.orchestratorCore = alice
        _ = try alice.initSession(contactId: bobId, recipientBundle: try bob.pqxdhTestBundle())
    }

    override func tearDown() async throws {
        CryptoManager.shared.orchestratorCore = coreBefore
        KeychainManager.shared.deleteSession(for: bobId)
        KeychainManager.shared.deleteData(forKey: copyAccount)
        KeychainManager.shared.deleteSessionAtRiskFlag(forDevice: bobId)
        try await super.tearDown()
    }

    /// A session on disk answers from its own record, whatever an older build left beside it.
    func testASessionOnlyOnDiskAnswersFromItsOwnRecord() throws {
        let negotiated = alice.getSessionSuiteId(contactId: bobId)
        XCTAssertGreaterThan(negotiated, 0)
        CryptoManager.shared.saveSessionToKeychain(forDevice: bobId)
        XCTAssertTrue(alice.removeSession(contactId: bobId))
        plantACopy(negotiated + 1)

        XCTAssertEqual(CryptoManager.shared.sessionSuiteId(forDevice: bobId), negotiated)
    }

    /// A retired session has no current state, so nothing protects what is sent next.
    func testARetiredSessionNamesNoSuite() throws {
        XCTAssertTrue(CryptoManager.shared.retireSession(device: bobId))
        plantACopy(3)

        XCTAssertEqual(CryptoManager.shared.sessionSuiteId(forDevice: bobId), 0)
    }

    /// A contact not opened this run has its session on disk, and the profile says so.
    func testAProfileShowsASessionOnlyOnDisk() throws {
        CryptoManager.shared.saveSessionToKeychain(forDevice: bobId)
        let negotiated = alice.getSessionSuiteId(contactId: bobId)
        XCTAssertTrue(alice.removeSession(contactId: bobId))

        let summary = ProfileShareViewModel().sessionSecurity(ofPeer: bobId)

        XCTAssertTrue(summary.hasSession)
        XCTAssertTrue(summary.suiteLabel.hasPrefix(ProfileShareViewModel.cryptoSuiteName(suiteId: Int(negotiated))))
    }

    /// Older builds' copies go at launch; the sessions beside them stay.
    func testThePurgeRemovesTheCopiesAndNothingElse() throws {
        CryptoManager.shared.saveSessionToKeychain(forDevice: bobId)
        let session = KeychainManager.shared.loadSessionData(for: bobId)
        KeychainManager.shared.saveSessionAtRiskFlag(forDevice: bobId)
        plantACopy(3)

        XCTAssertGreaterThanOrEqual(KeychainManager.shared.deleteRetiredSessionSuiteIds(), 1)

        XCTAssertNil(KeychainManager.shared.loadData(forKey: copyAccount))
        XCTAssertNotNil(session)
        XCTAssertEqual(KeychainManager.shared.loadSessionData(for: bobId), session)
        XCTAssertTrue(KeychainManager.shared.loadSessionAtRiskFlag(forDevice: bobId))
    }

    func testNoSessionNamesNoSuite() throws {
        XCTAssertTrue(alice.removeSession(contactId: bobId))
        plantACopy(3)

        XCTAssertEqual(CryptoManager.shared.sessionSuiteId(forDevice: bobId), 0)
    }
}
