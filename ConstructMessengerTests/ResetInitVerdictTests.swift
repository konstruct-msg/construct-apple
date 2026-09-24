//
//  ResetInitVerdictTests.swift
//  ConstructMessengerTests
//
//  The Swift half of the SESSION_RESET_INIT verdict. The rule and its ledger live in the core's
//  session machine since 2026-09-24 and are tested there; what is left here is that this app
//  asks the core, reads the answer the right way round, and that the answer survives the trip
//  across UniFFI — which is where a verdict read backwards would land silently.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ResetInitVerdictTests: XCTestCase {

    private var savedUserId: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedUserId = AuthSessionManager.shared.currentUserId
        let me = UUID().uuidString
        AuthSessionManager.shared.updateUserId(me)
        try CryptoCoreTestBootstrap.ensureCore(localUserId: me)
    }

    override func tearDown() {
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        super.tearDown()
    }

    private func freshDevice() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Build 579, 15:22:04: one init delivered twice a second apart, with the establishment record
    /// not yet caught up. The first copy applies, the second is a redelivery.
    /// Mutation that reddens it: map `.resetInitSuperseded(redelivery: true)` to `.apply` or to
    /// `.predatesSession` in `CryptoManager.judgeResetInit`.
    func testARedeliveredInitIsRecognisedThroughTheCore() {
        let device = freshDevice()
        let key = Data(repeating: 0xA7, count: 32)
        let ts: UInt64 = 1_785_943_323
        let staleEstablished: UInt64 = 1_785_943_288

        XCTAssertEqual(CryptoManager.shared.judgeResetInit(fromDevice: device, initEphemeral: key, sentAt: ts, establishedAt: staleEstablished), .apply)
        XCTAssertEqual(CryptoManager.shared.judgeResetInit(fromDevice: device, initEphemeral: key, sentAt: ts, establishedAt: staleEstablished), .redelivery,
                       "a redelivery of the init we just applied must not re-establish")
        XCTAssertEqual(CryptoManager.shared.judgeResetInit(fromDevice: device, initEphemeral: Data(repeating: 0xB3, count: 32), sentAt: ts + 17, establishedAt: ts + 1), .apply,
                       "a genuine peer retry is a new key and applies over the session the last one built")
    }

    /// A never-applied init older than the session held is a backlog replay.
    /// Mutation that reddens it: map `redelivery: false` to `.apply`.
    func testAnInitOlderThanTheSessionIsAReplay() {
        XCTAssertEqual(
            CryptoManager.shared.judgeResetInit(fromDevice: freshDevice(), initEphemeral: Data(repeating: 1, count: 32), sentAt: 1_785_943_300, establishedAt: 1_785_943_324),
            .predatesSession
        )
    }

    /// An account id is not a device, and the core's ledger is per device: handed one, the call
    /// cannot be asked and falls back to applying — the direction that cannot strand a peer.
    func testAnAccountIdIsNotAskedAndApplies() {
        let key = Data(repeating: 2, count: 32)
        let account = UUID().uuidString
        XCTAssertEqual(CryptoManager.shared.judgeResetInit(fromDevice: account, initEphemeral: key, sentAt: 1, establishedAt: nil), .apply)
        XCTAssertEqual(CryptoManager.shared.judgeResetInit(fromDevice: account, initEphemeral: key, sentAt: 1, establishedAt: nil), .apply)
    }
}
