//
//  TranscriptOrderIsTotalTests.swift
//  ConstructMessengerTests
//
//  The transcript's order key must be a *total* order, and every row must carry one.
//
//  Neither held. `serverOrderKey` is the sort key of twelve fetches, and two rows that compare
//  equal on it fall through to the secondary descriptor — `id`, a random UUID. Two ways to get
//  there: a row created with no key at all (the system notice, left nil until the next launch's
//  backfill), and two rows in the same millisecond (the key was `<ms>-<seq>` with `seq` fixed at
//  zero for anything local).
//
//  This is not only a display defect. `MessageRouter.isRepeatOfLastRow` — the check that stops a
//  notice restating a condition that has not changed — asks for *the newest row*. Among rows that
//  compare equal, "newest" was a coin flip, so the suppression sometimes read the wrong row and
//  let the duplicate through. That is the 2026-08-04 screenshot: five identical "session out of
//  sync" blocks, stacked.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class TranscriptOrderIsTotalTests: XCTestCase {

    // MARK: - The key itself

    /// Mutation: drop the `\(separator)\(messageId)` component from `ServerMessageOrder.local` —
    /// this reddens. It is the whole reason the key is total.
    func testTwoRowsInTheSameMillisecondGetDifferentKeys() {
        let sameInstant = Date(timeIntervalSince1970: 1_758_600_000.123)
        let a = ServerMessageOrder.local(timestamp: sameInstant, messageId: "AAAA-1111")
        let b = ServerMessageOrder.local(timestamp: sameInstant, messageId: "BBBB-2222")
        XCTAssertNotEqual(a, b, "same millisecond, two rows — equal keys hand the order to a random UUID")
        XCTAssertLessThan(a, b, "and the tie-break must be stable, not merely unequal")
    }

    /// Mutation: make `local` return `pending(localMessageId:)` — this reddens. A row with no
    /// server position is not a row *waiting* for one; pinning a notice below every later message
    /// is a different bug from ordering it at random.
    func testALocalRowSitsAtItsOwnTimestampAndNotAtTheBottom() {
        let older = ServerMessageOrder.local(timestamp: Date(timeIntervalSince1970: 1_000), messageId: "a")
        let newer = ServerMessageOrder.local(timestamp: Date(timeIntervalSince1970: 2_000), messageId: "b")
        let waiting = ServerMessageOrder.pending(localMessageId: "c")
        XCTAssertLessThan(older, newer, "a local key orders by its own timestamp")
        XCTAssertLessThan(newer, waiting, "a row still waiting for a server position stays below both")
    }

    /// Mutation: change the clamp in `local` from `1` to `0` — this reddens. `key(serverTimestamp…)`
    /// refuses zero, and the old code answered a zero timestamp with the pending sentinel, which
    /// sent the oldest row in the transcript to the bottom.
    func testAnEpochTimestampStaysAtTheTop() {
        let epoch = ServerMessageOrder.local(timestamp: Date(timeIntervalSince1970: 0), messageId: "a")
        let later = ServerMessageOrder.local(timestamp: Date(timeIntervalSince1970: 1), messageId: "b")
        XCTAssertLessThan(epoch, later)
        XCTAssertLessThan(epoch, ServerMessageOrder.pending(localMessageId: "c"))
    }

    // MARK: - Every row carries one

    /// The invariant the comment on `backfillMissingServerOrderKeys` had been asserting on its own
    /// since the column was added, while `addSystemMessage` left it nil.
    ///
    /// Mutation: delete `message.serverOrderKey = …` from any `Message(context:)` site in the app
    /// — this reddens and names the file and line.
    func testEveryRowCreationSiteStampsTheOrderColumn() {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")

        guard let walker = FileManager.default.enumerator(
            at: appRoot, includingPropertiesForKeys: nil
        ) else { return XCTFail("cannot walk \(appRoot.path)") }

        var offenders: [String] = []
        var sitesChecked = 0

        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !url.path.contains("/Generated/"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains("= Message(context:") {
                sitesChecked += 1
                // The stamp is written with the row's other columns, so a generous window is
                // still a tight claim: it must be in the same construction block.
                let window = lines[index..<min(index + 30, lines.count)].joined(separator: "\n")
                if !window.contains("serverOrderKey") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertGreaterThan(sitesChecked, 5, "found no row creation sites — the walk itself is broken")
        XCTAssertTrue(
            offenders.isEmpty,
            "a Message row is created without an order key at: \(offenders.joined(separator: ", ")). "
            + "A nil key sorts by a random UUID in every transcript fetch."
        )
    }

    // MARK: - What it buys

    /// The behaviour the random tie-break was corrupting. Repeated, because a coin flip passes
    /// once in two: the old code failed this roughly half of every run, which is exactly how
    /// `SystemNoticeRepeatTests` came to be a "known flake".
    ///
    /// Mutation: give both rows the same `serverOrderKey` — this reddens within a few iterations.
    func testTheNewestRowIsDecidedByTheKeyAndNotByAUuid() {
        for _ in 0..<50 {
            let container = PersistenceController(inMemory: true).container
            let context = container.viewContext

            let other = User(context: context)
            other.id = UUID().uuidString
            other.username = "annie"
            let chat = Chat(context: context)
            chat.id = UUID().uuidString
            chat.otherUser = other

            let notice = "The encrypted session is out of sync."
            add(notice, from: "SYSTEM", at: Date(timeIntervalSince1970: 1_000), to: chat, in: context)
            add("Привет", from: "annie", at: Date(timeIntervalSince1970: 2_000), to: chat, in: context)
            try? context.save()

            XCTAssertFalse(
                MessageRouter.isRepeatOfLastRowForTesting(notice, in: chat, context: context),
                "the message is newer, so the notice is news again — reading a random row loses this"
            )
        }
    }

    private func add(
        _ text: String, from: String, at timestamp: Date,
        to chat: Chat, in context: NSManagedObjectContext
    ) {
        let m = Message(context: context)
        m.id = UUID().uuidString
        m.chat = chat
        m.fromUserId = from
        m.toUserId = "me"
        m.timestamp = timestamp
        m.serverOrderKey = ServerMessageOrder.local(timestamp: timestamp, messageId: m.id)
        m.isSentByMe = false
        m.deliveryStatus = .delivered
        m.applyStoredEncryption(plaintext: text, contactId: "annie")
    }
}
