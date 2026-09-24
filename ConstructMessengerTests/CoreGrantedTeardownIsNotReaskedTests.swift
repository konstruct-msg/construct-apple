//
//  CoreGrantedTeardownIsNotReaskedTests.swift
//  ConstructMessengerTests
//
//  Build 690, 2026-09-24, two devices: after one divergence neither message nor call got through
//  again. On every undecryptable message the core decided END_SESSION — and in deciding, recorded
//  the teardown and opened its window. `MessageRouter` handed that decision to the coordinator as
//  an ask, the coordinator put it to the same window, and the window refused the grant it had
//  just issued: "END_SESSION cooldown active, skipping", `0/1 device(s)`. No teardown left either
//  device all session, so neither side ever rebuilt the ratchet.
//
//  The alarm path had the same trap and was fixed by `preapproved` (fd6a7829); the incoming-message
//  path, which is the one every divergence takes first, still asked.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class CoreGrantedTeardownIsNotReaskedTests: XCTestCase {

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

    // MARK: - The premise

    /// Why a grant must not be put to the window again: the grant *is* the window's opening, so a
    /// second ask for the same device is refused. If the core ever stops behaving this way, the
    /// rule below is no longer needed — and this is the test that says so.
    func testAGrantOpensTheWindowThatRefusesTheNextAsk() throws {
        let device = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ask = CfeIncomingEvent.teardownRequested(contactId: device, cause: .blind)

        let first = try CryptoManager.shared.handleOrchestratorEvent(ask, tag: "test")
        let second = try CryptoManager.shared.handleOrchestratorEvent(ask, tag: "test")

        XCTAssertTrue(first.contains { if case .sendEndSession = $0 { return true }; return false },
                      "the first ask for a device must be granted — nothing is in flight yet")
        XCTAssertFalse(second.contains { if case .sendEndSession = $0 { return true }; return false },
                       "a second ask inside the window was granted; the grant no longer opens it")
    }

    // MARK: - The rule

    /// Mutation: in `MessageRouter`'s `.sendEndSession` verdict, call `needsEndSession` instead of
    /// `coreGrantedEndSession` — this reddens.
    func testTheCoresVerdictReachesTheCoordinatorAsAGrant() throws {
        let block = try verdictBlock(in: source("Services/Messaging/MessageRouter.swift"))
        XCTAssertTrue(block.contains("coreGrantedEndSession:"),
                      "the core's `.sendEndSession` verdict is not handed over as a grant")
        XCTAssertFalse(block.contains("needsEndSession:"),
                       "the core's `.sendEndSession` verdict is handed over as an ask, which the window refuses")
    }

    /// Mutation: pass `preapproved: false` from `coreGrantedEndSession` — this reddens.
    func testTheCoordinatorSendsAGrantWithoutAskingAgain() throws {
        let source = try source("Services/Session/SessionCoordinator.swift")
        guard let start = source.range(of: "coreGrantedEndSession peer: PeerAddress) {") else {
            return XCTFail("SessionCoordinator does not implement coreGrantedEndSession")
        }
        let body = String(source[start.upperBound...].prefix(200))
        XCTAssertTrue(body.contains("preapproved: true"),
                      "a grant is put to the teardown window again: \(body)")
    }

    // MARK: - Helpers

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `.sendEndSession` arm of the routing-verdict switch, up to the next arm.
    private func verdictBlock(in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "case .sendEndSession(let divergedDevice):"),
                                  "the verdict arm moved — this test must follow it")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n        case .")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}
