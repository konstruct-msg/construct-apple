//
//  FailedDecryptKeepsTheSessionTests.swift
//  Construct Messenger
//
//  A message the core cannot read leaves the session where it is.
//
//  Until 2026-11-04 a failed decrypt here went on to an archive of this app's own and then dropped
//  the session from the core and the Keychain. The archive lookup never reached an archive — the
//  one caller hands a SENDER_SYNC, whose `message.from` is our own account — and the drop ran on
//  every own-device session the SENDER_SYNC walk tried before the one that opened the copy. A wrong
//  candidate failing is that walk's expected outcome; each one cost a healthy session with a
//  sibling. The core already tries the current state and every previous one, newest first
//  (`decisions/the-core-keeps-previous-states-the-app-keeps-no-archive.md`).
//

import Synchronization
import XCTest
@testable import Construct_Messenger

/// A core with one session, whose decrypt answers as told and which records every write to it.
private final class DecryptCore: OrchestratorCore, @unchecked Sendable {
    /// Never deallocated: the generated `deinit` frees the Rust handle unconditionally, and a fake
    /// built with `noHandle` has none (see `RecordingCore` in SessionInitAddressesTheDeviceTests).
    private static let kept = Mutex<[DecryptCore]>([])

    var readable = false
    private(set) var removed: [String] = []
    private(set) var imported: [String] = []
    private(set) var retired: [String] = []

    init() {
        super.init(noHandle: NoHandle())
        Self.kept.withLock { $0.append(self) }
    }

    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func hasSession(contactId: String) -> Bool { true }

    override func decryptWirePayload(contactId: String, wirePayload: Data) throws -> DecryptedMessageResult {
        guard readable else {
            throw CryptoError.DecryptionFailed(message: "AEAD decryption failed")
        }
        return DecryptedMessageResult(plaintext: Data("hi".utf8), storageKey: Data(repeating: 1, count: 32))
    }

    override func removeSession(contactId: String) -> Bool {
        removed.append(contactId)
        return true
    }

    override func importSession(contactId: String, data: Data) throws -> String {
        imported.append(contactId)
        return "imported"
    }

    override func retireSession(contactId: String) -> [CfeAction] {
        retired.append(contactId)
        return []
    }
}

final class FailedDecryptKeepsTheSessionTests: XCTestCase {
    private let sibling = "6f5e37ac1b9d40e2a8c37f5b12de904a"
    private let ownAccount = "14f28d31-9f4a-4c1e-8b77-0d2a6e5f3c91"

    /// A SENDER_SYNC as the walk hands it: `from` is our own account, the session named apart.
    private func senderSync() -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            from: ownAccount,
            to: ownAccount,
            timestamp: 1_788_698_000,
            rawPayload: Data(repeating: 0x42, count: 64)
        )
    }

    func testAFailedDecryptThrowsAndLeavesTheSessionAlone() {
        let core = DecryptCore()
        var saved: [String] = []

        XCTAssertThrowsError(try MessageCryptoService().decryptMessage(
            senderSync(),
            contactIdOverride: sibling,
            core: core,
            restoreSession: { _ in XCTFail("the session is in memory"); return false },
            saveSession: { saved.append($0) }
        )) { error in
            guard case .decryptionFailed? = error as? CryptoManagerError else {
                return XCTFail("expected decryptionFailed, got \(error)")
            }
        }

        XCTAssertEqual(core.removed, [], "a message this session cannot read is no reason to drop it")
        XCTAssertEqual(core.imported, [], "nothing replaces the current state from outside the core")
        XCTAssertEqual(core.retired, [], "nor is it retired: the next candidate may be the sender")
        XCTAssertEqual(saved, [], "a failed decrypt changed nothing worth persisting")
    }

    /// The other half, so the test above is not passing on a service that does nothing: a decrypt
    /// that works returns the plaintext and persists the advanced session, under the device.
    func testADecryptThatWorksPersistsTheSessionItAdvanced() throws {
        let core = DecryptCore()
        core.readable = true
        var saved: [String] = []

        let result = try MessageCryptoService().decryptMessage(
            senderSync(),
            contactIdOverride: sibling,
            core: core,
            restoreSession: { _ in false },
            saveSession: { saved.append($0) }
        )

        XCTAssertEqual(result.plaintext, Data("hi".utf8))
        XCTAssertEqual(saved, [sibling])
        XCTAssertEqual(core.removed, [])
    }
}

/// What older builds archived is purged; the live session beside it is not.
final class RetiredSessionArchivePurgeTests: XCTestCase {
    private let device = "0b4577bc9d40e2a8c37f5b12de904a6f"

    override func tearDown() {
        KeychainManager.shared.deleteSession(for: device)
        KeychainManager.shared.deleteRetiredSessionArchives()
        super.tearDown()
    }

    func testThePurgeDeletesArchivesAndKeepsTheLiveSession() {
        let keychain = KeychainManager.shared
        let archive = KeychainSessionAccounts.archiveAccount(for: device)
        let live = KeychainSessionAccounts.account(for: device)
        XCTAssertTrue(keychain.saveData(Data([1, 2, 3]), forKey: archive, accessible: KeychainManager.cryptoKeyAccessible))
        XCTAssertTrue(keychain.saveData(Data([4, 5, 6]), forKey: live, accessible: KeychainManager.cryptoKeyAccessible))

        XCTAssertGreaterThanOrEqual(keychain.deleteRetiredSessionArchives(), 1)

        XCTAssertNil(keychain.loadData(forKey: archive), "the archive is chain keys kept past their use")
        XCTAssertEqual(keychain.loadData(forKey: live), Data([4, 5, 6]), "the live session is not an archive")
    }
}
