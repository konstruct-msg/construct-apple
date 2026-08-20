//
//  SingleAckCacheTests.swift
//  ConstructMessengerTests
//
//  Until 2026-08-02 the question "was this message processed?" had two in-memory answers:
//  the orchestrator's `lifecycle.ack_store`, and a second, entirely independent `RustAckStore`
//  owned by `PersistentACKStore`. `RustAckStore::new()` builds a fresh `AckStore::default()`,
//  so the two never saw each other's writes — the Rust decrypt path marked only the first,
//  `preemptACK` marked only the second, and one site in `PublicKeyBundleHandler` wrote both
//  plus Core Data in a row under a comment claiming the orchestrator cache "persists with the
//  next state save" (it does not: `export_orchestrator_state_cfe` writes an empty
//  `processed_ids` on purpose).
//
//  There is now one cache and one durable store. These tests pin that, and pin the one place
//  the cache must deliberately NOT be consulted.
//
//  Acceptance is mutation-based: give `PersistentACKStore` its own `RustAckStore()` again and
//  testOrchestratorMarkIsVisibleToAckStore must go red.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class SingleAckCacheTests: XCTestCase {

    @MainActor
    override func setUpWithError() throws {
        try CryptoCoreTestBootstrap.ensureCore(localUserId: "1a2b3c4d-0000-4000-8000-000000000002")
    }

    private func freshId(_ tag: String) -> String {
        "ack-\(tag)-\(UUID().uuidString)"
    }

    /// The direction that was broken: Rust marks on its own decrypt path, and every Swift-side
    /// duplicate guard reads through `PersistentACKStore`. Two stores meant the guard never saw
    /// what the decrypt path had already recorded.
    @MainActor
    func testOrchestratorMarkIsVisibleToAckStore() {
        let messageId = freshId("orchestrator-write")
        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))

        CryptoManager.shared.markAckProcessedInOrchestrator(messageId: messageId)

        XCTAssertTrue(
            PersistentACKStore.shared.isProcessedInMemory(messageId),
            "A mark made in the orchestrator must be the same fact PersistentACKStore reads"
        )
    }

    /// The reverse direction, so neither side can drift back into owning its own cache.
    @MainActor
    func testAckStoreMarkIsVisibleToOrchestrator() {
        let messageId = freshId("swift-write")
        XCTAssertNotEqual(CryptoManager.shared.ackIsProcessedInOrchestrator(messageId: messageId), .inCache)

        PersistentACKStore.shared.markProcessedInCache(messageId)

        XCTAssertEqual(
            CryptoManager.shared.ackIsProcessedInOrchestrator(messageId: messageId),
            .inCache,
            "PersistentACKStore must write the orchestrator's cache, not a private one"
        )
    }

    /// `CheckAckInDb` asks "was this processed in a *prior* session?". A mark made earlier in
    /// this same launch must not answer it — otherwise a live message becomes a phantom
    /// duplicate and is dropped without ever reaching the transcript.
    @MainActor
    func testCacheMarkDoesNotAnswerTheDurableQuestion() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let messageId = freshId("cache-only")

        PersistentACKStore.shared.markProcessedInCache(messageId)

        XCTAssertTrue(PersistentACKStore.shared.isProcessedInMemory(messageId))
        XCTAssertFalse(
            PersistentACKStore.shared.isProcessedInCoreData(messageId, in: context),
            "A cache-only mark must never be mistaken for a durable ACK from a prior launch"
        )
    }

    /// A durable ACK warms the cache, so the hot-path guard stops paying for a fetch.
    @MainActor
    func testDurableHitWarmsTheCache() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let messageId = freshId("durable-warm")

        let record = ProcessedMessage(context: context)
        record.messageId = messageId
        record.senderId = "sender"
        record.processedAt = Date()
        try context.save()

        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))
        XCTAssertTrue(PersistentACKStore.shared.isProcessedInCoreData(messageId, in: context))
        XCTAssertTrue(
            PersistentACKStore.shared.isProcessedInMemory(messageId),
            "A durable hit must warm the single cache"
        )
    }
}
