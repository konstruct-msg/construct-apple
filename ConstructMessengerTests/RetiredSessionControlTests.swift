//
//  RetiredSessionControlTests.swift
//  ConstructMessengerTests
//
//  AGENTS.md rule 11: a temporary exception has an end date and a check. That each retired type is
//  still recognised on receipt is ContentTypeConformanceTests' job, against the cross-client table.
//

import XCTest
@testable import Construct_Messenger

final class RetiredSessionControlTests: XCTestCase {

    /// Red on the day the receive guards for 21/24/25/26 may go. `RetiredSessionControl`'s
    /// comment lists them and the protos change that goes with them.
    func testTheReceiveGuardsAreDeletedByTheirEndDate() {
        XCTAssertLessThan(
            Date(), RetiredSessionControl.removeAfter,
            "the last build that sent END_SESSION / SESSION_RESET_INIT / ping / ready has expired — delete the guards listed in RetiredSessionControl.swift"
        )
    }

    /// END_SESSION (21) is acknowledged and dropped before `routeIncomingMessage` builds an
    /// event for the core. Past that point its sentinel payload is not a wire payload: the core
    /// would answer it as unreadable — a DECRYPTION_ERROR sent to a build that cannot read one.
    ///
    /// Mutation: disable the early exit — this reddens (nothing else did, 2026-11-03).
    func testEndSessionIsAcknowledgedBeforeAnyDecryption() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Messaging/MessageRouter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let route = try XCTUnwrap(source.range(of: "func routeIncomingMessage("))
        let body = source[route.lowerBound...]
        let exit = try XCTUnwrap(body.range(of: """
                    if message.isEndSession {
                        PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId)
            """), "the early exit acknowledges")
        let after = body[exit.upperBound...]
        let returns = try XCTUnwrap(after.range(of: "return\n"), "and returns")
        let build = try XCTUnwrap(body.range(of: "buildIncomingEvent("))
        XCTAssertLessThan(exit.lowerBound, build.lowerBound, "before the event for the core is built")
        XCTAssertLessThan(returns.lowerBound, build.lowerBound)
    }
}
