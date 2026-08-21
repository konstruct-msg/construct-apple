//
//  ReactionStoreTests.swift
//  ConstructMessengerTests
//
//  Persist the ReactionReducer table: a reaction is a Reaction row, never a Message.
//  Orphans (target missing) stay until the target arrives or the 7-day TTL.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class ReactionStoreTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    private let target = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let reactor = "11111111-2222-4333-8444-555555555555"
    private let t0: Int64 = 1_700_000_000_000
    private let t1: Int64 = 1_700_000_000_500

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
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
        ReactionStore.applyIncoming(
            targetMessageId: target ?? self.target,
            reactorUserId: reactor ?? self.reactor,
            actionRawValue: action,
            emoji: emoji,
            payloadTimestampMs: ts,
            fallbackTimestampMs: 0,
            nowMs: now ?? ts,
            in: context
        )
    }

    private func stored() -> Reaction? {
        ReactionStore.row(targetMessageId: target, reactorUserId: reactor, in: context)
    }

    private func insertTargetMessage() {
        let msg = Message(context: context)
        msg.id = target
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
        XCTAssertEqual(ReactionStore.reactions(on: target, in: context).count, 1,
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
        XCTAssertTrue(ReactionStore.reactions(on: target, in: context).isEmpty)
    }

    func testOrphanIsStoredWhenTargetMissing() {
        apply(emoji: "😮", action: 1, ts: t0)
        XCTAssertNotNil(stored(), "a reaction that beat its message must still land")
        let messages = (try? context.fetch(Message.fetchRequest())) ?? []
        XCTAssertTrue(messages.isEmpty)
    }

    func testOrphanEvictedAfterSevenDaysIfTargetNeverArrives() {
        apply(emoji: "😢", action: 1, ts: t0, now: t0)
        XCTAssertNotNil(stored())
        let sevenDays = t0 + 7 * 24 * 60 * 60 * 1000
        ReactionStore.sweepOrphans(nowMs: sevenDays, in: context)
        XCTAssertNil(stored(), "an orphan whose target never arrived must not grow forever")
    }

    func testReactionOnExistingMessageSurvivesSevenDays() {
        insertTargetMessage()
        apply(emoji: "😠", action: 1, ts: t0, now: t0)
        let sevenDays = t0 + 7 * 24 * 60 * 60 * 1000
        ReactionStore.sweepOrphans(nowMs: sevenDays, in: context)
        XCTAssertEqual(stored()?.emoji, "😠",
                       "TTL is for missing targets, not for old reactions on live messages")
    }

    func testEnvelopeSecondsAreConvertedToMilliseconds() {
        XCTAssertEqual(ReactionStore.envelopeTimestampMs(1_700_000_000), 1_700_000_000_000)
        XCTAssertEqual(ReactionStore.envelopeTimestampMs(1_700_000_000_000), 1_700_000_000_000)
        XCTAssertEqual(ReactionStore.envelopeTimestampMs(0), 0)
    }

    func testRestoreLocal_IgnoresLWWAndPutsThePreviousRowBack() {
        apply(emoji: "😂", action: 1, ts: t0)
        apply(emoji: "❤️", action: 1, ts: t1)
        XCTAssertEqual(stored()?.emoji, "❤️")
        ReactionStore.restoreLocal(
            targetMessageId: target,
            reactorUserId: reactor,
            previous: ReactionReducer.Row(emoji: "😂", timestampMs: t0),
            nowMs: t1,
            in: context
        )
        XCTAssertEqual(stored()?.emoji, "😂")
        XCTAssertEqual(stored()?.timestampMs, t0, "rollback is not LWW — the wire refused the tap")
    }

    func testRestoreLocal_NilPreviousDeletesTheOptimisticRow() {
        apply(emoji: "❤️", action: 1, ts: t1)
        ReactionStore.restoreLocal(
            targetMessageId: target,
            reactorUserId: reactor,
            previous: nil,
            nowMs: t1,
            in: context
        )
        XCTAssertNil(stored())
    }
}
