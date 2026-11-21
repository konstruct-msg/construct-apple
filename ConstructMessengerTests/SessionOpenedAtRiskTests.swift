//
//  SessionOpenedAtRiskTests.swift
//  ConstructMessengerTests
//
//  Since construct-core 0.77.0 the core decides whether a bundle past the signed-prekey age limit
//  may open a session (`plan_stale_spk`), and its answer to the open says so with
//  `SessionOpenedAtRisk`. The flag that action sets is what the at-risk banner and the foreground
//  upgrade sweep read — the same flag a degraded `allowStale` init sets.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class SessionOpenedAtRiskTests: XCTestCase {

    private let device = "a7e1c0de" + String(repeating: "0", count: 24)

    override func tearDown() {
        KeychainManager.shared.deleteSessionAtRiskFlag(forDevice: device)
        super.tearDown()
    }

    /// Mutation: make the case a no-op — this reddens.
    func testTheCoresAtRiskAnswerSetsTheFlag() {
        KeychainManager.shared.deleteSessionAtRiskFlag(forDevice: device)
        SessionActionExecutor.shared.execute([.sessionOpenedAtRisk(contactId: device)])
        XCTAssertTrue(KeychainManager.shared.loadSessionAtRiskFlag(forDevice: device))
    }

    /// The answer to an open is read before it is executed: a clean open clears the flag, an
    /// at-risk one must not, or the flag the executor is about to set is cleared first and then
    /// set — and a reordering of the two would leave a degraded session looking sound.
    ///
    /// Mutation: drop `!atRisk` from the clear — this reddens.
    func testAnAtRiskOpenIsNotClearedByTheAnswer() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Crypto/SessionInitializationService.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(
            text.contains("if case .sessionBundleFetched = event, !refused, !atRisk {"),
            "answerOpenSession clears the at-risk flag on an open the core called at risk"
        )
    }
}
