//
//  ReactionStoreTests.swift
//  ConstructMessengerTests
//
//  `Reactions` over `ReactionStore` (messages B3): a reaction is a Reaction row, never a Message.
//  Orphans (target missing) stay until the target arrives or the 7-day TTL — the store decides
//  which reaction is an orphan, as the crate's `expire_reactions` does.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class ReactionStoreTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var store: CoreDataReactionStore!
    private var context: NSManagedObjectContext { container.viewContext }
    private let day: Int64 = 24 * 60 * 60 * 1000

    private let target = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let reactor = "11111111-2222-4333-8444-555555555555"
    private let t0: Int64 = 1_700_000_000_000
    private let t1: Int64 = 1_700_000_000_500

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        store = CoreDataReactionStore(container: container)
    }

    override func tearDown() {
        store = nil
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func apply(
        emoji: String,
        action: Int,
        ts: Int64,
        now: Int64? = nil,
        target: String? = nil,
        reactor: String? = nil
    ) -> ReactionReducer.Decision {
        Reactions.applyIncoming(
            targetMessageId: target ?? self.target,
            reactorUserId: reactor ?? self.reactor,
            actionRawValue: action,
            emoji: emoji,
            payloadTimestampMs: ts,
            fallbackTimestampMs: 0,
            nowMs: now ?? ts,
            store: store
        )
    }

    private func stored() -> ReactionRecord? {
        try? store.reaction(on: target, by: reactor)
    }

    private func insertTargetMessage(id: String? = nil) {
        let msg = Message(context: context)
        msg.id = id ?? target
        msg.fromUserId = reactor
        msg.toUserId = "00000000-0000-4000-8000-000000000000"
        msg.timestamp = Date(timeIntervalSince1970: TimeInterval(t0) / 1000)
        msg.isSentByMe = false
        msg.encryptedContent = Data()
        msg.retryCount = 0
        try? context.save()
    }

    func testAddCreatesRow_NotAMessage() {
        XCTAssertEqual(apply(emoji: "❤️", action: 1, ts: t0), .set(emoji: "❤️", timestampMs: t0))
        let row = stored()
        XCTAssertEqual(row?.emoji, "❤️")
        XCTAssertEqual(row?.timestampMs, t0)
        XCTAssertEqual(row?.targetMessageId, target)
        XCTAssertEqual(row?.reactorUserId, reactor)

        let messages = (try? context.fetch(Message.fetchRequest())) ?? []
        XCTAssertTrue(messages.isEmpty, "a reaction must never become a transcript row")
    }

    func testNewerAddReplacesEmoji() {
        apply(emoji: "😂", action: 1, ts: t0)
        XCTAssertEqual(apply(emoji: "🔥", action: 1, ts: t1), .set(emoji: "🔥", timestampMs: t1))
        XCTAssertEqual(stored()?.emoji, "🔥")
        XCTAssertEqual(try store.reactions(on: target).count, 1,
                       "one row per (message, reactor) — replace, do not insert a second")
    }

    func testStaleAddDoesNotOverwrite() {
        apply(emoji: "❤️", action: 1, ts: t1)
        XCTAssertEqual(apply(emoji: "😂", action: 1, ts: t0), .keepExisting)
        XCTAssertEqual(stored()?.emoji, "❤️")
    }

    func testRemoveDeletesRow() {
        apply(emoji: "❤️", action: 1, ts: t0)
        XCTAssertEqual(apply(emoji: "", action: 2, ts: t1), .clear)
        XCTAssertNil(stored())
    }

    func testInvalidDoesNotInsert() {
        XCTAssertEqual(apply(emoji: "❤️", action: 1, ts: t0, target: ""), .dropInvalid)
        XCTAssertTrue(try store.reactions(on: target).isEmpty)
    }

    func testOrphanIsStoredWhenTargetMissing() {
        apply(emoji: "😮", action: 1, ts: t0)
        XCTAssertNotNil(stored(), "a reaction that beat its message must still land")
        let messages = (try? context.fetch(Message.fetchRequest())) ?? []
        XCTAssertTrue(messages.isEmpty)
    }

    /// Mutation: `>=` for `<=` on `receivedAt` in `expireOrphans` — the six-day orphan goes and
    /// the seven-day one stays.
    func testOrphanEvictedAfterSevenDaysIfTargetNeverArrives() {
        apply(emoji: "😢", action: 1, ts: t0, now: t0)
        Reactions.sweepOrphans(nowMs: t0 + 6 * day, store: store)
        XCTAssertNotNil(stored(), "six days is not yet the TTL")
        Reactions.sweepOrphans(nowMs: t0 + 7 * day, store: store)
        XCTAssertNil(stored(), "an orphan whose target never arrived must not grow forever")
    }

    /// Mutation: drop the message check in `expireOrphans` — every old reaction goes, the bug
    /// construct-core 0.37.0 shipped.
    func testReactionOnExistingMessageSurvivesSevenDays() {
        insertTargetMessage()
        apply(emoji: "😠", action: 1, ts: t0, now: t0)
        Reactions.sweepOrphans(nowMs: t0 + 7 * day, store: store)
        XCTAssertEqual(stored()?.emoji, "😠",
                       "TTL is for missing targets, not for old reactions on live messages")
    }

    /// A message stored under an upper-case id still holds its reactions. Mutation: compare ids
    /// exactly in `messageExists` — the reaction is swept as an orphan.
    func testAMessageWithAnUpperCaseIdIsHeld() {
        insertTargetMessage(id: target.uppercased())
        apply(emoji: "👍", action: 1, ts: t0, now: t0)
        Reactions.sweepOrphans(nowMs: t0 + 7 * day, store: store)
        XCTAssertEqual(stored()?.emoji, "👍")
    }

    /// Ids are stored lowercased, as the crate stores them, and read without case. Mutation: drop
    /// `lowercased()` in `upsert` — the stored target keeps its case.
    func testIdsAreLowercasedAtTheSeam() throws {
        try store.upsert(ReactionRecord(
            targetMessageId: target.uppercased(), reactorUserId: reactor.uppercased(),
            emoji: "🔥", timestampMs: t0, receivedAt: nil
        ))
        let row = try XCTUnwrap(store.reaction(on: target, by: reactor))
        XCTAssertEqual(row.targetMessageId, target)
        XCTAssertEqual(row.reactorUserId, reactor)
    }

    /// A message's reactions come oldest first. Mutation: sort descending.
    func testAMessagesReactionsComeOldestFirst() throws {
        apply(emoji: "🔥", action: 1, ts: t1, reactor: "22222222-2222-4333-8444-555555555555")
        apply(emoji: "❤️", action: 1, ts: t0)
        XCTAssertEqual(try store.reactions(on: target).map(\.emoji), ["❤️", "🔥"])
    }

    func testEnvelopeSecondsAreConvertedToMilliseconds() {
        XCTAssertEqual(Reactions.envelopeTimestampMs(1_700_000_000), 1_700_000_000_000)
        XCTAssertEqual(Reactions.envelopeTimestampMs(1_700_000_000_000), 1_700_000_000_000)
        XCTAssertEqual(Reactions.envelopeTimestampMs(0), 0)
    }

    func testRestoreLocal_IgnoresLWWAndPutsThePreviousRowBack() {
        apply(emoji: "😂", action: 1, ts: t0)
        apply(emoji: "❤️", action: 1, ts: t1)
        XCTAssertEqual(stored()?.emoji, "❤️")
        Reactions.restoreLocal(
            targetMessageId: target,
            reactorUserId: reactor,
            previous: ReactionReducer.Row(emoji: "😂", timestampMs: t0),
            nowMs: t1,
            store: store
        )
        XCTAssertEqual(stored()?.emoji, "😂")
        XCTAssertEqual(stored()?.timestampMs, t0, "rollback is not LWW — the wire refused the tap")
    }

    func testRestoreLocal_NilPreviousDeletesTheOptimisticRow() {
        apply(emoji: "❤️", action: 1, ts: t1)
        Reactions.restoreLocal(
            targetMessageId: target,
            reactorUserId: reactor,
            previous: nil,
            nowMs: t1,
            store: store
        )
        XCTAssertNil(stored())
    }
}
