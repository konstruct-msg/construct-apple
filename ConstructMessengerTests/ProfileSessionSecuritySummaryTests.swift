import XCTest
@testable import Construct_Messenger

@MainActor
final class ProfileSessionSecuritySummaryTests: XCTestCase {

    private typealias VM = ProfileShareViewModel

    func testNoSessionReadsAsNoSessionWhateverTheSuite() {
        let s = VM.sessionSecuritySummary(sessionExists: false, suiteId: 3, preV2Handshake: true)
        XCTAssertFalse(s.hasSession)
        XCTAssertEqual(s.suiteLabel, NSLocalizedString("session_crypto_no_session", comment: ""))
    }

    func testSessionWithoutNegotiatedSuiteReadsAsNoSessionLabelButHasSession() {
        let s = VM.sessionSecuritySummary(sessionExists: true, suiteId: 0, preV2Handshake: false)
        XCTAssertTrue(s.hasSession)
        XCTAssertEqual(s.suiteLabel, NSLocalizedString("session_crypto_no_session", comment: ""))
    }

    func testSuiteNamesAndUnknownSuite() {
        XCTAssertEqual(VM.sessionSecuritySummary(sessionExists: true, suiteId: 1, preV2Handshake: false).suiteLabel,
                       "X25519 · ChaCha20-Poly1305")
        XCTAssertEqual(VM.sessionSecuritySummary(sessionExists: true, suiteId: 9, preV2Handshake: false).suiteLabel,
                       "Suite 9")
    }

    func testPreV2HandshakeIsMarkedDegraded() {
        let s = VM.sessionSecuritySummary(sessionExists: true, suiteId: 3, preV2Handshake: true)
        XCTAssertEqual(s.suiteLabel, "X25519 · ChaCha20-Poly1305 · PQ Ratchet (ML-KEM-768) · PQXDH degraded")
    }
}
