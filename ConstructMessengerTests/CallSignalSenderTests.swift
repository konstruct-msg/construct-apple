import XCTest
@testable import Construct_Messenger

/// A call signal reaches CallManager under the sender's account, never the device id the core
/// names it by.
///
/// CallManager gates every signal on an account — blocked, callable contact. The executor used to
/// dispatch `callSignalDecrypted` itself, with the action's contact id, which is the *device* the
/// core decrypted on: the gate failed and the signal was dropped as "non-callable". Harmless while
/// sealed signals went through the router's frame branch with the account; from core 0.29 every
/// sealed signal arrived as `callSignalDecrypted`, and every incoming call was dropped
/// (2026-10-02). Now only the router, which holds the account, dispatches it.
///
/// What this pins is the classification: the executor lists `callSignalDecrypted` as router-bound
/// (so a drain that leaves it unconsumed logs it). It cannot see a dispatch put back into
/// `SessionActionExecutor.executeOne` — CallManager is a singleton with no seam — so that change
/// would pass here; the comment there is the guard. Mutation: take it off the router-bound list —
/// the first test reddens.
@MainActor
final class CallSignalSenderTests: XCTestCase {

    private let action = CfeAction.callSignalDecrypted(
        contactId: "6f5e37ac6f5e37ac6f5e37ac6f5e37ac",  // a device id, as the core names it
        messageId: "m-1",
        protoBytes: Data([0x0a, 0x01, 0x41])
    )

    func testTheExecutorLeavesCallSignalsToTheRouter() {
        XCTAssertEqual(SessionActionExecutor.routerBoundName(action), "callSignalDecrypted")
    }

    func testTheRouterTakesTheSignalBytesAndNothingElse() {
        let other = CfeAction.notifyNewMessage(chatId: "c", preview: "p")
        XCTAssertEqual(MessageRouter.callSignals(in: [other, action, other]), [Data([0x0a, 0x01, 0x41])])
        XCTAssertTrue(MessageRouter.callSignals(in: [other]).isEmpty)
    }
}
