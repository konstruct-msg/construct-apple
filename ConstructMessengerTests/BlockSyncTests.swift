//
//  BlockSyncTests.swift
//  ConstructMessengerTests
//
//  A lost unblock left the server's `user_blocks` row behind and the person shown as unblocked
//  could not be called (TODO 170, 2026-10-18).
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

final class BlockSyncTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "BlockSyncTests"

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Block then unblock before either reached the server: only the unblock is sent.
    /// Mutation: keep the first wish instead of replacing it — this reddens.
    func testTheLatestWishReplacesTheOneWaiting() {
        BlockSync.record("u1", blocked: true, reason: "spam", in: defaults)
        BlockSync.record("u1", blocked: false, in: defaults)
        XCTAssertEqual(BlockSync.pending(in: defaults), ["u1": .init(blocked: false, reason: nil)])
    }

    /// An unblock recorded while the block was in flight is not cleared by the block's answer.
    /// Mutation: `confirm` removes the entry whatever it holds — this reddens.
    func testAnAnswerClearsOnlyTheWishThatWasSent() {
        BlockSync.record("u1", blocked: true, in: defaults)
        let sent = BlockSync.pending(in: defaults)["u1"]!
        BlockSync.record("u1", blocked: false, in: defaults)
        BlockSync.confirm("u1", sent, in: defaults)
        XCTAssertEqual(BlockSync.pending(in: defaults)["u1"]?.blocked, false)
        BlockSync.confirm("u1", .init(blocked: false, reason: nil), in: defaults)
        XCTAssertEqual(BlockSync.pending(in: defaults), [:])
    }

    /// Mutation: drop everything that fails (the old best-effort) — the path cases redden.
    func testThePathFailingIsRetriedAndARefusalIsNot() {
        XCTAssertEqual(BlockSync.disposition(after: VeilTunnelNotUp()), .retry)
        XCTAssertEqual(BlockSync.disposition(after: GRPCClientError.clientSideTimeout), .retry)
        XCTAssertEqual(BlockSync.disposition(after: RPCError(code: .unavailable, message: "")), .retry)
        XCTAssertEqual(BlockSync.disposition(after: RPCError(code: .unauthenticated, message: "")), .retry)
        XCTAssertEqual(BlockSync.disposition(after: RPCError(code: .notFound, message: "user not found")), .drop)
        XCTAssertEqual(BlockSync.disposition(after: RPCError(code: .invalidArgument, message: "")), .drop)
    }

    /// The server's row is shown here rather than lifted blindly; a queued wish wins.
    /// Mutation: adopt everything the server lists — the queued unblock reddens.
    func testAServerBlockNotShownHereIsShownUnlessAWishIsQueued() {
        let adopt = BlockSync.toAdopt(
            serverBlocked: ["stale", "queued", "known"],
            pending: ["queued": .init(blocked: false, reason: nil)],
            isBlockedHere: { $0 == "known" }
        )
        XCTAssertEqual(adopt, ["stale"])
    }
}
