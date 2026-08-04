//
//  DurableAckExpectationTests.swift
//  ConstructMessengerTests
//
//  `CfeAction.persistAck` says "platform must durable-persist this record" (core `ack_store.rs:109`).
//  The platform never did. The handler called `markAckProcessedInOrchestrator`, which is provably
//  inert — `mark_processed` inserts into the cache BEFORE emitting the action, so the second call
//  short-circuits — and recorded `persist_ack_platform_only_memory` on every decrypted message.
//  A counter that increments once per message measures traffic, not failure: the same inversion
//  `chunkReassemblyExpired` had to correct, and it made the gap it was named for invisible.
//
//  The L2 write does happen, in `MessageRouter`'s terminal paths. The action was therefore not
//  useless — it was the core stating an obligation that nothing checked. These tests pin the
//  settlement: an obligation is outstanding until Core Data actually has the record, and clearing
//  it is one-shot so a second pass over the same id cannot report a stale gap.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class DurableAckExpectationTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }
    private let store = PersistentACKStore.shared
    private let sender = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        store.resetDurableWriteExpectationsForTesting()
    }

    override func tearDown() {
        store.resetDurableWriteExpectationsForTesting()
        container = nil
        super.tearDown()
    }

    // MARK: - The gap

    /// The core asked, nobody wrote: this is the case the metric exists for.
    func testUnwrittenObligationIsReportedAsAGap() {
        let id = UUID().uuidString
        store.expectDurableWrite(id)

        XCTAssertTrue(store.settleDurableWrite(id, in: context),
                      "the core required a durable record and Core Data has none — after a restart "
                      + "the message comes back with nothing remembering it")
    }

    /// The healthy path: a terminal path wrote L2 before the pass ended.
    func testWrittenObligationIsNotAGap() {
        let id = UUID().uuidString
        store.expectDurableWrite(id)
        store.markProcessed(id, senderId: sender, in: context)

        XCTAssertFalse(store.settleDurableWrite(id, in: context),
                       "an obligation the router honoured must be silent — a signal that fires on "
                       + "healthy traffic disables the check it belongs to")
    }

    /// No obligation, no verdict. Messages the core never asked about (control carriers it
    /// short-circuits, duplicates it drops) must not be accused of missing a write they were
    /// never required to make.
    func testNoObligationIsNeverAGap() {
        let id = UUID().uuidString

        XCTAssertFalse(store.settleDurableWrite(id, in: context),
                       "the core did not ask about this message")
    }

    // MARK: - Settlement is one-shot

    /// A second settle must not re-report. The router settles once per routing pass, and the same
    /// envelope is re-delivered constantly — a sticky obligation would turn one real gap into an
    /// ERROR on every redelivery of that id.
    func testSettlingTwiceReportsOnce() {
        let id = UUID().uuidString
        store.expectDurableWrite(id)

        XCTAssertTrue(store.settleDurableWrite(id, in: context))
        XCTAssertFalse(store.settleDurableWrite(id, in: context),
                       "the obligation was already reported and cleared")
    }

    /// Clearing happens even when the write DID land, or the entry would leak for the lifetime of
    /// the process — every healthy message would accumulate.
    func testSettlingClearsTheObligationOnTheHealthyPathToo() {
        let id = UUID().uuidString
        store.expectDurableWrite(id)
        store.markProcessed(id, senderId: sender, in: context)

        _ = store.settleDurableWrite(id, in: context)
        XCTAssertFalse(store.hasOutstandingDurableWriteForTesting(id))
    }

    /// Obligations are per message, so one unmet id cannot implicate another.
    func testObligationsAreIndependent() {
        let unmet = UUID().uuidString
        let honoured = UUID().uuidString
        store.expectDurableWrite(unmet)
        store.expectDurableWrite(honoured)
        store.markProcessed(honoured, senderId: sender, in: context)

        XCTAssertFalse(store.settleDurableWrite(honoured, in: context))
        XCTAssertTrue(store.settleDurableWrite(unmet, in: context))
    }

    // MARK: - Not covered here, on purpose
    //
    // "The obligation must read Core Data, not the in-memory ACK cache" is the subtlest property of
    // `settleDurableWrite` and there is NO test for it, because none is possible in this target.
    //
    // A test was written and it was vacuous. Swapping `isProcessedInCoreData` for `isProcessed`
    // (which consults the cache first) left the whole suite green: `isInCache` asks the Rust
    // orchestrator, the orchestrator is not up in unit tests, so the cache branch returns false and
    // both spellings take the same path. `markProcessedInCache` writes somewhere nothing can read.
    // The test asserted the right thing and could not observe it — it read as coverage of exactly
    // the property most worth covering. Deleted rather than left green.
    //
    // The property is held structurally instead: `settleDurableWrite` names
    // `isProcessedInCoreData` directly, and that method's own doc says why the cache cannot answer
    // this class of question. Reaching it from a test needs an injection seam on `CryptoManager`,
    // which is a larger change than this defect justifies.
}
