//
//  UnreadMessageAnswerTests.swift
//  ConstructMessengerTests
//
//  A message no held state reads is answered with a DECRYPTION_ERROR, and the core answers only a
//  writer whose certificate it can check against the server keys. Until 2026-09-30 this app handed
//  those keys over only before a receiving open, so in a process that had not opened one the
//  error was never produced: the sender never learned, and the message was lost with everything
//  after it (stand 2026-09-30, `af352953`, `f1268b74`; Android fixed the same in `1747454`).
//  TODO 80 (1).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class UnreadMessageAnswerTests: XCTestCase {

    private var savedKey: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        if !CryptoManager.shared.isInitialized {
            CryptoManager.shared.setLocalUserId(UUID().uuidString)
            _ = try CryptoManager.shared.generateRegistrationBundle()
            CryptoManager.shared.reloadCoreFromKeychain()
        }
        XCTAssertTrue(CryptoManager.shared.isInitialized, "without a core nothing below is reached")
        savedKey = UserDefaults.standard.data(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        UserDefaults.standard.set(TestCertificateServer.shared.verifyingKey, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedKey, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        super.tearDown()
    }

    /// Mutation: hand the keys over only in `openReceiving` again — no error is produced.
    func testAnUnreadMessageIsAnsweredBeforeAnyReceivingOpen() throws {
        let writer = try makeTestDevice()
        let certificate = try TestCertificateServer.shared.certificate(for: writer.core)
        // A process that has opened no receiving session: the core holds no server keys yet.
        CryptoManager.shared.orchestratorCore?.setTrustedServerKeys(keys: [])

        let messageId = UUID().uuidString
        // Mid-ratchet, no handshake, on a state this device does not hold.
        var actions = try CryptoManager.shared.handleOrchestratorEvent(.messageReceived(
            messageId: messageId,
            from: writer.deviceId,
            data: handBuiltWirePayload(messageNumber: 5, suiteId: 3),
            contentType: 0,
            senderCertificate: certificate
        ))
        if actions.contains(where: { if case .checkAckInDb = $0 { return true }; return false }) {
            actions = try CryptoManager.shared.handleOrchestratorEvent(
                .ackDbResult(messageId: messageId, isProcessed: false)
            )
        }

        XCTAssertTrue(
            actions.contains {
                guard case .sendDecryptionError(let contactId, let id, _) = $0 else { return false }
                return contactId == writer.deviceId && id == messageId
            },
            "the writer is told, so it resends on a state it opens: \(actions)"
        )
    }
}
