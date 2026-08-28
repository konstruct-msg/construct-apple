//
//  SelfAddressedTrafficTests.swift
//  ConstructMessengerTests
//
//  Our own account is not a peer. It reached the peer path anyway, and the visible half was a
//  chat with ourselves in the list on 2026-08-28.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class SelfAddressedTrafficTests: XCTestCase {

    private let ourAccount = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
    private let peerAccount = "7574fdec-2c1a-4a0f-9d3e-1b0b6f2c9a41"
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
        SessionAddressing.ownAccountOverrideForTesting = ourAccount
    }

    override func tearDown() {
        SessionAddressing.ownAccountOverrideForTesting = nil
        DeliveryReceiptBatcher.shared.discardForTesting()
        context = nil
        super.tearDown()
    }

    // MARK: - The shape of an envelope that has no peer

    /// Own-account traffic is addressed `from == to == us`. That is the whole signature, and it is
    /// asked of the envelope rather than of the peer the receive path derives from it.
    ///
    /// Mutation: compare only `from`, or only `to` — either reddens on the two ordinary directions
    /// below, which are the traffic that must keep flowing.
    func testOnlyAnEnvelopeAddressedBothWaysToUsIsOurOwnReflection() {
        XCTAssertTrue(
            SessionAddressing.isOwnReflection(from: ourAccount, to: ourAccount, ourAccountId: ourAccount)
        )
        XCTAssertFalse(
            SessionAddressing.isOwnReflection(from: peerAccount, to: ourAccount, ourAccountId: ourAccount),
            "an ordinary incoming message is addressed to us and must not be dropped"
        )
        XCTAssertFalse(
            SessionAddressing.isOwnReflection(from: ourAccount, to: peerAccount, ourAccountId: ourAccount),
            "our own send to a contact is not a reflection"
        )
        XCTAssertFalse(
            SessionAddressing.isOwnReflection(from: peerAccount, to: peerAccount, ourAccountId: ourAccount)
        )
    }

    /// No signed-in account means no comparison to make. Answering `true` on an empty id would
    /// classify an envelope between two empty strings — the shape a decode failure produces — as
    /// our own traffic and drop it silently.
    ///
    /// Mutation: drop the `ourAccountId.isEmpty` guard — this reddens.
    func testNothingIsOurOwnReflectionWithoutAnAccount() {
        XCTAssertFalse(SessionAddressing.isOwnReflection(from: "", to: "", ourAccountId: ""))
        XCTAssertFalse(
            SessionAddressing.isOwnReflection(from: ourAccount, to: ourAccount, ourAccountId: "")
        )
    }

    /// Why the guard cannot be left to the derived peer: `from == me ? to : from` answers **me**
    /// for exactly this envelope, and is right for every other pair. The receive path then treats
    /// us as the person on the other side — which is how the chat with ourselves was minted.
    ///
    /// This test has no mutation of its own. It pins the reason the classifier exists, so that
    /// deleting the classifier in favour of "just compare the derived peer" is a visible decision
    /// rather than a simplification.
    func testTheDerivedPeerCannotTellOurOwnTrafficApart() {
        let derivedPeer = { (from: String, to: String) in from == self.ourAccount ? to : from }
        XCTAssertEqual(derivedPeer(ourAccount, ourAccount), ourAccount)
        XCTAssertEqual(derivedPeer(peerAccount, ourAccount), peerAccount)
    }

    // MARK: - Our own account as a recipient

    /// Mutation: return the signed-in account unconditionally, or drop the empty-id guard —
    /// either reddens.
    func testOurOwnAccountIsRecognisedAndNothingElseIs() {
        XCTAssertTrue(SessionAddressing.isOurOwnAccount(ourAccount))
        XCTAssertFalse(SessionAddressing.isOurOwnAccount(peerAccount))
        XCTAssertFalse(SessionAddressing.isOurOwnAccount(""))
    }

    /// A SENDER_SYNC is a copy of a message *we* sent, so the receipt for it was addressed back to
    /// the account that produced it. Nobody is waiting for that checkmark — and the server's
    /// per-device fan-out handed the receipt straight back to us, where its real content type (14,
    /// inside the KNST frame) is invisible on the outer envelope.
    ///
    /// Mutation: remove the own-account guard from `sendDeliveryReceipt` — this reddens, while the
    /// peer case keeps passing, which is exactly how the defect looked in production.
    func testAReceiptToOurOwnAccountIsNeverEnqueued() async {
        let batcher = DeliveryReceiptBatcher.shared
        batcher.discardForTesting()

        OutboundSessionService.sendDeliveryReceipt(
            for: ["6f1e3c2a-0000-4000-8000-000000000001"], to: peerAccount, in: context
        )
        await settle { batcher.pendingCountForTesting == 1 }
        XCTAssertEqual(batcher.pendingCountForTesting, 1, "a receipt to a contact must still be sent")

        OutboundSessionService.sendDeliveryReceipt(
            for: ["6f1e3c2a-0000-4000-8000-000000000002"], to: ourAccount, in: context
        )
        await settle { batcher.pendingCountForTesting > 1 }
        XCTAssertEqual(
            batcher.pendingCountForTesting, 1,
            "a receipt addressed to our own account comes back through the fan-out as a "
            + "self-addressed delivery — it must never leave"
        )
    }

    // MARK: - The guard's place in the receive path

    /// The guard has to sit **after** the SENDER_SYNC branch and **before** anything that resolves
    /// a peer: SENDER_SYNC is the one carrier that legitimately arrives self-addressed, and the
    /// chat, the session and the tie-break all come later.
    ///
    /// Mutation: move the guard above the SENDER_SYNC branch (multi-device sync stops entirely) or
    /// below `findOrCreateChat` (the chat with ourselves comes back) — this reddens either way.
    func testTheReceivePathDropsOurOwnTrafficAfterSenderSyncAndBeforeTheChat() throws {
        let source = try XCTUnwrap(
            try? String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("ConstructMessenger/Services/Messaging/MessageRouter.swift"),
                encoding: .utf8
            )
        )
        let senderSync = try XCTUnwrap(source.range(of: "if message.isSenderSync {"))
        let reflection = try XCTUnwrap(source.range(of: "SessionAddressing.isOwnReflection("))
        let chat = try XCTUnwrap(source.range(of: "try findOrCreateChat(for: otherUserId, in: context)"))
        XCTAssertLessThan(
            senderSync.lowerBound, reflection.lowerBound,
            "SENDER_SYNC is self-addressed by design and must be routed before the drop"
        )
        XCTAssertLessThan(
            reflection.lowerBound, chat.lowerBound,
            "the drop must precede chat creation, or the chat with ourselves is created first"
        )
    }

    // MARK: - Helpers

    /// `sendDeliveryReceipt` hops to the main actor to enqueue. Yield until the condition holds or
    /// the budget runs out; the assertion, not this, decides the outcome.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<50 {
            if done() { return }
            await Task.yield()
        }
    }
}
